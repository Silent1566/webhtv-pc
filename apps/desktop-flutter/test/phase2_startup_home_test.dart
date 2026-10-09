/// 启动加载首页的门禁（§17.1.3，用户反馈 2026-10-09「刚启动时没有默认加载数据」）。
///
/// 缺陷背景：`AppState.bootstrap()` 只恢复配置与选中站点（`config.defaultSite()`），
/// **从不发首页请求**；而浏览页在无 `homeResult` 时只渲染空态。壳层里的自动接入
/// 逻辑原本在每个「不适用」分支直接 `return`，于是冷启动必然停在空页，要用户手动
/// 点分类或刷新才有数据。
///
/// 修法：壳层首帧后统一回落 `_loadInitialHome()`（幂等）。本文件用**真实
/// `AppShell` + 真实 `AppState` + 捕获客户端**锁定两条不变量：
///
/// 1. **冷启动必须自动加载首页**：`bootstrap()` 后 `homeResult` 为 null（这是缺陷的
///    前置条件，用例先断言它，防止将来 bootstrap 自己开始拉首页而让用例失去判别力），
///    挂载 `AppShell` 后必须发出首页请求并拿到内容；
/// 2. **幂等**：已有 `homeResult` 时不得重复发请求。
///
/// 为什么必须用真实壳层：缺陷就发生在「壳层初始化 → 自动接入分支」这一段，直接构造
/// `BrowsePage` 会绕过它（既有的 `phase5_category_filter_test` 直接驱动 `AppState`，
/// 覆盖不到本缺陷）。
///
/// 装配注意（踩过三次，务必保留）：
/// - **一切真实 I/O（`createTemp`、`bootstrap`、`importConfig`）都放在 `setUp` 里**。
///   `testWidgets` 用的是 fake-async binding，直接在测试体里 `await` 真实文件/DB I/O
///   会**永久挂起**（现象：`Test timed out`，且连 `print` 都不输出）；`setUp` 在
///   fake-async 区之外，`await` 正常完成。这与 `integration_test`（真实 async
///   binding）不同，不能照搬那边的写法。
/// - 收敛循环**不能用 `pumpAndSettle`**：加载态含 `CircularProgressIndicator` 这类
///   无限动画，`pumpAndSettle` 会一直等它停，直接撞 10 分钟默认超时。改用有界轮次。
/// - 捕获客户端是纯内存实现（无真实 socket），其 `Future` 由微任务完成，
///   `tester.pump` 能推进，因此**可以**留在测试体里。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/app.dart';

/// 捕获请求并返回固定首页响应的假 HTTP 客户端（widget 测试不可做真实 socket I/O）。
class _CapturingClient extends http.BaseClient {
  final List<Uri> requests = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request.url);
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(jsonEncode(_homePayload()))),
      200,
    );
  }
}

/// 首页响应：带 `class` 与推荐 `list`（有内容 → 不会触发「自动进第一个分类」）。
Map<String, Object?> _homePayload() => {
  'class': [
    {'type_id': '1', 'type_name': '电影'},
  ],
  'list': [
    {'vod_id': 'v1', 'vod_name': '冷启动影片', 'vod_pic': ''},
  ],
};

const String _configJson = '''
{
  "name": "启动加载测试配置",
  "sites": [
    {
      "key": "startup_site",
      "name": "启动站点",
      "type": 4,
      "api": "http://127.0.0.1:19978/vod/api?key=startup_site",
      "searchable": 1
    }
  ]
}
''';

/// 交替「推进一帧 → 给真实 I/O 一点时间」，有界收敛（不用 `pumpAndSettle`）。
Future<void> _settle(WidgetTester tester, {int rounds = 20}) async {
  for (var round = 0; round < rounds; round++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 8)),
    );
  }
  await tester.pump(const Duration(milliseconds: 16));
}

Future<void> _mountShell(WidgetTester tester, AppState state) async {
  tester.view.physicalSize = const Size(1280, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(home: AppShell(state: state, startup: const StartupArguments())),
  );
  await _settle(tester);
}

