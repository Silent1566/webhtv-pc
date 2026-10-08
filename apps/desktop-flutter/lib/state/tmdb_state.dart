/// TMDB 详情页状态（`docs/phase4/design/04` §2.2）。
///
/// `ChangeNotifier`，供详情页订阅。负责：
/// - 匹配 → 详情 → 季度 → 剧集的加载编排；
/// - **代际（generation）**防迟到响应（对齐 Phase 3 的详情竞态处理）；
/// - 加载阶段与错误隔离（TMDB 失败不影响线路与选集）。
///
/// 关键契约：
/// - 离开页面时 `dispose()` 取消在途请求并清空状态；
/// - 迟到响应**必须丢弃**（`04` §2.2）；
/// - TMDB 失败只影响 TMDB 区块（`04` §3.4）。
library;

import 'package:flutter/foundation.dart';

import '../core/app_error.dart';
import '../core/playback.dart';
import '../core/protocol.dart';
import '../core/tmdb_config.dart';
import '../core/tmdb_detail_model.dart';
import '../core/tmdb_identity.dart';
import '../core/tmdb_media.dart';
import '../core/tmdb_season.dart';
import '../core/tmdb_title.dart';
import '../services/tmdb_enrichment_service.dart';
import '../services/tmdb_identity_service.dart';
import '../services/tmdb_season_service.dart';
import '../services/tmdb_service.dart';
import '../ui/tmdb_widgets.dart' show TmdbLoadPhase;

/// TMDB 详情页状态。
class TmdbState extends ChangeNotifier {
  TmdbState({
    required TmdbConfig Function() config,
    required TmdbService service,
    required TmdbIdentityService identityService,
    required TmdbSeasonService seasonService,
    required TmdbEnrichmentService enrichmentService,
    bool Function()? isCurrentRun,
  }) : _config = config,
       _service = service,
       _identityService = identityService,
       _seasonService = seasonService,
       _enrichmentService = enrichmentService,
       _isCurrentRun = isCurrentRun ?? _alwaysCurrent;

  static bool _alwaysCurrent() => true;

  /// 外部运行号是否仍然有效（由 `AppState` 提供，对应详情运行号）。
  ///
  /// 用于「返回列表 → 点另一部剧」时丢弃迟到的 TMDB 响应（`04` §2.2）。
  final bool Function() _isCurrentRun;

  // ignore_for_file: prefer_initializing_formals
  final TmdbConfig Function() _config;
  final TmdbService _service;
  final TmdbIdentityService _identityService;
  final TmdbSeasonService _seasonService;
  final TmdbEnrichmentService _enrichmentService;

  // -------------------------------------------------------------------------
  // 状态字段
  // -------------------------------------------------------------------------

  TmdbLoadPhase _phase = TmdbLoadPhase.idle;
  AppError? _error;
  TmdbMatchResult? _matchResult;
  Map<String, Object?>? _detail;
  Resolution? _resolution;
  List<int> _availableSeasons = const [];
  int _selectedSeason = -1;
  Map<int, int> _seasonEpisodeCounts = const {};
  List<TmdbEpisode> _episodes = const [];
  List<TmdbPerson> _cast = const [];
  List<TmdbPerson> _creators = const [];
  List<TmdbItem> _recommendations = const [];
  List<TmdbVideo> _videos = const [];
  List<String> _photos = const [];
  bool _busy = false;

  int _generation = 0;
  int _metadataGeneration = 0;
  int _configId = 0;
  String _siteKey = '';
  String _vodId = '';
  String _sourceTitle = '';
  /// 当前详情页的站源条目（供 UI 读取原始字段）。
  Vod? _vod;
  TmdbSourceLine? _activeLine;
  bool _disposed = false;

  TmdbLoadPhase get phase => _phase;
  AppError? get error => _error;
  TmdbMatchResult? get matchResult => _matchResult;
  Map<String, Object?>? get detail => _detail;
  Resolution? get resolution => _resolution;
  List<int> get availableSeasons => _availableSeasons;
  int get selectedSeason => _selectedSeason;
  Map<int, int> get seasonEpisodeCounts => _seasonEpisodeCounts;
  List<TmdbEpisode> get episodes => _episodes;
  List<TmdbPerson> get cast => _cast;
  List<TmdbPerson> get creators => _creators;
  List<TmdbItem> get recommendations => _recommendations;
  List<TmdbVideo> get videos => _videos;
  List<String> get photos => _photos;
  bool get busy => _busy;
  int get generation => _generation;
  int get metadataGeneration => _metadataGeneration;
  bool get isDisposed => _disposed;

  /// 当前站源条目（未加载时为 `null`）。
  Vod? get vod => _vod;

  /// 当前线路的季度解析输入（供手动绑定使用）。
  TmdbSourceLine? get sourceLine => _activeLine;

  /// 详情页全部线路（详情页切换线路时用）。
  List<VodPlayLine> _playLines = const [];
  List<VodPlayLine> get playLines => _playLines;

  /// 按 `flag` 取线路；未找到返回 `null`。
  VodPlayLine? lineByFlag(String flag) {
    for (final line in _playLines) {
      if (line.flag == flag) return line;
    }
    return null;
  }

