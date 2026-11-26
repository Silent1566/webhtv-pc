import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/skip_plan.dart';
import 'package:webhtv_pc/core/skip_segment_colors.dart';
import 'package:webhtv_pc/ui/player_overlay.dart';
import 'package:webhtv_pc/ui/theme.dart';

import 'player_navigation_preview_test.dart' show MeasuredTrack;

const captureKey = ValueKey('timeline-raster');
const segmentCard = ValueKey('player-skip-segment-preview');
SkipSegment segment(SkipKind kind, int start, int end, {bool open = false}) =>
    SkipSegment(
      kind: kind,
      provider: 'fixture',
      identity: '$kind-$start-$end',
      startMs: start,
      endMs: end,
      openEnded: open,
    );

Future<MeasuredTrack> mount(
  WidgetTester tester, {
  List<SkipSegment> segments = const [],
  Duration duration = const Duration(seconds: 100),
  Duration position = const Duration(seconds: 5),
  Duration buffered = const Duration(seconds: 75),
  bool rtl = false,
  Brightness brightness = Brightness.dark,
  bool preview = false,
  bool showHighlights = true,
  SkipSegmentColors colors = const SkipSegmentColors(),
  Color? playedColor,
  ValueChanged<Duration>? onSeek,
  VoidCallback? onStart,
  VoidCallback? onEnd,
}) async {
  final measured = MeasuredTrack();
  final base = buildAppTheme(brightness);
  final theme = base.copyWith(
    sliderTheme: base.sliderTheme.copyWith(activeTrackColor: playedColor),
  );
  final slider = PlayerProgressSlider(
    position: position,
    duration: duration,
    buffered: buffered,
    skipSegments: segments,
    skipSegmentColors: colors,
    showSkipSegmentHighlights: showHighlights,
    onSeek: onSeek ?? (_) {},
    onSeekStart: onStart,
    onSeekEnd: onEnd,
    thumbnailPreviewEnabled: preview,
    thumbnailProvider: preview ? (_) async => null : null,
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: RepaintBoundary(
        key: captureKey,
        child: Scaffold(
          body: Directionality(
            textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
            child: Center(
              child: SizedBox(
                width: 600,
                height: 32,
                child: SliderTheme(
                  data: theme.sliderTheme.copyWith(
                    trackShape: measured,
                    padding: const EdgeInsets.symmetric(horizontal: 36),
                  ),
                  child: slider,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return measured;
}

Offset at(Rect rect, double fraction, {bool rtl = false}) => Offset(
  rect.left + rect.width * (rtl ? 1 - fraction : fraction),
  rect.center.dy,
);

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

Future<({ByteData data, int width})> raster(
  WidgetTester tester, {
  double pixelRatio = 1,
}) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(captureKey),
  );
  return (await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: pixelRatio);
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final width = image.width;
    image.dispose();
    return (data: data!, width: width);
  }))!;
}

int pixel(({ByteData data, int width}) image, int x, int y) {
  final i = (y * image.width + x) * 4;
  return (image.data.getUint8(i + 3) << 24) |
      (image.data.getUint8(i) << 16) |
      (image.data.getUint8(i + 1) << 8) |
      image.data.getUint8(i + 2);
}

bool hasColorAt(({ByteData data, int width}) image, Offset point, int color) =>
    [
      for (var y = point.dy.floor() - 8; y <= point.dy.ceil() + 8; y++)
        pixel(image, point.dx.round(), y),
    ].contains(color);

double bandContrast(
  ({ByteData data, int width}) image,
  Offset point,
  Rect rect,
  int background,
) {
  final luminance = Color(background).computeLuminance();
  var strongest = 1.0;
  for (var x = point.dx.floor() - 1; x <= point.dx.ceil(); x++) {
    for (var y = rect.top.ceil(); y < rect.bottom.floor(); y++) {
      final sample = Color(pixel(image, x, y)).computeLuminance();
      final contrast = sample > luminance
          ? (sample + .05) / (luminance + .05)
          : (luminance + .05) / (sample + .05);
      if (contrast > strongest) strongest = contrast;
    }
  }
  return strongest;
}

void main() {
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 1.25, 1.5, 2.0]) {
      for (final rtl in [false, true]) {
        testWidgets('segment antialiased edges never inherit played color '
            '$brightness scale=$scale rtl=$rtl', (tester) async {
          // The segment is entirely played; changing the hidden base must not
          // change either its fill or its antialiased edge.
          const playhead = Duration(seconds: 50);
          final track = await mount(
            tester,
            position: playhead,
            brightness: brightness,
            rtl: rtl,
            segments: [segment(SkipKind.intro, 10000, 30000)],
          );
          final before = await raster(tester, pixelRatio: scale);
          final rect = track.globalRect!;
          await mount(
            tester,
            position: playhead,
            brightness: brightness,
            rtl: rtl,
            playedColor: const Color(0xFFFF00FF),
            segments: [segment(SkipKind.intro, 10000, 30000)],
          );
          final after = await raster(tester, pixelRatio: scale);
          final x = (at(rect, .2, rtl: rtl).dx * scale).round();
          for (
            var y = (rect.top * scale).floor() - 1;
            y <= (rect.bottom * scale).ceil();
            y++
          ) {
            expect(
              pixel(after, x, y),
              pixel(before, x, y),
              reason:
                  'changing hidden played color must not tint segment edge y=$y',
            );
          }
          await finish(tester);
        });
      }
    }
  }

  testWidgets(
    'segment edges do not inherit buffered color when buffer reaches them',
    (tester) async {
      final track = await mount(
        tester,
        buffered: const Duration(seconds: 9),
        segments: [segment(SkipKind.intro, 10000, 30000)],
      );
      final rect0 = track.globalRect!;
      final before = await raster(tester, pixelRatio: 1.25);
      expect(
        pixel(
          before,
          (at(rect0, .2).dx * 1.25).round(),
          (rect0.center.dy * 1.25).round(),
        ),
        const SkipSegmentColors().intro,
        reason: 'short buffer must not change the marker fill itself',
      );
      final rect = track.globalRect!;
      await mount(tester, segments: [segment(SkipKind.intro, 10000, 30000)]);
      final after = await raster(tester, pixelRatio: 1.25);
      final x = (at(rect, .2).dx * 1.25).round();
      final tertiary = buildAppTheme(Brightness.dark).colorScheme.tertiary
          .toARGB32();
      for (
        var y = (rect.top * 1.25).floor() - 1;
        y <= (rect.bottom * 1.25).ceil();
        y++
      ) {
        expect(
          pixel(after, x, y),
          isNot(tertiary),
          reason: 'buffer color must never show inside a marked interval y=$y',
        );
      }
      expect([
        for (
          var y = (rect.top * 1.25).ceil();
          y < (rect.bottom * 1.25).floor();
          y++
        )
          pixel(after, x, y),
      ], everyElement(const SkipSegmentColors().intro));
      await finish(tester);
    },
  );

  for (final brightness in Brightness.values) {
    for (final rtl in [false, true]) {
      for (final position in [5, 15, 50]) {
        testWidgets(
          'single-color priority remains uniform before during after segment '
          '$brightness rtl=$rtl position=$position',
          (tester) async {
            final track = await mount(
              tester,
              position: Duration(seconds: position),
              brightness: brightness,
              rtl: rtl,
              segments: [segment(SkipKind.intro, 10000, 30000)],
            );
            final image = await raster(tester);
            final rect = track.globalRect!;
            final backgroundX = at(rect, .9, rtl: rtl).dx.round();
            for (final fraction in [.12, .25]) {
              final x = at(rect, fraction, rtl: rtl).dx.round();
              for (var y = rect.top.ceil(); y < rect.bottom.floor(); y++) {
                expect(
                  pixel(image, x, y),
                  const SkipSegmentColors().intro,
                  reason:
                      'segment color must outrank played and buffered colors',
                );
              }
              for (final y in [rect.top.floor() - 1, rect.bottom.ceil()]) {
                expect(
                  pixel(image, x, y),
                  pixel(image, backgroundX, y),
                  reason: 'no amber fringe outside the unified native track',
                );
              }
            }
            await finish(tester);
          },
        );
      }
    }
  }

  testWidgets(
    'hidden highlights preserve native played track after a skipped segment',
    (tester) async {
      await mount(tester, position: const Duration(seconds: 50));
      final native = await raster(tester);
      await mount(
        tester,
        position: const Duration(seconds: 50),
        showHighlights: false,
        segments: [segment(SkipKind.intro, 10000, 30000)],
      );
      final hidden = await raster(tester);
      expect(
        hidden.data.buffer.asUint8List(),
        orderedEquals(native.data.buffer.asUint8List()),
      );
      await finish(tester);
    },
  );

  testWidgets(
    'all seven kinds paint on track center and retain buffer outside ranges',
    (tester) async {
      final segments = [
        for (var i = 0; i < SkipKind.values.length; i++)
          segment(SkipKind.values[i], 10000 + i * 12000, 17000 + i * 12000),
      ];
      final track = await mount(tester, segments: segments);
      final rect = track.globalRect!;
      final image = await raster(tester);
      const colors = SkipSegmentColors();
      expect(SkipKind.values.map(colors.colorFor).toSet(), hasLength(7));
      for (var i = 0; i < segments.length; i++) {
        final color = colors.colorFor(segments[i].kind);
        expect(
          pixel(
            image,
            at(rect, (13500 + i * 12000) / 100000).dx.round(),
            rect.center.dy.floor(),
          ),
          color,
          reason: 'visible ${segments[i].kind}',
        );
        expect(
          hasColorAt(image, at(rect, (9000 + i * 12000) / 100000), color),
          isFalse,
        );
        expect(
          hasColorAt(image, at(rect, (18000 + i * 12000) / 100000), color),
          isFalse,
        );
      }
      final buffer = buildAppTheme(Brightness.dark).colorScheme.tertiary
          .toARGB32();
      expect(
        pixel(image, at(rect, .45).dx.round(), rect.center.dy.floor()),
        buffer,
      );
      expect(tester.getSize(find.byType(PlayerProgressSlider)).height, 32);
      await finish(tester);
    },
  );

  for (final kind in SkipKind.values) {
    testWidgets('hover ${kind.name} shows name and range without thumbnails', (
      tester,
    ) async {
      final track = await mount(
        tester,
        segments: [segment(kind, 10000, 20000)],
      );
      final mouse = await hover(tester, at(track.globalRect!, .15));
      expect(find.byKey(segmentCard), findsOneWidget);
      expect(find.text('${kind.label}  00:10–00:20'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('player-thumbnail-preview')),
        findsNothing,
      );
      await mouse.moveTo(at(track.globalRect!, .4));
      await tester.pump();
      expect(find.byKey(segmentCard), findsNothing);
      await finish(tester, mouse);
    });
  }

  testWidgets('custom colors paint immediately without changing other kinds', (
    tester,
  ) async {
    final colors = const SkipSegmentColors().withColor(
      SkipKind.intro,
      0xFF1234CD,
    );
    final track = await mount(
      tester,
      segments: [segment(SkipKind.intro, 10000, 20000)],
      colors: colors,
    );
    final image = await raster(tester);
    expect(hasColorAt(image, at(track.globalRect!, .15), 0xFF1234CD), isTrue);
    await finish(tester);
  });

  testWidgets(
    'clamps negative start and overrun end and resolves open-ended duration',
    (tester) async {
      final track = await mount(
        tester,
        segments: [
          segment(SkipKind.recap, -10000, 20000),
          segment(SkipKind.outro, 80000, 150000),
          segment(SkipKind.postCredits, 90000, 0, open: true),
        ],
      );
      final mouse = await hover(tester, at(track.globalRect!, .1));
      expect(find.text('回顾  00:00–00:20'), findsOneWidget);
      await mouse.moveTo(at(track.globalRect!, .85));
      await tester.pump();
      expect(find.text('片尾  01:20–01:40'), findsOneWidget);
      await mouse.moveTo(at(track.globalRect!, 1));
      await tester.pump();
      expect(find.text('片尾  01:20–01:40'), findsOneWidget);
      expect(find.text('彩蛋  01:30–01:40'), findsOneWidget);
      await finish(tester, mouse);
    },
  );

  testWidgets('invalid or inverted intervals paint nothing', (tester) async {
    await mount(tester);
    final before = await raster(tester);
    final track = await mount(
      tester,
      segments: [
        segment(SkipKind.intro, 50000, 20000),
        segment(SkipKind.intro, 20000, 20000),
        segment(SkipKind.intro, -20000, -10000),
        segment(SkipKind.intro, 100000, 120000),
      ],
    );
    final after = await raster(tester);
    expect(
      after.data.buffer.asUint8List(),
      orderedEquals(before.data.buffer.asUint8List()),
    );
    final mouse = await hover(tester, at(track.globalRect!, .3));
    expect(find.byKey(segmentCard), findsNothing);
    await finish(tester, mouse);
  });

  for (final duration in [Duration.zero, const Duration(seconds: -1)]) {
    testWidgets('nonpositive duration $duration paints no markers or hover', (
      tester,
    ) async {
      final track = await mount(
        tester,
        duration: duration,
        segments: [segment(SkipKind.intro, 0, 10000)],
      );
      final image = await raster(tester);
      expect(
        hasColorAt(
          image,
          at(track.globalRect!, .5),
          const SkipSegmentColors().intro,
        ),
        isFalse,
      );
      final mouse = await hover(tester, at(track.globalRect!, .5));
      expect(find.byKey(segmentCard), findsNothing);
      expect(tester.widget<Slider>(find.byType(Slider)).onChanged, isNull);
      await finish(tester, mouse);
    });
  }

  testWidgets(
    'overlap hover reports every matching kind and no adjacent interval',
    (tester) async {
      final track = await mount(
        tester,
        segments: [
          segment(SkipKind.intro, 10000, 30000),
          segment(SkipKind.advertisement, 20000, 40000),
          segment(SkipKind.preview, 40000, 50000),
        ],
      );
      final mouse = await hover(tester, at(track.globalRect!, .25));
      expect(find.text('片头  00:10–00:30'), findsOneWidget);
      expect(find.text('广告  00:20–00:40'), findsOneWidget);
      expect(find.text('预告  00:40–00:50'), findsNothing);
      await mouse.moveTo(at(track.globalRect!, .4));
      await tester.pump();
      expect(find.text('广告  00:20–00:40'), findsNothing);
      expect(find.text('预告  00:40–00:50'), findsOneWidget);
      await finish(tester, mouse);
    },
  );

  testWidgets('RTL marker and hover use actual padded native track', (
    tester,
  ) async {
    final track = await mount(
      tester,
      rtl: true,
      segments: [segment(SkipKind.intro, 10000, 20000)],
    );
    final image = await raster(tester);
    final color = const SkipSegmentColors().intro;
    expect(
      hasColorAt(image, at(track.globalRect!, .15, rtl: true), color),
      isTrue,
    );
    expect(hasColorAt(image, at(track.globalRect!, .15), color), isFalse);
    final mouse = await hover(tester, at(track.globalRect!, .15, rtl: true));
    expect(find.text('片头  00:10–00:20'), findsOneWidget);
    await finish(tester, mouse);
  });

  testWidgets('segment hover coexists with enabled thumbnail preview', (
    tester,
  ) async {
    final track = await mount(
      tester,
      preview: true,
      segments: [segment(SkipKind.intro, 10000, 20000)],
    );
    final mouse = await hover(tester, at(track.globalRect!, .15));
    await tester.pump(const Duration(milliseconds: 250));
    expect(
      find.byKey(const ValueKey('player-thumbnail-preview')),
      findsOneWidget,
    );
    expect(find.text('00:15'), findsOneWidget);
    expect(find.text('片头  00:10–00:20'), findsOneWidget);
    expect(find.text('预览不可用'), findsOneWidget);
    await finish(tester, mouse);
  });

  testWidgets(
    'markers do not intercept drag and buffer returns after release',
    (tester) async {
      final seeks = <Duration>[];
      var starts = 0;
      var ends = 0;
      final track = await mount(
        tester,
        segments: [segment(SkipKind.intro, 10000, 20000)],
        onSeek: seeks.add,
        onStart: () => starts++,
        onEnd: () => ends++,
      );
      final gesture = await tester.startGesture(at(track.globalRect!, .15));
      await gesture.moveTo(at(track.globalRect!, .6));
      await tester.pump();
      expect(
        tester.widget<Slider>(find.byType(Slider)).secondaryTrackValue,
        isNull,
      );
      await gesture.up();
      await tester.pumpAndSettle();
      expect(starts, 1);
      expect(ends, 1);
      expect(seeks.last.inMilliseconds, closeTo(60000, 200));
      expect(
        tester.widget<Slider>(find.byType(Slider)).secondaryTrackValue,
        75000,
      );
      expect(find.byKey(segmentCard), findsNothing);
      await finish(tester);
    },
  );
  for (final brightness in Brightness.values) {
    testWidgets(
      'low contrast custom RGB retains a visible boundary $brightness',
      (tester) async {
        final background = buildAppTheme(brightness).colorScheme.surface
            .toARGB32();
        final colors = const SkipSegmentColors().withColor(
          SkipKind.intro,
          background,
        );
        final track = await mount(
          tester,
          brightness: brightness,
          colors: colors,
          segments: [segment(SkipKind.intro, 10000, 20000)],
        );
        final image = await raster(tester);
        final center = at(track.globalRect!, .15);
        expect(
          bandContrast(
            image,
            at(track.globalRect!, .10) + const Offset(1, 0),
            track.globalRect!,
            background,
          ),
          greaterThanOrEqualTo(3),
          reason: 'boundary must remain visible even when fill matches surface',
        );
        expect(
          pixel(image, center.dx.round(), track.globalRect!.center.dy.floor()),
          background,
          reason: 'must preserve the chosen RGB',
        );
        await finish(tester);
      },
    );
  }
  testWidgets(
    'light default seven colors retain fill RGB with contrast boundaries',
    (tester) async {
      final segments = [
        for (var i = 0; i < SkipKind.values.length; i++)
          segment(SkipKind.values[i], 10000 + i * 12000, 17000 + i * 12000),
      ];
      final track = await mount(
        tester,
        brightness: Brightness.light,
        segments: segments,
      );
      final image = await raster(tester);
      final background = buildAppTheme(Brightness.light).colorScheme.surface
          .toARGB32();
      for (var i = 0; i < segments.length; i++) {
        final point = at(track.globalRect!, (13500 + i * 12000) / 100000);
        expect(
          hasColorAt(
            image,
            point,
            const SkipSegmentColors().colorFor(segments[i].kind),
          ),
          isTrue,
        );
        expect(
          bandContrast(
            image,
            at(track.globalRect!, (10000 + i * 12000) / 100000) +
                const Offset(1, 0),
            track.globalRect!,
            background,
          ),
          greaterThanOrEqualTo(3),
        );
      }
      await finish(tester);
    },
  );
  testWidgets('clamped marker outline stays inside the real track endpoints', (
    tester,
  ) async {
    final baseline = await mount(tester);
    final rect = baseline.globalRect!;
    final before = await raster(tester);
    await mount(tester, segments: [segment(SkipKind.intro, -10000, 120000)]);
    final after = await raster(tester);
    for (var y = (rect.top - 7).floor(); y < rect.bottom.ceil() + 7; y++) {
      for (final x in [rect.left.floor() - 1, rect.right.ceil()]) {
        expect(
          pixel(after, x, y),
          pixel(before, x, y),
          reason: 'marker outline must not extend past timeline bounds',
        );
      }
    }
    await finish(tester);
  });
  testWidgets(
    'highlight is entirely within native track and never leaves an upper band',
    (tester) async {
      final track = await mount(tester);
      final rect = track.globalRect!;
      final before = await raster(tester);
      await mount(tester, segments: [segment(SkipKind.intro, 10000, 20000)]);
      final after = await raster(tester);
      final x = at(rect, .15).dx.round();
      for (var y = (rect.top - 8).floor(); y < rect.top.floor(); y++) {
        expect(
          pixel(after, x, y),
          pixel(before, x, y),
          reason: 'no highlight above native track',
        );
      }
      for (var y = rect.bottom.ceil(); y < rect.bottom.ceil() + 8; y++) {
        expect(
          pixel(after, x, y),
          pixel(before, x, y),
          reason: 'no highlight below native track',
        );
      }
      expect(
        pixel(after, x, rect.center.dy.floor()),
        const SkipSegmentColors().intro,
      );
      await finish(tester);
    },
  );

  for (final brightness in Brightness.values) {
    testWidgets(
      'hidden highlights equal native raster including no outlines $brightness',
      (tester) async {
        await mount(tester, brightness: brightness);
        final baseline = await raster(tester);
        await mount(
          tester,
          brightness: brightness,
          showHighlights: false,
          segments: [segment(SkipKind.intro, -10000, 120000)],
        );
        final hidden = await raster(tester);
        expect(
          hidden.data.buffer.asUint8List(),
          orderedEquals(baseline.data.buffer.asUint8List()),
        );
        await finish(tester);
      },
    );
  }

  for (final preview in [false, true]) {
    testWidgets(
      'hidden highlights preserve segment hover and preview=$preview',
      (tester) async {
        final track = await mount(
          tester,
          showHighlights: false,
          preview: preview,
          segments: [segment(SkipKind.intro, 10000, 20000)],
        );
        final mouse = await hover(tester, at(track.globalRect!, .15));
        await tester.pump(const Duration(milliseconds: 250));
        expect(find.text('片头  00:10–00:20'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('player-thumbnail-preview')),
          preview ? findsOneWidget : findsNothing,
        );
        await finish(tester, mouse);
      },
    );
  }
  testWidgets(
    'same-track fill replaces buffered color but preserves unmarked pixels and thumb',
    (tester) async {
      final track = await mount(tester);
      final rect = track.globalRect!;
      final native = await raster(tester);
      await mount(tester, segments: [segment(SkipKind.intro, 0, 20000)]);
      final marked = await raster(tester);
      final center = rect.center.dy.floor();
      expect(
        pixel(marked, at(rect, .15).dx.round(), center),
        const SkipSegmentColors().intro,
      );
      expect(
        pixel(native, at(rect, .15).dx.round(), center),
        buildAppTheme(Brightness.dark).colorScheme.tertiary.toARGB32(),
      );
      for (final fraction in [.05, .4, .9]) {
        final x = at(rect, fraction).dx.round();
        for (var y = center - 8; y <= center + 8; y++) {
          expect(
            pixel(marked, x, y),
            pixel(native, x, y),
            reason:
                'native thumb or unmarked track must remain unchanged $fraction x=$x y=$y rect=$rect',
          );
        }
      }
      await finish(tester);
    },
  );
  testWidgets(
    'readable dark defaults fill every interior track row without white edges',
    (tester) async {
      final segments = [
        for (var i = 0; i < SkipKind.values.length; i++)
          segment(SkipKind.values[i], 10000 + i * 12000, 17000 + i * 12000),
      ];
      final track = await mount(tester, segments: segments);
      final image = await raster(tester);
      final rect = track.globalRect!;
      for (var i = 0; i < segments.length; i++) {
        final x = at(rect, (13500 + i * 12000) / 100000).dx.round();
        for (var y = rect.top.ceil(); y < rect.bottom.floor(); y++) {
          expect(
            pixel(image, x, y),
            const SkipSegmentColors().colorFor(segments[i].kind),
            reason:
                '${segments[i].kind} must be pure chosen RGB at track row $y',
          );
        }
      }
      await finish(tester);
    },
  );
  for (final brightness in Brightness.values) {
    testWidgets(
      'track-matching custom RGB keeps full-height interior and minimal endpoints $brightness',
      (tester) async {
        final background = buildAppTheme(brightness)
            .sliderTheme
            .inactiveTrackColor!
            .toARGB32();
        final colors = const SkipSegmentColors().withColor(
          SkipKind.intro,
          background,
        );
        final track = await mount(
          tester,
          brightness: brightness,
          colors: colors,
          segments: [segment(SkipKind.intro, 10000, 20000)],
        );
        final image = await raster(tester);
        final rect = track.globalRect!;
        for (var y = rect.top.ceil(); y < rect.bottom.floor(); y++) {
          expect(
            pixel(image, at(rect, .15).dx.round(), y),
            background,
            reason: 'conditional edge must not consume top/bottom of fill',
          );
        }
        expect(
          bandContrast(
            image,
            at(rect, .10) + const Offset(1, 0),
            rect,
            background,
          ),
          greaterThanOrEqualTo(3),
        );
        await finish(tester);
      },
    );
  }
}
