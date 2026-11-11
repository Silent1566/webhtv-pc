/// Phase 7 · 实时同步状态层（`docs/phase7/design/01` §6、`design/04` §3.1
/// 「开关矩阵与联动、周期选择」）。
///
/// 本套件只测**状态层**（联动规则、持久化、引擎装配），UI 控件在 T8 补齐后
/// 追加到同一文件。因此这里用 `test()` 而不是 `testWidgets()`：真实文件 I/O
/// 在 fake-async zone 里会永久挂起（本仓库踩过多次）。
///
/// 三件必须锁死的事（错任一件都静默失效）：
/// 1. **`realtime.pushEnabled` 缺服务端 → 自动拉起服务端**，否则路径 B 不可能工作；
/// 2. **`realtime.settingsEnabled` 缺设置同步 → 拒绝**，否则绕过 Phase 5 的凭据确认；
/// 3. **总开关关闭 → 定时器全停但子开关值保留**，否则用户下次开启要从头再配一遍。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/core/realtime_sync.dart';
import 'package:webhtv_pc/services/android_bridge_service.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/realtime_sync_engine.dart';
import 'package:webhtv_pc/services/sync_client.dart';
import 'package:webhtv_pc/services/sync_server.dart';
import 'package:webhtv_pc/state/app_state.dart';

/// 不触网的桥接与推送客户端：本套件不测桥接/推送。
class _OfflineBridge extends AndroidBridgeService {
  _OfflineBridge() : super(log: LogService());
}

class _NoNetworkClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      throw const SocketException('测试禁止出网');
}

/// 手动调度器：与引擎套件同构（这里只用来断言「排了几个」）。
class ManualScheduler {
  final List<PendingFire> pending = [];

  RealtimeTimerHandle call(Duration delay, void Function() onFire) {
    final handle = PendingFire(delay, onFire);
    pending.add(handle);
    return handle;
  }

  int get activeCount => pending.where((item) => item.isActive).length;

  void clear() {
    for (final item in pending) {
      item.cancel();
    }
    pending.clear();
  }
}

class PendingFire implements RealtimeTimerHandle {
  PendingFire(this.delay, this._onFire);

  final Duration delay;
  final void Function() _onFire;
  bool _active = true;

  @override
  bool get isActive => _active;

  @override
  void cancel() => _active = false;

  void fire() {
    if (!_active) return;
    _active = false;
    _onFire();
  }
}

