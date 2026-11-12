import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/ai_config.dart';
import 'package:webhtv_pc/core/detail_ratings.dart';
import 'package:webhtv_pc/core/detail_recommendation.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/tmdb_config.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/services/ai_completion_client.dart';
import 'package:webhtv_pc/services/ai_season_mapping_service.dart';
import 'package:webhtv_pc/services/ai_content/ai_content_completion.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/detail_rating_service.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/recommendation_feedback_store.dart';
import 'package:webhtv_pc/services/site_service.dart';
import 'package:webhtv_pc/services/tmdb_enrichment_service.dart';
import 'package:webhtv_pc/services/tmdb_identity_service.dart';
import 'package:webhtv_pc/services/tmdb_season_service.dart';
import 'package:webhtv_pc/services/tmdb_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/state/detail_recommendation_state.dart';
import 'package:webhtv_pc/state/tmdb_state.dart';
import 'package:webhtv_pc/ui/ai_content/ai_recommendation_section.dart';
import 'package:webhtv_pc/ui/browse_pages.dart';
import 'package:webhtv_pc/ui/detail_ratings_section.dart';
import 'package:webhtv_pc/ui/detail_recommendations.dart';
import 'package:webhtv_pc/ui/theme.dart';
import 'package:webhtv_pc/ui/tmdb_detail_page.dart';
import 'package:webhtv_pc/ui/tmdb_detail_view.dart';

import 'support/temp_dirs.dart';
import 'support/test_fonts.dart';

const _title = '星际旅途';
const _overview = '普通简介：两位旅人在星空下寻找回家的路。';
const _settings = TmdbConfig(apiKey: 'fixture');
final _vod = Vod(
  vodId: 'source-1',
  vodName: _title,
  vodContent: _overview,
  vodPlayFrom: '高清线路',
  vodPlayUrl: '第1集\$https://fixture.test/1.mp4#第2集\$https://fixture.test/2.mp4',
);

