/// 多源导入后的「选一个源来切换」选择框。
///
/// ## 为什么单开一个文件
///
/// `phase5_sync_ui_test.dart` 的 `FakeBridge` 默认只返回**一个**源，
/// 多源路径若混进去，那个文件的每个用例都要先说清"我这台设备有几个源"。
/// 这里用 `support/fake_sources_bridge.dart`（默认两个源）单独覆盖：
///
/// 1. 一台设备多个源时弹**选择框**，而不是静默挑一个或直接切换；
/// 2. 选中某个源才切换，且切到的是**选中的那个**；
/// 3. 选「先不切换」保持当前配置（沿用 Q10：导入本身不切换）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/sync_client.dart';
import 'package:webhtv_pc/services/sync_server.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/config_pages.dart';

import 'support/fake_sources_bridge.dart';

/// 记录请求但永不真正发出的假 client（推送用例不需要，仅为构造注入）。
class _QuietClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(Stream<List<int>>.value(utf8.encode('OK')), 200);
}

void main() {
  late Directory tempDir;
  late AppState state;
  late FakeSourcesBridge bridge;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('webhtv-source-picker');
    bridge = FakeSourcesBridge();
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
      syncClient: SyncClient(log: LogService(), client: _QuietClient()),
      syncServerFactory: (host) => SyncServer(
        log: LogService(),
        host: host,
        bindAddress: '127.0.0.1',
        lanIpOverride: '127.0.0.1',
        startPort: 18720,
        endPort: 18730,
      ),
    );
    await state.bootstrap();
  });

  tearDown(() async {
    state.dispose();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  Future<void> openPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 4200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: AndroidSettingsPage(state: state)));
    await tester.pumpAndSettle();
  }

  /// 推进一帧 → 放行真实 I/O，循环到 UI 收敛（同 `phase5_sync_ui_test`）。
  Future<void> settleIo(WidgetTester tester, {int rounds = 90}) async {
    for (var round = 0; round < rounds; round++) {
      await tester.pump(const Duration(milliseconds: 16));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 16)),
      );
    }
    await tester.pumpAndSettle();
  }

  Future<void> tapIo(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await settleIo(tester);
  }

  Future<void> importFromDevice(WidgetTester tester) async {
    await tester.enterText(
      find.byKey(const ValueKey('android-device-input')),
      '192.168.50.9:9978',
    );
    await tapIo(tester, find.text('接入设备'));
    await tapIo(tester, find.byKey(const ValueKey('android-import')));
  }

  testWidgets('多个源时弹选择框，列出设备上的每个播放源', (tester) async {
    await openPage(tester);
    await importFromDevice(tester);

    expect(
      find.byKey(const ValueKey('bridge-source-picker')),
      findsOneWidget,
      reason: '多源时不能静默挑一个，也不能直接切走',
    );
    final records = state.database!.listConfigs();
    expect(records, hasLength(2), reason: '前置条件：两个源各落一条记录');
    for (final record in records) {
      expect(
        find.byKey(ValueKey('bridge-source-pick-${record.id}')),
        findsOneWidget,
        reason: '每个源都必须在选择框里可选',
      );
    }
    expect(
      state.activeRecord,
      isNull,
      reason: '选择框还开着时不得已经切换',
    );
  });

  testWidgets('选中某个源才切换，且切到的是选中的那个', (tester) async {
    await openPage(tester);
    await importFromDevice(tester);

    final records = state.database!.listConfigs();
    // 故意选**第二条**（源 B）：如果实现只会切"第一条"，这条会红。
    final target = records.firstWhere(
      (item) => item.bridgeInterfaceKey == 'b',
    );
    await tapIo(
      tester,
      find.byKey(ValueKey('bridge-source-pick-${target.id}')),
    );

    // 选完源之后还有一次"是否切换"确认，确认才真正切换。
    await tapIo(
      tester,
      find.byKey(const ValueKey('bridge-switch-confirm-ok')),
    );

    expect(state.activeRecord?.id, target.id);
    expect(state.activeRecord?.bridgeInterfaceKey, 'b');
  });

  testWidgets('选择框点「先不切换」→ 当前配置保持不变', (tester) async {
    await openPage(tester);
    final before = state.activeRecord?.id;

    await importFromDevice(tester);
    expect(
      find.byKey(const ValueKey('bridge-source-picker')),
      findsOneWidget,
    );
    await tapIo(
      tester,
      find.byKey(const ValueKey('bridge-source-pick-later')),
    );

    expect(state.activeRecord?.id, before);
    expect(state.database!.listConfigs(), hasLength(2),
        reason: '导入本身仍要落库，只是不切换');
    expect(
      find.byKey(const ValueKey('bridge-switch-confirm')),
      findsNothing,
    );
  });
}
