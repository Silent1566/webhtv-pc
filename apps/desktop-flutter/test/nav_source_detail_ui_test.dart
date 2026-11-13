/// 导航源详情页的 UI 接线门禁。
///
/// 需求方向（用户决策，2026-10）：导航源**不做任何站源 ↔ TMDB 匹配对齐**，卡片
/// 100% 由 TMDB 数据生成，站源的集名/集数/顺序一律丢弃；所有卡片点击都弹「换源」
/// 说明而不是播放；导航源进来不显示线路条（也没有可显示的播放线路）；换源并入
/// 播放源之后页面回到既有行为。
///
/// 本文件只钉**接线**：导航源判据、卡片数据来源（TMDB 全集，不是站源集数）、
/// key 前缀的命名空间隔离、换源提示框的两个动作、以及视图模式偏好记忆。
/// 底层能力（`TmdbState.ensureAllSeasonEpisodes` / `TmdbEpisodeCards.fromMetadata`）
/// 各自已有门禁。
///
/// 为什么要用 `_TestAppState` 而不是真 `AppState`：真实 `AppState.tmdb` 是惰性
/// 构造的内部实例，`testWidgets` 的 fake-async 区推不动真实 HTTP（框架把请求固定
/// 返回 400），拿不到「已匹配 + 已聚合」的前提。这里按既有的测试注入习惯只替换
/// 四处：TMDB 状态、本页站点、播放解析、全局搜索（换源浮层打开时它会自动搜一次，
/// 真搜索会在 fake-async 区里留下悬空计时器）。
///
/// 一条纪律：`testWidgets` 里**不要 await 真实磁盘 I/O**（偏好落盘）——fake-async
/// 区里它永远不会完成，用例会以超时收场。偏好写入一律在 `setUp`（真实 async 区）里做。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/tmdb_config.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/site_service.dart';
import 'package:webhtv_pc/services/tmdb_enrichment_service.dart';
import 'package:webhtv_pc/services/tmdb_identity_service.dart';
import 'package:webhtv_pc/services/tmdb_season_service.dart';
import 'package:webhtv_pc/services/tmdb_service.dart';
import 'package:webhtv_pc/services/ui_preferences_store.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/state/search_state.dart';
import 'package:webhtv_pc/state/tmdb_state.dart';
import 'package:webhtv_pc/ui/browse_pages.dart';
import 'package:webhtv_pc/ui/toast.dart';

// ---------------------------------------------------------------------------
// fake HTTP（与 `tmdb_season_aggregate_test` 同一套基础设施）
// ---------------------------------------------------------------------------

class _FakeClient extends http.BaseClient {
  final List<(String, Object?)> routes = [];

  void route(String suffix, Object? body) => routes.add((suffix, body));

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    for (final (suffix, body) in routes) {
      if (request.url.path.endsWith(suffix)) {
        final text = body is String ? body : jsonEncode(body);
        return http.StreamedResponse(
          Stream<List<int>>.value(utf8.encode(text)),
          200,
        );
      }
    }
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode('{"status_code":404}')),
      404,
    );
  }
}

/// 两季（S1 3 集 / S2 2 集）的 TMDB 响应：全集 5 集。
_FakeClient _tmdbClient() => _FakeClient()
  ..route('/search/multi', {
    'results': [
      {
        'id': 1399,
        'media_type': 'tv',
        'name': '导航剧',
        'first_air_date': '2024-01-01',
      },
    ],
  })
  ..route('/tv/1399', {
    'id': 1399,
    'name': '导航剧',
    'seasons': [
      {'season_number': 1, 'episode_count': 3},
      {'season_number': 2, 'episode_count': 2},
    ],
  })
  ..route('/season/1', {
    'season_number': 1,
    'episodes': [
      for (var i = 1; i <= 3; i++)
        {'episode_number': i, 'name': 'S1E$i', 'season_number': 1},
    ],
  })
  ..route('/season/2', {
    'season_number': 2,
    'episodes': [
      for (var i = 1; i <= 2; i++)
        {'episode_number': i, 'name': 'S2E$i', 'season_number': 2},
    ],
  })
  ..route('/videos', {'results': []});

