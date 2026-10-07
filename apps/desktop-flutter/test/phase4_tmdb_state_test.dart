/// Phase 4 · TMDB 状态层（`docs/phase4/design/04` §2.2）。
///
/// 对应门禁：`docs/phase4/design/05` §3.11 与 §4.4「代际防迟到响应 / 加载阶段 /
/// 错误隔离 / 季度切换」。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/tmdb_config.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/core/tmdb_season.dart';
import 'package:webhtv_pc/services/tmdb_enrichment_service.dart';
import 'package:webhtv_pc/services/tmdb_identity_service.dart';
import 'package:webhtv_pc/services/tmdb_season_service.dart';
import 'package:webhtv_pc/services/tmdb_service.dart';
import 'package:webhtv_pc/state/tmdb_state.dart';
import 'package:webhtv_pc/ui/tmdb_widgets.dart' show TmdbLoadPhase;

// ---------------------------------------------------------------------------
// fake HTTP
// ---------------------------------------------------------------------------

class _FakeClient extends http.BaseClient {
  final List<Uri> requests = [];
  final List<(String, Object?)> routes = [];
  Object? failure;

  int get count => requests.length;

  void route(String suffix, Object? body) => routes.add((suffix, body));

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request.url);
    final local = failure;
    if (local != null) throw local;
    for (final (suffix, body) in routes) {
      if (request.url.path.endsWith(suffix)) {
        final text = body is String ? body : jsonEncode(body);
        return http.StreamedResponse(
          Stream<List<int>>.value(utf8.encode(text)),
          200,
        );
      }
    }
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode('{"status_code":404}')),
      404,
    );
  }
}

/// 总是 401。
class _AuthFailClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(
        Stream<List<int>>.value(utf8.encode('{"status_code":7}')),
        401,
      );
}

TmdbConfig _ready() => const TmdbConfig(apiKey: 'k');

TmdbState _state({
  required TmdbConfig Function() config,
  required http.Client client,
  TmdbMatchStore? store,
  TmdbSeasonStore? seasonStore,
}) {
  final service = TmdbService(config: config, client: client);
  return TmdbState(
    config: config,
    service: service,
    identityService: TmdbIdentityService(
      config: config,
      service: service,
      store: store ?? InMemoryTmdbMatchStore(),
    ),
    seasonService: TmdbSeasonService(
      store: seasonStore ?? InMemoryTmdbSeasonStore(),
    ),
    enrichmentService: TmdbEnrichmentService(service: service, config: config),
  );
}

Vod _vod({String name = '来源剧名'}) => Vod(vodId: 'v1', vodName: name);

TmdbSourceLine _line({int count = 10}) => TmdbSourceLine(
  flagKey: 'f#0',
  sourceFlag: '线路一',
  episodeNames: List.generate(count, (i) => '第${i + 1}集'),
);

VodPlayLine _playLine({int count = 10}) => VodPlayLine(
  flag: '线路一',
  episodes: [
    for (var i = 0; i < count; i++)
      VodEpisode(name: '第${i + 1}集', url: 'https://cdn/e${i + 1}.m3u8'),
  ],
);

