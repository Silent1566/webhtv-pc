/// Phase 4 · TMDB 季度解析器（`docs/phase4/design/02` §2/§3/§5）。
///
/// 对应门禁：`docs/phase4/design/05` §3.5「判定顺序 15 步 / 后级不覆盖前级 /
/// ambiguous 不落盘 / 不覆盖旧绑定」与 §3.7「分段有效性 8 条」。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/core/tmdb_season.dart';

SeasonBinding _binding({
  SeasonBindingMode mode = SeasonBindingMode.manualSeason,
  int? seasonNumber = 1,
  List<SeasonSegment> segments = const [],
  int tmdbId = 1399,
  int sourceEpisodeCount = 0,
  int version = seasonBindingVersion,
}) => SeasonBinding(
  siteKey: 'csp_A',
  vodId: 'v1',
  sourceTitle: '剧名',
  flagKey: '线路一#0',
  tmdbId: tmdbId,
  mediaType: TmdbMediaType.tv,
  mode: mode,
  seasonNumber: seasonNumber,
  segments: segments,
  sourceEpisodeCount: sourceEpisodeCount,
  updatedAt: 1,
  version: version,
);

void main() {
  group('SeasonScope 显式三态（§2.3）', () {
    test('KnownSeason(0) 与 UnknownSeason 可区分', () {
      const specials = KnownSeason(0);
      const unknown = UnknownSeason();
      expect(specials.isSpecials, isTrue);
      expect(specials.isKnown, isTrue);
      expect(unknown.isKnown, isFalse);
      expect(specials == unknown, isFalse);
      expect(specials.seasons, [0]);
      expect(unknown.seasons, isEmpty);
    });

    test('KnownSeason 相等语义', () {
      expect(const KnownSeason(1), const KnownSeason(1));
      expect(const KnownSeason(1) == const KnownSeason(2), isFalse);
    });

    test('MultiSeason 需要 >= 2 段才算已知', () {
      const one = MultiSeason([
        SeasonSegment(
          seasonNumber: 1,
          sourceEpisodeStartIndex: 0,
          sourceEpisodeEndIndex: 4,
          tmdbEpisodeStartNumber: 1,
        ),
      ]);
      expect(one.isKnown, isFalse);
      const two = MultiSeason([
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
      ]);
      expect(two.isKnown, isTrue);
      expect(two.seasons, [1, 2]);
      expect(two.covers(2), isTrue);
      expect(two.covers(3), isFalse);
      expect(two.segmentFor(2)?.sourceEpisodeStartIndex, 5);
      expect(two.segmentFor(3), isNull);
    });

    test('JSON 往返', () {
      const known = KnownSeason(2);
      expect(SeasonScope.fromJson(known.toJson()), known);
      const unknown = UnknownSeason();
      expect(SeasonScope.fromJson(unknown.toJson()), unknown);
      const multi = MultiSeason([
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
      ]);
      expect(SeasonScope.fromJson(multi.toJson()), multi);
      // 段数 < 2 退化为 unknown
      expect(
        SeasonScope.fromJson(const MultiSeason([
          SeasonSegment(
            seasonNumber: 1,
            sourceEpisodeStartIndex: 0,
            sourceEpisodeEndIndex: 4,
            tmdbEpisodeStartNumber: 1,
          ),
        ]).toJson()),
        const UnknownSeason(),
      );
    });
  });

  group('SeasonSegment（§2.4）', () {
    test('length 与相等语义', () {
      const segment = SeasonSegment(
        seasonNumber: 1,
        sourceEpisodeStartIndex: 2,
        sourceEpisodeEndIndex: 5,
        tmdbEpisodeStartNumber: 3,
      );
      expect(segment.length, 4);
      expect(
        segment,
        const SeasonSegment(
          seasonNumber: 1,
          sourceEpisodeStartIndex: 2,
          sourceEpisodeEndIndex: 5,
          tmdbEpisodeStartNumber: 3,
        ),
      );
      expect(segment.hashCode, isNotNull);
    });

    test('JSON 往返与非法输入', () {
      const segment = SeasonSegment(
        seasonNumber: 2,
        sourceEpisodeStartIndex: 5,
        sourceEpisodeEndIndex: 9,
        tmdbEpisodeStartNumber: 1,
      );
      expect(SeasonSegment.fromJson(segment.toJson()), segment);
      expect(SeasonSegment.fromJson(null), isNull);
      expect(SeasonSegment.fromJson({'seasonNumber': 1}), isNull);
    });

    test('encodeSegments / decodeSegments 往返与容错', () {
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
      expect(decodeSegments(encodeSegments(segments)), segments);
      expect(decodeSegments(null), isEmpty);
      expect(decodeSegments(''), isEmpty);
      expect(decodeSegments('not-json'), isEmpty);
      expect(decodeSegments('{}'), isEmpty);
    });
  });

  group('解析器判定顺序 15 步（§3.3）', () {
    const seasons = [0, 1, 2];
    const counts = {0: 3, 1: 12, 2: 10};

    test('1. requestSeason 含于 TMDB → resolved(request)', () {
      final result = TmdbSeasonResolver.resolve(
        const SeasonResolveInput(
          requestSeason: 2,
          tmdbSeasons: seasons,
          seasonCounts: counts,
        ),
      );
      expect(result.status, ResolutionStatus.resolved);
      expect(result.source, ResolutionSource.request);
      expect(result.reason, 'request_season');
      expect(result.scope, const KnownSeason(2));
      expect(result.canPersist, isTrue);
    });

    test('1. requestSeason 不在 TMDB → ambiguous(requested_season_missing_from_tmdb)', () {
      final result = TmdbSeasonResolver.resolve(
        const SeasonResolveInput(
          requestSeason: 9,
          tmdbSeasons: seasons,
          seasonCounts: counts,
        ),
      );
      expect(result.status, ResolutionStatus.ambiguous);
      expect(result.source, ResolutionSource.request);
      expect(result.reason, 'requested_season_missing_from_tmdb');
      expect(result.canPersist, isFalse);
    });

    test('2. manualFlat → flat(manual_flat)，即使 TMDB 季度为空', () {
      final result = TmdbSeasonResolver.resolve(
        SeasonResolveInput(
          manualBinding: _binding(
            mode: SeasonBindingMode.manualFlat,
            seasonNumber: null,
          ),
          tmdbSeasons: const [],
        ),
      );
      expect(result.status, ResolutionStatus.flat);
      expect(result.source, ResolutionSource.manualFlat);
      expect(result.reason, 'manual_flat');
      expect(result.canPersist, isTrue);
    });

    test('3. tmdbSeasons 为空 → ambiguous(tmdb_seasons_empty)', () {
      final result = TmdbSeasonResolver.resolve(const SeasonResolveInput());
      expect(result.status, ResolutionStatus.ambiguous);
      expect(result.source, ResolutionSource.none);
      expect(result.reason, 'tmdb_seasons_empty');
    });

    test('4. manualMultiSlice 有效分段 → multiSlice(manual_multi_slice_segments)', () {
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
      final result = TmdbSeasonResolver.resolve(
        SeasonResolveInput(
          manualBinding: _binding(
            mode: SeasonBindingMode.manualMultiSlice,
            seasonNumber: null,
            segments: segments,
            sourceEpisodeCount: 10,
          ),
          tmdbSeasons: const [1, 2],
          seasonCounts: const {1: 12, 2: 10},
          sourceEpisodeCount: 10,
        ),
      );
      expect(result.status, ResolutionStatus.multiSlice);
      expect(result.source, ResolutionSource.manualMultiSlice);
      expect(result.reason, 'manual_multi_slice_segments');
      expect(result.scope, const MultiSeason(segments));
      expect(result.canPersist, isTrue);
    });

    test('4. manualMultiSlice 分段失效但集数可覆盖 → 重算（manual_multi_slice）', () {
      final result = TmdbSeasonResolver.resolve(
        SeasonResolveInput(
          manualBinding: _binding(
            mode: SeasonBindingMode.manualMultiSlice,
            seasonNumber: null,
            // 分段无效：endIndex 越界
            segments: const [
              SeasonSegment(
                seasonNumber: 1,
                sourceEpisodeStartIndex: 0,
                sourceEpisodeEndIndex: 99,
                tmdbEpisodeStartNumber: 1,
              ),
              SeasonSegment(
                seasonNumber: 2,
                sourceEpisodeStartIndex: 100,
                sourceEpisodeEndIndex: 199,
                tmdbEpisodeStartNumber: 1,
              ),
            ],
            sourceEpisodeCount: 22,
          ),
          tmdbSeasons: const [1, 2],
          seasonCounts: const {1: 12, 2: 10},
          sourceEpisodeCount: 22,
        ),
      );
      expect(result.status, ResolutionStatus.multiSlice);
      expect(result.source, ResolutionSource.manualMultiSlice);
      expect(result.reason, 'manual_multi_slice');
      expect(result.scope.seasons, [1, 2]);
      // 重算出的分段必须有效，才能落盘（§3.4）
      expect(result.canPersist, isTrue);
      expect(
        hasValidPersistedSegments(
          segments: (result.scope as MultiSeason).segments,
          tmdbSeasons: const [1, 2],
          seasonCounts: const {1: 12, 2: 10},
          sourceEpisodeCount: 22,
        ),
        isTrue,
      );
    });

    test('4. manualMultiSlice 分段失效且集数不匹配 → ambiguous(manual_multi_slice_stale)', () {
      final result = TmdbSeasonResolver.resolve(
        SeasonResolveInput(
          manualBinding: _binding(
            mode: SeasonBindingMode.manualMultiSlice,
            seasonNumber: null,
            segments: const [],
            sourceEpisodeCount: 7,
          ),
          tmdbSeasons: const [1, 2],
          seasonCounts: const {1: 12, 2: 10},
          sourceEpisodeCount: 7,
        ),
      );
      expect(result.status, ResolutionStatus.ambiguous);
      expect(result.source, ResolutionSource.manualMultiSlice);
      expect(result.reason, 'manual_multi_slice_stale');
      expect(result.canPersist, isFalse);
    });

    test('5. manualSeason → resolved(manual_season)', () {
      final result = TmdbSeasonResolver.resolve(
        SeasonResolveInput(
          manualBinding: _binding(seasonNumber: 2),
          tmdbSeasons: seasons,
          seasonCounts: counts,
        ),
      );
      expect(result.status, ResolutionStatus.resolved);
      expect(result.source, ResolutionSource.manual);
      expect(result.reason, 'manual_season');
      expect(result.scope, const KnownSeason(2));
    });

    test('5. manualSeason 指向不在 TMDB 的季度 → 继续后续判定', () {
      final result = TmdbSeasonResolver.resolve(
        SeasonResolveInput(
          manualBinding: _binding(seasonNumber: 9),
          tmdbSeasons: const [1],
          seasonCounts: const {1: 12},
        ),
      );
      // 落到第 9 步：单普通季度
      expect(result.source, ResolutionSource.singleSeason);
      expect(result.reason, 'single_ordinary_season');
    });

    test('6. 多显式季度 + 标题冲突 → ambiguous(multiple_explicit_seasons)', () {
      final result = TmdbSeasonResolver.resolve(
        const SeasonResolveInput(
          explicitSourceSeasons: [1, 2],
          titleSeason: 2,
          tmdbSeasons: seasons,
          seasonCounts: counts,
        ),
      );
      expect(result.status, ResolutionStatus.ambiguous);
      expect(result.source, ResolutionSource.explicitConflict);
      expect(result.reason, 'multiple_explicit_seasons');
    });

    test('6. 多显式季度含非 TMDB 季度 → ambiguous', () {
      final result = TmdbSeasonResolver.resolve(
        const SeasonResolveInput(
          explicitSourceSeasons: [1, 9],
          tmdbSeasons: seasons,
          seasonCounts: counts,
        ),
      );
      expect(result.status, ResolutionStatus.ambiguous);
      expect(result.reason, 'multiple_explicit_seasons');
    });

    test('6. 多显式季度 + 集号连续完整 → multiSlice(explicit_multi)', () {
      final result = TmdbSeasonResolver.resolve(
        const SeasonResolveInput(
          explicitSourceSeasons: [1, 2],
          tmdbSeasons: [1, 2],
          seasonCounts: {1: 3, 2: 2},
          sourceEpisodeCount: 5,
          // 1..5 按季集数（3+2）顺序映射到 S1E1..S1E3、S2E1..S2E2
          sourceEpisodeNumbers: [1, 2, 3, 4, 5],
        ),
      );
      expect(result.status, ResolutionStatus.multiSlice);
      expect(result.source, ResolutionSource.explicitMulti);
      expect(result.reason, 'multiple_explicit_seasons');
      expect(result.scope.seasons, [1, 2]);
      expect(result.canPersist, isTrue);
    });

    test('7. 单显式季度 + 标题冲突 → ambiguous(title_and_source_season_conflict)', () {
      final result = TmdbSeasonResolver.resolve(
        const SeasonResolveInput(
          explicitSourceSeasons: [1],
          titleSeason: 2,
          tmdbSeasons: seasons,
          seasonCounts: counts,
        ),
      );
      expect(result.status, ResolutionStatus.ambiguous);
      expect(result.source, ResolutionSource.explicitConflict);
      expect(result.reason, 'title_and_source_season_conflict');
    });

    test('7. 单显式季度含于 TMDB → resolved(explicit_source_season)', () {
      final result = TmdbSeasonResolver.resolve(
        const SeasonResolveInput(
          explicitSourceSeasons: [2],
          tmdbSeasons: seasons,
          seasonCounts: counts,
        ),
      );
      expect(result.source, ResolutionSource.explicit);
      expect(result.reason, 'explicit_source_season');
      expect(result.scope, const KnownSeason(2));
    });

    test('7. 单显式季度不在 TMDB → ambiguous(explicit_season_missing_from_tmdb)', () {
      final result = TmdbSeasonResolver.resolve(
        const SeasonResolveInput(
          explicitSourceSeasons: [9],
          tmdbSeasons: seasons,
          seasonCounts: counts,
        ),
      );
      expect(result.status, ResolutionStatus.ambiguous);
      expect(result.source, ResolutionSource.explicit);
      expect(result.reason, 'explicit_season_missing_from_tmdb');
    });

    test('8. 标题季度含于 TMDB → resolved(title_season)', () {
      final result = TmdbSeasonResolver.resolve(
        const SeasonResolveInput(
          titleSeason: 2,
          tmdbSeasons: seasons,
          seasonCounts: counts,
        ),
      );
      expect(result.source, ResolutionSource.title);
      expect(result.reason, 'title_season');
      expect(result.scope, const KnownSeason(2));
    });

    test('8. 标题季度不在 TMDB → ambiguous(title_season_missing_from_tmdb)', () {
      final result = TmdbSeasonResolver.resolve(
        const SeasonResolveInput(
          titleSeason: 9,
          tmdbSeasons: seasons,
          seasonCounts: counts,
        ),
      );
      expect(result.status, ResolutionStatus.ambiguous);
      expect(result.source, ResolutionSource.title);
      expect(result.reason, 'title_season_missing_from_tmdb');
    });

    test('9. 单普通季度 → resolved(single_ordinary_season)', () {
      final result = TmdbSeasonResolver.resolve(
        const SeasonResolveInput(
          tmdbSeasons: [1],
          seasonCounts: {1: 12},
        ),
      );
      expect(result.source, ResolutionSource.singleSeason);
      expect(result.reason, 'single_ordinary_season');
      expect(result.scope, const KnownSeason(1));
    });

    test('9. 单普通季度但存在特别篇时仍取普通季度', () {
      final result = TmdbSeasonResolver.resolve(
        const SeasonResolveInput(
          tmdbSeasons: [0, 1],
          seasonCounts: {0: 3, 1: 12},
        ),
      );
      expect(result.source, ResolutionSource.singleSeason);
      expect(result.scope, const KnownSeason(1));
    });

    test('10. 关闭启发式 → ambiguous(heuristic_guessing_disabled)', () {
      final result = TmdbSeasonResolver.resolve(
        const SeasonResolveInput(
          tmdbSeasons: [1],
          seasonCounts: {1: 12},
          allowHeuristicGuessing: false,
        ),
      );
      expect(result.status, ResolutionStatus.ambiguous);
      expect(result.source, ResolutionSource.none);
      expect(result.reason, 'heuristic_guessing_disabled');
    });

    test('10. 关闭启发式仍接受请求/手动/显式/标题四类证据', () {
      for (final input in [
        const SeasonResolveInput(
          requestSeason: 1,
          tmdbSeasons: [1],
          seasonCounts: {1: 12},
          allowHeuristicGuessing: false,
        ),
        const SeasonResolveInput(
          explicitSourceSeasons: [1],
          tmdbSeasons: [1],
          seasonCounts: {1: 12},
          allowHeuristicGuessing: false,
        ),
        const SeasonResolveInput(
          titleSeason: 1,
          tmdbSeasons: [1],
          seasonCounts: {1: 12},
          allowHeuristicGuessing: false,
        ),
      ]) {
        final result = TmdbSeasonResolver.resolve(input);
        expect(result.status, ResolutionStatus.resolved, reason: 'input');
      }
      final manual = TmdbSeasonResolver.resolve(
        SeasonResolveInput(
          manualBinding: _binding(seasonNumber: 1),
          tmdbSeasons: const [1],
          seasonCounts: const {1: 12},
          allowHeuristicGuessing: false,
        ),
      );
      expect(manual.status, ResolutionStatus.resolved);
      expect(manual.source, ResolutionSource.manual);
    });

    test('11. 仅特别篇 → resolved(0, specials_only)', () {
      final result = TmdbSeasonResolver.resolve(
        const SeasonResolveInput(
          tmdbSeasons: [0],
          seasonCounts: {0: 3},
        ),
      );
      expect(result.status, ResolutionStatus.resolved);
      expect(result.source, ResolutionSource.singleSeason);
      expect(result.reason, 'specials_only');
      expect(result.scope, const KnownSeason(0));
      expect((result.scope as KnownSeason).isSpecials, isTrue);
    });

    test('12. 精确集数唯一 → resolved(unique_episode_count)', () {
      final result = TmdbSeasonResolver.resolve(
        const SeasonResolveInput(
          tmdbSeasons: [1, 2],
          seasonCounts: {1: 12, 2: 10},
          sourceEpisodeCount: 10,
        ),
      );
      expect(result.status, ResolutionStatus.resolved);
      expect(result.source, ResolutionSource.episodeCount);
      expect(result.reason, 'unique_episode_count');
      expect(result.scope, const KnownSeason(2));
    });

    test('12. 精确集数重复 → ambiguous(duplicate_episode_counts)', () {
      final result = TmdbSeasonResolver.resolve(
        const SeasonResolveInput(
          tmdbSeasons: [1, 2],
          seasonCounts: {1: 10, 2: 10},
          sourceEpisodeCount: 10,
        ),
      );
      expect(result.status, ResolutionStatus.ambiguous);
      expect(result.source, ResolutionSource.episodeCount);
      expect(result.reason, 'duplicate_episode_counts');
      expect(result.canPersist, isFalse);
    });

    test('13. 全季切片 → multiSlice(all_season_counts)', () {
      final result = TmdbSeasonResolver.resolve(
        const SeasonResolveInput(
          tmdbSeasons: [1, 2],
          seasonCounts: {1: 12, 2: 10},
          sourceEpisodeCount: 22,
        ),
      );
      expect(result.status, ResolutionStatus.multiSlice);
      expect(result.source, ResolutionSource.allSeasonCounts);
      expect(result.reason, 'all_season_counts');
      expect(result.scope.seasons, [1, 2]);
      expect(result.canPersist, isTrue);
    });

    test('14. 扁平集号多季 → multiSlice(flat_episode_keys)', () {
      final result = TmdbSeasonResolver.resolve(
        const SeasonResolveInput(
          tmdbSeasons: [1, 2],
          seasonCounts: {1: 3, 2: 3},
          sourceEpisodeCount: 4,
          // 4 → S2E1，因此映射出 [1, 2]
          sourceEpisodeNumbers: [1, 2, 4, 5],
        ),
      );
      expect(result.status, ResolutionStatus.multiSlice);
      expect(result.source, ResolutionSource.flatEpisodeKeys);
      expect(result.reason, 'flat_episode_keys');
      expect(result.scope.seasons, [1, 2]);
    });

    test('15. 证据不足 → ambiguous(insufficient_season_evidence)', () {
      final result = TmdbSeasonResolver.resolve(
        const SeasonResolveInput(
          tmdbSeasons: [1, 2],
          seasonCounts: {1: 12, 2: 10},
          sourceEpisodeCount: 7,
        ),
      );
      expect(result.status, ResolutionStatus.ambiguous);
      expect(result.source, ResolutionSource.none);
      expect(result.reason, 'insufficient_season_evidence');
    });
  });

  group('后级不得覆盖前级（§3.3）', () {
    test('请求季度压过手动绑定', () {
      final result = TmdbSeasonResolver.resolve(
        SeasonResolveInput(
          requestSeason: 1,
          manualBinding: _binding(seasonNumber: 2),
          tmdbSeasons: const [1, 2],
          seasonCounts: const {1: 12, 2: 10},
        ),
      );
      expect(result.source, ResolutionSource.request);
      expect(result.scope, const KnownSeason(1));
    });

    test('手动绑定压过显式季度', () {
      final result = TmdbSeasonResolver.resolve(
        SeasonResolveInput(
          manualBinding: _binding(seasonNumber: 2),
          explicitSourceSeasons: const [1],
          tmdbSeasons: const [1, 2],
          seasonCounts: const {1: 12, 2: 10},
        ),
      );
      expect(result.source, ResolutionSource.manual);
      expect(result.scope, const KnownSeason(2));
    });

    test('显式季度与标题一致时 source 为 explicit', () {
      final result = TmdbSeasonResolver.resolve(
        const SeasonResolveInput(
          explicitSourceSeasons: [2],
          titleSeason: 2,
          tmdbSeasons: [1, 2],
          seasonCounts: {1: 12, 2: 10},
        ),
      );
      expect(result.source, ResolutionSource.explicit);
      expect(result.scope, const KnownSeason(2));
    });

    test('显式季度与标题冲突时按契约取 ambiguous（不静默选一边）', () {
      final result = TmdbSeasonResolver.resolve(
        const SeasonResolveInput(
          explicitSourceSeasons: [2],
          titleSeason: 1,
          tmdbSeasons: [1, 2],
          seasonCounts: {1: 12, 2: 10},
        ),
      );
      expect(result.status, ResolutionStatus.ambiguous);
      expect(result.source, ResolutionSource.explicitConflict);
      expect(result.reason, 'title_and_source_season_conflict');
    });

    test('标题季度压过单季启发式', () {
      final result = TmdbSeasonResolver.resolve(
        const SeasonResolveInput(
          titleSeason: 2,
          tmdbSeasons: [1, 2],
          seasonCounts: {1: 12, 2: 10},
        ),
      );
      expect(result.source, ResolutionSource.title);
      expect(result.scope, const KnownSeason(2));
    });

    test('单季启发式压过集数匹配', () {
      final result = TmdbSeasonResolver.resolve(
        const SeasonResolveInput(
          tmdbSeasons: [1, 2],
          seasonCounts: {1: 12, 2: 10},
          sourceEpisodeCount: 10,
        ),
      );
      // 第 9 步的 ordinary.length == 2，所以不成立；落到第 12 步。
      expect(result.source, ResolutionSource.episodeCount);
    });
  });

  group('分段有效性 8 条（§5.3）', () {
    const tmdbSeasons = [1, 2];
    const counts = {1: 12, 2: 10};

    List<SeasonSegment> valid() => const [
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

    test('全部条件满足 → 有效', () {
      expect(
        hasValidPersistedSegments(
          segments: valid(),
          tmdbSeasons: tmdbSeasons,
          seasonCounts: counts,
          sourceEpisodeCount: 10,
        ),
        isTrue,
      );
    });

    test('1. 段数 < 2 → 无效', () {
      expect(
        hasValidPersistedSegments(
          segments: valid().take(1).toList(),
          tmdbSeasons: tmdbSeasons,
          seasonCounts: counts,
          sourceEpisodeCount: 10,
        ),
        isFalse,
      );
    });

    test('2. sourceEpisodeCount <= 0 → 无效', () {
      expect(
        hasValidPersistedSegments(
          segments: valid(),
          tmdbSeasons: tmdbSeasons,
          seasonCounts: counts,
          sourceEpisodeCount: 0,
        ),
        isFalse,
      );
    });

    test('3. seasonNumber 不在 TMDB → 无效', () {
      final segments = [
        const SeasonSegment(
          seasonNumber: 1,
          sourceEpisodeStartIndex: 0,
          sourceEpisodeEndIndex: 4,
          tmdbEpisodeStartNumber: 1,
        ),
        const SeasonSegment(
          seasonNumber: 9,
          sourceEpisodeStartIndex: 5,
          sourceEpisodeEndIndex: 9,
          tmdbEpisodeStartNumber: 1,
        ),
      ];
      expect(
        hasValidPersistedSegments(
          segments: segments,
          tmdbSeasons: tmdbSeasons,
          seasonCounts: counts,
          sourceEpisodeCount: 10,
        ),
        isFalse,
      );
    });

    test('4. 不连续（有空洞）→ 无效', () {
      final segments = [
        const SeasonSegment(
          seasonNumber: 1,
          sourceEpisodeStartIndex: 0,
          sourceEpisodeEndIndex: 3,
          tmdbEpisodeStartNumber: 1,
        ),
        const SeasonSegment(
          seasonNumber: 2,
          sourceEpisodeStartIndex: 5, // 跳过了 index 4
          sourceEpisodeEndIndex: 9,
          tmdbEpisodeStartNumber: 1,
        ),
      ];
      expect(
        hasValidPersistedSegments(
          segments: segments,
          tmdbSeasons: tmdbSeasons,
          seasonCounts: counts,
          sourceEpisodeCount: 10,
        ),
        isFalse,
      );
    });

    test('4. 首段 startIndex != 0 → 无效', () {
      final segments = [
        const SeasonSegment(
          seasonNumber: 1,
          sourceEpisodeStartIndex: 1,
          sourceEpisodeEndIndex: 4,
          tmdbEpisodeStartNumber: 1,
        ),
        const SeasonSegment(
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
          seasonCounts: counts,
          sourceEpisodeCount: 10,
        ),
        isFalse,
      );
    });

    test('5. endIndex < startIndex → 无效', () {
      final segments = [
        const SeasonSegment(
          seasonNumber: 1,
          sourceEpisodeStartIndex: 0,
          sourceEpisodeEndIndex: 4,
          tmdbEpisodeStartNumber: 1,
        ),
        const SeasonSegment(
          seasonNumber: 2,
          sourceEpisodeStartIndex: 5,
          sourceEpisodeEndIndex: 4,
          tmdbEpisodeStartNumber: 1,
        ),
      ];
      expect(
        hasValidPersistedSegments(
          segments: segments,
          tmdbSeasons: tmdbSeasons,
          seasonCounts: counts,
          sourceEpisodeCount: 10,
        ),
        isFalse,
      );
    });

    test('5. endIndex >= sourceEpisodeCount → 无效', () {
      final segments = [
        const SeasonSegment(
          seasonNumber: 1,
          sourceEpisodeStartIndex: 0,
          sourceEpisodeEndIndex: 4,
          tmdbEpisodeStartNumber: 1,
        ),
        const SeasonSegment(
          seasonNumber: 2,
          sourceEpisodeStartIndex: 5,
          sourceEpisodeEndIndex: 10,
          tmdbEpisodeStartNumber: 1,
        ),
      ];
      expect(
        hasValidPersistedSegments(
          segments: segments,
          tmdbSeasons: tmdbSeasons,
          seasonCounts: counts,
          sourceEpisodeCount: 10,
        ),
        isFalse,
      );
    });

    test('6. tmdbEpisodeStartNumber <= 0 → 无效', () {
      final segments = [
        const SeasonSegment(
          seasonNumber: 1,
          sourceEpisodeStartIndex: 0,
          sourceEpisodeEndIndex: 4,
          tmdbEpisodeStartNumber: 0,
        ),
        const SeasonSegment(
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
          seasonCounts: counts,
          sourceEpisodeCount: 10,
        ),
        isFalse,
      );
    });

    test('7. 段长越界（tmdbEpisodeStartNumber + len - 1 > count）→ 无效', () {
      final segments = [
        const SeasonSegment(
          seasonNumber: 1,
          sourceEpisodeStartIndex: 0,
          sourceEpisodeEndIndex: 4,
          tmdbEpisodeStartNumber: 10, // 10 + 5 - 1 = 14 > 12
        ),
        const SeasonSegment(
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
          seasonCounts: counts,
          sourceEpisodeCount: 10,
        ),
        isFalse,
      );
    });

    test('7. 季度集数为 0 → 无效', () {
      final segments = [
        const SeasonSegment(
          seasonNumber: 1,
          sourceEpisodeStartIndex: 0,
          sourceEpisodeEndIndex: 4,
          tmdbEpisodeStartNumber: 1,
        ),
        const SeasonSegment(
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
          seasonCounts: const {1: 12, 2: 0},
          sourceEpisodeCount: 10,
        ),
        isFalse,
      );
    });

    test('8. 未完整覆盖 → 无效', () {
      final segments = [
        const SeasonSegment(
          seasonNumber: 1,
          sourceEpisodeStartIndex: 0,
          sourceEpisodeEndIndex: 4,
          tmdbEpisodeStartNumber: 1,
        ),
        const SeasonSegment(
          seasonNumber: 2,
          sourceEpisodeStartIndex: 5,
          sourceEpisodeEndIndex: 8, // 只到 8，共 10 集
          tmdbEpisodeStartNumber: 1,
        ),
      ];
      expect(
        hasValidPersistedSegments(
          segments: segments,
          tmdbSeasons: tmdbSeasons,
          seasonCounts: counts,
          sourceEpisodeCount: 10,
        ),
        isFalse,
      );
    });
  });

  group('completeSeasonSegments（§3.3 第 6/13 步）', () {
    test('各季集数之和恰等于来源集数时生成分段', () {
      final segments = completeSeasonSegments(
        const [1, 2],
        const {1: 3, 2: 2},
      );
      expect(segments.length, 2);
      expect(segments[0].seasonNumber, 1);
      expect(segments[0].sourceEpisodeStartIndex, 0);
      expect(segments[0].sourceEpisodeEndIndex, 2);
      expect(segments[1].seasonNumber, 2);
      expect(segments[1].sourceEpisodeStartIndex, 3);
      expect(segments[1].sourceEpisodeEndIndex, 4);
    });

    test('只有一季时返回空（不足 2 段）', () {
      expect(completeSeasonSegments(const [1], const {1: 5}), isEmpty);
    });

    test('某季集数为 0 时返回空', () {
      expect(completeSeasonSegments(const [1, 2], const {1: 3, 2: 0}), isEmpty);
    });
  });

  group('SeasonBinding 校验（§5.1）', () {
    test('matches 要求版本、身份、类型、模式全部一致', () {
      final binding = _binding(seasonNumber: 1);
      expect(binding.matches(1399), isTrue);
      expect(binding.matches(2000), isFalse);
      expect(_binding(seasonNumber: 1, version: 99).matches(1399), isFalse);
    });

    test('manualSeason 要求 seasonNumber 非空且 >= 0', () {
      expect(_binding(seasonNumber: 1).matches(1399), isTrue);
      expect(_binding(seasonNumber: 0).matches(1399), isTrue); // 特别篇
      expect(_binding(seasonNumber: null).matches(1399), isFalse);
      expect(_binding(seasonNumber: -1).matches(1399), isFalse);
    });

    test('manualFlat / manualMultiSlice 要求 seasonNumber 为空', () {
      expect(
        _binding(mode: SeasonBindingMode.manualFlat, seasonNumber: null)
            .matches(1399),
        isTrue,
      );
      expect(
        _binding(mode: SeasonBindingMode.manualFlat, seasonNumber: 1)
            .matches(1399),
        isFalse,
      );
    });

    test('validate 逐条拒绝规则', () {
      expect(
        SeasonBinding.validate(
          siteKey: '',
          vodId: 'v',
          sourceTitle: 't',
          tmdbId: 1399,
          mediaType: TmdbMediaType.tv,
          mode: SeasonBindingMode.manualSeason,
          seasonNumber: 1,
        ),
        'scope_incomplete',
      );
      expect(
        SeasonBinding.validate(
          siteKey: 's',
          vodId: 'v',
          sourceTitle: 't',
          tmdbId: 0,
          mediaType: TmdbMediaType.tv,
          mode: SeasonBindingMode.manualSeason,
          seasonNumber: 1,
        ),
        'tmdb_id_invalid',
      );
      expect(
        SeasonBinding.validate(
          siteKey: 's',
          vodId: 'v',
          sourceTitle: 't',
          tmdbId: 1399,
          mediaType: TmdbMediaType.movie,
          mode: SeasonBindingMode.manualSeason,
          seasonNumber: 1,
        ),
        'media_type_not_tv',
      );
      expect(
        SeasonBinding.validate(
          siteKey: 's',
          vodId: 'v',
          sourceTitle: 't',
          tmdbId: 1399,
          mediaType: TmdbMediaType.tv,
          mode: SeasonBindingMode.manualSeason,
          seasonNumber: null,
        ),
        'season_number_required',
      );
      expect(
        SeasonBinding.validate(
          siteKey: 's',
          vodId: 'v',
          sourceTitle: 't',
          tmdbId: 1399,
          mediaType: TmdbMediaType.tv,
          mode: SeasonBindingMode.manualFlat,
          seasonNumber: 1,
        ),
        'season_number_forbidden',
      );
      expect(
        SeasonBinding.validate(
          siteKey: 's',
          vodId: 'v',
          sourceTitle: 't',
          tmdbId: 1399,
          mediaType: TmdbMediaType.tv,
          mode: SeasonBindingMode.manualSeason,
          seasonNumber: 1,
        ),
        isNull,
      );
    });

    test('toScope 三态映射', () {
      expect(_binding(seasonNumber: 2).toScope(), const KnownSeason(2));
      expect(
        _binding(mode: SeasonBindingMode.manualFlat, seasonNumber: null).toScope(),
        const UnknownSeason(),
      );
      expect(
        _binding(
          mode: SeasonBindingMode.manualMultiSlice,
          seasonNumber: null,
          segments: const [
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
          ],
        ).toScope(),
        isA<MultiSeason>(),
      );
    });

    test('JSON 往返', () {
      final binding = _binding(seasonNumber: 2);
      final round = SeasonBinding.fromJson(binding.toJson())!;
      expect(round.siteKey, binding.siteKey);
      expect(round.vodId, binding.vodId);
      expect(round.flagKey, binding.flagKey);
      expect(round.tmdbId, binding.tmdbId);
      expect(round.mediaType, binding.mediaType);
      expect(round.mode, binding.mode);
      expect(round.seasonNumber, binding.seasonNumber);
      expect(round.version, binding.version);
    });

    test('JSON 非法输入返回 null', () {
      expect(SeasonBinding.fromJson(null), isNull);
      expect(SeasonBinding.fromJson({'mode': 'bogus'}), isNull);
      expect(
        SeasonBinding.fromJson({'mode': 'manualSeason', 'mediaType': 'person'}),
        isNull,
      );
    });
  });

  group('RouteBinding（§5.5）', () {
    test('covers 判定', () {
      final binding = RouteBinding(
        siteKey: 's',
        vodId: 'v',
        flagKey: 'f',
        sourceFlag: '线路一',
        sourceFingerprint: 'fp',
        tmdbId: 1399,
        mediaType: TmdbMediaType.tv,
        scope: const KnownSeason(2),
        updatedAt: 1,
      );
      expect(binding.covers(2), isTrue);
      expect(binding.covers(1), isFalse);
    });

    test('routeIdentity 形态', () {
      expect(RouteBinding.routeIdentity('csp_A', '123'), 'csp_A@@@123');
    });

    test('容量上限常量为 512', () {
      expect(maxRouteBindings, 512);
    });
  });

  group('来源指纹（§2.5）', () {
    test('稳定指纹不含 URL，只含序号与剧集名', () {
      final a = SourceFingerprint.stable(
        flagKey: 'f1',
        episodeNames: ['第1集', '第2集'],
      );
      final b = SourceFingerprint.stable(
        flagKey: 'f1',
        episodeNames: ['第1集', '第2集'],
      );
      expect(a, b);
      expect(a, isNot(contains('http')));
      // 换 CDN 只改 URL 不改名字 → 指纹不变
      expect(
        SourceFingerprint.stable(flagKey: 'f1', episodeNames: ['第1集', '第2集']),
        a,
      );
    });

    test('剧集名变化会改变指纹', () {
      expect(
        SourceFingerprint.stable(flagKey: 'f1', episodeNames: ['第1集']),
        isNot(SourceFingerprint.stable(flagKey: 'f1', episodeNames: ['第1话'])),
      );
    });

    test('结构指纹含季度集数映射，TMDB 集数变化时改变', () {
      final before = SourceFingerprint.structure(
        flagKey: 'f1',
        episodeNames: ['第1集'],
        seasonCounts: const {1: 12},
      );
      final after = SourceFingerprint.structure(
        flagKey: 'f1',
        episodeNames: ['第1集'],
        seasonCounts: const {1: 13},
      );
      expect(before, isNot(after));
    });

    test('手动绑定指纹含 sourceTitle 与 flagKey', () {
      final a = SourceFingerprint.manual(
        sourceTitle: '剧名',
        flagKey: 'f1',
        episodeNames: ['第1集'],
      );
      expect(a, startsWith('剧名|f1|'));
      expect(
        a,
        isNot(
          SourceFingerprint.manual(
            sourceTitle: '别的',
            flagKey: 'f1',
            episodeNames: ['第1集'],
          ),
        ),
      );
    });
  });
}
