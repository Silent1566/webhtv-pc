/// OMDb 评分查询（对齐安卓 `service/OmdbService.java`）。
///
/// 只做一件事：拿 `imdb_id` + API Key 换 OMDb 的评分 JSON。**没有 Key 就一次都
/// 不请求**——PC 端历史上刻意不请求 OMDb（`docs/phase4/design/03` §5.1），现在
/// 由用户在 TMDB 设置页显式填 Key 打开，因此「没有 Key」是常态而不是错误。
///
/// 与安卓一致的边界：
/// - 空 base / 空 imdbId / 空 key 一律返回空（不构造 URL，不发请求）；
/// - 非 2xx、非 JSON 对象、超过 [maxBytes] 的响应体都当失败，返回空；
/// - 失败**不抛异常**：评分是增强信息，不能把详情页打成错误页。
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'log_service.dart';

class OmdbService {
  OmdbService({
    http.Client? client,
    this.baseUrl = defaultBaseUrl,
    this.timeout = const Duration(seconds: 8),
    LogService? log,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       // 具名参数 `log` 不能作为初始化形参绑定到私有字段。
       // ignore: prefer_initializing_formals
       _log = log;

  static const String defaultBaseUrl = 'https://www.omdbapi.com/';

  /// 响应体上限：评分 JSON 只有几百字节，超过这条线的都是错误页或网关页面。
  static const int maxBytes = 256 * 1024;

  final String baseUrl;
  final Duration timeout;
  final http.Client _client;
  final bool _ownsClient;
  final LogService? _log;

  /// 查询一次。返回空 Map 表示「没拿到」（未配置、网络失败、无此条目）。
  Future<Map<String, Object?>> fetch({
    required String imdbId,
    required String apiKey,
  }) async {
    final id = imdbId.trim();
    final key = apiKey.trim();
    if (id.isEmpty || key.isEmpty || baseUrl.trim().isEmpty) {
      return const {};
    }
    final uri = Uri.tryParse(baseUrl.trim());
    if (uri == null) return const {};
    final url = uri.replace(
      queryParameters: {...uri.queryParameters, 'i': id, 'apikey': key},
    );
    try {
      final response = await _client.get(url).timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        _log?.warning('OMDb 返回 HTTP ${response.statusCode}', scope: 'tmdb');
        return const {};
      }
      if (response.bodyBytes.length > maxBytes) return const {};
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map) return const {};
      return decoded.cast<String, Object?>();
    } catch (error) {
      // 失败只记日志：错误集中在详情页的一次性增强里，不弹窗、不重试。
      _log?.warning('OMDb 请求失败：$error', scope: 'tmdb');
      return const {};
    }
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}
