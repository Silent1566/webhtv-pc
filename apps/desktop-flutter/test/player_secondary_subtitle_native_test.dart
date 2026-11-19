// ignore_for_file: invalid_use_of_protected_member

/// 次字幕（`secondary-sid`）在**真实内核**上的行为（迭代 3-D）。
///
/// 这条用例只证明本仓库这份素材能证明的部分，不伪造其余：
/// - **能证明**：引擎一条字幕轨都没有时不给「次字幕」入口
///   （[canOfferSecondarySubtitle] 为 false），往 `secondary-sid` 写一个
///   不存在的轨道号只许降级成 false / 收下，**不许抛**；`no`（关闭）是内核
///   认的合法值，写入通道真的通到 mpv（回读一致）。
/// - **不能证明**：单条/两条**真实**字幕轨时的入口与双字幕叠加。理由不是偷懒，
///   是这份环境测不出来：`flutter test` 里 `player.open` 既不回调也不报错
///   （实测 20 s 内既没有 duration 也没有 tracks 事件，`waitForPlayerInitialization`
///   之后就没动静了），所以「加载一份带字幕轨的容器再看轨道表」这条路在本环境
///   走不通；仓库里也没有现成的多字幕轨素材
///   （`packages/test-fixtures/media/sample.mp4` 用 ffprobe 看是 1 条 h264 +
///   1 条 aac，0 条字幕轨）。界面侧的「单轨不给入口 / 两轨给入口」由
///   `test/player_secondary_subtitle_menu_test.dart` 用假内核实测，
///   core 侧的判定由 `test/player_tracks_test.dart` 覆盖——这里不造一条假的通过。
///
/// 跳过判据与 `player_offset_native_test.dart` 同源（`support/libmpv_guard.dart`）：
/// `flutter test` 默认环境没有内核时跳过，这是「本机不具备」，不是用例坏了。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
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

  test('无字幕轨：不给次字幕入口，写入只降级不抛', () async {
    final player = Player(
      configuration: const PlayerConfiguration(logLevel: MPVLogLevel.warn),
    );
    final native = player.platform! as NativePlayer;
    // 无画面/无声音的头less用例：不要等 flutter test 不提供的插件挂纹理。
    await native.setProperty('ao', 'null');
    await native.setProperty('vo', 'null');
    final controller = PlayerController(player: player);
    // **必须在建完控制器之后**置 false：`PlayerController` 的构造会挂上
    // `VideoController`，而 `setProperty` 默认等 `waitForVideoControllerInitializationIfAttached`
    // ——顺序反了的话，后面每一次属性写入都挂在那里（实测：30 s 到点为止）。
    native.isVideoControllerAttached = false;
    addTearDown(() async {
      final released = Completer<void>();
      native.release.add(() async => released.complete());
      controller.dispose();
      await released.future.timeout(const Duration(seconds: 10));
    });

    // 1) 入口：引擎此刻一条字幕轨都没有 → 次字幕没有可选的第二条，不能给入口。
    final raw = controller.rawSubtitleTrackInfos;
    expect(raw, isEmpty, reason: '前提：没有加载媒体，引擎报 0 条字幕轨');
    expect(
      canOfferSecondarySubtitle(tracks: raw, primaryId: ''),
      isFalse,
      reason: '0 条字幕轨时「次字幕」入口必须不出现',
    );
    expect(
      canOfferSecondarySubtitle(tracks: raw, primaryId: '1'),
      isFalse,
      reason: '主字幕也没有时同样不给入口',
    );

    // 2) 写一个不存在的轨道号：mpv 不校验轨号是否存在，收下或拒掉都允许，
    //    唯一不允许的是抛异常（界面那句「失败只提示不抛」的内核侧依据）。
    final applied = await controller.selectSecondarySubtitle('1');
    final rejected = controller.rejectedMpvProperties;
    debugPrint(
      '无字幕轨：secondary-sid=1 applied=$applied '
      'rejected=${rejected.map((entry) => entry.describe()).join('；')}',
    );
    expect(applied, isA<bool>());
    if (!applied) {
      // 未生效必须留下可读原因，不能悄悄给一个 false（`writeMpvPropertyValue` 的契约）。
      expect(rejected, isNotEmpty, reason: '未生效却没有留下原因');
    }

    // 3) 「关闭」是内核认的合法值：这半条证明写入通道真的通到了 mpv，而不只是
    //    在 Dart 侧拼了个字符串（回读一致才算 applied）。
    expect(
      await controller.selectSecondarySubtitle(secondarySubtitleOffId),
      isTrue,
      reason: '内核不接受 secondary-sid=no：写入通道或白名单有问题',
    );
    expect(
      (await native.getProperty('secondary-sid')).trim(),
      secondarySubtitleOffId,
      reason: '回读必须还是 no',
    );
  }, skip: skipWithoutLibmpv);
}
