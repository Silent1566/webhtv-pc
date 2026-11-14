import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/tmdb_source_payload.dart';

Map<String, Object?> wire({
  Map<String, Object?> detail = const {},
  List<Object?> complete = const [],
  String language = '',
  String type = 'movie',
  int season = 0,
}) => {
  'schema': 1,
  'id': 42,
  'media_type': type,
  'season_number': season,
  'language': language,
  'complete': complete,
  'detail': detail,
};
TmdbSourcePayload source({
  Map<String, Object?> detail = const {},
  List<Object?> complete = const [],
  String language = '',
  String type = 'movie',
  int season = 0,
}) => TmdbSourcePayload.fromJson(
  wire(
    detail: detail,
    complete: complete,
    language: language,
    type: type,
    season: season,
  ),
)!;

void main() {
  group('payload normalization', () {
    test('accepts object wire shape and exposes frozen typed identity', () {
      final p = TmdbSourcePayload.fromJson({
        ...wire(),
        'media_type': ' MOVIE ',
        'language': 'zh-Hant',
        'fetched_at': '2026-11-13T12:00:00Z',
      })!;
      expect(p.schema, 1);
      expect(p.id, 42);
      expect(p.seasonNumber, 0);
      expect(p.identity.key, 'movie:42');
      expect(p.mediaType.name, 'movie');
      expect(p.language, 'zh-TW');
      expect(p.fetchedAt, '2026-11-13T12:00:00Z');
      expect(p.toJson()['detail'], isA<Map<String, Object?>>());
      expect(TmdbSourcePayload.fromJson(p.toJson())!.toJson(), p.toJson());
    });
    for (final entry in <String, Object?>{
      'schema': 2,
      'id': 0,
      'media_type': 'person',
      'season_number': -1,
    }.entries) {
      test('rejects invalid envelope ${entry.key}', () {
        expect(
          TmdbSourcePayload.fromJson({...wire(), entry.key: entry.value}),
          isNull,
        );
      });
    }
    test('rejects non-object envelope and ignores non-object detail', () {
      for (final input in [null, [], 'bad', 3]) {
        expect(TmdbSourcePayload.fromJson(input), isNull);
      }
      expect(
        TmdbSourcePayload.fromJson({...wire(), 'detail': 'not JSON'})!.detail,
        isEmpty,
      );
      expect(TmdbSourcePayload.fromJson({...wire(), 'id': '42'}), isNull);
      expect(
        TmdbSourcePayload.fromJson({...wire(), 'season_number': 'invalid'})!
            .seasonNumber,
        0,
      );
    });
    test('rejects movie season and numeric detail identity conflicts', () {
      expect(TmdbSourcePayload.fromJson(wire(season: 1)), isNull);
      expect(TmdbSourcePayload.fromJson(wire(detail: {'id': 43})), isNull);
      expect(
        TmdbSourcePayload.fromJson(
          wire(type: 'tv', season: 2, detail: {'season_number': 3}),
        ),
        isNull,
      );
      expect(
        source(detail: {'id': '42', 'season_number': 2}).detail
            .containsKey('id'),
        isFalse,
      );
      expect(
        source(detail: {'season_number': 2}).detail
            .containsKey('season_number'),
        isFalse,
      );
    });
    test(
      'normalizes invalid language and timestamps without rejecting identity',
      () {
        final p = TmdbSourcePayload.fromJson({
          ...wire(),
          'language': 'a' * 65,
          'fetched_at': 'yesterday',
        })!;
        expect(p.language, '');
        expect(p.fetchedAt, '');
        expect(source(language: 'en_us').language, 'en-US');
      },
    );
    for (final image in [
      'http://host/x',
      '//host/x',
      'file:///x',
      'javascript:x',
      '/a b',
      '/a\\b',
      'https://',
      'https://host/a b',
    ]) {
      test('removes unsafe image $image and its complete claim', () {
        final p = source(detail: {'poster_path': image}, complete: ['images']);
        expect(p.detail.containsKey('poster_path'), isFalse);
        expect(p.complete, isEmpty);
      });
    }
    test('keeps safe image paths and HTTPS references recursively', () {
      final p = source(
        detail: {
          'poster_path': ' /p.jpg ',
          'images': {
            'backdrops': [
              {'file_path': 'https://host/b.jpg'},
              {'file_path': 'http://bad'},
            ],
          },
        },
      );
      expect(p.detail['poster_path'], '/p.jpg');
      expect(((p.detail['images'] as Map)['backdrops'] as List).first, {
        'file_path': 'https://host/b.jpg',
      });
    });
    test('prunes oversized strings and arrays and false claims', () {
      final p = source(
        detail: {
          'overview': '文' * 22000,
          'genres': List.filled(501, 1),
          'credits': {'cast': List.filled(501, {})},
        },
        complete: ['credits'],
      );
      expect(p.detail.containsKey('overview'), isFalse);
      expect(p.detail.containsKey('genres'), isFalse);
      expect(p.detail.containsKey('credits'), isFalse);
      expect(p.complete, isEmpty);
      expect(
        source(detail: {'overview': 'a' * 65536}).detail['overview'],
        hasLength(65536),
      );
      expect(
        source(detail: {'genres': List.filled(500, 1)}).detail['genres'],
        hasLength(500),
      );
    });
    test('rejects protocol input over two MiB and cyclic malformed input', () {
      expect(
        TmdbSourcePayload.fromJson({
          ...wire(),
          'junk': 'x' * (2 * 1024 * 1024),
        }),
        isNull,
      );
      final cycle = wire();
      cycle['detail'] = cycle;
      expect(TmdbSourcePayload.fromJson(cycle), isNull);
      expect(
        TmdbSourcePayload.fromJson({
          ...wire(),
          'detail': {'runtime': double.nan},
        }),
        isNull,
      );
    });
    test('validates field containers and preserves complete empty objects', () {
      final p = source(
        detail: {
          'title': 4,
          'credits': {'cast': List.filled(501, {})},
          'external_ids': {'imdb_id': null},
          'images': {},
          'videos': {},
          'recommendations': {},
          'similar': {},
        },
        complete: [
          'credits',
          'external_ids',
          'images',
          'videos',
          'recommendations',
          'similar',
        ],
      );
      expect(p.detail.containsKey('title'), isFalse);
      expect(p.complete, {
        'external_ids',
        'images',
        'videos',
        'recommendations',
        'similar',
      });
    });
    test(
      'canonicalizes capabilities and removes unsupported season claims',
      () {
        final p = source(
          type: 'tv',
          complete: [
            ' CORE ',
            'season:001',
            'season_videos:01',
            'episode:01:002',
            'episode_videos:1:0',
            'unknown',
            1,
          ],
        );
        expect(p.complete, {'core', 'episode:1:2'});
        final seasonal = source(
          type: 'tv',
          detail: {'seasons': []},
          complete: ['season:001', 'season_videos:01'],
        );
        expect(seasonal.complete, {'season:1', 'season_videos:1'});
      },
    );
    test(
      'normalized payload is detached and immutable including nested data',
      () {
        final raw = wire(
          detail: {
            'images': {'posters': []},
          },
          complete: ['images'],
        );
        final p = TmdbSourcePayload.fromJson(raw)!;
        ((raw['detail'] as Map)['images'] as Map)['posters'] = [1];
        expect(((p.detail['images'] as Map)['posters'] as List), isEmpty);
        expect(() => p.detail['title'] = 'changed', throwsUnsupportedError);
        expect(() => p.complete.add('core'), throwsUnsupportedError);
        final out = p.toJson();
        (out['detail'] as Map)['title'] = 'copy';
        expect(p.detail.containsKey('title'), isFalse);
        expect(jsonEncode(out), isNotEmpty);
      },
    );
  });
  group('capability planning', () {
    const all = {
      'core',
      'credits',
      'images',
      'external_ids',
      'videos',
      'recommendations',
      'similar',
    };
    test('identity alone is missing every required static group', () {
      final plan = planTmdbSource(source(), required: all);
      expect(plan.required, all);
      expect(plan.available, isEmpty);
      expect(plan.missing, all);
      expect(plan.needsNetwork, isTrue);
    });
    test('complete empty groups need no network including zero core', () {
      final p = source(
        detail: {
          'vote_average': 0,
          'genres': [],
          'credits': {},
          'images': {},
          'external_ids': {},
          'videos': {},
          'recommendations': {},
          'similar': {},
        },
        complete: all.toList(),
      );
      final plan = planTmdbSource(p, required: all);
      expect(plan.available, all);
      expect(plan.missing, isEmpty);
      expect(plan.needsNetwork, isFalse);
      expect(planTmdbSource(p, required: {}).needsNetwork, isFalse);
    });
    test(
      'infers full movie core, credits, images, ids, videos and page one',
      () {
        final p = source(
          detail: {
            'title': 'Source',
            'overview': 'Plot',
            'release_date': '2026-01-01',
            'vote_average': 0,
            'genres': [],
            'credits': {
              'cast': [
                {'id': 1},
              ],
            },
            'poster_path': '/p',
            'backdrop_path': '/b',
            'external_ids': {'imdb_id': 'tt42'},
            'videos': {
              'results': [{}],
            },
            'recommendations': {
              'page': 1,
              'results': [{}],
            },
            'similar': {
              'page': 2,
              'results': [{}],
            },
          },
        );
        expect(planTmdbSource(p, required: all).missing, {'similar'});
      },
    );
    test('page one requires a numeric page field', () {
      final p = source(
        detail: {
          'recommendations': {
            'page': '1',
            'results': [{}],
          },
        },
      );
      expect(
        planTmdbSource(p, required: {'recommendations'}).needsNetwork,
        isTrue,
      );
    });
    test('TV inferred core needs both season and episode counts', () {
      final detail = <String, Object?>{
        'name': 'Show',
        'overview': 'Plot',
        'first_air_date': '2026-01-01',
        'vote_average': 0,
        'genres': [],
        'number_of_seasons': 1,
      };
      expect(
        planTmdbSource(
          source(type: 'tv', detail: detail),
          required: {'core'},
        ).needsNetwork,
        isTrue,
      );
      detail['number_of_episodes'] = 0;
      expect(
        planTmdbSource(
          source(type: 'tv', detail: detail),
          required: {'core'},
        ).needsNetwork,
        isFalse,
      );
    });
    test('target-language mismatch invalidates even complete core only', () {
      final p = source(
        language: 'en-US',
        detail: {'title': 'Source', 'images': {}},
        complete: ['core', 'images'],
      );
      expect(
        planTmdbSource(
          p,
          required: {'core', 'images'},
          targetLanguage: 'zh-CN',
        ).missing,
        {'core'},
      );
      expect(
        planTmdbSource(
          source(language: 'zh', complete: ['core']),
          required: {'core'},
          targetLanguage: 'zh-CN',
        ).needsNetwork,
        isFalse,
      );
      expect(
        planTmdbSource(
          source(language: 'zh-TW', complete: ['core']),
          required: {'core'},
          targetLanguage: 'zh-CN',
        ).needsNetwork,
        isTrue,
      );
    });
    test('undeclared language uses display text heuristic', () {
      expect(
        planTmdbSource(
          source(detail: {'title': '中文'}, complete: ['core']),
          required: {'core'},
          targetLanguage: 'zh-CN',
        ).needsNetwork,
        isFalse,
      );
      expect(
        planTmdbSource(
          source(detail: {'title': 'English'}, complete: ['core']),
          required: {'core'},
          targetLanguage: 'zh-CN',
        ).needsNetwork,
        isTrue,
      );
    });
    test(
      'covers seasons episodes and video groups by exact group identity',
      () {
        final p = source(
          type: 'tv',
          detail: {
            'seasons': [
              {
                'season_number': 1,
                'episodes': [
                  {'episode_number': 2, 'name': 'Episode'},
                ],
              },
            ],
          },
          complete: ['season_videos:1', 'episode_videos:1:2'],
        );
        final plan = planTmdbSource(
          p,
          required: {
            'season:1',
            'season:2',
            'episode:1:2',
            'episode:1:3',
            'season_videos:1',
            'episode_videos:1:2',
            'episode_videos:1:3',
          },
        );
        expect(plan.available, {
          'season:1',
          'episode:1:2',
          'season_videos:1',
          'episode_videos:1:2',
        });
        expect(plan.missing, {'season:2', 'episode:1:3', 'episode_videos:1:3'});
      },
    );
    test('own-season top-level episodes make the season available', () {
      final p = source(
        type: 'tv',
        season: 2,
        detail: {
          'episodes': [
            {'episode_number': 3, 'name': 'Source episode'},
          ],
        },
      );
      final plan = planTmdbSource(p, required: {'season:2'});
      expect(plan.available, {'season:2'});
      expect(plan.needsNetwork, isFalse);
    });
    test('own-season top-level episode is available by episode number', () {
      final p = source(
        type: 'tv',
        season: 2,
        detail: {
          'episodes': [
            {'episode_number': 3, 'name': 'Source episode'},
          ],
        },
      );
      final plan = planTmdbSource(p, required: {'episode:2:3', 'episode:2:4'});
      expect(plan.available, {'episode:2:3'});
      expect(plan.missing, {'episode:2:4'});
    });
    test('own-season top-level episodes never satisfy another season', () {
      final p = source(
        type: 'tv',
        season: 2,
        detail: {
          'episodes': [
            {'episode_number': 3, 'name': 'Source episode'},
          ],
        },
      );
      final plan = planTmdbSource(p, required: {'season:1', 'episode:1:3'});
      expect(plan.available, isEmpty);
      expect(plan.missing, {'season:1', 'episode:1:3'});
    });
    test('own-season empty episodes do not infer completion or videos', () {
      final p = source(
        type: 'tv',
        season: 2,
        detail: {'episodes': []},
        complete: ['season:2', 'season_videos:2'],
      );
      expect(p.complete, isEmpty);
      final required = {
        'season:2',
        'episode:2:3',
        'season_videos:2',
        'episode_videos:2:3',
      };
      final plan = planTmdbSource(p, required: required);
      expect(plan.available, isEmpty);
      expect(plan.missing, required);
    });
    test('season summary alone is not complete episode metadata', () {
      final p = source(
        type: 'tv',
        detail: {
          'seasons': [
            {'season_number': 1, 'episode_count': 5},
          ],
        },
      );
      expect(planTmdbSource(p, required: {'season:1'}).needsNetwork, isTrue);
    });
  });
  group('fill-only merge', () {
    test('rejects wrong media identity without mutating source', () {
      final p = source(detail: {'title': 'Source'});
      for (final lower in <Map<String, Object?>>[
        {'id': 43, 'overview': 'Other'},
        {'id': 42, 'media_type': 'tv', 'overview': 'Other'},
      ]) {
        expect(mergeTmdbSourceDetail(p, lower), p.detail);
      }
      expect(
        mergeTmdbSourceDetail(p, {'id': '42', 'overview': 'Bad'}),
        p.detail,
      );
    });
    test('same identity fills absent blank zero and empty fields only', () {
      final p = source(
        detail: {
          'id': 42,
          'title': 'Source',
          'overview': ' ',
          'vote_average': 0,
          'genres': [],
          'credits': {'cast': []},
        },
      );
      final lower = <String, Object?>{
        'id': 42,
        'title': 'Network',
        'overview': 'Plot',
        'vote_average': 8,
        'genres': [
          {'id': 1},
        ],
        'credits': {
          'cast': [
            {'id': 2},
          ],
        },
        'poster_path': '/p',
      };
      final merged = mergeTmdbSourceDetail(p, lower);
      expect(merged['title'], 'Source');
      expect(merged['overview'], 'Plot');
      expect(merged['vote_average'], 8);
      expect(merged['genres'], [
        {'id': 1},
      ]);
      expect((merged['credits'] as Map)['cast'], [
        {'id': 2},
      ]);
      expect(p.detail['overview'], ' ');
      expect(lower['title'], 'Network');
    });
    test('complete zero empty lists and empty objects are authoritative', () {
      final p = source(
        detail: {
          'vote_average': 0,
          'genres': [],
          'credits': {'cast': []},
          'images': {},
          'videos': {'results': []},
          'external_ids': {},
        },
        complete: ['core', 'credits', 'images', 'videos', 'external_ids'],
      );
      final merged = mergeTmdbSourceDetail(p, {
        'id': 42,
        'vote_average': 9,
        'genres': [1],
        'credits': {
          'cast': [1],
        },
        'images': {
          'posters': [1],
        },
        'videos': {
          'results': [1],
        },
        'external_ids': {'imdb_id': 'tt42'},
      });
      expect(merged['vote_average'], 0);
      expect(merged['genres'], isEmpty);
      expect((merged['credits'] as Map)['cast'], isEmpty);
      expect((merged['images'] as Map)['posters'], [1]);
      expect((merged['videos'] as Map)['results'], isEmpty);
      expect((merged['external_ids'] as Map)['imdb_id'], 'tt42');
    });
    test('nonempty source arrays are never appended or reordered', () {
      final p = source(
        detail: {
          'genres': [1],
          'seasons': [
            {'season_number': 1},
          ],
        },
      );
      expect(
        mergeTmdbSourceDetail(p, {
          'id': 42,
          'genres': [2],
          'seasons': [
            {'season_number': 2},
          ],
        })['genres'],
        [1],
      );
      expect(
        mergeTmdbSourceDetail(p, {
          'id': 42,
          'seasons': [
            {'season_number': 2},
          ],
        })['seasons'],
        p.detail['seasons'],
      );
    });
    test('language overrides title name overview only when target-looking', () {
      final p = source(
        language: 'en-US',
        detail: {
          'title': 'Title',
          'name': 'Name',
          'overview': 'Plot',
          'tagline': 'Tag',
          'original_title': 'Original',
        },
      );
      final merged = mergeTmdbSourceDetail(p, {
        'id': 42,
        'title': '中文标题',
        'name': '中文名',
        'overview': '中文简介',
        'tagline': '中文标语',
        'original_title': 'Changed',
      }, targetLanguage: 'zh-CN');
      expect(merged['title'], '中文标题');
      expect(merged['name'], '中文名');
      expect(merged['overview'], '中文简介');
      expect(merged['tagline'], 'Tag');
      expect(merged['original_title'], 'Original');
      expect(
        mergeTmdbSourceDetail(p, {
          'id': 42,
          'title': 'English lower',
        }, targetLanguage: 'zh-CN')['title'],
        'Title',
      );
      expect(
        mergeTmdbSourceDetail(p, {'id': 42, 'title': '中文标题'})['title'],
        'Title',
      );
      expect(
        mergeTmdbSourceDetail(
          source(language: 'zh-CN', detail: {'title': 'Source'}),
          {'id': 42, 'title': '中文'},
          targetLanguage: 'zh-CN',
        )['title'],
        'Source',
      );
    });
    test('season lower identity is validated when present', () {
      final p = source(type: 'tv', season: 1, detail: {'season_number': 1});
      expect(
        mergeTmdbSourceDetail(p, {
          'id': 42,
          'season_number': 2,
          'overview': 'wrong',
        }),
        p.detail,
      );
    });
  });
}
