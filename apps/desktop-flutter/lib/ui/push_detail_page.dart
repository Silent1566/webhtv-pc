/// 「推送详情」页：推送落地后的第一站——先看清这是什么，再决定播不播。
///
/// 为什么不让推送直接起播（用户 2026-11-21 决策）：推送来的常常是网盘分享链或
/// 一条裸地址，"立刻播"多数时候只会得到一个播放失败页。先给一页把剧名、匹配到的
/// 元数据、真实地址摊开，用户确认后再点播放；匹配错了也能在这一页改。
///
/// 本页不复制播放器逻辑：点「播放」仍然把同一个 [PlaybackRequest] 交给
/// `PlayerPage`，与从对话框直接起播的唯一区别是多了一次确认。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/protocol.dart';
import '../core/push_parser.dart';
import '../state/app_state.dart';
import 'browse_pages.dart';
import 'common.dart';
import 'meta_match_dialog.dart';
import 'player_page.dart';
import 'poster_image.dart';
import 'search_page.dart';
import 'toast.dart';
import 'tokens.dart';

/// 网盘分享页：PC 不能把这类地址直接当视频流播放，详情页要先说清楚。
final RegExp _panSharePattern = RegExp(
  r'^(https?://)?(pan\.baidu\.com|pan\.quark\.cn|alipan\.com|aliyundrive\.com|'
  r'115\.com|cloud\.189\.cn|mega\.nz|drive\.google\.com)/',
  caseSensitive: false,
);

bool isPanShareLink(String url) => _panSharePattern.hasMatch(url.trim());

/// 推送落点：**先详情、再播放**（用户 2026-11-21 决策）。
///
/// 与安卓 `SiteApi.detailContent` 的契约一致：推送 = 合成站点
/// `push_agent` 上的一条普通 vod。因此**优先**走用户配置的「推送」源：
/// 选中该站点 → 普通 `DetailPage` → 它的线路/剧集/TMDB 全走既有管线，和点播
/// 没有区别。只有配置里没有这个源时，才退到本文件的兜底页（或已匹配时的 TMDB
/// 详情页）——那时没有线路可播，直接播地址就是唯一选择。
Future<void> openPushLanding(
  BuildContext context,
  AppState state,
  PlaybackRequest request, {
  PushParsed? parsed,
}) async {
  final source =
      parsed ?? parsePushFields(url: request.url, title: request.vodName);
  // 用户手填的剧名压过推送源返回的名字；没填就听推送源的（并交给常规 TMDB 管线）。
  final titleOverride = source.hasExplicitTitle ? source.title : '';
  // 本地文件不是站源内容：不能把磁盘路径当 ids 发给推送源。直接给推送详情页
  // （可播放、可补剧名），本地播放语义不变（无 Header、不写历史）。
  if (request.isLocal) {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => PushDetailPage(state: state, request: request),
      ),
    );
    return;
  }
  // 1) 先找「推送源」：当前配置 → 其它已保存配置（可用的优先）。
  final candidate = state.pushSourceCandidate();
  if (candidate != null) {
    if (!candidate.active) {
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => DetailPage(
            state: state,
            vod: Vod(
              vodId: request.vodId,
              vodName: request.vodName,
              extra: titleOverride.isEmpty
                  ? const {}
                  : {pushDisplayNameExtraKey: titleOverride},
            ),
            sourceContext: candidate.context,
            sourceSiteKey: candidate.site.key,
          ),
        ),
      );
      return;
    }
    // 与点一个站点一样：先切到它再按普通 vod 打开详情。不 await selectSite
    // （它会拉站点首页，推送源可能很慢），详情页只需要"当前选中的站点"。
    unawaited(state.selectSite(candidate.site));
    if (!context.mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => DetailPage(
          state: state,
          vod: Vod(
            vodId: request.vodId,
            vodName: request.vodName,
            extra: titleOverride.isEmpty
                ? const {}
                : {pushDisplayNameExtraKey: titleOverride},
          ),
        ),
      ),
    );
    return;
  }
  // 兼容/防御：选源逻辑失效时仍认当前配置里那个精确站点。
  final pushSite = state.siteInActiveSource(pushSiteKey);
  if (pushSite != null) {
    unawaited(state.selectSite(pushSite));
    if (!context.mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => DetailPage(
          state: state,
          vod: Vod(
            vodId: request.vodId,
            vodName: request.vodName,
            extra: titleOverride.isEmpty
                ? const {}
                : {pushDisplayNameExtraKey: titleOverride},
          ),
        ),
      ),
    );
    return;
  }
  // 2) 没有推送源：合成站点服务（安卓 pushDetail 同款），仍是普通详情页。
  final pushContext = state.pushSiteContext(source);
  if (pushContext != null) {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => DetailPage(
          state: state,
          vod: Vod(
            vodId: request.vodId,
            vodName: request.vodName,
            extra: titleOverride.isEmpty
                ? const {}
                : {pushDisplayNameExtraKey: titleOverride},
          ),
          sourceContext: pushContext,
          sourceSiteKey: pushSiteKey,
        ),
      ),
    );
    return;
  }
  // 3) 连配置都没有：极简兜底页。
  await Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => PushDetailPage(state: state, request: request),
    ),
  );
}

