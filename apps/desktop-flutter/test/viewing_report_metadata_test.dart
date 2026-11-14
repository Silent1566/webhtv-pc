import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:sqlite3/sqlite3.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/tmdb_config.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/services/tmdb_cache.dart';
import 'package:webhtv_pc/services/tmdb_service.dart';
import 'package:webhtv_pc/services/tmdb_stores.dart';
import 'package:webhtv_pc/services/viewing_report_metadata.dart';
import 'package:webhtv_pc/services/storage.dart';

PlaybackHistory record({
  int id = 1,
  String source = 'local|A',
  String title = 'Title',
  int tmdbId = 0,
  String type = '',
}) => PlaybackHistory(
  id: id,
  sourceKey: source,
  siteKey: 's',
  vodId: 'v',
  vodName: title,
  flag: 'f',
  episodeName: 'e',
  episodeId: 'e',
  positionMs: 123,
  durationMs: 456,
  updatedAt: 100,
  tmdbId: tmdbId,
  mediaType: type,
);

void main() {
  test('progress-like bare Vod never rewrites an existing snapshot', () {
    final db = AppDatabase.inMemory();
    addTearDown(db.dispose);
    final provider = ViewingReportMetadata(database: db);
    provider.capture(sourceKey: 'local|A', siteKey: 's', vod: Vod(vodId: 'v', vodName: 'Title', vodActor: 'Actor', vodDirector: 'Director'));
    expect(provider.captureWrites, 1);
    // Player-constructed Vod carries only id/name/pic: merged == known, so the
    // 5-second progress path must not upsert the identical JSON again.
    for (var i = 0; i < 12; i++) {
      provider.capture(sourceKey: 'local|A', siteKey: 's', vod: Vod(vodId: 'v', vodName: 'Title', vodPic: 'p.jpg'));
    }
    expect(provider.captureWrites, 1);
    // A subset of what is already stored is equally a no-op.
    provider.capture(sourceKey: 'local|A', siteKey: 's', vod: Vod(vodId: 'v', vodName: 'Title', vodActor: 'Actor'));
    expect(provider.captureWrites, 1);
    expect(provider.forRecords([record()])[1]?.directors, ['Director']);
    // New information still writes, and keeps the known dimensions.
    provider.capture(sourceKey: 'local|A', siteKey: 's', vod: Vod(vodId: 'v', vodName: 'Title', vodArea: 'Japan'));
    expect(provider.captureWrites, 2);
    final merged = provider.forRecords([record()])[1]!;
    expect(merged.areas, ['Japan']);
    expect(merged.actors, ['Actor']);
    expect(merged.directors, ['Director']);
  });

  test('validated embedded source detail fills only missing dimensions', () {
    final db = AppDatabase.inMemory();
    addTearDown(db.dispose);
    final provider = ViewingReportMetadata(database: db);
    Map<String, Object?> payload({int id = 77, String title = 'Title'}) => {
      'schema': 1,
      'id': 77,
      'media_type': 'movie',
      'detail': {
        'id': id,
        'title': title,
        'genres': [
          {'name': 'Embedded genre'},
        ],
        'origin_country': ['JP'],
        'credits': {
          'cast': [
            {'name': 'Embedded actor'},
          ],
          'crew': [
            {'name': 'Embedded director', 'job': 'Director'},
          ],
        },
      },
    };
    provider.capture(
      sourceKey: 'local|A',
      siteKey: 's',
      vod: Vod(
        vodId: 'v',
        vodName: 'Title',
        vodActor: 'Source actor',
        extra: {'tmdb': payload(), 'vod_class': 'Source genre'},
      ),
    );
    final result = provider.forRecords([record()])[1]!;
    expect(result.actors, ['Source actor']);
    expect(result.genres, ['Source genre']);
    expect(result.directors, ['Embedded director']);
    expect(result.areas, ['JP']);
    expect(result.mediaType, 'movie');
    provider.capture(
      sourceKey: 'local|B',
      siteKey: 's',
      vod: Vod(
        vodId: 'v',
        vodName: 'Title',
        extra: {'tmdb': payload(title: 'Wrong')},
      ),
    );
    expect(provider.forRecords([record(source: 'local|B')]), isEmpty);
    provider.capture(
      sourceKey: 'local|C',
      siteKey: 's',
      vod: Vod(vodId: 'v', vodName: 'Title', extra: {'tmdb': payload(id: 99)}),
    );
    expect(provider.forRecords([record(source: 'local|C')]), isEmpty);
  });

  test('corrupt snapshot and cache files do not hide valid records', () async {
    final dir = await Directory.systemTemp.createTemp('viewing-corrupt');
    addTearDown(() => dir.delete(recursive: true));
    final db = AppDatabase.inMemory();
    addTearDown(db.dispose);
    db.upsertViewingMetadataJson(
      sourceKey: 'local|A',
      siteKey: 's',
      vodId: 'v',
      sourceTitle: 'title',
      metadata: '{bad',
    );
    final cache = TmdbCache(cacheDir: dir.path);
    cache.write(TmdbCacheType.detail, 'corrupt', {
      'id': 66,
      'title': 'Corrupt',
    });
    File(cache.filePath(TmdbCacheType.detail, 'corrupt')!)
        .writeAsStringSync('{bad');
    cache.write(TmdbCacheType.detail, 'valid', {
      'id': 77,
      'title': 'Title',
      'genres': [
        {'name': 'Valid'},
      ],
      'credit': 'Mixed actor / director',
      'created_by': [
        {'name': 'Not a director'},
      ],
    });
    final service = TmdbService(config: () => const TmdbConfig(), cache: cache);
    addTearDown(service.close);
    final provider = ViewingReportMetadata(database: db, tmdbService: service);
    final result = provider.forRecords([
      record(),
      record(id: 2, tmdbId: 77, type: 'movie'),
    ]);
    expect(result.containsKey(1), isFalse);
    expect(result[2]?.genres, ['Valid']);
    expect(result[2]?.actors, isEmpty);
    expect(result[2]?.directors, isEmpty);
    expect(cache.detailScanCount, 1);
    expect(service.requestCount, 0);
  });

  test(
    'aggregate cast and explicit directing jobs are independently extracted',
    () async {
      final dir = await Directory.systemTemp.createTemp('viewing-aggregate');
      addTearDown(() => dir.delete(recursive: true));
      final db = AppDatabase.inMemory();
      addTearDown(db.dispose);
      final cache = TmdbCache(cacheDir: dir.path);
      cache.write(TmdbCacheType.detail, 'tv', {
        'id': 77,
        'name': 'Title',
        'aggregate_credits': {
          'cast': [
            {'name': 'Actor'},
            {'name': 'Actor'},
          ],
          'crew': [
            {
              'name': 'Director',
              'jobs': [
                {'job': 'Director'},
              ],
            },
            {
              'name': 'Producer',
              'jobs': [
                {'job': 'Producer'},
              ],
            },
          ],
        },
        'created_by': [
          {'name': 'Creator'},
        ],
      });
      final service = TmdbService(
        config: () => const TmdbConfig(),
        cache: cache,
      );
      addTearDown(service.close);
      final result = ViewingReportMetadata(
        database: db,
        tmdbService: service,
      ).forRecords([record(tmdbId: 77, type: 'tv')])[1]!;
      expect(result.actors, ['Actor']);
      expect(result.directors, ['Director']);
      expect(result.mediaType, 'tv');
    },
  );

  test(
    'one report batch scans detail files only once for distinct identities',
    () async {
      final dir = await Directory.systemTemp.createTemp('viewing-batch');
      addTearDown(() => dir.delete(recursive: true));
      final db = AppDatabase.inMemory();
      addTearDown(db.dispose);
      final cache = TmdbCache(cacheDir: dir.path);
      for (var id = 77; id < 80; id++) {
        cache.write(TmdbCacheType.detail, 'file-id-$id', {
          'id': id,
          'title': 'Title',
          'genres': [
            {'name': 'Genre-id-$id'},
          ],
        });
      }
      final service = TmdbService(
        config: () => const TmdbConfig(),
        cache: cache,
      );
      addTearDown(service.close);
      final provider = ViewingReportMetadata(
        database: db,
        tmdbService: service,
      );
      final result = provider.forRecords([
        record(tmdbId: 77, type: 'movie'),
        record(id: 2, tmdbId: 78, type: 'movie'),
        record(id: 3, tmdbId: 77, type: 'movie'),
      ]);
      expect(result[1]?.genres, ['Genre-id-77']);
      expect(result[2]?.genres, ['Genre-id-78']);
      expect(result[3]?.genres, ['Genre-id-77']);
      expect(cache.detailScanCount, 1);
      expect(cache.detailFileReadCount, 3);
      expect(service.requestCount, 0);
      provider.forRecords([record(tmdbId: 77, type: 'movie')]);
      expect(cache.detailScanCount, 2, reason: 'no stale cross-call index');
    },
  );

  test('bound match uses existing normalized titles and manual aliases only inside its source/vod', () async {
    final dir = await Directory.systemTemp.createTemp('viewing-bound');
    addTearDown(() => dir.delete(recursive: true));
    final db = AppDatabase.inMemory();
    addTearDown(db.dispose);
    final configId = db.saveConfig(
      name: 'A',
      origin: 'A',
      sourceKey: 'local|A',
      json: {},
    );
    db.saveConfig(name: 'B', origin: 'B', sourceKey: 'local|B', json: {});
    final store = DatabaseTmdbMatchStore(database: db, configId: configId);
    store.putManual(
      siteKey: 's',
      vodId: 'v',
      sourceTitles: ['Original Name', 'Alias'],
      item: const TmdbItem(
        tmdbId: 77,
        mediaType: TmdbMediaType.movie,
        title: 'Renamed Title',
      ),
      matchedAt: 5,
    );
    final cache = TmdbCache(cacheDir: dir.path);
    cache.write(TmdbCacheType.detail, 'bound', {
      'id': 77,
      'title': 'Renamed Title',
      'genres': [
        {'name': 'Bound genre'},
      ],
    });
    final service = TmdbService(config: () => const TmdbConfig(), cache: cache);
    addTearDown(service.close);
    final provider = ViewingReportMetadata(database: db, tmdbService: service);
    expect(provider.forRecords([record(title: 'Renamed Title')])[1]?.genres, [
      'Bound genre',
    ]);
    expect(provider.forRecords([record(title: 'Alias')])[1]?.genres, [
      'Bound genre',
    ]);
    expect(
      provider.forRecords([record(title: 'Original Name [HD]')])[1]?.genres,
      ['Bound genre'],
    );
    expect(provider.forRecords([record(title: 'Unrelated')]), isEmpty);
    expect(
      provider.forRecords([record(source: 'local|B', title: 'Renamed Title')]),
      isEmpty,
    );
    final differentVod = PlaybackHistory(
      id: 2,
      sourceKey: 'local|A',
      siteKey: 's',
      vodId: 'different',
      vodName: 'Renamed Title',
      flag: '',
      episodeName: '',
      episodeId: '',
      positionMs: 0,
      durationMs: 0,
      updatedAt: 0,
    );
    expect(provider.forRecords([differentVod]), isEmpty);
  });

  test(
    'cached production country keeps localized name before ISO fallback',
    () async {
      final dir = await Directory.systemTemp.createTemp('viewing-country');
      addTearDown(() => dir.delete(recursive: true));
      final db = AppDatabase.inMemory();
      addTearDown(db.dispose);
      final cache = TmdbCache(cacheDir: dir.path);
      cache.write(TmdbCacheType.detail, 'country', {
        'id': 77,
        'title': 'Title',
        'production_countries': [
          {'name': '中国', 'iso_3166_1': 'CN'},
          {'iso_3166_1': 'ZZ'},
        ],
      });
      final service = TmdbService(
        config: () => const TmdbConfig(),
        cache: cache,
      );
      addTearDown(service.close);
      expect(
        ViewingReportMetadata(
          database: db,
          tmdbService: service,
        ).forRecords([record(tmdbId: 77, type: 'movie')])[1]?.areas,
        ['中国', 'ZZ'],
      );
    },
  );

  test('CJK whitespace splits names but Latin full names remain intact', () {
    final db = AppDatabase.inMemory();
    addTearDown(db.dispose);
    final provider = ViewingReportMetadata(database: db);
    provider.capture(
      sourceKey: 'local|A',
      siteKey: 's',
      vod: Vod(
        vodId: 'v',
        vodName: 'Title',
        vodActor: '张三 李四｜王五',
        vodDirector: 'Christopher Nolan / 陈导 李导',
      ),
    );
    final result = provider.forRecords([record()])[1]!;
    expect(result.actors, ['张三', '李四', '王五']);
    expect(result.directors, ['Christopher Nolan', '陈导', '李导']);
  });

  test('legacy empty source records never consult snapshots or TMDB', () async {
    final dir = await Directory.systemTemp.createTemp('viewing-legacy');
    addTearDown(() => dir.delete(recursive: true));
    final db = AppDatabase.inMemory();
    addTearDown(db.dispose);
    final cache = TmdbCache(cacheDir: dir.path);
    cache.write(TmdbCacheType.detail, 'legacy', {
      'id': 77,
      'title': 'Title',
      'genres': [
        {'name': 'Drama'},
      ],
    });
    final service = TmdbService(config: () => const TmdbConfig(), cache: cache);
    addTearDown(service.close);
    final records = [record(source: '', tmdbId: 77, type: 'movie')];
    expect(
      ViewingReportMetadata(
        database: db,
        tmdbService: service,
      ).forRecords(records),
      isEmpty,
    );
    expect(records, hasLength(1));
    expect(records.single.sourceKey, '');
  });

  test(
    'source snapshots isolate same site/vod by source and title and fill only',
    () {
      final db = AppDatabase.inMemory();
      addTearDown(db.dispose);
      final provider = ViewingReportMetadata(database: db);
      provider.capture(
        sourceKey: 'local|A',
        siteKey: 's',
        vod: Vod(
          vodId: 'v',
          vodName: 'Title',
          vodActor: 'A / A, B',
          vodDirector: 'D',
          vodArea: 'JP',
          extra: {'vod_class': 'Drama'},
        ),
      );
      provider.capture(
        sourceKey: 'local|B',
        siteKey: 's',
        vod: Vod(vodId: 'v', vodName: 'Title', vodActor: 'Other'),
      );
      provider.capture(
        sourceKey: 'local|A',
        siteKey: 's',
        vod: Vod(vodId: 'v', vodName: 'Title', vodPic: 'poster'),
      );
      final result = provider.forRecords([
        record(),
        record(id: 2, source: 'local|B'),
        record(id: 3, title: 'Wrong'),
        record(id: 4, source: ''),
      ]);
      expect(result[1]?.actors, ['A', 'B']);
      expect(result[1]?.directors, ['D']);
      expect(result[1]?.genres, ['Drama']);
      expect(result[1]?.mediaType, '');
      expect(result[2]?.actors, ['Other']);
      expect(result.containsKey(3), isFalse);
      expect(result.containsKey(4), isFalse);
      expect(db.historyCount(), 0);
    },
  );

  test('old schema10 reopens without changing historical rows', () async {
    final dir = await Directory.systemTemp.createTemp('viewing-migration');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/db.sqlite';
    final db = AppDatabase.open(path).database!;
    db.upsertHistory(
      sourceKey: 'local|A',
      siteKey: 's',
      vodId: 'v',
      vodName: 'Title',
      flag: 'f',
      episodeName: 'e',
      episodeId: 'e',
      positionMs: 123,
      durationMs: 456,
      updatedAt: 100,
    );
    final original = db.recentHistory().single;
    db.dispose();
    final old = sqlite3.open(path);
    old.execute('DROP TABLE viewing_metadata;');
    old.execute("UPDATE meta SET value='10' WHERE key='schema_version';");
    old.close();
    var reopened = AppDatabase.open(path).database!;
    expect(reopened.schemaVersionValue, '11');
    ViewingReportMetadata(database: reopened).capture(
      sourceKey: 'local|A',
      siteKey: 's',
      vod: Vod(vodId: 'v', vodName: 'Title', vodArea: 'Japan'),
    );
    reopened.dispose();
    reopened = AppDatabase.open(path).database!;
    addTearDown(reopened.dispose);
    expect(
      ViewingReportMetadata(database: reopened)
          .forRecords(reopened.recentHistory())[original.id]
          ?.areas,
      ['Japan'],
    );
    final after = reopened.recentHistory().single;
    expect(
      [
        after.id,
        after.sourceKey,
        after.positionMs,
        after.durationMs,
        after.updatedAt,
      ],
      [original.id, 'local|A', 123, 456, 100],
    );
  });

  test(
    'offline cache fallback survives missing credentials and never requests',
    () async {
      final dir = await Directory.systemTemp.createTemp('viewing-cache');
      addTearDown(() => dir.delete(recursive: true));
      final cache = TmdbCache(cacheDir: dir.path);
      var count = 0;
      final service = TmdbService(
        config: () => const TmdbConfig(),
        cache: cache,
        client: MockClient((_) async {
          count++;
          return http.Response('{}', 500);
        }),
      );
      addTearDown(service.close);
      cache.write(TmdbCacheType.detail, 'legacy-with-old-credentials', {
        'id': 77,
        'title': 'Translated title',
        'genres': [
          {'name': 'TMDB genre'},
        ],
        'origin_country': ['JP'],
        'credits': {
          'cast': [
            {'name': 'Cache actor'},
          ],
          'crew': [
            {'name': 'Director', 'job': 'Director'},
            {'name': 'Writer', 'job': 'Writer'},
          ],
        },
        'created_by': [
          {'name': 'Creator is not director'},
        ],
      });
      final db = AppDatabase.inMemory();
      addTearDown(db.dispose);
      final provider = ViewingReportMetadata(
        database: db,
        tmdbService: service,
      );
      provider.capture(
        sourceKey: 'local|A',
        siteKey: 's',
        vod: Vod(vodId: 'v', vodName: 'Title', vodActor: 'Source actor'),
      );
      final result = provider.forRecords([
        record(tmdbId: 77, type: 'movie'),
        record(id: 2, source: 'local|B', tmdbId: 77, type: 'tv'),
      ]);
      expect(result[1]?.actors, ['Source actor']);
      expect(result[1]?.genres, ['TMDB genre']);
      expect(result[1]?.directors, ['Director']);
      expect(result[1]?.areas, ['JP']);
      expect(result[2]?.genres ?? [], isEmpty);
      expect(count, 0);
      expect(service.requestCount, 0);
      File(cache.filePath(TmdbCacheType.detail, 'legacy-with-old-credentials')!)
          .writeAsStringSync('{bad');
      expect(
        provider.forRecords([record(tmdbId: 77, type: 'movie')])[1]?.genres ??
            [],
        isEmpty,
      );
    },
  );

  test('no database and invalid/mixed metadata safely remain unknown', () {
    expect(ViewingReportMetadata().forRecords([record()]), isEmpty);
    final db = AppDatabase.inMemory();
    final provider = ViewingReportMetadata(database: db);
    provider.capture(
      sourceKey: 'local|A',
      siteKey: 's',
      vod: Vod(
        vodId: 'v',
        vodName: 'Title',
        vodActor: '未知',
        vodDirector: 'N/A',
        extra: {
          'credit': 'actor / director',
          'media_type': 'nonsense',
          'type_name': '未知',
        },
      ),
    );
    expect(provider.forRecords([record()]), isEmpty);
    db.dispose();
    expect(provider.forRecords([record()]), isEmpty);
  });

  test('schema 11 adds isolated viewing snapshots', () {
    final db = AppDatabase.inMemory();
    addTearDown(db.dispose);
    expect(db.schemaVersionValue, '11');
    expect(db.count('viewing_metadata'), 0);
  });
}