/// 搜不到任何作品：TMDB「未匹配」的前提。
_FakeClient _unmatchedClient() => _FakeClient()
  ..route('/search/multi', {'results': []})
  ..route('/videos', {'results': []});

TmdbConfig _ready() => const TmdbConfig(apiKey: 'k');

TmdbState _tmdbState({required http.Client client}) {
  final service = TmdbService(config: _ready, client: client);
  return TmdbState(
    config: _ready,
    service: service,
    identityService: TmdbIdentityService(
      config: _ready,
      service: service,
      store: InMemoryTmdbMatchStore(),
    ),
    seasonService: TmdbSeasonService(store: InMemoryTmdbSeasonStore()),
    enrichmentService: TmdbEnrichmentService(service: service, config: _ready),
  );
}

/// 只替换 TMDB 状态、本页站点、播放解析、全局搜索与换源解析的 `AppState`。
class _TestAppState extends AppState {
  _TestAppState({
    required AppPaths paths,
    required LogService log,
    required TmdbState tmdb,
    required Site? site,
  }) : _fakeTmdb = tmdb,
       _fakeSite = site,
       super(paths: paths, log: log);

  /// 换源浮层搜索到的候选（`null` = 搜不到任何来源）。
  ///
  /// 换源提交链路要真的「搜到候选 → 解析 → 并入」，这三步都发生在浮层内部；
  /// 浮层自己不发网络请求，它读 [activeSearch] 快照并回调 `onProbe`，所以注入点
  /// 只能落在这两处状态层入口上。
  MultiSiteSearchOutcome? _searchOutcome;
  List<VodPlayLine> _probeLines = const [];

  /// 装入「能搜到一条候选、并能解析出 [lines]」的换源环境。
  void installSwap({
    required String siteKey,
    required String siteName,
    required String vodId,
    required List<VodPlayLine> lines,
  }) {
    _probeLines = lines;
    final outcome = MultiSiteSearchOutcome(
      runId: 1,
      keyword: '导航剧',
      results: [
        SiteSearchEntry(
          siteKey: siteKey,
          siteName: siteName,
          result: SiteResult(
            list: [Vod(vodId: vodId, vodName: '导航剧')],
          ),
        ),
      ],
    )..finished = true;
    _searchOutcome = outcome;
  }

  /// 浮层读的是这个快照（不是 `searchAll` 的返回值）。
  @override
  MultiSiteSearchOutcome? get activeSearch => _searchOutcome ?? super.activeSearch;

  @override
  Future<List<VodPlayLine>> swapProbe({
    required String siteKey,
    required String vodId,
    String vodName = '',
  }) async => _probeLines;

  /// 并入后的 TMDB 重载走不到真实网络（本用例只关心「线路条是否恢复」，
  /// 那由 `_navSourceMode` 判据决定，与 TMDB 元数据刷新无关）；记录调用即可。
  final List<String> reloads = [];

  @override
  Future<void> reloadTmdb() async => reloads.add('reload');

  final TmdbState _fakeTmdb;
  final Site? _fakeSite;

  /// 被请求播放的 `episode.url` 序列（只记录，不真的解析/开播放器）。
  final List<String> playedTargets = [];

  /// 换源浮层自动发起的那次全局搜索的关键词（空 = 没搜过）。
  ///
  /// 它是「换源入口真的被调用」的观测点：导航源卡片的点击链是
  /// 「弹说明框 → 换源 → `_openSourceSwap` → 浮层 → 搜索」。
  final List<String> searchedKeywords = [];

  @override
  TmdbState get tmdb => _fakeTmdb;

  @override
  Site? get selectedSite => _fakeSite;

  /// 抛「用户主动中断」而不是返回 `null`：`_play` 对 `null` 会弹换源确认框，
  /// 对 `siteCancelled` 只闪一条通知，用例因此不必处理未关闭的对话框。
  @override
  Future<PlaybackDecision?> resolvePlayback({
    required String episodeTarget,
    String? flag,
    String? vodId,
    int? qualityIndex,
    bool Function()? isCurrent,
    Site? siteOverride,
    SiteService? serviceOverride,
    String? preferredParseName,
  }) async {
    playedTargets.add(episodeTarget);
    throw AppError(AppErrorKind.siteCancelled, '测试：不真的解析播放地址');
  }

