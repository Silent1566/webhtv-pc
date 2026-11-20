import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/meta_pipeline.dart';
import 'package:webhtv_pc/core/meta_source.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/source_meta_resolver.dart';
import 'package:webhtv_pc/core/tmdb_detail_model.dart';
import 'package:webhtv_pc/core/tmdb_media.dart';

MetaPipeline ordered(
  List<MetaSourceKind> order, {
  MetaFieldMode mode = MetaFieldMode.priority,
}) {
  var pipeline = MetaPipeline.defaults;
  for (final field in MetaField.values.where(MetaPipeline.supportsSource)) {
    pipeline = pipeline.withRule(
      pipeline.ruleOf(field).copyWith(order: order, mode: mode),
    );
  }
  return pipeline;
}

final vod = Vod(
  vodId: 'local',
  vodName: 'Local',
  vodContent: 'Local overview',
  vodPic: 'local.jpg',
  vodActor: 'Local actor',
  vodDirector: 'Local director',
  vodYear: '2024',
  vodArea: 'Local country',
  extra: {'type_name': 'Drama', 'vod_lang': 'Local language'},
);
const tmdb = TmdbDetailData(
  tmdbId: 42,
  title: 'TMDB',
  overview: 'TMDB overview',
  posterUrl: 'tmdb.jpg',
  backdropUrls: ['tmdb-bg.jpg'],
  genres: ['Drama', 'TMDB genre'],
  cast: [TmdbPerson(personId: 9, name: 'TMDB actor')],
  networks: ['Netflix'],
  seasons: [TmdbSeasonInfo(number: 1, episodeCount: 8)],
  runtime: 50,
  status: 'Ended',
  rating: 8,
);

void main() {
  test('defaults fill ten missing fields from original resource and never invent identity or rating', () {
    final value = SourceMetaResolver.resolve(
      pipeline: MetaPipeline.defaults,
      source: vod,
    );
    expect(value.title, 'Local');
    expect(value.overview, 'Local overview');
    expect(value.posterUrl, 'local.jpg');
    expect(value.backdropUrls, ['local.jpg']);
    expect(value.cast.single.name, 'Local actor');
    expect(value.cast.single.ref, isNull);
    expect(value.cast.single.personId, lessThan(0));
    expect(value.creatorTeam.single.name, 'Local director');
    expect(value.genres, ['Drama']);
    expect(value.countries, ['Local country']);
    expect(value.languages, ['Local language']);
    expect(value.releaseDate, '2024');
    expect(value.tmdbId, 0);
    expect(value.rating, 0);
  });
  test('source first wins while preserving nonconfigurable TMDB metadata', () {
    final value = SourceMetaResolver.resolve(
      pipeline: ordered([MetaSourceKind.source, MetaSourceKind.tmdb]),
      source: vod,
      tmdb: tmdb,
    );
    expect(value.title, 'Local');
    expect(value.overview, 'Local overview');
    expect(value.posterUrl, 'local.jpg');
    expect(value.backdropUrls, ['local.jpg']);
    expect(value.cast.single.name, 'Local actor');
    expect(value.genres, ['Drama']);
    expect(value.tmdbId, 42);
    expect(value.networks, ['Netflix']);
    expect(value.seasons.single.episodeCount, 8);
    expect(value.runtime, 50);
    expect(value.status, 'Ended');
    expect(value.rating, 8);
  });
  test(
    'disabled source cannot leak from any field or from TMDB-enriched Vod',
    () {
      final value = SourceMetaResolver.resolve(
        pipeline: ordered([MetaSourceKind.tmdb]),
        source: vod,
        tmdb: const TmdbDetailData(tmdbId: 42),
      );
      expect(value.title, isEmpty);
      expect(value.overview, isNull);
      expect(value.posterUrl, isNull);
      expect(value.backdropUrls, isEmpty);
      expect(value.cast, isEmpty);
      expect(value.creatorTeam, isEmpty);
      expect(value.genres, isEmpty);
      expect(value.countries, isEmpty);
      expect(value.languages, isEmpty);
      expect(value.releaseDate, isEmpty);
    },
  );
  test(
    'external ordering uses raw provider fields not a mixed primary identity',
    () {
      final value = SourceMetaResolver.resolve(
        pipeline: ordered([
          MetaSourceKind.bangumi,
          MetaSourceKind.douban,
          MetaSourceKind.tmdb,
          MetaSourceKind.source,
        ]),
        source: vod,
        tmdb: tmdb,
        providers: {
          MetaSourceKind.douban: const TmdbDetailData(
            title: 'Douban',
            overview: 'Douban overview',
          ),
          MetaSourceKind.bangumi: const TmdbDetailData(
            title: 'Bangumi',
            overview: '  ',
          ),
        },
      );
      expect(value.title, 'Bangumi');
      expect(value.overview, 'Douban overview');
      expect(value.posterUrl, 'tmdb.jpg');
    },
  );
  test('aggregate scalar uses first value while lists merge in configured order with deduplication', () {
    final value = SourceMetaResolver.resolve(
      pipeline: ordered([
        MetaSourceKind.source,
        MetaSourceKind.tmdb,
      ], mode: MetaFieldMode.aggregate),
      source: vod,
      tmdb: tmdb,
    );
    expect(value.title, 'Local');
    expect(value.backdropUrls, ['local.jpg']);
    expect(value.genres, ['Drama', 'TMDB genre']);
    expect(value.cast.map((p) => p.name), ['Local actor', 'TMDB actor']);
  });
  test(
    'lazy loads stop per scalar and priority list, providers are loaded once',
    () async {
      final calls = <MetaSourceKind>[];
      final providers = await SourceMetaResolver.loadProviders(
        pipeline: ordered([MetaSourceKind.source, MetaSourceKind.bangumi]),
        source: vod,
        load: (kind) async {
          calls.add(kind);
          return const TmdbDetailData(title: 'External');
        },
      );
      expect(calls, isEmpty);
      expect(providers, isEmpty);
    },
  );
}
