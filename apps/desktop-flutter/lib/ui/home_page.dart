/// 首页（观测台）：全幅 hero + 三条续播/推荐轨道。
///
/// 分工（见 `docs/phase11/design/01-home-hero.md`）：
/// - 取数交给 `AppState`，折成 hero/轨道交给 `buildHomeFeed`，画卡片交给
///   `HomeRailView`。页面里不排序、不去重。
/// - 点什么都必须是**既有的那条路**：续播走 `resumeHistoryEntry`（自带切站点与
///   可读失败提示），追剧走 `playFollowingLatest` / `openFollowingDetail`。
/// - 页面不认识外壳：要用外壳能力的地方由回调注入（不 import `app.dart`）。
///
/// 两级渲染（`02-home-feed-contract.md` §3）：第一帧只用本地历史与追剧，推荐异步
/// 后到；到达后**只往 hero 尾部追加、从不驱逐已有条目**——用户可能正读到第一张，
/// 换掉它就是把人读一半的内容抽走。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../core/detail_recommendation.dart';
import '../core/protocol.dart' show HeaderRule;
import '../core/home_feed.dart';
import '../core/home_hot.dart';
import '../core/tmdb_identity.dart';
import '../core/tmdb_title.dart';
import '../core/watched_recommendation.dart';
import '../services/search_suggest_service.dart' show HotRankCategory;
import '../state/app_state.dart';
import '../state/detail_recommendation_state.dart';
import 'glass_dialog.dart';
import 'glass_widgets.dart';
import 'async_action_feedback.dart';
import 'following_actions.dart';
import 'home_cards.dart';
import 'home_backdrop.dart';
import 'history_cross_source.dart';
import 'history_entry_detail.dart';
import 'home_hero.dart';
import 'home_hero_image_probe.dart';
import 'image_header_scope.dart';
import 'poster_image.dart' show posterImageProvider;
import 'playback_resume.dart';
import 'recommendation_detail_route.dart';
import 'recommendation_info_dialog.dart';
import 'search_page.dart';
import 'tokens.dart';

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.state,
    required this.onOpenBrowse,
    required this.onOpenHistory,
    required this.onOpenFollowing,
    required this.onImportConfig,
    required this.onSearch,
    this.heroImageLoader,
    this.hasShellArtwork = false,
    this.onHeroBackdropChanged,
  });

  final AppState state;

  /// 图片I/O注入点；生产默认验证真实解码像素，测试可供给确定性图像结果。
  final HomeHeroImageLoader? heroImageLoader;

  final bool hasShellArtwork;

  /// The shell paints decoded hero art behind chrome, without moving this viewport.
  final ValueChanged<Widget?>? onHeroBackdropChanged;

  /// 「去点播逛逛」与推荐卡的去向。
  final VoidCallback onOpenBrowse;

  /// 继续观看轨道的「查看全部」。
  final VoidCallback onOpenHistory;

  /// 追剧更新轨道的「查看全部」。
  final VoidCallback onOpenFollowing;

  /// 未导入配置时的主按钮：打开配置页。
  final VoidCallback onImportConfig;

  /// 热门「去找片源」：带着标题去搜索页（`initialKeyword` 自动搜索）。
  final ValueChanged<String> onSearch;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  /// 数据与在途任务都在会话里：页面销毁不丢，返回时直接投影。
  late final _session = widget.state.homeHeroSession;

  ImageStream? _heroBackdropStream;
  ImageStreamListener? _heroBackdropListener;
  Widget? _shellHeroBackdrop;

  void _watchHeroBackdrop(
    BuildContext context,
    HomeItem? item,
    HomeBackdrop backdrop,
    ValueChanged<HomeItem> onImageError,
  ) {
    final url = item?.backdrop?.trim() ?? '';
    final stream = url.isEmpty
        ? null
        : posterImageProvider(
            url,
            headers: imageHeadersOrNull(context, url),
          ).resolve(createLocalImageConfiguration(context));
    if (stream?.key == _heroBackdropStream?.key) return;
    _stopWatchingHeroBackdrop();

    void report(Widget? layer) {
      if (_shellHeroBackdrop == layer) return;
      _shellHeroBackdrop = layer;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _shellHeroBackdrop == layer) {
          widget.onHeroBackdropChanged?.call(layer);
        }
      });
      WidgetsBinding.instance.ensureVisualUpdate();
    }

    if (stream == null) {
      report(null);
      return;
    }
    bool hasFrame = false;
    final listener = ImageStreamListener(
      (image, _) {
        image.dispose();
        if (!hasFrame) report(backdrop);
        hasFrame = true;
      },
      onError: (_, _) {
        report(null);
        onImageError(item!);
      },
    );
    _heroBackdropStream = stream;
    _heroBackdropListener = listener;
    stream.addListener(listener);
    if (!hasFrame) report(null);
  }

  void _stopWatchingHeroBackdrop() {
    final listener = _heroBackdropListener;
    if (listener != null) _heroBackdropStream?.removeListener(listener);
    _heroBackdropStream = null;
    _heroBackdropListener = null;
  }

  AppState get _state => widget.state;

  @override
  void initState() {
    super.initState();
    _session.attachImageLoader(widget.heroImageLoader);
    _session.attach();
    _session.addListener(_onSessionChanged);
    // 放到首帧之后：第一帧必须是本地内容，不能被网络挡住（§5「不显示骨架」）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _session.startBackgroundLoads();
    });
  }

  void _onSessionChanged() {
    if (mounted) setState(() {});
  }

  /// 图片请求头来自当前配置；会话按它算快照 scope 与图片地址。
  List<HeaderRule> _headerRules() =>
      ImageHeaderScope.maybeRules(context) ??
      _state.effectiveConfig?.headers ??
      const [];

  @override
  void dispose() {
    _stopWatchingHeroBackdrop();
    // 会话归 AppState 所有：退出页面只解除订阅，**不取消在途任务**——否则切到
    // 点播再回来又得从零等一遍，正是这次要修的那个等待。
    _session.removeListener(_onSessionChanged);
    _session.detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = _session.project(headerRules: _headerRules());
    final rails = p.rails;
    final hot = p.hot;
    final heroItems = p.heroItems;
    final candidates = p.candidates;
    final hasRails = p.hasRails;

    return LayoutBuilder(
      builder: (context, constraints) {
        // 首屏只有一档高度（见 `homeHeroHeight`）：素材有没有 16:9 都占满内容区。
        // 用户 2026-11-25 要的是「每张都是大海报」，高度不再随素材缩。
        final heroHeight = homeHeroHeight(constraints.maxHeight);
        return Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fill(
              child: IgnorePointer(
                child: ValueListenableBuilder<int>(
                  valueListenable: _session.heroIndex,
                  builder: (context, index, _) {
                    final backdrop = HomeBackdrop(
                      items: heroItems,
                      index: index,
                      onImageError: _session.onHeroImageError,
                    );
                    if (widget.onHeroBackdropChanged == null) return backdrop;
                    final item = heroItems.isEmpty
                        ? null
                        : heroItems[index % heroItems.length];
                    _watchHeroBackdrop(
                      context,
                      item,
                      backdrop,
                      _session.onHeroImageError,
                    );
                    if (widget.hasShellArtwork) return const SizedBox.expand();
                    return const SizedBox.expand();
                  },
                ),
              ),
            ),
            CustomScrollView(
              key: const ValueKey('home-scroll'),
              slivers: [
                SliverToBoxAdapter(
                  child: heroItems.isEmpty
                      ? (p.reserveHeroSlot
                            ? _HomeHeroStartupPlaceholder(
                                height: heroHeight,
                                loading: p.scanRunning,
                                hasCandidates:
                                    candidates.isNotEmpty || hasRails,
                                hasConfig: _state.hasConfig,
                                onOpenBrowse: widget.onOpenBrowse,
                                onImportConfig: widget.onImportConfig,
                              )
                            : _HomeEmptyHero(
                                height: 220,
                                hasConfig: _state.hasConfig,
                                onImportConfig: widget.onImportConfig,
                                onOpenBrowse: widget.onOpenBrowse,
                              ))
                      : HomeHero(
                          items: heroItems,
                          height: heroHeight,
                          paintImage: false,
                          initialIndex: _session.heroIndex.value,
                          onIndexChanged: (index) =>
                              _session.heroIndex.value = index,
                          onPrimary: (item) =>
                              _activate(context, item, primary: true),
                          onSecondary: (item) =>
                              _activate(context, item, primary: false),
                        ),
                ),
                for (final rail in [...rails, ...hot])
                  SliverToBoxAdapter(
                    child: HomeRailView(
                      key: ValueKey(
                        'home-rail-${rail.kind.name}-${switch (rail.kind) {
                          HomeRailKind.recommendTmdb || HomeRailKind.recommendDouban => _session.recommendationPagingKey,
                          _ => '',
                        }}',
                      ),
                      rail: rail,
                      loadMore: switch (rail.kind) {
                        HomeRailKind.recommendTmdb =>
                          () => _session.loadMoreRecommendations(
                            RecommendationRow.tmdb,
                          ),
                        HomeRailKind.recommendDouban =>
                          () => _session.loadMoreRecommendations(
                            RecommendationRow.douban,
                          ),
                        _ => null,
                      },
                      hasMore: switch (rail.kind) {
                        HomeRailKind.recommendTmdb =>
                          _session.recommendationHasMore(
                            RecommendationRow.tmdb,
                          ),
                        HomeRailKind.recommendDouban =>
                          _session.recommendationHasMore(
                            RecommendationRow.douban,
                          ),
                        _ => false,
                      },
                      onPagination: (message) =>
                          _session.recordRailPagination(rail.kind, message),
                      isLoading: () => switch (rail.kind) {
                        HomeRailKind.recommendTmdb ||
                        HomeRailKind.recommendDouban =>
                          _session.recommendationLoading,
                        _ => false,
                      },
                      paginationError: switch (rail.kind) {
                        HomeRailKind.recommendTmdb =>
                          _session.recommendationError(RecommendationRow.tmdb),
                        HomeRailKind.recommendDouban =>
                          _session.recommendationError(
                            RecommendationRow.douban,
                          ),
                        _ => null,
                      },
                      onTap: (item) => _activate(
                        context,
                        item,
                        primary:
                            item.kind == HomeItemKind.resume ||
                            item.kind == HomeItemKind.recommend ||
                            item.kind == HomeItemKind.hot,
                      ),
                      onLongPress: switch (rail.kind) {
                        HomeRailKind.recommendTmdb ||
                        HomeRailKind.recommendDouban => (item) => unawaited(
                          _showRecommendationInfo(item),
                        ),
                        HomeRailKind.hotMovie ||
                        HomeRailKind.hotTv ||
                        HomeRailKind.hotVariety => (item) => unawaited(
                          _showHotInfo(item, rail.kind),
                        ),
                        _ => null,
                      },
                      onSeeAll: switch (rail.seeAll) {
                        HomeSeeAll.history => widget.onOpenHistory,
                        HomeSeeAll.following => widget.onOpenFollowing,
                        null => null,
                      },
                    ),
                  ),
                const SliverToBoxAdapter(child: SizedBox(height: AppSpace.xxl)),
              ],
            ),
          ],
        );
      },
    );
  }

  Future<void> _activate(
    BuildContext context,
    HomeItem item, {
    required bool primary,
  }) async {
    switch (item.kind) {
      case HomeItemKind.resume:
        final record = item.history;
        if (record == null) return;
        if (primary) {
          // 主按钮（卡片整张 / hero「继续播放」）就是续播：切回这条记录自己的
          // 站点再起播，失败有可读提示。
          //
          // 首页 feed 取的是**全源**历史（`recentHistory(sourceKey: '')`），所以这里
          // 必须和历史页一样先过跨源闸门：直接 `resumeHistoryEntry` 会拿生效配置
          // 去找别的源的站点，轻则误报「站点已不在配置中」，重则同名 key 在错源上
          // 起播（串源）。原来源优先、失败再回退的语义由跨源流程自己负责。
          if (_state.isHistoryFromOtherSource(record)) {
            await openHistoryFromOtherSource(
              context,
              _state,
              record,
              wantsPlayOverride: true,
            );
          } else {
            await resumeHistoryEntry(context, _state, record);
          }
        } else {
          // 「查看详情」进详情页，并**优先这条记录自己的播放源**：先切站点，
          // 带着线路/集/进度进去（`history_entry_detail.dart`）。
          await openHistoryDetail(context, _state, record);
        }
        _session.invalidateMetadata();
        return;
      case HomeItemKind.following:
        final following = item.following;
        if (following == null) return;
        if (primary) {
          await playFollowingLatest(context, _state, following);
        } else {
          await openFollowingDetail(
            context,
            _state,
            following,
            markRead: true,
            syncProgress: true,
          );
        }
        _session.invalidateMetadata();
        return;
      case HomeItemKind.hot:
        if (primary) {
          await _openHotDetail(item);
        } else {
          widget.onSearch(item.title);
        }
        return;
      case HomeItemKind.recommend:
        if (primary) {
          await _openRecommendationDetail(context, item);
        } else {
          await _searchRecommendation(item.title, item.entry?.item.identity);
        }
        _session.invalidateMetadata();
        return;
    }
  }

  Future<void> _searchRecommendation(String title, [TmdbIdentity? identity]) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          appBar: AppBar(
            title: const Text('搜索站源'),
            backgroundColor: Colors.transparent,
            flexibleSpace: const IgnorePointer(
              child: GlassPane(
                borderRadius: BorderRadius.zero,
                child: SizedBox.expand(),
              ),
            ),
          ),
          body: SearchPage(
            state: _state,
            initialKeyword: title,
            identityHint: identity,
          ),
        ),
      ),
    );
  }

  RecommendationInfo _recommendationInfo(HomeItem item) => RecommendationInfo(
    title: item.title,
    sourceLabel: item.entry?.source == RecommendationSource.douban
        ? '豆瓣'
        : 'TMDB',
    posterUrl: item.poster,
    meta: [
      ...item.subtitle.split(' · ').where((part) => part.trim().isNotEmpty),
      if ((item.entry?.doubanRating ?? 0) > 0)
        '豆瓣 ${item.entry!.doubanRating.toStringAsFixed(1)}',
    ],
    overview: item.overview,
    reason: item.reason,
    credit: item.entry?.item.credit,
    openLabel: item.entry?.item.identity == null ? '去找片源' : '详情',
  );

  Future<void> _showRecommendationInfo(HomeItem item) {
    final entry = item.entry;
    return showRecommendationInfo(
      context,
      info: _recommendationInfo(item),
      watched: _session.watched,
      work: entry == null ? null : RecommendationWork.fromEntry(entry),
      onOpen: () => unawaited(
        item.entry?.item.identity == null
            ? _searchRecommendation(item.title)
            : _activate(context, item, primary: true),
      ),
      onNotInterested: () async => _session.feedback.block(item.title),
    );
  }

  Future<void> _showHotInfo(HomeItem item, HomeRailKind kind) {
    final category = switch (kind) {
      HomeRailKind.hotMovie => HotRankCategory.movie,
      HomeRailKind.hotTv => HotRankCategory.series,
      HomeRailKind.hotVariety => HotRankCategory.variety,
      _ => throw ArgumentError.value(kind),
    };
    final source = _session
        .hotRows(category)
        ?.where(
          (row) => hotItem(row, categoryKey: category.name).key == item.key,
        )
        .firstOrNull;
    return showRecommendationInfo(
      context,
      info: RecommendationInfo(
        title: item.title,
        kind: RecommendationInfoKind.hot,
        sourceLabel: '360kan · ${category.label}榜',
        posterUrl: item.poster,
        meta: [
          if ((source?.rank ?? 0) > 0) '第 ${source!.rank} 名',
          if (item.subtitle.isNotEmpty) item.subtitle,
          if (item.reason.isNotEmpty && item.reason != '热门') item.reason,
        ],
      ),
      watched: _session.watched,
      work: RecommendationWork(
        title: item.title,
        mediaType: category == HotRankCategory.movie
            ? TmdbMediaType.movie
            : TmdbMediaType.tv,
      ),
      onOpen: () => unawaited(_openHotDetail(item)),
      onSearchSource: () => widget.onSearch(item.title),
    );
  }

  Future<void> _openRecommendationDetail(BuildContext context, HomeItem item) {
    final entry = item.entry;
    final identity = entry?.item.identity;
    if (identity == null) {
      // 没有 TMDB 身份时只展示已有资料，不伪造详情身份或跳到无关站点。
      return _showRecommendationInfo(item);
    }
    // 去向与点播页的推荐卡是同一条规则：先按标题在当前站点搜一次，命中进该站点的
    // 真实详情页，没命中才退成导航源形态的回退页（`recommendation_detail_route.dart`）。
    return openRecommendationDetail(
      context,
      _state,
      entry!.item,
      site: _state.selectedSite,
    );
  }

  Future<void> _openHotDetail(HomeItem item) async {
    final feedback = AsyncActionFeedback.begin(context, '正在查找详情：${item.title}');
    if (feedback == null) return;
    try {
      final service = _state.tmdbService;
      if (!service.config.isReady) {
        feedback.dismiss();
        await _hotDetailUnavailable(item, '未配置 TMDB，暂时无法查询热门作品详情。可先去找片源。');
        return;
      }
      final mediaType = switch (item.key.split(':').elementAtOrNull(1)) {
        'movie' => TmdbMediaType.movie,
        'series' || 'variety' => TmdbMediaType.tv,
        _ => null,
      };
      final candidates = [
        for (final candidate in await service.search(item.title))
          if (candidate.identity != null &&
              (mediaType == null || candidate.mediaType == mediaType))
            candidate,
      ];
      if (!mounted || !feedback.isCurrent) return;
      feedback.dismiss();
      if (candidates.isEmpty) {
        await _hotDetailUnavailable(item, '暂未找到《${item.title}》的作品详情，可先去找片源。');
        return;
      }
      final title = normalizeTitle(item.title);
      final exact = candidates
          .where((candidate) => normalizeTitle(candidate.title) == title)
          .toList();
      final selected = exact.length == 1
          ? exact.single
          : await _chooseHotDetail(item, exact.isEmpty ? candidates : exact);
      if (!mounted || !feedback.isCurrent || selected == null) return;
      await openRecommendationDetail(
        context,
        _state,
        selected,
        site: _state.selectedSite,
      );
    } catch (_) {
      if (!mounted || !feedback.isCurrent) return;
      feedback.dismiss();
      await _hotDetailUnavailable(item, '暂未取得《${item.title}》的详情，请稍后重试，或先去找片源。');
    } finally {
      feedback.close();
    }
  }

  Future<TmdbItem?> _chooseHotDetail(HomeItem item, List<TmdbItem> candidates) {
    return showGlassDialog<TmdbItem>(
      context: context,
      builder: (dialogContext) => GlassAlertDialog(
        key: const ValueKey('home-hot-details-picker'),
        constraints: const BoxConstraints(maxWidth: 608),
        title: Text('选择《${item.title}》的详情'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final candidate in candidates)
                  ListTile(
                    key: ValueKey(
                      'home-hot-candidate-${candidate.identity!.key}',
                    ),
                    leading: Icon(
                      candidate.isMovie ? Icons.movie_outlined : Icons.tv,
                    ),
                    title: Text(candidate.title),
                    subtitle: Text(candidate.subtitle),
                    onTap: () => Navigator.of(dialogContext).pop(candidate),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            key: const ValueKey('home-hot-details-cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }

  Future<void> _hotDetailUnavailable(HomeItem item, String message) async {
    final search = await showGlassDialog<bool>(
      context: context,
      builder: (dialogContext) => GlassAlertDialog(
        key: const ValueKey('home-hot-details-unavailable'),
        title: const Text('暂未找到详情'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('关闭'),
          ),
          FilledButton.icon(
            key: const ValueKey('home-hot-details-search'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            icon: const Icon(Icons.search),
            label: const Text('去找片源'),
          ),
        ],
      ),
    );
    if (mounted && search == true) widget.onSearch(item.title);
  }
}

/// 没有可续播内容时的首屏。
///
/// 为什么不是一个居中的 `EmptyState`：首屏那一整块是「大屏」的第一印象，
/// 居中空态会把「这里是播放器的脸」变成「这里出错了」。所以它仍然占满 hero 的
/// 高度，用同一套夜空底色，只把文案与一个按钮放在左下——与有内容时的落点一致。
class _HomeEmptyHero extends StatelessWidget {
  const _HomeEmptyHero({
    required this.height,
    required this.hasConfig,
    required this.onImportConfig,
    required this.onOpenBrowse,
  });

  final double height;
  final bool hasConfig;
  final VoidCallback onImportConfig;
  final VoidCallback onOpenBrowse;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SizedBox(
      key: const ValueKey('home-empty-hero'),
      height: height,
      width: double.infinity,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpace.xl,
          AppSpace.xl,
          AppSpace.xl,
          44,
        ),
        child: Align(
          alignment: Alignment.bottomLeft,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                hasConfig ? '还没有可续播的内容' : '还没有导入配置',
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: AppWeight.title,
                  color: scheme.onSurface,
                ),
              ),
              const SizedBox(height: AppSpace.sm),
              Text(
                hasConfig ? '看过一集之后，这里会接着上次的位置。' : '支持 URL、本地文件与 JSON 文本三种方式。',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: AppSpace.lg),
              FilledButton(
                key: const ValueKey('home-empty-action'),
                onPressed: hasConfig ? onOpenBrowse : onImportConfig,
                child: Text(hasConfig ? '去点播逛逛' : '导入配置'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 首次无缓存也固定占好推荐位，加载/失败只替换内容，不移动下方轨道。
class _HomeHeroStartupPlaceholder extends StatelessWidget {
  const _HomeHeroStartupPlaceholder({
    required this.height,
    required this.loading,
    required this.hasCandidates,
    required this.hasConfig,
    required this.onOpenBrowse,
    required this.onImportConfig,
  });
  final double height;
  final bool loading;
  final bool hasCandidates;
  final bool hasConfig;
  final VoidCallback onOpenBrowse;
  final VoidCallback onImportConfig;

  @override
  Widget build(BuildContext context) => SizedBox(
    key: const ValueKey('home-hero-startup-placeholder'),
    height: height,
    width: double.infinity,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.xl,
        AppSpace.xl,
        AppSpace.xl,
        44,
      ),
      child: Align(
        alignment: Alignment.bottomLeft,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              !hasCandidates
                  ? (hasConfig ? '还没有可续播的内容' : '还没有导入配置')
                  : (loading ? '正在准备精选推荐' : '暂无可用的高清推荐'),
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: AppSpace.sm),
            Text(
              loading ? '优先恢复本地图片，后台检查新的高清宽图。' : '继续观看和追剧列表仍保留在下方。',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            if (!hasCandidates) ...[
              const SizedBox(height: AppSpace.lg),
              FilledButton(
                key: const ValueKey('home-empty-action'),
                onPressed: hasConfig ? onOpenBrowse : onImportConfig,
                child: Text(hasConfig ? '去点播逛逛' : '导入配置'),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}
