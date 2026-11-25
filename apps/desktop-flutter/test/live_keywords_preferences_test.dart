import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/services/ui_preferences_store.dart';
import 'package:webhtv_pc/state/app_state.dart';

void main() {
  late Directory temp;
  late String settingsPath;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('webhtv-live-keywords-');
    settingsPath = '${temp.path}${Platform.pathSeparator}settings.json';
  });

  tearDown(() {
    temp.deleteSync(recursive: true);
  });

  Map<String, dynamic> readRaw() =>
      jsonDecode(File(settingsPath).readAsStringSync()) as Map<String, dynamic>;

  test(
    'unset keywords use defaults without becoming explicit on other saves',
    () async {
      final store = UiPreferencesStore(path: settingsPath);
      await store.load();
      expect(store.liveSiteKeywords, ['直播', 'Live']);
      expect(store.hasExplicitLiveSiteKeywords, isFalse);

      await store.rememberSite('vod');
      expect((readRaw()['ui'] as Map).containsKey('liveSiteKeywords'), isFalse);
      final reloaded = UiPreferencesStore(path: settingsPath);
      await reloaded.load();
      expect(reloaded.liveSiteKeywords, ['直播', 'Live']);
      expect(reloaded.hasExplicitLiveSiteKeywords, isFalse);
    },
  );

  test(
    'setter trims, drops blanks and deduplicates case-insensitively',
    () async {
      final store = UiPreferencesStore(path: settingsPath);
      await store.load();
      final input = [' 直播 ', '', '  ', ' Live ', 'live', '直播', ' 虎牙 '];
      expect(await store.setLiveSiteKeywords(input), isTrue);
      input.add('不应跟随输入变化');
      expect(store.liveSiteKeywords, ['直播', 'Live', '虎牙']);
      expect(store.hasExplicitLiveSiteKeywords, isTrue);
      expect((readRaw()['ui'] as Map)['liveSiteKeywords'], [
        '直播',
        'Live',
        '虎牙',
      ]);
    },
  );

  test('persisted keywords survive reload and preserve sibling settings', () async {
    File(settingsPath).writeAsStringSync(
      jsonEncode({
        'ui': {'historyAggregation': 'title'},
        'sync': {'enabled': true},
      }),
    );
    final store = UiPreferencesStore(path: settingsPath);
    await store.load();
    expect(await store.setLiveSiteKeywords(['斗鱼', 'Sports']), isTrue);

    final reloaded = UiPreferencesStore(path: settingsPath);
    await reloaded.load();
    expect(reloaded.liveSiteKeywords, ['斗鱼', 'Sports']);
    expect(reloaded.hasExplicitLiveSiteKeywords, isTrue);
    expect(reloaded.historyAggregation, 'title');
    expect((readRaw()['sync'] as Map)['enabled'], isTrue);
    debugPrint(
      'PERSISTENCE_EVIDENCE $settingsPath '
      '${jsonEncode({
        'ui': {'liveSiteKeywords': (readRaw()['ui'] as Map)['liveSiteKeywords']},
      })}',
    );
  });

  test(
    'reading hand-edited keywords normalizes without restoring defaults',
    () async {
      File(settingsPath).writeAsStringSync(
        jsonEncode({
          'ui': {
            'liveSiteKeywords': [' Live ', 'live', '', '  ', ' 虎牙 ', '虎牙', 42],
          },
        }),
      );
      final store = UiPreferencesStore(path: settingsPath);
      await store.load();
      expect(store.liveSiteKeywords, ['Live', '虎牙']);
      expect(store.hasExplicitLiveSiteKeywords, isTrue);
    },
  );

  test('explicit empty keywords stay empty after save and reload', () async {
    final store = UiPreferencesStore(path: settingsPath);
    await store.load();
    expect(await store.setLiveSiteKeywords(const []), isTrue);
    expect(store.liveSiteKeywords, isEmpty);
    expect(store.hasExplicitLiveSiteKeywords, isTrue);
    expect((readRaw()['ui'] as Map)['liveSiteKeywords'], isEmpty);

    final reloaded = UiPreferencesStore(path: settingsPath);
    await reloaded.load();
    expect(reloaded.liveSiteKeywords, isEmpty);
    expect(reloaded.hasExplicitLiveSiteKeywords, isTrue);
    await reloaded.rememberSite('vod');
    expect((readRaw()['ui'] as Map)['liveSiteKeywords'], isEmpty);
  });

  test('whitespace-only keywords are an explicit empty list', () async {
    final store = UiPreferencesStore(path: settingsPath);
    await store.load();
    await store.setLiveSiteKeywords([' ', '']);
    final reloaded = UiPreferencesStore(path: settingsPath);
    await reloaded.load();
    expect(reloaded.liveSiteKeywords, isEmpty);
    expect(reloaded.hasExplicitLiveSiteKeywords, isTrue);
  });

  test('AppState exposes defaults before preferences are attached', () {
    final state = AppState();
    addTearDown(state.dispose);
    expect(state.liveSiteKeywords, ['直播', 'Live']);
  });

  test(
    'failed save keeps session keywords and still notifies like live settings',
    () async {
      final blockedParent = File(
        '${temp.path}${Platform.pathSeparator}blocked',
      );
      blockedParent.writeAsStringSync('not a directory');
      final store = UiPreferencesStore(
        path: '${blockedParent.path}${Platform.pathSeparator}settings.json',
      );
      final state = AppState()..attachUiPreferences(store);
      addTearDown(state.dispose);
      var notifications = 0;
      state.addListener(() => notifications++);

      await state.setLiveSiteKeywords([' 临时 ']);
      expect(state.liveSiteKeywords, ['临时']);
      expect(notifications, 1);
      expect(File(store.path).existsSync(), isFalse);
    },
  );

  test(
    'AppState setter persists normalized values and notifies listeners',
    () async {
      final store = UiPreferencesStore(path: settingsPath);
      await store.load();
      final state = AppState()..attachUiPreferences(store);
      addTearDown(state.dispose);
      var notifications = 0;
      state.addListener(() => notifications++);

      await state.setLiveSiteKeywords([' 自定义 ', '自定义', ' ']);
      expect(state.liveSiteKeywords, ['自定义']);
      expect(notifications, 1);
      final reloaded = UiPreferencesStore(path: settingsPath);
      await reloaded.load();
      expect(reloaded.liveSiteKeywords, ['自定义']);

      await state.setLiveSiteKeywords([]);
      expect(state.liveSiteKeywords, isEmpty);
      expect(notifications, 2);
      expect((readRaw()['ui'] as Map)['liveSiteKeywords'], isEmpty);
    },
  );
}
