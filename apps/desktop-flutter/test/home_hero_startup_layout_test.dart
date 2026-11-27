import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;


import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/home_hero_art.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/tmdb_config.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/storage.dart';
import 'package:webhtv_pc/services/home_hero_startup_cache.dart';
import 'package:webhtv_pc/services/tmdb_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/home_cards.dart';
import 'package:webhtv_pc/ui/home_backdrop.dart';
import 'package:webhtv_pc/ui/home_hero.dart';
import 'package:webhtv_pc/ui/home_page.dart';
import 'package:webhtv_pc/ui/theme.dart';

import 'support/home_hd_art_fixture.dart';
import 'support/detail_test_seams.dart';
import 'support/test_fonts.dart';

class _StartupState extends AppState {
  _StartupState(Directory dir, this.metadata) : super(paths:AppPaths.resolve(overrides:{
    'config':dir.path,'data':dir.path,'cache':dir.path,'state':dir.path,
  }),log:MemoryOnlyLogService());
  final TmdbService metadata;
  @override bool get externalMetaEnabled=>false;
  @override TmdbService get tmdbService=>metadata;
  @override List<PlaybackHistory> recentHistory({int limit=100,String? sourceKey})=>const[
    PlaybackHistory(id:1,sourceKey:'original',siteKey:'site',vodId:'v1',vodName:'启动剧集',
      vodPic:'https://fixture.example/poster.jpg',flag:'原线路',episodeName:'第2集',episodeId:'entry2',
      positionMs:123456,durationMs:1200000,updatedAt:100,tmdbId:42,mediaType:'tv'),
  ];
  @override Future<Vod?> historyVod(PlaybackHistory row)async=>null;
  @override Future<TmdbItem?> historyTmdbItem(PlaybackHistory row,{bool Function()? isCurrent})async=>null;
}

final _captureRoot = GlobalKey();
final _capture = Platform.environment['HERO_STARTUP_CAPTURE'] == '1';

Future<void> captureStartup(WidgetTester tester,String name)async{
  if(!_capture)return;
  final bytes=await tester.runAsync(()async{
    final boundary=_captureRoot.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image=await boundary.toImage(pixelRatio:1);
    final data=await image.toByteData(format:ui.ImageByteFormat.png);
    image.dispose();
    return data!.buffer.asUint8List(data.offsetInBytes,data.lengthInBytes);
  });
  var root=Directory.current;
  while(!Directory('${root.path}/apps/desktop-flutter').existsSync()){root=root.parent;}
  final output=File('${root.path}/docs/superpowers/evidence/home-hero-startup-cache/$name.png');
  output.parent.createSync(recursive:true);output.writeAsBytesSync(bytes!);
}

