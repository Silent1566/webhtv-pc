/// 从历史条目恢复播放（深模块：一处实现，多处调用）。
///
/// 调用点：
/// - `HistoryPage` 的点击分流（`play` 模式）；
/// - 崩溃恢复横幅的「继续上次播放」（P2-8）。
///
/// 语义约束（来自 `docs/phase6/design/01` §4、§15.2）：
/// - 历史只存剧集入口与站点 key，恢复时必须**重新解析**播放决策，
///   不能把可能过期的直链直接交给播放器；
/// - 必须先切到该条记录所属站点，否则详情/解析会串站；
/// - 站点已不在当前配置中时给出可读提示，不静默失败。
library;

import 'package:flutter/material.dart';

import '../core/app_error.dart';
import '../services/proxy_server.dart';
import '../services/storage.dart';
import '../state/app_state.dart';
import 'async_action_feedback.dart';
import 'player_page.dart';
import 'toast.dart';

Future<void> resumeHistoryEntry(
  BuildContext context,
  AppState state,
  PlaybackHistory item, {
  AsyncActionFeedback? feedback,
}) async {
  if (!context.mounted || ModalRoute.of(context)?.isCurrent == false) return;
  final episodeTarget = restoreHistoryPlaybackTarget(item.episodeId);
  final config = state.config;
  final site = config?.sites
      .where((candidate) => candidate.key == item.siteKey)
      .firstOrNull;
  if (site == null) {
    showToast('该记录所属站点已不在当前配置中：${item.siteKey}', kind: ToastKind.error);
    return;
  }
  final action =
      feedback ?? AsyncActionFeedback.begin(context, '正在准备播放：${item.vodName}');
  if (action == null || !action.isCurrent) return;
  try {
    await state.selectSite(site);
    if (!context.mounted || !action.isCurrent) return;
    final decision = await state.resolvePlayback(
      episodeTarget: episodeTarget,
      flag: item.flag,
      vodId: item.vodId,
    );
    if (decision == null || decision.url == null) {
      throw AppError(
        AppErrorKind.playbackUrlMissing,
        '历史记录没有可用播放地址',
        detail: episodeTarget,
      );
    }
    if (!context.mounted || !action.isCurrent) return;
    action.dismiss();
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlayerPage(
          state: state,
          request: PlaybackRequest(
            url: decision.url!,
            qualities: decision.qualities,
            qualityIndex: decision.qualityIndex,
            // 续播同样带解析选项（原来源续播用的是那份配置的解析器）。
            parseSources: decision.parseSources,
            parseSource: decision.parseSource,
            // 续播后再次写进度时必须保留**同一个入口目标**，否则这一条历史会
            // 被刚解析出的可播地址覆盖，下一次续播又失败。
            episodeTarget: episodeTarget,
            headers: decision.headers?.asRequestHeaders ?? const {},
            title: item.vodName,
            siteKey: item.siteKey,
            vodId: item.vodId,
            vodName: item.vodName,
            episodeName: item.episodeName,
            flag: item.flag,
            startPosition: Duration(milliseconds: item.positionMs),
            vodPic: item.vodPic,
            // 外挂字幕（§10.3）/弹幕（§21 Phase 3）：历史恢复同样带入。
            subtitles: decision.subs,
            danmaku: decision.danmaku,
            subtitleHeaders:
                decision.assetHeaders?.asRequestHeaders ?? const {},
          ),
        ),
      ),
    );
  } catch (error) {
    final failure = error is AppError
        ? error
        : AppError(AppErrorKind.unknown, '$error', cause: error);
    if (!context.mounted || !action.isCurrent) return;
    action.dismiss();
    showToast(failure.userMessage, kind: ToastKind.error);
  } finally {
    if (feedback == null) action.close();
  }
}
