import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/ai_config.dart';
import 'package:webhtv_pc/core/tmdb_config.dart';
import 'package:webhtv_pc/services/ai_config_store.dart';
import 'package:webhtv_pc/services/settings_file.dart';
import 'package:webhtv_pc/services/tmdb_config_store.dart';
import 'package:webhtv_pc/services/ui_preferences_store.dart';

class _ReadBoundaryFile implements File {
  _ReadBoundaryFile(this.delegate, this.snapshotRead, this.peerWrites);
  final File delegate;
  final Completer<void> snapshotRead;
  final Completer<void> peerWrites;
  @override
  String get path => delegate.path;
  @override
  Directory get parent => delegate.parent;
  @override
  Future<bool> exists() => delegate.exists();
  @override
  bool existsSync() => delegate.existsSync();
  @override
  Future<String> readAsString({Encoding encoding = utf8}) async {
    final raw = await delegate.readAsString(encoding: encoding);
    if (!snapshotRead.isCompleted) snapshotRead.complete();
    await peerWrites.future;
    return raw;
  }

  @override
  String readAsStringSync({Encoding encoding = utf8}) =>
      delegate.readAsStringSync(encoding: encoding);
  @override
  Future<FileSystemEntity> delete({bool recursive = false}) =>
      delegate.delete(recursive: recursive);
  @override
  void deleteSync({bool recursive = false}) =>
      delegate.deleteSync(recursive: recursive);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'TMDB autosave cannot overwrite concurrent volume AI or sync updates',
    () async {
      final temp = Directory.systemTemp.createTempSync('settings-atomicity-');
      final path = '${temp.path}/settings.json';
      final file = File(path)
        ..writeAsStringSync(
          jsonEncode({
            'ui': {'playerVolume': 5},
            'future': {'keep': 42},
          }),
        );
      final preferences = UiPreferencesStore(path: path);
      await preferences.load();
      final ai = AiConfigStore(path: path);
      final tmdb = TmdbConfigStore(path: path);
      final snapshotRead = Completer<void>();
      final peerWrites = Completer<void>();
      final controlled = _ReadBoundaryFile(file, snapshotRead, peerWrites);
      final files = {
        for (final suffix in [
          'tmp',
          'tmdb.tmp',
          'ui.tmp',
          'ai.tmp',
          'sync.tmp',
        ])
          '$path.$suffix': File('$path.$suffix'),
      };
      addTearDown(() {
        if (!peerWrites.isCompleted) peerWrites.complete();
        temp.deleteSync(recursive: true);
      });
      final saving = IOOverrides.runZoned(
        () => tmdb.save(const TmdbConfig().copyWith(apiKey: 'tmdb-last-key')),
        createFile: (requested) =>
            requested == path ? controlled : files[requested]!,
      );
      try {
        await Future.any<void>([snapshotRead.future, saving.then((_) {})]);
        expect(await preferences.rememberPlayerVolume(37), isTrue);
        expect(
          await ai.save(AiConfig.fromJson({'apiKey': 'ai-last-key'})),
          isTrue,
        );
        expect(
          writeSettingsSectionSync(
            path: path,
            writer: SettingsWriter.sync,
            mutate: (root) {
              root['sync'] = {'revision': 7};
              return true;
            },
          ).ok,
          isTrue,
        );
      } finally {
        if (!peerWrites.isCompleted) peerWrites.complete();
      }
      expect(await saving, isTrue);
      final restored = jsonDecode(file.readAsStringSync()) as Map;
      expect((restored['ui'] as Map)['playerVolume'], 37);
      expect((restored['ai'] as Map)['apiKey'], 'ai-last-key');
      expect((restored['sync'] as Map)['revision'], 7);
      expect((restored['tmdb'] as Map)['apiKey'], 'tmdb-last-key');
      expect((restored['future'] as Map)['keep'], 42);
    },
  );
}
