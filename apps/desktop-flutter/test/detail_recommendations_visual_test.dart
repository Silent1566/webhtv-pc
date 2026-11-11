import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:webhtv_pc/core/detail_recommendation.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/tmdb_enrichment_service.dart';
import 'package:webhtv_pc/services/tmdb_identity_service.dart';
import 'package:webhtv_pc/services/tmdb_season_service.dart';
import 'package:webhtv_pc/services/tmdb_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/state/detail_recommendation_state.dart';
import 'package:webhtv_pc/state/tmdb_state.dart';
import 'package:webhtv_pc/ui/browse_pages.dart';
import 'package:webhtv_pc/services/recommendation_feedback_store.dart';
import 'package:webhtv_pc/ui/detail_recommendations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/tmdb_config.dart';
import 'package:webhtv_pc/core/tmdb_detail_model.dart';
import 'support/visual_test_fonts.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/core/tmdb_media.dart';
import 'package:webhtv_pc/ui/theme.dart';
import 'package:webhtv_pc/ui/tmdb_detail_view.dart';

const fixtureItems = [
  TmdbItem(
    tmdbId: 21,
    mediaType: TmdbMediaType.movie,
    title: '星际旅途',
    rating: 8.4,
  ),
  TmdbItem(
    tmdbId: 22,
    mediaType: TmdbMediaType.movie,
    title: '夜空之城',
    rating: 7.9,
  ),
];
// ---------------------------------------------------------------------------
// Task4 夹具：导航源回退页（推荐点击在当前站点没命中时的落点）
// ---------------------------------------------------------------------------

/// 当前站点：普通站点（indexs 不为 1）——回退页的导航源形态**不是**它给的，
/// 而是合成条目的空 vodId 让详情页跳过站源请求、按 TMDB 卡片渲染。
Site _fallbackSite() => Site(
  key: 'current',
  name: '当前站',
  type: 1,
  api: 'https://fixture.invalid/api.php/provide/vod',
);

