import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/detail_recommendation.dart';
import 'package:webhtv_pc/core/home_feed.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/tmdb_config.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/core/watched_recommendation.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/recommendation_feedback_store.dart';
import 'package:webhtv_pc/services/search_suggest_service.dart';
import 'package:webhtv_pc/services/storage.dart';
import 'package:webhtv_pc/services/tmdb_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/state/detail_recommendation_state.dart';
import 'package:webhtv_pc/ui/home_cards.dart';
import 'package:webhtv_pc/ui/home_page.dart';

import 'support/detail_test_seams.dart';

class _State extends AppState {
  _State(Directory dir, this.dependencies, this.metadata)
    : super(
        paths: AppPaths.resolve(
          overrides: {
            'config': dir.path,
            'data': dir.path,
            'cache': dir.path,
            'state': dir.path,
          },
        ),
        log: MemoryOnlyLogService(),
      );
  final DetailRecommendationDependencies dependencies;
  final TmdbService metadata;
  String source = 'first';
  String seed = 'seed';
  @override
  String get activeSourceKey => source;
  @override
  bool get externalMetaEnabled => false;
  @override
  TmdbService get tmdbService => metadata;
  @override
  DetailRecommendationDependencies get recommendationDependencies =>
      dependencies;
  @override
  Future<List<SearchSuggestItem>> searchHotRank(
    HotRankCategory category,
  ) async => [];
  @override
  List<PlaybackHistory> recentHistory({int limit = 100, String? sourceKey}) => [
    PlaybackHistory(
      id: 1,
      siteKey: 'site',
      vodId: seed,
      vodName: seed,
      flag: 'line',
      episodeName: 'one',
      episodeId: 'one',
      positionMs: 0,
      durationMs: 100000,
      updatedAt: 1,
      completed: true,
    ),
  ];
  @override
  Future<TmdbItem?> historyTmdbItem(
    PlaybackHistory row, {
    bool Function()? isCurrent,
  }) async => null;
  @override
  Future<Vod?> historyVod(PlaybackHistory row) async => null;
}

RecommendationEntry _entry(RecommendationRow row, int id) =>
    RecommendationEntry(
      item: TmdbItem(
        tmdbId: (row == RecommendationRow.tmdb ? 1000 : 2000) + id,
        mediaType: TmdbMediaType.movie,
        title: '${row.name}-$id',
      ),
      source: row == RecommendationRow.tmdb
          ? RecommendationSource.tmdb
          : RecommendationSource.douban,
      doubanId: row == RecommendationRow.douban ? 'db-$id' : null,
    );
RecommendationPage _page(
  RecommendationRow row,
  int start,
  int count, {
  int next = 20,
  bool more = true,
}) => RecommendationPage(
  items: [for (var id = start; id < start + count; id++) _entry(row, id)],
  nextOffset: next,
  hasMore: more,
);

