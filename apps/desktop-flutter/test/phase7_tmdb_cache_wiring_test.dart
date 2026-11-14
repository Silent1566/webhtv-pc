/// Phase 7 · TMDB 缓存接线 / 二次进入秒开 / 渲染归属门。
///
/// 缺陷背景（用户反馈原话）：「进入详情页貌似没有 TMDB 缓冲，感觉每次都重新查询了，
/// 正常有缓冲后应该能直接出对应的效果才对，现在点第二次还是会先显示原始模式后再等于
/// 会渲染成 tmdb 版本」。两条独立成因：
///
/// 1. `AppState` 构造 `TmdbService` 时**没传 `cache`**，于是 `_request` 里的
///    `readFirstFresh/readFirstAny/write` 分支恒不生效，磁盘缓存等于不存在；
/// 2. `AppState.clearDetail()` 把 TMDB 内存态整块清掉，第二次进同一部剧时
///    `_isSameTitle` 恒为 false，首帧必然先渲染站源「原始模式」。
///
/// 本文件锁定三件事：
/// 1. `AppState` 手里的 TMDB 磁盘缓存**确实指向** `AppPaths.cacheDir`；
/// 2. 同一部剧连续两次 `loadForVod` 第二次不再发出任何 TMDB 请求；进程内状态全丢
///    （模拟重启）后仍能靠磁盘缓存零请求还原；
/// 3. 渲染归属门 `belongsTo` 只对同一作品放行，且 `beginLoad` 换作品时必须清掉
///    上一部剧的匹配结论（否则 `hasMatch` 为真会把旧数据渲染到新作品上）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/tmdb_config.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/tmdb_cache.dart';
import 'package:webhtv_pc/services/tmdb_enrichment_service.dart';
import 'package:webhtv_pc/services/tmdb_identity_service.dart';
import 'package:webhtv_pc/services/tmdb_season_service.dart';
import 'package:webhtv_pc/services/tmdb_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/state/tmdb_state.dart';

// ---------------------------------------------------------------------------
// fake HTTP（按路径后缀路由；`requests` 就是「到底还打不打网络」的证据）
// ---------------------------------------------------------------------------

class _FakeClient extends http.BaseClient {
  final List<Uri> requests = [];
  final List<(String, Object?)> routes = [];

  int get count => requests.length;

  void route(String suffix, Object? body) => routes.add((suffix, body));

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request.url);
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

/// 一部「剧名」作品的完整响应：搜索命中 → 详情（1 季 3 集）→ 季度剧集 → 无视频。
_FakeClient _client() => _FakeClient()
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
    ],
    'aggregate_credits': {
      'cast': [
        {'id': 287, 'name': '演员甲', 'roles': []},
      ],
    },
    'credits': {
      'crew': [
        {'id': 500, 'name': '导演甲', 'job': 'Director'},
      ],
    },
    'created_by': [
      {'id': 500, 'name': '导演甲'},
    ],
  })
  ..route('/season/1', {
    'season_number': 1,
    'episodes': [
      {'episode_number': 1, 'name': '第一集', 'season_number': 1},
      {'episode_number': 2, 'name': '第二集', 'season_number': 1},
      {'episode_number': 3, 'name': '第三集', 'season_number': 1},
    ],
  })
  ..route('/videos', {'results': []});

TmdbConfig _ready() => const TmdbConfig(apiKey: 'k');

TmdbState _state({required http.Client client, TmdbCache? cache}) {
  final config = _ready;
  final service = TmdbService(config: config, client: client, cache: cache);
  return TmdbState(
    config: config,
    service: service,
    identityService: TmdbIdentityService(
      config: config,
      service: service,
      store: InMemoryTmdbMatchStore(),
    ),
    seasonService: TmdbSeasonService(store: InMemoryTmdbSeasonStore()),
    enrichmentService: TmdbEnrichmentService(service: service, config: config),
  );
}

Vod _vod({String vodId = 'v1', String name = '剧名'}) =>
    Vod(vodId: vodId, vodName: name);

List<VodPlayLine> _lines() => [
  VodPlayLine(
    flag: '线路一',
    episodes: [
      for (var i = 1; i <= 3; i++)
        VodEpisode(name: '第$i集', url: 'https://cdn/a$i.mp4'),
    ],
  ),
];

