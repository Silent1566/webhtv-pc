/// TMDB 季度解析、绑定与进度编排（`docs/phase4/design/02` §3–§7）。
///
/// 把纯逻辑（`tmdb_season`）与存储（`AppDatabase`）串起来，负责：
/// - 线路级季度解析（含自动落盘判定）；
/// - 手动绑定的保存/清除/失效；
/// - 季度进度的写入与读取（含历史投影与换源候选）。
///
/// 关键契约：
/// - 只有结果唯一时才自动落盘（`02` §3.4）；
/// - `ambiguous` **不覆盖**已有高置信绑定（`02` §3.4）；
/// - `UnknownSeason` **不写**季度进度（`02` §6.2）。
library;

import '../core/tmdb_identity.dart';
import '../core/tmdb_season.dart';
import '../core/tmdb_title.dart';

/// 一条来源线路的结构快照（供解析器与指纹使用）。
class TmdbSourceLine {
  const TmdbSourceLine({
    required this.flagKey,
    required this.sourceFlag,
    required this.episodeNames,
    this.episodeUrls = const [],
    this.sourceSeasonNumbers,
    this.sourceEpisodeNumbers,
    this.explicitEpisodeSeasons,
  });

  /// 线路绑定键（`02` §2.2）。
  final String flagKey;

  /// 线路显示名。
  final String sourceFlag;

  /// 每集原始名称（用于指纹与元数据应用）。
  final List<String> episodeNames;

  /// 每集地址（用于续播与消歧，`04` §8.2）。
  final List<String> episodeUrls;

  /// 每集解析出的季度号（`-1` 未知，`0` 特别篇）。
  final List<int>? sourceSeasonNumbers;

  /// 每集解析出的集号（可空）。
  final List<int>? sourceEpisodeNumbers;

  /// 每集解析出的季度号（可空，用于分段校验）。
  final List<int>? explicitEpisodeSeasons;

  int get episodeCount => episodeNames.length;

  /// 稳定指纹（不含 URL，`02` §2.5）。
  String stableFingerprint() =>
      SourceFingerprint.stable(flagKey: flagKey, episodeNames: episodeNames);

  /// 结构指纹（含季度集数映射）。
  String structureFingerprint(Map<int, int> seasonCounts) =>
      SourceFingerprint.structure(
        flagKey: flagKey,
        episodeNames: episodeNames,
        seasonCounts: seasonCounts,
      );
}

/// 季度解析请求。
class TmdbSeasonResolveRequest {
  const TmdbSeasonResolveRequest({
    required this.siteKey,
    required this.vodId,
    required this.sourceTitle,
    required this.line,
    required this.tmdbId,
    required this.tmdbSeasons,
    required this.seasonCounts,
    this.requestSeason = -1,
    this.allowHeuristicGuessing = true,
  });

  final String siteKey;
  final String vodId;
  final String sourceTitle;
  final TmdbSourceLine line;
  final int tmdbId;
  final List<int> tmdbSeasons;
  final Map<int, int> seasonCounts;
  final int requestSeason;
  final bool allowHeuristicGuessing;
}

/// 解析结果（含可播放季度）。
class TmdbSeasonResolveOutcome {
  const TmdbSeasonResolveOutcome({
    required this.resolution,
    required this.availableSeasons,
    required this.persisted,
  });

  final Resolution resolution;

  /// 可播放季度（`02` §4.3）；空表示退化为扁平列表。
  final List<int> availableSeasons;

  /// 是否已自动落盘（仅结果唯一时为真，`02` §3.4）。
  final bool persisted;

  SeasonScope get scope => resolution.scope;
}

/// 季度进度快照（`02` §6.1）。
class TmdbSeasonProgressRecord {
  const TmdbSeasonProgressRecord({
    required this.configId,
    required this.mediaType,
    required this.tmdbId,
    required this.seasonNumber,
    required this.episodeNumber,
    required this.positionMs,
    required this.durationMs,
    required this.sourceFlag,
    required this.sourceEpisodeName,
    required this.sourceEpisodeUrl,
    required this.sourceHistoryKey,
    required this.sourceBindingKey,
    required this.updatedAt,
  });

