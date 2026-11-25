/// Managed-session proxy seam (real loopback HTTP; supplied port is a verified fake forward).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/proxy_policy.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/proxy_server.dart';
import 'package:webhtv_pc/services/tolerant_http_reader.dart';
import 'package:xml/xml.dart';

void main() {
  late _Upstream upstream;
  late LocalProxyServer proxy;
  late List<Uri> calls;
  late ProxySession session;

  Future<int?> resolver(Uri target) async {
    calls.add(target);
    if (target.scheme == 'http' &&
        (target.host == 'guest.local' || target.host == 'other.local') &&
        target.port == 5000) {
      return upstream.port;
    }
    return null;
  }

  setUp(() async {
    upstream = await _Upstream.start();
    calls = <Uri>[];
    proxy = LocalProxyServer(log: LogService());
    await proxy.start();
    session = proxy.sessions.create(
      siteKey: 'managed',
      targetResolver: resolver,
    );
  });

  tearDown(() async {
    await proxy.stop();
    await upstream.stop();
  });

  test(
    'managed session maps top path/query and preserves Range and UA',
    () async {
      final response = await _get(
        proxy.urlFor(
          session,
          Uri.parse('http://guest.local:5000/media.bin?sign=a%2Bb'),
        ),
        range: 'bytes=0-9',
        userAgent: 'ManagedPlayer/1',
      );
      expect(response.status, 206);
      expect(utf8.decode(response.body), '0123456789');
      expect(
        response.headers.value(HttpHeaders.contentRangeHeader),
        'bytes 0-9/1024',
      );
      expect(calls.single.path, '/media.bin');
      expect(calls.single.query, 'sign=a%2Bb');
      expect(upstream.hits.last['range'], 'bytes=0-9');
      expect(upstream.hits.last['user-agent'], 'ManagedPlayer/1');
    },
  );

  test(
    'HLS children from guest logical names are tokenized and fetched',
    () async {
      final response = await _get(
        proxy.urlFor(
          session,
          Uri.parse('http://guest.local:5000/live/index.m3u8'),
        ),
      );
      expect(response.status, 200);
      final body = utf8.decode(response.body);
      expect(body, contains('/p/${session.token}/'));
      expect(body, isNot(contains('http://guest.local:5000/abs.ts')));
      final urls = _httpUrls(body).toSet();
      expect(urls, isNotEmpty);
      for (final url in urls) {
        final child = await _get(url);
        expect(child.status, 200, reason: url);
      }
      expect(
        calls.map((uri) => uri.path).toSet(),
        containsAll(<String>[
          '/live/index.m3u8',
          '/live/seg-1.ts',
          '/live/abs.ts',
          '/live/key.bin',
        ]),
      );
    },
  );

  test('redirected HLS resolves children from final logical current', () async {
    final response = await _get(
      proxy.urlFor(
        session,
        Uri.parse('http://guest.local:5000/dir/index.m3u8'),
      ),
    );
    expect(response.status, 200);
    final child = await _get(_httpUrls(utf8.decode(response.body)).single);
    expect(child.status, 200);
    expect(calls.map((uri) => uri.path), contains('/other/seg.ts'));
    expect(calls.map((uri) => uri.path), isNot(contains('/dir/seg.ts')));
  });

  test(
    'mapped redirect keeps credentials only on the logical origin',
    () async {
      final cookieSession = proxy.sessions.create(
        siteKey: 'managed-cookie',
        cookie: 'sid=GUEST',
        targetResolver: resolver,
      );
      final response = await _get(
        proxy.urlFor(
          cookieSession,
          Uri.parse('http://guest.local:5000/redirect'),
        ),
      );
      expect(response.status, 200);
      expect(upstream.hits.first['cookie'], 'sid=GUEST');
      expect(upstream.hits.last['cookie'], isEmpty);
    },
  );

  test(
    'DASH base and templates stay tokenized and player-expandable',
    () async {
      final response = await _get(
        proxy.urlFor(
          session,
          Uri.parse('http://guest.local:5000/dash/manifest.mpd'),
        ),
      );
      expect(response.status, 200);
      expect(response.headers.contentType?.mimeType, 'application/dash+xml');
      final body = utf8.decode(response.body);
      expect(body, isNot(contains('http://guest.local:5000')));
      expect(response.headers.value(HttpHeaders.contentRangeHeader), isNull);
      expect(response.headers.value(HttpHeaders.cacheControlHeader), isNull);
      expect(response.headers.contentLength, response.body.length);
      final document = XmlDocument.parse(body);
      expect(
        document.rootElement.namespaceUri,
        'urn:mpeg:dash:schema:mpd:2011',
      );
      final base = document.findAllElements('BaseURL').single.innerText;
      expect(
        base,
        startsWith('http://127.0.0.1:${proxy.port}/p/${session.token}/d/'),
      );
      expect(base, endsWith('/'));
      final templates = document
          .findAllElements('SegmentTemplate')
          .map((element) => element.getAttribute('media') ?? '')
          .toList();
      expect(
        templates.any((value) => value.endsWith(r'seg-$Number$.m4s')),
        isTrue,
      );
      final absolute = templates[1];
      expect(absolute, endsWith(r'seg-$Number$.m4s'));
      expect(absolute, isNot(contains('guest.local')));

      final segment = await _get('${base}seg-1.m4s');
      expect(segment.status, 200);
      expect(calls.map((uri) => uri.path), contains('/dash/seg-1.m4s'));
      final abs = await _get(absolute.replaceAll(r'$Number$', '7'));
      expect(abs.status, 200);
      expect(calls.map((uri) => uri.path), contains('/abs/seg-7.m4s'));
    },
  );

  test(
    'DASH file BaseURL resolves Initialization against its directory',
    () async {
      final response = await _get(
        proxy.urlFor(
          session,
          Uri.parse('http://guest.local:5000/dash/filebase.mpd'),
        ),
      );
      expect(response.status, 200);
      final document = XmlDocument.parse(utf8.decode(response.body));
      final base = document.findAllElements('BaseURL').single.innerText;
      expect(base, contains('/d/'));
      final init = document
          .findAllElements('Initialization')
          .single
          .getAttribute('sourceURL')!;
      expect(init, isNot(contains('video.mp4/init.mp4')));
      final child = await _get(init);
      expect(child.status, 200);
      expect(calls.map((uri) => uri.path), contains('/dash/init.mp4'));
      expect(
        calls.map((uri) => uri.path),
        isNot(contains('/dash/video.mp4/init.mp4')),
      );
    },
  );

  test('DASH forbidden response remains an error entity', () async {
    final response = await _get(
      proxy.urlFor(session, Uri.parse('http://guest.local:5000/forbidden.mpd')),
    );
    expect(response.status, 403);
    expect(utf8.decode(response.body), 'forbidden');
  });

  test('invalid token is rejected before resolver invocation', () async {
    final valid = proxy.urlFor(
      session,
      Uri.parse('http://guest.local:5000/media.bin'),
    );
    final response = await _get(
      valid.replaceFirst('/p/${session.token}/', '/p/forged/'),
    );
    expect(response.status, 401);
    expect(calls, isEmpty);
  });

  test('token revoked while resolver awaits cannot open upstream', () async {
    final started = Completer<void>();
    final gate = Completer<int?>();
    final revocable = proxy.sessions.create(
      siteKey: 'managed-race',
      targetResolver: (target) {
        started.complete();
        return gate.future;
      },
    );
    final pending = _get(
      proxy.urlFor(revocable, Uri.parse('http://guest.local:5000/media.bin')),
    );
    await started.future;
    proxy.sessions.revoke(revocable.token);
    gate.complete(upstream.port);
    final response = await pending;
    expect(response.status, 401);
    expect(upstream.hits, isEmpty);
  });

  test('invalid mapped ports and self recursion fail closed', () async {
    for (final port in <int>[0, -1, 70000, proxy.port]) {
      final bad = proxy.sessions.create(
        siteKey: 'managed-bad-port',
        targetResolver: (target) async => port,
      );
      final response = await _get(
        proxy.urlFor(bad, Uri.parse('http://guest.local:5000/media.bin')),
      );
      expect(response.status, 502, reason: 'port=$port');
    }
    expect(upstream.hits, isEmpty);
  });

  test('HEAD is forwarded without downloading media bytes', () async {
    final response = await _get(
      proxy.urlFor(session, Uri.parse('http://guest.local:5000/media.bin')),
      head: true,
    );
    expect(response.status, 200);
    expect(response.body, isEmpty);
    expect(upstream.hits.last['method'], 'HEAD');
  });

  test('link-local unknown target is denied without resolver bypass', () async {
    final response = await _get(
      proxy.urlFor(session, Uri.parse('http://169.254.1.1/latest')),
    );
    expect(response.status, 403);
  });

  test(
    'unknown origin falls back to ordinary denial; metadata never resolves',
    () async {
      final nullSession = proxy.sessions.create(
        siteKey: 'managed-null',
        targetResolver: resolver,
      );
      final denied = await _get(
        proxy.urlFor(
          nullSession,
          Uri.parse('http://127.0.0.1:${upstream.port}/media.bin'),
        ),
      );
      expect(denied.status, 403);
      calls.clear();
      final metadata = await _get(
        proxy.urlFor(nullSession, Uri.parse('http://169.254.169.254/latest')),
      );
      expect(metadata.status, 403);
      expect(calls, isEmpty);
    },
  );

  group('managed tolerant framing retry', () {
    test('duplicate identical Content-Length is served byte-exact', () async {
      final raw = await _RawUpstream.start(
        'HTTP/1.1 206 Partial Content\r\n'
        'Content-Length: 10\r\n'
        'Content-Length: 10\r\n'
        'Content-Range: bytes 0-9/1024\r\n'
        'Content-Range: bytes 0-9/1024\r\n'
        'Content-Type: video/mp4\r\n'
        'accept-ranges: bytes\r\n'
        'accept-ranges: bytes\r\n'
        '\r\n'
        '0123456789',
      );
      addTearDown(raw.stop);
      final managed = proxy.sessions.create(
        siteKey: 'managed-tolerant',
        userAgent: 'ManagedPlayer/1',
        targetResolver: (target) async =>
            target.host == 'guest.local' ? raw.port : null,
      );
      final response = await _get(
        proxy.urlFor(
          managed,
          Uri.parse('http://guest.local:5000/media.bin?sign=a%2Bb'),
        ),
        range: 'bytes=0-9',
      );
      expect(response.status, 206);
      expect(utf8.decode(response.body), '0123456789');
      expect(
        response.headers.value(HttpHeaders.contentRangeHeader),
        'bytes 0-9/1024',
      );
      expect(raw.connections, 2);
      await _waitFor(() => raw.requests.length == 2);
      for (final request in raw.requests) {
        expect(
          request.split('\r\n').first,
          'GET /media.bin?sign=a%2Bb HTTP/1.1',
        );
      }
      final retried = raw.requests.last.toLowerCase();
      expect(retried, contains('range: bytes=0-9'));
      expect(retried, contains('user-agent: managedplayer/1'));
      expect(retried, contains('accept-encoding: identity'));
      expect('host:'.allMatches(retried).length, 1);
    });

    test('duplicate differing Content-Length fails closed honestly', () async {
      final raw = await _RawUpstream.start(
        'HTTP/1.1 206 Partial Content\r\n'
        'Content-Length: 1024\r\n'
        'Content-Length: 2048\r\n'
        'Content-Type: video/mp4\r\n'
        '\r\n',
      );
      addTearDown(raw.stop);
      final log = LogService();
      final quietProxy = LocalProxyServer(log: log);
      addTearDown(quietProxy.stop);
      await quietProxy.start();
      final managed = quietProxy.sessions.create(
        siteKey: 'managed-framing',
        targetResolver: (target) async => raw.port,
      );
      final response = await _get(
        quietProxy.urlFor(
          managed,
          Uri.parse('http://guest.local:5000/media.bin?sign=SECRET_SIGNATURE'),
        ),
      );
      expect(response.status, 502);
      final body = utf8.decode(response.body);
      expect(jsonDecode(body), {
        'status': 502,
        'msg': UpstreamFramingFailure.message,
      });
      expect(body, isNot(contains('1024')));
      expect(body, isNot(contains('2048')));
      final diagnostics = log.entries
          .where((entry) => entry.scope == 'proxy')
          .map((entry) => entry.message)
          .where((message) => message.contains('Content-Length'))
          .toList();
      expect(diagnostics, hasLength(1));
      expect(diagnostics.single, isNot(contains('SECRET_SIGNATURE')));
      expect(diagnostics.single, isNot(contains('1024')));
      expect(diagnostics.single, isNot(contains('2048')));
    });

    test('non-managed session never uses the tolerant reader', () async {
      final raw = await _RawUpstream.start(
        'HTTP/1.1 200 OK\r\n'
        'Content-Length: 2\r\n'
        'Content-Length: 2\r\n'
        '\r\n'
        'ok',
      );
      addTearDown(raw.stop);
      final plainProxy = LocalProxyServer(
        log: LogService(),
        policy: const ProxyTargetPolicy(allowLoopback: true),
      );
      addTearDown(plainProxy.stop);
      await plainProxy.start();
      final plain = plainProxy.sessions.create(siteKey: 'plain');
      final response = await _get(
        plainProxy.urlFor(
          plain,
          Uri.parse('http://127.0.0.1:${raw.port}/media.bin'),
        ),
      );
      expect(response.status, 502);
      // 不透明文案已经让步于可定位文案；但非受管会话没有容错重试（连接数仍是 1）。
      expect(jsonDecode(utf8.decode(response.body)), {
        'status': 502,
        'msg': UpstreamFramingFailure.message,
      });
      expect(raw.connections, 1);
    });

    test('tolerant path still accounts the session byte quota', () async {
      final body = List<int>.generate(1024, (index) => 48 + index % 10);
      final raw = await _RawUpstream.start(
        'HTTP/1.1 206 Partial Content\r\n'
        'Content-Length: 1024\r\n'
        'Content-Length: 1024\r\n'
        'Content-Range: bytes 0-1023/1024\r\n'
        '\r\n'
        '${latin1.decode(body)}',
      );
      addTearDown(raw.stop);
      final managed = proxy.sessions.create(
        siteKey: 'managed-quota',
        maxBytes: 100,
        targetResolver: (target) async => raw.port,
      );
      final response = await _get(
        proxy.urlFor(managed, Uri.parse('http://guest.local:5000/media.bin')),
      );
      expect(response.status, 429);
      expect(utf8.decode(response.body), contains('会话累计流量或请求数超过上限'));
      expect(raw.connections, 2);
    });

    test(
      'tolerant path refuses manifest responses instead of leaking',
      () async {
        final raw = await _RawUpstream.start(
          'HTTP/1.1 200 OK\r\n'
          'Content-Length: 24\r\n'
          'Content-Length: 24\r\n'
          'Content-Type: application/vnd.apple.mpegurl\r\n'
          '\r\n'
          '#EXTM3U\n#EXT-X-ENDLIST\n',
        );
        addTearDown(raw.stop);
        final managed = proxy.sessions.create(
          siteKey: 'managed-manifest',
          targetResolver: (target) async => raw.port,
        );
        final response = await _get(
          proxy.urlFor(managed, Uri.parse('http://guest.local:5000/live.m3u8')),
        );
        expect(response.status, 502);
        final body = utf8.decode(response.body);
        expect(body, contains('清单'));
        expect(body, isNot(contains('EXTM3U')));
      },
    );

    test('tolerant path never follows a 3xx', () async {
      final raw = await _RawUpstream.start(
        'HTTP/1.1 302 Found\r\n'
        'Content-Length: 0\r\n'
        'Content-Length: 0\r\n'
        'Location: http://guest.local:5000/next.m3u8\r\n'
        '\r\n',
      );
      addTearDown(raw.stop);
      final managed = proxy.sessions.create(
        siteKey: 'managed-redirect',
        targetResolver: (target) async => raw.port,
      );
      final response = await _get(
        proxy.urlFor(managed, Uri.parse('http://guest.local:5000/start.bin')),
      );
      expect(response.status, 502);
      expect(utf8.decode(response.body), contains('重定向'));
      expect(raw.connections, 2);
    });

    test('HEAD on the tolerant path returns headers only', () async {
      final raw = await _RawUpstream.start(
        'HTTP/1.1 200 OK\r\n'
        'Content-Length: 1024\r\n'
        'Content-Length: 1024\r\n'
        'Content-Type: video/mp4\r\n'
        '\r\n',
      );
      addTearDown(raw.stop);
      final managed = proxy.sessions.create(
        siteKey: 'managed-head',
        targetResolver: (target) async => raw.port,
      );
      final response = await _get(
        proxy.urlFor(managed, Uri.parse('http://guest.local:5000/media.bin')),
        head: true,
      );
      expect(response.status, 200);
      expect(response.body, isEmpty);
      expect(response.headers.contentLength, 1024);
      await _waitFor(() => raw.requests.length == 2);
      for (final request in raw.requests) {
        expect(request.split('\r\n').first, 'HEAD /media.bin HTTP/1.1');
      }
    });
  });
}

