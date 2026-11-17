import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/player_options.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/settings_file.dart';
import 'package:webhtv_pc/services/ui_preferences_store.dart';
import 'package:webhtv_pc/state/app_state.dart';

void main() {
  late Directory temp;
  late AppPaths paths;
  setUp(() {
    temp = Directory.systemTemp.createTempSync('webhtv-volume-prefs-');
    paths = AppPaths.resolve(
      overrides: {
        'config': '${temp.path}/config',
        'data': '${temp.path}/data',
        'cache': '${temp.path}/cache',
        'state': '${temp.path}/logs',
      },
    );
    Directory(paths.configDir).createSync(recursive: true);
  });
  tearDown(() {
    expect(temp.absolute.parent.path, Directory.systemTemp.absolute.path);
    expect(
      temp.path.split(Platform.pathSeparator).last,
      startsWith('webhtv-volume-prefs-'),
    );
    temp.deleteSync(recursive: true);
  });
  Future<UiPreferencesStore> load() async {
    final store = UiPreferencesStore(path: paths.settingsPath);
    await store.load();
    return store;
  }

  test('loaded explicit volume survives unrelated UI persistence', () async {
    File(paths.settingsPath).writeAsStringSync(
      jsonEncode({
        'ui': {'playerVolume': 37, 'playerResumeVolume': 37},
        'sync': {'fixture': 'keep'},
      }),
    );
    final store = await load();
    await store.rememberThemeMode('light');
    final raw = readSettingsRootSync(paths.settingsPath);
    expect((raw['ui'] as Map)['playerVolume'], 37);
    expect(raw['sync'], {'fixture': 'keep'});
  });

  test('missing preference defaults to 100 without materializing it on unrelated save', () async {
    final store = await load();
    expect(store.playerVolume, 100);
    await store.rememberThemeMode('light');
    expect(
      (readSettingsRootSync(paths.settingsPath)['ui'] as Map).containsKey(
        'playerVolume',
      ),
      false,
    );
  });

  test(
    'explicit 37 then zero round trips with last nonzero resume value',
    () async {
      final store = await load();
      expect(await store.rememberPlayerVolume(37), true);
      expect((await load()).playerVolume, 37);
      expect(await store.rememberPlayerVolume(0), true);
      final restored = await load();
      expect(restored.playerVolume, 0);
      expect(restored.playerResumeVolume, 37);
    },
  );

  test('malformed and nonfinite persisted values fall back while finite values clamp', () async {
    for (final entry in <(Object?, double)>[
      (null, 100),
      ('37', 100),
      (true, 100),
      (<Object>[], 100),
      (<String, Object>{}, 100),
      (-8, 0),
      (180, 100),
      (0, 0),
      (37.5, 37.5),
    ]) {
      File(paths.settingsPath).writeAsStringSync(
        jsonEncode({
          'ui': {'playerVolume': entry.$1},
        }),
      );
      expect((await load()).playerVolume, entry.$2, reason: 'raw=${entry.$1}');
    }
    File(paths.settingsPath).writeAsStringSync(
      '{"ui":{"playerVolume":1e400,"playerResumeVolume":-1e400}}',
    );
    final restored = await load();
    expect(restored.playerVolume, 100);
    expect(restored.playerResumeVolume, 100);
  });

  test('nonfinite edits retain last preference and do not poison subsequent writes', () async {
    final store = await load();
    await store.rememberPlayerVolume(37);
    for (final invalid in [
      double.nan,
      double.infinity,
      double.negativeInfinity,
    ]) {
      expect(await store.rememberPlayerVolume(invalid), false);
    }
    expect((await load()).playerVolume, 37);
    await store.rememberPlayerVolume(23);
    expect((await load()).playerVolume, 23);
  });

  test('rapid changes and interleaved settings writers retain final volume and other sections', () async {
    final store = await load();
    final state = AppState(paths: paths, log: LogService())
      ..attachUiPreferences(store);
    addTearDown(state.dispose);
    var notifications = 0;
    state.addListener(() => notifications++);
    final pending = <Future<bool>>[];
    for (var i = 0; i < 40; i++) {
      pending.add(state.setPlayerVolume(i.toDouble()));
      expect(
        writeSettingsSectionSync(
          path: paths.settingsPath,
          writer: SettingsWriter.sync,
          mutate: (root) {
            root['sync'] = {'revision': i};
            return true;
          },
        ).ok,
        true,
      );
    }
    pending.add(
      store.rememberPlayerOptions(
        const PlayerOptions(audioNormalization: true),
      ),
    );
    pending.add(store.rememberThemeMode('light'));
    pending.add(state.setPlayerVolume(0));
    expect(await Future.wait(pending), everyElement(true));
    final restored = await load();
    expect(restored.playerVolume, 0);
    expect(restored.playerResumeVolume, 39);
    expect(restored.themeMode, 'light');
    expect(restored.playerOptions.audioNormalization, true);
    expect(readSettingsRootSync(paths.settingsPath)['sync'], {'revision': 39});
    expect(
      notifications,
      0,
      reason: 'volume persistence must not rebuild playback and gesture state',
    );
  });
}
