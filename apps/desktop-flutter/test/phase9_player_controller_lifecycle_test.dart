// ignore_for_file: invalid_use_of_protected_member

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/subtitle.dart';
import 'package:webhtv_pc/services/subtitle_service.dart';
import 'package:webhtv_pc/ui/player_controller.dart';

// No frames are pumped: VideoController's post-frame native setup never runs.
// Media I/O and delayed engine disposal are controlled at PlatformPlayer only.
class _MediaIO extends PlatformPlayer {
  _MediaIO() : super(configuration: const PlayerConfiguration());

  final openGate = Completer<void>();
  final disposalGate = Completer<void>();
  final volumeGate = Completer<void>();
  final subtitleGate = Completer<void>();
  Future<void>? disposal;
  Object? openError;
  bool reportLoaded = true;
  int opens = 0;

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    opens++;
    await openGate.future;
    if (openError case final error?) throw error;
    if (reportLoaded) {
      state = state.copyWith(
        duration: const Duration(seconds: 100),
        position: const Duration(seconds: 1),
        playing: true,
      );
      durationController.add(state.duration);
      positionController.add(state.position);
      playingController.add(true);
    }
  }

  @override
  Future<void> setVolume(double volume) => volumeGate.future;

  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) => subtitleGate.future;

  @override
  Future<void> dispose() =>
      disposal ??= disposalGate.future.then((_) => super.dispose());
}

class _ObservedController extends PlayerController {
  _ObservedController(Player player, {super.subtitleLoader})
    : super(player: player);

  int notifications = 0;

  @override
  void notifyListeners() {
    notifications++;
    super.notifyListeners();
  }
}

class _SubtitleIO implements SubtitleLoader {
  final gate = Completer<SubtitleDocument>();

  @override
  Future<SubtitleDocument> load(
    SubtitleInfo subtitle, {
    Map<String, String> headers = const {},
  }) => gate.future;
}

class _Fixture {
  _Fixture({SubtitleLoader? subtitleLoader}) {
    controller = _ObservedController(
      Player(platformPlayer: media),
      subtitleLoader: subtitleLoader ?? _SubtitleIO(),
    );
    addTearDown(() async {
      dispose();
      media.disposalGate.complete();
      await media.disposal;
    });
  }

  final media = _MediaIO();
  late final _ObservedController controller;
  bool disposed = false;

  void dispose() {
    if (disposed) return;
    disposed = true;
    controller.dispose();
  }
}