class _Response {
  const _Response(this.status, this.headers, this.body);
  final int status;
  final HttpHeaders headers;
  final List<int> body;
}

Future<_Response> _get(
  String url, {
  String? range,
  String? userAgent,
  bool head = false,
}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(head ? 'HEAD' : 'GET', Uri.parse(url));
    if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
    if (userAgent != null) {
      request.headers.set(HttpHeaders.userAgentHeader, userAgent);
    }
    final response = await request.close();
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response) {
      bytes.add(chunk);
    }
    return _Response(response.statusCode, response.headers, bytes.takeBytes());
  } finally {
    client.close(force: true);
  }
}

List<String> _httpUrls(String text) =>
    RegExp(r'https?://[^\s"<>]+')
        .allMatches(text)
        .map((match) => match.group(0)!)
        .toList();

class _Upstream {
  _Upstream._(this._server);
  final HttpServer _server;
  final List<Map<String, String>> hits = [];
  int get port => _server.port;
  static const int guestPort = 5000;

  static Future<_Upstream> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final upstream = _Upstream._(server);
    unawaited(upstream._listen());
    return upstream;
  }

  Future<void> stop() => _server.close(force: true);

  Future<void> _listen() async {
    await for (final request in _server) {
      try {
        await _respond(request);
      } finally {
        try {
          await request.response.close();
        } catch (_) {}
      }
    }
  }

  Future<void> _respond(HttpRequest request) async {
    hits.add({
      'user-agent': request.headers.value(HttpHeaders.userAgentHeader) ?? '',
      'range': request.headers.value(HttpHeaders.rangeHeader) ?? '',
      'cookie': request.headers.value(HttpHeaders.cookieHeader) ?? '',
      'method': request.method,
    });
    final path = request.uri.path;
    if (path == '/media.bin') {
      final all = List<int>.generate(1024, (index) => 48 + index % 10);
      if (request.headers.value(HttpHeaders.rangeHeader) == 'bytes=0-9') {
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes 0-9/1024',
        );
        request.response.add(all.sublist(0, 10));
      } else {
        request.response.add(all);
      }
      return;
    }
    if (path == '/live/index.m3u8') {
      request.response.headers.contentType = ContentType(
        'application',
        'vnd.apple.mpegurl',
      );
      request.response.write(
        '#EXTM3U\n'
        '#EXT-X-TARGETDURATION:1\n'
        '#EXT-X-KEY:METHOD=AES-128,URI="key.bin"\n'
        '#EXTINF:1,\nseg-1.ts\n'
        '#EXTINF:1,\nhttp://guest.local:${_Upstream.guestPort}/live/abs.ts\n'
        '#EXT-X-ENDLIST\n',
      );
      return;
    }
    if (path == '/live/seg-1.ts' ||
        path == '/live/abs.ts' ||
        path == '/live/key.bin') {
      request.response.write('live-${path.split('/').last}');
      return;
    }
    if (path == '/dir/index.m3u8') {
      request.response.statusCode = HttpStatus.found;
      request.response.headers.set(
        HttpHeaders.locationHeader,
        'http://guest.local:${_Upstream.guestPort}/other/index.m3u8',
      );
      return;
    }
    if (path == '/other/index.m3u8') {
      request.response.headers.contentType = ContentType(
        'application',
        'vnd.apple.mpegurl',
      );
      request.response.write('#EXTM3U\n#EXTINF:1,\nseg.ts\n#EXT-X-ENDLIST\n');
      return;
    }
    if (path == '/other/seg.ts') {
      request.response.write('other-segment');
      return;
    }
    if (path == '/redirect') {
      request.response.statusCode = HttpStatus.found;
      request.response.headers.set(
        HttpHeaders.locationHeader,
        'http://other.local:${_Upstream.guestPort}/final.m3u8',
      );
      return;
    }
    if (path == '/final.m3u8') {
      request.response.headers.contentType = ContentType(
        'application',
        'vnd.apple.mpegurl',
      );
      request.response.write('#EXTM3U\n#EXT-X-ENDLIST\n');
      return;
    }
    if (path == '/dash/manifest.mpd') {
      request.response.headers.contentType = ContentType(
        'application',
        'dash+xml',
        charset: 'utf-8',
      );
      request.response.write('''<?xml version="1.0" encoding="UTF-8"?>
<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="PT2S">
  <BaseURL>http://guest.local:5000/dash/</BaseURL>
  <Period><AdaptationSet mimeType="video/mp4">
    <Representation id="v1" bandwidth="128000">
      <SegmentTemplate initialization="init-\$RepresentationID\$.mp4" media="seg-\$Number\$.m4s"/>
    </Representation>
    <Representation id="v2" bandwidth="64000">
      <SegmentTemplate media="http://guest.local:5000/abs/seg-\$Number\$.m4s"/>
    </Representation>
  </AdaptationSet></Period>
</MPD>''');
      return;
    }
    if (path == '/dash/filebase.mpd') {
      request.response.headers.contentType = ContentType(
        'application',
        'dash+xml',
        charset: 'utf-8',
      );
      request.response.write('''<?xml version="1.0" encoding="UTF-8"?>
<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static">
  <Period><AdaptationSet mimeType="video/mp4">
    <Representation id="v1" bandwidth="128000">
      <BaseURL>video.mp4</BaseURL>
      <SegmentBase><Initialization sourceURL="init.mp4"/></SegmentBase>
    </Representation>
  </AdaptationSet></Period>
</MPD>''');
      return;
    }
    if (path == '/dash/init.mp4') {
      request.response.headers.contentType = ContentType('video', 'mp4');
      request.response.add(List<int>.filled(16, 3));
      return;
    }
    if (path == '/dash/seg-1.m4s' || path == '/abs/seg-7.m4s') {
      request.response.headers.contentType = ContentType('video', 'mp4');
      request.response.add(List<int>.filled(32, 7));
      return;
    }
    if (path == '/forbidden.mpd') {
      request.response.statusCode = HttpStatus.forbidden;
      request.response.headers.contentType = ContentType(
        'application',
        'dash+xml',
      );
      request.response.write('forbidden');
      return;
    }
    request.response.statusCode = HttpStatus.notFound;
  }
}

