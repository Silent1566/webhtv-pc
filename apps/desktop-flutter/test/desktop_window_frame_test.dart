import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/app.dart';
import 'package:webhtv_pc/ui/desktop_window_frame.dart';
import 'package:webhtv_pc/ui/startup_arguments.dart';
import 'package:webhtv_pc/ui/theme.dart';
import 'package:webhtv_pc/ui/wallpaper_backdrop.dart';
import 'package:webhtv_pc/ui/window_mode.dart';
import 'package:window_manager/window_manager.dart';

import 'support/detail_test_seams.dart';
import 'support/test_fonts.dart';
import 'support/widget_settle.dart';

const _channel = MethodChannel('window_manager');
const _navigatorBody = ValueKey('navigator-body');

void main() {
  late List<String> calls;
  late bool fullscreen;
  late bool maximized;
  Completer<bool>? pendingFullscreen;
  bool failCommands = false;

  setUp(() {
    calls = [];
    fullscreen = false;
    maximized = false;
    pendingFullscreen = null;
    failCommands = false;
  });

  void mockWindow(WidgetTester tester) {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 800);
    addTearDown(tester.view.reset);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (
      call,
    ) async {
      calls.add(call.method);
      return switch (call.method) {
        'isFullScreen' => pendingFullscreen?.future ?? fullscreen,
        'isMaximized' => maximized,
        'setFullScreen' =>
          fullscreen = (call.arguments as Map)['isFullScreen'] as bool,
        _ when failCommands => throw PlatformException(code: 'unavailable'),
        _ => null,
      };
    });
  }

  Future<void> pumpFrame(WidgetTester tester) async {
    mockWindow(tester);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => DesktopWindowFrame(child: child!),
        home: const SizedBox.expand(key: _navigatorBody),
      ),
    );
    await tester.pump();
  }

  Future<void> notify(WidgetTester tester, String event) async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      _channel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('onEvent', {'eventName': event}),
      ),
      (_) {},
    );
    await tester.pump();
  }

  testWidgets('caption buttons issue window commands, not route pops', (
    tester,
  ) async {
    await pumpFrame(tester);
    for (final (label, command) in [
      ('最小化', 'minimize'),
      ('最大化', 'maximize'),
      ('关闭', 'close'),
    ]) {
      await tester.tap(find.byTooltip(label));
      await tester.pump();
      expect(calls.last, command);
    }
    expect(find.byKey(_navigatorBody), findsOneWidget);
  });

  testWidgets('starts in maximized state and listens for maximize changes', (
    tester,
  ) async {
    maximized = true;
    await pumpFrame(tester);
    await tester.tap(find.byTooltip('还原'));
    expect(calls.last, 'unmaximize');

    maximized = false;
    await notify(tester, 'unmaximize');
    expect(find.byTooltip('最大化'), findsOneWidget);
    maximized = true;
    await notify(tester, 'maximize');
    expect(find.byTooltip('还原'), findsOneWidget);
  });

  testWidgets('drag, double-click and system menu use the caption area', (
    tester,
  ) async {
    await pumpFrame(tester);
    const blank = Offset(400, 20);
    await tester.dragFrom(blank, const Offset(24, 0));
    expect(calls.last, 'startDragging');
    calls.clear();
    await tester.tapAt(blank);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(blank);
    await tester.pump();
    expect(calls.where((method) => method != 'isFullScreen'), ['maximize']);
    await tester.tapAt(blank, buttons: kSecondaryMouseButton);
    expect(calls.last, 'popUpWindowMenu');
    await tester.pump(kDoubleTapTimeout);
  });

  testWidgets('hover shows the caption tooltip above the Navigator', (
    tester,
  ) async {
    await pumpFrame(tester);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: const Offset(400, 20));
    await mouse.moveTo(tester.getCenter(find.byTooltip('关闭')));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.text('关闭'), findsOneWidget);
    await mouse.moveTo(const Offset(400, 20));
  });

  testWidgets('keyboard focus can activate a caption control', (tester) async {
    await pumpFrame(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.f6);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(calls.last, 'minimize');
    await tester.sendKeyEvent(LogicalKeyboardKey.f6);
    await tester.pump();
    calls.clear();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(calls, isEmpty);
  });

  testWidgets('startup full screen hides caption until native exit', (
    tester,
  ) async {
    fullscreen = true;
    await pumpFrame(tester);
    final body = find.byKey(_navigatorBody);
    final navigatorElement = tester.element(find.byType(Navigator));
    expect(find.byTooltip('最小化'), findsNothing);
    expect(tester.getSize(body), const Size(1280, 800));

    fullscreen = false;
    await notify(tester, 'leave-full-screen');
    expect(find.byTooltip('最小化'), findsOneWidget);
    expect(tester.getSize(body).height, lessThan(800));

    fullscreen = true;
    await notify(tester, 'enter-full-screen');
    expect(find.byTooltip('最小化'), findsNothing);
    expect(tester.getSize(body), const Size(1280, 800));
    expect(tester.element(find.byType(Navigator)), same(navigatorElement));
  });

  testWidgets('F11 and Escape update the caption without native events', (
    tester,
  ) async {
    mockWindow(tester);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            WindowEscapeShortcuts(child: DesktopWindowFrame(child: child!)),
        home: const Focus(autofocus: true, child: SizedBox.expand()),
      ),
    );
    await tester.pump();
    expect(find.byTooltip('关闭'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.f11);
    await tester.pump();
    expect(fullscreen, isTrue);
    expect(find.byTooltip('关闭'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(fullscreen, isFalse);
    expect(find.byTooltip('关闭'), findsOneWidget);
  });

  testWidgets('minimum window width and height constrain only the body', (
    tester,
  ) async {
    await pumpFrame(tester);
    final body = find.byKey(_navigatorBody);
    tester.view.physicalSize = const Size(1024, 640);
    await tester.pump();
    final captionHeight = tester.getTopLeft(body).dy;
    expect(captionHeight, greaterThan(0));
    expect(tester.getSize(body), Size(1024, 640 - captionHeight));
    expect(tester.getRect(find.byTooltip('关闭')).right, lessThanOrEqualTo(1024));
    expect(tester.takeException(), isNull);
  });

  testWidgets('native fullscreen event wins over an in-flight startup read', (
    tester,
  ) async {
    pendingFullscreen = Completer<bool>();
    await pumpFrame(tester);
    await notify(tester, 'enter-full-screen');
    pendingFullscreen!.complete(false);
    await tester.pump();
    expect(find.byTooltip('关闭'), findsNothing);
  });

  testWidgets('disposal unregisters listener while platform read is pending', (
    tester,
  ) async {
    final existing = windowManager.listeners.length;
    pendingFullscreen = Completer<bool>();
    await pumpFrame(tester);
    expect(windowManager.listeners, hasLength(existing + 1));
    await tester.pumpWidget(const SizedBox.shrink());
    expect(windowManager.listeners, hasLength(existing));
    pendingFullscreen!.complete(true);
    await tester.pump();
    await notify(tester, 'enter-full-screen');
    expect(tester.takeException(), isNull);
  });

  testWidgets('unsupported caption command does not surface an async error', (
    tester,
  ) async {
    await pumpFrame(tester);
    failCommands = true;
    await tester.tap(find.byTooltip('最小化'));
    await tester.pump();
    expect(calls.last, 'minimize');
    expect(tester.takeException(), isNull);
  });

  final captureDir = Platform.environment['GLASS_WINDOW_CAPTURE'];
  if (captureDir != null) {
    setUpAll(() async {
      expectFontsAvailableOrSkip();
      final cjk = firstExisting(cjkFontCandidates())!;
      final icons = firstExisting(iconFontCandidates());
      expect(icons, isNotNull, reason: describeFixtureFonts());
      reportFixtureFonts();
      for (final family in ['Roboto', 'Noto Sans CJK SC']) {
        await (FontLoader(
          family,
        )..addFont(cjk.readAsBytes().then(ByteData.sublistView))).load();
      }
      await loadFixtureFonts();
    });

    for (final brightness in Brightness.values) {
      testWidgets(
        'capture app window with no wallpaper in ${brightness.name}',
        (tester) async {
          mockWindow(tester);
          final temp = Directory.systemTemp.createTempSync('caption-capture-');
          final paths = AppPaths.resolve(
            overrides: {
              'config': '${temp.path}/config',
              'data': '${temp.path}/data',
              'cache': '${temp.path}/cache',
              'state': '${temp.path}/logs',
            },
          );
          Directory(paths.configDir).createSync(recursive: true);
          File('${paths.configDir}/usage-boundary-accepted')
              .writeAsStringSync('test');
          final state = AppState(paths: paths, log: MemoryOnlyLogService());
          final boundary = GlobalKey();
          try {
            await tester.pumpWidget(
              MaterialApp(
                theme: buildAppTheme(brightness),
                builder: (context, child) => RepaintBoundary(
                  key: boundary,
                  child: WallpaperBackdrop(
                    url: null,
                    builder: (context, hasArtwork) =>
                        DesktopWindowFrame(child: child!),
                  ),
                ),
                home: AppShell(state: state, startup: const StartupArguments()),
              ),
            );
            await settle(tester);
            expect(find.text('首页'), findsWidgets);
            final mouse = await tester.createGesture(
              kind: PointerDeviceKind.mouse,
            );
            await mouse.addPointer(
              location: tester.getCenter(find.byTooltip('关闭')),
            );
            await tester.pump(const Duration(seconds: 1));
            await tester.pumpAndSettle();
            await tester.runAsync(() async {
              final render =
                  boundary.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary;
              final image = await render.toImage();
              try {
                final bytes = (await image.toByteData(
                  format: ui.ImageByteFormat.png,
                ))!;
                await Directory(captureDir).create(recursive: true);
                await File('$captureDir/caption-${brightness.name}-after.png')
                    .writeAsBytes(bytes.buffer.asUint8List());
              } finally {
                image.dispose();
              }
            });
            await mouse.removePointer();
            await tester.pumpAndSettle();
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            state.dispose();
            temp.deleteSync(recursive: true);
          }
        },
      );
    }
  }
}
