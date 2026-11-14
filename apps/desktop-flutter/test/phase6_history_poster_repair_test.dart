/// 历史记录海报补齐的三级回退（`HistoryPosterRepair`）。
///
/// 真实缺陷（2026-11 用户反馈）：「最近观看」里桥接源的历史没有海报，显示破图
/// 占位。根因三条：
/// 1. 原来的补图只在**生效配置**里找站点，跨源记录 `site == null` 直接跳过；
/// 2. 桥接源的 `ac=detail&ids=` 实测返回 `vod_id:"" vod_pic:""`（空壳），
///    只有 `wd=片名` 搜索能拿到图；
/// 3. TMDB 匹配行里的海报挂在**非生效配置**上，按 config_id 收窄的查询读不到。
///
/// group A 只喂假协作者（无网络无数据库），逐级钉住回退顺序；
/// group B 用真实 AppState + MockClient 钉住「非生效配置的站点也会被查」。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/history_scope.dart';
import 'package:webhtv_pc/core/http_api.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/history_poster_repair.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/site_service.dart';
import 'package:webhtv_pc/services/spider_router.dart';
import 'package:webhtv_pc/services/storage.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/library_pages.dart';

/// 真机那条记录：siteKey/vodId/vodName 照抄，避免「测试里编的数据」漂移。
const String _siteKey = 'Hxq';
const String _vodId = 'w5_akN4sHJkojZBhuzXU';
const String _vodName = '现在拨打的电话';
const String _bridgeSource = 'bridge|dev-uuid-0001|other';

const String _tmdbPoster = 'http://img.example/tmdb.jpg';
const String _searchPoster = 'http://img.example/search.jpg';

/// 记录里记下的调用参数，用于断言回退真的用对了站点 / 影片。
class _Calls {
  final List<String> details = <String>[];
  final List<String> folders = <String>[];
  final List<String> searches = <String>[];
}

/// `ids=` 详情返回的行；各用例按需改写，复刻桥接站时用默认的空壳。
List<Map<String, Object?>> Function() _detailRows = () => <Map<String, Object?>>[
  <String, Object?>{'vod_id': '', 'vod_name': '', 'vod_pic': ''},
];

/// `wd=` 搜索返回的行。
List<Map<String, Object?>> Function() _searchRows = () => <Map<String, Object?>>[
  <String, Object?>{'vod_id': _vodId, 'vod_name': _vodName, 'vod_pic': _searchPoster},
];

PlaybackHistory _history({
  String siteKey = _siteKey,
  String vodId = _vodId,
  String vodName = _vodName,
  String sourceKey = _bridgeSource,
}) => PlaybackHistory(
  id: 1,
  siteKey: siteKey,
  vodId: vodId,
  vodName: vodName,
  flag: '线路一',
  episodeName: '第1集',
  episodeId: 'http://x/1',
  positionMs: 30000,
  durationMs: 100000,
  updatedAt: 1000,
  sourceKey: sourceKey,
);

Site _site({String key = _siteKey, bool searchable = true}) => Site(
  key: key,
  name: '猴哥',
  type: 4,
  api: 'http://127.0.0.1:19978/vod/api?key=Hxq',
  searchable: searchable,
  quickSearch: true,
);

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

/// 构造一个把请求都记进 [calls]、并按当前素材回答的 [SiteService]。
SiteService _service(AppConfig config, _Calls calls) => SiteService(
  appConfig: config,
  router: SpiderRouter(
    client: HttpApiClient(
      client: MockClient((request) async {
        final query = request.url.queryParameters;
        final tag = config.name ?? '';
        if (query.containsKey('ids')) {
          calls.details.add('$tag|${query['ids']}');
          return _json(<String, Object?>{'list': _detailRows()});
        }
        if (query.containsKey('t')) {
          calls.folders.add('$tag|${query['t']}');
          return _json(<String, Object?>{'list': _detailRows()});
        }
        if (query.containsKey('wd')) {
          calls.searches.add('$tag|${query['wd']}');
          return _json(<String, Object?>{'list': _searchRows()});
        }
        return _json(<String, Object?>{'list': <Object?>[]});
      }),
    ),
    globalHeaders: config.headers,
  ),
);

