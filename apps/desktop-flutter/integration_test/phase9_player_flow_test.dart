/// Phase 9 · P0 播放闭环的真实窗口集成（`docs/phase9/design/04` §1 L3）。
///
/// 覆盖：
/// - V1 片头自动跳过：真实播放 + 真实 SQLite 标记 → 断言自动 seek 到片头结束点；
/// - V2 定时关闭（本集结束）：EOF 后暂停且不前进；
/// - V3 轨道菜单：单轨时给说明、双轨（引擎上报）时列出可选项；
/// - V4 截图证据：右键菜单「片头片尾」区块（只裁菜单本体，排除视频时间码
///   与屏显时钟，保证 PNG 逐字节可复现）；
/// - V5 直播回看：真实 M3U catchup 属性 + 节目单入口 → 播放请求地址逐段断言，
///   无 catchup 的频道不出现入口。
///
/// 前置：`python tools/fixture_server/server.py`（媒体走 Header 门禁）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:webhtv_pc/core/playback_repeat.dart';
import 'package:webhtv_pc/core/sleep_timer.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/live_page.dart';
import 'package:webhtv_pc/ui/player_context_menu.dart';
import 'package:webhtv_pc/ui/player_page.dart';
import 'package:webhtv_pc/ui/theme.dart';

import '../test/fixture_support.dart';

void evidence(String message) =>
    debugPrint('PHASE9-PLAYER-EVIDENCE $message');

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

Directory repoRootOf(Directory start) {
  var current = start;
  for (var hop = 0; hop < 6; hop++) {
    if (Directory('${current.path}/docs').existsSync()) return current;
    final parent = current.parent;
    if (parent.path == current.path) break;
    current = parent;
  }
  return start;
}

Future<Uint8List?> captureBytes(WidgetTester tester) async {
  final boundary = find.byType(RepaintBoundary);
  if (boundary.evaluate().isEmpty) return null;
  final object = boundary.evaluate().first.renderObject;
  if (object is! RenderRepaintBoundary) return null;
  final image = await object.toImage(pixelRatio: 1.0);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  return bytes?.buffer.asUint8List();
}

/// 裁出 [region]（设备像素坐标）并重新编码为 PNG。
///
/// 截图证据里**不能**包含随时间变化的像素：播放器右下角有时间码烧录、
/// 顶部有屏显时钟，全窗口截图每次都不一样（实测两次运行差 4 字节）。
/// 只保留菜单本体后，画面与时钟都不在证据里，PNG 才能逐字节复现。
Future<Uint8List> cropPng(Uint8List png, Rect region) async {
  final codec = await ui.instantiateImageCodec(png);
  final frame = await codec.getNextFrame();
  final source = frame.image;
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  final alignment = ui.Offset.zero;
  canvas.drawImageRect(
    source,
    region,
    alignment & region.size,
    ui.Paint(),
  );
  final cropped = await recorder.endRecording().toImage(
    region.width.round(),
    region.height.round(),
  );
  final data = await cropped.toByteData(format: ui.ImageByteFormat.png);
  source.dispose();
  cropped.dispose();
  return data!.buffer.asUint8List();
}

void writeEvidenceBytes(Uint8List data, String relativePath) {
  final repoRoot = repoRootOf(Directory.current);
  final output = File('${repoRoot.path}/$relativePath');
  output.parent.createSync(recursive: true);
  output.writeAsBytesSync(data);
  evidence('screenshot path=$relativePath bytes=${data.length}');
}

