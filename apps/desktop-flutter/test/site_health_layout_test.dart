import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/site_service.dart';
import 'package:webhtv_pc/services/storage.dart';
import 'package:webhtv_pc/ui/diagnostics_pages.dart';
import 'package:webhtv_pc/ui/source_field.dart';
import 'package:webhtv_pc/ui/theme.dart';

import 'site_self_check_panel_test.dart' show HealthState, serviceFor;
import 'site_self_check_test.dart' show ProbeRuntime, ProbeRouter;
import 'support/test_fonts.dart';

class _RecordedHealthState extends HealthState {
  _RecordedHealthState(ProbeRuntime runtime, int count)
    : super(
        serviceFor(runtime, [
          for (var i = 0; i < count; i++)
            Site(
              key: i.toRadixString(16).padLeft(32, '0'),
              name: i == 1 ? '有很长名称的示例站点，需要完整名称才能区分来源' : '示例站点 $i',
              type: 1,
              api: 'https://fixture.invalid/api',
            ),
        ]),
      );

  @override
  List<SiteHealth> siteHealth() => [
    for (var i = 0; i < current.appConfig.sites.length; i++)
      SiteHealth(
        siteKey: current.appConfig.sites[i].key,
        homeOk: i < 10 ? 16 : 0,
        homeTotal: 16,
        categoryOk: i < 10 ? 27 : 0,
        categoryTotal: 28,
        detailOk: i < 10 ? 24 : 0,
        detailTotal: 26,
        playOk: i < 10 ? 3 : 0,
        playTotal: 3,
        avgLatencyMs: 1520 + i,
        lastError: i < 10 ? null : '请求失败：远端拒绝当前请求，请检查站点配置与网络连接后重试。',
        updatedAt: DateTime(2026, 11, 24),
      ),
  ];
}

class _DatabaseHealthState extends HealthState {
  _DatabaseHealthState(super.current, this.database);
  @override
  final AppDatabase database;

  @override
  List<SiteHealth> siteHealth() => database.siteHealth();
}

Future<GlobalKey> _mount(
  WidgetTester tester, {
  Size size = const Size(1280, 806),
  Brightness brightness = Brightness.dark,
  ProbeRuntime? runtime,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final state = _RecordedHealthState(runtime ?? ProbeRuntime(), 98);
  addTearDown(state.dispose);
  final base = buildAppTheme(brightness);
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
    textButtonTheme: TextButtonThemeData(
      style: (base.textButtonTheme.style ?? const ButtonStyle()).copyWith(
        textStyle: WidgetStatePropertyAll(
          base.textTheme.labelLarge?.copyWith(fontFamily: 'FixtureCJK'),
        ),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: (base.filledButtonTheme.style ?? const ButtonStyle()).copyWith(
        textStyle: WidgetStatePropertyAll(
          base.textTheme.labelLarge?.copyWith(fontFamily: 'FixtureCJK'),
        ),
      ),
    ),
  );
  final key = GlobalKey();
  await tester.pumpWidget(
    RepaintBoundary(
      key: key,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: theme,
        home: SiteHealthPage(state: state),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return key;
}

void main() {
  setUpAll(loadFixtureFonts);
  testWidgets(
    'returning from a completed check refreshes history from the database',
    (tester) async {
      final database = AppDatabase.inMemory();
      final runtime = ProbeRuntime()
        ..onHome = (_, _) async => SiteResult(
          classes: const [VodClass(typeId: '1', typeName: '电影')],
          list: [Vod(vodId: 'home', vodName: '首页内容')],
        );
      final router = ProbeRouter(runtime);
      final station = Site(
        key: 'fresh',
        name: '刚体检的站点',
        type: 1,
        api: 'https://fixture.invalid',
      );
      final service = SiteService(
        appConfig: AppConfig(sites: [station]),
        router: router,
        database: database,
      );
      final state = _DatabaseHealthState(service, database);
      addTearDown(state.dispose);
      addTearDown(database.dispose);
      addTearDown(router.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.dark),
          home: SiteHealthPage(state: state),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('还没有调用记录'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('site-health-self-check-open')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('self-check-select-all')));
      await tester.pump();
      await tester.ensureVisible(
        find.byKey(const ValueKey('self-check-start')),
      );
      await tester.tap(find.byKey(const ValueKey('self-check-start')));
      await tester.pumpAndSettle();
      expect(database.siteHealth().single.homeTotal, 1);
      expect(database.siteHealth().single.categoryTotal, 1);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.textContaining('还没有调用记录'), findsNothing);
      expect(find.text('刚体检的站点'), findsOneWidget);
      expect(find.text('1/1 (100%)'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  for (final scenario in [
    (
      name: 'dark-wide',
      size: const Size(1280, 806),
      brightness: Brightness.dark,
    ),
    (
      name: 'light-narrow',
      size: const Size(640, 720),
      brightness: Brightness.light,
    ),
  ]) {
    testWidgets('capture populated health page ${scenario.name}', (
      tester,
    ) async {
      final key = await _mount(
        tester,
        size: scenario.size,
        brightness: scenario.brightness,
      );
      expect(find.text('逐站明细'), findsOneWidget);
      expect(tester.takeException(), isNull);
      final phase = Platform.environment['HEALTH_LAYOUT_CAPTURE'];
      if (phase != null) {
        await tester.runAsync(() async {
          final boundary =
              key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final path = '../../.local/health-layout-$phase-${scenario.name}.png';
          await File(path).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets(
    'manual check is reachable without scrolling through 98 records',
    (tester) async {
      final runtime = ProbeRuntime();
      await _mount(tester, runtime: runtime);
      final open = find.byKey(const ValueKey('site-health-self-check-open'));
      expect(open.hitTestable(), findsOneWidget);
      expect(runtime.homes, isEmpty);
      await tester.drag(find.byType(ListView).first, const Offset(0, -700));
      await tester.pumpAndSettle();
      expect(open.hitTestable(), findsOneWidget);
      await tester.tap(open);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('self-check-select-all')).hitTestable(),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('self-check-start')).hitTestable(),
        findsOneWidget,
      );
      expect(runtime.homes, isEmpty);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(open.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'wide health page uses available width and fits all seven headers',
    (tester) async {
      await _mount(tester);
      expect(tester.getSize(find.byType(SourceField)).width, greaterThan(1180));
      for (final label in ['站点', '首页', '分类', '详情', '播放', '平均耗时', '最近错误']) {
        final rect = tester.getRect(find.text(label).first);
        expect(rect.left, greaterThanOrEqualTo(24), reason: label);
        expect(rect.right, lessThanOrEqualTo(1256), reason: label);
      }
      expect(find.text('示例站点 0'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'narrow table exposes a top scrollbar and all offscreen fields remain reachable',
    (tester) async {
      await _mount(
        tester,
        size: const Size(640, 720),
        brightness: Brightness.light,
      );
      await tester.ensureVisible(find.text('逐站明细'));
      await tester.pumpAndSettle();
      final scrollbar = tester.widget<Scrollbar>(
        find.byKey(const ValueKey('site-health-table-scrollbar')),
      );
      expect(scrollbar.thumbVisibility, isTrue);
      expect(scrollbar.scrollbarOrientation, ScrollbarOrientation.top);
      expect(scrollbar.controller!.position.maxScrollExtent, greaterThan(0));
      scrollbar.controller!.jumpTo(
        scrollbar.controller!.position.maxScrollExtent,
      );
      await tester.pumpAndSettle();
      final rect = tester.getRect(find.text('最近错误'));
      expect(rect.left, greaterThanOrEqualTo(24));
      expect(rect.right, lessThanOrEqualTo(616));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
