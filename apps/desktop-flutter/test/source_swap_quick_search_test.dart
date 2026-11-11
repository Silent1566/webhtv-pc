/// 换源搜索的 `quick=true` 门禁（对齐安卓换源语义）。
///
/// 安卓换源入口 `TmdbDetailActivity.java` 的 `startInlineSourceSearch` 调的是
/// `searchContent(sites, keyword, true)`：范围仍是**全部**站点，真正的限流手段是
/// 第三参 `quick`。PC 端对应 `AppState.searchAll(quick:)` →
/// `SpiderRouter.search` 的 `effectiveQuick = quick && site.quickSearch` →
/// `HttpApiClient` 在搜索参数里加 `quick=true`。
///
/// 这里断言的是**发出去的 HTTP 请求**，不是传下去的参数：只看字段值无法证明
/// 站点真的收到了 `quick`。站点必须**声明** `quickSearch: 1`，否则上游语义是
/// 「该站点不支持快速搜索」，`quick` 会被 `effectiveQuick` 吞掉。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';

void main() {
  late Directory tempDir;
  late AppState state;
  late _QuickCaptureClient client;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('webhtv-quick-search');
    client = _QuickCaptureClient();
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
      httpClient: client,
    );
    await state.bootstrap();
  });

  tearDown(() async {
    state.dispose();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  Future<void> importSites({required int quickSearch}) async {
    final ok = await state.importConfig(
      jsonEncode({
        'name': '快速搜索测试',
        'sites': [
          {
            'key': 'q-1',
            'name': '快搜站',
            'type': 1,
            'api': 'http://127.0.0.1:1/api/type1/',
            'searchable': 1,
            'quickSearch': quickSearch,
          },
        ],
      }),
    );
    expect(ok, isTrue, reason: '配置导入应成功');
  }

  /// 搜索请求真正落到网络上的 `quick` 参数（没有该参数时为 null）。
  List<String?> quickParameters() => [
    for (final query in client.searchQueries) query['quick'],
  ];

  test('换源搜索（quick: true）真的把 quick=true 发给了声明 quickSearch 的站点', () async {
    await importSites(quickSearch: 1);

    final outcome = await state.searchAll('换源关键词', quick: true);

    expect(outcome.succeededCount, 1, reason: '站点应搜索成功');
    expect(client.searchQueries, hasLength(1));
    expect(
      quickParameters(),
      <String?>['true'],
      reason: 'quick 必须在 URL 参数里真的发出去，不能只停在 AppState 参数上',
    );
  });

  test('不传 quick（大搜索）时不带 quick 参数', () async {
    await importSites(quickSearch: 1);

    await state.searchAll('大搜索关键词');

    expect(client.searchQueries, hasLength(1));
    expect(
      quickParameters(),
      <String?>[null],
      reason: '默认 quick=false：大搜索保持全量，不能被换源入口的语义污染',
    );
  });

  test('站点没声明 quickSearch 时即使 quick: true 也不发 quick', () async {
    await importSites(quickSearch: 0);

    await state.searchAll('未声明关键词', quick: true);

    expect(client.searchQueries, hasLength(1));
    expect(
      quickParameters(),
      <String?>[null],
      reason: 'upstream 语义：quick 只对声明了 quickSearch 的站点生效',
    );
  });
}

/// 假站点客户端：只记录搜索请求的 query 参数，不碰真实 socket。
class _QuickCaptureClient extends http.BaseClient {
  /// 每一个搜索请求（带 `wd`）的 query 参数。
  final List<Map<String, String>> searchQueries = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final query = request.url.queryParameters;
    if (query['wd'] != null) searchQueries.add(query);
    final payload = {'page': 1, 'pagecount': 1, 'limit': 20, 'total': 0, 'list': <Object>[]};
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(jsonEncode(payload))),
      200,
    );
  }
}
