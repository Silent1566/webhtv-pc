import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/following.dart';
import 'package:webhtv_pc/core/tmdb_config.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/search_suggest_service.dart';
import 'package:webhtv_pc/services/tmdb_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/home_cards.dart';
import 'package:webhtv_pc/ui/home_hero.dart';
import 'package:webhtv_pc/ui/home_page.dart';
import 'package:webhtv_pc/ui/layout_scale.dart';
import 'package:webhtv_pc/ui/theme.dart';

import 'support/detail_test_seams.dart';
import 'support/test_fonts.dart';

const _font = 'HomeScrollCaptureCJK';
const _backdrop = '$tmdbDefaultBackdropBase/home-scroll-synthetic-backdrop.png';
const _poster = '$tmdbDefaultImageBase/home-scroll-synthetic-poster.png';
const _offset = 800.0;
final _rootKey = GlobalKey();

class _CaptureState extends AppState {
  _CaptureState(this.metadata)
    : super(
        paths: AppPaths.resolve(
          overrides: {
            'config': _evidenceDir().path,
            'data': _evidenceDir().path,
            'cache': _evidenceDir().path,
            'state': _evidenceDir().path,
          },
        ),
        log: MemoryOnlyLogService(),
      );

  final TmdbService metadata;

  @override
  bool get externalMetaEnabled => false;

  @override
  TmdbService get tmdbService => metadata;

  @override
  List<Following> get followings => [
    Following(
      seriesKey: 'source:0:site:synthetic',
      season: 0,
      siteKey: 'site',
      vodId: 'synthetic',
      vodName: '山海之间 · 合成取证画面',
      vodPic: _poster,
      latestReleasedEpisode: 4,
      latestEpisodeName: '第04集',
    ),
  ];

  @override
  Future<TmdbItem?> followingTmdbItem(Following item) async =>
      TmdbItem(tmdbId: 42, mediaType: TmdbMediaType.tv, title: item.vodName);

  @override
  Future<List<SearchSuggestItem>> searchHotRank(
    HotRankCategory category,
  ) async => [
    for (var i = 1; i <= 8; i++)
      SearchSuggestItem(
        title: '${category.label} · 合成样本 $i',
        cover: _poster,
        subtitle: '确定性测试素材',
        score: '8.3',
        rank: i,
      ),
  ];
}

Directory _evidenceDir() {
  var root = Directory.current;
  for (var hop = 0; hop < 6; hop++) {
    if (Directory('${root.path}/apps/desktop-flutter').existsSync()) {
      return Directory('${root.path}/.local/home-scroll');
    }
    root = root.parent;
  }
  throw StateError('Repository root not found');
}

ThemeData _captureTheme() {
  final base = buildAppTheme(Brightness.dark);
  final label = base.textTheme.labelLarge?.copyWith(fontFamily: _font);
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: _font),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: _font),
    textButtonTheme: TextButtonThemeData(
      style: base.textButtonTheme.style?.copyWith(
        textStyle: WidgetStatePropertyAll(label),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: base.filledButtonTheme.style?.copyWith(
        textStyle: WidgetStatePropertyAll(label),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: base.outlinedButtonTheme.style?.copyWith(
        textStyle: WidgetStatePropertyAll(label),
      ),
    ),
    chipTheme: base.chipTheme.copyWith(
      labelStyle: base.chipTheme.labelStyle?.copyWith(fontFamily: _font),
      secondaryLabelStyle: base.chipTheme.secondaryLabelStyle?.copyWith(
        fontFamily: _font,
      ),
    ),
  );
}

Future<Uint8List> _fixtureBytes({required bool portrait}) async {
  final width = portrait ? 400 : 1600;
  final height = portrait ? 600 : 900;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final rect = Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble());
  canvas.drawRect(
    rect,
    Paint()
      ..shader = ui.Gradient.linear(
        Offset.zero,
        Offset(width.toDouble(), height.toDouble()),
        [const Color(0xFF147D92), const Color(0xFF633E9A)],
      ),
  );
  final sun = Offset(width * 0.74, height * 0.26);
  canvas.drawCircle(
    sun,
    width * 0.105,
    Paint()..color = const Color(0xFFFFC65C),
  );
  for (final factor in [0.135, 0.16]) {
    canvas.drawCircle(
      sun,
      width * factor,
      Paint()
        ..color = const Color(0xFFF7DB91)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
  }
  for (var i = 0; i < 3; i++) {
    final ridge = Path()
      ..moveTo(-width * 0.1, height.toDouble())
      ..lineTo(width * (0.16 + i * 0.31), height * (0.28 + i * 0.12))
      ..lineTo(width * (0.52 + i * 0.31), height.toDouble())
      ..close();
    canvas.drawPath(
      ridge,
      Paint()
        ..color = [
          const Color(0xFF17435D),
          const Color(0xFF236D70),
          const Color(0xFF162C4C),
        ][i],
    );
  }
  for (var i = 1; i < 9; i++) {
    canvas.drawLine(
      Offset(0, height * i / 10),
      Offset(width.toDouble(), height * i / 10),
      Paint()
        ..color = const Color(0x33FFFFFF)
        ..strokeWidth = 1,
    );
  }
  final paragraph =
      (ui.ParagraphBuilder(
              ui.ParagraphStyle(
                fontFamily: _font,
                fontSize: portrait ? 23 : 32,
              ),
            )
            ..pushStyle(ui.TextStyle(color: const Color(0xFFFFFFFF)))
            ..addText(
              portrait
                  ? 'SYNTHETIC\nCAPTURE'
                  : 'SYNTHETIC 16:9 FIXTURE · NOT A FILM STILL',
            ))
          .build()
        ..layout(ui.ParagraphConstraints(width: width - 64.0));
  canvas.drawParagraph(paragraph, const Offset(32, 30));
  paragraph.dispose();
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return Uint8List.sublistView(bytes!);
}

