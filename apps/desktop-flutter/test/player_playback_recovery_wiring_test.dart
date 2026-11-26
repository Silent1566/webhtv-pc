// ignore_for_file: invalid_use_of_protected_member
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:webhtv_pc/core/player_options.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/ui/player_overlay.dart';
import 'package:webhtv_pc/ui/player_page.dart';
import 'package:webhtv_pc/ui/toast.dart';

import 'player_live_controls_test.dart'
    show MediaIO, MediaJournal, flush, unmount;
import 'player_queue_test.dart' show QueueState;
import 'support/player_page_harness.dart';
import 'support/test_fonts.dart';

class _RecoveryIO extends MediaIO {
  _RecoveryIO(super.original, super.journal);
  final openedMedia = <Media>[];
  final sought = <Duration>[];
  bool ignoreSeek = true;
  bool ignoreStart = true;
  bool failNextOpen = false;
  Completer<void>? nextOpenGate;
  int playCalls = 0;
  int _openRevision = 0;

  void sample(int seconds, {bool? playing, bool? buffering}) {
    state = state.copyWith(
      position: Duration(seconds: seconds),
      duration: const Duration(seconds: 1000),
      playing: playing ?? state.playing,
      buffering: buffering ?? state.buffering,
    );
    original.durationController.add(state.duration);
    if (playing != null) original.playingController.add(playing);
    if (buffering != null) original.bufferingController.add(buffering);
    original.positionController.add(state.position);
  }

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    final revision = ++_openRevision;
    final media = playable as Media;
    openedMedia.add(media);
    final gate = nextOpenGate;
    nextOpenGate = null;
    if (gate != null) await gate.future;
    if (revision != _openRevision) return;
    if (failNextOpen) {
      failNextOpen = false;
      throw StateError('HTTP 404 Not Found');
    }
    await setRate(1);
    sample(ignoreStart ? 1 : (media.start?.inSeconds ?? 1), playing: play);
  }

  @override
  Future<void> stop() async => pause();
  @override
  Future<void> pause() async {
    state = state.copyWith(playing: false);
    original.playingController.add(false);
  }

  @override
  Future<void> play() async {
    playCalls++;
    state = state.copyWith(playing: true);
    original.playingController.add(true);
  }

  @override
  Future<void> seek(Duration position) async {
    sought.add(position);
    if (!ignoreSeek) sample(position.inSeconds);
  }
}

final _lines = [
  VodPlayLine(
    flag: 'line-a',
    episodes: [
      VodEpisode(name: '第1集', url: 'a1'),
      VodEpisode(name: '第2集', url: 'a2'),
    ],
  ),
  VodPlayLine(
    flag: 'line-b',
    episodes: [
      VodEpisode(name: '第1集', url: 'b1'),
      VodEpisode(name: '第2集', url: 'b2'),
    ],
  ),
];

class _PageFixture {
  late _RecoveryIO io;
  late QueueState state;
  final capture = GlobalKey();
  late ValueNotifier<PlaybackRequest> requests;
  DateTime now = DateTime(2026, 1, 1);
  void advance(int seconds) => now = now.add(Duration(seconds: seconds));
}

