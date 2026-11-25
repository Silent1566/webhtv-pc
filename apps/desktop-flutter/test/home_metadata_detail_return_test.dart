import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/home_feed.dart';
import 'package:webhtv_pc/core/tmdb_config.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/detail_rating_service.dart';
import 'package:webhtv_pc/services/search_suggest_service.dart';
import 'package:webhtv_pc/services/storage.dart';
import 'package:webhtv_pc/services/tmdb_service.dart';
import 'package:webhtv_pc/services/tmdb_stores.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/state/detail_recommendation_state.dart';
import 'package:webhtv_pc/ui/browse_pages.dart';
import 'package:webhtv_pc/ui/home_backdrop.dart';
import 'package:webhtv_pc/ui/home_hero.dart';
import 'package:webhtv_pc/ui/home_page.dart';
import 'package:webhtv_pc/ui/poster_image.dart';
import 'package:webhtv_pc/ui/theme.dart';
import 'package:webhtv_pc/ui/tmdb_detail_view.dart';

import 'support/detail_test_seams.dart';
import 'support/home_hd_art_fixture.dart';

const _config = TmdbConfig(
  apiKey: 'fixture-key',
  apiBase: 'https://tmdb.fixture/3',
  imageBase: 'https://images.fixture/t/p/w342',
  backdropBase: 'https://images.fixture/t/p/w1280',
);
const _oldBackdrop = 'https://images.fixture/t/p/w1280/old-backdrop.jpg';
const _newBackdrop = 'https://images.fixture/t/p/w1280/new-backdrop.jpg';
const _title = '回归样片';

class _TransportState extends AppState {
  _TransportState(Directory dir, TmdbService metadata, http.Client transport)
    : super(
        paths: AppPaths.resolve(
          overrides: {
            'config': dir.path,
            'data': dir.path,
            'cache': '${dir.path}/cache',
            'state': '${dir.path}/logs',
          },
        ),
        log: MemoryOnlyLogService(),
        httpClient: transport,
        tmdbService: metadata,
        searchSuggestService: SearchSuggestService(client: transport),
        externalPlayerDetector: () => [],
        warmAutoRoutes: false,
      ) {
    recommendations = DetailRecommendationDependencies.fromServices(
      service: metadata,
      doubanClient: transport,
    );
    ratings = DetailRatingService.fromServices(client: transport);
  }

  late final DetailRecommendationDependencies recommendations;
  late final DetailRatingService ratings;

  @override
  DetailRecommendationDependencies get recommendationDependencies =>
      recommendations;

  @override
  DetailRatingService get detailRatingService => ratings;

  @override
  void dispose() {
    recommendations.close();
    ratings.close();
    super.dispose();
  }
}

class _RouteObserver extends NavigatorObserver {
  final detailPushed = Completer<void>();

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute != null && !detailPushed.isCompleted) {
      detailPushed.complete();
    }
  }
}

Map<String, Object?> _historySnapshot(PlaybackHistory row) => {
  'source': row.sourceKey,
  'site': row.siteKey,
  'vod': row.vodId,
  'flag': row.flag,
  'episode': row.episodeId,
  'episodeName': row.episodeName,
  'position': row.positionMs,
  'duration': row.durationMs,
  'updatedAt': row.updatedAt,
  'tmdbId': row.tmdbId,
  'mediaType': row.mediaType,
  'poster': row.vodPic,
};

