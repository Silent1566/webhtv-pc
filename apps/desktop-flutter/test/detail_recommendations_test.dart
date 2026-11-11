import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/detail_recommendation.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/following.dart';
import 'package:webhtv_pc/core/tmdb_media.dart';
import 'package:webhtv_pc/core/tmdb_config.dart';
import 'package:webhtv_pc/core/tmdb_detail_model.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/recommendation_feedback_store.dart';
import 'package:webhtv_pc/services/tmdb_service.dart';
import 'package:webhtv_pc/services/site_service.dart';
import 'package:webhtv_pc/services/following_air_time_service.dart';
import 'package:webhtv_pc/services/tmdb_enrichment_service.dart';
import 'support/visual_test_fonts.dart';
import 'package:webhtv_pc/services/tmdb_identity_service.dart';
import 'package:webhtv_pc/services/tmdb_recommendation_service.dart';
import 'package:webhtv_pc/services/tmdb_season_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/state/detail_recommendation_state.dart';
import 'package:webhtv_pc/state/tmdb_state.dart';
import 'package:webhtv_pc/ui/browse_pages.dart';
import 'package:webhtv_pc/ui/detail_recommendations.dart';
import 'package:webhtv_pc/ui/search_page.dart';
import 'package:webhtv_pc/ui/tmdb_detail_page.dart';
import 'package:webhtv_pc/ui/tmdb_detail_view.dart';
import 'package:webhtv_pc/ui/theme.dart';
import 'package:webhtv_pc/ui/following_calendar_page.dart';

const item = TmdbItem(tmdbId: 2, mediaType: TmdbMediaType.movie, title: '推荐作品');
DetailRecommendationDependencies deps({
  bool titleOnly = false,
  RecommendationLoader? loader,
}) => DetailRecommendationDependencies(
  feedback: RecommendationFeedbackStore(),
  loaders: {
    for (final row in RecommendationRow.values)
      row:
          loader ??
          (r) async => RecommendationPage(
            items: [
              RecommendationEntry(
                item: titleOnly
                    ? const TmdbItem(
                        tmdbId: 0,
                        mediaType: TmdbMediaType.movie,
                        title: '豆瓣作品',
                      )
                    : item,
                source: row == RecommendationRow.douban
                    ? RecommendationSource.douban
                    : RecommendationSource.tmdb,
                reason: '根据观看历史',
                doubanRating: 8.7,
              ),
            ],
            nextOffset: 12,
            hasMore: true,
          ),
  },
);

class SourceState extends AppState {
  SourceState(
    Directory dir,
    this.dependencies, {
    this.site,
    this.tmdbFixture,
    this.tmdbState,
    this.overrideDetail = true,
  }) : super(
         paths: AppPaths.resolve(
           overrides: {
             'config': dir.path,
             'data': dir.path,
             'cache': dir.path,
             'state': dir.path,
           },
         ),
         log: LogService(),
       );
  final TmdbService? tmdbFixture;
  @override
  TmdbService get tmdbService => tmdbFixture ?? super.tmdbService;

  /// 注入的 TMDB 状态（null = 用 AppState 自己那份）。
  ///
  /// 为什么需要：AppState.tmdb 用私有的 _tmdbService 字段装配，覆写 [tmdbService]
  /// 的 getter 影响不到它；要「已匹配 + 已聚合」的前置就得整份注入（与
  /// nav_source_detail_ui_test 同一做法）。
  final TmdbState? tmdbState;
  @override
  TmdbState get tmdb => tmdbState ?? super.tmdb;

  /// 是否屏蔽真实详情加载（既有用例只要页面骨架，不需要发请求）。
  final bool overrideDetail;

  final Site? site;
  SiteService? detailService;
  @override
  Site? get selectedSite => site;
  final DetailRecommendationDependencies dependencies;
  @override
  DetailRecommendationDependencies get recommendationDependencies =>
      dependencies;

  /// 站源搜索调用记录：[站点 key, 关键词, 是否快搜]。
  final List<(String, String, bool)> searchCalls = [];

  /// 站源搜索结果夹具（null = 空结果）。
  Future<SiteResult?> Function(Site site, String keyword)? searchFixture;

  @override
  Future<SiteResult?> search(
    Site site, {
    required String keyword,
    int page = 1,
    bool quick = false,
  }) async {
    searchCalls.add((site.key, keyword, quick));
    final fixture = searchFixture;
    if (fixture != null) return fixture(site, keyword);
    return const SiteResult();
  }

  @override
  Future<void> loadDetail(
    Vod vod, {
    SiteService? serviceOverride,
    Site? siteOverride,
  }) async {
    if (overrideDetail) return;
    await super.loadDetail(
      vod,
      serviceOverride: serviceOverride ?? detailService,
      siteOverride: siteOverride,
    );
  }
}

class _Task6EmptyService implements SiteService {
  _Task6EmptyService({this.withIdentity = true});
  final bool withIdentity;

  @override
  Future<SiteCallResult<SiteResult>> detail(
    Site site,
    String vodId, {
    VodIdentityHint? identity,
  }) async => SiteCallResult(
    value: SiteResult(
      list: [
        Vod(
          vodId: vodId,
          vodName: '已知推荐剧',
          extra: withIdentity
              ? {'tmdb_id': 1399, 'media_type': 'tv'}
              : const {},
        ),
      ],
    ),
    latency: Duration.zero,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Task6EmptySourceState extends SourceState {
  _Task6EmptySourceState(
    super.dir,
    super.dependencies, {
    super.site,
    super.tmdbState,
  }) : super(overrideDetail: false);

  @override
  Future<void> loadDetail(
    Vod vod, {
    SiteService? serviceOverride,
    Site? siteOverride,
  }) => super.loadDetail(
    vod,
    serviceOverride: _Task6EmptyService(),
    siteOverride: siteOverride,
  );
}

class CalendarRecommendationState extends SourceState {
  CalendarRecommendationState(
    super.dir,
    super.dependencies, {
    super.tmdbFixture,
  });
  @override
  Future<TmdbItem?> followingTmdbItem(Following following) async =>
      const TmdbItem(
        tmdbId: 42,
        mediaType: TmdbMediaType.tv,
        title: 'CalendarShow',
      );
}

/// Task4 回退页夹具：TMDB 侧「搜到 → 详情 → 全季剧集」的一整套假响应。
///
/// 标题固定为 [title]：合成条目的名字就是它，匹配链按标题搜到同一部作品。
http.Client recommendationTmdbClient({String title = '导航剧'}) =>
    MockClient((request) async {
      final path = request.url.path;
      final Object body;
      if (path.endsWith('/search/multi')) {
        body = {
          'results': [
            {
              'id': 1399,
              'media_type': 'tv',
              'name': title,
              'first_air_date': '2024-01-01',
            },
          ],
        };
      } else if (path.endsWith('/tv/1399')) {
        body = {
          'id': 1399,
          'name': title,
          'seasons': [
            {'season_number': 1, 'episode_count': 2},
          ],
        };
      } else if (path.endsWith('/season/1')) {
        body = {
          'season_number': 1,
          'episodes': [
            {'episode_number': 1, 'name': 'E1', 'season_number': 1},
            {'episode_number': 2, 'name': 'E2', 'season_number': 1},
          ],
        };
      } else if (path.endsWith('/videos')) {
        body = {'results': <Object>[]};
      } else {
        return http.Response('{"status_code":404}', 404);
      }
      return http.Response(
        jsonEncode(body),
        200,
        headers: const {'content-type': 'application/json; charset=utf-8'},
      );
    });

TmdbState recommendationTmdbState(
  http.Client client, {
  TmdbConfig settings = const TmdbConfig(apiKey: 'fixture'),
  TmdbMatchStore? matchStore,
}) {
  TmdbConfig config() => settings;
  final service = TmdbService(config: config, client: client);
  return TmdbState(
    config: config,
    service: service,
    identityService: TmdbIdentityService(
      config: config,
      service: service,
      store: matchStore ?? InMemoryTmdbMatchStore(),
    ),
    seasonService: TmdbSeasonService(store: InMemoryTmdbSeasonStore()),
    enrichmentService: TmdbEnrichmentService(service: service, config: config),
  );
}

/// 导航源卡片的 key 前缀（合成条目 vodId 为空，前缀因此是 nav-）。
const _navCardPrefix = 'tmdb-episode-card-nav-';

Finder _navCards() => find.byWidgetPredicate(
  (widget) =>
      widget is OutlinedButton &&
      widget.key is ValueKey<String> &&
      (widget.key! as ValueKey<String>).value.startsWith(_navCardPrefix),
);

/// 只 pump 固定轮次：页面上可能有转圈动画，pumpAndSettle 会一直等下去。
Future<void> _pumpRounds(WidgetTester tester, {int rounds = 60}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
}

/// 让 finder 命中**且整块落在视口内**（只命中不算，卡片可能在视口外）。
Future<void> _revealInViewport(WidgetTester tester, Finder finder) async {
  final viewport = tester.view.physicalSize / tester.view.devicePixelRatio;
  for (var attempt = 0; attempt < 80; attempt++) {
    if (finder.evaluate().isNotEmpty) {
      final rect = tester.getRect(finder.first);
      if (rect.top >= 0 && rect.bottom <= viewport.height) return;
    }
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -200));
    await tester.pump();
  }
}