void main() {
  late Directory dir;
  late TmdbService metadata;
  late _State state;
  final requests = <RecommendationRow, List<RecommendationRequest>>{};
  final loaders = <RecommendationRow, RecommendationLoader>{};
  setUp(() {
    dir = Directory('../../.local/home-pagination/test-state').absolute;
    dir.createSync(recursive: true);
    requests.clear();
    loaders.clear();
    metadata = TmdbService(
      config: () => const TmdbConfig(enabled: false),
      client: MockClient((_) async => http.Response('{}', 200)),
    );
    state = _State(
      dir,
      DetailRecommendationDependencies(
        feedback: RecommendationFeedbackStore(),
        loaders: {
          for (final row in [RecommendationRow.tmdb, RecommendationRow.douban])
            row: (request) async {
              requests.putIfAbsent(row, () => []).add(request);
              return await (loaders[row]?.call(request) ??
                  Future.value(
                    request.offset == 0
                        ? _page(row, 0, 20)
                        : _page(row, 19, 12, next: 40, more: false),
                  ));
            },
        },
      ),
      metadata,
    );
  });
  tearDown(() {
    state.dispose();
    metadata.close();
  });

  Future<void> pumpHome(WidgetTester tester) async {
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

  Finder rail(RecommendationRow row) => find.byWidgetPredicate(
    (widget) =>
        widget is HomeRailView &&
        widget.rail.kind ==
            (row == RecommendationRow.tmdb
                ? HomeRailKind.recommendTmdb
                : HomeRailKind.recommendDouban),
  );
  Future<ScrollableState> showRail(
    WidgetTester tester,
    RecommendationRow row,
  ) async {
    await tester.drag(
      find.byKey(const ValueKey('home-scroll')),
      const Offset(0, -650),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(rail(row));
    await tester.pumpAndSettle();
    return tester.state<ScrollableState>(
      find.descendant(of: rail(row), matching: find.byType(Scrollable)),
    );
  }

  Future<void> forward(WidgetTester tester, RecommendationRow row) async {
    final scroll = await showRail(tester, row);
    scroll.position.jumpTo(scroll.position.maxScrollExtent - 80);
    await tester.pump();
    await tester.drag(
      find.descendant(of: rail(row), matching: find.byType(ListView)),
      const Offset(-200, 0),
    );
    await tester.pumpAndSettle();
  }

  for (final row in [RecommendationRow.tmdb, RecommendationRow.douban]) {
    testWidgets(
      '${row.name} deliberate horizontal end scroll appends beyond first page in order',
      (tester) async {
        await pumpHome(tester);
        await forward(tester, row);
        final projected = tester.widget<HomeRailView>(rail(row)).rail.items;
        expect(projected.map((item) => item.title), [
          for (var i = 0; i < 31; i++) '${row.name}-$i',
        ]);
        expect(requests[row]!.map((request) => request.offset), [0, 20]);
        expect(
          projected.last.entry?.item.tmdbId,
          (row == RecommendationRow.tmdb ? 1000 : 2000) + 30,
        );
        expect(requests[row]!.last.current.title, 'seed');
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'ordinary vertical wheel keeps outer page scrolling without pagination',
    (tester) async {
      await pumpHome(tester);
      final horizontal = await showRail(tester, RecommendationRow.tmdb);
      horizontal.position.jumpTo(horizontal.position.maxScrollExtent);
      await tester.pumpAndSettle();
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
      final before = outer.pixels;
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: tester.getCenter(rail(RecommendationRow.tmdb)),
          scrollDelta: const Offset(0, -80),
        ),
      );
      await tester.pumpAndSettle();
      expect(outer.pixels, lessThan(before));
      expect(requests[RecommendationRow.tmdb]!.length, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  test('recommendation projection retains appended pages without increasing hero capacity', () {
    final feed = buildHomeFeed(
      history: [],
      followings: [],
      tmdbRecommendations: [
        for (var i = 0; i < 45; i++) _entry(RecommendationRow.tmdb, i),
      ],
      doubanRecommendations: [
        for (var i = 0; i < 32; i++) _entry(RecommendationRow.douban, i),
      ],
    );
    expect(feed.rails[0].items.length, 45);
    expect(feed.rails[1].items.length, 32);
    expect(feed.hero.length, 3);
  });

  testWidgets(
    'non-scrollable recommendation autofills, stops once scrollable',
    (tester) async {
      loaders[RecommendationRow.tmdb] = (request) async => request.offset == 0
          ? _page(RecommendationRow.tmdb, 0, 2)
          : _page(RecommendationRow.tmdb, 2, 12, next: 40);
      await pumpHome(tester);
      await showRail(tester, RecommendationRow.tmdb);
      expect(requests[RecommendationRow.tmdb]!.map((r) => r.offset), [0, 20]);
      expect(
        tester
            .widget<HomeRailView>(rail(RecommendationRow.tmdb))
            .rail
            .items
            .length,
        14,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'resize autofills only after previously scrollable rail becomes non-scrollable',
    (tester) async {
      loaders[RecommendationRow.tmdb] = (request) async => request.offset == 0
          ? _page(RecommendationRow.tmdb, 0, 6)
          : _page(RecommendationRow.tmdb, 6, 20, next: 40, more: false);
      await pumpHome(tester);
      final scroll = await showRail(tester, RecommendationRow.tmdb);
      expect(scroll.position.maxScrollExtent, greaterThan(0));
      expect(requests[RecommendationRow.tmdb]!.length, 1);
      tester.view.physicalSize = const Size(2200, 800);
      await tester.pumpAndSettle();
      expect(requests[RecommendationRow.tmdb]!.map((r) => r.offset), [0, 20]);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'horizontal trackpad end signal paginates but programmatic positioning does not',
    (tester) async {
      await pumpHome(tester);
      final scroll = await showRail(tester, RecommendationRow.tmdb);
      scroll.position.jumpTo(scroll.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(requests[RecommendationRow.tmdb]!.length, 1);
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: tester.getCenter(rail(RecommendationRow.tmdb)),
          scrollDelta: const Offset(90, 0),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<HomeRailView>(rail(RecommendationRow.tmdb))
            .rail
            .items
            .length,
        31,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('in-flight repeated end gestures make one continuation request', (
    tester,
  ) async {
    final pending = Completer<RecommendationPage>();
    loaders[RecommendationRow.tmdb] = (request) => request.offset == 0
        ? Future.value(_page(RecommendationRow.tmdb, 0, 20))
        : pending.future;
    await pumpHome(tester);
    await forward(tester, RecommendationRow.tmdb);
    await forward(tester, RecommendationRow.tmdb);
    expect(requests[RecommendationRow.tmdb]!.map((r) => r.offset), [0, 20]);
    pending.complete(
      _page(RecommendationRow.tmdb, 20, 5, next: 40, more: false),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<HomeRailView>(rail(RecommendationRow.tmdb))
          .rail
          .items
          .length,
      25,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'failed continuation preserves entries and retries on a new end gesture without storms',
    (tester) async {
      var fail = true;
      loaders[RecommendationRow.tmdb] = (request) async {
        if (request.offset == 0) return _page(RecommendationRow.tmdb, 0, 20);
        if (fail) throw StateError('offline');
        return _page(RecommendationRow.tmdb, 20, 2, next: 40, more: false);
      };
      await pumpHome(tester);
      await forward(tester, RecommendationRow.tmdb);
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(requests[RecommendationRow.tmdb]!.map((r) => r.offset), [0, 20]);
      expect(
        tester
            .widget<HomeRailView>(rail(RecommendationRow.tmdb))
            .rail
            .items
            .length,
        20,
      );
      fail = false;
      await forward(tester, RecommendationRow.tmdb);
      expect(requests[RecommendationRow.tmdb]!.map((r) => r.offset), [
        0,
        20,
        20,
      ]);
      expect(
        tester
            .widget<HomeRailView>(rail(RecommendationRow.tmdb))
            .rail
            .items
            .length,
        22,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final next in [0, 20, -1]) {
    testWidgets('non-forward continuation cursor $next becomes terminal', (
      tester,
    ) async {
      loaders[RecommendationRow.tmdb] = (request) async => request.offset == 0
          ? _page(RecommendationRow.tmdb, 0, 20)
          : _page(RecommendationRow.tmdb, 20, 1, next: next);
      await pumpHome(tester);
      await forward(tester, RecommendationRow.tmdb);
      await forward(tester, RecommendationRow.tmdb);
      expect(requests[RecommendationRow.tmdb]!.map((r) => r.offset), [0, 20]);
      expect(
        state.homeHeroSession.recommendationHasMore(RecommendationRow.tmdb),
        isFalse,
      );
      expect(
        tester
            .widget<HomeRailView>(rail(RecommendationRow.tmdb))
            .rail
            .items
            .length,
        21,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('terminal hasMore false ignores future end gestures', (
    tester,
  ) async {
    loaders[RecommendationRow.tmdb] = (_) async =>
        _page(RecommendationRow.tmdb, 0, 20, more: false);
    await pumpHome(tester);
    await forward(tester, RecommendationRow.tmdb);
    expect(requests[RecommendationRow.tmdb]!.map((r) => r.offset), [0]);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final duplicate in [false, true]) {
    testWidgets(
      'underfilled ${duplicate ? "duplicate" : "empty"} continuation does not autofill-loop and permits deliberate advance',
      (tester) async {
        loaders[RecommendationRow.tmdb] = (request) async {
          if (request.offset == 0) {
            return _page(RecommendationRow.tmdb, 0, 1, next: 1);
          }
          if (request.offset == 1) {
            return _page(RecommendationRow.tmdb, 0, duplicate ? 1 : 0, next: 2);
          }
          return _page(RecommendationRow.tmdb, 1, 10, next: 3, more: false);
        };
        await pumpHome(tester);
        await showRail(tester, RecommendationRow.tmdb);
        await tester.pump(const Duration(seconds: 3));
        expect(requests[RecommendationRow.tmdb]!.map((r) => r.offset), [0, 1]);
        await forward(tester, RecommendationRow.tmdb);
        expect(requests[RecommendationRow.tmdb]!.map((r) => r.offset), [
          0,
          1,
          2,
        ]);
        expect(
          tester
              .widget<HomeRailView>(rail(RecommendationRow.tmdb))
              .rail
              .items
              .length,
          11,
        );
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('empty first page follows forward cursor to make a usable rail', (
    tester,
  ) async {
    loaders[RecommendationRow.tmdb] = (request) async => request.offset == 0
        ? _page(RecommendationRow.tmdb, 0, 0)
        : _page(RecommendationRow.tmdb, 0, 20, next: 40, more: false);
    await pumpHome(tester);
    await showRail(tester, RecommendationRow.tmdb);
    expect(requests[RecommendationRow.tmdb]!.map((r) => r.offset), [0, 20]);
    expect(
      tester
          .widget<HomeRailView>(rail(RecommendationRow.tmdb))
          .rail
          .items
          .length,
      20,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'appended pages preserve watched and feedback filters and cross-source identity dedup',
    (tester) async {
      state.dependencies.watched.setWatched(
        RecommendationWork(
          title: 'watched',
          mediaType: TmdbMediaType.movie,
          tmdbId: 1020,
        ),
        true,
      );
      state.dependencies.feedback.block('tmdb-21');
      loaders[RecommendationRow.tmdb] = (request) async => request.offset == 0
          ? _page(RecommendationRow.tmdb, 0, 20)
          : _page(RecommendationRow.tmdb, 19, 5, next: 40, more: false);
      loaders[RecommendationRow.douban] = (request) async => request.offset == 0
          ? _page(RecommendationRow.douban, 0, 20)
          : RecommendationPage(
              items: [
                _entry(RecommendationRow.tmdb, 22),
                _entry(RecommendationRow.douban, 20),
              ],
              hasMore: false,
            );
      await pumpHome(tester);
      await forward(tester, RecommendationRow.tmdb);
      await forward(tester, RecommendationRow.douban);
      final feed = state.homeHeroSession.project(headerRules: []).rails;
      final tmdb = feed
          .firstWhere((r) => r.kind == HomeRailKind.recommendTmdb)
          .items;
      final douban = feed
          .firstWhere((r) => r.kind == HomeRailKind.recommendDouban)
          .items;
      expect(tmdb.map((i) => i.title), [
        for (var i = 0; i < 20; i++) 'tmdb-$i',
        'tmdb-22',
        'tmdb-23',
      ]);
      expect(douban.map((i) => i.title), [
        for (var i = 0; i <= 20; i++) 'douban-$i',
      ]);
      expect(
        requests[RecommendationRow.tmdb]!.last.blockedTitles,
        contains('tmdb21'),
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final context in [false, true]) {
    testWidgets(
      'stale continuation is ignored after ${context ? "context" : "seed"} reset',
      (tester) async {
        final pending = Completer<RecommendationPage>();
        loaders[RecommendationRow.tmdb] = (request) async {
          if (request.offset > 0) return pending.future;
          return _page(
            RecommendationRow.tmdb,
            state.seed == 'seed' && state.source == 'first' ? 0 : 100,
            20,
          );
        };
        await pumpHome(tester);
        await forward(tester, RecommendationRow.tmdb);
        final oldKey = state.homeHeroSession.recommendationPagingKey;
        if (context) {
          state.source = 'second';
        } else {
          state.seed = 'new-seed';
        }
        state.homeHeroSession.project(headerRules: []);
        state.homeHeroSession.startBackgroundLoads();
        await tester.pumpAndSettle();
        pending.complete(_page(RecommendationRow.tmdb, 900, 1, next: 40));
        await tester.pumpAndSettle();
        expect(state.homeHeroSession.recommendationPagingKey, isNot(oldKey));
        final projected = state.homeHeroSession
            .project(headerRules: [])
            .rails
            .firstWhere((r) => r.kind == HomeRailKind.recommendTmdb)
            .items;
        expect(projected.map((i) => i.title), [
          for (var i = 100; i < 120; i++) 'tmdb-$i',
        ]);
        expect(requests[RecommendationRow.tmdb]!.map((r) => r.offset), [
          0,
          20,
          0,
        ]);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'detach cancels in-flight continuation and lease, remount revalidates from first page',
    (tester) async {
      final pending = Completer<RecommendationPage>();
      loaders[RecommendationRow.tmdb] = (request) async => request.offset == 0
          ? _page(RecommendationRow.tmdb, 0, 20)
          : pending.future;
      await pumpHome(tester);
      await forward(tester, RecommendationRow.tmdb);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(state.dependencies.isLeased, isFalse);
      pending.complete(_page(RecommendationRow.tmdb, 900, 1, next: 40));
      await tester.pumpAndSettle();
      await state.homeHeroSession.loadMoreRecommendations(
        RecommendationRow.tmdb,
      );
      expect(requests[RecommendationRow.tmdb]!.map((r) => r.offset), [0, 20]);
      await pumpHome(tester);
      expect(requests[RecommendationRow.tmdb]!.map((r) => r.offset), [
        0,
        20,
        0,
      ]);
      expect(
        state.homeHeroSession
            .project(headerRules: [])
            .rails
            .firstWhere((r) => r.kind == HomeRailKind.recommendTmdb)
            .items
            .length,
        20,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'dispose during continuation ignores completion and emits no late notification',
    (tester) async {
      final pending = Completer<RecommendationPage>();
      loaders[RecommendationRow.tmdb] = (request) async => request.offset == 0
          ? _page(RecommendationRow.tmdb, 0, 20)
          : pending.future;
      await pumpHome(tester);
      await forward(tester, RecommendationRow.tmdb);
      await tester.pumpWidget(const SizedBox.shrink());
      state.homeHeroSession.dispose();
      pending.complete(_page(RecommendationRow.tmdb, 900, 1, next: 40));
      await tester.pumpAndSettle();
      expect(state.dependencies.isLeased, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'simultaneously underfilled provider rails both autofill without lost requests',
    (tester) async {
      for (final row in [RecommendationRow.tmdb, RecommendationRow.douban]) {
        loaders[row] = (request) async => request.offset == 0
            ? _page(row, 0, 2)
            : _page(row, 2, 12, next: 40, more: false);
      }
      await pumpHome(tester);
      await showRail(tester, RecommendationRow.tmdb);
      await showRail(tester, RecommendationRow.douban);
      expect(requests[RecommendationRow.tmdb]!.map((r) => r.offset), [0, 20]);
      expect(requests[RecommendationRow.douban]!.map((r) => r.offset), [0, 20]);
      expect(
        tester
            .widget<HomeRailView>(rail(RecommendationRow.douban))
            .rail
            .items
            .length,
        14,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
