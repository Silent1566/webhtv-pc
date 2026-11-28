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
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import '../core/detail_recommendation.dart';
import '../core/push_parser.dart';
import '../core/protocol.dart' show Vod, HeaderRule;
import '../core/following.dart';
import '../core/following_calendar.dart';
import '../core/home_feed.dart';
import '../core/home_hot.dart';
import '../core/image_headers.dart';
import '../core/live_site_keywords.dart';
import '../core/meta_pipeline.dart';
import '../core/meta_source.dart';
import '../core/tmdb_identity.dart';
import '../core/tmdb_title.dart';
import '../services/home_art_service.dart';
import '../services/home_hero_startup_cache.dart';
import '../services/search_suggest_service.dart';
import '../services/storage.dart';
import '../state/app_state.dart';
import '../state/detail_recommendation_state.dart';
import 'glass_dialog.dart';
import 'glass_widgets.dart';
import 'async_action_feedback.dart';
import 'following_actions.dart';
import 'following_air_data.dart';
import 'home_cards.dart';
import 'home_backdrop.dart';
import 'history_cross_source.dart';
import 'history_entry_detail.dart';
import 'home_hero.dart';
import 'home_hero_image_probe.dart';
import 'home_hero_startup_image.dart';
import 'image_header_scope.dart';
import 'poster_image.dart' show posterImageProvider;
import 'playback_resume.dart';
import 'recommendation_detail_route.dart';
import 'recommendation_info_dialog.dart';
import 'search_page.dart';
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

