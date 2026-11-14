/// 解析器运行时测试（设计文档 §12「解析器设计」、§7.4.8、§12.3 验收）。
///
/// 覆盖两层：
/// 1. 选择策略（纯逻辑）：type 映射、flag 匹配、默认选择、未知类型的明确报错；
/// 2. JSON 解析执行（type=1/2/3）：响应 `{url}`/`{data.url}`/完整 Result、
///    响应头注入、错误归一化、超时与大小上限。
///
/// §12.3 验收点对应：
/// - `parse=0` 不走解析器（由 playback 测试覆盖：返回 direct）；
/// - `parse=1`/`jx=1` 必须走解析器（decision 返回 needParser，见 playback 测试）；
/// - `flag` 命中解析器；
/// - 解析失败不影响直接换源（错误归类为 parse*，调用方可回退）；
/// - 解析结果必须校验媒体类型；
/// - 解析过程有超时；不允许无限嗅探。
///
/// `type=0`（Web 嗅探）与 `type=4`（Super）的执行语义见
/// `test/parse_sniff_behavior_test.dart`（嗅探引擎用假实现，不启动浏览器）。
///
/// 本文件不含 `testWidgets`（flutter_test binding 会拦截 HTTP，见 README §3.3）。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/core/http_api.dart';
import 'package:webhtv_pc/core/parse_failover.dart';
import 'package:webhtv_pc/core/parse_runtime.dart';
import 'package:webhtv_pc/core/playback.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/sniff/sniff_types.dart';
import 'package:webhtv_pc/services/parse_service.dart';

import 'support/test_fixture_server.dart';

