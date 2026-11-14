/// TMDB 匹配与季度的 SQLite 存储适配（`docs/phase4/design/03` §6）。
///
/// 把 `TmdbMatchStore` / `TmdbSeasonStore` 两个纯逻辑接口接到 [AppDatabase]，
/// 使 `TmdbIdentityService` / `TmdbSeasonService` 在应用里具备**持久化**能力
/// （此前只有 `InMemory*` 实现，重启即丢）。
///
/// 设计约束：
/// - 任何一次读写失败都**不得**影响播放与浏览（`03` §6.6）：全部 try/catch 后降级；
/// - 读取顺序必须与 `TmdbMatchCache.findScoped` 一致（`01` §2.4）；
/// - 列表字段（`segments` / `season_numbers`）统一用 JSON 文本承载。
library;

import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import '../core/tmdb_identity.dart';
import '../core/tmdb_season.dart';
import 'storage.dart';
import 'tmdb_identity_service.dart';
import 'tmdb_season_service.dart';

/// 匹配记录的持久化实现。
class DatabaseTmdbMatchStore implements TmdbMatchStore {
  DatabaseTmdbMatchStore({required this.database, required this.configId});

  final AppDatabase database;
  final int configId;

  static const String _entryScope = 'entry';
  static const String _scopedScope = 'scoped';
  static const String _titleScope = 'title';
  static const String _conflictMarker = '__conflict__';

  @override
  TmdbMatchRecord? find({
    required String siteKey,
    required String vodId,
    String? sourceTitle,
  }) {
    try {
      final normalized = TmdbCacheKey.normalizeSourceTitle(sourceTitle);
      // 读取顺序（`01` §2.4）：手动条目级锚点 → 条目+标题 → 条目级 → 标题域。
      final anchor = _row(
        siteKey: siteKey,
        vodId: vodId,
        sourceTitle: '',
        scope: _entryScope,
      );
      final anchorRecord = anchor == null ? null : _record(anchor);
      if (anchorRecord != null &&
          anchorRecord.isManual &&
          anchorRecord.matchesManualTitle(normalized)) {
        return anchorRecord;
      }

      if (normalized.isNotEmpty) {
        final scoped = _row(
          siteKey: siteKey,
          vodId: vodId,
          sourceTitle: normalized,
          scope: _scopedScope,
        );
        final scopedRecord = scoped == null ? null : _record(scoped);
        if (scopedRecord != null) return scopedRecord;
      }

      if (_compatible(anchorRecord, normalized)) return anchorRecord;

      if (normalized.isEmpty) return null;
      // 标题域：以 (site_key='', vod_id=归一化标题) 承载；冲突用 source_title 标记。
      final title = _row(
        siteKey: '',
        vodId: normalized,
        sourceTitle: '',
        scope: _titleScope,
      );
      if (title != null) {
        if (title['source_title'] == _conflictMarker) return null;
        final record = _record(title);
        return _compatible(record, normalized) ? record : null;
      }
      return null;
    } catch (_) {
      // 存储不可用 → 视为未命中（降级为无匹配，不影响浏览与播放）
      return null;
    }
  }

  @override
  void putAuto({
    required String siteKey,
    required String vodId,
    required TmdbItem item,
    String? sourceTitle,
    required int matchedAt,
  }) {
    if (item.identity == null || siteKey.isEmpty || vodId.isEmpty) return;
    try {
      // 手动结论不得被自动覆盖（`01` §2.5）。
      final existing = find(
        siteKey: siteKey,
        vodId: vodId,
        sourceTitle: sourceTitle,
      );
      if (existing?.isManual ?? false) return;

      final normalized = TmdbCacheKey.normalizeSourceTitle(sourceTitle);
      if (normalized.isEmpty) {
        _write(
          siteKey: siteKey,
          vodId: vodId,
          sourceTitle: '',
          scope: _entryScope,
          item: item,
          manual: false,
          manualTitles: const [],
          matchedAt: matchedAt,
        );
        return;
      }
      _write(
        siteKey: siteKey,
        vodId: vodId,
        sourceTitle: normalized,
        scope: _scopedScope,
        item: item,
        manual: false,
        manualTitles: const [],
        matchedAt: matchedAt,
      );
      _putTitle(
        normalized,
        item,
        manual: false,
        manualTitles: const [],
        matchedAt: matchedAt,
      );
    } catch (_) {
      // 写失败不影响播放结果（`03` §6.6）
    }
  }

