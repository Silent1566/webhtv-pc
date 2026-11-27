import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/detail_ratings.dart';
import 'package:webhtv_pc/core/meta_pipeline.dart';
import 'package:webhtv_pc/core/meta_source.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/tmdb_config.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/detail_rating_service.dart';
import 'package:webhtv_pc/services/external_meta_service.dart';
import 'package:webhtv_pc/services/imdb_rating_service.dart';
import 'package:webhtv_pc/services/site_service.dart';
import 'package:webhtv_pc/services/tmdb_enrichment_service.dart';
import 'package:webhtv_pc/services/tmdb_identity_service.dart';
import 'package:webhtv_pc/services/tmdb_season_service.dart';
import 'package:webhtv_pc/services/tmdb_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/state/tmdb_state.dart';
import 'package:webhtv_pc/ui/browse_pages.dart';
import 'package:webhtv_pc/ui/common.dart';
import 'package:webhtv_pc/ui/theme.dart';

import 'support/detail_test_seams.dart';
import 'support/temp_dirs.dart';
import 'support/test_fonts.dart';

const _settings = TmdbConfig(apiKey: 'fixture');
const _playUrl =
    '第1集\$https://fixture.test/1.mp4#第2集\$https://fixture.test/2.mp4';

final _vodA = Vod(
  vodId: 'source-a',
  vodName: '甲作品',
  vodContent: '甲的简介。',
  vodPlayFrom: '高清线路',
  vodPlayUrl: _playUrl,
);

final _vodB = Vod(
  vodId: 'source-b',
  vodName: '乙作品',
  vodContent: '乙的简介。',
  vodPlayFrom: '高清线路',
  vodPlayUrl: _playUrl,
);

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

/// 真实 [ImdbRatingService] + 受控传输：按 imdb_id 给分，并记录实际查过的编号。
http.Client _imdbClient(Map<String, String> ratings, List<String> requested) =>
    MockClient((request) async {
      final body = request.body;
      final id =
          RegExp(r'tt\d{7,}').firstMatch(body)?.group(0) ??
          RegExp(r'tt\d{7,}').firstMatch(request.url.toString())?.group(0) ??
          '';
      requested.add(id);
      final value = double.tryParse(ratings[id] ?? '');
      return _json({
        'data': {
          'title': value == null
              ? null
              : {
                  'ratingsSummary': {
                    'aggregateRating': value,
                    'voteCount': 12345,
                  },
                },
        },
      });
    });

Map<String, Object?> _detailFixture(
  int id,
  String title,
  String imdbId,
  double voteAverage,
) => {
  'id': id,
  'title': title,
  'original_title': '$title Original',
  'overview': '$title 的 TMDB 简介。',
  'release_date': '2024-01-01',
  'vote_average': voteAverage,
  'runtime': 108,
  // 真实 TMDB 详情带 append=external_ids；IMDb 分只能按它换编号。
  'external_ids': {'imdb_id': imdbId},
  'translations': {
    'translations': [
      {
        'iso_639_1': 'en',
        'data': {'title': title},
      },
    ],
  },
};

/// 受控 TMDB：按标题命中详情，详情响应里的 external_ids 决定 IMDb 编号。
http.Client _tmdbClient(Map<int, Map<String, Object?>> details) =>
    MockClient((request) async {
      final path = request.url.path;
      if (path.endsWith('/search/multi')) {
        final query = request.url.queryParameters['query'] ?? '';
        final id = details.entries
            .firstWhere(
              (entry) => query.contains(entry.value['title']! as String),
              orElse: () => details.entries.first,
            )
            .key;
        return _json({
          'results': [
            {
              'id': id,
              'media_type': 'movie',
              'title': details[id]!['title'],
              'release_date': '2024-01-01',
            },
          ],
        });
      }
      if (path.endsWith('/videos')) return _json({'results': <Object>[]});
      final matched = RegExp(r'/(?:movie|tv)/(\d+)').firstMatch(path);
      final id = int.tryParse(matched?.group(1) ?? '') ?? details.keys.first;
      return _json(details[id] ?? details.values.first);
    });

/// 旧链路（DetailRatingService）的受控实现：不发网络，只给固定值。
class _ScriptedRatings implements DetailRatingService {
  _ScriptedRatings(this.values);

  final DetailRatingValues values;
  int calls = 0;