  final int configId;
  final String mediaType;
  final int tmdbId;
  final int seasonNumber;
  final int episodeNumber;
  final int positionMs;
  final int durationMs;
  final String sourceFlag;
  final String sourceEpisodeName;
  final String sourceEpisodeUrl;
  final String sourceHistoryKey;
  final String sourceBindingKey;
  final int updatedAt;

  TmdbIdentity? get identity => TmdbIdentity.parse('$mediaType:$tmdbId');

  /// 季度身份键（`02` §2.1）。
  String get identityKey => '$mediaType:$tmdbId:season:$seasonNumber';
}

/// 季度绑定持久化接口。
abstract interface class TmdbSeasonStore {
  SeasonBinding? findBinding({
    required int configId,
    required String siteKey,
    required String vodId,
    required String sourceTitle,
    required String flagKey,
  });

  void saveBinding({
    required int configId,
    required SeasonBinding binding,
  });

  void removeBinding({
    required int configId,
    required String siteKey,
    required String vodId,
    String? sourceTitle,
    String? flagKey,
  });

  void saveRouteBinding({
    required int configId,
    required RouteBinding binding,
  });

  void removeRouteBinding({
    required int configId,
    required String siteKey,
    required String vodId,
    required String flagKey,
  });

  List<RouteBinding> routeBindings({
    required int configId,
    required int tmdbId,
    required String mediaType,
  });

  TmdbSeasonProgressRecord? findProgress({
    required int configId,
    required String mediaType,
    required int tmdbId,
    required int seasonNumber,
  });

  void saveProgress({
    required int configId,
    required TmdbSeasonProgressRecord record,
  });

  List<TmdbSeasonProgressRecord> progressForMedia({
    required int configId,
    required String mediaType,
    required int tmdbId,
  });

  int removeProgress({
    required int configId,
    required String mediaType,
    required int tmdbId,
    required int seasonNumber,
  });

  int removeProgressForMedia({
    required int configId,
    required String mediaType,
    required int tmdbId,
  });
}

/// 内存实现（单测用）。
class InMemoryTmdbSeasonStore implements TmdbSeasonStore {
  final Map<String, SeasonBinding> bindings = {};
  final Map<String, RouteBinding> routes = {};
  final Map<String, TmdbSeasonProgressRecord> progress = {};

  String _bindingKey(int configId, String siteKey, String vodId, String title, String flag) =>
      '$configId|$siteKey|$vodId|$title|$flag';

  String _routeKey(int configId, String siteKey, String vodId, String flag) =>
      '$configId|$siteKey|$vodId|$flag';

  String _progressKey(int configId, String mediaType, int tmdbId, int season) =>
      '$configId|$mediaType|$tmdbId|$season';

  @override
  SeasonBinding? findBinding({
    required int configId,
    required String siteKey,
    required String vodId,
    required String sourceTitle,
    required String flagKey,
  }) => bindings[_bindingKey(configId, siteKey, vodId, sourceTitle, flagKey)];

  @override
  void saveBinding({required int configId, required SeasonBinding binding}) {
    bindings[_bindingKey(
      configId,
      binding.siteKey,
      binding.vodId,
      binding.sourceTitle,
      binding.flagKey,
    )] = binding;
  }

  @override
  void removeBinding({
    required int configId,
    required String siteKey,
    required String vodId,
    String? sourceTitle,
    String? flagKey,
  }) {
    bindings.removeWhere((key, value) {
      if (value.siteKey != siteKey || value.vodId != vodId) return false;
      if (sourceTitle != null && value.sourceTitle != sourceTitle) return false;
      if (flagKey != null && value.flagKey != flagKey) return false;
      return true;
    });
  }

  @override
  void saveRouteBinding({required int configId, required RouteBinding binding}) {
    routes[_routeKey(configId, binding.siteKey, binding.vodId, binding.flagKey)] =
        binding;
  }

  @override
  void removeRouteBinding({
    required int configId,
    required String siteKey,
    required String vodId,
    required String flagKey,
  }) {
    routes.remove(_routeKey(configId, siteKey, vodId, flagKey));
  }