const _url = 'https://fixture.test/lifecycle.m3u8';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('open suspended during dispose still returns success without notify or state writes', () async {
    final fixture = _Fixture();
    final controller = fixture.controller;
    final pending = controller.open(_url, awaitFirstFrame: false);
    expect(controller.isLoading, isTrue);
    fixture.dispose();
    final notifications = controller.notifications;
    fixture.media.openGate.complete();

    final outcome = await pending;
    expect(outcome.succeeded, isTrue);
    expect(outcome.url, _url);
    expect(outcome.duration, const Duration(seconds: 100));
    expect(controller.notifications, notifications);
    expect(controller.lastOutcome, isNull);
    expect(controller.diagnostics, isNull);
    expect(controller.isLoading, isTrue);
    expect(fixture.media.durationController.hasListener, isFalse);
    expect(fixture.media.positionController.hasListener, isFalse);
    expect(fixture.media.playingController.hasListener, isFalse);
    expect(fixture.media.errorController.hasListener, isFalse);
  });

  test('open suspended during dispose still returns classified failure without notify or state writes', () async {
    final fixture = _Fixture();
    final controller = fixture.controller;
    fixture.media.openError = StateError('404 missing episode');
    final pending = controller.open(_url, awaitFirstFrame: false);
    fixture.dispose();
    final notifications = controller.notifications;
    fixture.media.openGate.complete();

    final outcome = await pending;
    expect(outcome.succeeded, isFalse);
    expect(outcome.failureKind, PlayerFailureKind.notFound);
    expect(outcome.errorMessage, contains('404 missing episode'));
    expect(controller.notifications, notifications);
    expect(controller.lastOutcome, isNull);
    expect(controller.diagnostics, isNull);
    expect(controller.isLoading, isTrue);
    expect(fixture.media.errorController.hasListener, isFalse);
  });

  test(
    'open completing after dispose can timeout without notify or state writes',
    () async {
      final fixture = _Fixture();
      final controller = fixture.controller;
      fixture.media.reportLoaded = false;
      final pending = controller.open(
        _url,
        awaitFirstFrame: false,
        timeout: const Duration(milliseconds: 1),
      );
      fixture.dispose();
      final notifications = controller.notifications;
      fixture.media.openGate.complete();

      final outcome = await pending;
      expect(outcome.succeeded, isFalse);
      expect(outcome.failureKind, PlayerFailureKind.timeout);
      expect(controller.notifications, notifications);
      expect(controller.lastOutcome, isNull);
      expect(controller.diagnostics, isNull);
      expect(controller.isLoading, isTrue);
      expect(fixture.media.durationController.hasListener, isFalse);
    },
  );

  test(
    'dispose during a pending retry delay never opens the engine again',
    () async {
      final fixture = _Fixture();
      final controller = fixture.controller;
      fixture.media.openError = StateError('connection refused');
      fixture.media.openGate.complete();
      final firstFailure = Completer<void>();
      controller.addListener(() {
        if (controller.lastOutcome?.succeeded == false &&
            !firstFailure.isCompleted) {
          firstFailure.complete();
        }
      });
      final pending = controller.openWithRetry(_url);
      await firstFailure.future;
      // Let openWithRetry enter its 600ms delay before disposing.
      await Future<void>.delayed(Duration.zero);
      fixture.dispose();
      final notifications = controller.notifications;
      final firstOutcome = controller.lastOutcome;

      final outcome = await pending;
      expect(outcome.failureKind, PlayerFailureKind.network);
      expect(outcome, same(firstOutcome));
      expect(fixture.media.opens, 1);
      expect(controller.notifications, notifications);
    },
  );

  test('failure returning after dispose never starts a retry', () async {
    final fixture = _Fixture();
    fixture.media.openError = StateError('connection refused');
    final pending = fixture.controller.openWithRetry(_url);
    fixture.dispose();
    final notifications = fixture.controller.notifications;
    fixture.media.openGate.complete();

    final outcome = await pending;
    expect(outcome.failureKind, PlayerFailureKind.network);
    expect(fixture.media.opens, 1);
    expect(fixture.controller.notifications, notifications);
  });

  test(
    'engine stream events after dispose do not notify or update state',
    () async {
      final fixture = _Fixture();
      final controller = fixture.controller;
      fixture.dispose();
      final notifications = controller.notifications;
      final media = fixture.media;
      media.positionController.add(const Duration(seconds: 9));
      media.durationController.add(const Duration(seconds: 100));
      media.bufferController.add(const Duration(seconds: 20));
      media.bufferingController.add(true);
      media.bufferingPercentageController.add(50);
      media.playingController.add(true);
      media.completedController.add(true);
      media.volumeController.add(25);
      media.rateController.add(2);
      media.videoParamsController.add(const VideoParams(w: 1920, h: 1080));
      media.audioParamsController.add(const AudioParams(sampleRate: 48000));
      media.audioBitrateController.add(128000);
      media.widthController.add(1920);
      media.heightController.add(1080);
      media.errorController.add('late engine warning');
      media.tracksController.add(
        const Tracks(subtitle: [SubtitleTrack('1', 'English', 'en')]),
      );
      media.trackController.add(
        const Track(subtitle: SubtitleTrack('1', 'English', 'en')),
      );
      await Future<void>.delayed(Duration.zero);

      expect(controller.notifications, notifications);
      expect(controller.position, Duration.zero);
      expect(controller.duration, Duration.zero);
      expect(controller.buffered, Duration.zero);
      expect(controller.isBuffering, isFalse);
      expect(controller.bufferingPercent, isNull);
      expect(controller.isPlaying, isFalse);
      expect(controller.isCompleted, isFalse);
      expect(controller.volume, 100);
      expect(controller.rate, 1);
      expect(controller.videoWidth, isNull);
      expect(controller.videoHeight, isNull);
      expect(controller.audioBitrate, isNull);
      expect(controller.lastEngineError, isNull);
      expect(controller.embeddedOptions, isEmpty);
      expect(controller.selectedSubtitle, isNull);
    },
  );

  test('a tracks notification disposing the controller prevents the next notification', () async {
    final fixture = _Fixture();
    fixture.controller.addListener(fixture.dispose);
    fixture.media.tracksController.add(
      const Tracks(subtitle: [SubtitleTrack('1', 'English', 'en')]),
    );
    await Future<void>.delayed(Duration.zero);

    expect(fixture.disposed, isTrue);
    expect(fixture.controller.notifications, 1);
  });

  test('volume completion after dispose does not notify', () async {
    final fixture = _Fixture();
    final pending = fixture.controller.setVolume(25);
    fixture.dispose();
    final notifications = fixture.controller.notifications;
    fixture.media.volumeGate.complete();
    await pending;

    expect(fixture.controller.notifications, notifications);
  });

  test(
    'subtitle completion after dispose does not notify or update selection',
    () async {
      final fixture = _Fixture();
      final pending = fixture.controller.selectSubtitle(SubtitleOption.off);
      fixture.dispose();
      final notifications = fixture.controller.notifications;
      fixture.media.subtitleGate.complete();

      expect(await pending, isTrue);
      expect(fixture.controller.notifications, notifications);
      expect(fixture.controller.selectedSubtitle, isNull);
      expect(fixture.controller.subtitleBusy, isTrue);
    },
  );

  test(
    'subtitle loading failure after dispose does not notify or write errors',
    () async {
      final subtitles = _SubtitleIO();
      final fixture = _Fixture(subtitleLoader: subtitles);
      final pending = fixture.controller.selectSubtitle(
        const SubtitleOption(
          id: 'external:0',
          label: 'English',
          kind: SubtitleSourceKind.external,
          url: 'https://fixture.test/subtitles.srt',
          format: 'srt',
        ),
      );
      fixture.dispose();
      final notifications = fixture.controller.notifications;
      subtitles.gate.completeError(StateError('subtitle load failed'));

      expect(await pending, isFalse);
      expect(fixture.controller.notifications, notifications);
      expect(fixture.controller.subtitleError, isNull);
      expect(fixture.controller.subtitleBusy, isTrue);
    },
  );

  test(
    'active open retains success state, diagnostics and notifications',
    () async {
      final fixture = _Fixture();
      fixture.media.openGate.complete();
      final outcome = await fixture.controller.open(
        _url,
        awaitFirstFrame: false,
      );

      expect(outcome.succeeded, isTrue);
      expect(fixture.controller.lastOutcome, same(outcome));
      expect(fixture.controller.isLoading, isFalse);
      expect(fixture.controller.duration, const Duration(seconds: 100));
      expect(fixture.controller.diagnostics, isNotNull);
      expect(fixture.controller.notifications, greaterThan(1));
    },
  );

  test('active open retains error classification and failure state', () async {
    final fixture = _Fixture();
    fixture.media.openError = StateError('404 missing episode');
    fixture.media.openGate.complete();
    final outcome = await fixture.controller.open(_url, awaitFirstFrame: false);

    expect(outcome.succeeded, isFalse);
    expect(outcome.failureKind, PlayerFailureKind.notFound);
    expect(fixture.controller.lastOutcome, same(outcome));
    expect(fixture.controller.isLoading, isFalse);
    expect(fixture.controller.diagnostics, isNotNull);
    expect(fixture.controller.notifications, 2);
  });
}
