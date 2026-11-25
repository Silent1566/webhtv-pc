/// 已连接安卓环境 MVP · 设置页（新建分区）契约。
///
/// 真 widget + 真 AppState；ADB/SDK 只在进程与 socket 边界上换夹具，
/// 用例里不执行任何真实 ADB/设备/模拟器命令。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/android_adb_profile.dart';
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/services/android_adb_runtime.dart';
import 'package:webhtv_pc/services/android_bridge_service.dart';
import 'package:webhtv_pc/services/android_connection_store.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/config_pages.dart';

import 'android_adb_runtime_fixtures.dart';
import 'support/temp_dirs.dart';

/// 手写的已保存连接描述（version1，不含任何本机转发端口）。
const Map<String, Object?> _savedProfileJson = {
  'version': 1,
  'mode': 'network',
  'target': '192.168.50.3:5555',
  'adbPath': '',
  'emulatorPath': '',
  'avdHome': '',
  'serverPort': 5037,
  'gatewayPort': 9978,
};

void main() {
  late Directory tempDir;
  late LogService log;
  late FakeProcessHost processes;
  late AndroidAdbRuntime runtime;
  late AppState state;

  Future<void> boot({
    List<Map<String, Object?>> savedRecords = const [],
  }) async {
    final configDir = Directory('${tempDir.path}/webhtv-pc');
    configDir.createSync(recursive: true);
    if (savedRecords.isNotEmpty) {
      File(
        '${configDir.path}/$androidConnectionsFileName',
      ).writeAsStringSync(jsonEncode({'version': 1, 'records': savedRecords}));
    }
    state = AppState(
      paths: AppPaths.resolve(
        overrides: {
          'config': configDir.path,
          'data': configDir.path,
          'cache': '${configDir.path}/cache',
          'state': '${configDir.path}/logs',
        },
      ),
      log: log,
      androidBridgeService: AndroidBridgeService(log: log),
      androidAdbRuntime: runtime,
    );
    await state.bootstrap();
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('webhtv-adb-settings');
    log = LogService();
    processes = FakeProcessHost();
    runtime = AndroidAdbRuntime(
      bridge: AndroidBridgeService(log: log),
      log: log,
      processes: processes,
    );
  });

  tearDown(() async {
    state.dispose();
    await deleteTempDirBestEffort(tempDir);
  });

  Future<void> openPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 4200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(home: AndroidSettingsPage(state: state)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('渲染已连接环境分区与它的键，老控件仍在', (tester) async {
    await tester.runAsync(boot);
    await openPage(tester);

    expect(find.byKey(const ValueKey('android-bridge')), findsOneWidget);
    // 新分区：模式/目标/可选 SDK 路径/列表按钮/连接按钮。
    expect(find.byKey(const ValueKey('android-adb-mode')), findsOneWidget);
    expect(find.byKey(const ValueKey('android-adb-target')), findsOneWidget);
    expect(find.byKey(const ValueKey('android-adb-path')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('android-adb-list-devices')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('android-adb-list-avds')), findsOneWidget);
    expect(find.byKey(const ValueKey('android-adb-connect')), findsOneWidget);
    expect(find.text('还没有保存的安卓环境。'), findsOneWidget);

    // 既有控件不能被顶掉或改名。
    expect(find.byKey(const ValueKey('android-device-input')), findsOneWidget);
    expect(find.byKey(const ValueKey('android-device-add')), findsOneWidget);
    expect(find.byKey(const ValueKey('android-scan')), findsOneWidget);
    expect(find.text('最近接入'), findsOneWidget);
  });

  testWidgets('列出已保存环境：重连与忘记按钮都在，且显示描述', (tester) async {
    await tester.runAsync(
      () => boot(
        savedRecords: [
          {
            'profile': _savedProfileJson,
            'deviceUuid': 'uuid-saved-0001',
            'name': '客厅电视',
            'lastUsedMs': 1700000000000,
          },
        ],
      ),
    );
    final key = AndroidAdbProfile.fromJson(_savedProfileJson)!.connectionKey;

    await openPage(tester);

    expect(find.byKey(ValueKey('android-adb-saved-$key')), findsOneWidget);
    expect(
      find.byKey(ValueKey('android-adb-saved-reconnect-$key')),
      findsOneWidget,
    );
    expect(
      find.byKey(ValueKey('android-adb-saved-forget-$key')),
      findsOneWidget,
    );
    expect(find.textContaining('192.168.50.3:5555'), findsWidgets);
    expect(find.byKey(const ValueKey('android-adb-error')), findsNothing);
  });

  testWidgets('AVD 模式才出现模拟器/AVD 目录输入框', (tester) async {
    await tester.runAsync(boot);
    await openPage(tester);

    expect(
      find.byKey(const ValueKey('android-adb-emulator-path')),
      findsNothing,
    );

    await tester.tap(find.text('已有 AVD'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('android-adb-emulator-path')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('android-adb-avd-home')), findsOneWidget);
  });

  testWidgets('连接失败：页面本地错误卡带运行时原因，不占用同步错误卡', (tester) async {
    await tester.runAsync(boot);
    await openPage(tester);

    // 运行时已关闭：连接立即失败，不产生任何真实进程/socket。
    await tester.runAsync(runtime.close);
    await tester.enterText(
      find.byKey(const ValueKey('android-adb-target')),
      '10.0.2.2:5555',
    );
    await tester.tap(find.byKey(const ValueKey('android-adb-connect')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('android-adb-error')), findsOneWidget);
    expect(find.textContaining('ADB 运行时已关闭'), findsOneWidget);
    expect(
      find.textContaining('类别：${AppErrorKind.bridgeUnreachable.name}'),
      findsOneWidget,
    );
    // 同步自己的错误卡不得被挪用。
    expect(find.byKey(const ValueKey('android-error')), findsNothing);
  });

  testWidgets('目标格式非法：同样落在页面本地错误卡', (tester) async {
    await tester.runAsync(boot);
    await openPage(tester);

    await tester.enterText(
      find.byKey(const ValueKey('android-adb-target')),
      'http://192.168.50.3:9978',
    );
    await tester.tap(find.byKey(const ValueKey('android-adb-connect')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('android-adb-error')), findsOneWidget);
    expect(find.textContaining('不是 HTTP 网关地址'), findsOneWidget);
  });
}
