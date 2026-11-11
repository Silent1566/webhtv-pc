/// 历史聚合开关 + 跨源来源标注的 UI 行为（docs/phase5/design/05）。
///
/// 锁三条用户可见行为：
///
/// 1. 默认按同名作品**聚合**（同一部剧多集只出现一张卡）；
/// 2. 点开关能切到「逐集」，同一个剧本就变成 N 张卡；
/// 3. 全局范围下，来自**其他源**的卡带来源标注（chip + 副标题来源名）。
///
/// ## 为什么所有播种与配置激活都要在测试体里同步完成
///
/// testWidgets 跑在假时钟下，activateConfigRecord / setHistoryScope 会真的写
/// 数据库与 settings.json；假时钟不会推进这些真实 I/O，await 永远不返回。
/// 但 setUp 又拿不到注入过 httpClient 的同一实例，因此这里把真实 I/O 放在
/// tester.runAsync 里跑（那里是真实时钟）。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:webhtv_pc/core/history_aggregation.dart';
import 'package:webhtv_pc/core/history_scope.dart';
import 'package:webhtv_pc/core/source_key.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/library_pages.dart';

/// 任何真实 socket 都不该在这次测试里发生。
class _NoNetworkClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    throw StateError('测试不应发起网络请求');
  }
}

const String sourceA = 'bridge|dev-uuid-0001|a';
const String sourceB = 'bridge|dev-uuid-0001|b';
const String deviceBase = 'http://192.168.50.9:9978';

/// 最小可用站点：activateConfigRecord 要求配置里至少有一个站点
/// （parseConfigRecord 对空站点直接判 configInvalid），否则无法设为当前源。
const List<Object?> minimalSites = [
  <String, Object?>{
    'key': 'csp_a',
    'name': '站A',
    'type': 4,
    'api': 'http://127.0.0.1:9978/vod/api?key=csp_a',
    'searchable': 1,
  },
];

void main() {
  late Directory tempDir;
  late AppState state;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('webhtv-history-agg');
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
    origin: deviceBase,
    json: const {'sites': minimalSites},
    makeActive: false,
    sourceKey: BridgeSourceKey.of(
      deviceUuid: 'dev-uuid-0001',
      interfaceKey: interfaceKey,
    ),
    bridgeDevice: 'dev-uuid-0001',
    bridgeInterfaceKey: interfaceKey,
    bridgeConfigUrl: '$deviceBase/vod/api?configKey=$interfaceKey',
  );

  void seedHistory({
    required String sourceKey,
    required String vodName,
    required String episodeName,
    required int updatedAt,
    int tmdbId = 0,
    String mediaType = '',
  }) {
    state.database!.upsertHistory(
      siteKey: 'csp_a',
      vodId: 'v-$vodName',
      vodName: vodName,
      flag: '线路一',
      episodeName: episodeName,
      episodeId: 'http://x/$vodName/$episodeName',
      positionMs: 30000,
      durationMs: 100000,
      updatedAt: updatedAt,
      sourceKey: sourceKey,
      tmdbId: tmdbId,
      mediaType: mediaType,
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

  /// 点开关并等**真实写盘**落地。
  Future<void> tapAggregation(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('history-aggregation-switch')));
    for (var round = 0; round < 20; round++) {
      await tester.pump(const Duration(milliseconds: 16));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });
    }
  }

  testWidgets('默认聚合：同一 TMDB 的多集只出现一张卡', (tester) async {
    seedRecord('a', '源A');
    seedHistory(
      sourceKey: sourceA,
      vodName: '庆余年',
      episodeName: '第1集',
      updatedAt: 300,
      tmdbId: 1234,
      mediaType: 'tv',
    );
    seedHistory(
      sourceKey: sourceA,
      vodName: '庆余年',
      episodeName: '第2集',
      updatedAt: 200,
      tmdbId: 1234,
      mediaType: 'tv',
    );
    await pumpHistory(tester);

    expect(state.historyAggregation, UiHistoryAggregation.tmdb);
    expect(find.byKey(const ValueKey('history-grid')), findsOneWidget);
    // 片名只渲染一次 = 只有一张卡。
    expect(find.text('庆余年'), findsOneWidget);
    // 聚合数量角标。
    expect(find.textContaining('2 条'), findsOneWidget);
  });

  testWidgets('切到逐集后同一部剧变成两张卡', (tester) async {
    seedRecord('a', '源A');
    seedHistory(
      sourceKey: sourceA,
      vodName: '庆余年',
      episodeName: '第1集',
      updatedAt: 300,
      tmdbId: 1234,
      mediaType: 'tv',
    );
    seedHistory(
      sourceKey: sourceA,
      vodName: '庆余年',
      episodeName: '第2集',
      updatedAt: 200,
      tmdbId: 1234,
      mediaType: 'tv',
    );
    await pumpHistory(tester);
    expect(find.text('庆余年'), findsOneWidget);

    await tapAggregation(tester);
    await tester.pumpAndSettle();

    expect(state.historyAggregation, UiHistoryAggregation.off);
    expect(find.text('庆余年'), findsNWidgets(2));
  });

  testWidgets('全局范围下非当前源的卡片带来源标注', (tester) async {
    seedRecord('a', '源A');
    seedRecord('b', '摸鱼');
    await tester.runAsync(() async {
      await state.activateConfigRecord(1);
      await state.setHistoryScope(UiHistoryScope.global);
    });
    expect(state.activeSourceKey, sourceA);

    seedHistory(
      sourceKey: sourceA,
      vodName: '本站剧',
      episodeName: '第1集',
      updatedAt: 300,
      tmdbId: 11,
      mediaType: 'tv',
    );
    seedHistory(
      sourceKey: sourceB,
      vodName: '外站剧',
      episodeName: '第1集',
      updatedAt: 200,
      tmdbId: 22,
      mediaType: 'tv',
    );

    await pumpHistory(tester);

    // 两张卡都在（全局范围）。
    expect(find.text('本站剧'), findsOneWidget);
    expect(find.text('外站剧'), findsOneWidget);
    // 非当前源那张带来源名。
    expect(find.textContaining('摸鱼'), findsWidgets);
  });

  testWidgets('按源范围下只显示当前源的记录', (tester) async {
    seedRecord('a', '源A');
    seedRecord('b', '摸鱼');
    await tester.runAsync(() async {
      await state.activateConfigRecord(1);
    });

    seedHistory(
      sourceKey: sourceA,
      vodName: '本站剧',
      episodeName: '第1集',
      updatedAt: 300,
      tmdbId: 11,
      mediaType: 'tv',
    );
    seedHistory(
      sourceKey: sourceB,
      vodName: '外站剧',
      episodeName: '第1集',
      updatedAt: 200,
      tmdbId: 22,
      mediaType: 'tv',
    );

    await pumpHistory(tester);
    expect(state.historyScope, UiHistoryScope.source);
    expect(find.text('本站剧'), findsOneWidget);
    expect(find.text('外站剧'), findsNothing);
  });
}
