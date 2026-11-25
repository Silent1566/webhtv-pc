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
  setUp((){
    dimensions.clear(); inspected.clear(); delayedImage = null;
    dir=Directory.systemTemp.createTempSync('home-hd-backfill');
    metadata=TmdbService(
      config:()=>const TmdbConfig(apiKey:'fixture'),
      client:MockClient((request) async {
        final id=int.tryParse(request.url.path.split('/').last)??0;
        return http.Response(jsonEncode({
          'id':id,'name':'作品${id-1}',
          'poster_path':'/poster$id.jpg','backdrop_path':'/backdrop$id.jpg',
          'overview':'剧情$id','first_air_date':'2026-01-01',
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
          final evidence = url.endsWith('/backdrop1.jpg') && delayedImage != null
              ? await delayedImage!.future
              : dimensions[url.split('/').last];
          if (evidence?.isEligible ?? false) await loadHdHeroFixture(provider, ImageConfiguration.empty);
          return evidence;
        },
      ))))));
    await tester.pumpAndSettle();
  }

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
