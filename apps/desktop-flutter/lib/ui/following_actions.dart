/// 追剧页两个视角共用的动作：播放最新集 / 从日历条目起播 / 打开详情。
///
/// 合并前列表页与日历页各有一份实现（`_playLatest`/`_playEntry`、两份 `_openDetail`），
/// 差异只在「标读 / 标已看 / 进度回写」这几个副作用上；差异用显式参数表达，
/// 逻辑只留一份，避免两处越改越远。
library;

import 'package:flutter/material.dart';

import '../core/app_error.dart';
import '../core/following.dart';
import '../core/following_calendar.dart';
import '../core/protocol.dart';
import '../services/storage.dart';
import '../state/app_state.dart';
import 'async_action_feedback.dart';
import 'browse_pages.dart';
import 'playback_resume.dart';
import 'toast.dart';

/// 一部追剧要播放的「最新一集」：站点线路名优先用 sourceFlag。
PlaybackHistory followingPlaybackHistory(Following item) => PlaybackHistory(
  id: 0,
  siteKey: item.siteKey,
  vodId: item.vodId,
  vodName: item.vodName,
  vodPic: item.vodPic,
  flag: item.sourceFlag.isEmpty ? item.flag : item.sourceFlag,
  episodeName: item.latestEpisodeName,
  episodeId: item.latestEpisodeTarget,
  positionMs: 0,
  durationMs: 0,
  updatedAt: item.updatedAtMs,
);

/// 列表卡的「播放最新集」：先标读（清徽标）再起播，起播后回写已看进度。
///
/// 没有最新集入口或原站点已缺失时退回详情页；旧地址不能当作有效播放源。
Future<void> playFollowingLatest(
  BuildContext context,
  AppState state,
  Following item,
) async {
  if (item.latestEpisodeTarget.isEmpty ||
      state.siteInActiveSource(item.siteKey) == null) {
    await openFollowingDetail(
      context,
      state,
      item,
      markRead: true,
      syncProgress: true,
    );
    return;
  }
  final feedback = AsyncActionFeedback.begin(context, '正在准备播放：${item.vodName}');
  if (feedback == null) return;
  try {
    await state.markFollowingRead(item);
    if (!context.mounted || !feedback.isCurrent) return;
    await resumeHistoryEntry(
      context,
      state,
      followingPlaybackHistory(item),
      feedback: feedback,
    );
    if (!context.mounted || !feedback.isCurrent) return;
    // 起播成功后回写「已看到第几集」（只增不减，不联网不抛）。
    state.syncFollowingProgress(items: [item]);
  } catch (error) {
    if (context.mounted && feedback.isCurrent) {
      feedback.dismiss();
      showToast(
        error is AppError ? error.userMessage : '$error',
        kind: ToastKind.error,
      );
    }
  } finally {
    feedback.close();
  }
}

/// 日历条目起播：只有「最新一集」能直接起播，其余提示去详情页选集。
///
/// 与 [playFollowingLatest] 的差别是**不改已读水位、不把进度当成已看**：
/// 用户可能是回头补看某一集。
Future<void> playFollowingEntry(
  BuildContext context,
  AppState state,
  Following item,
  CalendarEntry entry,
) async {
  final isLatest = entry.episode >= 1 && entry.episode == item.releasedEpisode;
  if (!isLatest ||
      item.latestEpisodeTarget.isEmpty ||
      state.siteInActiveSource(item.siteKey) == null) {
    if (entry.episode >= 1 && !isLatest) {
      showToast('${entry.code} 不是最新一集，请在详情页选集播放', kind: ToastKind.info);
    }
    await openFollowingDetail(context, state, item);
    return;
  }
  final feedback = AsyncActionFeedback.begin(context, '正在准备播放：${item.vodName}');
  if (feedback == null) return;
  try {
    await resumeHistoryEntry(
      context,
      state,
      followingPlaybackHistory(item),
      feedback: feedback,
    );
    if (!context.mounted || !feedback.isCurrent) return;
    await state.markFollowingWatched(item);
  } finally {
    feedback.close();
  }
}

/// 打开详情页：先换到条目所属站点，再 push。
///
/// [markRead] / [syncProgress] 是列表卡（通知入口）独有的副作用：从列表进详情时
/// 立即标读，返回后回写已看；日历条目不做这两件事。
Future<void> openFollowingDetail(
  BuildContext context,
  AppState state,
  Following item, {
  bool markRead = false,
  bool syncProgress = false,
}) async {
  if (!context.mounted || ModalRoute.of(context)?.isCurrent == false) return;
  // 追剧行同样只存 site_key：本地爬虫源在 effectiveConfig 里，查 state.config 会落空。
  final site = state.siteInActiveSource(item.siteKey);
  final feedback = AsyncActionFeedback.begin(context, '正在打开详情：${item.vodName}');
  if (feedback == null) return;
  try {
    if (markRead) await state.markFollowingRead(item);
    if (!context.mounted || !feedback.isCurrent) return;
    if (site != null) await state.selectSite(site);
    if (!context.mounted || !feedback.isCurrent) return;
    feedback.dismiss();
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DetailPage(
          state: state,
          vod: Vod(
            vodId: site == null ? '' : item.vodId,
            vodName: item.vodName,
            vodPic: item.vodPic,
          ),
          historyFlag: item.flag,
        ),
      ),
    );
    if (!context.mounted || !feedback.isCurrent) return;
    if (syncProgress) state.syncFollowingProgress(items: [item]);
  } catch (error) {
    if (context.mounted && feedback.isCurrent) {
      feedback.dismiss();
      showToast(
        error is AppError ? error.userMessage : '$error',
        kind: ToastKind.error,
      );
    }
  } finally {
    feedback.close();
  }
}