  @override
  List<RouteBinding> routeBindings({
    required int configId,
    required int tmdbId,
    required String mediaType,
  }) {
    final result = routes.values
        .where(
          (binding) =>
              binding.tmdbId == tmdbId && binding.mediaType.name == mediaType,
        )
        .toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return result;
  }

  @override
  TmdbSeasonProgressRecord? findProgress({
    required int configId,
    required String mediaType,
    required int tmdbId,
    required int seasonNumber,
  }) => progress[_progressKey(configId, mediaType, tmdbId, seasonNumber)];

  @override
  void saveProgress({
    required int configId,
    required TmdbSeasonProgressRecord record,
  }) {
    progress[_progressKey(
      configId,
      record.mediaType,
      record.tmdbId,
      record.seasonNumber,
    )] = record;
  }

  @override
  List<TmdbSeasonProgressRecord> progressForMedia({
    required int configId,
    required String mediaType,
    required int tmdbId,
  }) {
    final result = progress.values
        .where(
          (record) => record.tmdbId == tmdbId && record.mediaType == mediaType,
        )
        .toList()
      ..sort((a, b) => a.seasonNumber.compareTo(b.seasonNumber));
    return result;
  }

  @override
  int removeProgress({
    required int configId,
    required String mediaType,
    required int tmdbId,
    required int seasonNumber,
  }) =>
      progress.remove(_progressKey(configId, mediaType, tmdbId, seasonNumber)) == null
      ? 0
      : 1;

  @override
  int removeProgressForMedia({
    required int configId,
    required String mediaType,
    required int tmdbId,
  }) {
    final before = progress.length;
    progress.removeWhere(
      (key, record) =>
          record.tmdbId == tmdbId && record.mediaType == mediaType,
    );
    return before - progress.length;
  }
}

/// 季度解析与进度编排服务。
class TmdbSeasonService {
  TmdbSeasonService({
    required TmdbSeasonStore store,
    DateTime Function()? clock,
    int maxRouteBindings = 512,
  }) : _store = store,
       _clock = clock ?? DateTime.now,
       _maxRouteBindings = maxRouteBindings;

  // ignore_for_file: prefer_initializing_formals
  final TmdbSeasonStore _store;
  final DateTime Function() _clock;
  final int _maxRouteBindings;

  /// 解析季度并（在唯一时）落盘（`02` §3.3/§3.4）。
  TmdbSeasonResolveOutcome resolve(
    TmdbSeasonResolveRequest request, {
    int configId = 0,
    bool allowLegacyFallback = false,
  }) {
    final binding = _store.findBinding(
      configId: configId,
      siteKey: request.siteKey,
      vodId: request.vodId,
      sourceTitle: request.sourceTitle,
      flagKey: request.line.flagKey,
    );
    final legacy = (!allowLegacyFallback || binding != null)
        ? null
        : _store.findBinding(
            configId: configId,
            siteKey: request.siteKey,
            vodId: request.vodId,
            sourceTitle: request.sourceTitle,
            flagKey: '',
          );
    final effective = binding ?? legacy;

    final resolution = TmdbSeasonResolver.resolve(
      SeasonResolveInput(
        requestSeason: request.requestSeason,
        manualBinding: effective,
        explicitSourceSeasons: request.line.sourceSeasonNumbers ?? const [],
        titleSeason: sourceSeasonNumber(request.sourceTitle),
        tmdbSeasons: request.tmdbSeasons,
        seasonCounts: request.seasonCounts,
        sourceEpisodeCount: request.line.episodeCount,
        sourceEpisodeNumbers: request.line.sourceEpisodeNumbers,
        explicitEpisodeSeasons: request.line.explicitEpisodeSeasons,
        allowHeuristicGuessing: request.allowHeuristicGuessing,
      ),
    );

    final available = _availableFor(
      request: request,
      binding: effective,
      resolution: resolution,
    );
    // 自动落盘：仅结果唯一，且不覆盖已有的手动绑定（`02` §3.4）。
    var persisted = false;
    if (resolution.canPersist &&
        effective == null &&
        resolution.status != ResolutionStatus.flat) {
      persisted = _persistAutoBinding(
        configId: configId,
        request: request,
        resolution: resolution,
      );
    }

    return TmdbSeasonResolveOutcome(
      resolution: resolution,
      availableSeasons: available,
      persisted: persisted,
    );
  }

