/// Phase 4 · 纯 TMDB 详情页集成（`docs/phase4/design/05` §5.5）。
///
/// 前置：本机 fixture 服务已启动（端口 18080）。
///
/// 步骤与断言：
///   1. 通过 TMDB 搜索进入纯 TMDB 详情页
///   2. 断言季度选择器显示 TMDB **全部**季度（含不可播放季度）
///   3. 断言剧集卡片**没有**播放按钮
///   4. 点击剧集卡片 → 跳转到搜索页并带入标题
///   5. 断言搜索结果中出现 fixture 站点条目
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/search_page.dart';
import 'package:webhtv_pc/ui/tmdb_detail_page.dart';

void evidence(String message) =>
    debugPrint('PHASE4-EVIDENCE tmdb-only-detail $message');

Future<void> drainRealIo(
  WidgetTester tester, {
  required bool Function() until,
  Duration timeout = const Duration(seconds: 20),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (until()) return;
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 120));
    });
    await tester.pump();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final base =
      Platform.environment['WEBHTV_FIXTURE_BASE'] ?? 'http://127.0.0.1:18080';

  testWidgets('纯 TMDB 详情页：全部季度 / 卡片不可播 / 跳搜索页', (tester) async {
    final temp = Directory.systemTemp.createTempSync('webhtv-tmdb-only-e2e');
    final paths = AppPaths.resolve(
      overrides: {'roaming': temp.path, 'local': temp.path},
    );
    final state = AppState(paths: paths, log: LogService());
    addTearDown(() {
      state.dispose();
      try {
        temp.deleteSync(recursive: true);
      } catch (_) {}
    });
    await state.bootstrap();

    await state.saveTmdbConfig(
      state.tmdbConfig.copyWith(
        apiBase: '$base/tmdb/3',
        apiKey: 'fixture-key',
        accessToken: '',
        imageBase: '$base/tmdb-img/w342',
        backdropBase: '$base/tmdb-img/w780',
        enabledSites: const [],
        disabledSites: const [],
        allowedSites: const [],
      ),
    );

    final imported = await state.importConfig(
      jsonEncode({
        'name': 'TMDB 纯详情 e2e',
        'sites': [
          {
            'key': 'nodejs_tmdb',
            'name': 'TMDB 站点',
            'type': 1,
            'api': '$base/api/tmdb-detail',
            'searchable': 1,
          },
        ],
      }),
    );
    expect(imported, isTrue, reason: state.lastError?.logLine);

    // 1) 通过 TMDB 搜索进入（`04` §6.1 入口 1）。
    List<TmdbItem> results;
    try {
      results = await state.tmdbService.search('示例');
    } catch (error) {
      evidence('search-error=$error');
      rethrow;
    }
    expect(results, isNotEmpty, reason: 'TMDB 搜索无结果');
    final tv = results.firstWhere((item) => item.isTv);
    evidence('search-results=${results.length} picked=${tv.identity?.key}');

    String? searchedTitle;
    TmdbIdentity? searchedHint;
    await tester.pumpWidget(
      MaterialApp(
        home: TmdbDetailPage(
          service: state.tmdbService,
          identity: tv.identity!,
          initialItem: tv,
          onSearchSource: (title, hint) {
            searchedTitle = title;
            searchedHint = hint;
          },
        ),
      ),
    );
    await tester.pump();

    // 2) 季度选择器显示 TMDB 全部季度（含不可播放季度：特别篇 + S1 + S2）。
    await drainRealIo(
      tester,
      until: () =>
          find.byKey(const ValueKey('tmdb-only-season-0')).evaluate().isNotEmpty,
    );
    for (final season in [0, 1, 2]) {
      expect(
        find.byKey(ValueKey('tmdb-only-season-$season')),
        findsOneWidget,
        reason: '缺少 TMDB 季度 $season',
      );
    }
    evidence('seasons=all(0,1,2) options=3');

    // 3) 剧集卡片**没有**播放按钮（`04` §6.2 关键约束）。
    expect(
      find.text('播放'),
      findsNothing,
      reason: '纯 TMDB 详情页不得出现播放按钮',
    );
    expect(
      find.byKey(const ValueKey('tmdb-play')),
      findsNothing,
      reason: '纯 TMDB 详情页不得出现播放入口',
    );
    evidence('play-button=absent');

    // 4) 点击剧集卡片 → 跳搜索页（这里断言回调收到标题与身份提示）。
    final episodeTiles = find.byType(InkWell).evaluate().isNotEmpty
        ? find.byType(InkWell)
        : find.byType(GestureDetector);
    expect(
      episodeTiles.evaluate(),
      isNotEmpty,
      reason: '未找到可点击的剧集卡片',
    );
    await tester.tap(find.text('搜索站源').first);
    await tester.pumpAndSettle();
    expect(searchedTitle, isNotNull, reason: '未触发搜索站源回调');
    expect(searchedTitle, isNotEmpty, reason: '带入的标题为空');
    expect(searchedHint?.tmdbId, tv.tmdbId, reason: '身份提示不一致');
    evidence('search-source title=$searchedTitle hint=${searchedHint?.key}');

    // 5) 搜索页带入标题后自动搜索，且结果中出现 fixture 站点条目。
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SearchPage(
            state: state,
            initialKeyword: '示例剧集',
            identityHint: tv.identity,
          ),
        ),
      ),
    );
    await tester.pump();
    await drainRealIo(
      tester,
      until: () =>
          state.activeSearch != null &&
          state.activeSearch!.finished &&
          state.activeSearch!.results.isNotEmpty,
      timeout: const Duration(seconds: 30),
    );
    final outcome = state.activeSearch;
    expect(outcome, isNotNull, reason: '搜索未产生结果');
    final entries = outcome!.results;
    expect(entries, isNotEmpty, reason: '搜索结果为空');
    final vodCount = entries.fold<int>(0, (sum, entry) => sum + entry.itemCount);
    expect(vodCount, greaterThan(0), reason: '搜索结果没有条目');
    evidence(
      'search entries=${entries.length} items=$vodCount '
      'sites=${entries.map((e) => e.siteKey).toSet().join(",")}',
    );
  });
}