  @override
  Future<DetailRatingValues> fetch(
    DetailRatingRequest request, {
    required String omdbApiKey,
  }) async {
    calls++;
    return values;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FixtureState extends AppState {
  _FixtureState({
    required Directory dir,
    required this._tmdbState,
    required TmdbService tmdbService,
    required this._legacyRatings,
    ExternalMetaService? external,
  }) : _tmdbService = tmdbService,
       super(
         paths: AppPaths.resolve(
           overrides: {
             'config': dir.path,
             'data': dir.path,
             'cache': dir.path,
             'state': dir.path,
           },
         ),
         log: MemoryOnlyLogService(),
         tmdbService: tmdbService,
         externalMetaService: external,
       );

  final TmdbState _tmdbState;
  final TmdbService _tmdbService;
  final DetailRatingService _legacyRatings;

  @override
  TmdbConfig get tmdbConfig => _settings;

  @override
  TmdbState get tmdb => _tmdbState;

  @override
  TmdbService get tmdbService => _tmdbService;

  @override
  DetailRatingService get detailRatingService => _legacyRatings;

  @override
  Future<void> loadDetail(
    Vod vod, {
    SiteService? serviceOverride,
    Site? siteOverride,
  }) async {}
}

class _Harness {
  _Harness({
    required this.state,
    required this.tmdb,
    required this.requests,
    required this.ratings,
  });

  final _FixtureState state;
  final TmdbState tmdb;
  final List<String> requests;
  final _ScriptedRatings ratings;
}

/// 挂载真实 DetailPage：真实 AppState/评分管线 + 受控 HTTP。
Future<_Harness> _pumpDetail(
  WidgetTester tester, {
  required Vod vod,
  required Vod loadFor,
  required http.Client tmdbClient,
  required _ScriptedRatings ratings,
  required Map<String, String> imdbRatings,
}) async {
  tester.view.physicalSize = const Size(1280, 950);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final dir = Directory.systemTemp.createTempSync('imdb-detail');
  final requests = <String>[];
  final imdb = ImdbRatingService(
    // 零存活期：重新打开 IMDb 源时必须真的再查一次（否则断言看到的是缓存）。
    cacheTtl: Duration.zero,
    client: _imdbClient(imdbRatings, requests),
  );
  final service = TmdbService(config: () => _settings, client: tmdbClient);
  final tmdb = TmdbState(
    config: () => _settings,
    service: service,
    identityService: TmdbIdentityService(
      config: () => _settings,
      service: service,
      store: InMemoryTmdbMatchStore(),
    ),
    seasonService: TmdbSeasonService(store: InMemoryTmdbSeasonStore()),
    enrichmentService: TmdbEnrichmentService(
      service: service,
      config: () => _settings,
    ),
  );
  late _FixtureState state;
  final external = ExternalMetaService(
    enabled: () => state.externalMetaEnabled,
    pipeline: () => state.metaPipeline,
    imdbRating: (imdbId) => imdb.byImdbId(imdbId),
  );
  state = _FixtureState(
    dir: dir,
    tmdbState: tmdb,
    tmdbService: service,
    legacyRatings: ratings,
    external: external,
  );
  addTearDown(() {
    state.dispose();
    tmdb.dispose();
    service.close();
    imdb.close();
    deleteTempDirBestEffortSync(dir);
  });

  await tester.runAsync(state.bootstrap);
  await tmdb.loadForVod(loadFor, siteKey: 'current', siteName: '当前站源');
  state.seedDetailForTest(vod: vod);

  final theme = buildAppTheme(Brightness.dark);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme.copyWith(
        textTheme: theme.textTheme.apply(fontFamily: 'FixtureCJK'),
      ),
      home: DetailPage(state: state, vod: vod),
    ),
  );
  await _settleIo(tester);
  return _Harness(
    state: state,
    tmdb: tmdb,
    requests: requests,
    ratings: ratings,
  );
}

Future<void> _settleIo(WidgetTester tester) async {
  await tester.runAsync(() async {
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await tester.pump();
    }
  });
  await tester.pumpAndSettle();
}

List<String> _ratingLabels(WidgetTester tester) => tester
    .widgetList<TagChip>(
      find.descendant(
        of: find.byKey(const ValueKey('detail-rating-tags')),
        matching: find.byType(TagChip),
      ),
    )
    .map((chip) => chip.label)
    .toList();

Finder _imdbInRatingRow() => find.descendant(
  of: find.byKey(const ValueKey('detail-rating-tags')),
  matching: find.textContaining('IMDb'),
);

