/// 追剧日历「本周」条带 + 「未看/已看」呈现。
///
/// 纯逻辑用例只碰 `core/following_calendar.dart`；页面用例沿用
/// `phase9_calendar_page_test.dart` 的临时目录 + 真实 `AppState` 那套 setup。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/following.dart';
import 'package:webhtv_pc/core/following_calendar.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/following_calendar_page.dart';
import 'package:webhtv_pc/ui/theme.dart';

Following _item({
  required String seriesKey,
  required String vodName,
  int released = 0,
  int watched = 0,
  int lastCheckedAtMs = 0,
}) => Following(
  seriesKey: seriesKey,
  season: 0,
  siteKey: 'site1',
  vodId: 'vod1',
  vodName: vodName,
  vodPic: 'https://example.com/p.jpg',
  latestReleasedSeason: 0,
  latestReleasedEpisode: released,
  seasonReleasedEpisodes: released,
  trackedSeason: 0,
  watchedEpisode: watched,
  readWatermarkEpisode: released,
  status: FollowingStatus.returning,
  lastCheckedAtMs: lastCheckedAtMs,
  enabled: true,
);

/// 一个自然日中午 12 点（避开夏令时边界，且只由年月日决定）。
int _noonMs(DateTime day) =>
    DateTime(day.year, day.month, day.day, 12).millisecondsSinceEpoch;

/// **今天**中午 12 点：无论当前几点都落在今天内（23:00 后也不会跨日）。
int _todayNoonMs() {
  final now = DateTime.now();
  return _noonMs(DateTime(now.year, now.month, now.day));
}

String _dotKey(DateTime day) =>
    'calendar-dot-${day.year}-${day.month}-${day.day}';

/// 页面**自己显示**的月份（从标题反推，避免测试另读一次 now）。
DateTime _shownMonth(WidgetTester tester) {
  final text = tester
      .widget<Text>(find.byKey(const ValueKey('calendar-title')))
      .data!;
  final match = RegExp(r'^(\d+)年(\d+)月$').firstMatch(text)!;
  return DateTime(int.parse(match.group(1)!), int.parse(match.group(2)!));
}

/// 周视图标题 `10月26日 - 11月1日` → `[起月, 起日, 止月, 止日]`。
List<int> _weekRange(WidgetTester tester) {
  final text = tester
      .widget<Text>(find.byKey(const ValueKey('calendar-week-title')))
      .data!;
  final match = RegExp(r'^(\d+)月(\d+)日 - (\d+)月(\d+)日$').firstMatch(text)!;
  return [
    int.parse(match.group(1)!),
    int.parse(match.group(2)!),
    int.parse(match.group(3)!),
    int.parse(match.group(4)!),
  ];
}

/// 周条带 7 个格子的日期（按 Row 内的从左到右顺序，从格子 key 解析）。
List<DateTime> _weekDates(WidgetTester tester) {
  final finder = find.byWidgetPredicate(
    (widget) =>
        widget.key is ValueKey<String> &&
        (widget.key! as ValueKey<String>).value.startsWith(
          'calendar-week-day-',
        ),
  );
  final pattern = RegExp(r'^calendar-week-day-(\d+)-(\d+)-(\d+)$');
  final dates = <DateTime>[];
  for (final element in finder.evaluate()) {
    final key = element.widget.key! as ValueKey<String>;
    final match = pattern.firstMatch(key.value)!;
    dates.add(
      DateTime(
        int.parse(match.group(1)!),
        int.parse(match.group(2)!),
        int.parse(match.group(3)!),
      ),
    );
  }
  return dates;
}

