import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/core/tmdb_config.dart';
import 'package:webhtv_pc/core/tmdb_media.dart' show TmdbVideoScope;
import 'package:webhtv_pc/services/tmdb_enrichment_service.dart';
import 'package:webhtv_pc/services/tmdb_identity_service.dart';
import 'package:webhtv_pc/services/tmdb_season_service.dart';
import 'package:webhtv_pc/services/tmdb_service.dart';
import 'package:webhtv_pc/state/tmdb_state.dart';
import 'package:webhtv_pc/ui/tmdb_widgets.dart' show TmdbLoadPhase;

class SourceClient extends http.BaseClient {
  final requests = <Uri>[];
  Map<String, Object?> body = {
    'id': 42,
    'media_type': 'movie',
    'title': '网络标题',
    'overview': '网络补齐简介',
  };
  int status = 200;
  Completer<void>? gate;
  Map<String, Object?> Function(Uri)? response;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request.url);
    if (gate != null) await gate!.future;
    return http.StreamedResponse(
      Stream.value(
        utf8.encode(jsonEncode(response?.call(request.url) ?? body)),
      ),
      status,
    );
  }
}

TmdbState sourceState(
  SourceClient client, {
  TmdbConfig Function()? config,
  bool Function()? current,
  TmdbMatchStore? store,
}) {
  final effective = config ?? () => const TmdbConfig();
  final service = TmdbService(config: effective, client: client);
  return TmdbState(
    config: effective,
    service: service,
    identityService: TmdbIdentityService(
      config: effective,
      service: service,
      store: store ?? InMemoryTmdbMatchStore(),
    ),
    seasonService: TmdbSeasonService(store: InMemoryTmdbSeasonStore()),
    enrichmentService: TmdbEnrichmentService(
      service: service,
      config: effective,
    ),
    isCurrentRun: current,
  );
}

Map<String, Object?> sourceDetail({bool tv = false}) => {
  'id': 42,
  'media_type': tv ? 'tv' : 'movie',
  if (tv) 'name': '来源内嵌剧集' else 'title': '来源内嵌电影',
  'overview': '订阅源直接提供的 TMDB 简介：没有凭据也应即时展示，播放线路始终来自站源。',
  'original_title': 'Source Embedded Film',
  'release_date': '2024-06-01',
  'vote_average': 8.6,
  'runtime': 112,
  'genres': [
    {'id': 18, 'name': '剧情'},
  ],
  'poster_path': 'https://fixture.test/poster.png',
  'backdrop_path': 'https://fixture.test/backdrop.png',
  'images': {'posters': [], 'backdrops': []},
  'credits': {
    'cast': [
      {'id': 8, 'name': '来源演员', 'character': '主角'},
    ],
    'crew': [],
  },
  'external_ids': {'imdb_id': 'tt0042000'},
  'videos': {'results': []},
  'recommendations': {'page': 1, 'results': []},
  'similar': {'page': 1, 'results': []},
  if (tv) ...{
    'number_of_seasons': 1,
    'number_of_episodes': 2,
    'first_air_date': '2024-06-01',
    'seasons': [
      {
        'season_number': 1,
        'episode_count': 2,
        'name': '第一季',
        'episodes': [
          {
            'id': 421,
            'season_number': 1,
            'episode_number': 1,
            'name': '源第一集',
            'overview': '源集简介',
          },
          {'id': 422, 'season_number': 1, 'episode_number': 2, 'name': '源第二集'},
        ],
        'videos': {'results': []},
      },
    ],
  },
};