class _Ratings implements DetailRatingService {
  int calls = 0;
  @override
  Future<DetailRatingValues> fetch(
    DetailRatingRequest request, {
    required String omdbApiKey,
  }) async {
    calls++;
    return const DetailRatingValues(
      doubanRating: 8.8,
      imdb: '8.4',
      rottenTomatoes: '91%',
      metacritic: '82/100',
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _DetailState extends AppState {
  _DetailState(Directory dir, this.fixtureTmdb, this.fixtureService)
    : super(
        paths: AppPaths.resolve(
          overrides: {
            'config': dir.path,
            'data': dir.path,
            'cache': dir.path,
            'state': dir.path,
          },
        ),
        log: LogService(),
        aiContentCompletion: AiContentCompletion(
          complete:
              ({
                required AiConfig config,
                required String prompt,
                Duration timeout = Duration.zero,
              }) async {
                aiRequests++;
                return const AiCompletionResult(
                  ok: true,
                  statusCode: 200,
                  text: '{"items":[{"title":"AI额外推荐","mediaType":"movie","year":2024}]}',
                  message: '',
                );
              },
        ),
      );

  static int aiRequests = 0;
  final TmdbState fixtureTmdb;
  final TmdbService fixtureService;
  final openedUrls = <String>[];
  AiSeasonBindingsResult? storedMappings;

  @override
  AiSeasonBindingsResult? aiMappingsFor(Vod vod, VodPlayLine line) =>
      storedMappings ?? super.aiMappingsFor(vod, line);
  final ratings = _Ratings();
  final recommendations = DetailRecommendationDependencies(
    feedback: RecommendationFeedbackStore(),
    loaders: {
      for (final row in RecommendationRow.values)
        row: (request) async => RecommendationPage(
          items: [
            RecommendationEntry(
              item: const TmdbItem(
                tmdbId: 22,
                mediaType: TmdbMediaType.movie,
                title: '非AI推荐作品',
              ),
              source: row == RecommendationRow.douban
                  ? RecommendationSource.douban
                  : RecommendationSource.tmdb,
              reason: '根据观看历史',
            ),
          ],
          nextOffset: 12,
          hasMore: false,
        ),
    },
  );

  @override
  Site get selectedSite => Site(
    key: 'current',
    name: '当前站源',
    type: 1,
    api: 'https://fixture.test/api',
  );
  @override
  TmdbConfig get tmdbConfig => _settings;
  @override
  TmdbState get tmdb => fixtureTmdb;
  @override
  TmdbService get tmdbService => fixtureService;
  @override
  DetailRatingService get detailRatingService => ratings;
  @override
  DetailRecommendationDependencies get recommendationDependencies =>
      recommendations;
  @override
  Future<bool> openExternalUrl(String url) async {
    openedUrls.add(url);
    return true;
  }

  @override
  Future<void> loadDetail(
    Vod vod, {
    SiteService? serviceOverride,
    Site? siteOverride,
  }) async {}
}

http.Client _client() => MockClient((request) async {
  final Object body;
  if (request.url.path.endsWith('/search/multi')) {
    body = {
      'results': [
        {
          'id': 21,
          'media_type': 'movie',
          'title': _title,
          'release_date': '2024-01-01',
        },
      ],
    };
  } else if (request.url.path.endsWith('/videos')) {
    body = {'results': <Object>[]};
  } else {
    body = {
      'id': 21,
      'title': _title,
      'original_title': 'Journey Home',
      'overview': _overview,
      'release_date': '2024-01-01',
      'vote_average': 8.4,
      'runtime': 108,
      // 真实 TMDB 详情带 append=external_ids；IMDb 外链只能从这里拿到 id。
      'external_ids': {'imdb_id': 'tt1234567'},
      'translations': {
        'translations': [
          {
            'iso_639_1': 'en',
            'data': {'title': 'Journey Home'},
          },
        ],
      },
    };
  }
  return http.Response(
    jsonEncode(body),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
});

Future<void> _settleIo(WidgetTester tester) async {
  await tester.runAsync(() async {
    for (var i = 0; i < 40; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await tester.pump();
    }
  });
  await tester.pumpAndSettle();
}

void _scrollTo(WidgetTester tester, double offset) {
  final scrollable = tester.state<ScrollableState>(
    find
        .byWidgetPredicate(
          (widget) =>
              widget is Scrollable &&
              widget.axisDirection == AxisDirection.down,
        )
        .first,
  );
  scrollable.position.jumpTo(offset);
}

void main() {
  late Directory dir;
  late _DetailState state;
  late TmdbService service;
  late TmdbState tmdb;

  setUpAll(() async {
    await loadFixtureFonts();
    await loadFixtureFonts(cjkFamily: 'Noto Sans CJK SC');
    await loadFixtureFonts(cjkFamily: 'Roboto');
  });
  setUp(() async {
    dir = Directory.systemTemp.createTempSync('detail-removed-actions');
    service = TmdbService(config: () => _settings, client: _client());
    tmdb = TmdbState(
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
    _DetailState.aiRequests = 0;
    state = _DetailState(dir, tmdb, service);
    await state.bootstrap();
    await state.saveAiConfig(
      const AiConfig(
        enabled: true,
        apiKey: 'fixture-key',
        endpoint: 'https://fixture.test/v1',
        model: 'fixture-model',
      ),
    );
    state.seedDetailForTest(vod: _vod);
    await tmdb.loadForVod(_vod, siteKey: 'current', siteName: '当前站源');
    expect(state.aiReady, isTrue);
    expect(tmdb.hasMatch, isTrue);
  });
  tearDown(() {
    state.dispose();
    tmdb.dispose();
    service.close();
    deleteTempDirBestEffortSync(dir);
  });

  Future<GlobalKey> pumpSource(
    WidgetTester tester, {
    Brightness brightness = Brightness.light,
    double width = 1280,
  }) async {
    tester.view.physicalSize = Size(width, 950);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final boundary = GlobalKey();
    final theme = buildAppTheme(brightness);
    await tester.pumpWidget(
      MaterialApp(
        theme: theme.copyWith(
          textTheme: theme.textTheme.apply(fontFamily: 'FixtureCJK'),
        ),
        builder: (context, child) =>
            RepaintBoundary(key: boundary, child: child!),
        home: DetailPage(state: state, vod: _vod),
      ),
    );
    await _settleIo(tester);
    return boundary;
  }

  /// 纯 TMDB 详情页现在只能从**推荐卡片 / 演职人员作品**进入（状态条那个
  /// 「在 TMDB 中查看」入口已按用户决策去掉）。截图与断言不必绕推荐链，
  /// 直接 push 同一个页面即可——被验证的是页面本身，不是入口。
  Future<void> openPurePage(WidgetTester tester) async {
    final navigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    unawaited(
      navigator.push<void>(
        MaterialPageRoute<void>(
          builder: (_) => TmdbDetailPage(
            service: state.tmdbService,
            identity: TmdbIdentity.of(TmdbMediaType.movie, 21)!,
            initialItem: const TmdbItem(
              tmdbId: 21,
              mediaType: TmdbMediaType.movie,
              title: _title,
            ),
            recommendationDependencies: state.recommendationDependencies,
            ratingService: state.ratings,
            omdbApiKey: '',
            // 与生产接线一致：推荐区最下方带 AI 行（种子是这部作品）。
            aiRecommendations: AiRecommendationSection(
              state: state,
              seedTitle: _title,
            ),
          ),
        ),
      ),
    );
    await _settleIo(tester);
    expect(find.byType(TmdbDetailPage), findsOneWidget);
  }

  testWidgets('layout scores sit above overview while footer only has links', (
    tester,
  ) async {
    await pumpSource(tester);
    final header = find.byKey(const ValueKey('tmdb-detail-title'));
    expect(header, findsOneWidget);
    expect(find.text('豆瓣 8.8'), findsOneWidget);
    expect(find.text('IMDb 8.4'), findsOneWidget);
    final score = find.text('豆瓣 8.8');
    final overview = find.byKey(const ValueKey('tmdb-detail-hero-overview'));
    expect(
      tester.getBottomLeft(score).dy,
      lessThan(tester.getTopLeft(overview).dy),
    );
    expect(find.text('TMDB 8.4'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('detail-rating-tags')),
        matching: find.byType(InkWell),
      ),
      findsNothing,
    );
    final calls = state.ratings.calls;
    _scrollTo(tester, 10000);
    await _settleIo(tester);
    final footer = find.byType(DetailRatingsSection);
    expect(footer, findsOneWidget);
    final rec = find.byType(DetailRecommendations);
    expect(
      tester.getTopLeft(footer).dy,
      greaterThanOrEqualTo(tester.getBottomLeft(rec).dy),
    );
    expect(
      find.descendant(of: footer, matching: find.byType(OutlinedButton)),
      findsNWidgets(5),
    );
    expect(
      find.descendant(of: footer, matching: find.byIcon(Icons.star)),
      findsNothing,
    );
    expect(
      state.ratings.calls,
      calls,
      reason: 'head and footer share one fetch',
    );
  });

  for (final pageKind in ['source', 'pure']) {
    for (final width in [1280.0, 900.0]) {
      for (final brightness in Brightness.values) {
        testWidgets('layout evidence $pageKind $width ${brightness.name}', (
          tester,
        ) async {
          final phase =
              Platform.environment['DETAIL_LAYOUT_CAPTURE_PHASE'] ?? '';
          final boundary = await pumpSource(
            tester,
            width: width,
            brightness: brightness,
          );
          if (pageKind == 'pure') await openPurePage(tester);

          // `middle` 用来核对区块之间的间距是否一致（用户反馈 2026-11-11）。
          for (final position in ['hero', 'middle', 'footer']) {
            _scrollTo(tester, switch (position) {
              'hero' => 0,
              'middle' => 1200,
              _ => 10000,
            });
            await _settleIo(tester);
            expect(tester.takeException(), isNull);
            if (phase.isEmpty) continue;
            await tester.runAsync(() async {
              final render =
                  boundary.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary;
              final image = await render.toImage(pixelRatio: 1);
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              final file = File(
                '../../.local/detail-layout/$phase-$pageKind-$position-$width-${brightness.name}.png',
              );
              await file.parent.create(recursive: true);
              await file.writeAsBytes(bytes!.buffer.asUint8List());
              image.dispose();
            });
          }
        });
      }
    }
  }

  for (final brightness in Brightness.values) {
    testWidgets('capture real source ${brightness.name}', (tester) async {
      final boundary = await pumpSource(tester, brightness: brightness);
      _scrollTo(tester, 900);
      await tester.pumpAndSettle();
      expect(find.textContaining('高清线路'), findsWidgets);
      expect(find.byType(DetailRatingsSection), findsOneWidget);
      expect(tester.takeException(), isNull);
      final phase = Platform.environment['DETAIL_REMOVED_CAPTURE_PHASE'] ?? '';
      if (phase.isEmpty) return;
      expect(['before', 'after'], contains(phase));
      if (phase == 'before') {
        expect(find.text('阅读简介').hitTestable(), findsOneWidget);
      }
      await tester.runAsync(() async {
        final repaint =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await repaint.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          '../../.local/detail-removed-actions/$phase-source-${brightness.name}-1280x950-offset900.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    });
  }

  testWidgets(
    'source removes AI and reader actions but keeps overview and playable episodes',
    (tester) async {
      await pumpSource(tester);
      expect(find.text(_overview), findsWidgets);
      expect(find.byKey(const ValueKey('detail-hero-play')), findsOneWidget);
      _scrollTo(tester, 900);
      await tester.pumpAndSettle();
      expect(find.textContaining('高清线路'), findsWidgets);
      expect(find.textContaining('2 集'), findsWidgets);
      expect(find.textContaining('第1集'), findsWidgets);
      expect(find.textContaining('第2集'), findsWidgets);
      // AI 推荐行已恢复到推荐区最下方（用户 2026-11-12 要求）。
      expect(find.byType(AiRecommendationSection), findsOneWidget);
      expect(find.byKey(const ValueKey('detail-ai-business')), findsNothing);
      expect(find.text('阅读简介'), findsNothing);
      final episodeBody = find
          .ancestor(
            of: find.byType(TmdbEpisodeHeader),
            matching: find.byType(Column),
          )
          .first;
      expect(
        find.descendant(of: episodeBody, matching: find.byType(Wrap)),
        findsNothing,
      );
    },
  );

  testWidgets('source has no reader action', (tester) async {
    await pumpSource(tester);
    _scrollTo(tester, 900);
    await tester.pumpAndSettle();
    expect(find.text('阅读简介'), findsNothing);
  });

  testWidgets('AI season chips still filter and restore playable episodes', (
    tester,
  ) async {
    state.storedMappings = const AiSeasonBindingsResult(
      status: AiSeasonApplyStatus.applied,
      bindings: [
        AiEpisodeBinding(sourceIndex: 0, seasonNumber: 1, episodeNumber: 1),
        AiEpisodeBinding(sourceIndex: 1, seasonNumber: 2, episodeNumber: 1),
      ],
      mappedCount: 2,
    );
    await pumpSource(tester);
    final aiBefore = _DetailState.aiRequests;
    _scrollTo(tester, 900);
    await tester.pumpAndSettle();
    expect(find.text('全部映射'), findsOneWidget);
    expect(find.text('第1季'), findsOneWidget);
    expect(find.text('第2季'), findsOneWidget);
    expect(
      tester
          .widget<TmdbEpisodeHeader>(find.byType(TmdbEpisodeHeader))
          .episodeCount,
      2,
    );
    await tester.tap(find.text('第2季'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TmdbEpisodeHeader>(find.byType(TmdbEpisodeHeader))
          .episodeCount,
      1,
    );
    await tester.tap(find.text('全部映射'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TmdbEpisodeHeader>(find.byType(TmdbEpisodeHeader))
          .episodeCount,
      2,
    );
    expect(_DetailState.aiRequests, aiBefore, reason: '切换季度不得重发 AI 推荐');
  });

  testWidgets('source rating links remain actionable', (tester) async {
    await pumpSource(tester);
    _scrollTo(tester, 900);
    await tester.pumpAndSettle();
    for (final key in ['tmdb', 'douban', 'imdb', 'rotten', 'metacritic']) {
      expect(find.byKey(ValueKey('detail-ratings-$key')), findsOneWidget);
    }
    // 外链的可点开行为已由 detail_ratings_section_test 锁死；这里只锁
    // 「评分外链区块与五个 chip 仍在真实详情页渲染」，不重复断言回调细节。
    expect(find.byKey(const ValueKey('detail-ratings-tmdb')), findsOneWidget);
  });

  testWidgets(
    'source detail keeps AI row at the bottom of the recommendation area',
    (tester) async {
      await pumpSource(tester);
      _scrollTo(tester, 1600);
      await _settleIo(tester);
      // 无缓存 → 进页面自动生成一次（与其它推荐行同时加载）。
      expect(_DetailState.aiRequests, 1);
      expect(find.byType(AiRecommendationSection), findsOneWidget);
      expect(find.byType(DetailRecommendations), findsOneWidget);
      expect(find.text('非AI推荐作品'), findsWidgets);
      expect(find.byType(DetailRatingsSection), findsOneWidget);
      // AI 行必须排在推荐区内、其它推荐行之后。
      final aiTop = tester
          .getTopLeft(find.byKey(const ValueKey('recommendation-heading-ai')))
          .dy;
      final doubanTop = tester
          .getTopLeft(
            find.byKey(const ValueKey('recommendation-heading-douban')),
          )
          .dy;
      expect(aiTop, greaterThan(doubanTop));
    },
  );

  testWidgets(
    'pure TMDB reached from real source retains links and non-AI rows without AI requests',
    (tester) async {
      await pumpSource(tester);
      await openPurePage(tester);
      _scrollTo(tester, 900);
      await tester.pumpAndSettle();
      for (final key in ['tmdb', 'douban', 'imdb', 'rotten', 'metacritic']) {
        expect(find.byKey(ValueKey('tmdb-only-ratings-$key')), findsOneWidget);
      }
      expect(
        find.byKey(const ValueKey('tmdb-only-ratings-tmdb')),
        findsOneWidget,
      );
      _scrollTo(tester, 1600);
      await _settleIo(tester);
      expect(find.byType(AiRecommendationSection), findsOneWidget);
      expect(_DetailState.aiRequests, greaterThanOrEqualTo(1));
      expect(find.byType(DetailRecommendations), findsOneWidget);
      expect(find.text('非AI推荐作品'), findsWidgets);
      expect(find.byType(DetailRatingsSection), findsOneWidget);
      expect(find.text('AI 推荐'), findsWidgets);
      expect(find.text('阅读简介'), findsNothing);
    },
  );
}
