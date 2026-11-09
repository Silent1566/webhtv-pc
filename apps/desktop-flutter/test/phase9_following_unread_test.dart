import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:webhtv_pc/core/following.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/following_progress_service.dart';
import 'package:webhtv_pc/services/following_service.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/notification_service.dart';
import 'package:webhtv_pc/services/storage.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/app.dart';
import 'package:webhtv_pc/ui/browse_pages.dart';
import 'package:webhtv_pc/ui/player_page.dart';
import 'package:webhtv_pc/ui/theme.dart';
import 'package:webhtv_pc/ui/toast.dart';

import 'support/player_page_harness.dart'
    show installMediaKitMocks, installWindowManagerMocks;

Following _item() => Following(
  seriesKey: followingSeriesKey('s', 'v'),
  season: 0,
  siteKey: 's',
  vodId: 'v',
  vodName: '测试剧',
  flag: '线路一',
  sourceFlag: '线路一',
  latestReleasedEpisode: 2,
  seasonReleasedEpisodes: 2,
  readWatermarkEpisode: 1,
  lastNotifiedEpisode: 1,
  metadataUpdatedAtMs: 1,
  notifyEnabled: true,
);

const _lines = [
  FollowingLineEpisodes(
    flag: '线路一',
    sourceFlag: '线路一',
    episodeCount: 3,
    latestEpisodeName: '第3集',
    latestEpisodeTarget: 'target-3',
  ),
];

void _play(AppDatabase db, {int episode = 2}) => db.upsertHistory(
  siteKey: 's',
  vodId: 'v',
  vodName: '测试剧',
  flag: '线路一',
  episodeName: '第$episode集',
  episodeId: 'target-$episode',
  positionMs: 999000,
  durationMs: 1000000,
  updatedAt: 1000,
);

class _Client extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final query = request.url.queryParameters;
    final body = query.containsKey('play')
        ? {'parse': 0, 'url': 'http://127.0.0.1:1/test.mp4'}
        : {
            'class': [
              {'type_id': '1', 'type_name': '剧集'},
            ],
            'list': [
              {
                'vod_id': 'v',
                'vod_name': '测试剧',
                'vod_pic': '',
                'vod_play_from': '线路一',
                'vod_play_url': '第1集\$target-1#第2集\$target-2',
              },
            ],
          };
    return http.StreamedResponse(
      Stream.value(utf8.encode(jsonEncode(body))),
      200,
    );
  }
}

class _PendingNotifier implements SystemNotifier {
  final entered = Completer<void>();
  final result = Completer<bool>();
  @override
  Future<bool> initialize() async => true;
  @override
  Future<bool> show({
    required int id,
    required String title,
    required String body,
    String? payload,
  }) {
    entered.complete();
    return result.future;
  }
}

