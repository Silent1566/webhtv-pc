/// 推送接收的设置页入口（W3）。
///
/// 对应计划 `docs/superpowers/plans/2026-11-20-push-receive-and-title.md` 的开关模型：
/// 局域网服务总开关 + 「接收推送播放」子开关，两者默认都关闭；开推送会自动拉起
/// 服务，关服务会把推送一并落下去（由 `SyncState` 负责，页面只读状态）。
///
/// 两条测试环境约束（与 `phase5_sync_ui_test.dart` 同口径）：
/// 1. 注入的服务端只绑定回环 + 测试端口段，widget 测试**不做**真实局域网 I/O；
/// 2. 真实 socket/文件 I/O 必须靠 `tester.runAsync` 推进——`testWidgets` 用的是
///    假时钟，真实 I/O 的完成回调不会被 `pumpAndSettle` 推进。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/sync_server.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/config_pages.dart';

void main() {
  late Directory tempDir;
  late AppState state;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('webhtv-push-settings');
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
      // 固定到回环 + 测试端口区间：不占 9978，也不碰局域网。
      syncServerFactory: (host) => SyncServer(
        log: LogService(),
        host: host,
        bindAddress: '127.0.0.1',
        lanIpOverride: '127.0.0.1',
        startPort: 18800,
        endPort: 18810,
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
    // 放大视口：设置页是长 `ListView`，默认 800×600 下靠后的控件不会被构建。
    tester.view.physicalSize = const Size(1200, 4200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(home: AndroidSettingsPage(state: state)),
    );
    await tester.pumpAndSettle();
  }

  /// 交替「推进一帧 → 给真实 I/O 一点时间」，直到 UI 收敛。
  Future<void> settleIo(WidgetTester tester, {int rounds = 90}) async {
    for (var round = 0; round < rounds; round++) {
      await tester.pump(const Duration(milliseconds: 16));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 16)),
      );
    }
    await tester.pumpAndSettle();
  }

  /// 点一个会触发**真实 I/O** 的控件并等它落地。
  Future<void> tapIo(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await settleIo(tester);
  }

  /// 开启局域网服务总开关（必须先过确认框，P3）。
  Future<void> enableServer(WidgetTester tester) async {
    await tapIo(tester, find.byKey(const ValueKey('android-sync-server')));
    expect(find.text('开启局域网同步服务'), findsOneWidget);
    await tapIo(tester, find.text('开启'));
    expect(state.syncState.serverRunning, isTrue, reason: '确认后服务应真正监听');
  }

  /// 收尾：停掉真实监听。
  ///
  /// 不停会被 flutter_test 判「A Timer is still pending」——HttpServer 的
  /// idleTimeout 定时器活在测试 zone 里，widget 树 dispose 后它依然存活。
  Future<void> stopServer(WidgetTester tester) async {
    await tester.runAsync(() => state.syncState.setServerEnabled(false));
    await tester.pumpAndSettle();
  }

  bool receivePushTileValue(WidgetTester tester) => tester
      .widget<SwitchListTile>(find.byKey(const ValueKey('android-receive-push')))
      .value;

  group('接收推送开关（W3）', () {
    testWidgets('默认关闭，且不显示推送页地址', (tester) async {
      await openPage(tester);
      expect(find.text('接收推送播放'), findsOneWidget);
      expect(receivePushTileValue(tester), isFalse);
      expect(state.syncState.receivePushEnabled, isFalse);
      expect(find.byKey(const ValueKey('receive-push-url')), findsNothing);
      expect(find.byKey(const ValueKey('receive-push-copy')), findsNothing);
    });

    testWidgets('打开开关后状态为真并展示推送页地址', (tester) async {
      await openPage(tester);
      await tapIo(tester, find.byKey(const ValueKey('android-receive-push')));
      expect(state.syncState.receivePushEnabled, isTrue);
      expect(receivePushTileValue(tester), isTrue);

      final address = find.byKey(const ValueKey('receive-push-url'));
      expect(address, findsOneWidget, reason: '开启后必须给出手机要打开的地址');
      final text = tester.widget<SelectableText>(address).data;
      expect(text, startsWith('http://127.0.0.1:'));
      expect(text, endsWith('/'));
      expect(find.textContaining('Windows 防火墙'), findsOneWidget);
      await stopServer(tester);
    });

    testWidgets('关闭服务开关后接收推送回落、地址消失', (tester) async {
      await openPage(tester);
      await enableServer(tester);
      await tapIo(tester, find.byKey(const ValueKey('android-receive-push')));
      expect(state.syncState.receivePushEnabled, isTrue);
      expect(find.byKey(const ValueKey('receive-push-url')), findsOneWidget);

      // 关服务不需要确认框，但会真正 stop 掉端口（真实 I/O）。
      await tapIo(tester, find.byKey(const ValueKey('android-sync-server')));
      expect(state.syncState.serverRunning, isFalse);
      expect(state.syncState.receivePushEnabled, isFalse);
      expect(receivePushTileValue(tester), isFalse, reason: 'UI 只读状态，必须跟着回落');
      expect(find.byKey(const ValueKey('receive-push-url')), findsNothing);
    });

    testWidgets('地址行带复制按钮，点击不抛错', (tester) async {
      await openPage(tester);
      await tapIo(tester, find.byKey(const ValueKey('android-receive-push')));
      final copy = find.byKey(const ValueKey('receive-push-copy'));
      expect(copy, findsOneWidget);
      await tester.ensureVisible(copy);
      await tester.tap(copy);
      await tester.pump();
      expect(tester.takeException(), isNull);
      await stopServer(tester);
    });
  });
}