void main() {
  testWidgets(
    'real history detail return refreshes retained home metadata without identity changes',
    (tester) async {
      final dir = Directory.systemTemp.createTempSync('home-detail-return');
      var newest = false;
      var detailRequests = 0;
      http.Response json(Object body) => http.Response(
        jsonEncode(body),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
      final transport = MockClient((request) async {
        if (request.url.host == 'source.fixture') {
          return json({
            'list': [
              {
                'vod_id': 'vod42',
                'vod_name': _title,
                'vod_year': '2026',
                'vod_pic': 'https://source.fixture/poster.jpg',
                'vod_play_from': '原线路',
                'vod_play_url': r'第2集$https://media.fixture/episode2.m3u8',
              },
            ],
          });
        }
        return json({'results': [], 'data': [], 'items': [], 'subjects': []});
      });
      final metadata = TmdbService(
        config: () => _config,
        client: MockClient((request) async {
          if (request.url.path.endsWith('/tv/42')) {
            detailRequests++;
            return json({
              'id': 42,
              'name': _title,
              'overview': newest ? '详情更新后的简介' : '首页首次解析的旧简介',
              'poster_path': '/poster.jpg',
              'backdrop_path': newest
                  ? '/new-backdrop.jpg'
                  : '/old-backdrop.jpg',
              'first_air_date': '2026-01-01',
              'seasons': [
                {'season_number': 1, 'episode_count': 2},
              ],
            });
          }
          return json({'results': [], 'episodes': []});
        }),
      );
      final state = _TransportState(dir, metadata, transport);
      addTearDown(() {
        state.dispose();
        transport.close();
        dir.deleteSync(recursive: true);
      });
      await tester.runAsync(() async {
        await bootstrapWithoutExternalMeta(state);
        expect(await state.saveTmdbConfig(_config), isTrue);
        await state.importConfig(
          jsonEncode({
            'sites': [
              {
                'key': 'original-site',
                'name': '影视站',
                'type': 1,
                'api': 'https://source.fixture/api.php/provide/vod',
              },
            ],
          }),
        );
        state.database!.upsertHistory(
          sourceKey: state.activeSourceKey,
          siteKey: 'original-site',
          vodId: 'vod42',
          vodName: _title,
          vodPic: 'https://source.fixture/poster.jpg',
          flag: '原线路',
          episodeName: '第2集',
          episodeId: 'https://media.fixture/episode2.m3u8',
          positionMs: 123456,
          durationMs: 1200000,
          updatedAt: 1700000000123,
          tmdbId: 42,
          mediaType: 'tv',
        );
        DatabaseTmdbMatchStore(
          database: state.database!,
          configId: state.tmdbConfigId,
        ).putAuto(
          siteKey: 'original-site',
          vodId: 'vod42',
          sourceTitle: _title,
          item: const TmdbItem(
            tmdbId: 42,
            mediaType: TmdbMediaType.tv,
            title: _title,
          ),
          matchedAt: 1700000000000,
        );
      });
      final before = _historySnapshot(
        state.recentHistory(sourceKey: '').single,
      );
      final observer = _RouteObserver();
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.dark),
          navigatorObservers: [observer],
          home: Scaffold(
            body: ListenableBuilder(
              listenable: state,
              builder: (_, _) => HomePage(
              heroImageLoader: loadHdHeroFixture,
                state: state,
                onOpenBrowse: () {},
                onOpenHistory: () {},
                onOpenFollowing: () {},
                onImportConfig: () {},
                onSearch: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      HomeItem hero({bool offstage = false}) => tester
          .widget<HomeHero>(find.byType(HomeHero, skipOffstage: !offstage))
          .items
          .first;
      expect(hero().backdrop, _oldBackdrop);
      expect(hero().overview, '首页首次解析的旧简介');
      final homeState = tester.state(find.byType(HomePage));
      final homeElement = tester.element(find.byType(HomePage));
      newest = true;
      final loaded = Completer<void>();
      void onTmdbChanged() {
        if (state.tmdb.detail?['overview'] == '详情更新后的简介' &&
            !loaded.isCompleted) {
          loaded.complete();
        }
      }

      state.tmdb.addListener(onTmdbChanged);
      addTearDown(() => state.tmdb.removeListener(onTmdbChanged));
      await tester.tap(find.byKey(const ValueKey('home-hero-secondary')));
      await tester.runAsync(
        () => observer.detailPushed.future.timeout(const Duration(seconds: 5)),
      );
      await tester.pump();
      await tester.runAsync(
        () => loaded.future.timeout(const Duration(seconds: 5)),
      );
      await tester.pumpAndSettle();
      expect(find.byType(DetailPage), findsOneWidget);
      final page = tester.widget<DetailPage>(find.byType(DetailPage));
      expect(page.historyFlag, '原线路');
      expect(page.historyEpisodeId, 'https://media.fixture/episode2.m3u8');
      expect(
        tester
            .widget<TmdbDetailHeader>(find.byType(TmdbDetailHeader))
            .data
            .backdropUrls,
        [_newBackdrop],
      );
      expect(state.tmdb.detailData!.overview, '详情更新后的简介');
      expect(
        hero(offstage: true).backdrop,
        _oldBackdrop,
        reason: '被覆盖的首页仍持有首次解析，不能由手工重建替代返回失效',
      );
      expect(
        _historySnapshot(state.recentHistory(sourceKey: '').single),
        before,
      );
      final requestsBeforeReturn = detailRequests;
      Navigator.of(tester.element(find.byType(DetailPage))).pop();
      await tester.pumpAndSettle();
      expect(find.byType(DetailPage), findsNothing);
      expect(tester.state(find.byType(HomePage)), same(homeState));
      expect(tester.element(find.byType(HomePage)), same(homeElement));
      expect(hero().backdrop, _newBackdrop);
      expect(hero().overview, '详情更新后的简介');
      expect(find.text('首页首次解析的旧简介'), findsNothing);
      expect(find.text('详情更新后的简介'), findsOneWidget);
      final background = find.descendant(
        of: find.byType(HomeBackdrop),
        matching: find.byType(PosterImage),
      );
      expect(tester.widget<PosterImage>(background).url, _newBackdrop);
      expect(detailRequests, greaterThan(requestsBeforeReturn));
      expect(
        _historySnapshot(state.recentHistory(sourceKey: '').single),
        before,
      );
      expect(tester.takeException(), isNull);
      state.tmdb.removeListener(onTmdbChanged);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
