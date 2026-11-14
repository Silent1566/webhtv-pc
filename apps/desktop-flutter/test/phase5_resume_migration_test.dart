/// 跨源续播的匹配与进度迁移（`core/resume_matching.dart` / `core/resume_migration.dart`）。
///
/// 这两条是本功能最容易写错的语义，必须在无窗口环境下锁死：
///
/// 1. **置信分级**：TMDB 一致才最高；片名一致但缺年份**不升格**；
/// 2. **硬闸门**：不是同一集、已看完、位置过短一律不迁移
///    （「宁可不续播，不可错续播」）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/resume_matching.dart';
import 'package:webhtv_pc/core/resume_migration.dart';

ResumeRequest req({
  String vodName = '庆余年',
  String vodYear = '2019',
  int tmdbId = 0,
  String mediaType = '',
}) => ResumeRequest(
      vodName: vodName,
      vodYear: vodYear,
      tmdbId: tmdbId,
      mediaType: mediaType,
    );

ResumeCandidate cand({
  String siteKey = 'csp_a',
  String vodId = 'v1',
  String vodName = '庆余年',
  String vodYear = '2019',
  int tmdbId = 0,
  String mediaType = '',
  bool hasTargetEpisode = true,
}) => ResumeCandidate(
      siteKey: siteKey,
      siteName: siteKey,
      vodId: vodId,
      vodName: vodName,
      vodYear: vodYear,
      tmdbId: tmdbId,
      mediaType: mediaType,
      hasTargetEpisode: hasTargetEpisode,
    );

