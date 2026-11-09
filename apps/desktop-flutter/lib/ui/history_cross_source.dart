/// 跨源历史续播：先用**记录自己那份配置**播，不行才在当前播放源里找替代站点。
///
/// 对应上游安卓 `HistoryResumeCoordinator` + `VodSourceResolver`
/// （`docs/global-history-resume-design.md` §11、§14）与用户 2026-11 的决定：
///
/// 1. **原来源优先**：历史记录属于哪个配置，就用那个配置的站点、请求头与解析
///    规则去播/看详情。**绝不** `activateConfigRecord`——那会把整个 App 弹到
///    另一个源上；顶栏选中的站点也保持不变。
/// 2. **失败才回退**：原配置已删除、原配置里没有该站点、播放地址解析失败
///    这几种情况，先提示原因，再走既有的「在当前源内找替代站点 → 迁移进度」。
///    播放器已经打开之后的失败不在这里处理（播放器有自己的重试/报错）。
/// 3. **不静默失败**：解析不出目标时给出可执行的动作（打开全局搜索 / 切源），
///    而不是像 v7 那样只弹一句「站点已不在当前配置中」就结束。
///
/// ## 入口顺序
///
/// | 顺序 | 条件 | 行为 |
/// | --- | --- | --- |
/// | 1 | 原配置可读且有该站点，点击设置为「播放」 | 用原配置解析 → 直接起播 |
/// | 2 | 原配置可读且有该站点，点击设置为「详情」 | 用原配置打开详情页（站点/线路/集都来自它） |
/// | 3 | 原配置缺失 / 无该站点 / 解析失败 | 提示原因 → 当前源内找替代站点 → 迁移进度 |
///
/// 第 3 步找不到高置信候选时**不自动播放**，而是让用户选：
/// 「打开全局搜索」或「取消」。这是「宁可不续播，不可错续播」的落地
/// （`docs/phase6/design/01` §4.1）。
library;

import 'package:flutter/material.dart';

import '../core/app_error.dart';
import '../core/history_view.dart';
import '../core/protocol.dart';
import '../core/resume_matching.dart';
import '../core/resume_migration.dart';
import '../services/proxy_server.dart';
import '../services/site_service.dart';
import '../services/storage.dart';
import '../state/app_state.dart';
import '../state/playback_source_context.dart';
import 'async_action_feedback.dart';
import 'browse_pages.dart';
import 'history_resume_seed.dart';
import 'player_page.dart';
import 'search_page.dart';
import 'toast.dart';

/// 从一条**非当前源**的历史恢复播放 / 看详情。
Future<void> openHistoryFromOtherSource(
  BuildContext context,
  AppState state,
  PlaybackHistory item,
) async {
  // 用户设定：点历史是进详情还是直接播。原来源与当前源**同一套语义**。
  if (!context.mounted || ModalRoute.of(context)?.isCurrent == false) return;
  final wantsPlay = state.historyClickAction == UiHistoryClickAction.play;
  final needsPreparation =
      wantsPlay ||
      state.playbackContextFor(item.sourceKey)?.siteByKey(item.siteKey) == null;
  final feedback = needsPreparation
      ? AsyncActionFeedback.begin(context, '正在准备续播：${item.vodName}')
      : null;
  if (needsPreparation && feedback == null) return;
  try {
    // ── 第一步：原配置优先 ──
    final fallbackReason = await _tryOriginalSource(
      context,
      state,
      item,
      wantsPlay: wantsPlay,
      feedback: feedback,
    );
    if (!context.mounted || (feedback != null && !feedback.isCurrent)) return;
    if (fallbackReason == null) return;

    // ── 第二步：原配置不可用 → 提示原因，再走既有的当前源匹配 ──
    _toast(context, '$fallbackReason，改为在当前播放源中匹配');
    await _matchInCurrentSource(context, state, item, feedback!);
  } catch (error) {
    if (context.mounted && feedback?.isCurrent == true) {
      feedback!.dismiss();
      final message = error is AppError ? error.userMessage : '$error';
      _toast(context, '自动匹配失败：$message', kind: ToastKind.error);
    }
  } finally {
    feedback?.close();
  }
}

