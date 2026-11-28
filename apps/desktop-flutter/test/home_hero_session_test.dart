import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:webhtv_pc/core/detail_recommendation.dart';
import 'package:webhtv_pc/core/following.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/home_hero_art.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/core/tmdb_config.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/storage.dart';
import 'package:webhtv_pc/services/recommendation_feedback_store.dart';
import 'package:webhtv_pc/services/tmdb_cache.dart';
import 'package:webhtv_pc/services/tmdb_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/state/detail_recommendation_state.dart';
import 'package:webhtv_pc/state/home_hero_session.dart';

class _State extends AppState {
  _State(Directory dir, this.metadata, this.dependencies)
      : super(paths: AppPaths.resolve(overrides: {
          // 契约（tests/test_linux_path_isolation.py）：四个平台目录必须逐字列出，
          // 不允许用计算出来的映射——漏一个键会悄悄把缓存写到默认目录。
          'config': dir.path,
          'data': dir.path,
          'cache': dir.path,
          'state': dir.path,
        }));
  final TmdbService metadata;
  final DetailRecommendationDependencies dependencies;
  String source = 'first';
  List<PlaybackHistory> rows = [history(60000)];
  List<Following> trackedShows = [];
  @override
  List<Following> get followings => trackedShows;
  @override String get activeSourceKey => source;
  @override TmdbService get tmdbService => metadata;
  @override DetailRecommendationDependencies get recommendationDependencies => dependencies;
  @override bool get externalMetaEnabled => false;
  @override List<PlaybackHistory> recentHistory({int limit = 100, String? sourceKey}) => rows;
  @override Future<TmdbItem?> historyTmdbItem(PlaybackHistory row, {bool Function()? isCurrent}) async => null;
  @override Future<Vod?> historyVod(PlaybackHistory row) async => null;
}

PlaybackHistory history(
  int position, {
  String title = 'local',
  bool completed = false,
}) => PlaybackHistory(
  id: title == 'local' ? 1 : 2,
  siteKey: 'site',
  vodId: title == 'local' ? 'v0' : title,
  vodName: title,
  vodPic: 'https://fixture.example/backdrop-$title.jpg',
  flag: 'line',
  episodeName: 'one',
  episodeId: 'one',
  positionMs: position,
  durationMs: 600000,
  updatedAt: 1000,
  completed: completed,
);

RecommendationPage recommendation(String title) => RecommendationPage(items: [
  RecommendationEntry(item: TmdbItem(tmdbId: 0, mediaType: TmdbMediaType.movie, title: title,
    backdropUrl: 'https://fixture.example/backdrop-$title.jpg'), source: RecommendationSource.tmdb),
]);

