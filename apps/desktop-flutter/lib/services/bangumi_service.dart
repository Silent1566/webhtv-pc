/// Bangumi API v0 客户端（「TMDB 不可用时的外部元数据兜底」）。
///
/// 为什么单独一层：豆瓣 / Bangumi 只在 TMDB 拿不到数据时兜底（用户决策
/// 2026-11-17），兜底源**绝不能**把主链路拖下水——所以这里把「网络 + 限速 +
/// 缓存 + 重试」全部关在一个类里，对外只暴露 5 个方法：
/// - [search]：**永不抛异常**，任何失败都返回 `const []`（兜底失败 = 无兜底）；
/// - [subject] / [persons] / [person] / [personSubjects]：失败抛
///   [BangumiException]，由调用方决定怎么退化。
///
/// 已冻结的接口事实（2026-11 实测，不要按「常识」改）：
/// - 搜索是 **POST** + JSON body，filter.type 默认 `[2, 6]`，覆盖动画与
///   三次元作品；书籍 1、音乐 3、游戏 4 不属于本服务的影视兜底范围；
/// - `persons` 与 `personSubjects` 的响应是**裸 JSON 数组**，不是
///   `{data:..}` 包装，按包装解析会一律空手而归；
/// - Bangumi 要求 `User-Agent`，缺了会被拒；实测偶发 TLS 断连，因此每个
///   请求最多重试 [maxRetries] 次（只有网络异常与 5xx 重试，4xx 不重试）。
///
/// 边界：
/// - 只依赖 `package:http`，**不 import Flutter**，可被纯 Dart 脚本直接跑；
/// - 所有请求串行（[minInterval] 间隔），同一 URL 走内存缓存
///   （[cacheDirectory] 非空时额外落盘），缓存时间基准可注入（[clock]）；
/// - 日志不打印响应体 / 请求头 / 凭据，除 UA 外的敏感内容一律不出现在日志里。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../core/external_meta.dart';
import '../core/meta_source.dart';
import '../core/tmdb_identity.dart';
import '../core/tmdb_title.dart';

/// Bangumi 要求的 User-Agent（缺 UA 会被站点拒绝）。
const String bangumiUserAgent =
    'webhtv-pc/0.1 (https://github.com/Silent1566/webhtv-pc)';

/// Bangumi 请求失败的统一异常。
class BangumiException implements Exception {
  const BangumiException(this.message, {this.statusCode});

  final String message;

  /// HTTP 状态码；网络异常（没有响应）时为 `null`。
  final int? statusCode;

  @override
  String toString() => statusCode == null
      ? 'BangumiException: $message'
      : 'BangumiException($statusCode): $message';
}

/// 影视兜底覆盖动画（2）和三次元（6）；最终匹配交给 MetaMatchRules。
const List<int> _subjectTypes = [2, 6];

/// 搜索单页条数。10 条足够让 `MetaMatchRules.choose` 做出取舍。
const int _searchLimit = 10;

/// 作品详情 / 人物详情的缓存时间（详情几乎不变，给足）。
const Duration _subjectTtl = Duration(hours: 24);
const Duration _personTtl = Duration(hours: 24);

/// 列表类（演职员 / 人物作品）的缓存时间（会随新集数更新，短一点）。
const Duration _subjectListTtl = Duration(hours: 12);

/// 搜索结果的缓存时间（同名词条会变，但短时间内重复搜很常见）。
const Duration _searchTtl = Duration(hours: 1);

/// 单个请求**额外**的重试次数；总尝试次数 = 1 + 2 = 3。
const int maxRetries = 2;

/// 单次 HTTP 请求的超时。
const Duration _requestTimeout = Duration(seconds: 15);

/// 内存缓存条数上限（超了淘汰最旧的一条，桌面端常驻不必无限增长）。
const int _memoryCacheLimit = 64;