Future<_PageFixture> _mount(
  WidgetTester tester, {
  bool dragPause = true,
  Size size = const Size(1280, 800),
}) async {
  final f = _PageFixture();
  final dir = Directory.systemTemp.createTempSync('playback-recovery-');
  f.state = QueueState(
    paths: AppPaths.resolve(
      overrides: {
        for (final key in ['config', 'data', 'cache', 'state'])
          key: '${dir.path}/$key',
      },
    ),
    log: LogService(),
  );
  addTearDown(() {
    f.state.dispose();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  await tester.runAsync(() async {
    await f.state.bootstrap();
    await f.state.setPlayerOptions(
      f.state.playerOptions.copyWith(autoNext: false, dragPause: dragPause),
    );
  });
  f.requests = ValueNotifier(
    PlaybackRequest(
      url: 'https://media.test/a2',
      title: '恢复夹具',
      siteKey: 'fixture',
      vodId: 'vod',
      vodName: '恢复夹具',
      episodeName: '第2集',
      episodeTarget: 'a2',
      flag: 'line-a',
      episodeIndex: 1,
      playLines: _lines,
    ),
  );
  addTearDown(f.requests.dispose);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  installMediaKitMocks(tester);
  installWindowManagerMocks(tester);
  var active = true;
  addTearDown(() => active = false);
  final seen = <Player>{};
  tester.binding.addPersistentFrameCallback((_) {
    if (!active || find.byType(Video).evaluate().isEmpty) return;
    final player = tester.widget<Video>(find.byType(Video)).controller.player;
    if (!seen.add(player)) return;
    f.io = _RecoveryIO(player.platform!, MediaJournal());
    player.platform = f.io;
  });
  await tester.pumpWidget(
    MaterialApp(
      builder: (_, child) => RepaintBoundary(key: f.capture, child: child!),
      home: ValueListenableBuilder<PlaybackRequest>(
        valueListenable: f.requests,
        builder: (_, request, _) =>
            PlayerPage(state: f.state, request: request, clock: () => f.now),
      ),
    ),
  );
  await flush(tester);
  f.io.sample(300, playing: true);
  await flush(tester);
  expect(tester.takeException(), isNull);
  return f;
}

PlayerProgressSlider _slider(WidgetTester tester) {
  debugRevealPlayerControls(
    tester.state<State<PlayerPage>>(find.byType(PlayerPage)),
  );
  return tester.widget<PlayerProgressSlider>(find.byType(PlayerProgressSlider));
}

Future<void> _drag(WidgetTester tester, int target) async {
  final slider = _slider(tester);
  slider.onSeekStart!();
  await flush(tester);
  slider.onSeek(Duration(seconds: target));
  slider.onSeekEnd!();
  await flush(tester);
}

void _pageTest(String name, Future<void> Function(WidgetTester) body) {
  testWidgets(name, (tester) async {
    try {
      await body(tester);
    } finally {
      await unmount(tester);
    }
  });
}

Future<void> _capture(WidgetTester tester, _PageFixture f, String name) async {
  if (Platform.environment['PLAYBACK_RECOVERY_CAPTURE'] != '1') return;
  await tester.pump();
  final boundary =
      f.capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    final dir = Directory('../../.local/playback-recovery');
    await dir.create(recursive: true);
    await File('${dir.path}/$name.png')
        .writeAsBytes(bytes!.buffer.asUint8List());
  });
}

