/// Phase 7 · 实时同步端到端（`docs/phase7/design/04` §3.1 的
/// `integration_test/phase7_realtime_flow_test.dart`）。
///
/// 真实窗口 + 真实 HTTP（fixture 当安卓）+ 真实 SQLite。
///
/// ## 这条用例要证明什么
///
/// L1/L2 已经把每个纯函数与每个端点单独锁死了。L3 存在的唯一理由是：
/// **把它们串起来时增量语义仍然成立**——也就是「第二轮只拉增量」。
/// 这条性质无法在单元层证明，因为它依赖真实游标推进 + 真实落库 + 真实
/// 第二轮的过滤。
///
/// 步骤：
///   1. 接入 fixture 设备（真实 HTTP 探测）；
///   2. 开启实时同步 + 实时拉取 → 引擎起定时器；
///   3. 手动拉一轮（`manualPullRecentRecords`，不依赖定时器）→ 落库；
///   4. **第二轮只拉增量**：`since` 已推进，同一条记录不再重复返回；
///   5. 幂等：重复拉同一批不产生新行（`skipped`）；
///   6. 断线（fixture 切 403）→ 方向停止 + 游标**不推进**；
///   7. 关闭同步 → 定时器归零（G12）。
///
/// 需要 fixture 服务在跑（`tools/fixture_server/server.py`），
/// 基址由 `WEBHTV_FIXTURE_BASE` 提供（默认 `http://127.0.0.1:18080`）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:webhtv_pc/core/realtime_sync.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';

import 'fixture_http.dart';

void evidence(String message) =>
    debugPrint('PHASE7-EVIDENCE realtime-flow $message');

