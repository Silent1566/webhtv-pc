import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/ai_config.dart';
import 'package:webhtv_pc/core/detail_recommendation.dart';
import 'package:webhtv_pc/core/external_detail_meta.dart';
import 'package:webhtv_pc/core/external_meta.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/core/meta_source.dart';
import 'package:webhtv_pc/services/ai_completion_client.dart';
import 'package:webhtv_pc/services/ai_content/ai_content_completion.dart';
import 'package:webhtv_pc/services/detail_rating_service.dart';
import 'package:webhtv_pc/services/external_meta_service.dart';
import 'package:webhtv_pc/services/recommendation_feedback_store.dart';
import 'package:webhtv_pc/state/detail_recommendation_state.dart';
import 'package:webhtv_pc/ui/ai_content/ai_recommendation_section.dart';
import 'package:webhtv_pc/ui/tmdb_detail_page.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/push_parser.dart';
import 'package:webhtv_pc/core/home_feed.dart';
import 'package:webhtv_pc/ui/home_hero.dart';
import 'package:webhtv_pc/ui/home_backdrop.dart';
import 'package:webhtv_pc/ui/app.dart';
import 'package:webhtv_pc/ui/ai_content/ai_content_page.dart';
import 'package:webhtv_pc/ui/startup_arguments.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/search_suggest_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/browse_pages.dart';
import 'package:webhtv_pc/ui/detail_comments_section.dart';
import 'package:webhtv_pc/ui/following_page.dart';
import 'package:webhtv_pc/ui/glass_widgets.dart';
import 'package:webhtv_pc/ui/glass_dialog.dart';
import 'package:webhtv_pc/ui/tmdb_widgets.dart' show ContentMenuBorder;
import 'package:webhtv_pc/ui/home_page.dart';
import 'package:webhtv_pc/ui/home_cards.dart';
import 'package:webhtv_pc/ui/library_pages.dart';
import 'package:webhtv_pc/ui/live_page.dart';
import 'package:webhtv_pc/ui/push_detail_page.dart';
import 'package:webhtv_pc/ui/poster_image.dart';
import 'package:webhtv_pc/ui/search_page.dart';
import 'package:webhtv_pc/ui/search_result_view.dart';
import 'package:webhtv_pc/state/search_state.dart';
import 'package:webhtv_pc/ui/tmdb_detail_view.dart';
import 'package:webhtv_pc/core/tmdb_config.dart';
import 'package:webhtv_pc/core/tmdb_media.dart';
import 'package:webhtv_pc/services/tmdb_service.dart';
import 'package:webhtv_pc/ui/theme.dart';
import 'package:webhtv_pc/ui/viewing_report_page.dart';
import 'package:webhtv_pc/ui/wallpaper_backdrop.dart';

import 'support/detail_test_seams.dart';
import 'support/test_fonts.dart';
import 'viewing_report_v2_fixture.dart';

const _font = 'FixtureCJK';
final _captureDir = Platform.environment['GLASS_CONTENT_CAPTURE'];
final _capturePhase = Platform.environment['GLASS_CAPTURE_PHASE'];
final _librarySize = Platform.environment['GLASS_LIBRARY_WIDE'] == '1'
    ? const Size(1271, 660)
    : const Size(1024, 640);

void _expectUnframedPage<T extends Widget>() {
  final page = find.byType(T);
  expect(page, findsOneWidget);
  expect(
    find.descendant(of: page, matching: find.byType(GlassPane)),
    findsNothing,
    reason: 'Page headers and viewports must not be framed',
  );
}

ThemeData _theme() {
  final theme = buildAppTheme(
    Platform.environment['GLASS_CONTENT_LIGHT'] == '1'
        ? Brightness.light
        : Brightness.dark,
  );
  final text = theme.textTheme.apply(fontFamily: _font);
  final button = WidgetStatePropertyAll(text.labelLarge);
  return theme.copyWith(
    textTheme: text,
    scaffoldBackgroundColor: Colors.transparent,
    inputDecorationTheme: theme.inputDecorationTheme.copyWith(
      labelStyle: text.bodyMedium,
      hintStyle: text.bodyMedium,
      floatingLabelStyle: text.bodySmall,
    ),
    appBarTheme: theme.appBarTheme.copyWith(titleTextStyle: text.titleMedium),
    dialogTheme: theme.dialogTheme.copyWith(
      titleTextStyle: text.titleLarge,
      contentTextStyle: text.bodyMedium,
    ),
    primaryTextTheme: theme.primaryTextTheme.apply(fontFamily: _font),
    filledButtonTheme: FilledButtonThemeData(
      style: theme.filledButtonTheme.style?.copyWith(textStyle: button),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: theme.outlinedButtonTheme.style?.copyWith(textStyle: button),
    ),
    textButtonTheme: TextButtonThemeData(
      style: theme.textButtonTheme.style?.copyWith(textStyle: button),
    ),
    chipTheme: theme.chipTheme.copyWith(
      labelStyle: theme.chipTheme.labelStyle?.copyWith(fontFamily: _font),
      secondaryLabelStyle: theme.chipTheme.secondaryLabelStyle?.copyWith(
        fontFamily: _font,
      ),
    ),
  );
}

Future<void> _capture(
  WidgetTester tester,
  GlobalKey root,
  String scenario,
) async {
  final dir = _captureDir;
  if (dir == null) return;
  expectFontsAvailableOrSkip();
  expect(firstExisting(iconFontCandidates()), isNotNull);
  await tester.runAsync(() async {
    final boundary =
        root.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage();
    try {
      final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      File('$dir/$scenario-$_capturePhase.png')
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        );
    } finally {
      image.dispose();
    }
  });
}

void _expectPanel(Finder content) {
  expect(content, findsWidgets);
  expect(
    find.ancestor(of: content, matching: find.byType(GlassPane)),
    findsWidgets,
  );
}

void _expectUnframed(Finder content) {
  expect(content, findsWidgets);
  expect(
    find.ancestor(of: content, matching: find.byType(GlassPane)),
    findsNothing,
    reason: 'homepage copy and content rails belong on the shared backdrop, not a framed panel',
  );
}

