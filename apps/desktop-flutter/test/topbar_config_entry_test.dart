/// 配置切换属于顶栏；配置维护属于「设置 → 站点与内容」。
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/search_suggest_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/app.dart';
import 'package:webhtv_pc/ui/config_pages.dart';
import 'package:webhtv_pc/ui/diagnostics_pages.dart';
import 'package:webhtv_pc/ui/settings_layout.dart';
import 'package:webhtv_pc/ui/startup_arguments.dart';
import 'package:webhtv_pc/ui/theme.dart';

import 'support/detail_test_seams.dart';
import 'support/test_fonts.dart';
import 'support/widget_settle.dart';

// 保留真实激活与持久化；只隔离与入口交互无关的启动联网。
class _EntryTestState extends AppState {
  _EntryTestState({required super.paths})
    : super(
        log: MemoryOnlyLogService(),
        httpClient: MockClient((_) async => http.Response('{"list":[]}', 200)),
        searchSuggestService: SearchSuggestService(
          client: MockClient((_) async => http.Response('{}', 200)),
        ),
      );

  @override
  Future<void> loadHome(Site site) async {}

  @override
  Future<void> startupConfigRefresh() async {}

  @override
  Future<void> maybeAutoCheckForUpdates() async {}
}

void main() {
  final phase = Platform.environment['CONFIG_MANAGEMENT_CAPTURE_PHASE'];
  late Directory tempDir;
  late AppState state;
  final boundary = GlobalKey();

  setUpAll(() async {
    final cjk = firstExisting(cjkFontCandidates());
    if (cjk != null) {
      for (final family in [
        'FixtureCJK',
        'Roboto',
        'monospace',
        'Microsoft YaHei UI',
        'Noto Sans CJK SC',
      ]) {
        await (FontLoader(
          family,
        )..addFont(cjk.readAsBytes().then(ByteData.sublistView))).load();
      }
    }
    await loadFixtureFonts();
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('webhtv-topbar-config');
    final paths = AppPaths.resolve(
      overrides: {
        'config': '${tempDir.path}/config',
        'data': '${tempDir.path}/data',
        'cache': '${tempDir.path}/cache',
        'state': '${tempDir.path}/logs',
      },
    );
    for (final directory in [
      paths.configDir,
      paths.dataDir,
      paths.cacheDir,
      paths.logDir,
    ]) {
      expect(
        directory.startsWith('${tempDir.path}${Platform.pathSeparator}'),
        isTrue,
      );
    }
    state = _EntryTestState(paths: paths);
    await state.bootstrap();
    await File('${paths.configDir}/usage-boundary-accepted')
        .writeAsString('test');
  });

  tearDown(() async {
    state.dispose();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  int seed(String name) => state.database!.saveConfig(
    name: name,
    origin: 'https://example.test/$name.json',
    json: {
      'sites': [
        {
          'key': 'k-$name',
          'name': '示例站点',
          'type': 0,
          'api': 'https://example.test/api',
        },
      ],
    },
    siteCount: 1,
    makeActive: false,
  );

  Future<void> mount(
    WidgetTester tester, {
    Size size = const Size(1072, 728),
    Brightness brightness = Brightness.dark,
    Widget? home,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final theme = buildAppTheme(brightness);
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: MaterialApp(
          theme: theme.copyWith(
            textTheme: theme.textTheme.apply(fontFamily: 'FixtureCJK'),
            primaryTextTheme: theme.primaryTextTheme.apply(
              fontFamily: 'FixtureCJK',
            ),
          ),
          home:
              home ?? AppShell(state: state, startup: const StartupArguments()),
        ),
      ),
    );
    await settle(tester);
    expect(find.text('我已了解并继续'), findsNothing);
    expect(tester.takeException(), isNull);
  }

  Future<void> switcher(WidgetTester tester) async {
    await tester.tap(find.textContaining('配置：').first);
    await settle(tester);
  }

  Future<int?> standaloneSwitcher(
    BuildContext context,
    int activeId, {
    bool withManagement = true,
  }) async {
    var manageRequested = false;
    final navigator = Navigator.of(context);
    final route = DialogRoute<int>(
      context: context,
      builder: (_) => ConfigSwitcherDialog(
        records: state.savedConfigs,
        activeId: activeId,
        onManage: withManagement ? () => manageRequested = true : null,
      ),
      traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
    );
    final result = await navigator.push(route);
    if (manageRequested) {
      await route.completed;
      if (context.mounted) {
        navigator.push(
          MaterialPageRoute<void>(builder: (_) => ConfigPage(state: state)),
        );
      }
    }
    return result;
  }

  Future<void> sites(WidgetTester tester) async {
    final sidebar = find.byType(AppSideBar);
    await tester.tap(find.descendant(of: sidebar, matching: find.text('设置')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('settings-category-sites')));
    await settle(tester);
  }

  void expectSettingsParent(WidgetTester tester) {
    expect(find.byType(ConfigPage), findsNothing);
    expect(find.byKey(const ValueKey('config-switcher')), findsNothing);
    expect(
      tester.widget<AppSideBar>(find.byType(AppSideBar)).section,
      ShellSection.settings,
    );
    expect(
      find.byKey(const ValueKey('settings-category-content-sites')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('settings-config-management-open')),
      findsOneWidget,
    );
  }

  List<int>? lastConfigBytes() {
    final file = File('${state.paths.dataDir}/last-config.json');
    return file.existsSync() ? file.readAsBytesSync() : null;
  }

  List<int>? settingsBytes() {
    final file = File(state.paths.settingsPath);
    return file.existsSync() ? file.readAsBytesSync() : null;
  }

  Future<void> capture(
    WidgetTester tester,
    String scenario,
    Brightness brightness,
    Size size,
  ) async {
    if (phase == null) return;
    await tester.runAsync(() async {
      final render =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await render.toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final root = Directory('../../.local/config-management-settings')
          .absolute;
      final file = File(
        '${root.path}/$phase-$scenario-${brightness.name}-${size.width.toInt()}x${size.height.toInt()}.png',
      );
      expect(file.path.startsWith('${root.path}/'), isTrue);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
      // ignore: avoid_print
      print('captured ${file.path} (${bytes.lengthInBytes} bytes)');
    });
  }

  testWidgets('顶栏只保留配置切换，不再显示管理入口', (tester) async {
    final id = seed('家庭配置');
    await tester.runAsync(() => state.activateConfigRecord(id));
    await mount(tester);
    expect(find.byKey(const ValueKey('topbar-manage-config')), findsNothing);
    expect(find.text('管理'), findsNothing);
    expect(find.text('配置：家庭配置'), findsOneWidget);
  });

  testWidgets('普通侧栏设置仍默认偏好，站点首行是真实配置摘要', (tester) async {
    final first = seed('家庭配置');
    seed('备用配置');
    await tester.runAsync(() => state.activateConfigRecord(first));
    await mount(tester);
    final beforeSettings = settingsBytes();
    await tester.tap(
      find.descendant(of: find.byType(AppSideBar), matching: find.text('设置')),
    );
    await settle(tester);
    expect(find.byKey(const ValueKey('settings-theme-mode')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('settings-config-management-open')),
      findsNothing,
    );
    await tester.tap(find.byKey(const ValueKey('settings-category-sites')));
    await settle(tester);
    final rows = tester
        .widgetList<SettingsNavRow>(
          find.descendant(
            of: find.byKey(const ValueKey('settings-category-content-sites')),
            matching: find.byType(SettingsNavRow),
          ),
        )
        .toList();
    expect(rows.first.title, '配置管理');
    expect(find.text('当前：家庭配置 · 已保存 2 个配置'), findsOneWidget);
    expect(settingsBytes(), beforeSettings, reason: '类别切换不能写偏好');
    final beforeLast = lastConfigBytes();
    await tester.tap(
      find.byKey(const ValueKey('settings-config-management-open')),
    );
    await settle(tester);
    expect(find.byType(ConfigPage), findsOneWidget);
    expect(state.activeRecord?.id, first);
    expect(lastConfigBytes(), beforeLast);
    await tester.pageBack();
    await settle(tester);
    expectSettingsParent(tester);
  });

  for (final category in ['sites', 'playback']) {
    testWidgets('重新点击已选中的侧栏设置保留 $category 分类与滚动，离开后重入才默认偏好', (tester) async {
      await mount(tester);
      await sites(tester);
      await tester.tap(find.byKey(ValueKey('settings-category-$category')));
      await settle(tester);
      final content = find.byKey(
        ValueKey('settings-category-content-$category'),
      );
      await tester.drag(content, const Offset(0, -260));
      await settle(tester);
      final controller = tester.widget<ListView>(content).controller!;
      final offset = controller.offset;
      if (category == 'sites') expect(offset, greaterThan(0));
      await tester.tap(
        find.descendant(of: find.byType(AppSideBar), matching: find.text('设置')),
      );
      await settle(tester);
      expect(content, findsOneWidget);
      expect(
        tester.widget<ListView>(content).controller!.offset,
        closeTo(offset, 0.5),
      );
      await tester.tap(
        find.descendant(of: find.byType(AppSideBar), matching: find.text('首页')),
      );
      await settle(tester);
      await tester.tap(
        find.descendant(of: find.byType(AppSideBar), matching: find.text('设置')),
      );
      await settle(tester);
      expect(
        find.byKey(const ValueKey('settings-category-content-preferences')),
        findsOneWidget,
      );
      expect(content, findsNothing);
    });
  }

  testWidgets('切换框保留调用处的局部主题并使用根导航器', (tester) async {
    final first = seed('家庭配置');
    seed('备用配置');
    await tester.runAsync(() => state.activateConfigRecord(first));
    await mount(
      tester,
      home: Navigator(
        onGenerateRoute: (_) => MaterialPageRoute<void>(
          builder: (_) => Theme(
            data: buildAppTheme(Brightness.light),
            child: AppShell(state: state, startup: const StartupArguments()),
          ),
        ),
      ),
    );
    final shellContext = tester.element(find.byType(AppShell));
    final rootNavigator = Navigator.of(shellContext, rootNavigator: true);
    await switcher(tester);
    final dialogContext = tester.element(find.byType(ConfigSwitcherDialog));
    expect(Theme.of(dialogContext).brightness, Brightness.light);
    expect(ModalRoute.of(dialogContext)!.navigator, same(rootNavigator));
  });

  testWidgets('切换框 Tab 焦点闭环留在模态内', (tester) async {
    final first = seed('家庭配置');
    seed('备用配置');
    await tester.runAsync(() => state.activateConfigRecord(first));
    await mount(tester);
    await switcher(tester);
    final route = ModalRoute.of(
      tester.element(find.byType(ConfigSwitcherDialog)),
    )!;
    expect(route.traversalEdgeBehavior, TraversalEdgeBehavior.closedLoop);
    for (var i = 0; i < 10; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final focusContext = FocusManager.instance.primaryFocus?.context;
      expect(focusContext, isNotNull);
      expect(
        ModalRoute.of(focusContext!),
        same(route),
        reason: 'Tab $i 不得逃到背后壳层',
      );
    }
  });

  testWidgets('单配置也打开切换框，当前行与取消都不激活或持久化', (tester) async {
    final only = seed('唯一配置');
    await tester.runAsync(() => state.activateConfigRecord(only));
    await mount(tester);
    final before = lastConfigBytes();
    await switcher(tester);
    expect(find.byKey(const ValueKey('config-switcher')), findsOneWidget);
    expect(find.byKey(ValueKey('config-switch-current-$only')), findsOneWidget);
    expect(find.text('使用中'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('config-switcher-manage')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(ValueKey('config-switch-option-$only')));
    await settle(tester);
    expect(find.byKey(const ValueKey('config-switcher')), findsOneWidget);
    expect(lastConfigBytes(), before);
    await tester.tap(find.byKey(const ValueKey('config-switcher-cancel')));
    await settle(tester);
    expect(state.activeRecord?.id, only);
    expect(state.database!.activeConfig()?.id, only);
    expect(lastConfigBytes(), before);
    expect(find.byType(ConfigPage), findsNothing);
    expect(
      tester.widget<AppSideBar>(find.byType(AppSideBar)).section,
      ShellSection.home,
    );
  });

  testWidgets('切换框配置管理先关闭弹窗，返回落在设置站点分类', (tester) async {
    final first = seed('家庭配置');
    seed('备用配置');
    await tester.runAsync(() => state.activateConfigRecord(first));
    await mount(tester);
    final before = lastConfigBytes();
    await switcher(tester);
    final manage = find.byKey(const ValueKey('config-switcher-manage'));
    expect(
      find.descendant(of: manage, matching: find.text('配置管理')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: manage,
        matching: find.byIcon(Icons.settings_outlined),
      ),
      findsOneWidget,
    );
    await tester.tap(manage);
    await settle(tester);
    expect(find.byType(ConfigPage), findsOneWidget);
    expect(find.byKey(const ValueKey('config-switcher')), findsNothing);
    expect(find.byType(AnimatedModalBarrier), findsNothing);
    expect(
      ModalRoute.of(tester.element(find.byType(ConfigPage)))!.isCurrent,
      isTrue,
    );
    await tester.tap(find.byKey(const ValueKey('config-import-toggle')));
    await settle(tester);
    expect(find.text('选择本地文件'), findsOneWidget, reason: '不能有遮罩挡住管理控件');
    expect(find.text('配置导入与管理'), findsOneWidget);
    expect(state.activeRecord?.id, first);
    expect(state.database!.activeConfig()?.id, first);
    expect(lastConfigBytes(), before);
    await tester.pageBack();
    await settle(tester);
    expectSettingsParent(tester);
    expect(lastConfigBytes(), before);
  });

  testWidgets('再次从设置其他分类走切换框管理，仍以站点分类为父级', (tester) async {
    final first = seed('家庭配置');
    seed('备用配置');
    await tester.runAsync(() => state.activateConfigRecord(first));
    await mount(tester);
    for (var entry = 0; entry < 2; entry++) {
      await switcher(tester);
      await tester.tap(find.byKey(const ValueKey('config-switcher-manage')));
      await settle(tester);
      await tester.pageBack();
      await settle(tester);
      expectSettingsParent(tester);
      await tester.tap(
        find.byKey(const ValueKey('settings-category-playback')),
      );
      await settle(tester);
      expect(
        find.byKey(const ValueKey('settings-player-buttons')),
        findsOneWidget,
      );
    }
  });

  testWidgets('多配置点非当前项仍激活并记住目标', (tester) async {
    final first = seed('甲');
    final second = seed('乙');
    await tester.runAsync(() => state.activateConfigRecord(first));
    await mount(tester);
    await switcher(tester);
    await tester.tap(find.byKey(ValueKey('config-switch-option-$second')));
    await settle(tester);
    expect(state.activeRecord?.id, second);
    expect(state.database!.activeConfig()?.id, second);
    expect(state.lastConfigRecord?.recordId, second);
    expect(find.byKey(const ValueKey('config-switcher')), findsNothing);
    expect(find.byType(ConfigPage), findsNothing);
  });

  testWidgets('零配置导入按钮直达管理，返回落到设置站点空态', (tester) async {
    await mount(tester);
    final before = lastConfigBytes();
    await tester.tap(find.widgetWithText(TextButton, '导入配置').first);
    await settle(tester);
    expect(find.byType(ConfigPage), findsOneWidget);
    await tester.pageBack();
    await settle(tester);
    expectSettingsParent(tester);
    expect(find.text('尚未保存配置 · 导入 URL、本地文件或 JSON'), findsOneWidget);
    expect(state.activeRecord, isNull);
    expect(lastConfigBytes(), before);
  });

  testWidgets('零配置导入入口直达管理，返回设置站点空态仍可操作', (tester) async {
    await mount(tester);
    final before = lastConfigBytes();
    await tester.tap(find.widgetWithText(TextButton, '导入配置').first);
    await settle(tester);
    expect(find.byType(ConfigPage), findsOneWidget);
    expect(find.text('选择本地文件'), findsOneWidget);
    expect(find.byKey(const ValueKey('config-switcher')), findsNothing);
    await tester.pageBack();
    await settle(tester);
    expectSettingsParent(tester);
    expect(find.text('尚未保存配置 · 导入 URL、本地文件或 JSON'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('settings-config-management-open')),
    );
    await settle(tester);
    expect(find.byType(ConfigPage), findsOneWidget);
    expect(state.activeRecord, isNull);
    expect(state.database!.activeConfig(), isNull);
    expect(lastConfigBytes(), before);
  });

  testWidgets('有保存但无当前配置时摘要不虚构当前项，进入管理不激活', (tester) async {
    seed('未启用配置');
    await mount(tester);
    await sites(tester);
    expect(find.text('未启用配置 · 已保存 1 个配置'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('settings-config-management-open')),
    );
    await settle(tester);
    expect(find.byType(ConfigPage), findsOneWidget);
    expect(state.activeRecord, isNull);
    expect(state.database!.activeConfig(), isNull);
    expect(lastConfigBytes(), isNull);
  });

  testWidgets('超长配置名在目标宽度省略，切换框和设置摘要不溢出', (tester) async {
    final id = seed('这是一个特别特别长的配置名称用于验证顶栏和设置以及切换框不会被撑爆的情况' * 3);
    seed('备用');
    await tester.runAsync(() => state.activateConfigRecord(id));
    await mount(tester);
    expect(tester.getRect(find.text('站点：示例站点')).right, lessThanOrEqualTo(1072));
    await switcher(tester);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('config-switcher-cancel')));
    await settle(tester);
    await sites(tester);
    final summary = tester.widget<Text>(
      find.byKey(const ValueKey('settings-config-management-summary')),
    );
    expect(summary.overflow, TextOverflow.ellipsis);
    expect(tester.takeException(), isNull);
  });

  for (final brightness in Brightness.values) {
    testWidgets('窄窗配置管理可见可点且长名称不溢出 ${brightness.name}', (tester) async {
      final first = seed('这是一个特别长的配置名称用于检验窄窗站点设置摘要与选择器的真实换行' * 3);
      seed('另一个很长的备用配置名称用于验证没有单行空间时仍保留管理操作' * 3);
      await tester.runAsync(() => state.activateConfigRecord(first));
      const size = Size(480, 640);
      await mount(
        tester,
        size: size,
        brightness: brightness,
        home: Scaffold(body: SettingsPage(state: state)),
      );
      await tester.tap(find.byKey(const ValueKey('settings-category-sites')));
      await settle(tester);
      final summary = tester.widget<Text>(
        find.byKey(const ValueKey('settings-config-management-summary')),
      );
      expect(summary.overflow, TextOverflow.ellipsis);
      final before = lastConfigBytes();
      final context = tester.element(find.byType(SettingsPage));
      final result = standaloneSwitcher(context, first);
      await settle(tester);
      final manage = find.byKey(const ValueKey('config-switcher-manage'));
      expect(manage.hitTestable(), findsOneWidget);
      expect(tester.getRect(manage).left, greaterThanOrEqualTo(0));
      expect(tester.getRect(manage).right, lessThanOrEqualTo(size.width));
      expect(tester.getRect(manage).bottom, lessThanOrEqualTo(size.height));
      expect(tester.takeException(), isNull);
      await tester.tap(manage);
      await settle(tester);
      expect(await result, isNull);
      expect(find.byType(ConfigSwitcherDialog), findsNothing);
      expect(find.byType(AnimatedModalBarrier), findsNothing);
      expect(find.byType(ConfigPage), findsOneWidget);
      expect(state.activeRecord?.id, first);
      expect(lastConfigBytes(), before);
      await tester.pageBack();
      await settle(tester);
      expect(
        find.byKey(const ValueKey('settings-category-content-sites')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }

  for (final brightness in Brightness.values) {
    testWidgets('capture migration wide ${brightness.name}', (tester) async {
      final first = seed('家庭配置');
      seed('本地备用');
      await tester.runAsync(() => state.activateConfigRecord(first));
      const size = Size(1072, 728);
      await mount(tester, brightness: brightness);
      await capture(tester, 'shell', brightness, size);
      await switcher(tester);
      await capture(tester, 'switcher', brightness, size);
      await tester.tap(find.byKey(const ValueKey('config-switcher-cancel')));
      await settle(tester);
      await sites(tester);
      await capture(tester, 'settings-sites', brightness, size);
      // 同一个既有目标页，Before 走旧顶栏，After 走设置首行。
      final entry = phase == 'before'
          ? find.byKey(const ValueKey('topbar-manage-config'))
          : find.byKey(const ValueKey('settings-config-management-open'));
      await tester.tap(entry);
      await settle(tester);
      expect(find.byType(ConfigPage), findsOneWidget);
      await capture(tester, 'management', brightness, size);
      expect(tester.takeException(), isNull);
    }, skip: phase == null);
  }

  testWidgets('capture migration narrow dark', (tester) async {
    final first = seed('家庭配置');
    seed('本地备用');
    await tester.runAsync(() => state.activateConfigRecord(first));
    const size = Size(480, 640);
    await mount(
      tester,
      size: size,
      home: Scaffold(body: SettingsPage(state: state)),
    );
    await tester.tap(find.byKey(const ValueKey('settings-category-sites')));
    await settle(tester);
    await capture(tester, 'settings-sites', Brightness.dark, size);
    final context = tester.element(find.byType(SettingsPage));
    final result = standaloneSwitcher(
      context,
      first,
      withManagement: phase != 'before',
    );
    await settle(tester);
    final manage = find.byKey(const ValueKey('config-switcher-manage'));
    expect(manage, phase == 'before' ? findsNothing : findsOneWidget);
    if (phase != 'before') expect(manage.hitTestable(), findsOneWidget);
    await capture(tester, 'switcher', Brightness.dark, size);
    expect(tester.takeException(), isNull);
    await tester.tap(
      phase == 'before'
          ? find.byKey(const ValueKey('config-switcher-cancel'))
          : manage,
    );
    await settle(tester);
    expect(await result, isNull);
    if (phase != 'before') {
      expect(find.byType(ConfigPage), findsOneWidget);
      expect(find.byType(ConfigSwitcherDialog), findsNothing);
    }
  }, skip: phase == null);
}
