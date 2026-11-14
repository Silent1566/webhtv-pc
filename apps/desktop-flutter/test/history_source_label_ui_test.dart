/// 历史卡片上的「非当前源」标注：**一枚** chip，固定在海报左上角。
///
/// 用户 2026-10-27 反馈原实现把来源写了两遍（右上 chip + 副标题里追加
/// `集名 · 来源名`），且没有可读名时会写出 URL。本文件只锁用户可见行为：
///
/// 1. 非当前源的卡片上，来源可读名**恰好出现一次**，位置在海报左上；
/// 2. 副标题只保留集名，不含来源、不含 URL；
/// 3. 「来源未知」（空 source_key）同样只在左上出现一次；
/// 4. 进度角标（左下）与聚合数量角标（右下）位置不变，删除态照旧抑制；
/// 5. 文字放大到 clamp 上界时不溢出固定高度的文字区。
///
/// ## 为什么真实 I/O 要夹在 `tester.runAsync` 里
///
/// `testWidgets` 跑在假时钟下：`activateConfigRecord` / `setHistoryScope` 会
/// 真写数据库与 settings.json，假时钟不推进这些 await（本仓库既有的
/// `webhtv-pc-test-io-layering` 分层纪律）。
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

/// 任何真实 socket 都不该在这次测试里发生。
class _NoNetworkClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    throw StateError('测试不应发起网络请求');
  }
}

const String sourceA = 'bridge|dev-uuid-0001|a';
const String sourceB = 'bridge|dev-uuid-0001|b';
const String sourceC = 'bridge|dev-uuid-0001|c';
const String deviceBase = 'http://192.168.50.9:9978';

