/// Phase 5 · PC 同步服务端端到端（`docs/phase5/design/03` §5.2）。
///
/// 真实窗口 + 真实 HTTP（测试自己当"安卓"推给 PC）+ 真实 SQLite。
///
/// 8 步（`design/03` §5.2）：
///   1. 开启同步 → 服务端启动，端口在 9978–9998；
///   2. `GET /device` → 返回 PC 的 Device JSON；
///   3. `POST /action?do=sync&mode=1&type=history` 推 3 条 → 200 `OK`；
///   4. 真实壳层的「最近观看」页出现这 3 条；
///   5. 再推同样 3 条 → 全 `skipped`，历史仍 3 条（幂等）；
///   6. 推 1 条**更旧**的 → `skipped`，本地进度不变（旧不覆盖新）；
///   7. 推 1 条更新的 → `applied`，本地进度前进；
///   8. 关闭同步 → 端口释放（再次绑定成功）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/app.dart';
import 'package:webhtv_pc/ui/config_pages.dart';

import 'fixture_http.dart';
import 'phase5_evidence.dart';

void evidence(String message) =>
    debugPrint('PHASE5-EVIDENCE sync-flow $message');

/// 造一条安卓形态的历史（毫秒直传 + 哨兵值）。
Map<String, Object?> androidHistory({
  String vodId = 'demo-001',
  String episodeUrl = 'http://127.0.0.1:18080/media/ep-1.m3u8',
  String vodName = '端到端剧集',
  int position = 600000,
  int duration = 2700000,
  required int createTime,
}) => {
  'key': 'csp_Media@@@$vodId@@@1',
  'vodName': vodName,
  'vodPic': '',
  'vodFlag': '线路一',
  'vodRemarks': '第2集',
  'episodeUrl': episodeUrl,
  'position': position,
  'duration': duration,
  'createTime': createTime,
  'opening': -9223372036854775808,
  'ending': -9223372036854775808,
};

/// 真实的"安卓"客户端：把表单 POST 到 PC 的服务端。
Future<Map<String, Object?>> postSync({
  required int port,
  required String mode,
  required String type,
  required Map<String, String> form,
}) async {
  final client = HttpClient();
  try {
    final uri = Uri.parse(
      'http://127.0.0.1:$port/action?do=sync&mode=$mode&type=$type',
    );
    final request = await client.postUrl(uri);
    request.headers.contentType = ContentType(
      'application',
      'x-www-form-urlencoded',
    );
    request.write(
      form.entries
          .map(
            (entry) =>
                '${Uri.encodeQueryComponent(entry.key)}='
                '${Uri.encodeQueryComponent(entry.value)}',
          )
          .join('&'),
    );
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    return {'status': response.statusCode, 'body': body};
  } finally {
    client.close();
  }
}