void main() {
  setUpAll(() async {
    if (Platform.environment['PLAYBACK_RECOVERY_CAPTURE'] == '1') {
      await loadFixtureFonts();
      await loadFixtureFonts(cjkFamily: 'Roboto');
      await loadFixtureFonts(cjkFamily: 'Microsoft YaHei UI');
    }
  });
  setUp(dismissAllToasts);
  tearDown(dismissAllToasts);
  _pageTest(
    'default drag pause still registers failed seek and returns to original position',
    (tester) async {
      final f = await _mount(tester);
      await _drag(tester, 600);
      expect(f.io.sought.last, const Duration(seconds: 600));
      f.advance(21);
      f.io.sample(300);
      await flush(tester);
      expect(find.byType(PlayerSeekRecoveryBanner), findsOneWidget);
      await _capture(tester, f, 'after-seek-1280');
      await tester.tap(
        find.byKey(const ValueKey('player-seek-recovery-return')),
      );
      await flush(tester);
      expect(f.io.sought.last, const Duration(seconds: 300));
    },
  );
  _pageTest('failed seek banner disappears after target really resumes', (
    tester,
  ) async {
    final f = await _mount(tester, dragPause: false);
    await _drag(tester, 600);
    f.advance(21);
    f.io.sample(300);
    await flush(tester);
    expect(find.byType(PlayerSeekRecoveryBanner), findsOneWidget);
    f.io.sample(600);
    await flush(tester);
    f.advance(1);
    f.io.sample(601);
    await flush(tester);
    expect(find.byType(PlayerSeekRecoveryBanner), findsNothing);
  });
  _pageTest(
    'buffering beyond guard timeout is not seek failure and can settle later',
    (tester) async {
      final f = await _mount(tester, dragPause: false);
      f.io.original.bufferController.add(const Duration(seconds: 310));
      await flush(tester);
      await _drag(tester, 600);
      f.io.sample(1, buffering: true);
      await flush(tester);
      f.advance(30);
      f.io.sample(1, buffering: true);
      await flush(tester);
      expect(find.byType(PlayerSeekRecoveryBanner), findsNothing);
      f.io.sample(600, playing: true, buffering: false);
      await flush(tester);
      f.advance(1);
      f.io.sample(601);
      await flush(tester);
      expect(find.byType(PlayerSeekRecoveryBanner), findsNothing);
    },
  );
  _pageTest('latest queued seek owns recovery target and original position', (
    tester,
  ) async {
    final f = await _mount(tester, dragPause: false);
    f.io.original.bufferController.add(const Duration(seconds: 310));
    await flush(tester);
    final gate = Completer<void>();
    f.io.nextOpenGate = gate;
    await _drag(tester, 600);
    f.io.sample(1, playing: false, buffering: true);
    await flush(tester);
    await _drag(tester, 700);
    gate.complete();
    for (var i = 0; i < 6; i++) {
      await flush(tester);
    }
    f.io.sample(2, playing: true, buffering: false);
    await flush(tester);
    f.advance(21);
    f.io.sample(2);
    await flush(tester);
    await flush(tester);
    expect(find.byType(PlayerSeekRecoveryBanner), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('player-seek-recovery-retry')));
    await flush(tester);
    expect(f.io.openedMedia.last.start, const Duration(seconds: 700));
  });
  _pageTest('old seek reopen cannot carry recovery into replacement episode', (
    tester,
  ) async {
    final f = await _mount(tester, dragPause: false);
    f.io.original.bufferController.add(const Duration(seconds: 310));
    await flush(tester);
    final gate = Completer<void>();
    f.io.nextOpenGate = gate;
    await _drag(tester, 600);
    f.requests.value = f.requests.value.copyWith(
      url: 'https://media.test/a1',
      episodeTarget: 'a1',
      episodeName: '第1集',
      episodeIndex: 0,
    );
    await flush(tester);
    gate.complete();
    await flush(tester);
    f.advance(30);
    f.io.sample(50, playing: true);
    await flush(tester);
    expect(find.byType(PlayerSeekRecoveryBanner), findsNothing);
    expect(f.io.openedMedia.last.uri, 'https://media.test/a1');
  });
  _pageTest(
    'automatic same-episode fallback explicitly restores playhead and speed',
    (tester) async {
      final f = await _mount(tester);
      await tester.runAsync(
        () => f.state.setPlayerOptions(
          f.state.playerOptions.copyWith(
            failureFallback: PlayerFailureFallback.line,
          ),
        ),
      );
      await f.io.setRate(2);
      await flush(tester);
      f.io.ignoreStart = false;
      f.io.failNextOpen = true;
      f.requests.value = f.requests.value.copyWith(
        url: 'https://media.test/expired-a2',
      );
      for (var i = 0; i < 6; i++) {
        await flush(tester);
      }
      expect(f.state.targets.last.target, 'b2');
      expect(f.io.openedMedia.last.start, const Duration(seconds: 300));
      expect(f.io.state.rate, 2);
      expect(find.textContaining('播放中断'), findsNothing);
    },
  );
  _pageTest(
    'runtime error clears on progress then same-text new event confirms again',
    (tester) async {
      final f = await _mount(tester);
      f.io.original.errorController.add('HTTP stream failed');
      await flush(tester);
      f.advance(9);
      f.io.sample(300);
      await flush(tester);
      expect(find.textContaining('播放中断'), findsOneWidget);
      await _capture(tester, f, 'after-runtime-1280');
      f.io.sample(302);
      await flush(tester);
      expect(find.textContaining('播放中断'), findsNothing);
      f.advance(20);
      f.io.sample(303);
      await flush(tester);
      expect(find.textContaining('播放中断'), findsNothing);
      f.io.original.errorController.add('HTTP stream failed');
      await flush(tester);
      f.advance(9);
      f.io.sample(303);
      await flush(tester);
      expect(find.textContaining('播放中断'), findsOneWidget);
    },
  );

  _pageTest('warning then long pause resumes without a stale error deadline', (
    tester,
  ) async {
    final f = await _mount(tester);
    f.io.original.errorController.add('No audio devices found!');
    await flush(tester);
    await f.io.pause();
    await flush(tester);
    f.advance(30);
    await f.io.play();
    await flush(tester);
    expect(find.textContaining('播放中断'), findsNothing);
    f.io.sample(302);
    await flush(tester);
    f.advance(30);
    f.io.sample(304);
    await flush(tester);
    expect(find.textContaining('播放中断'), findsNothing);
  });

  _pageTest(
    'warning before backward seek never rejects normal new-position playback',
    (tester) async {
      final f = await _mount(tester, dragPause: false);
      f.io.original.errorController.add('Subtitle track not found');
      await flush(tester);
      f.io.ignoreSeek = false;
      await _drag(tester, 120);
      f.io.sample(120);
      await flush(tester);
      f.advance(1);
      f.io.sample(121);
      await flush(tester);
      f.advance(30);
      f.io.sample(122);
      await flush(tester);
      expect(find.textContaining('播放中断'), findsNothing);
      expect(find.byType(PlayerSeekRecoveryBanner), findsNothing);
    },
  );
  _pageTest(
    'engine error then premature EOF confirms failure rather than treating EOF as pause',
    (tester) async {
      final f = await _mount(tester);
      f.io.original.errorController.add('HTTP stream failed');
      await flush(tester);
      f.io.sample(300, playing: false, buffering: false);
      f.io.original.completedController.add(true);
      await flush(tester);
      f.advance(9);
      await tester.pump(const Duration(seconds: 1));
      await flush(tester);
      expect(find.textContaining('播放中断'), findsOneWidget);
      expect(f.io.openedMedia.length, 1);
    },
  );

  _pageTest(
    'old default drag completion cannot resume a newly paused replacement episode',
    (tester) async {
      final f = await _mount(tester);
      f.io.original.bufferController.add(const Duration(seconds: 310));
      await flush(tester);
      final gate = Completer<void>();
      f.io.nextOpenGate = gate;
      await _drag(tester, 600);
      f.requests.value = f.requests.value.copyWith(
        url: 'https://media.test/a1',
        episodeTarget: 'a1',
        episodeName: '第1集',
        episodeIndex: 0,
      );
      for (var i = 0; i < 4; i++) {
        await flush(tester);
      }
      await f.io.pause();
      await flush(tester);
      final playCalls = f.io.playCalls;
      gate.complete();
      for (var i = 0; i < 4; i++) {
        await flush(tester);
      }
      expect(f.io.playCalls, playCalls);
      expect(f.io.state.playing, isFalse);
      expect(find.byType(PlayerSeekRecoveryBanner), findsNothing);
    },
  );
  for (final initiallyPlaying in [false, true]) {
    _pageTest(
      'queued seek preserves latest playing intention instead of first: initial=$initiallyPlaying',
      (tester) async {
        final f = await _mount(tester);
        if (!initiallyPlaying) await f.io.pause();
        await flush(tester);
        f.io.original.bufferController.add(const Duration(seconds: 310));
        await flush(tester);
        final gate = Completer<void>();
        f.io.nextOpenGate = gate;
        await _drag(tester, 600);
        if (initiallyPlaying) {
          await f.io.pause();
        } else {
          await f.io.play();
        }
        await flush(tester);
        await _drag(tester, 700);
        gate.complete();
        for (var i = 0; i < 6; i++) {
          await flush(tester);
        }
        expect(f.io.openedMedia.last.start, const Duration(seconds: 700));
        expect(f.io.state.playing, !initiallyPlaying);
      },
    );
  }

  _pageTest(
    'no-op seek at normal completion does not keep recovery polling alive',
    (tester) async {
      final f = await _mount(tester);
      await _drag(tester, 300);
      expect(find.byType(PlayerSeekRecoveryBanner), findsNothing);
      f.io.sample(1000, playing: false);
      f.io.original.completedController.add(true);
      await flush(tester);
      f.advance(30);
      await tester.pump(const Duration(seconds: 2));
      expect(find.byType(PlayerSeekRecoveryBanner), findsNothing);
      expect(find.textContaining('播放中断'), findsNothing);
    },
  );
  _pageTest('natural completion releases active seek recovery timer', (tester) async {
    final f = await _mount(tester);
    final timers = <Timer>[];
    await runZoned(() async {
      await _drag(tester, 999);
      expect(timers, isNotEmpty);
      f.io.sample(1000, playing: false);
      f.io.original.completedController.add(true);
      await flush(tester);
      await tester.pump(const Duration(seconds: 2));
      expect(timers.where((timer) => timer.isActive), isEmpty);
    }, zoneSpecification: ZoneSpecification(
      createPeriodicTimer: (self, parent, zone, period, callback) {
        final timer = parent.createPeriodicTimer(zone, period, callback);
        if (period == const Duration(seconds: 1)) timers.add(timer);
        return timer;
      },
    ));
  });

}