void main() {
  setUp(() {
    _detailRows = () => <Map<String, Object?>>[
      <String, Object?>{'vod_id': '', 'vod_name': '', 'vod_pic': ''},
    ];
    _searchRows = () => <Map<String, Object?>>[
      <String, Object?>{
        'vod_id': _vodId,
        'vod_name': _vodName,
        'vod_pic': _searchPoster,
      },
    ];
  });

  group('A · 三级回退顺序（全假协作者）', () {
    test('记录属于非生效配置时仍命中 L1，且把记录自己的站点传给详情', () async {
      final calls = _Calls();
      // 生效配置里没有这个站点——这正是原缺陷：按生效配置找不到就直接放弃。
      final active = AppConfig(name: '生效', sites: <Site>[_site(key: 'other')]);
      final recordConfig = AppConfig(name: '其他源', sites: <Site>[_site()]);
      _detailRows = () => <Map<String, Object?>>[
        <String, Object?>{
          'vod_id': _vodId,
          'vod_name': _vodName,
          'vod_pic': 'http://img.example/detail.jpg',
        },
      ];
      final repair = HistoryPosterRepair(
        siteService: _service(recordConfig, calls),
        configForSourceKey: (sourceKey) =>
            sourceKey == _bridgeSource ? recordConfig : null,
        cachedTmdbPosterUrl: (_, _) => _tmdbPoster,
        fallbackConfig: active,
      );

      final poster = await repair.posterFor(_history());

      expect(poster, 'http://img.example/detail.jpg', reason: 'L1 命中即短路');
      expect(
        calls.details,
        <String>['其他源|$_vodId'],
        reason: '必须用记录自己那份配置的站点查详情，并带上该记录的 vod_id',
      );
      expect(calls.searches, isEmpty, reason: 'L1 命中后不得再去搜索');
    });

    test('L1 返回空 vod_id + 空 vod_pic（真机桥接站）→ 命中 L2 TMDB 缓存', () async {
      final calls = _Calls();
      final active = AppConfig(name: '生效', sites: <Site>[_site()]);
      final repair = HistoryPosterRepair(
        siteService: _service(active, calls),
        configForSourceKey: (_) => null,
        cachedTmdbPosterUrl: (siteKey, vodId) {
          expect(siteKey, _siteKey);
          expect(vodId, _vodId);
          return _tmdbPoster;
        },
        fallbackConfig: active,
      );

      final poster = await repair.posterFor(_history());

      expect(poster, _tmdbPoster);
      expect(calls.details, <String>['生效|$_vodId'], reason: 'L1 确实先试过详情');
      expect(calls.searches, isEmpty, reason: 'L2 命中即短路');
    });

    test('没有 TMDB、详情是空壳 → L3 按片名搜索（前后空格差异也要认）', () async {
      final calls = _Calls();
      final active = AppConfig(name: '生效', sites: <Site>[_site()]);
      final repair = HistoryPosterRepair(
        siteService: _service(active, calls),
        configForSourceKey: (_) => null,
        cachedTmdbPosterUrl: (_, _) => null,
        fallbackConfig: active,
      );

      // 历史里保存的片名带空格，搜索结果里是干净的；vod_id 也对不上。
      final poster = await repair.posterFor(
        _history(vodName: '  $_vodName ', vodId: 'unknown_id'),
      );

      expect(poster, _searchPoster);
      expect(calls.searches, <String>['生效|$_vodName'], reason: '关键词必须 trim 后发送');
    });

    test('搜索里同名条目都对不上 → null（不瞎猜一张图）', () async {
      final calls = _Calls();
      final active = AppConfig(name: '生效', sites: <Site>[_site()]);
      _searchRows = () => <Map<String, Object?>>[
        <String, Object?>{
          'vod_id': 'another_id',
          'vod_name': '另一部剧',
          'vod_pic': 'http://img.example/other.jpg',
        },
      ];
      final repair = HistoryPosterRepair(
        siteService: _service(active, calls),
        configForSourceKey: (_) => null,
        cachedTmdbPosterUrl: (_, _) => null,
        fallbackConfig: active,
      );

      expect(await repair.posterFor(_history()), isNull);
    });

    test('三级全抛异常 → 返回 null，不把异常抛给历史页', () async {
      final active = AppConfig(name: '生效', sites: <Site>[_site()]);

      // 站点查不到（配置读取抛异常）→ 三级都没素材 → null。
      final noConfig = HistoryPosterRepair(
        siteService: _service(active, _Calls()),
        configForSourceKey: (_) => throw StateError('配置读不出来'),
        cachedTmdbPosterUrl: (_, _) => throw StateError('TMDB 读不出来'),
        fallbackConfig: active,
      );
      expect(await noConfig.posterFor(_history()), isNull);

      // 站点在，但详情、TMDB、搜索全炸：仍然只能是 null。
      final broken = SiteService(
        appConfig: active,
        router: SpiderRouter(
          client: HttpApiClient(
            client: MockClient((_) async => throw const SocketException('断网')),
          ),
          globalHeaders: active.headers,
        ),
      );
      final repair = HistoryPosterRepair(
        siteService: broken,
        configForSourceKey: (_) => active,
        cachedTmdbPosterUrl: (_, _) => throw StateError('TMDB 读不出来'),
        fallbackConfig: active,
      );
      expect(await repair.posterFor(_history()), isNull);
    });
  });

  group('B · 真实 AppState：非生效配置的站点也会被查详情', () {
    late Directory tempDir;
    late AppState state;
    late List<Uri> calls;

    setUp(() async {
      calls = <Uri>[];
      tempDir = await Directory.systemTemp.createTemp('webhtv-history-poster');
      state = AppState(
        paths: AppPaths.resolve(
          overrides: {
            'config': '${tempDir.path}/webhtv-pc',
            'data': '${tempDir.path}/webhtv-pc',
            'cache': '${tempDir.path}/webhtv-pc/cache',
            'state': '${tempDir.path}/webhtv-pc/logs',
          },
        ),
        log: LogService(),
        // 历史页后台补图会发真实 HTTP；`testWidgets` 是假时钟，真实 socket
        // I/O 会挂死（仓库纪律 webhtv-pc-test-io-layering），这里注入 MockClient。
        // 所有真实写盘（sqlite / 配置）都在 setUp 里完成，不进假时钟区。
        httpClient: MockClient((request) async {
          calls.add(request.url);
          final query = request.url.queryParameters;
          if (query.containsKey('ids')) {
            // 复刻真机桥接站：`ids=` 返回空壳。
            return _json(<String, Object?>{
              'list': <Object?>[
                <String, Object?>{'vod_id': '', 'vod_name': '', 'vod_pic': ''},
              ],
            });
          }
          return _json(<String, Object?>{'list': <Object?>[]});
        }),
      );
      await state.bootstrap();
      // 生效配置里**没有** Hxq。
      final ok = await state.importConfig(
        jsonEncode(<String, Object?>{
          'sites': <Object?>[
            <String, Object?>{
              'key': 'active_site',
              'name': '生效站点',
              'type': 4,
              'api': 'http://127.0.0.1:19978/vod/api?key=active',
            },
          ],
        }),
      );
      expect(ok, isTrue, reason: '前置：生效配置导入必须成功');
      // 非生效配置：Hxq 挂在这份上，历史记录的 source_key 指向它。
      state.database!.saveConfig(
        name: '其他源',
        origin: 'bridge://x',
        json: <String, Object?>{
          'sites': <Object?>[
            <String, Object?>{
              'key': _siteKey,
              'name': '猴哥',
              'type': 4,
              'api': 'http://127.0.0.1:19978/vod/api?key=Hxq',
              'searchable': 1,
              'quickSearch': 1,
            },
          ],
        },
        makeActive: false,
        sourceKey: _bridgeSource,
      );
      state.database!.upsertHistory(
        siteKey: _siteKey,
        vodId: _vodId,
        vodName: _vodName,
        flag: '线路一',
        episodeName: '第1集',
        episodeId: 'http://x/1',
        positionMs: 30000,
        durationMs: 100000,
        updatedAt: 1000,
        sourceKey: _bridgeSource,
      );
      // 记录挂在非生效源上，默认「只看当前源」的视图里看不见。
      await state.setHistoryScope(UiHistoryScope.global);
      calls.clear();
    });

    tearDown(() async {
      state.dispose();
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    });

    testWidgets('历史页会用非生效配置的站点发 ids=<vodId> 详情请求', (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: HistoryPage(state: state))),
      );
      await tester.pump();
      // 补图是 postFrameCallback 里 unawaited 起的；给足 pump + runAsync 窗口。
      for (var round = 0; round < 20; round++) {
        await tester.pump(const Duration(milliseconds: 16));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 16)),
        );
      }

      final detailCalls = calls
          .where((url) => url.queryParameters['ids'] == _vodId)
          .toList();
      expect(
        detailCalls,
        isNotEmpty,
        reason: '非生效配置里的 Hxq 站点必须被查详情（原缺陷在这里直接 continue），'
            '实际请求：$calls',
      );
    });
  });
}
