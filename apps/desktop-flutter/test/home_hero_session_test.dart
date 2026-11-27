import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:webhtv_pc/core/detail_recommendation.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/home_hero_art.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/core/tmdb_config.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/storage.dart';
import 'package:webhtv_pc/services/recommendation_feedback_store.dart';
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
  @override String get activeSourceKey => source;
  @override TmdbService get tmdbService => metadata;
  @override DetailRecommendationDependencies get recommendationDependencies => dependencies;
  @override bool get externalMetaEnabled => false;
  @override List<PlaybackHistory> recentHistory({int limit = 100, String? sourceKey}) => rows;
  @override Future<TmdbItem?> historyTmdbItem(PlaybackHistory row, {bool Function()? isCurrent}) async => null;
  @override Future<Vod?> historyVod(PlaybackHistory row) async => null;
}

PlaybackHistory history(int position) => PlaybackHistory(
  id: 1, siteKey: 'site', vodId: 'v0', vodName: 'local',
  vodPic: 'https://fixture.example/backdrop-local.jpg', flag: 'line',
  episodeName: 'one', episodeId: 'one', positionMs: position,
  durationMs: 600000, updatedAt: 1000,
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