  /// 「按集号自动切片」是否可用（`04` §5.2）。
  ///
  /// 仅在 TMDB 季集数能完整覆盖线路集数时为真；否则弹窗中该项必须禁用。
  bool get canAutoSlice {
    if (_seasonEpisodeCounts.length < 2) return false;
    final ordered = _seasonEpisodeCounts.keys.toList()..sort();
    final segments = completeSeasonSegments(ordered, _seasonEpisodeCounts);
    if (segments.length < 2) return false;
    final line = _activeLine;
    if (line == null) return false;
    return segments.last.sourceEpisodeEndIndex + 1 == line.episodeCount;
  }

  /// 切换当前线路（`04` §4.3：切换线路必须重新解析可播放季度）。
  ///
  /// [preferredSeason] 是用户的**季度意图**（通常传切换前的 `selectedSeason`）。
  /// 为什么必须传：换线路后 `_selectedSeason` 会被重置，若不给意图，
  /// 解析器会回落到默认季（第一条正片季）。当新线路只有别的季度时
  /// （例如「线路一 S1+S2」切到「只有 S2 的线路二」），默认季在该线路上
  /// **一集都没有** → 剧集区空白。用户看到的就是「点了线路什么都不显示」。
  /// 传意图后解析器会优先满足它，满足不了才回落。
  void selectLine(String flag, {int preferredSeason = -1}) {
    if (_disposed) return;
    final line = lineByFlag(flag);
    if (line == null) return;
    if (_activeLine?.flagKey == flag) return;
    // 切走之前，把当前线路选定的季度记下来，回来时恢复（见 _lineSeasonMemory）。
    _rememberLineSeason(_selectedLineFlag, _selectedSeason);
    _selectedLineFlag = flag;
    _activeLine = sourceLineOf(line, 0, unique: _isFlagUnique(flag));
    // 线路变了 → 旧季度的剧集元数据不再适用
    _episodes = const [];
    _selectedSeason = -1;
    _availableSeasons = const [];
    _resolution = null;
    // 季度意图优先级：该线路的**记忆** > 调用方给的当前季度 > 无。
    // 记忆优先，因为它是「用户在这条线路上上次看的那一季」，比「另一条线路
    // 的当前季度」更贴合意图（两条线路可能覆盖不同季度）。
    final remembered = rememberedSeasonOfLine(flag);
    _preferredSeason = remembered >= 0 ? remembered : preferredSeason;
    notifyListeners();
  }

  /// 当前选定的线路 `flag`（供 `loadForVod` 在重新加载时保留选择）。
  String _selectedLineFlag = '';

  /// **每条线路**上次选定的季度（`flag -> season`）。
  ///
  /// 为什么需要（用户反馈 2026-10-08：「选集卡片没有记忆，我切换到其他线路后
  /// 又会重新转换一次」）：季度是**线路级**的（`02` §2.2），同一部剧的不同线路
  /// 可能只覆盖不同季度。用户在线路 A 选了 S2、切到线路 B、再切回 A 时，
  /// 期望仍停在 S2；早期实现每次换线路都重跑季度解析并回落到默认季（S1），
  /// 于是「又转换一次」，选集卡片跳回第一季。
  ///
  /// 上限 [maxRememberedLineSeasons] 条：详情页线路数量有限（实测站点最多
  /// 十几条），但防御异常配置导致的无限增长。
  final Map<String, int> _lineSeasonMemory = {};

  /// 线路季度记忆的上限。
  static const int maxRememberedLineSeasons = 64;

  /// 记录某条线路当前选定的季度。
  void _rememberLineSeason(String flag, int season) {
    if (flag.isEmpty || season < 0) return;
    if (_lineSeasonMemory.length >= maxRememberedLineSeasons &&
        !_lineSeasonMemory.containsKey(flag)) {
      _lineSeasonMemory.remove(_lineSeasonMemory.keys.first);
    }
    _lineSeasonMemory[flag] = season;
  }

  /// 取某条线路上次选定的季度（`-1` 表示无记忆）。
  int rememberedSeasonOfLine(String flag) =>
      flag.isEmpty ? -1 : (_lineSeasonMemory[flag] ?? -1);

  /// 线路季度记忆快照（测试与诊断用）。
  Map<String, int> get lineSeasonMemory => Map.unmodifiable(_lineSeasonMemory);

  /// 切换线路时携带的**季度意图**（`-1` 表示无意图）。
  ///
  /// 由 [selectLine] 写入、由 [loadDetail] 消费后清零：它只在「换线路后
  /// 那一次季度解析」里生效，不应污染后续的季度切换。
  int _preferredSeason = -1;

  /// 取出并清除季度意图（只生效一次）。
  int takePreferredSeason() {
    final value = _preferredSeason;
    _preferredSeason = -1;
    return value;
  }

  /// 详情页某条线路对应的绑定键（`04` §2.3）。
  ///
  /// 与 [selectLine] / [sourceLineOf] 用**同一套唯一性判定**，因此 UI 可以
  /// 直接用它判断「这一条线路是不是 TMDB 当前解析的线路」，不会因为
  /// `#index` 后缀规则不一致而永远判否（实测缺陷：剧集剧照整块不生效）。
  String flagKeyForLine(VodPlayLine line) =>
      flagKeyOf(line, 0, unique: _isFlagUnique(line.flag));

