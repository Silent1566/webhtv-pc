import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/external_meta.dart';
import 'package:webhtv_pc/core/home_feed.dart';
import 'package:webhtv_pc/core/meta_pipeline.dart';
import 'package:webhtv_pc/core/meta_source.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/tmdb_config.dart';
import 'package:webhtv_pc/core/tmdb_detail_model.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/services/douban_recommendation_service.dart';
import 'package:webhtv_pc/services/external_meta_service.dart';
import 'package:webhtv_pc/services/home_art_service.dart';
import 'package:webhtv_pc/services/storage.dart';
import 'package:webhtv_pc/services/tmdb_service.dart';

const imageBase = 'https://images.tmdb.org/t/p/w500';
const backdropBase = 'https://images.tmdb.org/t/p/w1280';
// 取自本轮真实缓存的公开图像字段：没有横图，只有一张1696×2528海报。
const posterOnly = <String, Object?>{
  'id': 336223,
  'name': '女友的妹妹：充满诱惑的三角关系',
  'backdrop_path': null,
  'poster_path': '/hhZx0mcYpKsWaz3r3FWT6octsXt.jpg',
  'images': {
    'backdrops': [],
    'posters': [
      {'file_path': '/hhZx0mcYpKsWaz3r3FWT6octsXt.jpg', 'width': 1696, 'height': 2528},
    ],
  },
  'overview': 'TMDB简介',
  'first_air_date': '2026-01-01',
  'genres': [
    {'id': 35, 'name': '喜剧'},
  ],
};

PlaybackHistory row({String mediaType = 'tv'}) => PlaybackHistory(
  id: 1,
  sourceKey: 'original-source',
  siteKey: 'original-site',
  vodId: 'atvp_detail:132095',
  vodName: '女友的妹妹：充满诱惑的三角关系',
  vodPic: 'https://resource.example/poster.jpg',
  vodYear: '2024',
  flag: 'quark',
  episodeName: '第1集',
  episodeId: 'original-entry',
  positionMs: 60000,
  durationMs: 780000,
  updatedAt: 123,
  tmdbId: 336223,
  mediaType: mediaType,
);

MetaPipeline only(List<MetaSourceKind> order) {
  var result = MetaPipeline.defaults;
  for (final field in MetaField.values) {
    result = result.withRule(result.ruleOf(field).copyWith(order: order));
  }
  return result;
}

TmdbService metadata({bool enabled = true}) {
  final service = TmdbService(
    config: () => TmdbConfig(
      enabled: enabled,
      apiKey: enabled ? 'fixture' : '',
      imageBase: imageBase,
      backdropBase: backdropBase,
    ),
  );
  addTearDown(service.close);
  return service;
}

void main() {
  test('真实poster-only字段：首页和详情使用相同背景，不再排除海报兜底', () async {
    final history = row();
    final service = HomeMetaService(
      tmdb: metadata(),
      loader: (_) async => posterOnly,
    );
    final resolved = await service.resolveHistory(
      [history],
      pipeline: only([MetaSourceKind.tmdb]),
      match: (_) async => throw StateError('known identity must not search again'),
    );
    const expected = '$imageBase/hhZx0mcYpKsWaz3r3FWT6octsXt.jpg';
    expect(resolved[homeHistoryKey(history)]!.backdrop, expected);
    final detail = TmdbDetailData.fromDetail(
      posterOnly,
      imageBase: imageBase,
      backdropBase: backdropBase,
    );
    expect(detail.backdropUrls.first, expected);
    expect(resolved[homeHistoryKey(history)]!.year, '2026');
    expect(history.sourceKey, 'original-source');
    expect(history.flag, 'quark');
    expect(history.positionMs, 60000);
    expect(history.updatedAt, 123);
  });

  test('资源源排在TMDB前时背景、海报、标题及年份都来自资源源', () async {
    final history = row();
    var sourceCalls = 0;
    final service = HomeMetaService(tmdb: metadata(), loader: (_) async => posterOnly);
    final resolved = await service.resolveHistory(
      [history],
      pipeline: only([MetaSourceKind.source, MetaSourceKind.tmdb]),
      match: (_) async => throw StateError('known identity must not search again'),
      source: (entry) async {
        expect(entry.sourceKey, 'original-source');
        sourceCalls++;
        return Vod(
          vodId: entry.vodId,
          vodName: '资源源标题',
          vodPic: 'https://resource.example/fresh.jpg',
          vodContent: '资源源简介',
          vodYear: '2025',
          extra: {'type_name': '家庭'},
        );
      },
    );
    final art = resolved[homeHistoryKey(history)]!;
    expect(sourceCalls, 1);
    expect(art.title, '资源源标题');
    expect(art.poster, 'https://resource.example/fresh.jpg');
    expect(art.backdrop, 'https://resource.example/fresh.jpg');
    expect(art.overview, '资源源简介');
    expect(art.year, '2025');
  });

  test('TMDB关闭仍按豆瓣字段链补背景，不抓照片评论', () async {
    final dir = Directory.systemTemp.createTempSync('home-history-fields');
    addTearDown(() => dir.deleteSync(recursive: true));
    final paths = <String>[];
    final external = ExternalMetaService(
      douban: DoubanRecommendationService(
        cacheDirectory: dir,
        delay: (_) async {},
        client: MockClient((request) async {
          paths.add(request.url.path);
          final Object body = request.url.path.endsWith('/credits')
              ? {'items': []}
              : {
                  'id': '38645936',
                  'title': '豆瓣标题',
                  'is_tv': true,
                  'type': 'tv',
                  'year': '2026',
                  'intro': '豆瓣简介',
                  'genres': ['家庭'],
                  'cover': {'url': 'https://douban.example/cover.jpg'},
                  'pubdate': ['2026-01-01(日本)'],
                };
          return http.Response(
            jsonEncode(body),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      ),
    );
    addTearDown(external.close);
    final history = row();
    final service = HomeMetaService(tmdb: metadata(enabled: false));
    final resolved = await service.resolveHistory(
      [history],
      pipeline: only([MetaSourceKind.douban, MetaSourceKind.source]),
      external: external,
      pinned: (_) => MetaIdentity.of(MetaSourceKind.douban, TmdbMediaType.tv, 38645936),
      match: (_) async => throw StateError('TMDB disabled must not match'),
    );
    final art = resolved[homeHistoryKey(history)]!;
    expect(art.title, '豆瓣标题');
    expect(art.overview, '豆瓣简介');
    expect(art.backdrop, 'https://douban.example/cover.jpg');
    expect(art.poster, 'https://douban.example/cover.jpg');
    expect(paths.where((p) => p.endsWith('/photos') || p.contains('comments')), isEmpty);
  });
}
