import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/core/cat_http.dart';
import 'package:webhtv_pc/core/http_api.dart';
import 'package:webhtv_pc/core/ipc_protocol.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/request_cancellation.dart';

void main() {
  for (final kind in _RequestKind.values) {
    test(
      '${kind.name} cancellation when the body arrives cannot publish a late success',
      () async {
        final server = await _WireServer.start();
        final transport = _ObservedClient();
        final client = _RequestClient(kind, transport);
        addTearDown(() async {
          transport.close();
          await server.close();
        });
        final cancellation = RequestCancellation();
        final reason = AppError(AppErrorKind.siteCancelled, 'obsolete search');
        transport.onBodyChunk = () => cancellation.cancel(reason);
        await expectLater(
          client.execute(server.uri('/ok'), cancellation: cancellation),
          throwsA(same(reason)),
        );
        expect(transport.closeCount, 0);
      },
    );

    test(
      '${kind.name} response-size limit is preserved on the abortable path',
      () async {
        final server = await _WireServer.start();
        final transport = _ObservedClient();
        final client = _RequestClient(kind, transport, maxResponseBytes: 8);
        addTearDown(() async {
          transport.close();
          await server.close();
        });
        await expectLater(
          client.execute(
            server.uri('/ok'),
            cancellation: RequestCancellation(),
          ),
          throwsA(
            kind == _RequestKind.catJson
                ? isA<SpiderError>().having(
                    (e) => e.code,
                    'code',
                    SpiderErrorCode.resourceLimit,
                  )
                : isA<AppError>().having(
                    (e) => e.kind,
                    'kind',
                    AppErrorKind.siteParse,
                  ),
          ),
        );
      },
    );

    test(
      '${kind.name} cancellation-capable request matches the legacy wire encoding',
      () async {
        final server = await _WireServer.start();
        final transport = _ObservedClient();
        final client = _RequestClient(kind, transport);
        addTearDown(() async {
          transport.close();
          await server.close();
        });
        final uri = server
            .uri('/legacy')
            .replace(queryParameters: {'wd': '中文 + &', 'pg': '2'});
        if (kind == _RequestKind.catJson) {
          await transport.post(
            uri,
            headers: {
              'Content-Type': 'application/json; charset=utf-8',
              'X-Wire-Test': 'cat',
            },
            body: jsonEncode({'wd': '中文 + &', 'pg': 2, 'quick': false}),
          );
        } else if (kind == _RequestKind.apiForm) {
          await transport.post(
            uri,
            headers: {'User-Agent': 'wire-agent', 'X-Wire-Test': 'api'},
            body: {'wd': '中文 + &', 'pg': '2'},
          );
        } else {
          await transport.get(
            uri,
            headers: {'User-Agent': 'wire-agent', 'X-Wire-Test': 'api'},
          );
        }
        await client.execute(
          server.uri('/ok'),
          cancellation: RequestCancellation(),
        );
        final legacy = await server.received('/legacy');
        final abortable = await server.received('/ok');
        expect(abortable.method, legacy.method);
        expect(abortable.headers, legacy.headers);
        expect(abortable.body, legacy.body);
        _expectWire(kind, abortable);
      },
    );

    test('${kind.name} pre-cancelled request is never sent', () async {
      final server = await _WireServer.start();
      final transport = _ObservedClient();
      final client = _RequestClient(kind, transport);
      addTearDown(() async {
        transport.close();
        await server.close();
      });
      final cancellation = RequestCancellation()..cancel();
      await expectLater(
        client.execute(server.uri('/never'), cancellation: cancellation),
        throwsA(same(cancellation.reason)),
      );
      expect(transport.sendCount, 0);
      final result = await client.execute(server.uri('/ok'));
      expect(result.list.single.vodName, 'wire success');
      expect(server.requests.map((r) => r.uri.path), ['/ok']);
    });

    for (final bodyInFlight in [false, true]) {
      test(
        '${kind.name} cancellation aborts ${bodyInFlight ? 'body' : 'headers'} and isolates an in-flight peer',
        () async {
          final server = await _WireServer.start();
          final transport = _ObservedClient();
          final client = _RequestClient(kind, transport);
          addTearDown(() async {
            transport.close();
            await server.close();
          });
          final cancellation = RequestCancellation();
          final path = bodyInFlight ? '/slow-body' : '/slow-headers';
          final target = client.execute(
            server.uri(path),
            cancellation: cancellation,
          );
          final outcome = expectLater(
            target,
            throwsA(
              isA<AppError>().having(
                (e) => e.kind,
                'kind',
                AppErrorKind.siteCancelled,
              ),
            ),
          );
          final captured = await server.received(path).timeout(_deadline);
          _expectWire(kind, captured);
          if (bodyInFlight) {
            await transport.firstBodyChunk.future.timeout(_deadline);
          }
          final peer = client.execute(server.uri('/held'));
          await server.received('/held').timeout(_deadline);
          cancellation.cancel();
          await outcome.timeout(_deadline);
          await server.disconnected(path).timeout(_deadline);
          expect(transport.closeCount, 0);
          server.complete('/held');
          expect(
            (await peer.timeout(_deadline)).list.single.vodName,
            'wire success',
          );
          final result = await client.execute(server.uri('/ok'));
          expect(result.list.single.vodName, 'wire success');
        },
      );
    }

    test(
      '${kind.name} cancellation preserves an external timeout reason',
      () async {
        final server = await _WireServer.start();
        final transport = _ObservedClient();
        final client = _RequestClient(kind, transport);
        addTearDown(() async {
          transport.close();
          await server.close();
        });
        final cancellation = RequestCancellation();
        final reason = AppError(
          AppErrorKind.siteTimeout,
          'search budget exhausted',
        );
        final target = client.execute(
          server.uri('/slow-headers'),
          cancellation: cancellation,
        );
        final outcome = expectLater(target, throwsA(same(reason)));
        await server.received('/slow-headers').timeout(_deadline);
        cancellation.cancel(reason);
        await outcome.timeout(_deadline);
        await server.disconnected('/slow-headers').timeout(_deadline);
        expect(transport.closeCount, 0);
      },
    );

    for (final bodyInFlight in [false, true]) {
      test(
        '${kind.name} timeout aborts ${bodyInFlight ? 'body' : 'headers'} on the wire without closing the shared client',
        () async {
          final server = await _WireServer.start();
          final transport = _ObservedClient();
          final client = _RequestClient(
            kind,
            transport,
            timeout: const Duration(milliseconds: 300),
          );
          addTearDown(() async {
            transport.close();
            await server.close();
          });
          final path = bodyInFlight ? '/slow-body' : '/slow-headers';
          final request = client.execute(server.uri(path));
          final outcome = expectLater(
            request,
            throwsA(
              kind == _RequestKind.catJson
                  ? isA<SpiderError>().having(
                      (e) => e.toAppError().kind,
                      'kind',
                      AppErrorKind.siteTimeout,
                    )
                  : isA<AppError>().having(
                      (e) => e.kind,
                      'kind',
                      AppErrorKind.siteTimeout,
                    ),
            ),
          );
          await server.received(path).timeout(_deadline);
          if (bodyInFlight) {
            await transport.firstBodyChunk.future.timeout(_deadline);
          }
          await outcome;
          await server
              .disconnected(path)
              .timeout(
                _deadline,
                onTimeout: () => throw StateError(
                  'timed-out request remained connected: $path',
                ),
              );
          expect(transport.closeCount, 0);
          final result = await client.execute(server.uri('/ok'));
          expect(result.list.single.vodName, 'wire success');
        },
      );
    }
  }
}