  bool _isFlagUnique(String flag) {
    var count = 0;
    for (final line in _playLines) {
      if (line.flag == flag) count++;
    }
    return count == 1;
  }

  TmdbItem? get item => switch (_matchResult) {
    TmdbMatchHit(:final record) => record.toItem(),
    _ => null,
  };

  TmdbIdentity? get identity => item?.identity;

  SeasonScope get scope => _resolution?.scope ?? const UnknownSeason();

  /// 是否已匹配（用于渲染 TMDB 区块）。
  bool get hasMatch => _matchResult is TmdbMatchHit;

  /// 站点是否被规则禁用（`01` §6.1）。
  ///
  /// 站点禁用时 TMDB 区块整块不渲染——用户明确表达了「这个站不要 TMDB」，
  /// 再给入口只会是噪音。
  bool get siteDisabled {
    final result = _matchResult;
    return result is TmdbMatchDisabled && result.isSiteDisabled;
  }

  /// 是否尚未配置凭据（`03` §5.2）。
  ///
  /// 未配置**必须仍然渲染入口**：这是用户第一次启用 TMDB 的唯一时机。
  /// 早期版本把 notConfigured 与 siteDisabled 一起判为「不渲染」，导致
  /// 全新安装的发布包里详情页没有任何 TMDB 区块、也没有进入设置页的入口。
  bool get notConfigured {
    final result = _matchResult;
    return result is TmdbMatchDisabled && result.isNotConfigured;
  }

  /// TMDB 区块是否应渲染（`04` §3.1）。
  ///
  /// 只有「站点被禁用」不渲染；「未配置」渲染状态条 + [去设置] 入口，
  /// 否则用户永远无法进入 TMDB 设置页。
  bool get shouldRender =>
      _phase != TmdbLoadPhase.idle && !siteDisabled;

  /// 季度导航是否需要显示切换控件（> 1 季）。
  bool get hasSeasonSwitcher => _availableSeasons.length > 1;

  /// 评分文案（`04` §3.2）。
  String get ratingText => TmdbEnrichmentService.ratingText(
    tmdbRating: item?.tmdbRating ?? 0,
    matched: hasMatch,
  );

  // -------------------------------------------------------------------------
  // 展示模型（`04` §3、§4.2：海报 / 导演 / 剧照卡片 / 动态背景）
  // -------------------------------------------------------------------------

  /// 详情页展示模型（海报、背景图、剧照、演职人员、导演、类型…）。
  ///
  /// 未匹配或详情未就绪时退化为 `item` 快照（只有标题/海报/评分），
  /// 使头部至少能渲染，不会因缺少详情而空白。
  TmdbDetailData? get detailData {
    final currentItem = item;
    final config = _config();
    if (currentItem == null) return null;
    final detail = _detail;
    if (detail == null) {
      return TmdbDetailData.fromItem(currentItem);
    }
    return TmdbDetailData.fromDetail(
      detail,
      imageBase: config.imageBase,
      backdropBase: config.backdropBase,
      item: currentItem,
      // 详情没给时长时，用已加载剧集的众数时长（用户反馈的「没有其他信息」）。
      runtimeFallback: tmdbTypicalRuntime(_episodes),
    );
  }

  /// 动态背景图列表（剧集海报/剧照）。
  List<String> get backdropUrls => detailData?.backdropUrls ?? const [];

  /// 展示用季度（含季海报与集数）。
  List<TmdbSeasonInfo> get seasons => detailData?.seasons ?? const [];

  /// 当前季度的 TMDB 集元数据（按集号索引）。
  Map<int, TmdbEpisode> get episodeMetadataByNumber => {
    for (final episode in _episodes) episode.number: episode,
  };

  /// 把**已过滤**的剧集列表渲染为海报卡片（季度过滤后的子集）。
  ///
  /// 与 [episodeCardsForLine] 的区别：季度过滤会先缩小集列表，卡片必须与
  /// **实际渲染的集**一一对应，否则会出现「卡片比集多」的补集假象。
  List<TmdbEpisodeCard> episodeCardsForEpisodes(
    List<VodEpisode> episodes, {
    int? seasonNumber,
    bool includeMetadata = true,
  }) {
    // 线路隔离（`04` §4.3）：非当前线路不得套用当前季度的集元数据，
    // 否则会把别的线路的剧照/集标题贴到这条线路上（跨线路串图）。
    final metadata = includeMetadata
        ? episodeMetadataByNumber
        : const <int, TmdbEpisode>{};
    final usePosition = metadata.isEmpty
        ? false
        : shouldUseEpisodePosition(
            episodes.map((episode) => episode.name).toList(),
            _episodes,
          );
    return TmdbEpisodeCards.build(
      sourceNames: episodes.map((episode) => episode.name).toList(),
      metadataByNumber: metadata,
      usePosition: usePosition,
      seasonNumber: seasonNumber ?? _selectedSeason,
      // 剧照回退池：本剧的剧照（无剧照则用背景图）。
      //
      // 只在**该集没有 TMDB 剧照**时按顺序取用，因此不会覆盖真实剧照；
      // 目的与上游 `TmdbEpisodeAdapter.fallbackStillUrl` 一致：
      // 宁可给一张本剧的画面，也不要让用户看到一排灰色占位（实测用户
      // 反馈就是「每集没有对应的海报卡片」）。
      fallbackStills: detailData?.photoUrls ?? const <String>[],
    );
  }

