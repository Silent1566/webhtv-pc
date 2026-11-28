// ignore_for_file: invalid_use_of_protected_member
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
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
  Completer<void>? finishOpen;
  Uint8List? frameSnapshot;
  Future<Uint8List?>? pendingSnapshot;
  int screenshotCalls = 0;
  int? stopPositionEcho;
  int? openPositionOverride;
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
    if (revision != _openRevision) return;
    if (failNextOpen) {
      failNextOpen = false;
      throw StateError('HTTP 404 Not Found');
    }
    await setRate(1);
    sample(
      openPositionOverride ?? (ignoreStart ? 1 : (media.start?.inSeconds ?? 1)),
      playing: play,
    );
    final gate = finishOpen;
    finishOpen = null;
    if (gate != null) await gate.future;
  }

  @override
  Future<Uint8List?> screenshot({
    String? format = 'image/jpeg',
    bool includeLibassSubtitles = false,
  }) async {
    screenshotCalls++;
    return pendingSnapshot == null ? frameSnapshot : await pendingSnapshot;
  }

  @override
  Future<void> stop() async {
    final echo = stopPositionEcho;
    if (echo != null) sample(echo);
    await pause();
  }

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
  bool trackFullscreen = false,
  int initialEpisodeIndex = 1,
  bool autoPreload = false,
  Size size = const Size(1280, 800),
}) async {
  final f = _PageFixture();
  final dir = Directory.systemTemp.createTempSync('playback-recovery-');
  f.state = QueueState(
    paths: AppPaths.resolve(
      overrides: {
        'config': '${dir.path}/config',
        'data': '${dir.path}/data',
        'cache': '${dir.path}/cache',
        'state': '${dir.path}/state',
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
      f.state.playerOptions.copyWith(
        autoNext: autoPreload,
        preloadNext: autoPreload,
        dragPause: dragPause,
      ),
    );
  });
  final episode = _lines.first.episodes[initialEpisodeIndex];
  f.requests = ValueNotifier(
    PlaybackRequest(
      url: 'https://media.test/${episode.url}',
      title: '恢复夹具',
      siteKey: 'fixture',
      vodId: 'vod',
      vodName: '恢复夹具',
      episodeName: episode.name,
      episodeTarget: episode.url,
      flag: 'line-a',
      episodeIndex: initialEpisodeIndex,
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
  installWindowManagerMocks(tester, trackFullscreen: trackFullscreen);
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

/// 等**真实信号**成立：门控 open 之后还有真实时间的异步收尾（首帧轮询、
/// 字幕/弹幕装配），按假时钟数 pump 次数在重载 runner 上会先于它就绪。
/// 这里每轮让出 20ms 真实时间，最多 2s；超时后仍由调用方的断言报失败。
Future<void> _waitFor(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 100 && !ready(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

const _startMissToast = '未能跳到该位置，已从头播放';

Future<void> _reopenWithEarlyLanding(
  WidgetTester tester,
  _PageFixture f,
) async {
  f.io.original.bufferController.add(const Duration(seconds: 310));
  await flush(tester);
  final finishOpen = f.io.finishOpen = Completer<void>();
  f.io.ignoreStart = false;
  int successfulOpens() => f.state.log.entries
      .where((entry) => entry.message.startsWith('播放结果 succeeded=true'))
      .length;
  try {
    await _drag(tester, 600);
    await _waitFor(tester, () => f.io.state.position.inSeconds == 600);
    expect(f.io.openedMedia.last.start, const Duration(seconds: 600));
    expect(f.io.state.position, const Duration(seconds: 600));
    expect(successfulOpens(), 1);
    f.io.sample(622);
    await flush(tester);
    expect(successfulOpens(), 1);
  } finally {
    finishOpen.complete();
  }
  await _waitFor(tester, () => successfulOpens() == 2);
  expect(successfulOpens(), 2);
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
  for (final action in ['first_frame', 'timeout', 'seek']) {
    _pageTest(
      switch (action) {
        'timeout' => 'episode cut releases the old frame on timeout',
        'seek' => 'seeking discards the prepared frame before the cut',
        _ => 'episode cut holds the old frame until the replacement starts',
      },
      (tester) async {
        final f = await _mount(tester, initialEpisodeIndex: 0);
        f.io.frameSnapshot = await tester.runAsync(() async {
          final recorder = ui.PictureRecorder();
          final canvas = Canvas(recorder);
          canvas.drawColor(const Color(0xff394a73), BlendMode.src);
          canvas.drawRect(
            const Rect.fromLTWH(0, 54, 160, 36),
            Paint()..color = const Color(0xffca914d),
          );
          final picture = recorder.endRecording();
          final image = await picture.toImage(160, 90);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          image.dispose();
          picture.dispose();
          return data!.buffer.asUint8List();
        });
        f.io.sample(997, playing: true);
        await _waitFor(
          tester,
          () =>
              f.state.log.entries.any((e) => e.message.startsWith('换集过渡旧帧就绪')),
        );
        expect(f.io.screenshotCalls, 1, reason: 'Must capture before the cut');
        expect(f.io.openedMedia, hasLength(1));
        if (action == 'seek') {
          f.io.ignoreSeek = false;
          f.io.original.bufferController.add(const Duration(seconds: 1000));
          await flush(tester);
          await _drag(tester, 400);
          expect(f.io.sought.last, const Duration(seconds: 400));
        }
        final finish = f.io.finishOpen = Completer<void>();
        try {
          await tester.sendKeyEvent(LogicalKeyboardKey.bracketRight);
          await _waitFor(tester, () => f.io.openedMedia.length == 2);
          expect(f.io.openedMedia, hasLength(2));
          await tester.pump();
          if (action == 'first_frame') {
            await _capture(tester, f, 'episode-cut-hold');
          }
          expect(
            find.byKey(const ValueKey('episode-cut-frame')),
            action == 'seek' ? findsNothing : findsOneWidget,
            reason: f.state.log.entries
                .map((e) => e.message)
                .toList()
                .reversed
                .take(12)
                .join('\n'),
          );
          if (action == 'timeout') {
            await tester.pump(const Duration(milliseconds: 1250));
            expect(
              find.byKey(const ValueKey('episode-cut-frame')),
              findsNothing,
            );
          }
        } finally {
          finish.complete();
        }
        await flush(tester);
        expect(find.byKey(const ValueKey('episode-cut-frame')), findsNothing);
      },
    );
  }

  _pageTest(
    'cross-buffer tail seek schedules preparation before reopened media is ready',
    (tester) async {
      final f = await _mount(tester, initialEpisodeIndex: 0, autoPreload: true);
      f.io.original.bufferController.add(const Duration(seconds: 310));
      await flush(tester);
      final finish = f.io.finishOpen = Completer<void>();
      try {
        await _drag(tester, 980);
        await _waitFor(tester, () => f.io.openedMedia.length == 2);
        expect(f.io.openedMedia, hasLength(2));
        expect(f.io.openedMedia.last.uri, contains('a1'));
        expect(
          f.state.log.entries.any(
            (e) =>
                e.message.startsWith('下一集预载调度') &&
                e.message.contains('position=980000ms seek=true'),
          ),
          isTrue,
        );
      } finally {
        finish.complete();
      }
      await flush(tester);
    },
  );

  _pageTest('a slow capture does not keep the page in the old episode', (
    tester,
  ) async {
    final f = await _mount(tester, initialEpisodeIndex: 0);
    final slow = Completer<Uint8List?>();
    f.io.pendingSnapshot = slow.future;
    f.io.sample(997, playing: true);
    await _waitFor(tester, () => f.io.screenshotCalls > 0);
    expect(
      f.io.screenshotCalls,
      1,
      reason: 'Capture is pending before the cut',
    );
    try {
      await tester.sendKeyEvent(LogicalKeyboardKey.bracketRight);
      await _waitFor(tester, () => f.io.openedMedia.length == 2);
      expect(f.io.openedMedia, hasLength(2));
      expect(
        f.io.screenshotCalls,
        1,
        reason: 'No replacement capture at the cut',
      );
      expect(find.byKey(const ValueKey('episode-cut-frame')), findsNothing);
    } finally {
      slow.complete(null);
    }
  });

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
  _pageTest('failed seek notice closes without seeking and stays dismissed', (
    tester,
  ) async {
    final f = await _mount(tester);
    await _drag(tester, 600);
    f.advance(21);
    f.io.sample(300);
    await flush(tester);
    expect(find.byType(PlayerSeekRecoveryBanner), findsOneWidget);
    final seeks = List<Duration>.of(f.io.sought);
    final opens = f.io.openedMedia.length;

    await tester.tap(find.byTooltip('关闭跳转提示（Esc）'));
    await flush(tester);
    expect(find.byType(PlayerSeekRecoveryBanner), findsNothing);
    f.advance(21);
    f.io.sample(301, playing: true);
    await flush(tester);
    expect(find.byType(PlayerSeekRecoveryBanner), findsNothing);
    expect(f.io.sought, seeks);
    expect(f.io.openedMedia, hasLength(opens));

    await _drag(tester, 610);
    f.advance(21);
    f.io.sample(302, playing: true);
    await flush(tester);
    expect(find.byType(PlayerSeekRecoveryBanner), findsOneWidget);
  });

  _pageTest('Escape closes failed seek notice before leaving fullscreen', (
    tester,
  ) async {
    final f = await _mount(tester, trackFullscreen: true);
    await tester.sendKeyEvent(LogicalKeyboardKey.f11);
    await flush(tester);
    expect(windowManagerFullscreen, isTrue);
    await _drag(tester, 600);
    f.advance(21);
    f.io.sample(300);
    await flush(tester);
    expect(find.byType(PlayerSeekRecoveryBanner), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await flush(tester);
    expect(find.byType(PlayerSeekRecoveryBanner), findsNothing);
    expect(windowManagerFullscreen, isTrue);
    expect(f.io.sought, [const Duration(seconds: 600)]);
  });

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
    'cross-buffer reopen does not warn when resumed playback is past tolerance',
    (tester) async {
      final f = await _mount(tester, dragPause: false);
      f.io.ignoreStart = false;
      f.io.original.bufferController.add(const Duration(seconds: 310));
      f.io.sample(300, buffering: true);
      await flush(tester);
      await _drag(tester, 600);
      bool reportedLanding() => f.state.log.entries.any(
        (entry) =>
            entry.message.startsWith('恢复播放进度') &&
            entry.message.contains('position=600000ms'),
      );
      await _waitFor(tester, reportedLanding);
      expect(f.io.openedMedia, hasLength(2));
      expect(f.io.openedMedia.last.start, const Duration(seconds: 600));
      expect(f.io.state.position, const Duration(seconds: 600));
      expect(reportedLanding(), isTrue);

      f.io.sample(617, buffering: true);
      await flush(tester);
      f.io.sample(618, buffering: false);
      await flush(tester);
      f.advance(1);
      f.io.sample(619);
      await flush(tester);
      f.advance(21);
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(PlayerSeekRecoveryBanner), findsNothing);
    },
  );

  _pageTest(
    'cross-buffer reopen remembers a landing before native open returns',
    (tester) async {
      final f = await _mount(tester, dragPause: false);
      await _reopenWithEarlyLanding(tester, f);
      expect(
        toastCenter.toasts.map((toast) => toast.message),
        isNot(contains(_startMissToast)),
      );
      for (final position in [623, 624, 625]) {
        f.advance(1);
        f.io.sample(position);
        await flush(tester);
      }
      f.advance(21);
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(PlayerSeekRecoveryBanner), findsNothing);
      expect(
        f.state.log.entries.map((entry) => entry.message),
        isNot(anyElement(startsWith('起播定位未生效'))),
      );
      expect(
        toastCenter.toasts.map((toast) => toast.message),
        isNot(contains(_startMissToast)),
      );
    },
  );

  _pageTest(
    'cross-buffer reopen still warns if the early landing never progresses',
    (tester) async {
      final f = await _mount(tester, dragPause: false);
      await _reopenWithEarlyLanding(tester, f);
      expect(
        toastCenter.toasts.map((toast) => toast.message),
        isNot(contains(_startMissToast)),
      );
      f.advance(21);
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(PlayerSeekRecoveryBanner), findsOneWidget);
      expect(
        toastCenter.toasts.map((toast) => toast.message),
        contains(_startMissToast),
      );
    },
  );

  _pageTest(
    'cross-buffer reopen ignores a near-target echo from the pre-open stop',
    (tester) async {
      final f = await _mount(tester, dragPause: false);
      f.io.stopPositionEcho = 600;
      f.io.openPositionOverride = 622;
      f.io.original.bufferController.add(const Duration(seconds: 310));
      await flush(tester);
      await _drag(tester, 600);
      bool reportedMiss() => f.state.log.entries.any(
        (entry) => entry.message.startsWith('起播定位未生效：wanted=600000ms'),
      );
      await _waitFor(tester, reportedMiss);
      expect(reportedMiss(), isTrue);
      expect(f.io.openedMedia.last.start, const Duration(seconds: 600));
      expect(
        toastCenter.toasts.map((toast) => toast.message),
        contains(_startMissToast),
      );
      for (final position in [623, 624]) {
        f.advance(1);
        f.io.sample(position);
        await flush(tester);
      }
      f.advance(21);
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(PlayerSeekRecoveryBanner), findsOneWidget);
    },
  );

  _pageTest(
    'cross-buffer reopen still warns if playback never reached the target',
    (tester) async {
      final f = await _mount(tester, dragPause: false);
      f.io.original.bufferController.add(const Duration(seconds: 310));
      await flush(tester);
      await _drag(tester, 600);
      bool reportedMiss() => f.state.log.entries.any(
        (entry) => entry.message.startsWith('起播定位未生效：wanted=600000ms'),
      );
      await _waitFor(tester, reportedMiss);
      expect(f.io.openedMedia.last.start, const Duration(seconds: 600));
      expect(reportedMiss(), isTrue);

      f.io.sample(617);
      await flush(tester);
      f.io.sample(618);
      await flush(tester);
      f.advance(21);
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(PlayerSeekRecoveryBanner), findsOneWidget);
    },
  );

  _pageTest(
    'cross-buffer reopen cannot settle on movement reported during buffering',
    (tester) async {
      final f = await _mount(tester, dragPause: false);
      f.io.ignoreStart = false;
      f.io.original.bufferController.add(const Duration(seconds: 310));
      f.io.sample(300, buffering: true);
      await flush(tester);
      await _drag(tester, 600);
      bool reportedLanding() => f.state.log.entries.any(
        (entry) =>
            entry.message.startsWith('恢复播放进度') &&
            entry.message.contains('position=600000ms'),
      );
      await _waitFor(tester, reportedLanding);
      expect(reportedLanding(), isTrue);

      f.io.sample(617, buffering: true);
      await flush(tester);
      f.advance(21);
      f.io.sample(618, buffering: true);
      await flush(tester);
      expect(find.byType(PlayerSeekRecoveryBanner), findsNothing);
      f.io.sample(619, buffering: false);
      await flush(tester);
      f.advance(21);
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(PlayerSeekRecoveryBanner), findsOneWidget);
    },
  );

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
      await _waitFor(
        tester,
        () =>
            f.state.targets.isNotEmpty &&
            f.io.openedMedia.length >= 3 &&
            f.io.openedMedia.last.start == const Duration(seconds: 300) &&
            f.io.state.rate == 2,
      );
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
  _pageTest('natural completion releases active seek recovery timer', (
    tester,
  ) async {
    final f = await _mount(tester);
    final timers = <Timer>[];
    await runZoned(
      () async {
        await _drag(tester, 999);
        expect(timers, isNotEmpty);
        f.io.sample(1000, playing: false);
        f.io.original.completedController.add(true);
        await flush(tester);
        await tester.pump(const Duration(seconds: 2));
        expect(timers.where((timer) => timer.isActive), isEmpty);
      },
      zoneSpecification: ZoneSpecification(
        createPeriodicTimer: (self, parent, zone, period, callback) {
          final timer = parent.createPeriodicTimer(zone, period, callback);
          if (period == const Duration(seconds: 1)) timers.add(timer);
          return timer;
        },
      ),
    );
  });
}
