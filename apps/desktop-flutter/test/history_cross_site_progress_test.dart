/// 详情页「同配置内跨爬虫源进度」的纯逻辑门禁。
///
/// 这层最容易错的是**集对齐**：换一个爬虫源后，同一部剧的集名、集号、线路名
/// 全都不一样，任何一处「差不多就对上了」都会把用户送到别的集、迁移错的进度
/// （`docs/phase6/design/01` §4.1：宁可不续播，不可错续播）。
/// 因此每条规则都要求**唯一命中**，歧义一律返回 `null`——本文件把这些钉子逐条钉住。
///
/// 另一组门禁是「哪些记录算可续播」：它与 `AppState.resumePositionFor` 的三条
/// 否决（已看完、位置过短、贴着片尾）必须同口径，否则卡片标了进度、点进去却从头开始。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/history_cross_site.dart';
import 'package:webhtv_pc/core/protocol.dart';

void main() {
  VodPlayLine lineOf(
    String flag,
    List<(String, String)> episodes, {
    String? sourceFlag,
  }) => VodPlayLine(
    flag: flag,
    sourceFlag: sourceFlag,
    episodes: [
      for (final (name, url) in episodes) VodEpisode(name: name, url: url),
    ],
  );

  HistoryCandidate candidateOf({
    String siteKey = 'site-b',
    String vodId = 'b-1',
    String flag = '线路一',
    String episodeName = '第1集',
    String episodeId = 'https://b/e1',
    int positionMs = 600000,
    int durationMs = 2400000,
    int updatedAt = 1000,
    bool completed = false,
  }) => HistoryCandidate(
    siteKey: siteKey,
    vodId: vodId,
    flag: flag,
    episodeName: episodeName,
    episodeId: episodeId,
    positionMs: positionMs,
    durationMs: durationMs,
    updatedAt: updatedAt,
    completed: completed,
  );

  group('候选映射到当前线路：只认唯一命中', () {
    final line = lineOf('线路一', [
      ('第1集', 'https://a/e1'),
      ('第2集', 'https://a/e2'),
      ('第3集', 'https://a/e3'),
    ]);

    test('跨站集名一致时按集名对齐', () {
      final mapped = mapHistoryCandidateToLine(
        candidate: candidateOf(episodeName: '第2集', episodeId: 'https://b/e2'),
        line: line,
      );
      expect(mapped, isNotNull);
      expect(mapped!.episodeIndex, 1);
      expect(mapped.episodeName, '第2集');
    });

    test('集名不同但集号一致时按集号对齐（第3集 vs EP03）', () {
      final other = lineOf('线路一', [
        ('EP01', 'https://a/e1'),
        ('EP02', 'https://a/e2'),
        ('EP03', 'https://a/e3'),
      ]);
      final mapped = mapHistoryCandidateToLine(
        candidate: candidateOf(episodeName: '第3集', episodeId: 'https://b/e3'),
        line: other,
      );
      expect(mapped?.episodeIndex, 2);
    });

    test('集名与集号都无法唯一命中时返回 null（不猜）', () {
      final ambiguous = lineOf('线路一', [
        ('第1集', 'https://a/e1'),
        ('第1集', 'https://a/e1b'),
      ]);
      expect(
        mapHistoryCandidateToLine(
          candidate: candidateOf(episodeName: '第1集', episodeId: 'https://b/e1'),
          line: ambiguous,
        ),
        isNull,
      );
    });

    test('集入口 URL 精确命中优先于集名歧义', () {
      final sameSite = lineOf('线路一', [
        ('第1集', 'https://a/e1'),
        ('第1集', 'https://a/e1b'),
      ]);
      final mapped = mapHistoryCandidateToLine(
        candidate: candidateOf(episodeName: '第1集', episodeId: 'https://a/e1b'),
        line: sameSite,
      );
      expect(mapped?.episodeIndex, 1);
    });

    test('季度不同时拒绝（S02E05 不得落到 S01E05）', () {
      final season1 = lineOf('线路一', [
        ('S01E05', 'https://a/s1e5'),
      ]);
      expect(
        mapHistoryCandidateToLine(
          candidate: candidateOf(episodeName: 'S02E05', episodeId: ''),
          line: season1,
        ),
        isNull,
      );
    });

    test('单集线路（电影）按「整部就是这一集」对齐', () {
      final movie = lineOf('线路一', [('正片', 'https://a/movie')]);
      final mapped = mapHistoryCandidateToLine(
        candidate: candidateOf(episodeName: 'HD中字', episodeId: 'https://b/movie'),
        line: movie,
      );
      expect(mapped?.episodeIndex, 0);
    });

    test('空集名/空线路不抛错，且不产生映射', () {
      expect(
        mapHistoryCandidateToLine(
          candidate: candidateOf(episodeName: '', episodeId: ''),
          line: line,
        ),
        isNull,
      );
      expect(
        mapHistoryCandidateToLine(
          candidate: candidateOf(episodeName: '第1集'),
          line: lineOf('线路一', const []),
        ),
        isNull,
      );
    });
  });

  group('进度投影：最近观看排序 + 可续播判定', () {
    final line = lineOf('线路一', [
      ('第1集', 'https://a/e1'),
      ('第2集', 'https://a/e2'),
      ('第3集', 'https://a/e3'),
    ]);

    test('按最近观看倒序；primary 取最近的可续播记录', () {
      final progress = buildCrossSiteProgress(
        candidates: [
          candidateOf(episodeName: '第1集', episodeId: 'https://b/e1', updatedAt: 100, positionMs: 600000),
          candidateOf(episodeName: '第3集', episodeId: 'https://b/e3', updatedAt: 300, completed: true),
          candidateOf(episodeName: '第2集', episodeId: 'https://b/e2', updatedAt: 200, positionMs: 900000),
        ],
        line: line,
      );
      expect(progress.mapped.map((m) => m.episodeName).toList(), ['第3集', '第2集', '第1集']);
      expect(progress.resumable.map((m) => m.episodeName).toList(), ['第2集', '第1集']);
      expect(progress.primary?.episodeName, '第2集');
      expect(progress.needsChoice, isTrue);
    });

    test('只有一条可续播记录时不弹选择框', () {
      final progress = buildCrossSiteProgress(
        candidates: [
          candidateOf(episodeName: '第1集', episodeId: 'https://b/e1', updatedAt: 100),
          candidateOf(episodeName: '第2集', episodeId: 'https://b/e2', updatedAt: 200, completed: true),
        ],
        line: line,
      );
      expect(progress.resumable, hasLength(1));
      expect(progress.needsChoice, isFalse);
      expect(progress.primary?.episodeName, '第1集');
    });

    test('位置过短 / 已看完 / 贴片尾都不算可续播', () {
      expect(candidateOf(positionMs: 4999).hasResumePosition, isFalse);
      expect(
        hasResumePositionMs(positionMs: 600000, durationMs: 2400000, completed: false),
        isTrue,
        reason: '详情页把本站记录投影成候选时用的是同一个判定',
      );
      expect(
        hasResumePositionMs(positionMs: 600000, durationMs: 2400000, completed: true),
        isFalse,
      );
      expect(candidateOf(completed: true).hasResumePosition, isFalse);
      expect(candidateOf(positionMs: 2396000, durationMs: 2400000).hasResumePosition, isFalse);
      expect(candidateOf(positionMs: 5000).hasResumePosition, isTrue);
      expect(candidateOf(durationMs: 0, positionMs: 600000).hasResumePosition, isTrue);
    });

    test('映射不到任何集时不产生投影（不标、不弹）', () {
      final progress = buildCrossSiteProgress(
        candidates: [candidateOf(episodeName: '花絮', episodeId: 'https://b/x')],
        line: line,
      );
      expect(progress.mapped, isEmpty);
      expect(progress.primary, isNull);
      expect(progress.needsChoice, isFalse);
    });
  });

  group('续播种子：把原记录的身份改写成目标线路自己的身份', () {
    final line = lineOf('线路一', [
      ('第1集', 'https://a/e1'),
      ('第2集', 'https://a/e2'),
    ], sourceFlag: '丫仙女');
    const mapped = MappedHistoryCandidate(
      candidate: HistoryCandidate(
        siteKey: 'site-b',
        vodId: 'b-1',
        flag: '备用线路',
        episodeName: '第2集',
        episodeId: 'https://b/e2',
        positionMs: 650000,
        durationMs: 2400000,
        updatedAt: 1000,
      ),
      episodeIndex: 1,
      episodeName: '第2集',
    );

    test('种子用目标线路的 playbackFlag 与集入口，进度沿用原记录', () {
      final seed = reboundResumeSeed(mapped: mapped, line: line);
      expect(seed, isNotNull);
      expect(seed!.flag, '丫仙女');
      expect(seed.episodeId, 'https://a/e2');
      expect(seed.episodeName, '第2集');
      expect(seed.positionMs, 650000);
      expect(seed.durationMs, 2400000);
      expect(seed.completed, isFalse);
    });
  });

  group('展示文案的纯格式化', () {
    test('观看时长按时/分/秒展开', () {
      expect(clockText(0), '00:00');
      expect(clockText(65000), '01:05');
      expect(clockText(3665000), '1:01:05');
    });

    test('观看时间用相对说法，超过一周退化成日期', () {
      const now = 1700000000000;
      expect(watchedAgoLabel(now + 5000, nowMs: now), '刚刚');
      expect(watchedAgoLabel(now - 5 * 60 * 1000, nowMs: now), '5 分钟前');
      expect(watchedAgoLabel(now - 3 * 3600 * 1000, nowMs: now), '3 小时前');
      expect(watchedAgoLabel(now - 2 * 86400 * 1000, nowMs: now), '2 天前');
      expect(watchedAgoLabel(0, nowMs: now), '');
      expect(
        watchedAgoLabel(now - 30 * 86400 * 1000, nowMs: now),
        matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')),
      );
    });
  });
}
