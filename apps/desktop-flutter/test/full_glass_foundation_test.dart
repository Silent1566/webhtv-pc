import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/ui/app.dart';
import 'package:webhtv_pc/ui/glass_surface.dart';
import 'package:webhtv_pc/ui/theme.dart';
import 'package:webhtv_pc/ui/wallpaper_backdrop.dart';

import 'support/test_fonts.dart';

void main() {
  setUpAll(() async {
    await loadFixtureFonts();
  });

  test(
    'route canvases expose the app backdrop while fields retain clear fill',
    () {
      for (final brightness in Brightness.values) {
        final theme = buildAppTheme(brightness);
        expect(theme.scaffoldBackgroundColor.a, 0);
        expect(theme.inputDecorationTheme.fillColor!.a, greaterThan(.9));
      }
    },
  );

  for (final brightness in Brightness.values) {
    testWidgets(
      'no wallpaper still paints art behind the navigation in $brightness',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final boundary = GlobalKey();
        var hasArtwork = false;
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(brightness).copyWith(
              textTheme: buildAppTheme(brightness).textTheme
                  .apply(fontFamily: 'FixtureCJK'),
              navigationRailTheme: buildAppTheme(brightness).navigationRailTheme
                  .copyWith(
                    selectedLabelTextStyle: buildAppTheme(brightness)
                        .navigationRailTheme
                        .selectedLabelTextStyle
                        ?.copyWith(fontFamily: 'FixtureCJK'),
                    unselectedLabelTextStyle: buildAppTheme(brightness)
                        .navigationRailTheme
                        .unselectedLabelTextStyle
                        ?.copyWith(fontFamily: 'FixtureCJK'),
                  ),
            ),
            home: RepaintBoundary(
              key: boundary,
              child: WallpaperBackdrop(
                url: null,
                builder: (context, available) {
                  hasArtwork = available;
                  return Material(
                    type: MaterialType.transparency,
                    child: Row(
                      children: [
                        AppSideBar(
                          section: ShellSection.home,
                          onSelect: (_) {},
                        ),
                        const Expanded(child: Center(child: Text('WebHTV PC'))),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final samples = (await tester.runAsync(() async {
          final render =
              boundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await render.toImage();
          try {
            final phase = Platform.environment['GLASS_FULL_PHASE'];
            final dir = Platform.environment['GLASS_FULL_CAPTURE'];
            if (phase != null && dir != null) {
              await Directory(dir).create(recursive: true);
              final png = (await image.toByteData(
                format: ui.ImageByteFormat.png,
              ))!;
              await File('$dir/foundation-${brightness.name}-$phase.png')
                  .writeAsBytes(png.buffer.asUint8List());
            }
            final bytes = (await image.toByteData())!;
            return [
              for (final point in [
                const Offset(120, 120),
                const Offset(1120, 680),
              ])
                [
                  for (var c = 0; c < 3; c++)
                    bytes.getUint8(
                      (point.dy.toInt() * image.width + point.dx.toInt()) * 4 +
                          c,
                    ),
                ],
            ];
          } finally {
            image.dispose();
          }
        }))!;
        expect(
          hasArtwork,
          isTrue,
          reason:
              'default artwork must keep glass available without configuration',
        );
        expect(
          samples[0],
          isNot(samples[1]),
          reason: 'a solid color is not a usable glass backdrop',
        );
        expect(
          find.descendant(
            of: find.byType(AppSideBar),
            matching: find.byType(BackdropFilter),
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'zero blur and neutral saturation do not filter a live video texture',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.dark),
          home: const GlassSurface(
            blurSigma: 0,
            saturation: 1,
            child: Text('Playback controls'),
          ),
        ),
      );
      expect(find.text('Playback controls'), findsOneWidget);
      expect(find.byType(BackdropFilter), findsNothing);
    },
  );

  testWidgets('normal glass still samples the backdrop', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.dark),
        home: const GlassSurface(child: Text('Normal panel')),
      ),
    );
    expect(find.byType(BackdropFilter), findsOneWidget);
  });
}
