/// 历史页的「历史范围」开关（对齐安卓 `global_history_mode`）。
///
/// ## 为什么单开一个文件
///
/// `phase6_history_page_test.dart` 的用例全部建立在「只有当前源」的种子上，
/// 加进来就得给每个用例补一个不关心前置条件。这里只锁两条用户可见行为：
///
/// 1. 默认**只显示当前播放源**的历史（跨源串进度是本次要修的缺陷）；
/// 2. 页面上那个开关能切到「全部来源」，且状态落进偏好（重启后保持）。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:webhtv_pc/core/history_scope.dart';
import 'package:webhtv_pc/core/source_key.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/library_pages.dart';

void main() {
  late Directory tempDir;
  late AppState state;

  const sourceA = 'bridge|dev-uuid-0001|a';
  const sourceB = 'bridge|dev-uuid-0001|b';

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('webhtv-history-scope');
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
      // 历史页点卡片会走 `resolvePlayback`（真实 HTTP + 本地代理链）。
      // `testWidgets` 是假时钟，真实 socket I/O 会挂死，必须注入假 client
      // （本仓库既有的分层纪律：webhtv-pc-test-io-layering）。
      httpClient: _NoNetworkClient(),
    );
    await state.bootstrap();
  });

  tearDown(() async {
    state.dispose();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  int seedRecord(String interfaceKey, String name) => state.database!.saveConfig(
        name: name,
        origin: 'http://192.168.50.9:9978',
        json: const {'sites': <Object?>[]},
        makeActive: false,
        sourceKey: BridgeSourceKey.of(
          deviceUuid: 'dev-uuid-0001',
          interfaceKey: interfaceKey,
        ),
        bridgeDevice: 'dev-uuid-0001',
        bridgeInterfaceKey: interfaceKey,
        bridgeConfigUrl: 'https://sub.example/$interfaceKey.json',
      );

  void seedHistory({
    required String sourceKey,
    required String vodName,
    required String siteKey,
    required int updatedAt,
  }) {
    state.database!.upsertHistory(
      siteKey: siteKey,
      vodId: 'v-$vodName',
      vodName: vodName,
      flag: '线路一',
      episodeName: '第1集',
      episodeId: 'http://x/$vodName',
      positionMs: 30000,
      durationMs: 100000,
      updatedAt: updatedAt,
      sourceKey: sourceKey,
    );
  }

  Future<void> pumpHistory(WidgetTester tester) async {
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
  }

  /// 点历史范围开关，并等**真实写盘**落地。
  ///
  /// 为什么不能只 `tap + pumpAndSettle`：`setHistoryScope` 会 await
  /// `UiPreferencesStore._persist`（真实文件 I/O），而 `testWidgets` 是假时钟，
  /// 那个 await 不会被 pump 推进 —— 不夹 `runAsync` 窗口时按钮文案会停在上一次
  /// 状态，断言就成了「开关没反应」的假绿/假红。
  Future<void> tapScope(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('history-scope-switch')));
    for (var round = 0; round < 20; round++) {
      await tester.pump(const Duration(milliseconds: 16));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 16)),
      );
    }
    await tester.pumpAndSettle();
  }

  /// 种下两个源的历史，并把源 A 设为当前配置。返回 A 的记录 id。
  Future<int> seedTwoSources() async {
    final a = seedRecord('a', '源 A');
    seedRecord('b', '源 B');
    seedHistory(
      sourceKey: sourceA,
      vodName: 'A源剧集',
      siteKey: 'csp_a',
      updatedAt: 2000,
    );
    seedHistory(
      sourceKey: sourceB,
      vodName: 'B源剧集',
      siteKey: 'csp_b',
      updatedAt: 1000,
    );
    await state.activateConfigRecord(a);
    return a;
  }

  testWidgets('空来源记录不出现在「当前来源」里（用户 2026-10-28 反馈）', (tester) async {
    await seedTwoSources();
    // 空 source_key = 迁移前老记录 / 实时同步写入的记录。
    seedHistory(
      sourceKey: '',
      vodName: '无源老记录',
      siteKey: 'csp_a',
      updatedAt: 3000,
    );

    await pumpHistory(tester);

    expect(find.text('A源剧集'), findsOneWidget);
    expect(
      find.text('无源老记录'),
      findsNothing,
      reason: '按源隔离时不得把无法归属的记录混进来（会显示成「来源未知」）',
    );
    expect(
      find.textContaining('来源未知'),
      findsNothing,
      reason: '当前来源视图里不应出现「来源未知」角标',
    );

    // 全局视图仍然可见：严格过滤不是丢数据，只是换视图。
    // 必须走 tapScope（内夹 runAsync 窗口）：直接 await setHistoryScope
    // 会在假时钟下等真实写盘，整条用例挂死到超时。
    await tapScope(tester);
    expect(find.text('无源老记录'), findsOneWidget);
  });

  test('搜索同样不返回空来源记录（否则搜索页会翻出它们）', () async {
    await seedTwoSources();
    seedHistory(
      sourceKey: '',
      vodName: '无源老记录',
      siteKey: 'csp_a',
      updatedAt: 3000,
    );

    expect(state.searchHistory('记录').map((item) => item.vodName), isEmpty);

    await state.setHistoryScope(UiHistoryScope.global);
    expect(
      state.searchHistory('记录').map((item) => item.vodName),
      ['无源老记录'],
    );
  });

  testWidgets('默认只显示当前播放源的历史（跨源不串）', (tester) async {
    await seedTwoSources();
    expect(
      state.historyScope,
      UiHistoryScope.source,
      reason: '默认必须是按源隔离',
    );

    await pumpHistory(tester);

    expect(find.text('A源剧集'), findsOneWidget);
    expect(
      find.text('B源剧集'),
      findsNothing,
      reason: '另一条源的历史不得出现在当前源的列表里',
    );
  });

  testWidgets('开关标出当前范围，点一下切到「全部来源」并显示两个源', (tester) async {
    await seedTwoSources();
    await pumpHistory(tester);

    final toggle = find.byKey(const ValueKey('history-scope-switch'));
    expect(toggle, findsOneWidget, reason: '历史范围开关必须在工具栏可见');
    expect(
      find.text('当前来源'),
      findsOneWidget,
      reason: '默认范围必须在按钮上写出来，不能只靠 Tooltip',
    );

    await tapScope(tester);

    expect(state.historyScope, UiHistoryScope.global);
    expect(find.text('全部来源'), findsOneWidget);
    expect(find.text('A源剧集'), findsOneWidget);
    expect(find.text('B源剧集'), findsOneWidget);
  });

  testWidgets('再点一下能切回「当前来源」（开关可逆）', (tester) async {
    await seedTwoSources();
    await pumpHistory(tester);

    await tapScope(tester);
    expect(state.historyScope, UiHistoryScope.global);
    await tapScope(tester);

    expect(state.historyScope, UiHistoryScope.source);
    expect(find.text('全部来源'), findsNothing);
    expect(find.text('B源剧集'), findsNothing);
  });

  testWidgets('当前来源空、全部来源有记录时，空态说清原因并给直达开关', (tester) async {
    final a = seedRecord('a', '源 A');
    seedRecord('b', '源 B');
    // 当前源（A）没有任何记录，但 B 源和一条无来源老记录都在库里。
    seedHistory(
      sourceKey: sourceB,
      vodName: 'B源剧集',
      siteKey: 'csp_b',
      updatedAt: 2000,
    );
    seedHistory(
      sourceKey: '',
      vodName: '无源老记录',
      siteKey: 'csp_a',
      updatedAt: 3000,
    );
    await state.activateConfigRecord(a);

    await pumpHistory(tester);

    expect(
      find.text('当前来源暂无记录'),
      findsOneWidget,
      reason: '按源过滤后页面为空不等于没历史，写「暂无播放记录」是假话',
    );
    expect(
      find.textContaining('2 条记录'),
      findsOneWidget,
      reason: '必须说清全部来源里还剩多少条，用户才知道不是数据丢了',
    );
    expect(find.textContaining('1 条归属不到具体播放源'), findsOneWidget);
    expect(find.text('B源剧集'), findsNothing);

    final showAll = find.byKey(const ValueKey('history-empty-show-all'));
    expect(showAll, findsOneWidget, reason: '空态必须给唯一出路，否则用户只能自己找工具栏');
    await tester.tap(showAll);
    for (var round = 0; round < 20; round++) {
      await tester.pump(const Duration(milliseconds: 16));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 16)),
      );
    }
    await tester.pumpAndSettle();

    expect(state.historyScope, UiHistoryScope.global);
    expect(find.text('B源剧集'), findsOneWidget);
    expect(find.text('无源老记录'), findsOneWidget);
  });

  testWidgets('真的没有任何历史时，空态保持原文案', (tester) async {
    seedRecord('a', '源 A');
    await pumpHistory(tester);

    expect(find.text('暂无播放记录'), findsOneWidget);
    expect(find.text('当前来源暂无记录'), findsNothing);
    expect(find.byKey(const ValueKey('history-empty-show-all')), findsNothing);
  });

  test('范围偏好落盘（重启后保持）', () async {
    // 纯状态层用例（不用 testWidgets）：`bootstrap`/`setHistoryScope` 都是真实
    // 文件 I/O，放进假时钟里会一直不完成。
    await seedTwoSources();
    await state.setHistoryScope(UiHistoryScope.global);
    expect(state.historyScope, UiHistoryScope.global);

    final reopened = AppState(
      paths: AppPaths.resolve(
        overrides: {
          'config': '${tempDir.path}/webhtv-pc',
          'data': '${tempDir.path}/webhtv-pc',
          'cache': '${tempDir.path}/webhtv-pc/cache',
          'state': '${tempDir.path}/webhtv-pc/logs',
        },
      ),
      log: LogService(),
      httpClient: _NoNetworkClient(),
    );
    try {
      await reopened.bootstrap();
      expect(
        reopened.historyScope,
        UiHistoryScope.global,
        reason: '开关状态必须写进 settings.json，否则每次启动都退回默认',
      );
    } finally {
      reopened.dispose();
    }
  });
}

/// 假 client：任何请求都直接失败，绝不发真实 socket。
class _NoNetworkClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    throw StateError('测试不发真实站点请求：${request.url}');
  }
}