/// 尝试用记录自己的配置播放/看详情。
///
/// 返回 `null` 表示「已经处理完了（起播或推了详情页）」；返回非空字符串表示
/// 原来源不可用，字符串是给用户看的原因，调用方据此回退。
Future<String?> _tryOriginalSource(
  BuildContext context,
  AppState state,
  PlaybackHistory item, {
  required bool wantsPlay,
  required AsyncActionFeedback? feedback,
}) async {
  final sourceContext = state.playbackContextFor(item.sourceKey);
  if (sourceContext == null) {
    return '原播放源「${_sourceNameOf(state, item)}」已删除或无法读取';
  }
  final site = sourceContext.siteByKey(item.siteKey);
  if (site == null) {
    return '原播放源「${_sourceNameOf(state, item)}」里已没有该站点';
  }

  if (!wantsPlay) {
    await _openDetailFromSource(context, state, item, sourceContext, site);
    return null;
  }

  try {
    final episodeTarget = restoreHistoryPlaybackTarget(item.episodeId);
    final decision = await state.resolvePlaybackForSource(
      sourceKey: sourceContext.sourceKey,
      siteKey: item.siteKey,
      episodeTarget: episodeTarget,
      flag: item.flag,
      vodId: item.vodId,
    );
    if (decision == null || decision.url == null) {
      return '原播放源「${_sourceNameOf(state, item)}」没有返回可用播放地址';
    }
    if (!context.mounted || !feedback!.isCurrent) return null;
    feedback.dismiss();
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlayerPage(
          state: state,
          request: PlaybackRequest(
            url: decision.url!,
            episodeTarget: episodeTarget,
            headers: decision.headers?.asRequestHeaders ?? const {},
            title: item.vodName,
            siteKey: item.siteKey,
            vodId: item.vodId,
            vodName: item.vodName,
            episodeName: item.episodeName,
            flag: item.flag,
            // 续播后再写进度必须保留同一个入口目标，否则这条历史会被刚解析出的
            // 可播地址覆盖（下一次续播又失败）。
            startPosition: Duration(milliseconds: item.positionMs),
            vodPic: item.vodPic,
            subtitles: decision.subs,
            danmaku: decision.danmaku,
            subtitleHeaders:
                decision.assetHeaders?.asRequestHeaders ?? const {},
            // 来源归属：播放器换集、写进度都继续按这份配置走。
            sourceKey: sourceContext.sourceKey,
          ),
        ),
      ),
    );
    return null;
  } catch (error) {
    final failure = error is AppError
        ? error
        : AppError(AppErrorKind.unknown, '$error', cause: error);
    return '原播放源「${_sourceNameOf(state, item)}」${failure.userMessage}';
  }
}

/// 用原配置打开详情页：站点、线路、集入口都来自那份配置，**不**切生效配置。
Future<void> _openDetailFromSource(
  BuildContext context,
  AppState state,
  PlaybackHistory item,
  PlaybackSourceContext sourceContext,
  Site site,
) async {
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => DetailPage(
        state: state,
        vod: Vod(
          vodId: item.vodId,
          vodName: item.vodName,
          vodPic: item.vodPic,
        ),
        historyFlag: item.flag,
        historyEpisodeId: item.episodeId,
        resumeSeed: resumeSeedOf(item),
        sourceContext: sourceContext,
        sourceSiteKey: site.key,
      ),
    ),
  );
}

/// 历史来源的可读名称（内部提示用）；不知道名字时不暴露 URL。
String _sourceNameOf(AppState state, PlaybackHistory item) =>
    state.historySourceLabel(item.sourceKey) ?? '其他来源';

