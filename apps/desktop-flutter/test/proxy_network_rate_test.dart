import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:webhtv_pc/core/proxy_policy.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/proxy_server.dart';
import 'package:webhtv_pc/ui/player_controller.dart';

class _RealHttp extends HttpOverrides {}

class _Media extends PlatformPlayer {
  _Media() : super(configuration: const PlayerConfiguration());
  Future<void>? _closing;

  @override
  Future<void> dispose() => _closing ??= super.dispose();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('shared proxy network rate', () {
    late Duration now;
    late _Media media;
    late PlayerController controller;

    setUp(() {
      now = Duration.zero;
      media = _Media();
      controller = PlayerController(
        player: Player(platformPlayer: media),
        networkClock: () => now,
      );
    });

    tearDown(() async {
      controller.dispose();
      await media.dispose();
    });

    test(
      'updates on each byte delta without waiting for buffer completion',
      () async {
        expect(
          await controller.sampleNetworkRate(
            proxyTraffic: (sessionId: 'one', receivedBytes: 1000),
          ),
          isNull,
        );
        now = const Duration(seconds: 1);
        expect(
          await controller.sampleNetworkRate(
            proxyTraffic: (sessionId: 'one', receivedBytes: 21000),
          ),
          20000.0,
        );
        expect(controller.bytesPerSecond, 20000.0);
        now = const Duration(seconds: 2);
        expect(
          await controller.sampleNetworkRate(
            proxyTraffic: (sessionId: 'one', receivedBytes: 51000),
          ),
          30000.0,
        );
        expect(controller.bytesPerSecond, 30000.0);
      },
    );

    test(
      'uses measured elapsed time rather than assuming exactly one second',
      () async {
        await controller.sampleNetworkRate(
          proxyTraffic: (sessionId: 'one', receivedBytes: 0),
        );
        now = const Duration(milliseconds: 500);
        expect(
          await controller.sampleNetworkRate(
            proxyTraffic: (sessionId: 'one', receivedBytes: 20000),
          ),
          40000.0,
        );
      },
    );

    test(
      'no received bytes means zero, not an old engine rate or unknown',
      () async {
        await controller.sampleNetworkRate(
          proxyTraffic: (sessionId: 'one', receivedBytes: 1000),
        );
        now = const Duration(seconds: 1);
        expect(
          await controller.sampleNetworkRate(
            proxyTraffic: (sessionId: 'one', receivedBytes: 1000),
          ),
          0.0,
        );
        expect(formatByteRate(controller.bytesPerSecond), '0 B/s');
      },
    );

    test(
      'a new session starts a fresh baseline, even if its counter is larger',
      () async {
        await controller.sampleNetworkRate(
          proxyTraffic: (sessionId: 'one', receivedBytes: 1000),
        );
        now = const Duration(seconds: 1);
        await controller.sampleNetworkRate(
          proxyTraffic: (sessionId: 'one', receivedBytes: 11000),
        );
        now = const Duration(seconds: 2);
        expect(
          await controller.sampleNetworkRate(
            proxyTraffic: (sessionId: 'two', receivedBytes: 1000000),
          ),
          isNull,
        );
        expect(controller.bytesPerSecond, isNull);
        now = const Duration(seconds: 3);
        expect(
          await controller.sampleNetworkRate(
            proxyTraffic: (sessionId: 'two', receivedBytes: 1002000),
          ),
          2000.0,
        );
      },
    );

    test(
      'a stopped ticker cannot average traffic across an unsampled gap',
      () async {
        await controller.sampleNetworkRate(
          proxyTraffic: (sessionId: 'one', receivedBytes: 0),
        );
        now = const Duration(seconds: 1);
        await controller.sampleNetworkRate(
          proxyTraffic: (sessionId: 'one', receivedBytes: 10000),
        );
        controller.resetNetworkRate();
        expect(controller.bytesPerSecond, isNull);
        now = const Duration(seconds: 60);
        expect(
          await controller.sampleNetworkRate(
            proxyTraffic: (sessionId: 'one', receivedBytes: 500000),
          ),
          isNull,
        );
        now = const Duration(seconds: 61);
        expect(
          await controller.sampleNetworkRate(
            proxyTraffic: (sessionId: 'one', receivedBytes: 530000),
          ),
          30000.0,
        );
      },
    );

    test(
      'a reset counter or non-positive interval never yields an invalid rate',
      () async {
        await controller.sampleNetworkRate(
          proxyTraffic: (sessionId: 'one', receivedBytes: 1000),
        );
        expect(
          await controller.sampleNetworkRate(
            proxyTraffic: (sessionId: 'one', receivedBytes: 2000),
          ),
          isNull,
        );
        now = const Duration(seconds: 1);
        expect(
          await controller.sampleNetworkRate(
            proxyTraffic: (sessionId: 'one', receivedBytes: 500),
          ),
          isNull,
        );
        now = const Duration(seconds: 2);
        expect(
          await controller.sampleNetworkRate(
            proxyTraffic: (sessionId: 'one', receivedBytes: 2500),
          ),
          2000.0,
        );
      },
    );

    test('unmanaged playback keeps the original engine fallback', () async {
      expect(await controller.sampleNetworkRate(), isNull);
    });
  });

