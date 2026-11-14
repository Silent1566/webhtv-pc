/// 多源桥接：历史按源隔离 + 全局历史开关 + 推送按源（用户反馈 2026-10-26）。
///
/// ## 为什么单开一个文件
///
/// 这些断言全部落在**状态层**（AppState + AppDatabase），不需要 widget 树；
/// 走 `test()` 可以用真实文件 I/O 与真实 sqlite，不必像
/// `phase5_sync_ui_test.dart` 那样在假时钟里夹 `runAsync` 窗口。
///
/// ## 锁定的用户可见行为
///
/// 1. 桥接后同一台安卓设备上的每个源都成为**独立配置记录**，互不覆盖
///    （去重键是 `source_key`，不是网关 `origin`）；
/// 2. 历史**默认按源隔离**：切到 A 源只看到 A 源的进度，切到 B 源只看 B 源；
/// 3. 「全部来源」开关打开后才跨源显示（对齐安卓 `global_history_mode`）；
/// 4. 清空历史只清当前源，不误删别的源；
/// 5. 推送给安卓的载荷带该源的 `configKey`，且历史只含当前源；
/// 6. 实时从安卓拉来的进度带该设备**当前激活源**的标识（否则历史页
///    「当前来源」里会冒出「来源未知」卡片，用户反馈 2026-10-28）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/android_bridge.dart';
import 'package:webhtv_pc/core/android_sources.dart';
import 'package:webhtv_pc/core/android_sync.dart';
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/core/history_scope.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/realtime_sync.dart';
import 'package:webhtv_pc/core/source_key.dart';
import 'package:webhtv_pc/services/android_read_client.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';

import 'support/fake_sources_bridge.dart';

/// 假只读客户端：路径 A 的读取全部由测试接管（本文件不触网）。
class _FakeReadClient extends AndroidReadClient {
  _FakeReadClient() : super(log: LogService());

  /// 下一次 `readHistory` 返回的记录（每条站点查询都返回同一批）。
  List<SyncHistoryItem> items = const [];

  /// 非空时 `probePullCapability` 直接抛这个错误。
  AppError? probeFailure;

  int readCalls = 0;

  @override
  Future<AndroidPullProbe> probePullCapability(String deviceBase) async {
    final failure = probeFailure;
    if (failure != null) throw failure;
    return const AndroidPullProbe(
      capability: RealtimePullCapability.history,
      historyStatusCode: 200,
      currentStatusCode: null,
    );
  }

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
}