  /// 可播放季度（`02` §4.3）。
  ///
  /// 自动解析按 A–G 六级顺序从**线路**推导；但用户的手动绑定是显式决策，
  /// 必须优先（`02` §5.3「线路级季度绑定」、`04` §5.3「仅选季度」）：
  /// - `manualSeason` → 只保留该季（不在 TMDB 季度列表时退化为空）；
  /// - `manualMultiSlice` → 分段所属季度（需分段仍有效）；
  /// - `manualFlat` → 空（扁平列表，无季度导航）。
  ///
  /// 不这样做的话，「仅选季度」只会改绑定记录，而详情页仍按线路推导出的
  /// 旧季度渲染，用户看不到任何变化。
  List<int> _availableFor({
    required TmdbSeasonResolveRequest request,
    required SeasonBinding? binding,
    required Resolution resolution,
  }) {
    if (binding != null &&
        binding.matches(request.tmdbId) &&
        binding.mode != SeasonBindingMode.manualFlat) {
      switch (binding.mode) {
        case SeasonBindingMode.manualSeason:
          final season = binding.seasonNumber;
          if (season != null &&
              season >= 0 &&
              request.tmdbSeasons.contains(season)) {
            return [season];
          }
          return const [];
        case SeasonBindingMode.manualMultiSlice:
          if (hasValidPersistedSegments(
            segments: binding.segments,
            tmdbSeasons: request.tmdbSeasons,
            seasonCounts: request.seasonCounts,
            sourceEpisodeCount: request.line.episodeCount,
          )) {
            final seasons = <int>[];
            for (final segment in binding.segments) {
              if (!seasons.contains(segment.seasonNumber)) {
                seasons.add(segment.seasonNumber);
              }
            }
            return seasons;
          }
          // 分段失效 → 回退到自动推导（`02` §3.3 第 4 步语义）
          break;
        case SeasonBindingMode.manualFlat:
          return const [];
      }
    }
    // 自动落盘绑定（`02` §3.4）也是权威来源：解析结论已确证时直接采用。
    if (binding != null &&
        binding.matches(request.tmdbId) &&
        resolution.scope.isKnown) {
      return resolution.scope.seasons;
    }
    return resolveAvailableSeasons(
      sourceSeasonNumbers:
          request.line.sourceSeasonNumbers ??
          List<int>.filled(request.line.episodeCount, -1),
      titleSeason: sourceSeasonNumber(request.sourceTitle),
      firstSeason: request.tmdbSeasons.isEmpty ? -1 : request.tmdbSeasons.first,
      tmdbSeasons: request.tmdbSeasons,
      seasonCounts: request.seasonCounts,
      sourceEpisodeNumbers: request.line.sourceEpisodeNumbers,
    );
  }

