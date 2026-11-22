/// 首页取图服务单测：钉死失败隔离与并发口径，全程不联网。
///
/// 用注入的 loader 而不是 MockClient：本服务只负责「按身份取图 + 失败隔离」，
/// 缓存与 HTTP 是 `TmdbService` 的契约，在这里再打一遍桩只会测到别人。
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/tmdb_config.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/services/home_art_service.dart';
import 'package:webhtv_pc/services/tmdb_service.dart';

const String imageBase = 'https://image.tmdb.org/t/p/w500';
const String backdropBase = 'https://image.tmdb.org/t/p/w780';

TmdbIdentity tv(int id) => TmdbIdentity.of(TmdbMediaType.tv, id)!;
TmdbIdentity movie(int id) => TmdbIdentity.of(TmdbMediaType.movie, id)!;

/// 造一份详情：`images` 段带横竖两套，根级路径用来模拟「只有 poster_path」。
Map<String, Object?> detail({
  List<String> posters = const [],
  List<String> backdrops = const [],
  String? posterPath,
  String? backdropPath,
}) => {
  'id': 1,
  'images': {
    'posters': [
      for (final path in posters)
        {
          'file_path': path,
          'width': 1000,
          'height': 1500,
          'vote_average': 5.0,
          'vote_count': 10,
        },
    ],
    'backdrops': [
      for (final path in backdrops)
        {
          'file_path': path,
          'width': 1920,
          'height': 1080,
          'vote_average': 5.0,
          'vote_count': 10,
        },
    ],
  },
  'poster_path': ?posterPath,
  'backdrop_path': ?backdropPath,
};

/// 只提供 `imageBase` / `backdropBase`：注入 loader 后一次网络都不会发生。
TmdbService fakeTmdb() {
  final tmdb = TmdbService(
    config: () => const TmdbConfig(
      apiKey: 'test-key',
      imageBase: imageBase,
      backdropBase: backdropBase,
    ),
  );
  addTearDown(tmdb.close);
  return tmdb;
}

