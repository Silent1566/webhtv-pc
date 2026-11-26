/// 首页的**会话级**推荐状态：只要应用没退出，用户切走再回来看到的必须是同一份
/// 已就绪内容。
///
/// 为什么不能留在 `HomePage.State` 里：外壳每次切页都会替换页面子树
/// （`ui/app_motion.dart` 的 `KeyedSubtree`），页面 State 随之销毁。原先「已加载
/// 12 张 + 已通过高清资格 + 已选到第 8 张」只活在 State 里，返回首页就得从零
/// 重新取数、重新解码、重新攒列表——用户看到的就是「又要等一遍」。
///
/// 分工：本模块拥有**数据**（推荐、热门、播出时间、元数据、图片资格、列表顺序、
/// 当前作品、在途任务）；`HomePage` 只负责画和跳转。页面销毁不取消这里的任务，
/// 结果照常写回，返回时直接投影即可。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart'
    show ChangeNotifier, ValueNotifier, listEquals;
import 'package:flutter/widgets.dart' show WidgetsBinding;

import '../core/detail_recommendation.dart';
import '../core/following.dart';
import '../core/following_calendar.dart';
import '../core/home_feed.dart';
import '../core/home_hot.dart';
import '../core/image_headers.dart';
import '../core/live_site_keywords.dart';
import '../core/meta_pipeline.dart';
import '../core/meta_source.dart';
import '../core/protocol.dart' show Vod, HeaderRule;
import '../core/push_parser.dart';
import '../core/tmdb_identity.dart';
import '../services/home_art_service.dart';
import '../services/home_hero_startup_cache.dart';
import '../services/recommendation_feedback_store.dart';
import '../services/search_suggest_service.dart';
import '../services/storage.dart';
import '../ui/home_hero_image_probe.dart';
import '../ui/home_hero_startup_image.dart';
import 'app_state.dart';
import 'detail_recommendation_state.dart';
import '../ui/following_air_data.dart';

/// hero 的容量上限（与 `core/home_feed.dart` 的 `_heroMax` 同一个数）。
const int heroMax = 12;

/// 推荐种子只取最近 4 条。
///
/// 不是「越多越准」：种子越多，缓存键变化越频繁（看一集就换键），而首页每次启动
/// 都换键等于每次启动都重新打网络——详情页那套 7 天缓存就白设了。
const int _seedLimit = 4;

/// 每条推荐行参与元数据解析的条数（= hero 的推荐预算 3）。
const int _heroRecommendBudgetForMeta = 3;

/// 追剧卡片元数据的整轮上限。
const Duration _followingMetaTimeout = Duration(seconds: 20);

/// 会话里「元数据/热门多久算旧」：只影响**再次进入**时是否后台复核，不清空内容。
const Duration _revalidateAfter = Duration(hours: 6);

/// 上次后台复核失败后的最小重试间隔：避免每次切页都打一轮注定失败的请求。
const Duration _retryAfterFailure = Duration(minutes: 1);

/// 页面一帧要画的东西：都在这里算好，页面只做布局。
class HomeProjection {
  const HomeProjection({
    required this.rails,
    required this.hot,
    required this.heroItems,
    required this.candidates,
    required this.hasRails,
    required this.scanRunning,
    required this.reserveHeroSlot,
  });

  final List<HomeRail> rails;
  final List<HomeRail> hot;
  final List<HomeItem> heroItems;
  final List<HomeItem> candidates;
  final bool hasRails;
  final bool scanRunning;
  final bool reserveHeroSlot;
}

