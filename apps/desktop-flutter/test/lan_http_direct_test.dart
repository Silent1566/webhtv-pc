/// Real loopback requests verify LAN DIRECT, outbound routing, TLS and timeouts.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/services/android_bridge_service.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/sync_client.dart';

class _ProxyRecordingOverrides extends HttpOverrides {
  _ProxyRecordingOverrides({
    this.proxy = 'PROXY 127.0.0.1:9',
    this.configureClientProxy = false,
  });

  final String proxy;
  final bool configureClientProxy;
  final List<Uri> proxyQueries = [];
  final List<HttpClient> clients = [];

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    // Bypass flutter_test's HTTP mock, but keep the real SDK client.
    final client = super.createHttpClient(context);
    clients.add(client);
    if (configureClientProxy) client.findProxy = _findProxy;
    return client;
  }

  String _findProxy(Uri url) {
    proxyQueries.add(url);
    return proxy;
  }

  @override
  String findProxyFromEnvironment(Uri url, Map<String, String>? environment) =>
      _findProxy(url);
}

class _FixedClient extends http.BaseClient {
  _FixedClient(this.body, {this.routes = const {}});

  final String body;
  final Map<String, String> routes;
  final List<Uri> requests = [];
  int closeCalls = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request.url);
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(routes[request.url.path] ?? body)),
      200,
    );
  }

  @override
  void close() => closeCalls++;
}

const _deviceJson = '{"uuid":"fixture-device","name":"LAN fixture","type":1}';
const _syncBody = 'OK applied=0 skipped=0 failed=0 total=0';
const _liveJson =
    '{"lives":[{"name":"Via proxy","url":"http://127.0.0.1/live.m3u"}]}';

Future<HttpServer> _startFixture(List<String> hits) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    hits.add(request.uri.toString());
    await request.drain<void>();
    request.response.write(
      request.uri.path == '/device' ? _deviceJson : _syncBody,
    );
    await request.response.close();
  });
  return server;
}

void _expectClientsClosed(_ProxyRecordingOverrides overrides, String base) {
  expect(overrides.clients, isNotEmpty);
  for (final client in overrides.clients) {
    expect(() => client.getUrl(Uri.parse(base)), throwsStateError);
  }
}

const String _tlsKey = '''
-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgY+sZJUsctz4E5aRM
4PgFozcnqh95TzYs/w5r7dFoxjGhRANCAARlj2WVmWYqrTQ5LxYTH7J+N0weXnaU
PoP2VwvwYaFjTbQcMHsmqPMeaFV3p3Miw3ggzcblR+u07ectRWPDuZYI
-----END PRIVATE KEY-----
''';

const String _tlsCertificate = '''
-----BEGIN CERTIFICATE-----
MIIBfDCCASOgAwIBAgIUBe7ttleZzRI1qCNtBtffwqk8MvIwCgYIKoZIzj0EAwIw
FDESMBAGA1UEAwwJbG9jYWxob3N0MB4XDTI2MTExNjA3MTUzNloXDTM2MTExMzA3
MTUzNlowFDESMBAGA1UEAwwJbG9jYWxob3N0MFkwEwYHKoZIzj0CAQYIKoZIzj0D
AQcDQgAEZY9llZlmKq00OS8WEx+yfjdMHl52lD6D9lcL8GGhY020HDB7JqjzHmhV
d6dzIsN4IM3G5UfrtO3nLUVjw7mWCKNTMFEwHQYDVR0OBBYEFEGNam+NG4Z6A6KT
n69uM9WZ+aVjMB8GA1UdIwQYMBaAFEGNam+NG4Z6A6KTn69uM9WZ+aVjMA8GA1Ud
EwEB/wQFMAMBAf8wCgYIKoZIzj0EAwIDRwAwRAIgP4khm9BOauLu8cQPbED6wb4g
CBDgcFqSRRYckeesjzQCIBmPUDWUU3gSiE9sHCfdj7RW7mP6MGjtaJwElEYKcn4u
-----END CERTIFICATE-----
''';

