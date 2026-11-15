/// 按设置装配 provider 列表，并并行搜索（单源失败不影响其他）。
library;

import 'dart:async';

import 'package:http/http.dart' as http;

import '../../core/subtitle_provider.dart';
import '../../core/subtitle_settings.dart';
import '../log_service.dart';
import 'assrt_provider.dart';
import 'http_provider.dart';
import 'local_provider.dart';
import 'provider.dart';
import 'shooter_provider.dart';
import 'xunlei_provider.dart';

/// 一次并行搜索的结果：候选 + 每个失败源的可读原因。
class SubtitleSearchOutcome {
  const SubtitleSearchOutcome({
    this.candidates = const [],
    this.failures = const {},
  });

  final List<SubtitleCandidate> candidates;

  /// providerId → 原因（超时 / HTTP 码 / 需要本地文件）。**已脱敏**，不含 token。
  final Map<String, String> failures;
}

/// 按设置构造 provider 列表；未配置的源不构造（不产生无意义请求）。
List<SubtitleProvider> buildSubtitleProviders(
  SubtitleSettings settings, {
  http.Client? client,
  String cacheDir = '',
}) {
  final providers = <SubtitleProvider>[];
  if (settings.hasLocalProvider) providers.add(const LocalSubtitleProvider());
  if (settings.hasHttpProvider) {
    providers.add(HttpSubtitleProvider(client: client));
  }
  final assrt = buildAssrtProvider(
    settings: settings,
    client: client,
    cacheDir: cacheDir,
  );
  if (assrt != null) providers.add(assrt);
  final xunlei = buildXunleiProvider(
    settings: settings,
    client: client,
    cacheDir: cacheDir,
  );
  if (xunlei != null) providers.add(xunlei);
  final shooter = buildShooterProvider(
    settings: settings,
    client: client,
    cacheDir: cacheDir,
  );
  if (shooter != null) providers.add(shooter);
  return providers;
}

/// 并行搜索并聚合；单个 provider 失败不影响其他。
Future<SubtitleSearchOutcome> searchSubtitleProvidersReport({
  required List<SubtitleProvider> providers,
  required SubtitleQuery query,
  required SubtitleSettings settings,
  LogService? log,
  Duration timeout = const Duration(seconds: 15),
}) async {
  if (providers.isEmpty) return const SubtitleSearchOutcome();
  final failures = <String, String>{};
  final futures = <Future<List<SubtitleCandidate>>>[];
  for (final provider in providers) {
    if (provider.needsLocalMediaPath && (query.mediaPath ?? '').trim().isEmpty) {
      // 不是错误，是没有输入：UI 要能把它和「网络失败」区分开。
      failures[provider.id] = '需要本地视频文件';
      continue;
    }
    futures.add(
      provider
          .search(query, settings)
          .timeout(timeout, onTimeout: () {
            failures[provider.id] = '超时';
            log?.warning(
              '字幕源搜索超时 provider=${provider.id}',
              scope: 'subtitle',
            );
            return const <SubtitleCandidate>[];
          })
          .catchError((Object error) {
            final reason = sanitizeSubtitleReason(error);
            failures[provider.id] = reason;
            log?.warning(
              '字幕源搜索失败 provider=${provider.id} reason=$reason',
              scope: 'subtitle',
            );
            return const <SubtitleCandidate>[];
          }),
    );
  }
  final results = await Future.wait(futures);
  return SubtitleSearchOutcome(
    candidates: [for (final list in results) ...list],
    failures: failures,
  );
}

/// 旧签名（Phase 9 调用面）：只要候选，不关心失败原因。
Future<List<SubtitleCandidate>> searchSubtitleProviders({
  required List<SubtitleProvider> providers,
  required SubtitleQuery query,
  required SubtitleSettings settings,
  LogService? log,
  Duration timeout = const Duration(seconds: 15),
}) async {
  final outcome = await searchSubtitleProvidersReport(
    providers: providers,
    query: query,
    settings: settings,
    log: log,
    timeout: timeout,
  );
  return outcome.candidates;
}

/// 失败原因要进日志与 UI：ASSRT 把 token 放在 query 里，异常文本可能带上它。
String sanitizeSubtitleReason(Object error) {
  var text = error.toString();
  text = text.replaceAll(
    RegExp(r'token=[^&\s]*', caseSensitive: false),
    'token=***',
  );
  if (text.length > 200) text = '${text.substring(0, 200)}…';
  return text;
}
