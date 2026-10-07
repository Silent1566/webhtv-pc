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
  void selectLine(String flag) {
    if (_disposed) return;
    final line = lineByFlag(flag);
    if (line == null) return;
    if (_activeLine?.flagKey == flag) return;
    _activeLine = sourceLineOf(line, 0, unique: _isFlagUnique(flag));
    // 线路变了 → 旧季度的剧集元数据不再适用
    _episodes = const [];
    _selectedSeason = -1;
    _availableSeasons = const [];
    _resolution = null;
    notifyListeners();
  }

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

  /// TMDB 区块是否应渲染（未配置 / 站点禁用时不渲染，`04` §3.1）。
  bool get shouldRender =>
      _phase != TmdbLoadPhase.disabled && _phase != TmdbLoadPhase.idle;

  /// 季度导航是否需要显示切换控件（> 1 季）。
  bool get hasSeasonSwitcher => _availableSeasons.length > 1;

  /// 评分文案（`04` §3.2）。
  String get ratingText => TmdbEnrichmentService.ratingText(
    tmdbRating: item?.tmdbRating ?? 0,
    matched: hasMatch,
  );

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
    _detail = null;
    _episodes = const [];
    _cast = const [];
    _creators = const [];
    _recommendations = const [];
    _videos = const [];
    _photos = const [];
    _seasonEpisodeCounts = const {};
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

    final line = sourceLineOf(playLines.first, 0);
    final generation = beginLoad(
      siteKey: siteKey,
      vodId: vod.vodId,
      sourceTitle: vod.vodName,
      vod: vod,
      line: line,
      configId: configId,
      siteName: siteName,
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

    await loadDetail(
      generation: generation,
      // 季集数以详情响应为权威（`loadDetail` 会从 `seasons[]` 回填）
      tmdbSeasons: const [],
      seasonCounts: const {},
      allowHeuristicGuessing: config.heuristicSeasonGuessing,
    );
    if (!_valid(generation)) return;

    await loadEpisodes(generation: generation);
    if (!_valid(generation)) return;

    await loadVideos(generation: generation);
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
  }) async {
    if (_disposed || generation != _generation) return;
    final currentItem = item;
    if (currentItem == null) return;

    _busy = true;
    notifyListeners();
    try {
      final detail = await _service.detail(currentItem);
      if (_disposed || generation != _generation) return;
      _detail = detail;
      _cast = _service.cast(detail);
      _creators = _service.creators(detail);
      _photos = _service.photos(detail, preferLandscape: true);
      _recommendations = [
        ..._service.recommendationsFromDetail(detail),
        ..._service.similarFromDetail(detail),
      ];
      _seasonEpisodeCounts = _seasonCountsFromDetail(detail, seasonCounts);
      // 季集数以详情响应为权威：调用方未给时从 `seasons[]` 回填（`02` §3）。
      final effectiveSeasons = tmdbSeasons.isNotEmpty
          ? tmdbSeasons
          : (_seasonEpisodeCounts.keys.toList()..sort());

      // 季度解析（含落盘）
      final line = _activeLine;
      if (line != null) {
        final outcome = _seasonService.resolve(
          TmdbSeasonResolveRequest(
            siteKey: _siteKey,
            vodId: _vodId,
            sourceTitle: _sourceTitle,
            line: line,
            tmdbId: currentItem.tmdbId,
            tmdbSeasons: effectiveSeasons,
            seasonCounts: _seasonEpisodeCounts,
            requestSeason: requestSeason,
            allowHeuristicGuessing: allowHeuristicGuessing,
          ),
          configId: _configId,
        );
        if (_disposed || generation != _generation) return;
        _resolution = outcome.resolution;
        _availableSeasons = outcome.availableSeasons;
        if (_selectedSeason < 0 && _availableSeasons.isNotEmpty) {
          // 默认选第一项，使多季作品无需手动切换即有内容（`04` §4.1）。
          _selectedSeason = _availableSeasons.first;
        }
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

  /// 切换季度（`04` §4.3）。
  ///
  /// 只改季度，不改线路。
  void selectSeason(int seasonNumber) {
    if (_disposed) return;
    if (!_availableSeasons.contains(seasonNumber)) return;
    if (_selectedSeason == seasonNumber) return;
    _selectedSeason = seasonNumber;
    // 清空旧季度剧集，避免残留（`04` §4.3）
    _episodes = const [];
    notifyListeners();
  }

  /// 应用剧集元数据到线路（`02` §9）。
  TmdbEpisodeEnrichmentResult applyEpisodesToLine(VodPlayLine line) {
    if (_disposed || _selectedSeason < 0 || _episodes.isEmpty) {
      return TmdbEpisodeEnrichmentResult(
        line: line,
        changed: false,
        appliedCount: 0,
        rejectedReason: 'no_metadata',
      );
    }
    return _enrichmentService.applyEpisodeMetadata(
      line: line,
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
