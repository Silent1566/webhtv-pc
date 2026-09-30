/// 测试用本地 HTTP 服务：返回仓库 `packages/test-fixtures` 中的同一份 fixture。
///
/// 为什么需要它：单元测试不能依赖外部进程。这里只重放与
/// `tools/fixture_server/server.py` 相同的 fixture 数据，保证
/// “fixture 与预期结果不分叉”（设计文档 §19）。语言无关的 Mock Server
/// 仍由 Python 版本承担，供集成测试与手动验收使用。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../fixture_support.dart';

class TestFixtureServer {
  TestFixtureServer._(this._server, this.baseUrl);

  final HttpServer _server;
  final String baseUrl;

  static const String requiredReferer = 'http://127.0.0.1:18080/';
  static const List<String> acceptedUserAgents = [
    'WebHTV-PC/0.1 (Windows)',
    'WebHTV-PC-Phase0',
  ];

  /// 记录收到的请求，供“请求捕获”契约测试断言编码方式。
  final List<CapturedRequest> captured = [];

  /// 启动服务。`port` 为 0 时由系统分配空闲端口。
  static Future<TestFixtureServer> start({int port = 0}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    final base = 'http://127.0.0.1:${server.port}';
    final fixture = TestFixtureServer._(server, base);
    unawaited(fixture._listen());
    return fixture;
  }

  Future<void> _listen() async {
    await for (final request in _server) {
      try {
        await _handle(request);
      } catch (error, stackTrace) {
        stderr.writeln(
          '[test_fixture_server] ${request.method} ${request.uri} '
          'failed: $error\n$stackTrace',
        );
        try {
          request.response.statusCode = HttpStatus.internalServerError;
          request.response.write('fixture error: $error');
        } catch (_) {
          // 连接可能已关闭。
        }
      } finally {
        try {
          await request.response.close();
        } catch (_) {
          // 客户端可能已断开（例如超限后主动取消订阅）。
        }
      }
    }
  }

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    final query = request.uri.queryParameters;
    final form = await _readForm(request);
    final parameters = {...query, ...form};
    final body = await _readBody(request);

    captured.add(
      CapturedRequest(
        method: request.method,
        path: path,
        query: query,
        form: form,
        headers: _captureHeaders(request),
        body: body,
      ),
    );