void main() {
  group('磁盘缓存接线（用户反馈：每次进详情页都重新查询）', () {
    test('AppState 构造的 TMDB 服务带磁盘缓存，且目录指向 AppPaths.cacheDir', () async {
      final tempDir = await Directory.systemTemp.createTemp('webhtv-tmdb-wire');
      addTearDown(() {
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      });
      final paths = AppPaths.resolve(
        overrides: {
          'config': '${tempDir.path}/webhtv-pc',
          'data': '${tempDir.path}/webhtv-pc',
          'cache': '${tempDir.path}/webhtv-pc/cache',
          'state': '${tempDir.path}/webhtv-pc/logs',
        },
      );
      final state = AppState(paths: paths, log: LogService());

      final cache = state.tmdbCacheForTest;
      // 只断言「非空」不够：历史上缺陷正是漏传参数，缓存实例根本不存在。
      expect(cache.cacheDir, paths.cacheDir, reason: '缓存根必须是 AppPaths.cacheDir');
      expect(
        cache.directory,
        TmdbCache(cacheDir: paths.cacheDir).directory,
        reason: '缓存的真实落盘目录必须与 cacheDir 推出的 tmdb 目录一致',
      );
      expect(
        cache.directory,
        startsWith(tempDir.path),
        reason: '目录必须落在本次测试的临时缓存根下（不是空实现）',
      );
      expect(cache.cacheDir, isNotNull);
    });

    test('clearDetail 不再清 TMDB：作品归属保留，二次进入才能首帧直出', () async {
      final tempDir = await Directory.systemTemp.createTemp('webhtv-tmdb-keep');
      addTearDown(() {
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      });
      final paths = AppPaths.resolve(
        overrides: {
          'config': '${tempDir.path}/webhtv-pc',
          'data': '${tempDir.path}/webhtv-pc',
          'cache': '${tempDir.path}/webhtv-pc/cache',
          'state': '${tempDir.path}/webhtv-pc/logs',
        },
      );
      final state = AppState(paths: paths, log: LogService());
      // TmdbState 的身份服务依赖已打开的数据库（`_database!`），必须先 bootstrap。
      await state.bootstrap();
      state.tmdb.beginLoad(
        siteKey: 's',
        vodId: 'v1',
        sourceTitle: '剧名',
        vod: _vod(),
        line: TmdbSourceLine(
          flagKey: 'f#0',
          sourceFlag: '线路一',
          episodeNames: const ['第1集'],
        ),
      );
      expect(state.tmdb.vodId, 'v1');

      state.clearDetail();

      expect(
        state.tmdb.vodId,
        'v1',
        reason: 'clearDetail 保留作品维度 TMDB 数据（清了就必然先渲染站源原始模式）',
      );
      expect(state.tmdb.belongsTo('v1'), isTrue);
      expect(state.detailResult, isNull, reason: '站源详情结果仍必须清空');
    });
  });

  group('二次进入同一部剧：不再重复请求', () {
    test('连续两次 loadForVod 第二次零请求（内存复用 + 磁盘缓存）', () async {
      final temp = Directory.systemTemp.createTempSync('webhtv-tmdb-twice');
      addTearDown(() {
        try {
          temp.deleteSync(recursive: true);
        } catch (_) {}
      });
      final client = _client();
      final state = _state(client: client, cache: TmdbCache(cacheDir: temp.path));

      await state.loadForVod(
        _vod(),
        siteKey: 's',
        siteName: '站点',
        lines: _lines(),
      );
      expect(state.hasMatch, isTrue, reason: '前置：首次必须已匹配');
      expect(state.detail, isNotNull, reason: '前置：首次必须已取到详情');
      final afterFirst = client.count;
      expect(afterFirst, greaterThan(0), reason: '前置：首次必须真的打过网络');

      // 详情页「第二次进入同一部剧」的形态：同一个 TmdbState + 同一份缓存。
      await state.loadForVod(
        _vod(),
        siteKey: 's',
        siteName: '站点',
        lines: _lines(),
      );
      expect(
        client.count,
        afterFirst,
        reason: '第二次进入不得再发任何 TMDB 请求（否则必然先闪原始模式）',
      );
      expect(state.hasMatch, isTrue);
      expect(state.detail, isNotNull);
      state.dispose();
    });

    test('进程内状态全丢后仍靠磁盘缓存零请求还原（重启场景）', () async {
      final temp = Directory.systemTemp.createTempSync('webhtv-tmdb-disk');
      addTearDown(() {
        try {
          temp.deleteSync(recursive: true);
        } catch (_) {}
      });
      final client = _client();
      final first = _state(
        client: client,
        cache: TmdbCache(cacheDir: temp.path),
      );
      await first.loadForVod(
        _vod(),
        siteKey: 's',
        siteName: '站点',
        lines: _lines(),
      );
      final afterFirst = client.count;
      expect(afterFirst, greaterThan(0));
      first.dispose();

      // 全新 state/服务（内存全空），只有同一个磁盘缓存目录。
      final second = _state(
        client: client,
        cache: TmdbCache(cacheDir: temp.path),
      );
      await second.loadForVod(
        _vod(),
        siteKey: 's',
        siteName: '站点',
        lines: _lines(),
      );
      expect(
        second.hasMatch,
        isTrue,
        reason: '磁盘缓存必须能让「重启后首帧」直接拿到 TMDB 匹配',
      );
      expect(second.detail, isNotNull, reason: '磁盘缓存必须能让详情零请求还原');
      expect(
        client.count,
        afterFirst,
        reason: '磁盘缓存命中时不得再打网络（这正是「没有 TMDB 缓冲」的根因）',
      );
      second.dispose();
    });
  });

  group('渲染归属门（防串剧）', () {
    test('保留的数据只对同一作品 belongsTo；换作品时匹配结论必须清空', () async {
      final client = _client();
      final state = _state(client: client);
      await state.loadForVod(
        _vod(),
        siteKey: 's',
        siteName: '站点',
        lines: _lines(),
      );
      expect(state.hasMatch, isTrue);
      expect(state.vodId, 'v1');
      expect(state.belongsTo('v1'), isTrue, reason: '同一作品必须放行');
      expect(state.belongsTo('v2'), isFalse, reason: '另一部作品必须降级为「无 TMDB」');

      // 换作品：渲染归属门是第一道防线，状态层必须自己清干净（第二道）。
      state.beginLoad(
        siteKey: 's',
        vodId: 'v2',
        sourceTitle: '别的剧',
        vod: _vod(vodId: 'v2', name: '别的剧'),
        line: TmdbSourceLine(
          flagKey: 'f#0',
          sourceFlag: '线路一',
          episodeNames: const ['第1集'],
        ),
      );
      expect(
        state.matchResult,
        isNull,
        reason: '换作品必须清掉上一部剧的匹配结论，否则 hasMatch 为真会渲染旧数据',
      );
      expect(state.hasMatch, isFalse);
      expect(state.belongsTo('v2'), isTrue);
      expect(state.belongsTo('v1'), isFalse);
      state.dispose();
    });
  });
}
