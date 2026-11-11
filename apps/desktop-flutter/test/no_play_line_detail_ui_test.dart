/// 「本片没有可播放线路」时的详情页 UI 接线门禁。
///
/// 需求方向（用户决策，2026-10）：普通站点进来、本片 `vod_play_url` 为空（解析不
/// 出任何线路）时，若 TMDB 已匹配，选集区改铺 TMDB 全集卡片——卡片只是换源入口，
/// 点击弹「需要换源播放」说明；TMDB 未匹配/未配置时保留原提示文字并加「换源」按钮。
///
/// 本文件只钉**这条新路径**的接线：判据、卡片数量与 key 命名空间、点击链
/// （卡片 → 弹窗 → 换源浮层）、以及未匹配时的空态。导航源（`indexs == 1`）那条
/// 路径由 `nav_source_detail_ui_test.dart` 单独钉住，本文件不碰它。
///
/// 为什么要 `_TestAppState` 与 fake HTTP：真实 `AppState.tmdb` 是惰性构造的内部
/// 实例，`testWidgets` 的 fake-async 区推不动真实 HTTP（框架把请求固定返回 400），
/// 拿不到「已匹配 + 已加载详情」的前提。`loadDetail` 直接置空：本文件关心的是
/// 渲染判据，站源详情请求在用例里没有可等待的价值，置空还能让提示文字保持默认值。
library;

import 'dart:async';
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
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/state/search_state.dart';
import 'package:webhtv_pc/state/tmdb_state.dart';
import 'package:webhtv_pc/ui/browse_pages.dart';
import 'package:webhtv_pc/ui/common.dart';
import 'package:webhtv_pc/ui/toast.dart';

// ---------------------------------------------------------------------------
// fake HTTP（与 `nav_source_detail_ui_test` 同一套基础设施）
// ---------------------------------------------------------------------------

class _FakeClient extends http.BaseClient {
  final List<(String, Object?)> routes = [];

  /// 每季剧集接口的被请求次数（季号 → 次数）：用来断言「逐季真发请求」。
  final Map<int, int> seasonRequests = {};

  /// 已请求的接口路径（前缀匹配用，例如 `/season/`）。
  final List<String> requestedPaths = [];

  /// 非空时挂起所有响应：模拟聚合还没回来。
  Completer<void>? gate;

