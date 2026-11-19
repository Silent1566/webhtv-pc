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
import '../core/following.dart';
import '../core/following_calendar.dart';
import '../core/home_feed.dart';
import '../core/home_hot.dart';
import '../core/tmdb_identity.dart';
import '../services/home_art_service.dart';
import '../services/search_suggest_service.dart';
import '../state/app_state.dart';
import '../state/detail_recommendation_state.dart';
import 'following_actions.dart';
import 'following_air_data.dart';
import 'home_cards.dart';
import 'history_cross_source.dart';
import 'history_entry_detail.dart';
import 'home_hero.dart';
import 'playback_resume.dart';
import 'tokens.dart';

/// hero 的容量上限（与 `core/home_feed.dart` 的 `_heroMax` 同一个数）。
const int _heroMax = 12;

/// 参与推荐的历史条数：最近 4 条（1 条当 current，其余当种子）。
///
/// 不是「越多越准」：种子越多，缓存键变化越频繁（看一集就换键），而首页每次启动
/// 都换键等于每次启动都重新打网络——详情页那套 7 天缓存就白设了。
const int _seedLimit = 4;

/// 每条推荐行参与元数据解析的条数（= hero 的推荐预算 3）。
const int _heroRecommendBudgetForMeta = 3;

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.state,
    required this.onOpenBrowse,
    required this.onOpenHistory,
    required this.onOpenFollowing,
    required this.onImportConfig,
    required this.onSearch,
  });

  final AppState state;

  /// 「去点播逛逛」与推荐卡的去向。
  final VoidCallback onOpenBrowse;

  /// 继续观看轨道的「查看全部」。
  final VoidCallback onOpenHistory;

  /// 追剧更新轨道的「查看全部」。
  final VoidCallback onOpenFollowing;

  /// 未导入配置时的主按钮：打开配置页。
  final VoidCallback onImportConfig;

  /// 点「热门」卡片：带着这个词去搜索页（搜索页已有 `initialKeyword` 自动搜索）。
  final ValueChanged<String> onSearch;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  /// 已到达的推荐：行 → 条目。空表示还没到（或失败后永远不来）。
  final Map<RecommendationRow, List<RecommendationEntry>> _recommendations = {};

  /// 按 TMDB 身份取回的高清图：HomeItem.key → 图。空表示还没到。
  final Map<String, HomeMeta> _art = {};

  /// 热门榜单：类目 → 条目（360kan，搜索页同一份数据）。
  final Map<HotRankCategory, List<SearchSuggestItem>> _hot = {};

  bool _requested = false;
  bool _hotRequested = false;
  bool _artRequested = false;
  bool _airRequested = false;
  bool _leased = false;

  /// 追剧的播出时间（TMDB，6h 缓存）：用来判断「近 48 小时有没有更新」。
  FollowingAirData? _air;
  List<FollowingAirTime> _airTimes = const [];

  AppState get _state => widget.state;

  @override
  void initState() {
    super.initState();
    // 放到首帧之后：第一帧必须是本地内容，不能被网络挡住（§5「不显示骨架」）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadRecommendations();
      _loadArt();
      _loadHot();
      _loadAir();
    });
  }

  @override
  void dispose() {
    // 租约必须还：豆瓣 provider 的 750ms 间隔定时器挂在它上面，
    // 不还就会活到 widget 树之外（detail_recommendation_state.dart:16-22 记过这个坑）。
    if (_leased) _state.recommendationDependencies.release();
    _air?.removeListener(_onAirChanged);
    _air?.dispose();
    super.dispose();
  }

  /// 取追剧的播出时间。没有追剧、或 TMDB 未配置时安静返回（列表保持原样）。
  Future<void> _loadAir() async {
    if (_airRequested || !mounted) return;
    _airRequested = true;
    final items = _state.followings;
    if (items.isEmpty) return;
    final air = FollowingAirData(state: _state);
    _air = air;
    air.addListener(_onAirChanged);
    try {
      await air.refresh(items);
    } catch (_) {
      // 播出时间拿不到就退化成「全部保留」，绝不因为查不到时间而藏掉轨道。
    }
    _onAirChanged();
  }

  void _onAirChanged() {
    if (!mounted) return;
    setState(() => _airTimes = _air?.airTimes ?? const []);
  }

  /// 追剧轨道只保留「近 48 小时内更新」的（用户 2026-11-19：「近期没有时不显示」）。
  ///
  /// 判据是**该剧最新一集的真实播出时间**：只有查到、且确实早于 48 小时才隐藏；
  /// 查不到（TMDB 未配置 / 该集没有播出日期）一律保留——宁可多显示一条，
  /// 也不让「追剧」因为一个第三方元数据缺席而整条消失。
  List<Following> _recentFollowings(List<Following> all) {
    if (_airTimes.isEmpty) return all;
    final now = DateTime.now().millisecondsSinceEpoch;
    const windowMs = 48 * 60 * 60 * 1000;
    final airAt = <String, int>{};
    for (final time in _airTimes) {
      final key = '${time.identityKey}#${time.episode}';
      final previous = airAt[key];
      if (previous == null || time.airAtMs > previous) {
        airAt[key] = time.airAtMs;
      }
    }
    return [
      for (final item in all)
        if (_isRecent(item, airAt: airAt, now: now, windowMs: windowMs)) item,
    ];
  }

  bool _isRecent(
    Following item, {
    required Map<String, int> airAt,
    required int now,
    required int windowMs,
  }) {
    final released = airAt['${item.identityKey}#${item.latestReleasedEpisode}'];
    if (released == null) return true;
    // 数据里出现「未来时间」说明集号与播出表对不上，按未知处理。
    if (released > now) return true;
    return now - released <= windowMs;
  }

  /// 按「最近 4 条历史」取一次个性推荐（TMDB + 豆瓣，串行）。
  ///
  /// 种子组是**确定性**的（最近 N 条，按 updatedAt 降序）：只要用户没再看新的一集，
  /// 推导出的缓存键就不变，第二次启动命中磁盘缓存、一条请求都不发。
  Future<void> _loadRecommendations() async {
    if (_requested || !mounted) return;
    _requested = true;

    final rows = _state.recentHistory(sourceKey: '');
    final seeds = [
      for (final row in rows.take(_seedLimit))
        _state.recommendationSeedForHistory(row),
    ].where((seed) => seed.title.trim().isNotEmpty && !seed.isAudio).toList();
    // 没有历史就没有「因为你看过…」：推荐位整块不出现（§5 空块隐藏）。
    if (seeds.isEmpty) return;

    final request = RecommendationRequest(
      current: seeds.first,
      history: seeds.skip(1).toList(),
    );
    final loaders = _state.recommendationDependencies.acquire();
    _leased = true;

    // 串行而不是并发：豆瓣侧有 750ms 的请求间隔与 30 分钟冷却，
    // 两条链同时挤，只会一起变慢。
    for (final row in [RecommendationRow.tmdb, RecommendationRow.douban]) {
      final loader = loaders[row];
      if (loader == null) continue;
      try {
        final result = await loader(request);
        if (!mounted) return;
        if (result.items.isNotEmpty) {
          setState(() => _recommendations[row] = result.items);
          // 推荐到了才有身份可解析：补一次元数据（已经解析过的键会被跳过）。
          unawaited(_resolveMeta(_recommendationIdentities()));
        }
      } catch (_) {
        // 推荐是锦上添花：失败就整块隐藏，不弹 toast、不留红条（§5）。
      }
    }
  }

  /// 按 TMDB 身份取图（`services/home_art_service.dart`）。
  ///
  /// 只覆盖**续播**条目：追番记录没有 TMDB 身份，推荐条目本来就带 TMDB 图，
  /// 热门条目来自 360kan 榜单（自带封面）。没有身份的条目一律保留站点海报——
  /// 按标题去 TMDB 搜一遍是 N 次请求，首页首屏付不起这个代价。
  Future<void> _loadArt() async {
    if (_artRequested || !mounted) return;
    _artRequested = true;
    final byKey = <String, TmdbIdentity>{};
    for (final row in _state.recentHistory(sourceKey: '')) {
      final identity = TmdbIdentity.of(
        TmdbMediaType.parse(row.mediaType),
        row.tmdbId,
      );
      if (identity == null) continue;
      byKey[homeHistoryKey(row)] = identity;
    }
    await _resolveMeta(byKey);
  }

  /// 只解析还没解析过的键（历史与推荐可能指向同一部作品，重复解析纯属浪费）。
  Future<void> _resolveMeta(Map<String, TmdbIdentity> byKey) async {
    if (byKey.isEmpty) return;
    final pending = {
      for (final entry in byKey.entries)
        if (!_art.containsKey(entry.key)) entry.key: entry.value,
    };
    if (pending.isEmpty) return;
    final resolved = await HomeMetaService(tmdb: _state.tmdbService)
        .resolve(pending);
    if (!mounted || resolved.isEmpty) return;
    setState(() => _art.addAll(resolved));
  }

  /// 推荐条目也走同一套元数据：它们本来就有 TMDB 身份，`detail` 命中缓存时
  /// 零请求，于是推荐幻灯片同样有类型标签、简介与 16:9 背景（首屏因此能进
  /// 「占满一屏」那档）。只取两条推荐行各自的**前三张**——那是 hero 的预算，
  /// 再多就是替一屏都放不下的条目付请求。
  Map<String, TmdbIdentity> _recommendationIdentities() {
    final byKey = <String, TmdbIdentity>{};
    for (final row in _recommendations.values) {
      for (final entry in row.take(_heroRecommendBudgetForMeta)) {
        final identity = entry.item.identity;
        if (identity == null) continue;
        byKey[entry.key] = identity;
      }
    }
    return byKey;
  }

  /// 热门榜单：电影 / 剧集 / 综艺（与搜索页同一份数据与缓存）。
  ///
  /// 不走 `buildHomeFeed`：它不是本机数据，也不参与重排——直接折成轨道接在后面。
  Future<void> _loadHot() async {
    if (_hotRequested || !mounted) return;
    _hotRequested = true;
    final results = <HotRankCategory, List<SearchSuggestItem>>{};
    for (final category in HotRankCategory.values) {
      try {
        final items = await _state.searchHotRank(category);
        if (items.isNotEmpty) results[category] = items;
      } catch (_) {
        // 榜单是添头：一个类目失败不影响另外两个，也不弹错误。
      }
    }
    if (!mounted || results.isEmpty) return;
    setState(() => _hot.addAll(results));
  }

  /// 首次使用的首屏：热门三榜**轮流**取，凑到 12 条。
  ///
  /// 轮流而不是「先电影取满」：第一次打开的人看到 12 张电影海报，会以为这是个
  /// 电影站；三类交替才说明「这里电影/剧集/综艺都有」。
  List<HomeItem> _hotHeroFallback(List<HomeRail> hot) {
    if (hot.isEmpty) return const [];
    final pools = [for (final rail in hot) rail.items];
    final items = <HomeItem>[];
    for (var round = 0; items.length < _heroMax; round++) {
      var added = false;
      for (final pool in pools) {
        if (round >= pool.length) continue;
        items.add(pool[round]);
        added = true;
        if (items.length >= _heroMax) break;
      }
      if (!added) break;
    }
    return items;
  }

  HomeItem _withArt(HomeItem item) {
    final art = _art[item.key];
    if (art == null) return item;
    return item.copyWith(
      poster: art.poster,
      backdrop: art.backdrop,
      overview: art.overview,
      tags: art.genres,
      // 副信息只在站点没给的时候补：站源写的「2024 · 8.1」是它自己的口径，
      // 两边混着用会出现「2024 · 8.1」和「2024 · 8.6」两种评分来源。
      subtitle: item.subtitle.trim().isEmpty
          ? _metaSubtitle(art)
          : item.subtitle,
    );
  }

  /// 站源没给副信息时，用 TMDB 的年份与评分补一个（同一套「年份 · 评分」口径）。
  String _metaSubtitle(HomeMeta meta) => [
    if (meta.year.isNotEmpty) meta.year,
    if (meta.rating > 0) meta.rating.toStringAsFixed(1),
  ].join(' · ');

  /// 热门轨道，去掉与本机条目重名的（「战狼2」既是续播又是热门时只留续播那条）。
  List<HomeRail> _hotRails({
    required List<HomeItem> hero,
    required List<HomeRail> rails,
  }) {
    if (_hot.isEmpty) return const [];
    final known = {
      for (final item in hero) recommendationTitleKey(item.title),
      for (final rail in rails)
        for (final item in rail.items) recommendationTitleKey(item.title),
    };
    return [
      for (final rail in hotRails(_hot))
        if (rail.items.any(
          (item) => !known.contains(recommendationTitleKey(item.title)),
        ))
          HomeRail(
            kind: rail.kind,
            title: rail.title,
            seeAll: rail.seeAll,
            items: [
              for (final item in rail.items)
                if (!known.contains(recommendationTitleKey(item.title))) item,
            ],
          ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    // 全局（跨源）历史：首页要回答的是「我上次看到哪」，不是「这个站点里我看过什么」。
    final history = _state.recentHistory(sourceKey: '');
    final followings = _recentFollowings(_state.followings);
    final local = buildHomeFeed(history: history, followings: followings);
    final feed = _recommendations.isEmpty
        ? local
        : _merge(
            local,
            buildHomeFeed(
              history: history,
              followings: followings,
              tmdbRecommendations:
                  _recommendations[RecommendationRow.tmdb] ?? const [],
              doubanRecommendations:
                  _recommendations[RecommendationRow.douban] ?? const [],
            ),
          );
    // 元数据优先级的图覆盖站点图（取不到的条目原样保留站点海报）。
    final hero = [for (final item in feed.hero) _withArt(item)];
    final rails = [
      for (final rail in feed.rails)
        HomeRail(
          kind: rail.kind,
          title: rail.title,
          items: [for (final item in rail.items) _withArt(item)],
          seeAll: rail.seeAll,
        ),
    ];
    // 首屏兜底（用户 2026-11-19 问「第一次用的时候海报取什么」）：
    // 没有历史、没有追剧、推荐也还没到时，hero 用**热门榜单**的前 12 条——
    // 于是第一次打开就看到一组真实的海报轮播，而不是一块只会说「还没有内容」
    // 的渐变。点主按钮 = 带着标题去搜索（与热门卡同一条路）。
    //
    // 顺序要紧：先算出 hero，再据此过滤热门轨道——否则首次使用时 hero 里的
    // 12 部片会立刻在下面三条轨道里**原样再出现一遍**。
    final heroItems = hero.isNotEmpty ? hero : _hotHeroFallback(hotRails(_hot));

    // 热门接在本机轨道之后（用户 2026-11-19：用过也照样要给热门），
    // 并去掉 hero 里已经有的条目。
    final hot = _hotRails(hero: heroItems, rails: rails);

    return LayoutBuilder(
      builder: (context, constraints) {
        // 首屏高度按「有没有 16:9 背景图」分两档（见 `homeHeroHeight`）：
        // 有图就占满一屏（用户要的全屏大海报），没图就收到 62%——占满一屏的
        // 纯渐变只会是一块空。
        final heroHeight = homeHeroHeight(
          constraints.maxHeight,
          hasArt: heroItems.any(
            (item) => (item.backdrop ?? '').trim().isNotEmpty,
          ),
        );
        return CustomScrollView(
          key: const ValueKey('home-scroll'),
          slivers: [
            SliverToBoxAdapter(
              child: heroItems.isEmpty
                  ? _HomeEmptyHero(
                      height: heroHeight,
                      hasConfig: _state.hasConfig,
                      onImportConfig: widget.onImportConfig,
                      onOpenBrowse: widget.onOpenBrowse,
                    )
                  : HomeHero(
                      items: heroItems,
                      height: heroHeight,
                      onPrimary: (item) =>
                          _activate(context, item, primary: true),
                      onSecondary: (item) =>
                          _activate(context, item, primary: false),
                    ),
            ),
            for (final rail in [...rails, ...hot])
              SliverToBoxAdapter(
                child: HomeRailView(
                  rail: rail,
                  onTap: (item) => _activate(context, item, primary: false),
                  onSeeAll: switch (rail.seeAll) {
                    HomeSeeAll.history => widget.onOpenHistory,
                    HomeSeeAll.following => widget.onOpenFollowing,
                    null => null,
                  },
                ),
              ),
            const SliverToBoxAdapter(child: SizedBox(height: AppSpace.xxl)),
          ],
        );
      },
    );
  }

  /// 本地 feed 与「带推荐的 feed」合并：**只追加，不驱逐**（§3）。
  ///
  /// 为什么不做 `buildHomeFeed` 里的 I2 替换：那一步只有在「推荐一开始就在」时才
  /// 安全。异步到达时替换会把用户正在看的那一张换掉；而 `take(_heroMax)` 只在末尾
  /// 截断，永远不会动 loca 部分的前缀。
  HomeFeed _merge(HomeFeed local, HomeFeed withRecommendations) {
    if (local.hero.isEmpty) return withRecommendations;
    final known = {for (final item in local.hero) item.key};
    final appended = withRecommendations.hero.where(
      (item) => !known.contains(item.key),
    );
    return HomeFeed(
      hero: [...local.hero, ...appended].take(_heroMax).toList(),
      rails: withRecommendations.rails,
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
        return;
      case HomeItemKind.hot:
        // 热门只有标题：带上它去搜索页，由用户挑站源（首页不做第二条解析链）。
        widget.onSearch(item.title);
        return;
      case HomeItemKind.recommend:
        // 推荐卡在第一版只做展示入口：点主按钮去点播页按标题找片源，
        // 与「首页不放第二条播放链路」的约束一致；精确的三条去向
        // （站点命中 / 导航源 / 纯标题搜索）留在详情页的推荐行里。
        widget.onOpenBrowse();
        return;
    }
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
    return Container(
      key: const ValueKey('home-empty-hero'),
      height: height,
      width: double.infinity,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [scheme.surface, scheme.surfaceContainerLow, scheme.surface],
        ),
      ),
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
    );
  }
}
