/// 弹幕运动时钟（\`lib/core/danmaku_motion.dart\`）。
///
/// 播放器上报的 `position` 是**离散事件**（media-kit `stream.position` → 整页
/// `setState`），两次上报之间弹幕本来是不动的；用户看到的就是「一格一格跳」。
/// 这个时钟把离散位置插值成每帧连续位置，并守住三条边界：暂停不动、跳转立即
/// 跟随、上报断流时最多外插一段就停，避免弹幕飞出画面半天才对上。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/danmaku_motion.dart';

void main() {
  final t0 = DateTime(2026, 1, 1, 12);

  DateTime at(int ms) => t0.add(Duration(milliseconds: ms));

  group('弹幕运动时钟', () {
    test('播放中按墙钟插值：两次上报之间位置连续前进', () {
      final clock = DanmakuMotionClock()
        ..sync(
          position: const Duration(seconds: 1),
          playing: true,
          rate: 1,
          at: t0,
        );

      expect(clock.sample(t0), const Duration(seconds: 1));
      expect(
        clock.sample(at(16)),
        const Duration(milliseconds: 1016),
      );
      expect(
        clock.sample(at(100)),
        const Duration(milliseconds: 1100),
      );
    });

    test('暂停时位置不再前进', () {
      final clock = DanmakuMotionClock()
        ..sync(
          position: const Duration(seconds: 1),
          playing: false,
          rate: 1,
          at: t0,
        );

      expect(clock.sample(at(16)), const Duration(seconds: 1));
      expect(clock.sample(at(500)), const Duration(seconds: 1));
    });

    test('倍速播放时插值按倍率放大', () {
      final clock = DanmakuMotionClock()
        ..sync(
          position: const Duration(seconds: 1),
          playing: true,
          rate: 2,
          at: t0,
        );

      expect(clock.sample(at(100)), const Duration(milliseconds: 1200));
    });

    test('重复上报同一位置不算重新对表（页面重建不重置基准）', () {
      // 播放器页每次 setState（音量、缓冲、缓冲条…）都会把同一个 position
      // 再传一遍；若每次都把基准时间重置成「现在」，插值就永远停在原地。
      final clock = DanmakuMotionClock()
        ..sync(
          position: const Duration(seconds: 1),
          playing: true,
          rate: 1,
          at: t0,
        )
        ..sync(
          position: const Duration(seconds: 1),
          playing: true,
          rate: 1,
          at: at(16),
        );

      expect(clock.sample(at(32)), const Duration(milliseconds: 1032));
    });

    test('上报位置小幅回退时不倒退（容忍上报抖动）', () {
      final clock = DanmakuMotionClock()
        ..sync(
          position: const Duration(seconds: 1),
          playing: true,
          rate: 1,
          at: t0,
        );
      final live = clock.sample(at(100));
      expect(live, const Duration(milliseconds: 1100));

      clock.sync(
        position: const Duration(milliseconds: 1060),
        playing: true,
        rate: 1,
        at: at(100),
      );

      expect(
        clock.sample(at(100)),
        live,
        reason: '回退小于 reanchorToleranceMs 时保持连续，不往回跳一格',
      );
      // 之后继续前进，而且不会再退回上报值。
      expect(
        clock.sample(at(116)),
        const Duration(milliseconds: 1116),
      );
    });

    test('明显的前跳/回跳（拖动进度条）立即跟随', () {
      final clock = DanmakuMotionClock()
        ..sync(
          position: const Duration(seconds: 1),
          playing: true,
          rate: 1,
          at: t0,
        );
      clock.sample(at(100));

      clock.sync(
        position: const Duration(seconds: 60),
        playing: true,
        rate: 1,
        at: at(100),
      );
      expect(clock.sample(at(100)), const Duration(seconds: 60));

      clock.sync(
        position: const Duration(seconds: 5),
        playing: true,
        rate: 1,
        at: at(200),
      );
      expect(clock.sample(at(200)), const Duration(seconds: 5));
    });

    test('上报断流时最多外插 maxExtrapolationMs', () {
      final clock = DanmakuMotionClock()
        ..sync(
          position: const Duration(seconds: 1),
          playing: true,
          rate: 1,
          at: t0,
        );

      expect(
        clock.sample(at(5000)),
        const Duration(
          milliseconds: 1000 + DanmakuMotionClock.defaultMaxExtrapolationMs,
        ),
      );
    });

    test('位置永不为负', () {
      final clock = DanmakuMotionClock()
        ..sync(
          position: const Duration(milliseconds: 10),
          playing: true,
          rate: 1,
          at: t0,
        );

      expect(
        clock.sample(t0.subtract(const Duration(milliseconds: 20))),
        const Duration(milliseconds: 10),
        reason: '墙钟倒退（系统时间校准）时不能给出负位置',
      );
    });
  });
}
