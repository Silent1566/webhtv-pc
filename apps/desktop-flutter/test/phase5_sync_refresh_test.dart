/// 设置页「安卓接入」状态必须反映真实接入情况（用户反馈 2026-10-09）。
///
/// 缺陷现象：重新打开应用后顶栏已显示「配置：安卓桥接 (127.0.0.1)」（配置确实
/// 恢复了），但设置页的「安卓接入」一行仍写着「未接入：可扫描局域网，或手动
/// 输入安卓设备地址」。
///
/// 实测证据（用户 `settings.json` + 运行日志）：
/// - `sync.peers` 有 1 台（`vivo V1923A @ http://127.0.0.1:19978`，已落盘）；
/// - `sync.devices` / `sync.deviceHistory` **为空**；
/// - 日志里 `devices=0`、且**从未出现过**「尝试自动接入」——因为历史为空时
///   自动接入本来就该安静跳过（不是缺陷）。
///
/// 因此本文件锁定**两个**真实缺陷：
///
/// 1. **状态不刷新**：`SettingsPage` 是 `StatelessWidget`，只读 `state.syncState`
///    但自身不监听；它靠上层（`AppShell`）监听 `AppState` 后重建。而 `AppState`
///    从未订阅 `syncState`，于是接入状态变化（如探测/授权/自动接入完成）不会
///    触发任何重建。对照：`AndroidSettingsPage` 自己 `addListener`，所以它显示
///    正确——正是这个差异暴露了缺口。
/// 2. **摘要只看内存态**：原摘要依据 `sync.devices`，而它是**内存态**，
///    `load()` 只恢复 `deviceHistory`/`peers`，从不恢复它。重启后即使已接入过
///    （甚至已授权对端、配置已恢复为桥接），摘要仍永远写「未接入」。
///    修法：取 `devices ∪ deviceHistory ∪ peers` 的地址并集。
///
/// 装配注意（踩过多次，务必保留）：
/// - 真实 I/O（`createTemp`、`bootstrap`、`probe`）必须放在 `setUp` 或
///   `tester.runAsync` 里。`testWidgets` 是 fake-async binding，测试体里直接
///   `await` 真实文件/DB I/O 会**永久挂起**（现象 `Test timed out`）。
/// - 收敛循环**不能用 `pumpAndSettle`**：加载态含无限动画，会撞 10 分钟默认超时。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:webhtv_pc/core/android_bridge.dart';
import 'package:webhtv_pc/core/http_api.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/android_bridge_service.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/sync_client.dart';
import 'package:webhtv_pc/services/sync_server.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/diagnostics_pages.dart';

/// 假桥接：探测必定成功、导入返回固定配置，不碰网络。
class _FakeBridge extends AndroidBridgeService {
  _FakeBridge() : super(log: LogService());

  static const AndroidDevice device = AndroidDevice(
    uuid: 'fake-android-uuid',
    name: '测试安卓设备',
    reachableBase: 'http://192.168.50.9:9978',
    reportedIp: 'http://172.16.1.4:9978',
    type: 1,
  );

  @override
  Future<AndroidDevice> probeDevice(String base) async => device;

  @override
  Future<BridgeConversion> fetchGatewayConfig(
    String base, {
    String? selfBase,
    void Function(BridgeStage stage)? onStage,
  }) async {
    onStage?.call(BridgeStage.converting);
    return BridgeConversion(
      config: AppConfig(
        name: '安卓桥接（fixture）',
        sites: [
          Site(
            key: 'bridge_site',
            name: '桥接站点',
            type: SiteType.jsonApiBase64Ext,
            api: 'http://192.168.50.9:9978/vod/api?key=bridge_site',
          ),
        ],
      ),
    );
  }
}

/// 不发请求的客户端（本用例不涉及同步网络）。
class _NoNetworkClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    throw StateError('本用例不应发起同步请求：${request.url}');
  }
}

/// 交替「推进一帧 → 给真实 I/O 一点时间」，有界收敛（不用 `pumpAndSettle`）。
Future<void> _settle(WidgetTester tester, {int rounds = 20}) async {
  for (var round = 0; round < rounds; round++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 8)),
    );
  }
  await tester.pump(const Duration(milliseconds: 16));
}

