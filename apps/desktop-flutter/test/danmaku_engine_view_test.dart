import 'package:canvas_danmaku/canvas_danmaku.dart' as engine;
import 'package:canvas_danmaku/scroll_danmaku_painter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/danmaku.dart';
import 'package:webhtv_pc/core/danmaku_style.dart';
import 'package:webhtv_pc/ui/danmaku_engine_view.dart';

void main() {
  realEngineContractTests();
  DanmakuItem item(
    int timeMs,
    String text, {
    DanmakuType type = DanmakuType.scroll,
  }) => DanmakuItem(timeMs: timeMs, text: text, type: type);

  group('投放游标', () {
    test('按播放位置投放，每条只投一次', () {
      final cursor = DanmakuEmitCursor(
        items: [item(3000, 'c'), item(1000, 'a'), item(2000, 'b')],
      );
      expect(cursor.advanceTo(500).map((e) => e.text), isEmpty);
      expect(cursor.advanceTo(1000).map((e) => e.text), ['a']);
      expect(cursor.advanceTo(1200).map((e) => e.text), isEmpty);
      expect(cursor.advanceTo(2500).map((e) => e.text), ['b']);
      expect(cursor.advanceTo(3000).map((e) => e.text), ['c']);
      expect(cursor.pendingCount, 0);
    });

    test('明显倒退（拖动）重新定位，不补发中间那段', () {
      final cursor = DanmakuEmitCursor(
        items: [
          item(1000, 'a'),
          item(2000, 'b'),
          item(3000, 'c'),
          item(4000, 'd'),
        ],
      );
      expect(cursor.advanceTo(3500).map((e) => e.text), ['a', 'b', 'c']);
      expect(cursor.advanceTo(500).map((e) => e.text), isEmpty);
      expect(cursor.advanceTo(2500).map((e) => e.text), ['a', 'b']);
    });

    test('小幅位置抖动不触发重新定位', () {
      final cursor = DanmakuEmitCursor(
        items: [item(1000, 'a'), item(2000, 'b')],
      );
      expect(cursor.advanceTo(1600).map((e) => e.text), ['a']);
      expect(cursor.advanceTo(1400).map((e) => e.text), isEmpty);
      expect(cursor.advanceTo(2000).map((e) => e.text), ['b']);
    });

    test('换集：reset 到当前位置，不补发之前的弹幕', () {
      final cursor = DanmakuEmitCursor(items: [item(1000, 'a')]);
      expect(cursor.advanceTo(5000).map((e) => e.text), ['a']);
      cursor.reset([item(1000, 'x'), item(4000, 'y')], positionMs: 3000);
      expect(cursor.advanceTo(3100).map((e) => e.text), isEmpty);
      expect(cursor.advanceTo(4100).map((e) => e.text), ['y']);
    });
  });

  group('选项映射', () {
    test('字号、透明度、区域、时长、隐藏开关逐一对应', () {
      const style = DanmakuStyle(
        opacity: 0.8,
        textScale: 1.0,
        areaRatio: 0.5,
        strokeWidth: 1.2,
        scrollDurationMs: 20000,
        fixedDurationMs: 4000,
        showTop: false,
      );
      final option = danmakuOptionFor(style);
      expect(option.fontSize, 25);
      expect(option.opacity, 0.8);
      expect(option.area, 0.5);
      expect(option.strokeWidth, 1.2);
      expect(option.duration, 20);
      expect(option.staticDuration, 4);
      expect(option.hideTop, isTrue);
      expect(option.hideBottom, isFalse);
    });

    test('字重必须是 FontWeight.values 的下标，而不是 CSS 字重', () {
      final option = danmakuOptionFor(const DanmakuStyle());
      // 传 400 会让引擎在 generateParagraph 里 RangeError（真机上表现是「一条都不出」）。
      expect(option.fontWeight, 3, reason: '3 = FontWeight.w400');
      expect(option.fontWeight, lessThan(FontWeight.values.length));
      expect(FontWeight.values[option.fontWeight], FontWeight.w400);
    });

    test('倍速按比例缩短滚动时长，非法倍速按 1x', () {
      expect(danmakuOptionFor(const DanmakuStyle(), rate: 2).duration, 10);
      expect(danmakuOptionFor(const DanmakuStyle(), rate: 0).duration, 20);
    });
  });

  group('类型映射', () {
    test('三种类型对应引擎类型，反向滚动归一到 scroll', () {
      expect(
        danmakuItemTypeFor(DanmakuType.scroll),
        engine.DanmakuItemType.scroll,
      );
      expect(
        danmakuItemTypeFor(DanmakuType.reverse),
        engine.DanmakuItemType.scroll,
      );
      expect(danmakuItemTypeFor(DanmakuType.top), engine.DanmakuItemType.top);
      expect(
        danmakuItemTypeFor(DanmakuType.bottom),
        engine.DanmakuItemType.bottom,
      );
    });
  });
}

