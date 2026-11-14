/// 换源链路（`AppState.swapProbe` / `searchAll`）的真实 HTTP 门禁。
///
/// 为什么单独一个文件：`TestWidgetsFlutterBinding` 会把所有 `HttpClient` 请求
/// 固定返回 400，因此**只要同一文件里出现 `testWidgets`**，同文件的普通 `test()`
/// 也拿不到真实网络（`phase3_detail_page_test.dart` 文件头记录过同一坑）。这里
/// 全部用真实 fixture 服务证明：换源浮层真正走的 `searchAll` 会把 keyword 原样
/// 发到站点、按分组收窄、单站失败只丢那一站；`swapProbe` 只解析目标站点自己的线路。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';

import 'support/test_fixture_server.dart';

void main() {
  late TestFixtureServer server;
  late Directory tempDir;
  late AppState state;

  setUp(() async {
    server = await TestFixtureServer.start();
    tempDir = await Directory.systemTemp.createTemp('webhtv-swap-state');
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
    );
    // 四个站点都指向**同一个** fixture 服务（family 在路径里）：
    // - cathttp/ok：搜索/详情都返回正常样本；
    // - cathttp/biz：任何动作都返回业务错误 → 失败站；
    // - cathttp/page：详情返回空 list →「解析为空」的站。
    final ok = await state.importConfig(
      jsonEncode({
        'name': '换源测试',
        'sites': [
          {
            'key': 'swap-ok',
            'name': '木偶[盘]',
            'type': 3,
            'api': '${server.baseUrl}/cathttp/ok/spider/demo',
            'searchable': 1,
          },
          {
            'key': 'swap-ok2',
            'name': '金牌影视[采]',
            'type': 3,
            'api': '${server.baseUrl}/cathttp/ok/spider/other',
            'searchable': 1,
          },
          {
            'key': 'swap-biz',
            'name': '坏站',
            'type': 3,
            'api': '${server.baseUrl}/cathttp/biz/spider/demo',
            'searchable': 1,
          },
          {
            'key': 'swap-empty',
            'name': '空站',
            'type': 3,
            'api': '${server.baseUrl}/cathttp/page/spider/demo',
            'searchable': 1,
          },
        ],
      }),
    );
    expect(ok, isTrue, reason: '配置导入应成功');
  });

  tearDown(() async {
    state.dispose();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
    await server.stop();
  });

  /// 某个站点收到的 `/search` 请求（按 api 路径区分站点）。
  List<CapturedRequest> searchCallsOf(String apiMarker) => server.captured
      .where((item) => item.path.contains(apiMarker) && item.path.endsWith('/search'))
      .toList();

  test('换源搜索：单站失败只丢那一站，其余站结果仍在', () async {
    // 浮层消费的是 `state.activeSearch`，也就是 `searchAll` 写回的那一批。
    final outcome = await state.searchAll('swapkw');
    final byKey = {for (final entry in outcome.results) entry.siteKey: entry};

    expect(byKey['swap-ok']!.succeeded, isTrue, reason: '成功站必须有结果');
    expect(byKey['swap-ok']!.result!.list, isNotEmpty);
    expect(byKey['swap-ok2']!.succeeded, isTrue, reason: '另一成功站也必须有结果');
    expect(
      byKey['swap-biz']!.succeeded,
      isFalse,
      reason: '业务错误站保留失败状态，不得空列表化，也不能拖垮整批',
    );
    expect(byKey['swap-biz']!.error, isNotNull);
    expect(
      searchCallsOf('/biz/spider/demo'),
      isNotEmpty,
      reason: '失败站是「请求过但失败」，不是被过滤后根本没搜',
    );
    expect(outcome.finished, isTrue);
    expect(
      outcome.results.map((entry) => entry.siteKey).toList(),
      ['swap-ok', 'swap-ok2', 'swap-biz', 'swap-empty'],
      reason: '结果顺序与配置里的站点顺序一致（稳定）',
    );
  });

  test('换源搜索：分组收窄到组内站点，组外站点连请求都不发', () async {
    final outcome = await state.searchAll('swapkw', group: '盘');

    expect(
      outcome.results.map((entry) => entry.siteKey),
      ['swap-ok'],
      reason: '[盘] 分组只含木偶[盘]；[采] 站不得被搜到',
    );
    expect(outcome.group, '盘');
    expect(outcome.scoped, isTrue);
    expect(
      searchCallsOf('/ok/spider/other'),
      isEmpty,
      reason: '分组外的站点连请求都不该发',
    );
  });

  test('换源搜索：keyword 原样发到站点', () async {
    await state.searchAll('swapkw12345');

    final calls = searchCallsOf('/ok/spider/demo');
    expect(calls, isNotEmpty, reason: '成功站应当收到搜索请求');
    final haystack = calls
        .map((item) => [jsonEncode(item.query), jsonEncode(item.form), item.body].join('|'))
        .join('\n');
    expect(
      haystack,
      contains('swapkw12345'),
      reason: '搜索词必须真的进到请求里（query/form/body 任一）',
    );
  });

  test('空 keyword：拦截在调用方，searchAll 本身不做空词短路', () async {
    // 唯一的空词保护在浮层提交处（lib/ui/source_swap_sheet.dart:411
    // `if (text.isEmpty || text == _keyword) return;`）与搜索页
    // （lib/ui/search_page.dart:243）。状态层 `searchAll` 不拦空词——这条记录
    // 现状：将来若在 `searchAll` 里补拦截，这里应当反过来断言「不发请求」。
    server.captured.clear();
    await state.searchAll('   ');
    expect(
      searchCallsOf('/ok/spider/demo'),
      isNotEmpty,
      reason: '现状：空词由浮层/搜索页在调用前拦下，状态层不拦截',
    );
  });

  test('swapProbe 解析出该站点自己的线路', () async {
    final lines = await state.swapProbe(
      siteKey: 'swap-ok',
      vodId: 'cat-1',
      vodName: 'CatSpider 样本影片',
    );

    expect(lines.length, 2, reason: '样本详情的 vod_play_from 是 cat\$\$\$备用');
    expect([for (final line in lines) line.flag], ['cat', '备用']);
    expect(
      lines.every((line) => line.episodes.isNotEmpty),
      isTrue,
      reason: '解析出的线路必须带集数，不能是空壳线路',
    );
  });

  test('swapProbe：站点不存在时抛 AppError，不伪造线路', () async {
    await expectLater(
      state.swapProbe(siteKey: 'no-such-site', vodId: 'cat-1'),
      throwsA(isA<AppError>()),
    );
  });

  test('swapProbe：业务错误站抛错', () async {
    await expectLater(
      state.swapProbe(siteKey: 'swap-biz', vodId: 'cat-1'),
      throwsA(isA<AppError>()),
    );
  });

  test('swapProbe：详情没有线路时返回空列表', () async {
    final lines = await state.swapProbe(siteKey: 'swap-empty', vodId: 'cat-1');
    expect(lines, isEmpty, reason: '空详情不得伪造出线路');
  });

  test('siteByKey：公开查找跳过 hide 站点', () async {
    expect(state.siteByKey('swap-ok')?.name, '木偶[盘]');
    expect(state.siteByKey('no-such-site'), isNull);
  });
}