void main() {
  late Directory tempDir;
  late AppPaths paths;

  /// 全新实例（未接入过任何设备）。
  late AppState fresh;

  /// 「重启后」的实例：同一数据目录，已授权对端（持久化）但内存设备列表为空。
  late AppState reopened;

  AppState buildState() => AppState(
    paths: paths,
    log: LogService(),
    androidBridgeService: _FakeBridge(),
    syncClient: SyncClient(log: LogService(), client: _NoNetworkClient()),
    // 固定回环 + 测试端口区间：不占 9978，也不碰局域网。
    syncServerFactory: (host) => SyncServer(
      log: LogService(),
      host: host,
      bindAddress: '127.0.0.1',
      lanIpOverride: '127.0.0.1',
      startPort: 18720,
      endPort: 18730,
    ),
  );

  setUp(() async {
    // `setUp` 不在 fake-async 区内，真实 I/O 可以正常 await 完成。
    tempDir = await Directory.systemTemp.createTemp('webhtv-sync-refresh');
    paths = AppPaths.resolve(
      overrides: {'roaming': tempDir.path, 'local': tempDir.path},
    );

    // 1) 全新实例（未接入）。
    fresh = buildState();
    await fresh.bootstrap();

    // 2) 制造「上次接入过」的持久化证据：接入一台设备 → 落盘。
    final seeder = buildState();
    await seeder.bootstrap();
    final device = await seeder.syncState.probe('192.168.50.9:9978');
    expect(device, isNotNull, reason: '前置条件：假桥接探测应成功');
    await seeder.syncState.authorizePeer(device!);
    expect(seeder.syncState.peers, isNotEmpty, reason: '前置条件：对端应已落盘');
    seeder.dispose();

    // 3) 「重启」：同一数据目录重新打开。
    reopened = buildState();
    await reopened.bootstrap();
  });

  tearDown(() async {
    fresh.dispose();
    reopened.dispose();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  /// 挂载设置页，并在上层放一个监听 `AppState` 的重建器。
  ///
  /// 这正是真实应用的装配：`AppShell` 监听 `AppState`，状态变化时 `setState`
  /// 重建内容区，从而让 `SettingsPage`（`StatelessWidget`）重新读取 `syncState`。
  /// 因此本 harness 复现的是产品结构，而不是为测试特制的东西。
  Future<void> mountSettings(WidgetTester tester, AppState state) async {
    tester.view.physicalSize = const Size(1280, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: ListenableBuilder(
          listenable: state,
          builder: (context, child) => Scaffold(body: SettingsPage(state: state)),
        ),
      ),
    );
    await tester.pump();
  }

  String summaryOf(WidgetTester tester) =>
      tester
          .widget<Text>(find.byKey(const ValueKey('settings-android-summary')))
          .data ??
      '';

  testWidgets('AppState 转发 syncState 通知：接入后设置页自动刷新', (tester) async {
    expect(fresh.syncState.devices, isEmpty);
    expect(fresh.syncState.deviceHistory, isEmpty);
    expect(fresh.syncState.peers, isEmpty);

    await mountSettings(tester, fresh);
    expect(
      summaryOf(tester),
      contains('未接入'),
      reason: '前置条件：初始应显示「未接入」',
    );

    // 关键：这一行必须真的会重建。用 AppState 的监听计数直接锁定转发关系
    // ——若 AppState 不转发 syncState 的通知，下面的计数永远为 0。
    var appStateNotifications = 0;
    fresh.addListener(() => appStateNotifications++);

    // 模拟「用户接入一台设备」（探测成功 → 授权为对端）。
    // 两步都会在 SyncState 上 notifyListeners()。
    final device = await tester.runAsync(
      () => fresh.syncState.probe('192.168.50.9:9978'),
    );
    expect(device, isNotNull, reason: '假桥接探测应成功');
    await tester.runAsync(() => fresh.syncState.authorizePeer(device!));

    expect(
      appStateNotifications,
      greaterThan(0),
      reason: 'AppState 必须转发 syncState 的通知（否则设置页永远不刷新）',
    );

    await _settle(tester);
    expect(
      summaryOf(tester),
      contains('已接入'),
      reason: '接入完成后设置页必须显示「已接入」（缺陷 1：不刷新）',
    );
  });

  testWidgets('摘要基于持久化证据：重启后仍显示「已接入」（缺陷 2）', (tester) async {
    expect(
      reopened.syncState.devices,
      isEmpty,
      reason: '前置条件：重启后内存态设备列表必为空（这正是原缺陷的成因）',
    );
    expect(
      reopened.syncState.peers,
      isNotEmpty,
      reason: '前置条件：已授权对端应从磁盘恢复',
    );

    await mountSettings(tester, reopened);

    expect(
      summaryOf(tester),
      contains('已接入'),
      reason: '重启后必须仍显示「已接入」——原实现只看内存态 devices，'
          '即使已授权对端也永远写「未接入」（用户反馈的缺陷点）',
    );
  });

  testWidgets('移除转发后 syncState 的通知不再到达 AppState 监听者', (tester) async {
    var notifications = 0;
    reopened.addListener(() => notifications++);
    // 模拟 dispose 时的摘除（dispose 里会先 removeListener 再 dispose）。
    reopened.syncState.removeListener(reopened.notifyListeners);

    reopened.syncState.clearMessages();
    expect(notifications, 0, reason: '移除转发后不应再有通知');
  });
}
