import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/skip_plan.dart';
import 'package:webhtv_pc/core/skip_segment_colors.dart';
import 'package:webhtv_pc/ui/player_overlay.dart';
import 'package:webhtv_pc/ui/theme.dart';

const _capture = ValueKey('actual-default-track-raster');
const _railColor = Color(0xFFE0E0E0);

Future<({ByteData data, int width, int height})> _render(
  WidgetTester tester, {
  required double scale,
  required double verticalOffset,
  required TextDirection direction,
  bool modern = false,
}) async {
  final base = buildAppTheme(Brightness.dark);
  final theme = base.copyWith(
    scaffoldBackgroundColor: Colors.black,
    colorScheme: base.colorScheme.copyWith(tertiary: _railColor),
    sliderTheme: base.sliderTheme.copyWith(
      activeTrackColor: _railColor,
      inactiveTrackColor: _railColor,
      secondaryActiveTrackColor: _railColor,
      // Exercise Flutter's actual default shape resolution, not MeasuredTrack.
      year2023: !modern,
    ),
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: RepaintBoundary(
        key: _capture,
        child: Scaffold(
          body: Directionality(
            textDirection: direction,
            child: Center(
              child: Transform.translate(
                offset: Offset(0, verticalOffset),
                child: const SizedBox(
                  width: 1120,
                  height: 32,
                  child: PlayerProgressSlider(
                    position: Duration(seconds: 50),
                    duration: Duration(seconds: 100),
                    buffered: Duration(seconds: 75),
                    skipSegmentColors: SkipSegmentColors(intro: 0xFFE0E0E0),
                    skipSegments: [
                      SkipSegment(
                        kind: SkipKind.intro,
                        provider: 'fixture',
                        identity: 'intro',
                        startMs: 10000,
                        endMs: 30000,
                      ),
                    ],
                    onSeek: _ignoreSeek,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_capture),
  );
  return (await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: scale);
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final result = (data: data!, width: image.width, height: image.height);
    image.dispose();
    return result;
  }))!;
}

void _ignoreSeek(Duration _) {}

int _red(({ByteData data, int width, int height}) image, int x, int y) =>
    image.data.getUint8((y * image.width + x) * 4);

void main() {
  for (final direction in TextDirection.values) {
    for (final modern in [false, true]) {
      for (final scale in [1.0, 1.25, 1.5, 2.0]) {
        for (final offset in [0.0, 0.25, 0.5]) {
          testWidgets('default track highlight aligns with played and cache '
              '$direction modern=$modern scale=$scale offset=$offset', (
            tester,
          ) async {
            tester.view.physicalSize = const Size(1200, 160);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            final image = await _render(
              tester,
              scale: scale,
              verticalOffset: offset,
              direction: direction,
              modern: modern,
            );
            double visual(double value) =>
                direction == TextDirection.rtl ? 1 - value : value;
            int x(double fraction) =>
                ((40 + 1120 * visual(fraction)) * scale).round();
            final marker = x(.2);
            final played = x(.4);
            final cached = x(.65);
            final unplayed = x(.9);
            for (var y = 0; y < image.height; y++) {
              final expected = _red(image, played, y);
              // Native secondaryTrackValue is composited over inactive;
              // compare its geometry separately, not its compounded alpha.
              expect(
                _red(image, cached, y) > 0,
                expected > 0,
                reason: 'buffer and played track must occupy the same rows',
              );
              for (final sample in [marker, unplayed]) {
                expect(
                  (_red(image, sample, y) - expected).abs(),
                  lessThanOrEqualTo(1),
                  reason:
                      'the same rail color must cover identical rows '
                      'at marker/played/cache/inactive x=$sample y=$y '
                      'values=${[_red(image, marker, y), _red(image, played, y), _red(image, cached, y), _red(image, unplayed, y)]}',
                );
              }
            }
            expect(
              [for (var y = 0; y < image.height; y++) _red(image, marker, y)],
              contains(greaterThan(128)),
              reason: 'the test must actually sample a visible track',
            );
            await tester.pumpWidget(const SizedBox.shrink());
            expect(tester.takeException(), isNull);
          });
        }
      }
    }
  }
}
