import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:webhtv_pc/ui/window_mode.dart';

/// 应用壳层的全屏逃生口：页面已经 pop、全屏却没恢复时，用户还能按 Esc。
///
/// 为什么单独测这个 widget：它挂在 `MaterialApp.builder` 里（Navigator 之上），
/// 直接 pump 整个 `WebHtvApp` 会拉起真实 bootstrap；这里只验证「快捷键 →
/// 退出全屏 + 恢复标题栏」这条链路。
const MethodChannel _channel = MethodChannel('window_manager');

void main() {
  late bool fullscreen;
  late List<MethodCall> calls;

  void installMock(WidgetTester tester) {
    fullscreen = false;
    calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (
      call,
    ) async {
      calls.add(call);
      switch (call.method) {
        case 'isFullScreen':
          return fullscreen;
        case 'setFullScreen':
          fullscreen = (call.arguments as Map)['isFullScreen'] as bool;
          return null;
        case 'isFocused':
          return true;
        case 'isPreventClose':
          return false;
        default:
          return null;
      }
    });
  }

  Future<void> pumpShell(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: WindowEscapeShortcuts(
          child: Scaffold(
            body: Focus(autofocus: true, child: const SizedBox.expand()),
          ),
        ),
      ),
    );
  }

  testWidgets('非播放页按 Esc：退出全屏并恢复标题栏', (tester) async {
    installMock(tester);
    // 先让平台处于全屏，壳层 initState 的回读才会把它记下来。
    fullscreen = true;
    await pumpShell(tester);
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump();

    expect(fullscreen, isFalse, reason: 'Esc 必须真的退出全屏');
    expect(calls.where((call) => call.method == 'setFullScreen'), isNotEmpty);
    final styleCalls = calls
        .where((call) => call.method == 'setTitleBarStyle')
        .toList();
    expect(styleCalls, isNotEmpty);
    expect((styleCalls.last.arguments as Map)['titleBarStyle'], 'normal');
    expect(
      (styleCalls.last.arguments as Map)['windowButtonVisibility'],
      isTrue,
    );
  });

  testWidgets('窗口态按 Esc：不产生全屏/标题栏调用', (tester) async {
    installMock(tester);
    await pumpShell(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump();

    expect(calls.where((call) => call.method == 'setFullScreen'), isEmpty);
    expect(calls.where((call) => call.method == 'setTitleBarStyle'), isEmpty);
  });
}
