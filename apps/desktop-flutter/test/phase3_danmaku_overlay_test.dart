/// 弹幕渲染层 widget 测试（设计文档 §21 Phase 3「字幕/弹幕可开启和关闭」）。
///
/// **为什么单独一个文件**：`testWidgets` 会初始化 flutter_test 的 binding，而该
/// binding 会拦截本进程内的所有 HTTP 请求（统一返回 400）。因此凡是需要真实
/// HTTP 的测试（DanmakuService 加载）必须放在**没有** `testWidgets` 的文件里，
/// 否则会拿到假 400 而不是真实响应。这里只做纯渲染/样式断言，不发网络。
library;

import 'dart:ui' show PictureRecorder;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/danmaku.dart';
import 'package:webhtv_pc/ui/danmaku_overlay.dart';

void main() {
  group('弹幕渲染层与开关（Phase 3）', () {
    testWidgets('开启时渲染 CustomPaint，关闭时完全不绘制', (tester) async {
      final items = [
        DanmakuItem(timeMs: 0, text: '一条弹幕', type: DanmakuType.scroll),
      ];

      Future<void> pumpWith(DanmakuStyle style) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 800,
                height: 400,
                child: DanmakuOverlay(
                  items: items,
                  position: const Duration(milliseconds: 1000),
                  style: style,
                ),
              ),
            ),
          ),
        );
      }

      await pumpWith(const DanmakuStyle());
      expect(find.byType(CustomPaint), findsWidgets);
      expect(find.byType(DanmakuOverlay), findsOneWidget);

      await pumpWith(const DanmakuStyle(enabled: false));
      // 关闭后本层不产生任何绘制内容。
      expect(
        find.descendant(
          of: find.byType(DanmakuOverlay),
          matching: find.byType(CustomPaint),
        ),
        findsNothing,
      );
    });

    testWidgets('无弹幕时不绘制', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 800,
              height: 400,
              child: DanmakuOverlay(
                items: [],
                position: Duration.zero,
                style: DanmakuStyle(),
              ),
            ),
          ),
        ),
      );
      expect(
        find.descendant(
          of: find.byType(DanmakuOverlay),
          matching: find.byType(CustomPaint),
        ),
        findsNothing,
      );
    });

    test('按类型过滤：滚动/顶部/底部可分别隐藏', () {
      final items = [
        DanmakuItem(timeMs: 0, text: 's', type: DanmakuType.scroll),
        DanmakuItem(timeMs: 0, text: 't', type: DanmakuType.top),
        DanmakuItem(timeMs: 0, text: 'b', type: DanmakuType.bottom),
      ];
      expect(filterDanmakuItems(items, const DanmakuStyle()), hasLength(3));
      expect(
        filterDanmakuItems(items, const DanmakuStyle(showScroll: false)).length,
        2,
      );
      expect(
        filterDanmakuItems(items, const DanmakuStyle(showTop: false)).length,
        2,
      );
      expect(
        filterDanmakuItems(items, const DanmakuStyle(showBottom: false)).length,
        2,
      );
      // 关闭时一律为空。
      expect(
        filterDanmakuItems(items, const DanmakuStyle(enabled: false)),
        isEmpty,
      );
    });

    test('样式参数被夹紧到合理区间', () {
      const style = DanmakuStyle();
      expect(style.copyWith(opacity: 5).opacity, 1.0);
      expect(style.copyWith(opacity: 0).opacity, 0.1);
      expect(style.copyWith(textScale: 99).textScale, 2.5);
      expect(style.copyWith(textScale: 0).textScale, 0.5);
      // 开关与类型开关不被夹紧影响。
      final off = style.copyWith(enabled: false);
      expect(off.enabled, isFalse);
      expect(off, isNot(style));
    });
  });

  group('弹幕运动与绘制开销（用户反馈：卡顿、文字像有拖影）', () {
    Widget host(DanmakuOverlay overlay) => MaterialApp(
      home: Scaffold(
        body: SizedBox(width: 800, height: 400, child: overlay),
      ),
    );

    DanmakuPainter painterOf(WidgetTester tester) {
      for (final widget in tester.widgetList<CustomPaint>(
        find.byType(CustomPaint),
      )) {
        final painter = widget.painter;
        if (painter is DanmakuPainter) return painter;
      }
      fail('叠加层里没有 DanmakuPainter');
    }

    final items = [
      DanmakuItem(timeMs: 0, text: '滑动的弹幕', type: DanmakuType.scroll),
    ];

    testWidgets('播放中逐帧推进：两次位置上报之间弹幕继续移动', (tester) async {
      var now = DateTime(2026, 1, 1);
      await tester.pumpWidget(
        host(
          DanmakuOverlay(
            items: items,
            position: const Duration(seconds: 2),
            style: const DanmakuStyle(),
            playing: true,
            clockNow: () => now,
          ),
        ),
      );
      final painter = painterOf(tester);
      expect(painter.debugPositionMs, 2000);

      now = now.add(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 16));

      expect(
        painter.debugPositionMs,
        2016,
        reason: '两帧之间的位移必须由渲染层自己插值出来，不能等下一次位置上报',
      );
      expect(
        painterOf(tester),
        same(painter),
        reason: '逐帧推进只该重绘这一层，不该重建整个叠加层',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('暂停时弹幕停在原地', (tester) async {
      var now = DateTime(2026, 1, 1);
      await tester.pumpWidget(
        host(
          DanmakuOverlay(
            items: items,
            position: const Duration(seconds: 2),
            style: const DanmakuStyle(),
            clockNow: () => now,
          ),
        ),
      );
      final painter = painterOf(tester);
      now = now.add(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(painter.debugPositionMs, 2000);
    });

    testWidgets('没有播放器驱动时保持旧语义：位置就是传入的播放位置', (tester) async {
      await tester.pumpWidget(
        host(
          DanmakuOverlay(
            items: [
              DanmakuItem(timeMs: 0, text: '静态', type: DanmakuType.scroll),
            ],
            position: const Duration(seconds: 3),
            style: const DanmakuStyle(),
          ),
        ),
      );
      expect(painterOf(tester).debugPositionMs, 3000);
    });

    testWidgets('重建后继续复用排版缓存（缓存挂在叠加层，不在每帧的绘制器里）', (
      tester,
    ) async {
      var now = DateTime(2026, 1, 1);
      Widget build(Duration position) => host(
        DanmakuOverlay(
          items: items,
          position: position,
          style: const DanmakuStyle(),
          playing: true,
          clockNow: () => now,
        ),
      );

      await tester.pumpWidget(build(const Duration(seconds: 1)));
      final first = painterOf(tester);

      // 一次位置上报导致整层重建：新的绘制器必须共用同一个排版缓存，
      // 否则每次上报都把缓存清空、把可见弹幕重新排一遍。
      now = now.add(const Duration(milliseconds: 100));
      await tester.pumpWidget(build(const Duration(milliseconds: 1100)));
      final second = painterOf(tester);
      expect(second, isNot(same(first)));
      expect(
        identical(second.debugLayoutCache, first.debugLayoutCache),
        isTrue,
        reason: '排版缓存要是每次 rebuild 都新建，等于没缓存',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });

    test('同一批弹幕每帧复用文本排版（不在 paint 里重新排一遍）', () {
      final scene = DanmakuScene.plan(
        items: const [
          DanmakuItem(timeMs: 0, text: '缓存', type: DanmakuType.scroll),
          DanmakuItem(timeMs: 0, text: '描边', type: DanmakuType.top),
        ],
        enabled: true,
        width: 800,
        height: 400,
      );
      final painter = DanmakuPainter(
        scene: scene,
        liveScene: DanmakuScene.empty(),
        style: const DanmakuStyle(),
        positionOf: () => const Duration(milliseconds: 500),
        liveNowOf: () => 0,
      );
      final recorder = PictureRecorder();
      final canvas = Canvas(recorder);
      painter.paint(canvas, const Size(800, 400));
      final afterFirstFrame = painter.debugTextLayoutCount;
      expect(afterFirstFrame, greaterThan(0));

      painter.paint(canvas, const Size(800, 400));
      expect(
        painter.debugTextLayoutCount,
        afterFirstFrame,
        reason: '第二帧应命中缓存：排版是每帧最贵的部分',
      );
      recorder.endRecording().dispose();
    });
  });
}