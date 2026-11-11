import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/tmdb_detail_model.dart';
import 'package:webhtv_pc/core/tmdb_media.dart';
import 'package:webhtv_pc/ui/app.dart' show PosterImage;
import 'package:webhtv_pc/ui/image_header_scope.dart';
import 'package:webhtv_pc/ui/theme.dart';
import 'package:webhtv_pc/ui/tmdb_detail_view.dart';

const _poster = 'https://fixture.test/poster.png';
const _still = 'https://fixture.test/still.png';
const _portrait = 'https://fixture.test/portrait.png';
const _broken = 'https://fixture.test/broken.png';
const _pngs = <String, String>{
  'https://fixture.test/poster.png': 'iVBORw0KGgoAAAANSUhEUgAAAKAAAADwCAIAAAAII/iNAAAE5UlEQVR4nO3csW1dNxhHcUrwGFkgXXpXniFFPEbmSJUBvICBZCo3LjxEChmKLd33dC/Jj/x4eH6lgRh8PPzLBiL54bcPH4u4HmcfQLEMDGdgOAPDGRjOwHAGhjMwnIHhDAxnYDgDwxkYzsBwBoYzMJyB4QwM9272AZj+/fuP17/4+5+fx5/kwe/J6uiw62sjSxu4j5NpfzQms38Gd1BRt/q/usrArVo6DWhs4CbthaIbG7herzahjQ1cqW+VuMYGhjNwjYjBBY3YwHAGhjPwZXF/IYr4nQ0MZ2A4A8MZGM7AcAaGM/Blcf+jPuJ3NjCcgeEMXCPia2nQV34Dwxm4Ut/Bxf3FzcD1elUJ/f5ZAzdpbxP93dEGbtVSaMD3vhu4g7pOY36ywR9d6cmfTdqFP12oQfwzGM7AcAaGMzCcgeEMDGdgOAPDGRjOwHAGhjMwnIHhDAxnYDgDwxkYzsBwBoYzMJyB4QwMZ2A4A8MZGM7AcAaGMzCcgeEMDGdgOAPDGRjOwHAGhjMwnIHhDAxnYDgDwxkYzsBwBoYzMJyB4dIF/vb1y+wjoKQLXGzcVa7Apu0uV+Bnlu4lUWCjRkgU+AV7d5E3sLrIEvhwr464XZbACpIi8J2lOuJGKQIrzgKBHXGL+YHtF2p+4DN8BNUmB7ZctDUWXHwKtZYJrDozA18dpSOu4ILhpgWum6MjvsoFw60X2BFfMiewkYZZb8HF93HFhMDmGWnJBRdfyTnfvn5ZNbBOGh244/Ic8X1P97P2gm18y/PNDA1sj/HWXnDx0Rz58U6WD6wXXrz4cYHjpuaI73DBKK/f+qDA0SNzxOXGJbhgOE7gzUd86+OPCLz51Q9w54Y5Cy6+pCPhgb30aPdvGLXgst97evPz0gLrhdjAU/a0z4jPfFIXvKqT7zgw8MQl7TPiN7ngJZ1/wdjA4BFf+mhRgcH3uxbsggv0kV39UCGBkTebQcXFkhdcfGr4wCR1j7V/4GyjyXaeOtWfwgXDdQ6ccy45T3Vey/l3WfC6jRtPvkvgbfUMnHwlyY93qP3MLjivLi+yW+Al9rHEIftywUn1eovbBV5ixB0P2SfwEre2p+0WXNI/x77H6xA4+X2tpftl7rjgstOj3DRwThHPrjXwulPIdvKg87hguKbA2UZwVZ7zx53EBc8X+s52D5xnxEHqA+OvZozoa9x9wYX+Q3KVgZ3vKlxwKegfVDfwHMOeVE1g5Ndn5IcqLniKkY/pcmDqSy+jPtrgC3TBcAb+Ce+fPb4WGPz1+RnsX6Z3wXAXAu8w3ycRn3TW7bngESZuw8DHMF+uzgbGfODx5l6dC76pS5jpwzgVePopVc0F39P4sjMMw8BRMtQtZwInOegsq398Fxwiz7N4I3Ceg0509RJSXZoLhjPwKedHmWq+5X7gbGfNL+GNueCzEsY742bgRT/PRDlvzAVfcCdhzrrFwHjHgdO+x+kObybzdbngVpnrlsPAyU883Vr344Kb5I9t4BpPXfPXLa8DL3FoneeCK62yhJ8Cr3JoneeC4QwM939gvz4juWC474GdL5ULhjMw3GPx6zOaC4Z7dL5sLhjOwHAGhjMwnIHhDAxnYDgDwxkYzsBwBoYzMNzDX5/+mX0GBXLBcA+//Pp+9hkUyAXDGRjOwHAGhjMwnIHhDAxnYDgDw/0HH0f0UptyPbAAAAAASUVORK5CYII=',
  'https://fixture.test/still.png': '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',
  'https://fixture.test/portrait.png': 'iVBORw0KGgoAAAANSUhEUgAAAGgAAAB0CAIAAADmauAWAAACh0lEQVR4nO2cwU3DUBAFCaIOSuCGRAHUkBK4QAPQAA1wogRqoAAkbpRAJRz2gkgI8Xj37bd5c4xs7+7ofdtynGy2tw8nZjqn3Q0sFYuDWBzE4iAWB7E4iMVBLA5icRCLg1gcxOIgZ90N7OHu+nzv50+vn+JODjCQuN987W4wgsFRluqf1vDGRfQnjlmIvRqj15y4mdlpjF6nuJSxu9y1iUscuMVdj7j0UfXuGsQVDSl2N8rtyOJQiyvNhTJ0UnGCwWTuvFQhOnGyLGgKOXEQi4OIxIlvsgTlnDiIxUEsDqIQ1/L0orqoEwexOIjFQSwOYnEQi4NYHMTiIBYHsTiIQlzLGx7VRZ04iMVBLA4iEic+zQnKOXEQi4PoxMlWq6aQEweRihNkQZZrdeJKB1Neu71UIQ3iinIhvlXsSVz6kPrnCG1LNXHUlqcvnee4lIG7fpXU/Fuup9fP7+8q3Dy+HN7++X77Y/eSto5g0/6nVB/vb2zHi8ur3E4m0ZY47Gv3CC0GG8TNV7b3gGJ9UnHpynYPLtOnu6qWWhNXOdEkTjbM93LV0StPnNiarG6tuC5rguqF4nqtVfdQJW4Ea0FRJyXixrEWVPSTL240a0F6V8nixrQW5PaWKW5ka0Fih2nixrcWZPXpL2sgOeKWErcgpdsEccuyFszv2UsVMlfcEuMWzOx8lrjlWgvm9O+lCuHilh63AE/hxEGguHXELWCzOHEQi4MQcWtapwGYyImDTBa3vrgFU+dy4iAWB7E4yDRxaz3BBZOmc+IgFgexOMgEces+wQXHz+jEQSwOYnEQi4McK+4/XBmCIyd14iAWB7E4iMVBLA5icRCLg1gcxOIgFgexOIjFQb4AQc/MmXA98FUAAAAASUVORK5CYII=',
};

