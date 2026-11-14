import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:webhtv_pc/core/tmdb_config.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/services/tmdb_service.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/detail_source_merge.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/browse_pages.dart';
import 'package:webhtv_pc/ui/theme.dart';

const _sourceOverview = '接口返回的来源简介：TMDB 匹配不到时仍应显示这一段文字。';

class _ImageClient implements HttpClient {
  @override
  Future<HttpClientRequest> getUrl(Uri url) async => _ImageRequest();
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _ImageRequest implements HttpClientRequest {
  @override
  final HttpHeaders headers = _ImageHeaders();
  @override
  Future<HttpClientResponse> close() async => _ImageResponse();
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _ImageHeaders implements HttpHeaders {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _ImageResponse extends Stream<List<int>> implements HttpClientResponse {
  final bytes = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  );
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

class _TmdbClient extends http.BaseClient {
  _TmdbClient(this.scenario);
  final String scenario;
  final requests = <Uri>[];
  final gate = Completer<void>();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request.url);
    await gate.future;
    final failed = scenario == 'failed' || scenario == 'snapshot-empty';
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(jsonEncode({'results': []}))),
      failed ? 500 : 200,
    );
  }
}

Vod _vod({
  String? content = _sourceOverview,
  String id = 'overview-source',
  Object? payload,
}) => Vod(
  vodId: id,
  vodName: '无 TMDB 匹配的来源影片',
  vodContent: content,
  vodPic: 'https://fixture.test/poster.png',
  vodPlayFrom: id.isEmpty ? null : '线路一',
  vodPlayUrl: id.isEmpty ? null : r'第1集$https://fixture.test/1.m3u8',
  extra: {'tmdb': ?payload},
);

Map<String, Object?> _payload(String? overview, {bool identityOnly = false}) =>
    {
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
      'detail': identityOnly
          ? <String, Object?>{}
          : {
              'title': '来源匹配影片',
              'overview': overview,
              'credits': {'cast': [], 'crew': []},
              'images': {'posters': [], 'backdrops': []},
              'external_ids': {},
              'videos': {'results': []},
              'recommendations': {'page': 1, 'results': []},
              'similar': {'page': 1, 'results': []},
            },
    };

class _SiteClient extends http.BaseClient {
  _SiteClient(this.detailContent);
  final String? detailContent;
  final gate = Completer<void>();
  final requests = <Uri>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request.url);
    final ids = request.url.queryParameters['ids'];
    if (ids != null) await gate.future;
    return http.StreamedResponse(
      Stream.value(
        utf8.encode(
          jsonEncode({
            'list': ids == null
                ? []
                : [
                    {
                      'vod_id': ids,
                      'vod_name': '详情接口标题',
                      if (detailContent != null) 'vod_content': detailContent,
                      'vod_play_from': '详情线路',
                      'vod_play_url': r'第1集$https://fixture.test/detail.m3u8',
                      'detail_marker': 'detail-only',
                    },
                  ],
          }),
        ),
      ),
      200,
    );
  }
}

