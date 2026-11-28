import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/search_suggest_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/app.dart';
import 'package:webhtv_pc/ui/desktop_window_frame.dart';
import 'package:webhtv_pc/ui/glass_widgets.dart';
import 'package:webhtv_pc/ui/glass_surface.dart';
import 'package:webhtv_pc/ui/glass_dialog.dart';
import 'package:webhtv_pc/ui/startup_arguments.dart';
import 'package:webhtv_pc/ui/wallpaper_backdrop.dart';
import 'package:window_manager/window_manager.dart';

import 'support/detail_test_seams.dart';

const _channel = MethodChannel('window_manager');

class _RootState extends AppState {
  _RootState(this.bootstrapGate)
    : super(
        paths: AppPaths.resolve(
          overrides: {
            for (final role in ['config', 'data', 'cache', 'state'])
              role: '${Directory.systemTemp.path}/glass-root-fixture/$role',
          },
        ),
        log: MemoryOnlyLogService(),
        warmAutoRoutes: false,
        httpClient: MockClient((request) async => http.Response('{}', 200)),
        searchSuggestService: SearchSuggestService(
          client: MockClient((request) async => http.Response('{}', 200)),
        ),
      );

  final Future<void> bootstrapGate;
  int disposeCalls = 0;

  @override
  bool get externalMetaEnabled => false;

  @override
  Future<void> bootstrap() => bootstrapGate;

  @override
  Future<void> startupConfigRefresh() async {}

  @override
  Future<void> maybeAutoCheckForUpdates() async {}

  @override
  void dispose() {
    disposeCalls++;
    super.dispose();
  }
}

final class _BoundaryFiles extends IOOverrides {
  _BoundaryFiles({required bool accepted}) : file = _BoundaryFile(accepted);

  final _BoundaryFile file;

  @override
  File createFile(String path) =>
      path.endsWith('usage-boundary-accepted') ? file : super.createFile(path);
}

class _BoundaryFile implements File {
  _BoundaryFile(this.accepted);

  bool accepted;
  int writeCalls = 0;

  @override
  Future<bool> exists() async => accepted;

  @override
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) async {
    accepted = true;
    writeCalls++;
    return this;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _WindowCalls {
  bool fullscreen = false;
  final methods = <String>[];

  Future<Object?> handle(MethodCall call) async {
    methods.add(call.method);
    switch (call.method) {
      case 'isFullScreen':
        return fullscreen;
      case 'setFullScreen':
        fullscreen = (call.arguments as Map)['isFullScreen'] as bool;
        return null;
      case 'isPreventClose':
      case 'isMaximized':
        return false;
      case 'isFocused':
        return true;
      default:
        return null;
    }
  }
}

Future<void> _pumpRoot(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
}

Future<void> _withRoot(
  WidgetTester tester,
  Future<void> Function(
    _RootState,
    Completer<void>,
    _WindowCalls,
    _BoundaryFile,
  )
  body, {
  bool accepted = true,
  StartupArguments startup = const StartupArguments(),
}) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final files = _BoundaryFiles(accepted: accepted);
  await IOOverrides.runWithIOOverrides(() async {
    final gate = Completer<void>();
    // Construct in the widget-test zone: no real-zone fixture cleanup futures.
    final state = _RootState(gate.future);
    final window = _WindowCalls();
    final existingListeners = windowManager.listeners.length;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      _channel,
      window.handle,
    );
    try {
      await tester.pumpWidget(
        WebHtvApp(stateFactory: () => state, startup: startup),
      );
      await _pumpRoot(tester);
      await body(state, gate, window, files.file);
    } finally {
      if (!gate.isCompleted) gate.complete();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(state.disposeCalls, 1);
      expect(windowManager.listeners, hasLength(existingListeners));
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        _channel,
        null,
      );
    }
  }, files);
}

