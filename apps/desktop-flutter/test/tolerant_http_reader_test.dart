/// 容错读取器（严格但有界）的真实 socket 单测。
///
/// 全部用例用手写 HTTP/1.1 字面量发到本机原始 socket，不经 HttpServer，
/// 因此可以如实复现「同一个分帧头出现两次」这类 HttpServer 无法生成的响应。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/services/tolerant_http_reader.dart';

void main() {
  const timeout = Duration(seconds: 5);

  TolerantHttpReader reader() =>
      TolerantHttpReader(connectTimeout: timeout, idleTimeout: timeout);

  Future<TolerantHttpResponse> send(
    _RawUpstream upstream, {
    String path = '/media.bin',
    String method = 'GET',
    Map<String, String> headers = const {},
  }) {
    return reader().send(
      wireTarget: Uri.parse('http://127.0.0.1:${upstream.port}$path'),
      method: method,
      headers: headers,
      timeout: timeout,
    );
  }

  test(
    'duplicate identical Content-Length is collapsed and body matches',
    () async {
      final upstream = await _RawUpstream.start(
        'HTTP/1.1 206 Partial Content\r\n'
        'Content-Length: 10\r\n'
        'Content-Length: 10\r\n'
        'Content-Range: bytes 0-9/1024\r\n'
        'Content-Type: video/mp4\r\n'
        '\r\n'
        '0123456789',
      );
      addTearDown(upstream.stop);
      final response = await send(upstream);
      addTearDown(response.close);
      expect(response.statusCode, 206);
      expect(response.headers['content-length'], '10');
      expect(response.contentLength, 10);
      expect(response.headers['content-range'], 'bytes 0-9/1024');
      expect(utf8.decode(await _read(response.body)), '0123456789');
    },
  );

  test(
    'duplicate differing Content-Length fails closed without values',
    () async {
      final upstream = await _RawUpstream.start(
        'HTTP/1.1 200 OK\r\n'
        'Content-Length: 1024\r\n'
        'Content-Length: 2048\r\n'
        '\r\n'
        'x',
      );
      addTearDown(upstream.stop);
      final error = await _expectError(send(upstream));
      expect(error.kind, TolerantHttpFailureKind.framing);
      expect(error.message, contains('Content-Length'));
      expect(error.message, isNot(contains('1024')));
      expect(error.message, isNot(contains('2048')));
      expect(error.toString(), isNot(contains('1024')));
      expect(error.toString(), isNot(contains('2048')));
    },
  );

  test('duplicate identical Content-Range is accepted', () async {
    final upstream = await _RawUpstream.start(
      'HTTP/1.1 206 Partial Content\r\n'
      'Content-Length: 4\r\n'
      'Content-Range: bytes 0-3/64\r\n'
      'Content-Range: bytes 0-3/64\r\n'
      '\r\n'
      'abcd',
    );
    addTearDown(upstream.stop);
    final response = await send(upstream);
    addTearDown(response.close);
    expect(response.headers['content-range'], 'bytes 0-3/64');
    expect(utf8.decode(await _read(response.body)), 'abcd');
  });

  test('duplicate differing Content-Range fails closed', () async {
    final upstream = await _RawUpstream.start(
      'HTTP/1.1 206 Partial Content\r\n'
      'Content-Length: 4\r\n'
      'Content-Range: bytes 0-3/64\r\n'
      'Content-Range: bytes 0-3/128\r\n'
      '\r\n'
      'abcd',
    );
    addTearDown(upstream.stop);
    final error = await _expectError(send(upstream));
    expect(error.kind, TolerantHttpFailureKind.framing);
    expect(error.message, contains('Content-Range'));
    expect(error.message, isNot(contains('128')));
  });

  test('response head over 32 KiB is rejected', () async {
    final upstream = await _RawUpstream.start(
      'HTTP/1.1 200 OK\r\nX-Pad: ${'a' * 40000}\r\n\r\n',
    );
    addTearDown(upstream.stop);
    final error = await _expectError(send(upstream));
    expect(error.kind, TolerantHttpFailureKind.protocol);
    expect(error.message, contains('32 KiB'));
  });

  test('more than 128 response headers are rejected', () async {
    final buffer = StringBuffer('HTTP/1.1 200 OK\r\n');
    for (var index = 0; index < 130; index++) {
      buffer.write('X-$index: v\r\n');
    }
    buffer.write('\r\n');
    final upstream = await _RawUpstream.start(buffer.toString());
    addTearDown(upstream.stop);
    final error = await _expectError(send(upstream));
    expect(error.kind, TolerantHttpFailureKind.protocol);
    expect(error.message, contains('128'));
  });

  test('bare LF header lines are rejected', () async {
    final upstream = await _RawUpstream.start(
      'HTTP/1.1 200 OK\nX-A: b\r\nContent-Length: 0\r\n\r\n',
    );
    addTearDown(upstream.stop);
    final error = await _expectError(send(upstream));
    expect(error.kind, TolerantHttpFailureKind.protocol);
    expect(error.message, contains('CRLF'));
  });

  test(
    'list headers are not collapsed: duplicates are dropped entirely',
    () async {
      final upstream = await _RawUpstream.start(
        'HTTP/1.1 200 OK\r\n'
        'Content-Length: 2\r\n'
        'Set-Cookie: a=1\r\n'
        'Set-Cookie: b=2\r\n'
        'Server: one\r\n'
        'Server: two\r\n'
        '\r\n'
        'ok',
      );
      addTearDown(upstream.stop);
      final response = await send(upstream);
      addTearDown(response.close);
      expect(response.headers.containsKey('set-cookie'), isFalse);
      expect(response.headers.containsKey('server'), isFalse);
      expect(utf8.decode(await _read(response.body)), 'ok');
    },
  );

  test('3xx is not followed and fails closed', () async {
    final upstream = await _RawUpstream.start(
      'HTTP/1.1 302 Found\r\n'
      'Location: http://127.0.0.1:1/next\r\n'
      'Location: http://127.0.0.1:1/next\r\n'
      'Content-Length: 0\r\n'
      '\r\n',
    );
    addTearDown(upstream.stop);
    final error = await _expectError(send(upstream));
    expect(error.kind, TolerantHttpFailureKind.redirect);
    expect(error.message, isNot(contains('/next')));
    expect(upstream.connections, 1);
  });

  test('HEAD returns headers only', () async {
    final upstream = await _RawUpstream.start(
      'HTTP/1.1 200 OK\r\nContent-Length: 1024\r\nContent-Type: video/mp4\r\n\r\n',
    );
    addTearDown(upstream.stop);
    final response = await send(upstream, method: 'HEAD');
    addTearDown(response.close);
    expect(response.statusCode, 200);
    expect(response.contentLength, 1024);
    expect(await _read(response.body), isEmpty);
    await _waitFor(() => upstream.requests.isNotEmpty);
    expect(
      upstream.requests.single.split('\r\n').first,
      'HEAD /media.bin HTTP/1.1',
    );
  });

  test('chunked body is decoded without buffering the whole entity', () async {
    final upstream = await _RawUpstream.start(
      'HTTP/1.1 200 OK\r\n'
      'Transfer-Encoding: chunked\r\n'
      'Content-Type: video/mp4\r\n'
      '\r\n'
      '5\r\nhello\r\n'
      '6\r\n world\r\n'
      '0\r\n\r\n',
    );
    addTearDown(upstream.stop);
    final response = await send(upstream);
    addTearDown(response.close);
    expect(response.contentLength, -1);
    expect(utf8.decode(await _read(response.body)), 'hello world');
  });

  test('request line, Range and injected headers are sent verbatim', () async {
    final upstream = await _RawUpstream.start(
      'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok',
    );
    addTearDown(upstream.stop);
    final response = await send(
      upstream,
      path: '/media.bin?sign=a%2Bb',
      headers: const {
        'Range': 'bytes=0-1',
        'Accept-Encoding': 'identity',
        'User-Agent': 'ManagedPlayer/1',
        'Host': 'evil.example',
        'Connection': 'keep-alive',
      },
    );
    addTearDown(response.close);
    await _read(response.body);
    await _waitFor(() => upstream.requests.isNotEmpty);
    final request = upstream.requests.single;
    expect(request.split('\r\n').first, 'GET /media.bin?sign=a%2Bb HTTP/1.1');
    final lower = request.toLowerCase();
    expect('host:'.allMatches(lower).length, 1);
    expect(lower, contains('host: 127.0.0.1:${upstream.port}'));
    expect('connection:'.allMatches(lower).length, 1);
    expect(lower, contains('connection: close'));
    expect(request, contains('Range: bytes=0-1'));
    expect(request, contains('User-Agent: ManagedPlayer/1'));
    expect(request, contains('Accept-Encoding: identity'));
    expect(request, isNot(contains('evil.example')));
    expect(request, isNot(contains('keep-alive')));
  });

  test('only loopback http endpoints and clean headers are accepted', () async {
    for (final url in <String>[
      'http://10.0.0.1:8080/x',
      'https://127.0.0.1:8080/x',
    ]) {
      final error = await _expectError(
        reader().send(
          wireTarget: Uri.parse(url),
          method: 'GET',
          headers: const {},
          timeout: timeout,
        ),
      );
      expect(error.kind, TolerantHttpFailureKind.protocol, reason: url);
    }
    final upstream = await _RawUpstream.start('HTTP/1.1 200 OK\r\n\r\n');
    addTearDown(upstream.stop);
    final error = await _expectError(
      send(upstream, headers: const {'X-Bad': 'a\r\nInjected: 1'}),
    );
    expect(error.kind, TolerantHttpFailureKind.protocol);
    expect(upstream.connections, 0);
  });

  test('truncated fixed-length body fails closed while streaming', () async {
    final upstream = await _RawUpstream.start(
      'HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\n0123',
      closeAfterWrite: true,
    );
    addTearDown(upstream.stop);
    final response = await send(upstream);
    addTearDown(response.close);
    final error = await _expectError(_read(response.body));
    expect(error.kind, TolerantHttpFailureKind.protocol);
  });

  test('differing header whitespace is not byte-identical', () async {
    final upstream = await _RawUpstream.start(
      'HTTP/1.1 200 OK\r\n'
      'Content-Length: 2\r\nContent-Length:  2\r\n\r\nok',
    );
    addTearDown(upstream.stop);
    final error = await _expectError(send(upstream));
    expect(error.kind, TolerantHttpFailureKind.framing);
  });

  test('unsupported transfer coding before chunked is rejected', () async {
    final upstream = await _RawUpstream.start(
      'HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip, chunked\r\n\r\n'
      '2\r\nok\r\n0\r\n\r\n',
    );
    addTearDown(upstream.stop);
    final error = await _expectError(send(upstream));
    expect(error.kind, TolerantHttpFailureKind.protocol);
  });

  test(
    'Content-Length integer overflow is a sanitized framing failure',
    () async {
      final upstream = await _RawUpstream.start(
        'HTTP/1.1 200 OK\r\n'
        'Content-Length: 99999999999999999999999999999999999\r\n\r\n',
      );
      addTearDown(upstream.stop);
      final error = await _expectError(send(upstream));
      expect(error.kind, TolerantHttpFailureKind.framing);
      expect(error.message, isNot(contains('99999')));
    },
  );

  test('reading the whole body closes the socket automatically', () async {
    final upstream = await _RawUpstream.start(
      'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok',
    );
    addTearDown(upstream.stop);
    final response = await send(upstream);
    expect(await _read(response.body), [111, 107]);
    await _waitFor(() => upstream.closed == 1);
  });

  test('HEAD closes the socket even without a body subscription', () async {
    final upstream = await _RawUpstream.start(
      'HTTP/1.1 200 OK\r\nContent-Length: 1024\r\n\r\n',
    );
    addTearDown(upstream.stop);
    final response = await send(upstream, method: 'HEAD');
    expect(response.contentLength, 1024);
    await _waitFor(() => upstream.closed == 1);
  });

  test('head idle timeout is reported without leaking the endpoint', () async {
    final upstream = await _RawUpstream.start('');
    addTearDown(upstream.stop);
    final error = await _expectError(
      const TolerantHttpReader(
        connectTimeout: Duration(milliseconds: 50),
        idleTimeout: Duration(milliseconds: 50),
      ).send(
        wireTarget: Uri.parse(
          'http://127.0.0.1:${upstream.port}/SECRET?token=SECRET',
        ),
        method: 'GET',
        headers: const {},
        timeout: const Duration(seconds: 1),
      ),
    );
    expect(error.kind, TolerantHttpFailureKind.timeout);
    expect(error.message, isNot(contains('SECRET')));
    await _waitFor(() => upstream.closed == 1);
  });
}

