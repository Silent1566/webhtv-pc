import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/services/imdb_rating_service.dart';
import 'package:webhtv_pc/services/log_service.dart';

/// JSON-LD 形状的 IMDb 标题页：真实页面的 `aggregateRating` 就挂在 ld+json 块里。
const imdbPage = '''
<html><head><script type="application/ld+json">
{"@context":"https://schema.org","@type":"Movie","name":"X",
 "aggregateRating":{"@type":"AggregateRating","ratingValue":8.1,"ratingCount":12345}}
</script></head><body></body></html>''';

/// 计数 MockClient：既断言「发了几枪」，也抓请求头与 URL。
class Transport {
  Transport(this.onRequest);

  Future<http.Response> Function(http.Request request) onRequest;
  final requests = <http.Request>[];

  MockClient client() => MockClient((request) {
    requests.add(request);
    return onRequest(request);
  });
}

http.Response graphqlResponse(num value, int votes) => http.Response(
  jsonEncode({
    'data': {
      'title': {
        'ratingsSummary': {'aggregateRating': value, 'voteCount': votes},
      },
    },
  }),
  200,
);

void main() {
  test('抓标题页并解析分值，请求带桌面 Chrome UA 与 en-US', () async {
    final transport = Transport((_) async => http.Response(imdbPage, 200));
    final rating = await ImdbRatingService(client: transport.client())
        .byImdbId('tt0133093');

    expect(rating.value, '8.1');
    expect(rating.votes, '12,345');
    expect(transport.requests, hasLength(2));
    final request = transport.requests.last;
    expect(request.method, 'GET');
    expect(request.url.toString(), 'https://www.imdb.com/title/tt0133093/');
    expect(request.headers['user-agent'], contains('Chrome'));
    expect(request.headers['user-agent'], contains('Windows NT'));
    expect(request.headers['accept-language'], 'en-US,en;q=0.9');
  });

  test('imdbId 不合法时一次都不请求', () async {
    final transport = Transport((_) async => http.Response(imdbPage, 200));
    final service = ImdbRatingService(client: transport.client());

    for (final id in ['', '   ', 'xyz', 'tt12', 'tt123456']) {
      expect((await service.byImdbId(id)).isEmpty, isTrue, reason: id);
      expect((await service.byImdbId(' $id ')).isEmpty, isTrue, reason: id);
    }
    expect(transport.requests, isEmpty);
  });

  test('baseUrl 没有 scheme/host 时不发请求', () async {
    final transport = Transport((_) async => http.Response(imdbPage, 200));
    final service = ImdbRatingService(
      client: transport.client(),
      baseUrl: '/title-only',
    );

    expect((await service.byImdbId('tt0133093')).isEmpty, isTrue);
    expect(transport.requests, isEmpty);
  });

  test('403 阻断页返回空值且不抛', () async {
    final transport = Transport((_) async => http.Response('blocked', 403));
    final rating = await ImdbRatingService(client: transport.client())
        .byImdbId('tt0133093');

    expect(rating.isEmpty, isTrue);
    expect(rating.votes, isEmpty);
    expect(transport.requests, hasLength(2));
  });

  test('超时返回空值且不抛', () async {
    final transport = Transport((_) async {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      return http.Response(imdbPage, 200);
    });
    final rating = await ImdbRatingService(
      client: transport.client(),
      timeout: const Duration(milliseconds: 10),
    ).byImdbId('tt0133093');

    expect(rating.isEmpty, isTrue);
    expect(transport.requests, hasLength(2));
  });

  test('没有分值的页面（机器人页 / 非 JSON）返回空值', () async {
    final transport = Transport(
      (_) async => http.Response('<html>robot check</html>', 200),
    );
    final rating = await ImdbRatingService(client: transport.client())
        .byImdbId('tt0133093');

    expect(rating.isEmpty, isTrue);
  });

  test('响应体超过 4MB 时按失败处理', () async {
    final huge = '${'a' * (ImdbRatingService.maxBytes + 1)}$imdbPage';
    final transport = Transport((_) async => http.Response(huge, 200));
    final rating = await ImdbRatingService(client: transport.client())
        .byImdbId('tt0133093');

    expect(rating.isEmpty, isTrue);
    expect(transport.requests, hasLength(2));
  });

  test('GraphQL 成功只发一次 POST 并解析 7.6 / 1,234', () async {
    final transport = Transport(
      (_) async => http.Response(
        jsonEncode({
          'data': {
            'title': {
              'ratingsSummary': {'aggregateRating': 7.6, 'voteCount': 1234},
            },
          },
        }),
        200,
      ),
    );
    final rating = await ImdbRatingService(client: transport.client())
        .byImdbId(' tt34852924 ');

    expect(rating.value, '7.6');
    expect(rating.votes, '1,234');
    expect(transport.requests, hasLength(1));
    final request = transport.requests.single;
    expect(request.method, 'POST');
    expect(request.url.toString(), 'https://api.graphql.imdb.com/');
    expect(request.headers['content-type'], contains('application/json'));
    expect(request.headers['x-imdb-client-name'], 'imdb-web-next');
    expect(
      request.headers['accept'],
      'application/graphql-response+json, application/json',
    );
    expect(request.headers['user-agent'], contains('Chrome'));
    expect(jsonDecode(request.body), {
      'query': 'query { title(id: "tt34852924") { ratingsSummary { aggregateRating voteCount } } }',
    });
  });

  test('GraphQL 202/挑战页/非法 JSON 时只补一次 HTML GET', () async {
    for (final response in [
      http.Response('<html>challenge</html>', 202),
      http.Response('<html>challenge</html>', 200),
      http.Response('{broken', 200),
      http.Response('blocked', 403),
    ]) {
      final transport = Transport(
        (request) async =>
            request.method == 'POST' ? response : http.Response(imdbPage, 200),
      );
      final rating = await ImdbRatingService(client: transport.client())
          .byImdbId('tt0133093');
      expect(rating.value, '8.1');
      expect(rating.votes, '12,345');
      expect(transport.requests, hasLength(2));
      expect(transport.requests.map((r) => r.method), ['POST', 'GET']);
      expect(
        transport.requests.last.url.toString(),
        'https://www.imdb.com/title/tt0133093/',
      );
    }
  });

  test('GraphQL title null/errors/无 data 且 HTML 403 时返回空', () async {
    for (final body in [
      {
        'data': {'title': null},
      },
      {
        'errors': [
          {'message': 'not found'},
        ],
      },
      <String, Object?>{},
      {
        'data': {
          'title': {
            'ratingsSummary': {'aggregateRating': 0, 'voteCount': 1234},
          },
        },
      },
    ]) {
      final transport = Transport(
        (request) async => request.method == 'POST'
            ? http.Response(jsonEncode(body), 200)
            : http.Response('blocked', 403),
      );
      final rating = await ImdbRatingService(client: transport.client())
          .byImdbId('tt0133093');
      expect(rating.isEmpty, isTrue);
      expect(rating.votes, isEmpty);
      expect(transport.requests, hasLength(2));
    }
  });

  test('GraphQL 与 HTML 地址独立注入，失败只兜底到注入 HTML 地址', () async {
    final transport = Transport(
      (request) async => request.method == 'POST'
          ? http.Response('{}', 200)
          : http.Response(imdbPage, 200),
    );
    final rating = await ImdbRatingService(
      client: transport.client(),
      baseUrl: 'https://html.fixture/imdb/',
      graphqlUrl: 'https://graphql.fixture/api',
    ).byImdbId('tt34852924');
    expect(rating.value, '8.1');
    expect(transport.requests.map((r) => r.url.toString()), [
      'https://graphql.fixture/api',
      'https://html.fixture/imdb/title/tt34852924/',
    ]);
  });

  test('任一端点非法时都零请求', () async {
    for (final bad in ['', '/relative', 'ftp://host', 'https://']) {
      final transport = Transport((_) async => http.Response(imdbPage, 200));
      expect(
        (await ImdbRatingService(
          client: transport.client(),
          baseUrl: bad,
        ).byImdbId('tt34852924')).isEmpty,
        isTrue,
      );
      expect(
        (await ImdbRatingService(
          client: transport.client(),
          graphqlUrl: bad,
        ).byImdbId('tt34852924')).isEmpty,
        isTrue,
      );
      expect(transport.requests, isEmpty, reason: bad);
    }
  });

  test('GraphQL 超时或超过 4MB 时仍可由 HTML 成功兜底', () async {
    for (final delayed in [false, true]) {
      final transport = Transport((request) async {
        if (request.method == 'GET') return http.Response(imdbPage, 200);
        if (delayed) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        return http.Response(
          jsonEncode({
            'data': {
              'title': {
                'ratingsSummary': {'aggregateRating': 7.6, 'voteCount': 1234},
              },
            },
            'padding': 'x' * (ImdbRatingService.maxBytes + 1),
          }),
          200,
        );
      });
      final rating = await ImdbRatingService(
        client: transport.client(),
        timeout: const Duration(milliseconds: 10),
      ).byImdbId('tt34852924');
      expect(rating.value, '8.1');
      expect(transport.requests, hasLength(2));
    }
  });

  test('同一 ID 并发查询只发一轮请求，结果共享', () async {
    final transport = Transport((_) async {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      return graphqlResponse(7.6, 1234);
    });
    final service = ImdbRatingService(client: transport.client());

    final ratings = await Future.wait([
      service.byImdbId('tt34852924'),
      service.byImdbId(' tt34852924 '),
      service.byImdbId('tt34852924'),
    ]);

    for (final rating in ratings) {
      expect(rating.value, '7.6');
      expect(rating.votes, '1,234');
      expect(identical(rating, ratings.first), isTrue);
    }
    expect(transport.requests, hasLength(1));
  });

  test('成功结果按 trim 后的 ID 缓存：顺序调用只发一次请求', () async {
    final transport = Transport((_) async => graphqlResponse(7.6, 1234));
    final service = ImdbRatingService(client: transport.client());

    expect((await service.byImdbId('tt34852924')).value, '7.6');
    expect((await service.byImdbId('  tt34852924  ')).votes, '1,234');

    expect(transport.requests, hasLength(1));
  });

  test('空结果不进缓存：失败后下一次可重试成功', () async {
    var failing = true;
    final transport = Transport(
      (_) async =>
          failing ? http.Response('blocked', 403) : graphqlResponse(7.6, 1234),
    );
    final service = ImdbRatingService(client: transport.client());

    expect((await service.byImdbId('tt34852924')).isEmpty, isTrue);
    expect(transport.requests, hasLength(2));

    failing = false;
    final retry = await service.byImdbId('tt34852924');
    expect(retry.value, '7.6');
    expect(transport.requests, hasLength(3));
  });

  test('不同 ID 不串缓存', () async {
    final transport = Transport((request) async {
      final query = (jsonDecode(request.body) as Map)['query'] as String;
      return query.contains('tt1111111')
          ? graphqlResponse(7.0, 100)
          : graphqlResponse(9.1, 200);
    });
    final service = ImdbRatingService(client: transport.client());

    expect((await service.byImdbId('tt1111111')).value, '7.0');
    expect((await service.byImdbId('tt2222222')).value, '9.1');
    expect((await service.byImdbId('tt1111111')).votes, '100');
    expect((await service.byImdbId('tt2222222')).votes, '200');
    expect(transport.requests, hasLength(2));
  });

  test('缓存最多 64 项：第 65 个 ID 挤掉最早的条目', () async {
    final transport = Transport((_) async => graphqlResponse(7.6, 1234));
    final service = ImdbRatingService(client: transport.client());

    for (var i = 0; i < ImdbRatingService.maxCacheEntries + 1; i++) {
      await service.byImdbId('tt${1000000 + i}');
    }
    expect(transport.requests, hasLength(65));

    // 被挤掉的第一个 ID 需要重查，重查后的插入又会挤掉下一个。
    await service.byImdbId('tt1000000');
    expect(transport.requests, hasLength(66));
    // 仍在缓存里的近期条目不再发请求。
    await service.byImdbId('tt1000064');
    expect(transport.requests, hasLength(66));
  });

  test('close 清空缓存与在途状态：关闭后在途与后续查询都不再给分', () async {
    final transport = Transport((_) async {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      return graphqlResponse(7.6, 1234);
    });
    final service = ImdbRatingService(client: transport.client());

    final pending = service.byImdbId('tt34852924');
    service.close();

    expect((await pending).isEmpty, isTrue);
    expect((await service.byImdbId('tt34852924')).isEmpty, isTrue);
    expect(transport.requests, hasLength(1));
  });

  test('200 无评分是正常空值不写 warning，HTTP/解析异常才写', () async {
    final quietLog = LogService();
    final quiet = Transport(
      (request) async => request.method == 'POST'
          ? http.Response(
              jsonEncode({
                'data': {'title': null},
              }),
              200,
            )
          : http.Response('<html>no rating</html>', 200),
    );
    expect(
      (await ImdbRatingService(
        client: quiet.client(),
        log: quietLog,
      ).byImdbId('tt34852924')).isEmpty,
      isTrue,
    );
    expect(quietLog.entries.where((e) => e.level == LogLevel.warning), isEmpty);
    await quietLog.dispose();

    final noisyLog = LogService();
    final noisy = Transport((_) async => http.Response('blocked', 403));
    await ImdbRatingService(
      client: noisy.client(),
      log: noisyLog,
    ).byImdbId('tt34852924');
    expect(
      noisyLog.entries.where((e) => e.level == LogLevel.warning),
      isNotEmpty,
    );
    await noisyLog.dispose();
  });
}
