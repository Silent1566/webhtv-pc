import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/session_recovery.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/config_source_status.dart';
import 'package:webhtv_pc/services/storage.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/app.dart';
import 'package:webhtv_pc/ui/app_motion.dart';
import 'package:webhtv_pc/ui/config_source_status_view.dart';
import 'package:webhtv_pc/ui/glass_chrome.dart';
import 'package:webhtv_pc/ui/recovery_banner.dart';
import 'package:webhtv_pc/ui/startup_arguments.dart';
import 'package:webhtv_pc/ui/theme.dart';

import 'support/detail_test_seams.dart';
import 'support/test_fonts.dart';
import 'support/widget_settle.dart';

class _NoticeState extends AppState {
  _NoticeState({required super.paths}) : super(log: MemoryOnlyLogService());

  String siteName = '测试站';
  String? configName;

  @override
  ConfigRecord? get activeRecord => configName == null
      ? null
      : ConfigRecord(
          id: 1,
          name: configName!,
          origin: '/fixture/config.json',
          updatedAt: DateTime(2026),
          siteCount: 1,
          liveCount: 0,
        );
  Site get site => Site(
    key: 'notice-fixture',
    name: siteName,
    type: 1,
    api: 'https://fixture.invalid/api',
  );
  ConfigSourceStatus? sourceWarning;
  bool withPosters = false;

  @override
  AppConfig? get config => AppConfig(sites: [site]);
  @override
  bool get hasConfig => true;
  @override
  Site? get selectedSite => site;
  @override
  bool get externalMetaEnabled => false;
  @override
  SiteResult? get homeResult => SiteResult(
    classes: const [
      VodClass(typeId: 'movie', typeName: '电影'),
      VodClass(typeId: 'series', typeName: '电视剧'),
    ],
    list: withPosters
        ? List.generate(
            48,
            (index) => Vod(vodId: 'v$index', vodName: '影片 $index'),
          )
        : const [],
  );
  @override
  ConfigSourceStatus? get restoredConfigSourceStatus => sourceWarning;

  @override
  void dismissRestoredConfigSourceWarning() {
    sourceWarning = null;
    notifyListeners();
  }

  void showSourceWarning({bool long = false}) {
    sourceWarning = ConfigSourceStatus(
      recordId: 1,
      name: long ? List.filled(18, '本地配置来源已移动，请恢复文件').join('；') : '本地配置',
      availability: ConfigSourceAvailability.missing,
    );
    notifyListeners();
  }

  @override
  void enterCurrentVod() {}
  @override
  Future<void> loadHome(Site site) async {}
  @override
  Future<void> startupConfigRefresh() async {}
  @override
  Future<void> maybeAutoCheckForUpdates() async {}
}

