/// TMDB 季度模型、解析器与可播放季度（`docs/phase4/design/02` §2–§5）。
///
/// 这一层是**纯逻辑**：不依赖 Flutter，也不依赖 `dart:io`。
///
/// 上游对应实现：`TmdbSeasonScope`、`TmdbSeasonSegment`、`TmdbSeasonResolver`（422 行）、
/// `EpisodeSeasonPolicy`、`EpisodeSeasonSnapshot`。
///
/// 关键契约（`00` §3.2）：
/// - 季度用**显式三态**表达，禁止用整数默认值兼表「特别篇」和「未解析」。
/// - `KnownSeason(0)` 只表示已明确映射到 TMDB 特别篇。
/// - `UnknownSeason` 不得在渲染层被降级成「第 1 季」。
/// - 只有结果**唯一**时才允许自动落盘（`02` §3.4）。
library;

import 'dart:convert';

import 'tmdb_identity.dart';

// ---------------------------------------------------------------------------
// §2.4 SeasonSegment
// ---------------------------------------------------------------------------

/// 一条扁平线路中属于某一 TMDB 季度的**已验证**切片（`02` §2.4）。
class SeasonSegment {
  const SeasonSegment({
    required this.seasonNumber,
    required this.sourceEpisodeStartIndex,
    required this.sourceEpisodeEndIndex,
    required this.tmdbEpisodeStartNumber,
  });

  final int seasonNumber;

  /// 来源剧集起始下标（含）。
  final int sourceEpisodeStartIndex;

  /// 来源剧集结束下标（含）。
  final int sourceEpisodeEndIndex;

  /// 该段首集对应的 TMDB 集号。
  final int tmdbEpisodeStartNumber;

  /// 段长（集数）。
  int get length => sourceEpisodeEndIndex - sourceEpisodeStartIndex + 1;

  Map<String, Object?> toJson() => {
    'seasonNumber': seasonNumber,
    'sourceEpisodeStartIndex': sourceEpisodeStartIndex,
    'sourceEpisodeEndIndex': sourceEpisodeEndIndex,
    'tmdbEpisodeStartNumber': tmdbEpisodeStartNumber,
  };

