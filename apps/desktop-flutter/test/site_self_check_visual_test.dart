import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/site_service.dart';
import 'package:webhtv_pc/ui/site_self_check_panel.dart';
import 'package:webhtv_pc/ui/theme.dart';

import 'site_self_check_test.dart' show ProbeRouter, ProbeRuntime, content;
import 'support/test_fonts.dart';

void main() {
  setUpAll(() async {
    await loadFixtureFonts();
  });
  for (final scenario in [
    (
      name: 'light-ready',
      size: const Size(1024, 800),
      brightness: Brightness.light,
      run: false,
      expand: false,
    ),
    (
      name: 'dark-results',
      size: const Size(1024, 900),
      brightness: Brightness.dark,
      run: true,
      expand: true,
    ),
    (
      name: 'narrow-ready',
      size: const Size(420, 860),
      brightness: Brightness.light,
      run: false,
      expand: false,
    ),
    (
      name: 'narrow-long-error',
      size: const Size(420, 860),
      brightness: Brightness.dark,
      run: true,
      expand: true,
    ),
  ]) {
    testWidgets('render ${scenario.name} without overflow', (tester) async {
      tester.view.physicalSize = scenario.size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final sites = [
        Site(key: 'ok', name: '内容示例站', type: 1, api: 'https://fixture.invalid'),
        Site(
          key: 'bad',
          name: '长错误示例站 · 需要检查访问与配置',
          type: 1,
          api: 'https://fixture.invalid',
        ),
        Site(key: 'missing', name: '尚未安装的运行时', type: 3, api: 'csp_fixture'),
      ];
      final runtime = ProbeRuntime()
        ..onHome = (site, _) async {
          if (site.key == 'bad') {
            throw AppError(
              AppErrorKind.siteNetwork,
              '首页请求失败，请检查网络连接或稍后重试。详细原因：远端服务拒绝了当前请求；${List.filled(12, '请检查配置与认证信息。').join()}',
            );
          }
          return SiteResult(
            classes: const [VodClass(typeId: '1', typeName: '电影')],
            list: content().list,
          );
        };
      final router = ProbeRouter(runtime, unavailable: {'missing'});
      addTearDown(router.dispose);
      final service = SiteService(
        appConfig: AppConfig(sites: sites),
        router: router,
      );
      final base = buildAppTheme(scenario.brightness);
      final theme = base.copyWith(
        textTheme: base.textTheme.apply(fontFamily: 'FixtureCJK'),
        primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'FixtureCJK'),
        inputDecorationTheme: base.inputDecorationTheme.copyWith(
          hintStyle:
              (base.inputDecorationTheme.hintStyle ?? base.textTheme.bodyMedium)
                  ?.copyWith(fontFamily: 'FixtureCJK'),
        ),
        appBarTheme: base.appBarTheme.copyWith(
          titleTextStyle: base.appBarTheme.titleTextStyle?.copyWith(
            fontFamily: 'FixtureCJK',
          ),
        ),
        listTileTheme: base.listTileTheme.copyWith(
          titleTextStyle: base.listTileTheme.titleTextStyle?.copyWith(
            fontFamily: 'FixtureCJK',
          ),
          subtitleTextStyle: base.listTileTheme.subtitleTextStyle?.copyWith(
            fontFamily: 'FixtureCJK',
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: base.filledButtonTheme.style?.copyWith(
            textStyle: WidgetStatePropertyAll(
              base.textTheme.labelLarge?.copyWith(
                fontFamily: 'FixtureCJK',
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: base.outlinedButtonTheme.style?.copyWith(
            textStyle: WidgetStatePropertyAll(
              base.textTheme.labelLarge?.copyWith(fontFamily: 'FixtureCJK'),
            ),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: base.textButtonTheme.style?.copyWith(
            textStyle: WidgetStatePropertyAll(
              base.textTheme.labelLarge?.copyWith(fontFamily: 'FixtureCJK'),
            ),
          ),
        ),
      );
      final boundaryKey = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: RepaintBoundary(
            key: boundaryKey,
            child: Scaffold(
              appBar: AppBar(title: const Text('站点健康')),
              body: ListView(
                padding: const EdgeInsets.all(24),
                children: [SiteSelfCheckPanel(service: service, sites: sites)],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      if (scenario.run) {
        await tester.tap(find.byKey(const ValueKey('self-check-select-all')));
        await tester.pump();
        await tester.ensureVisible(
          find.byKey(const ValueKey('self-check-start')),
        );
        await tester.tap(find.byKey(const ValueKey('self-check-start')));
        await tester.pumpAndSettle();
        expect(find.text('内容检查通过'), findsOneWidget);
        expect(find.text('失败'), findsNWidgets(2));
      }
      if (scenario.expand) {
        final row = find.byKey(const ValueKey('self-check-result-bad'));
        final host = find.byType(ListView).first;
        await tester.dragUntilVisible(row, host, const Offset(0, -300));
        await tester.pumpAndSettle();
        await tester.tap(row);
        await tester.pumpAndSettle();
        final error = find.textContaining('首页请求失败');
        await tester.dragUntilVisible(error, host, const Offset(0, -300));
        await tester.pumpAndSettle();
      }
      expect(tester.takeException(), isNull);
      if (Platform.environment['SITE_SELF_CHECK_CAPTURE'] == '1') {
        await tester.runAsync(() async {
          final boundary =
              boundaryKey.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final dir = Directory('../../.local');
          await dir.create(recursive: true);
          await File('${dir.path}/site-self-check-after-${scenario.name}.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.pumpWidget(const SizedBox());
    });
  }
}