  @override
  void putManual({
    required String siteKey,
    required String vodId,
    required List<String> sourceTitles,
    required TmdbItem item,
    required int matchedAt,
  }) {
    if (item.identity == null || siteKey.isEmpty || vodId.isEmpty) return;
    try {
      final aliases = <String>{};
      for (final sourceTitle in sourceTitles) {
        final normalized = TmdbCacheKey.normalizeSourceTitle(sourceTitle);
        if (normalized.isNotEmpty) aliases.add(normalized);
      }
      // TMDB 标题本身也是别名：富集会把 vodName 改写为它，下次进场要能读回。
      final tmdbTitle = TmdbCacheKey.normalizeSourceTitle(item.title);
      if (tmdbTitle.isNotEmpty) aliases.add(tmdbTitle);
      final list = aliases.toList();

      _write(
        siteKey: siteKey,
        vodId: vodId,
        sourceTitle: '',
        scope: _entryScope,
        item: item,
        manual: true,
        manualTitles: list,
        matchedAt: matchedAt,
      );
      for (final alias in list) {
        _write(
          siteKey: siteKey,
          vodId: vodId,
          sourceTitle: alias,
          scope: _scopedScope,
          item: item,
          manual: true,
          manualTitles: list,
          matchedAt: matchedAt,
        );
        _putTitle(
          alias,
          item,
          manual: true,
          manualTitles: list,
          matchedAt: matchedAt,
        );
      }
    } catch (_) {
      // 静默降级
    }
  }

  @override
  void remove({required String siteKey, required String vodId}) {
    try {
      database.removeTmdbMatches(
        configId: configId,
        siteKey: siteKey,
        vodId: vodId,
      );
    } catch (_) {
      // 静默降级
    }
  }

  // -------------------------------------------------------------------------
  // 内部
  // -------------------------------------------------------------------------

  Row? _row({
    required String siteKey,
    required String vodId,
    required String sourceTitle,
    required String scope,
  }) => database.findTmdbMatch(
    configId: configId,
    siteKey: siteKey,
    vodId: vodId,
    sourceTitle: sourceTitle,
    scope: scope,
  );

  void _write({
    required String siteKey,
    required String vodId,
    required String sourceTitle,
    required String scope,
    required TmdbItem item,
    required bool manual,
    required List<String> manualTitles,
    required int matchedAt,
  }) {
    final identity = item.identity!;
    database.upsertTmdbMatch(
      configId: configId,
      siteKey: siteKey,
      vodId: vodId,
      sourceTitle: sourceTitle,
      scope: scope,
      tmdbId: identity.tmdbId,
      mediaType: identity.mediaType.name,
      title: item.title,
      subtitle: item.subtitle,
      overview: item.overview,
      posterUrl: item.posterUrl,
      backdropUrl: item.backdropUrl,
      credit: item.credit,
      rating: item.rating,
      originalLanguage: item.originalLanguage,
      originCountry: item.originCountry,
      manual: manual,
      manualTitles: manualTitles,
      matchedAt: matchedAt,
    );
  }

  /// 维护全局标题域（`01` §2.4）：
  /// 同身份 → 覆盖；手动优先于自动；两个手动且身份不同 → 记冲突。
  void _putTitle(
    String normalizedTitle,
    TmdbItem item, {
    required bool manual,
    required List<String> manualTitles,
    required int matchedAt,
  }) {
    if (normalizedTitle.isEmpty) return;
    void write({required bool asManual}) => _write(
      siteKey: '',
      vodId: normalizedTitle,
      sourceTitle: '',
      scope: _titleScope,
      item: item,
      manual: asManual,
      manualTitles: manualTitles,
      matchedAt: matchedAt,
    );

    final existing = _row(
      siteKey: '',
      vodId: normalizedTitle,
      sourceTitle: '',
      scope: _titleScope,
    );
    if (existing == null) {
      write(asManual: manual);
      return;
    }
    if (existing['source_title'] == _conflictMarker) return;
    final sameIdentity = existing['tmdb_id'] == item.tmdbId &&
        existing['media_type'] == item.mediaType.name;
    if (sameIdentity) {
      write(asManual: manual);
      return;
    }
    final existingManual = (existing['manual'] as int? ?? 0) != 0;
    if (manual && !existingManual) {
      write(asManual: true);
      return;
    }
    if (existingManual && !manual) {
      // 保留手动结论，自动猜测不得冲掉它。
      return;
    }
    // 两个手动且身份不同 → 真正的同名歧义。
    database.upsertTmdbMatch(
      configId: configId,
      siteKey: '',
      vodId: normalizedTitle,
      sourceTitle: _conflictMarker,
      scope: _titleScope,
      tmdbId: item.tmdbId,
      mediaType: item.mediaType.name,
      title: item.title,
      matchedAt: matchedAt,
    );
  }