Future<void> _waitFor(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) fail('condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// 手写 HTTP/1.1 响应字面量的本机原始 socket 服务端。
///
/// 必须绕开 HttpServer：它无法生成「同一个分帧头出现两次」的响应，
/// 而那正是真实 guest `/proxy` 应答者的行为。
class _RawUpstream {
  _RawUpstream._(this._port, this._response);

  final int _port;
  final String _response;
  ServerSocket? _server;
  final List<Socket> _accepted = <Socket>[];
  final List<String> requests = <String>[];
  int connections = 0;

  int get port => _port;

  static Future<_RawUpstream> start(String response) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final upstream = _RawUpstream._(server.port, response).._server = server;
    upstream._listen();
    return upstream;
  }

  void _listen() {
    _server!.listen((socket) {
      connections += 1;
      _accepted.add(socket);
      final buffer = <int>[];
      var recorded = false;
      socket.listen((data) {
        if (recorded) return;
        buffer.addAll(data);
        final text = latin1.decode(buffer);
        final end = text.indexOf('\r\n\r\n');
        if (end < 0) return;
        recorded = true;
        requests.add(text.substring(0, end + 4));
      }, onError: (Object _) {});
      socket.add(latin1.encode(_response));
    });
  }

  Future<void> stop() async {
    for (final socket in _accepted) {
      socket.destroy();
    }
    await _server?.close();
  }
}
