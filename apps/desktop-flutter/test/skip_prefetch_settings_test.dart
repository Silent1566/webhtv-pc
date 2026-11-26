import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/core/tmdb_playback.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:webhtv_pc/core/skip_plan.dart';
import 'package:webhtv_pc/ui/player_page.dart';

import 'player_live_controls_test.dart' show flush, MediaIO, MediaJournal;
import 'support/player_page_harness.dart';

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/player_options.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/proxy_server.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/intro_skip_options_page.dart';

class _RealHttpOverrides extends HttpOverrides {}

class _PrefetchSkipState extends AppState {
  _PrefetchSkipState({required super.paths, required super.log});
  final primes = <List<Uri>>[];
  final cancels = <bool?>[];
  @override
  void primeSkipPrefetch(Iterable<Uri> targets) => primes.add(targets.toList());
  @override
  void cancelSkipPrefetch({bool clearCache = true}) => cancels.add(clearCache);
}

class _SkipMedia implements NativePlayer {
  _SkipMedia(PlatformPlayer original, MediaJournal journal)
    : transport = MediaIO(original, journal);
  final MediaIO transport;
  PlatformPlayer get original => transport.original;
  @override
  bool get disposed => transport.disposed;
  @override
  PlayerConfiguration get configuration => transport.configuration;
  @override
  PlayerStream get stream => transport.stream;
  @override
  PlayerState get state => transport.state;
  @override
  set state(PlayerState value) => transport.state = value;
  @override
  Future<int> get handle => transport.handle;
  @override
  List<Future<void> Function()> get release => transport.release;
  @override
  Completer<void> get videoControllerCompleter =>
      transport.videoControllerCompleter;
  @override
  bool get isVideoControllerAttached => transport.isVideoControllerAttached;
  @override
  set isVideoControllerAttached(bool value) =>
      transport.isVideoControllerAttached = value;
  void progress(int seconds) => transport.progress(seconds);

  final nativeCalls = <String>[];
  final seeks = <Duration>[];
  final openedStarts = <Duration?>[];
  int initialPosition = 1;
  Duration? initialBuffered;
  Future<void>? subtitleReady;
  final subtitleRequested = Completer<void>();
  int stops = 0;
  Duration initialDuration = const Duration(seconds: 1000);

  void emit({
    Duration? duration,
    int? position,
    bool? playing,
    Duration? buffered,
    bool? completed,
  }) {
    state = state.copyWith(
      duration: duration,
      position: position == null ? null : Duration(seconds: position),
      playing: playing,
      buffer: buffered,
      completed: completed,
    );
    if (duration != null) original.durationController.add(duration);
    if (position != null) original.positionController.add(state.position);
    if (playing != null) original.playingController.add(playing);
    if (buffered != null) original.bufferController.add(buffered);
    if (completed != null) original.completedController.add(completed);
  }

  final unexpectedCalls = <Symbol>[];
  final released = Completer<void>();

  @override
  Future<void> open(
    Playable playable, {
    bool play = true,
    bool synchronized = true,
  }) async {
    final media = playable as Media;
    transport.journal.opened.add(media.uri);
    openedStarts.add(media.start);
    final gate = transport.journal.gates.remove(media.uri);
    if (gate != null) await gate.future;
    if (transport.journal.failed.contains(media.uri)) {
      throw StateError('fixture next failed');
    }
    emit(
      duration: initialDuration,
      position: media.start?.inSeconds ?? initialPosition,
      playing: play,
      buffered: initialBuffered,
    );
  }

  @override
  Future<void> seek(Duration position, {bool synchronized = true}) {
    seeks.add(position);
    emit(position: position.inSeconds, playing: state.playing);
    return Future<void>.value();
  }

  @override
  Future<void> play({bool synchronized = true}) async => emit(playing: true);
  @override
  Future<void> pause({bool synchronized = true}) async {
    state = state.copyWith(playing: false);
    if (!disposed) original.playingController.add(false);
  }

