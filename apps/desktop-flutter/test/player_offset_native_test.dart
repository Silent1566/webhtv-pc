// ignore_for_file: invalid_use_of_protected_member

/// 偏移在**真实内核**上的行为（`sub-delay` / `audio-delay`）。
///
/// 纯逻辑用例（`player_offset_ui_test.dart`）只能证明「写了什么值、失败怎么降级」，
/// 证明不了 mpv 收不收这条写入、回读回来是什么形状。这一条补的就是那半截：
/// 内核收下、回读落在 1 ms 容差内、`setTrackOffset` 如实返回 true。
///
/// 跳过判据与 `player_audio_normalization_native_test.dart` 同源
/// （`support/libmpv_guard.dart`）：`flutter test` 默认环境没有内核时跳过，
/// 这是「本机不具备」，不是用例坏了。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:webhtv_pc/core/mpv_properties.dart';
import 'package:webhtv_pc/core/player_options.dart';
import 'package:webhtv_pc/core/player_tracks.dart';
import 'package:webhtv_pc/ui/player_controller.dart';

import 'support/libmpv_guard.dart';

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  final skipWithoutLibmpv = libmpvUnavailableReason;
  if (skipWithoutLibmpv == null) {
    MediaKit.ensureInitialized(
      libmpv: Platform.environment['WEBHTV_TEST_LIBMPV'],
    );
  }

  test('真实内核接受 sub-delay / audio-delay，回读落在 1 ms 容差内', () async {
    final player = Player(
      configuration: const PlayerConfiguration(logLevel: MPVLogLevel.warn),
    );
    final native = player.platform! as NativePlayer;
    await native.setProperty('ao', 'null');
    await native.setProperty('vo', 'null');
    final controller = PlayerController(player: player);
    // 无画面/无声音的头less用例：不要等 flutter test 不提供的插件挂纹理。
    native.isVideoControllerAttached = false;
    addTearDown(() async {
      final released = Completer<void>();
      native.release.add(() async => released.complete());
      controller.dispose();
      await released.future.timeout(const Duration(seconds: 10));
    });

    // 1) 控制器的单条写入路径：内核不认这条属性时必须如实给 false，不能抛。
    expect(
      await controller.setTrackOffset(
        TrackOffset(kind: TrackOffsetKind.subtitle, milliseconds: 500),
      ),
      isTrue,
      reason: '内核不接受 sub-delay 写入',
    );
    expect(
      mpvDelayReadbackMatches(500, await native.getProperty('sub-delay')),
      isTrue,
      reason: '回读必须落在 1 ms 容差内',
    );
    expect(controller.rejectedMpvProperties, isEmpty);

    expect(
      await controller.setTrackOffset(
        TrackOffset(kind: TrackOffsetKind.audio, milliseconds: -250),
      ),
      isTrue,
      reason: '内核不接受 audio-delay 写入',
    );
    expect(
      mpvDelayReadbackMatches(-250, await native.getProperty('audio-delay')),
      isTrue,
    );

    // 2) 整表注入走的是通用回读（`applyPlayerOptions` → `applyMpvProperties`）：
    //    容差口径不对的话，启动/切集时这里会被判成「没写进去」。
    //    只挑这两个键：别的属性（hwdec/cache…）与本改动无关，不该拖进来陪跑。
    const offsets = PlayerOptions(subtitleOffsetMs: -250, audioOffsetMs: 300);
    final delayOnly = <String, String>{
      for (final entry in offsets.mpvProperties.entries)
        if (TrackOffsetKind.fromMpvPropertyKey(entry.key) != null)
          entry.key: entry.value,
    };
    expect(delayOnly, <String, String>{
      'sub-delay': '-0.250',
      'audio-delay': '0.300',
    });
    expect(await controller.applyMpvProperties(delayOnly), isTrue);
    expect(
      mpvDelayReadbackMatches(-250, await native.getProperty('sub-delay')),
      isTrue,
    );
    expect(
      mpvDelayReadbackMatches(300, await native.getProperty('audio-delay')),
      isTrue,
    );
    expect(controller.rejectedMpvProperties, isEmpty);

    // 3) 归零：`0.000` 也要真的写进内核（换集后不能残留上一集的偏移）。
    expect(
      await controller.setTrackOffset(
        TrackOffset(kind: TrackOffsetKind.subtitle),
      ),
      isTrue,
    );
    expect(
      mpvDelayReadbackMatches(0, await native.getProperty('sub-delay')),
      isTrue,
    );
  }, skip: skipWithoutLibmpv);
}