/// Bangumi API v0 客户端。
class BangumiService {
  BangumiService({
    http.Client? client,
    Uri? baseUri,
    this.userAgent = bangumiUserAgent,
    this.minInterval = const Duration(seconds: 1),
    Directory? cacheDirectory,
    DateTime Function()? clock,
    Future<void> Function(Duration)? delay,
    void Function(String message)? log,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       _baseUri = baseUri ?? Uri.parse('https://api.bgm.tv'),
       // 具名参数与被赋值的私有字段不同名，不能写成初始化形参。
       // ignore: prefer_initializing_formals
       _cacheDirectory = cacheDirectory,
       _clock = clock ?? DateTime.now,
       _delay = delay ?? Future<void>.delayed,
       // ignore: prefer_initializing_formals
       _log = log;

  /// 请求头里的 UA（同时也是日志里唯一允许出现的固定串）。
  final String userAgent;

  /// 两次请求之间的最小间隔；串行执行，不并发打 Bangumi。
  final Duration minInterval;

  final http.Client _client;
  final bool _ownsClient;
  final Uri _baseUri;
  final Directory? _cacheDirectory;
  final DateTime Function() _clock;
  final Future<void> Function(Duration) _delay;
  final void Function(String message)? _log;

  /// 限速队列：串成一条 Future 链，天然保证「上一次请求结束 → 等间隔 →
  /// 下一次」，不需要锁也不需要轮询。
  Future<void> _queue = Future<void>.value();
  DateTime? _lastRequestAt;

  final _memory = <String, _CacheEntry>{};
  bool _closed = false;

  // -------------------------------------------------------------------------
  // §1 搜索
  // -------------------------------------------------------------------------

  /// 检索动画与三次元作品候选；**任何失败都返回 `const []`**（不抛异常）。
  ///
  /// 这里只做「请求 + 解析成 [MetaCandidate]」，**不做**二次过滤与排序：
  /// 打分与取舍是 `MetaMatchRules.choose` 的职责，两处都写会让阈值漂移。
  Future<List<MetaCandidate>> search(MetaQuery query) async {
    if (_closed) return const [];
    try {
      final keywords = query.queries;
      if (keywords.isEmpty) return const [];
      final body = await _cachedJson(
        path: '/v0/search/subjects',
        query: {'limit': '$_searchLimit'},
        body: {
          'keyword': keywords.first,
          'filter': {'type': _subjectTypes},
        },
        ttl: _searchTtl,
      );
      return _candidates(body);
    } catch (error) {
      // 兜底源失败绝不能冒泡到详情页：调用方拿到空列表就会自己退化。
      // 只记异常类型，不记响应体（可能含整页 HTML / 用户查询内容）。
      _emitLog('Bangumi 搜索失败（已忽略）: ${error.runtimeType}');
      return const [];
    }
  }

  // -------------------------------------------------------------------------
  // §2 作品与人物
  // -------------------------------------------------------------------------

  /// `/v0/subjects/{id}` 的原始 JSON（不做字段裁剪：详情页按需取）。
  Future<Map<String, Object?>> subject(int id) async {
    _ensureValidId(id);
    final body = await _cachedJson(path: '/v0/subjects/$id', ttl: _subjectTtl);
    return _objectOf(body, 'subject $id');
  }

  /// `/v0/subjects/{id}/persons` 的原始 JSON 列表（响应是**裸数组**）。
  Future<List<Map<String, Object?>>> persons(int subjectId) async {
    _ensureValidId(subjectId);
    final body = await _cachedJson(
      path: '/v0/subjects/$subjectId/persons',
      ttl: _subjectListTtl,
    );
    return _listOf(body, 'subjects/$subjectId/persons');
  }

  /// `/v0/persons/{id}` 的原始 JSON。
  Future<Map<String, Object?>> person(int personId) async {
    _ensureValidId(personId);
    final body = await _cachedJson(
      path: '/v0/persons/$personId',
      ttl: _personTtl,
    );
    return _objectOf(body, 'person $personId');
  }

  /// `/v0/persons/{id}/subjects` 的原始 JSON 列表（响应是**裸数组**）。
  Future<List<Map<String, Object?>>> personSubjects(int personId) async {
    _ensureValidId(personId);
    final body = await _cachedJson(
      path: '/v0/persons/$personId/subjects',
      ttl: _subjectListTtl,
    );
    return _listOf(body, 'persons/$personId/subjects');
  }

  // -------------------------------------------------------------------------
  // §3 生命周期
  // -------------------------------------------------------------------------

  /// 关闭内部自建的 client 并清空缓存；自注入的 client 由调用方负责关闭。
  void close() {
    if (_closed) return;
    _closed = true;
    _memory.clear();
    if (_ownsClient) _client.close();
  }

  void _ensureOpen() {
    if (_closed) throw const BangumiException('Bangumi 客户端已关闭');
  }

  void _ensureValidId(int id) {
    _ensureOpen();
    if (id <= 0) throw const BangumiException('Bangumi id 必须大于 0');
  }

  void _emitLog(String message) {
    try {
      _log?.call(message);
    } catch (_) {
      // 可选诊断回调失败不能改变兜底请求的结果。
    }
  }

  // -------------------------------------------------------------------------
  // §4 请求：缓存 → 串行限速 → 重试
  // -------------------------------------------------------------------------

  /// 取 JSON：先查缓存，未命中才排队发请求并回填缓存。
  Future<Object?> _cachedJson({
    required String path,
    required Duration ttl,
    Map<String, String>? query,
    Map<String, Object?>? body,
  }) async {
    _ensureOpen();
    final uri = _uri(path, query: query);
    final encoded = body == null ? null : jsonEncode(body);
    // POST 的 URL 相同不代表请求相同，body 必须进缓存键。
    final key = encoded == null ? 'GET $uri' : 'POST $uri $encoded';
    final cached = await _readCache(key, ttl);
    _ensureOpen();
    if (cached.found) return cached.value;

    final raw = await _serialize(() => _fetch(uri, body: encoded));
    _ensureOpen();
    final decoded = _decode(raw, path);
    await _writeCache(key, decoded);
    return decoded;
  }

  /// 拼出请求地址：`baseUri` 自带路径前缀（反代 / 测试桩）时保留前缀。
  Uri _uri(String path, {Map<String, String>? query}) {
    final base = _baseUri;
    var prefix = base.path;
    if (prefix == '/') {
      prefix = '';
    } else if (prefix.endsWith('/')) {
      prefix = prefix.substring(0, prefix.length - 1);
    }
    return base.replace(path: '$prefix$path', queryParameters: query);
  }

  /// 串行化 + 间隔限速：所有请求依次执行，两次之间至少隔 [minInterval]。
  Future<T> _serialize<T>(Future<T> Function() action) async {
    final previous = _queue;
    final gate = Completer<void>();
    _queue = gate.future;
    try {
      await previous;
      _ensureOpen();
      return await action();
    } finally {
      if (!gate.isCompleted) gate.complete();
    }
  }

  /// 等到距上次请求至少 [minInterval]；时间基准走可注入的 [clock]。
  Future<void> _space() async {
    _ensureOpen();
    final last = _lastRequestAt;
    if (last != null) {
      final elapsed = _clock().difference(last);
      if (elapsed < minInterval) await _delay(minInterval - elapsed);
    }
    _ensureOpen();
    _lastRequestAt = _clock();
  }

  /// 发一次请求（含重试），返回响应体文本；失败抛 [BangumiException]。
  Future<String> _fetch(Uri uri, {String? body}) async {
    Object? failure;
    int? status;
    for (var attempt = 0; attempt <= maxRetries; attempt++) {
      await _space();
      try {
        final response = await _send(uri, body: body);
        _ensureOpen();
        final code = response.statusCode;
        if (code == 200) return _bodyText(response);
        status = code;
        if (code < 500 || code >= 600) {
          // 4xx 是「请求本身不对」（id 不存在 / UA 被拒）：重试只会再失败一次。
          throw BangumiException(
            'Bangumi ${uri.path} 返回 HTTP $code',
            statusCode: code,
          );
        }
        failure = BangumiException(
          'Bangumi ${uri.path} 返回 HTTP $code',
          statusCode: code,
        );
      } on BangumiException {
        rethrow;
      } catch (error) {
        // TLS 断连 / DNS / 超时：实测偶发，重试通常就好。
        _ensureOpen();
        if (error is! IOException &&
            error is! http.ClientException &&
            error is! TimeoutException) {
          throw BangumiException('Bangumi 请求失败: ${error.runtimeType}');
        }
        failure = error;
        status = null;
      }
      _emitLog('Bangumi 第 ${attempt + 1} 次尝试失败: ${uri.path}');
    }
    final message = failure is BangumiException
        ? failure.message
        : 'Bangumi ${uri.path} 请求失败: ${failure.runtimeType}';
    throw BangumiException(message, statusCode: status);
  }

  Future<http.Response> _send(Uri uri, {String? body}) async {
    _ensureOpen();
    final request = http.Request(body == null ? 'GET' : 'POST', uri);
    request.headers['User-Agent'] = userAgent;
    request.headers['Accept'] = 'application/json';
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      // 用 bodyBytes 显式 UTF-8：中文关键词不能依赖 client 的默认编码。
      request.bodyBytes = utf8.encode(body);
    }
    // 超时覆盖响应头和完整 body；只限制 send 会漏掉挂起的 body 流。
    return _client
        .send(request)
        .then(http.Response.fromStream)
        .timeout(_requestTimeout);
  }

  /// 响应体解码：`response.body` 在 `Content-Type` 不带 charset 时会退回
  /// latin1，中文标题整片乱码，因此这里固定按 UTF-8 解。
  static String _bodyText(http.Response response) =>
      utf8.decode(response.bodyBytes, allowMalformed: true);

  Object? _decode(String raw, String path) {
    try {
      return jsonDecode(raw);
    } on FormatException {
      throw BangumiException('Bangumi $path 响应不是合法 JSON');
    }
  }

  // -------------------------------------------------------------------------
  // §5 缓存
  // -------------------------------------------------------------------------

  Future<({bool found, Object? value})> _readCache(
    String key,
    Duration ttl,
  ) async {
    _ensureOpen();
    final now = _clock();
    final memory = _memory[key];
    if (memory != null) {
      if (now.difference(memory.time) < ttl) {
        return (found: true, value: memory.value);
      }
      _memory.remove(key);
    }
    final directory = _cacheDirectory;
    if (directory == null) return (found: false, value: null);
    final file = _cacheFile(directory, key);
    try {
      final exists = await file.exists();
      _ensureOpen();
      if (!exists) return (found: false, value: null);
      final stat = await file.stat();
      _ensureOpen();
      if (now.difference(stat.modified) >= ttl) {
        return (found: false, value: null);
      }
      final raw = await file.readAsString();
      _ensureOpen();
      final decoded = _decode(raw, key);
      _memory[key] = _CacheEntry(stat.modified, decoded);
      return (found: true, value: decoded);
    } on BangumiException {
      rethrow;
    } catch (_) {
      // 缓存坏了就当作没命中：绝不因为缓存文件让请求失败。
      return (found: false, value: null);
    }
  }

  Future<void> _writeCache(String key, Object? value) async {
    if (_closed) return;
    _memory[key] = _CacheEntry(_clock(), value);
    _trimMemory();
    final directory = _cacheDirectory;
    if (directory == null) return;
    try {
      await directory.create(recursive: true);
      if (_closed) return;
      await _cacheFile(directory, key).writeAsString(jsonEncode(value));
    } catch (_) {
      // 落盘失败只是少了下次启动的加速，不影响本次结果。
    }
  }

  void _trimMemory() {
    while (_memory.length > _memoryCacheLimit) {
      String? oldestKey;
      DateTime? oldestAt;
      for (final entry in _memory.entries) {
        if (oldestAt == null || entry.value.time.isBefore(oldestAt)) {
          oldestAt = entry.value.time;
          oldestKey = entry.key;
        }
      }
      if (oldestKey == null) return;
      _memory.remove(oldestKey);
    }
  }

  /// 缓存文件名：URL 里有 `/`、`?`、中文，直接用会被文件系统拒绝；
  /// 定长十六进制名同时避开 Windows 的 255 字节文件名上限。
  static File _cacheFile(Directory directory, String key) {
    final hash = _fnv1a(key).toRadixString(16).padLeft(8, '0');
    return File('${directory.path}${Platform.pathSeparator}bgm_$hash.json');
  }

  /// FNV-1a（32 位）：稳定、无依赖，只用来给缓存文件起名。
  static int _fnv1a(String value) {
    var hash = 0x811c9dc5;
    for (final byte in utf8.encode(value)) {
      hash = ((hash ^ byte) * 0x01000193) & 0xffffffff;
    }
    return hash;
  }

  // -------------------------------------------------------------------------
  // §6 响应 → 类型
  // -------------------------------------------------------------------------

  /// 搜索响应 → 候选列表。
  ///
  /// 注意：`id <= 0` 的条目**丢弃**（构造不出 [MetaIdentity]，留着只会让
  /// 打分拿到不可用的身份）；其余条目一条都不筛，取舍交给
  /// `MetaMatchRules.choose`。
  List<MetaCandidate> _candidates(Object? body) {
    final values = <Object?>[];
    if (body is List) {
      values.addAll(body);
    } else if (body is Map) {
      final data = body['data'];
      if (data is List) values.addAll(data);
    }
    final result = <MetaCandidate>[];
    for (final value in values) {
      if (value is! Map) continue;
      final map = value.cast<String, Object?>();
      final identity = MetaIdentity.of(
        MetaSourceKind.bangumi,
        _mediaTypeOf(map),
        _int(map['id']),
      );
      if (identity == null) continue;
      final name = _text(map, 'name');
      final nameCn = _text(map, 'name_cn');
      final title = nameCn.isEmpty ? name : nameCn;
      final poster = _posterOf(map);
      final summary = _text(map, 'summary');
      result.add(
        MetaCandidate(
          identity: identity,
          title: title,
          originalTitle: name == title ? '' : name,
          year: firstYear(_text(map, 'date')),
          episodeCount: _episodeCountOf(map),
          rating: _ratingOf(map),
          posterUrl: poster.isEmpty ? null : poster,
          overview: summary.isEmpty ? null : summary,
          seasonLabel: _seasonLabel(title.isEmpty ? name : title),
        ),
      );
    }
    return result;
  }

  /// `platform` → movie / tv。
  ///
  /// 先判电影：`剧场版` 里含「剧」字，按「含剧即 tv」先判会把剧场版错判
  /// 成剧集。
  TmdbMediaType _mediaTypeOf(Map<String, Object?> map) {
    final platform = _text(map, 'platform');
    if (platform.contains('剧场版') || platform.contains('电影')) {
      return TmdbMediaType.movie;
    }
    if (platform.contains('剧')) return TmdbMediaType.tv;
    // 没有可用的 platform：用集数兜底（多集只会是剧集，单集更可能是电影）。
    final eps = _int(map['eps']);
    final total = _int(map['total_episodes']);
    return eps > 1 || total > 1 ? TmdbMediaType.tv : TmdbMediaType.movie;
  }

  Map<String, Object?> _objectOf(Object? body, String label) {
    if (body is! Map) {
      throw BangumiException('Bangumi $label 响应不是 JSON 对象');
    }
    return body.cast<String, Object?>();
  }

  List<Map<String, Object?>> _listOf(Object? body, String label) {
    if (body is! List) {
      throw BangumiException('Bangumi $label 响应不是 JSON 数组');
    }
    final result = <Map<String, Object?>>[];
    for (final value in body) {
      // 数组里混进非对象元素时跳过，不因一条脏数据丢掉整页演职员。
      if (value is Map) result.add(value.cast<String, Object?>());
    }
    return result;
  }
}

/// 一条缓存记录：写入时间 + 已解码的 JSON。
class _CacheEntry {
  const _CacheEntry(this.time, this.value);