class _FixtureClient implements HttpClient {
  final requests = <String>[];
  final sentHeaders = <String, Map<String, String>>{};
  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    requests.add(url.toString());
    final headers = _FixtureHeaders();
    sentHeaders[url.toString()] = headers.values;
    return _FixtureRequest(url.toString(), headers);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FixtureRequest implements HttpClientRequest {
  _FixtureRequest(this.url, this.headers);
  final String url;
  @override
  final HttpHeaders headers;
  @override
  Future<HttpClientResponse> close() async => _FixtureResponse(url);
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FixtureHeaders implements HttpHeaders {
  final values = <String, String>{};
  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) {
    values[name.toLowerCase()] = value.toString();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FixtureResponse extends Stream<List<int>> implements HttpClientResponse {
  _FixtureResponse(String url)
    : bytes = base64Decode(
        _pngs[url] ?? _pngs['https://fixture.test${Uri.parse(url).path}'] ?? '',
      );
  final Uint8List bytes;
  @override
  int get statusCode => bytes.isEmpty ? 404 : 200;
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

final _cards = <TmdbEpisodeCard>[
  const TmdbEpisodeCard(
    number: 1,
    title: '真实剧照',
    stillUrl: _still,
    runtime: 42,
  ),
  const TmdbEpisodeCard(number: 2, title: '缺失剧照', runtime: 45),
  const TmdbEpisodeCard(number: 3, title: '空白剧照', stillUrl: '  ', runtime: 48),
  const TmdbEpisodeCard(
    number: 4,
    title: '加载失败',
    stillUrl: _broken,
    runtime: 40,
  ),
];
final _people = <TmdbPerson>[
  const TmdbPerson(
    personId: 1,
    name: '真实照片',
    profileUrl: _portrait,
    subtitle: '演员',
  ),
  const TmdbPerson(personId: 2, name: '张明', subtitle: '演员'),
  const TmdbPerson(
    personId: 3,
    name: '  Ada Lovelace  ',
    profileUrl: ' ',
    subtitle: '演员',
  ),
  const TmdbPerson(
    personId: 4,
    name: '李华',
    profileUrl: _broken,
    subtitle: '演员',
  ),
  const TmdbPerson(
    personId: 5,
    name: 'Élodie Dupont',
    profileUrl: _broken,
    subtitle: '演员',
  ),
  const TmdbPerson(personId: 6, name: '👩🏽‍🚀 星际旅人', subtitle: '演员'),
  const TmdbPerson(personId: 7, name: ' ', subtitle: '演员'),
];
TmdbDetailData _data({String? poster = _poster}) => TmdbDetailData(
  title: '详情缺图状态 · 固定测试夹具',
  posterUrl: poster,
  overview: '剧照优先；缺失或加载失败时回退海报。真实照片保留，演职人员与制作团队共用姓名字标。',
  cast: _people,
  creatorTeam: [
    for (final p in _people)
      TmdbPerson(
        personId: p.personId,
        name: p.name,
        profileUrl: p.profileUrl,
        subtitle: '制作团队',
      ),
  ],
);

Widget _host(
  Widget child, {
  Brightness brightness = Brightness.dark,
  Key? captureKey,
}) {
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
  for (var i = 0; i < 12; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
  await tester.pumpAndSettle();
  debugNetworkImageHttpClientProvider = null;
}

Finder _imageForEpisode(int number) => find.descendant(
  of: find.byKey(ValueKey('tmdb-episode-card-still-$number')),
  matching: find.byType(RawImage),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _FixtureClient client;
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
    client = _FixtureClient();
    debugNetworkImageHttpClientProvider = () => client;
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });
  tearDown(() {
    debugNetworkImageHttpClientProvider = null;
  });

  for (final width in [1280, 900]) {
    for (final brightness in Brightness.values) {
      testWidgets('capture fixtures $width ${brightness.name}', (tester) async {
        tester.view.physicalSize = Size(width.toDouble(), 950);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final boundary = GlobalKey();
        await tester.pumpWidget(
          _host(
            TmdbDetailView(
              data: _data(),
              episodeCards: _cards,
              gridMode: true,
              paintBackdrop: false,
              onEpisodeTap: (_, _) {},
            ),
            brightness: brightness,
            captureKey: boundary,
          ),
        );
        await Scrollable.ensureVisible(
          tester.element(find.byKey(const ValueKey('tmdb-section-episodes'))),
        );
        await _settle(tester);
        expect(tester.takeException(), isNull);
        final phase = Platform.environment['DETAIL_IMAGE_CAPTURE_PHASE'] ?? '';
        if (phase.isNotEmpty) {
          await tester.runAsync(() async {
            final render =
                boundary.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final image = await render.toImage(pixelRatio: 1);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final file = File(
              '../../.local/detail-image-fallback/$phase-$width-${brightness.name}.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
      });
    }
  }

  for (final number in [2, 3, 4]) {
    testWidgets(
      'episode $number resolves missing blank or broken still to poster',
      (tester) async {
        await tester.pumpWidget(
          _host(
            TmdbDetailView(
              data: _data(),
              episodeCards: [_cards[number - 1]],
              paintBackdrop: false,
            ),
          ),
        );
        await _settle(tester);
        expect(
          _imageForEpisode(number),
          findsOneWidget,
          reason:
              'missing or failed still must render the decoded series poster',
        );
        final image = tester.widget<RawImage>(_imageForEpisode(number));
        expect(image.image, isNotNull);
        expect(image.image!.width, 160);
        expect(image.image!.height, 240);
      },
    );
  }
  testWidgets('episode valid still is retained', (tester) async {
    await tester.pumpWidget(
      _host(
        TmdbDetailView(
          data: _data(),
          episodeCards: [_cards.first],
          paintBackdrop: false,
        ),
      ),
    );
    await _settle(tester);
    expect(tester.widget<RawImage>(_imageForEpisode(1)).image!.width, 320);
  });

  testWidgets(
    'cast and crew missing and failed portraits use identical lettermarks',
    (tester) async {
      await tester.pumpWidget(_host(TmdbDetailSections(data: _data())));
      await _settle(tester);
      for (final prefix in ['tmdb-person', 'tmdb-crew']) {
        for (final entry in {
          2: '张',
          3: 'AL',
          4: '李',
          5: 'ÉD',
          6: '星',
        }.entries) {
          expect(
            find.descendant(
              of: find.byKey(ValueKey('$prefix-${entry.key}')),
              matching: find.text(entry.value),
            ),
            findsOneWidget,
          );
        }
        expect(
          find.descendant(
            of: find.byKey(ValueKey('$prefix-7')),
            matching: find.byIcon(Icons.person_outline),
          ),
          findsOneWidget,
        );
        final photo = tester.widget<RawImage>(
          find.descendant(
            of: find.byKey(ValueKey('$prefix-1')),
            matching: find.byType(RawImage),
          ),
        );
        expect(photo.image, isNotNull);
      }
      expect(tester.takeException(), isNull);
    },
  );
  final imageRules = [
    HeaderRule(
      host: 'stills.test',
      header: HeaderMap({'Referer': 'https://stills.test/'}),
    ),
    HeaderRule(
      host: 'posters.test',
      header: HeaderMap({'Referer': 'https://posters.test/'}),
    ),
  ];
  const scopedPoster = 'https://posters.test/poster.png';
  const scopedBroken = 'https://stills.test/broken.png';

  for (final primary in <String?>[null, '  ']) {
    testWidgets('resolved poster headers for absent still $primary', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          ImageHeaderScope(
            rules: imageRules,
            child: PosterImage(url: primary, fallbackUrl: scopedPoster),
          ),
        ),
      );
      await _settle(tester);
      expect(client.requests, [scopedPoster]);
      expect(
        client.sentHeaders[scopedPoster]?['referer'],
        'https://posters.test/',
      );
      expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
    });
  }
  testWidgets('failed still uses its own headers then poster host headers', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        ImageHeaderScope(
          rules: imageRules,
          child: const PosterImage(
            url: scopedBroken,
            fallbackUrl: scopedPoster,
          ),
        ),
      ),
    );
    await _settle(tester);
    expect(client.requests, [scopedBroken, scopedPoster]);
    expect(
      client.sentHeaders[scopedBroken]?['referer'],
      'https://stills.test/',
    );
    expect(
      client.sentHeaders[scopedPoster]?['referer'],
      'https://posters.test/',
    );
    expect(
      tester.widget<RawImage>(find.byType(RawImage).last).image,
      isNotNull,
    );
  });

  for (final primary in <String?>[null, '  ']) {
    testWidgets('absent still failed poster requests only once $primary', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(PosterImage(url: primary, fallbackUrl: _broken)),
      );
      await _settle(tester);
      expect(client.requests, [_broken]);
      expect(find.byIcon(Icons.image_not_supported_outlined), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('distinct failed still and poster each request only once', (
    tester,
  ) async {
    const failedPoster = 'https://posters.test/broken.png';
    await tester.pumpWidget(
      _host(const PosterImage(url: scopedBroken, fallbackUrl: failedPoster)),
    );
    await _settle(tester);
    expect(client.requests, [scopedBroken, failedPoster]);
    expect(find.byIcon(Icons.image_not_supported_outlined), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('same trimmed URLs do not retry failed image', (tester) async {
    await tester.pumpWidget(
      _host(const PosterImage(url: ' $_broken ', fallbackUrl: _broken)),
    );
    await _settle(tester);
    expect(client.requests, [_broken]);
    expect(find.byIcon(Icons.image_not_supported_outlined), findsOneWidget);
  });
  testWidgets('missing both image URLs keeps normal placeholder', (
    tester,
  ) async {
    await tester.pumpWidget(_host(const PosterImage(url: '  ')));
    await _settle(tester);
    expect(client.requests, isEmpty);
    expect(find.byIcon(Icons.image_not_supported_outlined), findsOneWidget);
  });
  testWidgets('monogram uses supported bold font and semantic panel colors', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const SizedBox(
          width: 104,
          height: 116,
          child: PersonMonogram(name: '张明'),
        ),
      ),
    );
    await _settle(tester);
    final text = tester.widget<Text>(find.text('张'));
    expect(text.style?.fontWeight, FontWeight.w700);
    final theme = Theme.of(tester.element(find.text('张')));
    expect(text.style?.color, theme.colorScheme.onSurfaceVariant);
    final panel = tester.widget<Container>(
      find.byKey(const ValueKey('person-monogram')),
    );
    expect(panel.color, theme.colorScheme.surfaceContainerHigh);
  });
}
