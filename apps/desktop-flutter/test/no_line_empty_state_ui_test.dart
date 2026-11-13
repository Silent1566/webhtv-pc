/// 「本片没有可播放线路」空态卡片的 UI 门禁。
///
/// 覆盖用户决策里的四条：卡片式空态（边框 + 图标 + 标题 + 弱化说明）、
/// TMDB 动作随状态变化（未配置 → 配置 / 未匹配 → 匹配 / 已匹配 → 无 TMDB 动作，
/// 用户决策 2026-11-11 去掉了「在 TMDB 中查看」）、
/// 「换源」三态常驻、以及「匹配成功后自动铺卡、不需要手动刷新」这条链路。
///
/// 与 `no_play_line_detail_ui_test.dart` 的分工：那个文件钉的是「已匹配 → 铺卡片」
/// 与「未匹配 → 提示文字 + 换源」两条既有路径，本文件钉的是**空态本身**的形态与
/// 出路。导航源路径（`indexs == 1`）由 `nav_source_detail_ui_test.dart` 单独钉住。
///
/// 为什么要自己一套 `_TestAppState` 与 fake HTTP：真实 `AppState.tmdb` 是惰性
/// 构造的内部实例，`testWidgets` 的 fake-async 区推不动真实网络（框架把请求固定
/// 返回 400），拿不到「已匹配 + 已加载详情」的前提。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/tmdb_config.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
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
import 'package:webhtv_pc/ui/config_pages.dart';
import 'package:webhtv_pc/ui/tmdb_widgets.dart';
import 'package:webhtv_pc/ui/toast.dart';

// ---------------------------------------------------------------------------
// fake HTTP
// ---------------------------------------------------------------------------

/// 两季（S1 3 集 / S2 2 集）的 TMDB 响应；候选与季列表可在用例中途改写，
/// 用来推演「先未匹配、后匹配成功」。
class _FakeClient extends http.BaseClient {
  /// `/search/multi` 的候选。
  List<Object?> searchResults = const [];

  /// `/tv/<id>` 的季列表。空 = 摊不出剧集（例如电影）。
  List<Object?> seasons = const [];

  static const Map<int, int> _episodeCounts = {1: 3, 2: 2};

  http.StreamedResponse _json(Object body) => http.StreamedResponse(
    Stream<List<int>>.value(utf8.encode(jsonEncode(body))),
    200,
  );

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final path = request.url.path;
    if (path.endsWith('/search/multi')) {
      return _json({'results': searchResults});
    }
    if (RegExp(r'/tv/\d+$').hasMatch(path)) {
      return _json({'id': 1399, 'name': '无线路剧', 'seasons': seasons});
    }
    final season = RegExp(r'/season/(\d+)$').firstMatch(path);
    if (season != null) {
      final number = int.parse(season.group(1)!);
      final count = _episodeCounts[number] ?? 0;
      return _json({
        'season_number': number,
        'episodes': [
          for (var i = 1; i <= count; i++)
            {
              'episode_number': i,
              'name': 'S${number}E$i',
              'season_number': number,
            },
        ],
      });
    }
    if (path.endsWith('/videos')) return _json({'results': <Object>[]});
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode('{"status_code":404}')),
      404,
    );
  }
}

const _tvCandidate = <String, Object?>{
  'id': 1399,
  'media_type': 'tv',
  'name': '无线路剧',
  'first_air_date': '2024-01-01',
};

const _tvSeasons = <Object?>[
  {'season_number': 1, 'episode_count': 3},
  {'season_number': 2, 'episode_count': 2},
];

/// 已配置的 TMDB（`apiKey` 非空即 `isReady`）。
const _configured = TmdbConfig(apiKey: 'k');

TmdbState _tmdbState({
  required http.Client client,
  TmdbConfig config = _configured,
}) {
  TmdbConfig read() => config;
  final service = TmdbService(config: read, client: client);
  return TmdbState(
    config: read,
    service: service,
    identityService: TmdbIdentityService(
      config: read,
      service: service,
      store: InMemoryTmdbMatchStore(),
    ),
    seasonService: TmdbSeasonService(store: InMemoryTmdbSeasonStore()),
    enrichmentService: TmdbEnrichmentService(service: service, config: read),
  );
}

