/// CatSpider HTTP（`webhtv-cat-http-v1` / 兼容标签 `tvbox-http-v1`）门禁测试
/// （设计文档 §9.3、§9.4、§8.1、§8.3）。
///
/// 覆盖 `docs/phase2/README.md` §3「CatSpider HTTP」门禁：
/// **至少 3 个可重复 fixture 样本（成功 / 业务错误 / 非 2xx）各走完整
/// home/search/play**，且 404/501 与明确业务错误必须映射为
/// `SPIDER_UNSUPPORTED` / 业务错误，**不得转成空列表冒充成功**。
///
/// fixture 一律来自 `packages/test-fixtures/cathttp`，经 `TestFixtureServer`
/// 的样本族路由 `/cathttp/<family>/<route>` 提供，保证 fixture 与预期结果不分叉（§19）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/cat_http.dart';
import 'package:webhtv_pc/core/http_api.dart';
import 'package:webhtv_pc/core/ipc_protocol.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/sidecar_runtime.dart';
import 'package:webhtv_pc/services/spider_router.dart';

import 'support/test_fixture_server.dart';

void main() {
  late TestFixtureServer server;
  late CatHttpClient client;

  setUp(() async {
    server = await TestFixtureServer.start();
    client = CatHttpClient();
  });

  tearDown(() async {
    client.close();
    await server.stop();
  });

  String apiOf(String family) => '${server.baseUrl}/cathttp/$family';

  /// 三族共用的完整链路：home / search / play。
  List<CatHttpCall> fullChain(String api) {
    final builder = CatHttpRequestBuilder(api: api);
    return [
      builder.build(CatHttpRoute.home),
      builder.build(CatHttpRoute.search, keyword: '样本', page: 1),
      builder.build(CatHttpRoute.play, vodId: 'cat-1', flag: 'cat'),
    ];
  }

  // ---------------------------------------------------------------------------
  // 门禁：三族样本各走完整 home/search/play（§9.4）
  // ---------------------------------------------------------------------------
  group('CatSpider HTTP 三族样本（§9.4 门禁）', () {
    test('样本 A 成功：home/search/play 均返回结构化 Result', () async {
      final builder = CatHttpRequestBuilder(api: apiOf('ok'));

      final home = await client.call(
        builder.build(CatHttpRoute.home),
        siteKey: 'cat-ok',
      );
      expect(home.classes, isNotEmpty);
      expect(home.classes.first.typeName, '电影');
      expect(home.list, isNotEmpty);
      expect(home.list.first.vodId, 'cat-1');

      final search = await client.call(
        builder.build(CatHttpRoute.search, keyword: '样本', page: 1),
        siteKey: 'cat-ok',
      );
      expect(search.list, isNotEmpty);
      expect(search.list.first.vodName, '搜索结果影片');
      expect(search.page, 1);

      final play = await client.call(
        builder.build(CatHttpRoute.play, vodId: 'cat-1', flag: 'cat'),
        siteKey: 'cat-ok',
      );
      expect(play.playUrl, contains('/media/sample.m3u8'));
      expect(play.format, contains('mpegurl'));
      expect(play.header, isNotNull);
      expect(play.header!['Referer'], isNotNull);
    });

    test('样本 B 业务错误：home/search/play 一律业务错误，不空列表化', () async {
      for (final call in fullChain(apiOf('biz'))) {
        await expectLater(
          client.call(call, siteKey: 'cat-biz'),
          throwsA(
            isA<SpiderError>()
                .having((e) => e.code, 'code', SpiderErrorCode.parseError)
                .having((e) => e.message, 'message', contains('需要登录'))
                .having((e) => e.userVisible, 'userVisible', isTrue),
          ),
          reason: 'route=${call.route} 必须报业务错误而不是返回空列表',
        );
      }
    });

    test('样本 C 非 2xx：home/search/play 一律 SPIDER_HTTP_ERROR', () async {
      for (final call in fullChain(apiOf('http'))) {
        await expectLater(
          client.call(call, siteKey: 'cat-http'),
          throwsA(
            isA<SpiderError>()
                .having((e) => e.code, 'code', SpiderErrorCode.httpError)
                // 5xx 必须标记为可重试。
                .having((e) => e.retryable, 'retryable', isTrue),
          ),
          reason: 'route=${call.route} 非 2xx 不得冒充成功',
        );
      }
    });

    test('未实现路由 404 → SPIDER_UNSUPPORTED（不转空列表）', () async {
      for (final call in fullChain(apiOf('unsupported'))) {
        await expectLater(
          client.call(call, siteKey: 'cat-ns'),
          throwsA(
            isA<SpiderError>()
                .having((e) => e.code, 'code', SpiderErrorCode.unsupported),
          ),
          reason: 'route=${call.route} 的 404 必须映射为 SPIDER_UNSUPPORTED',
        );
      }
    });

    test('成功族信封形态：{code:0,data} 与顶层数组都被解包', () async {
      // `endpoint()` 会追加路由，因此这里直接把样本族当作不同的站点 base。
      final envelope = await client.call(
        CatHttpRequestBuilder(api: apiOf('envelope')).build(CatHttpRoute.home),
        siteKey: 'cat-env',
      );
      expect(envelope.list.first.vodId, 'cat-env-1');

      final array = await client.call(
        CatHttpRequestBuilder(
          api: apiOf('envelope'),
        ).build(CatHttpRoute.search, keyword: 'x'),
        siteKey: 'cat-arr',
      );
      expect(array.list.first.vodId, 'cat-arr-1');
    });

    test('page 被兜底为 1：请求发出 page=1 且记录诊断（§9.4）', () async {
      // 用运行时层（CatHttpSiteRuntime）驱动，这是 §9.4「记录诊断」的实际实现位置。
      final runtime = CatHttpSiteRuntime(client: client, siteKey: 'cat-page');
      final site = Site(
        key: 'cat-page',
        name: 'page 样本',
        type: SiteType.spider,
        api: apiOf('page'),
      );

      final result = await runtime.category(site, typeId: '1', page: 0);
      expect(result.page, 1);
      // 非法 page 必须在诊断中留痕（§9.4「page 非法值按 1 处理并记录诊断」）。
      expect(client.diagnostics, isNotEmpty);
      expect(client.diagnostics.last, contains(CatHttpRequestBuilder.pageDiagnostic));
      expect(client.diagnostics.last, contains('/category'));

      // 请求体确实被兜底为 page=1。
      final builder = CatHttpRequestBuilder(api: apiOf('page'));
      expect(builder.build(CatHttpRoute.category, page: 'bad').body['page'], 1);
    });
  });

  // ---------------------------------------------------------------------------
  // 请求构造与归一化（§9.4）
  // ---------------------------------------------------------------------------
  group('路由构造与归一化（§9.4）', () {
    test('api 末尾 / 先归一化再追加路由（不留双斜杠）', () {
      expect(
        CatHttpRequestBuilder(
          api: 'http://h:1/spider/',
        ).endpoint(CatHttpRoute.home).toString(),
        'http://h:1/spider/home',
      );
      expect(
        CatHttpRequestBuilder(
          api: 'http://h:1/spider',
        ).endpoint(CatHttpRoute.home).toString(),
        'http://h:1/spider/home',
      );
      expect(
        CatHttpRequestBuilder(
          api: 'http://h:1/spider/',
        ).endpoint(CatHttpRoute.play).toString(),
        'http://h:1/spider/play',
      );
    });

    test('请求体字段：category(id/page/filters) search(wd/page) play(flag/id)', () {
      final builder = CatHttpRequestBuilder(api: 'http://h:1/spider');
      expect(builder.build(CatHttpRoute.category, typeId: '2', page: 3).body, {
        'id': '2',
        'page': 3,
        'filters': <String, String>{},
      });
      expect(builder.build(CatHttpRoute.search, keyword: 'k', page: 2).body, {
        'wd': 'k',
        'page': 2,
      });
      expect(builder.build(CatHttpRoute.play, vodId: 'v', flag: 'f').body, {
        'flag': 'f',
        'id': 'v',
      });
      expect(builder.build(CatHttpRoute.detail, vodId: 'v').body, {'id': 'v'});
      expect(builder.build(CatHttpRoute.home).body, isEmpty);
      expect(builder.build(CatHttpRoute.init).body, isEmpty);
    });

    test('page 非法值按 1 处理并给出诊断标记', () {
      expect(CatHttpRequestBuilder.normalizePage(null), (1, true));
      expect(CatHttpRequestBuilder.normalizePage('abc'), (1, true));
      expect(CatHttpRequestBuilder.normalizePage(0), (1, true));
      expect(CatHttpRequestBuilder.normalizePage(-3), (1, true));
      expect(CatHttpRequestBuilder.normalizePage(5), (5, false));
      expect(CatHttpRequestBuilder.normalizePage('7'), (7, false));
    });

    test('api 非法（空 / 非 http(s)）抛 SPIDER_BAD_REQUEST', () {
      for (final api in ['', '   ', 'ftp://h/', 'file:///etc/passwd', 'not a url']) {
        expect(
          () => CatHttpRequestBuilder(api: api).endpoint(CatHttpRoute.home),
          throwsA(
            isA<SpiderError>()
                .having((e) => e.code, 'code', SpiderErrorCode.badRequest),
          ),
          reason: 'api="$api" 必须被拒绝',
        );
      }
    });

    test('默认注入 Content-Type 与 User-Agent', () {
      final builder = CatHttpRequestBuilder(api: 'http://h:1/spider');
      final headers = builder.headersFor(builder.endpoint(CatHttpRoute.home));
      expect(headers['Content-Type'], 'application/json; charset=utf-8');
      expect(headers['User-Agent'], HttpApiRequestBuilder.defaultUserAgent);
    });

    test('所有路由都在 §9.4 定义的方法集内', () {
      expect(CatHttpRoute.all, containsAll(const [
        '/init',
        '/home',
        '/category',
        '/detail',
        '/search',
        '/play',
      ]));
    });
  });

  // ---------------------------------------------------------------------------
  // 响应解包边界（§9.4）
  // ---------------------------------------------------------------------------
  group('响应解包边界（§9.4）', () {
    test('空响应与非 JSON → SPIDER_PARSE_ERROR', () {
      for (final body in ['', '   ', '<html>error</html>', '{oops']) {
        expect(
          () => client.decode(body, siteKey: 's', route: CatHttpRoute.home),
          throwsA(
            isA<SpiderError>()
                .having((e) => e.code, 'code', SpiderErrorCode.parseError),
          ),
          reason: 'body="$body" 不得被当作成功响应',
        );
      }
    });

    test('{code:0,data:null} → 空 Result；非 0 code → 业务错误', () {
      final empty = client.decode(
        '{"code":0,"data":null}',
        siteKey: 's',
        route: CatHttpRoute.home,
      );
      expect(empty.list, isEmpty);

      expect(
        () => client.decode(
          '{"code":7,"msg":"bad"}',
          siteKey: 's',
          route: CatHttpRoute.home,
        ),
        throwsA(
          isA<SpiderError>().having((e) => e.message, 'message', contains('bad')),
        ),
      );
    });

    test('{code:0,data:[...]} 被包装为 list', () {
      final result = client.decode(
        '{"code":0,"data":[{"vod_id":"x","vod_name":"X"}]}',
        siteKey: 's',
        route: CatHttpRoute.search,
      );
      expect(result.list.single.vodId, 'x');
    });

    test('平铺 {list:[...]} 与 {url:...} 播放结果直接解析', () {
      final flat = client.decode(
        '{"list":[{"vod_id":"y","vod_name":"Y"}]}',
        siteKey: 's',
        route: CatHttpRoute.home,
      );
      expect(flat.list.single.vodId, 'y');

      final play = client.decode(
        '{"url":"http://h/a.m3u8","flag":"f"}',
        siteKey: 's',
        route: CatHttpRoute.play,
      );
      expect(play.playUrl, 'http://h/a.m3u8');
    });
  });

  // ---------------------------------------------------------------------------
  // 运行时绑定与能力判定（§9.4 第 6 条、§8.1）
  // ---------------------------------------------------------------------------
  group('运行时绑定与能力判定（§9.4、§8.1）', () {
    Site spider(String api, {String? jar}) => Site(
      key: 'k',
      name: 'n',
      type: SiteType.spider,
      api: api,
      jar: jar,
    );

    test('spider_router 把 /spider/ 形态判为可用（MVP-B CatSpider HTTP）', () {
      for (final api in ['http://h:1/spider/', 'http://h:1/spider']) {
        final availability = SpiderRouter.classify(spider(api));
        expect(availability.available, isTrue, reason: api);
        expect(availability.runtimeName, contains('CatSpider HTTP'));
      }
    });

    test('JS/Python/CSP/JAR 形态仍判为不可用（Phase 3，不伪装成功）', () {
      // `.js`/`.py`/`csp_` 是比 `/spider/` 片段更强的信号（§8.1）。
      for (final api in [
        'http://h:1/spider/a.js',
        'http://h:1/spider/a.py',
        'http://h:1/csp_xxx',
      ]) {
        final availability = SpiderRouter.classify(
          Site(key: 'k', name: 'n', type: SiteType.spider, api: api),
        );
        expect(
          availability.available,
          isFalse,
          reason: '$api 不得被 /spider/ 片段误判为 CatSpider HTTP',
        );
      }

      // Android/JAR 形态：由站点 `jar` 字段声明（§9.9）。
      final jar = SpiderRouter.classify(
        Site(
          key: 'k',
          name: 'n',
          type: SiteType.spider,
          api: 'http://h:1/api.php',
          jar: 'a.jar',
        ),
      );
      expect(jar.available, isFalse);
    });

    test('CatHttpRuntime.looksLikeCatHttp 只认 /spider/ 与 catspider', () {
      expect(CatHttpRuntime.looksLikeCatHttp(spider('http://h/spider/')), isTrue);
      expect(CatHttpRuntime.looksLikeCatHttp(spider('http://h/spider')), isTrue);
      expect(CatHttpRuntime.looksLikeCatHttp(spider('http://catspider.h/')), isTrue);
      expect(CatHttpRuntime.looksLikeCatHttp(spider('http://h/api.php')), isFalse);
      expect(
        CatHttpRuntime.looksLikeCatHttp(spider('http://h/spider/a.js')),
        isFalse,
        reason: '.js 必须判为独立运行时，而不是 cat http',
      );
    });
  });
}