/// 既有机制：在**当前播放源**内找一个能接上的站点，并把进度迁移过去。
Future<void> _matchInCurrentSource(
  BuildContext context,
  AppState state,
  PlaybackHistory item,
  AsyncActionFeedback feedback,
) async {
  if (!context.mounted || !feedback.isCurrent) return;
  final config = state.config;
  if (config == null || config.sites.isEmpty) {
    _toast(context, '当前没有生效的播放源配置，无法续播', kind: ToastKind.error);
    return;
  }

  // ── 路径一：原站点仍在当前配置里 → 直接续播（进度不需要迁移） ──
  final sameSite = config.sites
      .where((candidate) => candidate.key == item.siteKey)
      .firstOrNull;
  if (sameSite != null) {
    await _playOnSite(
      context,
      state,
      item,
      sameSite,
      item.episodeName,
      feedback: feedback,
    );
    return;
  }

  // ── 路径二：原站点不在了 → 在当前源内找可替代站点 ──
  //
  // 搜索只在**当前配置**的站点里发（用户决定 3：不切源），因此这里不需要
  // 处理「跨配置搜索」的竞态。
  final sites = [
    for (final site in config.sites)
      if (!site.hide && site.searchable) site,
  ];
  if (sites.isEmpty) {
    _toast(context, '当前播放源没有可搜索的站点，请切换播放源后重试', kind: ToastKind.error);
    return;
  }

  final keyword = _searchKeywordOf(item);
  if (keyword.isEmpty) {
    _toast(context, '该记录缺少片名，无法在当前源中匹配：${item.vodName}', kind: ToastKind.error);
    return;
  }

  final request = ResumeRequest(
    vodName: item.vodName,
    vodYear: item.vodYear,
    tmdbId: item.tmdbId,
    mediaType: item.mediaType,
  );

  if (!context.mounted || !feedback.isCurrent) return;
  try {
    final outcome = await state.searchAll(
      keyword,
      timeout: const Duration(seconds: 12),
    );
    if (!context.mounted || !feedback.isCurrent) return;

    // 第一阶段：列表阶段只能拿到片名/年份，先按它们粗筛（安卓 §11 两阶段
    // 解析）。`hasTargetEpisode` 此时一律为 false——**不能**预置成 true，
    // 否则「目标集不存在」的候选也会通过 `pickAutoPlayable` 被自动播放。
    final listed = <ResumeCandidate>[
      for (final entry in outcome.results)
        if (entry.succeeded)
          for (final vod in entry.result!.list.take(4))
            ResumeCandidate(
              siteKey: entry.siteKey,
              siteName: entry.siteName,
              vodId: vod.vodId,
              vodName: vod.vodName,
              vodYear: vod.vodYear?.trim() ?? '',
            ),
    ];
    if (listed.isEmpty) {
      _toast(context, '未在当前播放源中找到「${item.vodName}」');
      if (context.mounted && feedback.isCurrent) {
        feedback.dismiss();
        await _offerGlobalSearch(context, state, item);
      }
      return;
    }

    // 第二阶段：只对**等级够格**的候选加载详情，回填集数与「目标集是否存在」。
    // 限制条数是为了不让一次续播打出十几请求（安卓 §11：每站 ≤2、全局 ≤12）。
    final candidates = await _enrichCandidates(
      state,
      request,
      listed,
      seed: resumeSeedOf(item),
    );
    if (!context.mounted || !feedback.isCurrent) return;

    final ranked = rankCandidates(request, candidates);
    final pick = pickAutoPlayable(ranked);
    // 没有任何候选能接上这一集：主动说清楚「片找到了但集对不上」，
    // 否则用户会以为自动匹配没工作。
    if (pick == null && context.mounted) {
      final anyAuto = ranked.any(
        (row) => MatchConfidence.canAutoPlay(row.confidence),
      );
      if (anyAuto) _toast(context, '已找到同名作品，但没有对应的集，请在详情页手动选择');
    }
    if (pick != null) {
      final site = config.sites
          .where((candidate) => candidate.key == pick.siteKey)
          .firstOrNull;
      if (site != null) {
        await _playOnSite(
          context,
          state,
          item,
          site,
          item.episodeName,
          feedback: feedback,
          vodIdOverride: pick.vodId,
          vodNameOverride: pick.vodName,
        );
        return;
      }
    }
    // 没有高置信候选：让用户自己选，不猜。
    if (context.mounted && feedback.isCurrent) {
      feedback.dismiss();
      await _offerGlobalSearch(context, state, item);
    }
  } catch (error) {
    if (context.mounted && feedback.isCurrent) {
      feedback.dismiss();
      _toast(context, '自动匹配失败：$error', kind: ToastKind.error);
    }
  }
}

/// 在指定站点上解析并播放（公共尾部）。
///
/// [vodIdOverride] / [vodNameOverride] 用于「换到了另一个站点的同名作品」：
/// 此时详情要用新条目的 id，但**进度仍来自原记录**（见 [ResumePositionPolicy]）。
Future<void> _playOnSite(
  BuildContext context,
  AppState state,
  PlaybackHistory item,
  Site site,
  String episodeName, {
  required AsyncActionFeedback feedback,
  String? vodIdOverride,
  String? vodNameOverride,
}) async {
  if (!context.mounted || !feedback.isCurrent) return;
  await state.selectSite(site);
  if (!context.mounted || !feedback.isCurrent) return;
  feedback.dismiss();
  final vodId = vodIdOverride ?? item.vodId;
  final vodName = vodNameOverride ?? item.vodName;
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => DetailPage(
        state: state,
        vod: Vod(vodId: vodId, vodName: vodName, vodPic: item.vodPic),
        // 线路与集入口取自**原记录**：它们指向的是原源里的那一集，
        // 详情页找不到时会按「歧义就不猜」退回第一条线路（既有语义），
        // 不会把用户送到错误的集上。
        historyFlag: item.flag,
        historyEpisodeId: item.episodeId,
        // 进度必须一起带过去：跨源时详情页按当前站点查不到本机历史，
        // 少了它就只能从头播（用户点「继续观看」的意图被丢掉）。
        resumeSeed: resumeSeedOf(item),
      ),
    ),
  );
}

