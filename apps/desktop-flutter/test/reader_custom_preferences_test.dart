import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/reader/reader_models.dart';
import 'package:webhtv_pc/services/reader/reader_preferences_store.dart';
import 'package:webhtv_pc/services/reader/reader_tts_controller.dart';
import 'package:webhtv_pc/services/reader/tts_engines.dart';

class _UnusedAudio implements ReaderAudioOutput {
  @override
  Future<void> play(TtsAudio audio) async =>
      throw StateError('Preference editing must not start playback');
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}

void main() {
  test(
    'failed custom rule writes notify the changed in-memory preference',
    () async {
      final temp = Directory.systemTemp.createTempSync('reader-failed-notify-');
      final store = ReaderPreferencesStore('${temp.path}/reader.json');
      store.save(
        ReaderPreferences(
          source: TtsSource.custom,
          custom: const TtsCustomConfig(url: 'initial'),
        ),
      );
      final controller = ReaderTtsController(
        engines: TtsEngines(
          factory: (_) =>
              throw StateError('No synthesis during preference editing'),
        ),
        store: store,
        audio: _UnusedAudio(),
      )..loadPreferences();
      addTearDown(() async {
        await controller.close();
        temp.deleteSync(recursive: true);
      });
      final file = File(store.path);
      expect(file.absolute.path, '${temp.absolute.path}/reader.json');
      file.deleteSync();
      Directory(store.path).createSync();
      final changes = <String?>[];
      controller.addListener(
        () => changes.add(controller.settings.custom?.url),
      );
      await expectLater(
        controller.setCustom(const TtsCustomConfig(url: 'changed')),
        throwsA(isA<FileSystemException>()),
      );
      expect(controller.settings.custom?.url, 'changed');
      expect(changes, ['changed']);
    },
  );
  test(
    'clearing custom speech rule persists without resetting other preferences',
    () async {
      final temp = Directory.systemTemp.createTempSync('reader-custom-clear-');
      final store = ReaderPreferencesStore('${temp.path}/reader.json');
      store.save(
        ReaderPreferences(
          source: TtsSource.custom,
          options: TtsOptions(rate: 1.4, pitch: 0.9, voice: 'kept-voice'),
          timerMinutes: 45,
          custom: const TtsCustomConfig(
            name: 'kept-name',
            url: 'https://old.test/tts?text={{speakText}}',
            contentType: 'audio/wav',
            header: 'X-Example: kept-header',
          ),
        ),
      );
      final controller = ReaderTtsController(
        engines: TtsEngines(
          factory: (_) => throw StateError(
            'Preference editing must not create a speech engine',
          ),
        ),
        store: store,
        audio: _UnusedAudio(),
      )..loadPreferences();
      addTearDown(() async {
        await controller.close();
        temp.deleteSync(recursive: true);
      });
      final changes = <TtsCustomConfig?>[];
      controller.addListener(() => changes.add(controller.settings.custom));

      await controller.setCustom(null);

      expect(controller.settings.custom, isNull);
      expect(changes, [null]);
      final restored = ReaderPreferencesStore(store.path).load();
      expect(restored.custom, isNull);
      expect(restored.source, TtsSource.custom);
      expect(restored.options.rate, 1.4);
      expect(restored.options.pitch, 0.9);
      expect(restored.options.voice, 'kept-voice');
      expect(restored.timerMinutes, 45);

      await controller.setRate(1.6);
      expect(store.load().custom, isNull);
      expect(store.load().options.rate, 1.6);

      await controller.setCustom(
        const TtsCustomConfig(
          name: 'new-name',
          url: 'https://new.test/tts?text={{speakText}}',
          contentType: 'audio/ogg',
          header: 'X-Example: new-header',
        ),
      );
      final updated = store.load();
      expect(updated.custom?.url, 'https://new.test/tts?text={{speakText}}');
      expect(updated.custom?.name, 'new-name');
      expect(updated.custom?.contentType, 'audio/ogg');
      expect(updated.custom?.header, 'X-Example: new-header');
      expect(updated.options.rate, 1.6);
      expect(updated.options.pitch, 0.9);
      expect(updated.options.voice, 'kept-voice');
      expect(updated.timerMinutes, 45);
    },
  );
}
