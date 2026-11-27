import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:webhtv_pc/ui/player_page.dart';

import 'support/player_page_harness.dart';

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
      reason:
          'setAsFrameless 会把插件内 is_frameless_ 置 true，'
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

  testWidgets('非 Windows 的 F11：标题栏先转 hidden，再进全屏', (tester) async {
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

  testWidgets('Windows：F11 与返回只提交全屏状态', (tester) async {
    await pumpPlayerPage(tester, pushRoute: true, trackFullscreen: true);
    windowManagerCalls.clear();

    await tester.sendKeyEvent(LogicalKeyboardKey.f11);
    await settlePlayerPage(tester);
    expect(windowManagerFullscreen, isTrue);
    await tester.tap(find.byType(BackButton));
    await settlePlayerPage(tester);

    expect(find.byType(PlayerPage), findsNothing);
    expect(windowManagerFullscreen, isFalse);
    expect(methods(), isNot(contains('setTitleBarStyle')));
    expect(methods(), isNot(contains('setAsFrameless')));
    expect(
      windowManagerCalls
          .where((c) => c.method == 'setFullScreen')
          .map((c) => (c.arguments as Map)['isFullScreen']),
      [true, false],
    );
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('全屏播放后点返回：先退出全屏再 pop，标题栏恢复', (tester) async {
    await pumpPlayerPage(tester, pushRoute: true, trackFullscreen: true);
    await tester.sendKeyEvent(LogicalKeyboardKey.f11);
    await settlePlayerPage(tester);
    expect(windowManagerFullscreen, isTrue, reason: '前置：必须真的进入全屏');

    await tester.tap(find.byType(BackButton));
    await settlePlayerPage(tester);

    expect(find.byType(PlayerPage), findsNothing, reason: '返回必须真的退出播放页');
    final setCalls = windowManagerCalls
        .where((call) => call.method == 'setFullScreen')
        .toList();
    expect(
      (setCalls.last.arguments as Map)['isFullScreen'],
      isFalse,
      reason: '退出播放前必须退出全屏，否则窗口停在 fullscreen',
    );
    final styleCalls = windowManagerCalls
        .where((call) => call.method == 'setTitleBarStyle')
        .toList();
    expect(
      (styleCalls.last.arguments as Map)['titleBarStyle'],
      'normal',
      reason: '标题栏必须恢复，否则最小化/最大化/关闭按钮不可见',
    );
    expect(
      (styleCalls.last.arguments as Map)['windowButtonVisibility'],
      isTrue,
    );
  });

  testWidgets('播放页被销毁时兜底恢复窗口（不经过返回键）', (tester) async {
    await pumpPlayerPage(tester, trackFullscreen: true);
    await tester.sendKeyEvent(LogicalKeyboardKey.f11);
    await settlePlayerPage(tester);
    expect(windowManagerFullscreen, isTrue);

    windowManagerCalls.clear();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pump();

    final setCalls = windowManagerCalls
        .where((call) => call.method == 'setFullScreen')
        .toList();
    expect(setCalls, isNotEmpty, reason: 'dispose 必须兜底退出全屏');
    expect(
      (setCalls.last.arguments as Map)['isFullScreen'],
      isFalse,
      reason: '页面销毁后窗口必须回到窗口态',
    );
    final styleCalls = windowManagerCalls
        .where((call) => call.method == 'setTitleBarStyle')
        .toList();
    expect((styleCalls.last.arguments as Map)['titleBarStyle'], 'normal');
  });
}
