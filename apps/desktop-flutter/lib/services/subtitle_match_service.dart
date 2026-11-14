/// 字幕匹配编排：候选聚合 → 打分排序 → 自动选择（`docs/phase9/design/02` §1.3）。
///
/// 只做「找与选」；下载/装配由播放器控制器负责（它已能处理编码与临时文件）。
/// 任何失败都返回 null / 空列表，不抛出。
library;

import '../core/subtitle_provider.dart';
import '../core/subtitle_settings.dart';
import 'log_service.dart';
import 'subtitle_providers.dart';

class SubtitleMatchService {
  SubtitleMatchService({
    this.log,
    this.providers,
    this.timeout = const Duration(seconds: 8),
  });

  final LogService? log;
  final List<SubtitleProvider>? providers;
  final Duration timeout;

  /// 手动搜索：返回打分后的候选（可能为空）。
  Future<List<SubtitleCandidate>> search({
    required SubtitleQuery query,
    required SubtitleSettings settings,
  }) async {
    final resolvedProviders =
        providers ?? buildSubtitleProviders(settings);
    if (resolvedProviders.isEmpty) return const [];
    final raw = await searchSubtitleProviders(
      providers: resolvedProviders,
      query: query,
      settings: settings,
      log: log,
      timeout: timeout,
    );
    return rankSubtitleCandidates(
      candidates: raw,
      query: query,
      preferredLanguages: settings.preferredLanguages,
    );
  }

  /// 自动匹配：达到阈值才返回；否则返回 null（交给用户手选）。
  Future<SubtitleCandidate?> autoMatch({
    required SubtitleQuery query,
    required SubtitleSettings settings,
  }) async {
    final ranked = await search(query: query, settings: settings);
    if (ranked.isEmpty) return null;
    final best = ranked.first;
    log?.info(
      '字幕自动匹配 provider=${best.providerId} score=${best.score.toStringAsFixed(2)} '
      'title=${best.title} lang=${best.language}',
      scope: 'subtitle',
    );
    return best.score >= kSubtitleAutoPickThreshold ? best : null;
  }
}
