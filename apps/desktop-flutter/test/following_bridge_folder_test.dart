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
///
/// 另外钉住线路归属：目录展开后「展示名」唯一、「原始 flag」可能被多条分享链
/// 共用（同一网盘 provider），追第二条时不能按原始 flag 认成第一条。
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

  /// 目录展开（`t=`）返回的分享链条目。
  late List<Map<String, Object?>> entries;

  /// 每条分享链的详情（按 `ids=` 查）。
  late Map<String, Map<String, Object?>> shares;

  http.Response body(Object json) => http.Response(
    jsonEncode(json),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );

  String episodesOf(List<String> targets) => [
    for (var index = 0; index < targets.length; index++)
      'E${index + 1}\$${targets[index]}',
  ].join('#');

  Map<String, Object?> shareVod({
    required String vodId,
    required String vodName,
    required String flag,
    required List<String> targets,
  }) => {
    'vod_id': vodId,
    'vod_name': vodName,
    'vod_tag': 'file',
    'vod_play_from': flag,
    'vod_play_url': episodesOf(targets),
  };

  Map<String, Object?> normalVod() => {
    'vod_id': 'normal_123',
    'vod_name': '普通剧',
    'vod_play_from': '线路1',
    'vod_play_url': episodesOf([
      'http://media.example/1',
      'http://media.example/2',
    ]),
  };

  /// 单条分享链：provider 名 baidu、原始 flag 丫仙女、两集。
  void seedSingleShare() {
    entries = [
      {
        'vod_id': 'https://share.example/baidu',
        'vod_name': 'baidu',
        'vod_tag': 'file',
      },
    ];
    shares = {
      'https://share.example/baidu': shareVod(
        vodId: 'atvp_resume:baidu',
        vodName: '分享资源标题',
        flag: '丫仙女',
        targets: [
          'https://share.example/baidu/1',
          'https://share.example/baidu/2',
        ],
      ),
    };
  }

  setUp(() async {
    calls.clear();
    seedSingleShare();
    temp = Directory.systemTemp.createTempSync('webhtv-following-folder');
    final client = MockClient((request) async {
      calls.add(request.url);
      final query = request.url.queryParameters;
      if (query.containsKey('t')) return body({'list': entries});
      final ids = query['ids'] ?? '';
      if (ids.startsWith('atvp_detail:')) {
        // 真机网关对目录壳走 ids= 的回应：能解析成条目，但没有线路。
        return body({
          'list': [
            {'vod_id': ids, 'vod_name': '你也有今天'},
          ],
        });
      }
      final shared = shares[ids];
      if (shared != null) {
        return body({
          'list': [shared],
        });
      }
      return body({
        'list': [normalVod()],
      });
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
      // 与详情页按钮同一口径：flag = 展开后的展示名，sourceFlag = 原始 flag。
      flag: 'baidu',
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
    expect(outcome.following.latestEpisodeName, 'E2');
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
      flag: 'baidu',
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

  test('多条分享链共用同一原始 flag：检查要认展示名，不能拿第一条兜底', () async {
    entries = [
      {'vod_id': 'https://share.example/a', 'vod_name': 'A', 'vod_tag': 'file'},
      {'vod_id': 'https://share.example/b', 'vod_name': 'B', 'vod_tag': 'file'},
    ];
    // 两条分享链的 vod_play_from 都是 baidu（真机常见）：展示名 A / B 唯一，
    // 原始 flag 相同；追的是 B，集数必须取 B 的 5 集而不是 A 的 3 集。
    shares = {
      'https://share.example/a': shareVod(
        vodId: 'atvp_resume:a',
        vodName: 'A 的分享',
        flag: 'baidu',
        targets: [
          'https://share.example/a/1',
          'https://share.example/a/2',
          'https://share.example/a/3',
        ],
      ),
      'https://share.example/b': shareVod(
        vodId: 'atvp_resume:b',
        vodName: 'B 的分享',
        flag: 'baidu',
        targets: [
          'https://share.example/b/1',
          'https://share.example/b/2',
          'https://share.example/b/3',
          'https://share.example/b/4',
          'https://share.example/b/5',
        ],
      ),
    };
    final site = state.effectiveConfig!.sites.first;
    final item = state.followFromDetail(
      site: site,
      vod: Vod(vodId: 'atvp_detail:2132', vodName: '你也有今天'),
      flag: 'B',
      sourceFlag: 'baidu',
      releasedEpisode: 5,
    );
    expect(item, isNotNull);

    final outcome = await state.checkFollowing(item!);

    expect(outcome!.ok, isTrue, reason: '检查更新不得失败：${outcome.error}');
    expect(
      outcome.following.releasedEpisode,
      5,
      reason: '集数必须来自追的 B（5 集），不是同 flag 的 A（3 集）',
    );
    expect(outcome.following.latestEpisodeTarget, 'https://share.example/b/5');
    expect(outcome.following.latestEpisodeName, 'E5');
  });
}
