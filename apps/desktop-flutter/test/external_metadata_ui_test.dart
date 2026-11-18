import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/external_detail_meta.dart';
import 'package:webhtv_pc/core/meta_source.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/tmdb_config.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/core/tmdb_media.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/douban_recommendation_service.dart';
import 'package:webhtv_pc/services/external_meta_service.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/tmdb_service.dart';
import 'package:webhtv_pc/services/ui_preferences_store.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/browse_pages.dart';
import 'package:webhtv_pc/ui/meta_sources_page.dart';
import 'package:webhtv_pc/ui/theme.dart';
import 'package:webhtv_pc/ui/tmdb_detail_view.dart';
import 'external_metadata_service_test.dart' show response, suggestion, subject;

Future<void> capture(GlobalKey key, String scenario) async {
  final phase = Platform.environment['EXTMETA_CAPTURE'];
  if (phase == null) return;
  final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 1);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  final file = File('../../.local/extmeta-captures/$scenario-$phase.png');
  await file.parent.create(recursive:true);
  await file.writeAsBytes(png!.buffer.asUint8List());
  image.dispose();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final font=File('/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc');
    if (font.existsSync()) await (FontLoader('FixtureCJK')..addFont(font.readAsBytes().then(ByteData.sublistView))).load();
  });
  Future<AppState> makeState(WidgetTester tester, {ExternalMetaService? external}) async {
    final dir = Directory.systemTemp.createTempSync('extmeta-ui');
    addTearDown(()=>dir.deleteSync(recursive:true));
    final state = AppState(
      paths:AppPaths.resolve(overrides:{'config':dir.path,'data':dir.path,'cache':'${dir.path}/cache','state':'${dir.path}/state'}),
      log:LogService(),
      tmdbService:TmdbService(config:()=>const TmdbConfig(),client:MockClient((_) async => response({'results':[]}))),
      externalMetaService:external ?? ExternalMetaService(),
    );
    addTearDown(state.dispose);
    await tester.runAsync(state.bootstrap);
    return state;
  }
  void viewport(WidgetTester tester) {
    tester.view.physicalSize=const Size(1280,950);
    tester.view.devicePixelRatio=1;
    addTearDown(tester.view.reset);
  }
  Widget app(Widget child, GlobalKey key) {
    final theme=buildAppTheme(Brightness.dark);
    return RepaintBoundary(key:key, child:MaterialApp(theme:theme.copyWith(
      textTheme:theme.textTheme.apply(fontFamily:'FixtureCJK')), home:child));
  }

  testWidgets('unconfigured TMDB detail uses external overview rating and clickable cast', (tester) async {
    viewport(tester);
    final cache = Directory.systemTemp.createTempSync('extmeta-ui-cache');
    addTearDown(()=>cache.deleteSync(recursive:true));
    final external = ExternalMetaService(douban:DoubanRecommendationService(cacheDirectory:cache, delay:(_) async {},
      client:MockClient((r) async {
        if (r.url.path=='/j/subject_suggest') return response(suggestion);
        if (r.url.path.endsWith('/credits')) return response({'items':[
          {'id':'1051526','name':'范伟','character':'演员 Actor (饰 王响)','roles':['演员']},
          {'id':'1397818','name':'辛爽','character':'导演 Director','roles':['导演','编剧']},
        ]});
        if (r.url.path.endsWith('/photos')) return response({'total':3,'photos':[
          {'image':{'large':{'url':'https://img.example/1.jpg'}}},
          {'image':{'large':{'url':'https://img.example/2.jpg'}}},
          {'image':{'large':{'url':'https://img.example/3.jpg'}}},
        ]});
        if (r.url.path.endsWith('/works')) return response({'total':1,'works':[
          {'roles':['演员 (饰 王响)'],'work':{'id':'35588177','title':'漫长的季节','type':'tv','year':'2023','rating':{'value':9.4}}}]});
        if (r.url.path.contains('/celebrity/')) return response({'title':'范伟','extra':{'info':[['IMDB编号','nm1981215'],['出生日期','1962年9月2日']]}});
        if (r.url.path.endsWith('/interests')) return response({'total':413365,'interests':[
          {'comment':'节奏慢但后劲足，范伟的表演撑住了整部剧。','create_time':'2023-04-23','vote_count':12,'rating':{'value':5},'user':{'name':'江户川乱跑'}},
          {'comment':'看着看着就哭了。','create_time':'2023-05-01','vote_count':3,'rating':{'value':4},'user':{'name':'冬天不冷'}},
        ]});
        return response({...subject,'cover':{},'cover_url':''});
      })));
    final state=await makeState(tester,external:external);
    final vod=Vod(vodId:'source',vodName:'漫长的季节',vodYear:'2023',vodArea:'中国大陆',
      vodPlayFrom:'线路',vodPlayUrl:r'第1集$https://media.example/1.mp4',extra:{'type_name':'国产剧'});
    state.seedDetailForTest(vod:vod);
    final key=GlobalKey();
    await tester.pumpWidget(app(DetailPage(state:state,vod:vod),key));
    await tester.pumpAndSettle();
    await tester.runAsync(()=>capture(key,'detail'));
    expect(find.text('豆瓣 9.4'),findsOneWidget);
    expect(find.text('TMDB 9.4'),findsNothing);
    expect(find.text('豆瓣简介'),findsOneWidget);
    await tester.scrollUntilVisible(find.byKey(const ValueKey('detail-external-comments')),400,
      scrollable:find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    expect(find.textContaining('短评（2'),findsOneWidget);
    expect(find.textContaining('范伟的表演'),findsOneWidget);
    // 整页同源：徽标只出现一次，在标题行；逐条不再重复。
    expect(find.byKey(const ValueKey('detail-comments-source')),findsOneWidget);
    expect(find.byKey(const ValueKey('detail-comment-source-douban')),findsNothing);
    await tester.scrollUntilVisible(find.byKey(const ValueKey('tmdb-section-people')),400,
      scrollable:find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('范伟').first);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tmdb-person-page')),findsOneWidget);
    final person = find.byKey(const ValueKey('tmdb-person-page'));
    expect(find.descendant(of: person, matching: find.textContaining('1962年9月2日')), findsOneWidget);
    expect(find.descendant(of: person, matching: find.textContaining('IMDB编号')), findsOneWidget);
    expect(find.byKey(const ValueKey('tmdb-person-photos')), findsOneWidget);
    expect(find.text('照片（3）'), findsOneWidget);
    expect(tester.takeException(),isNull);
  });

  testWidgets('external people never call TMDB and their works search by title', (tester) async {
    viewport(tester);
    var tmdbCalls=0;String? searched;
    final service=TmdbService(config:()=>const TmdbConfig(apiKey:'fixture'), client:MockClient((_) async {
      tmdbCalls++;return response({});
    }));
    addTearDown(service.close);
    const ref=MetaPersonRef(kind:MetaSourceKind.douban,id:1051526,name:'范伟');
    final detail=ExternalPersonMeta.douban(ref:ref, celebrity:{'title':'范伟','extra':{'info':[['性别','男'],['出生日期','1962年9月2日'],
        ['出生地','中国,辽宁,沈阳'],['IMDB编号','nm1981215']]},
        'photos':[
          {'image':{'large':{'url':'https://img.example/p1.jpg'}}},
          {'image':{'large':{'url':'https://img.example/p2.jpg'}}},
          {'image':{'large':{'url':'https://img.example/p3.jpg'}}},
        ]},
      works:[{'roles':['演员 (饰 王响)'],'work':{'id':'35588177','title':'漫长的季节','type':'tv','year':'2023','rating':{'value':9.4}}}])!;
    final key=GlobalKey();
    await tester.pumpWidget(app(TmdbPersonPage(service:service,
      person:const TmdbPerson(personId:1051526,name:'范伟',ref:ref),
      externalLoader:(_) async=>detail,onSearchTitle:(title)=>searched=title),key));
    await tester.pumpAndSettle();
    await tester.runAsync(()=>capture(key,'person'));
    expect(find.textContaining('1962年9月2日'),findsOneWidget);
    await tester.tap(find.text('漫长的季节'));
    expect(searched,'漫长的季节');
    expect(tmdbCalls,0);
    expect(tester.takeException(),isNull);
  });

  testWidgets('fallback switch is independent from TMDB and saved when turned off', (tester) async {
    viewport(tester);
    final state=await makeState(tester);
    final key=GlobalKey();
    await tester.pumpWidget(app(MetaSourcesPage(state:state),key));
    await tester.pumpAndSettle();
    final switchFinder=find.byKey(const ValueKey('external-meta-enabled'));
    expect(switchFinder,findsOneWidget);
    expect(tester.widget<SwitchListTile>(switchFinder).value,isTrue);
    await tester.tap(switchFinder);
    await tester.pumpAndSettle();
    expect(state.externalMetaEnabled,isFalse);
    final store=UiPreferencesStore(path:'${state.paths.configDir}/settings.json');
    await tester.runAsync(store.load);
    expect(store.externalMetaEnabled,isFalse);
    expect(tester.takeException(),isNull);
  });
}
