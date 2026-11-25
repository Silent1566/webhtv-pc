/// Content-detected managed HLS, exercised with hand-written socket HTTP.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/proxy_policy.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/proxy_server.dart';

const _media =
    '#EXTM3U\n'
    '#EXT-X-TARGETDURATION:1\n'
    '#EXT-X-KEY:METHOD=AES-128,URI="http://guest.local:5000/key.bin"\n'
    '#EXT-X-MAP:URI="init.mp4"\n'
    '#EXTINF:1,\nhttp://guest.local:5000/seg.ts\n'
    '#EXTINF:1,\nrelative.ts\n'
    '#EXT-X-ENDLIST\n';
const _master =
    '#EXTM3U\n'
    '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",URI="http://guest.local:5000/audio"\n'
    '#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=1000,URI="iframe"\n'
    '#EXT-X-STREAM-INF:BANDWIDTH=10000\nhttp://guest.local:5000/media\n';
const _cap = 1024 * 1024;

void main() {
  late LocalProxyServer proxy;
  late _RawOrigin origin;
  late List<Uri> resolved;

  setUp(() async {
    resolved = [];
    origin = await _RawOrigin.start((socket, request) async {
      final path = request.split(' ')[1];
      final text = path == '/master'
          ? _master
          : (path == '/media' || path == '/audio' || path == '/iframe')
          ? _media
          : 'segment';
      await _reply(socket, utf8.encode(text));
    });
    proxy = LocalProxyServer(log: LogService());
    await proxy.start();
  });
  tearDown(() async {
    await proxy.stop();
    await origin.stop();
  });

  ProxySession managed({
    int maxRequests = 4096,
    int? maxBytes,
    String? userAgent,
    String? referer,
    String? cookie,
  }) => proxy.sessions.create(
    siteKey: 'managed-octet',
    maxRequests: maxRequests,
    maxBytes: maxBytes ?? ProxySession.defaultMaxBytes,
    userAgent: userAgent,
    referer: referer,
    cookie: cookie,
    targetResolver: (target) async {
      resolved.add(target);
      return target.host == 'guest.local' && target.port == 5000
          ? origin.port
          : null;
    },
  );

  String url(ProxySession session, String path) =>
      proxy.urlFor(session, Uri.parse('http://guest.local:5000$path'));

  for (final topRedirect in [true, false]) {
    test(
      'unrestricted public host scope stays empty after ${topRedirect ? 'top' : 'child'} redirect',
      () async {
        final text =
            '#EXTM3U\n#EXT-X-TARGETDURATION:1\n'
            '#EXTINF:1,\nhttp://8.8.8.8/segment.ts\n'
            '#EXTINF:1,\nhttp://9.9.9.9/other.ts\n#EXT-X-ENDLIST\n';
        origin.respond = (socket, request) {
          final target = Uri.parse(request.split(' ')[1]);
          if (topRedirect &&
              target.host == '93.184.216.34' &&
              target.path == '/top') {
            return _reply(
              socket,
              [],
              status: '302 Found',
              extra: 'Location: http://1.1.1.1/manifest\r\n',
            );
          }
          if (target.path == '/top' || target.path == '/manifest') {
            return _reply(socket, utf8.encode(text));
          }
          if (!topRedirect && target.host == '8.8.8.8') {
            return _reply(
              socket,
              [],
              status: '302 Found',
              extra: 'Location: http://1.1.1.1/final.ts\r\n',
            );
          }
          return _reply(socket, [0, 1, 2, 3]);
        };
        await proxy.stop();
        proxy = HttpOverrides.runWithHttpOverrides(
          () => LocalProxyServer(log: LogService()),
          _HttpProxyOverride(origin.port),
        );
        await proxy.start();
        final session = proxy.sessions.create(
          siteKey: 'android-public-redirect',
          inspectPlaylistContent: true,
        );
        final response = await _get(
          proxy.urlFor(session, Uri.parse('http://93.184.216.34/top')),
        );
        expect(response.status, 200);
        expect(
          response.headers.contentType?.mimeType,
          'application/vnd.apple.mpegurl',
        );
        final body = utf8.decode(response.bytes);
        final children = _urls(body);
        expect(children, hasLength(2));
        expect(body, isNot(contains('8.8.8.8')));
        expect(body, isNot(contains('9.9.9.9')));
        for (final child in children) {
          expect(Uri.parse(child).pathSegments.take(2), ['p', session.token]);
          final fetched = await _get(child);
          expect(fetched.status, 200);
          expect(fetched.bytes, [0, 1, 2, 3]);
        }
        expect(session.allowedHosts, isEmpty);
        expect(session.derivedHosts, contains('1.1.1.1'));
        expect(origin.requests, hasLength(4));
      },
    );
  }

  for (final sessionFence in [false, true]) {
    test(
      '${sessionFence ? 'ordinary PC session' : 'custom global'} host fence retains approved redirect scope',
      () async {
        final text =
            '#EXTM3U\n#EXT-X-TARGETDURATION:1\n'
            '#EXTINF:1,\nhttp://1.1.1.1/allowed.ts\n'
            '#EXTINF:1,\nhttp://8.8.8.8/foreign.ts\n#EXT-X-ENDLIST\n';
        origin.respond = (socket, request) {
          final target = Uri.parse(request.split(' ')[1]);
          if (target.host == '93.184.216.34') {
            return _reply(
              socket,
              [],
              status: '302 Found',
              extra: 'Location: http://1.1.1.1/manifest\r\n',
            );
          }
          if (target.path == '/manifest') {
            return _reply(
              socket,
              utf8.encode(text),
              type: 'application/vnd.apple.mpegurl',
            );
          }
          return _reply(socket, [0, 1, 2, 3]);
        };
        await proxy.stop();
        proxy = HttpOverrides.runWithHttpOverrides(
          () => LocalProxyServer(
            log: LogService(),
            policy: ProxyTargetPolicy(
              allowedHosts: sessionFence ? const {} : const {'93.184.216.34'},
            ),
          ),
          _HttpProxyOverride(origin.port),
        );
        await proxy.start();
        final session = proxy.sessions.create(
          siteKey: 'fenced-redirect',
          allowedHosts: sessionFence ? const {'93.184.216.34'} : const {},
          inspectPlaylistContent: !sessionFence,
        );
        final response = await _get(
          proxy.urlFor(session, Uri.parse('http://93.184.216.34/top')),
        );
        expect(response.status, 200);
        final children = _urls(utf8.decode(response.bytes));
        final allowed = children.first;
        expect(Uri.parse(allowed).pathSegments.take(2), ['p', session.token]);
        expect((await _get(allowed)).status, 200);
        final denied = proxy.urlFor(
          session,
          Uri.parse('http://8.8.8.8/foreign.ts'),
        );
        expect((await _get(denied)).status, 403);
        expect(origin.requests, hasLength(3));
        expect(session.derivedHosts, contains('1.1.1.1'));
        if (sessionFence) expect(session.inspectPlaylistContent, isFalse);
      },
    );
  }

  test('public Android provenance with null resolver rewrites while ordinary PC stays exact', () async {
    final text =
        '#EXTM3U\n#EXT-X-TARGETDURATION:1\n'
        '#EXTINF:1,\nhttp://93.184.216.34/segment.ts\n'
        '#EXTINF:1,\nhttp://1.1.1.1/cdn.ts\n#EXT-X-ENDLIST\n';
    origin.respond = (socket, request) {
      if (Uri.parse(request.split(' ')[1]).path == '/opaque') {
        final bytes = utf8.encode(text);
        return _reply(
          socket,
          bytes,
          status: '206 Partial Content',
          extra:
              'Content-Range: bytes 0-${bytes.length - 1}/${bytes.length}\r\n',
        );
      }
      return _reply(socket, [0, 1, 2, 3]);
    };
    await proxy.stop();
    proxy = HttpOverrides.runWithHttpOverrides(
      () => LocalProxyServer(log: LogService()),
      _HttpProxyOverride(origin.port),
    );
    await proxy.start();
    final target = Uri.parse('http://93.184.216.34/opaque');
    final android = proxy.sessions.create(
      siteKey: 'android-public',
      inspectPlaylistContent: true,
      cookie: 'sid=same-origin',
      authorization: 'Bearer same-origin',
      userAgent: 'AndroidSource/1',
      referer: 'https://source.test/page',
      extraHeaders: {
        'X-Auth-Token': 'same-origin',
        'X-Public-Test': 'retained',
      },
    );
    expect(android.targetResolver, isNull);
    final response = await _get(proxy.urlFor(android, target));
    expect(response.status, 200);
    expect(
      response.headers.contentType?.mimeType,
      'application/vnd.apple.mpegurl',
    );
    final rewritten = utf8.decode(response.bytes);
    final children = _urls(rewritten);
    expect(children, hasLength(2));
    expect(rewritten, isNot(contains('93.184.216.34')));
    expect(rewritten, isNot(contains('1.1.1.1')));
    for (final child in children) {
      expect(Uri.parse(child).pathSegments.take(2), ['p', android.token]);
      expect((await _get(child)).bytes, [0, 1, 2, 3]);
    }
    for (final request in origin.requests) {
      final headers = request.toLowerCase();
      expect(headers, contains('user-agent: androidsource/1'));
      expect(headers, contains('referer: https://source.test/page'));
      expect(headers, contains('x-public-test: retained'));
      if (request.split(' ')[1].contains('93.184.216.34')) {
        expect(headers, contains('cookie: sid=same-origin'));
        expect(headers, contains('authorization: bearer same-origin'));
        expect(headers, contains('x-auth-token: same-origin'));
      } else {
        expect(headers, isNot(contains('cookie:')));
        expect(headers, isNot(contains('authorization:')));
        expect(headers, isNot(contains('x-auth-token:')));
      }
    }
    final pc = proxy.sessions.create(siteKey: 'ordinary-pc');
    expect(pc.inspectPlaylistContent, isFalse);
    final unchanged = await _get(proxy.urlFor(pc, target));
    expect(unchanged.status, 206);
    expect(unchanged.bytes, utf8.encode(text));
    expect(unchanged.headers.contentType?.mimeType, 'application/octet-stream');
  });

  test(
    'inspection hint retains the global allowed-host policy before socket',
    () async {
      await proxy.stop();
      proxy = HttpOverrides.runWithHttpOverrides(
        () => LocalProxyServer(
          log: LogService(),
          policy: const ProxyTargetPolicy(allowedHosts: {'93.184.216.34'}),
        ),
        _HttpProxyOverride(origin.port),
      );
      await proxy.start();
      origin.respond = (socket, _) => _reply(
        socket,
        utf8.encode(
          '#EXTM3U\n#EXTINF:1,\nhttp://1.1.1.1/cdn.ts\n#EXT-X-ENDLIST\n',
        ),
      );
      final session = proxy.sessions.create(
        siteKey: 'global-fence',
        inspectPlaylistContent: true,
      );
      final response = await _get(
        proxy.urlFor(session, Uri.parse('http://93.184.216.34/opaque')),
      );
      final child = _urls(utf8.decode(response.bytes)).single;
      expect(Uri.parse(child).pathSegments.take(2), ['p', session.token]);
      expect((await _get(child)).status, 403);
      expect(origin.requests, hasLength(1));
    },
  );

  test(
    'inspection hint without resolver never authorizes private addresses',
    () async {
      final session = proxy.sessions.create(
        siteKey: 'public-hint',
        inspectPlaylistContent: true,
      );
      for (final host in ['127.0.0.1', '192.168.50.3', '169.254.169.254']) {
        expect(
          (await _get(
            proxy.urlFor(
              session,
              Uri.parse('http://$host:${origin.port}/opaque'),
            ),
          )).status,
          403,
        );
      }
      expect(origin.requests, isEmpty);
    },
  );

  test('public provenance does not enable tolerant framing retries', () async {
    final bytes = utf8.encode('#EXTM3U\n');
    origin.respond = (socket, _) async {
      socket.add(
        _headers(bytes.length, extra: 'Content-Length: ${bytes.length}\r\n'),
      );
      socket.add(bytes);
      await socket.flush();
    };
    await proxy.stop();
    proxy = HttpOverrides.runWithHttpOverrides(
      () => LocalProxyServer(log: LogService()),
      _HttpProxyOverride(origin.port),
    );
    await proxy.start();
    final session = proxy.sessions.create(
      siteKey: 'android-public',
      inspectPlaylistContent: true,
    );
    final response = await _get(
      proxy.urlFor(session, Uri.parse('http://93.184.216.34/opaque')),
    );
    expect(response.status, 502);
    expect(origin.requests, hasLength(1));
  });

  for (final scenario in [('master', _master, 3), ('media', _media, 4)]) {
    test(
      'managed octet-stream HLS ${scenario.$1} proxies every child',
      () async {
        final session = managed();
        final response = await _get(url(session, '/${scenario.$1}'));
        expect(response.status, 200);
        final text = utf8.decode(response.bytes);
        final children = _urls(text);
        expect(children, hasLength(scenario.$3));
        expect(text, isNot(contains('guest.local')));
        expect(
          response.headers.contentType?.mimeType,
          'application/vnd.apple.mpegurl',
        );
        for (final child in children) {
          expect(Uri.parse(child).pathSegments.take(2), ['p', session.token]);
          final fetched = await _get(child);
          expect(fetched.status, 200);
          expect(utf8.decode(fetched.bytes), isNot(contains('guest.local')));
        }
        expect(resolved, hasLength(1 + scenario.$3));
        expect(
          resolved.every(
            (uri) => uri.host == 'guest.local' && uri.port == 5000,
          ),
          isTrue,
        );
        expect(
          session.receivedBytes,
          greaterThanOrEqualTo(utf8.encode(scenario.$2).length),
        );
      },
    );
  }

  test('BOM and whitespace split across chunks still detect HLS', () async {
    origin.respond = (socket, _) async {
      final bytes = utf8.encode(' \r\n\uFEFF\t$_media');
      socket.add(_headers(bytes.length));
      for (final byte in bytes.take(12)) {
        socket.add([byte]);
        await socket.flush();
      }
      socket.add(bytes.sublist(12));
      await socket.flush();
    };
    final session = managed();
    final response = await _get(url(session, '/opaque'));
    expect(_urls(utf8.decode(response.bytes)), hasLength(4));
    expect(utf8.decode(response.bytes), isNot(contains('guest.local')));
  });

  test(
    'over 1 MiB undecided octet body streams unchanged before EOF',
    () async {
      final releaseTail = Completer<void>();
      addTearDown(() {
        if (!releaseTail.isCompleted) releaseTail.complete();
      });
      final bytes = [...List<int>.filled(_cap + 1, 32), ...utf8.encode(_media)];
      origin.respond = (socket, _) async {
        socket.add(_headers(bytes.length));
        socket.add(bytes.sublist(0, _cap + 1));
        await socket.flush();
        await releaseTail.future;
        socket.add(bytes.sublist(_cap + 1));
        await socket.flush();
      };
      final session = managed();
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final request = await client.getUrl(Uri.parse(url(session, '/large')));
      final response = await request.close().timeout(
        const Duration(seconds: 3),
      );
      final first = Completer<void>();
      final received = BytesBuilder(copy: false);
      final done = Completer<void>();
      response.listen(
        (chunk) {
          received.add(chunk);
          if (!first.isCompleted) first.complete();
        },
        onDone: done.complete,
        onError: done.completeError,
      );
      await first.future.timeout(const Duration(seconds: 3));
      expect(received.length, greaterThan(0));
      expect(done.isCompleted, isFalse);
      releaseTail.complete();
      await done.future.timeout(const Duration(seconds: 3));
      expect(response.statusCode, 200);
      expect(received.takeBytes(), bytes);
      expect(session.receivedBytes, bytes.length);
      expect(session.bytes, bytes.length);
    },
  );

  test('recognized octet HLS above 1 MiB fails closed', () async {
    final bytes = [...utf8.encode(_media), ...List<int>.filled(_cap, 32)];
    origin.respond = (socket, _) => _reply(socket, bytes);
    final response = await _get(url(managed(), '/oversized'));
    expect(response.status, 502);
    expect(utf8.decode(response.bytes), contains('1 MiB'));
    expect(utf8.decode(response.bytes), isNot(contains('guest.local')));
  });

  test('HEAD octet response never sniffs or makes an extra GET', () async {
    origin.respond = (socket, _) async {
      socket.add(_headers(utf8.encode(_media).length));
      await socket.flush();
    };
    final session = managed();
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final request = await client.openUrl(
      'HEAD',
      Uri.parse(url(session, '/head')),
    );
    final response = await request.close().timeout(const Duration(seconds: 3));
    expect(response.statusCode, 200);
    expect(await response.toList(), isEmpty);
    expect(origin.requests, hasLength(1));
    expect(origin.requests.single, startsWith('HEAD '));
  });

  test('tolerant octet HLS framing fallback fails closed', () async {
    final bytes = utf8.encode(_media);
    origin.respond = (socket, _) async {
      socket.add(
        _headers(bytes.length, extra: 'Content-Length: ${bytes.length}\r\n'),
      );
      socket.add(bytes);
      await socket.flush();
    };
    final response = await _get(url(managed(), '/duplicate'));
    expect(response.status, 502);
    expect(utf8.decode(response.bytes), isNot(contains('guest.local')));
  });

  test('non-managed identical octet-stream playlist is byte-exact', () async {
    final direct = Uri.parse('http://127.0.0.1:${origin.port}/media');
    final legacy = LocalProxyServer(
      log: LogService(),
      policy: const ProxyTargetPolicy(allowPrivate: true, allowLoopback: true),
    );
    await legacy.start();
    addTearDown(legacy.stop);
    final session = legacy.sessions.create(siteKey: 'legacy');
    final response = await _get(legacy.urlFor(session, direct));
    expect(response.status, 200);
    expect(response.bytes, utf8.encode(_media));
    expect(response.headers.contentType?.mimeType, 'application/octet-stream');
  });

  test('managed binary MP4 bytes remain untouched', () async {
    final bytes = [
      0,
      0,
      0,
      24,
      102,
      116,
      121,
      112,
      255,
      254,
      128,
      0,
      ...utf8.encode(_media),
    ];
    origin.respond = (socket, _) => _reply(socket, bytes, type: 'video/mp4');
    final session = managed();
    final response = await _get(url(session, '/binary'));
    expect(response.status, 200);
    expect(response.bytes, bytes);
    expect(response.headers.contentType?.mimeType, 'video/mp4');
  });

  test(
    'existing HLS content-type rewrite still synthesizes full 200',
    () async {
      final bytes = utf8.encode(_media);
      origin.respond = (socket, _) => _reply(
        socket,
        bytes,
        type: 'application/vnd.apple.mpegurl',
        status: '206 Partial Content',
        extra: 'Content-Range: bytes 0-${bytes.length - 1}/${bytes.length}\r\n',
      );
      final session = managed();
      final response = await _get(url(session, '/typed'), range: 'bytes=0-');
      expect(response.status, 200);
      expect(_urls(utf8.decode(response.bytes)), hasLength(4));
      expect(response.headers.value(HttpHeaders.contentRangeHeader), isNull);
    },
  );

  test(
    'complete 206 octet HLS returns honest full 200 and entity headers',
    () async {
      final bytes = utf8.encode(_media);
      origin.respond = (socket, _) => _reply(
        socket,
        bytes,
        status: '206 Partial Content',
        extra:
            'Content-Range: bytes 0-${bytes.length - 1}/${bytes.length}\r\n'
            'Accept-Ranges: bytes\r\nETag: "original"\r\n'
            'Last-Modified: Tue, 24 Nov 2026 00:00:00 GMT\r\n',
      );
      final session = managed();
      final response = await _get(url(session, '/ranged'), range: 'bytes=0-');
      expect(response.status, 200);
      expect(_urls(utf8.decode(response.bytes)), hasLength(4));
      expect(utf8.decode(response.bytes), contains('#EXT-X-ENDLIST'));
      expect(response.headers.contentLength, response.bytes.length);
      for (final name in [
        HttpHeaders.contentRangeHeader,
        HttpHeaders.acceptRangesHeader,
        HttpHeaders.etagHeader,
        HttpHeaders.lastModifiedHeader,
      ]) {
        expect(response.headers.value(name), isNull);
      }
      expect(origin.requests, hasLength(1));
      expect(origin.requests.single.toLowerCase(), contains('range: bytes=0-'));
    },
  );

  test('partial 206 HLS retries without Range instead of relabeling a fragment', () async {
    final full = utf8.encode(_media);
    final fragment = utf8.encode('#EXTM3U\n#EXTINF:1,\nseg.ts\n');
    origin.respond = (socket, request) =>
        request.toLowerCase().contains('range:')
        ? _reply(
            socket,
            fragment,
            status: '206 Partial Content',
            extra:
                'Content-Range: bytes 0-${fragment.length - 1}/${full.length}\r\n',
          )
        : _reply(socket, full);
    final session = managed(
      userAgent: 'ManagedPlayer/1',
      referer: 'http://guest.local:5000/page',
      cookie: 'sid=abc',
    );
    final response = await _get(
      url(session, '/partial'),
      range: 'bytes=0-23',
      userAgent: 'PlayerRequest/1',
    );
    expect(response.status, 200);
    expect(_urls(utf8.decode(response.bytes)), hasLength(4));
    expect(utf8.decode(response.bytes), contains('#EXT-X-ENDLIST'));
    expect(origin.requests, hasLength(2));
    final retry = origin.requests.last.toLowerCase();
    expect(retry, isNot(contains('range:')));
    expect(retry, contains('user-agent: managedplayer/1'));
    expect(retry, contains('referer: http://guest.local:5000/page'));
    expect(retry, contains('cookie: sid=abc'));
    expect(session.requests, 2);
    expect(session.receivedBytes, full.length + fragment.length);
  });

  test('retry cannot switch to a different mapped endpoint', () async {
    final other = await _RawOrigin.start(
      (socket, _) => _reply(socket, utf8.encode(_media)),
    );
    addTearDown(other.stop);
    var calls = 0;
    final session = proxy.sessions.create(
      siteKey: 'managed-pinned',
      targetResolver: (target) async => ++calls == 1 ? origin.port : other.port,
    );
    origin.respond = (socket, _) => _reply(
      socket,
      utf8.encode('#EXTM3U\n'),
      status: '206 Partial Content',
      extra: 'Content-Range: bytes 0-7/100\r\n',
    );
    final response = await _get(url(session, '/pin'), range: 'bytes=0-7');
    expect(response.status, 502);
    expect(other.requests, isEmpty);
    expect(origin.requests, hasLength(1));
  });

  test(
    'retry still returning partial 206 fails closed after exactly one retry',
    () async {
      final fragment = utf8.encode('#EXTM3U\n');
      origin.respond = (socket, _) => _reply(
        socket,
        fragment,
        status: '206 Partial Content',
        extra: 'Content-Range: bytes 0-7/100\r\n',
      );
      final session = managed();
      final response = await _get(url(session, '/partial'), range: 'bytes=0-7');
      expect(response.status, 502);
      expect(origin.requests, hasLength(2));
      expect(session.requests, 2);
      expect(session.receivedBytes, 16);
    },
  );

  test('session revoked during sniff cannot trigger manifest retry', () async {
    final session = managed();
    origin.respond = (socket, _) async {
      final bytes = utf8.encode('#EXTM3U\n');
      socket.add(
        _headers(
          bytes.length,
          status: '206 Partial Content',
          extra: 'Content-Range: bytes 0-7/100\r\n',
        ),
      );
      socket.add(bytes.take(4).toList());
      await socket.flush();
      proxy.sessions.revoke(session.token);
      socket.add(bytes.sublist(4));
      await socket.flush();
    };
    final response = await _get(url(session, '/revoked'), range: 'bytes=0-7');
    expect(response.status, 401);
    expect(origin.requests, hasLength(1));
  });

  test(
    'sniffing only successful 200/206 leaves error playlists unchanged',
    () async {
      origin.respond = (socket, _) =>
          _reply(socket, utf8.encode(_media), status: '404 Not Found');
      final response = await _get(url(managed(), '/missing'));
      expect(response.status, 404);
      expect(response.bytes, utf8.encode(_media));
    },
  );

  test('octet playlist quota still returns 429 before sniffing', () async {
    final session = managed(maxRequests: 1);
    final first = await _get(url(session, '/media'));
    expect(first.status, 200);
    final second = await _get(url(session, '/media'));
    expect(second.status, 429);
    expect(session.receivedBytes, utf8.encode(_media).length);
    final small = managed(maxBytes: 1);
    expect((await _get(url(small, '/media'))).status, 429);
  });

  test(
    'partial manifest retry is token-rechecked and request-quota accounted',
    () async {
      final fragment = utf8.encode('#EXTM3U\n');
      origin.respond = (socket, _) => _reply(
        socket,
        fragment,
        status: '206 Partial Content',
        extra: 'Content-Range: bytes 0-7/100\r\n',
      );
      final session = managed(maxRequests: 1);
      final response = await _get(url(session, '/partial'), range: 'bytes=0-7');
      expect(response.status, 429);
      expect(session.requests, 2);
    },
  );
}

