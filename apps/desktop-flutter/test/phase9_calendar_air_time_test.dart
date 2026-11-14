import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/following.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/tmdb_media.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/following_air_time_service.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/following_calendar_page.dart';
import 'package:webhtv_pc/ui/theme.dart';

/// 一部测试追番（数据层 `season` 恒为 0 基下标）。
Following _following({
  String siteKey = 's',
  String vodId = 'v1',
  String vodName = '测试剧',
  int season = 0,
}) => Following(
  seriesKey: followingSeriesKey(siteKey, vodId),
  season: season,
  siteKey: siteKey,
  vodId: vodId,
  vodName: vodName,
);

/// 本地自然日 0 点的毫秒纪元（断言口径与生产代码一致）。
int _localDayMs(int year, int month, int day) =>
    DateTime(year, month, day).millisecondsSinceEpoch;

void main() {
  group('追番真实播出时间服务', () {
    /// 记录调用次数的假 TMDB：所有网络能力都由用例注入。
    late int resolveCalls;
    late int fetchCalls;

    setUp(() {
      resolveCalls = 0;
      fetchCalls = 0;
    });

    FollowingAirTimeService buildService({
      bool configured = true,
      int? tmdbId = 12345,
      List<TmdbEpisode>? episodes,
      Object? resolveError,
      Object? fetchError,
      Future<List<TmdbEpisode>> Function()? fetchOverride,
      Duration timeout = const Duration(seconds: 10),
    }) => FollowingAirTimeService(
      isConfigured: () => configured,
      resolveTmdbId: (item) async {
        resolveCalls++;
        if (resolveError != null) throw resolveError;
        return tmdbId;
      },
      fetchEpisodes: (id, seasonNumber) {
        fetchCalls++;
        if (fetchError != null) return Future.error(fetchError);
        if (fetchOverride != null) return fetchOverride();
        return Future.value(episodes ?? const []);
      },
      requestTimeout: timeout,
    );

    test('匹配命中 → 集号/季 0 基/本地 0 点毫秒', () async {
      late int requestedSeason;
      final service = FollowingAirTimeService(
        isConfigured: () => true,
        resolveTmdbId: (item) async => 12345,
        fetchEpisodes: (id, seasonNumber) async {
          requestedSeason = seasonNumber;
          return const [
            TmdbEpisode(number: 3, date: '2019-11-20'),
            TmdbEpisode(number: 4, date: '2019-11-27'),
          ];
        },
      );

      final items = [_following()];
      final airTimes = await service.airTimesFor(items);

      // 数据层 season=0（0 基）→ 请求 TMDB 的 1 基季号 1。
      expect(requestedSeason, 1);
      expect(airTimes, hasLength(2));
      expect(airTimes[0].seriesKey, items[0].seriesKey);
      expect(airTimes[0].season, 0);
      expect(airTimes[0].episode, 3);
      expect(airTimes[0].airAtMs, _localDayMs(2019, 11, 20));
      expect(airTimes[1].episode, 4);
      expect(airTimes[1].airAtMs, _localDayMs(2019, 11, 27));
      // 空/非法日期被过滤，不影响其它集。
      expect(
        airTimes.every((it) => it.identityKey == items[0].identityKey),
        isTrue,
      );
    });

    test('空/非法 date 被过滤掉', () async {
      final service = buildService(
        episodes: const [
          TmdbEpisode(number: 1, date: ''),
          TmdbEpisode(number: 2, date: '2019-02-30'),
          TmdbEpisode(number: 3, date: 'not-a-date'),
          TmdbEpisode(number: 4, date: '2019-12-01'),
        ],
      );
      final airTimes = await service.airTimesFor([_following()]);
      expect(airTimes.map((it) => it.episode), [4]);
    });

    test('集标题来自同一份取集结果：命中集带集名，缺失集留空', () async {
      final service = buildService(
        episodes: const [
          TmdbEpisode(number: 3, title: '决斗之夜', date: '2019-11-20'),
          TmdbEpisode(number: 4, date: '2019-11-27'),
          TmdbEpisode(number: 5, title: '  ', date: '2019-12-04'),
        ],
      );
      final airTimes = await service.airTimesFor([_following()]);
      expect(airTimes.map((it) => it.episodeTitle).toList(), [
        '决斗之夜',
        '',
        '',
      ]);
      // 不额外发请求：一次取集就够。
      expect(fetchCalls, 1);
      expect(resolveCalls, 1);
    });

    test('TMDB 未配置 → 空结果且零请求', () async {
      final service = buildService(configured: false);
      final airTimes = await service.airTimesFor([_following()]);
      expect(airTimes, isEmpty);
      expect(resolveCalls, 0);
      expect(fetchCalls, 0);
    });

    test('请求抛错 → 空结果、不抛、写负缓存', () async {
      final service = buildService(fetchError: Exception('boom'));
      expect(await service.airTimesFor([_following()]), isEmpty);
      expect(fetchCalls, 1);
      // 负缓存生效：第二次不再请求。
      expect(await service.airTimesFor([_following()]), isEmpty);
      expect(fetchCalls, 1);
    });

    test('请求超时 → 空结果、不抛、写负缓存', () async {
      final pending = Completer<List<TmdbEpisode>>();
      final service = buildService(
        fetchOverride: () => pending.future,
        timeout: const Duration(milliseconds: 20),
      );
      expect(await service.airTimesFor([_following()]), isEmpty);
      expect(fetchCalls, 1);
      expect(
        await service.airTimesFor([_following()]),
        isEmpty,
        reason: '超时同样计入负缓存',
      );
      expect(fetchCalls, 1);
      pending.complete(const []);
    });

    test('成功结果缓存 → 第二次不重复请求', () async {
      final service = buildService(
        episodes: const [TmdbEpisode(number: 1, date: '2020-01-02')],
      );
      final items = [_following()];
      final first = await service.airTimesFor(items);
      expect(first, hasLength(1));
      final second = await service.airTimesFor(items);
      expect(second, hasLength(1));
      expect(resolveCalls, 1);
      expect(fetchCalls, 1);
    });

    test('无 tmdbId 匹配 → 跳过该剧，其余照常产出', () async {
      final service = FollowingAirTimeService(
        isConfigured: () => true,
        resolveTmdbId: (item) async => item.vodId == 'matched' ? 999 : null,
        fetchEpisodes: (id, seasonNumber) async => const [
          TmdbEpisode(number: 7, date: '2021-03-04'),
        ],
      );
      final airTimes = await service.airTimesFor([
        _following(vodId: 'missing', vodName: '未匹配剧'),
        _following(vodId: 'matched', vodName: '已匹配剧'),
      ]);
      expect(airTimes, hasLength(1));
      expect(airTimes.single.episode, 7);
      expect(airTimes.single.seriesKey, followingSeriesKey('s', 'matched'));
    });

    test('有 TMDB 数据 → 官方总集数等于该季剧集数，season 为 0 基', () async {
      final service = buildService(
        episodes: const [
          TmdbEpisode(number: 1, date: '2019-11-20'),
          TmdbEpisode(number: 2, date: ''),
          TmdbEpisode(number: 3, date: '2019-12-04'),
        ],
      );
      final items = [_following(season: 2)];

      final totals = await service.seasonTotalsFor(items);

      // 总数取 TMDB 该季剧集条数，含 date 缺失的那一集；季号沿用数据层 0 基。
      expect(totals, hasLength(1));
      expect(totals.single.totalEpisodes, 3);
      expect(totals.single.season, 2);
      expect(totals.single.seriesKey, items.single.seriesKey);
      expect(totals.single.identityKey, '${items.single.seriesKey}:s2');
    });

    test('取总集数：TMDB 未配置 → 空结果且零请求', () async {
      final service = buildService(configured: false);
      expect(await service.seasonTotalsFor([_following()]), isEmpty);
      expect(resolveCalls, 0);
      expect(fetchCalls, 0);
    });

    test('取总集数：请求抛错 → 空结果、不抛、写负缓存', () async {
      final service = buildService(fetchError: Exception('boom'));
      expect(await service.seasonTotalsFor([_following()]), isEmpty);
      expect(fetchCalls, 1);
      expect(
        await service.seasonTotalsFor([_following()]),
        isEmpty,
        reason: '负缓存生效：第二次不再请求',
      );
      expect(fetchCalls, 1);
    });

    test('取总集数：请求超时 → 空结果、不抛、写负缓存', () async {
      final pending = Completer<List<TmdbEpisode>>();
      final service = buildService(
        fetchOverride: () => pending.future,
        timeout: const Duration(milliseconds: 20),
      );
      expect(await service.seasonTotalsFor([_following()]), isEmpty);
      expect(fetchCalls, 1);
      expect(await service.seasonTotalsFor([_following()]), isEmpty);
      expect(fetchCalls, 1);
      pending.complete(const []);
    });

    test('总集数与播出时间共享同一次请求', () async {
      final service = buildService(
        episodes: const [
          TmdbEpisode(number: 1, date: '2019-11-20'),
          TmdbEpisode(number: 2, date: '2019-11-27'),
        ],
      );
      final items = [_following()];

      // 合并接口：一次调用同时拿到两者，且只发一次取集请求。
      final result = await service.resolveFor(items);
      expect(result.airTimes, hasLength(2));
      expect(result.seasonTotals.single.totalEpisodes, 2);
      expect(fetchCalls, 1);

      // 分开调用也命中同一份缓存：不新增请求。
      expect(await service.airTimesFor(items), hasLength(2));
      expect(await service.seasonTotalsFor(items), hasLength(1));
      expect(resolveCalls, 1);
      expect(fetchCalls, 1);
    });
  });

  group('追剧日历接入真实播出时间', () {
    late Directory temp;
    late AppState state;

    setUp(() async {
      temp = Directory.systemTemp.createTempSync('webhtv-calendar-air');
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

    testWidgets('注入 airTimes 后条目落在排期日并显示「平台排期」', (tester) async {
      final today = DateTime.now();
      final airDay = DateTime(today.year, today.month, today.day);
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
        releasedEpisode: 12,
      )!;
      state.database!.upsertFollowing(
        item.copyWith(
          latestReleasedEpisode: 12,
          seasonReleasedEpisodes: 12,
          watchedEpisode: 12,
          readWatermarkEpisode: 12,
          status: FollowingStatus.returning,
        ),
      );
      // 注入假服务：真实播出时间是今天第 5 集，绝不发真实网络请求。
      state.attachFollowingAirTimeService(
        FollowingAirTimeService(
          isConfigured: () => true,
          resolveTmdbId: (following) async => 4242,
          fetchEpisodes: (id, seasonNumber) async => [
            TmdbEpisode(
              number: 5,
              date:
                  '${airDay.year}-${airDay.month.toString().padLeft(2, '0')}'
                  '-${airDay.day.toString().padLeft(2, '0')}',
            ),
          ],
        ),
      );
      state.notifyListeners();

      tester.view.physicalSize = const Size(1100, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.dark),
          home: Scaffold(body: FollowingCalendarPage(state: state)),
        ),
      );
      // 第一次 pump 触发异步加载，第二次 pump 渲染加载结果。
      await tester.pump();
      await tester.pump();

      expect(
        find.byKey(ValueKey('calendar-entry-${item.identityKey}-S01E05')),
        findsOneWidget,
      );
      expect(find.text('平台排期'), findsOneWidget);
      expect(find.text('本地推算'), findsNothing);
      // 一集一条：集号是 `S01E05`（两位补齐），不再是区间文案。
      expect(find.text('S01E05'), findsOneWidget);
      // 真实播出日当天有圆点。
      expect(
        find.byKey(
          ValueKey('calendar-dot-${airDay.year}-${airDay.month}-${airDay.day}'),
        ),
        findsOneWidget,
      );
    });
  });
}