  /// 换源浮层打开就会搜一次；真搜索会在 fake-async 区里留下悬空计时器。
  ///
  /// 这里只记关键词并把预先装好的候选推成当前快照（浮层读 [activeSearch]），
  /// 于是「勾选 → 解析 → 并入」走的仍是浮层自己的真实接线。
  @override
  Future<MultiSiteSearchOutcome> searchAll(
    String keyword, {
    String? siteKey,
    String? group,
    int? maxConcurrency,
    Duration timeout = const Duration(seconds: 20),
    bool quick = false,
  }) async {
    searchedKeywords.add(keyword);
    final installed = _searchOutcome;
    if (installed != null) {
      notifyListeners();
      return installed;
    }
    final outcome = MultiSiteSearchOutcome(
      runId: 1,
      keyword: keyword,
      results: const [],
    )..finished = true;
    return outcome;
  }
}

// ---------------------------------------------------------------------------
// 夹具
// ---------------------------------------------------------------------------

/// `indexs == 1` 才是导航源；普通站点不带这个字段。
Site _site({required bool nav}) => Site(
  key: 'nav-site',
  name: nav ? '导航站' : '普通站',
  type: 1,
  api: 'http://nav.example/api.php/provide/vod',
  indexs: nav ? 1 : null,
);

/// 导航源的站源线路：只有 2 集，且季集信息与 TMDB **不同构**。
///
/// 卡片必须来自 TMDB 全集（5 张），不能是这 2 集——站源集数在导航源下直接丢弃。
Vod _navVod() => Vod(
  vodId: 'nav-1',
  vodName: '导航剧',
  vodPlayFrom: '线路一',
  vodPlayUrl: 'S01E03\$http://nav.example/e0#S02E02\$http://nav.example/e1',
);

/// 普通站点的线路：集名不带季度信号，季度过滤不会缩减它（2 集就是 2 张卡）。
Vod _plainVod() => Vod(
  vodId: 'plain-1',
  vodName: '普通剧',
  vodPlayFrom: '线路一',
  vodPlayUrl: '第1集\$http://plain.example/e0#第2集\$http://plain.example/e1',
);

/// 导航源卡片的 key 前缀（独立命名空间，与既有两条路径彻底隔离）。
const _navCardPrefix = 'tmdb-episode-card-nav-nav-1';

Finder _episodeCards(String prefix) => find.byWidgetPredicate(
  (widget) =>
      widget is OutlinedButton &&
      widget.key is ValueKey<String> &&
      (widget.key! as ValueKey<String>).value.startsWith(prefix),
);

/// 让 [finder] 命中**且整块落在视口内**。
///
/// 只「命中」不够：剧集区在满屏 hero 之下，卡片建出来了坐标也可能仍在视口外，
/// 此时 `tap` 会静默命中不到任何东西（`warnIfMissed` 只打一条警告），用例会
/// 变成空洞的。
Future<void> _revealInViewport(
  WidgetTester tester,
  Finder finder, {
  int attempts = 80,
}) async {
  final viewport = tester.view.physicalSize / tester.view.devicePixelRatio;
  for (var attempt = 0; attempt < attempts; attempt++) {
    if (finder.evaluate().isNotEmpty) {
      final rect = tester.getRect(finder.first);
      if (rect.top >= 0 && rect.bottom <= viewport.height) return;
    }
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -200));
    await tester.pump();
  }
}