  /// 当前季度的 TMDB 剧集卡片（纯 TMDB 详情页用，不涉及线路）。
  List<TmdbEpisodeCard> get episodeCards =>
      TmdbEpisodeCards.fromMetadata(_episodes);

  // -------------------------------------------------------------------------
  // 加载
  // -------------------------------------------------------------------------

  /// 开始一次详情加载（递增代际，`04` §2.2）。
  ///
  /// 返回本次请求的代际号；调用方可用它校验后续异步结果。
  int beginLoad({
    required String siteKey,
    required String vodId,
    required String sourceTitle,
    required Vod vod,
    required TmdbSourceLine line,
    int configId = 0,
    String siteName = '',
    int requestSeason = -1,
    bool keepTitleData = false,
  }) {
    if (_disposed) return _generation;
    _generation++;
    _metadataGeneration++;
    _configId = configId;
    _siteKey = siteKey;
    _vodId = vodId;
    _sourceTitle = sourceTitle;
    _vod = vod;
    _activeLine = line;
    _error = null;
    // 同一作品换线路：保留**作品维度**的数据（详情/演职人员/推荐/剧照/季集数），
    // 只重置**线路维度**的数据（剧集元数据与季度解析结果）。
    // 上游 `TmdbUIAdapter` 同样只在作品维度加载一次，换线路不重发请求。
    if (!keepTitleData) {
      _detail = null;
      _cast = const [];
      _creators = const [];
      _recommendations = const [];
      _videos = const [];
      _photos = const [];
      _seasonEpisodeCounts = const {};
    }
    _episodes = const [];
    _availableSeasons = const [];
    _selectedSeason = requestSeason;

    // 前置：未配置 / 站点禁用 → disabled，不发起请求
    final config = _config();
    if (!config.isReady) {
      _phase = TmdbLoadPhase.disabled;
      _matchResult = const TmdbMatchDisabled(TmdbMissReason.notConfigured);
      notifyListeners();
      return _generation;
    }
    if (!config.isSiteEnabled(siteKey, siteName)) {
      _phase = TmdbLoadPhase.disabled;
      _matchResult = const TmdbMatchDisabled(TmdbMissReason.siteDisabled);
      notifyListeners();
      return _generation;
    }

    _phase = TmdbLoadPhase.loading;
    notifyListeners();
    return _generation;
  }

  /// 匹配（含缓存命中）。
  Future<void> loadMatch({
    required int generation,
    required String sourceTitle,
    String? searchKeyword,
    String? vodName,
    String? vodRemarks,
    String? vodYear,
    TmdbMediaType? expectedMediaType,
    String siteName = '',
  }) async {
    if (_disposed || generation != _generation) return;
    _busy = true;
    notifyListeners();
    try {
      final outcome = await _identityService.match(
        TmdbMatchRequest(
          siteKey: _siteKey,
          vodId: _vodId,
          sourceTitle: sourceTitle,
          siteName: siteName,
          searchKeyword: searchKeyword,
          vodName: vodName,
          vodRemarks: vodRemarks,
          vodYear: vodYear,
          expectedMediaType: expectedMediaType,
        ),
      );
      if (_disposed || generation != _generation) return;
      _matchResult = outcome.result;
      switch (outcome.result) {
        case TmdbMatchDisabled():
          _phase = TmdbLoadPhase.disabled;
        case TmdbMatchConflict():
          _phase = TmdbLoadPhase.ready;
        case TmdbMatchMiss(:final reason, :final detail):
          // 网络/鉴权失败属可重试错误态；无候选/歧义只是未匹配（`01` §8）。
          switch (reason) {
            case TmdbMissReason.networkFailure:
              _error = AppError(
                AppErrorKind.tmdbNetwork,
                'TMDB 请求失败',
                detail: detail,
                retryable: true,
              );
              _phase = TmdbLoadPhase.failed;
            case TmdbMissReason.authFailure:
              _error = AppError(
                AppErrorKind.tmdbAuth,
                'TMDB 鉴权失败',
                detail: detail,
              );
              _phase = TmdbLoadPhase.failed;
            case TmdbMissReason.notConfigured:
              _phase = TmdbLoadPhase.disabled;
            case TmdbMissReason.siteDisabled:
              _phase = TmdbLoadPhase.disabled;
            case TmdbMissReason.noCandidates:
            case TmdbMissReason.ambiguous:
              _phase = TmdbLoadPhase.ready;
          }
        case TmdbMatchHit():
          _phase = TmdbLoadPhase.ready;
      }
    } on TmdbCancelledException {
      if (_disposed || generation != _generation) return;
      _phase = TmdbLoadPhase.idle;
    } on TmdbAuthException catch (error) {
      if (_disposed || generation != _generation) return;
      _error = AppError(
        AppErrorKind.tmdbAuth,
        'TMDB 鉴权失败',
        detail: error.message,
        statusCode: error.statusCode,
      );
      _phase = TmdbLoadPhase.failed;
    } on AppError catch (error) {
      if (_disposed || generation != _generation) return;
      _error = error;
      _phase = TmdbLoadPhase.failed;
    } catch (error) {
      if (_disposed || generation != _generation) return;
      _error = AppError(
        AppErrorKind.tmdbNetwork,
        'TMDB 请求失败',
        detail: '$error',
        retryable: true,
      );
      _phase = TmdbLoadPhase.failed;
    } finally {
      if (!_disposed && generation == _generation) {
        _busy = false;
        notifyListeners();
      }
    }
  }

