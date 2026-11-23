/// 更新偏好存储单测（ADR-0015）：settings.json 只动 update 段。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/app_update.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/update_preferences_store.dart';

void main() {
  late Directory temp;
  late String settingsPath;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('webhtv-update-prefs-');
    final root = temp.path;
    settingsPath = '$root/settings.json';
  });

  tearDown(() => temp.deleteSync(recursive: true));

  UpdatePreferencesStore store() =>
      UpdatePreferencesStore(path: settingsPath, log: LogService());

  test('文件不存在时回落默认值（自动检查关闭、稳定版通道）', () async {
    final subject = store();
    await subject.load();
    expect(subject.loaded, isTrue);
    expect(subject.preferences, AppUpdatePreferences.defaults);
    expect(subject.preferences.autoCheck, isFalse);
    expect(subject.preferences.channel, AppUpdateChannel.stable);
  });

  test('读取已有 update 段，其它段不受影响', () async {
    File(settingsPath).writeAsStringSync(
      jsonEncode({
        'ui': {'themeMode': 'light'},
        'update': {
          'autoCheck': true,
          'channel': 'beta',
          'lastCheckedAt': '2026-11-23T08:30:00.000Z',
          'lastCheckError': 'HTTP 403',
        },
      }),
    );
    final subject = store();
    await subject.load();
    expect(subject.preferences.autoCheck, isTrue);
    expect(subject.preferences.channel, AppUpdateChannel.beta);
    expect(
      subject.preferences.lastCheckedAt,
      DateTime.utc(2026, 11, 23, 8, 30),
    );
    expect(subject.preferences.lastCheckError, 'HTTP 403');
  });

  test('保存只替换 update 段，ui / tmdb 原样保留', () async {
    File(settingsPath).writeAsStringSync(
      jsonEncode({
        'ui': {'themeMode': 'light'},
        'tmdb': {'enabled': true},
      }),
    );
    final subject = store();
    await subject.load();
    final ok = await subject.persist(
      const AppUpdatePreferences(
        autoCheck: true,
        channel: AppUpdateChannel.beta,
      ),
    );
    expect(ok, isTrue);
    final root = jsonDecode(File(settingsPath).readAsStringSync()) as Map;
    expect(root['ui'], {'themeMode': 'light'});
    expect(root['tmdb'], {'enabled': true});
    expect(root['update']['autoCheck'], isTrue);
    expect(root['update']['channel'], 'beta');
  });

  test('值没变时不写盘', () async {
    final original = jsonEncode({
      'ui': {'themeMode': 'dark'},
      'update': {'autoCheck': true, 'channel': 'stable'},
    });
    File(settingsPath).writeAsStringSync(original);
    final subject = store();
    await subject.load();
    final ok = await subject.persist(subject.preferences);
    expect(ok, isTrue);
    expect(File(settingsPath).readAsStringSync(), original);
  });

  test('文件损坏时回落默认值，不抛错', () async {
    File(settingsPath).writeAsStringSync('{ broken json');
    final subject = store();
    await subject.load();
    expect(subject.preferences, AppUpdatePreferences.defaults);
  });
}
