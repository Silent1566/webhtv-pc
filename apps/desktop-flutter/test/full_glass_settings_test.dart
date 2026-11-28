import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/core/reader/reader_models.dart';
import 'package:webhtv_pc/services/reader/reader_preferences_store.dart';
import 'package:webhtv_pc/services/reader/reader_tts_controller.dart';
import 'package:webhtv_pc/services/reader/tts_engines.dart';
import 'package:webhtv_pc/ui/reader/reader_page.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/web_home_store.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/glass_chrome.dart';
import 'package:webhtv_pc/ui/diagnostics_pages.dart';
import 'package:webhtv_pc/ui/glass_surface.dart';
import 'package:webhtv_pc/ui/glass_widgets.dart';
import 'package:webhtv_pc/ui/health_filter_controls.dart';
import 'package:webhtv_pc/ui/player_button_config_page.dart';
import 'package:webhtv_pc/ui/settings_detail_pages.dart';
import 'package:webhtv_pc/ui/settings_layout.dart';
import 'package:webhtv_pc/ui/settings_overview_page.dart';
import 'package:webhtv_pc/ui/site_self_check_panel.dart';
import 'package:webhtv_pc/ui/theme.dart';
import 'package:webhtv_pc/ui/wallpaper_backdrop.dart';
import 'package:webhtv_pc/ui/web_home_page.dart';

import 'support/test_fonts.dart';

class _SilentReaderOutput implements ReaderAudioOutput {
  @override
  Future<void> play(TtsAudio audio) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}

