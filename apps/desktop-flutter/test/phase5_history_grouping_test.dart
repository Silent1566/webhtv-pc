/// 历史同名聚合投影（`lib/core/history_grouping.dart`）。
///
/// 锁四条用户可见语义（用户 2026-10-27 的需求）：
///
/// 1. 默认优先按 TMDB 身份合并——同一部剧在不同源、不同集的记录并成一张卡；
/// 2. 没有 TMDB 身份时按片名回退合并，且**年份只在桶内冲突时**才拆；
/// 3. `none` 模式完全不做聚合，每条记录独立（保留 v7 形态）；
/// 4. 代表记录取 `updatedAt` 最新，而不是进度最大。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/history_aggregation.dart';
import 'package:webhtv_pc/core/history_grouping.dart';

HistoryGroupInput row({
  required int id,
  required String vodName,
  required int updatedAt,
  String sourceKey = 'bridge|dev|a',
  String siteKey = 'csp_a',
  String vodId = '',
  String flag = '线路一',
  String episodeName = '第1集',
  String episodeId = '',
  int positionMs = 30000,
  int durationMs = 100000,
  String vodYear = '',
  int tmdbId = 0,
  String mediaType = '',
}) => HistoryGroupInput(
      id: id,
      sourceKey: sourceKey,
      siteKey: siteKey,
      vodId: vodId.isEmpty ? 'v-$id' : vodId,
      vodName: vodName,
      flag: flag,
      episodeName: episodeName,
      episodeId: episodeId.isEmpty ? 'http://x/$id' : episodeId,
      positionMs: positionMs,
      durationMs: durationMs,
      updatedAt: updatedAt,
      vodYear: vodYear,
      tmdbId: tmdbId,
      mediaType: mediaType,
    );