Future<void> _prime(ImageProvider provider, ui.Image image) async {
  final key = await provider.obtainKey(ImageConfiguration.empty);
  PaintingBinding.instance.imageCache.putIfAbsent(
    key,
    () => OneFrameImageStreamCompleter(
      Future.value(ImageInfo(image: image.clone())),
    ),
  );
  expect(
    PaintingBinding.instance.imageCache.statusForKey(key).pending ||
        PaintingBinding.instance.imageCache.statusForKey(key).keepAlive,
    isTrue,
  );
}

Future<Map<String, List<int>>> _capture(
  WidgetTester tester,
  String stage,
  String scenario,
) async {
  final samples = await tester.runAsync(() async {
    final boundary =
        _rootKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    expect(image.width, 1280);
    expect(image.height, 800);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final pixels = Uint8List.sublistView(rgba!);
    final samples = <String, List<int>>{};
    for (final point in [
      const Offset(600, 100),
      const Offset(1000, 200),
      const Offset(1100, 350),
    ]) {
      final index = (point.dy.toInt() * image.width + point.dx.toInt()) * 4;
      samples['${point.dx.toInt()},${point.dy.toInt()}'] = pixels.sublist(
        index,
        index + 3,
      );
    }
    image.dispose();
    File('${_evidenceDir().path}/$stage-$scenario.png')
        .writeAsBytesSync(Uint8List.sublistView(bytes!));
    return samples;
  });
  return samples!;
}

