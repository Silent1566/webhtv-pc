import 'dart:async';
import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/ui/player_overlay.dart';
import 'package:webhtv_pc/ui/theme.dart';

final previewPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
);
const previewCard = ValueKey('player-thumbnail-preview');

class MeasuredTrack extends RoundedRectSliderTrackShape {
  Rect? globalRect;
  @override
  Rect getPreferredRect({
    required RenderBox parentBox,
    Offset offset = Offset.zero,
    required SliderThemeData sliderTheme,
    bool isEnabled = false,
    bool isDiscrete = false,
  }) {
    final rect = super.getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    globalRect = rect.shift(parentBox.localToGlobal(Offset.zero) - offset);
    return rect;
  }
}

Future<MeasuredTrack> mount(
  WidgetTester tester, {
  bool enabled = true,
  Duration duration = const Duration(seconds: 100),
  Future<Uint8List?> Function(Duration)? provider,
  Object source = 1,
  double width = 400,
  bool rtl = false,
  ValueChanged<Duration>? seek,
  MeasuredTrack? track,
}) async {
  final measured = track ?? MeasuredTrack();
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(Brightness.dark),
      home: Scaffold(
        body: Directionality(
          textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
          child: Align(
            alignment: Alignment.bottomCenter,
            child: SizedBox(
              width: width,
              height: 32,
              child: SliderTheme(
                data: buildAppTheme(Brightness.dark).sliderTheme.copyWith(
                  trackShape: measured,
                  padding: const EdgeInsets.symmetric(horizontal: 36),
                ),
                child: PlayerProgressSlider(
                  position: const Duration(seconds: 25),
                  duration: duration,
                  buffered: const Duration(seconds: 75),
                  onSeek: seek ?? (_) {},
                  thumbnailPreviewEnabled: enabled,
                  thumbnailProvider: provider,
                  previewSourceKey: source,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return measured;
}

Future<TestGesture> hover(WidgetTester tester, Offset point) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: Offset.zero);
  await mouse.moveTo(point);
  await tester.pump();
  return mouse;
}

Future<void> finish(WidgetTester tester, [TestGesture? mouse]) async {
  await mouse?.removePointer();
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(milliseconds: 300));
  expect(tester.takeException(), isNull);
}

void main() {
  testWidgets('default constructor never requests a preview', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlayerProgressSlider(
            position: Duration.zero,
            duration: const Duration(seconds: 100),
            buffered: Duration.zero,
            onSeek: (_) {},
          ),
        ),
      ),
    );
    final slider = tester.widget<PlayerProgressSlider>(
      find.byType(PlayerProgressSlider),
    );
    expect(slider.thumbnailPreviewEnabled, isFalse);
    final mouse = await hover(tester, tester.getCenter(find.byType(Slider)));
    await tester.pump(const Duration(seconds: 1));
    expect(find.byKey(previewCard), findsNothing);
    await finish(tester, mouse);
  });

  testWidgets(
    'hover uses Material trackRect including padding and 200ms debounce',
    (tester) async {
      final targets = <Duration>[];
      final track = await mount(
        tester,
        provider: (target) async {
          targets.add(target);
          return previewPng;
        },
      );
      final rect = track.globalRect!;
      final mouse = await hover(
        tester,
        Offset(rect.left + rect.width * .25, rect.center.dy),
      );
      expect(find.text('加载中…'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 199));
      expect(targets, isEmpty);
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pumpAndSettle();
      expect(targets, [const Duration(seconds: 25)]);
      expect(find.byType(Image), findsOneWidget);
      expect(find.text('00:25'), findsOneWidget);
      expect(tester.getSize(find.byType(PlayerProgressSlider)).height, 32);
      final card = tester.getRect(find.byKey(previewCard));
      expect(card.bottom, lessThan(tester.getRect(find.byType(Slider)).top));
      final ignore = tester.widget<IgnorePointer>(
        find
            .ancestor(
              of: find.byKey(previewCard),
              matching: find.byType(IgnorePointer),
            )
            .first,
      );
      expect(ignore.ignoring, isTrue);
      await finish(tester, mouse);
    },
  );

  testWidgets('rapid hover is debounced and only newest request may paint', (
    tester,
  ) async {
    final requests = <Completer<Uint8List?>>[];
    final targets = <Duration>[];
    final track = await mount(
      tester,
      provider: (target) {
        targets.add(target);
        final c = Completer<Uint8List?>();
        requests.add(c);
        return c.future;
      },
    );
    final rect = track.globalRect!;
    final mouse = await hover(tester, Offset(rect.left, rect.center.dy));
    await tester.pump(const Duration(milliseconds: 100));
    await mouse.moveTo(rect.center);
    await tester.pump(const Duration(milliseconds: 200));
    expect(targets, [const Duration(seconds: 50)]);
    await mouse.moveTo(Offset(rect.right, rect.center.dy));
    await tester.pump(const Duration(milliseconds: 200));
    expect(targets.last, const Duration(seconds: 100));
    requests.first.complete(previewPng);
    await tester.pump();
    expect(find.byType(Image), findsNothing);
    requests.last.complete(null);
    await tester.pumpAndSettle();
    expect(find.text('预览不可用'), findsOneWidget);
    expect(find.text('01:40'), findsOneWidget);
    await finish(tester, mouse);
  });

  testWidgets(
    'drag continuously emits seek without awaiting thumbnail and restores buffer',
    (tester) async {
      final seeks = <Duration>[];
      final pending = Completer<Uint8List?>();
      final track = await mount(
        tester,
        provider: (_) => pending.future,
        seek: seeks.add,
      );
      final rect = track.globalRect!;
      final drag = await tester.startGesture(
        Offset(rect.left + rect.width * .25, rect.center.dy),
      );
      await drag.moveTo(rect.center);
      await tester.pump(const Duration(milliseconds: 200));
      final count = seeks.length;
      expect(count, greaterThan(0));
      expect(
        tester.widget<Slider>(find.byType(Slider)).secondaryTrackValue,
        isNull,
      );
      await drag.moveTo(Offset(rect.left + rect.width * .7, rect.center.dy));
      expect(seeks.length, greaterThan(count));
      expect(find.byKey(previewCard), findsOneWidget);
      await drag.up();
      await tester.pump();
      expect(find.byKey(previewCard), findsNothing);
      expect(
        tester.widget<Slider>(find.byType(Slider)).secondaryTrackValue,
        75000,
      );
      pending.complete(previewPng);
      await finish(tester);
    },
  );

  for (final invalidation in [
    'exit',
    'disable',
    'source',
    'duration',
    'provider',
    'dispose',
  ]) {
    testWidgets('late results are ignored after $invalidation', (tester) async {
      final pending = Completer<Uint8List?>();
      Future<Uint8List?> provider(Duration _) => pending.future;
      final track = await mount(tester, provider: provider);
      final mouse = await hover(tester, track.globalRect!.center);
      await tester.pump(const Duration(milliseconds: 200));
      if (invalidation == 'exit') {
        await mouse.moveTo(Offset.zero);
        await tester.pump();
      } else if (invalidation == 'dispose') {
        await tester.pumpWidget(const SizedBox());
      } else {
        await mount(
          tester,
          provider: invalidation == 'provider' ? null : provider,
          enabled: invalidation != 'disable',
          source: invalidation == 'source' ? 2 : 1,
          duration: invalidation == 'duration'
              ? Duration.zero
              : const Duration(seconds: 100),
          track: track,
        );
      }
      expect(find.byKey(previewCard), findsNothing);
      pending.complete(previewPng);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(Image), findsNothing);
      await finish(tester, mouse);
    });
  }

  for (final failure in ['null', 'throw', 'sync throw', 'bad image']) {
    testWidgets('$failure has bounded error feedback and no exception', (
      tester,
    ) async {
      final track = await mount(
        tester,
        provider: (_) {
          if (failure == 'sync throw') throw StateError('thumbnail failed');
          if (failure == 'throw') {
            return Future.error(StateError('thumbnail failed'));
          }
          return Future.value(
            failure == 'bad image' ? Uint8List.fromList([1, 2, 3]) : null,
          );
        },
      );
      final mouse = await hover(tester, track.globalRect!.center);
      final size = tester.getSize(find.byKey(previewCard));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
      expect(find.text('预览不可用'), findsOneWidget);
      expect(tester.getSize(find.byKey(previewCard)), size);
      await finish(tester, mouse);
    });
  }

  testWidgets('unknown duration and explicit live disable never request', (
    tester,
  ) async {
    var calls = 0;
    for (final duration in [
      Duration.zero,
      const Duration(seconds: -1),
      const Duration(seconds: 100),
    ]) {
      final track = await mount(
        tester,
        enabled: duration.inSeconds != 100,
        duration: duration,
        provider: (_) async {
          calls++;
          return null;
        },
      );
      final mouse = await hover(tester, track.globalRect!.center);
      await tester.pump(const Duration(seconds: 1));
      expect(calls, 0);
      expect(find.byKey(previewCard), findsNothing);
      await finish(tester, mouse);
    }
  });

  for (final width in [400.0, 120.0]) {
    testWidgets(
      'both track ends clamp to duration and viewport at width $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 360);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final targets = <Duration>[];
        final track = await mount(
          tester,
          width: width,
          provider: (target) async {
            targets.add(target);
            return null;
          },
        );
        final rect = track.globalRect!;
        final mouse = await hover(tester, Offset(1, rect.center.dy));
        await tester.pump(const Duration(milliseconds: 200));
        expect(targets.last, Duration.zero);
        var card = tester.getRect(find.byKey(previewCard));
        expect(card.left, greaterThanOrEqualTo(0));
        expect(card.right, lessThanOrEqualTo(width));
        await mouse.moveTo(Offset(width - 1, rect.center.dy));
        await tester.pump(const Duration(milliseconds: 200));
        expect(targets.last, const Duration(seconds: 100));
        card = tester.getRect(find.byKey(previewCard));
        expect(card.left, greaterThanOrEqualTo(0));
        expect(card.right, lessThanOrEqualTo(width));
        await finish(tester, mouse);
      },
    );
  }

  testWidgets('RTL hover follows Slider direction', (tester) async {
    Duration? target;
    final track = await mount(
      tester,
      rtl: true,
      provider: (next) async {
        target = next;
        return null;
      },
    );
    final rect = track.globalRect!;
    final mouse = await hover(
      tester,
      Offset(rect.left + rect.width * .25, rect.center.dy),
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(target, const Duration(seconds: 75));
    await finish(tester, mouse);
  });

  testWidgets('keyboard seek keeps buffer and never requests thumbnails', (
    tester,
  ) async {
    var calls = 0;
    final seeks = <Duration>[];
    await mount(
      tester,
      provider: (_) async {
        calls++;
        return null;
      },
      seek: seeks.add,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump(const Duration(seconds: 1));
    expect(seeks, isNotEmpty);
    expect(
      tester.widget<Slider>(find.byType(Slider)).secondaryTrackValue,
      75000,
    );
    expect(calls, 0);
    expect(find.byKey(previewCard), findsNothing);
    await finish(tester);
  });

  testWidgets('dispose cancels pending debounce timer', (tester) async {
    var calls = 0;
    final track = await mount(
      tester,
      provider: (_) async {
        calls++;
        return null;
      },
    );
    final mouse = await hover(tester, track.globalRect!.center);
    await finish(tester, mouse);
    expect(calls, 0);
  });
}