void main() {
  late Directory tempDir;
  late Directory listTempDir;
  late _TestAppState navState;
  late _TestAppState plainState;
  late _TestAppState unmatchedState;
  late _TestAppState listState;
  late TmdbState navTmdb;
  late TmdbState plainTmdb;
  late TmdbState unmatchedTmdb;

  setUp(() async {
    // `toastCenter` 是进程级单例：上一条用例留下的通知会漏进这一条。
    dismissAllToasts();
    tempDir = await Directory.systemTemp.createTemp('webhtv-nav-detail');
    listTempDir = await Directory.systemTemp.createTemp('webhtv-nav-detail-list');
    final paths = AppPaths.resolve(
      overrides: {
        'config': '${tempDir.path}/webhtv-pc',
        'data': '${tempDir.path}/webhtv-pc',
        'cache': '${tempDir.path}/webhtv-pc/cache',
        'state': '${tempDir.path}/webhtv-pc/logs',
      },
    );
    // 偏好存盘是**共享的** `settings.json`：视图模式用例单独占一份工作目录，
    // 免得「list」这条偏好渗进其它用例的渲染模式。
    final listPaths = AppPaths.resolve(
      overrides: {
        'config': '${listTempDir.path}/webhtv-pc',
        'data': '${listTempDir.path}/webhtv-pc',
        'cache': '${listTempDir.path}/webhtv-pc/cache',
        'state': '${listTempDir.path}/webhtv-pc/logs',
      },
    );
    navTmdb = _tmdbState(client: _tmdbClient());
    plainTmdb = _tmdbState(client: _tmdbClient());
    unmatchedTmdb = _tmdbState(client: _unmatchedClient());
    navState = _TestAppState(
      paths: paths,
      log: LogService(),
      tmdb: navTmdb,
      site: _site(nav: true),
    );
    plainState = _TestAppState(
      paths: paths,
      log: LogService(),
      tmdb: plainTmdb,
      site: _site(nav: false),
    );
    unmatchedState = _TestAppState(
      paths: paths,
      log: LogService(),
      tmdb: unmatchedTmdb,
      site: _site(nav: true),
    );
    listState = _TestAppState(
      paths: listPaths,
      log: LogService(),
      tmdb: _tmdbState(client: _tmdbClient()),
      site: _site(nav: true),
    );
    await navState.bootstrap();
    await plainState.bootstrap();
    await unmatchedState.bootstrap();
    await listState.bootstrap();
    // 真实 async 区里写盘：`testWidgets` 内 await 它会永远不返回。
    await listState.setEpisodeViewMode(UiEpisodeViewMode.list);
  });

  tearDown(() async {
    navState.dispose();
    plainState.dispose();
    unmatchedState.dispose();
    listState.dispose();
    for (final dir in [tempDir, listTempDir]) {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    }
  });

  /// 把「已匹配 + 详情 + 选中季元数据」装进注入的 TMDB 状态。
  Future<void> loadTmdb(
    TmdbState tmdb,
    Vod vod, {
    required bool nav,
  }) async {
    await tmdb.loadForVod(
      vod,
      siteKey: 'nav-site',
      siteName: nav ? '导航站' : '普通站',
      navSource: nav,
    );
  }

  Future<void> pumpDetail(WidgetTester tester, AppState state, Vod vod) async {
    tester.view.physicalSize = const Size(1400, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MaterialApp(home: DetailPage(state: state, vod: vod)),
    );
    await tester.pump();
  }

  testWidgets('导航源 + TMDB 已匹配 → 卡片数等于 TMDB 全部季的全部集数', (tester) async {
    await loadTmdb(navTmdb, _navVod(), nav: true);
    expect(
      navTmdb.episodesBySeason,
      isEmpty,
      reason: '前置：聚合是显式触发的补充加载，loadForVod 不带它',
    );

    await pumpDetail(tester, navState, _navVod());
    // 页面必须自己触发一次 `ensureAllSeasonEpisodes`，拉回来后重建才出卡
    // （底层没有自动调用）。
    for (var i = 0; i < 60 && navTmdb.episodesBySeason.isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(navTmdb.episodesBySeason.keys.toSet(), {1, 2}, reason: 'UI 必须显式触发按季聚合');

    final cards = _episodeCards(_navCardPrefix);
    await _revealInViewport(tester, cards);
    expect(cards, findsNWidgets(5), reason: 'TMDB 全集 S1(3)+S2(2)=5，不是站源的 2 集');
    expect(
      _episodeCards('tmdb-episode-card-线路一-'),
      findsNothing,
      reason: '导航源不得走「线路几集就出几张卡」的既有路径',
    );
  });

  testWidgets('导航源不渲染线路条（没有播放线路可言）', (tester) async {
    await loadTmdb(navTmdb, _navVod(), nav: true);
    await navTmdb.ensureAllSeasonEpisodes(generation: navTmdb.generation);
    await pumpDetail(tester, navState, _navVod());

    expect(
      find.byKey(const ValueKey('tmdb-line-selector')),
      findsNothing,
      reason: '导航源进来不显示线路条（用户决策 4）',
    );
    expect(
      find.byKey(const ValueKey('detail-clear-external')),
      findsNothing,
      reason: '没有外部线路，清空按钮也不该出现',
    );
    // 卡片仍然照常渲染：跳过线路条的代价不是跳过整个选集区。
    final cards = _episodeCards(_navCardPrefix);
    await _revealInViewport(tester, cards);
    expect(cards, findsNWidgets(5));
  });

  testWidgets('点任意一张卡片 → 弹出换源说明框，含「知道了」「换源」两个动作', (tester) async {
    await loadTmdb(navTmdb, _navVod(), nav: true);
    await navTmdb.ensureAllSeasonEpisodes(generation: navTmdb.generation);
    await pumpDetail(tester, navState, _navVod());

    // 第一张卡（站源根本没有 S1E1）也必须可点：导航源不做匹配，卡片一律可点。
    final first = find.byKey(const ValueKey('$_navCardPrefix-0'));
    await _revealInViewport(tester, first);
    expect(first, findsOneWidget);
    expect(
      tester.widget<OutlinedButton>(first).onPressed,
      isNotNull,
      reason: '所有卡片都可点（点击只是换源入口），不得置灰',
    );

    await tester.tap(first);
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(const ValueKey('nav-source-swap')), findsOneWidget);
    expect(find.byKey(const ValueKey('nav-source-swap-dismiss')), findsOneWidget);
    expect(find.byKey(const ValueKey('nav-source-swap-confirm')), findsOneWidget);
    expect(find.text('知道了'), findsWidgets);
    expect(find.text('换源'), findsWidgets);
  });

  testWidgets('点「知道了」→ 框关闭，不发生任何播放', (tester) async {
    await loadTmdb(navTmdb, _navVod(), nav: true);
    await navTmdb.ensureAllSeasonEpisodes(generation: navTmdb.generation);
    await pumpDetail(tester, navState, _navVod());

    final first = find.byKey(const ValueKey('$_navCardPrefix-0'));
    await _revealInViewport(tester, first);
    await tester.tap(first);
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.byKey(const ValueKey('nav-source-swap-dismiss')));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(const ValueKey('nav-source-swap')), findsNothing);
    expect(navState.playedTargets, isEmpty, reason: '导航源卡片不得直接播放');
    expect(
      find.byKey(const ValueKey('source-swap-sheet')),
      findsNothing,
      reason: '「知道了」只关闭说明框，不打开换源浮层',
    );
  });

  testWidgets('点「换源」→ 框关闭并打开换源浮层', (tester) async {
    await loadTmdb(navTmdb, _navVod(), nav: true);
    await navTmdb.ensureAllSeasonEpisodes(generation: navTmdb.generation);
    await pumpDetail(tester, navState, _navVod());

    final first = find.byKey(const ValueKey('$_navCardPrefix-0'));
    await _revealInViewport(tester, first);
    await tester.tap(first);
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.byKey(const ValueKey('nav-source-swap-confirm')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byKey(const ValueKey('nav-source-swap')), findsNothing);
    // 换源浮层出现 = `_openSourceSwap()` 真的被调用（说明框 → 换源入口的接线）。
    expect(find.byKey(const ValueKey('source-swap-sheet')), findsOneWidget);
    expect(
      navState.searchedKeywords,
      ['导航剧'],
      reason: '浮层用本页片名发起换源搜索',
    );
    expect(navState.playedTargets, isEmpty, reason: '换源不是播放');
  });

  testWidgets('导航源 + TMDB 未匹配 → 说明 + 换源按钮的空态，不出任何卡片', (tester) async {
    await loadTmdb(unmatchedTmdb, _navVod(), nav: true);
    expect(unmatchedTmdb.hasMatch, isFalse, reason: '前置：搜不到作品');
    await pumpDetail(tester, unmatchedState, _navVod());

    final swap = find.byKey(const ValueKey('nav-source-swap-empty'));
    await _revealInViewport(tester, swap);
    expect(swap, findsOneWidget);
    expect(find.textContaining('导航源'), findsWidgets);
    expect(
      _episodeCards(_navCardPrefix),
      findsNothing,
      reason: '未匹配时不回退渲染站源集卡片（用户决策 7）',
    );
    expect(
      _episodeCards('tmdb-episode-card-线路一-'),
      findsNothing,
      reason: '未匹配时也不得回退到既有线路卡片路径',
    );
  });

  testWidgets('普通站点（indexs != 1）→ 线路条与卡片数维持既有行为', (tester) async {
    await loadTmdb(plainTmdb, _plainVod(), nav: false);
    await pumpDetail(tester, plainState, _plainVod());

    final selector = find.byKey(const ValueKey('tmdb-line-selector'));
    await _revealInViewport(tester, selector);
    expect(selector, findsOneWidget, reason: '非导航源必须照常显示线路条');

    final cards = _episodeCards('tmdb-episode-card-线路一-');
    await _revealInViewport(tester, cards);
    expect(cards, findsNWidgets(2), reason: '站源 2 集就是 2 张卡：导航源路径不影响普通站点');
    expect(_episodeCards('tmdb-episode-card-nav-'), findsNothing);
  });

  testWidgets('视图模式：偏好为 list 时导航源卡片也以列表渲染，切换后写回偏好', (tester) async {
    final tmdb = listState.tmdb;
    await loadTmdb(tmdb, _navVod(), nav: true);
    await tmdb.ensureAllSeasonEpisodes(generation: tmdb.generation);
    await pumpDetail(tester, listState, _navVod());

    final listStrip = find.byKey(
      const ValueKey('tmdb-episode-strip-nav-nav-1'),
    );
    await _revealInViewport(tester, listStrip);
    expect(listStrip, findsOneWidget, reason: '偏好为 list → 导航源卡片渲染列表条');
    expect(find.byKey(const ValueKey('$_navCardPrefix-grid')), findsNothing);

    final toggle = find.byKey(const ValueKey('tmdb-episode-view-mode'));
    await _revealInViewport(tester, toggle);
    await tester.tap(toggle);
    await tester.pump();
    expect(
      find.byKey(const ValueKey('$_navCardPrefix-grid')),
      findsOneWidget,
      reason: '切换后立即变网格',
    );
    // 落盘是异步的（fake-async 区里永不完成），这里只断言**内存里的当前值**。
    expect(
      listState.episodeViewMode,
      UiEpisodeViewMode.grid,
      reason: '切换必须写回偏好（下次进详情页沿用）',
    );
  });

  testWidgets('换源并入外部线路后：线路条恢复，集数是该线路的真实集数，卡片换回既有前缀',
      (tester) async {
    // 外部线路 3 集：与 TMDB 全集（5）和导航源站源（2）都不相同，
    // 因此线路条上的数字能唯一指认它来自这条外部线路。
    navState.installSwap(
      siteKey: 'swap-site',
      siteName: '换源站',
      vodId: 'swap-1',
      lines: [
        VodPlayLine(
          flag: 'ext',
          episodes: [
            for (var i = 1; i <= 3; i++)
              VodEpisode(
                name: '换源第$i集',
                url: 'http://swap.example/e$i',
              ),
          ],
        ),
      ],
    );
    await loadTmdb(navTmdb, _navVod(), nav: true);
    await navTmdb.ensureAllSeasonEpisodes(generation: navTmdb.generation);
    await pumpDetail(tester, navState, _navVod());
    // 详情加载会重跑 `loadForVod`（可能推进代际）：等聚合回来后本帧才出卡。
    for (var i = 0; i < 60 && navTmdb.episodesBySeason.isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }

    // ---- 换源前：导航源模式 ----
    expect(
      find.byKey(const ValueKey('tmdb-line-selector')),
      findsNothing,
      reason: '前置：换源前没有线路条',
    );
    final beforeCards = _episodeCards(_navCardPrefix);
    await _revealInViewport(tester, beforeCards);
    expect(
      beforeCards,
      findsNWidgets(5),
      reason: '前置：卡片来自 TMDB 全集',
    );

    // ---- 走真实的换源提交链路：弹说明框 → 换源 → 浮层勾选/解析/并入 ----
    final firstCard = find.byKey(const ValueKey('$_navCardPrefix-0'));
    await _revealInViewport(tester, firstCard);
    await tester.tap(firstCard);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('nav-source-swap-confirm')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.byKey(const ValueKey('source-swap-sheet')),
      findsOneWidget,
      reason: '换源按钮必须升起浮层',
    );

    final rowKey = const ValueKey('source-swap-check-swap-site-swap-1');
    expect(find.byKey(rowKey), findsOneWidget, reason: '浮层应展示装好的候选');
    await tester.tap(find.byKey(rowKey));
    await tester.pump();
    // 第一次提交 = 「解析所选」；解析完成后按钮变成「并入 N 条线路」。
    await tester.tap(find.byKey(const ValueKey('source-swap-commit')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    await tester.tap(find.byKey(const ValueKey('source-swap-commit')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.byKey(const ValueKey('source-swap-sheet')),
      findsNothing,
      reason: '并入后浮层关闭',
    );

    // ---- 断言 2：线路条恢复，名字是外部线路真名，集数是它的真实集数 ----
    final selector = find.byKey(const ValueKey('tmdb-line-selector'));
    await _revealInViewport(tester, selector);
    expect(
      selector,
      findsOneWidget,
      reason: '并入外部线路后 `_externalLines` 非空 → 退出导航源模式，线路条必须回来',
    );
    expect(
      find.textContaining('换源站 · ext'),
      findsWidgets,
      reason: '线路名是外部线路的真实名字（站点名 · 原线路名）',
    );
    expect(
      find.textContaining('换源站 · ext（3 集）'),
      findsWidgets,
      reason: '线路条上的集数是该外部线路的真实集数 3，不是 TMDB 的 5 集也不是导航源的 2 集',
    );

    // ---- 断言 2.1：导航源自己的站源线路**不得**出现在线路条上 ----
    //
    // 用户反馈 2026-10-22：换源后线路条把导航源那条**不可播放**的线路也带回来了
    // （截图里「片单（4 集）」与外部线路并列），点它只会得到「这一集没有可播放
    // 的地址」。导航源的站源集数信息本来就一律丢弃（它只是索引条目），所以它
    // 连出现在线路条上的资格都没有。
    expect(
      find.textContaining('线路一（2 集）'),
      findsNothing,
      reason: '导航源的站源线路不可播放，换源后不得回到线路条上',
    );

    // ---- 断言 3：卡片切回既有命名空间 ----
    expect(
      _episodeCards(_navCardPrefix),
      findsNothing,
      reason: '导航源卡片前缀必须消失',
    );
    final externalCards = _episodeCards('tmdb-episode-card-换源站 · ext-');
    await _revealInViewport(tester, externalCards);
    expect(
      externalCards,
      findsNWidgets(3),
      reason: '卡片回到既有路径：该外部线路 3 集就是 3 张卡',
    );

    // ---- 断言 4：点击不再弹换源说明框 ----
    await tester.tap(
      find.byKey(const ValueKey('tmdb-episode-card-换源站 · ext-0')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(
      find.byKey(const ValueKey('nav-source-swap')),
      findsNothing,
      reason: '已换到真实播放源，卡片点击不再走导航源说明框',
    );
    expect(
      navState.playedTargets,
      ['http://swap.example/e1'],
      reason: '点击直接进入既有播放链路（用外部线路自己的集地址）',
    );
  });
}
