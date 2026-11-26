/// 详情页匹配到的 TMDB 身份必须回写到历史行：首页 hero 与历史页聚合读的都是
/// 历史行，只落在 `tmdb_matches` 的话「详情页有匹配、首页没有背景与简介」。
library;

import 'dart:async';
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
  Completer<http.Response>? pendingSearch;
  Completer<void>? searchStarted;

  setUp(() async {
    calls = <Uri>[];
    pendingSearch = null;
    searchStarted = null;
    tempDir = await Directory.systemTemp.createTemp('webhtv-history-identity');
    // 任何真实 HTTP 都记下来：本文件的断言核心是「零请求」。
    Future<http.Response> respond(http.Request request) async {
      calls.add(request.url);
      if (pendingSearch != null && request.url.path.contains('/search/')) {
        if (!(searchStarted?.isCompleted ?? true)) searchStarted!.complete();
        return pendingSearch!.future;
      }
      return http.Response(
        jsonEncode(<String, Object?>{'page': 1, 'results': <Object?>[]}),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }
    // 身份匹配走 TmdbService，不是 AppState 的站点客户端：两处都必须注入。
    final metadata = TmdbService(
      config: () => state.tmdbConfig,
      client: MockClient(respond),
    );
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
      httpClient: MockClient(respond),
      tmdbService: metadata,
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

  test('跨源同site/vod/title的历史只读自身配置匹配，不读取当前配置结论', () async {
    final currentSource = state.activeSourceKey;
    const foreignSource = 'local|https://fixture.example/foreign.json';
    final foreignId = state.database!.saveConfig(
      name: '另一来源', origin: 'https://fixture.example/foreign.json',
      json: {'sites': [{'key': siteKey, 'name': '外源影视', 'type': 3, 'api': 'c1'}]},
      sourceKey: foreignSource, makeActive: false,
    );
    state.database!.upsertHistory(
      siteKey: siteKey, vodId: vodId, vodName: vodName, flag: '原线路',
      episodeName: '第1集', episodeId: 'foreign-entry',
      positionMs: 60000, durationMs: 600000, updatedAt: 2000,
      sourceKey: foreignSource,
    );
    for (final entry in [(state.tmdbConfigId, matchedItem),
      (foreignId, const TmdbItem(tmdbId: 999, mediaType: TmdbMediaType.tv, title: vodName))]) {
      DatabaseTmdbMatchStore(database: state.database!, configId: entry.$1).putAuto(
        siteKey: siteKey, vodId: vodId, item: entry.$2, sourceTitle: vodName, matchedAt: 1,
      );
    }
    final before = state.database!.findHistory(siteKey: siteKey, vodId: vodId, sourceKey: foreignSource)!;
    final result = await state.historyTmdbItem(before);
    expect(result?.tmdbId, 999);
    expect(state.database!.findHistory(siteKey: siteKey, vodId: vodId, sourceKey: foreignSource)!.tmdbId, 999);
    expect(state.database!.findHistory(siteKey: siteKey, vodId: vodId, sourceKey: currentSource)!.tmdbId, 0);
    expect(state.activeSourceKey, currentSource);
    expect(calls, isEmpty);
  });

  test('已失效的首页请求不能回写缓存命中的身份', () async {
    final before = row(vodName);
    DatabaseTmdbMatchStore(database: state.database!, configId: state.tmdbConfigId).putAuto(
      siteKey: siteKey, vodId: vodId, item: matchedItem, sourceTitle: vodName, matchedAt: 1,
    );
    final result = await state.historyTmdbItem(before, isCurrent: () => false);
    expect(result, isNull);
    expect(row(vodName).tmdbId, 0);
    expect(row(vodName).positionMs, before.positionMs);
  });

  test('请求在飞时历史已换成新身份：旧结论不得回写历史或匹配表', () async {
    expect(await state.saveTmdbConfig(const TmdbConfig(apiKey: 'fixture')), isTrue);
    final before = row(vodName);
    pendingSearch = Completer<http.Response>();
    searchStarted = Completer<void>();
    final pending = state.historyTmdbItem(before, isCurrent: () => true);
    // 等第一条真实搜索发出，再把历史换成更强的结论（模拟详情页/另一轮匹配先落地）。
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(calls, isNotEmpty, reason: '前置：旧请求必须真的在飞');
    state.rememberHistoryIdentity(
      siteKey: siteKey, vodId: vodId,
      item: const TmdbItem(tmdbId: 999, mediaType: TmdbMediaType.tv, title: vodName),
      sourceKey: before.sourceKey,
    );
    pendingSearch!.complete(http.Response(
      jsonEncode({'results': [{'id': 341707, 'media_type': 'tv', 'name': vodName,
        'first_air_date': '2026-01-01', 'vote_average': 8.0}]}),
      200, headers: {'content-type': 'application/json; charset=utf-8'},
    ));
    expect(await pending, isNull);
    expect(row(vodName).tmdbId, 999);
    expect(row(vodName).positionMs, before.positionMs);
    expect(row(vodName).updatedAt, before.updatedAt);
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
