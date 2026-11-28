import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/following.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/live_service.dart';
import 'package:webhtv_pc/state/search_state.dart';
import 'package:webhtv_pc/ui/following_page.dart';
import 'package:webhtv_pc/ui/glass_surface.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/app.dart';
import 'package:webhtv_pc/ui/app_motion.dart';
import 'package:webhtv_pc/ui/glass_chrome.dart';
import 'package:webhtv_pc/ui/startup_arguments.dart';
import 'package:webhtv_pc/ui/theme.dart';

import 'support/detail_test_seams.dart';
import 'support/widget_settle.dart';
import 'support/test_fonts.dart';

class _State extends AppState {
  _State({required super.paths})
    : super(log: MemoryOnlyLogService(), liveService: _Lives());

  String? wallpaper;
  final fixtureSite = Site(
    key: 'test',
    name: '测试站',
    type: 1,
    api: 'https://fixture.test/api',
  );
  final fixtureVods = List.generate(
    48,
    (i) => Vod(vodId: 'v$i', vodName: '测试影片 $i'),
  );
  @override
  AppConfig? get config =>
      AppConfig(sites: [fixtureSite], wallpaper: wallpaper);
  @override
  bool get hasConfig => true;
  @override
  Site? get selectedSite => fixtureSite;
  @override
  bool get externalMetaEnabled => false;
  @override
  SiteResult? get homeResult => SiteResult(
    classes: const [VodClass(typeId: 'one', typeName: '电影')],
    list: fixtureVods,
  );
  @override
  void enterCurrentVod() {}
  @override
  List<LiveSource> get liveSources =>
      List.generate(64, (i) => LiveSource(name: '信号 $i', type: 2));
  @override
  List<Following> get followings => List.generate(
    24,
    (i) => Following(
      seriesKey: 'series$i',
      season: 1,
      siteKey: 'test',
      vodId: 'v$i',
      vodName: '测试追剧 $i',
    ),
  );
  @override
  Future<void> loadHome(Site site) async {}
  @override
  MultiSiteSearchOutcome? activeSearch;
  @override
  Future<MultiSiteSearchOutcome> searchAll(
    String keyword, {
    String? siteKey,
    String? group,
    int? maxConcurrency,
    Duration timeout = const Duration(seconds: 20),
    bool quick = false,
  }) async {
    final outcome = MultiSiteSearchOutcome(
      runId: 1,
      keyword: keyword,
      results: [
        SiteSearchEntry(
          siteKey: fixtureSite.key,
          siteName: fixtureSite.name,
          result: SiteResult(list: fixtureVods),
        ),
      ],
    );
    outcome.finished = true;
    activeSearch = outcome;
    notifyListeners();
    return outcome;
  }

  @override
  Future<void> startupConfigRefresh() async {}

  @override
  Future<void> maybeAutoCheckForUpdates() async {}
}

class _Lives extends LiveService {
  @override
  Future<LiveLoadResult> load(
    LiveSource source, {
    bool useCache = true,
  }) async => LiveLoadResult(
    playlist: LivePlaylist(
      sourceName: source.name,
      groups: [
        LiveGroup(
          name: '测试频道',
          channels: List.generate(
            64,
            (i) => LiveChannel(
              name: '频道 $i',
              urls: ['https://fixture.test/live/$i'],
            ),
          ),
        ),
      ],
    ),
    source: source,
    latency: Duration.zero,
  );
}

