/// Phase 5 · 安卓桥接端到端（`docs/phase5/design/03` §5.1）。
///
/// 真实窗口 + 真实 HTTP（fixture 服务充当安卓设备）+ 真实 SQLite。
/// 只验证端到端串联，**不重复** L1/L2 的边界用例（`design/03` §1）。
///
/// 8 步（`design/03` §5.1）：
///   1. 打开设置页 → 安卓设备接入；
///   2. 输入 fixture 地址 → 设备信息正确；
///   3. 点「导入站点」→ 导入成功、站点数 = 170；
///   4. 新配置记录产生，**当前配置未被覆盖**（Q10）；
///   5. 切到桥接配置 → 首页请求打到 fixture；
///   6. 请求的 `Host` 与可达地址一致（P2）；
///   7. 故障注入 `empty` → 明确报错，不是"0 个站点成功"；
///   8. 故障注入 `mismatch` → 拒绝导入 + 错误分类正确。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/config_pages.dart';

import 'fixture_http.dart';
import 'phase5_evidence.dart';

void evidence(String message) =>
    debugPrint('PHASE5-EVIDENCE bridge-flow $message');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// 用**非回环主机名**（`localhost`）接入：这样 `Host` 头如果由客户端默认
  /// 生成而非我们显式设置，两次断言就会不一致，P2 才真的被锁住。
  const androidBase = 'localhost:18080';

  late Directory temp;
  late AppState state;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('webhtv-bridge-flow');
    state = AppState(
      paths: AppPaths.resolve(
        overrides: {'roaming': temp.path, 'local': temp.path},
      ),
      log: LogService(),
    );
    await state.bootstrap();
    await fixtureReset('/android');
    await fixtureMode('/android', 'ok');
  });

  tearDown(() {
    state.dispose();
    try {
      temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> openAndroidPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 4200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(home: AndroidSettingsPage(state: state)),
    );
    await tester.pumpAndSettle();
  }

  /// 交替推进一帧与真实 I/O，直到收敛（真实 HTTP/SQLite 必用）。
  Future<void> settle(WidgetTester tester, {int rounds = 40}) async {
    for (var round = 0; round < rounds; round++) {
      await tester.pump(const Duration(milliseconds: 16));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
    }
    await tester.pumpAndSettle();
  }

  Future<void> tapIo(WidgetTester tester, Finder finder) async {
    await tester.tap(finder);
    await settle(tester);
  }

  testWidgets('设置页 → 接入 fixture 设备 → 导入站点（不切换当前配置）', (tester) async {
    // 前置：没有配置，也没有历史记录。
    expect(state.config, isNull);
    expect(state.database!.listConfigs(), isEmpty);

    // 1) 打开安卓接入页。
    await openAndroidPage(tester);
    expect(find.text('安卓设备接入'), findsOneWidget);
    evidence('step=1 page-opened');

    // 2) 手动输入 fixture 地址 → 设备信息正确（名称 / 类型 / 站点数在导入后可见）。
    await tester.enterText(
      find.byKey(const ValueKey('android-device-input')),
      androidBase,
    );
    await tapIo(tester, find.text('接入设备'));

    expect(state.syncState.lastError, isNull, reason: '设备探测失败');
    expect(state.syncState.devices, hasLength(1));
    final device = state.syncState.devices.single;
    expect(device.name, 'vivo V1923A');
    expect(device.typeLabel, '电视', reason: 'fixture 的 type=0（Leanback）');
    expect(device.reachableBase, fixtureAndroidBase(androidBase));
    expect(state.syncState.notice, contains('已识别设备'));
    evidence('step=2 device=${device.name} type=${device.type}');

    // 3) 导入站点 → 170 个站点。
    final before = state.database!.activeConfig();
    await tapIo(tester, find.byKey(const ValueKey('android-import')));

    expect(state.syncState.lastError, isNull, reason: '导入失败');
    final conversion = state.syncState.conversionFor(androidBase);
    expect(conversion, isNotNull);
    expect(conversion!.siteCount, 170);
    expect(
      conversion.hostRewrites,
      isEmpty,
      reason: 'fixture 用请求 Host 现算站点地址，不应该需要修正',
    );
    evidence('step=3 sites=${conversion.siteCount}');

    // 4) 新配置记录产生，且**当前配置未被覆盖**（Q10）。
    final records = state.database!.listConfigs();
    expect(records, hasLength(1), reason: '应产生一条新配置记录');
    expect(records.single.origin, 'http://localhost:18080');
    expect(records.single.siteCount, 170);
    expect(
      state.database!.activeConfig()?.id,
      before?.id,
      reason: '导入不得切换当前配置（Q10）',
    );
    expect(state.config, isNull, reason: '导入不应把桥接配置设为生效配置');
    evidence('step=4 record=${records.single.id} active-unchanged=true');

    // 4b) 站点地址与请求的 Host 一致（P2 的端到端形态）。
    final siteHosts = <String>{};
    for (final site in conversion.config.sites) {
      final uri = Uri.parse(site.api);
      siteHosts.add('${uri.host}:${uri.port}');
    }
    expect(siteHosts, {'localhost:18080'});
    evidence('step=4b site-hosts=${siteHosts.join(',')}');

    // 截图证据（`design/03` §7）：设备卡片 + 站点数 + 「未切换当前配置」提示。
    await captureEvidence(
      tester,
      relativePath: 'docs/phase5/evidence/android-bridge.png',
      evidence: evidence,
    );
  });

  testWidgets('Host 头与可达地址一致（P2）：切到桥接配置后首页请求打到 fixture', (tester) async {
    // 5) 切到桥接配置。
    await openAndroidPage(tester);
    await tester.enterText(
      find.byKey(const ValueKey('android-device-input')),
      androidBase,
    );
    await tapIo(tester, find.text('接入设备'));
    await tapIo(tester, find.byKey(const ValueKey('android-import')));

    final record = state.database!.listConfigs().single;
    await tester.runAsync(() => state.activateConfigRecord(record.id));
    await settle(tester, rounds: 10);

    expect(state.config, isNotNull);
    expect(state.config!.sites, hasLength(170));
    expect(state.selectedSite, isNotNull);

    // 5b) 加载首页 → 请求打到 fixture 的 `/vod/api?key=...`。
    final site = state.selectedSite!;
    await tester.runAsync(() => state.loadHome(site));
    await settle(tester, rounds: 10);
    expect(state.lastError, isNull, reason: '首页加载失败');
    expect(state.homeResult, isNotNull);

    final stats = await fixtureStats('/android');
    final counts = (stats['counts'] as Map).cast<String, dynamic>();
    final keyRoute = counts.keys.firstWhere(
      (route) => route.startsWith('/vod/api?key='),
      orElse: () => '',
    );
    expect(keyRoute, isNotEmpty, reason: '首页请求未打到 fixture：$counts');

    // 6) 请求的 `Host` 必须是可达地址本身——不是客户端默认生成的值。
    //    这里 base 用的是 `localhost`（非回环字面量），只要 `Host` 由我们显式
    //    设置且当真来自 base，就一定是 `localhost:18080`。
    final lastHost = (stats['lastHost'] as Map).cast<String, dynamic>();
    expect(lastHost['/vod/api?ac=config'], 'localhost:18080');
    expect(
      lastHost[keyRoute],
      'localhost:18080',
      reason: '站点请求的 Host 必须与可达地址一致（P2）',
    );
    evidence('step=5,6 keyRoute=$keyRoute host=${lastHost[keyRoute]}');
    evidence('step=5,6 host-matches-reachable=true');
  });

  testWidgets('故障注入 empty → 明确报错，不显示"0 个站点导入成功"', (tester) async {
    await fixtureMode('/android', 'empty');
    await openAndroidPage(tester);
    await tester.enterText(
      find.byKey(const ValueKey('android-device-input')),
      androidBase,
    );
    await tapIo(tester, find.text('接入设备'));
    await tapIo(tester, find.byKey(const ValueKey('android-import')));

    // 7) 错误必须分类呈现（P5）。
    expect(state.syncState.lastError?.kind, AppErrorKind.bridgeEmptySites);
    expect(find.byKey(const ValueKey('android-error')), findsOneWidget);
    expect(
      state.database!.listConfigs(),
      isEmpty,
      reason: '失败不得留下半成品配置记录',
    );
    evidence('step=7 kind=${state.syncState.lastError!.kind.name}');
  });

  testWidgets('故障注入 mismatch → 拒绝导入 + 分类正确', (tester) async {
    await fixtureMode('/android', 'mismatch');
    await openAndroidPage(tester);
    await tester.enterText(
      find.byKey(const ValueKey('android-device-input')),
      androidBase,
    );
    await tapIo(tester, find.text('接入设备'));
    await tapIo(tester, find.byKey(const ValueKey('android-import')));

    // 8) 站点指向第三方主机 → 必须拒绝整份配置，而不是"导入 1 个站点"。
    expect(state.syncState.lastError?.kind, AppErrorKind.bridgeHostMismatch);
    expect(state.database!.listConfigs(), isEmpty);
    evidence('step=8 kind=${state.syncState.lastError!.kind.name}');
  });

  tearDownAll(() async {
    await fixtureMode('/android', 'ok');
    await fixtureReset('/android');
    evidence('cleanup=mode-ok,stats-reset');
  });
}
