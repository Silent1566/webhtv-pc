/// 追剧日历纯逻辑层（`lib/core/following_calendar.dart`）。
///
/// 锁死四类最容易写错的边界：月历补齐与跨年/闰年、集号文案、渐进式归日
/// （真实播出 → `nextAirAtMs` → 本地降级）与**一集一条**（同剧同日多集不再合并）。
///
/// 全部用例只碰纯函数：不建窗口、不读写磁盘、不联网。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/following.dart';
import 'package:webhtv_pc/core/following_calendar.dart';

/// 基准时刻：2026-10-22 09:00（本地时区）。
final int _now = DateTime(2026, 10, 22, 9).millisecondsSinceEpoch;
Following _item({
  String seriesKey = 'source:0:site1:vod1',
  String vodName = '示例剧',
  int season = 0,
  int released = 0,
  int watched = 0,
  int read = 0,
  String status = FollowingStatus.returning,
  int nextAirAtMs = 0,
  int lastCheckedAtMs = 0,
  int metadataUpdatedAtMs = 0,
  int updatedAtMs = 0,
  bool enabled = true,
}) => Following(
  seriesKey: seriesKey,
  season: season,
  siteKey: 'site1',
  vodId: 'vod1',
  vodName: vodName,
  vodPic: 'https://example.com/p.jpg',
  latestReleasedSeason: 0,
  latestReleasedEpisode: released,
  seasonReleasedEpisodes: released,
  trackedSeason: 0,
  watchedEpisode: watched,
  readWatermarkEpisode: read,
  status: status,
  nextAirAtMs: nextAirAtMs,
  lastCheckedAtMs: lastCheckedAtMs,
  metadataUpdatedAtMs: metadataUpdatedAtMs,
  updatedAtMs: updatedAtMs,
  enabled: enabled,
);

FollowingAirTime _air(
  String seriesKey,
  int episode,
  DateTime at, {
  int season = 0,
  String episodeTitle = '',
}) => FollowingAirTime(
  seriesKey: seriesKey,
  season: season,
  episode: episode,
  airAtMs: at.millisecondsSinceEpoch,
  episodeTitle: episodeTitle,
);

