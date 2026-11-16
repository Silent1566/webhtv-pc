// ignore_for_file: invalid_use_of_protected_member

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit/ffi/ffi.dart';
import 'package:webhtv_pc/core/player_options.dart';
import 'package:webhtv_pc/ui/player_controller.dart';

Future<void> _eventually(FutureOr<bool> Function() check) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!await check()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Native state did not settle within 5 seconds');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<File> _wave(Directory directory) async {
  const rate = 48000;
  const samples = rate * 8;
  final data = ByteData(44 + samples * 2);
  void text(int offset, String value) {
    for (var i = 0; i < value.length; i++) {
      data.setUint8(offset + i, value.codeUnitAt(i));
    }
  }

  text(0, 'RIFF');
  data.setUint32(4, 36 + samples * 2, Endian.little);
  text(8, 'WAVEfmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, rate, Endian.little);
  data.setUint32(28, rate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  text(36, 'data');
  data.setUint32(40, samples * 2, Endian.little);
  for (var i = 0; i < samples; i++) {
    final amplitude = (i ~/ rate).isEven ? 1200 : 12000;
    data.setInt16(
      44 + i * 2,
      (amplitude * math.sin(2 * math.pi * 440 * i / rate)).round(),
      Endian.little,
    );
  }
  return File('${directory.path}/levels.wav')
      .writeAsBytes(data.buffer.asUint8List());
}

class _NativeFixture {
  _NativeFixture(
    this.player,
    this.native,
    this.controller,
    this.directory,
    this.wave,
  );
  final Player player;
  final NativePlayer native;
  final PlayerController controller;
  final Directory directory;
  final File wave;

  static Future<_NativeFixture> create() async {
    final directory = await Directory.systemTemp.createTemp(
      'webhtv-normalization-native-',
    );
    final wave = await _wave(directory);
    final player = Player(
      configuration: const PlayerConfiguration(logLevel: MPVLogLevel.warn),
    );
    final native = player.platform! as NativePlayer;
    await native.setProperty('ao', 'null');
    await native.setProperty('vo', 'null');
    final controller = PlayerController(player: player);
    // Audio-only headless test: do not pump the scheduled VideoController
    // texture setup, or wait for a plugin that flutter test does not host.
    native.isVideoControllerAttached = false;
    final fixture = _NativeFixture(player, native, controller, directory, wave);
    addTearDown(() async {
      final released = Completer<void>();
      native.release.add(() async => released.complete());
      controller.dispose();
      await released.future.timeout(const Duration(seconds: 10));
      await directory.delete(recursive: true);
    });
    return fixture;
  }

  Future<void> open([File? file]) async {
    final outcome = await controller.open(
      (file ?? wave).path,
      timeout: const Duration(seconds: 10),
      awaitFirstFrame: false,
    );
    expect(outcome.succeeded, isTrue, reason: outcome.summary);
    expect(outcome.duration, greaterThan(Duration.zero));
    await _eventually(
      () async => await native.getProperty('current-ao') == 'null',
    );
    expect(await native.getProperty('ao'), 'null');
  }

  Future<void> expectAf(String expected) async {
    final actual = await native.getProperty('af');
    debugPrint(
      'NATIVE af=${actual.isEmpty ? '<empty>' : actual} volume=${await native.getProperty('volume')} mute=${await native.getProperty('mute')}',
    );
    expect(actual, expected);
  }
}

Future<bool> _ffmpegAvailable() async {
  try {
    final result = await Process.run('ffmpeg', ['-version']);
    return result.exitCode == 0;
  } on ProcessException {
    return false;
  }
}

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized(
    libmpv: Platform.environment['WEBHTV_TEST_LIBMPV'],
  );
  final ffmpegAvailable = await _ffmpegAvailable();

  test('real controller enables clears and retains af on media reopen without volume or mute changes', () async {
    final f = await _NativeFixture.create();
    await f.open();
    await f.controller.setVolume(37);
    await _eventually(() => f.controller.volume == 37);
    await f.native.setProperty('mute', 'yes');
    final volumeState = f.controller.volumeState;
    final volume = await f.native.getProperty('volume');
    final mute = await f.native.getProperty('mute');
    await f.expectAf('');
    expect(
      await f.controller.applyMpvProperties(
        const PlayerOptions(audioNormalization: true).mpvProperties,
      ),
      isTrue,
    );
    await f.expectAf('dynaudnorm');
    await f.open();
    await f.expectAf('dynaudnorm');
    expect(await f.controller.applyMpvProperties({'af': ''}), isTrue);
    await f.expectAf('');
    await f.open();
    await f.expectAf('');
    expect(await f.native.getProperty('volume'), volume);
    expect(await f.native.getProperty('mute'), mute);
    expect(f.controller.volumeState, volumeState);
    await f.controller.toggleMute();
    await _eventually(() => f.controller.volume == 0);
    final mutedState = f.controller.volumeState;
    expect(mutedState.muted, isTrue);
    expect(await f.controller.applyMpvProperties({'af': 'dynaudnorm'}), isTrue);
    expect(f.controller.volumeState, mutedState);
    expect(await f.native.getProperty('volume'), '0.000000');
    expect(await f.native.getProperty('mute'), mute);
    expect(await f.controller.applyMpvProperties({'af': ''}), isTrue);
    await f.controller.toggleMute();
    await _eventually(() => f.controller.volume == 37);
    expect(f.controller.volume, 37);
  });

  test('invalid af is rejected by production whitelist and real libmpv returns rc=-9', () async {
    final f = await _NativeFixture.create();
    await f.open();
    expect(await f.controller.applyMpvProperties({'af': 'dynaudnorm'}), isTrue);
    const bogus = 'webhtv_bogus_normalization_filter';
    expect(await f.controller.applyMpvProperties({'af': bogus}), isFalse);
    expect(f.controller.rejectedMpvProperties.single.key, 'af');
    final key = 'af'.toNativeUtf8();
    final value = bogus.toNativeUtf8();
    int rc;
    try {
      rc = f.native.mpv.mpv_set_property_string(
        f.native.ctx,
        key.cast(),
        value.cast(),
      );
    } finally {
      calloc.free(key);
      calloc.free(value);
    }
    debugPrint(
      'NATIVE invalid af rc=$rc rejected=${f.controller.rejectedMpvProperties.single.reason}',
    );
    expect(rc, -9);
    await f.expectAf('dynaudnorm');
    expect(await f.controller.applyMpvProperties({'af': ''}), isTrue);
    await f.expectAf('');
  });

  test('rapid queued production-controller af writes finish at final preference', () async {
    final f = await _NativeFixture.create();
    await f.open();
    await f.controller.setVolume(43);
    await _eventually(() => f.controller.volume == 43);
    final before = f.controller.volumeState;
    var queue = Future<void>.value();
    var preference = const PlayerOptions();
    for (var i = 0; i < 20; i++) {
      preference = preference.copyWith(
        audioNormalization: !preference.audioNormalization,
      );
      final af = preference.mpvProperties['af']!;
      queue = queue.then((_) async {
        expect(await f.controller.applyMpvProperties({'af': af}), isTrue);
        expect(await f.native.getProperty('af'), af);
      });
    }
    await queue;
    await f.expectAf(preference.mpvProperties['af']!);
    expect(f.controller.volumeState, before);
    expect(preference.audioNormalization, isFalse);
    debugPrint(
      'NATIVE rapid toggles=20 finalPreference=${preference.audioNormalization}',
    );
  });

  test(
    'AC3 passthrough bypasses PCM normalization while decoded WAV accepts af',
    () async {
      final f = await _NativeFixture.create();
      final ac3 = File('${f.directory.path}/levels.ac3');
      final generated = await Process.run('ffmpeg', [
        '-hide_banner',
        '-loglevel',
        'error',
        '-y',
        '-i',
        f.wave.path,
        '-c:a',
        'ac3',
        '-b:a',
        '192k',
        ac3.path,
      ]);
      expect(generated.exitCode, 0, reason: '${generated.stderr}');
      const options = PlayerOptions(
        audioPassthrough: true,
        audioNormalization: true,
      );
      expect(await f.controller.applyPlayerOptions(options), isTrue);
      await f.open(ac3);
      await f.expectAf('dynaudnorm');
      final passthrough = await f.native.getProperty('audio-out-params/format');
      debugPrint('NATIVE AC3 audio-out-params/format=$passthrough');
      expect(passthrough, 'spdif-ac3');
      await f.open();
      await f.expectAf('dynaudnorm');
      final decoded = await f.native.getProperty('audio-out-params/format');
      debugPrint('NATIVE WAV audio-out-params/format=$decoded');
      expect(decoded, isNot(startsWith('spdif')));
      expect(await f.controller.applyMpvProperties({'af': ''}), isTrue);
      await f.expectAf('');
    },
    skip: ffmpegAvailable
        ? false
        : 'ffmpeg is unavailable; skipping only AC3 passthrough compatibility',
  );
}
