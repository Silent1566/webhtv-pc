import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/following.dart';
import 'package:webhtv_pc/core/home_feed.dart';
import 'package:webhtv_pc/core/meta_pipeline.dart';
import 'package:webhtv_pc/core/meta_source.dart';
import 'package:webhtv_pc/core/tmdb_config.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/tmdb_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/home_hero.dart';
import 'package:webhtv_pc/ui/home_cards.dart';
import 'package:webhtv_pc/ui/home_page.dart';
import 'package:webhtv_pc/ui/theme.dart';

import 'support/detail_test_seams.dart';
import 'support/home_hd_art_fixture.dart';

class _FollowingHomeState extends AppState {
  _FollowingHomeState(Directory dir, this.metadata, {this.followingCount = 1})
    : super(
        paths: AppPaths.resolve(
          overrides: {
            'config': dir.path,
            'data': dir.path,
            'cache': dir.path,
            'state': dir.path,
          },
        ),
        log: MemoryOnlyLogService(),
      );

  final TmdbService metadata;
  final int followingCount;
  int matchCalls = 0;
  final matchedVodIds = <String>{};
  Completer<TmdbItem?>? pendingMatch;
  MetaPipeline _pipeline = MetaPipeline.defaults;

  @override
  bool get externalMetaEnabled => false;

  @override
  MetaPipeline get metaPipeline => _pipeline;

  void setPipeline(MetaPipeline value) {
    _pipeline = value;
    notifyListeners();
  }

  @override
  TmdbService get tmdbService => metadata;

  @override
  List<Following> get followings => [
    for (var i = 0; i < followingCount; i++)
      Following(
        seriesKey: 'source:0:site:show$i',
        season: 0,
        siteKey: 'site',
        vodId: 'show$i',
        vodName: '今天是太阳雨$i',
        vodPic: 'https://source.example/poster$i.jpg',
        latestReleasedEpisode: 4,
        latestEpisodeName: '番外第4期',
      ),
  ];

  @override
  Future<TmdbItem?> followingTmdbItem(Following item) async {
    matchCalls++;
    matchedVodIds.add(item.vodId);
    if (pendingMatch != null) return pendingMatch!.future;
    return TmdbItem(
      tmdbId: 42,
      mediaType: TmdbMediaType.tv,
      title: item.vodName,
    );
  }
}

MetaPipeline withoutTmdbOverview() {
  final pipeline = MetaPipeline.defaults;
  final rule = pipeline.ruleOf(MetaField.overview);
  return pipeline.withRule(
    rule.copyWith(
      order: rule.order.where((kind) => kind != MetaSourceKind.tmdb).toList(),
    ),
  );
}

