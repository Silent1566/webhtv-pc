/// Phase 4 · TMDB 分段校验与扁平切片（`docs/phase4/design/02` §5.3、§3.3）。
///
/// 对应门禁：`docs/phase4/design/05` §3.7「分段有效性 8 条 / flatSeasonSegments /
/// 段长越界 / 单段」。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/tmdb_season.dart';

void main() {
  group('分段有效性 8 条（§5.3）—— 逐条反例', () {
    const tmdbSeasons = [1, 2];
    const counts = {1: 12, 2: 10};

    bool valid(List<SeasonSegment> segments, {int sourceEpisodeCount = 10}) =>
        hasValidPersistedSegments(
          segments: segments,
          tmdbSeasons: tmdbSeasons,
          seasonCounts: counts,
          sourceEpisodeCount: sourceEpisodeCount,
        );

    const okSegments = [
      SeasonSegment(
        seasonNumber: 1,
        sourceEpisodeStartIndex: 0,
        sourceEpisodeEndIndex: 4,
        tmdbEpisodeStartNumber: 1,
      ),
      SeasonSegment(
        seasonNumber: 2,
        sourceEpisodeStartIndex: 5,
        sourceEpisodeEndIndex: 9,
        tmdbEpisodeStartNumber: 1,
      ),
    ];

    test('基准：8 条全满足 → 有效', () {
      expect(valid(okSegments), isTrue);
    });

    test('1. segments.size() < 2 → 无效', () {
      expect(valid(okSegments.take(1).toList()), isFalse);
      expect(valid(const []), isFalse);
    });

    test('2. sourceEpisodeCount <= 0 → 无效', () {
      expect(valid(okSegments, sourceEpisodeCount: 0), isFalse);
      expect(valid(okSegments, sourceEpisodeCount: -1), isFalse);
    });

    test('3. seasonNumber 不在 tmdbSeasons → 无效', () {
      const segments = [
        SeasonSegment(
          seasonNumber: 1,
          sourceEpisodeStartIndex: 0,
          sourceEpisodeEndIndex: 4,
          tmdbEpisodeStartNumber: 1,
        ),
        SeasonSegment(
          seasonNumber: 3,
          sourceEpisodeStartIndex: 5,
          sourceEpisodeEndIndex: 9,
          tmdbEpisodeStartNumber: 1,
        ),
      ];
      expect(valid(segments), isFalse);
    });

    test('4. 首段 startIndex != 0 → 无效', () {
      const segments = [
        SeasonSegment(
          seasonNumber: 1,
          sourceEpisodeStartIndex: 2,
          sourceEpisodeEndIndex: 4,
          tmdbEpisodeStartNumber: 1,
        ),
        SeasonSegment(
          seasonNumber: 2,
          sourceEpisodeStartIndex: 5,
          sourceEpisodeEndIndex: 9,
          tmdbEpisodeStartNumber: 1,
        ),
      ];
      expect(valid(segments), isFalse);
    });

    test('4. 段间不连续（有空洞）→ 无效', () {
      const segments = [
        SeasonSegment(
          seasonNumber: 1,
          sourceEpisodeStartIndex: 0,
          sourceEpisodeEndIndex: 3,
          tmdbEpisodeStartNumber: 1,
        ),
        SeasonSegment(
          seasonNumber: 2,
          sourceEpisodeStartIndex: 5,
          sourceEpisodeEndIndex: 9,
          tmdbEpisodeStartNumber: 1,
        ),
      ];
      expect(valid(segments), isFalse);
    });

    test('4. 段间重叠 → 无效', () {
      const segments = [
        SeasonSegment(
          seasonNumber: 1,
          sourceEpisodeStartIndex: 0,
          sourceEpisodeEndIndex: 5,
          tmdbEpisodeStartNumber: 1,
        ),
        SeasonSegment(
          seasonNumber: 2,
          sourceEpisodeStartIndex: 5,
          sourceEpisodeEndIndex: 9,
          tmdbEpisodeStartNumber: 1,
        ),
      ];
      expect(valid(segments), isFalse);
    });

    test('5. endIndex < startIndex → 无效', () {
      const segments = [
        SeasonSegment(
          seasonNumber: 1,
          sourceEpisodeStartIndex: 0,
          sourceEpisodeEndIndex: 4,
          tmdbEpisodeStartNumber: 1,
        ),
        SeasonSegment(
          seasonNumber: 2,
          sourceEpisodeStartIndex: 5,
          sourceEpisodeEndIndex: 4,
          tmdbEpisodeStartNumber: 1,
        ),
      ];
      expect(valid(segments), isFalse);
    });

    test('5. endIndex >= sourceEpisodeCount → 无效', () {
      const segments = [
        SeasonSegment(
          seasonNumber: 1,
          sourceEpisodeStartIndex: 0,
          sourceEpisodeEndIndex: 4,
          tmdbEpisodeStartNumber: 1,
        ),
        SeasonSegment(
          seasonNumber: 2,
          sourceEpisodeStartIndex: 5,
          sourceEpisodeEndIndex: 10,
          tmdbEpisodeStartNumber: 1,
        ),
      ];
      expect(valid(segments), isFalse);
    });

    test('6. tmdbEpisodeStartNumber <= 0 → 无效', () {
      const zero = [
        SeasonSegment(
          seasonNumber: 1,
          sourceEpisodeStartIndex: 0,
          sourceEpisodeEndIndex: 4,
          tmdbEpisodeStartNumber: 0,
        ),
        SeasonSegment(
          seasonNumber: 2,
          sourceEpisodeStartIndex: 5,
          sourceEpisodeEndIndex: 9,
          tmdbEpisodeStartNumber: 1,
        ),
      ];
      expect(valid(zero), isFalse);
      const negative = [
        SeasonSegment(
          seasonNumber: 1,
          sourceEpisodeStartIndex: 0,
          sourceEpisodeEndIndex: 4,
          tmdbEpisodeStartNumber: -1,
        ),
        SeasonSegment(
          seasonNumber: 2,
          sourceEpisodeStartIndex: 5,
          sourceEpisodeEndIndex: 9,
          tmdbEpisodeStartNumber: 1,
        ),
      ];
      expect(valid(negative), isFalse);
    });

    test('7. 段长越界（start + len - 1 > count）→ 无效', () {
      const segments = [
        SeasonSegment(
          seasonNumber: 1,
          sourceEpisodeStartIndex: 0,
          sourceEpisodeEndIndex: 4,
          tmdbEpisodeStartNumber: 10, // 10 + 5 - 1 = 14 > 12
        ),
        SeasonSegment(
          seasonNumber: 2,
          sourceEpisodeStartIndex: 5,
          sourceEpisodeEndIndex: 9,
          tmdbEpisodeStartNumber: 1,
        ),
      ];
      expect(valid(segments), isFalse);
    });

    test('7. 恰好贴边（start + len - 1 == count）→ 有效', () {
      const segments = [
        SeasonSegment(
          seasonNumber: 1,
          sourceEpisodeStartIndex: 0,
          sourceEpisodeEndIndex: 4,
          tmdbEpisodeStartNumber: 8, // 8 + 5 - 1 = 12 == 12
        ),
        SeasonSegment(
          seasonNumber: 2,
          sourceEpisodeStartIndex: 5,
          sourceEpisodeEndIndex: 9,
          tmdbEpisodeStartNumber: 6, // 6 + 5 - 1 = 10 == 10
        ),
      ];
      expect(valid(segments), isTrue);
    });

    test('7. 季度集数为 0 或缺失 → 无效', () {
      const segments = [
        SeasonSegment(
          seasonNumber: 1,
          sourceEpisodeStartIndex: 0,
          sourceEpisodeEndIndex: 4,
          tmdbEpisodeStartNumber: 1,
        ),
        SeasonSegment(
          seasonNumber: 2,
          sourceEpisodeStartIndex: 5,
          sourceEpisodeEndIndex: 9,
          tmdbEpisodeStartNumber: 1,
        ),
      ];
      expect(
        hasValidPersistedSegments(
          segments: segments,
          tmdbSeasons: tmdbSeasons,
          seasonCounts: const {1: 12},
          sourceEpisodeCount: 10,
        ),
        isFalse,
      );
    });

    test('8. 末段 endIndex + 1 != sourceEpisodeCount → 无效', () {
      const short = [
        SeasonSegment(
          seasonNumber: 1,
          sourceEpisodeStartIndex: 0,
          sourceEpisodeEndIndex: 4,
          tmdbEpisodeStartNumber: 1,
        ),
        SeasonSegment(
          seasonNumber: 2,
          sourceEpisodeStartIndex: 5,
          sourceEpisodeEndIndex: 8,
          tmdbEpisodeStartNumber: 1,
        ),
      ];
      expect(valid(short), isFalse);
    });
  });

  group('completeSeasonSegments（§3.3 第 6/13 步）', () {
    test('三季连续分段', () {
      final segments = completeSeasonSegments(
        const [1, 2, 3],
        const {1: 3, 2: 2, 3: 4},
      );
      expect(segments.length, 3);
      expect(segments[0].sourceEpisodeStartIndex, 0);
      expect(segments[0].sourceEpisodeEndIndex, 2);
      expect(segments[1].sourceEpisodeStartIndex, 3);
      expect(segments[1].sourceEpisodeEndIndex, 4);
      expect(segments[2].sourceEpisodeStartIndex, 5);
      expect(segments[2].sourceEpisodeEndIndex, 8);
      // 全部 tmdbEpisodeStartNumber 为 1（各季从头开始）
      expect(segments.every((s) => s.tmdbEpisodeStartNumber == 1), isTrue);
    });

    test('生成的分段必须通过 8 条校验', () {
      const counts = {1: 3, 2: 2, 3: 4};
      final segments = completeSeasonSegments(const [1, 2, 3], counts);
      expect(
        hasValidPersistedSegments(
          segments: segments,
          tmdbSeasons: const [1, 2, 3],
          seasonCounts: counts,
          sourceEpisodeCount: 9,
        ),
        isTrue,
      );
    });

    test('单季 / 空季 / 集数 0 → 空', () {
      expect(completeSeasonSegments(const [1], const {1: 5}), isEmpty);
      expect(completeSeasonSegments(const [], const {}), isEmpty);
      expect(completeSeasonSegments(const [1, 2], const {1: 3, 2: 0}), isEmpty);
      expect(completeSeasonSegments(const [1, 2], const {1: 3}), isEmpty);
    });
  });

  group('sliceBySeasonCounts（§4.5）', () {
    final episodes = List.generate(22, (i) => 'E${i + 1}');

    test('按季集数切出正确区间', () {
      expect(
        sliceBySeasonCounts(episodes, const [1, 2], const {1: 12, 2: 10}, 1),
        episodes.sublist(0, 12),
      );
      expect(
        sliceBySeasonCounts(episodes, const [1, 2], const {1: 12, 2: 10}, 2),
        episodes.sublist(12, 22),
      );
    });

    test('越界返回空（不补集）', () {
      expect(
        sliceBySeasonCounts(
          episodes.sublist(0, 8),
          const [1],
          const {1: 12},
          1,
        ),
        isEmpty,
      );
    });

    test('季度不在列表 / 列表为空 / 集数为 0 → 空', () {
      expect(
        sliceBySeasonCounts(episodes, const [1, 2], const {1: 12, 2: 10}, 9),
        isEmpty,
      );
      expect(
        sliceBySeasonCounts(const <String>[], const [1], const {1: 12}, 1),
        isEmpty,
      );
      expect(
        sliceBySeasonCounts(episodes, const [1, 2], const {1: 12, 2: 0}, 2),
        isEmpty,
      );
      expect(
        sliceBySeasonCounts(episodes, const [], const {}, 1),
        isEmpty,
      );
    });
  });

  group('mapFlatEpisodeNumber 边界（§4.6）', () {
    const counts = {1: 3, 2: 2, 3: 4};

    test('逐集映射', () {
      expect(mapFlatEpisodeNumber(1, const [1, 2, 3], counts),
          (seasonNumber: 1, episodeNumber: 1));
      expect(mapFlatEpisodeNumber(3, const [1, 2, 3], counts),
          (seasonNumber: 1, episodeNumber: 3));
      expect(mapFlatEpisodeNumber(4, const [1, 2, 3], counts),
          (seasonNumber: 2, episodeNumber: 1));
      expect(mapFlatEpisodeNumber(5, const [1, 2, 3], counts),
          (seasonNumber: 2, episodeNumber: 2));
      expect(mapFlatEpisodeNumber(6, const [1, 2, 3], counts),
          (seasonNumber: 3, episodeNumber: 1));
      expect(mapFlatEpisodeNumber(9, const [1, 2, 3], counts),
          (seasonNumber: 3, episodeNumber: 4));
    });

    test('越界与非法输入', () {
      expect(mapFlatEpisodeNumber(10, const [1, 2, 3], counts), isNull);
      expect(mapFlatEpisodeNumber(0, const [1, 2, 3], counts), isNull);
      expect(mapFlatEpisodeNumber(-5, const [1, 2, 3], counts), isNull);
      expect(mapFlatEpisodeNumber(1, const [], counts), isNull);
      expect(mapFlatEpisodeNumber(1, const [1], const {1: 0}), isNull);
    });

    test('特别篇（season 0）参与映射', () {
      expect(mapFlatEpisodeNumber(1, const [0, 1], const {0: 3, 1: 12}),
          (seasonNumber: 0, episodeNumber: 1));
      expect(mapFlatEpisodeNumber(4, const [0, 1], const {0: 3, 1: 12}),
          (seasonNumber: 1, episodeNumber: 1));
    });
  });

  group('mappedSeasonsByEpisodeNumbers（§4.3 E）', () {
    test('多季映射', () {
      expect(
        mappedSeasonsByEpisodeNumbers(
          const [1, 2, 4, 5, 6],
          const [1, 2],
          const {1: 3, 2: 3},
        ),
        [1, 2],
      );
    });

    test('单季映射返回单元素列表', () {
      expect(
        mappedSeasonsByEpisodeNumbers(
          const [1, 2, 3],
          const [1, 2],
          const {1: 3, 2: 3},
        ),
        [1],
      );
    });

    test('任一集无法映射 → 空（不部分成功）', () {
      expect(
        mappedSeasonsByEpisodeNumbers(
          const [1, 2, 99],
          const [1, 2],
          const {1: 3, 2: 3},
        ),
        isEmpty,
      );
    });

    test('空输入 → 空', () {
      expect(
        mappedSeasonsByEpisodeNumbers(null, const [1], const {1: 3}),
        isEmpty,
      );
      expect(
        mappedSeasonsByEpisodeNumbers(const [], const [1], const {1: 3}),
        isEmpty,
      );
    });
  });

  group('SeasonSegment 与 MultiSeason 集成', () {
    test('MultiSeason.segmentFor 精确定位段', () {
      const multi = MultiSeason([
        SeasonSegment(
          seasonNumber: 1,
          sourceEpisodeStartIndex: 0,
          sourceEpisodeEndIndex: 2,
          tmdbEpisodeStartNumber: 1,
        ),
        SeasonSegment(
          seasonNumber: 2,
          sourceEpisodeStartIndex: 3,
          sourceEpisodeEndIndex: 4,
          tmdbEpisodeStartNumber: 1,
        ),
        SeasonSegment(
          seasonNumber: 3,
          sourceEpisodeStartIndex: 5,
          sourceEpisodeEndIndex: 8,
          tmdbEpisodeStartNumber: 1,
        ),
      ]);
      expect(multi.segmentFor(1)?.sourceEpisodeEndIndex, 2);
      expect(multi.segmentFor(3)?.sourceEpisodeStartIndex, 5);
      expect(multi.segmentFor(9), isNull);
      expect(multi.seasons, [1, 2, 3]);
      expect(multi.isKnown, isTrue);
    });

    test('MultiSeason 相等性与 hashCode', () {
      const segments = [
        SeasonSegment(
          seasonNumber: 1,
          sourceEpisodeStartIndex: 0,
          sourceEpisodeEndIndex: 2,
          tmdbEpisodeStartNumber: 1,
        ),
        SeasonSegment(
          seasonNumber: 2,
          sourceEpisodeStartIndex: 3,
          sourceEpisodeEndIndex: 4,
          tmdbEpisodeStartNumber: 1,
        ),
      ];
      expect(const MultiSeason(segments), const MultiSeason(segments));
      expect(const MultiSeason(segments).hashCode, isNotNull);
    });
  });

  group('encodeSegments / decodeSegments 往返（存储用）', () {
    test('往返一致', () {
      const segments = [
        SeasonSegment(
          seasonNumber: 1,
          sourceEpisodeStartIndex: 0,
          sourceEpisodeEndIndex: 2,
          tmdbEpisodeStartNumber: 1,
        ),
        SeasonSegment(
          seasonNumber: 2,
          sourceEpisodeStartIndex: 3,
          sourceEpisodeEndIndex: 4,
          tmdbEpisodeStartNumber: 2,
        ),
      ];
      expect(decodeSegments(encodeSegments(segments)), segments);
    });

    test('容错：非法 JSON / 非数组 / 缺字段', () {
      expect(decodeSegments(null), isEmpty);
      expect(decodeSegments(''), isEmpty);
      expect(decodeSegments('   '), isEmpty);
      expect(decodeSegments('not json'), isEmpty);
      expect(decodeSegments('{"a":1}'), isEmpty);
      expect(decodeSegments('[{"seasonNumber":1}]'), isEmpty);
      expect(decodeSegments('[1, 2, 3]'), isEmpty);
    });
  });
}
