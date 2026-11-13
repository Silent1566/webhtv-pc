/// 真浏览器冒烟测试：用系统 Chromium 内核跑一个「页面脚本请求 m3u8」的站点，
/// 断言 CDP 网络事件里能看见那条请求。
///
/// 为什么要真浏览器：这条链路上「定位 → 启动 → DevToolsActivePort → CDP →
/// flatten session → 事件」任何一环断了都只在真实进程里表现出来，假服务无法证明。
/// 本机没有可用浏览器时跳过——它是能力探测，不是失败。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/sniff/browser_process.dart';
import 'package:webhtv_pc/core/sniff/default_sniff_transport.dart';
import 'package:webhtv_pc/core/sniff/sniff_transport.dart';

const String _parsePage = '''
<!doctype html>
<html><head><meta charset="utf-8"><title>sniff smoke</title></head>
<body><script>
  fetch('/sig').then(function () {
    var xhr = new XMLHttpRequest();
    xhr.open('GET', '/stream.m3u8');
    xhr.send();
  });
</script></body></html>
''';

void main() {
  test('真实浏览器：页面脚本请求的 m3u8 出现在 CDP 网络事件里', () async {
    const transport = DefaultSniffTransport();
    // 「存在且可执行」不等于可用（snap 包装脚本在受限环境里起不来）：
    // 按真实可用性挑第一个，缺浏览器时如实 skip。
    BrowserCommand? command;
    for (final candidate in await transport.locateAll()) {
      if (await transport.probe(candidate) == null) {
        command = candidate;
        break;
      }
    }
    if (command == null) {
      markTestSkipped('本机没有可用的 Chromium 内核浏览器（可用 WEBHTV_SNIFF_BROWSER 指定）');
      return;
    }

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final response = request.response;
      switch (request.uri.path) {
        case '/parse':
          response.headers.contentType = ContentType.html;
          response.write(_parsePage);
        case '/sig':
          response.headers.contentType = ContentType.json;
          response.write('{}');
        case '/stream.m3u8':
          response.headers.contentType = ContentType.parse(
            'application/vnd.apple.mpegurl',
          );
          response.write('#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:10\n');
        default:
          response.statusCode = HttpStatus.notFound;
      }
      await response.close();
    });

    BrowserSession? session;
    CdpConnection? connection;
    try {
      session = await transport.launch(
        command,
        headless: true,
        readyTimeout: const Duration(seconds: 30),
      );
      connection = await transport.connect(
        session.webSocketUrl,
        timeout: const Duration(seconds: 20),
      );

      final target = await connection.send(
        'Target.createTarget',
        params: {'url': 'about:blank'},
      );
      final targetId = target['targetId'] as String;

      final attached = await connection.send(
        'Target.attachToTarget',
        params: {'targetId': targetId, 'flatten': true},
      );
      final sessionId = attached['sessionId'] as String;

      await connection.send('Network.enable', sessionId: sessionId);
      await connection.send('Page.enable', sessionId: sessionId);

      // 先挂监听再导航：requestWillBeSent 会在导航命令返回前就发出。
      final mediaRequest = connection.events
          .firstWhere(
            (event) =>
                event.method == 'Network.requestWillBeSent' &&
                _requestUrl(event)?.contains('/stream.m3u8') == true,
          )
          .timeout(const Duration(seconds: 30));

      final pageUrl = 'http://127.0.0.1:${server.port}/parse';
      await connection.send(
        'Page.navigate',
        params: {'url': pageUrl},
        sessionId: sessionId,
      );

      final event = await mediaRequest;
      final url = _requestUrl(event);
      expect(url, contains('/stream.m3u8'));
      expect(event.sessionId, sessionId);
    } finally {
      await connection?.close();
      if (session is ChromiumBrowserProcess) {
        final profile = session.profileDirectory;
        await session.close();
        expect(
          Directory(profile).existsSync(),
          isFalse,
          reason: 'close() 必须删除临时 profile 目录',
        );
      } else {
        await session?.close();
      }
      await server.close(force: true);
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}

String? _requestUrl(CdpEvent event) {
  final request = event.params['request'];
  if (request is! Map) return null;
  final url = request['url'];
  return url is String ? url : null;
}
