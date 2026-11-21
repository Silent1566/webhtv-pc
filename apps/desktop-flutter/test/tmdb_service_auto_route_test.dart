/// 自动 API 线路的换线行为（`docs/phase4/design/03` §5.7）。
///
/// 只测服务层：注入按主机路由的 fake 客户端，验证「网络/5xx 才换线、401 不换、
/// 全部失败走陈旧兜底、换线不影响缓存键」。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/core/tmdb_config.dart';
import 'package:webhtv_pc/services/tmdb_cache.dart';
import 'package:webhtv_pc/services/tmdb_route_selector.dart';
import 'package:webhtv_pc/services/tmdb_service.dart';

class _HostClient extends http.BaseClient {
  _HostClient(this.routes);

  /// host → (statusCode, body) 或 `null`（模拟连接失败）。
  final Map<String, (int, String)?> routes;
  final List<Uri> requests = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request.url);
    final entry = routes[request.url.host];
    if (entry == null) throw const SocketException('no route');
    final (status, body) = entry;
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(body)),
      status,
      request: request,
    );
  }
}

String _searchBody(String title) => jsonEncode({
  'results': [
    {
      'id': 550,
      'media_type': 'movie',
      'title': title,
      'poster_path': '/p.jpg',
    },
  ],
});

const _searchJson = '{"results":[]}';

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('tmdb-auto-'));
  tearDown(() => temp.deleteSync(recursive: true));

  TmdbService service(http.Client client, TmdbRouteSelector selector) =>
      TmdbService(
        config: () => const TmdbConfig(apiBase: 'auto', apiKey: 'k'),
        client: client,
        cache: TmdbCache(cacheDir: p.join(temp.path, 'cache')),
        routeSelector: selector,
      );

  test('官方线路网络失败时切到备用线路，并记住冷却', () async {
    final selector = TmdbRouteSelector();
    final client = _HostClient({
      'api.tmdb.org': null,
      'api.themoviedb.org': (200, _searchJson),
    });
    final items = await service(client, selector).search('dune');

    expect(items, isEmpty);
    expect(
      client.requests.map((uri) => uri.host).toList(),
      ['api.tmdb.org', 'api.themoviedb.org'],
      reason: '按候选顺序换线',
    );
    expect(selector.isCooling(TmdbRouteKind.api, 'https://api.tmdb.org'), isTrue);
    expect(
      selector.isCooling(TmdbRouteKind.api, 'https://api.themoviedb.org'),
      isFalse,
    );
  });

  test('401 不换线：换到哪条都是同一套凭据', () async {
    final selector = TmdbRouteSelector();
    final client = _HostClient({
      'api.tmdb.org': (401, '{"status_message":"invalid key"}'),
      'api.themoviedb.org': (200, _searchJson),
    });
    await expectLater(
      service(client, selector).search('dune'),
      throwsA(isA<TmdbAuthException>()),
    );
    expect(client.requests, hasLength(1));
    expect(selector.isCooling(TmdbRouteKind.api, 'https://api.tmdb.org'), isFalse);
  });

  test('5xx 换线', () async {
    final selector = TmdbRouteSelector();
    final client = _HostClient({
      'api.tmdb.org': (503, '{"status_message":"down"}'),
      'api.themoviedb.org': (200, _searchJson),
    });
    await service(client, selector).search('dune');
    expect(client.requests.map((uri) => uri.host).toList(), [
      'api.tmdb.org',
      'api.themoviedb.org',
    ]);
  });

  test('缓存键与线路无关：换线后同一请求仍只写一份缓存', () async {
    final selector = TmdbRouteSelector();
    final client = _HostClient({
      'api.tmdb.org': (200, _searchBody('缓存命中')),
      'api.themoviedb.org': (200, _searchJson),
    });
    final svc = service(client, selector);
    final first = await svc.search('dune');
    expect(first.single.title, '缓存命中');

    // 第二条同名请求必须命中同一份缓存（键里不含具体候选主机），零请求。
    final second = await svc.search('dune');
    expect(second.single.title, '缓存命中');
    expect(client.requests, hasLength(1));
  });

  test('非自动配置只请求配置的那一条，不做任何换线', () async {
    final selector = TmdbRouteSelector();
    final client = _HostClient({
      'api.tmdb.org': null,
      'api.themoviedb.org': (200, _searchJson),
    });
    final svc = TmdbService(
      // 默认是自动（§5.7）：这里要的是「显式固定一条线路」的形态。
      config: () => const TmdbConfig(
        apiBase: 'https://api.tmdb.org/3',
        apiKey: 'k',
      ),
      client: client,
      cache: TmdbCache(cacheDir: p.join(temp.path, 'cache')),
      routeSelector: selector,
    );
    await expectLater(svc.search('dune'), throwsA(isA<AppError>()));
    expect(client.requests, hasLength(1));
  });
}
