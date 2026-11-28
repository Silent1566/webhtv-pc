import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/tmdb_config.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/recommendation_feedback_store.dart';
import 'package:webhtv_pc/services/site_service.dart';
import 'package:webhtv_pc/services/tmdb_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/state/detail_recommendation_state.dart';
import 'package:webhtv_pc/ui/browse_pages.dart';
import 'package:webhtv_pc/ui/theme.dart';
import 'package:webhtv_pc/ui/poster_image.dart';
import 'package:webhtv_pc/ui/tmdb_detail_page.dart';

import 'support/detail_test_seams.dart';
import 'support/test_fonts.dart';

const _size = Size(1200, 800);
const _base = 'https://glass-detail.invalid';
const _title = '远岸之光';
const _overview = '一座灯塔，一段穿过海峡的旅程。此处只使用合成影片和本地图样。';
const _art = '/art.png';
const _broken = '/broken.png';
const _oldArt = '/previous.png';
const _search = ValueKey('tmdb-search-source');
const _hero = ValueKey('tmdb-detail-hero');
const _slideshow = ValueKey('tmdb-backdrop-slideshow');
const _poster = ValueKey('tmdb-detail-poster');
const _heroTitle = ValueKey('tmdb-detail-title');
final _identity = TmdbIdentity.of(TmdbMediaType.movie, 95)!;