void main(){
  setUpAll(()async{if(_capture)await loadFixtureFonts();});
  late Directory dir;
  late TmdbService metadata;
  late _StartupState state;
  late Completer<HomeHeroArtEvidence?> delayed;
  late Completer<void> imageLoaderCompleted;
  var imageLoadStarted=false;
  setUp((){
    dir=Directory.systemTemp.createTempSync('home-startup-layout');
    delayed=Completer<HomeHeroArtEvidence?>.sync();
    imageLoaderCompleted=Completer<void>();
    imageLoadStarted=false;
    metadata=TmdbService(config:()=>const TmdbConfig(apiKey:'fixture',
      imageBase:'https://fixture.example/posters',backdropBase:'https://fixture.example/backdrops'),client:MockClient((_)async=>http.Response(
      jsonEncode({'id':42,'name':'启动剧集','poster_path':'/poster.jpg',
        'backdrop_path':'/startup-backdrop.jpg','overview':'启动剧情','first_air_date':'2026-01-01'}),
      200,headers:{'content-type':'application/json; charset=utf-8'})));
    state=_StartupState(dir,metadata);
  });
  tearDown(() async {
    state.dispose();metadata.close();
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    try { await dir.delete(recursive:true); } on FileSystemException {
      // Windows文件解码器可能暂时持有句柄；临时目录留待系统清理，不影响产品profile。
    }
  });

  Future<void> pump(WidgetTester tester,{bool settle=true})async{
    tester.view.physicalSize=const Size(1280,800);
    tester.view.devicePixelRatio=1;
    addTearDown(tester.view.reset);
    await loadHdHeroFixture(
      const NetworkImage('https://fixture.example/backdrops/startup-backdrop.jpg'),
      ImageConfiguration.empty,
    );
    await tester.pumpWidget(MaterialApp(theme:buildAppTheme(Brightness.dark),
      home:Scaffold(body:RepaintBoundary(key:_captureRoot,child:HomePage(state:state,onOpenBrowse:(){},onOpenHistory:(){},
        onOpenFollowing:(){},onImportConfig:(){},onSearch:(_){},
        heroImageLoader:(provider,configuration){
          imageLoadStarted=true;
          return delayed.future.then((result){
          if(!imageLoaderCompleted.isCompleted) imageLoaderCompleted.complete();
          return result;
        });
        },
      )))));
    if(settle) await tester.pumpAndSettle();
  }

  Finder rail()=>find.byType(HomeRailView,skipOffstage:false);

  testWidgets('无缓存冷启动第一帧即预留hero全高，加载完成轨道不被往下推', (tester)async{
    await pump(tester);
    final placeholder=find.byKey(const ValueKey('home-hero-startup-placeholder'));
    expect(placeholder,findsOneWidget);
    expect(tester.getSize(placeholder).height,800);
    final initialLogs=state.log.entries.where((entry)=>entry.scope=='home').toList();
    expect(initialLogs.where((entry)=>entry.message.contains('event=cache_restore') &&
      entry.message.contains('usable=0')).length,1);
    expect(initialLogs.any((entry)=>entry.message.contains('event=scan_start')),isTrue);
    expect(initialLogs.any((entry)=>entry.message.contains('event=first_available')),isFalse);
    final before=tester.getTopLeft(rail()).dy;
    await captureStartup(tester,'cold-first-frame');
    // 先准备真实高清像素，等待结果的异步边界只负责门控，不发真实网络。
    await loadHdHeroFixture(const NetworkImage('https://fixture.example/backdrops/startup-backdrop.jpg'),ImageConfiguration.empty);
    expect(imageLoadStarted,isTrue,reason:'必须已触发真实候选图片验证，不能只验证占位');
    delayed.complete(const HomeHeroArtEvidence(width:1920,height:1080));
    await tester.pump();
    expect(imageLoaderCompleted.isCompleted,isTrue,reason:'门控完成后图片结果已送达');
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.byType(HomeHero),findsOneWidget);
    expect(tester.getTopLeft(rail()).dy,before,reason:'只替换同高内容，不重新插入hero');
    await captureStartup(tester,'cold-ready-same-height');
    final history=tester.widget<HomeHero>(find.byType(HomeHero)).items.single.history!;
    expect(history.flag,'原线路');
    expect(history.episodeId,'entry2');
    expect(history.positionMs,123456);
    final readyLogs=state.log.entries.where((entry)=>entry.scope=='home').toList();
    expect(readyLogs.where((entry)=>entry.message.contains('event=first_available') &&
      entry.message.contains('source=verified_image')).length,1);
    expect(readyLogs.any((entry)=>entry.message.contains('event=scan_complete') &&
      entry.message.contains('accepted=1')),isTrue);
    await tester.pump();
    expect(state.log.entries.where((entry)=>entry.scope=='home' &&
      entry.message.contains('event=first_available')).length,1,reason:'重建不能重复打印首项事件');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('重启离线时第一帧即恢复本地宽图，后台未完成也不退回轨道', (tester)async{
    // 与生产scope相同，但不调用任何页面私有方法：这个摘要只绑定当前来源/字段/header。
    final scope=sha256.convert(utf8.encode(jsonEncode([
      state.activeSourceKey,state.metaPipeline.toJson(),state.externalMetaEnabled,
      state.metaOverrides.toJson(),state.liveSiteKeywords,
      state.tmdbConfig.enabled,state.tmdbConfig.imageBase,state.tmdbConfig.backdropBase,
      state.tmdbConfig.enabledSites,state.tmdbConfig.disabledSites,state.tmdbConfig.allowedSites,
    ]))).toString();
    const url='https://fixture.example/saved-startup-backdrop.jpg';
    await tester.runAsync(() async {
    await loadHdHeroFixture(const NetworkImage(url),ImageConfiguration.empty);
    final stream=const NetworkImage(url).resolve(ImageConfiguration.empty);
    final imageReady=Completer<ImageInfo>();
    late ImageStreamListener listener;
    listener=ImageStreamListener((info,_){if(!imageReady.isCompleted)imageReady.complete(info);});
    stream.addListener(listener);
    final info=await imageReady.future;
    final data=await info.image.toByteData(format:ui.ImageByteFormat.png);
    info.dispose();stream.removeListener(listener);
    final cache=HomeHeroStartupCache(directory:dir);
    await cache.save(scope,[HomeHeroStartupCandidate(
      key:sha256.convert(utf8.encode(jsonEncode(['original|site|v1',42,'tv']))).toString(),
      sourceUrl:url,title:'上次缓存的剧集',
      bytes:data!.buffer.asUint8List(data.offsetInBytes,data.lengthInBytes),
      overview:'离线缓存简介',subtitle:'2026',
    )]);
    });
    final cachedImage=PaintingBinding.instance.imageCache;
    cachedImage.clear();cachedImage.clearLiveImages();
    // 网络验证故意一直未完成；read只依赖已经落盘的图片字节。
    await tester.runAsync(() => pump(tester,settle:false));
    final hero=tester.widget<HomeHero>(find.byType(HomeHero));
    expect(hero.items.single.title,'上次缓存的剧集');
    expect(hero.items.single.backdrop,startsWith('file:'));
    expect(state.log.entries.where((entry)=>entry.scope=='home' &&
      entry.message.contains('event=cache_restore') && entry.message.contains('usable=1')).length,1);
    expect(state.log.entries.any((entry)=>entry.scope=='home' &&
      entry.message.contains('event=first_available') && entry.message.contains('source=local_cache')),isTrue);
    expect(File.fromUri(Uri.parse(hero.items.single.backdrop!)).existsSync(),isTrue);
    expect(hero.items.single.history!.positionMs,123456,reason:'播放上下文来自当前历史而非旧缓存');
    // FileImage解码是平台I/O；断言真实本地图帧到达，不只断言file URI被选中了。
    final fileProvider=FileImage(File.fromUri(Uri.parse(hero.items.single.backdrop!)));
    final decoded=await tester.runAsync(()async{
      final stream=fileProvider.resolve(ImageConfiguration.empty);
      final done=Completer<ImageInfo>();
      late ImageStreamListener listener;
      listener=ImageStreamListener((info,_){if(!done.isCompleted)done.complete(info);},
        onError:(Object error,StackTrace? stack)=>done.completeError(error,stack));
      stream.addListener(listener);
      try{return await done.future.timeout(const Duration(seconds:5));}
      finally{stream.removeListener(listener);}
    });
    expect(decoded!.image.width,1920);
    expect(decoded.image.height,1080);
    decoded.dispose();
    // 重挂实际图像widget以消费已在runAsync完成的FileImage缓存；HomePage和hero原始身份不变。
    tester.view.physicalSize=const Size(1281,800);
    await tester.pump();
    tester.view.physicalSize=const Size(1280,800);
    await tester.pumpAndSettle();
    final bg=tester.widget<HomeBackdrop>(find.byType(HomeBackdrop));
    expect(bg.items.single.backdrop,hero.items.single.backdrop);
    final bgImage=find.descendant(of:find.byType(HomeBackdrop),matching:find.byType(Image));
    final rawImage=find.descendant(of:find.byType(HomeBackdrop),matching:find.byType(RawImage));
    expect(bgImage,findsOneWidget);
    final rendered=tester.widget<RawImage>(rawImage.first);
    expect(rendered.image,isNotNull,reason:'离线真实本地像素必须已经交给背景组件');
    expect(rendered.image!.width,1920);
    expect(tester.widget<Image>(bgImage).image,isA<FileImage>());
    await captureStartup(tester,'offline-cached-first-frame');
    await tester.pumpAndSettle();
    final before=tester.getTopLeft(rail()).dy;
    delayed.complete(null);
    await tester.runAsync(() => imageLoaderCompleted.future.timeout(const Duration(seconds:5)));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(tester.widget<HomeHero>(find.byType(HomeHero)).items.single.title,'上次缓存的剧集');
    expect(tester.getTopLeft(rail()).dy,before);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('页面显示成功后自动保存图片本体，不只测试手工预置快照', (tester)async{
    final cacheDir=Directory('${dir.path}/home-hero-startup-v1')..createSync(recursive:true);
      await pump(tester);
      expect(imageLoadStarted,isTrue);
      delayed.complete(const HomeHeroArtEvidence(width:1920,height:1080));
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.byType(HomeHero),findsOneWidget);
      // 产品异步链在widget fake-zone中创建；真实图像/磁盘I/O完成后要推进帧
      // 才能提交下一步。按已观察到的index事件推进，不用固定sleep或假时钟超时。
      // 读回校验在后台 isolate 里跑，日志会比 index.json 稍晚；两者都到齐才算完成。
      bool savedAndValidated() =>
          File('${cacheDir.path}/index.json').existsSync() &&
          state.log.entries.any((entry)=>entry.scope=='home' &&
            entry.message.contains('event=cache_save') &&
            entry.message.contains('readable=1'));
      final deadline=Stopwatch()..start();
      while(!savedAndValidated() && deadline.elapsed < const Duration(seconds:8)){
        await tester.runAsync(() => Future<void>((){}));
        await tester.pump();
      }
      expect(File('${cacheDir.path}/index.json').existsSync(),isTrue,reason:'真实编码与磁盘index提交应已完成');
      final index=File('${cacheDir.path}/index.json');
      final manifest=jsonDecode(index.readAsStringSync()) as Map;
      final entries=manifest['entries'] as List;
      expect(entries.length,1);
      expect(state.log.entries.any((entry)=>entry.scope=='home' &&
        entry.message.contains('event=cache_save') && entry.message.contains('readable=1')),isTrue);
      final diagnostics=state.log.entries.where((entry)=>entry.scope=='home').map((entry)=>entry.message).join('\n');
      expect(diagnostics, isNot(contains('https://')));
      expect(diagnostics, isNot(contains(dir.path)));
      expect(diagnostics, isNot(contains('fixture')));
      expect(diagnostics, isNot(contains('原线路')));
      expect(diagnostics, isNot(contains('entry2')));
      final file=File('${cacheDir.path}/${(entries.single as Map)['file']}');
      expect(file.existsSync(),isTrue);
      expect(file.lengthSync(),greaterThan(0));
      final decoded=await tester.runAsync(()async{
        final codec=await ui.instantiateImageCodec(await file.readAsBytes());
        final info=await codec.getNextFrame();
        codec.dispose();return info.image;
      });
      expect(decoded!.width,1920);expect(decoded.height,1080);decoded.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('候选全部不合格，加载态变空态也保持同一顶部高度', (tester)async{
    await pump(tester);
    final before=tester.getTopLeft(rail()).dy;
    delayed.complete(null);
    await tester.pumpAndSettle();
    expect(find.byType(HomeHero),findsNothing);
    final placeholder=find.byKey(const ValueKey('home-hero-startup-placeholder'));
    expect(placeholder,findsOneWidget);
    expect(tester.getSize(placeholder).height,800);
    expect(tester.getTopLeft(rail()).dy,before);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
