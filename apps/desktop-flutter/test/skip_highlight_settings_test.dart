import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/skip_plan.dart';
import 'package:webhtv_pc/core/skip_segment_colors.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/intro_skip_options_page.dart';
import 'package:webhtv_pc/ui/player_context_menu.dart';
import 'package:webhtv_pc/ui/player_page.dart';
import 'package:webhtv_pc/ui/theme.dart';

import 'support/player_page_harness.dart';
import 'support/test_fonts.dart';

const _toggleKey = ValueKey('settings-player-skip-highlight');
const _menuKey = ValueKey('player-menu-item-skip_highlight');
const _captureKey = ValueKey('highlight-toggle-evidence');

Future<void> _flush(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 100)),
  );
  await settlePlayerPage(tester);
}

Future<void> _reveal(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    // The settings page is lazy; controls below the fold are not built yet.
    await tester.scrollUntilVisible(
      finder,
      200,
      scrollable: find.byType(Scrollable).first,
    );
  }
  expect(finder, findsOneWidget);
  await tester.ensureVisible(finder);
  await settlePlayerPage(tester, times: 2);
}

Future<void> _expectPersisted(
  WidgetTester tester,
  AppState state,
  bool expected,
) async {
  final raw =
      jsonDecode(File(state.paths.settingsPath).readAsStringSync()) as Map;
  expect(raw['player']['showSkipSegmentHighlights'], expected);
  final reloaded = AppState(paths: state.paths, log: LogService());
  await tester.runAsync(() => reloaded.bootstrap());
  expect(reloaded.playerOptions, state.playerOptions);
  reloaded.dispose();
}

void main() {
  setUpAll(() async {
    await loadFixtureFonts(cjkFamily: 'Noto Sans CJK SC');
    await loadFixtureFonts(cjkFamily: 'Roboto');
  });

  for (final brightness in Brightness.values) {
    testWidgets('设置高亮开关 ${brightness.name} 实时落盘重载且不改跳过与颜色', (tester) async {
      final temp = Directory.systemTemp.createTempSync(
        'webhtv-highlight-settings',
      );
      final state = AppState(
        paths: AppPaths.resolve(
          overrides: {
            'config': '${temp.path}/config',
            'data': '${temp.path}/data',
            'cache': '${temp.path}/cache',
            'state': '${temp.path}/logs',
          },
        ),
        log: LogService(),
      );
      addTearDown(() {
        state.dispose();
        temp.deleteSync(recursive: true);
      });
      await tester.runAsync(() async {
        await state.bootstrap();
        await state.setPlayerOptions(
          state.playerOptions.copyWith(
            skipMode: SkipMode.auto,
            skipKinds: SkipKindBits.intro | SkipKindBits.outro,
            skipSegmentColors: const SkipSegmentColors(intro: 0xFF123456),
          ),
        );
      });
      final before = state.playerOptions;
      tester.view.physicalSize = const Size(900, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final theme = buildAppTheme(brightness);
      await tester.pumpWidget(
        MaterialApp(
          theme: theme.copyWith(
            textTheme: theme.textTheme.apply(fontFamily: 'Noto Sans CJK SC'),
          ),
          builder: (_, child) =>
              RepaintBoundary(key: _captureKey, child: child!),
          home: IntroSkipOptionsPage(state: state),
        ),
      );
      await _reveal(tester, find.byKey(_toggleKey));
      expect(find.text('显示片段高亮'), findsOneWidget);
      expect(find.text('仅显示或隐藏进度条颜色，不影响识别和自动跳过'), findsOneWidget);
      expect(
        tester.widget<SwitchListTile>(find.byKey(_toggleKey)).value,
        isTrue,
      );
      await tester.tap(find.byKey(_toggleKey));
      await _flush(tester);
      expect(
        tester.widget<SwitchListTile>(find.byKey(_toggleKey)).value,
        isFalse,
      );
      expect(
        state.playerOptions,
        before.copyWith(showSkipSegmentHighlights: false),
      );
      await _expectPersisted(tester, state, false);
      if (Platform.environment['CAPTURE_HIGHLIGHT_TOGGLE'] == '1') {
        await Scrollable.ensureVisible(
          tester.element(find.text('片段颜色')),
          alignment: 0,
        );
        await tester.pumpAndSettle();
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(_captureKey),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File(
            '../../docs/phase9/evidence/skip-segments/highlight-toggle-${brightness.name}-after.png',
          );
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.tap(find.byKey(_toggleKey));
      await _flush(tester);
      expect(state.playerOptions, before);
      await _expectPersisted(tester, state, true);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('真实右键高亮开关不关菜单且就地回显，与设置往返共享持久化偏好', (tester) async {
    await pumpPlayerPage(
      tester,
      onStateReady: (state) async {
        await state.setPlayerOptions(
          state.playerOptions.copyWith(
            skipMode: SkipMode.auto,
            skipKinds: SkipKindBits.intro | SkipKindBits.outro,
            skipSegmentColors: const SkipSegmentColors(intro: 0xFF123456),
            preloadNext: false,
            skipRemoteEnabled: false,
          ),
        );
      },
    );
    final state = tester.widget<PlayerPage>(find.byType(PlayerPage)).state;
    final before = state.playerOptions;
    await tester.tapAt(const Offset(300, 260), buttons: kSecondaryButton);
    await settlePlayerPage(tester);
    final group = find.descendant(
      of: find.byType(PlayerContextMenu),
      matching: find.text('跳过片段'),
    );
    await _reveal(tester, group);
    await tester.tap(group);
    await settlePlayerPage(tester);
    final item = find.byKey(_menuKey);
    await _reveal(tester, item);
    expect(
      find.descendant(of: item, matching: find.byIcon(Icons.check)),
      findsOneWidget,
    );
    await tester.tap(item);
    await _flush(tester);
    expect(find.byType(PlayerContextMenu), findsOneWidget);
    expect(
      find.descendant(of: item, matching: find.byIcon(Icons.check)),
      findsNothing,
    );
    expect(
      state.playerOptions,
      before.copyWith(showSkipSegmentHighlights: false),
    );
    await _expectPersisted(tester, state, false);
    final colors = find.byKey(const ValueKey('player-menu-item-skip_colors'));
    await _reveal(tester, colors);
    await tester.tap(colors);
    await settlePlayerPage(tester);
    expect(find.byType(PlayerContextMenu), findsNothing);
    expect(find.byType(IntroSkipOptionsPage), findsOneWidget);
    final toggle = find.byKey(_toggleKey);
    await _reveal(tester, toggle);
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
    await tester.tap(toggle);
    await _flush(tester);
    expect(state.playerOptions, before);
    await _expectPersisted(tester, state, true);
    await tester.pageBack();
    await settlePlayerPage(tester);
    await tester.tapAt(const Offset(300, 260), buttons: kSecondaryButton);
    await settlePlayerPage(tester);
    await _reveal(tester, group);
    await tester.tap(group);
    await settlePlayerPage(tester);
    expect(
      find.descendant(of: item, matching: find.byIcon(Icons.check)),
      findsOneWidget,
    );
  });
}
