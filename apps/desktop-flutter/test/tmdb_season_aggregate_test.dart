/// 导航源「全部季剧集元数据」聚合（`TmdbState.ensureAllSeasonEpisodes`）。
///
/// 对应需求：导航源（`site.indexs == 1`）要把站源线路摊平成一条线性线路，
/// 补卡策略（`EpisodeSupplementPolicy.build`）需要 **TMDB 每一季的完整剧集
/// 列表**（`Map<int, List<TmdbEpisode>>`），而 `loadEpisodes` 只装选中那一季。
/// 本文件验证：非导航源零请求、导航源逐季聚合、单季失败隔离、迟到响应丢弃、
/// 换作品清空。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/tmdb_config.dart';
import 'package:webhtv_pc/services/tmdb_cache.dart';
import 'package:webhtv_pc/services/tmdb_enrichment_service.dart';
import 'package:webhtv_pc/services/tmdb_identity_service.dart';
import 'package:webhtv_pc/services/tmdb_season_service.dart';
import 'package:webhtv_pc/services/tmdb_service.dart';
import 'package:webhtv_pc/state/tmdb_state.dart';
import 'package:webhtv_pc/ui/tmdb_widgets.dart' show TmdbLoadPhase;

// ---------------------------------------------------------------------------
// fake HTTP（与 `phase4_tmdb_state_test.dart` 同一套基础设施）
// ---------------------------------------------------------------------------

class _FakeClient extends http.BaseClient {
  final List<Uri> requests = [];
  final List<(String, Object?)> routes = [];
  Object? failure;

  /// 指定后缀的请求在这里挂住，用于制造「迟到响应」。
  String? gateSuffix;
  Completer<void>? gate;

  int get count => requests.length;

  void route(String suffix, Object? body) => routes.add((suffix, body));

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request.url);
    final suffix = gateSuffix;
    final gate = this.gate;
    if (gate != null && suffix != null && request.url.path.endsWith(suffix)) {
      await gate.future;
    }
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

TmdbConfig _ready() => const TmdbConfig(apiKey: 'k');

TmdbState _state({
  required TmdbConfig Function() config,
  required http.Client client,
  TmdbMatchStore? store,
  TmdbSeasonStore? seasonStore,
  TmdbCache? cache,
}) {
  final service = TmdbService(config: config, client: client, cache: cache);
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

Vod _vod({String name = '剧名', String id = 'v1'}) =>
    Vod(vodId: id, vodName: name);

VodPlayLine _playLine({int count = 3}) => VodPlayLine(
  flag: '线路一',
  episodes: [
    for (var i = 0; i < count; i++)
      VodEpisode(name: '第${i + 1}集', url: 'https://cdn/e${i + 1}.m3u8'),
  ],
);

/// 两季（S1 3 集 / S2 2 集）的导航源站点响应。
_FakeClient _navClient({bool season2 = true}) {
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
        {'season_number': 1, 'episode_count': 3},
        {'season_number': 2, 'episode_count': 2},
      ],
    })
    ..route('/season/1', {
      'season_number': 1,
      'episodes': [
        for (var i = 1; i <= 3; i++)
          {'episode_number': i, 'name': 'S1E$i', 'season_number': 1},
      ],
    })
    ..route('/videos', {'results': []});
  if (season2) {
    client.route('/season/2', {
      'season_number': 2,
      'episodes': [
        for (var i = 1; i <= 2; i++)
          {'episode_number': i, 'name': 'S2E$i', 'season_number': 2},
      ],
    });
  }
  return client;
}

/// 只数「拉某季剧集」的请求：`/tv/{id}/season/{n}`。
/// 注意 `/tv/{id}/season/{n}/videos` 也含 `/season/`，必须排除（那是视频请求）。
final RegExp _seasonPath = RegExp(r'/season/\d+$');

int _seasonRequests(_FakeClient client) =>
    client.requests.where((uri) => _seasonPath.hasMatch(uri.path)).length;

