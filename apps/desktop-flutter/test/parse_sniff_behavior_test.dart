/// 解析层对齐安卓的嗅探行为测试（`type=0` Web 嗅探、`type=4` Super、
/// `json:`/`parse:<名称>` 前缀）。
///
/// 纪律：断言的是**解析层的行为**（请求参数、竞速胜负、会话一定被停止），
/// 不是假引擎的内部逻辑。假引擎只复述 `lib/core/sniff/sniff_types.dart` 的契约。
///
/// 超时用构造参数缩短（默认即安卓常量 30s / 90s / 25s），否则用例会真的等 90 秒。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/core/http_api.dart';
import 'package:webhtv_pc/core/parse_failover.dart';
import 'package:webhtv_pc/core/parse_runtime.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/sniff/sniff_engine_factory.dart';
import 'package:webhtv_pc/core/sniff/sniff_types.dart';
import 'package:webhtv_pc/services/parse_service.dart';
import 'package:webhtv_pc/services/site_service.dart';
import 'package:webhtv_pc/services/spider_router.dart';

import 'support/sniff_fakes.dart';
import 'support/test_fixture_server.dart';

const _mediaUrl = 'https://cdn.test/v.m3u8';

ParseEntry _web(String url, {String name = 'web', Object? ext}) =>
    ParseEntry(name: name, type: 0, url: url, ext: ext);

ParseEntry _json(String url, {String name = 't1'}) =>
    ParseEntry(name: name, type: 1, url: url);

ParseSelection _selectionOf(List<ParseEntry> entries, {String? preferName}) =>
    ParseRuntime.select(entries, preferName: preferName);

/// 让被 `unawaited` 的竞速分支跑完（取消是异步的）。
Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 60));

Matcher _throwsKind(AppErrorKind kind) =>
    throwsA(isA<AppError>().having((error) => error.kind, 'kind', kind));

