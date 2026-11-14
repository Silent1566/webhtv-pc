import 'dart:convert';

import '../core/protocol.dart';
import '../core/tmdb_identity.dart';
import '../core/viewing_metadata.dart';
import 'storage.dart';
import 'tmdb_service.dart';

class ViewingReportMetadata {
  ViewingReportMetadata({this.database, this.tmdbService});

  final AppDatabase? database;
  final TmdbService? tmdbService;

  /// Snapshot upserts actually executed (diagnostics; see TmdbService.requestCount).
  int captureWrites = 0;

  void capture({
    required String sourceKey,
    required String siteKey,
    required Vod vod,
  }) {
    final db = database;
    final title = _title(vod.vodName);
    if (db == null ||
        sourceKey.trim().isEmpty ||
        siteKey.trim().isEmpty ||
        vod.vodId.trim().isEmpty ||
        title.isEmpty) {
      return;
    }
    try {
      final source = ViewingMetadata(
        genres: _labels(vod.extra['type_name']).isNotEmpty
            ? _labels(vod.extra['type_name'])
            : _labels(vod.extra['vod_class']),
        areas: _labels(vod.vodArea),
        actors: _labels(vod.vodActor, splitNames: true),
        directors: _labels(vod.vodDirector, splitNames: true),
        mediaType: normalizeMediaTypeValue(
          vod.extra['media_type'] is String
              ? vod.extra['media_type'] as String
              : '',
        ),
      );
      var metadata = source;
      final embedded = vod.tmdb;
      if (embedded != null &&
          _detailTitles(embedded.detail)
              .any((value) => _title(value) == title)) {
        metadata = _fill(
          source,
          _fromDetail(embedded.detail, embedded.identity),
        );
      }
      if (!_hasData(metadata)) return;
      final previous = db.viewingMetadataJson(
        sourceKey: sourceKey.trim(),
        siteKey: siteKey,
        vodId: vod.vodId,
        sourceTitle: title,
      );
      metadata = _fill(metadata, _decode(previous));
      final json = jsonEncode(_json(metadata));
      if (json == previous) return;
      captureWrites++;
      db.upsertViewingMetadataJson(
        sourceKey: sourceKey.trim(),
        siteKey: siteKey,
        vodId: vod.vodId,
        sourceTitle: title,
        metadata: json,
      );
    } catch (_) {
      // Metadata collection must not interfere with detail or progress.
    }
  }

  Map<int, ViewingMetadata> forRecords(List<PlaybackHistory> records) {
    final db = database;
    if (db == null || !db.isHealthy) return const {};
    final sources = <(String, String, String, String), ViewingMetadata>{};
    final matches = <(String, String, String, String), TmdbIdentity?>{};
    final sourceById = <int, ViewingMetadata>{};
    final identityById = <int, TmdbIdentity>{};
    for (final record in records) {
      final title = _title(record.vodName);
      if (record.sourceKey.trim().isEmpty || title.isEmpty) continue;
      try {
        final key = (record.sourceKey, record.siteKey, record.vodId, title);
        sourceById[record.id] = sources.putIfAbsent(
          key,
          () => _decode(
            db.viewingMetadataJson(
              sourceKey: record.sourceKey,
              siteKey: record.siteKey,
              vodId: record.vodId,
              sourceTitle: title,
            ),
          ),
        );
        final identity =
            TmdbIdentity.from(record.mediaType, record.tmdbId) ??
            matches.putIfAbsent(key, () {
              final match = db.viewingMetadataTmdbMatch(
                sourceKey: record.sourceKey,
                siteKey: record.siteKey,
                vodId: record.vodId,
                sourceTitle: record.vodName,
              );
              return match == null
                  ? null
                  : TmdbIdentity.from(match['media_type'], match['tmdb_id']);
            });
        if (identity != null) identityById[record.id] = identity;
      } catch (_) {
        // Isolate corrupt rows from the remaining report records.
      }
    }
    Map<TmdbIdentity, List<Map<String, Object?>>> cached;
    try {
      cached =
          tmdbService?.cachedDetails(identityById.values.toSet()) ?? const {};
    } catch (_) {
      cached = const {};
    }
    final details = <TmdbIdentity, ViewingMetadata>{};
    final result = <int, ViewingMetadata>{};
    for (final entry in sourceById.entries) {
      final identity = identityById[entry.key];
      final fallback = identity == null
          ? const ViewingMetadata()
          : details.putIfAbsent(identity, () {
              var value = ViewingMetadata(mediaType: identity.mediaType.name);
              for (final detail
                  in cached[identity] ?? const <Map<String, Object?>>[]) {
                value = _fill(value, _fromDetail(detail, identity));
              }
              return value;
            });
      final merged = _fill(entry.value, fallback);
      if (_hasData(merged)) result[entry.key] = merged;
    }
    return result;
  }
}

