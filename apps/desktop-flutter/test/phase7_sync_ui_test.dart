/// Phase 7 · 实时同步 UI（`docs/phase7/design/01` §6.1、§7、`design/04` G10）。
///
/// ## 为什么与 `phase7_realtime_state_test.dart` 分开
///
/// 那个文件用 `test()` 跑真实文件 I/O（设置落盘、真实 HTTP 端点）；
/// 本文件是 `testWidgets`（fake-async zone）。两类 I/O 混在一个文件里
/// 会互相干扰：widget 测试的假时钟不会推进真实 I/O 的回调，真实 I/O 的
/// 回调又可能在 mock 之后到达。分文件是本仓库已经踩出来的结论。
///
/// ## 断言重点
///
/// 1. **符号存在**（G10）：`realtime-*` 一组 key 必须能在发布包 UI 里找到；
/// 2. **默认全关**（P3）：未开启时子开关不可操作；
/// 3. **披露文案**（P5）：降级、明文 HTTP、安卓服务未运行、频幕冻结；
/// 4. **手动三按钮语义分开**（§4.4/§4.5）：服务端关闭时给 `syncDisabled`
///    而不是网络错误。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:webhtv_pc/core/android_sync.dart';
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/realtime_sync.dart';
import 'package:webhtv_pc/services/android_bridge_service.dart';
import 'package:webhtv_pc/services/android_read_client.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/realtime_sync_engine.dart';
import 'package:webhtv_pc/services/sync_client.dart';
import 'package:webhtv_pc/services/sync_server.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/config_pages.dart';

/// 不触网的桥接服务（本文件不测桥接）。
class _OfflineBridge extends AndroidBridgeService {
  _OfflineBridge() : super(log: LogService());
}

/// 不触网的推送客户端。
class _NoNetworkClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      throw const SocketException('测试禁止出网');
}

/// 假只读客户端：路径 A 的读取与心跳全部由测试接管。
class _FakeReadClient extends AndroidReadClient {
  _FakeReadClient() : super(log: LogService());

  RealtimePullCapability capability = RealtimePullCapability.history;
  List<SyncHistoryItem> items = const [];
  RealtimeHeartbeatProbe heartbeatProbe = const RealtimeHeartbeatProbe(
    state: RealtimePeerState.ok,
  );
  int readCalls = 0;

  @override
  Future<AndroidPullProbe> probePullCapability(String deviceBase) async =>
      AndroidPullProbe(
        capability: capability,
        historyStatusCode: 200,
        currentStatusCode: null,
      );

  @override
  Future<AndroidHistoryReadResult> readHistory({
    required String deviceBase,
    required String siteKey,
    required RealtimePullCapability capability,
    int limit = realtimeDefaultSiteLimit,
    Map<String, SyncHistoryItem> localByMatchKey = const {},
  }) async {
    readCalls++;
    return AndroidHistoryReadResult(
      siteKey: siteKey,
      items: items,
      failures: const [],
      updatedAtSource: UpdatedAtSource.updatedAt,
      skippedAsUnchanged: 0,
      endpoint: capability,
    );
  }

  @override
  Future<RealtimeHeartbeatProbe> heartbeat(
    String deviceBase, {
    Duration stepTimeout = const Duration(seconds: 2),
    Duration? tcpTimeout,
  }) async => heartbeatProbe;
}

/// 手动调度器：widget 测试不得创建真实定时器（否则用例结束就残留）。
///
/// 本文件不推进时间，只记一个「已排程」标记：需要的是「有没有排」
/// 与「关掉之后还有没有剩」，不需要真的触发。
class _ManualScheduler {
  final List<_Pending> pending = [];