DanmakuItem item(int timeMs, String text) =>
    DanmakuItem(timeMs: timeMs, text: text);

Future<void> show(
  WidgetTester tester, {
  required List<DanmakuItem> items,
  int positionMs = 0,
  DanmakuStyle style = const DanmakuStyle(),
  bool playing = true,
  bool held = false,
  bool seeking = false,
  ({int revision, Duration target})? seek,
  double rate = 1,
  List<DanmakuItem> live = const [],
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: SizedBox.expand(
        child: DanmakuEngineView(
          items: items,
          position: Duration(milliseconds: positionMs),
          style: style,
          playing: playing,
          held: held,
          seeking: seeking,
          seek: seek,
          rate: rate,
          liveItems: live,
        ),
      ),
    ),
  );
  await tester.pump();
}

ScrollDanmakuPainter painter(WidgetTester tester) => tester
    .widgetList<CustomPaint>(find.byType(CustomPaint))
    .map((widget) => widget.painter)
    .whereType<ScrollDanmakuPainter>()
    .single;

List<String> texts(WidgetTester tester) =>
    painter(tester).danmakuItems.map((entry) => entry.content.text).toList();

void realEngineContractTests() {
  testWidgets('identical periodic position preserves moving engine state', (
    tester,
  ) async {
    final items = [item(0, 'moving')];
    await show(tester, items: items);
    await tester.pump(const Duration(milliseconds: 16));
    final state = tester.state(find.byType(engine.DanmakuScreen<Object?>));
    final entry = painter(tester).danmakuItems.single;
    var previousX = entry.xPosition;
    for (var index = 0; index < 8; index++) {
      await show(tester, items: items);
      await tester.pump(const Duration(milliseconds: 16));
      expect(
        tester.state(find.byType(engine.DanmakuScreen<Object?>)),
        same(state),
      );
      expect(painter(tester).danmakuItems.single, same(entry));
      expect(painter(tester).running, isTrue);
      expect(entry.xPosition, lessThan(previousX));
      previousX = entry.xPosition;
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'rate and style update existing real engine without resetting x',
    (tester) async {
      final items = [item(0, 'rate')];
      await show(tester, items: items);
      await tester.pump(const Duration(milliseconds: 16));
      final entry = painter(tester).danmakuItems.single;
      final before = entry.xPosition;
      await tester.pump(const Duration(milliseconds: 100));
      final delta1 = before - entry.xPosition;
      final atChange = entry.xPosition;
      await show(
        tester,
        items: items,
        rate: 2,
        style: const DanmakuStyle(opacity: 0.6),
      );
      expect(painter(tester).durationInMilliseconds, 10000);
      expect(painter(tester).danmakuItems.single, same(entry));
      expect(entry.xPosition, closeTo(atChange, 0.001));
      await tester.pump(const Duration(milliseconds: 100));
      expect(atChange - entry.xPosition, closeTo(2 * delta1, 0.001));
      await show(
        tester,
        items: items,
        rate: 2,
        style: const DanmakuStyle(opacity: 0.6, textScale: 1.2),
      );
      expect(painter(tester).fontSize, 30);
      expect(painter(tester).danmakuItems.single, same(entry));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('held position reports defer due emissions until release', (
    tester,
  ) async {
    final items = [item(0, 'old'), item(1000, 'due')];
    await show(tester, items: items);
    final entry = painter(tester).danmakuItems.single;
    await show(tester, items: items, positionMs: 1000, held: true);
    expect(texts(tester), ['old']);
    final frozenX = entry.xPosition;
    await tester.pump(const Duration(milliseconds: 100));
    expect(entry.xPosition, frozenX);
    await show(tester, items: items, positionMs: 1000);
    expect(texts(tester), ['old', 'due']);
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    expect(entry.xPosition, lessThan(frozenX));
  });

  testWidgets('live append emits only the new entry', (tester) async {
    final items = <DanmakuItem>[];
    final a = item(0, 'a');
    final b = item(1, 'b');
    await show(tester, items: items, live: [a]);
    await show(tester, items: items, live: [a, b]);
    expect(texts(tester), ['a', 'b']);
  });

  testWidgets('live same-length rolling window emits the unseen arrival', (
    tester,
  ) async {
    final items = <DanmakuItem>[];
    final a = item(0, 'a');
    final b = item(1, 'b');
    final c = item(2, 'c');
    await show(tester, items: items, live: [a, b]);
    await show(tester, items: items, live: [b, c]);
    expect(texts(tester), [
      'a',
      'b',
      'c',
    ], reason: 'Pruning one item while appending one must not drop c.');
  });

  testWidgets('live prune does not re-emit a surviving item', (tester) async {
    final items = <DanmakuItem>[];
    final a = item(0, 'a');
    final b = item(1, 'b');
    await show(tester, items: items, live: [a, b]);
    await show(tester, items: items, live: [b]);
    expect(texts(tester), [
      'a',
      'b',
    ], reason: 'A pruning-only update must not duplicate surviving b.');
  });

  testWidgets('disable then re-enable uses a fresh engine safely', (
    tester,
  ) async {
    final items = [item(0, 'toggle')];
    await show(tester, items: items);
    await show(tester, items: items, style: const DanmakuStyle(enabled: false));
    expect(find.byType(engine.DanmakuScreen<Object?>), findsNothing);
    await show(tester, items: items);
    expect(
      tester.takeException(),
      isNull,
      reason: 'Re-enable must not invoke a disposed controller.',
    );
    expect(find.byType(engine.DanmakuScreen<Object?>), findsOneWidget);
  });
  testWidgets('same-text distinct live arrivals are both emitted', (
    tester,
  ) async {
    final items = <DanmakuItem>[];
    final a = item(0, 'same');
    final b = item(0, 'same');
    await show(tester, items: items, live: [a]);
    await show(tester, items: items, live: [a, b]);
    expect(texts(tester), ['same', 'same']);
  });

  testWidgets('pruned live arrival still in flight is not emitted again', (
    tester,
  ) async {
    final items = <DanmakuItem>[];
    final a = item(0, 'a');
    await show(tester, items: items, live: [a]);
    await show(tester, items: items, live: []);
    await show(tester, items: items, live: [a]);
    expect(texts(tester), ['a']);
  });
  for (final targetMs in [10000, 0]) {
    testWidgets('explicit seek to $targetMs clears old engine and skips gap', (
      tester,
    ) async {
      final items = [item(0, 'zero'), item(1000, 'gap'), item(10000, 'ten')];
      final startMs = targetMs == 0 ? 10000 : 0;
      await show(tester, items: items, positionMs: startMs);
      final seek = (revision: 1, target: Duration(milliseconds: targetMs));
      await show(
        tester,
        items: items,
        positionMs: targetMs,
        seek: seek,
        seeking: true,
      );
      expect(texts(tester), isEmpty);
      await show(tester, items: items, positionMs: targetMs, seek: seek);
      expect(texts(tester), [targetMs == 0 ? 'zero' : 'ten']);
    });
  }

  testWidgets('fast seek whose seeking edges collapse still skips the gap', (
    tester,
  ) async {
    final items = [item(0, 'old'), item(1000, 'gap'), item(10000, 'target')];
    await show(tester, items: items);
    await show(
      tester,
      items: items,
      positionMs: 10000,
      seek: (revision: 1, target: const Duration(seconds: 10)),
    );
    expect(texts(tester), ['target']);
  });

  testWidgets(
    'stale position after seek request cannot consume target cursor',
    (tester) async {
      final items = [
        item(1000, 'old'),
        item(1100, 'gap'),
        item(1200, 'target'),
      ];
      const seek = (revision: 1, target: Duration(milliseconds: 1200));
      await show(tester, items: items, positionMs: 1000);
      await show(tester, items: items, positionMs: 1000, seek: seek);
      expect(texts(tester), isEmpty);
      await show(tester, items: items, positionMs: 1000, seek: seek);
      expect(texts(tester), isEmpty);
      await show(tester, items: items, positionMs: 1200, seek: seek);
      expect(texts(tester), ['target']);
    },
  );

  testWidgets(
    'seeking without a new event holds but does not clear active text',
    (tester) async {
      final items = [item(0, 'old'), item(1000, 'due')];
      await show(tester, items: items);
      final entry = painter(tester).danmakuItems.single;
      await show(tester, items: items, positionMs: 1000, seeking: true);
      expect(texts(tester), ['old']);
      expect(painter(tester).running, isFalse);
      await show(tester, items: items, positionMs: 1000);
      expect(painter(tester).danmakuItems.first, same(entry));
      expect(texts(tester), ['old', 'due']);
    },
  );

  testWidgets('a new episode cancels the previous pending seek event', (
    tester,
  ) async {
    final previous = [item(0, 'old'), item(10000, 'old-target')];
    const seek = (revision: 1, target: Duration(seconds: 10));
    await show(tester, items: previous);
    await show(tester, items: previous, seek: seek, seeking: true);
    final next = [item(0, 'new-episode')];
    // 新媒体明确清除旧的定位事件；不能还等上一集的 10 秒目标。
    await show(tester, items: next, held: true);
    await show(tester, items: next);
    expect(texts(tester), ['new-episode']);
  });

  testWidgets('paused seek defers target emission until playback resumes', (
    tester,
  ) async {
    final items = [item(0, 'old'), item(1000, 'target')];
    const seek = (revision: 1, target: Duration(seconds: 1));
    await show(tester, items: items);
    await show(
      tester,
      items: items,
      positionMs: 1000,
      playing: false,
      seek: seek,
    );
    expect(texts(tester), isEmpty);
    await show(tester, items: items, positionMs: 1000, seek: seek);
    expect(texts(tester), ['target']);
  });

  testWidgets(
    'pending seek survives disabled screen recreation without gap feed',
    (tester) async {
      final items = [item(0, 'old'), item(1000, 'gap'), item(10000, 'target')];
      const seek = (revision: 1, target: Duration(seconds: 10));
      await show(tester, items: items);
      await show(tester, items: items, seek: seek, seeking: true);
      await show(
        tester,
        items: items,
        seek: seek,
        seeking: true,
        style: const DanmakuStyle(enabled: false),
      );
      await show(tester, items: items, seek: seek, seeking: true);
      await show(tester, items: items, positionMs: 10000, seek: seek);
      expect(texts(tester), ['target']);
    },
  );

  testWidgets(
    'small backward explicit seek is not swallowed as position jitter',
    (tester) async {
      final items = [item(1000, 'target'), item(1200, 'old')];
      await show(tester, items: items, positionMs: 1200);
      await show(
        tester,
        items: items,
        positionMs: 1000,
        seek: (revision: 1, target: const Duration(seconds: 1)),
      );
      expect(texts(tester), ['target']);
    },
  );

  testWidgets(
    'expired pruned live identity can leave the retained dedup window',
    (tester) async {
      final items = <DanmakuItem>[];
      final a = item(0, 'a');
      await show(tester, items: items, live: [a]);
      await show(tester, items: items, live: []);
      await tester.pump(const Duration(seconds: 21));
      await show(tester, items: items, live: []);
      await show(tester, items: items, live: [a]);
      expect(
        painter(tester).danmakuItems
            .where((entry) => !entry.expired)
            .map((entry) => entry.content.text),
        ['a'],
      );
    },
  );
}
