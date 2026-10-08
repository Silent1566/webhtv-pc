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

/// 横向滚动到底，收集某条线路**全部**剧集卡片的集号。
///
/// 为什么不能直接数当前渲染的卡片：卡片条是懒加载的横向 `ListView`，只构建
/// 视口内的项（实测 8 集线路只建出 6 张）。直接数会得到「少渲染」的假失败。
/// 这里逐屏滚动并累计集号，既覆盖全部卡片，又顺带证明「卡片能滚到最后一集」。
Future<Set<int>> collectEpisodeCardNumbers(
  WidgetTester tester,
  String flagKey,
) async {
  final numbers = <int>{};
  final strip = find.byKey(ValueKey('tmdb-episode-card-$flagKey-strip'));
  expect(strip, findsOneWidget, reason: '未找到线路 $flagKey 的剧集卡片条');
  final scrollable = find.descendant(
    of: strip,
    matching: find.byType(Scrollable),
  );
  for (var pass = 0; pass < 12; pass++) {
    for (final element in find.byWidgetPredicate(
      (widget) =>
          widget is OutlinedButton &&
          widget.key is ValueKey<String> &&
          (widget.key! as ValueKey<String>).value.startsWith(
            'tmdb-episode-card-$flagKey-',
          ),
    ).evaluate()) {
      final key = ((element.widget as OutlinedButton).key! as ValueKey<String>)
          .value;
      final suffix = key.substring('tmdb-episode-card-$flagKey-'.length);
      final index = int.tryParse(suffix);
      if (index != null) numbers.add(index);
    }
    if (scrollable.evaluate().isEmpty) break;
    await tester.drag(scrollable.first, const Offset(-400, 0));
    await tester.pump();
  }
  return numbers;
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
    //
    // 走**真实 UI 路径**：点季度条上的「第 2 季」。直接调 `selectSeason` 只会
    // 改状态层，页面不会重建、也不会重新拉取剧集（`selectSeason` 会清空
    // `_episodes`，`04` §4.3 第 3 步），后续断言就会基于过期数据。
    final season2Chip = find.byKey(const ValueKey('tmdb-season-2'));
    expect(season2Chip, findsOneWidget, reason: '详情页必须有第 2 季入口');
    await tester.tap(season2Chip);
    await tester.pump();
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
    // 走**真实 UI 路径**：点击线路条上的「线路二」（对齐上游 `@id/flag`）。
    // 这里必须点 UI 而不是直接调状态层，否则锁不住「点击线路切换集数卡片」
    // 这条用户可见行为（2026-10-08 用户要求：点击切换线路显示对应的集数卡片）。
    await tester.pump();
    final line2Chip = find.byKey(const ValueKey('tmdb-line-线路二'));
    expect(line2Chip, findsOneWidget, reason: '详情页必须有线路二的选择入口');
    await tester.tap(line2Chip);
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

    // 7.5) 点击线路后，UI 上的剧集卡片必须**只剩线路二那 8 张**。
    //
    // 这是「点击切换线路显示对应的集数卡片」的核心断言：线路一有 22 集，
    // 若切换无效，页面上仍会渲染线路一的卡片。
    await tester.pump();
    expect(
      find.byKey(const ValueKey('tmdb-episode-card-线路一-0')),
      findsNothing,
      reason: '切换到线路二后，线路一的剧集卡片必须消失',
    );
    expect(
      find.byKey(const ValueKey('tmdb-episode-card-线路二-0')),
      findsOneWidget,
      reason: '切换到线路二后，必须渲染线路二的剧集卡片',
    );
    // 线路条上的集数也必须反映当前季度（S2 → 8 集）。
    expect(
      find.textContaining('线路二（8 集）'),
      findsOneWidget,
      reason: '线路条必须显示线路二在当前季度下的集数',
    );
    evidence('line-switch-ui active=线路二 cards=线路二 only');

    // 8) 渲染层断言：详情页上的剧集卡片数量等于线路二集数（不补集）。
    //
    // 选集入口自 2026-10-08 起只有剧集卡片（用户反馈：卡片与文字按钮二者取一），
    // 因此这里改为数卡片；卡片本身就是 `OutlinedButton`，计数口径不变。
    await tester.pump();
    final cardIndexes = await collectEpisodeCardNumbers(tester, '线路二');
    expect(
      cardIndexes.length,
      8,
      reason: '线路二渲染了 ${cardIndexes.length} 张剧集卡片（应为 8）',
    );
    expect(
      cardIndexes,
      {0, 1, 2, 3, 4, 5, 6, 7},
      reason: '卡片下标必须连续覆盖 0..7（不丢集）',
    );
    // 反向断言：不得同时存在文字版集按钮（否则就是「两套控件」回归）。
    final textButtons = find.byWidgetPredicate(
      (widget) =>
          widget is OutlinedButton &&
          widget.key is ValueKey<String> &&
          (widget.key! as ValueKey<String>).value.startsWith('episode-'),
    );
    expect(
      textButtons.evaluate(),
      isEmpty,
      reason: '有剧集卡片时不得再渲染文字版集按钮（二者取其一）',
    );
    evidence('line2-cards=8 text-episode-buttons=0');
  });
}

/// 剧集所在季度（`-1` 未分类）。
int _seasonOf(VodEpisode episode) {
  final raw = episode.extra['tmdb_season_number'];
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  return sourceSeasonNumber(episode.name);
}