  /// 手动绑定（`02` §8.4）。
  ///
  /// 返回写入后的绑定；参数非法时返回 `null`。
  SeasonBinding? bindSeason({
    int configId = 0,
    required String siteKey,
    required String vodId,
    required String sourceTitle,
    required String flagKey,
    required String sourceFlag,
    required int tmdbId,
    required TmdbMediaType mediaType,
    required SeasonBindingMode mode,
    int? seasonNumber,
    required TmdbSourceLine line,
    required Map<int, int> seasonCounts,
    int tmdbSeasonEpisodeCount = 0,
  }) {
    final error = SeasonBinding.validate(
      siteKey: siteKey,
      vodId: vodId,
      sourceTitle: sourceTitle,
      tmdbId: tmdbId,
      mediaType: mediaType,
      mode: mode,
      seasonNumber: seasonNumber,
    );
    if (error != null) return null;

    final segments = mode == SeasonBindingMode.manualMultiSlice
        ? completeSeasonSegments(
            seasonCounts.keys.toList()..sort(),
            seasonCounts,
          )
        : const <SeasonSegment>[];
    if (mode == SeasonBindingMode.manualMultiSlice && segments.length < 2) {
      return null;
    }

    final binding = SeasonBinding(
      siteKey: siteKey,
      vodId: vodId,
      sourceTitle: sourceTitle,
      flagKey: flagKey,
      tmdbId: tmdbId,
      mediaType: mediaType,
      mode: mode,
      seasonNumber: seasonNumber,
      sourceFingerprint: SourceFingerprint.manual(
        sourceTitle: sourceTitle,
        flagKey: flagKey,
        episodeNames: line.episodeNames,
      ),
      sourceEpisodeCount: line.episodeCount,
      tmdbSeasonEpisodeCount: tmdbSeasonEpisodeCount,
      segments: segments,
      updatedAt: _clock().millisecondsSinceEpoch,
    );
    _store.saveBinding(configId: configId, binding: binding);

    // 同步维护线路绑定索引（换源候选，`02` §5.5）
    _recordRouteBinding(
      configId: configId,
      siteKey: siteKey,
      vodId: vodId,
      flagKey: flagKey,
      sourceFlag: sourceFlag,
      line: line,
      tmdbId: tmdbId,
      mediaType: mediaType,
      scope: binding.toScope(),
    );
    return binding;
  }

  /// 清除绑定（`02` §8.4「自动（清除手动绑定）」）。
  void clearBinding({
    int configId = 0,
    required String siteKey,
    required String vodId,
    String? sourceTitle,
    String? flagKey,
  }) {
    _store.removeBinding(
      configId: configId,
      siteKey: siteKey,
      vodId: vodId,
      sourceTitle: sourceTitle,
      flagKey: flagKey,
    );
    if (flagKey != null) {
      _store.removeRouteBinding(
        configId: configId,
        siteKey: siteKey,
        vodId: vodId,
        flagKey: flagKey,
      );
    }
  }

  /// 媒体重新匹配后清除旧绑定（`02` §5.4）。
  ///
  /// 返回是否真的清除了内容。
  bool removeIfMediaChanged({
    int configId = 0,
    required String siteKey,
    required String vodId,
    required String sourceTitle,
    required String flagKey,
    required int tmdbId,
    required TmdbMediaType mediaType,
  }) {
    final existing = _store.findBinding(
      configId: configId,
      siteKey: siteKey,
      vodId: vodId,
      sourceTitle: sourceTitle,
      flagKey: flagKey,
    );
    if (existing == null) return false;
    // 身份未变 → 保留
    if (existing.tmdbId == tmdbId && existing.mediaType == mediaType) {
      return false;
    }
    clearBinding(
      configId: configId,
      siteKey: siteKey,
      vodId: vodId,
      sourceTitle: sourceTitle,
      flagKey: flagKey,
    );
    return true;
  }

  /// 来源结构变化后修剪线路绑定（`02` §5.4）。
  ///
  /// `currentFingerprints` = `flagKey -> 当前结构指纹`。
  int pruneRouteBindings({
    int configId = 0,
    required String siteKey,
    required String vodId,
    required Map<String, String> currentFingerprints,
  }) {
    final existing = _store.routeBindings(
      configId: configId,
      tmdbId: 0,
      mediaType: '',
    );
    // 内存/数据库实现可能不支持按 0 查询；这里以「全部」语义兜底遍历。
    var removed = 0;
    final candidates = existing.isEmpty
        ? _allRouteBindingsForScope(configId, siteKey, vodId)
        : existing
              .where((b) => b.siteKey == siteKey && b.vodId == vodId)
              .toList();
    for (final binding in candidates) {
      final current = currentFingerprints[binding.flagKey];
      if (current == null || current != binding.sourceFingerprint) {
        _store.removeRouteBinding(
          configId: configId,
          siteKey: binding.siteKey,
          vodId: binding.vodId,
          flagKey: binding.flagKey,
        );
        removed++;
      }
    }
    return removed;
  }

