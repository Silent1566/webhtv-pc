/// 播放器页的测试脚手架。
///
/// 为什么单独一个文件：本轮有 3 个套件要 pump `PlayerPage`，
/// 而它需要 `AppState`（真实临时目录）+ `PlaybackRequest`。
/// 复制三份会让「窗口尺寸」「初始开关」这类参数漂移。
///
/// **为什么必须 mock `media_kit_video` 的 MethodChannel**：
/// `PlayerPage.initState`（`player_page.dart:339`）构造 `PlayerController`，
/// 其构造（`player_controller.dart:117-122`）构造 `VideoController`，
/// 后者在 `NativeVideoController.create`
/// （`media_kit_video/lib/src/video_controller/native_video_controller/real.dart:177`）
/// 上调用 `MethodChannel('com.alexmercerind/media_kit_video')` 的
/// `VideoOutputManager.Create`。`flutter test` 里没有这个平台实现，
/// 于是抛 `MissingPluginException`。
///
/// 本仓库在 `test/phase7_player_advance_test.dart:3-8` 记录过同一件事，
/// 并因此把 phase7 整份套件改成**源码级断言**、从不 pump `PlayerPage`。
/// 本轮不走那条路：我们把该通道 mock 成成功返回，于是页面能真实构建，
/// 浮层/屏显/菜单都能被真实交互驱动（探针实测：`PlayerPage=1 AppBar=1 exc=null`）。
///
/// **绝不用 `pumpAndSettle`**：加载态渲染 `LoadingBlock`（内含常驻
/// `CircularProgressIndicator`），且 `PlayerController.open` 起了 180 秒加载超时定时器
/// （`player_controller.dart:830`），`transientCallbackCount` 恒 ≥1
/// （探针实测一路推进到 25 秒仍为 1），`pumpAndSettle` 必然超时。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/player_page.dart';
import 'package:webhtv_pc/ui/theme.dart';

/// `media_kit_video` 的平台通道（见文件头注释）。
const MethodChannel mediaKitVideoChannel = MethodChannel(
  'com.alexmercerind/media_kit_video',
);

/// `window_manager` 的平台通道（`window_manager-0.5.2/lib/src/window_manager.dart:43`）。
const MethodChannel windowManagerChannel = MethodChannel('window_manager');

/// `window_manager` 收到的平台调用流水，按发生顺序记录。
///
/// 为什么需要：Esc 用例的标题是「只关菜单，**不退出全屏**」。
/// 若只断言「菜单关了」，一个**同时**退出全屏的实现也能通过——
/// 那正是这条用例声称要排除的情况。装上 mock 之后才能反向断言
/// 「整场没有发生过 `setFullScreen`」。
final List<MethodCall> windowManagerCalls = <MethodCall>[];

/// 把 `window_manager` 的平台调用 mock 成成功返回，并记录流水。
///
/// 必须在 `pumpWidget` **之前**调用。默认 `isFullScreen` 返回 `false`
/// （即「当前不是全屏」），于是 `_exitFullscreen()` 会走
/// `if (await windowManager.isFullScreen())` 的假分支、什么都不做——
/// 这正是我们要能观测到的差别。
void installWindowManagerMocks(WidgetTester tester) {
  windowManagerCalls.clear();
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    windowManagerChannel,
    (call) async {
      windowManagerCalls.add(call);
      return switch (call.method) {
        'isFullScreen' => false,
        'isFocused' => true,
        'isPreventClose' => false,
        _ => null,
      };
    },
  );
}

/// 把 `media_kit_video` 的平台调用全部变成成功返回。
///
/// 必须在 `pumpWidget` **之前**调用。`MediaKit.ensureInitialized()` 也要先调，
/// 否则 `Player()` 构造会抛「must be called before using any API」。
void installMediaKitMocks(WidgetTester tester) {
  MediaKit.ensureInitialized();
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    mediaKitVideoChannel,
    (call) async => null,
  );
}

/// 推进假时间若干次，**替代 `pumpAndSettle`**。
///
/// 默认 8×250ms：足够让 `postFrameCallback` 里的 `_touchControls()` 与
/// `_load()` 跑起来、让 3 秒自动隐藏定时器到期（需要时传更大的 `times`），
/// 又不会触发 180 秒加载超时。
Future<void> settlePlayerPage(
  WidgetTester tester, {
  Duration step = const Duration(milliseconds: 250),
  int times = 8,
}) async {
  for (var i = 0; i < times; i++) {
    await tester.pump(step);
  }
}

/// 屏显刷新循环当前是否在运行（`design/02` §4.3）。
///
/// 走 `PlayerPage` 的 `@visibleForTesting` 观测缝，因为该需求在 widget 树上
/// 没有可观测的表象（屏显层此时完全隐藏，没有文本或像素可断言）。
bool osdTickerRunning(WidgetTester tester) => debugOsdTickerRunning(
  tester.state<State<PlayerPage>>(find.byType(PlayerPage)),
);

/// pump 一个播放器页。
///
/// **不加载真实媒体**：`url` 指向不可达地址，`PlayerController` 会进入加载态，
/// 但控制浮层、屏显层、菜单层的结构都已经在树里——本轮的断言对象是它们，
/// 不是解码结果。真实出画的几何不变式由 L3 集成测试（Task 12）覆盖。
Future<void> pumpPlayerPage(
  WidgetTester tester, {
  Map<String, bool>? osdFlags,
  Set<String>? hiddenButtons,
  List<String>? buttonOrder,
  Size size = const Size(1280, 720),
}) async {
  final temp = Directory.systemTemp.createTempSync('webhtv-phase8-page');
  addTearDown(() {
    try {
      temp.deleteSync(recursive: true);
    } catch (_) {}
  });
  final paths = AppPaths.resolve(
    overrides: {
      'config': '${temp.path}/webhtv-pc',
      'data': '${temp.path}/webhtv-pc',
      'cache': '${temp.path}/webhtv-pc/cache',
      'state': '${temp.path}/webhtv-pc/logs',
    },
  );
  final state = AppState(paths: paths, log: LogService());
  addTearDown(state.dispose);

  // 全部配置写入必须包在 `runAsync` 里：`bootstrap()` 与各 `set*` 都会经
  // `_persistQueue` 串行落盘，而那个 Future 是在**真实 zone** 里创建的；
  // 直接在 `testWidgets` 的 FakeAsync zone 里 await 它会永久挂起
  // （本 brief 头部 Trap A；探针实测包进 runAsync 后正常）。
  await tester.runAsync(() async {
    await state.bootstrap();
    if (osdFlags != null) {
      for (final entry in osdFlags.entries) {
        await state.setOsdFlag(entry.key, entry.value);
      }
    }
    if (hiddenButtons != null) {
      await state.setPlayerButtonHidden(hiddenButtons);
    }
    if (buttonOrder != null) {
      await state.setPlayerButtonOrder(buttonOrder);
    }
  });

  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  installMediaKitMocks(tester);
  installWindowManagerMocks(tester);

  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(Brightness.dark),
      home: Scaffold(
        body: PlayerPage(
          state: state,
          request: const PlaybackRequest(
            url: 'http://127.0.0.1:9/never.m3u8',
            title: '示例剧集',
            siteKey: 'fixture',
            vodId: 'demo-1',
            vodName: '示例剧集',
            episodeName: 'E3',
            flag: '线路一',
          ),
        ),
      ),
    ),
  );
  // 让 initState 的 postFrameCallback 跑起来，但不等真实网络。
  // 用显式 pump 而不是 pumpAndSettle（见文件头注释：永不 settle）。
  await settlePlayerPage(tester);
}
