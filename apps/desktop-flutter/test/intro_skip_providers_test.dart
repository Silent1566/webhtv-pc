/// 片头片尾**远端标定**数据源的契约测试（`lib/services/intro_skip/`）。
///
/// 锁死四件事：
/// 1. 三家各自把真实响应形状解析成 [RawSkipSegment]，含 null 时间点、chapter
///    丢弃与秒→毫秒；
/// 2. `null`（没答上来）与 `[]`（这集没数据）的差别决定能不能缓存；
/// 3. 并行查询里一家失败不影响另一家，总超时能收口；
/// 4. 缓存是 LRU、有上限、且存的是**未折算**的原始段。
///
/// 全部用注入的 `http.Client` 与内联 JSON，不发真实网络。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/skip_plan.dart';
import 'package:webhtv_pc/services/intro_skip/introdb_provider.dart';
import 'package:webhtv_pc/services/intro_skip/provider.dart';
import 'package:webhtv_pc/services/intro_skip/registry.dart';
import 'package:webhtv_pc/services/intro_skip/theintrodb_provider.dart';
import 'package:webhtv_pc/services/intro_skip/todb_provider.dart';

// --- 夹具 ---------------------------------------------------------------------

/// 实测的 IntroDB 响应（2026-11）。四个顶层字段是对象而不是数组。
const String introDbBody =
    '{"imdb_id":"tt0944947","media_type":"tv","season":1,"episode":1,'
    '"intro":null,"recap":null,'
    '"outro":{"start_sec":3631.5,"end_sec":3699.5,"start_ms":3631500,'
    '"end_ms":3699500,"confidence":1,"submission_count":2},'
    '"post_credits":null,"no_intro":false}';

/// 实测的 TheIntroDB 响应（2026-11）。`credits[].end_ms` 为 null = 延伸到结尾。
const String theIntroDbBody =
    '{"tvdb_id":121361,"type":"tv","season":1,"episode":1,'
    '"intro":[{"start_ms":473681,"end_ms":571154}],'
    '"credits":[{"start_ms":3630040,"end_ms":null}]}';

/// 实测的 TODB PlayBack 响应（2026-11）。时间单位是秒，另加一条 chapter。
const String todbBody =
    '{"page":1,"page_size":3,"has_more":false,"items":['
    '{"version_id":1192,"version_name":"爱奇艺","version_runtime":1300,'
    '"version_platform":"iqiyi","video_type":"tv","marker":['
    '{"marker_id":1588,"marker_type":"intro","title":null,'
    '"time_start":0,"time_end":27},'
    '{"marker_id":1589,"marker_type":"outro","title":null,'
    '"time_start":1270,"time_end":null},'
    '{"marker_id":1590,"marker_type":"chapter","title":"第一幕",'
    '"time_start":300,"time_end":600}]}]}';

const SkipQuery tvQuery = SkipQuery(
  tmdbId: 1399,
  imdbId: 'tt0944947',
  mediaType: 'tv',
  season: 1,
  episode: 1,
);

const SkipQuery movieQuery = SkipQuery(tmdbId: 603, mediaType: 'movie');

/// UTF-8 JSON 响应（TODB 的版本名是中文，顺带锁住解码路径）。
http.Response jsonResponse(String body, [int statusCode = 200]) =>
    http.Response.bytes(
      utf8.encode(body),
      statusCode,
      headers: const <String, String>{
        'content-type': 'application/json; charset=utf-8',
      },
    );

/// 按 host 分派响应的客户端；未登记的 host 一律 500（失败路径）。
MockClient byHost(
  Map<String, http.Response> responses, {
  List<http.Request>? log,
}) => MockClient((request) async {
  log?.add(request);
  return responses[request.url.host] ?? jsonResponse('{}', 500);
});

/// 假 provider：把 `fetch` 换成任意行为（超时、抛异常、固定结果）。
class FakeProvider extends IntroSkipProvider {
  FakeProvider({required this.id, required this.onFetch});

  @override
  final String id;

  final Future<List<RawSkipSegment>?> Function() onFetch;

  @override
  String get name => id;

  @override
  int get sourceBit => SkipSourceBits.bitOf(id);

  @override
  Future<List<RawSkipSegment>?> fetch(
    SkipQuery query, {
    required http.Client client,
  }) => onFetch();
}

