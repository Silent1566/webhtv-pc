/// Phase 8 · 播放器全屏必须真正铺满显示器（真实窗口，`flutter test -d windows`）。
///
/// ## 为什么这个套件存在
///
/// 缺陷症状不是「全屏没生效」，而是「全屏后窗口停在原尺寸，只是变成无边框小窗」。
/// `window_manager` 在 Windows 上的全屏就是「去边框 + SetWindowPos 到
/// monitor.rcMonitor」，而整段铺满逻辑被
/// `window_manager-0.5.2/windows/window_manager.cpp:593` 的
/// `if (!is_frameless_)` 包住。旧代码在 setFullScreen(true) 之前先调了
/// `setAsFrameless()`，把 is_frameless_ 置为 true，铺满分支整体被跳过。
///
/// 桩测试（`test/phase8_player_fullscreen_test.dart`）只能断言播放器**调用了
/// 哪些** window_manager 方法；那证明不了窗口真的铺满了显示器。
/// 只有真实窗口 + 真实窗口管理器能证明，所以本套件断言
/// *真实窗口矩形* 与 *真实显示器矩形* 相等。
///
/// ## 单位
/// `windowManager.getBounds()` 返回**逻辑像素**
/// （window_manager.cpp:721-730 把 GetWindowRect 的每个值除以 devicePixelRatio）；
/// `Display.size` 是**物理像素**（sky_engine/lib/ui/window.dart:30-31）。
/// 两者只有 DPI 缩放 100% 时才相等，所以这里统一换算成逻辑像素再比。
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/player_page.dart';
import 'package:webhtv_pc/ui/theme.dart';
import 'package:window_manager/window_manager.dart';

import '../test/fixture_support.dart';
import 'phase8_player_test_support.dart';

void evidence(String message) =>
    debugPrint('PHASE8-FULLSCREEN-EVIDENCE $message');

Future<bool> fixtureReachable() async {
  try {
    final client = HttpClient()
      ..connectionTimeout = const Duration(milliseconds: 500);
    final request = await client.getUrl(Uri.parse('$fixtureBaseUrl/health'));
    final response = await request.close();
    await response.drain<void>();
    client.close();
    return response.statusCode == 200;
  } catch (_) {
    return false;
  }
}

/// 显示器矩形（换算成逻辑像素）。
///
/// 多显示器时取面积最大的那块——本用例只验证「铺满某个显示器」，
/// 具体是哪一块由 window_manager 的 MONITOR_DEFAULTTONEAREST 决定。
Rect displayRectLogical() {
  final displays = ui.PlatformDispatcher.instance.displays.toList();
  if (displays.isEmpty) return Rect.zero;
  displays.sort(
    (a, b) => (b.size.width * b.size.height).compareTo(a.size.width * a.size.height),
  );
  final best = displays.first;
  final ratio = best.devicePixelRatio == 0 ? 1.0 : best.devicePixelRatio;
  return Rect.fromLTWH(0, 0, best.size.width / ratio, best.size.height / ratio);
}

