import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/home_hero_art.dart';
import 'package:webhtv_pc/ui/home_hero_image_probe.dart';

const _hd = HomeHeroArtEvidence(width: 1920, height: 1080);
const _url = 'https://images.invalid/t/p/w1280/hero.png';

class _TrackedCompleter extends OneFrameImageStreamCompleter {
  _TrackedCompleter(super.image);

  final listeners = <ImageStreamListener>{};

  @override
  void addListener(ImageStreamListener listener) {
    listeners.add(listener);
    super.addListener(listener);
  }

  @override
  void removeListener(ImageStreamListener listener) {
    listeners.remove(listener);
    super.removeListener(listener);
  }
}

Future<ui.Image> _decodedPng(int width, int height) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawColor(const ui.Color(0xff2478ac), ui.BlendMode.src);
  final picture = recorder.endRecording();
  final original = await picture.toImage(width, height);
  picture.dispose();
  final png = await original.toByteData(format: ui.ImageByteFormat.png);
  original.dispose();
  final codec = await ui.instantiateImageCodec(png!.buffer.asUint8List());
  final frame = await codec.getNextFrame();
  codec.dispose();
  return frame.image;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final cache = PaintingBinding.instance.imageCache;
  final handles = <ImageStreamCompleterHandle>[];
  final streams = <_TrackedCompleter>[];

  _TrackedCompleter prime(NetworkImage provider, Future<ImageInfo> image) {
    final completer = _TrackedCompleter(image);
    streams.add(completer);
    handles.add(completer.keepAlive());
    cache.putIfAbsent(provider, () => completer);
    return completer;
  }

  tearDown(() {
    cache.clear();
    cache.clearLiveImages();
    for (final handle in handles) {
      handle.dispose();
    }
    handles.clear();
    for (final stream in streams) {
      expect(stream.listeners, isEmpty, reason: 'no leaked image listeners');
    }
    streams.clear();
  });

  group('decoded first-frame evidence, never URL or metadata', () {
    for (final sample in [
      (1920, 1080, true),
      (1280, 720, true),
      (1279, 720, false),
      (241, 330, false),
      (1920, 400, false),
      (1280, 1280, false),
    ]) {
      testWidgets('real PNG ${sample.$1}x${sample.$2}: eligible=${sample.$3}', (
        tester,
      ) async {
        final pixels = await tester.runAsync(
          () => _decodedPng(sample.$1, sample.$2),
        );
        final provider = NetworkImage(_url, headers: const {'Referer': 'hero'});
        final stream = prime(provider, Future.value(ImageInfo(image: pixels!)));
        final probe = HomeHeroImageProbe();
        addTearDown(probe.dispose);
        final pending = probe.check(_url, headers: const {'Referer': 'hero'});
        await tester.pump();
        final evidence = await pending;
        expect(evidence, isNotNull);
        expect(evidence!.width, sample.$1);
        expect(evidence.height, sample.$2);
        expect(evidence.isEligible, sample.$3);
        expect(stream.listeners, isEmpty);
        expect(cache.statusForKey(provider).keepAlive, isTrue);
        expect(
          provider.resolve(ImageConfiguration.empty).completer,
          same(stream),
        );
      });
    }

    testWidgets('corrupt image bytes fail without an unhandled decode error', (
      tester,
    ) async {
      final image = Completer<ImageInfo>();
      final stream = prime(const NetworkImage(_url), image.future);
      final probe = HomeHeroImageProbe();
      addTearDown(probe.dispose);
      final pending = probe.check(_url);
      await tester.pump();
      await tester.runAsync(() async {
        try {
          final codec = await ui.instantiateImageCodec(
            Uint8List.fromList([1, 2, 3, 4]),
          );
          try {
            final frame = await codec.getNextFrame();
            image.complete(ImageInfo(image: frame.image));
          } finally {
            codec.dispose();
          }
        } catch (error, stack) {
          image.completeError(error, stack);
        }
      });
      await tester.pump();
      expect(await pending, isNull);
      expect(
        stream.listeners,
        hasLength(1),
        reason: 'only Flutter cache pending listener',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('already decoded synchronous image removes its listener', (
      tester,
    ) async {
      final pixels = await tester.runAsync(() => _decodedPng(1280, 720));
      final stream = prime(
        const NetworkImage(_url),
        Future.value(ImageInfo(image: pixels!)),
      );
      await tester.pump();
      final probe = HomeHeroImageProbe();
      addTearDown(probe.dispose);
      final pending = probe.check(_url);
      await tester.pump();
      expect((await pending)!.isEligible, isTrue);
      expect(stream.listeners, isEmpty);
    });
  });

  group('default stream lifecycle', () {
    testWidgets('timeout detaches listener and ignores late decode/error', (
      tester,
    ) async {
      final image = Completer<ImageInfo>();
      final provider = const NetworkImage(_url);
      final stream = prime(provider, image.future);
      final baseline = stream.listeners.length;
      final probe = HomeHeroImageProbe(timeout: const Duration(seconds: 2));
      addTearDown(probe.dispose);
      final pending = probe.check(_url);
      await tester.pump();
      expect(stream.listeners, hasLength(baseline + 1));
      await tester.pump(const Duration(seconds: 2));
      expect(await pending, isNull);
      expect(stream.listeners, hasLength(baseline));
      image.completeError(StateError('late decode failure'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(await probe.check(_url), isNull);
    });

    testWidgets('timeout ignores a late successful decoded frame', (
      tester,
    ) async {
      final pixels = await tester.runAsync(() => _decodedPng(1920, 1080));
      final image = Completer<ImageInfo>();
      final stream = prime(const NetworkImage(_url), image.future);
      final baseline = stream.listeners.length;
      final probe = HomeHeroImageProbe(timeout: const Duration(seconds: 1));
      addTearDown(probe.dispose);
      final pending = probe.check(_url);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(await pending, isNull);
      expect(stream.listeners, hasLength(baseline));
      image.complete(ImageInfo(image: pixels!));
      await tester.pump();
      expect(await probe.check(_url), isNull);
      expect(stream.listeners, isEmpty);
    });

    testWidgets('dispose completes pending checks and removes listener/timer', (
      tester,
    ) async {
      final image = Completer<ImageInfo>();
      final stream = prime(const NetworkImage(_url), image.future);
      final baseline = stream.listeners.length;
      final probe = HomeHeroImageProbe();
      final pending = probe.check(_url);
      await tester.pump();
      expect(stream.listeners, hasLength(baseline + 1));
      probe.dispose();
      expect(await pending, isNull);
      expect(stream.listeners, hasLength(baseline));
      expect(await probe.check(_url), isNull);
      image.completeError(StateError('late disposed decode failure'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      probe.dispose();
    });

    testWidgets('clear cancels old listener and permits a fresh check', (
      tester,
    ) async {
      final firstImage = Completer<ImageInfo>();
      final provider = const NetworkImage(_url);
      final firstStream = prime(provider, firstImage.future);
      final baseline = firstStream.listeners.length;
      final probe = HomeHeroImageProbe();
      addTearDown(probe.dispose);
      final old = probe.check(_url);
      await tester.pump();
      probe.clear();
      expect(await old, isNull);
      expect(firstStream.listeners, hasLength(baseline));
      cache.evict(provider);
      final pixels = await tester.runAsync(() => _decodedPng(1280, 720));
      final nextStream = prime(
        provider,
        Future.value(ImageInfo(image: pixels!)),
      );
      final fresh = probe.check(_url);
      await tester.pump();
      expect((await fresh)!.width, 1280);
      expect(nextStream.listeners, isEmpty);
      firstImage.completeError(StateError('obsolete decode failure'));
      await tester.pump();
      expect((await probe.check(_url))!.width, 1280);
      expect(tester.takeException(), isNull);
    });
  });

  group('bounded evidence cache and loader seam', () {
    test(
      'identical concurrent calls coalesce and reuse decoded evidence',
      () async {
        var calls = 0;
        final result = Completer<HomeHeroArtEvidence?>();
        final probe = HomeHeroImageProbe(
          loader: (provider, configuration) {
            calls++;
            return result.future;
          },
        );
        addTearDown(probe.dispose);
        final first = probe.check(_url);
        final second = probe.check(_url);
        result.complete(_hd);
        expect(await first, same(_hd));
        expect(await second, same(_hd));
        expect(await probe.check(_url), same(_hd));
        expect(calls, 1);
      },
    );

    test(
      'provider key includes immutable headers, independent of insertion order',
      () async {
        final providers = <NetworkImage>[];
        final probe = HomeHeroImageProbe(
          loader: (provider, configuration) async {
            providers.add(provider as NetworkImage);
            return HomeHeroArtEvidence(
              width: providers.length * 1280,
              height: 720,
            );
          },
        );
        addTearDown(probe.dispose);
        final headers = {'Referer': 'a', 'Cookie': 'one'};
        final first = probe.check(_url, headers: headers);
        headers['Referer'] = 'b';
        expect((await first)!.width, 1280);
        expect(providers.single.headers, {'Referer': 'a', 'Cookie': 'one'});
        expect(
          (await probe.check(
            _url,
            headers: {'Cookie': 'one', 'Referer': 'a'},
          ))!.width,
          1280,
        );
        expect((await probe.check(_url, headers: headers))!.width, 2560);
        expect(providers, hasLength(2));
        expect(
          providers.first,
          NetworkImage(_url, headers: const {'Referer': 'a', 'Cookie': 'one'}),
        );
      },
    );

    test('changed headers never coalesce in-flight checks', () async {
      final results = <String, Completer<HomeHeroArtEvidence?>>{};
      final probe = HomeHeroImageProbe(
        loader: (provider, configuration) {
          final key = (provider as NetworkImage).headers!['Referer']!;
          return (results[key] = Completer<HomeHeroArtEvidence?>()).future;
        },
      );
      addTearDown(probe.dispose);
      final first = probe.check(_url, headers: {'Referer': 'a'});
      final second = probe.check(_url, headers: {'Referer': 'b'});
      await Future<void>.value();
      expect(results.keys, unorderedEquals(['a', 'b']));
      results['a']!.complete(_hd);
      results['b']!.complete(
        const HomeHeroArtEvidence(width: 241, height: 330),
      );
      expect((await first)!.isEligible, isTrue);
      expect((await second)!.isEligible, isFalse);
    });

    test('null and empty headers use the same NetworkImage key', () async {
      var calls = 0;
      final probe = HomeHeroImageProbe(
        loader: (provider, configuration) async {
          calls++;
          expect((provider as NetworkImage).headers, isNull);
          return _hd;
        },
      );
      addTearDown(probe.dispose);
      await probe.check(_url, headers: {});
      await probe.check(_url);
      expect(calls, 1);
    });

    test('configuration reaches the loader unchanged', () async {
      const config = ImageConfiguration(
        devicePixelRatio: 2,
        size: ui.Size(800, 450),
      );
      final probe = HomeHeroImageProbe(
        loader: (provider, configuration) async {
          expect(configuration, same(config));
          expect(provider, const NetworkImage(_url));
          return _hd;
        },
      );
      addTearDown(probe.dispose);
      expect(await probe.check(_url, configuration: config), _hd);
    });

    test('cache evicts least recently used entry at maxEntries', () async {
      final loaded = <String>[];
      final probe = HomeHeroImageProbe(
        maxEntries: 2,
        loader: (provider, _) async {
          loaded.add((provider as NetworkImage).url);
          return _hd;
        },
      );
      addTearDown(probe.dispose);
      await probe.check('a');
      await probe.check('b');
      await probe.check('a');
      await probe.check('c');
      await probe.check('a');
      await probe.check('b');
      expect(loaded, ['a', 'b', 'c', 'b']);
    });

    test(
      'zero capacity disables stored evidence, not concurrent coalescing',
      () async {
        var calls = 0;
        final firstResult = Completer<HomeHeroArtEvidence?>();
        final probe = HomeHeroImageProbe(
          maxEntries: 0,
          loader: (_, _) {
            calls++;
            return calls == 1 ? firstResult.future : Future.value(_hd);
          },
        );
        addTearDown(probe.dispose);
        final first = probe.check(_url);
        final second = probe.check(_url);
        firstResult.complete(_hd);
        await Future.wait([first, second]);
        expect(calls, 1);
        await probe.check(_url);
        expect(calls, 2);
      },
    );

    test('null failures are cached and count against the capacity', () async {
      var calls = 0;
      final probe = HomeHeroImageProbe(
        maxEntries: 1,
        loader: (_, _) async {
          calls++;
          return null;
        },
      );
      addTearDown(probe.dispose);
      expect(await probe.check('a'), isNull);
      expect(await probe.check('a'), isNull);
      expect(calls, 1);
      await probe.check('b');
      await probe.check('a');
      expect(calls, 3);
    });

    test('synchronous and asynchronous loader errors become null', () async {
      for (final loader in <HomeHeroImageLoader>[
        (_, _) => throw StateError('sync'),
        (_, _) => Future.error(StateError('async')),
      ]) {
        final probe = HomeHeroImageProbe(loader: loader);
        expect(await probe.check(_url), isNull);
        probe.dispose();
      }
    });

    testWidgets(
      'custom loader timeout ignores late completion and late errors',
      (tester) async {
        for (final lateError in [false, true]) {
          final result = Completer<HomeHeroArtEvidence?>();
          final probe = HomeHeroImageProbe(
            timeout: const Duration(seconds: 1),
            loader: (_, _) => result.future,
          );
          addTearDown(probe.dispose);
          final pending = probe.check(_url);
          await tester.pump();
          await tester.pump(const Duration(seconds: 1));
          expect(await pending, isNull);
          if (lateError) {
            result.completeError(StateError('late'));
          } else {
            result.complete(_hd);
          }
          await tester.pump();
          expect(await probe.check(_url), isNull);
          expect(tester.takeException(), isNull);
        }
      },
    );

    test(
      'clear prevents an obsolete loader from overwriting newer evidence',
      () async {
        final results = <Completer<HomeHeroArtEvidence?>>[];
        final probe = HomeHeroImageProbe(
          loader: (_, _) {
            final result = Completer<HomeHeroArtEvidence?>();
            results.add(result);
            return result.future;
          },
        );
        addTearDown(probe.dispose);
        final obsolete = probe.check(_url);
        await Future<void>.value();
        probe.clear();
        expect(await obsolete, isNull);
        final fresh = probe.check(_url);
        await Future<void>.value();
        results[1].complete(
          const HomeHeroArtEvidence(width: 1280, height: 720),
        );
        expect((await fresh)!.width, 1280);
        results[0].complete(_hd);
        await Future<void>.value();
        expect((await probe.check(_url))!.width, 1280);
      },
    );

    test(
      'immediate clear and dispose invalidate pending cache writes',
      () async {
        final obsolete = Completer<HomeHeroArtEvidence?>();
        final fresh = Completer<HomeHeroArtEvidence?>();
        var calls = 0;
        final probe = HomeHeroImageProbe(
          loader: (_, _) {
            calls++;
            return calls == 1 ? obsolete.future : fresh.future;
          },
        );
        addTearDown(probe.dispose);
        final beforeClear = probe.check(_url);
        probe.clear();
        expect(await beforeClear, isNull);
        obsolete.complete(_hd);
        await Future<void>.value();
        final afterClear = probe.check(_url);
        fresh.complete(const HomeHeroArtEvidence(width: 1280, height: 720));
        expect((await afterClear)!.width, 1280);
        final beforeDispose = probe.check('another');
        probe.dispose();
        expect(await beforeDispose, isNull);
        expect(await probe.check(_url), isNull);
      },
    );

    testWidgets('dispose cancels a custom loader and ignores its late error', (
      tester,
    ) async {
      var calls = 0;
      final result = Completer<HomeHeroArtEvidence?>();
      final probe = HomeHeroImageProbe(
        loader: (_, _) {
          calls++;
          return result.future;
        },
      );
      final pending = probe.check(_url);
      await tester.pump();
      probe.dispose();
      expect(await pending, isNull);
      result.completeError(StateError('late'));
      await tester.pump();
      expect(await probe.check(_url), isNull);
      expect(calls, 1);
      expect(tester.takeException(), isNull);
    });
  });
}
