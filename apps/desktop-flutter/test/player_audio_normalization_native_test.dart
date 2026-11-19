// ignore_for_file: invalid_use_of_protected_member

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit/ffi/ffi.dart';
import 'package:webhtv_pc/core/mpv_properties.dart';
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

  /// 内核能不能真的挂上归一滤镜是**平台事实**，本仓库选不了：
  ///
  /// - 随包 Windows libmpv（v0.36.0-403 / FFmpeg n6.0）没编进任何 ffmpeg 滤镜，
  ///   裸名写入被内核直接拒（`rc=-9`），`lavfi=[dynaudnorm]` 更糟——属性写成功、
  ///   建链时 `Audio filter initialized failed`，音轨被整条丢掉。见
  ///   `core/mpv_properties.dart` 的 [audioNormalizationAf]。
  /// - Linux 的系统 libmpv（完整 FFmpeg）接受同一个裸名写入并原样回读。
  ///
  /// 所以用例按这个事实分支，两边都只断言"内核到底做了什么"：拒绝时必须给出
  /// 拒绝原因、必须没写进去、并且播放照常。
  Future<bool> tryEnableNormalization() {
    return controller.applyMpvProperties({'af': audioNormalizationAf});
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
    final afApplicable = await f.tryEnableNormalization();
    if (afApplicable) {
      await f.expectAf(audioNormalizationAf);
      await f.open();
      await f.expectAf(audioNormalizationAf);
    } else {
      // 内核没有这个滤镜：只准如实报告，不准写进去、也不准动音轨。
      expect(f.controller.rejectedMpvProperties.single.key, 'af');
      await f.expectAf('');
      await f.open();
      await f.expectAf('');
    }
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
    // 同一内核的第二次写入必须和第一次同口径：不能这次说成功、上次说失败。
    final mutedAfApplied = await f.tryEnableNormalization();
    expect(mutedAfApplied, afApplicable);
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
    final afApplicable = await f.tryEnableNormalization();
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
    // 被拒的写入不许动到已经生效（或本来就为空）的链路。
    await f.expectAf(afApplicable ? audioNormalizationAf : '');
    expect(await f.controller.applyMpvProperties({'af': ''}), isTrue);
    await f.expectAf('');
  });

  test('rapid queued production-controller af writes finish at final preference', () async {
    final f = await _NativeFixture.create();
    await f.open();
    await f.controller.setVolume(43);
    await _eventually(() => f.controller.volume == 43);
    final before = f.controller.volumeState;
    final afApplicable = await f.tryEnableNormalization();
    var queue = Future<void>.value();
    var preference = const PlayerOptions();
    for (var i = 0; i < 20; i++) {
      preference = preference.copyWith(
        audioNormalization: !preference.audioNormalization,
      );
      final af = preference.mpvProperties['af']!;
      queue = queue.then((_) async {
        expect(
          await f.controller.applyMpvProperties({'af': af}),
          af.isEmpty || afApplicable,
          reason: 'af="$af" 在 afApplicable=$afApplicable 的内核上口径不一致',
        );
        expect(await f.native.getProperty('af'), afApplicable ? af : '');
      });
    }
    await queue;
    await f.expectAf(afApplicable ? preference.mpvProperties['af']! : '');
    expect(f.controller.volumeState, before);
    expect(preference.audioNormalization, isFalse);
    debugPrint(
      'NATIVE rapid toggles=20 finalPreference=${preference.audioNormalization} afApplicable=$afApplicable',
    );
  });

  test(
    'AC3 passthrough bypasses PCM normalization while decoded WAV accepts af',
    () async {
      final f = await _NativeFixture.create();
      final afApplicable = await f.tryEnableNormalization();
      expect(await f.controller.applyMpvProperties({'af': ''}), isTrue);
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
      expect(await f.controller.applyPlayerOptions(options), afApplicable);
      await f.open(ac3);
      await f.expectAf(afApplicable ? audioNormalizationAf : '');
      final passthrough = await f.native.getProperty('audio-out-params/format');
      debugPrint('NATIVE AC3 audio-out-params/format=$passthrough');
      expect(passthrough, 'spdif-ac3');
      await f.open();
      await f.expectAf(afApplicable ? audioNormalizationAf : '');
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
