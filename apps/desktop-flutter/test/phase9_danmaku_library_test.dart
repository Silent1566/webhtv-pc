import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/danmaku_catalog.dart';
import 'package:webhtv_pc/core/danmaku_match.dart';
import 'package:webhtv_pc/core/danmaku_settings.dart';
import 'package:webhtv_pc/services/danmaku_library_service.dart';

/// 裁剪后的真实 danmu_api 中转响应（本会话对可用测试源实测，去掉了其余候选）。
const String relayFixture = '''
[
  {"name":"灵笼 第二季(2025)【动漫】from bilibili - 【bilibili1】 第1话 末世桃源","url":"http://relay.test:9321/TOKEN/api/v2/comment/120952?format=xml"},
  {"name":"灵笼 第二季(2025)【3D网络放送】from dandan - 【dandan】 第1话","url":"http://relay.test:9321/TOKEN/api/v2/comment/121029?format=xml"}
]
''';

const String firstRelayUrl =
    'http://relay.test:9321/TOKEN/api/v2/comment/120952?format=xml';

/// 旧通用契约（`{code,data:[...]}`）的响应体。
String legacyFixture() => jsonEncode({
  'code': 0,
  'data': [
    {
      'id': 'd1',
      'title': '灵笼',
      'episode': '01',
      'url': 'https://example.test/1.xml',
      'count': 120,
    },
    {'id': 'd2', 'title': '缺地址'},
  ],
});

