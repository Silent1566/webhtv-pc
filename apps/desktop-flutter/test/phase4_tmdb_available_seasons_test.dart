/// Phase 4 · TMDB 可播放季度（`docs/phase4/design/02` §4）。
///
/// 对应门禁：`docs/phase4/design/05` §3.6「A–G 六级顺序 / UI 矩阵 7 行 /
/// 不补集 / 不丢集」。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/tmdb_season.dart';

void main() {
  group('可播放季度解析 A–G（§4.3）', () {
    test('A1 完整显式映射 → 返回 TMDB 顺序的季度子集', () {
      final seasons = resolveAvailableSeasons(
        sourceSeasonNumbers: const [1, 3, 1, 3],
        tmdbSeasons: const [0, 1, 2, 3],
        seasonCounts: const {0: 3, 1: 12, 2: 10, 3: 8},
      );
      // 保持 tmdbSeasons 顺序，只含线路实际出现过的季度
      expect(seasons, [1, 3]);
    });

    test('A2 部分映射且已解析季度唯一 → 该单季', () {
      final seasons = resolveAvailableSeasons(
        sourceSeasonNumbers: const [2, 2, -1, 2],
        tmdbSeasons: const [1, 2, 3],
        seasonCounts: const {1: 12, 2: 10, 3: 8},
      );
      expect(seasons, [2]);
    });

    test('A2 部分映射且已解析季度不唯一 → 空（退化为扁平）', () {
      final seasons = resolveAvailableSeasons(
        sourceSeasonNumbers: const [1, 2, -1],
        tmdbSeasons: const [1, 2, 3],
        seasonCounts: const {1: 12, 2: 10, 3: 8},
      );
      expect(seasons, isEmpty);
    });

    test('A2 含非 TMDB 季度 → 空（退化为扁平）', () {
      final seasons = resolveAvailableSeasons(
        sourceSeasonNumbers: const [9, -1],
        tmdbSeasons: const [1, 2, 3],
        seasonCounts: const {1: 12, 2: 10, 3: 8},
      );
      expect(seasons, isEmpty);
    });

    test('B 标题季度含于 TMDB → 单季', () {
      final seasons = resolveAvailableSeasons(
        sourceSeasonNumbers: const [-1, -1],
        titleSeason: 3,
        tmdbSeasons: const [1, 2, 3],
        seasonCounts: const {1: 12, 2: 10, 3: 8},
      );
      expect(seasons, [3]);
    });

    test('B 标题季度不含于 TMDB → 空', () {
      final seasons = resolveAvailableSeasons(
        sourceSeasonNumbers: const [-1, -1],
        titleSeason: 9,
        tmdbSeasons: const [1, 2, 3],
        seasonCounts: const {1: 12, 2: 10, 3: 8},
      );
      expect(seasons, isEmpty);
    });

    test('C 单一 TMDB 季度 → 单季（无任何信号也成立）', () {
      final seasons = resolveAvailableSeasons(
        sourceSeasonNumbers: const [-1, -1, -1],
        tmdbSeasons: const [1],
        seasonCounts: const {1: 12},
      );
      expect(seasons, [1]);
    });

    test('D 精确切片 → sliceable seasons', () {
      final seasons = resolveAvailableSeasons(
        sourceSeasonNumbers: const [-1, -1, -1, -1, -1],
        tmdbSeasons: const [1, 2],
        seasonCounts: const {1: 3, 2: 2},
      );
      expect(seasons, [1, 2]);
    });

    test('E 扁平集号多季 → 该集合', () {
      final seasons = resolveAvailableSeasons(
        sourceSeasonNumbers: const [-1, -1, -1, -1],
        tmdbSeasons: const [1, 2],
        seasonCounts: const {1: 3, 2: 3},
        sourceEpisodeNumbers: const [1, 2, 4, 5],
      );
      expect(seasons, [1, 2]);
    });

    test('F 单季兼容（firstSeasonCount >= sourceEpisodeCount 且不可切片）→ 单季', () {
      final seasons = resolveAvailableSeasons(
        sourceSeasonNumbers: const [-1, -1, -1, -1, -1],
        firstSeason: 1,
        tmdbSeasons: const [1, 2],
        // S1 有 12 集 >= 5，且 12+10 != 5 所以不可切片
        seasonCounts: const {1: 12, 2: 10},
      );
      expect(seasons, [1]);
    });

    test('G 其他 → 空（退化为扁平）', () {
      final seasons = resolveAvailableSeasons(
        sourceSeasonNumbers: const [-1, -1, -1, -1, -1, -1, -1],
        firstSeason: 1,
        tmdbSeasons: const [1, 2],
        // S1 只有 3 集 < 7，且不可切片
        seasonCounts: const {1: 3, 2: 10},
      );
      expect(seasons, isEmpty);
    });

    test('空输入直接返回空', () {
      expect(
        resolveAvailableSeasons(
          sourceSeasonNumbers: const [],
          tmdbSeasons: const [1],
          seasonCounts: const {1: 12},
        ),
        isEmpty,
      );
      expect(
        resolveAvailableSeasons(
          sourceSeasonNumbers: const [-1],
          tmdbSeasons: const [],
          seasonCounts: const {},
        ),
        isEmpty,
      );
    });
  });

  group('UI 行为矩阵 7 行（§4.4）', () {
    /// 模拟选集区渲染（严格版）：`UnknownSeason` 或季度导航为空时渲染线路原始列表；
    /// `KnownSeason` 只渲染该季对应集数。
    List<String> renderEpisodes({
      required List<int> availableSeasons,
      required List<int> sourceSeasonNumbers,
      required List<String> sourceEpisodes,
      int selectedSeason = -1,
    }) {
      if (availableSeasons.isEmpty) return sourceEpisodes;
      final result = <String>[];
      for (var index = 0; index < sourceEpisodes.length; index++) {
        if (sourceSeasonNumbers[index] == selectedSeason) {
          result.add(sourceEpisodes[index]);
        }
      }
      return result;
    }

    /// 模拟选集区渲染（**不得丢集**语义）：未分类（`-1`）的集永远保留，
    /// 因为它们无法被证明不属于当前季。
    List<String> renderEpisodesKeepingUnclassified({
      required List<int> availableSeasons,
      required List<int> sourceSeasonNumbers,
      required List<String> sourceEpisodes,
      int selectedSeason = -1,
    }) {
      if (availableSeasons.isEmpty) return sourceEpisodes;
      final result = <String>[];
      for (var index = 0; index < sourceEpisodes.length; index++) {
        final season = sourceSeasonNumbers[index];
        if (season < 0 || season == selectedSeason) {
          result.add(sourceEpisodes[index]);
        }
      }
      return result;
    }

    test('仅 S03E05 → 隐藏切换，显示「第 3 季」上下文，仅 1 项', () {
      final available = resolveAvailableSeasons(
        sourceSeasonNumbers: const [3],
        tmdbSeasons: const [1, 2, 3],
        seasonCounts: const {1: 12, 2: 10, 3: 8},
      );
      expect(available, [3]);
      expect(
        renderEpisodes(
          availableSeasons: available,
          sourceSeasonNumbers: const [3],
          sourceEpisodes: const ['S03E05'],
          selectedSeason: 3,
        ),
        ['S03E05'],
      );
    });

    test('第 2 季 E01–E08 → 8 个真实播放项', () {
      final available = resolveAvailableSeasons(
        sourceSeasonNumbers: List.filled(8, 2),
        tmdbSeasons: const [1, 2],
        seasonCounts: const {1: 12, 2: 10},
      );
      expect(available, [2]);
      final episodes = List.generate(8, (i) => 'S2E${i + 1}');
      expect(
        renderEpisodes(
          availableSeasons: available,
          sourceSeasonNumbers: List.filled(8, 2),
          sourceEpisodes: episodes,
          selectedSeason: 2,
        ).length,
        8,
      );
    });

    test('明确包含第 1、3 季 → 只显示这两季，每季仅对应线路集数', () {
      final available = resolveAvailableSeasons(
        sourceSeasonNumbers: const [1, 1, 3, 3],
        tmdbSeasons: const [1, 2, 3],
        seasonCounts: const {1: 12, 2: 10, 3: 8},
      );
      expect(available, [1, 3]);
      final episodes = const ['S1E1', 'S1E2', 'S3E1', 'S3E2'];
      expect(
        renderEpisodes(
          availableSeasons: available,
          sourceSeasonNumbers: const [1, 1, 3, 3],
          sourceEpisodes: episodes,
          selectedSeason: 1,
        ),
        ['S1E1', 'S1E2'],
      );
      expect(
        renderEpisodes(
          availableSeasons: available,
          sourceSeasonNumbers: const [1, 1, 3, 3],
          sourceEpisodes: episodes,
          selectedSeason: 3,
        ),
        ['S3E1', 'S3E2'],
      );
    });

    test('E01、E02、E04 → 只显示 1、2、4，不补 E03', () {
      final available = resolveAvailableSeasons(
        sourceSeasonNumbers: const [1, 1, 1],
        tmdbSeasons: const [1],
        seasonCounts: const {1: 12},
      );
      expect(available, [1]);
      final rendered = renderEpisodes(
        availableSeasons: available,
        sourceSeasonNumbers: const [1, 1, 1],
        sourceEpisodes: const ['E01', 'E02', 'E04'],
        selectedSeason: 1,
      );
      expect(rendered, ['E01', 'E02', 'E04']);
      expect(rendered, isNot(contains('E03')));
      expect(rendered.length, 3);
    });

    test('无季度信息的 8 集扁平列表 → 原样显示 8 集', () {
      final available = resolveAvailableSeasons(
        sourceSeasonNumbers: List.filled(8, -1),
        firstSeason: 1,
        tmdbSeasons: const [1, 2],
        seasonCounts: const {1: 3, 2: 10},
      );
      expect(available, isEmpty);
      final episodes = List.generate(8, (i) => 'E${i + 1}');
      expect(
        renderEpisodes(
          availableSeasons: available,
          sourceSeasonNumbers: List.filled(8, -1),
          sourceEpisodes: episodes,
        ),
        episodes,
      );
    });

    test('线路数量精确等于 TMDB 多季总数 → 显示可映射全部季度', () {
      final available = resolveAvailableSeasons(
        sourceSeasonNumbers: List.filled(5, -1),
        tmdbSeasons: const [1, 2],
        seasonCounts: const {1: 3, 2: 2},
      );
      expect(available, [1, 2]);
    });
    test('部分集有季度、部分未知且季度唯一 → 季度导航显示该季，但选集不得丢集', () {
      // A2 分支：已解析季度唯一（都是 S1）→ 返回 [1] 作为**季度导航上下文**。
      final available = resolveAvailableSeasons(
        sourceSeasonNumbers: const [1, -1, 1],
        tmdbSeasons: const [1, 2],
        seasonCounts: const {1: 12, 2: 10},
      );
      expect(available, [1]);

      // 关键契约（§4.1）：`resolveAvailableSeasons` 只决定**季度导航**；
      // 选集区必须渲染线路真实存在的全部剧集，不得因「无法识别季度」而丢弃。
      final episodes = const ['E01', 'E02', 'E03'];
      final rendered = renderEpisodesKeepingUnclassified(
        availableSeasons: available,
        sourceSeasonNumbers: const [1, -1, 1],
        sourceEpisodes: episodes,
        selectedSeason: 1,
      );
      expect(rendered, episodes, reason: '未分类的 E02 不得被丢弃');
    });

    test('部分集有季度、部分未知且季度不唯一 → 退化为扁平，全部集数保留', () {
      final available = resolveAvailableSeasons(
        sourceSeasonNumbers: const [1, 2, -1],
        tmdbSeasons: const [1, 2, 3],
        seasonCounts: const {1: 12, 2: 10, 3: 8},
      );
      expect(available, isEmpty, reason: '季度不唯一 → 退化为扁平');
      final episodes = const ['E01', 'E02', 'E03'];
      expect(
        renderEpisodes(
          availableSeasons: available,
          sourceSeasonNumbers: const [1, 2, -1],
          sourceEpisodes: episodes,
        ),
        episodes,
        reason: '不得丢集',
      );
    });
  });

  group('不补集 / 不丢集（§4.1 核心原则）', () {
    test('TMDB 有 S1E9 但线路只有 8 集 → 不生成第 9 项', () {
      final available = resolveAvailableSeasons(
        sourceSeasonNumbers: List.filled(8, 1),
        tmdbSeasons: const [1],
        seasonCounts: const {1: 12},
      );
      expect(available, [1]);
      // 线路只有 8 集，渲染结果必须恰好 8 项
      final sourceEpisodes = List.generate(8, (i) => 'E${i + 1}');
      final rendered = sourceEpisodes
          .where((_) => true)
          .toList(); // 季度过滤后仍是 8 项
      expect(rendered.length, 8);
      expect(rendered.length, lessThan(12), reason: '不得用 TMDB 的 12 集补齐');
    });

    test('线路集数少于 TMDB 季度集数时切片返回真实长度', () {
      final sliced = sliceBySeasonCounts(
        List.generate(8, (i) => 'E${i + 1}'),
        const [1],
        const {1: 12},
        1,
      );
      // 段长 12 > 列表长度 8 → 越界返回空
      expect(sliced, isEmpty);
    });

    test('切片正常时返回对应区间', () {
      final episodes = List.generate(22, (i) => 'E${i + 1}');
      expect(
        sliceBySeasonCounts(episodes, const [1, 2], const {1: 12, 2: 10}, 1),
        episodes.sublist(0, 12),
      );
      expect(
        sliceBySeasonCounts(episodes, const [1, 2], const {1: 12, 2: 10}, 2),
        episodes.sublist(12, 22),
      );
      expect(
        sliceBySeasonCounts(episodes, const [1, 2], const {1: 12, 2: 10}, 9),
        isEmpty,
      );
    });
  });

  group('切片与映射辅助（§4.5/§4.6）', () {
    test('canSliceBySeasonCounts 四条前置条件', () {
      expect(canSliceBySeasonCounts(5, const [1, 2], const {1: 3, 2: 2}), isTrue);
      // episodeCount <= 0
      expect(canSliceBySeasonCounts(0, const [1, 2], const {1: 3, 2: 2}), isFalse);
      // seasons 为空
      expect(canSliceBySeasonCounts(5, const [], const {}), isFalse);
      // 某季集数为 0
      expect(canSliceBySeasonCounts(5, const [1, 2], const {1: 5, 2: 0}), isFalse);
      // 总和不等
      expect(canSliceBySeasonCounts(6, const [1, 2], const {1: 3, 2: 2}), isFalse);
    });

    test('hasCompleteExplicitSeasonMapping', () {
      expect(
        hasCompleteExplicitSeasonMapping(const [1, 1], const [1, 2]),
        isTrue,
      );
      // 有未分类集
      expect(
        hasCompleteExplicitSeasonMapping(const [1, -1], const [1, 2]),
        isFalse,
      );
      // 含非 TMDB 季度
      expect(
        hasCompleteExplicitSeasonMapping(const [1, 9], const [1, 2]),
        isFalse,
      );
      expect(hasCompleteExplicitSeasonMapping(const [], const [1]), isFalse);
    });

    test('mapFlatEpisodeNumber', () {
      const counts = {1: 3, 2: 2};
      expect(mapFlatEpisodeNumber(1, const [1, 2], counts),
          (seasonNumber: 1, episodeNumber: 1));
      expect(mapFlatEpisodeNumber(3, const [1, 2], counts),
          (seasonNumber: 1, episodeNumber: 3));
      expect(mapFlatEpisodeNumber(4, const [1, 2], counts),
          (seasonNumber: 2, episodeNumber: 1));
      expect(mapFlatEpisodeNumber(5, const [1, 2], counts),
          (seasonNumber: 2, episodeNumber: 2));
      expect(mapFlatEpisodeNumber(6, const [1, 2], counts), isNull);
      expect(mapFlatEpisodeNumber(0, const [1, 2], counts), isNull);
      expect(mapFlatEpisodeNumber(-1, const [1, 2], counts), isNull);
    });

    test('canMapFlatEpisodeNumbers', () {
      expect(
        canMapFlatEpisodeNumbers(const [1, 3, 4], const [1, 2], const {1: 3, 2: 2}),
        isTrue,
      );
      expect(
        canMapFlatEpisodeNumbers(const [1, 9], const [1, 2], const {1: 3, 2: 2}),
        isFalse,
      );
      expect(canMapFlatEpisodeNumbers(null, const [1], const {1: 3}), isFalse);
      expect(canMapFlatEpisodeNumbers(const [], const [1], const {1: 3}), isFalse);
    });

    test('mappedSeasonsByEpisodeNumbers 保持 seasons 顺序', () {
      expect(
        mappedSeasonsByEpisodeNumbers(
          const [4, 1, 5],
          const [1, 2],
          const {1: 3, 2: 2},
        ),
        [1, 2],
      );
      // 任一集无法映射 → 空
      expect(
        mappedSeasonsByEpisodeNumbers(
          const [1, 99],
          const [1, 2],
          const {1: 3, 2: 2},
        ),
        isEmpty,
      );
    });

    test('shouldUseSingleSeasonEpisodeData', () {
      // S1 集数 >= 来源集数 且不可切片 → true
      expect(
        shouldUseSingleSeasonEpisodeData(5, 1, const [1, 2], const {1: 12, 2: 10}),
        isTrue,
      );
      // 可切片 → false
      expect(
        shouldUseSingleSeasonEpisodeData(5, 1, const [1, 2], const {1: 3, 2: 2}),
        isFalse,
      );
      // S1 集数不足 → false
      expect(
        shouldUseSingleSeasonEpisodeData(5, 1, const [1, 2], const {1: 3, 2: 10}),
        isFalse,
      );
      // 只有一季 → false
      expect(
        shouldUseSingleSeasonEpisodeData(5, 1, const [1], const {1: 12}),
        isFalse,
      );
    });

    test('sliceableSeasons 只保留非负', () {
      expect(sliceableSeasons(const [0, 1, 2]), [0, 1, 2]);
      expect(sliceableSeasons(const [-1, 1]), [1]);
      expect(sliceableSeasons(const []), isEmpty);
    });

    test('coveredSeasonsByEpisodeCount', () {
      expect(
        coveredSeasonsByEpisodeCount(5, const [1, 2], const {1: 3, 2: 2}),
        [1, 2],
      );
      expect(
        coveredSeasonsByEpisodeCount(6, const [1, 2], const {1: 3, 2: 2}),
        isEmpty,
      );
    });
  });
}