/// 只替换 TMDB 状态、本页站点、详情请求、换源解析与 TMDB 搜索的 `AppState`。
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

  /// 换源浮层自动发起的那次全局搜索的关键词（空 = 没搜过）。
  final List<String> searchedKeywords = [];

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
          result: SiteResult(list: [Vod(vodId: vodId, vodName: '无线路剧')]),
        ),
      ],
    )..finished = true;
  }

  @override
  TmdbState get tmdb => _fakeTmdb;

  @override
  Site? get selectedSite => _fakeSite;

  @override
  MultiSiteSearchOutcome? get activeSearch => _searchOutcome ?? super.activeSearch;

  @override
  Future<List<VodPlayLine>> swapProbe({
    required String siteKey,
    required String vodId,
    String vodName = '',
  }) async => _probeLines;

  /// 详情请求置空：用例以 `widget.vod` 的线路（空）为事实来源。
  @override
  Future<void> loadDetail(
    Vod vod, {
    SiteService? serviceOverride,
    Site? siteOverride,
  }) async {}

  /// 并入后的 TMDB 重载走不到真实网络（本文件只关心空态的接线）。
  @override
  Future<void> reloadTmdb() async {}

  /// 匹配弹窗打开即搜索：走假数据，避免 fake-async 区里发真实请求。
  @override
  Future<List<TmdbItem>> searchTmdb(String keyword) async => const [];

  @override
  Future<TmdbItem?> resolveTmdbProviderId(String input) async => null;

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

/// 普通站点（`indexs` 非 1）：不走导航源路径。
Site _plainSite() => Site(
  key: 'plain-site',
  name: '普通站',
  type: 1,
  api: 'http://plain.example/api.php/provide/vod',
);

/// 本片在源站没有任何剧集地址：`vod_play_url` 为空 → 一条线路都解析不出。
Vod _noLineVod() => Vod(vodId: 'noline-1', vodName: '无线路剧');

Finder _episodeCards(String prefix) => find.byWidgetPredicate(
  (widget) =>
      widget is OutlinedButton &&
      widget.key is ValueKey<String> &&
      (widget.key! as ValueKey<String>).value.startsWith(prefix),
);

