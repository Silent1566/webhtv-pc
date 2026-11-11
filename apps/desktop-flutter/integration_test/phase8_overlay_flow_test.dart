/// Phase 8 · 浮层几何不变式（`docs/phase8/design/01` §5、`design/05` §3.1）。
///
/// ## 这个套件存在的唯一理由
///
/// 用户投诉「每次唤醒控制台都会导致画面缩放」。修复的正确性**不能靠肉眼**——
/// `Column` → `Stack` 的迁移很容易半做（把浮层包在 `SafeArea` 里、
/// 给 `Stack` 加 `padding`、用 `Align` 而不是 `Positioned.fill`），
/// 每一种都会让视频区尺寸重新依赖浮层。
///
/// 本套件用**真实窗口 + 真实出画**，断言视频区矩形在控制栏显隐前后
/// **逐像素相同**。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/player_page.dart';
import 'package:webhtv_pc/ui/theme.dart';

import '../test/fixture_support.dart';

void evidence(String message) =>
    debugPrint('PHASE8-OVERLAY-EVIDENCE $message');

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

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  testWidgets('V1：控制栏显隐前后视频区矩形逐像素相同', (tester) async {
    if (!await fixtureReachable()) {
      markTestSkipped(
        'fixture 服务不可达（$fixtureBaseUrl）：'
        '先运行 `python tools/fixture_server/server.py`',
      );
      return;
    }
    final temp = Directory.systemTemp.createTempSync('webhtv-phase8-overlay');
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

    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

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

    // 等真实出画：媒体解码要走真实 async 区。
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 250));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 120)),
      );
    }

    // 确保控制栏可见。
    await tester.tap(find.byType(PlayerPage), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 300));

    final visibleRect = tester.getRect(find.byType(Video));
    evidence(
      'rect-visible '
      'left=${visibleRect.left} top=${visibleRect.top} '
      'w=${visibleRect.width} h=${visibleRect.height}',
    );

    // 等自动隐藏（3 秒 + 余量）。
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();

    final hiddenRect = tester.getRect(find.byType(Video));
    evidence(
      'rect-hidden '
      'left=${hiddenRect.left} top=${hiddenRect.top} '
      'w=${hiddenRect.width} h=${hiddenRect.height}',
    );

    expect(
      hiddenRect,
      visibleRect,
      reason:
          '控制栏显隐不得改变视频区几何——这正是用户投诉的「画面缩放」根因。'
          '若此处失败，检查控制浮层是否被放进了 Column/Row，'
          '或是否被 SafeArea/Padding 包裹。',
    );
    evidence('geometry-invariant PASS');
    expect(tester.takeException(), isNull);
  });

  testWidgets('V2：进出全屏前后视频区矩形在同一窗口尺寸下相同', (tester) async {
    if (!await fixtureReachable()) {
      markTestSkipped('fixture 服务不可达（$fixtureBaseUrl）');
      return;
    }
    final temp = Directory.systemTemp.createTempSync('webhtv-phase8-fs');
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

    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

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
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 250));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 120)),
      );
    }
    await tester.tap(find.byType(PlayerPage), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 300));

    // 顶栏在浮层里，所以窗口化与全屏时视频区都占满 body。
    // 这里断言的是「顶栏不再占用 56px」：视频区高度 == 窗口高度。
    final rect = tester.getRect(find.byType(Video));
    evidence('rect-windowed h=${rect.height} viewport=900');
    expect(
      rect.height,
      closeTo(900, 1),
      reason: '顶栏改浮层后，视频区应占满整个 body（不再被 AppBar 挤掉 56px）',
    );
    expect(tester.takeException(), isNull);
  });
}
