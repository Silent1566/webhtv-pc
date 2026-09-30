/// 解析器运行时测试（设计文档 §12「解析器设计」、§7.4.8、§12.3 验收）。
///
/// 覆盖两层：
/// 1. 选择策略（纯逻辑）：type 映射、flag 匹配、默认选择、不支持类型的明确报错；
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
/// 本文件不含 `testWidgets`（flutter_test binding 会拦截 HTTP，见 README §3.3）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/core/parse_runtime.dart';
import 'package:webhtv_pc/core/playback.dart';
import 'package:webhtv_pc/core/protocol.dart';
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

    test('PC 端只支持 JSON 类（type=1/2/3）', () {
      expect(parseKindSupported(ParseKind.json), isTrue);
      expect(parseKindSupported(ParseKind.jsonExtend), isTrue);
      expect(parseKindSupported(ParseKind.jsonMix), isTrue);
      // Web 嗅探与 Super 需要浏览器内核，明确不支持。
      expect(parseKindSupported(ParseKind.webSniff), isFalse);
      expect(parseKindSupported(ParseKind.superParse), isFalse);
      expect(parseKindSupported(ParseKind.unknown), isFalse);
    });
  });

  group('解析器选择（§12.2）', () {
    test('flag 命中 ext.flag 的解析器优先', () {
      final selection = ParseRuntime.select(
        [
          ParseEntry(name: '默认', type: 1, url: 'http://h/a'),
          ParseEntry(
            name: '腾讯线路',
            type: 1,
            url: 'http://h/b',
            ext: {
              'flag': ['qq', 'tencent'],
            },
          ),
        ],
        flag: 'qq',
      );
      expect(selection.entry.name, '腾讯线路');
      expect(selection.matched, 'qq');
      expect(selection.kind, ParseKind.json);
    });

    test('flag 不匹配时回退到第一个支持的 JSON 类解析器', () {
      final selection = ParseRuntime.select(
        [
          // 第一个是不可用的 Web 嗅探，应跳过。
          ParseEntry(name: 'Web 嗅探', type: 0, url: 'http://h/web'),
          ParseEntry(name: 'JSON 解析', type: 1, url: 'http://h/json'),
        ],
        flag: 'nomatch',
      );
      expect(selection.entry.name, 'JSON 解析');
    });

    test('preferName 指定解析器优先（用户显式选择语义）', () {
      final selection = ParseRuntime.select(
        [
          ParseEntry(name: 'A', type: 1, url: 'http://h/a'),
          ParseEntry(name: 'B', type: 3, url: 'http://h/b'),
        ],
        preferName: 'B',
      );
      expect(selection.entry.name, 'B');
      expect(selection.kind, ParseKind.jsonMix);
    });

    test('没有任何解析器 → noneConfigured', () {
      final error = _captureParseError(() => ParseRuntime.select(const []));
      expect(error.kind, ParseSelectionError.noneConfigured);
    });

    test('只有不支持的解析器 → unsupportedOnly 且给出明确原因', () {
      final error = _captureParseError(
        () => ParseRuntime.select([
          ParseEntry(name: 'Web 嗅探', type: 0, url: 'http://h/web'),
          ParseEntry(name: 'Super', type: 4, url: 'http://h/super'),
        ]),
      );
      expect(error.kind, ParseSelectionError.unsupportedOnly);
      expect(error.message, contains('PC 端均不支持'));
      expect(error.message, contains('type=1/2/3'));
    });

    test('preferName 指向不支持类型的解析器 → selectedUnsupported', () {
      final error = _captureParseError(
        () => ParseRuntime.select(
          [
            ParseEntry(name: 'JSON', type: 1, url: 'http://h/a'),
            ParseEntry(name: 'Web 嗅探', type: 0, url: 'http://h/web'),
          ],
          preferName: 'Web 嗅探',
        ),
      );
      expect(error.kind, ParseSelectionError.selectedUnsupported);
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
        ParseRuntime.select([
          ParseEntry(name: name, type: type, url: url),
        ]);

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
          ParseEntry(name: 't1', type: 1, url: '${server.baseUrl}/api/parse/type1'),
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
          ParseEntry(name: 't1', type: 1, url: '${server.baseUrl}/api/parse/type1'),
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
          selection: selectionFor('missing', 1, '${server.baseUrl}/api/parse/type1'),
          entries: const [],
          webUrl: '/missing-url',
        ),
        throwsA(
          isA<AppError>()
              .having((e) => e.kind, 'kind', AppErrorKind.parseEmpty),
        ),
      );
    });

    test('响应 url 为空字符串 → parseEmpty', () async {
      await expectLater(
        service.run(
          selection: selectionFor('empty', 1, '${server.baseUrl}/api/parse/type1'),
          entries: const [],
          webUrl: '/bad',
        ),
        throwsA(
          isA<AppError>()
              .having((e) => e.kind, 'kind', AppErrorKind.parseEmpty),
        ),
      );
    });

    test('非 2xx → parseHttp（调用方可回退直接换源）', () async {
      await expectLater(
        service.run(
          selection: selectionFor('err', 1, '${server.baseUrl}/api/parse/type1'),
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
          selection: selectionFor('notjson', 1, '${server.baseUrl}/api/parse/type1'),
          entries: const [],
          webUrl: '/not-json',
        ),
        throwsA(
          isA<AppError>()
              .having((e) => e.kind, 'kind', AppErrorKind.parseInvalid),
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
          isA<AppError>()
              .having((e) => e.kind, 'kind', AppErrorKind.parseInvalid),
        ),
      );
    });

    test('不支持的 type 直接报 parseUnsupportedType（不静默）', () async {
      // 绕过 select 的类型过滤，直接构造不支持类型的 selection。
      const selection = ParseSelection(
        entry: ParseEntry(name: 'Web 嗅探', type: 0, url: 'http://h/web'),
        kind: ParseKind.webSniff,
      );
      await expectLater(
        service.run(
          selection: selection,
          entries: const [],
          webUrl: '/ep1',
        ),
        throwsA(
          isA<AppError>()
              .having(
                (e) => e.kind,
                'kind',
                AppErrorKind.parseUnsupportedType,
              ),
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
          isA<AppError>()
              .having((e) => e.kind, 'kind', AppErrorKind.parseNetwork),
        ),
      );
    });

    test('超时 → parseNetwork（§12.3「解析过程有超时」）', () async {
      final slow = ParseService(timeout: const Duration(milliseconds: 1));
      addTearDown(slow.close);
      await expectLater(
        slow.run(
          selection: selectionFor('slow', 1, '${server.baseUrl}/api/slow?delay=3'),
          entries: const [],
          webUrl: '/ep1',
        ),
        throwsA(
          isA<AppError>()
              .having((e) => e.kind, 'kind', AppErrorKind.parseNetwork),
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
        selection: selectionFor(
          't1',
          1,
          '${server.baseUrl}/api/parse/type1',
        ),
        entries: const [],
        webUrl: '/ep1',
      );
      expect(looksLikeMediaUrl(result.url), isTrue);
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