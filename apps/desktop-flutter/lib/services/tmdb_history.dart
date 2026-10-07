/// 季度历史卡片投影（`docs/phase4/design/02` §7.1）。
///
/// 历史页需要把季度进度按「每季一张卡片」展示，而不是按来源记录平铺：
/// - 同一 TMDB 节目的不同季度生成**多张**卡片；
/// - 同一季度的多个来源合并为**一张**卡片；
/// - 未确认季度不生成季度卡片（按来源记录保持独立，`02` §7.1）。
///
/// 放在独立文件是为了让 UI 与测试都能引用，而不必依赖 settings 存储。
library;

import '../core/tmdb_identity.dart';
import 'tmdb_season_service.dart';

/// 季度历史卡片。
class SeasonHistoryCard {
  const SeasonHistoryCard({
    required this.mediaType,
    required this.tmdbId,
    required this.seasonNumber,
    required this.episodeNumber,
    required this.positionMs,
    required this.durationMs,
    required this.updatedAt,
    required this.sources,
  });

  final String mediaType;
  final int tmdbId;
  final int seasonNumber;
  final int episodeNumber;
  final int positionMs;
  final int durationMs;
  final int updatedAt;

  /// 该季度的全部来源（至少 1 个），按 `updatedAt` 降序。
  final List<TmdbSeasonProgressRecord> sources;

  /// 展示代表（`updatedAt` 最新）。
  TmdbSeasonProgressRecord get representative => sources.first;

  TmdbIdentity? get identity => TmdbIdentity.parse('$mediaType:$tmdbId');

  /// 历史展示键（`02` §7.1）：`mediaType:tmdbId:season:N`。
  String get displayKey => '$mediaType:$tmdbId:season:$seasonNumber';

  String get seasonLabel => seasonNumber == 0 ? '特别篇' : '第 $seasonNumber 季';

  int get progressPercent {
    if (durationMs <= 0) return 0;
    final ratio = positionMs / durationMs;
    return (ratio.clamp(0.0, 1.0) * 100).round();
  }

  bool get completed =>
      durationMs > 0 && positionMs >= durationMs - 5000;
}

/// 按 `(mediaType, tmdbId, seasonNumber)` 分组投影季度历史卡片。
///
/// 输出按卡片 `updatedAt` 降序（最近观看在前）。
List<SeasonHistoryCard> projectSeasonHistory(
  List<TmdbSeasonProgressRecord> records,
) {
  final grouped = <String, List<TmdbSeasonProgressRecord>>{};
  for (final record in records) {
    // `episodeNumber <= 0` 的记录不参与投影（`02` §7.2 第 1 条）。
    if (record.episodeNumber <= 0) continue;
    final key = '${record.mediaType}:${record.tmdbId}:${record.seasonNumber}';
    (grouped[key] ??= []).add(record);
  }
  final cards = <SeasonHistoryCard>[];
  for (final entry in grouped.entries) {
    final sources = entry.value.toList()
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final head = sources.first;
    cards.add(
      SeasonHistoryCard(
        mediaType: head.mediaType,
        tmdbId: head.tmdbId,
        seasonNumber: head.seasonNumber,
        episodeNumber: head.episodeNumber,
        positionMs: head.positionMs,
        durationMs: head.durationMs,
        updatedAt: head.updatedAt,
        sources: sources,
      ),
    );
  }
  cards.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  return cards;
}
