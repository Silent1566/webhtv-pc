/// 设置页分类导航（`docs/superpowers/plans/settings-categories.md` 的 UI Task）。
///
/// ## 这一组用例锁什么
///
/// 「设置 + 一张长页」被否掉过两次：先是宽窗把「偏好+播放」与「连接与增强+
/// 维护与说明」**两张内容列并排堆叠**，一屏两列同时展开；随后是「高级设置」
/// 中枢整页——它把 18 行混在一个入口下面，播放参数要三级才到。现在的形态是
/// **五个按用途划分的分类 + 每类单列**，任意设置最多两级可达。回归锁必须能抓到
/// 下面每一种退回旧形态的实现：
///
/// 1. 默认不是「偏好」，或五个稳定分类 key 缺失/重名/多出一份；
/// 2. 当前类别之外的类别内容仍然渲染（=又变成多列同时可见）；
/// 3. 切类别时顺手写盘（分类只影响显示，不是配置项）；
/// 4. 键盘不可达（只能用鼠标点）；
/// 5. 切回来类别后滚动位置归零（各类别滚动不保留）；
/// 6. 480/720/1024/宽窗、暗/亮任一档溢出或导航与正文糊在一起
///    （矮窗单列一档：480×320 与左栏 1024×300，见「矮窗：…」）；
/// 7. 正文又退回两列；
/// 8. 再挂一个 `NavigationRail`（外壳已有一个）；
/// 9. 旧功能/旧业务事实被搬走或改写（主题选择不再写进 `AppState`）；
/// 10. 屏显这类**成组开关**又回到分类页里就地摊开（结构锁，见「点击类别切换」）。
///
/// ## 为什么用 `tester.getSemantics`
///
/// 选中态必须是**公开语义**，不只是内部 `_category` 字段：视觉组按五个
/// 稳定 key 读 `SemanticsFlag.isSelected`。内部字段对调用方不可见，
/// 断言它等于把测试绑在实现上。
///
/// ## 为什么所有配置写入都包在 `tester.runAsync` 里
///
/// 与 `phase8_settings_entries_test.dart` 同因：`UiPreferencesStore._persistQueue`
/// 在 `setUp` 的**真实** zone 里创建，续体落在真实事件循环，`FakeAsync` 推不动。
/// 详见该文件头注释与 `docs/phase8/design/05` §1.2。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/diagnostics_pages.dart';
import 'package:webhtv_pc/ui/osd_settings_page.dart';
import 'package:webhtv_pc/ui/theme.dart';

// Reject unsafe paths before bootstrap can access storage.
void _requireIsolatedPaths(AppPaths paths, Directory temp) {
  for (final dir in [
    paths.configDir,
    paths.dataDir,
    paths.cacheDir,
    paths.logDir,
  ]) {
    expect(
      p.isWithin(temp.path, dir),
      isTrue,
      reason: 'Test directory must remain beneath its owned temp directory',
    );
  }
}

