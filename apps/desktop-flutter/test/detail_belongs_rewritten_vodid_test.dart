import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/tmdb_config.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/tmdb_enrichment_service.dart';
import 'package:webhtv_pc/services/tmdb_identity_service.dart';
import 'package:webhtv_pc/services/tmdb_season_service.dart';
import 'package:webhtv_pc/services/tmdb_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/state/tmdb_state.dart';
import 'package:webhtv_pc/ui/browse_pages.dart';
import 'package:webhtv_pc/ui/tmdb_widgets.dart';
import 'package:webhtv_pc/ui/toast.dart';

const _listId = r'2$swz14y33hdc-2946404633528039801$1';
const _detailId = r'2$15178$1';
final _listVod = Vod(vodId: _listId, vodName: '列表标题');
final _site = Site(
  key: 'rewritten-site',
  name: '重写 ID 站点',
  type: 1,
  api: 'http://127.0.0.1:1/api',
);

class _SiteClient extends http.BaseClient {
  bool noLines = false;
  final Map<String, Completer<void>> gates = {};
  final List<String> detailIds = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final id = request.url.queryParameters['ids'];
    if (id == null) return _response({'list': []});
    detailIds.add(id);
    final gate = gates[id];
    if (gate != null) await gate.future;
    final previous = id == 'previous-list';
    return _response({
      'list': [
        {
          'vod_id': previous ? 'previous-authoritative' : _detailId,
          'vod_name': previous ? '上一部剧详情' : '权威详情标题',
          if (!noLines) 'vod_play_from': previous ? '上一部剧线路' : '权威线路',
          if (!noLines)
            'vod_play_url':
                '第1集\$http://127.0.0.1:1/e1.mp4#第2集\$http://127.0.0.1:1/e2.mp4',
        },
      ],
    });
  }
}

http.StreamedResponse _response(Object body) => http.StreamedResponse(
  Stream<List<int>>.value(utf8.encode(jsonEncode(body))),
  200,
);

class _TmdbClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      _response({'results': []});
}

// 只替换外部 TMDB 请求，详情请求及运行号保护仍走真实 AppState。
class _State extends AppState {
  _State({
    required super.paths,
    required super.log,
    required _SiteClient client,
  }) : super(httpClient: client) {
    const config = TmdbConfig(apiKey: 'test-key');
    final service = TmdbService(config: () => config, client: _TmdbClient());
    _tmdb = TmdbState(
      config: () => config,
      service: service,
      identityService: TmdbIdentityService(
        config: () => config,
        service: service,
        store: InMemoryTmdbMatchStore(),
      ),
      seasonService: TmdbSeasonService(store: InMemoryTmdbSeasonStore()),
      enrichmentService: TmdbEnrichmentService(
        service: service,
        config: () => config,
      ),
    );
  }

  late final TmdbState _tmdb;

  @override
  TmdbState get tmdb => _tmdb;

  @override
  Site get selectedSite => _site;
}

