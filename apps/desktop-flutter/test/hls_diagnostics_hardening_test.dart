// ignore_for_file: invalid_use_of_protected_member, avoid_print
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/libmpv_guard.dart';

import 'package:media_kit/media_kit.dart';
import 'package:webhtv_pc/core/playback_diagnostics.dart';
import 'package:webhtv_pc/core/proxy_policy.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/proxy_server.dart';
import 'package:webhtv_pc/ui/player_controller.dart';

import 'support/player_navigation_fixture.dart';

const _vod = '#EXTM3U\n#EXTINF:6,\npart.ts\n#EXT-X-ENDLIST\n';

class _RealHttp extends HttpOverrides {}

class _HttpMedia extends NavigationMediaIO {
  _HttpMedia(this.client);
  final HttpClient client;
  Object? openError;
  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    final response = await (await client.getUrl(
      Uri.parse((playable as Media).uri),
    )).close();
    await response.drain<void>();
    if (openError case final error?) {
      throw error;
    }
    await super.open(playable, play: play);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final nativeUnavailable = libmpvUnavailableReason;
  if (nativeUnavailable == null) {
    MediaKit.ensureInitialized(
      libmpv: Platform.environment['WEBHTV_TEST_LIBMPV'],
    );
  }
  late HttpServer upstream;
  late HttpClient client;
  late LocalProxyServer proxy;
  late LogService log;
  late ProxySession session;
  late HttpOverrides? previous;
  setUp(() async {
    previous = HttpOverrides.current;
    HttpOverrides.global = _RealHttp();
    upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    client = HttpClient();
    log = LogService();
    proxy = LocalProxyServer(
      log: log,
      policy: const ProxyTargetPolicy(allowLoopback: true),
    );
    await proxy.start();
    session = proxy.sessions.create(
      siteKey: 'fixture',
      allowedHosts: {'127.0.0.1'},
    );
    final segment = await File(
      '../../packages/test-fixtures/media/segment-000.ts',
    ).readAsBytes();
    upstream.listen((request) async {
      final partial = request.headers.value('range') == 'bytes=1-';
      final bytes = request.uri.path == '/opaque'
          ? utf8.encode(_vod)
          : request.uri.path.endsWith('.ts')
          ? segment
          : [0x47, 0, 1, 2];
      request.response.statusCode = request.uri.path == '/error' ? 404 : 206;
      request.response.headers.set(
        'content-type',
        request.uri.path == '/html' ? 'text/html' : 'text/plain',
      );
      request.response.headers.set(
        'content-range',
        'bytes ${partial ? 1 : 0}-${bytes.length - 1}/${bytes.length}',
      );
      request.response.contentLength = bytes.length;
      request.response.add(bytes);
      await request.response.close();
    });
  });
  tearDown(() async {
    client.close(force: true);
    await proxy.stop();
    await upstream.close(force: true);
    log.dispose();
    HttpOverrides.global = previous;
  });
  String url(String path, {ProxySession? owner}) => proxy.urlFor(
    owner ?? session,
    Uri.parse('http://127.0.0.1:${upstream.port}$path'),
  );
  Future<int> fetch(String value) async {
    final response = await (await client.getUrl(Uri.parse(value))).close();
    await response.drain<void>();
    await Future<void>.delayed(Duration.zero);
    return response.statusCode;
  }