void main() {
  late Directory tempDir;
  late AppState state;
  late FakeSourcesBridge bridge;
  late _FakeReadClient readClient;

  const device = AndroidDevice(
    uuid: 'dev-uuid-0001',
    name: '测试电视',
    reachableBase: 'http://192.168.50.9:9978',
    type: 0,
  );

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('webhtv-multisource');
    bridge = FakeSourcesBridge();
    readClient = _FakeReadClient();
    state = AppState(
      paths: AppPaths.resolve(
        overrides: {
          'config': '${tempDir.path}/webhtv-pc',
          'data': '${tempDir.path}/webhtv-pc',
          'cache': '${tempDir.path}/webhtv-pc/cache',
          'state': '${tempDir.path}/webhtv-pc/logs',
        },
      ),
      log: LogService(),
      androidBridgeService: bridge,
      androidReadClient: readClient,
    );
    await state.bootstrap();
  });

  tearDown(() async {
    state.dispose();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  /// 落一条桥接配置记录（不走网络），返回记录 id。
  int seedRecord({
    required String interfaceKey,
    required String name,
    bool makeActive = false,
  }) {
    return state.database!.saveConfig(
      name: name,
      origin: device.reachableBase,
      json: const {'sites': <Object?>[]},
      makeActive: makeActive,
      sourceKey: BridgeSourceKey.of(
        deviceUuid: device.uuid,
        interfaceKey: interfaceKey,
      ),
      bridgeDevice: device.uuid,
      bridgeInterfaceKey: interfaceKey,
      bridgeConfigUrl: 'https://sub.example/$interfaceKey.json',
    );
  }

  void seedHistory({
    required String sourceKey,
    required String vodName,
    required String siteKey,
    int updatedAt = 1000,
  }) {
    state.database!.upsertHistory(
      siteKey: siteKey,
      vodId: 'v-$vodName',
      vodName: vodName,
      flag: '线路一',
      episodeName: '第1集',
      episodeId: 'http://x/$vodName',
      positionMs: 30000,
      durationMs: 100000,
      updatedAt: updatedAt,
      sourceKey: sourceKey,
    );
  }

  group('实时拉取的源归属（用户 2026-10-28：历史页出现「来源未知」）', () {
    /// 把桥接源 A 存成一条记录并设为当前配置（站点 key 用 csp_a）。
    Future<void> activateSourceA() async {
      final id = await state.saveBridgeConfig(
        name: '源 A',
        origin: device.reachableBase,
        config: AppConfig(
          sites: [
            Site(key: 'csp_a', name: '站A', type: 3, api: 'http://x/a'),
          ],
        ),
        diagnostics: const [],
        deviceUuid: device.uuid,
        interfaceKey: 'a',
      );
      expect(id, isNotNull);
      expect(await state.activateConfigRecord(id!), isTrue);
      expect(state.activeSourceKey, 'bridge|dev-uuid-0001|a');
      await state.setHistoryScope(UiHistoryScope.source);
    }

    /// 让实时拉取有设备可指（peer 地址 = 设备网关）。
    Future<void> preparePull() async {
      readClient.items = const [
        SyncHistoryItem(
          siteKey: 'csp_a',
          vodId: '/v/1',
          vodName: '示例剧',
          flag: '线路一',
          episodeName: '第01集',
          episodeId: 'http://x/1',
          positionMs: 1000,
          durationMs: 10000,
          updatedAt: 1700000000000,
        ),
      ];
      await state.syncState.authorizePeer(device);
    }

    test('拉来的进度落在设备当前激活源上，历史页「当前来源」看得到它', () async {
      await activateSourceA();
      await preparePull();

      await state.syncState.manualPullRecentRecords();

      expect(readClient.readCalls, greaterThan(0));
      expect(
        state.database!.recentHistory(sourceKey: 'bridge|dev-uuid-0001|a'),
        hasLength(1),
        reason: '拉来的记录必须带设备当前激活源的标识',
      );
      final visible = state.recentHistory();
      expect(visible, hasLength(1));
      expect(visible.single.sourceKey, 'bridge|dev-uuid-0001|a');
      expect(
        state.historySourceLabel(visible.single.sourceKey),
        isNull,
        reason: '它就是当前源，不该被标成别的源；更不该显示「来源未知」',
      );
    });

    test('归属跟设备当前激活源走，不按站点清单反查', () async {
      await activateSourceA();
      // 设备此刻激活的是 B：同一个站点 key 在 A/B 里都存在（多义），
      // 反查站点清单会拒绝归属，而设备自己说了算。
      bridge.sources = const [
        AndroidSource(interfaceKey: 'a', name: '源 A', url: 'https://s/a.json'),
        AndroidSource(
          interfaceKey: 'b',
          name: '源 B',
          url: 'https://s/b.json',
          active: true,
        ),
      ];
      await preparePull();

      await state.syncState.manualPullRecentRecords();

      expect(
        state.database!.recentHistory(sourceKey: 'bridge|dev-uuid-0001|b'),
        hasLength(1),
      );
      expect(state.recentHistory(), isEmpty, reason: '它属于 B 源，不该出现在 A 源视图');
    });

    test('判不出归属时落空来源：只在「全部来源」里出现，不猜', () async {
      await activateSourceA();
      // 老安卓没有 /manage/configs：拿不到「当前激活的是哪个源」。
      bridge.hasSourceCatalog = false;
      await preparePull();

      await state.syncState.manualPullRecentRecords();

      expect(state.recentHistory(), isEmpty);
      expect(
        state.database!.recentHistory(sourceKey: ''),
        hasLength(1),
        reason: '判不出归属只能落空来源（宁可看不见，也不能串到别的源）',
      );
      await state.setHistoryScope(UiHistoryScope.global);
      expect(state.recentHistory(), hasLength(1));
    });
  });
  group('同一设备多个源各自成记录（不再新增"桥接源"）', () {
    test('两个源生成两条记录，来源标识互不相同且都能被 sourceKey 找到', () async {
      final a = seedRecord(interfaceKey: 'a', name: '源 A');
      final b = seedRecord(interfaceKey: 'b', name: '源 B');

      final records = state.database!.listConfigs();
      expect(records, hasLength(2), reason: '按 origin 去重会把第二个源覆盖掉');
      expect(a, isNot(b));
      expect(
        state.database!.configBySourceKey('bridge|dev-uuid-0001|a')?.id,
        a,
      );
      expect(
        state.database!.configBySourceKey('bridge|dev-uuid-0001|b')?.id,
        b,
      );
    });

    test('重复导入同一个源只更新原记录，不会新增一行', () async {
      final first = seedRecord(interfaceKey: 'a', name: '源 A');
      final second = seedRecord(interfaceKey: 'a', name: '源 A（改名）');

      expect(second, first, reason: '同一个 source_key 必须命中同一行');
      expect(state.database!.listConfigs(), hasLength(1));
      expect(state.database!.listConfigs().single.name, '源 A（改名）');
    });
  });

  group('历史默认按源隔离', () {
    test('切到源 A 只看到源 A 的进度，看不到源 B 的', () async {
      final a = seedRecord(interfaceKey: 'a', name: '源 A');
      seedRecord(interfaceKey: 'b', name: '源 B');
      seedHistory(
        sourceKey: 'bridge|dev-uuid-0001|a',
        vodName: 'A源剧集',
        siteKey: 'csp_a',
      );
      seedHistory(
        sourceKey: 'bridge|dev-uuid-0001|b',
        vodName: 'B源剧集',
        siteKey: 'csp_b',
      );

      await state.activateConfigRecord(a);

      expect(state.activeSourceKey, 'bridge|dev-uuid-0001|a');
      expect(state.historyScope, UiHistoryScope.source, reason: '默认按源隔离');
      expect(
        state.recentHistory().map((item) => item.vodName),
        ['A源剧集'],
        reason: '跨源串进度是本次要修的缺陷',
      );
      // 搜索也必须遵守同一过滤（否则搜索页会翻出别的源的记录）。
      expect(
        state.searchHistory('剧集').map((item) => item.vodName),
        ['A源剧集'],
      );
    });

    test('打开「全部来源」后能同时看到两个源的历史', () async {
      final a = seedRecord(interfaceKey: 'a', name: '源 A');
      seedHistory(
        sourceKey: 'bridge|dev-uuid-0001|a',
        vodName: 'A源剧集',
        siteKey: 'csp_a',
      );
      seedHistory(
        sourceKey: 'bridge|dev-uuid-0001|b',
        vodName: 'B源剧集',
        siteKey: 'csp_b',
      );
      await state.activateConfigRecord(a);

      await state.setHistoryScope(UiHistoryScope.global);

      expect(state.historyScopeIsGlobal, isTrue);
      expect(state.historySourceFilter, '');
      expect(
        state.recentHistory().map((item) => item.vodName).toSet(),
        {'A源剧集', 'B源剧集'},
      );

      // 关回去立刻恢复隔离（开关必须真的可逆）。
      await state.setHistoryScope(UiHistoryScope.source);
      expect(state.recentHistory().map((item) => item.vodName), ['A源剧集']);
    });

    test('全局历史是「读视图」：推送仍然只推当前源', () async {
      final a = seedRecord(interfaceKey: 'a', name: '源 A');
      seedHistory(
        sourceKey: 'bridge|dev-uuid-0001|a',
        vodName: 'A源剧集',
        siteKey: 'csp_a',
      );
      seedHistory(
        sourceKey: 'bridge|dev-uuid-0001|b',
        vodName: 'B源剧集',
        siteKey: 'csp_b',
      );
      await state.activateConfigRecord(a);
      await state.setHistoryScope(UiHistoryScope.global);

      final pushed = state.syncHistoryItems();

      expect(
        pushed.map((item) => item.vodName),
        ['A源剧集'],
        reason: '把别的源的进度推到当前源会在安卓侧写串 cid',
      );
    });

    test('清空历史只清当前源；全局模式下才全清', () async {
      final a = seedRecord(interfaceKey: 'a', name: '源 A');
      seedHistory(
        sourceKey: 'bridge|dev-uuid-0001|a',
        vodName: 'A源剧集',
        siteKey: 'csp_a',
      );
      seedHistory(
        sourceKey: 'bridge|dev-uuid-0001|b',
        vodName: 'B源剧集',
        siteKey: 'csp_b',
      );
      await state.activateConfigRecord(a);

      state.clearHistory();

      expect(state.recentHistory(), isEmpty);
      expect(
        state.database!.recentHistory(sourceKey: 'bridge|dev-uuid-0001|b'),
        hasLength(1),
        reason: '清空当前源不得误删别的源的历史',
      );

      await state.setHistoryScope(UiHistoryScope.global);
      state.clearHistory();
      expect(state.database!.recentHistory(sourceKey: ''), isEmpty);
    });
  });

  group('推送载荷按源', () {
    test('桥接记录发 configKey + 该源自己的订阅地址，绝不用网关地址', () async {
      final a = seedRecord(interfaceKey: 'a', name: '源 A');
      await state.activateConfigRecord(a);
      await state.syncState.authorizePeer(device);

      final payload =
          jsonDecode(state.syncConfigJson()!) as Map<String, Object?>;

      expect(payload['configKey'], 'a');
      expect(payload['url'], 'https://sub.example/a.json');
      expect(
        payload['url'],
        isNot(device.reachableBase),
        reason: '把网关地址当 config.url 会让安卓凭空多出一行「桥接源」',
      );
    });

    test('本地导入的配置沿用老协议（origin 就是订阅地址）', () async {
      final id = state.database!.saveConfig(
        name: '本地源',
        origin: 'https://local.example/sub.json',
        json: const {'sites': <Object?>[]},
        makeActive: true,
      );
      expect(id, greaterThan(0));
      await state.activateConfigRecord(id);
      await state.syncState.authorizePeer(
        const AndroidDevice(
          uuid: 'dev-uuid-0001',
          name: '测试电视',
          reachableBase: 'http://local.example',
        ),
      );

      final payload =
          jsonDecode(state.syncConfigJson()!) as Map<String, Object?>;

      expect(payload.containsKey('configKey'), isFalse);
      expect(payload['url'], 'https://local.example/sub.json');
    });
  });

  group('多源导入', () {
    test('一台设备上的所有源都被拉过来，各自一条记录，且都不切换当前配置', () async {
      bridge.sources = const [
        AndroidSource(
          interfaceKey: 'a',
          name: '源 A',
          url: 'https://sub.example/a.json',
          active: true,
        ),
        AndroidSource(
          interfaceKey: 'b',
          name: '源 B',
          url: 'https://sub.example/b.json',
        ),
      ];

      final before = state.database!.activeConfig()?.id;
      final ok = await state.syncState.importSites(device.reachableBase);

      expect(ok, isTrue);
      expect(state.syncState.lastError, isNull);
      final records = state.database!.listConfigs();
      expect(records, hasLength(2), reason: '多源必须各自成记录');
      expect(
        records.map((item) => item.bridgeInterfaceKey).toSet(),
        {'a', 'b'},
      );
      expect(
        records.map((item) => item.sourceKey).toSet(),
        {'bridge|dev-uuid-0001|a', 'bridge|dev-uuid-0001|b'},
      );
      expect(state.syncState.importRecordIds, hasLength(2));
      expect(
        state.database!.activeConfig()?.id,
        before,
        reason: '导入本身不切换（Q10），切换只能由用户确认',
      );
      expect(bridge.fetchCalls, 2, reason: '每个源各取一次站点清单');
    });

    test('老安卓没有 /manage/configs 时降级为只导入当前激活源', () async {
      bridge.hasSourceCatalog = false;

      final ok = await state.syncState.importSites(device.reachableBase);

      expect(ok, isTrue, reason: '缺少配置清单不能让整条导入失败');
      expect(state.database!.listConfigs(), hasLength(1));
      expect(state.syncState.importRecordIds, hasLength(1));
    });

    test('指定 interfaceKey 时只重拉那一个源', () async {
      bridge.sources = const [
        AndroidSource(interfaceKey: 'a', name: '源 A', url: 'https://s/a.json'),
        AndroidSource(interfaceKey: 'b', name: '源 B', url: 'https://s/b.json'),
      ];

      final ok = await state.syncState.importSites(
        device.reachableBase,
        interfaceKey: 'b',
      );

      expect(ok, isTrue);
      final records = state.database!.listConfigs();
      expect(records, hasLength(1));
      expect(records.single.bridgeInterfaceKey, 'b');
      expect(bridge.fetchCalls, 1);
    });

    test('设备上找不到指定源时明确报错，不静默成功', () async {
      bridge.sources = const [
        AndroidSource(interfaceKey: 'a', name: '源 A', url: 'https://s/a.json'),
      ];

      final ok = await state.syncState.importSites(
        device.reachableBase,
        interfaceKey: 'missing',
      );

      expect(ok, isFalse);
      expect(state.syncState.lastError?.kind, AppErrorKind.bridgeUnreachable);
      expect(state.database!.listConfigs(), isEmpty);
    });
  });
}