void main() {
  late Directory tempDir;
  late AppPaths paths;
  late ManualScheduler scheduler;

  AppState buildState() => AppState(
    paths: paths,
    log: LogService(),
    androidBridgeService: _OfflineBridge(),
    syncClient: SyncClient(log: LogService(), client: _NoNetworkClient()),
    // 回环 + 测试端口区间：不占 9978，也不碰局域网。
    syncServerFactory: (host) => SyncServer(
      log: LogService(),
      host: host,
      bindAddress: '127.0.0.1',
      lanIpOverride: '127.0.0.1',
      startPort: 18800,
      endPort: 18810,
    ),
    realtimeScheduler: scheduler.call,
  );

  /// 预置一台「已授权 + 最近接入」的安卓设备（实时同步的目标）。
  Future<void> seedDevice() async {
    final file = File(paths.settingsPath);
    await file.parent.create(recursive: true);
    await file.writeAsString(
      jsonEncode({
        'sync': {
          'deviceUuid': 'pc-uuid',
          'peers': [
            {
              'uuid': 'android-uuid-0001',
              'name': '测试电视',
              'address': 'http://127.0.0.1:19979',
            },
          ],
          'lastBridge': 'http://127.0.0.1:19979',
          'devices': [
            {
              'uuid': 'android-uuid-0001',
              'name': '测试电视',
              'address': 'http://127.0.0.1:19979',
              'lastUsed': 1700000000000,
            },
          ],
        },
      }),
    );
  }

  setUp(() async {
    scheduler = ManualScheduler();
    tempDir = await Directory.systemTemp.createTemp('webhtv-realtime-state');
    paths = AppPaths.resolve(
      overrides: {
        'config': '${tempDir.path}/webhtv-pc',
        'data': '${tempDir.path}/webhtv-pc',
        'cache': '${tempDir.path}/webhtv-pc/cache',
        'state': '${tempDir.path}/webhtv-pc/logs',
      },
    );
    await seedDevice();
  });

  tearDown(() async {
    scheduler.clear();
    try {
      await tempDir.delete(recursive: true);
    } on Object {
      // Windows 上偶发占用，清理失败不影响断言。
    }
  });

  group('默认值与持久化（design/01 §6.1、§9.1）', () {
    test('全新安装：实时同步全部默认关闭，且不排任何定时器', () async {
      final state = buildState();
      await state.bootstrap();

      final realtime = state.syncState.realtime;
      expect(realtime.enabled, isFalse);
      expect(realtime.pullEnabled, isFalse);
      expect(realtime.pushEnabled, isFalse);
      expect(realtime.settingsEnabled, isFalse);
      expect(realtime.intervalSeconds, realtimeDefaultIntervalSeconds);
      expect(realtime.heartbeatSeconds, keepAliveDefaultHeartbeatSeconds);
      expect(realtime.pollAllSites, isFalse);
      expect(scheduler.activeCount, 0);
      state.dispose();
    });

    test('开关写入 settings.json 的 sync.realtime 段并能读回', () async {
      final state = buildState();
      await state.bootstrap();

      expect(await state.syncState.setRealtimeEnabled(true), isTrue);
      expect(await state.syncState.setRealtimePull(true), isTrue);
      expect(await state.syncState.setRealtimeIntervalSeconds(300), isTrue);
      expect(await state.syncState.setRealtimePollAllSites(true), isTrue);

      final settings =
          jsonDecode(await File(paths.settingsPath).readAsString())
              as Map<String, Object?>;
      final realtime =
          (settings['sync']! as Map<String, Object?>)['realtime']!
              as Map<String, Object?>;
      expect(realtime['enabled'], isTrue);
      expect(realtime['pullEnabled'], isTrue);
      expect(realtime['intervalSeconds'], 300);
      expect(realtime['pollAllSites'], isTrue);
      expect(realtime.containsKey('pullCursorMs'), isTrue);
      state.dispose();

      // 重启后保持。
      final reopened = buildState();
      await reopened.bootstrap();
      expect(reopened.syncState.realtime.enabled, isTrue);
      expect(reopened.syncState.realtime.intervalSeconds, 300);
      expect(reopened.syncState.realtime.pollAllSites, isTrue);
      reopened.dispose();
    });

    test('非法周期被吸附到合法档位（不静默接受）', () async {
      final state = buildState();
      await state.bootstrap();
      // 超上限 → 先夹到 3600，再吸附到最近的合法档位（档位表为上界 300）。
      await state.syncState.setRealtimeIntervalSeconds(9999);
      expect(
        state.syncState.realtime.intervalSeconds,
        realtimeIntervalChoices.last,
      );
      await state.syncState.setRealtimeIntervalSeconds(1);
      expect(
        state.syncState.realtime.intervalSeconds,
        realtimeMinIntervalSeconds,
      );
      state.dispose();
    });

    test('心跳周期不得大于轮询周期（归一化时自动夹紧）', () async {
      final state = buildState();
      await state.bootstrap();
      await state.syncState.setRealtimeHeartbeatSeconds(300);
      await state.syncState.setRealtimeIntervalSeconds(15);
      expect(
        state.syncState.realtime.heartbeatSeconds,
        lessThanOrEqualTo(state.syncState.realtime.intervalSeconds),
      );
      state.dispose();
    });
  });

  group('联动规则（design/01 §6.2）', () {
    test('pushEnabled 缺服务端 → 自动开启服务端并提示', () async {
      final state = buildState();
      await state.bootstrap();
      expect(state.syncState.serverRunning, isFalse);

      await state.syncState.setRealtimeEnabled(true);
      expect(await state.syncState.setRealtimePush(true), isTrue);

      expect(state.syncState.realtime.pushEnabled, isTrue);
      expect(state.syncState.serverRunning, isTrue, reason: '路径 B 需要端口在听');
      expect(state.syncState.notice, contains('自动开启'));

      await state.syncState.setServerEnabled(false);
      state.dispose();
    });

    test('settingsEnabled 缺设置同步 → 拒绝，且开关保持 false', () async {
      final state = buildState();
      await state.bootstrap();
      expect(await state.syncState.setRealtimeEnabled(true), isTrue);

      expect(state.syncState.settingsSyncEnabled, isFalse);
      final accepted = await state.syncState.setRealtimeSettings(true);

      expect(accepted, isFalse, reason: '必须先开 Phase 5 的设置同步');
      expect(state.syncState.realtime.settingsEnabled, isFalse);
      expect(state.syncState.lastError?.kind, AppErrorKind.realtimeSyncDisabled);
      state.dispose();
    });

    test('先开设置同步后，settingsEnabled 被接受', () async {
      final state = buildState();
      await state.bootstrap();
      await state.syncState.setSettingsSyncEnabled(true);
      expect(await state.syncState.setRealtimeSettings(true), isTrue);
      expect(state.syncState.realtime.settingsEnabled, isTrue);
      state.dispose();
    });

    test('关闭总开关 → 定时器全停，子开关值保留', () async {
      final state = buildState();
      await state.bootstrap();
      await state.syncState.setRealtimeEnabled(true);
      await state.syncState.setRealtimePull(true);
      expect(scheduler.activeCount, greaterThan(0));

      await state.syncState.setRealtimeEnabled(false);
      expect(scheduler.activeCount, 0, reason: 'G12：总开关关掉必须释放定时器');
      expect(state.syncState.realtime.pullEnabled, isTrue, reason: '子开关值保留');
      expect(state.syncState.realtimeSnapshot, isNotNull);
      state.dispose();
    });

    test('未接入任何设备 → 开启也不排定时器（空跑只刷日志）', () async {
      await File(paths.settingsPath).delete();
      final state = buildState();
      await state.bootstrap();
      await state.syncState.setRealtimeEnabled(true);
      await state.syncState.setRealtimePull(true);

      expect(state.syncState.realtimeDeviceBase, isNull);
      expect(scheduler.activeCount, 0);
      state.dispose();
    });
  });

  group('引擎装配（design/01 §6.4）', () {
    test('开启实时同步+拉取 → 轮询与心跳各一个定时器', () async {
      final state = buildState();
      await state.bootstrap();
      await state.syncState.setRealtimeEnabled(true);
      await state.syncState.setRealtimePull(true);

      expect(scheduler.activeCount, 2);
      final snapshot = state.syncState.realtimeSnapshot!;
      expect(snapshot.running, isTrue);
      expect(snapshot.pollScheduled, isTrue);
      expect(snapshot.heartbeatScheduled, isTrue);
      state.dispose();
    });

    test('只开推送方向 → 只有心跳（路径 B 也要知道安卓在不在）', () async {
      final state = buildState();
      await state.bootstrap();
      await state.syncState.setRealtimeEnabled(true);
      await state.syncState.setRealtimePush(true);

      final snapshot = state.syncState.realtimeSnapshot!;
      expect(snapshot.pollScheduled, isFalse);
      expect(snapshot.heartbeatScheduled, isTrue);
      await state.syncState.setServerEnabled(false);
      state.dispose();
    });

    test('dispose 后不残留定时器（G12）', () async {
      final state = buildState();
      await state.bootstrap();
      await state.syncState.setRealtimeEnabled(true);
      await state.syncState.setRealtimePull(true);
      expect(scheduler.activeCount, 2);

      state.dispose();
      expect(scheduler.activeCount, 0);
    });

    test('切换设备后引擎重新对齐（能力缓存失效）', () async {
      // 只留设备历史、不留已授权对端：这样「忘掉设备」后就没有可用目标了。
      await File(paths.settingsPath).writeAsString(
        jsonEncode({
          'sync': {
            'deviceUuid': 'pc-uuid',
            'lastBridge': 'http://127.0.0.1:19979',
            'devices': [
              {
                'uuid': 'android-uuid-0001',
                'name': '测试电视',
                'address': 'http://127.0.0.1:19979',
                'lastUsed': 1700000000000,
              },
            ],
          },
        }),
      );
      final state = buildState();
      await state.bootstrap();
      await state.syncState.setRealtimeEnabled(true);
      await state.syncState.setRealtimePull(true);
      expect(state.syncState.realtimeDeviceBase, 'http://127.0.0.1:19979');
      expect(scheduler.activeCount, 2);

      await state.syncState.forgetDevice('android-uuid-0001');

      expect(state.syncState.realtimeDeviceBase, isNull);
      expect(
        scheduler.activeCount,
        0,
        reason: '目标设备没了就不该继续空跑（更不该继续打旧设备）',
      );
      state.dispose();
    });
  });

  group('路径 B 的门禁跟随开关（design/01 §3.2.2）', () {
    test('未开实时推送 → 端点回 403（数据不外发）', () async {
      final state = buildState();
      await state.bootstrap();
      await state.syncState.setServerEnabled(true);
      final base = state.syncState.serverBaseUrl!;

      final response = await http.get(
        Uri.parse('$base/api/playback/sync?since=0'),
      );
      expect(response.statusCode, 403);

      await state.syncState.setServerEnabled(false);
      state.dispose();
    });

    test('开了实时推送 → 端点可用（不再要求 Phase 5 的手动推送开关）', () async {
      final state = buildState();
      await state.bootstrap();
      await state.syncState.setRealtimeEnabled(true);
      await state.syncState.setRealtimePush(true);
      expect(state.syncState.pushEnabled, isFalse, reason: '手动推送仍是关闭的');
      final base = state.syncState.serverBaseUrl!;

      final response = await http.get(
        Uri.parse('$base/api/playback/sync?since=0'),
      );
      expect(response.statusCode, 200);
      expect(response.headers['content-type'], contains('application/json'));

      await state.syncState.setServerEnabled(false);
      state.dispose();
    });
  });
}