List<String> _urls(String text) =>
    RegExp(r'https?://[^\s"<>]+')
        .allMatches(text)
        .map((match) => match.group(0)!)
        .toList();

List<int> _headers(
  int length, {
  String type = 'application/octet-stream',
  String status = '200 OK',
  String extra = '',
}) => ascii.encode(
  'HTTP/1.1 $status\r\nContent-Length: $length\r\n'
  'Content-Type: $type\r\nConnection: close\r\n$extra\r\n',
);
Future<void> _reply(
  Socket socket,
  List<int> bytes, {
  String type = 'application/octet-stream',
  String status = '200 OK',
  String extra = '',
}) async {
  socket.add(_headers(bytes.length, type: type, status: status, extra: extra));
  socket.add(bytes);
  await socket.flush();
}

class _Response {
  _Response(this.status, this.headers, this.bytes);
  final int status;
  final HttpHeaders headers;
  final List<int> bytes;
}

Future<_Response> _get(String url, {String? range, String? userAgent}) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(url));
    if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
    if (userAgent != null) {
      request.headers.set(HttpHeaders.userAgentHeader, userAgent);
    }
    final response = await request.close().timeout(const Duration(seconds: 3));
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(const Duration(seconds: 3))) {
      bytes.add(chunk);
    }
    return _Response(response.statusCode, response.headers, bytes.takeBytes());
  } finally {
    client.close(force: true);
  }
}

class _RawOrigin {
  _RawOrigin(this.server, this.respond);
  final ServerSocket server;
  Future<void> Function(Socket, String) respond;
  final sockets = <Socket>[];
  final requests = <String>[];
  int get port => server.port;
  static Future<_RawOrigin> start(
    Future<void> Function(Socket, String) respond,
  ) async {
    final origin = _RawOrigin(
      await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
      respond,
    );
    origin.server.listen((socket) {
      origin.sockets.add(socket);
      final bytes = BytesBuilder(copy: false);
      var sent = false;
      socket.listen((chunk) {
        if (sent) return;
        bytes.add(chunk);
        final request = latin1.decode(bytes.toBytes());
        if (!request.contains('\r\n\r\n')) return;
        sent = true;
        origin.requests.add(request);
        unawaited(origin.respond(socket, request));
      }, onError: (Object _) {});
    });
    return origin;
  }

  Future<void> stop() async {
    for (final socket in sockets) {
      socket.destroy();
    }
    await server.close();
  }
}

class _HttpProxyOverride extends HttpOverrides {
  _HttpProxyOverride(this.port);
  final int port;
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context)
        ..findProxy = (_) => 'PROXY 127.0.0.1:$port';
}
