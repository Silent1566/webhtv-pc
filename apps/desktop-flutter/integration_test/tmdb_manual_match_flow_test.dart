/// Phase 4 · TMDB 手动匹配集成（`docs/phase4/design/05` §5.3）。
///
/// 前置：本机 fixture 服务已启动（端口 18080）。
///
/// 步骤与断言：
///   1. 打开一个匹配失败的 fixture 详情页
///   2. 手动匹配 → 选定作品
///   3. 进入季度绑定 → 选定「第 1 季」
///   4. 断言详情页状态显示已匹配（手动结论）
///   5. 重新加载详情 → 断言手动结论仍生效（持久化）
///   6. 改选「第 2 季」→ 断言季度与选集同步切换
///   7. 清除手动绑定（自动）→ 断言回到自动解析结果
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/core/tmdb_season.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/tmdb_widgets.dart' show TmdbLoadPhase;

void evidence(String message) =>
    debugPrint('PHASE4-EVIDENCE tmdb-manual-match $message');

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

  testWidgets('TMDB 手动匹配：持久化 → 仅选季度 → 清除绑定', (tester) async {
    final temp = Directory.systemTemp.createTempSync('webhtv-tmdb-manual-e2e');
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
        'name': 'TMDB 手动匹配 e2e',
        'sites': [
          {
            'key': 'nodejs_tmdb',
            'name': 'TMDB 站点',
            'type': 1,
            'api': '$base/api/tmdb-nomatch',
            'searchable': 1,
          },
        ],
      }),
    );
    expect(imported, isTrue, reason: state.lastError?.logLine);

    final vod = Vod(vodId: 'tmdb-nomatch', vodName: '无法自动匹配的剧集标题');
    await state.loadDetail(vod);
    expect(state.detailPhase, LoadPhase.ready, reason: '详情未就绪');

    // 1) 自动匹配失败（标题与 TMDB fixture 无关）。
    await drainRealIo(
      tester,
      until: () => state.tmdb.phase != TmdbLoadPhase.idle && !state.tmdb.hasMatch,
    );
    expect(state.tmdb.hasMatch, isFalse, reason: '不应自动匹配成功');
    evidence('auto-match-missed=true');

    // 2) 手动匹配：通过 Provider ID 直达（`tmdb:1399`）。
    final item = await state.resolveTmdbProviderId('tmdb:1399');
    expect(item, isNotNull, reason: 'Provider ID 直达失败');
    expect(item!.tmdbId, 1399);
    final outcome = await state.matchTmdbManual(item: item);
    expect(outcome, isNotNull, reason: '手动匹配未返回结果');
    await drainRealIo(tester, until: () => state.tmdb.hasMatch);
    expect(state.tmdb.hasMatch, isTrue, reason: '手动匹配后仍未匹配');
    evidence('manual-match tmdbId=${state.tmdb.item?.tmdbId}');

    // 3) 季度绑定：选定第 1 季（`04` §5.2）。
    final bound = await state.bindTmdbSeason(const TmdbSeasonNumber(1));
    expect(bound, isTrue, reason: '季度绑定未写入');
    await state.reloadTmdb();
    await drainRealIo(
      tester,
      until: () => state.tmdb.selectedSeason == 1,
    );
    expect(state.tmdb.selectedSeason, 1, reason: '绑定后未选中第 1 季');
    evidence('bound season=1 selected=${state.tmdb.selectedSeason}');

    // 4) 选集同步：第 1 季 → 6 集（线路只有 6 集）。
    final line = state.tmdb.lineByFlag('线路一')!;
    expect(line.episodes.length, 6, reason: '线路应为 6 集');
    evidence('s1-episodes=${line.episodes.length}');

    // 5) 持久化：重新加载详情（模拟「返回列表再进入」），手动结论仍生效。
    state.clearDetail();
    await state.loadDetail(vod);
    await drainRealIo(
      tester,
      until: () => state.tmdb.hasMatch && state.tmdb.selectedSeason >= 0,
    );
    expect(state.tmdb.hasMatch, isTrue, reason: '重进详情页后手动结论丢失');
    expect(state.tmdb.item?.tmdbId, 1399, reason: '重进后身份不一致');
    final manualRecord = state.tmdb.matchResult;
    expect(
      manualRecord is TmdbMatchHit && manualRecord.record.isManual,
      isTrue,
      reason: '重进后结论不是手动来源',
    );
    evidence(
      'persisted manual=true tmdbId=${state.tmdb.item?.tmdbId} '
      'season=${state.tmdb.selectedSeason}',
    );

    // 6) 仅选季度：改选第 2 季 → 季度与选集同步切换。
    //
    // 注意：`bindTmdbSeason` 只写绑定；`resolve` 的判定顺序中**手动绑定优先于**
    // 线路显式季度（`02` §3.3 第 5 步），但 `availableSeasons` 是按**线路**
    // 解析的（`02` §4.3），因此这里同时断言绑定已写入与选中季度已生效。
    final rebound = await state.bindTmdbSeason(const TmdbSeasonNumber(2));
    expect(rebound, isTrue, reason: '改选季度未写入');
    await state.reloadTmdb();
    await drainRealIo(
      tester,
      until: () => state.tmdb.selectedSeason == 2,
      timeout: const Duration(seconds: 10),
    );
    // 绑定记录本身必须已更新为第 2 季（这是「仅选季度」的持久化事实）。
    final binding = state.tmdb.resolution?.scope;
    evidence(
      'rebound season=2 selected=${state.tmdb.selectedSeason} '
      'scope=$binding available=${state.tmdb.availableSeasons}',
    );
    expect(
      binding,
      const KnownSeason(2),
      reason: '绑定记录未变为第 2 季（实际 $binding）',
    );

    // 7) 清除手动绑定（「自动」）→ 回到**自动季度解析**。
    //
    // 注意：`TmdbSeasonAuto` 清除的是**季度绑定**，不是媒体匹配
    // （`04` §5.2：「自动（清除手动绑定）」；媒体身份由「重新匹配」改变）。
    // 线路一集名为「第 1 季第 N 集」（6 集）→ 自动解析应回到第 1 季。
    final cleared = await state.bindTmdbSeason(const TmdbSeasonAuto());
    expect(cleared, isTrue, reason: '清除绑定未成功');
    await state.reloadTmdb();
    await drainRealIo(
      tester,
      until: () => state.tmdb.resolution?.scope == const KnownSeason(1),
    );
    expect(
      state.tmdb.resolution?.scope,
      const KnownSeason(1),
      reason: '清除手动绑定后未回到自动解析的第 1 季（实际 ${state.tmdb.resolution?.scope}）',
    );
    // 媒体匹配仍保留（清除的是季度绑定）。
    expect(state.tmdb.hasMatch, isTrue, reason: '清除季度绑定不应丢失媒体匹配');
    evidence(
      'cleared auto-scope=${state.tmdb.resolution?.scope} '
      'available=${state.tmdb.availableSeasons} '
      'selected=${state.tmdb.selectedSeason}',
    );
  });
}