void main() {
  group('前置检查：未配置 / 站点禁用（零请求）', () {
    test('未配置 → disabled 且零请求', () {
      final client = _FakeClient();
      final state = _state(config: () => const TmdbConfig(), client: client);
      final generation = state.beginLoad(
        siteKey: 's',
        vodId: 'v',
        sourceTitle: '剧名',
        vod: _vod(),
        line: _line(),
      );
      expect(state.phase, TmdbLoadPhase.disabled);
      expect(state.matchResult, isA<TmdbMatchDisabled>());
      expect(
        (state.matchResult as TmdbMatchDisabled).reason,
        TmdbMissReason.notConfigured,
      );
      expect(state.shouldRender, isTrue, reason: '未配置必须渲染入口，否则无法进入设置页');
      expect(state.notConfigured, isTrue);
      expect(state.siteDisabled, isFalse);
      expect(client.count, 0);
      expect(generation, greaterThan(0));
      state.dispose();
    });

    test('站点禁用 → disabled 且零请求', () {
      final client = _FakeClient();
      final config = const TmdbConfig(apiKey: 'k', disabledSites: ['[书]']);
      final state = _state(config: () => config, client: client);
      state.beginLoad(
        siteKey: '[书]站',
        vodId: 'v',
        sourceTitle: '剧名',
        vod: _vod(),
        line: _line(),
      );
      expect(state.phase, TmdbLoadPhase.disabled);
      expect(
        (state.matchResult as TmdbMatchDisabled).reason,
        TmdbMissReason.siteDisabled,
      );
      expect(client.count, 0);
      state.dispose();
    });
  });

  group('加载阶段（§3.3）', () {
    test('beginLoad → loading', () {
      final client = _FakeClient();
      final state = _state(config: _ready, client: client);
      state.beginLoad(
        siteKey: 's',
        vodId: 'v',
        sourceTitle: '剧名',
        vod: _vod(),
        line: _line(),
      );
      expect(state.phase, TmdbLoadPhase.loading);
      expect(state.shouldRender, isTrue);
      state.dispose();
    });

    test('匹配成功 → ready', () async {
      final client = _FakeClient()
        ..route('/search/multi', {
          'results': [
            {
              'id': 1399,
              'media_type': 'tv',
              'name': '来源剧名',
              'first_air_date': '2024-01-01',
            },
          ],
        })
        ..route('/tv/1399', {'id': 1399, 'name': '来源剧名'});
      final state = _state(config: _ready, client: client);
      final generation = state.beginLoad(
        siteKey: 's',
        vodId: 'v',
        sourceTitle: '来源剧名',
        vod: _vod(),
        line: _line(),
      );
      await state.loadMatch(generation: generation, sourceTitle: '来源剧名');
      expect(state.phase, TmdbLoadPhase.ready);
      expect(state.hasMatch, isTrue);
      expect(state.item?.identity?.key, 'tv:1399');
      state.dispose();
    });

    test('匹配失败 → ready 但 hasMatch 为 false（不阻塞页面）', () async {
      final client = _FakeClient()..route('/search/multi', {'results': []});
      final state = _state(config: _ready, client: client);
      final generation = state.beginLoad(
        siteKey: 's',
        vodId: 'v',
        sourceTitle: '剧名',
        vod: _vod(),
        line: _line(),
      );
      await state.loadMatch(generation: generation, sourceTitle: '剧名');
      expect(state.phase, TmdbLoadPhase.ready);
      expect(state.hasMatch, isFalse);
      expect(state.error, isNull, reason: '未匹配不是错误');
      state.dispose();
    });

    test('网络失败 → failed 且带可定位错误', () async {
      final client = _FakeClient()
        ..failure = const FormatException('boom');
      final state = _state(config: _ready, client: client);
      final generation = state.beginLoad(
        siteKey: 's',
        vodId: 'v',
        sourceTitle: '剧名',
        vod: _vod(),
        line: _line(),
      );
      await state.loadMatch(generation: generation, sourceTitle: '剧名');
      expect(state.phase, TmdbLoadPhase.failed);
      expect(state.error, isNotNull);
      expect(isTmdbError(state.error), isTrue);
      state.dispose();
    });

    test('鉴权失败 → failed + tmdbAuth', () async {
      final state = _state(config: _ready, client: _AuthFailClient());
      final generation = state.beginLoad(
        siteKey: 's',
        vodId: 'v',
        sourceTitle: '剧名',
        vod: _vod(),
        line: _line(),
      );
      await state.loadMatch(generation: generation, sourceTitle: '剧名');
      expect(state.phase, TmdbLoadPhase.failed);
      expect(state.error?.kind, AppErrorKind.tmdbAuth);
      state.dispose();
    });
  });

  group('代际防迟到响应（§2.2）', () {
    test('旧代际的 loadMatch 结果被丢弃', () async {
      final client = _FakeClient()
        ..route('/search/multi', {
          'results': [
            {
              'id': 1399,
              'media_type': 'tv',
              'name': 'A',
              'first_air_date': '2024-01-01',
            },
          ],
        })
        ..route('/tv/1399', {'id': 1399, 'name': 'A'});
      final state = _state(config: _ready, client: client);
      final first = state.beginLoad(
        siteKey: 's',
        vodId: 'v',
        sourceTitle: 'A',
        vod: _vod(name: 'A'),
        line: _line(),
      );
      // 第二次 beginLoad 使第一次失效
      state.beginLoad(
        siteKey: 's',
        vodId: 'v2',
        sourceTitle: 'B',
        vod: _vod(name: 'B'),
        line: _line(),
      );
      await state.loadMatch(generation: first, sourceTitle: 'A');
      expect(
        state.hasMatch,
        isFalse,
        reason: '旧代际结果必须被丢弃',
      );
      state.dispose();
    });

    test('旧代际的 loadDetail 结果被丢弃', () async {
      final client = _FakeClient()
        ..route('/search/multi', {
          'results': [
            {
              'id': 1399,
              'media_type': 'tv',
              'name': '剧名',
              'first_air_date': '2024-01-01',
            },
          ],
        })
        ..route('/tv/1399', {'id': 1399, 'name': '剧名'});
      final state = _state(config: _ready, client: client);
      final first = state.beginLoad(
        siteKey: 's',
        vodId: 'v',
        sourceTitle: '剧名',
        vod: _vod(),
        line: _line(),
      );
      await state.loadMatch(generation: first, sourceTitle: '剧名');
      expect(state.hasMatch, isTrue);

      state.beginLoad(
        siteKey: 's',
        vodId: 'v2',
        sourceTitle: '剧名',
        vod: _vod(),
        line: _line(),
      );
      // 用旧代际加载详情 → 必须丢弃
      await state.loadDetail(
        generation: first,
        tmdbSeasons: const [1],
        seasonCounts: const {1: 10},
      );
      expect(state.detail, isNull, reason: '旧代际详情必须被丢弃');
      expect(state.resolution, isNull);
      state.dispose();
    });

    test('dispose 后所有回调失效', () async {
      final client = _FakeClient()
        ..route('/search/multi', {
          'results': [
            {
              'id': 1399,
              'media_type': 'tv',
              'name': '剧名',
              'first_air_date': '2024-01-01',
            },
          ],
        })
        ..route('/tv/1399', {'id': 1399, 'name': '剧名'});
      final state = _state(config: _ready, client: client);
      final generation = state.beginLoad(
        siteKey: 's',
        vodId: 'v',
        sourceTitle: '剧名',
        vod: _vod(),
        line: _line(),
      );
      state.dispose();
      expect(state.isDisposed, isTrue);
      // dispose 后调用不应抛异常，也不应改变状态
      await state.loadMatch(generation: generation, sourceTitle: '剧名');
      expect(state.hasMatch, isFalse);
    });
  });

  group('详情 + 季度加载（§4.3）', () {
    test('加载详情后解析季度并返回可播放季度', () async {
      final client = _FakeClient()
        ..route('/search/multi', {
          'results': [
            {
              'id': 1399,
              'media_type': 'tv',
              'name': '剧名',
              'first_air_date': '2024-01-01',
            },
          ],
        })
        ..route('/tv/1399', {
          'id': 1399,
          'name': '剧名',
          'seasons': [
            {'season_number': 1, 'episode_count': 12, 'air_date': '2024-03-01'},
            {'season_number': 2, 'episode_count': 10, 'air_date': '2025-04-05'},
          ],
          'credits': {
            'cast': [
              {'id': 1, 'name': '演员A', 'character': '主角'},
            ],
          },
          'created_by': [
            {'id': 3, 'name': '导演A'},
          ],
          'images': {
            'backdrops': [
              {'file_path': '/b.jpg', 'width': 1920, 'height': 1080},
            ],
          },
          'recommendations': {
            'results': [
              {
                'id': 1400,
                'media_type': 'tv',
                'name': '推荐',
                'first_air_date': '2022-01-01',
              },
            ],
          },
          'similar': {
            'results': [
              {
                'id': 1401,
                'media_type': 'tv',
                'name': '相似',
                'first_air_date': '2021-01-01',
              },
            ],
          },
        });
      final state = _state(config: _ready, client: client);
      final generation = state.beginLoad(
        siteKey: 's',
        vodId: 'v',
        sourceTitle: '剧名',
        vod: _vod(),
        line: _line(count: 12),
      );
      await state.loadMatch(generation: generation, sourceTitle: '剧名');
      await state.loadDetail(
        generation: generation,
        tmdbSeasons: const [1, 2],
        seasonCounts: const {1: 12, 2: 10},
      );
      expect(state.phase, TmdbLoadPhase.ready);
      expect(state.detail, isNotNull);
      expect(state.cast.length, 1);
      expect(state.creators.length, 1);
      expect(state.photos, isNotEmpty);
      expect(state.recommendations.length, 2);
      // 12 集恰好等于 S1 集数 → resolved(1)
      expect(state.scope, const KnownSeason(1));
      expect(state.selectedSeason, 1);
      expect(state.hasSeasonSwitcher, isFalse);
      state.dispose();
    });

    test('季度集数从详情 seasons[] 提取', () async {
      final client = _FakeClient()
        ..route('/search/multi', {
          'results': [
            {
              'id': 1399,
              'media_type': 'tv',
              'name': '剧名',
              'first_air_date': '2024-01-01',
            },
          ],
        })
        ..route('/tv/1399', {
          'id': 1399,
          'name': '剧名',
          'seasons': [
            {'season_number': 1, 'episode_count': 12},
            {'season_number': 0, 'episode_count': 0}, // 应被过滤
          ],
        });
      final state = _state(config: _ready, client: client);
      final generation = state.beginLoad(
        siteKey: 's',
        vodId: 'v',
        sourceTitle: '剧名',
        vod: _vod(),
        line: _line(count: 12),
      );
      await state.loadMatch(generation: generation, sourceTitle: '剧名');
      await state.loadDetail(
        generation: generation,
        tmdbSeasons: const [1],
        seasonCounts: const {},
      );
      expect(state.seasonEpisodeCounts, {1: 12});
      state.dispose();
    });

    test('详情失败 → failed，但已有匹配信息保留', () async {
      final client = _FakeClient()
        ..route('/search/multi', {
          'results': [
            {
              'id': 1399,
              'media_type': 'tv',
              'name': '剧名',
              'first_air_date': '2024-01-01',
            },
          ],
        });
      // 详情路由缺失 → 404
      final state = _state(config: _ready, client: client);
      final generation = state.beginLoad(
        siteKey: 's',
        vodId: 'v',
        sourceTitle: '剧名',
        vod: _vod(),
        line: _line(),
      );
      await state.loadMatch(generation: generation, sourceTitle: '剧名');
      await state.loadDetail(
        generation: generation,
        tmdbSeasons: const [1],
        seasonCounts: const {1: 10},
      );
      expect(state.phase, TmdbLoadPhase.failed);
      expect(state.error?.kind, AppErrorKind.tmdbHttp);
      // 匹配信息仍在（头部仍可渲染）
      expect(state.hasMatch, isTrue);
      state.dispose();
    });
  });

  group('季度切换（§4.3）', () {
    Future<TmdbState> buildMultiSeasonState(_FakeClient client) async {
      client
        ..route('/search/multi', {
          'results': [
            {
              'id': 1399,
              'media_type': 'tv',
              'name': '剧名',
              'first_air_date': '2024-01-01',
            },
          ],
        })
        ..route('/tv/1399', {
          'id': 1399,
          'name': '剧名',
          'seasons': [
            {'season_number': 1, 'episode_count': 3},
            {'season_number': 2, 'episode_count': 2},
          ],
        })
        ..route('/season/1', {
          'episodes': [
            {'episode_number': 1, 'season_number': 1, 'name': 'S1E1'},
            {'episode_number': 2, 'season_number': 1, 'name': 'S1E2'},
            {'episode_number': 3, 'season_number': 1, 'name': 'S1E3'},
          ],
        })
        ..route('/season/2', {
          'episodes': [
            {'episode_number': 1, 'season_number': 2, 'name': 'S2E1'},
            {'episode_number': 2, 'season_number': 2, 'name': 'S2E2'},
          ],
        });
      final state = _state(config: _ready, client: client);
      final generation = state.beginLoad(
        siteKey: 's',
        vodId: 'v',
        sourceTitle: '剧名',
        vod: _vod(),
        line: _line(count: 5),
      );
      await state.loadMatch(generation: generation, sourceTitle: '剧名');
      await state.loadDetail(
        generation: generation,
        tmdbSeasons: const [1, 2],
        seasonCounts: const {1: 3, 2: 2},
      );
      await state.loadEpisodes(generation: generation);
      return state;
    }

    test('多季可切换，hasSeasonSwitcher 为 true', () async {
      final state = await buildMultiSeasonState(_FakeClient());
      expect(state.availableSeasons, [1, 2]);
      expect(state.hasSeasonSwitcher, isTrue);
      expect(state.selectedSeason, 1);
      state.dispose();
    });

    test('切换季度清空旧剧集', () async {
      final client = _FakeClient();
      final state = await buildMultiSeasonState(client);
      expect(state.episodes.length, 3, reason: 'S1 有 3 集');
      state.selectSeason(2);
      expect(state.selectedSeason, 2);
      expect(state.episodes, isEmpty, reason: '切换后必须清空旧季度剧集');
      state.dispose();
    });

    test('切换到不可用季度被忽略', () async {
      final state = await buildMultiSeasonState(_FakeClient());
      state.selectSeason(9);
      expect(state.selectedSeason, 1, reason: '不在 availableSeasons 内应忽略');
      state.dispose();
    });

    test('切换到同一季度无副作用', () async {
      final state = await buildMultiSeasonState(_FakeClient());
      final before = state.episodes;
      state.selectSeason(1);
      expect(identical(state.episodes, before), isTrue);
      state.dispose();
    });

    test('loadEpisodes 后按季加载对应剧集', () async {
      final client = _FakeClient();
      final state = await buildMultiSeasonState(client);
      expect(state.episodes.map((e) => e.title), ['S1E1', 'S1E2', 'S1E3']);
      state.selectSeason(2);
      await state.loadEpisodes(generation: state.generation);
      expect(state.episodes.map((e) => e.title), ['S2E1', 'S2E2']);
      state.dispose();
    });

    test('剧集元数据加载失败不影响状态（保留空列表）', () async {
      final client = _FakeClient()
        ..route('/search/multi', {
          'results': [
            {
              'id': 1399,
              'media_type': 'tv',
              'name': '剧名',
              'first_air_date': '2024-01-01',
            },
          ],
        })
        ..route('/tv/1399', {
          'id': 1399,
          'name': '剧名',
          'seasons': [
            {'season_number': 1, 'episode_count': 10},
          ],
        });
      // 缺 /season/1 路由 → 404
      final state = _state(config: _ready, client: client);
      final generation = state.beginLoad(
        siteKey: 's',
        vodId: 'v',
        sourceTitle: '剧名',
        vod: _vod(),
        line: _line(count: 10),
      );
      await state.loadMatch(generation: generation, sourceTitle: '剧名');
      await state.loadDetail(
        generation: generation,
        tmdbSeasons: const [1],
        seasonCounts: const {1: 10},
      );
      await state.loadEpisodes(generation: generation);
      expect(state.episodes, isEmpty);
      expect(state.phase, TmdbLoadPhase.ready, reason: '剧集元数据失败不影响主状态');
      state.dispose();
    });
  });

  group('剧集元数据应用与头部补位', () {
    test('applyEpisodesToLine 应用当前季度元数据', () async {
      final client = _FakeClient()
        ..route('/search/multi', {
          'results': [
            {
              'id': 1399,
              'media_type': 'tv',
              'name': '剧名',
              'first_air_date': '2024-01-01',
            },
          ],
        })
        ..route('/tv/1399', {
          'id': 1399,
          'name': '剧名',
          'seasons': [
            {'season_number': 1, 'episode_count': 2},
          ],
        })
        ..route('/season/1', {
          'episodes': [
            {'episode_number': 1, 'season_number': 1, 'name': '真相'},
            {'episode_number': 2, 'season_number': 1, 'name': '答案'},
          ],
        });
      final state = _state(config: _ready, client: client);
      final generation = state.beginLoad(
        siteKey: 's',
        vodId: 'v',
        sourceTitle: '剧名',
        vod: _vod(),
        line: _line(count: 2),
      );
      await state.loadMatch(generation: generation, sourceTitle: '剧名');
      await state.loadDetail(
        generation: generation,
        tmdbSeasons: const [1],
        seasonCounts: const {1: 2},
      );
      await state.loadEpisodes(generation: generation);

      final line = _playLine(count: 2);
      final result = state.applyEpisodesToLine(line);
      expect(result.changed, isTrue);
      expect(result.appliedCount, 2);
      expect(result.line.episodes[0].extra['display_name'], 'E1 真相');
      state.dispose();
    });

    test('季度未知（-1）时 applyEpisodesToLine 不应用', () {
      final client = _FakeClient();
      final state = _state(config: _ready, client: client);
      final result = state.applyEpisodesToLine(_playLine(count: 2));
      expect(result.changed, isFalse);
      expect(result.rejectedReason, 'no_metadata');
      state.dispose();
    });

    test('enrich 头部补位（手动匹配到不同标题的作品）', () async {
      // 站源标题与 TMDB 标题不同：真实路径是用户手动匹配（`01` §7）。
      final store = InMemoryTmdbMatchStore();
      store.cache.putManual(
        's',
        'v',
        ['来源剧名'],
        const TmdbItem(
          tmdbId: 1399,
          mediaType: TmdbMediaType.tv,
          title: 'TMDB 标题',
        ),
        matchedAt: 1,
      );
      final client = _FakeClient()
        ..route('/tv/1399', {
          'id': 1399,
          'name': 'TMDB 标题',
          'overview': 'TMDB 简介',
          'first_air_date': '2024-03-01',
        });
      final state = _state(config: _ready, client: client, store: store);
      final generation = state.beginLoad(
        siteKey: 's',
        vodId: 'v',
        sourceTitle: '来源剧名',
        vod: _vod(),
        line: _line(),
      );
      await state.loadMatch(generation: generation, sourceTitle: '来源剧名');
      expect(state.hasMatch, isTrue);
      await state.loadDetail(
        generation: generation,
        tmdbSeasons: const [1],
        seasonCounts: const {1: 10},
      );
      final result = state.enrich(_vod());
      expect(result.vod.vodName, 'TMDB 标题');
      expect(result.vod.vodContent, 'TMDB 简介');
      expect(result.vod.vodYear, '2024');
      state.dispose();
    });

    test('enrich：来源标题含季度时保留来源标题（§3.1）', () async {
      final store = InMemoryTmdbMatchStore();
      store.cache.putManual(
        's',
        'v',
        ['来源剧名 第2季'],
        const TmdbItem(
          tmdbId: 1399,
          mediaType: TmdbMediaType.tv,
          title: 'TMDB 标题',
        ),
        matchedAt: 1,
      );
      final client = _FakeClient()
        ..route('/tv/1399', {'id': 1399, 'name': 'TMDB 标题'});
      final state = _state(config: _ready, client: client, store: store);
      final generation = state.beginLoad(
        siteKey: 's',
        vodId: 'v',
        sourceTitle: '来源剧名 第2季',
        vod: _vod(name: '来源剧名 第2季'),
        line: _line(),
      );
      await state.loadMatch(
        generation: generation,
        sourceTitle: '来源剧名 第2季',
      );
      await state.loadDetail(
        generation: generation,
        tmdbSeasons: const [1, 2],
        seasonCounts: const {1: 12, 2: 10},
      );
      final result = state.enrich(_vod(name: '来源剧名 第2季'));
      expect(result.vod.vodName, '来源剧名 第2季', reason: '来源含季度应保留');
      state.dispose();
    });

    test('enrich 在未匹配时原样返回', () {
      final client = _FakeClient();
      final state = _state(config: _ready, client: client);
      final vod = _vod(name: '原样');
      final result = state.enrich(vod);
      expect(result.vod.vodName, '原样');
      expect(result.isEmpty, isTrue);
      state.dispose();
    });

    test('评分文案', () async {
      final client = _FakeClient()
        ..route('/search/multi', {
          'results': [
            {
              'id': 1399,
              'media_type': 'tv',
              'name': '剧名',
              'first_air_date': '2024-01-01',
              'vote_average': 8.2,
            },
          ],
        })
        ..route('/tv/1399', {'id': 1399, 'name': '剧名'});
      final state = _state(config: _ready, client: client);
      final generation = state.beginLoad(
        siteKey: 's',
        vodId: 'v',
        sourceTitle: '剧名',
        vod: _vod(),
        line: _line(),
      );
      await state.loadMatch(generation: generation, sourceTitle: '剧名');
      expect(state.ratingText, contains('8.2'));
      state.dispose();
    });
  });

  group('clear / clearError（§2.2）', () {
    test('clear 重置全部状态并递增代际', () async {
      final client = _FakeClient()
        ..route('/search/multi', {
          'results': [
            {
              'id': 1399,
              'media_type': 'tv',
              'name': '剧名',
              'first_air_date': '2024-01-01',
            },
          ],
        })
        ..route('/tv/1399', {'id': 1399, 'name': '剧名'});
      final state = _state(config: _ready, client: client);
      final generation = state.beginLoad(
        siteKey: 's',
        vodId: 'v',
        sourceTitle: '剧名',
        vod: _vod(),
        line: _line(),
      );
      await state.loadMatch(generation: generation, sourceTitle: '剧名');
      await state.loadDetail(
        generation: generation,
        tmdbSeasons: const [1],
        seasonCounts: const {1: 10},
      );
      expect(state.hasMatch, isTrue);

      state.clear();
      expect(state.phase, TmdbLoadPhase.idle);
      expect(state.hasMatch, isFalse);
      expect(state.detail, isNull);
      expect(state.resolution, isNull);
      expect(state.episodes, isEmpty);
      expect(state.availableSeasons, isEmpty);
      expect(state.selectedSeason, -1);
      expect(state.error, isNull);
      expect(state.vod, isNull);
      state.dispose();
    });

    test('clearError 只清错误', () async {
      final client = _FakeClient()..failure = const FormatException('x');
      final state = _state(config: _ready, client: client);
      final generation = state.beginLoad(
        siteKey: 's',
        vodId: 'v',
        sourceTitle: '剧名',
        vod: _vod(),
        line: _line(),
      );
      await state.loadMatch(generation: generation, sourceTitle: '剧名');
      expect(state.error, isNotNull);
      state.clearError();
      expect(state.error, isNull);
      state.dispose();
    });

    test('通知监听者', () async {
      final client = _FakeClient();
      final state = _state(config: _ready, client: client);
      var notifications = 0;
      state.addListener(() => notifications++);
      state.beginLoad(
        siteKey: 's',
        vodId: 'v',
        sourceTitle: '剧名',
        vod: _vod(),
        line: _line(),
      );
      expect(notifications, greaterThan(0));
      state.clear();
      expect(notifications, greaterThan(1));
      state.dispose();
    });
  });

  group('错误隔离（§3.4）', () {
    test('全部 tmdb* 错误都属非致命类别', () {
      for (final kind in tmdbErrorKinds) {
        final error = AppError(kind, 'x');
        expect(isTmdbError(error), isTrue, reason: kind.name);
        expect(
          describeErrorKind(kind),
          contains('不影响站源浏览与播放'),
          reason: kind.name,
        );
      }
    });

    test('tmdb 错误不被误判为站点/字幕错误', () {
      expect(isTmdbError(AppError(AppErrorKind.siteNetwork, 'x')), isFalse);
      expect(isTmdbError(AppError(AppErrorKind.subtitleHttp, 'x')), isFalse);
      expect(isTmdbError(AppError(AppErrorKind.epgHttp, 'x')), isFalse);
      expect(isTmdbError(null), isFalse);
      expect(isTmdbError('x'), isFalse);
    });

    test('describeTmdbFailure 输出非致命文案', () {
      expect(
        describeTmdbFailure(AppError(AppErrorKind.tmdbNetwork, 'x')),
        contains('不影响站源浏览与播放'),
      );
      expect(
        describeTmdbFailure('raw'),
        contains('不影响站源浏览与播放'),
      );
    });
  });

  group('相关视频加载（失败隔离）', () {
    test('loadVideos 成功填充', () async {
      final client = _FakeClient()
        ..route('/search/multi', {
          'results': [
            {
              'id': 1399,
              'media_type': 'tv',
              'name': '剧名',
              'first_air_date': '2024-01-01',
            },
          ],
        })
        ..route('/tv/1399', {'id': 1399, 'name': '剧名'})
        ..route('/videos', {
          'results': [
            {
              'key': 'abc123',
              'site': 'YouTube',
              'name': '预告',
              'type': 'Trailer',
            },
          ],
        });
      final state = _state(config: _ready, client: client);
      final generation = state.beginLoad(
        siteKey: 's',
        vodId: 'v',
        sourceTitle: '剧名',
        vod: _vod(),
        line: _line(),
      );
      await state.loadMatch(generation: generation, sourceTitle: '剧名');
      await state.loadVideos(generation: generation);
      expect(state.videos.length, 1);
      expect(state.videos.first.key, 'abc123');
      state.dispose();
    });

    test('loadVideos 失败 → 空列表且不改变 phase', () async {
      final client = _FakeClient()
        ..route('/search/multi', {
          'results': [
            {
              'id': 1399,
              'media_type': 'tv',
              'name': '剧名',
              'first_air_date': '2024-01-01',
            },
          ],
        })
        ..route('/tv/1399', {'id': 1399, 'name': '剧名'});
      // 缺 /videos 路由
      final state = _state(config: _ready, client: client);
      final generation = state.beginLoad(
        siteKey: 's',
        vodId: 'v',
        sourceTitle: '剧名',
        vod: _vod(),
        line: _line(),
      );
      await state.loadMatch(generation: generation, sourceTitle: '剧名');
      final phaseBefore = state.phase;
      await state.loadVideos(generation: generation);
      expect(state.videos, isEmpty);
      expect(state.phase, phaseBefore);
      state.dispose();
    });
  });
}