void _expectCommentContrast(
  WidgetTester tester,
  String text,
  Color background,
) {
  final foreground = tester.widget<Text>(find.text(text)).style!.color!;
  final foregroundLuminance = foreground.computeLuminance();
  final backgroundLuminance = background.computeLuminance();
  final contrast = foregroundLuminance > backgroundLuminance
      ? (foregroundLuminance + .05) / (backgroundLuminance + .05)
      : (backgroundLuminance + .05) / (foregroundLuminance + .05);
  expect(contrast, greaterThanOrEqualTo(4.5), reason: text);
}

void main() {
  late Directory temp;
  late AppState state;
  const artUri = 'https://glass-content.invalid/art.png';
  late List<int> artBytes;
  var populateHotRanks = false;
  var populateBrowse = false;
  var browseHomeRequests = 0;
  final root = GlobalKey();

  setUpAll(() async {
    await loadFixtureFonts(cjkFamily: _font);
    for (final family in [
      'Roboto',
      'Microsoft YaHei UI',
      'Microsoft YaHei',
      'Noto Sans CJK SC',
    ]) {
      await loadFixtureFonts(
        cjkFamily: family,
        iconFamily: 'UnusedFixtureIcons',
      );
    }
    artBytes = await _captureArtwork();
    await loadFixtureFonts(
      cjkFamily: 'monospace',
      iconFamily: 'UnusedFixtureIcons',
    );
  });
  setUp(() async {
    populateHotRanks = false;
    populateBrowse = false;
    browseHomeRequests = 0;
    temp = Directory.systemTemp.createTempSync('glass-content-');
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    state = AppState(
      paths: AppPaths.resolve(
        overrides: {
          'config': '${temp.path}/config',
          'data': '${temp.path}/data',
          'cache': '${temp.path}/cache',
          'state': '${temp.path}/state',
        },
      ),
      log: MemoryOnlyLogService(),
      searchSuggestService: SearchSuggestService(
        client: MockClient((request) async {
          if (populateHotRanks && request.url.path == '/v1/rank') {
            return http.Response(
              jsonEncode({
                'data': [
                  {'title': '漫长的季节', 'cover': artUri, 'doubanscore': '9.4'},
                  {'title': '繁花', 'cover': artUri, 'doubanscore': '8.7'},
                ],
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          return http.Response('[]', 200);
        }),
      ),
      httpClient: MockClient((request) async {
        final query = request.url.queryParameters;
        final category = query['t'];
        if (populateBrowse && category == null && !query.containsKey('ids')) {
          browseHomeRequests++;
        }
        return http.Response(
          jsonEncode({
            'class': [
              {'type_id': '1', 'type_name': '电影'},
              if (populateBrowse)
                for (var i = 2; i <= 23; i++)
                  {'type_id': '$i', 'type_name': '频道 $i'},
            ],
            if (populateBrowse)
              'filters': {
                '1': [
                  {
                    'key': 'class',
                    'name': '剧情',
                    'value': [
                      {'n': '全部', 'v': ''},
                      {'n': '喜剧', 'v': '喜剧'},
                    ],
                  },
                ],
              },
            'list': [
              {
                'vod_id': 'v1',
                'vod_name': populateBrowse && category != null
                    ? '分类样片'
                    : '漫长的季节',
                'vod_pic': artUri,
              },
              {'vod_id': 'v2', 'vod_name': '繁花', 'vod_pic': artUri},
              if (populateBrowse)
                for (var i = 3; i <= 10; i++)
                  {'vod_id': 'v$i', 'vod_name': '测试影片 $i', 'vod_pic': artUri},
            ],
            if (populateBrowse) 'pagecount': 1,
          }),
          200,
          headers: {"content-type": "application/json; charset=utf-8"},
        );
      }),
    );
    await bootstrapWithoutExternalMeta(state);
  });
  tearDown(() {
    debugNetworkImageHttpClientProvider = null;
    state.dispose();
    temp.deleteSync(recursive: true);
  });

  Future<void> mount(
    WidgetTester tester,
    Widget home, {
    Size size = const Size(1280, 800),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: _theme(),
        debugShowCheckedModeBanner: false,
        builder: (context, child) => RepaintBoundary(
          key: root,
          child: WallpaperBackdrop(url: null, builder: (_, _) => child!),
        ),
        home: home,
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
  }

  Scaffold shell(Widget body) =>
      Scaffold(backgroundColor: Colors.transparent, body: body);

  /// File images decode on real I/O; keep that work outside fake-async before capture.
  Future<void> settleArt(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 120)),
      );
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  testWidgets('real shell keeps sidebar, top bar and content glass', (
    tester,
  ) async {
    await tester.runAsync(
      () => File(
        '${state.paths.configDir}${Platform.pathSeparator}usage-boundary-accepted',
      ).writeAsString('test'),
    );
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: _theme(),
        debugShowCheckedModeBanner: false,
        builder: (context, child) => RepaintBoundary(
          key: root,
          child: WallpaperBackdrop(url: null, builder: (_, _) => child!),
        ),
        home: AppShell(state: state, startup: const StartupArguments()),
      ),
    );
    await settleArt(tester);
    expect(find.byType(AppShell), findsOneWidget);
    expect(find.byKey(const ValueKey('home-empty-action')), findsWidgets);
    await _capture(tester, root, 'shell');
  });

  testWidgets('independent AI content tabs have their own glass body', (
    tester,
  ) async {
    final ai = state.aiIntegration;
    await mount(
      tester,
      shell(
        AiContentPage(
          deps: AiContentPageDeps(
            services: AiContentServices(
              recommendation: ai.recommendation,
              title: ai.title,
              group: ai.group,
              ad: ai.ad,
              logDiagnosis: ai.diagnosis,
              profile: ai.profile,
              userData: ai.userData,
            ),
            loadSnapshot: () async => throw StateError('No action requested'),
          ),
        ),
      ),
    );
    _expectPanel(find.text('推荐'));
    _expectPanel(find.text('生成推荐'));
  });

  testWidgets('home onboarding stays unframed and still invokes import', (
    tester,
  ) async {
    var imported = false;
    await mount(
      tester,
      shell(
        HomePage(
          state: state,
          onImportConfig: () => imported = true,
          onOpenBrowse: () {},
          onOpenHistory: () {},
          onOpenFollowing: () {},
          onSearch: (_) {},
        ),
      ),
    );
    final action = find.byKey(const ValueKey('home-empty-action'));
    await _capture(tester, root, 'home');
    await tester.tap(action);
    expect(imported, isTrue);
    _expectUnframed(action);
  });

  testWidgets('home hero copy stays unframed above the page backdrop', (
    tester,
  ) async {
    await mount(
      tester,
      shell(
        HomeHero(
          height: 700,
          paintImage: false,
          items: const [
            HomeItem(
              kind: HomeItemKind.resume,
              key: 'sample',
              title: '漫长的季节',
              overview: '王响与故人们，在桦林追寻一段未完的往事。',
              reason: '继续观看 · 第 2 集',
            ),
          ],
          onPrimary: (_) {},
          onSecondary: (_) {},
        ),
      ),
    );
    await _capture(tester, root, 'home-hero');
    _expectUnframed(find.byKey(const ValueKey('home-hero-primary')));
  });

  testWidgets(
    'decoded artwork visibly underlays home hero and real shell posters',
    (tester) async {
      debugNetworkImageHttpClientProvider = () => _CaptureImageClient(artBytes);
      const item = HomeItem(
        kind: HomeItemKind.resume,
        key: 'art',
        title: '远岸之光',
        backdrop: artUri,
        poster: artUri,
        overview: '一座灯塔，一段穿过海峡的旅程。',
        reason: '继续观看 · 第 2 集',
      );
      await mount(
        tester,
        shell(
          Stack(
            fit: StackFit.expand,
            children: [
              const HomeBackdrop(items: [item], index: 0),
              HomeHero(
                height: 700,
                paintImage: false,
                items: const [item],
                onPrimary: (_) {},
                onSecondary: (_) {},
              ),
            ],
          ),
        ),
      );
      await settleArt(tester);
      expect(
        find.byWidgetPredicate(
          (widget) => widget is RawImage && widget.image != null,
        ),
        findsWidgets,
      );
      _expectUnframed(find.byKey(const ValueKey('home-hero-primary')));
      await _capture(tester, root, 'home-artwork');

      state.database!.upsertFavorite(
        kind: 'vod',
        siteKey: 's',
        targetId: 'v1',
        title: '远岸之光',
        vodPic: artUri,
      );
      await tester.runAsync(
        () => File(
          '${state.paths.configDir}${Platform.pathSeparator}usage-boundary-accepted',
        ).writeAsString('test'),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await mount(
        tester,
        AppShell(state: state, startup: const StartupArguments()),
      );
      await settleArt(tester);
      await tester.tap(find.text('收藏'));
      await settleArt(tester);
      expect(
        find.byWidgetPredicate(
          (widget) => widget is RawImage && widget.image != null,
        ),
        findsWidgets,
      );
      expect(find.text('远岸之光'), findsOneWidget);
      await _capture(tester, root, 'shell-posters');
      debugNetworkImageHttpClientProvider = null;
    },
  );

  testWidgets('home history keeps an unframed scrollable rail', (tester) async {
    state.database!.upsertHistory(
      siteKey: 's',
      vodId: 'v1',
      vodName: '漫长的季节',
      flag: '线路一',
      episodeName: '第 2 集',
      episodeId: 'e2',
      positionMs: 100000,
      durationMs: 2000000,
    );
    await mount(
      tester,
      shell(
        HomePage(
          state: state,
          onImportConfig: () {},
          onOpenBrowse: () {},
          onOpenHistory: () {},
          onOpenFollowing: () {},
          onSearch: (_) {},
        ),
      ),
    );
    final scroll = find
        .descendant(
          of: find.byKey(const ValueKey('home-scroll')),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.byType(HomeRailView),
      400,
      scrollable: scroll,
    );
    await tester.drag(
      find.byKey(const ValueKey('home-scroll')),
      const Offset(0, -350),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await _capture(tester, root, 'home-rail');
    _expectUnframed(find.text('继续观看'));
    _expectUnframed(find.text('暂无可用的高清推荐'));
  });

  testWidgets('browse posters open the source detail and back', (tester) async {
    await tester.runAsync(() async {
      expect(
        await state.importConfig('''
        {"name":"内容测试","sites":[{"key":"s","name":"样片站","type":1,"api":"http://127.0.0.1:19978/vod/api?key=s"}]}
      '''),
        isTrue,
      );
      await state.loadHome(state.selectedSite!);
    });
    await mount(tester, shell(BrowsePage(state: state)));
    final first = find.text('漫长的季节');
    final second = find.text('繁花');
    expect(first, findsOneWidget);
    expect(second, findsOneWidget);
    await settleArt(tester);
    await _capture(tester, root, 'browse');
    await tester.tap(find.byKey(const ValueKey('vod-card-v1')));
    await tester.pumpAndSettle();
    expect(find.byType(DetailPage), findsOneWidget);
    final header = tester.widget<TmdbDetailHeader>(
      find.byType(TmdbDetailHeader),
    );
    expect(header.data.posterUrl, artUri);
    final hero = find.byKey(const ValueKey('tmdb-detail-hero'));
    expect(tester.getSize(hero).height, 800);
    _expectUnframed(find.byKey(const ValueKey('tmdb-detail-title')));
    await _capture(tester, root, 'detail');
    await tester.drag(find.byType(ListView).first, const Offset(0, -600));
    await tester.pumpAndSettle();
    await _capture(tester, root, 'detail-body');
    await tester.tap(find.byTooltip('返回').first);
    await tester.pumpAndSettle();
    expect(first, findsOneWidget);
  });

  testWidgets('detail page sections sit on the page backdrop', (tester) async {
    final vod = Vod(
      vodId: 'detail-unframed',
      vodName: '板块样片',
      vodPic: artUri,
      vodContent: '来源提供的简介。',
      vodPlayFrom: '高清线路',
      vodPlayUrl:
          r'高清线路$第1集$https://fixture.test/1.mp4#第2集$https://fixture.test/2.mp4',
    );
    state.seedDetailForTest(vod: vod);
    debugNetworkImageHttpClientProvider = () => _CaptureImageClient(artBytes);
    try {
      await mount(
        tester,
        DetailPage(state: state, vod: vod),
        size: const Size(1024, 640),
      );
      await tester.pumpAndSettle();
      await settleArt(tester);
      await _capture(tester, root, 'detail-unframed');
      _expectUnframed(find.byKey(const ValueKey('tmdb-detail-title')));
      // 详情页正文不再有页面级玻璃容器（弹层另算）。
      expect(find.byType(GlassPane), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      debugNetworkImageHttpClientProvider = null;
    }
  });

  testWidgets('rich detail routes keep body content unframed', (tester) async {
    final rich = _RichDetailState(state.paths, artUri);
    addTearDown(rich.dispose);
    final vod = rich.vod;
    await tester.runAsync(() async {
      await rich.bootstrap();
      rich.seedDetailForTest(vod: vod);
      await rich.tmdb.loadForVod(vod, siteKey: '');
    });
    debugNetworkImageHttpClientProvider = () => _CaptureImageClient(artBytes);
    try {
      Finder key(String value) => find.byKey(ValueKey(value));
      int bodyPaneCount(Finder route) {
        final scaffold = tester.widget<Scaffold>(
          find.descendant(of: route, matching: find.byType(Scaffold)),
        );
        return (scaffold.body is GlassPane ? 1 : 0) +
            find
                .descendant(
                  of: find.byWidget(scaffold.body!),
                  matching: find.byType(GlassPane),
                )
                .evaluate()
                .length;
      }

      Future<void> reveal(String target, [double alignment = .1]) async {
        final finder = key(target);
        final scroll = tester.state<ScrollableState>(
          find.byType(Scrollable).first,
        );
        for (var i = 0; i < 8 && finder.evaluate().isEmpty; i++) {
          final position = scroll.position;
          position.jumpTo(
            (position.pixels + 340).clamp(0.0, position.maxScrollExtent),
          );
          await tester.pump();
        }
        expect(finder, findsOneWidget);
        await Scrollable.ensureVisible(
          tester.element(finder),
          alignment: alignment,
        );
        await tester.pumpAndSettle();
      }

      Future<void> finishAiRow() async {
        final row = key('recommendation-row-ai');
        await tester.runAsync(() async {
          for (var i = 0; i < 100 && row.evaluate().isEmpty; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
            await tester.pump();
          }
        });
        expect(row, findsOneWidget);
        await tester.pumpAndSettle();
      }

      const size = Size(1024, 640);
      await mount(
        tester,
        DetailPage(state: rich, vod: vod),
        size: size,
      );
      await tester.pumpAndSettle();
      await settleArt(tester);
      await reveal('tmdb-line-selector');
      expect(key('tmdb-line-高清线路'), findsOneWidget);
      await reveal('tmdb-status-matched', .15);
      await _capture(tester, root, 'detail-sections-status-lines');
      await reveal('tmdb-section-videos');
      expect(find.text('样片预告'), findsOneWidget);
      expect(find.text('这段短评保留了原有内边距。'), findsOneWidget);
      await _capture(tester, root, 'detail-sections-middle');
      // Exposed fixture pixels beside the metadata (178, 364) and score (138, 318).
      final light =
          Theme.of(tester.element(key('detail-external-comments')))
              .brightness ==
          Brightness.light;
      _expectCommentContrast(
        tester,
        '观众样片 · 12 有用',
        light ? const Color(0xFFBCCBD8) : const Color(0xFF1C2C3E),
      );
      _expectCommentContrast(
        tester,
        '8.0',
        light ? const Color(0xFFA8B7C4) : const Color(0xFF0B1B2D),
      );
      await finishAiRow();
      await reveal('detail-ratings-section', .95);
      expect(key('detail-ratings-imdb'), findsOneWidget);
      for (final row in RecommendationRow.values) {
        expect(key('recommendation-row-${row.name}'), findsOneWidget);
      }
      final sourcePanes = bodyPaneCount(find.byType(DetailPage));
      await _capture(tester, root, 'detail-sections-bottom');

      // Cast -> person work opens the production pure TMDB route.
      await reveal('tmdb-person-8', .45);
      await tester.tap(key('tmdb-person-8'));
      await tester.pumpAndSettle();
      expect(find.byType(TmdbPersonPage), findsOneWidget);
      expect(key('tmdb-person-biography'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.byType(GlassPane),
        ),
        findsOneWidget,
      );
      await _capture(tester, root, 'detail-sections-person');
      final personPanes = bodyPaneCount(find.byType(TmdbPersonPage));
      await reveal('tmdb-person-work-movie:94', .45);
      await tester.tap(key('tmdb-person-work-movie:94'));
      await tester.pumpAndSettle();
      await reveal('tmdb-section-videos');
      await finishAiRow();
      final fallbackPanes = bodyPaneCount(find.byType(TmdbDetailPage));
      await reveal('recommendation-heading-ai', .1);
      await _capture(tester, root, 'detail-sections-tmdb');

      await tester.pumpWidget(const SizedBox.shrink());
      await mount(
        tester,
        Scaffold(
          body: SingleChildScrollView(
            child: AiRecommendationSection(state: rich, seedTitle: vod.vodName),
          ),
        ),
        size: size,
      );
      await finishAiRow();
      expect(
        find.ancestor(
          of: key('recommendation-section-ai'),
          matching: find.byType(GlassPane),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      expect(
        [sourcePanes, personPanes, fallbackPanes],
        [0, 0, 0],
        reason: 'Source, person and pure TMDB bodies must not have GlassPane with overlays closed',
      );
    } finally {
      debugNetworkImageHttpClientProvider = null;
    }
  });

  testWidgets('unrated detail comment ink meets contrast on exposed backdrop', (
    tester,
  ) async {
    await mount(
      tester,
      shell(
        const ExternalCommentsSection(
          page: ExternalCommentPage(
            comments: [
              ExternalComment(
                source: MetaSourceKind.douban,
                author: '未评分观众',
                text: '未评分样片',
              ),
            ],
            total: 1,
          ),
        ),
      ),
    );
    _expectUnframed(find.text('未评分'));
    final light = _theme().brightness == Brightness.light;
    _expectCommentContrast(
      tester,
      '未评分',
      light ? const Color(0xFFA8B7C4) : const Color(0xFF0B1B2D),
    );
  });

  testWidgets(
    'source detail without artwork shows no-play recovery above fold',
    (tester) async {
      final vod = Vod(
        vodId: 'source-detail-no-art',
        vodName: '无图样片',
        vodContent: '这是来源提供的简介。',
      );
      state.seedDetailForTest(vod: vod);
      await mount(
        tester,
        DetailPage(state: state, vod: vod),
        size: const Size(1024, 640),
      );
      await tester.pumpAndSettle();
      await _capture(tester, root, 'detail-no-art');

      final title = find.byKey(const ValueKey('tmdb-detail-title'));
      final swap = find.byKey(const ValueKey('detail-no-line-swap'));
      final card = find.byKey(const ValueKey('detail-no-line-empty'));
      expect(swap.hitTestable(), findsOneWidget);
      expect(tester.getBottomRight(card).dy, lessThanOrEqualTo(640));
      expect(
        find.text('该影片没有可播放的剧集（vod_play_url 为空）。').hitTestable(),
        findsOneWidget,
      );
      expect(tester.widget<OutlinedButton>(swap).onPressed, isNotNull);
      expect(find.byKey(const ValueKey('detail-hero-play')), findsNothing);
      expect(tester.getTopLeft(title).dy, greaterThanOrEqualTo(56));
      expect(find.text('这是来源提供的简介。').hitTestable(), findsOneWidget);
      _expectUnframed(title);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('search landing sits on the page backdrop, not in panes', (
    tester,
  ) async {
    populateHotRanks = true;
    debugNetworkImageHttpClientProvider = () => _CaptureImageClient(artBytes);
    try {
      await tester.runAsync(() async {
        await state.searchAll('剧集推荐');
      });
      await mount(tester, shell(SearchPage(state: state)));
      await settleArt(tester);
      final input = find.byKey(const ValueKey('search-input'));
      expect(input, findsOneWidget);
      await _capture(tester, root, 'search');
      _expectUnframed(input);
      _expectUnframed(find.text('搜索历史'));
      _expectUnframed(find.text('剧集推荐'));
      _expectUnframed(find.text('热门推荐'));
      // 底色去掉后输入框仍可聚焦，历史词与热门卡仍可点。
      await tester.tap(input);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(input).focusNode?.hasFocus, isTrue);
      await tester.tap(find.text('剧集推荐'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('search-input')), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      debugNetworkImageHttpClientProvider = null;
    }
  });

  testWidgets('focused search label remains visible inside the toolbar', (
    tester,
  ) async {
    await mount(
      tester,
      shell(SearchPage(state: state, shellUnderlap: true)),
      size: const Size(1024, 640),
    );
    final input = find.byKey(const ValueKey('search-input'));
    await tester.tap(input);
    await tester.pumpAndSettle();
    final label = find.descendant(of: input, matching: find.text('搜索影片'));
    final labelRect = tester.getRect(label);
    await _capture(tester, root, 'search-focus');
    // 标签不能被任何祖先裁切框切掉（旧实现被工具条的圆角裁切吃了 5px）。
    final clips = find.ancestor(of: input, matching: find.byType(ClipRRect));
    for (final clip in clips.evaluate()) {
      final rect = tester.getRect(find.byElementPredicate((e) => e == clip));
      expect(
        rect.contains(labelRect.topLeft) &&
            rect.contains(labelRect.bottomRight),
        isTrue,
        reason: 'label $labelRect clipped by $rect',
      );
    }
    expect(labelRect.top, greaterThan(0));
  });

  testWidgets('populated hot rankings stay unframed and keep their cards', (
    tester,
  ) async {
    populateHotRanks = true;
    debugNetworkImageHttpClientProvider = () => _CaptureImageClient(artBytes);
    try {
      await tester.runAsync(() async {
        await state.searchAll('剧集推荐');
      });
      await mount(tester, shell(SearchPage(state: state)));
      await settleArt(tester);
      _expectUnframed(find.text('漫长的季节'));
      _expectUnframed(find.text('搜索历史'));
      await _capture(tester, root, 'search-populated');
    } finally {
      debugNetworkImageHttpClientProvider = null;
    }
  });

  testWidgets('typed search empty body stays unframed before submission', (
    tester,
  ) async {
    await mount(tester, shell(SearchPage(state: state)));
    await tester.enterText(
      find.byKey(const ValueKey('search-input')),
      '无结果关键词',
    );
    await tester.pump(const Duration(milliseconds: 400));
    final hint = find.text('输入关键词开始搜索');
    expect(hint, findsOneWidget);
    _expectUnframed(hint);
  });

  testWidgets('empty search result entry keeps guidance unframed', (
    tester,
  ) async {
    await mount(
      tester,
      shell(
        SearchResultView(
          outcome: MultiSiteSearchOutcome(
            runId: 1,
            keyword: '无结果',
            results: [],
          ),
          keyPrefix: 'empty-search',
          itemKeyOf: (site, vod) => '$site-$vod',
          onTapItem: (_, _) {},
        ),
      ),
    );
    _expectUnframed(find.text('没有搜索结果'));
  });

  // 人物页正文自本轮起也去掉了页面级玻璃面：加载/失败两种状态都直接铺在
  // 页面背景上，顶栏那个 GlassPane 属于外壳，不是正文。
  testWidgets('person loading and failed bodies sit on the page backdrop', (
    tester,
  ) async {
    final response = Completer<http.Response>();
    final service = TmdbService(
      config: () => const TmdbConfig(apiKey: 'k'),
      client: MockClient((_) => response.future),
    );
    await mount(
      tester,
      TmdbPersonPage(
        service: service,
        person: const TmdbPerson(personId: 1, name: '测试人物'),
      ),
    );
    _expectUnframed(find.byType(CircularProgressIndicator));
    response.complete(http.Response('failure', 500));
    await tester.pumpAndSettle();
    _expectUnframed(find.byKey(const ValueKey('tmdb-person-retry')));
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.byType(GlassPane),
      ),
      findsOneWidget,
      reason: '顶栏是小屋外壳，不是正文',
    );
  });

  testWidgets('unframed library: favorites retain open and delete actions', (
    tester,
  ) async {
    debugNetworkImageHttpClientProvider = () => _CaptureImageClient(artBytes);
    for (var i = 1; i <= 10; i++) {
      state.database!.upsertFavorite(
        kind: 'vod',
        siteKey: 's',
        targetId: 'v$i',
        title: i == 10 ? '繁花' : '已收藏影片 $i',
        vodPic: artUri,
        updatedAt: DateTime.utc(2026, 11, 1).millisecondsSinceEpoch + i * 1000,
      );
    }
    await mount(tester, shell(FavoritesPage(state: state)), size: _librarySize);
    final card = find.byKey(const ValueKey('favorite-card-vod-s-v10'));
    expect(card.hitTestable(), findsOneWidget);
    expect(
      find.descendant(of: card, matching: find.byType(PosterImage)),
      findsOneWidget,
    );
    await settleArt(tester);
    await _capture(tester, root, 'library-favorites');
    await tester.tap(card);
    await tester.pumpAndSettle();
    expect(find.byType(DetailPage), findsOneWidget);
    expect(
      tester.widget<DetailPage>(find.byType(DetailPage)).vod.vodName,
      '繁花',
    );
    Navigator.of(tester.element(find.byType(DetailPage))).pop();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('favorites-delete-switch')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('favorite-delete-overlay-vod-s-v10')),
      findsOneWidget,
    );
    await tester.tap(card);
    await tester.pumpAndSettle();
    expect(card, findsNothing);
    expect(find.text('收藏（9）'), findsOneWidget);
    debugNetworkImageHttpClientProvider = null;
    _expectUnframedPage<FavoritesPage>();
  });

  testWidgets('unframed library: history retains progress, search and groups', (
    tester,
  ) async {
    debugNetworkImageHttpClientProvider = () => _CaptureImageClient(artBytes);
    for (var i = 0; i < 18; i++) {
      final grouped = i >= 16;
      state.database!.upsertHistory(
        siteKey: 's',
        vodId: grouped ? 'v1' : 'v$i-other',
        vodName: grouped ? '漫长的季节' : '已观看影片 $i',
        vodPic: artUri,
        updatedAt: DateTime.utc(2026, 11, 1).millisecondsSinceEpoch + i * 1000,
        flag: '线路一',
        episodeName: '第 $i 集',
        episodeId: 'e$i',
        positionMs: 120000,
        durationMs: 240000,
        sourceKey: state.activeSourceKey,
      );
    }
    await mount(tester, shell(HistoryPage(state: state)), size: _librarySize);
    final grid = find.byKey(const ValueKey('history-grid'));
    final search = find.byType(TextField);
    final groupTitle = find.text('漫长的季节');
    expect(groupTitle, findsOneWidget);
    expect(find.text('2 条'), findsOneWidget);
    final progress = tester.widget<LinearProgressIndicator>(
      find
          .descendant(of: grid, matching: find.byType(LinearProgressIndicator))
          .first,
    );
    expect(progress.value, .5);
    await settleArt(tester);
    await _capture(tester, root, 'library-history');
    final searchPosition = tester.getTopLeft(search);
    final scrollable = find.descendant(
      of: grid,
      matching: find.byType(Scrollable),
    );
    await tester.drag(grid, const Offset(0, -240));
    await tester.pumpAndSettle();
    expect(
      tester.state<ScrollableState>(scrollable).position.pixels,
      greaterThan(0),
    );
    expect(tester.getTopLeft(search), searchPosition);
    await tester.enterText(search, '漫长');
    await tester.pumpAndSettle();
    expect(groupTitle, findsOneWidget);
    expect(find.textContaining('已观看影片'), findsNothing);
    final aggregation = find.byKey(
      const ValueKey('history-aggregation-switch'),
    );
    await tester.runAsync(() => tester.tap(aggregation));
    await settleArt(tester);
    expect(groupTitle, findsNWidgets(2));
    expect(find.text('2 条'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('history-viewing-report')));
    await tester.pumpAndSettle();
    expect(find.byType(ViewingReportPage), findsOneWidget);
    Navigator.of(tester.element(find.byType(ViewingReportPage))).pop();
    await tester.pumpAndSettle();
    expect(groupTitle, findsNWidgets(2));
    debugNetworkImageHttpClientProvider = null;
    _expectUnframedPage<HistoryPage>();
  });

  testWidgets(
    'unframed library: browse retains category scroll, focus and reload',
    (tester) async {
      populateBrowse = true;
      debugNetworkImageHttpClientProvider = () => _CaptureImageClient(artBytes);
      await tester.runAsync(() async {
        expect(
          await state.importConfig('''
        {"name":"内容测试","sites":[{"key":"s","name":"样片站","type":1,"api":"http://127.0.0.1:19978/vod/api?key=s","filterable":1}]}
      '''),
          isTrue,
        );
        await state.loadHome(state.selectedSite!);
      });
      await mount(
        tester,
        shell(
          ListenableBuilder(
            listenable: state,
            builder: (_, _) => BrowsePage(state: state),
          ),
        ),
        size: _librarySize,
      );
      final tab = find.byKey(const ValueKey('browse-tab-1'));
      final defaultTab = find.byKey(const ValueKey('browse-tab-default'));
      final categories = find.ancestor(
        of: tab,
        matching: find.byType(SingleChildScrollView),
      );
      final card = find.byKey(const ValueKey('vod-card-v1'));
      expect(card.hitTestable(), findsOneWidget);
      expect(
        find.descendant(of: card, matching: find.byType(PosterImage)),
        findsOneWidget,
      );
      await settleArt(tester);
      await _capture(tester, root, 'library-browse');
      final refresh = find.byKey(const ValueKey('browse-refresh'));
      final homeRequests = browseHomeRequests;
      await tester.tap(refresh);
      await tester.pumpAndSettle();
      expect(browseHomeRequests, greaterThan(homeRequests));
      expect(card.hitTestable(), findsOneWidget);
      final categoryPosition = tester
          .state<ScrollableState>(
            find.descendant(of: categories, matching: find.byType(Scrollable)),
          )
          .position;
      await tester.drag(categories, const Offset(-500, 0));
      await tester.pumpAndSettle();
      expect(categoryPosition.pixels, greaterThan(0));
      categoryPosition.jumpTo(0);
      await tester.pump();
      final label = find.descendant(of: tab, matching: find.text('电影'));
      final focus = Focus.of(tester.element(label));
      FocusManager.instance.primaryFocus?.unfocus();
      for (var i = 0; i < 8 && !focus.hasPrimaryFocus; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
      }
      expect(focus.hasPrimaryFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('分类样片'), findsOneWidget);
      expect(find.byTooltip('刷新当前分类'), findsOneWidget);
      final selected = tester.widget<Text>(
        find.descendant(of: tab, matching: find.text('电影')),
      );
      expect(selected.style?.fontWeight, FontWeight.w600);
      final filter = find.byKey(const ValueKey('category-filter-menu'));
      await tester.tap(filter);
      await tester.pumpAndSettle();
      _expectPanel(find.text('喜剧'));
      await tester.tap(filter);
      await tester.pumpAndSettle();
      await tester.tap(defaultTab);
      await tester.pumpAndSettle();
      expect(find.text('漫长的季节'), findsOneWidget);
      await tester.tap(card);
      await tester.pumpAndSettle();
      expect(find.byType(DetailPage), findsOneWidget);
      Navigator.of(tester.element(find.byType(DetailPage))).pop();
      await tester.pumpAndSettle();
      expect(card.hitTestable(), findsOneWidget);
      debugNetworkImageHttpClientProvider = null;
      _expectUnframedPage<BrowsePage>();
    },
  );

  testWidgets('unframed library: empty pages retain recovery copy', (
    tester,
  ) async {
    await mount(tester, shell(FavoritesPage(state: state)), size: _librarySize);
    expect(find.text('暂无收藏'), findsOneWidget);
    final panes = <int>[find.byType(GlassPane).evaluate().length];
    await mount(tester, shell(HistoryPage(state: state)), size: _librarySize);
    expect(find.text('暂无播放记录'), findsOneWidget);
    panes.add(find.byType(GlassPane).evaluate().length);
    expect(
      find.byKey(const ValueKey('history-viewing-report')).hitTestable(),
      findsOneWidget,
    );
    await mount(tester, shell(BrowsePage(state: state)), size: _librarySize);
    expect(find.text('还没有导入配置'), findsOneWidget);
    panes.add(find.byType(GlassPane).evaluate().length);
    expect(panes, [0, 0, 0], reason: 'Empty pages must also be unframed');
  });

  testWidgets('the following empty state stays unframed', (tester) async {
    await mount(tester, shell(FollowingPage(state: state)));
    expect(find.text('还没有追剧'), findsOneWidget);
    expect(find.byType(GlassPane), findsNothing);
  });

  testWidgets('populated following keeps controls and rows without panels', (
    tester,
  ) async {
    final poster = File('${temp.path}/following-poster.png');
    await tester.runAsync(() => poster.writeAsBytes(artBytes));
    final item = state.followFromDetail(
      site: Site(key: 's', name: '甲站', type: 4, api: 'http://127.0.0.1:1/vod'),
      vod: Vod(vodId: 'v1', vodName: '漫长的季节', vodPic: poster.uri.toString()),
      flag: 'VIP线路',
      sourceFlag: 'VIP线路',
      releasedEpisode: 10,
    )!;
    await mount(
      tester,
      shell(FollowingPage(state: state, shellUnderlap: true)),
      size: const Size(1024, 640),
    );
    await settleArt(tester);
    expect(
      find.byKey(const ValueKey('following-update-summary')),
      findsOneWidget,
    );
    final check = find.byKey(const ValueKey('following-check-all'));
    expect(tester.widget<FilledButton>(check).onPressed, isNotNull);
    expect(
      find.byKey(ValueKey('following-card-${item.identityKey}')),
      findsOneWidget,
    );
    await _capture(tester, root, 'following-list');
    expect(find.byType(GlassPane), findsNothing);
  });

  testWidgets('live empty state keeps guidance unframed', (tester) async {
    await mount(tester, shell(LivePage(state: state)));
    _expectUnframed(find.text('当前配置没有直播源'));
  });

  testWidgets('following settings menu and interval dialog preserve escape', (
    tester,
  ) async {
    await mount(tester, shell(FollowingPage(state: state)));
    await tester.tap(find.byKey(const ValueKey('following-more')));
    await tester.pumpAndSettle();
    final menu = tester
        .widgetList<Material>(find.byType(Material))
        .where((material) => material.shape is ContentMenuBorder);
    expect(menu, isNotEmpty);
    await tester.tap(find.byKey(const ValueKey('following-interval')));
    await tester.pumpAndSettle();
    expect(find.byType(GlassAlertDialog), findsOneWidget);
    await _capture(tester, root, 'following-interval');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(GlassAlertDialog), findsNothing);
    expect(find.byKey(const ValueKey('following-more')), findsOneWidget);
  });

  testWidgets('viewing report data keeps sections unframed', (tester) async {
    await mount(
      tester,
      ViewingReportPage(
        state: state,
        historyOverride: viewingReportFixtureRecords,
        now: viewingReportFixtureNow,
        metadataOverride: viewingReportFixtureMetadata,
      ),
    );
    _expectUnframed(find.text('观看时长'));
  });

  testWidgets(
    'push no-site route keeps controls and default art at narrow size',
    (tester) async {
      final request = pushPlaybackRequest(
        parsed: parsePushFields(
          url: 'https://example.invalid/season.m3u8',
          title: '漫长的季节',
        ),
      );
      await mount(
        tester,
        shell(
          Builder(
            builder: (context) => Center(
              child: FilledButton(
                onPressed: () => openPushLanding(context, state, request),
                child: const Text('打开推送'),
              ),
            ),
          ),
        ),
        size: const Size(1024, 640),
      );
      await tester.tap(find.text('打开推送'));
      await tester.pumpAndSettle();
      expect(find.byType(PushDetailPage), findsOneWidget);
      expect(find.byType(DefaultGlassBackdrop), findsWidgets);
      final location = find.byKey(const ValueKey('push-detail-location'));
      expect(location, findsOneWidget);
      await _capture(tester, root, 'push-narrow');
      _expectPanel(location);
      expect(find.text('播放'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('打开推送'), findsOneWidget);
    },
  );
}

class _RichDetailState extends AppState {
  _RichDetailState(AppPaths paths, String art)
    : vod = Vod(
        vodId: 'rich-sections',
        vodName: '远岸之光',
        vodPic: art,
        vodPlayFrom: r'高清线路$$$备用线路',
        vodPlayUrl: r'第1集$https://fixture.test/1.mp4#第2集$https://fixture.test/2.mp4$$$正片$https://fixture.test/3.mp4',
        extra: {
          'tmdb': {
            'schema': 1,
            'id': 42,
            'media_type': 'movie',
            'language': 'zh-CN',
            'complete': [
              'core',
              'credits',
              'images',
              'external_ids',
              'videos',
              'recommendations',
              'similar',
            ],
            'detail': _detail(42, '远岸之光', art),
          },
        },
      ),
      super(
        paths: paths,
        log: MemoryOnlyLogService(),
        externalMetaService: _RichDetailComments(),
        aiContentCompletion: AiContentCompletion(
          complete:
              ({
                required config,
                required prompt,
                timeout = Duration.zero,
              }) async => const AiCompletionResult(
                ok: true,
                statusCode: 200,
                text: '{"items":[{"title":"智能推荐样片","mediaType":"movie","year":2020}]}',
                message: '',
              ),
        ),
        tmdbService: TmdbService(
          config: () => const TmdbConfig(
            apiKey: 'fixture',
            apiBase: 'https://fixture.test',
          ),
          client: MockClient((request) async {
            final data = switch (request.url.path) {
              '/3/person/8' => {
                'id': 8,
                'name': '样片演员',
                'biography': '在虚构电影中饰演灯塔守护人。',
                'combined_credits': {
                  'cast': [
                    {
                      'id': 94,
                      'media_type': 'movie',
                      'title': '回到海边',
                      'release_date': '2025-02-12',
                    },
                  ],
                },
              },
              '/3/movie/94' => _detail(94, '回到海边', art),
              '/3/movie/94/videos' => _videos,
              _ => {'results': []},
            };
            return http.Response(
              jsonEncode(data),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }),
        ),
      );

  final Vod vod;

  @override
  bool get externalMetaEnabled => true;

  @override
  AiConfig get aiConfig => const AiConfig(
    enabled: true,
    apiKey: 'fixture',
    endpoint: 'https://fixture.test/v1',
    model: 'fixture',
  );

  @override
  final detailRatingService = DetailRatingService();

  @override
  final recommendationDependencies = DetailRecommendationDependencies(
    feedback: RecommendationFeedbackStore(),
    loaders: {
      for (final row in RecommendationRow.values)
        row: (_) async => RecommendationPage(
          items: [
            RecommendationEntry(
              item: TmdbItem(
                tmdbId: 70 + row.index,
                mediaType: TmdbMediaType.movie,
                title: switch (row) {
                  RecommendationRow.related => '相似作品',
                  RecommendationRow.tmdb => '海岸书信',
                  RecommendationRow.douban => '潮汐之后',
                },
              ),
              source: row == RecommendationRow.douban
                  ? RecommendationSource.douban
                  : RecommendationSource.tmdb,
            ),
          ],
        ),
    },
  );

  static const _videos = {
    'results': [
      {
        'key': 'sample-video',
        'name': '样片预告',
        'site': 'YouTube',
        'type': 'Trailer',
        'official': true,
      },
    ],
  };

  static Map<String, Object?> _detail(int id, String title, String art) => {
    'id': id,
    'media_type': 'movie',
    'title': title,
    'overview': '一座灯塔，以及一段穿过海峡的旅程。',
    'poster_path': art,
    'backdrop_path': art,
    'vote_average': 8.6,
    'runtime': 110,
    'release_date': '2024-06-01',
    'credits': {
      'cast': [
        {'id': 8, 'name': '样片演员', 'character': '守塔人'},
      ],
      'crew': [],
    },
    'images': {'posters': [], 'backdrops': []},
    'external_ids': {'imdb_id': 'tt0042000'},
    'videos': _videos,
  };
}

class _RichDetailComments extends ExternalMetaService {
  @override
  Future<ExternalCommentPage> commentsByTitle(
    MetaQuery query, {
    int offset = 0,
    int limit = 5,
  }) async => const ExternalCommentPage(
    comments: [
      ExternalComment(
        source: MetaSourceKind.douban,
        author: '观众样片',
        text: '这段短评保留了原有内边距。',
        rating: 4,
        maxRating: 5,
        votes: 12,
      ),
    ],
    total: 1,
  );
}

Future<List<int>> _captureArtwork() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawColor(Colors.black, BlendMode.src);
  final brush = Paint();
  canvas.drawRect(
    const Rect.fromLTWH(600, 0, 600, 800),
    brush..color = Colors.white,
  );
  const sea = Rect.fromLTWH(0, 185, 1200, 615);
  canvas.drawRect(
    sea,
    brush
      ..shader = const LinearGradient(
        colors: [Color(0xFF092B48), Color(0xFF165B72), Color(0xFFCC9774)],
      ).createShader(sea),
  );
  brush.shader = null;
  canvas.drawCircle(
    const Offset(860, 290),
    110,
    brush..color = const Color(0xFFF9D292),
  );
  for (var i = 0; i < 10; i++) {
    final y = 420.0 + i * 30;
    final wave = Path()..moveTo(0, y);
    wave.cubicTo(230, y - 60, 485, y + 45, 690, y);
    wave.cubicTo(925, y - 55, 1000, y + 10, 1200, y - 8);
    wave.lineTo(1200, 800);
    wave.lineTo(0, 800);
    canvas.drawPath(
      wave,
      brush
        ..color = Color.lerp(
          const Color(0xE5477493),
          const Color(0xFF093248),
          i / 9,
        )!,
    );
  }
  final picture = recorder.endRecording();
  final image = await picture.toImage(1200, 800);
  picture.dispose();
  final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
  image.dispose();
  return bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
}

class _CaptureImageClient implements HttpClient {
  _CaptureImageClient(this.bytes);
  final List<int> bytes;
  @override
  Future<HttpClientRequest> getUrl(Uri url) async =>
      _CaptureImageRequest(bytes);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CaptureImageRequest implements HttpClientRequest {
  _CaptureImageRequest(this.bytes);
  final List<int> bytes;
  @override
  Future<HttpClientResponse> close() async => _CaptureImageResponse(bytes);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CaptureImageResponse extends StreamView<List<int>>
    implements HttpClientResponse {
  _CaptureImageResponse(List<int> bytes)
    : contentLength = bytes.length,
      super(Stream.value(bytes));
  @override
  final int contentLength;
  @override
  int get statusCode => 200;
  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
