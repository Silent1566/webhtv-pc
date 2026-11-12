/// Phase 4 · TMDB 匹配与季度编排服务（`docs/phase4/design/01` §4/§7、
/// `02` §3–§7）。
///
/// 覆盖门禁：`docs/phase4/design/05` §3.5 用例组 13（ambiguous 不落盘 / 不覆盖旧绑定）
/// 与 §3.8 用例组 1–7（进度写入 / 不覆盖 / 读取 / 投影 / 换源 / 删除）。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:webhtv_pc/core/tmdb_config.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/core/tmdb_season.dart';
import 'package:webhtv_pc/core/tmdb_title.dart';
import 'package:webhtv_pc/services/tmdb_identity_service.dart';
import 'package:webhtv_pc/services/tmdb_season_service.dart';
import 'package:webhtv_pc/services/tmdb_service.dart';

// ---------------------------------------------------------------------------
// fake HTTP
// ---------------------------------------------------------------------------

class _FakeClient extends http.BaseClient {
  final List<Uri> requests = [];
  final List<(String, Object?)> routes = [];

  /// 按搜索词路由（`request.url.queryParameters['query']`），优先于 [routes]。
  ///
  /// 年份拆分重试与原始词兜底会对**同一个** `/search/multi` 发出不同 query，
  /// 只按路径后缀路由无法让它们返回不同结果。
  final List<(String, Object?)> queryRoutes = [];
  Object? failure;

  int get count => requests.length;

  /// 只数搜索请求（详情请求不算，避免把详情缓存差异混进请求数断言）。
  int get searchCount => requests
      .where((url) => url.path.endsWith('/search/multi'))
      .length;

  void route(String pathSuffix, Object? body) =>
      routes.add((pathSuffix, body));

  void routeQuery(String query, Object? body) =>
      queryRoutes.add((query, body));

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request.url);
    final local = failure;
    if (local != null) throw local;
    final query = request.url.queryParameters['query'];
    if (query != null) {
      for (final (expected, body) in queryRoutes) {
        if (query == expected) return _ok(body);
      }
    }
    for (final (suffix, body) in routes) {
      if (request.url.path.endsWith(suffix)) return _ok(body);
    }
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode('{"status_code":404}')),
      404,
    );
  }

  http.StreamedResponse _ok(Object? body) {
    final text = body is String ? body : jsonEncode(body);
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(text)),
      200,
    );
  }
}

TmdbConfig _ready() => const TmdbConfig(apiKey: 'k');

TmdbIdentity _tv(int id) => TmdbIdentity.of(TmdbMediaType.tv, id)!;

/// 搜索结果条目（tv）：标题 + 首播年份走 `first_air_date → 副标题`（§5.1）。
Map<String, Object?> _tvResult({
  required int id,
  required String name,
  String? firstAirDate,
  double vote = 0,
}) => {
  'id': id,
  'media_type': 'tv',
  'name': name,
  'first_air_date': ?firstAirDate,
  if (vote > 0) 'vote_average': vote,
};

/// 搜索结果条目（movie）。
Map<String, Object?> _movieResult({
  required int id,
  required String title,
  String? releaseDate,
  double vote = 0,
}) => {
  'id': id,
  'media_type': 'movie',
  'title': title,
  'release_date': ?releaseDate,
  if (vote > 0) 'vote_average': vote,
};

// ---------------------------------------------------------------------------
// TmdbIdentityService
// ---------------------------------------------------------------------------

