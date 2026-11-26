import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/proxy_policy.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/proxy_server.dart';

const _vod = '''#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:6
#EXT-X-PLAYLIST-TYPE:VOD
#EXTINF:6.000,
seg-0.ts
#EXTINF:6.000,
seg-1.ts
#EXTINF:6.000,
seg-2.ts
#EXT-X-ENDLIST
''';

void main() {
  test('suffixless text/plain HLS Range response is a complete rewritten VOD', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final hits = <String>[];
    final bytes = utf8.encode(_vod);
    server.listen((request) async {
      hits.add(request.headers.value(HttpHeaders.rangeHeader) ?? '');
      request.response
        ..statusCode = HttpStatus.partialContent
        ..headers.set(
          HttpHeaders.contentTypeHeader,
          'text/plain; charset=utf-8',
        )
        ..headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes 0-${bytes.length - 1}/${bytes.length}',
        )
        ..headers.contentLength = bytes.length
        ..add(bytes);
      await request.response.close();
    });
    final log = LogService();
    final proxy = LocalProxyServer(
      log: log,
      policy: const ProxyTargetPolicy(allowLoopback: true),
    );
    final client = HttpClient();
    try {
      await proxy.start();
      final session = proxy.sessions.create(
        siteKey: 'fixture',
        allowedHosts: {'127.0.0.1'},
      );
      final target = Uri.parse(
        'http://127.0.0.1:${server.port}/nby/m3u8/getM3u8?url=upstream.m3u8&token=PRIVATE',
      );
      final request = await client.getUrl(
        Uri.parse(proxy.urlFor(session, target)),
      );
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-');
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      final shape = HlsPlaylistShape.parse(body);
      expect(shape.totalSeconds, 18);
      expect(shape.segments, 3);
      expect(shape.hasEndList, isTrue);
      expect(hits, ['bytes=0-']);
      expect(response.statusCode, HttpStatus.ok);
      expect(
        response.headers.contentType?.mimeType,
        'application/vnd.apple.mpegurl',
      );
      expect(response.headers.value(HttpHeaders.contentRangeHeader), isNull);
      expect(response.contentLength, utf8.encode(body).length);
      expect(body, contains('${proxy.baseUrl}/p/${session.token}/i/'));
    } finally {
      client.close(force: true);
      await proxy.stop();
      await server.close(force: true);
    }
  });

  group('bounded HLS detection through real HTTP', () {
    late HttpServer upstream;
    late LocalProxyServer proxy;
    late HttpClient client;
    late ProxySession session;
    late LogService log;
    late Future<void> Function(HttpRequest) serve;

    setUp(() async {
      upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      serve = (request) async {
        request.response.headers.set(
          'content-type',
          'application/octet-stream',
        );
        request.response.add(utf8.encode(_vod));
      };
      upstream.listen((request) async {
        try {
          await serve(request);
          await request.response.close();
        } catch (_) {
          // The bounded-read and cancellation cases intentionally disconnect.
        }
      });
      log = LogService();
      proxy = LocalProxyServer(
        log: log,
        policy: const ProxyTargetPolicy(allowLoopback: true),
        requestTimeout: const Duration(seconds: 2),
      );
      await proxy.start();
      session = proxy.sessions.create(
        siteKey: 'fixture',
        allowedHosts: {'127.0.0.1'},
      );
      client = HttpClient()..autoUncompress = false;
    });

    tearDown(() async {
      client.close(force: true);
      await proxy.stop();
      await upstream.close(force: true);
    });

    Future<HttpClientResponse> open({
      String path = '/getM3u8?url=x.m3u8&token=PRIVATE',
      String method = 'GET',
      String? range,
    }) async {
      final target = Uri.parse('http://127.0.0.1:${upstream.port}$path');
      final request = await client.openUrl(
        method,
        Uri.parse(proxy.urlFor(session, target)),
      );
      if (range != null) request.headers.set('range', range);
      return request.close();
    }

    test('binary MIME HLS is rewritten, with safe synthesized headers and diagnostics', () async {
      serve = (request) async {
        request.response.headers
          ..set('content-type', 'application/octet-stream')
          ..set('accept-ranges', 'bytes')
          ..set('etag', 'old-entity')
          ..set('last-modified', 'Wed, 21 Oct 2015 07:28:00 GMT')
          ..set('set-cookie', 'secret=PRIVATE')
          ..set('cache-control', 'no-cache');
        request.response.add(utf8.encode(_vod));
      };
      final response = await open();
      final body = await response.transform(utf8.decoder).join();
      expect(response.statusCode, 200);
      expect(
        response.headers.contentType?.mimeType,
        'application/vnd.apple.mpegurl',
      );
      expect(HlsPlaylistShape.parse(body).totalSeconds, 18);
      for (final header in [
        'accept-ranges',
        'etag',
        'last-modified',
        'set-cookie',
      ]) {
        expect(response.headers.value(header), isNull);
      }
      expect(response.headers.value('cache-control'), 'no-cache');
      final entries = log.entries.map((e) => e.message).join('\n');
      expect(entries, contains('segments=3 extinfSum=18.0s endlist=yes'));
      expect(entries, isNot(contains('PRIVATE')));
      expect(entries, isNot(contains(session.token)));
    });

    test(
      'BOM whitespace and one-byte chunks still recognize only the signature',
      () async {
        serve = (request) async {
          for (final byte in utf8.encode('﻿ \r\n\t$_vod')) {
            request.response.add([byte]);
            await request.response.flush();
          }
        };
        final response = await open();
        final body = await response.transform(utf8.decoder).join();
        expect(
          response.headers.contentType?.mimeType,
          'application/vnd.apple.mpegurl',
        );
        expect(HlsPlaylistShape.parse(body).totalSeconds, 18);
        expect(body.split('\n').first, '#EXTM3U');
        expect(HlsPlaylistShape.parse(body).hasEndList, isTrue);
        expect(body, contains('${proxy.baseUrl}/p/${session.token}/i/'));
      },
    );

    for (final text in [
      '#EXTM3',
      '#EXTM3U',
      '#EXTM3UX\nnot-a-playlist',
      '<pre>靓仔链接失效了</pre>',
      'prefix #EXTM3U\n',
      '${' ' * 256}#EXTM3U\n',
    ]) {
      test(
        'non-signature prefix passes byte-exactly (${text.length} bytes)',
        () async {
          final bytes = utf8.encode(text);
          serve = (request) async {
            request.response.headers
              ..set('content-type', 'text/plain; charset=utf-8')
              ..contentLength = bytes.length;
            request.response.add(bytes);
          };
          final response = await open();
          expect(
            await response.fold<List<int>>([], (b, c) => b..addAll(c)),
            bytes,
          );
          expect(response.headers.contentType?.mimeType, 'text/plain');
          expect(response.contentLength, bytes.length);
        },
      );
    }

    for (final range in ['bytes=0-15', 'bytes=5-', 'bytes=-18']) {
      test(
        'actual partial $range stays 206 byte-exact even with HLS MIME',
        () async {
          final bytes = utf8.encode(_vod);
          final start = range == 'bytes=0-15'
              ? 0
              : range == 'bytes=5-'
              ? 5
              : bytes.length - 18;
          final end = range == 'bytes=0-15' ? 15 : bytes.length - 1;
          serve = (request) async {
            expect(request.headers.value('range'), range);
            request.response.statusCode = 206;
            request.response.headers
              ..set('content-type', 'application/vnd.apple.mpegurl')
              ..set('content-range', 'bytes $start-$end/${bytes.length}')
              ..set('accept-ranges', 'bytes')
              ..contentLength = end - start + 1;
            request.response.add(bytes.sublist(start, end + 1));
          };
          final response = await open(range: range, path: '/index.m3u8');
          expect(
            await response.fold<List<int>>([], (b, c) => b..addAll(c)),
            bytes.sublist(start, end + 1),
          );
          expect(response.statusCode, 206);
          expect(
            response.headers.value('content-range'),
            'bytes $start-$end/${bytes.length}',
          );
          expect(response.contentLength, end - start + 1);
        },
      );
    }

    test(
      'HEAD preserves upstream metadata without reading or synthesizing a body',
      () async {
        serve = (request) async {
          expect(request.method, 'HEAD');
          request.response.statusCode = 206;
          request.response.headers
            ..set('content-type', 'application/vnd.apple.mpegurl')
            ..set('content-range', 'bytes 0-174/175')
            ..contentLength = 175;
        };
        final response = await open(
          method: 'HEAD',
          range: 'bytes=0-',
          path: '/index.m3u8',
        );
        expect(
          await response.fold<List<int>>([], (b, c) => b..addAll(c)),
          isEmpty,
        );
        expect(response.statusCode, 206);
        expect(response.contentLength, 175);
        expect(response.headers.value('content-range'), 'bytes 0-174/175');
      },
    );

    test(
      'redirected HLS resolves relative children against final URI',
      () async {
        serve = (request) async {
          if (request.uri.path == '/start') {
            request.response.statusCode = 302;
            request.response.headers.set('location', '/cdn/vod/index.m3u8');
          } else {
            request.response.add(utf8.encode(_vod));
          }
        };
        final response = await open(path: '/start');
        final body = await response.transform(utf8.decoder).join();
        expect(response.statusCode, 200);
        expect(body, contains('${proxy.baseUrl}/p/${session.token}/i/0'));
        expect(session.childTargetAt(0)?.path, '/cdn/vod/seg-0.ts');
      },
    );

    test(
      'compressed bytes keep encoding and range, never decode as a playlist',
      () async {
        final bytes = gzip.encode(utf8.encode(_vod));
        serve = (request) async {
          expect(request.headers.value('accept-encoding'), 'identity');
          request.response.statusCode = 206;
          request.response.headers
            ..set('content-type', 'text/plain')
            ..set('content-encoding', 'gzip')
            ..set(
              'content-range',
              'bytes 0-${bytes.length - 1}/${bytes.length}',
            )
            ..contentLength = bytes.length;
          request.response.add(bytes);
        };
        final response = await open(range: 'bytes=0-');
        expect(
          await response.fold<List<int>>([], (b, c) => b..addAll(c)),
          bytes,
        );
        expect(response.statusCode, 206);
        expect(response.headers.value('content-encoding'), 'gzip');
        expect(response.contentLength, bytes.length);
      },
    );

    test('binary is streamed after first mismatching byte, not buffered to 64KB or EOF', () async {
      final release = Completer<void>();
      serve = (request) async {
        request.response.bufferOutput = false;
        request.response.headers.contentLength = 1024 * 1024;
        request.response.add([0x47]);
        await request.response.flush();
        await release.future;
        request.response.add(Uint8List(1024 * 1024 - 1));
      };
      try {
        final response = await open();
        final iterator = StreamIterator(response);
        expect(
          await iterator.moveNext().timeout(const Duration(seconds: 1)),
          isTrue,
        );
        expect(iterator.current, [
          0x47,
        ], reason: log.entries.map((e) => e.message).join('\n'));
        release.complete();
        var count = 1;
        while (await iterator.moveNext()) {
          count += iterator.current.length;
        }
        expect(count, 1024 * 1024);
        expect(response.contentLength, 1024 * 1024);
      } finally {
        if (!release.isCompleted) release.complete();
      }
    });

    test('an unexpected upstream prefix error is still reported', () async {
      final raw = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final handlers = <Future<void>>[];
      final connections = raw.listen((socket) {
        handlers.add(() async {
          final headers = <int>[];
          await for (final chunk in socket) {
            headers.addAll(chunk);
            if (ascii.decode(headers).contains('\r\n\r\n')) break;
          }
          socket.add(
            ascii.encode(
              'HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n'
              'Content-Length: 8388608\r\nConnection: close\r\n\r\n#',
            ),
          );
          await socket.flush();
          await socket.close();
          socket.destroy();
        }());
      });
      try {
        final target = Uri.parse('http://127.0.0.1:${raw.port}/getM3u8');
        final request = await client.getUrl(
          Uri.parse(proxy.urlFor(session, target)),
        );
        final response = await request.close();
        await response.drain<void>();
        expect(response.statusCode, 500);
        expect(
          log.entries.any(
            (entry) =>
                entry.level == LogLevel.error &&
                entry.message.contains('HttpException'),
          ),
          isTrue,
          reason: log.entries.map((entry) => entry.message).join('\n'),
        );
        expect(proxy.activeRequests, 0);
      } finally {
        await connections.cancel();
        await raw.close();
        await Future.wait(handlers);
      }
    });

    test('client cancellation owns pending inspected replay errors', () async {
      final errors = <String>[];
      final stopped = Completer<void>();
      final pendingRead = Completer<void>();
      final release = Completer<void>();
      var bytesRead = 0;
      serve = (request) async {
        request.response.bufferOutput = false;
        request.response.headers.contentLength = 8 * 1024 * 1024;
        request.response.add([0x47]);
        await request.response.flush();
        await release.future;
      };
      await proxy.stop();
      runZonedGuarded(
        () async {
          try {
            final upstreamClient = _ObservedHttpClient(
              HttpClient(),
              onPendingRead: () => pendingRead.complete(),
              onBytes: (count) => bytesRead += count,
            );
            proxy = LocalProxyServer(
              log: log,
              upstreamClient: upstreamClient,
              policy: const ProxyTargetPolicy(allowLoopback: true),
              requestTimeout: const Duration(seconds: 2),
            );
            await proxy.start();
            session = proxy.sessions.create(
              siteKey: 'fixture',
              allowedHosts: {'127.0.0.1'},
            );
            final response = await open();
            final iterator = StreamIterator(response);
            expect(await iterator.moveNext(), isTrue);
            expect(iterator.current, [0x47]);
            await pendingRead.future.timeout(const Duration(seconds: 1));
            expect(proxy.activeRequests, 1);
            client.close(force: true);
            await iterator.cancel();
            await proxy.stop();
            await Future<void>(() async {
              while (proxy.activeRequests != 0) {
                await Future<void>.delayed(const Duration(milliseconds: 10));
              }
            }).timeout(const Duration(seconds: 1));
          } finally {
            release.complete();
            stopped.complete();
          }
        },
        (error, stack) {
          errors.add('$error\n$stack');
        },
      );
      await stopped.future.timeout(const Duration(seconds: 4));
      await Future<void>.delayed(Duration.zero);
      expect(errors, isEmpty);
      expect(proxy.activeRequests, 0);
      expect(
        bytesRead,
        1,
        reason: 'Cancellation must not drain the 8 MiB body.',
      );
    });

    test('client cancellation closes the bounded binary stream and releases request slot', () async {
      var chunksSent = 0;
      serve = (request) async {
        request.response.bufferOutput = false;
        request.response.headers.contentLength = 128 * 64 * 1024;
        for (var i = 0; i < 128; i++) {
          request.response.add(Uint8List(64 * 1024));
          await request.response.flush();
          chunksSent++;
          await Future<void>.delayed(const Duration(milliseconds: 15));
        }
      };
      final response = await open();
      final iterator = StreamIterator(response);
      expect(await iterator.moveNext(), isTrue);
      client.close(force: true);
      await iterator.cancel();
      await Future<void>(() async {
        while (proxy.activeRequests != 0) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      }).timeout(const Duration(seconds: 2));
      expect(chunksSent, lessThan(128));
    });

    test(
      'known HLS signature retains the 16MiB playlist safety limit',
      () async {
        serve = (request) async {
          request.response.add(utf8.encode('#EXTM3U\n'));
          for (var i = 0; i < 17; i++) {
            request.response.add(Uint8List(1024 * 1024));
            await request.response.flush();
          }
        };
        final response = await open();
        await response.drain<void>();
        expect(response.statusCode, 500);
        expect(
          log.entries.any((e) => e.message.contains('HLS 清单超过 16 MiB')),
          isTrue,
        );
      },
    );
  });
}

