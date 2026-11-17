import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/player_options.dart';
import 'package:webhtv_pc/services/ui_preferences_store.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/player_page.dart';

import 'support/player_page_harness.dart';

Finder get _slider =>
    find.byWidgetPredicate((widget) => widget is Slider && widget.max == 100);

Future<void> _expectStored(
  WidgetTester tester,
  AppState state,
  double volume,
  double resume,
) async {
  await tester.runAsync(() async {
    final restored = UiPreferencesStore(path: state.paths.settingsPath);
    await restored.load();
    expect(restored.playerVolume, volume);
    expect(restored.playerResumeVolume, resume);
  });
}

Future<AppState> _mount(WidgetTester tester, {double? seed}) async {
  late AppState state;
  await pumpPlayerPage(
    tester,
    onStateReady: (s) async {
      state = s;
      if (seed != null) {
        File(s.paths.settingsPath).writeAsStringSync(
          jsonEncode({
            'ui': {'playerVolume': seed, 'playerResumeVolume': 37},
          }),
        );
        final store = UiPreferencesStore(path: s.paths.settingsPath);
        await store.load();
        s.attachUiPreferences(store);
      }
      await s.setPlayerOptions(
        const PlayerOptions(
          doubleClickLeft: PlayerDoubleClickAction.volumeUp,
          doubleClickRight: PlayerDoubleClickAction.volumeDown,
        ),
      );
    },
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await settlePlayerPage(tester);
  });
  return state;
}

void main() {
  testWidgets(
    'new player page restores persisted volume instead of engine default',
    (tester) async {
      final state = await _mount(tester, seed: 37);
      expect(_slider, findsOneWidget);
      expect(tester.widget<Slider>(_slider).value, 37);
      await _expectStored(tester, state, 37, 37);
    },
  );

  testWidgets(
    'slider keyboard and both mute entries persist immediately including zero',
    (tester) async {
      final state = await _mount(tester);
      expect(tester.widget<Slider>(_slider).value, 100);
      tester.widget<Slider>(_slider).onChanged!(37);
      await tester.pump();
      await _expectStored(tester, state, 37, 37);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(tester.widget<Slider>(_slider).value, 42);
      await _expectStored(tester, state, 42, 42);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.tap(find.byTooltip('静音（M）'));
      await tester.pump();
      expect(tester.widget<Slider>(_slider).value, 0);
      await _expectStored(tester, state, 0, 37);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
      await tester.pump();
      expect(tester.widget<Slider>(_slider).value, 37);
      await _expectStored(tester, state, 37, 37);
    },
  );

  testWidgets(
    'left and right double clicks persist through real production callbacks',
    (tester) async {
      final state = await _mount(tester, seed: 37);
      await tester.tapAt(const Offset(300, 280));
      await tester.tapAt(const Offset(300, 280));
      await tester.pump();
      expect(tester.widget<Slider>(_slider).value, 42);
      await _expectStored(tester, state, 42, 42);
      await tester.tapAt(const Offset(980, 280));
      await tester.tapAt(const Offset(980, 280));
      await tester.pump();
      expect(tester.widget<Slider>(_slider).value, 37);
      await _expectStored(tester, state, 37, 37);
    },
  );

  testWidgets(
    'rapid slider edits and leaving page retain last zero across rebuilt page',
    (tester) async {
      final state = await _mount(tester, seed: 37);
      final page = tester.widget<PlayerPage>(find.byType(PlayerPage));
      final change = tester.widget<Slider>(_slider).onChanged!;
      for (final volume in [12.0, 21.0, 48.0, 0.0]) {
        change(volume);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await _expectStored(tester, state, 0, 48);
      await tester.pumpWidget(
        MaterialApp(
          home: PlayerPage(state: state, request: page.request),
        ),
      );
      await settlePlayerPage(tester);
      expect(tester.widget<Slider>(_slider).value, 0);
      await tester.tap(find.byTooltip('取消静音（M）'));
      await tester.pump();
      expect(tester.widget<Slider>(_slider).value, 48);
      await _expectStored(tester, state, 48, 48);
    },
  );
}
