// ignore_for_file: invalid_use_of_protected_member

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:webhtv_pc/ui/player_controller.dart';

import 'support/player_navigation_fixture.dart';

class _ErrorEventIO extends NavigationNativeIO {
  @override
  Future<void> observeProperty(
    String property,
    Future<void> Function(String) listener, {
    bool waitForInitialization = true,
  }) async {}

  @override
  Future<void> unobserveProperty(
    String property, {
    bool waitForInitialization = true,
  }) async {}

  @override
  Future<void> setAudioTrack(
    AudioTrack track, {
    bool synchronized = true,
  }) async {
    throw StateError('track selection failed');
  }

  void error(String message) => media.errorController.add(message);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _ErrorEventIO io;
  late PlayerController controller;

  setUp(() {
    io = _ErrorEventIO();
    controller = PlayerController(player: Player(platformPlayer: io));
  });
  tearDown(() async {
    controller.dispose();
    await pumpEventQueue();
  });

  test(
    'each real error event has an identity even for identical text',
    () async {
      expect(controller.playbackErrorRevision, 0);
      expect(controller.playbackErrorMessage, isNull);
      final delivered = <(int, String?)>[];
      controller.addListener(() {
        delivered.add((
          controller.playbackErrorRevision,
          controller.playbackErrorMessage,
        ));
      });

      io.error('stream failed');
      await pumpEventQueue();
      io.error('stream failed');
      await pumpEventQueue();
      io.error('another failure');
      await pumpEventQueue();

      expect(delivered, [
        (1, 'stream failed'),
        (2, 'stream failed'),
        (3, 'another failure'),
      ]);
      expect(controller.lastEngineError, 'another failure');
    },
  );

  test(
    'position, buffering, and playing notifications are not error events',
    () async {
      io.error('stream failed');
      await pumpEventQueue();
      io.media.report(
        duration: const Duration(seconds: 100),
        position: const Duration(seconds: 2),
        playing: true,
      );
      io.media.bufferingController.add(true);
      await pumpEventQueue();
      io.media.bufferingController.add(false);
      await pumpEventQueue();

      expect(controller.playbackErrorRevision, 1);
      expect(controller.playbackErrorMessage, 'stream failed');
    },
  );

  test('operation errors preserve lastEngineError without pretending to be stream events', () async {
    expect(await controller.selectAudioTrack('auto'), isFalse);
    expect(controller.lastEngineError, contains('track selection failed'));
    expect(controller.playbackErrorRevision, 0);
    expect(controller.playbackErrorMessage, isNull);

    io.error('actual stream error');
    await pumpEventQueue();
    expect(await controller.selectAudioTrack('auto'), isFalse);
    expect(controller.lastEngineError, contains('track selection failed'));
    expect(controller.playbackErrorRevision, 1);
    expect(controller.playbackErrorMessage, 'actual stream error');
  });

  test(
    'open clears the stream message but revision remains monotonic',
    () async {
      io.error('stream failed');
      await pumpEventQueue();
      expect(controller.playbackErrorRevision, 1);

      final outcome = await controller.open(
        'https://example.test/video.mp4',
        awaitFirstFrame: false,
      );
      expect(outcome.succeeded, isTrue);
      expect(controller.playbackErrorMessage, isNull);
      expect(controller.lastEngineError, isNull);
      expect(controller.playbackErrorRevision, 1);

      io.error('stream failed');
      await pumpEventQueue();
      expect(controller.playbackErrorRevision, 2);
      expect(controller.playbackErrorMessage, 'stream failed');
    },
  );

  test('empty and whitespace events still advance engine identity', () async {
    io.error('');
    await pumpEventQueue();
    expect(controller.playbackErrorRevision, 1);
    expect(controller.playbackErrorMessage, '');
    io.error('  ');
    await pumpEventQueue();
    expect(controller.playbackErrorRevision, 2);
    expect(controller.playbackErrorMessage, '  ');
  });
}