void main() {
  group('type=0 Web 嗅探', () {
    test('成功：解析器url 拼目标后打开，候选地址与请求头归一化返回', () async {
      final engine = FakeSniffEngine.success(
        _mediaUrl,
        headers: {'referer': 'https://site.test/', 'user-agent': 'UA-X'},
      );
      final service = ParseService(sniffEngine: engine);
      addTearDown(service.close);

      final result = await service.run(
        selection: _selectionOf([_web('https://jx.test/sniff?u=')]),
        entries: const [],
        webUrl: 'https://v.qq.com/x/cover/abc',
      );

      expect(result.url, _mediaUrl);
      expect(result.parseKind, ParseKind.webSniff);
      expect(result.entryName, 'web');
      // 只保留 UA/Referer/Cookie 三类（§12.3 不落完整 Cookie/Token），且键规范化。
      expect(result.headers, {
        'Referer': 'https://site.test/',
        'User-Agent': 'UA-X',
      });
      final request = engine.requests.single;
      expect(
        request.pageUrl,
        'https://jx.test/sniff?u=https://v.qq.com/x/cover/abc',
      );
      expect(request.timeout, SniffTimeouts.parseWeb);
      expect(request.source, 'parse:web');
      expect(request.headers, isEmpty);
      expect(request.clickScript, isNull);
      expect(request.rules, isEmpty);
      expect(request.revealWindow, isTrue);
      // §12.3：成功路径也必须停会话。
      expect(engine.sessions.single.stopCount, 1);
    });

    test('解析器 ext.header（UA/Referer/Cookie）落到 SniffRequest.headers', () async {
      final engine = FakeSniffEngine.success(_mediaUrl);
      final service = ParseService(sniffEngine: engine);
      addTearDown(service.close);

      await service.run(
        selection: _selectionOf([
          _web(
            'https://jx.test/p?u=',
            ext: {
              'header': {
                'User-Agent': 'Mobile-UA',
                'Referer': 'https://v.qq.com/',
              },
            },
          ),
        ]),
        entries: const [],
        webUrl: 'https://v.qq.com/x/cover/abc',
      );

      expect(engine.requests.single.headers, {
        'User-Agent': 'Mobile-UA',
        'Referer': 'https://v.qq.com/',
      });
    });

    test('站点 click 与 config.rules 透传给嗅探请求', () async {
      final engine = FakeSniffEngine.success(_mediaUrl);
      final service = ParseService(sniffEngine: engine);
      addTearDown(service.close);

      await service.runWithFallback(
        selection: _selectionOf([_web('https://jx.test/p?u=')]),
        entries: const [],
        webUrl: 'https://v.qq.com/x/cover/abc',
        sniffClick: 'document.querySelector("video").click()',
        sniffRules: [
          {
            'hosts': ['jx.test'],
            'regex': [r'\.m3u8'],
            'exclude': ['/ad/'],
            'script': ['window.__play()'],
          },
        ],
      );

      final request = engine.requests.single;
      expect(request.clickScript, 'document.querySelector("video").click()');
      expect(request.rules.single.hosts, ['jx.test']);
      expect(request.rules.single.regexes, [r'\.m3u8']);
      expect(request.rules.single.excludes, ['/ad/']);
      expect(request.rules.single.scripts, ['window.__play()']);
    });

    test('超时 → parseSniffTimeout，且会话一定被停止', () async {
      // 事件被延迟 30s 才发出：解析层必须在自己的上限内结束，不能等引擎。
      final engine = FakeSniffEngine(
        delay: const Duration(seconds: 30),
        script: (_) => const [SniffCandidate(url: _mediaUrl)],
      );
      final service = ParseService(
        sniffEngine: engine,
        webSniffTimeout: const Duration(milliseconds: 60),
      );
      addTearDown(service.close);

      await expectLater(
        service.run(
          selection: _selectionOf([_web('https://jx.test/p?u=')]),
          entries: const [],
          webUrl: 'https://v.qq.com/x/cover/abc',
        ),
        _throwsKind(AppErrorKind.parseSniffTimeout),
      );
      expect(engine.sessions.single.stopCount, 1);
    });

    test('解析页没有任何候选就结束 → parseInvalid，且会话被停止', () async {
      final engine = FakeSniffEngine.hanging();
      final service = ParseService(sniffEngine: engine);
      addTearDown(service.close);

      await expectLater(
        service.run(
          selection: _selectionOf([_web('https://jx.test/p?u=')]),
          entries: const [],
          webUrl: 'https://v.qq.com/x/cover/abc',
        ),
        _throwsKind(AppErrorKind.parseInvalid),
      );
      expect(engine.sessions.single.stopCount, 1);
    });

    test('解析页报错 → parseInvalid，仍停止会话', () async {
      final engine = FakeSniffEngine(
        script: (_) => const [SniffFailed(message: '页面崩溃', detail: 'crash')],
      );
      final service = ParseService(sniffEngine: engine);
      addTearDown(service.close);

      await expectLater(
        service.run(
          selection: _selectionOf([_web('https://jx.test/p?u=')]),
          entries: const [],
          webUrl: 'https://v.qq.com/x/cover/abc',
        ),
        _throwsKind(AppErrorKind.parseInvalid),
      );
      expect(engine.sessions.single.stopCount, 1);
    });

    test('人机校验后继续等：reveal 一次后仍拿到候选', () async {
      final engine = FakeSniffEngine(
        script: (_) => const [
          SniffChallenge(reason: 'cloudflare'),
          SniffCandidate(url: _mediaUrl),
        ],
      );
      final service = ParseService(sniffEngine: engine);
      addTearDown(service.close);

      final result = await service.run(
        selection: _selectionOf([_web('https://jx.test/p?u=')]),
        entries: const [],
        webUrl: 'https://v.qq.com/x/cover/abc',
      );

      expect(result.url, _mediaUrl);
      expect(engine.sessions.single.revealCount, 1);
      expect(engine.sessions.single.stopCount, 1);
    });

    test('不允许弹窗时遇人机校验 → parseSniffChallenge', () async {
      final engine = FakeSniffEngine(
        script: (_) => const [
          SniffChallenge(reason: 'cloudflare'),
          SniffCandidate(url: _mediaUrl),
        ],
      );
      final service = ParseService(sniffEngine: engine);
      addTearDown(service.close);

      await expectLater(
        service.runWithFallback(
          selection: _selectionOf([_web('https://jx.test/p?u=')]),
          entries: const [],
          webUrl: 'https://v.qq.com/x/cover/abc',
          revealWindow: false,
        ),
        _throwsKind(AppErrorKind.parseSniffChallenge),
      );
      expect(engine.sessions.single.revealCount, 0);
      expect(engine.sessions.single.stopCount, 1);
    });

    test('无头会话遇人机校验 → 立刻 parseSniffChallenge（不硬等到超时）', () async {
      final engine = FakeSniffEngine(
        sessionCanReveal: false,
        script: (_) => const [
          SniffChallenge(reason: 'cloudflare'),
          SniffCandidate(url: _mediaUrl),
        ],
      );
      final service = ParseService(sniffEngine: engine);
      addTearDown(service.close);

      final stopwatch = Stopwatch()..start();
      await expectLater(
        service.run(
          selection: _selectionOf([_web('https://jx.test/p?u=')]),
          entries: const [],
          webUrl: 'https://v.qq.com/x/cover/abc',
        ),
        _throwsKind(AppErrorKind.parseSniffChallenge),
      );
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)),
          reason: '不能把能力缺失伪装成 180s 超时');
      expect(engine.sessions.single.revealCount, 0);
      expect(engine.sessions.single.stopCount, 1);
    });

    test('嗅探超时默认 180s（Super 180s / 单次 Web 60s / JSON 15s 不变）', () {
      expect(SniffTimeouts.parseWeb, const Duration(seconds: 180));
      expect(SniffTimeouts.parseSuper, const Duration(seconds: 180));
      expect(SniffTimeouts.superWebAttempt, const Duration(seconds: 60));
      expect(SniffTimeouts.parseDefault, const Duration(seconds: 15));
      final service = ParseService();
      addTearDown(service.close);
      expect(service.webSniffTimeout, SniffTimeouts.parseWeb);
      expect(service.superParseTimeout, SniffTimeouts.parseSuper);
      expect(service.superWebAttemptTimeout, SniffTimeouts.superWebAttempt);
      expect(service.jsonParseTimeout, SniffTimeouts.parseDefault);
    });

    test('本机没有嗅探引擎 → parseSniffUnavailable（不静默降级）', () async {
      installSharedSniffEngine(null);
      addTearDown(resetSharedSniffEngine);
      final service = ParseService();
      addTearDown(service.close);

      await expectLater(
        service.run(
          selection: _selectionOf([_web('https://jx.test/p?u=')]),
          entries: const [],
          webUrl: 'https://v.qq.com/x/cover/abc',
        ),
        _throwsKind(AppErrorKind.parseSniffUnavailable),
      );
    });

    test('引擎启动即报不可用 → parseSniffUnavailable', () async {
      final service = ParseService(
        sniffEngine: FakeSniffEngine.unavailable(message: '没有可用的浏览器内核'),
      );
      addTearDown(service.close);

      await expectLater(
        service.run(
          selection: _selectionOf([_web('https://jx.test/p?u=')]),
          entries: const [],
          webUrl: 'https://v.qq.com/x/cover/abc',
        ),
        _throwsKind(AppErrorKind.parseSniffUnavailable),
      );
    });

    test('嗅探不是解析失败：解析器不可用仍属解析类错误（可换源）', () {
      expect(
        isParseError(AppError(AppErrorKind.parseSniffUnavailable, 'x')),
        isTrue,
      );
      expect(
        isParseError(AppError(AppErrorKind.parseSniffTimeout, 'x')),
        isTrue,
      );
      expect(
        isParseError(AppError(AppErrorKind.parseSniffChallenge, 'x')),
        isTrue,
      );
    });
  });

  group('type=4 Super', () {
    late TestFixtureServer server;

    setUp(() async {
      server = await TestFixtureServer.start();
    });

    tearDown(() async {
      await server.stop();
    });

    ParseService withService(SniffEngine engine) => ParseService(
      sniffEngine: engine,
      superWebAttemptTimeout: const Duration(milliseconds: 80),
      superParseTimeout: const Duration(seconds: 2),
    );

    test('web 腿先成功：type=1 失败不判整体失败（安卓 fatal=false）', () async {
      final engine = FakeSniffEngine.success(_mediaUrl);
      final service = withService(engine);
      addTearDown(service.close);
      final entries = [
        const ParseEntry(name: 'god', type: 4),
        _json('http://127.0.0.1:9/parse', name: '坏JSON'),
        _web('https://jx.test/p?u='),
      ];

      final result = await service.run(
        selection: _selectionOf(entries),
        entries: entries,
        webUrl: 'https://v.qq.com/x/cover/abc',
      );

      expect(result.parseKind, ParseKind.webSniff);
      expect(result.entryName, 'web');
      expect(result.url, _mediaUrl);
    });

    test('json 腿先成功：胜出后取消在跑的 web 腿（会话被停止）', () async {
      final engine = FakeSniffEngine(
        delay: const Duration(seconds: 5),
        script: (_) => const [
          SniffCandidate(url: 'https://cdn.test/slow.m3u8'),
        ],
      );
      final service = withService(engine);
      addTearDown(service.close);
      final entries = [
        const ParseEntry(name: 'god', type: 4),
        _json('${server.baseUrl}/api/parse/type1'),
        _web('https://jx.test/p?u='),
      ];

      final result = await service.run(
        selection: _selectionOf(entries),
        entries: entries,
        webUrl: '/ep1',
      );

      expect(result.parseKind, ParseKind.json);
      expect(result.entryName, 't1');
      expect(result.url, '${server.baseUrl}/media/sample.mp4');
      await _settle();
      expect(engine.sessions, hasLength(1));
      expect(engine.sessions.single.stopCount, 1);
    });

    test('web 腿按优先级尝试：xmflv 失败后换 hls.one，其它排最后', () async {
      final engine = FakeSniffEngine(
        script: (request) => request.pageUrl.contains('xmflv.com')
            ? const [SniffFailed(message: 'xmflv 失败')]
            : const [SniffCandidate(url: _mediaUrl)],
      );
      final service = withService(engine);
      addTearDown(service.close);
      final entries = [
        const ParseEntry(name: 'god', type: 4),
        _web('https://m3u8.tv/p?u=', name: 'tv'),
        _web('https://hls.one/p?u=', name: 'hls'),
        _web('https://xmflv.com/p?u=', name: 'xm'),
      ];

      final result = await service.run(
        selection: _selectionOf(entries),
        entries: entries,
        webUrl: 'https://v.qq.com/x/cover/abc',
      );

      expect(result.entryName, 'hls');
      expect(engine.requests.map((request) => request.source), [
        'parse:xm',
        'parse:hls',
      ]);
      // 失败的那条也必须停会话，成功的那条同样。
      expect(engine.sessions.map((session) => session.stopCount), [1, 1]);
    });

    test('全部失败 → 抛出解析错误（不伪装成功）', () async {
      final engine = FakeSniffEngine(
        script: (_) => const [SniffFailed(message: '页面失败')],
      );
      final service = withService(engine);
      addTearDown(service.close);
      final entries = [
        const ParseEntry(name: 'god', type: 4),
        _json('http://127.0.0.1:9/parse', name: '坏JSON'),
        _web('https://jx.test/p?u='),
      ];

      Object? caught;
      try {
        await service.run(
          selection: _selectionOf(entries),
          entries: entries,
          webUrl: 'https://v.qq.com/x/cover/abc',
        );
        fail('应当抛出');
      } catch (error) {
        caught = error;
      }
      expect(isParseError(caught), isTrue, reason: '实际：$caught');
      expect(engine.sessions.single.stopCount, 1);
    });

    test('解析器数量为 0 → parseEmpty', () async {
      final service = withService(FakeSniffEngine.success(_mediaUrl));
      addTearDown(service.close);
      final entries = [const ParseEntry(name: 'god', type: 4)];

      await expectLater(
        service.run(
          selection: _selectionOf(entries),
          entries: entries,
          webUrl: 'https://v.qq.com/x/cover/abc',
        ),
        _throwsKind(AppErrorKind.parseEmpty),
      );
    });

    test('目标解嵌：解析器套解析器时只把真正的播放页交给解析器', () async {
      final engine = FakeSniffEngine.success(_mediaUrl);
      final service = withService(engine);
      addTearDown(service.close);
      final entries = [
        const ParseEntry(name: 'god', type: 4),
        _web('https://bd.jx.cn/parse?url='),
      ];
      const target =
          'https://bd.jx.cn/?url=https%3A%2F%2Fv.qq.com%2Fx%2Fcover%2Fabc';

      await service.run(
        selection: _selectionOf(entries),
        entries: entries,
        webUrl: target,
      );

      final pageUrl = engine.requests.single.pageUrl;
      expect(
        pageUrl,
        'https://bd.jx.cn/parse?url=https://v.qq.com/x/cover/abc',
      );
      expect(pageUrl.contains('%3A%2F%2F'), isFalse);
    });

    test('整体超时 → parseSniffTimeout', () async {
      final engine = FakeSniffEngine(
        delay: const Duration(seconds: 5),
        script: (_) => const [SniffCandidate(url: _mediaUrl)],
      );
      final service = ParseService(
        sniffEngine: engine,
        superWebAttemptTimeout: const Duration(seconds: 5),
        superParseTimeout: const Duration(milliseconds: 80),
      );
      addTearDown(service.close);
      final entries = [
        const ParseEntry(name: 'god', type: 4),
        _web('https://jx.test/p?u='),
      ];

      await expectLater(
        service.run(
          selection: _selectionOf(entries),
          entries: entries,
          webUrl: 'https://v.qq.com/x/cover/abc',
        ),
        _throwsKind(AppErrorKind.parseSniffTimeout),
      );
      await _settle();
      expect(engine.sessions.single.stopCount, 1);
    });
  });

  group('Super 目标解嵌（unwrapSuperParseUrl）', () {
    final webs = [
      const ParseEntry(name: 'jx', type: 0, url: 'https://bd.jx.cn/parse?url='),
    ];

    test('host 属于已知解析器 → 解出 url= 里的地址', () {
      expect(
        unwrapSuperParseUrl(
          'https://bd.jx.cn/?url=https%3A%2F%2Fv.qq.com%2Fx%2Fcover%2Fabc',
          webs,
        ),
        'https://v.qq.com/x/cover/abc',
      );
    });

    test('路径像解析入口（/api、jiexi、/jx）也解', () {
      expect(
        unwrapSuperParseUrl(
          'https://other.test/api?url=https%3A%2F%2Fv.qq.com%2Fa',
          webs,
        ),
        'https://v.qq.com/a',
      );
      expect(
        unwrapSuperParseUrl(
          'https://other.test/jiexi?jx=https%3A%2F%2Fv.qq.com%2Fb',
          webs,
        ),
        'https://v.qq.com/b',
      );
    });

    test('最多解 4 层', () {
      const deep =
          'https://bd.jx.cn/?url=https://bd.jx.cn/?url=https://bd.jx.cn/?url='
          'https://bd.jx.cn/?url=https://bd.jx.cn/?url=https://v.qq.com/deep';
      final unwrapped = unwrapSuperParseUrl(deep, webs);
      expect(unwrapped.startsWith('https://bd.jx.cn/'), isTrue);
      expect(unwrapped, isNot('https://v.qq.com/deep'));
    });

    test('普通播放页不受影响（不解普通站点的 url= 参数）', () {
      const page = 'https://v.qq.com/x/cover/abc?url=https://other.test/x';
      expect(unwrapSuperParseUrl(page, webs), page);
    });
  });

  group('json: / parse:<名称> 前缀（对齐 ParseJob.setParse）', () {
    late TestFixtureServer server;
    late ParseService service;

    setUp(() async {
      server = await TestFixtureServer.start();
      service = ParseService();
    });

    tearDown(() async {
      service.close();
      await server.stop();
    });

    test('json: 余下部分当作 type=1 解析接口，目标是剧集自身地址', () async {
      final spec = resolveParseTarget(
        target: 'json:${server.baseUrl}/api/parse/type1',
        targetSuffix: '/ep1',
        parses: const [],
        flag: null,
      );

      expect(spec.selection.kind, ParseKind.json);
      expect(spec.selection.entry.type, 1);
      expect(spec.selection.entry.url, '${server.baseUrl}/api/parse/type1');
      expect(spec.webUrl, '/ep1');

      final result = await service.run(
        selection: spec.selection,
        entries: const [],
        webUrl: spec.webUrl,
      );
      expect(result.url, '${server.baseUrl}/media/sample.mp4');
      final request = server.captured.lastWhere(
        (item) => item.path.startsWith('/api/parse/type1'),
      );
      expect(request.path, '/api/parse/type1/ep1');
    });

    test('json: 前缀经站点服务直达解析器（不再被「目标不是直链」拒绝）', () async {
      final config = AppConfig(
        name: '前缀闭环',
        sites: [
          Site(
            key: 'prefix-site',
            name: '前缀站点',
            type: 1,
            api: '${server.baseUrl}/api/type1/',
          ),
        ],
        parses: [
          ParseEntry(
            name: 'Fixture 解析器',
            type: 1,
            url: '${server.baseUrl}/api/parse/type1',
          ),
        ],
      );
      final router = SpiderRouter(
        client: HttpApiClient(),
        globalHeaders: const [],
      );
      addTearDown(router.dispose);
      final siteService = SiteService(appConfig: config, router: router);

      final outcome = await siteService.resolvePlayback(
        site: config.sites.first,
        episodeTarget: 'json:${server.baseUrl}/api/parse/type1',
        parseService: service,
      );

      // 前缀命中 → 解析器返回的媒体地址成为最终可播放决策（不是「不是直链」错误）。
      expect(outcome.value.action, PlaybackAction.direct);
      expect(outcome.value.url, '${server.baseUrl}/media/sample.mp4');
      expect(outcome.value.reason, contains('parsed-by'));
    });

    test('前缀识别：只有 json:/parse: 开头才算（普通 url 不受影响）', () {
      expect(isParsePrefixedTarget('json:https://jx.test/?url='), isTrue);
      expect(isParsePrefixedTarget('parse:虾米'), isTrue);
      expect(isParsePrefixedTarget('  json:https://jx.test/'), isTrue);
      expect(isParsePrefixedTarget('https://v.qq.com/x/cover/abc'), isFalse);
      expect(isParsePrefixedTarget('magnet:?xt=urn:btih:x'), isFalse);
      expect(isParsePrefixedTarget(''), isFalse);
    });

    test('parse:<名称> 用指定名称覆盖默认选择', () {
      final parses = [
        _json('https://a.test/parse', name: 'A'),
        const ParseEntry(name: 'B', type: 3, url: 'https://b.test/parse'),
      ];
      final spec = resolveParseTarget(
        target: 'parse:B',
        targetSuffix: 'https://v.qq.com/x/cover/abc',
        parses: parses,
        flag: null,
      );

      expect(spec.selection.entry.name, 'B');
      expect(spec.selection.kind, ParseKind.jsonMix);
      expect(spec.webUrl, 'https://v.qq.com/x/cover/abc');
    });

    test('parse:<名称> 指向不存在的解析器 → parseInvalid（可诊断）', () {
      final parses = [_json('https://a.test/parse', name: 'A')];
      expect(
        () =>
            resolveParseTarget(target: 'parse:不存在', parses: parses, flag: null),
        throwsA(
          isA<AppError>()
              .having((error) => error.kind, 'kind', AppErrorKind.parseInvalid)
              .having((error) => error.message, 'message', contains('不存在'))
              .having((error) => error.detail, 'detail', contains('A')),
        ),
      );
    });

    test('无前缀：按 flag 选择解析器，目标就是剧集地址本身', () {
      final parses = [
        _json('https://a.test/parse', name: 'A'),
        ParseEntry(
          name: 'B',
          type: 1,
          url: 'https://b.test/parse',
          ext: {
            'flag': ['qq'],
          },
        ),
      ];
      final spec = resolveParseTarget(
        target: 'https://v.qq.com/x/cover/abc',
        parses: parses,
        flag: 'qq',
      );

      expect(spec.selection.entry.name, 'B');
      expect(spec.webUrl, 'https://v.qq.com/x/cover/abc');
    });

    test('type=0/4 现在可选：配置第一条是嗅探时默认选中它', () {
      final selection = _selectionOf([
        _web('https://jx.test/p?u='),
        _json('https://a.test/parse'),
      ]);
      expect(selection.kind, ParseKind.webSniff);
    });
  });

  group('站点 click / 结果 click 取值顺序（安卓 ParseJob.getClick）', () {
    Site clickSite({String? siteClick}) => Site(
      key: 'click-site',
      name: 'click 站点',
      type: 4,
      api: 'https://gateway.test/api',
      extra: siteClick == null ? const {} : {'click': siteClick},
    );

    Future<List<String?>> playClicks(Site site) async {
      final parser = _ClickCaptureParseService();
      addTearDown(parser.close);
      final router = SpiderRouter(
        globalHeaders: const [],
        client: HttpApiClient(
          client: MockClient(
            (_) async => http.Response(
              jsonEncode({
                'parse': 1,
                'url': _mediaUrl,
                'click': 'resultClick()',
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            ),
          ),
        ),
      );
      addTearDown(router.dispose);
      final service = SiteService(
        appConfig: AppConfig(
          sites: [site],
          parses: [
            ParseEntry(name: 'json', type: 1, url: 'https://parser.test/?url='),
          ],
        ),
        router: router,
      );
      final decision = (await service.resolvePlayback(
        site: site,
        episodeTarget: 'ep-1',
        parseService: parser,
      )).value;
      expect(decision.action, PlaybackAction.direct);
      expect(decision.url, _mediaUrl);
      return parser.sniffClicks;
    }

    test('站点 click 优先于结果 click', () async {
      final clicks = await playClicks(clickSite(siteClick: 'siteClick()'));
      expect(clicks, ['siteClick()']);
    });

    test('站点没有 click 时用结果 click', () async {
      final clicks = await playClicks(clickSite());
      expect(clicks, ['resultClick()']);
    });
  });

  group('站点 playUrl 前缀 → 解析目标（§7.4.8、安卓 VodApi:185）', () {
    test('前缀 + 非媒体结果：解析器拿到的 webUrl 是拼接后的地址', () async {
      final site = Site(
        key: 'prefix-site',
        name: '前缀站点',
        type: SiteType.jsonApi,
        api: 'https://api.test/api.php/provide/vod/',
        extra: {'playUrl': '/jx.php?url='},
      );
      final parser = _ClickCaptureParseService();
      addTearDown(parser.close);
      final router = SpiderRouter(
        globalHeaders: const [],
        client: HttpApiClient(
          client: MockClient((request) async {
            fail('普通 HTTP API 站点不应先请求播放入口：${request.url}');
          }),
        ),
      );
      addTearDown(router.dispose);
      final service = SiteService(
        appConfig: AppConfig(
          sites: [site],
          parses: [
            ParseEntry(name: 'json', type: 1, url: 'https://parser.test/?url='),
          ],
        ),
        router: router,
      );
      final decision = (await service.resolvePlayback(
        site: site,
        episodeTarget: 'abc123',
        parseService: parser,
      )).value;
      expect(decision.action, PlaybackAction.direct);
      expect(parser.webUrls, ['/jx.php?url=abc123']);
    });

    test('没有配置解析器时选择失败 → AppError（不把 ParseSelectionException 泄漏给上层）', () async {
      final site = Site(
        key: 'prefix-site',
        name: '前缀站点',
        type: SiteType.jsonApi,
        api: 'https://api.test/api.php/provide/vod/',
        extra: {'playUrl': '/jx.php?url='},
      );
      final router = SpiderRouter(
        globalHeaders: const [],
        client: HttpApiClient(
          client: MockClient((request) async {
            fail('普通 HTTP API 站点不应先请求播放入口：${request.url}');
          }),
        ),
      );
      addTearDown(router.dispose);
      final service = SiteService(
        appConfig: AppConfig(sites: [site], parses: const []),
        router: router,
      );
      await expectLater(
        () => service.resolvePlayback(site: site, episodeTarget: 'abc123'),
        throwsA(
          isA<AppError>()
              .having((error) => error.kind, 'kind', AppErrorKind.parseInvalid)
              .having(
                (error) => error.message,
                'message',
                contains('解析器'),
              ),
        ),
      );
    });
  });

  group('解析轨迹日志（源名 / 连接 / 结果）', () {
    late List<String> trace;
    late List<String> verbose;

    setUp(() {
      trace = [];
      verbose = [];
      installParseTrace(trace: trace.add, verbose: verbose.add);
    });

    tearDown(() {
      // 全局 sink 必须复位：否则会把后面用例的日志写进本用例的列表。
      installParseTrace();
    });

    test('JSON 解析成功：记录源名、解析接口连接、目标与产出地址', () async {
      final service = ParseService(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({'url': _mediaUrl}),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ),
        ),
      );
      addTearDown(service.close);

      await service.run(
        selection: _selectionOf([_json('https://p.test/?url=')]),
        entries: const [],
        webUrl: 'https://v.test/1?token=secret',
      );

      final start = trace.firstWhere((line) => line.startsWith('解析源='));
      expect(start, contains('源=${_json('x').name}'), reason: '必须能看出用的哪个解析源');
      expect(start, contains('type=1'));
      expect(start, contains('连接=https://p.test/'), reason: '解析接口地址要打出来');
      expect(start, contains('目标=https://v.test/1'), reason: '目标地址要打出来');
      expect(start, isNot(contains('token=secret')), reason: '查询串按既有口径脱敏');

      final done = trace.firstWhere((line) => line.startsWith('解析成功'));
      expect(done, contains('地址=https://cdn.test/v.m3u8'), reason: '结果地址要打出来');
      expect(done, contains('耗时='));

      expect(
        verbose.any((line) => line.startsWith('HTTP 200')),
        isTrue,
        reason: '状态码与字节数属于细节层，受详细调试日志开关控制',
      );
    });

    test('JSON 解析失败：记录失败类别与原因（可据此判断是站点挂了还是没地址）', () async {
      final service = ParseService(
        client: MockClient(
          (_) async => http.Response('<html>nope</html>', 200),
        ),
      );
      addTearDown(service.close);

      await expectLater(
        service.run(
          selection: _selectionOf([_json('https://p.test/?url=')]),
          entries: const [],
          webUrl: 'https://v.test/1',
        ),
        _throwsKind(AppErrorKind.parseInvalid),
      );

      final failed = trace.firstWhere((line) => line.startsWith('解析失败'));
      expect(failed, contains('kind=parseInvalid'));
      // 解析失败不影响直接换源（§12.3）：失败原因必须留在日志里。
      expect(failed, contains('响应不是 JSON'));
    });

    test('Web 嗅探：记录页面地址、命中途径与结果；类型与无头模式可辨', () async {
      final engine = FakeSniffEngine.success(_mediaUrl);
      final service = ParseService(sniffEngine: engine);
      addTearDown(service.close);

      await service.run(
        selection: _selectionOf([_web('https://jx.test/s?u=')]),
        entries: const [],
        webUrl: 'https://v.test/1',
      );

      final traceLine = trace.firstWhere((line) => line.startsWith('解析源='));
      expect(traceLine, contains('type=0'));
      expect(traceLine, contains('连接=https://jx.test/s'));

      final sniff = verbose.firstWhere((line) => line.startsWith('嗅探 '));
      expect(sniff, contains('页面=https://jx.test/s?'));
      expect(sniff, contains('超时=180s'), reason: '实际预算要能核对');
      expect(sniff, contains('无头='));

      final hit = verbose.firstWhere((line) => line.startsWith('嗅探命中'));
      expect(hit, contains('via=network'));
      expect(hit, contains('地址=https://cdn.test/v.m3u8'));
    });

    test('超级解析：先打全部候选腿，再打胜出的源', () async {
      final engine = FakeSniffEngine(
        script: (request) => request.pageUrl.contains('a.test')
            ? const [SniffFailed(message: '挂了')]
            : const [SniffCandidate(url: 'https://cdn.test/b.m3u8')],
      );
      final service = ParseService(sniffEngine: engine);
      addTearDown(service.close);

      final config = AppConfig(
        sites: const [],
        parses: const [
          ParseEntry(name: 'A', type: 0, url: 'https://a.test/?u='),
          ParseEntry(name: 'B', type: 0, url: 'https://b.test/?u='),
          ParseEntry(name: 'T1', type: 1, url: 'https://t1.test/?url='),
        ],
      );
      await service.run(
        selection: ParseRuntime.select(config.playbackParsers),
        entries: config.parses,
        webUrl: 'https://v.test/1',
      );

      final legs = trace.firstWhere((line) => line.startsWith('超级解析 腿'));
      expect(legs, contains('T1'), reason: 'JSON 腿要列出源名');
      expect(legs, contains('A'));
      expect(legs, contains('B'));

      final winner = trace.firstWhere((line) => line.startsWith('超级解析胜出'));
      expect(winner, contains('源=B'));
      expect(winner, contains('地址=https://cdn.test/b.m3u8'));
    });

    test('失败切换：候选链一次性打出来，便于判断为什么换源', () {
      final selections = parseFailoverSelections(
        primary: ParseSelection(
          entry: const ParseEntry(name: '首选', type: 1, url: 'https://a.test/'),
          kind: ParseKind.json,
        ),
        entries: const [
          ParseEntry(name: '首选', type: 1, url: 'https://a.test/'),
          ParseEntry(name: '备选', type: 1, url: 'https://b.test/'),
        ],
        settings: const ParseFailoverSettings(enabled: true, maxAttempts: 3),
      );
      expect(
        selections.map((selection) => selection.entry.name).toList(),
        ['备选'],
        reason: '候选链来自既有实现，日志只是把它显性化',
      );
    });
  });

  group('超级解析默认遍历（安卓 VodConfig.java:609）', () {
    test('配置列表头部合成「超级解析」，且配置原文不被污染', () {
      final config = AppConfig(
        sites: [],
        parses: [
          ParseEntry(name: '虾米', type: 0, url: 'https://jx.test/?u='),
          ParseEntry(name: 'json', type: 1, url: 'https://p.test/?u='),
        ],
      );
      expect(config.playbackParsers.first.name, superParseEntryName);
      expect(config.playbackParsers.first.type, 4);
      expect(config.playbackParsers.length, 3);
      expect(
        config.parses.length,
        2,
        reason: '合成条目只用于选择解析器，导入/导出/同步必须还是配置原文',
      );
      expect(
        ParseRuntime.select(config.playbackParsers).kind,
        ParseKind.superParse,
        reason: '没有 flag/显式选择时默认就是超级解析',
      );
      expect(parsersWithSuperParse(const []), isEmpty);
      expect(
        parsersWithSuperParse(const [
          ParseEntry(name: superParseEntryName, type: 4),
        ]).length,
        1,
        reason: '配置里已显式写了「超级解析」就不重复插入',
      );
    });

    test('默认选择超级解析 → 多个嗅探源依次尝试，第一个成功的胜出', () async {
      final engine = FakeSniffEngine(
        script: (request) => request.pageUrl.contains('a.test')
            ? const [SniffFailed(message: '这个源挂了')]
            : const [SniffCandidate(url: 'https://cdn.test/from-b.m3u8')],
      );
      final service = ParseService(sniffEngine: engine);
      addTearDown(service.close);

      final config = AppConfig(
        sites: [],
        parses: [
          ParseEntry(name: 'A', type: 0, url: 'https://a.test/?u='),
          ParseEntry(name: 'B', type: 0, url: 'https://b.test/?u='),
        ],
      );
      final selection = ParseRuntime.select(config.playbackParsers);
      final result = await service.run(
        selection: selection,
        entries: config.parses,
        webUrl: 'https://v.qq.com/x/cover/abc',
      );

      expect(result.url, 'https://cdn.test/from-b.m3u8');
      expect(
        engine.requests.map((request) => request.pageUrl).toList(),
        [
          'https://a.test/?u=https://v.qq.com/x/cover/abc',
          'https://b.test/?u=https://v.qq.com/x/cover/abc',
        ],
        reason: '按配置顺序逐个尝试，失败不中止（用户要的「遍历查找可用的」）',
      );
      expect(engine.sessions.first.stopCount, 1);
      expect(engine.sessions.last.stopCount, 1);
    });

    test('解析源切换：preferredParseName 覆盖默认的超级解析（仅本次）', () {
      final config = AppConfig(
        sites: const [],
        parses: const [
          ParseEntry(name: '虾米', type: 0, url: 'https://a.test/?u='),
          ParseEntry(name: 'B', type: 1, url: 'https://b.test/?u='),
        ],
      );
      final picked = resolveParseTarget(
        target: 'https://v.test/1',
        parses: config.playbackParsers,
        preferredParseName: '虾米',
      );
      expect(picked.selection.entry.name, '虾米');
      expect(picked.selection.kind, ParseKind.webSniff);

      final fallback = resolveParseTarget(
        target: 'https://v.test/1',
        parses: config.playbackParsers,
      );
      expect(
        fallback.selection.kind,
        ParseKind.superParse,
        reason: '没指定解析源时仍默认超级解析（自动遍历）',
      );
    });

    test('显式 flag 仍然优先于超级解析', () {
      final config = AppConfig(
        sites: [],
        parses: [
          ParseEntry(
            name: '腾讯线路',
            type: 1,
            url: 'https://p.test/?u=',
            ext: {
              'flag': ['qq'],
            },
          ),
        ],
      );
      final selection = ParseRuntime.select(config.playbackParsers, flag: 'qq');
      expect(selection.entry.name, '腾讯线路');
      expect(selection.kind, ParseKind.json);
    });
  });
}

/// 记录 [ParseService.runWithFallback] 收到的 `sniffClick` / `webUrl`，其余返回媒体地址。
class _ClickCaptureParseService extends ParseService {
  final List<String?> sniffClicks = [];
  final List<String> webUrls = [];

  @override
  Future<ParseRunResult> runWithFallback({
    required ParseSelection selection,
    required List<ParseEntry> entries,
    required String webUrl,
    String? flag,
    String? source,
    ParseFailoverSettings failover = const ParseFailoverSettings.defaults(),
    String? sniffClick,
    List<Object?> sniffRules = const [],
    bool revealWindow = true,
  }) async {
    sniffClicks.add(sniffClick);
    webUrls.add(webUrl);
    return ParseRunResult(
      url: _mediaUrl,
      headers: const {},
      parseKind: selection.kind,
      source: 'parse:${selection.entry.name}',
      entryName: selection.entry.name,
    );
  }
}
