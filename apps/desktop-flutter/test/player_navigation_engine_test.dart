import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:webhtv_pc/core/player_options.dart';
import 'package:webhtv_pc/services/player_thumbnail_service.dart';
import 'package:webhtv_pc/ui/player_controller.dart';

import 'support/player_navigation_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('controller defaults to zero preview engines; ordinary seek never waits for extraction', () async {
    final media = NavigationMediaIO();
    final preview = ThumbnailIO()..extractionGate = Completer();
    var creates = 0;
    final seeks = <Duration>[];
    final service = PlayerThumbnailService(
      sessionFactory: () {
        creates++;
        return preview;
      },
    );
    final controller = PlayerController(
      player: Player(platformPlayer: media),
      thumbnailService: service,
      onSeek: seeks.add,
    );
    await controller.open('https://fixture.test/video', awaitFirstFrame: false);
    expect(await controller.thumbnailAt(const Duration(seconds: 4)), isNull);
    expect(creates, 0);
    controller.setThumbnailPreviewEnabled(true);
    final pending = controller.thumbnailAt(const Duration(seconds: 4));
    await Future<void>.delayed(Duration.zero);
    final seeking = controller.seek(const Duration(seconds: 20));
    expect(seeks, [const Duration(seconds: 20)]);
    await seeking.timeout(const Duration(milliseconds: 100));
    expect(media.state.position, const Duration(seconds: 20));
    controller.dispose();
    expect(await pending, isNull);
    preview.extractionGate!.complete(preview.bytes);
    await service.dispose();
    expect(preview.releases, 1);
  });

  test('options enable preview and every open replaces media generation and headers', () async {
    final media = NavigationMediaIO();
    final engines = <ThumbnailIO>[];
    final service = PlayerThumbnailService(
      sessionFactory: () {
        final io = ThumbnailIO();
        engines.add(io);
        return io;
      },
    );
    final controller = PlayerController(
      player: Player(platformPlayer: media),
      thumbnailService: service,
    );
    await controller.applyPlayerOptions(
      const PlayerOptions(showThumbnailPreview: true),
    );
    final headers = {'Authorization': 'fixture-secret'};
    await controller.open(
      'https://fixture.test/video',
      headers: headers,
      awaitFirstFrame: false,
    );
    headers['Authorization'] = 'changed';
    expect(media.media!.httpHeaders!['Authorization'], 'fixture-secret');
    expect(
      () => media.media!.httpHeaders!['Other'] = 'value',
      throwsUnsupportedError,
    );
    expect(await controller.thumbnailAt(const Duration(seconds: 5)), [1, 2, 3]);
    expect(
      engines.single.media!.httpHeaders!['Authorization'],
      'fixture-secret',
    );
    final generation = controller.thumbnailGeneration;
    await controller.open(
      'https://fixture.test/video',
      headers: {'Authorization': 'replacement-secret'},
      awaitFirstFrame: false,
    );
    expect(controller.thumbnailGeneration, greaterThan(generation));
    expect(await controller.thumbnailAt(const Duration(seconds: 5)), [1, 2, 3]);
    expect(
      engines.last.media!.httpHeaders!['Authorization'],
      'replacement-secret',
    );
    controller.dispose();
    await service.dispose();
    expect(engines.every((io) => io.releases == 1), isTrue);
  });

  test(
    'new media invalidates navigation suspended in a native property await',
    () async {
      final io = NavigationNativeIO();
      final calls = <Duration>[];
      final controller = PlayerController(
        player: Player(platformPlayer: io),
        onSeek: calls.add,
      );
      await controller.open(
        'https://fixture.test/first',
        awaitFirstFrame: false,
      );
      final gate = Completer<String>();
      io.propertyGates['seekable'] = gate;
      io.requested['seekable'] = Completer<void>();
      final navigation = controller.seekToKeyframe(forward: true);
      await io.requested['seekable']!.future;
      await controller.open(
        'https://fixture.test/replacement',
        awaitFirstFrame: false,
      );
      gate.complete('yes');
      expect(await navigation, isFalse);
      expect(io.commands, 0);
      expect(calls, isEmpty);
      controller.dispose();
    },
  );

  test(
    'navigation completed after media replacement never publishes old onSeek',
    () async {
      final io = NavigationNativeIO();
      final calls = <Duration>[];
      final controller = PlayerController(
        player: Player(platformPlayer: io),
        onSeek: calls.add,
      );
      await controller.open(
        'https://fixture.test/first',
        awaitFirstFrame: false,
      );
      final gate = Completer<String>();
      io.propertyGates['seeking'] = gate;
      io.requested['seeking'] = Completer<void>();
      final navigation = controller.seekToKeyframe(forward: true);
      await io.requested['seeking']!.future;
      expect(io.commands, 1);
      await controller.open(
        'https://fixture.test/replacement',
        awaitFirstFrame: false,
      );
      gate.complete('no');
      expect(await navigation, isFalse);
      expect(calls, isEmpty);
      expect(io.commands, 1);
      final ordinary = controller.seek(const Duration(seconds: 20));
      expect(calls, [const Duration(seconds: 20)]);
      await ordinary;
      controller.dispose();
    },
  );

  test(
    'unknown duration and non-native keyframes fail without seek or callback',
    () async {
      final media = NavigationMediaIO();
      final seeks = <Duration>[];
      var creates = 0;
      final service = PlayerThumbnailService(
        sessionFactory: () {
          creates++;
          return ThumbnailIO();
        },
      );
      final controller = PlayerController(
        player: Player(platformPlayer: media),
        thumbnailService: service,
        onSeek: seeks.add,
      );
      controller.setThumbnailPreviewEnabled(true);
      await controller.open(
        'https://fixture.test/video',
        awaitFirstFrame: false,
      );
      expect(await controller.seekToKeyframe(forward: true), isFalse);
      media.report(
        duration: Duration.zero,
        position: const Duration(seconds: 1),
      );
      await Future<void>.delayed(Duration.zero);
      expect(await controller.thumbnailAt(const Duration(seconds: 4)), isNull);
      expect(await controller.seekToKeyframe(forward: false), isFalse);
      expect(creates, 0);
      expect(seeks, isEmpty);
      expect(media.seeks, 0);
      controller.dispose();
      await service.dispose();
    },
  );
}
