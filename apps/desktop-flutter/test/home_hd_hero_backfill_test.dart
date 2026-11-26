import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/home_hero_art.dart';
import 'package:webhtv_pc/services/recommendation_feedback_store.dart';
import 'package:webhtv_pc/state/detail_recommendation_state.dart';
import 'package:webhtv_pc/core/meta_pipeline.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/tmdb_config.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/storage.dart';
import 'package:webhtv_pc/services/tmdb_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/home_cards.dart';
import 'package:webhtv_pc/ui/home_backdrop.dart';
import 'package:webhtv_pc/ui/home_hero.dart';
import 'package:webhtv_pc/ui/home_page.dart';
import 'package:webhtv_pc/ui/theme.dart';
import 'support/home_hd_art_fixture.dart';
import 'support/test_fonts.dart';

PlaybackHistory row(int n) => PlaybackHistory(
  id: n+1, siteKey: 'site', vodId: 'v$n', vodName: '作品$n',
  vodPic: 'https://fixture.example/poster$n.jpg',
  flag: 'line', episodeName: '第1集', episodeId: 'entry$n',
  positionMs: 60000, durationMs: 600000, updatedAt: 1000-n,
  tmdbId: n+1, mediaType: 'tv',
);

class _State extends AppState {
  _State(Directory dir, this.metadata, int count)
      : rows = [for(var n=0;n<count;n++) row(n)],
        super(paths:AppPaths.resolve(overrides:{
          'config':dir.path,'data':dir.path,'cache':dir.path,'state':dir.path,
        }));
  final List<PlaybackHistory> rows;
  final TmdbService metadata;
  final recommendationFixture = DetailRecommendationDependencies(loaders: const {}, feedback: RecommendationFeedbackStore());
  @override DetailRecommendationDependencies get recommendationDependencies => recommendationFixture;
  MetaPipeline pipeline = MetaPipeline.defaults;
  @override MetaPipeline get metaPipeline => pipeline;
  @override TmdbService get tmdbService => metadata;
  @override bool get externalMetaEnabled => false;
  @override List<PlaybackHistory> recentHistory({int limit=100,String? sourceKey}) => rows;
  @override Future<TmdbItem?> historyTmdbItem(PlaybackHistory row,{bool Function()? isCurrent}) async => null;
  @override Future<Vod?> historyVod(PlaybackHistory row) async => null;
}

final _captureRoot = GlobalKey();
final _capture = Platform.environment['HD_HERO_CAPTURE'] == '1';

Future<void> capture(WidgetTester tester, String name) async {
  if (!_capture) return;
  final data = await tester.runAsync(() async {
    final boundary = _captureRoot.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return bytes!.buffer.asUint8List();
  });
  var root = Directory.current;
  while (!Directory('${root.path}/apps/desktop-flutter').existsSync()) { root = root.parent; }
  final output = File('${root.path}/docs/superpowers/evidence/home-hd-hero/$name.png');
  output.parent.createSync(recursive: true);
  output.writeAsBytesSync(data!);
}

