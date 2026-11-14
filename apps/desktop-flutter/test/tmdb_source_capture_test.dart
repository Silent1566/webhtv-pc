import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/tmdb_detail_model.dart';
import 'package:webhtv_pc/ui/theme.dart';
import 'package:webhtv_pc/ui/tmdb_detail_view.dart';

import 'dart:async';
import 'dart:convert';

import 'tmdb_source_state_test.dart';

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final font = File('/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc');
    if (font.existsSync()) {
      await (FontLoader(
        'FixtureCJK',
      )..addFont(font.readAsBytes().then(ByteData.sublistView))).load();
    }
    final root =
        Platform.environment['FLUTTER_ROOT'] ??
        '../../.local/linux-build/flutter';
    final icons = File(
      '$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    );
    if (icons.existsSync()) {
      await (FontLoader(
        'MaterialIcons',
      )..addFont(icons.readAsBytes().then(ByteData.sublistView))).load();
    }
  });
  setUp(() {
    debugNetworkImageHttpClientProvider = () => _FixtureClient();
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });
  tearDown(() => debugNetworkImageHttpClientProvider = null);
  testWidgets('source detail existing presenter actual state no credentials', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 950);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final client = SourceClient();
    final state = sourceState(client);
    final vod = sourceVod();
    await state.loadForVod(vod, siteKey: 's');
    final display = state.hasMatch ? state.enrich(vod).vod : vod;
    final data =
        state.detailData ??
        TmdbDetailData(
          title: display.vodName,
          overview: display.vodContent,
          posterUrl: display.vodPic,
        );
    final theme = buildAppTheme(Brightness.dark);
    final boundary = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: theme.copyWith(
          textTheme: theme.textTheme.apply(fontFamily: 'FixtureCJK'),
        ),
        home: RepaintBoundary(
          key: boundary,
          child: Scaffold(
            body: SingleChildScrollView(
              child: TmdbDetailView(data: data, paintBackdrop: false),
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pumpAndSettle();
    debugNetworkImageHttpClientProvider = null;
    expect(tester.takeException(), isNull);
    expect(client.requests, isEmpty);
    final phase = Platform.environment['TMDB_SOURCE_CAPTURE_PHASE'] ?? '';
    if (phase.isNotEmpty) {
      await tester.runAsync(() async {
        final image =
            await (boundary.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('../../.local/tmdb-source/$phase.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });
}