/// 反复让出事件循环，直到 [done] 为真（不轮询计时器，只推进微任务/事件队列）。
Future<void> _drainUntil(bool Function() done, {int maxTurns = 200}) async {
  for (var i = 0; i < maxTurns; i++) {
    if (done()) return;
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('非导航源：一行行为都不变', () {
    test('未传 navSource / 传 false → isNavSource 为 false 且聚合零请求', () async {
      final client = _navClient();
      final state = _state(config: _ready, client: client);

      await state.loadForVod(
        _vod(),
        siteKey: 's',
        siteName: '站',
        lines: [_playLine()],
      );
      expect(state.isNavSource, isFalse, reason: '未声明时默认按普通站点处理');
      expect(state.episodesBySeason, isEmpty);

      final before = _seasonRequests(client);
      await state.ensureAllSeasonEpisodes(generation: state.generation);
      expect(
        _seasonRequests(client),
        before,
        reason: '非导航源不得发起任何季节请求（零请求）',
      );
      expect(state.episodesBySeason, isEmpty);
      expect(state.phase, TmdbLoadPhase.ready, reason: '不得改变主阶段');

      // 显式传 false 与默认等价。
      await state.loadForVod(
        _vod(),
        siteKey: 's',
        siteName: '站',
        lines: [_playLine()],
        navSource: false,
      );
      expect(state.isNavSource, isFalse);
      state.dispose();
    });
  });

  group('导航源：逐季聚合', () {
    test('按 seasonEpisodeCounts 拉全部季，key 覆盖全部季且长度等于集数', () async {
      final temp = Directory.systemTemp.createTempSync('webhtv-tmdb-aggregate');
      addTearDown(() {
        try {
          temp.deleteSync(recursive: true);
        } catch (_) {}
      });
      final client = _navClient();
      // 与生产 `AppState` 一致地带 TMDB 缓存：选中季已在 `loadEpisodes` 里拉过，
      // 聚合时是**缓存命中**，因此网络请求仍是每季一次。
      final state = _state(
        config: _ready,
        client: client,
        cache: TmdbCache(cacheDir: temp.path),
      );

      await state.loadForVod(
        _vod(),
        siteKey: 's',
        siteName: '站',
        lines: [_playLine()],
        navSource: true,
      );

      expect(state.isNavSource, isTrue);
      expect(state.seasonEpisodeCounts, {1: 3, 2: 2});
      expect(state.episodes, hasLength(3), reason: '前置：选中季 S1 已有元数据');
      expect(
        state.episodesBySeason,
        isEmpty,
        reason: '聚合是显式触发的补充加载，不得混进 loadForVod 主链',
      );

      await state.ensureAllSeasonEpisodes(generation: state.generation);

      expect(state.episodesBySeason.keys.toSet(), {1, 2});
      expect(state.episodesBySeason[1]!.length, 3);
      expect(state.episodesBySeason[2]!.length, 2);
      expect(state.episodesBySeason[2]!.first.title, 'S2E1');
      expect(
        _seasonRequests(client),
        2,
        reason: '两个季各一次网络请求（S1 由 loadEpisodes 已拉，聚合是缓存命中）',
      );
      expect(
        client.requests.where((uri) => uri.path.endsWith('/season/2')).length,
        1,
      );
      state.dispose();
    });
  });

  group('失败隔离', () {
    test('某一季抛异常 → 其他季照常填充，整体不抛', () async {
      final client = _navClient(season2: false);
      final state = _state(config: _ready, client: client);

      await state.loadForVod(
        _vod(),
        siteKey: 's',
        siteName: '站',
        lines: [_playLine()],
        navSource: true,
      );
      final phaseBefore = state.phase;

      await state.ensureAllSeasonEpisodes(generation: state.generation);

      expect(state.episodesBySeason.containsKey(1), isTrue, reason: 'S1 必须成功');
      expect(
        state.episodesBySeason.containsKey(2),
        isFalse,
        reason: '单季失败只跳过该季，缺的季不写空列表',
      );
      expect(state.episodesBySeason[1]!.length, 3);
      expect(state.phase, phaseBefore, reason: '聚合失败不得改主阶段');
      expect(state.error, isNull, reason: '聚合失败不得产生错误横幅');
      state.dispose();
    });
  });

  group('代际与换作品', () {
    test('generation 变化后迟到响应不得污染 episodesBySeason', () async {
      final client = _navClient()
        ..gateSuffix = '/season/2'
        ..gate = Completer<void>();
      final state = _state(config: _ready, client: client);

      await state.loadForVod(
        _vod(),
        siteKey: 's',
        siteName: '站',
        lines: [_playLine()],
        navSource: true,
      );

      final pending = state.ensureAllSeasonEpisodes(
        generation: state.generation,
      );
      // S1 先落地，S2 卡在闸门上。
      await _drainUntil(
        () => state.episodesBySeason.containsKey(1),
      );
      expect(state.episodesBySeason.containsKey(1), isTrue, reason: '前置：S1 已聚合');

      // 换代：模拟用户进了另一部剧。
      state.beginLoad(
        siteKey: 's',
        vodId: 'v2',
        sourceTitle: '另一部',
        vod: _vod(name: '另一部', id: 'v2'),
        line: null,
        navSource: true,
      );
      client.gate!.complete();
      await pending;

      expect(
        state.episodesBySeason,
        isEmpty,
        reason: '旧代际的迟到响应必须丢弃，且不得回填已被清空的聚合缓存',
      );
      state.dispose();
    });

    test('换作品（再次 loadForVod 到不同 vod）后旧聚合被清空', () async {
      final client = _navClient();
      final state = _state(config: _ready, client: client);

      await state.loadForVod(
        _vod(),
        siteKey: 's',
        siteName: '站',
        lines: [_playLine()],
        navSource: true,
      );
      await state.ensureAllSeasonEpisodes(generation: state.generation);
      expect(state.episodesBySeason.keys.toSet(), {1, 2});

      await state.loadForVod(
        _vod(id: 'v2'),
        siteKey: 's',
        siteName: '站',
        lines: [_playLine()],
        navSource: true,
      );
      expect(
        state.episodesBySeason,
        isEmpty,
        reason: '换作品必须清空聚合缓存，否则新作品会按上一部剧的季集元数据出卡',
      );
      expect(state.vod?.vodId, 'v2');
      state.dispose();
    });
  });
}