  group('actual upstream byte accounting', () {
    late HttpServer upstream;
    late HttpClient client;
    late LocalProxyServer proxy;
    late LogService log;
    late HttpOverrides? previousHttp;

    setUp(() async {
      previousHttp = HttpOverrides.current;
      HttpOverrides.global = _RealHttp();
      upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      client = HttpClient();
      log = LogService();
      proxy = LocalProxyServer(
        log: log,
        policy: const ProxyTargetPolicy(allowLoopback: true),
      );
      await proxy.start();
    });

    tearDown(() async {
      client.close(force: true);
      await proxy.stop();
      await upstream.close(force: true);
      log.dispose();
      HttpOverrides.global = previousHttp;
    });

    ProxySession session() =>
        proxy.sessions.create(siteKey: 'test', allowedHosts: {'127.0.0.1'});
    Uri target(String path) =>
        Uri.parse('http://127.0.0.1:${upstream.port}/$path');

    test(
      'counts chunks before the response finishes and isolates other sessions',
      () async {
        final gate = Completer<void>();
        addTearDown(() {
          if (!gate.isCompleted) gate.complete();
        });
        upstream.listen((request) async {
          try {
            request.response.headers.contentType = ContentType.binary;
            request.response.contentLength = 131072;
            request.response.add(List<int>.filled(65536, 1));
            await request.response.flush();
            await gate.future;
            request.response.add(List<int>.filled(65536, 2));
            await request.response.close();
          } catch (_) {}
        });
        final one = session();
        final two = session();
        final url = proxy.urlFor(one, target('media.bin'));
        final response = await (await client.getUrl(Uri.parse(url))).close();
        final first = Completer<void>();
        final done = Completer<void>();
        var received = 0;
        response.listen(
          (chunk) {
            received += chunk.length;
            if (received >= 65536 && !first.isCompleted) first.complete();
          },
          onDone: () => done.complete(),
          onError: done.completeError,
        );
        await first.future.timeout(const Duration(seconds: 3));
        expect(done.isCompleted, isFalse);
        expect(proxy.trafficFor(url)?.receivedBytes, 65536);
        expect(
          one.bytes,
          131072,
          reason:
              'quota tracks advertised bytes; speed must not use that counter',
        );
        expect(
          proxy
              .trafficFor(proxy.urlFor(two, target('other.bin')))
              ?.receivedBytes,
          0,
        );
        gate.complete();
        await done.future.timeout(const Duration(seconds: 3));
        expect(proxy.trafficFor(url)?.receivedBytes, 131072);
      },
    );

    test(
      'counts upstream playlist bytes, not the larger rewritten body',
      () async {
        const body = '#EXTM3U\n#EXTINF:4,\npart.ts\n#EXT-X-ENDLIST\n';
        upstream.listen((request) async {
          request.response.headers.contentType = ContentType(
            'application',
            'vnd.apple.mpegurl',
          );
          request.response.write(body);
          await request.response.close();
        });
        final one = session();
        final url = proxy.urlFor(one, target('index.m3u8'));
        final response = await (await client.getUrl(Uri.parse(url))).close();
        final rewritten = await response.transform(utf8.decoder).join();
        expect(rewritten.length, greaterThan(body.length));
        expect(proxy.trafficFor(url)?.receivedBytes, utf8.encode(body).length);
      },
    );

    test(
      'HEAD does not count advertised content length as received traffic',
      () async {
        upstream.listen((request) async {
          request.response.headers.contentType = ContentType.binary;
          request.response.contentLength = 65536;
          await request.response.close();
        });
        final one = session();
        final url = proxy.urlFor(one, target('media.bin'));
        final response = await (await client.openUrl(
          'HEAD',
          Uri.parse(url),
        )).close();
        await response.drain<void>();
        expect(proxy.trafficFor(url)?.receivedBytes, 0);
      },
    );

    test('only resolves a live session on this proxy origin', () async {
      final one = session();
      final url = proxy.urlFor(one, target('media.bin'));
      expect(proxy.trafficFor(url)?.sessionId, one.id);
      expect(
        proxy.trafficFor(
          Uri.parse(url).replace(host: 'example.com').toString(),
        ),
        isNull,
      );
      expect(
        proxy.trafficFor(
          Uri.parse(url).replace(port: proxy.port + 1).toString(),
        ),
        isNull,
      );
      expect(proxy.trafficFor('invalid'), isNull);
      expect(proxy.trafficFor('${proxy.baseUrl}/p/unknown/media'), isNull);
      proxy.sessions.revoke(one.token);
      expect(proxy.trafficFor(url), isNull);
    });
  });
}