http.Client _fallbackTmdbClient() => MockClient((request) async {
  final path = request.url.path;
  final Object body;
  if (path.endsWith('/search/multi')) {
    body = {
      'results': [
        {
          'id': 1399,
          'media_type': 'tv',
          'name': '导航剧',
          'first_air_date': '2024-01-01',
        },
      ],
    };
  } else if (path.endsWith('/tv/1399')) {
    body = {
      'id': 1399,
      'name': '导航剧',
      'overview': '一部用于视觉证据的剧集。',
      'seasons': [
        {'season_number': 1, 'episode_count': 2},
      ],
    };
  } else if (path.endsWith('/season/1')) {
    body = {
      'season_number': 1,
      'episodes': [
        {'episode_number': 1, 'name': '第一集', 'season_number': 1},
        {'episode_number': 2, 'name': '第二集', 'season_number': 1},
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

TmdbState _fallbackTmdbState() {
  TmdbConfig config() => const TmdbConfig(apiKey: 'fixture');
  final service = TmdbService(config: config, client: _fallbackTmdbClient());
  return TmdbState(
    config: config,
    service: service,
    identityService: TmdbIdentityService(
      config: config,
      service: service,
      store: InMemoryTmdbMatchStore(),
    ),
    seasonService: TmdbSeasonService(store: InMemoryTmdbSeasonStore()),
    enrichmentService: TmdbEnrichmentService(service: service, config: config),
  );
}

DetailRecommendationDependencies _fallbackDependencies() =>
    DetailRecommendationDependencies(
      feedback: RecommendationFeedbackStore(),
      loaders: {
        for (final row in RecommendationRow.values)
          row: (r) async => RecommendationPage(
            items: [
              for (final item in fixtureItems)
                RecommendationEntry(
                  item: item,
                  source: row == RecommendationRow.douban
                      ? RecommendationSource.douban
                      : RecommendationSource.tmdb,
                  reason: '根据观看历史',
                  doubanRating: 8.4,
                ),
            ],
            nextOffset: 12,
            hasMore: false,
          ),
      },
    );

/// 只替换站点 / TMDB 状态 / 推荐依赖的 AppState（其余走真实实现：
/// `loadDetail` 因为合成条目 vodId 为空而只跑 TMDB 链）。
class _FallbackState extends AppState {
  _FallbackState(
    Directory dir,
    this.dependencies, {
    required this.site,
    required this.tmdbState,
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
  final DetailRecommendationDependencies dependencies;
  final Site site;
  final TmdbState tmdbState;
  @override
  Site? get selectedSite => site;
  @override
  TmdbState get tmdb => tmdbState;
  @override
  DetailRecommendationDependencies get recommendationDependencies =>
      dependencies;
}

const _fallbackCardPrefix = 'tmdb-episode-card-nav-';

Finder _fallbackCards() => find.byWidgetPredicate(
  (widget) =>
      widget is OutlinedButton &&
      widget.key is ValueKey<String> &&
      (widget.key! as ValueKey<String>).value.startsWith(_fallbackCardPrefix),
);

void main() {
  setUpAll(loadVisualTestFonts);
  const pagingPhase = String.fromEnvironment('PAGING_CAPTURE_PHASE');
  for (final width in [1280.0, 420.0]) {
    testWidgets('horizontal paging capture $width', (tester) async {
      tester.view.physicalSize = Size(width, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final capture = GlobalKey();
      final offsets = <RecommendationRow, List<int>>{
        for (final row in RecommendationRow.values) row: [],
      };
      final dependencies = DetailRecommendationDependencies(
        feedback: RecommendationFeedbackStore(),
        loaders: {
          for (final row in RecommendationRow.values)
            row: (request) async {
              offsets[row]!.add(request.offset);
              return RecommendationPage(
                items: [
                  for (var i = request.offset; i < request.offset + 12; i++)
                    RecommendationEntry(
                      item: TmdbItem(
                        tmdbId: 100 + i,
                        mediaType: TmdbMediaType.movie,
                        title: '星空旅途 ${i + 1}',
                        subtitle: '2024 · 8.4',
                        rating: 8.4,
                      ),
                      source: row == RecommendationRow.douban
                          ? RecommendationSource.douban
                          : RecommendationSource.tmdb,
                      doubanRating: 8.4,
                    ),
                ],
                nextOffset: request.offset + 12,
                hasMore: request.offset == 0,
              );
            },
        },
      );
      final theme = buildAppTheme(Brightness.dark);
      await tester.pumpWidget(
        MaterialApp(
          theme: theme.copyWith(
            textTheme: theme.textTheme.apply(fontFamily: 'FixtureCJK'),
            textButtonTheme: TextButtonThemeData(
              style: theme.textButtonTheme.style?.copyWith(
                textStyle: const WidgetStatePropertyAll(
                  TextStyle(fontFamily: 'FixtureCJK', fontSize: 14),
                ),
              ),
            ),
          ),
          home: RepaintBoundary(
            key: capture,
            child: Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(16),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text('详情推荐 · 横向浏览'),
                      const Divider(),
                      DetailRecommendations(
                        dependencies: dependencies,
                        current: const RecommendationSeed(title: '固定作品：星空'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      Future<void> captureFrame(String position) async {
        if (pagingPhase.isEmpty) return;
        final boundary =
            capture.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File(
            '../../.local/recommendation-horizontal-paging/'
            '$pagingPhase-$width-$position.png',
          );
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }

      await captureFrame('start');
      for (final row in RecommendationRow.values) {
        final list = find.byKey(ValueKey('recommendation-row-${row.name}'));
        for (var i = 0; i < 2; i++) {
          await tester.drag(list, const Offset(-2200, 0));
          await tester.pumpAndSettle();
        }
        expect(offsets[row], pagingPhase == 'before' ? [0] : [0, 12]);
        expect(
          find.descendant(
            of: list,
            matching: find.text(
              pagingPhase == 'before' ? '星空旅途 12' : '星空旅途 24',
            ),
          ),
          findsOneWidget,
        );
      }
      expect(tester.takeException(), isNull);
      await captureFrame('right');
    });
  }
  for (final position in ['first', 'bottom']) {
    for (final phase in ['before', 'after']) {
      for (final page in ['source', 'pure']) {
        testWidgets('fixed dark bottom capture $position $phase $page', (
          tester,
        ) async {
          tester.view.physicalSize = const Size(1280, 800);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final capture = GlobalKey();
          final data = TmdbDetailData.fromItem(
            const TmdbItem(
              tmdbId: 20,
              mediaType: TmdbMediaType.movie,
              title: '固定作品：星空',
              subtitle: '2024',
            ),
          );
          await tester.pumpWidget(
            MaterialApp(
              theme: buildAppTheme(Brightness.dark).copyWith(
                textTheme: buildAppTheme(Brightness.dark).textTheme
                    .apply(fontFamily: 'FixtureCJK'),
                textButtonTheme: TextButtonThemeData(
                  style: buildAppTheme(Brightness.dark).textButtonTheme.style
                      ?.copyWith(
                        textStyle: const WidgetStatePropertyAll(
                          TextStyle(fontFamily: 'FixtureCJK', fontSize: 14),
                        ),
                      ),
                ),
              ),
              home: RepaintBoundary(
                key: capture,
                child: Scaffold(
                  body: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          page == 'source'
                              ? '站源详情 · 固定作品：星空 · 底部'
                              : 'TMDB 详情 · 固定作品：星空 · 底部',
                        ),
                        const Divider(),
                        Expanded(
                          child: SingleChildScrollView(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(
                                minHeight: 1400,
                              ),
                              child: TmdbDetailSections(
                                data: data,
                                recommendations: fixtureItems,
                                recommendationBottom: phase == 'before'
                                    ? null
                                    : DetailRecommendations(
                                        current: const RecommendationSeed(
                                          title: '固定作品：星空',
                                        ),
                                        dependencies: DetailRecommendationDependencies(
                                          feedback:
                                              RecommendationFeedbackStore(),
                                          loaders: {
                                            for (final row
                                                in RecommendationRow.values)
                                              row: (r) async => RecommendationPage(
                                                items: [
                                                  for (final item
                                                      in fixtureItems)
                                                    RecommendationEntry(
                                                      item: item,
                                                      source:
                                                          row ==
                                                              RecommendationRow
                                                                  .douban
                                                          ? RecommendationSource
                                                                .douban
                                                          : RecommendationSource
                                                                .tmdb,
                                                      reason: '根据观看历史',
                                                      doubanRating: 8.4,
                                                    ),
                                                ],
                                                nextOffset: 12,
                                                hasMore: position == 'bottom',
                                              ),
                                          },
                                        ),
                                      ),
                                videos: const [
                                  TmdbVideo(
                                    id: 'v',
                                    key: 'fixture',
                                    name: '固定预告片',
                                    site: 'YouTube',
                                    type: 'Trailer',
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          if (position == 'bottom') {
            tester
                .state<ScrollableState>(find.byType(Scrollable).first)
                .position
                .jumpTo(430);
          } else {
            await Scrollable.ensureVisible(
              tester.element(
                find.byKey(
                  ValueKey(
                    phase == 'before'
                        ? 'tmdb-section-recommendations'
                        : 'recommendation-heading-related',
                  ),
                ),
              ),
              alignment: 0,
            );
          }
          await tester.pumpAndSettle();
          if (position == 'bottom' && phase == 'after') {
            // 评分行必须仍完整落在横向卡片内。
            expect(find.textContaining('豆瓣 8.4'), findsWidgets);
            expect(find.text('加载更多'), findsNothing);
            for (final finder in [find.textContaining('豆瓣 8.4').first]) {
              final rect = tester.getRect(finder);
              expect(rect.top, greaterThanOrEqualTo(0));
              expect(rect.bottom, lessThanOrEqualTo(784));
            }
            final score = tester.getRect(find.textContaining('豆瓣 8.4').first);
            final row = tester.getRect(
              find.byKey(const ValueKey('recommendation-row-douban')),
            );
            expect(score.bottom, lessThanOrEqualTo(row.bottom));
          }
        });
      }
    }
  }

  testWidgets('nav-source fallback page (1280x800 dark)', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final dir = Directory.systemTemp.createTempSync('task4-visual-fallback');
    addTearDown(() => dir.deleteSync(recursive: true));
    final tmdb = _fallbackTmdbState();
    final state = _FallbackState(
      dir,
      _fallbackDependencies(),
      site: _fallbackSite(),
      tmdbState: tmdb,
    );
    addTearDown(state.dispose);
    await tester.runAsync(state.bootstrap);
    final capture = GlobalKey();
    final base = buildAppTheme(Brightness.dark);
    await tester.pumpWidget(
      MaterialApp(
        theme: base.copyWith(
          textTheme: base.textTheme.apply(fontFamily: 'FixtureCJK'),
          textButtonTheme: TextButtonThemeData(
            style: base.textButtonTheme.style?.copyWith(
              textStyle: const WidgetStatePropertyAll(
                TextStyle(fontFamily: 'FixtureCJK', fontSize: 14),
              ),
            ),
          ),
        ),
        home: RepaintBoundary(
          key: capture,
          child: DetailPage(
            state: state,
            vod: Vod(vodId: '', vodName: '导航剧'),
          ),
        ),
      ),
    );
    for (var i = 0; i < 120 && tmdb.episodesBySeason.isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    await tester.pump(const Duration(milliseconds: 200));
    expect(tmdb.hasMatch, isTrue, reason: '截图前提：合成条目已匹配到 TMDB 作品');
    expect(tmdb.episodesBySeason.keys.toSet(), {1});
    final cards = _fallbackCards();
    // 卡片在满屏 hero 之下：先滚到「两张卡都整块落在视口内」再截。
    for (var attempt = 0; attempt < 60; attempt++) {
      if (cards.evaluate().isNotEmpty) {
        final rect = tester.getRect(cards.first);
        if (rect.top >= 120 && rect.bottom <= 760) break;
      }
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -120));
      await tester.pump();
    }
    expect(cards, findsNWidgets(2), reason: '两张 TMDB 剧集卡片');
    final cardRect = tester.getRect(cards.first);
    expect(cardRect.top, greaterThanOrEqualTo(0));
    expect(cardRect.bottom, lessThanOrEqualTo(800));
    // 动作名只出现在卡片的 Tooltip 上（不是可见文本）：截图上的「换源播放」
    // 属于悬停提示，这里按 widget 断言它确实接的是换源而不是播放。
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Tooltip && (widget.message ?? '').startsWith('换源播放'),
      ),
      findsNWidgets(2),
      reason: '卡片是换源入口，不是播放入口',
    );
  });
}
