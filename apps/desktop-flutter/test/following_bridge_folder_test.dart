/// 追剧取数 → 网盘聚合目录条目（`atvp_detail:`）必须按 folder 展开。
///
/// 真实缺陷（2026-11-22 用户反馈，Windows 真机日志）：
/// 从一个「详情页能播（5 条线路）」的爬虫源详情点「追剧」，检查更新时报
/// `Bad state: 详情里没有可用线路`。
///
/// 成因与历史记录那条同源（见 `phase6_history_folder_detail_test.dart`）：
/// 网盘聚合的分类只返回 `vod_tag: folder` 壳，详情页靠 `t=<vod_id>` 展开成
/// 分享链再合并线路，而追剧存下来的 `vod_id` 就是这个壳；检查更新拿它去
/// `ids=` 详情接口只会得到没有 `vod_play_url` 的空壳，于是「明明有线路」也
/// 被判成没线路。
///
/// 两条取数路径共用同一入口（`AppState.followingVod`），所以一起钉住：
/// 检查更新（线路/集数）与家页/追剧卡片的站源元数据都必须走 `t=`。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/state/app_state.dart';

import 'support/detail_test_seams.dart';

void main() {
  late Directory temp;
  late AppState state;
  final calls = <Uri>[];

  http.Response body(Object json) => http.Response(
    jsonEncode(json),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );

  /// 真机网关对 `ids=atvp_detail:…` 的回应：能解析成条目，但没有线路。
  http.Response folderShell() => body({
    'list': [
      {'vod_id': 'atvp_detail:2132', 'vod_name': '你也有今天'},
    ],
  });

  /// `t=<folder>` 展开出的分享链条目。
  http.Response folderEntries() => body({
    'list': [
      {
        'vod_id': 'https://share.example/baidu',
        'vod_name': 'baidu',
        'vod_tag': 'file',
      },
    ],
  });

  /// 分享链详情：两条分集的普通影片。
  http.Response shareDetail() => body({
    'list': [
      {
        'vod_id': 'atvp_resume:baidu',
        'vod_name': '分享资源标题',
        'vod_tag': 'file',
        'vod_play_from': '丫仙女',
        'vod_play_url':
            '第1集\$https://share.example/baidu/1'
            '#第2集\$https://share.example/baidu/2',
      },
    ],
  });

  /// 普通（非目录）条目的详情：一条线路两集。
  http.Response normalDetail() => body({
    'list': [
      {
        'vod_id': 'normal_123',
        'vod_name': '普通剧',
        'vod_play_from': '线路1',
        'vod_play_url':
            '第1集\$http://media.example/1#第2集\$http://media.example/2',
      },
    ],
  });

  setUp(() async {
    calls.clear();
    temp = Directory.systemTemp.createTempSync('webhtv-following-folder');
    final client = MockClient((request) async {
      calls.add(request.url);
      final query = request.url.queryParameters;
      if (query.containsKey('t')) return folderEntries();
      final ids = query['ids'] ?? '';
      if (ids.startsWith('atvp_detail:')) return folderShell();
      if (ids.startsWith('https://share.example')) return shareDetail();
      return normalDetail();
    });
    state = AppState(
      paths: AppPaths.resolve(
        overrides: {
          'config': '${temp.path}/webhtv-pc',
          'data': '${temp.path}/webhtv-pc',
          'cache': '${temp.path}/webhtv-pc/cache',
          'state': '${temp.path}/webhtv-pc/logs',
        },
      ),
      log: MemoryOnlyLogService(),
      httpClient: client,
    );
    await bootstrapWithoutExternalMeta(state);
    final ok = await state.importConfig(
      jsonEncode({
        'sites': [
          {
            'key': 'bridge',
            'name': '网盘聚合站',
            'type': 4,
            'api': 'http://127.0.0.1:19978/vod/api?key=bridge',
          },
        ],
      }),
    );
    expect(ok, isTrue, reason: '前置：配置导入必须成功');
    calls.clear();
  });

  tearDown(() async {
    state.dispose();
    try {
      await temp.delete(recursive: true);
    } catch (_) {}
  });

  test('从详情页追的目录条目：检查更新按 t= 展开，不再误报没线路', () async {
    final site = state.effectiveConfig!.sites.first;
    final item = state.followFromDetail(
      site: site,
      vod: Vod(vodId: 'atvp_detail:2132', vodName: '你也有今天'),
      flag: '丫仙女',
      sourceFlag: '丫仙女',
      releasedEpisode: 2,
    );
    expect(item, isNotNull, reason: '前置：追剧必须写入成功');
    calls.clear();

    final outcome = await state.checkFollowing(item!);

    expect(outcome!.ok, isTrue, reason: '检查更新不得失败：${outcome.error}');
    expect(outcome.following.releasedEpisode, 2, reason: '已发布集数必须来自展开后的线路');
    expect(
      outcome.following.latestEpisodeTarget,
      'https://share.example/baidu/2',
      reason: '「播放最新集」的入口必须落在展开后的分集上，而不是目录壳',
    );
    expect(outcome.following.latestEpisodeName, '第2集');
    expect(
      calls.where((url) => url.queryParameters['t'] == 'atvp_detail:2132'),
      isNotEmpty,
      reason: '目录条目必须用 t=<vod_id> 展开（分类接口），实际请求：$calls',
    );
    expect(
      calls.where((url) => url.queryParameters['ids'] == 'atvp_detail:2132'),
      isEmpty,
      reason: '拿目录壳去 ids= 详情只能拿到没有线路的空壳',
    );
  });

  test('非目录条目仍走 ids= 详情（不因修复而改道）', () async {
    final site = state.effectiveConfig!.sites.first;
    final item = state.followFromDetail(
      site: site,
      vod: Vod(vodId: 'normal_123', vodName: '普通剧'),
      flag: '线路1',
      releasedEpisode: 2,
    );
    expect(item, isNotNull);
    calls.clear();

    final outcome = await state.checkFollowing(item!);

    expect(outcome!.ok, isTrue, reason: '检查更新不得失败：${outcome.error}');
    expect(outcome.following.releasedEpisode, 2);
    expect(
      calls.where((url) => url.queryParameters['ids'] == 'normal_123'),
      isNotEmpty,
      reason: '普通条目必须继续走 ids= 详情，实际请求：$calls',
    );
    expect(
      calls.where((url) => url.queryParameters['t'] == 'normal_123'),
      isEmpty,
      reason: '普通条目不得凭空走 folder 展开',
    );
  });

  test('家页/追剧卡片的站源元数据同样按 t= 展开目录条目', () async {
    final site = state.effectiveConfig!.sites.first;
    final item = state.followFromDetail(
      site: site,
      vod: Vod(vodId: 'atvp_detail:2132', vodName: '你也有今天'),
      flag: '丫仙女',
      sourceFlag: '丫仙女',
      releasedEpisode: 2,
    );
    expect(item, isNotNull);
    calls.clear();

    final vod = await state.followingVod(item!);

    expect(vod, isNotNull);
    expect(state.playLinesOf(vod!).map((line) => line.episodes.length), [
      2,
    ], reason: '站源元数据要能读到展开后的线路，而不是目录壳');
    expect(
      calls.where((url) => url.queryParameters['t'] == 'atvp_detail:2132'),
      isNotEmpty,
      reason: '目录条目必须用 t=<vod_id> 展开，实际请求：$calls',
    );
    expect(
      calls.where((url) => url.queryParameters['ids'] == 'atvp_detail:2132'),
      isEmpty,
      reason: '拿目录壳去 ids= 详情只能拿到没有线路的空壳',
    );
  });
}
