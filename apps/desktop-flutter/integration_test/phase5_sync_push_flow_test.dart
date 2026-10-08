/// Phase 5 · PC 主动推送端到端（`docs/phase5/design/03` §5.3）。
///
/// PC 当客户端，fixture 服务充当安卓的 `/action` 接收端。
///
/// 6 步（`design/03` §5.3）：
///   1. 本地造 3 条历史；
///   2. 点「推送到设备」→ fixture 收到请求；
///   3. 断言 `mode=1`、`type=history`、表单含 `config` 与 `targets`；
///   4. 断言 `targets` 中每条 `key` 以 `@@@0` 结尾；
///   5. 断言请求体**不含** `settings`（默认关闭，P3）；
///   6. fixture 注入 403 → UI 报 `syncLocalWriteRejected` 且文案含安卓侧开关指引。
library;

import 'dart:convert';
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

void evidence(String message) =>
    debugPrint('PHASE5-EVIDENCE sync-push $message');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late AppState state;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('webhtv-push-flow');
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

  Future<void> settle(WidgetTester tester, {int rounds = 30}) async {
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

  testWidgets('推送历史到安卓：形态正确、cid=0、默认不带 settings、403 有指引', (tester) async {
    // 1) 本地造 3 条历史（其中一条已播完，用于验证 completed 重算也走同一路径）。
    final now = DateTime.now().millisecondsSinceEpoch;
    final rows = [
      ('demo-001', '端到端剧集', 'http://127.0.0.1:18080/media/ep-1.m3u8', 600000),
      ('demo-002', '端到端剧集二', 'http://127.0.0.1:18080/media/ep-2.m3u8', 1200000),
      ('demo-003', '端到端剧集三', 'http://127.0.0.1:18080/media/ep-3.m3u8', 2700000),
    ];
    for (final (vodId, name, episodeUrl, position) in rows) {
      state.database!.upsertHistory(
        siteKey: 'csp_Media',
        vodId: vodId,
        vodName: name,
        flag: '线路一',
        episodeName: '第2集',
        episodeId: episodeUrl,
        positionMs: position,
        durationMs: 2700000,
        updatedAt: now,
      );
    }
    expect(state.recentHistory(), hasLength(3));
    evidence('step=1 local-history=3');

    // 前置：接入并授权 fixture 设备（真实路径「接入设备 → 导入站点」）。
    await tester.runAsync(() => state.syncState.probe('127.0.0.1:18080'));
    await tester.runAsync(
      () => state.syncState.authorizePeer(state.syncState.devices.single),
    );
    // 导入站点会产生以 fixture 为 origin 的配置记录，从而让
    // `syncConfigJson()` 能给出与"安卓当前配置"一致的 url（否则推送会被
    // 主动拒绝——那是设计行为，见 `design/02` §3.5）。
    await tester.runAsync(
      () => state.syncState.importSites('127.0.0.1:18080'),
    );
    final record = state.database!.listConfigs().single;
    await tester.runAsync(() => state.activateConfigRecord(record.id));
    await tester.runAsync(() => state.syncState.setPushEnabled(true));
    expect(state.syncState.pushEnabled, isTrue);
    expect(
      state.syncState.peers.single.address,
      fixtureAndroidBase('127.0.0.1:18080'),
    );

    // 打开真实设置页。
    tester.view.physicalSize = const Size(1200, 4200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(home: AndroidSettingsPage(state: state)),
    );
    await tester.pumpAndSettle();

    // 2) 点「推送到设备」→ fixture 收到请求。
    await fixtureReset('/android');
    await tapIo(tester, find.text('推送到设备'));

    final stats = await tester.runAsync(() => fixtureStats('/android'));
    final counts = (stats!['counts'] as Map).cast<String, dynamic>();
    expect(
      counts['/action'],
      1,
      reason: 'fixture 未收到推送请求：$counts',
    );
    expect(state.syncState.lastError, isNull, reason: '推送失败');
    evidence('step=2 fixture-received=1');

    // 3) `mode=1`、`type=history`、表单含 `config` 与 `targets`。
    final query = (stats['lastQuery'] as Map).cast<String, dynamic>();
    final form = (stats['lastForm'] as Map).cast<String, dynamic>();
    expect(query['do'], 'sync');
    expect(query['mode'], '1', reason: '推送 = mode 1（对方接收）');
    expect(query['type'], 'history');
    expect(form.containsKey('config'), isTrue);
    expect(form.containsKey('targets'), isTrue);
    expect(
      (stats['lastHost'] as Map)['/action'],
      '127.0.0.1:18080',
      reason: 'Host 必须与可达地址一致',
    );
    evidence('step=3 mode=${query['mode']} type=${query['type']} '
        'form=${form.keys.toList()..sort()}');

    // 4) `targets` 中每条 `key` 以 `@@@0` 结尾，且毫秒直传。
    final targets = decodeTargets(form['targets'] as String);
    expect(targets, hasLength(3));
    for (final target in targets) {
      final key = target['key'] as String;
      expect(key.endsWith('@@@0'), isTrue, reason: 'key=$key');
      expect(key.split('@@@'), hasLength(3));
      expect(target.containsKey('opening'), isFalse);
      expect(target.containsKey('ending'), isFalse);
      expect(target['speed'], 1.0);
    }
    final firstTarget = targets.firstWhere(
      (target) => (target['key'] as String).contains('demo-001'),
    );
    expect(firstTarget['position'], 600000, reason: '毫秒直传，无换算');
    expect(firstTarget['createTime'], now);
    evidence('step=4 cid-zero=3 millis-verbatim=true');

    // 5) 请求体不含 `settings=true`（含凭据项默认不同步，P3）。
    final options = form['options'] as String;
    expect(options, contains('"settings":false'));
    expect(options, isNot(contains('"settings":true')));
    expect(form.containsKey('allowSensitive'), isFalse);
    evidence('step=5 settings-not-sent=true');

    // 6) fixture 注入 403 → UI 报 syncLocalWriteRejected 且给出安卓侧开关位置。
    await tester.runAsync(() => fixtureMode('/android', '403'));
    await tapIo(tester, find.text('推送到设备'));

    final error = state.syncState.lastError;
    expect(error?.kind, AppErrorKind.syncLocalWriteRejected);
    expect(error!.message, contains('观影记录同步'));
    expect(error.message, contains('本机 API 修改'));
    expect(error.statusCode, 403);
    // UI 必须把归类与文案都显示出来，而不是只说"同步失败"。
    expect(find.byKey(const ValueKey('android-error')), findsOneWidget);
    expect(find.textContaining('本机 API 修改'), findsWidgets);
    evidence('step=6 kind=${error.kind.name} guidance-shown=true');

    await tester.runAsync(() => fixtureMode('/android', 'ok'));
  });

  tearDownAll(() async {
    await fixtureMode('/android', 'ok');
    await fixtureReset('/android');
    evidence('cleanup=mode-ok,stats-reset');
  });
}

/// 解析 fixture 记下的 `targets` 字段。
List<Map<String, Object?>> decodeTargets(String text) => [
  for (final item in jsonDecode(text) as List<Object?>)
    (item as Map).cast<String, Object?>(),
];