    if (path.startsWith('/media/')) {
      await _serveMedia(request, path.substring('/media/'.length));
      return;
    }
    // 弹幕 fixture（§21 Phase 3）：与媒体共用 Header 门禁，与 Python 服务一致。
    if (path.startsWith('/danmaku/')) {
      await _serveDanmaku(request, path.substring('/danmaku/'.length));
      return;
    }
    if (path.startsWith('/live/')) {
      await _serveLive(request, path.substring('/live/'.length));
      return;
    }
    if (path.startsWith('/live.') &&
        path.split('/').last.startsWith('live.')) {
      await _serveLive(request, path.substring(1));
      return;
    }
    // 解析器专用端点（§12）：webUrl 会拼接在路径后，因此用 startsWith 匹配
    // （type1/ep2 等），与 Android `url + webUrl` 语义一致。
    //   parse/type1 → `{url,data:{url}}` + UA/Referer header；
    //   parse/type1/bad →  200 但 {url:""} → parseEmpty；
    //   parse/type1/missing-url → 200 但无 url → parseEmpty；
    //   parse/type1/error → 500 → 错误归一化；
    //   parse/type1/not-json → 200 非 JSON → parseInvalid。
    //   parse/always-error → 无论后缀均 500（用于“解析服务整体不可用”场景，
    //    因为 webUrl 会被拼接到路径后，无法用固定后缀匹配）。
    if (path.startsWith('/api/parse/always-error')) {
      request.response.statusCode = HttpStatus.internalServerError;
      await _json(request, {'msg': 'parse service down'});
      return;
    }
    if (path.startsWith('/api/parse/type1')) {
      final suffix = path.substring('/api/parse/type1'.length);
      if (suffix.endsWith('/error')) {
        request.response.statusCode = HttpStatus.internalServerError;
        await _json(request, {'msg': 'parse service boom'});
        return;
      }
      if (suffix.endsWith('/not-json')) {
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.json;
        request.response.write('this is not json');
        return;
      }
      if (suffix.endsWith('/bad')) {
        await _json(request, {'url': ''});
        return;
      }
      if (suffix.endsWith('/missing-url')) {
        await _json(request, {'data': {'why': 'no url field'}});
        return;
      }
      await _json(request, {
        'url': '$baseUrl/media/sample.mp4',
        'data': {'url': '$baseUrl/media/sample.mp4'},
        'User-Agent': 'WebHTV-PC-Phase0',
        'Referer': 'http://127.0.0.1:18080/',
      });
      return;
    }
    // type=2/3 完整 Result（url/header）。
    if (path.startsWith('/api/parse/type2')) {
      await _json(request, {
        'url': '$baseUrl/media/sample.mp4',
        'header': {
          'User-Agent': 'WebHTV-PC-Phase0',
          'Referer': 'http://127.0.0.1:18080/',
        },
      });
      return;
    }
    switch (path) {
      case '/health':
        await _json(request, {'status': 'ok'});
        return;
      case '/api/echo':
        await _json(request, {
          'method': request.method,
          'params': parameters,
          'path': path,
        });
        return;
      case '/api/play':
        await _fixtureJson(request, 'http/play.json');
        return;
      // 带外挂字幕的播放结果（§10.3），与 Python fixture 服务保持一致。
      case '/api/play-with-subs':
        await _fixtureJson(request, 'http/play-with-subs.json');
        return;
      // 带弹幕源的播放结果（§21 Phase 3）。
      case '/api/play-with-danmaku':
        await _fixtureJson(request, 'http/play-with-danmaku.json');
        return;
      // 播放结果需要解析器（§12）：parse=1，验证走解析器。
      case '/api/play-parse-required':
        await _fixtureJson(request, 'http/play-parse-required.json');
        return;
      case '/api/repository-a.json':
        await _json(request, {
          'name': '仓库条目 A',
          'sites': [
            {
              'key': 'repo-a',
              'name': '仓库站点 A',
              'type': 1,
              'api': '$baseUrl/api/type1/',
              'searchable': 1,
            },
          ],
        });
        return;
      case '/api/repository-b.json':
        await _json(request, {
          'name': '仓库条目 B',
          'sites': [
            {
              'key': 'repo-b',
              'name': '仓库站点 B',
              'type': 0,
              'api': '$baseUrl/api/type0/',
            },
          ],
        });
        return;
      case '/api/repository-broken.json':
        await _json(request, {'name': '空仓库条目'});
        return;
      case '/api/repository-nested.json':
        // 条目本身仍是一个仓库：必须停止递归展开（§7.4.2）。
        await _json(request, {
          'name': '嵌套仓库条目',
          'urls': [
            {'name': '内层', 'url': '$baseUrl/api/repository-a.json'},
          ],
        });
        return;
      case '/api/msg':
        await _fixtureJson(request, 'http/result-msg.json');
        return;
      case '/api/filters':
        await _fixtureJson(request, 'http/filters.json');
        return;
      case '/api/multi-flag':
        await _fixtureJson(request, 'http/result-multi-flag.json');
        return;
      case '/api/multi-episode':
        await _fixtureJson(request, 'http/result-multi-episode.json');
        return;
      case '/api/error-html':
        request.response.statusCode = HttpStatus.badGateway;
        request.response.headers.contentType = ContentType.html;
        request.response.write(readFixture('http/error-html.html'));
        return;
      case '/api/slow':
        final delay = double.tryParse(parameters['delay'] ?? '3') ?? 3;
        await Future<void>.delayed(
          Duration(milliseconds: (delay * 1000).clamp(0, 30000).round()),
        );
        await _fixtureJson(request, 'http/home.json');
        return;
      case '/api/gzip':
        final payload = gzip.encode(utf8.encode(readFixture('config/config-min.json')));
        request.response.headers.set('Content-Encoding', 'gzip');
        request.response.headers.contentType = ContentType.json;
        request.response.add(payload);
        return;
      case '/api/br':
        // 产品侧按 Content-Encoding 处理 br；这里用 identity 返回，
        // brotli 的真实解码由 brotli 包自身的单测覆盖（见 core_protocol_test）。
        await _fixtureJson(request, 'config/config-min.json');
        return;
      case '/api/bom':
        final bytes = <int>[0xEF, 0xBB, 0xBF, ...utf8.encode(readFixture('config/config-min.json'))];
        request.response.headers.contentType = ContentType.json;
        request.response.add(bytes);
        return;
      case '/api/gbk':
        // 用 GBK 字节给出 JSON（站点名含中文），验证 charset=gbk 分支。
        final gbkBytes = _encodeGbk('{"name":"GBK 配置","sites":[{"key":"k","name":"站点","type":1,"api":"$baseUrl/api/type1/"}]}');
        request.response.headers.set('Content-Type', 'application/json; charset=gbk');
        request.response.add(gbkBytes);
        return;
      case '/api/redirect-loop':
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(HttpHeaders.locationHeader, '/api/redirect-loop');
        return;
      case '/api/redirect-to-file':
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(HttpHeaders.locationHeader, 'file:///etc/passwd');
        return;
      case '/api/oversize':
        request.response.headers.contentType = ContentType.json;
        final chunk = utf8.encode('x' * 1024 * 1024);
        for (var index = 0; index < 4; index++) {
          request.response.add(chunk);
        }
        return;
      case '/api/redirect-to-config':
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(
          HttpHeaders.locationHeader,
          '/api/type1/config.json',
        );
        return;
      case '/api/type1/config.json':
        await _fixtureJson(request, 'config/config-min.json');
        return;
    }

