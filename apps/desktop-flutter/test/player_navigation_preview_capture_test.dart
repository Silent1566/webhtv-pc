import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/player_buttons.dart';
import 'package:webhtv_pc/ui/player_overlay.dart';
import 'package:webhtv_pc/ui/theme.dart';

import 'support/test_fonts.dart';

const _captureKey = ValueKey('navigation-capture');

ThemeData captureTheme() {
  final theme = buildAppTheme(Brightness.dark);
  return theme.copyWith(
    textTheme: theme.textTheme.apply(
      fontFamily: 'FixtureCJK',
      fontFamilyFallback: const ['FixtureCJK'],
    ),
    appBarTheme: theme.appBarTheme.copyWith(
      titleTextStyle: theme.appBarTheme.titleTextStyle?.copyWith(
        fontFamily: 'FixtureCJK',
        fontFamilyFallback: const ['FixtureCJK'],
      ),
    ),
  );
}

Future<void> loadCaptureFonts() async {
  expectFontsAvailableOrSkip();
  await loadFixtureFonts();
  final mono = firstExisting([
    '/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf',
    r'C:\Windows\Fonts\consola.ttf',
    '/System/Library/Fonts/Menlo.ttc',
  ]);
  expect(mono, isNotNull, reason: 'Readable captures require a monospace font');
  if (mono != null) {
    final bytes = ByteData.sublistView(await mono.readAsBytes());
    await (FontLoader('monospace')..addFont(Future.value(bytes))).load();
  }
}

Widget scene({
  bool enabled = false,
  Future<Uint8List?> Function(Duration)? provider,
}) => MaterialApp(
  theme: captureTheme(),
  builder: (context, child) => RepaintBoundary(key: _captureKey, child: child!),
  home: Scaffold(
    body: Stack(
      children: [
        const Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF21364D), Color(0xFF0B0E1A)],
              ),
            ),
            child: Center(
              child: Text('WebHTV · 导航预览', style: TextStyle(fontSize: 28)),
            ),
          ),
        ),
        Positioned.fill(
          child: PlayerControlOverlay(
            topBar: AppBar(title: const Text('导航视觉样本')),
            progressRow: SizedBox(
              height: 32,
              child: Row(
                children: [
                  const Text(
                    '00:30',
                    style: TextStyle(fontFamily: 'monospace', fontSize: 12),
                  ),
                  Expanded(
                    child: PlayerProgressSlider(
                      position: const Duration(seconds: 30),
                      duration: const Duration(minutes: 2),
                      buffered: const Duration(seconds: 70),
                      onSeek: (_) {},
                      thumbnailPreviewEnabled: enabled,
                      thumbnailProvider: provider,
                      previewSourceKey: 1,
                    ),
                  ),
                  const Text(
                    '02:00',
                    style: TextStyle(fontFamily: 'monospace', fontSize: 12),
                  ),
                ],
              ),
            ),
            actionButtons: [
              IconButton(
                onPressed: () {},
                icon: const Icon(Icons.skip_previous),
              ),
              IconButton(onPressed: () {}, icon: const Icon(Icons.pause)),
              IconButton(onPressed: () {}, icon: const Icon(Icons.skip_next)),
            ],
            actionGroups: const [
              PlayerButtonGroup.transport,
              PlayerButtonGroup.transport,
              PlayerButtonGroup.transport,
            ],
          ),
        ),
      ],
    ),
  ),
);

Future<void> capture(WidgetTester tester, String name) async {
  if (Platform.environment['TASK2_CAPTURE'] != '1') return;
  await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(_captureKey),
    );
    final image = await boundary.toImage(pixelRatio: 1);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    final file = File(
      '../../.superpowers/sdd/12-player-navigation-plan/task-2/$name.png',
    );
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(data!.buffer.asUint8List());
  });
}

Future<Uint8List> thumbnailFixture() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  const rect = Rect.fromLTWH(0, 0, 192, 108);
  canvas.drawRect(
    rect,
    Paint()
      ..shader = const LinearGradient(
        colors: [Color(0xFF21364D), Color(0xFF0B0E1A)],
      ).createShader(rect),
  );
  canvas.drawCircle(
    const Offset(142, 28),
    9,
    Paint()..color = const Color(0xFF9BB8E0),
  );
  final ridge = Path()
    ..moveTo(0, 96)
    ..lineTo(52, 38)
    ..lineTo(104, 96)
    ..lineTo(147, 59)
    ..lineTo(192, 108)
    ..lineTo(0, 108)
    ..close();
  canvas.drawPath(ridge, Paint()..color = const Color(0xFF3A4560));
  final picture = recorder.endRecording();
  final image = await picture.toImage(192, 108);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return data!.buffer.asUint8List();
}

void main() {
  setUpAll(loadCaptureFonts);
  for (final size in [const Size(1280, 720), const Size(640, 360)]) {
    testWidgets(
      'default capture ${size.width.toInt()}x${size.height.toInt()}',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(scene());
        await tester.pumpAndSettle();
        expect(
          tester.getSize(find.text('00:30')).width,
          lessThan(45),
          reason:
              'Default capture must use loaded monospace, not Ahem fallback',
        );
        expect(tester.getSize(find.byType(PlayerProgressSlider)).height, 32);
        expect(tester.getSize(find.byType(PlayerControlOverlay)), size);
        final phase = Platform.environment['TASK2_PHASE'] ?? 'after';
        await capture(
          tester,
          '$phase-default-${size.width.toInt()}x${size.height.toInt()}',
        );
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
    for (final mode in ['loading', 'image', 'error']) {
      testWidgets(
        'preview $mode capture ${size.width.toInt()}x${size.height.toInt()}',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = size;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final bytes = await tester.runAsync(thumbnailFixture);
          final pending = Completer<Uint8List?>();
          await tester.pumpWidget(
            scene(
              enabled: true,
              provider: (_) {
                if (mode == 'loading') return pending.future;
                if (mode == 'error') {
                  return Future.error(StateError('fixture extraction failed'));
                }
                return Future.value(bytes);
              },
            ),
          );
          await tester.pumpAndSettle();
          final mouse = await tester.createGesture(
            kind: PointerDeviceKind.mouse,
          );
          await mouse.addPointer(location: Offset.zero);
          await mouse.moveTo(tester.getCenter(find.byType(Slider)));
          await tester.pump(const Duration(milliseconds: 200));
          await tester.pumpAndSettle();
          if (mode == 'image') {
            await tester.runAsync(
              () => precacheImage(
                MemoryImage(bytes!),
                tester.element(find.byType(Slider)),
              ),
            );
            await tester.pumpAndSettle();
          }
          final card = tester.getRect(
            find.byKey(const ValueKey('player-thumbnail-preview')),
          );
          final slider = tester.getRect(find.byType(PlayerProgressSlider));
          expect(card.bottom, lessThan(slider.top));
          expect(card.left, greaterThanOrEqualTo(0));
          expect(card.right, lessThanOrEqualTo(size.width));
          expect(slider.height, 32);
          expect(card.size, const Size(192, 136));
          if (mode == 'image') expect(find.byType(Image), findsOneWidget);
          if (mode == 'loading') expect(find.text('加载中…'), findsOneWidget);
          if (mode == 'error') expect(find.text('预览不可用'), findsOneWidget);
          debugPrint(
            'TASK2-GEOMETRY $mode viewport=$size slider=$slider preview=$card',
          );
          await capture(
            tester,
            'after-preview-$mode-${size.width.toInt()}x${size.height.toInt()}',
          );
          await mouse.removePointer();
          await tester.pumpWidget(const SizedBox());
          pending.complete(null);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
