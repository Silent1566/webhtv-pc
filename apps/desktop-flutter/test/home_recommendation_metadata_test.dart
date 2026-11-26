import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/detail_recommendation.dart';
import 'package:webhtv_pc/core/home_feed.dart';
import 'package:webhtv_pc/core/meta_pipeline.dart';
import 'package:webhtv_pc/core/meta_source.dart';
import 'package:webhtv_pc/core/tmdb_config.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/recommendation_feedback_store.dart';
import 'package:webhtv_pc/services/storage.dart';
import 'package:webhtv_pc/services/tmdb_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/state/detail_recommendation_state.dart';
import 'package:webhtv_pc/ui/home_hero.dart';
import 'package:webhtv_pc/ui/home_cards.dart';
import 'package:webhtv_pc/ui/home_page.dart';
import 'package:webhtv_pc/ui/theme.dart';

import 'support/home_hd_art_fixture.dart';

const entry = RecommendationEntry(
  item: TmdbItem(tmdbId: 42, mediaType: TmdbMediaType.tv, title: '推荐原名', subtitle: '2001'),
  source: RecommendationSource.tmdb,
);

MetaPipeline only(MetaSourceKind source) {
  var pipeline = MetaPipeline.defaults;
  for (final field in MetaField.values) {
    pipeline = pipeline.withRule(pipeline.ruleOf(field).copyWith(order: [source]));
  }
  return pipeline;
}

class _State extends AppState {
  _State(Directory dir, this.metadata, this.dependencies)
      : super(paths: AppPaths.resolve(overrides: {
          'config': dir.path, 'data': dir.path, 'cache': dir.path, 'state': dir.path,
        }));
  final TmdbService metadata;
  final DetailRecommendationDependencies dependencies;
  MetaPipeline pipeline = MetaPipeline.defaults;
  List<String> restrictSites = const [];
  @override
  TmdbConfig get tmdbConfig =>
      super.tmdbConfig.copyWith(enabledSites: restrictSites);

  @override
  TmdbService get tmdbService => metadata;
  @override
  DetailRecommendationDependencies get recommendationDependencies => dependencies;
  @override
  bool get externalMetaEnabled => false;
  @override
  MetaPipeline get metaPipeline => pipeline;
  @override
  List<PlaybackHistory> recentHistory({int limit = 100, String? sourceKey}) => const [
    PlaybackHistory(
      id: 1, siteKey: 'site', vodId: 'seen', vodName: '看过的作品', flag: 'line',
      episodeName: 'e1', episodeId: 'e1', positionMs: 1000, durationMs: 1000,
      updatedAt: 123, completed: true,
    ),
  ];

  void changePipeline(MetaPipeline value) {
    pipeline = value;
    notifyListeners();
  }
}

http.Response response(String title) => http.Response(
  jsonEncode({
    'id': 42, 'name': title, 'first_air_date': '2026-01-01',
    'poster_path': '/poster.jpg', 'backdrop_path': '/backdrop.jpg',
    'overview': 'TMDB简介',
  }),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  late Directory dir;
  late TmdbService metadata;
  late _State state;
  late DetailRecommendationDependencies dependencies;
  Completer<http.Response>? pending;
  var requests = 0;

  setUp(() {
    pending = null;
    requests = 0;
    dir = Directory.systemTemp.createTempSync('home-recommendation-meta');
    metadata = TmdbService(
      config: () => const TmdbConfig(apiKey: 'fixture'),
      client: MockClient((_) async {
        requests++;
        return pending == null ? response('TMDB详情名') : pending!.future;
      }),
    );
    dependencies = DetailRecommendationDependencies(
      feedback: RecommendationFeedbackStore(file: File('${dir.path}/feedback.json')),
      loaders: {
        for (final kind in RecommendationRow.values)
          kind: (_) async => RecommendationPage(
            items: kind == RecommendationRow.tmdb ? const [entry] : const [],
          ),
      },
    );
    state = _State(dir, metadata, dependencies);
  });
  tearDown(() {
    state.dispose();
    dependencies.close();
    metadata.close();
    dir.deleteSync(recursive: true);
  });

  Future<void> pumpHome(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(Brightness.dark),
      home: Scaffold(body: ListenableBuilder(
        listenable: state,
        builder: (_, _) => HomePage(
              heroImageLoader: loadHdHeroFixture,
          state: state, onOpenBrowse: () {}, onOpenHistory: () {},
          onOpenFollowing: () {}, onImportConfig: () {}, onSearch: (_) {},
        ),
      )),
    ));
    await tester.pumpAndSettle();
  }
  HomeItem hero(WidgetTester tester) =>
      tester.widget<HomeHero>(find.byType(HomeHero)).items.single;

  Future<HomeItem> railItem(WidgetTester tester) async {
    final rail = find.byType(HomeRailView);
    if (rail.evaluate().isEmpty) {
      await tester.scrollUntilVisible(rail, 240, scrollable: find.descendant(
        of: find.byKey(const ValueKey('home-scroll')), matching: find.byType(Scrollable),
      ).first);
      await tester.pumpAndSettle();
    }
    return tester.widget<HomeRailView>(rail.first).rail.items.single;
  }

  testWidgets('启用站点白名单不会让推荐整体失去TMDB元数据', (tester) async {
    // 推荐没有站点：空 siteKey 不该被站点闸门判成「未在启用站点里」。
    state.pipeline = MetaPipeline.defaults;
    state.restrictSites = const ['only-this-site'];
    await pumpHome(tester);
    expect(hero(tester).title, 'TMDB详情名');
    expect(requests, 1, reason: '高清候选复用轨道正在读取的元数据');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('解析不到元数据时，年份字段停用仍不显示站点年份', (tester) async {
    pending = Completer<http.Response>();
    final p = state.pipeline;
    state.pipeline = p.withRule(p.ruleOf(MetaField.releaseDate).copyWith(order: []));
    await pumpHome(tester);
    pending!.complete(http.Response(
      jsonEncode({'id': 42}),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    ));
    await tester.pumpAndSettle();
    expect((await railItem(tester)).subtitle, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('推荐的标题规则没有TMDB时不接收TMDB详情标题', (tester) async {
    state.pipeline = only(MetaSourceKind.source);
    await pumpHome(tester);
    expect((await railItem(tester)).title, '推荐原名');
    expect(requests, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('推荐旧请求不能在字段规则变化后覆盖新结果', (tester) async {
    pending = Completer<http.Response>();
    await pumpHome(tester);
    expect(requests, 1, reason: '高清候选复用轨道正在读取的元数据');
    state.changePipeline(only(MetaSourceKind.source));
    await tester.pumpAndSettle();
    pending!.complete(response('过期TMDB标题'));
    await tester.pumpAndSettle();
    expect((await railItem(tester)).title, '推荐原名');
    expect((await railItem(tester)).overview, isNot('TMDB简介'));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('年份字段停用后不从推荐副标题复活旧年份', (tester) async {
    await pumpHome(tester);
    expect(hero(tester).subtitle, '2026');
    final p = state.pipeline;
    state.changePipeline(p.withRule(p.ruleOf(MetaField.releaseDate).copyWith(order: [])));
    await tester.pumpAndSettle();
    expect(hero(tester).subtitle, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