http.Response jsonResponse(String body) => http.Response.bytes(
  utf8.encode(body),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

/// 中转形态的响应体：`[{name,url}]`。
String relayBody(List<Map<String, String>> items) => jsonEncode(items);

const DanmakuQuery relayQuery = DanmakuQuery(
  title: '灵笼',
  episode: '第1集',
  siteKey: 's',
  vodId: 'v',
  episodeName: '第1集',
);

void main() {
  group('弹幕库设置（design/02 §2.4）', () {
    test('默认全关', () {
      const settings = DanmakuSettings.defaults();
      expect(settings.autoSearch, isFalse);
      expect(settings.hasLibrary, isFalse);
      expect(settings.isEnabled, isFalse);
    });

    test('序列化往返与空白清理', () {
      const settings = DanmakuSettings(
        autoSearch: true,
        sources: [
          DanmakuSourceConfig(
            id: 'legacy',
            name: '默认',
            url: '  https://example.test/d  ',
          ),
        ],
      );
      final restored = DanmakuSettings.fromJson(
        jsonDecode(jsonEncode(settings.toJson())),
      );
      expect(restored.autoSearch, isTrue);
      expect(restored.apiUrl, 'https://example.test/d');
      expect(restored.sources.single.url, 'https://example.test/d');
      expect(restored.isEnabled, isTrue);
    });
  });

  group('弹幕中转协议（design/02 §2.3）', () {
    test('POST：自动补 /danmaku、表单 name/episode，并按 name 拆分片名与集', () async {
      final requests = <http.Request>[];
      final service = DanmakuLibraryService(
        client: MockClient((request) async {
          requests.add(request);
          return jsonResponse(relayFixture);
        }),
      );

      final entries = await service.search(
        apiUrl: 'http://relay.test:9321/TOKEN',
        title: '灵笼',
        episode: '第1话',
      );

      expect(requests, hasLength(1));
      final request = requests.single;
      expect(request.method, 'POST');
      expect(request.url.host, 'relay.test');
      expect(request.url.port, 9321);
      expect(request.url.path, '/TOKEN/danmaku');
      expect(request.headers['accept'], 'application/json');
      expect(
        request.headers['content-type'],
        contains('application/x-www-form-urlencoded'),
      );
      final form = Uri.splitQueryString(request.body);
      expect(form['name'], '灵笼');
      expect(form['episode'], '第1话');

      expect(entries, hasLength(2));
      final first = entries.first;
      expect(first.title, '灵笼 第二季(2025)【动漫】from bilibili');
      expect(first.episode, '【bilibili1】 第1话 末世桃源');
      expect(first.url, firstRelayUrl);
      expect(first.id, firstRelayUrl);
      expect(first.providerId, 'tvbox');
      expect(first.count, 0);
      // 单源 search 不填来源归属（由 searchSources 负责）。
      expect(first.libraryId, isEmpty);
      expect(first.libraryName, isEmpty);
      expect(first.channel, isEmpty);
      // 数值集号在协议转换时就解析好：UI 排序/「仅本集」只读字段，不再解析展示串。
      expect(first.episodeNumber, 1);
      expect(entries.last.episodeNumber, 1);

      final picked = pickDanmakuEntry(entries: entries, query: relayQuery);
      expect(picked, isNotNull);
      expect(picked!.url, firstRelayUrl);
    });

    test('已是 /danmaku 或路径段数 > 1 的地址不再二次追加', () async {
      Future<Uri> targetFor(String apiUrl) async {
        late Uri target;
        final service = DanmakuLibraryService(
          client: MockClient((request) async {
            target = request.url;
            return jsonResponse('[]');
          }),
        );
        await service.search(apiUrl: apiUrl, title: 't', episode: '第1话');
        return target;
      }

      expect(
        (await targetFor('http://relay.test:9321/TOKEN/danmaku')).path,
        '/TOKEN/danmaku',
      );
      expect(
        (await targetFor('http://relay.test:9321/TOKEN/Danmaku')).path,
        '/TOKEN/Danmaku',
      );
      expect(
        (await targetFor('http://relay.test:9321/api/v2/search')).path,
        '/api/v2/search',
      );
      // 只有主机的地址补成根下的 /danmaku。
      expect((await targetFor('http://relay.test:9321')).path, '/danmaku');
    });

    test('{name}/{episode} 占位符走 GET 且做编码替换，不发 POST', () async {
      final requests = <http.Request>[];
      final service = DanmakuLibraryService(
        client: MockClient((request) async {
          requests.add(request);
          return jsonResponse(relayFixture);
        }),
      );

      final entries = await service.search(
        apiUrl: 'http://relay.test:9321/search?kw={name}&ep={episode}',
        title: '灵笼',
        episode: '第1话',
      );

      expect(requests, hasLength(1));
      final request = requests.single;
      expect(request.method, 'GET');
      expect(request.url.path, '/search');
      expect(request.url.queryParameters['kw'], '灵笼');
      expect(request.url.queryParameters['ep'], '第1话');
      // 原始 query 里必须是 UTF-8 百分号编码，而不是直接塞中文。
      expect(request.url.query, contains('%E7%81%B5%E7%AC%BC'));
      expect(entries, hasLength(2));
    });
  });

  group('旧通用契约兜底（design/02 §2.3）', () {
    test('中转 500 / 非 JSON 时回落 GET ?title=&episode= 并按旧形状解析', () async {
      final relayFailures = <http.Response>[
        http.Response('server error', 500),
        http.Response(
          '<html><body>danmu_api web ui</body></html>',
          200,
          headers: {'content-type': 'text/html; charset=utf-8'},
        ),
      ];

      for (final failure in relayFailures) {
        final requests = <http.Request>[];
        final service = DanmakuLibraryService(
          client: MockClient((request) async {
            requests.add(request);
            return request.method == 'POST'
                ? failure
                : jsonResponse(legacyFixture());
          }),
        );

        final entries = await service.search(
          apiUrl: 'http://relay.test:9321/TOKEN',
          title: '灵笼',
          episode: '第1话',
        );

        expect(requests, hasLength(2), reason: '中转不可用后才补一次旧契约请求');
        expect(requests.first.method, 'POST');
        expect(requests.first.url.path, '/TOKEN/danmaku');
        expect(requests.last.method, 'GET');
        // 回落用用户填的原地址，不追加 /danmaku。
        expect(requests.last.url.path, '/TOKEN');
        expect(requests.last.url.queryParameters['title'], '灵笼');
        expect(requests.last.url.queryParameters['episode'], '第1话');

        expect(entries, hasLength(1));
        expect(entries.single.id, 'd1');
        expect(entries.single.title, '灵笼');
        expect(entries.single.episode, '01');
        expect(entries.single.count, 120);
      }
    });

    test('中转超时按 relayTimeout 判定，超时后回落旧契约', () async {
      final methods = <String>[];
      final service = DanmakuLibraryService(
        // 比 MockClient 的 120ms 更短，模拟 danmu_api 冷搜索赶不上超时。
        relayTimeout: const Duration(milliseconds: 20),
        client: MockClient((request) async {
          methods.add(request.method);
          if (request.method == 'POST') {
            await Future<void>.delayed(const Duration(milliseconds: 120));
            return jsonResponse(relayFixture);
          }
          return jsonResponse(legacyFixture());
        }),
      );

      final entries = await service.search(
        apiUrl: 'http://relay.test:9321/TOKEN',
        title: '灵笼',
        episode: '第1话',
      );

      expect(methods, ['POST', 'GET']);
      expect(entries, hasLength(1));
      expect(entries.single.id, 'd1');
      expect(entries.single.count, 120);
    });

    test('中转返回合法空数组 [] 是权威结果：只有一次请求', () async {
      final requests = <http.Request>[];
      final service = DanmakuLibraryService(
        client: MockClient((request) async {
          requests.add(request);
          return jsonResponse('[]');
        }),
      );

      final entries = await service.search(
        apiUrl: 'http://relay.test:9321/TOKEN',
        title: '灵笼',
        episode: '第1话',
      );

      expect(entries, isEmpty);
      expect(requests, hasLength(1));
      expect(requests.single.method, 'POST');
    });

    test('未配置地址时零请求', () async {
      var called = false;
      final service = DanmakuLibraryService(
        client: MockClient((_) async {
          called = true;
          return jsonResponse('[]');
        }),
      );
      expect(await service.search(apiUrl: '', title: 'x'), isEmpty);
      expect(called, isFalse);
    });

    test('非 2xx / 非法 JSON / 网络异常返回空', () async {
      final cases = <DanmakuLibraryService>[
        DanmakuLibraryService(
          client: MockClient((_) async => http.Response('x', 500)),
        ),
        DanmakuLibraryService(
          client: MockClient((_) async => http.Response('not json', 200)),
        ),
        DanmakuLibraryService(
          client: MockClient((_) async => throw const SocketException('x')),
        ),
      ];
      for (final service in cases) {
        expect(
          await service.search(apiUrl: 'https://example.test/s', title: 'x'),
          isEmpty,
        );
      }
    });

    test('中转结果按 url 去重保序', () async {
      final service = DanmakuLibraryService(
        client: MockClient(
          (_) async => jsonResponse(
            jsonEncode([
              {'name': '灵笼 - 第1话', 'url': 'https://example.test/a.xml'},
              {'name': '灵笼 - 第1话', 'url': 'https://example.test/a.xml'},
              {'name': '灵笼 - 第2话', 'url': 'https://example.test/b.xml'},
            ]),
          ),
        ),
      );
      final entries = await service.search(
        apiUrl: 'http://relay.test:9321/TOKEN',
        title: '灵笼',
        episode: '第1话',
      );
      expect(entries.map((entry) => entry.url), [
        'https://example.test/a.xml',
        'https://example.test/b.xml',
      ]);
      expect(entries.first.episode, '第1话');
    });

    test('中转结果最多 30 条', () async {
      final service = DanmakuLibraryService(
        client: MockClient(
          (_) async => jsonResponse(
            jsonEncode([
              for (var i = 0; i < 35; i++)
                {
                  'name': '灵笼 - 第${i + 1}话',
                  'url': 'https://example.test/$i.xml',
                },
            ]),
          ),
        ),
      );
      final entries = await service.search(
        apiUrl: 'http://relay.test:9321/TOKEN',
        title: '灵笼',
      );
      expect(entries, hasLength(30));
    });
  });

  group('多源并行搜索（S1）', () {
    test('两源并行合并：按源顺序拼接、带来源与渠道、按 url 去重', () async {
      final hosts = <String>[];
      final service = DanmakuLibraryService(
        client: MockClient((request) async {
          hosts.add(request.url.host);
          switch (request.url.host) {
            case 'bili.test':
              return jsonResponse(
                relayBody([
                  {
                    'name':
                        '灵笼 第二季(2025)【动漫】from bilibili - 【bilibili1】 第1话 末世桃源',
                    'url': 'https://cdn.test/bili-1.xml',
                  },
                  {
                    'name': '灵笼 第二季(2025)【动漫】from bilibili - 【bilibili1】 第2话',
                    'url': 'https://cdn.test/shared.xml',
                  },
                ]),
              );
            case 'dd.test':
              return jsonResponse(
                relayBody([
                  {
                    // 与 bilibili 源撞同一个 url：合并时只留先到的。
                    'name': '灵笼 第二季(2025)【动漫】from dandan - 【dandan】 第1话',
                    'url': 'https://cdn.test/shared.xml',
                  },
                  {
                    'name': '灵笼 第二季(2025)【动漫】from dandan - 【dandan】 第3话',
                    'url': 'https://cdn.test/dd-3.xml',
                  },
                ]),
              );
          }
          return http.Response('not found', 404);
        }),
      );

      final result = await service.searchSources(
        sources: const [
          DanmakuSourceConfig(
            id: 'bili',
            name: 'B站',
            url: 'http://bili.test:9321/TOKEN',
          ),
          DanmakuSourceConfig(
            id: 'dd',
            name: '弹弹',
            url: 'http://dd.test:9321/TOKEN',
          ),
        ],
        title: '灵笼',
        episode: '第1话',
      );

      expect(hosts.toSet(), {'bili.test', 'dd.test'});
      expect(result.entries.map((entry) => entry.url), [
        'https://cdn.test/bili-1.xml',
        'https://cdn.test/shared.xml',
        'https://cdn.test/dd-3.xml',
      ]);
      expect(result.entries.map((entry) => entry.libraryId), [
        'bili',
        'bili',
        'dd',
      ]);
      expect(result.entries.map((entry) => entry.libraryName), [
        'B站',
        'B站',
        '弹弹',
      ]);
      expect(result.entries.map((entry) => entry.channel), [
        'bilibili',
        'bilibili',
        'dandan',
      ]);

      expect(result.sources.map((source) => source.id), ['bili', 'dd']);
      expect(result.sources.map((source) => source.name), ['B站', '弹弹']);
      expect(result.sources.map((source) => source.ok), [true, true]);
      expect(result.sources.map((source) => source.count), [
        2,
        2,
      ], reason: 'count 是合并去重前的源内条数');
      expect(result.sources.every((source) => source.elapsedMs >= 0), isTrue);
      expect(result.sources.every((source) => source.error == null), isTrue);
    });

    test('没有渠道标记时用 providerId 兜底', () async {
      final service = DanmakuLibraryService(
        client: MockClient(
          (_) async => jsonResponse(
            relayBody([
              {
                'name': '灵笼 - 第1话',
                'url': 'https://cdn.test/a.xml',
                'source': 'duoduo',
              },
            ]),
          ),
        ),
      );
      final result = await service.searchSources(
        sources: const [
          DanmakuSourceConfig(id: 'relay', name: '中转', url: 'http://a.test/d'),
        ],
        title: '灵笼',
      );
      expect(result.entries.single.channel, 'duoduo');
    });

    test('上游没给来源时渠道是「未知」，不是占位 providerId', () async {
      final service = DanmakuLibraryService(
        client: MockClient(
          (_) async => jsonResponse(
            relayBody([
              {'name': '灵笼 - 第1话', 'url': 'https://cdn.test/tvbox.xml'},
            ]),
          ),
        ),
      );
      final result = await service.searchSources(
        sources: const [
          DanmakuSourceConfig(id: 'relay', name: '中转', url: 'http://a.test/d'),
        ],
        title: '灵笼',
      );
      // 'tvbox' 是适配层在「上游没给来源」时写的占位值：它出现在渠道筛选里
      // 就是一个既不可读也不指向真实平台的假分组。
      expect(result.entries.single.channel, kUnknownDanmakuChannel);
    });

    test('单源失败只影响该源：ok=false + error，其它源结果仍在', () async {
      final service = DanmakuLibraryService(
        client: MockClient((request) async {
          if (request.url.host == 'down.test') {
            return http.Response('boom', 500);
          }
          return jsonResponse(
            relayBody([
              {
                'name': '灵笼 第二季(2025)【动漫】from dandan - 【dandan】 第1话',
                'url': 'https://cdn.test/ok.xml',
              },
            ]),
          );
        }),
      );

      final result = await service.searchSources(
        sources: const [
          DanmakuSourceConfig(
            id: 'down',
            name: '坏源',
            url: 'http://down.test:9321/TOKEN',
          ),
          DanmakuSourceConfig(
            id: 'ok',
            name: '好源',
            url: 'http://ok.test:9321/TOKEN',
          ),
        ],
        title: '灵笼',
      );

      expect(result.sources.map((source) => source.ok), [false, true]);
      expect(result.sources.first.count, 0);
      expect(result.sources.first.error, isNotNull);
      expect(result.sources.first.error, contains('500'));
      expect(result.entries.map((entry) => entry.libraryId), ['ok']);
    });

    test('地址非法的源判失败而不是静默成功', () async {
      var called = false;
      final service = DanmakuLibraryService(
        client: MockClient((_) async {
          called = true;
          return jsonResponse('[]');
        }),
      );
      final result = await service.searchSources(
        sources: const [
          DanmakuSourceConfig(id: 'bad', name: '坏地址', url: 'not-a-url'),
        ],
        title: '灵笼',
      );
      expect(result.sources.single.ok, isFalse);
      expect(result.sources.single.error, contains('地址无效'));
      expect(result.entries, isEmpty);
      expect(called, isFalse);
    });

    test('禁用的源不参与搜索；没有启用的源时零请求', () async {
      var called = 0;
      final service = DanmakuLibraryService(
        client: MockClient((_) async {
          called++;
          return jsonResponse('[]');
        }),
      );

      final empty = await service.searchSources(sources: const [], title: '灵笼');
      expect(empty.entries, isEmpty);
      expect(empty.sources, isEmpty);

      final skipped = await service.searchSources(
        sources: const [
          DanmakuSourceConfig(
            id: 'off',
            name: '关掉的',
            url: 'http://off.test/d',
            enabled: false,
          ),
        ],
        title: '灵笼',
      );
      expect(skipped.sources, isEmpty);
      expect(called, isZero);
    });

    test('maxConcurrency 生效：同时最多 N 个请求', () async {
      var active = 0;
      var peak = 0;
      final service = DanmakuLibraryService(
        client: MockClient((_) async {
          active++;
          if (active > peak) peak = active;
          await Future<void>.delayed(const Duration(milliseconds: 20));
          active--;
          return jsonResponse('[]');
        }),
      );

      final result = await service.searchSources(
        sources: [
          for (var index = 0; index < 5; index++)
            DanmakuSourceConfig(
              id: 's$index',
              name: '源 $index',
              url: 'http://s$index.test:9321/TOKEN',
            ),
        ],
        title: '灵笼',
        maxConcurrency: 2,
      );

      expect(peak, greaterThan(1), reason: '确实并行');
      expect(peak, lessThanOrEqualTo(2));
      expect(result.sources, hasLength(5));
      expect(result.sources.every((source) => source.ok), isTrue);
    });

    // ---- S6：逐源回调（增量渲染的底座） ----

    test('逐源回调：按完成顺序回调，最终合并仍按源顺序', () async {
      // 断言一律放到回调外：回调里的异常会被服务层吞掉（这正是它的契约），
      // 写在里面的 expect 失败会被静默吃掉。
      final calls = <String>[];
      final counts = <String, int>{};
      final owners = <String, Set<String>>{};
      final service = DanmakuLibraryService(
        client: MockClient((request) async {
          if (request.url.host == 'slow.test') {
            await Future<void>.delayed(const Duration(milliseconds: 60));
            return jsonResponse(
              relayBody([
                {
                  'name': '灵笼 第二季(2025)【动漫】from dandan - 【dandan】 第3话',
                  'url': 'https://cdn.test/dd-3.xml',
                },
              ]),
            );
          }
          return jsonResponse(
            relayBody([
              {
                'name':
                    '灵笼 第二季(2025)【动漫】from bilibili - 【bilibili1】 第1话',
                'url': 'https://cdn.test/bili-1.xml',
              },
              {
                'name':
                    '灵笼 第二季(2025)【动漫】from bilibili - 【bilibili1】 第2话',
                'url': 'https://cdn.test/shared.xml',
              },
            ]),
          );
        }),
      );

      final result = await service.searchSources(
        // 慢源排在配置的第一位：若按配置顺序回调，这个用例抓不到差异。
        sources: const [
          DanmakuSourceConfig(
            id: 'slow',
            name: '慢源',
            url: 'http://slow.test:9321/TOKEN',
          ),
          DanmakuSourceConfig(
            id: 'fast',
            name: '快源',
            url: 'http://fast.test:9321/TOKEN',
          ),
        ],
        title: '灵笼',
        episode: '第1话',
        onSourceResult: (source, entries) {
          calls.add(source.id);
          counts[source.id] = entries.length;
          owners[source.id] = entries.map((entry) => entry.libraryId).toSet();
        },
      );

      expect(calls, ['fast', 'slow'], reason: '回调顺序 = 完成顺序，不是配置顺序');
      expect(counts, {'fast': 2, 'slow': 1});
      // 回调拿到的是「该源自己那批」：未跨源合并，但已带归属信息，
      // UI 拿到就能直接渲染来源/渠道。
      expect(owners, {
        'fast': {'fast'},
        'slow': {'slow'},
      });
      // 旧契约不变：按源配置顺序合并 + 按 url 去重。
      expect(result.entries.map((entry) => entry.url), [
        'https://cdn.test/dd-3.xml',
        'https://cdn.test/bili-1.xml',
        'https://cdn.test/shared.xml',
      ]);
      expect(result.entries.map((entry) => entry.libraryId), [
        'slow',
        'fast',
        'fast',
      ]);
      expect(result.sources.map((source) => source.id), ['slow', 'fast']);
    });

    test('回调抛异常不影响搜索：结果与逐源记账照常', () async {
      final service = DanmakuLibraryService(
        client: MockClient(
          (_) async => jsonResponse(
            relayBody([
              {'name': '灵笼 - 第1话', 'url': 'https://cdn.test/a.xml'},
            ]),
          ),
        ),
      );

      final result = await service.searchSources(
        sources: const [
          DanmakuSourceConfig(id: 'a', name: '源A', url: 'http://a.test/d'),
          DanmakuSourceConfig(id: 'b', name: '源B', url: 'http://b.test/d'),
        ],
        title: '灵笼',
        onSourceResult: (source, entries) => throw StateError('回调炸了'),
      );

      expect(result.sources.map((source) => source.ok), [true, true]);
      // 两个源撞同一个 url：合并后仍只有一条。
      expect(result.entries.map((entry) => entry.url), [
        'https://cdn.test/a.xml',
      ]);
    });
  });

  group('匹配质量（design/02 §2.3）', () {
    test('集号按可信度择序提取', () {
      expect(extractEpisodeNumber('【bilibili1】 第2话 波澜初起'), 2);
      expect(extractEpisodeNumber('第12-13集'), 12);
      expect(extractEpisodeNumber('EP03'), 3);
      expect(extractEpisodeNumber('12'), 12);
      expect(extractEpisodeNumber('第1集'), 1);
      expect(extractEpisodeNumber(''), isNull);
      expect(extractEpisodeNumber(null), isNull);
    });

    test('同分条目保持输入顺序', () {
      DanmakuLibraryEntry entry(String id, String provider) =>
          DanmakuLibraryEntry(
            providerId: provider,
            id: id,
            title: '灵笼',
            episode: '第1话',
            url: 'https://example.test/$id.xml',
          );
      final ranked = rankDanmakuEntries(
        entries: [entry('b', 'zzz'), entry('a', 'aaa'), entry('c', 'mmm')],
        query: relayQuery,
      );
      expect(ranked.map((item) => item.id), ['b', 'a', 'c']);
      expect(ranked.map((item) => item.score).toSet(), hasLength(1));
    });
  });
}