  /// 写入季度进度（`02` §6.2）。
  ///
  /// `UnknownSeason` **不写**；电影不写。
  bool recordProgress({
    int configId = 0,
    required TmdbIdentity identity,
    required SeasonScope scope,
    required int episodeNumber,
    required int positionMs,
    required int durationMs,
    required String sourceFlag,
    required String sourceEpisodeName,
    required String sourceEpisodeUrl,
    required String sourceHistoryKey,
    required String sourceBindingKey,
    int? segmentSeason,
  }) {
    // 电影不写季度进度
    if (!identity.isTv) return false;

    // 定位要写入的季度（`02` §6.2）
    final target = switch (scope) {
      KnownSeason(:final seasonNumber) => seasonNumber,
      MultiSeason() => segmentSeason,
      UnknownSeason() => null,
    };
    if (target == null || target < 0) return false;

    _store.saveProgress(
      configId: configId,
      record: TmdbSeasonProgressRecord(
        configId: configId,
        mediaType: identity.mediaType.name,
        tmdbId: identity.tmdbId,
        seasonNumber: target,
        episodeNumber: episodeNumber,
        positionMs: positionMs,
        durationMs: durationMs,
        sourceFlag: sourceFlag,
        sourceEpisodeName: sourceEpisodeName,
        sourceEpisodeUrl: sourceEpisodeUrl,
        sourceHistoryKey: sourceHistoryKey,
        sourceBindingKey: sourceBindingKey,
        updatedAt: _clock().millisecondsSinceEpoch,
      ),
    );
    return true;
  }

  /// 读取季度进度（续播，`02` §6.3）。
  TmdbSeasonProgressRecord? progressFor({
    int configId = 0,
    required TmdbIdentity identity,
    required int seasonNumber,
  }) {
    if (!identity.isTv || seasonNumber < 0) return null;
    return _store.findProgress(
      configId: configId,
      mediaType: identity.mediaType.name,
      tmdbId: identity.tmdbId,
      seasonNumber: seasonNumber,
    );
  }

  /// 全部季度进度（历史投影，`02` §7.1）。
  List<TmdbSeasonProgressRecord> progressList({
    int configId = 0,
    required TmdbIdentity identity,
  }) => _store.progressForMedia(
    configId: configId,
    mediaType: identity.mediaType.name,
    tmdbId: identity.tmdbId,
  );

  /// 同季度换源候选（`02` §7.3）。
  List<RouteBinding> candidatesForSeason({
    int configId = 0,
    required TmdbIdentity identity,
    required int seasonNumber,
  }) {
    if (!identity.isTv) return const [];
    return _store
        .routeBindings(
          configId: configId,
          tmdbId: identity.tmdbId,
          mediaType: identity.mediaType.name,
        )
        .where((binding) => binding.covers(seasonNumber))
        .toList();
  }

  /// 自动换源的季度兼容判定（`02` §7.3）。
  bool acceptsSource({
    required SeasonScope target,
    required SeasonScope source,
  }) {
    return switch (target) {
      KnownSeason(:final seasonNumber) => source.seasons.contains(seasonNumber),
      MultiSeason(:final segments) => segments.any(
        (segment) => source.seasons.contains(segment.seasonNumber),
      ),
      UnknownSeason() => false,
    };
  }

  /// 删除某一季度历史（`02` §7.4）：只删该季进度。
  int deleteSeasonHistory({
    int configId = 0,
    required TmdbIdentity identity,
    required int seasonNumber,
  }) {
    if (!identity.isTv) return 0;
    return _store.removeProgress(
      configId: configId,
      mediaType: identity.mediaType.name,
      tmdbId: identity.tmdbId,
      seasonNumber: seasonNumber,
    );
  }

  /// 删除整部节目历史（`02` §7.4 的**二级操作**）。
  int deleteMediaHistory({
    int configId = 0,
    required TmdbIdentity identity,
  }) {
    if (!identity.isTv) return 0;
    return _store.removeProgressForMedia(
      configId: configId,
      mediaType: identity.mediaType.name,
      tmdbId: identity.tmdbId,
    );
  }

  // -------------------------------------------------------------------------
  // 内部
  // -------------------------------------------------------------------------