const _deadline = Duration(seconds: 2);

enum _RequestKind { apiGet, apiForm, catJson }

class _RequestClient {
  _RequestClient(
    this.kind,
    http.Client transport, {
    Duration timeout = const Duration(seconds: 10),
    int maxResponseBytes = 8 * 1024 * 1024,
  }) : _api = HttpApiClient(
         client: transport,
         timeout: timeout,
         maxResponseBytes: maxResponseBytes,
       ),
       _cat = CatHttpClient(
         client: transport,
         timeout: timeout,
         maxResponseBytes: maxResponseBytes,
       );
  final _RequestKind kind;
  final HttpApiClient _api;
  final CatHttpClient _cat;

  Future<SiteResult> execute(Uri uri, {RequestCancellation? cancellation}) {
    if (kind == _RequestKind.catJson) {
      return _cat.call(
        CatHttpCall(
          route: CatHttpRoute.search,
          uri: uri,
          body: const {'wd': '中文 + &', 'pg': 2, 'quick': false},
          headers: const {
            'Content-Type': 'application/json; charset=utf-8',
            'X-Wire-Test': 'cat',
          },
        ),
        siteKey: 'wire-cat',
        cancellation: cancellation,
      );
    }
    return _api.execute(
      HttpApiCall(
        method: kind == _RequestKind.apiForm ? 'POST' : 'GET',
        uri: uri.replace(queryParameters: {'wd': '中文 + &', 'pg': '2'}),
        formBody: kind == _RequestKind.apiForm
            ? const {'wd': '中文 + &', 'pg': '2'}
            : null,
        headers: const {'User-Agent': 'wire-agent', 'X-Wire-Test': 'api'},
        action: 'search',
      ),
      siteKey: 'wire-api',
      cancellation: cancellation,
    );
  }
}