void main() {
  late Directory temp;
  late AppState state;
  var stateCreated = false;

  setUp(() async {
    stateCreated = false;
    temp = Directory.systemTemp.createTempSync('webhtv-settings-categories');
    final paths = AppPaths.resolve(
      overrides: {
        'config': p.join(temp.path, 'config'),
        'data': p.join(temp.path, 'data'),
        'cache': p.join(temp.path, 'cache'),
        'state': p.join(temp.path, 'logs'),
      },
    );
    _requireIsolatedPaths(paths, temp);
    state = AppState(paths: paths, log: LogService());
    stateCreated = true;
    await state.bootstrap();
  });

  tearDown(() {
    if (stateCreated) state.dispose();
    try {
      temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// 有界 $pumpAndSettle（5 秒），理由见 $phase8_settings_entries_test.dart。
  Future<void> settle(WidgetTester tester) => tester.pumpAndSettle(
    const Duration(milliseconds: 50),
    EnginePhase.sendSemanticsUpdate,
    const Duration(seconds: 5),
  );

  /// 五个稳定分类 key（固定接口，宽窄一致）。
  const categories = <String>[
    'settings-category-preferences',
    'settings-category-playback',
    'settings-category-sites',
    'settings-category-connections',
    'settings-category-maintenance',
  ];

  /// 每个类别在分类页上**独有**的入口 key：用来判断「当前类别内容独占」。
  ///
  /// 标记只取留在**分类页**的控件：屏显的 7 个开关已进 $OsdSettingsPage，
  /// 站点健康的明细表在 $SiteHealthPage，因此这里用的是各自的行入口。
  const categoryMarker = <String, String>{
    'settings-category-preferences': 'settings-theme-mode',
    'settings-category-playback': 'settings-player-buttons',
    'settings-category-sites': 'settings-site-health-open',
    'settings-category-connections': 'settings-ai-open',
    'settings-category-maintenance': 'settings-python-environment-open',
  };

  Finder categoryFinder(String key) => find.byKey(ValueKey(key));
  Finder markerFinder(String key) => find.byKey(ValueKey(categoryMarker[key]!));
  Finder contentFinder(String id) =>
      find.byKey(ValueKey('settings-category-content-$id'));

  /// 当前类别内容区的滚动位置。
  ///
  /// 读 $ListView.controller（公开字段）而不是 $Scrollable 位置：维护类别里
  /// 有 $SelectableText，它自带内部 $Scrollable，按类型找会命中一堆。
  double contentOffset(WidgetTester tester, String id) {
    final controller = tester.widget<ListView>(contentFinder(id)).controller;
    expect(controller, isNotNull, reason: '类别 $id 的内容列表必须挂自己的控制器');
    expect(controller!.hasClients, isTrue, reason: '类别 $id 的内容列表应已挂载（否则读不到位置）');
    return controller.offset;
  }

  /// 挂载设置页；宽窗时套一个外壳 $NavigationRail（复现真实产品结构）。
  Future<void> pumpSettings(
    WidgetTester tester, {
    Size size = const Size(1440, 900),
    Brightness brightness = Brightness.dark,
    bool withShell = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final page = ListenableBuilder(
      listenable: state,
      builder: (context, child) => Scaffold(body: SettingsPage(state: state)),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(brightness),
        home: withShell
            ? Scaffold(
                body: Row(
                  children: [
                    NavigationRail(
                      selectedIndex: 1,
                      onDestinationSelected: (_) {},
                      minWidth: 76,
                      labelType: NavigationRailLabelType.all,
                      destinations: const [
                        NavigationRailDestination(
                          icon: Icon(Icons.grid_view),
                          label: Text('首页'),
                        ),
                        NavigationRailDestination(
                          icon: Icon(Icons.tune),
                          label: Text('设置'),
                        ),
                      ],
                    ),
                    Expanded(child: page),
                  ],
                ),
              )
            : page,
      ),
    );
    await settle(tester);
  }

  testWidgets('默认进入偏好类别：五个稳定 key 各恰好一处，其余类别不渲染', (tester) async {
    await pumpSettings(tester);

    // ① 五个分类 key 各**恰好一处**（宽窄共用一个 key，同一时刻只渲染一套）。
    for (final key in categories) {
      expect(
        categoryFinder(key),
        findsOneWidget,
        reason: '缺少稳定分类控件 $key（宽窗与窄窗都必须存在，且各只有一个）',
      );
    }

    /// 分类控件（不含正文内容区）的 key 形态。
    bool isCategoryControl(Widget widget) {
      final key = widget.key;
      if (key is! ValueKey<String>) return false;
      return key.value.startsWith('settings-category-') &&
          !key.value.startsWith('settings-category-content-');
    }

    expect(
      find.byWidgetPredicate(isCategoryControl),
      findsNWidgets(categories.length),
      reason: '分类控件总数必须恰好 5 个（多出一个 = 两套导航同时渲染）',
    );

    // 默认偏好：只断言业务标记 key，不断言文案（导航标签与区块标题共用词）。
    expect(
      markerFinder('settings-category-preferences'),
      findsOneWidget,
      reason: '默认类别应为「偏好」',
    );
    for (final key in categories.skip(1)) {
      expect(
        markerFinder(key),
        findsNothing,
        reason: '$key 的内容不得与当前类别同时渲染（否则又退回多列同时展开）',
      );
      expect(
        contentFinder(key.replaceFirst('settings-category-', '')),
        findsNothing,
        reason: '$key 的内容区不得与当前类别同时挂载',
      );
    }

    // 偏好类别的旧内容原样还在（原基线的前两项业务事实）。
    expect(
      find.byKey(const ValueKey('settings-history-click-action')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('settings-search-thread')),
      findsOneWidget,
    );
  });

  testWidgets('点击类别切换：当前类别独占，且选中语义跟着走', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpSettings(tester);

    // 前置：默认偏好的选中语义为真，其余为假。
    expect(
      tester.getSemantics(categoryFinder('settings-category-preferences')),
      isSemantics(isSelected: true),
      reason: '默认类别必须有公开选中语义',
    );
    expect(
      tester.getSemantics(categoryFinder('settings-category-playback')),
      isSemantics(isSelected: false),
      reason: '非当前类别必须**明确**为未选中（不是没有语义）',
    );

    await tester.tap(categoryFinder('settings-category-playback'));
    await settle(tester);

    expect(markerFinder('settings-category-playback'), findsOneWidget);
    expect(
      markerFinder('settings-category-preferences'),
      findsNothing,
      reason: '切到播放后，偏好内容必须消失（内容独占）',
    );
    // 屏显已从「播放」类里就地展开的 7 个开关改成一行入口 → 独立明细页。
    // 结构锁：**成组开关块不得回到分类页**。这里同时正向锁入口行、反向锁区块。
    expect(
      find.byKey(const ValueKey('settings-osd-open')),
      findsOneWidget,
      reason: '播放类必须有「屏显（OSD）」入口行',
    );
    expect(
      find.byKey(const ValueKey('settings-osd')),
      findsNothing,
      reason: '屏显开关必须只在 OsdSettingsPage 里（分类页不得再就地摊开成组开关）',
    );
    for (final id in const [
      'title',
      'size',
      'time',
      'progress',
      'traffic',
      'mini',
      'diagnostics',
    ]) {
      expect(
        find.byKey(ValueKey('settings-osd-$id'), skipOffstage: false),
        findsNothing,
        reason: '屏显开关 settings-osd-$id 不得挂在分类页上',
      );
    }
    expect(
      tester.getSemantics(categoryFinder('settings-category-playback')),
      isSemantics(isSelected: true),
    );
    expect(
      tester.getSemantics(categoryFinder('settings-category-preferences')),
      isSemantics(isSelected: false),
    );

    // 新增的第五类「站点与内容」也必须能选中并独占正文。
    await tester.tap(categoryFinder('settings-category-sites'));
    await settle(tester);
    expect(markerFinder('settings-category-sites'), findsOneWidget);
    expect(markerFinder('settings-category-playback'), findsNothing);
    expect(
      tester.getSemantics(categoryFinder('settings-category-sites')),
      isSemantics(isSelected: true),
    );
    expect(
      tester.getSemantics(categoryFinder('settings-category-playback')),
      isSemantics(isSelected: false),
    );

    // 反向：切回偏好必须复原，不是单向跳转。
    await tester.tap(categoryFinder('settings-category-preferences'));
    await settle(tester);
    expect(markerFinder('settings-category-preferences'), findsOneWidget);
    expect(markerFinder('settings-category-playback'), findsNothing);
    expect(markerFinder('settings-category-sites'), findsNothing);

    // $skipOffstage: false：未选类别**连离屏 widget 都不存在**，因此它们
    // 既不会进入 Tab 焦点路径，也不会被屏幕阅读器读到——「保留滚动位置」
    // 不得靠挂载隐藏列表来换。
    for (final key in categories.skip(1)) {
      expect(
        find.byKey(ValueKey(categoryMarker[key]!), skipOffstage: false),
        findsNothing,
        reason: '$key 的内容不得以离屏形态挂在树里（会污染焦点路径与读屏）',
      );
    }

    handle.dispose();
  });

  testWidgets('五个类别都可达各自旧入口（分类只是显示分组，入口一个不少）', (tester) async {
    await pumpSettings(tester);
    for (final key in categories) {
      await tester.tap(categoryFinder(key));
      await settle(tester);
      expect(
        markerFinder(key),
        findsOneWidget,
        reason: '类别 $key 选中后必须能看到自己的内容入口',
      );
    }
  });

  testWidgets('切类别不写盘：分类是纯 UI 状态', (tester) async {
    await pumpSettings(tester);
    final before = File(state.paths.settingsPath).readAsBytesSync();

    for (final key in categories.skip(1)) {
      await tester.tap(categoryFinder(key));
      await settle(tester);
    }
    // 比对前后**字节**：分类切换只要碰过任何偏好就会被抓到（包括把
    // 「当前分类」写进文件这种实现）。
    final after = File(state.paths.settingsPath).readAsBytesSync();
    expect(
      after,
      before,
      reason: '切换分类不得写 settings.json（分类不是配置项，重启后也不该被记住到文件里）',
    );
    // 业务值本身也没被顺带改掉。
    expect(state.themeMode, 'dark', reason: '前置：默认暗色');
    expect(state.historyClickAction, 'detail', reason: '前置：默认进入详情页');
  });

  testWidgets('键盘可达：Tab 进入分类栏，方向键移动，回车切换类别', (tester) async {
    await pumpSettings(tester);

    /// 当前焦点落在哪个分类控件上（通过真实键盘焦点走查，不碰私有状态）。
    String? focusedCategory() {
      final context = FocusManager.instance.primaryFocus?.context;
      if (context == null) return null;
      final semantics = context.findAncestorWidgetOfExactType<Semantics>();
      final key = semantics?.key;
      if (key is ValueKey<String> &&
          key.value.startsWith('settings-category-')) {
        return key.value;
      }
      return null;
    }

    // 逐个 Tab 直到进入分类栏（导航在树里先于正文，所以它是第一个焦点组）。
    for (var i = 0; i < 8 && focusedCategory() == null; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
    }
    expect(
      focusedCategory(),
      'settings-category-preferences',
      reason: 'Tab 必须能把焦点带进分类栏（第一项是默认类别）',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(
      focusedCategory(),
      'settings-category-playback',
      reason: '方向键必须能在分类之间移动焦点',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle(tester);
    expect(
      markerFinder('settings-category-playback'),
      findsOneWidget,
      reason: '回车必须真的切换类别（只移动焦点不激活 = 键盘半残）',
    );
    expect(markerFinder('settings-category-preferences'), findsNothing);

    // 空格键同样可用（原生按钮语义，而不是自定义快捷键）。
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await settle(tester);
    expect(
      markerFinder('settings-category-playback'),
      findsOneWidget,
      reason: '空格在已选中的分类上重放不得把页面打乱',
    );
  });

  testWidgets('各分类滚动位置独立保留：切走再回来不回到顶部', (tester) async {
    // 矮视口：播放与连接两类的内容都必须比它高，两个位置才都可区分。
    //
    // 340 是**矮窗下限附近的取样**（不是随便取的小数）：
    // 五类左栏的内容高约「16 上内边距 + 页标题 + 5×(48 行 + 4 间距)」≈ 300+，
    // 340 高时栏只剩约 224（页内边距与页标题之后），5 类塞不下——源码因此把栏
    // 包进 SingleChildScrollView（diagnostics_pages.dart:708），栏自己滚、五项都在；
    // 340 高时内容区约 240，播放类（7 行）与连接类（6 行）都高过它，
    // 两个位置都非零且彼此不同，滚动保留才有区分力。
    await pumpSettings(tester, size: const Size(1440, 340));

    await tester.tap(categoryFinder('settings-category-playback'));
    await settle(tester);
    expect(contentOffset(tester, 'playback'), 0, reason: '首次进入应在顶部');

    await tester.drag(contentFinder('playback'), const Offset(0, -220));
    await settle(tester);
    final playbackOffset = contentOffset(tester, 'playback');
    expect(
      playbackOffset,
      greaterThan(0),
      reason: '前置：播放类别必须真的滚下去了（否则下面的保留断言没有区分力）',
    );

    // 另一个类别也滚一下，两个位置必须**各自**独立。
    await tester.tap(categoryFinder('settings-category-connections'));
    await settle(tester);
    expect(contentOffset(tester, 'connections'), 0, reason: '连接类别是新进入的，应从头开始');
    await tester.drag(contentFinder('connections'), const Offset(0, -120));
    await settle(tester);
    final connectionsOffset = contentOffset(tester, 'connections');
    expect(connectionsOffset, greaterThan(0), reason: '前置：连接类别也要滚下去');
    expect(connectionsOffset, isNot(playbackOffset), reason: '两个类别的滚动位置应各自独立');

    await tester.tap(categoryFinder('settings-category-playback'));
    await settle(tester);
    expect(
      contentOffset(tester, 'playback'),
      playbackOffset,
      reason: '切回播放必须恢复原滚动位置（分类切换不丢位置）',
    );

    await tester.tap(categoryFinder('settings-category-connections'));
    await settle(tester);
    expect(
      contentOffset(tester, 'connections'),
      connectionsOffset,
      reason: '切回连接必须恢复自己的滚动位置',
    );
  });

  testWidgets('子页面原生返回后保留播放分类和非零滚动位置', (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      await pumpSettings(tester, size: const Size(1440, 420));
      await tester.tap(categoryFinder('settings-category-playback'));
      await settle(tester);

      await tester.drag(contentFinder('playback'), const Offset(0, -120));
      await settle(tester);
      // 落点：屏显从「播放类里就地展开的 7 个开关」改成一行入口 → 独立明细页。
      final entry = find.byKey(const ValueKey('settings-osd-open'));
      await tester.ensureVisible(entry);
      await settle(tester);
      final before = contentOffset(tester, 'playback');
      expect(before, greaterThan(0), reason: '必须从非零位置进入子页，才能抓到返回时归零');
      expect(entry.hitTestable(), findsOneWidget, reason: '屏显入口必须真实可点');

      await tester.tap(entry);
      await settle(tester);
      expect(
        find.byType(OsdSettingsPage),
        findsOneWidget,
        reason: '原入口必须真的进入屏显明细页，不是空壳路由',
      );
      expect(
        find.byKey(const ValueKey('settings-osd-title')),
        findsOneWidget,
        reason: '明细页必须真的渲染了屏显开关',
      );
      expect(contentFinder('playback'), findsNothing, reason: '子页面应遮住原设置页');

      await tester.tap(find.byType(BackButton));
      await settle(tester);
      expect(find.byKey(const ValueKey('settings-osd-title')), findsNothing);
      expect(
        tester.getSemantics(categoryFinder('settings-category-playback')),
        isSemantics(isSelected: true),
        reason: '原生返回后必须仍在播放类别，不得重置为偏好',
      );
      expect(
        tester.getSemantics(categoryFinder('settings-category-preferences')),
        isSemantics(isSelected: false),
      );
      expect(contentFinder('preferences'), findsNothing);
      expect(
        contentOffset(tester, 'playback'),
        closeTo(before, 0.01),
        reason: '原生返回后当前 ListView 的公开 controller.offset 必须保持进入前的位置',
      );
      expect(entry.hitTestable(), findsOneWidget);

      // 真实配置写入会 notifyListeners，宿主 ListenableBuilder 与 AppShell
      // 一样重建 SettingsPage；这次重建也不得重置分类或滚动位置。
      expect(state.searchThread, 20);
      var notifications = 0;
      void notified() => notifications++;
      state.addListener(notified);
      try {
        await tester.runAsync(() => state.setSearchThread(37));
        final persisted = jsonDecode(
          File(state.paths.settingsPath).readAsStringSync(),
        ) as Map<String, dynamic>;
        expect(
          (persisted['ui'] as Map)['searchThread'],
          37,
          reason: '隔离配置必须真正保存到文件',
        );
        await settle(tester);
        expect(notifications, greaterThan(0), reason: '必须触发真实 state 通知');
        expect(state.searchThread, 37);
        expect(
          tester.getSemantics(categoryFinder('settings-category-playback')),
          isSemantics(isSelected: true),
          reason: '真实配置保存通知宿主重建后仍在播放类别',
        );
        expect(
          tester.getSemantics(categoryFinder('settings-category-preferences')),
          isSemantics(isSelected: false),
        );
        for (final id in const [
          'preferences',
          'sites',
          'connections',
          'maintenance',
        ]) {
          expect(contentFinder(id), findsNothing, reason: '宿主重建后仍只挂当前类别');
        }
        expect(contentOffset(tester, 'playback'), closeTo(before, 0.01));
      } finally {
        state.removeListener(notified);
      }
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('宽窄 × 暗亮都不溢出，且导航与正文分离', (tester) async {
    // 480 = 极窄（分类挪到顶部）；720/1024 = 中等；1440 = 宽桌面。
    const widths = <double>[480, 720, 1024, 1440];
    for (final brightness in Brightness.values) {
      for (final width in widths) {
        await pumpSettings(
          tester,
          size: Size(width, 800),
          brightness: brightness,
        );

        expect(
          tester.takeException(),
          isNull,
          reason: '$brightness @ ${width}px：布局溢出（RenderFlex overflow）',
        );

        for (final key in categories) {
          expect(
            categoryFinder(key),
            findsOneWidget,
            reason: '$brightness @ ${width}px：分类控件 $key 缺失或重复',
          );
        }

        // 导航与正文不得重叠：宽窗左右分栏，窄窗上下分层。
        final navRect = tester.getRect(
          categoryFinder('settings-category-preferences'),
        );
        final contentRect = tester.getRect(contentFinder('preferences'));
        if (width >= 900) {
          expect(
            navRect.right,
            lessThanOrEqualTo(contentRect.left),
            reason: '$brightness @ ${width}px：宽窗分类导航应在正文左侧且不与正文重叠',
          );
        } else {
          expect(
            navRect.bottom,
            lessThanOrEqualTo(contentRect.top),
            reason: '$brightness @ ${width}px：窄窗分类应移到正文上方',
          );
        }
      }
    }
  });

  testWidgets('矮窗：480×320 与 1024×300 不溢出，五个分类仍逐个点得动', (tester) async {
    // 分类从 4 类增到 5 类后，左栏内容高「5×(48 行 + 4 间距)」≈ 260，矮窗放不下：
    // 源码把左栏包进 SingleChildScrollView（diagnostics_pages.dart:708）。
    // 所以「不溢出」必须和「第 5 类真的点得到并切过去」一起断言 —— 少画一个分类
    // 同样不溢出，但那是把分类弄丢；只断言 key 存在也抓不到「按不到」。
    const viewports = <Size>[Size(480, 320), Size(1024, 300)];
    final semantics = tester.ensureSemantics();
    try {
      for (final size in viewports) {
        final where = '${size.width}×${size.height}';
        await pumpSettings(tester, size: size);
        expect(tester.takeException(), isNull, reason: '$where：设置首页布局溢出');

        for (final key in categories) {
          expect(
            categoryFinder(key),
            findsOneWidget,
            reason: '$where：分类控件 $key 缺失或重复（矮窗不许靠少画一个换不溢出）',
          );
        }

        // 宽窗（≥720）走左栏：栏必须**自身**可滚，才证明上面的不溢出是
        // 「滚得到」而不是「画不下就不画」。
        if (size.width >= 720) {
          final railScrollable = find
              .ancestor(
                of: categoryFinder('settings-category-preferences'),
                matching: find.byType(Scrollable),
              )
              .first;
          expect(
            tester
                .state<ScrollableState>(railScrollable)
                .position
                .maxScrollExtent,
            greaterThan(0),
            reason: '$where：5 类放不下，左栏必须自己可滚（否则溢出的只是被裁掉）',
          );
        }

        // 逐个类别：滚到可见 → 命中测试通过 → 点下去真的切换（内容标记 + 选中语义）。
        for (final key in categories) {
          final control = categoryFinder(key);
          final id = key.replaceFirst('settings-category-', '');
          await tester.ensureVisible(control);
          await settle(tester);
          expect(
            control.hitTestable(),
            findsOneWidget,
            reason: '$where：$key 滚到可见后必须真的可点',
          );
          await tester.tap(control);
          await settle(tester);
          expect(tester.takeException(), isNull, reason: '$where：切到 $id 后不得溢出');
          expect(
            markerFinder(key),
            findsOneWidget,
            reason: '$where：点了 $key 就必须渲染该类内容（不是空切）',
          );
          for (final other in categories.where((k) => k != key)) {
            expect(
              markerFinder(other),
              findsNothing,
              reason: '$where：切到 $id 后 $other 的内容必须消失（仍只渲染当前类）',
            );
          }
          expect(
            tester.getSemantics(control),
            isSemantics(isSelected: true),
            reason: '$where：$key 的选中语义必须跟着切换走',
          );
        }
      }
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('正文是限定宽度的单列，不是并列的两张表单', (tester) async {
    await pumpSettings(tester, size: const Size(1440, 1000));

    // 同一类别内两块内容必须同左边界 —— 两列布局下它们的 left 会相差半个
    // 内容宽度，这条断言就是退化的检测器。
    final theme = tester.getRect(
      find.byKey(const ValueKey('settings-theme-mode')),
    );
    final search = tester.getRect(
      find.byKey(const ValueKey('settings-search-thread')),
    );
    expect(search.left, theme.left, reason: '偏好类别内两块内容应同左对齐（单列）');

    // 不再断言「同宽」：搜索入口改回**固有宽度**（「调整搜索线程」是一枚按钮，
    // 撑满整行会让它看起来像第二个表单区，而不是单列里的一个动作）。
    // 单列的判据换成「都贴内容区左缘、且都不越过内容区右缘」——两列布局下
    // 并列的第二块会从半个内容宽度处开始，仍然会被 left 断言抓到。
    final content = tester.getRect(contentFinder('preferences'));
    expect(
      search.right,
      lessThanOrEqualTo(content.right),
      reason: '搜索入口不得越过内容区右缘（越界即意味着被切成两列）',
    );
    expect(search.width, lessThan(content.width), reason: '按钮按内容取宽，不得撑满整个内容区');
    expect(
      theme.width,
      lessThanOrEqualTo(content.width),
      reason: '内容宽度不得超出内容区',
    );
  });

  testWidgets('不新增第二个 NavigationRail（外壳已有一个）', (tester) async {
    await pumpSettings(tester, withShell: true);
    expect(
      find.byType(NavigationRail),
      findsOneWidget,
      reason: '设置页分类导航不得用 NavigationRail 再挂一个（外壳已有一个）',
    );
    for (final key in categories) {
      await tester.tap(categoryFinder(key));
      await settle(tester);
      expect(
        find.byType(NavigationRail),
        findsOneWidget,
        reason: '切换到 $key 后仍只能有一个 NavigationRail',
      );
    }
  });

  testWidgets('旧功能仍真的生效：分类导航里的主题选择照旧写进 AppState', (tester) async {
    await pumpSettings(tester);
    expect(state.themeMode, 'dark', reason: '前置：默认暗色');

    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('settings-theme-mode')),
        matching: find.text('亮色'),
      ),
    );
    // 写盘续体落在真实事件循环（见文件头注释）：交替「推进一帧 → 给真实 I/O
    // 一点时间」，直到界面收敛。**不得**在这之后手动 setThemeMode——
    // 那会让断言变成对自身的镜像，点坏了也通过。
    for (var round = 0; round < 12; round++) {
      await tester.pump(const Duration(milliseconds: 16));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 16)),
      );
    }
    await settle(tester);

    expect(
      state.themeMode,
      'light',
      reason: '新布局里点「亮色」必须仍然改变主题状态（业务事实不得随布局搬走）',
    );
    expect(
      tester
          .widget<SegmentedButton<ThemeMode>>(
            find.byKey(const ValueKey('settings-theme-mode')),
          )
          .selected,
      {ThemeMode.light},
      reason: '控件回显必须跟着状态走（不是只改内存）',
    );
  });
}
