import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/external_meta.dart';
import 'package:webhtv_pc/core/meta_source.dart';
import 'package:webhtv_pc/core/tmdb_config.dart';
import 'package:webhtv_pc/services/douban_recommendation_service.dart';
import 'package:webhtv_pc/services/external_meta_service.dart';
import 'package:webhtv_pc/services/tmdb_service.dart';

http.Response ok(Object body) => http.Response(jsonEncode(body), 200,
    headers: {'content-type': 'application/json; charset=utf-8'});

void main() {
  test('有 IMDb 编号时走确定性映射，不再按标题猜', () async {
    final temp = Directory.systemTemp.createTempSync('imdb-map');
    addTearDown(() => temp.deleteSync(recursive: true));
    var findCalls = 0;
    final tmdb = TmdbService(
      config: () => const TmdbConfig(apiKey: 'fixture'),
      client: MockClient((request) async {
        findCalls++;
        expect(request.url.path, contains('/find/tt4574334'));
        return ok({'movie_results': [], 'tv_results': [{'id': 66732}]});
      }),
    );
    addTearDown(tmdb.close);
    final douban = DoubanRecommendationService(
      cacheDirectory: temp,
      delay: (_) async {},
      client: MockClient((request) async {
        if (request.url.path == '/j/subject_suggest') {
          return ok([{'id': '1', 'title': '怪奇物语', 'year': '2016', 'episode': '8'}]);
        }
        if (request.url.path.endsWith('/credits')) return ok({'items': []});
        return ok({'title': '怪奇物语', 'imdb': 'tt4574334'});
      }),
    );
    final service = ExternalMetaService(douban: douban, tmdb: tmdb);
    addTearDown(service.close);
    final detail = await service.detail(const MetaQuery(title: '怪奇物语', year: 2016));
    expect(detail!.imdbId, 'tt4574334');
    final identity = await service.resolveIdentity(
      const MetaQuery(title: '怪奇物语', year: 2016),
      MetaSourceKind.tmdb,
      0,
    );
    expect(identity?.key, 'tmdb:tv:66732');
    expect(findCalls, 1);
  });
}