void main() {
  group('UiHistoryAggregation', () {
    test('默认是 tmdb 聚合', () {
      expect(UiHistoryAggregation.normalize(null), UiHistoryAggregation.tmdb);
      expect(UiHistoryAggregation.normalize('  '), UiHistoryAggregation.tmdb);
    });

    test('非法值回落到默认档而不是逐集档', () {
      expect(UiHistoryAggregation.normalize('bogus'), UiHistoryAggregation.tmdb);
      expect(UiHistoryAggregation.isAggregated('bogus'), isTrue);
    });

    test('三档互相区分', () {
      expect(UiHistoryAggregation.normalize('none'), UiHistoryAggregation.off);
      expect(UiHistoryAggregation.normalize('TITLE'), UiHistoryAggregation.title);
      expect(UiHistoryAggregation.isAggregated('none'), isFalse);
      expect(UiHistoryAggregation.isAggregated('tmdb'), isTrue);
      expect(UiHistoryAggregation.usesTmdb('tmdb'), isTrue);
      expect(UiHistoryAggregation.usesTmdb('title'), isFalse);
    });
  });

  group('groupHistory · none 模式', () {
    test('每条记录自成一组（保留逐集形态）', () {
      final groups = groupHistory(
        [
          row(id: 1, vodName: '庆余年', updatedAt: 300),
          row(id: 2, vodName: '庆余年', updatedAt: 200),
          row(id: 3, vodName: '庆余年', updatedAt: 100),
        ],
        mode: UiHistoryAggregation.off,
      );
      expect(groups.length, 3);
      for (final group in groups) {
        expect(group.members.length, 1);
        expect(group.aggregated, isFalse);
      }
      // 输入顺序即输出顺序（调用方已按 updatedAt 降序排好）。
      expect([for (final g in groups) g.representative.id], [1, 2, 3]);
    });
  });

  group('groupHistory · tmdb 模式', () {
    test('同一 TMDB 身份跨源跨集合并成一组', () {
      final groups = groupHistory(
        [
          row(
            id: 1,
            vodName: '庆余年',
            updatedAt: 300,
            sourceKey: 'bridge|dev|a',
            tmdbId: 1234,
            mediaType: 'tv',
          ),
          row(
            id: 2,
            vodName: '庆余年 第二季',
            updatedAt: 200,
            sourceKey: 'bridge|dev|b',
            tmdbId: 1234,
            mediaType: 'tv',
          ),
        ],
        mode: UiHistoryAggregation.tmdb,
      );
      expect(groups.length, 1);
      expect(groups.single.members.length, 2);
      expect(groups.single.aggregatedByTmdb, isTrue);
      expect(groups.single.crossSource, isTrue);
      expect(groups.single.representative.id, 1);
    });

    test('TMDB 不同即不合并（同名也不行）', () {
      final groups = groupHistory(
        [
          row(id: 1, vodName: '同名剧', updatedAt: 300, tmdbId: 1, mediaType: 'tv'),
          row(id: 2, vodName: '同名剧', updatedAt: 200, tmdbId: 2, mediaType: 'tv'),
        ],
        mode: UiHistoryAggregation.tmdb,
      );
      expect(groups.length, 2);
    });

    test('电影与剧集同 ID 不合并', () {
      final groups = groupHistory(
        [
          row(id: 1, vodName: 'X', updatedAt: 300, tmdbId: 7, mediaType: 'movie'),
          row(id: 2, vodName: 'X', updatedAt: 200, tmdbId: 7, mediaType: 'tv'),
        ],
        mode: UiHistoryAggregation.tmdb,
      );
      expect(groups.length, 2);
    });

    test('没有 TMDB 身份时按片名回退合并', () {
      final groups = groupHistory(
        [
          row(id: 1, vodName: '庆余年', updatedAt: 300),
          row(id: 2, vodName: ' 庆余年 ', updatedAt: 200),
        ],
        mode: UiHistoryAggregation.tmdb,
      );
      expect(groups.length, 1);
      expect(groups.single.aggregatedByTmdb, isFalse);
    });

    test('一条有 TMDB 一条没有时不会错误合并', () {
      final groups = groupHistory(
        [
          row(id: 1, vodName: '庆余年', updatedAt: 300, tmdbId: 55, mediaType: 'tv'),
          row(id: 2, vodName: '庆余年', updatedAt: 200),
        ],
        mode: UiHistoryAggregation.tmdb,
      );
      expect(groups.length, 2);
    });

    test('代表记录取最新而不是进度最大', () {
      final groups = groupHistory(
        [
          row(
            id: 1,
            vodName: 'X',
            updatedAt: 300,
            positionMs: 1000,
            durationMs: 100000,
            tmdbId: 9,
            mediaType: 'tv',
          ),
          row(
            id: 2,
            vodName: 'X',
            updatedAt: 200,
            positionMs: 90000,
            durationMs: 100000,
            tmdbId: 9,
            mediaType: 'tv',
          ),
        ],
        mode: UiHistoryAggregation.tmdb,
      );
      expect(groups.single.representative.id, 1);
      expect(groups.single.representative.positionMs, 1000);
    });

    test('输出按代表记录 updatedAt 降序', () {
      final groups = groupHistory(
        [
          row(id: 1, vodName: 'A', updatedAt: 100, tmdbId: 1, mediaType: 'tv'),
          row(id: 2, vodName: 'B', updatedAt: 300, tmdbId: 2, mediaType: 'tv'),
          row(id: 3, vodName: 'C', updatedAt: 200, tmdbId: 3, mediaType: 'tv'),
        ],
        mode: UiHistoryAggregation.tmdb,
      );
      expect([for (final g in groups) g.representative.vodName], ['B', 'C', 'A']);
    });
  });

  group('groupHistory · 年份消歧', () {
    test('桶内只有一个年份时不拆', () {
      final groups = groupHistory(
        [
          row(id: 1, vodName: '同名', updatedAt: 300, vodYear: '2020'),
          row(id: 2, vodName: '同名', updatedAt: 200, vodYear: '2020'),
        ],
        mode: UiHistoryAggregation.tmdb,
      );
      expect(groups.length, 1);
    });

    // 反向验证靶子：把 `years.length <= 1` 放宽成 `years.isEmpty` 时，本条会
    // 从 1 张卡变成 2 张（y:2020 与 year-unknown 各一桶）——那正是用户抱怨的
    // 「安卓推来的无年份记录」与「PC 本地有年份记录」分裂成散卡。
    test('桶内只有一个年份、其余记录无年份时也不拆', () {
      final groups = groupHistory(
        [
          row(id: 1, vodName: '同名', updatedAt: 300, vodYear: '2020'),
          row(id: 2, vodName: '同名', updatedAt: 200),
          row(id: 3, vodName: '同名', updatedAt: 100),
        ],
        mode: UiHistoryAggregation.tmdb,
      );
      expect(groups.length, 1);
      expect(groups.single.members.length, 3);
    });

    test('桶内出现两个年份时按年份拆，无年份单独一桶', () {
      final groups = groupHistory(
        [
          row(id: 1, vodName: '同名', updatedAt: 300, vodYear: '2020'),
          row(id: 2, vodName: '同名', updatedAt: 200, vodYear: '1999'),
          row(id: 3, vodName: '同名', updatedAt: 100),
        ],
        mode: UiHistoryAggregation.tmdb,
      );
      expect(groups.length, 3);
    });
  });

  group('groupHistory · title 模式', () {
    test('即使有 TMDB 身份也按片名合并', () {
      final groups = groupHistory(
        [
          row(id: 1, vodName: '庆余年', updatedAt: 300, tmdbId: 1, mediaType: 'tv'),
          row(id: 2, vodName: '庆余年', updatedAt: 200, tmdbId: 2, mediaType: 'tv'),
        ],
        mode: UiHistoryAggregation.title,
      );
      expect(groups.length, 1);
      expect(groups.single.aggregatedByTmdb, isFalse);
    });
  });

  test('空输入返回空列表', () {
    expect(groupHistory(const [], mode: UiHistoryAggregation.tmdb), isEmpty);
  });
}
