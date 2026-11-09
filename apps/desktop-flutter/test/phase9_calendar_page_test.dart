import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/following.dart';
import 'package:webhtv_pc/core/following_calendar.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/tmdb_media.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/following_air_time_service.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/following_calendar_page.dart';
import 'package:webhtv_pc/ui/theme.dart';
import 'package:webhtv_pc/ui/tokens.dart';

/// 一个自然日中午 12 点的毫秒纪元（避开夏令时边界）。
int _noonMs(DateTime day) =>
    DateTime(day.year, day.month, day.day, 12).millisecondsSinceEpoch;

/// **今天**中午 12 点。
///
/// 为什么不用 `now + 1h`：那个值在 23:00–24:00 会跨到次日，条目被归到明天的日
/// 列表里，而断言看的是「今天」，于是每天最后 1 小时必然失败（实际发生过）。
/// `DateTime(y, m, d, 12)` 只由年月日决定，**无论当前几点都落在今天之内**，
/// 且始终在 `FollowingCalendarPolicy` 的可信窗口内（今天正午距 now 最多 ±12h，
/// 远小于 maxAirLead 365 天 / maxAirAge 1825 天）。
int _todayNoonMs() {
  final now = DateTime.now();
  return _noonMs(DateTime(now.year, now.month, now.day));
}

String _dayKey(DateTime day) =>
    'calendar-day-${day.year}-${day.month}-${day.day}';

String _dotKey(DateTime day) =>
    'calendar-dot-${day.year}-${day.month}-${day.day}';

/// 页面**自己显示**的月份。
///
/// 期望值从标题反推，而不是测试里另读一次 `DateTime.now()`：页面在 `initState`
/// 里定月份，若测试先读 now 再 build，月末最后一刻跨月时两者会差一个月（真实的
/// 午夜/月末脆弱点）。从标题读则比较的是「切换前后」这个纯行为差异。
DateTime _shownMonth(WidgetTester tester) {
  final text = tester
      .widget<Text>(find.byKey(const ValueKey('calendar-title')))
      .data!;
  final match = RegExp(r'^(\d+)年(\d+)月$').firstMatch(text)!;
  return DateTime(int.parse(match.group(1)!), int.parse(match.group(2)!));
}