void main() {
  late Directory dir;
  late TmdbService metadata;
  late _FollowingHomeState state;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('home-following-meta');
    metadata = TmdbService(
      config: () => const TmdbConfig(apiKey: 'test-key'),
      client: MockClient(
        (request) async => http.Response(
          jsonEncode({
            'id': 42,
            'name': '今天是太阳雨',
            'poster_path': '/metadata-poster.jpg',
            'backdrop_path': '/metadata-backdrop.jpg',
            'overview': '元数据提供的剧情简介',
            'genres': [
              {'id': 18, 'name': '剧情'},
            ],
            'first_air_date': '2026-05-01',
            'vote_average': 8.3,
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      ),
    );
    state = _FollowingHomeState(dir, metadata);
  });

  tearDown(() {
    state.dispose();
    metadata.close();
    dir.deleteSync(recursive: true);
  });

  Future<void> pumpHome(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.dark),
        home: Scaffold(
          body: ListenableBuilder(
            listenable: state,
            builder: (_, _) => HomePage(
              heroImageLoader: loadHdHeroFixture,
              state: state,
              onOpenBrowse: () {},
              onOpenHistory: () {},
              onOpenFollowing: () {},
              onImportConfig: () {},
              onSearch: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  HomeItem heroItem(WidgetTester tester) =>
      tester.widget<HomeHero>(find.byType(HomeHero)).items.first;

  HomeItem railItem(WidgetTester tester) =>
      tester.widget<HomeRailView>(find.byType(HomeRailView).first).rail.items.first;

  Future<void> revealRail(WidgetTester tester) async {
    await tester.scrollUntilVisible(find.byType(HomeRailView),400,
      scrollable:find.descendant(of:find.byKey(const ValueKey('home-scroll')),matching:find.byType(Scrollable)).first);
  }

  testWidgets('关闭海报与背景来源时尚未完成匹配也不显示站点图', (tester) async {
    final pending = Completer<TmdbItem?>();
    state.pendingMatch = pending;
    var pipeline = MetaPipeline.defaults;
    for (final field in [MetaField.poster, MetaField.backdrop]) {
      pipeline = pipeline.withRule(pipeline.ruleOf(field).copyWith(order: []));
    }
    state.setPipeline(pipeline);
    await pumpHome(tester);
    expect(tester.getSize(find.byKey(const ValueKey('home-hero-startup-placeholder'))).height,800);
    await revealRail(tester);
    expect(state.matchCalls, 1, reason: '候选复用进行中的轨道匹配');
    expect(railItem(tester).poster, isNull);
    expect(railItem(tester).backdrop, isNull);
    pending.complete(null);
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('晚到的匹配不能覆盖切换后的空字段规则', (tester) async {
    final pending = Completer<TmdbItem?>();
    state.pendingMatch = pending;
    await pumpHome(tester);
    var pipeline = MetaPipeline.defaults;
    for (final field in MetaField.values) {
      pipeline = pipeline.withRule(pipeline.ruleOf(field).copyWith(order: []));
    }
    state.setPipeline(pipeline);
    await tester.pumpAndSettle();
    await revealRail(tester);
    expect(railItem(tester).poster, isNull);
    pending.complete(
      const TmdbItem(tmdbId: 42, mediaType: TmdbMediaType.tv, title: '今天是太阳雨'),
    );
    await tester.pumpAndSettle();
    await revealRail(tester);
    expect(railItem(tester).poster, isNull);
    expect(railItem(tester).backdrop, isNull);
    expect(railItem(tester).overview, isEmpty);
    expect(metadata.requestCount, 0, reason: '过期匹配后不得再发详情请求');
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('追剧首页复用已匹配身份补全背景、海报与简介', (tester) async {
    await pumpHome(tester);

    final item = heroItem(tester);
    expect(item.poster, endsWith('/metadata-poster.jpg'));
    expect(item.backdrop, endsWith('/metadata-backdrop.jpg'));
    expect(item.overview, '元数据提供的剧情简介');
    expect(item.tags, ['剧情']);
    expect(item.title, '今天是太阳雨', reason: '标题同样用刮削名（管线解析结果）');
    expect(find.text('元数据提供的剧情简介'), findsOneWidget);
    expect(item.reason, '更新至 番外第4期');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('候选补位解析预算有界，全部14条追剧可参与而不遍历整份记录', (tester) async {
    state.dispose();
    state = _FollowingHomeState(dir, metadata, followingCount: 14);
    await pumpHome(tester);

    expect(state.matchedVodIds, hasLength(14));
    expect(state.matchCalls, 14, reason: '每个候选只匹配一次，允许超过原12条预算补位');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('预算外追剧卡也同步隐藏用户关闭的海报', (tester) async {
    state.dispose();
    state = _FollowingHomeState(dir, metadata, followingCount: 14);
    var pipeline = MetaPipeline.defaults;
    for (final field in [MetaField.poster, MetaField.backdrop]) {
      pipeline = pipeline.withRule(pipeline.ruleOf(field).copyWith(order: []));
    }
    state.setPipeline(pipeline);
    await pumpHome(tester);
    expect(tester.getSize(find.byKey(const ValueKey('home-hero-startup-placeholder'))).height,800);
    await revealRail(tester);
    final rail = tester.widget<HomeRailView>(find.byType(HomeRailView)).rail;
    // 14 条追剧在夹具里指向**同一个** TMDB 身份：取回刮削名之后它们的标题全变成
    // 「今天是太阳雨」，首页按作品收敛（2026-11-25），所以这里不再断言 14 张。
    // 用例要钉的性质不变：预算外那几张（没被解析过的）也不得留着站点海报。
    expect(rail.items, isNotEmpty);
    expect(rail.items.last.poster, isNull);
    expect(rail.items.every((item) => item.poster == null), isTrue);
    expect(state.matchedVodIds, hasLength(14));
    expect(state.matchCalls, 14, reason: '即使禁用图像字段，匹配也不重复');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('修改简介来源后按新规则重新解析', (tester) async {
    await pumpHome(tester);
    expect(heroItem(tester).overview, '元数据提供的剧情简介');

    state.setPipeline(withoutTmdbOverview());
    await tester.pumpAndSettle();
    expect(heroItem(tester).overview, isNot('元数据提供的剧情简介'));
    expect(heroItem(tester).backdrop, endsWith('/metadata-backdrop.jpg'));

    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });
}
