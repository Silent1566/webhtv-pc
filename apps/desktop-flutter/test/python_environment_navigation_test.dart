/// 运行环境设置页的真实入口（任务书 Task C）。
///
/// 从**真实** [SettingsPage] 的「维护与说明 → 工具」进入，验证：
/// - 入口 key 稳定、点击真的推入 [PythonEnvironmentPage]；
/// - 返回后仍停在「维护与说明」分类（分类是页面自己的 UI 状态，不该被导航重置）；
/// - 全流程目录与日志都在 `Directory.systemTemp`，绝不写 `%APPDATA%`。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/diagnostics_pages.dart';
import 'package:webhtv_pc/ui/python_environment_page.dart';
import 'package:webhtv_pc/ui/theme.dart';

void main() {
  late Directory temp;
  late AppState state;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('webhtv_python_nav_');
    LogService.logDirectoryOverride = '${temp.path}\\logs';
    final paths = AppPaths.resolve(
      overrides: {'roaming': temp.path, 'local': temp.path},
    );
    state = AppState(paths: paths, log: LogService());
    await state.bootstrap();
  });

  tearDown(() {
    state.dispose();
    LogService.logDirectoryOverride = null;
    if (temp.existsSync()) {
      try {
        temp.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  testWidgets('维护与说明里的真实入口打开运行环境页，返回后仍在该分类', (tester) async {
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.dark),
        home: ListenableBuilder(
          listenable: state,
          builder: (context, child) =>
              Scaffold(body: SettingsPage(state: state)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('settings-category-maintenance')),
    );
    await tester.pumpAndSettle();

    final entry = find.byKey(
      const ValueKey('settings-python-environment-open'),
    );
    expect(entry, findsOneWidget);
    expect(find.textContaining('内置 Python'), findsWidgets);
    await tester.ensureVisible(entry);
    await tester.pumpAndSettle();
    await tester.tap(entry);
    await tester.pumpAndSettle();

    expect(find.byType(PythonEnvironmentPage), findsOneWidget);
    expect(
      find.byKey(const ValueKey('python-environment-status')),
      findsOneWidget,
    );
    expect(find.textContaining('清理缓存不会删除'), findsOneWidget);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('settings-category-content-maintenance')),
      findsOneWidget,
    );
    expect(entry, findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}
