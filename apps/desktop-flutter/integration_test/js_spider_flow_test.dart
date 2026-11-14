/// JS（Node）Spider 端到端集成测试（设计文档 §9.1、§9.3、§9.7、§9.8、§21 Phase 3）。
///
/// 真实链路：本地 `spider-local:<key>` 站点 → `SpiderManifestRegistry` 扫描
/// JS manifest（`runtime=node`）→ `LocalSpiderCommand.resolve` 解析出
/// `node host.js ...` → 真实 Node 子进程 + `webhtv-ipc-v1` 帧握手 →
/// 站源用同步 `req()` 访问真实 fixture 服务 → 返回结构化 Result。
///
/// 覆盖 §21 Phase 3「JS/Node Spider」验收点：
/// - JS 站源能真实启动、握手并被调用（非桩）；
/// - home/category/detail/search 返回真实数据；
/// - 站点入口缺失时可用性判定给出明确原因（不静默）；
/// - 站点启动失败只影响该站点，主程序存活。
///
/// 前置条件：本机 fixture 服务已启动（`py -m tools.fixture_server.server --port 18080`），
/// 且本机安装了 Node（`node --version`）。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';

import '../test/fixture_support.dart';

void evidence(String message) => debugPrint('PHASE3-EVIDENCE $message');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  late Directory temp;
  late AppPaths paths;
  late AppState state;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('webhtv-js-spider-e2e');
    paths = AppPaths.resolve(
      overrides: {
        'config': p.join(temp.path, 'config'),
        'data': p.join(temp.path, 'data'),
        'cache': p.join(temp.path, 'cache'),
        'state': p.join(temp.path, 'logs'),
      },
    );
    state = AppState(
      paths: paths,
      log: LogService(),
      // 显式指向仓库内的 JS / Python 宿主，使集成测试不依赖 PATH 布局。
      sidecarHostPath: p.join(
        repositoryRoot.path,
        'sidecars',
        'spider-host-python',
        'host.py',
      ),
      jsSidecarHostPath: p.join(
        repositoryRoot.path,
        'sidecars',
        'spider-host-js',
        'host.js',
      ),
    );
    await state.bootstrap();
  });

  tearDown(() async {
    state.dispose();
    try {
      await temp.delete(recursive: true);
    } catch (_) {}
  });

  /// 把 JS fixture 站源装进 `<config>/spiders/<key>/`。
  ///
  /// 与产品布局一致：`manifest.json` 与 `spiders/` 同在站点目录下，
  /// 因此 `entry`（`spiders/fixture_spider.js`）按 manifest 目录解析。
  /// `base` 覆写为真实 fixture 服务地址（默认 127.0.0.1:18080 与前置条件一致）。
  Directory installJsSpider({required String key, String? base}) {
    final dir = Directory(p.join(paths.configDir, 'spiders', key))
      ..createSync(recursive: true);
    final sourceRoot = p.join(
      repositoryRoot.path,
      'sidecars',
      'spider-host-js',
    );
    var manifestText = File(
      p.join(sourceRoot, 'manifests', 'fixture.json'),
    ).readAsStringSync();
    // 覆写 key 与 fixture 服务地址，使同一份 fixture 可多实例安装。
    manifestText = manifestText
        .replaceFirst('"key": "js-fixture"', '"key": "$key"')
        .replaceFirst(
          '"base": "http://127.0.0.1:18080"',
          '"base": "${base ?? fixtureBaseUrl}"',
        );
    File(p.join(dir.path, 'manifest.json')).writeAsStringSync(manifestText);
    Directory(p.join(dir.path, 'spiders')).createSync(recursive: true);
    File(
      p.join(sourceRoot, 'spiders', 'fixture_spider.js'),
    ).copySync(p.join(dir.path, 'spiders', 'fixture_spider.js'));
    return dir;
  }

  Future<Site> importSite(String key) async {
    await state.importConfig(
      '{"name":"JS Spider 集成","sites":[{"key":"$key-site",'
      '"name":"JS 本地站点","type":3,"api":"spider-local:$key",'
      '"searchable":1}]}',
    );
    return state.config!.sites.firstWhere((s) => s.key == '$key-site');
  }

  testWidgets('JS Spider：真实 Node 侧车浏览闭环（§21 Phase 3）', (tester) async {
    // 未装站源：可用性判定必须给出明确原因（不显示空列表）。
    final missing = await importSite('missing-fixture');
    await state.rescanSpiders();
    final missingItem = state.siteItems.firstWhere(
      (item) => item.site.key == missing.key,
    );
    expect(missingItem.availability.available, isFalse);
    expect(missingItem.availability.reason, isNotNull);
    evidence(
      'js-unavailable isolated=true runtime=${missingItem.availability.runtimeName}',
    );

    // 装上真实 JS 站源：注册表可见，runtime=node。
    installJsSpider(key: 'js-e2e');
    await state.rescanSpiders();
    final manifest = state.localSpiders
        .firstWhere((s) => s.key == 'js-e2e')
        .manifest;
    expect(manifest.runtime, 'node');
    evidence(
      'js-manifest runtime=${manifest.runtime} '
      'capabilities=${manifest.capabilities.sorted.join(",")}',
    );

    // 导入 spider-local 站点并确认真实可用（宿主机 + JS 宿主 + Node 均就绪）。
    final site = await importSite('js-e2e');
    final item = state.siteItems.firstWhere((i) => i.site.key == site.key);
    expect(item.availability.available, isTrue, reason: item.availability.reason);
    evidence('js-available runtime=${item.availability.runtimeName}');

    // 首页：真实启动 Node 侧车并调用 homeContent。
    await state.selectSite(site);
    expect(state.homeResult, isNotNull, reason: 'JS 站源首页应返回真实数据');
    expect(state.homeResult!.list, isNotEmpty);
    evidence('js-home list=${state.homeResult!.list.length}');

    // 分类。
    await state.loadCategory('1', page: 1);
    expect(state.categoryResult, isNotNull);
    expect(state.categoryResult!.list, isNotEmpty);
    evidence('js-category list=${state.categoryResult!.list.length}');

    // 详情（按 vod 加载）。
    final firstVod = state.categoryResult!.list.first;
    await state.loadDetail(firstVod);
    expect(state.detailResult, isNotNull);
    expect(state.detailResult!.list, isNotEmpty);
    evidence('js-detail episodes=${state.detailResult!.list.length}');

    // 搜索（多站点并发入口，只有可用且 searchable 的站点会真跑）。
    final outcome = await state.searchAll('测试', maxConcurrency: 1);
    expect(outcome.results, isNotEmpty);
    evidence('js-search sites=${outcome.results.length}');

    // 运行时状态与隔离等级如实上报（§18.2.1）。
    final statuses = state.spiderRuntimeStatuses();
    expect(statuses, isNotEmpty);
    expect(statuses.first.state.name, 'running');
    evidence('js-runtime running isolation=${statuses.first.isolation}');

    await state.stopSpider(site.key);
    evidence(
      'js-stopped state=${state.spiderRuntimeStatuses().first.state.name}',
    );
  });

  testWidgets('JS Spider：站点失败被隔离，主程序存活（§9.8）', (tester) async {
    // 入口不存在的 JS manifest：可用性判定阶段即给出明确原因。
    final dir = Directory(p.join(paths.configDir, 'spiders', 'js-broken'))
      ..createSync(recursive: true);
    File(p.join(dir.path, 'manifest.json')).writeAsStringSync(
      '{"abi":"webhtv-ipc-v1","abiMinor":0,"key":"js-broken",'
      '"name":"JS Broken","runtime":"node",'
      '"entry":"spiders/does_not_exist.js",'
      '"capabilities":["home","category","detail","search","play"],'
      '"permissions":{"network":true,"localProxy":false,"ui":false,'
      '"storage":"cache-only","process":false,"clipboard":false,'
      '"browser":false}}',
    );
    await state.rescanSpiders();
    final broken = await importSite('js-broken');
    final brokenItem = state.siteItems.firstWhere(
      (i) => i.site.key == broken.key,
    );
    expect(brokenItem.availability.available, isFalse);
    expect(brokenItem.availability.reason, contains('入口不存在'));
    evidence('js-broken isolated=true reason=entry-missing');

    // 主程序仍能正常工作：装一个正常 JS 站源并加载首页。
    installJsSpider(key: 'js-ok');
    await state.rescanSpiders();
    final ok = await importSite('js-ok');
    await state.selectSite(ok);
    expect(state.homeResult, isNotNull);
    expect(state.homeResult!.list, isNotEmpty);
    evidence('js-ok-after-failure list=${state.homeResult!.list.length}');
    await state.stopSpider(ok.key);
  });
}