  /// 从站源 `Vod` 开始一次完整的 TMDB 增强加载（`04` §3.3）。
  ///
  /// 流程：匹配 → 详情（含季度解析）→ 剧集元数据 → 相关视频。
  ///
  /// 契约：
  /// - 任何一步失败只影响 TMDB 区块（`04` §3.4），不抛出、不阻塞浏览与播放；
  /// - 未配置 / 站点禁用时 `beginLoad` 直接进入 `disabled`，**零请求**；
  /// - 每次异步回跳都校验代际与外部运行号，迟到响应一律丢弃（`04` §2.2）。
  Future<void> loadForVod(
    Vod vod, {
    required String siteKey,
    String siteName = '',
    int configId = 0,
    List<VodPlayLine>? lines,
  }) async {
    final playLines = lines ?? parsePlayLines(vod.vodPlayFrom, vod.vodPlayUrl);
    if (playLines.isEmpty) return;
    _playLines = playLines;

    // 保持「换线路时选定的线路」（`04` §3.1 ④）。
    //
    // 为什么：`reloadTmdb` 会重跑整条加载链，早期实现固定取 `playLines.first`，
    // 于是用户点了「线路二」→ 触发 reload → 当前线路被悄悄改回线路一，
    // 剧集卡片又变回线路一的集（用户看到的「点了线路没反应」）。
    // 这里保留已在列表里的当前线路，只在其失效时才回落到第一条。
    VodPlayLine? keep;
    for (final candidate in playLines) {
      if (candidate.flag == _selectedLineFlag) {
        keep = candidate;
        break;
      }
    }
    final line = keep == null
        ? sourceLineOf(playLines.first, 0)
        : sourceLineOf(
            keep,
            playLines.indexOf(keep),
            unique: _isFlagUnique(keep.flag),
          );
    // 记录实际采用的线路，使后续 `reloadTmdb` 继续保留它，
    // 并让「季度记忆」能按线路归档（见 _lineSeasonMemory）。
    //
    // 首次加载时 `keep` 为 null（还没有用户选择），此时必须记为**实际使用的**
    // 第一条线路，否则 `_selectedLineFlag` 为空 → 季度记忆归不到任何线路
    // → 切走再切回时恢复不了（用户反馈的「又转换一次」）。
    _selectedLineFlag = keep?.flag ?? playLines.first.flag;

    // 同一部作品的 TMDB 数据在**所有线路之间共用**（用户反馈 2026-10-08：
    // 「多线路貌似没共用同一份 tmdb 数据或缓存」）。
    //
    // 上游 `TmdbUIAdapter` 同样只在**作品维度**加载一次详情/演职人员/推荐，
    // 换线路只重跑季度解析与选集（`seasonEpisodeCache` 按
    // `tmdbId|mediaType|season` 缓存，也不随线路失效）。
    //
    // 因此区分「同一作品」与「换了作品」：同一作品复用已加载数据，不重发请求。
    final sameTitle = _isSameTitle(vodId: vod.vodId, sourceTitle: vod.vodName);
    final generation = beginLoad(
      siteKey: siteKey,
      vodId: vod.vodId,
      sourceTitle: vod.vodName,
      vod: vod,
      line: line,
      configId: configId,
      siteName: siteName,
      keepTitleData: sameTitle,
    );
    if (!_valid(generation)) return;
    // 未配置 / 站点禁用：beginLoad 已进入 disabled，不得发起任何请求
    if (_phase == TmdbLoadPhase.disabled) return;

    final config = _config();
    await loadMatch(
      generation: generation,
      sourceTitle: vod.vodName,
      siteName: siteName,
    );
    if (!_valid(generation) || !hasMatch) return;

    // 详情已缓存且是同一作品 → 跳过详情请求，只重跑季度解析（零网络）。
    final hasDetail = _detail != null && sameTitle;
    await loadDetail(
      generation: generation,
      // 季集数以详情响应为权威（`loadDetail` 会从 `seasons[]` 回填）
      tmdbSeasons: const [],
      seasonCounts: const {},
      allowHeuristicGuessing: config.heuristicSeasonGuessing,
      reuseDetail: hasDetail,
    );
    if (!_valid(generation)) return;

    await loadEpisodes(generation: generation);
    if (!_valid(generation)) return;

    // 相关视频也只在作品维度加载一次（换线路不重发）。
    if (!hasDetail || _videos.isEmpty) {
      await loadVideos(generation: generation);
    }
  }