  TmdbMatchRecord? _record(Row row) {
    final mediaType = TmdbMediaType.parse(row['media_type']);
    final identity = TmdbIdentity.of(mediaType, row['tmdb_id'] as int?);
    if (identity == null) return null;
    final raw = row['manual_titles'] as String?;
    final rating = (row['rating'] as num?)?.toDouble() ?? 0;
    return TmdbMatchRecord(
      identity: identity,
      title: row['title'] as String? ?? '',
      subtitle: row['subtitle'] as String? ?? '',
      overview: row['overview'] as String?,
      posterUrl: row['poster_url'] as String?,
      backdropUrl: row['backdrop_url'] as String?,
      credit: row['credit'] as String?,
      rating: rating,
      tmdbRating: rating,
      originalLanguage: row['original_language'] as String? ?? '',
      originCountry: row['origin_country'] as String? ?? '',
      manual: (row['manual'] as int? ?? 0) != 0,
      manualTitles: raw == null || raw.isEmpty ? const [] : raw.split('\u0001'),
      matchedAt: row['matched_at'] as int? ?? 0,
    );
  }

  /// 标题兼容（`01` §2.4）：源标题为空，或与缓存标题归一后相等。
  bool _compatible(TmdbMatchRecord? record, String normalizedTitle) {
    if (record == null || record.identity.tmdbId <= 0) return false;
    if (normalizedTitle.isEmpty) return true;
    final cached = TmdbCacheKey.normalizeSourceTitle(record.title);
    return cached.isEmpty || cached == normalizedTitle;
  }
}

/// 季度绑定 / 线路绑定 / 季度进度的持久化实现（`02` §5、§6）。
class DatabaseTmdbSeasonStore implements TmdbSeasonStore {
  DatabaseTmdbSeasonStore({required this.database});

  final AppDatabase database;

  @override
  SeasonBinding? findBinding({
    required int configId,
    required String siteKey,
    required String vodId,
    required String sourceTitle,
    required String flagKey,
  }) {
    try {
      final row = database.findTmdbSeasonBinding(
        configId: configId,
        siteKey: siteKey,
        vodId: vodId,
        sourceTitle: sourceTitle,
        flagKey: flagKey,
      );
      return row == null ? null : _binding(row);
    } catch (_) {
      return null;
    }
  }

  @override
  void saveBinding({required int configId, required SeasonBinding binding}) {
    try {
      database.upsertTmdbSeasonBinding(
        configId: configId,
        siteKey: binding.siteKey,
        vodId: binding.vodId,
        sourceTitle: binding.sourceTitle,
        flagKey: binding.flagKey,
        tmdbId: binding.tmdbId,
        mediaType: binding.mediaType.name,
        mode: binding.mode.name,
        seasonNumber: binding.seasonNumber,
        sourceFingerprint: binding.sourceFingerprint,
        sourceEpisodeCount: binding.sourceEpisodeCount,
        tmdbSeasonEpisodeCount: binding.tmdbSeasonEpisodeCount,
        segments: binding.segments.isEmpty
            ? null
            : encodeSegments(binding.segments),
        version: binding.version,
        updatedAt: binding.updatedAt,
      );
    } catch (_) {
      // 写失败不影响播放（`03` §6.6）
    }
  }

  @override
  void removeBinding({
    required int configId,
    required String siteKey,
    required String vodId,
    String? sourceTitle,
    String? flagKey,
  }) {
    try {
      database.removeTmdbSeasonBindings(
        configId: configId,
        siteKey: siteKey,
        vodId: vodId,
        sourceTitle: sourceTitle,
        flagKey: flagKey,
      );
    } catch (_) {}
  }