void main() {
  testWidgets(
    'shell caption toolbar and rail have no drawn rim or divider',
    (tester) => _withRoot(tester, (state, gate, window, boundary) async {
      gate.complete();
      await _pumpRoot(tester);
      final caption = find.ancestor(
        of: find.byTooltip('最小化'),
        matching: find.byType(GlassSurface),
      );
      final top = find.descendant(
        of: find.byType(GlassTopBar),
        matching: find.byType(GlassSurface),
      );
      final rail = find.descendant(
        of: find.byType(AppSideBar),
        matching: find.byType(GlassSurface),
      );
      for (final region in [caption, top, rail]) {
        expect(region, findsOneWidget);
        expect(
          tester.widget<GlassSurface>(region).rimAlpha,
          0,
          reason: 'shell chrome must not draw the framed white edge',
        );
      }
      expect(
        find.descendant(
          of: find.byType(AppShell),
          matching: find.byType(VerticalDivider),
        ),
        findsNothing,
      );
      expect(tester.getSize(find.byType(NavigationRail)).width, 76);
      expect(find.byTooltip('关闭'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }),
  );

  testWidgets(
    'dialogs also inherit the global borderless material rule',
    (tester) => _withRoot(tester, (state, gate, window, boundary) async {
      gate.complete();
      await _pumpRoot(tester);
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      unawaited(
        showGlassDialog<void>(
          context: navigator.context,
          builder: (_) => const GlassAlertDialog(
            title: Text('Dialog material'),
            content: Text('Keep readable dialog content'),
          ),
        ),
      );
      await _pumpRoot(tester);
      final surface = find.descendant(
        of: find.byType(GlassAlertDialog),
        matching: find.byType(GlassSurface),
      );
      expect(surface, findsOneWidget);
      expect(tester.widget<GlassSurface>(surface).rimAlpha, 0);
      navigator.pop();
      await _pumpRoot(tester);
    }),
  );

  testWidgets(
    'production root keeps caption above pushed routes without replacing Navigator',
    (tester) => _withRoot(tester, (state, gate, window, boundary) async {
      gate.complete();
      await _pumpRoot(tester);
      expect(find.byType(AppShell), findsOneWidget);
      expect(find.byType(DesktopWindowFrame), findsOneWidget);
      expect(find.byTooltip('最小化'), findsOneWidget);
      final navigatorFinder = find.byType(Navigator);
      final originalNavigator = tester.state<NavigatorState>(navigatorFinder);
      final originalElement = tester.element(navigatorFinder);
      expect(
        find.ancestor(
          of: find.byType(DesktopWindowFrame),
          matching: find.byType(WallpaperBackdrop),
        ),
        findsOneWidget,
      );
      expect(
        find.ancestor(
          of: navigatorFinder,
          matching: find.byType(DesktopWindowFrame),
        ),
        findsOneWidget,
      );
      unawaited(
        originalNavigator.push<void>(
          MaterialPageRoute(
            builder: (_) =>
                const Scaffold(body: Center(child: Text('Nested route'))),
          ),
        ),
      );
      await _pumpRoot(tester);
      expect(find.text('Nested route'), findsOneWidget);
      expect(find.byTooltip('最小化'), findsOneWidget);
      expect(tester.getTopLeft(find.text('Nested route')).dy, greaterThan(44));
      expect(
        tester.state<NavigatorState>(navigatorFinder),
        same(originalNavigator),
      );
      expect(tester.element(navigatorFinder), same(originalElement));
      expect(tester.takeException(), isNull);
    }),
  );

  testWidgets(
    'delayed startup fullscreen hides caption and Escape restores without native event',
    (tester) => _withRoot(tester, (state, gate, window, boundary) async {
      expect(window.fullscreen, isFalse);
      expect(window.methods, contains('isFullScreen'));
      expect(find.byTooltip('最小化'), findsOneWidget);
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      unawaited(
        navigator.push<void>(
          MaterialPageRoute(
            builder: (_) => const Focus(
              autofocus: true,
              child: Scaffold(body: Center(child: Text('Focused route'))),
            ),
          ),
        ),
      );
      await _pumpRoot(tester);
      gate.complete();
      await _pumpRoot(tester);
      expect(window.fullscreen, isTrue);
      expect(find.byTooltip('最小化'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _pumpRoot(tester);
      expect(window.fullscreen, isFalse);
      expect(find.byTooltip('最小化'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }, startup: const StartupArguments(fullscreen: true)),
  );

  testWidgets(
    'first-run boundary uses transparent outer BottomSheet Material and persists consent',
    (tester) => _withRoot(tester, (state, gate, window, boundary) async {
      gate.complete();
      await _pumpRoot(tester);
      final sheet = find.byType(BottomSheet);
      expect(sheet, findsOneWidget);
      expect(find.text('使用边界提示'), findsOneWidget);
      expect(
        find.descendant(of: sheet, matching: find.byType(GlassPane)),
        findsOneWidget,
      );
      final outerMaterial = tester.widget<Material>(
        find.descendant(of: sheet, matching: find.byType(Material)).first,
      );
      expect(
        outerMaterial.type == MaterialType.transparency ||
            outerMaterial.color?.a == 0,
        isTrue,
        reason:
            'BottomSheet Material outside GlassPane must not paint an opaque slab '
            '(type=${outerMaterial.type}, color=${outerMaterial.color})',
      );
      await tester.tap(find.text('我已了解并继续'));
      await _pumpRoot(tester);
      expect(boundary.writeCalls, 1);
      expect(boundary.accepted, isTrue);
      expect(find.byType(BottomSheet), findsNothing);
      expect(tester.takeException(), isNull);
    }, accepted: false),
  );
}