void main() {
  late Directory tempDir;
  late _SiteClient client;
  late _State state;
  late AppPaths paths;
  late LogService log;

  setUp(() async {
    dismissAllToasts();
    tempDir = await Directory.systemTemp.createTemp('webhtv-rewritten-detail');
    paths = AppPaths.resolve(
      overrides: {'roaming': tempDir.path, 'local': tempDir.path},
    );
    client = _SiteClient();
    log = LogService();
    state = _State(paths: paths, log: log, client: client);
    await state.bootstrap();
    expect(
      await state.importConfig(
        jsonEncode({
          'sites': [
            {'key': _site.key, 'name': _site.name, 'type': 1, 'api': _site.api},
          ],
        }),
      ),
      isTrue,
    );
  });

  tearDown(() async {
    dismissAllToasts();
    state.dispose();
    await tempDir.delete(recursive: true);
  });

  Future<void> pumpDetail(
    WidgetTester tester,
    Vod vod, {
    VoidCallback? checkFirstFrame,
  }) async {
    tester.view.physicalSize = const Size(1400, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: DetailPage(state: state, vod: vod),
      ),
    );
    checkFirstFrame?.call();
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> scrollPastHero(WidgetTester tester) async {
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -3000));
    await tester.pump();
  }

  testWidgets('详情重写 vod_id 后仍展示权威线路、两集及 TMDB 状态条', (tester) async {
    await pumpDetail(tester, _listVod);
    expect(client.detailIds, [_listId]);
    expect(state.detailRequestVodId, _listId);
    expect(state.detailResult!.list.first.vodId, _detailId);
    expect(state.selectedVod!.vodId, _detailId);
    expect(state.tmdb.vodId, _detailId);
    expect(find.byKey(const ValueKey('detail-hero-play')), findsOneWidget);
    await scrollPastHero(tester);
    expect(find.textContaining('权威线路'), findsWidgets);
    expect(find.textContaining('2 集'), findsWidgets);
    expect(find.textContaining('第1集'), findsWidgets);
    expect(find.textContaining('第2集'), findsWidgets);
    expect(find.textContaining('没有可播放的剧集'), findsNothing);
    expect(find.byType(TmdbStatusBar), findsOneWidget);
    expect(find.byKey(const ValueKey('tmdb-status-unmatched')), findsOneWidget);
  });

  testWidgets('重写 ID 的无线路详情仍显示 TMDB 动作并用权威标题匹配', (tester) async {
    client.noLines = true;
    await pumpDetail(tester, _listVod);
    expect(state.tmdb.vodId, _detailId);
    await scrollPastHero(tester);
    expect(find.byType(TmdbStatusBar), findsOneWidget);
    final action = find.byKey(const ValueKey('detail-no-line-tmdb'));
    expect(action, findsOneWidget);
    expect(
      find.descendant(of: action, matching: find.text('匹配 TMDB')),
      findsOneWidget,
    );
    await tester.tap(action);
    await tester.pump();
    final input = tester.widget<TextField>(
      find.byKey(const ValueKey('tmdb-match-input')),
    );
    expect(input.controller!.text, '权威详情标题');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('新页面首帧不认领上一部剧的权威详情与 TMDB', (tester) async {
    await state.loadDetail(Vod(vodId: 'previous-list', vodName: '上一部剧'));
    expect(state.tmdb.vodId, 'previous-authoritative');
    final gate = Completer<void>();
    client.gates[_listId] = gate;
    await pumpDetail(
      tester,
      Vod(
        vodId: _listId,
        vodName: '本页列表标题',
        vodPlayFrom: '本页列表线路',
        vodPlayUrl: '本页第1集\$http://127.0.0.1:1/current.mp4',
      ),
      checkFirstFrame: () {
        expect(find.text('上一部剧详情'), findsNothing);
        expect(find.byType(TmdbStatusBar), findsNothing);
        expect(find.text('本页列表标题'), findsWidgets);
      },
    );
    await scrollPastHero(tester);
    expect(find.text('上一部剧详情'), findsNothing);
    expect(find.textContaining('上一部剧线路'), findsNothing);
    expect(find.textContaining('本页列表线路'), findsWidgets);
    gate.complete();
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  });

  test('上一部剧的迟到响应不能覆盖最新请求的权威条目', () async {
    final gate = Completer<void>();
    client.gates['previous-list'] = gate;
    final previous = state.loadDetail(
      Vod(vodId: 'previous-list', vodName: '上一部剧'),
    );
    await state.loadDetail(_listVod);
    expect(state.detailRequestVodId, _listId);
    expect(state.detailResult!.list.first.vodId, _detailId);
    gate.complete();
    await previous;
    expect(state.detailRequestVodId, _listId);
    expect(state.detailResult!.list.first.vodId, _detailId);
    expect(state.selectedVod!.vodId, _detailId);
    expect(state.tmdb.vodId, _detailId);
    expect(
      log.entries.any((entry) => entry.message.contains('详情结果已作废')),
      isTrue,
    );
  });

  test('详细调试开关切换写自检日志，启动恢复开启也写提示', () async {
    expect(await state.setSpiderDebugLog(true), isTrue);
    expect(state.spiderDebugLog, isTrue);
    expect(log.entries.last.scope, 'spider');
    expect(log.entries.last.level, LogLevel.info);
    expect(log.entries.last.message, '详细调试日志已开启（爬虫入参/出参全量打印）');
    expect(await state.setSpiderDebugLog(false), isTrue);
    expect(state.spiderDebugLog, isFalse);
    expect(log.entries.last.message, '详细调试日志已关闭');
    expect(await state.setSpiderDebugLog(true), isTrue);
    state.dispose();
    log = LogService();
    state = _State(paths: paths, log: log, client: _SiteClient());
    await state.bootstrap();
    expect(state.spiderDebugLog, isTrue);
    expect(
      log.entries.where(
        (entry) =>
            entry.scope == 'spider' &&
            entry.level == LogLevel.info &&
            entry.message == '详细调试日志已开启（爬虫入参/出参全量打印）',
      ),
      hasLength(1),
    );
  });
}