/// 最小可用站点：`activateConfigRecord` 要求配置里至少有一个站点。
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
    tempDir = await Directory.systemTemp.createTemp('webhtv-history-source');
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
    String episodeName = '第1集',
    int updatedAt = 1000,
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

  /// 种好配置并把当前源切到本机源 A、范围切到「全部来源」。
  Future<void> activateSourceA(WidgetTester tester) async {
    seedRecord('a', '源A');
    seedRecord('b', '摸鱼源');
    seedRecord('c', '备用源');
    await tester.runAsync(() async {
      await state.activateConfigRecord(1);
      await state.setHistoryScope(UiHistoryScope.global);
    });
    expect(state.activeSourceKey, sourceA);
    expect(state.historyScope, UiHistoryScope.global);
  }

  Future<void> pumpHistory(
    WidgetTester tester, {
    Size size = const Size(1400, 1000),
    double textScaleFactor = 1.0,
  }) async {
    if (textScaleFactor != 1.0) {
      tester.platformDispatcher.textScaleFactorTestValue = textScaleFactor;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    }
    tester.view.physicalSize = size;
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

  Finder rowOf(int id) => find.byKey(ValueKey('history-row-$id'));

  Finder posterOf(int id) => find
      .descendant(of: rowOf(id), matching: find.byType(AspectRatio))
      .first;

  Finder chipOf(int id) =>
      find.byKey(ValueKey('history-source-chip-$id'));

  /// chip 必须落在海报的**左上象限**，而且贴着左上角（不是随便哪个偏上位置）。
  void expectTopLeft(WidgetTester tester, int id) {
    final poster = tester.getRect(posterOf(id));
    final chip = tester.getRect(chipOf(id));
    expect(
      chip.center.dx,
      lessThan(poster.center.dx),
      reason: '来源 chip 必须在海报左半边（要求：海报左上角）',
    );
    expect(
      chip.center.dy,
      lessThan(poster.center.dy),
      reason: '来源 chip 必须在海报上半边（要求：海报左上角）',
    );
    expect(
      chip.left - poster.left,
      lessThan(24),
      reason: '来源 chip 必须贴住左边，而不是浮在中间',
    );
    expect(
      chip.top - poster.top,
      lessThan(24),
      reason: '来源 chip 必须贴住上边，而不是浮在中间',
    );
  }

  testWidgets('非当前源：可读来源名只在海报左上出现一次', (tester) async {
    await activateSourceA(tester);
    seedHistory(sourceKey: sourceB, vodName: '外站剧');
    final id = state.recentHistory().single.id;

    await pumpHistory(tester);

    expect(
      find.text('摸鱼源'),
      findsOneWidget,
      reason: '来源名必须只渲染一次（旧实现 chip + 副标题各一次）',
    );
    expect(chipOf(id), findsOneWidget);
    expectTopLeft(tester, id);

    // 副标题只有集名：不得再拼来源名，也不得出现任何 URL。
    expect(find.text('第1集'), findsOneWidget);
    expect(find.text('第1集 · 摸鱼源'), findsNothing);
    expect(
      find.textContaining(deviceBase),
      findsNothing,
      reason: '来源标注必须是可读名，不能把 origin/URL 渲染到卡片上',
    );
  });

  testWidgets('来源未知：标记同样只在海报左上出现一次', (tester) async {
    await activateSourceA(tester);
    seedHistory(sourceKey: '', vodName: '无源老记录');
    final id = state.recentHistory().single.id;

    await pumpHistory(tester);

    expect(
      find.text('来源未知'),
      findsOneWidget,
      reason: '空 source_key 的记录也必须只标一次（旧实现只写进了副标题）',
    );
    expect(chipOf(id), findsOneWidget);
    expectTopLeft(tester, id);
    expect(find.text('第1集'), findsOneWidget);
    expect(find.text('第1集 · 来源未知'), findsNothing);
  });

  testWidgets('多源聚合卡：组合标签只出现一次，仍是左上单枚 chip', (tester) async {
    await activateSourceA(tester);
    // 同一部剧（同一 TMDB 身份）分别来自两个非当前源 → 组成一张聚合卡。
    seedHistory(sourceKey: sourceB, vodName: '合剧', tmdbId: 77, mediaType: 'tv');
    seedHistory(
      sourceKey: sourceC,
      vodName: '合剧',
      updatedAt: 2000,
      tmdbId: 77,
      mediaType: 'tv',
    );
    final id = state.recentHistory().first.id;

    await pumpHistory(tester);

    expect(find.text('合剧'), findsOneWidget, reason: '聚合后只有一张卡');
    expect(
      find.text('2 个其他来源'),
      findsOneWidget,
      reason: '多源聚合只能出现一次组合标签，不能拆成两行/两枚 chip',
    );
    expect(find.byType(Row), findsWidgets);
    expectTopLeft(tester, id);
  });

  testWidgets('进度角标在左下、聚合数量角标在右下，chip 在左上', (tester) async {
    await activateSourceA(tester);
    seedHistory(sourceKey: sourceB, vodName: '外站剧', tmdbId: 88, mediaType: 'tv');
    seedHistory(
      sourceKey: sourceB,
      vodName: '外站剧',
      episodeName: '第2集',
      updatedAt: 2000,
      tmdbId: 88,
      mediaType: 'tv',
    );
    final id = state.recentHistory().first.id;

    await pumpHistory(tester);

    final poster = tester.getRect(posterOf(id));
    final progress = tester.getRect(find.text('已看 30%'));
    expect(progress.center.dx, lessThan(poster.center.dx), reason: '进度角标在左');
    expect(progress.center.dy, greaterThan(poster.center.dy), reason: '进度角标在下');

    final count = tester.getRect(find.byKey(ValueKey('history-group-count-$id')));
    expect(count.center.dx, greaterThan(poster.center.dx), reason: '数量角标在右');
    expect(count.center.dy, greaterThan(poster.center.dy), reason: '数量角标在下');

    expectTopLeft(tester, id);
  });

  testWidgets('删除态照旧抑制来源 chip 与聚合数量角标', (tester) async {
    await activateSourceA(tester);
    seedHistory(sourceKey: sourceB, vodName: '外站剧', tmdbId: 99, mediaType: 'tv');
    seedHistory(
      sourceKey: sourceB,
      vodName: '外站剧',
      episodeName: '第2集',
      updatedAt: 2000,
      tmdbId: 99,
      mediaType: 'tv',
    );
    final id = state.recentHistory().first.id;

    await pumpHistory(tester);
    expect(chipOf(id), findsOneWidget);

    await tester.longPress(rowOf(id));
    await tester.pump();

    expect(
      chipOf(id),
      findsNothing,
      reason: '删除态是另一个模式：来源 chip 必须一起收起（与原来一致）',
    );
    expect(find.byKey(ValueKey('history-group-count-$id')), findsNothing);
    expect(find.text('已看 30%'), findsNothing);
  });

  for (final scale in const [1.25, 1.5]) {
    testWidgets('文字放大 $scale 倍时带来源 chip 的卡片不溢出', (tester) async {
      await activateSourceA(tester);
      seedHistory(sourceKey: sourceB, vodName: '外站剧');
      final id = state.recentHistory().single.id;

      await pumpHistory(tester, textScaleFactor: scale);

      expect(
        tester.takeException(),
        isNull,
        reason: 'textScaleFactor=$scale 时卡片溢出了固定高度的文字区',
      );
      expect(find.text('摸鱼源'), findsOneWidget);
      expect(chipOf(id), findsOneWidget);
    });
  }
}
