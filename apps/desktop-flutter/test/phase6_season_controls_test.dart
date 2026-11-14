/// 季度按钮常驻（`docs/phase6/design/03` §2）。
///
/// `TmdbState` 的构造方式与 `test/phase4_tmdb_ui_test.dart` 完全一致：
/// **直接构造**（`TmdbState(config:, service:, identityService:,
/// seasonService:, enrichmentService:)`），不走 `AppState`——
/// `TmdbState` 是独立可测的组件，`AppState` 里的那个实例需要 bootstrap
/// 才能装配，测起来更慢也更脆。
///
/// `InMemoryTmdbMatchStore` 在 `tmdb_identity_service.dart`，
/// `InMemoryTmdbSeasonStore` 与 `TmdbSourceLine` 在 `tmdb_season_service.dart`
/// ——**都不在 `tmdb_stores.dart`**（该文件是数据库版 store 的实现）。
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:webhtv_pc/core/episode_range.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/tmdb_config.dart';
import 'package:webhtv_pc/core/tmdb_detail_model.dart';
import 'package:webhtv_pc/services/tmdb_enrichment_service.dart';
import 'package:webhtv_pc/services/tmdb_identity_service.dart';
import 'package:webhtv_pc/services/tmdb_season_service.dart';
import 'package:webhtv_pc/services/tmdb_service.dart';
import 'package:webhtv_pc/state/tmdb_state.dart';
import 'package:webhtv_pc/ui/tmdb_detail_view.dart';
import 'package:webhtv_pc/ui/tmdb_widgets.dart';

/// 假 HTTP 客户端：按路径后缀返回预置 JSON（与 `phase4_tmdb_ui_test` 同构）。
class _FakeClient extends http.BaseClient {
  _FakeClient(this._routes);