void main() {
  setUpAll(() async {
    await loadFixtureFonts();
  });

  testWidgets(
    'pipeline IMDb score replaces the legacy duplicate in place and follows the source switch',
    (tester) async {
      final harness = await _pumpDetail(
        tester,
        vod: _vodA,
        loadFor: _vodA,
        tmdbClient: _tmdbClient({
          21: _detailFixture(21, _vodA.vodName, 'tt1234567', 8.4),
        }),
        ratings: _ScriptedRatings(
          const DetailRatingValues(
            doubanRating: 8.8,
            imdb: '8.4',
            rottenTomatoes: '91%',
            metacritic: '82/100',
          ),
        ),
        imdbRatings: const {'tt1234567': '8.1'},
      );

      expect(harness.ratings.calls, greaterThan(0), reason: '旧链路应确实给出过 IMDb 分');
      expect(harness.requests, ['tt1234567']);
      // 同一个 IMDb 只出现一次，且用的是管线分；站名顺序保持固定。
      expect(_ratingLabels(tester), [
        'TMDB 8.4',
        '豆瓣 8.8',
        'IMDb 8.1',
        '烂番茄 91%',
        'Metacritic 82/100',
      ]);
      expect(find.text('IMDb 8.4'), findsNothing);
      expect(find.text('IMDb 8.1'), findsOneWidget);
      expect(harness.state.imdbRatingEnabled, isTrue);
      expect(
        tester.getBottomLeft(find.text('IMDb 8.1')).dy,
        lessThan(
          tester
              .getTopLeft(find.byKey(const ValueKey('tmdb-detail-hero-overview')))
              .dy,
        ),
        reason: '评分行在简介上方',
      );

      await tester.runAsync(
        () => harness.state.setMetaPipeline(
          harness.state.metaPipeline.toggleSource(
            MetaField.rating,
            MetaSourceKind.imdb,
          ),
        ),
      );
      await _settleIo(tester);
      expect(harness.state.imdbRatingEnabled, isFalse);
      expect(_imdbInRatingRow(), findsNothing, reason: '停用 IMDb 源后旧链路的分也不得残留');
      expect(_ratingLabels(tester), [
        'TMDB 8.4',
        '豆瓣 8.8',
        '烂番茄 91%',
        'Metacritic 82/100',
      ]);
      expect(harness.requests, ['tt1234567'], reason: '停用后不得再发 IMDb 请求');

      await tester.runAsync(
        () => harness.state.setMetaPipeline(
          harness.state.metaPipeline.toggleSource(
            MetaField.rating,
            MetaSourceKind.imdb,
          ),
        ),
      );
      await _settleIo(tester);
      expect(_ratingLabels(tester), [
        'TMDB 8.4',
        '豆瓣 8.8',
        'IMDb 8.1',
        '烂番茄 91%',
        'Metacritic 82/100',
      ]);
      expect(harness.requests, ['tt1234567', 'tt1234567']);
      expect(harness.state.imdbRatingEnabled, isTrue);

      // 总开关关闭：IMDb 不请求、不显示（旧链路的分一并隐藏）。
      await tester.runAsync(
        () => harness.state.setExternalMetaEnabled(false),
      );
      await _settleIo(tester);
      expect(_imdbInRatingRow(), findsNothing);
      expect(_ratingLabels(tester), [
        'TMDB 8.4',
        '豆瓣 8.8',
        '烂番茄 91%',
        'Metacritic 82/100',
      ]);
      expect(harness.requests.length, 2);
      expect(harness.state.imdbRatingEnabled, isFalse);

      await tester.runAsync(() => harness.state.setExternalMetaEnabled(true));
      await _settleIo(tester);
      expect(find.text('IMDb 8.1'), findsOneWidget);
      expect(harness.requests, ['tt1234567', 'tt1234567', 'tt1234567']);
      expect(harness.state.imdbRatingEnabled, isTrue);
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );

  testWidgets(
    'late TMDB external_ids triggers an IMDb lookup for this work only',
    (tester) async {
      final harness = await _pumpDetail(
        tester,
        vod: _vodB,
        // 先让全局 TMDB 状态停在上一部作品上：本页首帧不得借用它的 imdb_id。
        loadFor: _vodA,
        tmdbClient: _tmdbClient({
          21: _detailFixture(21, _vodA.vodName, 'tt0000001', 8.4),
          22: _detailFixture(22, _vodB.vodName, 'tt0000002', 7.9),
        }),
        ratings: _ScriptedRatings(DetailRatingValues.empty),
        imdbRatings: const {'tt0000001': '8.1', 'tt0000002': '7.3'},
      );

      expect(harness.tmdb.belongsTo(_vodA.vodId), isTrue);
      expect(find.byKey(const ValueKey('detail-rating-tags')), findsNothing);
      expect(
        harness.requests,
        isEmpty,
        reason: '上一部作品的 tt0000001 不得被本页评分查询使用',
      );

      await harness.tmdb.loadForVod(
        _vodB,
        siteKey: 'current',
        siteName: '当前站源',
      );
      await _settleIo(tester);

      expect(harness.tmdb.belongsTo(_vodB.vodId), isTrue);
      expect(harness.requests, ['tt0000002']);
      expect(find.text('IMDb 7.3'), findsOneWidget);
      expect(find.text('IMDb 8.1'), findsNothing);
      expect(_ratingLabels(tester), ['TMDB 7.9', 'IMDb 7.3']);
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );
}