void main() {
  test('成功一条：按 TMDB 身份拼出 16:9 背景与 2:3 海报', () async {
    final service = HomeMetaService(
      tmdb: fakeTmdb(),
      loader: (identity) async =>
          detail(posters: ['/p1.jpg'], backdrops: ['/b1.jpg']),
    );

    final art = await service.resolve({'site-a|1': tv(1399)});

    expect(art.keys, ['site-a|1']);
    expect(art['site-a|1']!.poster, '$imageBase/p1.jpg');
    expect(art['site-a|1']!.backdrop, '$backdropBase/b1.jpg');
  });

  test('失败一条只丢自己：其余条目仍然有图', () async {
    final service = HomeMetaService(
      tmdb: fakeTmdb(),
      loader: (identity) async {
        if (identity.tmdbId == 2) throw StateError('boom');
        return detail(posters: ['/p.jpg'], backdrops: ['/b.jpg']);
      },
    );

    final art = await service.resolve({'a': tv(1), 'b': tv(2), 'c': tv(3)});

    expect(art.keys.toSet(), {'a', 'c'});
    expect(art['a']!.backdrop, '$backdropBase/b.jpg');
  });

  test('同一身份被多个 key 引用只请求一次', () async {
    final requested = <String>[];
    final service = HomeMetaService(
      tmdb: fakeTmdb(),
      loader: (identity) async {
        requested.add(identity.key);
        return detail(posters: ['/p.jpg'], backdrops: ['/b.jpg']);
      },
    );

    final art = await service.resolve({
      'vod-1': tv(1399),
      'vod-2': tv(1399),
      'other': tv(2),
    });

    expect(requested, ['tv:1399', 'tv:2']);
    expect(art.keys.toSet(), {'vod-1', 'vod-2', 'other'});
    // 同一身份共享同一份结果，不是每个 key 各拼一次。
    expect(identical(art['vod-1'], art['vod-2']), isTrue);
  });

  test('并发不超过 concurrency', () async {
    var active = 0;
    var maxActive = 0;
    var calls = 0;
    final service = HomeMetaService(
      tmdb: fakeTmdb(),
      loader: (identity) async {
        calls++;
        active++;
        if (active > maxActive) maxActive = active;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        active--;
        return detail(posters: ['/p.jpg'], backdrops: ['/b.jpg']);
      },
    );

    final art = await service.resolve({
      for (var i = 1; i <= 5; i++) 'k$i': tv(i),
    });

    expect(calls, 5);
    expect(art.length, 5);
    expect(maxActive, lessThanOrEqualTo(2));
    // 不是被压成串行：两个槽位确实同时在飞。
    expect(maxActive, 2);
  });

  test('超时返回已经拿到的部分', () async {
    // 永不完成：模拟卡住的请求。
    final hanging = Completer<Map<String, Object?>>();
    final service = HomeMetaService(
      tmdb: fakeTmdb(),
      loader: (identity) {
        if (identity.tmdbId == 1) {
          return Future<Map<String, Object?>>.value(
            detail(posters: ['/p.jpg'], backdrops: ['/b.jpg']),
          );
        }
        return hanging.future;
      },
    );

    final art = await service.resolve(
      {'fast': tv(1), 'slow': tv(2)},
      concurrency: 1,
      timeout: const Duration(milliseconds: 50),
    );

    expect(art.keys, ['fast']);
    expect(art['fast']!.poster, '$imageBase/p.jpg');
  });

  test('空输入返回空且不请求', () async {
    var calls = 0;
    final service = HomeMetaService(
      tmdb: fakeTmdb(),
      loader: (identity) async {
        calls++;
        return detail();
      },
    );

    final art = await service.resolve(const <String, TmdbIdentity>{});

    expect(art, isEmpty);
    expect(calls, 0);
  });

  test('只有 poster_path 时 backdrop 为 null', () async {
    final service = HomeMetaService(
      tmdb: fakeTmdb(),
      loader: (identity) async => detail(posterPath: '/only-poster.jpg'),
    );

    final art = await service.resolve({'a': tv(1)});

    expect(art['a']!.poster, '$imageBase/only-poster.jpg');
    expect(art['a']!.backdrop, isNull);
  });

  test('详情里没有任何图时该键不出现（保留站点海报）', () async {
    final service = HomeMetaService(
      tmdb: fakeTmdb(),
      loader: (identity) async => detail(),
    );

    final art = await service.resolve({'a': tv(1)});

    expect(art, isEmpty);
  });

  test('同一次 detail 顺带取到刮削名（剧集用 name、电影用 title）', () async {
    final service = HomeMetaService(
      tmdb: fakeTmdb(),
      loader: (_) async => {'id': 1, 'name': '刮削后的剧名', 'poster_path': '/p.jpg'},
    );

    final art = await service.resolve({'k': tv(1)});

    expect(art['k']!.title, '刮削后的剧名');
  });

  test('只有名字时也要返回（首页因此能显示刮削名）', () async {
    final service = HomeMetaService(
      tmdb: fakeTmdb(),
      loader: (_) async => {'id': 1, 'title': '刮削后的片名'},
    );

    final art = await service.resolve({'k': movie(1)});

    expect(art['k']!.title, '刮削后的片名');
    expect(art['k']!.backdrop, isNull);
  });

  test('同一次 detail 顺带取到类型标签 / 年份 / 评分（不额外请求）', () async {
    // 详情页用到的 `genres` / `release_date|first_air_date` / `vote_average`
    // 就在同一份响应里；首页把它们一起接出来，才能在不加请求的前提下
    // 把「标签」补上。
    final service = HomeMetaService(
      tmdb: fakeTmdb(),
      loader: (identity) async => {
        ...detail(backdrops: ['/b.jpg']),
        'genres': [
          {'id': 18, 'name': '剧情'},
          {'id': 9648, 'name': '悬疑'},
          {'id': 1, 'name': '   '},
          {'id': 2, 'name': '家庭'},
          {'id': 3, 'name': '第四个不该出现'},
        ],
        'first_air_date': '2026-03-01',
        'vote_average': 8.6,
      },
    );

    final meta = (await service.resolve({'a': tv(9)}))['a']!;

    expect(meta.genres, ['剧情', '悬疑', '家庭'], reason: '空白名跳过，最多 3 个');
    expect(meta.year, '2026');
    expect(meta.rating, 8.6);
  });

  test('只有标签没有图与简介时也要返回（标签本身就是内容）', () async {
    final service = HomeMetaService(
      tmdb: fakeTmdb(),
      loader: (identity) async => detail()
        ..['genres'] = [
          {'id': 18, 'name': '剧情'},
        ],
    );

    final meta = (await service.resolve({'a': tv(2)}))['a']!;

    expect(meta.genres, ['剧情']);
    expect(meta.poster, isNull);
    expect(meta.overview, isNull);
  });
}