  /// 路径后缀 → 响应体。
  final Map<String, Object?> _routes;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    for (final entry in _routes.entries) {
      if (request.url.path.endsWith(entry.key)) {
        final body = entry.value;
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

TmdbConfig _ready() => const TmdbConfig(apiKey: 'k');

TmdbState _tmdbState({
  required TmdbConfig Function() config,
  required http.Client client,
}) {
  final service = TmdbService(config: config, client: client);
  return TmdbState(
    config: config,
    service: service,
    identityService: TmdbIdentityService(
      config: config,
      service: service,
      store: InMemoryTmdbMatchStore(),
    ),
    seasonService: TmdbSeasonService(store: InMemoryTmdbSeasonStore()),
    enrichmentService: TmdbEnrichmentService(service: service, config: config),
  );
}

// `Vod` 的构造**不是** `const`（`core/protocol.dart:818`），
// 因此这里不能写 `const Vod(...)`。
Vod _vod() => Vod(vodId: 'v1', vodName: '剧名');

/// `TmdbState.beginLoad` 收的是 `TmdbSourceLine`（不是 `VodPlayLine`）。
TmdbSourceLine _line({required int count}) => TmdbSourceLine(
  flagKey: 'f#0',
  sourceFlag: '线路一',
  episodeNames: List.generate(count, (i) => '第${i + 1}集'),
);

void main() {
  /// 走完整的匹配 + 详情流程，得到可渲染的 `TmdbState`。
  Future<TmdbState> matchedState({
    required int episodeCount,
    required List<int> tmdbSeasons,
    required Map<int, int> seasonCounts,
    String mediaType = 'tv',
  }) async {
    final tmdbId = mediaType == 'tv' ? 1399 : 550;
    final client = _FakeClient({
      '/search/multi': {
        'results': [
          {
            'id': tmdbId,
            'media_type': mediaType,
            if (mediaType == 'tv') 'name': '剧名' else 'title': '剧名',
            if (mediaType == 'tv')
              'first_air_date': '2024-01-01'
            else
              'release_date': '2024-01-01',
          },
        ],
      },
      '/tv/$tmdbId': {
        'id': tmdbId,
        'name': '剧名',
        'seasons': [
          for (final season in tmdbSeasons)
            {
              'season_number': season,
              'episode_count': seasonCounts[season] ?? 0,
            },
        ],
      },
      '/movie/$tmdbId': {'id': tmdbId, 'title': '剧名'},
    });
    final state = _tmdbState(config: _ready, client: client);
    final generation = state.beginLoad(
      siteKey: 's',
      vodId: 'v1',
      sourceTitle: '剧名',
      vod: _vod(),
      line: _line(count: episodeCount),
    );
    await state.loadMatch(generation: generation, sourceTitle: '剧名');
    await state.loadDetail(
      generation: generation,
      tmdbSeasons: tmdbSeasons,
      seasonCounts: seasonCounts,
    );
    return state;
  }

  Future<void> pumpSelector(
    WidgetTester tester,
    TmdbState tmdb, {
    VoidCallback? onSelectManual,
    ValueChanged<int>? onChanged,
    EdgeInsets padding = const EdgeInsets.symmetric(horizontal: 16),
    bool showManualEntry = true,
  }) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TmdbSeasonSelector(
            state: tmdb,
            onChanged: onChanged,
            onSelectManual: onSelectManual,
            padding: padding,
            showManualEntry: showManualEntry,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  group('季度按钮常驻（design/03 §2）', () {
    // 用户决策 2026-11-11：季度区只留 chip 条 + 一个「选择季度」按钮，
    // 原来的「第 N 季 ▾」下拉按钮去掉（三者点下去效果重叠）。
    testWidgets('多季：只有 chip 条 + 选择季度，没有下拉按钮', (tester) async {
      final tmdb = await matchedState(
        episodeCount: 5,
        tmdbSeasons: const [1, 2],
        seasonCounts: const {1: 3, 2: 2},
      );
      await pumpSelector(tester, tmdb, onChanged: (_) {});

      expect(find.byKey(const ValueKey('tmdb-season-button')), findsNothing);
      expect(
        find.byKey(const ValueKey('tmdb-season-switcher')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('tmdb-season-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('tmdb-season-2')), findsOneWidget);
      expect(find.byKey(const ValueKey('tmdb-choose-season')), findsOneWidget);
      tmdb.dispose();
    });

    // **站点页的 chip 必须真的可点**（`onSelected != null`）。
    //
    // 变异自检抓到的缺口：原用例只断言 chip **存在**，不断言可点——
    // 把站点页的 `selectableSeasons: seasons` 改成 `const []`
    // （于是 chip 全部不可点、切季功能静默失效）时，全部用例照样绿。
    testWidgets('多季：站点页 chip 真的可点并回调', (tester) async {
      final tmdb = await matchedState(
        episodeCount: 5,
        tmdbSeasons: const [1, 2],
        seasonCounts: const {1: 3, 2: 2},
      );
      int? picked;
      await pumpSelector(tester, tmdb, onChanged: (s) => picked = s);

      for (final season in const [1, 2]) {
        final chip = tester.widget<ChoiceChip>(
          find.byKey(ValueKey('tmdb-season-$season')),
        );
        expect(
          chip.onSelected,
          isNotNull,
          reason:
              '站点页的季度本来就都是可选的，chip 必须可点。'
              '传空 selectableSeasons 会让切季静默失效。',
        );
      }

      await tester.tap(find.byKey(const ValueKey('tmdb-season-2')));
      await tester.pump();
      expect(picked, 2);
      tmdb.dispose();
    });

    // 未传 `onChanged` 时 chip 必须**禁用**（不能点了没反应）。
    // 变异自检抓到的缺口：`selectable` 若漏判 `onChanged != null`，
    // chip 会显示为可点但点了什么都不发生。
    testWidgets('未传 onChanged 时 chip 禁用', (tester) async {
      final tmdb = await matchedState(
        episodeCount: 5,
        tmdbSeasons: const [1, 2],
        seasonCounts: const {1: 3, 2: 2},
      );
      await pumpSelector(tester, tmdb);

      final chip = tester.widget<ChoiceChip>(
        find.byKey(const ValueKey('tmdb-season-1')),
      );
      expect(chip.onSelected, isNull, reason: '没有回调就不应该显得可点（一个点了没反应的按钮比没有更糟）');
      tmdb.dispose();
    });

    testWidgets('单季：无 chip 条，用一行文字说明当前季度并保留改绑入口', (tester) async {
      final tmdb = await matchedState(
        episodeCount: 3,
        tmdbSeasons: const [1],
        seasonCounts: const {1: 3},
      );
      await pumpSelector(tester, tmdb);

      expect(find.byKey(const ValueKey('tmdb-season-context')), findsOneWidget);
      expect(find.text('当前季度：第 1 季'), findsOneWidget);
      expect(find.byKey(const ValueKey('tmdb-season-switcher')), findsNothing);
      expect(find.byKey(const ValueKey('tmdb-choose-season')), findsOneWidget);
      tmdb.dispose();
    });

    testWidgets('未确定季度：文字说明 + 选择季度按钮', (tester) async {
      // 7 集，而 S1=3、S2=2：既不能切片（3+2≠7），单季兼容也不成立
      // （S1 的 3 集 < 7），因此 availableSeasons 为空。
      final tmdb = await matchedState(
        episodeCount: 7,
        tmdbSeasons: const [1, 2],
        seasonCounts: const {1: 3, 2: 2},
      );
      await pumpSelector(tester, tmdb);

      expect(find.text('未确定季度'), findsOneWidget);
      expect(find.text('选择季度'), findsOneWidget);
      tmdb.dispose();
    });

    testWidgets('点「选择季度」触发 onSelectManual', (tester) async {
      final tmdb = await matchedState(
        episodeCount: 3,
        tmdbSeasons: const [1],
        seasonCounts: const {1: 3},
      );
      var opened = 0;
      await pumpSelector(tester, tmdb, onSelectManual: () => opened++);

      await tester.tap(find.byKey(const ValueKey('tmdb-choose-season')));
      await tester.pump();
      expect(opened, 1);
      tmdb.dispose();
    });

    // `design/03` C4：电影不渲染季度按钮。
    testWidgets('电影 → 季度按钮不渲染', (tester) async {
      final tmdb = await matchedState(
        episodeCount: 3,
        tmdbSeasons: const [],
        seasonCounts: const {},
        mediaType: 'movie',
      );
      await pumpSelector(tester, tmdb);

      expect(find.byKey(const ValueKey('tmdb-choose-season')), findsNothing);
      tmdb.dispose();
    });

    // `design/03` C5：未匹配 TMDB → 不渲染。
    testWidgets('未匹配 → 季度按钮不渲染', (tester) async {
      final client = _FakeClient({
        '/search/multi': {'results': []},
      });
      final tmdb = _tmdbState(config: _ready, client: client);
      final generation = tmdb.beginLoad(
        siteKey: 's',
        vodId: 'v1',
        sourceTitle: '剧名',
        vod: _vod(),
        line: _line(count: 3),
      );
      await tmdb.loadMatch(generation: generation, sourceTitle: '剧名');
      await pumpSelector(tester, tmdb);

      expect(find.byKey(const ValueKey('tmdb-season-button')), findsNothing);
      tmdb.dispose();
    });

    // 下拉按钮已去掉（2026-11-11）；「选择季度」成为唯一的手动改绑入口，
    // 因此它在多季与单季都必须存在——上面两条用例分别锁住了这两种情形。
    testWidgets('没有下拉按钮后仍能手动改绑（按钮在，回调能通）', (tester) async {
      final tmdb = await matchedState(
        episodeCount: 7,
        tmdbSeasons: const [1, 2],
        seasonCounts: const {1: 3, 2: 2},
      );
      var opened = 0;
      await pumpSelector(tester, tmdb, onSelectManual: () => opened++);

      expect(find.byKey(const ValueKey('tmdb-season-button')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('tmdb-choose-season')));
      await tester.pump();
      expect(opened, 1);
      tmdb.dispose();
    });

    // 季度选择器**不得**因加按钮而改变行高（Global Constraints：
    // 任何净高度变化会把控件挤出测试视口）。
    testWidgets('加按钮后行高仍是 tmdbSeasonSelectorHeight', (tester) async {
      final tmdb = await matchedState(
        episodeCount: 3,
        tmdbSeasons: const [1],
        seasonCounts: const {1: 3},
      );
      await pumpSelector(tester, tmdb);

      final box = tester.getSize(
        find.byKey(const ValueKey('tmdb-choose-season')).first,
      );
      expect(
        box.height,
        lessThanOrEqualTo(tmdbSeasonSelectorHeight),
        reason: '按钮必须在既有行高内，不得把这一行撑高',
      );
      tmdb.dispose();
    });

    testWidgets('showManualEntry=false 时按钮禁用（不给假入口）', (tester) async {
      final tmdb = await matchedState(
        episodeCount: 3,
        tmdbSeasons: const [1],
        seasonCounts: const {1: 3},
      );
      // **必须传一个非 null 的回调**：否则 `onPressed` 本来就是 null，
      // 断言在「有守卫」与「没守卫」两种实现下都绿——测不出守卫是否存在
      // （变异自检抓到的缺口）。
      var opened = 0;
      await pumpSelector(
        tester,
        tmdb,
        showManualEntry: false,
        onSelectManual: () => opened++,
      );

      final button = tester.widget<TextButton>(
        find.byKey(const ValueKey('tmdb-choose-season')),
      );
      expect(
        button.onPressed,
        isNull,
        reason: 'showManualEntry=false 时即使传了回调也不得可点',
      );

      // 点一下也不应该触发（禁用态真的不透传）。
      await tester.tap(
        find.byKey(const ValueKey('tmdb-choose-season')),
        warnIfMissed: false,
      );
      await tester.pump();
      expect(opened, 0);
      tmdb.dispose();
    });

    testWidgets('showManualEntry=true 时回调真的接通', (tester) async {
      final tmdb = await matchedState(
        episodeCount: 3,
        tmdbSeasons: const [1],
        seasonCounts: const {1: 3},
      );
      var opened = 0;
      await pumpSelector(tester, tmdb, onSelectManual: () => opened++);

      await tester.tap(find.byKey(const ValueKey('tmdb-choose-season')));
      await tester.pump();
      expect(opened, 1, reason: '默认（true）必须可点');
      tmdb.dispose();
    });

    testWidgets('padding 参数真的生效（纯 TMDB 页要贴合自己的内容列）', (tester) async {
      final tmdb = await matchedState(
        episodeCount: 3,
        tmdbSeasons: const [1],
        seasonCounts: const {1: 3},
      );
      await pumpSelector(
        tester,
        tmdb,
        padding: const EdgeInsets.symmetric(horizontal: 2),
      );

      // 单季没有 chip 条，这行左沿由季度状态文字承担。
      final left = tester.getTopLeft(
        find.byKey(const ValueKey('tmdb-season-context')).first,
      );
      expect(
        left.dx,
        lessThan(10),
        reason: 'padding.left=2 时内容应贴近左沿；写死 16 会让它偏移到 ~16',
      );
      tmdb.dispose();
    });
  });

  group('tmdbSeasonStatusLabel（纯函数）', () {
    test('有选中季 → 当前季度：第 N 季', () async {
      final tmdb = await matchedState(
        episodeCount: 3,
        tmdbSeasons: const [1],
        seasonCounts: const {1: 3},
      );
      expect(tmdbSeasonStatusLabel(tmdb), '当前季度：第 1 季');
      tmdb.dispose();
    });

    test('特别篇 → 当前季度：特别篇', () async {
      final tmdb = await matchedState(
        episodeCount: 3,
        tmdbSeasons: const [0],
        seasonCounts: const {0: 3},
      );
      expect(tmdbSeasonStatusLabel(tmdb), '当前季度：特别篇');
      tmdb.dispose();
    });

    // `design/03` C3：解析不出季度 → 「未确定季度」。
    test('无法解析季度 → 未确定季度', () async {
      final tmdb = await matchedState(
        episodeCount: 7,
        tmdbSeasons: const [1, 2],
        seasonCounts: const {1: 3, 2: 2},
      );
      expect(tmdb.selectedSeason, lessThan(0), reason: '前置：确实没解析出季度');
      expect(tmdbSeasonStatusLabel(tmdb), '未确定季度');
      tmdb.dispose();
    });

    // `design/03` §2.2 的中间一行：`selectedSeason < 0` 但**解析出了季度**。
    // 当前 `TmdbState` 在 `_availableSeasons` 非空时总会把 `_selectedSeason`
    // 落定（`tmdb_state.dart` 的 `scope is KnownSeason` / `_defaultSeasonOf`），
    // 因此这一行现在**不可达**。本用例把它锁成「不可达」这个事实，
    // 若将来状态机改了、`selectedSeason` 可能为 -1 而季度已解析，
    // 这条会失败并提醒实现补上 §2.2 的中间行。
    test('selectedSeason<0 而季度已解析 → 不可达（现状）', () async {
      final tmdb = await matchedState(
        episodeCount: 5,
        tmdbSeasons: const [1, 2],
        seasonCounts: const {1: 3, 2: 2},
      );
      expect(tmdb.availableSeasons, isNotEmpty, reason: '前置：解析出了季度');
      expect(
        tmdb.selectedSeason,
        greaterThanOrEqualTo(0),
        reason:
            'availableSeasons 非空时 TmdbState 总会落定 selectedSeason，'
            '因此 §2.2 的「有季度但 selectedSeason<0」这一行当前不可达。'
            '若这条失败，说明状态机变了，需要补 §2.2 的中间行文案逻辑。',
      );
      tmdb.dispose();
    });
  });

  group('季度 UI 统一（design/03 §3）', () {
    TmdbDetailData detailData() => const TmdbDetailData(
      title: '剧名',
      overview: '',
      posterUrl: null,
      backdropUrls: [],
      rating: 0,
    );

    const twoSeasons = [
      TmdbSeasonInfo(number: 1, episodeCount: 3, name: '第 1 季'),
      TmdbSeasonInfo(number: 2, episodeCount: 2, name: '第 2 季'),
    ];

    Future<void> pumpDetailView(
      WidgetTester tester, {
      List<int> selectableSeasons = const [1, 2],
      ValueChanged<int>? onSeasonChanged,
      Size viewport = const Size(1400, 2400),
    }) async {
      // 视口默认给到 2400 高：`TmdbDetailView` 的内容区是
      // 「满屏 hero → 信息表 → 季度 → 剧集」，季度 chip 在 1200 高时
      // 落在视口外，`tap` 会报 *would not hit test*。
      tester.view.physicalSize = viewport;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: TmdbDetailView(
                data: detailData(),
                seasons: twoSeasons,
                selectedSeason: 1,
                selectableSeasons: selectableSeasons,
                onSeasonChanged: onSeasonChanged,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('TmdbDetailView 的季度区块是 chip 条，不是海报卡片条', (tester) async {
      // **必须指定 anchor**：裸 `find.byType(RepaintBoundary)` 不适用，
      // 这里要直接点 chip —— 而 `TmdbDetailView` 的内容区很长
      // （头部 hero + 信息表 + 季度 + 剧集），chip 默认落在 1200 高视口之外。
      // 先设高视口把季度条带进视口，再断言与点击。
      await pumpDetailView(tester, viewport: const Size(1400, 2400));

      expect(
        find.byKey(const ValueKey('tmdb-section-seasons')),
        findsOneWidget,
        reason: '区块 key 必须保留',
      );
      expect(
        find.byKey(const ValueKey('tmdb-season-strip')),
        findsNothing,
        reason: '海报卡片条已改为 chip 条',
      );
      expect(
        find.byKey(const ValueKey('tmdb-detail-season-switcher')),
        findsOneWidget,
        reason: '改为 chip 条后必须有自己的容器 key',
      );
      expect(
        find.byKey(const ValueKey('tmdb-detail-season-1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('tmdb-detail-season-2')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull, reason: '不得溢出');
    });

    // 旧的海报卡片 key 不得残留（它们是两套 UI 并存的痕迹）。
    testWidgets('不再有 tmdb-season-card-* 海报卡片', (tester) async {
      await pumpDetailView(tester);

      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget.key is ValueKey<String> &&
              (widget.key! as ValueKey<String>).value.startsWith(
                'tmdb-season-card-',
              ),
        ),
        findsNothing,
      );
    });

    // **既有语义**（`tmdb_detail_view.dart:944`）：
    // 「可切换的季度号；为空但 seasons 非空时**只展示不可切换**」。
    // 这条是 pre-flight 发现的 brief 缺陷（brief 的 SeasonChipStrip 把空
    // 当成「全部可切换」，与既有语义相反）。
    testWidgets('selectableSeasons 为空 → chip 只展示不可切换（既有语义）', (tester) async {
      var changed = 0;
      await pumpDetailView(
        tester,
        selectableSeasons: const [],
        onSeasonChanged: (_) => changed++,
      );

      final chip = tester.widget<ChoiceChip>(
        find.byKey(const ValueKey('tmdb-detail-season-2')),
      );
      expect(
        chip.onSelected,
        isNull,
        reason:
            '空 selectableSeasons = 只展示。brief 的 '
            '`isEmpty || contains` 会让它变成可点，纯 TMDB 页因此能选到'
            '未确证的季度。',
      );

      await tester.tap(
        find.byKey(const ValueKey('tmdb-detail-season-2')),
        warnIfMissed: false,
      );
      await tester.pump();
      expect(changed, 0);
    });

    testWidgets('selectableSeasons 含该季 → 可点并回调', (tester) async {
      int? selected;
      await pumpDetailView(
        tester,
        selectableSeasons: const [2],
        onSeasonChanged: (season) => selected = season,
      );

      // 第 1 季不在 selectable 里 → 禁点击。
      final chip1 = tester.widget<ChoiceChip>(
        find.byKey(const ValueKey('tmdb-detail-season-1')),
      );
      expect(chip1.onSelected, isNull);

      // **必须先 `ensureVisible`**：`TmdbDetailView` 的内容区是
      // 「满屏 hero → 信息表 → 季度 → 剧集」，季度 chip 的 y 约 2500，
      // 在 2400 高视口下仍在屏外，直接 `tap` 会报 *would not hit test*。
      final chip2 = find.byKey(const ValueKey('tmdb-detail-season-2'));
      await tester.ensureVisible(chip2);
      await tester.pumpAndSettle();
      await tester.tap(chip2);
      await tester.pump();
      expect(selected, 2);
    });

    testWidgets('季度数为 1 时不渲染 chip 条', (tester) async {
      tester.view.physicalSize = const Size(1400, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: TmdbDetailView(
                data: detailData(),
                seasons: const [
                  TmdbSeasonInfo(number: 1, episodeCount: 3, name: '第 1 季'),
                ],
                selectedSeason: 1,
                selectableSeasons: const [1],
                onSeasonChanged: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey('tmdb-detail-season-switcher')),
        findsNothing,
        reason: '单季无 chip 条（与站点页一致）',
      );
      expect(
        find.byKey(const ValueKey('tmdb-section-seasons')),
        findsOneWidget,
        reason: '区块头仍在，只是没有 chip',
      );
    });

    // 未确定季度时区块头带「选择季度」入口（既有行为，不得因改 UI 而丢）。
    testWidgets('未确定季度 → 区块头有「选择季度」入口', (tester) async {
      tester.view.physicalSize = const Size(1400, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: TmdbDetailView(
                data: detailData(),
                seasons: twoSeasons,
                selectedSeason: -1,
                selectableSeasons: const [1, 2],
                onSeasonChanged: (_) {},
                onSelectSeason: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byKey(const ValueKey('tmdb-choose-season')), findsOneWidget);
    });
  });

  group('选集区间条（design/03 §4.3、§4.5）', () {
    List<TmdbEpisodeCard> cardsFor(int count) => [
      for (var i = 1; i <= count; i++)
        TmdbEpisodeCard(number: i, title: '第$i集'),
    ];

    /// 当前条上实际挂载的**卡片**（排除区间 chip）。
    ///
    /// 横向 `ListView` 是**懒构建**的：1400 宽视口下只挂载 ~6 张卡，
    /// 因此不能用它数「本区间共几张卡」。
    Finder cardButtons(String keyPrefix) => find.byWidgetPredicate(
      (widget) =>
          widget is OutlinedButton &&
          widget.key is ValueKey<String> &&
          (widget.key! as ValueKey<String>).value.startsWith('$keyPrefix-') &&
          !(widget.key! as ValueKey<String>).value.contains('range') &&
          !(widget.key! as ValueKey<String>).value.contains('still'),
    );

    Future<void> pumpStrip(
      WidgetTester tester, {
      required int count,
      required List<EpisodeRange> ranges,
      int rangeIndex = 0,
      ValueChanged<int>? onRangeChanged,
      void Function(int index, TmdbEpisodeCard card)? onTap,
      bool gridMode = true,
    }) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              // `gridMode: true`：`shrinkWrap` + 不可滚会**构建全部**子项，
              // 因此能用 `findsNWidgets` 数卡片数（横向 `ListView` 是懒构建的，
              // 数不准）。
              child: TmdbEpisodeStrip(
                keyPrefix: 'tmdb-episode-card-线路一',
                cards: cardsFor(count),
                ranges: ranges,
                rangeIndex: rangeIndex,
                onRangeChanged: onRangeChanged,
                onTap: onTap,
                gridMode: gridMode,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('区间数 > 1 时渲染区间条', (tester) async {
      final ranges = EpisodeRangePolicy.build(70, 0, false);
      await pumpStrip(tester, count: 70, ranges: ranges);

      expect(
        find.byKey(const ValueKey('tmdb-episode-card-线路一-range-strip')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('tmdb-episode-card-线路一-range-0')),
        findsOneWidget,
      );
      // 70 集、每段 40 → 标签 1-40 / 41-70（brief 写的 1-20 误用了每段 20）。
      expect(find.text('1-40'), findsWidgets);
      expect(find.text('41-70'), findsWidgets);
    });

    testWidgets('区间数为 1 时不渲染区间条', (tester) async {
      final ranges = EpisodeRangePolicy.build(10, 0, false);
      await pumpStrip(tester, count: 10, ranges: ranges);

      expect(
        find.byKey(const ValueKey('tmdb-episode-card-线路一-range-strip')),
        findsNothing,
      );
    });

    testWidgets('只渲染当前区间的卡片', (tester) async {
      final ranges = EpisodeRangePolicy.build(70, 0, false);
      await pumpStrip(tester, count: 70, ranges: ranges, rangeIndex: 0);

      // 区间 0 = [0, 40) → 40 张卡（70 集的阶梯值是 40，不是 20）。
      expect(cardButtons('tmdb-episode-card-线路一'), findsNWidgets(40));
      expect(
        find.byKey(const ValueKey('tmdb-episode-card-线路一-40')),
        findsNothing,
        reason: '第 2 区间的卡片不得被渲染',
      );
    });

    testWidgets('切到第 2 区间只渲染该区间的卡片', (tester) async {
      final ranges = EpisodeRangePolicy.build(70, 0, false);
      await pumpStrip(tester, count: 70, ranges: ranges, rangeIndex: 1);

      // 区间 1 = [40, 70) → 30 张卡。
      expect(cardButtons('tmdb-episode-card-线路一'), findsNWidgets(30));
      expect(
        find.byKey(const ValueKey('tmdb-episode-card-线路一-40')),
        findsOneWidget,
      );
    });

    testWidgets('点区间 chip 回调下标', (tester) async {
      final ranges = EpisodeRangePolicy.build(70, 0, false);
      int? tapped;
      await pumpStrip(
        tester,
        count: 70,
        ranges: ranges,
        onRangeChanged: (index) => tapped = index,
      );

      await tester.tap(
        find.byKey(const ValueKey('tmdb-episode-card-线路一-range-1')),
      );
      await tester.pump();
      expect(tapped, 1);
    });

    // ===== 以下为 brief 没有的钉子（预检 + 变异自检发现）=====

    // **`design/03` §4.5 的核心**：分页只切**渲染**，播放必须仍用**线路原始下标**。
    //
    // brief 的 `_buildStrip` 把**可见下标**直接交给 `onTap`，而调用方
    // `browse_pages.dart#_playEpisodeAt` 把它当作「未切片列表的下标」
    // （它会按 `line.episodes[index]` 取集，再做 indexWhere 换算原始下标）——
    // 于是第 2 区间的第 0 张卡会播成**第 1 区间的第 0 集**：静默播错集。
    //
    // 本用例断言：切到区间 1 后点第一张卡，回调收到的是**原始下标 40**。
    testWidgets('切到第 2 区间后点首张卡 → 回调收到原始下标 40（不是 0）', (tester) async {
      final ranges = EpisodeRangePolicy.build(70, 0, false);
      int? tappedIndex;
      await pumpStrip(
        tester,
        count: 70,
        ranges: ranges,
        rangeIndex: 1,
        onRangeChanged: (_) {},
        onTap: (index, _) => tappedIndex = index,
      );

      // 区间 1 = [40, 70) → 首卡的**原始下标**是 40。
      await tester.tap(find.byKey(const ValueKey('tmdb-episode-card-线路一-40')));
      await tester.pump();
      expect(
        tappedIndex,
        40,
        reason:
            '分页只切渲染（§4.5）：回调必须给**原始下标**，'
            '否则调用方的「渲染下标 → 原始下标」换算会二次映射，静默播错集。',
      );
    });

    // 卡片自身的 key 后缀也必须是**原始下标**，否则集成门禁按
    // `tmdb-episode-card-<flag>-<i>` 计数/定位会错位。
    testWidgets('卡片 key 后缀用原始下标（第 2 区间从 40 开始）', (tester) async {
      final ranges = EpisodeRangePolicy.build(70, 0, false);
      await pumpStrip(
        tester,
        count: 70,
        ranges: ranges,
        rangeIndex: 1,
        onRangeChanged: (_) {},
      );

      expect(
        find.byKey(const ValueKey('tmdb-episode-card-线路一-40')),
        findsOneWidget,
        reason: '第 2 区间首卡必须是原始下标 40',
      );
      expect(
        find.byKey(const ValueKey('tmdb-episode-card-线路一-0')),
        findsNothing,
        reason: '第 1 区间的下标不得在第 2 区间重现（会与门禁定位冲突）',
      );
    });

    // 「最近播放」标记也必须是原始下标，否则分页后标错卡。
    //
    // 标记本体是一个带 `recentKey` 的徽标（`<prefix>-recent-<i>`），
    // **只在 `isRecent` 为真时渲染**；卡片外壳的 key 两种情况都在，
    // 因此断言外壳测不出这个变异（首轮 M7 存活的原因）。
    testWidgets('recentIndex 用原始下标，分页后仍标中正确的卡', (tester) async {
      final ranges = EpisodeRangePolicy.build(70, 0, false);
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TmdbEpisodeStrip(
              keyPrefix: 'tmdb-episode-card-线路一',
              cards: cardsFor(70),
              ranges: ranges,
              rangeIndex: 1,
              onRangeChanged: (_) {},
              // 原始下标 42（在区间 1 = [40,70) 内）。
              recentIndex: 42,
            ),
          ),
        ),
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey('tmdb-episode-card-线路一-recent-42')),
        findsOneWidget,
        reason: '原始下标 42 的卡必须带「最近播放」徽标',
      );
      // 区间内下标 2 的位置**不得**被误标（它对应原始下标 42，二者在本例
      // 恰好相同，所以另测一个区间内下标≠原始下标 的位置）。
      expect(
        find.byKey(const ValueKey('tmdb-episode-card-线路一-recent-2')),
        findsNothing,
        reason:
            '徽标 key 必须用**原始下标**：若用区间内下标，'
            '第 2 区间的首卡会被标成 recent-0 而非 recent-40',
      );
    });

    // 选中区间要**自动滚入视野**（对齐上游 `smoothScrollTo`）。
    // 用 ScrollController 算偏移，因此可以直接读 controller.offset。
    testWidgets('选中的区间自动滚入视野', (tester) async {
      final ranges = EpisodeRangePolicy.build(3000, 0, false);
      // 3000 集：阶梯 300 → 被 50 封顶 → 每段 50 → 60 个区间，必然超出屏宽。
      expect(ranges.length, greaterThan(20), reason: '前置：区间数要足够多');
      await pumpStrip(
        tester,
        count: 120,
        ranges: ranges,
        rangeIndex: 30,
        onRangeChanged: (_) {},
        gridMode: false,
      );
      await tester.pumpAndSettle();

      final list = tester.widget<ListView>(
        find.byKey(const ValueKey('tmdb-episode-card-线路一-range-strip')),
      );
      expect(
        list.controller?.offset ?? 0,
        greaterThan(0),
        reason: '选中靠后的区间时必须滚动，否则用户看不到当前区间',
      );
    });

    // 区间数 > 1 但 `onRangeChanged` 为空 → chip 禁用（不给假入口）。
    testWidgets('未传 onRangeChanged 时区间 chip 禁用', (tester) async {
      final ranges = EpisodeRangePolicy.build(70, 0, false);
      await pumpStrip(tester, count: 70, ranges: ranges);

      final chip = tester.widget<ChoiceChip>(
        find.byKey(const ValueKey('tmdb-episode-card-线路一-range-0')),
      );
      expect(chip.onSelected, isNull);
    });

    // 传入 `ranges` 但区间数 ≤ 1 时，卡片应是**全部**（不得被空区间切没）。
    testWidgets('区间数 ≤ 1 时渲染全部卡片', (tester) async {
      await pumpStrip(
        tester,
        count: 10,
        ranges: EpisodeRangePolicy.build(10, 0, false),
      );

      expect(cardButtons('tmdb-episode-card-线路一'), findsNWidgets(10));
    });

    // 区间 chip 的标签是**真实集号**（`design/03` §4.2 / 验收 C11），
    // 不是列表下标：降到 0 基会让人误以为集号从 0 开始。
    testWidgets('区间标签是真实集号（正序 1 基）', (tester) async {
      final ranges = EpisodeRangePolicy.build(70, 0, false);
      await pumpStrip(tester, count: 70, ranges: ranges);

      expect(find.text('1-40'), findsWidgets, reason: '首段从第 1 集开始');
      expect(find.text('0-39'), findsNothing, reason: '不得降到 0 基');
    });

    // 倒序时区间标签也是真实集号方向（大集号在前）。
    testWidgets('倒序时区间标签从大集号开始', (tester) async {
      final ranges = EpisodeRangePolicy.build(70, 0, true);
      await pumpStrip(tester, count: 70, ranges: ranges);

      expect(find.text('70-41'), findsWidgets);
      expect(find.text('40-1'), findsWidgets);
    });
  });

  group('切季行为（design/03 §5.1）', () {
    test('selectSeason 自增 seasonEpoch', () async {
      final tmdb = await matchedState(
        episodeCount: 5,
        tmdbSeasons: const [1, 2],
        seasonCounts: const {1: 3, 2: 2},
      );
      final before = tmdb.seasonEpoch;
      tmdb.selectSeason(2);
      expect(tmdb.seasonEpoch, greaterThan(before));
      tmdb.dispose();
    });

    test('重复选同一季不自增', () async {
      final tmdb = await matchedState(
        episodeCount: 5,
        tmdbSeasons: const [1, 2],
        seasonCounts: const {1: 3, 2: 2},
      );
      final before = tmdb.seasonEpoch;
      tmdb.selectSeason(tmdb.selectedSeason);
      expect(tmdb.seasonEpoch, before);
      tmdb.dispose();
    });

    // 选一个**不在** availableSeasons 里的季度不得自增（否则 UI 会误重置区间）。
    test('选不可用季度不自增', () async {
      final tmdb = await matchedState(
        episodeCount: 5,
        tmdbSeasons: const [1, 2],
        seasonCounts: const {1: 3, 2: 2},
      );
      final before = tmdb.seasonEpoch;
      tmdb.selectSeason(99);
      expect(tmdb.seasonEpoch, before);
      tmdb.dispose();
    });

    test('初始 seasonEpoch 是 0', () async {
      final tmdb = await matchedState(
        episodeCount: 3,
        tmdbSeasons: const [1],
        seasonCounts: const {1: 3},
      );
      expect(tmdb.seasonEpoch, 0);
      tmdb.dispose();
    });
  });
}
