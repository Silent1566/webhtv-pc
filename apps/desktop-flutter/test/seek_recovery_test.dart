/// seek 失败恢复的判据（`docs/reference/xiugou-tv-borrowings.md` §3.2）。
///
/// 三条硬规则：暂停/缓冲/定位中既不算到位也不算失败；只有真的播起来并停在
/// 目标附近才算成功；旧媒体代际的跳转不得污染新媒体。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/seek_recovery.dart';

SeekRecovery _recovery({
  Duration origin = const Duration(seconds: 30),
  Duration target = const Duration(minutes: 20),
  int generation = 1,
  Duration age = Duration.zero,
}) => SeekRecovery(
  origin: origin,
  target: target,
  generation: generation,
  startedAt: DateTime(2026, 1, 1).add(age),
);

SeekRecoveryVerdict _evaluate(
  SeekRecovery recovery, {
  int generation = 1,
  Duration position = const Duration(minutes: 20),
  Duration? previousPosition,
  bool seen = true,
  bool playing = true,
  bool buffering = false,
  bool seeking = false,
  Duration age = Duration.zero,
}) => evaluateSeekRecovery(
  recovery: recovery,
  generation: generation,
  enginePosition: position,
  previousEnginePosition: previousPosition,
  enginePositionSeen: seen,
  playing: playing,
  buffering: buffering,
  isSeeking: seeking,
  now: DateTime(2026, 1, 1).add(age),
);

void main() {
  test('目标位置卡住超过窗口仍然是失败，不可凭到达值永久等待', () {
    expect(
      _evaluate(_recovery(), age: const Duration(seconds: 21)),
      SeekRecoveryVerdict.failed,
    );
  });

  test('单次目标位置上报不是继续推进的证据', () {
    expect(_evaluate(_recovery()), SeekRecoveryVerdict.pending);
  });

  group('成功：真的播起来并停在目标附近', () {
    test('目标附近（含容差）且正在播放 → settled', () {
      expect(
        _evaluate(
          _recovery(),
          position: const Duration(minutes: 20) + const Duration(seconds: 2),
          previousPosition: const Duration(minutes: 20),
        ),
        SeekRecoveryVerdict.settled,
      );
    });

    test('超出容差仍在窗口内 → pending', () {
      expect(
        _evaluate(
          _recovery(),
          position: const Duration(minutes: 10),
          age: const Duration(seconds: 5),
        ),
        SeekRecoveryVerdict.pending,
      );
    });
  });

  group('暂停/缓冲/定位中：既不算到位也不算失败', () {
    for (final flag in ['paused', 'buffering', 'seeking']) {
      test('$flag 且已过窗口 → 仍 pending', () {
        final verdict = _evaluate(
          _recovery(),
          position: const Duration(minutes: 3),
          playing: flag != 'paused',
          buffering: flag == 'buffering',
          seeking: flag == 'seeking',
          age: const Duration(minutes: 2),
        );
        expect(verdict, SeekRecoveryVerdict.pending);
      });
    }

    test('暂停时即使位置正好在目标上也不算到位（没有真的播起来）', () {
      expect(
        _evaluate(_recovery(), playing: false),
        SeekRecoveryVerdict.pending,
      );
    });
  });

  group('失败：窗口内一直没到目标', () {
    test('过了窗口且位置没到 → failed', () {
      expect(
        _evaluate(
          _recovery(),
          position: const Duration(minutes: 2),
          age: seekFailureWindow,
        ),
        SeekRecoveryVerdict.failed,
      );
    });

    test('没到窗口 → 还等', () {
      expect(
        _evaluate(
          _recovery(),
          position: const Duration(minutes: 2),
          age: seekFailureWindow - const Duration(seconds: 1),
        ),
        SeekRecoveryVerdict.pending,
      );
    });

    test('引擎还没上报过位置 → 不判失败', () {
      expect(
        _evaluate(
          _recovery(),
          position: Duration.zero,
          seen: false,
          age: const Duration(minutes: 5),
        ),
        SeekRecoveryVerdict.pending,
      );
    });
  });

  group('代际与可恢复性', () {
    test('旧代际的跳转一律 pending（不污染新媒体）', () {
      expect(
        _evaluate(_recovery(generation: 1), generation: 2),
        SeekRecoveryVerdict.pending,
      );
    });

    test('原位置与目标相同 → 没有可恢复出口', () {
      expect(
        _recovery(
          origin: const Duration(minutes: 20),
          target: const Duration(minutes: 20),
        ).recoverable,
        isFalse,
      );
      expect(_recovery().recoverable, isTrue);
    });
  });
}
