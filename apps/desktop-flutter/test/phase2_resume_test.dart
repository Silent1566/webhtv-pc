/// 播放进度恢复（§15.2「继续播放」）门禁测试。
///
/// 覆盖 `docs/phase2/README.md` §3「进度恢复 UI」门禁的判定逻辑部分：
/// 进入播放器时是否应续播、续播到哪个位置。判定规则（§15.2）：
/// - 有历史且未看完 → 返回历史位置；
/// - 位置不足 5 秒 → 不续播（避免「刚打开就跳」）；
/// - 已看完（`completed`）或距结尾不足 5 秒 → 不续播；
/// - 无记录 → 不续播。
///
/// 这里用真实 `AppState` + 临时目录中的真实 SQLite，验证「写入 → 读回 →
/// 判定 → 交给播放器」这条链路，而不是桩。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';

void main() {
  late Directory tempDir;
  late AppState state;

  /// 跨重启用例会提前释放主 state，tearDown 不能再释放一次。
  var primaryDisposed = false;

  setUp(() async {
    primaryDisposed = false;
    tempDir = await Directory.systemTemp.createTemp('webhtv-resume');
    state = AppState(
      paths: AppPaths.resolve(
        overrides: {'roaming': tempDir.path, 'local': tempDir.path},
      ),
      log: LogService(),
    );
    await state.bootstrap();
    expect(state.database, isNotNull, reason: '临时目录中的数据库应可打开');
  });

  tearDown(() async {
    if (!primaryDisposed) {
      state.dispose();
      primaryDisposed = true;
    }
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  /// 直接写入一条历史记录，便于精确控制 `completed` 与时长。
  void seed({
    required int positionMs,
    int durationMs = 0,
    bool? completed,
    String siteKey = 'site-a',
    String vodId = 'vod-1',
    String flag = 'line-1',
    String episodeId = 'http://h/ep1',
  }) {
    state.database!.upsertHistory(
      siteKey: siteKey,
      vodId: vodId,
      vodName: '测试影片',
      flag: flag,
      episodeName: '第 1 集',
      episodeId: episodeId,
      positionMs: positionMs,
      durationMs: durationMs,
      completed: completed,
    );
  }

  Duration? resume({
    String siteKey = 'site-a',
    String vodId = 'vod-1',
    String flag = 'line-1',
    String episodeId = 'http://h/ep1',
  }) => state.resumePositionFor(
    siteKey: siteKey,
    vodId: vodId,
    flag: flag,
    episodeId: episodeId,
  );

  group('续播位置判定（§15.2）', () {
    test('有历史且未看完 → 返回历史位置', () {
      seed(positionMs: 90 * 1000, durationMs: 40 * 60 * 1000);
      expect(resume(), const Duration(seconds: 90));
    });

    test('位置不足 5 秒 → 不续播', () {
      seed(positionMs: 4999, durationMs: 40 * 60 * 1000);
      expect(resume(), isNull);

      seed(positionMs: 5000, durationMs: 40 * 60 * 1000);
      expect(
        resume(),
        const Duration(seconds: 5),
        reason: '正好达到阈值应续播',
      );
    });

    test('已看完（completed）→ 不续播，从头播放', () {
      seed(positionMs: 30 * 60 * 1000, durationMs: 40 * 60 * 1000, completed: true);
      expect(resume(), isNull);
    });

    test('距结尾不足 5 秒 → 视为看完，不续播', () {
      seed(positionMs: 40 * 60 * 1000 - 1000, durationMs: 40 * 60 * 1000);
      expect(resume(), isNull);

      seed(positionMs: 40 * 60 * 1000 - 6000, durationMs: 40 * 60 * 1000);
      expect(resume(), isNotNull, reason: '距结尾 6 秒仍应续播');
    });

    test('无历史记录 → 不续播', () {
      expect(resume(), isNull);
      expect(resume(vodId: 'other'), isNull);
    });

    test('按 flag 与 episodeId 精确匹配，不同剧集互不串扰', () {
      seed(positionMs: 100 * 1000, flag: 'line-1', episodeId: 'http://h/ep1');
      seed(
        positionMs: 200 * 1000,
        flag: 'line-2',
        episodeId: 'http://h/ep1',
      );

      expect(resume(flag: 'line-1'), const Duration(seconds: 100));
      expect(resume(flag: 'line-2'), const Duration(seconds: 200));
      // 未记录过的剧集不续播。
      expect(resume(episodeId: 'http://h/ep999'), isNull);
    });

    test('完成后再次播放到新位置会覆盖旧的 completed 状态', () {
      seed(positionMs: 30 * 60 * 1000, durationMs: 40 * 60 * 1000, completed: true);
      expect(resume(), isNull);

      // 重新观看并停留到中间位置。
      seed(positionMs: 12 * 60 * 1000, durationMs: 40 * 60 * 1000, completed: false);
      expect(resume(), const Duration(minutes: 12));
    });
  });

  group('recordProgress 端到端（§15.2）', () {
    test('写入进度后可读回并用于续播', () {
      final vod = Vod(vodId: 'vod-9', vodName: '端到端影片');
      state.recordProgress(
        vod: vod,
        flag: 'line-a',
        episodeName: '第 2 集',
        episodeId: 'http://h/ep2',
        position: const Duration(minutes: 7),
        duration: const Duration(minutes: 45),
        siteKey: 'site-z',
      );

      final history = state.recentHistory();
      expect(history, isNotEmpty);
      expect(history.first.vodId, 'vod-9');
      expect(history.first.progressPercent, greaterThan(0));

      expect(
        state.resumePositionFor(
          siteKey: 'site-z',
          vodId: 'vod-9',
          flag: 'line-a',
          episodeId: 'http://h/ep2',
        ),
        const Duration(minutes: 7),
      );
    });

    test('播放到结尾写入的进度被标记为 completed 且不再续播', () {
      final vod = Vod(vodId: 'vod-10', vodName: '看完的影片');
      state.recordProgress(
        vod: vod,
        flag: 'line-a',
        episodeName: '第 1 集',
        episodeId: 'http://h/ep1',
        position: const Duration(minutes: 45),
        duration: const Duration(minutes: 45),
        siteKey: 'site-z',
      );

      expect(
        state.resumePositionFor(
          siteKey: 'site-z',
          vodId: 'vod-10',
          flag: 'line-a',
          episodeId: 'http://h/ep1',
        ),
        isNull,
      );
      expect(state.recentHistory().first.completed, isTrue);
    });

    test('跨重启（重新打开数据库）后仍能续播', () async {
      state.recordProgress(
        vod: Vod(vodId: 'vod-11', vodName: '重启影片'),
        flag: 'line-a',
        episodeName: '第 3 集',
        episodeId: 'http://h/ep3',
        position: const Duration(minutes: 22),
        duration: const Duration(minutes: 60),
        siteKey: 'site-z',
      );
      state.dispose();
      primaryDisposed = true;
      // 模拟重启：同一路径重新打开。
      final reopened = AppState(
        paths: AppPaths.resolve(
          overrides: {'roaming': tempDir.path, 'local': tempDir.path},
        ),
        log: LogService(),
      );
      await reopened.bootstrap();
      expect(
        reopened.resumePositionFor(
          siteKey: 'site-z',
          vodId: 'vod-11',
          flag: 'line-a',
          episodeId: 'http://h/ep3',
        ),
        const Duration(minutes: 22),
      );
      reopened.dispose();
    });
  });
}
