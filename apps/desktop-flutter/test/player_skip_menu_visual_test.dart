import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/ui/player_context_menu.dart';
import 'package:webhtv_pc/ui/player_page.dart';

import 'support/player_page_harness.dart';
import 'support/test_fonts.dart';

void main() {
  setUpAll(() async {
    await loadFixtureFonts(cjkFamily: 'Noto Sans CJK SC');
    await loadFixtureFonts(cjkFamily: 'Roboto');
  });

  testWidgets('跳过片段菜单真实渲染', (tester) async {
    expectFontsAvailableOrSkip();
    await pumpPlayerPage(tester);
    debugOsdClockOverride = DateTime(2026, 11, 23, 20, 30);
    addTearDown(() => debugOsdClockOverride = null);
    await tester.tapAt(const Offset(300, 80), buttons: kSecondaryButton);
    await settlePlayerPage(tester);
    final before = Platform.environment['CAPTURE_PHASE'] == 'before';

    Future<void> drill(String label) async {
      final target = find.descendant(
        of: find.byType(PlayerContextMenu),
        matching: find.text(label),
      );
      expect(target, findsOneWidget);
      await tester.ensureVisible(target);
      await tester.tap(target);
      await settlePlayerPage(tester, times: 3);
    }

    Future<void> capture(String name) async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(playerPageCaptureRootKey),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final dir = Directory('../../docs/phase9/evidence/skip-segments');
        await dir.create(recursive: true);
        await File('${dir.path}/menu-$name.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }

    await drill(before ? '片头片尾' : '跳过片段');
    await capture(before ? 'before' : 'after');
    if (!before) {
      await drill('片段类型');
      await capture('types-after');
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  });
}