void main() {
  group('追番动作只合并最新行所属字段', () {
    late AppDatabase db;
    late FollowingService service;
    late Completer<List<FollowingLineEpisodes>?> resolver;
    setUp(() {
      db = AppDatabase.inMemory();
      resolver = Completer<List<FollowingLineEpisodes>?>();
      service = FollowingService(
        database: db,
        resolveLines: (_) => resolver.future,
      );
      db.upsertFollowing(_item());
    });
    tearDown(() => db.dispose());

    test('旧 item 设置开关不能覆盖新的已看和已读，比较最新开关', () {
      final stale = _item();
      db.upsertFollowing(
        stale.copyWith(
          watchedEpisode: 2,
          readWatermarkEpisode: 2,
          notifyEnabled: false,
        ),
      );
      service.setNotifyEnabled(stale, true);
      final stored = db.followings().single;
      expect(stored.notifyEnabled, isTrue);
      expect(stored.watchedEpisode, 2);
      expect(stored.readWatermarkEpisode, 2);
      service.setNotifyEnabled(stale, false);
      expect(db.followings().single.notifyEnabled, isFalse);
      expect(db.followings().single.watchedEpisode, 2);
      expect(db.followings().single.readWatermarkEpisode, 2);
    });

    test('旧 item 标读按最新发布集数并保留观看与开关', () {
      final stale = _item();
      db.upsertFollowing(
        stale.copyWith(
          latestReleasedEpisode: 4,
          seasonReleasedEpisodes: 4,
          watchedEpisode: 3,
          notifyEnabled: false,
        ),
      );
      service.markRead(stale);
      final stored = db.followings().single;
      expect(stored.readWatermarkEpisode, 4);
      expect(stored.watchedEpisode, 3);
      expect(stored.notifyEnabled, isFalse);
    });

    for (final fails in [false, true]) {
      test('check ${fails ? '失败' : '成功'}等待期间的notify/read/真实播放进度保留', () async {
        final stale = _item();
        final pending = service.check(stale);
        service.setNotifyEnabled(stale, false);
        service.markRead(db.followings().single);
        _play(db);
        FollowingProgressService(database: db)
            .syncVod(siteKey: 's', vodId: 'v');
        if (fails) {
          resolver.completeError(StateError('检查失败'));
        } else {
          resolver.complete(_lines);
        }
        final outcome = await pending;
        expect(outcome.ok, !fails);
        final stored = db.followings().single;
        expect(stored.notifyEnabled, isFalse);
        expect(stored.readWatermarkEpisode, 2);
        expect(stored.watchedEpisode, 2);
        expect(stored.releasedEpisode, fails ? 2 : 3);
      });
      test('check ${fails ? '失败' : '成功'}返回不重建期间已删除条目', () async {
        final stale = _item();
        final pending = service.check(stale);
        service.remove(stale);
        if (fails) {
          resolver.completeError(StateError('检查失败'));
        } else {
          resolver.complete(_lines);
        }
        await pending;
        expect(db.followings(), isEmpty);
      });
    }

    test('已删除条目的标读和开关动作不重新插入', () {
      final stale = _item();
      service.remove(stale);
      service.markRead(stale);
      service.setNotifyEnabled(stale, false);
      expect(db.followings(), isEmpty);
    });

    test('add→check→数据库重读持久化最新集名称与入口', () async {
      db.deleteFollowing(_item().seriesKey, 0);
      final added = service.add(
        siteKey: 's',
        vodId: 'v',
        vodName: '测试剧',
        flag: '线路一',
        releasedEpisode: 1,
      );
      final pending = service.check(added);
      resolver.complete(_lines);
      await pending;
      final stored = db.following(added.seriesKey, added.season)!;
      expect(stored.latestEpisodeName, '第3集');
      expect(stored.latestEpisodeTarget, 'target-3');
      expect(stored.releasedEpisode, 3);
    });
  });

  group('真实AppState通知发送的状态合并', () {
    late Directory temp;
    late AppState state;
    late _PendingNotifier platform;
    setUp(() async {
      temp = Directory.systemTemp.createTempSync('following-notify-race');
      platform = _PendingNotifier();
      state = AppState(
        paths: AppPaths.resolve(
          overrides: {'roaming': temp.path, 'local': temp.path},
        ),
        log: LogService(),
        httpClient: _Client(),
        followingNotifier: FollowingNotifier(platform: platform),
      );
      await state.bootstrap();
      await state.setFollowingSettings(
        state.followingSettings.copyWith(enabled: false, notifyEnabled: true),
      );
      await state.importConfig(
        jsonEncode({
          'sites': [
            {
              'key': 's',
              'name': '站点',
              'type': 4,
              'api': 'http://127.0.0.1:1/vod',
            },
          ],
        }),
      );
      state.database!.upsertFollowing(
        _item().copyWith(latestReleasedEpisode: 1, seasonReleasedEpisodes: 1),
      );
    });
    tearDown(() {
      dismissAllToasts();
      state.dispose();
      temp.deleteSync(recursive: true);
    });
    test('公共进度同步将旧items仅作为identity选择器，不覆盖最新状态或重建删除项', () async {
      final stale = state.database!.followings().single;
      state.database!.upsertFollowing(
        stale.copyWith(
          latestReleasedEpisode: 4,
          seasonReleasedEpisodes: 4,
          watchedEpisode: 3,
          readWatermarkEpisode: 4,
          notifyEnabled: false,
        ),
      );
      _play(state.database!);
      state.syncFollowingProgress(items: [stale]);
      final stored = state.database!.followings().single;
      expect(stored.watchedEpisode, 3);
      expect(stored.readWatermarkEpisode, 4);
      expect(stored.notifyEnabled, isFalse);
      expect(stored.releasedEpisode, 4);
      await state.unfollowFollowing(stored);
      state.syncFollowingProgress(items: [stale]);
      expect(state.database!.followings(), isEmpty);
    });

    test('发送通知只推进lastNotified，发送不等于已读', () async {
      final pending = state.checkFollowing(state.database!.followings().single);
      await platform.entered.future;
      platform.result.complete(true);
      await pending;
      final stored = state.database!.followings().single;
      expect(stored.lastNotifiedEpisode, 2);
      expect(stored.readWatermarkEpisode, 1);
      expect(stored.watchedEpisode, 0);
      expect(state.followingUpdateCount, 1);
      await state.markFollowingRead(stored);
      expect(state.followingUpdateCount, 0);
      expect(state.database!.followings().single.unwatchedCount, 2);
    });
    test('通知await期间新已读/观看/开关不被旧快照回盖', () async {
      final pending = state.checkFollowing(state.database!.followings().single);
      await platform.entered.future;
      final fresh = state.database!.followings().single;
      await state.markFollowingRead(fresh);
      await state.setFollowingNotifyEnabled(fresh, false);
      state.database!.upsertFollowing(
        state.database!.followings().single.copyWith(
          latestReleasedEpisode: 3,
          seasonReleasedEpisodes: 3,
          latestEpisodeName: '第3集',
          latestEpisodeTarget: 'target-3',
        ),
      );
      _play(state.database!);
      state.syncFollowingProgress();
      platform.result.complete(true);
      await pending;
      final stored = state.database!.followings().single;
      expect(stored.lastNotifiedEpisode, 2, reason: '只确认本次实际发送的集数');
      expect(stored.releasedEpisode, 3);
      expect(stored.latestEpisodeTarget, 'target-3');
      expect(stored.readWatermarkEpisode, 2);
      expect(stored.watchedEpisode, 2);
      expect(stored.notifyEnabled, isFalse);
    });
    test('通知await期间删除不被重新插入', () async {
      final stale = state.database!.followings().single;
      final pending = state.checkFollowing(stale);
      await platform.entered.future;
      await state.unfollowFollowing(stale);
      platform.result.complete(true);
      await pending;
      expect(state.database!.followings(), isEmpty);
    });
  });

  group('真实AppShell的未读红点与即时确认链路', () {
    late Directory temp;
    late AppState state;
    late Following item;
    String? notificationId;
    const notificationChannel = MethodChannel('local_notifier');
    setUp(() async {
      temp = Directory.systemTemp.createTempSync('following-unread-shell');
      state = AppState(
        paths: AppPaths.resolve(
          overrides: {'roaming': temp.path, 'local': temp.path},
        ),
        log: LogService(),
        httpClient: _Client(),
      );
      await state.bootstrap();
      await state.setFollowingSettings(
        state.followingSettings.copyWith(enabled: false, notifyEnabled: true),
      );
      await state.importConfig(
        jsonEncode({
          'sites': [
            {
              'key': 's',
              'name': '站点',
              'type': 4,
              'api': 'http://127.0.0.1:1/vod',
            },
          ],
        }),
      );
      File(
        '${state.paths.configDir}${Platform.pathSeparator}usage-boundary-accepted',
      ).writeAsStringSync('ok');
      item = state.followFromDetail(
        site: state.config!.sites.single,
        vod: Vod(vodId: 'v', vodName: '测试剧'),
        flag: '线路一',
        sourceFlag: '线路一',
        releasedEpisode: 1,
      )!;
      notificationId = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(notificationChannel, (call) async {
            if (call.method == 'setup') return true;
            if (call.method == 'notify') {
              notificationId = (call.arguments as Map)['identifier'] as String;
            }
            return null;
          });
    });
    tearDown(() {
      dismissAllToasts();
      state.dispose();
      temp.deleteSync(recursive: true);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(notificationChannel, null);
    });
    Following stored() =>
        state.database!.following(item.seriesKey, item.season)!;
    Future<void> pumpFrames(WidgetTester tester) async {
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 30));
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      }
    }

    Future<void> mount(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.dark),
          home: AppShell(state: state, startup: const StartupArguments()),
        ),
      );
      await pumpFrames(tester);
    }

    Future<void> openMenu(WidgetTester tester) async {
      await tester.tap(find.text('追番').first);
      await pumpFrames(tester);
      await tester.tap(
        find.byKey(ValueKey('following-menu-${item.identityKey}')),
      );
      await pumpFrames(tester);
    }

    void update() => state.database!.upsertFollowing(
      item.copyWith(
        latestReleasedEpisode: 2,
        seasonReleasedEpisodes: 2,
        metadataUpdatedAtMs: 1,
      ),
    );
    Badge sidebarBadge(WidgetTester tester) => tester.widget<Badge>(
      find.descendant(
        of: find.byType(NavigationRail),
        matching: find.byType(Badge),
      ),
    );

    testWidgets('未读1→真实菜单标读后0，侧栏红点隐藏且卡片未看不变', (tester) async {
      update();
      await mount(tester);
      expect(state.followingUpdateCount, 1);
      expect(sidebarBadge(tester).isLabelVisible, isTrue);
      expect((sidebarBadge(tester).label! as Text).data, '1');
      await openMenu(tester);
      await tester.tap(find.text('标为已读（仅清除提示）'));
      await pumpFrames(tester);
      expect(stored().readWatermarkEpisode, 2);
      expect(stored().watchedEpisode, 0);
      expect(stored().unwatchedCount, 2);
      expect(state.followingUpdateCount, 0);
      expect(sidebarBadge(tester).isLabelVisible, isFalse);
      expect(find.text('2 集未看'), findsWidgets);
    });

    testWidgets('从追番打开详情即时标读，不等待详情返回', (tester) async {
      update();
      await mount(tester);
      await openMenu(tester);
      await tester.tap(find.text('打开详情'));
      await pumpFrames(tester);
      expect(find.byType(DetailPage), findsOneWidget);
      expect(stored().readWatermarkEpisode, 2);
      expect(stored().watchedEpisode, 0);
      expect(state.followingUpdateCount, 0);
    });

    testWidgets('最新入口为空时卡片退详情仍即时标读', (tester) async {
      update();
      await mount(tester);
      await tester.tap(find.text('追番').first);
      await pumpFrames(tester);
      await tester.tap(
        find.byKey(ValueKey('following-card-${item.identityKey}')),
      );
      await pumpFrames(tester);
      expect(find.byType(DetailPage), findsOneWidget);
      expect(stored().readWatermarkEpisode, 2);
      expect(stored().watchedEpisode, 0);
    });

    testWidgets('追番播放最新集在播放器仍打开时已经标读', (tester) async {
      installMediaKitMocks(tester);
      installWindowManagerMocks(tester);
      state.database!.upsertFollowing(
        item.copyWith(
          latestReleasedEpisode: 2,
          seasonReleasedEpisodes: 2,
          metadataUpdatedAtMs: 1,
          latestEpisodeName: '第2集',
          latestEpisodeTarget: 'target-2',
        ),
      );
      await mount(tester);
      await tester.tap(find.text('追番').first);
      await pumpFrames(tester);
      await tester.tap(
        find.byKey(ValueKey('following-card-${item.identityKey}')),
      );
      await pumpFrames(tester);
      expect(find.byType(PlayerPage), findsOneWidget);
      expect(stored().readWatermarkEpisode, 2);
      expect(stored().watchedEpisode, 0);
      expect(state.followingUpdateCount, 0);
      await tester.pumpWidget(const SizedBox());
      await pumpFrames(tester);
    });

    testWidgets('真实系统通知点击即时已读，播放器路由未退出；返回只同步真实历史', (tester) async {
      installMediaKitMocks(tester);
      installWindowManagerMocks(tester);
      await mount(tester);
      final pending = state.checkFollowing(item);
      await pumpFrames(tester);
      await pending;
      expect(notificationId, isNotNull);
      state.database!.upsertFollowing(
        stored().copyWith(
          latestEpisodeName: '第2集',
          latestEpisodeTarget: 'target-2',
        ),
      );
      expect(stored().readWatermarkEpisode, 1, reason: '发送不算确认');
      expect(state.followingUpdateCount, 1);
      final clicked = tester.binding.defaultBinaryMessenger
          .handlePlatformMessage(
            'local_notifier',
            const StandardMethodCodec().encodeMethodCall(
              MethodCall('onLocalNotificationClick', {
                'notificationId': notificationId,
              }),
            ),
            (_) {},
          );
      await clicked;
      expect(stored().readWatermarkEpisode, 2, reason: '点击消息即确认，不等待导航/播放返回');
      await pumpFrames(tester);
      expect(find.byType(PlayerPage), findsOneWidget);
      expect(stored().readWatermarkEpisode, 2, reason: '播放器仍打开');
      expect(stored().watchedEpisode, 0);
      final current = stored();
      state.database!.upsertFollowing(
        current.copyWith(
          latestReleasedEpisode: 3,
          seasonReleasedEpisodes: 3,
          notifyEnabled: false,
        ),
      );
      _play(state.database!);
      Navigator.of(tester.element(find.byType(PlayerPage))).pop();
      await pumpFrames(tester);
      expect(stored().releasedEpisode, 3);
      expect(stored().readWatermarkEpisode, 2, reason: '退出播放不能把未确认的新消息一并标读');
      expect(stored().watchedEpisode, 2);
      expect(stored().notifyEnabled, isFalse);
      expect(state.followingUpdateCount, 1);
      await tester.pumpWidget(const SizedBox());
      await pumpFrames(tester);
    });
  });
}
