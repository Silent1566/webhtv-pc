import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/ui/config_pages.dart';

import 'android_pc_config_execution_fixtures.dart';

void main() {
  late PcExecutionFixture f;
  setUp(() async {
    final root = Directory(
      '../../.superpowers/sdd/2026-11-24-pc-config-android-execution/state-ui/settings-fixture',
    );
    if (root.existsSync()) root.deleteSync(recursive: true);
    root.createSync(recursive: true);
    f = PcExecutionFixture(root);
    await f.boot();
  });
  tearDown(() => f.close());

  testWidgets('execution menu accepts decoded JSON with HTML transport MIME', (
    tester,
  ) async {
    final record = f.state.savedConfigs.firstWhere((r) => r.id == f.recordId);
    f.state.database!.saveConfig(
      name: record.name,
      origin: record.origin,
      json: record.json,
      sourceKey: record.sourceKey,
      contentType: 'text/html; charset=utf-8',
      siteCount: record.siteCount,
      makeActive: false,
    );
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: ConfigPage(state: f.state)));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(ValueKey('config-menu-${f.recordId}')),
    );
    await tester.pumpAndSettle();
    expect(find.text('在安卓环境运行此配置'), findsOneWidget);
    await tester.tap(find.text('在安卓环境运行此配置'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('config-android-execution-dialog')),
      findsOneWidget,
    );
    expect(f.state.savedConfigs.single.contentType, 'text/html; charset=utf-8');
  });
  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: ConfigPage(state: f.state)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('config-menu-${f.recordId}')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('在安卓环境运行此配置'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'more menu opens actual execution picker with PC default, environment and explicit safety copy',
    (tester) async {
      await open(tester);
      expect(
        find.byKey(const ValueKey('config-android-execution-dialog')),
        findsOneWidget,
      );
      expect(find.textContaining('桌面运行'), findsWidgets);
      expect(find.textContaining('已保存测试环境'), findsOneWidget);
      expect(find.textContaining('不切换安卓当前配置'), findsOneWidget);
      expect(find.textContaining('本地 JAR'), findsOneWidget);
    },
  );
  testWidgets('empty saved profiles show next step and disable prepare', (
    tester,
  ) async {
    await tester.runAsync(
      () => f.state.forgetAndroidConnection(f.profile.connectionKey),
    );
    await open(tester);
    expect(find.textContaining('先到安卓设备接入连接环境'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('config-android-execution-prepare')),
          )
          .onPressed,
      isNull,
    );
  });
  testWidgets(
    'busy prepare disables actions and missing keys show local error not false availability',
    (tester) async {
      f.importGate = Completer<void>();
      f.missingKey = true;
      await open(tester);
      await tester.tap(find.textContaining('已保存测试环境'));
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('config-android-execution-prepare')),
      );
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('config-android-execution-prepare')),
            )
            .onPressed,
        isNull,
      );
      f.importGate!.complete();
      for (var i = 0; i < 50; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(
        find.byKey(const ValueKey('config-android-execution-error')),
        findsOneWidget,
      );
      expect(
        f.state.androidExecutionForRecord(f.state.savedConfigs.single),
        isNull,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(f.close);
    },
  );
}
