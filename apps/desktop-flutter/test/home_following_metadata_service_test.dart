import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/external_meta.dart';
import 'package:webhtv_pc/core/following.dart';
import 'package:webhtv_pc/core/meta_pipeline.dart';
import 'package:webhtv_pc/core/meta_source.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/tmdb_config.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/services/douban_recommendation_service.dart';
import 'package:webhtv_pc/services/external_meta_service.dart';
import 'package:webhtv_pc/services/home_art_service.dart';
import 'package:webhtv_pc/services/tmdb_service.dart';

Following following(String id, {int season = 0}) => Following(
  seriesKey: 'source:0:site:$id',
  season: season,
  siteKey: 'site',
  vodId: id,
  vodName: '漫长的季节',
  vodPic: 'https://source.example/poster.jpg',
);

MetaPipeline only(List<MetaSourceKind> order) {
  var pipeline = MetaPipeline.defaults;
  for (final field in MetaField.values) {
    pipeline = pipeline.withRule(pipeline.ruleOf(field).copyWith(order: order));
  }
  return pipeline;
}

TmdbService tmdb({TmdbConfig config = const TmdbConfig(apiKey: 'test-key')}) {
  final result = TmdbService(config: () => config);
  addTearDown(result.close);
  return result;
}

const item = TmdbItem(tmdbId: 42, mediaType: TmdbMediaType.tv, title: '漫长的季节');
const detail = <String, Object?>{
  'id': 42,
  'name': '漫长的季节',
  'poster_path': '/tmdb-poster.jpg',
  'backdrop_path': '/tmdb-backdrop.jpg',
  'overview': 'TMDB 简介',
  'genres': [
    {'id': 18, 'name': '剧情'},
  ],
  'first_air_date': '2023-04-22',
};

