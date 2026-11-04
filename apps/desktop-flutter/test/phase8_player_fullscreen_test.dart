import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/player_page_harness.dart';

/// 播放器全屏必须真的铺满显示器。
///
/// 缺陷成因（window_manager 0.5.2）：
/// - `windows/window_manager.cpp:591-614` 里把窗口 `SetWindowPos` 到显示器
///   `rcMonitor` 的整段铺满逻辑，全部包在 :593 的 `if (!is_frameless_)` 内。
/// - `SetAsFrameless()`（`window_manager.cpp:214-225`）只置 `is_frameless_ = true`
///   并 `SetWindowPos(SWP_NOSIZE)`，**不会**改 `GWL_STYLE`、也不会移动窗口。
/// - 因此旧实现「先 `setAsFrameless()` 再 `setFullScreen(true)`」会让 :593 判定
///   失败，铺满分支整体跳过，窗口停在原尺寸，只有 `WM_NCCALCSIZE`
///   （`window_manager_plugin.cpp:147-154`）把它当成无边框——观感是一块
///   原位不动的无边框小窗，而不是全屏。
/// - `IsFullScreen()`（`window_manager.cpp:564-566`）只返回内部标志
///   `g_is_window_fullscreen`，不查询真实窗口状态，所以旧实现的「回读确认」
///   是同义反复、永远为 true，无法发现铺满失败。
///
/// 这些用例断言的不是「看过窗口」，而是**调用序列**：进入全屏的调用里不得出现
/// `setAsFrameless`，且必须先 `setTitleBarStyle(hidden)` 再 `setFullScreen(true)`。
/// 序列一旦回到旧样子，铺满分支就必然被跳过。
void main() {
  List<String> methods() =>
      windowManagerCalls.map((c) => c.method).toList(growable: false);

  testWidgets('点全屏按钮：铺满路径不得调用 setAsFrameless', (tester) async {
    await pumpPlayerPage(tester);
    windowManagerCalls.clear();

    await tester.tap(find.byTooltip('全屏（F11）'));
    await settlePlayerPage(tester);

    expect(
      methods(),
      isNot(contains('setAsFrameless')),
      reason: 'setAsFrameless 会把插件内 is_frameless_ 置 true，'
          '使 window_manager.cpp:593 的铺满分支被跳过（实测调用序列：${methods()}）',
    );
    expect(methods(), contains('setFullScreen'));
    final setFullScreen = windowManagerCalls.lastWhere(
      (c) => c.method == 'setFullScreen',
    );
    expect(
      (setFullScreen.arguments as Map)['isFullScreen'],
      isTrue,
      reason: '要的是进入全屏，不是退出',
    );
  });

  testWidgets('F11 快捷键：标题栏先转 hidden，再进全屏', (tester) async {
    await pumpPlayerPage(tester);
    windowManagerCalls.clear();

    await tester.sendKeyEvent(LogicalKeyboardKey.f11);
    await settlePlayerPage(tester);

    final sequence = methods();
    expect(sequence, isNot(contains('setAsFrameless')));

    final hiddenIndex = windowManagerCalls.indexWhere(
      (c) =>
          c.method == 'setTitleBarStyle' &&
          (c.arguments as Map)['titleBarStyle'] == 'hidden',
    );
    final fullScreenIndex = windowManagerCalls.indexWhere(
      (c) =>
          c.method == 'setFullScreen' &&
          (c.arguments as Map)['isFullScreen'] == true,
    );
    expect(hiddenIndex, isNonNegative, reason: '进入全屏前必须把标题栏设为 hidden');
    expect(fullScreenIndex, isNonNegative);
    expect(
      hiddenIndex,
      lessThan(fullScreenIndex),
      reason: 'hidden 必须早于 setFullScreen(true)（实测序列：$sequence）',
    );
  });
}
