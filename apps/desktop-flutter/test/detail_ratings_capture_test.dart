/// 详情页「评分与外部链接」Before/After 截图门禁（用户需求 2026-11-11）。
///
/// 只在 `DETAIL_RATINGS_CAPTURE_PHASE` 非空时写 PNG（与
/// `detail_image_fallback_test.dart` 同一套做法）：CI 上它只是一次普通渲染断言，
/// 本地要对比时才落图。
///
/// Before 与 After 是**同一次渲染路径、同一 fixture、同一视口、同一主题**，
/// 唯一差别是 `ratingsSection` 传不传——差异因此只可能来自新增区块本身。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/detail_ratings.dart';
import 'package:webhtv_pc/core/tmdb_detail_model.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/ui/detail_ratings_section.dart';
import 'package:webhtv_pc/ui/theme.dart';
import 'package:webhtv_pc/ui/tmdb_detail_view.dart';

const _poster = 'https://fixture.test/poster.png';
const _backdrop = 'https://fixture.test/backdrop.png';

/// 1x1 透明 PNG：截图只关心布局与文案，图片内容不该成为差异来源。
const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

class _FixtureClient implements HttpClient {
  @override
  Future<HttpClientRequest> getUrl(Uri url) async => _FixtureRequest();

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FixtureRequest implements HttpClientRequest {
  final _headers = _FixtureHeaders();
  @override
  HttpHeaders get headers => _headers;
  @override
  Future<HttpClientResponse> close() async => _FixtureResponse();
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FixtureHeaders implements HttpHeaders {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FixtureResponse extends Stream<List<int>> implements HttpClientResponse {
  final Uint8List bytes = base64Decode(_png);
  @override
  int get statusCode => 200;
  @override
  int get contentLength => bytes.length;
  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value(bytes).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

const _request = DetailRatingRequest(
  tmdbId: 1399,
  title: '示例剧集',
  year: 2011,
  mediaType: TmdbMediaType.tv,
  imdbId: 'tt0944947',
  originalTitle: 'Game of Thrones',
  englishTitle: 'Game of Thrones',
);

TmdbDetailData _data() => TmdbDetailData(
  tmdbId: 1399,
  title: '示例剧集',
  originalTitle: 'Game of Thrones',
  overview: '评分与外部链接固定夹具：TMDB / 豆瓣 / IMDb / 烂番茄 / Metacritic 各一条。',
  posterUrl: _poster,
  backdropUrls: const [_backdrop],
  posterUrls: const [_poster],
  rating: 8.4,
  releaseDate: '2011-04-17',
  runtime: 57,
  genres: const ['剧情', '奇幻'],
  countries: const ['美国'],
  status: 'Ended',
);

Widget _host(Widget child, {required Brightness brightness, Key? captureKey}) {
  final theme = buildAppTheme(brightness);
  return MaterialApp(
    theme: theme.copyWith(
      textTheme: theme.textTheme.apply(fontFamily: 'FixtureCJK'),
    ),
    home: RepaintBoundary(
      key: captureKey,
      child: Scaffold(body: SingleChildScrollView(child: child)),
    ),
  );
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
  await tester.pumpAndSettle();
  debugNetworkImageHttpClientProvider = null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final font = File('/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc');
    final root =
        Platform.environment['FLUTTER_ROOT'] ??
        '/tmp/webhtv-linux-sdk/flutter-3.47.5';
    final icons = File(
      '$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    );
    if (icons.existsSync()) {
      await (FontLoader(
        'MaterialIcons',
      )..addFont(icons.readAsBytes().then(ByteData.sublistView))).load();
    }
    if (font.existsSync()) {
      await (FontLoader(
        'FixtureCJK',
      )..addFont(font.readAsBytes().then(ByteData.sublistView))).load();
    }
  });

  setUp(() {
    debugNetworkImageHttpClientProvider = () => _FixtureClient();
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  tearDown(() => debugNetworkImageHttpClientProvider = null);

  for (final withSection in [false, true]) {
    for (final width in [1280, 900]) {
      for (final brightness in Brightness.values) {
        final phase = withSection ? 'after' : 'before';
        testWidgets('capture $phase $width ${brightness.name}', (tester) async {
          tester.view.physicalSize = Size(width.toDouble(), 950);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final boundary = GlobalKey();
          await tester.pumpWidget(
            _host(
              TmdbDetailView(
                data: _data(),
                paintBackdrop: false,
                ratingLinks: withSection
                    ? DetailRatingsSection(
                        request: _request,
                        ratings: DetailRatingRules.build(
                          request: _request,
                          values: const DetailRatingValues(
                            doubanRating: 9.4,
                            imdb: '9.2',
                            imdbVotes: '2.4M',
                            rottenTomatoes: '89%',
                            metacritic: '82/100',
                          ),
                        ),
                        onOpen: (url) async => true,
                        onCopy: (url) async {},
                      )
                    : null,
                ratingTags: withSection
                    ? DetailRatingTags(
                        ratings: DetailRatingRules.build(
                          request: _request,
                          values: const DetailRatingValues(
                            doubanRating: 9.4,
                            imdb: '9.2',
                            imdbVotes: '2.4M',
                            rottenTomatoes: '89%',
                            metacritic: '82/100',
                          ),
                        ),
                        tmdbRating: 8.4,
                      )
                    : null,
              ),
              brightness: brightness,
              captureKey: boundary,
            ),
          );
          // 滚到**两个阶段都存在**的锚点（空态卡片）：hero 恒为整屏高，
          // 不滚的话截图里只有背景图，Before/After 会一模一样。
          await Scrollable.ensureVisible(
            tester.element(find.byKey(const ValueKey('tmdb-episodes-empty'))),
          );
          await _settle(tester);
          expect(tester.takeException(), isNull);
          if ((Platform.environment['DETAIL_RATINGS_CAPTURE_PHASE'] ?? '')
              .isEmpty) {
            return;
          }
          await tester.runAsync(() async {
            final render =
                boundary.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final image = await render.toImage(pixelRatio: 1);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final file = File(
              '../../.local/detail-ratings/'
              '$phase-$width-${brightness.name}.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        });
      }
    }
  }
}