  final DateTime time;
  final Object? value;
}

// ---------------------------------------------------------------------------
// 字段读取与形态归一（响应里的数字可能被写成字符串，一律容错）
// ---------------------------------------------------------------------------

Map<String, Object?> _map(Object? value) =>
    value is Map ? value.cast<String, Object?>() : const {};

String _text(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value is String) return value.trim();
  if (value is num) return value.toString();
  return '';
}

int _int(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim()) ?? 0;
  return 0;
}

double _number(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value.trim()) ?? 0;
  return 0;
}

int _episodeCountOf(Map<String, Object?> map) {
  final eps = _int(map['eps']);
  return eps > 0 ? eps : _int(map['total_episodes']);
}

double _ratingOf(Map<String, Object?> map) {
  final score = _number(_map(map['rating'])['score']);
  return score.isFinite && score > 0 ? score : 0;
}

/// 封面：`large` → `common` → `medium` → `grid`，取首个非空。
String _posterOf(Map<String, Object?> map) {
  final images = _map(map['images']);
  for (final key in const ['large', 'common', 'medium', 'grid']) {
    final value = _text(images, key);
    if (value.isNotEmpty) return value;
  }
  return '';
}

/// 与 `core/tmdb_title.dart` 的 `sourceSeasonPattern` 同源；这里只用来把
/// 命中的那段原文原样还原成标签（`第二季` / `Season 2` / `S2`）。
final RegExp _seasonLabelPattern = RegExp(
  '(第\\s*[零〇一二三四五六七八九十两0-9]+\\s*[季部]'
  '|season\\s*([0-9]{1,2})'
  '|s([0-9]{1,2})(?:[-._\\s]*e[0-9]{1,3})?)',
  caseSensitive: false,
);

/// 标题里的季号标签；解析不出季号时返回空串（不做猜测）。
String _seasonLabel(String title) {
  final number = sourceSeasonNumber(title);
  if (number <= 0) return '';
  final match = _seasonLabelPattern.firstMatch(title);
  if (match == null) return '第$number季';
  final chinese = match.group(1);
  if (chinese != null) return chinese.replaceAll(RegExp(r'\s+'), '');
  final english = match.group(2);
  if (english != null) return 'Season $english';
  return 'S$number';
}
