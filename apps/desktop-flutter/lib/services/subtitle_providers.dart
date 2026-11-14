/// 字幕源适配（`docs/phase9/design/02` §1）。
///
/// 两种 provider：
/// - **本地目录**：扫描用户配置的目录（深度 2），按文件名与标题的归一化包含关系
///   匹配；无需网络，失败只会「搜不到」；
/// - **HTTP 源**：`GET <endpoint>?q=<标题>&season=&episode=&token=`
///   期望返回 `{"code":0,"data":[{...}]}` 或裸数组，字段见 [HttpSubtitleProvider]。
///
/// 约束：
/// - 任何异常都收敛为空列表 + 日志，**不抛给播放器**；
/// - token 不进日志；
/// - 单次搜索有超时与结果上限，避免拖慢起播。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../core/subtitle_provider.dart';
import '../core/subtitle_settings.dart';
import 'log_service.dart';

/// 字幕源接口。
abstract class SubtitleProvider {
  String get id;

  String get name;

  Future<List<SubtitleCandidate>> search(
    SubtitleQuery query,
    SubtitleSettings settings,
  );
}

/// 本地字幕目录。
class LocalSubtitleProvider implements SubtitleProvider {
  const LocalSubtitleProvider({this.maxFiles = 500});

  @override
  String get id => 'local';

  @override
  String get name => '本地目录';

  /// 单次扫描的文件上限（防止用户把整个磁盘加进来）。
  final int maxFiles;

  static const Set<String> _extensions = {'srt', 'ass', 'ssa', 'vtt', 'sub'};

  @override
  Future<List<SubtitleCandidate>> search(
    SubtitleQuery query,
    SubtitleSettings settings,
  ) async {
    final target = normalizeSubtitleTitle(query.title);
    if (target.isEmpty) return const [];
    final results = <SubtitleCandidate>[];
    var scanned = 0;

    for (final rawDir in settings.localDirectories) {
      final dir = Directory(rawDir.trim());
      if (!await dir.exists()) continue;
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        if (scanned >= maxFiles) break;
        scanned += 1;
        final path = entity.path;
        final extension = path.split('.').last.toLowerCase();
        if (!_extensions.contains(extension)) continue;
        final stem = path.split(Platform.pathSeparator).last;
        final normalized = normalizeSubtitleTitle(stem);
        if (normalized.isEmpty) continue;
        if (!normalized.contains(target) && !target.contains(normalized)) {
          continue;
        }
        final language = _languageFromName(stem);
        results.add(
          SubtitleCandidate(
            providerId: id,
            assetId: path,
            title: stem,
            language: language,
            format: extension,
            url: path,
          ),
        );
        if (results.length >= 30) break;
      }
    }
    return results;
  }

  static String _languageFromName(String filename) {
    final lower = filename.toLowerCase();
    bool any(List<String> tokens) => tokens.any(lower.contains);
    if (any(['chs', 'zh-hans', 'zh_cn', '简体', '简中'])) return 'zh-Hans';
    if (any(['cht', 'zh-hant', 'zh_tw', '繁体', '繁中'])) return 'zh-Hant';
    if (any(['eng', 'english', '英文', '英语'])) return 'en';
    return '';
  }
}

/// 通用 HTTP 字幕源。
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
class HttpSubtitleProvider implements SubtitleProvider {
  HttpSubtitleProvider({http.Client? client, this.timeout = const Duration(seconds: 8)})
    : _client = client ?? http.Client();

  final http.Client _client;
  final Duration timeout;

  @override
  String get id => 'http';

  @override
  String get name => 'HTTP 字幕源';

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

/// 按设置构造 provider 列表；未配置的源不构造（不产生无意义请求）。
List<SubtitleProvider> buildSubtitleProviders(
  SubtitleSettings settings, {
  http.Client? client,
}) {
  final providers = <SubtitleProvider>[];
  if (settings.hasLocalProvider) providers.add(const LocalSubtitleProvider());
  if (settings.hasHttpProvider) {
    providers.add(HttpSubtitleProvider(client: client));
  }
  return providers;
}

/// 并行搜索并聚合；单个 provider 失败不影响其他。
Future<List<SubtitleCandidate>> searchSubtitleProviders({
  required List<SubtitleProvider> providers,
  required SubtitleQuery query,
  required SubtitleSettings settings,
  LogService? log,
  Duration timeout = const Duration(seconds: 8),
}) async {
  if (providers.isEmpty) return const [];
  final futures = [
    for (final provider in providers)
      provider
          .search(query, settings)
          .timeout(timeout, onTimeout: () => const <SubtitleCandidate>[])
          .catchError((Object error) {
            log?.warning(
              '字幕源搜索失败 provider=${provider.id} $error',
              scope: 'subtitle',
            );
            return const <SubtitleCandidate>[];
          }),
  ];
  final results = await Future.wait(futures);
  return [for (final list in results) ...list];
}
