import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/services/player_thumbnail_service.dart';

import 'support/player_navigation_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('disabled preview creates no engine or media request', () async {
    var creates = 0;
    final service = PlayerThumbnailService(
      sessionFactory: () {
        creates++;
        return ThumbnailIO();
      },
    );
    service.setMedia('https://fixture.test/video');
    expect(await service.thumbnailAt(const Duration(seconds: 1)), isNull);
    expect(creates, 0);
    await service.dispose();
  });

  test(
    'cache reuses a demand result and evicts the least recent of 32 images',
    () async {
      final io = ThumbnailIO();
      final service = PlayerThumbnailService(sessionFactory: () => io);
      service.setMedia('https://fixture.test/video');
      service.setEnabled(true);
      final first = await service.thumbnailAt(const Duration(seconds: 1));
      expect(first, [1, 2, 3]);
      expect(
        await service.thumbnailAt(const Duration(seconds: 1)),
        same(first),
      );
      for (var second = 2; second <= 32; second++) {
        await service.thumbnailAt(Duration(seconds: second));
      }
      await service.thumbnailAt(const Duration(seconds: 1));
      await service.thumbnailAt(const Duration(seconds: 33));
      await service.thumbnailAt(const Duration(seconds: 2));
      expect(io.targets.length, 34);
      await service.dispose();
      expect(io.releases, 1);
    },
  );

  test(
    'same URL with new immutable headers invalidates old extraction and cache',
    () async {
      final first = ThumbnailIO()..extractionGate = Completer();
      final second = ThumbnailIO();
      var creates = 0;
      final service = PlayerThumbnailService(
        sessionFactory: () => creates++ == 0 ? first : second,
      );
      final headers = {
        'Authorization': 'private-test-value',
        'Referer': 'https://fixture.test/',
      };
      service.setMedia('https://fixture.test/video', headers: headers);
      service.setEnabled(true);
      final pending = service.thumbnailAt(const Duration(seconds: 1));
      await Future<void>.delayed(Duration.zero);
      headers['Authorization'] = 'changed';
      expect(first.media!.httpHeaders!['Authorization'], 'private-test-value');
      expect(
        () => first.media!.httpHeaders!['Other'] = 'value',
        throwsUnsupportedError,
      );
      final oldGeneration = service.generation;
      service.setMedia(
        'https://fixture.test/video',
        headers: {'Authorization': 'new-private-value'},
      );
      expect(service.generation, greaterThan(oldGeneration));
      expect(await pending, isNull);
      final replacement = service.thumbnailAt(const Duration(seconds: 2));
      first.extractionGate!.complete(first.bytes);
      expect(await replacement, [1, 2, 3]);
      expect(second.media!.httpHeaders!['Authorization'], 'new-private-value');
      expect(first.releases, 1);
      await service.dispose();
      expect(second.releases, 1);
    },
  );

  test('one extraction is allowed; duplicate requests share it; disable discards result', () async {
    final io = ThumbnailIO()..extractionGate = Completer();
    final service = PlayerThumbnailService(sessionFactory: () => io);
    service.setMedia('https://fixture.test/video');
    service.setEnabled(true);
    final pending = service.thumbnailAt(const Duration(seconds: 1));
    final duplicate = service.thumbnailAt(const Duration(seconds: 1));
    final finalTarget = service.thumbnailAt(const Duration(seconds: 2));
    await Future<void>.delayed(Duration.zero);
    expect(io.targets, [const Duration(seconds: 1)]);
    service.setEnabled(false);
    expect(await pending, isNull);
    expect(await duplicate, isNull);
    expect(await finalTarget, isNull);
    io.extractionGate!.complete(io.bytes);
    await service.dispose();
    expect(io.releases, 1);
    expect(await service.thumbnailAt(const Duration(seconds: 1)), isNull);
  });

  test(
    'final target during opening is delivered without another hover request',
    () async {
      final io = ThumbnailIO()..openGate = Completer<void>();
      final service = PlayerThumbnailService(sessionFactory: () => io);
      service.setMedia('https://fixture.test/video');
      service.setEnabled(true);
      final first = service.thumbnailAt(const Duration(seconds: 1));
      await Future<void>.delayed(Duration.zero);
      final last = service.thumbnailAt(const Duration(seconds: 7));
      io.openGate!.complete();
      expect(await first, [1, 2, 3]);
      expect(await last, [7]);
      expect(io.targets, [
        const Duration(seconds: 1),
        const Duration(seconds: 7),
      ]);
      expect(io.maxActive, 1);
      await service.dispose();
    },
  );

  test(
    'only final coalesced request runs; intermediate requests complete safely',
    () async {
      final io = ThumbnailIO()..extractionGate = Completer<Uint8List?>();
      final service = PlayerThumbnailService(sessionFactory: () => io);
      service.setMedia('https://fixture.test/video');
      service.setEnabled(true);
      final first = service.thumbnailAt(const Duration(seconds: 1));
      await Future<void>.delayed(Duration.zero);
      final middle = service.thumbnailAt(const Duration(seconds: 4));
      final last = service.thumbnailAt(const Duration(seconds: 7));
      final duplicate = service.thumbnailAt(const Duration(seconds: 7));
      expect(await middle, isNull);
      io.extractionGate!.complete(io.bytes);
      expect(await first, [1, 2, 3]);
      expect(await last, [7]);
      expect(await duplicate, [7]);
      expect(io.targets, [
        const Duration(seconds: 1),
        const Duration(seconds: 7),
      ]);
      expect(io.maxActive, 1);
      await service.dispose();
    },
  );

  for (final mode in ['disable', 'media', 'dispose']) {
    test(
      'pending latest target is canceled on $mode including slow drain',
      () async {
        final io = ThumbnailIO()
          ..openGate = Completer<void>()
          ..disposalGate = Completer<void>();
        var creates = 0;
        final service = PlayerThumbnailService(
          sessionFactory: () {
            creates++;
            return io;
          },
        );
        service.setMedia('https://fixture.test/video');
        service.setEnabled(true);
        final first = service.thumbnailAt(const Duration(seconds: 1));
        await Future<void>.delayed(Duration.zero);
        final latest = service.thumbnailAt(const Duration(seconds: 7));
        if (mode == 'disable') service.setEnabled(false);
        if (mode == 'media') {
          service.setMedia('https://fixture.test/replacement');
        }
        if (mode == 'dispose') unawaited(service.dispose());
        expect(await first, isNull);
        expect(await latest, isNull);
        expect(creates, 1);
        io.openGate!.complete();
        io.disposalGate!.complete();
        await service.dispose();
        expect(io.releases, 1);
        expect(io.targets, isEmpty);
      },
    );
  }

  testWidgets(
    'pending deadline includes time queued behind a timed-out decoder',
    (tester) async {
      final io = ThumbnailIO()..openGate = Completer<void>();
      var creates = 0;
      final service = PlayerThumbnailService(
        sessionFactory: () {
          creates++;
          return io;
        },
      );
      service.setMedia('https://fixture.test/video');
      service.setEnabled(true);
      var firstDone = false;
      var lastDone = false;
      final first = service.thumbnailAt(const Duration(seconds: 1)).then((
        value,
      ) {
        firstDone = true;
        return value;
      });
      await tester.pump(const Duration(seconds: 1));
      final latest = service.thumbnailAt(const Duration(seconds: 7)).then((
        value,
      ) {
        lastDone = true;
        return value;
      });
      await tester.pump(const Duration(seconds: 4));
      expect(firstDone, isTrue);
      expect(lastDone, isFalse);
      await tester.pump(const Duration(seconds: 1));
      expect(lastDone, isTrue);
      expect(await first, isNull);
      expect(await latest, isNull);
      expect(creates, 1);
      io.openGate!.complete();
      await service.dispose();
    },
  );

  test('error returns null and releases the failed engine', () async {
    final io = ThumbnailIO()..error = StateError('decode failed');
    final service = PlayerThumbnailService(sessionFactory: () => io);
    service.setMedia('https://fixture.test/video');
    service.setEnabled(true);
    expect(await service.thumbnailAt(const Duration(seconds: 1)), isNull);
    await service.dispose();
    expect(io.releases, 1);
  });

  test('empty decoder output is not displayed or cached', () async {
    final io = ThumbnailIO()
      ..extractionGate = (Completer<Uint8List?>()..complete(Uint8List(0)));
    final service = PlayerThumbnailService(sessionFactory: () => io);
    service.setMedia('https://fixture.test/video');
    service.setEnabled(true);
    expect(await service.thumbnailAt(const Duration(seconds: 1)), isNull);
    await service.dispose();
    expect(io.releases, 1);
  });

  testWidgets(
    'even an oversized configured budget completes at five seconds and drains',
    (tester) async {
      final io = ThumbnailIO()..extractionGate = Completer();
      final service = PlayerThumbnailService(
        sessionFactory: () => io,
        extractionTimeout: const Duration(seconds: 30),
      );
      service.setMedia('https://fixture.test/video');
      service.setEnabled(true);
      var done = false;
      Uint8List? result;
      service.thumbnailAt(const Duration(seconds: 1)).then((value) {
        result = value;
        done = true;
      });
      await tester.pump(const Duration(milliseconds: 4999));
      expect(done, isFalse);
      await tester.pump(const Duration(milliseconds: 1));
      expect(done, isTrue);
      expect(result, isNull);
      final next = service.thumbnailAt(const Duration(seconds: 2));
      service.setEnabled(false);
      expect(await next, isNull);
      io.extractionGate!.complete(io.bytes);
      await service.dispose();
      expect(io.releases, 1);
    },
  );

  test(
    'decode error returns before slow disposal but keeps the concurrency slot',
    () async {
      final io = ThumbnailIO()
        ..error = StateError('decode failed')
        ..disposalGate = Completer();
      var creates = 0;
      final service = PlayerThumbnailService(
        sessionFactory: () {
          creates++;
          return io;
        },
      );
      service.setMedia('https://fixture.test/video');
      service.setEnabled(true);
      try {
        expect(
          await service
              .thumbnailAt(const Duration(seconds: 1))
              .timeout(const Duration(milliseconds: 100)),
          isNull,
        );
        final next = service.thumbnailAt(const Duration(seconds: 2));
        await Future<void>.delayed(Duration.zero);
        expect(creates, 1);
        service.setEnabled(false);
        expect(await next, isNull);
      } finally {
        io.disposalGate!.complete();
        await service.dispose();
      }
    },
  );

  test('timeout completes within budget but no new job starts before old job drains', () async {
    final io = ThumbnailIO()
      ..extractionGate = Completer()
      ..disposalGate = Completer();
    var creates = 0;
    final service = PlayerThumbnailService(
      sessionFactory: () {
        creates++;
        return io;
      },
      extractionTimeout: const Duration(milliseconds: 20),
    );
    service.setMedia('https://fixture.test/video');
    service.setEnabled(true);
    final watch = Stopwatch()..start();
    expect(await service.thumbnailAt(const Duration(seconds: 1)), isNull);
    expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
    expect(await service.thumbnailAt(const Duration(seconds: 2)), isNull);
    expect(creates, 1);
    io.extractionGate!.complete(io.bytes);
    await Future<void>.delayed(Duration.zero);
    expect(await service.thumbnailAt(const Duration(seconds: 2)), isNull);
    final disposal = service.dispose();
    io.disposalGate!.complete();
    await disposal;
    expect(io.releases, 1);
  });
}
