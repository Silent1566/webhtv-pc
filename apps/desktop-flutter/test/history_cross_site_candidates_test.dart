/// 「同一个配置里、另一个爬虫源的历史」查询门禁。
///
/// 详情页跨爬虫源标记/续播依赖这一条查询，它有三个不能松的口子：
/// 1. **只认当前播放源**（同一份配置）：跨配置的记录归历史页的「用原来源打开」，
///    混进详情页会让「历史只显示当前源」的默认偏好失效；
/// 2. **不含本站点自己那条**：本站记录的优先级与旗标由详情页既有路径独占，
///    这里再返回一份会让「上次看到这里」被算两次、弹框里出现重复选项；
/// 3. **TMDB 身份优先于同名**：同名不同剧（翻拍/短剧）只能靠身份区分，
///    身份命中的顺序必须排在按片名命中的前面——与安卓 `findPlaybackByTmdb` 一致。
///
/// 另外一条与偏好耦合：`ui.historyAggregation` 关成逐集时不按 TMDB 身份查
/// （安卓 `isHistoryAggregationEffective` 同），但仍按同名查。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/history_aggregation.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/storage.dart';
import 'package:webhtv_pc/state/app_state.dart';

import 'support/detail_test_seams.dart';

void main() {
  late Directory tempDir;
  late AppState state;
  late String sourceKey;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('webhtv-cross-site');
    state = AppState(
      paths: AppPaths.resolve(
        overrides: {
          'config': '${tempDir.path}/webhtv-pc',
          'data': '${tempDir.path}/webhtv-pc',
          'cache': '${tempDir.path}/webhtv-pc/cache',
          'state': '${tempDir.path}/webhtv-pc/logs',
        },
      ),
      log: MemoryOnlyLogService(),
      httpClient: MockClient((request) async =>
          http.Response(jsonEncode(<String, Object?>{'list': []}), 200)),
    );
    await bootstrapWithoutExternalMeta(state);
    final ok = await state.importConfig(
      jsonEncode(<String, Object?>{
        'sites': <Object?>[
          <String, Object?>{
            'key': 'site-a',
            'name': '甲站',
            'type': 3,
            'api': 'c1',
            'searchable': 1,
            'quickSearch': 1,
            'filter': 0,
          },
          <String, Object?>{
            'key': 'site-b',
            'name': '乙站',
            'type': 3,
            'api': 'c1',
            'searchable': 1,
            'quickSearch': 1,
            'filter': 0,
          },
        ],
      }),
      displayName: '测试源',
    );
    expect(ok, isTrue, reason: '前置：配置导入必须成功');
    sourceKey = state.activeSourceKey;
    expect(sourceKey, isNotEmpty, reason: '前置：必须能解析出播放源标识');
  });

  tearDown(() async {
    state.dispose();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  void seed({
    required String siteKey,
    required String vodId,
    required String vodName,
    String episodeName = '第1集',
    String? source,
    int updatedAt = 100,
    int tmdbId = 0,
    String mediaType = '',
    int positionMs = 600000,
    int durationMs = 2400000,
  }) {
    state.database!.upsertHistory(
      siteKey: siteKey,
      vodId: vodId,
      vodName: vodName,
      flag: '线路一',
      episodeName: episodeName,
      episodeId: 'https://$siteKey/$vodId/$episodeName',
      positionMs: positionMs,
      durationMs: durationMs,
      updatedAt: updatedAt,
      sourceKey: source ?? sourceKey,
      tmdbId: tmdbId,
      mediaType: mediaType,
    );
  }

  List<PlaybackHistory> query() => state.findHistoryCandidatesAcrossSites(
    siteKey: 'site-a',
    vodId: 'a-1',
    vodName: '庆余年',
  );

  test('只返回同源其它站点的记录：本站、别的源、别的作品都不进来', () {
    seed(siteKey: 'site-a', vodId: 'a-1', vodName: '庆余年', updatedAt: 100);
    seed(siteKey: 'site-b', vodId: 'b-1', vodName: '庆余年', updatedAt: 200);
    seed(siteKey: 'site-b', vodId: 'b-2', vodName: '别的剧', updatedAt: 300);
    seed(
      siteKey: 'site-b',
      vodId: 'b-3',
      vodName: '庆余年',
      updatedAt: 400,
      source: 'local|another-source',
    );

    final rows = query();
    expect(rows.map((row) => row.vodId).toList(), ['b-1']);
  });

  test('来源不明的老记录（source_key 为空）不得混进来', () {
    seed(siteKey: 'site-b', vodId: 'b-legacy', vodName: '庆余年', source: '');
    expect(query(), isEmpty);
  });

  test('同名多集按最近观看倒序', () {
    seed(siteKey: 'site-b', vodId: 'b-1', vodName: '庆余年', episodeName: '第1集', updatedAt: 100);
    seed(siteKey: 'site-b', vodId: 'b-1', vodName: '庆余年', episodeName: '第2集', updatedAt: 300);
    seed(siteKey: 'site-b', vodId: 'b-1', vodName: '庆余年', episodeName: '第3集', updatedAt: 200);

    final rows = query();
    expect(rows.map((row) => row.episodeName).toList(), ['第2集', '第3集', '第1集']);
  });

  test('TMDB 身份命中排在按片名命中的前面（即使片名不同、时间更早）', () {
    state.database!.upsertHistory(
      siteKey: 'site-b',
      vodId: 'b-tmdb',
      vodName: '庆余年 第一季',
      flag: '线路一',
      episodeName: '第5集',
      episodeId: 'https://site-b/b-tmdb/e5',
      positionMs: 600000,
      durationMs: 2400000,
      updatedAt: 50,
      sourceKey: sourceKey,
      tmdbId: 1234,
      mediaType: 'tv',
    );
    seed(siteKey: 'site-b', vodId: 'b-1', vodName: '庆余年', updatedAt: 200);

    final rows = state.findHistoryCandidatesAcrossSites(
      siteKey: 'site-a',
      vodId: 'a-1',
      vodName: '庆余年',
      tmdbId: 1234,
      mediaType: 'tv',
    );
    expect(rows.map((row) => row.siteKey).toSet(), {'site-b'});
    expect(rows.first.vodId, 'b-tmdb', reason: '身份命中必须排在同名命中之前');
    expect(rows.map((row) => row.vodId).toList(), ['b-tmdb', 'b-1']);
  });

  test('逐集模式（聚合关闭）下不按 TMDB 身份查，仍按同名查', () async {
    state.database!.upsertHistory(
      siteKey: 'site-b',
      vodId: 'b-tmdb',
      vodName: '庆余年 第一季',
      flag: '线路一',
      episodeName: '第5集',
      episodeId: 'https://site-b/b-tmdb/e5',
      positionMs: 600000,
      durationMs: 2400000,
      updatedAt: 50,
      sourceKey: sourceKey,
      tmdbId: 1234,
      mediaType: 'tv',
    );
    seed(siteKey: 'site-b', vodId: 'b-1', vodName: '庆余年', updatedAt: 200);
    expect(await state.setHistoryAggregation(UiHistoryAggregation.off), isTrue);
    expect(state.historyAggregation, UiHistoryAggregation.off);

    final rows = state.findHistoryCandidatesAcrossSites(
      siteKey: 'site-a',
      vodId: 'a-1',
      vodName: '庆余年',
      tmdbId: 1234,
      mediaType: 'tv',
    );
    expect(rows.map((row) => row.vodId).toList(), ['b-1']);
  });

  test('没有具体播放源时不查（宁可不标，不可猜源）', () {
    seed(siteKey: 'site-b', vodId: 'b-1', vodName: '庆余年', updatedAt: 200);
    expect(
      state.findHistoryCandidatesAcrossSites(
        siteKey: 'site-a',
        vodId: 'a-1',
        vodName: '庆余年',
        sourceKey: '',
      ),
      isEmpty,
    );
  });
}
