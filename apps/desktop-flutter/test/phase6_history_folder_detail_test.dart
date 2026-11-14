/// 历史记录 → 详情：网盘聚合站的 `atvp_detail:` 条目必须按 folder 展开。
///
/// 真实缺陷（2026-10-20 用户反馈，正式版日志）：
/// `[site] 详情加载失败 site=02544b… vod=atvp_detail:2132
///  siteBusiness: 站源请求失败，请检查站源或查看应用日志`
///
/// 打开详情页的 `Vod` 由历史记录重建（只有 `vod_id`），而 `atvp_detail:` 前缀
/// 表示这是 `vod_tag: folder` 壳：分类接口 `t=<vod_id>` 才能展开成分享链，
/// 拿它去 `ids=` 详情接口只会被站源拒绝。分类列表点进去带 `vod_tag`，所以
/// 浏览正常、历史必错——本文件钉住这条差异。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/browse_pages.dart';
import 'package:webhtv_pc/ui/library_pages.dart';

void main() {
  late Directory temp;
  late AppState state;
  final calls = <Uri>[];

  http.Response body(Object json) => http.Response(
    jsonEncode(json),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );

  /// 真机网关对 `ids=atvp_detail:…` 的回应：业务错误，不是空壳。
  http.Response businessError() => body({
    'code': -1,
    'msg': '站源请求失败，请检查站源或查看应用日志',
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

  /// 分享链的详情：普通影片，两条线路图标在这里合成。
  http.Response shareDetail() => body({
    'list': [
      {
        'vod_id': 'atvp_resume:baidu',
        'vod_name': '分享资源标题',
        'vod_tag': 'file',
        'vod_play_from': '丫仙女',
        'vod_play_url': r'baidu01$$baidu@1#baidu02$$baidu@2',
      },
    ],
  });

  setUp(() async {
    calls.clear();
    temp = Directory.systemTemp.createTempSync('webhtv-history-folder');
    final client = MockClient((request) async {
      calls.add(request.url);
      final query = request.url.queryParameters;
      if (query.containsKey('t')) return folderEntries();
      if (query.containsKey('ids')) {
        final ids = query['ids'] ?? '';
        // 只有分享链详情能成功；`atvp_detail:` 壳一律按真机行为报业务错误。
        return ids.startsWith('atvp_detail:') ? businessError() : shareDetail();
      }
      return body({'list': []});
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
      log: LogService(),
      httpClient: client,
    );
    await state.bootstrap();
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

  void seedHistory({required String vodId}) {
    state.database!.upsertHistory(
      siteKey: 'bridge',
      vodId: vodId,
      vodName: '你也有今天',
      flag: '丫仙女',
      episodeName: '第1集',
      episodeId: 'baidu@1',
      positionMs: 30000,
      durationMs: 100000,
      // 同 phase6_history_page_test：种子必须归属到当前生效源，
      // 否则空来源记录在按源隔离的视图里不可见。
      sourceKey: state.activeSourceKey,
    );
  }

  Future<void> pumpHistory(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: HistoryPage(state: state))),
    );
    await tester.pump();
  }

  testWidgets('点历史里的 atvp_detail 条目按 folder 展开（t=），不走 ids=', (tester) async {
    seedHistory(vodId: 'atvp_detail:2132');
    await pumpHistory(tester);

    await tester.tap(find.byKey(const ValueKey('history-row-1')));
    await tester.pumpAndSettle();

    expect(find.byType(DetailPage), findsOneWidget, reason: '必须先打开详情页');

    final folderCalls = calls
        .where((url) => url.queryParameters['t'] == 'atvp_detail:2132')
        .toList();
    final shellAsDetail = calls
        .where((url) => url.queryParameters['ids'] == 'atvp_detail:2132')
        .toList();
    expect(
      folderCalls,
      isNotEmpty,
      reason: 'atvp_detail: 壳必须用 t=<vod_id> 展开（分类接口），实际请求：$calls',
    );
    expect(
      shellAsDetail,
      isEmpty,
      reason: '拿 folder 壳去 ids= 详情接口会被站源拒绝（真机返回业务错误）',
    );
    expect(state.detailPhase, LoadPhase.ready);
    expect(state.detailError, isNull, reason: '详情不得报错');
    expect(
      state.playLinesOf(state.selectedVod!).length,
      1,
      reason: '展开后的分享链必须合并成可播放线路',
    );
  });

  testWidgets('非 folder 的历史条目仍走 ids= 详情（不因修复而改道）', (tester) async {
    seedHistory(vodId: 'normal_123');
    await pumpHistory(tester);

    await tester.tap(find.byKey(const ValueKey('history-row-1')));
    await tester.pumpAndSettle();

    expect(find.byType(DetailPage), findsOneWidget);
    expect(
      calls.where((url) => url.queryParameters['ids'] == 'normal_123'),
      isNotEmpty,
      reason: '普通条目必须继续走 ids= 详情接口，实际请求：$calls',
    );
    expect(
      calls.where((url) => url.queryParameters['t'] == 'normal_123'),
      isEmpty,
      reason: '普通条目不得凭空走 folder 展开',
    );
  });

  // 纯 `test`（不是 `testWidgets`）：这条只验日志内容，走真实异步即可；
  // 放进假时钟区会因为真实 I/O 挂死。
  test('详情失败时日志写明请求上下文与堆栈（不再只有一行分类文案）', () async {
    // 站源对任何请求都返回业务错误，等价于用户遇到的 siteBusiness 失败。
    state.dispose();
    final failing = MockClient((request) async => businessError());
    state = AppState(
      paths: AppPaths.resolve(
        overrides: {
          'config': '${temp.path}/webhtv-pc',
          'data': '${temp.path}/webhtv-pc',
          'cache': '${temp.path}/webhtv-pc/cache',
          'state': '${temp.path}/webhtv-pc/logs',
        },
      ),
      log: LogService(),
      httpClient: failing,
    );
    await state.bootstrap();
    await state.importConfig(
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
    await state.selectSite(state.config!.sites.first);

    // 两条路径各失败一次：普通条目走 `ids=` 详情（action=detail），
    // folder 条目走 `t=` 展开（action=category）。两者文案相同，日志必须能分开。
    await state.loadDetail(Vod(vodId: 'normal_123', vodName: '普通条目'));
    await state.loadDetail(
      Vod(vodId: 'atvp_detail:2132', vodName: '你也有今天'),
    );

    final log = state.log.export();
    expect(log, contains('详情加载失败'), reason: '既有失败日志必须保留');
    expect(
      log,
      contains('站源请求失败'),
      reason: '上游 msg 必须落进日志（不能只剩分类文案）',
    );
    expect(
      log,
      contains('atvp_detail:2132'),
      reason: '必须写明失败的是哪一次请求',
    );
    expect(
      log,
      contains('action=detail'),
      reason: '必须写明请求动作：详情与分类走同一套错误，不写就分不清',
    );
    expect(
      log,
      contains('action=category'),
      reason: 'folder 展开走分类接口，同样要写清动作',
    );
    expect(
      log,
      contains('#0'),
      reason: '必须带堆栈：目前 AppError 丢弃 stackTrace，用户无法定位',
    );
  });
}