Future<Map<String, Object?>> getDevice(int port) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(
      Uri.parse('http://127.0.0.1:$port/device'),
    );
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    return {
      'status': response.statusCode,
      'json': jsonDecode(body) as Map<String, dynamic>,
    };
  } finally {
    client.close();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late AppState state;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('webhtv-sync-flow');
    state = AppState(
      paths: AppPaths.resolve(
        overrides: {'roaming': temp.path, 'local': temp.path},
      ),
      log: LogService(),
    );
    await state.bootstrap();
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

  testWidgets('开启同步 → 真实 HTTP 推送 → 合并裁决 → 端口释放', (tester) async {
    // 默认关闭（P3）。
    expect(state.syncState.serverEnabled, isFalse);

    // 用户显式开启（这里直接调状态层：UI 二次确认已由 L2 覆盖）。
    final started = await tester.runAsync(
      () => state.syncState.setServerEnabled(true),
    );
    expect(started, isTrue);
    await settle(tester, rounds: 10);

    // 1) 端口落在安卓同款区间（`design/02` §4.1）。
    final port = state.syncState.serverPort;
    expect(port, greaterThanOrEqualTo(9978));
    expect(port, lessThanOrEqualTo(9998));
    expect(state.syncState.serverRunning, isTrue);
    evidence('step=1 port=$port');

    // 2) `GET /device` → PC 的 Device JSON（type=1 = 应用对端）。
    final device = await tester.runAsync(() => getDevice(port));
    expect(device!['status'], 200);
    final payload = device['json']! as Map<String, dynamic>;
    expect(payload['type'], 1);
    expect(payload['uuid'], state.syncState.deviceUuid);
    expect(payload['name'], state.syncState.deviceName);
    expect(payload['ip'], isA<String>());
    evidence('step=2 device-type=${payload['type']} uuid-masked='
        '${state.syncState.maskedDeviceUuid}');

    // 2b) 用户授权对端（`design/02` §5：未授权 uuid/IP 的推送一律 403）。
    //     真实路径是「接入设备 → 导入站点」时自动授权；这里只做同步，
    //     因此显式走一次授权，而不是把 403 当成测试缺陷。
    final peer = await tester.runAsync(
      () => state.syncState.probe('127.0.0.1:18080'),
    );
    expect(peer, isNotNull, reason: 'fixture 设备探测失败');
    await tester.runAsync(() => state.syncState.authorizePeer(peer!));
    expect(state.syncState.peers, hasLength(1));
    evidence('step=2b peer-authorized=1');

    // 3) 推 3 条历史 → 200 OK。
    final now = DateTime.now().millisecondsSinceEpoch;
    const day = 24 * 60 * 60 * 1000;
    final batch = [
      androidHistory(vodId: 'demo-001', createTime: now + 1000 * 1),
      androidHistory(
        vodId: 'demo-002',
        episodeUrl: 'http://127.0.0.1:18080/media/ep-2.m3u8',
        vodName: '端到端剧集二',
        createTime: now + 1000 * 2,
      ),
      androidHistory(
        vodId: 'demo-003',
        episodeUrl: 'http://127.0.0.1:18080/media/ep-3.m3u8',
        vodName: '端到端剧集三',
        createTime: now + 1000 * 3,
      ),
    ];
    final config = jsonEncode({
      'id': 1,
      'type': 0,
      'name': '安卓侧配置',
      'url': 'http://127.0.0.1:18080/vod/api?ac=config',
    });

    final first = await tester.runAsync(
      () => postSync(
        port: port,
        mode: '1',
        type: 'history',
        form: {'config': config, 'targets': jsonEncode(batch)},
      ),
    );
    expect(first!['status'], 200);
    expect(first['body'], startsWith('OK'));
    expect(first['body'], contains('applied=3'));
    expect(first['body'], contains('total=3'));
    expect(state.database!.count('history'), 3);
    evidence('step=3 ${first['body']}');

    // 4) 真实壳层的「最近观看」页必须出现这 3 条。
    tester.view.physicalSize = const Size(1400, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(home: AppShell(state: state, startup: const StartupArguments())),
    );
    await settle(tester, rounds: 40);
    final accept = find.text('我已了解并同意');
    if (accept.evaluate().isNotEmpty) {
      await tester.tap(accept);
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text('最近观看'));
    await settle(tester, rounds: 10);

    for (final name in const ['端到端剧集', '端到端剧集二', '端到端剧集三']) {
      expect(find.text(name), findsOneWidget, reason: '历史页缺少 $name');
    }
    evidence('step=4 history-page-shows=3');

    // 5) 再推同一批 → 全部 skipped（幂等，不新增行）。
    final second = await tester.runAsync(
      () => postSync(
        port: port,
        mode: '1',
        type: 'history',
        form: {'config': config, 'targets': jsonEncode(batch)},
      ),
    );
    expect(second!['body'], contains('applied=0'));
    expect(second['body'], contains('skipped=3'));
    expect(state.database!.count('history'), 3);
    evidence('step=5 idempotent=true ${second['body']}');

    // 6) 推一条**更旧**的 → skipped，本地进度不变（旧不覆盖新）。
    final older = await tester.runAsync(
      () => postSync(
        port: port,
        mode: '1',
        type: 'history',
        form: {
          'config': config,
          'targets': jsonEncode([
            androidHistory(
              vodId: 'demo-001',
              position: 1000,
              createTime: now - day,
            ),
          ]),
        },
      ),
    );
    expect(older!['body'], contains('skipped=1'));
    expect(older['body'], contains('applied=0'));
    expect(state.recentHistory().first.positionMs, 600000);
    evidence('step=6 legacy-ignored=true position=600000');

    // 7) 推一条更新的 → applied，进度前进。
    final newer = await tester.runAsync(
      () => postSync(
        port: port,
        mode: '1',
        type: 'history',
        form: {
          'config': config,
          'targets': jsonEncode([
            androidHistory(
              vodId: 'demo-002',
              episodeUrl: 'http://127.0.0.1:18080/media/ep-2.m3u8',
              vodName: '端到端剧集二',
              position: 1800000,
              createTime: now + day,
            ),
          ]),
        },
      ),
    );
    expect(newer!['body'], contains('applied=1'));
    final updated = state
        .recentHistory()
        .firstWhere((row) => row.vodId == 'demo-002');
    expect(updated.positionMs, 1800000);
    expect(
      updated.updatedAt,
      now + day,
      reason: '必须落远端时间戳（毫秒直传），不是 now()',
    );
    evidence('step=7 progress-forward=true position=1800000');

    // 截图证据（`design/03` §7）：同步开关 + 已授权对端 + 同步明细。
    // 在关闭服务端**之前**拍：关掉之后页面上就没有"正在监听"的状态了。
    await tester.pumpWidget(
      MaterialApp(home: AndroidSettingsPage(state: state)),
    );
    await settle(tester, rounds: 10);
    await captureEvidence(
      tester,
      relativePath: 'docs/phase5/evidence/android-sync.png',
      evidence: evidence,
    );

    // 8) 关闭同步 → 端口立即释放（再次绑定成功）。
    await tester.runAsync(() => state.syncState.setServerEnabled(false));
    await settle(tester, rounds: 10);
    expect(state.syncState.serverRunning, isFalse);

    final rebound = await tester.runAsync(() async {
      final probe = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        port,
      );
      return probe.port;
    });
    expect(
      rebound,
      port,
      reason: '关闭后端口必须真的释放，否则用户无法再次开启',
    );
    evidence('step=8 port-released=$port');
  });

  tearDownAll(() async {
    await fixtureReset('/android');
    evidence('cleanup=stats-reset');
  });
}