void main() {
  test('默认优先级下 TMDB 已填满展示字段时不读站源', () async {
    var sourceCalls = 0;
    final service = HomeMetaService(tmdb: tmdb(), loader: (_) async => detail);
    final row = following('show');
    final result = await service.resolveFollowings(
      [row],
      pipeline: only([MetaSourceKind.tmdb, MetaSourceKind.source]),
      match: (_) async => item,
      source: (_) async {
        sourceCalls++;
        return Vod(vodId: 'show', vodName: '漫长的季节');
      },
    );
    expect(sourceCalls, 0);
    expect(result[row.identityKey]!.backdrop, endsWith('/tmdb-backdrop.jpg'));
  });

  test('TMDB 缺展示字段时才读站源补齐', () async {
    var sourceCalls = 0;
    final service = HomeMetaService(
      tmdb: tmdb(),
      loader: (_) async => const {
        'id': 42,
        'name': '漫长的季节',
        'poster_path': '/tmdb-poster.jpg',
      },
    );
    final row = following('show');
    final result = await service.resolveFollowings(
      [row],
      pipeline: only([MetaSourceKind.tmdb, MetaSourceKind.source]),
      match: (_) async => item,
      source: (_) async {
        sourceCalls++;
        return Vod(
          vodId: 'show',
          vodName: '漫长的季节',
          vodContent: '站源简介',
          extra: {'type_name': '剧情'},
        );
      },
    );
    expect(sourceCalls, 1);
    expect(result[row.identityKey]!.overview, '站源简介');
    expect(result[row.identityKey]!.poster, endsWith('/tmdb-poster.jpg'));
  });

  test('类型聚合包含末位站源，不因 TMDB 已有类型而跳过', () async {
    final service = HomeMetaService(tmdb: tmdb(), loader: (_) async => detail);
    final base = only([MetaSourceKind.tmdb, MetaSourceKind.source]);
    final pipeline = base.withRule(
      base.ruleOf(MetaField.genres).copyWith(mode: MetaFieldMode.aggregate),
    );
    final row = following('show');
    final result = await service.resolveFollowings(
      [row],
      pipeline: pipeline,
      match: (_) async => item,
      source: (_) async =>
          Vod(vodId: 'show', vodName: '漫长的季节', extra: {'type_name': '悬疑'}),
    );
    expect(result[row.identityKey]!.genres, ['剧情', '悬疑']);
  });

  test('多季追剧共享身份详情，保留各自追剧键', () async {
    var calls = 0;
    var matches = 0;
    final service = HomeMetaService(
      tmdb: tmdb(),
      loader: (_) async {
        calls++;
        return detail;
      },
    );
    final a = following('show');
    final b = following('show', season: 2);
    final result = await service.resolveFollowings(
      [a, b],
      pipeline: only([MetaSourceKind.tmdb]),
      match: (_) async {
        matches++;
        return item;
      },
    );
    expect(calls, 1);
    expect(matches, 1);
    expect(result.keys.toSet(), {a.identityKey, b.identityKey});
    expect(result[a.identityKey]!.overview, 'TMDB 简介');
    expect(result[b.identityKey]!.poster, endsWith('/tmdb-poster.jpg'));
  });

  test('站源在 TMDB 后、豆瓣前时不跳过它的简介', () async {
    final temp = Directory.systemTemp.createTempSync('home-meta-middle-source');
    addTearDown(() => temp.deleteSync(recursive: true));
    final external = ExternalMetaService(
      douban: DoubanRecommendationService(
        cacheDirectory: temp,
        delay: (_) async {},
        client: MockClient((request) async {
          final Object body = request.url.path == '/j/subject_suggest'
              ? [
                  {
                    'id': '35588177',
                    'title': '漫长的季节',
                    'year': '2023',
                    'episode': '12',
                    'type': 'movie',
                  },
                ]
              : request.url.path.endsWith('/credits')
              ? {'items': []}
              : {
                  'id': '35588177',
                  'title': '漫长的季节',
                  'is_tv': true,
                  'type': 'tv',
                  'year': '2023',
                  'intro': '不应胜出的豆瓣简介',
                  'cover': {'url': 'https://douban.example/poster.jpg'},
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
    final service = HomeMetaService(
      tmdb: tmdb(),
      loader: (_) async => {...detail, 'overview': ''},
    );
    var sourceCalls = 0;
    final row = following('show');
    final result = await service.resolveFollowings(
      [row],
      pipeline: only([
        MetaSourceKind.tmdb,
        MetaSourceKind.source,
        MetaSourceKind.douban,
      ]),
      external: external,
      match: (_) async => item,
      source: (_) async {
        sourceCalls++;
        return Vod(
          vodId: 'show',
          vodName: '漫长的季节',
          vodContent: '中间优先级站源简介',
          vodYear: '2023',
          extra: {'type_name': '悬疑'},
        );
      },
    );
    expect(result[row.identityKey]!.overview, '中间优先级站源简介');
    expect(sourceCalls, 1);
  });

  for (final sourceFirst in [false, true]) {
    test('逐字段优先级选择正确来源（sourceFirst=$sourceFirst）', () async {
      final service = HomeMetaService(
        tmdb: tmdb(),
        loader: (_) async => detail,
      );
      final row = following('show');
      final result = await service.resolveFollowings(
        [row],
        pipeline: only(
          sourceFirst
              ? [MetaSourceKind.source, MetaSourceKind.tmdb]
              : [MetaSourceKind.tmdb, MetaSourceKind.source],
        ),
        match: (_) async => item,
        source: (_) async => Vod(
          vodId: 'show',
          vodName: '漫长的季节',
          vodPic: 'https://source.example/new.jpg',
          vodContent: '站源简介',
          vodYear: '2022',
          extra: {'type_name': '悬疑'},
        ),
      );
      final meta = result[row.identityKey]!;
      expect(meta.overview, sourceFirst ? '站源简介' : 'TMDB 简介');
      expect(
        meta.poster,
        sourceFirst
            ? 'https://source.example/new.jpg'
            : endsWith('/tmdb-poster.jpg'),
      );
      expect(
        meta.backdrop,
        sourceFirst ? isNull : endsWith('/tmdb-backdrop.jpg'),
      );
      expect(meta.year, sourceFirst ? '2022' : '2023');
    });
  }

  test('全部来源停用后不读站源、不匹配、不恢复原海报', () async {
    var calls = 0;
    final service = HomeMetaService(
      tmdb: tmdb(),
      loader: (_) async {
        calls++;
        return detail;
      },
    );
    final row = following('show');
    final result = await service.resolveFollowings(
      [row],
      pipeline: only([]),
      match: (_) async {
        calls++;
        return item;
      },
      source: (_) async {
        calls++;
        return null;
      },
    );
    expect(calls, 0);
    expect(result[row.identityKey]!.poster, isNull);
    expect(result[row.identityKey]!.backdrop, isNull);
    expect(result[row.identityKey]!.overview, isNull);
  });

  test('TMDB 关闭或站点被停用时不调用匹配与详情', () async {
    for (final config in [
      const TmdbConfig(),
      const TmdbConfig(apiKey: 'test', disabledSites: ['site']),
    ]) {
      var calls = 0;
      final row = following('show');
      final service = HomeMetaService(
        tmdb: tmdb(config: config),
        loader: (_) async {
          calls++;
          return detail;
        },
      );
      final result = await service.resolveFollowings(
        [row],
        pipeline: only([MetaSourceKind.tmdb, MetaSourceKind.source]),
        match: (_) async {
          calls++;
          return item;
        },
      );
      expect(calls, 0);
      expect(
        result[row.identityKey]!.poster,
        'https://source.example/poster.jpg',
      );
    }
  });

  test('单条匹配异常不影响其他追剧与站源兜底', () async {
    final service = HomeMetaService(tmdb: tmdb(), loader: (_) async => detail);
    final a = following('a');
    final b = following('b');
    final result = await service.resolveFollowings(
      [a, b],
      pipeline: only([MetaSourceKind.tmdb, MetaSourceKind.source]),
      match: (row) async {
        if (row.vodId == 'a') throw StateError('offline');
        return item;
      },
    );
    expect(result[a.identityKey]!.poster, 'https://source.example/poster.jpg');
    expect(result[b.identityKey]!.overview, 'TMDB 简介');
  });

  test('超时停止领取后续追剧，已返回快照不受迟到结果影响', () async {
    final pending = Completer<TmdbItem?>();
    var calls = 0;
    final service = HomeMetaService(tmdb: tmdb(), loader: (_) async => detail);
    final result = await service.resolveFollowings(
      [following('a'), following('b')],
      pipeline: only([MetaSourceKind.tmdb]),
      concurrency: 1,
      timeout: const Duration(milliseconds: 10),
      match: (_) {
        calls++;
        return pending.future;
      },
    );
    expect(result, isEmpty);
    pending.complete(item);
    await Future<void>.delayed(Duration.zero);
    expect(calls, 1);
    expect(result, isEmpty);
  });

  for (final pinned in [false, true]) {
    test('TMDB 不可用时按豆瓣补齐展示字段，不抓照片评论（pin=$pinned）', () async {
      final temp = Directory.systemTemp.createTempSync('home-meta-external');
      addTearDown(() => temp.deleteSync(recursive: true));
      final paths = <String>[];
      final external = ExternalMetaService(
        douban: DoubanRecommendationService(
          cacheDirectory: temp,
          delay: (_) async {},
          client: MockClient((request) async {
            paths.add(request.url.path);
            final Object body = request.url.path == '/j/subject_suggest'
                ? [
                    {
                      'id': '35588177',
                      'title': '漫长的季节',
                      'year': '2023',
                      'episode': '12',
                      'type': 'movie',
                    },
                  ]
                : request.url.path.endsWith('/credits')
                ? {'items': []}
                : {
                    'id': '35588177',
                    'title': '漫长的季节',
                    'is_tv': true,
                    'type': 'tv',
                    'year': '2023',
                    'intro': '豆瓣简介',
                    'genres': ['悬疑'],
                    'cover': {'url': 'https://douban.example/poster.jpg'},
                    'pubdate': ['2023-04-22(中国大陆)'],
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
      final service = HomeMetaService(tmdb: tmdb(config: const TmdbConfig()));
      final row = following('show');
      final result = await service.resolveFollowings(
        [row],
        pipeline: only([MetaSourceKind.douban, MetaSourceKind.source]),
        external: external,
        pinned: (_) => pinned
            ? MetaIdentity.of(MetaSourceKind.douban, TmdbMediaType.tv, 35588177)
            : null,
        match: (_) async => throw StateError('TMDB must stay off'),
      );
      expect(result[row.identityKey]!.overview, '豆瓣简介');
      expect(
        result[row.identityKey]!.poster,
        'https://douban.example/poster.jpg',
      );
      expect(
        paths.where((p) => p.endsWith('/photos') || p.contains('comments')),
        isEmpty,
      );
    });
  }
}
