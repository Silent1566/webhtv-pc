/// 弹幕渲染层 widget 测试（设计文档 §21 Phase 3「字幕/弹幕可开启和关闭」）。
///
/// **为什么单独一个文件**：`testWidgets` 会初始化 flutter_test 的 binding，而该
/// binding 会拦截本进程内的所有 HTTP 请求（统一返回 400）。因此凡是需要真实
/// HTTP 的测试（DanmakuService 加载）必须放在**没有** `testWidgets` 的文件里，
/// 否则会拿到假 400 而不是真实响应。这里只做纯渲染/样式断言，不发网络。
library;

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
}
