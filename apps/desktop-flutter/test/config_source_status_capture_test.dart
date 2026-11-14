import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/ui/app.dart';
import 'package:webhtv_pc/ui/config_pages.dart';
import 'package:webhtv_pc/ui/theme.dart';

import 'config_source_status_fixture.dart';

void main() {
  final phase = Platform.environment['CONFIG_SOURCE_CAPTURE_PHASE'];
  setUpAll(() async {
    final cjk = File('/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc');
    for (final family in ['FixtureCJK', 'Microsoft YaHei UI', 'Noto Sans CJK SC']) {
      await (FontLoader(family)..addFont(cjk.readAsBytes().then(ByteData.sublistView))).load();
    }
    final icons = File('${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
    await (FontLoader('MaterialIcons')..addFont(icons.readAsBytes().then(ByteData.sublistView))).load();
  });

  Future<void> capture(WidgetTester tester, String scenario, Size size, Brightness brightness) async {
    final state = (await tester.runAsync(() => createConfigSourceFixture(scenario)))!;
    addTearDown(state.dispose);
    final boundary = GlobalKey();
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final theme = buildAppTheme(brightness);
    await tester.pumpWidget(MaterialApp(
      theme: theme.copyWith(
        textTheme: theme.textTheme.apply(fontFamily: 'FixtureCJK'),
        primaryTextTheme: theme.primaryTextTheme.apply(fontFamily: 'FixtureCJK'),
        listTileTheme: theme.listTileTheme.copyWith(
          titleTextStyle: theme.listTileTheme.titleTextStyle?.copyWith(fontFamily: 'FixtureCJK'),
          subtitleTextStyle: theme.listTileTheme.subtitleTextStyle?.copyWith(fontFamily: 'FixtureCJK'),
        ),
      ),
      home: RepaintBoundary(key: boundary, child: scenario == 'list'
        ? ConfigPage(state: state)
        : AppShell(state: state, startup: const StartupArguments())),
    ));
    await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 80)));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('家庭配置'), scenario == 'list' ? findsNWidgets(2) : findsNothing);
    if (phase != null) {
      await tester.runAsync(() async {
        final render = boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await render.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final suffix = size.width == 1280 ? scenario : '$scenario-narrow-light';
        final file = File('../../docs/phase9/evidence/screenshots/config-hardening/$phase-$suffix.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
        // ignore: avoid_print
        print('captured ${file.path} (${bytes.lengthInBytes} bytes)');
      });
    }
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  }

  testWidgets('list desktop dark paired capture', (tester) async {
    await capture(tester, 'list', const Size(1280, 950), Brightness.dark);
  });
  testWidgets('startup desktop dark paired capture', (tester) async {
    await capture(tester, 'startup', const Size(1280, 950), Brightness.dark);
  });
  if (phase != 'before') {
    testWidgets('list narrow light smoke', (tester) async {
      await capture(tester, 'list', const Size(780, 950), Brightness.light);
    });
    testWidgets('startup narrow light smoke', (tester) async {
      await capture(tester, 'startup', const Size(1024, 950), Brightness.light);
    });
  }
}
