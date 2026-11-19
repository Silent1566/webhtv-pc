/// 迭代 3-C：失败回退阶梯的纯策略。
///
/// 这些断言是「接线」的前提——页面上换不换线路、换不换解析源，全部由这里的结果
/// 决定，所以每一条规则都要能在这里单独钉住：
/// 1. `off`（默认档）一律放弃，未开启的用户零行为变更；
/// 2. `line` / `line_parse` / `line_parse_source` 三档的深度差异；
/// 3. 不可回退的失败（格式不支持 / 加载失败）绝不换线路；
/// 4. 总次数上限；原地重试只给一次；
/// 5. 边界位置（下标 -1、末位、空列表）不猜、不越界。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/playback_fallback.dart';
import 'package:webhtv_pc/core/playback_open_policy.dart';
import 'package:webhtv_pc/core/player_options.dart';

/// 造一个「三条线路、两个解析源、当前在第 1 条线路 / 第 1 个解析源」的请求。
PlaybackFallbackRequest _request({
  PlaybackFailureClass failure = PlaybackFailureClass.recoverable,
  PlayerFailureFallback mode = PlayerFailureFallback.line,
  int lineIndex = 0,
  int lineCount = 3,
  int parseSourceIndex = 0,
  int parseSourceCount = 2,
  int attempts = 0,
}) => PlaybackFallbackRequest(
  failure: failure,
  mode: mode,
  lineIndex: lineIndex,
  lineCount: lineCount,
  parseSourceIndex: parseSourceIndex,
  parseSourceCount: parseSourceCount,
  attempts: attempts,
);