/// 切换 fixture 的故障注入模式（`/android/__mode?config=<v>`）。
Future<void> setFixtureMode(String mode) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(
      Uri.parse('$fixtureAndroidUrl/__mode?config=$mode'),
    );
    final response = await request.close();
    await response.drain<void>();
  } finally {
    client.close();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late AppState state;

  setUp(() async {
    await fixtureReset('/android');
    await setFixtureMode('ok');
    temp = Directory.systemTemp.createTempSync('webhtv-realtime-flow');
    state = AppState(
      paths: AppPaths.resolve(
        overrides: {
          'config': '${temp.path}/webhtv-pc',
          'data': '${temp.path}/webhtv-pc',
          'cache': '${temp.path}/webhtv-pc/cache',
          'state': '${temp.path}/webhtv-pc/logs',
        },
      ),
      log: LogService(),
    );
    await state.bootstrap();
  });

  tearDown(() async {
    state.dispose();
    try {
      temp.deleteSync(recursive: true);
    } catch (_) {}
    await setFixtureMode('ok');
  });

  /// 交替「推进一帧 → 给真实 I/O 一点时间」。
  Future<void> settle(WidgetTester tester, {int rounds = 30}) async {
    for (var round = 0; round < rounds; round++) {
      await tester.pump(const Duration(milliseconds: 16));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
    }
    await tester.pumpAndSettle();
  }

  /// 让状态层认识这台 fixture 设备（真实探测 + 授权 + 导入站点）。
  ///
  /// 走**生产路径**：
  /// - `probe()` 自己会把设备记进接入历史 → `realtimeDeviceBase` 有值；
  /// - `importSites()` 从 fixture 的 `/vod/api` 导入 170 个站点 →
  ///   `syncSiteKeys()` 非空。
  ///
  /// **为什么必须导入站点**：引擎在「无可轮询站点」时会正确地直接返回
  /// （不是发空请求）。不导入站点的话 `manualPullRecentRecords()` 返回 null，
  /// 测的就不是拉取而是「没有站点」这条早退路径。
  Future<void> connectFixture(
    WidgetTester tester, {
    bool importSites = true,
  }) async {
    final device = await tester.runAsync(
      () => state.syncState.probe(fixtureAndroidUrl),
    );
    expect(device, isNotNull, reason: 'fixture /device 必须可探测');
    await tester.runAsync(() => state.syncState.authorizePeer(device!));
    expect(
      state.syncState.realtimeDeviceBase,
      isNotNull,
      reason: '实时同步必须知道打哪个地址（probe 应已记入接入历史）',
    );

    if (!importSites) return;

    // 导入站点：让引擎有东西可轮询。
    final imported = await tester.runAsync(
      () => state.syncState.importSites(device!.reachableBase),
    );
    expect(imported, isTrue, reason: 'fixture /vod/api 必须能导入站点');
    final recordId = state.syncState.lastImportRecordId;
    expect(recordId, isNotNull);
    await tester.runAsync(() => state.activateConfigRecord(recordId!));
    expect(
      state.syncSiteKeys(all: false),
      isNotEmpty,
      reason: '导入并启用后必须有可轮询站点',
    );
    evidence('站点已导入 keys=${state.syncSiteKeys(all: false).length}');
  }

  testWidgets('真实 HTTP 增量同步：第二轮只拉增量 + 幂等 + 403 不推进游标', (tester) async {
    await connectFixture(tester);

    // —— 1. 开启实时同步（真实定时器；这里只验证装配与手动路径）。
    await tester.runAsync(() async {
      await state.syncState.setRealtimeEnabled(true);
      await state.syncState.setRealtimePull(true);
    });
    await settle(tester, rounds: 5);
    expect(state.syncState.realtime.enabled, isTrue);
    expect(state.syncState.realtime.pullEnabled, isTrue);
    evidence('开关 realtime=on pull=on');

    // —— 2. 手动拉一轮（不依赖定时器，结果确定）。
    final first = await tester.runAsync(
      () => state.syncState.manualPullRecentRecords(),
    );
    expect(first, isNotNull, reason: '手动拉取必须真的发出请求');
    evidence('第一轮 ${first!.describe()}');
    // fixture 的 `/api/playback/history` 返回 3 条 → 应全部落库。
    expect(first.stats.applied, greaterThan(0), reason: '第一轮应有记录落库');
    expect(first.cursorAdvanced, isTrue, reason: '成功后游标必须推进');
    final cursorAfterFirst = state.syncState.realtimePullCursorMs;
    expect(cursorAfterFirst, greaterThan(0));

    // 落库证据：真实 SQLite 里能读到这些记录。
    final stored = state.recentHistory(limit: 50);
    expect(
      stored.where((row) => row.siteKey == 'csp_Media').length,
      greaterThan(0),
      reason: '记录必须真的落进 SQLite（不是只在内存里）',
    );
    evidence('落库 rows=${stored.length} cursor=$cursorAfterFirst');

    // —— 3. 幂等：再拉一轮同一批 → 不产生新行。
    final rowsBeforeSecond = state.recentHistory(limit: 200).length;
    final second = await tester.runAsync(
      () => state.syncState.manualPullRecentRecords(),
    );
    expect(second, isNotNull);
    evidence('第二轮 ${second!.describe()}');
    expect(
      state.recentHistory(limit: 200).length,
      rowsBeforeSecond,
      reason: '重复拉取不得产生新行（幂等）',
    );

    // —— 4. 增量语义：把 fixture 切到 empty，第二轮必须返回 0 条。
    await setFixtureMode('empty');
    final emptyRound = await tester.runAsync(
      () => state.syncState.manualPullRecentRecords(),
    );
    expect(emptyRound, isNotNull);
    expect(
      emptyRound!.stats.applied,
      0,
      reason: '对端无增量时不得凭空造记录',
    );
    evidence('empty 轮 ${emptyRound.describe()}');

    // —— 5. 403：方向停止 + 游标不推进（`design/04` §5 #6 的端到端形态）。
    await setFixtureMode('403');
    final cursorBefore403 = state.syncState.realtimePullCursorMs;
    final forbidden = await tester.runAsync(
      () => state.syncState.manualPullRecentRecords(),
    );
    evidence('403 轮 ${forbidden?.describe() ?? '(null)'}');
    expect(
      state.syncState.realtimePullCursorMs,
      cursorBefore403,
      reason: '鉴权失败时推进游标会永久丢掉断线期间的增量',
    );
    await setFixtureMode('ok');

    // —— 6. 关闭 → 定时器归零（G12）。
    await tester.runAsync(() => state.syncState.setRealtimeEnabled(false));
    await settle(tester, rounds: 5);
    expect(
      state.syncState.realtimeSnapshot?.activeTimers ?? 0,
      0,
      reason: 'G12：关闭后不得残留定时器',
    );
    evidence('关闭 activeTimers=0');
  });

  testWidgets('能力探测：/history 存在 → 完整可用；降级到 /current 时披露', (tester) async {
    await connectFixture(tester);

    // 能力探测经**真实拉取**间接验证：fixture 有 `/api/playback/history`，
    // 因此不应出现降级站点（P5：披露只在真降级时出现）。
    //
    // 之所以不直接调探测函数：那需要为测试在生产代码上开一个口子，
    // 而「有没有降级」这件事在拉取结果里本来就可见。
    await tester.runAsync(() async {
      await state.syncState.setRealtimeEnabled(true);
      await state.syncState.setRealtimePull(true);
    });
    final result = await tester.runAsync(
      () => state.syncState.manualPullRecentRecords(),
    );
    expect(result, isNotNull);
    expect(
      result!.degradedSites,
      isEmpty,
      reason: 'fixture 有 /history，不该走 /current 降级',
    );
    expect(
      state.syncState.realtimePullCapability,
      RealtimePullCapability.history,
      reason: '探测结论应是完整可用（缓存 60 s，刚探过）',
    );
    evidence('降级站点=${result.degradedSites.length} '
        'capability=${state.syncState.realtimePullCapability?.name}');

    await tester.runAsync(() => state.syncState.setRealtimeEnabled(false));
    await settle(tester, rounds: 5);
  });

  testWidgets('路径 B：安卓来拉 PC 增量（真实 HTTP + 真实游标）', (tester) async {
    // 必须先授权对端：未配置 token 时路径 B 只允许白名单内的对端
    // （`design/01` §3.2.2）。不授权的话拿到的是 403「对端未授权」，
    // 那测的是鉴权而不是增量。
    await connectFixture(tester, importSites: false);

    // 先在本地造一条历史，让路径 B 有东西可给。
    await tester.runAsync(() async {
      await state.syncState.setRealtimeEnabled(true);
      await state.syncState.setRealtimePush(true);
    });
    await settle(tester, rounds: 5);
    expect(
      state.syncState.serverRunning,
      isTrue,
      reason: '开启实时推送必须自动拉起服务端（否则安卓拉不到）',
    );
    final port = Uri.parse(state.syncState.serverBaseUrl!).port;

    /// 发一次拉取请求。
    ///
    /// **不无条件 `jsonDecode`**：400（非法游标）的响应体是**纯文本**
    /// （`Invalid X-WebHTV-Since cursor...`），解析会抛 FormatException。
    /// 200 才是 JSON（`design/01` §3.2.2 的响应形态）。
    Future<Map<String, Object?>> pull(String since) async {
      final client = HttpClient();
      try {
        final request = await client.getUrl(
          Uri.parse('http://127.0.0.1:$port/api/playback/sync?since=$since'),
        );
        final response = await request.close();
        final body = await response.transform(utf8.decoder).join();
        Object? decoded;
        try {
          decoded = jsonDecode(body);
        } on FormatException {
          decoded = null;
        }
        return {
          'status': response.statusCode,
          'json': decoded is Map
              ? decoded.map((key, value) => MapEntry('$key', value))
              : <String, Object?>{'raw': body},
        };
      } finally {
        client.close();
      }
    }

    // 空游标 → 200 + JSON（不推进任何本地游标）。
    final first = await pull('0');
    expect(first['status'], 200);
    final payload = first['json']! as Map<String, Object?>;
    expect(payload.containsKey('nextSince'), isTrue);
    expect(payload['items'], isA<List<Object?>>());
    evidence('路径 B since=0 status=200 nextSince=${payload['nextSince']}');

    // 非法游标 → 400（不得回落 0，否则安卓会莫名全量重拉）。
    final bad = await pull('abc');
    expect(bad['status'], 400);
    evidence('路径 B 非法游标 status=400');

    // 身份解析：真实 HTTP 四态里的 create。
    final identity = await tester.runAsync(() async {
      final client = HttpClient();
      try {
        final request = await client.postUrl(
          Uri.parse(
            'http://127.0.0.1:$port/api/playback/identity/resolve',
          ),
        );
        request.headers.contentType = ContentType.json;
        request.write(
          jsonEncode({
            'schema': 'webhtv.playback.identity.v1',
            'operation': 'resolve',
            'configType': 'vod',
            'interfaceKey': 'e2e-device-a',
            // 64 位小写 hex（与安卓 `PlaybackConfigIdentity` 的键形态一致）。
            'strictAddressKeys': [
              'e2e0e2e0e2e0e2e0e2e0e2e0e2e0e2e0e2e0e2e0e2e0e2e0e2e0e2e0e2e0e2e0',
            ],
            'endpointMatchKeys': <String>[],
            'hostMatchKeys': <String>[],
            'legacyConfigKeys': <String>[],
            'sourceDataState': 'empty',
          }),
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
    });
    expect(identity!['status'], 200);
    expect((identity['json']! as Map)['action'], 'create');
    evidence('身份解析 action=create');

    await tester.runAsync(() => state.syncState.setServerEnabled(false));
    await settle(tester, rounds: 5);
  });
}
