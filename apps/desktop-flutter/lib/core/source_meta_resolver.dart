import 'meta_pipeline.dart';
import 'meta_source.dart';
import 'protocol.dart';
import 'source_detail_meta.dart';
import 'tmdb_detail_model.dart';
import 'tmdb_media.dart';

/// Resolves display fields from unmixed provider snapshots. The resource stays
/// local and never acquires an external work or person identity.
abstract final class SourceMetaResolver {
  static bool _scalar(MetaField field) => const {
    MetaField.title,
    MetaField.overview,
    MetaField.poster,
    MetaField.backdrop,
    MetaField.releaseDate,
  }.contains(field);

  static bool _text(String? value) => (value ?? '').trim().isNotEmpty;

  static bool _has(MetaField field, TmdbDetailData data) => switch (field) {
    MetaField.title => _text(data.title),
    MetaField.overview => _text(data.overview),
    MetaField.poster => _text(data.posterUrl),
    MetaField.backdrop => data.backdropUrls.any(_text),
    MetaField.cast => data.cast.isNotEmpty,
    MetaField.crew =>
      data.creatorTeam.isNotEmpty ||
          data.crew.isNotEmpty ||
          data.creators.isNotEmpty ||
          data.directors.isNotEmpty ||
          data.writers.isNotEmpty,
    MetaField.genres => data.genres.any(_text),
    MetaField.countries => data.countries.any(_text),
    MetaField.languages => data.languages.any(_text),
    MetaField.releaseDate => _text(data.releaseDate),
    _ => false,
  };

  /// Only load a provider when a configured field needs it. A single raw
  /// snapshot serves every field, but its identity never labels mixed data.
  static Future<Map<MetaSourceKind, TmdbDetailData>> loadProviders({
    required MetaPipeline pipeline,
    required Vod source,
    TmdbDetailData? tmdb,
    required Future<TmdbDetailData?> Function(MetaSourceKind) load,
  }) async {
    final local = sourceDetailMeta(source);
    final loaded = <MetaSourceKind, TmdbDetailData?>{};
    for (final field in MetaField.values.where(MetaPipeline.supportsSource)) {
      for (final kind in pipeline.orderOf(field)) {
        final TmdbDetailData? data;
        if (kind == MetaSourceKind.source) {
          data = local;
        } else if (kind == MetaSourceKind.tmdb) {
          data = tmdb;
        } else {
          if (!loaded.containsKey(kind)) loaded[kind] = await load(kind);
          data = loaded[kind];
        }
        if (data != null &&
            _has(field, data) &&
            (_scalar(field) ||
                pipeline.modeOf(field) == MetaFieldMode.priority)) {
          break;
        }
      }
    }
    return {
      for (final entry in loaded.entries)
        if (entry.value != null) entry.key: entry.value!,
    };
  }

  static TmdbDetailData resolve({
    required MetaPipeline pipeline,
    required Vod source,
    TmdbDetailData? tmdb,
    Map<MetaSourceKind, TmdbDetailData> providers = const {},
    TmdbDetailData? primary,
  }) {
    final snapshots = {
      ...providers,
      MetaSourceKind.source: sourceDetailMeta(source),
      MetaSourceKind.tmdb: ?tmdb,
    };
    final base = tmdb ?? primary ?? const TmdbDetailData();
    List<TmdbDetailData> selected(MetaField field) {
      final values = <TmdbDetailData>[];
      for (final kind in pipeline.orderOf(field)) {
        final value = snapshots[kind];
        if (value == null || !_has(field, value)) continue;
        values.add(value);
        if (_scalar(field) || pipeline.modeOf(field) == MetaFieldMode.priority) {
          break;
        }
      }
      return values;
    }

    TmdbDetailData first(MetaField field) =>
        selected(field).firstOrNull ?? const TmdbDetailData();
    List<T> list<T>(
      MetaField field,
      List<T> Function(TmdbDetailData) items,
      Object Function(T) key,
    ) {
      final seen = <Object>{};
      return [
        for (final value in selected(field))
          for (final item in items(value))
            if (seen.add(key(item))) item,
      ];
    }

    List<String> strings(
      MetaField field,
      List<String> Function(TmdbDetailData) items,
    ) => list(
      field,
      (data) =>
          items(data).map((s) => s.trim()).where((s) => s.isNotEmpty).toList(),
      (s) => s,
    );
    Object personKey(TmdbPerson person) => person.name.trim().toLowerCase();
    final poster = first(MetaField.poster);
    return TmdbDetailData(
      tmdbId: base.tmdbId,
      mediaType: base.mediaType,
      title: first(MetaField.title).title,
      originalTitle: base.originalTitle,
      overview: first(MetaField.overview).overview,
      tagline: base.tagline,
      posterUrl: poster.posterUrl,
      posterUrls: poster.posterUrls,
      backdropUrls: first(MetaField.backdrop).backdropUrls
          .where(_text)
          .toList(),
      photoUrls: base.photoUrls,
      stillUrls: base.stillUrls,
      seasons: base.seasons,
      cast: list(MetaField.cast, (d) => d.cast, personKey),
      crew: list(MetaField.crew, (d) => d.crew, personKey),
      creators: list(MetaField.crew, (d) => d.creators, personKey),
      creatorTeam: list(MetaField.crew, (d) => d.creatorTeam, personKey),
      directors: strings(MetaField.crew, (d) => d.directors),
      writers: strings(MetaField.crew, (d) => d.writers),
      genres: strings(MetaField.genres, (d) => d.genres),
      countries: strings(MetaField.countries, (d) => d.countries),
      languages: strings(MetaField.languages, (d) => d.languages),
      releaseDate: first(MetaField.releaseDate).releaseDate,
      networks: base.networks,
      rating: base.rating,
      ratingSourceLabel: base.ratingSourceLabel,
      voteCount: base.voteCount,
      runtime: base.runtime,
      seasonCount: base.seasonCount,
      episodeCount: base.episodeCount,
      status: base.status,
      homepage: base.homepage,
    );
  }
}