void main() {
  late Directory dir;
  late _State state;
  late TmdbService metadata;
  late HomeHeroSession session;
  var now = DateTime(2026, 1, 1);
  var calls = 0;
  var fail = false;
  Completer<RecommendationPage>? pending;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('hero-session-state-');
    now = DateTime(2026, 1, 1); calls = 0; fail = false; pending = null;
    metadata = TmdbService(config: () => const TmdbConfig(enabled: false),
      client: MockClient((_) async => http.Response('{}', 200)));
    final deps = DetailRecommendationDependencies(
      feedback: RecommendationFeedbackStore(),
      loaders: {RecommendationRow.tmdb: (_) async {
        calls++;
        if (fail) throw StateError('offline');
        return pending?.future ?? Future.value(recommendation('cached'));
      }},
    );
    state = _State(dir, metadata, deps);
    session = HomeHeroSession(state, clock: () => now);
    session.attachImageLoader((_, _) async => const HomeHeroArtEvidence(width: 1920, height: 1080));
    session.attach();
  });
  tearDown(() {
    session.dispose(); state.dispose(); metadata.close();
    dir.deleteSync(recursive: true);
  });

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(home: ListenableBuilder(listenable: session,
      builder: (_, _) {
        final p = session.project(headerRules: const []);
        return Text(p.heroItems.map((item) => item.title).join('|'));
      })));
    await tester.pumpAndSettle();
  }

  testWidgets('六小时后只发一个后台任务，慢刷新和失败都保留已显示推荐', (tester) async {
    await pump(tester);
    expect(calls, 1);
    expect(find.textContaining('cached'), findsOneWidget);
    pending = Completer<RecommendationPage>();
    now = now.add(const Duration(hours: 7));
    session.detach(); session.attach();
    await pump(tester);
    expect(calls, 2);
    expect(find.textContaining('cached'), findsOneWidget);
    session.detach(); session.attach();
    await pump(tester);
    // 离页会撤销在途请求（限速定时器不能活过页面），返回时按缓存重来一次。
    expect(calls, 3);
    pending!.completeError(StateError('offline'));
    await tester.pumpAndSettle();
    expect(find.textContaining('cached'), findsOneWidget, reason: '刷新失败不清空已显示推荐');
    now = now.add(const Duration(seconds: 30));
    await pump(tester);
    expect(calls, 3, reason: '失败后的最短重试间隔');
    now = now.add(const Duration(minutes: 2));
    await pump(tester);
    expect(calls, 4, reason: '退避结束后才重试');
    await tester.pumpWidget(const SizedBox.shrink());
    session.detach();
  });

  testWidgets('完播后从已显示的轮播移除，但保留推荐轨道与其他续播', (tester) async {
    await pump(tester);
    expect(find.textContaining('cached'), findsOneWidget);

    state.rows = [
      history(60000),
      history(600000, title: 'cached', completed: true),
    ];
    await pump(tester);
    final projection = session.project(headerRules: const []);
    expect(projection.heroItems.map((item) => item.title), ['local']);
    expect(
      projection.rails.expand((rail) => rail.items).map((item) => item.title),
      contains('cached'),
    );

    await tester.pumpWidget(const SizedBox.shrink());
    session.detach();
  });

  test('剧集详情按键读取新鲜缓存，不扫描目录或触发请求', () async {
    var time = DateTime(2026, 1, 1);
    final cache = TmdbCache(cacheDir: dir.path, clock: () => time);
    var requests = 0;
    final service = TmdbService(
      config: () => const TmdbConfig(apiKey: 'fixture'),
      cache: cache,
      client: MockClient((_) async {
        requests++;
        return http.Response(
          '{"id":12,"name":"Series","last_episode_to_air":'
          '{"season_number":2,"episode_number":3}}',
          200,
        );
      }),
    );
    addTearDown(service.close);
    const series = TmdbItem(tmdbId: 12, mediaType: TmdbMediaType.tv, title: 'Series');
    await service.detail(series, includeRelated: false);
    expect(service.cachedDetail(series.identity!)?['last_episode_to_air'], {
      'season_number': 2,
      'episode_number': 3,
    });
    time = time.add(const Duration(days: 30));
    expect(service.cachedDetail(series.identity!), isNull);
    expect(requests, 1);
    expect(cache.detailScanCount, 0);
  });

  testWidgets('最新一集刚开始看就退出轮播，新集发布后重新进入', (tester) async {
    final show = Following(
      seriesKey: 'show',
      season: 0,
      siteKey: 'site',
      vodId: 'show',
      vodName: '连载剧',
      watchedEpisode: 2,
      latestReleasedEpisode: 2,
    );
    state.trackedShows = [show];
    state.rows = const [
      PlaybackHistory(
        id: 2,
        siteKey: 'site',
        vodId: 'show',
        vodName: '连载剧',
        vodPic: 'https://fixture.example/backdrop-show.jpg',
        flag: 'line',
        episodeName: '第2集',
        episodeId: 'two',
        positionMs: 5000,
        durationMs: 600000,
        updatedAt: 1,
        mediaType: 'tv',
      ),
    ];
    await pump(tester);
    final caughtUp = session.project(headerRules: const []);
    expect(caughtUp.candidates.map((i) => i.title), isNot(contains('连载剧')));
    expect(caughtUp.rails.expand((rail) => rail.items).map((i) => i.title),
        contains('连载剧'));

    state.trackedShows = [show.copyWith(latestReleasedEpisode: 3)];
    await pump(tester);
    expect(session.project(headerRules: const []).candidates.map((i) => i.title),
        contains('连载剧'));
    await tester.pumpWidget(const SizedBox.shrink());
    session.detach();
  });

  testWidgets('配置切换拒收旧推荐任务并保留最新进度，不因进度更新重发推荐', (tester) async {
    pending = Completer<RecommendationPage>();
    final old = pending!;
    await pump(tester);
    expect(calls, 1);
    state.source = 'second';
    pending = null;
    await pump(tester);
    expect(calls, 2);
    old.complete(recommendation('obsolete'));
    await tester.pumpAndSettle();
    expect(find.textContaining('obsolete'), findsNothing);
    state.rows = [history(180000)];
    await pump(tester);
    final p = session.project(headerRules: const []);
    expect(p.heroItems.first.history!.positionMs, 180000);
    expect(calls, 2);
    await tester.pumpWidget(const SizedBox.shrink());
    session.detach();
  });
}