Future<void> _waitFor(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) fail('condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Future<List<int>> _read(Stream<List<int>> stream) async {
  final builder = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    builder.add(chunk);
  }
  return builder.takeBytes();
}

Future<TolerantHttpException> _expectError(Future<Object?> future) async {
  try {
    final value = await future;
    if (value is TolerantHttpResponse) await value.close();
    fail('expected TolerantHttpException');
  } on TolerantHttpException catch (error) {
    return error;
  }
}

/// 手写响应字面量的本机原始 socket 服务端。
class _RawUpstream {
  _RawUpstream._(this._port, this._response);

  final int _port;
  final String _response;
  ServerSocket? _server;
  final List<Socket> _accepted = <Socket>[];
  final List<String> requests = <String>[];
  int connections = 0;
  int closed = 0;

  int get port => _port;

  static Future<_RawUpstream> start(
    String response, {
    bool closeAfterWrite = false,
  }) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final upstream = _RawUpstream._(server.port, response).._server = server;
    upstream._listen(closeAfterWrite);
    return upstream;
  }

  void _listen(bool closeAfterWrite) {
    _server!.listen((socket) {
      connections += 1;
      _accepted.add(socket);
      final buffer = <int>[];
      var recorded = false;
      socket.listen(
        (data) {
          if (recorded) return;
          buffer.addAll(data);
          final text = latin1.decode(buffer);
          final end = text.indexOf('\r\n\r\n');
          if (end < 0) return;
          recorded = true;
          requests.add(text.substring(0, end + 4));
        },
        onError: (Object _) {},
        onDone: () {
          closed += 1;
          socket.destroy();
        },
      );
      socket.add(latin1.encode(_response));
      unawaited(
        socket.flush().then((_) {
          if (closeAfterWrite) unawaited(socket.close());
        }),
      );
    });
  }

  Future<void> stop() async {
    for (final socket in _accepted) {
      socket.destroy();
    }
    await _server?.close();
  }
}
