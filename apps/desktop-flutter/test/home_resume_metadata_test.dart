/// 首页 hero 的续播条目：历史行没存 TMDB 身份时按片名补身份（背景 + 简介），
/// 匹配不到才退回站源 `vod_content`。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/home_feed.dart';
import 'package:webhtv_pc/core/meta_pipeline.dart';
import 'package:webhtv_pc/core/meta_source.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/tmdb_config.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/storage.dart';
import 'package:webhtv_pc/services/tmdb_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/home_hero.dart';
import 'package:webhtv_pc/ui/home_page.dart';
import 'package:webhtv_pc/ui/theme.dart';

import 'support/detail_test_seams.dart';

const String imageBase = 'https://image.tmdb.org/t/p/w500';
const String backdropBase = 'https://image.tmdb.org/t/p/w780';

const Map<String, Object?> detail = {
  'id': 42,
  'name': '一马当先',
  'poster_path': '/metadata-poster.jpg',
  'backdrop_path': '/metadata-backdrop.jpg',
  'overview': '元数据提供的剧情简介',
  'genres': [
    {'id': 18, 'name': '剧情'},
  ],
  'first_air_date': '2026-11-01',
  'vote_average': 8.3,
};

PlaybackHistory historyRow(
  int index, {
  int tmdbId = 0,
  String mediaType = '',
}) => PlaybackHistory(
  id: index + 1,
  siteKey: 'site',
  vodId: 'vod$index',
  vodName: '一马当先$index',
  vodPic: 'https://source.example/poster$index.jpg',
  flag: 'line',
  episodeName: '第1集',
  episodeId: 'e$index',
  positionMs: 60000,
  durationMs: 600000,
  updatedAt: 1000 + index,
  tmdbId: tmdbId,
  mediaType: mediaType,
);

class _ResumeHomeState extends AppState {
  _ResumeHomeState(
    Directory dir,
    this.metadata, {
    int rowCount = 1,
    bool rowHasIdentity = false,
  }) : rows = [
         for (var i = 0; i < rowCount; i++)
           historyRow(
             i,
             tmdbId: rowHasIdentity ? 42 : 0,
             mediaType: rowHasIdentity ? 'tv' : '',
           ),
       ],
       super(
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
  final List<PlaybackHistory> rows;

  /// 身份匹配的假结论：null 表示「匹配不到」。
  TmdbItem? matched;

  /// 站源详情（只有简介，没有 16:9 图）。
  Vod? sourceVod;

  int matchCalls = 0;
  int sourceCalls = 0;

  MetaPipeline _pipeline = MetaPipeline.defaults;

  @override
  MetaPipeline get metaPipeline => _pipeline;

  void setPipeline(MetaPipeline value) {
    _pipeline = value;
    notifyListeners();
  }

  @override
  bool get externalMetaEnabled => false;

  @override
  TmdbService get tmdbService => metadata;

  @override
  List<PlaybackHistory> recentHistory({int limit = 100, String? sourceKey}) =>
      rows;

  @override
  Future<TmdbItem?> historyTmdbItem(PlaybackHistory row) async {
    matchCalls++;
    return matched;
  }

  @override
  Future<Vod?> historyVod(PlaybackHistory row) async {
    sourceCalls++;
    return sourceVod;
  }
}

void main() {
  late Directory dir;
  late TmdbService metadata;
  late _ResumeHomeState state;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('home-resume-meta');
    metadata = TmdbService(
      config: () => const TmdbConfig(
        apiKey: 'test-key',
        imageBase: imageBase,
        backdropBase: backdropBase,
      ),
      client: MockClient(
        (request) async => http.Response(
          jsonEncode(detail),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      ),
    );
    state = _ResumeHomeState(dir, metadata);
  });

  tearDown(() {
    state.dispose();
    metadata.close();
    dir.deleteSync(recursive: true);
  });

  void replaceState(_ResumeHomeState next) {
    state.dispose();
    state = next;
  }

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

  HomeItem hero(WidgetTester tester) =>
      tester.widget<HomeHero>(find.byType(HomeHero)).items.first;

  testWidgets('历史行没有 TMDB 身份：按片名匹配后补上背景与简介', (tester) async {
    state.matched = const TmdbItem(
      tmdbId: 42,
      mediaType: TmdbMediaType.tv,
      title: '一马当先',
    );
    await pumpHome(tester);

    expect(state.matchCalls, 1);
    final item = hero(tester);
    expect(item.backdrop, '$backdropBase/metadata-backdrop.jpg');
    expect(item.overview, '元数据提供的剧情简介');
    expect(find.text('元数据提供的剧情简介'), findsOneWidget);
    expect(state.sourceCalls, 0, reason: '匹配到身份就不必再读站点');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('匹配不到身份：用站源简介兜底，不伪造 16:9 背景', (tester) async {
    state.sourceVod = Vod(
      vodId: 'vod0',
      vodName: '一马当先0',
      vodContent: '站源提供的剧情简介',
    );
    await pumpHome(tester);

    expect(state.matchCalls, 1);
    expect(state.sourceCalls, 1);
    final item = hero(tester);
    expect(item.overview, '站源提供的剧情简介');
    expect(item.backdrop, isNull, reason: '站源只有竖版海报，不能当 16:9 背景');
    expect(item.poster, 'https://source.example/poster0.jpg');
    expect(find.text('站源提供的剧情简介'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('用户把爬虫源移出简介来源时，不读站点', (tester) async {
    var pipeline = MetaPipeline.defaults;
    final rule = pipeline.ruleOf(MetaField.overview);
    pipeline = pipeline.withRule(
      rule.copyWith(
        order: rule.order
            .where((kind) => kind != MetaSourceKind.source)
            .toList(),
      ),
    );
    state.setPipeline(pipeline);
    state.sourceVod = Vod(
      vodId: 'vod0',
      vodName: '一马当先0',
      vodContent: '站源提供的剧情简介',
    );
    await pumpHome(tester);

    expect(state.matchCalls, 1);
    expect(state.sourceCalls, 0, reason: '用户已经关掉了站源简介');
    expect(hero(tester).overview, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('已经带身份的行不重复匹配', (tester) async {
    replaceState(_ResumeHomeState(dir, metadata, rowHasIdentity: true));
    await pumpHome(tester);

    expect(state.matchCalls, 0);
    expect(state.sourceCalls, 0);
    final item = hero(tester);
    expect(item.backdrop, '$backdropBase/metadata-backdrop.jpg');
    expect(item.overview, '元数据提供的剧情简介');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('只匹配 hero 的续播预算（6 条），整份历史不跟着搜', (tester) async {
    replaceState(_ResumeHomeState(dir, metadata, rowCount: 8));
    await pumpHome(tester);

    expect(state.matchCalls, 6);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
