/// MVP-A 端到端集成测试：配置导入 → 站点列表 → 首页 → 分类 → 详情 → 播放 → 历史（§21 Phase 1 验收）。
///
/// 这是一个真实桌面应用测试：它驱动真正的 widget 树、真正的 SQLite 数据库、
/// 真正的 HTTP 客户端和真正的 media-kit 播放器（挂载 `Video` 控件），
/// 通过 `integration_test` 在 Windows 上运行。
///
/// 前置条件：本机 fixture 服务已启动
///   `py -m tools.fixture_server.server`
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/app.dart';
import 'package:webhtv_pc/ui/browse_pages.dart';
import 'package:webhtv_pc/ui/config_pages.dart';
import 'package:webhtv_pc/ui/diagnostics_pages.dart';
import 'package:webhtv_pc/ui/library_pages.dart';
import 'package:webhtv_pc/ui/player_page.dart';
import 'package:window_manager/window_manager.dart';

import '../test/fixture_support.dart';

/// 把可复查事实写入测试输出，供 Phase 1 验收报告引用。
void evidence(String message) => debugPrint('PHASE1-EVIDENCE $message');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  setUpAll(() async {
    await windowManager.ensureInitialized();
  });

  testWidgets('主界面可交互且包含 §17.1 的桌面布局', (tester) async {
    await tester.pumpWidget(const WebHtvApp());
    await tester.pumpAndSettle(const Duration(seconds: 5));

    // 启动页必须已经消失。
    expect(find.text('正在初始化…'), findsNothing);
    // 顶栏入口（配置 / 站点）存在。
    expect(find.textContaining('配置'), findsWidgets);
    // 侧栏五个桌面入口存在。
    expect(find.text('首页'), findsWidgets);
    expect(find.text('最近观看'), findsWidgets);
    expect(find.text('收藏'), findsWidgets);
    expect(find.text('设置'), findsWidgets);
    expect(find.text('日志'), findsWidgets);

    evidence('shell-ready topbar=true sidebar=5');
  });

  testWidgets('首次启动展示使用边界提示，且可确认（§22.4）', (tester) async {
    // 使用独立配置目录，确保本次是“首次启动”。
    final temp = await Directory.systemTemp.createTemp('webhtv-boundary-test');
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

    await tester.pumpWidget(
      MaterialApp(home: AppShell(state: state, startup: const StartupArguments())),
    );
    await tester.pumpAndSettle();

    expect(find.text('使用边界提示'), findsOneWidget);
    expect(find.textContaining('不内置'), findsWidgets);
    evidence('usage-boundary-notice=present');

    await tester.tap(find.text('我已了解并继续'));
    await tester.pumpAndSettle();
    expect(find.text('使用边界提示'), findsNothing);
    evidence('usage-boundary-notice=accepted');
  });

  testWidgets('配置导入 → 首页 → 分类 → 详情 → 播放 闭环', (tester) async {
    final fixtureBase = fixtureBaseUrl;
    final configJson = jsonDecode(readFixture('config/config-e2e.json'));
    // 把 fixture 中的固定端口替换为实际服务地址，便于自定义端口运行。
    final configText = jsonEncode(configJson).replaceAll(
      'http://127.0.0.1:18080',
      fixtureBase,
    );

    final temp = await Directory.systemTemp.createTemp('webhtv-e2e-test');
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

    // 1) 导入配置（JSON 文本入口）。导入会自动加载默认站点首页。
    final imported = await state.importConfig(configText, displayName: 'e2e');
    expect(imported, isTrue, reason: state.lastError?.logLine);
    expect(state.config!.sites.length, 6);
    expect(state.siteItems.length, 6);
    evidence(
      'config-imported sites=${state.config!.sites.length} '
      'origin=${redactUrl(state.activeRecord?.origin ?? "")}',
    );

    // 2) 首页：分类与列表。
    final home = state.homeResult!;
    expect(home.classes, isNotEmpty);
    expect(home.list, isNotEmpty);
    evidence(
      'home-ok classes=${home.classes.length} list=${home.list.length} '
      'site=${state.selectedSite?.key}',
    );

    // 3) 分类：按 type_id 请求并翻页字段正确。
    await state.loadCategory(home.classes.first.typeId, page: 1);
    final category = state.categoryResult!;
    expect(category.list, isNotEmpty);
    expect(state.contentPhase, LoadPhase.ready);
    evidence(
      'category-ok t=${home.classes.first.typeId} list=${category.list.length} '
      'page=${category.page} pagecount=${category.pageCount}',
    );

    // 4) 详情：多线路/多剧集。
    await state.loadDetail(category.list.first);
    final vod = state.detailResult!.list.first;
    final lines = state.playLinesOf(vod);
    expect(lines, isNotEmpty);
    evidence(
      'detail-ok vod=${vod.vodId} lines=${lines.length} '
      'episodes=${lines.first.episodes.length}',
    );

    // 5) 播放决策：解析为可直连地址。
    final decision = await state.resolvePlayback(
      episodeTarget: lines.first.episodes.first.url,
      flag: lines.first.flag,
      vodId: vod.vodId,
    );
    expect(decision, isNotNull);
    expect(decision!.action, PlaybackAction.direct);
    // §11（Phase 2）：带 Header 的播放决策会被改写为本地代理 URL，
    // 目标地址以 base64url 编码在 `/p/<token>/<encoded>` 路径中。
    // 两种形态都必须指向同一媒体资源，且代理改写后仍能真实播放。
    final direct = decision.url!;
    if (direct.contains('/p/')) {
      final encoded = direct.split('/p/').last.split('/').last;
      final decoded = utf8.decode(
        base64Url.decode(base64Url.normalize(encoded)),
      );
      expect(
        decoded,
        contains('/media/sample.m3u8'),
        reason: '代理 URL 必须编码同一个媒体目标',
      );
      evidence('playback-proxied target=$decoded');
    } else {
      expect(direct, contains('/media/sample.m3u8'));
    }
    evidence('playback-decision ${decision.logLine}');

    // 6) 真实播放：挂载 media-kit Video 控件并等待出画。
    final player = Player();
    final videoController = VideoController(player);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: Video(controller: videoController)),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    final outcome = await _openMedia(
      player,
      decision.url!,
      decision.headers?.asRequestHeaders ?? const {},
    );
    evidence('playback ${outcome.summary}');
    expect(outcome.succeeded, isTrue, reason: outcome.summary);
    expect(outcome.firstFrame, isNotNull, reason: '未观测到首帧（position 未前进）');
    // §22.2 的首帧预算是「Release 发行包 + 固定素材 + 重复 10 次 + P50/P95，P95 ≤ 5s」。
    // 本用例是 debug 集成构建且只采一次，用 Release 阈值在这里断言会把渲染环境抖动
    // 误判成功能回归（同机实测：Release 包首帧 0.9–3.2s，debug 集成构建偶发 > 5s）。
    // 因此此处只断言「首帧确实到达」，并把实测值写入证据；10 次 P95 门禁由
    // tools/phase1/run_windows_acceptance.ps1 的 first-frame 采样在 Release 包上执行。
    expect(outcome.firstFrame!.inMilliseconds, greaterThan(0));

    // 7) Seek。
    final seekReached = await _seekAndWait(player, const Duration(seconds: 3));
    evidence('seek reached=$seekReached position=${player.state.position.inMilliseconds}ms');
    expect(seekReached, isTrue);

    // 8) 进度写入与恢复（§15）。
    expect(state.database, isNotNull, reason: '数据库未打开');
    state.recordProgress(
      vod: vod,
      flag: lines.first.flag,
      episodeName: lines.first.episodes.first.name,
      episodeId: lines.first.episodes.first.url,
      position: const Duration(seconds: 3),
      duration: player.state.duration,
    );
    final history = state.recentHistory();
    expect(history, isNotEmpty);
    expect(history.first.vodId, vod.vodId);
    expect(history.first.progressPercent, greaterThan(0));
    evidence(
      'history-persisted vod=${history.first.vodId} '
      'progress=${history.first.progressPercent}% '
      'completed=${history.first.completed}',
    );

    await player.dispose();
  });

  // Phase 2 门禁：进入播放器时自动从历史位置续播（§15.2）。
  testWidgets('进入播放器自动从历史位置续播（§15.2）', (tester) async {
    final fixtureBase = fixtureBaseUrl;
    final configText = jsonEncode(
      jsonDecode(readFixture('config/config-e2e.json')),
    ).replaceAll('http://127.0.0.1:18080', fixtureBase);

    final temp = await Directory.systemTemp.createTemp('webhtv-resume-e2e');
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

    final imported = await state.importConfig(configText, displayName: 'resume');
    expect(imported, isTrue, reason: state.lastError?.logLine);

    final home = state.homeResult!;
    await state.loadCategory(home.classes.first.typeId, page: 1);
    await state.loadDetail(state.categoryResult!.list.first);
    final vod = state.detailResult!.list.first;
    final line = state.playLinesOf(vod).first;
    final episode = line.episodes.first;
    final siteKey = state.selectedSite!.key;

    // 预置历史：已经看到 12 秒（超过 5 秒续播阈值，且远离结尾）。
    state.recordProgress(
      vod: vod,
      flag: line.flag,
      episodeName: episode.name,
      episodeId: episode.url,
      position: const Duration(seconds: 12),
      duration: const Duration(minutes: 40),
    );
    expect(
      state.resumePositionFor(
        siteKey: siteKey,
        vodId: vod.vodId,
        flag: line.flag,
        episodeId: episode.url,
      ),
      const Duration(seconds: 12),
    );

    // 真实 UI 路径：渲染详情页并点击第一集。
    await tester.pumpWidget(
      MaterialApp(home: DetailPage(state: state, vod: vod)),
    );
    await tester.pumpAndSettle(const Duration(seconds: 5));

    final episodeButton = find.widgetWithText(OutlinedButton, episode.name).first;
    expect(episodeButton, findsOneWidget);
    await tester.tap(episodeButton);
    await tester.pumpAndSettle(const Duration(seconds: 10));

    // 断言：进入的播放器确实带上了历史续播位置（不是从头开始）。
    final playerPage = tester.widget<PlayerPage>(find.byType(PlayerPage));
    expect(
      playerPage.request.startPosition,
      const Duration(seconds: 12),
      reason: '进入播放器必须自动从历史位置续播（§15.2）',
    );
    expect(playerPage.request.vodId, vod.vodId);
    expect(playerPage.request.episodeName, episode.name);
    evidence(
      'resume-ui vod=${vod.vodId} episode=${episode.name} '
      'startPosition=${playerPage.request.startPosition?.inSeconds}s',
    );

    // 释放播放器：弹出播放器路由，避免真实播放器残留。
    final context = tester.element(find.byType(PlayerPage));
    Navigator.of(context).pop();
    await tester.pumpAndSettle(const Duration(seconds: 5));
    expect(find.byType(PlayerPage), findsNothing);
  });

  testWidgets('单站点失败不影响其他站点，UI 不卡死（§8.1、§8.4）', (tester) async {
    final fixtureBase = fixtureBaseUrl;
    final temp = await Directory.systemTemp.createTemp('webhtv-failure-test');
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
        'name': '失败站点配置',
        'sites': [
          {
            'key': 'good',
            'name': '可用站点',
            'type': 1,
            'api': '$fixtureBase/api/type1/',
            'header': {
              'Referer': 'http://127.0.0.1:18080/',
              'User-Agent': 'WebHTV-PC/0.1 (Windows)',
            },
          },
          {
            'key': 'broken',
            'name': '失效站点',
            'type': 1,
            'api': '$fixtureBase/api/error-html',
          },
          {
            'key': 'unavailable',
            'name': '未支持 Spider 站点',
            'type': 3,
            'api': 'http://127.0.0.1:18080/spider/demo.js',
          },
        ],
      }),
      displayName: 'failure-sites',
    );
    expect(imported, isTrue, reason: state.lastError?.logLine);

    // 可用站点正常工作。
    final good = state.siteItems.firstWhere((item) => item.site.key == 'good');
    await state.selectSite(good.site);
    expect(state.homeResult?.list, isNotEmpty);
    evidence('good-site home-ok list=${state.homeResult!.list.length}');

    // 失效站点的错误可定位，且 UI 状态回到 failed 而不是永久 loading。
    final broken = state.siteItems.firstWhere((item) => item.site.key == 'broken');
    await state.selectSite(broken.site);
    expect(state.lastError, isNotNull);
    expect(state.lastError!.kind, AppErrorKind.siteHttp);
    expect(state.contentPhase, LoadPhase.failed);
    evidence('broken-site error=${state.lastError!.logLine}');

    // 未支持运行时：站点列表显示为不可运行，而不是空列表。
    final unavailable = state.siteItems
        .firstWhere((item) => item.site.key == 'unavailable');
    expect(unavailable.availability.available, isFalse);
    expect(unavailable.availability.runtimeName, contains('JS'));
    evidence(
      'unavailable-site runtime=${unavailable.availability.runtimeName} '
      'stage=${unavailable.availability.stage}',
    );

    // 切换回可用站点仍然工作（失败没有污染状态）。
    await state.selectSite(good.site);
    expect(state.homeResult?.list, isNotEmpty);
    expect(state.lastError, isNull);
    evidence('recovery after-failure home-ok');
  });

  testWidgets('渲染 UI 页面：配置页、浏览页、详情页、历史页、设置页、日志页', (tester) async {
    final fixtureBase = fixtureBaseUrl;
    final temp = await Directory.systemTemp.createTemp('webhtv-ui-test');
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

    await tester.pumpWidget(
      MaterialApp(home: AppShell(state: state, startup: const StartupArguments())),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('我已了解并继续'));
    await tester.pumpAndSettle();

    // 配置页：三种导入入口与保存列表（页面自带 Scaffold）。
    await state.importConfig(
      readFixture('config/config-e2e.json').replaceAll(
        'http://127.0.0.1:18080',
        fixtureBase,
      ),
      displayName: 'ui-test',
    );
    await tester.pumpWidget(MaterialApp(home: ConfigPage(state: state)));
    await tester.pumpAndSettle();
    expect(find.text('配置导入与管理'), findsOneWidget);
    expect(find.text('选择本地文件'), findsOneWidget);
    expect(find.text('使用仓库 fixture'), findsOneWidget);
    expect(find.textContaining('ui-test'), findsWidgets);
    evidence('config-page-rendered saved-records=${state.configs.length}');

    // 其余页面都是壳层 body 内容，必须放在 Scaffold 内，与产品真实结构一致。
    await state.selectSite(state.siteItems.first.site);
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: BrowsePage(state: state))),
    );
    await tester.pumpAndSettle();
    expect(find.text('默认推荐'), findsOneWidget);
    expect(find.textContaining('刷新首页'), findsOneWidget);
    expect(find.byType(GridView), findsWidgets);
    evidence('browse-page-rendered cards=${state.homeResult!.list.length}');

    // 详情页（自带 Scaffold）：线路与剧集按钮。
    await state.loadDetail(state.homeResult!.list.first);
    await tester.pumpWidget(
      MaterialApp(
        home: DetailPage(state: state, vod: state.homeResult!.list.first),
      ),
    );
    await tester.pumpAndSettle();
    final vod = state.detailResult!.list.first;
    expect(find.text(vod.vodName), findsWidgets);
    final lines = state.playLinesOf(vod);
    expect(find.textContaining(lines.first.displayName), findsWidgets);
    evidence(
      'detail-page-rendered lines=${lines.length} '
      'episodes=${lines.first.episodes.length}',
    );

    // 历史 / 收藏 / 设置 / 日志页（壳层 body 内容）。
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: HistoryPage(state: state))),
    );
    await tester.pumpAndSettle();
    expect(find.text('清空历史'), findsOneWidget);

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: FavoritesPage(state: state))),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('收藏'), findsWidgets);

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: SettingsPage(state: state))),
    );
    await tester.pumpAndSettle();
    expect(find.text('运行信息'), findsOneWidget);
    expect(find.text('清理缓存目录'), findsOneWidget);

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: LogsPage(state: state))),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('复制全部'), findsOneWidget);
    expect(state.log.entries, isNotEmpty);
    evidence('pages-rendered history/favorites/settings/logs logs=${state.log.entries.length}');
  });

  testWidgets('窗口缩放与全屏切换后布局稳定（§17.5）', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    await tester.pumpWidget(const WebHtvApp());
    await tester.pumpAndSettle(const Duration(seconds: 5));
    expect(tester.takeException(), isNull);
    evidence('layout-1280x720 ok');

    await tester.binding.setSurfaceSize(const Size(1920, 1080));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    evidence('layout-1920x1080 ok');

    await tester.binding.setSurfaceSize(const Size(1024, 640));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    evidence('layout-1024x640 ok');

    // 全屏进入与退出（X11/Windows 下由窗口管理器异步处理）。
    if (Platform.isWindows || Platform.isLinux) {
      await windowManager.setFullScreen(true);
      final entered = await _waitForFullScreen(true);
      evidence('fullscreen-entered=$entered');
      await windowManager.setFullScreen(false);
      final restored = await _waitForFullScreen(false);
      evidence('fullscreen-restored=$restored');
      expect(entered && restored, isTrue);
    }

    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('数据库删除后可初始化默认库（§16.3）', (tester) async {
    final temp = await Directory.systemTemp.createTemp('webhtv-rebuild-test');
    final paths = AppPaths.resolve(
      overrides: {
        'config': '${temp.path}${Platform.pathSeparator}config',
        'data': '${temp.path}${Platform.pathSeparator}data',
        'cache': '${temp.path}${Platform.pathSeparator}cache',
        'state': '${temp.path}${Platform.pathSeparator}logs',
      },
    );
    addTearDown(() => temp.deleteSync(recursive: true));

    final first = AppState(paths: paths, log: LogService());
    await first.bootstrap();
    expect(first.startupInfo?.databaseError, isNull);
    first.recordProgress(
      vod: Vod(vodId: 'v', vodName: 'n'),
      flag: 'f',
      episodeName: 'e',
      episodeId: 'i',
      position: const Duration(seconds: 1),
      duration: const Duration(seconds: 10),
    );
    expect(first.recentHistory(), isNotEmpty);
    first.dispose();

    // 删除数据目录后应能重建而不是崩溃。
    Directory(paths.dataDir).deleteSync(recursive: true);

    final second = AppState(paths: paths, log: LogService());
    await second.bootstrap();
    expect(second.startupInfo?.databaseError, isNull);
    expect(second.recentHistory(), isEmpty);
    expect(second.database, isNotNull);
    evidence('database-rebuild-after-delete ok');

    // 缓存目录删除后同样可重建（§16.3）。
    Directory(paths.cacheDir).deleteSync(recursive: true);
    await second.resetCache();
    expect(Directory(paths.cacheDir).existsSync(), isTrue);
    evidence('cache-rebuild-after-delete ok');
    second.dispose();
  });
}

