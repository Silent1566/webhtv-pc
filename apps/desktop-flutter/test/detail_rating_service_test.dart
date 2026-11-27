import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/detail_ratings.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/services/detail_rating_service.dart';
import 'package:webhtv_pc/services/imdb_rating_service.dart';
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

const imdbPage = '''
<html><head><script type="application/ld+json">
{"@context":"https://schema.org","@type":"Movie","name":"X",
 "aggregateRating":{"@type":"AggregateRating","ratingValue":8.1,"ratingCount":12345}}
</script></head><body></body></html>''';

/// IMDb 直连 + OMDb 双通道：两条线分开计数，才能断言「该直连时恰一枪、
/// 不该直连时零枪」。
class ImdbHarness {
  ImdbHarness({this.doubanRating = 8.6});

  double doubanRating;
  Object? omdbResponse;

  /// IMDb 直连开关；默认开，保持既有用例契约。
  bool enabled = true;
  http.Response Function(http.Request request) onImdb = (request) =>
      jsonResponse({
        'data': {
          'title': {
            'ratingsSummary': {'aggregateRating': 8.1, 'voteCount': 12345},
          },
        },
      });

  final omdbRequests = <http.Request>[];
  final imdbRequests = <http.Request>[];

  Future<double> douban({
    required String title,
    required String mediaType,
    required int year,
  }) async => doubanRating;

  DetailRatingService service() => DetailRatingService(
    omdb: OmdbService(
      client: MockClient((request) async {
        omdbRequests.add(request);
        return jsonResponse(omdbResponse ?? omdbSuccessBody());
      }),
    ),
    imdb: ImdbRatingService(
      client: MockClient((request) async {
        imdbRequests.add(request);
        return onImdb(request);
      }),
    ),
    douban: douban,
    imdbEnabled: () => enabled,
  );
}

/// 记录 GraphQL 请求数的真实 ImdbRatingService（借用/自有释放测试用）。
class SharedImdb {
  int requests = 0;

  MockClient client() => MockClient((request) async {
    requests++;
    return jsonResponse({
      'data': {
        'title': {
          'ratingsSummary': {'aggregateRating': 7.6, 'voteCount': 1234},
        },
      },
    });
  });
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

  test('无 Key + 有效 imdbId：直连 IMDb 一次并合入评分', () async {
    final harness = ImdbHarness();
    final values = await harness.service().fetch(movie, omdbApiKey: '');

    expect(values.doubanRating, 8.6);
    expect(values.imdb, '8.1');
    expect(values.imdbVotes, '12,345');
    expect(harness.imdbRequests, hasLength(1));
    expect(
      harness.imdbRequests.single.url.toString(),
      'https://api.graphql.imdb.com/',
    );
    expect(harness.omdbRequests, isEmpty);
    expect(harness.imdbRequests.single.method, 'POST');
    expect(
      jsonDecode(harness.imdbRequests.single.body)['query'],
      contains('title(id: "tt1234567")'),
    );
  });

  test('OMDb 已给出 IMDb 分时不再直连 IMDb', () async {
    final harness = ImdbHarness();
    final values = await harness.service().fetch(movie, omdbApiKey: 'key');

    expect(values.imdb, '8.4');
    expect(values.imdbVotes, '1.2M');
    expect(harness.omdbRequests, hasLength(1));
    expect(harness.imdbRequests, isEmpty);
  });

  test('OMDb 200 但没有 IMDb 分时补一次直连', () async {
    final harness = ImdbHarness(doubanRating: 0)
      ..omdbResponse = {
        'Response': 'true',
        'imdbRating': 'N/A',
        'imdbVotes': 'N/A',
        'Metascore': 'N/A',
        'Ratings': [],
      };
    final values = await harness.service().fetch(movie, omdbApiKey: 'key');

    expect(values.imdb, '8.1');
    expect(values.imdbVotes, '12,345');
    expect(harness.omdbRequests, hasLength(1));
    expect(harness.imdbRequests, hasLength(1));
  });

  test('OMDb 返回 Response=false 时同样补一次直连', () async {
    final harness = ImdbHarness(doubanRating: 0)
      ..omdbResponse = {'Response': 'false', 'Error': 'Movie not found!'};
    final values = await harness.service().fetch(movie, omdbApiKey: 'key');

    expect(values.imdb, '8.1');
    expect(harness.imdbRequests, hasLength(1));
  });

