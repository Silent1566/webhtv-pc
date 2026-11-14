import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/config_pages.dart';
import 'package:webhtv_pc/ui/diagnostics_pages.dart';
import 'package:webhtv_pc/ui/theme.dart';

import 'support/test_fonts.dart';
import 'tmdb_root_key_ingress_test.dart' as root;

void main() {
  testWidgets(
    'subscription-only settings inputs stay empty and save/export never copy key',
    (tester) async {
      final temp = Directory.systemTemp.createTempSync('tmdb-settings-');
      final state = AppState(
        paths: AppPaths.resolve(
          overrides: {
            'config': '${temp.path}/config',
            'data': '${temp.path}/data',
            'cache': '${temp.path}/cache',
            'state': '${temp.path}/logs',
          },
        ),
        log: LogService(),
      );
      addTearDown(() {
        state.dispose();
        temp.deleteSync(recursive: true);
      });
      tester.view.physicalSize = const Size(1100, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() async {
        await loadFixtureFonts();
        await state.bootstrap();
        expect(
          await state.importConfig(jsonEncode(root.fixture(root.secret))),
          isTrue,
        );
      });
      final boundary = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.dark).copyWith(
            textTheme: buildAppTheme(Brightness.dark).textTheme
                .apply(fontFamily: 'FixtureCJK'),
          ),
          home: RepaintBoundary(
            key: boundary,
            child: TmdbSettingsPage(state: state),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final capture = Platform.environment['TMDB_SETTINGS_CAPTURE'];
      if (capture != null) {
        await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(capture).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('tmdb-api-key')))
            .controller!
            .text,
        '',
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('tmdb-access-token')))
            .controller!
            .text,
        '',
      );
      expect(state.tmdbConfig.isReady, isTrue);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('tmdb-save')),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(find.byKey(const ValueKey('tmdb-save')));
      await tester.tap(find.byKey(const ValueKey('tmdb-save')));
      await tester.runAsync(() async {
        final settings = File(state.paths.settingsPath);
        for (var attempt = 0; attempt < 100; attempt++) {
          if (settings.existsSync() &&
              settings.readAsStringSync().contains('"tmdb"')) {
            return;
          }
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      await tester.pump();
      await tester.pump();
      expect(
        File(state.paths.settingsPath).readAsStringSync(),
        isNot(contains(root.secret)),
      );
      expect(state.tmdbConfig.apiKey, root.secret);
      await tester.runAsync(() async {
        expect(
          jsonEncode(await state.exportSyncedSettings(allowSensitive: true)),
          isNot(contains(root.secret)),
        );
      });
      expect(
        state.log.entries.map((entry) => entry.line).join(),
        isNot(contains(root.secret)),
      );
    },
  );
  testWidgets(
    'diagnostics summary shows effective readiness but never the key',
    (tester) async {
      final temp = Directory.systemTemp.createTempSync('tmdb-diagnostics-');
      final state = AppState(
        paths: AppPaths.resolve(
          overrides: {
            'config': '${temp.path}/config',
            'data': '${temp.path}/data',
            'cache': '${temp.path}/cache',
            'state': '${temp.path}/logs',
          },
        ),
        log: LogService(),
      );
      addTearDown(() {
        state.dispose();
        temp.deleteSync(recursive: true);
      });
      tester.view.physicalSize = const Size(1200, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() async {
        await state.bootstrap();
        expect(
          await state.importConfig(jsonEncode(root.fixture(root.secret))),
          isTrue,
        );
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.dark),
          home: SettingsPage(state: state),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('settings-category-connections')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('settings-tmdb-summary')),
        findsOneWidget,
      );
      expect(find.textContaining('已启用'), findsWidgets);
      final visibleText = tester
          .widgetList<Text>(find.byType(Text))
          .map((item) => item.data ?? '')
          .join();
      expect(visibleText, isNot(contains(root.secret)));
    },
  );
}
