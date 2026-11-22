/// 弹幕场景预排（`lib/core/danmaku.dart` 的 `DanmakuScene`）。
///
/// 渲染层现在每帧都要问一次「此刻显示哪些弹幕」：旧的
/// `DanmakuTrackAllocator.visibleAt` 每次都重排全表（排序 + 全量轨道分配），
/// 一集几千条弹幕时就是每帧 O(n log n)。`DanmakuScene` 把轨道预排一次，
/// 之后按开始时刻二分窗口，只碰真正活跃的那几条。
///
/// 这里锁两件事：**结果与旧实现逐条一致**（轨道、进度、顺序），以及
/// **窗口边界**（开始那一刻可见、活到时长整点为止）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/danmaku.dart';

List<DanmakuItem> buildItems() {
  final items = <DanmakuItem>[];
  for (var i = 0; i < 120; i++) {
    items.add(
      DanmakuItem(
        timeMs: i * 700,
        text: i.isEven ? '第 $i 条中文弹幕' : 'item-$i',
        type: switch (i % 4) {
          0 => DanmakuType.scroll,
          1 => DanmakuType.top,
          2 => DanmakuType.bottom,
          _ => DanmakuType.reverse,
        },
        textSizeSp: i % 5 == 0 ? 18 : 16,
      ),
    );
  }
  // 同一时刻挤满：验证轨道满时的丢弃也一致。
  for (var i = 0; i < 40; i++) {
    items.add(DanmakuItem(timeMs: 12000, text: '同时涌进 $i', type: DanmakuType.scroll));
  }
  return items;
}

void expectSame(List<VisibleDanmaku> actual, List<VisibleDanmaku> expected) {
  expect(actual.length, expected.length, reason: '可见条数必须一致');
  for (var i = 0; i < expected.length; i++) {
    expect(actual[i].item, expected[i].item, reason: '第 $i 条顺序/身份');
    expect(actual[i].track, expected[i].track, reason: '第 $i 条轨道');
    expect(actual[i].progress, closeTo(expected[i].progress, 1e-9));
  }
}

void main() {
  group('DanmakuScene', () {
    test('与旧 visibleAt 逐条一致（多位置、多尺寸、多时长）', () {
      final items = buildItems();
      const sizes = [
        (1280.0, 720.0),
        (800.0, 450.0),
        (2560.0, 1440.0),
      ];
      const durations = [
        (8000, 4000),
        (4000, 1000),
        (20000, 8000),
      ];
      for (final (width, height) in sizes) {
        for (final (scroll, fixed) in durations) {
          final scene = DanmakuScene.plan(
            items: items,
            enabled: true,
            scrollDurationMs: scroll,
            fixedDurationMs: fixed,
            width: width,
            height: height,
          );
          for (var position = 0; position <= 90000; position += 1379) {
            expectSame(
              scene.visibleAt(position),
              DanmakuTrackAllocator.visibleAt(
                items: items,
                positionMs: position,
                enabled: true,
                scrollDurationMs: scroll,
                fixedDurationMs: fixed,
                width: width,
                height: height,
              ),
            );
          }
        }
      }
    });

    test('窗口边界：开始那一刻可见，活到时长整点为止', () {
      final scene = DanmakuScene.plan(
        items: [
          DanmakuItem(timeMs: 5000, text: '边界', type: DanmakuType.scroll),
        ],
        enabled: true,
        scrollDurationMs: 10000,
        fixedDurationMs: 4000,
        width: 1280,
        height: 720,
      );

      expect(scene.visibleAt(4999), isEmpty);
      final entering = scene.visibleAt(5000);
      expect(entering, hasLength(1));
      expect(entering.single.progress, 0.0);
      expect(scene.visibleAt(10000).single.progress, closeTo(0.5, 1e-9));
      expect(scene.visibleAt(15000).single.progress, closeTo(1.0, 1e-9));
      expect(scene.visibleAt(15001), isEmpty);
    });

    test('关闭弹幕或没有条目时场景为空', () {
      final items = buildItems();
      expect(
        DanmakuScene.plan(items: items, enabled: false).visibleAt(12000),
        isEmpty,
      );
      expect(
        DanmakuScene.plan(items: const [], enabled: true).visibleAt(0),
        isEmpty,
      );
    });

    test('几千条弹幕里查询只返回活跃那些', () {
      final items = [
        for (var i = 0; i < 5000; i++)
          DanmakuItem(timeMs: i * 120, text: '长片弹幕 $i', type: DanmakuType.scroll),
      ];
      final scene = DanmakuScene.plan(
        items: items,
        enabled: true,
        scrollDurationMs: 12000,
        fixedDurationMs: 4000,
        width: 1920,
        height: 1080,
      );
      final visible = scene.visibleAt(600000);
      expect(visible, isNotEmpty);
      for (final entry in visible) {
        final elapsed = 600000 - entry.item.timeMs;
        expect(elapsed, inInclusiveRange(0, 12000));
      }
    });
  });
}
