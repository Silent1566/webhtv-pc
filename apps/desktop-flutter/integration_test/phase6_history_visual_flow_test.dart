/// Phase 6 · 历史页视觉证据（`docs/phase6/design/05` §6）。
///
/// 产出四张 PNG（真实光栅化，不是 widget 树的重描述）：
///
/// | 文件 | 内容 | 视口 |
/// | --- | --- | --- |
/// | `docs/phase6/evidence/history-cards.png` | 卡片网格 | 1440×900 |
/// | `docs/phase6/evidence/history-cards-r235x1.png` | 列数自适应 | 2.35:1 |
/// | `docs/phase6/evidence/history-delete-mode.png` | 删除态 | 1440×900 |
/// | `docs/phase6/evidence/history-multi-select.png` | 多选态 | 1440×900 |
///
/// ## 为什么必须显式套 `buildAppTheme`
///
/// 本仓库既有集成测试（含 `tmdb_detail_visual_flow_test.dart`）一律用裸
/// `MaterialApp` pump 页面、**不传 `theme:`**，拍出来的是 Flutter 默认亮色主题，
/// 不是线上观感（`docs/phase4/evidence/tmdb-detail-header.png` 是白底、
/// 而应用其实强制暗色，就是这个原因）。用那种截图复核本次改动等于没复核。
/// 这里显式套 `buildAppTheme(Brightness.dark)`。
///
/// ## 为什么不需要 fixture 服务与网络
///
/// 历史行直接种进真实 SQLite（`upsertHistory`），海报地址指向不可达主机
/// ——`PosterImage` 于是渲染成占位块，这**诚实反映"图还没到"的状态**；
/// 而本次要复核的层级、间距、列数、遮罩、复选框都是真实的。
/// 站点配置用**内联 JSON**（不联网），因此不需要
/// `python tools/fixture_server/server.py`。
///
/// ## 为什么要注入假 HTTP client
///
/// `HistoryPage.initState` 会 fire `_repairMissingPosters()`，它按
/// `siteService` 拉详情补海报。真实 socket I/O 在集成测试里虽可行，
/// 但会让"拍图"这件事依赖网络时序；本文件只关心渲染结果，故注入一个
/// 一律抛错的 client，让补图安静失败（不影响网格渲染）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/core/episode_range.dart';
import 'package:webhtv_pc/core/tmdb_detail_model.dart';
import 'package:webhtv_pc/ui/app.dart';
import 'package:webhtv_pc/ui/tmdb_detail_view.dart';
import 'package:webhtv_pc/ui/theme.dart';
import 'package:webhtv_pc/ui/tmdb_widgets.dart';

void evidence(String message) =>
    debugPrint('PHASE6-EVIDENCE history-visual $message');

/// 从当前目录向上找仓库根（以 `docs/phase6` 存在为判据）。
Directory repoRootOf(Directory start) {
  var current = start;
  for (var hop = 0; hop < 6; hop++) {
    if (Directory('${current.path}/docs/phase6').existsSync()) return current;
    final parent = current.parent;
    if (parent.path == current.path) break;
    current = parent;
  }
  return start;
}

/// 把当前整窗渲染结果写成 PNG。
Future<void> capture(
  WidgetTester tester, {
  required String relativePath,
}) async {
  final boundary = find.byType(RepaintBoundary);
  if (boundary.evaluate().isEmpty) {
    evidence('screenshot-skip reason=no-repaint-boundary path=$relativePath');
    return;
  }
  final object = boundary.evaluate().first.renderObject;
  if (object is! RenderRepaintBoundary) {
    evidence('screenshot-skip reason=not-repaint-boundary path=$relativePath');
    return;
  }
  final image = await object.toImage(pixelRatio: 1.0);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  if (bytes == null) {
    evidence('screenshot-skip reason=encode-failed path=$relativePath');
    return;
  }
  final repoRoot = repoRootOf(Directory.current);
  final output = File('${repoRoot.path}/$relativePath');
  output.parent.createSync(recursive: true);
  output.writeAsBytesSync(bytes.buffer.asUint8List());
  evidence(
    'screenshot path=$relativePath bytes=${bytes.lengthInBytes} '
    'size=${image.width}x${image.height}',
  );
}

/// 一律拒绝的站点 client（见文件头注释）。
class _NoSiteNetwork extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    throw StateError('视觉证据用例不发站点请求：${request.url}');
  }
}

/// 种一条历史。`vodId`/`episodeId` 必须随 `id` 变化，否则三次 upsert 会
/// 因唯一键 `(site_key, vod_id, flag, episode_id)` 塌成同一行。
void seedHistory(
  AppState state, {
  required int id,
  required String vodName,
  required String episodeName,
  int positionMs = 30000,
  int durationMs = 100000,
  int? updatedAt,
}) {
  state.database!.upsertHistory(
    siteKey: 'site-a',
    vodId: 'v$id',
    vodName: vodName,
    flag: '线路一',
    episodeName: episodeName,
    episodeId: 'http://x/e$id',
    positionMs: positionMs,
    durationMs: durationMs,
    updatedAt: updatedAt,
  );
}