  for (final scenario in [
    ('opaque', 200, 206),
    ('binary', 206, 206),
    ('html', 502, 206),
    ('error', 404, 404),
  ]) {
    test('explicit HTTP statuses ${scenario.$1}', () async {
      expect(await fetch(url('/${scenario.$1}')), scenario.$2);
      final line = log.entries
          .lastWhere((e) => e.message.contains('elapsed='))
          .message;
      expect(line, contains('upstreamStatus=${scenario.$3}'));
      expect(line, contains('downstreamStatus=${scenario.$2}'));
    });
  }
  test('local denial has actual status and no invented upstream', () async {
    final denied = proxy.urlFor(session, Uri.parse('file:///invalid'));
    expect(await fetch(denied), 403);
    final line = log.entries
        .lastWhere((e) => e.message.contains('elapsed='))
        .message;
    expect(line, contains('downstreamStatus=403'));
    expect(line, isNot(contains('upstreamStatus=')));
  });
  test('legacy ProxyLogRecord status remains compatible', () {
    const record = ProxyLogRecord(
      tokenFingerprint: 'fingerprint',
      targetHost: 'fixture',
      statusCode: 206,
    );
    expect(record.line, contains('status=206'));
  });
  test('observations isolate target, child, session, origin, revocation and bounded storage', () async {
    final playing = url('/opaque');
    expect(proxy.observedFormatFor(playing), isNull);
    await fetch(playing);
    expect(proxy.observedFormatFor(playing), MediaFormat.hls);
    final child = proxy.urlForChild(
      session,
      Uri.parse('http://127.0.0.1:${upstream.port}/part.ts'),
    );
    await fetch(child);
    expect(proxy.observedFormatFor(child), isNull);
    expect(proxy.observedFormatFor(url('/binary')), isNull);
    final other = proxy.sessions.create(
      siteKey: 'fixture',
      allowedHosts: {'127.0.0.1'},
    );
    expect(proxy.observedFormatFor(url('/opaque', owner: other)), isNull);
    expect(
      proxy.observedFormatFor(playing.replaceFirst('127.0.0.1', 'localhost')),
      isNull,
    );
    expect(
      proxy.observedFormatFor(
        Uri.parse(playing).replace(port: proxy.port + 1).toString(),
      ),
      isNull,
    );
    proxy.sessions.revoke(session.token);
    expect(proxy.observedFormatFor(playing), isNull);
    for (var i = 0; i < ProxySession.maxChildTargets + 1; i++) {
      other.recordHlsPath('/$i');
    }
    expect(other.hasObservedHlsPath('/0'), isTrue);
    expect(
      other.hasObservedHlsPath('/${ProxySession.maxChildTargets}'),
      isFalse,
    );
  });
  test(
    'HEAD and incomplete Range do not erase prior positive signature evidence',
    () async {
      final playing = url('/opaque');
      await fetch(playing);
      expect(proxy.observedFormatFor(playing), MediaFormat.hls);
      final head = await (await client.openUrl(
        'HEAD',
        Uri.parse(playing),
      )).close();
      await head.drain<void>();
      expect(proxy.observedFormatFor(playing), MediaFormat.hls);
      final request = await client.getUrl(Uri.parse(playing));
      request.headers.set('range', 'bytes=1-');
      final response = await request.close();
      await response.drain<void>();
      expect(proxy.observedFormatFor(playing), MediaFormat.hls);
    },
  );
  test('completion rereads live evidence and never blocks success on observation failure', () async {
    final media = _HttpMedia(client);
    var failRead = false;
    final controller = PlayerController(
      player: Player(platformPlayer: media),
      observedMediaFormatFor: (url) {
        if (failRead) throw StateError('diagnostic unavailable');
        return proxy.observedFormatFor(url);
      },
    );
    addTearDown(controller.dispose);
    await controller.open(url('/opaque'), awaitFirstFrame: false);
    expect(controller.diagnostics?.format, MediaFormat.hls);
    await controller.open(url('/binary'), awaitFirstFrame: false);
    expect(controller.diagnostics?.format, MediaFormat.unknown);
    failRead = true;
    expect(
      (await controller.open(url('/opaque'), awaitFirstFrame: false)).succeeded,
      isTrue,
    );
    expect(controller.diagnostics?.format, MediaFormat.unknown);
  });
  test('failure completion reads live format and observation failures do not alter failure', () async {
    final media = _HttpMedia(client)
      ..openError = StateError('404 fixture missing');
    var failRead = false;
    final controller = PlayerController(
      player: Player(platformPlayer: media),
      observedMediaFormatFor: (url) {
        if (failRead) throw StateError('diagnostic unavailable');
        return proxy.observedFormatFor(url);
      },
    );
    addTearDown(controller.dispose);
    final first = await controller.open(url('/opaque'), awaitFirstFrame: false);
    expect(first.succeeded, isFalse);
    expect(controller.diagnostics?.format, MediaFormat.hls);
    expect(controller.diagnostics?.succeeded, isFalse);
    failRead = true;
    final second = await controller.open(
      url('/opaque'),
      awaitFirstFrame: false,
    );
    expect(second.succeeded, isFalse);
    expect(second.failureKind, first.failureKind);
    expect(controller.diagnostics?.format, MediaFormat.unknown);
  });
  test(
    'missing observation callback preserves success and unknown opaque format',
    () async {
      final media = _HttpMedia(client);
      final controller = PlayerController(
        player: Player(platformPlayer: media),
      );
      addTearDown(controller.dispose);
      expect(
        (await controller.open(
          url('/opaque'),
          awaitFirstFrame: false,
        )).succeeded,
        isTrue,
      );
      expect(controller.diagnostics?.format, MediaFormat.unknown);
    },
  );
  test(
    'real HTTP proxy observation reaches completed controller diagnostics',
    () async {
      final media = _HttpMedia(client);
      final controller = PlayerController(
        player: Player(platformPlayer: media),
        observedMediaFormatFor: proxy.observedFormatFor,
      );
      addTearDown(controller.dispose);
      final outcome = await controller.open(
        url('/opaque'),
        awaitFirstFrame: false,
      );
      expect(outcome.succeeded, isTrue);
      expect(controller.diagnostics?.format, MediaFormat.hls);
      expect(controller.diagnostics?.logLine, contains('format=hls'));
    },
  );
  test('installed media_kit loads real suffixless proxy HLS and reports observed format', () async {
    final player = Player(
      configuration: const PlayerConfiguration(logLevel: MPVLogLevel.error),
    );
    final native = player.platform! as NativePlayer;
    await native.setProperty('ao', 'null');
    await native.setProperty('vo', 'null');
    final controller = PlayerController(
      player: player,
      observedMediaFormatFor: proxy.observedFormatFor,
    );
    native.isVideoControllerAttached = false;
    final released = Completer<void>();
    native.release.add(() async => released.complete());
    try {
      final outcome = await controller.open(
        url('/opaque'),
        timeout: const Duration(seconds: 15),
        awaitFirstFrame: false,
      );
      expect(outcome.succeeded, isTrue);
      expect(outcome.duration, greaterThan(Duration.zero));
      expect(controller.diagnostics?.format, MediaFormat.hls);
      expect(controller.diagnostics?.logLine, contains('format=hls'));
      print(
        'NATIVE_PIPELINE succeeded=true format=hls durationMs=${outcome.duration.inMilliseconds}',
      );
    } finally {
      controller.dispose();
      await released.future.timeout(const Duration(seconds: 10));
    }
  }, skip: nativeUnavailable);
}
