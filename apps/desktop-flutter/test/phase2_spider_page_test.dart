/// Spider 管理页门禁测试（设计文档 §17.2、§18.2.1、§18.2、§11）。
///
/// 覆盖 `docs/phase2/README.md` §3 / 步骤 6 的门禁要求：管理页必须展示
/// **运行时、ABI 版本、capability、权限、健康状态**，并支持**启停**。
///
/// 分工：
/// - `testWidgets` 只断言**渲染结果**（展示类要求）。真实磁盘扫描放在
///   `tester.runAsync` 中，因为 `testWidgets` 运行在 fake-async 区，真实 I/O 的
///   完成回调不会被处理，直接 `await` 会死锁。
/// - 真实副作用（启动/停止 sidecar、启动/释放代理端口）用普通 `test()` 覆盖：
///   这些是状态与资源行为，在普通 async 区可正常等待，避免 fake-async 干扰。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/spider_page.dart';

import 'fixture_support.dart';
import 'support/test_fixture_server.dart';

void main() {
  late TestFixtureServer server;
  late Directory tempDir;
  late AppPaths paths;
  late AppState state;

  setUp(() async {
    server = await TestFixtureServer.start();
    tempDir = await Directory.systemTemp.createTemp('webhtv-spider-page');
    paths = AppPaths.resolve(
      overrides: {'roaming': tempDir.path, 'local': tempDir.path},
    );
    state = AppState(
      paths: paths,
      log: LogService(),
      sidecarHostPath: p.join(
        repositoryRoot.path,
        'sidecars',
        'spider-host-python',
        'host.py',
      ),
    );
    await state.bootstrap();
  });

  tearDown(() async {
    await state.stopProxy();
    await state.stopSpider('local-fixture');
    state.dispose();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
    await server.stop();
  });

  Future<void> drainRealIo(WidgetTester tester) async {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 80));
    });
    await tester.pump();
  }

  /// 渲染管理页，并让「扫描本地 Spider」这一真实 I/O 在真实 async 区完成。
  ///
  /// 页面首帧后会通过 post-frame callback 调 `_rescan()`；该扫描运行在
  /// fake-async 区，真实磁盘 I/O 无法推进，而 `scan()` 会**先清空**注册表，
  /// 导致页面错误地显示「已安装的本地 Spider（0）」。这里在真实区重新扫描
  /// 一次作为最终状态，使测试环境与真机一致。
  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: SpiderPage(state: state))),
    );
    await drainRealIo(tester);
    await tester.runAsync(() => state.rescanSpiders());
    await tester.pump();
  }

  Directory writeSpider(String dirName, Map<String, Object?> manifest) {
    final dir = Directory(p.join(paths.configDir, 'spiders', dirName));
    dir.createSync(recursive: true);
    File(p.join(dir.path, 'manifest.json')).writeAsStringSync(
      jsonEncode(manifest),
    );
    return dir;
  }

  Map<String, Object?> fixtureManifest({
    String key = 'sidecar-fixture',
    String? entry,
    String? base,
  }) {
    final manifest =
        jsonDecode(readFixture('spider/manifest-fixture.json'))
            as Map<String, Object?>;
    manifest['key'] = key;
    manifest['name'] = '管理页样本 Spider';
    if (entry != null) manifest['entry'] = entry;
    if (base != null) {
      manifest['config'] = {'base': base, 'playMedia': '/media/sample.m3u8'};
    }
    return manifest;
  }

  /// 装一个可真实运行的本地 Spider（entry 落在 manifest 目录内）。
  void installRunnableSpider() {
    final dir = writeSpider(
      'live',
      fixtureManifest(
        key: 'sidecar-fixture',
        entry: 'fixture_spider.py',
        base: server.baseUrl,
      ),
    );
    File(
      p.join(
        repositoryRoot.path,
        'sidecars',
        'spider-host-python',
        'spiders',
        'fixture_spider.py',
      ),
    ).copySync(p.join(dir.path, 'fixture_spider.py'));
  }

  Future<void> importLocalSite() async {
    await state.importConfig(
      jsonEncode({
        'name': '管理页测试配置',
        'sites': [
          {
            'key': 'local-fixture',
            'name': '本地样本站点',
            'type': 3,
            'api': 'spider-local:sidecar-fixture',
            'searchable': 1,
          },
        ],
      }),
    );
  }

  // ---------------------------------------------------------------------------
  // 渲染（§17.2）
  // ---------------------------------------------------------------------------
  group('Spider 管理页渲染（§17.2）', () {
    testWidgets('空状态：本地 Spider 与运行时都为 0', (tester) async {
      await pumpPage(tester);

      expect(find.text('Spider 运行时'), findsOneWidget);
      expect(find.text('已安装的本地 Spider（0）'), findsOneWidget);
      expect(find.text('运行时状态（0）'), findsOneWidget);
      expect(
        find.text('本次会话还没有站点启动过 Spider 运行时。'),
        findsOneWidget,
      );
    });

    testWidgets('隔离等级如实标记为「尽力隔离」，不宣称沙箱（§18.2.1）', (tester) async {
      await pumpPage(tester);

      expect(
        find.text('隔离等级:进程隔离 + 尽力隔离(不是沙箱)'),
        findsOneWidget,
      );
      final body = tester.widget<Text>(
        find.textContaining('不提供文件系统与网络沙箱'),
      );
      expect(body.data, contains('Job Object'));
      expect(body.data, contains('不自动下载远程脚本'));
      expect(body.data, isNot(contains('强隔离')));
      expect(body.data, isNot(contains('提供沙箱')));
    });

    testWidgets('本地 Spider 卡片展示 ABI、capability、权限与限制', (tester) async {
      writeSpider('demo', fixtureManifest(key: 'demo-spider'));
      await pumpPage(tester);

      expect(find.text('已安装的本地 Spider（1）'), findsOneWidget);
      expect(find.text('管理页样本 Spider（key=demo-spider）'), findsOneWidget);
      // ABI 版本（§17.2 要求展示 ABI 版本）。
      expect(find.text('ABI:webhtv-ipc-v1 minor=0'), findsOneWidget);
      // capability。
      expect(
        find.text('能力:category, detail, home, play, search'),
        findsOneWidget,
      );
      // 权限（§9.7、§17.2）。
      expect(
        find.text(
          '权限:network=true localProxy=false storage=cache-only '
          'ui=false process=false browser=false',
        ),
        findsOneWidget,
      );
      // 资源限制。
      expect(
        find.text('限制:memory=128MiB cpu=15s 并发=2 响应=4MiB 单帧=16MiB'),
        findsOneWidget,
      );
    });

    testWidgets('入口缺失时给出明确提示而不是静默可用', (tester) async {
      // fixture manifest 的 entry 指向 spiders/fixture_spider.py，这里故意不创建。
      writeSpider('broken', fixtureManifest(key: 'broken-spider'));
      await pumpPage(tester);

      expect(find.text('入口缺失'), findsOneWidget);
    });
  });

  // ---------------------------------------------------------------------------
  // 代理卡片渲染与按钮启用状态（§11、§17.2）
  // ---------------------------------------------------------------------------
  group('本地代理卡片（§11）', () {
    testWidgets('未启动时展示状态与启停按钮，停止按钮不可点', (tester) async {
      await pumpPage(tester);

      expect(
        find.text('未启动（首次需要 Header 注入的播放会自动启动）'),
        findsOneWidget,
      );
      expect(find.text('活跃会话:0'), findsOneWidget);
      expect(find.text('启动代理'), findsOneWidget);
      expect(find.text('停止并释放端口'), findsOneWidget);

      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '启动代理'))
            .onPressed,
        isNotNull,
      );
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, '停止并释放端口'),
            )
            .onPressed,
        isNull,
        reason: '未启动时不应允许停止',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // 健康状态与启停（真实副作用，§17.2、§18.2、§11）
  // ---------------------------------------------------------------------------
  group('运行时健康状态与启停（§17.2、§18.2）', () {
    test('真实 sidecar 启动后可强制停止并回到未启动', () async {
      installRunnableSpider();
      await state.rescanSpiders();
      await importLocalSite();

      // 触发一次真实调用，让运行时真正启动（§9.8）。
      final outcome = await state.searchAll('样本', maxConcurrency: 1);
      expect(outcome.results, isNotEmpty);

      final statuses = state.spiderRuntimeStatuses();
      expect(statuses, hasLength(1));
      expect(statuses.first.siteKey, 'local-fixture');
      expect(statuses.first.state.name, 'running');
      // 管理页展示运行时名与隔离等级所需的数据都在状态里。
      expect(statuses.first.isolation, isNotNull);

      await state.stopSpider('local-fixture');
      expect(
        state.spiderRuntimeStatuses().first.state.name,
        'stopped',
        reason: '强制停止后必须回到未启动（§18.2）',
      );
    });

    test('只扫描 manifest 不会启动运行时（页面据此展示空状态）', () async {
      installRunnableSpider();
      await state.rescanSpiders();

      expect(state.localSpiders, hasLength(1));
      expect(
        state.spiderRuntimeStatuses(),
        isEmpty,
        reason: '仅扫描本地 manifest 不得启动 sidecar（导入站点配置后的首页加载才会启动）',
      );
    });
  });

  group('本地代理启停与端口释放（§11）', () {
    test('启动后可停止并释放端口', () async {
      expect(state.proxyRunning, isFalse);

      await state.startProxy();
      expect(state.proxyRunning, isTrue);
      final port = state.proxyPort;
      expect(port, greaterThan(0));

      await state.stopProxy();
      expect(state.proxyRunning, isFalse);

      // 端口必须真的释放：能再次绑定同一端口（§11.4）。
      final rebound = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
      expect(rebound.port, port);
      await rebound.close(force: true);
    });
  });
}