/// 加载媒体并测量加载与首帧（与产品 [PlayerController.open] 同一判定口径）。
Future<PlayerLoadOutcomeLike> _openMedia(
  Player player,
  String url,
  Map<String, String> headers,
) async {
  final stopwatch = Stopwatch()..start();
  Duration? firstFrame;
  Duration? loadElapsed;
  final subscriptions = <Object>[];

  subscriptions.add(
    player.stream.position.listen((position) {
      if (position > Duration.zero) firstFrame ??= stopwatch.elapsed;
    }),
  );

  await player.open(Media(url, httpHeaders: headers));
  // 等待时长可知（加载门禁），再给首帧一个独立窗口。
  try {
    loadElapsed = await player.stream.duration
        .firstWhere((value) => value > Duration.zero)
        .timeout(const Duration(seconds: 20));
  } catch (_) {
    loadElapsed = null;
  }
  if (loadElapsed == null) {
    return PlayerLoadOutcomeLike(succeeded: false);
  }
  final deadline = stopwatch.elapsed + const Duration(seconds: 5);
  while (firstFrame == null && stopwatch.elapsed < deadline) {
    await Future<void>.delayed(const Duration(milliseconds: 25));
    if (player.state.position > Duration.zero) {
      firstFrame ??= stopwatch.elapsed;
    }
  }

  return PlayerLoadOutcomeLike(
    succeeded: true,
    duration: player.state.duration,
    loadElapsed: stopwatch.elapsed,
    firstFrame: firstFrame,
  );
}

Future<bool> _seekAndWait(Player player, Duration target) async {
  await player.pause();
  await player.seek(target);
  final deadline = DateTime.now().add(const Duration(seconds: 6));
  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (player.state.position >= target - const Duration(milliseconds: 750)) {
      return true;
    }
  }
  return false;
}

Future<bool> _waitForFullScreen(bool expected) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (DateTime.now().isBefore(deadline)) {
    if (await windowManager.isFullScreen() == expected) return true;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return await windowManager.isFullScreen() == expected;
}

/// 集成测试用的最小加载结论（与产品侧同口径，便于对比证据）。
class PlayerLoadOutcomeLike {
  const PlayerLoadOutcomeLike({
    required this.succeeded,
    this.duration = Duration.zero,
    this.loadElapsed = Duration.zero,
    this.firstFrame,
  });

  final bool succeeded;
  final Duration duration;
  final Duration loadElapsed;
  final Duration? firstFrame;

  String get summary =>
      'succeeded=$succeeded duration=${duration.inMilliseconds}ms '
      'load=${loadElapsed.inMilliseconds}ms '
      'firstFrame=${firstFrame == null ? "unobserved" : "${firstFrame!.inMilliseconds}ms"}';
}
