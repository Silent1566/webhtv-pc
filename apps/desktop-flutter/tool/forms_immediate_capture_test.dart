import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/ui/config_pages.dart';
import 'package:webhtv_pc/ui/danmaku_settings_page.dart';
import 'package:webhtv_pc/ui/settings_detail_pages.dart';
import 'package:webhtv_pc/ui/following_page.dart';
import 'package:webhtv_pc/ui/theme.dart';

import '../test/support/test_fonts.dart';
import '../test/settings_immediate_forms_test.dart' show isolatedState;

void main() {
  final phase = Platform.environment['CAPTURE_PHASE'] ?? 'before';
  final out = Directory('../../.local/ux-instant-settings/forms/$phase')
    ..createSync(recursive: true);
  setUpAll(() async {
    expect(firstExisting(cjkFontCandidates()), isNotNull);
    expect(firstExisting(iconFontCandidates()), isNotNull);
    await loadFixtureFonts();
    for (final family in [
      'Roboto',
      'Microsoft YaHei UI',
      'Microsoft YaHei',
      'Noto Sans CJK SC',
      'Source Han Sans SC',
      'Segoe UI',
    ]) {
      final bytes = firstExisting(cjkFontCandidates())!.readAsBytesSync();
      await (FontLoader(
        family,
      )..addFont(Future.value(ByteData.view(bytes.buffer)))).load();
    }
  });
  for (final scene in [
    'tmdb-dark',
    'tmdb-light',
    'danmaku-dark',
    'proxy-dark',
    'doh-dark',
    'following-dark',
  ]) {
    testWidgets('capture $scene', (tester) async {
      final target = File('${out.path}/$scene-560x720.png');
      if (phase == 'before') expect(target.existsSync(), isFalse);
      final state = await isolatedState(tester);
      tester.view.physicalSize = const Size(560, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final brightness = scene.endsWith('light')
          ? Brightness.light
          : Brightness.dark;
      final theme = buildAppTheme(brightness);
      final page = switch (scene.split('-').first) {
        'tmdb' => TmdbSettingsPage(state: state),
        'danmaku' => DanmakuSettingsPage(state: state),
        'proxy' => OutboundProxyPage(state: state),
        'doh' => DohSettingsPage(state: state),
        _ => Scaffold(body: FollowingPage(state: state)),
      };
      await tester.pumpWidget(
        RepaintBoundary(
          key: const ValueKey('capture'),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: theme.copyWith(
              textTheme: theme.textTheme.apply(fontFamily: 'FixtureCJK'),
              primaryTextTheme: theme.primaryTextTheme.apply(
                fontFamily: 'FixtureCJK',
              ),
            ),
            home: page,
          ),
        ),
      );
      await tester.pumpAndSettle();
      if (scene.startsWith('tmdb')) {
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('tmdb-test')),
          300,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.ensureVisible(find.byKey(const ValueKey('tmdb-test')));
      } else {
        final key = switch (scene.split('-').first) {
          'danmaku' => 'settings-danmaku-api',
          'proxy' => 'settings-outbound-proxy-default',
          'doh' => 'settings-doh-endpoint',
          _ => 'following-interval',
        };
        await tester.tap(find.byKey(ValueKey(key)));
      }
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final image = await tester
            .renderObject<RenderRepaintBoundary>(
              find.byKey(const ValueKey('capture')),
            )
            .toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        target.writeAsBytesSync(bytes!.buffer.asUint8List());
        image.dispose();
      });
      expect(target.lengthSync(), greaterThan(1024));
    });
  }
}
