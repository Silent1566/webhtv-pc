/// Phase 7 · 续播闸门（`docs/phase7/design/03` §4.1/§4.2、`design/04` R1–R6）。
///
/// 本文件只锁**纯逻辑**：真播完判定、跨端 `completed` 重算的口径一致。
/// 连播的防重入与失败回滚属 L2（`phase7_player_advance_test.dart`，T15–T17）。
///
/// 反向验证靶子（`design/04` §3.2 #1）：
/// 去掉 `duration <= 0` 检查后，本文件必须转红。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/android_sync.dart';
import 'package:webhtv_pc/core/playback.dart';

void main() {
  group('R1–R4 · 真播完判定（design/03 §4.1）', () {
    test('R1 · duration=0 → false（时长未知不等于播完）', () {
      // 这是反向验证 #1 的靶子：缓存耗尽时 duration 可能还没取到，
      // 此时播放器的 completed 若为 true 一定是误报。
      expect(isGenuineEnd(durationMs: 0, positionMs: 0), isFalse);
      expect(isGenuineEnd(durationMs: 0, positionMs: 999999), isFalse);
      expect(isGenuineEnd(durationMs: -1, positionMs: 999999), isFalse);
    });

    test('R2 · position = duration-6s → false（不连播）', () {
      expect(
        isGenuineEnd(durationMs: 2700000, positionMs: 2700000 - 6000),
        isFalse,
      );
    });

    test('R3 · position = duration-5s → true（边界含等号）', () {
      expect(
        isGenuineEnd(durationMs: 2700000, positionMs: 2700000 - 5000),
        isTrue,
      );
    });

    test('R4 · position = duration → true', () {
      expect(isGenuineEnd(durationMs: 2700000, positionMs: 2700000), isTrue);
    });

    test('position 超出 duration（异常源）仍判播完', () {
      expect(isGenuineEnd(durationMs: 60000, positionMs: 90000), isTrue);
    });

    test('position 为 0 且 duration 正常 → false（刚开播）', () {
      expect(isGenuineEnd(durationMs: 2700000, positionMs: 0), isFalse);
    });

    test('余量可覆盖（传入自定义 margin）', () {
      expect(
        isGenuineEnd(durationMs: 100000, positionMs: 90000, marginMs: 15000),
        isTrue,
      );
      expect(
        isGenuineEnd(durationMs: 100000, positionMs: 90000, marginMs: 5000),
        isFalse,
      );
    });

    test('Duration 形态入口与毫秒入口同结论', () {
      const duration = Duration(minutes: 45);
      expect(
        isGenuineEndDuration(
          duration: duration,
          position: duration - const Duration(seconds: 5),
        ),
        isTrue,
      );
      expect(
        isGenuineEndDuration(
          duration: duration,
          position: duration - const Duration(seconds: 6),
        ),
        isFalse,
      );
      expect(
        isGenuineEndDuration(duration: Duration.zero, position: Duration.zero),
        isFalse,
      );
    });
  });

  group('R5/R6 · completed 的跨端语义（design/03 §4.2）', () {
    test('R5 · PC 不采信同步来的 completed，按公式重算', () {
      // 构造一条"安卓认为播完、PC 认为没播完"的记录：
      // 45 min 剧集，position = 0.96 × duration（安卓 progress>=0.95 判完播），
      // 但距结束还有 108 s，远超 PC 的 5 s 余量。
      const durationMs = 2700000;
      final androidSaysCompleted = (0.96 * durationMs) / durationMs >= 0.95;
      expect(androidSaysCompleted, isTrue);

      final item = SyncHistoryItem.tryFromJson({
        'key': 'CupFox@@@/video/104339.html@@@1',
        'vodName': '扫毒风暴',
        'vodFlag': '线路1',
        'vodRemarks': '第01集',
        'position': (0.96 * durationMs).round(),
        'duration': durationMs,
        'createTime': 1792208633969,
        // 即使对端直接给了 completed=true，也必须被忽略。
        'completed': true,
      })!;

      expect(item.completed, isFalse);
      expect(
        recomputeCompleted(
          durationMs: item.durationMs,
          positionMs: item.positionMs,
        ),
        isFalse,
      );
    });

    test('R6 · position 达 5 s 余量内 → PC 判播完', () {
      const durationMs = 2700000;
      final item = SyncHistoryItem.tryFromJson({
        'key': 'CupFox@@@/video/104339.html@@@1',
        'vodName': '扫毒风暴',
        'position': durationMs - 5000,
        'duration': durationMs,
        'createTime': 1,
      })!;
      expect(item.completed, isTrue);
      expect(
        recomputeCompleted(
          durationMs: item.durationMs,
          positionMs: item.positionMs,
        ),
        isTrue,
      );
    });

    test('duration<=0 时同步记录不算播完（与闸门同口径）', () {
      final item = SyncHistoryItem.tryFromJson({
        'key': 'CupFox@@@/video/104339.html@@@1',
        'vodName': '扫毒风暴',
        'position': 999,
        'duration': 0,
        'createTime': 1,
      })!;
      expect(item.completed, isFalse);
      expect(
        recomputeCompleted(
          durationMs: item.durationMs,
          positionMs: item.positionMs,
        ),
        isFalse,
      );
    });

    test('三处口径必须同值：闸门 / 同步项 / 重算', () {
      // 同一组 (duration, position) 在三个入口必须给同一个结论，
      // 否则会出现「同步说播完、播放器说不播完」的错位。
      const cases = [
        (2700000, 0),
        (2700000, 2700000 - 6000),
        (2700000, 2700000 - 5000),
        (2700000, 2700000),
        (0, 0),
        (60000, 60000),
      ];
      for (final (duration, position) in cases) {
        final gate = isGenuineEnd(durationMs: duration, positionMs: position);
        final recomputed = recomputeCompleted(
          durationMs: duration,
          positionMs: position,
        );
        final item = SyncHistoryItem.tryFromJson({
          'key': 'CupFox@@@v@@@1',
          'vodName': 'x',
          'position': position,
          'duration': duration,
          'createTime': 1,
        })!;
        expect(recomputed, gate, reason: 'd=$duration p=$position');
        expect(item.completed, gate, reason: 'd=$duration p=$position');
      }
    });

    test('余量常量在闸门与同步层保持一致（5000 ms）', () {
      // 两处独立常量若漂移，三处口径就不再同值。
      expect(genuineEndMarginMs, 5000);
      const durationMs = 100000;
      expect(
        SyncHistoryItem.tryFromJson({
          'key': 'a@@@b@@@1',
          'vodName': 'x',
          'position': durationMs - genuineEndMarginMs,
          'duration': durationMs,
          'createTime': 1,
        })!.completed,
        isTrue,
      );
    });
  });
}
