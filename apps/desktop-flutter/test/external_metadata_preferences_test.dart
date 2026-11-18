import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/services/ui_preferences_store.dart';

void main() {
  late Directory directory;
  setUp(() { directory = Directory.systemTemp.createTempSync('extmeta-prefs'); });
  tearDown(() => directory.deleteSync(recursive:true));
  test('fallback defaults on and explicit false survives reload without disturbing other settings', () async {
    final path = '${directory.path}/settings.json';
    File(path).writeAsStringSync(jsonEncode({'ui':{'themeMode':'light'}, 'custom':{'keep':1}}));
    final store = UiPreferencesStore(path:path);
    await store.load();
    expect(store.externalMetaEnabled, isTrue);
    expect(await store.rememberExternalMetaEnabled(false), isTrue);
    final reopened = UiPreferencesStore(path:path);
    await reopened.load();
    expect(reopened.externalMetaEnabled, isFalse);
    final payload=jsonDecode(File(path).readAsStringSync()) as Map;
    expect(payload['ui']['externalMetaEnabled'], isFalse);
    expect(payload['ui']['themeMode'], 'light');
    expect(payload['custom']['keep'], 1);
    await reopened.rememberExternalMetaEnabled(true);
    final third = UiPreferencesStore(path:path);
    await third.load();
    expect(third.externalMetaEnabled,isTrue);
  });
  test('invalid nonboolean value does not disable fallback', () async {
    final path = '${directory.path}/settings.json';
    File(path).writeAsStringSync('{"ui":{"externalMetaEnabled":"false"}}');
    final store=UiPreferencesStore(path:path);
    await store.load();
    expect(store.externalMetaEnabled, isTrue);
  });
}
