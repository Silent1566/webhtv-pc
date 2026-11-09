import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:xml/xml.dart';
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/core/cat_http.dart';
import 'package:webhtv_pc/core/http_api.dart';
import 'package:webhtv_pc/core/ipc_protocol.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/spider_process.dart';
import 'package:webhtv_pc/services/spider_router.dart';

Site _catSite() => Site(
  key: 'csp_AList',
  name: 'AList',
  type: SiteType.spider,
  api: 'https://example.com/spider/alist?sign=request-sign&%74oken=request-token&keep=1',
);

http.Response _response(String body, [int status = 200]) => http.Response(
  body,
  status,
  headers: {
    'content-type': 'application/json; charset=utf-8',
    'set-cookie': 'sid=response-cookie',
    'authorization': 'Bearer response-auth',
    'x-keep': 'visible',
  },
);

Map<String, dynamic> _loggedBody(LogService log) =>
    jsonDecode(log.entries.last.message.split(' body=').last)
        as Map<String, dynamic>;

void _expectRedacted(LogService log) {
  final text = log.export();
  for (final secret in [
    'request-sign',
    'request-token',
    'request-cookie',
    'request-auth',
    'response-cookie',
    'response-auth',
    'body-cookie',
    'body-auth',
    'body-sign',
    'body-token',
  ]) {
    expect(text, isNot(contains(secret)), reason: secret);
  }
  expect(text, contains('<redacted>'));
}

class _ThrowingLog extends LogService {
  @override
  void debug(String message, {String? scope}) =>
      throw StateError('disk failed');
}

class _UnreadableParams extends MapBase<String, Object?> {
  @override
  Iterable<String> get keys => throw StateError('must not traverse params');
  @override
  Object? operator [](Object? key) => throw StateError('must not read params');
  @override
  void operator []=(String key, Object? value) =>
      throw UnsupportedError('read only');
  @override
  void clear() => throw UnsupportedError('read only');
  @override
  Object? remove(Object? key) => throw UnsupportedError('read only');
}

