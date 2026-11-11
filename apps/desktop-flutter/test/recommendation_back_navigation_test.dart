import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/detail_recommendation.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/tmdb_config.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/services/site_service.dart';
import 'package:webhtv_pc/services/tmdb_service.dart';
import 'package:webhtv_pc/services/tmdb_recommendation_service.dart';
import 'package:webhtv_pc/state/detail_recommendation_state.dart';
import 'package:webhtv_pc/state/search_state.dart';
import 'package:webhtv_pc/ui/browse_pages.dart';
import 'package:webhtv_pc/ui/theme.dart';
import 'package:webhtv_pc/ui/tmdb_detail_page.dart';

import 'detail_recommendations_test.dart' as fixtures;
import 'support/visual_test_fonts.dart';

const _recommended = TmdbItem(
  tmdbId: 1399,
  mediaType: TmdbMediaType.tv,
  title: '导航剧',
);
final _site = Site(
  key: 'current',
  name: '当前站',
  type: 1,
  api: 'https://fixture.invalid',
);
final _originVod = Vod(vodId: 'origin', vodName: '原作品');

// Only the external site response is replaced; loadDetail/clearDetail stay real.
class _DetailFixture implements SiteService {
  Future<void>? delay;

  @override
  Future<SiteCallResult<SiteResult>> detail(
    Site site,
    String vodId, {
    VodIdentityHint? identity,
  }) async {
    await delay;
    return SiteCallResult(
      value: SiteResult(
        list: [
          Vod(
            vodId: vodId,
            vodName: '原作品',
            vodContent: '来源详情的介绍',
            vodPlayFrom: '原线路',
            vodPlayUrl: r'第1集$https://fixture.invalid/original.mp4',
            extra: {
              'recommendations': {
                'results': [
                  {'id': 1399, 'media_type': 'tv', 'name': '导航剧'},
                ],
              },
            },
          ),
        ],
      ),
      latency: Duration.zero,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

http.Client _tmdbClient() {
  final fallback = fixtures.recommendationTmdbClient();
  return MockClient((request) async {
    final path = request.url.path;
    if (path.endsWith('/search/multi') &&
        request.url.queryParameters['query'] == '原作品') {
      return http.Response(
        jsonEncode({
          'results': [
            {
              'id': 42,
              'media_type': 'tv',
              'name': '原作品',
              'first_air_date': '2024-01-01',
            },
          ],
        }),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }
    if (path.endsWith('/tv/42')) {
      return http.Response(
        jsonEncode({
          'id': 42,
          'name': '原作品',
          'seasons': [],
          'recommendations': {
            'results': [
              {'id': 1399, 'media_type': 'tv', 'name': '导航剧'},
            ],
          },
        }),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }
    return fallback.get(request.url);
  });
}

DetailRecommendationDependencies _dependencies() {
  final service = TmdbRecommendationService(
    TmdbService(
      config: () => const TmdbConfig(apiKey: 'fixture'),
      client: _tmdbClient(),
    ),
  );
  final dependencies = fixtures.deps(
    loader: (request) async => const RecommendationPage(
      items: [
        RecommendationEntry(
          item: _recommended,
          source: RecommendationSource.tmdb,
        ),
      ],
    ),
  );
  dependencies.loaders[RecommendationRow.related] = (request) =>
      service.related(
        current: request.current,
        detail: request.detail,
        sourceOnly: request.sourceOnly,
        offset: request.offset,
        pageSize: request.pageSize,
        blockedTitles: request.blockedTitles,
      );
  return dependencies;
}

class _BackState extends fixtures.SourceState {
  _BackState(Directory dir)
    : super(
        dir,
        _dependencies(),
        site: _site,
        tmdbState: fixtures.recommendationTmdbState(_tmdbClient()),
        tmdbFixture: TmdbService(
          config: () => const TmdbConfig(apiKey: 'fixture'),
          client: _tmdbClient(),
        ),
        overrideDetail: false,
      );

  final _service = _DetailFixture();
  int detailClears = 0;

  @override
  void clearDetail() {
    detailClears++;
    super.clearDetail();
  }

  MultiSiteSearchOutcome? _swapOutcome;

  @override
  Future<void> loadDetail(
    Vod vod, {
    SiteService? serviceOverride,
    Site? siteOverride,
  }) => super.loadDetail(
    vod,
    serviceOverride: _service,
    siteOverride: siteOverride,
  );

  @override
  MultiSiteSearchOutcome? get activeSearch => _swapOutcome;

  @override
  Future<MultiSiteSearchOutcome> searchAll(
    String keyword, {
    String? siteKey,
    String? group,
    int? maxConcurrency,
    Duration timeout = const Duration(seconds: 20),
    bool quick = false,
  }) async {
    _swapOutcome = MultiSiteSearchOutcome(
      runId: 1,
      keyword: keyword,
      results: [
        SiteSearchEntry(
          siteKey: 'playable',
          siteName: '播放站',
          result: SiteResult(
            list: [Vod(vodId: 'real', vodName: '导航剧')],
          ),
        ),
      ],
    )..finished = true;
    notifyListeners();
    return _swapOutcome!;
  }

  @override
  Future<List<VodPlayLine>> swapProbe({
    required String siteKey,
    required String vodId,
    String vodName = '',
  }) async => [
    VodPlayLine(
      flag: '真实线路',
      episodes: [
        VodEpisode(name: '第1集', url: 'https://fixture.invalid/real.mp4'),
      ],
    ),
  ];
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 80; i++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
}

Finder _card() => find.byKey(const ValueKey('tmdb-episode-card-nav--0'));
Finder _recommendation() =>
    find.byKey(const ValueKey('recommendation-related-tv:1399'));
Finder _pageScrollable() => find.byType(Scrollable).first;
ScrollPosition _position(WidgetTester tester) =>
    tester.state<ScrollableState>(_pageScrollable()).position;

Future<void> _reveal(WidgetTester tester, Finder target) async {
  for (var i = 0; i < 40; i++) {
    if (target.evaluate().isNotEmpty) {
      await Scrollable.ensureVisible(
        tester.element(target.first),
        alignment: 0.5,
      );
      await _settle(tester);
      return;
    }
    await tester.drag(_pageScrollable(), const Offset(0, -200));
    await _settle(tester);
  }
  expect(target, findsWidgets);
}

Future<({double offset, Offset cardPosition})> _openFallback(
  WidgetTester tester, {
  bool pure = false,
}) async {
  if (pure) {
    await _reveal(tester, find.byKey(const ValueKey('tmdb-open-detail')));
    await tester.tap(find.byKey(const ValueKey('tmdb-open-detail')));
    await _settle(tester);
    expect(find.byType(TmdbDetailPage), findsOneWidget);
  }
  await _reveal(tester, _recommendation());
  for (final row in ['related', 'tmdb', 'douban']) {
    expect(find.byKey(ValueKey('recommendation-row-$row')), findsOneWidget);
  }
  final offset = _position(tester).pixels;
  final cardPosition = tester.getTopLeft(_recommendation());
  await tester.tap(_recommendation());
  await _settle(tester);
  expect(tester.widget<DetailPage>(find.byType(DetailPage)).vod.vodId, isEmpty);
  await _reveal(tester, _card());
  expect(
    find.byKey(const ValueKey('tmdb-episode-card-nav--1')),
    findsOneWidget,
  );
  return (offset: offset, cardPosition: cardPosition);
}

Future<void> _dialog(WidgetTester tester) async {
  await tester.tap(_card());
  await _settle(tester);
  expect(find.text('需要换源播放'), findsOneWidget);
}

Future<void> _sheet(WidgetTester tester) async {
  await _dialog(tester);
  await tester.tap(find.byKey(const ValueKey('nav-source-swap-confirm')));
  await _settle(tester);
  expect(find.byKey(const ValueKey('source-swap-sheet')), findsOneWidget);
  expect(find.text('需要换源播放'), findsNothing);
}

Future<void> _capture(
  WidgetTester tester,
  GlobalKey key,
  String scenario,
) async {
  const phase = String.fromEnvironment('BACK_EVIDENCE_PHASE');
  if (phase.isEmpty) return;
  await tester.pump();
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('../../.local/task5-$phase-$scenario.png');
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  setUpAll(loadVisualTestFonts);

  Future<GlobalKey> setup(WidgetTester tester, {bool routed = false}) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final dir = Directory.systemTemp.createTempSync('task5-back');
    final state = _BackState(dir);
    addTearDown(() => dir.deleteSync(recursive: true));
    addTearDown(state.dispose);
    await tester.runAsync(state.bootstrap);
    final key = GlobalKey();
    final base = buildAppTheme(Brightness.dark);
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          theme: base.copyWith(
            textTheme: base.textTheme.apply(fontFamily: 'FixtureCJK'),
            appBarTheme: base.appBarTheme.copyWith(
              titleTextStyle: const TextStyle(
                fontFamily: 'FixtureCJK',
                fontSize: 20,
              ),
            ),
          ),
          debugShowCheckedModeBanner: false,
          home: routed
              ? Builder(
                  builder: (context) => Scaffold(
                    body: TextButton(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) =>
                              DetailPage(state: state, vod: _originVod),
                        ),
                      ),
                      child: const Text('打开原作品'),
                    ),
                  ),
                )
              : DetailPage(state: state, vod: _originVod),
        ),
      ),
    );
    await _settle(tester);
    if (routed) {
      await tester.tap(find.text('打开原作品'));
      await _settle(tester);
    }
    return key;
  }

  for (final escape in [false, true]) {
    testWidgets(
      'path a: ${escape ? "Esc" : "system back"} dismisses dialog only',
      (tester) async {
        final key = await setup(tester);
        await _openFallback(tester);
        final offset = _position(tester).pixels;
        final position = tester.getTopLeft(_card());
        await _dialog(tester);
        if (escape) {
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        } else {
          await tester.binding.handlePopRoute();
        }
        await _settle(tester);
        await _capture(tester, key, escape ? 'a-esc' : 'a-system');
        expect(find.text('需要换源播放'), findsNothing);
        expect(
          tester.widget<DetailPage>(find.byType(DetailPage)).vod.vodId,
          isEmpty,
        );
        expect(_card(), findsOneWidget);
        expect(_position(tester).pixels, closeTo(offset, 0.01));
        expect(tester.getTopLeft(_card()), position);
      },
    );
  }

  testWidgets('path b: back cancels open sheet without popping fallback', (
    tester,
  ) async {
    final key = await setup(tester);
    await _openFallback(tester);
    final offset = _position(tester).pixels;
    await _sheet(tester);
    await tester.binding.handlePopRoute();
    await _settle(tester);
    await _capture(tester, key, 'b');
    expect(find.byKey(const ValueKey('source-swap-sheet')), findsNothing);
    expect(find.text('需要换源播放'), findsNothing);
    expect(
      _card(),
      findsOneWidget,
      reason: 'One back dismisses only the open swap sheet',
    );
    expect(
      tester.widget<DetailPage>(find.byType(DetailPage)).vod.vodId,
      isEmpty,
    );
    expect(_position(tester).pixels, closeTo(offset, 0.01));
  });

  testWidgets(
    'path b: X closes sheet and next back leaves fallback exactly once',
    (tester) async {
      await setup(tester);
      await _openFallback(tester);
      await _sheet(tester);
      await tester.tap(find.byKey(const ValueKey('source-swap-close')));
      await _settle(tester);
      expect(_card(), findsOneWidget);
      expect(find.byKey(const ValueKey('source-swap-sheet')), findsNothing);
      expect(find.text('需要换源播放'), findsNothing);
      await tester.binding.handlePopRoute();
      await _settle(tester);
      expect(
        tester.widget<DetailPage>(find.byType(DetailPage)).vod.vodId,
        'origin',
      );
      expect(_card(), findsNothing);
    },
  );

  for (final exit in ['app-bar', 'system', 'remove']) {
    testWidgets('restore pending: $exit abandons original safely', (
      tester,
    ) async {
      await setup(tester, routed: true);
      final state =
          tester.widget<DetailPage>(find.byType(DetailPage)).state
              as _BackState;
      final before = await _openFallback(tester);
      final gate = Completer<void>();
      state._service.delay = gate.future;
      await tester.binding.handlePopRoute();
      await _settle(tester);
      expect(
        _position(tester).pixels,
        closeTo(before.offset, 0.01),
        reason:
            'The original layout must stay intact even while reload is pending',
      );
      expect(tester.getTopLeft(_recommendation()), before.cardPosition);
      if (exit == 'system') {
        await tester.binding.handlePopRoute();
      } else if (exit == 'remove') {
        final route = ModalRoute.of(tester.element(find.byType(DetailPage)))!;
        route.navigator!.removeRoute(route);
      } else {
        await tester.tap(find.byTooltip('返回'));
      }
      await _settle(tester);
      expect(find.text('打开原作品'), findsOneWidget);
      expect(find.byType(DetailPage), findsNothing);
      gate.complete();
      await _settle(tester);
      expect(
        state.detailResult,
        isNull,
        reason: 'Late restore must not repopulate global detail after leaving original',
      );
      expect(state.selectedVod, isNull);
      expect(
        state.detailClears,
        1,
        reason: 'The abandoned original must clear exactly once',
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('abandoning old restore does not clear a newer detail route', (
    tester,
  ) async {
    await setup(tester, routed: true);
    final state =
        tester.widget<DetailPage>(find.byType(DetailPage)).state as _BackState;
    await _openFallback(tester);
    final gate = Completer<void>();
    state._service.delay = gate.future;
    await tester.binding.handlePopRoute();
    await _settle(tester);
    final original = ModalRoute.of(tester.element(find.byType(DetailPage)))!;
    unawaited(
      original.navigator!.push(
        MaterialPageRoute<void>(
          builder: (_) => DetailPage(
            state: state,
            vod: Vod(vodId: 'next', vodName: '下一作品'),
          ),
        ),
      ),
    );
    await _settle(tester);
    original.navigator!.removeRoute(original);
    await _settle(tester);
    expect(
      state.selectedVod?.vodId,
      'next',
      reason: 'Removing the old page must not clear a newer page detail slot',
    );
    expect(state.detailClears, 0);
    gate.complete();
    await _settle(tester);
    expect(state.detailResult?.list.first.vodId, 'next');
    expect(tester.takeException(), isNull);
  });

  for (final pure in [false, true]) {
    for (final system in [false, true]) {
      testWidgets(
        'paths c+d: ${pure ? "pure" : "source"} origin restored after merge and ${system ? "system" : "app-bar"} back',
        (tester) async {
          final key = await setup(tester);
          final before = await _openFallback(tester, pure: pure);
          await _sheet(tester);
          await tester.tap(
            find.byKey(const ValueKey('source-swap-check-playable-real')),
          );
          await _settle(tester);
          await tester.tap(find.byKey(const ValueKey('source-swap-commit')));
          await _settle(tester);
          expect(find.text('并入 1 条线路'), findsOneWidget);
          await tester.tap(find.byKey(const ValueKey('source-swap-commit')));
          await _settle(tester);
          expect(find.byKey(const ValueKey('source-swap-sheet')), findsNothing);
          await _reveal(
            tester,
            find.byKey(const ValueKey('tmdb-line-selector')),
          );
          expect(
            find.byKey(const ValueKey('tmdb-line-selector')),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('tmdb-line-播放站 · 真实线路')),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('detail-hero-play')),
            findsOneWidget,
          );
          if (system) {
            await tester.binding.handlePopRoute();
          } else {
            await tester.tap(find.byTooltip('返回'));
          }
          await _settle(tester);
          await _capture(
            tester,
            key,
            'cd-${pure ? "pure" : "source"}-${system ? "system" : "appbar"}',
          );
          expect(find.byKey(const ValueKey('source-swap-sheet')), findsNothing);
          expect(find.text('需要换源播放'), findsNothing);
          if (pure) {
            expect(find.byType(TmdbDetailPage), findsOneWidget);
          } else {
            expect(
              tester.widget<DetailPage>(find.byType(DetailPage)).vod.vodId,
              'origin',
            );
          }
          for (final row in ['related', 'tmdb', 'douban']) {
            expect(
              find.byKey(ValueKey('recommendation-row-$row')),
              findsOneWidget,
              reason: 'The originating page must retain all three recommendation rows',
            );
          }
          expect(_recommendation(), findsOneWidget);
          expect(_position(tester).pixels, closeTo(before.offset, 0.01));
          expect(tester.getTopLeft(_recommendation()), before.cardPosition);
          if (!pure) {
            await tester.drag(_pageScrollable(), const Offset(0, 2200));
            await _settle(tester);
            await _reveal(
              tester,
              find.byKey(const ValueKey('detail-hero-play')),
            );
            expect(
              find.byKey(const ValueKey('detail-hero-play')),
              findsOneWidget,
            );
            expect(find.textContaining('来源详情的介绍'), findsWidgets);
            await _reveal(tester, find.byKey(const ValueKey('tmdb-line-原线路')));
            expect(find.byKey(const ValueKey('tmdb-line-原线路')), findsOneWidget);
          }
        },
      );
    }
  }
}