void main() {
  group('月历网格', () {
    test('周一起始：2026-10 补齐为 9/28~11/1 共 5 行 35 格', () {
      final month = followingCalendarMonth(year: 2026, month: 10);
      expect(month.year, 2026);
      expect(month.month, 10);
      expect(month.mondayFirst, isTrue);
      expect(month.dayCount, 31);
      expect(month.weeks.length, 5);
      expect(month.cells.length, 35);
      expect(month.cells.first.date, DateTime(2026, 9, 28));
      expect(month.cells.first.weekday, DateTime.monday);
      expect(month.cells.first.inMonth, isFalse);
      // 10-01 是周四，周一起始时落在第 4 格。
      expect(month.cells[3].date, DateTime(2026, 10, 1));
      expect(month.cells[3].inMonth, isTrue);
      expect(month.cells[3].dayOfMonth, 1);
      expect(month.cells.last.date, DateTime(2026, 11, 1));
      expect(month.cells.last.inMonth, isFalse);
      expect(month.cells.where((cell) => cell.inMonth).length, 31);
    });

    test('周日起始：2026-10 补齐为 9/27~10/31，末格仍属本月', () {
      final month = followingCalendarMonth(
        year: 2026,
        month: 10,
        mondayFirst: false,
      );
      expect(month.mondayFirst, isFalse);
      expect(month.cells.length, 35);
      expect(month.cells.first.date, DateTime(2026, 9, 27));
      expect(month.cells.first.weekday, DateTime.sunday);
      expect(month.cells.first.inMonth, isFalse);
      expect(month.cells[4].date, DateTime(2026, 10, 1));
      expect(month.cells.last.date, DateTime(2026, 10, 31));
      expect(month.cells.last.inMonth, isTrue);
    });

    test('跨年与越界归一：2026-12 跨到 2027，month 0/13 折回相邻月', () {
      final december = followingCalendarMonth(year: 2026, month: 12);
      expect(december.dayCount, 31);
      expect(december.cells.first.date, DateTime(2026, 11, 30));
      expect(december.cells.last.date, DateTime(2027, 1, 3));
      expect(december.cells.last.inMonth, isFalse);

      final nextJanuary = followingCalendarMonth(year: 2026, month: 13);
      expect(nextJanuary.year, 2027);
      expect(nextJanuary.month, 1);
      expect(nextJanuary.cells.first.date, DateTime(2026, 12, 28));
      expect(nextJanuary.cells.last.date, DateTime(2027, 1, 31));

      final previousDecember = followingCalendarMonth(year: 2025, month: 0);
      expect(previousDecember.year, 2024);
      expect(previousDecember.month, 12);
      expect(previousDecember.dayCount, 31);
    });

    test('闰年 2024-02 为 29 天，平年 2023-02 为 28 天', () {
      final leap = followingCalendarMonth(year: 2024, month: 2);
      expect(leap.dayCount, 29);
      expect(leap.cells.where((cell) => cell.inMonth).length, 29);
      expect(leap.cells.first.date, DateTime(2024, 1, 29));
      expect(leap.cells.last.date, DateTime(2024, 3, 3));
      expect(
        leap.cells
            .firstWhere((cell) => cell.date == DateTime(2024, 2, 29))
            .inMonth,
        isTrue,
      );

      final normal = followingCalendarMonth(year: 2023, month: 2);
      expect(normal.dayCount, 28);
      expect(normal.cells.where((cell) => cell.inMonth).length, 28);
      expect(normal.cells.first.date, DateTime(2023, 1, 30));
    });
  });

  group('集号文案', () {
    test('单集标签与区间函数仍按原规则（UI 仍用它渲染单集）', () {
      expect(
        followingCalendarEpisodeLabel(
          season: 0,
          startEpisode: 16,
          endEpisode: 16,
        ),
        'S1E16 · 共 1 集',
      );
      expect(
        followingCalendarEpisodeLabel(
          season: 1,
          startEpisode: 5,
          endEpisode: 5,
        ),
        'S2E5 · 共 1 集',
      );
      expect(
        followingCalendarEpisodeLabel(
          season: 0,
          startEpisode: 0,
          endEpisode: 0,
        ),
        'S1 · 集号未知',
      );
    });

    test('code 两位补零：S01E23 / 季 0 基 +1 / 集号未知只给季', () {
      final byAir = followingCalendarByDay(
        items: [_item(released: 30, watched: 0)],
        nowMs: _now,
        airTimes: [_air('source:0:site1:vod1', 23, DateTime(2026, 10, 22, 20))],
      );
      final entry = byAir.values.single.single;
      expect(entry.code, 'S01E23');
      expect(entry.episodeLabel, 'S1E23 · 共 1 集');

      // 季 1（数据层 0 基）→ S02；集号个位数补零。
      final seasonTwo = followingCalendarByDay(
        items: [_item(season: 1, released: 30, watched: 0)],
        nowMs: _now,
        airTimes: [
          _air('source:0:site1:vod1', 5, DateTime(2026, 10, 22, 20), season: 1),
        ],
      );
      expect(seasonTwo.values.single.single.code, 'S02E05');

      // 集号未知 → 只有季号，不编造 E00。
      final unknown = followingCalendarByDay(
        items: [_item()],
        nowMs: _now,
      ).values.single.single;
      expect(unknown.code, 'S01');
      expect(unknown.episode, 0);
    });
  });

  group('一集一条', () {
    test('同一天更新 5 集 → 5 条，各带自己的集号与未看判定', () {
      final item = _item(released: 25, watched: 23);
      final day = DateTime(2026, 10, 22);
      final byDay = followingCalendarByDay(
        items: [item],
        nowMs: _now,
        airTimes: [
          // 故意乱序传入，验证按集号稳定排序。
          _air('source:0:site1:vod1', 25, DateTime(2026, 10, 22, 21)),
          _air('source:0:site1:vod1', 21, DateTime(2026, 10, 22, 19)),
          _air('source:0:site1:vod1', 24, DateTime(2026, 10, 22, 22)),
          _air('source:0:site1:vod1', 22, DateTime(2026, 10, 22, 20)),
          _air('source:0:site1:vod1', 23, DateTime(2026, 10, 22, 21)),
        ],
      );
      expect(byDay.length, 1);
      final entries = byDay[day]!;
      expect(entries.length, 5);
      expect(entries.map((entry) => entry.episode).toList(), [
        21,
        22,
        23,
        24,
        25,
      ]);
      // 区间语义已移除：起止恒等于该集，且每条的集数恒为 1。
      for (final entry in entries) {
        expect(entry.episodeStart, entry.episode);
        expect(entry.episodeEnd, entry.episode);
        expect(entry.episodeCount, 1);
        expect(entry.source, CalendarSource.real);
        expect(entry.identityKey, 'source:0:site1:vod1:s0');
      }
      // 未看只看真实已看集号：21/22/23 已看，24/25 未看。
      expect(entries.map((entry) => entry.unwatchedCount).toList(), [
        0,
        0,
        0,
        1,
        1,
      ]);
      expect(byDay[day]!.where((entry) => entry.unwatched).length, 2);
      expect(entries.first.vodName, '示例剧');
      expect(entries.first.vodPic, 'https://example.com/p.jpg');
      expect(entries.first.ongoing, isTrue);
    });

    test('同一集重复的 airTime 只产出一条（不重复画行）', () {
      final byDay = followingCalendarByDay(
        items: [_item(released: 9, watched: 8)],
        nowMs: _now,
        airTimes: [
          _air('source:0:site1:vod1', 9, DateTime(2026, 10, 22, 20)),
          _air('source:0:site1:vod1', 9, DateTime(2026, 10, 22, 22)),
        ],
      );
      expect(byDay.values.single.length, 1);
      expect(byDay.values.single.single.episode, 9);
    });
  });

  group('归日（渐进式）', () {
    test('真实播出时间：跨两天多条，各自归日', () {
      final item = _item(released: 17, watched: 15);
      final byDay = followingCalendarByDay(
        items: [item],
        nowMs: _now,
        airTimes: [
          _air('source:0:site1:vod1', 15, DateTime(2026, 10, 15, 20)),
          _air('source:0:site1:vod1', 16, DateTime(2026, 10, 22, 20)),
          _air('source:0:site1:vod1', 17, DateTime(2026, 10, 22, 21)),
        ],
      );
      expect(byDay.length, 2);
      expect(byDay.keys.first, DateTime(2026, 10, 15));
      expect(byDay.keys.last, DateTime(2026, 10, 22));

      final earlier = byDay[DateTime(2026, 10, 15)]!.single;
      expect(earlier.episode, 15);
      expect(earlier.episodeLabel, 'S1E15 · 共 1 集');
      expect(earlier.source, CalendarSource.real);
      expect(earlier.unwatched, isFalse);

      final sameDay = byDay[DateTime(2026, 10, 22)]!;
      expect(sameDay.map((entry) => entry.episode).toList(), [16, 17]);
      expect(sameDay.every((entry) => entry.unwatched), isTrue);
    });

    test('nextAirAtMs>0 且可信：按它归日并标记 real', () {
      final nextAir = DateTime(2026, 10, 25, 22).millisecondsSinceEpoch;
      final item = _item(released: 12, watched: 12, nextAirAtMs: nextAir);
      final byDay = followingCalendarByDay(items: [item], nowMs: _now);
      expect(byDay.keys.single, DateTime(2026, 10, 25));
      final entry = byDay.values.single.single;
      expect(entry.source, CalendarSource.real);
      expect(entry.episode, 12);
      expect(entry.episodeLabel, 'S1E12 · 共 1 集');
      expect(entry.unwatched, isFalse);
    });

    test('nextAirAtMs<=0：降级 local，只出最新一集', () {
      final item = _item(
        released: 17,
        watched: 15,
        nextAirAtMs: 0,
        lastCheckedAtMs: DateTime(2026, 10, 22, 12).millisecondsSinceEpoch,
      );
      final byDay = followingCalendarByDay(items: [item], nowMs: _now);
      expect(byDay.keys.single, DateTime(2026, 10, 22));
      // 降级路径日期是推算的假日期 → 只出最新一集，不逐集展开。
      final entry = byDay.values.single.single;
      expect(entry.episode, 17);
      expect(entry.source, CalendarSource.local);
      expect(entry.unwatched, isTrue);
      expect(entry.ongoing, isTrue);
      expect(entry.watchedEpisode, 15);
      expect(entry.unwatchedCount, 1);
      expect(entry.progressLabel, '已看 15 集 · 未看 1 集');
      expect(entry.remainingEpisodes, 2);

      // 已看完（无更新）时同样只出最新一集。
      final finished = _item(
        released: 17,
        watched: 17,
        lastCheckedAtMs: DateTime(2026, 10, 22, 12).millisecondsSinceEpoch,
      );
      final finishedEntry = followingCalendarByDay(
        items: [finished],
        nowMs: _now,
      ).values.single.single;
      expect(finishedEntry.episode, 17);
      expect(finishedEntry.episodeLabel, 'S1E17 · 共 1 集');
      expect(finishedEntry.unwatched, isFalse);
      expect(finishedEntry.remainingEpisodes, 0);
    });

    test('降级路径不逐集展开：released=200、watched=0 当天只出 1 条（最新 E200）', () {
      final item = _item(
        released: 200,
        watched: 0,
        read: 200,
        lastCheckedAtMs: DateTime(2026, 10, 22, 8).millisecondsSinceEpoch,
      );
      final byDay = followingCalendarByDay(items: [item], nowMs: _now);
      expect(byDay.keys.single, DateTime(2026, 10, 22));
      final entries = byDay.values.single;
      expect(entries.length, 1);
      final entry = entries.single;
      expect(entry.episode, 200);
      expect(entry.code, 'S01E200');
      expect(entry.source, CalendarSource.local);
      // 单集判定语义：这条（E200）本身还没看 → 1。
      expect(entry.unwatchedCount, 1);
      // 「共 200 集」的未看总量由 remainingEpisodes / 日汇总表达，不靠条数。
      expect(entry.remainingEpisodes, 200);
      expect(entry.totalEpisodes, 200);
      expect(entry.progressLabel, '未开始看 · 未看 1 集');
      final summary = followingCalendarDaySummary(entries);
      expect(summary.episodeCount, 1);
      expect(summary.seriesCount, 1);
    });

    test('时间异常兜底：负数/未来过远/过旧 → 逐级退回本地时间再到今天', () {
      // 负数的 nextAirAtMs 视为不可用 → local。
      final negative = _item(
        released: 3,
        watched: 3,
        nextAirAtMs: -1,
        lastCheckedAtMs: DateTime(2026, 10, 20, 8).millisecondsSinceEpoch,
      );
      final negativeDay = followingCalendarByDay(
        items: [negative],
        nowMs: _now,
      );
      expect(negativeDay.keys.single, DateTime(2026, 10, 20));
      expect(negativeDay.values.single.single.source, CalendarSource.local);

      // 未来过远（> 1 年）的“真实”播出时间不可信 → 退回 local。
      final farFuture = _item(
        released: 3,
        watched: 3,
        nextAirAtMs: _now + const Duration(days: 400).inMilliseconds,
        lastCheckedAtMs: DateTime(2026, 10, 20, 8).millisecondsSinceEpoch,
      );
      final farFutureDay = followingCalendarByDay(
        items: [farFuture],
        nowMs: _now,
      );
      expect(farFutureDay.keys.single, DateTime(2026, 10, 20));
      expect(farFutureDay.values.single.single.source, CalendarSource.local);

      // 检查时间在未来（超 1 天时钟容差）→ 视为脏数据，归到 today。
      final futureCheck = _item(
        released: 3,
        watched: 3,
        lastCheckedAtMs: DateTime(2026, 11, 5, 8).millisecondsSinceEpoch,
      );
      final futureCheckDay = followingCalendarByDay(
        items: [futureCheck],
        nowMs: _now,
      );
      expect(futureCheckDay.keys.single, DateTime(2026, 10, 22));

      // 本地时间全部为 0 → today，且集号未知时有明确文案。
      final blank = _item();
      final blankDay = followingCalendarByDay(items: [blank], nowMs: _now);
      expect(blankDay.keys.single, DateTime(2026, 10, 22));
      expect(blankDay.values.single.single.episodeLabel, 'S1 · 集号未知');

      // 过旧（> 5 年）的本地时间同样不可信 → today。
      final tooOld = _item(
        released: 3,
        watched: 3,
        lastCheckedAtMs: DateTime(2019, 1, 1).millisecondsSinceEpoch,
      );
      final tooOldDay = followingCalendarByDay(items: [tooOld], nowMs: _now);
      expect(tooOldDay.keys.single, DateTime(2026, 10, 22));
    });

    test('空列表：byDay 为空，单日与今日查询返回空容器', () {
      final byDay = followingCalendarByDay(items: const [], nowMs: _now);
      expect(byDay, isEmpty);

      final day = followingCalendarDayOf(byDay, DateTime(2026, 10, 22, 15, 30));
      expect(day.date, DateTime(2026, 10, 22));
      expect(day.entries, isEmpty);
      expect(day.isEmpty, isTrue);
      expect(day.unwatchedCount, 0);
      expect(day.seriesCount, 0);

      final today = followingCalendarToday(byDay, nowMs: _now);
      expect(today.date, DateTime(2026, 10, 22));
      expect(today.isNotEmpty, isFalse);

      final summary = followingCalendarDaySummary(day.entries);
      expect(summary.isEmpty, isTrue);
      expect(summary.seriesCount, 0);
      expect(summary.episodeCount, 0);
      expect(summary.label, '0 部更新');
    });

    test('多剧同日：按剧名排序，不再未看优先，两轮结果完全一致', () {
      final watchedFirst = _item(
        seriesKey: 'source:0:s:a',
        vodName: 'A剧',
        released: 5,
        watched: 5,
        lastCheckedAtMs: DateTime(2026, 10, 22, 8).millisecondsSinceEpoch,
      );
      final unwatchedSecond = _item(
        seriesKey: 'source:0:s:b',
        vodName: 'B剧',
        released: 5,
        watched: 1,
        lastCheckedAtMs: DateTime(2026, 10, 22, 8).millisecondsSinceEpoch,
      );
      final unwatchedThird = _item(
        seriesKey: 'source:0:s:c',
        vodName: 'C剧',
        released: 5,
        watched: 0,
        lastCheckedAtMs: DateTime(2026, 10, 22, 8).millisecondsSinceEpoch,
      );
      final items = [unwatchedThird, watchedFirst, unwatchedSecond];
      final first = followingCalendarByDay(items: items, nowMs: _now);
      final second = followingCalendarByDay(items: items, nowMs: _now);
      final names = first.values.single.map((entry) => entry.vodName).toList();
      final again = second.values.single.map((entry) => entry.vodName).toList();
      // 降级路径每部剧只出一条（最新一集），所以顺序就是剧名顺序。
      expect(names, ['A剧', 'B剧', 'C剧']);
      expect(again, names);
      expect(first.values.single.first.unwatched, isFalse);
      expect(first.values.single.last.unwatched, isTrue);
      expect(followingCalendarDaySummary(first.values.single).seriesCount, 3);
    });

    test('当月有更新的日号集合只取当月', () {
      final laterNow = DateTime(2026, 11, 10, 9).millisecondsSinceEpoch;
      final real = _item(released: 17, watched: 17);
      final september = _item(
        seriesKey: 'source:0:site1:vod2',
        vodName: '九月剧',
        released: 2,
        watched: 2,
        lastCheckedAtMs: DateTime(2026, 9, 30, 8).millisecondsSinceEpoch,
      );
      final november = _item(
        seriesKey: 'source:0:site1:vod3',
        vodName: '十一月剧',
        released: 2,
        watched: 2,
        lastCheckedAtMs: DateTime(2026, 11, 1, 8).millisecondsSinceEpoch,
      );
      final byDay = followingCalendarByDay(
        items: [real, september, november],
        nowMs: laterNow,
        airTimes: [
          _air('source:0:site1:vod1', 16, DateTime(2026, 10, 5, 20)),
          _air('source:0:site1:vod1', 17, DateTime(2026, 10, 22, 20)),
        ],
      );
      expect(byDay.length, 4);
      expect(followingCalendarUpdateDaysInMonth(byDay, year: 2026, month: 10), {
        5,
        22,
      });
      expect(followingCalendarUpdateDaysInMonth(byDay, year: 2026, month: 9), {
        30,
      });
      expect(followingCalendarUpdateDaysInMonth(byDay, year: 2026, month: 11), {
        1,
      });
      expect(
        followingCalendarUpdateDaysInMonth(byDay, year: 2025, month: 10),
        isEmpty,
      );
      expect(
        followingCalendarUnwatchedDaysInMonth(byDay, year: 2026, month: 10),
        {5: false, 22: false},
      );
    });

    test('不按 enabled 过滤：关闭追踪的剧仍在日历里', () {
      final disabled = _item(
        released: 4,
        watched: 4,
        enabled: false,
        lastCheckedAtMs: DateTime(2026, 10, 22, 8).millisecondsSinceEpoch,
      );
      final byDay = followingCalendarByDay(items: [disabled], nowMs: _now);
      expect(byDay.values.single.single.vodName, '示例剧');
    });
  });

  group('总集数与进度', () {
    test('官方总集数优先：totalEpisodes=24、progress=已看/24、totalSource=official', () {
      final item = _item(released: 12, watched: 6);
      final entry = followingCalendarByDay(
        items: [item],
        nowMs: _now,
        airTimes: [_air('source:0:site1:vod1', 12, DateTime(2026, 10, 22, 20))],
        officialTotalEpisodes: {item.identityKey: 24},
      ).values.single.single;
      expect(entry.totalEpisodes, 24);
      expect(entry.totalSource, CalendarTotalSource.official);
      expect(entry.totalSource.label, '官方总集数');
      expect(entry.hasOfficialTotal, isTrue);
      expect(entry.progress, closeTo(0.25, 1e-9));
    });

    test('无官方总集数：分母降级为本线路可播集数并标记 line', () {
      final entry = followingCalendarByDay(
        items: [_item(released: 12, watched: 6)],
        nowMs: _now,
        airTimes: [_air('source:0:site1:vod1', 12, DateTime(2026, 10, 22, 20))],
      ).values.single.single;
      expect(entry.totalEpisodes, 12);
      expect(entry.totalSource, CalendarTotalSource.line);
      expect(entry.hasOfficialTotal, isFalse);
      expect(entry.progress, closeTo(0.5, 1e-9));
    });

    test('总集数全未知：totalEpisodes=0、progress=0、totalSource=unknown', () {
      final entry = followingCalendarByDay(
        items: [_item()],
        nowMs: _now,
      ).values.single.single;
      expect(entry.totalEpisodes, 0);
      expect(entry.totalSource, CalendarTotalSource.unknown);
      expect(entry.progress, 0.0);
      expect(entry.hasOfficialTotal, isFalse);
    });

    test('progress 夹在 0..1：已看超过总集数时封顶为 1', () {
      final item = _item(released: 30, watched: 30);
      final entry = followingCalendarByDay(
        items: [item],
        nowMs: _now,
        airTimes: [_air('source:0:site1:vod1', 30, DateTime(2026, 10, 22, 20))],
        officialTotalEpisodes: {item.identityKey: 20},
      ).values.single.single;
      expect(entry.totalEpisodes, 20);
      expect(entry.progress, 1.0);
    });
  });

  group('分集标题与剧级首条', () {
    test('episodeTitle 只落在该集条目上，其余集为空串', () {
      final byDay = followingCalendarByDay(
        items: [_item(released: 10, watched: 9)],
        nowMs: _now,
        airTimes: [
          _air(
            'source:0:site1:vod1',
            9,
            DateTime(2026, 10, 22, 19),
            episodeTitle: '',
          ),
          _air(
            'source:0:site1:vod1',
            10,
            DateTime(2026, 10, 22, 20),
            episodeTitle: '决斗之夜',
          ),
        ],
      );
      final entries = byDay[DateTime(2026, 10, 22)]!;
      expect(entries.map((entry) => entry.episodeTitle).toList(), [
        '',
        '决斗之夜',
      ]);
      // 集级判定只看本集集号：E09 已看、E10 未看，两者同时成立。
      expect(entries.map((entry) => entry.episodeWatched).toList(), [
        true,
        false,
      ]);
      expect(entries.map((entry) => entry.episodeUnwatched).toList(), [
        false,
        true,
      ]);
    });

    test('集号未知时集级状态不成立（不把未知当已看）', () {
      final entry = followingCalendarByDay(
        items: [_item()],
        nowMs: _now,
      ).values.single.single;
      expect(entry.episodeTitle, '');
      expect(entry.episodeWatched, isFalse);
      expect(entry.episodeUnwatched, isFalse);
    });

    test('同剧同日多集只有首条是剧级首条，跨剧各算首条', () {
      final entries = followingCalendarByDay(
        items: [
          _item(released: 10, watched: 9),
          _item(
            seriesKey: 'source:0:site1:vod2',
            vodName: '另一部',
            released: 3,
            watched: 3,
          ),
        ],
        nowMs: _now,
        airTimes: [
          _air('source:0:site1:vod1', 9, DateTime(2026, 10, 22, 19)),
          _air('source:0:site1:vod1', 10, DateTime(2026, 10, 22, 20)),
        ],
      ).values.single;
      // 排序是「剧名 → 身份键 → 集号」：「另一部」在「示例剧」之前。
      expect(entries.map((entry) => entry.vodName).toList(), [
        '另一部',
        '示例剧',
        '示例剧',
      ]);
      expect(followingCalendarSeriesLeadIndexes(entries).toList(), [0, 1]);
      expect(entries.length, 3);
    });
  });

  group('已看 / 未看（只用真实已看，不用水位）', () {
    test('刚追、一集未看：降级只出最新一集，未看量看 watchedEpisode / remainingEpisodes', () {
      // 首次追番的水位 = 已发布集数，若拿它当「已看」就会把未看抹成 0。
      final fresh = _item(
        released: 7,
        watched: 0,
        read: 7,
        lastCheckedAtMs: DateTime(2026, 10, 22, 8).millisecondsSinceEpoch,
      );
      final entries = followingCalendarByDay(
        items: [fresh],
        nowMs: _now,
      ).values.single;
      expect(entries.length, 1);
      final entry = entries.single;
      expect(entry.episode, 7);
      expect(entry.episodeStart, entry.episodeEnd);
      expect(entry.watchedEpisode, 0);
      expect(entry.unwatchedCount, 1);
      expect(entry.unwatched, isTrue);
      expect(entry.totalEpisodes, 7);
      expect(entry.remainingEpisodes, 7);
      expect(entry.progressLabel, '未开始看 · 未看 1 集');
      expect(entry.progress, 0.0);

      // 水位不参与：把水位改成 0 结果必须完全一致。
      final noWatermark = _item(
        released: 7,
        watched: 0,
        read: 0,
        lastCheckedAtMs: DateTime(2026, 10, 22, 8).millisecondsSinceEpoch,
      );
      final same = followingCalendarByDay(
        items: [noWatermark],
        nowMs: _now,
      ).values.single;
      expect(same.length, entries.length);
      expect(same.single.episode, entry.episode);
      expect(same.single.unwatchedCount, entry.unwatchedCount);
      expect(same.single.remainingEpisodes, entry.remainingEpisodes);
    });

    test('三条归日路径的未看都只看真实已看集数', () {
      // real：airTimes 路径（水位 = 已发布也不该把未看抹掉）。
      final byAir = followingCalendarByDay(
        items: [_item(released: 7, watched: 2, read: 7)],
        nowMs: _now,
        airTimes: [_air('source:0:site1:vod1', 3, DateTime(2026, 10, 21, 20))],
      ).values.single.single;
      expect(byAir.source, CalendarSource.real);
      expect(byAir.episode, 3);
      expect(byAir.watchedEpisode, 2);
      expect(byAir.unwatchedCount, 1);
      expect(byAir.progressLabel, '已看 2 集 · 未看 1 集');

      // real：nextAirAtMs 路径。
      final byNext = followingCalendarByDay(
        items: [
          _item(
            released: 7,
            watched: 7,
            read: 7,
            nextAirAtMs: DateTime(2026, 10, 25, 22).millisecondsSinceEpoch,
          ),
        ],
        nowMs: _now,
      ).values.single.single;
      expect(byNext.source, CalendarSource.real);
      expect(byNext.unwatched, isFalse);
      expect(byNext.unwatchedCount, 0);
      expect(byNext.progressLabel, '已看 7 集 · 已看完');

      // local：降级路径（假日期 → 只出最新一集）。
      final byLocal = followingCalendarByDay(
        items: [
          _item(
            released: 7,
            watched: 3,
            read: 7,
            lastCheckedAtMs: DateTime(2026, 10, 22, 8).millisecondsSinceEpoch,
          ),
        ],
        nowMs: _now,
      ).values.single;
      expect(byLocal.length, 1);
      expect(byLocal.single.episode, 7);
      expect(byLocal.single.unwatchedCount, 1);
      expect(byLocal.single.remainingEpisodes, 4);
      expect(byLocal.single.progressLabel, '已看 3 集 · 未看 1 集');
      expect(byLocal.single.source, CalendarSource.local);
    });

    test('集号未知时进度文案为「集号未知」', () {
      final entry = followingCalendarByDay(
        items: [_item()],
        nowMs: _now,
      ).values.single.single;
      expect(entry.episodeLabel, 'S1 · 集号未知');
      expect(entry.progressLabel, '集号未知');
      expect(entry.unwatched, isFalse);
      expect(entry.unwatchedCount, 0);
    });
  });

  group('已播出 / 待播', () {
    test('未来集标待播：不算未看，日汇总单独计待播', () {
      final futureDay = DateTime(2026, 10, 23, 20);
      final byDay = followingCalendarByDay(
        items: [_item(released: 10, watched: 9)],
        nowMs: _now,
        airTimes: [
          _air('source:0:site1:vod1', 10, DateTime(2026, 10, 22, 20)),
          _air('source:0:site1:vod1', 14, futureDay),
        ],
      );
      final airedEntry = byDay[DateTime(2026, 10, 22)]!.single;
      expect(airedEntry.episodeAired, isTrue);
      expect(airedEntry.episodePending, isFalse);
      expect(airedEntry.episodeUnwatched, isTrue);
      // 排期上限来自该剧全部 airTimes 的集号最大值。
      expect(airedEntry.airingThroughEpisode, 14);

      final pendingEntry = byDay[DateTime(2026, 10, 23)]!.single;
      expect(pendingEntry.episode, 14);
      expect(pendingEntry.episodeAired, isFalse);
      expect(pendingEntry.episodePending, isTrue);
      expect(pendingEntry.episodeUnwatched, isFalse);
      expect(pendingEntry.episodeWatched, isFalse);
      expect(pendingEntry.unwatchedCount, 0);

      final pendingSummary = followingCalendarDaySummary(
        byDay[DateTime(2026, 10, 23)]!,
      );
      expect(pendingSummary.unwatchedEpisodeCount, 0);
      expect(pendingSummary.pendingEpisodeCount, 1);
      expect(pendingSummary.hasUnwatched, isFalse);
      expect(pendingSummary.hasPending, isTrue);
      expect(pendingSummary.label, '1 部更新 · 待播 1 集');
    });

    test('当天与过去集都算已播出：未看照常统计，待播为 0', () {
      final byDay = followingCalendarByDay(
        items: [_item(released: 12, watched: 10)],
        nowMs: _now,
        airTimes: [
          // 当天晚些时候（19:00/21:00）仍算当天已播出，不按钟点卡未来。
          _air('source:0:site1:vod1', 11, DateTime(2026, 10, 22, 19)),
          _air('source:0:site1:vod1', 12, DateTime(2026, 10, 22, 21)),
          _air('source:0:site1:vod1', 9, DateTime(2026, 10, 20, 20)),
        ],
      );
      final entries = byDay[DateTime(2026, 10, 22)]!;
      expect(entries.every((entry) => entry.episodeAired), isTrue);
      expect(entries.every((entry) => !entry.episodePending), isTrue);
      final nowSummary = followingCalendarDaySummary(entries);
      expect(nowSummary.unwatchedEpisodeCount, 2);
      expect(nowSummary.pendingEpisodeCount, 0);
      expect(nowSummary.label, '1 部更新 · 未看 2 集');
    });

    test('未看与待播同时存在时文案并列', () {
      // 同一天不可能既有已播又有待播（按自然日判定），这里直接钉标签组合规则。
      const summary = CalendarDaySummary(
        seriesCount: 1,
        episodeCount: 3,
        unwatchedEpisodeCount: 2,
        pendingEpisodeCount: 1,
      );
      expect(summary.hasUnwatched, isTrue);
      expect(summary.hasPending, isTrue);
      expect(summary.label, '1 部更新 · 未看 2 集 · 待播 1 集');
    });

    test('本地降级路径视为已播出', () {
      final entry = followingCalendarByDay(
        items: [
          _item(
            released: 9,
            watched: 8,
            lastCheckedAtMs: DateTime(2026, 10, 22, 8).millisecondsSinceEpoch,
          ),
        ],
        nowMs: _now,
      ).values.single.single;
      expect(entry.source, CalendarSource.local);
      expect(entry.episodeAired, isTrue);
      expect(entry.episodePending, isFalse);
      expect(entry.unwatchedCount, 1);
      expect(entry.airingThroughEpisode, 0);
    });

    test('来源文案：real 是平台排期，local 是本地推算', () {
      expect(CalendarSource.real.label, '平台排期');
      expect(CalendarSource.local.label, '本地推算');
    });
  });

  group('按日汇总', () {
    test('N 部更新 / 未看 M 集：按身份键去重，未看按条计数', () {
      final itemA = _item(
        seriesKey: 'source:0:s:a',
        vodName: 'A剧',
        released: 5,
      );
      final itemB = _item(
        seriesKey: 'source:0:s:b',
        vodName: 'B剧',
        released: 9,
      );
      final byDay = followingCalendarByDay(
        items: [itemA, itemB],
        nowMs: _now,
        airTimes: [
          _air('source:0:s:a', 4, DateTime(2026, 10, 22, 20)),
          _air('source:0:s:a', 5, DateTime(2026, 10, 22, 21)),
          _air('source:0:s:b', 9, DateTime(2026, 10, 22, 22)),
        ],
      );
      final entries = byDay.values.single;
      final summary = followingCalendarDaySummary(entries);
      expect(summary.seriesCount, 2);
      expect(summary.episodeCount, 3);
      expect(summary.unwatchedEpisodeCount, 3);
      expect(summary.hasUnwatched, isTrue);
      expect(summary.label, '2 部更新 · 未看 3 集');
      expect(summary.isEmpty, isFalse);
      expect(
        followingCalendarDaySummary(entries).seriesCount,
        entries.map((e) => e.identityKey).toSet().length,
      );
    });

    test('全部已看时汇总只报部数', () {
      final item = _item(released: 5, watched: 5);
      final entries = followingCalendarByDay(
        items: [item],
        nowMs: _now,
        airTimes: [
          _air('source:0:site1:vod1', 4, DateTime(2026, 10, 22, 20)),
          _air('source:0:site1:vod1', 5, DateTime(2026, 10, 22, 21)),
        ],
      ).values.single;
      final summary = followingCalendarDaySummary(entries);
      expect(summary.episodeCount, 2);
      expect(summary.unwatchedEpisodeCount, 0);
      expect(summary.hasUnwatched, isFalse);
      expect(summary.label, '1 部更新');
    });
  });

  group('周条带', () {
    test('周一起始的 7 天条带与跨月标记保持不变', () {
      // 基准时刻放到锚点周之后：那一周的排期已成过去，未看照常统计。
      final nowMs = DateTime(2026, 11, 5, 9).millisecondsSinceEpoch;
      final item = _item(released: 9, watched: 8);
      final byDay = followingCalendarByDay(
        items: [item],
        nowMs: nowMs,
        airTimes: [
          _air('source:0:site1:vod1', 8, DateTime(2026, 10, 27, 20)),
          _air('source:0:site1:vod1', 9, DateTime(2026, 10, 29, 20)),
        ],
      );
      expect(
        followingCalendarWeekStart(DateTime(2026, 10, 29)),
        DateTime(2026, 10, 26),
      );
      final week = followingCalendarWeek(byDay, anchor: DateTime(2026, 10, 29));
      expect(week.days.length, 7);
      expect(week.start, DateTime(2026, 10, 26));
      expect(week.end, DateTime(2026, 11, 1));
      expect(week.spansTwoMonths, isTrue);
      expect(week.anchor, DateTime(2026, 10, 29));
      expect(week.days[1].entries.single.episode, 8);
      expect(week.days[3].entries.single.episode, 9);
      expect(week.activeDayCount, 2);
      // 已看 8 集 → E8 那条已看、E9 那条未看，所以只有 1 天有未看。
      expect(week.unwatchedDayCount, 1);
      expect(followingCalendarWeekdayLabel(DateTime(2026, 10, 26)), '一');
      expect(followingCalendarWeekdayLabels.last, '日');
    });
  });
}
