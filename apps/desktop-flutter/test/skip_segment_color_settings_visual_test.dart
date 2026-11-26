/// Additive color editor After evidence; no reliable Before exists.
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/intro_skip_options_page.dart';
import 'package:webhtv_pc/ui/theme.dart';

import 'support/test_fonts.dart';

const _captureKey = ValueKey('skip-colors-evidence');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await loadFixtureFonts(cjkFamily: 'Noto Sans CJK SC');
    await loadFixtureFonts(cjkFamily: 'Roboto');
  });

  Future<void> capture(WidgetTester tester, String name) async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(_captureKey),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final dir = Directory('../../docs/phase9/evidence/skip-segments');
      await dir.create(recursive: true);
      await File('${dir.path}/colors-$name-after.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  for (final brightness in Brightness.values) {
    testWidgets('片段颜色列表与自定义对话框 ${brightness.name} After', (tester) async {
      final temp = Directory.systemTemp.createTempSync('webhtv-colors-visual');
      final log = LogService();
      final state = AppState(
        paths: AppPaths.resolve(
          overrides: {
            'config': '${temp.path}/config',
            'data': '${temp.path}/data',
            'cache': '${temp.path}/cache',
            'state': '${temp.path}/logs',
          },
        ),
        log: log,
      );
      await tester.runAsync(() => state.bootstrap());
      addTearDown(() async {
        state.dispose();
        // Windows 上未释放的日志句柄会让目录删除抛错。
        await log.dispose();
        if (temp.existsSync()) temp.deleteSync(recursive: true);
      });
      tester.view.physicalSize = const Size(900, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final theme = buildAppTheme(brightness);
      await tester.pumpWidget(
        MaterialApp(
          theme: theme.copyWith(
            textTheme: theme.textTheme.apply(fontFamily: 'Noto Sans CJK SC'),
          ),
          builder: (_, child) =>
              RepaintBoundary(key: _captureKey, child: child!),
          home: IntroSkipOptionsPage(state: state),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('片段颜色'),
        240,
        scrollable: find.byType(Scrollable).first,
      );
      await Scrollable.ensureVisible(
        tester.element(find.text('片段颜色')),
        alignment: 0,
      );
      await tester.pumpAndSettle();
      expect(find.text('恢复全部默认颜色').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await capture(tester, 'list-${brightness.name}');
      await tester.tap(
        find.byKey(const ValueKey('settings-player-skip-color-intro')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('skip-color-preset-FFFFEB3B')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(tester.takeException(), isNull);
      await capture(tester, 'dialog-${brightness.name}');
    });
  }
}
