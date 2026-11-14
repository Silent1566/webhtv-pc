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
import 'package:webhtv_pc/core/tmdb_detail_model.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/core/tmdb_source_payload.dart';
import 'package:webhtv_pc/services/tmdb_service.dart';
import 'package:webhtv_pc/ui/theme.dart';
import 'package:webhtv_pc/ui/tmdb_episode_detail.dart';

import 'tmdb_source_state_test.dart' show sourceVod, sourceDetail;

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

class _EpisodeClient extends http.BaseClient {
  final requests = <Uri>[];
  int status = 200;
  String videoKey = 'dQw4w9WgXcQ';
  Completer<void>? gate;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request.url);
    if (gate != null) await gate!.future;
    final body = {
      'id': 421,
      'season_number': 1,
      'episode_number': 1,
      'name': '网络单集标题',
      'overview': '网络单集简介：这条内容来自 TMDB 请求。',
      'air_date': '2024-06-02',
      'still_path': '/network-still.png',
      'runtime': 58,
      'vote_average': 9.1,
      'images': {'stills': []},
      'videos': {
        'results': [
          {
            'id': 'net-video',
            'key': videoKey,
            'site': 'YouTube',
            'name': '网络单集视频',
            'type': 'Trailer',
          },
        ],
      },
    };
    return http.StreamedResponse(
      Stream<List<int>>.value(
        utf8.encode(
          jsonEncode(
            request.url.path.endsWith('/videos') ? body['videos'] : body,
          ),
        ),
      ),
      status,
    );
  }
}

final _payload = TmdbSourcePayload.fromJson({
  'schema': 1,
  'id': 42,
  'media_type': 'tv',
  'season_number': 1,
  'language': 'zh-CN',
  'complete': ['episode:1:1', 'episode_videos:1:1'],
  'detail': {
    'seasons': [
      {
        'season_number': 1,
        'episodes': [
          {
            'id': 421,
            'season_number': 1,
            'episode_number': 1,
            'name': '来源单集标题',
            'overview': '来源单集简介：离线内嵌内容',
            'still_path': '/source-still.png',
            'runtime': 47,
            'vote_average': 8.4,
            'videos': {
              'results': [
                {
                  'id': 'source-video',
                  'key': 'dQw4w9WgXcQ',
                  'site': 'YouTube',
                  'name': '来源单集视频',
                  'type': 'Trailer',
                },
              ],
            },
          },
        ],
      },
    ],
  },
})!;

