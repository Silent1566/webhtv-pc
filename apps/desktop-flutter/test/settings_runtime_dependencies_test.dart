/// 「运行时与外部依赖」区块（设置 → 站点与内容 → 运行时与外部依赖）。
///
/// ## 这一组用例锁什么
///
/// 加固壳解包运行时与 Python 运行时是**同一类东西**（本地程序运行时、按需获取、
/// 装不装只影响对应类型的站源）。它们原先分在两个分类里，用户从站源错误信息
/// 找过来时要先猜去哪一组。收成区块后必须锁住三件事：
///
/// 1. 分类页上只有一个区块入口（旧的单行「加固壳解包运行时」入口已不存在），
///    且点得进区块页；
/// 2. 区块页里两类运行时都在，各自点进**既有**的明细页（不复制第二份页面）；
/// 3. 「已装/未装」「能不能用」跟着状态走：状态变了页面自己刷新，
///    不要求用户退出去再进来。
///
/// 状态用注入的最小桩（`shellRuntimeInstalled` / `pythonEnvironmentStatus`）：
/// 真实状态要读 18 个 jar 的磁盘目录、要先探测解释器，widget 测试两件事都不该碰。
///
/// ## 为什么还要宽/窄 × 暗/亮各一次
///
/// 分类页那行摘要与新页面的长副标题都是**单行截断**文本：480 宽是它们最容易
/// 溢出的地方，且两套主题都跑一遍，才不至于只有暗色那套被验证过。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/python_environment.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/diagnostics_pages.dart';
import 'package:webhtv_pc/ui/python_environment_page.dart';
import 'package:webhtv_pc/ui/runtime_dependencies_page.dart';
import 'package:webhtv_pc/ui/settings_layout.dart';
import 'package:webhtv_pc/ui/shell_runtime_page.dart';
import 'package:webhtv_pc/ui/theme.dart';

import 'support/settings_row_navigation.dart';

