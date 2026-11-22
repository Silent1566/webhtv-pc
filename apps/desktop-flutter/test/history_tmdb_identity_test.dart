/// 详情页匹配到的 TMDB 身份必须回写到历史行：首页 hero 与历史页聚合读的都是
/// 历史行，只落在 `tmdb_matches` 的话「详情页有匹配、首页没有背景与简介」。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/tmdb_config.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/storage.dart';
import 'package:webhtv_pc/services/tmdb_enrichment_service.dart';
import 'package:webhtv_pc/services/tmdb_identity_service.dart';
import 'package:webhtv_pc/services/tmdb_season_service.dart';
import 'package:webhtv_pc/services/tmdb_service.dart';
import 'package:webhtv_pc/services/tmdb_stores.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/state/tmdb_state.dart';

const String siteKey = 'nodejs_guazi';
const String vodId = '159108/24';
const String vodName = '一马当先';
const TmdbItem matchedItem = TmdbItem(
  tmdbId: 341707,
  mediaType: TmdbMediaType.tv,
  title: vodName,
);

void main() {
  late Directory tempDir;
  late AppState state;
  late List<Uri> calls;

  setUp(() async {
    calls = <Uri>[];
    tempDir = await Directory.systemTemp.createTemp('webhtv-history-identity');
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
      // 任何真实 HTTP 都记下来：本文件的断言核心是「零请求」。
      httpClient: MockClient((request) async {
        calls.add(request.url);
        return http.Response(
          jsonEncode(<String, Object?>{'page': 1, 'results': <Object?>[]}),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    await state.bootstrap();
    final ok = await state.importConfig(
      jsonEncode(<String, Object?>{
        'sites': <Object?>[
          <String, Object?>{
            'key': siteKey,
            'name': '瓜子',
            'type': 3,
            'api': 'c1',
            'searchable': 1,
            'quickSearch': 1,
            'filter': 0,
          },
        ],
      }),
      displayName: '瓜子源',
    );
    expect(ok, isTrue, reason: '前置：配置导入必须成功');
    state.database!.upsertHistory(
      siteKey: siteKey,
      vodId: vodId,
      vodName: vodName,
      flag: '瓜子专线',
      episodeName: '第1集',
      episodeId: 'https://cdn/e1.m3u8',
      positionMs: 250806,
      durationMs: 722760,
      updatedAt: 1000,
      sourceKey: state.activeSourceKey,
    );
  });

  tearDown(() async {
    state.dispose();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  PlaybackHistory row(String name) =>
      state.recentHistory(sourceKey: '').firstWhere((r) => r.vodName == name);

  test('详情页匹配过的作品：首页读到身份零请求，并把身份回写历史行', () async {
    final before = row(vodName);
    expect(before.tmdbId, 0, reason: '前置：历史行确实没有身份');
    DatabaseTmdbMatchStore(
      database: state.database!,
      configId: state.tmdbConfigId,
    ).putAuto(
      siteKey: siteKey,
      vodId: vodId,
      item: matchedItem,
      sourceTitle: vodName,
      matchedAt: 1,
    );

    final item = await state.historyTmdbItem(before);

    expect(item?.tmdbId, 341707);
    expect(item?.mediaType, TmdbMediaType.tv);
    expect(calls, isEmpty, reason: '已落盘的匹配结论不得再打网络（也不触发分季探测）');
    final after = row(vodName);
    expect(after.tmdbId, 341707, reason: '身份必须回写到历史行，下次读历史就有时它');
    expect(after.mediaType, 'tv');
  });

  test('回写只改身份两列：同一部作品的多行一起更新，进度与时间不动', () async {
    state.database!.upsertHistory(
      siteKey: siteKey,
      vodId: vodId,
      vodName: vodName,
      flag: '备用线路',
      episodeName: '第2集',
      episodeId: 'https://cdn/e2.m3u8',
      positionMs: 60000,
      durationMs: 722760,
      updatedAt: 900,
      sourceKey: state.activeSourceKey,
    );

    state.rememberHistoryIdentity(
      siteKey: siteKey,
      vodId: vodId,
      item: matchedItem,
      sourceKey: state.activeSourceKey,
    );

    final rows = state
        .recentHistory(sourceKey: '')
        .where((r) => r.vodName == vodName)
        .toList();
    expect(rows.length, 2);
    expect(rows.every((r) => r.tmdbId == 341707), isTrue, reason: '身份是作品级的');
    expect(rows.every((r) => r.mediaType == 'tv'), isTrue);
    expect(
      {for (final r in rows) r.flag: r.positionMs},
      {'瓜子专线': 250806, '备用线路': 60000},
      reason: '回写不得碰进度',
    );
    expect(
      {for (final r in rows) r.flag: r.updatedAt},
      {'瓜子专线': 1000, '备用线路': 900},
      reason: '回写不得改更新时间（否则历史顺序会跳）',
    );
  });

  test('没有匹配结论且 TMDB 不可用：返回空、不回写、零请求', () async {
    final before = row(vodName);
    expect(await state.historyTmdbItem(before), isNull);
    expect(calls, isEmpty);
    expect(row(vodName).tmdbId, 0, reason: '匹配不到就不能给历史行编一个身份');
  });

  test('详情页匹配命中时回调数据层（TmdbState.onMatched）', () async {
    final config = const TmdbConfig(apiKey: 'k');
    final service = TmdbService(
      config: () => config,
      client: MockClient(
        (request) async => http.Response(
          jsonEncode(<String, Object?>{'status_code': 404}),
          404,
        ),
      ),
    );
    addTearDown(service.close);
    final store = InMemoryTmdbMatchStore();
    store.putAuto(
      siteKey: siteKey,
      vodId: vodId,
      item: matchedItem,
      sourceTitle: vodName,
      matchedAt: 1,
    );
    final seen = <String>[];
    final tmdb = TmdbState(
      config: () => config,
      service: service,
      identityService: TmdbIdentityService(
        config: () => config,
        service: service,
        store: store,
      ),
      seasonService: TmdbSeasonService(store: InMemoryTmdbSeasonStore()),
      enrichmentService: TmdbEnrichmentService(
        service: service,
        config: () => config,
      ),
      onMatched: (key, id, item) => seen.add('$key|$id|${item.tmdbId}'),
    );
    addTearDown(tmdb.dispose);
    tmdb.beginLoad(
      siteKey: siteKey,
      vodId: vodId,
      sourceTitle: vodName,
      vod: Vod(vodId: vodId, vodName: vodName),
    );

    await tmdb.loadMatch(generation: tmdb.generation, sourceTitle: vodName);

    expect(seen, ['$siteKey|$vodId|341707']);
  });
}