  @override
  void saveRouteBinding({required int configId, required RouteBinding binding}) {
    try {
      final scope = binding.scope;
      database.upsertTmdbRouteBinding(
        configId: configId,
        siteKey: binding.siteKey,
        vodId: binding.vodId,
        flagKey: binding.flagKey,
        sourceFlag: binding.sourceFlag,
        sourceFingerprint: binding.sourceFingerprint,
        tmdbId: binding.tmdbId,
        mediaType: binding.mediaType.name,
        scopeKind: scopeKindOf(scope),
        seasonNumbers: jsonEncode(scope.seasons),
        segments: scope is MultiSeason
            ? encodeSegments(scope.segments)
            : null,
        updatedAt: binding.updatedAt,
      );
    } catch (_) {}
  }

  @override
  void removeRouteBinding({
    required int configId,
    required String siteKey,
    required String vodId,
    required String flagKey,
  }) {
    try {
      database.removeTmdbRouteBinding(
        configId: configId,
        siteKey: siteKey,
        vodId: vodId,
        flagKey: flagKey,
      );
    } catch (_) {}
  }

  @override
  List<RouteBinding> routeBindings({
    required int configId,
    required int tmdbId,
    required String mediaType,
  }) {
    try {
      // `TmdbSeasonService._allRouteBindingsForScope` 用 `tmdbId = 0` +
      // `mediaType = ''` 表达「全量查询」语义（接口注释：实现方负责忽略过滤），
      // 容量淘汰（§5.5）依赖它。
      final rows = tmdbId <= 0 && mediaType.isEmpty
          ? database.tmdbRouteBindingsAll(configId: configId)
          : database.tmdbRouteBindingsFor(
              configId: configId,
              tmdbId: tmdbId,
              mediaType: mediaType,
              seasonNumber: 0,
            );
      final result = <RouteBinding>[];
      for (final row in rows) {
        final binding = _routeBinding(row);
        if (binding != null) result.add(binding);
      }
      return result;
    } catch (_) {
      return const [];
    }
  }

  @override
  TmdbSeasonProgressRecord? findProgress({
    required int configId,
    required String mediaType,
    required int tmdbId,
    required int seasonNumber,
  }) {
    try {
      final row = database.findTmdbSeasonProgress(
        configId: configId,
        mediaType: mediaType,
        tmdbId: tmdbId,
        seasonNumber: seasonNumber,
      );
      return row == null ? null : _progress(row);
    } catch (_) {
      return null;
    }
  }

  @override
  void saveProgress({
    required int configId,
    required TmdbSeasonProgressRecord record,
  }) {
    try {
      database.upsertTmdbSeasonProgress(
        configId: configId,
        mediaType: record.mediaType,
        tmdbId: record.tmdbId,
        seasonNumber: record.seasonNumber,
        episodeNumber: record.episodeNumber,
        positionMs: record.positionMs,
        durationMs: record.durationMs,
        sourceFlag: record.sourceFlag,
        sourceEpisodeName: record.sourceEpisodeName,
        sourceEpisodeUrl: record.sourceEpisodeUrl,
        sourceHistoryKey: record.sourceHistoryKey,
        sourceBindingKey: record.sourceBindingKey,
        updatedAt: record.updatedAt,
      );
    } catch (_) {
      // 进度写失败不影响播放（§15.2）
    }
  }

