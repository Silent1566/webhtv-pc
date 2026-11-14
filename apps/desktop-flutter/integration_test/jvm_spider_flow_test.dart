/// JVM（Java）Spider 端到端集成测试（设计文档 §9.3、§9.7、§9.8、§9.9、§21 Phase 3，ADR-0002）。
///
/// 真实链路：本地 `spider-local:<key>` 站点 → `SpiderManifestRegistry` 扫描
/// JVM manifest（`runtime=jvm`）→ `LocalSpiderCommand.resolve` 解析出
/// `java -Xmx… -jar host.jar ...` → 真实 JVM 子进程 + `webhtv-ipc-v1` 帧握手 →
/// 站源（`spiders/fixture/FixtureSpider.java`，宿主用 JDK 自带编译器编译）访问真实
/// fixture 服务 → 返回结构化 Result。
///
/// 覆盖 §21 Phase 3「PC Java Spider（`tvbox-java-v1`）」验收点：
/// - JVM 站源能真实启动、握手并被调用（非桩）；
/// - home/category/detail/search/play 返回真实数据；
/// - `csp_*` 站点在 PC 端映射到 `jvm` 运行时，缺 jar / Android jar（含 `classes.dex`）
///   时给出**可定位**原因而不是空列表（ADR-0002）；
/// - 站点入口缺失时可用性判定给出明确原因（不静默）；
/// - 站点启动失败只影响该站点，主程序存活。
///
/// 前置条件：本机 fixture 服务已启动（`py -m tools.fixture_server.server --port 18080`）、
/// 安装了 JDK 17+，且 `sidecars/spider-host-jvm/host.jar` 已构建
/// （`pwsh -File sidecars/spider-host-jvm/build.ps1`）。
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
    temp = await Directory.systemTemp.createTemp('webhtv-jvm-spider-e2e');
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
      // 显式指向仓库内的 Python / JVM 宿主，使集成测试不依赖 PATH 布局。
      sidecarHostPath: p.join(
        repositoryRoot.path,
        'sidecars',
        'spider-host-python',
        'host.py',
      ),
      jvmSidecarHostPath: p.join(
        repositoryRoot.path,
        'sidecars',
        'spider-host-jvm',
        'host.jar',
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

  /// 把 JVM fixture 站源装进 `<config>/spiders/<key>/`。
  ///
  /// 与产品布局一致：`manifest.json` 与 `spiders/` 同在站点目录下，
  /// 因此 `entry`（`spiders/fixture/FixtureSpider.java`）按 manifest 目录解析。
  /// `base` 覆写为真实 fixture 服务地址（默认 127.0.0.1:18080 与前置条件一致）。
  ///
  /// 注意：源码入口需要 JDK（`javax.tools` 编译器）；只有 JRE 的机器上本用例
  /// 会以「找不到可用 Java 运行时」如实失败，而不是静默跳过。
  Directory installJvmSpider({required String key, String? base}) {
    final dir = Directory(p.join(paths.configDir, 'spiders', key))
      ..createSync(recursive: true);
    final sourceRoot = p.join(
      repositoryRoot.path,
      'sidecars',
      'spider-host-jvm',
    );
    var manifestText = File(
      p.join(sourceRoot, 'manifests', 'fixture.json'),
    ).readAsStringSync();
    // 覆写 key 与 fixture 服务地址，使同一份 fixture 可多实例安装。
    manifestText = manifestText
        .replaceFirst('"key": "jvm-fixture"', '"key": "$key"')
        .replaceFirst(
          '"base": "http://127.0.0.1:18080"',
          '"base": "${base ?? fixtureBaseUrl}"',
        );
    File(p.join(dir.path, 'manifest.json')).writeAsStringSync(manifestText);
    Directory(p.join(dir.path, 'spiders', 'fixture')).createSync(recursive: true);
    File(
      p.join(sourceRoot, 'spiders', 'fixture', 'FixtureSpider.java'),
    ).copySync(
      p.join(dir.path, 'spiders', 'fixture', 'FixtureSpider.java'),
    );
    return dir;
  }

  Future<Site> importSite(String key) async {
    await state.importConfig(
      '{"name":"JVM Spider 集成","sites":[{"key":"$key-site",'
      '"name":"JVM 本地站点","type":3,"api":"spider-local:$key",'
      '"searchable":1}]}',
    );
    return state.config!.sites.firstWhere((s) => s.key == '$key-site');
  }

  testWidgets('JVM Spider：真实 JVM 侧车浏览闭环（§21 Phase 3）', (tester) async {
    // 未装站源：可用性判定必须给出明确原因（不显示空列表）。
    final missing = await importSite('missing-jvm-fixture');
    await state.rescanSpiders();
    final missingItem = state.siteItems.firstWhere(
      (item) => item.site.key == missing.key,
    );
    expect(missingItem.availability.available, isFalse);
    expect(missingItem.availability.reason, isNotNull);
    evidence(
      'jvm-unavailable isolated=true runtime=${missingItem.availability.runtimeName}',
    );

    // 装上真实 JVM 站源：注册表可见，runtime=jvm。
    installJvmSpider(key: 'jvm-e2e');
    await state.rescanSpiders();
    final manifest = state.localSpiders
        .firstWhere((s) => s.key == 'jvm-e2e')
        .manifest;
    expect(manifest.runtime, 'jvm');
    evidence(
      'jvm-manifest runtime=${manifest.runtime} '
      'capabilities=${manifest.capabilities.sorted.join(",")}',
    );

    // 导入 spider-local 站点并确认真实可用（Java 运行时 + host.jar + 站源均就绪）。
    final site = await importSite('jvm-e2e');
    final item = state.siteItems.firstWhere((i) => i.site.key == site.key);
    expect(item.availability.available, isTrue, reason: item.availability.reason);
    evidence('jvm-available runtime=${item.availability.runtimeName}');

    // 首页：真实启动 JVM 侧车并调用 homeContent。
    await state.selectSite(site);
    expect(state.homeResult, isNotNull, reason: 'JVM 站源首页应返回真实数据');
    expect(state.homeResult!.list, isNotEmpty);
    evidence('jvm-home list=${state.homeResult!.list.length}');

    // 分类。
    await state.loadCategory('1', page: 1);
    expect(state.categoryResult, isNotNull);
    expect(state.categoryResult!.list, isNotEmpty);
    evidence('jvm-category list=${state.categoryResult!.list.length}');

    // 详情（按 vod 加载）。
    final firstVod = state.categoryResult!.list.first;
    await state.loadDetail(firstVod);
    expect(state.detailResult, isNotNull);
    expect(state.detailResult!.list, isNotEmpty);
    evidence('jvm-detail episodes=${state.detailResult!.list.length}');

    // 搜索（多站点并发入口，只有可用且 searchable 的站点会真跑）。
    final outcome = await state.searchAll('测试', maxConcurrency: 1);
    expect(outcome.results, isNotEmpty);
    evidence('jvm-search sites=${outcome.results.length}');

    // 播放：站源返回结构化 url/flag/header（§9.3 `play`）。
    // 注意：分类列表的 vod 不带 `vod_play_from`/`vod_play_url`，播放入口在**详情**里。
    final detailVod = state.detailResult!.list.first;
    final lines = state.playLinesOf(detailVod);
    expect(lines, isNotEmpty, reason: 'fixture 详情应带播放入口');
    final episode = lines.first.episodes.first;
    final decision = await state.resolvePlayback(
      episodeTarget: episode.url,
      flag: lines.first.flag,
      vodId: detailVod.vodId,
    );
    expect(decision, isNotNull);
    expect(decision!.url, isNotEmpty);
    evidence(
      'jvm-play action=${decision.action.name} url=${decision.url} '
      'flag=${decision.flag ?? "-"}',
    );

    // 运行时状态与隔离等级如实上报（§18.2.1）。
    final statuses = state.spiderRuntimeStatuses();
    expect(statuses, isNotEmpty);
    expect(statuses.first.state.name, 'running');
    evidence('jvm-runtime running isolation=${statuses.first.isolation}');

    await state.stopSpider(site.key);
    evidence(
      'jvm-stopped state=${state.spiderRuntimeStatuses().first.state.name}',
    );
  });

  testWidgets('JVM Spider：站点失败被隔离，主程序存活（§9.8）', (tester) async {
    // 入口不存在的 JVM manifest：可用性判定阶段即给出明确原因。
    final dir = Directory(p.join(paths.configDir, 'spiders', 'jvm-broken'))
      ..createSync(recursive: true);
    File(p.join(dir.path, 'manifest.json')).writeAsStringSync(
      '{"abi":"webhtv-ipc-v1","abiMinor":0,"key":"jvm-broken",'
      '"name":"JVM Broken","runtime":"jvm",'
      '"entry":"spiders/does_not_exist.java",'
      '"capabilities":["home","category","detail","search","play"],'
      '"permissions":{"network":true,"localProxy":false,"ui":false,'
      '"storage":"cache-only","process":false,"clipboard":false,'
      '"browser":false}}',
    );
    await state.rescanSpiders();
    final broken = await importSite('jvm-broken');
    final brokenItem = state.siteItems.firstWhere(
      (i) => i.site.key == broken.key,
    );
    expect(brokenItem.availability.available, isFalse);
    expect(brokenItem.availability.reason, contains('入口不存在'));
    evidence('jvm-broken isolated=true reason=entry-missing');

    // 主程序仍能正常工作：装一个正常 JVM 站源并加载首页。
    installJvmSpider(key: 'jvm-ok');
    await state.rescanSpiders();
    final ok = await importSite('jvm-ok');
    await state.selectSite(ok);
    expect(state.homeResult, isNotNull);
    expect(state.homeResult!.list, isNotEmpty);
    evidence('jvm-ok-after-failure list=${state.homeResult!.list.length}');
    await state.stopSpider(ok.key);
  });

  testWidgets('csp_* 站点在 PC 端映射到桌面 JVM 运行时（ADR-0002）', (tester) async {
    // `csp_<Class>` 是 TVBox 生态形态：PC 端不再一律报「不可用」，而是先找
    // 本地缓存的桌面 jar。缺 jar 时必须给出缓存目录与 dex 说明。
    await state.importConfig(
      '{"name":"CSP 集成","sites":[{"key":"csp_Demo","name":"CSP Demo",'
      '"type":3,"api":"csp_Demo","searchable":1}]}',
    );
    final item = state.siteItems.firstWhere((i) => i.site.key == 'csp_Demo');
    expect(item.availability.available, isFalse);
    expect(item.availability.runtimeName, 'PC Java Spider');
    expect(
      item.availability.reason,
      contains('classes.dex'),
      reason: '缺 jar 时必须说明 Android jar 无法在 JVM 加载',
    );
    evidence(
      'csp-unavailable runtime=${item.availability.runtimeName} '
      'reason-has-dex-hint=true',
    );

    // 放入一个含 `classes.dex` 的 Android jar：必须报「JVM 无法加载」，
    // 而不是启动后崩溃或返回空列表。
    final cspDir = Directory(p.join(paths.configDir, 'spiders', 'csp', 'csp_Demo'))
      ..createSync(recursive: true);
    await _writeZipWithEntries(
      File(p.join(cspDir.path, 'index.jar')),
      const ['classes.dex', 'AndroidManifest.xml'],
    );
    await state.rescanSpiders();
    final androidItem = state.siteItems.firstWhere(
      (i) => i.site.key == 'csp_Demo',
    );
    expect(androidItem.availability.available, isFalse);
    expect(androidItem.availability.runtimeName, 'Android/JAR Spider');
    expect(androidItem.availability.reason, contains('ADR-0002'));
    evidence(
      'csp-android-jar runtime=${androidItem.availability.runtimeName} '
      'isolated=true',
    );
  });
}

