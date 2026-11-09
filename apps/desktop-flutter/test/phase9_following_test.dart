import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/following.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/following_progress_service.dart';
import 'package:webhtv_pc/services/following_service.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/notification_service.dart';
import 'package:webhtv_pc/services/storage.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/following_page.dart';
import 'package:webhtv_pc/ui/theme.dart';

Following _item({
  int released = 0,
  int watched = 0,
  int read = 0,
  int notified = 0,
  String status = FollowingStatus.returning,
}) => Following(
  seriesKey: followingSeriesKey('s', 'v'),
  season: 0,
  siteKey: 's',
  vodId: 'v',
  vodName: '测试剧',
  flag: '线路一',
  sourceFlag: '线路一',
  trackedSeason: 0,
  latestReleasedSeason: 0,
  latestReleasedEpisode: released,
  seasonReleasedEpisodes: released,
  watchedEpisode: watched,
  readWatermarkEpisode: read,
  lastNotifiedEpisode: notified,
  status: status,
  createdAtMs: 1,
  updatedAtMs: 1,
);

void main() {
  group('追番身份与调度（P2-1）', () {
    test('身份键与安卓同格式', () {
      expect(
        followingSeriesKey('SiteA', 'VOD-1'),
        'source:0:sitea:vod-1',
      );
      expect(
        followingIdentityKey('source:0:sitea:vod-1', 2),
        'source:0:sitea:vod-1:s2',
      );
      expect(followingIdentityKey('source:0:a:b', -1), 'source:0:a:b:s0');
    });

    test('调度：连载 6h / 未开播 24h / 完结 7d / 前台 15m', () {
      final now = DateTime(2026, 10, 22, 9).millisecondsSinceEpoch;
      final returning = FollowingSchedule.nextCheckAt(
        nowMs: now,
        status: FollowingStatus.returning,
        nextAirAtMs: 0,
      );
      expect(returning - now, const Duration(hours: 6).inMilliseconds);

      final planned = FollowingSchedule.nextCheckAt(
        nowMs: now,
        status: FollowingStatus.planned,
        nextAirAtMs: 0,
      );
      expect(planned - now, const Duration(hours: 24).inMilliseconds);

      final ended = FollowingSchedule.nextCheckAt(
        nowMs: now,
        status: FollowingStatus.ended,
        nextAirAtMs: 0,
      );
      expect(ended - now, const Duration(days: 7).inMilliseconds);

      final foreground = FollowingSchedule.nextCheckAt(
        nowMs: now,
        status: FollowingStatus.returning,
        nextAirAtMs: 0,
        foreground: true,
      );
      expect(foreground - now, const Duration(minutes: 15).inMilliseconds);
    });

    test('首播时间后 30 分钟追一次；已过期按 1h 后', () {
      final now = DateTime(2026, 10, 22, 9).millisecondsSinceEpoch;
      final airAt = now + const Duration(minutes: 10).inMilliseconds;
      final fromAir = FollowingSchedule.nextCheckAt(
        nowMs: now,
        status: FollowingStatus.returning,
        nextAirAtMs: airAt,
      );
      // 首播后 30 分钟与「至少 1 小时后」取较晚者。
      expect(
        fromAir,
        now + FollowingSchedule.minOneShotAfterCheck.inMilliseconds,
      );

      final pastAir = FollowingSchedule.nextCheckAt(
        nowMs: now,
        status: FollowingStatus.returning,
        nextAirAtMs: now - 1000,
      );
      expect(
        pastAir,
        now + FollowingSchedule.minOneShotAfterCheck.inMilliseconds,
      );
    });

    test('失败退避：15m/30m/1h/2h/6h/1d', () {
      final now = DateTime(2026, 10, 22, 9).millisecondsSinceEpoch;
      final expected = <int, Duration>{
        1: const Duration(minutes: 15),
        2: const Duration(minutes: 30),
        3: const Duration(hours: 1),
        4: const Duration(hours: 2),
        5: const Duration(hours: 6),
        9: const Duration(days: 1),
      };
      for (final entry in expected.entries) {
        expect(
          FollowingSchedule.backoffAt(now, entry.key) - now,
          entry.value.inMilliseconds,
          reason: 'failure=${entry.key}',
        );
      }
    });
  });

  group('更新/通知策略（P2-1）', () {
    test('首次元数据不制造「新集」提示', () {
      final item = _item();
      final result = applyFollowingSnapshot(
        item,
        const FollowingSnapshot(
          status: FollowingStatus.returning,
          latestReleasedSeason: 0,
          latestReleasedEpisode: 10,
          seasonReleasedEpisodes: 10,
          seasonTotalEpisodes: 12,
          fetchedAtMs: 100,
        ),
        nowMs: 100,
      );
      expect(result.hasNewEpisode, isFalse);
      expect(result.following.readWatermarkEpisode, 10);
      // 首次拿到元数据只是建立水位基线，已看仍为 0：有未看集，但不算「新集」。
      expect(result.following.watchedEpisode, 0);
      expect(result.following.unwatchedCount, 10);
      expect(result.following.hasUpdate, isTrue);
      expect(shouldNotifyFollowing(result.following), isFalse);
    });

    test('已发布超过已看/已读 → 有更新；通知后不再提示', () {
      final item = _item(released: 10, watched: 8, read: 10, notified: 10);
      final result = applyFollowingSnapshot(
        item,
        const FollowingSnapshot(
          status: FollowingStatus.returning,
          latestReleasedSeason: 0,
          latestReleasedEpisode: 12,
          seasonReleasedEpisodes: 12,
          seasonTotalEpisodes: 12,
          fetchedAtMs: 100,
          latestEpisodeName: 'E12',
          latestEpisodeTarget: 'target-12',
        ),
        nowMs: 100,
      );
      expect(result.hasNewEpisode, isTrue);
      final updated = result.following;
      expect(updated.releasedEpisode, 12);
      expect(updated.hasUpdate, isTrue);
      expect(updated.unwatchedCount, 4);
      expect(shouldNotifyFollowing(updated), isTrue);
      expect(updated.latestEpisodeName, 'E12');
      expect(updated.latestEpisodeTarget, 'target-12');

      final notified = markFollowingNotified(updated, nowMs: 200);
      expect(shouldNotifyFollowing(notified), isFalse);

      final read = markFollowingRead(updated, nowMs: 300);
      // 已读水位只抑制新集提示，不再冒充已看：未看的 4 集还在。
      expect(read.readWatermarkEpisode, 12);
      expect(read.watchedEpisode, 8);
      expect(read.unwatchedCount, 4);
      expect(read.hasUpdate, isTrue);
      expect(shouldNotifyFollowing(read), isFalse);
    });

    test('集数回退不覆盖（max 单调）', () {
      final item = _item(released: 10, read: 10);
      final result = applyFollowingSnapshot(
        item,
        const FollowingSnapshot(
          status: FollowingStatus.returning,
          latestReleasedSeason: 0,
          latestReleasedEpisode: 8,
          seasonReleasedEpisodes: 8,
          seasonTotalEpisodes: 8,
          fetchedAtMs: 100,
        ),
        nowMs: 100,
      );
      expect(result.following.releasedEpisode, 10);
      expect(result.hasNewEpisode, isFalse);
    });

    test('失败写入计数、错误与退避时间', () {
      final failed = markFollowingFailure(
        _item(),
        error: 'HTTP 500',
        nowMs: 1000,
      );
      expect(failed.failureCount, 1);
      expect(failed.lastError, 'HTTP 500');
      expect(
        failed.nextCheckAtMs,
        1000 + const Duration(minutes: 15).inMilliseconds,
      );
    });

    test('设置夹取与 JSON 往返', () {
      final settings = FollowingSettings.defaults.copyWith(
        enabled: true,
        notifyEnabled: true,
        intervalMinutes: 5,
      );
      expect(settings.intervalMinutes, 15);
      expect(FollowingSettings.fromJson(settings.toJson()), settings);
      expect(
        FollowingSettings.fromJson({'intervalMinutes': 99999}).intervalMinutes,
        1440,
      );
    });

    test('Following JSON 往返（备份/同步）', () {
      final item = _item(released: 12, read: 10);
      final parsed = Following.tryParse(item.toJson());
      expect(parsed, isNotNull);
      expect(parsed!.releasedEpisode, 12);
      expect(parsed.hasUpdate, isTrue);
    });
  });

  group('追番存储与服务（P2-1）', () {
    late AppDatabase db;
    late DateTime now;
    late List<FollowingLineEpisodes> lines;
    late Object? failure;
    late FollowingService service;

    setUp(() {
      db = AppDatabase.inMemory();
      now = DateTime(2026, 10, 22, 9);
      lines = const [
        FollowingLineEpisodes(
          flag: '线路一',
          sourceFlag: '线路一',
          episodeCount: 10,
          latestEpisodeName: 'E10',
          latestEpisodeTarget: 't10',
        ),
        FollowingLineEpisodes(
          flag: '线路二',
          sourceFlag: '线路二',
          episodeCount: 4,
        ),
      ];
      failure = null;
      service = FollowingService(
        database: db,
        resolveLines: (item) async {
          if (failure != null) throw StateError('$failure');
          return lines;
        },
        now: () => now,
      );
    });

    tearDown(() => db.dispose());

    test('添加：首次追番=未开始，且集数立即落库（不等首次检查）', () {
      final item = service.add(
        siteKey: 's',
        vodId: 'v',
        vodName: '测试剧',
        flag: '线路一',
        sourceFlag: '线路一',
        releasedEpisode: 10,
      );
      expect(item.readWatermarkEpisode, 10);
      expect(item.watchedEpisode, 0, reason: '首次追番一律未开始');
      // 刚追、尚未 check：`releasedEpisode` 就必须是真实集数，不能是 0。
      expect(item.latestReleasedEpisode, 10);
      expect(item.seasonReleasedEpisodes, 10);
      expect(item.releasedEpisode, 10, reason: '不能显示「已更新 0 集」');
      expect(item.unwatchedCount, 10);
      expect(item.hasUpdate, isTrue, reason: '有未看的发布集');
      expect(shouldNotifyFollowing(item), isFalse, reason: '刚追不提示新集');
      expect(service.all(), hasLength(1));
      expect(service.byVod('s', 'v')?.vodName, '测试剧');
      expect(service.byKey(item.seriesKey, 0)?.vodId, 'v');
    });

    test('检查：集数增加 → 有新集；按线路匹配而不是第一条', () async {
      final added = service.add(
        siteKey: 's',
        vodId: 'v',
        vodName: '测试剧',
        flag: '线路二',
        sourceFlag: '线路二',
        releasedEpisode: 4,
      );
      lines = const [
        FollowingLineEpisodes(
          flag: '线路一',
          sourceFlag: '线路一',
          episodeCount: 10,
        ),
        FollowingLineEpisodes(
          flag: '线路二',
          sourceFlag: '线路二',
          episodeCount: 6,
          latestEpisodeName: 'E6',
          latestEpisodeTarget: 't6',
        ),
      ];
      final outcome = await service.check(added);
      expect(outcome.ok, isTrue);
      expect(outcome.changed, isTrue);
      expect(outcome.following.releasedEpisode, 6);
      expect(outcome.following.hasUpdate, isTrue);
      expect(outcome.following.nextCheckAtMs, greaterThan(now.millisecondsSinceEpoch));
      expect(service.byVod('s', 'v')!.releasedEpisode, 6);
    });

    test('检查失败：不抛、写退避与错误', () async {
      final added = service.add(
        siteKey: 's',
        vodId: 'v',
        vodName: '测试剧',
        releasedEpisode: 1,
      );
      failure = 'HTTP 500';
      final outcome = await service.check(added);
      expect(outcome.ok, isFalse);
      expect(outcome.following.failureCount, 1);
      expect(outcome.following.lastError, contains('HTTP 500'));
      expect(
        outcome.following.nextCheckAtMs,
        now.millisecondsSinceEpoch + const Duration(minutes: 15).inMilliseconds,
      );
    });

    test('checkAll(onlyDue) 只检查到期条目，并发 1', () async {
      final a = service.add(
        siteKey: 's',
        vodId: 'v1',
        vodName: 'A',
        releasedEpisode: 1,
      );
      service.add(
        siteKey: 's',
        vodId: 'v2',
        vodName: 'B',
        releasedEpisode: 1,
      );
      db.upsertFollowing(
        a.copyWith(
          nextCheckAtMs: now.millisecondsSinceEpoch + 100000,
          metadataUpdatedAtMs: 1,
        ),
      );
      final summary = await service.checkAll(onlyDue: true);
      expect(summary.checked, 1, reason: '未到期的 v1 不应检查');
      expect(summary.changed, 1);
      expect(summary.failed, 0);
    });

    test('标记已读只压水位，不改已看', () {
      final added = service.add(
        siteKey: 's',
        vodId: 'v',
        vodName: '测试剧',
        releasedEpisode: 1,
      );
      // `check` 是异步；这里用同步路径直接构造有更新的项。
      final updated = added.copyWith(
        latestReleasedEpisode: 8,
        seasonReleasedEpisodes: 8,
        readWatermarkEpisode: 1,
      );
      db.upsertFollowing(updated);
      final read = service.markRead(updated);
      expect(read.readWatermarkEpisode, 8);
      expect(read.watchedEpisode, 0, reason: '已读水位不冒充已看');
      expect(read.unwatchedCount, 8);
      expect(read.hasUpdate, isTrue, reason: '8 集仍未看');
      expect(
        shouldNotifyFollowing(read),
        isFalse,
        reason: '水位仍然负责抑制新集提示',
      );
    });
  });

  group('播放历史 → 已看回写（已看口径修正）', () {
    late AppDatabase db;
    late FollowingService service;
    late FollowingProgressService progress;

    setUp(() {
      db = AppDatabase.inMemory();
      service = FollowingService(
        database: db,
        resolveLines: (item) async => const [],
        now: () => DateTime(2026, 10, 22, 9),
      );
      progress = FollowingProgressService(database: db);
    });

    tearDown(() => db.dispose());

    /// 写一条播放历史（`upsertHistory` 会按位置自动判定 `completed`）。
    void play({
      String flag = '线路一',
      required String episodeName,
      required int positionMs,
      int durationMs = 1000000,
    }) {
      db.upsertHistory(
        siteKey: 's',
        vodId: 'v',
        vodName: '测试剧',
        flag: flag,
        episodeName: episodeName,
        episodeId: '$flag/$episodeName',
        positionMs: positionMs,
        durationMs: durationMs,
        updatedAt: 1000,
      );
    }

    Following add({int releasedEpisode = 12, String flag = '线路一'}) =>
        service.add(
          siteKey: 's',
          vodId: 'v',
          vodName: '测试剧',
          flag: flag,
          sourceFlag: flag,
          releasedEpisode: releasedEpisode,
        );

    test('completed 的集算已看，取所有候选的最大集号', () {
      final item = add();
      play(episodeName: '第3集', positionMs: 999000);
      play(episodeName: '第1集', positionMs: 999000);
      final next = progress.syncOne(item);
      expect(next.watchedEpisode, 3);
      expect(next.unwatchedCount, 9);
      expect(db.followingByVod('s', 'v')!.watchedEpisode, 3);
    });

    test('未完成但进度 ≥ 0.95 也算已看，0.90 不算', () {
      final item = add();
      play(episodeName: '第5集', positionMs: 900000);
      play(episodeName: '第4集', positionMs: 960000);
      expect(progress.syncOne(item).watchedEpisode, 4);
    });

    test('只增不减：历史被清理后已看不回退', () {
      final item = add().copyWith(watchedEpisode: 8);
      db.upsertFollowing(item);
      play(episodeName: '第2集', positionMs: 999000);
      expect(progress.syncOne(item).watchedEpisode, 8);
      expect(db.followingByVod('s', 'v')!.watchedEpisode, 8);
    });

    test('集号解析失败的行跳过（不猜集号）', () {
      final item = add();
      play(episodeName: '特别篇：总集回顾', positionMs: 999000);
      play(episodeName: '预告', positionMs: 999000);
      expect(progress.syncOne(item).watchedEpisode, 0);
      expect(progress.syncOne(item).unwatchedCount, 12);
    });

    test('线路优先：flag 命中时只看该线路，命中不到才看全线路', () {
      final item = add(flag: '线路一');
      play(flag: '线路二', episodeName: '第9集', positionMs: 999000);
      play(flag: '线路一', episodeName: '第2集', positionMs: 999000);
      expect(progress.syncOne(item).watchedEpisode, 2);

      final otherLine = add(flag: '线路三');
      expect(
        progress.syncOne(otherLine).watchedEpisode,
        9,
        reason: '线路三没有历史 → 退回全线路',
      );
    });

    test('异常不抛：库不可用时安全返回、不推进', () {
      final broken = AppDatabase.inMemory();
      broken.dispose();
      final safe = FollowingProgressService(database: broken);
      expect(() => safe.syncAll(), returnsNormally);
      expect(safe.syncAll().updated, 0);
      final item = add();
      expect(safe.syncOne(item).watchedEpisode, 0);
    });
  });

  group('追番页（P2-1）', () {
    late Directory temp;
    late AppPaths paths;
    late AppState state;

    setUp(() async {
      temp = Directory.systemTemp.createTempSync('webhtv-following');
      paths = AppPaths.resolve(
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

    testWidgets('空态、卡片与更新徽标', (tester) async {
      tester.view.physicalSize = const Size(1100, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.dark),
          home: Scaffold(body: FollowingPage(state: state)),
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('following-empty')), findsOneWidget);

      final site = Site(
        key: 's',
        name: '甲站',
        type: 4,
        api: 'http://127.0.0.1:1/vod',
      );
      final item = state.followFromDetail(
        site: site,
        vod: Vod(vodId: 'v1', vodName: '测试剧'),
        flag: '线路一',
        sourceFlag: '线路一',
        releasedEpisode: 10,
      );
      expect(item, isNotNull);
      // 模拟发现两集新内容。
      state.database!.upsertFollowing(
        item!.copyWith(
          latestReleasedEpisode: 12,
          seasonReleasedEpisodes: 12,
        ),
      );
      state.notifyListeners();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.byKey(const ValueKey('following-list')), findsOneWidget);
      expect(find.text('测试剧'), findsOneWidget);
      // 未看 = 已发布 12 − 已看 0 = 12（水位 10 不参与）。
      final identityKey = followingIdentityKey(
        followingSeriesKey('s', 'v1'),
        0,
      );
      expect(
        find.byKey(ValueKey('following-badge-$identityKey')),
        findsOneWidget,
      );
      expect(
        find.byKey(ValueKey('following-unwatched-$identityKey')),
        findsOneWidget,
      );
      expect(find.text('12 集未看'), findsWidgets);
      expect(
        find.byKey(const ValueKey('following-update-summary')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('following-check-all')), findsOneWidget);
      expect(find.byKey(const ValueKey('following-auto')), findsOneWidget);
      expect(find.byKey(const ValueKey('following-interval')), findsOneWidget);
    });
  });

  group('追番默认开启与间隔（P2-1 增强）', () {
    late Directory temp;
    late AppPaths paths;

    AppState newState({FollowingNotifier? notifier}) => AppState(
      paths: paths,
      log: LogService(),
      followingNotifier: notifier,
    );

    setUp(() {
      temp = Directory.systemTemp.createTempSync('webhtv-following-default');
      paths = AppPaths.resolve(
        overrides: {
          'config': '${temp.path}${Platform.pathSeparator}config',
          'data': '${temp.path}${Platform.pathSeparator}data',
          'cache': '${temp.path}${Platform.pathSeparator}cache',
          'state': '${temp.path}${Platform.pathSeparator}logs',
        },
      );
    });

    tearDown(() {
      try {
        temp.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('从未设置 → 自动检查默认开启且调度定时器生效', () async {
      final state = newState();
      await state.bootstrap();
      addTearDown(state.dispose);

      expect(state.followingSettings.enabled, isTrue);
      expect(state.followingSettings.intervalMinutes, 360);
      expect(state.followingAutoCheckActive, isTrue);
    });

    test('显式关闭 → 重启应用后仍保持关闭', () async {
      final first = newState();
      await first.bootstrap();
      await first.setFollowingSettings(
        first.followingSettings.copyWith(enabled: false),
      );
      expect(first.followingSettings.enabled, isFalse);
      expect(first.followingAutoCheckActive, isFalse);
      first.dispose();

      final second = newState();
      await second.bootstrap();
      addTearDown(second.dispose);
      expect(second.followingSettings.enabled, isFalse);
      expect(second.followingAutoCheckActive, isFalse);
    });

    test('间隔设置：持久化、夹取 15–1440 与文案', () async {
      final first = newState();
      await first.bootstrap();
      await first.setFollowingSettings(
        first.followingSettings.copyWith(intervalMinutes: 30),
      );
      expect(first.followingSettings.intervalLabel, '每 30 分钟');
      first.dispose();

      final second = newState();
      await second.bootstrap();
      addTearDown(second.dispose);
      expect(second.followingSettings.intervalMinutes, 30);
      expect(
        second.followingSettings.copyWith(intervalMinutes: 5).intervalMinutes,
        15,
      );
      expect(
        second.followingSettings.copyWith(intervalMinutes: 5000).intervalMinutes,
        1440,
      );
      expect(FollowingSettings.formatInterval(360), '每 6 小时');
      expect(FollowingSettings.formatInterval(90), '每 90 分钟');
    });

    test('TMDB 季服务只读访问器：数据库就绪后非空', () async {
      final state = newState();
      await state.bootstrap();
      addTearDown(state.dispose);

      expect(state.tmdbSeasonService, isNotNull);
      expect(identical(state.tmdbSeasonService, state.tmdbSeasonService), isTrue);
    });
  });

  group('追番已看回写接线（AppState）', () {
    late Directory temp;
    late AppPaths paths;
    late AppState state;

    setUp(() async {
      temp = Directory.systemTemp.createTempSync('webhtv-following-progress');
      paths = AppPaths.resolve(
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

    test('列表/日历读取前的刷新路径会按播放历史回写已看', () async {
      final site = Site(
        key: 's',
        name: '甲站',
        type: 4,
        api: 'http://127.0.0.1:1/vod',
      );
      final item = state.followFromDetail(
        site: site,
        vod: Vod(vodId: 'v1', vodName: '测试剧'),
        flag: '线路一',
        sourceFlag: '线路一',
        releasedEpisode: 10,
      )!;
      expect(item.watchedEpisode, 0, reason: '刚追 = 未开始');
      expect(item.releasedEpisode, 10, reason: '集数在追番时就已经落库');

      state.database!.upsertHistory(
        siteKey: 's',
        vodId: 'v1',
        vodName: '测试剧',
        flag: '线路一',
        episodeName: '第6集',
        episodeId: 'e6',
        positionMs: 999000,
        durationMs: 1000000,
        updatedAt: 1000,
      );

      final result = state.syncFollowingProgress();
      expect(result.updated, 1);
      final synced = state.followings.single;
      expect(synced.watchedEpisode, 6);
      expect(synced.unwatchedCount, 4);
      expect(synced.readWatermarkEpisode, 10, reason: '水位不受已看回写影响');
    });

    test('未读更新计数：刚追静默，已看不代替消息确认', () async {
      final site = Site(
        key: 's',
        name: '甲站',
        type: 4,
        api: 'http://127.0.0.1:1/vod',
      );
      final item = state.followFromDetail(
        site: site,
        vod: Vod(vodId: 'v1', vodName: '测试剧'),
        flag: '线路一',
        sourceFlag: '线路一',
        releasedEpisode: 10,
      )!;
      expect(state.followingUpdateCount, 0, reason: '刚追建立已读基线，卡片仍未看10集');
      expect(item.unwatchedCount, 10);
      state.database!.upsertFollowing(item.copyWith(
        latestReleasedEpisode: 12, seasonReleasedEpisodes: 12));
      expect(state.followingUpdateCount, 1, reason: '发现未读更新');

      // 播放到第10集：播放历史只推进已看，不确认新消息。
      for (final episode in ['第9集', '第10集']) {
        state.database!.upsertHistory(
          siteKey: 's',
          vodId: 'v1',
          vodName: '测试剧',
          flag: '线路一',
          episodeName: episode,
          episodeId: 'e-$episode',
          positionMs: 999000,
          durationMs: 1000000,
          updatedAt: 1000,
        );
      }
      state.syncFollowingProgress(items: [item]);
      final done = state.followings.single;
      expect(done.watchedEpisode, 10);
      expect(done.unwatchedCount, 2);
      expect(state.followingUpdateCount, 1, reason: '播放历史不代替已读');

      // 标记已读清除红点，但不更改卡片未看口径。
      await state.markFollowingRead(done);
      expect(state.followingUpdateCount, 0);
    });
  });

  group('看了 → 历史 → 追番已看闭环', () {
    late Directory temp;
    late AppPaths paths;
    late AppState state;

    setUp(() async {
      temp = Directory.systemTemp.createTempSync('webhtv-following-loop');
      paths = AppPaths.resolve(
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

    Site site() => Site(
      key: 's',
      name: '甲站',
      type: 4,
      api: 'http://127.0.0.1:1/vod',
    );

    Following add({int releasedEpisode = 10}) => state.followFromDetail(
      site: site(),
      vod: Vod(vodId: 'v1', vodName: '测试剧'),
      flag: '线路一',
      sourceFlag: '线路一',
      releasedEpisode: releasedEpisode,
    )!;

    /// 走 AppState 真实播放写入路径（历史 + 单剧回写），并等它跑完。
    Future<void> play({
      required String episodeName,
      required int positionMs,
      int durationMs = 1000000,
    }) async {
      state.recordProgress(
        vod: Vod(vodId: 'v1', vodName: '测试剧'),
        flag: '线路一',
        episodeName: episodeName,
        episodeId: 'e-$episodeName',
        position: Duration(milliseconds: positionMs),
        duration: Duration(milliseconds: durationMs),
        siteKey: 's',
      );
      // 回写排在事件循环之后，等它落库再断言。
      await Future<void>.delayed(Duration.zero);
    }

    /// 直接读库：绕开 `followings` getter 的一次性补齐，证明是播放链路写进去的。
    Following stored() => state.database!.followingByVod('s', 'v1')!;

    test('播放历史写完后自动回写已看：未看集数减少、无需手动刷新', () async {
      final item = add();
      expect(item.watchedEpisode, 0);

      // 播到片尾（写入时即标 completed）。
      await play(episodeName: '第6集', positionMs: 999000);

      expect(stored().watchedEpisode, 6, reason: '播放历史反推已看到第 6 集');
      expect(stored().unwatchedCount, 4, reason: '未看 10 − 6 = 4');
      expect(state.followings.single.unwatchedCount, 4);
    });

    test('历史进度未达 95% 且未完成：不推进已看', () async {
      add();

      await play(episodeName: '第6集', positionMs: 500000);

      expect(stored().watchedEpisode, 0, reason: '半集不算看过');
      expect(stored().unwatchedCount, 10);
    });

    test('per-item 通知开关落库：重新读取仍为关闭，全局开关不变', () async {
      // 先把全局打开，让「条目初值」与「全局值」都是开，关闭才有意义。
      await state.setFollowingSettings(
        state.followingSettings.copyWith(notifyEnabled: true),
      );
      final item = add();
      expect(item.notifyEnabled, isTrue);

      await state.setFollowingNotifyEnabled(item, false);

      expect(stored().notifyEnabled, isFalse, reason: '落库后重新查库仍关闭');
      expect(state.followings.single.notifyEnabled, isFalse);
      expect(state.followingSettings.notifyEnabled, isTrue, reason: '全局开关不受影响');
    });

    test('标记已读只压水位：已看与未看不被改动', () async {
      add();
      await play(episodeName: '第6集', positionMs: 999000);
      expect(stored().watchedEpisode, 6);

      await state.markFollowingRead(state.followings.single);

      expect(stored().readWatermarkEpisode, 10, reason: '已读水位压到已发布集数');
      expect(stored().watchedEpisode, 6, reason: '已读不冒充已看');
      expect(stored().unwatchedCount, 4, reason: '未看集数不受已读影响');
    });
  });

  group('追番系统通知与降级（P2-1 增强）', () {
    Following updated({int released = 12, int notified = 10}) => Following(
      seriesKey: followingSeriesKey('s', 'v'),
      season: 0,
      siteKey: 's',
      vodId: 'v',
      vodName: '测试剧',
      latestReleasedEpisode: released,
      seasonReleasedEpisodes: released,
      watchedEpisode: notified,
      readWatermarkEpisode: notified,
      lastNotifiedEpisode: notified,
      status: FollowingStatus.returning,
      notifyEnabled: true,
      createdAtMs: 1,
      updatedAtMs: 1,
    );

    test('初始化失败 → 降级为应用内提示，不抛错', () async {
      final platform = _FakeSystemNotifier(initOk: false);
      final notifier = FollowingNotifier(platform: platform);

      final batch = await notifier.notifyNewEpisodes([updated()]);

      expect(batch.delivered, 0);
      expect(batch.hasDegraded, isTrue);
      expect(batch.degraded.single, contains('测试剧'));
      expect(batch.notice, contains('系统通知不可用'));
      expect(batch.notice, contains('应用内提示'));
      expect(notifier.systemAvailable, isFalse);
      expect(notifier.degradedReason, contains('初始化失败'));
      expect(platform.shown, isEmpty);
    });

    test('发送失败 / 发送抛错 → 同样降级且不中断', () async {
      final failing = FollowingNotifier(
        platform: _FakeSystemNotifier(showOk: false),
      );
      final failedBatch = await failing.notifyNewEpisodes([updated()]);
      expect(failedBatch.delivered, 0);
      expect(failedBatch.notice, contains('发送失败'));

      final throwing = FollowingNotifier(
        platform: _FakeSystemNotifier(throwOnShow: true),
      );
      final thrownBatch = await throwing.notifyNewEpisodes([updated()]);
      expect(thrownBatch.delivered, 0);
      expect(thrownBatch.hasDegraded, isTrue);
      expect(throwing.systemAvailable, isTrue, reason: '初始化本身是成功的');
    });

    test('系统通知可用 → 标题含剧名、正文含新集信息', () async {
      final platform = _FakeSystemNotifier();
      final notifier = FollowingNotifier(platform: platform);

      final batch = await notifier.notifyNewEpisodes([updated()]);

      expect(batch.delivered, 1);
      expect(batch.notice, isEmpty, reason: '没降级就不该有应用内提示');
      expect(platform.shown.single['title'], contains('测试剧'));
      expect(platform.shown.single['body'], contains('第 12 集'));
      expect(platform.shown.single['payload'], updated().identityKey);
    });
  });
}

/// 记录调用的假平台实现：用来模拟「初始化/发送失败」。
class _FakeSystemNotifier implements SystemNotifier {
  _FakeSystemNotifier({
    this.initOk = true,
    this.showOk = true,
    this.throwOnShow = false,
  });

  final bool initOk;
  final bool showOk;
  final bool throwOnShow;
  final List<Map<String, String>> shown = [];

  @override
  Future<bool> initialize() async => initOk;

  @override
  Future<bool> show({
    required int id,
    required String title,
    required String body,
    String? payload,
  }) async {
    if (throwOnShow) throw StateError('通知通道不可用');
    if (!showOk) return false;
    shown.add({'title': title, 'body': body, 'payload': payload ?? ''});
    return true;
  }
}