void main() {
  group('追剧日历页（P2-1 配套）', () {
    late Directory temp;
    late AppState state;

    setUp(() async {
      temp = Directory.systemTemp.createTempSync('webhtv-calendar');
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
    void follow({int released = 12, int watched = 0, int? nextAirAtMs}) {
      final item = state.followFromDetail(
        site: Site(
          key: 's',
          name: '甲站',
          type: 4,
          api: 'http://127.0.0.1:1/vod',
        ),
        vod: Vod(vodId: 'v1', vodName: '测试剧'),
        flag: '线路一',
        sourceFlag: '线路一',
        releasedEpisode: released,
      )!;
      state.database!.upsertFollowing(
        item.copyWith(
          latestReleasedEpisode: released,
          seasonReleasedEpisodes: released,
          watchedEpisode: watched,
          readWatermarkEpisode: watched,
          nextAirAtMs: nextAirAtMs ?? 0,
          status: FollowingStatus.returning,
        ),
      );
      state.notifyListeners();
    }

    Future<void> pumpPage(
      WidgetTester tester, {
      Size size = const Size(1100, 800),
    }) async {
      tester.view.physicalSize = size;
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

    test('「今天正午」恒落在当天内（含 23:50 / 00:05 边界）', () {
      // 这是本文件全部「今天」类断言的时钟前提，直接按公式验证：
      // 取一天里最早与最晚的几个时刻，DateTime(y, m, d, 12) 的归日都必须仍是当天。
      for (final hour in const [0, 5, 12, 23]) {
        for (final minute in const [0, 5, 50, 59]) {
          final now = DateTime(2026, 8, 31, hour, minute);
          final today = DateTime(now.year, now.month, now.day);
          final noon = DateTime(now.year, now.month, now.day, 12);
          expect(followingCalendarDateOf(noon.millisecondsSinceEpoch), today);
          // 反例对照：旧写法 `now + 1h` 在 23 点之后就会跨日。
          if (hour == 23) {
            expect(
              followingCalendarDateOf(
                now.add(const Duration(hours: 1)).millisecondsSinceEpoch,
              ),
              isNot(today),
              reason: 'now+1h 在 23 点后跨日，正是原先的缺陷',
            );
          }
        }
      }
    });

    Future<void> showMonth(WidgetTester tester, DateTime target) async {
      final current = _shownMonth(tester);
      final delta =
          (target.year - current.year) * 12 + target.month - current.month;
      expect(delta.abs(), lessThanOrEqualTo(48));
      for (var step = 0; step < delta.abs(); step++) {
        await tester.tap(
          find.byKey(
            ValueKey(delta > 0 ? 'calendar-next-month' : 'calendar-prev-month'),
          ),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
    }

    ScrollPosition listPosition(WidgetTester tester) => tester
        .state<ScrollableState>(
          find
              .descendant(
                of: find.byKey(const ValueKey('calendar-list')),
                matching: find.byType(Scrollable),
              )
              .first,
        )
        .position;

    Future<void> pumpDenseCalendar(WidgetTester tester) async {
      follow(released: 24);
      state.attachFollowingAirTimeService(
        FollowingAirTimeService(
          isConfigured: () => true,
          resolveTmdbId: (item) async => 4242,
          fetchEpisodes: (id, seasonNumber) async => [
            for (var episode = 1; episode <= 24; episode++)
              TmdbEpisode(
                number: episode,
                date: '2026-11-${episode.toString().padLeft(2, '0')}',
              ),
          ],
        ),
      );
      await pumpPage(tester, size: const Size(1280, 800));
      await tester.pumpAndSettle();
      await showMonth(tester, DateTime(2026, 11));
      // 点击定位用例仍从顶部起步，保留原有定位断言。
      listPosition(tester).jumpTo(0);
      await tester.pump();
    }

    DateTime selectedToday(WidgetTester tester) {
      final month = _shownMonth(tester);
      final day = tester
          .widget<Text>(
            find.descendant(
              of: find.byKey(const ValueKey('calendar-today')),
              matching: find.byType(Text),
            ),
          )
          .data!;
      return DateTime(month.year, month.month, int.parse(day));
    }

    Finder dayHeader(DateTime day) => find.byKey(
      ValueKey('calendar-day-header-${day.year}-${day.month}-${day.day}'),
    );

    void expectHeaderVisible(WidgetTester tester, DateTime day) {
      final viewport = tester.getRect(
        find.byKey(const ValueKey('calendar-list')),
      );
      final header = tester.getRect(dayHeader(day));
      expect(header.top, greaterThanOrEqualTo(viewport.top));
      expect(header.bottom, lessThanOrEqualTo(viewport.bottom));
    }

    Future<(DateTime, Completer<List<TmdbEpisode>>)> pumpLoadingCalendar(
      WidgetTester tester, {
      bool denseLocal = false,
    }) async {
      follow(released: 24);
      await pumpPage(tester);
      final today = selectedToday(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      if (denseLocal && today.day > 1) {
        for (var index = 2; index <= 10; index++) {
          final item = state.followFromDetail(
            site: Site(
              key: 's',
              name: '甲站',
              type: 4,
              api: 'http://127.0.0.1:1/vod',
            ),
            vod: Vod(vodId: 'v$index', vodName: '较早的剧$index'),
            flag: '线路一',
            releasedEpisode: 1,
          )!;
          state.database!.upsertFollowing(
            item.copyWith(
              nextAirAtMs: _noonMs(DateTime(today.year, today.month, 1)),
              status: FollowingStatus.returning,
            ),
          );
        }
      }
      final episodes = Completer<List<TmdbEpisode>>();
      state.attachFollowingAirTimeService(
        FollowingAirTimeService(
          isConfigured: () => true,
          resolveTmdbId: (item) async => item.vodId == 'v1' ? 4242 : null,
          fetchEpisodes: (id, seasonNumber) => episodes.future,
        ),
      );
      await pumpPage(tester);
      await tester.pumpAndSettle();
      return (selectedToday(tester), episodes);
    }

    List<TmdbEpisode> loadedEpisodes(
      DateTime today, {
      bool todayEmpty = false,
    }) {
      final early = DateTime(today.year, today.month, today.day == 1 ? 3 : 1);
      final target = todayEmpty
          ? DateTime(
              today.year,
              today.month,
              today.day == 1 ? 2 : today.day - 1,
            )
          : today;
      String date(DateTime day) =>
          '${day.year}-${day.month.toString().padLeft(2, '0')}-'
          '${day.day.toString().padLeft(2, '0')}';
      return [
        for (var episode = 1; episode <= 20; episode++)
          TmdbEpisode(number: episode, date: date(early)),
        TmdbEpisode(number: 21, date: date(target)),
        TmdbEpisode(
          number: 22,
          date: date(DateTime(today.year, today.month, today.day + 1)),
        ),
      ];
    }

    testWidgets('首帧及异步数据就绪后无点击自动定位今天分段', (tester) async {
      final (today, episodes) = await pumpLoadingCalendar(
        tester,
        denseLocal: true,
      );
      expectHeaderVisible(tester, today);
      if (today.day > 1) {
        expect(listPosition(tester).pixels, greaterThan(0));
      }
      episodes.complete(loadedEpisodes(today));
      await tester.pumpAndSettle();
      expectHeaderVisible(tester, today);
      if (today.day > 1) {
        expect(listPosition(tester).pixels, greaterThan(0));
      }
      final position = listPosition(tester);
      await tester.drag(
        find.byKey(const ValueKey('calendar-list')),
        const Offset(0, 300),
      );
      await tester.pumpAndSettle();
      final offset = position.pixels;
      state.notifyListeners();
      await tester.pumpAndSettle();
      expect(position.pixels, offset);
      expect(tester.takeException(), isNull);
    });

    testWidgets('今天无更新自动定位最近较早分段并保留提示与全部分段', (tester) async {
      final (today, episodes) = await pumpLoadingCalendar(tester);
      episodes.complete(loadedEpisodes(today, todayEmpty: true));
      await tester.pumpAndSettle();
      final target = DateTime(
        today.year,
        today.month,
        today.day == 1 ? 2 : today.day - 1,
      );
      expect(find.text('${today.month}月${today.day}日 没有更新'), findsOneWidget);
      expectHeaderVisible(tester, target);
      expect(
        dayHeader(DateTime(today.year, today.month, today.day + 1)),
        findsOneWidget,
      );
      if (today.day > 2) {
        expect(dayHeader(DateTime(today.year, today.month, 1)), findsOneWidget);
        expect(listPosition(tester).pixels, greaterThan(0));
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('当前月完全无内容时保留空态与今天无更新提示', (tester) async {
      final (today, episodes) = await pumpLoadingCalendar(tester);
      final nextMonth = DateTime(today.year, today.month + 1);
      episodes.complete([
        TmdbEpisode(
          number: 1,
          date:
              '${nextMonth.year}-${nextMonth.month.toString().padLeft(2, '0')}-01',
        ),
      ]);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('calendar-list')), findsNothing);
      expect(find.byKey(const ValueKey('calendar-day-empty')), findsOneWidget);
      expect(find.text('${today.month}月${today.day}日 没有更新'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('加载期间手动滚动后数据就绪不抢回列表位置', (tester) async {
      final (today, episodes) = await pumpLoadingCalendar(
        tester,
        denseLocal: true,
      );
      final position = listPosition(tester);
      await tester.drag(
        find.byKey(const ValueKey('calendar-list')),
        const Offset(0, 300),
      );
      await tester.pumpAndSettle();
      final offset = position.pixels;
      episodes.complete(loadedEpisodes(today));
      await tester.pumpAndSettle();
      expect(listPosition(tester), same(position));
      expect(position.pixels, offset);
      expect(tester.takeException(), isNull);
    });

    testWidgets('切周视图再切回月视图自动定位选中日而不回顶部', (tester) async {
      await pumpDenseCalendar(tester);
      const listKey = ValueKey('calendar-list');
      final selected = DateTime(2026, 11, 20);
      await tester.tap(find.byKey(ValueKey(_dayKey(selected))));
      await tester.pumpAndSettle();
      listPosition(tester).jumpTo(0);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('calendar-view-week')));
      await tester.pumpAndSettle();
      expectHeaderVisible(tester, selected);
      expect(listPosition(tester).pixels, greaterThan(0));
      await tester.drag(find.byKey(listKey), const Offset(0, 1000));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('calendar-view-month')));
      await tester.pumpAndSettle();
      expectHeaderVisible(tester, selected);
      expect(listPosition(tester).pixels, greaterThan(0));
      expect(tester.takeException(), isNull);
    });

    testWidgets('点击远端更新日期会滚动定位并标记选中分段', (tester) async {
      await pumpDenseCalendar(tester);
      final position = listPosition(tester);
      expect(position.pixels, 0);
      await tester.tap(find.byKey(const ValueKey('calendar-day-2026-11-20')));
      await tester.pumpAndSettle();
      expect(listPosition(tester), same(position));
      expect(position.pixels, greaterThan(0));
      final header = find.byKey(
        const ValueKey('calendar-day-header-2026-11-20'),
      );
      final viewport = tester.getRect(
        find.byKey(const ValueKey('calendar-list')),
      );
      expect(viewport.contains(tester.getCenter(header)), isTrue);
      expect(
        find.byKey(const ValueKey('calendar-day-selected-2026-11-20')),
        findsOneWidget,
      );
      expect(
        tester.widget<Text>(header).style!.color,
        Theme.of(tester.element(header)).colorScheme.primary,
      );
      final offset = position.pixels;
      state.notifyListeners();
      await tester.pumpAndSettle();
      expect(position.pixels, offset);
      expect(tester.takeException(), isNull);
    });

    testWidgets('点击无更新日期显示明确提示且保留列表滚动位置', (tester) async {
      await pumpDenseCalendar(tester);
      await tester.drag(
        find.byKey(const ValueKey('calendar-list')),
        const Offset(0, -400),
      );
      await tester.pumpAndSettle();
      final position = listPosition(tester);
      final offset = position.pixels;
      await tester.tap(find.byKey(const ValueKey('calendar-day-2026-11-28')));
      await tester.pumpAndSettle();
      expect(find.text('11月28日 没有更新'), findsOneWidget);
      expect(find.byKey(const ValueKey('calendar-list')), findsOneWidget);
      expect(listPosition(tester), same(position));
      expect(position.pixels, offset);
      expect(tester.takeException(), isNull);
    });

    testWidgets('月历完整区域不超过视口40%且五周月份更矮', (tester) async {
      await pumpDenseCalendar(tester);
      final grid = find.byKey(const ValueKey('calendar-grid'));
      final page = find.byType(FollowingCalendarPage);
      final viewport = tester.getRect(
        find.byKey(const ValueKey('calendar-list')),
      );
      final cards = find.byWidgetPredicate(
        (widget) =>
            widget is InkWell &&
            widget.key.toString().contains('calendar-entry-'),
      );
      final visible = cards.evaluate().where((element) {
        final box = element.renderObject as RenderBox;
        final rect = box.localToGlobal(Offset.zero) & box.size;
        return rect.top >= viewport.top && rect.bottom <= viewport.bottom;
      }).length;
      final regionHeight = tester
          .getSize(find.byKey(const ValueKey('calendar-region')))
          .height;
      final firstCard = find.byWidgetPredicate(
        (widget) =>
            widget is Container && '${widget.key}'.contains('calendar-card-'),
      );
      final cardHeight = tester.getSize(firstCard.first).height;
      final cellHeight = tester
          .getSize(find.byKey(const ValueKey('calendar-day-2026-11-1')))
          .height;
      debugPrint(
        'CALENDAR_METRICS cell=$cellHeight grid=${tester.getSize(grid).height} '
        'region=$regionHeight viewport=${tester.getSize(page).height} '
        'gridRatio=${tester.getSize(grid).height / tester.getSize(page).height} '
        'regionRatio=${regionHeight / tester.getSize(page).height} visible=$visible '
        'card=$cardHeight',
      );
      expect(cellHeight, inInclusiveRange(24, 30));
      expect(regionHeight / tester.getSize(page).height, lessThanOrEqualTo(.4));
      expect(visible, greaterThanOrEqualTo(4));
      final sixWeekHeight = tester.getSize(grid).height;
      await showMonth(tester, DateTime(2026, 12));
      expect(tester.getSize(grid).height, lessThan(sixWeekHeight));
      debugPrint('CALENDAR_FIVE_WEEKS grid=${tester.getSize(grid).height}');
      await showMonth(tester, DateTime(2026, 11));
      tester.view.physicalSize = const Size(1280, 600);
      await tester.pumpAndSettle();
      final compactHeight = tester
          .getSize(find.byKey(const ValueKey('calendar-region')))
          .height;
      expect(
        compactHeight / tester.getSize(page).height,
        lessThanOrEqualTo(.4),
      );
      expect(
        tester
            .getSize(find.byKey(const ValueKey('calendar-day-2026-11-1')))
            .height,
        greaterThanOrEqualTo(24),
      );
      debugPrint(
        'CALENDAR_COMPACT region=$compactHeight viewport=600 '
        'grid=${tester.getSize(grid).height}',
      );
      tester.view.physicalSize = const Size(1280, 400);
      await tester.pumpAndSettle();
      final region = find.byKey(const ValueKey('calendar-region'));
      expect(tester.getSize(region).height, lessThanOrEqualTo(160));
      final lastDay = find.byKey(const ValueKey('calendar-day-2026-11-30'));
      await tester.ensureVisible(lastDay);
      await tester.pumpAndSettle();
      expect(
        tester.getRect(region).contains(tester.getCenter(lastDay)),
        isTrue,
      );
      expect(lastDay.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('周视图点击更新和空日期同样定位与反馈', (tester) async {
      await pumpDenseCalendar(tester);
      await tester.tap(find.byKey(const ValueKey('calendar-day-2026-11-20')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('calendar-view-week')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('calendar-week-day-2026-11-22')),
      );
      await tester.pumpAndSettle();
      final header = find.byKey(
        const ValueKey('calendar-day-header-2026-11-22'),
      );
      expect(
        tester
            .getRect(find.byKey(const ValueKey('calendar-list')))
            .contains(tester.getCenter(header)),
        isTrue,
      );
      expect(
        find.byKey(const ValueKey('calendar-day-selected-2026-11-22')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('calendar-next-month')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('calendar-week-day-2026-11-29')),
      );
      await tester.pumpAndSettle();
      expect(find.text('11月29日 没有更新'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('今日按钮定位当天分段并标记选中', (tester) async {
      follow(nextAirAtMs: _todayNoonMs());
      await pumpPage(tester);
      final today = DateTime.fromMillisecondsSinceEpoch(_todayNoonMs());
      await showMonth(tester, DateTime(today.year, today.month - 1));
      await tester.tap(find.byKey(const ValueKey('calendar-today-button')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(
          ValueKey(
            'calendar-day-selected-${today.year}-${today.month}-${today.day}',
          ),
        ),
        findsOneWidget,
      );
      expect(
        tester
            .getRect(find.byKey(const ValueKey('calendar-list')))
            .contains(
              tester.getCenter(
                find.byKey(
                  ValueKey(
                    'calendar-day-header-${today.year}-${today.month}-${today.day}',
                  ),
                ),
              ),
            ),
        isTrue,
      );
    });

    testWidgets('跨月格子切月且无更新时明确反馈', (tester) async {
      await pumpDenseCalendar(tester);
      await showMonth(tester, DateTime(2026, 12));
      await tester.tap(find.byKey(const ValueKey('calendar-day-2026-11-30')));
      await tester.pumpAndSettle();
      expect(_shownMonth(tester), DateTime(2026, 11));
      expect(find.text('11月30日 没有更新'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('月份切换改变标题与网格', (tester) async {
      follow();
      await pumpPage(tester);
      // 期望值从页面标题反推：不在测试里另读 now，避免月末跨月时差一个月。
      final current = _shownMonth(tester);
      expect(find.text('${current.year}年${current.month}月'), findsOneWidget);

      final next = DateTime(current.year, current.month + 1);
      await tester.tap(find.byKey(const ValueKey('calendar-next-month')));
      await tester.pump();
      expect(find.text('${next.year}年${next.month}月'), findsOneWidget);
      expect(find.byKey(ValueKey(_dayKey(next))), findsOneWidget);
      expect(_shownMonth(tester), next);

      await tester.tap(find.byKey(const ValueKey('calendar-prev-month')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('calendar-prev-month')));
      await tester.pump();
      final prev = DateTime(current.year, current.month - 1);
      expect(find.text('${prev.year}年${prev.month}月'), findsOneWidget);
      expect(find.byKey(ValueKey(_dayKey(prev))), findsOneWidget);
      expect(_shownMonth(tester), prev);

      // 「今天」把标题与选中日拉回当月。
      await tester.tap(find.byKey(const ValueKey('calendar-today-button')));
      await tester.pump();
      expect(_shownMonth(tester), current);
    });

    testWidgets('今天高亮且周一表头齐全', (tester) async {
      follow();
      await pumpPage(tester);
      expect(find.byKey(const ValueKey('calendar-today')), findsOneWidget);
      expect(find.byKey(const ValueKey('calendar-weekdays')), findsOneWidget);
      for (final label in const ['一', '二', '三', '四', '五', '六', '日']) {
        expect(find.text(label), findsWidgets);
      }
    });

    testWidgets('有更新的日子出现圆点', (tester) async {
      follow();
      await pumpPage(tester);
      // 锚定在**页面当前显示的月份**里，而不是测试自己读的 now：
      // 否则月末最后一刻测试读到上月、页面已切到下月时二者对不上。
      final shown = _shownMonth(tester);
      final airDay = DateTime(shown.year, shown.month, 15);
      final quietDay = DateTime(shown.year, shown.month, 16);
      // 未来 1 年内的播出时间在可信窗口内 → 归到该日并算「有更新」。
      state.database!.upsertFollowing(
        state.followings.single.copyWith(nextAirAtMs: _noonMs(airDay)),
      );
      state.notifyListeners();
      await tester.pump();

      expect(find.byKey(ValueKey(_dotKey(airDay))), findsOneWidget);
      // 没条目的日子不画圆点。
      expect(find.byKey(ValueKey(_dotKey(quietDay))), findsNothing);
    });

    testWidgets('当日条目显示集号与观看进度', (tester) async {
      follow(released: 17, watched: 15);
      await pumpPage(tester);
      expect(find.byKey(const ValueKey('calendar-list')), findsOneWidget);
      expect(find.text('测试剧'), findsOneWidget);
      // 一集一条：降级日只出最新一集，集号是单集 `S01E17` 而不是区间。
      expect(find.text('S01E17'), findsOneWidget);
      // 未配置 TMDB → 分母是线路可播集数，不写总集数、不给百分比。
      expect(find.text('第1季 · 线路已播 17 集'), findsOneWidget);
      expect(find.textContaining('%'), findsNothing);
      // 逐集的整剧已看文案已移除：这一集高于已看水位 15 → 集级胶囊「未看」。
      expect(find.text('已看 15 集'), findsNothing);
      expect(find.text('2 集未看'), findsNothing);
      expect(find.text('未看'), findsOneWidget);
    });

    testWidgets('接入官方总集数后显示「已播 23 / 40 集」与百分比', (tester) async {
      // 参考截图的形态：本线路已可播 23 集，官方该季 40 集 → 57%。
      // 日期一律用 DateTime(y,m,d,12) / 当天正午反推，不用 now 加偏移。
      final today = DateTime.now();
      final airDay = DateTime(today.year, today.month, today.day);
      final dateText =
          '${airDay.year}-${airDay.month.toString().padLeft(2, '0')}'
          '-${airDay.day.toString().padLeft(2, '0')}';
      follow(released: 23, watched: 20);
      // 假 TMDB：该季 40 集，只有第 23 集有播出日（就是今天）。
      state.attachFollowingAirTimeService(
        FollowingAirTimeService(
          isConfigured: () => true,
          resolveTmdbId: (item) async => 4242,
          fetchEpisodes: (id, seasonNumber) async => [
            for (var episode = 1; episode <= 40; episode++)
              TmdbEpisode(number: episode, date: episode == 23 ? dateText : ''),
          ],
        ),
      );
      state.notifyListeners();
      await pumpPage(tester);
      // 一次 pump 触发异步加载，再 pump 渲染播出时间与总集数的结果。
      await tester.pump();

      expect(find.text('S01E23'), findsOneWidget);
      expect(find.text('第1季 · 线路已播 23 / 40 集'), findsOneWidget);
      expect(find.text('57%'), findsOneWidget);
      // 集号 23 高于已看水位 20 → 这一集未看，不再逐集重复整剧已看集数。
      expect(find.text('未看'), findsOneWidget);
      expect(find.text('已看 20 集'), findsNothing);
      // 分段标题按「部数」统计，不是条目数。
      expect(find.text('1 部更新 · 未看 1 集'), findsOneWidget);
    });

    /// 官方 40 集、第 `released` 集播出日为今天 → 一条卡片，供卡片/进度/徽标断言。
    Future<String> followOfficial(
      WidgetTester tester, {
      int released = 23,
      int watched = 20,
    }) async {
      final today = DateTime.now();
      final dateText =
          '${today.year}-${today.month.toString().padLeft(2, '0')}'
          '-${today.day.toString().padLeft(2, '0')}';
      follow(released: released, watched: watched);
      state.attachFollowingAirTimeService(
        FollowingAirTimeService(
          isConfigured: () => true,
          resolveTmdbId: (item) async => 4242,
          fetchEpisodes: (id, seasonNumber) async => [
            for (var episode = 1; episode <= 40; episode++)
              TmdbEpisode(
                number: episode,
                date: episode == released ? dateText : '',
              ),
          ],
        ),
      );
      state.notifyListeners();
      await pumpPage(tester);
      await tester.pump();
      return state.followings.single.identityKey;
    }

    Future<String> followTwoEpisodes(WidgetTester tester) async {
      final today = DateTime.now();
      final dateText =
          '${today.year}-${today.month.toString().padLeft(2, '0')}-'
          '${today.day.toString().padLeft(2, '0')}';
      follow(released: 10, watched: 9);
      state.attachFollowingAirTimeService(
        FollowingAirTimeService(
          isConfigured: () => true,
          resolveTmdbId: (item) async => 4242,
          fetchEpisodes: (id, seasonNumber) async => [
            for (var episode = 1; episode <= 27; episode++)
              TmdbEpisode(
                number: episode,
                title: episode == 10 ? '决斗之夜' : '',
                date: episode == 9 || episode == 10 ? dateText : '',
              ),
          ],
        ),
      );
      await pumpPage(tester);
      await tester.pumpAndSettle();
      return state.followings.single.identityKey;
    }

    testWidgets('主行集号紧跟剧名右侧而不是卡片最右侧', (tester) async {
      final identity = await followTwoEpisodes(tester);
      final card = find.byKey(ValueKey('calendar-card-$identity-S01E09'));
      final name = find.descendant(of: card, matching: find.text('测试剧'));
      final code = find.descendant(of: card, matching: find.text('S01E09'));
      final gap = tester.getTopLeft(code).dx - tester.getTopRight(name).dx;
      expect(gap, inInclusiveRange(0, AppSpace.md));
      // 字号不同，比较垂直中心而不是 top：集号必须与剧名同在主行。
      expect(
        tester.getCenter(code).dy,
        closeTo(tester.getCenter(name).dy, AppSpace.md),
      );
      expect(tester.widget<Text>(code).style?.fontWeight, FontWeight.w700);
    });

    testWidgets('箭头贴卡片右内边距且长剧名不挤压集号和状态', (tester) async {
      final identity = await followTwoEpisodes(tester);
      final longName = List.filled(30, '这是很长的剧名').join();
      for (final label in ['测试剧', longName]) {
        state.database!.upsertFollowing(
          state.followings.single.copyWith(vodName: label),
        );
        state.notifyListeners();
        await tester.pumpAndSettle();
        for (final (code, status) in [('S01E09', '已看'), ('S01E10', '未看')]) {
          final card = find.byKey(ValueKey('calendar-card-$identity-$code'));
          final name = find.descendant(of: card, matching: find.text(label));
          final episode = find.descendant(of: card, matching: find.text(code));
          final capsule = find.byKey(
            ValueKey('calendar-episode-state-$identity-$code'),
          );
          final arrow = find.descendant(
            of: card,
            matching: find.byIcon(Icons.chevron_right),
          );
          expect(arrow, findsOneWidget);
          expect(
            tester.getRect(card).right - tester.getRect(arrow).right,
            inInclusiveRange(AppSpace.lg, AppSpace.lg + 2),
          );
          expect(
            tester.getTopLeft(episode).dx - tester.getTopRight(name).dx,
            inInclusiveRange(0, AppSpace.md),
          );
          expect(
            tester.getRect(capsule).left,
            greaterThanOrEqualTo(tester.getRect(episode).right),
          );
          expect(
            tester.getRect(capsule).right,
            lessThanOrEqualTo(tester.getRect(arrow).left - AppSpace.sm),
          );
          expect(
            tester.getCenter(capsule).dy,
            closeTo(tester.getCenter(episode).dy, 1),
          );
          expect(
            find.descendant(of: capsule, matching: find.text(status)),
            findsOneWidget,
          );
          expect(tester.widget<Text>(name).maxLines, 1);
          expect(tester.widget<Text>(name).overflow, TextOverflow.ellipsis);
        }
        expect(tester.takeException(), isNull);
      }
    });

    /// 今天 0:00（用例内多次比较日期时用，不含时分秒）。
    DateTime todayMidnight() {
      final now = DateTime.now();
      return DateTime(now.year, now.month, now.day);
    }

    String tmdbDate(DateTime day) =>
        '${day.year}-${day.month.toString().padLeft(2, '0')}-'
        '${day.day.toString().padLeft(2, '0')}';

    /// 今天 E09 已看 / E10 已播未看，明天 E11 待播；官方该季 27 集。
    Future<String> followTodayAndTomorrow(WidgetTester tester) async {
      final today = todayMidnight();
      final tomorrow = DateTime(today.year, today.month, today.day + 1);
      follow(released: 10, watched: 9);
      state.attachFollowingAirTimeService(
        FollowingAirTimeService(
          isConfigured: () => true,
          resolveTmdbId: (item) async => 4242,
          fetchEpisodes: (id, seasonNumber) async => [
            for (var episode = 1; episode <= 27; episode++)
              TmdbEpisode(
                number: episode,
                date: switch (episode) {
                  9 || 10 => tmdbDate(today),
                  11 => tmdbDate(tomorrow),
                  _ => '',
                },
              ),
          ],
        ),
      );
      await pumpPage(tester);
      await tester.pumpAndSettle();
      return state.followings.single.identityKey;
    }

    testWidgets('待播集不算未看且剧级行给出排期上限', (tester) async {
      final identity = await followTodayAndTomorrow(tester);
      final today = todayMidnight();
      final tomorrow = DateTime(today.year, today.month, today.day + 1);

      await showMonth(tester, today);
      await tester.tap(find.byKey(ValueKey(_dayKey(today))));
      await tester.pumpAndSettle();
      expect(
        find.byKey(ValueKey('calendar-card-$identity-S01E09')),
        findsOneWidget,
      );
      expect(
        find.byKey(ValueKey('calendar-card-$identity-S01E10')),
        findsOneWidget,
      );
      // 剧级行：线路已播 + 排期上限；每个自然日每部剧只有首卡带它，
      // 因此今天（E09 首卡）与明天（E11 首卡）各一次。
      expect(find.textContaining('第1季 · 线路已播 10 / 27 集'), findsNWidgets(2));
      expect(find.textContaining('平台排期至 E11'), findsNWidgets(2));
      expect(find.text('平台排期'), findsNWidgets(2));
      expect(
        find.byKey(ValueKey('calendar-air-progress-$identity-S01E10')),
        findsNothing,
      );
      expect(find.text('1 部更新 · 未看 1 集'), findsOneWidget);
      expect(find.text('1 部更新 · 待播 1 集'), findsOneWidget);
      // 数据供应商的名字不上界面：来源一律写中性说法，防回潮。
      expect(find.textContaining('TMDB'), findsNothing);

      await showMonth(tester, tomorrow);
      await tester.tap(find.byKey(ValueKey(_dayKey(tomorrow))));
      await tester.pumpAndSettle();
      final pendingCard = find.byKey(
        ValueKey('calendar-card-$identity-S01E11'),
      );
      expect(pendingCard, findsOneWidget);
      final capsule = find.byKey(
        ValueKey('calendar-episode-state-$identity-S01E11'),
      );
      expect(
        find.descendant(of: capsule, matching: find.text('待播')),
        findsOneWidget,
      );
      // 未来集不进入未看：这张卡里没有「未看」。
      expect(
        find.descendant(of: pendingCard, matching: find.text('未看')),
        findsNothing,
      );
    });

    testWidgets('同剧同日两集仅首卡显示剧级行进度条和来源', (tester) async {
      final identity = await followTwoEpisodes(tester);
      for (final view in ['month', 'week']) {
        await tester.tap(find.byKey(ValueKey('calendar-view-$view')));
        await tester.pumpAndSettle();
        expect(find.textContaining('线路已播 10 / 27 集'), findsOneWidget);
        expect(find.text('37%'), findsOneWidget);
        expect(find.text('平台排期'), findsOneWidget);
        expect(
          find.byKey(ValueKey('calendar-air-progress-$identity-S01E09')),
          findsOneWidget,
        );
        expect(
          find.byKey(ValueKey('calendar-air-progress-$identity-S01E10')),
          findsNothing,
        );
        expect(find.textContaining('集未看'), findsNothing);
        expect(find.textContaining('已看 9 集'), findsNothing);
      }
    });

    testWidgets('分集标题只显示在对应集且空标题整行省略', (tester) async {
      final identity = await followTwoEpisodes(tester);
      final first = find.byKey(ValueKey('calendar-card-$identity-S01E09'));
      final second = find.byKey(ValueKey('calendar-card-$identity-S01E10'));
      expect(find.descendant(of: first, matching: find.text('决斗之夜')), findsNothing);
      expect(find.descendant(of: second, matching: find.text('决斗之夜')), findsOneWidget);
      expect(find.byKey(ValueKey('calendar-title-$identity-S01E09')), findsNothing);
      expect(find.byKey(ValueKey('calendar-title-$identity-S01E10')), findsOneWidget);
      expect(find.text('null'), findsNothing);
    });

    testWidgets('集级状态按水位区分E09已看和E10未看', (tester) async {
      final identity = await followTwoEpisodes(tester);
      for (final (code, label) in [('S01E09', '已看'), ('S01E10', '未看')]) {
        final card = find.byKey(ValueKey('calendar-card-$identity-$code'));
        expect(find.descendant(of: card, matching: find.text(label)), findsOneWidget);
        expect(
          find.descendant(of: card, matching: find.text(label == '已看' ? '未看' : '已看')),
          findsNothing,
        );
      }
    });

    testWidgets('条目卡片：surfaceContainerLow 底、lg 圆角、发丝边、无阴影', (tester) async {
      final identity = await followOfficial(tester);
      final card = find.byKey(ValueKey('calendar-card-$identity-S01E23'));
      expect(card, findsOneWidget);
      final decoration =
          tester.widget<Container>(card).decoration! as BoxDecoration;
      final scheme = Theme.of(tester.element(card)).colorScheme;
      expect(decoration.color, scheme.surfaceContainerLow);
      expect(decoration.borderRadius, AppRadius.lgAll);
      // 全站不用阴影、不用 elevation：层级靠表面阶梯 + 发丝边。
      expect(decoration.boxShadow, isNull);
      final side = (decoration.border! as Border).top;
      expect(side.width, 1);
      expect(side.color.a, closeTo(.72, .01));
      final material = tester.widget<Material>(
        find.descendant(of: card, matching: find.byType(Material)).first,
      );
      expect(material.elevation, 0);
      expect(material.surfaceTintColor, isNull);
      final poster = find.descendant(
        of: card,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is SizedBox && widget.width == 48 && widget.height == 72,
        ),
      );
      expect(tester.getSize(poster), const Size(48, 72));
      // 卡片之间只用间隙，列表内不再有把各行连成一片的分隔线。
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('calendar-list')),
          matching: find.byType(Divider),
        ),
        findsNothing,
      );
    });

    testWidgets('播出进度条限宽并跟随卡片内容左对齐', (tester) async {
      final identity = await followOfficial(tester);
      final progress = find.byKey(
        ValueKey('calendar-air-progress-$identity-S01E23'),
      );
      final aired = find.byKey(ValueKey('calendar-aired-$identity-S01E23'));
      final card = find.byKey(ValueKey('calendar-card-$identity-S01E23'));
      expect(progress, findsOneWidget);
      final width = tester.getSize(progress).width;
      // 上限 280：1280 宽下不再横跨整行，避免读成一条分隔线。
      expect(width, inInclusiveRange(1, 280));
      expect(width, lessThan(tester.getSize(card).width / 2));
      expect(tester.getTopLeft(progress).dx, tester.getTopLeft(aired).dx);
    });

    testWidgets('集级胶囊取代逐集重复的未看数值徽标', (tester) async {
      final identity = await followOfficial(tester);
      final capsule = find.byKey(
        ValueKey('calendar-episode-state-$identity-S01E23'),
      );
      expect(capsule, findsOneWidget);
      expect(
        find.descendant(of: capsule, matching: find.text('未看')),
        findsOneWidget,
      );
      expect(find.text('20 集未看'), findsNothing);
      expect(find.text('已看 20 集'), findsNothing);
      expect(find.textContaining('还剩'), findsNothing);
      // 来源标记保留且只出现一次：real 表示日期来自平台排期。
      expect(find.text('平台排期'), findsOneWidget);
    });

    testWidgets('全部看完时集级胶囊显示已看且不出现未看', (tester) async {
      final identity = await followOfficial(tester, released: 40, watched: 40);
      final capsule = find.byKey(
        ValueKey('calendar-episode-state-$identity-S01E40'),
      );
      expect(capsule, findsOneWidget);
      expect(
        find.descendant(of: capsule, matching: find.text('已看')),
        findsOneWidget,
      );
      expect(find.text('未看'), findsNothing);
      expect(find.textContaining('集未看'), findsNothing);
      expect(find.textContaining('已看完'), findsNothing);
    });

    testWidgets('同剧同日多集在整月和整周列表都不会产生重复 key', (tester) async {
      final noon = DateTime.fromMillisecondsSinceEpoch(_todayNoonMs());
      final dateText =
          '${noon.year}-${noon.month.toString().padLeft(2, '0')}'
          '-${noon.day.toString().padLeft(2, '0')}';
      follow(released: 2, watched: 0);
      state.attachFollowingAirTimeService(
        FollowingAirTimeService(
          isConfigured: () => true,
          resolveTmdbId: (item) async => 4242,
          fetchEpisodes: (id, seasonNumber) async => [
            TmdbEpisode(number: 1, date: dateText),
            TmdbEpisode(number: 2, date: dateText),
          ],
        ),
      );
      await pumpPage(tester);
      await tester.pump();
      final identity = state.followings.single.identityKey;
      for (final view in ['month', 'week']) {
        await tester.tap(find.byKey(ValueKey('calendar-view-$view')));
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(
          find.byKey(ValueKey('calendar-entry-$identity-S01E01')),
          findsOneWidget,
        );
        expect(
          find.byKey(ValueKey('calendar-entry-$identity-S01E02')),
          findsOneWidget,
        );
        expect(find.text('1 部更新 · 未看 2 集'), findsOneWidget);
      }
    });

    testWidgets('未知分母只显示已播集数，不显示百分比', (tester) async {
      follow(released: 0);
      await pumpPage(tester);
      expect(find.text('S01'), findsOneWidget);
      expect(find.text('第1季 · 线路已播 0 集'), findsOneWidget);
      // 集号未知：不给集级胶囊（无法判断这一集），也不再写整剧已看/未看。
      expect(
        find.byKey(ValueKey('calendar-episode-state-${state.followings.single.identityKey}-S01')),
        findsNothing,
      );
      expect(find.textContaining('已看'), findsNothing);
      expect(find.textContaining('%'), findsNothing);
    });

    testWidgets('固定日期日历 fixture 生成整周与整月真实 widget 截图', (tester) async {
      final boundaryKey = GlobalKey();
      final font = FontLoader('CalendarFixture');
      await tester.runAsync(() async {
        for (final name in ['msyh.ttc', 'msyhbd.ttc']) {
          final bytes = await File(r'C:\Windows\Fonts\' + name).readAsBytes();
          font.addFont(Future.value(ByteData.sublistView(bytes)));
        }
        await font.load();
        final icons = FontLoader('MaterialIcons');
        final iconBytes = await File(
          r'C:\dev\flutter\bin\cache\artifacts\material_fonts\materialicons-regular.otf',
        ).readAsBytes();
        icons.addFont(Future.value(ByteData.sublistView(iconBytes)));
        await icons.load();
      });
      // 相对今天取日期：E09/E10 当天已播（一封一未看），E11 明天待播。
      final today = todayMidnight();
      final tomorrow = DateTime(today.year, today.month, today.day + 1);
      follow(released: 10, watched: 9);
      state.attachFollowingAirTimeService(
        FollowingAirTimeService(
          isConfigured: () => true,
          resolveTmdbId: (item) async => 4242,
          fetchEpisodes: (id, seasonNumber) async => [
            for (var episode = 1; episode <= 27; episode++)
              TmdbEpisode(
                number: episode,
                title: episode == 10 ? '决斗之夜' : '',
                date: switch (episode) {
                  9 || 10 => tmdbDate(today),
                  11 => tmdbDate(tomorrow),
                  _ => '',
                },
              ),
          ],
        ),
      );
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final theme = buildAppTheme(Brightness.dark);
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundaryKey,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: theme.copyWith(
              textTheme: theme.textTheme.apply(fontFamily: 'CalendarFixture'),
              primaryTextTheme: theme.primaryTextTheme.apply(
                fontFamily: 'CalendarFixture',
              ),
              textButtonTheme: TextButtonThemeData(
                style: theme.textButtonTheme.style?.copyWith(
                  textStyle: WidgetStatePropertyAll(
                    theme.textTheme.labelLarge?.copyWith(
                      fontFamily: 'CalendarFixture',
                    ),
                  ),
                ),
              ),
            ),
            home: Scaffold(body: FollowingCalendarPage(state: state)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await showMonth(tester, today);
      await tester.tap(find.byKey(ValueKey(_dayKey(today))));
      await tester.pumpAndSettle();
      final identity = state.followings.single.identityKey;
      // 今天同剧两集：剧级行只属于各自当天的首卡（今天 E09、明天 E11）。
      expect(find.textContaining('第1季 · 线路已播 10 / 27 集'), findsNWidgets(2));
      expect(find.text('37%'), findsNWidgets(2));
      expect(find.textContaining('平台排期至 E11'), findsNWidgets(2));
      expect(
        find.byKey(ValueKey('calendar-air-progress-$identity-S01E09')),
        findsOneWidget,
      );
      expect(
        find.byKey(ValueKey('calendar-air-progress-$identity-S01E10')),
        findsNothing,
      );
      // 逐集重复的已看/未看文案已移除，集级胶囊按水位区分：E09 已看、E10 未看。
      expect(find.textContaining('集未看'), findsNothing);
      expect(find.textContaining('已看 '), findsNothing);
      expect(find.text('已看'), findsOneWidget);
      expect(find.text('未看'), findsOneWidget);
      // 集标题只在有标题的那一集出现。
      expect(find.text('决斗之夜'), findsOneWidget);
      expect(find.text('平台排期'), findsNWidgets(2));
      expect(find.text('1 部更新 · 未看 1 集'), findsOneWidget);
      // 明天的 E11 排期在未来：只报待播，不进未看。
      expect(find.text('1 部更新 · 待播 1 集'), findsOneWidget);
      expect(find.text('待播'), findsOneWidget);
      // 整页不出现数据供应商名字（截图 fixture 覆盖完整页面）。
      expect(find.textContaining('TMDB'), findsNothing);
      for (final view in ['week', 'month']) {
        await tester.tap(find.byKey(ValueKey('calendar-view-$view')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          find.byKey(ValueKey('calendar-day-selected-${today.year}-'
              '${today.month}-${today.day}')),
          findsOneWidget,
        );
        final card = find.byKey(ValueKey('calendar-card-$identity-S01E09'));
        final nextCard = find.byKey(ValueKey('calendar-card-$identity-S01E10'));
        final decoration =
            tester.widget<Container>(card).decoration! as BoxDecoration;
        final radius = (decoration.borderRadius! as BorderRadius).topLeft.x;
        final progress = find.byKey(
          ValueKey('calendar-air-progress-$identity-S01E09'),
        );
        final poster = find.descendant(
          of: card,
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is SizedBox && widget.width == 48 && widget.height == 72,
          ),
        );
        final gap =
            tester.getTopLeft(nextCard).dy - tester.getBottomLeft(card).dy;
        expect(gap, AppSpace.sm);
        debugPrint(
          'CALENDAR_CARD view=$view color=0x${decoration.color!.toARGB32().toRadixString(16)} '
          'radius=$radius card=${tester.getSize(card)} '
          'progress=${tester.getSize(progress).width} poster=${tester.getSize(poster)} gap=$gap',
        );
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(boundaryKey),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1);
          try {
            expect(image.width, 1280);
            expect(image.height, 800);
            final png = await image.toByteData(format: ui.ImageByteFormat.png);
            if (png == null) throw StateError('Flutter 未返回 PNG 字节');
            final output = File('.local/calendar-final-$view.png');
            await output.parent.create(recursive: true);
            await output.writeAsBytes(
              png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
            );
          } finally {
            image.dispose();
          }
        });
      }
    }, skip: Platform.environment['CALENDAR_CAPTURE'] != '1');

    testWidgets('没有追番时给出空状态提示且不渲染网格', (tester) async {
      await pumpPage(tester);
      expect(
        find.byKey(const ValueKey('calendar-following-empty')),
        findsOneWidget,
      );
      expect(find.text('还没有追番，日历暂时没有内容'), findsOneWidget);
      expect(find.byKey(const ValueKey('calendar-grid')), findsNothing);
    });

    testWidgets('来源标记区分平台排期与本地推算', (tester) async {
      // 两部剧都钉在**今天正午**：DateTime(y,m,d,12) 只由年月日决定，无论当前
      // 几点都落在今天内，23:50 跑也不会像 `now + 1h` 那样跨到次日。
      // 页面默认选中今天，所以两条都应出现在当日列表里，无需再点格子。
      final noon = _todayNoonMs();

      // 本地推算：只有检查/更新时间，无 nextAirAtMs → 走降级分支。
      follow();
      state.database!.upsertFollowing(
        state.followings.single.copyWith(
          lastCheckedAtMs: noon,
          metadataUpdatedAtMs: noon,
        ),
      );

      // 真实播出：nextAirAtMs 落在今天正午（在可信窗口内）→ 归为 real。
      final item = state.followFromDetail(
        site: Site(
          key: 's2',
          name: '乙站',
          type: 4,
          api: 'http://127.0.0.1:1/vod',
        ),
        vod: Vod(vodId: 'v2', vodName: '第二部'),
        flag: '线路一',
        releasedEpisode: 8,
      )!;
      state.database!.upsertFollowing(
        item.copyWith(
          latestReleasedEpisode: 8,
          seasonReleasedEpisodes: 8,
          nextAirAtMs: noon,
          status: FollowingStatus.returning,
        ),
      );
      state.notifyListeners();
      await pumpPage(tester);

      expect(find.text('本地推算'), findsOneWidget);
      expect(find.text('平台排期'), findsOneWidget);
    });
  });
}
