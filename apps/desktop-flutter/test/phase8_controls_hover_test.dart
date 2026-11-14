/// 控制浮层的鼠标唤醒（`design/01` §4.5）。
///
/// 这两条用例锁的是**同一处守卫的两侧**，缺一条都会漏掉一种错误实现：
///
/// - 去掉第 1 层的 `MouseRegion(onHover:)` → 第 1 条红（唤不醒）；
/// - 把 `onHover` 里的 `if (!_controlsVisible)` 去掉、无条件
///   `_touchControls()` → 第 2 条红（指针一动就重置 3 秒计时器，
///   控制条在有人动鼠标时**永不隐藏**）。
///
/// `design/01` §4.5 原文就点明了这个坑：「不要在 `onHover` 里调用
/// `_touchControls()`……会让 3 秒计时器被无限重置，控制栏永不隐藏」。
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/ui/player_page.dart';

import 'support/player_page_harness.dart';

/// 制造真实的鼠标悬停事件（`PointerHoverEvent`）。
///
/// `PlayerPage` 第 1 层的 `MouseRegion` 只响应移动，所以这里必须用
/// `PointerDeviceKind.mouse` 且**不按下**——按下会变成 `PointerDownEvent`，
/// 走的是手势识别而不是 hover。
Future<TestGesture> _mouseOver(WidgetTester tester, Offset at) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: Offset.zero);
  addTearDown(mouse.removePointer);
  await mouse.moveTo(at);
  await tester.pump();
  return mouse;
}

void main() {
  testWidgets('指针在画面上移动，能从隐藏态唤醒控制浮层', (tester) async {
    await pumpPlayerPage(tester);
    final state = tester.state<State<PlayerPage>>(find.byType(PlayerPage));
    expect(debugPlayerControlsVisible(state), isTrue, reason: '进场即可见');

    // 自动隐藏延时是 3 秒（`design/01` §4.4）。
    await tester.pump(const Duration(milliseconds: 3200));
    expect(
      debugPlayerControlsVisible(state),
      isFalse,
      reason: '3 秒无操作后应自动隐藏',
    );

    await _mouseOver(tester, const Offset(400, 300));
    expect(
      debugPlayerControlsVisible(state),
      isTrue,
      reason: '鼠标移动必须把浮层唤回来（桌面播放器惯例）',
    );
  });

  testWidgets('浮层可见时，指针移动不得重置隐藏计时', (tester) async {
    await pumpPlayerPage(tester);
    final state = tester.state<State<PlayerPage>>(find.byType(PlayerPage));

    // 前置：先让它自动隐藏。
    //
    // 注意**时间基准不是 0**：`pumpPlayerPage` 结尾自己推进了 2 秒，
    // 3 秒计时器从进场就开始算，所以这里再推 1.5 秒即可越过 3 秒。
    await tester.pump(const Duration(milliseconds: 1500));
    expect(
      debugPlayerControlsVisible(state),
      isFalse,
      reason: '前置条件：浮层已自动隐藏',
    );

    // 一次悬停唤醒，计时从这一刻重新开始（这才是被测窗口的起点）。
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(const Offset(400, 300));
    await tester.pump();
    expect(debugPlayerControlsVisible(state), isTrue, reason: '前置条件：悬停已唤醒');

    // 计时窗口内继续移动（累计 1.6 秒）。
    for (var i = 1; i <= 4; i++) {
      await mouse.moveTo(Offset(400.0 + i * 8, 300));
      await tester.pump(const Duration(milliseconds: 400));
    }

    // 再推到唤醒后 3.1 秒。计时器若没被重置，隐藏发生在 3.0 秒 → 此刻已隐藏；
    // 若每次 hover 都重置（错误实现），最后一次重置在 1.6 秒、隐藏要到
    // 4.6 秒 → 此刻仍可见，本条即失败。
    await tester.pump(const Duration(milliseconds: 1500));
    expect(
      debugPlayerControlsVisible(state),
      isFalse,
      reason: '指针移动不应延长控制条的显示时间',
    );
  });
}