    final route = path.endsWith('/') ? path.substring(0, path.length - 1) : path;
    if (route == '/api/type0' ||
        route == '/api/type1' ||
        route == '/api/type2' ||
        route == '/api/type4') {
      await _serveApi(request, route, parameters);
      return;
    }

    // `webhtv-cat-http-v1` fixture（§9.4）。
    if (path.startsWith('/cathttp/')) {
      await _serveCatHttp(request, path);
      return;
    }

    request.response.statusCode = HttpStatus.notFound;
    await _json(request, {'status': 404, 'msg': 'fixture route not found'});
  }

  /// cat http fixture：三个可重复样本族（成功 / 业务错误 / 非 2xx 与未实现）。
  ///
  /// 支持两种寻址：
  /// - 扁平路由 `/cathttp/<route>`（下方 switch，供单点行为断言）；
  /// - 样本族路由 `/cathttp/<family>/<route>`，`family ∈ {ok,biz,http,unsupported}`，
  ///   用于「≥3 个可重复样本各走完整 home/search/play」的门禁（§9.4）。
  Future<void> _serveCatHttp(HttpRequest request, String path) async {
    final route = path
        .replaceFirst('/cathttp', '')
        .replaceFirst(RegExp(r'/$'), '');

    final family = RegExp(
      r'^/(ok|biz|http|unsupported|envelope|page)/(.+)$',
    ).firstMatch(route);
    if (family != null) {
      await _serveCatHttpFamily(
        request,
        family.group(1)!,
        '/${family.group(2)}',
      );
      return;
    }

    switch (route) {
      case '/init':
        await _json(request, {
          'status': 'ok',
          'abi': 'webhtv-cat-http-v1',
        });
        return;
      case '/server-error':
        request.response.statusCode = HttpStatus.badGateway;
        await _json(request, {'status': 502, 'msg': '上游网关错误'});
        return;
      case '/home':
        await _fixtureJson(request, 'cathttp/home.json');
        return;
      case '/home-envelope':
        await _fixtureJson(request, 'cathttp/home-envelope.json');
        return;
      case '/category':
        await _fixtureJson(request, 'cathttp/category.json');
        return;
      case '/detail':
        await _fixtureJson(request, 'cathttp/detail.json');
        return;
      case '/search':
        await _fixtureJson(request, 'cathttp/search.json');
        return;
      case '/search-array':
        await _fixtureJson(request, 'cathttp/search-array.json');
        return;
      case '/play':
        await _fixtureJson(request, 'cathttp/play.json');
        return;
      case '/error':
        await _fixtureJson(request, 'cathttp/result-business-error.json');
        return;
      case '/page-echo':
        await _fixtureJson(request, 'cathttp/page-echo.json');
        return;
    }
    // 未实现的 cat http 路由返回 404，必须映射为 SPIDER_UNSUPPORTED（§9.4）。
    request.response.statusCode = HttpStatus.notFound;
    await _json(request, {'status': 404, 'msg': 'cat http 路由未实现'});
  }

  /// 样本族：同一族下 home/search/play 行为一致，便于「三族各自跑完整链路」。
  Future<void> _serveCatHttpFamily(
    HttpRequest request,
    String family,
    String action,
  ) async {
    switch (family) {
      case 'ok':
        switch (action) {
          case '/init':
            await _json(request, {
              'status': 'ok',
              'abi': 'webhtv-cat-http-v1',
            });
          case '/home':
            await _fixtureJson(request, 'cathttp/home.json');
          case '/category':
            await _fixtureJson(request, 'cathttp/category.json');
          case '/detail':
            await _fixtureJson(request, 'cathttp/detail.json');
          case '/search':
            await _fixtureJson(request, 'cathttp/search.json');
          case '/play':
            await _fixtureJson(request, 'cathttp/play.json');
          default:
            request.response.statusCode = HttpStatus.notFound;
            await _json(request, {'status': 404, 'msg': 'cat http 路由未实现'});
        }
      case 'biz':
        // HTTP 200 + 业务错误信封：必须映射为业务错误，不得空列表化（§9.4）。
        await _fixtureJson(request, 'cathttp/result-business-error.json');
      case 'envelope':
        // `{code:0,data}` 信封与顶层数组形态（§9.4 解包规则）。
        switch (action) {
          case '/home':
            await _fixtureJson(request, 'cathttp/home-envelope.json');
          case '/search':
            await _fixtureJson(request, 'cathttp/search-array.json');
          case '/play':
            await _fixtureJson(request, 'cathttp/play.json');
          default:
            request.response.statusCode = HttpStatus.notFound;
            await _json(request, {'status': 404, 'msg': 'cat http 路由未实现'});
        }
      case 'page':
        // page 兜底回显：服务端能看到客户端实际发出的 page。
        await _fixtureJson(request, 'cathttp/page-echo.json');
      case 'http':
        request.response.statusCode = HttpStatus.badGateway;
        await _json(request, {'status': 502, 'msg': '上游网关错误'});
      default:
        request.response.statusCode = HttpStatus.notFound;
        await _json(request, {'status': 404, 'msg': 'cat http 路由未实现'});
    }
  }

  Future<void> _serveApi(
    HttpRequest request,
    String route,
    Map<String, String> parameters,
  ) async {
    if (parameters.containsKey('wd')) {
      await _fixtureJson(request, 'http/category.json');
      return;
    }
    if (parameters.containsKey('ids')) {
      if (route == '/api/type0') {
        request.response.headers.contentType = ContentType('application', 'xml', charset: 'utf-8');
        request.response.write(_xmlDetail);
        return;
      }
      if (parameters['ids'] == 'multi-1') {
        await _fixtureJson(request, 'http/result-multi-flag.json');
        return;
      }
      if (parameters['ids'] == 'episodes-1') {
        await _fixtureJson(request, 'http/result-multi-episode.json');
        return;
      }
      if (parameters['ids'] == 'msg-1') {
        await _fixtureJson(request, 'http/result-msg.json');
        return;
      }
      await _fixtureJson(request, 'http/detail.json');
      return;
    }
    if (parameters.containsKey('t')) {
      await _fixtureJson(request, 'http/category.json');
      return;
    }
    if (route == '/api/type0') {
      request.response.headers.contentType = ContentType('application', 'xml', charset: 'utf-8');
      request.response.write(_xmlHome);
      return;
    }
    await _fixtureJson(request, 'http/home.json');
  }

  static const String _xmlHome = '''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0">
  <class id="1">电影</class>
  <class id="2">电视剧</class>
  <list id="demo-1">
    <name>XML 测试视频</name>
    <note>第 1 集</note>
    <pic></pic>
    <dt>第 1 集\$http://127.0.0.1:18080/media/sample.m3u8</dt>
  </list>
</rss>''';

  static const String _xmlDetail = '''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0">
  <list id="demo-1">
    <name>XML 测试视频</name>
    <note>第 1 集</note>
    <pic></pic>
    <des>仅用于本地契约验证</des>
    <year>2026</year>
    <area>大陆</area>
    <dt>第 1 集\$http://127.0.0.1:18080/media/sample.m3u8#第 2 集\$http://127.0.0.1:18080/media/sample.mp4</dt>
  </list>
</rss>''';

  static Map<String, String> _captureHeaders(HttpRequest request) {
    final captured = <String, String>{};
    request.headers.forEach((name, values) {
      captured[name.toLowerCase()] = values.join(', ');
    });
    return captured;
  }

  Future<Map<String, String>> _readForm(HttpRequest request) async {
    final contentType = request.headers.contentType;
    if (contentType == null ||
        contentType.mimeType != 'application/x-www-form-urlencoded') {
      return const {};
    }
    final body = await utf8.decoder.bind(request).join();
    return Uri.splitQueryString(body);
  }

  Future<String> _readBody(HttpRequest request) async {
    // 表单已在 _readForm 中读取；这里只处理其他 body。
    return '';
  }

  /// 返回 fixture 文件，并把其中的 18080 端口替换为实际测试端口。
  Future<void> _fixtureJson(
    HttpRequest request,
    String relative,
  ) async {
    final text = readFixture(relative)
        .replaceAll('http://127.0.0.1:18080', baseUrl);
    request.response.headers.contentType = ContentType(
      'application',
      'json',
      charset: 'utf-8',
    );
    request.response.add(utf8.encode(text));
  }

  Future<void> _json(HttpRequest request, Object value) async {
    request.response.headers.contentType = ContentType(
      'application',
      'json',
      charset: 'utf-8',
    );
    request.response.add(utf8.encode(jsonEncode(value)));
  }

  /// 直播清单 fixture（§13.3）：重放 `packages/test-fixtures/live/`。
  Future<void> _serveLive(HttpRequest request, String relative) async {
    final candidate = p.normalize(p.join(fixturePath('live'), relative));
    final root = p.normalize(fixturePath('live'));
    if (!p.isWithin(root, candidate)) {
      request.response.statusCode = HttpStatus.notFound;
      await _json(request, {'status': 404, 'msg': 'live fixture not found'});
      return;
    }
    final file = File(candidate);
    if (!await file.exists()) {
      request.response.statusCode = HttpStatus.notFound;
      await _json(request, {'status': 404, 'msg': 'live fixture not found'});
      return;
    }
    final bytes = await file.readAsBytes();
    request.response.headers.contentType = ContentType(
      'audio',
      'x-mpegurl',
      charset: 'utf-8',
    );
    request.response.add(bytes);
  }

  /// 弹幕文件与媒体同样要求 Referer/UA：弹幕常与视频同源，必须验证这一点。
  Future<void> _serveDanmaku(HttpRequest request, String relative) async {
    final referer = request.headers.value('referer');
    final userAgent = request.headers.value('user-agent');
    if (referer != requiredReferer || !acceptedUserAgents.contains(userAgent)) {
      request.response.statusCode = HttpStatus.forbidden;
      await _json(request, {'status': 403, 'msg': 'header requirement not met'});
      return;
    }
    final candidate = File(p.join(fixturePath('danmaku'), relative));
    if (!candidate.existsSync()) {
      request.response.statusCode = HttpStatus.notFound;
      await _json(request, {'status': 404});
      return;
    }
    final bytes = candidate.readAsBytesSync();
    request.response.headers.set(
      HttpHeaders.contentTypeHeader,
      candidate.path.endsWith('.xml')
          ? 'application/xml; charset=utf-8'
          : 'text/plain; charset=utf-8',
    );
    request.response.headers.set(HttpHeaders.contentLengthHeader, '${bytes.length}');
    request.response.add(bytes);
  }

  Future<void> _serveMedia(HttpRequest request, String relative) async {
    final referer = request.headers.value('referer');
    final userAgent = request.headers.value('user-agent');
    if (referer != requiredReferer || !acceptedUserAgents.contains(userAgent)) {
      request.response.statusCode = HttpStatus.forbidden;
      await _json(request, {'status': 403, 'msg': 'header requirement not met'});
      return;
    }
    final candidate = File(p.join(fixturePath('media'), relative));
    if (!candidate.existsSync()) {
      request.response.statusCode = HttpStatus.notFound;
      await _json(request, {'status': 404});
      return;
    }
    final bytes = candidate.readAsBytesSync();
    // 与 Python fixture 服务一致：SubRip 用自己的 MIME，而非 text/plain。
    if (candidate.path.endsWith('.srt')) {
      request.response.headers.set(
        HttpHeaders.contentTypeHeader,
        'application/x-subrip; charset=utf-8',
      );
    } else {
      request.response.headers.contentType = ContentType.binary;
    }
    request.response.headers.set(HttpHeaders.contentLengthHeader, '${bytes.length}');
    request.response.add(bytes);
  }

  /// 最小 GBK 编码：只需覆盖 fixture 用到的中文与 ASCII 字符。
  List<int> _encodeGbk(String text) {
    final bytes = <int>[];
    for (final rune in text.runes) {
      if (rune < 0x80) {
        bytes.add(rune);
        continue;
      }
      final pair = _gbkTable[rune];
      if (pair == null) {
        bytes.addAll([0x3F]); // '?'
      } else {
        bytes.addAll(pair);
      }
    }
    return bytes;
  }

  static const Map<int, List<int>> _gbkTable = {
    0x4E2D: [0xD6, 0xD0], // 中
    0x6587: [0xCE, 0xC4], // 文
    0x914D: [0xC5, 0xE4], // 配
    0x7F6E: [0xD6, 0xC3], // 置
    0x7AD9: [0xD5, 0xBE], // 站
    0x70B9: [0xB5, 0xE3], // 点
  };

  /// 关闭服务并等待端口释放。
  Future<void> stop() async {
    await _server.close(force: true);
  }
}

/// 一次被捕获的请求。
class CapturedRequest {
  const CapturedRequest({
    required this.method,
    required this.path,
    required this.query,
    required this.form,
    required this.headers,
    required this.body,
  });

  final String method;
  final String path;
  final Map<String, String> query;
  final Map<String, String> form;
  final Map<String, String> headers;
  final String body;

  /// 全部参数（query 与 form 合并），用于断言“参数存在且编码方式正确”。
  Map<String, String> get parameters => {...query, ...form};

  bool get usedFormBody => form.isNotEmpty;
}