void main() {
  late Directory temp;
  late AppPaths paths;

  /// 冷启动实例：`bootstrap` 只恢复配置与站点，**不拉首页**。
  late AppState coldState;
  late _CapturingClient coldClient;

  /// 已有首页结果的实例（导入时已拉过一次）。
  late AppState warmState;
  late _CapturingClient warmClient;

  setUp(() async {
    // `setUp` 不在 fake-async 区内，这里的真实 I/O 可以正常 await 完成。
    temp = await Directory.systemTemp.createTemp('webhtv-startup-home');
    paths = AppPaths.resolve(
      overrides: {'roaming': temp.path, 'local': temp.path},
    );

    // 1) 先落盘一份配置（导入本身会拉一次首页，与冷启动无关）。
    final seeder = AppState(
      paths: paths,
      log: LogService(),
      httpClient: _CapturingClient(),
    );
    await seeder.bootstrap();
    final seeded = await seeder.importConfig(_configJson, displayName: '启动');
    expect(seeded, isTrue, reason: seeder.lastError?.logLine);
    seeder.dispose();

    // 2) 冷启动：同一数据目录重新打开。
    coldClient = _CapturingClient();
    coldState = AppState(
      paths: paths,
      log: LogService(),
      httpClient: coldClient,
    );
    await coldState.bootstrap();

    // 3) 暖实例：另开一份数据目录并导入（导入后 homeResult 非空）。
    warmClient = _CapturingClient();
    warmState = AppState(
      paths: AppPaths.resolve(
        overrides: {
          'roaming': '${temp.path}${Platform.pathSeparator}warm',
          'local': '${temp.path}${Platform.pathSeparator}warm',
        },
      ),
      log: LogService(),
      httpClient: warmClient,
    );
    await warmState.bootstrap();
    final warmImported =
        await warmState.importConfig(_configJson, displayName: '暖');
    expect(warmImported, isTrue, reason: warmState.lastError?.logLine);
  });

  tearDown(() async {
    coldState.dispose();
    warmState.dispose();
    try {
      await temp.delete(recursive: true);
    } catch (_) {}
  });

  testWidgets('冷启动：bootstrap 后无首页，挂载 AppShell 必须自动加载首页', (tester) async {
    // 前置条件：缺陷的起点就是「bootstrap 恢复出站点但不拉首页」。
    expect(
      coldState.selectedSite?.key,
      'startup_site',
      reason: 'bootstrap 应恢复出选中站点（否则首页无从加载）',
    );
    expect(
      coldState.homeResult,
      isNull,
      reason: 'bootstrap **不得**自己拉首页——这正是缺陷起点；'
          '若这里变成非 null，说明加载改到了 bootstrap，本用例需同步调整',
    );
    expect(
      coldClient.requests,
      isEmpty,
      reason: 'bootstrap 阶段不应有任何站点请求',
    );

    await _mountShell(tester, coldState);

    expect(
      coldClient.requests,
      isNotEmpty,
      reason: '冷启动挂载壳层后必须发出首页请求（否则用户停在空页）',
    );
    expect(
      coldState.homeResult,
      isNotNull,
      reason: '首页结果必须已就绪，用户才能直接看到内容',
    );
    expect(
      coldState.homeResult!.list.map((v) => v.vodName),
      contains('冷启动影片'),
      reason: '首页内容必须来自真实请求结果',
    );
  });

  testWidgets('幂等：已有首页结果时挂载 AppShell 不得重复请求', (tester) async {
    expect(warmState.homeResult, isNotNull, reason: '导入后应已有首页结果');
    // 只看挂载之后的请求。
    warmClient.requests.clear();

    await _mountShell(tester, warmState);

    expect(
      warmClient.requests,
      isEmpty,
      reason: '已有 homeResult 时不得重复拉首页（幂等守卫）',
    );
  });
}
