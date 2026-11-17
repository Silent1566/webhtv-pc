import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/subtitle_settings.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/subtitle_settings_page.dart';
import 'package:webhtv_pc/ui/theme.dart';

void main() {
  const captureKey = ValueKey('subtitle-capture');
  final repo = Directory.current.parent.parent;
  final phase = Platform.environment['CAPTURE_PHASE'] ?? 'before';
  final output = Directory(
    '${repo.path}/.local/ux-instant-settings/subtitles/$phase',
  );
  setUpAll(() async {
    expect(['before', 'after'], contains(phase));
    output.createSync(recursive: true);
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
      '${repo.path}/.tools/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    ).readAsBytesSync();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(Future.value(ByteData.view(icons.buffer)))).load();
  });
  for (final brightness in Brightness.values) {
    testWidgets('subtitle $phase ${brightness.name} 560x720', (tester) async {
      final temp = Directory.systemTemp.createTempSync('subtitle-capture-');
      final paths = AppPaths.resolve(
        overrides: {
          'config': '${temp.path}/config',
          'data': '${temp.path}/data',
          'cache': '${temp.path}/cache',
          'state': '${temp.path}/logs',
        },
      );
      expect(paths.configDir.startsWith(temp.path), isTrue);
      LogService.logDirectoryOverride = paths.logDir;
      final state = AppState(
        paths: paths,
        log: LogService(),
        externalPlayerDetector: () => const [],
      );
      addTearDown(() async {
        state.dispose();
        LogService.logDirectoryOverride = null;
        temp.deleteSync(recursive: true);
      });
      await tester.runAsync(state.bootstrap);
      await tester.runAsync(
        () => state.setSubtitleSettings(
          SubtitleSettings(
            autoMatch: true,
            assrtToken: 'example-assrt-token',
            xunleiEnabled: true,
            httpEndpoint: 'https://example.test/subtitles/search',
            httpToken: 'example-http-token',
            localDirectories: [r'C:\Videos\subtitles'],
          ),
        ),
      );
      tester.view.physicalSize = const Size(560, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final theme = buildAppTheme(brightness);
      await tester.pumpWidget(
        MaterialApp(
          theme: theme.copyWith(
            textTheme: theme.textTheme.apply(fontFamily: 'CaptureSans'),
            primaryTextTheme: theme.primaryTextTheme.apply(
              fontFamily: 'CaptureSans',
            ),
          ),
          home: RepaintBoundary(
            key: captureKey,
            child: SubtitleSettingsPage(state: state),
          ),
        ),
      );
      await tester.pumpAndSettle();
      Future<void> capture(String area) async {
        expect(tester.takeException(), isNull);
        expect(find.byType(ErrorWidget), findsNothing);
        final target = File(
          '${output.path}/$area-${brightness.name}-560x720.png',
        );
        if (phase == 'before') expect(target.existsSync(), isFalse);
        await tester.runAsync(() async {
          final image = await tester
              .renderObject<RenderRepaintBoundary>(find.byKey(captureKey))
              .toImage(pixelRatio: 1);
          try {
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            target.writeAsBytesSync(data!.buffer.asUint8List());
          } finally {
            image.dispose();
          }
        });
        expect(target.lengthSync(), greaterThan(1024));
      }

      await capture('configuration');
      tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position
          .jumpTo(10000);
      await tester.pumpAndSettle();
      await capture('bottom');
    });
  }
}