void main() {
  test('Cat HTTP 首页 60 条完整记录且签名后字段仍保留', () async {
    final log = LogService();
    addTearDown(log.dispose);
    final debug = SpiderDebugLog(log: log, enabled: true);
    final content = '完整剧情' * 500;
    final payload = {
      'class': [
        {'type_id': '1', 'type_name': '电影'},
      ],
      'list': List.generate(
        60,
        (i) => {
          'vod_id': '$i',
          'vod_name': '作品$i',
          'vod_pic': 'https://cdn.example.com/$i.jpg?sign=body-sign&t=1',
          'vod_content': content,
          'tail': 'item-tail-$i',
        },
      ),
      'header': {'Cookie': 'body-cookie', 'Authorization': 'body-auth'},
      'url': 'https://cdn.example.com/play?token=body-token&t=2',
      'tail': 'response-tail',
    };
    final body = jsonEncode(payload);
    final cat = CatHttpClient(
      client: MockClient((request) async {
        expect(request.url.queryParameters['sign'], 'request-sign');
        expect(request.url.queryParameters['token'], 'request-token');
        expect(request.body, '{}');
        return _response(body);
      }),
      debugLog: debug,
    );
    final router = SpiderRouter(
      client: HttpApiClient(),
      catHttpClient: cat,
      globalHeaders: const [],
    );
    addTearDown(router.dispose);
    final result = await router.runtimeFor(_catSite()).home(_catSite());
    expect(result.list, hasLength(60));
    expect(log.entries, hasLength(2));
    expect(log.entries.every((e) => e.scope == 'spider'), isTrue);
    expect(log.entries.every((e) => e.level == LogLevel.debug), isTrue);
    final request = log.entries.first.message;
    expect(request, startsWith('http→'));
    expect(request, contains('action=/home'));
    expect(request, contains('site=csp_AList'));
    expect(request, contains('keep=1'));
    expect(request, contains('params={}'));
    expect(log.entries.last.message, startsWith('http←'));
    expect(log.entries.last.message, contains('status=200'));
    expect(log.entries.last.message, contains('visible'));
    _expectRedacted(log);
    final logged = _loggedBody(log);
    expect(logged['list'], hasLength(60));
    expect(
      logged['list'][0]['vod_pic'],
      'https://cdn.example.com/0.jpg?sign=<redacted>&t=1',
    );
    expect(logged['url'], 'https://cdn.example.com/play?token=<redacted>&t=2');
    for (var i = 0; i < 60; i++) {
      expect(logged['list'][i]['vod_content'], content);
      expect(logged['list'][i]['tail'], 'item-tail-$i');
      expect(logged['list'][i]['vod_pic'], contains('t=1'));
    }
    expect(logged['tail'], 'response-tail');
    final lineBytes = utf8.encode('${log.entries.last.line}\n').length;
    stdout.writeln(
      '60-item fixture: body=${utf8.encode(body).length} bytes, '
      'response-log=$lineBytes bytes, '
      '20MiB=${LogService.verboseMaxFileBytes} bytes',
    );
    expect(lineBytes, lessThan(LogService.verboseMaxFileBytes));
  });

  test('Cat HTTP 分类参数完整且旁路不改变请求头和请求体', () async {
    final log = LogService();
    addTearDown(log.dispose);
    final cat = CatHttpClient(
      debugLog: SpiderDebugLog(log: log, enabled: true),
      client: MockClient((request) async {
        expect(request.headers['cookie'], 'request-cookie');
        expect(request.headers['authorization'], 'request-auth');
        expect(jsonDecode(request.body), {
          'id': '电影',
          'page': 2,
          'filters': {'year': '2024', 'token': 'request-token'},
        });
        return _response('{"list":[]}');
      }),
    );
    addTearDown(cat.close);
    final call = CatHttpRequestBuilder(api: _catSite().api).build(
      CatHttpRoute.category,
      typeId: '电影',
      page: 2,
      filters: {'year': '2024', 'token': 'request-token'},
    );
    final withHeaders = CatHttpCall(
      route: call.route,
      uri: call.uri,
      body: call.body,
      headers: {
        ...call.headers,
        'Cookie': 'request-cookie',
        'Authorization': 'request-auth',
      },
    );
    await cat.call(withHeaders, siteKey: 'csp_AList');
    expect(log.entries, hasLength(2));
    expect(log.entries.first.message, contains('action=/category'));
    expect(log.entries.first.message, contains('"page":2'));
    expect(log.entries.first.message, contains('"year":"2024"'));
    _expectRedacted(log);
    expect(call.body['filters'], {'year': '2024', 'token': 'request-token'});
  });

  test('同一缓存 Cat 运行时切换开关即时生效，详情一进一出', () async {
    final log = LogService();
    addTearDown(log.dispose);
    final debug = SpiderDebugLog(log: log);
    final cat = CatHttpClient(
      debugLog: debug,
      client: MockClient(
        (request) async =>
            _response('{"list":[{"vod_id":"7","vod_name":"详情"}]}'),
      ),
    );
    final router = SpiderRouter(
      client: HttpApiClient(),
      catHttpClient: cat,
      globalHeaders: const [],
    );
    addTearDown(router.dispose);
    final runtime = router.runtimeFor(_catSite());
    expect((await runtime.detail(_catSite(), '7')).list.single.vodId, '7');
    expect(log.entries, isEmpty);
    debug.enabled = true;
    expect((await runtime.detail(_catSite(), '7')).list.single.vodId, '7');
    expect(log.entries, hasLength(2));
    expect(log.entries.first.message, contains('action=/detail'));
    expect(log.entries.first.message, contains('"id":"7"'));
    debug.enabled = false;
    await runtime.detail(_catSite(), '7');
    expect(log.entries, hasLength(2));
  });

  for (final type in [0, 1, 2, 4]) {
    test('HTTP API type=$type 覆盖 GET/表单及完整响应', () async {
      final log = LogService();
      addTearDown(log.dispose);
      final debug = SpiderDebugLog(log: log, enabled: true);
      final xml =
          '<rss><class id="1">电影</class>'
          '<list id="7"><name>作品</name></list></rss>';
      final body = type == 0
          ? xml
          : '{"list":[{"vod_id":"7","vod_name":"作品"}],"tail":"response-tail"}';
      final client = HttpApiClient(
        debugLog: debug,
        client: MockClient((request) async {
          expect(request.url.queryParameters['sign'], 'request-sign');
          expect(request.url.queryParameters['pg'], '3');
          expect(request.headers['authorization'], 'request-auth');
          expect(request.method, type == 4 ? 'POST' : 'GET');
          if (type == 4) expect(request.bodyFields['extend'], 'x' * 1200);
          return _response(body);
        }),
      );
      addTearDown(client.close);
      final site = Site(
        key: 'http-$type',
        name: 'HTTP',
        type: type,
        api: 'https://example.com/api?sign=request-sign&keep=1',
        ext: type == 4 ? 'x' * 1200 : null,
        header: HeaderMap({'Authorization': 'request-auth'}),
      );
      final call = HttpApiRequestBuilder(site: site)
          .build(HttpApiAction.category, typeId: '1', page: 3);
      final result = await client.execute(call, siteKey: site.key);
      expect(result.list.single.vodId, '7');
      expect(log.entries, hasLength(2));
      expect(log.entries.first.message, contains('action=category'));
      expect(log.entries.first.message, contains('pg=3'));
      if (type == 4) expect(log.entries.first.message, contains('x' * 1200));
      expect(log.entries.last.message, contains('status=200'));
      if (type == 0) {
        expect(log.entries.last.message, endsWith('body=$xml'));
      } else {
        expect(_loggedBody(log)['tail'], 'response-tail');
      }
      _expectRedacted(log);
      debug.enabled = false;
      await client.execute(call, siteKey: site.key);
      expect(log.entries, hasLength(2));
    });
  }

  test('XML 正文的签名 URL 脱敏后不吞掉后续站点字段', () async {
    final log = LogService();
    addTearDown(log.dispose);
    final xml =
        '<rss><list id="7"><name>作品</name>'
        '<pic>https://cdn.example.com/a.jpg?token=body-token</pic>'
        '<des>完整剧情尾部</des></list></rss>';
    final api = HttpApiClient(
      debugLog: SpiderDebugLog(log: log, enabled: true),
      client: MockClient((_) async => _response(xml)),
    );
    addTearDown(api.close);
    final result = await api.execute(
      HttpApiCall(
        method: 'GET',
        uri: Uri.parse('https://example.com/'),
        headers: const {},
        action: 'home',
      ),
      siteKey: 'xml',
    );
    expect(result.list.single.vodId, '7');
    _expectRedacted(log);
    final text = log.entries.last.message.split(' body=').last;
    expect(text, contains('完整剧情尾部'));
    expect(text, contains('</des>'));
    expect(text, contains('</list>'));
    final document = XmlDocument.parse(text);
    expect(
      document.rootElement.getElement('list')!.getElement('pic')!.innerText,
      'https://cdn.example.com/a.jpg?token=<redacted>',
    );
  });

  test('非法 XML 解析失败时降级为文本脱敏，日志不消失也不抛', () async {
    final log = LogService();
    addTearDown(log.dispose);
    final body =
        '<html><body>坏页?token=body-token &nbsp; 未闭合 '
        '${'w' * 200} 完整尾部</body>';
    final api = HttpApiClient(
      debugLog: SpiderDebugLog(log: log, enabled: true),
      client: MockClient((_) async => _response(body)),
    );
    addTearDown(api.close);
    await expectLater(
      api.execute(
        HttpApiCall(
          method: 'GET',
          uri: Uri.parse('https://example.com/'),
          headers: const {},
          action: 'home',
        ),
        siteKey: 'xml',
      ),
      throwsA(
        isA<AppError>().having((e) => e.kind, 'kind', AppErrorKind.siteParse),
      ),
    );
    expect(log.entries, hasLength(2));
    final text = log.entries.last.message;
    expect(text, contains('status=200'));
    expect(text, contains('完整尾部'));
    expect(text, isNot(contains('body-token')));
    expect(text, contains('token=<redacted>'));
  });

  test('HTTP API 的 JSON 字符串扩展与嵌套 URL 参数也脱敏', () async {
    final log = LogService();
    addTearDown(log.dispose);
    final queryExt = jsonEncode({
      'token': 'request-token',
      'tail': 'query-tail',
    });
    final formExt = jsonEncode({
      'header': {'Authorization': 'request-auth'},
      'tail': 'form-tail',
    });
    final responseExt = jsonEncode({
      'header': {'Cookie': 'body-cookie'},
      'tail': 'body-tail',
    });
    final uri = Uri.https('example.com', '/api', {
      'extend': queryExt,
      'redirect': 'https://cdn.example.com/media?sign=request-sign&t=1',
    });
    final api = HttpApiClient(
      debugLog: SpiderDebugLog(log: log, enabled: true),
      client: MockClient((request) async {
        expect(request.url.queryParameters['extend'], queryExt);
        expect(request.bodyFields['extend'], formExt);
        return _response(jsonEncode({'list': [], 'extend': responseExt}));
      }),
    );
    addTearDown(api.close);
    await api.execute(
      HttpApiCall(
        method: 'POST',
        uri: uri,
        formBody: {'extend': formExt},
        headers: const {},
        action: 'home',
      ),
      siteKey: 'api',
    );
    expect(log.entries, hasLength(2));
    _expectRedacted(log);
    final request = log.entries.first.message;
    expect(request, contains('query-tail'));
    expect(request, contains('form-tail'));
    expect(request, contains('t%3D1'));
    final extended = jsonDecode(_loggedBody(log)['extend'] as String);
    expect(extended['tail'], 'body-tail');
  });

  test('关闭或无日志服务时不遍历参数、不解码响应、不执行额外编码', () {
    final log = LogService();
    addTearDown(log.dispose);
    final debug = SpiderDebugLog(log: log);
    var decoded = 0;
    void invoke(SpiderDebugLog target) {
      target.httpOutbound(
        method: 'POST',
        action: '/home',
        siteKey: 'cat',
        uri: Uri.parse('https://example.com/'),
        params: _UnreadableParams(),
      );
      target.httpInbound(
        method: 'POST',
        action: '/home',
        siteKey: 'cat',
        statusCode: 200,
        body: () {
          decoded++;
          throw StateError('must not decode');
        },
      );
    }

    expect(() => invoke(debug), returnsNormally);
    expect(() => invoke(SpiderDebugLog(enabled: true)), returnsNormally);
    expect(decoded, 0);
    expect(log.entries, isEmpty);
  });

  test('日志写入异常不影响两类 HTTP 客户端结果', () async {
    final log = _ThrowingLog();
    addTearDown(log.dispose);
    final debug = SpiderDebugLog(log: log, enabled: true);
    final cat = CatHttpClient(
      debugLog: debug,
      client: MockClient((_) async => _response('{"list":[]}')),
    );
    final api = HttpApiClient(
      debugLog: debug,
      client: MockClient((_) async => _response('{"list":[]}')),
    );
    addTearDown(cat.close);
    addTearDown(api.close);
    expect(
      (await cat.call(
        CatHttpRequestBuilder(api: _catSite().api).build('/home'),
        siteKey: 'cat',
      )).list,
      isEmpty,
    );
    expect(
      (await api.execute(
        HttpApiCall(
          method: 'GET',
          uri: Uri.parse('https://example.com/'),
          headers: const {},
        ),
        siteKey: 'api',
      )).list,
      isEmpty,
    );
    expect(
      () => debug.httpOutbound(
        method: 'POST',
        action: '/home',
        siteKey: 'cat',
        uri: Uri.parse('https://example.com/'),
        params: _UnreadableParams(),
      ),
      returnsNormally,
    );
    expect(
      () => debug.httpInbound(
        method: 'POST',
        action: '/home',
        siteKey: 'cat',
        statusCode: 200,
        body: () => throw StateError('decode failed'),
      ),
      returnsNormally,
    );
  });

  test('网络失败和超时仍一进一出且保留原错误类型', () async {
    final log = LogService();
    addTearDown(log.dispose);
    final debug = SpiderDebugLog(log: log, enabled: true);
    for (final timeout in [false, true]) {
      final error = timeout
          ? TimeoutException('request-token')
          : http.ClientException('request-token');
      final cat = CatHttpClient(
        debugLog: debug,
        client: MockClient((_) async => throw error),
      );
      final api = HttpApiClient(
        debugLog: debug,
        client: MockClient((_) async => throw error),
      );
      addTearDown(cat.close);
      addTearDown(api.close);
      final before = log.entries.length;
      await expectLater(
        cat.call(
          CatHttpRequestBuilder(api: _catSite().api).build('/home'),
          siteKey: 'cat',
        ),
        throwsA(
          isA<SpiderError>().having(
            (e) => e.code,
            'code',
            timeout ? SpiderErrorCode.timeout : SpiderErrorCode.httpError,
          ),
        ),
      );
      expect(log.entries, hasLength(before + 2));
      expect(log.entries.last.message, contains('status=network_error'));
      await expectLater(
        api.execute(
          HttpApiCall(
            method: 'GET',
            uri: Uri.parse('https://example.com/'),
            headers: const {},
          ),
          siteKey: 'api',
        ),
        throwsA(
          isA<AppError>().having(
            (e) => e.kind,
            'kind',
            timeout ? AppErrorKind.siteTimeout : AppErrorKind.siteNetwork,
          ),
        ),
      );
      expect(log.entries, hasLength(before + 4));
      expect(log.entries.last.message, contains('status=network_error'));
      _expectRedacted(log);
    }
  });

  test('本次批量追加将超上限时先轮转，主文件不越阈值', () async {
    final folder = await Directory.systemTemp.createTemp('http-debug-rotate-');
    addTearDown(() => folder.delete(recursive: true));
    final log = LogService(maxFileBytes: 1024);
    addTearDown(log.dispose);
    await log.open(folder.path);
    final file = File('${folder.path}${Platform.pathSeparator}webhtv-pc.log');
    final oldText = 'old ${'x' * 600}';
    final newText = 'new ${'y' * 300}';
    log.info(oldText);
    log.flush();
    expect(file.lengthSync(), lessThan(1024));
    log.info('$newText first');
    log.info('$newText second');
    log.flush();
    final rotated = File('${file.path}.1');
    expect(rotated.existsSync(), isTrue);
    expect(file.lengthSync(), lessThanOrEqualTo(1024));
    expect(rotated.readAsStringSync(), contains(oldText));
    expect(file.readAsStringSync(), contains('$newText first'));
    expect(file.readAsStringSync(), contains('$newText second'));
  });

  test('单批本身超上限时只轮转一次仍写全文，不丢日志', () async {
    final folder = await Directory.systemTemp.createTemp(
      'http-debug-large-batch-',
    );
    addTearDown(() => folder.delete(recursive: true));
    final log = LogService(maxFileBytes: 1024);
    addTearDown(log.dispose);
    await log.open(folder.path);
    final file = File('${folder.path}${Platform.pathSeparator}webhtv-pc.log');
    log.info('old');
    log.flush();
    final text = '完整全文${'z' * 1200}';
    log.info('$text first');
    log.info('$text second');
    log.flush();
    expect(File('${file.path}.1').existsSync(), isTrue);
    expect(File('${file.path}.2').existsSync(), isFalse);
    expect(file.lengthSync(), greaterThan(1024));
    expect(file.readAsStringSync(), contains('$text first'));
    expect(file.readAsStringSync(), contains('$text second'));
  });

  test('非成功 HTTP 状态也打印完整错误响应，错误语义不变', () async {
    final log = LogService();
    addTearDown(log.dispose);
    final debug = SpiderDebugLog(log: log, enabled: true);
    final body = 'error start ${'z' * 8000} error end';
    final cat = CatHttpClient(
      debugLog: debug,
      client: MockClient((_) async => _response(body, 404)),
    );
    final api = HttpApiClient(
      debugLog: debug,
      client: MockClient((_) async => _response(body, 503)),
    );
    addTearDown(cat.close);
    addTearDown(api.close);
    await expectLater(
      cat.call(
        CatHttpRequestBuilder(api: _catSite().api).build('/home'),
        siteKey: 'cat',
      ),
      throwsA(
        isA<SpiderError>().having(
          (e) => e.code,
          'code',
          SpiderErrorCode.unsupported,
        ),
      ),
    );
    expect(log.entries, hasLength(2));
    expect(log.entries.last.message, contains('status=404'));
    expect(log.entries.last.message, endsWith('body=$body'));
    await expectLater(
      api.execute(
        HttpApiCall(
          method: 'GET',
          uri: Uri.parse('https://example.com/'),
          headers: const {},
        ),
        siteKey: 'api',
      ),
      throwsA(isA<AppError>().having((e) => e.statusCode, 'status', 503)),
    );
    expect(log.entries, hasLength(4));
    expect(log.entries.last.message, contains('status=503'));
    expect(log.entries.last.message, endsWith('body=$body'));
  });
}