  /// 是否为**同一部作品**（决定 TMDB 数据能否跨线路复用）。
  ///
  /// 用 `vodId` + 源标题判定：换线路时两者都不变（线路是 `Vod` 内的字段），
  /// 换作品时至少有一个变化。这是「作品维度」与「线路维度」的分界。
  ///
  /// 注意**不能用 `_detail != null`**：`loadMatch` 为了构造匹配记录快照，内部
  /// 会先请求一次详情（`includeRelated: false`），因此首次加载时 `_detail`
  /// 尚未赋值，用它会把自己的第二次调用误判成「换了作品」。
  /// 这里以**已匹配的身份**为准：只要作品身份没变，就是同一部作品。
  bool _isSameTitle({required String vodId, required String sourceTitle}) {
    if (_vodId != vodId || _sourceTitle != sourceTitle) return false;
    // 首次加载（还没有任何匹配结论）→ 不是「同一作品」，需要完整加载。
    return _matchResult is TmdbMatchHit || _detail != null;
  }

  bool _valid(int generation) =>
      !_disposed && generation == _generation && _isCurrentRun();

  /// 线路绑定键（`04` §2.3）。
  ///
  /// 同一详情内 `line.flag` 唯一时 `flagKey == line.flag`，减少绑定碎片。
  static String flagKeyOf(VodPlayLine line, int index, {bool unique = true}) =>
      unique ? line.flag : '${line.flag}#$index';

  /// 由线路构造季度解析输入（`02` §2.2）。
  static TmdbSourceLine sourceLineOf(
    VodPlayLine line,
    int index, {
    bool unique = true,
  }) {
    final seasons = <int>[];
    final numbers = <int>[];
    for (final episode in line.episodes) {
      seasons.add(sourceSeasonNumber(episode.name));
      numbers.add(episodeNumberFromName(episode.name));
    }
    final hasExplicit = seasons.any((season) => season >= 0);
    return TmdbSourceLine(
      flagKey: flagKeyOf(line, index, unique: unique),
      sourceFlag: line.displayName,
      episodeNames: line.episodes.map((episode) => episode.name).toList(),
      episodeUrls: line.episodes.map((episode) => episode.url).toList(),
      sourceSeasonNumbers: seasons,
      sourceEpisodeNumbers: numbers,
      // 仅在存在显式季度时提供，否则保持 `null`（不猜测）
      explicitEpisodeSeasons: hasExplicit ? seasons : null,
    );
  }

  /// 加载详情 + 季度 + 剧集。
  Future<void> loadDetail({
    required int generation,
    required List<int> tmdbSeasons,
    required Map<int, int> seasonCounts,
    int requestSeason = -1,
    bool allowHeuristicGuessing = true,
    bool reuseDetail = false,
  }) async {
    if (_disposed || generation != _generation) return;
    final currentItem = item;
    if (currentItem == null) return;

    // 同一作品换线路：详情响应已在内存，**零请求**直接用。
    // 上游 `TmdbUIAdapter` 的详情/演职人员/推荐同样只在作品维度加载一次。
    final cached = reuseDetail ? _detail : null;
    if (cached == null) {
      _busy = true;
      notifyListeners();
    }
    try {
      final detail = cached ?? await _service.detail(currentItem);
      if (_disposed || generation != _generation) return;
      if (cached == null) {
        _detail = detail;
        _cast = _service.cast(detail);
        _creators = _service.creators(detail);
        _photos = _service.photos(detail, preferLandscape: true);
        _recommendations = [
          ..._service.recommendationsFromDetail(detail),
          ..._service.similarFromDetail(detail),
        ];
      }
      _seasonEpisodeCounts = _seasonCountsFromDetail(detail, seasonCounts);
      // 季集数以详情响应为权威：调用方未给时从 `seasons[]` 回填（`02` §3）。
      final effectiveSeasons = tmdbSeasons.isNotEmpty
          ? tmdbSeasons
          : (_seasonEpisodeCounts.keys.toList()..sort());

      // 季度解析（含落盘）
      final line = _activeLine;
      if (line != null) {
        // 换线路时携带的季度意图优先于调用方默认值（见 selectLine 注释）。
        final preferred = takePreferredSeason();
        final outcome = _seasonService.resolve(
          TmdbSeasonResolveRequest(
            siteKey: _siteKey,
            vodId: _vodId,
            sourceTitle: _sourceTitle,
            line: line,
            tmdbId: currentItem.tmdbId,
            tmdbSeasons: effectiveSeasons,
            seasonCounts: _seasonEpisodeCounts,
            requestSeason: preferred >= 0 ? preferred : requestSeason,
            allowHeuristicGuessing: allowHeuristicGuessing,
          ),
          configId: _configId,
        );
        if (_disposed || generation != _generation) return;
        _resolution = outcome.resolution;
        _availableSeasons = outcome.availableSeasons;
        // 采纳**解析器确证的季度**（`02` §3.2）。
        //
        // 为什么必须优先采纳：请求季度（来自换线路的意图/记忆，或调用方）被
        // 解析器接受后会体现为 `KnownSeason(n)`。早期实现无条件用
        // `_defaultSeasonOf(availableSeasons)` 覆盖它，于是「记住的第 2 季」
        // 被改回第 1 季（用户反馈的「切回线路后又会重新转换一次」）。
        final scope = outcome.resolution.scope;
        if (scope is KnownSeason) {
          _selectedSeason = scope.seasonNumber;
        } else if (_selectedSeason < 0 && _availableSeasons.isNotEmpty) {
          // 无法确证单季（或调用方未指定）→ 默认选中第一项，使多季作品
          // 无需手动切换即有内容（`04` §4.1）。
          //
          // 但**特别篇（0）不作为默认**：特别篇是附加内容，默认打开「特别篇」
          // 会让用户以为正片只有几集。`availableSeasons` 由 `02` §4.3 的可播放
          // 季度解析器确证，因此从其中挑第一个正片季度不是猜测。
          _selectedSeason = _defaultSeasonOf(_availableSeasons);
        }
        // 换线路后的自愈：解析出的季度若在该线路上**一集都没有**，
        // 换成该线路上真有集的那一季（否则剧集区空白，见 reconcileSeasonWithLine）。
        reconcileSeasonWithLine();
        // 把最终选定的季度记入线路记忆（含首次自动选定的默认季），
        // 使「切走 → 切回」能回到同一季。
        _rememberLineSeason(_selectedLineFlag, _selectedSeason);
      }
      _phase = TmdbLoadPhase.ready;
    } on TmdbCancelledException {
      if (_disposed || generation != _generation) return;
      _phase = TmdbLoadPhase.idle;
    } on TmdbAuthException catch (error) {
      if (_disposed || generation != _generation) return;
      _error = AppError(
        AppErrorKind.tmdbAuth,
        'TMDB 鉴权失败',
        detail: error.message,
        statusCode: error.statusCode,
      );
      _phase = TmdbLoadPhase.failed;
    } on AppError catch (error) {
      if (_disposed || generation != _generation) return;
      _error = error;
      _phase = TmdbLoadPhase.failed;
    } catch (error) {
      if (_disposed || generation != _generation) return;
      _error = AppError(
        AppErrorKind.tmdbNetwork,
        'TMDB 请求失败',
        detail: '$error',
        retryable: true,
      );
      _phase = TmdbLoadPhase.failed;
    } finally {
      if (!_disposed && generation == _generation) {
        _busy = false;
        notifyListeners();
      }
    }
  }

