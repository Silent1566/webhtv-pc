/// Phase 4 · 真实壳层 TMDB 入口端到端（发布包缺陷 P4-7 的 AOT 回归）。
///
/// 背景：正式版 exe 曾经**完全没有** TMDB 设置与效果。根因是
/// `TmdbState.shouldRender` 把「未配置」也判为「不渲染」，`TmdbStatusBar`
/// 直接 `SizedBox.shrink()`，而全应用唯一引用 `TmdbSettingsPage` 的就是
/// 状态条上那个从未渲染的 `onConfigure` 回调 → 该页被 release AOT 整体剔除。
///
/// 本用例在**真实 `AppShell`**（非直接构造组件）里走完整交互路径：
///   1. 进入「设置」页签；
///   2. 断言 TMDB 入口存在（全新安装、无凭据）；
///   3. 点击入口，断言真正进入 TMDB 设置页并渲染出关键控件。
///
/// 该路径在 debug 与 profile(AOT) 下都必须通过；配合
/// `tools/phase4/verify_release_symbols.py` 构成「运行期 + 产物」双重门禁。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/app.dart';

void evidence(String message) =>
    debugPrint('PHASE4-EVIDENCE tmdb-shell-entry $message');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('真实壳层：设置页 → 打开 TMDB 设置（未配置仍可达）', (tester) async {
    final temp = Directory.systemTemp.createTempSync('webhtv-tmdb-shell');
    final paths = AppPaths.resolve(
      overrides: {'roaming': temp.path, 'local': temp.path},
    );
    final state = AppState(paths: paths, log: LogService());
    addTearDown(() {
      state.dispose();
      try {
        temp.deleteSync(recursive: true);
      } catch (_) {}
    });
    await state.bootstrap();

    // 前置：全新安装，没有凭据。
    expect(
      state.tmdbConfig.isReady,
      isFalse,
      reason: '前置条件：未配置 TMDB',
    );

    tester.view.physicalSize = const Size(1600, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      MaterialApp(home: AppShell(state: state, startup: const StartupArguments())),
    );
    // 壳层要先完成边界确认读取（真实文件 I/O）。
    for (var i = 0; i < 60; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      if (find.byType(NavigationRail).evaluate().isNotEmpty) break;
    }
    expect(
      find.byType(NavigationRail),
      findsOneWidget,
      reason: '壳层侧栏未渲染',
    );

    // 若首次启动的边界提示存在，先确认（否则它会遮挡交互）。
    final accept = find.text('我已了解并同意');
    if (accept.evaluate().isNotEmpty) {
      await tester.tap(accept);
      await tester.pumpAndSettle();
      evidence('boundary=accepted');
    } else {
      evidence('boundary=already-accepted');
    }

    // 1) 进入「设置」页签。
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    evidence('section=settings');

    // 2) 未配置时入口必须存在。
    final entry = find.byKey(const ValueKey('settings-tmdb-open'));
    expect(
      entry,
      findsOneWidget,
      reason: '设置页必须有无条件可见的 TMDB 入口（P4-7 回归）',
    );
    evidence('settings-entry=present');

    // 3) 点击入口 → 真正进入 TMDB 设置页。
    await tester.tap(entry);
    await tester.pumpAndSettle();

    expect(find.text('TMDB 设置'), findsOneWidget, reason: '未进入 TMDB 设置页');
    expect(find.byKey(const ValueKey('tmdb-enabled')), findsOneWidget);
    expect(find.byKey(const ValueKey('tmdb-api-key')), findsOneWidget);
    expect(find.byKey(const ValueKey('tmdb-access-token')), findsOneWidget);
    evidence(
      'tmdb-settings=rendered keys=enabled,api-key,access-token',
    );
  });
}