  bool _persistAutoBinding({
    required int configId,
    required TmdbSeasonResolveRequest request,
    required Resolution resolution,
  }) {
    final scope = resolution.scope;
    final mode = switch (scope) {
      KnownSeason() => SeasonBindingMode.manualSeason,
      MultiSeason() => SeasonBindingMode.manualMultiSlice,
      UnknownSeason() => null,
    };
    if (mode == null) return false;
    final seasonNumber = switch (scope) {
      KnownSeason(:final seasonNumber) => seasonNumber,
      _ => null,
    };
    final segments = switch (scope) {
      MultiSeason(:final segments) => segments,
      _ => const <SeasonSegment>[],
    };

    _store.saveBinding(
      configId: configId,
      binding: SeasonBinding(
        siteKey: request.siteKey,
        vodId: request.vodId,
        sourceTitle: request.sourceTitle,
        flagKey: request.line.flagKey,
        tmdbId: request.tmdbId,
        mediaType: TmdbMediaType.tv,
        mode: mode,
        seasonNumber: seasonNumber,
        sourceFingerprint: request.line.structureFingerprint(
          request.seasonCounts,
        ),
        sourceEpisodeCount: request.line.episodeCount,
        tmdbSeasonEpisodeCount: seasonNumber == null
            ? 0
            : (request.seasonCounts[seasonNumber] ?? 0),
        segments: segments,
        updatedAt: _clock().millisecondsSinceEpoch,
      ),
    );
    _recordRouteBinding(
      configId: configId,
      siteKey: request.siteKey,
      vodId: request.vodId,
      flagKey: request.line.flagKey,
      sourceFlag: request.line.sourceFlag,
      line: request.line,
      tmdbId: request.tmdbId,
      mediaType: TmdbMediaType.tv,
      scope: scope,
    );
    return true;
  }

  void _recordRouteBinding({
    required int configId,
    required String siteKey,
    required String vodId,
    required String flagKey,
    required String sourceFlag,
    required TmdbSourceLine line,
    required int tmdbId,
    required TmdbMediaType mediaType,
    required SeasonScope scope,
  }) {
    if (!scope.isKnown || tmdbId <= 0 || mediaType != TmdbMediaType.tv) {
      _store.removeRouteBinding(
        configId: configId,
        siteKey: siteKey,
        vodId: vodId,
        flagKey: flagKey,
      );
      return;
    }
    _store.saveRouteBinding(
      configId: configId,
      binding: RouteBinding(
        siteKey: siteKey,
        vodId: vodId,
        flagKey: flagKey,
        sourceFlag: sourceFlag,
        sourceFingerprint: line.stableFingerprint(),
        tmdbId: tmdbId,
        mediaType: mediaType,
        scope: scope,
        updatedAt: _clock().millisecondsSinceEpoch,
      ),
    );
    _trimRouteBindings(configId: configId);
  }

  void _trimRouteBindings({required int configId}) {
    final all = _allRouteBindingsForScope(configId, null, null);
    if (all.length <= _maxRouteBindings) return;
    final sorted = all.toList()
      ..sort((a, b) => a.updatedAt.compareTo(b.updatedAt));
    final excess = all.length - _maxRouteBindings;
    for (var i = 0; i < excess; i++) {
      _store.removeRouteBinding(
        configId: configId,
        siteKey: sorted[i].siteKey,
        vodId: sorted[i].vodId,
        flagKey: sorted[i].flagKey,
      );
    }
  }

  /// 列举某作用域下的线路绑定。
  ///
  /// 内存实现可直接遍历；数据库实现通过 `routeBindings` 全量查询兜底。
  List<RouteBinding> _allRouteBindingsForScope(
    int configId,
    String? siteKey,
    String? vodId,
  ) {
    final store = _store;
    if (store is InMemoryTmdbSeasonStore) {
      return store.routes.values
          .where(
            (binding) =>
                (siteKey == null || binding.siteKey == siteKey) &&
                (vodId == null || binding.vodId == vodId),
          )
          .toList();
    }
    // 数据库实现：用 tmdbId=0 触发全量查询语义（实现方负责忽略过滤）
    return store.routeBindings(configId: configId, tmdbId: 0, mediaType: '');
  }
}
