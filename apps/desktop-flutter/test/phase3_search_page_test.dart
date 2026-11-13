/// 搜索页交互门禁（对齐上游安卓「默影视」SearchFragment + CollectFragment）。
///
/// 覆盖：
/// - 落地页的搜索历史（可删）+ 热门推荐（三类目）；
/// - 输入联想 → 点联想词即搜；
/// - **点击联想词必须能用真实鼠标命中**（实测缺陷，用户 2026-10-14：
///   「点击联想结果没有反应也没有输入到输入框中」——收起面板靠输入框失焦，
///   而 PC 上点面板本身就会让它失焦，面板在按下与抬起之间被卸载）；
///
/// 全部走真实 `AppState`（假 HTTP 客户端 + 假联想服务），不依赖外网与真实 socket。
///
/// **平台必须是 Windows**：`TextField` 的默认 `onTapOutside` 只在桌面/Web 上
/// 让输入框失焦（`kIsWeb || desktop`），而 `flutter_test` 默认平台是 android——
/// 不覆盖成 Windows，上面那条真实鼠标缺陷根本复现不出来（实测）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/search_suggest_service.dart';
import 'package:webhtv_pc/services/ui_preferences_store.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/search_page.dart';

/// 站点配置：`甲站[盘]` / `丁站[盘]` 同属「盘」，`乙站[采]` 属「采」，`丙站` 无分组。
const String _configJson = '''
{
  "name": "搜索页测试",
  "sites": [
    {"key": "ui-a", "name": "甲站[盘]", "type": 1, "api": "http://127.0.0.1:1/api/type1/", "searchable": 1},
    {"key": "ui-b", "name": "乙站[采]", "type": 1, "api": "http://127.0.0.1:1/api/type1/", "searchable": 1},
    {"key": "ui-c", "name": "丙站", "type": 1, "api": "http://127.0.0.1:1/api/type1/", "searchable": 1},
    {"key": "ui-d", "name": "丁站[盘]", "type": 1, "api": "http://127.0.0.1:1/api/type1/", "searchable": 1}
  ]
}
''';

