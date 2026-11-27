import 'dart:io';
import 'dart:ui' show FlutterView;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:webhtv_pc/ui/window_mode.dart';
import 'package:window_manager/window_manager.dart';

class _FullscreenTrace extends WidgetsBindingObserver with WindowListener {
  _FullscreenTrace(this.view);

  final FlutterView view;
  final sizes = <Size>[];
  final events = <String>[];

  @override
  void didChangeMetrics() => sizes.add(view.physicalSize);

  @override
  void onWindowEnterFullScreen() => events.add('enter');

  @override
  void onWindowLeaveFullScreen() => events.add('leave');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  for (final maximized in [false, true]) {
    testWidgets(
      'fullscreen has no intermediate viewport (maximized: $maximized)',
      (tester) async {
        await windowManager.ensureInitialized();
        await tester.pumpWidget(const ColoredBox(color: Color(0xFF182338)));
        await windowManager.unmaximize();
        await windowManager.setTitleBarStyle(TitleBarStyle.normal);
        await windowManager.setSize(const Size(720, 480));
        await windowManager.center();
        await windowManager.show();
        await tester.pumpAndSettle();
        final normalBounds = await windowManager.getBounds();
        if (maximized) {
          await windowManager.maximize();
          await tester.pumpAndSettle();
        }
        final beforeBounds = await windowManager.getBounds();
        final windowedSize = tester.view.physicalSize;

        final trace = _FullscreenTrace(tester.view);
        WidgetsBinding.instance.addObserver(trace);
        windowManager.addListener(trace);
        try {
          await enterPlayerFullscreen();
          await tester.pumpAndSettle();
          final fullscreenSize = tester.view.physicalSize;
          final fullscreenBounds = await windowManager.getBounds();
          expect(fullscreenSize, isNot(windowedSize));
          final physicalBounds =
              fullscreenBounds.size * tester.view.devicePixelRatio;
          expect(fullscreenSize.width, closeTo(physicalBounds.width, 0.5));
          expect(fullscreenSize.height, closeTo(physicalBounds.height, 0.5));

          // Repeating the same request must not save fullscreen as the restore bounds.
          await windowManager.setFullScreen(true);
          await tester.pumpAndSettle();
          expect(trace.sizes.toSet(), {
            fullscreenSize,
          }, reason: 'enter viewport sequence');
          expect(trace.events, ['enter']);
          trace.sizes.clear();

          await restoreWindowedMode();
          await tester.pumpAndSettle();
          expect(tester.view.physicalSize, windowedSize);
          expect(trace.sizes.toSet(), {
            windowedSize,
          }, reason: 'leave viewport sequence');
          expect(trace.events, ['enter', 'leave']);
          expect(await windowManager.getBounds(), beforeBounds);
          expect(
            await windowManager.isAlwaysOnTop(),
            isFalse,
            reason: 'windowed mode must not stay topmost',
          );
          expect(await windowManager.isMaximized(), maximized);
          if (maximized) {
            await windowManager.unmaximize();
            await tester.pumpAndSettle();
            expect(await windowManager.getBounds(), normalBounds);
          }
        } finally {
          windowManager.removeListener(trace);
          WidgetsBinding.instance.removeObserver(trace);
          await restoreWindowedMode();
          await windowManager.unmaximize();
        }
      },
      skip: !Platform.isWindows,
    );
  }

  testWidgets(
    'rapid native requests finish windowed without losing the frame',
    (tester) async {
      await windowManager.ensureInitialized();
      await tester.pumpWidget(const ColoredBox(color: Color(0xFF182338)));
      await restoreWindowedMode();
      await windowManager.setSize(const Size(720, 480));
      await windowManager.show();
      await tester.pumpAndSettle();
      final before = await windowManager.getBounds();
      try {
        for (var i = 0; i < 6; i++) {
          await windowManager.setFullScreen(true);
          await windowManager.setFullScreen(false);
        }
        await tester.pumpAndSettle();
        expect(await windowManager.isFullScreen(), isFalse);
        expect(await windowManager.getBounds(), before);
        expect(tester.view.physicalSize.width, greaterThan(0));
        await windowManager.setFullScreen(true);
        await windowManager.hide();
        await windowManager.setFullScreen(false);
        await windowManager.show();
        await tester.pumpAndSettle();
        expect(await windowManager.isFullScreen(), isFalse);
        expect(await windowManager.getBounds(), before);
      } finally {
        await restoreWindowedMode();
        await windowManager.show();
      }
    },
    skip: !Platform.isWindows,
  );

  testWidgets('fullscreen preserves live always-on-top preference', (
    tester,
  ) async {
    await windowManager.ensureInitialized();
    await tester.pumpWidget(const ColoredBox(color: Color(0xFF182338)));
    try {
      for (final initial in [false, true]) {
        await windowManager.setAlwaysOnTop(initial);
        await enterPlayerFullscreen();
        await tester.pumpAndSettle();
        expect(
          await windowManager.isAlwaysOnTop(),
          initial,
          reason: 'fullscreen stacking is not the user preference',
        );
        await windowManager.setAlwaysOnTop(!initial);
        await restoreWindowedMode();
        await tester.pumpAndSettle();
        expect(
          await windowManager.isAlwaysOnTop(),
          !initial,
          reason: 'preference changes during fullscreen survive exit',
        );
      }
    } finally {
      await restoreWindowedMode();
      await windowManager.setAlwaysOnTop(false);
    }
  }, skip: !Platform.isWindows);
}