/// 轮询到 [predicate] 成立为止：每轮推进一帧并让出真实 async 区。
Future<bool> waitFor(
  WidgetTester tester,
  Future<bool> Function() predicate, {
  int attempts = 40,
  Duration step = const Duration(milliseconds: 150),
}) async {
  for (var i = 0; i < attempts; i++) {
    final ok = await tester.runAsync(predicate);
    if (ok == true) return true;
    await tester.pump(step);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 60)),
    );
  }
  return await tester.runAsync(predicate) ?? false;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  setUpAll(() async {
    await windowManager.ensureInitialized();
  });

  testWidgets('点全屏按钮：真实窗口铺满显示器，退出后回到原矩形', (tester) async {
    if (!await fixtureReachable()) {
      markTestSkipped(
        'fixture 服务不可达（$fixtureBaseUrl）：'
        '先运行 `python tools/fixture_server/server.py`',
      );
      return;
    }
    final temp = Directory.systemTemp.createTempSync('webhtv-phase8-fs-window');
    final paths = AppPaths.resolve(
      overrides: {
        'config': '${temp.path}/webhtv-pc',
        'data': '${temp.path}/webhtv-pc',
        'cache': '${temp.path}/webhtv-pc/cache',
        'state': '${temp.path}/webhtv-pc/logs',
      },
    );
    final state = AppState(paths: paths, log: LogService());
    addTearDown(() {
      state.dispose();
      try {
        temp.deleteSync(recursive: true);
      } catch (_) {}
    });
    await state.bootstrap();

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(Brightness.dark),
        home: Scaffold(
          body: PlayerPage(
            state: state,
            request: PlaybackRequest(
              url: '$fixtureBaseUrl/media/sample.m3u8',
              title: '示例剧集',
              siteKey: 'fixture',
              vodId: 'demo-1',
              vodName: '示例剧集',
              episodeName: 'E3',
              flag: '线路一',
              headers: fixtureMediaHeaders,
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 24; i++) {
      await tester.pump(const Duration(milliseconds: 250));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
    }

    final display = displayRectLogical();
    final before = await windowManager.getBounds();
    evidence('display-logical $display');
    evidence('bounds-before-ltrb ${before.left},${before.top},'
        '${before.width},${before.height}');
    expect(
      display.width > 0 && display.height > 0,
      isTrue,
      reason: 'dart:ui 的 displays 为空，无法判定「铺满」——本用例不能靠猜通过',
    );
    // 前置条件：起始窗口必须明显小于显示器，否则「本来就那么大」会让
    // 下面的铺满断言失去区分力。
    expect(
      before.width < display.width - 1 || before.height < display.height - 1,
      isTrue,
      reason: '窗口起始尺寸已等于显示器尺寸，本用例无法证明「铺满」——请先把窗口调小',
    );

    await revealPlayerControls(tester);
    await tester.tap(find.byTooltip('全屏（F11）'));
    await tester.pump();

    expect(
      await waitFor(tester, () => windowManager.isFullScreen()),
      isTrue,
      reason: '点全屏按钮后 windowManager 应报告已进入全屏',
    );

    final bounds = await windowManager.getBounds();
    evidence('bounds-fullscreen-ltrb ${bounds.left},${bounds.top},'
        '${bounds.width},${bounds.height}');

    // 铺满显示器：原点贴合显示器左上角，宽高等于显示器（逻辑）尺寸。
    expect(
      bounds.left,
      closeTo(display.left, 2),
      reason: '全屏窗口左上角 X 应贴合显示器左边缘（rcMonitor.left）',
    );
    expect(
      bounds.top,
      closeTo(display.top, 2),
      reason: '全屏窗口左上角 Y 应贴合显示器上边缘（rcMonitor.top）',
    );
    expect(
      bounds.width,
      closeTo(display.width, 2),
      reason:
          '全屏窗口宽度应等于显示器宽度。偏小说明 window_manager.cpp:593 的 '
          '`if (!is_frameless_)` 铺满分支被跳过——检查进入全屏前是否调了 '
          'setAsFrameless()',
    );
    expect(
      bounds.height,
      closeTo(display.height, 2),
      reason: '全屏窗口高度应等于显示器高度（同上看铺满分支是否执行）',
    );

    // 退出全屏应回到进入前的矩形。
    await revealPlayerControls(tester);
    await tester.tap(find.byTooltip('全屏（F11）'));
    await tester.pump();
    expect(
      await waitFor(tester, () async => !await windowManager.isFullScreen()),
      isTrue,
      reason: '再点一次应退出全屏',
    );

    final restored = await windowManager.getBounds();
    evidence('bounds-restored-ltrb ${restored.left},${restored.top},'
        '${restored.width},${restored.height}');
    expect(
      restored.width,
      closeTo(before.width, 8),
      reason: '退出全屏后窗口宽度应恢复进入前的尺寸（window_manager.cpp:636-641）',
    );
    expect(
      restored.height,
      closeTo(before.height, 8),
      reason: '退出全屏后窗口高度应恢复进入前的尺寸',
    );
    expect(tester.takeException(), isNull);
    evidence('window-fullscreen PASS');
  });
}
