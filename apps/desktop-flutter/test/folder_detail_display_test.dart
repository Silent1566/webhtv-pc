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
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/browse_pages.dart';
import 'package:webhtv_pc/ui/theme.dart';

const _parentId = 'atvp_detail:133099';
const _parentName = '父级作品标题';
const _quarkOverview = '夸克分享链返回的来源简介：详情页必须显示这一段。';

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

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

class _FolderFixture {
  final calls = <Uri>[];
  final gate = Completer<void>();

  MockClient client({String? parentContent}) => MockClient((request) async {
    calls.add(request.url);
    final query = request.url.queryParameters;
    if (query.containsKey('t')) {
      return _json({
        'list': [
          {
            'vod_id': 'https://share/baidu',
            'vod_name': '百度',
            'vod_tag': 'file',
          },
          {
            'vod_id': 'https://share/quark',
            'vod_name': '夸克',
            'vod_tag': 'file',
          },
          {'vod_id': 'https://share/uc', 'vod_name': 'UC', 'vod_tag': 'file'},
        ],
      });
    }
    final ids = query['ids'];
    if (ids != null) {
      if (ids.endsWith('/uc')) return _json({'code': -1, 'msg': '资源不可用'});
      await gate.future;
      final quark = ids.endsWith('/quark');
      return _json({
        'list': [
          {
            'vod_id': 'atvp_resume:${quark ? 'quark' : 'baidu'}',
            'vod_name': quark ? '夸克资源标题' : '百度资源标题',
            'vod_tag': 'file',
            if (quark) 'vod_content': _quarkOverview,
            if (!quark) 'vod_pic': 'https://fixture.test/baidu.png',
            if (quark) 'vod_remarks': '更新至第2集',
            if (!quark) 'vod_year': '2024',
            if (quark) 'vod_area': '中国大陆',
            if (quark) 'vod_director': '来源导演',
            if (quark) 'vod_actor': '来源演员',
            'vod_play_from': quark ? 'quark' : 'baidu',
            'vod_play_url': quark
                ? r'第2集$https://fixture.test/quark2.m3u8'
                : r'第1集$https://fixture.test/baidu1.m3u8',
            'child_marker': 'must-not-copy',
          },
        ],
      });
    }
    return _json({'list': []});
  });
}

Future<void> _loadFonts() async {
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

  setUpAll(_loadFonts);

  setUp(() {
    debugNetworkImageHttpClientProvider = () => _ImageClient();
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  tearDown(() => debugNetworkImageHttpClientProvider = null);

  testWidgets('folder detail retains child synopsis and fills display fields', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 950);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final temp = Directory.systemTemp.createTempSync('webhtv-folder-overview');
    addTearDown(() {
      try {
        temp.deleteSync(recursive: true);
      } catch (_) {}
    });
    final fixture = _FolderFixture();
    final state = AppState(
      httpClient: fixture.client(),
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
    final imported = await tester.runAsync(
      () => state.importConfig(
        jsonEncode({
          'sites': [
            {
              'key': 'bridge',
              'name': '网盘聚合站',
              'type': 4,
              'api': 'https://fixture.test/vod/api?key=bridge',
            },
          ],
        }),
      ),
    );
    expect(imported, isTrue);
    final parent = Vod(
      vodId: _parentId,
      vodName: _parentName,
      vodTag: 'folder',
      extra: {'parent_marker': 'kept'},
    );
    final boundary = GlobalKey();
    final theme = buildAppTheme(Brightness.dark);
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: MaterialApp(
          theme: theme.copyWith(
            textTheme: theme.textTheme.apply(fontFamily: 'FixtureCJK'),
          ),
          home: DetailPage(state: state, vod: parent),
        ),
      ),
    );
    await tester.pump();
    fixture.gate.complete();
    for (var i = 0; i < 15; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    debugNetworkImageHttpClientProvider = null;

    final phase = Platform.environment['FOLDER_OVERVIEW_CAPTURE'] ?? '';
    if (phase.isNotEmpty) {
      await tester.pump();
      await tester.runAsync(() async {
        final image =
            await (boundary.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('../../.local/tmdb-overview/folder-$phase.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }

    expect(state.detailPhase, LoadPhase.ready);
    expect(state.detailError, isNotNull);
    expect(state.detailError!.detail, contains('线路「UC」加载失败'));
    final vod = state.selectedVod!;
    expect(vod.vodId, _parentId);
    expect(vod.vodName, _parentName);
    expect(vod.vodContent, _quarkOverview);
    expect(vod.vodPic, 'https://fixture.test/baidu.png');
    expect(vod.vodRemarks, '更新至第2集');
    expect(vod.vodYear, '2024');
    expect(vod.vodArea, '中国大陆');
    expect(vod.vodDirector, '来源导演');
    expect(vod.vodActor, '来源演员');
    expect(vod.extra['parent_marker'], 'kept');
    expect(vod.extra.containsKey('tmdb'), isFalse);
    expect(vod.extra.containsKey('child_marker'), isFalse);
    expect(vod.vodTag, 'file');
    expect(state.playLinesOf(vod), hasLength(2));
    expect(
      state.playLinesOf(vod).map((line) => line.episodes.single.url),
      containsAll([
        'https://fixture.test/baidu1.m3u8',
        'https://fixture.test/quark2.m3u8',
      ]),
    );
    expect(find.text(_quarkOverview), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('parent synopsis wins over child display fields', (tester) async {
    tester.view.physicalSize = const Size(1280, 950);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final temp = Directory.systemTemp.createTempSync('webhtv-folder-parent');
    addTearDown(() {
      try {
        temp.deleteSync(recursive: true);
      } catch (_) {}
    });
    final fixture = _FolderFixture();
    final state = AppState(
      httpClient: fixture.client(),
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
    await tester.runAsync(
      () => state.importConfig(
        jsonEncode({
          'sites': [
            {
              'key': 'bridge',
              'name': '网盘聚合站',
              'type': 4,
              'api': 'https://fixture.test/vod/api?key=bridge',
            },
          ],
        }),
      ),
    );
    final parent = Vod(
      vodId: 'atvp_detail:parent-content',
      vodName: '已有简介的父级',
      vodContent: '父级自己的简介不能被其它作品覆盖',
      vodTag: 'folder',
    );
    fixture.gate.complete();
    await state.loadDetail(parent);
    expect(state.detailPhase, LoadPhase.ready);
    expect(state.selectedVod?.vodContent, '父级自己的简介不能被其它作品覆盖');
    expect(state.selectedVod?.vodName, '已有简介的父级');
    expect(state.selectedVod?.vodId, 'atvp_detail:parent-content');
    debugNetworkImageHttpClientProvider = null;
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