void main() {
  late Directory workspace;
  late AppState state;
  final captureKey = GlobalKey();

  setUpAll(() async {
    await loadFixtureFonts();
    await loadFixtureFonts(cjkFamily: 'Roboto');
    await loadFixtureFonts(cjkFamily: 'Noto Sans CJK SC');
    await loadFixtureFonts(cjkFamily: 'Microsoft YaHei UI');
  });
  setUp(() async {
    workspace = await Directory.systemTemp.createTemp('glass-settings');
    final paths = AppPaths.resolve(
      overrides: {
        for (final name in ['config', 'data', 'cache', 'state'])
          name: '${workspace.path}/$name',
      },
    );
    state = AppState(paths: paths, log: LogService());
    await state.bootstrap();
  });
  tearDown(() async {
    state.dispose();
    await workspace.delete(recursive: true);
  });

  Future<void> mount(
    WidgetTester tester,
    Brightness brightness,
    Widget page,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1024, 640);
    addTearDown(tester.view.reset);
    final theme = buildAppTheme(brightness);
    await tester.pumpWidget(
      MaterialApp(
        theme: theme.copyWith(
          textTheme: theme.textTheme.apply(fontFamily: 'FixtureCJK'),
        ),
        builder: (context, child) =>
            RepaintBoundary(key: captureKey, child: child!),
        home: page,
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> capture(
    WidgetTester tester,
    String scenario,
    Brightness brightness,
  ) async {
    final phase = Platform.environment['GLASS_FULL_PHASE'];
    final dir = Platform.environment['GLASS_FULL_CAPTURE'];
    if (phase == null || dir == null) return;
    expectFontsAvailableOrSkip();
    expect(firstExisting(iconFontCandidates()), isNotNull);
    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(captureKey),
      );
      final image = await boundary.toImage();
      try {
        final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        await Directory(dir).create(recursive: true);
        await File('$dir/$scenario-${brightness.name}-$phase.png')
            .writeAsBytes(png.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    });
  }

  testWidgets('manual check panel keeps its title when embedded', (
    tester,
  ) async {
    await mount(
      tester,
      Brightness.dark,
      const Scaffold(body: SiteSelfCheckPanel(service: null, sites: [])),
    );
    expect(find.text('手动站点体检'), findsOneWidget);
  });

  for (final brightness in Brightness.values) {
    testWidgets(
      'shell settings frame stays below its header while the list underlaps in $brightness',
      (tester) async {
        await mount(
          tester,
          brightness,
          WallpaperBackdrop(
            url: null,
            builder: (_, _) => Scaffold(
              body: SettingsPage(
                state: state,
                initialCategory: SettingsCategory.danmaku,
                shellUnderlap: true,
              ),
            ),
          ),
        );
        final category = find.byKey(
          const ValueKey('settings-category-danmaku'),
        );
        final navigation = tester.getRect(
          find.ancestor(of: category, matching: find.byType(GlassPane)).first,
        );
        final list = find.byKey(
          const ValueKey('settings-category-content-danmaku'),
        );
        final material = find.descendant(
          of: find.byType(SettingsCategoriesBody),
          matching: find.byType(GlassPane),
        );
        final pane = material.at(1);
        final frame = tester.getRect(pane);
        final header = tester.getRect(find.text('调整日常偏好、播放体验与连接服务。'));
        final listViewport = find.descendant(
          of: list,
          matching: find.byType(Viewport),
        );
        final entry = find.byKey(const ValueKey('settings-danmaku-open'));
        final entryBefore = tester.getRect(entry);
        await capture(tester, 'settings-frame', brightness);
        expect(
          frame.top,
          navigation.top,
          reason: 'the right panel border must align with the category rail, not begin above the header',
        );
        expect(frame.top, greaterThan(header.bottom));
        expect(frame.bottom, navigation.bottom);
        expect(
          tester.getTopLeft(listViewport).dy,
          0,
          reason: 'keep list underlap independent of the fixed panel frame',
        );
        await tester.tap(
          find.byKey(const ValueKey('settings-category-maintenance')),
        );
        await tester.pumpAndSettle();
        final maintenance = find.byKey(
          const ValueKey('settings-category-content-maintenance'),
        );
        final controller = tester.widget<ListView>(maintenance).controller!;
        controller.jumpTo(controller.position.maxScrollExtent);
        await tester.pump();
        expect(tester.getRect(pane), frame);
        await tester.tap(category);
        await tester.pumpAndSettle();
        expect(tester.getRect(entry), entryBefore);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final scenario in ['app-default', 'inherited', 'explicit', 'fallback']) {
    testWidgets('secondary glass card preserves $scenario margin geometry', (
      tester,
    ) async {
      final appTheme = buildAppTheme(Brightness.dark);
      final explicit = scenario == 'explicit'
          ? const EdgeInsets.fromLTRB(3, 5, 7, 11)
          : null;
      final inherited = scenario == 'inherited' || scenario == 'explicit'
          ? const EdgeInsets.fromLTRB(13, 17, 19, 23)
          : scenario == 'fallback'
          ? null
          : EdgeInsets.zero;
      final expected = explicit ?? inherited ?? EdgeInsets.zero;
      final childKey = UniqueKey();
      final hostKey = UniqueKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme.copyWith(cardTheme: CardThemeData(margin: inherited)),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                key: hostKey,
                width: 300,
                height: 180,
                child: explicit == null
                    ? SettingsGlassCard(child: SizedBox.expand(key: childKey))
                    : SettingsGlassCard(
                        margin: explicit,
                        child: SizedBox.expand(key: childKey),
                      ),
              ),
            ),
          ),
        ),
      );
      final outer = tester.getRect(find.byKey(hostKey));
      final inner = tester.getRect(find.byKey(childKey));
      expect(
        inner,
        Rect.fromLTRB(
          outer.left + expected.left,
          outer.top + expected.top,
          outer.right - expected.right,
          outer.bottom - expected.bottom,
        ),
      );
      expect(tester.takeException(), isNull);
    });
  }

  Finder glassAbove(Finder target) =>
      find.ancestor(of: target, matching: find.byType(GlassPane));

  testWidgets('reset confirmation has one glass layer and can cancel', (
    tester,
  ) async {
    final orderBefore = List.of(state.playerButtonOrder);
    await mount(tester, Brightness.dark, PlayerButtonConfigPage(state: state));
    await tester.tap(find.byKey(const ValueKey('player-buttons-reset')));
    await tester.pumpAndSettle();
    final message = find.text('将按钮顺序与显示状态恢复为默认值。');
    expect(message, findsOneWidget);
    await capture(tester, 'reset-confirmation', Brightness.dark);
    final framed = find
        .ancestor(of: message, matching: find.byType(GlassSurface))
        .evaluate()
        .length;
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(message, findsNothing);
    expect(state.playerButtonOrder, orderBefore);
    expect(
      framed,
      1,
      reason: 'the modal route needs its own single glass panel',
    );
  });

  testWidgets(
    'playback selection popup has one glass surface and dismisses with Escape',
    (tester) async {
      await mount(tester, Brightness.dark, PlaybackOptionsPage(state: state));
      final dropdown = find.byType(SettingsDropdown<double>).first;
      await tester.ensureVisible(dropdown);
      await tester.tap(dropdown);
      await tester.pumpAndSettle();
      final option = find.text('3×').last;
      final panelCount = find
          .ancestor(of: option, matching: find.byType(GlassPane))
          .evaluate()
          .length;
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(panelCount, greaterThanOrEqualTo(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'health filter opens a glass menu without changing selection on cancel',
    (tester) async {
      var current = '全部状态';
      await mount(
        tester,
        Brightness.dark,
        Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: healthFilterSelect(
                context: context,
                key: const ValueKey('glass-health-filter'),
                label: '结论',
                value: current,
                options: const ['全部状态', '有成功', '有失败'],
                onChanged: (value) => current = value,
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('glass-health-filter')));
      await tester.pumpAndSettle();
      final glass = glassAbove(find.text('有失败')).evaluate().length;
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(current, '全部状态');
      expect(glass, 1);
    },
  );

  for (final brightness in Brightness.values) {
    testWidgets('reader preserves readable paragraphs in $brightness', (
      tester,
    ) async {
      final controller = ReaderTtsController(
        engines: TtsEngines(
          factory: (_) => throw StateError('No speech requested'),
        ),
        store: ReaderPreferencesStore('${workspace.path}/reader.json'),
        audio: _SilentReaderOutput(),
      );
      addTearDown(controller.close);
      await mount(
        tester,
        brightness,
        ReaderPage(
          controller: controller,
          title: '阅读器',
          initialText: '阅读时保留清晰的段落与字距。\n使用上方按钮开始朗读，或者选择文字。\n背景材质按整页分组，正文不逐段模糊。',
        ),
      );
      expect(find.byType(GlassChromeSurface), findsOneWidget);
      expect(find.byType(GlassPane), findsOneWidget);
      await capture(tester, 'reader', brightness);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'all settings and deeper diagnostics use grouped glass in $brightness',
      (tester) async {
        await mount(tester, brightness, SettingsOverviewPage(state: state));
        final category = find.byKey(const ValueKey('settings-category-sites'));
        final form = find.byKey(const ValueKey('settings-theme-mode'));
        await capture(tester, 'overview', brightness);
        final railHasGlass = glassAbove(category).evaluate().length;
        final formHasGlass = glassAbove(form).evaluate().length;
        final hubHasDefaultArt = find
            .byType(DefaultGlassBackdrop)
            .evaluate()
            .isNotEmpty;
        await tester.tap(category);
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('settings-site-health-open')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('site-health-self-check-open')),
        );
        await tester.pumpAndSettle();
        expect(find.widgetWithText(AppBar, '手动站点体检'), findsOneWidget);
        expect(find.text('手动站点体检'), findsOneWidget);
        expect(find.text('只检查首页和分类，不检查详情、搜索或播放；结果不代表已验证能播。'), findsOneWidget);
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const ValueKey('self-check-start')),
              )
              .onPressed,
          isNull,
        );
        await capture(tester, 'manual-check', brightness);
        expect(
          railHasGlass,
          1,
          reason: 'the settings rail has its own uninterrupted glass panel',
        );
        expect(
          formHasGlass,
          1,
          reason: 'the settings form is independently framed',
        );
        expect(hubHasDefaultArt, isTrue);
        expect(find.byType(GlassChromeSurface), findsOneWidget);
        expect(find.byType(GlassPane), findsWidgets);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'browser host paints its error and app bar with glass in $brightness',
      (tester) async {
        const plugin = MethodChannel('io.jns.webview.win');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(plugin, (_) async {
          throw PlatformException(
            code: 'webview_unavailable',
            message: 'WebView2 Runtime not installed',
          );
        });
        addTearDown(() => messenger.setMockMethodCallHandler(plugin, null));
        await mount(
          tester,
          brightness,
          WebHomePage(
            state: state,
            source: const WebHomeSource(
              key: 'glass-fixture',
              name: '网页首页',
              entry: 'index.html',
              importedAt: '',
              entrySha256: '',
            ),
          ),
        );
        final error = find.text('HTML 源无法显示');
        expect(error, findsOneWidget);
        await capture(tester, 'browser-error', brightness);
        expect(glassAbove(error), findsOneWidget);
        expect(find.byType(GlassChromeSurface), findsOneWidget);
        expect(
          tester
              .widget<IconButton>(find.byKey(const ValueKey('webhome-reload')))
              .onPressed,
          isNull,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
