import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/detail_recommendation.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/services/recommendation_feedback_store.dart';
import 'package:webhtv_pc/state/detail_recommendation_state.dart';
import 'package:webhtv_pc/ui/detail_recommendations.dart';

RecommendationPage page(
  int offset, {
  int count = 6,
  bool more = true,
  String prefix = 'Card',
}) => RecommendationPage(
  items: [
    for (var i = offset; i < offset + count; i++)
      RecommendationEntry(
        item: TmdbItem(
          tmdbId: i + 100,
          mediaType: TmdbMediaType.movie,
          title: '$prefix $i',
        ),
        source: RecommendationSource.tmdb,
      ),
  ],
  nextOffset: offset + count,
  hasMore: more,
);

Finder row(RecommendationRow key) =>
    find.byKey(ValueKey('recommendation-row-${key.name}'));
ScrollPosition position(WidgetTester tester, RecommendationRow key) => tester
    .state<ScrollableState>(
      find.descendant(of: row(key), matching: find.byType(Scrollable)),
    )
    .position;

Future<void> mount(
  WidgetTester tester,
  DetailRecommendationDependencies deps, {
  double width = 420,
  String title = 'Current',
  ValueChanged<TmdbItem>? onOpen,
}) async {
  tester.view.physicalSize = Size(width, 1100);
  tester.view.devicePixelRatio = 1;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: Column(
            children: [
              DetailRecommendations(
                dependencies: deps,
                current: RecommendationSeed(title: title),
                onOpenItem: onOpen,
              ),
              const SizedBox(height: 600),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> endDrag(
  WidgetTester tester,
  RecommendationRow key, {
  PointerDeviceKind kind = PointerDeviceKind.touch,
}) async {
  await tester.drag(row(key), const Offset(-1200, 0), kind: kind);
  await tester.pumpAndSettle();
}

Future<double> originalOtherRowTop(WidgetTester tester) async {
  await mount(
    tester,
    DetailRecommendationDependencies(
      feedback: RecommendationFeedbackStore(),
      loaders: {
        RecommendationRow.tmdb: (r) async =>
            page(0, count: 3, more: false, prefix: 'Other'),
      },
    ),
  );
  return tester
      .getTopLeft(find.byKey(const ValueKey('recommendation-heading-tmdb')))
      .dy;
}

void main() {
  tearDown(() {
    final view =
        TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.resetPhysicalSize();
    view.resetDevicePixelRatio();
  });
  for (final kind in [
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
    PointerDeviceKind.trackpad,
  ]) {
    testWidgets(
      '$kind horizontal end appends, preserves position and opens card',
      (tester) async {
        final offsets = <int>[];
        TmdbItem? opened;
        final deps = DetailRecommendationDependencies(
          feedback: RecommendationFeedbackStore(),
          loaders: {
            RecommendationRow.related: (r) async {
              offsets.add(r.offset);
              return page(r.offset, more: r.offset == 0);
            },
          },
        );
        await mount(tester, deps, onOpen: (item) => opened = item);
        final gesture = await tester.startGesture(
          tester.getCenter(row(RecommendationRow.related)),
          kind: kind,
        );
        if (kind == PointerDeviceKind.trackpad) {
          await gesture.panZoomUpdate(
            tester.getCenter(row(RecommendationRow.related)),
            pan: const Offset(-1000, 0),
          );
        } else {
          await gesture.moveBy(const Offset(-20, 0));
          await gesture.moveBy(const Offset(-1000, 0));
        }
        await tester.pump();
        final oldOffset = position(tester, RecommendationRow.related).pixels;
        await gesture.up();
        await tester.pumpAndSettle();
        expect(offsets, [0, 6]);
        expect(
          position(tester, RecommendationRow.related).pixels,
          greaterThanOrEqualTo(oldOffset),
        );
        await endDrag(tester, RecommendationRow.related, kind: kind);
        expect(offsets, [0, 6]);
        await tester.tap(find.text('Card 11'));
        await tester.pumpAndSettle();
        expect(opened?.tmdbId, 111);
      },
    );
  }
  testWidgets('in-flight requests deduplicate and exhausted rows stop', (
    tester,
  ) async {
    final offsets = <int>[];
    final pending = Completer<RecommendationPage>();
    final deps = DetailRecommendationDependencies(
      feedback: RecommendationFeedbackStore(),
      loaders: {
        RecommendationRow.related: (r) {
          offsets.add(r.offset);
          return r.offset == 0 ? Future.value(page(0)) : pending.future;
        },
      },
    );
    await mount(tester, deps);
    await endDrag(tester, RecommendationRow.related);
    await endDrag(tester, RecommendationRow.related);
    expect(offsets, [0, 6]);
    final oldOffset = position(tester, RecommendationRow.related).pixels;
    pending.complete(page(6, more: false));
    await tester.pumpAndSettle();
    expect(position(tester, RecommendationRow.related).pixels, oldOffset);
    await endDrag(tester, RecommendationRow.related);
    expect(offsets, [0, 6]);
    expect(find.text('Card 11'), findsOneWidget);
  });
  testWidgets(
    'failed end request does not loop and next deliberate drag retries',
    (tester) async {
      final offsets = <int>[];
      var failed = false;
      final deps = DetailRecommendationDependencies(
        feedback: RecommendationFeedbackStore(),
        loaders: {
          RecommendationRow.related: (r) async {
            offsets.add(r.offset);
            if (r.offset > 0 && !failed) {
              failed = true;
              throw StateError('offline');
            }
            return page(r.offset, more: r.offset == 0);
          },
        },
      );
      await mount(tester, deps);
      await endDrag(tester, RecommendationRow.related);
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(offsets, [0, 6]);
      await endDrag(tester, RecommendationRow.related);
      expect(offsets, [0, 6, 6]);
      await endDrag(tester, RecommendationRow.related);
      expect(find.text('Card 11'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  for (final outcome in ['empty', 'error', 'pending']) {
    testWidgets('empty row stays hidden without a gap after $outcome page', (
      tester,
    ) async {
      final originalY = await originalOtherRowTop(tester);
      final first = Completer<RecommendationPage>();
      final next = Completer<RecommendationPage>();
      final offsets = <int>[];
      final deps = DetailRecommendationDependencies(
        feedback: RecommendationFeedbackStore(),
        loaders: {
          RecommendationRow.tmdb: (r) async =>
              page(0, count: 3, more: false, prefix: 'Other'),
          RecommendationRow.related: (r) {
            offsets.add(r.offset);
            if (r.offset == 0) return first.future;
            if (outcome == 'pending') return next.future;
            if (outcome == 'error') return Future.error(StateError('offline'));
            return Future.value(
              const RecommendationPage(items: [], nextOffset: 2, hasMore: true),
            );
          },
        },
      );
      await mount(tester, deps);
      void expectHidden() {
        expect(
          find.byKey(const ValueKey('recommendation-heading-related')),
          findsNothing,
        );
        expect(row(RecommendationRow.related), findsNothing);
        expect(
          tester
              .getTopLeft(
                find.byKey(const ValueKey('recommendation-heading-tmdb')),
              )
              .dy,
          originalY,
        );
        expect(find.text('Other 0'), findsOneWidget);
      }

      expectHidden();
      first.complete(
        const RecommendationPage(items: [], nextOffset: 1, hasMore: true),
      );
      await tester.pumpAndSettle();
      expect(offsets, [0, 1]);
      expectHidden();
      await tester.pump(const Duration(seconds: 3));
      tester.view.physicalSize = const Size(600, 1100);
      await tester.pumpAndSettle();
      expect(offsets, [0, 1]);
      expectHidden();
      if (outcome == 'pending') {
        next.complete(page(1, more: false, prefix: 'Filled'));
        await tester.pumpAndSettle();
        expect(find.text('Filled 1'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('recommendation-heading-related')),
          findsOneWidget,
        );
      }
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('feedback hiding last entry does not leave a blank row or gap', (
    tester,
  ) async {
    final originalY = await originalOtherRowTop(tester);
    final feedback = RecommendationFeedbackStore();
    final offsets = <int>[];
    final deps = DetailRecommendationDependencies(
      feedback: feedback,
      loaders: {
        RecommendationRow.tmdb: (r) async =>
            page(0, count: 3, more: false, prefix: 'Other'),
        RecommendationRow.related: (r) async {
          offsets.add(r.offset);
          return RecommendationPage(
            items: page(0, count: 1).items,
            nextOffset: r.offset + 1,
            hasMore: true,
          );
        },
      },
    );
    await mount(tester, deps);
    expect(find.text('Card 0'), findsOneWidget);
    expect(offsets, [0, 1]);
    feedback.block('Card 0');
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('recommendation-heading-related')),
      findsNothing,
    );
    expect(row(RecommendationRow.related), findsNothing);
    expect(
      tester
          .getTopLeft(find.byKey(const ValueKey('recommendation-heading-tmdb')))
          .dy,
      originalY,
    );
    expect(find.text('Other 0'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    expect(offsets, [0, 1]);
    expect(tester.takeException(), isNull);
  });
  testWidgets('empty first page with more data still fills a usable row', (
    tester,
  ) async {
    final offsets = <int>[];
    final deps = DetailRecommendationDependencies(
      feedback: RecommendationFeedbackStore(),
      loaders: {
        RecommendationRow.related: (r) async {
          offsets.add(r.offset);
          if (r.offset == 0) {
            return const RecommendationPage(
              items: [],
              nextOffset: 1,
              hasMore: true,
            );
          }
          return page(1, more: false);
        },
      },
    );
    await mount(tester, deps);
    expect(offsets, [0, 1]);
    expect(find.text('Card 1'), findsOneWidget);
    expect(
      position(tester, RecommendationRow.related).maxScrollExtent,
      greaterThan(0),
    );
  });
  testWidgets('short first and subsequent pages fill only until row scrolls', (
    tester,
  ) async {
    final offsets = <int>[];
    final deps = DetailRecommendationDependencies(
      feedback: RecommendationFeedbackStore(),
      loaders: {
        RecommendationRow.related: (r) async {
          offsets.add(r.offset);
          return page(r.offset, count: 1);
        },
      },
    );
    await mount(tester, deps, width: 600);
    expect(offsets, [0, 1, 2, 3, 4]);
    expect(
      position(tester, RecommendationRow.related).maxScrollExtent,
      greaterThan(0),
    );
    await tester.pump(const Duration(seconds: 3));
    expect(offsets, [0, 1, 2, 3, 4]);
  });
  testWidgets('underfilled non-advancing visible content does not auto-loop', (
    tester,
  ) async {
    final offsets = <int>[];
    final deps = DetailRecommendationDependencies(
      feedback: RecommendationFeedbackStore(),
      loaders: {
        RecommendationRow.related: (r) async {
          offsets.add(r.offset);
          return RecommendationPage(
            items: page(0, count: 1).items,
            nextOffset: r.offset + 1,
            hasMore: true,
          );
        },
      },
    );
    await mount(tester, deps);
    expect(offsets, [0, 1]);
    await tester.pump(const Duration(seconds: 3));
    expect(offsets, [0, 1]);
  });
  testWidgets('viewport growth fills newly underfilled row', (tester) async {
    final offsets = <int>[];
    final deps = DetailRecommendationDependencies(
      feedback: RecommendationFeedbackStore(),
      loaders: {
        RecommendationRow.related: (r) async {
          offsets.add(r.offset);
          return page(r.offset, count: 3);
        },
      },
    );
    await mount(tester, deps, width: 400);
    expect(offsets, [0]);
    tester.view.physicalSize = const Size(1000, 1100);
    await tester.pumpAndSettle();
    expect(offsets, [0, 3, 6]);
    expect(
      position(tester, RecommendationRow.related).maxScrollExtent,
      greaterThan(0),
    );
  });
  testWidgets('underfilled failed page stops automatic retries after resize', (
    tester,
  ) async {
    final offsets = <int>[];
    final deps = DetailRecommendationDependencies(
      feedback: RecommendationFeedbackStore(),
      loaders: {
        RecommendationRow.related: (r) async {
          offsets.add(r.offset);
          if (r.offset > 0) throw StateError('offline');
          return page(0, count: 1);
        },
      },
    );
    await mount(tester, deps);
    expect(offsets, [0, 1]);
    tester.view.physicalSize = const Size(800, 1100);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 3));
    expect(offsets, [0, 1]);
    await endDrag(tester, RecommendationRow.related);
    expect(offsets, [0, 1, 1]);
  });
  testWidgets('each row pages independently and vertical drag never pages', (
    tester,
  ) async {
    final offsets = <RecommendationRow, List<int>>{
      for (final key in RecommendationRow.values) key: [],
    };
    final deps = DetailRecommendationDependencies(
      feedback: RecommendationFeedbackStore(),
      loaders: {
        for (final key in RecommendationRow.values)
          key: (r) async {
            offsets[key]!.add(r.offset);
            return page(r.offset, more: r.offset == 0);
          },
      },
    );
    await mount(tester, deps);
    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -150),
    );
    await tester.pumpAndSettle();
    for (final key in RecommendationRow.values) {
      expect(offsets[key], [0]);
    }
    await tester.drag(find.byType(SingleChildScrollView), const Offset(0, 150));
    await tester.pumpAndSettle();
    for (final key in RecommendationRow.values) {
      await endDrag(tester, key);
      expect(offsets[key], [0, 6]);
      for (final other in RecommendationRow.values.where(
        (other) => other.index > key.index,
      )) {
        expect(offsets[other], [0]);
      }
    }
  });
  testWidgets('refresh ignores stale paging completion and resets new row', (
    tester,
  ) async {
    final pending = Completer<RecommendationPage>();
    final calls = <String>[];
    final deps = DetailRecommendationDependencies(
      feedback: RecommendationFeedbackStore(),
      loaders: {
        RecommendationRow.related: (r) {
          calls.add('${r.current.title}:${r.offset}');
          if (r.current.title == 'Current' && r.offset > 0) {
            return pending.future;
          }
          return Future.value(
            page(
              r.offset,
              more: r.current.title == 'Current',
              prefix: r.current.title,
            ),
          );
        },
      },
    );
    await mount(tester, deps);
    await endDrag(tester, RecommendationRow.related);
    await mount(tester, deps, title: 'New');
    pending.complete(page(6, prefix: 'Stale'));
    await tester.pumpAndSettle();
    expect(calls, ['Current:0', 'Current:6', 'New:0']);
    expect(find.text('Stale 6'), findsNothing);
    expect(position(tester, RecommendationRow.related).pixels, 0);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'disposing in-flight row prevents completion or scheduled loads',
    (tester) async {
      final pending = Completer<RecommendationPage>();
      final offsets = <int>[];
      final deps = DetailRecommendationDependencies(
        feedback: RecommendationFeedbackStore(),
        loaders: {
          RecommendationRow.related: (r) {
            offsets.add(r.offset);
            return r.offset == 0 ? Future.value(page(0)) : pending.future;
          },
        },
      );
      await mount(tester, deps);
      await endDrag(tester, RecommendationRow.related);
      await tester.pumpWidget(const SizedBox());
      pending.complete(page(6));
      await tester.pumpAndSettle();
      expect(offsets, [0, 6]);
      expect(tester.takeException(), isNull);
    },
  );
}
