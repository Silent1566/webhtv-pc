library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/ai_settings_page.dart';
import 'package:webhtv_pc/ui/theme.dart';

const captureKey = ValueKey('ai-immediate-capture');

void main() {
  final root = Directory.current.parent.parent;
  final phase = Platform.environment['CAPTURE_PHASE'] ?? 'before';
  if (!['before', 'after'].contains(phase)) throw StateError('Invalid phase');
  final output = Directory('${root.path}/.local/ux-instant-settings/ai/$phase')
    ..createSync(recursive: true);
  setUpAll(() async {
    final bytes = File('/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc')
        .readAsBytesSync();
    for (final family in [
      'CaptureSans',
      'Roboto',
      'Microsoft YaHei UI',
      'Microsoft YaHei',
      'Noto Sans CJK SC',
      'Source Han Sans SC',
      'Segoe UI',
    ]) {
      await (FontLoader(
        family,
      )..addFont(Future.value(ByteData.view(bytes.buffer)))).load();
    }
    final icons = File(
      '${root.path}/.tools/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    ).readAsBytesSync();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(Future.value(ByteData.view(icons.buffer)))).load();
  });
  for (final brightness in Brightness.values) {
    testWidgets('AI $phase $brightness inputs and actions 560x720', (
      tester,
    ) async {
      final temp = Directory.systemTemp.createTempSync('ai-immediate-capture');
      final paths = AppPaths.resolve(
        overrides: {
          'config': '${temp.path}/config',
          'data': '${temp.path}/data',
          'cache': '${temp.path}/cache',
          'state': '${temp.path}/logs',
        },
      );
      LogService.logDirectoryOverride = paths.logDir;
      final state = AppState(
        paths: paths,
        log: LogService(),
        externalPlayerDetector: () => const [],
      );
      addTearDown(() async {
        state.dispose();
        LogService.logDirectoryOverride = null;
        await temp.delete(recursive: true);
      });
      await tester.runAsync(state.bootstrap);
      tester.view.physicalSize = const Size(560, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final base = buildAppTheme(brightness);
      await tester.pumpWidget(
        RepaintBoundary(
          key: captureKey,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: base.copyWith(
              textTheme: base.textTheme.apply(fontFamily: 'CaptureSans'),
              primaryTextTheme: base.primaryTextTheme.apply(
                fontFamily: 'CaptureSans',
              ),
            ),
            home: AiSettingsPage(state: state),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final area in ['inputs', 'actions']) {
        if (area == 'actions') {
          await tester.scrollUntilVisible(
            find.byKey(const ValueKey('ai-test')),
            180,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.ensureVisible(find.text('操作与状态'));
          await tester.pumpAndSettle();
        }
        expect(tester.takeException(), isNull);
        final file = File(
          '${output.path}/ai-$area-${brightness.name}-560x720.png',
        );
        if (phase == 'before' && file.existsSync()) {
          throw StateError('Refusing to overwrite Before');
        }
        await tester.runAsync(() async {
          final image = await tester
              .renderObject<RenderRepaintBoundary>(find.byKey(captureKey))
              .toImage(pixelRatio: 1);
          try {
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            file.writeAsBytesSync(data!.buffer.asUint8List());
          } finally {
            image.dispose();
          }
        });
        expect(file.lengthSync(), greaterThan(1024));
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
