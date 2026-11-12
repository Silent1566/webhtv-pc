import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/temp_dirs.dart';

import 'package:webhtv_pc/core/detail_recommendation.dart';
import 'package:webhtv_pc/core/tmdb_config.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/services/douban_recommendation_service.dart';
import 'package:webhtv_pc/services/tmdb_service.dart';

const current = RecommendationSeed(
  title: '当前电影',
  year: '2020',
  mediaType: TmdbMediaType.movie,
);
const watched = RecommendationSeed(
  title: '历史电影',
  year: '2019',
  mediaType: TmdbMediaType.movie,
);

Map<String, Object?> subject(
  String id,
  String title, {
  String year = '2020',
  String type = 'movie',
  double rating = 8,
}) => {
  'id': id,
  'title': title,
  'year': year,
  'type': type,
  'rating': {'value': rating},
  'pic': {'normal': 'https://img.doubanio.com/s_ratio_poster/$id.jpg'},
};
http.Response jsonResponse(Object body, {int status = 200}) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

class Fixture {
  Fixture(this.directory);
  final Directory directory;
  DateTime now = DateTime.utc(2026, 11, 10);
  final requests = <http.Request>[];
  final times = <DateTime>[];
  final waits = <Duration>[];
  final suggestions = <String, Object>{
    current.title: [subject('100', current.title)],
    watched.title: [subject('200', watched.title, year: '2019')],
  };
  final related = <String, Object>{
    'movie/100': {
      'subjects': [subject('1292052', '推荐电影', rating: 9.7)],
    },
  };
  bool fail = false;
  int status = 200;
  String? raw;
  Future<http.Response> respond(http.Request request) async {
    requests.add(request);
    times.add(now);
    if (fail) throw const SocketException('offline');
    if (status != 200) return jsonResponse({}, status: status);
    if (raw != null) {
      return http.Response(
        raw!,
        200,
        headers: {'content-type': 'text/html; charset=utf-8'},
      );
    }
    if (request.url.path.endsWith('subject_suggest')) {
      return jsonResponse(suggestions[request.url.queryParameters['q']] ?? []);
    }
    if (request.url.path.endsWith('subject_abstract')) {
      return jsonResponse({
        'subject': {
          'rating': {'value': 8.6},
        },
      });
    }
    final parts = request.url.path.split('/');
    return jsonResponse(related['${parts[4]}/${parts[5]}'] ?? {'items': []});
  }

  DoubanRecommendationService service({TmdbService? tmdb}) =>
      DoubanRecommendationService(
        client: MockClient(respond),
        tmdb: tmdb,
        cacheDirectory: directory,
        clock: () => now,
        delay: (duration) async {
          waits.add(duration);
          now = now.add(duration);
        },
      );
}

