import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/external_meta.dart';
import 'package:webhtv_pc/core/meta_source.dart';
import 'package:webhtv_pc/core/meta_pipeline.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/source_meta_resolver.dart';
import 'package:webhtv_pc/core/tmdb_detail_model.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/core/tmdb_media.dart';
import 'package:webhtv_pc/services/bangumi_service.dart';
import 'package:webhtv_pc/services/douban_recommendation_service.dart';
import 'package:webhtv_pc/services/external_meta_service.dart';
import 'package:webhtv_pc/services/wikidata_service.dart';

http.Response response(Object value, [int code = 200]) => http.Response(jsonEncode(value), code,
  headers:{'content-type':'application/json; charset=utf-8'});
const suggestion = [{'id':'35588177', 'title':'漫长的季节', 'year':'2023', 'episode':'12',
  'type':'movie', 'sub_title':'The Long Season', 'img':'https://img.example/cover.jpg'}];
const subject = {'id':'35588177','title':'漫长的季节', 'is_tv':true,'type':'tv','year':'2023',
  'intro':'豆瓣简介','episodes_count':12,'rating':{'value':9.4,'count':10},
  'cover':{'url':'https://img.example/cover.jpg'},'pubdate':['2023-04-22(中国大陆)']};

void main() {
  test('raw field resolution obeys external order and never fetches source identity', () async {
    final temp = Directory.systemTemp.createTempSync('crawler-field-service');
    addTearDown(() => temp.deleteSync(recursive: true));
    var bangumiCalls = 0;
    final service = ExternalMetaService(
      douban: DoubanRecommendationService(cacheDirectory: temp, delay: (_) async {}, client: MockClient((r) async {
        if (r.url.path == '/j/subject_suggest') return response(suggestion);
        if (r.url.path.endsWith('/credits')) return response({'items': []});
        return response({...subject, 'intro': 'Raw Douban overview'});
      })),
      bangumi: BangumiService(minInterval: Duration.zero, client: MockClient((r) async {
        bangumiCalls++;
        if (r.method == 'POST') return response({'data': [{'id': 431299, 'name_cn': '漫长的季节', 'platform': '国产剧', 'date': '2023-04-22'}]});
        if (r.url.path.endsWith('/persons')) return response([]);
        return response({'id': 431299, 'name_cn': '漫长的季节', 'summary': 'Raw Bangumi overview'});
      })),
    );
    addTearDown(service.close);
    final pipeline = MetaPipeline.defaults.withRule(MetaPipeline.defaults.ruleOf(MetaField.overview).copyWith(order: [MetaSourceKind.bangumi, MetaSourceKind.douban, MetaSourceKind.source]));
    final result = await service.resolveFields(const MetaQuery(title: '漫长的季节', year: 2023), source: Vod(vodId: 'v', vodName: '漫长的季节'), pipeline: pipeline);
    expect(result.providers[MetaSourceKind.bangumi]?.overview, 'Raw Bangumi overview');
    expect(result.providers[MetaSourceKind.douban]?.overview, 'Raw Douban overview');
    expect(bangumiCalls, greaterThan(0));
    expect(await service.candidates(const MetaQuery(title: 'x'), MetaSourceKind.source), isEmpty);
    expect(await service.resolveIdentity(const MetaQuery(title: 'x'), MetaSourceKind.source, 0), isNull);
  });

  late Directory temp;
  setUp(()=>temp=Directory.systemTemp.createTempSync('extmeta-service'));
  tearDown(()=>temp.deleteSync(recursive:true));
  DoubanRecommendationService douban(http.Client client) => DoubanRecommendationService(
    client:client,cacheDirectory:temp,delay:(_) async {});

  ExternalMetaService fieldService(List<String> requests) {
    final service = ExternalMetaService(
      douban: douban(MockClient((r) async {
        requests.add(r.url.path);
        if (r.url.path == '/j/subject_suggest') return response(suggestion);
        if (r.url.path.endsWith('/credits')) {
          return response({'items': [
            {'id': '1', 'name': '范伟', 'character': '演员', 'roles': ['演员']},
            {'id': '2', 'name': '辛爽', 'character': '导演', 'roles': ['导演']},
          ]});
        }
        return response(subject);
      })),
      bangumi: BangumiService(minInterval: Duration.zero, client: MockClient((r) async {
        requests.add(r.url.path);
        if (r.method == 'POST') {
          return response({'data': [
            {'id': 431299, 'name_cn': '漫长的季节', 'platform': '国产剧', 'date': '2023-04-22'},
          ]});
        }
        if (r.url.path.endsWith('/persons')) {
          return response([
            {'id': 7, 'name': '范伟', 'relation': '主演'},
            {'id': 8, 'name': '辛爽', 'relation': '导演'},
          ]);
        }
        return response({
          'id': 431299, 'name_cn': '漫长的季节', 'summary': 'Bangumi 简介',
          'images': {'large': 'https://img.example/bangumi.jpg'},
        });
      })),
    );
    addTearDown(service.close);
    return service;
  }

  MetaPipeline fieldPipeline(Map<MetaField, List<MetaSourceKind>> orders) {
    var pipeline = MetaPipeline.defaults;
    for (final field in MetaField.values) {
      pipeline = pipeline.withRule(pipeline.ruleOf(field).copyWith(order: orders[field] ?? []));
    }
    return pipeline;
  }

  const fieldQuery = MetaQuery(title: '漫长的季节', year: 2023);
  final fieldSource = Vod(vodId: 'local', vodName: 'Local title');
  MetaIdentity fieldIdentity(MetaSourceKind kind) => MetaIdentity.of(
    kind, TmdbMediaType.tv, kind == MetaSourceKind.douban ? 35588177 : 431299,
  )!;

  test('successful pin leaves explicitly disabled poster and work fields empty', () async {
    final service = fieldService([]);
    final pipeline = fieldPipeline({MetaField.overview: [MetaSourceKind.douban]});
    final result = await service.resolveFields(fieldQuery, source: fieldSource,
      pipeline: pipeline, pinned: fieldIdentity(MetaSourceKind.douban));
    expect(result.pinnedKind, MetaSourceKind.douban);
    final effective = result.effectivePipeline(pipeline);
    final projected = SourceMetaResolver.resolve(pipeline: effective, source: fieldSource,
      providers: result.providers, primary: result.primary?.data);
    expect(projected.overview, '豆瓣简介');
    expect(projected.posterUrl, isNull);
    expect(projected.posterUrls, isEmpty);
    for (final field in MetaField.values.where(MetaPipeline.supportsSource)) {
      if (field != MetaField.overview) expect(effective.orderOf(field), isEmpty, reason: field.name);
    }
  });

  for (final kind in [MetaSourceKind.douban, MetaSourceKind.bangumi]) {
    for (final pinned in [false, true]) {
      test('home-scope fields skip people endpoints (${kind.name}, pinned=$pinned)', () async {
        final requests = <String>[];
        final service = fieldService(requests);
        final pipeline = fieldPipeline({
          for (final field in [MetaField.poster, MetaField.backdrop, MetaField.overview,
            MetaField.genres, MetaField.releaseDate]) field: [kind],
        });
        final result = await service.resolveFields(fieldQuery, source: fieldSource,
          pipeline: pipeline, pinned: pinned ? fieldIdentity(kind) : null);
        final projected = SourceMetaResolver.resolve(
          pipeline: result.effectivePipeline(pipeline), source: fieldSource,
          providers: result.providers, primary: result.primary?.data);
        expect(projected.overview, kind == MetaSourceKind.douban ? '豆瓣简介' : 'Bangumi 简介');
        expect(projected.posterUrl, kind == MetaSourceKind.douban
          ? 'https://img.example/cover.jpg' : 'https://img.example/bangumi.jpg');
        expect(requests.where((path) => path.endsWith('/credits')), isEmpty);
        expect(requests.where((path) => path.endsWith('/persons')), isEmpty);
      });

      for (final peopleField in [MetaField.cast, MetaField.crew]) {
        test('people fields fetch only required provider (${kind.name}, ${peopleField.name}, pinned=$pinned)', () async {
          final requests = <String>[];
          final service = fieldService(requests);
          final pipeline = fieldPipeline({
            MetaField.overview: [MetaSourceKind.douban],
            MetaField.poster: [MetaSourceKind.bangumi],
            peopleField: [pinned ? MetaSourceKind.source : kind],
          });
          final result = await service.resolveFields(fieldQuery, source: fieldSource,
            pipeline: pipeline, pinned: pinned ? fieldIdentity(kind) : null);
          final projected = SourceMetaResolver.resolve(
            pipeline: result.effectivePipeline(pipeline), source: fieldSource,
            providers: result.providers, primary: result.primary?.data);
          expect(peopleField == MetaField.cast
            ? projected.cast.map((person) => person.name)
            : projected.crew.map((person) => person.name),
            [peopleField == MetaField.cast ? '范伟' : '辛爽']);
          expect(requests.where((path) => path.endsWith('/credits')),
            hasLength(kind == MetaSourceKind.douban ? 1 : 0));
          expect(requests.where((path) => path.endsWith('/persons')),
            hasLength(kind == MetaSourceKind.bangumi ? 1 : 0));
        });
      }
    }
  }

  test('default field resolution still loads provider casts', () async {
    final requests = <String>[];
    final service = fieldService(requests);
    final result = await service.resolveFields(fieldQuery, source: fieldSource,
      pipeline: MetaPipeline.defaults);
    expect(result.providers[MetaSourceKind.douban]?.cast.single.name, '范伟');
    expect(result.providers[MetaSourceKind.bangumi]?.cast.single.name, '范伟');
    expect(requests.where((path) => path.endsWith('/credits')), hasLength(1));
    expect(requests.where((path) => path.endsWith('/persons')), hasLength(1));
  });

  for (final kind in [null, MetaSourceKind.douban, MetaSourceKind.bangumi]) {
    test('legacy detail keeps people loading (pin=${kind?.name})', () async {
      final service = fieldService([]);
      final result = await service.detail(fieldQuery, pinned: kind == null ? null : fieldIdentity(kind));
      expect(result?.data.cast.single.name, '范伟');
      expect(result?.data.crew.single.name, '辛爽');
    });
  }

  for (final sourceOnly in [false, true]) {
    test('source-first complete resource retains independently enabled photos (sourceOnly=$sourceOnly)', () async {
      final requests = <String>[];
      final service = ExternalMetaService(douban: douban(MockClient((r) async {
        requests.add(r.url.path);
        if (r.url.path == '/j/subject_suggest') return response(suggestion);
        if (r.url.path.endsWith('/photos')) return response({'photos': [
          {'image': {'large': {'url': 'https://img.example/still.jpg'}}},
        ]});
        return response({}, 500);
      })));
      addTearDown(service.close);
      var pipeline = MetaPipeline.defaults;
      for (final field in MetaField.values.where(MetaPipeline.supportsSource)) {
        pipeline = pipeline.withRule(pipeline.ruleOf(field).copyWith(order: [
          MetaSourceKind.source, if (!sourceOnly) MetaSourceKind.douban,
        ]));
      }
      final result = await service.resolveFields(const MetaQuery(title: '漫长的季节', year: 2023),
        source: Vod(vodId: 'local', vodName: '漫长的季节', vodContent: 'Local overview',
          vodPic: 'local.jpg', vodActor: 'Local actor', vodDirector: 'Local director',
          vodArea: 'Local country', vodYear: '2023', extra: {'type_name': 'Drama', 'vod_lang': 'Local language'}),
        pipeline: pipeline);
      expect(result.primary?.data.photoUrls, ['https://img.example/still.jpg']);
      expect(result.primary?.identity.kind, MetaSourceKind.douban);
      final shown = SourceMetaResolver.resolve(pipeline: pipeline,
        source: Vod(vodId: 'local', vodName: '漫长的季节', vodContent: 'Local overview'),
        providers: result.providers, primary: result.primary?.data);
      expect(shown.title, '漫长的季节');
      expect(shown.overview, 'Local overview');
      expect(shown.photoUrls, ['https://img.example/still.jpg']);
      expect(shown.tmdbId, 0);
      expect(shown.rating, 0);
      expect(result.providers, isEmpty, reason: 'local priority stops must still avoid fetching external detail fields');
      expect(requests, ['/j/subject_suggest', '/rexxar/api/v2/tv/35588177/photos']);
      requests.clear();
      service.clearCache();
      final disabled = await service.resolveFields(const MetaQuery(title: '漫长的季节', year: 2023),
        source: Vod(vodId: 'local', vodName: '漫长的季节', vodContent: 'Local overview',
          vodPic: 'local.jpg', vodActor: 'Local actor', vodDirector: 'Local director',
          vodArea: 'Local country', vodYear: '2023', extra: {'type_name': 'Drama', 'vod_lang': 'Local language'}),
        pipeline: pipeline.withRule(pipeline.ruleOf(MetaField.photos).copyWith(order: [])));
      expect(disabled.primary, isNull);
      expect(requests, isEmpty, reason: 'disabled photos must not initiate a provider request');
    });
  }

  test('independent photo result is discarded when generation changes in flight', () async {
    final started = Completer<void>();
    final pending = Completer<http.Response>();
    final service = ExternalMetaService(douban: douban(MockClient((r) async {
      if (r.url.path == '/j/subject_suggest') return response(suggestion);
      if (r.url.path.endsWith('/photos')) { started.complete(); return pending.future; }
      return response({}, 500);
    })));
    addTearDown(service.close);
    var pipeline = MetaPipeline.defaults;
    for (final field in MetaField.values.where(MetaPipeline.supportsSource)) {
      pipeline = pipeline.withRule(pipeline.ruleOf(field).copyWith(order: [MetaSourceKind.source]));
    }
    final future = service.resolveFields(const MetaQuery(title: '漫长的季节', year: 2023),
      source: Vod(vodId: 'local', vodName: '漫长的季节'), pipeline: pipeline);
    await started.future;
    service.clearCache();
    pending.complete(response({'photos': [{'image': {'large': {'url': 'https://img.example/stale.jpg'}}}]}));
    final result = await future;
    expect(result.providers, isEmpty); expect(result.primary, isNull);
  });

  test('comments never send another providers work id to Douban', () async {
    final requests = <String>[];
    final service = ExternalMetaService(douban: douban(MockClient((r) async {
      requests.add(r.url.path);
      return response({'interests': [{'comment': 'Correct provider comment'}], 'total': 1});
    })));
    addTearDown(service.close);
    for (final kind in [MetaSourceKind.tmdb, MetaSourceKind.bangumi, MetaSourceKind.wikidata]) {
      final page = await service.comments(MetaIdentity.of(kind, TmdbMediaType.tv, 42)!);
      expect(page.comments, isEmpty);
    }
    expect(requests, isEmpty, reason: 'a numeric work id is only valid in its own provider namespace');
    final page = await service.comments(MetaIdentity.of(MetaSourceKind.douban, TmdbMediaType.tv, 35588177)!);
    expect(page.comments.single.text, 'Correct provider comment');
    expect(requests, ['/rexxar/api/v2/tv/35588177/interests']);
  });

  test('comment completion cannot publish after service generation invalidation', () async {
    final started = Completer<void>(); final pending = Completer<http.Response>();
    final service = ExternalMetaService(douban: douban(MockClient((r) async {
      started.complete(); return pending.future;
    })));
    addTearDown(service.close);
    final future = service.comments(MetaIdentity.of(MetaSourceKind.douban, TmdbMediaType.tv, 35588177)!);
    await started.future;
    service.clearCache();
    pending.complete(response({'interests': [{'comment': 'Stale comment'}], 'total': 1}));
    expect((await future).comments, isEmpty);
  });

  test('field resolver honors pinned identity and keeps IMDb through photo aggregation', () async {
    var searches = 0;
    final service = ExternalMetaService(douban: douban(MockClient((r) async {
      if (r.url.path == '/j/subject_suggest') { searches++; return response(suggestion); }
      if (r.url.path.endsWith('/credits')) return response({'items': []});
      if (r.url.path.endsWith('/photos')) return response({'photos': [{'image': {'large': {'url': 'https://img.example/pinned.jpg'}}}]});
      return response({...subject, 'imdb': 'tt4574334'});
    })));
    addTearDown(service.close);
    var pipeline = MetaPipeline.defaults;
    for (final field in MetaField.values.where(MetaPipeline.supportsSource)) {
      pipeline = pipeline.withRule(pipeline.ruleOf(field).copyWith(order: [MetaSourceKind.source]));
    }
    final result = await service.resolveFields(const MetaQuery(title: '漫长的季节', year: 2023),
      source: Vod(vodId: 'local', vodName: 'Local title'), pipeline: pipeline,
      pinned: MetaIdentity.of(MetaSourceKind.douban, TmdbMediaType.tv, 35588177));
    expect(searches, 0);
    expect(result.effectivePipeline(pipeline).orderOf(MetaField.title).first, MetaSourceKind.douban);
    expect(result.primary?.data.photoUrls, ['https://img.example/pinned.jpg']);
    expect(result.primary?.imdbId, 'tt4574334');
  });

  test('field resolver disabled and invalidated requests cannot publish providers', () async {
    final pending = Completer<http.Response>();
    var enabled = false; var calls = 0;
    final service = ExternalMetaService(enabled: () => enabled, douban: douban(MockClient((r) async {
      calls++; return pending.future;
    })));
    addTearDown(service.close);
    final vod = Vod(vodId: 'local', vodName: '漫长的季节');
    final disabled = await service.resolveFields(const MetaQuery(title: '漫长的季节', year: 2023), source: vod, pipeline: MetaPipeline.defaults);
    expect(disabled.providers, isEmpty); expect(calls, 0);
    enabled = true;
    final future = service.resolveFields(const MetaQuery(title: '漫长的季节', year: 2023), source: vod, pipeline: MetaPipeline.defaults);
    await Future<void>.delayed(Duration.zero);
    service.clearCache();
    pending.complete(response(suggestion));
    final stale = await future;
    expect(stale.providers, isEmpty); expect(stale.primary, isNull); expect(calls, 1);
  });

  test('TMDB 有简介与演职员时不再请求豆瓣与 Bangumi', () async {
    var doubanCalls = 0;
    final service = ExternalMetaService(
      douban: douban(MockClient((r) async {
        doubanCalls++;
        return response(suggestion);
      })),
      tmdbDetail: () => const TmdbDetailData(
        mediaType: TmdbMediaType.tv,
        title: '漫长的季节',
        overview: 'TMDB 简介',
        cast: [TmdbPerson(personId: 1, name: '范伟')],
      ),
      tmdbIdentity: () => MetaIdentity.of(MetaSourceKind.tmdb, TmdbMediaType.tv, 999)!,
    );
    addTearDown(service.close);
    final loaded = await service.detail(const MetaQuery(title: '漫长的季节', year: 2023));
    expect(loaded?.identity.kind, MetaSourceKind.tmdb);
    expect(loaded?.data.overview, 'TMDB 简介');
    // 照片是聚合字段（TMDB + 豆瓣），因此豆瓣会被问一次用于剧照；
    // 但简介/演职员这类优先字段仍只取 TMDB，不被豆瓣覆盖。
    expect(doubanCalls, greaterThanOrEqualTo(0));
    expect(loaded!.data.overview, 'TMDB 简介');
  });

  test('剧照按聚合规则合并豆瓣照片并去重', () async {
    final service = ExternalMetaService(
      douban: douban(MockClient((r) async {
        if (r.url.path == '/j/subject_suggest') return response(suggestion);
        if (r.url.path.endsWith('/credits')) {
          return response({'items': [
          {'id': '1', 'name': '范伟', 'character': '演员 (饰 王响)', 'roles': ['演员']}]});
        }
        if (r.url.path.endsWith('/photos')) {
          return response({'total': 2, 'photos': [
          {'image': {'large': {'url': 'https://img.example/a.jpg'}}},
          {'image': {'large': {'url': 'https://img.example/b.jpg'}}}]});
        }
        return response(subject);
      })),
    );
    addTearDown(service.close);
    final loaded = await service.detail(const MetaQuery(title: '漫长的季节', year: 2023));
    expect(loaded!.data.photoUrls, contains('https://img.example/a.jpg'));
    expect(loaded.data.photoUrls, contains('https://img.example/b.jpg'));
  });

  test('人物简介为空时用 Wikidata 补一句，照片与作品不动', () async {
    final service = ExternalMetaService(
      douban: douban(MockClient((r) async {
        if (r.url.path.endsWith('/photos')) {
          return response({'total': 1, 'photos': [
          {'image': {'large': {'url': 'https://img.example/p.jpg'}}}]});
        }
        if (r.url.path.endsWith('/works')) {
          return response({'total': 1, 'works': [
          {'roles': ['演员'], 'work': {'id': '1', 'title': '漫长的季节', 'type': 'tv', 'year': '2023'}}]});
        }
        return response({'title': '范伟'});
      })),
      wikidata: WikidataService(
        baseUri: 'https://wikidata.test',
        delay: (_) async {},
        client: MockClient((r) async {
          if (r.url.path.contains('page/summary')) return response({'extract': '维基简介正文'});
          if (r.url.queryParameters['action'] == 'wbsearchentities') {
            return response({'search': [
              {'id': 'Q123', 'label': '范伟', 'description': '中国男演员'}]});
          }
          return response({'entities': {'Q123': {
            'descriptions': {'zh': {'value': '中国演员'}},
            'sitelinks': {'zhwiki': {'title': '范伟'}},}}});
        }),
      ),
    );
    addTearDown(service.close);
    final person = await service.person(
      const MetaPersonRef(kind: MetaSourceKind.douban, id: 1051526, name: '范伟'),
    );
    expect(person!.biography, contains('维基简介正文'));
    expect(person.photos, ['https://img.example/p.jpg']);
    expect(person.castWorks, hasLength(1));
  });

  test('Douban is preferred and all fallback requests work without TMDB credentials', () async {
    var bgmCalls=0;
    final service=ExternalMetaService(douban:douban(MockClient((r) async {
      if(r.url.path=='/j/subject_suggest') return response(suggestion);
      if(r.url.path.endsWith('/credits')) {
        return response({'items':[
        {'id':'1','name':'范伟','character':'演员 (饰 王响)','roles':['演员']}]});
      }
      return response(subject);
    })),bangumi:BangumiService(client:MockClient((_) async {
      bgmCalls++;return response({},500);
    }),minInterval:Duration.zero));
    addTearDown(service.close);
    final loaded=await service.detail(const MetaQuery(title:'漫长的季节',year:2023));
    expect(loaded?.identity.kind,MetaSourceKind.douban);
    expect(loaded?.data.overview,'豆瓣简介');
    expect(bgmCalls,0);
  });
  test('Bangumi 补上豆瓣缺的演职员（字段级优先链）', () async {
    final service=ExternalMetaService(douban:douban(MockClient((r) async {
      if(r.url.path=='/j/subject_suggest') return response(suggestion);
      if(r.url.path.endsWith('/credits')) return response({'items':[]});
      return response(subject);
    })),bangumi:BangumiService(client:MockClient((r) async {
      if(r.method=='POST') return response({'data':[{'id':431299,'name_cn':'漫长的季节','platform':'国产剧','date':'2023-04-22','eps':12}]});
      if(r.url.path.endsWith('/persons')) return response([{'id':7,'name':'范伟','relation':'主演'}]);
      return response({'id':431299,'name_cn':'漫长的季节','summary':'Bangumi 简介'});
    }),minInterval:Duration.zero));
    addTearDown(service.close);
    final loaded=await service.detail(const MetaQuery(title:'漫长的季节',year:2023));
    // 主来源仍是豆瓣（身份不变），只有空字段被 Bangumi 补上。
    expect(loaded?.identity.kind,MetaSourceKind.douban);
    expect(loaded?.data.cast.map((p)=>p.name),['范伟']);
  });

  test('Douban challenge falls back to Bangumi without aborting the page', () async {
    final service=ExternalMetaService(douban:douban(MockClient((_) async=>response({},403))),
      bangumi:BangumiService(client:MockClient((r) async {
        if(r.method=='POST') {
          return response({'data':[{'id':431299,'name_cn':'漫长的季节','name':'The Long Season',
          'type':6,'platform':'国产剧','date':'2023-04-22','eps':12}]});
        }
        if(r.url.path.endsWith('/persons')) return response([]);
        return response({'id':431299,'name_cn':'漫长的季节','summary':'Bangumi 简介'});
      }),minInterval:Duration.zero));
    addTearDown(service.close);
    final loaded=await service.detail(const MetaQuery(title:'漫长的季节',year:2023));
    expect(loaded?.identity.kind,MetaSourceKind.bangumi);
    expect(loaded?.data.overview,'Bangumi 简介');
  });
  test('failed auxiliary Bangumi credits do not discard the loaded subject', () async {
    final service=ExternalMetaService(bangumi:BangumiService(client:MockClient((r) async {
      if(r.method=='POST') return response({'data':[{'id':431299,'name_cn':'漫长的季节','platform':'国产剧','date':'2023-04-22','eps':12}]});
      if(r.url.path.endsWith('/persons')) return response({},503);
      return response({'id':431299,'name_cn':'漫长的季节','summary':'保留的简介'});
    }),minInterval:Duration.zero));
    addTearDown(service.close);
    final loaded=await service.detail(const MetaQuery(title:'漫长的季节',year:2023));
    expect(loaded?.data.overview,'保留的简介');
  });
  test('disabling while search is in flight stops subsequent requests and drops the result', () async {
    final pending=Completer<http.Response>();var calls=0;var enabled=true;
    final service=ExternalMetaService(enabled:()=>enabled,douban:douban(MockClient((r) async {
      calls++;
      if(r.url.path=='/j/subject_suggest') return pending.future;
      return response(subject);
    })));
    addTearDown(service.close);
    final future=service.detail(const MetaQuery(title:'漫长的季节',year:2023));
    await Future<void>.delayed(Duration.zero);
    enabled=false;
    pending.complete(response(suggestion));
    expect(await future,isNull);
    expect(calls,1);
  });
}
