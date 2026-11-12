import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/detail_ratings.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/services/detail_rating_service.dart';
import 'package:webhtv_pc/services/omdb_service.dart';

const movie = DetailRatingRequest(
  tmdbId: 42,
  title: '示例电影',
  year: 2020,
  mediaType: TmdbMediaType.movie,
  imdbId: 'tt1234567',
);

Map<String, Object?> omdbSuccessBody() => {
  'Response': 'true',
  'Title': 'Example Movie',
  'imdbRating': '8.4',
  'imdbVotes': '1,234,567',
  'Metascore': '78',
  'Ratings': [
    {'Source': 'Rotten Tomatoes', 'Value': '87%'},
    {'Source': 'Metacritic', 'Value': '78/100'},
  ],
};

http.Response jsonResponse(Object body, {int status = 200}) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

/// 假豆瓣 + 计数 MockClient（OMDb），互不依赖，便于断言「谁发了几个请求」。
class Harness {
  Harness({this.doubanRating = 8.6});

  double doubanRating;
  bool doubanFails = false;
  bool networkFails = false;
  Object? omdbResponse;
  final requests = <http.Request>[];
  int doubanCalls = 0;
  ({String title, String mediaType, int year})? lastDouban;

  Future<double> douban({
    required String title,
    required String mediaType,
    required int year,
  }) async {
    doubanCalls++;
    lastDouban = (title: title, mediaType: mediaType, year: year);
    if (doubanFails) throw const SocketException('offline');
    return doubanRating;
  }

  MockClient client() => MockClient((request) async {
    requests.add(request);
    if (networkFails) throw const SocketException('offline');
    return jsonResponse(omdbResponse ?? omdbSuccessBody());
  });

  DetailRatingService service() => DetailRatingService(
    omdb: OmdbService(client: client()),
    douban: douban,
  );
}

void main() {
  test('没有 OMDb Key 时只查豆瓣，OMDb 一次都不请求', () async {
    final harness = Harness();
    final values = await harness.service().fetch(movie, omdbApiKey: '');

    expect(values.doubanRating, 8.6);
    expect(values.imdb, isEmpty);
    expect(harness.requests, isEmpty);
    expect(harness.doubanCalls, 1);
    expect(harness.lastDouban?.title, '示例电影');
    expect(harness.lastDouban?.mediaType, 'movie');
    expect(harness.lastDouban?.year, 2020);
  });

  test('有 imdbId 与 Key 时解析 OMDb 的 imdb / 烂番茄 / Metacritic', () async {
    final harness = Harness(doubanRating: 0);
    final values = await harness.service().fetch(movie, omdbApiKey: 'key');

    expect(values.doubanRating, 0);
    expect(values.imdb, '8.4');
    expect(values.imdbVotes, '1.2M');
    expect(values.rottenTomatoes, '87%');
    expect(values.metacritic, '78/100');
    expect(harness.requests, hasLength(1));
    final url = harness.requests.single.url;
    expect(url.host, 'www.omdbapi.com');
    expect(url.queryParameters['i'], 'tt1234567');
    expect(url.queryParameters['apikey'], 'key');
  });

  test('"N/A" 与 Response=false 都按未取得处理', () async {
    final na = Harness(doubanRating: 0)
      ..omdbResponse = {
        'Response': 'true',
        'imdbRating': 'N/A',
        'imdbVotes': 'N/A',
        'Metascore': 'N/A',
        'Ratings': [
          {'Source': 'Rotten Tomatoes', 'Value': 'N/A'},
          {'Source': 'Metacritic', 'Value': 'N/A'},
        ],
      };
    final naValues = await na.service().fetch(movie, omdbApiKey: 'key');
    expect(naValues.isEmpty, isTrue);
    expect(naValues.imdb, isEmpty);
    expect(naValues.imdbVotes, isEmpty);
    expect(naValues.rottenTomatoes, isEmpty);
    expect(naValues.metacritic, isEmpty);

    final failed = Harness(doubanRating: 0)
      ..omdbResponse = {'Response': 'false', 'Error': 'Movie not found!'};
    final failedValues = await failed.service().fetch(movie, omdbApiKey: 'key');
    expect(failedValues.isEmpty, isTrue);
    expect(failedValues.imdb, isEmpty);
    expect(failedValues.metacritic, isEmpty);
  });

  test('豆瓣与 OMDb 同时成功时合成一份结果', () async {
    final harness = Harness();
    final values = await harness.service().fetch(movie, omdbApiKey: 'key');

    expect(values.doubanRating, 8.6);
    expect(values.imdb, '8.4');
    expect(values.imdbVotes, '1.2M');
    expect(values.rottenTomatoes, '87%');
    expect(values.metacritic, '78/100');
    expect(harness.requests, hasLength(1));
    expect(harness.doubanCalls, 1);
  });

  test('网络异常时退回空值且不抛异常', () async {
    final harness = Harness()
      ..networkFails = true
      ..doubanFails = true;
    final values = await harness.service().fetch(movie, omdbApiKey: 'key');

    expect(values.isEmpty, isTrue);
    expect(values.doubanRating, 0);
    expect(values.imdb, isEmpty);
  });

  test('缓存：同一请求只查一次，换 Key 后必须重新请求', () async {
    final harness = Harness();
    final service = harness.service();

    final first = await service.fetch(movie, omdbApiKey: '');
    expect(first.doubanRating, 8.6);
    final second = await service.fetch(movie, omdbApiKey: '');
    expect(second.doubanRating, 8.6);
    expect(harness.requests, isEmpty);
    expect(harness.doubanCalls, 1);

    final withKey = await service.fetch(movie, omdbApiKey: 'key');
    expect(withKey.imdb, '8.4');
    expect(harness.requests, hasLength(1));
    expect(harness.doubanCalls, 2);

    await service.fetch(movie, omdbApiKey: 'key');
    expect(harness.requests, hasLength(1));
    expect(harness.doubanCalls, 2);
    service.close();
  });

  test('request.isEmpty 时一个请求都不发', () async {
    final harness = Harness();
    final values = await harness.service().fetch(
      const DetailRatingRequest(),
      omdbApiKey: 'key',
    );

    expect(values.isEmpty, isTrue);
    expect(harness.requests, isEmpty);
    expect(harness.doubanCalls, 0);
  });

  test('没有 imdbId 时即使有 Key 也不打 OMDb', () async {
    final harness = Harness();
    final values = await harness.service().fetch(
      const DetailRatingRequest(tmdbId: 7, title: '另一部电影', year: 2021),
      omdbApiKey: 'key',
    );

    expect(values.doubanRating, 8.6);
    expect(harness.requests, isEmpty);
  });
}