Site _currentSite() => Site(
  key: 'current',
  name: '当前站',
  type: 1,
  api: 'https://fixture.invalid/api.php/provide/vod',
);

void main() {
  setUpAll(loadVisualTestFonts);
  setUp(() {});
  Future<void> size(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets(
    'new bottom rows replace old wall after videos; feedback crosses rows',
    (tester) async {
      await size(tester);
      final dependencies = deps();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: TmdbDetailSections(
                data: TmdbDetailData.fromItem(item),
                recommendations: const [item],
                recommendationBottom: DetailRecommendations(
                  dependencies: dependencies,
                  current: const RecommendationSeed(title: '当前作品'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('个性推荐·豆瓣'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('tmdb-recommendation-wall')),
        findsNothing,
      );
      expect(
        tester.getTopLeft(find.text('猜你喜欢')).dy,
        lessThan(tester.getTopLeft(find.text('个性推荐·TMDB')).dy),
      );
      await tester.longPress(
        find.byKey(const ValueKey('recommendation-related-movie:2')),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('根据观看历史'), findsOneWidget);
      expect(find.textContaining('8.7'), findsNWidgets(2));
      await tester.tap(find.text('不感兴趣'));
      await tester.pumpAndSettle();
      expect(find.text('猜你喜欢'), findsNothing);
      expect(find.text('个性推荐·豆瓣'), findsNothing);
    },
  );
  testWidgets(
    'source page without TMDB match still shows searchable title-only Douban',
    (tester) async {
      await size(tester);
      final dir = Directory.systemTemp.createTempSync('task3-source');
      final state = SourceState(dir, deps(titleOnly: true));
      addTearDown(() => dir.deleteSync(recursive: true));
      addTearDown(state.dispose);
      await tester.runAsync(state.bootstrap);
      await tester.pumpWidget(
        MaterialApp(
          home: DetailPage(
            state: state,
            vod: Vod(vodId: '1', vodName: '当前作品'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView).first, const Offset(0, -2500));
      await tester.pumpAndSettle();
      expect(find.text('个性推荐·豆瓣'), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const ValueKey('recommendation-douban-title:豆瓣作品')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('recommendation-douban-title:豆瓣作品')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(SearchPage), findsOneWidget);
      expect(find.byType(TmdbDetailPage), findsNothing);
    },
  );
  testWidgets(
    'pure page loads bottom and propagates dependencies to nested item detail',
    (tester) async {
      await size(tester);
      final dependencies = deps();
      final service = TmdbService(
        config: () => const TmdbConfig(apiKey: 'fixture'),
        client: MockClient(
          (r) async => http.Response(
            jsonEncode({
              'id': 1,
              'title': '当前作品',
              'videos': {'results': []},
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ),
        ),
      );
      addTearDown(service.close);
      await tester.pumpWidget(
        MaterialApp(
          home: TmdbDetailPage(
            service: service,
            identity: TmdbIdentity.of(TmdbMediaType.movie, 1)!,
            initialItem: item,
            recommendationDependencies: dependencies,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.drag(
        find.byType(SingleChildScrollView).first,
        const Offset(0, -2200),
      );
      await tester.pumpAndSettle();
      expect(find.text('猜你喜欢'), findsOneWidget);
      expect(find.text('个性推荐·豆瓣'), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const ValueKey('recommendation-related-movie:2')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('recommendation-related-movie:2')),
      );
      await tester.pumpAndSettle();
      final pages = tester
          .widgetList<TmdbDetailPage>(
            find.byType(TmdbDetailPage, skipOffstage: false),
          )
          .toList();
      expect(pages, hasLength(2));
      expect(pages.last.recommendationDependencies, same(dependencies));
    },
  );
  testWidgets(
    'secondary tap opens metadata and horizontal pagination uses offset 12',
    (tester) async {
      var offset = -1;
      final dependencies = deps(
        loader: (r) async {
          offset = r.offset;
          return RecommendationPage(
            items: [
              for (var i = 0; i < 12; i++)
                RecommendationEntry(
                  item: i == 0 && r.offset == 0
                      ? item
                      : TmdbItem(
                          tmdbId: 2 + r.offset + i,
                          mediaType: TmdbMediaType.movie,
                          title: '推荐作品${r.offset + i}',
                        ),
                  source: RecommendationSource.tmdb,
                ),
            ],
            nextOffset: r.offset + 12,
            hasMore: r.offset == 0,
          );
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: DetailRecommendations(
                dependencies: dependencies,
                current: const RecommendationSeed(title: '作品'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final row = find.byKey(const ValueKey('recommendation-row-related'));
      await tester.drag(row, const Offset(-1400, 0));
      await tester.pumpAndSettle();
      expect(offset, 12);
      expect(
        tester.widget<ListView>(row).childrenDelegate.estimatedChildCount,
        47,
      );
      await tester.drag(row, const Offset(2400, 0));
      await tester.pumpAndSettle();
      final gesture = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await gesture.down(
        tester.getCenter(
          find.byKey(const ValueKey('recommendation-related-movie:2')),
        ),
      );
      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.text('不感兴趣'), findsOneWidget);
    },
  );

  testWidgets(
    'distinct Douban subjects survive TMDB enrichment and share feedback',
    (tester) async {
      await size(tester);
      final feedback = RecommendationFeedbackStore();
      final dependencies = DetailRecommendationDependencies(
        feedback: feedback,
        loaders: {
          RecommendationRow.douban: (r) async => const RecommendationPage(
            items: [
              RecommendationEntry(
                item: item,
                source: RecommendationSource.douban,
                doubanId: 'a',
                doubanRating: 8.1,
              ),
              RecommendationEntry(
                item: item,
                source: RecommendationSource.douban,
                doubanId: 'b',
                doubanRating: 8.8,
              ),
            ],
          ),
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DetailRecommendations(
              dependencies: dependencies,
              current: const RecommendationSeed(title: '当前'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('推荐作品'), findsNWidgets(2));
      expect(
        find.byKey(const ValueKey('recommendation-douban-douban:a')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('recommendation-douban-douban:b')),
        findsOneWidget,
      );
      await tester.longPress(
        find.byKey(const ValueKey('recommendation-douban-douban:a')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('不感兴趣'));
      await tester.pumpAndSettle();
      expect(find.text('个性推荐·豆瓣'), findsNothing);
    },
  );

  testWidgets('pure recommendations refresh from real global source history', (
    tester,
  ) async {
    await size(tester);
    final dir = Directory.systemTemp.createTempSync('task3-global-history');
    final app = AppState(
      paths: AppPaths.resolve(
        overrides: {
          'config': dir.path,
          'data': dir.path,
          'cache': dir.path,
          'state': dir.path,
        },
      ),
      log: LogService(),
    );
    await tester.runAsync(app.bootstrap);
    addTearDown(() => dir.deleteSync(recursive: true));
    addTearDown(app.dispose);
    void history(String id, String title) => app.database!.upsertHistory(
      siteKey: 'external-site',
      vodId: id,
      vodName: title,
      flag: 'line',
      episodeName: 'episode',
      episodeId: id,
      positionMs: 1,
      durationMs: 100,
      sourceKey: 'other-source',
      vodYear: '2023',
      updatedAt: int.parse(id),
    );
    history('1', '外部历史甲');
    final wiring = app.recommendationDependencies;
    final dependencies = DetailRecommendationDependencies(
      feedback: wiring.feedback,
      history: wiring.history,
      historyChanges: wiring.historyChanges,
      loaders: {
        RecommendationRow.douban: (r) async => RecommendationPage(
          items: [
            RecommendationEntry(
              item: TmdbItem(
                tmdbId: 0,
                mediaType: TmdbMediaType.movie,
                title: '根据${r.history.first.title}',
              ),
              source: RecommendationSource.douban,
              doubanId: 'subject',
            ),
          ],
        ),
      },
    );
    expect(wiring.history().single.title, '外部历史甲');
    expect(wiring.history().single.tmdbId, 0);
    expect(wiring.history().single.year, '2023');
    final service = TmdbService(
      config: () => const TmdbConfig(apiKey: 'fixture'),
      client: MockClient(
        (r) async => http.Response('{"id":1,"title":"Current"}', 200),
      ),
    );
    addTearDown(service.close);
    await tester.pumpWidget(
      MaterialApp(
        home: TmdbDetailPage(
          service: service,
          identity: TmdbIdentity.of(TmdbMediaType.movie, 1)!,
          initialItem: item,
          recommendationDependencies: dependencies,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('根据外部历史甲'), findsOneWidget);
    history('2', '外部历史乙');
    app.notifySyncedDataChanged();
    await tester.pumpAndSettle();
    expect(find.text('根据外部历史乙'), findsOneWidget);
    expect(find.text('根据外部历史甲'), findsNothing);
  });

  testWidgets('pure snapshot keeps Douban visible when TMDB is unconfigured', (
    tester,
  ) async {
    await size(tester);
    var requests = 0;
    final service = TmdbService(
      config: () => const TmdbConfig(),
      client: MockClient((r) async {
        requests++;
        return http.Response('{}', 400);
      }),
    );
    addTearDown(service.close);
    final dependencies = DetailRecommendationDependencies(
      feedback: RecommendationFeedbackStore(),
      loaders: {
        RecommendationRow.douban: (r) async => const RecommendationPage(
          items: [
            RecommendationEntry(
              item: item,
              source: RecommendationSource.douban,
              doubanId: 'subject',
            ),
          ],
        ),
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: TmdbDetailPage(
          service: service,
          identity: item.identity!,
          initialItem: item,
          recommendationDependencies: dependencies,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('个性推荐·豆瓣'), findsOneWidget);
    expect(requests, 0);
  });

  testWidgets(
    'page disposal releases providers, leaks no timers and stops requests',
    (tester) async {
      await size(tester);
      final dir = Directory.systemTemp.createTempSync('task3-lease');
      addTearDown(() => dir.deleteSync(recursive: true));
      var tmdbRequests = 0;
      var doubanRequests = 0;
      final service = TmdbService(
        config: () => const TmdbConfig(apiKey: 'fixture'),
        client: MockClient((request) async {
          tmdbRequests++;
          return http.Response(
            '{"id":1,"title":"Current"}',
            200,
            headers: const {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      addTearDown(service.close);
      final dependencies = DetailRecommendationDependencies.fromServices(
        service: service,
        cacheDirectory: dir,
        doubanClient: MockClient((request) async {
          doubanRequests++;
          return http.Response('{}', 429);
        }),
      );
      addTearDown(dependencies.close);
      await tester.pumpWidget(
        MaterialApp(
          home: TmdbDetailPage(
            service: service,
            identity: item.identity!,
            initialItem: item,
            recommendationDependencies: dependencies,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(dependencies.isLeased, isTrue);
      final tmdbBeforeDispose = tmdbRequests;
      final doubanBeforeDispose = doubanRequests;
      // 拆页面：租约释放后不得再排任何请求或计时器。
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: SizedBox())),
      );
      await tester.pump(const Duration(seconds: 3));
      expect(dependencies.isLeased, isFalse);
      expect(doubanRequests, doubanBeforeDispose);
      expect(tmdbRequests, tmdbBeforeDispose);
      await tester.pumpAndSettle();
    },
  );

  testWidgets('unmatched source retains explicit TV media type', (
    tester,
  ) async {
    await size(tester);
    final dir = Directory.systemTemp.createTempSync('task3-type');
    final state = SourceState(dir, deps());
    await tester.runAsync(state.bootstrap);
    addTearDown(() => dir.deleteSync(recursive: true));
    addTearDown(state.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: DetailPage(
          state: state,
          vod: Vod(
            vodId: 'type',
            vodName: 'Type',
            extra: const {'media_type': 'tv'},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView).first, const Offset(0, -2200));
    await tester.pumpAndSettle();
    final recommendations = tester.widget<DetailRecommendations>(
      find.byType(DetailRecommendations),
    );
    expect(recommendations.current.mediaType, TmdbMediaType.tv);
  });

  testWidgets(
    'enabled source embedded related preserves order cap40 with personal rows',
    (tester) async {
      await size(tester);
      final dir = Directory.systemTemp.createTempSync('task3-embedded');
      addTearDown(() => dir.deleteSync(recursive: true));
      var relatedRequests = 0;
      final service = TmdbService(
        config: () => const TmdbConfig(apiKey: 'fixture'),
        client: MockClient((request) async {
          relatedRequests++;
          return http.Response('{}', 500);
        }),
      );
      addTearDown(service.close);
      final related = TmdbRecommendationService(service);
      final dependencies = DetailRecommendationDependencies(
        feedback: RecommendationFeedbackStore(),
        loaders: {
          RecommendationRow.related: (r) => related.related(
            current: r.current,
            detail: r.detail,
            sourceOnly: r.sourceOnly,
            offset: r.offset,
            pageSize: r.pageSize,
            blockedTitles: r.blockedTitles,
          ),
          RecommendationRow.tmdb: (r) async => const RecommendationPage(
            items: [
              RecommendationEntry(
                item: item,
                source: RecommendationSource.tmdb,
              ),
            ],
          ),
          RecommendationRow.douban: (r) async => const RecommendationPage(
            items: [
              RecommendationEntry(
                item: item,
                source: RecommendationSource.douban,
                doubanId: 'personal',
              ),
            ],
          ),
        },
      );
      final state = SourceState(dir, dependencies);
      await tester.runAsync(state.bootstrap);
      addTearDown(state.dispose);
      final vod = Vod(
        vodId: 'embedded',
        vodName: 'Current',
        extra: {
          'media_type': 'movie',
          'recommendations': {
            'results': [
              for (var i = 0; i < 45; i++)
                {
                  'id': 100 + i,
                  'title': i == 0
                      ? 'A'
                      : i == 1
                      ? 'B'
                      : 'Item$i',
                  'vote_average': i == 0 ? 1.0 : 9.0,
                },
            ],
          },
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: DetailPage(state: state, vod: vod),
        ),
      );
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView).first, const Offset(0, -2200));
      await tester.pumpAndSettle();
      final recommendations = tester.widget<DetailRecommendations>(
        find.byType(DetailRecommendations),
      );
      expect(recommendations.sourceOnly, false);
      final controller = DetailRecommendationState(
        loaders: dependencies.loaders,
        feedback: dependencies.feedback,
      );
      addTearDown(controller.dispose);
      await controller.refresh(
        current: recommendations.current,
        detail: recommendations.detail,
        sourceOnly: recommendations.sourceOnly,
        embeddedRelated: recommendations.embeddedRelated,
      );
      expect(
        controller
            .row(RecommendationRow.related)
            .items
            .map((e) => e.item.title)
            .take(2),
        ['A', 'B'],
      );
      expect(controller.row(RecommendationRow.related).items, hasLength(12));
      while (controller.row(RecommendationRow.related).hasMore) {
        await controller.loadMore(RecommendationRow.related);
      }
      expect(controller.row(RecommendationRow.related).items, hasLength(40));
      expect(relatedRequests, 0);
      expect(
        tester.getTopLeft(find.text('A')).dx,
        lessThan(tester.getTopLeft(find.text('B')).dx),
      );
      for (var page = 0; page < 3; page++) {
        final row = find.byKey(const ValueKey('recommendation-row-related'));
        await tester.ensureVisible(row);
        await tester.pumpAndSettle();
        await tester.drag(row, const Offset(-3000, 0));
        await tester.pumpAndSettle();
      }
      final relatedRow = tester.widget<ListView>(
        find.byKey(const ValueKey('recommendation-row-related')),
      );
      expect(
        relatedRow.childrenDelegate.estimatedChildCount,
        79,
      ); // 40 cards + 39 separators.
      expect(
        find.byKey(const ValueKey('recommendation-more-related')),
        findsNothing,
      );
      expect(relatedRequests, 0);
      expect(controller.row(RecommendationRow.tmdb).items, isNotEmpty);
      expect(controller.row(RecommendationRow.douban).items, isNotEmpty);
      expect(find.text('个性推荐·TMDB'), findsOneWidget);
      expect(find.text('个性推荐·豆瓣'), findsOneWidget);
    },
  );

  testWidgets(
    'history and current seeds use canonical tags from their source config',
    (tester) async {
      await size(tester);
      final dir = Directory.systemTemp.createTempSync('task3-classification');
      final app = AppState(
        paths: AppPaths.resolve(
          overrides: {
            'config': dir.path,
            'data': dir.path,
            'cache': dir.path,
            'state': dir.path,
          },
        ),
        log: LogService(),
      );
      await tester.runAsync(app.bootstrap);
      addTearDown(() => dir.deleteSync(recursive: true));
      addTearDown(app.dispose);
      final db = app.database!;
      db.saveConfig(
        name: 'other audio source',
        origin: 'fixture-a',
        sourceKey: 'audio-source',
        makeActive: false,
        json: {
          'sites': [
            {
              'key': 'same-key',
              'name': '「音」声源',
              'type': 0,
              'api': 'https://fixture.invalid',
            },
            {
              'key': 'short',
              'name': '【短】剧源',
              'type': 0,
              'api': 'https://fixture.invalid',
            },
          ],
        },
      );
      db.saveConfig(
        name: 'other movie source',
        origin: 'fixture-b',
        sourceKey: 'movie-source',
        makeActive: false,
        json: {
          'sites': [
            {
              'key': 'same-key',
              'name': '普通影视',
              'type': 0,
              'api': 'https://fixture.invalid',
            },
          ],
        },
      );
      void history(String id, String site, String source) => db.upsertHistory(
        siteKey: site,
        vodId: id,
        vodName: id,
        flag: 'line',
        episodeName: 'episode',
        episodeId: id,
        positionMs: 1,
        durationMs: 100,
        sourceKey: source,
      );
      history('audio', 'same-key', 'audio-source');
      history('short', 'short', 'audio-source');
      history('movie', 'same-key', 'movie-source');
      final seeds = {
        for (final seed in app.recommendationDependencies.history())
          seed.title: seed,
      };
      expect(seeds['audio']!.isAudio, true);
      expect(seeds['audio']!.isShortDrama, false);
      expect(seeds['short']!.isShortDrama, true);
      expect(seeds['short']!.isAudio, false);
      expect(
        app
            .recommendationSeedForVod(
              Vod(
                vodId: 'short-type',
                vodName: 'Short',
                extra: const {'type_name': '「短」'},
              ),
            )
            .isShortDrama,
        true,
      );
      expect(seeds['movie']!.isAudio, false);
      expect(seeds['movie']!.isShortDrama, false);
      final state = SourceState(
        dir,
        deps(),
        site: Site(
          key: 'audio',
          name: '【听】声源',
          type: 0,
          api: 'https://fixture.invalid',
        ),
      );
      await tester.runAsync(state.bootstrap);
      addTearDown(state.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: DetailPage(
            state: state,
            vod: Vod(vodId: 'current', vodName: 'Current'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView).first, const Offset(0, -2200));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<DetailRecommendations>(find.byType(DetailRecommendations))
            .current
            .isAudio,
        true,
      );
    },
  );

  testWidgets(
    'resolved recommendation without a site degrades to the title search page',
    (tester) async {
      await size(tester);
      final dir = Directory.systemTemp.createTempSync('task4-resolved-nav');
      final service = TmdbService(
        config: () => const TmdbConfig(apiKey: 'fixture'),
        client: MockClient(
          (r) async => http.Response('{"id":2,"title":"Recommended"}', 200),
        ),
      );
      addTearDown(service.close);
      // 没有选中站点：既搜不了站源，导航源回退页也没有站点可加载 TMDB，
      // 因此只能走既有的按标题搜索——这是唯一不会把用户送进空页的降级。
      final state = SourceState(dir, deps(), tmdbFixture: service);
      await tester.runAsync(state.bootstrap);
      addTearDown(() => dir.deleteSync(recursive: true));
      addTearDown(state.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: DetailPage(
            state: state,
            vod: Vod(vodId: 'current', vodName: 'Current'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView).first, const Offset(0, -2200));
      await tester.pumpAndSettle();
      final card = find.byKey(const ValueKey('recommendation-related-movie:2'));
      await tester.ensureVisible(card);
      await tester.pumpAndSettle();
      await tester.tap(card);
      await tester.pumpAndSettle();
      expect(find.byType(TmdbDetailPage, skipOffstage: false), findsNothing);
      expect(find.byType(SearchPage), findsOneWidget);
      expect(
        tester.widget<SearchPage>(find.byType(SearchPage)).initialKeyword,
        '推荐作品',
      );
    },
  );

  for (final scale in [1.5, 2.0]) {
    testWidgets('recommendation rows fit at text scale $scale', (tester) async {
      await size(tester);
      final dependencies = DetailRecommendationDependencies(
        feedback: RecommendationFeedbackStore(),
        loaders: {
          RecommendationRow.douban: (r) async => const RecommendationPage(
            items: [
              RecommendationEntry(
                item: item,
                source: RecommendationSource.douban,
                doubanId: 'scaled',
                doubanRating: 8.4,
              ),
            ],
          ),
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.dark),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Scaffold(
            body: DetailRecommendations(
              dependencies: dependencies,
              current: const RecommendationSeed(title: 'Current'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final score = tester.getRect(find.text('豆瓣 8.4'));
      final row = tester.getRect(
        find.byKey(const ValueKey('recommendation-row-douban')),
      );
      expect(score.bottom, lessThanOrEqualTo(row.bottom));
    });
  }

  testWidgets(
    'calendar episode person work keeps shared recommendations and title search',
    (tester) async {
      await size(tester);
      final dir = Directory.systemTemp.createTempSync('task3-calendar-nav');
      final today = DateTime.now();
      final date =
          '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
      final service = TmdbService(
        config: () => const TmdbConfig(apiKey: 'fixture'),
        client: MockClient((request) async {
          final path = request.url.path;
          final Object body = path.endsWith('/episode/1')
              ? {
                  'id': 100,
                  'episode_number': 1,
                  'season_number': 1,
                  'name': 'Episode',
                  'guest_stars': [
                    {'id': 88, 'name': 'Guest', 'character': 'Actor'},
                  ],
                }
              : path.endsWith('/person/88')
              ? {
                  'id': 88,
                  'name': 'Guest',
                  'combined_credits': {
                    'cast': [
                      {'id': 2, 'media_type': 'movie', 'title': 'PersonWork'},
                    ],
                  },
                }
              : {'id': 2, 'title': 'PersonWork', 'results': []};
          return http.Response(
            jsonEncode(body),
            200,
            headers: const {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      addTearDown(service.close);
      final dependencies = deps(titleOnly: true);
      dependencies.feedback.block('ExistingBlock');
      final state = CalendarRecommendationState(
        dir,
        dependencies,
        tmdbFixture: service,
      );
      await tester.runAsync(state.bootstrap);
      addTearDown(() => dir.deleteSync(recursive: true));
      addTearDown(state.dispose);
      final following = state.followFromDetail(
        site: Site(
          key: 's',
          name: 'Site',
          type: 4,
          api: 'https://fixture.invalid',
        ),
        vod: Vod(vodId: 'v', vodName: 'CalendarShow'),
        flag: 'line',
        releasedEpisode: 1,
      )!;
      state.attachFollowingAirTimeService(
        FollowingAirTimeService(
          isConfigured: () => true,
          resolveTmdbId: (_) async => 42,
          fetchEpisodes: (id, season) async => [
            TmdbEpisode(number: 1, title: 'Episode', date: date),
          ],
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: FollowingCalendarPage(state: state)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.longPress(
        find.byKey(ValueKey('calendar-entry-${following.identityKey}-S01E01')),
      );
      await tester.pumpAndSettle();
      final guest = find.byKey(const ValueKey('tmdb-episode-person-88'));
      await tester.ensureVisible(guest);
      await tester.pumpAndSettle();
      await tester.tap(guest);
      await tester.pumpAndSettle();
      final work = find.byKey(const ValueKey('tmdb-person-work-movie:2'));
      await tester.ensureVisible(work);
      await tester.pumpAndSettle();
      await tester.tap(work);
      await tester.pumpAndSettle();
      final detail = tester.widget<TmdbDetailPage>(find.byType(TmdbDetailPage));
      expect(detail.recommendationDependencies, same(dependencies));
      expect(detail.onSearchTitle, isNotNull);
      expect(
        dependencies.feedback.blockedTitles,
        contains(recommendationTitleKey('ExistingBlock')),
      );
      await tester.drag(
        find.byType(SingleChildScrollView).first,
        const Offset(0, -2200),
      );
      await tester.pumpAndSettle();
      final card = find.byKey(
        const ValueKey('recommendation-douban-title:豆瓣作品'),
      );
      await tester.ensureVisible(card);
      await tester.pumpAndSettle();
      await tester.tap(card);
      await tester.pumpAndSettle();
      expect(find.byType(SearchPage), findsOneWidget);
      expect(
        tester.widget<SearchPage>(find.byType(SearchPage)).initialKeyword,
        '豆瓣作品',
      );
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.ensureVisible(card);
      await tester.pumpAndSettle();
      await tester.longPress(card);
      await tester.pumpAndSettle();
      await tester.tap(find.text('不感兴趣'));
      await tester.pumpAndSettle();
      expect(
        state.recommendationDependencies.feedback.blockedTitles,
        contains(recommendationTitleKey('豆瓣作品')),
      );
      await tester.pageBack();
      await tester.pumpAndSettle();
    },
  );

  testWidgets('推荐卡片在当前站点命中 → 打开该站点那条真实条目', (tester) async {
    await size(tester);
    final dir = Directory.systemTemp.createTempSync('task4-site-match');
    final state = SourceState(dir, deps(), site: _currentSite());
    addTearDown(() => dir.deleteSync(recursive: true));
    addTearDown(state.dispose);
    await tester.runAsync(state.bootstrap);
    state.searchFixture = (site, keyword) async => SiteResult(
      list: [
        Vod(vodId: 'other', vodName: '别的剧'),
        Vod(vodId: 'match-1', vodName: '推荐作品'),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: DetailPage(
          state: state,
          vod: Vod(vodId: 'current', vodName: '当前作品'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView).first, const Offset(0, -2200));
    await tester.pumpAndSettle();
    final card = find.byKey(const ValueKey('recommendation-related-movie:2'));
    await tester.ensureVisible(card);
    await tester.pumpAndSettle();
    await tester.tap(card);
    await tester.pumpAndSettle();
    // 搜的是本页所在站点，用的是标题，并且走快搜（与换源浮层同一口径）。
    expect(state.searchCalls, [('current', '推荐作品', true)]);
    expect(find.byType(TmdbDetailPage, skipOffstage: false), findsNothing);
    final pages = tester
        .widgetList<DetailPage>(find.byType(DetailPage, skipOffstage: false))
        .toList();
    expect(pages.length, 2, reason: '必须在当前页之上再推一层站源详情页');
    expect(pages.last.vod.vodId, 'match-1');
    expect(pages.last.state.selectedSite?.key, 'current');
  });

  testWidgets('推荐卡片在当前站点没有命中 → 打开导航源形态详情（合成条目无 vodId）', (tester) async {
    await size(tester);
    final dir = Directory.systemTemp.createTempSync('task4-site-miss');
    final state = SourceState(dir, deps(), site: _currentSite());
    addTearDown(() => dir.deleteSync(recursive: true));
    addTearDown(state.dispose);
    await tester.runAsync(state.bootstrap);
    state.searchFixture = (site, keyword) async => SiteResult(
      list: [Vod(vodId: 'other', vodName: '完全无关的剧')],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: DetailPage(
          state: state,
          vod: Vod(vodId: 'current', vodName: '当前作品'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView).first, const Offset(0, -2200));
    await tester.pumpAndSettle();
    final card = find.byKey(const ValueKey('recommendation-related-movie:2'));
    await tester.ensureVisible(card);
    await tester.pumpAndSettle();
    await tester.tap(card);
    await tester.pumpAndSettle();
    expect(find.byType(TmdbDetailPage, skipOffstage: false), findsNothing);
    final pages = tester
        .widgetList<DetailPage>(find.byType(DetailPage, skipOffstage: false))
        .toList();
    expect(pages.length, 2);
    expect(pages.last.vod.vodId, isEmpty, reason: '合成条目不能带任何可请求的站源 id');
    expect(pages.last.vod.vodName, '推荐作品');
    expect(pages.last.vod.vodPlayUrl, isNull, reason: '回退页不得伪造播放线路');
  });

  testWidgets('推荐卡片搜索抛错 → 同样退回导航源形态，异常不外泄', (tester) async {
    await size(tester);
    final dir = Directory.systemTemp.createTempSync('task4-site-error');
    final state = SourceState(dir, deps(), site: _currentSite());
    addTearDown(() => dir.deleteSync(recursive: true));
    addTearDown(state.dispose);
    await tester.runAsync(state.bootstrap);
    state.searchFixture = (site, keyword) async => throw StateError('站点 500');
    await tester.pumpWidget(
      MaterialApp(
        home: DetailPage(
          state: state,
          vod: Vod(vodId: 'current', vodName: '当前作品'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView).first, const Offset(0, -2200));
    await tester.pumpAndSettle();
    final card = find.byKey(const ValueKey('recommendation-related-movie:2'));
    await tester.ensureVisible(card);
    await tester.pumpAndSettle();
    await tester.tap(card);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final pages = tester
        .widgetList<DetailPage>(find.byType(DetailPage, skipOffstage: false))
        .toList();
    expect(pages.last.vod.vodId, isEmpty);
  });

  testWidgets('导航源回退页：TMDB 剧集卡片 + 换源入口，换源前没有播放入口', (tester) async {
    await size(tester);
    final dir = Directory.systemTemp.createTempSync('task4-fallback-page');
    final tmdb = recommendationTmdbState(recommendationTmdbClient());
    final state = SourceState(
      dir,
      deps(),
      site: _currentSite(),
      tmdbState: tmdb,
      overrideDetail: false,
    );
    addTearDown(() => dir.deleteSync(recursive: true));
    addTearDown(state.dispose);
    await tester.runAsync(state.bootstrap);
    // 合成条目（vodId 为空）就是「当前站点没命中」的产物；本页必须跳过站源
    // 详情请求，只跑 TMDB 链。
    await tester.pumpWidget(
      MaterialApp(
        home: DetailPage(
          state: state,
          vod: Vod(vodId: '', vodName: '导航剧'),
        ),
      ),
    );
    for (var i = 0; i < 120 && tmdb.episodesBySeason.isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    await _pumpRounds(tester, rounds: 10);
    expect(tmdb.hasMatch, isTrue, reason: '合成条目仍必须按标题匹配到 TMDB 作品');
    expect(tmdb.episodesBySeason.keys.toSet(), {1});
    final cards = _navCards();
    await _revealInViewport(tester, cards);
    expect(cards, findsNWidgets(2), reason: '两集 TMDB 剧集卡片');
    expect(
      find.byKey(const ValueKey('detail-hero-play'), skipOffstage: false),
      findsNothing,
      reason: '换源之前没有任何可播放线路',
    );
    expect(
      find.byKey(const ValueKey('tmdb-line-selector'), skipOffstage: false),
      findsNothing,
      reason: '导航源形态不渲染线路条',
    );
    expect(
      find.byTooltip('收藏该影片', skipOffstage: false),
      findsNothing,
      reason: '没有站源身份就不该能写进收藏',
    );
    expect(
      find.byTooltip('追番', skipOffstage: false),
      findsNothing,
      reason: '没有站源身份就不该能写进追番',
    );
    // 换源入口：卡片点击 → 复用导航源那条换源说明框。
    // 卡片 key = 前缀 + '-' + 下标；前缀本身以 '-' 结尾（base 是 nav- + 空 vodId）。
    final first = find.byKey(const ValueKey('tmdb-episode-card-nav--0'));
    await _revealInViewport(tester, first);
    await tester.tap(first);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('nav-source-swap-confirm')),
      findsOneWidget,
    );
  });

  testWidgets('来源页不认领合成条目（空 vodId）留下的 TMDB 数据', (tester) async {
    await size(tester);
    final dir = Directory.systemTemp.createTempSync('task4-ownership');
    final tmdb = recommendationTmdbState(recommendationTmdbClient());
    final state = SourceState(
      dir,
      deps(),
      site: _currentSite(),
      tmdbState: tmdb,
    );
    addTearDown(() => dir.deleteSync(recursive: true));
    addTearDown(state.dispose);
    await tester.runAsync(state.bootstrap);
    // 内存里留着「导航剧」的 TMDB 数据：合成条目（推荐回退页）加载出来的产物。
    await tmdb.loadForVod(
      Vod(vodId: '', vodName: '导航剧'),
      siteKey: 'current',
      siteName: '当前站',
      navSource: true,
    );
    expect(tmdb.hasMatch, isTrue);
    await tester.pumpWidget(
      MaterialApp(
        home: DetailPage(
          state: state,
          vod: Vod(vodId: 'current', vodName: '当前剧'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('导航剧', skipOffstage: false),
      findsNothing,
      reason: '空 vodId 的 TMDB 数据只属于合成条目页，真实条目页不得认领',
    );
  });

  testWidgets('纯 TMDB 页底部推荐同样先搜当前站点（无命中 → 导航源回退页）', (tester) async {
    await size(tester);
    final dir = Directory.systemTemp.createTempSync('task4-pure-page');
    final tmdb = recommendationTmdbState(recommendationTmdbClient());
    final state = SourceState(
      dir,
      deps(),
      site: _currentSite(),
      tmdbState: tmdb,
      tmdbFixture: TmdbService(
        config: () => const TmdbConfig(apiKey: 'fixture'),
        client: recommendationTmdbClient(),
      ),
    );
    addTearDown(() => dir.deleteSync(recursive: true));
    addTearDown(state.dispose);
    await tester.runAsync(state.bootstrap);
    await tmdb.loadForVod(
      Vod(vodId: 'current', vodName: '导航剧'),
      siteKey: 'current',
      siteName: '当前站',
    );
    state.searchFixture = (site, keyword) async => const SiteResult();
    await tester.pumpWidget(
      MaterialApp(
        home: DetailPage(
          state: state,
          vod: Vod(vodId: 'current', vodName: '导航剧'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final open = find.byKey(const ValueKey('tmdb-open-detail'));
    // 入口在 hero 下方，ListView 懒建：必须先把它滚进视口再点。
    await _revealInViewport(tester, open);
    await tester.pumpAndSettle();
    await tester.tap(open);
    // 先把路由转场走完（300ms）：上一页此时仍有同名推荐卡，只按 key 找会命中两个。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await _pumpRounds(tester, rounds: 30);
    expect(find.byType(TmdbDetailPage), findsOneWidget);
    await tester.drag(
      find.byType(SingleChildScrollView).first,
      const Offset(0, -2200),
    );
    await _pumpRounds(tester, rounds: 10);
    final card = find
        .byKey(const ValueKey('recommendation-related-movie:2'))
        .last;
    await tester.ensureVisible(card);
    await _pumpRounds(tester, rounds: 5);
    await tester.tap(card);
    await tester.pumpAndSettle();
    expect(state.searchCalls.last.$1, 'current', reason: '纯页用当前选中站点搜索');
    expect(state.searchCalls.last.$2, '推荐作品');
    final pages = tester
        .widgetList<DetailPage>(find.byType(DetailPage, skipOffstage: false))
        .toList();
    expect(pages.last.vod.vodId, isEmpty);
  });
  const knownSeries = TmdbItem(
    tmdbId: 1399,
    mediaType: TmdbMediaType.tv,
    title: '已知推荐剧',
  );

  Future<
    ({
      SourceState state,
      List<String> requests,
      GlobalKey capture,
      InMemoryTmdbMatchStore store,
    })
  >
  openKnownFallback(
    WidgetTester tester, {
    TmdbItem recommendation = knownSeries,
    TmdbConfig settings = const TmdbConfig(apiKey: 'fixture'),
    bool failDetail = false,
    bool failSeasons = false,
    bool mismatchId = false,
    bool mismatchType = false,
    bool mismatchShape = false,
    bool realNoEpisode = false,
  }) async {
    await size(tester);
    final requests = <String>[];
    final client = MockClient((request) async {
      final path = request.url.path;
      requests.add(path);
      Object body;
      if (path.endsWith('/search/multi')) {
        body = {'results': <Object>[]};
      } else if (path.endsWith('/tv/1399') && !failDetail) {
        body = {
          'id': mismatchId ? 999 : 1399,
          if (mismatchType) 'media_type': 'movie',
          if (mismatchShape) 'title': '错类型电影' else 'name': '已知推荐剧',
          'seasons': [
            {'season_number': 1, 'episode_count': 2},
            {'season_number': 2, 'episode_count': 2},
          ],
        };
      } else if (path.endsWith('/movie/2') && !failDetail) {
        body = {'id': 2, 'title': '已知推荐电影'};
      } else if (path.contains('/season/') && !failSeasons) {
        final season = int.parse(path.split('/').last);
        body = {
          'season_number': season,
          'episodes': [
            for (var episode = 1; episode <= 2; episode++)
              {
                'episode_number': episode,
                'season_number': season,
                'name': '第$season季第$episode集',
              },
          ],
        };
      } else if (path.endsWith('/videos')) {
        body = {'results': <Object>[]};
      } else {
        return http.Response('{}', 404);
      }
      return http.Response(
        jsonEncode(body),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });
    final store = InMemoryTmdbMatchStore();
    final tmdb = recommendationTmdbState(
      client,
      settings: settings,
      matchStore: store,
    );
    final dir = Directory.systemTemp.createTempSync('task6-known-fallback');
    final dependencies = deps(
      loader: (_) async => RecommendationPage(
        items: [
          RecommendationEntry(
            item: recommendation,
            source: RecommendationSource.tmdb,
          ),
        ],
      ),
    );
    final SourceState state = realNoEpisode
        ? _Task6EmptySourceState(
            dir,
            dependencies,
            site: _currentSite(),
            tmdbState: tmdb,
          )
        : SourceState(
            dir,
            dependencies,
            site: _currentSite(),
            tmdbState: tmdb,
            overrideDetail: false,
          );
    addTearDown(() => dir.deleteSync(recursive: true));
    addTearDown(state.dispose);
    await tester.runAsync(state.bootstrap);
    final capture = GlobalKey();
    final base = buildAppTheme(Brightness.dark);
    await tester.pumpWidget(
      RepaintBoundary(
        key: capture,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: base.copyWith(
            textTheme: base.textTheme.apply(fontFamily: 'FixtureCJK'),
            filledButtonTheme: FilledButtonThemeData(
              style: base.filledButtonTheme.style?.copyWith(
                textStyle: WidgetStatePropertyAll(
                  base.textTheme.labelLarge?.copyWith(fontFamily: 'FixtureCJK'),
                ),
              ),
            ),
            outlinedButtonTheme: OutlinedButtonThemeData(
              style: base.outlinedButtonTheme.style?.copyWith(
                textStyle: WidgetStatePropertyAll(
                  base.textTheme.labelLarge?.copyWith(fontFamily: 'FixtureCJK'),
                ),
              ),
            ),
            textButtonTheme: TextButtonThemeData(
              style: base.textButtonTheme.style?.copyWith(
                textStyle: WidgetStatePropertyAll(
                  base.textTheme.labelLarge?.copyWith(fontFamily: 'FixtureCJK'),
                ),
              ),
            ),
            appBarTheme: base.appBarTheme.copyWith(
              titleTextStyle: const TextStyle(
                fontFamily: 'FixtureCJK',
                fontSize: 20,
              ),
            ),
          ),
          home: DetailPage(
            state: state,
            vod: Vod(vodId: 'origin', vodName: '当前作品'),
          ),
        ),
      ),
    );
    await _pumpRounds(tester);
    if (realNoEpisode) {
      await _pumpRounds(tester, rounds: 120);
      return (state: state, requests: requests, capture: capture, store: store);
    }
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -2200));
    await _pumpRounds(tester);
    final key = ValueKey(
      'recommendation-related-${recommendation.mediaType.wireName}:${recommendation.tmdbId}',
    );
    final card = find.byKey(key);
    await tester.ensureVisible(card);
    await _pumpRounds(tester);
    await tester.tap(card);
    await _pumpRounds(tester, rounds: 120);
    expect(
      tester.widget<DetailPage>(find.byType(DetailPage)).vod.vodId,
      isEmpty,
    );
    return (state: state, requests: requests, capture: capture, store: store);
  }

  testWidgets(
    'task6 known series fallback shows every season without title matching',
    (tester) async {
      final fixture = await openKnownFallback(tester);
      const beforeEvidence = String.fromEnvironment('TASK6_EVIDENCE');
      if (beforeEvidence == 'before') {
        await _revealInViewport(
          tester,
          find.byKey(const ValueKey('nav-source-swap-empty')),
        );
        await tester.pump();
        final boundary =
            fixture.capture.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('../../.local/task6-before-known-series-fallback.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      expect(
        fixture.state.tmdb.hasMatch,
        isTrue,
        reason: 'The recommendation known identity must survive empty title-search results',
      );
      expect(fixture.state.tmdb.identity?.key, 'tv:1399');
      expect(
        fixture.store.cache.entries,
        isEmpty,
        reason: 'Synthetic identity must not create match cache records',
      );
      await _revealInViewport(tester, _navCards());
      expect(_navCards(), findsNWidgets(4));
      for (var index = 0; index < 4; index++) {
        expect(
          find.byKey(ValueKey('tmdb-episode-card-nav--$index')),
          findsOneWidget,
        );
      }
      expect(fixture.state.tmdb.episodesBySeason.keys.toSet(), {1, 2});
      expect(
        fixture.requests.where((path) => path.endsWith('/search/multi')),
        isEmpty,
      );
      expect(find.byKey(const ValueKey('detail-hero-play')), findsNothing);
      expect(find.byKey(const ValueKey('tmdb-line-selector')), findsNothing);
      const evidence = String.fromEnvironment('TASK6_EVIDENCE');
      if (evidence.isNotEmpty) {
        await tester.pump();
        final boundary =
            fixture.capture.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '../../docs/superpowers/evidence/detail-recommendations/task-6-known-series-fallback.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.tap(find.byKey(const ValueKey('tmdb-episode-card-nav--0')));
      await _pumpRounds(tester);
      expect(
        find.byKey(const ValueKey('nav-source-swap-confirm')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('nav-source-swap-confirm')));
      await _pumpRounds(tester);
      expect(find.byKey(const ValueKey('source-swap-sheet')), findsOneWidget);
    },
  );

  for (final scenario in [
    'movie',
    'unconfigured',
    'disabled',
    'failed-detail',
    'failed-seasons',
    'wrong-id',
    'wrong-type',
    'wrong-shape',
  ]) {
    testWidgets('task6 $scenario fallback keeps honest swap-only content', (
      tester,
    ) async {
      final fixture = await openKnownFallback(
        tester,
        recommendation: scenario == 'movie'
            ? const TmdbItem(
                tmdbId: 2,
                mediaType: TmdbMediaType.movie,
                title: '已知推荐电影',
              )
            : knownSeries,
        settings: scenario == 'unconfigured'
            ? const TmdbConfig()
            : scenario == 'disabled'
            ? const TmdbConfig(apiKey: 'fixture', disabledSites: ['current'])
            : const TmdbConfig(apiKey: 'fixture'),
        failDetail: scenario == 'failed-detail',
        failSeasons: scenario == 'failed-seasons',
        mismatchId: scenario == 'wrong-id',
        mismatchType: scenario == 'wrong-type',
        mismatchShape: scenario == 'wrong-shape',
      );
      if (scenario == 'wrong-id' ||
          scenario == 'wrong-type' ||
          scenario == 'wrong-shape') {
        expect(
          fixture.state.tmdb.hasMatch,
          isFalse,
          reason: 'A fetched different identity must never own the fallback',
        );
      }
      await _revealInViewport(
        tester,
        find.byKey(const ValueKey('nav-source-swap-empty')),
      );
      expect(_navCards(), findsNothing);
      expect(
        find.byKey(const ValueKey('nav-source-swap-empty')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('detail-hero-play')), findsNothing);
      if (scenario == 'unconfigured' || scenario == 'disabled') {
        expect(fixture.requests, isEmpty);
      }
    });
  }

  testWidgets(
    'task6 real source without episodes uses known identity card view',
    (tester) async {
      final fixture = await openKnownFallback(tester, realNoEpisode: true);
      expect(
        tester.widget<DetailPage>(find.byType(DetailPage)).vod.vodId,
        'origin',
      );
      expect(fixture.state.tmdb.hasMatch, isTrue);
      expect(fixture.state.tmdb.identity?.key, 'tv:1399');
      final cards = find.byWidgetPredicate(
        (widget) =>
            widget is OutlinedButton &&
            widget.key is ValueKey<String> &&
            (widget.key! as ValueKey<String>).value.startsWith(
              'tmdb-episode-card-noline-origin-',
            ),
      );
      await _revealInViewport(tester, cards);
      expect(cards, findsNWidgets(4));
      expect(find.byKey(const ValueKey('detail-hero-play')), findsNothing);
      expect(
        fixture.requests.where((path) => path.endsWith('/search/multi')),
        hasLength(1),
        reason: 'The unbound initial source may match once; authoritative known identity must not search again',
      );
    },
  );

  testWidgets(
    'task6 same-title synthetic reload compares identity and never writes match cache',
    (tester) async {
      final fixture = await openKnownFallback(tester);
      expect(fixture.store.cache.entries, isEmpty);
      await fixture.state.loadDetail(
        Vod(
          vodId: '',
          vodName: '已知推荐剧',
          extra: {'tmdb_id': 2, 'media_type': 'movie'},
        ),
        siteOverride: _currentSite(),
      );
      await _pumpRounds(tester);
      expect(fixture.state.tmdb.identity?.key, 'movie:2');
      expect(fixture.state.tmdb.detail?['title'], '已知推荐电影');
      expect(fixture.state.tmdb.episodesBySeason, isEmpty);
      expect(fixture.store.cache.entries, isEmpty);
      expect(
        fixture.requests.where((path) => path.endsWith('/search/multi')),
        isEmpty,
      );
      await tester.binding.handlePopRoute();
      await _pumpRounds(tester, rounds: 120);
      expect(
        tester.widget<DetailPage>(find.byType(DetailPage)).vod.vodId,
        'origin',
      );
      fixture.state.detailService = _Task6EmptyService(withIdentity: false);
      final directRequests = fixture.requests
          .where(
            (path) => path.endsWith('/tv/1399') || path.endsWith('/movie/2'),
          )
          .length;
      unawaited(
        Navigator.of(tester.element(find.byType(DetailPage))).push(
          MaterialPageRoute<void>(
            builder: (_) => DetailPage(
              state: fixture.state,
              vod: Vod(vodId: 'different-real', vodName: '已知推荐剧'),
            ),
          ),
        ),
      );
      await _pumpRounds(tester, rounds: 120);
      expect(
        tester.widget<DetailPage>(find.byType(DetailPage)).vod.vodId,
        'different-real',
      );
      expect(fixture.state.tmdb.vodId, 'different-real');
      expect(
        fixture.state.tmdb.identity,
        isNull,
        reason: 'A different real Vod with the same title must not inherit either synthetic identity',
      );
      expect(
        fixture.requests.where((path) => path.endsWith('/search/multi')),
        isNotEmpty,
      );
      expect(
        fixture.requests.where(
          (path) => path.endsWith('/tv/1399') || path.endsWith('/movie/2'),
        ),
        hasLength(directRequests),
      );
    },
  );

  testWidgets(
    'task6 playable source cannot use known identity to bypass matching',
    (tester) async {
      final requests = <String>[];
      final client = MockClient((request) async {
        requests.add(request.url.path);
        return http.Response(jsonEncode({'results': <Object>[]}), 200);
      });
      final state = recommendationTmdbState(client);
      addTearDown(state.dispose);
      final future = state.loadForVod(
        Vod(
          vodId: 'playable',
          vodName: '站源作品',
          vodPlayFrom: '线路',
          vodPlayUrl: r'第一集$https://fixture.invalid/play.mp4',
        ),
        siteKey: 'current',
        knownIdentity: knownSeries.identity,
      );
      await _pumpRounds(tester);
      await future;
      expect(state.hasMatch, isFalse);
      expect(
        requests.where((path) => path.endsWith('/search/multi')),
        hasLength(1),
      );
      expect(requests.where((path) => path.endsWith('/tv/1399')), isEmpty);
    },
  );

  testWidgets(
    'task6 authoritative source response cannot drop an already known no-playback identity',
    (tester) async {
      final fixture = await openKnownFallback(tester);
      await fixture.state.loadDetail(
        Vod(
          vodId: 'known-source',
          vodName: '已知推荐剧',
          extra: {'tmdb_id': 1399, 'media_type': 'tv'},
        ),
        siteOverride: _currentSite(),
        serviceOverride: _Task6EmptyService(withIdentity: false),
      );
      await _pumpRounds(tester, rounds: 120);
      expect(fixture.state.tmdb.hasMatch, isTrue);
      expect(fixture.state.tmdb.identity?.key, 'tv:1399');
      expect(fixture.state.tmdb.episodesBySeason.keys.toSet(), {1, 2});
      expect(
        fixture.requests.where((path) => path.endsWith('/search/multi')),
        isEmpty,
      );
      await fixture.state.loadDetail(
        Vod(vodId: 'known-source', vodName: '已知推荐剧'),
        siteOverride: Site(
          key: 'other',
          name: '另一站',
          type: 1,
          api: 'https://fixture.invalid/other',
        ),
        serviceOverride: _Task6EmptyService(withIdentity: false),
      );
      await _pumpRounds(tester, rounds: 120);
      expect(
        fixture.state.tmdb.hasMatch,
        isFalse,
        reason: 'Same Vod id on another site must not inherit seeded identity',
      );
    },
  );
}