void main() {
  setUpAll(() async {
    expectFontsAvailableOrSkip();
    await loadFixtureFonts(cjkFamily: _font);
  });

  testWidgets('real HomePage loaded synthetic backdrop at top and scroll 800', (
    tester,
  ) async {
    final stage = Platform.environment['HOME_SCROLL_CAPTURE_STAGE'];
    expect(stage == null || ['before', 'after'].contains(stage), isTrue);
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final metadata = TmdbService(
      config: () => const TmdbConfig(
        apiKey: 'capture-fixture',
        imageBase: tmdbDefaultImageBase,
        backdropBase: tmdbDefaultBackdropBase,
      ),
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'id': 42,
            'name': '山海之间 · 合成取证画面',
            'poster_path': '/home-scroll-synthetic-poster.png',
            'backdrop_path': '/home-scroll-synthetic-backdrop.png',
            'overview': '这是一张确定性合成的 16:9 测试背景，不是真实影视海报。向下滚动后对比背景是否保留。',
            'genres': [
              {'id': 18, 'name': '合成素材'},
            ],
            'first_air_date': '2026-05-01',
            'vote_average': 8.3,
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      ),
    );
    final state = _CaptureState(metadata);
    addTearDown(() {
      state.dispose();
      metadata.close();
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
    });
    var cardWidth = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            cardWidth = LayoutScale.cardWidth(context).round();
            return const SizedBox();
          },
        ),
      ),
    );
    await tester.runAsync(() async {
      final backdropBytes = await _fixtureBytes(portrait: false);
      final posterBytes = await _fixtureBytes(portrait: true);
      if (stage != null) {
        _evidenceDir().createSync(recursive: true);
        File('${_evidenceDir().path}/synthetic-backdrop.png')
            .writeAsBytesSync(backdropBytes);
        File('${_evidenceDir().path}/synthetic-poster.png')
            .writeAsBytesSync(posterBytes);
      }
      final backdropCodec = await ui.instantiateImageCodec(backdropBytes);
      final posterCodec = await ui.instantiateImageCodec(posterBytes);
      final backdropImage = (await backdropCodec.getNextFrame()).image;
      final posterImage = (await posterCodec.getNextFrame()).image;
      expect(backdropImage.width / backdropImage.height, 16 / 9);
      await _prime(const NetworkImage(_backdrop), backdropImage);
      await _prime(const NetworkImage(_poster), posterImage);
      await _prime(
        ResizeImage.resizeIfNeeded(
          cardWidth,
          null,
          const NetworkImage(_poster),
        ),
        posterImage,
      );
      backdropImage.dispose();
      posterImage.dispose();
      backdropCodec.dispose();
      posterCodec.dispose();
    });
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _captureTheme(),
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(1280, 800),
            devicePixelRatio: 1,
            disableAnimations: true,
          ),
          child: RepaintBoundary(
            key: _rootKey,
            child: Scaffold(
              body: HomePage(
                state: state,
                onOpenBrowse: () {},
                onOpenHistory: () {},
                onOpenFollowing: () {},
                onImportConfig: () {},
                onSearch: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final hero = tester.widget<HomeHero>(find.byType(HomeHero));
    expect(hero.items, hasLength(1));
    expect(hero.items.single.backdrop, _backdrop);
    final loadedBackdrop = find.byWidgetPredicate(
      (widget) =>
          widget is RawImage &&
          widget.image?.width == 1600 &&
          widget.image?.height == 900,
    );
    expect(
      loadedBackdrop,
      findsAtLeastNWidgets(1),
      reason: 'The real image widget must contain decoded fixture pixels, not a placeholder.',
    );
    expect(find.byIcon(Icons.image_not_supported_outlined), findsNothing);
    expect(find.byIcon(Icons.downloading), findsNothing);
    final title = find.descendant(
      of: find.byType(HomeHero),
      matching: find.text('山海之间 · 合成取证画面'),
    );
    final titleBefore = tester.getRect(title);
    final heroBefore = tester.getRect(find.byKey(const ValueKey('home-hero')));
    expect(titleBefore.overlaps(const Rect.fromLTWH(0, 0, 1280, 800)), isTrue);
    final scrollable = tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byKey(const ValueKey('home-scroll')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    final position = scrollable.position;
    expect(position.pixels, 0);
    expect(position.maxScrollExtent, greaterThanOrEqualTo(_offset));
    final topSamples = stage == null
        ? null
        : await _capture(tester, stage, 'top');
    position.jumpTo(_offset);
    await tester.pumpAndSettle();
    expect(position.pixels, _offset);
    final heroBottomAfterScroll = heroBefore.bottom - position.pixels;
    final titleBottomAfterScroll = titleBefore.bottom - position.pixels;
    expect(
      heroBottomAfterScroll,
      lessThanOrEqualTo(0),
      reason: 'Hero copy must be fully above the viewport.',
    );
    expect(titleBottomAfterScroll, lessThan(0));
    expect(title.hitTestable(), findsNothing);
    expect(
      find.byType(HomeRailView).evaluate().any((element) {
        final box = element.renderObject! as RenderBox;
        return (box.localToGlobal(Offset.zero) & box.size).overlaps(
          const Rect.fromLTWH(0, 0, 1280, 800),
        );
      }),
      isTrue,
    );
    final loadedPosters = tester
        .widgetList<RawImage>(find.byType(RawImage))
        .where(
          (image) => image.image?.width == 400 && image.image?.height == 600,
        )
        .length;
    expect(loadedPosters, greaterThan(0));
    expect(find.byIcon(Icons.image_not_supported_outlined), findsNothing);
    expect(find.byIcon(Icons.downloading), findsNothing);
    if (stage == 'after') {
      expect(
        loadedBackdrop,
        findsAtLeastNWidgets(1),
        reason: 'The decoded backdrop must remain mounted after the hero scrolls away.',
      );
    }
    if (stage != null) {
      final scrolledSamples = await _capture(tester, stage, 'scrolled');
      if (stage == 'after') {
        expect(
          scrolledSamples,
          topSamples,
          reason: 'Open rail whitespace must retain the fixed top-screen backdrop pixels.',
        );
        expect(
          scrolledSamples.values.map((rgb) => rgb.join(',')).toSet().length,
          greaterThan(1),
          reason: 'The retained background must be an image, not a uniform surface.',
        );
        for (final rgb in scrolledSamples.values) {
          expect(
            rgb,
            isNot([11, 14, 26]),
            reason: 'The baseline dark surface must not hide the backdrop.',
          );
        }
      }
      File('${_evidenceDir().path}/$stage.json').writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert({
          'stage': stage,
          'viewport': {'width': 1280, 'height': 800, 'devicePixelRatio': 1},
          'theme': 'buildAppTheme(Brightness.dark) with loaded Noto CJK font',
          'disableAnimations': true,
          'heroItems': hero.items.length,
          'scrollOffset': position.pixels,
          'maxScrollExtent': position.maxScrollExtent,
          'heroBottomAfterScroll': heroBottomAfterScroll,
          'heroTitleBottomAfterScroll': titleBottomAfterScroll,
          'backdropUrl': _backdrop,
          'backdropFixture': 'synthetic-backdrop.png (1600x900, 16:9)',
          'posterFixture': 'synthetic-poster.png (400x600, 2:3)',
          'loadedPostersAfterScroll': loadedPosters,
          'cardCacheWidth': cardWidth,
          'openWhitespaceTopRgb': topSamples,
          'openWhitespaceScrolledRgb': scrolledSamples,
          'fixtureSeam': 'MockClient TMDB metadata + primed ImageProvider cache using decoded PNG fixture pixels',
        }),
      );
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