void _expectWire(_RequestKind kind, _WireRequest request) {
  if (kind == _RequestKind.catJson) {
    expect(request.method, 'POST');
    expect(request.headers['x-wire-test'], 'cat');
    expect(request.headers['content-type'], 'application/json; charset=utf-8');
    expect(jsonDecode(request.body), {'wd': '中文 + &', 'pg': 2, 'quick': false});
    expect(request.body, jsonEncode({'wd': '中文 + &', 'pg': 2, 'quick': false}));
  } else {
    expect(request.method, kind == _RequestKind.apiForm ? 'POST' : 'GET');
    expect(request.uri.queryParameters, {'wd': '中文 + &', 'pg': '2'});
    expect(request.headers['user-agent'], 'wire-agent');
    expect(request.headers['x-wire-test'], 'api');
    if (kind == _RequestKind.apiForm) {
      expect(
        request.headers['content-type'],
        'application/x-www-form-urlencoded',
      );
      expect(Uri.splitQueryString(request.body), {'wd': '中文 + &', 'pg': '2'});
      expect(request.body, 'wd=%E4%B8%AD%E6%96%87+%2B+%26&pg=2');
    } else {
      expect(request.body, isEmpty);
      expect(request.headers['content-type'], isNull);
    }
  }
}

class _ObservedClient extends http.BaseClient {
  final http.Client _inner = http.Client();
  final Completer<void> firstBodyChunk = Completer<void>();
  int closeCount = 0;
  int sendCount = 0;
  void Function()? onBodyChunk;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    sendCount++;
    final response = await _inner.send(request);
    return http.StreamedResponse(
      response.stream.map((chunk) {
        onBodyChunk?.call();
        if (request.url.path == '/slow-body' && !firstBodyChunk.isCompleted) {
          firstBodyChunk.complete();
        }
        return chunk;
      }),
      response.statusCode,
      headers: response.headers,
      request: request,
    );
  }

  @override
  void close() {
    closeCount++;
    _inner.close();
  }
}

class _WireRequest {
  _WireRequest(this.method, this.uri, this.headers, this.body);
  final String method;
  final Uri uri;
  final Map<String, String> headers;
  final String body;
}

class _WireServer {
  _WireServer(this._server) {
    _server.listen(_accept);
  }

  static Future<_WireServer> start() async =>
      _WireServer(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0));

  final ServerSocket _server;
  final Set<Socket> _sockets = {};
  final Map<String, Completer<_WireRequest>> _received = {};
  final Map<String, Completer<void>> _disconnected = {};
  final List<_WireRequest> requests = [];
  final Map<String, Socket> _held = {};

  Uri uri(String path) => Uri.parse('http://127.0.0.1:${_server.port}$path');
  Future<_WireRequest> received(String path) =>
      (_received[path] ??= Completer<_WireRequest>()).future;
  Future<void> disconnected(String path) =>
      (_disconnected[path] ??= Completer<void>()).future;

  void _accept(Socket socket) {
    _sockets.add(socket);
    final bytes = <int>[];
    String? path;
    var handled = false;
    void disconnected() {
      _sockets.remove(socket);
      if (path != null) {
        final done = _disconnected[path!] ??= Completer<void>();
        if (!done.isCompleted) done.complete();
      }
      socket.destroy();
    }

    socket.listen(
      (chunk) {
        if (handled) return;
        bytes.addAll(chunk);
        final raw = latin1.decode(bytes);
        final end = raw.indexOf('\r\n\r\n');
        if (end < 0) return;
        final lines = raw.substring(0, end).split('\r\n');
        final first = lines.first.split(' ');
        final headers = <String, String>{};
        for (final line in lines.skip(1)) {
          final separator = line.indexOf(':');
          headers[line.substring(0, separator).toLowerCase()] = line
              .substring(separator + 1)
              .trim();
        }
        final length = int.parse(headers['content-length'] ?? '0');
        if (bytes.length < end + 4 + length) return;
        handled = true;
        final uri = Uri.parse(first[1]);
        path = uri.path;
        final request = _WireRequest(
          first[0],
          uri,
          headers,
          utf8.decode(bytes.sublist(end + 4, end + 4 + length)),
        );
        requests.add(request);
        (_received[path!] ??= Completer<_WireRequest>()).complete(request);
        if (path == '/slow-headers') return;
        if (path == '/held') {
          _held[path!] = socket;
          return;
        }
        if (path == '/slow-body') {
          socket.write(
            'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n1\r\n{\r\n',
          );
          return;
        }
        _respond(socket);
      },
      onDone: disconnected,
      onError: (Object _) => disconnected(),
    );
  }

  void complete(String path) => _respond(_held.remove(path)!);

  void _respond(Socket socket) {
    final body = utf8.encode(
      '{"list":[{"vod_id":"wire-1","vod_name":"wire success"}]}',
    );
    socket.write(
      'HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: ${body.length}\r\nConnection: close\r\n\r\n',
    );
    socket.add(body);
    unawaited(socket.flush().then((_) => socket.close()));
  }

  Future<void> close() async {
    for (final socket in _sockets.toList()) {
      socket.destroy();
    }
    await _server.close();
  }
}
