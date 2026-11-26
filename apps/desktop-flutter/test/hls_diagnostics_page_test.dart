// ignore_for_file: invalid_use_of_protected_member, avoid_print
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/player_page.dart';

import 'support/player_page_harness.dart';
import 'support/libmpv_guard.dart';
import 'player_queue_test.dart'
    show QueueFixture, QueueMediaIO, queueItems, closeQueue, settleQueue;

import 'package:media_kit/media_kit.dart';
import 'package:webhtv_pc/core/playback_diagnostics.dart';
import 'package:webhtv_pc/core/proxy_policy.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/proxy_server.dart';

const _vod = '#EXTM3U\n#EXTINF:6,\npart.ts\n#EXT-X-ENDLIST\n';

class _RealHttp extends HttpOverrides {}

class _ObservedApp extends AppState {
  _ObservedApp(this.proxy, {required super.paths, required super.log});
  final LocalProxyServer proxy;
  final reads = <String>[];
  final completed = <PlaybackDiagnostics>[];
  @override
  MediaFormat? proxyObservedFormatFor(String url) {
    reads.add(url);
    return proxy.observedFormatFor(url);
  }

  @override
  void recordPlaybackDiagnostics(PlaybackDiagnostics diagnostics) =>
      completed.add(diagnostics);
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
        'bytes 0-${bytes.length - 1}/${bytes.length}',
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

  for (final replacePending in [false, true]) {
    testWidgets(
      'PlayerPage runtime evidence after ${replacePending ? "pending controller replacement" : "initial controller construction"}',
      (tester) async {
        final playing = url('/opaque');
        final second = url(
          '/opaque',
          owner: proxy.sessions.create(
            siteKey: 'fixture',
            allowedHosts: {'127.0.0.1'},
          ),
        );
        await tester.runAsync(() async {
          await fetch(playing);
          await fetch(second);
        });
        final temp = Directory.systemTemp.createTempSync(
          'hls-diagnostic-page-',
        );
        final app = _ObservedApp(
          proxy,
          paths: AppPaths.resolve(
            overrides: {
              'config': '${temp.path}/config',
              'data': '${temp.path}/data',
              'cache': '${temp.path}/cache',
              'state': '${temp.path}/state',
            },
          ),
          log: log,
        );
        addTearDown(() {
          app.dispose();
          if (temp.existsSync()) temp.deleteSync(recursive: true);
        });
        installMediaKitMocks(tester);
        installWindowManagerMocks(tester);
        tester.view.physicalSize = const Size(1280, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });
        PlaybackRequest request(String address, String episode) =>
            PlaybackRequest(
              url: address,
              title: 'fixture',
              siteKey: 'fixture',
              vodId: '',
              vodName: 'fixture',
              episodeName: episode,
              flag: 'fixture',
              directUrl: true,
            );
        final queue = QueueFixture()
          ..resolveFile = ((key, current) async => request(second, 'two'));
        addTearDown(queue.dispose);
        final media = <QueueMediaIO>[];
        final gate = Completer<void>();
        final attached = <Player>{};
        var active = true;
        addTearDown(() {
          active = false;
          if (!gate.isCompleted) gate.complete();
        });
        tester.binding.addPersistentFrameCallback((_) {
          if (!active || find.byType(Video).evaluate().isEmpty) return;
          final player = tester
              .widget<Video>(find.byType(Video))
              .controller
              .player;
          if (!attached.add(player)) return;
          final io = QueueMediaIO(player.platform!);
          if (media.isEmpty && replacePending) io.nextOpen = gate;
          media.add(io);
          player.platform = io;
        });
        await tester.pumpWidget(
          MaterialApp(
            home: PlayerPage(
              state: app,
              request: request(playing, 'one'),
              queue: queue,
              queueItemKey: queueItems.first.key,
            ),
          ),
        );
        await settleQueue(tester);
        if (replacePending) {
          expect(app.completed, isEmpty);
          expect(media.single.opened, hasLength(1));
          await tester.runAsync(() => tester.tap(find.byTooltip('下一集（]）')));
          await settleQueue(tester);
          expect(
            media,
            hasLength(2),
            reason: 'must exercise replacement constructor',
          );
          expect(identical(media[0].original, media[1].original), isFalse);
          final delegate = debugPlayerObservedMediaFormatFor(
            tester.state<State<PlayerPage>>(find.byType(PlayerPage)),
          );
          expect(delegate, app.proxyObservedFormatFor);
          expect(delegate?.call(second), MediaFormat.hls);
          expect(delegate?.call(url('/unobserved')), isNull);
          expect(
            delegate?.call(second.replaceFirst('127.0.0.1', 'localhost')),
            isNull,
          );
          final revoked = proxy.sessions.create(
            siteKey: 'fixture',
            allowedHosts: {'127.0.0.1'},
          );
          final revokedUrl = url('/opaque', owner: revoked);
          await tester.runAsync(() => fetch(revokedUrl));
          expect(delegate?.call(revokedUrl), MediaFormat.hls);
          proxy.sessions.revoke(revoked.token);
          expect(delegate?.call(revokedUrl), isNull);
          expect(
            app.completed,
            isEmpty,
            reason: 'replacement delegate proof does not claim completed native playback',
          );
          gate.complete();
        }
        if (!replacePending) {
          expect(app.completed, isNotEmpty);
          expect(app.completed.last.format, MediaFormat.hls);
          expect(app.completed.last.succeeded, isTrue);
          expect(app.reads, contains(playing));
          expect(
            log.entries.any(
              (e) =>
                  e.scope == 'diagnostics' && e.message.contains('format=hls'),
            ),
            isTrue,
          );
        }
        print(
          'PAGE_PIPELINE replacement=$replacePending controllers=${media.length} delegateFormat=hls completed=${!replacePending}',
        );
        await closeQueue(tester);
      },
      skip: nativeUnavailable != null,
    );
  }
}