enum _Route { site, tmdb }

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late List<int> artBytes;
  late _ImageClient images;
  late Directory temp;
  late _SourceState source;

  void detailTest(String name, WidgetTesterCallback body) {
    testWidgets(name, (tester) async {
      debugNetworkImageHttpClientProvider = () => images;
      try {
        await body(tester);
      } finally {
        debugNetworkImageHttpClientProvider = null;
      }
    });
  }

  setUpAll(() async {
    await loadFixtureFonts();
    artBytes = await _fixtureArtwork();
  });
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('glass-detail-widget-');
    images = _ImageClient();
    source = _SourceState(temp);
    await source.bootstrap();
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });
  tearDown(() async {
    debugNetworkImageHttpClientProvider = null;
    source.dispose();
    await temp.delete(recursive: true);
  });

  for (final route in _Route.values) {
    for (final brightness in Brightness.values) {
      detailTest(
        '${route.name} ${brightness.name}: decoded glass preserves controls and scroll',
        (tester) async {
          final detail = await _mount(
            tester,
            route,
            brightness,
            source,
            art: _art,
          );
          final pending = _geometry(tester, route);
          final pendingOpaque = _barIsOpaque(tester);
          final pendingCount = _filter.evaluate().length;
          expect(pending.hero.top, route == _Route.site ? 0 : 56);
          expect(pending.hero.height, tester.view.physicalSize.height);
          expect(pending.origin, 0);
          expect(pending.offset, 0);

          images.release(_art, artBytes);
          await _until(tester, () => _artIsDecoded(_art));
          await tester.pumpAndSettle();
          final active = _geometry(tester, route);
          await _checkPixels(tester, detail.boundary, route, brightness);

          expect(_filter, findsOneWidget);
          expect(tester.getRect(_filter), active.bar);
          expect(pendingCount, 0, reason: 'a pending URL is not a frame');
          expect(pendingOpaque, isTrue);
          expect(active, pending);
          expect(
            images.requests.where((url) => url.path == _art),
            hasLength(1),
          );
          expect(tester.getRect(find.byKey(_slideshow)).top, 0);

          final scroll = _verticalPosition(tester);
          scroll.jumpTo(180);
          await tester.pumpAndSettle();
          expect(scroll.pixels, greaterThan(0));
          expect(tester.getRect(_back(route)), active.back);
          expect(tester.getRect(find.byType(AppBar)), active.bar);
          expect(_filter, findsOneWidget);
          if (route == _Route.tmdb) {
            final search = find.byKey(_search);
            expect(tester.getRect(search), active.search);
            await tester.tap(search);
            expect(detail.searches, [(_title, _identity)]);
          }
          await tester.tap(_back(route));
          await tester.pumpAndSettle();
          expect(find.text('Route host'), findsOneWidget);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }

    detailTest('${route.name}: absent and undecodable art stay opaque', (
      tester,
    ) async {
      await _mount(tester, route, Brightness.dark, source);
      final absent = _geometry(tester, route);
      final absentOpaque = _barIsOpaque(tester);
      expect(_filter, findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await _mount(tester, route, Brightness.dark, source, art: _broken);
      final loading = _geometry(tester, route);
      images.release(_broken, utf8.encode('not an image'));
      await _until(tester, _brokenBackdropHasFallenThrough);
      expect(_filter, findsNothing);
      expect(absentOpaque, isTrue);
      expect(_barIsOpaque(tester), isTrue);
      expect(loading, absent);
      expect(loading.hero.height, tester.view.physicalSize.height);
      expect(_geometry(tester, route), loading);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  detailTest('site: no-play detail keeps its hero for an invalid candidate', (
    tester,
  ) async {
    await _mount(
      tester,
      _Route.site,
      Brightness.dark,
      source,
      art: _broken,
      hasPlayLines: false,
    );
    final pending = _geometry(tester, _Route.site);
    final swap = find.byKey(const ValueKey('detail-no-line-swap'));
    expect(pending.hero.height, tester.view.physicalSize.height);
    expect(swap.hitTestable(), findsNothing);
    images.release(_broken, utf8.encode('not an image'));
    await _until(tester, _brokenBackdropHasFallenThrough);
    expect(_geometry(tester, _Route.site), pending);
    expect(swap.hitTestable(), findsNothing);
    expect(_barIsOpaque(tester), isTrue);
  });

  detailTest('late outgoing frame cannot enable glass during rotation', (
    tester,
  ) async {
    await _mount(
      tester,
      _Route.tmdb,
      Brightness.dark,
      source,
      metadata: Future.value(
        _tmdbResponse(backdrop: _art, preferredBackdrop: _oldArt),
      ),
    );
    expect(_backdropImage(_oldArt), findsOneWidget);
    expect(_backdropImage(_art), findsNothing);
    final initial = _geometry(tester, _Route.tmdb);
    await tester.pump(const Duration(seconds: 5));
    expect(_backdropImage(_art), findsOneWidget);
    images.release(_oldArt, artBytes);
    // Keep the old AnimatedSwitcher child alive long enough to decode.
    await _until(tester, () => _artIsDecoded(_oldArt), tick: Duration.zero);
    await tester.pump();
    expect(_filter, findsNothing);
    expect(_barIsOpaque(tester), isTrue);

    images.release(_art, artBytes);
    await _until(tester, () => _artIsDecoded(_art));
    await tester.pumpAndSettle();
    expect(_filter, findsOneWidget);
    expect(_geometry(tester, _Route.tmdb), initial);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  detailTest('replacing decoded TMDB art immediately restores the opaque bar', (
    tester,
  ) async {
    final metadata = Completer<http.Response>();
    await _mount(
      tester,
      _Route.tmdb,
      Brightness.dark,
      source,
      art: _art,
      metadata: metadata.future,
    );
    images.release(_art, artBytes);
    await _until(tester, () => _artIsDecoded(_art));
    await tester.pumpAndSettle();
    expect(_filter, findsOneWidget);
    _verticalPosition(tester).jumpTo(24);
    await tester.pump();
    final initial = _geometry(tester, _Route.tmdb);

    metadata.complete(_tmdbResponse(backdrop: _broken));
    await tester.pump();
    await tester.pump();
    expect(images.requests.map((url) => url.path), [_art, _broken]);
    expect(_filter, findsNothing);
    expect(_barIsOpaque(tester), isTrue);
    expect(_geometry(tester, _Route.tmdb), initial);
    images.release(_broken, utf8.encode('not an image'));
    await _until(tester, _brokenBackdropHasFallenThrough);
    expect(_filter, findsNothing);
    expect(_barIsOpaque(tester), isTrue);
    expect(_geometry(tester, _Route.tmdb), initial);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  detailTest('TMDB no-snapshot loading and errors keep their original inset', (
    tester,
  ) async {
    final metadata = Completer<http.Response>();
    await _mount(
      tester,
      _Route.tmdb,
      Brightness.dark,
      source,
      metadata: metadata.future,
      withSnapshot: false,
    );
    final indicator = find.byType(CircularProgressIndicator);
    expect(tester.getCenter(indicator), const Offset(600, 428));
    expect(_filter, findsNothing);
    expect(_barIsOpaque(tester), isTrue);
    expect(tester.widget<TextButton>(find.byKey(_search)).onPressed, isNull);
    final searchRect = tester.getRect(find.byKey(_search));

    metadata.complete(
      http.Response('{"status_message":"fixture failure"}', 404),
    );
    await tester.pumpAndSettle();
    final errorRect = tester.getRect(
      find.byKey(const ValueKey('tmdb-only-error')),
    );
    final retryRect = tester.getRect(
      find.byKey(const ValueKey('tmdb-only-retry')),
    );
    expect(errorRect.expandToInclude(retryRect).center, const Offset(600, 428));
    expect(_filter, findsNothing);
    expect(_barIsOpaque(tester), isTrue);
    expect(tester.getRect(find.byKey(_search)), searchRect);
    expect(tester.widget<TextButton>(find.byKey(_search)).onPressed, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

class _SourceState extends AppState with ExternalMetaOff {
  _SourceState(Directory dir)
    : super(
        paths: AppPaths.resolve(
          overrides: {
            for (final name in ['config', 'data', 'cache', 'state'])
              name: dir.path,
          },
        ),
        log: MemoryOnlyLogService(),
      );

  @override
  Future<void> loadDetail(
    Vod vod, {
    Site? siteOverride,
    SiteService? serviceOverride,
  }) async {}
}

http.Response _tmdbResponse({String? backdrop, String? preferredBackdrop}) =>
    http.Response(
      jsonEncode({
        'id': 95,
        'media_type': 'movie',
        'title': _title,
        'overview': _overview,
        'backdrop_path': ?backdrop,
        'credits': {'cast': [], 'crew': []},
        'images': {
          'backdrops': [
            if (preferredBackdrop != null)
              {'file_path': preferredBackdrop, 'width': 1200, 'height': 800},
          ],
          'posters': [],
        },
        'recommendations': {'results': []},
        'similar': {'results': []},
      }),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

Future<({GlobalKey boundary, List<(String, TmdbIdentity)> searches})> _mount(
  WidgetTester tester,
  _Route route,
  Brightness brightness,
  _SourceState source, {
  String? art,
  Future<http.Response>? metadata,
  bool withSnapshot = true,
  bool hasPlayLines = true,
}) async {
  tester.view.physicalSize = _size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final boundary = GlobalKey();
  final searches = <(String, TmdbIdentity)>[];
  final theme = buildAppTheme(brightness);
  final typography = theme.textTheme.apply(fontFamily: 'FixtureCJK');
  late final Widget page;
  switch (route) {
    case _Route.site:
      final vod = Vod(
        vodId: 'glass-fixture-95',
        vodName: _title,
        vodContent: _overview,
        vodPic: art == null ? null : '$_base$art',
        vodPlayFrom: hasPlayLines ? '合成线路' : null,
        vodPlayUrl: hasPlayLines
            ? '第1集\$https://glass-detail.invalid/fake.mp4'
            : null,
      );
      source.seedDetailForTest(vod: vod);
      page = DetailPage(state: source, vod: vod);
    case _Route.tmdb:
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/movie/95')) {
          return metadata == null ? _tmdbResponse() : await metadata;
        }
        return http.Response('{"results":[]}', 200);
      });
      final service = TmdbService(
        config: () => const TmdbConfig(apiKey: 'fixture', backdropBase: _base),
        client: client,
      );
      final recommendations = DetailRecommendationDependencies(
        feedback: RecommendationFeedbackStore(),
        loaders: {},
      );
      addTearDown(service.close);
      addTearDown(recommendations.close);
      page = TmdbDetailPage(
        service: service,
        identity: _identity,
        initialItem: !withSnapshot
            ? null
            : TmdbItem(
                tmdbId: 95,
                mediaType: TmdbMediaType.movie,
                title: _title,
                overview: _overview,
                backdropUrl: art == null ? null : '$_base$art',
              ),
        recommendationDependencies: recommendations,
        onSearchSource: (title, identity) => searches.add((title, identity)),
      );
  }
  await tester.pumpWidget(
    MaterialApp(
      theme: theme.copyWith(
        textTheme: typography,
        appBarTheme: theme.appBarTheme.copyWith(
          titleTextStyle: typography.titleMedium,
        ),
        textButtonTheme: TextButtonThemeData(
          style: theme.textButtonTheme.style?.copyWith(
            textStyle: WidgetStatePropertyAll(typography.labelLarge),
          ),
        ),
      ),
      home: const Scaffold(body: Text('Route host')),
    ),
  );
  unawaited(
    tester
        .state<NavigatorState>(find.byType(Navigator))
        .push<void>(
          PageRouteBuilder<void>(
            transitionDuration: Duration.zero,
            reverseTransitionDuration: Duration.zero,
            pageBuilder: (_, _, _) =>
                RepaintBoundary(key: boundary, child: page),
          ),
        ),
  );
  if (withSnapshot) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump();
  }
  return (boundary: boundary, searches: searches);
}

Finder get _titleInBar =>
    find.descendant(of: find.byType(AppBar), matching: find.text(_title));
Finder get _filter => find.descendant(
  of: find.byType(AppBar),
  matching: find.byType(BackdropFilter),
);
// A rejected detail image now falls through to the app backdrop instead of
// inserting a broken-image icon. Wait for that exact selected image to leave
// the subtree, not merely for the opaque bar (which is already true while loading).
bool _brokenBackdropHasFallenThrough() {
  final backdrop = find.descendant(
    of: find.byKey(_slideshow),
    matching: find.byWidgetPredicate(
      (widget) => widget is PosterImage && widget.url == '$_base$_broken',
    ),
  );
  if (backdrop.evaluate().length != 1) return false;
  final transparentFallback = find.descendant(
    of: backdrop,
    matching: find.byWidgetPredicate(
      (widget) =>
          widget is SizedBox &&
          widget.width == double.infinity &&
          widget.height == double.infinity &&
          widget.child == null,
    ),
  );
  return transparentFallback.evaluate().isNotEmpty && !_artIsDecoded(_broken);
}

Finder _back(_Route route) => route == _Route.site
    ? find.descendant(of: find.byType(AppBar), matching: find.byTooltip('返回'))
    : find.descendant(
        of: find.byType(AppBar),
        matching: find.byType(BackButton),
      );

ScrollPosition _verticalPosition(WidgetTester tester) => tester
    .state<ScrollableState>(
      find
          .byWidgetPredicate(
            (widget) =>
                widget is Scrollable &&
                widget.axisDirection == AxisDirection.down,
          )
          .first,
    )
    .position;

({
  Rect bar,
  Rect back,
  Rect hero,
  Rect poster,
  Rect title,
  Rect heroTitle,
  Rect? search,
  double origin,
  double offset,
})
_geometry(WidgetTester tester, _Route route) => (
  bar: tester.getRect(find.byType(AppBar)),
  back: tester.getRect(_back(route)),
  hero: tester.getRect(find.byKey(_hero)),
  poster: tester.getRect(find.byKey(_poster)),
  title: tester.getRect(_titleInBar),
  heroTitle: tester.getRect(find.byKey(_heroTitle)),
  search: route == _Route.tmdb ? tester.getRect(find.byKey(_search)) : null,
  origin: tester.getTopLeft(find.byType(Scaffold).last).dy,
  offset: _verticalPosition(tester).pixels,
);

bool _barIsOpaque(WidgetTester tester) =>
    tester
        .widget<Material>(
          find
              .descendant(
                of: find.byType(AppBar),
                matching: find.byType(Material),
              )
              .first,
        )
        .color
        ?.a ==
    1;

Finder _backdropImage(String path) => find.descendant(
  of: find.byKey(_slideshow),
  matching: find.byWidgetPredicate(
    (widget) =>
        widget is Image &&
        widget.image is NetworkImage &&
        (widget.image as NetworkImage).url == '$_base$path',
  ),
);

bool _artIsDecoded(String path) => _backdropImage(path).evaluate().any(
  (element) => find
      .descendant(
        of: find.byWidget(element.widget),
        matching: find.byWidgetPredicate(
          (w) => w is RawImage && w.image != null,
        ),
      )
      .evaluate()
      .isNotEmpty,
);

Future<void> _until(
  WidgetTester tester,
  bool Function() condition, {
  Duration tick = const Duration(milliseconds: 16),
}) async {
  for (var attempt = 0; attempt < 50 && !condition(); attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(tick);
  }
  expect(condition(), isTrue, reason: 'expected fixture image state');
}

Future<void> _checkPixels(
  WidgetTester tester,
  GlobalKey boundary,
  _Route route,
  Brightness brightness,
) async {
  final titleInk = _ink(tester, _titleInBar);
  final searchInk = route == _Route.tmdb
      ? _ink(tester, find.text('搜索站源'))
      : null;
  final g = _geometry(tester, route);
  final capture = Platform.environment['GLASS_DETAIL_CAPTURE'];
  final samples = (await tester.runAsync(() async {
    final box =
        boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final picture = await box.toImage();
    try {
      if (capture == 'before' || capture == 'after') {
        final file = File(
          '../../.local/glass-rollout-captures/detail/${route.name}-${brightness.name}-$capture.png',
        );
        await file.parent.create(recursive: true);
        if (!await file.exists()) {
          final png = (await picture.toByteData(
            format: ui.ImageByteFormat.png,
          ))!;
          await file.writeAsBytes(
            png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
          );
        }
      }
      final data = (await picture.toByteData())!;
      Color pixel(int x, int y) {
        final i = (y * picture.width + x) * 4;
        return Color.fromARGB(
          255,
          data.getUint8(i),
          data.getUint8(i + 1),
          data.getUint8(i + 2),
        );
      }

      final y = g.title.center.dy.round();
      // Sample glyph-free areas beside the text on the black and white plateaus.
      final xLow = g.title.right.ceil() + 10;
      final xHigh = (g.search?.left.floor() ?? 1040) - 10;
      final low = pixel(xLow, y);
      final high = pixel(xHigh, y);
      final ratios = [
        for (final ink in [titleInk, ?searchInk]) ...[
          _contrast(ink, low),
          _contrast(ink, high),
        ],
      ];
      if (capture != null) {
        // ignore: avoid_print
        print(
          'DETAIL ${route.name}/${brightness.name} $capture $g '
          'title=$titleInk search=$searchInk low($xLow,$y)=$low high($xHigh,$y)=$high '
          'contrast=${ratios.map((r) => r.toStringAsFixed(2)).toList()}',
        );
      }
      return (low: low, high: high, ratios: ratios);
    } finally {
      picture.dispose();
    }
  }))!;
  if (capture == 'before') return;
  expect(
    samples.high.computeLuminance(),
    greaterThan(samples.low.computeLuminance() + .01),
  );
  for (final ratio in samples.ratios) {
    expect(ratio, greaterThanOrEqualTo(4.5));
  }
}

Color _ink(WidgetTester tester, Finder text) =>
    DefaultTextStyle.of(tester.element(text)).style.color!;

double _contrast(Color ink, Color backing) {
  final a = Color.alphaBlend(ink, backing).computeLuminance();
  final b = backing.computeLuminance();
  return (math.max(a, b) + .05) / (math.min(a, b) + .05);
}

Future<List<int>> _fixtureArtwork() async {
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
  final image = await picture.toImage(
    _size.width.toInt(),
    _size.height.toInt(),
  );
  picture.dispose();
  final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
  image.dispose();
  return bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
}

class _ImageClient implements HttpClient {
  final requests = <Uri>[];
  final _gates = <String, Completer<List<int>>>{};
  Completer<List<int>> _gate(String path) =>
      _gates.putIfAbsent(path, Completer.new);
  void release(String path, List<int> data) => _gate(path).complete(data);

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    requests.add(url);
    return _ImageRequest(_gate(url.path).future);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ImageRequest implements HttpClientRequest {
  _ImageRequest(this.bytes);
  final Future<List<int>> bytes;

  @override
  Future<HttpClientResponse> close() async => _ImageResponse(await bytes);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ImageResponse extends StreamView<List<int>>
    implements HttpClientResponse {
  _ImageResponse(List<int> bytes)
    : contentLength = bytes.length,
      super(Stream.value(bytes));

  @override
  final int contentLength;
  @override
  int get statusCode => HttpStatus.ok;
  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
