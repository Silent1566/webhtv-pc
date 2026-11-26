/// 运行中引擎错误的确认闸门（`docs/reference/xiugou-tv-borrowings.md` §3.3）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/playback_error_gate.dart';

DateTime _at(int seconds) =>
    DateTime(2026, 1, 1).add(Duration(seconds: seconds));

const Duration _pausedPosition = Duration(minutes: 5);

PlaybackErrorGateAction _offer(
  PlaybackErrorGate gate, {
  String message = 'Failed to open stream',
  int generation = 1,
  Duration position = _pausedPosition,
  int at = 0,
  bool playing = true,
  bool buffering = false,
  bool seeking = false,
}) => gate.offer(
  message: message,
  generation: generation,
  position: position,
  at: _at(at),
  playing: playing,
  buffering: buffering,
  seeking: seeking,
);

PlaybackErrorGateAction _observe(
  PlaybackErrorGate gate, {
  int generation = 1,
  Duration position = _pausedPosition,
  int at = 0,
  bool playing = true,
  bool buffering = false,
  bool seeking = false,
}) => gate.observe(
  generation: generation,
  position: position,
  at: _at(at),
  playing: playing,
  buffering: buffering,
  seeking: seeking,
);

void main() {
  group('确认窗口', () {
    test('刚开始报错只进入 pending，不立刻判失败', () {
      final gate = PlaybackErrorGate();
      expect(_offer(gate), PlaybackErrorGateAction.pending);
      expect(_observe(gate, at: 1), PlaybackErrorGateAction.pending);
      expect(gate.committed, isFalse);
    });

    test('位置一直不动且过了窗口 → committed 只发生一次', () {
      final gate = PlaybackErrorGate(window: const Duration(seconds: 8));
      expect(_offer(gate), PlaybackErrorGateAction.pending);
      expect(_observe(gate, at: 8), PlaybackErrorGateAction.committed);
      expect(gate.committed, isTrue);
      expect(_observe(gate, at: 20), PlaybackErrorGateAction.committed);
      expect(_offer(gate, at: 21), PlaybackErrorGateAction.committed);
    });
  });

  group('位置仍在推进：错误不成立', () {
    test('推进后 pending 被撤销，不提交', () {
      final gate = PlaybackErrorGate(window: const Duration(seconds: 8));
      expect(_offer(gate), PlaybackErrorGateAction.pending);
      expect(
        _observe(gate, position: const Duration(minutes: 5, seconds: 2), at: 9),
        PlaybackErrorGateAction.idle,
      );
      expect(gate.committed, isFalse);
    });

    test('已提交后位置又推进 → recovered', () {
      final gate = PlaybackErrorGate(window: const Duration(seconds: 8));
      _offer(gate);
      expect(_observe(gate, at: 8), PlaybackErrorGateAction.committed);
      expect(
        _observe(gate, position: const Duration(minutes: 5, seconds: 3), at: 9),
        PlaybackErrorGateAction.recovered,
      );
      expect(gate.committed, isFalse);
    });
  });

  group('暂停/缓冲/定位中：位置不动不能当致命证据', () {
    for (final flag in ['paused', 'buffering', 'seeking']) {
      test('$flag 且过了窗口 → 仍 pending', () {
        final gate = PlaybackErrorGate(window: const Duration(seconds: 8));
        _offer(
          gate,
          playing: flag != 'paused',
          buffering: flag == 'buffering',
          seeking: flag == 'seeking',
        );
        expect(
          _observe(
            gate,
            at: 30,
            playing: flag != 'paused',
            buffering: flag == 'buffering',
            seeking: flag == 'seeking',
          ),
          PlaybackErrorGateAction.pending,
        );
      });
    }
  });

  group('错误风暴', () {
    test('重复同一条错误不重启计时', () {
      final gate = PlaybackErrorGate(window: const Duration(seconds: 8));
      _offer(gate, at: 0);
      _offer(gate, at: 6);
      expect(_observe(gate, at: 8), PlaybackErrorGateAction.committed);
    });

    test('新错误只换文本，不延后结论', () {
      final gate = PlaybackErrorGate(window: const Duration(seconds: 8));
      _offer(gate, message: 'A', at: 0);
      _offer(gate, message: 'B', at: 7);
      expect(gate.message, 'B');
      expect(_observe(gate, at: 8), PlaybackErrorGateAction.committed);
    });
  });

  group('换媒体', () {
    test('代际变化清空上一部片的错误与结论', () {
      final gate = PlaybackErrorGate(window: const Duration(seconds: 8));
      _offer(gate, generation: 1);
      expect(
        _observe(gate, generation: 1, at: 8),
        PlaybackErrorGateAction.committed,
      );
      expect(
        _observe(gate, generation: 2, at: 9),
        PlaybackErrorGateAction.idle,
      );
      expect(gate.committed, isFalse);
      expect(gate.pending, isFalse);
    });
  });

  group('active observation sequences', () {
    for (final flag in ['paused', 'buffering', 'seeking']) {
      test('$flag then resume requires a full new active window', () {
        final gate = PlaybackErrorGate();
        expect(_offer(gate), PlaybackErrorGateAction.pending);
        expect(
          _observe(
            gate,
            at: 1,
            playing: flag != 'paused',
            buffering: flag == 'buffering',
            seeking: flag == 'seeking',
          ),
          PlaybackErrorGateAction.pending,
        );
        expect(_observe(gate, at: 30), PlaybackErrorGateAction.pending);
        expect(gate.pending, isTrue);
        expect(_observe(gate, at: 37), PlaybackErrorGateAction.pending);
        expect(_observe(gate, at: 38), PlaybackErrorGateAction.committed);
      });
    }

    for (final seeking in [false, true]) {
      for (final committed in [false, true]) {
        test(
          'backward seek (seeking=$seeking, committed=$committed) rebases progress',
          () {
            final gate = PlaybackErrorGate();
            _offer(gate);
            if (committed) {
              expect(_observe(gate, at: 8), PlaybackErrorGateAction.committed);
            }
            expect(
              _observe(
                gate,
                position: const Duration(seconds: 120),
                at: 30,
                seeking: seeking,
              ),
              committed
                  ? PlaybackErrorGateAction.committed
                  : PlaybackErrorGateAction.pending,
            );
            expect(
              _observe(gate, position: const Duration(seconds: 121), at: 31),
              committed
                  ? PlaybackErrorGateAction.recovered
                  : PlaybackErrorGateAction.idle,
            );
            expect(gate.message, isNull);
            expect(gate.pending, isFalse);
            expect(gate.committed, isFalse);
          },
        );
      }
    }

    test('backward regression starts a new stalled-position window', () {
      final gate = PlaybackErrorGate();
      _offer(gate);
      expect(
        _observe(gate, position: const Duration(seconds: 120), at: 30),
        PlaybackErrorGateAction.pending,
      );
      expect(
        _observe(gate, position: const Duration(seconds: 120), at: 37),
        PlaybackErrorGateAction.pending,
      );
      expect(
        _observe(gate, position: const Duration(seconds: 120), at: 38),
        PlaybackErrorGateAction.committed,
      );
    });

    test(
      'new error offered with real progress can recover a committed error',
      () {
        final gate = PlaybackErrorGate();
        _offer(gate, message: 'A');
        expect(_observe(gate, at: 8), PlaybackErrorGateAction.committed);
        expect(
          _offer(
            gate,
            message: 'B',
            position: const Duration(seconds: 301),
            at: 9,
          ),
          PlaybackErrorGateAction.recovered,
        );
        expect(gate.message, isNull);
        expect(gate.committed, isFalse);
      },
    );

    test('seeking position is not recovery evidence for a committed error', () {
      final gate = PlaybackErrorGate();
      _offer(gate);
      _observe(gate, at: 8);
      expect(
        _observe(
          gate,
          position: const Duration(seconds: 900),
          at: 9,
          seeking: true,
        ),
        PlaybackErrorGateAction.committed,
      );
      expect(gate.committed, isTrue);
      expect(
        _observe(
          gate,
          position: const Duration(seconds: 120),
          at: 10,
          seeking: true,
        ),
        PlaybackErrorGateAction.committed,
      );
      expect(
        _observe(gate, position: const Duration(seconds: 121), at: 11),
        PlaybackErrorGateAction.recovered,
      );
    });

    test('same-text new event after recovery starts a fresh window', () {
      final gate = PlaybackErrorGate();
      _offer(gate);
      _observe(gate, at: 8);
      expect(
        _observe(gate, position: const Duration(seconds: 301), at: 9),
        PlaybackErrorGateAction.recovered,
      );
      expect(
        _offer(gate, position: const Duration(seconds: 301), at: 10),
        PlaybackErrorGateAction.pending,
      );
      expect(
        _observe(gate, position: const Duration(seconds: 301), at: 17),
        PlaybackErrorGateAction.pending,
      );
      expect(
        _observe(gate, position: const Duration(seconds: 301), at: 18),
        PlaybackErrorGateAction.committed,
      );
    });

    test(
      'same-text new event after pending dismissal starts a fresh window',
      () {
        final gate = PlaybackErrorGate();
        _offer(gate);
        expect(
          _observe(gate, position: const Duration(seconds: 301), at: 1),
          PlaybackErrorGateAction.idle,
        );
        expect(
          _observe(gate, position: const Duration(seconds: 301), at: 30),
          PlaybackErrorGateAction.idle,
        );
        expect(
          _offer(gate, position: const Duration(seconds: 301), at: 31),
          PlaybackErrorGateAction.pending,
        );
        expect(
          _observe(gate, position: const Duration(seconds: 301), at: 39),
          PlaybackErrorGateAction.committed,
        );
      },
    );

    test(
      'resumed error storm updates text without moving the new deadline',
      () {
        final gate = PlaybackErrorGate();
        _offer(gate, message: 'A');
        _observe(gate, at: 1, buffering: true);
        expect(
          _offer(gate, message: 'B', at: 30),
          PlaybackErrorGateAction.pending,
        );
        expect(
          _offer(gate, message: 'C', at: 37),
          PlaybackErrorGateAction.pending,
        );
        expect(gate.message, 'C');
        expect(
          _offer(gate, message: 'D', at: 38),
          PlaybackErrorGateAction.committed,
        );
        expect(gate.message, 'D');
      },
    );

    test('generation change drops a suspended old error and its deadline', () {
      final gate = PlaybackErrorGate();
      _offer(gate);
      _observe(gate, at: 1, seeking: true);
      expect(
        _observe(gate, generation: 2, at: 30),
        PlaybackErrorGateAction.idle,
      );
      expect(gate.message, isNull);
      expect(gate.pending, isFalse);
      expect(
        _observe(gate, generation: 2, at: 100),
        PlaybackErrorGateAction.idle,
      );
      expect(
        _offer(gate, generation: 2, at: 101),
        PlaybackErrorGateAction.pending,
      );
      expect(
        _observe(gate, generation: 2, at: 108),
        PlaybackErrorGateAction.pending,
      );
      expect(
        _observe(gate, generation: 2, at: 109),
        PlaybackErrorGateAction.committed,
      );
    });

    for (final message in ['', '  \t\n']) {
      test('blank error does not start a fatal window: $message', () {
        final gate = PlaybackErrorGate();
        expect(_offer(gate, message: message), PlaybackErrorGateAction.idle);
        expect(_observe(gate, at: 30), PlaybackErrorGateAction.idle);
        expect(gate.message, isNull);
        expect(gate.pending, isFalse);
      });
    }

    test('blank event does not replace or extend a valid pending error', () {
      final gate = PlaybackErrorGate();
      _offer(gate, message: 'real error');
      expect(
        _offer(gate, message: '  ', at: 7),
        PlaybackErrorGateAction.pending,
      );
      expect(gate.message, 'real error');
      expect(_observe(gate, at: 8), PlaybackErrorGateAction.committed);
    });

    test('buffering without an error remains idle after resume', () {
      final gate = PlaybackErrorGate();
      expect(_observe(gate, buffering: true), PlaybackErrorGateAction.idle);
      expect(_observe(gate, at: 30), PlaybackErrorGateAction.idle);
      expect(_observe(gate, at: 60), PlaybackErrorGateAction.idle);
      expect(gate.committed, isFalse);
    });

    for (final message in [
      'No audio devices found!',
      'Failed to initialize a video output',
      'Subtitle track not found',
    ]) {
      test('nonfatal warning while playback advances stays safe: $message', () {
        final gate = PlaybackErrorGate();
        _offer(gate, message: message);
        expect(
          _observe(gate, position: const Duration(seconds: 301), at: 1),
          PlaybackErrorGateAction.idle,
        );
        expect(
          _observe(gate, position: const Duration(seconds: 301), at: 30),
          PlaybackErrorGateAction.idle,
        );
        expect(gate.committed, isFalse);
      });
    }
  });
}