/// 让 [finder] 命中**且整块落在视口内**（详情区在满屏 hero 之下）。
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
  late _FakeClient unconfiguredClient;
  late _FakeClient unmatchedClient;
  late _FakeClient emptySeasonClient;
  late TmdbState unconfiguredTmdb;
  late TmdbState unmatchedTmdb;
  late TmdbState emptySeasonTmdb;
  late _TestAppState unconfiguredState;
  late _TestAppState unmatchedState;
  late _TestAppState emptySeasonState;

  setUp(() async {
    // `toastCenter` 是进程级单例：上一条用例留下的通知会漏进这一条。
    dismissAllToasts();
    tempDir = await Directory.systemTemp.createTemp('webhtv-noline-empty');
    final paths = AppPaths.resolve(
      overrides: {
        'config': '${tempDir.path}/webhtv-pc',
        'data': '${tempDir.path}/webhtv-pc',
        'cache': '${tempDir.path}/webhtv-pc/cache',
        'state': '${tempDir.path}/webhtv-pc/logs',
      },
    );

    unconfiguredClient = _FakeClient();
    unmatchedClient = _FakeClient();
    emptySeasonClient = _FakeClient()
      ..searchResults = const [_tvCandidate]
      ..seasons = const [];

    unconfiguredTmdb = _tmdbState(
      client: unconfiguredClient,
      config: const TmdbConfig(),
    );
    unmatchedTmdb = _tmdbState(client: unmatchedClient);
    emptySeasonTmdb = _tmdbState(client: emptySeasonClient);

    unconfiguredState = _TestAppState(
      paths: paths,
      log: LogService(),
      tmdb: unconfiguredTmdb,
      site: _plainSite(),
    );
    unmatchedState = _TestAppState(
      paths: paths,
      log: LogService(),
      tmdb: unmatchedTmdb,
      site: _plainSite(),
    );
    emptySeasonState = _TestAppState(
      paths: paths,
      log: LogService(),
      tmdb: emptySeasonTmdb,
      site: _plainSite(),
    );
    await unconfiguredState.bootstrap();
    await unmatchedState.bootstrap();
    await emptySeasonState.bootstrap();
  });

  tearDown(() async {
    unconfiguredState.dispose();
    unmatchedState.dispose();
    emptySeasonState.dispose();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  /// 把「匹配（或不匹配）+ 当前季剧集」装进注入的 TMDB 状态。
  ///
  /// `navSource: false` 是前提：站点不是导航源，`loadForVod` 本身**不**带全季
  /// 聚合，聚合只能由详情页在无线路模式下显式触发。
  Future<void> loadTmdb(TmdbState tmdb) => tmdb.loadForVod(
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

  /// 推进若干帧直到 [done] 成立。
  Future<void> pumpUntil(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 80 && !done(); i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
  }

  testWidgets('空态是卡片式提示区：边框 + 图标 + 标题 + 弱化说明', (tester) async {
    await loadTmdb(unmatchedTmdb);
    await pumpDetail(tester, unmatchedState);

    final card = find.byKey(const ValueKey('detail-no-line-empty'));
    await _revealInViewport(tester, card);
    expect(card, findsOneWidget, reason: '空态必须是一个有边界的提示区，不是裸 Text');

    final decoration = tester.widget<Container>(card).decoration;
    expect(decoration, isA<BoxDecoration>());
    expect(
      (decoration! as BoxDecoration).border,
      isNotNull,
      reason: '卡片要有边框（主题色，不硬编码）',
    );
    expect(find.byIcon(Icons.play_disabled_outlined), findsOneWidget);
    expect(find.text('本片在当前源没有可播放的剧集'), findsOneWidget);
    expect(
      find.text('该影片没有可播放的剧集（vod_play_url 为空）。'),
      findsOneWidget,
      reason: '技术细节保留在弱化说明行里，不当主标题',
    );
    // 这条路径不是导航源：空态的图标/标题/说明都不许提它。
    expect(find.textContaining('导航源'), findsNothing);
  });

  testWidgets('TMDB 未配置 → 「配置 TMDB」，点击进 TMDB 设置页', (tester) async {
    await loadTmdb(unconfiguredTmdb);
    expect(unconfiguredTmdb.phase, TmdbLoadPhase.disabled, reason: '前置：未配置');
    expect(unconfiguredTmdb.hasMatch, isFalse);
    await pumpDetail(tester, unconfiguredState);

    final swap = find.byKey(const ValueKey('detail-no-line-swap'));
    final action = find.byKey(const ValueKey('detail-no-line-tmdb'));
    await _revealInViewport(tester, swap);
    expect(action, findsOneWidget);
    expect(find.text('配置 TMDB'), findsOneWidget);
    expect(find.text('匹配 TMDB'), findsNothing, reason: '未配置时没有可匹配的能力');
    expect(swap, findsOneWidget, reason: '换源是保底出路，永远在');

    await tester.tap(action);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(TmdbSettingsPage), findsOneWidget);
  });

  testWidgets('TMDB 已配置未匹配 → 「匹配 TMDB」，点击打开匹配对话框', (tester) async {
    await loadTmdb(unmatchedTmdb);
    expect(unmatchedTmdb.hasMatch, isFalse, reason: '前置：搜不到作品');
    expect(unmatchedTmdb.shouldRender, isTrue);
    await pumpDetail(tester, unmatchedState);

    final swap = find.byKey(const ValueKey('detail-no-line-swap'));
    final action = find.byKey(const ValueKey('detail-no-line-tmdb'));
    await _revealInViewport(tester, swap);
    expect(action, findsOneWidget);
    // 按 key 定位空态自己那个按钮：状态条区也有一个同名「匹配 TMDB」入口
    // （`tmdb-match`），这里钉的是空态这一份。
    expect(
      find.descendant(of: action, matching: find.text('匹配 TMDB')),
      findsOneWidget,
    );
    expect(find.text('配置 TMDB'), findsNothing);
    expect(find.text('在 TMDB 中查看'), findsNothing);
    expect(swap, findsOneWidget);

    await tester.tap(action);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(TmdbMatchDialog), findsOneWidget);
  });

  testWidgets('TMDB 已匹配但摊不出剧集 → 不给 TMDB 入口，只剩换源', (tester) async {
    await loadTmdb(emptySeasonTmdb);
    expect(emptySeasonTmdb.hasMatch, isTrue, reason: '前置：已匹配');
    expect(emptySeasonTmdb.identity, isNotNull, reason: '前置：有身份（纯 TMDB 页另有入口）');
    expect(
      emptySeasonTmdb.seasonEpisodeCounts,
      isEmpty,
      reason: '前置：这部电影/无季作品摊不出剧集，因此停在空态',
    );
    await pumpDetail(tester, emptySeasonState);

    final swap = find.byKey(const ValueKey('detail-no-line-swap'));
    await _revealInViewport(tester, swap);
    // 用户决策 2026-11-11 去掉了「在 TMDB 中查看」（见
    // `browse_pages.dart` 的 `_noLineTmdbAction`）：已匹配的空态不再有 TMDB
    // 动作，出路只剩「换源」；也不给匹配入口（再匹配还是同一结果）。
    expect(
      find.byKey(const ValueKey('detail-no-line-tmdb')),
      findsNothing,
      reason: '已匹配的空态不再给 TMDB 动作',
    );
    expect(find.text('在 TMDB 中查看'), findsNothing);
    expect(find.text('匹配 TMDB'), findsNothing, reason: '已经匹配上了，再匹配还是同一结果');
    expect(find.text('配置 TMDB'), findsNothing);
    expect(swap, findsOneWidget, reason: '换源是空态唯一的出路，永远在');
    expect(_episodeCards('tmdb-episode-card-noline-'), findsNothing);
  });

  testWidgets('空态「换源」→ 直接打开换源浮层', (tester) async {
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

  testWidgets('匹配成功后自动铺出 TMDB 卡片，无需手动刷新', (tester) async {
    await loadTmdb(unmatchedTmdb);
    expect(unmatchedTmdb.hasMatch, isFalse, reason: '前置：还没匹配上');
    await pumpDetail(tester, unmatchedState);

    final swap = find.byKey(const ValueKey('detail-no-line-swap'));
    await _revealInViewport(tester, swap);
    expect(
      find.byKey(const ValueKey('detail-no-line-empty')),
      findsOneWidget,
      reason: '前置：未匹配时显示空态卡片',
    );

    // 模拟「匹配在别处完成」：候选与季数据就位后重跑同一条装配链。
    unmatchedClient
      ..searchResults = const [_tvCandidate]
      ..seasons = _tvSeasons;
    await loadTmdb(unmatchedTmdb);
    expect(unmatchedTmdb.hasMatch, isTrue, reason: '前置：匹配成功');

    // 关键：**没有**重新 pumpWidget，也没有任何「请刷新」——只推帧，
    // 铺卡必须由 TMDB 状态的 notifyListeners 自己驱动。
    await pumpUntil(tester, () => unmatchedTmdb.episodesBySeason.isNotEmpty);
    final cards = _episodeCards('tmdb-episode-card-noline-');
    await _revealInViewport(tester, cards);
    expect(cards, findsNWidgets(5), reason: 'S1(3)+S2(2) 全季一次性铺出');
    expect(
      find.byKey(const ValueKey('detail-no-line-empty')),
      findsNothing,
      reason: '有卡片可点之后空态必须退场',
    );
    expect(
      find.textContaining('请刷新'),
      findsNothing,
      reason: '这条链路不需要用户刷新，页面也不该提示刷新',
    );
  });
}