/// 用剧名去站点里搜（推送只给了地址，真正能播的往往是站点里的那一份）。
Future<void> openSearchRoute(
  BuildContext context,
  AppState state,
  String keyword,
) {
  final text = keyword.trim();
  if (text.isEmpty) return Future<void>.value();
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => Scaffold(
        appBar: AppBar(title: Text('搜索：$text')),
        body: SearchPage(state: state, initialKeyword: text),
      ),
    ),
  );
}

class PushDetailPage extends StatelessWidget {
  const PushDetailPage({super.key, required this.state, required this.request});

  final AppState state;

  /// 推送落地时构造的请求（远程地址或本地文件）。
  final PlaybackRequest request;

  String get _title {
    final matched = state.pushMatchedItem(
      vodId: request.vodId,
      title: request.vodName,
    );
    final title = matched?.title.trim() ?? '';
    return title.isEmpty ? request.vodName : title;
  }

  Future<void> _play(BuildContext context) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlayerPage(state: state, request: request),
      ),
    );
  }

  Future<void> _match(BuildContext context) async {
    if (!state.tmdbConfig.isReady) {
      showToast('TMDB 未配置，无法匹配元数据', kind: ToastKind.error);
      return;
    }
    await showDialog<bool>(
      context: context,
      builder: (_) => MetaMatchDialog(
        state: state,
        vod: Vod(vodId: request.vodId, vodName: request.vodName),
        tmdbSearch: state.searchTmdb,
        // 推送记录的当前匹配在推送表里，不在 state.tmdb。
        currentTmdb: state
            .pushMatchedItem(vodId: request.vodId, title: request.vodName)
            ?.identity,
        allowExternal: false,
        onPickTmdb: (item) async {
          await state.manualMatchPush(
            vodId: request.vodId,
            title: request.vodName,
            item: item,
          );
          // 匹配成功就换到 TMDB 详情页（用户决策：推送复用 TMDB 详情页）。
          if (context.mounted) {
            await openPushLanding(context, state, request);
          }
        },
      ),
    );
  }

  Future<void> _searchSites(BuildContext context) =>
      openSearchRoute(context, state, _title);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('推送详情'),
        actions: [
          IconButton(
            key: const ValueKey('push-detail-copy-url'),
            tooltip: '复制地址',
            onPressed: () => Clipboard.setData(
              ClipboardData(text: request.isLocal ? request.localPath : request.url),
            ),
            icon: const Icon(Icons.copy, size: 18),
          ),
        ],
      ),
      // 自动匹配是异步的：命中后会 notify，这里必须跟着重画，否则海报/剧名要
      // 等用户离开再进才出现。
      body: ListenableBuilder(
        listenable: state,
        builder: (context, _) {
          final matched = state.pushMatchedItem(
            vodId: request.vodId,
            title: request.vodName,
          );
          final title = _title;
          final poster =
              matched?.posterUrl?.trim().isNotEmpty == true
              ? matched!.posterUrl
              : state.cachedTmdbPosterUrl(
                  siteKey: pushSiteKey,
                  vodId: request.vodId,
                );
          final location = request.isLocal ? request.localPath : request.url;
          return SingleChildScrollView(
            padding: formPagePadding(context),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: AppRadius.lgAll,
                  child: PosterImage(
                    url: poster,
                    width: 180,
                    height: 270,
                    placeholder: const Center(
                      child: Icon(Icons.send_outlined, size: 36),
                    ),
                  ),
                ),
                const SizedBox(width: AppSpace.xl),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: theme.textTheme.headlineSmall),
                      if (matched != null && matched.subtitle.trim().isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: AppSpace.xs),
                          child: Text(
                            matched.subtitle,
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      if (matched?.overview?.trim().isNotEmpty == true)
                        Padding(
                          padding: const EdgeInsets.only(top: AppSpace.sm),
                          child: Text(
                            matched!.overview!.trim(),
                            maxLines: 4,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium,
                          ),
                        ),
                      const SizedBox(height: AppSpace.lg),
                      Text(
                        request.isLocal ? '本地文件' : '播放地址',
                        style: theme.textTheme.labelMedium,
                      ),
                      const SizedBox(height: AppSpace.xs),
                      SelectableText(
                        location,
                        key: const ValueKey('push-detail-location'),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontFamily: 'monospace',
                        ),
                      ),
                      if (!request.isLocal && isPanShareLink(request.url))
                        Padding(
                          padding: const EdgeInsets.only(top: AppSpace.sm),
                          child: Row(
                            key: const ValueKey('push-detail-pan-hint'),
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(
                                Icons.info_outline,
                                size: 16,
                                color: theme.colorScheme.error,
                              ),
                              const SizedBox(width: AppSpace.xs),
                              Expanded(
                                child: Text(
                                  '这是网盘分享链接，PC 不能把分享页直接当视频播放。'
                                  '建议先匹配元数据，再用剧名到站点里搜。',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.error,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      if (state.siteInActiveSource(pushSiteKey) == null)
                        Padding(
                          padding: const EdgeInsets.only(top: AppSpace.sm),
                          child: Text(
                            '当前配置里没有可用的「推送」源（push_agent）：'
                            '没法像普通点播那样取线路，只能直接播这条地址，'
                            '或用剧名到站点里搜同名资源。',
                            key: const ValueKey('push-detail-no-site-hint'),
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      if (matched == null && state.tmdbConfig.isReady)
                        Padding(
                          padding: const EdgeInsets.only(top: AppSpace.sm),
                          child: Text(
                            '还没有匹配到元数据；可以在下面手动指定，或用剧名到站点里搜。',
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      const SizedBox(height: AppSpace.xl),
                      Wrap(
                        spacing: AppSpace.sm,
                        runSpacing: AppSpace.sm,
                        children: [
                          FilledButton.icon(
                            key: const ValueKey('push-detail-play'),
                            onPressed: () => _play(context),
                            icon: const Icon(Icons.play_arrow, size: 18),
                            label: const Text('播放'),
                          ),
                          OutlinedButton.icon(
                            key: const ValueKey('push-detail-match'),
                            onPressed: () => _match(context),
                            icon: const Icon(Icons.manage_search, size: 18),
                            label: Text(matched == null ? '匹配元数据' : '修改匹配'),
                          ),
                          TextButton.icon(
                            key: const ValueKey('push-detail-search'),
                            onPressed: () => _searchSites(context),
                            icon: const Icon(Icons.search, size: 18),
                            label: const Text('用剧名搜索站点'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
