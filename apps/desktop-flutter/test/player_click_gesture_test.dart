/// 播放器画面点击语义（桌面播放器惯例，`docs/phase8/design/01` §4.6）。
///
/// 锁三件事：
/// 1. **单击 = 暂停/播放**，且不得顺带切全屏；
/// 2. **双击 = 全屏/退出全屏**，且第 2 击要把播放状态拨回第 1 击前（双击不改变
///    播放状态）；
/// 3. 两击间隔超过判定窗就是两次单击，不得被误判成双击。
///
/// 为什么单独一个套件：这套语义是本轮**有意**偏离上游安卓控制层的产品决策
/// （安卓单击只显隐控制栏），它既要在纯函数层锁住分派，也要在真实 widget 树上
/// 验证「单击不触发全屏 / 双击只触发一次全屏」——后者靠 `window_manager`
/// 的调用流水观测，不需要真实窗口。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/ui/player_page.dart';

import 'support/player_page_harness.dart';

void main() {
  test('单击翻转播放，双击在第一击之上再切全屏（纯语义）', () {
    expect(
      resolvePlayerGesture(doubleClick: false),
      PlayerGestureAction.togglePlayback,
      reason: '单击是传输控制，不是显隐控制栏（安卓语义）',
    );
    expect(
      resolvePlayerGesture(doubleClick: true),
      PlayerGestureAction.togglePlaybackAndFullscreen,
      reason: '双击 = 第 2 击照常翻转（与第 1 击抵消）+ 切换全屏',
    );
  });

  testWidgets('双击判定窗：窗口内第 2 击算双击，窗口外不算', (tester) async {
    final gate = PlayerDoubleClickGate();
    addTearDown(gate.dispose);

    expect(gate.registerTap(), isFalse, reason: '第 1 击永远是单击');
    expect(gate.registerTap(), isTrue, reason: '窗口内的第 2 击是双击');
    expect(
      gate.registerTap(),
      isFalse,
      reason: '双击成立后窗口立即重置：第 3 击属于新的一轮',
    );

    // 走完一个判定窗（含余量）后，计时器到期，下一次点击重新算单击。
    await tester.pump(kPlayerDoubleClickWindow + const Duration(milliseconds: 50));
    expect(gate.registerTap(), isFalse);
    await tester.pump(kPlayerDoubleClickWindow + const Duration(milliseconds: 50));
    expect(
      gate.registerTap(),
      isFalse,
      reason: '相隔超过判定窗的两次点击不是双击',
    );

    // 这个用例没有 widget 树，没人替它 dispose：留在 FakeAsync 里的判定窗计时器
    // 会被框架判成「A Timer is still pending」而失败（实测踩过）。
    gate.dispose();
  });

  testWidgets('单击画面：不进全屏，控制栏立即回来', (tester) async {
    await pumpPlayerPage(tester, trackFullscreen: true);
    final state = tester.state<State<PlayerPage>>(find.byType(PlayerPage));

    // 前置：等 3 秒自动隐藏生效。
    await tester.pump(const Duration(seconds: 4));
    await settlePlayerPage(tester);
    expect(
      debugPlayerControlsVisible(state),
      isFalse,
      reason: '前置条件：控制栏已隐藏',
    );

    windowManagerCalls.clear();
    await tester.tapAt(const Offset(400, 300));
    await tester.pump();

    expect(
      debugPlayerControlsVisible(state),
      isTrue,
      reason: '单击必须立刻唤回控制栏：暂停是静默状态，没有反馈会像没点上',
    );
    expect(
      windowManagerCalls.where((call) => call.method == 'setFullScreen'),
      isEmpty,
      reason: '单击不得进全屏；全屏只属于双击',
    );

    // 让点击开启的 3 秒隐藏计时器与判定窗都跑完，避免留下 pending timer。
    await settlePlayerPage(tester);
  });

  testWidgets('双击画面：进全屏，且只发一次全屏切换', (tester) async {
    await pumpPlayerPage(tester, trackFullscreen: true);
    windowManagerCalls.clear();

    // 两次 tap 之间不 pump：判定窗按假时钟计时，同一刻到达即双击。
    await tester.tapAt(const Offset(400, 300));
    await tester.tapAt(const Offset(400, 300));
    await settlePlayerPage(tester);

    final setFullScreen = windowManagerCalls
        .where((call) => call.method == 'setFullScreen')
        .toList(growable: false);
    expect(
      setFullScreen,
      hasLength(1),
      reason: '两次点击只该触发一次全屏切换（实测：${windowManagerCalls.map((c) => c.method)}）',
    );
    expect(
      (setFullScreen.single.arguments as Map)['isFullScreen'],
      isTrue,
      reason: '要的是进入全屏，不是退出',
    );

    // 双击的第 2 击会显式恢复播放状态；等它的异步调用落地。
    await settlePlayerPage(tester);
  });

  testWidgets('双击画面：已全屏时退出全屏（同一入口的两个方向）', (tester) async {
    await pumpPlayerPage(tester, trackFullscreen: true);

    // 先用控制栏按钮进全屏，建立「已全屏」这个前提。
    await tester.tap(find.byTooltip('全屏（F11）'));
    await settlePlayerPage(tester);
    expect(windowManagerFullscreen, isTrue, reason: '前置条件：已经进入全屏');

    windowManagerCalls.clear();
    await tester.tapAt(const Offset(400, 300));
    await tester.tapAt(const Offset(400, 300));
    await settlePlayerPage(tester);

    final setFullScreen = windowManagerCalls
        .where((call) => call.method == 'setFullScreen')
        .toList(growable: false);
    expect(setFullScreen, hasLength(1), reason: '双击只该切换一次全屏');
    expect(
      (setFullScreen.single.arguments as Map)['isFullScreen'],
      isFalse,
      reason: '全屏态下的双击必须是**退出**全屏',
    );
    expect(windowManagerFullscreen, isFalse);
  });

  testWidgets('两击间隔超过判定窗：按两次单击处理，不进全屏', (tester) async {
    await pumpPlayerPage(tester, trackFullscreen: true);
    windowManagerCalls.clear();

    await tester.tapAt(const Offset(400, 300));
    await tester.pump(
      kPlayerDoubleClickWindow + const Duration(milliseconds: 50),
    );
    await tester.tapAt(const Offset(400, 300));
    await settlePlayerPage(tester);

    expect(
      windowManagerCalls.where((call) => call.method == 'setFullScreen'),
      isEmpty,
      reason: '相隔超过判定窗的两次点击不是双击',
    );
  });
}