/// 第二阶段解析：给候选补上 `episodeCount` 与 `hasTargetEpisode`。
///
/// 为什么必须做：`pickAutoPlayable` 要求 `hasTargetEpisode`，而搜索结果里
/// **没有**线路信息——只有加载详情才知道这部剧有没有那一集。少了这一步，
/// 「同名片但只有 1 集」的候选会被当成能续播，用户点「继续观看」后进度迁移
/// 必然被 `resumeEpisodeMatches` 拒掉，落得从头播（正是要修的缺口）。
///
/// 两个刻意的收窄：
/// 1. 只查**等级够格**的候选（TMDB/年份粗筛后），不把搜索结果全打一遍详情；
/// 2. 单条详情失败只降级该候选（`hasTargetEpisode: false`），不中断整次续播。
///
/// 限制条数上限 [maxDetailProbes] 与安卓 §11 的「全局 ≤12 候选」一致。
Future<List<ResumeCandidate>> _enrichCandidates(
  AppState state,
  ResumeRequest request,
  List<ResumeCandidate> listed, {
  required ResumeSeed seed,
}) async {
  final service = state.siteService;
  if (service == null) return listed;
  final config = state.config;
  if (config == null) return listed;

  // 先按第一阶段等级排序，保证被截断掉的是最不像的那些。
  final ranked = rankCandidates(request, listed);
  final enriched = <ResumeCandidate>[];
  var probes = 0;
  for (final row in ranked) {
    final candidate = row.candidate;
    final site = config.sites
        .where((item) => item.key == candidate.siteKey)
        .firstOrNull;
    if (site == null) {
      enriched.add(candidate);
      continue;
    }
    if (probes >= maxDetailProbes) {
      // 探测预算用尽：原样保留（等级仍参与排序，但 hasTargetEpisode 为
      // false，不会被自动播放选中）。宁可让用户手选，不可赌一把播错集。
      enriched.add(candidate);
      continue;
    }
    probes++;
    try {
      final detail = await service.detail(
        site,
        candidate.vodId,
        identity: VodIdentityHint(
          vodId: candidate.vodId,
          vodName: candidate.vodName,
        ),
      );
      // `detail` 返回的是 `SiteResult`（folder 分享链会有多条），线路要
      // 逐条摊平；直接用 `firstOrNull` 会漏掉 folder 的分集线路。
      final lines = <VodPlayLine>[
        for (final vod in detail.value.list) ...SiteService.playLinesOf(vod),
      ];
      enriched.add(
        ResumeCandidate(
          siteKey: candidate.siteKey,
          siteName: candidate.siteName,
          vodId: candidate.vodId,
          vodName: candidate.vodName,
          vodYear: candidate.vodYear,
          tmdbId: candidate.tmdbId,
          mediaType: candidate.mediaType,
          episodeCount: episodeCountOf(lines),
          hasTargetEpisode: candidateHasResumeEpisode(lines: lines, seed: seed),
        ),
      );
    } catch (_) {
      // 详情失败只影响这一个候选：保持 hasTargetEpisode=false 即可，
      // 不把它升格成「能续播」。
      enriched.add(candidate);
    }
  }
  return enriched;
}

/// 一次续播最多探测多少个候选的详情（安卓 §11 的全局候选上限）。
const int maxDetailProbes = 12;

/// 搜索关键词：优先用片名本身（站点的搜索接口认片名，不认已清洗的标题）。
///
/// 为什么先原生片名再清洗：安卓 §10.3 的优先级是「规范标题 → 缓存标题 →
/// 原片名 → 去噪标题」，但 PC 侧此处**没有** TMDB 缓存可用（跨源时原源的
/// TMDB 绑定属于另一个 `config_id`），而站点的搜索接口对原片名的召回率
/// 最高。清洗只在原片名为空时兜底。
String _searchKeywordOf(PlaybackHistory item) {
  final raw = item.vodName.trim();
  if (raw.isNotEmpty) return raw;
  return '';
}

/// 降级入口：打开全局搜索，并带上「继续观看」上下文。
Future<void> _offerGlobalSearch(
  BuildContext context,
  AppState state,
  PlaybackHistory item,
) async {
  if (!context.mounted) return;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      key: const ValueKey('history-cross-source-dialog'),
      title: const Text('未找到可可靠续播的播放源'),
      content: Text(
        '「${item.vodName}」不在当前播放源中，且没有高置信的同名站点。\n'
        '可以打开全局搜索手动选择来源；进度会在选中后按同一集迁移。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('history-cross-source-open-search'),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('打开全局搜索'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => SearchPage(
        state: state,
        initialKeyword: _searchKeywordOf(item),
        // 续播上下文一起带进全局搜索：用户挑中一条结果后仍按同一集迁移进度。
        resumeSeed: resumeSeedOf(item),
      ),
    ),
  );
}

/// 文件内的通知入口：统一走全局浮动通知（右下角），不再依赖 `ScaffoldMessenger`。
void _toast(
  BuildContext context,
  String message, {
  ToastKind kind = ToastKind.info,
}) {
  if (!context.mounted) return;
  showToast(message, kind: kind);
}
