import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/detail_recommendation.dart';
import 'package:webhtv_pc/core/home_feed.dart';
import 'package:webhtv_pc/core/tmdb_config.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/douban_recommendation_service.dart';
import 'package:webhtv_pc/services/search_suggest_service.dart';
import 'package:webhtv_pc/services/storage.dart';
import 'package:webhtv_pc/services/tmdb_service.dart';
import 'package:webhtv_pc/services/tmdb_recommendation_service.dart';
import 'package:webhtv_pc/services/recommendation_feedback_store.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/state/detail_recommendation_state.dart';
import 'package:webhtv_pc/ui/home_cards.dart';
import 'package:webhtv_pc/ui/home_page.dart';

import 'support/detail_test_seams.dart';

class _State extends AppState {
  _State(
    Directory dir,
    this.metadata,
    this.dependencies,
    this.suggest,
    MemoryOnlyLogService logger,
  ) : super(
        paths: AppPaths.resolve(
          overrides: {
            'config': dir.path,
            'data': dir.path,
            'cache': dir.path,
            'state': dir.path,
          },
        ),
        log: logger,
      );
  final TmdbService metadata;
  final DetailRecommendationDependencies dependencies;
  final SearchSuggestService suggest;
  DateTime now = DateTime(2026, 1, 1);
  String source = 'first';
  bool seedsEnabled = true;
  Future<List<SearchSuggestItem>> Function(HotRankCategory)? hotOverride;
  @override
  String get activeSourceKey => source;
  @override
  Future<List<SearchSuggestItem>> homeHotRank(HotRankCategory category) =>
      hotOverride?.call(category) ?? super.homeHotRank(category);
  @override
  DateTime Function() get heroSessionClock =>
      () => now;
  @override
  TmdbService get tmdbService => metadata;
  @override
  DetailRecommendationDependencies get recommendationDependencies =>
      dependencies;
  @override
  SearchSuggestService get searchSuggestService => suggest;
  @override
  bool get externalMetaEnabled => false;
  @override
  List<PlaybackHistory> recentHistory({int limit = 100, String? sourceKey}) => seedsEnabled ? [
    PlaybackHistory(
      id: 1,
      siteKey: 'fixture',
      vodId: 'seed',
      vodName: 'private-seed-title',
      tmdbId: 1,
      mediaType: 'movie',
      flag: 'line',
      episodeName: 'one',
      episodeId: 'one',
      positionMs: 0,
      durationMs: 100000,
      updatedAt: 1,
      completed: true,
    ),
  ] : const [];
}

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);
Finder _rail(HomeRailKind kind) =>
    find.byWidgetPredicate((w) => w is HomeRailView && w.rail.kind == kind);
Future<void> _show(WidgetTester tester, HomeRailKind kind) async {
  final outer = tester
      .state<ScrollableState>(
        find
            .descendant(
              of: find.byKey(const ValueKey('home-scroll')),
              matching: find.byType(Scrollable),
            )
            .first,
      )
      .position;
  outer.jumpTo(0);
  await tester.pumpAndSettle();
  for (var i = 0; i < 12 && _rail(kind).evaluate().isEmpty; i++) {
    await tester.drag(
      find.byKey(const ValueKey('home-scroll')),
      const Offset(0, -300),
    );
    await tester.pumpAndSettle();
  }
  await tester.ensureVisible(_rail(kind));
  await tester.pumpAndSettle();
}

Future<void> _end(WidgetTester tester, HomeRailKind kind) async {
  await _show(tester, kind);
  final list = find.descendant(
    of: _rail(kind),
    matching: find.byType(ListView),
  );
  final position = tester
      .state<ScrollableState>(
        find.descendant(of: list, matching: find.byType(Scrollable)),
      )
      .position;
  position.jumpTo(position.maxScrollExtent - 60);
  await tester.pump();
  await tester.drag(list, const Offset(-180, 0));
  await tester.pumpAndSettle();
}

int _count(WidgetTester tester, HomeRailKind kind) =>
    tester.widget<HomeRailView>(_rail(kind)).rail.items.length;