void main() {
  group('本周条带（纯逻辑）', () {
    test('10/29 锚点：周一→周日 7 天，且跨到 11 月', () {
      // 锚点周（10/26 ~ 11/1）之后，三条本地时间才都落在可信窗口内。
      final nowMs = DateTime(2026, 11, 6, 9).millisecondsSinceEpoch;
      final byDay = followingCalendarByDay(
        items: [
          _item(
            seriesKey: 'source:0:site1:vodA',
            vodName: 'A剧',
            released: 3,
            watched: 1,
            lastCheckedAtMs: DateTime(2026, 10, 26, 8).millisecondsSinceEpoch,
          ),
          _item(
            seriesKey: 'source:0:site1:vodB',
            vodName: 'B剧',
            released: 2,
            watched: 2,
            lastCheckedAtMs: DateTime(2026, 10, 29, 8).millisecondsSinceEpoch,
          ),
          _item(
            seriesKey: 'source:0:site1:vodC',
            vodName: 'C剧',
            released: 1,
            watched: 0,
            lastCheckedAtMs: DateTime(2026, 11, 1, 8).millisecondsSinceEpoch,
          ),
        ],
        nowMs: nowMs,
      );

      final week = followingCalendarWeek(byDay, anchor: DateTime(2026, 10, 29));
      expect(week.days.length, 7);
      expect(week.start, DateTime(2026, 10, 26));
      expect(week.start.weekday, DateTime.monday);
      expect(week.end, DateTime(2026, 11, 1));
      expect(week.end.weekday, DateTime.sunday);
      expect(week.spansTwoMonths, isTrue);
      expect(week.anchor, DateTime(2026, 10, 29));
      // 跨月不靠 Duration 加减，日号序列 26..31,1 必须正确。
      expect(week.days.map((day) => day.date.day).toList(), [
        26,
        27,
        28,
        29,
        30,
        31,
        1,
      ]);
      expect(
        week.days
            .map((day) => followingCalendarWeekdayLabel(day.date))
            .toList(),
        ['一', '二', '三', '四', '五', '六', '日'],
      );
      expect(week.days.first.entries.single.vodName, 'A剧');
      expect(week.days.first.unwatchedCount, 1);
      expect(week.days[3].entries.single.vodName, 'B剧');
      expect(week.days[3].unwatchedCount, 0);
      expect(week.days.last.entries.single.vodName, 'C剧');
      expect(week.days.last.unwatchedCount, 1);
      expect(week.activeDayCount, 3);
      expect(week.unwatchedDayCount, 2);
    });

    test('周日起点仍归入同一周；跨年周为 12/28 ~ 1/3', () {
      expect(
        followingCalendarWeekStart(DateTime(2026, 11, 1)),
        DateTime(2026, 10, 26),
      );
      expect(
        followingCalendarWeekStart(DateTime(2026, 10, 26)),
        DateTime(2026, 10, 26),
      );

      final week = followingCalendarWeek(
        const {},
        anchor: DateTime(2027, 1, 1),
      );
      expect(week.start, DateTime(2026, 12, 28));
      expect(week.end, DateTime(2027, 1, 3));
      expect(week.spansTwoMonths, isTrue);
      expect(week.days.every((day) => day.isEmpty), isTrue);
      expect(week.activeDayCount, 0);
      expect(week.unwatchedDayCount, 0);
      expect(followingCalendarWeekdayLabel(DateTime(2027, 1, 3)), '日');
    });
  });

  group('追剧日历页 · 本周视图', () {
    late Directory temp;
    late AppState state;

    setUp(() async {
      temp = Directory.systemTemp.createTempSync('webhtv-calendar-week');
      final paths = AppPaths.resolve(
        overrides: {
          'config': '${temp.path}${Platform.pathSeparator}config',
          'data': '${temp.path}${Platform.pathSeparator}data',
          'cache': '${temp.path}${Platform.pathSeparator}cache',
          'state': '${temp.path}${Platform.pathSeparator}logs',
        },
      );
      state = AppState(paths: paths, log: LogService());
      await state.bootstrap();
    });

    tearDown(() {
      state.dispose();
      try {
        temp.deleteSync(recursive: true);
      } catch (_) {}
    });

    /// 追一部剧并把调度字段改成用例需要的值。
    ///
    /// 水位（`readWatermarkEpisode`）**一律拉满到已发布集数**：水位绝不能影响
    /// 「未看」的判定，这样写等于在页面层再钉一次这个约束。
    void follow({
      required String vodId,
      required String vodName,
      int released = 12,
      int watched = 0,
      int nextAirAtMs = 0,
    }) {
      final item = state.followFromDetail(
        site: Site(
          key: 's',
          name: '甲站',
          type: 4,
          api: 'http://127.0.0.1:1/vod',
        ),
        vod: Vod(vodId: vodId, vodName: vodName),
        flag: '线路一',
        sourceFlag: '线路一',
        releasedEpisode: released,
      )!;
      state.database!.upsertFollowing(
        item.copyWith(
          latestReleasedEpisode: released,
          seasonReleasedEpisodes: released,
          watchedEpisode: watched,
          readWatermarkEpisode: released,
          nextAirAtMs: nextAirAtMs,
          status: FollowingStatus.returning,
        ),
      );
      state.notifyListeners();
    }

    Future<void> pumpPage(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1100, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.dark),
          home: Scaffold(body: FollowingCalendarPage(state: state)),
        ),
      );
      await tester.pump();
    }

    testWidgets('「本周」切换成 7 天条带（周一起始），再点「月」切回月历', (tester) async {
      follow(vodId: 'v1', vodName: '测试剧', released: 7);
      await pumpPage(tester);
      expect(find.byKey(const ValueKey('calendar-grid')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('calendar-view-week')));
      await tester.pump();
      expect(find.byKey(const ValueKey('calendar-week-strip')), findsOneWidget);
      expect(find.byKey(const ValueKey('calendar-grid')), findsNothing);
      expect(find.byKey(const ValueKey('calendar-week-title')), findsOneWidget);

      final dates = _weekDates(tester);
      expect(dates.length, 7);
      expect(dates.first.weekday, DateTime.monday);
      expect(dates.last.weekday, DateTime.sunday);
      for (final label in followingCalendarWeekdayLabels) {
        expect(find.text(label), findsOneWidget);
      }

      await tester.tap(find.byKey(const ValueKey('calendar-view-month')));
      await tester.pump();
      expect(find.byKey(const ValueKey('calendar-grid')), findsOneWidget);
      expect(find.byKey(const ValueKey('calendar-week-strip')), findsNothing);
      expect(_shownMonth(tester), isNotNull);
    });

    testWidgets('分段标题按「部数」统计，不是条目数', (tester) async {
      // 两部剧都钉在今天正午：页面默认选中今天，无需再点格子。
      final noon = _todayNoonMs();
      follow(
        vodId: 'v1',
        vodName: '未看剧',
        released: 5,
        watched: 1,
        nextAirAtMs: noon,
      );
      follow(
        vodId: 'v2',
        vodName: '已看剧',
        released: 5,
        watched: 5,
        nextAirAtMs: noon,
      );
      await pumpPage(tester);
      await tester.tap(find.byKey(const ValueKey('calendar-view-week')));
      await tester.pump();

      // 2 部（不是 2 条），其中 1 集未看；同周其余 6 天没有分段。
      expect(find.text('2 部更新 · 未看 1 集'), findsOneWidget);
      expect(find.text('无更新'), findsNothing);
    });

    testWidgets('圆点颜色：已播未看用强调色，已看与待播用弱化色', (tester) async {
      await pumpPage(tester);
      final shown = _shownMonth(tester);
      final today = DateTime.now();
      // 今天必定落在页面默认月份里：当天已播未看 → 强调色。
      final unwatchedDay = DateTime(shown.year, shown.month, today.day);
      // 另一天：月内 1 号（今天是 1 号时用 2 号）。它要么已全部看完、
      // 要么排期在未来（待播），两种都不算未看 → 弱化色。
      final otherDay = DateTime(
        shown.year,
        shown.month,
        today.day == 1 ? 2 : 1,
      );
      follow(
        vodId: 'v1',
        vodName: '未看剧',
        released: 9,
        watched: 2,
        nextAirAtMs: _noonMs(unwatchedDay),
      );
      follow(
        vodId: 'v2',
        vodName: '已看剧',
        released: 9,
        watched: 9,
        nextAirAtMs: _noonMs(otherDay),
      );
      await tester.pump();

      final scheme = buildAppTheme(Brightness.dark).colorScheme;
      Color dotColor(DateTime day) {
        final dot = tester.widget<Container>(
          find.byKey(ValueKey(_dotKey(day))),
        );
        return (dot.decoration! as BoxDecoration).color!;
      }

      expect(dotColor(unwatchedDay), scheme.primary);
      expect(dotColor(otherDay), scheme.outlineVariant);
    });

    testWidgets('周视图翻到跨月那一周：标题跨两个月、7 天连续', (tester) async {
      follow(vodId: 'v1', vodName: '测试剧', released: 7);
      await pumpPage(tester);
      await tester.tap(find.byKey(const ValueKey('calendar-view-week')));
      await tester.pump();

      // 6 周内必然越过一次月界。
      var range = _weekRange(tester);
      for (var i = 0; i < 6 && range[0] == range[2]; i++) {
        await tester.tap(find.byKey(const ValueKey('calendar-next-month')));
        await tester.pump();
        range = _weekRange(tester);
      }
      expect(range[0], isNot(range[2]), reason: '6 周内必然跨过月界');

      final dates = _weekDates(tester);
      expect(dates.length, 7);
      expect(dates.first.month, range[0]);
      expect(dates.first.day, range[1]);
      expect(dates.last.month, range[2]);
      expect(dates.last.day, range[3]);
      for (var i = 1; i < dates.length; i++) {
        expect(
          dates[i],
          DateTime(dates[i - 1].year, dates[i - 1].month, dates[i - 1].day + 1),
        );
      }
    });
  });
}
