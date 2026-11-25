library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/proxy_policy.dart';
import 'package:webhtv_pc/core/png_wrapped_transport_stream.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/proxy_server.dart';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLttAAAAABJRU5ErkJggg==',
);
List<int> _ts([int packets = 8]) =>
    List.generate(packets * 188, (i) => i % 188 == 0 ? 0x47 : i % 251);
List<int> _wrapped([int packets = 8]) => [..._png, ..._ts(packets)];
void main() {
  late LocalProxyServer proxy;
  late _RawOrigin origin;
  setUp(() async {
    origin = await _RawOrigin.start(
      (s, r) => _reply(s, _wrapped(), type: 'image/png'),
    );
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
    Future<int?> Function(Uri)? resolver,
  }) => proxy.sessions.create(
    siteKey: 'png-ts',
    maxRequests: maxRequests,
    maxBytes: maxBytes ?? ProxySession.defaultMaxBytes,
    userAgent: 'fixture-agent',
    referer: 'http://guest.local:5000/',
    cookie: 'fixture=cookie',
    authorization: 'fixture-auth',
    targetResolver:
        resolver ?? (u) async => u.host == 'guest.local' ? origin.port : null,
  );
  String url(ProxySession s) =>
      proxy.urlFor(s, Uri.parse('http://guest.local:5000/segment'));
  test('literal chunked PNG plus TS split prefix becomes exact TS', () async {
    origin.respond = (s, r) async {
      s.add(
        ascii.encode(
          'HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nTransfer-Encoding: chunked\r\nETag: fixture\r\nLast-Modified: Wed, 21 Oct 2015 07:28:00 GMT\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n',
        ),
      );
      final b = _wrapped();
      for (final c in [
        b.sublist(0, 4),
        b.sublist(4, 70),
        b.sublist(70, 300),
        b.sublist(300),
      ]) {
        s.add(ascii.encode('${c.length.toRadixString(16)}\r\n'));
        s.add(c);
        s.add([13, 10]);
        await s.flush();
      }
      s.add(ascii.encode('0\r\n\r\n'));
      await s.flush();
    };
    final r = await _get(url(managed()));
    expect(r.status, 200);
    expect(r.headers.contentType?.mimeType, 'video/mp2t');
    expect(r.bytes, _ts());
    for (final h in [
      'content-range',
      'accept-ranges',
      'etag',
      'last-modified',
    ]) {
      expect(r.headers.value(h), isNull);
    }
  });
  for (final sample in <String, List<int>>{
    'png': _png,
    'garbage': [..._png, 1, 2, 3],
    'no-IEND': [..._png.take(50), ..._ts()],
    'no-sync': [..._png, ...List.filled(600, 1)],
    'mp4': [0, 0, 0, 24, 102, 116, 121, 112, ..._ts()],
  }.entries) {
    test('${sample.key} unproven partial is byte exact', () async {
      origin.respond = (s, r) => _reply(
        s,
        sample.value,
        type: 'image/png',
        status: '206 Partial Content',
        extra:
            'Content-Range: bytes 0-${sample.value.length - 1}/${sample.value.length}\r\n',
      );
      final r = await _get(url(managed()), range: 'bytes=0-');
      expect(r.status, 206);
      expect(r.bytes, sample.value);
      expect(r.headers.contentType?.mimeType, 'image/png');
      expect(origin.requests.length, 1);
    });
  }
  test('ordinary PC identical wrapped bytes unchanged', () async {
    await proxy.stop();
    proxy = LocalProxyServer(
      log: LogService(),
      policy: const ProxyTargetPolicy(allowLoopback: true),
    );
    await proxy.start();
    final s = proxy.sessions.create(siteKey: 'ordinary');
    final r = await _get(
      proxy.urlFor(s, Uri.parse('http://127.0.0.1:${origin.port}/segment')),
    );
    expect(r.bytes, _wrapped());
    expect(r.headers.contentType?.mimeType, 'image/png');
  });
  for (final range in ['bytes=0-', 'bytes=1000-']) {
    test('partial $range checked unconditional full retry', () async {
      final b = _wrapped();
      origin.respond = (s, r) {
        if (!r.toLowerCase().contains('range:')) {
          return _reply(s, b, type: 'image/png');
        }
        if (r.toLowerCase().contains('range: bytes=0-16383')) {
          return _reply(
            s,
            b,
            type: 'image/png',
            status: '206 Partial Content',
            extra: 'Content-Range: bytes 0-${b.length - 1}/${b.length}\r\n',
          );
        }
        final start = range == 'bytes=0-' ? 0 : 1000;
        final part = b.sublist(start, start == 0 ? 700 : b.length);
        return _reply(
          s,
          part,
          type: 'image/png',
          status: '206 Partial Content',
          extra:
              'Content-Range: bytes $start-${start + part.length - 1}/${b.length}\r\n',
        );
      };
      final r = await _get(url(managed()), range: range);
      expect(r.status, 200);
      expect(r.bytes, _ts());
      expect(r.headers.contentType?.mimeType, 'video/mp2t');
      expect(r.headers.value('content-range'), isNull);
      expect(origin.requests.length, range == 'bytes=0-' ? 2 : 3);
      expect(origin.requests.last.toLowerCase(), isNot(contains('range:')));
      for (final request in origin.requests) {
        expect(request, contains('fixture-agent'));
        expect(request, contains('fixture=cookie'));
        expect(request, contains('fixture-auth'));
        expect(
          request.toLowerCase(),
          contains('referer: http://guest.local:5000/'),
        );
      }
    });
  }
  test('complete 206 proof needs no retry and uses logical length', () async {
    final b = _wrapped();
    origin.respond = (s, r) => _reply(
      s,
      b,
      type: 'image/png',
      status: '206 Partial Content',
      extra: 'Content-Range: bytes 0-${b.length - 1}/${b.length}\r\n',
    );
    final r = await _get(url(managed()), range: 'bytes=0-');
    expect(r.status, 200);
    expect(r.bytes, _ts());
    expect(r.headers.contentLength, _ts().length);
    expect(origin.requests.length, 1);
  });
  for (final fail in ['partial', 'endpoint', 'revoke', 'quota']) {
    test('checked retry fails closed on $fail', () async {
      final b = _wrapped();
      var resolutions = 0;
      late ProxySession session;
      session = managed(
        maxRequests: fail == 'quota' ? 1 : 4096,
        resolver: (u) async {
          resolutions++;
          if (resolutions == 2 && fail == 'revoke') {
            proxy.sessions.revoke(session.token);
          }
          return fail == 'endpoint' && resolutions == 2
              ? origin.port + 1
              : origin.port;
        },
      );
      origin.respond = (s, r) => _reply(
        s,
        b.take(700).toList(),
        type: 'image/png',
        status: '206 Partial Content',
        extra: 'Content-Range: bytes 0-699/${b.length}\r\n',
      );
      final r = await _get(url(session), range: 'bytes=0-');
      expect(
        r.status,
        fail == 'revoke'
            ? 401
            : fail == 'quota'
            ? 429
            : 502,
      );
      expect(origin.requests.length, lessThanOrEqualTo(2));
    });
  }
  test('404 error never converts to media', () async {
    origin.respond = (s, r) => _reply(
      s,
      utf8.encode('<Error>NoSuchKey</Error>'),
      type: 'image/png',
      status: '404 Not Found',
    );
    final r = await _get(url(managed()));
    expect(r.status, 404);
    expect(utf8.decode(r.bytes), contains('NoSuchKey'));
    expect(origin.requests.length, 1);
  });
  test('HEAD no GET or inspection', () async {
    origin.respond = (s, r) async {
      s.add(_headers(_wrapped().length, type: 'image/png'));
      await s.flush();
    };
    final c = HttpClient();
    try {
      final req = await c.headUrl(Uri.parse(url(managed())));
      final r = await req.close().timeout(const Duration(seconds: 3));
      expect(r.statusCode, 200);
      expect(r.headers.contentType?.mimeType, 'image/png');
      await r.drain<void>();
    } finally {
      c.close(force: true);
    }
    expect(origin.requests.single, startsWith('HEAD '));
  });
  test(
    'Android PNG media alias is restricted to unencrypted EXTINF role',
    () async {
      final s = managed();
      origin.respond = (socket, request) => _reply(
        socket,
        utf8.encode(
          '#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXTINF:1,\nimage.png\n#EXT-X-ENDLIST\n',
        ),
        type: 'application/vnd.apple.mpegurl',
      );
      final r = await _get(url(s));
      final media = const LineSplitter()
          .convert(utf8.decode(r.bytes))
          .singleWhere((l) => l.startsWith('http'));
      expect(Uri.parse(media).path, endsWith('/i/0.ts'));
      origin.respond = (socket, request) =>
          _reply(socket, _wrapped(), type: 'image/png');
      expect((await _get(media)).bytes, _ts());
      expect((await _get(media.replaceFirst('.ts', ''))).bytes, _ts());
      expect((await _get(media.replaceFirst('0.ts', '1.ts'))).status, 400);
      expect((await _get(media.replaceFirst('0.ts', '0.mp4'))).status, 400);
    },
  );
  for (final shape in [
    'variant',
    'encrypted',
    'map',
    'byterange',
    'ordinary',
  ]) {
    test('PNG URI is not aliased for excluded role $shape', () async {
      if (shape == 'ordinary') {
        await proxy.stop();
        proxy = LocalProxyServer(
          log: LogService(),
          policy: const ProxyTargetPolicy(allowLoopback: true),
        );
        await proxy.start();
      }
      final s = shape == 'ordinary'
          ? proxy.sessions.create(siteKey: 'pc')
          : managed();
      final protection = shape == 'encrypted'
          ? '#EXT-X-KEY:METHOD=AES-128,URI="key.png"\n'
          : shape == 'map'
          ? '#EXT-X-MAP:URI="init.png"\n'
          : '';
      final byteRange = shape == 'byterange' ? '#EXT-X-BYTERANGE:1000@0\n' : '';
      final text = shape == 'variant'
          ? '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=100\nimage.png\n'
          : '#EXTM3U\n$protection#EXTINF:1,\n${byteRange}image.png\n#EXT-X-ENDLIST\n';
      origin.respond = (socket, request) => _reply(
        socket,
        utf8.encode(text),
        type: 'application/vnd.apple.mpegurl',
      );
      final target = shape == 'ordinary'
          ? proxy.urlFor(
              s,
              Uri.parse('http://127.0.0.1:${origin.port}/manifest'),
            )
          : url(s);
      final r = await _get(target);
      expect(utf8.decode(r.bytes), isNot(contains('/i/0.ts')));
      expect(utf8.decode(r.bytes), isNot(contains('/i/1.ts')));
      if (shape != 'ordinary') {
        final child = const LineSplitter()
            .convert(utf8.decode(r.bytes))
            .lastWhere((line) => line.startsWith('http'));
        origin.respond = (socket, request) =>
            _reply(socket, _wrapped(), type: 'image/png');
        final media = await _get(child);
        expect(media.bytes, _wrapped());
        expect(media.headers.contentType?.mimeType, 'image/png');
      }
    });
  }

  for (final kind in ['wrapped', 'binary', 'large-png']) {
    test('$kind forwards first bytes before upstream EOF', () async {
      final release = Completer<void>();
      var eof = false;
      final b = kind == 'wrapped'
          ? _wrapped(2000)
          : kind == 'binary'
          ? List.filled(400000, 42)
          : [..._png, ...List.filled(400000, 42)];
      origin.respond = (socket, request) async {
        socket.add(_headers(b.length, type: 'image/png'));
        socket.add(b.sublist(0, 20000));
        await socket.flush();
        await release.future;
        socket.add(b.sublist(20000));
        await socket.flush();
        eof = true;
      };
      final client = HttpClient();
      try {
        final req = await client.getUrl(Uri.parse(url(managed())));
        final response = await req.close().timeout(const Duration(seconds: 2));
        final iterator = StreamIterator(response);
        expect(
          await iterator.moveNext().timeout(const Duration(seconds: 2)),
          isTrue,
        );
        expect(eof, isFalse);
        final bytes = BytesBuilder()..add(iterator.current);
        release.complete();
        while (await iterator.moveNext()) {
          bytes.add(iterator.current);
        }
        await iterator.cancel();
        expect(bytes.takeBytes(), kind == 'wrapped' ? _ts(2000) : b);
      } finally {
        if (!release.isCompleted) release.complete();
        client.close(force: true);
      }
    });
  }
  test(
    'ordinary PNG nonzero range remains unchanged after one negative probe',
    () async {
      origin.respond = (socket, request) => _reply(
        socket,
        _png,
        type: 'image/png',
        status: '206 Partial Content',
        extra: request.contains('bytes=0-16383')
            ? 'Content-Range: bytes 0-69/70\r\n'
            : 'Content-Range: bytes 1000-1069/2000\r\n',
      );
      final r = await _get(url(managed()), range: 'bytes=1000-');
      expect(r.status, 206);
      expect(r.bytes, _png);
      expect(r.headers.value('content-range'), 'bytes 1000-1069/2000');
      expect(origin.requests.length, 2);
    },
  );
  test('unknown-length proof exceeding byte quota fails closed before media output', () async {
    origin.respond = (socket, request) async {
      socket.add(
        ascii.encode(
          'HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nConnection: close\r\n\r\n',
        ),
      );
      socket.add(_wrapped());
      await socket.flush();
    };
    final r = await _get(url(managed(maxBytes: 400)));
    expect(r.status, 429);
  });
  for (final point in ['prefix', 'copy']) {
    test('token revoke cancels stalled $point and closes upstream', () async {
      final s = managed();
      final started = Completer<void>();
      origin.respond = (socket, request) async {
        socket.add(_headers(1000000, type: 'image/png'));
        socket.add(point == 'prefix' ? _png.take(4).toList() : _wrapped());
        await socket.flush();
        started.complete();
      };
      final client = HttpClient();
      try {
        final req = await client.getUrl(Uri.parse(url(s)));
        final response = req.close();
        await started.future.timeout(const Duration(seconds: 2));
        await Future<void>.delayed(const Duration(milliseconds: 40));
        proxy.sessions.revoke(s.token);
        final r = await response.timeout(const Duration(seconds: 2));
        if (point == 'prefix') expect(r.statusCode, 401);
        try {
          await r.drain<void>().timeout(const Duration(seconds: 2));
        } on HttpException catch (_) {}
        await origin.closed.future.timeout(const Duration(seconds: 2));
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(proxy.activeRequests, 0);
      } finally {
        client.close(force: true);
      }
    });
  }
  test(
    'client disconnect releases idle upstream within read timeout',
    () async {
      await proxy.stop();
      proxy = LocalProxyServer(
        log: LogService(),
        requestTimeout: const Duration(milliseconds: 150),
      );
      await proxy.start();
      final s = managed();
      origin.respond = (socket, request) async {
        socket.add(_headers(1000000, type: 'image/png'));
        socket.add(_wrapped());
        await socket.flush();
      };
      final client = HttpClient();
      try {
        final req = await client.getUrl(Uri.parse(url(s)));
        final r = await req.close().timeout(const Duration(seconds: 2));
        expect(r.headers.contentType?.mimeType, 'video/mp2t');
        await r.listen(null).cancel();
        client.close(force: true);
        await origin.closed.future.timeout(const Duration(seconds: 2));
      } finally {
        client.close(force: true);
      }
    },
  );
  test('stalled prefix read times out and releases upstream', () async {
    await proxy.stop();
    proxy = LocalProxyServer(
      log: LogService(),
      requestTimeout: const Duration(milliseconds: 150),
    );
    await proxy.start();
    origin.respond = (socket, request) async {
      socket.add(_headers(1000000, type: 'image/png'));
      socket.add(_png.take(4).toList());
      await socket.flush();
    };
    final r = await _get(url(managed()));
    expect(r.status, 502);
    await origin.closed.future.timeout(const Duration(seconds: 2));
  });
  test(
    'proof requires structural IEND and all three 188-spaced syncs within cap',
    () {
      int? probe(List<int> b) {
        final p = PngWrappedTransportStreamProbe();
        for (final byte in b) {
          p.add(byte);
        }
        return p.offset;
      }

      expect(probe(_wrapped()), _png.length);
      expect(probe([..._png, ..._ts().take(376)]), isNull);
      final bad = _wrapped();
      bad[_png.length + 188] = 1;
      expect(probe(bad), isNull);
      final forged = [
        ..._png.take(41),
        0,
        0,
        0,
        0,
        73,
        69,
        78,
        68,
        174,
        66,
        96,
        130,
        ..._ts(),
      ];
      expect(probe(forged), isNull);
      final large = [
        ..._png.take(8),
        0,
        0,
        64,
        0,
        73,
        68,
        65,
        84,
        ...List.filled(16384, 1),
        ..._png.skip(58),
        ..._ts(),
      ];
      final p = PngWrappedTransportStreamProbe();
      for (final byte in large.take(
        PngWrappedTransportStreamProbe.prefixLimit,
      )) {
        p.add(byte);
      }
      expect(p.done, isTrue);
      expect(p.offset, isNull);
    },
  );
  test(
    'public Android provenance hint enables proof without a target resolver',
    () async {
      await proxy.stop();
      proxy = LocalProxyServer(
        log: LogService(),
        policy: const ProxyTargetPolicy(allowLoopback: true),
      );
      await proxy.start();
      final session = proxy.sessions.create(
        siteKey: 'verified-android',
        inspectPlaylistContent: true,
      );
      final r = await _get(
        proxy.urlFor(
          session,
          Uri.parse('http://127.0.0.1:${origin.port}/segment'),
        ),
      );
      expect(r.bytes, _ts());
      expect(r.headers.contentType?.mimeType, 'video/mp2t');
    },
  );
  test(
    'comments after EXTINF preserve alias role and key URI remains excluded',
    () async {
      final s = managed();
      origin.respond = (socket, request) => _reply(
        socket,
        utf8.encode(
          '#EXTM3U\n#EXT-X-KEY:METHOD=NONE,URI="unused.png"\n#EXTINF:1,\n# comment\nimage.png\n#EXT-X-ENDLIST\n',
        ),
        type: 'application/vnd.apple.mpegurl',
      );
      final r = await _get(url(s));
      final text = utf8.decode(r.bytes);
      expect(text, contains('/i/1.ts'));
      expect(text, isNot(contains('/i/0.ts')));
      origin.respond = (socket, request) =>
          _reply(socket, _wrapped(), type: 'image/png');
      final key = RegExp(r'URI="([^"]*)"').firstMatch(text)!.group(1)!;
      expect((await _get(key)).bytes, _wrapped());
    },
  );
  test('proof retry never masks an upstream 404', () async {
    final b = _wrapped();
    origin.respond = (socket, request) =>
        request.toLowerCase().contains('range:')
        ? _reply(
            socket,
            b.take(700).toList(),
            type: 'image/png',
            status: '206 Partial Content',
            extra: 'Content-Range: bytes 0-699/${b.length}\r\n',
          )
        : _reply(
            socket,
            utf8.encode('<Error>NoSuchKey</Error>'),
            type: 'application/xml',
            status: '404 Not Found',
          );
    final r = await _get(url(managed()), range: 'bytes=0-');
    expect(r.status, 404);
    expect(origin.requests.length, 2);
    expect(utf8.decode(r.bytes), contains('NoSuchKey'));
  });
  for (final type in ['application/json', 'application/vnd.apple.mpegurl']) {
    test(
      'full proof retry rejects changed representation type $type',
      () async {
        final b = _wrapped();
        origin.respond = (socket, request) =>
            request.toLowerCase().contains('range:')
            ? _reply(
                socket,
                b.take(700).toList(),
                type: 'image/png',
                status: '206 Partial Content',
                extra: 'Content-Range: bytes 0-699/${b.length}\r\n',
              )
            : _reply(
                socket,
                utf8.encode(
                  type.contains('json')
                      ? '{"error":"fixture"}'
                      : '#EXTM3U\n#EXTINF:1,\nimage.png\n',
                ),
                type: type,
              );
        final r = await _get(url(managed()), range: 'bytes=0-');
        expect(r.status, 502);
        expect(origin.requests.length, 2);
      },
    );
  }
  test(
    'healthy streaming resets idle deadline rather than total movie cutoff',
    () async {
      await proxy.stop();
      proxy = LocalProxyServer(
        log: LogService(),
        requestTimeout: const Duration(milliseconds: 150),
      );
      await proxy.start();
      final b = _wrapped(2000);
      origin.respond = (socket, request) async {
        socket.add(_headers(b.length, type: 'image/png'));
        for (var i = 0; i < b.length; i += 20000) {
          socket.add(b.sublist(i, i + 20000 > b.length ? b.length : i + 20000));
          await socket.flush();
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      };
      final r = await _get(url(managed()));
      expect(r.status, 200);
      expect(r.bytes, _ts(2000));
    },
  );
  test(
    'filled registered child table cannot normalize an aliasless new resource',
    () async {
      final s = managed();
      for (var i = 0; i < ProxySession.maxChildTargets; i++) {
        s.indexOfChild(Uri.parse('http://guest.local:5000/fill-$i'));
      }
      origin.respond = (socket, request) => _reply(
        socket,
        utf8.encode('#EXTM3U\n#EXTINF:1,\nnew.png\n#EXT-X-ENDLIST\n'),
        type: 'application/vnd.apple.mpegurl',
      );
      final manifest = await _get(url(s));
      final child = const LineSplitter()
          .convert(utf8.decode(manifest.bytes))
          .singleWhere((l) => l.startsWith('http'));
      origin.respond = (socket, request) =>
          _reply(socket, _wrapped(), type: 'image/png');
      final r = await _get(child);
      expect(r.bytes, _wrapped());
      expect(r.headers.contentType?.mimeType, 'image/png');
    },
  );
  test(
    'nonzero-range PNG keeps original 206 when prefix probe is 404',
    () async {
      final body = _wrapped();
      origin.respond = (socket, request) =>
          request.toLowerCase().contains('range: bytes=0-16383')
          ? _reply(
              socket,
              utf8.encode('<Error>NoSuchKey</Error>'),
              type: 'application/xml',
              status: '404 Not Found',
            )
          : _reply(
              socket,
              body.sublist(1000),
              type: 'image/png',
              status: '206 Partial Content',
              extra:
                  'Content-Range: bytes 1000-${body.length}/${body.length}\r\n',
            );
      final r = await _get(url(managed()), range: 'bytes=1000-');
      expect(r.status, 206);
      expect(r.bytes, body.sublist(1000));
      expect(r.headers.contentType?.mimeType, 'image/png');
      expect(
        r.headers.value('content-range'),
        'bytes 1000-${body.length}/${body.length}',
      );
      expect(origin.requests.length, 2);
    },
  );
  for (final shape in ['map', 'key', 'variant', 'byterange']) {
    test('saturated long-form $shape role never normalizes', () async {
      final s = managed();
      for (var i = 0; i < ProxySession.maxChildTargets; i++) {
        s.indexOfChild(Uri.parse('http://guest.local:5000/fill-$i'));
      }
      final tag = shape == 'map'
          ? '#EXT-X-MAP:URI="init.png"\n'
          : shape == 'key'
          ? '#EXT-X-KEY:METHOD=AES-128,URI="key.png"\n'
          : shape == 'variant'
          ? '#EXT-X-STREAM-INF:BANDWIDTH=100\n'
          : '#EXT-X-BYTERANGE:1000@0\n';
      final role = shape == 'variant' ? '' : '#EXTINF:1,\n';
      final playlist = '#EXTM3U\n$tag${role}image.png\n#EXT-X-ENDLIST\n';
      origin.respond = (socket, request) => _reply(
        socket,
        utf8.encode(playlist),
        type: 'application/vnd.apple.mpegurl',
      );
      final manifest = await _get(url(s));
      final text = utf8.decode(manifest.bytes);
      expect(text, isNot(contains('.ts')));
      final children = [
        ...const LineSplitter()
            .convert(text)
            .where((line) => line.startsWith('http')),
        ...RegExp(r'URI="([^"]*)"')
            .allMatches(text)
            .map((match) => match.group(1)!),
      ];
      origin.respond = (socket, request) =>
          _reply(socket, _wrapped(), type: 'image/png');
      for (final child in children) {
        final r = await _get(child);
        expect(r.status, 200);
        expect(r.bytes, _wrapped());
        expect(r.headers.contentType?.mimeType, 'image/png');
      }
    });
  }
  test(
    '4097 overflow EXTINF children cannot fail open after metadata saturation',
    () async {
      final s = managed();
      for (var i = 0; i < ProxySession.maxChildTargets; i++) {
        s.indexOfChild(Uri.parse('http://guest.local:5000/fill-$i'));
      }
      final playlist = StringBuffer('#EXTM3U\n#EXT-X-TARGETDURATION:1\n');
      for (var i = 0; i <= ProxySession.maxChildTargets; i++) {
        playlist.write('#EXTINF:1,\nimage-$i.png\n');
      }
      playlist.write('#EXT-X-ENDLIST\n');
      origin.respond = (socket, request) => _reply(
        socket,
        utf8.encode(playlist.toString()),
        type: 'application/vnd.apple.mpegurl',
      );
      final manifest = await _get(url(s));
      final children = const LineSplitter()
          .convert(utf8.decode(manifest.bytes))
          .where((line) => line.startsWith('http'))
          .toList();
      expect(children.length, 4097);
      origin.respond = (socket, request) =>
          _reply(socket, _wrapped(), type: 'image/png');
      for (final child in [children.first, children.last]) {
        final r = await _get(child);
        expect(r.status, 200);
        expect(r.bytes, _wrapped());
        expect(r.headers.contentType?.mimeType, 'image/png');
      }
    },
  );
  for (final point in ['headers', 'prefix']) {
    test(
      'optional nonzero PNG probe $point stall replays original 206',
      () async {
        await proxy.stop();
        proxy = LocalProxyServer(
          log: LogService(),
          requestTimeout: const Duration(milliseconds: 150),
        );
        await proxy.start();
        final body = _png.sublist(20);
        final probeClosed = Completer<void>();
        origin.respond = (socket, request) async {
          if (request.contains('bytes=0-16383')) {
            origin.peerClosed[socket]!.future.then((_) {
              if (!probeClosed.isCompleted) probeClosed.complete();
            });
            if (point == 'prefix') {
              socket.add(
                _headers(
                  10000,
                  type: 'image/png',
                  status: '206 Partial Content',
                  extra: 'Content-Range: bytes 0-9999/10000\r\n',
                ),
              );
              socket.add(_png.take(4).toList());
              await socket.flush();
            }
          } else {
            await _reply(
              socket,
              body,
              type: 'image/png',
              status: '206 Partial Content',
              extra: 'Content-Range: bytes 20-69/70\r\nETag: fixture\r\nAccept-Ranges: bytes\r\n',
            );
          }
        };
        final s = managed();
        final r = await _get(url(s), range: 'bytes=20-');
        expect(r.status, 206);
        expect(r.bytes, body);
        expect(r.headers.contentType?.mimeType, 'image/png');
        expect(r.headers.value('content-range'), 'bytes 20-69/70');
        expect(r.headers.value('etag'), 'fixture');
        expect(origin.requests.length, 2);
        expect(s.requests, 2);
        await probeClosed.future.timeout(const Duration(seconds: 2));
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(proxy.activeRequests, 0);
      },
    );
  }
  for (final reason in [
    'token',
    'endpoint',
    'resolver-timeout',
    'host-policy',
    'requests',
    'bytes',
  ]) {
    test('optional probe still fails closed on $reason', () async {
      await proxy.stop();
      final schemes = <String>['http'];
      proxy = LocalProxyServer(
        log: LogService(),
        policy: ProxyTargetPolicy(allowedSchemes: schemes),
        requestTimeout: const Duration(milliseconds: 150),
      );
      await proxy.start();
      var resolves = 0;
      late ProxySession s;
      s = managed(
        maxRequests: reason == 'requests' ? 1 : 4096,
        maxBytes: reason == 'bytes' ? 100 : null,
        resolver: (target) async {
          resolves++;
          if (resolves == 2 && reason == 'host-policy') schemes.clear();
          if (resolves == 2 && reason == 'token') {
            proxy.sessions.revoke(s.token);
          }
          if (resolves == 2 && reason == 'resolver-timeout') {
            return Completer<int?>().future;
          }
          return resolves == 2 && reason == 'endpoint'
              ? origin.port + 1
              : origin.port;
        },
      );
      origin.respond = (socket, request) => _reply(
        socket,
        request.contains('bytes=0-16383') ? _wrapped() : _png.sublist(20),
        type: 'image/png',
        status: '206 Partial Content',
        extra: request.contains('bytes=0-16383')
            ? 'Content-Range: bytes 0-1573/1574\r\n'
            : 'Content-Range: bytes 20-69/70\r\n',
      );
      final r = await _get(url(s), range: 'bytes=20-');
      expect(
        r.status,
        reason == 'token'
            ? 401
            : reason == 'host-policy'
            ? 403
            : reason == 'requests' || reason == 'bytes'
            ? 429
            : 502,
      );
      expect(origin.requests.length, reason == 'bytes' ? 2 : 1);
    });
  }
  test(
    'registered positive alias remains eligible after child table fills',
    () async {
      final s = managed();
      origin.respond = (socket, request) => _reply(
        socket,
        utf8.encode('#EXTM3U\n#EXTINF:1,\nimage.png\n#EXT-X-ENDLIST\n'),
        type: 'application/vnd.apple.mpegurl',
      );
      final manifest = await _get(url(s));
      final child = const LineSplitter()
          .convert(utf8.decode(manifest.bytes))
          .singleWhere((line) => line.startsWith('http'));
      expect(child, endsWith('/i/0.ts'));
      for (var i = 1; i < ProxySession.maxChildTargets; i++) {
        s.indexOfChild(Uri.parse('http://guest.local:5000/fill-$i'));
      }
      origin.respond = (socket, request) =>
          _reply(socket, _wrapped(), type: 'image/png');
      expect((await _get(child)).bytes, _ts());
      final unknown = proxy.urlFor(
        s,
        Uri.parse('http://guest.local:5000/unregistered.png'),
      );
      expect((await _get(unknown)).bytes, _wrapped());
      final unknownIndex = proxy.urlForChild(
        s,
        Uri.parse('http://guest.local:5000/fill-1'),
      );
      expect((await _get(unknownIndex)).bytes, _wrapped());
    },
  );
  test('direct approved media remains eligible with full table before any manifest', () async {
    final s = managed();
    for (var i = 0; i < ProxySession.maxChildTargets; i++) {
      s.indexOfChild(Uri.parse('http://guest.local:5000/fill-$i'));
    }
    final r = await _get(url(s));
    expect(r.bytes, _ts());
    expect(r.headers.contentType?.mimeType, 'video/mp2t');
  });
  test(
    'registered media source survives checked redirect and full retry',
    () async {
      final s = managed();
      origin.respond = (socket, request) => _reply(
        socket,
        utf8.encode('#EXTM3U\n#EXTINF:1,\nimage.png\n#EXT-X-ENDLIST\n'),
        type: 'application/vnd.apple.mpegurl',
      );
      final manifest = await _get(url(s));
      final child = const LineSplitter()
          .convert(utf8.decode(manifest.bytes))
          .singleWhere((line) => line.startsWith('http'));
      origin.respond = (socket, request) {
        if (request.split(' ')[1] == '/image.png') {
          return _reply(
            socket,
            [],
            status: '302 Found',
            extra: 'Location: /final.png\r\n',
          );
        }
        if (request.contains('range:') || request.contains('Range:')) {
          return _reply(
            socket,
            _wrapped().take(700).toList(),
            type: 'image/png',
            status: '206 Partial Content',
            extra: 'Content-Range: bytes 0-699/1574\r\n',
          );
        }
        return _reply(socket, _wrapped(), type: 'image/png');
      };
      final r = await _get(child, range: 'bytes=0-');
      expect(r.bytes, _ts());
      expect(r.status, 200);
      expect(r.headers.contentType?.mimeType, 'video/mp2t');
    },
  );
}

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
  final closed = Completer<void>();
  final peerClosed = <Socket, Completer<void>>{};
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
      origin.peerClosed[socket] = Completer<void>();
      final bytes = BytesBuilder(copy: false);
      var sent = false;
      socket.listen(
        (chunk) {
          if (sent) return;
          bytes.add(chunk);
          final request = latin1.decode(bytes.toBytes());
          if (!request.contains('\r\n\r\n')) return;
          sent = true;
          origin.requests.add(request);
          unawaited(origin.respond(socket, request).catchError((Object _) {}));
        },
        onError: (Object _) {},
        onDone: () {
          socket.destroy();
          if (!origin.peerClosed[socket]!.isCompleted) {
            origin.peerClosed[socket]!.complete();
          }
          if (!origin.closed.isCompleted) origin.closed.complete();
        },
      );
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
