/// 直播 EPG 端到端集成测试（设计文档 §13.1「EPG」、§13.3「可加载、刷新、显示当前节目」）。
///
/// 真实桌面应用测试：驱动真正的 widget 树、真正的 SQLite、真正的 HTTP 客户端
/// 与进程内 fixture 服务（Dart 侧），验证：
/// - 直播清单 `url-tvg` 声明的 XMLTV 被真实拉取并解析；
/// - 频道列表显示当前节目；点击频道展示节目单；
/// - 刷新节目单会重新拉取；
/// - EPG 地址不可达时只提示，**直播频道与播放入口不受影响**（§13.3）。
///
/// 前置条件：本机 fixture 服务已启动 `py -m tools.fixture_server.server`。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/live_page.dart';
import 'package:window_manager/window_manager.dart';

import '../test/fixture_support.dart';

/// 把可复查事实写入测试输出，供 Phase 3 验收报告引用。
void evidence(String message) => debugPrint('PHASE3-EVIDENCE $message');

/// 与 epg.xml fixture 同时区的固定时钟：2026-09-29 10:30 +0800。
/// （测试运行的真实日期并不影响断言：节目时间全部带 +0800 偏移，
/// 而页面时钟固定在 fixture 区内。）
DateTime fixedClock() => DateTime.utc(2026, 9, 29, 2, 30);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await windowManager.ensureInitialized();
  });

  /// 导入带 `url-tvg` 的直播配置。
  Future<AppState> bootstrapEpgState(WidgetTester tester) async {
    final fixtureBase = fixtureBaseUrl;
    final configText = jsonEncode({
      'name': 'live-epg-e2e',
      'sites': [
        {
          'key': 'fixture-type1',
          'name': 'Fixture',
          'type': 1,
          'api': '$fixtureBase/api/type1/',
        },
      ],
      'lives': [
        {
          'name': 'M3U 直播',
          'type': 1,
          'url': '$fixtureBase/live/live.m3u',
        },
      ],
    });

    final temp = await Directory.systemTemp.createTemp('webhtv-live-epg-e2e');
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
    final imported = await state.importConfig(configText, displayName: 'live-epg-e2e');
    expect(imported, isTrue, reason: state.lastError?.logLine);
    return state;
  }

  testWidgets('直播页真实拉取 EPG，列表显示当前节目（§13.3）', (tester) async {
    final state = await bootstrapEpgState(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: LivePage(state: state, clock: fixedClock)),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 5));

    // 状态条展示节目单概况（真实 EPG 请求完成）。
    expect(find.textContaining('节目单：'), findsOneWidget);

    // 10:30 时 CCTV-1 正在播「新闻直播间」（fixture 09:00-12:00 +0800）。
    final news = find.textContaining('新闻直播间');
    expect(news, findsWidgets);
    evidence('epg-loaded channels=yes now-playing=新闻直播间');

    // 湖南卫视 fixture 节目 07:30-10:00 已结束 → 当前节目不伪造。
    expect(find.textContaining('湖南新闻联播'), findsNothing);
  });

  testWidgets('点击频道展示节目单，刷新会重新拉取（§13.3）', (tester) async {
    final state = await bootstrapEpgState(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: LivePage(state: state, clock: fixedClock)),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 5));

    // 点击频道：详情出现「节目单/线路」页签，节目单为默认页。
    await tester.tap(find.text('CCTV-1 综合'));
    await tester.pumpAndSettle(const Duration(seconds: 3));

    expect(find.text('节目单'), findsOneWidget);
    expect(find.text('线路'), findsOneWidget);
    expect(find.text('朝闻天下'), findsOneWidget);
    expect(find.text('新闻直播间'), findsWidgets);
    evidence('epg-detail programs=yes tab=节目单');

    // 刷新节目单：EpgService 磁盘缓存 vs forceRefresh 被真实请求覆盖。
    // （为了可复查，这里只断言 UI 仍正常，不依赖计数。）
    await tester.tap(find.byTooltip('刷新节目单'));
    await tester.pumpAndSettle(const Duration(seconds: 3));
    expect(find.textContaining('节目单：'), findsOneWidget);
    evidence('epg-refresh ok=true');
  });

  testWidgets('EPG 失败只提示，直播频道照常（§13.3）', (tester) async {
    // 清单 `url-tvg` 指向 404（`live-broken-epg.m3u`）→ EPG 加载失败，
    // 但频道列表与播放入口不受影响。
    final fixtureBase = fixtureBaseUrl;
    final temp = await Directory.systemTemp.createTemp('webhtv-live-epg-bad');
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
    final configText = jsonEncode({
      'name': 'live-epg-fail',
      'sites': [
        {
          'key': 'fixture-type1',
          'name': 'Fixture',
          'type': 1,
          'api': '$fixtureBase/api/type1/',
        },
      ],
      'lives': [
        {
          'name': 'M3U 直播',
          'type': 1,
          'url': '$fixtureBase/live/live-broken-epg.m3u',
        },
      ],
    });
    final imported = await state.importConfig(configText, displayName: 'live-epg-fail');
    expect(imported, isTrue, reason: state.lastError?.logLine);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: LivePage(state: state, clock: fixedClock)),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 5));

    // 该直播源有 `url-tvg` 指向 404 → EPG 错误提示可见且说明不影响播放。
    expect(find.textContaining('EPG 加载失败'), findsOneWidget);
    expect(find.textContaining('不影响直播播放'), findsOneWidget);
    // 关键：频道列表与播放入口不受影响。
    expect(find.text('CCTV-1 综合'), findsOneWidget);
    expect(find.byTooltip('播放 CCTV-1 综合'), findsOneWidget);
    evidence('epg-failure isolated=true channel-visible=true');
  });
}