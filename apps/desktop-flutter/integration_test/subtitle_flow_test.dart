/// 外挂字幕端到端集成测试（设计文档 §10.3「外挂字幕」「字幕轨选择」）。
///
/// 真实桌面应用测试：真正的 widget 树、真正的 HTTP 客户端、真正的 media-kit
/// 播放器（挂载 `Video` 控件）、以及真正受 Header 门禁保护的字幕 fixture。
///
/// 覆盖验收点：
/// - 播放结果里的 `subs` 能在播放器里被装配并默认启用（`flag` 默认位）；
/// - 字幕**关**得掉、也重新**开**得回来（§13.3「字幕可开启和关闭」）；
/// - 字幕请求带上与媒体一致的 Header（缺 Header 的 `/media/` 会 403）；
/// - 字幕失败不影响视频播放：坏字幕地址下视频照常出画（§10.4）。
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
    final temp = await Directory.systemTemp.createTemp('webhtv-subtitle-e2e');
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
        'name': 'subtitle-e2e',
        'sites': [
          {
            'key': 'fixture-type1',
            'name': 'Fixture',
            'type': 1,
            'api': '$fixtureBaseUrl/api/type1/',
          },
        ],
      }),
      displayName: 'subtitle-e2e',
    );
    expect(imported, isTrue, reason: state.lastError?.logLine);
    return state;
  }

  /// 播放请求：媒体与字幕都指向受 Header 门禁保护的 `/media/`。
  PlaybackRequest requestWith({
    required List<SubtitleInfo> subtitles,
  }) => PlaybackRequest(
    url: fixtureMp4Url,
    headers: fixtureMediaHeaders,
    title: '字幕测试',
    siteKey: 'fixture-type1',
    vodId: 'vod-1',
    vodName: '字幕测试片',
    episodeName: '第 1 集',
    flag: '线路1',
    subtitles: subtitles,
    subtitleHeaders: fixtureMediaHeaders,
  );

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

  testWidgets('外挂字幕默认启用 → 关闭 → 重新开启（§10.3、§13.3）', (tester) async {
    final state = await bootstrapState();
    final request = requestWith(
      subtitles: [
        SubtitleInfo(
          url: '$fixtureBaseUrl/media/sample.srt',
          name: '简体中文',
          lang: 'zh',
          format: 'srt',
          // flag=1（默认位）：播放器应自动启用。
          flag: SubtitleInfo.selectionFlagDefault,
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: PlayerPage(state: state, request: request))),
    );
    final player = await pumpUntilFirstFrame(tester);

    // 1) 默认启用：mpv 里出现外挂字幕轨（`uri` 形态即宿主注入的外挂字幕）。
    var externalTrack = player.state.track.subtitle;
    for (var attempt = 0; attempt < 20 && !externalTrack.uri; attempt++) {
      await tester.pump(const Duration(milliseconds: 250));
      externalTrack = player.state.track.subtitle;
    }
    expect(externalTrack.uri, isTrue, reason: '默认 flag 的外挂字幕应被自动启用');
    expect(
      player.state.tracks.subtitle.any(
        (track) => (track.title ?? '').contains('简体中文'),
      ),
      isTrue,
      reason: '外挂字幕应出现在轨道表里（证明字幕文件真的被 mpv 加载）',
    );
    evidence(
      'subtitle-default-on uri=${externalTrack.uri} '
      'title=${externalTrack.title} lines=${request.subtitles.length}',
    );

    // 2) 关闭：字幕菜单 →「关闭字幕」。
    await tester.tap(find.byTooltip('字幕'));
    await tester.pumpAndSettle();
    expect(find.text('关闭字幕'), findsOneWidget);
    await tester.tap(find.text('关闭字幕'));
    await tester.pumpAndSettle(const Duration(seconds: 2));
    expect(player.state.track.subtitle.id, 'no');
    evidence('subtitle-off id=${player.state.track.subtitle.id}');

    // 3) 重新开启：同一菜单选回外挂字幕。
    await tester.tap(find.byTooltip('字幕'));
    await tester.pumpAndSettle();
    final externalLabel = find.textContaining('简体中文');
    expect(externalLabel, findsWidgets);
    await tester.tap(externalLabel.first);
    // 重新选择要走一次「带 Header 拉取字幕 → 落盘 → sub-add」，
    // pumpAndSettle 只保证帧稳定，不等待网络，所以这里显式轮询轨道状态。
    var reselected = player.state.track.subtitle;
    for (var attempt = 0; attempt < 40 && !reselected.uri; attempt++) {
      await tester.pump(const Duration(milliseconds: 250));
      reselected = player.state.track.subtitle;
    }
    expect(reselected.uri, isTrue);
    evidence('subtitle-reselected uri=${reselected.uri}');

    // 4) 视频仍在播：字幕操作不得影响播放。
    expect(player.state.position > Duration.zero, isTrue);
  });

  testWidgets('字幕加载失败不影响视频播放（§10.4）', (tester) async {
    final state = await bootstrapState();
    final request = requestWith(
      subtitles: [
        SubtitleInfo(
          url: '$fixtureBaseUrl/media/nope.srt',
          name: '坏字幕',
          lang: 'zh',
          format: 'srt',
          flag: SubtitleInfo.selectionFlagDefault,
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: PlayerPage(state: state, request: request))),
    );
    final player = await pumpUntilFirstFrame(tester);

    // 视频照常出画。
    expect(find.textContaining('播放失败').evaluate(), isEmpty);
    // 字幕错误只提示，不阻断。
    for (var attempt = 0; attempt < 20; attempt++) {
      await tester.pump(const Duration(milliseconds: 250));
      if (find.textContaining('字幕加载失败').evaluate().isNotEmpty) break;
    }
    expect(find.textContaining('字幕加载失败'), findsWidgets);
    expect(player.state.position > Duration.zero, isTrue);
    evidence(
      'subtitle-failure isolated=true playing=${player.state.position > Duration.zero}',
    );
  });
}