  test('imdbId 为空或不合法时一次 IMDb 请求都不发', () async {
    final harness = ImdbHarness();
    final service = harness.service();

    final noId = await service.fetch(
      const DetailRatingRequest(tmdbId: 7, title: '另一部电影', year: 2021),
      omdbApiKey: '',
    );
    expect(noId.doubanRating, 8.6);
    expect(harness.imdbRequests, isEmpty);

    for (final id in ['xyz', 'tt12']) {
      await service.fetch(
        DetailRatingRequest(tmdbId: 7, title: '另一部电影', year: 2021, imdbId: id),
        omdbApiKey: '',
      );
    }
    expect(harness.imdbRequests, isEmpty);
  });

  test('IMDb 403 时退回空值，豆瓣分照常返回', () async {
    final harness = ImdbHarness()
      ..onImdb = ((request) => http.Response('blocked', 403));
    final values = await harness.service().fetch(movie, omdbApiKey: '');

    expect(values.doubanRating, 8.6);
    expect(values.imdb, isEmpty);
    expect(values.imdbVotes, isEmpty);
    expect(harness.imdbRequests, hasLength(2));
    expect(harness.imdbRequests.map((r) => r.method), ['POST', 'GET']);
  });

  test('缓存：命中后只发一次 IMDb 请求', () async {
    final harness = ImdbHarness();
    final service = harness.service();

    final first = await service.fetch(movie, omdbApiKey: '');
    final second = await service.fetch(movie, omdbApiKey: '');

    expect(first.imdb, '8.1');
    expect(second.imdb, '8.1');
    expect(harness.imdbRequests, hasLength(1));
    service.close();
  });

  test('IMDb 空结果不进缓存：两次调用各发 POST 与 GET', () async {
    final harness = ImdbHarness(doubanRating: 0)
      ..onImdb = ((request) => http.Response('blocked', 403));
    final service = harness.service();

    expect((await service.fetch(movie, omdbApiKey: '')).isEmpty, isTrue);
    expect((await service.fetch(movie, omdbApiKey: '')).isEmpty, isTrue);
    expect(harness.imdbRequests, hasLength(4));
    expect(harness.imdbRequests.map((r) => r.method), [
      'POST',
      'GET',
      'POST',
      'GET',
    ]);
  });

  test('禁用 IMDb：不发直连请求，OMDb 的 IMDb 分与人数也被滤掉，其它分照常', () async {
    final harness = ImdbHarness()..enabled = false;
    final service = harness.service();

    final noKey = await service.fetch(movie, omdbApiKey: '');
    expect(noKey.doubanRating, 8.6);
    expect(noKey.imdb, isEmpty);
    expect(harness.imdbRequests, isEmpty);

    final withKey = await service.fetch(movie, omdbApiKey: 'key');
    expect(withKey.imdb, isEmpty);
    expect(withKey.imdbVotes, isEmpty);
    expect(withKey.rottenTomatoes, '87%');
    expect(withKey.metacritic, '78/100');
    expect(withKey.doubanRating, 8.6);
    expect(harness.omdbRequests, hasLength(1));
    expect(harness.imdbRequests, isEmpty);
  });

  test('enabled→disabled→enabled：结果与计数，缓存键互不污染', () async {
    final harness = ImdbHarness();
    final service = harness.service();

    final on = await service.fetch(movie, omdbApiKey: '');
    expect(on.imdb, '8.1');
    expect(on.imdbVotes, '12,345');
    expect(harness.imdbRequests, hasLength(1));

    harness.enabled = false;
    final off = await service.fetch(movie, omdbApiKey: '');
    expect(off.imdb, isEmpty);
    expect(off.imdbVotes, isEmpty);
    expect(off.doubanRating, 8.6);
    expect(harness.imdbRequests, hasLength(1));

    harness.enabled = true;
    final back = await service.fetch(movie, omdbApiKey: '');
    expect(back.imdb, '8.1');
    expect(harness.imdbRequests, hasLength(1));
    service.close();
  });

  test('fromServices 借用共享实例：close 不关掉它，之后仍能取分', () async {
    final shared = SharedImdb();
    final imdb = ImdbRatingService(client: shared.client());
    final service = DetailRatingService.fromServices(
      client: shared.client(),
      imdb: imdb,
    );

    service.close();

    final rating = await imdb.byImdbId('tt1234567');
    expect(rating.value, '7.6');
    expect(shared.requests, 1);
    imdb.close();
  });

  test('fromServices 无注入时自建实例，并由 close 关闭', () async {
    final shared = SharedImdb();
    final service = DetailRatingService.fromServices(client: shared.client());
    final owned = service.imdb;

    expect(owned, isNotNull);
    service.close();

    expect((await owned!.byImdbId('tt1234567')).isEmpty, isTrue);
    expect(shared.requests, 0);
  });
}
