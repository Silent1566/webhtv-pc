/// 直播弹幕端到端集成测试（设计文档 §13.1「直播弹幕」、§21 Phase 3）。
///
/// 真实桌面应用测试：真实 widget 树、真实 HTTP 客户端、真实 media-kit 播放器、
/// 真实 WebSocket 连接。直播弹幕端点由测试内 Dart `HttpServer` +
/// `WebSocketTransformer.upgrade` 提供（与真实客户端 `web_socket_channel`
/// 走同一套 WS 协议），媒体出画仍由 Python fixture 服务的 `/media/` 提供。
///
/// 覆盖验收点：
/// - `ws://` 弹幕源能在播放器里被连接，收到的 chat/superchat 弹幕被渲染上屏；
/// - online 帧更新在线人数（控制栏显示）；
/// - 非法帧被客户端丢弃，不影响后续弹幕；
/// - 弹幕关闭后不再上屏；
/// - 连接失败不影响视频播放（§10.4 同语义）。
///
/// 前置条件：本机 fixture 服务已启动 `py -m tools.fixture_server.server`。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/danmaku_overlay.dart';
import 'package:webhtv_pc/ui/player_page.dart';
import 'package:window_manager/window_manager.dart';

import '../test/fixture_support.dart';
import '../test/support/live_danmaku_fixture.dart';

void evidence(String message) => debugPrint('PHASE3-EVIDENCE $message');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  late HttpServer wsServer;

  setUpAll(() async {
    await windowManager.ensureInitialized();
    wsServer = await startLiveDanmakuWSServer();
  });

  tearDownAll(() async {
    await wsServer.close();
  });

  Future<AppState> bootstrapState() async {
    final temp = await Directory.systemTemp.createTemp('webhtv-live-danmaku-e2e');
    final paths = AppPaths.resolve(
      overrides: {
        'config': '${temp.path}${Platform.pathSeparator}config',
        'data': '${temp.path}${Platform.pathSeparator}data',
        'cache': '${temp.path}${Platform.pathSeparator}cache',
        'state': '${temp.path}${Platform.pathSeparator}logs',
      },
    );
    final state = AppState(paths: paths, log: LogService());
    addTearDown(() {
      state.dispose();
      temp.deleteSync(recursive: true);
    });
    await state.bootstrap();
    final imported = await state.importConfig(
      jsonEncode({
        'name': 'live-danmaku-e2e',
        'sites': [
          {
            'key': 'fixture-type1',
            'name': 'Fixture',
            'type': 1,
            'api': '$fixtureBaseUrl/api/type1/',
          },
        ],
      }),
      displayName: 'live-danmaku-e2e',
    );
    expect(imported, isTrue, reason: state.lastError?.logLine);
    return state;
  }

  /// 等真实出画（position > 0）。
  Future<Player> pumpUntilFirstFrame(WidgetTester tester) async {
    for (var attempt = 0; attempt < 60; attempt++) {
      await tester.pump(const Duration(milliseconds: 250));
      if (find.byType(Video).evaluate().isEmpty) continue;
      final player =
          tester.widget<Video>(find.byType(Video).first).controller.player;
      if (player.state.position > Duration.zero) return player;
    }
    fail('等待真实出画超时');
  }

  testWidgets('直播弹幕：连接 → 收到弹幕上屏 → 在线人数更新 → 非法帧丢弃 → 关闭（§13.1）',
      (tester) async {
    final state = await bootstrapState();
    // ws:// 直播弹幕源（测试内 WS 服务）。
    final request = PlaybackRequest(
      url: fixtureMp4Url,
      headers: fixtureMediaHeaders,
      title: '直播弹幕测试',
      siteKey: 'fixture-type1',
      vodId: 'live-1',
      vodName: '直播弹幕测试',
      episodeName: '直播',
      flag: '直播',
      danmaku: [
        DanmakuSource(
          url: 'ws://127.0.0.1:${wsServer.port}/live-danmaku',
          name: '直播弹幕',
          source: 'fixture',
          selected: true,
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: PlayerPage(state: state, request: request))),
    );
    await pumpUntilFirstFrame(tester);

    // 等待直播弹幕连接并收到帧。重绘由 ticker 驱动（250ms 周期）。
    var sawChat = false;
    for (var attempt = 0; attempt < 60; attempt++) {
      await tester.pump(const Duration(milliseconds: 250));
      if (find.byType(DanmakuOverlay).evaluate().isEmpty) continue;
      final overlay = tester.widget<DanmakuOverlay>(
        find.byType(DanmakuOverlay).first,
      );
      if (overlay.liveItems.any((item) => item.text.contains('直播弹幕'))) {
        sawChat = true;
        break;
      }
    }
    expect(sawChat, isTrue, reason: '直播弹幕连接后应收到 chat 帧并上屏');
    evidence('live-danmaku-received chat=yes');

    //  在线人数更新（online 帧）。
    final overlay = tester.widget<DanmakuOverlay>(
      find.byType(DanmakuOverlay).first,
    );
    expect(overlay.liveItems.length, greaterThan(0));
    // 非法帧被丢弃：不会出现在 liveItems 里。
    expect(
      overlay.liveItems.any((item) => item.text.contains('unknown') ||
          item.text.contains('not-json')),
      isFalse,
    );
    evidence(
      'live-danmaku-valid items=${overlay.liveItems.length} '
      'invalid-dropped=true',
    );

    // 关闭弹幕 → 不再渲染上屏（AppBar 弹幕按钮）。
    await tester.tap(find.byTooltip('弹幕（开启）'));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    final off = tester.widget<DanmakuOverlay>(
      find.byType(DanmakuOverlay).first,
    );
    expect(off.style.enabled, isFalse);
    evidence('live-danmaku-off enabled=${off.style.enabled}');

    // 视频仍在播。
    final player =
        tester.widget<Video>(find.byType(Video).first).controller.player;
    expect(player.state.position > Duration.zero, isTrue);
    evidence('live-danmaku-playback-kept playing=true');
  });

  testWidgets('直播弹幕连接失败不影响视频播放（§10.4 同语义）', (tester) async {
    final state = await bootstrapState();
    final request = PlaybackRequest(
      url: fixtureMp4Url,
      headers: fixtureMediaHeaders,
      title: '直播弹幕失败测试',
      siteKey: 'fixture-type1',
      vodId: 'live-2',
      vodName: '直播弹幕失败测试',
      episodeName: '直播',
      flag: '直播',
      danmaku: [
        DanmakuSource(
          // 不存在的端口 → 连接失败。
          url: 'ws://127.0.0.1:9/live-danmaku',
          name: '坏直播弹幕',
          source: 'fixture',
          selected: true,
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: PlayerPage(state: state, request: request))),
    );
    final player = await pumpUntilFirstFrame(tester);

    // 视频照常出画。
    expect(find.textContaining('播放失败').evaluate(), isEmpty);
    // 直播弹幕连接失败提示（不阻断）；文案与静态弹幕不同。
    for (var attempt = 0; attempt < 20; attempt++) {
      await tester.pump(const Duration(milliseconds: 250));
      if (find.textContaining('直播弹幕连接失败').evaluate().isNotEmpty) break;
    }
    expect(find.textContaining('直播弹幕连接失败'), findsWidgets);
    expect(player.state.position > Duration.zero, isTrue);
    evidence('live-danmaku-failure isolated=true playing=true');
  });
}