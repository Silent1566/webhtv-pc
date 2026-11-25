import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/app.dart';
import 'package:webhtv_pc/ui/startup_arguments.dart';

import 'android_pc_config_execution_fixtures.dart';

void main() {
  late PcExecutionFixture f;
  late AppState restarted;
  bool closed = false;
  setUp(() async {
    final root = Directory(
      '../../.superpowers/sdd/2026-11-24-pc-config-android-execution/state-ui/startup-fixture',
    );
    if (root.existsSync()) root.deleteSync(recursive: true);
    root.createSync(recursive: true);
    f = PcExecutionFixture(root);
    await f.boot();
    await f.state.runConfigOnAndroid(f.recordId, f.profile.connectionKey);
    f.state.dispose();
    await f.state.androidExecutionShutdown;
    // New state/publisher; borrowed reverse state was released by the previous owner.
    f.runtime = f.newRuntime();
    restarted = AppState(
      paths: f.paths,
      log: LogService(),
      androidAdbRuntime: f.runtime,
      androidBridgeService: f.bridge,
      androidExecutionStore: f.store,
      httpClient: f.client,
      warmAutoRoutes: false,
    );
    await restarted.bootstrap();
  });
  tearDown(() async {
    if (!closed) {
      restarted.dispose();
      await restarted.androidExecutionShutdown;
    }

    if (f.root.existsSync()) f.root.deleteSync(recursive: true);
  });
  testWidgets(
    'startup prepares selected original binding before browsing or desktop JAR probes',
    (tester) async {
      expect(restarted.config!.sites.first.type, 3);
      expect(
        restarted.siteService,
        isNull,
        reason: 'selected but unprepared execution cannot silently use PC',
      );
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: AppShell(state: restarted, startup: const StartupArguments()),
        ),
      );
      for (var i = 0; i < 100; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 16));
        if (restarted.siteService != null) break;
      }
      expect(
        restarted.siteService,
        isNotNull,
        reason: restarted.lastError?.logLine,
      );
      expect(restarted.effectiveConfig!.sites.first.type, 4);
      expect(f.copies, hasLength(1));
      expect(f.imports.toSet(), hasLength(1));
      expect(restarted.activeSourceKey, pcExecutionSource);
      expect(restarted.savedConfigs.single.json, pcExecutionRaw);
      expect(f.requests.where((url) => url.path.endsWith('.jar')), isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        restarted.dispose();
        closed = true;
        await restarted.androidExecutionShutdown;
      });
    },
  );
}