  void route(String suffix, Object? body) => routes.add((suffix, body));

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final path = request.url.path;
    requestedPaths.add(path);
    final season = RegExp(r'/season/(\d+)$').firstMatch(path);
    if (season != null) {
      final number = int.parse(season.group(1)!);
      seasonRequests[number] = (seasonRequests[number] ?? 0) + 1;
    }
    final pending = gate;
    if (pending != null) await pending.future;
    for (final (suffix, body) in routes) {
      if (path.endsWith(suffix)) {
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
        'name': '无线路剧',
        'first_air_date': '2024-01-01',
      },
    ],
  })
  ..route('/tv/1399', {
    'id': 1399,
    'name': '无线路剧',
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

/// 只替换 TMDB 状态、本页站点、播放解析、详情请求、全局搜索与换源解析的
/// `AppState`。
class _TestAppState extends AppState {
  _TestAppState({
    required AppPaths paths,
    required LogService log,
    required TmdbState tmdb,
    required Site site,
  }) : _fakeTmdb = tmdb,
       _fakeSite = site,
       super(paths: paths, log: log);

  final TmdbState _fakeTmdb;
  final Site _fakeSite;

  /// 换源浮层读的是这个快照（不是 `searchAll` 的返回值）。
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
    _searchOutcome = MultiSiteSearchOutcome(
      runId: 1,
      keyword: '无线路剧',
      results: [
        SiteSearchEntry(
          siteKey: siteKey,
          siteName: siteName,
          result: SiteResult(
            list: [Vod(vodId: vodId, vodName: '无线路剧')],
          ),
        ),
      ],
    )..finished = true;
  }

  @override
  MultiSiteSearchOutcome? get activeSearch => _searchOutcome ?? super.activeSearch;

  @override
  Future<List<VodPlayLine>> swapProbe({
    required String siteKey,
    required String vodId,
    String vodName = '',
  }) async => _probeLines;

  /// 并入后的 TMDB 重载走不到真实网络（本文件只关心卡片与弹窗接线）。
  @override
  Future<void> reloadTmdb() async {}

  /// 被请求播放的 `episode.url` 序列（只记录，不真的解析/开播放器）。
  final List<String> playedTargets = [];

  /// 换源浮层自动发起的那次全局搜索的关键词（空 = 没搜过）。
  ///
  /// 它是「换源入口真的被调用」的观测点：卡片的点击链是
  /// 「弹说明框 → 换源 → `_openSourceSwap` → 浮层 → 搜索」。
  final List<String> searchedKeywords = [];

  @override
  TmdbState get tmdb => _fakeTmdb;

  @override
  Site? get selectedSite => _fakeSite;

  /// 详情请求置空：用例以 `widget.vod` 的线路（空）为事实来源，不依赖站源详情。
  @override
  Future<void> loadDetail(
    Vod vod, {
    SiteService? serviceOverride,
    Site? siteOverride,
  }) async {}

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
  }) async {
    playedTargets.add(episodeTarget);
    throw AppError(AppErrorKind.siteCancelled, '测试：不真的解析播放地址');
  }

  /// 换源浮层打开就会搜一次；真搜索会在 fake-async 区里留下悬空计时器。
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
    return MultiSiteSearchOutcome(
      runId: 1,
      keyword: keyword,
      results: const [],
    )..finished = true;
  }
}

// ---------------------------------------------------------------------------
// 夹具
// ---------------------------------------------------------------------------

/// 普通站点（`indexs` 为空 / 非 1）：不走导航源路径。
Site _plainSite() => Site(
  key: 'plain-site',
  name: '普通站',
  type: 1,
  api: 'http://plain.example/api.php/provide/vod',
);

/// 本片在源站没有任何剧集地址：`vod_play_url` 为空 → 一条线路都解析不出。
Vod _noLineVod({String vodId = 'noline-1'}) =>
    Vod(vodId: vodId, vodName: '无线路剧');

/// 新模式的卡片 key 前缀（必须与导航源的 `nav-` 命名空间彻底隔离）。
const _cardPrefix = 'tmdb-episode-card-noline-noline-1';

Finder _episodeCards(String prefix) => find.byWidgetPredicate(
  (widget) =>
      widget is OutlinedButton &&
      widget.key is ValueKey<String> &&
      (widget.key! as ValueKey<String>).value.startsWith(prefix),
);

/// 让 [finder] 命中**且整块落在视口内**（命中不等于可点：剧集区在满屏 hero 之下）。
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

/// 反复向下滚动直到 [finder] 命中（详情区在 hero 之下，懒构建）。
///
/// 与 [_revealInViewport] 的分工：那个要求「命中且可点」，这里只要求「滚下去把它
/// 建出来」——用于断言某个东西**不该**出现时先滚到它本该出现的深度。
Future<void> _scrollUntilBuilt(
  WidgetTester tester,
  Finder finder, {
  int attempts = 40,
}) async {
  for (var attempt = 0; attempt < attempts; attempt++) {
    if (finder.evaluate().isNotEmpty) return;
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -200));
    await tester.pump();
  }
}