void main() {
  group('解析器类型映射（§12.1）', () {
    test('type 数字映射到 ParseKind', () {
      expect(parseKindOf(0), ParseKind.webSniff);
      expect(parseKindOf(1), ParseKind.json);
      expect(parseKindOf(2), ParseKind.jsonExtend);
      expect(parseKindOf(3), ParseKind.jsonMix);
      expect(parseKindOf(4), ParseKind.superParse);
      expect(parseKindOf(99), ParseKind.unknown);
    });

    test('type=0/1/2/3/4 均可执行，仅未知类型不可执行', () {
      // 对齐安卓：0（Web 嗅探）与 4（Super）可执行，缺浏览器内核在执行期报错。
      expect(parseKindSupported(ParseKind.webSniff), isTrue);
      expect(parseKindSupported(ParseKind.json), isTrue);
      expect(parseKindSupported(ParseKind.jsonExtend), isTrue);
      expect(parseKindSupported(ParseKind.jsonMix), isTrue);
      expect(parseKindSupported(ParseKind.superParse), isTrue);
      expect(parseKindSupported(ParseKind.unknown), isFalse);
    });
  });

  group('解析器选择（§12.2）', () {
    test('flag 命中 ext.flag 的解析器优先', () {
      final selection = ParseRuntime.select([
        ParseEntry(name: '默认', type: 1, url: 'http://h/a'),
        ParseEntry(
          name: '腾讯线路',
          type: 1,
          url: 'http://h/b',
          ext: {
            'flag': ['qq', 'tencent'],
          },
        ),
      ], flag: 'qq');
      expect(selection.entry.name, '腾讯线路');
      expect(selection.matched, 'qq');
      expect(selection.kind, ParseKind.json);
    });

    test('flag 不匹配时回退到第一个已知类型的解析器（未知类型跳过）', () {
      final selection = ParseRuntime.select([
        // 类型未知的解析器不可执行，选择时跳过。
        ParseEntry(name: '未来类型', type: 99, url: 'http://h/unknown'),
        ParseEntry(name: 'JSON 解析', type: 1, url: 'http://h/json'),
      ], flag: 'nomatch');
      expect(selection.entry.name, 'JSON 解析');
    });

    test('type=0/4 是已知类型：按配置顺序选中（对齐安卓选中项）', () {
      final sniff = ParseRuntime.select([
        ParseEntry(name: 'Web 嗅探', type: 0, url: 'http://h/web'),
        ParseEntry(name: 'JSON 解析', type: 1, url: 'http://h/json'),
      ]);
      expect(sniff.kind, ParseKind.webSniff);
      expect(sniff.entry.name, 'Web 嗅探');

      final superParse = ParseRuntime.select([
        ParseEntry(name: 'Super', type: 4),
        ParseEntry(name: 'JSON 解析', type: 1, url: 'http://h/json'),
      ]);
      expect(superParse.kind, ParseKind.superParse);
    });

    test('preferName 指定解析器优先（用户显式选择语义）', () {
      final selection = ParseRuntime.select([
        ParseEntry(name: 'A', type: 1, url: 'http://h/a'),
        ParseEntry(name: 'B', type: 3, url: 'http://h/b'),
      ], preferName: 'B');
      expect(selection.entry.name, 'B');
      expect(selection.kind, ParseKind.jsonMix);
    });

    test('没有任何解析器 → noneConfigured', () {
      final error = _captureParseError(() => ParseRuntime.select(const []));
      expect(error.kind, ParseSelectionError.noneConfigured);
    });

    test('只有未知类型的解析器 → unsupportedOnly 且给出明确原因', () {
      final error = _captureParseError(
        () => ParseRuntime.select([
          ParseEntry(name: '未来类型', type: 99, url: 'http://h/x'),
          ParseEntry(name: '另一未知', type: 8, url: 'http://h/y'),
        ]),
      );
      expect(error.kind, ParseSelectionError.unsupportedOnly);
      expect(error.message, contains('类型未知'));
      expect(error.message, contains('type=99'));
      expect(error.message, contains('type=0/1/2/3/4'));
    });

    test('preferName 指向未知类型的解析器 → selectedUnsupported', () {
      final error = _captureParseError(
        () => ParseRuntime.select([
          ParseEntry(name: 'JSON', type: 1, url: 'http://h/a'),
          ParseEntry(name: '未来类型', type: 99, url: 'http://h/unknown'),
        ], preferName: '未来类型'),
      );
      expect(error.kind, ParseSelectionError.selectedUnsupported);
      expect(error.message, contains('类型未知'));
    });

    test('preferName 指向 type=0/4 的解析器 → 正常选中（可执行）', () {
      final selection = ParseRuntime.select([
        ParseEntry(name: 'JSON', type: 1, url: 'http://h/a'),
        ParseEntry(name: 'Web 嗅探', type: 0, url: 'http://h/web'),
      ], preferName: 'Web 嗅探');
      expect(selection.kind, ParseKind.webSniff);
    });
  });

  group('JSON 解析执行（§12.2、§12.3）', () {
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

    ParseSelection selectionFor(String name, int type, String url) =>
        ParseRuntime.select([ParseEntry(name: name, type: type, url: url)]);

    test('type=1：从 {url,data.url} 与响应头取结果', () async {
      final result = await service.run(
        selection: selectionFor('t1', 1, '${server.baseUrl}/api/parse/type1'),
        entries: const [],
        // §12.2：解析器请求为 `解析器url + 目标路径`（对齐 Android `url + webUrl`）。
        webUrl: '/ep1',
      );

      expect(result.url, '${server.baseUrl}/media/sample.mp4');
      expect(result.parseKind, ParseKind.json);
      expect(result.entryName, 't1');
      // 响应头注入（§8.4）。
      expect(result.headers['User-Agent'], 'WebHTV-PC-Phase0');
      expect(result.headers['Referer'], 'http://127.0.0.1:18080/');
      expect(result.source, contains('t1'));
      // 请求确实带了目标地址（jsonParse 的 url+webUrl 拼接）。
      final request = server.captured.lastWhere(
        (item) => item.path.startsWith('/api/parse/type1'),
      );
      expect(request.method, 'GET');
      expect(request.path, '/api/parse/type1/ep1');
    });

    test('type=2：完整 Result（url + header）', () async {
      final result = await service.run(
        selection: selectionFor('t2', 2, '${server.baseUrl}/api/parse/type2'),
        entries: [
          ParseEntry(
            name: 't1',
            type: 1,
            url: '${server.baseUrl}/api/parse/type1',
          ),
        ],
        webUrl: '/ep1',
      );

      expect(result.url, '${server.baseUrl}/media/sample.mp4');
      expect(result.parseKind, ParseKind.jsonExtend);
      expect(result.headers['Referer'], 'http://127.0.0.1:18080/');
      // type=2 是 POST 表单（携带 type=1 解析器查找表）。
      final request = server.captured.lastWhere(
        (item) => item.path.startsWith('/api/parse/type2'),
      );
      expect(request.method, 'POST');
    });

    test('type=3：JSON Mix（POST 携带 flag）', () async {
      final result = await service.run(
        selection: selectionFor('t3', 3, '${server.baseUrl}/api/parse/type2'),
        entries: [
          ParseEntry(
            name: 't1',
            type: 1,
            url: '${server.baseUrl}/api/parse/type1',
          ),
        ],
        webUrl: '/ep1',
        flag: 'qq',
      );

      expect(result.parseKind, ParseKind.jsonMix);
      final request = server.captured.lastWhere(
        (item) => item.path.startsWith('/api/parse/type2'),
      );
      expect(request.method, 'POST');
      // 表单带上 flag（对齐 jsonExtMix）：flag 经 `jx` 字段传输。
      expect(request.form['jx'], 'qq');
      expect(request.form['name'], 't3');
    });

    test('响应缺 url/data.url → parseEmpty', () async {
      await expectLater(
        service.run(
          selection: selectionFor(
            'missing',
            1,
            '${server.baseUrl}/api/parse/type1',
          ),
          entries: const [],
          webUrl: '/missing-url',
        ),
        throwsA(
          isA<AppError>().having(
            (e) => e.kind,
            'kind',
            AppErrorKind.parseEmpty,
          ),
        ),
      );
    });

    test('响应 url 为空字符串 → parseEmpty', () async {
      await expectLater(
        service.run(
          selection: selectionFor(
            'empty',
            1,
            '${server.baseUrl}/api/parse/type1',
          ),
          entries: const [],
          webUrl: '/bad',
        ),
        throwsA(
          isA<AppError>().having(
            (e) => e.kind,
            'kind',
            AppErrorKind.parseEmpty,
          ),
        ),
      );
    });

    test('非 2xx → parseHttp（调用方可回退直接换源）', () async {
      await expectLater(
        service.run(
          selection: selectionFor(
            'err',
            1,
            '${server.baseUrl}/api/parse/type1',
          ),
          entries: const [],
          webUrl: '/error',
        ),
        throwsA(
          isA<AppError>()
              .having((e) => e.kind, 'kind', AppErrorKind.parseHttp)
              .having((e) => e.statusCode, 'statusCode', 500),
        ),
      );
    });

    test('响应不是 JSON → parseInvalid', () async {
      await expectLater(
        service.run(
          selection: selectionFor(
            'notjson',
            1,
            '${server.baseUrl}/api/parse/type1',
          ),
          entries: const [],
          webUrl: '/not-json',
        ),
        throwsA(
          isA<AppError>().having(
            (e) => e.kind,
            'kind',
            AppErrorKind.parseInvalid,
          ),
        ),
      );
    });

    test('解析器未配置 url → parseInvalid', () async {
      await expectLater(
        service.run(
          selection: selectionFor('nourl', 1, ''),
          entries: const [],
          webUrl: '/ep1',
        ),
        throwsA(
          isA<AppError>().having(
            (e) => e.kind,
            'kind',
            AppErrorKind.parseInvalid,
          ),
        ),
      );
    });

    test('未知 type 直接报 parseUnsupportedType（不静默）', () async {
      // 绕过 select 的类型过滤，直接构造未知类型的 selection。
      const selection = ParseSelection(
        entry: ParseEntry(name: '未来类型', type: 99, url: 'http://h/unknown'),
        kind: ParseKind.unknown,
      );
      await expectLater(
        service.run(selection: selection, entries: const [], webUrl: '/ep1'),
        throwsA(
          isA<AppError>()
              .having((e) => e.kind, 'kind', AppErrorKind.parseUnsupportedType)
              .having((e) => e.message, 'message', contains('类型未知')),
        ),
      );
    });

    test('连接失败 → parseNetwork（可回退）', () async {
      await expectLater(
        service.run(
          selection: selectionFor('dead', 1, 'http://127.0.0.1:9/parse'),
          entries: const [],
          webUrl: '/ep1',
        ),
        throwsA(
          isA<AppError>().having(
            (e) => e.kind,
            'kind',
            AppErrorKind.parseNetwork,
          ),
        ),
      );
    });

    test('超时 → parseNetwork（§12.3「解析过程有超时」）', () async {
      final slow = ParseService(
        jsonParseTimeout: const Duration(milliseconds: 1),
      );
      addTearDown(slow.close);
      await expectLater(
        slow.run(
          selection: selectionFor(
            'slow',
            1,
            '${server.baseUrl}/api/slow?delay=3',
          ),
          entries: const [],
          webUrl: '/ep1',
        ),
        throwsA(
          isA<AppError>().having(
            (e) => e.kind,
            'kind',
            AppErrorKind.parseNetwork,
          ),
        ),
      );
    });

    test('解析错误分类可识别（§12.3 解析失败不影响换源）', () {
      expect(
        isParseError(AppError(AppErrorKind.parseHttp, 'HTTP 500')),
        isTrue,
      );
      expect(
        isParseError(AppError(AppErrorKind.parseNetwork, 'timeout')),
        isTrue,
      );
      expect(
        isParseError(AppError(AppErrorKind.playbackUrlMissing, '缺地址')),
        isFalse,
      );
      expect(isParseError(StateError('boom')), isFalse);
    });

    test('§12.3 解析结果必须是媒体地址（校验媒体类型）', () async {
      final result = await service.run(
        selection: selectionFor('t1', 1, '${server.baseUrl}/api/parse/type1'),
        entries: const [],
        webUrl: '/ep1',
      );
      expect(looksLikeMediaUrl(result.url), isTrue);
    });
  });

  group('解析器请求超时（安卓 TIMEOUT_PARSE_DEF）', () {
    test('默认 15s，且只作用于解析器请求（站点预算不变）', () {
      final service = ParseService();
      addTearDown(service.close);
      expect(service.jsonParseTimeout, SniffTimeouts.parseDefault);
      expect(service.jsonParseTimeout, const Duration(seconds: 15));
      expect(service.timeout, siteRequestTimeout, reason: '站点接口仍是原预算，本轮不收紧');
      expect(siteRequestTimeout, const Duration(seconds: 180));
      // 站点接口客户端仍是同一个预算：解析器收紧 15s 不影响它。
      final api = HttpApiClient();
      addTearDown(api.close);
      expect(api.timeout, siteRequestTimeout);
    });
  });

  group('失败切换候选排序（P1-4 裁决：JSON 类先、嗅探类后）', () {
    const primary = ParseSelection(
      entry: ParseEntry(name: 'A', type: 1, url: 'https://a.test/parse'),
      kind: ParseKind.json,
    );
    // 配置顺序故意把嗅探类排在 JSON 类前面，且 Super（type=4）在 Web（type=0）之前：
    // 这样「先 JSON 后嗅探」与「嗅探类内部保序」两个断言都能被证伪。
    const entries = [
      ParseEntry(name: 'A', type: 1, url: 'https://a.test/parse'),
      ParseEntry(name: 'Super', type: 4),
      ParseEntry(name: 'T2', type: 2, url: 'https://t2.test/parse'),
      ParseEntry(name: 'Web-1', type: 0, url: 'https://w1.test/p?u='),
      ParseEntry(name: 'T3', type: 3, url: 'https://t3.test/parse'),
    ];

    test('先 JSON 类再嗅探类，两类内部各自保持配置顺序', () {
      final selections = parseFailoverSelections(
        primary: primary,
        entries: entries,
        settings: const ParseFailoverSettings(enabled: true, maxAttempts: 5),
      );
      expect(selections.map((selection) => selection.entry.name), [
        'T2',
        'T3',
        'Super',
        'Web-1',
      ], reason: 'JSON 类（1/2/3）整体在前且内部保序；嗅探类（0/4）在后且内部保序');
    });

    test('maxAttempts 截断发生在排序之后：上限先吃掉嗅探类', () {
      final limited = parseFailoverSelections(
        primary: primary,
        entries: entries,
        settings: const ParseFailoverSettings(enabled: true, maxAttempts: 3),
      );
      expect(limited.map((selection) => selection.entry.name), ['T2', 'T3']);
    });
  });

  group('站点 playUrl 前缀拼接（§7.4.8、安卓 VodApi:185）', () {
    Site siteWith(String playUrl) => Site(
      key: 'prefix',
      name: '前缀站点',
      type: 1,
      api: 'https://api.test/api.php/provide/vod/',
      extra: {'playUrl': playUrl},
    );

    test('前缀 + 非媒体拼接结果 → needParser，目标是拼接结果', () {
      final decision = PlaybackResolver.decide(
        PlaybackResolutionInput(
          site: siteWith('/jx.php?url='),
          episodeTarget: 'abc123',
        ),
      );
      expect(decision.action, PlaybackAction.needParser);
      expect(decision.url, '/jx.php?url=abc123');
    });

    test('前缀 + 媒体拼接结果 → direct（不误判成解析页）', () {
      final decision = PlaybackResolver.decide(
        PlaybackResolutionInput(
          site: siteWith('https://jx.test/proxy.m3u8?url='),
          episodeTarget: 'v-ep-1',
        ),
      );
      expect(decision.action, PlaybackAction.direct);
      expect(decision.url, 'https://jx.test/proxy.m3u8?url=v-ep-1');
    });

    test('目标为空仍抛 playbackUrlMissing（缺失地址不因前缀规则放宽）', () {
      expect(
        () => PlaybackResolver.decide(
          PlaybackResolutionInput(
            site: siteWith('/jx.php?url='),
            episodeTarget: '   ',
          ),
        ),
        throwsA(
          isA<AppError>().having(
            (error) => error.kind,
            'kind',
            AppErrorKind.playbackUrlMissing,
          ),
        ),
      );
    });
  });

  group('播放结果 click（安卓 Result.getClick）', () {
    test('HttpApiResponseParser 收下结果级 click', () {
      final result = HttpApiResponseParser.parse(
        '{"parse":1,"url":"https://cdn.test/v.m3u8","click":"video.play()"}',
        siteKey: 'click-site',
      );
      expect(result.click, 'video.play()');
      expect(result.parse, 1);
      expect(result.playUrl, 'https://cdn.test/v.m3u8');
    });

    test('spider/sidecar 形态的 Result JSON（含 click）同样有值', () {
      // sidecar（JS/JVM/Python）与 cat http 的 Result 都由
      // `sidecar_runtime.dart` / `cat_http.dart` 直接交给
      // [HttpApiResponseParser.parse]，所以这里锁的是「共用同一解释器」。
      final spiderResult = <String, Object?>{
        'parse': 1,
        'jx': 1,
        'url': 'https://cdn.test/v.m3u8',
        'header': {'User-Agent': 'UA-SPIDER'},
        'click': 'video.play()',
        'subs': <Object?>[],
      };
      final result = HttpApiResponseParser.parse(
        jsonEncode(spiderResult),
        siteKey: 'spider-site',
      );
      expect(result.click, 'video.play()');
      expect(result.parse, 1);
      expect(result.jx, 1);
      expect(result.header?.asRequestHeaders['User-Agent'], 'UA-SPIDER');
    });

    test('没有 click 时为 null，不伪造空串', () {
      final result = HttpApiResponseParser.parse(
        '{"url":"https://cdn.test/v.m3u8"}',
        siteKey: 'click-site',
      );
      expect(result.click, isNull);
    });
  });
}

/// 捕获解析器选择异常（同步）。
ParseSelectionException _captureParseError(void Function() action) {
  try {
    action();
  } on ParseSelectionException catch (error) {
    return error;
  } catch (error) {
    fail('期望 ParseSelectionException，实际抛出 ${error.runtimeType}: $error');
  }
  fail('期望抛出 ParseSelectionException，但没有抛出');
}