/// 建一个已导入配置、已种入历史的状态。
Future<AppState> _bootState(Directory temp, {required bool seed}) async {
  final paths = AppPaths.resolve(
    overrides: {
      'config': '${temp.path}/webhtv-pc',
      'data': '${temp.path}/webhtv-pc',
      'cache': '${temp.path}/webhtv-pc/cache',
      'state': '${temp.path}/webhtv-pc/logs',
    },
  );
  final state = AppState(
    paths: paths,
    log: LogService(),
    httpClient: _NoSiteNetwork(),
  );
  await state.bootstrap();
  // 预先写下边界确认标记：否则首次启动的边界提示会盖住窗口底部。
  File(
    '${paths.configDir}${Platform.pathSeparator}usage-boundary-accepted',
  ).writeAsStringSync(DateTime.now().toIso8601String());

  final imported = await state.importConfig(
    jsonEncode({
      'name': '历史页视觉证据 fixture',
      'sites': [
        {
          'key': 'site-a',
          'name': '甲站',
          'type': 1,
          'api': 'http://127.0.0.1:9/vod/api?key=site-a',
        },
      ],
    }),
  );
  if (!imported) {
    throw StateError('fixture 配置导入失败：${state.lastError?.logLine}');
  }

  if (seed) {
    // 12 条：足够铺满 1440×900 的多行网格，也足够看出列数自适应。
    const names = [
      '漫长的季节', '繁花', '三体', '狂飙', '隐秘的角落', '沉默的真相',
      '琅琊榜', '白夜追凶', '山海情', '觉醒年代', '人世间', '县委大院',
    ];
    for (var i = 0; i < names.length; i++) {
      seedHistory(
        state,
        id: i + 1,
        vodName: names[i],
        episodeName: '第${i + 1}集',
        // 进度刻意错开：0% / 中段 / 已看完三种角标都要出现。
        positionMs: i % 3 == 0 ? 0 : (i % 3 == 1 ? 32000 : 100000),
        durationMs: 100000,
        updatedAt: 2000000 - i * 1000,
      );
    }
  }
  return state;
}