void main(){
  setUpAll(() async { if (_capture) await loadFixtureFonts(); });
  late Directory dir;
  late TmdbService metadata;
  late _State state;
  final dimensions = <String, HomeHeroArtEvidence?>{};
  final inspected = <String>[];
  Completer<HomeHeroArtEvidence?>? delayedImage;
  final delayedChecks = <String, Completer<HomeHeroArtEvidence?>>{};
  var metadataVersion = 0;
  setUp((){
    dimensions.clear(); inspected.clear(); delayedChecks.clear(); delayedImage = null; metadataVersion = 0;
    dir=Directory.systemTemp.createTempSync('home-hd-backfill');
    metadata=TmdbService(
      config:()=>const TmdbConfig(apiKey:'fixture', apiBase:'https://fixture.example/3', imageBase:'https://fixture.example', backdropBase:'https://fixture.example'),
      client:MockClient((request) async {
        final id=int.tryParse(request.url.path.split('/').last)??0;
        return http.Response(jsonEncode({
          'id':id,'name':'作品${id-1}',
          'poster_path':'/poster$id.jpg','backdrop_path':'/backdrop$id.jpg',
          'overview': metadataVersion == 0 ? '剧情$id' : '更新剧情$id','first_air_date':'2026-01-01',
        }),200,headers:{'content-type':'application/json; charset=utf-8'});
      }),
    );
    state=_State(dir,metadata,15);
  });
  tearDown((){state.dispose();metadata.close();dir.deleteSync(recursive:true);});

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize=const Size(1280,800);
    tester.view.devicePixelRatio=1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(theme:buildAppTheme(Brightness.dark).copyWith(
      textTheme: buildAppTheme(Brightness.dark).textTheme.apply(fontFamily: 'FixtureCJK'),
      primaryTextTheme: buildAppTheme(Brightness.dark).primaryTextTheme.apply(fontFamily: 'FixtureCJK'),
    ),
      home:Scaffold(body:RepaintBoundary(key:_captureRoot, child:ListenableBuilder(listenable:state,builder:(_,_)=>HomePage(
        state:state,onOpenBrowse:(){},onOpenHistory:(){},onOpenFollowing:(){},
        onImportConfig:(){},onSearch:(_){},
        heroImageLoader:(provider,_)async{
          final url=(provider as NetworkImage).url;
          inspected.add(url);
          final imageName = url.split('/').last;
          final evidence = delayedChecks.containsKey(imageName)
              ? await delayedChecks[imageName]!.future
              : url.endsWith('/backdrop1.jpg') && delayedImage != null
                  ? await delayedImage!.future
                  : dimensions[imageName];
          if (evidence?.isEligible ?? false) await loadHdHeroFixture(provider, ImageConfiguration.empty);
          return evidence;
        },
      ))))));
    await tester.pumpAndSettle();
  }

  testWidgets('同次运行返回首页立即保留完整12项和第8项，不重新检查图片', (tester) async {
    for (var n = 1; n <= 13; n++) {
      dimensions['backdrop$n.jpg'] = const HomeHeroArtEvidence(width: 1920, height: 1080);
    }
    await pump(tester);
    expect(tester.widget<HomeHero>(find.byType(HomeHero)).items.length, 12);
    await tester.tap(find.byKey(const ValueKey('home-hero-dot-7')));
    await tester.pumpAndSettle();
    expect(tester.widget<HomeBackdrop>(find.byType(HomeBackdrop)).index, 7);
    final checks = inspected.length;
    await tester.pumpWidget(const SizedBox.shrink());
    delayedImage = Completer<HomeHeroArtEvidence?>();
    try {
      await pump(tester);
      final hero = find.byType(HomeHero);
      expect(hero, findsOneWidget, reason: '未重启应用，图片复查不能阻挡已有会话列表');
      expect(tester.widget<HomeHero>(hero).items.length, 12);
      expect(tester.widget<HomeBackdrop>(find.byType(HomeBackdrop)).index, 7);
      expect(inspected.length, checks, reason: '同输入重入不能重新检查已合格图片');
      await tester.tap(find.byKey(const ValueKey('home-hero-next')));
      await tester.pumpAndSettle();
      expect(tester.widget<HomeBackdrop>(find.byType(HomeBackdrop)).index, 8);
    } finally {
      if (!delayedImage!.isCompleted) {
        delayedImage!.complete(const HomeHeroArtEvidence(width: 1920, height: 1080));
      }
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('正在补齐时切页仍复用当前批次，返回不跳过在途作品', (tester) async {
    for (var n = 1; n <= 13; n++) {
      dimensions['backdrop$n.jpg'] = const HomeHeroArtEvidence(width: 1920, height: 1080);
    }
    final pending = Completer<HomeHeroArtEvidence?>();
    delayedChecks['backdrop3.jpg'] = pending;
    await pump(tester);
    expect(tester.widget<HomeHero>(find.byType(HomeHero)).items.length, 2);
    await tester.pumpWidget(const SizedBox.shrink());
    try {
      await pump(tester);
      expect(tester.widget<HomeHero>(find.byType(HomeHero)).items.length, 2);
      pending.complete(const HomeHeroArtEvidence(width: 1920, height: 1080));
      await tester.pumpAndSettle();
      final items = tester.widget<HomeHero>(find.byType(HomeHero)).items;
      expect(items.map((item) => item.title), [for (var n = 0; n < 12; n++) '作品$n']);
      // 在途项在切页时被撤销，返回后重查一次；已完成项不再重查。
      expect(inspected.where((url) => url.endsWith('/backdrop3.jpg')).length, 2);
      expect(inspected.where((url) => url.endsWith('/backdrop1.jpg')).length, 1);
    } finally {
      if (!pending.isCompleted) pending.complete(null);
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('新增候选只检查新增项，保留既有高清资格和观看位置', (tester) async {
    state.rows.removeRange(4, state.rows.length);
    for (var n = 1; n <= 5; n++) {
      dimensions['backdrop$n.jpg'] = const HomeHeroArtEvidence(width: 1920, height: 1080);
    }
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('home-hero-dot-2')));
    await tester.pumpAndSettle();
    final oldChecks = inspected.where((url) => url.endsWith('/backdrop1.jpg')).length;
    state.rows.add(row(4));
    state.notifyListeners();
    await tester.pumpAndSettle();
    expect(tester.widget<HomeHero>(find.byType(HomeHero)).items.length, 5);
    expect(tester.widget<HomeBackdrop>(find.byType(HomeBackdrop)).index, 2);
    expect(inspected.where((url) => url.endsWith('/backdrop1.jpg')).length, oldChecks);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('完整会话图片落盘后清理解码缓存，热返回12张都使用本地图片', (tester) async {
    for (var n = 1; n <= 12; n++) {
      dimensions['backdrop$n.jpg'] = const HomeHeroArtEvidence(width: 1920, height: 1080);
    }
    await pump(tester);
    final deadline = Stopwatch()..start();
    while (!state.log.entries.any((entry) => entry.message.contains('event=session_cache_save') &&
        entry.message.contains('readable=12')) && deadline.elapsed < const Duration(seconds: 25)) {
      await tester.runAsync(() => Future<void>(() {}));
      await tester.pump();
    }
    final manifest = File('${dir.path}/home-hero-session-v1/index.json');
    expect(manifest.existsSync(), isTrue, reason: state.log.entries.where((entry) => entry.scope == 'home').map((entry) => entry.message).join(' | '));
    expect((jsonDecode(manifest.readAsStringSync()) as Map)['entries'], hasLength(12));
    await tester.pumpWidget(const SizedBox.shrink());
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    await pump(tester);
    final items = tester.widget<HomeHero>(find.byType(HomeHero)).items;
    expect(items, hasLength(12));
    expect(items.every((item) => Uri.parse(item.backdrop!).scheme == 'file'), isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('后台元数据更新不替换正在阅读的作品，切走后再采用新文案', (tester) async {
    state.rows.removeRange(2, state.rows.length);
    for (var n = 1; n <= 2; n++) {
      dimensions['backdrop$n.jpg'] = const HomeHeroArtEvidence(width: 1920, height: 1080);
    }
    await pump(tester);
    expect(tester.widget<HomeHero>(find.byType(HomeHero)).items.first.overview, '剧情1');
    metadataVersion = 1;
    state.homeHeroSession.invalidateMetadata();
    await tester.pumpAndSettle();
    final items = tester.widget<HomeHero>(find.byType(HomeHero)).items;
    expect(items.first.overview, '剧情1', reason: '正在读的这一张不接受后台改写');
    expect(items[1].overview, '更新剧情2', reason: '没在读的那一张照常换成新内容');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('首批6项都无高清宽图时，第13项仍能补位且低清作品留在轨道', (tester)async{
    // 前面的poster/backdrop低清/竖图，即使URL写w1280也不合格。
    dimensions['backdrop13.jpg']=const HomeHeroArtEvidence(width:1920,height:1080);
    await pump(tester);
    final hero=tester.widget<HomeHero>(find.byType(HomeHero));
    expect(hero.items.map((x)=>x.title),['作品12']);
    expect(hero.items.single.backdrop,endsWith('/backdrop13.jpg'));
    expect(inspected.any((url)=>url.endsWith('/backdrop1.jpg')),isTrue);
    expect(inspected.any((url)=>url.endsWith('/backdrop13.jpg')),isTrue);
    await capture(tester, 'after-hd-backfill');
    await tester.drag(find.byKey(const ValueKey('home-scroll')),const Offset(0,-700));
    await tester.pumpAndSettle();
    final rail=tester.widget<HomeRailView>(find.byType(HomeRailView)).rail;
    expect(rail.items.length,15);
    expect(rail.items.first.title,'作品0');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('全部失败或低清：保留同高占位，低清作品仍在下方轨道', (tester)async{
    dimensions['backdrop1.jpg']=const HomeHeroArtEvidence(width:241,height:330);
    dimensions['backdrop2.jpg']=const HomeHeroArtEvidence(width:1279,height:720);
    await pump(tester);
    expect(find.byType(HomeHero),findsNothing);
    final placeholder=find.byKey(const ValueKey('home-hero-startup-placeholder'));
    expect(placeholder,findsOneWidget);
    expect(tester.getSize(placeholder).height,800);
    expect(tester.getTopLeft(find.byType(HomeRailView,skipOffstage:false)).dy,800);
    await tester.scrollUntilVisible(find.byType(HomeRailView),400,
      scrollable:find.descendant(of:find.byKey(const ValueKey('home-scroll')),matching:find.byType(Scrollable)).first);
    expect(tester.widget<HomeRailView>(find.byType(HomeRailView)).rail.items.length,15);
    await capture(tester, 'after-no-qualifying-art');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('解码完成乱序仍按候选顺序展示，而不是网速优先', (tester)async{
    delayedImage=Completer<HomeHeroArtEvidence?>();
    dimensions['backdrop2.jpg']=const HomeHeroArtEvidence(width:1920,height:1080);
    await pump(tester);
    expect(find.byType(HomeHero),findsNothing,reason:'首批仍有前排候选未完成，不抢位');
    expect(tester.getSize(find.byKey(const ValueKey('home-hero-startup-placeholder'))).height,800);
    delayedImage!.complete(const HomeHeroArtEvidence(width:1920,height:1080));
    await tester.pumpAndSettle();
    expect(tester.widget<HomeHero>(find.byType(HomeHero)).items.map((item)=>item.title),['作品0','作品1']);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('通过解码后实际绘制再失败：撤销当前项并由后续第13项补位', (tester)async{
    for(var n=1;n<=13;n++){
      dimensions['backdrop$n.jpg']=const HomeHeroArtEvidence(width:1920,height:1080);
    }
    await pump(tester);
    expect(tester.widget<HomeHero>(find.byType(HomeHero)).items.length,12);
    final background=tester.widget<HomeBackdrop>(find.byType(HomeBackdrop));
    final broken=tester.widget<HomeHero>(find.byType(HomeHero)).items.first;
    background.onImageError!(broken);
    await tester.pump();
    await tester.pumpAndSettle();
    final remaining=tester.widget<HomeHero>(find.byType(HomeHero)).items;
    expect(remaining.length,12);
    expect(remaining.map((item)=>item.title),isNot(contains(broken.title)));
    expect(remaining.map((item)=>item.title),contains('作品12'));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('宽图字段关闭：已通过资格的作品不得留在轮播', (tester)async{
    dimensions['backdrop1.jpg']=const HomeHeroArtEvidence(width:1920,height:1080);
    await pump(tester);
    expect(find.byType(HomeHero),findsOneWidget);
    state.pipeline=state.pipeline.withRule(state.pipeline.ruleOf(MetaField.backdrop).copyWith(order:[]));
    state.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.byType(HomeHero),findsNothing);
    expect(tester.getSize(find.byKey(const ValueKey('home-hero-startup-placeholder'))).height,800);
    await tester.scrollUntilVisible(find.byType(HomeRailView),400,
      scrollable:find.descendant(of:find.byKey(const ValueKey('home-scroll')),matching:find.byType(Scrollable)).first);
    expect(find.byType(HomeRailView),findsOneWidget);
    expect(tester.widget<HomeRailView>(find.byType(HomeRailView)).rail.items.length,15);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