Future<void> _pumpFonts() async {
  final font = File('/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc');
  if (font.existsSync()) {
    await (FontLoader(
      'FixtureCJK',
    )..addFont(font.readAsBytes().then(ByteData.sublistView))).load();
  }
  final root =
      Platform.environment['FLUTTER_ROOT'] ?? '.local/linux-build/flutter';
  final icons = File(
    '$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  );
  if (icons.existsSync()) {
    await (FontLoader(
      'MaterialIcons',
    )..addFont(icons.readAsBytes().then(ByteData.sublistView))).load();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(_pumpFonts);
  test('display fill preserves detail fields, canonical identity, play facts and payload', () {
    final detailPayload = _payload('详情 payload 简介');
    final detail = Vod(
      vodId: 'canonical-id',
      vodName: '详情标题',
      vodContent: '详情简介',
      vodPic: 'detail-pic',
      vodRemarks: '详情备注',
      vodYear: '2025',
      vodArea: '详情地区',
      vodDirector: '详情导演',
      vodActor: '详情演员',
      vodPlayFrom: 'detail-line',
      vodPlayUrl: 'detail-url',
      vodTag: 'file',
      extra: {'tmdb': detailPayload, 'detail_only': 1},
    );
    final listing = Vod(
      vodId: 'requested-id',
      vodName: '列表标题',
      vodContent: _sourceOverview,
      vodPic: 'list-pic',
      vodRemarks: '列表备注',
      vodYear: '2024',
      vodArea: '列表地区',
      vodDirector: '列表导演',
      vodActor: '列表演员',
      vodPlayFrom: 'list-line',
      vodPlayUrl: 'list-url',
      vodTag: 'folder',
      extra: {'tmdb': _payload('列表 payload'), 'list_only': 1},
    );
    final merged = mergeSourceDetailDisplay(detail: detail, listing: listing);
    expect(merged.toJson(), detail.toJson());
    expect(merged.tmdb?.toJson(), detail.tmdb?.toJson());
    final empty = Vod(
      vodId: 'canonical-id',
      vodName: '详情标题',
      vodContent: '  ',
      vodPic: '',
      vodPlayFrom: 'detail-line',
      vodPlayUrl: 'detail-url',
      extra: detail.extra,
    );
    final filled = mergeSourceDetailDisplay(detail: empty, listing: listing);
    expect(filled.vodContent, listing.vodContent);
    expect(filled.vodPic, listing.vodPic);
    expect(filled.vodRemarks, listing.vodRemarks);
    expect(filled.vodYear, listing.vodYear);
    expect(filled.vodArea, listing.vodArea);
    expect(filled.vodDirector, listing.vodDirector);
    expect(filled.vodActor, listing.vodActor);
    expect(filled.vodId, empty.vodId);
    expect(filled.vodName, empty.vodName);
    expect(filled.vodPlayFrom, empty.vodPlayFrom);
    expect(filled.vodPlayUrl, empty.vodPlayUrl);
    expect(filled.extra, detail.extra);
    expect(filled.extra.containsKey('list_only'), isFalse);
  });
  setUp(() {
    debugNetworkImageHttpClientProvider = () => _ImageClient();
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });
  tearDown(() => debugNetworkImageHttpClientProvider = null);

  for (final scenario in [
    'unconfigured',
    'miss',
    'failed',
    'snapshot-empty',
    'metadata-empty',
    'valid-long',
    'source-empty',
    'source-null',
    'source-whitespace',
    'synthetic-empty',
  ]) {
    testWidgets('actual source detail interface overview: $scenario', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 950);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final temp = Directory.systemTemp.createTempSync('webhtv-overview');
      addTearDown(() {
        try {
          temp.deleteSync(recursive: true);
        } catch (_) {}
      });
      final client = _TmdbClient(scenario);
      final config = scenario == 'unconfigured'
          ? const TmdbConfig()
          : const TmdbConfig(apiKey: 'fixture-key');
      final service = TmdbService(config: () => config, client: client);
      final state = AppState(
        tmdbService: service,
        paths: AppPaths.resolve(
          overrides: {
            'config': '${temp.path}/webhtv-pc',
            'data': '${temp.path}/webhtv-pc',
            'cache': '${temp.path}/webhtv-pc/cache',
            'state': '${temp.path}/webhtv-pc/logs',
          },
        ),
        log: LogService(),
      );
      addTearDown(state.dispose);
      await tester.runAsync(state.bootstrap);
      if (scenario != 'unconfigured') {
        await tester.runAsync(() => state.saveTmdbConfig(config));
      }
      final longOverview = '$_sourceOverview$_sourceOverview$_sourceOverview';
      final content = switch (scenario) {
        'source-empty' => '',
        'source-null' || 'synthetic-empty' => null,
        'source-whitespace' => '   ',
        _ => _sourceOverview,
      };
      final payload = switch (scenario) {
        'snapshot-empty' => _payload(null, identityOnly: true),
        'metadata-empty' => _payload(''),
        'valid-long' => _payload(longOverview),
        _ => null,
      };
      final blank =
          scenario.startsWith('source-') || scenario == 'synthetic-empty';
      final vod = _vod(
        content: content,
        payload: payload,
        id: scenario == 'synthetic-empty' ? '' : 'overview-source',
      );
      if (blank) {
        final previous = _vod(
          id: 'previous-work',
          payload: _payload('上一部作品的简介'),
        );
        await state.tmdb.loadForVod(previous, siteKey: 'fixture-site');
        expect(state.tmdb.detailData?.overview, '上一部作品的简介');
      }
      state.seedDetailForTest(vod: vod, phase: LoadPhase.loading);
      final loading = state.tmdb.loadForVod(vod, siteKey: 'fixture-site');
      final boundary = GlobalKey();
      final theme = buildAppTheme(Brightness.dark);
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: MaterialApp(
            theme: theme.copyWith(
              textTheme: theme.textTheme.apply(fontFamily: 'FixtureCJK'),
            ),
            home: DetailPage(state: state, vod: vod),
          ),
        ),
      );
      await tester.pump();
      if (!blank) {
        expect(
          find.text(scenario == 'valid-long' ? longOverview : _sourceOverview),
          findsOneWidget,
        );
      }
      client.gate.complete();
      await loading;
      state.seedDetailForTest(vod: vod);
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      if (blank) {
        expect(
          find.byKey(const ValueKey('tmdb-detail-hero-overview')),
          findsNothing,
        );
        expect(find.text('上一部作品的简介'), findsNothing);
      } else {
        expect(
          find.byKey(const ValueKey('tmdb-detail-hero-overview')),
          findsOneWidget,
        );
        expect(
          find.text(scenario == 'valid-long' ? longOverview : _sourceOverview),
          findsOneWidget,
        );
      }
      if (scenario == 'unconfigured') expect(client.requests, isEmpty);
      if (scenario == 'miss') {
        expect(state.tmdb.matchResult, isA<TmdbMatchMiss>());
      }
      if (scenario == 'failed') expect(state.tmdb.hasMatch, isFalse);
      if (scenario == 'snapshot-empty') {
        expect(state.tmdb.hasMatch, isTrue);
        expect(state.tmdb.detail, isNull);
      }
      if (scenario == 'synthetic-empty') {
        expect(state.playLinesOf(vod), isEmpty);
      } else {
        expect(
          state.playLinesOf(vod).single.episodes.single.url,
          'https://fixture.test/1.m3u8',
        );
      }
      debugNetworkImageHttpClientProvider = null;
      final phase = Platform.environment['TMDB_OVERVIEW_CAPTURE'] ?? '';
      if (phase.isNotEmpty && scenario == 'miss') {
        await tester.pump();
        await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File('../../.local/tmdb-overview/$phase.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
  for (final scenario in ['missing', 'whitespace', 'nonempty', 'both-empty']) {
    testWidgets('list synopsis survives sparse detail API: $scenario', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 950);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final temp = Directory.systemTemp.createTempSync(
        'webhtv-sparse-overview',
      );
      addTearDown(() {
        try {
          temp.deleteSync(recursive: true);
        } catch (_) {}
      });
      final detailContent = scenario == 'whitespace'
          ? '  '
          : scenario == 'nonempty'
          ? '详情接口自己的简介'
          : null;
      final siteClient = _SiteClient(detailContent);
      final tmdbClient = _TmdbClient('miss')..gate.complete();
      const config = TmdbConfig(apiKey: 'fixture-key');
      final state = AppState(
        httpClient: siteClient,
        tmdbService: TmdbService(config: () => config, client: tmdbClient),
        paths: AppPaths.resolve(
          overrides: {
            'config': '${temp.path}/webhtv-pc',
            'data': '${temp.path}/webhtv-pc',
            'cache': '${temp.path}/webhtv-pc/cache',
            'state': '${temp.path}/webhtv-pc/logs',
          },
        ),
        log: LogService(),
      );
      addTearDown(state.dispose);
      await tester.runAsync(state.bootstrap);
      await tester.runAsync(() => state.saveTmdbConfig(config));
      final imported = await tester.runAsync(
        () => state.importConfig(
          jsonEncode({
            'sites': [
              {
                'key': 'overview-fixture',
                'name': '来源简介夹具',
                'type': 1,
                'api': 'https://fixture.test/api',
                'searchable': 1,
              },
            ],
          }),
        ),
      );
      expect(imported, isTrue);
      final listVod = Vod(
        vodId: 'sparse-overview',
        vodName: '列表接口标题',
        vodContent: scenario == 'both-empty' ? null : _sourceOverview,
        vodPic: 'https://fixture.test/list-poster.png',
        vodRemarks: '列表备注',
        vodYear: '2024',
        vodArea: '来源地区',
        vodDirector: '来源导演',
        vodActor: '来源演员',
        vodPlayFrom: '列表旧线路',
        vodPlayUrl: r'旧集$https://fixture.test/list.m3u8',
        extra: {'list_marker': 'must-not-copy'},
      );
      if (scenario == 'both-empty') {
        state.seedDetailForTest(vod: _vod(id: 'previous-work'));
      }
      final boundary = GlobalKey();
      final theme = buildAppTheme(Brightness.dark);
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: MaterialApp(
            theme: theme.copyWith(
              textTheme: theme.textTheme.apply(fontFamily: 'FixtureCJK'),
            ),
            home: DetailPage(state: state, vod: listVod),
          ),
        ),
      );
      await tester.pump();
      if (scenario != 'both-empty') {
        expect(find.text(_sourceOverview), findsOneWidget);
      }
      siteClient.gate.complete();
      for (var j = 0; j < 15; j++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      debugNetworkImageHttpClientProvider = null;
      final phase = Platform.environment['TMDB_OVERVIEW_SPARSE_CAPTURE'] ?? '';
      if (phase.isNotEmpty && scenario == 'missing') {
        await tester.pump();
        await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File('../../.local/tmdb-overview/sparse-$phase.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      expect(state.detailPhase, LoadPhase.ready);
      expect(state.tmdb.matchResult, isA<TmdbMatchMiss>());
      expect(
        siteClient.requests.any(
          (url) => url.queryParameters['ids'] == listVod.vodId,
        ),
        isTrue,
      );
      expect(
        tmdbClient.requests.any((url) => url.path.endsWith('/search/multi')),
        isTrue,
      );
      if (scenario == 'both-empty') {
        expect(
          find.byKey(const ValueKey('tmdb-detail-hero-overview')),
          findsNothing,
        );
        expect(find.text(_sourceOverview), findsNothing);
      } else {
        final expected = scenario == 'nonempty'
            ? detailContent
            : _sourceOverview;
        expect(find.text(expected!), findsOneWidget);
        expect(state.selectedVod?.vodContent, expected);
        expect(state.detailResult?.list.first.vodContent, expected);
      }
      expect(state.selectedVod?.vodPic, listVod.vodPic);
      expect(state.selectedVod?.vodRemarks, listVod.vodRemarks);
      expect(state.selectedVod?.vodYear, listVod.vodYear);
      expect(state.selectedVod?.vodArea, listVod.vodArea);
      expect(state.selectedVod?.vodDirector, listVod.vodDirector);
      expect(state.selectedVod?.vodActor, listVod.vodActor);
      expect(state.selectedVod?.vodName, '详情接口标题');
      expect(state.selectedVod?.vodPlayFrom, '详情线路');
      expect(
        state.selectedVod?.vodPlayUrl,
        r'第1集$https://fixture.test/detail.m3u8',
      );
      expect(state.selectedVod?.extra['detail_marker'], 'detail-only');
      expect(state.selectedVod?.extra.containsKey('list_marker'), isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
