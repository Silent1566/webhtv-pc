/// 真实浏览器嗅探测试的离线夹具站点（纯 `dart:io`，端口 0）。
///
/// 为什么需要这个夹具：`type=0`/`type=4` 的地址是解析页自己用 JS 算出来并
/// 请求的，假传输只能复述 CDP 事件形状；只有让真 Chromium 跑起来，才能验证
/// 「页面脚本 → 网络请求 → CDP 事件 → 媒体判定」整条链路。
///
/// 每个页面被测的行为各自独立，互不复用：
/// - `/parse/xhr`：`fetch('/sig')` 成功后 XHR 请求 `/vod/master.m3u8?t=1`；
/// - `/parse/click`：只有点击 `#play` 才 XHR 请求 `/vod/click.m3u8`；
/// - `/parse/challenge`：Cloudflare 风格标题/正文，1.5s 后仍请求
///   `/vod/after-challenge.m3u8`；
/// - `/parse/slow`：只加载页面，永不产出媒体请求（超时用例）；
/// - `/parse/rule`：XHR 请求**无后缀**路径 `/hs/abcdef0123456789`，只有配置
///   规则能命中；
/// - `/json-broken`：非 JSON 响应（Super 的失败 JSON 腿）。
///
/// 服务端记录每个请求的路径与 UA/Referer，供请求头注入断言。
library;

import 'dart:io';

/// 夹具服务端收到的一条请求。
class SniffFixtureRequest {
  const SniffFixtureRequest({
    required this.path,
    required this.query,
    required this.userAgent,
    required this.referer,
  });

  /// 请求路径（不含 query）。
  final String path;

  /// 原始 query（无则空串）。
  final String query;

  /// `User-Agent` 请求头原值。
  final String? userAgent;

  /// `Referer` 请求头原值。
  final String? referer;

  /// 人类可读的路径 + query。
  String get url => query.isEmpty ? path : '$path?$query';

  @override
  String toString() => 'SniffFixtureRequest($url, ua=$userAgent, referer=$referer)';
}

/// 便携夹具站点：`start()` 绑定随机端口，`close()` 释放。
class SniffFixtureServer {
  SniffFixtureServer._(this._server);

  final HttpServer _server;
  final List<SniffFixtureRequest> _requests = [];

  /// 绑定 127.0.0.1:0 并开始接收请求。
  static Future<SniffFixtureServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fixture = SniffFixtureServer._(server);
    server.listen(fixture._handle);
    return fixture;
  }

  int get port => _server.port;

  /// `http://127.0.0.1:<port>`。
  String get origin => 'http://127.0.0.1:$port';

  /// 拼一个夹具地址。
  String url(String path) => '$origin$path';

  /// 全部已记录请求（按到达顺序）。
  List<SniffFixtureRequest> get requests => List<SniffFixtureRequest>.unmodifiable(_requests);

  /// 路径 + query 含 [needle] 的请求。
  List<SniffFixtureRequest> requestsTo(String needle) =>
      _requests.where((request) => request.url.contains(needle)).toList(growable: false);

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    _requests.add(
      SniffFixtureRequest(
        path: path,
        query: request.uri.query,
        userAgent: request.headers.value(HttpHeaders.userAgentHeader),
        referer: request.headers.value(HttpHeaders.refererHeader),
      ),
    );
    final response = request.response;
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    if (path.startsWith('/vod/')) {
      response.headers.contentType = ContentType.parse('application/vnd.apple.mpegurl');
      response.write('#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:6\n');
    } else {
      switch (path) {
        case '/parse/xhr':
          _html(response, _xhrPage);
        case '/parse/click':
          _html(response, _clickPage);
        case '/parse/challenge':
          _html(response, _challengePage);
        case '/parse/slow':
          _html(response, _slowPage);
        case '/parse/rule':
          _html(response, _rulePage);
        case '/sig':
          response.headers.contentType = ContentType.json;
          response.write('{"ok":true}');
        case '/json-broken':
          _html(response, '<html>not json</html>');
        default:
          response.statusCode = HttpStatus.notFound;
          response.write('fixture 没有这个路由：$path');
      }
    }
    await response.close();
  }

  static void _html(HttpResponse response, String body) {
    response.headers.contentType = ContentType.html;
    response.write(body);
  }
}

/// `fetch('/sig')` 成功后 XHR 一个带 query 的 m3u8。
const String _xhrPage = '''
<!doctype html>
<html><head><meta charset="utf-8"><title>xhr fixture</title></head>
<body>
<script>
  fetch('/sig').then(function () {
    var xhr = new XMLHttpRequest();
    xhr.open('GET', '/vod/master.m3u8?t=1');
    xhr.send();
  });
</script>
</body></html>
''';

/// 只有点击 `#play` 才产出媒体请求。
const String _clickPage = '''
<!doctype html>
<html><head><meta charset="utf-8"><title>click fixture</title></head>
<body>
<button id="play">play</button>
<script>
  document.getElementById('play').addEventListener('click', function () {
    var xhr = new XMLHttpRequest();
    xhr.open('GET', '/vod/click.m3u8');
    xhr.send();
  });
</script>
</body></html>
''';

/// Cloudflare 风格人机校验页：标题与正文都命中校验标记，1.5s 后仍发媒体请求。
const String _challengePage = '''
<!doctype html>
<html><head><meta charset="utf-8"><title>Just a moment...</title></head>
<body>
<h1>Just a moment...</h1>
<p>Verify you are human by completing the action below.</p>
<script>
  setTimeout(function () {
    var xhr = new XMLHttpRequest();
    xhr.open('GET', '/vod/after-challenge.m3u8');
    xhr.send();
  }, 1500);
</script>
</body></html>
''';

/// 永不产出媒体请求：只做一次无关的资源请求。
const String _slowPage = '''
<!doctype html>
<html><head><meta charset="utf-8"><title>slow fixture</title></head>
<body>
<script>
  fetch('/sig');
</script>
</body></html>
''';

/// 无后缀媒体地址：默认后缀判定抓不到，只有配置规则能命中。
const String _rulePage = '''
<!doctype html>
<html><head><meta charset="utf-8"><title>rule fixture</title></head>
<body>
<script>
  var xhr = new XMLHttpRequest();
  xhr.open('GET', '/hs/abcdef0123456789');
  xhr.send();
</script>
</body></html>
''';