void main() {
  late Directory temp;
  late AppState state;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('webhtv-runtime-dependencies');
    final paths = AppPaths.resolve(
      overrides: {
        'config': p.join(temp.path, 'config'),
        'data': p.join(temp.path, 'data'),
        'cache': p.join(temp.path, 'cache'),
        'state': p.join(temp.path, 'logs'),
      },
    );
    state = AppState(paths: paths, log: LogService());
    await state.bootstrap();
  });

  tearDown(() {
    state.dispose();
    try {
      temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> pumpSettings(
    WidgetTester tester, {
    Size size = const Size(1440, 900),
    Brightness brightness = Brightness.dark,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(brightness),
        // 外壳里的设置页是某个 Scaffold 的 body（分类条上的 ListTile 需要
        // Material 祖先）；直接挂裸页面会得到「No Material widget found」。
        home: ListenableBuilder(
          listenable: state,
          builder: (context, _) => Scaffold(body: SettingsPage(state: state)),
        ),
      ),
    );
    await pumpSettingsSettled(tester);
  }

  Future<void> pumpBlockPage(
    WidgetTester tester, {
    Size size = const Size(1000, 800),
    Brightness brightness = Brightness.dark,
    bool Function()? shellRuntimeInstalled,
    PythonEnvironmentStatus? Function()? pythonEnvironmentStatus,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(brightness),
        home: RuntimeDependenciesPage(
          state: state,
          shellRuntimeInstalled: shellRuntimeInstalled,
          pythonEnvironmentStatus: pythonEnvironmentStatus,
        ),
      ),
    );
    await pumpSettingsSettled(tester);
  }

  /// 「已就绪」的那份 Python 状态（ready 需要解释器、版本与四个模块齐全）。
  const readyPython = PythonEnvironmentStatus(
    executable: r'C:\py\python.exe',
    version: '3.11.9',
    source: PythonEnvironmentSource.bundled,
    dependencies: {'requests': true, 'Crypto': true, 'lxml': true, 'bs4': true},
  );

  testWidgets('分类页只留一个区块入口：旧的单行入口已并入，点得进区块页', (tester) async {
    await pumpSettings(tester);
    await tester.tap(find.byKey(const ValueKey('settings-category-sites')));
    await pumpSettingsSettled(tester);

    // 旧入口已并入区块：分类页上不能再有一行直接叫「加固壳解包运行时」。
    expect(
      find.byKey(
        const ValueKey('settings-shell-runtime-open'),
        skipOffstage: false,
      ),
      findsNothing,
      reason: '加固壳解包运行时已经收进「运行时与外部依赖」区块，不该在分类页上再占一行',
    );

    await revealCategoryRow(
      tester,
      category: 'sites',
      rowKey: 'settings-runtime-dependencies-open',
    );
    final entry = tester.widget<SettingsNavRow>(
      find.byKey(const ValueKey('settings-runtime-dependencies-open')),
    );
    expect(entry.title, '运行时与外部依赖');
    expect(
      entry.subtitle,
      allOf(contains('加固壳解包运行时'), contains('Python 运行时')),
      reason: '分类页这一行要能一眼看出区块里有什么',
    );

    await tester.tap(
      find.byKey(const ValueKey('settings-runtime-dependencies-open')),
    );
    await pumpSettingsSettled(tester);
    expect(find.byType(RuntimeDependenciesPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('区块页两行都在，且各自点进既有的明细页', (tester) async {
    await pumpBlockPage(tester);

    expect(find.text('加固壳解包运行时'), findsOneWidget);
    expect(find.text('Python 运行时（CatVod 依赖）'), findsOneWidget);

    // 行 1 → 既有的加固壳解包运行时页（不复制一份新页面）。
    await tester.tap(find.text('加固壳解包运行时'));
    await pumpSettingsSettled(tester);
    expect(find.byType(ShellRuntimePage), findsOneWidget);
    await backFromSettingsDetail(tester);

    // 行 2 → 既有的运行环境页。
    await tester.tap(find.text('Python 运行时（CatVod 依赖）'));
    await pumpSettingsSettled(tester);
    expect(find.byType(PythonEnvironmentPage), findsOneWidget);
    await backFromSettingsDetail(tester);
    expect(find.byType(RuntimeDependenciesPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('文案跟着状态走：已装/未装、已就绪/不可用/未检测', (tester) async {
    // ① 未安装 + 未检测
    await pumpBlockPage(tester, shellRuntimeInstalled: () => false);
    expect(find.textContaining('未安装 · unidbg'), findsOneWidget);
    expect(find.textContaining('已安装 · unidbg'), findsNothing);
    expect(find.textContaining('未检测'), findsOneWidget);

    // ② 已安装 + 已就绪
    await pumpBlockPage(
      tester,
      shellRuntimeInstalled: () => true,
      pythonEnvironmentStatus: () => readyPython,
    );
    expect(find.textContaining('已安装 · unidbg'), findsOneWidget);
    expect(find.textContaining('未安装 · unidbg'), findsNothing);
    expect(find.textContaining('已就绪'), findsOneWidget);

    // ③ 解释器缺失 = 不可用
    await pumpBlockPage(
      tester,
      shellRuntimeInstalled: () => false,
      pythonEnvironmentStatus: () => const PythonEnvironmentStatus(),
    );
    expect(find.textContaining('不可用'), findsOneWidget);
    expect(find.textContaining('已就绪'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('装完运行时回到本页会自己刷新（不必退出去再进来）', (tester) async {
    var installed = false;
    await pumpBlockPage(tester, shellRuntimeInstalled: () => installed);
    expect(find.textContaining('未安装 · unidbg'), findsOneWidget);

    installed = true;
    // 安装完成时 `AppState.installShellRuntime` 就是这么通知宿主的。
    state.notifyListeners();
    await pumpSettingsSettled(tester);

    expect(find.textContaining('已安装 · unidbg'), findsOneWidget);
    expect(find.textContaining('未安装 · unidbg'), findsNothing);
  });

  for (final brightness in [Brightness.dark, Brightness.light]) {
    testWidgets('窄窗不溢出：480×640（${brightness.name}）', (tester) async {
      await pumpBlockPage(
        tester,
        size: const Size(480, 640),
        brightness: brightness,
        shellRuntimeInstalled: () => false,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('加固壳解包运行时'), findsOneWidget);
      expect(find.text('Python 运行时（CatVod 依赖）'), findsOneWidget);

      // 分类页那一行摘要同样要经得起窄窗（它是单行截断的 Text）。
      await pumpSettings(
        tester,
        size: const Size(480, 640),
        brightness: brightness,
      );
      await tester.tap(find.byKey(const ValueKey('settings-category-sites')));
      await pumpSettingsSettled(tester);
      await revealCategoryRow(
        tester,
        category: 'sites',
        rowKey: 'settings-runtime-dependencies-open',
      );
      expect(tester.takeException(), isNull);
    });
  }
}
