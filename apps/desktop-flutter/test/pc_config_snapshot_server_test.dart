/// 本机快照发布器：真实 HTTP GET/HEAD、精确 token 路径与生命周期。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/pc_config_snapshot_server.dart';

const String token = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const String otherToken = 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';

class HttpResult {
  HttpResult(this.statusCode, this.headers, this.body);

  final int statusCode;
  final Map<String, String> headers;
  final String body;
}

Future<HttpResult> request(Uri uri, {String method = 'GET'}) async {
  final client = HttpClient();
  try {
    final outgoing = await client.openUrl(method, uri);
    final incoming = await outgoing.close();
    final body = await utf8.decoder.bind(incoming).join();
    final headers = <String, String>{};
    incoming.headers.forEach((name, values) {
      headers[name.toLowerCase()] = values.join(',');
    });
    return HttpResult(incoming.statusCode, headers, body);
  } finally {
    client.close(force: true);
  }
}

int startLines(LogService log) => log.entries
    .where((entry) => entry.message.contains('status=started'))
    .length;

void main() {
  late LogService log;
  late PcConfigSnapshotServer server;
  final snapshot = <String, Object?>{
    'name': 'pc-config',
    'sites': [
      {'key': 'a', 'api': 'https://api.example/a'},
    ],
  };

  setUp(() {
    log = LogService();
    server = PcConfigSnapshotServer(log: log);
  });

  tearDown(() async {
    await server.close();
    await log.dispose();
  });

  test('starts on loopback port 0 and exposes a stable token path', () async {
    expect(server.running, isFalse);
    expect(server.port, 0);
    await server.start();
    expect(server.running, isTrue);
    expect(server.port, greaterThan(0));
    final startedPort = server.port;
    await server.start();
    expect(server.port, startedPort);

    final path = server.putSnapshot(token, snapshot);
    expect(path, '/$token.json');
    expect(
      server.deviceUri(token, 19000).toString(),
      'http://127.0.0.1:19000/$token.json',
    );
  });

  test('serves GET and HEAD with exact JSON, no-store and ETag', () async {
    await server.start();
    final path = server.putSnapshot(token, snapshot);
    final uri = Uri.parse('http://127.0.0.1:${server.port}$path');

    final get = await request(uri);
    expect(get.statusCode, 200);
    expect(jsonDecode(get.body), snapshot);
    expect(get.headers['content-type'], contains('application/json'));
    expect(get.headers['cache-control'], 'no-store');
    expect(get.headers['etag'], isNotEmpty);
    expect(get.headers['access-control-allow-origin'], isNull);
    expect(
      get.headers['content-length'],
      utf8.encode(get.body).length.toString(),
    );

    final head = await request(uri, method: 'HEAD');
    expect(head.statusCode, 200);
    expect(head.body, isEmpty);
    expect(head.headers['content-length'], get.headers['content-length']);
    expect(head.headers['etag'], get.headers['etag']);
    expect(head.headers['access-control-allow-origin'], isNull);
  });

  test('returns 404 for unknown, private and non-exact paths', () async {
    await server.start();
    server.putSnapshot(token, snapshot);
    final base = 'http://127.0.0.1:${server.port}';

    for (final path in [
      '/',
      '/config.json',
      '/$otherToken.json',
      '/$token.json?download=1',
      '/static/$token.json',
    ]) {
      final result = await request(Uri.parse(base + path));
      expect(result.statusCode, 404, reason: path);
      expect(result.headers['access-control-allow-origin'], isNull);
    }
  });

  test('allows only GET and HEAD and never emits CORS headers', () async {
    await server.start();
    final path = server.putSnapshot(token, snapshot);
    final uri = Uri.parse('http://127.0.0.1:${server.port}$path');

    for (final method in ['POST', 'PUT', 'DELETE', 'PATCH', 'OPTIONS']) {
      final result = await request(uri, method: method);
      expect(result.statusCode, 405, reason: method);
      expect(result.headers['allow'], 'GET, HEAD');
      expect(result.headers['access-control-allow-origin'], isNull);
      expect(result.headers['access-control-allow-methods'], isNull);
    }
  });

  test('validates token format and payload size before publishing', () async {
    await server.start();
    for (final bad in [
      '',
      'short',
      '../$token',
      '$token.',
      'A' * 21,
      'A' * 20 + '=',
    ]) {
      expect(
        () => server.putSnapshot(bad, snapshot),
        throwsArgumentError,
        reason: bad,
      );
    }
    expect(
      () => server.putSnapshot(token, {'name': 'x' * (2 * 1024 * 1024)}),
      throwsArgumentError,
    );
    expect(() => server.deviceUri(token, 0), throwsArgumentError);
    expect(() => server.deviceUri(token, 70000), throwsArgumentError);
    expect(() => server.deviceUri('short', 19000), throwsArgumentError);
  });

  test('updates one token body in place and ETag follows the body', () async {
    await server.start();
    final path = server.putSnapshot(token, snapshot);
    final uri = Uri.parse('http://127.0.0.1:${server.port}$path');
    final first = await request(uri);

    final updated = <String, Object?>{
      'name': 'pc-config-v2',
      'sites': [
        {'key': 'a', 'api': 'https://api.example/v2'},
      ],
    };
    expect(server.putSnapshot(token, updated), path);
    final second = await request(uri);
    expect(jsonDecode(second.body), updated);
    expect(second.headers['etag'], isNot(first.headers['etag']));
    expect(second.headers['cache-control'], 'no-store');
  });

  test(
    'remove stops serving the exact token and close stops the server',
    () async {
      await server.start();
      final path = server.putSnapshot(token, snapshot);
      server.removeSnapshot(token);
      final uri = Uri.parse('http://127.0.0.1:${server.port}$path');
      expect((await request(uri)).statusCode, 404);

      await server.close();
      expect(server.running, isFalse);
      expect(server.port, 0);
      await server.close();
    },
  );

  test('concurrent start binds one listener and logs one start', () async {
    expect(server.running, isFalse);
    expect(startLines(log), 0);

    final first = server.start();
    final second = server.start();
    await Future.wait([first, second]);

    expect(server.running, isTrue);
    final boundPort = server.port;
    expect(boundPort, greaterThan(0));
    expect(startLines(log), 1);

    final path = server.putSnapshot(token, snapshot);
    final uri = Uri.parse('http://127.0.0.1:$boundPort$path');
    expect((await request(uri)).statusCode, 200);

    await server.close();
    expect(server.running, isFalse);
    expect(server.port, 0);
    await Future.wait([first, second]);
    expect(server.running, isFalse);

    // The one port that was ever bound is really released.
    final rebind = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      boundPort,
    );
    await rebind.close();

    // close() clears the memoized start, so a later start binds again.
    await server.start();
    expect(server.running, isTrue);
    expect(server.port, greaterThan(0));
    expect(startLines(log), 2);
  });

  test('close during a pending start leaves no active listener', () async {
    final pending = server.start();
    // close 不等待在途 bind：作废它，落地后由 start 自己关掉监听。
    await server.close();
    await pending;

    expect(server.running, isFalse);
    expect(server.port, 0);
    expect(startLines(log), 0);

    await server.start();
    expect(server.running, isTrue);
    expect(startLines(log), 1);
  });
}