void main() {
  late Directory temp;
  late _NoticeState state;
  final capture = GlobalKey();
  const phase = String.fromEnvironment('NOTICE_CAPTURE_PHASE');
  final evidence = Platform.environment['NOTICE_EVIDENCE'];

  setUpAll(() async {
    await loadFixtureFonts();
    final cjk = firstExisting(cjkFontCandidates());
    if (cjk == null) return;
    final bytes = ByteData.sublistView(await cjk.readAsBytes());
    for (final family in ['Roboto', 'Microsoft YaHei UI', 'Noto Sans CJK SC']) {
      await (FontLoader(family)..addFont(Future.value(bytes))).load();
    }
  });

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('startup-notice-');
    state = _NoticeState(
      paths: AppPaths.resolve(
        overrides: {
          'config': '${temp.path}/config',
          'cache': '${temp.path}/cache',
          'data': '${temp.path}/data',
          'state': '${temp.path}/state',
        },
      ),
    );
  });

  tearDown(() async {
    state.dispose();
    await temp.delete(recursive: true);
  });

  Future<void> mount(
    WidgetTester tester, {
    bool recovery = false,
    bool crashLog = false,
    Size size = const Size(1280, 800),
    double textScale = 1,
    Brightness brightness = Brightness.dark,
  }) async {
    await tester.runAsync(() async {
      if (recovery) {
        final marker = SessionMarker(
          version: SessionMarker.formatVersion,
          pid: -1,
          startedAtMs: DateTime.now().millisecondsSinceEpoch,
          appVersion: 'fixture',
          playback: const SessionPlaybackContext(
            siteKey: 'notice-fixture',
            vodId: 'movie-1',
            vodName: '测试影片',
            flag: '测试线路',
            episodeName: '第1集',
            episodeId: 'e1',
            positionMs: 1000,
            durationMs: 60000,
            updatedAtMs: 0,
          ),
        );
        final data = Directory(state.paths.dataDir)
          ..createSync(recursive: true);
        await File('${data.path}/session.json')
            .writeAsString(jsonEncode(marker.toJson()));
        if (crashLog) {
          await File('${data.path}/crash.log')
              .writeAsString('fixture crash log');
        }
      }
      await state.bootstrap();
      await File('${state.paths.configDir}/usage-boundary-accepted')
          .writeAsString('fixture');
    });
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final theme = buildAppTheme(brightness);
    await tester.pumpWidget(
      RepaintBoundary(
        key: capture,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme.copyWith(
            textTheme: theme.textTheme.apply(fontFamily: 'FixtureCJK'),
            primaryTextTheme: theme.primaryTextTheme.apply(
              fontFamily: 'FixtureCJK',
            ),
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: AppShell(state: state, startup: const StartupArguments()),
        ),
      ),
    );
    await settle(tester);
  }

  Future<void> shot(WidgetTester tester, String name) async {
    if (evidence == null || phase.isEmpty) return;
    await tester.runAsync(() async {
      final boundary =
          capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      await File('$evidence/$name-$phase.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
    });
  }

  Finder rail(String label) => find.descendant(
    of: find.byType(NavigationRail),
    matching: find.text(label),
  );

  Finder notices() => find
      .ancestor(
        of: find.byType(RecoveryBanner).evaluate().isNotEmpty
            ? find.byType(RecoveryBanner)
            : find.byType(RestoredConfigSourceBanner),
        matching: find.byType(SingleChildScrollView),
      )
      .first;

  void expectUncovered(WidgetTester tester, Finder control, Finder banner) {
    final controlRect = tester.getRect(control);
    final bannerRect = tester.getRect(banner);
    debugPrint('notice-layout control=$controlRect; notice=$bannerRect');
    expect(
      {
        'rectangles overlap': controlRect.overlaps(bannerRect),
        'control receives hit': control.hitTestable().evaluate().isNotEmpty,
      },
      {'rectangles overlap': false, 'control receives hit': true},
      reason: 'control=$controlRect; notice=$bannerRect',
    );
  }

  testWidgets(
    'recovery notice leaves recent-history toolbar visible and hittable',
    (tester) async {
      await mount(tester, recovery: true, crashLog: true);
      expect(state.pendingRecovery, isNotNull);
      await tester.tap(rail('最近观看'));
      await settle(tester);
      await shot(tester, 'history-recovery-1280x800-dark');
      final toolbar = find.byKey(const ValueKey('history-viewing-report'));
      expectUncovered(tester, toolbar, find.byType(RecoveryBanner));
      final input = find.byType(TextField).first;
      await tester.tap(input);
      await tester.enterText(input, '仍可搜索');
      final inputState = tester.state(find.byType(EditableText).first);
      expect(
        tester
            .widget<EditableText>(find.byType(EditableText).first)
            .controller
            .text,
        '仍可搜索',
      );
      await tester.tap(find.byKey(const ValueKey('recovery-show-log')));
      await settle(tester);
      expect(find.text('崩溃日志（最近一段）'), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('recovery-dismiss')));
      await settle(tester);
      expect(find.byType(RecoveryBanner), findsNothing);
      expect(state.pendingRecovery, isNull);
      expect(tester.state(find.byType(EditableText).first), same(inputState));
      expect(
        tester
            .widget<EditableText>(find.byType(EditableText).first)
            .controller
            .text,
        '仍可搜索',
      );
      expect(tester.getTopLeft(find.byType(AppShellTransition)).dy, 0);
      expect(tester.getTopLeft(input).dy, 76);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'config notice leaves browse category bar hittable and dismissal restores geometry',
    (tester) async {
      await mount(tester);
      await tester.tap(rail('点播'));
      await settle(tester);
      final category = find.byKey(const ValueKey('browse-tab-movie'));
      final original = tester.getRect(category);
      final topbar = tester.getRect(find.byType(GlassTopBar));
      final navigation = tester.getRect(find.byType(NavigationRail));
      await shot(tester, 'browse-normal-1280x800-dark');
      state.showSourceWarning();
      await settle(tester);
      await shot(tester, 'browse-config-1280x800-dark');
      expectUncovered(
        tester,
        category,
        find.byType(RestoredConfigSourceBanner),
      );
      expect(tester.getRect(find.byType(GlassTopBar)), topbar);
      expect(tester.getRect(find.byType(NavigationRail)), navigation);
      await tester.tap(find.byKey(const ValueKey('config-source-dismiss')));
      await settle(tester);
      expect(find.byType(RestoredConfigSourceBanner), findsNothing);
      expect(tester.getRect(category), original);
      expect(tester.getTopLeft(find.byType(AppShellTransition)).dy, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'notice leaves last browse item reachable and keeps scroll state when closed',
    (tester) async {
      state.withPosters = true;
      state.showSourceWarning();
      await mount(tester);
      await tester.tap(rail('点播'));
      await settle(tester);
      final scroll = find.byType(CustomScrollView);
      final scrollable = find
          .descendant(of: scroll, matching: find.byType(Scrollable))
          .first;
      final scrollState = tester.state<ScrollableState>(scrollable);
      await tester.drag(scroll, const Offset(0, -500));
      await settle(tester);
      expect(scrollState.position.pixels, greaterThan(0));
      scrollState.position.jumpTo(scrollState.position.maxScrollExtent);
      await tester.pump();
      final last = find.byKey(const ValueKey('vod-card-v47'));
      expect(last.hitTestable(), findsOneWidget);
      expect(tester.getRect(last).bottom, lessThanOrEqualTo(800));
      final offset = scrollState.position.pixels;
      await tester.tap(find.byKey(const ValueKey('config-source-dismiss')));
      await settle(tester);
      expect(tester.state<ScrollableState>(scrollable), same(scrollState));
      expect(
        scrollState.position.pixels,
        closeTo(offset.clamp(0, scrollState.position.maxScrollExtent), 0.01),
      );
      expect(last.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final size in [const Size(1024, 640), const Size(720, 600)]) {
    testWidgets(
      'long config and site labels keep titlebar actions reachable at $size with large text',
      (tester) async {
        state.siteName = '真实配置中的长站点名称：纪录片与电视剧播放站点';
        state.configName = '同时保留的很长本地配置名称：包含多个播放站点与直播源';
        await mount(tester, size: size, textScale: 1.6);
        await shot(
          tester,
          'topbar-long-labels-${size.width.toInt()}x${size.height.toInt()}-1.6-dark',
        );
        expect(tester.takeException(), isNull);
        final push = find.byKey(const ValueKey('topbar-push'));
        expect(push.hitTestable(), findsOneWidget);
        expect(tester.getRect(push).right, lessThanOrEqualTo(size.width));
        expect(find.byTooltip('站点：${state.siteName}'), findsOneWidget);
        expect(find.byTooltip('当前配置：${state.configName}'), findsOneWidget);
        expect(
          tester.getRect(find.text('v$appVersion')).right,
          closeTo(size.width - 24, 0.1),
        );
      },
    );
  }

  for (final brightness in Brightness.values) {
    testWidgets(
      'two long notices scroll at 720x600 1.6x text in ${brightness.name}',
      (tester) async {
        state.showSourceWarning(long: true);
        await mount(
          tester,
          recovery: true,
          crashLog: true,
          size: const Size(720, 600),
          textScale: 1.6,
          brightness: brightness,
        );
        await tester.tap(rail('点播'));
        await settle(tester);
        await shot(tester, 'browse-two-long-720x600-1.6-${brightness.name}');
        expect(tester.takeException(), isNull);
        final scroll = notices();
        final viewport = tester.getRect(scroll);
        final category = find.byKey(const ValueKey('browse-tab-movie'));
        expect(
          tester.getRect(category).top,
          greaterThanOrEqualTo(viewport.bottom),
        );
        expect(category.hitTestable(), findsOneWidget);
        expect(viewport.top, kShellContentTopInset);
        expect(
          tester.getRect(find.byType(GlassTopBar)).bottom,
          kShellContentTopInset,
        );
        await tester.drag(scroll, const Offset(0, -1200));
        await settle(tester);
        expect(
          find.byKey(const ValueKey('recovery-show-log')).hitTestable(),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const ValueKey('recovery-dismiss')));
        await settle(tester);
        expect(find.byType(RecoveryBanner), findsNothing);
        await tester.drag(notices(), const Offset(0, -1200));
        await settle(tester);
        await tester.tap(find.byKey(const ValueKey('config-source-dismiss')));
        await settle(tester);
        expect(find.byType(RestoredConfigSourceBanner), findsNothing);
        expect(tester.getTopLeft(find.byType(AppShellTransition)).dy, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