  RealtimeTimerHandle call(Duration delay, void Function() onFire) {
    final handle = _Pending();
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

class _Pending implements RealtimeTimerHandle {
  bool _active = true;

  @override
  bool get isActive => _active;

  @override
  void cancel() => _active = false;
}

void main() {
  late Directory tempDir;
  late AppPaths paths;
  late _ManualScheduler scheduler;
  late _FakeReadClient readClient;
  late AppState state;

  AppState buildState() => AppState(
    paths: paths,
    log: LogService(),
    androidBridgeService: _OfflineBridge(),
    syncClient: SyncClient(log: LogService(), client: _NoNetworkClient()),
    androidReadClient: readClient,
    realtimeScheduler: scheduler.call,
    syncServerFactory: (host) => SyncServer(
      log: LogService(),
      host: host,
      bindAddress: '127.0.0.1',
      lanIpOverride: '127.0.0.1',
      startPort: 18840,
      endPort: 18850,
    ),
  );

  setUp(() async {
    scheduler = _ManualScheduler();
    readClient = _FakeReadClient();
    tempDir = await Directory.systemTemp.createTemp('webhtv-realtime-ui');
    paths = AppPaths.resolve(
      overrides: {
        'config': '${tempDir.path}/webhtv-pc',
        'data': '${tempDir.path}/webhtv-pc',
        'cache': '${tempDir.path}/webhtv-pc/cache',
        'state': '${tempDir.path}/webhtv-pc/logs',
      },
    );
    // 预置一台已授权 + 最近接入的设备（实时同步的目标）。
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
              'address': 'http://127.0.0.1:19981',
            },
          ],
          'lastBridge': 'http://127.0.0.1:19981',
        },
      }),
    );
    state = buildState();
    await state.bootstrap();
    // 路径 A 需要「有站点可轮询」：没有配置时引擎会正确地直接返回
    // （不是发空请求），但那样就测不到读取与披露。这里导入一个最小配置
    // 并启用它——与用户「从安卓导入站源」后的状态一致。
    final recordId = await state.saveBridgeConfig(
      name: '测试站源',
      origin: 'http://127.0.0.1:19981',
      config: AppConfig(
        sites: [
          Site(
            key: 'CupFox',
            name: 'CupFox',
            type: 0,
            api: 'http://127.0.0.1:19981/api.php/provide/vod/',
          ),
        ],
      ),
      diagnostics: const [],
    );
    if (recordId != null) await state.activateConfigRecord(recordId);
  });

  tearDown(() async {
    state.dispose();
    scheduler.clear();
    try {
      await tempDir.delete(recursive: true);
    } on Object {
      // Windows 上偶发占用，清理失败不影响断言。
    }
  });

  /// 打开接入页。视口放大：页面是长 `ListView`，默认 800×600 下靠后控件不构建。
  Future<void> openPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 4200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(home: AndroidSettingsPage(state: state)),
    );
    await tester.pumpAndSettle();
  }

  /// 在真实异步区里执行状态层调用。
  ///
  /// **必须用 `runAsync`**：`testWidgets` 的时钟是假的，设置落盘（真实文件）
  /// 与读客户端（真实 HTTP）的回调都不会被推进，直接 `await` 会静默挂住
  /// ——这在本仓库已经踩过多次。
  Future<T?> io<T>(WidgetTester tester, Future<T> Function() action) =>
      tester.runAsync(action);

  /// 点一个会触发真实文件 I/O 的控件并等它落地。
  ///
  /// `testWidgets` 的时钟是假的：`pumpAndSettle` 不会推进真实 I/O，
  /// 必须夹 `runAsync` 窗口。
  Future<void> tapAndSettleIo(WidgetTester tester, Finder finder) async {
    await tester.tap(finder);
    await tester.pump();
    for (var round = 0; round < 40; round++) {
      await tester.pump(const Duration(milliseconds: 16));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 16)),
      );
    }
    await tester.pumpAndSettle();
  }

  group('符号与默认值（G10 + P3）', () {
    testWidgets('实时同步区块的 key 全部存在', (tester) async {
      await openPage(tester);

      for (final key in [
        'realtime-enabled',
        'realtime-pull',
        'realtime-push',
        'realtime-settings',
        'realtime-interval',
        'realtime-poll-all-sites',
        'realtime-manual-pull',
        'realtime-manual-request-push',
        'realtime-manual-push-history',
        'realtime-manual-push-settings',
      ]) {
        expect(
          find.byKey(ValueKey(key)),
          findsOneWidget,
          reason: 'G10：发布包 UI 必须有 $key 符号',
        );
      }
      expect(find.text('实时同步'), findsOneWidget);
      expect(find.text('手动操作'), findsOneWidget);
    });

    testWidgets('默认全部关闭，未开启总开关时子开关不可操作', (tester) async {
      await openPage(tester);
      expect(state.syncState.realtime.enabled, isFalse);

      for (final key in ['realtime-pull', 'realtime-push', 'realtime-settings']) {
        final tile = tester.widget<SwitchListTile>(
          find.byKey(ValueKey(key)),
        );
        expect(tile.value, isFalse, reason: '$key 默认必须关闭（P3）');
        expect(tile.onChanged, isNull, reason: '总开关关闭时 $key 不可操作');
      }
    });

    testWidgets('开启总开关 → 子开关可操作 + 出现状态行', (tester) async {
      await openPage(tester);
      await tapAndSettleIo(
        tester,
        find.byKey(const ValueKey('realtime-enabled')),
      );

      expect(state.syncState.realtime.enabled, isTrue);
      final pull = tester.widget<SwitchListTile>(
        find.byKey(const ValueKey('realtime-pull')),
      );
      expect(pull.onChanged, isNotNull);
      expect(find.byKey(const ValueKey('realtime-status')), findsOneWidget);
    });

    testWidgets('周期下拉选 300 s → 落到状态层', (tester) async {
      await openPage(tester);
      await tapAndSettleIo(
        tester,
        find.byKey(const ValueKey('realtime-enabled')),
      );

      await tester.tap(find.byKey(const ValueKey('realtime-interval')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('300 s').last);
      await tester.pumpAndSettle();
      await tapAndSettleIo(tester, find.byKey(const ValueKey('realtime-enabled')));

      expect(state.syncState.realtime.intervalSeconds, 300);
    });
  });

  group('联动规则的用户可见后果（design/01 §6.2）', () {
    testWidgets('未开「同步设置项」时开设置实时同步 → 披露拒绝原因', (tester) async {
      await openPage(tester);
      await tapAndSettleIo(
        tester,
        find.byKey(const ValueKey('realtime-enabled')),
      );

      await tapAndSettleIo(
        tester,
        find.byKey(const ValueKey('realtime-settings')),
      );

      expect(state.syncState.realtime.settingsEnabled, isFalse);
      expect(
        state.syncState.lastError?.kind,
        AppErrorKind.realtimeSyncDisabled,
      );
      // 错误必须上屏（不能只写日志）：用户点了却什么也没变会以为坏了。
      expect(find.byKey(const ValueKey('android-error')), findsOneWidget);
      expect(find.textContaining('同步设置'), findsWidgets);
    });

    testWidgets('实时推送的副标题明说「会自动拉起服务端」（用户在开启前就知道）',
        (tester) async {
      // 为什么不在 widget 测试里真的去开：拉起服务端是真实 `HttpServer` I/O，
      // 在 `testWidgets` 的 fake-async 区里会挂住（已实测）。
      // 联动的「真的会拉起」由 `phase7_realtime_state_test.dart` 用真实 HTTP 锁定，
      // 这里只负责「用户看得到这件事」。
      await openPage(tester);
      final push = tester.widget<SwitchListTile>(
        find.byKey(const ValueKey('realtime-push')),
      );
      expect('${push.subtitle}', contains('自动拉起'));

      final settings = tester.widget<SwitchListTile>(
        find.byKey(const ValueKey('realtime-settings')),
      );
      expect('${settings.subtitle}', contains('明文 HTTP'));
    });
  });

  group('披露文案（design/01 §7.2、P5）', () {
    testWidgets('开启设置实时同步后显示明文 HTTP 提示', (tester) async {
      await io(tester, () async {
        await state.syncState.setSettingsSyncEnabled(true);
        await state.syncState.setRealtimeEnabled(true);
      });
      await openPage(tester);
      await tapAndSettleIo(
        tester,
        find.byKey(const ValueKey('realtime-settings')),
      );

      expect(state.syncState.realtime.settingsEnabled, isTrue);
      expect(
        find.byKey(const ValueKey('realtime-disclosure-plaintext')),
        findsOneWidget,
      );
      expect(find.textContaining('明文 HTTP'), findsWidgets);
    });

    testWidgets('安卓服务未运行时给出「请打开管理页」指引', (tester) async {
      readClient.heartbeatProbe = const RealtimeHeartbeatProbe(
        state: RealtimePeerState.serviceStopped,
      );
      await io(tester, () async {
        await state.syncState.setRealtimeEnabled(true);
        await state.syncState.setRealtimePull(true);
      });
      // 手动触发一次心跳，让状态落到快照里。
      await io(tester, () => state.syncState.retryRealtimeNow());
      await openPage(tester);

      expect(
        find.byKey(const ValueKey('realtime-disclosure-service-stopped')),
        findsOneWidget,
      );
    });

    testWidgets('安卓进程被冻结时给出电池设置指引，并原样显示 backgroundGuide',
        (tester) async {
      readClient.heartbeatProbe = const RealtimeHeartbeatProbe(
        state: RealtimePeerState.peerFrozen,
        session: {
          'backgroundSettingsNeeded': true,
          'backgroundGuide': '请在 设置→电池→应用启动管理 中允许后台运行',
        },
      );
      await io(tester, () async {
        await state.syncState.setRealtimeEnabled(true);
        await state.syncState.setRealtimePull(true);
      });
      await io(tester, () => state.syncState.retryRealtimeNow());
      await openPage(tester);

      expect(
        find.byKey(const ValueKey('realtime-disclosure-peer-frozen')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('realtime-disclosure-background-guide')),
        findsOneWidget,
      );
      // 文案必须来自安卓原文（`design/02` §5.3：PC 不得自造）。
      expect(find.textContaining('应用启动管理'), findsWidgets);
    });

    testWidgets('降级到只读「当前播放」时显示降级披露', (tester) async {
      readClient.capability = RealtimePullCapability.currentOnly;
      await io(tester, () async {
        await state.syncState.setRealtimeEnabled(true);
        await state.syncState.setRealtimePull(true);
      });
      await io(tester, () => state.syncState.manualPullRecentRecords());
      await openPage(tester);

      expect(
        find.byKey(const ValueKey('realtime-disclosure-degraded')),
        findsOneWidget,
      );
      expect(find.textContaining('正在播放'), findsWidgets);
    });

    testWidgets('路径 A 不可用时披露「请升级安卓端」而不是「0 条」', (tester) async {
      readClient.capability = RealtimePullCapability.unsupported;
      await io(tester, () async {
        await state.syncState.setRealtimeEnabled(true);
        await state.syncState.setRealtimePull(true);
      });
      await io(tester, () => state.syncState.manualPullRecentRecords());
      await openPage(tester);

      expect(
        find.byKey(const ValueKey('realtime-disclosure-unsupported')),
        findsOneWidget,
      );
    });
  });

  group('手动操作（design/01 §4.4、§4.5、S21/S22）', () {
    testWidgets('「拉取最近记录」在实时同步关闭时仍可用（不依赖服务端）', (tester) async {
      expect(state.syncState.realtime.enabled, isFalse);
      expect(state.syncState.serverEnabled, isFalse);
      await openPage(tester);

      readClient.items = [
        SyncHistoryItem(
          siteKey: 'CupFox',
          vodId: '/video/1',
          vodName: '示例',
          flag: '线路1',
          episodeName: '第01集',
          episodeId: 'e1',
          positionMs: 1000,
          durationMs: 10000,
          updatedAt: 1700000000000,
        ),
      ];
      await tapAndSettleIo(
        tester,
        find.byKey(const ValueKey('realtime-manual-pull')),
      );

      expect(readClient.readCalls, greaterThan(0), reason: 'S21：应真的去读安卓');
      expect(
        find.byKey(const ValueKey('realtime-manual-result')),
        findsOneWidget,
      );
    });

    testWidgets('「请求安卓推送全量」在服务端关闭时给 syncDisabled（S22）', (tester) async {
      await openPage(tester);
      await tapAndSettleIo(
        tester,
        find.byKey(const ValueKey('realtime-manual-request-push')),
      );

      expect(
        state.syncState.lastError?.kind,
        AppErrorKind.syncDisabled,
        reason: 'S22：必须是 syncDisabled，不是网络错误',
      );
      expect(find.byKey(const ValueKey('android-error')), findsOneWidget);
      expect(find.textContaining('服务端'), findsWidgets);
    });

    testWidgets('推送历史未开启「向安卓推送」时明确拒绝', (tester) async {
      await openPage(tester);
      await tapAndSettleIo(
        tester,
        find.byKey(const ValueKey('realtime-manual-push-history')),
      );

      expect(state.syncState.pushEnabled, isFalse);
      expect(
        state.syncState.lastError?.kind,
        AppErrorKind.syncDisabled,
      );
    });
  });
}