  static SeasonSegment? fromJson(Object? value) {
    if (value is! Map) return null;
    final map = value.cast<Object?, Object?>();
    final season = _asInt(map['seasonNumber']);
    final start = _asInt(map['sourceEpisodeStartIndex']);
    final end = _asInt(map['sourceEpisodeEndIndex']);
    final tmdbStart = _asInt(map['tmdbEpisodeStartNumber']);
    if (season == null || start == null || end == null || tmdbStart == null) {
      return null;
    }
    return SeasonSegment(
      seasonNumber: season,
      sourceEpisodeStartIndex: start,
      sourceEpisodeEndIndex: end,
      tmdbEpisodeStartNumber: tmdbStart,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SeasonSegment &&
      other.seasonNumber == seasonNumber &&
      other.sourceEpisodeStartIndex == sourceEpisodeStartIndex &&
      other.sourceEpisodeEndIndex == sourceEpisodeEndIndex &&
      other.tmdbEpisodeStartNumber == tmdbEpisodeStartNumber;

  @override
  int get hashCode => Object.hash(
    seasonNumber,
    sourceEpisodeStartIndex,
    sourceEpisodeEndIndex,
    tmdbEpisodeStartNumber,
  );

  @override
  String toString() =>
      'SeasonSegment(S$seasonNumber, src[$sourceEpisodeStartIndex..$sourceEpisodeEndIndex], '
      'tmdbStart=$tmdbEpisodeStartNumber)';
}

// ---------------------------------------------------------------------------
// §2.3 SeasonScope 显式三态
// ---------------------------------------------------------------------------

/// 季度范围（`02` §2.3）。**禁止**用整数默认值兼表两种含义。
sealed class SeasonScope {
  const SeasonScope();

  /// 是否已确证（`KnownSeason` 或有效的 `MultiSeason`）。
  bool get isKnown => switch (this) {
    KnownSeason() => true,
    MultiSeason(:final segments) => segments.length >= 2,
    UnknownSeason() => false,
  };

  /// 已知季度号集合；`UnknownSeason` 返回空。
  List<int> get seasons => switch (this) {
    KnownSeason(:final seasonNumber) => [seasonNumber],
    MultiSeason(:final segments) => segments.map((s) => s.seasonNumber).toList(),
    UnknownSeason() => const [],
  };

  Map<String, Object?> toJson() => switch (this) {
    KnownSeason(:final seasonNumber) => {
      'kind': 'known',
      'seasonNumber': seasonNumber,
    },
    MultiSeason(:final segments) => {
      'kind': 'multi',
      'segments': segments.map((s) => s.toJson()).toList(),
    },
    UnknownSeason() => {'kind': 'unknown'},
  };

  static SeasonScope fromJson(Object? value) {
    if (value is! Map) return const UnknownSeason();
    final map = value.cast<Object?, Object?>();
    switch (map['kind']) {
      case 'known':
        final season = _asInt(map['seasonNumber']);
        return season == null ? const UnknownSeason() : KnownSeason(season);
      case 'multi':
        final raw = map['segments'];
        if (raw is! List) return const UnknownSeason();
        final segments = raw
            .map(SeasonSegment.fromJson)
            .whereType<SeasonSegment>()
            .toList();
        return segments.length >= 2 ? MultiSeason(segments) : const UnknownSeason();
      default:
        return const UnknownSeason();
    }
  }
}

/// 已确证的单季。
///
/// `seasonNumber == 0` **只**表示已明确映射到 TMDB 特别篇（`02` §2.3）。
class KnownSeason extends SeasonScope {
  const KnownSeason(this.seasonNumber);

  final int seasonNumber;

  bool get isSpecials => seasonNumber == 0;

  @override
  bool operator ==(Object other) =>
      other is KnownSeason && other.seasonNumber == seasonNumber;

  @override
  int get hashCode => seasonNumber.hashCode;

  @override
  String toString() => 'KnownSeason($seasonNumber)';
}

/// 一条线路覆盖多季，且每段边界可验证。
class MultiSeason extends SeasonScope {
  const MultiSeason(this.segments);

  final List<SeasonSegment> segments;

  /// 返回覆盖 [seasonNumber] 的分段；无则 `null`。
  SeasonSegment? segmentFor(int seasonNumber) {
    for (final segment in segments) {
      if (segment.seasonNumber == seasonNumber) return segment;
    }
    return null;
  }

  /// 该季是否被本线路覆盖。
  bool covers(int seasonNumber) => segmentFor(seasonNumber) != null;

  @override
  bool operator ==(Object other) =>
      other is MultiSeason &&
      other.segments.length == segments.length &&
      Iterable<int>.generate(segments.length)
          .every((i) => other.segments[i] == segments[i]);

  @override
  int get hashCode => Object.hashAll(segments);

  @override
  String toString() => 'MultiSeason(${segments.map((s) => s.seasonNumber).toList()})';
}

/// 季度绑定弹窗的语义化结果（`04` §5.2）。
///
/// 定义在纯逻辑层，避免状态层反向依赖 UI。
sealed class TmdbSeasonChoice {
  const TmdbSeasonChoice();
}

/// 自动（清除手动绑定）。
class TmdbSeasonAuto extends TmdbSeasonChoice {
  const TmdbSeasonAuto();
}

/// 按集号自动切片。
class TmdbSeasonAutoSlice extends TmdbSeasonChoice {
  const TmdbSeasonAutoSlice();
}

/// 保持原始集列表。
class TmdbSeasonKeepOriginal extends TmdbSeasonChoice {
  const TmdbSeasonKeepOriginal();
}

/// 选定某一季。
class TmdbSeasonNumber extends TmdbSeasonChoice {
  const TmdbSeasonNumber(this.seasonNumber);

  final int seasonNumber;
}

/// `02` §8.4：语义化选择 → 绑定模式与季号。
///
/// 返回 `(mode, seasonNumber)`；`TmdbSeasonAuto` 返回 `null`（表示清除绑定）。
({SeasonBindingMode mode, int? seasonNumber})? bindingModeOf(
  TmdbSeasonChoice choice,
) => switch (choice) {
  TmdbSeasonAuto() => null,
  TmdbSeasonAutoSlice() => (
    mode: SeasonBindingMode.manualMultiSlice,
    seasonNumber: null,
  ),
  TmdbSeasonKeepOriginal() => (
    mode: SeasonBindingMode.manualFlat,
    seasonNumber: null,
  ),
  TmdbSeasonNumber(:final seasonNumber) => (
    mode: SeasonBindingMode.manualSeason,
    seasonNumber: seasonNumber,
  ),
};

/// 证据不足，**不猜测**（`02` §2.3）。
class UnknownSeason extends SeasonScope {
  const UnknownSeason();

  @override
  bool operator ==(Object other) => other is UnknownSeason;

  @override
  int get hashCode => 0;

  @override
  String toString() => 'UnknownSeason()';
}

// ---------------------------------------------------------------------------
// §3.2 Resolution
// ---------------------------------------------------------------------------

/// 解析状态（`02` §3.2）。
enum ResolutionStatus { resolved, multiSlice, flat, ambiguous }

/// 解析依据来源（`02` §3.2）。
enum ResolutionSource {
  request,
  manual,
  manualFlat,
  manualMultiSlice,
  explicit,
  explicitMulti,
  explicitConflict,
  title,
  singleSeason,
  episodeCount,
  flatEpisodeKeys,
  allSeasonCounts,
  none,
}

/// 季度解析结果（`02` §3.2）。
class Resolution {
  const Resolution({
    required this.status,
    required this.scope,
    required this.source,
    required this.reason,
  });

  /// 已确证的单季。
  static Resolution resolved(
    int seasonNumber,
    ResolutionSource source,
    String reason,
  ) => Resolution(
    status: ResolutionStatus.resolved,
    scope: KnownSeason(seasonNumber),
    source: source,
    reason: reason,
  );

  /// 多季切片。`segments` 为空时 `scope` 退化为 [UnknownSeason]。
  static Resolution multiSlice(
    List<int> seasons,
    ResolutionSource source,
    String reason, [
    List<SeasonSegment>? segments,
  ]) => Resolution(
    status: ResolutionStatus.multiSlice,
    scope: segments == null ? const UnknownSeason() : MultiSeason(segments),
    source: source,
    reason: reason,
  );

  /// 保持原始集列表（仅由手动 `manualFlat` 产生）。
  static Resolution flat(ResolutionSource source, String reason) => Resolution(
    status: ResolutionStatus.flat,
    scope: const UnknownSeason(),
    source: source,
    reason: reason,
  );

  /// 证据不足，**不落盘**。
  static Resolution ambiguous(ResolutionSource source, String reason) =>
      Resolution(
        status: ResolutionStatus.ambiguous,
        scope: const UnknownSeason(),
        source: source,
        reason: reason,
      );

  final ResolutionStatus status;
  final SeasonScope scope;
  final ResolutionSource source;

  /// 稳定的机器可读原因串。
  final String reason;

  /// 是否唯一确定（允许自动落盘，`02` §3.4）。
  bool get canPersist =>
      status == ResolutionStatus.resolved ||
      (status == ResolutionStatus.multiSlice && scope.isKnown) ||
      status == ResolutionStatus.flat;

  bool get isAmbiguous => status == ResolutionStatus.ambiguous;

  @override
  String toString() =>
      'Resolution(${status.name}, ${scope.runtimeType}, ${source.name}, $reason)';
}

// ---------------------------------------------------------------------------
// §5.1 绑定记录
// ---------------------------------------------------------------------------

/// 手动绑定的模式（`02` §5.1）。
enum SeasonBindingMode {
  manualSeason,
  manualFlat,
  manualMultiSlice;

  static SeasonBindingMode? parse(Object? value) {
    switch (value) {
      case 'manualSeason':
        return SeasonBindingMode.manualSeason;
      case 'manualFlat':
        return SeasonBindingMode.manualFlat;
      case 'manualMultiSlice':
        return SeasonBindingMode.manualMultiSlice;
      default:
        return null;
    }
  }
}

/// 结构版本（`02` §5.4）。版本不匹配的记录视为无效。
const int seasonBindingVersion = 1;

/// 线路级季度绑定记录（`02` §5.1）。
class SeasonBinding {
  const SeasonBinding({
    required this.siteKey,
    required this.vodId,
    required this.sourceTitle,
    required this.flagKey,
    required this.tmdbId,
    required this.mediaType,
    required this.mode,
    this.seasonNumber,
    this.sourceFingerprint = '',
    this.sourceEpisodeCount = 0,
    this.tmdbSeasonEpisodeCount = 0,
    this.segments = const [],
    this.updatedAt = 0,
    this.version = seasonBindingVersion,
  });

  final String siteKey;
  final String vodId;
  final String sourceTitle;
  final String flagKey;
  final int tmdbId;
  final TmdbMediaType mediaType;
  final SeasonBindingMode mode;
  final int? seasonNumber;
  final String sourceFingerprint;
  final int sourceEpisodeCount;
  final int tmdbSeasonEpisodeCount;
  final List<SeasonSegment> segments;
  final int updatedAt;
  final int version;

  /// 读取校验（`02` §5.1）。
  bool matches(int expectedTmdbId) {
    if (version != seasonBindingVersion) return false;
    if (tmdbId != expectedTmdbId) return false;
    if (mediaType != TmdbMediaType.tv) return false;
    if (mode == SeasonBindingMode.manualSeason) {
      final season = seasonNumber;
      if (season == null || season < 0) return false;
    } else {
      if (seasonNumber != null) return false;
    }
    return true;
  }

  /// 写入前置校验（`02` §5.1）。返回 `null` 表示可写入。
  static String? validate({
    required String siteKey,
    required String vodId,
    required String sourceTitle,
    required int tmdbId,
    required TmdbMediaType mediaType,
    required SeasonBindingMode mode,
    int? seasonNumber,
  }) {
    if (siteKey.isEmpty || vodId.isEmpty || sourceTitle.isEmpty) {
      return 'scope_incomplete';
    }
    if (tmdbId <= 0) return 'tmdb_id_invalid';
    if (mediaType != TmdbMediaType.tv) return 'media_type_not_tv';
    if (mode == SeasonBindingMode.manualSeason) {
      if (seasonNumber == null || seasonNumber < 0) return 'season_number_required';
    } else {
      if (seasonNumber != null) return 'season_number_forbidden';
    }
    return null;
  }

  SeasonScope toScope() => switch (mode) {
    SeasonBindingMode.manualSeason => KnownSeason(seasonNumber!),
    SeasonBindingMode.manualMultiSlice =>
      segments.length >= 2 ? MultiSeason(segments) : const UnknownSeason(),
    SeasonBindingMode.manualFlat => const UnknownSeason(),
  };

  Map<String, Object?> toJson() => {
    'siteKey': siteKey,
    'vodId': vodId,
    'sourceTitle': sourceTitle,
    'flagKey': flagKey,
    'tmdbId': tmdbId,
    'mediaType': mediaType.name,
    'mode': mode.name,
    if (seasonNumber != null) 'seasonNumber': seasonNumber,
    'sourceFingerprint': sourceFingerprint,
    'sourceEpisodeCount': sourceEpisodeCount,
    'tmdbSeasonEpisodeCount': tmdbSeasonEpisodeCount,
    'segments': segments.map((s) => s.toJson()).toList(),
    'updatedAt': updatedAt,
    'version': version,
  };

  static SeasonBinding? fromJson(Object? value) {
    if (value is! Map) return null;
    final map = value.cast<Object?, Object?>();
    final mode = SeasonBindingMode.parse(map['mode']);
    final mediaType = TmdbMediaType.parse(map['mediaType']);
    if (mode == null || mediaType == null) return null;
    final rawSegments = map['segments'];
    return SeasonBinding(
      siteKey: _asString(map['siteKey']),
      vodId: _asString(map['vodId']),
      sourceTitle: _asString(map['sourceTitle']),
      flagKey: _asString(map['flagKey']),
      tmdbId: _asInt(map['tmdbId']) ?? 0,
      mediaType: mediaType,
      mode: mode,
      seasonNumber: _asInt(map['seasonNumber']),
      sourceFingerprint: _asString(map['sourceFingerprint']),
      sourceEpisodeCount: _asInt(map['sourceEpisodeCount']) ?? 0,
      tmdbSeasonEpisodeCount: _asInt(map['tmdbSeasonEpisodeCount']) ?? 0,
      segments: rawSegments is List
          ? rawSegments.map(SeasonSegment.fromJson).whereType<SeasonSegment>().toList()
          : const [],
      updatedAt: _asInt(map['updatedAt']) ?? 0,
      version: _asInt(map['version']) ?? seasonBindingVersion,
    );
  }
}

/// 线路绑定索引记录（`02` §5.5，换源候选用）。
class RouteBinding {
  const RouteBinding({
    required this.siteKey,
    required this.vodId,
    required this.flagKey,
    required this.sourceFlag,
    required this.sourceFingerprint,
    required this.tmdbId,
    required this.mediaType,
    required this.scope,
    required this.updatedAt,
  });

  final String siteKey;
  final String vodId;
  final String flagKey;
  final String sourceFlag;
  final String sourceFingerprint;
  final int tmdbId;
  final TmdbMediaType mediaType;
  final SeasonScope scope;
  final int updatedAt;

  /// 该绑定是否覆盖给定季度。
  bool covers(int seasonNumber) => scope.seasons.contains(seasonNumber);

  /// `02` §5.5 的 `routeIdentity`。
  static String routeIdentity(String siteKey, String vodId) =>
      '$siteKey@@@$vodId';

  @override
  bool operator ==(Object other) =>
      other is RouteBinding &&
      other.siteKey == siteKey &&
      other.vodId == vodId &&
      other.flagKey == flagKey &&
      other.sourceFlag == sourceFlag &&
      other.sourceFingerprint == sourceFingerprint &&
      other.tmdbId == tmdbId &&
      other.mediaType == mediaType &&
      other.scope == scope;

  @override
  int get hashCode => Object.hash(
    siteKey,
    vodId,
    flagKey,
    sourceFlag,
    sourceFingerprint,
    tmdbId,
    mediaType,
    scope,
  );
}

/// 线路绑定索引容量上限（`02` §5.5）。
const int maxRouteBindings = 512;

// ---------------------------------------------------------------------------
// §3.3 季度解析器
// ---------------------------------------------------------------------------

/// 季度解析器输入（`02` §3.1）。
class SeasonResolveInput {
  const SeasonResolveInput({
    this.requestSeason = -1,
    this.manualBinding,
    this.explicitSourceSeasons = const [],
    this.titleSeason = -1,
    this.tmdbSeasons = const [],
    this.seasonCounts = const {},
    this.sourceEpisodeCount = 0,
    this.sourceEpisodeNumbers,
    this.explicitEpisodeSeasons,
    this.allowHeuristicGuessing = true,
  });

  /// 请求上下文指定的季度，无则 `-1`。
  final int requestSeason;
  final SeasonBinding? manualBinding;

  /// 从线路/剧集名解析出的季度号集合（可含 `-1`）。
  final List<int> explicitSourceSeasons;

  /// 从标题解析出的季度，无则 `-1`。
  final int titleSeason;
  final List<int> tmdbSeasons;

  /// 季度号 → 集数。
  final Map<int, int> seasonCounts;
  final int sourceEpisodeCount;
  final List<int>? sourceEpisodeNumbers;
  final List<int>? explicitEpisodeSeasons;
  final bool allowHeuristicGuessing;
}

/// 季度解析器（`02` §3.3）。
///
/// 判定顺序**严格按序，后级不得覆盖前级**。
abstract final class TmdbSeasonResolver {
  /// 主入口。返回三元组 `(status, source, reason)` 与 `scope`。
  static Resolution resolve(SeasonResolveInput input) {
    final seasons = _distinctNonNegative(input.tmdbSeasons);
    final sliceable = sliceableSeasons(seasons);

    // 1. requestSeason
    if (input.requestSeason >= 0) {
      if (seasons.contains(input.requestSeason)) {
        return Resolution.resolved(
          input.requestSeason,
          ResolutionSource.request,
          'request_season',
        );
      }
      return Resolution.ambiguous(
        ResolutionSource.request,
        'requested_season_missing_from_tmdb',
      );
    }

    // 2. manualFlat
    final manual = input.manualBinding;
    if (manual != null && manual.mode == SeasonBindingMode.manualFlat) {
      return Resolution.flat(ResolutionSource.manualFlat, 'manual_flat');
    }

    // 3. tmdbSeasons 为空
    if (seasons.isEmpty) {
      return Resolution.ambiguous(
        ResolutionSource.none,
        'tmdb_seasons_empty',
      );
    }

    // 4. manualMultiSlice
    if (manual != null && manual.mode == SeasonBindingMode.manualMultiSlice) {
      final persisted = _persistedSegmentSeasons(
        manual,
        seasons,
        input.seasonCounts,
        input.sourceEpisodeCount,
      );
      if (persisted.length > 1) {
        return Resolution.multiSlice(
          persisted,
          ResolutionSource.manualMultiSlice,
          'manual_multi_slice_segments',
          manual.segments,
        );
      }
      final covered = input.sourceEpisodeNumbers == null
          ? coveredSeasonsByEpisodeCount(
              input.sourceEpisodeCount,
              sliceable,
              input.seasonCounts,
            )
          : mappedSeasonsByEpisodeNumbers(
              input.sourceEpisodeNumbers,
              sliceable,
              input.seasonCounts,
            );
      if (covered.isNotEmpty) {
        // 重算出的覆盖季度也要能落盘，因此一并生成完整分段（§3.4）。
        return Resolution.multiSlice(
          covered,
          ResolutionSource.manualMultiSlice,
          'manual_multi_slice',
          completeSeasonSegments(covered, input.seasonCounts),
        );
      }
      return Resolution.ambiguous(
        ResolutionSource.manualMultiSlice,
        'manual_multi_slice_stale',
      );
    }

    // 5. manualSeason
    if (manual != null &&
        manual.mode == SeasonBindingMode.manualSeason &&
        seasons.contains(manual.seasonNumber)) {
      return Resolution.resolved(
        manual.seasonNumber!,
        ResolutionSource.manual,
        'manual_season',
      );
    }

    // 6/7. explicitSourceSeasons
    final explicit = _distinctNonNegative(input.explicitSourceSeasons);
    if (explicit.length > 1) {
      if (input.titleSeason >= 0 || !seasons.toSet().containsAll(explicit)) {
        return Resolution.ambiguous(
          ResolutionSource.explicitConflict,
          'multiple_explicit_seasons',
        );
      }
      final ordered = sliceable.where(explicit.contains).toList();
      if (_matchesSeasonNumberRuns(
        input.sourceEpisodeNumbers,
        input.explicitEpisodeSeasons,
        ordered,
        input.seasonCounts,
      )) {
        return Resolution.multiSlice(
          ordered,
          ResolutionSource.explicitMulti,
          'multiple_explicit_seasons',
          completeSeasonSegments(ordered, input.seasonCounts),
        );
      }
      return Resolution.ambiguous(
        ResolutionSource.explicitConflict,
        'multiple_explicit_seasons',
      );
    }
    if (explicit.length == 1) {
      final season = explicit.first;
      if (input.titleSeason >= 0 && input.titleSeason != season) {
        return Resolution.ambiguous(
          ResolutionSource.explicitConflict,
          'title_and_source_season_conflict',
        );
      }
      if (seasons.contains(season)) {
        return Resolution.resolved(
          season,
          ResolutionSource.explicit,
          'explicit_source_season',
        );
      }
      return Resolution.ambiguous(
        ResolutionSource.explicit,
        'explicit_season_missing_from_tmdb',
      );
    }

    // 8. titleSeason
    if (input.titleSeason >= 0) {
      if (seasons.contains(input.titleSeason)) {
        return Resolution.resolved(
          input.titleSeason,
          ResolutionSource.title,
          'title_season',
        );
      }
      return Resolution.ambiguous(
        ResolutionSource.title,
        'title_season_missing_from_tmdb',
      );
    }

    // 9. 单普通季度
    final ordinary = seasons.where((s) => s > 0).toList();
    if (input.allowHeuristicGuessing && ordinary.length == 1) {
      return Resolution.resolved(
        ordinary.first,
        ResolutionSource.singleSeason,
        'single_ordinary_season',
      );
    }

    // 10. 关闭启发式
    if (!input.allowHeuristicGuessing) {
      return Resolution.ambiguous(
        ResolutionSource.none,
        'heuristic_guessing_disabled',
      );
    }

    // 11. 仅特别篇
    if (ordinary.isEmpty && seasons.length == 1 && seasons.first == 0) {
      return Resolution.resolved(
        0,
        ResolutionSource.singleSeason,
        'specials_only',
      );
    }

    // 12. 精确集数匹配
    final exact = _exactCountMatches(
      sliceable.isEmpty ? seasons : sliceable,
      input.seasonCounts,
      input.sourceEpisodeCount,
    );
    if (exact.length == 1) {
      return Resolution.resolved(
        exact.first,
        ResolutionSource.episodeCount,
        'unique_episode_count',
      );
    }
    if (exact.length > 1) {
      return Resolution.ambiguous(
        ResolutionSource.episodeCount,
        'duplicate_episode_counts',
      );
    }

    // 13. 全季切片
    if (canSliceBySeasonCounts(
      input.sourceEpisodeCount,
      sliceable,
      input.seasonCounts,
    )) {
      return Resolution.multiSlice(
        sliceable,
        ResolutionSource.allSeasonCounts,
        'all_season_counts',
        completeSeasonSegments(sliceable, input.seasonCounts),
      );
    }

    // 14. 扁平集号
    final keyed = mappedSeasonsByEpisodeNumbers(
      input.sourceEpisodeNumbers,
      sliceable,
      input.seasonCounts,
    );
    if (keyed.length > 1) {
      return Resolution.multiSlice(
        keyed,
        ResolutionSource.flatEpisodeKeys,
        'flat_episode_keys',
        completeSeasonSegments(keyed, input.seasonCounts),
      );
    }

    // 15. 证据不足
    return Resolution.ambiguous(
      ResolutionSource.none,
      'insufficient_season_evidence',
    );
  }
}

// ---------------------------------------------------------------------------
// §5.3 分段有效性
// ---------------------------------------------------------------------------

/// 分段有效性校验（`02` §5.3 的 8 条）。
///
/// 全部条件必须同时满足；任一条不满足 → 分段作废。
bool hasValidPersistedSegments({
  required List<SeasonSegment> segments,
  required List<int> tmdbSeasons,
  required Map<int, int> seasonCounts,
  required int sourceEpisodeCount,
}) {
  // 1. 至少 2 段
  if (segments.length < 2) return false;
  // 2. sourceEpisodeCount > 0
  if (sourceEpisodeCount <= 0) return false;

  var expectedStart = 0;
  for (final segment in segments) {
    // 3. seasonNumber 含于 tmdbSeasons
    if (!tmdbSeasons.contains(segment.seasonNumber)) return false;
    // 4. 连续无空洞
    if (segment.sourceEpisodeStartIndex != expectedStart) return false;
    // 5. endIndex >= startIndex 且 endIndex < sourceEpisodeCount
    if (segment.sourceEpisodeEndIndex < segment.sourceEpisodeStartIndex) {
      return false;
    }
    if (segment.sourceEpisodeEndIndex >= sourceEpisodeCount) return false;
    // 6. tmdbEpisodeStartNumber > 0
    if (segment.tmdbEpisodeStartNumber <= 0) return false;
    // 7. 段长不越界
    final length = segment.length;
    final tmdbCount = seasonCounts[segment.seasonNumber] ?? 0;
    if (tmdbCount <= 0) return false;
    if (segment.tmdbEpisodeStartNumber + length - 1 > tmdbCount) return false;

    expectedStart = segment.sourceEpisodeEndIndex + 1;
  }
  // 8. 完整覆盖
  return expectedStart == sourceEpisodeCount;
}

/// `02` §3.3 第 4 步的「已存分段有效且 > 1 季」。
List<int> _persistedSegmentSeasons(
  SeasonBinding binding,
  List<int> tmdbSeasons,
  Map<int, int> seasonCounts,
  int sourceEpisodeCount,
) {
  if (!hasValidPersistedSegments(
    segments: binding.segments,
    tmdbSeasons: tmdbSeasons,
    seasonCounts: seasonCounts,
    sourceEpisodeCount: sourceEpisodeCount,
  )) {
    return const [];
  }
  final result = <int>[];
  for (final segment in binding.segments) {
    if (!result.contains(segment.seasonNumber)) {
      result.add(segment.seasonNumber);
    }
  }
  return result;
}

// ---------------------------------------------------------------------------
// §4 可播放季度
// ---------------------------------------------------------------------------

/// 可播放季度解析（`02` §4.3 的 6 级顺序 A–G）。
///
/// 返回空列表表示「退化为扁平列表，隐藏季度导航」。
List<int> resolveAvailableSeasons({
  required List<int> sourceSeasonNumbers,
  int titleSeason = -1,
  int firstSeason = -1,
  required List<int> tmdbSeasons,
  required Map<int, int> seasonCounts,
  List<int>? sourceEpisodeNumbers,
}) {
  if (sourceSeasonNumbers.isEmpty || tmdbSeasons.isEmpty) return const [];

  // A. 存在任意显式季度号
  final hasExplicit = sourceSeasonNumbers.any((s) => s >= 0);
  if (hasExplicit) {
    if (hasCompleteExplicitSeasonMapping(sourceSeasonNumbers, tmdbSeasons)) {
      final available = <int>[];
      for (final season in tmdbSeasons) {
        if (sourceSeasonNumbers.contains(season)) available.add(season);
      }
      return available;
    }
    // A2. 有未分类的额外集：只在「已解析季度唯一且都属于 TMDB」时安全
    var onlyMapped = -1;
    for (final season in sourceSeasonNumbers) {
      if (season < 0) continue;
      if (!tmdbSeasons.contains(season)) return const [];
      if (onlyMapped >= 0 && onlyMapped != season) return const [];
      onlyMapped = season;
    }
    return onlyMapped >= 0 ? [onlyMapped] : const [];
  }

  // B. 标题季度
  if (titleSeason >= 0) {
    return tmdbSeasons.contains(titleSeason) ? [titleSeason] : const [];
  }

  // C. 单一 TMDB 季度
  if (tmdbSeasons.length == 1) return [tmdbSeasons.first];

  final sourceEpisodeCount = sourceSeasonNumbers.length;

  // D. 精确切片
  if (canSliceBySeasonCounts(sourceEpisodeCount, tmdbSeasons, seasonCounts)) {
    return sliceableSeasons(tmdbSeasons);
  }

  // E. 扁平集号多季
  final keyed = mappedSeasonsByEpisodeNumbers(
    sourceEpisodeNumbers,
    tmdbSeasons,
    seasonCounts,
  );
  if (keyed.length > 1) return keyed;

  // F. 单季兼容
  if (tmdbSeasons.contains(firstSeason) &&
      shouldUseSingleSeasonEpisodeData(
        sourceEpisodeCount,
        firstSeason,
        tmdbSeasons,
        seasonCounts,
      )) {
    return [firstSeason];
  }

  // G. 无法可靠映射
  return const [];
}

/// `02` §4.5：可切片季度（非负）。
List<int> sliceableSeasons(List<int> seasons) =>
    seasons.where((season) => season >= 0).toList();

/// `02` §4.5：能否按季集数精确切片。
///
/// 为真当且仅当：`episodeCount > 0`、`seasons` 非空、每季集数 `> 0`、
/// 各季集数之和**恰好等于** `episodeCount`。
bool canSliceBySeasonCounts(
  int episodeCount,
  List<int> seasons,
  Map<int, int> seasonCounts,
) {
  if (episodeCount <= 0 || seasons.isEmpty) return false;
  var sum = 0;
  for (final season in seasons) {
    final count = seasonCounts[season] ?? 0;
    if (count <= 0) return false;
    sum += count;
  }
  return sum == episodeCount;
}

/// `02` §4.5：按顺序把扁平列表切成连续区间；越界返回空。
List<T> sliceBySeasonCounts<T>(
  List<T> episodes,
  List<int> seasons,
  Map<int, int> seasonCounts,
  int selectedSeason,
) {
  if (episodes.isEmpty || seasons.isEmpty) return const [];
  var offset = 0;
  for (final season in seasons) {
    final count = seasonCounts[season] ?? 0;
    if (count <= 0) return const [];
    if (season == selectedSeason) {
      final end = offset + count;
      if (end > episodes.length) return const [];
      return episodes.sublist(offset, end);
    }
    offset += count;
  }
  return const [];
}

/// `02` §4.3 A1：是否每个已解析季度都能在 TMDB 找到，且没有未分类的集。
bool hasCompleteExplicitSeasonMapping(
  List<int> sourceSeasonNumbers,
  List<int> tmdbSeasons,
) {
  if (sourceSeasonNumbers.isEmpty) return false;
  final target = tmdbSeasons.toSet();
  for (final season in sourceSeasonNumbers) {
    if (season < 0) return false; // 存在未分类的集
    if (!target.contains(season)) return false;
  }
  return true;
}

/// `02` §4.6：扁平集号 → `(seasonNumber, episodeNumber)`。
///
/// 从第一季开始累加各季集数，找到 `sourceEpisodeNumber` 落在的季与季内集号。
/// `sourceEpisodeNumber <= 0` 或超出总和 → `null`。
({int seasonNumber, int episodeNumber})? mapFlatEpisodeNumber(
  int sourceEpisodeNumber,
  List<int> seasons,
  Map<int, int> seasonCounts,
) {
  if (sourceEpisodeNumber <= 0) return null;
  var remaining = sourceEpisodeNumber;
  for (final season in seasons) {
    final count = seasonCounts[season] ?? 0;
    if (count <= 0) return null;
    if (remaining <= count) {
      return (seasonNumber: season, episodeNumber: remaining);
    }
    remaining -= count;
  }
  return null;
}

/// `02` §4.6：能否完整映射全部扁平集号。
bool canMapFlatEpisodeNumbers(
  List<int>? sourceEpisodeNumbers,
  List<int> seasons,
  Map<int, int> seasonCounts,
) {
  if (sourceEpisodeNumbers == null || sourceEpisodeNumbers.isEmpty) return false;
  if (seasons.isEmpty) return false;
  for (final number in sourceEpisodeNumbers) {
    if (mapFlatEpisodeNumber(number, seasons, seasonCounts) == null) return false;
  }
  return true;
}

/// `02` §4.6：能否完整映射全部扁平集号（键形态）。
bool canMapFlatEpisodeKeys(
  List<int>? sourceEpisodeNumbers,
  List<int> seasons,
  Map<int, int> seasonCounts,
) =>
    canMapFlatEpisodeNumbers(sourceEpisodeNumbers, seasons, seasonCounts);

/// `02` §4.3 E：扁平集号能映射出的多季集合（保持 seasons 顺序）。
List<int> mappedSeasonsByEpisodeNumbers(
  List<int>? sourceEpisodeNumbers,
  List<int> seasons,
  Map<int, int> seasonCounts,
) {
  if (sourceEpisodeNumbers == null || sourceEpisodeNumbers.isEmpty) {
    return const [];
  }
  final result = <int>[];
  for (final number in sourceEpisodeNumbers) {
    final mapped = mapFlatEpisodeNumber(number, seasons, seasonCounts);
    if (mapped == null) return const [];
    if (!result.contains(mapped.seasonNumber)) result.add(mapped.seasonNumber);
  }
  // 保持 seasons 顺序
  return seasons.where(result.contains).toList();
}

/// `02` §3.3 第 4 步：按集数能覆盖的多季集合。
List<int> coveredSeasonsByEpisodeCount(
  int sourceEpisodeCount,
  List<int> seasons,
  Map<int, int> seasonCounts,
) {
  if (!canSliceBySeasonCounts(sourceEpisodeCount, seasons, seasonCounts)) {
    return const [];
  }
  return sliceableSeasons(seasons);
}

/// `02` §4.3 F：既有单季兼容策略。
///
/// `firstSeasonCount >= sourceEpisodeCount` 且不可切片。
bool shouldUseSingleSeasonEpisodeData(
  int sourceEpisodeCount,
  int firstSeason,
  List<int> seasons,
  Map<int, int> seasonCounts,
) {
  if (sourceEpisodeCount <= 0 || firstSeason < 0) return false;
  if (seasons.length <= 1) return false;
  final firstSeasonCount = seasonCounts[firstSeason] ?? 0;
  if (firstSeasonCount < sourceEpisodeCount) return false;
  return !canSliceBySeasonCounts(sourceEpisodeCount, seasons, seasonCounts);
}

// ---------------------------------------------------------------------------
// §5.3 完整分段构造
// ---------------------------------------------------------------------------

/// 为完整切片生成分段（`02` §3.3 第 6/13 步用）。
///
/// 只有各季集数之和恰好等于来源集数时才生成；否则返回空。
List<SeasonSegment> completeSeasonSegments(
  List<int> seasons,
  Map<int, int> seasonCounts,
) {
  final total = seasons.fold<int>(0, (sum, s) => sum + (seasonCounts[s] ?? 0));
  if (seasons.isEmpty || total <= 0) return const [];
  final segments = <SeasonSegment>[];
  var start = 0;
  for (final season in seasons) {
    final count = seasonCounts[season] ?? 0;
    if (count <= 0) return const [];
    segments.add(
      SeasonSegment(
        seasonNumber: season,
        sourceEpisodeStartIndex: start,
        sourceEpisodeEndIndex: start + count - 1,
        tmdbEpisodeStartNumber: 1,
      ),
    );
    start += count;
  }
  return segments.length >= 2 ? segments : const [];
}

/// `02` §3.3 第 6/13 步：扁平集号是否按季连续完整。
bool _matchesSeasonNumberRuns(
  List<int>? sourceEpisodeNumbers,
  List<int>? explicitEpisodeSeasons,
  List<int> orderedSeasons,
  Map<int, int> seasonCounts,
) {
  final numbers = sourceEpisodeNumbers;
  if (numbers == null || numbers.isEmpty) return false;
  final mapped = mappedSeasonsByEpisodeNumbers(numbers, orderedSeasons, seasonCounts);
  if (mapped.length != orderedSeasons.length) return false;
  // 显式集季若提供，必须与有序季度一致
  final explicit = explicitEpisodeSeasons;
  if (explicit != null && explicit.isNotEmpty) {
    for (final season in explicit) {
      if (season >= 0 && !orderedSeasons.contains(season)) return false;
    }
  }
  return true;
}

// ---------------------------------------------------------------------------
// 指纹（`02` §2.5）
// ---------------------------------------------------------------------------

/// 来源指纹（`02` §2.5）。
///
/// - **稳定指纹**用于手动绑定：只依赖序号与原始剧集名，**不含 URL**，
///   避免线路换 CDN 后绑定失效。
/// - **结构指纹**用于自动绑定校验：含季度集数映射，TMDB 季集数变化时必须重验。
abstract final class SourceFingerprint {
  /// 稳定指纹：`<flagKey>|<序号:原始剧集名>...`。
  static String stable({required String flagKey, required List<String> episodeNames}) {
    final buffer = StringBuffer(flagKey);
    for (var index = 0; index < episodeNames.length; index++) {
      buffer.write('|$index:${episodeNames[index]}');
    }
    return buffer.toString();
  }

  /// 手动绑定指纹（`02` §2.5）：`sourceTitle|flagKey|stableStructure`。
  static String manual({
    required String sourceTitle,
    required String flagKey,
    required List<String> episodeNames,
  }) =>
      '$sourceTitle|$flagKey|${stable(flagKey: '', episodeNames: episodeNames)}';

  /// 结构指纹：在稳定指纹基础上追加季度集数映射。
  static String structure({
    required String flagKey,
    required List<String> episodeNames,
    required Map<int, int> seasonCounts,
  }) {
    final seasons = seasonCounts.keys.toList()..sort();
    final buffer = StringBuffer(stable(flagKey: flagKey, episodeNames: episodeNames));
    for (final season in seasons) {
      buffer.write('|s$season=${seasonCounts[season]}');
    }
    return buffer.toString();
  }
}

// ---------------------------------------------------------------------------
// 内部工具
// ---------------------------------------------------------------------------

List<int> _distinctNonNegative(List<int> values) {
  final result = <int>[];
  for (final value in values) {
    if (value < 0) continue;
    if (!result.contains(value)) result.add(value);
  }
  return result;
}

List<int> _exactCountMatches(
  List<int> seasons,
  Map<int, int> seasonCounts,
  int sourceEpisodeCount,
) {
  final matches = <int>[];
  if (sourceEpisodeCount <= 0) return matches;
  for (final season in seasons) {
    if ((seasonCounts[season] ?? 0) == sourceEpisodeCount) matches.add(season);
  }
  return matches;
}

int? _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

String _asString(Object? value) => value is String ? value : (value?.toString() ?? '');

/// 把分段列表序列化为 JSON 字符串（存储层用）。
String encodeSegments(List<SeasonSegment> segments) =>
    jsonEncode(segments.map((s) => s.toJson()).toList());

/// 从 JSON 字符串解析分段列表。
List<SeasonSegment> decodeSegments(String? raw) {
  if (raw == null || raw.trim().isEmpty) return const [];
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const [];
    return decoded
        .map(SeasonSegment.fromJson)
        .whereType<SeasonSegment>()
        .toList();
  } catch (_) {
    return const [];
  }
}