  /// 加载当前季度的剧集元数据（递增元数据代际）。
  Future<void> loadEpisodes({required int generation}) async {
    if (_disposed || generation != _generation) return;
    final currentItem = item;
    if (currentItem == null || !currentItem.isTv || _selectedSeason < 0) return;

    _metadataGeneration++;
    final metadataGeneration = _metadataGeneration;
    try {
      final episodes = await _service.seasonEpisodes(
        currentItem,
        _selectedSeason,
      );
      if (_disposed ||
          generation != _generation ||
          metadataGeneration != _metadataGeneration) {
        return;
      }
      _episodes = episodes;
      notifyListeners();
    } on TmdbCancelledException {
      return;
    } catch (_) {
      // 剧集元数据失败不影响选集（保留来源集名，`04` §3.4）
      if (_disposed || generation != _generation) return;
      _episodes = const [];
      notifyListeners();
    }
  }

  /// 加载相关视频（失败不影响其他区块）。
  Future<void> loadVideos({required int generation}) async {
    if (_disposed || generation != _generation) return;
    final currentItem = item;
    if (currentItem == null) return;
    try {
      final videos = await _service.videos(
        currentItem,
        seasonNumber: _selectedSeason >= 0 ? _selectedSeason : null,
      );
      if (_disposed || generation != _generation) return;
      _videos = videos;
      notifyListeners();
    } catch (_) {
      if (_disposed || generation != _generation) return;
      _videos = const [];
      notifyListeners();
    }
  }

  /// 当前线路在某个季度下是否有可渲染的集（用于换线路后的季度自愈）。
  ///
  /// 只看**来源季度信号**（不依赖 TMDB 元数据，元数据是异步到的）：
  /// 这正是用户能看到的「这条线路到底有没有这一季」。
  bool lineHasEpisodesInSeason(int seasonNumber) {
    final line = _activeLine;
    if (line == null || seasonNumber < 0) return false;
    for (final name in line.episodeNames) {
      final season = sourceSeasonNumber(name);
      // 未分类的集无法证明不属于该季 → 视为有集（不得丢集）
      if (season < 0 || season == seasonNumber) return true;
    }
    return false;
  }

  /// 换线路后把季度调整到**该线路上真有集**的那一季。
  ///
  /// 为什么需要：用户从「线路一（S1+S2）」切到「线路二（只有 S2）」时，
  /// 若仍停留在 S1，线路二在 S1 下一集都没有，剧集区会空白——用户看到的是
  /// 「点了线路什么都不显示」。这里在 `availableSeasons` 里挑第一个**在该线路
  /// 真有集**的季度；挑不到就保持原值（由 UI 显示空态，不猜）。
  ///
  /// 返回是否发生了调整（调用方据此决定要不要重新拉取剧集元数据）。
  bool reconcileSeasonWithLine() {
    if (_disposed || _activeLine == null) return false;
    if (lineHasEpisodesInSeason(_selectedSeason)) return false;
    for (final season in _availableSeasons) {
      if (lineHasEpisodesInSeason(season)) {
        _selectedSeason = season;
        _episodes = const [];
        notifyListeners();
        return true;
      }
    }
    return false;
  }

