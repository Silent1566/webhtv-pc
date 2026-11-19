// ignore_for_file: invalid_use_of_protected_member
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:webhtv_pc/ui/player_controller.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/ui_preferences_store.dart';

import 'support/libmpv_guard.dart';

class _VolumeIO extends PlatformPlayer {
  _VolumeIO() : super(configuration: const PlayerConfiguration());
  Completer<void>? gate;
  final writes = <double>[];
  final openedVolumes = <double>[];
  @override
  Future<void> setVolume(double value) async {
    writes.add(value);
    await gate?.future;
    state = state.copyWith(volume: value);
    volumeController.add(value);
  }

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    openedVolumes.add(state.volume);
    state = state.copyWith(
      duration: const Duration(seconds: 100),
      playing: play,
    );
    volumeController.add(100);
    durationController.add(state.duration);
    playingController.add(play);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('real native player restores reloaded 37 and zero before playback and keeps them on reopen', () async {
    MediaKit.ensureInitialized(
      libmpv: Platform.environment['WEBHTV_TEST_LIBMPV'],
    );
    final temp = Directory.systemTemp.createTempSync('webhtv-volume-native-');
    addTearDown(() {
      expect(temp.absolute.parent.path, Directory.systemTemp.absolute.path);
      expect(
        temp.path.split(Platform.pathSeparator).last,
        startsWith('webhtv-volume-native-'),
      );
      temp.deleteSync(recursive: true);
    });
    final paths = AppPaths.resolve(
      overrides: {
        'config': '${temp.path}/config',
        'data': '${temp.path}/data',
        'cache': '${temp.path}/cache',
        'state': '${temp.path}/logs',
      },
    );
    final bytes = ByteData(44 + 32000);
    void text(int offset, String value) {
      for (var i = 0; i < value.length; i++) {
        bytes.setUint8(offset + i, value.codeUnitAt(i));
      }
    }

    text(0, 'RIFF');
    bytes.setUint32(4, 32036, Endian.little);
    text(8, 'WAVEfmt ');
    bytes.setUint32(16, 16, Endian.little);
    bytes.setUint16(20, 1, Endian.little);
    bytes.setUint16(22, 1, Endian.little);
    bytes.setUint32(24, 8000, Endian.little);
    bytes.setUint32(28, 16000, Endian.little);
    bytes.setUint16(32, 2, Endian.little);
    bytes.setUint16(34, 16, Endian.little);
    text(36, 'data');
    bytes.setUint32(40, 32000, Endian.little);
    final wave = File('${temp.path}/silence.wav')
      ..writeAsBytesSync(bytes.buffer.asUint8List());
    final store = UiPreferencesStore(path: paths.settingsPath);
    await store.load();
    await store.rememberPlayerVolume(37);
    for (final volume in [37.0, 0.0]) {
      await store.rememberPlayerVolume(volume);
      final restored = UiPreferencesStore(path: paths.settingsPath);
      await restored.load();
      final player = Player();
      final native = player.platform! as NativePlayer;
      await native.setProperty('ao', 'null');
      await native.setProperty('vo', 'null');
      final changes = <double>[];
      final controller = PlayerController(
        player: player,
        initialVolume: restored.playerVolume,
        initialResumeVolume: restored.playerResumeVolume,
        onVolumeChanged: changes.add,
      );
      native.isVideoControllerAttached = false;
      addTearDown(() async {
        final released = Completer<void>();
        native.release.add(() async => released.complete());
        controller.dispose();
        await released.future.timeout(const Duration(seconds: 10));
      });
      for (var i = 0; i < 2; i++) {
        expect(
          (await controller.open(wave.path, awaitFirstFrame: false)).succeeded,
          true,
        );
        expect(double.parse(await native.getProperty('volume')), volume);
        expect(controller.volume, volume);
      }
      expect(changes, isEmpty);
      if (volume == 0) {
        await controller.toggleMute();
        expect(double.parse(await native.getProperty('volume')), 37);
        expect(changes, [37]);
      }
    }
  }, skip: libmpvUnavailableReason);
  PlayerController create(
    _VolumeIO media, {
    double initialVolume = 100,
    double resume = 100,
    void Function(double)? remember,
  }) {
    final controller = PlayerController(
      player: Player(platformPlayer: media),
      initialVolume: initialVolume,
      initialResumeVolume: resume,
      onVolumeChanged: remember,
    );
    addTearDown(() async {
      controller.dispose();
      await Future<void>.delayed(Duration.zero);
    });
    return controller;
  }

