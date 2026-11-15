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

import 'dart:async';

import 'package:flutter/material.dart';

import '../core/app_error.dart';
import '../core/history_view.dart';
import '../core/playback_lines.dart';
import '../core/protocol.dart';
import '../core/source_swap.dart';
import '../services/proxy_server.dart';
import '../services/storage.dart';
import '../state/app_state.dart';
import 'async_action_feedback.dart';
import 'player_page.dart';
import 'toast.dart';

/// 目录记录起播前预取线路的最长等待。
///
/// 目录展开要 `t=<folder_id>` 分类 + 逐条目详情，实测 2~15s。等太久等于把
/// 「点一下历史」变成盯着转圈；超过上限就照旧起播，交给播放器侧继续补——
/// 选集按钮晚到总比播放被拖住好。
const Duration folderLinesPrefetchTimeout = Duration(seconds: 8);

/// 起播前取好的目录线路，字段直接对应 [PlaybackRequest] 的线路部分。
class FolderPlayLines {
  const FolderPlayLines({
    required this.lines,
    required this.routes,
    required this.flag,
    required this.playbackFlag,
    required this.episodeIndex,
  });

  final List<VodPlayLine> lines;
  final Map<String, SwapLineRoute> routes;
  final String flag;
  final String playbackFlag;
  final int episodeIndex;
}

/// 目录记录（`atvp_detail:`）在进播放器前把线路取好。
///
/// 为什么必须在起播前取：起播后再补的这段时间里，用户看到的是一个**没有选集
/// 按钮**的播放器（详情页有「选集（35）」，历史直接播放没有）。
///
/// 超时/失败/未命中一律返回 `null`（=「不要硬塞」）：线路只是附加入口，既不得
/// 阻断播放，也不弹错误 toast。返回非空时保证 [FolderPlayLines.flag] 指向的线路
/// 确实存在且 `episodes` 非空——那正是播放器渲染按钮的条件。
Future<FolderPlayLines?> prefetchFolderPlayLines(
  AppState state,
  PlaybackHistory item, {
  required String sourceKey,
  Duration timeout = folderLinesPrefetchTimeout,
  bool Function()? isCurrent,
}) async {
  if (!isBridgeFolderVodId(item.vodId)) return null;
  final started = DateTime.now();
  PlaybackLines? fetched;
  try {
    fetched = await state
        .playLinesForRecord(
          siteKey: item.siteKey,
          vodId: item.vodId,
          vodName: item.vodName,
          sourceKey: sourceKey,
          isCurrent: isCurrent,
        )
        .timeout(timeout);
  } on TimeoutException {
    state.log.debug(
      '目录记录预取线路超时 vod="${item.vodId}" '
      'timeout=${timeout.inMilliseconds}ms',
      scope: 'player',
    );
    return null;
  } catch (error) {
    // 异常文本可能带完整站点 URL/Header，只记分类。
    state.log.debug(
      '目录记录预取线路失败 vod="${item.vodId}" '
      'kind=${error is AppError ? error.kind.name : error.runtimeType}',
      scope: 'player',
    );
    return null;
  }
  final elapsed = DateTime.now().difference(started).inMilliseconds;
  final lines = fetched?.lines ?? const <VodPlayLine>[];
  state.log.debug(
    '目录记录预取线路取回 vod="${item.vodId}" lines=${lines.length} '
    'routes=${fetched?.routes.length ?? 0} elapsed=${elapsed}ms',
    scope: 'player',
  );
  if (lines.isEmpty) {
    state.log.debug(
      '目录记录预取线路为空 vod="${item.vodId}"，改由播放器补齐',
      scope: 'player',
    );
    return null;
  }
  final target = resolveHistoryTarget(
    historyFlag: item.flag,
    historyEpisodeId: restoreHistoryPlaybackTarget(item.episodeId),
    historyEpisodeName: item.episodeName,
    lines: lines,
  );
  if (!target.matched) {
    // 歧义就不猜：没完整命中当前集时不硬塞线路，让播放器侧照旧补并留下原因。
    state.log.debug(
      '目录记录预取线路未命中当前集 vod="${item.vodId}" '
      'flag="${item.flag}" episode="${item.episodeName}" lines=${lines.length}',
      scope: 'player',
    );
    return null;
  }
  final line = lines
      .where((candidate) => candidate.flag == target.flag)
      .firstOrNull;
  if (line == null || line.episodes.isEmpty) {
    // 采纳前先自检：`flag` 指不到带分集的线路时，播放器照样不会出现按钮。
    state.log.debug(
      '目录记录预取线路取不到分集 vod="${item.vodId}" '
      'flag="${target.flag}" lines=${lines.length}',
      scope: 'player',
    );
    return null;
  }
  state.log.debug(
    '目录记录预取线路命中 vod="${item.vodId}" lines=${lines.length} '
    'flag="${target.flag}" episodeIndex=${target.episodeIndex} '
    'episodes=${line.episodes.length} elapsed=${elapsed}ms',
    scope: 'player',
  );
  return FolderPlayLines(
    lines: lines,
    routes: fetched!.routes,
    flag: target.flag,
    playbackFlag: line.playbackFlag,
    episodeIndex: target.episodeIndex,
  );
}

Future<void> resumeHistoryEntry(
  BuildContext context,
  AppState state,
  PlaybackHistory item, {
  AsyncActionFeedback? feedback,
  Duration linesTimeout = folderLinesPrefetchTimeout,
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
    // 目录记录与解析**并行**取线路：两者互不依赖，串行只会把等待相加。
    // 预取自带 8s 上限与全部静默出口，await 它不会额外拖住起播。
    final prefetch = prefetchFolderPlayLines(
      state,
      item,
      sourceKey: '',
      timeout: linesTimeout,
      isCurrent: () => context.mounted && action.isCurrent,
    );
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
    final folderLines = await prefetch;
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
            // 预取命中才带上线路：线路、路由、命中线路与集下标必须成对，
            // 缺路由时换集会拿父目录 id 去问站点（站源判为业务错误）。
            flag: folderLines?.flag ?? item.flag,
            playbackFlag: folderLines?.playbackFlag,
            episodeIndex: folderLines?.episodeIndex ?? 0,
            playLines: folderLines?.lines ?? const [],
            lineRoutes: folderLines?.routes ?? const {},
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