  @override
  List<TmdbSeasonProgressRecord> progressForMedia({
    required int configId,
    required String mediaType,
    required int tmdbId,
  }) {
    try {
      return database
          .tmdbSeasonProgressFor(
            configId: configId,
            mediaType: mediaType,
            tmdbId: tmdbId,
          )
          .map(_progress)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  @override
  int removeProgress({
    required int configId,
    required String mediaType,
    required int tmdbId,
    required int seasonNumber,
  }) {
    try {
      return database.removeTmdbSeasonProgress(
        configId: configId,
        mediaType: mediaType,
        tmdbId: tmdbId,
        seasonNumber: seasonNumber,
      );
    } catch (_) {
      return 0;
    }
  }

  @override
  int removeProgressForMedia({
    required int configId,
    required String mediaType,
    required int tmdbId,
  }) {
    try {
      return database.removeTmdbSeasonProgressForMedia(
        configId: configId,
        mediaType: mediaType,
        tmdbId: tmdbId,
      );
    } catch (_) {
      return 0;
    }
  }

  // -------------------------------------------------------------------------
  // 行 → 模型
  // -------------------------------------------------------------------------

  SeasonBinding? _binding(Row row) {
    final mode = SeasonBindingMode.parse(row['mode']);
    final mediaType = TmdbMediaType.parse(row['media_type']);
    if (mode == null || mediaType == null) return null;
    return SeasonBinding(
      siteKey: row['site_key'] as String? ?? '',
      vodId: row['vod_id'] as String? ?? '',
      sourceTitle: row['source_title'] as String? ?? '',
      flagKey: row['flag_key'] as String? ?? '',
      tmdbId: row['tmdb_id'] as int? ?? 0,
      mediaType: mediaType,
      mode: mode,
      seasonNumber: row['season_number'] as int?,
      sourceFingerprint: row['source_fingerprint'] as String? ?? '',
      sourceEpisodeCount: row['source_episode_count'] as int? ?? 0,
      tmdbSeasonEpisodeCount: row['tmdb_season_episode_count'] as int? ?? 0,
      segments: decodeSegments(row['segments'] as String?),
      updatedAt: row['updated_at'] as int? ?? 0,
      version: row['version'] as int? ?? seasonBindingVersion,
    );
  }

  RouteBinding? _routeBinding(Row row) {
    final mediaType = TmdbMediaType.parse(row['media_type']);
    if (mediaType == null) return null;
    final kind = row['scope_kind'] as String? ?? 'unknown';
    final seasons = decodeIntList(row['season_numbers'] as String?);
    final segments = decodeSegments(row['segments'] as String?);
    final scope = SeasonScope.fromJson({
      'kind': kind,
      'seasonNumber': seasons.isEmpty ? null : seasons.first,
      'segments': segments.map((segment) => segment.toJson()).toList(),
    });
    return RouteBinding(
      siteKey: row['site_key'] as String? ?? '',
      vodId: row['vod_id'] as String? ?? '',
      flagKey: row['flag_key'] as String? ?? '',
      sourceFlag: row['source_flag'] as String? ?? '',
      sourceFingerprint: row['source_fingerprint'] as String? ?? '',
      tmdbId: row['tmdb_id'] as int? ?? 0,
      mediaType: mediaType,
      scope: scope,
      updatedAt: row['updated_at'] as int? ?? 0,
    );
  }

  TmdbSeasonProgressRecord _progress(Row row) => TmdbSeasonProgressRecord(
    configId: row['config_id'] as int? ?? 0,
    mediaType: row['media_type'] as String? ?? 'tv',
    tmdbId: row['tmdb_id'] as int? ?? 0,
    seasonNumber: row['season_number'] as int? ?? 0,
    episodeNumber: row['episode_number'] as int? ?? 0,
    positionMs: row['position_ms'] as int? ?? 0,
    durationMs: row['duration_ms'] as int? ?? 0,
    sourceFlag: row['source_flag'] as String? ?? '',
    sourceEpisodeName: row['source_episode_name'] as String? ?? '',
    sourceEpisodeUrl: row['source_episode_url'] as String? ?? '',
    sourceHistoryKey: row['source_history_key'] as String? ?? '',
    sourceBindingKey: row['source_binding_key'] as String? ?? '',
    updatedAt: row['updated_at'] as int? ?? 0,
  );
}

/// `SeasonScope` 的存储 kind（与 [SeasonScope.toJson] 的 `kind` 一致）。
String scopeKindOf(SeasonScope scope) => switch (scope) {
  KnownSeason() => 'known',
  MultiSeason() => 'multi',
  UnknownSeason() => 'unknown',
};

/// 分段列表 → JSON 文本（存储层列类型为 TEXT）。
String encodeSegments(List<SeasonSegment> segments) =>
    jsonEncode(segments.map((segment) => segment.toJson()).toList());

/// JSON 文本 → 分段列表；非法内容返回空列表。
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

/// JSON 文本 → 整数列表；非法内容返回空列表。
List<int> decodeIntList(String? raw) {
  if (raw == null || raw.trim().isEmpty) return const [];
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const [];
    return decoded
        .map((value) => value is int ? value : int.tryParse('$value'))
        .whereType<int>()
        .toList();
  } catch (_) {
    return const [];
  }
}
