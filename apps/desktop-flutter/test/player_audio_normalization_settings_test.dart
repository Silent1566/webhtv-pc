import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/player_options.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/ui_preferences_store.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/settings_detail_pages.dart';

const _toggleKey = ValueKey('settings-player-audio-normalization');

void main() {
  late Directory temp;
  late String settingsPath;
  late AppState state;
  late UiPreferencesStore store;
  final initial = const PlayerOptions.defaults().copyWith(
    cache: false,
    autoNext: false,
    audioPassthrough: true,
    demuxerMaxBytesMiB: 256,
  );

  setUp(() async {
    temp = Directory.systemTemp.createTempSync(
      'webhtv-normalization-settings-',
    );
    final paths = AppPaths.resolve(
      overrides: {
        'config': '${temp.path}/config',
        'data': '${temp.path}/data',
        'cache': '${temp.path}/cache',
        'state': '${temp.path}/logs',
      },
    );
    settingsPath = '${temp.path}/settings.json';
    final legacyPlayer = initial.toJson()..remove('audioNormalization');
    File(settingsPath).writeAsStringSync(
      jsonEncode({
        'ui': {'themeMode': 'light', 'lastSiteKey': 'fixture-site'},
        'player': legacyPlayer,
        'sync': {'fixture': 'preserve-me'},
      }),
    );
    store = UiPreferencesStore(path: settingsPath);
    await store.load();
    state = AppState(paths: paths, log: LogService())
      ..attachUiPreferences(store);
  });

  tearDown(() {
    state.dispose();
    expect(temp.absolute.parent.path, Directory.systemTemp.absolute.path);
    expect(
      temp.path.split(Platform.pathSeparator).last,
      startsWith('webhtv-normalization-settings-'),
    );
    temp.deleteSync(recursive: true);
  });

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(home: PlaybackOptionsPage(state: state)),
    );
    await tester.pumpAndSettle();
  }

  Future<void> expectPersisted(bool enabled) async {
    final reloaded = UiPreferencesStore(path: settingsPath);
    await reloaded.load();
    expect(reloaded.playerOptions.audioNormalization, enabled);
    final unrelated = reloaded.playerOptions.toJson()
      ..remove('audioNormalization');
    expect(unrelated, initial.toJson()..remove('audioNormalization'));
    expect(reloaded.themeMode, 'light');
    expect(reloaded.lastSiteKey, 'fixture-site');

    final raw = jsonDecode(File(settingsPath).readAsStringSync()) as Map;
    expect((raw['player'] as Map)['audioNormalization'], enabled);
    expect((raw['ui'] as Map)['themeMode'], 'light');
    expect((raw['ui'] as Map)['lastSiteKey'], 'fixture-site');
    expect(raw['sync'], {'fixture': 'preserve-me'});
  }

  testWidgets('normalization is default-off with a public key and scope help', (
    tester,
  ) async {
    await pumpPage(tester);
    final toggle = find.byKey(_toggleKey);
    expect(toggle, findsOneWidget);
    await tester.ensureVisible(toggle);
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
    expect(state.playerOptions.audioNormalization, isFalse);
    expect(find.text('音量归一'), findsOneWidget);
    expect(find.textContaining('音频直通时不生效'), findsOneWidget);
    final help =
        (tester.widget<SwitchListTile>(toggle).subtitle! as Text).data!;
    for (final term in [
      '全局',
      '实时',
      '已解码音频',
      '默认关闭',
      '动态',
      '延迟',
      '直通',
      '下次播放',
    ]) {
      expect(help, contains(term));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('actual switch saves on and off through AppState and reloads', (
    tester,
  ) async {
    await pumpPage(tester);
    final toggle = find.byKey(_toggleKey);
    expect(toggle, findsOneWidget);
    await tester.ensureVisible(toggle);
    for (final enabled in [true, false]) {
      await tester.runAsync(() async {
        await tester.tap(toggle);
        // The real-zone store write queue must finish before reload.
        await Future<void>.delayed(Duration.zero);
        await expectPersisted(enabled);
      });
      await tester.pumpAndSettle();
      expect(state.playerOptions.audioNormalization, enabled);
      expect(tester.widget<SwitchListTile>(toggle).value, enabled);
      expect(state.playerOptions.audioPassthrough, isTrue);
    }
    expect(tester.takeException(), isNull);
  });

  test(
    'legacy settings default off and real store preserves preferences',
    () async {
      expect(store.playerOptions.audioNormalization, isFalse);
      expect(state.playerOptions.audioNormalization, isFalse);
      for (final enabled in [true, false]) {
        expect(
          await state.setPlayerOptions(
            state.playerOptions.copyWith(audioNormalization: enabled),
          ),
          isTrue,
        );
        await expectPersisted(enabled);
        expect(state.playerOptions.audioNormalization, enabled);
      }
    },
  );
}