void main() {
  const introMax = skipMaxMediaTimeMs;

  group('IntroDB', () {
    test('顶层对象字段解析：outro 取 start_ms/end_ms，带分数与提交次数', () async {
      final segments = await const IntroDbProvider().fetch(
        tvQuery,
        client: byHost(<String, http.Response>{
          'api.introdb.app': jsonResponse(introDbBody),
        }),
      );
      expect(segments, hasLength(1));
      final outro = segments!.single;
      expect(outro.kind, SkipKind.outro);
      expect(outro.provider, 'introdb');
      expect(outro.startMs, 3631500);
      expect(outro.endMs, 3699500);
      expect(outro.confidence, 1);
      expect(outro.submissionCount, 2);
      // 该响应没有顶层时长字段：0 = 无从折算。
      expect(outro.referenceDurationMs, 0);
    });

    test('缺 *_ms 时退回 *_sec 乘 1000', () async {
      final segments = await const IntroDbProvider().fetch(
        tvQuery,
        client: byHost(<String, http.Response>{
          'api.introdb.app': jsonResponse(
            '{"intro":{"start_sec":5.5,"end_sec":90.25}}',
          ),
        }),
      );
      expect(segments, hasLength(1));
      expect(segments!.single.startMs, 5500);
      expect(segments.single.endMs, 90250);
    });

    test('四个顶层字段各自映射成本地类型', () async {
      final segments = await const IntroDbProvider().fetch(
        tvQuery,
        client: byHost(<String, http.Response>{
          'api.introdb.app': jsonResponse(
            '{"recap":{"start_ms":0,"end_ms":30000},'
            '"intro":{"start_ms":30000,"end_ms":120000},'
            '"outro":{"start_ms":1300000,"end_ms":1400000},'
            '"post_credits":{"start_ms":1400000,"end_ms":1450000}}',
          ),
        }),
      );
      expect(segments!.map((s) => s.kind).toList(), <SkipKind>[
        SkipKind.recap,
        SkipKind.intro,
        SkipKind.outro,
        // post_credits 是片尾彩蛋，不是下集预告。
        SkipKind.postCredits,
      ]);
    });

    test('顶层时长别名字段都认（duration_ms / runtime_sec …）', () async {
      final segments = await const IntroDbProvider().fetch(
        tvQuery,
        client: byHost(<String, http.Response>{
          'api.introdb.app': jsonResponse(
            '{"runtime_sec":1420,"outro":{"start_ms":1300000}}',
          ),
        }),
      );
      expect(segments!.single.referenceDurationMs, 1420000);
    });

    test('全为 null 的 200 是「这集没数据」：空列表而不是 null', () async {
      final segments = await const IntroDbProvider().fetch(
        tvQuery,
        client: byHost(<String, http.Response>{
          'api.introdb.app': jsonResponse(
            '{"intro":null,"recap":null,"outro":null,"post_credits":null}',
          ),
        }),
      );
      expect(segments, isNotNull);
      expect(segments, isEmpty);
    });

    test('404 是「没数据」，其它非 2xx 是「没答上来」', () async {
      final notFound = await const IntroDbProvider().fetch(
        tvQuery,
        client: byHost(<String, http.Response>{
          'api.introdb.app': jsonResponse('{}', 404),
        }),
      );
      expect(notFound, isNotNull);
      expect(notFound, isEmpty);
      for (final status in <int>[500, 503, 403]) {
        final failed = await const IntroDbProvider().fetch(
          tvQuery,
          client: byHost(<String, http.Response>{
            'api.introdb.app': jsonResponse('{}', status),
          }),
        );
        expect(failed, isNull, reason: 'status $status 必须算没答上来');
      }
    });

    test('坏 JSON 与非对象根一律 null（不抛异常）', () async {
      for (final body in <String>['not json', '[1,2,3]', '{"intro":']) {
        final segments = await const IntroDbProvider().fetch(
          tvQuery,
          client: byHost(<String, http.Response>{
            'api.introdb.app': jsonResponse(body),
          }),
        );
        expect(segments, isNull, reason: body);
      }
    });

    test('网络异常折成 null', () async {
      final segments = await const IntroDbProvider().fetch(
        tvQuery,
        client: MockClient((request) async {
          throw const SocketExceptionStub();
        }),
      );
      expect(segments, isNull);
    });

    test('离谱数值夹取而不是绕回：时间夹到 skipMaxMediaTimeMs、次数夹到上限', () async {
      final segments = await const IntroDbProvider().fetch(
        tvQuery,
        client: byHost(<String, http.Response>{
          'api.introdb.app': jsonResponse(
            '{"intro":{"start_ms":999999999999,"end_ms":-5,'
            '"confidence":5,"submission_count":99999999}}',
          ),
        }),
      );
      final intro = segments!.single;
      expect(intro.startMs, introMax);
      expect(intro.endMs, 0);
      expect(intro.confidence, 1);
      expect(intro.submissionCount, skipMaxSubmissionCount);
    });

    test('没有 IMDb 季集号时一次请求都不发（查不了 = 没数据）', () async {
      final log = <http.Request>[];
      final segments = await const IntroDbProvider().fetch(
        movieQuery,
        client: byHost(<String, http.Response>{}, log: log),
      );
      expect(log, isEmpty);
      expect(segments, isNotNull);
      expect(segments, isEmpty);
    });

    test('请求参数是 imdb_id + season + episode 的 GET', () async {
      final log = <http.Request>[];
      await const IntroDbProvider().fetch(
        tvQuery,
        client: byHost(<String, http.Response>{
          'api.introdb.app': jsonResponse(introDbBody),
        }, log: log),
      );
      final request = log.single;
      expect(request.method, 'GET');
      expect(request.url.host, 'api.introdb.app');
      expect(request.url.path, '/segments');
      expect(request.url.queryParameters, <String, String>{
        'imdb_id': 'tt0944947',
        'season': '1',
        'episode': '1',
      });
    });
  });

  group('TheIntroDB', () {
    test('intro 取数组、credits 映射片尾，end_ms=null 原样保留', () async {
      final segments = await const TheIntroDbProvider().fetch(
        tvQuery,
        client: byHost(<String, http.Response>{
          'api.theintrodb.org': jsonResponse(theIntroDbBody),
        }),
      );
      expect(segments, hasLength(2));
      final intro = segments!.first;
      expect(intro.kind, SkipKind.intro);
      expect(intro.provider, 'theintrodb');
      expect(intro.startMs, 473681);
      expect(intro.endMs, 571154);
      final outro = segments.last;
      expect(outro.kind, SkipKind.outro);
      expect(outro.startMs, 3630040);
      expect(outro.endMs, isNull);
      // 该接口不下发参考时长。
      expect(outro.referenceDurationMs, 0);
      expect(intro.referenceDurationMs, 0);
    });

    test('start_ms=null 不填 0：null 交给 SkipPlan.resolve 折算成 0', () async {
      final segments = await const TheIntroDbProvider().fetch(
        tvQuery,
        client: byHost(<String, http.Response>{
          'api.theintrodb.org': jsonResponse(
            '{"intro":[{"start_ms":null,"end_ms":571154}]}',
          ),
        }),
      );
      expect(segments!.single.startMs, isNull);
      expect(segments.single.endMs, 571154);
      // 折算这一步才把 null 当 0。
      final plan = SkipPlan.resolve(segments, durationMs: 0);
      expect(plan.segments.single.startMs, 0);
      expect(plan.segments.single.endMs, 571154);
    });

    test('recap / preview / next_episode / trailer 都按数组解析', () async {
      final segments = await const TheIntroDbProvider().fetch(
        tvQuery,
        client: byHost(<String, http.Response>{
          'api.theintrodb.org': jsonResponse(
            '{"recap":[{"start_ms":0,"end_ms":30000}],'
            '"preview":[{"start_ms":1400000,"end_ms":1450000}],'
            '"next_episode":[{"start_ms":1450000,"end_ms":1500000}],'
            '"trailer":[{"start_ms":1500000,"end_ms":1550000}]}',
          ),
        }),
      );
      expect(segments!.map((s) => s.kind).toList(), <SkipKind>[
        SkipKind.recap,
        SkipKind.preview,
        SkipKind.preview,
        SkipKind.preview,
      ]);
    });

    test('数组里混进非对象元素时逐个丢弃，不连累整段', () async {
      final segments = await const TheIntroDbProvider().fetch(
        tvQuery,
        client: byHost(<String, http.Response>{
          'api.theintrodb.org': jsonResponse(
            '{"intro":[null,7,{"start_ms":1000,"end_ms":2000}],'
            '"credits":"oops"}',
          ),
        }),
      );
      expect(segments, hasLength(1));
      expect(segments!.single.startMs, 1000);
    });

    test('404 可缓存 vs 非 2xx 不可缓存', () async {
      final notFound = await const TheIntroDbProvider().fetch(
        tvQuery,
        client: byHost(<String, http.Response>{
          'api.theintrodb.org': jsonResponse('{}', 404),
        }),
      );
      expect(notFound, isNotNull);
      expect(notFound, isEmpty);
      final failed = await const TheIntroDbProvider().fetch(
        tvQuery,
        client: byHost(<String, http.Response>{
          'api.theintrodb.org': jsonResponse('{}', 502),
        }),
      );
      expect(failed, isNull);
      final broken = await const TheIntroDbProvider().fetch(
        tvQuery,
        client: byHost(<String, http.Response>{
          'api.theintrodb.org': jsonResponse('<html>'),
        }),
      );
      expect(broken, isNull);
    });

    test('TV 带 season/episode，且时长已知时带 duration_ms', () async {
      final log = <http.Request>[];
      await const TheIntroDbProvider().fetch(
        const SkipQuery(
          tmdbId: 1399,
          mediaType: 'tv',
          season: 2,
          episode: 5,
          durationMs: 3600000,
        ),
        client: byHost(<String, http.Response>{
          'api.theintrodb.org': jsonResponse('{}'),
        }, log: log),
      );
      final parameters = log.single.url.queryParameters;
      expect(log.single.url.path, '/v4/media');
      expect(parameters['tmdb_id'], '1399');
      expect(parameters['season'], '2');
      expect(parameters['episode'], '5');
      expect(parameters['duration_ms'], '3600000');
    });

    test('电影不带季集号，时长未知时不带 duration_ms', () async {
      final log = <http.Request>[];
      await const TheIntroDbProvider().fetch(
        movieQuery,
        client: byHost(<String, http.Response>{
          'api.theintrodb.org': jsonResponse('{}'),
        }, log: log),
      );
      expect(log.single.url.queryParameters, <String, String>{
        'tmdb_id': '603',
      });
    });

    test('没有 TMDB 键时一次请求都不发', () async {
      final log = <http.Request>[];
      final segments = await const TheIntroDbProvider().fetch(
        const SkipQuery(imdbId: 'tt0944947', season: 1, episode: 1),
        client: byHost(<String, http.Response>{}, log: log),
      );
      expect(log, isEmpty);
      expect(segments, isEmpty);
    });
  });

  group('TODB PlayBack', () {
    test('marker 解析成毫秒、chapter 丢弃、end 为 null 原样保留', () async {
      final segments = await const TodbProvider().fetch(
        tvQuery,
        client: byHost(<String, http.Response>{
          'playback.theotherdb.org': jsonResponse(todbBody),
        }),
      );
      expect(segments, hasLength(2), reason: 'chapter 不是可跳过段');
      expect(segments!.map((s) => s.kind).toList(), <SkipKind>[
        SkipKind.intro,
        SkipKind.outro,
      ]);
      final intro = segments.first;
      expect(intro.startMs, 0);
      expect(intro.endMs, 27000);
      expect(intro.provider, 'todb');
      expect(intro.identity, 'todb|1192|1588');
      // version_runtime 也是秒。
      expect(intro.referenceDurationMs, 1300000);
      final outro = segments.last;
      expect(outro.startMs, 1270000);
      expect(outro.endMs, isNull);
      expect(outro.identity, 'todb|1192|1589');
    });

    test('多个版本都产出（去重留给 SkipPlan.resolve）', () async {
      final segments = await const TodbProvider().fetch(
        tvQuery,
        client: byHost(<String, http.Response>{
          'playback.theotherdb.org': jsonResponse(
            '{"items":['
            '{"version_id":1192,"version_runtime":1300,"marker":'
            '[{"marker_id":1,"marker_type":"intro",'
            '"time_start":5,"time_end":27}]},'
            '{"version_id":2001,"version_runtime":1290,"marker":'
            '[{"marker_id":2,"marker_type":"intro",'
            '"time_start":10,"time_end":30}]}]}',
          ),
        }),
      );
      expect(segments, hasLength(2));
      expect(segments!.map((s) => s.identity).toList(), <String>[
        'todb|1192|1',
        'todb|2001|2',
      ]);
      expect(
        SkipPlan.resolve(segments, durationMs: 1300000).segments,
        hasLength(1),
      );
    });

    test('请求是 POST JSON：tv 带季集号、movie 不带', () async {
      final tvLog = <http.Request>[];
      await const TodbProvider().fetch(
        tvQuery,
        client: byHost(<String, http.Response>{
          'playback.theotherdb.org': jsonResponse('{"items":[]}'),
        }, log: tvLog),
      );
      final tvRequest = tvLog.single;
      expect(tvRequest.method, 'POST');
      expect(tvRequest.url.path, '/api/metadata');
      expect(tvRequest.headers['content-type'], contains('application/json'));
      final tvPayload = jsonDecode(tvRequest.body) as Map<String, Object?>;
      expect(tvPayload, <String, Object?>{
        'platform_type': 'tmdb_id_tv',
        'platform_value': '1399',
        'includes': <String>['marker'],
        'page': 1,
        'page_size': 3,
        'season_number': 1,
        'episode_number': 1,
      });

      final movieLog = <http.Request>[];
      await const TodbProvider().fetch(
        movieQuery,
        client: byHost(<String, http.Response>{
          'playback.theotherdb.org': jsonResponse('{"items":[]}'),
        }, log: movieLog),
      );
      final moviePayload =
          jsonDecode(movieLog.single.body) as Map<String, Object?>;
      expect(moviePayload['platform_type'], 'tmdb_id_movie');
      expect(moviePayload['platform_value'], '603');
      expect(moviePayload.containsKey('season_number'), isFalse);
      expect(moviePayload.containsKey('episode_number'), isFalse);
    });

    test('404 可缓存 vs 非 2xx 不可缓存（坏 JSON 同理）', () async {
      final notFound = await const TodbProvider().fetch(
        tvQuery,
        client: byHost(<String, http.Response>{
          'playback.theotherdb.org': jsonResponse('{}', 404),
        }),
      );
      expect(notFound, isNotNull);
      expect(notFound, isEmpty);
      final failed = await const TodbProvider().fetch(
        tvQuery,
        client: byHost(<String, http.Response>{
          'playback.theotherdb.org': jsonResponse('{}', 500),
        }),
      );
      expect(failed, isNull);
      final broken = await const TodbProvider().fetch(
        tvQuery,
        client: byHost(<String, http.Response>{
          'playback.theotherdb.org': jsonResponse('{"items":['),
        }),
      );
      expect(broken, isNull);
    });

    test('没有 TMDB 键时一次请求都不发', () async {
      final log = <http.Request>[];
      final segments = await const TodbProvider().fetch(
        const SkipQuery(imdbId: 'tt0944947', season: 1, episode: 1),
        client: byHost(<String, http.Response>{}, log: log),
      );
      expect(log, isEmpty);
      expect(segments, isEmpty);
    });
  });

  group('注册表与并行查询', () {
    test('buildIntroSkipProviders 按数据源位过滤', () {
      expect(
        buildIntroSkipProviders(SkipSourceBits.defaults).map((p) => p.id),
        <String>['introdb', 'theintrodb', 'todb'],
      );
      expect(
        buildIntroSkipProviders(SkipSourceBits.todb).map((p) => p.id),
        <String>['todb'],
      );
      expect(buildIntroSkipProviders(SkipSourceBits.none), isEmpty);
      for (final provider in buildIntroSkipProviders(SkipSourceBits.defaults)) {
        expect(provider.sourceBit, SkipSourceBits.bitOf(provider.id));
        expect(SkipSourceBits.all, contains(provider.id));
      }
    });

    test('并行发起：三家同时在飞（串行会在这里超时）', () async {
      final seen = <String>[];
      final gate = Completer<void>();
      final client = MockClient((request) async {
        seen.add(request.url.host);
        if (seen.length == 3 && !gate.isCompleted) gate.complete();
        await gate.future;
        return jsonResponse('{"items":[]}');
      });
      final result = await lookupIntroSkip(
        query: tvQuery,
        providers: buildIntroSkipProviders(SkipSourceBits.defaults),
        client: client,
        timeout: const Duration(seconds: 2),
      );
      expect(seen, hasLength(3));
      expect(result.segments, isEmpty);
      expect(result.cacheable, isTrue);
    });

    test('单源非 2xx 不影响其余源，但整体不可缓存', () async {
      final log = <http.Request>[];
      final result = await lookupIntroSkip(
        query: tvQuery,
        providers: buildIntroSkipProviders(
          SkipSourceBits.introdb | SkipSourceBits.theintrodb,
        ),
        client: byHost(<String, http.Response>{
          'api.introdb.app': jsonResponse('{}', 500),
          'api.theintrodb.org': jsonResponse(theIntroDbBody),
        }, log: log),
      );
      expect(log, hasLength(2));
      expect(result.segments.map((s) => s.kind).toList(), <SkipKind>[
        SkipKind.intro,
        SkipKind.outro,
      ]);
      expect(result.segments.every((s) => s.provider == 'theintrodb'), isTrue);
      expect(result.cacheable, isFalse);
    });

    test('一家 404（明确没数据）+ 一家命中：仍可缓存', () async {
      final result = await lookupIntroSkip(
        query: tvQuery,
        providers: buildIntroSkipProviders(
          SkipSourceBits.introdb | SkipSourceBits.theintrodb,
        ),
        client: byHost(<String, http.Response>{
          'api.introdb.app': jsonResponse('{}', 404),
          'api.theintrodb.org': jsonResponse(theIntroDbBody),
        }),
      );
      expect(result.segments, hasLength(2));
      expect(result.cacheable, isTrue);
    });

    test('query 没有任何可用条件时短路：不发请求、结果可缓存', () async {
      final log = <http.Request>[];
      final cache = IntroSkipCache();
      final result = await lookupIntroSkip(
        query: const SkipQuery(),
        providers: buildIntroSkipProviders(SkipSourceBits.defaults),
        client: byHost(<String, http.Response>{}, log: log),
        cache: cache,
      );
      expect(log, isEmpty);
      expect(result.segments, isEmpty);
      expect(result.cacheable, isTrue);
      expect(cache.length, 0);
    });

    test('没有启用任何源时结果不可缓存', () async {
      final result = await lookupIntroSkip(
        query: tvQuery,
        providers: buildIntroSkipProviders(SkipSourceBits.none),
        client: byHost(<String, http.Response>{}),
      );
      expect(result.segments, isEmpty);
      expect(result.cacheable, isFalse);
    });

    test('总超时收口：迟迟不答的那家算失败，其余家照常返回', () async {
      final hanging = Completer<List<RawSkipSegment>?>();
      final result = await lookupIntroSkip(
        query: tvQuery,
        providers: <IntroSkipProvider>[
          FakeProvider(id: 'introdb', onFetch: () => hanging.future),
          FakeProvider(
            id: 'theintrodb',
            onFetch: () async => const <RawSkipSegment>[
              RawSkipSegment(
                kind: SkipKind.intro,
                provider: 'theintrodb',
                startMs: 473681,
                endMs: 571154,
              ),
            ],
          ),
        ],
        client: byHost(<String, http.Response>{}),
        timeout: const Duration(milliseconds: 50),
      );
      expect(result.segments, hasLength(1));
      expect(result.cacheable, isFalse);
      hanging.complete(null);
    });

    test('provider 自己抛异常等同「没答上来」', () async {
      final result = await lookupIntroSkip(
        query: tvQuery,
        providers: <IntroSkipProvider>[
          FakeProvider(
            id: 'introdb',
            onFetch: () async => throw StateError('x'),
          ),
          FakeProvider(
            id: 'todb',
            onFetch: () async => const <RawSkipSegment>[
              RawSkipSegment(
                kind: SkipKind.outro,
                provider: 'todb',
                startMs: 1270000,
                endMs: 1300000,
              ),
            ],
          ),
        ],
        client: byHost(<String, http.Response>{}),
      );
      expect(result.segments, hasLength(1));
      expect(result.segments.single.provider, 'todb');
      expect(result.cacheable, isFalse);
    });

    test('三家都答完才可缓存：缓存里存的是未折算的原始段', () async {
      final log = <http.Request>[];
      final cache = IntroSkipCache();
      final providers = buildIntroSkipProviders(SkipSourceBits.defaults);
      final client = byHost(<String, http.Response>{
        'api.introdb.app': jsonResponse(introDbBody),
        'api.theintrodb.org': jsonResponse(theIntroDbBody),
        'playback.theotherdb.org': jsonResponse(todbBody),
      }, log: log);

      final first = await lookupIntroSkip(
        query: tvQuery,
        providers: providers,
        client: client,
        cache: cache,
      );
      expect(first.cacheable, isTrue);
      expect(first.segments, hasLength(5), reason: '1 + 2 + 2');
      expect(cache.length, 1);

      final stored = cache.get(tvQuery.cacheKey);
      expect(stored, isNotNull);
      expect(stored!, hasLength(5));
      // 未折算：IntroDB 的绝对毫秒原样在，没有被本地时长改写。
      expect(stored.any((s) => s.startMs == 3631500), isTrue);
      expect(stored.any((s) => s.startMs == 1270000), isTrue);
      expect(() => stored.add(stored.first), throwsUnsupportedError);

      final before = log.length;
      final second = await lookupIntroSkip(
        query: tvQuery,
        providers: providers,
        client: client,
        cache: cache,
      );
      expect(log.length, before, reason: '命中缓存不该再发请求');
      expect(second.segments, hasLength(first.segments.length));
      expect(second.cacheable, isTrue);
    });

    test('缓存键不含时长：同一集换线路时长不会穿透缓存', () async {
      final cache = IntroSkipCache();
      final log = <http.Request>[];
      final client = byHost(<String, http.Response>{
        'api.introdb.app': jsonResponse(introDbBody),
      }, log: log);
      const providers = <IntroSkipProvider>[IntroDbProvider()];
      await lookupIntroSkip(
        query: const SkipQuery(
          tmdbId: 1399,
          imdbId: 'tt0944947',
          mediaType: 'tv',
          season: 1,
          episode: 1,
          durationMs: 1000,
        ),
        providers: providers,
        client: client,
        cache: cache,
      );
      final before = log.length;
      await lookupIntroSkip(
        query: const SkipQuery(
          tmdbId: 1399,
          imdbId: 'tt0944947',
          mediaType: 'tv',
          season: 1,
          episode: 1,
          durationMs: 2000,
        ),
        providers: providers,
        client: client,
        cache: cache,
      );
      expect(log.length, before);
    });

    test('失败结果不写缓存', () async {
      final cache = IntroSkipCache();
      final result = await lookupIntroSkip(
        query: tvQuery,
        providers: buildIntroSkipProviders(SkipSourceBits.defaults),
        client: byHost(<String, http.Response>{
          'api.introdb.app': jsonResponse(introDbBody),
          'api.theintrodb.org': jsonResponse('{}', 500),
          'playback.theotherdb.org': jsonResponse(todbBody),
        }),
        cache: cache,
      );
      expect(result.cacheable, isFalse);
      expect(cache.length, 0);
      expect(cache.get(tvQuery.cacheKey), isNull);
    });
  });

  group('内存缓存（LRU）', () {
    test('默认上限 128 条，超出淘汰最久未使用的', () {
      final cache = IntroSkipCache();
      for (var i = 0; i < 130; i++) {
        cache.put('k$i', const <RawSkipSegment>[]);
      }
      expect(cache.length, 128);
      expect(cache.get('k0'), isNull);
      expect(cache.get('k1'), isNull);
      expect(cache.get('k2'), isNotNull);
      expect(cache.get('k129'), isNotNull);
    });

    test('命中会刷新最近使用顺序', () {
      final cache = IntroSkipCache(capacity: 2);
      cache.put('a', const <RawSkipSegment>[]);
      cache.put('b', const <RawSkipSegment>[]);
      expect(cache.get('a'), isNotNull);
      cache.put('c', const <RawSkipSegment>[]);
      expect(cache.get('b'), isNull, reason: 'a 刚被读过，该淘汰 b');
      expect(cache.get('a'), isNotNull);
      expect(cache.get('c'), isNotNull);
      expect(cache.length, 2);
    });

    test('capacity <= 0 表示不缓存', () {
      final cache = IntroSkipCache(capacity: 0);
      cache.put('a', const <RawSkipSegment>[]);
      expect(cache.length, 0);
      expect(cache.get('a'), isNull);
    });

    test('clear 清空', () {
      final cache = IntroSkipCache(capacity: 4);
      cache.put('a', const <RawSkipSegment>[]);
      cache.clear();
      expect(cache.length, 0);
    });
  });
}

/// 模拟网络层异常（用自写异常而不是 dart:io，测试文件不引 IO）。
class SocketExceptionStub implements Exception {
  const SocketExceptionStub();

  @override
  String toString() => 'SocketExceptionStub';
}