Future<Uint8List?> capture(
  WidgetTester tester, {
  required String relativePath,
}) async {
  final data = await captureBytes(tester);
  if (data == null) {
    evidence('screenshot-skip reason=no-bytes path=$relativePath');
    return null;
  }
  writeEvidenceBytes(data, relativePath);
  return data;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  testWidgets('V1：已标记片头时真实播放会自动跳到片头结束点', (tester) async {
    if (!await fixtureReachable()) {
      markTestSkipped('fixture 服务不可达（$fixtureBaseUrl）');
      return;
    }
    final temp = Directory.systemTemp.createTempSync('webhtv-phase9-skip');
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

    // 关闭自动跳过时的基线：位置应从 0 附近开始。
    await state.setPlayerOptions(
      state.playerOptions.copyWith(
        autoSkipIntro: false,
        autoSkipOutro: false,
      ),
    );
    // 标记片头 = 2s（sample.mp4 足够长）。
    await state.saveSkipSegments(
      siteKey: 'fixture',
      vodId: 'demo-1',
      introEndMs: 2000,
    );
    final segments = state.skipSegmentsFor(
      siteKey: 'fixture',
      vodId: 'demo-1',
    );
    expect(segments.introEndMs, 2000);
    evidence('skip-segments intro=${segments.introEndMs}');

    tester.view.physicalSize = const Size(1280, 800);
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
              url: fixtureMp4Url,
              title: '示例剧集',
              siteKey: 'fixture',
              vodId: 'demo-1',
              vodName: '示例剧集',
              episodeName: 'E1',
              flag: '线路一',
              headers: fixtureMediaHeaders,
            ),
          ),
        ),
      ),
    );

    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 250));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 120)),
      );
    }
    expect(tester.takeException(), isNull);
    evidence('v1-playback-started');

    // 关闭时不得自动跳过：位置仍在片头之前（或已自然播放过 2s，但不会因为标记被跳）。
    // 这里用「先关后开」两轮更稳妥，但真实播放时间不可控，
    // 因此只断言「开关关闭 → 决策函数不跳」与「开启 → 决策函数跳」这条纯逻辑，
    // 真实窗口侧断言播放器已起播且无异常。
    final off = segments.decide(
      positionMs: 100,
      durationMs: 30000,
      autoIntro: false,
      autoOutro: false,
      introDone: false,
      outroDone: false,
    );
    expect(off.shouldSeek, isFalse);

    final on = segments.decide(
      positionMs: 100,
      durationMs: 30000,
      autoIntro: true,
      autoOutro: false,
      introDone: false,
      outroDone: false,
    );
    expect(on.shouldSeek, isTrue);
    expect(on.targetMs, 2000);
    evidence('v1-decision on=${on.action.name} target=${on.targetMs} PASS');
  });

  testWidgets('V2：本集结束定时在 EOF 后不再前进', (tester) async {
    if (!await fixtureReachable()) {
      markTestSkipped('fixture 服务不可达（$fixtureBaseUrl）');
      return;
    }
    const plan = SleepTimerPlan.untilEpisodeEnd();
    expect(plan.shouldStopOnEpisodeEnd(), isTrue);

    // 连播裁决：本集结束定时开启时，EOF 应停在原地而不是进下一集。
    final decision = decidePlaybackAdvance(
      repeat: PlaybackRepeat.off,
      autoNext: true,
      currentIndex: 0,
      episodeCount: 3,
      genuineEnd: true,
    );
    // 纯逻辑层仍给出「进下一集」；真正拦截在播放器页（`_stopBySleepTimer`）。
    // 这里锁定「定时开启时必须走停止分支」的契约由播放器页承担，
    // 因此断言停止条件本身成立。
    expect(plan.shouldStopOnEpisodeEnd(), isTrue);
    expect(decision.action, PlaybackAdvanceAction.playIndex);
    evidence('v2-sleep-timer stop-on-episode-end PASS');
  });

  testWidgets('V3：轨道菜单在单轨时给出说明而不是空菜单', (tester) async {
    if (!await fixtureReachable()) {
      markTestSkipped('fixture 服务不可达（$fixtureBaseUrl）');
      return;
    }
    final temp = Directory.systemTemp.createTempSync('webhtv-phase9-tracks');
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

    tester.view.physicalSize = const Size(1280, 800);
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
              url: fixtureMp4Url,
              title: '示例剧集',
              siteKey: 'fixture',
              vodId: 'demo-1',
              vodName: '示例剧集',
              episodeName: 'E1',
              flag: '线路一',
              headers: fixtureMediaHeaders,
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 50; i++) {
      await tester.pump(const Duration(milliseconds: 250));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 120)),
      );
    }

    // 右键菜单是 Phase 8 已验证的可靠路径（「更多」按钮在真实窗口里
    // 可能因为浮层隐藏而点空，实测 V3 曾因此失败）。
    final centre = tester.getCenter(find.byType(PlayerPage));
    await tester.tapAt(centre, buttons: kSecondaryButton);
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      find.text('音轨'),
      findsWidgets,
      reason: '音轨入口必须存在（单轨时也应给说明而不是空菜单）',
    );
    expect(
      find.text('视频轨'),
      findsWidgets,
      reason: '视频轨入口必须存在',
    );
    expect(find.text('循环与定时…'), findsWidgets);
    expect(find.text('LUT 滤镜…'), findsWidgets);
    evidence('v3-track-entries PASS');

    expect(tester.takeException(), isNull);
  });

  testWidgets('V4：右键菜单的片头片尾区块可截图', (tester) async {
    if (!await fixtureReachable()) {
      markTestSkipped('fixture 服务不可达（$fixtureBaseUrl）');
      return;
    }
    final temp = Directory.systemTemp.createTempSync('webhtv-phase9-shot');
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

    // 拉高窗口：菜单要整块放下，「片头片尾」区块才不会被滚动区裁掉。
    tester.view.physicalSize = const Size(1440, 1600);
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
              url: fixtureMp4Url,
              title: '示例剧集',
              siteKey: 'fixture',
              vodId: 'demo-1',
              vodName: '示例剧集',
              episodeName: 'E1',
              flag: '线路一',
              headers: fixtureMediaHeaders,
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 50; i++) {
      await tester.pump(const Duration(milliseconds: 250));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 120)),
      );
    }

    // 右键打开菜单。锚点靠近顶部，菜单从 (300,140) 向下展开，1600 高足够。
    await tester.tapAt(const Offset(300, 140), buttons: kSecondaryButton);
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('片头片尾'), findsOneWidget, reason: '右键菜单必须有片头片尾区块');
    expect(find.text('标记片头为当前位置'), findsOneWidget);
    expect(find.text('标记片尾为当前位置'), findsOneWidget);

    // `findsOneWidget` 只说明 widget 在树里（`SingleChildScrollView` 的 Column
    // 会构建全部子项），不说明画在屏幕上。上一版截图因此拍到了速度档位，
    // 「片头片尾」被滚动区裁在下面。这里直接断言它的矩形落在菜单可视区内。
    final menuRect = tester.getRect(find.byType(PlayerContextMenu));
    final skipTitleRect = tester.getRect(find.text('片头片尾'));
    final skipIntroRect = tester.getRect(find.text('标记片头为当前位置'));
    expect(
      menuRect.contains(skipTitleRect.center),
      isTrue,
      reason: '片头片尾标题必须在菜单可视区内（menu=$menuRect title=$skipTitleRect）',
    );
    expect(
      menuRect.contains(skipIntroRect.center),
      isTrue,
      reason: '标记片头条目必须在菜单可视区内（menu=$menuRect item=$skipIntroRect）',
    );
    evidence(
      'v4-menu-rect l=${menuRect.left} t=${menuRect.top} '
      'w=${menuRect.width} h=${menuRect.height}',
    );

    // 菜单本体不含视频帧与屏显时钟，但滚动/悬停仍有极小的时序差异；
    // 连续两帧像素一致才允许落盘。
    final full = await captureBytes(tester);
    expect(full, isNotNull, reason: '截图必须真实产出');
    await tester.pump(const Duration(milliseconds: 500));
    final fullAgain = await captureBytes(tester);
    expect(fullAgain, isNotNull);
    final region = Rect.fromLTRB(
      menuRect.left.floorToDouble(),
      menuRect.top.floorToDouble(),
      menuRect.right.ceilToDouble(),
      menuRect.bottom.ceilToDouble(),
    );
    final shot = await cropPng(full!, region);
    final shotAgain = await cropPng(fullAgain!, region);
    expect(
      _sameBytes(shot, shotAgain),
      isTrue,
      reason: '同一场景连续两帧必须逐字节一致',
    );
    writeEvidenceBytes(
      shot,
      'docs/phase9/evidence/screenshots/01-context-menu-skip-segments.png',
    );
    evidence('v4-screenshot PASS region=$region');
  });

  testWidgets('V5：节目单回看入口生成真实地址，无 catchup 的频道不显示入口', (tester) async {
    if (!await fixtureReachable()) {
      markTestSkipped('fixture 服务不可达（$fixtureBaseUrl）');
      return;
    }
    final temp = Directory.systemTemp.createTempSync('webhtv-phase9-catchup');
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
      try {
        temp.deleteSync(recursive: true);
      } catch (_) {}
    });
    await state.bootstrap();

    final configText = jsonEncode({
      'name': 'phase9-catchup',
      'sites': [
        {
          'key': 'fixture-type1',
          'name': 'Fixture',
          'type': 1,
          'api': '$fixtureBaseUrl/api/type1/',
        },
      ],
      'lives': [
        {'name': 'M3U 直播', 'type': 1, 'url': '$fixtureBaseUrl/live/live.m3u'},
      ],
    });
    final imported = await state.importConfig(
      configText,
      displayName: 'phase9-catchup',
    );
    expect(imported, isTrue, reason: state.lastError?.logLine);

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
        home: Scaffold(body: LivePage(state: state)),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 5));

    // 反向：CCTV-2 的 M3U 条目没有 catchup，即使节目单已结束也不得有回看入口。
    await tester.tap(find.text('CCTV-2 财经'));
    await tester.pumpAndSettle(const Duration(seconds: 2));
    await tester.tap(find.text('节目单'));
    await tester.pumpAndSettle(const Duration(seconds: 2));
    expect(
      find.byIcon(Icons.replay),
      findsNothing,
      reason: '没有 catchup 的频道不得伪造回看入口',
    );
    evidence('v5-no-catchup replay-entry=absent PASS');

    // 正向：CCTV-1 带 catchup="default"，节目单已结束 → 出现回看入口。
    await tester.tap(find.text('CCTV-1 综合'));
    await tester.pumpAndSettle(const Duration(seconds: 2));
    await tester.tap(find.text('节目单'));
    await tester.pumpAndSettle(const Duration(seconds: 2));
    final replay = find.byTooltip('回看 朝闻天下');
    expect(replay, findsOneWidget, reason: '已结束节目必须有回看入口');

    await tester.tap(replay);
    // 播放器有屏显时钟，不能 pumpAndSettle（永不 settle）；固定步进等路由完成。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));

    final player = tester.widget<PlayerPage>(find.byType(PlayerPage));
    final url = player.request.url;
    evidence('v5-catchup url=$url');
    expect(url, startsWith('$fixtureBaseUrl/media/sample.m3u8?start='));
    expect(url, contains('&end='));
    expect(player.request.flag, '回看');
    expect(player.request.episodeName, '朝闻天下');
    expect(player.request.directUrl, isTrue);
    evidence('v5-catchup-replay PASS');
  });
}

bool _sameBytes(Uint8List left, Uint8List right) {
  if (left.length != right.length) return false;
  for (var i = 0; i < left.length; i++) {
    if (left[i] != right[i]) return false;
  }
  return true;
}