void main() {
  late Directory tempDir;
  late AppState state;
  late _FakeSiteClient siteClient;

  /// 榜单假服务：留着引用，便于某条用例调小候选池（验证「池子不够时不出现换一批」）。
  late _FakeSuggestService fakeSuggest;

  /// 当前渲染出的热门卡片数（按 key 前缀数）。
  int hotCards(HotRankCategory category) => find
      .byWidgetPredicate(
        (widget) =>
            widget.key is ValueKey<String> &&
            (widget.key! as ValueKey<String>).value.startsWith(
              'search-hot-${category.name}-',
            ),
      )
      .evaluate()
      .length;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('webhtv-search-ui');
    siteClient = _FakeSiteClient();
    fakeSuggest = _FakeSuggestService();
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
      httpClient: siteClient,
      searchSuggestService: fakeSuggest,
    );
  });

  tearDown(() async {
    state.dispose();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  /// 装配 UI 偏好（历史/相似度）并导入站点配置。
  ///
  /// 全部包在 [WidgetTester.runAsync] 里：`testWidgets` 的函数体跑在
  /// **fake-async 区**，真实文件 I/O 的完成回调永远不会被投递（实测：直接
  /// `await store.load()` 会把测试挂死）。`setUp` 里只做临时目录创建。
  ///
  /// 不调 `bootstrap()`：与 `phase2_search_test.dart` 同样的轻量路径，
  /// `importConfig` 会自行装配站点服务。
  Future<void> prepare(
    WidgetTester tester, {
    List<String> history = const [],
    int? similarity,
  }) async {
    await tester.runAsync(() async {
      final store = UiPreferencesStore(
        path: p.join(tempDir.path, 'settings.json'),
      );
      await store.load();
      for (final keyword in history.reversed) {
        await store.rememberSearchKeyword(keyword);
      }
      if (similarity != null) await store.rememberSearchSimilarity(similarity);
      state.attachUiPreferences(store);
      final ok = await state.importConfig(_configJson);
      expect(ok, isTrue, reason: '配置导入应成功');
    });
  }

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: SearchPage(state: state))),
    );
    // 落地页会在 initState 异步拉热门榜单：多 pump 几次让空完成。
    await tester.pump();
    await tester.pump();
  }

  /// 走完一次搜索（假客户端在微任务内完成，pump 即可推进）。
  Future<void> submitSearch(WidgetTester tester, String keyword) async {
    await tester.enterText(find.byKey(const ValueKey('search-input')), keyword);
    // 越过联想防抖窗口，确保面板真的被打开过（回归才有意义）。
    await tester.pump(const Duration(milliseconds: 320));
    await tester.pump();
    await tester.tap(find.text('搜索'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump();
  }

  // ---------------------------------------------------------------------------
  // 落地页：历史 + 热门推荐
  // ---------------------------------------------------------------------------
  testWidgets('落地页展示搜索历史与热门推荐', (tester) async {
    await prepare(tester, history: ['旧词']);
    await pumpPage(tester);

    expect(find.text('搜索历史'), findsOneWidget);
    expect(find.byKey(const ValueKey('search-history-旧词')), findsOneWidget);
    expect(find.text('热门推荐'), findsOneWidget);
    expect(find.byKey(const ValueKey('search-hot-tab-movie')), findsOneWidget);
    expect(find.byKey(const ValueKey('search-hot-tab-series')), findsOneWidget);
    expect(find.byKey(const ValueKey('search-hot-tab-variety')), findsOneWidget);
    // 热门条目现在是**海报卡片**而不是词条
    // （用户 2026-10-14：「显示成卡片是否更好看点」）。
    expect(find.textContaining('电影热榜第一条'), findsOneWidget);
    expect(find.byKey(const ValueKey('search-hot-movie-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('search-hot-movie-1')), findsOneWidget);
  });

  testWidgets('热门卡片：名次/评分/集数角标，并写明点击是搜索', (tester) async {
    await prepare(tester);
    await pumpPage(tester);

    // 榜单是**名次**列表：卡面要能看出第几名（原来词条是「1. 片名」前缀）。
    expect(find.text('TOP1'), findsOneWidget);
    expect(find.text('TOP2'), findsOneWidget);
    // 豆瓣评分：第一条有、第二条没有（不能画出空角标）。
    expect(find.text('5.3'), findsOneWidget);
    // `upinfo` 作为副标题。
    expect(find.text('全47集'), findsOneWidget);
    expect(find.text('全22集'), findsOneWidget);
    // 卡片带海报很容易被当成「点开即播放」，页面必须有语义说明。
    expect(find.text('点击卡片搜索该片名'), findsOneWidget);
  });

  testWidgets('点击热门卡片 → 用该片名去各站点搜索（不是播放）', (tester) async {
    await prepare(tester);
    await pumpPage(tester);

    await tester.tap(find.byKey(const ValueKey('search-hot-movie-1')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump();

    expect(state.activeSearch?.keyword, '电影热榜第二条');
    expect(state.recentSearchKeywords.first, '电影热榜第二条');
  });

  testWidgets('切换热门类目时卡片跟着换', (tester) async {
    await prepare(tester);
    await pumpPage(tester);
    expect(find.text('电影热榜第一条'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('search-hot-tab-variety')));
    await tester.pump();

    expect(find.text('综艺热榜第一条'), findsOneWidget);
    expect(find.text('电影热榜第一条'), findsNothing);
    // 综艺的 `upinfo` 是期数而不是集数（同一批多张卡都是期数，所以不是 findsOneWidget）。
    expect(find.text('2026-10-13期'), findsWidgets);
  });

  testWidgets('热门推荐按可用宽高恰好铺满（不出现半行）', (tester) async {
    // 用户 2026-10-14：「能否自动基于高宽计算显示多少个推荐条目也就是刚好
    // 铺满的那种」——固定 10 条时窄窗口会出现「第一行 7 个 + 第二行 3 个
    // + 右侧一大片空白」。
    await prepare(tester);
    await pumpPage(tester);

    final grid = tester.widget<GridView>(find.byType(GridView));
    final delegate =
        grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
    final rendered = hotCards(HotRankCategory.movie);

    expect(delegate.crossAxisCount, greaterThan(1), reason: '前置条件：多列布局');
    expect(rendered, greaterThan(0));
    expect(
      rendered % delegate.crossAxisCount,
      0,
      reason: '显示条数必须是整数行——半行正是「右边一大片空白」的成因',
    );
    expect(
      find.byKey(ValueKey('search-hot-movie-$rendered')),
      findsNothing,
      reason: '第 capacity+1 条不该渲染（否则就不是恰好铺满）',
    );
  });

  testWidgets('「换一批」轮换出一屏之外的条目（条数不变）', (tester) async {
    await prepare(tester);
    await pumpPage(tester);

    final before = hotCards(HotRankCategory.movie);
    expect(find.text('电影热榜第一条'), findsOneWidget);
    final shuffle = find.byKey(const ValueKey('search-hot-shuffle'));
    expect(shuffle, findsOneWidget, reason: '候选池 12 条 > 一屏容量，应该能换一批');

    await tester.tap(shuffle);
    await tester.pump();

    expect(find.text('电影热榜第一条'), findsNothing, reason: '换一批后不该还是同一批');
    expect(
      hotCards(HotRankCategory.movie),
      before,
      reason: '换一批只换内容，不改变「恰好铺满」的条数',
    );
  });

  testWidgets('候选池不比一屏大时不显示「换一批」', (tester) async {
    fakeSuggest.hotCount = 2;
    await prepare(tester);
    await pumpPage(tester);

    expect(
      find.byKey(const ValueKey('search-hot-shuffle')),
      findsNothing,
      reason: '池子只有 2 条时轮换不出新内容，按钮不该出现（出现也只会点了没反应）',
    );
    expect(hotCards(HotRankCategory.movie), 2);
  });

  testWidgets('删除单条搜索历史', (tester) async {
    await prepare(tester, history: ['要删掉的词']);
    await pumpPage(tester);

    final chip = find.byKey(const ValueKey('search-history-要删掉的词'));
    expect(chip, findsOneWidget);
    // 不按具体图标断言：M2/M3 的 InputChip 删除图标不同（cancel / clear）。
    // 该 chip 没有前置图标，所以唯一的 Icon 后代就是删除按钮。
    final deleteIcon = find.descendant(of: chip, matching: find.byType(Icon));
    expect(deleteIcon, findsOneWidget, reason: '历史 chip 应带删除按钮');
    await tester.tap(deleteIcon);
    await tester.pump();

    expect(find.byKey(const ValueKey('search-history-要删掉的词')), findsNothing);
    expect(state.recentSearchKeywords, isEmpty);
  });

  // ---------------------------------------------------------------------------
  // 联想
  // ---------------------------------------------------------------------------
  testWidgets('输入触发联想，点击联想词即搜', (tester) async {
    await prepare(tester);
    await pumpPage(tester);

    await tester.enterText(find.byKey(const ValueKey('search-input')), '测试');
    await tester.pump(const Duration(milliseconds: 320));
    await tester.pump();

    final suggestion = find.byKey(const ValueKey('search-suggest-0'));
    expect(suggestion, findsOneWidget, reason: '输入后应展示联想词');
    expect(find.text('测试 联想词一'), findsOneWidget);

    await tester.tap(suggestion);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump();

    expect(state.activeSearch?.keyword, '测试 联想词一');
    expect(state.recentSearchKeywords.first, '测试 联想词一');
  });

  testWidgets('点击联想词用真实鼠标时序也能命中（回归：跨帧点击）', (tester) async {
    // 为什么需要这个用例（用户 2026-10-14：「点击联想结果没有反应也没有输入到
    // 输入框中」）：收起联想面板曾靠**输入框失焦**，而 PC 上点面板里的项本身
    // 就会让它失焦（`TextField` 的默认 `onTapOutside` 只在**桌面/Web** 上执行
    // unfocus）→ 面板在「按下」与「抬起」之间被卸载 → `ListTile.onTap` 永远
    // 收不到。两个关键点让它长期隐身：
    // ① `tester.tap` 的 down+up 在同一帧内完成，抳不到跨帧卸载；
    // ② `flutter_test` 默认平台是 **android**，而失焦逻辑只在桌面生效。
    // 因此这里同时做两件事：用 `startGesture` 拆开按下/抬起，并把平台覆盖成 Windows。
    // 注：`debugDefaultTargetPlatformOverride` 必须在**测试体内**复位——
    // 框架的 `debugAssertAllFoundationVarsUnset` 在 tearDown 之前就会跑。
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await prepare(tester);
      await pumpPage(tester);

      await tester.enterText(find.byKey(const ValueKey('search-input')), '测试');
      await tester.pump(const Duration(milliseconds: 320));
      await tester.pump();

      final suggestion = find.byKey(const ValueKey('search-suggest-0'));
      expect(suggestion, findsOneWidget, reason: '前置条件：联想面板已打开');

      // **鼠标指针**：与用户实际使用一致（touch 不会让 `InkWell` 拿焦点）。
      final gesture = await tester.startGesture(
        tester.getCenter(suggestion),
        kind: PointerDeviceKind.mouse,
      );
      // 跨帧：面板若在这一帧被卸载，抬起就再也落不到它身上。
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 16));
      expect(
        find.byKey(const ValueKey('search-suggest-0')),
        findsOneWidget,
        reason: '按下后跨帧面板不得被卸载（否则真实鼠标点击永远落空）',
      );
      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump();

      expect(state.activeSearch?.keyword, '测试 联想词一');
      expect(state.recentSearchKeywords.first, '测试 联想词一');
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('点击联想面板之外收起面板（onTapOutside）', (tester) async {
    await prepare(tester);
    await pumpPage(tester);

    await tester.enterText(find.byKey(const ValueKey('search-input')), '测试');
    await tester.pump(const Duration(milliseconds: 320));
    await tester.pump();
    expect(find.byKey(const ValueKey('search-suggest-0')), findsOneWidget);

    // 点联想面板之外的空白处（面板只覆盖到 y≈392，这里在它下方且无卡片）。
    // 不能点「搜索历史」那类文字：它们在面板覆盖范围内，会落到面板上。
    await tester.tapAt(const Offset(700, 560));
    await tester.pump();

    expect(
      find.byKey(const ValueKey('search-suggest-0')),
      findsNothing,
      reason: '点面板外部应收起联想',
    );
  });

  testWidgets('提交搜索后联想面板必须收起（回归）', (tester) async {
    await prepare(tester);
    await pumpPage(tester);

    await tester.enterText(find.byKey(const ValueKey('search-input')), '测试');
    await tester.pump(const Duration(milliseconds: 320));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('search-suggest-0')),
      findsOneWidget,
      reason: '前置条件：联想面板已打开',
    );

    await tester.tap(find.text('搜索'));
    await tester.pump();

    expect(
      find.byKey(const ValueKey('search-suggest-0')),
      findsNothing,
      reason: '提交后重设文本不得因 selection 变化重新打开联想面板',
    );
  });

  // ---------------------------------------------------------------------------
  // 结果筛选：分组 / 相似度 / 站点
  // ---------------------------------------------------------------------------
  testWidgets('结果按站点名分组提供筛选 chip，点击后只留该分组站点', (tester) async {
    await prepare(tester, similarity: 0);
    await pumpPage(tester);
    await submitSearch(tester, '测试');

    expect(find.textContaining('命中站点 4/4'), findsOneWidget);
    final groupPan = find.byKey(const ValueKey('search-group-盘'));
    final groupCai = find.byKey(const ValueKey('search-group-采'));
    expect(groupPan, findsOneWidget);
    expect(groupCai, findsOneWidget);

    await tester.tap(groupPan);
    await tester.pump();

    expect(find.byKey(const ValueKey('search-site-ui-a')), findsOneWidget);
    expect(find.byKey(const ValueKey('search-site-ui-d')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('search-site-ui-c')),
      findsNothing,
      reason: '无分组的站点不应出现在「盘」分组里',
    );
  });

  testWidgets('点击站点侧栏只显示该站点结果', (tester) async {
    await prepare(tester, similarity: 0);
    await pumpPage(tester);
    await submitSearch(tester, '测试');

    // 「全部站点」聚合视图：四个站点各 1 条，共 4 张结果卡片（key 带所属站点，
    // 因此四张卡片各自可精确匹配）。
    for (final siteKey in ['ui-a', 'ui-b', 'ui-c', 'ui-d']) {
      expect(
        find.byKey(ValueKey('search-result-$siteKey-demo-1')),
        findsOneWidget,
        reason: '全部视图应包含 $siteKey 的条目',
      );
    }

    await tester.tap(find.byKey(const ValueKey('search-site-ui-b')));
    await tester.pump();

    expect(
      find.byKey(const ValueKey('search-result-ui-b-demo-1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('search-result-ui-a-demo-1')),
      findsNothing,
      reason: '选中单站点后不得再渲染其它站点的条目',
    );
  });

  testWidgets('相似度筛选：精确会滤掉不匹配标题，不限恢复全部', (tester) async {
    // 标题 fixture 为「测试视频」，关键词「测试」覆盖率 50%：
    // 阈值 100（精确）应全部滤掉，阈值 0（不限）应全部可见。
    await prepare(tester, similarity: 100);
    await pumpPage(tester);
    await submitSearch(tester, '测试');

    expect(find.text('当前筛选下没有可见结果'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('search-similarity-0')));
    await tester.pump();

    for (final siteKey in ['ui-a', 'ui-b', 'ui-c', 'ui-d']) {
      expect(
        find.byKey(ValueKey('search-result-$siteKey-demo-1')),
        findsOneWidget,
      );
    }
  });

  // ---------------------------------------------------------------------------
  // 搜索范围（对齐上游 SearchFragment 的 scope 菜单）
  // ---------------------------------------------------------------------------
  testWidgets('范围选择器：选分组后只搜该分组的站点', (tester) async {
    await prepare(tester, similarity: 0);
    await pumpPage(tester);
    await submitSearch(tester, '测试');
    expect(state.activeSearch!.results.length, 4, reason: '默认搜全部站点');

    await tester.tap(find.byKey(const ValueKey('search-scope')));
    await tester.pumpAndSettle();
    // 菜单项包含「盘」「采」两个来自配置的分组。
    expect(find.byKey(const ValueKey('search-scope-all')), findsOneWidget);
    expect(find.byKey(const ValueKey('search-scope-group-盘')), findsOneWidget);
    expect(find.byKey(const ValueKey('search-scope-group-采')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('search-scope-group-盘')));
    await tester.pumpAndSettle();
    await tester.pump();

    expect(state.activeSearch!.group, '盘');
    expect(
      state.activeSearch!.results.map((e) => e.siteKey).toList(),
      ['ui-a', 'ui-d'],
      reason: '只有带 [盘] 标记的站点参与',
    );
  });

  testWidgets('范围选择器：选当前站点只搜该站点', (tester) async {
    await prepare(tester, similarity: 0);
    await pumpPage(tester);
    await submitSearch(tester, '测试');

    await tester.tap(find.byKey(const ValueKey('search-scope')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('search-scope-site')));
    await tester.pumpAndSettle();
    await tester.pump();

    expect(state.activeSearch!.siteKey, 'ui-a', reason: '默认站点为 ui-a');
    expect(state.activeSearch!.results.map((e) => e.siteKey).toList(), ['ui-a']);
  });

  testWidgets('范围选择器：当前站点被屏蔽时不给「当前站点」选项', (tester) async {
    await prepare(tester, similarity: 0);
    await pumpPage(tester);

    // 屏蔽的是**当前站点**（ui-a）：这种组合下「当前站点」范围必然一个请求都不发，
    // 给出来只会让用户以为搜索坏了（屏蔽站点不参与搜索，见 AppState.searchAll）。
    await tester.runAsync(() => state.setSiteBlocked('ui-a', true));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('search-scope')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('search-scope-all')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('search-scope-site')),
      findsNothing,
      reason: '被屏蔽的当前站点不得出现在搜索范围里',
    );
  });

  // ---------------------------------------------------------------------------
  // 结果分页（对齐上游 CustomScroller + SearchPageState）
  // ---------------------------------------------------------------------------
  testWidgets('单站点视图可加载下一页', (tester) async {
    await prepare(tester, similarity: 0);
    await pumpPage(tester);
    await submitSearch(tester, '测试');

    // 「全部」视图不分页（上游同样不分页），只给提示。
    expect(
      find.byKey(const ValueKey('search-all-paging-hint')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('search-load-more')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('search-site-ui-a')));
    await tester.pump();
    expect(find.byKey(const ValueKey('search-result-ui-a-demo-1')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('search-load-more')),
      findsOneWidget,
      reason: 'pagecount=3 → 还能翻页',
    );

    await tester.tap(find.byKey(const ValueKey('search-load-more')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(
      find.byKey(const ValueKey('search-result-ui-a-demo-2')),
      findsOneWidget,
      reason: '第 2 页条目应追加',
    );
    expect(
      find.byKey(const ValueKey('search-result-ui-a-demo-1')),
      findsOneWidget,
      reason: '第 1 页条目仍在',
    );
    // 加载更多按钮的文案跟着页码走。
    expect(find.textContaining('第 3 页'), findsOneWidget);
  });

  testWidgets('选中站点不会平白自动翻页（相似度为 0）', (tester) async {
    await prepare(tester, similarity: 0);
    await pumpPage(tester);
    await submitSearch(tester, '测试');
    final requestsAfterSearch = siteClient.searchRequests;

    await tester.tap(find.byKey(const ValueKey('search-site-ui-a')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      siteClient.searchRequests,
      requestsAfterSearch,
      reason: '相似度 0 时没有「整页被滤掉」可言，不应自动翻页',
    );
    expect(siteClient.requestedPages, [1]);
  });

  testWidgets('相似度把整页滤掉时自动续翻下一页', (tester) async {
    // 阈值 100（精确）：页面标题「测试视频N」都不等于「测试」→ 全被滤掉。
    await prepare(tester, similarity: 100);
    await pumpPage(tester);
    await submitSearch(tester, '测试');
    expect(state.activeSearch!.entryOf('ui-a')!.hasMore, isTrue);

    await tester.tap(find.byKey(const ValueKey('search-site-ui-a')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      siteClient.requestedPages,
      contains(2),
      reason: '整页被滤掉应自动续翻（上游 shouldContinue）',
    );
    // 但必须有上限：3 页都看不见时不能无限翻。
    expect(siteClient.requestedPages.length, lessThanOrEqualTo(3));
  });

  // ---------------------------------------------------------------------------
  // 相似度滑块（对齐上游 SliderNumberDialog）
  // ---------------------------------------------------------------------------
  testWidgets('相似度滑块可自定义阈值并生效', (tester) async {
    await prepare(tester, similarity: 30);
    await pumpPage(tester);
    await submitSearch(tester, '测试');
    expect(state.searchSimilarity, 30);

    await tester.tap(find.byKey(const ValueKey('search-similarity-custom')));
    await tester.pumpAndSettle();

    String valueText() => tester
        .widget<Text>(find.byKey(const ValueKey('similarity-value')))
        .data!;
    expect(find.byKey(const ValueKey('similarity-slider')), findsOneWidget);
    expect(valueText(), '30%');

    // 往右拖：阈值必然升高。
    await tester.drag(
      find.byKey(const ValueKey('similarity-slider')),
      const Offset(600, 0),
    );
    await tester.pumpAndSettle();
    final chosen = int.parse(valueText().replaceAll('%', ''));
    expect(chosen, greaterThan(30), reason: '向右拖动应提高阈值');

    await tester.tap(find.byKey(const ValueKey('similarity-confirm')));
    await tester.pumpAndSettle();

    expect(state.searchSimilarity, chosen, reason: '确定后取对话框里的值');
    // 落点是非预设值时才渲染在「自定义」chip 上（100 等预设值由预设 chip 表示）。
    if (!const [0, 30, 60, 100].contains(chosen)) {
      expect(find.text('≥$chosen%'), findsOneWidget);
    }
  });

  testWidgets('非预设相似度值显示在自定义 chip 上', (tester) async {
    await prepare(tester, similarity: 45);
    await pumpPage(tester);
    await submitSearch(tester, '测试');

    expect(find.text('≥45%'), findsOneWidget);
    // 预设 chip 都不处于选中态（自定义值不属于任何预设）。
    expect(find.text('不限'), findsOneWidget);
    expect(find.text('精确'), findsOneWidget);
  });

  testWidgets('相似度滑块取消不改动阈值', (tester) async {
    await prepare(tester, similarity: 30);
    await pumpPage(tester);
    await submitSearch(tester, '测试');

    await tester.tap(find.byKey(const ValueKey('search-similarity-custom')));
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const ValueKey('similarity-slider')),
      const Offset(600, 0),
    );
    await tester.pumpAndSettle();
    // 页面上的「取消」是取消搜索按钮，必须定位对话框里的那个。
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('取消'),
      ),
    );
    await tester.pumpAndSettle();

    expect(state.searchSimilarity, 30, reason: '取消必须不改值');
  });

  testWidgets('相似度预设 chips 设为自定义后仍可用', (tester) async {
    await prepare(tester, similarity: 30);
    await pumpPage(tester);
    await submitSearch(tester, '测试');

    // 先经滑块落到一个非预设值。
    await tester.tap(find.byKey(const ValueKey('search-similarity-custom')));
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const ValueKey('similarity-slider')),
      const Offset(120, 0),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('similarity-confirm')));
    await tester.pumpAndSettle();

    // 再点预设「精确」应能回到预设。
    await tester.tap(find.byKey(const ValueKey('search-similarity-100')));
    await tester.pumpAndSettle();
    expect(state.searchSimilarity, 100);
    expect(find.text('自定义…'), findsOneWidget);
  });

  testWidgets('搜索后清空输入回到推荐落地页（回归）', (tester) async {
    // 用户 2026-10-14：「搜索之后貌似没办法返回到搜索页面默认状态——就是能看到
    // 推荐的那些」。根因：落地页判定写过 `outcome == null && !hasKeyword`，而
    // `_activeSearch` 是**跨页面存活**的，搜过一次就再也回不去。
    await prepare(tester);
    await pumpPage(tester);
    await submitSearch(tester, '测试');
    expect(find.text('搜索历史'), findsNothing);
    expect(find.text('热门推荐'), findsNothing);

    await tester.enterText(find.byKey(const ValueKey('search-input')), '');
    await tester.pump();

    expect(find.text('搜索历史'), findsOneWidget, reason: '清空输入应回到落地页');
    expect(find.text('热门推荐'), findsOneWidget);
    expect(state.activeSearch, isNull, reason: '残留结果应被丢掉，否则再输入会闪旧结果');
  });

  testWidgets('重建搜索页（切走再切回）也是落地页，不带旧结果（回归）', (tester) async {
    // 用户 2026-10-14：「我切换到其他页面再切换搜索也不行」。
    await prepare(tester);
    await pumpPage(tester);
    await submitSearch(tester, '测试');
    expect(state.activeSearch, isNotNull);

    // 重建页面 = 切换 shell section 时的真实行为（State 被销毁重建）。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await pumpPage(tester);

    expect(find.text('热门推荐'), findsOneWidget, reason: '切回来应看到推荐落地页');
    expect(state.activeSearch, isNull, reason: '重建时丢掉上一轮的结果');
  });

  testWidgets('搜索结束后「返回推荐」按钮可用且能回落地页（回归）', (tester) async {
    // 用户 2026-10-14：「取消按钮也没办法点击」——原来写成
    // `searching ? cancel : null`，搜索一结束按钮就变灰，而那时恰好最需要它。
    await prepare(tester);
    await pumpPage(tester);
    await submitSearch(tester, '测试');

    final button = find.byKey(const ValueKey('search-cancel'));
    expect(button, findsOneWidget);
    expect(
      find.text('返回推荐'),
      findsOneWidget,
      reason: '搜索已结束时按钮语义是「返回推荐」而不是「取消」',
    );
    expect(
      tester.widget<OutlinedButton>(find.ancestor(
        of: find.text('返回推荐'),
        matching: find.byType(OutlinedButton),
      )).onPressed,
      isNotNull,
      reason: '按钮必须可点击（原来搜索结束后是 null）',
    );

    await tester.tap(button);
    await tester.pump();

    expect(find.text('热门推荐'), findsOneWidget, reason: '应回到落地页');
    expect(find.text('搜索历史'), findsOneWidget);
  });

  testWidgets('搜索在途时按钮是「取消」（保留原可取消语义）', (tester) async {
    await prepare(tester);
    await pumpPage(tester);

    // 挂住站点响应 → 搜索保持在途。
    // 不能靠 `unawaited(submitSearch(...))` 制造在途：`WidgetTester` 的 API 是
    // 受保护的（抛 Guarded function conflict），必须 await。
    siteClient.hold = Completer<void>();
    await tester.enterText(find.byKey(const ValueKey('search-input')), '测试');
    await tester.pump(const Duration(milliseconds: 320)); // 越过联想防抖
    await tester.tap(find.text('搜索'));
    await tester.pump();

    expect(find.text('取消'), findsOneWidget);
    expect(find.text('返回推荐'), findsNothing);

    // 放行让在途批次结束，避免残留状态影响其它用例。
    siteClient.hold!.complete();
    siteClient.hold = null;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump();
  });

  testWidgets('点击相似度 chip 生效并写入偏好（内存值）', (tester) async {
    await prepare(tester, similarity: 0);
    await pumpPage(tester);
    // 筛选条只在有结果时渲染，因此必须先搜一次。
    await submitSearch(tester, '测试');
    expect(state.searchSimilarity, 0);

    await tester.tap(find.byKey(const ValueKey('search-similarity-100')));
    await tester.pump();

    // 只断言内存生效（无 I/O，fake-async 区可靠）；磁盘往返由
    // `phase2_search_test.dart` 的普通 test() 覆盖（那里没有 fake-async 区）。
    expect(state.searchSimilarity, 100);
  });
}

/// 假站点客户端：`wd` 请求按 `pg` 返回分页搜索结果，其余返回空首页。
///
/// 分页契约：每站点共 3 页，第 N 页返回 `demo-N`；`pagecount=3` 让
/// `hasMore` 为真（分页 UI 才会出现「加载更多」）。
class _FakeSiteClient extends http.BaseClient {
  int searchRequests = 0;

  /// 已请求过的 `pg` 值（升序去重），供断言「自动续翻是否只该翻一次」。
  final List<int> requestedPages = [];

  /// 非 null 时挂住响应，用来构造「搜索**在途**」状态。
  ///
  /// 为什么需要：假客户端的响应在一个微任务内就返回，而「在途」正是
  /// 「取消 / 返回推荐」两种按钮语义之一；也不能靠 `unawaited(tester.xxx)`
  /// 制造在途（`WidgetTester` 的 API 受保护，必须 await）。
  Completer<void>? hold;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final gate = hold;
    if (gate != null) await gate.future;
    final query = request.url.queryParameters;
    final payload = query.containsKey('wd')
        ? _searchPayload(query)
        : {'class': [], 'list': []};
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(jsonEncode(payload))),
      200,
    );
  }

  Map<String, Object?> _searchPayload(Map<String, String> query) {
    searchRequests++;
    final page = int.tryParse(query['pg'] ?? '1') ?? 1;
    if (!requestedPages.contains(page)) requestedPages.add(page);
    return {
      'page': page,
      'pagecount': 3,
      'limit': 20,
      'total': 3,
      'list': [
        {
          'vod_id': 'demo-$page',
          'vod_name': page == 1 ? '测试视频' : '测试视频$page',
          'vod_pic': '',
          'vod_remarks': '第 $page 集',
        },
      ],
    };
  }
}