/// 写一个只含目录项的最小 zip（无需压缩数据，条目名以明文出现在 zip 中）。
///
/// 用于构造「含 `classes.dex` 的 Android jar」样本，验证 `CspJvmBinding.isAndroidJar`
/// 只读目录项、不加载任何类（§9.8：不可信 jar 不得被宿主执行）。
Future<void> _writeZipWithEntries(File file, List<String> entryNames) async {
  final bytes = <int>[];
  final central = <List<int>>[];
  for (final name in entryNames) {
    final nameBytes = name.codeUnits;
    final offset = bytes.length;
    bytes.addAll(_le32(0x04034b50));
    bytes.addAll(_le16(20));
    bytes.addAll(_le16(0));
    bytes.addAll(_le16(0));
    bytes.addAll(_le16(0));
    bytes.addAll(_le16(0));
    bytes.addAll(_le32(0));
    bytes.addAll(_le32(0));
    bytes.addAll(_le32(0));
    bytes.addAll(_le16(nameBytes.length));
    bytes.addAll(_le16(0));
    bytes.addAll(nameBytes);
    central.add([
      ..._le32(0x02014b50),
      ..._le16(20),
      ..._le16(20),
      ..._le16(0),
      ..._le16(0),
      ..._le16(0),
      ..._le16(0),
      ..._le32(0),
      ..._le32(0),
      ..._le32(0),
      ..._le16(nameBytes.length),
      ..._le16(0),
      ..._le16(0),
      ..._le16(0),
      ..._le16(0),
      ..._le32(0),
      ..._le32(offset),
      ...nameBytes,
    ]);
  }
  final centralStart = bytes.length;
  for (final record in central) {
    bytes.addAll(record);
  }
  final centralSize = bytes.length - centralStart;
  bytes.addAll(_le32(0x06054b50));
  bytes.addAll(_le16(0));
  bytes.addAll(_le16(0));
  bytes.addAll(_le16(central.length));
  bytes.addAll(_le16(central.length));
  bytes.addAll(_le32(centralSize));
  bytes.addAll(_le32(centralStart));
  bytes.addAll(_le16(0));
  await file.writeAsBytes(bytes);
}

List<int> _le16(int value) => [value & 0xff, (value >> 8) & 0xff];

List<int> _le32(int value) => [
  value & 0xff,
  (value >> 8) & 0xff,
  (value >> 16) & 0xff,
  (value >> 24) & 0xff,
];
