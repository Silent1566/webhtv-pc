import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/tmdb_config.dart';
import 'package:webhtv_pc/services/tmdb_service.dart';

http.Response ok(Object body) => http.Response(jsonEncode(body), 200,
    headers: {'content-type': 'application/json; charset=utf-8'});

void main() {
  test('IMDb 编号解析出电影身份，并带上 external_source', () async {
    var calls = 0;
    final service = TmdbService(
      config: () => const TmdbConfig(apiKey: 'fixture'),
      client: MockClient((request) async {
        calls++;
        expect(request.url.path, contains('/find/tt0133093'));
        expect(request.url.queryParameters['external_source'], 'imdb_id');
        return ok({'movie_results': [{'id': 603}], 'tv_results': []});
      }),
    );
    addTearDown(service.close);
    expect((await service.findByImdbId('tt0133093'))?.key, 'movie:603');
    expect(calls, 1);
  });

  test('只有电视剧结果时解析出剧集身份', () async {
    final service = TmdbService(
      config: () => const TmdbConfig(apiKey: 'fixture'),
      client: MockClient((_) async => ok({
        'movie_results': [],
        'tv_results': [{'id': 66732}],
      })),
    );
    addTearDown(service.close);
    expect((await service.findByImdbId('tt4574334'))?.key, 'tv:66732');
  });

  test('非法编号与未配置时一次都不请求', () async {
    var calls = 0;
    final configured = TmdbService(
      config: () => const TmdbConfig(apiKey: 'fixture'),
      client: MockClient((_) async {
        calls++;
        return ok({});
      }),
    );
    addTearDown(configured.close);
    expect(await configured.findByImdbId('n/a'), isNull);
    expect(await configured.findByImdbId(''), isNull);
    expect(calls, 0);

    final unconfigured = TmdbService(
      config: () => const TmdbConfig(),
      client: MockClient((_) async {
        calls++;
        return ok({});
      }),
    );
    addTearDown(unconfigured.close);
    expect(await unconfigured.findByImdbId('tt0133093'), isNull);
    expect(calls, 0);
  });

  test('没有匹配结果时返回 null', () async {
    final service = TmdbService(
      config: () => const TmdbConfig(apiKey: 'fixture'),
      client: MockClient((_) async => ok({
        'movie_results': [],
        'tv_results': [],
      })),
    );
    addTearDown(service.close);
    expect(await service.findByImdbId('tt9999999'), isNull);
  });
}