/// 假联想/榜单服务：不打外网，返回可断言的固定词表。
///
/// [hotCount] 可调：验证「按宽高恰好铺满」与「换一批」需要**比一屏更大**的
/// 候选池（默认 12 条）；而「池子不比一屏大」时需要调小，那时不该出现「换一批」。
class _FakeSuggestService extends SearchSuggestService {
  _FakeSuggestService()
    : super(client: http.Client(), timeout: const Duration(seconds: 1));

  /// 榜单候选池条数（用例直接调它，无需构造参数）。
  int hotCount = 12;

  static const List<String> _numerals = [
    '一',
    '二',
    '三',
    '四',
    '五',
    '六',
    '七',
    '八',
    '九',
    '十',
    '十一',
    '十二',
  ];

  @override
  Future<List<SearchSuggestItem>> suggest(String keyword) async => [
    SearchSuggestItem(title: '$keyword 联想词一'),
    SearchSuggestItem(title: '$keyword 联想词二'),
  ];

  @override
  Future<List<SearchSuggestItem>> hotRank(HotRankCategory category) async => [
    for (var i = 0; i < hotCount; i++)
      SearchSuggestItem(
        title: '${category.label}热榜第${_numerals[i % _numerals.length]}条',
        cover: 'https://p3.qhimg.com/d/${category.name}-$i.jpg',
        subtitle: category == HotRankCategory.variety
            ? '2026-10-13期'
            : (i == 0
                  ? '全47集'
                  : (i == 1 ? '全22集' : '全${40 + i}集')),
        // 只有第一条有评分：验证「没评分就不画空角标」。
        score: i == 0 ? '5.3' : null,
        detailUrl: 'http://www.360kan.com/tv/${category.name}-$i.html',
        rank: i + 1,
      ),
  ];
}