/// 追剧卡片元数据的整轮上限。
///
/// 普通详情默认 8s 够用，但网盘聚合的目录条目要按 `t=` 展开成分享链
/// （实测 2~15s）：不抬上限就永远读不到站源那几项。上限只管整轮——
/// 已解析出的行照旧生效，超时不会整轮作废。
const Duration _followingMetaTimeout = Duration(seconds: 20);

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
  final ValueNotifier<int> _heroIndex = ValueNotifier(0);
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

  List<String> _heroKeys = const [];
  final _heroStartupClock = Stopwatch()..start();
  bool _firstHeroAvailableLogged = false;
  late final HomeHeroImageProbe _heroProbe;
  late final HomeHeroStartupCache _startupCache;
  final _startupEncoder = HomeHeroStartupImageEncoder();
  List<CachedHomeHero> _startupSnapshots = const [];
  String _startupScope = '';
  String _startupSaveKey = '';
  final Set<String> _failedStartupKeys = {};
  final Map<String, HomeItem> _lastDisplayedHeroes = {};
  bool _reserveHeroSlot = true;
  String _heroScanKey = '';
  int _heroScanGeneration = 0;
  final Set<String> _heroInspected = {};
  final Map<String, HomeMeta> _heroCandidateMeta = {};
  final Map<String, String> _heroQualified = {};
  final List<String> _heroAcceptedOrder = [];
  bool _heroScanRunning = false;
  final Map<String, Future<TmdbItem?>> _heroMatches = {};
  final Map<String, Future<Vod?>> _heroSources = {};
  final Map<String, Future<void>> _railMetaPending = {};

  late final _recommendationFeedback =
      _state.recommendationDependencies.feedback;

  void _onRecommendationFeedback() {
    if (mounted) setState(() {});
  }

  /// 已到达的推荐：行 → 条目。空表示还没到（或失败后永远不来）。
  final Map<RecommendationRow, List<RecommendationEntry>> _recommendations = {};

  /// 按 TMDB 身份取回的高清图：HomeItem.key → 图。空表示还没到。
  final Map<String, HomeMeta> _art = {};
  String _recommendationMetaKey = '';
  int _recommendationMetaGeneration = 0;
  final Map<String, HomeMeta> _followingMeta = {};
  String _followingMetaKey = '';
  int _followingMetaGeneration = 0;

  final Map<String, HomeMeta> _resumeMeta = {};
  String _resumeMetaKey = '';
  int _resumeMetaGeneration = 0;

  /// 热门榜单：类目 → 条目（360kan，搜索页同一份数据）。
  final Map<HotRankCategory, List<SearchSuggestItem>> _hot = {};

  bool _requested = false;
  bool _hotRequested = false;
  bool _airRequested = false;
  bool _leased = false;

  /// 追剧的播出时间（TMDB，6h 缓存）：用来判断「近 48 小时有没有更新」。
  FollowingAirData? _air;
  List<FollowingAirTime> _airTimes = const [];

  AppState get _state => widget.state;

  @override
  void initState() {
    super.initState();
    _heroProbe = HomeHeroImageProbe(loader: widget.heroImageLoader);
    _startupCache = HomeHeroStartupCache(
      directory: Directory(_state.paths.cacheDir),
    );
    _recommendationFeedback.addListener(_onRecommendationFeedback);
    // 放到首帧之后：第一帧必须是本地内容，不能被网络挡住（§5「不显示骨架」）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadRecommendations();
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
    _startupEncoder.dispose();
    _heroProbe.dispose();
    _heroScanGeneration++;
    _stopWatchingHeroBackdrop();
    _heroIndex.dispose();
    _recommendationFeedback.removeListener(_onRecommendationFeedback);
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
      await air.refresh(items, includeNetworks: false);
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
      blockedTitles: _recommendationFeedback.blockedTitles,
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
          _ensureRecommendationMeta();
        }
      } catch (_) {
        // 推荐是锦上添花：失败就整块隐藏，不弹 toast、不留红条（§5）。
      }
    }
  }

  /// 直播站的 site key 集合（见 `core/live_site_keywords.dart`）。
  ///
  /// 缓存是必须的：`ConfigRecord.config` 会把整份配置 JSON（最大的那份 300 KB 以上）
  /// 解一遍，而首页每次 `setState` 都会重建。配置列表与关键词不变时直接复用上一次的
  /// 结果，只有真的换了配置或在设置里改了关键词才重算。
  List<ConfigRecord>? _liveKeysConfigs;
  List<String> _liveKeysKeywords = const [];
  Set<String> _liveSiteKeysCache = const {};

  Set<String> _liveSiteKeys() {
    final configs = _state.configs;
    final keywords = _state.liveSiteKeywords;
    if (identical(configs, _liveKeysConfigs) &&
        listEquals(keywords, _liveKeysKeywords)) {
      return _liveSiteKeysCache;
    }
    final keys = liveSiteKeysFor(
      sourceNames: [for (final source in _state.liveSources) source.name],
      siteNames: {
        // 跨配置查名字：历史行可能来自别的配置（`recentHistory(sourceKey: '')`）。
        for (final record in configs)
          for (final site in record.config?.sites ?? const [])
            site.key: site.name,
      },
      keywords: keywords,
    );
    _liveKeysConfigs = configs;
    _liveKeysKeywords = keywords;
    _liveSiteKeysCache = keys;
    return keys;
  }

  /// 输入身份/字段规则变化后重算；详情返回时也失效，不能永久记住首次缺图的结果。
  void _ensureResumeMeta(HomeFeed feed) {
    final rows = {
      // 未绑定身份只匹配 hero 预算；轨道中已有身份的条目仍可复用元数据缓存补图。
      for (final item in [
        ...feed.hero,
        for (final rail in feed.rails)
          for (final item in rail.items)
            if (item.history?.hasTmdbIdentity ?? false) item,
      ])
        if (item.history != null) item.key: item.history!,
    };
    final state = _state;
    final pipeline = state.metaPipeline;
    final enabled = state.externalMetaEnabled;
    final overrides = state.metaOverrides;
    final key = jsonEncode([
      identityHashCode(state),
      state.activeSourceKey,
      state.tmdbConfigRevision,
      pipeline.toJson(),
      enabled,
      for (final entry in rows.entries)
        [
          entry.key,
          entry.value.tmdbId,
          entry.value.mediaType,
          entry.value.vodName,
          entry.value.vodPic,
          entry.value.vodYear,
          overrides.of(entry.value.vodId)?.key,
        ],
    ]);
    if (key == _resumeMetaKey) return;
    _resumeMetaKey = key;
    final generation = ++_resumeMetaGeneration;
    _resumeMeta.clear();
    if (rows.isEmpty) return;
    final completed = Completer<void>();
    for (final key in rows.keys) {
      _railMetaPending[key] = completed.future;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      bool current() => mounted && generation == _resumeMetaGeneration;
      if (!current()) {
        if (!completed.isCompleted) completed.complete();
        return;
      }
      final resolved = await HomeMetaService(tmdb: state.tmdbService)
          .resolveHistory(
            rows.values,
            match: (row) async {
              if (row.siteKey == pushSiteKey) {
                return _heroHistoryMatch(row, current);
              }
              return _heroHistoryMatch(row, current);
            },
            source: _heroHistorySource,
            siteName: (row) =>
                (state.configForSourceKey(row.sourceKey) ??
                        state.effectiveConfig)
                    ?.sites
                    .where((site) => site.key == row.siteKey)
                    .firstOrNull
                    ?.name ??
                '',
            pipeline: pipeline,
            external: enabled ? state.externalMetaService : null,
            pinned: (row) => overrides.of(row.vodId),
            isCurrent: current,
          );
      if (!completed.isCompleted) completed.complete();
      if (!current() || resolved.isEmpty) return;
      setState(() => _resumeMeta.addAll(resolved));
    });
  }

  void _invalidateMetadata() {
    if (!mounted) return;
    setState(() {
      _heroScanKey = '';
      _heroScanGeneration++;
      _heroProbe.clear();
      _heroMatches.clear();
      _heroSources.clear();
      _railMetaPending.clear();
      _resumeMetaKey = '';
      _resumeMetaGeneration++;
      _resumeMeta.clear();
      _followingMetaKey = '';
      _followingMetaGeneration++;
      _followingMeta.clear();
      _art.clear();
      _recommendationMetaKey = '';
      _recommendationMetaGeneration++;
    });
    _ensureRecommendationMeta();
  }

  void _ensureRecommendationMeta() {
    final entries = {
      for (final row in _recommendations.values)
        for (final entry in row.take(_heroRecommendBudgetForMeta))
          entry.key: entry,
    };
    final state = _state;
    final pipeline = state.metaPipeline;
    final key = jsonEncode([
      identityHashCode(state),
      state.activeSourceKey,
      state.tmdbConfigRevision,
      pipeline.toJson(),
      for (final entry in entries.values)
        [
          entry.key,
          entry.item.title,
          entry.item.posterUrl,
          entry.item.backdropUrl,
          entry.item.overview,
          entry.item.subtitle,
        ],
    ]);
    if (key == _recommendationMetaKey) return;
    _recommendationMetaKey = key;
    final generation = ++_recommendationMetaGeneration;
    _art.clear();
    if (entries.isEmpty) return;
    final completed = Completer<void>();
    for (final key in entries.keys) {
      _railMetaPending[key] = completed.future;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      bool current() => mounted && generation == _recommendationMetaGeneration;
      if (!current()) {
        if (!completed.isCompleted) completed.complete();
        return;
      }
      // 推荐本来自带 TMDB 图：只走 TMDB 字段，不引外部源（豆瓣有 750ms 串行间隔，
      // 会让 hero 分批到），也不做 pin（pin 以 vodId 为键，推荐没有）。
      final resolved = await HomeMetaService(tmdb: state.tmdbService)
          .resolveRecommendations(
            entries.values,
            pipeline: pipeline,
            isCurrent: current,
          );
      if (!completed.isCompleted) completed.complete();
      if (!current() || resolved.isEmpty) return;
      setState(() => _art.addAll(resolved));
    });
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
    for (var round = 0; items.length < 120; round++) {
      var added = false;
      for (final pool in pools) {
        if (round >= pool.length) continue;
        items.add(pool[round]);
        added = true;
        if (items.length >= 120) break;
      }
      if (!added) break;
    }
    return items;
  }

  Future<TmdbItem?> _heroHistoryMatch(
    PlaybackHistory row,
    bool Function() current,
  ) {
    final key = jsonEncode([
      homeHistoryKey(row),
      row.tmdbId,
      row.mediaType,
      _state.tmdbConfigRevision,
      row.vodName,
    ]);
    return _heroMatches.putIfAbsent(key, () async {
      if (row.siteKey == pushSiteKey) {
        return _state.pushMatchedItem(vodId: row.vodId, title: row.vodName);
      }
      return _state.historyTmdbItem(row, isCurrent: current);
    });
  }

  Future<Vod?> _heroHistorySource(PlaybackHistory row) => _heroSources
      .putIfAbsent(homeHistoryKey(row), () => _state.historyVod(row));

  bool _hasResolvedMeta(HomeItem item) =>
      _heroCandidateMeta.containsKey(item.key) ||
      _resumeMeta.containsKey(item.key) ||
      _followingMeta.containsKey(item.key) ||
      _art.containsKey(item.key);

  Future<void> _loadHeroCandidateMeta(
    HomeItem item,
    bool Function() current,
  ) async {
    final pending = _railMetaPending[item.key];
    if (pending != null) await pending;
    if (_hasResolvedMeta(item) || !current()) return;
    final state = _state;
    final service = HomeMetaService(tmdb: state.tmdbService);
    final pipeline = state.metaPipeline;
    final external = state.externalMetaEnabled
        ? state.externalMetaService
        : null;
    final overrides = state.metaOverrides;
    Map<String, HomeMeta> resolved;
    if (item.history case final row?) {
      resolved = await service.resolveHistory(
        [row],
        pipeline: pipeline,
        match: (entry) => _heroHistoryMatch(entry, current),
        source: _heroHistorySource,
        siteName: (entry) =>
            (state.configForSourceKey(entry.sourceKey) ?? state.effectiveConfig)
                ?.sites
                .where((site) => site.key == entry.siteKey)
                .firstOrNull
                ?.name ??
            '',
        external: external,
        pinned: (entry) => overrides.of(entry.vodId),
        isCurrent: current,
      );
    } else if (item.following case final row?) {
      resolved = await service.resolveFollowings(
        [row],
        pipeline: pipeline,
        match: state.followingTmdbItem,
        source: state.followingVod,
        siteName: (entry) =>
            state.siteInActiveSource(entry.siteKey)?.name ?? '',
        external: external,
        pinned: (entry) => overrides.of(entry.vodId),
        timeout: _followingMetaTimeout,
        isCurrent: current,
      );
    } else if (item.entry case final entry?) {
      resolved = await service.resolveRecommendations(
        [entry],
        pipeline: pipeline,
        isCurrent: current,
      );
    } else {
      return;
    }
    if (current()) _heroCandidateMeta.addAll(resolved);
  }

  String _startupScopeFor(List<HeaderRule> rules) {
    // 只落盘摘要，不把API密钥、cookie或配置地址写进快照索引。
    return sha256
        .convert(
          utf8.encode(
            jsonEncode([
              _state.activeSourceKey,
              _state.metaPipeline.toJson(),
              _state.externalMetaEnabled,
              _state.metaOverrides.toJson(),
              _state.liveSiteKeywords,
              _state.tmdbConfig.enabled,
              _state.tmdbConfig.imageBase,
              _state.tmdbConfig.backdropBase,
              _state.tmdbConfig.enabledSites,
              _state.tmdbConfig.disabledSites,
              _state.tmdbConfig.allowedSites,
              for (final rule in rules)
                [rule.host, rule.header.asRequestHeaders],
            ]),
          ),
        )
        .toString();
  }

  void _restoreStartup(String scope) {
    if (_startupScope == scope) return;
    _startupEncoder.clear();
    _startupScope = scope;
    _startupSaveKey = '';
    _startupSnapshots = _startupCache.read(scope);
    _state.log.info(
      'event=cache_restore usable=${_startupSnapshots.length} '
      'result=${_startupSnapshots.isEmpty ? 'no_usable_snapshot' : 'hit'} '
      'elapsedMs=${_heroStartupClock.elapsedMilliseconds}',
      scope: 'home',
    );
    _failedStartupKeys.clear();
    _lastDisplayedHeroes.clear();
  }

  String _startupBindingKey(HomeItem item) => sha256
      .convert(
        utf8.encode(
          jsonEncode([item.key, item.history?.tmdbId, item.history?.mediaType]),
        ),
      )
      .toString();

  List<HomeItem> _displayHeroItems(List<HomeItem> candidates) {
    final byBinding = {
      for (final item in candidates) _startupBindingKey(item): item,
    };
    final byKey = {for (final item in candidates) item.key: item};
    final displayed = <HomeItem>[];
    final claimer = HomeWorkClaimer();
    final used = <String>{};
    void add(HomeItem item) {
      if (displayed.length >= _heroMax ||
          !used.add(item.key) ||
          !claimer.claim(item)) {
        return;
      }
      displayed.add(item);
    }

    // 快照只恢复展示字段，按钮仍使用当前原始历史，不能按缓存中的旧进度起播。
    for (final snapshot in _startupSnapshots) {
      final raw = byBinding[snapshot.key];
      if (raw == null || _failedStartupKeys.contains(raw.key)) continue;
      final fresh = _heroQualified[raw.key];
      add(
        fresh != null
            ? _withArt(raw).copyWith(backdrop: fresh)
            : raw.copyWith(
                title: snapshot.title,
                subtitle: snapshot.subtitle,
                overview: snapshot.overview,
                tags: snapshot.tags,
                backdrop: Uri.file(snapshot.filePath).toString(),
              ),
      );
    }
    // 后台扫描开始时不清空本会话已显示成功的推荐；只在同高区域替换内容。
    for (final old in _lastDisplayedHeroes.values) {
      final raw = byKey[old.key];
      if (raw == null ||
          _failedStartupKeys.contains(old.key) ||
          _startupBindingKey(old) != _startupBindingKey(raw)) {
        continue;
      }
      final fresh = _heroQualified[old.key];
      add(
        fresh == null
            ? raw.copyWith(
                title: old.title,
                subtitle: old.subtitle,
                overview: old.overview,
                tags: old.tags,
                backdrop: old.backdrop,
              )
            : _withArt(raw).copyWith(backdrop: fresh),
      );
    }
    for (final key in _heroAcceptedOrder) {
      final raw = byKey[key];
      if (raw != null) {
        add(_withArt(raw).copyWith(backdrop: _heroQualified[key]));
      }
    }
    _lastDisplayedHeroes
      ..clear()
      ..addEntries(displayed.map((item) => MapEntry(item.key, item)));
    if (!_firstHeroAvailableLogged && displayed.isNotEmpty) {
      _firstHeroAvailableLogged = true;
      final local =
          Uri.tryParse(displayed.first.backdrop ?? '')?.scheme == 'file';
      _state.log.info(
        'event=first_available source=${local ? 'local_cache' : 'verified_image'} '
        'visible=${displayed.length} elapsedMs=${_heroStartupClock.elapsedMilliseconds}',
        scope: 'home',
      );
    }
    return displayed;
  }

  void _saveStartupImages(List<HomeItem> candidates) {
    final byKey = {for (final item in candidates) item.key: item};
    final picks = [
      for (final key in _heroAcceptedOrder.take(3))
        if (byKey[key] case final item?)
          _withArt(item).copyWith(backdrop: _heroQualified[key]),
    ];
    if (picks.isEmpty) return;
    final scope = _startupScope;
    final key = jsonEncode([
      scope,
      for (final item in picks)
        [
          item.key,
          item.backdrop,
          item.title,
          item.subtitle,
          item.overview,
          item.tags,
        ],
    ]);
    if (key == _startupSaveKey) return;
    _startupSaveKey = key;
    final generation = _heroScanGeneration;
    final rules =
        ImageHeaderScope.maybeRules(context) ??
        _state.effectiveConfig?.headers ??
        const [];
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      bool current() =>
          mounted &&
          generation == _heroScanGeneration &&
          scope == _startupScope &&
          key == _startupSaveKey;
      if (!current()) return;
      final saved = <HomeHeroStartupCandidate>[];
      for (final item in picks) {
        final url = item.backdrop!;
        final headers = imageHeadersFor(rules, url).asRequestHeaders;
        final bytes = await _startupEncoder.encode(
          url,
          headers: headers.isEmpty ? null : headers,
        );
        if (!current()) return;
        if (bytes == null) continue;
        saved.add(
          HomeHeroStartupCandidate(
            key: _startupBindingKey(item),
            sourceUrl: url,
            title: item.title,
            bytes: bytes,
            subtitle: item.subtitle,
            overview: item.overview,
            tags: item.tags,
          ),
        );
      }
      if (current() && saved.isNotEmpty) {
        try {
          await _startupCache.save(scope, saved);
          if (!current()) return;
          final readable = _startupCache.read(scope).length;
          _state.log.info(
            'event=cache_save requested=${picks.length} encoded=${saved.length} '
            'readable=$readable result=${readable == 0 ? 'no_usable_snapshot' : 'ready'}',
            scope: 'home',
          );
          if (readable == 0) _startupSaveKey = '';
        } catch (_) {
          // 可删缓存写入失败不影响已经显示的图片。
          if (current()) {
            _startupSaveKey = '';
            _state.log.warning(
              'event=cache_save result=write_failed',
              scope: 'home',
            );
          }
        }
      } else if (current()) {
        // 编码失败不是永久完成；下一次有效重建可以重试，但不制造自动重试循环。
        _startupSaveKey = '';
        _state.log.info(
          'event=cache_save requested=${picks.length} encoded=0 result=no_encoded_image',
          scope: 'home',
        );
      }
    });
  }

  /// 图片真正通过解码和像素门槛才进轮播；其余作品仍保留在各自轨道。
  void _ensureHdHero(List<HomeItem> candidates) {
    final state = _state;
    final rules =
        ImageHeaderScope.maybeRules(context) ??
        state.effectiveConfig?.headers ??
        const [];
    final headerIdentity = [
      for (final rule in rules) [rule.host, rule.header.asRequestHeaders],
    ];
    _restoreStartup(_startupScopeFor(rules));
    final key = jsonEncode([
      identityHashCode(state),
      state.activeSourceKey,
      state.tmdbConfigRevision,
      state.metaPipeline.toJson(),
      state.externalMetaEnabled,
      headerIdentity,
      for (final item in candidates)
        [
          item.key,
          item.title,
          item.poster,
          item.backdrop,
          item.history?.tmdbId,
          item.history?.mediaType,
          item.history?.vodYear,
          item.following?.metadataUpdatedAtMs,
          item.following?.updatedAtMs,
          state.metaOverrides
              .of(item.history?.vodId ?? item.following?.vodId ?? '')
              ?.key,
        ],
    ]);
    if (key != _heroScanKey) {
      _heroScanKey = key;
      _startupSaveKey = '';
      _heroScanGeneration++;
      _heroScanRunning = false;
      _heroInspected.clear();
      _heroCandidateMeta.clear();
      _heroQualified.clear();
      _heroAcceptedOrder.clear();
      _heroProbe.clear();
      _heroMatches.clear();
      _heroSources.clear();
    }
    if (_heroScanRunning || _heroAcceptedOrder.length >= _heroMax) return;
    final queue = candidates
        .where((item) => !_heroInspected.contains(item.key))
        .toList();
    if (queue.isEmpty) return;
    _heroScanRunning = true;
    WidgetsBinding.instance.ensureVisualUpdate();
    final generation = _heroScanGeneration;
    final scanClock = Stopwatch()..start();
    _state.log.info(
      'event=scan_start generation=$generation candidates=${candidates.length} pending=${queue.length}',
      scope: 'home',
    );
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      bool current() => mounted && generation == _heroScanGeneration;
      if (!current()) return;
      var next = 0;
      Future<(HomeItem, String?)> inspect(HomeItem item) async {
        _heroInspected.add(item.key);
        try {
          await _loadHeroCandidateMeta(item, current);
          if (!current() ||
              state.metaPipeline.orderOf(MetaField.backdrop).isEmpty) {
            return (item, null);
          }
          final enriched = _withArt(item);
          final meta =
              _heroCandidateMeta[item.key] ??
              _resumeMeta[item.key] ??
              _followingMeta[item.key] ??
              _art[item.key];
          final urls = <String>{
            if ((enriched.backdrop ?? '').trim().isNotEmpty)
              enriched.backdrop!.trim(),
            ...?meta?.backdrops,
            if ((enriched.poster ?? '').trim().isNotEmpty &&
                state.metaPipeline
                    .orderOf(MetaField.backdrop)
                    .contains(MetaSourceKind.source))
              enriched.poster!.trim(),
          };
          for (final url in urls) {
            if (!current()) return (item, null);
            final headers = imageHeadersFor(rules, url).asRequestHeaders;
            final evidence = await _heroProbe.check(
              url,
              headers: headers.isEmpty ? null : headers,
            );
            if (evidence?.isEligible ?? false) return (item, url);
          }
        } catch (_) {
          // 一张图或一部作品失败不阻断后续候选。
        }
        return (item, null);
      }

      // 两张并发检查，但按候选原序提交，不能让下载更快的后排作品抢走前排位置。
      final candidatesByKey = {for (final item in candidates) item.key: item};
      while (current() &&
          next < queue.length &&
          _heroAcceptedOrder.length < _heroMax) {
        final remaining = _heroMax - _heroAcceptedOrder.length;
        final batch = queue
            .skip(next)
            .take(remaining < 2 ? remaining : 2)
            .toList();
        next += batch.length;
        final checked = await Future.wait(batch.map(inspect));
        if (!current()) return;
        setState(() {
          final claimer = HomeWorkClaimer();
          for (final accepted in _heroAcceptedOrder) {
            final item = candidatesByKey[accepted];
            if (item != null) claimer.claim(_withArt(item));
          }
          for (final (item, url) in checked) {
            if (url == null || _heroAcceptedOrder.length >= _heroMax) continue;
            if (!claimer.claim(_withArt(item))) continue;
            _heroQualified[item.key] = url;
            _failedStartupKeys.remove(item.key);
            _heroAcceptedOrder.add(item.key);
          }
        });
      }
      if (!current()) return;
      setState(() => _heroScanRunning = false);
      _state.log.info(
        'event=scan_complete generation=$generation inspected=$next '
        'accepted=${_heroAcceptedOrder.length} elapsedMs=${scanClock.elapsedMilliseconds}',
        scope: 'home',
      );
      WidgetsBinding.instance.ensureVisualUpdate();
    });
  }

  void _ensureFollowingMeta(HomeFeed feed) {
    final items = {
      for (final item in [
        ...feed.hero,
        for (final rail in feed.rails) ...rail.items,
      ])
        if (item.following != null) item.key: item.following!,
    }.values.take(_heroMax).toList();
    final state = _state;
    final pipeline = state.metaPipeline;
    final enabled = state.externalMetaEnabled;
    final overrides = state.metaOverrides;
    final siteNames = {
      for (final item in items)
        item.siteKey: state.siteInActiveSource(item.siteKey)?.name ?? '',
    };
    final key = jsonEncode([
      identityHashCode(state),
      state.activeSourceKey,
      state.tmdbConfigRevision,
      pipeline.toJson(),
      enabled,
      for (final item in items)
        [
          item.identityKey,
          item.vodName,
          item.vodPic,
          item.metadataUpdatedAtMs,
          item.updatedAtMs,
          overrides.of(item.vodId)?.key,
        ],
    ]);
    if (key == _followingMetaKey) return;
    _followingMetaKey = key;
    final generation = ++_followingMetaGeneration;
    _followingMeta.clear();
    if (items.isEmpty) return;
    final completed = Completer<void>();
    for (final item in items) {
      _railMetaPending[item.identityKey] = completed.future;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || generation != _followingMetaGeneration) {
        if (!completed.isCompleted) completed.complete();
        return;
      }
      final resolved = await HomeMetaService(tmdb: state.tmdbService)
          .resolveFollowings(
            items,
            match: state.followingTmdbItem,
            pipeline: pipeline,
            external: enabled ? state.externalMetaService : null,
            pinned: (item) => overrides.of(item.vodId),
            source: state.followingVod,
            siteName: (item) => siteNames[item.siteKey],
            timeout: _followingMetaTimeout,
            isCurrent: () => mounted && generation == _followingMetaGeneration,
          );
      if (!completed.isCompleted) completed.complete();
      if (!mounted ||
          generation != _followingMetaGeneration ||
          resolved.isEmpty) {
        return;
      }
      setState(() => _followingMeta.addAll(resolved));
    });
  }

  HomeItem _withArt(HomeItem item) {
    final pipeline = _state.metaPipeline;
    final hidePoster = pipeline.orderOf(MetaField.poster).isEmpty;
    final hideBackdrop = pipeline.orderOf(MetaField.backdrop).isEmpty;
    final art =
        _heroCandidateMeta[item.key] ??
        _resumeMeta[item.key] ??
        _followingMeta[item.key] ??
        _art[item.key];
    final overview = pipeline.orderOf(MetaField.overview).isEmpty
        ? ''
        : _firstNonEmpty([art?.overview]);
    if (art == null) {
      // 没有解析结果时也要按当前规则清掉被停用的字段：站点年份/评分不能借这个
      // 分支复活（与上面 poster/backdrop 的口径一致）。
      return item.copyWith(
        hidePoster: hidePoster,
        hideBackdrop: hideBackdrop,
        overview: overview,
        subtitle: pipeline.orderOf(MetaField.releaseDate).isEmpty ? '' : null,
      );
    }
    // 来源已由管线选定；不能再要求必须启用 TMDB 才接受豆瓣/站源的标题。
    final metaTitle = pipeline.orderOf(MetaField.title).isNotEmpty
        ? _firstNonEmpty([art.title])
        : null;
    return item.copyWith(
      title: metaTitle,
      poster: art.poster,
      backdrop: art.backdrop,
      hidePoster: hidePoster,
      hideBackdrop: hideBackdrop,
      overview: overview,
      tags: art.genres,
      subtitle: _metaSubtitle(art),
    );
  }

  /// 站源没给副信息时，用 TMDB 的年份与评分补一个（同一套「年份 · 评分」口径）。
  String _metaSubtitle(HomeMeta meta) => [
    if (_state.metaPipeline.orderOf(MetaField.releaseDate).isNotEmpty &&
        meta.year.isNotEmpty)
      meta.year,
    if (_state.metaPipeline.orderOf(MetaField.rating).isNotEmpty &&
        meta.rating > 0)
      meta.rating.toStringAsFixed(1),
  ].join(' · ');

  /// 取第一个非空串；都为空时返回 null（`HomeItem.copyWith` 据此保留原值）。
  String? _firstNonEmpty(List<String?> values) {
    for (final value in values) {
      final trimmed = (value ?? '').trim();
      if (trimmed.isNotEmpty) return trimmed;
    }
    return null;
  }

  /// 热门轨道，去掉与本机条目重名的（「战狼2」既是续播又是热门时只留续播那条）。
  List<HomeRail> _hotRails({
    required List<HomeItem> hero,
    required List<HomeRail> rails,
  }) {
    if (_hot.isEmpty) return const [];
    final known = {
      for (final item in hero) homeWorkKey(item.title),
      for (final rail in rails)
        for (final item in rail.items) homeWorkKey(item.title),
    };
    return [
      for (final rail in hotRails(_hot))
        if (rail.items.any((item) => !known.contains(homeWorkKey(item.title))))
          HomeRail(
            kind: rail.kind,
            title: rail.title,
            seeAll: rail.seeAll,
            items: [
              for (final item in rail.items)
                if (!known.contains(homeWorkKey(item.title))) item,
            ],
          ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    // 全局（跨源）历史：首页要回答的是「我上次看到哪」，不是「这个站点里我看过什么」。
    final history = _state.recentHistory(sourceKey: '');
    final followings = _recentFollowings(_state.followings);
    // 直播没有可续播的时间轴（用户 2026-11-25 图一）：写入侧已经不再落历史，但旧库
    // 里还有这类行，首页读到的是跨源全量历史，所以这里再挡一次。
    //
    // 判据不只「直播源名」：真实配置里还有把直播站接成**普通站点**的情况（`Douyu`
    // 在配置 38 里就是 type 3 的站点，名字「🌇｜斗鱼｜直播」），它的播放走通用详情入口，
    // 靠 `isLive` 拦不住。站点/历史行都没有「直播」字段，于是按站点名与键匹配可配置的
    // 关键词（默认「直播」「Live」，设置 → 直播 → 直播站识别里可增删）。
    final liveSiteKeys = _liveSiteKeys();
    final local = buildHomeFeed(
      history: history,
      followings: followings,
      liveSiteKeys: liveSiteKeys,
    );
    final blocked = _recommendationFeedback.blockedTitles;
    List<RecommendationEntry> recommended(RecommendationRow row) => [
      for (final entry
          in _recommendations[row] ?? const <RecommendationEntry>[])
        if (!blocked.contains(recommendationTitleKey(entry.item.title))) entry,
    ];
    final feed = _recommendations.isEmpty
        ? local
        : _merge(
            local,
            buildHomeFeed(
              history: history,
              followings: followings,
              liveSiteKeys: liveSiteKeys,
              tmdbRecommendations: recommended(RecommendationRow.tmdb),
              doubanRecommendations: recommended(RecommendationRow.douban),
            ),
          );
    _ensureFollowingMeta(feed);
    _ensureRecommendationMeta();
    // 续播条目没存 TMDB 身份时补一次匹配：否则 hero 只有竖版海报、没有简介。
    _ensureResumeMeta(feed);
    // 元数据优先级的图覆盖站点图（取不到的条目原样保留站点海报）。
    //
    // 换图会顺手把标题换成刮削名（`_withArt`）：「《那一夜…》百度云网盘…」于是
    // 变成「那一夜，我怀了社长的孩子」，与另一条更干净的记录撞在一起。投影层收过
    // 一次，但那一遍比的是站点名，所以这里按**作品**再收一次；hero 与轨道共用同一个
    // 认领器，跨轨道的重复也一并挡掉（用户 2026-11-25 图三/图四）。
    // 轨道之间共用一份认领，但**不与 hero 共用**：hero 是轨道的子集，同一部作品允许
    // 在自己的轨道里再出现一次（02 §1 I4）。共用会把 hero 的条目从它自己的轨道里删掉
    // ——只有一条续播/推荐时，整条轨道连同「查看全部」入口都会消失。
    final railClaimer = HomeWorkClaimer();
    final rails = <HomeRail>[];
    for (final rail in feed.rails) {
      final items = <HomeItem>[];
      for (final item in rail.items) {
        final art = _withArt(item);
        if (railClaimer.claim(art)) items.add(art);
      }
      // 被去重收空的轨道不画：只剩一个标题的轨道比没有更糟。
      if (items.isEmpty) continue;
      rails.add(
        HomeRail(
          kind: rail.kind,
          title: rail.title,
          items: items,
          seeAll: rail.seeAll,
        ),
      );
    }
    final candidates = homeHeroCandidates(
      feed,
      hot: _hotHeroFallback(hotRails(_hot)),
    );
    _ensureHdHero(candidates);
    final heroItems = _displayHeroItems(candidates);
    _saveStartupImages(candidates);
    final selectedKey = _heroKeys.isEmpty
        ? null
        : _heroKeys[_heroIndex.value % _heroKeys.length];
    final nextKeys = [for (final item in heroItems) item.key];
    if (!listEquals(_heroKeys, nextKeys)) {
      final nextIndex = selectedKey == null
          ? -1
          : nextKeys.indexOf(selectedKey);
      _heroKeys = nextKeys;
      _heroIndex.value = nextIndex < 0 ? 0 : nextIndex;
    }

    // 热门接在本机轨道之后（用户 2026-11-19：用过也照样要给热门），
    // 并去掉 hero 里已经有的条目。
    // 只过滤hero：热门轨道也不因作品是否有高清宽图而增删。
    final hot = _hotRails(hero: const [], rails: rails);
    final hasRails = rails.isNotEmpty || hot.isNotEmpty;
    // 冷启动bootstrap尚未恢复历史时也先预留，不能等异步列表出现才加高。
    if (candidates.isNotEmpty || heroItems.isNotEmpty || hasRails) {
      _reserveHeroSlot = true;
    }

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
                  valueListenable: _heroIndex,
                  builder: (context, index, _) {
                    void onImageError(HomeItem item) {
                      final url = item.backdrop;
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (!mounted ||
                            _lastDisplayedHeroes[item.key]?.backdrop != url) {
                          return;
                        }
                        setState(() {
                          _heroQualified.remove(item.key);
                          _heroAcceptedOrder.remove(item.key);
                          _failedStartupKeys.add(item.key);
                          _lastDisplayedHeroes.remove(item.key);
                        });
                      });
                      WidgetsBinding.instance.ensureVisualUpdate();
                    }

                    final backdrop = HomeBackdrop(
                      items: heroItems,
                      index: index,
                      onImageError: onImageError,
                    );
                    if (widget.onHeroBackdropChanged == null) return backdrop;
                    final item = heroItems.isEmpty
                        ? null
                        : heroItems[index % heroItems.length];
                    _watchHeroBackdrop(context, item, backdrop, onImageError);
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
                      ? (_reserveHeroSlot
                            ? _HomeHeroStartupPlaceholder(
                                height: heroHeight,
                                loading: _heroScanRunning,
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
                          onIndexChanged: (index) => _heroIndex.value = index,
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

  /// 本地 feed 与「带推荐的 feed」合并：**只追加，不驱逐**（§3）。
  ///
  /// 为什么不做 `buildHomeFeed` 里的 I2 替换：那一步只有在「推荐一开始就在」时才
  /// 安全。异步到达时替换会把用户正在看的那一张换掉；而 `take(_heroMax)` 只在末尾
  /// 截断，永远不会动 loca 部分的前缀。
  /// 推荐后到：只往 hero 尾部追加、不驱逐已有条目（§3「追加不重排」）。
  ///
  /// 判据是**作品**而不是 `key`：本站历史里叫「那一夜我怀了社长的孩子」、推荐里
  /// 叫「那一夜，我怀了社长的孩子」时 `key` 不同，却是同一部剧（用户 2026-11-25）。
  HomeFeed _merge(HomeFeed local, HomeFeed withRecommendations) {
    if (local.hero.isEmpty) return withRecommendations;
    final claimer = HomeWorkClaimer();
    final hero = [
      for (final item in [...local.hero, ...withRecommendations.hero])
        if (claimer.claim(item)) item,
    ].take(_heroMax).toList();
    return HomeFeed(hero: hero, rails: withRecommendations.rails);
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
        _invalidateMetadata();
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
        _invalidateMetadata();
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
        _invalidateMetadata();
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
    return showRecommendationInfo(
      context,
      info: _recommendationInfo(item),
      onOpen: () => unawaited(
        item.entry?.item.identity == null
            ? _searchRecommendation(item.title)
            : _activate(context, item, primary: true),
      ),
      onNotInterested: () async => _recommendationFeedback.block(item.title),
    );
  }

  Future<void> _showHotInfo(HomeItem item, HomeRailKind kind) {
    final category = switch (kind) {
      HomeRailKind.hotMovie => HotRankCategory.movie,
      HomeRailKind.hotTv => HotRankCategory.series,
      HomeRailKind.hotVariety => HotRankCategory.variety,
      _ => throw ArgumentError.value(kind),
    };
    final source = _hot[category]
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
