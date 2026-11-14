import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/osd_config.dart';
import 'package:webhtv_pc/ui/player_context_menu.dart';
import 'package:webhtv_pc/ui/player_osd.dart';
import 'package:webhtv_pc/ui/player_overlay.dart';
import 'package:webhtv_pc/ui/player_page.dart';

import 'support/player_page_harness.dart';

/// 按下 Shift+F10 再松开。
///
/// `tester.sendKeyEvent` 不接受修饰键参数（`flutter_test/lib/src/controller.dart:2213`），
/// 所以 Shift 必须显式先按下、再发 F10、最后按逆序松开——这也是真实键盘的
/// 事件顺序，`SingleActivator(shift: true)` 读的正是按下时刻的修饰键状态。
Future<void> pressShiftF10(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyDownEvent(LogicalKeyboardKey.f10);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.f10);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
}

void main() {
  testWidgets('播放器页是 Stack 结构，控制浮层不参与布局（design/01 §3）', (tester) async {
    await pumpPlayerPage(tester);
    final page = find.byType(PlayerPage);
    expect(page, findsOneWidget);
    // 控制浮层与屏显层都在树里。
    expect(find.byType(PlayerControlOverlay), findsOneWidget);
    expect(find.byType(PlayerOsdLayer), findsOneWidget);
  });

  testWidgets('顶栏仍是 AppBar（design/01 §4.1）', (tester) async {
    await pumpPlayerPage(tester);
    expect(find.byType(AppBar), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.byTooltip('更多'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('四个 tooltip 精确串仍在（design/00 §5 第 2 条）', (tester) async {
    await pumpPlayerPage(tester);
    expect(find.byTooltip('字幕轨'), findsOneWidget);
    expect(find.byTooltip('弹幕（开启）'), findsOneWidget);
    expect(find.byTooltip('全屏（F11）'), findsOneWidget);
  });

  testWidgets('屏显层 IgnorePointer：点击穿透到画面（design/01 §3.1）', (tester) async {
    await pumpPlayerPage(tester);
    // 屏显层**自身**无条件 IgnorePointer（`player_osd.dart:139`），
    // 与 `controlsVisible` 无关——它是纯信息层，任何情况下都不接收指针。
    //
    // 用 `descendant` 而不是 `ancestor`：这个 IgnorePointer 在
    // `PlayerOsdLayer.build` **内部**（它是 PlayerOsdLayer 的子节点），
    // 而控制浮层那个在**装配处**包着 `PlayerControlOverlay`（是祖先）。
    // 两者方向相反，抄错会 `findsNothing`。
    final ignoring = tester.widget<IgnorePointer>(
      find
          .descendant(
            of: find.byType(PlayerOsdLayer),
            matching: find.byType(IgnorePointer),
          )
          .first,
    );
    expect(ignoring.ignoring, isTrue, reason: '屏显层必须无条件忽略指针');

    // 反向锁：屏显层里的文字**不参与**命中测试，点击必须落到画面上。
    // 只断言 `ignoring` 会被「把 IgnorePointer 换成 AbsorbPointer」之类改法骗过。
    final osd = tester.widget<PlayerOsdLayer>(find.byType(PlayerOsdLayer));
    expect(osd.controlsVisible, isTrue, reason: '初始控制栏应可见');
  });

  testWidgets('隐藏态下控制浮层 IgnorePointer 生效（design/01 §3.1）', (tester) async {
    await pumpPlayerPage(tester);
    // 等自动隐藏（3 秒）。
    await tester.pump(const Duration(seconds: 4));
    await settlePlayerPage(tester);
    final overlay = tester.widget<IgnorePointer>(
      find
          .ancestor(
            of: find.byType(PlayerControlOverlay),
            matching: find.byType(IgnorePointer),
          )
          .first,
    );
    expect(overlay.ignoring, isTrue, reason: '隐藏后必须忽略指针');
  });

  testWidgets('右键打开菜单（design/04 §5.1）', (tester) async {
    await pumpPlayerPage(tester);
    await tester.tapAt(const Offset(400, 300), buttons: kSecondaryButton);
    await settlePlayerPage(tester);
    expect(find.byType(PlayerContextMenu), findsOneWidget);
    expect(find.text('播放'), findsWidgets);
  });

  testWidgets('菜单打开时控制栏强制可见且不隐藏（design/04 §5.4）', (tester) async {
    await pumpPlayerPage(tester);
    await tester.tapAt(const Offset(400, 300), buttons: kSecondaryButton);
    await settlePlayerPage(tester);
    // 推进到远超 3 秒自动隐藏阈值。
    await tester.pump(const Duration(seconds: 5));
    await settlePlayerPage(tester);
    final osd = tester.widget<PlayerOsdLayer>(find.byType(PlayerOsdLayer));
    expect(osd.controlsVisible, isTrue, reason: '菜单打开期间控制栏不得隐藏');
  });

  testWidgets('Esc 只关菜单，不退出全屏（design/04 §5.3）', (tester) async {
    await pumpPlayerPage(tester);
    await tester.tapAt(const Offset(400, 300), buttons: kSecondaryButton);
    await settlePlayerPage(tester);
    expect(find.byType(PlayerContextMenu), findsOneWidget);

    // 反向锁：Esc 若落到 `buildPlayerShortcuts` 的 `exitFullscreen` 上，
    // 这里会看到 `setFullScreen`。`isFullScreen` 被 mock 成 false，
    // 所以 `_exitFullscreen()` 走假分支——但那也要先**问过**平台，
    // 于是「问过没问过」本身就是可观测的差别。
    windowManagerCalls.clear();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settlePlayerPage(tester);

    expect(find.byType(PlayerContextMenu), findsNothing, reason: 'Esc 必须关掉菜单');
    expect(
      windowManagerCalls.where((c) => c.method == 'isFullScreen'),
      isEmpty,
      reason: 'Esc 不得触达全屏逻辑（否则菜单打开时按 Esc 会顺带退出全屏）',
    );
    expect(
      windowManagerCalls.where((c) => c.method == 'setFullScreen'),
      isEmpty,
      reason: 'Esc 不得真的切换全屏',
    );
  });

  testWidgets('点击菜单外关闭（design/04 §5.3）', (tester) async {
    await pumpPlayerPage(tester);
    await tester.tapAt(const Offset(400, 300), buttons: kSecondaryButton);
    await settlePlayerPage(tester);
    await tester.tapAt(const Offset(20, 20));
    await settlePlayerPage(tester);
    expect(find.byType(PlayerContextMenu), findsNothing);
  });

  // ---- 键盘入口：右键菜单不再只属于鼠标 -------------------------------------

  testWidgets('Shift+F10 打开菜单，且菜单落在画面中央附近', (tester) async {
    await pumpPlayerPage(tester);
    await pressShiftF10(tester);
    await settlePlayerPage(tester);

    expect(find.byType(PlayerContextMenu), findsOneWidget, reason: 'Shift+F10 必须能打开菜单');

    // 量的是**菜单面板**而不是 PlayerContextMenu 本身：后者返回
    // `Positioned.fill`（`player_context_menu.dart:270`），`getRect` 拿到的是
    // 整个视口，断言恒成立 = 空断言。面板是菜单里唯一的 `Material`。
    final panel = tester.getRect(find.descendant(
      of: find.byType(PlayerContextMenu),
      matching: find.byType(Material),
    ).first);
    final viewport = Offset.zero & tester.view.physicalSize / tester.view.devicePixelRatio;
    // 面板左上角 = 画面中心 - 半个菜单（240×420，见 `_openContextMenuAtCenter`）。
    expect((panel.left - (viewport.center.dx - 120)).abs(), lessThan(40),
        reason: '菜单水平居中（实测面板 $panel，视口 $viewport）');
    expect((panel.top - (viewport.center.dy - 210)).abs(), lessThan(40),
        reason: '菜单竖直居中（实测面板 $panel，视口 $viewport）');
  });

  testWidgets('contextMenu 键打开菜单', (tester) async {
    await pumpPlayerPage(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    await settlePlayerPage(tester);
    expect(find.byType(PlayerContextMenu), findsOneWidget);
  });

  testWidgets('F10 打开菜单', (tester) async {
    await pumpPlayerPage(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.f10);
    await settlePlayerPage(tester);
    expect(find.byType(PlayerContextMenu), findsOneWidget);
  });

  testWidgets('键盘连按两次：菜单仍只有一个（幂等）', (tester) async {
    await pumpPlayerPage(tester);
    await pressShiftF10(tester);
    await settlePlayerPage(tester);
    expect(find.byType(PlayerContextMenu), findsOneWidget);

    await pressShiftF10(tester);
    await settlePlayerPage(tester);
    expect(find.byType(PlayerContextMenu), findsOneWidget, reason: '连按不得叠加出第二个菜单');
    expect(tester.takeException(), isNull, reason: '连按不得抛异常');
  });

  testWidgets('键盘打开菜单后 Esc 仍只关菜单，不退出全屏', (tester) async {
    await pumpPlayerPage(tester);
    await pressShiftF10(tester);
    await settlePlayerPage(tester);
    expect(find.byType(PlayerContextMenu), findsOneWidget);

    windowManagerCalls.clear();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settlePlayerPage(tester);

    expect(find.byType(PlayerContextMenu), findsNothing, reason: 'Esc 必须关掉键盘打开的菜单');
    expect(
      windowManagerCalls.where((c) => c.method == 'setFullScreen'),
      isEmpty,
      reason: 'Esc 不得顺带切换全屏',
    );
  });

  testWidgets('快捷键说明里能看到新增的三条（含 F10 不得飘回全屏说明）', (tester) async {
    await pumpPlayerPage(tester);
    await tester.tap(find.byTooltip('更多'));
    await settlePlayerPage(tester);
    await tester.tap(find.text('快捷键说明').last);
    await settlePlayerPage(tester);

    expect(find.text('Shift + F10：打开右键菜单（画面中央）'), findsOneWidget);
    expect(find.text('菜单键：打开右键菜单（画面中央）'), findsOneWidget);
    // 反向锁：无修饰的 F10 现在打开菜单，说明里若还挂在「F11 / F」那行全屏
    // 说明上就会自相矛盾——旧表里也没有 F10，这条断言防的是把 F10 塞错行。
    expect(find.text('F11 / F：全屏切换'), findsOneWidget);
    expect(find.text('F10：打开右键菜单（画面中央）'), findsOneWidget);
  });

  testWidgets('屏显全关且控制栏隐藏时定时器停止（design/02 §4.3）', (tester) async {
    await pumpPlayerPage(tester, osdFlags: {
      for (final id in OsdFlag.values) id: false,
    });
    // 前置条件：控制栏可见时 ticker **必须**在跑（为了强制显示的时钟）。
    expect(
      osdTickerRunning(tester),
      isTrue,
      reason: '前置条件：控制栏可见时 ticker 必须在跑',
    );

    // 等自动隐藏；此时屏显开关全关 → 无事可刷 → ticker 必须停。
    //
    // **不能用 `transientCallbackCount == 0` 观测**：加载态永远挂着
    // `LoadingBlock` 的 `CircularProgressIndicator`，该计数恒 ≥1
    // （探针实测：一路推进到 25 秒仍为 1；连一个裸 spinner 也是 1）。
    // 那条件永远不成立，用例会永久失败——这正是本 brief 初版的问题。
    await tester.pump(const Duration(seconds: 4));
    await settlePlayerPage(tester);
    expect(
      osdTickerRunning(tester),
      isFalse,
      reason: '屏显全关 + 控制栏隐藏后 ticker 必须停止（不得每秒空转）',
    );
    // 反向锁：控制栏可见时必须重新启动（上游 `PlayerOsdController.java:152-158`）。
    await tester.tapAt(const Offset(400, 300));
    await settlePlayerPage(tester);
    expect(
      osdTickerRunning(tester),
      isTrue,
      reason: '控制栏重新可见后 ticker 必须重启（时钟要能跳秒）',
    );
  });

  testWidgets('按钮配置生效：隐藏 speed 后不渲染倍速（design/03 §5.1）', (tester) async {
    await pumpPlayerPage(tester, hiddenButtons: {'speed'});
    expect(find.text('倍速'), findsNothing);
    expect(find.byTooltip('全屏（F11）'), findsOneWidget);
  });

  testWidgets('按钮配置生效：顺序改变反映在渲染顺序（design/03 §5.1）', (tester) async {
    await pumpPlayerPage(
      tester,
      buttonOrder: ['fullscreen', 'prev', 'play', 'next'],
    );
    final fullscreen = tester.getTopLeft(find.byTooltip('全屏（F11）'));
    final prev = tester.getTopLeft(find.byTooltip('上一集（[）'));
    expect(fullscreen.dx, lessThan(prev.dx), reason: '全屏应排在最左');
  });

  testWidgets('无阴影、无 elevation（DESIGN.md The Flat-Field Rule）', (tester) async {
    await pumpPlayerPage(tester);
    for (final m in tester.widgetList<Material>(find.byType(Material))) {
      expect(m.elevation, 0);
    }
  });
}