void main() {
  late Directory directory;
  late Fixture fixture;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('douban_rec_test_');
    fixture = Fixture(directory);
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test('suggest to related retains Douban identity, score, poster without fabricated TMDB identity', () async {
    final page = await fixture.service().personal(current: current);
    final entry = page.items.single;
    expect(entry.source, RecommendationSource.douban);
    expect(entry.doubanId, '1292052');
    expect(entry.doubanRating, 9.7);
    expect(entry.item.title, '推荐电影');
    expect(entry.item.tmdbId, 0);
    expect(entry.item.identity, isNull);
    expect(entry.item.posterUrl, contains('m_ratio_poster'));
    expect(entry.reason, contains(current.title));
    expect(page.nextOffset, 1);
    expect(page.hasMore, isFalse);
    expect(fixture.requests.last.url.queryParameters['count'], '10');
    for (final request in fixture.requests) {
      expect(request.url.scheme, 'https');
      expect(request.headers.keys, isNot(contains('authorization')));
      expect(request.url.queryParameters.keys, isNot(contains('api_key')));
    }
  });

  test(
    'nested smart_box target and subjects.items parse real TV response',
    () async {
      const seed = RecommendationSeed(
        title: '当前剧集',
        year: '2021',
        mediaType: TmdbMediaType.tv,
      );
      fixture.suggestions[seed.title] = {
        'smart_box': [
          {'layout': 'celebrity', 'target': subject('bad', seed.title)},
          {
            'layout': 'subject',
            'target_type': 'tv',
            'target': {'id': '300', 'title': seed.title, 'year': '2021'},
          },
        ],
      };
      fixture.related['tv/300'] = {
        'subjects': {
          'items': [
            {
              'id': '301',
              'name': '推荐剧集',
              'card_subtitle': '2022 / 剧集',
              'is_tv': true,
              'cover_url': 'https://img.doubanio.com/tv.jpg',
              'rate': '9.1',
            },
          ],
        },
      };
      final page = await fixture.service().personal(current: seed);
      expect(page.items.single.item.mediaType, TmdbMediaType.tv);
      expect(page.items.single.doubanRating, 9.1);
      expect(page.items.single.item.subtitle, contains('2022'));
      expect(page.items.single.item.title, '推荐剧集');
    },
  );

  for (final cue in <String, Map<String, Object?>>{
    'query': {'more_url': 'https://movie.douban.com/explore?is_tv=1'},
    'quoted': {'more_url': "https://movie.douban.com/explore?filter=is_tv:'1'"},
    'encoded': {
      'more_url': 'https://movie.douban.com/explore?filter=is_tv%3a%271%27',
    },
    'boolean': {'is_tv': true},
    'integer': {'is_tv': 1},
    'string1': {'is_tv': '1'},
    'stringTrue': {'is_tv': 'true'},
  }.entries) {
    test('TV suggestion recognized from ${cue.key} cue alone', () async {
      final seed = RecommendationSeed(
        title: '当前剧集${cue.key}',
        year: '2021',
        mediaType: TmdbMediaType.tv,
      );
      fixture.suggestions[seed.title] = [
        {'id': '300', 'title': seed.title, 'year': '2021', ...cue.value},
      ];
      fixture.related['tv/300'] = {
        'items': [subject('301', '电视推荐', type: 'tv', year: '2022')],
      };
      final page = await fixture.service().personal(current: seed);
      expect(page.items.map((entry) => entry.item.title), ['电视推荐']);
      expect(page.items.single.item.mediaType, TmdbMediaType.tv);
      expect(page.items.single.doubanId, '301');
    });
  }

  test(
    'subject matching rejects different title, type and remake year',
    () async {
      fixture.suggestions[current.title] = [
        subject('bad-title', '别的电影'),
        subject('bad-type', current.title, type: 'tv'),
        subject('bad-year', current.title, year: '1990'),
        subject('100', current.title),
        subject('extra', current.title),
      ];
      fixture.related['movie/extra'] = {
        'items': [subject('extra-result', '不能加载')],
      };
      final page = await fixture.service().personal(current: current);
      expect(page.items.single.item.title, '推荐电影');
      expect(
        fixture.requests.where(
          (r) => r.url.path.contains('bad-') || r.url.path.contains('extra'),
        ),
        isEmpty,
      );
    },
  );

  test(
    'empty movie related tries TV and stops after first seed success',
    () async {
      fixture.related['movie/100'] = {'items': []};
      fixture.related['tv/100'] = {
        'items': [subject('401', '电视推荐', type: 'tv')],
      };
      fixture.suggestions[current.title] = [
        subject('100', current.title),
        subject('101', current.title),
      ];
      expect(
        (await fixture.service().personal(current: current))
            .items
            .single
            .item
            .title,
        '电视推荐',
      );
      expect(
        fixture.requests.where((r) => r.url.path.contains('/101/')),
        isEmpty,
      );
    },
  );

  test('suggest fallback only when the entire related pool is empty', () async {
    fixture.suggestions[current.title] = {
      'subjects': {
        'items': [subject('100', current.title), subject('500', '相近建议')],
      },
    };
    fixture.related.clear();
    final service = fixture.service();
    expect(
      (await service.personal(current: current)).items.single.item.title,
      '相近建议',
    );
  });

  test(
    'all related titles blocked falls back to unblocked suggestions',
    () async {
      fixture.suggestions[current.title] = [
        subject('100', current.title),
        subject('500', '相近建议'),
      ];
      final page = await fixture.service().personal(
        current: current,
        blockedTitles: {recommendationTitleKey('推荐电影')},
      );
      expect(page.items.map((entry) => entry.item.title), ['相近建议']);
      expect(page.items.single.doubanId, '500');
    },
  );

  test('one surviving related title suppresses suggestion fallback', () async {
    fixture.suggestions[current.title] = [
      subject('100', current.title),
      subject('500', '相近建议'),
    ];
    fixture.related['movie/100'] = {
      'items': [subject('1292052', '推荐电影'), subject('1292053', '仍可推荐')],
    };
    final page = await fixture.service().personal(
      current: current,
      blockedTitles: {recommendationTitleKey('推荐电影')},
    );
    expect(page.items.map((entry) => entry.item.title), ['仍可推荐']);
    expect(page.items.single.doubanId, '1292053');
  });

  test('history and feedback exclusions, audio seeds and duplicate history filtering', () async {
    fixture.related['movie/100'] = {
      'items': [
        subject('1', current.title),
        subject('2', watched.title),
        subject('3', '不感兴趣'),
        subject('4', '可见'),
      ],
    };
    fixture.related['movie/200'] = {
      'items': [subject('5', '历史推荐')],
    };
    final page = await fixture.service().personal(
      current: current,
      history: [
        watched,
        watched,
        const RecommendationSeed(title: '音频', isAudio: true),
      ],
      blockedTitles: {recommendationTitleKey('不感兴趣')},
    );
    expect(page.items.map((e) => e.item.title), ['可见', '历史推荐']);
    expect(
      fixture.requests.where((r) => r.url.queryParameters['q'] == '音频'),
      isEmpty,
    );
    expect(
      fixture.requests
          .where((r) => r.url.queryParameters['q'] == watched.title)
          .length,
      1,
    );
  });

  test(
    'current110 history88-7n rating*.8 duplicate12 and stable tie order',
    () async {
      const older = RecommendationSeed(
        title: '较旧历史',
        mediaType: TmdbMediaType.movie,
      );
      fixture.suggestions[older.title] = [subject('300', older.title)];
      fixture.related['movie/100'] = {
        'items': [
          subject('a', '当前低分', rating: 1),
          subject('b', '当前高分', rating: 10),
        ],
      };
      fixture.related['movie/200'] = {
        'items': [
          subject('c', '历史单次', rating: 10),
          subject('d', '历史重复', rating: 1),
          subject('e', '历史同分', rating: 10),
        ],
      };
      fixture.related['movie/300'] = {
        'items': [
          subject('d', '历史重复', rating: 1),
          subject('f', '较旧高分', rating: 10),
        ],
      };
      final page = await fixture.service().personal(
        current: current,
        history: [watched, older],
      );
      expect(page.items.map((e) => e.doubanId), ['b', 'a', 'd', 'c', 'e', 'f']);
    },
  );

  test(
    'row dedupe retains separate Douban ids with identical titles',
    () async {
      fixture.related['movie/100'] = {
        'items': [subject('1', '同名'), subject('1', '同名'), subject('2', '同名')],
      };
      final page = await fixture.service().personal(current: current);
      expect(page.items.map((e) => e.doubanId), ['1', '2']);
    },
  );

  test(
    'fallback mode stays consistent throughout a fixed paging snapshot',
    () async {
      final history = List.generate(
        8,
        (i) => RecommendationSeed(title: '回退历史$i'),
      );
      fixture.related.clear();
      fixture.suggestions[current.title] = [
        subject('100', current.title),
        for (var i = 0; i < 15; i++) subject('S$i', '建议$i'),
      ];
      for (var i = 0; i < history.length; i++) {
        fixture.suggestions[history[i].title] = [
          subject('seed$i', history[i].title),
        ];
      }
      fixture.related['movie/seed7'] = {
        'items': [subject('late', '迟到关联')],
      };
      final service = fixture.service();
      final first = await service.personal(current: current, history: history);
      expect(
        first.items.map((e) => e.doubanId),
        List.generate(12, (i) => 'S$i'),
      );
      final second = await service.personal(
        current: current,
        history: history,
        offset: first.nextOffset,
      );
      expect(second.items.map((e) => e.doubanId), ['S12', 'S13', 'S14']);
      expect(second.hasMore, isFalse);
      final replay = await service.personal(current: current, history: history);
      expect(
        replay.items.map((e) => e.doubanId),
        first.items.map((e) => e.doubanId),
      );
    },
  );

  test(
    'concurrent first pages never mix a fallback row with related items',
    () async {
      final history = List.generate(
        16,
        (i) => RecommendationSeed(title: '并发历史$i'),
      );
      fixture.related.clear();
      fixture.suggestions[current.title] = [
        subject('100', current.title),
        for (var i = 0; i < 15; i++) subject('F$i', '回退$i'),
      ];
      for (var i = 0; i < 16; i++) {
        fixture.suggestions[history[i].title] = [
          subject('seed$i', history[i].title),
        ];
        fixture.related['movie/seed$i'] = {
          'items': [subject('R$i', '关联$i')],
        };
      }
      final service = fixture.service();
      await Future.wait([
        service.personal(current: current, history: history),
        service.personal(current: current, history: history, offset: 12),
      ]);
      final first = await service.personal(current: current, history: history);
      final second = await service.personal(
        current: current,
        history: history,
        offset: first.nextOffset,
      );
      final reasons = [...first.items, ...second.items].map((e) => e.reason);
      final fallsBack = reasons.where((r) => r.contains('相近')).length;
      expect(
        fallsBack == 0 || fallsBack == reasons.length,
        isTrue,
        reason: 'one paging session must keep a single pool kind: $reasons',
      );
    },
  );

  test('locked fallback row never stalls when later seeds only yield related', () async {
    // Reviewer counterexample: 17 seeds, the first eight only produce exactly
    // twelve suggestion fallbacks, the rest only produce related items. The row
    // must finish honestly instead of returning an unchanged empty page with
    // hasMore still true (which the UI would page on forever).
    final history = List.generate(
      16,
      (i) => RecommendationSeed(title: '停滞历史$i'),
    );
    fixture.related.clear();
    fixture.suggestions[current.title] = [
      subject('100', current.title),
      for (var i = 0; i < 12; i++) subject('F$i', '回退$i'),
    ];
    for (var i = 0; i < history.length; i++) {
      fixture.suggestions[history[i].title] = [
        subject('seed$i', history[i].title),
      ];
    }
    for (var i = 8; i < 16; i++) {
      fixture.related['movie/seed$i'] = {
        'items': [subject('R$i', '关联$i')],
      };
    }
    final service = fixture.service();
    final first = await service.personal(current: current, history: history);
    expect(first.items.length, 12);
    expect(first.hasMore, isTrue);
    final second = await service.personal(
      current: current,
      history: history,
      offset: first.nextOffset,
    );
    expect(second.items, isEmpty);
    expect(second.hasMore, isFalse);
    final again = await service.personal(
      current: current,
      history: history,
      offset: first.nextOffset,
    );
    expect(again.items, isEmpty);
    expect(again.hasMore, isFalse);
  });

  test('seed budget extension never repeats B1 or drops boosted B2', () async {
    final history = List.generate(
      8,
      (index) => RecommendationSeed(
        title: '历史种子$index',
        mediaType: TmdbMediaType.movie,
        year: '2020',
      ),
    );
    fixture.related['movie/100'] = {
      'items': List.generate(10, (i) => subject('A$i', 'A$i', rating: 1)),
    };
    for (var i = 0; i < history.length; i++) {
      fixture.suggestions[history[i].title] = [
        subject('seed$i', history[i].title),
      ];
    }
    fixture.related['movie/seed0'] = {
      'items': List.generate(10, (i) => subject('B$i', 'B$i', rating: 10)),
    };
    fixture.related['movie/seed7'] = {
      'items': [subject('B2', 'B2', rating: 10)],
    };
    final service = fixture.service();
    final first = await service.personal(current: current, history: history);
    expect(first.items.map((entry) => entry.doubanId), [
      'A0',
      'A1',
      'A2',
      'A3',
      'A4',
      'A5',
      'A6',
      'A7',
      'A8',
      'A9',
      'B0',
      'B1',
    ]);
    final second = await service.personal(
      current: current,
      history: history,
      offset: first.nextOffset,
    );
    expect(second.items.map((entry) => entry.doubanId), [
      'B2',
      'B3',
      'B4',
      'B5',
      'B6',
      'B7',
      'B8',
      'B9',
    ]);
    expect(second.nextOffset, 20);
    expect(second.hasMore, isFalse);
    final repeated = await service.personal(current: current, history: history);
    expect(repeated.items.map((entry) => entry.doubanId), [
      'A0',
      'A1',
      'A2',
      'A3',
      'A4',
      'A5',
      'A6',
      'A7',
      'A8',
      'A9',
      'B0',
      'B1',
    ]);
  });

  test('12 item offset paging, feedback reapplied and history changes not frozen in cache', () async {
    fixture.related['movie/100'] = {
      'items': List.generate(15, (i) => subject('$i', '推荐$i')),
    };
    final service = fixture.service();
    final first = await service.personal(current: current);
    final second = await service.personal(
      current: current,
      offset: first.nextOffset,
    );
    expect(first.items.length, 12);
    expect(first.nextOffset, 12);
    expect(first.hasMore, isTrue);
    expect(second.items.map((e) => e.item.title), ['推荐12', '推荐13', '推荐14']);
    expect(second.nextOffset, 15);
    expect(second.hasMore, isFalse);
    expect(
      (await service.personal(current: current, offset: 99)).nextOffset,
      99,
    );
    final refreshed = await service.personal(
      current: current,
      history: const [RecommendationSeed(title: '推荐0')],
      blockedTitles: {recommendationTitleKey('推荐1')},
    );
    expect(refreshed.items.map((e) => e.item.title), isNot(contains('推荐0')));
    expect(refreshed.items.map((e) => e.item.title), isNot(contains('推荐1')));
  });

  test(
    'disk cache fresh for seven days then network failure returns stale data',
    () async {
      expect(
        (await fixture.service().personal(current: current))
            .items
            .single
            .doubanId,
        '1292052',
      );
      final savedCalls = fixture.requests.length;
      fixture.now = fixture.now.add(const Duration(days: 6));
      fixture.fail = true;
      expect(
        (await fixture.service().personal(current: current))
            .items
            .single
            .doubanId,
        '1292052',
      );
      expect(fixture.requests.length, savedCalls);
      fixture.now = fixture.now.add(const Duration(days: 2));
      expect(
        (await fixture.service().personal(current: current))
            .items
            .single
            .doubanId,
        '1292052',
      );
      expect(fixture.requests.length, greaterThan(savedCalls));
    },
  );

  for (final rejection in [403, 429, 418]) {
    test(
      'HTTP $rejection cooldown persists, stale survives and expires after 30 minutes',
      () async {
        await fixture.service().personal(current: current);
        fixture.now = fixture.now.add(const Duration(days: 8));
        fixture.status = rejection;
        expect(
          (await fixture.service().personal(current: current))
              .items
              .single
              .item
              .title,
          '推荐电影',
        );
        final rejectedCalls = fixture.requests.length;
        fixture.now = fixture.now.add(const Duration(minutes: 29));
        expect(
          (await fixture.service().personal(current: current))
              .items
              .single
              .item
              .title,
          '推荐电影',
        );
        expect(fixture.requests.length, rejectedCalls);
        fixture.now = fixture.now.add(const Duration(minutes: 2));
        fixture.status = 200;
        expect(
          (await fixture.service().personal(current: current))
              .items
              .single
              .item
              .title,
          '推荐电影',
        );
        expect(fixture.requests.length, greaterThan(rejectedCalls));
      },
    );
  }

  test(
    'captcha HTML blocks subsequent requests without poisoning cache',
    () async {
      final service = fixture.service();
      fixture.raw = '<html>captcha 验证码</html>';
      expect((await service.personal(current: current)).items, isEmpty);
      fixture.raw = null;
      expect(
        (await fixture.service().personal(current: current)).items,
        isEmpty,
      );
      expect(fixture.requests.length, 1);
      fixture.now = fixture.now.add(const Duration(minutes: 31));
      expect(
        (await fixture.service().personal(current: current))
            .items
            .single
            .doubanId,
        '1292052',
      );
    },
  );

  test(
    'malformed JSON and timeout return empty independently of other seeds',
    () async {
      final service = DoubanRecommendationService(
        client: MockClient((request) async {
          if (request.url.queryParameters['q'] == current.title) {
            throw TimeoutException('timeout');
          }
          if (request.url.path.endsWith('subject_suggest')) {
            return jsonResponse([subject('200', watched.title, year: '2019')]);
          }
          return jsonResponse({
            'items': [subject('501', '历史仍可见')],
          });
        }),
        cacheDirectory: directory,
        delay: (_) async {},
      );
      expect(
        (await service.personal(
          current: current,
          history: [watched],
        )).items.single.item.title,
        '历史仍可见',
      );
      fixture.raw = '{broken';
      expect(
        (await fixture.service().personal(current: current)).items,
        isEmpty,
      );
    },
  );

  test(
    'concurrent rows share serialized 750ms global request spacing',
    () async {
      fixture.related['movie/200'] = {
        'items': [subject('502', '历史结果')],
      };
      final service = fixture.service();
      final pages = await Future.wait([
        service.personal(current: current),
        service.personal(current: watched),
      ]);
      expect(pages.map((p) => p.items.single.item.title), ['推荐电影', '历史结果']);
      for (var i = 1; i < fixture.times.length; i++) {
        expect(
          fixture.times[i].difference(fixture.times[i - 1]),
          greaterThanOrEqualTo(const Duration(milliseconds: 750)),
        );
      }
    },
  );

  test('distinct Douban subjects survive identical TMDB enrichment', () async {
    fixture.related['movie/100'] = {
      'items': [subject('1', '同名'), subject('1', '同名'), subject('2', '同名')],
    };
    final tmdb = TmdbService(
      config: () => const TmdbConfig(apiKey: 'secret'),
      client: MockClient(
        (request) async => jsonResponse({
          'results': [
            {
              'id': 42,
              'media_type': 'movie',
              'title': '同名',
              'release_date': '2020-01-01',
            },
          ],
        }),
      ),
    );
    addTearDown(tmdb.close);
    final service = fixture.service(tmdb: tmdb);
    final page = await service.personal(current: current);
    expect(page.items.map((entry) => entry.doubanId), ['1', '2']);
    expect(page.items.map((entry) => entry.item.identity?.key), [
      'movie:42',
      'movie:42',
    ]);
    expect(page.nextOffset, 2);
    expect(page.hasMore, isFalse);
    final first = await service.personal(current: current, pageSize: 1);
    final second = await service.personal(
      current: current,
      pageSize: 1,
      offset: first.nextOffset,
    );
    expect(first.items.single.doubanId, '1');
    expect(first.hasMore, isTrue);
    expect(second.items.single.doubanId, '2');
    expect(second.hasMore, isFalse);
  });

  test(
    'TMDB enrichment keeps Douban data and rejects unsafe search matches',
    () async {
      final tmdb = TmdbService(
        config: () => const TmdbConfig(apiKey: 'secret'),
        client: MockClient(
          (request) async => jsonResponse({
            'results': [
              {
                'id': 42,
                'media_type': 'movie',
                'title': '推荐电影',
                'release_date': '2020-01-01',
                'vote_average': 7.1,
                'poster_path': '/poster.jpg',
              },
            ],
          }),
        ),
      );
      final entry =
          (await fixture.service(tmdb: tmdb).personal(current: current))
              .items
              .single;
      expect(entry.item.tmdbId, 42);
      expect(entry.item.tmdbRating, 7.1);
      expect(entry.doubanId, '1292052');
      expect(entry.doubanRating, 9.7);
      expect(entry.item.posterUrl, contains('poster.jpg'));
      tmdb.close();
    },
  );

  test(
    'TMDB missing config, wrong year or failures never blank Douban row',
    () async {
      for (final mode in ['disabled', 'wrong-year', 'failure']) {
        var calls = 0;
        final tmdb = TmdbService(
          config: () => mode == 'disabled'
              ? const TmdbConfig()
              : const TmdbConfig(apiKey: 'secret'),
          client: MockClient((request) async {
            calls++;
            if (mode == 'failure') throw const SocketException('offline');
            return jsonResponse({
              'results': [
                {
                  'id': 42,
                  'media_type': 'movie',
                  'title': '推荐电影',
                  'release_date': '1990-01-01',
                },
              ],
            });
          }),
        );
        final entry =
            (await fixture.service(tmdb: tmdb).personal(current: current))
                .items
                .single;
        expect(entry.item.tmdbId, 0);
        expect(entry.doubanRating, 9.7);
        if (mode == 'disabled') expect(calls, 0);
        tmdb.close();
      }
    },
  );

  test('missing rating uses nested subject abstract rating', () async {
    fixture.related['movie/100'] = {
      'items': [subject('1', '无分电影', rating: 0)],
    };
    expect(
      (await fixture.service().personal(current: current))
          .items
          .single
          .doubanRating,
      8.6,
    );
  });

  testWidgets('hanging HTTP request times out after fifteen seconds', (
    tester,
  ) async {
    final service = DoubanRecommendationService(
      client: MockClient((_) => Completer<http.Response>().future),
      cacheDirectory: directory,
    );
    RecommendationPage? result;
    unawaited(service.personal(current: current).then((page) => result = page));
    await tester.pump(const Duration(seconds: 14));
    expect(result, isNull);
    await tester.pump(const Duration(seconds: 2));
    expect(result?.items, isEmpty);
  });

  test(
    'unwritable disk cache still serves real network recommendations',
    () async {
      final file = File('${directory.path}/not-a-directory');
      await file.writeAsString('occupied');
      final service = DoubanRecommendationService(
        client: MockClient(fixture.respond),
        cacheDirectory: Directory(file.path),
        clock: () => fixture.now,
        delay: (_) async {},
      );
      expect(
        (await service.personal(current: current)).items.single.doubanId,
        '1292052',
      );
    },
  );

  test('close cancels TMDB enrichment before the next item starts', () async {
    fixture.related['movie/100'] = {
      'items': [subject('one', '第一部'), subject('two', '第二部')],
    };
    final pendingResponse = Completer<http.Response>();
    final started = Completer<void>();
    final titles = <String>[];
    final tmdb = TmdbService(
      config: () => const TmdbConfig(apiKey: 'test-key'),
      client: MockClient((request) async {
        titles.add(request.url.queryParameters['query'] ?? '');
        if (!started.isCompleted) started.complete();
        return pendingResponse.future;
      }),
    );
    final service = fixture.service(tmdb: tmdb);
    addTearDown(() {
      if (!pendingResponse.isCompleted) {
        pendingResponse.complete(jsonResponse({'results': []}));
      }
      service.close();
      tmdb.close();
    });
    final pending = service.personal(current: current);
    await started.future;
    expect(titles, ['第一部']);
    service.close();
    final completed = await pending.timeout(const Duration(seconds: 1));
    expect(completed.items, isEmpty);
    expect(titles, ['第一部']);
    pendingResponse.complete(jsonResponse({'results': []}));
    tmdb.close();
  });

  testWidgets('close cancels pending spacing and stops queued requests', (
    tester,
  ) async {
    final service = DoubanRecommendationService(
      client: MockClient(fixture.respond),
      cacheDirectory: directory,
      clock: () => fixture.now,
    );
    final pending = service.personal(current: current);
    await tester.pump();
    expect(fixture.requests.map((r) => r.url.path), ['/j/subject_suggest']);
    service.close();
    await tester.pump(const Duration(seconds: 3));
    final result = await pending;
    expect(result.items, isEmpty);
    expect(fixture.requests.map((r) => r.url.path), ['/j/subject_suggest']);
  });

  test('close does not close injected client', () async {
    final client = _CloseClient();
    final service = DoubanRecommendationService(
      client: client,
      cacheDirectory: directory,
    );
    service.close();
    final response = await client.get(Uri.https('movie.douban.com', '/health'));
    expect(response.statusCode, 200);
    expect(jsonDecode(response.body), isEmpty);
  });

  group('cancelPendingSpacing（页面关闭取消等待）', () {
    test('取消等待中的间隔后立刻返回，且不再发第二次请求', () async {
      final directory = await Directory.systemTemp.createTemp('douban_cancel_');
      final requests = <String>[];
      final live = DoubanRecommendationService(
        client: MockClient((request) async {
          requests.add(request.url.path);
          return jsonResponse([
            {
              'title': '详情电影',
              'id': '900',
              'type': 'movie',
              'year': '2020',
              'rating': {'value': 8.9},
            },
          ]);
        }),
        cacheDirectory: directory,
        // 故意不注入 delay：要测的正是真实 Timer 这条路径。
      );

      expect(await live.lookupRating(title: '详情电影', mediaType: 'movie'), 8.9);
      expect(requests, hasLength(1));

      final pending = live.lookupRating(title: '详情电影二', mediaType: 'movie');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      live.cancelPendingSpacing();
      // 取消后的请求按「没拿到」处理，而不是把 750ms 的 Timer 挂到进程结束。
      expect(await pending, 0);
      expect(requests, hasLength(1), reason: '取消后不得再打一枪豆瓣');
      live.close();
      await deleteTempDirBestEffort(directory);
    });
  });

  group('lookupRating（详情页评分）', () {
    test('subject_suggest 命中带分候选直接返回分数且不请求 subject_abstract', () async {
      fixture.suggestions['详情电影'] = [subject('900', '详情电影', rating: 8.9)];
      final service = fixture.service();
      final rating = await service.lookupRating(
        title: '详情电影',
        mediaType: 'movie',
        year: 2020,
      );
      expect(rating, 8.9);
      expect(fixture.requests.map((request) => request.url.path), [
        '/j/subject_suggest',
      ]);
      expect(fixture.requests.single.url.queryParameters['q'], '详情电影');
      service.close();
    });

    test('候选 rating 为 0 时回落 subject_abstract 取分', () async {
      fixture.suggestions['无分详情'] = [subject('901', '无分详情', rating: 0)];
      final service = fixture.service();
      final rating = await service.lookupRating(
        title: '无分详情',
        mediaType: 'movie',
      );
      expect(rating, 8.6);
      expect(fixture.requests.map((request) => request.url.path), [
        '/j/subject_suggest',
        '/j/subject_abstract',
      ]);
      expect(fixture.requests.last.url.queryParameters['subject_id'], '901');
      service.close();
    });

    test('候选为空数组时返回 0', () async {
      fixture.suggestions['查无此片'] = <Object>[];
      final service = fixture.service();
      final rating = await service.lookupRating(
        title: '查无此片',
        mediaType: 'movie',
      );
      expect(rating, 0);
      expect(fixture.requests.map((request) => request.url.path), [
        '/j/subject_suggest',
      ]);
      service.close();
    });

    test('空白标题直接返回 0 且不发任何请求', () async {
      final service = fixture.service();
      final rating = await service.lookupRating(
        title: '   ',
        mediaType: 'movie',
      );
      expect(rating, 0);
      expect(fixture.requests, isEmpty);
      expect(fixture.waits, isEmpty);
      service.close();
    });

    test('标点差异与副标题后缀都能命中（对齐安卓 rankDoubanSubjects）', () async {
      fixture.suggestions['归一电影'] = [subject('902', '归一·电影', rating: 8.1)];
      fixture.suggestions['后缀电影'] = [subject('903', '后缀电影 副标题', rating: 8.2)];
      // 名字完全对不上的候选不得被借来用：豆瓣按标题搜索常返回一批无关条目。
      fixture.suggestions['无关键'] = [subject('904', '另一个故事', rating: 9.9)];
      final service = fixture.service();
      expect(
        await service.lookupRating(title: '归一电影', mediaType: 'movie'),
        8.1,
      );
      // 豆瓣的候选常带副标题或年份后缀；安卓用「互为子串 +40」兜住这种情况，
      // 只认完全相等的标题会漏掉正确的片子。
      expect(
        await service.lookupRating(title: '后缀电影', mediaType: 'movie'),
        8.2,
      );
      expect(await service.lookupRating(title: '无关键', mediaType: 'movie'), 0);
      service.close();
    });
  });
}

class _CloseClient extends http.BaseClient {
  bool closed = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (closed) throw StateError('Client closed');
    return http.StreamedResponse(Stream.value(utf8.encode('[]')), 200);
  }

  @override
  void close() {
    closed = true;
  }
}