void main() {
  test('bridge subscription document retains outbound proxy routing', () async {
    final directHits = <String>[];
    final proxyHits = <String>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => proxy.close(force: true));
    final base = 'http://127.0.0.1:${server.port}';
    final subscription = '$base/lives.json';
    server.listen((request) async {
      directHits.add(request.uri.path);
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        request.uri.path == '/manage/configs'
            ? jsonEncode({
                'items': [
                  {'type': 1, 'active': true, 'url': subscription},
                ],
              })
            : '{"lives":[]}',
      );
      await request.response.close();
    });
    proxy.listen((request) async {
      proxyHits.add(request.uri.toString());
      request.response.headers.contentType = ContentType.json;
      request.response.write(_liveJson);
      await request.response.close();
    });

    final overrides = _ProxyRecordingOverrides(
      proxy: 'PROXY 127.0.0.1:${proxy.port}',
    );
    final sources = await HttpOverrides.runWithHttpOverrides(() async {
      final service = AndroidBridgeService(log: LogService());
      try {
        return await service.fetchLiveSources(base);
      } finally {
        service.close();
      }
    }, overrides);

    expect(sources.map((source) => source.name), ['Via proxy']);
    expect(directHits, ['/manage/configs']);
    expect(proxyHits, [subscription]);
    expect(overrides.proxyQueries, [Uri.parse(subscription)]);
    _expectClientsClosed(overrides, base);
  });

  for (final configured in [false, true]) {
    final proxyMode = configured
        ? 'preconfigured findProxy'
        : 'environment callback';

    test('default bridge is DIRECT despite $proxyMode', () async {
      final hits = <String>[];
      final server = await _startFixture(hits);
      addTearDown(() => server.close(force: true));
      final base = 'http://127.0.0.1:${server.port}';
      final overrides = _ProxyRecordingOverrides(
        configureClientProxy: configured,
      );
      final device = await HttpOverrides.runWithHttpOverrides(() async {
        final service = AndroidBridgeService(log: LogService());
        try {
          return await service.probeDevice(base);
        } finally {
          service.close();
        }
      }, overrides);

      expect(overrides.proxyQueries, isEmpty);
      expect(hits, ['/device']);
      expect(device.name, 'LAN fixture');
      expect(device.reachableBase, base);
      _expectClientsClosed(overrides, base);
    });

    test('default sync is DIRECT despite $proxyMode', () async {
      final hits = <String>[];
      final server = await _startFixture(hits);
      addTearDown(() => server.close(force: true));
      final base = 'http://127.0.0.1:${server.port}';
      final overrides = _ProxyRecordingOverrides(
        configureClientProxy: configured,
      );
      final result = await HttpOverrides.runWithHttpOverrides(() async {
        final sync = SyncClient(log: LogService());
        try {
          return await sync.pushKeep(deviceBase: base, items: const []);
        } finally {
          sync.close();
        }
      }, overrides);

      expect(overrides.proxyQueries, isEmpty);
      expect(hits, ['/action?do=sync&mode=1&type=keep']);
      expect(result.statusCode, 200);
      expect(result.body, _syncBody);
      _expectClientsClosed(overrides, base);
    });
  }

  test(
    'injected bridge client serves device and source paths and closes once',
    () async {
      const subscription = 'https://subscription.invalid/lives.json';
      final injected = _FixedClient(
        _deviceJson,
        routes: {
          '/manage/configs': jsonEncode({
            'items': [
              {'type': 1, 'active': true, 'url': subscription},
            ],
          }),
          '/lives.json': _liveJson,
        },
      );
      final overrides = _ProxyRecordingOverrides();
      await HttpOverrides.runWithHttpOverrides(() async {
        final service = AndroidBridgeService(
          log: LogService(),
          client: injected,
        );
        try {
          final device = await service.probeDevice('127.0.0.1:9978');
          final sources = await service.fetchLiveSources('127.0.0.1:9978');
          expect(device.name, 'LAN fixture');
          expect(sources.map((source) => source.name), ['Via proxy']);
        } finally {
          service.close();
        }
      }, overrides);

      expect(injected.requests.map((uri) => uri.path), [
        '/device',
        '/manage/configs',
        '/lives.json',
      ]);
      expect(injected.requests.last, Uri.parse(subscription));
      expect(overrides.clients, isEmpty);
      expect(injected.closeCalls, 1);
    },
  );

  test('injected sync client is retained and closes once', () async {
    final injected = _FixedClient(_syncBody);
    final overrides = _ProxyRecordingOverrides();
    final result = await HttpOverrides.runWithHttpOverrides(() async {
      final sync = SyncClient(log: LogService(), client: injected);
      try {
        return await sync.pushKeep(
          deviceBase: 'http://192.168.50.9:9978',
          items: const [],
        );
      } finally {
        sync.close();
      }
    }, overrides);

    expect(injected.requests.single.path, '/action');
    expect(result.statusCode, 200);
    expect(overrides.clients, isEmpty);
    expect(injected.closeCalls, 1);
  });

  for (final bridge in [true, false]) {
    final name = bridge ? 'bridge' : 'sync';
    test('default $name rejects an untrusted TLS certificate', () async {
      final context = SecurityContext()
        ..useCertificateChainBytes(utf8.encode(_tlsCertificate))
        ..usePrivateKeyBytes(utf8.encode(_tlsKey));
      final server = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        context,
      );
      addTearDown(() => server.close(force: true));
      final hits = <String>[];
      server.listen(
        (request) async {
          hits.add(request.uri.path);
          request.response.write(bridge ? _deviceJson : _syncBody);
          await request.response.close();
        },
        onError: (Object error) {
          expect(error, isA<HandshakeException>());
        },
      );
      final base = 'https://localhost:${server.port}';
      final overrides = _ProxyRecordingOverrides();
      await HttpOverrides.runWithHttpOverrides(() async {
        final service = bridge ? AndroidBridgeService(log: LogService()) : null;
        final sync = bridge ? null : SyncClient(log: LogService());
        try {
          await expectLater(
            bridge
                ? service!.probeDevice(base)
                : sync!.pushKeep(deviceBase: base, items: const []),
            throwsA(
              isA<AppError>().having(
                (error) => error.cause,
                'TLS cause',
                isA<HandshakeException>(),
              ),
            ),
          );
        } finally {
          service?.close();
          sync?.close();
        }
      }, overrides);
      expect(hits, isEmpty);
      _expectClientsClosed(overrides, base);
      await HttpOverrides.runWithHttpOverrides(() async {
        final trusted = SecurityContext()
          ..setTrustedCertificatesBytes(utf8.encode(_tlsCertificate));
        final injected = IOClient(
          HttpClient(context: trusted)..findProxy = (_) => 'DIRECT',
        );
        final service = bridge
            ? AndroidBridgeService(log: LogService(), client: injected)
            : null;
        final sync = bridge
            ? null
            : SyncClient(log: LogService(), client: injected);
        try {
          if (bridge) {
            expect((await service!.probeDevice(base)).name, 'LAN fixture');
          } else {
            expect(
              (await sync!.pushKeep(
                deviceBase: base,
                items: const [],
              )).statusCode,
              200,
            );
          }
        } finally {
          service?.close();
          sync?.close();
        }
      }, overrides);
      expect(hits, [bridge ? '/device' : '/action']);
      expect(overrides.proxyQueries, isEmpty);
      _expectClientsClosed(overrides, base);
    });

    test(
      'default $name preserves request timeout and unreachable classification',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final hits = <String>[];
        server.listen((request) async {
          hits.add(request.uri.path);
          await request.drain<void>();
          // Stall the response; the service, not the fixture, owns the timeout.
        });
        final base = 'http://127.0.0.1:${server.port}';
        final overrides = _ProxyRecordingOverrides();
        await HttpOverrides.runWithHttpOverrides(() async {
          const timeout = Duration(milliseconds: 150);
          final service = bridge
              ? AndroidBridgeService(log: LogService(), timeout: timeout)
              : null;
          final sync = bridge
              ? null
              : SyncClient(log: LogService(), timeout: timeout);
          try {
            await expectLater(
              bridge
                  ? service!.probeDevice(base)
                  : sync!.pushKeep(deviceBase: base, items: const []),
              throwsA(
                isA<AppError>()
                    .having(
                      (error) => error.kind,
                      'kind',
                      bridge
                          ? AppErrorKind.bridgeUnreachable
                          : AppErrorKind.syncPeerUnreachable,
                    )
                    .having(
                      (error) => error.cause,
                      'timeout cause',
                      isA<TimeoutException>(),
                    )
                    .having((error) => error.retryable, 'retryable', isTrue),
              ),
            );
          } finally {
            service?.close();
            sync?.close();
          }
        }, overrides);
        expect(hits, [bridge ? '/device' : '/action']);
        expect(overrides.proxyQueries, isEmpty);
        _expectClientsClosed(overrides, base);
      },
    );
  }
}
