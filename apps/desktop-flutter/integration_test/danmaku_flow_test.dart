/// 弹幕端到端集成测试（设计文档 §21 Phase 3「字幕/弹幕可开启和关闭」）。
///
/// 真实桌面应用测试：真正的 widget 树、真正的 HTTP 客户端、真正的 media-kit
/// 播放器（挂载 `Video` 控件）、以及真正受 Header 门禁保护的弹幕 fixture。
///
/// 覆盖验收点：
/// - 播放结果里的 `danmaku` 能在播放器里被拉取并渲染（真实 CustomPaint 出画）；
/// - 弹幕**关**得掉、也重新**开**得回来（这正是「弹幕可开启和关闭」验收原文）；
/// - 弹幕请求带上与媒体一致的 Header（缺 Header 的 `/danmaku/` 会 403）；
/// - 弹幕失败不影响视频播放：坏弹幕地址下视频照常出画（§10.4 同语义）。
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

void evidence(String message) => debugPrint('PHASE3-EVIDENCE $message');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  setUpAll(() async {
    await windowManager.ensureInitialized();
  });

  Future<AppState> bootstrapState() async {
    final temp = await Directory.systemTemp.createTemp('webhtv-danmaku-e2e');
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
        'name': 'danmaku-e2e',
        'sites': [
          {
            'key': 'fixture-type1',
            'name': 'Fixture',
            'type': 1,
            'api': '$fixtureBaseUrl/api/type1/',
          },
        ],
      }),
      displayName: 'danmaku-e2e',
    );
    expect(imported, isTrue, reason: state.lastError?.logLine);
    return state;
  }

  PlaybackRequest requestWith({required List<DanmakuSource> danmaku}) =>
      PlaybackRequest(
        url: fixtureMp4Url,
        headers: fixtureMediaHeaders,
        title: '弹幕测试',
        siteKey: 'fixture-type1',
        vodId: 'vod-1',
        vodName: '弹幕测试片',
        episodeName: '第 1 集',
        flag: '线路1',
        danmaku: danmaku,
        subtitleHeaders: fixtureMediaHeaders,
      );

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

  /// 等到弹幕层真的画出内容（CustomPaint 存在且可见项非空）。
  Future<bool> waitForDanmakuRendered(WidgetTester tester) async {
    for (var attempt = 0; attempt < 40; attempt++) {
      await tester.pump(const Duration(milliseconds: 250));
      if (find.byType(DanmakuOverlay).evaluate().isEmpty) continue;
      final overlay = tester.widget<DanmakuOverlay>(
        find.byType(DanmakuOverlay).first,
      );
      if (overlay.items.isEmpty) continue;
      // 真实渲染判据：本层产生了 CustomPaint 子节点（即确实在绘制）。
      final painted = find
          .descendant(
            of: find.byType(DanmakuOverlay),
            matching: find.byType(CustomPaint),
          )
          .evaluate()
          .isNotEmpty;
      if (painted && overlay.style.enabled) return true;
    }
    return false;
  }

  testWidgets('弹幕加载 → 渲染 → 关闭 → 重新开启（§21 Phase 3）', (tester) async {
    final state = await bootstrapState();
    final request = requestWith(
      danmaku: [
        DanmakuSource(
          url: '$fixtureBaseUrl/danmaku/sample.xml',
          name: '样例弹幕',
          source: 'sample',
          selected: true,
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: PlayerPage(state: state, request: request))),
    );
    await pumpUntilFirstFrame(tester);

    // 1) 弹幕被拉取并渲染。
    final rendered = await waitForDanmakuRendered(tester);
    expect(rendered, isTrue, reason: '弹幕应被加载并在叠加层上真实绘制');
    final overlay = tester.widget<DanmakuOverlay>(
      find.byType(DanmakuOverlay).first,
    );
    expect(overlay.items, isNotEmpty);
    expect(overlay.style.enabled, isTrue);
    evidence(
      'danmaku-rendered items=${overlay.items.length} '
      'selected=${overlay.style.enabled}',
    );

    // 2) 关闭：AppBar 弹幕按钮。
    await tester.tap(find.byTooltip('弹幕（开启）'));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    final paused = tester.widget<DanmakuOverlay>(
      find.byType(DanmakuOverlay).first,
    );
    expect(paused.style.enabled, isFalse);
    // 关闭后本层不绘制任何内容。
    expect(
      find
          .descendant(
            of: find.byType(DanmakuOverlay),
            matching: find.byType(CustomPaint),
          )
          .evaluate(),
      isEmpty,
    );
    evidence('danmaku-off enabled=${paused.style.enabled} painted=false');

    // 3) 重新开启。
    await tester.tap(find.byTooltip('弹幕（关闭）'));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    final resumed = tester.widget<DanmakuOverlay>(
      find.byType(DanmakuOverlay).first,
    );
    expect(resumed.style.enabled, isTrue);
    evidence('danmaku-resumed enabled=${resumed.style.enabled}');

    // 4) 视频仍在播：弹幕操作不得影响播放。
    final player =
        tester.widget<Video>(find.byType(Video).first).controller.player;
    expect(player.state.position > Duration.zero, isTrue);
    evidence('danmaku-playback-kept playing=true');
  });

  testWidgets('弹幕加载失败不影响视频播放（§10.4 同语义）', (tester) async {
    final state = await bootstrapState();
    final request = requestWith(
      danmaku: [
        DanmakuSource(
          url: '$fixtureBaseUrl/danmaku/nope.xml',
          name: '坏弹幕',
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
    // 弹幕错误只提示，不阻断。
    for (var attempt = 0; attempt < 20; attempt++) {
      await tester.pump(const Duration(milliseconds: 250));
      if (find.textContaining('弹幕加载失败').evaluate().isNotEmpty) break;
    }
    expect(find.textContaining('弹幕加载失败'), findsWidgets);
    final overlay = tester.widget<DanmakuOverlay>(
      find.byType(DanmakuOverlay).first,
    );
    expect(overlay.items, isEmpty);
    expect(player.state.position > Duration.zero, isTrue);
    evidence(
      'danmaku-failure isolated=true items=${overlay.items.length} playing=true',
    );
  });
}
