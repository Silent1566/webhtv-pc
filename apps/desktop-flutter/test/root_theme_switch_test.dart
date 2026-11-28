import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/search_suggest_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/app.dart';
import 'package:webhtv_pc/ui/desktop_window_frame.dart';
import 'package:webhtv_pc/ui/glass_dialog.dart';
import 'package:webhtv_pc/ui/diagnostics_pages.dart';
import 'package:webhtv_pc/ui/library_pages.dart';

import 'support/detail_test_seams.dart';
import 'support/test_fonts.dart';
import 'support/widget_settle.dart';

class _ThemeState extends AppState {
  _ThemeState(AppPaths paths)
    : super(
        paths: paths,
        log: MemoryOnlyLogService(),
        warmAutoRoutes: false,
        httpClient: MockClient((_) async => http.Response('{}', 200)),
        searchSuggestService: SearchSuggestService(
          client: MockClient((_) async => http.Response('{}', 200)),
        ),
      );
  @override
  bool get externalMetaEnabled => false;
  @override
  Future<void> startupConfigRefresh() async {}
  @override
  Future<void> maybeAutoCheckForUpdates() async {}
}

const _captureKey = ValueKey('theme-root-capture');

void main() {
  late Directory temp;
  late AppPaths paths;
  late _ThemeState state;

  setUpAll(() => loadFixtureFonts(cjkFamily: 'Microsoft YaHei UI'));
  setUp(() {
    temp = Directory.systemTemp.createTempSync('root-theme-switch');
    paths = AppPaths.resolve(
      overrides: {
        'config': '${temp.path}/config',
        'data': '${temp.path}/data',
        'cache': '${temp.path}/cache',
        'state': '${temp.path}/state',
      },
    );
    Directory(paths.configDir).createSync(recursive: true);
    File('${paths.configDir}/usage-boundary-accepted')
        .writeAsStringSync('accepted test fixture');
    state = _ThemeState(paths);
  });
  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  Future<void> mount(WidgetTester tester, [_ThemeState? restored]) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async {
        if (call.method == 'isFullScreen' ||
            call.method == 'isPreventClose' ||
            call.method == 'isMaximized') {
          return false;
        }
        if (call.method == 'isFocused') return true;
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('window_manager'),
        null,
      ),
    );
    await tester.pumpWidget(
      RepaintBoundary(
        key: _captureKey,
        child: WebHtvApp(stateFactory: () => restored ?? state),
      ),
    );
    await settle(tester);
    expect(find.byType(AppShell), findsOneWidget);
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }

  Future<void> capture(WidgetTester tester, String name) async {
    final dir = Platform.environment['THEME_SWITCH_CAPTURE'];
    if (dir == null) return;
    final phase = Platform.environment['THEME_SWITCH_PHASE'] ?? 'after';
    await tester.runAsync(() async {
      final image = await tester
          .renderObject<RenderRepaintBoundary>(find.byKey(_captureKey))
          .toImage();
      try {
        final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        await File('$dir/$name-$phase.png').writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        );
      } finally {
        image.dispose();
      }
    });
  }

  Future<void> choose(WidgetTester tester, String label) async {
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('settings-theme-mode')),
        matching: find.text(label),
      ),
    );
    await settle(tester);
  }

  testWidgets('actual root repaints light after selecting it in settings', (
    tester,
  ) async {
    try {
      await mount(tester);
      await tester.tap(
        find.descendant(
          of: find.byType(NavigationRail),
          matching: find.text('设置'),
        ),
      );
      await settle(tester);
      final settingsElement = tester.element(find.byType(SettingsPage));
      final navigatorState = tester.state<NavigatorState>(
        find.byType(Navigator),
      );
      expect(
        Theme.of(
          tester.element(find.byKey(const ValueKey('settings-theme-mode'))),
        ).brightness,
        Brightness.dark,
      );
      await capture(tester, 'settings-dark');
      await choose(tester, '亮色');
      expect(state.themeMode, 'light');
      expect(
        tester
            .widget<SegmentedButton<ThemeMode>>(
              find.byKey(const ValueKey('settings-theme-mode')),
            )
            .selected,
        {ThemeMode.light},
      );
      await capture(tester, 'settings-light-selected');
      expect(
        tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
        ThemeMode.light,
        reason: 'Saved light preference must rebuild MaterialApp, not only the settings selection',
      );
      expect(
        Theme.of(
          tester.element(find.byKey(const ValueKey('settings-theme-mode'))),
        ).brightness,
        Brightness.light,
      );
      expect(
        Theme.of(tester.element(find.byType(DesktopWindowFrame))).brightness,
        Brightness.light,
      );
      expect(tester.element(find.byType(SettingsPage)), same(settingsElement));
      expect(
        tester.state<NavigatorState>(find.byType(Navigator)),
        same(navigatorState),
      );
      final dialog = showGlassDialog<void>(
        context: tester.element(
          find.byKey(const ValueKey('settings-theme-mode')),
        ),
        builder: (_) => const GlassAlertDialog(
          title: Text('主题验证'),
          content: Text('弹窗应继承当前亮色主题'),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        Theme.of(tester.element(find.text('主题验证'))).brightness,
        Brightness.light,
      );
      Navigator.of(tester.element(find.text('主题验证'))).pop();
      await tester.pumpAndSettle();
      await dialog;
      await tester.tap(
        find.descendant(
          of: find.byType(NavigationRail),
          matching: find.text('收藏'),
        ),
      );
      await settle(tester);
      expect(find.byType(FavoritesPage), findsOneWidget);
      expect(
        Theme.of(tester.element(find.byType(FavoritesPage))).brightness,
        Brightness.light,
      );
      await tester.tap(
        find.descendant(
          of: find.byType(NavigationRail),
          matching: find.text('设置'),
        ),
      );
      await settle(tester);
      expect(find.byKey(const ValueKey('settings-theme-mode')), findsOneWidget);
      await choose(tester, '暗色');
      expect(
        Theme.of(
          tester.element(find.byKey(const ValueKey('settings-theme-mode'))),
        ).brightness,
        Brightness.dark,
      );
      expect(tester.takeException(), isNull);
    } finally {
      await unmount(tester);
    }
  });

  testWidgets('root follows system changes and restores persisted light mode', (
    tester,
  ) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    try {
      await mount(tester);
      await tester.runAsync(() => state.setThemeMode('system'));
      await settle(tester);
      expect(
        tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
        ThemeMode.system,
      );
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      await settle(tester);
      expect(
        Theme.of(tester.element(find.byType(AppShell))).brightness,
        Brightness.light,
      );
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      await settle(tester);
      expect(
        Theme.of(tester.element(find.byType(AppShell))).brightness,
        Brightness.dark,
      );
      await tester.runAsync(() => state.setThemeMode('light'));
      await settle(tester);
      await unmount(tester);
      final restored = _ThemeState(paths);
      await mount(tester, restored);
      expect(restored.themeMode, 'light');
      expect(
        Theme.of(tester.element(find.byType(AppShell))).brightness,
        Brightness.light,
      );
      expect(tester.takeException(), isNull);
    } finally {
      await unmount(tester);
    }
  });
}
