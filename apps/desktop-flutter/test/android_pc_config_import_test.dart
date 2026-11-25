import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/services/lan_http_client.dart';
import 'package:webhtv_pc/services/android_bridge_service.dart';
import 'package:webhtv_pc/services/log_service.dart';

void main() {
  test(
    'POSTs marked encoded form and preserves reused import receipt',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final log = LogService();
      final service = AndroidBridgeService(log: log);
      addTearDown(() async {
        service.close();
        log.dispose();
        await server.close(force: true);
      });
      final port = server.port;
      const token = 'private-snapshot-token';
      final snapshotUrl = Uri.parse(
        'http://127.0.0.1:41234/$token.json?x=a&b=2',
      );
      final received = server.first.then((request) async {
        expect(request.method, 'POST');
        expect(request.uri.path, '/manage/config/import');
        expect(request.uri.hasQuery, isFalse);
        expect(request.headers.value('X-WebHTV-PC-Import'), '1');
        expect(
          request.headers.contentType?.mimeType,
          'application/x-www-form-urlencoded',
        );
        expect(request.headers.value('Host'), '127.0.0.1:$port');
        expect(request.headers.value('Origin'), isNull);
        final body = await utf8.decoder.bind(request).join();
        expect(
          body,
          contains('url=${Uri.encodeQueryComponent(snapshotUrl.toString())}'),
        );
        expect(Uri.splitQueryString(body), {
          'url': snapshotUrl.toString(),
          'name': '合成 & copy',
          'type': '0',
        });
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'code': 0,
            'data': {
              'id': 42,
              'interfaceKey': 'real-interface-key',
              'url': snapshotUrl.toString(),
              'name': 'Original name',
              'created': false,
              'active': false,
            },
          }),
        );
        await request.response.close();
      });
      final result = await service.importPcConfig(
        '127.0.0.1:${server.port}/',
        snapshotUrl: snapshotUrl,
        name: '合成 & copy',
      );
      await received;
      expect(result.id, 42);
      expect(result.interfaceKey, 'real-interface-key');
      expect(result.url, snapshotUrl.toString());
      expect(result.name, 'Original name');
      expect(result.created, isFalse);
      expect(result.active, isFalse);
      final lines = log.entries.map((entry) => entry.line).join('\n');
      expect(lines, isNotEmpty);
      expect(lines, isNot(contains(token)));
      expect(lines, isNot(contains(snapshotUrl.toString())));
    },
  );

  test('omits empty name and sends selected type', () async {
    final fixture = await _fixture(_receipt());
    await fixture.service.importPcConfig(
      fixture.base,
      snapshotUrl: _snapshot,
      type: 2,
    );
    expect(await fixture.fields, {'url': _snapshot.toString(), 'type': '2'});
  });

  for (final (status, message) in [
    (405, 'Use POST'),
    (403, 'Loopback only'),
    (415, 'Use application/x-www-form-urlencoded'),
    (413, 'Body too large'),
    (500, 'Device database unavailable'),
  ]) {
    test('HTTP $status preserves device message and status', () async {
      final fixture = await _fixture({
        'code': status,
        'msg': message,
      }, status: status);
      await expectLater(
        fixture.service.importPcConfig(fixture.base, snapshotUrl: _snapshot),
        throwsA(
          isA<AppError>()
              .having((e) => e.kind, 'kind', AppErrorKind.bridgeUnreachable)
              .having((e) => e.statusCode, 'status', status)
              .having((e) => e.message, 'device message', contains(message))
              .having((e) => e.retryable, 'retryable', status >= 500),
        ),
      );
      expect(await fixture.fields, {'url': _snapshot.toString(), 'type': '0'});
    });
  }

  test('404 identifies missing import gateway', () async {
    final fixture = await _fixture('Not found', status: 404);
    await expectLater(
      fixture.service.importPcConfig(fixture.base, snapshotUrl: _snapshot),
      throwsA(
        isA<AppError>().having(
          (e) => e.kind,
          'kind',
          AppErrorKind.bridgeNoGateway,
        ),
      ),
    );
  });

  test('plain text HTTP device message is preserved', () async {
    final fixture = await _fixture('Use POST', status: 405);
    await expectLater(
      fixture.service.importPcConfig(fixture.base, snapshotUrl: _snapshot),
      throwsA(
        isA<AppError>().having(
          (e) => e.message,
          'message',
          contains('Use POST'),
        ),
      ),
    );
  });

  for (final (label, body) in <(String, Object)>[
    ('malformed JSON', '{"bad":'),
    ('non-object JSON', []),
    ('nonzero code', {'code': 1, 'msg': 'Import refused'}),
    ('missing code', {'data': _receipt()['data']}),
    ('empty interfaceKey', _receipt(interfaceKey: '')),
    ('whitespace interfaceKey', _receipt(interfaceKey: '  ')),
    ('zero id', _receipt(id: 0)),
    ('negative id', _receipt(id: -1)),
    ('missing data', {'code': 0}),
    (
      'missing created flag',
      {
        'code': 0,
        'data': {..._data(), 'created': null},
      },
    ),
    (
      'nonboolean active flag',
      {
        'code': 0,
        'data': {..._data(), 'active': 'false'},
      },
    ),
  ]) {
    test('rejects $label without inventing success', () async {
      final fixture = await _fixture(body);
      await expectLater(
        fixture.service.importPcConfig(fixture.base, snapshotUrl: _snapshot),
        throwsA(
          isA<AppError>().having(
            (e) => e.kind,
            'kind',
            AppErrorKind.bridgeNotAndroid,
          ),
        ),
      );
    });
  }

  test('successful created and active flags are returned honestly', () async {
    final fixture = await _fixture({
      'code': 0,
      'data': {..._data(), 'created': true, 'active': true},
    });
    final AndroidPcConfigImportResult result = await fixture.service
        .importPcConfig(fixture.base, snapshotUrl: _snapshot);
    expect(result.created, isTrue);
    expect(result.active, isTrue);
  });

  test('device echoed snapshot secrets are sanitized before caller logging', () async {
    final fixture = await _fixture({
      'code': 403,
      'message':
          'Refused $_snapshot raw=$_token encoded=${Uri.encodeComponent(_token)}',
    }, status: 403);
    try {
      await fixture.service.importPcConfig(
        fixture.base,
        snapshotUrl: _snapshot,
      );
      fail('Must reject');
    } on AppError catch (error) {
      fixture.log.warning(error.logLine);
      expect(error.message, contains('Refused'));
      expect(error.logLine, isNot(contains(_token)));
    }
    final lines = fixture.log.entries.map((entry) => entry.line).join('\n');
    expect(lines, isNotEmpty);
    expect(lines, isNot(contains(_token)));
    expect(lines, isNot(contains(_snapshot.toString())));
  });

  test('timeout override maps to retryable transport error', () async {
    final fixture = await _fixture(
      _receipt(),
      delay: const Duration(milliseconds: 100),
    );
    await expectLater(
      fixture.service.importPcConfig(
        fixture.base,
        snapshotUrl: _snapshot,
        timeout: const Duration(milliseconds: 10),
      ),
      throwsA(
        isA<AppError>()
            .having((e) => e.kind, 'kind', AppErrorKind.bridgeUnreachable)
            .having((e) => e.retryable, 'retryable', isTrue)
            .having((e) => e.message, 'message', contains('10ms')),
      ),
    );
  });

  test('connection refusal maps to retryable transport error', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;
    await server.close(force: true);
    final log = LogService();
    final service = AndroidBridgeService(log: log);
    addTearDown(() {
      service.close();
      log.dispose();
    });
    await expectLater(
      service.importPcConfig('http://127.0.0.1:$port', snapshotUrl: _snapshot),
      throwsA(
        isA<AppError>()
            .having((e) => e.kind, 'kind', AppErrorKind.bridgeUnreachable)
            .having((e) => e.retryable, 'retryable', isTrue),
      ),
    );
  });

  for (final invalidType in [-1, 3]) {
    test('rejects invalid type $invalidType before network', () async {
      final fixture = await _socketFixture((request) async {
        request.response.write(jsonEncode(_receipt()));
        await request.response.close();
      });
      await expectLater(
        fixture.service.importPcConfig(
          fixture.base,
          snapshotUrl: _snapshot,
          type: invalidType,
        ),
        throwsA(
          isA<AppError>().having(
            (e) => e.kind,
            'kind',
            AppErrorKind.bridgeNotAndroid,
          ),
        ),
      );
      expect(fixture.hits(), 0);
    });
  }

  for (final (label, url) in [
    ('relative', Uri.parse('/$_token.json')),
    ('scheme', Uri.parse('file:///$_token.json')),
    ('host', Uri.parse('http:/$_token.json')),
    ('credentials', Uri.parse('http://user:secret@127.0.0.1/$_token.json')),
    ('fragment', Uri.parse('http://127.0.0.1/$_token.json#private')),
  ]) {
    test('rejects invalid snapshot $label without sending secrets', () async {
      final fixture = await _socketFixture((request) async {
        request.response.write(jsonEncode(_receipt()));
        await request.response.close();
      });
      await expectLater(
        fixture.service.importPcConfig(fixture.base, snapshotUrl: url),
        throwsA(
          isA<AppError>().having(
            (e) => e.kind,
            'kind',
            AppErrorKind.bridgeNotAndroid,
          ),
        ),
      );
      expect(fixture.hits(), 0);
      expect(
        fixture.log.entries.map((e) => e.line).join(),
        isNot(contains(_token)),
      );
    });
  }

  test('rejects nonloopback control base before sending', () async {
    final log = LogService();
    final service = AndroidBridgeService(log: log);
    addTearDown(() {
      service.close();
      log.dispose();
    });
    await expectLater(
      service.importPcConfig(
        'http://192.0.2.1:9978',
        snapshotUrl: _snapshot,
        timeout: const Duration(milliseconds: 10),
      ),
      throwsA(
        isA<AppError>()
            .having((e) => e.kind, 'kind', AppErrorKind.bridgeUnreachable)
            .having((e) => e.retryable, 'local rejection', isFalse),
      ),
    );
  });

  test('rejects oversized encoded form before network', () async {
    final fixture = await _socketFixture((request) async {
      request.response.write(jsonEncode(_receipt()));
      await request.response.close();
    });
    await expectLater(
      fixture.service.importPcConfig(
        fixture.base,
        snapshotUrl: _snapshot,
        name: '界' * 2000,
      ),
      throwsA(
        isA<AppError>().having(
          (e) => e.kind,
          'kind',
          AppErrorKind.bridgeNotAndroid,
        ),
      ),
    );
    expect(fixture.hits(), 0);
  });

  test('rejects unmatched receipt URL with sanitized identity error', () async {
    final fixture = await _fixture({
      'code': 0,
      'data': {
        ..._data(),
        'url': 'http://127.0.0.1:41234/other-private-token.json',
      },
    });
    await expectLater(
      fixture.service.importPcConfig(fixture.base, snapshotUrl: _snapshot),
      throwsA(
        isA<AppError>()
            .having((e) => e.kind, 'kind', AppErrorKind.bridgeNotAndroid)
            .having((e) => e.message, 'identity mismatch', contains('URL'))
            .having(
              (e) => e.logLine,
              'sanitized',
              isNot(contains('other-private-token')),
            ),
      ),
    );
  });

  for (final fixedLength in [true, false]) {
    test(
      'rejects ${fixedLength ? 'fixed' : 'chunked'} response above 16KiB',
      () async {
        final body = utf8.encode(jsonEncode(_receipt()) + ' ' * 16384);
        final fixture = await _socketFixture((request) async {
          if (fixedLength) request.response.contentLength = body.length;
          request.response.add(body);
          await request.response.close();
        });
        await expectLater(
          fixture.service.importPcConfig(fixture.base, snapshotUrl: _snapshot),
          throwsA(
            isA<AppError>().having(
              (e) => e.kind,
              'kind',
              AppErrorKind.bridgeNotAndroid,
            ),
          ),
        );
      },
    );
  }

  test('oversized HTTP error keeps its status and retryability', () async {
    final body = utf8.encode('x' * 20000);
    final fixture = await _socketFixture((request) async {
      request.response.statusCode = 500;
      request.response.contentLength = body.length;
      request.response.add(body);
      await request.response.close();
    });
    await expectLater(
      fixture.service.importPcConfig(fixture.base, snapshotUrl: _snapshot),
      throwsA(
        isA<AppError>()
            .having((e) => e.kind, 'kind', AppErrorKind.bridgeUnreachable)
            .having((e) => e.statusCode, 'status', 500)
            .having((e) => e.retryable, 'retryable', isTrue)
            .having((e) => e.message, 'message', contains('HTTP 500')),
      ),
    );
  });

  test('accepts exactly 16KiB response', () async {
    final receipt = jsonEncode(_receipt());
    final fixture = await _socketFixture((request) async {
      request.response.write(
        receipt + ' ' * (16384 - utf8.encode(receipt).length),
      );
      await request.response.close();
    });
    expect(
      (await fixture.service.importPcConfig(
        fixture.base,
        snapshotUrl: _snapshot,
      )).id,
      42,
    );
  });

  for (final status in [303, 307, 308]) {
    test(
      'rejects $status redirect without second request or URL leakage',
      () async {
        final target = await _socketFixture((request) async {
          request.response.write(jsonEncode(_receipt()));
          await request.response.close();
        });
        final fixture = await _socketFixture((request) async {
          request.response.statusCode = status;
          request.response.headers.set(
            'Location',
            '${target.base}/$_token.json',
          );
          request.response.write('Redirect refused');
          await request.response.close();
        });
        await expectLater(
          fixture.service.importPcConfig(fixture.base, snapshotUrl: _snapshot),
          throwsA(
            isA<AppError>()
                .having((e) => e.kind, 'kind', AppErrorKind.bridgeUnreachable)
                .having((e) => e.statusCode, 'status', status),
          ),
        );
        expect(target.hits(), 0);
        final lines = fixture.log.entries.map((e) => e.line).join();
        expect(lines, isNot(contains(_token)));
        expect(lines, isNot(contains(_snapshot.toString())));
      },
    );
  }

  test('whole deadline aborts slow streamed body and closes socket', () async {
    final disconnected = Completer<void>();
    final fixture = await _socketFixture((request) async {
      final socket = await request.response.detachSocket(writeHeaders: false);
      socket.listen(
        (_) {},
        onDone: () {
          if (!disconnected.isCompleted) disconnected.complete();
        },
        onError: (Object _) {
          if (!disconnected.isCompleted) disconnected.complete();
        },
      );
      await Future<void>.delayed(const Duration(milliseconds: 60));
      socket.write(
        'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n',
      );
      final timer = Timer.periodic(const Duration(milliseconds: 20), (_) {
        socket.write('1\r\n \r\n');
      });
      addTearDown(() {
        timer.cancel();
        socket.destroy();
      });
    });
    final watch = Stopwatch()..start();
    await expectLater(
      fixture.service.importPcConfig(
        fixture.base,
        snapshotUrl: _snapshot,
        timeout: const Duration(milliseconds: 110),
      ),
      throwsA(
        isA<AppError>()
            .having((e) => e.kind, 'kind', AppErrorKind.bridgeUnreachable)
            .having((e) => e.retryable, 'retryable', isTrue),
      ),
    );
    expect(watch.elapsedMilliseconds, lessThan(250));
    await disconnected.future.timeout(
      const Duration(milliseconds: 300),
      onTimeout: () {
        throw StateError('request socket was not aborted');
      },
    );
  });

  test(
    'real device imports synthetic snapshot without active switch',
    _deviceSmoke,
    skip: !const bool.fromEnvironment('PC_IMPORT_DEVICE_SMOKE'),
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

const _token = 'private-snapshot-token';
final _snapshot = Uri.parse('http://127.0.0.1:41234/$_token.json');
Map<String, Object> _data({
  int id = 42,
  String interfaceKey = 'real-interface-key',
}) => {
  'id': id,
  'interfaceKey': interfaceKey,
  'url': _snapshot.toString(),
  'name': 'Synthetic import',
  'created': false,
  'active': false,
};
Map<String, Object> _receipt({
  int id = 42,
  String interfaceKey = 'real-interface-key',
}) => {'code': 0, 'data': _data(id: id, interfaceKey: interfaceKey)};

Future<
  ({
    AndroidBridgeService service,
    LogService log,
    String base,
    Future<Map<String, String>> fields,
  })
>
_fixture(
  Object body, {
  int status = 200,
  Duration delay = Duration.zero,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final log = LogService();
  final service = AndroidBridgeService(log: log);
  final fields = Completer<Map<String, String>>();
  final subscription = server.listen((request) async {
    expect(request.method, 'POST');
    expect(request.uri.path, '/manage/config/import');
    expect(request.headers.value('X-WebHTV-PC-Import'), '1');
    expect(request.headers.value('Host'), '127.0.0.1:${server.port}');
    expect(
      request.headers.contentType?.mimeType,
      'application/x-www-form-urlencoded',
    );
    fields.complete(
      Uri.splitQueryString(await utf8.decoder.bind(request).join()),
    );
    if (delay != Duration.zero) await Future<void>.delayed(delay);
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    request.response.write(body is String ? body : jsonEncode(body));
    await request.response.close();
  });
  addTearDown(() async {
    service.close();
    log.dispose();
    await subscription.cancel();
    await server.close(force: true);
  });
  return (
    service: service,
    log: log,
    base: 'http://127.0.0.1:${server.port}',
    fields: fields.future,
  );
}

Future<
  ({
    AndroidBridgeService service,
    LogService log,
    String base,
    int Function() hits,
  })
>
_socketFixture(Future<void> Function(HttpRequest) respond) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final port = server.port;
  final log = LogService();
  final service = AndroidBridgeService(log: log);
  var hits = 0;
  final subscription = server.listen((request) async {
    hits++;
    await request.drain<void>();
    await respond(request);
  });
  addTearDown(() async {
    service.close();
    log.dispose();
    await subscription.cancel();
    await server.close(force: true);
  });
  return (
    service: service,
    log: log,
    base: 'http://127.0.0.1:$port',
    hits: () => hits,
  );
}

Future<void> _deviceSmoke() async {
  const serial = '192.168.50.3:5555';
  Future<ProcessResult> rawAdb(List<String> args) =>
      Process.run('adb', ['-P', '5037', '-s', serial, ...args]);
  Future<String?> adbQuiet(List<String> args) async {
    try {
      final result = await rawAdb(args);
      return result.exitCode == 0 ? (result.stdout as String).trim() : null;
    } catch (_) {
      return null;
    }
  }

  Future<String> adb(List<String> args) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      final result = await rawAdb(args);
      if (result.exitCode == 0) return (result.stdout as String).trim();
      await Process.run('adb', ['-P', '5037', 'connect', serial]);
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    final result = await rawAdb(args);
    expect(
      result.exitCode,
      0,
      reason: 'adb ${args.first} failed: ${result.stderr}',
    );
    return (result.stdout as String).trim();
  }

  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final random = Random.secure();
  final token = List.generate(
    24,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  var snapshotReads = 0;
  final subscription = server.listen((request) async {
    if (request.method == 'GET' &&
        request.uri.path == '/$token.json' &&
        !request.uri.hasQuery) {
      snapshotReads++;
      request.response.headers.contentType = ContentType.json;
      request.response.headers.set('Cache-Control', 'no-store');
      request.response.write('{"sites":[]}');
    } else {
      request.response.statusCode = 404;
    }
    await request.response.close();
  });
  final log = LogService();
  final service = AndroidBridgeService(
    log: log,
    timeout: const Duration(seconds: 20),
  );
  final client = createLanHttpClient();
  int? forwardPort;
  int? reversePort;
  try {
    expect(await adb(['get-state']), 'device');
    forwardPort = int.parse(
      await adb(['forward', '--no-rebind', 'tcp:0', 'tcp:9978']),
    );
    reversePort = int.parse(
      await adb(['reverse', '--no-rebind', 'tcp:0', 'tcp:${server.port}']),
    );
    final base = 'http://127.0.0.1:$forwardPort';
    Future<http.Response> getWithRetry(
      Uri uri, {
      Map<String, String>? headers,
    }) async {
      Object? last;
      for (var attempt = 0; attempt < 3; attempt++) {
        try {
          return await client
              .get(uri, headers: headers)
              .timeout(const Duration(seconds: 20));
        } catch (error) {
          last = error;
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }
      }
      throw last!;
    }

    Future<int> activeCount() async {
      final response = await getWithRetry(
        Uri.parse('$base/vod/api?ac=config'),
        headers: {'Host': '127.0.0.1:$forwardPort'},
      );
      expect(response.statusCode, 200);
      final config =
          jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      final sites = config['sites'] as List<dynamic>;
      return sites
          .whereType<Map>()
          .map((site) => site['key'])
          .whereType<String>()
          .toSet()
          .length;
    }

    final before = await activeCount();
    expect(before, greaterThan(0));
    final snapshotUrl = Uri.parse('http://127.0.0.1:$reversePort/$token.json');
    final result = await service.importPcConfig(
      base,
      snapshotUrl: snapshotUrl,
      name: 'PC synthetic import smoke',
    );
    expect(result.id, greaterThan(0));
    expect(result.interfaceKey.trim(), isNotEmpty);
    expect(result.created, isTrue);
    expect(result.active, isFalse);
    final reused = await service.importPcConfig(
      base,
      snapshotUrl: snapshotUrl,
      name: 'Not a rename',
    );
    expect(reused.id, result.id);
    expect(reused.interfaceKey, result.interfaceKey);
    expect(reused.created, isFalse);
    expect(reused.active, isFalse);
    expect(reused.name, result.name);
    final catalog = await getWithRetry(
      Uri.parse('$base/vod/api').replace(
        queryParameters: {'ac': 'config', 'configKey': result.interfaceKey},
      ),
      headers: {'Host': '127.0.0.1:$forwardPort'},
    );
    expect(catalog.statusCode, 200);
    final catalogJson =
        jsonDecode(utf8.decode(catalog.bodyBytes)) as Map<String, dynamic>;
    List<Object?>? findSites(Object? value) {
      if (value is Map) {
        final sites = value['sites'];
        if (sites is List) return sites;
        for (final child in value.values) {
          final found = findSites(child);
          if (found != null) return found;
        }
      } else if (value is List) {
        for (final child in value) {
          final found = findSites(child);
          if (found != null) return found;
        }
      }
      return null;
    }

    final catalogSites = findSites(catalogJson);
    expect(
      catalogSites,
      isNotNull,
      reason: 'Catalog response keys: ${catalogJson.keys.toList()}',
    );
    // Android may auto-inject extra decoys; assert count only and never dump keys.
    final catalogSiteCount = catalogSites!
        .whereType<Map>()
        .map((site) => site['key'])
        .whereType<String>()
        .toSet()
        .length;
    expect(
      jsonEncode(catalogJson).contains(result.interfaceKey),
      isTrue,
      reason: 'Catalog must be rendered from the imported interface key',
    );
    expect(
      snapshotReads,
      greaterThan(0),
      reason: 'Device must read the synthetic snapshot through reverse',
    );
    final after = await activeCount();
    expect(
      after,
      before,
      reason: 'Import must not switch Android active config',
    );
    final lines = log.entries.map((entry) => entry.line).join('\n');
    expect(lines, isNot(contains(token)));
    expect(lines, isNot(contains(snapshotUrl.toString())));
    final fingerprint = sha256
        .convert(utf8.encode(result.interfaceKey))
        .toString()
        .substring(0, 12);
    // Receipt contains counts and fingerprints only, never source URLs or site keys.
    stderr.writeln(
      'DEVICE_RECEIPT interfaceKey_sha256_12=$fingerprint created=${result.created} reused_created=${reused.created} active=${result.active} active_site_key_count_before=$before after=$after snapshot_reads=$snapshotReads catalog_site_entries=$catalogSiteCount',
    );
  } finally {
    service.close();
    client.close();
    log.dispose();
    var reverseClean = true;
    var forwardClean = true;
    if (reversePort != null) {
      await adbQuiet(['reverse', '--remove', 'tcp:$reversePort']);
      final remaining = await adbQuiet(['reverse', '--list']);
      reverseClean =
          remaining == null || !remaining.contains('tcp:$reversePort');
    }
    if (forwardPort != null) {
      await adbQuiet(['forward', '--remove', 'tcp:$forwardPort']);
      final remaining = await adbQuiet(['forward', '--list']);
      forwardClean =
          remaining == null || !remaining.contains('tcp:$forwardPort');
    }
    await subscription.cancel();
    await server.close(force: true);
    stderr.writeln(
      'DEVICE_CLEANUP reverse_removed=$reverseClean forward_removed=$forwardClean server_closed=true no_temp_files=true',
    );
    expect(
      reverseClean && forwardClean,
      isTrue,
      reason: 'owned adb routes remain',
    );
  }
}