void main() {
  group('TmdbIdentityService 前置检查（§4 步骤 0，零请求）', () {
    test('未配置 → TmdbMatchDisabled(notConfigured) 且零请求', () async {
      final client = _FakeClient();
      final store = InMemoryTmdbMatchStore();
      final service = TmdbIdentityService(
        config: () => const TmdbConfig(),
        service: TmdbService(config: () => const TmdbConfig(), client: client),
        store: store,
      );
      final outcome = await service.match(
        const TmdbMatchRequest(siteKey: 's', vodId: 'v', sourceTitle: '剧名'),
      );
      expect(outcome.result, isA<TmdbMatchDisabled>());
      expect(
        (outcome.result as TmdbMatchDisabled).reason,
        TmdbMissReason.notConfigured,
      );
      expect(client.count, 0);
    });

    test('站点被禁用 → TmdbMatchDisabled(siteDisabled) 且零请求', () async {
      final client = _FakeClient();
      final config = const TmdbConfig(
        apiKey: 'k',
        disabledSites: ['[书]'],
      );
      final service = TmdbIdentityService(
        config: () => config,
        service: TmdbService(config: () => config, client: client),
        store: InMemoryTmdbMatchStore(),
      );
      final outcome = await service.match(
        const TmdbMatchRequest(
          siteKey: '[书]某站',
          vodId: 'v',
          sourceTitle: '剧名',
        ),
      );
      expect(outcome.result, isA<TmdbMatchDisabled>());
      expect(
        (outcome.result as TmdbMatchDisabled).reason,
        TmdbMissReason.siteDisabled,
      );
      expect(client.count, 0);
    });
  });

  group('TmdbIdentityService 匹配与落盘（§4/§5）', () {
    test('strict 命中并落盘（自动）', () async {
      final client = _FakeClient()
        ..route('/search/multi', {
          'results': [
            {
              'id': 1399,
              'media_type': 'tv',
              'name': '剧名',
              'first_air_date': '2024-03-01',
              'vote_average': 8.2,
            },
          ],
        })
        // strict 需要详情做分季变体防护
        ..route('/tv/1399', {'id': 1399, 'name': '剧名'});
      final store = InMemoryTmdbMatchStore();
      final service = TmdbIdentityService(
        config: _ready,
        service: TmdbService(config: _ready, client: client),
        store: store,
      );
      final outcome = await service.match(
        const TmdbMatchRequest(siteKey: 's', vodId: 'v', sourceTitle: '剧名'),
      );
      expect(outcome.result, isA<TmdbMatchHit>());
      expect(outcome.item?.identity?.key, 'tv:1399');
      expect(outcome.level, 'strict');
      // 已落盘
      expect(store.cache.findScoped('s', 'v', '剧名'), isNotNull);
    });

    test('无结果 → TmdbMatchMiss(noCandidates)', () async {
      final client = _FakeClient()..route('/search/multi', {'results': []});
      final service = TmdbIdentityService(
        config: _ready,
        service: TmdbService(config: _ready, client: client),
        store: InMemoryTmdbMatchStore(),
      );
      final outcome = await service.match(
        const TmdbMatchRequest(siteKey: 's', vodId: 'v', sourceTitle: '剧名'),
      );
      expect(outcome.result, isA<TmdbMatchMiss>());
      expect(
        (outcome.result as TmdbMatchMiss).reason,
        TmdbMissReason.noCandidates,
      );
    });

    test('媒体类型过滤：期望 tv 时不接受 movie', () async {
      final client = _FakeClient()
        ..route('/search/multi', {
          'results': [
            {
              'id': 550,
              'media_type': 'movie',
              'title': '剧名',
              'release_date': '2024-01-01',
            },
          ],
        });
      final service = TmdbIdentityService(
        config: _ready,
        service: TmdbService(config: _ready, client: client),
        store: InMemoryTmdbMatchStore(),
      );
      final outcome = await service.match(
        const TmdbMatchRequest(
          siteKey: 's',
          vodId: 'v',
          sourceTitle: '剧名',
          expectedMediaType: TmdbMediaType.tv,
        ),
      );
      expect(outcome.result, isA<TmdbMatchMiss>());
    });

    test('缓存命中不发请求', () async {
      final store = InMemoryTmdbMatchStore();
      store.cache.putManual(
        's',
        'v',
        ['剧名'],
        const TmdbItem(tmdbId: 1399, mediaType: TmdbMediaType.tv, title: '剧名'),
        matchedAt: 1,
      );
      final client = _FakeClient();
      final service = TmdbIdentityService(
        config: _ready,
        service: TmdbService(config: _ready, client: client),
        store: store,
      );
      final outcome = await service.match(
        const TmdbMatchRequest(siteKey: 's', vodId: 'v', sourceTitle: '剧名'),
      );
      expect(outcome.result, isA<TmdbMatchHit>());
      expect(outcome.level, 'manual');
      expect(client.count, 0, reason: '缓存命中必须零请求');
      expect(outcome.requestCount, 0);
    });

    test('候选查询词上限为 3（§4 步骤 3）', () async {
      final client = _FakeClient()..route('/search/multi', {'results': []});
      final service = TmdbIdentityService(
        config: _ready,
        service: TmdbService(config: _ready, client: client),
        store: InMemoryTmdbMatchStore(),
        maxQueries: 3,
      );
      await service.match(
        const TmdbMatchRequest(
          siteKey: 's',
          vodId: 'v',
          sourceTitle: '标题一',
          searchKeyword: '标题二',
          vodName: '标题三',
          vodRemarks: '标题四',
        ),
      );
      expect(client.count, 3);
    });

    test('手动匹配写入手动结论且不被自动覆盖', () async {
      final store = InMemoryTmdbMatchStore();
      final client = _FakeClient()
        ..route('/search/multi', {
          'results': [
            {
              'id': 9999,
              'media_type': 'tv',
              'name': '剧名',
              'first_air_date': '2024-01-01',
            },
          ],
        })
        ..route('/tv/9999', {'id': 9999, 'name': '剧名'});
      final service = TmdbIdentityService(
        config: _ready,
        service: TmdbService(config: _ready, client: client),
        store: store,
      );
      await service.matchManual(
        request: const TmdbMatchRequest(
          siteKey: 's',
          vodId: 'v',
          sourceTitle: '剧名',
        ),
        item: const TmdbItem(tmdbId: 1399, mediaType: TmdbMediaType.tv, title: '剧名'),
      );
      expect(store.cache.findScoped('s', 'v', '剧名')?.identity.tmdbId, 1399);

      // 自动匹配不得覆盖
      final outcome = await service.match(
        const TmdbMatchRequest(siteKey: 's', vodId: 'v', sourceTitle: '剧名'),
      );
      expect(outcome.level, 'manual');
      expect(store.cache.findScoped('s', 'v', '剧名')?.identity.tmdbId, 1399);
    });

    test('Provider ID 直达：tv:1399 / movie:550', () async {
      final client = _FakeClient()
        ..route('/tv/1399', {'id': 1399, 'name': '剧名', 'first_air_date': '2024-01-01'})
        ..route('/movie/550', {'id': 550, 'title': '电影', 'release_date': '2023-01-01'});
      final service = TmdbIdentityService(
        config: _ready,
        service: TmdbService(config: _ready, client: client),
        store: InMemoryTmdbMatchStore(),
      );
      final tv = await service.resolveProviderId('tv:1399');
      expect(tv?.identity?.key, 'tv:1399');
      final movie = await service.resolveProviderId('movie:550');
      expect(movie?.identity?.key, 'movie:550');
      // 类型未知时先查 tv
      final plain = await service.resolveProviderId('tmdb:1399');
      expect(plain?.identity?.key, 'tv:1399');
      // 非法输入
      expect(await service.resolveProviderId('abc'), isNull);
      expect(await service.resolveProviderId('tv:0'), isNull);
      expect(await service.resolveProviderId('tv:abc'), isNull);
    });

    test('searchCandidates 排序：完全匹配优先', () async {
      final client = _FakeClient()
        ..route('/search/multi', {
          'results': [
            {
              'id': 1,
              'media_type': 'tv',
              'name': '剧名第二季',
              'first_air_date': '2024-01-01',
            },
            {
              'id': 2,
              'media_type': 'tv',
              'name': '剧名',
              'first_air_date': '2024-01-01',
            },
          ],
        });
      final service = TmdbIdentityService(
        config: _ready,
        service: TmdbService(config: _ready, client: client),
        store: InMemoryTmdbMatchStore(),
      );
      final results = await service.searchCandidates('剧名');
      expect(results.first.title, '剧名', reason: '完全匹配应排最前');
    });

    test('鉴权失败向上传播（不被吞成未匹配）', () async {
      final client = _FakeClient()
        ..route('/search/multi', {'status_code': 7})
        ..failure = null;
      // 直接构造 401
      final client401 = _AuthFailClient();
      final service = TmdbIdentityService(
        config: _ready,
        service: TmdbService(config: _ready, client: client401),
        store: InMemoryTmdbMatchStore(),
      );
      await expectLater(
        service.match(
          const TmdbMatchRequest(siteKey: 's', vodId: 'v', sourceTitle: '剧名'),
        ),
        throwsA(isA<TmdbAuthException>()),
      );
      expect(client.count, 0);
    });
  });

  // -------------------------------------------------------------------------
  // 安卓对齐后的自动匹配回归（`01` §4/§5.3/§5.5/§5.6）
  // -------------------------------------------------------------------------

  group('TmdbIdentityService 年份拆分与原始词兜底（§4/§5.3/§5.5）', () {
    TmdbIdentityService build(
      _FakeClient client, {
      TmdbMatchStore? store,
      TmdbConfig Function()? config,
    }) {
      final configure = config ?? _ready;
      return TmdbIdentityService(
        config: configure,
        service: TmdbService(config: configure, client: client),
        store: store ?? InMemoryTmdbMatchStore(),
        maxQueries: 3,
      );
    }

    TmdbConfig smartOff() =>
        const TmdbConfig(apiKey: 'k', smartMatch: false);

    // 契约锚点：`01` §5.5（形如「剧名2024」的主查询几乎必然零结果 → 候选查询
    // 全部失败后做且只做一次年份拆分重试）+ §5.3（重试命中同样走完整三级，
    // `level` 加 `split.` 前缀）+ §4 步骤 6（自动结论落盘）。
    // 安卓同源：TmdbMatcher.java:71-76 / 374-382（split 重试）、394-397（条目年份）。
    test('尚公主2026：主查询零结果 → 拆分重试命中 split.strict 且落盘', () async {
      final client = _FakeClient()
        ..routeQuery('尚公主2026', {'results': []})
        ..routeQuery('尚公主', {
          'results': [
            _tvResult(id: 9001, name: '尚公主', firstAirDate: '2026-01-01'),
          ],
        })
        ..route('/tv/9001', {'id': 9001, 'name': '尚公主'});
      final store = InMemoryTmdbMatchStore();
      final service = build(client, store: store);

      final outcome = await service.match(
        const TmdbMatchRequest(
          siteKey: 's',
          vodId: 'v',
          sourceTitle: '尚公主2026',
        ),
      );

      expect(outcome.result, isA<TmdbMatchHit>());
      expect(outcome.item?.identity?.key, 'tv:9001');
      expect(outcome.level, 'split.strict', reason: '2026 == 2026 → 拆分级 strict');
      expect(outcome.requestCount, 2, reason: '主查询 1 次 + 拆分重试 1 次');
      expect(
        store.cache.findScoped('s', 'v', '尚公主2026'),
        isNotNull,
        reason: '命中必须落盘（§4 步骤 6）',
      );

      // 落盘后再 match：命中缓存、零搜索请求。
      final searchBefore = client.searchCount;
      final again = await service.match(
        const TmdbMatchRequest(
          siteKey: 's',
          vodId: 'v',
          sourceTitle: '尚公主2026',
        ),
      );
      expect(again.result, isA<TmdbMatchHit>());
      expect(again.level, 'cache');
      expect(again.requestCount, 0);
      expect(client.searchCount, searchBefore, reason: '缓存命中不得再发搜索请求');
    });

    // 契约锚点：`01` §5.3 第三级 `smart`「有年份时接受 ±1 年」+ §5.5「重试命中后
    // 跑完整三级，不是只跑 strict」。
    // 安卓同源：TmdbMatcher.java:214-228（smart 选择）、394-397（tmdbItemYear）。
    test('尚公主2026 + 条目 2025：smart 默认开启 → split.smart', () async {
      final client = _FakeClient()
        ..routeQuery('尚公主2026', {'results': []})
        ..routeQuery('尚公主', {
          'results': [
            _tvResult(id: 9002, name: '尚公主', firstAirDate: '2025-01-01'),
          ],
        })
        ..route('/tv/9002', {'id': 9002, 'name': '尚公主'});
      final outcome = await build(client).match(
        const TmdbMatchRequest(
          siteKey: 's',
          vodId: 'v',
          sourceTitle: '尚公主2026',
        ),
      );

      expect(outcome.result, isA<TmdbMatchHit>());
      expect(outcome.level, 'split.smart', reason: '相差 1 年由 smart 级接受');
      expect(outcome.requestCount, 2);
    });

    // 契约锚点：`01` §5.3「smart 仅当设置项『智能匹配』开启」+ §5.5「重试不受
    // 智能匹配开关影响：开关只管第三级」。
    test('smartMatch=false：同年仍 split.strict；差 1 年则未命中且无 smart 级', () async {
      final strictClient = _FakeClient()
        ..routeQuery('尚公主2026', {'results': []})
        ..routeQuery('尚公主', {
          'results': [
            _tvResult(id: 9001, name: '尚公主', firstAirDate: '2026-01-01'),
          ],
        })
        ..route('/tv/9001', {'id': 9001, 'name': '尚公主'});
      final strictOutcome = await build(
        strictClient,
        config: smartOff,
      ).match(
        const TmdbMatchRequest(
          siteKey: 's',
          vodId: 'v',
          sourceTitle: '尚公主2026',
        ),
      );
      expect(strictOutcome.result, isA<TmdbMatchHit>());
      expect(strictOutcome.level, 'split.strict');
      expect(strictOutcome.requestCount, 2);

      final missClient = _FakeClient()
        ..routeQuery('尚公主2026', {'results': []})
        ..routeQuery('尚公主', {
          'results': [
            _tvResult(id: 9002, name: '尚公主', firstAirDate: '2025-01-01'),
          ],
        })
        ..route('/tv/9002', {'id': 9002, 'name': '尚公主'});
      final missOutcome = await build(missClient, config: smartOff).match(
        const TmdbMatchRequest(
          siteKey: 's',
          vodId: 'v',
          sourceTitle: '尚公主2026',
        ),
      );
      expect(missOutcome.result, isA<TmdbMatchMiss>());
      expect(
        (missOutcome.result as TmdbMatchMiss).reason,
        TmdbMissReason.noCandidates,
      );
      expect(missOutcome.level, isNull, reason: '关闭智能匹配后不得出现 smart 级');
      expect(missOutcome.item, isNull);
    });

    // 契约锚点：`01` §4 步骤 3「单条查询清洗后零结果且原始输入与清洗结果不同 →
    // 用原始输入再搜一次」；§3.3 步骤 2（`【国产】` 是 PC 补充的噪声括号段）。
    // 安卓同源：TmdbMatcher.java:113-125（search(keyword, vod) 的原始词兜底）。
    test('原始关键词兜底：【国产】尚公主 → 清洗词零结果时再搜原始串', () async {
      expect(
        cleanTitle('【国产】尚公主'),
        '尚公主',
        reason: '前提：噪声括号段被丢成空格（§3.3 步骤 2）',
      );
      final client = _FakeClient()
        ..routeQuery('尚公主', {'results': []})
        ..routeQuery('【国产】尚公主', {
          'results': [
            _tvResult(id: 9003, name: '尚公主', firstAirDate: '2026-01-01'),
          ],
        })
        ..route('/tv/9003', {'id': 9003, 'name': '尚公主'});
      final outcome = await build(client).match(
        const TmdbMatchRequest(
          siteKey: 's',
          vodId: 'v',
          sourceTitle: '【国产】尚公主',
        ),
      );

      expect(outcome.result, isA<TmdbMatchHit>());
      expect(outcome.item?.identity?.key, 'tv:9003');
      expect(outcome.level, 'strict');
      // §4 约束：单条候选最多两次请求（清洗词 + 原始词）。
      expect(outcome.requestCount, 2);
      expect(
        client.requests.any(
          (url) => url.queryParameters['query'] == '【国产】尚公主',
        ),
        isTrue,
        reason: '原始输入必须真的被搜过',
      );
    });

    // 契约锚点：`01` §5.2「过滤后为空则视为本次匹配失败（不回退到未过滤结果）」
    // + §4 步骤 4：过滤同样作用于 §5.5 的重试结果。
    test('媒体类型过滤作用于拆分重试：重试只返回 movie → 未命中且不回退', () async {
      final client = _FakeClient()
        ..routeQuery('尚公主2026', {'results': []})
        ..routeQuery('尚公主', {
          'results': [
            _movieResult(id: 550, title: '尚公主', releaseDate: '2026-01-01'),
          ],
        });
      final outcome = await build(client).match(
        const TmdbMatchRequest(
          siteKey: 's',
          vodId: 'v',
          sourceTitle: '尚公主2026',
          expectedMediaType: TmdbMediaType.tv,
        ),
      );

      expect(outcome.result, isA<TmdbMatchMiss>());
      expect(
        (outcome.result as TmdbMatchMiss).reason,
        TmdbMissReason.noCandidates,
      );
      expect(outcome.item, isNull, reason: '不得回退到未过滤的 movie');
      expect(outcome.requestCount, 2);
    });

    // 契约锚点：`01` §4 约束「候选上限 3；每条候选最多两次请求（清洗词 + 原始词）；
    // 加上 §5.5 的唯一一次重试，最坏预算 7」——本场景 1 条候选 + 1 次重试 ≤ 3。
    test('有年份但两条 query 都空：请求数不超过 3，未命中为 noCandidates', () async {
      expect(
        cleanTitle('尚公主 2026'),
        '尚公主 2026',
        reason: '前提：年份留在清洗结果里（§3.3 无删年份步骤）',
      );
      final client = _FakeClient()
        ..routeQuery('尚公主 2026', {'results': []})
        ..routeQuery('尚公主', {'results': []});
      final outcome = await build(client).match(
        const TmdbMatchRequest(
          siteKey: 's',
          vodId: 'v',
          sourceTitle: '尚公主 2026',
        ),
      );

      expect(outcome.requestCount, lessThanOrEqualTo(3));
      expect(outcome.result, isA<TmdbMatchMiss>());
      expect(
        (outcome.result as TmdbMatchMiss).reason,
        TmdbMissReason.noCandidates,
      );
    });

    // 契约锚点：`01` §5.6 排序键 1「标题相似度（降序），比较前两侧先剥掉年份记号」。
    // 安卓同源：TmdbMatcher.java:214-228（titleSimilarityScore 剥年份）。
    test('searchCandidates 剥年份排序：尚公主（2026）排在尚公主 前传（2020）之前', () async {
      expect(
        cleanTitle('尚公主2026'),
        '尚公主2026',
        reason: '前提：清洗保留年份（§3.3）',
      );
      final client = _FakeClient()
        ..routeQuery('尚公主2026', {
          'results': [
            // 故意把评分更高、年份更早的候选放在前面，由排序而非输入顺序决定名次。
            _tvResult(
              id: 9102,
              name: '尚公主 前传',
              firstAirDate: '2020-01-01',
              vote: 9.5,
            ),
            _tvResult(
              id: 9101,
              name: '尚公主',
              firstAirDate: '2026-01-01',
              vote: 5,
            ),
          ],
        });
      final results = await build(client).searchCandidates('尚公主2026');

      expect(results.map((item) => item.title).toList(), [
        '尚公主',
        '尚公主 前传',
      ]);
    });

    // 契约锚点：`01` §5.5 重试规则「year <= 0 → return null」+「重试只做一次」：
    // 源标题没有年份就没有拆分查询，零结果只发 1 次搜索。
    // 安卓同源：TmdbMatcher.java:374-376（year <= 0 直接返回 null）。
    test('源标题无年份且零结果：只发 1 次搜索请求（不触发拆分重试）', () async {
      final client = _FakeClient()..routeQuery('尚公主', {'results': []});
      final outcome = await build(client).match(
        const TmdbMatchRequest(siteKey: 's', vodId: 'v', sourceTitle: '尚公主'),
      );

      expect(outcome.requestCount, 1);
      expect(client.searchCount, 1, reason: '无年份不得触发拆分重试');
      expect(outcome.result, isA<TmdbMatchMiss>());
      expect(
        (outcome.result as TmdbMatchMiss).reason,
        TmdbMissReason.noCandidates,
      );
    });
    // 契约锚点：`01` §5.5「重试的年份来源优先级：调用方显式 → vod.year → vod.name →
    // 关键词」——`vod.year` 与标题年份冲突时第一轮拆分判 null，必须退回「只用标题年份」
    // 再算一次，否则一条脏站源年份就把整条重试吞掉。
    test('站源年份冲突：vodYear 2025 + 标题 2026 仍能拆分重试命中', () async {
      final client = _FakeClient()
        ..routeQuery('尚公主2026', {'results': []})
        ..routeQuery('尚公主', {
          'results': [
            _tvResult(id: 9004, name: '尚公主', firstAirDate: '2026-01-01'),
          ],
        })
        ..route('/tv/9004', {'id': 9004, 'name': '尚公主'});
      final outcome = await build(client).match(
        const TmdbMatchRequest(
          siteKey: 's',
          vodId: 'v',
          sourceTitle: '尚公主2026',
          vodYear: '2025',
        ),
      );

      expect(outcome.result, isA<TmdbMatchHit>());
      expect(outcome.level, startsWith('split.'));
      expect(outcome.level, 'split.strict', reason: '重试年份取标题的 2026 → strict');
      expect(outcome.requestCount, 2);
      expect(client.searchCount, 2);
    });

    // 契约锚点：`01` §4 约束「同参数不重复请求」+ §5.5「重试只做一次」：拆分出的查询词
    // 与已搜过的候选相同时必须跳过，不能白花一次请求。
    test('拆分查询词与首条候选相同时不再重搜（alreadySearched 守卫）', () async {
      final client = _FakeClient()
        ..routeQuery('尚公主', {'results': []})
        ..routeQuery('尚公主2026', {'results': []});
      final outcome = await build(client).match(
        const TmdbMatchRequest(
          siteKey: 's',
          vodId: 'v',
          sourceTitle: '尚公主2026',
          searchKeyword: '尚公主',
        ),
      );

      expect(outcome.requestCount, 2, reason: '两条候选各 1 次，拆分不得重搜');
      expect(client.searchCount, 2);
      expect(
        client.requests
            .where((url) => url.queryParameters['query'] == '尚公主')
            .length,
        1,
        reason: '「尚公主」只应被搜一次',
      );
      expect(outcome.result, isA<TmdbMatchMiss>());
    });

    // 契约锚点：`01` §4 步骤 3「清洗后零结果且原始输入与清洗结果不同 → 用原始输入再搜
    // 一次」；搜索入口（§7.2）走同一条兜底。
    // 安卓同源：TmdbMatcher.java:113-125（search(keyword, vod)）。
    test('searchCandidates 原始词兜底：【国产】尚公主', () async {
      final client = _FakeClient()
        ..routeQuery('尚公主', {'results': []})
        ..routeQuery('【国产】尚公主', {
          'results': [
            _tvResult(id: 9005, name: '尚公主', firstAirDate: '2026-01-01'),
          ],
        });
      final results = await build(client).searchCandidates('【国产】尚公主');

      expect(results, isNotEmpty);
      expect(results.first.title, '尚公主');
      expect(
        client.requests.any(
          (url) => url.queryParameters['query'] == '【国产】尚公主',
        ),
        isTrue,
        reason: '原始词必须真的发出过一次请求',
      );
    });

    // 契约锚点：`01` §5.3「三级选择里的条目年份一律是副标题年份，缺省回退标题年份」
    // + §5.1（缺上映日期时副标题为空）。只读副标题会把有年份的候选判成未知年份。
    // 安卓同源：TmdbMatcher.java:394-397（tmdbItemYear）。
    test('条目年份回退标题：无 first_air_date 的「尚公主 2026」仍 strict 命中', () async {
      final client = _FakeClient()
        ..routeQuery('尚公主 2026', {
          'results': [_tvResult(id: 9006, name: '尚公主 2026')],
        })
        ..route('/tv/9006', {'id': 9006, 'name': '尚公主 2026'});
      final outcome = await build(client).match(
        const TmdbMatchRequest(
          siteKey: 's',
          vodId: 'v',
          sourceTitle: '尚公主 2026',
        ),
      );

      expect(outcome.result, isA<TmdbMatchHit>());
      expect(outcome.item?.subtitle, '', reason: '前提：没有上映日期 → 副标题为空');
      expect(outcome.item?.year, 2026, reason: '副标题缺省时回退标题年份');
      expect(outcome.level, 'strict');
      expect(outcome.requestCount, 1, reason: 'strict 已命中，不该再走拆分重试');
    });
  });

  // -------------------------------------------------------------------------
  // 匹配缓存键稳定性（`01` §2.4/§2.5）
  // -------------------------------------------------------------------------

  group('TmdbCacheKey 缓存键稳定性（§2.4）', () {
    // 契约锚点：`01` §2.4（三层键）。缓存键是**持久化格式**：清洗规则演进时键形态
    // 必须保持不变，否则升级前落盘的手动结论会读不回来。
    test('normalizeSourceTitle 先剥全部括号再归一', () {
      expect(TmdbCacheKey.normalizeSourceTitle('剧名 (2024)'), '剧名');
      expect(TmdbCacheKey.normalizeSourceTitle('【国产】庆余年'), '庆余年');
    });

    // 契约锚点：`01` §2.4 三层键 + §2.5（手动结论排他）：别名按旧键形态落盘，
    // 升级后用保留年份括号的标题仍必须读回同一条手动结论，且零网络请求。
    test('旧别名仍可读回：手动结论以「剧名」落盘，用「剧名 (2024)」match 命中 manual', () async {
      final store = InMemoryTmdbMatchStore();
      store.cache.putManual(
        's',
        'v',
        ['剧名'],
        const TmdbItem(tmdbId: 1399, mediaType: TmdbMediaType.tv, title: '剧名'),
        matchedAt: 1,
      );
      final client = _FakeClient();
      final service = TmdbIdentityService(
        config: _ready,
        service: TmdbService(config: _ready, client: client),
        store: store,
      );
      final outcome = await service.match(
        const TmdbMatchRequest(
          siteKey: 's',
          vodId: 'v',
          sourceTitle: '剧名 (2024)',
        ),
      );

      expect(outcome.result, isA<TmdbMatchHit>());
      expect(outcome.level, 'manual');
      expect(outcome.item?.identity?.key, 'tv:1399');
      expect(outcome.requestCount, 0);
      expect(client.searchCount, 0, reason: '缓存命中不得发搜索请求');
    });
  });

  group('TmdbSeasonService 解析与落盘（§3）', () {
    TmdbSourceLine line({
      String flagKey = 'f#0',
      List<String>? names,
      List<int>? seasons,
      List<int>? numbers,
    }) => TmdbSourceLine(
      flagKey: flagKey,
      sourceFlag: '线路一',
      episodeNames: names ?? List.generate(12, (i) => '第${i + 1}集'),
      sourceSeasonNumbers: seasons,
      sourceEpisodeNumbers: numbers,
    );

    test('唯一结果自动落盘', () {
      final store = InMemoryTmdbSeasonStore();
      final service = TmdbSeasonService(store: store);
      final outcome = service.resolve(
        TmdbSeasonRequestFactory.single(
          line: line(),
          tmdbSeasons: const [1],
          seasonCounts: const {1: 12},
        ),
      );
      expect(outcome.resolution.status, ResolutionStatus.resolved);
      expect(outcome.scope, const KnownSeason(1));
      expect(outcome.persisted, isTrue);
      expect(store.bindings.length, 1);
    });

    test('ambiguous 不落盘（§3.4）', () {
      final store = InMemoryTmdbSeasonStore();
      final service = TmdbSeasonService(store: store);
      final outcome = service.resolve(
        TmdbSeasonRequestFactory.single(
          line: line(names: List.generate(7, (i) => 'E${i + 1}')),
          tmdbSeasons: const [1, 2],
          seasonCounts: const {1: 12, 2: 10},
        ),
      );
      expect(outcome.resolution.status, ResolutionStatus.ambiguous);
      expect(outcome.persisted, isFalse);
      expect(store.bindings, isEmpty, reason: 'ambiguous 必须零写入');
    });

    test('ambiguous 不落盘，且不触碰其他线路的既有绑定（§3.4）', () {
      final store = InMemoryTmdbSeasonStore();
      final service = TmdbSeasonService(store: store);

      // 线路 A（f#0）先得到唯一结果 → 自动落盘 S2
      final a = service.resolve(
        TmdbSeasonRequestFactory.single(
          line: line(flagKey: 'f#0', names: List.generate(10, (i) => 'E${i + 1}')),
          tmdbSeasons: const [1, 2],
          seasonCounts: const {1: 12, 2: 10},
        ),
      );
      expect(a.resolution.status, ResolutionStatus.resolved);
      expect(a.scope, const KnownSeason(2));
      expect(a.persisted, isTrue);
      final beforeA = store.findBinding(
        configId: 0, siteKey: 's', vodId: 'v', sourceTitle: '剧名', flagKey: 'f#0',
      );

      // 线路 B（f#1）只有 7 集 → 两季都无法解释 → ambiguous
      final b = service.resolve(
        TmdbSeasonRequestFactory.single(
          line: line(flagKey: 'f#1', names: List.generate(7, (i) => 'E${i + 1}')),
          tmdbSeasons: const [1, 2],
          seasonCounts: const {1: 12, 2: 10},
        ),
      );
      expect(b.resolution.status, ResolutionStatus.ambiguous);
      expect(b.persisted, isFalse);
      expect(b.scope, const UnknownSeason());

      // f#1 不得产生任何绑定
      expect(
        store.findBinding(
          configId: 0, siteKey: 's', vodId: 'v', sourceTitle: '剧名', flagKey: 'f#1',
        ),
        isNull,
        reason: 'ambiguous 必须零写入',
      );
      // f#0 的绑定原样保留
      final afterA = store.findBinding(
        configId: 0, siteKey: 's', vodId: 'v', sourceTitle: '剧名', flagKey: 'f#0',
      );
      expect(afterA?.seasonNumber, 2);
      expect(afterA?.updatedAt, beforeA?.updatedAt, reason: '不得重写其他线路的绑定');
      // 全库只有一条绑定
      expect(store.bindings.length, 1);
    });

    test('手动绑定压过自动解析（§3.3 第 5 步）', () {
      final store = InMemoryTmdbSeasonStore();
      final service = TmdbSeasonService(store: store);
      service.bindSeason(
        siteKey: 's',
        vodId: 'v',
        sourceTitle: '剧名',
        flagKey: 'f#0',
        sourceFlag: '线路一',
        tmdbId: 1399,
        mediaType: TmdbMediaType.tv,
        mode: SeasonBindingMode.manualSeason,
        seasonNumber: 2,
        line: line(),
        seasonCounts: const {1: 12, 2: 10},
      );
      // 即便线路有 10 集（恰好等于 S2 集数），也应返回手动的 S2
      final outcome = service.resolve(
        TmdbSeasonRequestFactory.single(
          line: line(names: List.generate(10, (i) => 'E${i + 1}')),
          tmdbSeasons: const [1, 2],
          seasonCounts: const {1: 12, 2: 10},
        ),
      );
      expect(outcome.resolution.source, ResolutionSource.manual);
      expect(outcome.scope, const KnownSeason(2));
      expect(outcome.persisted, isFalse, reason: '已有绑定不需再次落盘');
    });

    test('可播放季度随解析结果返回', () {
      final store = InMemoryTmdbSeasonStore();
      final service = TmdbSeasonService(store: store);
      final outcome = service.resolve(
        TmdbSeasonRequestFactory.single(
          line: line(
            names: List.generate(5, (i) => 'E${i + 1}'),
            seasons: const [1, 1, 1, 2, 2],
          ),
          tmdbSeasons: const [1, 2],
          seasonCounts: const {1: 3, 2: 2},
        ),
      );
      expect(outcome.availableSeasons, [1, 2]);
    });

    test('手动绑定三种模式', () {
      final store = InMemoryTmdbSeasonStore();
      final service = TmdbSeasonService(store: store);
      final l = line();
      // manualSeason
      expect(
        service.bindSeason(
          siteKey: 's', vodId: 'v', sourceTitle: 't', flagKey: 'f#0',
          sourceFlag: '线路一', tmdbId: 1399, mediaType: TmdbMediaType.tv,
          mode: SeasonBindingMode.manualSeason, seasonNumber: 2,
          line: l, seasonCounts: const {1: 12, 2: 10},
        )?.seasonNumber,
        2,
      );
      // manualFlat
      expect(
        service.bindSeason(
          siteKey: 's', vodId: 'v', sourceTitle: 't', flagKey: 'f#1',
          sourceFlag: '线路二', tmdbId: 1399, mediaType: TmdbMediaType.tv,
          mode: SeasonBindingMode.manualFlat,
          line: l, seasonCounts: const {1: 12, 2: 10},
        )?.mode,
        SeasonBindingMode.manualFlat,
      );
      // manualMultiSlice
      expect(
        service.bindSeason(
          siteKey: 's', vodId: 'v', sourceTitle: 't', flagKey: 'f#2',
          sourceFlag: '线路三', tmdbId: 1399, mediaType: TmdbMediaType.tv,
          mode: SeasonBindingMode.manualMultiSlice,
          line: l, seasonCounts: const {1: 12, 2: 10},
        )?.mode,
        SeasonBindingMode.manualMultiSlice,
      );
    });

    test('非法绑定参数返回 null', () {
      final store = InMemoryTmdbSeasonStore();
      final service = TmdbSeasonService(store: store);
      final l = line();
      // movie 不允许
      expect(
        service.bindSeason(
          siteKey: 's', vodId: 'v', sourceTitle: 't', flagKey: 'f',
          sourceFlag: '线路', tmdbId: 1399, mediaType: TmdbMediaType.movie,
          mode: SeasonBindingMode.manualSeason, seasonNumber: 1,
          line: l, seasonCounts: const {1: 12},
        ),
        isNull,
      );
      // manualSeason 缺 seasonNumber
      expect(
        service.bindSeason(
          siteKey: 's', vodId: 'v', sourceTitle: 't', flagKey: 'f',
          sourceFlag: '线路', tmdbId: 1399, mediaType: TmdbMediaType.tv,
          mode: SeasonBindingMode.manualSeason,
          line: l, seasonCounts: const {1: 12},
        ),
        isNull,
      );
      // manualFlat 带 seasonNumber
      expect(
        service.bindSeason(
          siteKey: 's', vodId: 'v', sourceTitle: 't', flagKey: 'f',
          sourceFlag: '线路', tmdbId: 1399, mediaType: TmdbMediaType.tv,
          mode: SeasonBindingMode.manualFlat, seasonNumber: 1,
          line: l, seasonCounts: const {1: 12},
        ),
        isNull,
      );
      // tmdbId <= 0
      expect(
        service.bindSeason(
          siteKey: 's', vodId: 'v', sourceTitle: 't', flagKey: 'f',
          sourceFlag: '线路', tmdbId: 0, mediaType: TmdbMediaType.tv,
          mode: SeasonBindingMode.manualSeason, seasonNumber: 1,
          line: l, seasonCounts: const {1: 12},
        ),
        isNull,
      );
      expect(store.bindings, isEmpty);
    });

    test('clearBinding 清除绑定与线路索引', () {
      final store = InMemoryTmdbSeasonStore();
      final service = TmdbSeasonService(store: store);
      service.bindSeason(
        siteKey: 's', vodId: 'v', sourceTitle: 't', flagKey: 'f#0',
        sourceFlag: '线路一', tmdbId: 1399, mediaType: TmdbMediaType.tv,
        mode: SeasonBindingMode.manualSeason, seasonNumber: 1,
        line: line(), seasonCounts: const {1: 12},
      );
      expect(store.bindings.length, 1);
      expect(store.routes.length, 1);
      service.clearBinding(
        siteKey: 's', vodId: 'v', sourceTitle: 't', flagKey: 'f#0',
      );
      expect(store.bindings, isEmpty);
      expect(store.routes, isEmpty);
    });

    test('removeIfMediaChanged：身份变化才清除', () {
      final store = InMemoryTmdbSeasonStore();
      final service = TmdbSeasonService(store: store);
      service.bindSeason(
        siteKey: 's', vodId: 'v', sourceTitle: 't', flagKey: 'f#0',
        sourceFlag: '线路一', tmdbId: 1399, mediaType: TmdbMediaType.tv,
        mode: SeasonBindingMode.manualSeason, seasonNumber: 1,
        line: line(), seasonCounts: const {1: 12},
      );
      // 身份未变 → 不清除
      expect(
        service.removeIfMediaChanged(
          siteKey: 's', vodId: 'v', sourceTitle: 't', flagKey: 'f#0',
          tmdbId: 1399, mediaType: TmdbMediaType.tv,
        ),
        isFalse,
      );
      expect(store.bindings.length, 1);
      // 身份变化 → 清除
      expect(
        service.removeIfMediaChanged(
          siteKey: 's', vodId: 'v', sourceTitle: 't', flagKey: 'f#0',
          tmdbId: 2000, mediaType: TmdbMediaType.tv,
        ),
        isTrue,
      );
      expect(store.bindings, isEmpty);
    });
  });

  group('TmdbSeasonService 进度（§6）', () {
    test('KnownSeason 写入进度', () {
      final store = InMemoryTmdbSeasonStore();
      final service = TmdbSeasonService(store: store);
      final written = service.recordProgress(
        identity: _tv(1399),
        scope: const KnownSeason(2),
        episodeNumber: 3,
        positionMs: 1000,
        durationMs: 2000,
        sourceFlag: '线路一',
        sourceEpisodeName: '第3集',
        sourceEpisodeUrl: 'https://cdn/e3.m3u8',
        sourceHistoryKey: 'k',
        sourceBindingKey: 'b',
      );
      expect(written, isTrue);
      final record = service.progressFor(identity: _tv(1399), seasonNumber: 2);
      expect(record?.episodeNumber, 3);
      expect(record?.positionMs, 1000);
      expect(record?.identityKey, 'tv:1399:season:2');
    });

    test('MultiSeason 写入对应段的季度', () {
      final store = InMemoryTmdbSeasonStore();
      final service = TmdbSeasonService(store: store);
      const scope = MultiSeason([
        SeasonSegment(
          seasonNumber: 1,
          sourceEpisodeStartIndex: 0,
          sourceEpisodeEndIndex: 2,
          tmdbEpisodeStartNumber: 1,
        ),
        SeasonSegment(
          seasonNumber: 2,
          sourceEpisodeStartIndex: 3,
          sourceEpisodeEndIndex: 4,
          tmdbEpisodeStartNumber: 1,
        ),
      ]);
      expect(
        service.recordProgress(
          identity: _tv(1399),
          scope: scope,
          segmentSeason: 2,
          episodeNumber: 1,
          positionMs: 500,
          durationMs: 2000,
          sourceFlag: '线路',
          sourceEpisodeName: 'E1',
          sourceEpisodeUrl: 'u',
          sourceHistoryKey: 'k',
          sourceBindingKey: 'b',
        ),
        isTrue,
      );
      expect(service.progressFor(identity: _tv(1399), seasonNumber: 2), isNotNull);
      expect(service.progressFor(identity: _tv(1399), seasonNumber: 1), isNull);
    });

    test('MultiSeason 未指定段 → 不写', () {
      final store = InMemoryTmdbSeasonStore();
      final service = TmdbSeasonService(store: store);
      expect(
        service.recordProgress(
          identity: _tv(1399),
          scope: const MultiSeason([
            SeasonSegment(
              seasonNumber: 1,
              sourceEpisodeStartIndex: 0,
              sourceEpisodeEndIndex: 2,
              tmdbEpisodeStartNumber: 1,
            ),
            SeasonSegment(
              seasonNumber: 2,
              sourceEpisodeStartIndex: 3,
              sourceEpisodeEndIndex: 4,
              tmdbEpisodeStartNumber: 1,
            ),
          ]),
          episodeNumber: 1,
          positionMs: 500,
          durationMs: 2000,
          sourceFlag: '线路',
          sourceEpisodeName: 'E1',
          sourceEpisodeUrl: 'u',
          sourceHistoryKey: 'k',
          sourceBindingKey: 'b',
        ),
        isFalse,
      );
      expect(store.progress, isEmpty);
    });

    test('UnknownSeason 不写季度进度（§6.2）', () {
      final store = InMemoryTmdbSeasonStore();
      final service = TmdbSeasonService(store: store);
      expect(
        service.recordProgress(
          identity: _tv(1399),
          scope: const UnknownSeason(),
          episodeNumber: 1,
          positionMs: 500,
          durationMs: 2000,
          sourceFlag: '线路',
          sourceEpisodeName: 'E1',
          sourceEpisodeUrl: 'u',
          sourceHistoryKey: 'k',
          sourceBindingKey: 'b',
        ),
        isFalse,
      );
      expect(store.progress, isEmpty, reason: 'UnknownSeason 不得写季度进度');
    });

    test('电影不写季度进度', () {
      final store = InMemoryTmdbSeasonStore();
      final service = TmdbSeasonService(store: store);
      final movie = TmdbIdentity.of(TmdbMediaType.movie, 550)!;
      expect(
        service.recordProgress(
          identity: movie,
          scope: const KnownSeason(1),
          episodeNumber: 1,
          positionMs: 500,
          durationMs: 2000,
          sourceFlag: '线路',
          sourceEpisodeName: 'E1',
          sourceEpisodeUrl: 'u',
          sourceHistoryKey: 'k',
          sourceBindingKey: 'b',
        ),
        isFalse,
      );
    });

    test('播放另一季不覆盖当前季（§6.2）', () {
      final store = InMemoryTmdbSeasonStore();
      final service = TmdbSeasonService(store: store);
      void write(int season, int position) {
        service.recordProgress(
          identity: _tv(1399),
          scope: KnownSeason(season),
          episodeNumber: 1,
          positionMs: position,
          durationMs: 2000,
          sourceFlag: '线路',
          sourceEpisodeName: 'E1',
          sourceEpisodeUrl: 'u',
          sourceHistoryKey: 'k',
          sourceBindingKey: 'b',
        );
      }

      write(1, 111);
      write(2, 222);
      expect(
        service.progressFor(identity: _tv(1399), seasonNumber: 1)?.positionMs,
        111,
        reason: 'S2 写入不得覆盖 S1',
      );
      expect(
        service.progressFor(identity: _tv(1399), seasonNumber: 2)?.positionMs,
        222,
      );
    });

    test('progressList 按季度升序（历史投影，§7.1）', () {
      final store = InMemoryTmdbSeasonStore();
      final service = TmdbSeasonService(store: store);
      for (final season in [3, 1, 2]) {
        service.recordProgress(
          identity: _tv(1399),
          scope: KnownSeason(season),
          episodeNumber: 1,
          positionMs: 0,
          durationMs: 0,
          sourceFlag: '线路',
          sourceEpisodeName: 'E1',
          sourceEpisodeUrl: 'u',
          sourceHistoryKey: 'k',
          sourceBindingKey: 'b',
        );
      }
      final list = service.progressList(identity: _tv(1399));
      expect(list.map((r) => r.seasonNumber), [1, 2, 3]);
    });
  });

  group('TmdbSeasonService 换源与删除（§7）', () {
    TmdbSourceLine line({String flagKey = 'f#0'}) => TmdbSourceLine(
      flagKey: flagKey,
      sourceFlag: '线路',
      episodeNames: List.generate(12, (i) => '第${i + 1}集'),
    );

    test('candidatesForSeason 只返回覆盖该季的线路（§7.3）', () {
      final store = InMemoryTmdbSeasonStore();
      final service = TmdbSeasonService(store: store);
      service.bindSeason(
        siteKey: 's1', vodId: 'v1', sourceTitle: 't', flagKey: 'f#0',
        sourceFlag: 'S1线路', tmdbId: 1399, mediaType: TmdbMediaType.tv,
        mode: SeasonBindingMode.manualSeason, seasonNumber: 1,
        line: line(), seasonCounts: const {1: 12},
      );
      service.bindSeason(
        siteKey: 's2', vodId: 'v2', sourceTitle: 't', flagKey: 'f#0',
        sourceFlag: 'S2线路', tmdbId: 1399, mediaType: TmdbMediaType.tv,
        mode: SeasonBindingMode.manualSeason, seasonNumber: 2,
        line: line(), seasonCounts: const {1: 12, 2: 10},
      );
      final s1 = service.candidatesForSeason(
        identity: _tv(1399),
        seasonNumber: 1,
      );
      expect(s1.length, 1);
      expect(s1.first.sourceFlag, 'S1线路');
      final s2 = service.candidatesForSeason(
        identity: _tv(1399),
        seasonNumber: 2,
      );
      expect(s2.length, 1);
      expect(s2.first.sourceFlag, 'S2线路');
    });

    test('acceptsSource 五条兼容判定（§7.3）', () {
      final service = TmdbSeasonService(store: InMemoryTmdbSeasonStore());
      // target Known(N) accepts source Known(N)
      expect(
        service.acceptsSource(
          target: const KnownSeason(1),
          source: const KnownSeason(1),
        ),
        isTrue,
      );
      // target Known(N) accepts source Multi containing N
      const multi = MultiSeason([
        SeasonSegment(
          seasonNumber: 1,
          sourceEpisodeStartIndex: 0,
          sourceEpisodeEndIndex: 2,
          tmdbEpisodeStartNumber: 1,
        ),
        SeasonSegment(
          seasonNumber: 2,
          sourceEpisodeStartIndex: 3,
          sourceEpisodeEndIndex: 4,
          tmdbEpisodeStartNumber: 1,
        ),
      ]);
      expect(
        service.acceptsSource(target: const KnownSeason(2), source: multi),
        isTrue,
      );
      // target Known(N) rejects source Known(M), M != N
      expect(
        service.acceptsSource(
          target: const KnownSeason(1),
          source: const KnownSeason(2),
        ),
        isFalse,
      );
      // target Known(N) rejects source Unknown for automatic switching
      expect(
        service.acceptsSource(
          target: const KnownSeason(1),
          source: const UnknownSeason(),
        ),
        isFalse,
      );
      // target Unknown 只自动续播原来源
      expect(
        service.acceptsSource(
          target: const UnknownSeason(),
          source: const KnownSeason(1),
        ),
        isFalse,
      );
    });

    test('deleteSeasonHistory 只删该季（§7.4）', () {
      final store = InMemoryTmdbSeasonStore();
      final service = TmdbSeasonService(store: store);
      for (final season in [1, 2]) {
        service.recordProgress(
          identity: _tv(1399),
          scope: KnownSeason(season),
          episodeNumber: 1,
          positionMs: 0,
          durationMs: 0,
          sourceFlag: '线路',
          sourceEpisodeName: 'E1',
          sourceEpisodeUrl: 'u',
          sourceHistoryKey: 'k',
          sourceBindingKey: 'b',
        );
      }
      expect(
        service.deleteSeasonHistory(identity: _tv(1399), seasonNumber: 1),
        1,
      );
      expect(service.progressFor(identity: _tv(1399), seasonNumber: 2), isNotNull);
      expect(service.progressFor(identity: _tv(1399), seasonNumber: 1), isNull);
    });

    test('deleteMediaHistory 清空全部季度（二级操作）', () {
      final store = InMemoryTmdbSeasonStore();
      final service = TmdbSeasonService(store: store);
      for (final season in [1, 2, 3]) {
        service.recordProgress(
          identity: _tv(1399),
          scope: KnownSeason(season),
          episodeNumber: 1,
          positionMs: 0,
          durationMs: 0,
          sourceFlag: '线路',
          sourceEpisodeName: 'E1',
          sourceEpisodeUrl: 'u',
          sourceHistoryKey: 'k',
          sourceBindingKey: 'b',
        );
      }
      expect(service.deleteMediaHistory(identity: _tv(1399)), 3);
      expect(store.progress, isEmpty);
    });

    test('pruneRouteBindings 按指纹失效（§5.4）', () {
      final store = InMemoryTmdbSeasonStore();
      final service = TmdbSeasonService(store: store);
      service.bindSeason(
        siteKey: 's', vodId: 'v', sourceTitle: 't', flagKey: 'f#0',
        sourceFlag: '线路一', tmdbId: 1399, mediaType: TmdbMediaType.tv,
        mode: SeasonBindingMode.manualSeason, seasonNumber: 1,
        line: line(), seasonCounts: const {1: 12},
      );
      final fingerprint = store.routes.values.first.sourceFingerprint;
      // 指纹一致 → 不删
      expect(
        service.pruneRouteBindings(
          siteKey: 's',
          vodId: 'v',
          currentFingerprints: {'f#0': fingerprint},
        ),
        0,
      );
      // 指纹变化 → 删除
      expect(
        service.pruneRouteBindings(
          siteKey: 's',
          vodId: 'v',
          currentFingerprints: {'f#0': 'changed'},
        ),
        1,
      );
      expect(store.routes, isEmpty);
      // 线路消失（键不存在）→ 删除
    });

    test('pruneRouteBindings：线路消失也失效', () {
      final store = InMemoryTmdbSeasonStore();
      final service = TmdbSeasonService(store: store);
      service.bindSeason(
        siteKey: 's', vodId: 'v', sourceTitle: 't', flagKey: 'f#0',
        sourceFlag: '线路一', tmdbId: 1399, mediaType: TmdbMediaType.tv,
        mode: SeasonBindingMode.manualSeason, seasonNumber: 1,
        line: line(), seasonCounts: const {1: 12},
      );
      expect(
        service.pruneRouteBindings(
          siteKey: 's',
          vodId: 'v',
          currentFingerprints: const {},
        ),
        1,
      );
    });

    test('线路绑定索引容量上限（§5.5）', () {
      final store = InMemoryTmdbSeasonStore();
      final service = TmdbSeasonService(store: store, maxRouteBindings: 3);
      for (var i = 0; i < 5; i++) {
        service.bindSeason(
          siteKey: 's', vodId: 'v$i', sourceTitle: 't', flagKey: 'f#0',
          sourceFlag: '线路$i', tmdbId: 1399, mediaType: TmdbMediaType.tv,
          mode: SeasonBindingMode.manualSeason, seasonNumber: 1,
          line: line(flagKey: 'f#0'), seasonCounts: const {1: 12},
        );
      }
      expect(store.routes.length, lessThanOrEqualTo(3));
    });
  });
}

/// 总是返回 401 的客户端（验证鉴权传播）。
class _AuthFailClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(
        Stream<List<int>>.value(utf8.encode('{"status_code":7}')),
        401,
      );
}

/// 构造单线路解析请求的辅助。
abstract final class TmdbSeasonRequestFactory {
  static TmdbSeasonResolveRequest single({
    required TmdbSourceLine line,
    required List<int> tmdbSeasons,
    required Map<int, int> seasonCounts,
    String siteKey = 's',
    String vodId = 'v',
    String sourceTitle = '剧名',
    int tmdbId = 1399,
    int requestSeason = -1,
    bool allowHeuristicGuessing = true,
  }) => TmdbSeasonResolveRequest(
    siteKey: siteKey,
    vodId: vodId,
    sourceTitle: sourceTitle,
    line: line,
    tmdbId: tmdbId,
    tmdbSeasons: tmdbSeasons,
    seasonCounts: seasonCounts,
    requestSeason: requestSeason,
    allowHeuristicGuessing: allowHeuristicGuessing,
  );
}