/// 把窗口设成给定逻辑尺寸。
void useViewport(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

/// 打开真实壳层并切到「最近观看」。
Future<void> openHistory(WidgetTester tester, AppState state) async {
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(Brightness.dark),
      home: AppShell(state: state, startup: const StartupArguments()),
    ),
  );
  await tester.pump(const Duration(milliseconds: 120));
  // 首次启动的边界提示（若仍在）。
  final accept = find.text('我已了解并同意');
  if (accept.evaluate().isNotEmpty) {
    await tester.tap(accept);
    await tester.pumpAndSettle();
  }
  await tester.tap(find.text('最近观看'));
  await tester.pumpAndSettle();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('历史页卡片网格（dark，1440x900）', (tester) async {
    final temp = Directory.systemTemp.createTempSync('webhtv-p6-cards');
    final state = await _bootState(temp, seed: true);
    addTearDown(() {
      state.dispose();
      try {
        temp.deleteSync(recursive: true);
      } catch (_) {}
    });

    useViewport(tester, const Size(1440, 900));
    await openHistory(tester, state);

    // 前置：网格真的渲染出来了，且 12 条都在。
    expect(find.byKey(const ValueKey('history-grid')), findsOneWidget);
    expect(state.recentHistory().length, 12);
    expect(find.text('漫长的季节'), findsOneWidget);

    await capture(
      tester,
      relativePath: 'docs/phase6/evidence/history-cards.png',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('历史页列数自适应（dark，2.35:1）', (tester) async {
    final temp = Directory.systemTemp.createTempSync('webhtv-p6-wide');
    final state = await _bootState(temp, seed: true);
    addTearDown(() {
      state.dispose();
      try {
        temp.deleteSync(recursive: true);
      } catch (_) {}
    });

    // 2.35:1 超宽：列数必须比 1440×900 更多（证明不是写死的列数）。
    useViewport(tester, const Size(1800, 766));
    await openHistory(tester, state);

    final grid = tester.widget<GridView>(
      find.byKey(const ValueKey('history-grid')),
    );
    final columns =
        (grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
            .crossAxisCount;
    evidence('wide-viewport columns=$columns');
    expect(
      columns,
      greaterThan(8),
      reason: '1800 宽必须铺出比 1440 宽（8 列）更多的列',
    );

    await capture(
      tester,
      relativePath: 'docs/phase6/evidence/history-cards-r235x1.png',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('历史页删除态（dark，1440x900）', (tester) async {
    final temp = Directory.systemTemp.createTempSync('webhtv-p6-delete');
    final state = await _bootState(temp, seed: true);
    addTearDown(() {
      state.dispose();
      try {
        temp.deleteSync(recursive: true);
      } catch (_) {}
    });

    useViewport(tester, const Size(1440, 900));
    await openHistory(tester, state);

    // 长按第一张卡进入删除态。
    await tester.longPress(find.byKey(const ValueKey('history-row-1')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('history-delete-done')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('history-delete-overlay-1')),
      findsOneWidget,
    );

    await capture(
      tester,
      relativePath: 'docs/phase6/evidence/history-delete-mode.png',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('历史页多选态（dark，1440x900）', (tester) async {
    final temp = Directory.systemTemp.createTempSync('webhtv-p6-multi');
    final state = await _bootState(temp, seed: true);
    addTearDown(() {
      state.dispose();
      try {
        temp.deleteSync(recursive: true);
      } catch (_) {}
    });

    useViewport(tester, const Size(1440, 900));
    await openHistory(tester, state);

    await tester.tap(find.byKey(const ValueKey('history-bulk-delete')));
    await tester.pumpAndSettle();
    // 勾两条，让「已选 2 条」与两个选中态复选框都进图。
    await tester.tap(find.byKey(const ValueKey('history-row-1')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('history-row-2')));
    await tester.pumpAndSettle();

    expect(find.text('已选 2 条'), findsOneWidget);
    expect(find.byKey(const ValueKey('history-checkbox-1')), findsOneWidget);

    await capture(
      tester,
      relativePath: 'docs/phase6/evidence/history-multi-select.png',
    );
    expect(tester.takeException(), isNull);
  });
  // -------------------------------------------------------------------------
  // plans/03：季度按钮常驻 + 选集区间条（`docs/phase6/design/03` §2、§4.3）
  // -------------------------------------------------------------------------

  /// 一张季集卡片（`TmdbEpisodeCard` 的构造**不是** `const`）。
  TmdbEpisodeCard epCard(int number) =>
      TmdbEpisodeCard(number: number, title: '第$number集');

  testWidgets('季度按钮常驻（dark，1440x900）', (tester) async {
    final temp = Directory.systemTemp.createTempSync('webhtv-p6-season');
    final state = await _bootState(temp, seed: false);
    addTearDown(() {
      state.dispose();
      try {
        temp.deleteSync(recursive: true);
      } catch (_) {}
    });

    // 单季场景：按钮仍常驻（这是改绑的唯一入口）。
    //
    // 直接驱动 TmdbState 到「已匹配单季」需要真实 TMDB 服务；本 harness
    // 不发外网，因此用 `SeasonChipStrip` 直接渲染同一行形态并截图。
    // **诚实标注**：这张图证明的是**组件形态**（按钮 + chip 条），
    // 不是线上数据流；数据流的正确性由 `phase6_season_controls_test` 锁定。
    evidence('season-button 说明=组件形态截图，数据流由 L2 锁定');

    useViewport(tester, const Size(1440, 900));
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(Brightness.dark),
        home: Scaffold(
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 24),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Text('单季：季度按钮常驻'),
              ),
              SizedBox(
                height: tmdbSeasonSelectorHeight,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () {},
                      iconAlignment: IconAlignment.end,
                      icon: const Icon(Icons.expand_more, size: 18),
                      label: const Text('第 1 季'),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Text('多季：按钮在左，chip 条在右'),
              ),
              SeasonChipStrip(
                seasons: const [1, 2, 3, 0],
                selectedSeason: 2,
                selectableSeasons: const [1, 2, 3, 0],
                onChanged: (_) {},
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('第 1 季'), findsWidgets);
    expect(
      find.byKey(const ValueKey('tmdb-season-switcher')),
      findsOneWidget,
    );
    await capture(
      tester,
      relativePath: 'docs/phase6/evidence/season-button.png',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('选集区间条（dark，1440x900）', (tester) async {
    useViewport(tester, const Size(1440, 900));
    // 400 集：阶梯 50（被 cardPageMaxSize 封顶）→ 8 个区间，
    // 正好演示「每页上限 50 + 阶梯分组」（`design/03` §4.1）。
    final ranges = EpisodeRangePolicy.build(400, 120, false);
    expect(ranges.length, 8, reason: '400 集必须是 8 个区间');

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(Brightness.dark),
        home: Scaffold(
          body: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 24),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    '选集 · 线路一 · ${ranges.length} 个区间（400 集）',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                const SizedBox(height: 8),
                TmdbEpisodeStrip(
                  keyPrefix: 'tmdb-episode-card-线路一',
                  cards: [for (var i = 1; i <= 400; i++) epCard(i)],
                  ranges: ranges,
                  rangeIndex: 2,
                  onRangeChanged: (_) {},
                  // 网格模式：`shrinkWrap` + 不可滚会构建全部子项，
                  // 截图里能看到一整页的 50 张卡（横向条只挂载 ~6 张）。
                  gridMode: true,
                  cardWidth: 150,
                  height: 170,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('tmdb-episode-card-线路一-range-strip')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('tmdb-episode-card-线路一-range-2')),
      findsOneWidget,
    );
    evidence('episode-ranges=${ranges.length} labels=${ranges.map((r) => r.label).join(",")}');
    await capture(
      tester,
      relativePath: 'docs/phase6/evidence/episode-ranges.png',
    );
    expect(tester.takeException(), isNull);
  });
}