void main() {
  late Directory tempDir;
  late _TestAppState plainState;
  late _TestAppState unmatchedState;
  late TmdbState plainTmdb;
  late TmdbState unmatchedTmdb;
  late _FakeClient plainClient;

  setUp(() async {
    // `toastCenter` 是进程级单例：上一条用例留下的通知会漏进这一条。
    dismissAllToasts();
    tempDir = await Directory.systemTemp.createTemp('webhtv-noline-detail');
    final paths = AppPaths.resolve(
      overrides: {
        'config': '${tempDir.path}/webhtv-pc',
        'data': '${tempDir.path}/webhtv-pc',
        'cache': '${tempDir.path}/webhtv-pc/cache',
        'state': '${tempDir.path}/webhtv-pc/logs',
      },
    );
    plainClient = _tmdbClient();
    plainTmdb = _tmdbState(client: plainClient);
    unmatchedTmdb = _tmdbState(client: _unmatchedClient());
    plainState = _TestAppState(
      paths: paths,
      log: LogService(),
      tmdb: plainTmdb,
      site: _plainSite(),
    );
    unmatchedState = _TestAppState(
      paths: paths,
      log: LogService(),
      tmdb: unmatchedTmdb,
      site: _plainSite(),
    );
    await plainState.bootstrap();
    await unmatchedState.bootstrap();
  });

  tearDown(() async {
    plainState.dispose();
    unmatchedState.dispose();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  /// 把「已匹配 + 详情 + 当前季剧集」装进注入的 TMDB 状态。
  ///
  /// `navSource: false` 是本用例的前提：站点不是导航源，`loadForVod` 本身**不**
  /// 带全季聚合，聚合只能由详情页在无线路模式下显式触发。
  Future<void> loadTmdb(TmdbState tmdb) =>
      tmdb.loadForVod(
        _noLineVod(),
        siteKey: 'plain-site',
        siteName: '普通站',
        navSource: false,
      );

  Future<void> pumpDetail(WidgetTester tester, AppState state) async {
    tester.view.physicalSize = const Size(1400, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MaterialApp(home: DetailPage(state: state, vod: _noLineVod())),
    );
    await tester.pump();
  }

  /// 推进若干帧直到 [done] 成立（聚合是页面自己发起的异步补充加载）。
  Future<void> pumpUntil(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 80 && !done(); i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
  }

  testWidgets('普通站点 + 线路为空 + TMDB 已匹配 → 铺 TMDB 全集卡片', (tester) async {
    await loadTmdb(plainTmdb);
    expect(plainTmdb.hasMatch, isTrue, reason: '前置：TMDB 必须已匹配');
    expect(
      plainTmdb.episodesBySeason,
      isEmpty,
      reason: '前置：聚合是页面在无线路模式下显式触发的补充加载',
    );

    await pumpDetail(tester, plainState);
    await pumpUntil(tester, () => plainTmdb.episodesBySeason.isNotEmpty);

    final cards = _episodeCards(_cardPrefix);
    await _revealInViewport(tester, cards);
    expect(
      cards,
      findsNWidgets(5),
      reason: 'TMDB 全集 S1(3)+S2(2)=5 张',
    );
    // 命名空间隔离：导航源与既有线路卡片都不能出现在这条路径上。
    expect(_episodeCards('tmdb-episode-card-nav-'), findsNothing);
    expect(_episodeCards('tmdb-episode-card-线路'), findsNothing);
    // 没有线路可言，线路条不该出现。
    expect(find.byKey(const ValueKey('tmdb-line-selector')), findsNothing);
    // 文案里不出现「导航源」：这条路径不是导航源。
    expect(find.textContaining('导航源'), findsNothing);
    // 也没有空态换源按钮（有卡片可点就不需要它）。
    expect(find.byKey(const ValueKey('detail-no-line-swap')), findsNothing);
  });

  testWidgets('无线路模式会逐季请求 seasonEpisodes，S2 卡片用 TMDB 真实集名', (tester) async {
    await loadTmdb(plainTmdb);
    // 前置：装配阶段绝不会去拉 S2 的集——所以 S2 的请求只能来自无线路模式。
    expect(
      plainClient.seasonRequests[2],
      isNull,
      reason: '前置：非导航源装配阶段不碰非当前季',
    );
    expect(plainTmdb.episodesBySeason, isEmpty);

    await pumpDetail(tester, plainState);
    await pumpUntil(tester, () => plainTmdb.episodesBySeason.length >= 2);

    // 逐季真发请求：两季各一次。
    expect(
      plainClient.seasonRequests,
      {1: 1, 2: 1},
      reason: '无线路模式必须逐季拉全季集元数据',
    );
    expect(
      plainTmdb.episodesBySeason.keys.toSet(),
      {1, 2},
      reason: '聚合结果覆盖全部两季',
    );

    final cards = _episodeCards(_cardPrefix);
    await _revealInViewport(tester, cards);
    expect(cards, findsNWidgets(5));
    // S2 的两张卡必须带 TMDB 真实集名，而不是「第 N 集」占位。
    expect(
      find.text('S2E1'),
      findsOneWidget,
      reason: 'S2 卡片用 TMDB 集名，不得退化成「第 1 集」占位',
    );
    expect(
      find.text('S2E2'),
      findsOneWidget,
      reason: 'S2 卡片用 TMDB 集名，不得退化成「第 2 集」占位',
    );
    expect(find.text('第 1 集'), findsNothing);
    expect(find.text('第 2 集'), findsNothing);
  });

  testWidgets('聚合未返回时渲染 LoadingBlock，不闪「没有可播放的剧集」假空态', (tester) async {
    await loadTmdb(plainTmdb);
    // 装配完成之后再挂住响应：否则 `loadForVod` 自己那一趟也会被卡死。
    final gate = plainClient.gate = Completer<void>();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
      plainClient.gate = null;
    });

    await pumpDetail(tester, plainState);
    // 页面必须已经发起聚合（否则「转圈」只是初始态）。
    await pumpUntil(tester, () => plainClient.seasonRequests[2] != null);
    expect(plainTmdb.episodesBySeason, isEmpty, reason: '前置：聚合还没落地');

    // 选集区在 hero 之下、懒构建：先滚下去把它建出来。
    await _scrollUntilBuilt(tester, find.byType(LoadingBlock));
    expect(
      find.byType(LoadingBlock),
      findsWidgets,
      reason: '聚合未落地时只转圈',
    );
    expect(
      find.textContaining('没有可播放的剧集'),
      findsNothing,
      reason: '不得先闪一帧假空态',
    );
    expect(
      find.byKey(const ValueKey('detail-no-line-swap')),
      findsNothing,
      reason: '转圈期间不给空态换源按钮',
    );
    expect(_episodeCards(_cardPrefix), findsNothing);

    // 放开响应：聚合落地后必须换成卡片，而不是停在转圈。
    gate.complete();
    await pumpUntil(tester, () => plainTmdb.episodesBySeason.length >= 2);
    final cards = _episodeCards(_cardPrefix);
    await _revealInViewport(tester, cards);
    expect(cards, findsNWidgets(5));
  });

  testWidgets('点卡片 → 弹「需要换源播放」说明框，文案用通用措辞', (tester) async {
    await loadTmdb(plainTmdb);
    await pumpDetail(tester, plainState);

    final first = find.byKey(const ValueKey('$_cardPrefix-0'));
    await _revealInViewport(tester, first);
    expect(first, findsOneWidget);
    expect(
      tester.widget<OutlinedButton>(first).onPressed,
      isNotNull,
      reason: '所有卡片都可点（点击只是换源入口），不得置灰',
    );

    await tester.tap(first);
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(const ValueKey('no-line-swap')), findsOneWidget);
    expect(find.text('需要换源播放'), findsOneWidget);
    expect(
      find.text('当前站点没有可播放的线路（该影片的剧集地址为空）。'),
      findsOneWidget,
    );
    expect(find.text('知道了'), findsWidgets);
    expect(find.text('换源'), findsWidgets);
    // 不得复用导航源的 key，也不得出现「导航源」字样。
    expect(find.byKey(const ValueKey('nav-source-swap')), findsNothing);
    expect(find.textContaining('导航源'), findsNothing);
    expect(plainState.playedTargets, isEmpty, reason: '点击卡片不是播放');
  });

  testWidgets('点「知道了」→ 框关闭，不打开换源浮层也不播放', (tester) async {
    await loadTmdb(plainTmdb);
    await pumpDetail(tester, plainState);

    final first = find.byKey(const ValueKey('$_cardPrefix-0'));
    await _revealInViewport(tester, first);
    await tester.tap(first);
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.byKey(const ValueKey('no-line-swap-dismiss')));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(const ValueKey('no-line-swap')), findsNothing);
    expect(find.byKey(const ValueKey('source-swap-sheet')), findsNothing);
    expect(plainState.playedTargets, isEmpty);
  });

  testWidgets('点「换源」→ 框关闭并打开换源浮层（换源流程真的被调用）', (tester) async {
    // 外部线路 3 集：与 TMDB 全集的 5 集不同，便于区分。
    plainState.installSwap(
      siteKey: 'swap-site',
      siteName: '换源站',
      vodId: 'swap-1',
      lines: [
        VodPlayLine(
          flag: 'ext',
          episodes: [
            for (var i = 1; i <= 3; i++)
              VodEpisode(name: '换源第$i集', url: 'http://swap.example/e$i'),
          ],
        ),
      ],
    );
    await loadTmdb(plainTmdb);
    await pumpDetail(tester, plainState);

    final first = find.byKey(const ValueKey('$_cardPrefix-0'));
    await _revealInViewport(tester, first);
    await tester.tap(first);
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.byKey(const ValueKey('no-line-swap-confirm')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byKey(const ValueKey('no-line-swap')), findsNothing);
    // 换源浮层出现 = `_openSourceSwap()` 真的被调用（说明框 → 换源入口的接线）。
    expect(find.byKey(const ValueKey('source-swap-sheet')), findsOneWidget);
    expect(
      plainState.searchedKeywords,
      ['无线路剧'],
      reason: '浮层用本页片名发起换源搜索',
    );
    expect(plainState.playedTargets, isEmpty, reason: '换源不是播放');
  });

  testWidgets('线路为空 + TMDB 未匹配 → 保留原提示文字并给出「换源」按钮', (tester) async {
    await loadTmdb(unmatchedTmdb);
    expect(unmatchedTmdb.hasMatch, isFalse, reason: '前置：搜不到作品');
    await pumpDetail(tester, unmatchedState);

    // 先滚到空态：详情区在满屏 hero 之下，未进入视口前根本不会被构建。
    final swap = find.byKey(const ValueKey('detail-no-line-swap'));
    await _revealInViewport(tester, swap);
    expect(swap, findsOneWidget);
    expect(
      find.text('该影片没有可播放的剧集（vod_play_url 为空）。'),
      findsOneWidget,
      reason: '未匹配时保留原有提示文字',
    );
    // 不出任何剧集卡片（两条命名空间都不许有）。
    expect(_episodeCards(_cardPrefix), findsNothing);
    expect(_episodeCards('tmdb-episode-card-nav-'), findsNothing);
    expect(find.byKey(const ValueKey('tmdb-line-selector')), findsNothing);
    expect(find.textContaining('导航源'), findsNothing);
  });

  testWidgets('空态「换源」按钮 → 直接打开换源浮层', (tester) async {
    unmatchedState.installSwap(
      siteKey: 'swap-site',
      siteName: '换源站',
      vodId: 'swap-1',
      lines: [
        VodPlayLine(
          flag: 'ext',
          episodes: [
            VodEpisode(name: '换源第1集', url: 'http://swap.example/e1'),
          ],
        ),
      ],
    );
    await loadTmdb(unmatchedTmdb);
    await pumpDetail(tester, unmatchedState);

    final swap = find.byKey(const ValueKey('detail-no-line-swap'));
    await _revealInViewport(tester, swap);
    await tester.tap(swap);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byKey(const ValueKey('source-swap-sheet')), findsOneWidget);
    expect(unmatchedState.searchedKeywords, ['无线路剧']);
  });
}