  @override
  Future<void> setVolume(double volume, {bool synchronized = true}) =>
      transport.setVolume(volume);
  @override
  Future<void> setRate(double rate, {bool synchronized = true}) =>
      transport.setRate(rate);
  @override
  Future<void> setSubtitleTrack(
    SubtitleTrack track, {
    bool synchronized = true,
  }) async {
    if (subtitleReady != null) {
      if (!subtitleRequested.isCompleted) subtitleRequested.complete();
      await subtitleReady;
    }
    await transport.setSubtitleTrack(track);
  }

  @override
  Future<void> stop({
    bool open = false,
    bool notify = true,
    bool synchronized = true,
  }) async {
    stops++;
    state = state.copyWith(playing: false);
    if (notify) original.playingController.add(false);
  }

  @override
  Future<void> dispose({bool synchronized = true}) async {
    if (!original.videoControllerCompleter.isCompleted) {
      original.videoControllerCompleter.complete();
    }
    try {
      await transport.dispose();
    } finally {
      if (!released.isCompleted) released.complete();
    }
  }

  @override
  Future<void> setProperty(
    String key,
    String value, {
    bool waitForInitialization = true,
  }) async {
    nativeCalls.add('set:$key=$value wait=$waitForInitialization');
    if (!waitForInitialization &&
        const {'vo': 'libmpv', 'hwdec': 'auto', 'vid': 'auto'}[key] == value) {
      return;
    }
    throw UnsupportedError(
      'skip-menu transport does not apply native property $key',
    );
  }

  @override
  Future<String> getProperty(
    String key, {
    bool waitForInitialization = true,
  }) async {
    nativeCalls.add('get:$key');
    throw UnsupportedError(
      'skip-menu transport does not read native property $key',
    );
  }

  @override
  Future<void> observeProperty(
    String property,
    Future<void> Function(String) listener, {
    bool waitForInitialization = true,
  }) async {
    nativeCalls.add('observe:$property');
    throw UnsupportedError('skip-menu transport does not observe $property');
  }

  @override
  Future<void> unobserveProperty(
    String property, {
    bool waitForInitialization = true,
  }) async {
    nativeCalls.add('unobserve:$property');
    throw UnsupportedError('skip-menu transport has no observer for $property');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    unexpectedCalls.add(invocation.memberName);
    throw UnsupportedError('Unexpected native call: ${invocation.memberName}');
  }
}

Future<_SkipMedia> _mount(
  WidgetTester tester,
  PlayerPage page, {
  Size size = const Size(1280, 720),
  void Function(_SkipMedia)? configureMedia,
}) async {
  await tester.runAsync(page.state.bootstrap);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  installMediaKitMocks(tester);
  installWindowManagerMocks(tester);
  _SkipMedia? media;
  final seen = <Player>{};
  var active = true;
  addTearDown(() => active = false);
  tester.binding.addPersistentFrameCallback((_) {
    if (!active || find.byType(Video).evaluate().isEmpty) return;
    final player = tester.widget<Video>(find.byType(Video)).controller.player;
    if (!seen.add(player)) return;
    media = _SkipMedia(player.platform!, MediaJournal());
    configureMedia?.call(media!);
    player.platform = media;
  });
  await tester.pumpWidget(MaterialApp(home: page));
  await flush(tester);
  expect(tester.takeException(), isNull);
  return media!;
}

Future<void> unmount(WidgetTester tester) async {
  final videos = find.byType(Video);
  final platform = videos.evaluate().isEmpty
      ? null
      : tester.widget<Video>(videos).controller.player.platform;
  await tester.pumpWidget(const SizedBox.shrink());
  if (platform is _SkipMedia) {
    final disposal = Stopwatch()..start();
    while (!platform.released.isCompleted &&
        disposal.elapsed < const Duration(seconds: 10)) {
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    }
    expect(platform.released.isCompleted, isTrue);
    await tester.pump(const Duration(seconds: 5));
    // ignore: avoid_print
    print(
      'skip-menu native calls: ${platform.nativeCalls}; unknown: ${platform.unexpectedCalls}',
    );
    expect(platform.unexpectedCalls, isEmpty);
  }
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump();
}

