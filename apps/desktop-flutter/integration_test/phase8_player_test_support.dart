/// 挂载 `PlayerPage` 的集成套件共用的两个辅助。
///
/// ## 为什么需要单独一个文件
///
/// Phase 8 给播放器页加了两个会推翻既有测试假设的行为
/// （`design/01` §4.4/§4.5）。它们是**产品要求**，不是缺陷，
/// 所以修的是测试写法，不是产品。
///
/// ### 1. 屏显时钟每秒 `setState`，`pumpAndSettle(d)` 永不 settle
///
/// `OsdFlag.time` 默认 true（`lib/core/osd_config.dart:61`），而
/// `lib/ui/player_osd.dart:86` 的 `_clockVisible = controlsVisible || flags[time]`
/// 让时钟**永远**显示，于是 `_osdNeedsTicker`（`lib/ui/player_page.dart`）
/// 恒为真，1 秒一次的 `Timer.periodic` 常驻。
///
/// `pumpAndSettle(const Duration(seconds: n))` 以 n 为步长推进：
/// 只要 n ≥ 1 秒，**每一步都必然跨过一次定时器触发**，`hasScheduledFrame`
/// 永远为真，循环跑到 10 分钟默认超时后抛 `pumpAndSettle timed out`。
/// 实测（`subtitle_flow_test.dart:148`，`n=2`）：`10:09` 抛出。
///
/// 注意 `pumpAndSettle()`（**不带时长**）不受影响：默认步长 100ms，
/// 只有恰好跨过秒边界的那些步会重绘，其余步都能收敛。
/// 所以只需替换带时长的那种。
///
/// ### 2. 控制浮层 3 秒后自动隐藏并 `IgnorePointer`
///
/// 「点一下 → settle → 再点另一个按钮」的写法里，第二次点击落在已隐藏的
/// 浮层上。`tester.tap` 默认只 `warnIfMissed` 打一句警告，
/// 断言随后以「找不到 / 状态没变」的形式失败——**看不出真正原因**。
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/ui/player_page.dart';

/// 静置到画面稳定，但**不要求定时器停下**。
///
/// 语义上等价于「等这么久」：`pumpAndSettle(d)` 在正常页面上本来就等 d
/// 左右，调用方随后都要自己轮询真实异步（网络、解码）的状态，
/// 所以固定次数推进即可。
Future<void> settlePlayerPage(
  WidgetTester tester, {
  Duration total = const Duration(seconds: 2),
  Duration step = const Duration(milliseconds: 100),
}) async {
  final frames = (total.inMicroseconds / step.inMicroseconds).ceil();
  for (var i = 0; i < frames; i++) {
    await tester.pump(step);
  }
}

/// 让控制浮层回到可见态（`design/01` §4.4）。
///
/// **不能再用「单击画面」**：桌面语义下单击画面是**暂停/播放**
/// （`design/01` §4.6），用它唤醒控制栏会顺带暂停视频，字幕/弹幕用例
/// 后续的「仍在播」断言就不再成立。这里走 `@visibleForTesting` 的唤醒缝，
/// 它调用的就是产品自己的 `_touchControls()`。
///
/// 也**不能模拟鼠标悬停**：真实窗口下 `LiveTestWidgetsFlutterBinding`
/// 已经在跟踪真实的鼠标设备，`tester.createGesture(kind: PointerDeviceKind.mouse)`
/// 再加一个指针会让 `MouseTracker` 直接断言失败
/// （`(event is PointerAddedEvent) == (lastEvent is PointerRemovedEvent)`，
/// 实测在 `subtitle_flow_test.dart` 第一条用例就抛出）。
Future<void> revealPlayerControls(WidgetTester tester) async {
  final state = tester.state<State<PlayerPage>>(find.byType(PlayerPage));
  if (debugPlayerControlsVisible(state)) return;
  debugRevealPlayerControls(state);
  await tester.pump();
  // AnimatedOpacity 需要一帧登记 ticker、再一帧推进；单次 pump 拍到的
  // 仍是 opacity 0（`design/05` §1.3 记过这个坑）。
  await tester.pump(const Duration(milliseconds: 300));
}