class HomeHeroSession extends ChangeNotifier {
  HomeHeroSession(this._state, {DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;

  final AppState _state;

  AppState get state => _state;

  /// 当前轮播作品：视图按下标读，恢复时按作品 key 找回来。
  final ValueNotifier<int> heroIndex = ValueNotifier(0);
  List<String> _heroKeys = const [];

  final _heroStartupClock = Stopwatch()..start();
  bool _firstHeroAvailableLogged = false;

  HomeHeroImageLoader? _loader;
  late final HomeHeroImageProbe _heroProbe = HomeHeroImageProbe(loader: _loader);
  late final HomeHeroStartupCache _startupCache = HomeHeroStartupCache(
    directory: Directory(_state.paths.cacheDir),
  );
  final _startupEncoder = HomeHeroStartupImageEncoder();
  List<CachedHomeHero> _startupSnapshots = const [];
  /// 同一命名空间下最多 12 条的**完整**图片副本：热返回时即使 Flutter 的图片缓存
  /// 把位图淘汰了，也能从磁盘直接恢复，不必再走一趟网络。
  late final HomeHeroStartupCache _sessionCache = HomeHeroStartupCache.session(
    directory: Directory(_state.paths.cacheDir),
  );
  Map<String, CachedHomeHero> _sessionByBinding = const {};
  String _sessionSaveKey = '';
  /// 本次挂载是否优先用磁盘副本：只有「已经在看这一页」的返回才这么选，第一次
  /// 进入仍走网络（第一帧不该被一串磁盘解码拖住）。
  bool _preferLocalArt = false;
  String _startupScope = '';
  String _startupSaveKey = '';
  final Set<String> _failedStartupKeys = {};
  final Map<String, HomeItem> _lastDisplayedHeroes = {};
  bool _reserveHeroSlot = true;
  String _heroScanKey = '';
  String _heroScanScope = '';
  final Map<String, String> _candidateSignatures = {};
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

  bool _attached = false;
  bool _listeningFeedback = false;
  bool _recommendationsStarted = false;
  String _contextKey = '';
  String _recommendationRequestKey = '';
  int _recommendationGeneration = 0;
  DateTime? _recommendationFinishedAt;
  DateTime? _recommendationRetryAt;
  void Function()? _releaseRecommendation;
  DateTime? _hotFinishedAt;
  DateTime? _hotRetryAt;
  bool _backgroundScheduled = false;
  bool _entered = false;
  bool _hotStarted = false;
  bool _airStarted = false;
  bool _disposed = false;
  DateTime? _metaCheckedAt;

  /// 追剧的播出时间（TMDB，6h 缓存）：用来判断「近 48 小时有没有更新」。
  FollowingAirData? _air;
  List<FollowingAirTime> _airTimes = const [];

  List<ConfigRecord>? _liveKeysConfigs;
  List<String> _liveKeysKeywords = const [];
  Set<String> _liveSiteKeysCache = const {};

  /// 注入给影像检查的图片加载器。会话只有一份检查器，所以只认第一次注入的那个：
  /// 生产为 null（走真实解码），测试用的是确定性图像结果。
  void attachImageLoader(HomeHeroImageLoader? loader) => _loader = loader;

  /// 页面挂上来了：可以花钱解码、可以写盘。
  void attach() {
    _attached = true;
    _entered = true;
    // 已有资格图说明这是「返回首页」，可以直接吃磁盘副本。
    _preferLocalArt = _heroAcceptedOrder.isNotEmpty;
  }

  /// 页面解绑不取消取数/资格检查，返回时继续订阅同一批次。
  void detach() {
    _attached = false;
    _preferLocalArt = false;
    // 页面走了就没人等这两件事：编码与在途检查的超时定时器必须撤销。
    // 没跑完的检查**不标记为已检查**，返回时重新排一次（结果本来也没人收到）。
    _heroScanGeneration++;
    _heroScanRunning = false;
    _heroProbe.clear();
    _startupEncoder.clear();
    _startupSaveKey = '';
    _sessionSaveKey = '';
    // 推荐请求没人等了：撤销这一次，下次挂载按缓存重来。豆颛 750ms 限速定时器
    // 挂在租约上，留着它会活过页面（也与「最后一个租约释放就关掉 provider」同一纪律）。
    if (_releaseRecommendation != null) {
      _recommendationGeneration++;
      _releaseRecommendation!.call();
      _releaseRecommendation = null;
      _recommendationsStarted = false;
    }
  }

  bool get scanRunning => _heroScanRunning;
  bool get reserveHeroSlot => _reserveHeroSlot;

  /// 某个榜单的原始条目（长按信息卡要按 key 找回排名来源）。
  List<SearchSuggestItem>? hotRows(HotRankCategory category) => _hot[category];

  /// 「不感兴趣」直接落到共享的反馈库；首页只是它的一个读者。
  RecommendationFeedbackStore get feedback => _recommendationFeedback;

  /// 一次写入只提交一次通知。
  void _commit(void Function() body) {
    body();
    if (_disposed) return;
    notifyListeners();
  }

  /// 首帧之后启动「推荐 / 热门 / 播出时间」三条链；重复进入不会重跑。
  void startBackgroundLoads() {
    // 没有页面就没有人在看这些结果：留到下一次挂载再取，避免没人收尾的限速定时器。
    if (_disposed || !_attached) return;
    if (!_listeningFeedback) {
      _listeningFeedback = true;
      _recommendationFeedback.addListener(_onFeedbackChanged);
    }
    unawaited(_loadRecommendations());
    unawaited(_loadHot());
    unawaited(_loadAir());
  }

  void _onFeedbackChanged() {
    if (_disposed) return;
    notifyListeners();
  }

  /// 详情/播放返回后：已解析的字段可能变了，重算一次（不清空已完成的高清资格）。
  void invalidateMetadata() {
    if (_disposed) return;
    _commit(() {
      _heroScanKey = '';
      _candidateSignatures.clear();
      _heroScanGeneration++;
      _heroScanRunning = false;
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
      _metaCheckedAt = null;
    });
    _ensureRecommendationMeta();
  }

  /// 视图报告「这张图真的画不出来」：撤掉资格并由后续候选补位。
  void onHeroImageError(HomeItem item) {
    if (_disposed) return;
    final url = item.backdrop;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed) return;
      if (_lastDisplayedHeroes[item.key]?.backdrop != url) return;
      _commit(() {
        _heroQualified.remove(item.key);
        _heroAcceptedOrder.remove(item.key);
        _failedStartupKeys.add(item.key);
        _lastDisplayedHeroes.remove(item.key);
      });
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  // ── 取数 ────────────────────────────────────────────────────────────────

  Future<void> _loadAir() async {
    if (_airStarted || _disposed) return;
    _airStarted = true;
    final items = _state.followings;
    if (items.isEmpty) return;
    final scope = _contextKey;
    final air = FollowingAirData(state: _state);
    _air = air;
    air.addListener(_onAirChanged);
    try {
      await air.refresh(items, includeNetworks: false);
    } catch (_) {
      // 播出时间拿不到就退化成「全部保留」，绝不因为查不到时间而藏掉轨道。
    }
    if (!_disposed && scope == _contextKey) _onAirChanged();
  }

  void _onAirChanged() {
    if (_disposed) return;
    _commit(() => _airTimes = _air?.airTimes ?? const []);
  }

  /// 按「最近 4 条历史」取一次个性推荐（TMDB + 豆瓣，串行）。
  ///
  /// 种子组是**确定性**的（最近 N 条，按 updatedAt 降序）：只要用户没再看新的一集，
  /// 推导出的缓存键就不变，第二次启动命中磁盘缓存、一条请求都不发。
  Future<void> _loadRecommendations() async {
    if (_disposed) return;
    final seeds = [
      for (final row in _state.recentHistory(sourceKey: '').take(_seedLimit))
        _state.recommendationSeedForHistory(row),
    ].where((seed) => seed.title.trim().isNotEmpty && !seed.isAudio).toList();
    final blocked = _recommendationFeedback.blockedTitles.toList()..sort();
    final key = jsonEncode([
      _contextKey,
      for (final seed in seeds)
        [seed.title, seed.year, seed.tmdbId, seed.mediaType?.name, seed.isAudio, seed.isShortDrama],
      blocked,
    ]);
    if (key != _recommendationRequestKey) {
      _recommendationRequestKey = key;
      _recommendationGeneration++;
      _releaseRecommendation?.call();
      _releaseRecommendation = null;
      _recommendationsStarted = false;
      _recommendationFinishedAt = null;
      _recommendationRetryAt = null;
    }
    final now = _clock();
    if (_recommendationsStarted ||
        (_recommendationRetryAt?.isAfter(now) ?? false) ||
        (_recommendationFinishedAt != null && now.difference(_recommendationFinishedAt!) < _revalidateAfter)) {
      return;
    }
    _recommendationsStarted = true;
    if (seeds.isEmpty) {
      _recommendationsStarted = false;
      _recommendationFinishedAt = now;
      return;
    }
    final generation = ++_recommendationGeneration;
    bool current() => !_disposed && generation == _recommendationGeneration;
    final request = RecommendationRequest(current: seeds.first, history: seeds.skip(1).toList(),
      blockedTitles: blocked.toSet());
    final dependencies = _state.recommendationDependencies;
    final loaders = dependencies.acquire();
    var released = false;
    void release() {
      if (released) return;
      released = true;
      dependencies.release();
    }
    _releaseRecommendation = release;
    var failed = false;
    try {
      for (final row in [RecommendationRow.tmdb, RecommendationRow.douban]) {
        if (!current()) return;
        final loader = loaders[row];
        if (loader == null) continue;
        try {
          final result = await loader(request);
          if (!current()) return;
          if (result.items.isNotEmpty) {
            _commit(() => _recommendations[row] = result.items);
            _ensureRecommendationMeta();
          }
        } catch (_) {
          failed = true;
        }
      }
    } finally {
      release();
      if (current()) {
        _releaseRecommendation = null;
        _recommendationsStarted = false;
        _recommendationFinishedAt = failed ? null : _clock();
        _recommendationRetryAt = failed ? _clock().add(_retryAfterFailure) : null;
      }
    }
  }

  /// 直播站的 site key 集合（见 `core/live_site_keywords.dart`）。
  ///
  /// 缓存是必须的：`ConfigRecord.config` 会把整份配置 JSON（最大的那份 300 KB
  /// 以上）解一遍，而首页每次重建都会走这里。配置列表与关键词不变时直接复用。
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
        for (final record in configs)
          for (final site in record.config?.sites ?? const []) site.key: site.name,
      },
      keywords: keywords,
    );
    _liveKeysConfigs = configs;
    _liveKeysKeywords = keywords;
    _liveSiteKeysCache = keys;
    return keys;
  }

  /// 热门榜单：电影 / 剧集 / 综艺（与搜索页同一份数据与缓存）。
  Future<void> _loadHot() async {
    final now = _clock();
    if (_hotStarted || _disposed || (_hotRetryAt?.isAfter(now) ?? false) ||
        (_hotFinishedAt != null && now.difference(_hotFinishedAt!) < _revalidateAfter)) {
      return;
    }
    _hotStarted = true;
    final scope = _contextKey;
    final results = <HotRankCategory, List<SearchSuggestItem>>{};
    var failed = false;
    try {
      for (final category in HotRankCategory.values) {
        if (_disposed || scope != _contextKey) return;
        try {
          final items = await _state.searchHotRank(category);
          if (items.isNotEmpty) results[category] = items;
        } catch (_) { failed = true; }
      }
      if (_disposed || scope != _contextKey) return;
      if (results.isNotEmpty) _commit(() => _hot.addAll(results));
      _hotFinishedAt = failed ? null : _clock();
      _hotRetryAt = failed ? _clock().add(_retryAfterFailure) : null;
    } finally {
      if (scope == _contextKey) _hotStarted = false;
    }
  }

  // ── 元数据 ──────────────────────────────────────────────────────────────

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

  Future<Vod?> _heroHistorySource(PlaybackHistory row) => _heroSources.putIfAbsent(
    homeHistoryKey(row),
    () => _state.historyVod(row),
  );

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
    final external = state.externalMetaEnabled ? state.externalMetaService : null;
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
        siteName: (entry) => state.siteInActiveSource(entry.siteKey)?.name ?? '',
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

  /// 输入身份/字段规则变化后重算；详情返回时也失效，不能永久记住首次缺图的结果。
  void _ensureResumeMeta(HomeFeed feed) {
    final rows = {
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
    _resumeMeta.removeWhere((key, _) => !rows.containsKey(key));
    if (rows.isEmpty) return;
    final completed = Completer<void>();
    for (final key in rows.keys) {
      _railMetaPending[key] = completed.future;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      bool current() => !_disposed && generation == _resumeMetaGeneration;
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
                (state.configForSourceKey(row.sourceKey) ?? state.effectiveConfig)
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
      _commit(() => _resumeMeta.addAll(resolved));
    });
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
    _art.removeWhere((key, _) => !entries.containsKey(key));
    if (entries.isEmpty) return;
    final completed = Completer<void>();
    for (final key in entries.keys) {
      _railMetaPending[key] = completed.future;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      bool current() => !_disposed && generation == _recommendationMetaGeneration;
      if (!current()) {
        if (!completed.isCompleted) completed.complete();
        return;
      }
      // 推荐本来自带 TMDB 图：只走 TMDB 字段，不引外部源（豆瓣有 750ms 串行
      // 间隔，会让 hero 分批到），也不做 pin（pin 以 vodId 为键，推荐没有）。
      final resolved = await HomeMetaService(tmdb: state.tmdbService)
          .resolveRecommendations(
            entries.values,
            pipeline: pipeline,
            isCurrent: current,
          );
      if (!completed.isCompleted) completed.complete();
      if (!current() || resolved.isEmpty) return;
      _commit(() => _art.addAll(resolved));
    });
  }

  void _ensureFollowingMeta(HomeFeed feed) {
    final items = {
      for (final item in [
        ...feed.hero,
        for (final rail in feed.rails) ...rail.items,
      ])
        if (item.following != null) item.key: item.following!,
    }.values.take(heroMax).toList();
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
    final retainedKeys = items.map((item) => item.identityKey).toSet();
    _followingMeta.removeWhere((key, _) => !retainedKeys.contains(key));
    if (items.isEmpty) return;
    final completed = Completer<void>();
    for (final item in items) {
      _railMetaPending[item.identityKey] = completed.future;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (_disposed || generation != _followingMetaGeneration) {
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
            isCurrent: () => !_disposed && generation == _followingMetaGeneration,
          );
      if (!completed.isCompleted) completed.complete();
      if (_disposed || generation != _followingMetaGeneration || resolved.isEmpty) {
        return;
      }
      _commit(() => _followingMeta.addAll(resolved));
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
    if (_state.metaPipeline.orderOf(MetaField.rating).isNotEmpty && meta.rating > 0)
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

  // ── 投影 ────────────────────────────────────────────────────────────────

  /// 追剧轨道只保留「近 48 小时内更新」的（用户 2026-11-19：「近期没有时不显示」）。
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

  /// 本地 feed 与「带推荐的 feed」合并：**只追加，不驱逐**（§3）。
  ///
  /// 判据是**作品**而不是 `key`：本站历史里叫「那一夜我怀了社长的孩子」、推荐里
  /// 叫「那一夜，我怀了社长的孩子」时 `key` 不同，却是同一部剧（用户 2026-11-25）。
  HomeFeed _merge(HomeFeed local, HomeFeed withRecommendations) {
    if (local.hero.isEmpty) return withRecommendations;
    final claimer = HomeWorkClaimer();
    final hero = [
      for (final item in [...local.hero, ...withRecommendations.hero])
        if (claimer.claim(item)) item,
    ].take(heroMax).toList();
    return HomeFeed(hero: hero, rails: withRecommendations.rails);
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
              for (final rule in rules) [rule.host, rule.header.asRequestHeaders],
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
    _sessionByBinding = {
      for (final snapshot in _sessionCache.read(scope)) snapshot.key: snapshot,
    };
    _sessionSaveKey = '';
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

  List<HomeItem> _displayHeroItems(List<HomeItem> candidates, String? readingKey) {
    final byBinding = {for (final item in candidates) _startupBindingKey(item): item};
    final byKey = {for (final item in candidates) item.key: item};
    final displayed = <HomeItem>[];
    final claimer = HomeWorkClaimer();
    final used = <String>{};
    void add(HomeItem item) {
      if (displayed.length >= heroMax ||
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
      final fresh = (_preferLocalArt ? _localArtFor(raw) : null) ?? _heroQualified[raw.key];
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
      final fresh = (_preferLocalArt ? _localArtFor(raw) : null) ?? _heroQualified[old.key];
      // 已经在这一页上的条目继续留在原位，但**文案照常前进**：真正需要「别改写我
      // 正在读的这一张」的那一条由下面统一的 reading 处理兜住，不能靠冻结整页文字
      // 来实现（那会让后台更新的新内容永远进不来）。
      add(_withArt(raw).copyWith(backdrop: fresh ?? old.backdrop));
    }
    for (final key in _heroAcceptedOrder) {
      final raw = byKey[key];
      if (raw == null) continue;
      final art = (_preferLocalArt ? _localArtFor(raw) : null) ?? _heroQualified[key];
      add(_withArt(raw).copyWith(backdrop: art));
    }
    // 正在读的这一张不接受后台改写：新文案等用户切走之后再采用。
    // 放在所有来源之后统一处理，避免哪条分支先到就漏掉这条约束。
    final reading = readingKey == null ? null : _lastDisplayedHeroes[readingKey];
    if (reading != null) {
      final at = displayed.indexWhere((item) => item.key == readingKey);
      if (at >= 0) {
        displayed[at] = displayed[at].copyWith(
          title: reading.title,
          subtitle: reading.subtitle,
          overview: reading.overview,
          tags: reading.tags,
        );
      }
    }
    _lastDisplayedHeroes
      ..clear()
      ..addEntries(displayed.map((item) => MapEntry(item.key, item)));
    if (!_firstHeroAvailableLogged && displayed.isNotEmpty) {
      _firstHeroAvailableLogged = true;
      final local = Uri.tryParse(displayed.first.backdrop ?? '')?.scheme == 'file';
      _state.log.info(
        'event=first_available source=${local ? 'local_cache' : 'verified_image'} '
        'visible=${displayed.length} elapsedMs=${_heroStartupClock.elapsedMilliseconds}',
        scope: 'home',
      );
    }
    return displayed;
  }

  /// 磁盘副本只认「同一个作品绑定键 + 同一个图地址」，否则宁可回网络。
  String? _localArtFor(HomeItem item) {
    final snapshot = _sessionByBinding[_startupBindingKey(item)];
    if (snapshot == null) return null;
    if (snapshot.sourceUrl != _heroQualified[item.key]) return null;
    if (!File(snapshot.filePath).existsSync()) return null;
    return Uri.file(snapshot.filePath).toString();
  }

  /// 把已合格的完整列表（最多 12 张）落到会话图片目录。
  ///
  /// 写入在后台一次一版，列表没变就不重写；页面不在时连这次编码都不做。
  void _saveSessionImages(List<HomeItem> candidates, List<HeaderRule> rules) {
    if (!_attached) return;
    final byKey = {for (final item in candidates) item.key: item};
    final picks = [
      for (final key in _heroAcceptedOrder.take(heroMax))
        if (byKey[key] case final item?)
          _withArt(item).copyWith(backdrop: _heroQualified[key]),
    ];
    if (picks.isEmpty) return;
    final scope = _startupScope;
    final key = jsonEncode([
      scope,
      for (final item in picks)
        [item.key, item.backdrop, item.title, item.subtitle, item.overview, item.tags],
    ]);
    if (key == _sessionSaveKey) return;
    _sessionSaveKey = key;
    final generation = _heroScanGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      bool current() =>
          !_disposed &&
          _attached &&
          generation == _heroScanGeneration &&
          scope == _startupScope &&
          key == _sessionSaveKey;
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
      if (!current() || saved.isEmpty) return;
      try {
        await _sessionCache.save(scope, saved);
        if (!current()) return;
        _sessionByBinding = {
          for (final snapshot in _sessionCache.read(scope)) snapshot.key: snapshot,
        };
        _state.log.info(
          'event=session_cache_save encoded=${saved.length} readable=${_sessionByBinding.length}',
          scope: 'home',
        );
      } catch (_) {
        if (current()) _sessionSaveKey = '';
      }
    });
  }

  void _saveStartupImages(List<HomeItem> candidates, List<HeaderRule> rules) {
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
        [item.key, item.backdrop, item.title, item.subtitle, item.overview, item.tags],
    ]);
    if (key == _startupSaveKey) return;
    _startupSaveKey = key;
    final generation = _heroScanGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      bool current() =>
          !_disposed &&
          _attached &&
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
            _state.log.warning('event=cache_save result=write_failed', scope: 'home');
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
  void _ensureHdHero(List<HomeItem> candidates, List<HeaderRule> rules) {
    final state = _state;
    _restoreStartup(_startupScopeFor(rules));
    final scope = jsonEncode([
      _startupScope, state.tmdbConfigRevision,
    ]);
    final signatures = <String, String>{
      for (final item in candidates)
        item.key: jsonEncode([
          item.title, item.poster, item.backdrop,
          item.history?.tmdbId, item.history?.mediaType, item.history?.vodYear,
          item.following?.metadataUpdatedAtMs,
          state.metaOverrides.of(item.history?.vodId ?? item.following?.vodId ?? '')?.key,
        ]),
    };
    final key = jsonEncode([scope, signatures]);
    if (key != _heroScanKey) {
      final hardReset = scope != _heroScanScope;
      final changed = <String>{
        for (final entry in signatures.entries)
          if (hardReset || _candidateSignatures[entry.key] != entry.value) entry.key,
        for (final old in _candidateSignatures.keys)
          if (!signatures.containsKey(old)) old,
      };
      _heroScanKey = key;
      _heroScanScope = scope;
      _heroScanGeneration++;
      _heroScanRunning = false;
      if (hardReset) {
        _heroInspected.clear();
        _heroCandidateMeta.clear();
        _heroQualified.clear();
        _heroAcceptedOrder.clear();
        _heroProbe.clear();
        _heroMatches.clear();
        _heroSources.clear();
      } else {
        for (final itemKey in changed) {
          _heroInspected.remove(itemKey);
          _heroCandidateMeta.remove(itemKey);
          _heroQualified.remove(itemKey);
          _heroAcceptedOrder.remove(itemKey);
        }
      }
      _candidateSignatures
        ..clear()
        ..addAll(signatures);
      _startupSaveKey = '';
      _sessionSaveKey = '';
    }
    if (_heroScanRunning || _heroAcceptedOrder.length >= heroMax) return;
    final queue = candidates
        .where((item) => !_heroInspected.contains(item.key))
        .toList();
    if (queue.isEmpty) return;
    _heroScanRunning = true;
    WidgetsBinding.instance.ensureVisualUpdate();
    final generation = _heroScanGeneration;
    final scanClock = Stopwatch()..start();
    _state.log.info(
      'event=scan_start generation=$generation candidates=${candidates.length} '
      'pending=${queue.length}',
      scope: 'home',
    );
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      bool current() => !_disposed && generation == _heroScanGeneration;
      if (!current()) return;
      var next = 0;
      Future<(HomeItem, String?)> inspect(HomeItem item) async {
        try {
          await _loadHeroCandidateMeta(item, current);
          if (!current() || state.metaPipeline.orderOf(MetaField.backdrop).isEmpty) {
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
          _heroAcceptedOrder.length < heroMax) {
        final remaining = heroMax - _heroAcceptedOrder.length;
        final batch = queue
            .skip(next)
            .take(remaining < 2 ? remaining : 2)
            .toList();
        next += batch.length;
        final checked = await Future.wait(batch.map(inspect));
        if (!current()) return;
        _commit(() {
          _heroInspected.addAll(batch.map((item) => item.key));

          final claimer = HomeWorkClaimer();
          for (final accepted in _heroAcceptedOrder) {
            final item = candidatesByKey[accepted];
            if (item != null) claimer.claim(_withArt(item));
          }
          for (final (item, url) in checked) {
            if (url == null || _heroAcceptedOrder.length >= heroMax) continue;
            if (!claimer.claim(_withArt(item))) continue;
            _heroQualified[item.key] = url;
            _failedStartupKeys.remove(item.key);
            _heroAcceptedOrder.add(item.key);
          }
        });
      }
      if (!current()) return;
      _state.log.info(
        'event=scan_complete generation=$generation '
        'accepted=${_heroAcceptedOrder.length} inspected=${_heroInspected.length} '
        'elapsedMs=${scanClock.elapsedMilliseconds}',
        scope: 'home',
      );
      _commit(() => _heroScanRunning = false);
      WidgetsBinding.instance.ensureVisualUpdate();
    });
  }

  /// 页面每一帧调一次：算好投影，顺手推进后台任务。
  ///
  /// **绝不在这里 `notifyListeners()`**：它由 `build` 调用，同步通知会触发
  /// 「setState during build」。需要通知的写入都发生在 post-frame 回调里。
  void _syncContext(List<HeaderRule> rules) {
    final key = sha256.convert(utf8.encode(jsonEncode([
      _startupScopeFor(rules), _state.tmdbConfigRevision,
    ]))).toString();
    if (_contextKey == key) return;
    _contextKey = key;
    _recommendationGeneration++;
    _releaseRecommendation?.call();
    _releaseRecommendation = null;
    _recommendationsStarted = false;
    _recommendationRequestKey = '';
    _recommendationFinishedAt = null;
    _recommendationRetryAt = null;
    _recommendations.clear();
    _hotStarted = false;
    _hotFinishedAt = null;
    _hotRetryAt = null;
    _hot.clear();
    _airStarted = false;
    _air?.removeListener(_onAirChanged);
    _air?.dispose();
    _air = null;
    _airTimes = const [];
    _resumeMetaGeneration++;
    _followingMetaGeneration++;
    _recommendationMetaGeneration++;
    _resumeMetaKey = '';
    _followingMetaKey = '';
    _recommendationMetaKey = '';
    _resumeMeta.clear();
    _followingMeta.clear();
    _art.clear();
    _heroCandidateMeta.clear();
    _heroScanScope = '';
    _metaCheckedAt = _clock();
  }

  void _scheduleBackgroundLoads() {
    if (_backgroundScheduled || _disposed) return;
    _backgroundScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _backgroundScheduled = false;
      if (!_disposed) startBackgroundLoads();
    });
  }

  HomeProjection project({required List<HeaderRule> headerRules}) {
    _syncContext(headerRules);
    if (_entered) {
      _entered = false;
      _maybeRevalidate();
    }
    _scheduleBackgroundLoads();
    final history = _state.recentHistory(sourceKey: '');
    final followings = _recentFollowings(_state.followings);
    final liveSiteKeys = _liveSiteKeys();
    final local = buildHomeFeed(
      history: history,
      followings: followings,
      liveSiteKeys: liveSiteKeys,
    );
    final blocked = _recommendationFeedback.blockedTitles;
    List<RecommendationEntry> recommended(RecommendationRow row) => [
      for (final entry in _recommendations[row] ?? const <RecommendationEntry>[])
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
    // 轨道之间共用一份认领，但**不与 hero 共用**：hero 是轨道的子集，同一部作品
    // 允许在自己的轨道里再出现一次（02 §1 I4）。共用会把 hero 的条目从它自己的
    // 轨道里删掉——只有一条续播/推荐时，整条轨道连同「查看全部」入口都会消失。
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
    _ensureHdHero(candidates, headerRules);
    final selectedKey = _heroKeys.isEmpty
        ? null
        : _heroKeys[heroIndex.value % _heroKeys.length];
    final heroItems = _displayHeroItems(candidates, selectedKey);
    _saveStartupImages(candidates, headerRules);
    _saveSessionImages(candidates, headerRules);
    final nextKeys = [for (final item in heroItems) item.key];
    if (!listEquals(_heroKeys, nextKeys)) {
      final nextIndex = selectedKey == null ? -1 : nextKeys.indexOf(selectedKey);
      _heroKeys = nextKeys;
      heroIndex.value = nextIndex < 0 ? 0 : nextIndex;
    }

    // 热门接在本机轨道之后（用户 2026-11-19：用过也照样要给热门），并去掉 hero
    // 里已经有的条目。只过滤 hero：热门轨道也不因作品是否有高清宽图而增删。
    final hot = _hotRails(hero: const [], rails: rails);
    final hasRails = rails.isNotEmpty || hot.isNotEmpty;
    // 冷启动bootstrap尚未恢复历史时也先预留，不能等异步列表出现才加高。
    if (candidates.isNotEmpty || heroItems.isNotEmpty || hasRails) {
      _reserveHeroSlot = true;
    }
    return HomeProjection(
      rails: rails,
      hot: hot,
      heroItems: heroItems,
      candidates: candidates,
      hasRails: hasRails,
      scanRunning: _heroScanRunning,
      reserveHeroSlot: _reserveHeroSlot,
    );
  }

  /// 再次进入时按「上次复核时间」判断要不要后台再看一遍；失败过的按最短间隔退避。
  ///
  /// 这里**不清空任何内容**：过期只意味着值得复核一次，不意味着要把已经画好的
  /// 推荐撤掉。也不起周期定时器——只有用户回到首页时才检查。
  void _maybeRevalidate() {
    final now = _clock();
    if (_metaCheckedAt != null && now.difference(_metaCheckedAt!) < _revalidateAfter) return;
    _metaCheckedAt = now;
    _resumeMetaKey = '';
    _followingMetaKey = '';
    _recommendationMetaKey = '';
    _heroMatches.clear();
    _heroSources.clear();
    _heroCandidateMeta.clear();
    _candidateSignatures.clear();
    _heroScanKey = '';
    _scheduleBackgroundLoads();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (_listeningFeedback) {
      _listeningFeedback = false;
      _recommendationFeedback.removeListener(_onFeedbackChanged);
    }
    // 会话结束时在途扫描不再有人收尾：把标志归位，避免下一次进入永远不启动。
    _heroScanGeneration++;
    _heroScanRunning = false;
    _recommendationGeneration++;
    _releaseRecommendation?.call();
    _releaseRecommendation = null;
    _air?.removeListener(_onAirChanged);
    _air?.dispose();
    _air = null;
    _startupEncoder.dispose();
    _heroProbe.dispose();
    heroIndex.dispose();
    super.dispose();
  }
}
