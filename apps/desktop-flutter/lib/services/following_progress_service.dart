/// 播放历史 → 追番「已看集数」回写服务（Phase 9 · 已看口径修正）。
///
/// 安卓由 `FollowingPlaybackBridge.java` 在播放结束时直接写追番进度；PC 没有
/// 这条桥，改为**按历史反推**：把 `history` 里该剧看得最远的一集写回
/// `Following.watchedEpisode`。
///
/// 约束：
/// - 只增不减：历史被清理、换线路后已看不会倒退；
/// - 只读本地库，不联网；任何异常都不向上抛，只写日志。
library;

import '../core/following.dart';
import '../core/tmdb_title.dart';
import 'log_service.dart';
import 'storage.dart';

/// 「这一集算看完了」的进度阈值。
///
/// 未标 `completed` 但拖到接近片尾（≥95%）也算看完——播放器在退出、切集时
/// 可能来不及写 `completed`，只按标记判会漏掉大量真实看完的集。
const double followingWatchedProgressThreshold = 0.95;

/// 从一批播放历史反推「已看到的最大集号」（0 = 没有可用记录）。
///
/// 规则（顺序即优先级）：
/// 1. 线路：`flag` 精确匹配的行优先；一条都没命中时才看全部线路
///    （历史里的线路名与追番里存的可能不同，宁可用全集也不能没有进度）；
/// 2. 单集算已看：`completed` 为真，或进度 ≥ [threshold]；
/// 3. 集号由 [sourceEpisodeNumber] 解析 `episodeName`，解析失败（≤0）跳过；
/// 4. 取所有候选的**最大值**（不是最后一条，也不是记录条数）。
int watchedEpisodeFromHistory(
  List<PlaybackHistory> history, {
  String flag = '',
  double threshold = followingWatchedProgressThreshold,
}) {
  if (history.isEmpty) return 0;
  var rows = history;
  final target = flag.trim();
  if (target.isNotEmpty) {
    final sameLine = [
      for (final row in history)
        if (row.flag.trim() == target) row,
    ];
    if (sameLine.isNotEmpty) rows = sameLine;
  }
  var best = 0;
  for (final row in rows) {
    if (!row.completed && row.progress < threshold) continue;
    final number = sourceEpisodeNumber(row.episodeName);
    if (number <= 0) continue;
    if (number > best) best = number;
  }
  return best;
}

/// 一次回写的结果（只用于日志/测试断言）。
class FollowingProgressSyncResult {
  const FollowingProgressSyncResult({
    required this.scanned,
    required this.updated,
  });

  /// 扫过多少部追番。
  final int scanned;

  /// 有多少部的已看集数被推进。
  final int updated;

  static const FollowingProgressSyncResult empty = FollowingProgressSyncResult(
    scanned: 0,
    updated: 0,
  );
}

class FollowingProgressService {
  FollowingProgressService({
    required this.database,
    this.log,
    this.threshold = followingWatchedProgressThreshold,
  });

  final AppDatabase database;

  /// 失败日志（可为 null）。
  final LogService? log;

  final double threshold;

  /// 单条回写：反推集号大于现有已看才写（只增不减）。
  ///
  /// 没有变化时原样返回 [item]，不浪费一次 UPSERT；`updatedAt` 不动，
  /// 否则每次回写都会把列表顺序洗一遍。异常一律吞掉并返回 [item]。
  Following syncOne(Following item) {
    try {
      final watched = watchedEpisodeFromHistory(
        database.historyForVod(siteKey: item.siteKey, vodId: item.vodId),
        flag: item.flag,
        threshold: threshold,
      );
      if (watched <= 0 || watched <= item.watchedEpisode) return item;
      final next = item.copyWith(watchedEpisode: watched);
      database.upsertFollowing(next);
      return next;
    } catch (error) {
      log?.warning(
        '追番进度回写失败 ${item.vodName}（${item.siteKey}）：$error',
        scope: 'following',
      );
      return item;
    }
  }

  /// 单部剧回写（播放历史写入后触发）。
  ///
  /// 先按 `siteKey + vodId` 查这一条追番：不在追番里就直接返回（`scanned = 0`），
  /// 连历史表都不碰——播放时每 5 秒写一次进度，不能为此做全量扫描。
  FollowingProgressSyncResult syncVod({
    required String siteKey,
    required String vodId,
  }) {
    try {
      final item = database.followingByVod(siteKey, vodId);
      if (item == null) return FollowingProgressSyncResult.empty;
      final next = syncOne(item);
      return FollowingProgressSyncResult(
        scanned: 1,
        updated: identical(next, item) ? 0 : 1,
      );
    } catch (error) {
      log?.warning('追番进度回写失败 $siteKey/$vodId：$error', scope: 'following');
      return FollowingProgressSyncResult.empty;
    }
  }

  /// 全量回写（[items] 为空 = 库内全部追番）。整批失败只记日志、不抛。
  FollowingProgressSyncResult syncAll({List<Following>? items}) {
    var scanned = 0;
    var updated = 0;
    try {
      for (final item in items ?? database.followings()) {
        scanned += 1;
        final next = syncOne(item);
        if (!identical(next, item)) updated += 1;
      }
    } catch (error) {
      log?.warning('追番进度回写中断：$error', scope: 'following');
    }
    return FollowingProgressSyncResult(scanned: scanned, updated: updated);
  }
}