  test(
    'explicit volume updates before engine completion and last input wins',
    () async {
      final media = _VolumeIO()..gate = Completer<void>();
      final values = <double>[];
      final controller = create(media, remember: values.add);
      final first = controller.setVolume(37);
      final last = controller.setVolume(18);
      expect(controller.volume, 18);
      expect(values, [37, 18]);
      media.gate!.complete();
      await Future.wait([first, last]);
      expect(controller.volume, 18);
      expect(media.state.volume, 18);
    },
  );

  test(
    'initial zero and 37 apply before autoplay and media reopen never persists',
    () async {
      for (final volume in [0.0, 37.0]) {
        final media = _VolumeIO();
        final values = <double>[];
        final controller = create(
          media,
          initialVolume: volume,
          resume: 37,
          remember: values.add,
        );
        expect(controller.volume, volume);
        for (var i = 0; i < 2; i++) {
          final result = await controller.open(
            'https://fixture.test/$i.mp4',
            awaitFirstFrame: false,
          );
          expect(result.succeeded, true);
          expect(controller.volume, volume);
        }
        expect(media.openedVolumes, [volume, volume]);
        expect(values, isEmpty);
      }
    },
  );

  test(
    'edits during startup restoration reach engine before first playback',
    () async {
      final media = _VolumeIO()..gate = Completer<void>();
      final controller = create(media, initialVolume: 37);
      final opening = controller.open(
        'https://fixture.test/start.mp4',
        awaitFirstFrame: false,
      );
      await Future<void>.delayed(Duration.zero);
      final changed = controller.setVolume(18);
      media.gate!.complete();
      await changed;
      expect((await opening).succeeded, true);
      expect(media.openedVolumes, [18.0]);
    },
  );

  test(
    'live cancellation settles while startup volume engine write is blocked',
    () async {
      final media = _VolumeIO()..gate = Completer<void>();
      final controller = create(media, initialVolume: 37);
      final opening = controller.open(
        'https://fixture.test/live.mp4',
        awaitFirstFrame: false,
        isCurrent: () => true,
      );
      await Future<void>.delayed(Duration.zero);
      controller.dispose();
      try {
        final outcome = await opening.timeout(
          const Duration(milliseconds: 100),
        );
        expect(outcome.succeeded, false);
        expect(media.openedVolumes, isEmpty);
      } finally {
        media.gate!.complete();
        await opening;
      }
    },
  );

  test(
    'engine default and nonfinite reports cannot replace explicit user intent',
    () async {
      final media = _VolumeIO();
      final values = <double>[];
      final controller = create(media, remember: values.add);
      await controller.setVolume(37);
      for (final report in [100.0, 0.0, double.nan, double.infinity]) {
        media.volumeController.add(report);
      }
      await Future<void>.delayed(Duration.zero);
      expect(controller.volumeState, (
        volume: 37.0,
        resumeVolume: 37.0,
        muted: false,
      ));
      expect(values, [37]);
    },
  );

  test('mute entries and restored replacement retain nonzero resume volume without persisting restoration', () async {
    final media = _VolumeIO();
    final values = <double>[];
    final controller = create(media, remember: values.add);
    await controller.setVolume(37);
    await controller.toggleMute();
    expect(controller.volumeState, (
      volume: 0.0,
      resumeVolume: 37.0,
      muted: true,
    ));
    final replacementValues = <double>[];
    final replacement = create(_VolumeIO(), remember: replacementValues.add);
    await replacement.restoreVolumeState(controller.volumeState);
    expect(replacementValues, isEmpty);
    await replacement.toggleMute();
    expect(replacement.volumeState, (
      volume: 37.0,
      resumeVolume: 37.0,
      muted: false,
    ));
    expect(replacementValues, [37]);
    await controller.toggleMute();
    expect(values, [37, 0, 37]);
  });

  test(
    'invalid input retains last valid state and finite boundaries clamp',
    () async {
      final controller = create(_VolumeIO());
      await controller.setVolume(37);
      for (final bad in [
        double.nan,
        double.infinity,
        double.negativeInfinity,
      ]) {
        await controller.setVolume(bad);
      }
      expect(controller.volume, 37);
      await controller.setVolume(-1);
      expect(controller.volume, 0);
      await controller.setVolume(101);
      expect(controller.volume, 100);
    },
  );
}