void main() {
  group('默认档 off：一次都不自动切换', () {
    test('有下一条线路也不换', () {
      final decision = decidePlaybackFallback(
        _request(mode: PlayerFailureFallback.off),
      );
      expect(decision.step, FallbackStep.giveUp);
      expect(decision.hasNext, isFalse);
      expect(decision.targetIndex, isNull);
      expect(decision.reason, contains('off'));
    });

    test('即使失败是可回退的、候选也齐全，仍然放弃', () {
      for (final attempts in [0, 1, 2]) {
        expect(
          decidePlaybackFallback(
            _request(mode: PlayerFailureFallback.off, attempts: attempts),
          ).step,
          FallbackStep.giveUp,
          reason: 'off 档不得因为次数还富余就换线（attempts=$attempts）',
        );
      }
    });
  });

  group('line 档：只换线路', () {
    test('线路还有下一条 → nextLine，目标下标指向下一条', () {
      final decision = decidePlaybackFallback(_request());
      expect(decision.step, FallbackStep.nextLine);
      expect(decision.targetIndex, 1);
      expect(decision.hasNext, isTrue);
      expect(decision.reason, isNotEmpty);
    });

    test('线路用尽也不换解析源（allowsParse=false）→ 原地重试', () {
      final decision = decidePlaybackFallback(_request(lineIndex: 2));
      expect(decision.step, FallbackStep.retrySame);
      expect(decision.targetIndex, isNull);
    });

    test('线路用尽且已经回退过一次 → 放弃', () {
      final decision = decidePlaybackFallback(
        _request(lineIndex: 2, attempts: 1),
      );
      expect(decision.step, FallbackStep.giveUp);
    });
  });

  group('lineAndParse / lineAndParseAndSource：线路之后才轮到解析源', () {
    test('线路还有下一条时，先换线路而不是解析源', () {
      final decision = decidePlaybackFallback(
        _request(mode: PlayerFailureFallback.lineAndParse),
      );
      expect(decision.step, FallbackStep.nextLine);
      expect(decision.targetIndex, 1);
    });

    test('线路用尽 → nextParseSource，目标下标指向下一个解析源', () {
      final decision = decidePlaybackFallback(
        _request(mode: PlayerFailureFallback.lineAndParse, lineIndex: 2),
      );
      expect(decision.step, FallbackStep.nextParseSource);
      expect(decision.targetIndex, 1);
      expect(decision.reason, isNotEmpty);
    });

    test('lineAndParseAndSource 的阶梯同样到解析源为止（播放页没有 VOD 换源入口）', () {
      final decision = decidePlaybackFallback(
        _request(mode: PlayerFailureFallback.lineAndParseAndSource, lineIndex: 2),
      );
      expect(decision.step, FallbackStep.nextParseSource);
      // 解析源也用尽后不再有下一步，降到「原地重试一次」。
      expect(
        decidePlaybackFallback(
          _request(
            mode: PlayerFailureFallback.lineAndParseAndSource,
            lineIndex: 2,
            parseSourceIndex: 1,
          ),
        ).step,
        FallbackStep.retrySame,
      );
    });
  });

  group('不可回退的失败绝不换线路', () {
    test('格式不支持 / 加载失败在三档下都直接放弃', () {
      for (final mode in [
        PlayerFailureFallback.line,
        PlayerFailureFallback.lineAndParse,
        PlayerFailureFallback.lineAndParseAndSource,
      ]) {
        final decision = decidePlaybackFallback(
          _request(failure: PlaybackFailureClass.nonRecoverable, mode: mode),
        );
        expect(
          decision.step,
          FallbackStep.giveUp,
          reason: '$mode 不得为不可回退的失败换线',
        );
        expect(decision.targetIndex, isNull);
        expect(decision.reason, contains('不可回退'));
      }
    });

    test('不可回退时解析源同样不换', () {
      expect(
        decidePlaybackFallback(
          _request(
            failure: PlaybackFailureClass.nonRecoverable,
            mode: PlayerFailureFallback.lineAndParse,
            lineIndex: 2,
          ),
        ).step,
        FallbackStep.giveUp,
      );
    });
  });

  group('次数上限', () {
    test('上限常量是 3（一次原地重试 + 一次换线 + 一次换解析源）', () {
      expect(maxPlaybackFallbackAttempts, 3);
    });

    test('到达上限一律放弃，候选再多也不动', () {
      final decision = decidePlaybackFallback(
        _request(attempts: maxPlaybackFallbackAttempts),
      );
      expect(decision.step, FallbackStep.giveUp);
      expect(decision.reason, contains('$maxPlaybackFallbackAttempts'));
    });

    test('上限之前仍然换线路', () {
      final decision = decidePlaybackFallback(
        _request(attempts: maxPlaybackFallbackAttempts - 1),
      );
      expect(decision.step, FallbackStep.nextLine);
    });

    test('原地重试只给一次：第二次没有候选就放弃', () {
      expect(
        decidePlaybackFallback(_request(lineIndex: 2, attempts: 0)).step,
        FallbackStep.retrySame,
      );
      expect(
        decidePlaybackFallback(_request(lineIndex: 2, attempts: 1)).step,
        FallbackStep.giveUp,
      );
    });
  });

  group('边界位置：不猜、不越界', () {
    test('当前位置未知（-1）时不换线路', () {
      final decision = decidePlaybackFallback(_request(lineIndex: -1));
      expect(decision.step, FallbackStep.retrySame);
    });

    test('空线路 / 空解析源列表', () {
      final decision = decidePlaybackFallback(
        _request(
          mode: PlayerFailureFallback.lineAndParse,
          lineIndex: 0,
          lineCount: 0,
          parseSourceIndex: 0,
          parseSourceCount: 0,
        ),
      );
      expect(decision.step, FallbackStep.retrySame);
    });

    test('末位下标不越界：nextLine 目标始终落在 [0, count)', () {
      for (var index = 0; index < 3; index++) {
        final decision = decidePlaybackFallback(
          _request(lineIndex: index, lineCount: 3),
        );
        if (decision.step == FallbackStep.nextLine) {
          expect(decision.targetIndex, inInclusiveRange(0, 2));
          expect(decision.targetIndex, greaterThan(index));
        } else {
          expect(decision.step, FallbackStep.retrySame);
        }
      }
    });

    test('解析源末位 / 未知位置不越界', () {
      for (final index in [1, -1, 5]) {
        final decision = decidePlaybackFallback(
          _request(
            mode: PlayerFailureFallback.lineAndParse,
            lineIndex: 2,
            parseSourceIndex: index,
            parseSourceCount: 2,
          ),
        );
        expect(decision.step, FallbackStep.retrySame, reason: 'parseIndex=$index');
      }
    });
  });

  group('日志用理由', () {
    test('每一步的 logLine 都带步骤标识与目标', () {
      final nextLine = decidePlaybackFallback(_request());
      expect(nextLine.logLine, contains(FallbackStep.nextLine.id));
      expect(nextLine.logLine, contains('target=1'));

      final giveUp = decidePlaybackFallback(
        _request(mode: PlayerFailureFallback.off),
      );
      expect(giveUp.logLine, contains(FallbackStep.giveUp.id));
      expect(giveUp.logLine, contains('target=-'));
    });

    test('理由非空且不含换行（要能一行进日志）', () {
      for (final mode in PlayerFailureFallback.values) {
        for (final failure in PlaybackFailureClass.values) {
          final decision = decidePlaybackFallback(
            _request(mode: mode, failure: failure),
          );
          expect(decision.reason.trim(), isNotEmpty);
          expect(decision.reason, isNot(contains('\n')));
        }
      }
    });
  });
}
