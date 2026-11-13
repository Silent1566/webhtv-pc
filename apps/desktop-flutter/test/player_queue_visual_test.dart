import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'player_queue_test.dart' as fixture;
import 'support/test_fonts.dart';

void main() {
  setUpAll(() async {
    await loadFixtureFonts();
    await loadFixtureFonts(cjkFamily: 'Roboto');
    await loadFixtureFonts(cjkFamily: 'Microsoft YaHei UI');
  });
  testWidgets('current player queue episode fixture capture', (tester) async {
    expectFontsAvailableOrSkip();
    const phase = String.fromEnvironment(
      'QUEUE_CAPTURE',
      defaultValue: 'after',
    );
    final capture = GlobalKey();
    final mounted = await fixture.mountQueue(
      tester,
      before: phase == 'before',
      queue: fixture.QueueFixture(count: 3, hasMore: true),
      capture: capture,
    );
    mounted.media.progress(120);
    await tester.pump();
    await tester.tap(find.textContaining('选集（').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    if (phase == 'before') {
      expect(
        find.byKey(const ValueKey('player-episode-card-0')),
        findsOneWidget,
      );
      expect(find.text('第02集 月下重逢.mkv'), findsNothing);
    } else {
      expect(
        find.byKey(const ValueKey('player-queue-item-opaque-file-A')),
        findsOneWidget,
      );
      expect(find.text('第02集 月下重逢.mkv'), findsOneWidget);
      expect(mounted.queue.resolvedKeys, isEmpty);
    }
    final boundary =
        capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final dir = Directory('../../.superpowers/folder-playback/B');
      await dir.create(recursive: true);
      await File('${dir.path}/$phase.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
    await fixture.closeQueue(tester);
  });
}