class _ObservedHttpClient implements HttpClient {
  _ObservedHttpClient(
    this.delegate, {
    required this.onPendingRead,
    required this.onBytes,
  });

  final HttpClient delegate;
  final void Function() onPendingRead;
  final void Function(int) onBytes;

  @override
  set connectionTimeout(Duration? value) => delegate.connectionTimeout = value;
  @override
  set idleTimeout(Duration value) => delegate.idleTimeout = value;
  @override
  set autoUncompress(bool value) => delegate.autoUncompress = value;
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _ObservedRequest(
        await delegate.openUrl(method, url),
        onPendingRead,
        onBytes,
      );
  @override
  void close({bool force = false}) => delegate.close(force: force);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ObservedRequest implements HttpClientRequest {
  _ObservedRequest(this.delegate, this.onPendingRead, this.onBytes);

  final HttpClientRequest delegate;
  final void Function() onPendingRead;
  final void Function(int) onBytes;

  @override
  HttpHeaders get headers => delegate.headers;
  @override
  set followRedirects(bool value) => delegate.followRedirects = value;
  @override
  void abort([Object? exception, StackTrace? stackTrace]) =>
      delegate.abort(exception, stackTrace);
  @override
  Future<HttpClientResponse> close() async =>
      _ObservedResponse(await delegate.close(), onPendingRead, onBytes);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ObservedResponse extends Stream<List<int>>
    implements HttpClientResponse {
  _ObservedResponse(this.delegate, this.onPendingRead, this.onBytes);

  final HttpClientResponse delegate;
  final void Function() onPendingRead;
  final void Function(int) onBytes;

  @override
  HttpHeaders get headers => delegate.headers;
  @override
  int get contentLength => delegate.contentLength;
  @override
  int get statusCode => delegate.statusCode;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    late StreamSubscription<List<int>> source;
    var resumed = false;
    final controller = StreamController<List<int>>(sync: true);
    controller
      ..onListen = () {
        source = delegate.listen(
          (chunk) {
            onBytes(chunk.length);
            controller.add(chunk);
          },
          onError: controller.addError,
          onDone: controller.close,
        );
      }
      ..onPause = () {
        source.pause();
      }
      ..onResume = () {
        source.resume();
        if (!resumed) {
          resumed = true;
          onPendingRead();
        }
      }
      ..onCancel = () {
        return source.cancel();
      };
    return controller.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