void main() {
  setUpAll(() async {
    await loadFixtureFonts();
    final cjk = firstExisting(cjkFontCandidates());
    if (cjk == null) return;
    final bytes = ByteData.sublistView(await cjk.readAsBytes());
    for (final family in ['Roboto', 'Microsoft YaHei UI', 'Noto Sans CJK SC']) {
      await (FontLoader(family)..addFont(Future.value(bytes))).load();
    }
  });
  testWidgets('七页下穿、固定控件和壁纸门控几何稳定', (tester) async {
    final temp = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('shell-underlap'),
    ))!;
    final paths = AppPaths.resolve(
      overrides: {
        'config': '${temp.path}/config',
        'cache': '${temp.path}/cache',
        'data': '${temp.path}/data',
        'state': '${temp.path}/state',
      },
    );
    final state = _State(paths: paths);
    addTearDown(() async {
      state.dispose();
      await temp.delete(recursive: true);
    });
    await tester.runAsync(() async {
      await state.bootstrap();
      await File('${paths.configDir}/usage-boundary-accepted')
          .writeAsString('test');
      for (var i = 0; i < 48; i++) {
        state.database!.upsertFavorite(
          kind: 'vod',
          siteKey: 'test',
          targetId: 'v$i',
          title: '影片 $i',
        );
        state.database!.upsertHistory(
          siteKey: 'test',
          vodId: 'v$i',
          vodName: '观看记录 $i',
          flag: '线路',
          episodeName: '第1集',
          episodeId: 'e$i',
          positionMs: 1000,
          durationMs: 5000,
          sourceKey: state.activeSourceKey,
        );
      }
    });
    tester.view.physicalSize = const Size(1440, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final captureKey = GlobalKey();
    final theme = buildAppTheme(Brightness.light);
    Future<void> mount() => tester.pumpWidget(
      RepaintBoundary(
        key: captureKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme.copyWith(
            textTheme: theme.textTheme.apply(fontFamily: 'FixtureCJK'),
            primaryTextTheme: theme.primaryTextTheme.apply(
              fontFamily: 'FixtureCJK',
            ),
          ),
          home: AppShell(state: state, startup: const StartupArguments()),
        ),
      ),
    );
    await mount();
    await settle(tester);
    await tester.tap(find.text('收藏'));
    await settle(tester);
    final bar = find.byType(GlassTopBar);
    final content = find.byType(AppShellTransition);
    final grid = find.byKey(const ValueKey('favorites-grid'));
    final viewport = find.descendant(of: grid, matching: find.byType(Viewport));
    final card = find
        .byWidgetPredicate(
          (widget) =>
              widget.key is ValueKey<String> &&
              (widget.key as ValueKey<String>).value.startsWith(
                'favorite-card-',
              ),
        )
        .first;
    final cardKey = tester.widget(card).key!;
    final firstCard = find.byKey(cardKey);
    expect(tester.getTopLeft(content).dy, 0);
    expect(tester.getTopLeft(viewport).dy, 0);
    final start = tester.getTopLeft(firstCard).dy;
    expect(start, greaterThan(kGlassTopBarHeight));
    final scrollable = tester.state<ScrollableState>(
      find.descendant(of: grid, matching: find.byType(Scrollable)),
    );
    scrollable.position.jumpTo(start - 1);
    await tester.pump();
    expect(tester.getTopLeft(firstCard).dy, lessThan(kGlassTopBarHeight));
    expect(tester.getBottomLeft(bar).dy, kGlassTopBarHeight);
    final hit = tester.hitTestOnBinding(const Offset(705, 24));
    expect(
      hit.path.any(
        (entry) =>
            entry.target ==
            tester.renderObject(
              find.byKey(const ValueKey('shell-top-bar-hit-region')),
            ),
      ),
      isTrue,
    );
    expect(
      hit.path.any((entry) => entry.target == tester.renderObject(viewport)),
      isFalse,
    );

    final shots = Directory(
      '../../.superpowers/sdd/2026-11-26-style-spike/layout-2/captures',
    );
    final probes = <String, Object?>{};
    Future<void> capture(String key) async {
      if (Platform.environment['CAPTURE_SHELL_UNDERLAP'] != '1') return;
      await tester.runAsync(() async {
        await shots.create(recursive: true);
        final boundary =
            captureKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await boundary.toImage();
        try {
          final bytes = (await image.toByteData(
            format: ui.ImageByteFormat.png,
          ))!;
          await File('${shots.path}/$key.png')
              .writeAsBytes(bytes.buffer.asUint8List());
        } finally {
          image.dispose();
        }
      });
    }

    Finder key(String value) => find.byKey(ValueKey(value));
    Finder prefix(String value) => find.byWidgetPredicate(
      (widget) =>
          widget.key is ValueKey<String> &&
          (widget.key as ValueKey<String>).value.startsWith(value),
    );
    final scenarios = [
      (
        id: 'browse',
        label: '点播',
        fixed: key('browse-tab-default'),
        scroll: find.byType(CustomScrollView),
        item: prefix('vod-card-'),
      ),
      (
        id: 'live',
        label: '直播',
        fixed: find.textContaining('未声明 EPG 地址'),
        scroll: key('live-channel-list'),
        item: find.textContaining(RegExp(r'^频道 \d+$')),
      ),
      (
        id: 'search',
        label: '搜索',
        fixed: key('search-input'),
        scroll: key('search-result-list'),
        item: prefix('search-result-test-'),
      ),
      (
        id: 'history',
        label: '最近观看',
        fixed: find.byType(TextField),
        scroll: key('history-grid'),
        item: prefix('history-row-'),
      ),
      (
        id: 'favorites',
        label: '收藏',
        fixed: key('favorites-delete-switch'),
        scroll: key('favorites-grid'),
        item: prefix('favorite-card-'),
      ),
      (
        id: 'following',
        label: '追剧',
        fixed: key('following-check-all'),
        scroll: key('following-list'),
        item: find.byType(FollowingCard),
      ),
      (
        id: 'settings',
        label: '设置',
        fixed: key('settings-category-preferences'),
        scroll: key('settings-category-content-maintenance'),
        item: key('settings-python-environment-open'),
      ),
    ];
    final picture = (await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      for (var i = 0; i < 16; i++) {
        canvas.drawRect(
          Rect.fromLTWH(i * 8.0, 0, 8, 80),
          Paint()
            ..color = i.isEven
                ? const Color(0xff8da6c9)
                : const Color(0xffffdcc3),
        );
      }
      final picture = recorder.endRecording();
      try {
        return await picture.toImage(128, 80);
      } finally {
        picture.dispose();
      }
    }))!;
    addTearDown(picture.dispose);
    final glass = find.descendant(of: bar, matching: find.byType(GlassSurface));
    for (final scene in scenarios) {
      debugPrint('underlap scene: ${scene.id}');
      final nav = find.descendant(
        of: find.byType(NavigationRail),
        matching: find.text(scene.label),
      );
      await tester.ensureVisible(nav);
      await tester.tap(nav.hitTestable());
      await settle(tester);
      if (scene.id == 'search') {
        await tester.enterText(scene.fixed, '测试影片');
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await settle(tester);
      }
      if (scene.id == 'settings') {
        await tester.tap(key('settings-category-maintenance'));
        await settle(tester);
      }
      final fixed = scene.fixed.first;
      final fixedRect = tester.getRect(fixed);
      expect(
        fixedRect.top,
        greaterThanOrEqualTo(kShellContentTopInset),
        reason: scene.id,
      );
      final area = scene.scroll.first;
      final viewport = find.descendant(
        of: area,
        matching: find.byType(Viewport),
      );
      expect(tester.getTopLeft(viewport.first).dy, 0, reason: scene.id);
      final secondaryRow = switch (scene.id) {
        'live' => find.text('信号 0'),
        'search' => key('search-site-all'),
        _ => null,
      };
      if (secondaryRow != null) {
        final secondaryList = find.ancestor(
          of: secondaryRow,
          matching: find.byType(ListView),
        );
        final secondaryViewport = find.descendant(
          of: secondaryList,
          matching: find.byType(Viewport),
        );
        expect(tester.getTopLeft(secondaryViewport).dy, 0, reason: scene.id);
        expect(
          tester
              .widget<ListView>(secondaryList)
              .padding!
              .resolve(TextDirection.ltr)
              .top,
          greaterThanOrEqualTo(kShellContentTopInset),
          reason: scene.id,
        );
      }
      final scroll = tester.state<ScrollableState>(
        find.descendant(of: area, matching: find.byType(Scrollable)).first,
      );
      final item = scene.item.first;
      final stableItem = tester.widget(item).key == null
          ? item
          : find.byKey(tester.widget(item).key!);
      final itemRect = tester.getRect(stableItem);
      expect(
        itemRect.top,
        greaterThanOrEqualTo(kShellContentTopInset),
        reason: scene.id,
      );
      expect(glass, findsOneWidget);
      final url = 'https://fixture.test/${scene.id}.png';
      final provider = NetworkImage(url);
      final frame = Completer<ImageInfo>();
      final cache = PaintingBinding.instance.imageCache;
      cache.putIfAbsent(
        provider,
        () => OneFrameImageStreamCompleter(frame.future),
      );
      addTearDown(() => cache.evict(provider));
      state.wallpaper = url;
      await mount();
      await settle(tester);
      expect(glass, findsOneWidget);
      expect(tester.getRect(fixed), fixedRect, reason: scene.id);
      expect(tester.getRect(stableItem), itemRect, reason: scene.id);
      frame.complete(ImageInfo(image: picture.clone()));
      await settle(tester);
      expect(glass, findsOneWidget, reason: scene.id);
      expect(tester.getRect(fixed), fixedRect, reason: scene.id);
      expect(tester.getRect(stableItem), itemRect, reason: scene.id);
      await capture('${scene.id}-top');
      final max = scroll.position.maxScrollExtent;
      expect(max, greaterThan(0), reason: scene.id);
      final needed = itemRect.top - kShellContentTopInset + 32;
      scroll.position.jumpTo(needed.clamp(0, max).toDouble());
      await tester.pump();
      final crossed = tester.getTopLeft(stableItem).dy;
      expect(crossed, lessThan(kShellContentTopInset), reason: scene.id);
      expect(tester.getRect(fixed), fixedRect, reason: scene.id);
      await capture('${scene.id}-underlap');
      scroll.position.jumpTo(max);
      await settle(tester);
      final bottom = scroll.position.pixels;
      expect(scroll.position.extentAfter, 0, reason: scene.id);
      expect(tester.getRect(fixed), fixedRect, reason: scene.id);
      expect(fixed.hitTestable(), findsOneWidget, reason: scene.id);
      final lastItem = scene.id == 'settings'
          ? key('settings-spider-debug-log')
          : scene.item.last;
      final lastRect = tester.getRect(lastItem);
      expect(
        lastRect.top,
        greaterThanOrEqualTo(kShellContentTopInset),
        reason: scene.id,
      );
      expect(
        lastRect.bottom,
        lessThanOrEqualTo(tester.view.physicalSize.height),
        reason: scene.id,
      );
      state.wallpaper = null;
      await mount();
      await settle(tester);
      expect(glass, findsOneWidget, reason: scene.id);
      expect(scroll.position.pixels, bottom, reason: scene.id);
      expect(tester.getRect(fixed), fixedRect, reason: scene.id);
      probes[scene.id] = {
        'fixedTop': fixedRect.top,
        'initialItemTop': itemRect.top,
        'scrolledItemTop': crossed,
        'maxScroll': bottom,
        'lastItemBottom': lastRect.bottom,
        'gateGeometryStable': true,
      };
    }
    if (Platform.environment['CAPTURE_SHELL_UNDERLAP'] == '1') {
      await tester.runAsync(
        () => File('${shots.parent.path}/probes.json')
            .writeAsString(const JsonEncoder.withIndent('  ').convert(probes)),
      );
    }
  });
}