Vod sourceVod({
  Map<String, Object?>? detail,
  bool tv = false,
  int? seasonNumber,
  int tmdbId = 42,
  String language = 'zh-CN',
  String id = 'source-vod',
  List<String>? complete,
}) => Vod(
  vodId: id,
  vodName: '站源播放标题',
  vodContent: '站源播放简介',
  vodPlayFrom: '原始线路',
  vodPlayUrl: r'第1集$https://play.test/1#第2集$https://play.test/2',
  extra: {
    'tmdb': {
      'schema': 1,
      'id': tmdbId,
      'media_type': tv ? 'tv' : 'movie',
      'season_number': seasonNumber ?? (tv ? 1 : 0),
      'language': language,
      'complete':
          complete ??
          [
            'core',
            'credits',
            'images',
            'external_ids',
            'videos',
            'recommendations',
            'similar',
            if (tv) 'season:1',
            if (tv) 'season_videos:1',
          ],
      'detail': detail ?? sourceDetail(tv: tv),
    },
  },
);

void main() {
  for (final completeSeason in [true, false]) {
    test(
      'title and season video scopes remain separate with own episodes; complete=$completeSeason',
      () async {
        const titleVideo = {
          'id': 'title-video',
          'key': 'dQw4w9WgXcQ',
          'site': 'YouTube',
          'name': '作品视频',
          'type': 'Trailer',
        };
        const seasonVideo = {
          'id': 'season-video',
          'key': '9bZkp7q19f0',
          'site': 'YouTube',
          'name': '第一季视频',
          'type': 'Trailer',
        };
        final client = SourceClient()
          ..body = {
            'results': [seasonVideo],
          };
        final state = sourceState(
          client,
          config: () => const TmdbConfig(apiKey: 'key'),
        );
        final detail = sourceDetail(tv: true);
        detail['episodes'] = [
          {'episode_number': 1, 'name': '来源顶层第一集'},
          {'episode_number': 2, 'name': '来源顶层第二集'},
        ];
        detail['videos'] = {
          'results': [titleVideo],
        };
        detail['seasons'] = [
          {
            'season_number': 1,
            'episode_count': 2,
            if (completeSeason)
              'videos': {
                'results': [seasonVideo],
              },
          },
        ];
        await state.loadForVod(
          sourceVod(
            tv: true,
            detail: detail,
            complete: [
              'core',
              'credits',
              'images',
              'external_ids',
              'videos',
              'recommendations',
              'similar',
              if (completeSeason) 'season_videos:1',
            ],
          ),
          siteKey: 's',
        );
        expect(state.episodes.map((e) => e.title), ['来源顶层第一集', '来源顶层第二集']);
        expect(state.videos.map((v) => v.key).toSet(), {
          'dQw4w9WgXcQ',
          '9bZkp7q19f0',
        });
        final title = state.videos.singleWhere((v) => v.key == 'dQw4w9WgXcQ');
        final season = state.videos.singleWhere((v) => v.key == '9bZkp7q19f0');
        expect(title.scope, TmdbVideoScope.tv);
        expect(title.seasonNumber, 0);
        expect(season.scope, TmdbVideoScope.season);
        expect(season.seasonNumber, 1);
        expect(state.videos.where((v) => v.key == title.key), hasLength(1));
        if (completeSeason) {
          expect(client.requests, isEmpty);
        } else {
          expect(client.requests, hasLength(1));
          expect(
            client.requests.single.path,
            endsWith('/tv/42/season/1/videos'),
          );
        }
      },
    );
  }

  test('own-season top-level episodes seed counts and retain source titles without season requests', () async {
    final client = SourceClient()
      ..body = {
        'id': 4201,
        'season_number': 1,
        'episodes': [
          {'episode_number': 1, 'name': '网络不应覆盖'},
        ],
      };
    final state = sourceState(
      client,
      config: () => const TmdbConfig(apiKey: 'key'),
    );
    final detail = sourceDetail(tv: true)..remove('seasons');
    detail['episodes'] = [
      {'episode_number': 1, 'name': '来源自有季第一集'},
      {'episode_number': 2, 'name': '来源自有季第二集'},
    ];
    await state.loadForVod(sourceVod(tv: true, detail: detail), siteKey: 's');
    expect(state.seasonEpisodeCounts[1], 2);
    expect(state.episodes.map((e) => e.title), ['来源自有季第一集', '来源自有季第二集']);
    await state.ensureAllSeasonEpisodes(
      generation: state.generation,
      allowAnySource: true,
    );
    expect(state.episodesBySeason[1]?.map((e) => e.title), [
      '来源自有季第一集',
      '来源自有季第二集',
    ]);
    expect(
      client.requests.where((u) => u.path.endsWith('/tv/42/season/1')),
      isEmpty,
    );
  });
  test('explicit source season count zero is not replaced by top-level episode length', () async {
    final state = sourceState(SourceClient());
    final detail = sourceDetail(tv: true);
    detail['seasons'] = [
      {'season_number': 1, 'episode_count': 0},
    ];
    detail['episodes'] = [
      {'episode_number': 1, 'name': '来源集'},
    ];
    await state.loadForVod(sourceVod(tv: true, detail: detail), siteKey: 's');
    expect(state.seasonEpisodeCounts[1], 0);
    expect(state.playLines.single.episodes, hasLength(2));
  });
  test('own season two metadata remains seeded while season one is fetched for a mixed line', () async {
    final client = SourceClient()
      ..response = (uri) => uri.path.endsWith('/season/1')
          ? {
              'id': 4201,
              'season_number': 1,
              'episodes': [
                {'episode_number': 1, 'name': '网络第一季集'},
              ],
            }
          : {
              'id': 4202,
              'season_number': 2,
              'episodes': [
                {'episode_number': 1, 'name': '网络不应覆盖第二季'},
              ],
            };
    final state = sourceState(
      client,
      config: () => const TmdbConfig(apiKey: 'key'),
    );
    final detail = sourceDetail(tv: true);
    detail['seasons'] = [
      {'season_number': 1, 'episode_count': 1},
      {'season_number': 2, 'episode_count': 8},
    ];
    detail['episodes'] = [
      {'episode_number': 1, 'name': '来源第二季集'},
    ];
    final raw = sourceVod(
      tv: true,
      seasonNumber: 2,
      detail: detail,
      complete: [
        'core',
        'credits',
        'images',
        'external_ids',
        'videos',
        'recommendations',
        'similar',
        'season_videos:1',
        'season_videos:2',
      ],
    ).toJson();
    raw['vod_play_url'] =
        r'S1E1$https://play.test/s1#S2E1$https://play.test/s2';
    await state.loadForVod(Vod.fromJson(raw)!, siteKey: 's');
    await state.ensureAllSeasonEpisodes(
      generation: state.generation,
      allowAnySource: true,
    );
    expect(state.seasonEpisodeCounts[2], 8);
    expect(state.episodesBySeason[2]?.single.title, '来源第二季集');
    expect(state.episodesBySeason[1]?.single.title, '网络第一季集');
    expect(
      client.requests.where((u) => u.path.endsWith('/tv/42/season/2')),
      isEmpty,
    );
    expect(
      client.requests.where((u) => u.path.endsWith('/tv/42/season/1')),
      hasLength(1),
    );
  });

  test('missing season fills once and shares metadata with aggregation and same-work reload', () async {
    final client = SourceClient()
      ..body = {
        'id': 4201,
        'season_number': 1,
        'episodes': [
          {'id': 421, 'season_number': 1, 'episode_number': 1, 'name': '补齐第一集'},
          {'id': 422, 'season_number': 1, 'episode_number': 2, 'name': '补齐第二集'},
        ],
      };
    final state = sourceState(
      client,
      config: () => const TmdbConfig(apiKey: 'key'),
    );
    final detail = sourceDetail(tv: true);
    detail['seasons'] = [
      {
        'season_number': 1,
        'episode_count': 2,
        'videos': {'results': []},
      },
    ];
    final vod = sourceVod(
      tv: true,
      detail: detail,
      complete: [
        'core',
        'credits',
        'images',
        'external_ids',
        'videos',
        'recommendations',
        'similar',
        'season_videos:1',
      ],
    );
    await state.loadForVod(vod, siteKey: 's');
    expect(state.episodes.map((e) => e.title), ['补齐第一集', '补齐第二集']);
    await state.ensureAllSeasonEpisodes(
      generation: state.generation,
      allowAnySource: true,
    );
    await state.loadForVod(vod, siteKey: 's');
    expect(client.requests.length, 1);
    expect(client.requests.single.path, endsWith('/tv/42/season/1'));
    expect(state.episodesBySeason[1]?.length, 2);
  });
  test('source empty and zero complete fields remain semantic during selective related filling', () async {
    final client = SourceClient()
      ..body = {
        ...sourceDetail(),
        'vote_average': 9.9,
        'genres': [
          {'id': 1, 'name': '网络类型'},
        ],
        'recommendations': {
          'page': 1,
          'results': [
            {'id': 8, 'title': '不应覆盖', 'media_type': 'movie'},
          ],
        },
        'similar': {
          'page': 1,
          'results': [
            {'id': 9, 'title': '缺口相关推荐', 'media_type': 'movie'},
          ],
        },
      };
    final state = sourceState(
      client,
      config: () => const TmdbConfig(apiKey: 'key'),
    );
    final detail = {
      ...sourceDetail(),
      'vote_average': 0,
      'runtime': 0,
      'genres': [],
    }..remove('similar');
    await state.loadForVod(
      sourceVod(
        detail: detail,
        complete: [
          'core',
          'credits',
          'images',
          'external_ids',
          'videos',
          'recommendations',
        ],
      ),
      siteKey: 's',
    );
    expect(
      client.requests.single.queryParameters['append_to_response'],
      'similar',
    );
    expect(state.detail?['vote_average'], 0);
    expect(state.detail?['genres'], isEmpty);
    expect(state.recommendations.map((e) => e.title), ['缺口相关推荐']);
    expect(state.videos, isEmpty);
  });
  test('incompatible source display language requests core only and fills target title', () async {
    final client = SourceClient()..body = sourceDetail();
    final state = sourceState(
      client,
      config: () => const TmdbConfig(apiKey: 'key'),
    );
    await state.loadForVod(
      sourceVod(
        language: 'en-US',
        detail: {
          ...sourceDetail(),
          'title': 'English Source',
          'overview': 'English source overview',
        },
      ),
      siteKey: 's',
    );
    expect(client.requests.length, 1);
    expect(
      client.requests.single.queryParameters['append_to_response'],
      isNull,
    );
    expect(state.detailData?.title, '来源内嵌电影');
    expect(state.detail?['overview'], sourceDetail()['overview']);
  });

  test('source wins over automatic cache and site policy suppresses source with no key', () async {
    final client = SourceClient();
    final store = InMemoryTmdbMatchStore();
    final vod = sourceVod();
    store.putAuto(
      siteKey: 's',
      vodId: vod.vodId,
      sourceTitle: vod.vodName,
      item: const TmdbItem(
        tmdbId: 7,
        mediaType: TmdbMediaType.movie,
        title: '旧自动缓存',
      ),
      matchedAt: 1,
    );
    final state = sourceState(
      client,
      store: store,
      config: () => const TmdbConfig(apiKey: 'key'),
    );
    await state.loadForVod(vod, siteKey: 's');
    expect(state.identity?.tmdbId, 42);
    expect(client.requests, isEmpty);
    final off = sourceState(
      client,
      config: () => const TmdbConfig(disabledSites: ['s']),
    );
    await off.loadForVod(vod, siteKey: 's');
    expect(off.detailData, isNull);
    expect(client.requests, isEmpty);
  });
  test('new source identity under same vod replaces old work data', () async {
    final client = SourceClient();
    final state = sourceState(client);
    await state.loadForVod(sourceVod(), siteKey: 's');
    await state.loadForVod(
      sourceVod(
        tmdbId: 43,
        detail: {
          ...sourceDetail(),
          'id': 43,
          'title': '新来源身份',
          'credits': {'cast': [], 'crew': []},
        },
      ),
      siteKey: 's',
    );
    expect(state.identity?.tmdbId, 43);
    expect(state.detailData?.title, '新来源身份');
    expect(state.cast, isEmpty);
    expect(client.requests, isEmpty);
  });
  test('source first paint precedes in-flight network and wrong identity fill is rejected', () async {
    final client = SourceClient()
      ..gate = Completer<void>()
      ..body = {...sourceDetail(), 'id': 99};
    final state = sourceState(
      client,
      config: () => const TmdbConfig(apiKey: 'key'),
    );
    final partial = sourceDetail()..remove('credits');
    final load = state.loadForVod(
      sourceVod(
        detail: partial,
        complete: [
          'core',
          'images',
          'external_ids',
          'videos',
          'recommendations',
          'similar',
        ],
      ),
      siteKey: 's',
    );
    expect(state.detailData?.title, '来源内嵌电影');
    expect(state.cast, isEmpty);
    client.gate!.complete();
    await load;
    expect(state.identity?.tmdbId, 42);
    expect(state.cast, isEmpty);
    expect(state.detailData?.title, '来源内嵌电影');
  });
  test(
    'incomplete lower response must not falsely complete a missing group',
    () async {
      final client = SourceClient()..body = {'id': 42, 'title': '网络标题'};
      final state = sourceState(
        client,
        config: () => const TmdbConfig(apiKey: 'key'),
      );
      final partial = sourceDetail()..remove('credits');
      final vod = sourceVod(
        detail: partial,
        complete: [
          'core',
          'images',
          'external_ids',
          'videos',
          'recommendations',
          'similar',
        ],
      );
      await state.loadForVod(vod, siteKey: 's');
      await state.loadForVod(vod, siteKey: 's');
      expect(state.cast, isEmpty);
      expect(client.requests.length, 2);
    },
  );

  test(
    'stale asynchronous source fill is discarded when another work starts',
    () async {
      final client = SourceClient()..gate = Completer<void>();
      final state = sourceState(
        client,
        config: () => const TmdbConfig(apiKey: 'key'),
      );
      final partial = sourceDetail()..remove('credits');
      final first = state.loadForVod(
        sourceVod(
          detail: partial,
          complete: [
            'core',
            'images',
            'external_ids',
            'videos',
            'recommendations',
            'similar',
          ],
        ),
        siteKey: 's',
      );
      expect(state.detailData?.title, '来源内嵌电影');
      await state.loadForVod(
        sourceVod(
          id: 'other-vod',
          detail: {
            ...sourceDetail(),
            'title': '第二部',
            'overview': '第二部简介',
            'credits': {'cast': [], 'crew': []},
          },
        ),
        siteKey: 's',
      );
      client.gate!.complete();
      await first;
      expect(state.vodId, 'other-vod');
      expect(state.detail?['title'], '第二部');
      expect(state.detailData?.title, '第二部');
      expect(state.cast, isEmpty);
    },
  );
  test('same-work reuse and manual rematch are not replaced by stale source payload', () async {
    final client = SourceClient();
    final store = InMemoryTmdbMatchStore();
    final state = sourceState(
      client,
      config: () => const TmdbConfig(apiKey: 'key'),
      store: store,
    );
    final vod = sourceVod();
    await state.loadForVod(vod, siteKey: 's');
    final count = client.requests.length;
    await state.loadForVod(vod, siteKey: 's');
    expect(client.requests.length, count);
    store.putManual(
      siteKey: 's',
      vodId: vod.vodId,
      sourceTitles: [vod.vodName],
      item: TmdbItem(
        tmdbId: 7,
        mediaType: TmdbMediaType.movie,
        title: '手动选择作品',
      ),
      matchedAt: 1,
    );
    client.body = {'id': 7, 'title': '手动选择作品'};
    await state.loadForVod(vod, siteKey: 's');
    expect(state.identity?.tmdbId, 7);
    expect(state.detail?['title'], '手动选择作品');
    store.remove(siteKey: 's', vodId: vod.vodId);
    await state.loadForVod(vod, siteKey: 's');
    expect(state.identity?.tmdbId, 42);
  });
  test('configuration changes reject stale source fill and disabled policy zero requests', () async {
    final client = SourceClient()..gate = Completer<void>();
    var config = const TmdbConfig(apiKey: 'key');
    final state = sourceState(client, config: () => config);
    final partial = sourceDetail()..remove('credits');
    final pending = state.loadForVod(
      sourceVod(
        detail: partial,
        complete: [
          'core',
          'images',
          'external_ids',
          'videos',
          'recommendations',
          'similar',
        ],
      ),
      siteKey: 's',
    );
    config = const TmdbConfig(apiKey: 'other');
    client.gate!.complete();
    await pending;
    expect(state.detailData?.title, '来源内嵌电影');
    expect(state.cast, isEmpty);
    config = const TmdbConfig(enabled: false);
    final blocked = SourceClient();
    final off = sourceState(blocked, config: () => config);
    await off.loadForVod(sourceVod(), siteKey: 's');
    expect(off.detailData, isNull);
    expect(blocked.requests, isEmpty);
  });
  test('renderable payload publishes synchronously without credentials and preserves playback/enrichment roundtrip', () async {
    final client = SourceClient();
    final state = sourceState(client);
    final vod = sourceVod();
    final loading = state.loadForVod(vod, siteKey: 's');
    expect(state.detailData?.title, '来源内嵌电影');
    expect(state.detail?['overview'], sourceDetail()['overview']);
    await loading;
    expect(client.requests, isEmpty);
    expect(state.playLines.single.episodes.map((e) => e.url), [
      'https://play.test/1',
      'https://play.test/2',
    ]);
    expect(state.enrich(vod).vod.extra['tmdb'], vod.extra['tmdb']);
    expect(state.enrich(vod).vod.vodPlayUrl, vod.vodPlayUrl);
  });
  test(
    'complete payload with credentials avoids all search/detail/video requests',
    () async {
      final client = SourceClient();
      final state = sourceState(
        client,
        config: () => const TmdbConfig(apiKey: 'key'),
      );
      await state.loadForVod(sourceVod(), siteKey: 's');
      expect(state.detailData?.title, '来源内嵌电影');
      expect(client.requests, isEmpty);
    },
  );
  test(
    'unknown or nested junk payload is identity-only without credentials',
    () async {
      final client = SourceClient();
      final state = sourceState(client);
      await state.loadForVod(
        sourceVod(
          detail: {
            'future_field': {
              'unknown': [
                {'foo': 'bar'},
              ],
            },
            'junk_count': 7,
          },
          complete: [],
        ),
        siteKey: 's',
      );
      expect(state.detail, isNull);
      expect(state.detailData, isNull);
      expect(state.hasMatch, isFalse);
      expect(state.phase, TmdbLoadPhase.disabled);
      expect(client.requests, isEmpty);
    },
  );
  for (final entry in <String, Map<String, Object?>>{
    'overview': {'overview': '仅简介也算可渲染'},
    'genres': {
      'genres': [
        {'id': 18, 'name': '剧情'},
      ],
    },
    'external id': {
      'external_ids': {'imdb_id': 'tt0042000'},
    },
    'images.posters': {
      'images': {
        'posters': [
          {'file_path': '/poster.png'},
        ],
      },
    },
  }.entries) {
    test(
      'whitelisted ${entry.key} is renderable without credentials',
      () async {
        final client = SourceClient();
        final state = sourceState(client);
        await state.loadForVod(
          sourceVod(detail: entry.value, complete: []),
          siteKey: 's',
        );
        expect(state.detail, entry.value);
        expect(state.hasMatch, isTrue);
        expect(state.phase, TmdbLoadPhase.ready);
        expect(client.requests, isEmpty);
      },
    );
  }
  test(
    'identity only with ready credentials still fills through network',
    () async {
      final client = SourceClient();
      final state = sourceState(
        client,
        config: () => const TmdbConfig(apiKey: 'key'),
      );
      await state.loadForVod(
        sourceVod(detail: {}, complete: []),
        siteKey: 's',
      );
      expect(
        client.requests.where((url) => url.path.endsWith('/movie/42')),
        isNotEmpty,
      );
      expect(state.detailData?.title, '网络标题');
    },
  );
  test('identity only with no credentials does not fabricate detail', () async {
    final client = SourceClient();
    final state = sourceState(client);
    await state.loadForVod(
      sourceVod(detail: {}, complete: []),
      siteKey: 's',
    );
    expect(state.detailData, isNull);
    expect(state.detail, isNull);
    expect(client.requests, isEmpty);
  });
  test(
    'partial payload appends only missing groups and source values win',
    () async {
      final client = SourceClient()
        ..body = {
          ...sourceDetail(),
          'title': '网络标题',
          'vote_average': 9.9,
          'credits': {
            'cast': [
              {'id': 9, 'name': '补齐演员'},
            ],
            'crew': [],
          },
        };
      final state = sourceState(
        client,
        config: () => const TmdbConfig(apiKey: 'key'),
      );
      final detail = sourceDetail()
        ..remove('credits')
        ..remove('images')
        ..remove('poster_path')
        ..remove('backdrop_path');
      await state.loadForVod(
        sourceVod(
          detail: detail,
          complete: [
            'core',
            'external_ids',
            'videos',
            'recommendations',
            'similar',
          ],
        ),
        siteKey: 's',
      );
      expect(client.requests.length, 1);
      expect(client.requests.single.path, endsWith('/movie/42'));
      expect(
        client.requests.single.queryParameters['append_to_response']!
            .split(',')
            .toSet(),
        {'credits', 'images'},
      );
      expect(state.detailData?.title, '来源内嵌电影');
      expect(state.detailData?.rating, 8.6);
      expect(state.cast.single.name, '补齐演员');
      expect(state.detailData?.posterUrl, isNotEmpty);
    },
  );
  test('network failure preserves source first paint', () async {
    final client = SourceClient()..status = 500;
    final state = sourceState(
      client,
      config: () => const TmdbConfig(apiKey: 'key'),
    );
    final detail = sourceDetail()..remove('credits');
    await state.loadForVod(
      sourceVod(
        detail: detail,
        complete: [
          'core',
          'images',
          'external_ids',
          'videos',
          'recommendations',
          'similar',
        ],
      ),
      siteKey: 's',
    );
    expect(state.detailData?.title, '来源内嵌电影');
    expect(state.detail?['overview'], detail['overview']);
  });
  test('source season metadata is consumed without requests or changing source episodes', () async {
    final client = SourceClient();
    final state = sourceState(
      client,
      config: () => const TmdbConfig(apiKey: 'key'),
    );
    final vod = sourceVod(tv: true);
    await state.loadForVod(vod, siteKey: 's');
    expect(state.episodes.map((e) => e.title), ['源第一集', '源第二集']);
    await state.ensureAllSeasonEpisodes(
      generation: state.generation,
      allowAnySource: true,
    );
    expect(state.episodesBySeason[1]?.length, 2);
    expect(client.requests, isEmpty);
    expect(state.playLines.single.episodes.length, 2);
    expect(state.playLines.single.episodes.first.name, '第1集');
  });
}