const _item = TmdbItem(
  tmdbId: 42,
  mediaType: TmdbMediaType.tv,
  title: '来源剧集作品',
);

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

  for (final scenario in [
    'complete',
    'movie-complete',
    'no-key',
    'partial',
    'failure',
    'wrong-identity',
    'stale-config',
    'stale-disabled-sites',
    'stale-allowed-sites',
    'stale-enabled-sites',
    'cross-season',
    'disabled',
  ]) {
    testWidgets('source payload episode modal $scenario', (tester) async {
      tester.view.physicalSize = const Size(1280, 950);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final client = _EpisodeClient();
      var config = scenario == 'no-key'
          ? const TmdbConfig()
          : const TmdbConfig(apiKey: 'key');
      if (scenario == 'disabled') {
        config = const TmdbConfig(enabled: false, apiKey: 'key');
      }
      if (scenario.startsWith('stale-')) {
        client.gate = Completer<void>();
        client.videoKey = '9bZkp7q19f0';
      }
      final payload = scenario == 'movie-complete'
          ? TmdbSourcePayload.fromJson(sourceVod().extra['tmdb'])!
          : scenario == 'cross-season'
          ? TmdbSourcePayload.fromJson({
              ..._payload.toJson(),
              'season_number': 2,
              'complete': [],
              'detail': {
                'episodes': [
                  {
                    'id': 421,
                    'episode_number': 1,
                    'name': '来源第二季集',
                    'overview': '不应贴到第一季',
                    'still_path': '/s2.png',
                  },
                ],
              },
            })!
          : scenario == 'partial'
          ? TmdbSourcePayload.fromJson({
              ..._payload.toJson(),
              'complete': [],
              'detail': {'seasons': []},
            })!
          : scenario == 'wrong-identity'
          ? TmdbSourcePayload.fromJson({..._payload.toJson(), 'id': 99})!
          : (scenario == 'failure' || scenario.startsWith('stale-'))
          ? TmdbSourcePayload.fromJson({
              ..._payload.toJson(),
              'complete': ['episode:1:1'],
            })!
          : _payload;
      if (scenario == 'failure') client.status = 500;
      final service = TmdbService(config: () => config, client: client);
      final boundary = GlobalKey();
      final theme = buildAppTheme(Brightness.dark);
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: MaterialApp(
            theme: theme.copyWith(
              textTheme: theme.textTheme.apply(fontFamily: 'FixtureCJK'),
            ),
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: FilledButton(
                    onPressed: () => showTmdbEpisodeDetails(
                      context,
                      card: const TmdbEpisodeCard(
                        number: 1,
                        seasonNumber: 1,
                        title: '来源第一集',
                      ),
                      sourceName: '第1集',
                      service: service,
                      item: scenario == 'movie-complete'
                          ? const TmdbItem(
                              tmdbId: 42,
                              mediaType: TmdbMediaType.movie,
                              title: '来源内嵌电影',
                            )
                          : _item,
                      sourcePayload: payload,
                    ),
                    child: const Text('打开单集'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开单集'));
      if (scenario.startsWith('stale-')) {
        await tester.pump();
        config = switch (scenario) {
          'stale-disabled-sites' => const TmdbConfig(
            apiKey: 'key',
            disabledSites: ['s'],
          ),
          'stale-allowed-sites' => const TmdbConfig(
            apiKey: 'key',
            allowedSites: ['s'],
          ),
          'stale-enabled-sites' => const TmdbConfig(
            apiKey: 'key',
            enabledSites: ['s'],
          ),
          _ => const TmdbConfig(apiKey: 'changed'),
        };
        client.gate!.complete();
      }
      for (var i = 0; i < 12; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pumpAndSettle();
      debugNetworkImageHttpClientProvider = null;
      expect(tester.takeException(), isNull);
      debugPrint('TMDB_MODAL_REQUESTS=${client.requests.length}');
      if (scenario == 'movie-complete') {
        expect(find.text(sourceDetail()['overview'] as String), findsOneWidget);
        expect(client.requests, isEmpty);
      } else if (scenario == 'disabled') {
        expect(find.text('来源单集简介：离线内嵌内容'), findsNothing);
        expect(client.requests, isEmpty);
      } else if (scenario.startsWith('stale-')) {
        expect(find.text('来源单集简介：离线内嵌内容'), findsOneWidget);
        expect(find.text('网络单集视频'), findsNothing);
        expect(client.requests.length, 1);
      } else if (scenario == 'partial' ||
          scenario == 'wrong-identity' ||
          scenario == 'cross-season') {
        expect(find.text('网络单集简介：这条内容来自 TMDB 请求。'), findsOneWidget);
        expect(client.requests.length, scenario == 'wrong-identity' ? 1 : 2);
        if (scenario == 'cross-season') {
          expect(find.text('不应贴到第一季'), findsNothing);
        }
      } else {
        expect(find.text('来源单集简介：离线内嵌内容'), findsOneWidget);
        expect(find.text('来源单集视频'), findsOneWidget);
        expect(client.requests.length, scenario == 'failure' ? 1 : 0);
      }
      final phase = Platform.environment['TMDB_SOURCE_MODAL_PHASE'] ?? '';
      if (phase.isNotEmpty && scenario == 'complete') {
        await tester.pump();
        await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File('../../.local/tmdb-source/$phase-modal.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
