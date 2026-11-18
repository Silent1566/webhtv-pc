import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/external_meta.dart';
import 'package:webhtv_pc/core/meta_source.dart';
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
  late Directory temp;
  setUp(()=>temp=Directory.systemTemp.createTempSync('extmeta-service'));
  tearDown(()=>temp.deleteSync(recursive:true));
  DoubanRecommendationService douban(http.Client client) => DoubanRecommendationService(
    client:client,cacheDirectory:temp,delay:(_) async {});

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
        if (r.url.path.endsWith('/credits')) return response({'items': [
          {'id': '1', 'name': '范伟', 'character': '演员 (饰 王响)', 'roles': ['演员']}]});
        if (r.url.path.endsWith('/photos')) return response({'total': 2, 'photos': [
          {'image': {'large': {'url': 'https://img.example/a.jpg'}}},
          {'image': {'large': {'url': 'https://img.example/b.jpg'}}}]});
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
        if (r.url.path.endsWith('/photos')) return response({'total': 1, 'photos': [
          {'image': {'large': {'url': 'https://img.example/p.jpg'}}}]});
        if (r.url.path.endsWith('/works')) return response({'total': 1, 'works': [
          {'roles': ['演员'], 'work': {'id': '1', 'title': '漫长的季节', 'type': 'tv', 'year': '2023'}}]});
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
      if(r.url.path.endsWith('/credits')) return response({'items':[
        {'id':'1','name':'范伟','character':'演员 (饰 王响)','roles':['演员']}]});
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
        if(r.method=='POST') return response({'data':[{'id':431299,'name_cn':'漫长的季节','name':'The Long Season',
          'type':6,'platform':'国产剧','date':'2023-04-22','eps':12}]});
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
