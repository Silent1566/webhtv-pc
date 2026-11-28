import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/diagnostics_pages.dart';
import 'package:webhtv_pc/ui/glass_dialog.dart';
import 'package:webhtv_pc/ui/health_filter_controls.dart';
import 'package:webhtv_pc/ui/push_dialog.dart';
import 'package:webhtv_pc/ui/theme.dart';
import 'package:webhtv_pc/ui/wallpaper_backdrop.dart';

import 'support/test_fonts.dart';

const _section = ValueKey('settings-category-danmaku');
const _initialSection = ValueKey('settings-category-preferences');
const _dialogUrl = ValueKey('push-dialog-url');
const _dialogTitle = ValueKey('push-dialog-title');
const _open = ValueKey('open-push');

void main() {
  late Directory temp;
  late AppState state;
  late LogService log;
  final captureKey = GlobalKey();
  final stage = Platform.environment['SETTINGS_BORDERLESS_STAGE'];
  final output = Platform.environment['SETTINGS_BORDERLESS_CAPTURE'];

  setUpAll(() async {
    if (stage != null) {
      expectFontsAvailableOrSkip();
      expect(firstExisting(iconFontCandidates()), isNotNull);
    }
    for (final alias in ['Roboto', 'Noto Sans CJK SC', 'Microsoft YaHei UI']) {
      await loadFixtureFonts(cjkFamily: alias);
    }
  });
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('settings-borderless');
    log = LogService();
    state = AppState(
      paths: AppPaths.resolve(
        overrides: {
          for (final key in ['config', 'data', 'cache', 'state'])
            key: '${temp.path}/$key',
        },
      ),
      log: log,
    );
    await state.bootstrap();
  });
  tearDown(() async {
    state.dispose();
    await log.dispose();
    await temp.delete(recursive: true);
  });

  Future<void> mount(
    WidgetTester tester,
    Brightness brightness,
    Widget page, {
    Size size = const Size(1024, 640),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(brightness),
        builder: (_, child) => RepaintBoundary(key: captureKey, child: child!),
        home: WallpaperBackdrop(url: null, builder: (_, _) => page),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> capture(
    WidgetTester tester,
    String scenario,
    Brightness b,
  ) async {
    if (stage == null || output == null) return;
    await tester.runAsync(() async {
      final image = await tester
          .renderObject<RenderRepaintBoundary>(find.byKey(captureKey))
          .toImage();
      try {
        final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        await File('$output/$scenario-${b.name}-$stage.png')
            .writeAsBytes(data.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    });
  }

  Material category(WidgetTester tester, Key key) => tester.widget<Material>(
    find.descendant(of: find.byKey(key), matching: find.byType(Material)).first,
  );

  for (final brightness in Brightness.values) {
    testWidgets('settings hub at 1024x640 in ${brightness.name}', (
      tester,
    ) async {
      await mount(
        tester,
        brightness,
        Scaffold(
          body: SettingsPage(
            state: state,
            initialCategory: SettingsCategory.danmaku,
            shellUnderlap: true,
          ),
        ),
      );
      expect(find.text('调整日常偏好、播放体验与连接服务。'), findsOneWidget);
      expect(find.byKey(_section), findsOneWidget);
      await capture(tester, 'settings-hub', brightness);
    });

    testWidgets(
      'compact category has a fill only when selected in ${brightness.name}',
      (tester) async {
        await mount(
          tester,
          brightness,
          Scaffold(body: SettingsPage(state: state)),
          size: const Size(480, 640),
        );
        await capture(tester, 'settings-compact', brightness);
        expect(category(tester, _section).color, Colors.transparent);
        expect(
          category(tester, _initialSection).color,
          isNot(Colors.transparent),
        );
        expect(
          (category(tester, _section).shape! as RoundedRectangleBorder).side,
          BorderSide.none,
          reason: 'unselected category paints no decorative outline',
        );
        await tester.tap(find.byKey(_section));
        await tester.pumpAndSettle();
        expect(category(tester, _section).color, isNot(Colors.transparent));
        expect(category(tester, _initialSection).color, Colors.transparent);
        expect(
          find.byKey(const ValueKey('settings-category-content-danmaku')),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'push dialog retains Tab, Enter validation and Escape in ${brightness.name}',
      (tester) async {
        await mount(
          tester,
          brightness,
          Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: FilledButton(
                  key: _open,
                  onPressed: () => showGlassDialog<void>(
                    context: context,
                    builder: (_) => PushDialog(
                      state: state,
                      pickLocalFile: () async => null,
                    ),
                  ),
                  child: const Text('打开推送'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.byKey(_open));
        await tester.pumpAndSettle();
        await capture(tester, 'push-dialog', brightness);
        EditableText editable(Key key) => tester.widget<EditableText>(
          find.descendant(
            of: find.byKey(key),
            matching: find.byType(EditableText),
          ),
        );
        InputDecorator decorator(Key key) => tester.widget<InputDecorator>(
          find.descendant(
            of: find.byKey(key),
            matching: find.byType(InputDecorator),
          ),
        );
        expect(editable(_dialogUrl).focusNode.hasFocus, isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pumpAndSettle();
        expect(editable(_dialogTitle).focusNode.hasFocus, isTrue);
        final normal = decorator(_dialogUrl).decoration.enabledBorder!;
        final focused = decorator(_dialogTitle).decoration.focusedBorder!;
        expect(normal.borderSide, BorderSide.none);
        expect(focused.borderSide.style, BorderStyle.solid);
        expect(focused.borderSide.width, greaterThan(0));
        await tester.enterText(find.byKey(_dialogTitle), '只填剧名');
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pumpAndSettle();
        final play = find.byKey(const ValueKey('push-dialog-play'));
        expect(
          Focus.of(
            tester.element(
              find.descendant(of: play, matching: find.text('打开详情')),
            ),
          ).hasFocus,
          isTrue,
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(find.textContaining('推送需要一个播放地址'), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byKey(_dialogUrl), findsNothing);
        expect(state.pendingPush, isNull);
      },
    );
  }

  testWidgets(
    'health filter changes selection without a static button outline',
    (tester) async {
      const key = ValueKey('health-filter-test');
      final value = ValueNotifier('全部');
      addTearDown(value.dispose);
      await mount(
        tester,
        Brightness.dark,
        Scaffold(
          body: Center(
            child: Builder(
              builder: (context) => ValueListenableBuilder(
                valueListenable: value,
                builder: (context, selected, _) => healthFilterSelect(
                  context: context,
                  key: key,
                  label: '状态',
                  value: selected,
                  options: const ['全部', '失败'],
                  onChanged: (next) => value.value = next,
                ),
              ),
            ),
          ),
        ),
      );
      final filter = find.byKey(key);
      await tester.tap(filter);
      await tester.pumpAndSettle();
      await tester.tap(find.text('失败'));
      await tester.pumpAndSettle();
      expect(find.text('状态：失败'), findsOneWidget);
      final material = tester.widget<Material>(
        find.descendant(of: filter, matching: find.byType(Material)).first,
      );
      expect((material.shape! as OutlinedBorder).side, BorderSide.none);
    },
  );
}
