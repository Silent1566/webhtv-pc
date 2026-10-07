/// Phase 4 · TMDB 详情集成（`docs/phase4/design/05` §5.1）。
///
/// 前置：本机 fixture 服务已启动（`py -m tools.fixture_server.server`，端口 18080）。
///
/// 步骤与断言（对应 design/05 §5.1）：
///   1. 打开 fixture 站点详情页
///   2. 断言 TMDB 状态条从「匹配中」变为「已匹配」
///   3. 断言头部增强字段已应用（简介/海报补位）
///   4. 断言季度选择器显示「第 1 季」
///   5. 断言选集区 12 项
///   6. 切换到「第 2 季」，断言选集变为 10 项
///   7. 断言「TMDB 有 S2E10 但线路 S2 只有 8 集」时不出现第 9/10 项
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/tmdb_title.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/browse_pages.dart';
import 'package:webhtv_pc/ui/tmdb_widgets.dart';

void evidence(String message) =>
    debugPrint('PHASE4-EVIDENCE tmdb-detail $message');

/// 在真实 async 区推进 I/O，直到 [until] 成立或超时。
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

  final base = Platform.environment['WEBHTV_FIXTURE_BASE'] ??
      'http://127.0.0.1:18080';

  testWidgets('TMDB 详情：匹配 → 头部补位 → 季度切换 → 选集数量正确', (tester) async {
    final temp = Directory.systemTemp.createTempSync('webhtv-tmdb-detail-e2e');
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

    // TMDB 指向本机 fixture（生产代码只读 `settings.json`，这里直接写入）。
    final saved = await state.saveTmdbConfig(
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
    expect(saved, isTrue, reason: 'TMDB 设置写入失败');

    final imported = await state.importConfig(
      jsonEncode({
        'name': 'TMDB 详情 e2e',
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

    tester.view.physicalSize = const Size(1600, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final vod = Vod(vodId: 'tmdb-demo', vodName: '示例剧集');
    await tester.pumpWidget(
      MaterialApp(home: DetailPage(state: state, vod: vod)),
    );
    await tester.pump();

    // 1) 详情就绪（线路出现）。
    await drainRealIo(
      tester,
      until: () => state.detailPhase == LoadPhase.ready,
    );
    expect(state.detailPhase, LoadPhase.ready, reason: '详情未就绪');
    await tester.pump();

    // 2) TMDB 匹配 + 详情加载完成。
    await drainRealIo(
      tester,
      until: () => state.tmdb.hasMatch && state.tmdb.detail != null,
    );
    expect(state.tmdb.hasMatch, isTrue, reason: 'TMDB 未匹配');
    expect(state.tmdb.detail, isNotNull, reason: 'TMDB 详情未加载');
    evidence(
      'matched item=${state.tmdb.item?.title} '
      'phase=${state.tmdb.phase} '
      'error=${state.tmdb.error?.logLine} '
      'counts=${state.tmdb.seasonEpisodeCounts} '
      'scope=${state.tmdb.scope} '
      'seasons=${state.tmdb.availableSeasons} '
      'selected=${state.tmdb.selectedSeason}',
    );

    // 3) 头部补位：来源简介「站点简介（短）」应被 TMDB 更长的简介替换。
    final enriched = state.tmdb.enrich(vod).vod;
    expect(
      enriched.vodContent != null && enriched.vodContent!.length > 6,
      isTrue,
      reason: '简介未补位：${enriched.vodContent}',
    );
    evidence('overview-length=${enriched.vodContent!.length}');

    // 4) 季度选择器显示「第 1 季」。
    await drainRealIo(tester, until: () => state.tmdb.selectedSeason >= 0);
    expect(state.tmdb.selectedSeason, 1, reason: '默认季度不是第 1 季');

    // 5) 选集区：线路一 S1 12 集，季度 1 → 渲染 12 项。
    final line1 = state.tmdb.lineByFlag('线路一')!;
    expect(line1.episodes.length, 22, reason: '线路一应为 S1 12 + S2 10 = 22 集');
    final enrichedLine1 = state.tmdb.applyEpisodesToLine(line1).line;
    final s1Rendered = TmdbEpisodeRenderPolicy.filter(
      episodes: enrichedLine1.episodes,
      availableSeasons: state.tmdb.availableSeasons,
      selectedSeason: state.tmdb.selectedSeason,
      seasonOf: _seasonOf,
    );
    expect(s1Rendered.length, 12, reason: 'S1 应渲染 12 项，实际 ${s1Rendered.length}');
    // 剧集元数据已应用（TMDB 季 1 有 12 集）。
    await drainRealIo(tester, until: () => state.tmdb.episodes.length == 12);
    expect(state.tmdb.episodes.length, 12, reason: 'TMDB 季 1 剧集数不是 12');
    evidence('s1-line-episodes=${s1Rendered.length} tmdb-s1=12');

    // 6) 切换到第 2 季：TMDB 季 2 有 10 集，线路一 S2 也是 10 集 → 渲染 10 项。
    state.tmdb.selectSeason(2);
    await tester.pump();
    // `selectSeason` 会清空旧季度剧集（`04` §4.3 第 3 步），必须重新拉取。
    // 产品里由 `TmdbSeasonSelector.onChanged` 触发；测试直接调状态层时需自己触发。
    unawaited(state.tmdb.loadEpisodes(generation: state.tmdb.generation));
    // 元数据是异步加载的：先等 TMDB 季 2 的剧集到位，再断言渲染数。
    await drainRealIo(
      tester,
      until: () =>
          state.tmdb.episodes.length == 10 &&
          state.tmdb.applyEpisodesToLine(line1).line.episodes.any(
            (e) => _seasonOf(e) == 2 && e.extra['display_name'] != null,
          ),
    );
    expect(state.tmdb.episodes.length, 10, reason: 'TMDB 季 2 剧集数不是 10');
    final enrichedLine1S2 = state.tmdb.applyEpisodesToLine(line1).line;
    final s2Rendered = TmdbEpisodeRenderPolicy.filter(
      episodes: enrichedLine1S2.episodes,
      availableSeasons: state.tmdb.availableSeasons,
      selectedSeason: 2,
      seasonOf: _seasonOf,
    );
    expect(s2Rendered.length, 10, reason: 'S2 应渲染 10 项，实际 ${s2Rendered.length}');
    evidence(
      's2-selected=${state.tmdb.selectedSeason} '
      'tmdb-episodes=${state.tmdb.episodes.length} rendered=${s2Rendered.length}',
    );

    // 7) 线路二 S2 只有 8 集，TMDB 季 2 有 10 集 → 渲染 8 项，不得出现第 9/10 项。
    //
    // 先解析线路二（季度解析是**线路级**的，`02` §2.2），再断言渲染。
    state.tmdb.selectLine('线路二');
    await tester.pump();
    await state.reloadTmdb();
    await drainRealIo(
      tester,
      until: () =>
          state.tmdb.sourceLine?.sourceFlag == '线路二' &&
          state.tmdb.selectedSeason == 2,
    );
    final line2 = state.tmdb.lineByFlag('线路二')!;
    expect(line2.episodes.length, 8, reason: '线路二 S2 不是 8 集');
    await drainRealIo(
      tester,
      until: () => state.tmdb.applyEpisodesToLine(line2).appliedCount > 0,
    );
    final enrichedLine2 = state.tmdb.applyEpisodesToLine(line2).line;
    expect(
      enrichedLine2.episodes.length,
      8,
      reason: '线路二被补集到 ${enrichedLine2.episodes.length} 项（不得补集）',
    );
    final line2Rendered = TmdbEpisodeRenderPolicy.filter(
      episodes: enrichedLine2.episodes,
      availableSeasons: state.tmdb.availableSeasons,
      selectedSeason: 2,
      seasonOf: _seasonOf,
    );
    expect(
      line2Rendered.length,
      8,
      reason: '线路二渲染 ${line2Rendered.length} 项（应为 8）',
    );
    // TMDB 季 2 有 10 集；线路只有 8 集 → 第 9/10 集的 TMDB 标题不得出现在渲染列表里。
    final tmdbEp9 = state.tmdb.episodes.firstWhere((e) => e.number == 9);
    final tmdbEp10 = state.tmdb.episodes.firstWhere((e) => e.number == 10);
    final renderedTitles = line2Rendered
        .map((e) => e.extra['display_name'])
        .whereType<String>()
        .toSet();
    expect(
      renderedTitles.contains(tmdbEp9.displayTitle) ||
          renderedTitles.contains(tmdbEp10.displayTitle),
      isFalse,
      reason: '线路二出现了 TMDB 第 9/10 集的标题（不得补集）',
    );
    evidence(
      'line2-source=8 rendered=8 tmdb-s2=10 extra-episodes=0',
    );

    // 8) 渲染层断言：详情页上的集按钮数量等于线路二集数（不补集）。
    await tester.pump();
    final buttons = find.byWidgetPredicate(
      (widget) =>
          widget is OutlinedButton &&
          widget.key is ValueKey<String> &&
          (widget.key! as ValueKey<String>).value.startsWith('episode-线路二-'),
    );
    expect(
      buttons.evaluate().length,
      8,
      reason: '线路二渲染了 ${buttons.evaluate().length} 个集按钮（应为 8）',
    );
    evidence('line2-buttons=8');
  });
}

/// 剧集所在季度（`-1` 未分类）。
int _seasonOf(VodEpisode episode) {
  final raw = episode.extra['tmdb_season_number'];
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  return sourceSeasonNumber(episode.name);
}