String _title(String value) =>
    value.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

const _unknown = {
  '未知',
  '未知类型',
  '未知地区',
  '暂无',
  '暂无信息',
  '无',
  '未提供',
  '不详',
  'unknown',
  'n/a',
  'null',
  'none',
  '-',
  '--',
};

List<String> _labels(Object? value, {bool splitNames = false}) {
  if (value is String && _unknown.contains(value.trim().toLowerCase())) {
    return const [];
  }
  final items = value is String
      ? value.split(RegExp(r'[,，/、|｜;；]'))
      : value is List
      ? value
      : const [];
  final result = <String>[];
  for (final item in items) {
    if (item is! String) continue;
    final names = splitNames && !RegExp(r'[A-Za-z]').hasMatch(item)
        ? item.split(RegExp(r'\s+'))
        : [item];
    for (final name in names) {
      final text = name.trim();
      if (text.isEmpty ||
          _unknown.contains(text.toLowerCase()) ||
          result.contains(text)) {
        continue;
      }
      result.add(text);
    }
  }
  return List.unmodifiable(result);
}

ViewingMetadata _fill(
  ViewingMetadata first,
  ViewingMetadata fallback,
) => ViewingMetadata(
  genres: first.genres.isNotEmpty ? first.genres : fallback.genres,
  areas: first.areas.isNotEmpty ? first.areas : fallback.areas,
  actors: first.actors.isNotEmpty ? first.actors : fallback.actors,
  directors: first.directors.isNotEmpty ? first.directors : fallback.directors,
  mediaType: first.mediaType.isNotEmpty ? first.mediaType : fallback.mediaType,
);

bool _hasData(ViewingMetadata value) =>
    value.genres.isNotEmpty ||
    value.areas.isNotEmpty ||
    value.actors.isNotEmpty ||
    value.directors.isNotEmpty ||
    value.mediaType.isNotEmpty;

Map<String, Object?> _json(ViewingMetadata value) => {
  'genres': value.genres,
  'areas': value.areas,
  'actors': value.actors,
  'directors': value.directors,
  'mediaType': value.mediaType,
};

ViewingMetadata _decode(String? json) {
  if (json == null) return const ViewingMetadata();
  try {
    final value = jsonDecode(json);
    if (value is! Map) return const ViewingMetadata();
    return ViewingMetadata(
      genres: _labels(value['genres']),
      areas: _labels(value['areas']),
      actors: _labels(value['actors']),
      directors: _labels(value['directors']),
      mediaType: normalizeMediaTypeValue(
        value['mediaType'] is String ? value['mediaType'] as String : '',
      ),
    );
  } catch (_) {
    return const ViewingMetadata();
  }
}

Iterable<String> _detailTitles(Map<String, Object?> detail) => [
  for (final key in ['title', 'name', 'original_title', 'original_name'])
    if (detail[key] is String) detail[key] as String,
];

List<String> _names(Object? value) => _labels(
  value is List
      ? [
          for (final item in value)
            if (item is Map && item['name'] is String) item['name'],
        ]
      : const [],
);

ViewingMetadata _fromDetail(
  Map<String, Object?> detail,
  TmdbIdentity identity,
) {
  if (detail['id'] != identity.tmdbId) return const ViewingMetadata();
  final rawType = detail['media_type'];
  if (rawType != null && TmdbMediaType.parse(rawType) != identity.mediaType) {
    return const ViewingMetadata();
  }
  final credits = detail['credits'];
  final aggregate = detail['aggregate_credits'];
  final cast = _names(aggregate is Map ? aggregate['cast'] : null);
  final countries = detail['production_countries'];
  final areas = _labels(
    countries is List
        ? [
            for (final country in countries)
              if (country is Map)
                country['name'] is String &&
                        (country['name'] as String).trim().isNotEmpty
                    ? country['name']
                    : country['iso_3166_1'],
          ]
        : const [],
  );
  final directors = <String>[];
  for (final group in [credits, aggregate]) {
    if (group is! Map || group['crew'] is! List) continue;
    for (final member in group['crew'] as List) {
      if (member is! Map) continue;
      final jobs = member['jobs'];
      if (member['job'] == 'Director' ||
          jobs is List &&
              jobs.any((job) => job is Map && job['job'] == 'Director')) {
        if (member['name'] is String) directors.add(member['name'] as String);
      }
    }
  }
  return ViewingMetadata(
    genres: _names(detail['genres']),
    areas: areas.isNotEmpty ? areas : _labels(detail['origin_country']),
    actors: cast.isNotEmpty
        ? cast
        : _names(credits is Map ? credits['cast'] : null),
    directors: _labels(directors),
    mediaType: identity.mediaType.name,
  );
}