  /// 切换季度（`04` §4.3）。
  ///
  /// 只改季度，不改线路。
  void selectSeason(int seasonNumber) {
    if (_disposed) return;
    if (!_availableSeasons.contains(seasonNumber)) return;
    if (_selectedSeason == seasonNumber) return;
    _selectedSeason = seasonNumber;
    // 记住本线路的选择，换走再回来时恢复（见 _lineSeasonMemory）。
    _rememberLineSeason(_selectedLineFlag, seasonNumber);
    // 清空旧季度剧集，避免残留（`04` §4.3）
    _episodes = const [];
    notifyListeners();
  }

  /// 应用剧集元数据到线路（`02` §9）。
  ///
  /// **只作用于当前季度**（`02` §9.4）：一条线路可能同时包含多季的集
  /// （例如 S1 12 集 + S2 10 集且未做分段绑定），此时把 S2 的元数据写到 S1 的
  /// 集上会让标题串季。因此先筛出「属于当前季度的集」与「未分类的集」
  /// （未分类不得被静默丢弃，`02` §9.4 末条），只对它们应用。
  TmdbEpisodeEnrichmentResult applyEpisodesToLine(VodPlayLine line) {
    TmdbEpisodeEnrichmentResult unchanged(String reason) =>
        TmdbEpisodeEnrichmentResult(
          line: line,
          changed: false,
          appliedCount: 0,
          rejectedReason: reason,
        );
    if (_disposed || _selectedSeason < 0 || _episodes.isEmpty) {
      return unchanged('no_metadata');
    }

    final applicable = <int>[];
    for (var index = 0; index < line.episodes.length; index++) {
      final season = sourceSeasonNumber(line.episodes[index].name);
      if (season < 0 || season == _selectedSeason) applicable.add(index);
    }
    if (applicable.isEmpty) return unchanged('no_applicable_episode');

    final subset = VodPlayLine(
      flag: line.flag,
      episodes: applicable.map((index) => line.episodes[index]).toList(),
    );
    final result = _enrichmentService.applyEpisodeMetadata(
      line: subset,
      request: TmdbEpisodeEnrichment(
        seasonNumber: _selectedSeason,
        tmdbEpisodes: _episodes,
        generation: _generation,
        metadataGeneration: _metadataGeneration,
        seasonEpisodeCount: _episodes.length,
      ),
      currentGeneration: _generation,
      currentMetadataGeneration: _metadataGeneration,
    );
    if (!result.changed) return unchanged(result.rejectedReason ?? 'no_change');

    final merged = List<VodEpisode>.from(line.episodes);
    for (var offset = 0; offset < applicable.length; offset++) {
      merged[applicable[offset]] = result.line.episodes[offset];
    }
    return TmdbEpisodeEnrichmentResult(
      line: VodPlayLine(flag: line.flag, episodes: merged),
      changed: true,
      appliedCount: result.appliedCount,
    );
  }

  /// 头部补位（`04` §3.2）。
  TmdbEnrichmentResult enrich(Vod vod) {
    final currentItem = item;
    if (_disposed || currentItem == null) {
      return TmdbEnrichmentResult(vod: vod);
    }
    return _enrichmentService.enrichVod(
      vod: vod,
      item: currentItem,
      detail: _detail,
      sourceTitle: _sourceTitle,
    );
  }

  /// 清空状态（离开详情页时调用，`04` §2.2）。
  void clear() {
    if (_disposed) return;
    _generation++;
    _metadataGeneration++;
    _phase = TmdbLoadPhase.idle;
    _error = null;
    _matchResult = null;
    _detail = null;
    _resolution = null;
    _availableSeasons = const [];
    _selectedSeason = -1;
    _seasonEpisodeCounts = const {};
    _episodes = const [];
    _cast = const [];
    _creators = const [];
    _recommendations = const [];
    _videos = const [];
    _photos = const [];
    _busy = false;
    _vod = null;
    _activeLine = null;
    notifyListeners();
  }

  /// 清除错误（用户点击重试时）。
  void clearError() {
    if (_disposed || _error == null) return;
    _error = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    // 递增代际，使全部在途请求的回调失效（`04` §2.2）
    _generation++;
    _metadataGeneration++;
    super.dispose();
  }

  /// 默认选中季度（`04` §4.1）：优先第一个**非特别篇**季度。
  ///
  /// 仅当可播放季度只有特别篇时才回退到 `0`。
  static int _defaultSeasonOf(List<int> availableSeasons) {
    for (final season in availableSeasons) {
      if (season > 0) return season;
    }
    return availableSeasons.first;
  }

  Map<int, int> _seasonCountsFromDetail(
    Map<String, Object?> detail,
    Map<int, int> fallback,
  ) {
    final seasons = detail['seasons'];
    if (seasons is! List) return fallback;
    final counts = <int, int>{};
    for (final raw in seasons) {
      if (raw is! Map) continue;
      final number = raw['season_number'];
      final count = raw['episode_count'];
      final seasonNumber = number is int ? number : (number is num ? number.toInt() : null);
      final episodeCount = count is int ? count : (count is num ? count.toInt() : null);
      if (seasonNumber == null || episodeCount == null) continue;
      if (episodeCount <= 0) continue;
      counts[seasonNumber] = episodeCount;
    }
    return counts.isEmpty ? fallback : counts;
  }
}
