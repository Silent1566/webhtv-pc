import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/core/playback_lines.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/tmdb_config.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/tmdb_enrichment_service.dart';
import 'package:webhtv_pc/services/tmdb_identity_service.dart';
import 'package:webhtv_pc/services/tmdb_season_service.dart';
import 'package:webhtv_pc/services/tmdb_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/state/tmdb_state.dart';

import 'support/detail_test_seams.dart';

class _DetailState extends AppState {
  _DetailState({
    required super.paths,
    required super.log,
    required super.httpClient,
    required super.tmdbService,
  }) : super(warmAutoRoutes: false) {
    const config = TmdbConfig(enabled: false);
    final service = tmdbService;
    metadata = TmdbState(
      config: () => config,
      service: service,
      identityService: TmdbIdentityService(
        config: () => config,
        service: service,
        store: InMemoryTmdbMatchStore(),
      ),
      seasonService: TmdbSeasonService(store: InMemoryTmdbSeasonStore()),
      enrichmentService: TmdbEnrichmentService(
        config: () => config,
        service: service,
      ),
    );
  }
  late final TmdbState metadata;
  @override
  TmdbState get tmdb => metadata;
}

class _Fixture {
  String mode = 'normal';
  final calls = <String>[];
  http.Response _reply(Object body) => http.Response(
    jsonEncode(body),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
  late final client = MockClient((request) async {
    final q = request.url.queryParameters;
    final category = q['t'];
    if (category != null) {
      calls.add('category:$category');
      return _reply({
        'list': [
          {'vod_id': 'share:good', 'vod_name': 'quark', 'vod_tag': 'file'},
          if (mode == 'partial')
            {'vod_id': 'share:bad', 'vod_name': 'UC', 'vod_tag': 'file'},
        ],
      });
    }
    final id = q['ids'];
    if (id != null) {
      calls.add('detail:$id');
      if (id == 'share:bad' ||
          mode == 'business' ||
          (id.startsWith('atvp_detail:') && mode != 'folder-empty')) {
        return _reply({'code': -1, 'msg': '该 id 不可用于详情'});
      }
      if (id.startsWith('atvp_detail:') || mode == 'empty') {
        return _reply({'list': []});
      }
      return _reply({
        'list': [
          {
            if (mode != 'blank') 'vod_id': 'rewritten:$id',
            if (mode != 'blank') 'vod_name': '示例剧',
            'vod_tag': 'file',
            if (mode != 'no-lines') 'vod_play_from': r'quark$$$backup',
            if (mode != 'no-lines') 'vod_play_url': r'第1集$https://media.invalid/1#第2集$https://media.invalid/2$$$第1集$https://media.invalid/backup',
          },
        ],
      });
    }
    return _reply({'class': [], 'list': []});
  });
}

List<List<Object?>> _signature(List<VodPlayLine> lines) => [
  for (final line in lines)
    [
      line.flag,
      line.playbackFlag,
      for (final episode in line.episodes) [episode.name, episode.url],
    ],
];

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late _Fixture fixture;
  late _DetailState state;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('webhtv-swap-parity');
    fixture = _Fixture();
    state = _DetailState(
      paths: AppPaths.resolve(
        overrides: {
          'config': '${root.path}/config',
          'data': '${root.path}/data',
          'cache': '${root.path}/cache',
          'state': '${root.path}/state',
        },
      ),
      log: MemoryOnlyLogService(),
      httpClient: fixture.client,
      tmdbService: TmdbService(
        config: () => const TmdbConfig(enabled: false),
        client: MockClient((_) async => http.Response('{"results":[]}', 200)),
      ),
    );
    expect(
      await state.importConfig(
        jsonEncode({
          'sites': [
            {
              'key': 'fixture',
              'name': '对照站',
              'type': 4,
              'api': 'https://fixture.invalid/api',
            },
          ],
        }),
      ),
      isTrue,
    );
  });
  tearDown(() async {
    state.dispose();
    await root.delete(recursive: true);
  });

  for (final mode in ['normal', 'blank']) {
    test('普通非目录与换源使用相同详情和线路：$mode', () async {
      fixture.mode = mode;
      final vod = Vod(vodId: 'movie:1', vodName: '示例剧');
      await state.loadDetail(vod);
      final normal = state.playLinesOf(state.selectedVod!);
      final before = state.selectedVod;
      final result = await state.swapProbe(
        siteKey: 'fixture',
        vodId: vod.vodId,
        vodName: vod.vodName,
        listing: vod,
      );
      expect(result.lines.length, 2);
      expect(result.lines.map((line) => line.episodes.length), [2, 1]);
      expect(_signature(result.lines), _signature(normal));
      expect(result.routes.values.map((route) => route.vodId).toSet(), {
        mode == 'blank' ? 'movie:1' : 'rewritten:movie:1',
      }, reason: '非目录线路也必须路由到详情返回的权威 vod_id，缺失身份时回填请求 id');
      expect(identical(state.selectedVod, before), isTrue);
      expect(state.selectedSite?.key, 'fixture');
    });
  }
  for (final mode in ['folder-empty', 'folder-business', 'partial']) {
    test('换源目录与普通详情的线路集数一致：$mode', () async {
      fixture.mode = mode;
      final vod = Vod(
        vodId: 'atvp_detail:fixture',
        vodName: '示例剧',
        vodTag: 'folder',
      );
      await state.loadDetail(vod);
      expect(state.detailPhase, LoadPhase.ready);
      final normal = state.playLinesOf(state.selectedVod!);
      fixture.calls.clear();
      PlaybackLines? result;
      AppError? failure;
      try {
        result = await state.swapProbe(
          siteKey: 'fixture',
          vodId: vod.vodId,
          vodName: vod.vodName,
          listing: vod,
        );
      } on AppError catch (error) {
        failure = error;
      }
      expect(failure, isNull, reason: '不得把父目录 id 用作影片详情 id');
      expect(result!.lines.length, 2);
      expect(result.lines.map((line) => line.episodes.length), [2, 1]);
      expect(_signature(result.lines), _signature(normal));
      expect(
        result.routes.keys.toSet(),
        result.lines.map((line) => line.flag).toSet(),
      );
      expect(result.routes.values.map((route) => route.vodId).toSet(), {
        'share:good',
      });
      if (mode == 'partial') {
        expect(result.warnings.single.message, contains('UC'));
        expect(result.warnings.single.kind, AppErrorKind.siteBusiness);
      } else {
        expect(result.warnings, isEmpty);
      }
      expect(fixture.calls.first, 'category:atvp_detail:fixture');
      expect(fixture.calls, isNot(contains('detail:atvp_detail:fixture')));
    });
  }
  test('详情 list 为空时换源保留搜索条目自带线路', () async {
    fixture.mode = 'empty';
    final vod = Vod(
      vodId: 'movie:listing',
      vodName: '示例剧',
      vodPlayFrom: 'listing',
      vodPlayUrl: r'第1集$https://media.invalid/listing',
    );
    await state.loadDetail(vod);
    final normal = state.playLinesOf(state.selectedVod!);
    final result = await state.swapProbe(
      siteKey: 'fixture',
      vodId: vod.vodId,
      vodName: vod.vodName,
      listing: vod,
    );
    expect(result.lines.length, 1);
    expect(result.lines.single.flag, 'listing');
    expect(_signature(result.lines), _signature(normal));
  });
  test('非桥接目录不拿目录 id 当影片详情，如实说明需进入详情', () async {
    fixture.mode = 'normal';
    final vod = Vod(vodId: 'folder:1', vodName: '示例目录', vodTag: 'folder');
    await expectLater(
      state.swapProbe(
        siteKey: 'fixture',
        vodId: vod.vodId,
        vodName: vod.vodName,
        listing: vod,
      ),
      throwsA(
        isA<AppError>().having(
          (error) => error.kind,
          'kind',
          AppErrorKind.siteUnsupported,
        ),
      ),
    );
    expect(fixture.calls, isEmpty);
  });
  test('详情返回条目但无线路时不使用 listing 伪造成功', () async {
    fixture.mode = 'no-lines';
    final vod = Vod(
      vodId: 'movie:listing',
      vodName: '示例剧',
      vodPlayFrom: 'listing',
      vodPlayUrl: r'第1集$https://media.invalid/listing',
    );
    final result = await state.swapProbe(
      siteKey: 'fixture',
      vodId: vod.vodId,
      vodName: vod.vodName,
      listing: vod,
    );
    expect(result.lines, isEmpty);
  });
  test('详情业务错误不回退 listing 掩盖源错误', () async {
    fixture.mode = 'business';
    final vod = Vod(
      vodId: 'movie:listing',
      vodName: '示例剧',
      vodPlayFrom: 'listing',
      vodPlayUrl: r'第1集$https://media.invalid/listing',
    );
    await expectLater(
      state.swapProbe(
        siteKey: 'fixture',
        vodId: vod.vodId,
        vodName: vod.vodName,
        listing: vod,
      ),
      throwsA(isA<AppError>()),
    );
  });
}
