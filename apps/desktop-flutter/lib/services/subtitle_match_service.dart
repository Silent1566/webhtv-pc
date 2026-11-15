/// 字幕匹配编排：候选聚合 → 打分排序 → 自动选择 / 手动报告 / 下载解析
/// （`docs/phase9/design/02` §1.3、`docs/superpowers/plans/2026-11-15-subtitle-online-search.md`）。
///
/// 只做「找 / 选 / 下」；装配与播放由播放器页负责。
/// 任何失败都返回 null / 空列表，不抛出。
library;

import 'dart:async';

import '../core/subtitle_provider.dart';
import '../core/subtitle_settings.dart';
import 'log_service.dart';
import 'subtitle_providers.dart';

/// 手动搜索的完整结果：候选 + 失败原因 + 未启用的源。
///
/// 为什么不是 `List<SubtitleCandidate>` 就够：不变量 4 要求空态说真话——
/// 「全都没配置」「配了但网络失败」「真的没结果」是三种不同的话。
class SubtitleSearchReport {
  const SubtitleSearchReport({
    this.candidates = const [],
    this.failures = const {},
    this.unavailable = const [],
  });

  /// 已按分数/源优先级排序。
  final List<SubtitleCandidate> candidates;

  /// providerId → 原因（超时 / HTTP 码 / 需要本地文件）。已脱敏。
  final Map<String, String> failures;

  /// 未配置/未启用的源 id（`SubtitleSettings.disabledSourceIds`）。
  final List<String> unavailable;

  bool get isEmpty => candidates.isEmpty;
}

class SubtitleMatchService {
  SubtitleMatchService({
    this.log,
    this.providers,
    this.timeout = const Duration(seconds: 8),
    this.cacheDir = '',
  });

  final LogService? log;

  /// 测试注入用；为 null 时按设置装配。
  final List<SubtitleProvider>? providers;

  /// 单次搜索/下载的超时。自动匹配用 8s（不拖慢起播），手动搜索用 15s。
  final Duration timeout;

  /// 字幕缓存根目录；为空时 `resolve()` 无法落盘（测试可注入临时目录）。
  final String cacheDir;

  List<SubtitleProvider> _resolvedProviders(SubtitleSettings settings) =>
      providers ??
      buildSubtitleProviders(settings, cacheDir: cacheDir);

  Map<String, int> _priorities(List<SubtitleProvider> list) => {
    for (final provider in list) provider.id: provider.priority,
  };

  /// 手动搜索：返回完整报告（候选 + 失败 + 未启用）。
  Future<SubtitleSearchReport> searchReport({
    required SubtitleQuery query,
    required SubtitleSettings settings,
  }) async {
    final resolved = _resolvedProviders(settings);
    final unavailable = settings.disabledSourceIds;
    if (resolved.isEmpty) {
      return SubtitleSearchReport(unavailable: unavailable);
    }
    final outcome = await searchSubtitleProvidersReport(
      providers: resolved,
      query: query,
      settings: settings,
      log: log,
      timeout: timeout,
    );
    return SubtitleSearchReport(
      candidates: rankSubtitleCandidates(
        candidates: outcome.candidates,
        query: query,
        preferredLanguages: settings.preferredLanguages,
        providerPriorities: _priorities(resolved),
      ),
      failures: outcome.failures,
      unavailable: unavailable,
    );
  }

  /// 手动搜索（旧签名）：只要候选列表。
  Future<List<SubtitleCandidate>> search({
    required SubtitleQuery query,
    required SubtitleSettings settings,
  }) async => (await searchReport(query: query, settings: settings)).candidates;

  /// 自动匹配：达到阈值才返回；否则返回 null（交给用户手选）。
  Future<SubtitleCandidate?> autoMatch({
    required SubtitleQuery query,
    required SubtitleSettings settings,
  }) async {
    final report = await searchReport(query: query, settings: settings);
    final ranked = report.candidates;
    if (ranked.isEmpty) return null;
    final best = ranked.first;
    log?.info(
      '字幕自动匹配 provider=${best.providerId} score=${best.score.toStringAsFixed(2)} '
      'title=${best.title} lang=${best.language}',
      scope: 'subtitle',
    );
    return best.score >= kSubtitleAutoPickThreshold ? best : null;
  }

  /// 把候选落成可播放的本地文件；不需要 resolve 的源返回 null（调用方用原 URL）。
  ///
  /// 失败只记一行日志并返回 null，由调用方提示，不影响播放。
  Future<SubtitleResolvedAsset?> resolve(
    SubtitleCandidate candidate, {
    required SubtitleQuery query,
    required SubtitleSettings settings,
  }) async {
    if (!candidate.requiresResolve) return null;
    final resolved = _resolvedProviders(settings);
    SubtitleProvider? provider;
    for (final item in resolved) {
      if (item.id == candidate.providerId) {
        provider = item;
        break;
      }
    }
    if (provider == null) return null;
    try {
      final asset = await provider
          .resolve(candidate, query, settings)
          .timeout(timeout, onTimeout: () => null);
      if (asset == null) {
        log?.warning(
          '字幕解析无结果 provider=${provider.id} title=${candidate.title}',
          scope: 'subtitle',
        );
      }
      return asset;
    } catch (error) {
      log?.warning(
        '字幕解析失败 provider=${provider.id} ${sanitizeSubtitleReason(error)}',
        scope: 'subtitle',
      );
      return null;
    }
  }
}
