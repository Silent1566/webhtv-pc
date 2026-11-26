/// IMDb 免 Key 评分：GraphQL 优先，标题页 HTML 只兜底一次。
///
/// 共享实例语义（AppState 只应持有一个）：成功的分值与投票数按 trim 后的
/// $imdbId$ 缓存 $cacheTtl$，最多 $maxCacheEntries$ 条，空值**不缓存**；
/// 同一 ID 的并发查询共享同一个 Future，只发一轮请求。失败后清掉在途状态，
/// 下一次调用可以重试。$close()$ 清空缓存与在途状态，之后的返回不再进缓存。
///
/// 任一通道失败只记 warning，不影响详情页；每次查询最多两个请求。
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/imdb_rating.dart';
import 'log_service.dart';

class ImdbRatingService {
  ImdbRatingService({
    http.Client? client,
    this.baseUrl = defaultBaseUrl,
    this.graphqlUrl = defaultGraphqlUrl,
    this.timeout = const Duration(seconds: 10),
    this.cacheTtl = const Duration(days: 7),
    LogService? log,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       // ignore: prefer_initializing_formals
       _log = log;

  static const String defaultBaseUrl = 'https://www.imdb.com';
  static const String defaultGraphqlUrl = 'https://api.graphql.imdb.com/';
  static const int maxBytes = 4 * 1024 * 1024;
  static const int maxCacheEntries = 64;

  static const String _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
  static final RegExp _imdbIdPattern = RegExp(r'^tt[0-9]{7,}$');
  static const _headers = {
    'User-Agent': _userAgent,
    'Accept-Language': 'en-US,en;q=0.9',
  };

  /// HTML 兜底根地址；GraphQL 地址单独注入，两条通道均可使用测试传输。
  final String baseUrl;
  final String graphqlUrl;
  final Duration timeout;

  /// 成功分值的内存缓存存活时间。
  final Duration cacheTtl;
  final http.Client _client;
  final bool _ownsClient;
  final LogService? _log;

  final _cache = <String, _CachedRating>{};
  final _inFlight = <String, Future<ImdbRating>>{};
  bool _closed = false;

  Future<ImdbRating> byImdbId(String imdbId) async {
    final id = imdbId.trim();
    if (_closed || !_imdbIdPattern.hasMatch(id)) return ImdbRating.empty;
    final cached = _read(id);
    if (cached != null) return cached;
    final pending = _inFlight[id];
    if (pending != null) return pending;

    final future = _load(id);
    _inFlight[id] = future;
    try {
      return await future;
    } finally {
      // 失败也要移除：下一次调用才是可重试的；成功时值已经在缓存里。
      if (identical(_inFlight[id], future)) _inFlight.remove(id);
    }
  }

  Future<ImdbRating> _load(String id) async {
    final rating = await _request(id);
    // 页面没有评分是正常空值（不进缓存、不写日志）；关闭后到达的结果同样丢弃。
    if (_closed || rating.isEmpty) return ImdbRating.empty;
    _write(id, rating);
    return rating;
  }

  Future<ImdbRating> _request(String id) async {
    try {
      final base = _httpUri(baseUrl);
      final graphql = _httpUri(graphqlUrl);
      if (base == null || graphql == null) return ImdbRating.empty;
      final path = base.path.endsWith('/') ? base.path : '${base.path}/';
      final title = base.replace(path: '${path}title/$id/');
      final rating = await _graphqlRating(graphql, id);
      if (rating.isNotEmpty) return rating;
      return await _htmlRating(title);
    } catch (error) {
      _warn('IMDb 查询失败：$error');
      return ImdbRating.empty;
    }
  }

  Future<ImdbRating> _graphqlRating(Uri uri, String id) async {
    try {
      final response = await _client
          .post(
            uri,
            headers: const {
              ..._headers,
              'content-type': 'application/json',
              'x-imdb-client-name': 'imdb-web-next',
              'accept': 'application/graphql-response+json, application/json',
            },
            body: jsonEncode({
              'query':
                  'query { title(id: "$id") { ratingsSummary { aggregateRating voteCount } } }',
            }),
          )
          .timeout(timeout);
      if (!_usable(response, 'GraphQL')) return ImdbRating.empty;
      // 200 但没有分值属于「该条目没人打分」，是正常空值，不写 warning。
      return parseImdbGraphqlRating(
        jsonDecode(utf8.decode(response.bodyBytes)),
      );
    } catch (error) {
      _warn('IMDb GraphQL 请求失败：$error');
      return ImdbRating.empty;
    }
  }

  Future<ImdbRating> _htmlRating(Uri uri) async {
    try {
      final response = await _client
          .get(uri, headers: _headers)
          .timeout(timeout);
      if (!_usable(response, 'HTML')) return ImdbRating.empty;
      return parseImdbTitlePage(
        utf8.decode(response.bodyBytes, allowMalformed: true),
      );
    } catch (error) {
      _warn('IMDb HTML 请求失败：$error');
      return ImdbRating.empty;
    }
  }

  bool _usable(http.Response response, String source) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      _warn('IMDb $source 返回 HTTP ${response.statusCode}');
      return false;
    }
    if (response.bodyBytes.length > maxBytes) {
      _warn('IMDb $source 响应超过 4MB');
      return false;
    }
    return true;
  }

  Uri? _httpUri(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        uri.host.isEmpty ||
        (uri.scheme != 'https' && uri.scheme != 'http')) {
      return null;
    }
    return uri;
  }

  ImdbRating? _read(String id) {
    final entry = _cache[id];
    if (entry == null) return null;
    final age = DateTime.now().difference(entry.at);
    if (age.isNegative || age >= cacheTtl) {
      _cache.remove(id);
      return null;
    }
    return entry.rating;
  }

  void _write(String id, ImdbRating rating) {
    if (_closed) return;
    _cache[id] = _CachedRating(DateTime.now(), rating);
    if (_cache.length > maxCacheEntries) _cache.remove(_cache.keys.first);
  }

  void _warn(String message) => _log?.warning(message, scope: 'tmdb');

  void close() {
    if (_closed) return;
    _closed = true;
    _cache.clear();
    _inFlight.clear();
    if (_ownsClient) _client.close();
  }
}

class _CachedRating {
  const _CachedRating(this.at, this.rating);
  final DateTime at;
  final ImdbRating rating;
}
