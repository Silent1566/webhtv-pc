/// 弹幕库搜索客户端（`docs/phase9/design/02` §2.3）。
///
/// 协议（与字幕源同构，便于用户自建）：
/// `GET <apiUrl>?title=<片名>&episode=<集名>`
/// 响应：`{"code":0,"data":[{"id","title","episode","url","count"}]}` 或裸数组。
///
/// 约束：非 2xx / 非法 JSON / 超时一律返回空列表；单次最多 30 条。
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/danmaku_match.dart';

class DanmakuLibraryService {
  DanmakuLibraryService({
    http.Client? client,
    this.timeout = const Duration(seconds: 6),
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final Duration timeout;

  /// 搜索弹幕库；[apiUrl] 为空时零请求。
  Future<List<DanmakuLibraryEntry>> search({
    required String apiUrl,
    required String title,
    String? episode,
  }) async {
    final endpoint = apiUrl.trim();
    if (endpoint.isEmpty) return const [];
    final uri = Uri.tryParse(endpoint);
    if (uri == null || !uri.hasScheme) return const [];
    final target = uri.replace(
      queryParameters: {
        ...uri.queryParameters,
        'title': title,
        if (episode != null && episode.trim().isNotEmpty)
          'episode': episode.trim(),
      },
    );
    try {
      final response = await _client
          .get(target, headers: const {'Accept': 'application/json'})
          .timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return const [];
      }
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      final list = switch (decoded) {
        List value => value,
        Map value when value['data'] is List => value['data'] as List,
        _ => const [],
      };
      final entries = <DanmakuLibraryEntry>[];
      for (final raw in list) {
        if (raw is! Map) continue;
        final url = (raw['url'] ?? '').toString().trim();
        if (url.isEmpty) continue;
        entries.add(
          DanmakuLibraryEntry(
            providerId: (raw['provider'] ?? 'default').toString(),
            id: (raw['id'] ?? url).toString(),
            title: (raw['title'] ?? title).toString(),
            episode: (raw['episode'] ?? '').toString(),
            url: url,
            count: _intOf(raw['count']) ?? 0,
          ),
        );
        if (entries.length >= 30) break;
      }
      return entries;
    } catch (_) {
      return const [];
    }
  }

  void close() => _client.close();

  static int? _intOf(Object? raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw.trim());
    return null;
  }
}
