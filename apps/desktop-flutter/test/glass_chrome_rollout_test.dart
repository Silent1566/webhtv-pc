import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/ui/glass_chrome.dart';
import 'package:webhtv_pc/ui/theme.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('chrome $brightness: real art samples, flat backing does not', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(640, 320);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final theme = buildAppTheme(brightness);
      final boundary = GlobalKey();
      const sampleY = 40;

      Future<void> mount(GlassTopBarBackdrop backdrop) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: RepaintBoundary(
              key: boundary,
              child: Scaffold(
                body: Stack(
                  fit: StackFit.expand,
                  children: [
                    const Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(child: ColoredBox(color: Colors.black)),
                        Expanded(child: ColoredBox(color: Colors.white)),
                      ],
                    ),
                    Align(
                      alignment: Alignment.topCenter,
                      child: GlassTopBar(
                        backdrop: backdrop,
                        child: Row(
                          children: [
                            Text('WebHTV', style: theme.textTheme.titleMedium),
                            const Spacer(),
                            TextButton(
                              onPressed: () {},
                              child: const Text('Source'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      Future<List<Color>> sample(String state) async {
        final result = await tester.runAsync(() async {
          final box =
              boundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await box.toImage();
          try {
            final dir = Platform.environment['GLASS_CHROME_CAPTURE'];
            if (dir != null && dir.isNotEmpty) {
              await Directory(dir).create(recursive: true);
              final png = (await image.toByteData(
                format: ui.ImageByteFormat.png,
              ))!;
              await File('$dir/$brightness-$state.png').writeAsBytes(
                png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
              );
            }
            final data = (await image.toByteData())!;
            expect(data.getUint8((100 * image.width + 150) * 4), 0);
            expect(data.getUint8((100 * image.width + 470) * 4), 255);
            return [
              for (final x in [150, 470])
                Color.fromARGB(
                  255,
                  data.getUint8((sampleY * image.width + x) * 4),
                  data.getUint8((sampleY * image.width + x) * 4 + 1),
                  data.getUint8((sampleY * image.width + x) * 4 + 2),
                ),
            ];
          } finally {
            image.dispose();
          }
        });
        return result!;
      }

      final filter = find.descendant(
        of: find.byType(GlassTopBar),
        matching: find.byType(BackdropFilter),
      );
      await mount(GlassTopBarBackdrop.flatSurface);
      final flat = await sample('flat');
      expect(filter, findsNothing);
      expect(flat.first, flat.last);
      await mount(GlassTopBarBackdrop.content);
      final glass = await sample('art');
      expect(filter, findsOneWidget);
      expect(glass.last.r - glass.first.r, greaterThanOrEqualTo(20 / 255));
      final controlTheme = Theme.of(tester.element(find.byType(TextButton)));
      final buttonInk =
          controlTheme.textButtonTheme.style?.foregroundColor?.resolve({}) ??
          controlTheme.colorScheme.primary;
      for (final backing in glass) {
        for (final ink in [theme.colorScheme.onSurface, buttonInk]) {
          expect(
            _contrast(ink, backing),
            greaterThanOrEqualTo(4.5),
            reason: '$brightness enabled control $ink on $backing',
          );
        }
      }
    });
  }
}

double _contrast(Color a, Color b) {
  final x = a.computeLuminance();
  final y = b.computeLuminance();
  return x > y ? (x + .05) / (y + .05) : (y + .05) / (x + .05);
}
