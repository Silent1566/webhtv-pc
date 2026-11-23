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

    test('相同位置的重复上报不把弹幕拉回去（页面重建只重复同一位置）', () {
      final clock = DanmakuMotionClock()
        ..sync(
          position: const Duration(seconds: 10),
          playing: true,
          rate: 1,
          at: t0,
        )
        ..sync(
          position: const Duration(seconds: 10),
          playing: true,
          rate: 1,
          at: at(160),
        );

      // 断在 _reconcile 把「落后插值 120ms 以上的旧上报」当 seek：
      // 同一个位置再报一次就会把已经在动的弹幕拉回 10.000s。
      expect(
        clock.sample(at(160)),
        greaterThanOrEqualTo(const Duration(milliseconds: 10160)),
      );
    });

    test('重复上报不刷新断流外插的截止时间', () {
      final clock = DanmakuMotionClock()
        ..sync(
          position: const Duration(seconds: 10),
          playing: true,
          rate: 1,
          at: t0,
        );
      for (var ms = 40; ms <= 800; ms += 40) {
        clock.sync(
          position: const Duration(seconds: 10),
          playing: true,
          rate: 1,
          at: at(ms),
        );
      }

      // 每次重复上报都把基准时间推到「现在」时，这里只能走到 10.100s：
      // 外插上限被无限续期，缓冲卡住时弹幕会一直往前飘。
      expect(clock.sample(at(900)), const Duration(milliseconds: 10600));
    });

    test('负位置归一后的零重复上报同样不重置基准', () {
      final clock = DanmakuMotionClock()
        ..sync(
          position: const Duration(milliseconds: -50),
          playing: true,
          rate: 1,
          at: t0,
        )
        ..sync(
          position: Duration.zero,
          playing: true,
          rate: 1,
          at: at(160),
        );

      expect(clock.sample(at(160)), const Duration(milliseconds: 160));
    });

    test('暂停与倍速变化不把画面拉回上报值（只前进不后退）', () {
      final clock = DanmakuMotionClock()
        ..sync(
          position: const Duration(seconds: 1),
          playing: true,
          rate: 1,
          at: t0,
        )
        ..sync(
          position: const Duration(seconds: 1),
          playing: false,
          rate: 1,
          at: at(100),
        );

      // 暂停发生在「画面已经走到 1.1s、但最近一次上报还是 1.0s」的时刻。
      // 位置没变就整段跳过会把暂停丢掉；照单采纳上报值又会把画面拉回 1.0s
      // （一次可见回退）。正确语义：按旧倍率结算到此刻并钉住。
      expect(clock.sample(at(500)), const Duration(milliseconds: 1100));

      clock.sync(
        position: const Duration(seconds: 1),
        playing: true,
        rate: 2,
        at: at(500),
      );
      // 恢复播放：从钉住的那一帧按新倍率继续，不回退。
      expect(clock.sample(at(516)), const Duration(milliseconds: 1132));
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

    test('明显前跳（换源、拖到后面）立即跟随', () {
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

      // 往回拖由「定位信号」那条路径处理（见下面的定位用例），这里只锁前跳。
    });

    test('倒退不到 seek 下限（重缓冲/断点上报）不采纳，继续前进', () {
      final clock = DanmakuMotionClock()
        ..sync(
          position: const Duration(seconds: 10),
          playing: true,
          rate: 1,
          at: t0,
        );

      // 400ms 后才到的上报值比插值落后 300ms：HLS 断点、重缓冲、上报滞后
      // 都会给出这种「比当前轨迹旧」的值，那不是用户拖拽。
      clock.sync(
        position: const Duration(milliseconds: 10100),
        playing: true,
        rate: 1,
        at: at(400),
      );

      expect(
        clock.sample(at(400)),
        const Duration(milliseconds: 10400),
        reason: '落后 300ms 的旧上报不能把画面拉回 10.100s',
      );
      // 停在画面位置等上报追上来（追赶期间不推进），而不是从头再插值一遍。
      expect(clock.sample(at(416)), const Duration(milliseconds: 10400));
      // 上报追上冻结位置后对齐，并恢复 1x 前进。
      clock.sync(
        position: const Duration(milliseconds: 10400),
        playing: true,
        rate: 1,
        at: at(700),
      );
      expect(clock.sample(at(716)), const Duration(milliseconds: 10416));
    });

    test('远超外插上限的后退先冻结，下一条上报确认是重置才跟随', () {
      final clock = DanmakuMotionClock()
        ..sync(
          position: const Duration(seconds: 10),
          playing: true,
          rate: 1,
          at: t0,
        )
        // 600ms 时上报值与插值一致，基准推进到 10.600s（外插上限 600ms 之外
        // 的样本不能用来量倒退幅度，否则量到的是上限而不是上报值）。
        ..sync(
          position: const Duration(milliseconds: 10600),
          playing: true,
          rate: 1,
          at: at(600),
        );
      clock.sync(
        position: const Duration(milliseconds: 10201),
        playing: true,
        rate: 1,
        at: at(1200),
      );

      // live = 10.600 + 0.600 = 11.200s，上报 10.201s，落后 999ms。
      // 没有定位信号，判断不了是时间轴重置还是一条迟到很久的旧上报：先冻住。
      expect(clock.sample(at(1200)), const Duration(milliseconds: 11200));

      // 下一条仍停在候选附近 ⇒ 确认是重置，跟随到新时间轴。
      clock.sync(
        position: const Duration(milliseconds: 10301),
        playing: true,
        rate: 1,
        at: at(1240),
      );
      expect(clock.sample(at(1240)), const Duration(milliseconds: 10301));

      // 若下一条跳回原处，则刚才那条只是迟到的旧上报：取消，沿原轨迹前进。
    });

    test('播放器报告定位结束时立即对表（拖动进度条）', () {
      final clock = DanmakuMotionClock()
        ..sync(
          position: const Duration(seconds: 10),
          playing: true,
          rate: 1,
          at: t0,
        )
        // 定位开始：冻结在当时的画面位置（不是上报值）。
        ..sync(
          position: const Duration(seconds: 10),
          playing: true,
          rate: 1,
          at: at(100),
          seeking: true,
        );
      // 定位开始前画面已经走到 10.000 + 100ms：冻结在这一帧，而不是上报值。
      expect(clock.sample(at(500)), const Duration(milliseconds: 10100));

      // 定位结束：上报值就是拖到的位置，立即跟随——不需要拿幅度去猜。
      clock.sync(
        position: const Duration(seconds: 5),
        playing: true,
        rate: 1,
        at: at(600),
      );
      expect(clock.sample(at(600)), const Duration(seconds: 5));
      expect(clock.sample(at(616)), const Duration(milliseconds: 5016));
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

    group('停滞冻结与追齐（held）', () {
    test('追齐等待中用户把进度往回拖（真 seek）必须立即跟随', () {
      final clock = DanmakuMotionClock()
        ..sync(position: const Duration(seconds: 10), playing: true, rate: 1, at: t0)
        ..sync(
          position: const Duration(seconds: 10),
          playing: true,
          rate: 1,
          at: at(200),
          held: true,
        )
        // 解除停滞时上报落后 300ms：进入追齐等待，画面钉在 10.200s。
        ..sync(
          position: const Duration(milliseconds: 9900),
          playing: true,
          rate: 1,
          at: at(12200),
        );
      expect(clock.sample(at(12200)), const Duration(milliseconds: 10200));

      // 用户在等待期间把进度拖回 5s：播放器报告定位——先冻结，定位结束立即对表，
      // 不能继续等旧位置追上（那会让弹幕冻住好几秒）。
      clock.sync(
        position: const Duration(seconds: 5),
        playing: true,
        rate: 1,
        at: at(12240),
        seeking: true,
      );
      expect(clock.sample(at(12240)), const Duration(milliseconds: 10200));
      clock.sync(
        position: const Duration(seconds: 5),
        playing: true,
        rate: 1,
        at: at(12280),
      );
      expect(clock.sample(at(12280)), const Duration(seconds: 5));
    });

    test('追齐等待中再次进入停滞不再按墙钟外推', () {
      final clock = DanmakuMotionClock()
        ..sync(position: const Duration(seconds: 10), playing: true, rate: 1, at: t0)
        ..sync(
          position: const Duration(seconds: 10),
          playing: true,
          rate: 1,
          at: at(200),
          held: true,
        )
        ..sync(
          position: const Duration(milliseconds: 9900),
          playing: true,
          rate: 1,
          at: at(12200),
        )
        ..sync(
          position: const Duration(seconds: 10),
          playing: true,
          rate: 1,
          at: at(12300),
          held: true,
        );

      // 追齐期间墙钟不是播放时间：再进停滞必须停在 10.200s。
      expect(clock.sample(at(13000)), const Duration(milliseconds: 10200));
    });

    test('暂停状态下进入停滞不会凭空获得播放进度', () {
      final clock = DanmakuMotionClock()
        ..sync(position: const Duration(seconds: 10), playing: false, rate: 1, at: t0)
        ..sync(
          position: const Duration(seconds: 10),
          playing: false,
          rate: 1,
          at: at(200),
          held: true,
        );

      expect(clock.sample(at(500)), const Duration(seconds: 10));
    });

    test('进入停滞时按旧倍速结算，不拿新倍速回溯旧区间', () {
      final clock = DanmakuMotionClock()
        ..sync(position: const Duration(seconds: 10), playing: true, rate: 1, at: t0)
        ..sync(
          position: const Duration(seconds: 10),
          playing: true,
          rate: 2,
          at: at(200),
          held: true,
        );

      expect(clock.sample(at(500)), const Duration(milliseconds: 10200));
    });
  });
}