void main() {
  group('rateCandidate', () {
    test('TMDB 身份一致 → 最高置信', () {
      final result = rateCandidate(
        req(tmdbId: 1234, mediaType: 'tv'),
        cand(tmdbId: 1234, mediaType: 'tv', vodName: '完全不同的片名'),
      );
      expect(result, MatchConfidence.tmdb);
      expect(MatchConfidence.canAutoPlay(result), isTrue);
    });

    test('TMDB 冲突 → 直接拒绝（即使片名一致）', () {
      final result = rateCandidate(
        req(tmdbId: 1, mediaType: 'tv'),
        cand(tmdbId: 2, mediaType: 'tv'),
      );
      expect(result, MatchConfidence.rejected);
      expect(MatchConfidence.canAutoPlay(result), isFalse);
    });

    test('电影与剧集同 ID → 拒绝', () {
      expect(
        rateCandidate(
          req(tmdbId: 7, mediaType: 'movie'),
          cand(tmdbId: 7, mediaType: 'tv'),
        ),
        MatchConfidence.rejected,
      );
    });

    test('片名 + 年份一致 → 中置信，可自动播放', () {
      final result = rateCandidate(req(), cand());
      expect(result, MatchConfidence.titleYear);
      expect(MatchConfidence.canAutoPlay(result), isTrue);
    });

    test('片名一致但一方年份缺失 → 歧义（不升格）', () {
      expect(
        rateCandidate(req(vodYear: ''), cand()),
        MatchConfidence.ambiguous,
      );
      expect(
        rateCandidate(req(), cand(vodYear: '')),
        MatchConfidence.ambiguous,
      );
    });

    test('年份明确冲突 → 拒绝', () {
      expect(
        rateCandidate(req(vodYear: '2019'), cand(vodYear: '1999')),
        MatchConfidence.rejected,
      );
    });

    test('片名不同 → 歧义（仅包含关系也不认）', () {
      expect(
        rateCandidate(req(vodName: '庆余年'), cand(vodName: '庆余年外传')),
        MatchConfidence.ambiguous,
      );
    });

    test('季度标记被归一化掉 → 仍视为同一部作品', () {
      // `normalizeSourceTitle` 会清掉「第二季」这类季度信号，这是聚合与
      // 匹配都依赖的前提：同一部剧在不同源上的标题往往带不同的季度后缀。
      expect(
        rateCandidate(req(vodName: '庆余年'), cand(vodName: '庆余年 第二季')),
        MatchConfidence.titleYear,
      );
    });

    test('一方有 TMDB 一方没有 → 退回标题级', () {
      expect(
        rateCandidate(req(tmdbId: 5, mediaType: 'tv'), cand()),
        MatchConfidence.titleYear,
      );
    });
  });

  group('rankCandidates / pickAutoPlayable', () {
    test('按等级排序，且同等级保留输入顺序', () {
      final ranked = rankCandidates(req(), [
        cand(vodName: '无关', vodId: 'x1'),
        cand(vodId: 'x2'),
        cand(vodName: '无关2', vodId: 'x3'),
      ]);
      expect([for (final r in ranked) r.candidate.vodId], ['x2', 'x1', 'x3']);
      expect(ranked.first.confidence, MatchConfidence.titleYear);
    });

    test('找到目标集的候选优先于没找到的同等级候选', () {
      final ranked = rankCandidates(req(), [
        cand(vodId: 'no-target', hasTargetEpisode: false),
        cand(vodId: 'has-target', hasTargetEpisode: true),
      ]);
      expect(ranked.first.candidate.vodId, 'has-target');
    });

    test('只有歧义候选时不自动播放', () {
      final ranked = rankCandidates(req(vodYear: ''), [cand()]);
      expect(pickAutoPlayable(ranked), isNull);
    });

    test('高置信但没找到目标集时也不自动播放', () {
      final ranked = rankCandidates(req(), [
        cand(hasTargetEpisode: false),
      ]);
      expect(pickAutoPlayable(ranked), isNull);
    });

    test('高置信且找到目标集时返回该候选', () {
      final ranked = rankCandidates(req(), [cand(vodId: 'ok')]);
      expect(pickAutoPlayable(ranked)?.vodId, 'ok');
    });
  });

  group('ResumePositionPolicy.migrate', () {
    test('不是同一集 → 不迁移', () {
      expect(
        ResumePositionPolicy.migrate(
          sourcePositionMs: 60000,
          sourceDurationMs: 100000,
          targetDurationMs: 100000,
          sameEpisode: false,
        ),
        isNull,
      );
    });

    test('源记录已看完 → 不迁移', () {
      expect(
        ResumePositionPolicy.migrate(
          sourcePositionMs: 60000,
          sourceDurationMs: 100000,
          targetDurationMs: 100000,
          sameEpisode: true,
          sourceCompleted: true,
        ),
        isNull,
      );
    });

    test('位置过短（< 5s）→ 不迁移', () {
      expect(
        ResumePositionPolicy.migrate(
          sourcePositionMs: 3000,
          sourceDurationMs: 100000,
          targetDurationMs: 100000,
          sameEpisode: true,
        ),
        isNull,
      );
    });

    test('时长接近 → 沿用绝对毫秒', () {
      final result = ResumePositionPolicy.migrate(
        sourcePositionMs: 60000,
        sourceDurationMs: 100000,
        targetDurationMs: 101000,
        sameEpisode: true,
      );
      expect(result, isNotNull);
      expect(result!.positionMs, 60000);
      expect(result.strategy, ResumeMigration.absolute);
    });

    test('时长差异大 → 按比例换算', () {
      // 源 5 分钟 / 目标 2 小时：差异远超 max(10 分钟, 20%)，走比例分支。
      final result = ResumePositionPolicy.migrate(
        sourcePositionMs: 150000,
        sourceDurationMs: 300000,
        targetDurationMs: 7200000,
        sameEpisode: true,
      );
      expect(result, isNotNull);
      // 150s / 300s = 0.5 → 7200s * 0.5 = 3600s
      expect(result!.positionMs, 3600000);
      expect(result.strategy, ResumeMigration.ratio);
    });

    test('差异在 10 分钟内 → 即使比例上偏大也沿用绝对位置', () {
      // 源 1 分钟 / 目标 10 分钟：差异 9 分钟 < 10 分钟下限，按绝对位置。
      final result = ResumePositionPolicy.migrate(
        sourcePositionMs: 30000,
        sourceDurationMs: 60000,
        targetDurationMs: 600000,
        sameEpisode: true,
      );
      expect(result, isNotNull);
      expect(result!.positionMs, 30000);
      expect(result.strategy, ResumeMigration.absolute);
    });

    test('换算后落到结尾 5s 内 → 从头（返回 null）', () {
      expect(
        ResumePositionPolicy.migrate(
          sourcePositionMs: 59000,
          sourceDurationMs: 60000,
          targetDurationMs: 600000,
          sameEpisode: true,
        ),
        isNull,
      );
    });

    test('源时长未知 → 沿用绝对位置', () {
      final result = ResumePositionPolicy.migrate(
        sourcePositionMs: 60000,
        sourceDurationMs: 0,
        targetDurationMs: 0,
        sameEpisode: true,
      );
      expect(result?.positionMs, 60000);
      expect(result?.strategy, ResumeMigration.absolute);
    });

    test('目标时长未知 → 沿用绝对位置', () {
      final result = ResumePositionPolicy.migrate(
        sourcePositionMs: 60000,
        sourceDurationMs: 100000,
        targetDurationMs: 0,
        sameEpisode: true,
      );
      expect(result?.positionMs, 60000);
    });

    test('绝对位置超出目标结尾 → 不迁移', () {
      expect(
        ResumePositionPolicy.migrate(
          sourcePositionMs: 99000,
          sourceDurationMs: 100000,
          targetDurationMs: 90000,
          sameEpisode: true,
        ),
        isNull,
      );
    });
  });
}
