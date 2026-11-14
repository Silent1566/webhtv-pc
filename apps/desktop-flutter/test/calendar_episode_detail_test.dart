import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/following.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/tmdb_config.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/core/tmdb_media.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/following_air_time_service.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/tmdb_stores.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/following_calendar_page.dart';
import 'package:webhtv_pc/ui/theme.dart';

void main() {
  late Directory temp;
  late AppState state;
  late List<Uri> requests;
  late Future<http.Response> Function(http.Request) respond;
  late String date;

  http.Response jsonResponse(Object data, {int status = 200}) => http.Response(
    jsonEncode(data),
    status,
    headers: {'content-type': 'application/json'},
  );

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('calendar-episode-detail');
    requests = [];
    final today = DateTime.now();
    date =
        '${today.year}-${today.month.toString().padLeft(2, '0')}-'
        '${today.day.toString().padLeft(2, '0')}';
    respond = (request) async {
      if (request.url.path.endsWith('/search/multi')) {
        return jsonResponse({'results': []});
      }
      if (request.url.path.endsWith('/videos')) {
        return jsonResponse({'results': []});
      }
      if (request.url.path.endsWith('/episode/9')) {
        return jsonResponse({
          'id': 9009,
          'episode_number': 9,
          'season_number': 1,
          'name': '旧集网络详情标题',
          'air_date': date,
          'overview': '只有旧集的完整剧情',
          'runtime': 44,
          'vote_average': 8.1,
          'credits': {'cast': [], 'crew': [], 'guest_stars': []},
          'images': {'stills': []},
          'translations': {'translations': []},
        });
      }
      throw StateError('未约定的 HTTP 请求：${request.url}');
    };
    final client = MockClient((request) {
      requests.add(request.url);
      return respond(request);
    });
    await http.runWithClient(() async {
      state = AppState(
        paths: AppPaths.resolve(
          overrides: {
            'config': '${temp.path}/config',
            'data': '${temp.path}/data',
            'cache': '${temp.path}/cache',
            'state': '${temp.path}/logs',
          },
        ),
        log: LogService(),
      );
      await state.bootstrap();
    }, () => client);
  });

  tearDown(() {
    state.dispose();
    temp.deleteSync(recursive: true);
  });

  Future<void> configure() async {
    expect(
      await state.saveTmdbConfig(
        const TmdbConfig(apiBase: 'http://127.0.0.1:1/3', apiKey: 'local-fake'),
      ),
      isTrue,
    );
  }

  void saveMatch({TmdbMediaType type = TmdbMediaType.tv}) {
    DatabaseTmdbMatchStore(
      database: state.database!,
      configId: state.tmdbConfigId,
    ).putAuto(
      siteKey: 's',
      vodId: 'v1',
      sourceTitle: '测试剧',
      matchedAt: 1,
      item: TmdbItem(tmdbId: 4242, mediaType: type, title: '测试剧'),
    );
  }

  Future<String> pumpCalendar(
    WidgetTester tester, {
    int released = 10,
    bool airTimes = true,
  }) async {
    final item = state.followFromDetail(
      site: Site(key: 's', name: '甲站', type: 4, api: 'http://127.0.0.1:1/vod'),
      vod: Vod(vodId: 'v1', vodName: '测试剧'),
      flag: '线路一',
      releasedEpisode: released,
    )!;
    state.database!.upsertFollowing(
      item.copyWith(
        watchedEpisode: 0,
        status: FollowingStatus.returning,
        latestEpisodeName: '最新源第10集',
        latestEpisodeTarget: 'http://127.0.0.1:1/latest.mp4',
      ),
    );
    state.attachFollowingAirTimeService(
      FollowingAirTimeService(
        isConfigured: () => airTimes,
        resolveTmdbId: (_) async => 4242,
        fetchEpisodes: (id, season) async {
          expect(id, 4242);
          expect(season, 1, reason: '既有排期服务对 season=0 请求 TMDB season=1');
          return [
            TmdbEpisode(number: 9, title: '旧集完整标题', date: date),
            TmdbEpisode(number: 10, title: '最新元数据标题', date: date),
          ];
        },
      ),
    );
    tester.view.physicalSize = const Size(1100, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.dark),
        home: Scaffold(body: FollowingCalendarPage(state: state)),
      ),
    );
    await tester.pumpAndSettle();
    return item.identityKey;
  }

  Finder entry(String identity, [String code = 'S01E09']) =>
      find.byKey(ValueKey('calendar-entry-$identity-$code'));
  Finder inDetails(Finder matching) => find.descendant(
    of: find.byKey(const ValueKey('tmdb-episode-details')),
    matching: matching,
  );

  testWidgets('长按旧集打开详情，不播放、不标已看、不跳站点', (tester) async {
    final identity = await pumpCalendar(tester);
    final selected = state.selectedSite;
    final detailState = state.tmdb;
    final generation = detailState.generation;
    await tester.longPress(entry(identity));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('tmdb-episode-details')),
      findsOneWidget,
      reason: '日历条目必须注册长按并打开当集共享详情',
    );
    expect(inDetails(find.text('旧集完整标题')), findsOneWidget);
    expect(inDetails(find.textContaining('S1E9')), findsOneWidget);
    expect(inDetails(find.textContaining(date)), findsOneWidget);
    expect(inDetails(find.textContaining('最新')), findsNothing);
    expect(state.followings.single.watchedEpisode, 0);
    expect(state.selectedSite, same(selected));
    expect(state.recentHistory(sourceKey: ''), isEmpty);
    expect(state.tmdb, same(detailState));
    expect(detailState.generation, generation);
    expect(detailState.detail, isNull);
    expect(requests, isEmpty, reason: '缺配置仍展示基础详情且零 HTTP');
    expect(tester.takeException(), isNull);
  });

  testWidgets('存储匹配优先，旧集请求 S1E9 而非最新 E10', (tester) async {
    await tester.runAsync(configure);
    saveMatch();
    final identity = await pumpCalendar(tester);
    await tester.longPress(entry(identity));
    await tester.pumpAndSettle();
    expect(inDetails(find.text('只有旧集的完整剧情')), findsOneWidget);
    expect(
      requests.any((uri) => uri.path == '/3/tv/4242/season/1/episode/9'),
      isTrue,
    );
    expect(requests.any((uri) => uri.path.contains('/episode/10')), isFalse);
    expect(
      requests.any((uri) => uri.path.endsWith('/search/multi')),
      isFalse,
      reason: '已存储身份不应重新搜索',
    );
    expect(state.followings.single.watchedEpisode, 0);
    expect(state.recentHistory(sourceKey: ''), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('身份请求未完成前就显示基础弹窗，无匹配仍保留旧集', (tester) async {
    await tester.runAsync(configure);
    final pending = Completer<http.Response>();
    respond = (_) => pending.future;
    final identity = await pumpCalendar(tester);
    await tester.longPress(entry(identity));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byKey(const ValueKey('tmdb-episode-details')), findsOneWidget);
    expect(inDetails(find.text('旧集完整标题')), findsOneWidget);
    expect(requests, isNotEmpty);
    pending.complete(jsonResponse({'results': []}));
    await tester.pumpAndSettle();
    expect(inDetails(find.text('旧集完整标题')), findsOneWidget);
    expect(inDetails(find.textContaining('S1E9')), findsOneWidget);
    expect(state.followings.single.watchedEpisode, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('详情网络失败保留当集基础标题、集号和日期', (tester) async {
    await tester.runAsync(configure);
    saveMatch();
    respond = (_) async =>
        jsonResponse({'status_message': 'local failure'}, status: 500);
    final identity = await pumpCalendar(tester);
    await tester.longPress(entry(identity));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tmdb-episode-details')), findsOneWidget);
    expect(inDetails(find.text('旧集完整标题')), findsOneWidget);
    expect(inDetails(find.textContaining('S1E9')), findsOneWidget);
    expect(inDetails(find.textContaining(date)), findsOneWidget);
    expect(requests.any((uri) => uri.path.endsWith('/episode/9')), isTrue);
    expect(state.followings.single.watchedEpisode, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('集号未知不编造 E0，不请求当集元数据', (tester) async {
    await tester.runAsync(configure);
    saveMatch();
    final identity = await pumpCalendar(tester, released: 0, airTimes: false);
    await tester.longPress(entry(identity, 'S01'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tmdb-episode-details')), findsOneWidget);
    expect(inDetails(find.textContaining('测试剧')), findsWidgets);
    expect(inDetails(find.textContaining('E0')), findsNothing);
    expect(inDetails(find.textContaining('最新源')), findsNothing);
    expect(requests, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('存储电影身份不冒充追番剧集，无详情网络请求', (tester) async {
    await tester.runAsync(configure);
    saveMatch(type: TmdbMediaType.movie);
    final identity = await pumpCalendar(tester);
    await tester.longPress(entry(identity));
    await tester.pumpAndSettle();
    expect(inDetails(find.text('旧集完整标题')), findsOneWidget);
    expect(requests, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('旧集短按及详情播放按钮均沿用原播放回退路径', (tester) async {
    final identity = await pumpCalendar(tester);
    // 本地没有站点配置，旧路径回退会报站点缺失，不开共享弹窗或标已看。
    await tester.tap(entry(identity));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tmdb-episode-details')), findsNothing);
    expect(state.selectedSite, isNull);
    expect(state.followings.single.watchedEpisode, 0);
    await tester.longPress(entry(identity));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tmdb-episode-details')), findsOneWidget);
    await tester.tap(inDetails(find.text('播放')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tmdb-episode-details')), findsNothing);
    expect(state.selectedSite, isNull);
    expect(state.followings.single.watchedEpisode, 0);
    expect(state.recentHistory(sourceKey: ''), isEmpty);
    expect(tester.takeException(), isNull);
  });
}