void main() {
  late Directory dir;
  late MemoryOnlyLogService log;
  late TmdbService metadata;
  late TmdbRecommendationService tmdb;
  late DoubanRecommendationService douban;
  late DoubanRecommendationService Function() makeDouban;
  late SearchSuggestService suggest;
  late _State state;
  final remote = <Uri>[];
  var failPage2 = false;
  var rankCount = 30;
  var rankOverlap = 0;
  var rankFailure = false;
  setUp(() {
    dir = Directory('../../.local/home-pagination/diagnostics/widget-state')
        .absolute;
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    dir.createSync(recursive: true);
    log = MemoryOnlyLogService();
    remote.clear();
    failPage2 = false;
    rankCount = 30;
    rankOverlap = 0;
    rankFailure = false;
    metadata = TmdbService(
      config: () => const TmdbConfig(
        apiKey: 'private-test-credential',
        apiBase: 'https://api.fixture.invalid/3',
      ),
      client: MockClient((request) async {
        remote.add(request.url);
        if (request.url.path.endsWith('/recommendations')) {
          final page = int.parse(request.url.queryParameters['page'] ?? '1');
          if (page == 2 && failPage2) {
            throw const SocketException(
              'secret URL https://private.invalid?api_key=private-test-credential',
            );
          }
          return _json({
            'results': page > 3
                ? []
                : [
                    for (var i = 0; i < 12; i++)
                      {
                        'id': 100 + (page - 1) * 12 + i,
                        'title': 'candidate-${(page - 1) * 12 + i}',
                      },
                  ],
          });
        }
        if (request.url.path.endsWith('/similar') ||
            request.url.path.contains('/search/')) {
          return _json({'results': []});
        }
        final id = int.tryParse(request.url.pathSegments.last) ?? 1;
        return _json({
          'id': id,
          'title': id == 1 ? 'private-seed-title' : 'candidate-${id - 100}',
        });
      }),
    );
    tmdb = TmdbRecommendationService(metadata);
    makeDouban = () => DoubanRecommendationService(
      cacheDirectory: Directory('${dir.path}/douban'),
      delay: (_) async {},
      client: MockClient((request) async {
        remote.add(request.url);
        if (request.url.path.endsWith('subject_suggest')) {
          return _json([
            {'id': '1', 'title': 'private-seed-title', 'type': 'movie'},
          ]);
        }
        return _json({
          'subjects': [
            for (var i = 0; i < 36; i++)
              {
                'id': '${1000 + i}',
                'title': 'db-$i',
                'type': 'movie',
                'rating': {'value': 8},
              },
          ],
        });
      }),
    );
    douban = makeDouban();
    suggest = SearchSuggestService(
      log: log,
      client: MockClient((request) async {
        remote.add(request.url);
        if (rankFailure) throw const SocketException('rank unavailable');
        return _json({
          'data': [
            for (var i = 0; i < rankCount; i++)
              {
                'title': i < rankOverlap
                    ? 'candidate-$i'
                    : 'rank-${request.url.queryParameters['cat']}-$i',
              },
          ],
        });
      }),
    );
    state = _State(
      dir,
      metadata,
      DetailRecommendationDependencies(
        feedback: RecommendationFeedbackStore(),
        loaders: {
          RecommendationRow.tmdb: (r) => tmdb.personal(
            current: r.current,
            history: r.history,
            offset: r.offset,
            pageSize: r.pageSize,
            blockedTitles: r.blockedTitles,
            diagnostic: r.diagnostic,
          ),
          RecommendationRow.douban: (r) => douban.personal(
            current: r.current,
            history: r.history,
            offset: r.offset,
            pageSize: r.pageSize,
            blockedTitles: r.blockedTitles,
          ),
        },
      ),
      suggest,
      log,
    );
  });
  tearDown(() {
    state.dispose();
    tmdb.close();
    douban.close();
    suggest.close();
    metadata.close();
  });
  void saveTrace(String name) {
    if (Platform.environment['HOME_PAGING_TRACE'] != '1') return;
    final entries = log.entries
        .where((e) => e.scope == 'home-pagination')
        .map((e) => e.line)
        .toList();
    File('../../.local/home-pagination/diagnostics/trace-$name.log')
        .writeAsStringSync(entries.join('\n'));
    debugPrint('HOME-PAGING-TRACE name=$name events=${entries.length}');
  }

  Future<void> mount(WidgetTester tester) async {
    douban.close();
    douban = makeDouban();
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomePage(
            state: state,
            onOpenBrowse: () {},
            onOpenHistory: () {},
            onOpenFollowing: () {},
            onImportConfig: () {},
            onSearch: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'real TMDB source lazily requests page2 page3 and appends three UI pages',
    (tester) async {
      await mount(tester);
      await _show(tester, HomeRailKind.recommendTmdb);
      expect(_count(tester, HomeRailKind.recommendTmdb), 12);
      await _end(tester, HomeRailKind.recommendTmdb);
      expect(_count(tester, HomeRailKind.recommendTmdb), 24);
      await _end(tester, HomeRailKind.recommendTmdb);
      expect(_count(tester, HomeRailKind.recommendTmdb), 36);
      await _end(tester, HomeRailKind.recommendTmdb);
      expect(_count(tester, HomeRailKind.recommendTmdb), 36);
      expect(
        remote
            .where((u) => u.path.endsWith('/recommendations'))
            .map((u) => u.queryParameters['page']),
        ['1', '2', '3', '4'],
      );
      final traces = log.entries
          .where((e) => e.scope == 'home-pagination')
          .map((e) => e.message)
          .join('\n');
      expect(traces, contains('event=source_page'));
      expect(traces, contains('reason=streams_depleted'));
      expect(traces, isNot(contains('upstream_exhausted')));
      expect(traces, isNot(contains('private-test-credential')));
      expect(traces, isNot(contains('private-seed-title')));
      saveTrace('tmdb');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'real Douban candidate snapshot appends three pages and logs its finite pool',
    (tester) async {
      await mount(tester);
      await _show(tester, HomeRailKind.recommendDouban);
      expect(_count(tester, HomeRailKind.recommendDouban), 12);
      await _end(tester, HomeRailKind.recommendDouban);
      expect(_count(tester, HomeRailKind.recommendDouban), 24);
      await _end(tester, HomeRailKind.recommendDouban);
      expect(_count(tester, HomeRailKind.recommendDouban), 36);
      expect(
        log.entries.map((e) => e.message).join('\n'),
        contains('reason=subject_pool_depleted'),
      );
      saveTrace('douban');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final kind in [
    HomeRailKind.hotTv,
    HomeRailKind.hotMovie,
    HomeRailKind.hotVariety,
  ]) {
    testWidgets(
      '${kind.name} keeps the full fixed rank snapshot without remote repeats',
      (tester) async {
        await mount(tester);
        await _show(tester, kind);
        expect(_count(tester, kind), 30);
        await _end(tester, kind);
        expect(_count(tester, kind), 30);
        await _end(tester, kind);
        expect(_count(tester, kind), 30);
        await _end(tester, kind);
        expect(_count(tester, kind), 30);
        expect(remote.where((u) => u.path == '/v1/rank').length, 3);
        expect(
          log.entries.map((e) => e.message).join('\n'),
          contains('pagination=not_available'),
        );
        saveTrace(kind.name);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'larger rank fixture preserves full home snapshot while search limit remains30',
    (tester) async {
      rankCount = 45;
      await mount(tester);
      for (var i = 0; i < 3; i++) {
        await _end(tester, HomeRailKind.hotTv);
      }
      expect(_count(tester, HomeRailKind.hotTv), 45);
      expect((await state.searchHotRank(HotRankCategory.series)).length, 30);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'pagination diagnostic events are correlated and do not spam rebuilds',
    (tester) async {
      await mount(tester);
      await _end(tester, HomeRailKind.recommendDouban);
      final before = log.entries
          .where((e) => e.scope == 'home-pagination')
          .length;
      for (var i = 0; i < 30; i++) {
        state.homeHeroSession.startBackgroundLoads();
        await tester.pump();
      }
      final after = log.entries
          .where((e) => e.scope == 'home-pagination')
          .length;
      expect(after - before, lessThanOrEqualTo(2));
      final traces = log.entries
          .where((e) => e.scope == 'home-pagination')
          .map((e) => e.message)
          .join('\n');
      expect(traces, contains('event=ui_trigger'));
      expect(traces, contains('trigger=forward_drag'));
      expect(traces, contains('event=request_start'));
      expect(traces, contains('event=page_applied'));
      expect(traces, contains('request='));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  test('personal continuation failure keeps source cursor retryable and retry reaches real page2', () async {
    const seed = RecommendationSeed(
      title: 'private-seed-title',
      tmdbId: 1,
      mediaType: TmdbMediaType.movie,
    );
    final first = await tmdb.personal(current: seed);
    expect(first.items.length, 12);
    failPage2 = true;
    final failed = await tmdb.personal(current: seed, offset: 12);
    expect(failed.retryable, isTrue);
    expect(failed.hasMore, isTrue);
    expect(failed.endReason, 'source_failed_retryable');
    failPage2 = false;
    final retried = await tmdb.personal(current: seed, offset: 12);
    expect(retried.items.map((e) => e.item.tmdbId), [
      for (var i = 112; i < 124; i++) i,
    ]);
    expect(retried.retryable, isFalse);
  });

  test('personal cached continuation restores real source page cursors across provider restart', () async {
    const seed = RecommendationSeed(
      title: 'private-seed-title',
      tmdbId: 1,
      mediaType: TmdbMediaType.movie,
    );
    final cache = Directory('${dir.path}/restart');
    final initial = TmdbRecommendationService(metadata, cacheDirectory: cache);
    await initial.personal(current: seed);
    await initial.personal(current: seed, offset: 12);
    initial.close();
    final restored = TmdbRecommendationService(metadata, cacheDirectory: cache);
    final page = await restored.personal(current: seed, offset: 24);
    expect(page.items.map((e) => e.item.tmdbId), [
      for (var i = 124; i < 136; i++) i,
    ]);
    expect(
      remote
          .where((u) => u.path.endsWith('/recommendations'))
          .map((u) => u.queryParameters['page']),
      ['1', '2', '3'],
    );
    restored.close();
  });

  test('repeated personal source page stops that stream without scanning arbitrary later pages', () async {
    final calls = <int>[];
    final service = TmdbService(
      config: () => const TmdbConfig(apiKey: 'fixture'),
      client: MockClient((r) async {
        if (r.url.path.endsWith('/recommendations')) {
          calls.add(int.parse(r.url.queryParameters['page']!));
          return _json({
            'results': [
              for (var i = 0; i < 12; i++)
                {'id': 500 + i, 'title': 'repeated-$i'},
            ],
          });
        }
        return _json(
          r.url.path.endsWith('/similar')
              ? {'results': []}
              : {'id': 1, 'title': 'seed'},
        );
      }),
    );
    final provider = TmdbRecommendationService(service);
    const seed = RecommendationSeed(
      title: 'seed',
      tmdbId: 1,
      mediaType: TmdbMediaType.movie,
    );
    await provider.personal(current: seed);
    final page = await provider.personal(current: seed, offset: 12);
    expect(calls, [1, 2]);
    expect(page.items, isEmpty);
    expect(page.hasMore, isFalse);
    provider.close();
    service.close();
  });

  test('Douban blocked source is retryable and never claims finite pool exhaustion', () async {
    final provider = DoubanRecommendationService(
      cacheDirectory: Directory('${dir.path}/blocked'),
      client: MockClient((_) async => _json({}, 429)),
    );
    final page = await provider.personal(
      current: const RecommendationSeed(title: 'seed'),
    );
    expect(page.retryable, isTrue);
    expect(page.endReason, 'blocked_retryable');
    expect(page.endReason, isNot(contains('depleted')));
    provider.close();
  });

  test('aggregated watched pages retain last source outcome and report each raw provider page', () async {
    final offsets = <int>[];
    final result = await loadUnwatchedRecommendationPage(
      watched: state.dependencies.watched,
      request: const RecommendationRequest(
        current: RecommendationSeed(title: 'seed'),
      ),
      loader: (r) async => RecommendationPage(
        items: [],
        nextOffset: 12,
        hasMore: false,
        endReason: 'subject_pool_depleted',
        poolCount: 12,
      ),
      onPage: (offset, _) => offsets.add(offset),
    );
    expect(offsets, [0]);
    expect(result.endReason, 'subject_pool_depleted');
    expect(result.poolCount, 12);
  });

  testWidgets(
    'failed horizontal wheel burst retries only once per gesture and never says all loaded',
    (tester) async {
      await mount(tester);
      failPage2 = true;
      await _show(tester, HomeRailKind.recommendTmdb);
      final position = tester
          .state<ScrollableState>(
            find.descendant(
              of: _rail(HomeRailKind.recommendTmdb),
              matching: find.byType(Scrollable),
            ),
          )
          .position;
      position.jumpTo(position.maxScrollExtent);
      await tester.pumpAndSettle();
      for (var i = 0; i < 5; i++) {
        await tester.sendEventToBinding(
          PointerScrollEvent(
            position: tester.getCenter(_rail(HomeRailKind.recommendTmdb)),
            scrollDelta: const Offset(100, 0),
          ),
        );
        await tester.pumpAndSettle();
      }
      expect(
        remote
            .where(
              (u) =>
                  u.path.endsWith('/recommendations') &&
                  u.queryParameters['page'] == '2',
            )
            .length,
        1,
      );
      expect(
        state.homeHeroSession.recommendationError(RecommendationRow.tmdb),
        isNotNull,
      );
      expect(
        state.homeHeroSession.recommendationHasMore(RecommendationRow.tmdb),
        isTrue,
      );
      failPage2 = false;
      await _end(tester, HomeRailKind.recommendTmdb);
      expect(_count(tester, HomeRailKind.recommendTmdb), 24);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'both personal terminal outcomes remain available after releasing provider lease',
    (tester) async {
      await mount(tester);
      for (var i = 0; i < 3; i++) {
        await state.homeHeroSession.loadMoreRecommendations(
          RecommendationRow.tmdb,
        );
        await tester.pumpAndSettle();
      }
      for (var i = 0; i < 2; i++) {
        await state.homeHeroSession.loadMoreRecommendations(
          RecommendationRow.douban,
        );
        await tester.pumpAndSettle();
      }
      expect(
        state.homeHeroSession.recommendationHasMore(RecommendationRow.tmdb),
        isFalse,
      );
      expect(
        state.homeHeroSession.recommendationHasMore(RecommendationRow.douban),
        isFalse,
      );
      expect(state.dependencies.isLeased, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'fixed hot snapshot display is not suppressed by an unrelated slow personal provider',
    (tester) async {
      final pending = Completer<RecommendationPage>();
      state.dependencies.loaders[RecommendationRow.douban] = (_) =>
          pending.future;
      await mount(tester);
      await _end(tester, HomeRailKind.hotTv);
      expect(_count(tester, HomeRailKind.hotTv), 30);
      pending.complete(const RecommendationPage());
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'fixed hot snapshot log reports visible rows after cross-source filtering',
    (tester) async {
      rankOverlap = 5;
      await mount(tester);
      await _end(tester, HomeRailKind.hotTv);
      expect(_count(tester, HomeRailKind.hotTv), 25);
      await _end(tester, HomeRailKind.hotTv);
      expect(_count(tester, HomeRailKind.hotTv), 25);
      final events = log.entries
          .where(
            (e) => e.message.contains('event=rail_projection provider=hot_series'),
          )
          .map((e) => e.message)
          .toList();
      expect(events.last, contains('visibleCount=25'));
      expect(events.last, contains('filteredCount=5'));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'failed hot refresh keeps previous data but never labels failure as all loaded',
    (tester) async {
      await mount(tester);
      await _end(tester, HomeRailKind.hotTv);
      await _end(tester, HomeRailKind.hotTv);
      rankFailure = true;
      state.now = state.now.add(const Duration(hours: 7));
      state.homeHeroSession.startBackgroundLoads();
      await tester.pumpAndSettle();
      expect(log.entries.map((e) => e.message).join('\n'), contains('reason=fetch_failed'));
      expect(find.textContaining('全部加载'), findsNothing);
      expect(state.homeHeroSession.hotRows(HotRankCategory.series)!.length, 30);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test('partial personal page progress survives cache restart without reordering published prefix', () async {
    var fail = false;
    final service = TmdbService(
      config: () => const TmdbConfig(
        apiKey: 'fixture',
        apiBase: 'https://api.fixture.invalid/3',
      ),
      client: MockClient((r) async {
        final page = int.parse(r.url.queryParameters['page'] ?? '1');
        if (r.url.path.endsWith('/recommendations')) {
          if (page == 2 && fail) throw const SocketException('offline');
          return _json({
            'results': page > 2
                ? []
                : [
                    for (var i = 0; i < 12; i++)
                      {
                        'id': 100 + (page - 1) * 12 + i,
                        'title': 'r-${(page - 1) * 12 + i}',
                      },
                  ],
          });
        }
        if (r.url.path.endsWith('/similar')) {
          return _json({
            'results': page > 2
                ? []
                : [
                    for (var i = 0; i < 12; i++)
                      {
                        'id': 300 + (page - 1) * 12 + i,
                        'title': 's-${(page - 1) * 12 + i}',
                      },
                  ],
          });
        }
        return _json({'id': 1, 'title': 'seed'});
      }),
    );
    const seed = RecommendationSeed(
      title: 'seed',
      tmdbId: 1,
      mediaType: TmdbMediaType.movie,
    );
    final cache = Directory('${dir.path}/partial');
    final initial = TmdbRecommendationService(service, cacheDirectory: cache);
    await initial.personal(current: seed);
    await initial.personal(current: seed, offset: 12);
    fail = true;
    final partial = await initial.personal(current: seed, offset: 24);
    expect(partial.items.map((e) => e.item.tmdbId), [
      for (var i = 312; i < 324; i++) i,
    ]);
    expect(partial.retryable, isTrue);
    initial.close();
    fail = false;
    final restored = TmdbRecommendationService(service, cacheDirectory: cache);
    final recovered = await restored.personal(current: seed, offset: 36);
    expect(recovered.items.map((e) => e.item.tmdbId), [
      for (var i = 112; i < 124; i++) i,
    ]);
    restored.close();
    service.close();
  });

  test('hot cache log distinguishes full snapshot from public local cap and avoids repeat network', () async {
    var calls = 0;
    final provider = SearchSuggestService(
      log: log,
      cacheDir: '${dir.path}/cache-rank',
      client: MockClient((_) async {
        calls++;
        return _json({
          'data': [
            for (var i = 0; i < 45; i++) {'title': 'row-$i'},
          ],
        });
      }),
    );
    expect((await provider.hotRank(HotRankCategory.movie)).length, 30);
    expect(provider.hotSnapshot(HotRankCategory.movie)!.length, 45);
    expect((await provider.hotRank(HotRankCategory.movie)).length, 30);
    expect(calls, 1);
    expect(provider.hotOutcome(HotRankCategory.movie), 'fresh_cache');
    final trace = log.entries.map((e) => e.message).join('\n');
    expect(trace, contains('source=fresh_cache'));
    expect(trace, contains('truncated=local_limit'));
    saveTrace('hot-local-cap');
    provider.close();
  });

  test('disabled TMDB and unknown Douban responses are not reported as catalogue exhaustion', () async {
    final off = TmdbService(
      config: () => const TmdbConfig(),
      client: MockClient((_) async => _json({})),
    );
    final disabled = TmdbRecommendationService(off);
    final page = await disabled.personal(
      current: const RecommendationSeed(title: 'seed'),
    );
    expect(page.endReason, 'disabled');
    final unknown = DoubanRecommendationService(
      cacheDirectory: Directory('${dir.path}/unknown'),
      client: MockClient(
        (_) async => _json({'error': 'private-response-payload'}),
      ),
    );
    final result = await unknown.personal(
      current: const RecommendationSeed(title: 'seed'),
    );
    expect(result.retryable, isTrue);
    expect(result.endReason, 'source_failed_retryable');
    disabled.close();
    off.close();
    unknown.close();
  });

  testWidgets('homepage hides completion explanations while retaining source diagnostics', (tester) async {
    await mount(tester);
    for (var i = 0; i < 3; i++) {
      await _end(tester, HomeRailKind.recommendTmdb);
    }
    await _end(tester, HomeRailKind.recommendDouban);
    await _end(tester, HomeRailKind.recommendDouban);
    await _end(tester, HomeRailKind.hotTv);
    await _end(tester, HomeRailKind.hotTv);
    expect(find.textContaining('已加载完'), findsNothing);
    expect(find.textContaining('全部加载'), findsNothing);
    expect(find.textContaining('非全站上限'), findsNothing);
    expect(find.byTooltip(RegExp('快照或相关流|API总量上限')), findsNothing);
    final trace = log.entries.map((e) => e.message).join('\n');
    expect(trace, contains('reason=streams_depleted'));
    expect(trace, contains('reason=subject_pool_depleted'));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('snapshot-only hot rails show all existing rows without fabricated local pages', (tester) async {
    await mount(tester);
    for (final kind in [HomeRailKind.hotTv, HomeRailKind.hotMovie, HomeRailKind.hotVariety]) {
      await _show(tester, kind);
      expect(_count(tester, kind), 30);
      final original = tester.widget<HomeRailView>(_rail(kind)).rail.items.map((item) => item.key).toList();
      await _end(tester, kind);
      expect(_count(tester, kind), 30);
      expect(tester.widget<HomeRailView>(_rail(kind)).rail.items.map((item) => item.key), original);
      expect(log.entries.where((e) => e.message.contains('mode=local_snapshot')), isEmpty);
    }
    expect(remote.where((uri) => uri.path == '/v1/rank').length, 3);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('closed source is diagnosed without adding page explanations', (tester) async {
    state.dependencies.loaders[RecommendationRow.douban] = (_) async => const RecommendationPage(endReason: 'closed');
    await mount(tester);
    expect(log.entries.map((e) => e.message).join('\n'), contains('reason=closed'));
    expect(find.textContaining('推荐来源已关闭'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('throwing fixed hot refresh retains cards and only logs failure', (tester) async {
    await mount(tester);
    await _end(tester, HomeRailKind.hotTv);
    await _end(tester, HomeRailKind.hotTv);
    final before = state.homeHeroSession.hotRows(HotRankCategory.series)!.map((item) => item.title).toList();
    state.seedsEnabled = false;
    state.hotOverride = (_) async => throw StateError('private failure payload');
    state.now = state.now.add(const Duration(hours: 7));
    state.homeHeroSession.startBackgroundLoads();
    await tester.pumpAndSettle();
    expect(state.homeHeroSession.hotRows(HotRankCategory.series)!.map((item) => item.title), before);
    expect(_count(tester, HomeRailKind.hotTv), 30);
    expect(find.textContaining('榜单加载失败'), findsNothing);
    expect(find.textContaining('全部加载'), findsNothing);
    final errors = log.entries.where((entry) => entry.scope == 'home-pagination' && entry.message.contains('event=request_error')).map((entry) => entry.message).join('\n');
    expect(errors, contains('provider=hot_series'));
    expect(errors, contains('reason=retryable_error'));
    expect(errors, isNot(contains('private failure payload')));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('late throwing hot refresh is discarded after a new context snapshot wins', (tester) async {
    await mount(tester);
    await _end(tester, HomeRailKind.hotTv);
    await _end(tester, HomeRailKind.hotTv);
    final pending = Completer<List<SearchSuggestItem>>();
    state.hotOverride = (category) => category == HotRankCategory.series
        ? pending.future : Future.value(state.suggest.hotSnapshot(category) ?? []);
    state.now = state.now.add(const Duration(hours: 7));
    state.homeHeroSession.startBackgroundLoads();
    await tester.pumpAndSettle();
    state.source = 'new-context';
    state.hotOverride = (category) async => [
      for (var i = 0; i < 30; i++) SearchSuggestItem(title: 'new-${category.name}-$i'),
    ];
    state.homeHeroSession.project(headerRules: []);
    state.homeHeroSession.startBackgroundLoads();
    await tester.pumpAndSettle();
    pending.completeError(StateError('private stale payload'));
    await tester.pumpAndSettle();
    expect(state.homeHeroSession.hotRows(HotRankCategory.series)!.first.title, 'new-series-0');
    expect(_count(tester, HomeRailKind.hotTv), 30);
    expect(find.textContaining('全部加载'), findsNothing);
    final errors = log.entries.where((entry) => entry.scope == 'home-pagination' && entry.message.contains('event=request_error')).map((entry) => entry.message).join('\n');
    expect(errors, contains('reason=stale_discarded'));
    expect(errors, isNot(contains('private stale payload')));
    await tester.pumpWidget(const SizedBox.shrink());
  });

}
