/// 通用 HTTP 字幕源：用户自己给的搜索端点，响应约定见类注释。
///
/// 请求：`GET {endpoint}?q={标题}&season={季}&episode={集}`；
/// 若配置了 token，追加 `&token=...`（**不写日志**）。
///
/// 响应（二选一）：
/// ```json
/// {"code":0,"data":[{"id":"1","title":"剧名","language":"zh-Hans",
///   "format":"srt","url":"https://.../a.srt","season":1,"episode":2}]}
/// ```
/// 或直接返回数组。缺少 `url` 的条目丢弃；单次最多取 30 条。
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/subtitle_provider.dart';
import '../../core/subtitle_settings.dart';
import 'provider.dart';

class HttpSubtitleProvider extends SubtitleProvider {
  HttpSubtitleProvider({http.Client? client, this.timeout = const Duration(seconds: 8)})
    : _client = client ?? http.Client();

  final http.Client _client;
  final Duration timeout;

  @override
  String get id => 'http';

  @override
  String get name => 'HTTP 字幕源';

  @override
  int get priority => 5;

  @override
  Future<List<SubtitleCandidate>> search(
    SubtitleQuery query,
    SubtitleSettings settings,
  ) async {
    final endpoint = settings.httpEndpoint.trim();
    if (endpoint.isEmpty) return const [];
    final uri = Uri.tryParse(endpoint);
    if (uri == null || !uri.hasScheme) return const [];

    final params = <String, String>{
      'q': query.title,
      if (query.season != null) 'season': '${query.season}',
      if (query.episode != null) 'episode': '${query.episode}',
      if (settings.httpToken.trim().isNotEmpty) 'token': settings.httpToken.trim(),
    };
    final target = uri.replace(
      queryParameters: {...uri.queryParameters, ...params},
    );

    try {
      final response = await _client
          .get(target, headers: const {'Accept': 'application/json'})
          .timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) return const [];
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      final list = switch (decoded) {
        List value => value,
        Map value when value['data'] is List => value['data'] as List,
        _ => const [],
      };
      final results = <SubtitleCandidate>[];
      for (final raw in list) {
        if (raw is! Map) continue;
        final url = (raw['url'] ?? raw['downloadUrl'] ?? '').toString().trim();
        if (url.isEmpty) continue;
        final title = (raw['title'] ?? raw['name'] ?? '').toString().trim();
        final language = (raw['language'] ?? raw['lang'] ?? '').toString().trim();
        final format = (raw['format'] ?? '').toString().trim();
        results.add(
          SubtitleCandidate(
            providerId: id,
            assetId: (raw['id'] ?? url).toString(),
            title: title.isEmpty ? query.title : title,
            language: language,
            format: format,
            url: url,
            season: _intOf(raw['season']),
            episode: _intOf(raw['episode']),
          ),
        );
        if (results.length >= 30) break;
      }
      return results;
    } catch (_) {
      // 网络/解析/超时都按「没有结果」处理；调用方只提示一次。
      return const [];
    }
  }

  static int? _intOf(Object? raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw.trim());
    return null;
  }
}
