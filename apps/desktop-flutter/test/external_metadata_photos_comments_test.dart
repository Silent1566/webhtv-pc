import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/external_detail_meta.dart';
import 'package:webhtv_pc/core/external_meta.dart';
import 'package:webhtv_pc/core/meta_source.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/services/douban_recommendation_service.dart';

http.Response json(Object v) => http.Response(jsonEncode(v), 200,
  headers: {'content-type': 'application/json; charset=utf-8'});

void main() {
  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('extmeta-photos'));
  tearDown(() => temp.deleteSync(recursive: true));

  DoubanRecommendationService service(List<Object> log) =>
      DoubanRecommendationService(
        cacheDirectory: temp,
        delay: (_) async {},
        client: MockClient((request) async {
          log.add(request.url.path);
          if (request.url.path.endsWith('/photos')) {
            return json({
              'total': 273,
              'photos': [
                {'image': {'large': {'url': 'https://img.example/a.jpg'}}},
                {'image': {'large': {'url': 'https://img.example/b.jpg'},
                           'normal': {'url': 'https://img.example/b-normal.jpg'}}},
                {'image': {}},
              ],
            });
          }
          if (request.url.path.endsWith('/interests')) {
            return json({
              'total': 413365,
              'interests': [
                {'comment': '节奏慢但后劲足', 'create_time': '2023-04-23 02:10:44',
                 'vote_count': 12, 'rating': {'value': 5},
                 'user': {'name': '江户川乱跑'}},
                {'comment': '', 'user': {'name': '空评论'}},
              ],
            });
          }
          if (request.url.path.endsWith('/works')) {
            return json({'total': 1, 'works': [
              {'roles': ['演员 (饰 王响)'], 'work': {'id': '1', 'title': '漫长的季节',
                'type': 'tv', 'year': '2023', 'rating': {'value': 9.4}}},
            ]});
          }
          return json({'title': '范伟'});
        }),
      );

  test('album returns every photo once and skips empty entries', () async {
    final calls = <Object>[];
    final urls = await service(calls).metaCelebrityPhotos(1051526);
    expect(urls, ['https://img.example/a.jpg', 'https://img.example/b.jpg']);
  });

  test('comments keep text rating and votes and drop empty bodies', () async {
    final calls = <Object>[];
    final raw = await service(calls).metaInterests(35588177, isTv: true);
    final comments = externalComments(raw.items,
      source: MetaSourceKind.douban, total: raw.total).comments;
    expect(comments, hasLength(1));
    expect(comments.single.author, '江户川乱跑');
    expect(comments.single.rating, 5);
    expect(comments.single.maxRating, 5.0);
    expect(comments.single.ratingOutOfTen, 10.0);
    expect(comments.single.sourceLabel, '豆瓣');
    expect(comments.single.votes, 12);
    expect(calls.single, contains('/tv/35588177/interests'));
  });

  test('person page shows the whole album and the IMDB label is upper case', () async {
    final detail = ExternalPersonMeta.douban(
      ref: const MetaPersonRef(kind: MetaSourceKind.douban, id: 1051526),
      celebrity: {
        'title': '范伟',
        'extra': {'info': [['IMDB编号', 'nm1981215'], ['出生地', '中国,辽宁,沈阳']]},
        'photos': [
          {'image': {'large': {'url': 'https://img.example/1.jpg'}}},
          {'image': {'large': {'url': 'https://img.example/2.jpg'}}},
          {'image': {'large': {'url': 'https://img.example/3.jpg'}}},
        ],
      },
      works: [
        {'roles': ['演员 (饰 王响)'], 'work': {'id': '1', 'title': '漫长的季节',
          'type': 'tv', 'year': '2023', 'rating': {'value': 9.4}}},
      ],
    )!;
    expect(detail.photos, hasLength(3));
    expect(detail.department, contains('IMDB编号：nm1981215'));
    expect(detail.department.contains('IMDb'), isFalse);
  });

  test('Bangumi portrait stays first and extra photos follow', () {
    final detail = ExternalPersonMeta.bangumi(
      ref: const MetaPersonRef(kind: MetaSourceKind.bangumi, id: 46517),
      person: {'name': 'Millie', 'images': {'large': 'https://bgm.example/1.jpg'},
        'summary': '简介'},
      subjects: const [],
      extraPhotos: const ['https://bgm.example/2.jpg'],
    )!;
    expect(detail.photos, ['https://bgm.example/1.jpg', 'https://bgm.example/2.jpg']);
  });

  test('identity drives the interest endpoint choice', () async {
    final calls = <Object>[];
    final douban = service(calls);
    await douban.metaInterests(42, isTv: false);
    await douban.metaInterests(42, isTv: true);
    expect(calls.whereType<String>().toList(),
      ['/rexxar/api/v2/movie/42/interests', '/rexxar/api/v2/tv/42/interests']);
  });
}
