import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/detail_recommendation.dart';
import 'package:webhtv_pc/core/tmdb_config.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/services/tmdb_recommendation_service.dart';
import 'package:webhtv_pc/services/tmdb_cache.dart';
import 'package:webhtv_pc/services/tmdb_service.dart';

const current = RecommendationSeed(
  title: '当前',
  tmdbId: 1,
  mediaType: TmdbMediaType.movie,
);
const watched = RecommendationSeed(
  title: '已看',
  tmdbId: 2,
  mediaType: TmdbMediaType.movie,
);

Map<String, Object?> item(
  int id,
  String title, {
  double rating = 0,
  List<int> genres = const [],
  String language = '',
  List<String> countries = const [],
  String? type,
}) => {
  'id': id,
  'title': title,
  'name': title,
  'vote_average': rating,
  'genre_ids': genres,
  'original_language': language,
  'origin_country': countries,
  'media_type': ?type,
};
Map<String, Object?> detail(
  int id,
  List<Map<String, Object?>> rec, [
  List<Map<String, Object?>> similar = const [],
]) => {
  'id': id,
  'recommendations': {'results': rec},
  'similar': {'results': similar},
};

class Fixture {
  Fixture({bool ready = true}) {
    tmdb = TmdbService(
      config: () =>
          ready ? const TmdbConfig(apiKey: 'fixture') : const TmdbConfig(),
      client: MockClient((request) async {
        requests.add(request.url);
        if (failure) throw const SocketException('offline');
        return http.Response(
          jsonEncode(route(request.url)),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    service = TmdbRecommendationService(tmdb);
  }
  late TmdbService tmdb;
  late TmdbRecommendationService service;
  final requests = <Uri>[];
  bool failure = false;
  Object Function(Uri) route = (uri) =>
      uri.path.contains('recommendations') ||
          uri.path.contains('similar') ||
          uri.path.contains('search')
      ? {'results': []}
      : {'id': 1};
}

void main() {
  test(
    'provider close cancels seed search without starting detail HTTP',
    () async {
      final started = Completer<void>();
      final response = Completer<http.Response>();
      final requests = <Uri>[];
      final tmdb = TmdbService(
        config: () => const TmdbConfig(apiKey: 'fixture'),
        client: MockClient((request) {
          requests.add(request.url);
          started.complete();
          return response.future;
        }),
      );
      final provider = TmdbRecommendationService(tmdb);
      final operation = provider.personal(
        current: const RecommendationSeed(title: 'Alias'),
      );
      final cancelled = expectLater(
        operation,
        throwsA(isA<TmdbCancelledException>()),
      );
      await started.future;
      provider.close();
      await cancelled;
      response.complete(
        http.Response(
          jsonEncode({
            'results': [item(1, 'Alias', type: 'movie')],
          }),
          200,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(requests.length, 1);
      expect(requests.single.path, endsWith('/search/multi'));
    },
  );

  test(
    'provider close never closes shared TMDB and rejects new provider work',
    () async {
      final f = Fixture();
      f.service.close();
      f.service.close();
      await expectLater(
        f.service.related(current: current),
        throwsA(isA<TmdbCancelledException>()),
      );
      await expectLater(
        f.service.related(
          current: current,
          sourceOnly: true,
          detail: detail(1, [item(10, 'Other')]),
        ),
        throwsA(isA<TmdbCancelledException>()),
      );
      await expectLater(
        f.service.personal(current: current),
        throwsA(isA<TmdbCancelledException>()),
      );
      expect(f.requests, isEmpty);
      f.route = (uri) => {
        'results': [item(10, 'Other', type: 'movie')],
      };
      expect((await f.tmdb.search('Other')).single.title, 'Other');
      expect(f.requests.length, 1);
    },
  );

  test('provider close prevents both HTTP and recommendation cache writes after late response', () async {
    final directory = Directory.systemTemp.createTempSync(
      'task1_cancel_cache_',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final started = Completer<void>();
    final response = Completer<http.Response>();
    var requests = 0;
    final tmdb = TmdbService(
      config: () => const TmdbConfig(apiKey: 'fixture'),
      cache: TmdbCache(cacheDir: directory.path),
      client: MockClient((request) {
        requests++;
        started.complete();
        return response.future;
      }),
    );
    final provider = TmdbRecommendationService(tmdb, cacheDirectory: directory);
    final operation = provider.personal(current: current, history: [watched]);
    final cancelled = expectLater(
      operation,
      throwsA(isA<TmdbCancelledException>()),
    );
    await started.future;
    provider.close();
    await cancelled;
    response.complete(
      http.Response(jsonEncode(detail(1, [item(10, 'Other')])), 200),
    );
    await Future<void>.delayed(Duration.zero);
    expect(requests, 1);
    expect(directory.listSync(recursive: true).whereType<File>(), isEmpty);
  });

  test('provider close cancels a pagination batch without starting another request', () async {
    final started = Completer<void>();
    final response = Completer<http.Response>();
    final requests = <Uri>[];
    final tmdb = TmdbService(
      config: () => const TmdbConfig(apiKey: 'fixture'),
      client: MockClient((request) {
        requests.add(request.url);
        started.complete();
        return response.future;
      }),
    );
    final provider = TmdbRecommendationService(tmdb);
    final data = detail(1, List.generate(20, (i) => item(i + 10, 'Other$i')));
    expect(
      (await provider.related(current: current, detail: data)).items.length,
      12,
    );
    final operation = provider.related(
      current: current,
      detail: data,
      offset: 12,
    );
    final cancelled = expectLater(
      operation,
      throwsA(isA<TmdbCancelledException>()),
    );
    await started.future;
    provider.close();
    await cancelled;
    response.complete(
      http.Response(
        jsonEncode({
          'results': [item(50, 'Late')],
        }),
        200,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(requests.length, 1);
    expect(requests.single.queryParameters['page'], '2');
  });
  test(
    'provider close cancels delayed current detail before history HTTP',
    () async {
      final started = Completer<void>();
      final response = Completer<http.Response>();
      final requests = <Uri>[];
      final tmdb = TmdbService(
        config: () => const TmdbConfig(apiKey: 'fixture'),
        client: MockClient((request) async {
          requests.add(request.url);
          if (request.url.path.endsWith('/movie/1')) {
            started.complete();
            return response.future;
          }
          return http.Response(
            jsonEncode(detail(2, [item(20, '历史相关')])),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      final provider = TmdbRecommendationService(tmdb);
      final operation = provider.personal(current: current, history: [watched]);
      final cancelled = operation.then(
        (_) => false,
        onError: (Object error) {
          if (error is TmdbCancelledException) return true;
          throw error;
        },
      );
      await started.future;
      provider.close();
      response.complete(http.Response(jsonEncode(detail(1, [])), 200));
      expect(await cancelled, isTrue);
      expect(requests.map((uri) => uri.path), ['/3/movie/1']);
    },
  );

  testWidgets('provider close cancels pending HTTP timeout timer immediately', (
    tester,
  ) async {
    final response = Completer<http.Response>();
    var requestCount = 0;
    final tmdb = TmdbService(
      config: () => const TmdbConfig(apiKey: 'fixture'),
      client: MockClient((request) {
        requestCount++;
        return response.future;
      }),
    );
    final provider = TmdbRecommendationService(tmdb);
    unawaited(
      provider
          .personal(current: current, history: [watched])
          .then(
            (_) {},
            onError: (Object error) {
              if (error is! TmdbCancelledException) throw error;
            },
          ),
    );
    await tester.pump();
    expect(requestCount, 1);
    provider.close();
    await tester.pump();
    expect(requestCount, 1);
  });
  group('review identity exclusion', () {
    test(
      'sourceOnly canonical tv name excludes self without trusting detail id',
      () async {
        final f = Fixture(ready: false);
        const alias = RecommendationSeed(
          title: 'TV alias',
          mediaType: TmdbMediaType.tv,
        );
        final data = {
          ...detail(10, [item(1, 'TV canonical'), item(10, 'Other')]),
          'name': 'TV canonical',
          'title': 'Ignored movie title',
        };
        final page = await f.service.related(
          current: alias,
          sourceOnly: true,
          detail: data,
        );
        expect(page.items.single.item.identity!.key, 'tv:10');
        expect(f.requests, isEmpty);
      },
    );
    test(
      'sourceOnly excludes supplied canonical title without current identity',
      () async {
        final f = Fixture(ready: false);
        const alias = RecommendationSeed(
          title: 'Source alias',
          mediaType: TmdbMediaType.movie,
          tmdbId: 0,
        );
        final data = {
          ...detail(1, [
            item(1, 'Current canonical'),
            item(99, 'Current canonical'),
            item(10, 'Other'),
          ]),
          'title': 'Current canonical',
        };
        final page = await f.service.related(
          current: alias,
          sourceOnly: true,
          detail: data,
        );
        expect(page.items.map((e) => e.item.identity!.key), ['movie:10']);
        expect(f.requests, isEmpty);
      },
    );
    test(
      'resolved history identity exclusions persist across provider restart',
      () async {
        final directory = Directory.systemTemp.createTempSync(
          'task1_identity_cache_',
        );
        addTearDown(() => directory.deleteSync(recursive: true));
        final f = Fixture();
        f.route = (uri) => uri.path.endsWith('/search/multi')
            ? {
                'results': [item(2, '来源别名', type: 'movie')],
              }
            : uri.path.endsWith('/movie/2')
            ? {
                ...detail(2, [item(2, '不同候选名'), item(20, '历史相关')]),
                'title': '规范名称',
              }
            : detail(1, []);
        const alias = RecommendationSeed(
          title: '来源别名',
          mediaType: TmdbMediaType.movie,
        );
        final initial = TmdbRecommendationService(
          f.tmdb,
          cacheDirectory: directory,
        );
        expect(
          (await initial.personal(
            current: current,
            history: [alias],
          )).items.map((e) => e.item.tmdbId),
          [20],
        );
        f.requests.clear();
        f.failure = true;
        final restored = TmdbRecommendationService(
          f.tmdb,
          cacheDirectory: directory,
        );
        expect(
          (await restored.personal(
            current: current,
            history: [alias],
          )).items.map((e) => e.item.tmdbId),
          [20],
        );
        expect(f.requests, isEmpty);
      },
    );

    test('identity exclusions preserve another media type with the same numeric ID', () async {
      final f = Fixture();
      final page = await f.service.related(
        current: current,
        detail: detail(1, [item(1, '电影别名'), item(1, '同号电视剧', type: 'tv')]),
      );
      expect(page.items.single.item.identity!.key, 'tv:1');
    });
    test(
      'related excludes the current identity even with a different title',
      () async {
        final f = Fixture();
        final page = await f.service.related(
          current: current,
          detail: detail(1, [item(1, '当前别名'), item(10, '可选影片')]),
        );
        expect(page.items.map((e) => e.item.tmdbId), [10]);
      },
    );

    test('sourceOnly excludes the current identity without network', () async {
      final f = Fixture(ready: false);
      final page = await f.service.related(
        current: current,
        sourceOnly: true,
        detail: detail(1, [item(1, '当前别名'), item(10, '可选影片')]),
      );
      expect(page.items.map((e) => e.item.tmdbId), [10]);
      expect(f.requests, isEmpty);
    });

    test(
      'personal excludes current and watched identities across title aliases',
      () async {
        final f = Fixture();
        f.route = (uri) => uri.path.endsWith('/movie/2')
            ? detail(2, [item(1, '当前别名'), item(2, '已看别名'), item(20, '历史相关')])
            : detail(1, [item(2, '已看另一名'), item(10, '当前相关')]);
        final page = await f.service.personal(
          current: current,
          history: [watched],
        );
        expect(page.items.map((e) => e.item.tmdbId), [20, 10]);
      },
    );

    test('alias search resolves canonical detail and excludes canonical self titles', () async {
      final f = Fixture();
      f.route = (uri) => uri.path.endsWith('/search/multi')
          ? {
              'results': [item(2, '来源别名', type: 'movie')],
            }
          : uri.path.endsWith('/movie/2')
          ? {
              ...detail(2, [
                item(2, '规范名称'),
                item(99, '规范名称'),
                item(20, '历史相关'),
              ]),
              'title': '规范名称',
            }
          : detail(1, []);
      final page = await f.service.personal(
        current: current,
        history: [
          const RecommendationSeed(
            title: '来源别名',
            mediaType: TmdbMediaType.movie,
          ),
        ],
      );
      expect(page.items.map((e) => e.item.tmdbId), [20]);
      expect(f.requests.where((u) => u.path.endsWith('/movie/2')).length, 1);
    });

    test('related canonical title comes from detail while seed identity is retained', () async {
      final f = Fixture();
      final data = {
        ...detail(999, [item(1, '其他别名'), item(99, '规范当前'), item(10, '可选影片')]),
        'title': '规范当前',
      };
      final page = await f.service.related(current: current, detail: data);
      expect(page.items.map((e) => e.item.tmdbId), [10]);
      expect(f.requests.every((u) => !u.path.contains('/movie/999')), isTrue);
    });
  });
  test(
    'fixture transports UTF8 Chinese detail through real TMDB HTTP',
    () async {
      final f = Fixture();
      f.route = (uri) => detail(1, [item(10, '缓存相关')]);
      final data = await f.tmdb.detail(
        const TmdbItem(tmdbId: 1, mediaType: TmdbMediaType.movie, title: '当前'),
      );
      expect((data['recommendations'] as Map)['results'], isNotEmpty);
    },
  );
  test('domain uses valid TMDB identity then Douban identity then normalized title', () {
    expect(current.identity!.key, 'movie:1');
    expect(
      const RecommendationSeed(
        title: '未知',
        tmdbId: -1,
        mediaType: TmdbMediaType.tv,
      ).identity,
      isNull,
    );
    const known = TmdbItem(
      tmdbId: 9,
      mediaType: TmdbMediaType.movie,
      title: 'A',
    );
    const unknown = TmdbItem(
      tmdbId: 0,
      mediaType: TmdbMediaType.tv,
      title: '《A · B》',
    );
    expect(
      const RecommendationEntry(
        item: known,
        source: RecommendationSource.tmdb,
        doubanId: '55',
      ).key,
      'movie:9',
    );
    expect(
      const RecommendationEntry(
        item: unknown,
        source: RecommendationSource.douban,
        doubanId: '55',
      ).key,
      'douban:55',
    );
    expect(
      const RecommendationEntry(
        item: unknown,
        source: RecommendationSource.douban,
      ).key,
      'title:ab',
    );
    expect(recommendationTitleKey(' A・B（C）【D】_ / :，。 '), 'abcd');
    expect(const RecommendationPage().hasMore, isFalse);
  });

  test('sourceOnly keeps first occurrence, defaults media type, caps 40, never requests', () async {
    final f = Fixture(ready: false);
    final data = detail(
      1,
      [
        item(10, '首项'),
        item(10, '重复'),
        ...List.generate(44, (i) => item(i + 11, '影片$i')),
      ],
      [item(90, '相似')],
    );
    final page = await f.service.related(
      current: current,
      detail: data,
      sourceOnly: true,
      pageSize: 100,
    );
    expect(page.items.length, 40);
    expect(page.items.first.item.title, '首项');
    expect(page.items.first.item.mediaType, TmdbMediaType.movie);
    expect(page.items.last.item.tmdbId, 49);
    expect(page.hasMore, isFalse);
    expect(f.requests, isEmpty);
  });

  test(
    'ranking uses 120/105, rating .8, genre18 language10 country8',
    () async {
      final f = Fixture();
      final data = detail(
        1,
        [
          item(10, '基础'),
          item(11, '评分', rating: 10),
          item(12, '语言', language: 'ZH'),
          item(13, '国家', countries: ['cn']),
        ],
        [
          item(14, '类型', genres: [1, 2]),
        ],
      );
      data.addAll({
        'genres': [
          {'id': 1},
          {'id': 2},
        ],
        'original_language': 'zh',
        'production_countries': [
          {'iso_3166_1': 'CN'},
        ],
      });
      final page = await f.service.related(current: current, detail: data);
      expect(page.items.map((e) => e.item.title), [
        '类型',
        '语言',
        '评分',
        '国家',
        '基础',
      ]);
    },
  );

  test('duplicate adds 12 and equal scores retain first-seen order', () async {
    final f = Fixture();
    final data = detail(
      1,
      [item(10, '首项'), item(11, '重复'), item(12, '第三')],
      [item(11, '重复')],
    );
    final page = await f.service.related(current: current, detail: data);
    expect(page.items.map((e) => e.item.tmdbId), [11, 10, 12]);
  });

  test('related endpoint missing media_type inherits tv and explicit person is ignored', () async {
    final f = Fixture();
    f.route = (uri) =>
        uri.path.endsWith('/recommendations') &&
            uri.queryParameters['page'] == '1'
        ? {
            'results': [item(10, '剧集'), item(11, '演员', type: 'person')],
          }
        : uri.path.endsWith('/similar')
        ? {'results': []}
        : {'id': 3};
    final page = await f.service.related(
      current: const RecommendationSeed(
        title: '当前剧',
        mediaType: TmdbMediaType.tv,
        tmdbId: 3,
      ),
    );
    expect(page.items.single.item.identity!.key, 'tv:10');
  });

  test(
    'network pagination appends stable pages without page1 duplication',
    () async {
      final f = Fixture();
      f.route = (uri) {
        if (!uri.path.endsWith('/recommendations')) {
          return uri.path.endsWith('/similar') ? {'results': []} : {'id': 1};
        }
        final page = int.parse(uri.queryParameters['page']!);
        return {
          'results': page > 2
              ? []
              : List.generate(
                  20,
                  (i) => item(
                    100 + (page - 1) * 20 + i,
                    '影片${(page - 1) * 20 + i}',
                    rating: page == 2 ? 10 : 0,
                  ),
                ),
        };
      };
      final pages = <RecommendationPage>[];
      var offset = 0;
      do {
        final page = await f.service.related(current: current, offset: offset);
        pages.add(page);
        offset = page.nextOffset;
      } while (pages.last.hasMore);
      expect(pages.map((p) => p.items.length), [12, 12, 12, 4]);
      expect(
        pages.expand((p) => p.items).map((e) => e.item.tmdbId),
        List.generate(40, (i) => i + 100),
      );
      expect(
        f.requests
            .where(
              (u) =>
                  u.path.endsWith('/recommendations') &&
                  u.queryParameters['page'] == '1',
            )
            .length,
        1,
      );
    },
  );

  test('personal puts history ahead of current and excludes current watched feedback', () async {
    final f = Fixture();
    f.route = (uri) => uri.path.endsWith('/movie/2')
        ? detail(2, [
            item(20, '历史相关影片'),
            item(21, '已看'),
            item(22, '当前'),
            item(23, '不喜欢'),
          ])
        : uri.path.endsWith('/movie/1')
        ? detail(1, [item(10, '当前相关影片', rating: 10)])
        : {'results': []};
    final page = await f.service.personal(
      current: current,
      history: [watched],
      blockedTitles: {recommendationTitleKey('不喜欢')},
    );
    expect(page.items.map((e) => e.item.title), ['历史相关影片', '当前相关影片']);
    expect(page.items.first.reason, contains('已看'));
  });

  test(
    'history without identity matches cleaned title year and media type',
    () async {
      final f = Fixture();
      f.route = (uri) => uri.path.endsWith('/search/multi')
          ? {
              'results': [
                {
                  ...item(30, '已看', type: 'movie'),
                  'release_date': '2020-01-01',
                },
                {...item(31, '已看', type: 'tv'), 'first_air_date': '2021-01-01'},
                {
                  ...item(32, '已看', type: 'movie'),
                  'release_date': '2021-01-01',
                },
              ],
            }
          : uri.path.endsWith('/movie/32')
          ? detail(32, [item(40, '匹配相关')])
          : {'results': [], 'id': 1};
      final page = await f.service.personal(
        current: current,
        detail: detail(1, []),
        history: [
          const RecommendationSeed(
            title: '已看',
            year: '2021',
            mediaType: TmdbMediaType.movie,
          ),
        ],
      );
      expect(page.items.single.item.title, '匹配相关');
      expect(f.requests.any((u) => u.path.endsWith('/movie/32')), isTrue);
      expect(
        f.requests.any(
          (u) => u.path.endsWith('/tv/31') || u.path.endsWith('/movie/30'),
        ),
        isFalse,
      );
    },
  );

  test(
    'no match, audio, short drama and blocked history never seed requests',
    () async {
      final f = Fixture();
      f.route = (uri) => uri.path.endsWith('/search/multi')
          ? {
              'results': [item(30, '不相关', type: 'movie')],
            }
          : {'id': 1, 'results': []};
      final page = await f.service.personal(
        current: current,
        detail: detail(1, [item(10, '当前相关')]),
        history: [
          const RecommendationSeed(title: '音频', isAudio: true),
          const RecommendationSeed(title: '短剧', isShortDrama: true),
          const RecommendationSeed(
            title: '拉黑',
            tmdbId: 4,
            mediaType: TmdbMediaType.movie,
          ),
          const RecommendationSeed(title: '找不到'),
        ],
        blockedTitles: {'拉黑'},
      );
      expect(page.items.single.item.title, '当前相关');
      expect(
        f.requests.where((u) => u.path.endsWith('/search/multi')).length,
        1,
      );
    },
  );

  test('unconfigured TMDB returns no personal/network recommendations and zero requests', () async {
    final f = Fixture(ready: false);
    expect(
      (await f.service.personal(current: current, history: [watched])).items,
      isEmpty,
    );
    expect((await f.service.related(current: current)).items, isEmpty);
    expect(f.requests, isEmpty);
  });

  test(
    'personal history changes refresh and pagination respects feedback',
    () async {
      final f = Fixture();
      f.route = (uri) => uri.path.endsWith('/movie/2')
          ? detail(2, List.generate(25, (i) => item(i + 20, '历史$i')))
          : detail(1, [item(10, '当前相关')]);
      final first = await f.service.personal(
        current: current,
        history: [watched],
      );
      final second = await f.service.personal(
        current: current,
        history: [watched],
        offset: first.nextOffset,
      );
      expect(first.items.length, 12);
      expect(first.hasMore, isTrue);
      expect(second.items.first.item.title, '历史12');
      expect(
        first.items
            .map((e) => e.key)
            .toSet()
            .intersection(second.items.map((e) => e.key).toSet()),
        isEmpty,
      );
      expect(
        (await f.service.personal(current: current)).items.single.item.title,
        '当前相关',
      );
      expect(
        (await f.service.personal(
          current: current,
          history: [watched],
          blockedTitles: {'历史0'},
        )).items.first.item.title,
        '历史1',
      );
    },
  );

  test(
    'one seed failure does not hide another seed or current results',
    () async {
      final f = Fixture();
      f.route = (uri) {
        if (uri.path.endsWith('/movie/2')) {
          throw const SocketException('seed down');
        }
        return uri.path.endsWith('/movie/3')
            ? detail(3, [item(30, '可用历史')])
            : detail(1, [item(10, '可用当前')]);
      };
      final page = await f.service.personal(
        current: current,
        history: [
          watched,
          const RecommendationSeed(
            title: '其他已看',
            tmdbId: 3,
            mediaType: TmdbMediaType.movie,
          ),
        ],
      );
      expect(page.items.map((e) => e.item.title), ['可用历史', '可用当前']);
    },
  );

  test(
    'feedback filters are reversible without poisoning cached candidate lists',
    () async {
      final f = Fixture();
      final data = detail(1, [item(10, '恢复候选')]);
      expect(
        (await f.service.personal(
          current: current,
          detail: data,
          blockedTitles: {'恢复候选'},
        )).items,
        isEmpty,
      );
      expect(
        (await f.service.personal(
          current: current,
          detail: data,
        )).items.single.item.title,
        '恢复候选',
      );
    },
  );

  test(
    'repeating upstream pages terminate when no new identities are returned',
    () async {
      final f = Fixture();
      f.route = (uri) {
        if (f.requests.length >= 6) {
          throw const SocketException('test request budget');
        }
        return uri.path.endsWith('/recommendations')
            ? {
                'results': [item(10, '重复页')],
              }
            : uri.path.endsWith('/similar')
            ? {'results': []}
            : {'id': 1};
      };
      final page = await f.service.related(current: current);
      expect(page.items.single.item.title, '重复页');
      expect(page.hasMore, isFalse);
      expect(f.requests.length, lessThan(6));
    },
    timeout: const Timeout(Duration(seconds: 3)),
  );

  test(
    'related cache persists stable pagination across provider restart',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'task1_related_cache_',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final f = Fixture();
      f.route = (uri) =>
          uri.path.endsWith('/recommendations') &&
              uri.queryParameters['page'] == '1'
          ? {'results': List.generate(20, (i) => item(100 + i, '缓存$i'))}
          : uri.path.endsWith('/similar') ||
                uri.path.endsWith('/recommendations')
          ? {'results': []}
          : {'id': 1};
      final firstProvider = TmdbRecommendationService(
        f.tmdb,
        cacheDirectory: directory,
      );
      final first = await firstProvider.related(current: current);
      final resumed = TmdbRecommendationService(
        f.tmdb,
        cacheDirectory: directory,
      );
      final second = await resumed.related(
        current: current,
        offset: first.nextOffset,
      );
      expect(
        second.items.map((e) => e.item.tmdbId),
        List.generate(8, (i) => 112 + i),
      );
      expect(second.hasMore, isFalse);
      expect(
        f.requests
            .where(
              (u) =>
                  u.path.endsWith('/recommendations') &&
                  u.queryParameters['page'] == '1',
            )
            .length,
        1,
      );
    },
  );

  test('7-day persistent results survive restart and offline expiry uses stale cache', () async {
    final directory = Directory.systemTemp.createTempSync('task1_cache_');
    addTearDown(() => directory.deleteSync(recursive: true));
    var now = DateTime(2026, 11, 10);
    final f = Fixture();
    f.route = (uri) => detail(1, [item(10, '缓存相关')]);
    final initial = TmdbRecommendationService(
      f.tmdb,
      cacheDirectory: directory,
      clock: () => now,
    );
    expect(
      (await initial.personal(current: current)).items.single.item.title,
      '缓存相关',
    );
    f.requests.clear();
    f.failure = true;
    now = now.add(const Duration(days: 6));
    final fresh = TmdbRecommendationService(
      f.tmdb,
      cacheDirectory: directory,
      clock: () => now,
    );
    expect(
      (await fresh.personal(current: current)).items.single.item.title,
      '缓存相关',
    );
    expect(f.requests, isEmpty);
    now = now.add(const Duration(days: 2));
    final stale = TmdbRecommendationService(
      f.tmdb,
      cacheDirectory: directory,
      clock: () => now,
    );
    expect(
      (await stale.personal(current: current)).items.single.item.title,
      '缓存相关',
    );
    expect(f.requests, isNotEmpty);
  });
}
