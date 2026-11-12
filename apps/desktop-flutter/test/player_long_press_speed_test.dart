/// 长按画面快进：倍速来自用户设置（`PlayerOptions.longPressSpeed`，默认 3×）。
///
/// 锁三件事：
/// 1. 默认档位就是 3×（需求方 2026-11 明确要的默认值，此前写死 2×）；
/// 2. 长按**立即**请求设置里的那一档，而不是读一份启动时的快照；
/// 3. 松开恢复原速，且引擎拒绝改速时不把异常抛到页面。
///
/// 引擎在无原生实现的 widget 测试里不会回报真实速率，所以用
/// `debugLastGestureSpeed`（最近一次长按请求值）作为观测缝。
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/ui/player_page.dart';

import 'support/player_page_harness.dart';

/// 按住画面直到长按成立，返回仍按着的指针。
Future<TestGesture> _holdVideo(WidgetTester tester) async {
  final gesture = await tester.startGesture(const Offset(400, 300));
  // 长按识别器在 kLongPressTimeout 到点时才判成立；多推 50ms 留余量。
  await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
  return gesture;
}

void main() {
  testWidgets('长按画面请求的倍速默认 3×，松开后不抛异常', (tester) async {
    await pumpPlayerPage(tester);
    final state = tester.state<State<PlayerPage>>(find.byType(PlayerPage));

    final gesture = await _holdVideo(tester);
    expect(
      debugLastGestureSpeed(state),
      3,
      reason: '默认长按倍速必须是 3×（PlayerOptions.defaultLongPressSpeed）',
    );

    await gesture.up();
    await settlePlayerPage(tester);
    expect(
      tester.takeException(),
      isNull,
      reason: '改速失败只记日志；长按/松开不得把异常抛到页面',
    );
  });

  testWidgets('改过设置后长按立即用新档位（不重启播放器）', (tester) async {
    await pumpPlayerPage(tester);
    final state = tester.state<State<PlayerPage>>(find.byType(PlayerPage));
    final page = tester.widget<PlayerPage>(find.byType(PlayerPage));

    // 模拟「在播放器里打开完整设置页，把长按倍速改成 2.5× 再返回」。
    await tester.runAsync(
      () => page.state.setPlayerOptions(
        page.state.playerOptions.copyWith(longPressSpeed: 2.5),
      ),
    );

    final gesture = await _holdVideo(tester);
    expect(
      debugLastGestureSpeed(state),
      2.5,
      reason: '长按必须读当下生效的设置，而不是进页时的快照',
    );

    await gesture.up();
    await settlePlayerPage(tester);
    expect(tester.takeException(), isNull);
  });
}