void main() {
  for (final rate in [0.5, 1.0, 2.0]) {
    testWidgets(
      'midroll prefetch waits until near the segment instead of expiring minutes early rate=$rate',
      (tester) async {
        final temp = Directory.systemTemp.createTempSync(
          'prefetch-near-segment',
        );
        final log = LogService();
        final state = _PrefetchSkipState(
          paths: AppPaths.resolve(
            overrides: {
              'config': temp.path,
              'data': temp.path,
              'cache': '${temp.path}/cache',
              'state': '${temp.path}/logs',
            },
          ),
          log: log,
        );
        addTearDown(() async {
          state.dispose();
          await log.dispose();
        });
        await tester.runAsync(() async {
          await state.bootstrap();
          await state.setPlayerOptions(
            const PlayerOptions(
              skipPrefetch: true,
              skipMode: SkipMode.off,
              skipKinds: SkipKindBits.advertisement,
              skipSources: SkipSourceBits.todb,
            ),
          );
        });
        final client = MockClient(
          (_) async => http.Response(
            jsonEncode({
              'items': [
                {
                  'version_id': 1,
                  'version_runtime': 1000,
                  'marker': [
                    {
                      'marker_id': 1,
                      'marker_type': 'advertisement',
                      'time_start': 600,
                      'time_end': 620,
                    },
                  ],
                },
              ],
            }),
            200,
          ),
        );
        addTearDown(client.close);
        final media = await http.runWithClient(
          () => _mount(
            tester,
            PlayerPage(
              state: state,
              request: const PlaybackRequest(
                url: 'http://127.0.0.1:18888/p/fixture/data',
                title: 'fixture',
                siteKey: 'fixture',
                vodId: 'prefetch',
                vodName: 'fixture',
                episodeName: 'E1',
                flag: 'line',
                tmdb: TmdbPlaybackIdentity(
                  tmdbId: 1,
                  mediaType: TmdbMediaType.tv,
                  seasonNumber: 1,
                  episodeNumber: 1,
                ),
              ),
            ),
          ),
          () => client,
        );
        final deadline = Stopwatch()..start();
        while (!state.log.entries.any(
              (entry) => entry.message.contains('标定 1 段'),
            ) &&
            deadline.elapsed < const Duration(seconds: 3)) {
          await flush(tester);
        }
        expect(
          state.log.entries.any((entry) => entry.message.contains('标定 1 段')),
          isTrue,
        );
        expect(
          state.primes,
          isEmpty,
          reason: 'a target ten minutes away would expire before use',
        );
        await media.setRate(rate);
        await flush(tester);
        final near = 600 - (15 * rate).floor();
        media.emit(position: near - 1, playing: true);
        await flush(tester);
        expect(state.primes, isEmpty);
        media.emit(position: near, playing: true);
        await flush(tester);
        expect(state.primes, isNotEmpty);
        expect(state.primes.last.single.fragment, 't=620.0');
        await unmount(tester);
      },
    );
  }

  testWidgets(
    'real page to AppState private proxy prefetch then cache-only mpv landing request',
    (tester) async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final requests = <String>[];
        final arrived = Completer<void>();
        final server = await tester.runAsync(() async {
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          server.listen((request) async {
            requests.add(request.uri.path);
            if (request.uri.path.endsWith('.m3u8')) {
              request.response.headers.contentType = ContentType(
                'application',
                'vnd.apple.mpegurl',
              );
              request.response.write(
                [
                  '#EXTM3U',
                  '#EXT-X-TARGETDURATION:10',
                  for (var i = 0; i < 8; i++) ...['#EXTINF:10,', 's$i.ts'],
                  '#EXT-X-ENDLIST',
                  '',
                ].join(String.fromCharCode(10)),
              );
            } else {
              request.response.headers.contentType = ContentType(
                'video',
                'mp2t',
              );
              request.response.add([1, 2, 3, 4]);
            }
            await request.response.close();
            if (request.uri.path == '/s5.ts' && !arrived.isCompleted) {
              arrived.complete();
            }
          });
          return server;
        });
        final temp = Directory.systemTemp.createTempSync('prefetch-full-page');
        final log = LogService();
        final state = AppState(
          paths: AppPaths.resolve(
            overrides: {
              'config': temp.path,
              'data': temp.path,
              'cache': '${temp.path}/cache',
              'state': '${temp.path}/logs',
            },
          ),
          log: log,
        );
        final client = HttpClient();
        addTearDown(() async {
          client.close(force: true);
          await state.stopProxy();
          state.dispose();
          await log.dispose();
          await server!.close(force: true);
        });
        late String proxied;
        await tester.runAsync(() async {
          await state.bootstrap();
          await state.startProxy(port: 0);
          await state.setPlayerOptions(
            const PlayerOptions(
              skipPrefetch: true,
              skipMode: SkipMode.off,
              skipKinds: SkipKindBits.intro,
              skipRemoteEnabled: false,
            ),
          );
          await state.saveSkipSegments(
            siteKey: 'fixture',
            vodId: 'full-page',
            introEndMs: 30000,
          );
          final decision = await state.proxyManagedDecision(
            const PlaybackDecision(
              action: PlaybackAction.direct,
              url: 'http://127.0.0.1:9978/vod.m3u8',
            ),
            siteKey: 'fixture',
            managedResolver: (_) async => server!.port,
          );
          proxied = decision.url!;
          final response = await (await client.getUrl(Uri.parse(proxied)))
              .close();
          expect(response.statusCode, 200);
          await response.drain<void>();
          expect(requests, ['/vod.m3u8']);
        });
        await _mount(
          tester,
          PlayerPage(
            state: state,
            request: PlaybackRequest(
              url: proxied,
              title: 'fixture',
              siteKey: 'fixture',
              vodId: 'full-page',
              vodName: 'fixture',
              episodeName: 'E1',
              flag: 'line',
            ),
          ),
        );
        final deadline = Stopwatch()..start();
        while (!arrived.isCompleted &&
            deadline.elapsed < const Duration(seconds: 5)) {
          await tester.pump();
          await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        }
        expect(arrived.isCompleted, isTrue, reason: 'requests=$requests');
        await tester.runAsync(() async {
          final before = requests.where((path) => path == '/s3.ts').length;
          expect(before, 1);
          state.cancelSkipPrefetch(clearCache: false);
          final session = state.proxySessions.byToken(
            Uri.parse(proxied).pathSegments[1],
          )!;
          final target = Uri.parse(
            '${state.proxyBaseUrl}/p/${session.token}/${LocalProxyServer.encodeTarget(Uri.parse('http://127.0.0.1:9978/s3.ts'))}',
          );
          final response = await (await client.getUrl(target)).close();
          expect(await response.fold<List<int>>([], (a, b) => a..addAll(b)), [
            1,
            2,
            3,
            4,
          ]);
          expect(
            requests.where((path) => path == '/s3.ts').length,
            before,
            reason: 'actual AppState proxy cache served landing',
          );
          // ignore: avoid_print
          print(
            'prefetch real page landing bytes=4 upstream=$requests cacheHit=true',
          );
        });
        await unmount(tester);
      }, _RealHttpOverrides());
    },
  );

  for (final enabled in [false, true]) {
    testWidgets('real PlayerPage prefetch seam enabled=$enabled', (
      tester,
    ) async {
      final temp = Directory.systemTemp.createTempSync('prefetch-page');
      final log = LogService();
      final state = _PrefetchSkipState(
        paths: AppPaths.resolve(
          overrides: {
            'config': temp.path,
            'data': temp.path,
            'cache': '${temp.path}/cache',
            'state': '${temp.path}/logs',
          },
        ),
        log: log,
      );
      addTearDown(() async {
        state.dispose();
        await log.dispose();
      });
      await tester.runAsync(() async {
        await state.bootstrap();
        await state.setPlayerOptions(
          PlayerOptions(
            skipPrefetch: enabled,
            skipMode: SkipMode.auto,
            skipKinds: SkipKindBits.intro,
            skipRemoteEnabled: false,
          ),
        );
        await state.saveSkipSegments(
          siteKey: 'fixture',
          vodId: 'prefetch',
          introEndMs: 30000,
        );
      });
      final media = await _mount(
        tester,
        PlayerPage(
          state: state,
          request: const PlaybackRequest(
            url: 'http://127.0.0.1:18888/p/fixture/data',
            title: 'fixture',
            siteKey: 'fixture',
            vodId: 'prefetch',
            vodName: 'fixture',
            episodeName: 'E1',
            flag: 'line',
          ),
        ),
      );
      if (enabled) {
        expect(state.primes, isNotEmpty);
        expect(state.primes.every((batch) => batch.length == 1), isTrue);
        expect(state.primes.last.single.fragment, 't=30.0');
        expect(state.primes.last.single.path, '/p/fixture/data');
        expect(state.cancels, contains(false));
      } else {
        expect(state.primes, isEmpty);
        expect(state.cancels, isNotEmpty);
        expect(state.cancels, isNotEmpty);
        expect(state.cancels.last, isTrue);
      }
      expect(media.seeks, [const Duration(seconds: 30)]);
      await unmount(tester);
    });
  }

  test('skip prefetch default/JSON/normalization/copy equality round trips without touching skip defaults', () {
    final defaults = const PlayerOptions();
    expect(defaults.toJson()['skipPrefetch'], isTrue);
    final off = PlayerOptions.fromJson({'skipPrefetch': false});
    expect(off.toJson()['skipPrefetch'], isFalse);
    expect(off.normalized().toJson()['skipPrefetch'], isFalse);
    expect(off.copyWith().toJson()['skipPrefetch'], isFalse);
    expect(off, PlayerOptions.fromJson(off.toJson()));
    expect(off == defaults, isFalse);
    expect(off.hashCode, isNot(defaults.hashCode));
    expect(off.skipKinds, defaults.skipKinds);
    expect(off.skipMode, defaults.skipMode);
    expect(
      PlayerOptions.fromJson({'skipPrefetch': 'false'})
          .toJson()['skipPrefetch'],
      isTrue,
    );
  });

  testWidgets(
    'real skip settings toggle persists prefetch false and explains traffic cost',
    (tester) async {
      final temp = Directory.systemTemp.createTempSync(
        'skip-prefetch-settings',
      );
      final log = LogService();
      final state = AppState(
        paths: AppPaths.resolve(
          overrides: {
            'config': temp.path,
            'data': temp.path,
            'cache': '${temp.path}/cache',
            'state': '${temp.path}/logs',
          },
        ),
        log: log,
      );
      addTearDown(() async {
        state.dispose();
        await log.dispose();
      });
      await tester.runAsync(state.bootstrap);
      await tester.pumpWidget(
        MaterialApp(home: IntroSkipOptionsPage(state: state)),
      );
      final toggle = find.byKey(
        const ValueKey('settings-player-skip-prefetch'),
      );
      await tester.scrollUntilVisible(
        toggle,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(toggle, findsOneWidget);
      expect(find.textContaining('增加流量'), findsWidgets);
      await tester.ensureVisible(toggle);
      await tester.pump();
      await tester.runAsync(() => tester.tap(toggle));
      await tester.pump();
      await tester.runAsync(() async {
        final saved = jsonDecode(
          await File(state.paths.settingsPath).readAsString(),
        ) as Map;
        expect((saved['player'] as Map)['skipPrefetch'], isFalse);
      });
      expect(state.playerOptions.toJson()['skipPrefetch'], isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
