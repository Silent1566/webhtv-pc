/// Phase 8 · Task 10：设置页的「屏显」与「播放器按钮」两个入口
/// （`docs/phase8/design/02` §5.1、`design/03` §6.1、`design/05` §3.4 C13）。
///
/// ## 断言策略
///
/// 正向断言**精确值**，不用「不抛异常」这类空洞断言。每条用例的注释写明
/// 「什么错误实现会仍然通过」，并据此补断言。
///
/// ## 为什么所有配置写入都必须包在 `tester.runAsync` 里
///
/// `setUp` 跑在**真实**事件循环 zone；`testWidgets` 的函数体跑在 **`FakeAsync`**。
/// `UiPreferencesStore._persistQueue`（`ui_preferences_store.dart:469`）是
/// `setUp` 那个 zone 里造出来的 `Future`，`Future.then` 会按**该 Future 自己的
/// zone** 去 `scheduleMicrotask`（`_Future._addListener` 用的是 `_zone`），
/// 于是续体落在真实事件循环上，`FakeAsync` 永远不推进它。在 `testWidgets` 里
/// 直接 `await state.setOsdFlag(...)` 会挂到 10 分钟超时，并让后续用例连锁报
/// `Guarded function conflict`（那个报错是假象）。详见
/// `docs/phase8/design/05` §1.2。
///
/// `pumpAndSettle` 一律用**有界超时**（5s）：将来再出现挂起是几秒失败，
/// 而不是 10 分钟。
///
/// ## 分类导航（设置页改为「左分类 + 右单列」之后）
///
/// 设置页默认落在 `preferences`（偏好），屏显与播放器按钮属于 `playback`
/// （播放），因此每条用例在挂载后先经 `selectSettingsCategory` 显式选类，
/// 再执行原有断言。旧写法里「不同类别的入口必须在同一个首屏同时可见」不再成立，
/// 那条约束改为「选类后可达」；业务断言一条未删。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/osd_config.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/diagnostics_pages.dart';
import 'package:webhtv_pc/ui/player_button_config_page.dart';
import 'package:webhtv_pc/ui/theme.dart';

import 'support/settings_navigation.dart';

void main() {
  late Directory temp;
  late AppState state;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('webhtv-phase8-settings');
    final paths = AppPaths.resolve(
      overrides: {
        'config': '${temp.path}/webhtv-pc',
        'data': '${temp.path}/webhtv-pc',
        'cache': '${temp.path}/webhtv-pc/cache',
        'state': '${temp.path}/webhtv-pc/logs',
      },
    );
    state = AppState(paths: paths, log: LogService());
    await state.bootstrap();
  });

  tearDown(() {
    state.dispose();
    try {
      temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// 有界 `pumpAndSettle`：3 参形式，超时 5 秒（见文件头注释）。
  Future<void> settle(WidgetTester tester) => tester.pumpAndSettle(
    const Duration(milliseconds: 50),
    EnginePhase.sendSemanticsUpdate,
    const Duration(seconds: 5),
  );

  /// 交替「推进一帧 → 给真实 I/O 一点时间」，直到界面收敛。
  ///
  /// 为什么不能只 `tap + settle`：`AppState.setOsdFlag` 的形状是
  /// 「**同步**改内存 → `await _persist()` → `notifyListeners()`」
  /// （`app_state.dart:578-584`）。内存值点完立刻就是对的，但**界面刷新**
  /// 挂在 `notifyListeners` 上，而它要等写盘 Future 完成——那个续体落在
  /// **真实**事件循环上（见文件头注释），`pumpAndSettle` 的假时钟推不动它。
  /// 于是开关的 `value` 停在旧值，第二次点击会用**陈旧的 `value`** 再发一次
  /// 同一个方向的值，往返断言就会失败（实测确认）。
  ///
  /// 这是本仓库既有做法（`phase5_sync_ui_test.dart:176-198` 的 `settleIo`
  /// 同款机制），不是为这条用例特制的东西。
  Future<void> settleIo(WidgetTester tester, {int rounds = 12}) async {
    for (var round = 0; round < rounds; round++) {
      await tester.pump(const Duration(milliseconds: 16));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 16)),
      );
    }
    await settle(tester);
  }

  /// 在真实 zone 里完成一次配置写入（见文件头注释）。
  Future<void> configure(
    WidgetTester tester,
    Future<bool> Function() write,
  ) async {
    await tester.runAsync(() async {
      await write();
    });
  }

  /// 保留真实应用的 AppState 监听装配；挂载后显式选择目标类别。
  Future<void> pumpSettings(
    WidgetTester tester, {
    Size size = const Size(1500, 3400),
    String category = 'playback',
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.dark),
        home: ListenableBuilder(
          listenable: state,
          builder: (context, child) =>
              Scaffold(body: SettingsPage(state: state)),
        ),
      ),
    );
    await settle(tester);
    await selectSettingsCategory(tester, category);
  }

  Finder settingsScrollable() => find
      .byWidgetPredicate(
        (widget) =>
            widget is Scrollable && widget.axisDirection == AxisDirection.down,
      )
      .last;

  /// 屏显开关的中文名（`docs/phase8/design/02` §5.1 的表格逐字）。
  const osdLabels = <String, String>{
    OsdFlag.title: '标题',
    OsdFlag.size: '分辨率',
    OsdFlag.time: '时钟',
    OsdFlag.progress: '播放进度',
    OsdFlag.traffic: '网速',
    OsdFlag.mini: '迷你进度条',
    OsdFlag.diagnostics: '诊断面板',
  };

  Finder osdBlock() => find.byKey(const ValueKey('settings-osd'));
  Finder osdTile(String id) => find.byKey(ValueKey('settings-osd-$id'));

  /// 读回 `settings.json` 的 `ui.osd` 段原文。
  Map<String, Object?> persistedOsd() {
    final root = jsonDecode(
      File(state.paths.settingsPath).readAsStringSync(),
    ) as Map<String, Object?>;
    final ui = (root['ui'] as Map?)?.cast<String, Object?>();
    return (ui?['osd'] as Map?)?.cast<String, Object?>() ?? const {};
  }

  testWidgets('屏显区块存在，7 项开关齐全且中文名逐项正确', (tester) async {
    await pumpSettings(tester);

    expect(osdBlock(), findsOneWidget, reason: '设置页必须有屏显区块');

    // 逐项断言**精确中文名**，而不是「区块里有个开关」。
    // 什么错误实现会仍然通过：`_osdLabel` 整个删掉、直接 `Text(id)` 显示
    // 英文 id —— 那样每个 tile 仍然存在，只有这条精确文案断言能抓到。
    for (final id in OsdFlag.values) {
      expect(osdTile(id), findsOneWidget, reason: '缺少屏显开关「$id」');
      expect(
        find.descendant(of: osdTile(id), matching: find.text(osdLabels[id]!)),
        findsOneWidget,
        reason: '「$id」的中文名应为「${osdLabels[id]}」',
      );
    }

    // 反向：区块内**恰好** 7 个 `SwitchListTile`。
    // 什么错误实现会仍然通过：多渲染一个「全部开启」总开关（或把某个 id
    // 渲染两次）—— 逐个 byKey 查找抓不到多出来的那个，总数能抓到。
    expect(
      find.descendant(of: osdBlock(), matching: find.byType(SwitchListTile)),
      findsNWidgets(OsdFlag.values.length),
      reason: '屏显区块内应恰好 ${OsdFlag.values.length} 个开关',
    );
  });

  testWidgets('开关初值来自 AppState，而不是写死的默认表', (tester) async {
    // 先把状态改成与默认表**不同**的组合，再挂页面。
    // 什么错误实现会仍然通过：把 `value:` 写成 `defaultOsdFlags()[id]`
    // 或写死 `true` —— 在默认状态下两者与真实状态完全一致，
    // 只有先改状态才能区分。
    await configure(tester, () => state.setOsdFlag(OsdFlag.mini, true));
    await configure(tester, () => state.setOsdFlag(OsdFlag.title, false));
    await pumpSettings(tester);

    for (final id in OsdFlag.values) {
      expect(
        tester.widget<SwitchListTile>(osdTile(id)).value,
        state.osdFlags[id],
        reason: '「$id」的开关初值应等于 state.osdFlags[$id]',
      );
    }
    // 前置条件自证：这两项确实偏离了默认表，否则上面的断言没有区分力。
    expect(state.osdFlags[OsdFlag.mini], isTrue);
    expect(defaultOsdFlags()[OsdFlag.mini], isFalse);
    expect(state.osdFlags[OsdFlag.title], isFalse);
    expect(defaultOsdFlags()[OsdFlag.title], isTrue);
  });

  // 网速**已实现**（`player_controller.dart` 的 `sampleNetworkRate` 读 mpv 的
  // `demuxer-cache-state` 内 `raw-input-rate` 字段、回退 `cache-speed`；
  // `player_page.dart` 的 `_sampleNetworkRate` 只在开关打开时才采样，
  // `player_osd.dart` 只在开关打开时渲染），所以它的开关不再是置灰项。
  //
  // 副标题**刻意不写属性名**：数据源是两个属性的组合，而对用户没有意义；
  // 上一版把 `raw-input-rate` 写成"属性"是错的（实测它回 PROPERTY_NOT_FOUND），
  // 文案钉死实现细节就会把那个错误固化下来。
  testWidgets('网速开关可用：可点、副标题说明来源、点下去真的写进 AppState', (tester) async {
    await pumpSettings(tester);

    final traffic = tester.widget<SwitchListTile>(osdTile(OsdFlag.traffic));
    // 什么错误实现会仍然通过：留着上一版的 `onChanged: null` —— 开关永远点不动。
    expect(traffic.onChanged, isNotNull, reason: '网速已实现，开关不得再置灰');
    // 副标题只解释**数据来源**与「取不到」的显示，不得再出现「未采集」这类
    // 过时结论——那会让用户以为根本没有这个能力。
    expect(
      (traffic.subtitle! as Text).data,
      '取自播放引擎的网络输入速率；取不到时显示 —',
      reason: '副标题应说明数据来源与「取不到」的显示（精确文案）',
    );
    // 反向锁：副标题**不得**再写具体的 mpv 属性名。上一版写成
    // 「取自 mpv 的 raw-input-rate」，而实测该名字根本不是属性
    // （`mpv_get_property` 回 -8 PROPERTY_NOT_FOUND），屏显因此永远是 `—`。
    expect(
      (traffic.subtitle! as Text).data,
      isNot(contains('raw-input-rate')),
      reason: '文案不得把内部属性名（且曾写错的那个）暴露给用户',
    );

    // 反向断言 1（替换旧版的「**只有** traffic 置灰」）：
    // 新语义下没有任何置灰项，所以逐个 id 断言**每一项**都可点。
    // 单纯删掉旧断言会让「把整个 Column 的 `onChanged` 统一写成 null」这类
    // 实现漏网；逐个 id 报错还能直接指出是哪一项被置灰。
    for (final id in OsdFlag.values) {
      expect(
        tester.widget<SwitchListTile>(osdTile(id)).onChanged,
        isNotNull,
        reason: '「$id」已实现，不得置灰',
      );
    }

    // 反向断言 2：「真的接上了」与「只是把 null 换成了空函数」必须可区分。
    // `onChanged: (_) {}` 能让上面所有断言通过，却改变不了任何状态。
    // 所以这里真的点一下，断言 state 里 traffic **翻转**、且只翻它一个；
    // 再点回去，断言传入值被尊重（`onChanged: (_) => setOsdFlag(id, true)`
    // 这种「永远置 true」的实现会在第二次点击露馅）。
    expect(state.osdFlags[OsdFlag.traffic], isFalse, reason: '前置：默认关闭');

    await tester.ensureVisible(osdTile(OsdFlag.traffic));
    await settle(tester);
    await tester.tap(osdTile(OsdFlag.traffic));
    await settleIo(tester);

    expect(
      state.osdFlags[OsdFlag.traffic],
      isTrue,
      reason: '点一下必须真的写进 state（空实现会停在这里）',
    );
    // 精确整表：其余 6 项不得被顺带改掉（写死 id 的实现会在这里露馅）。
    expect(state.osdFlags, {
      OsdFlag.title: true,
      OsdFlag.size: true,
      OsdFlag.time: true,
      OsdFlag.progress: true,
      OsdFlag.traffic: true, // 刚点开
      OsdFlag.mini: false, // 从未点过 → 保持默认
      OsdFlag.diagnostics: false,
    });
    // 界面也必须跟着变（`notifyListeners` → `ListenableBuilder` 重建），
    // 而不是只有内存里对了。
    expect(
      tester.widget<SwitchListTile>(osdTile(OsdFlag.traffic)).value,
      isTrue,
      reason: '开关必须反映新状态（不是只改内存）',
    );

    await tester.tap(osdTile(OsdFlag.traffic));
    await settleIo(tester);
    expect(
      state.osdFlags[OsdFlag.traffic],
      isFalse,
      reason: '再次点击必须关闭（无视传入值的实现会在这里露馅）',
    );
  });

  testWidgets('切换屏显开关：精确状态 + 往返 + 落盘（design/05 §3.2 B5）', (tester) async {
    await pumpSettings(tester);
    expect(state.osdFlags[OsdFlag.mini], isFalse, reason: '前置条件：默认关闭');

    await tester.ensureVisible(osdTile(OsdFlag.mini));
    await settle(tester);
    await tester.tap(osdTile(OsdFlag.mini));
    await settleIo(tester);

    // 精确整表，而不是只看单个键：错把别的 id 一起改掉的实现会被抓到。
    expect(state.osdFlags, {
      OsdFlag.title: true,
      OsdFlag.size: true,
      OsdFlag.time: true,
      OsdFlag.progress: true,
      OsdFlag.traffic: false,
      OsdFlag.mini: true,
      OsdFlag.diagnostics: false,
    });
    // 界面也必须跟着变（`notifyListeners` → `ListenableBuilder` 重建）。
    // 什么错误实现会仍然通过：只改 `state` 不通知——那样 `state.osdFlags`
    // 已经是对的，但用户看到的开关还停在 off。
    expect(
      tester.widget<SwitchListTile>(osdTile(OsdFlag.mini)).value,
      isTrue,
      reason: '开关必须反映新状态（不是只改内存）',
    );

    // 往返：再点一次必须回到 false。
    // 什么错误实现会仍然通过：`onChanged: (_) => state.setOsdFlag(id, true)`
    // （无视传入值、永远置 true）—— 单次点击的断言抓不到它。
    await tester.tap(osdTile(OsdFlag.mini));
    await settleIo(tester);
    expect(state.osdFlags[OsdFlag.mini], isFalse, reason: '再次点击必须关闭');
    expect(
      tester.widget<SwitchListTile>(osdTile(OsdFlag.mini)).value,
      isFalse,
      reason: '开关必须跟着回到 off',
    );

    // 落盘：`_persist()` 的续体落在**真实**事件循环上（见文件头注释），
    // 所以不能靠 `settle` 等它。改为在 `runAsync` 里再写**另一个**键：
    // `_persistQueue` 是串行的，后一次写完时前一次必然已经写完，
    // 这样等待是确定性的，而不是 `Future.delayed` 式的碰运气。
    await configure(tester, () => state.setOsdFlag(OsdFlag.diagnostics, true));

    final osd = persistedOsd();
    expect(osd[OsdFlag.diagnostics], isTrue, reason: '诊断面板应已落盘');
    expect(osd[OsdFlag.mini], isFalse, reason: '「点开关 → 写盘」这条路径必须真的写下去（不是只改内存）');
    // 精确键集：**只有显式设过的两项**落盘。
    //
    // 这是 `design/02` §5.2 的「缺席 = 默认，不把默认值固化进文件」纪律
    // （`ui_preferences_store.dart:509-510` 的 `if (_osdFlags.isNotEmpty)`）。
    // 断言「7 个键全在」是**错的**——那会把默认值固化进用户文件，
    // 让「从未选过」与「选过默认值」不可区分。
    // 反向断言（键集精确）同时抓出「把整张默认表写下去」的实现。
    expect(osd.keys.toSet(), {
      OsdFlag.mini,
      OsdFlag.diagnostics,
    }, reason: '只应写显式设过的键（缺席 = 默认）');
  });

  // 关键用例：**每个开关写的是自己的 id**，不是同一个 id 写 7 遍。
  //
  // 为什么必须有这一条：上面那条用例只点 `mini`，所以「7 个开关全部
  // `setOsdFlag(OsdFlag.mini, value)`」这种实现能让**全部 7 条用例通过**
  // （实测确认：把写路径改成写死 `mini`，7 条全绿）。
  // 实现本身是对的（`diagnostics_pages.dart:199` 用的是循环变量 `id`），
  // 但**回归锁是空的**——将来有人把 `id` 写成常量，没人会发现。
  //
  // 做法：点**两个不同的**开关（`progress` 与 `diagnostics`），
  // 断言各自落在自己的键上、且**其余键一个都没被碰**。
  testWidgets('每个开关写自己的 flag id（不是同一个 id 写 7 遍）', (tester) async {
    await pumpSettings(tester);
    // 前置：两个目标默认一开一关，方向不同，便于区分。
    expect(state.osdFlags[OsdFlag.progress], isTrue, reason: '前置：默认开');
    expect(state.osdFlags[OsdFlag.diagnostics], isFalse, reason: '前置：默认关');

    await tester.ensureVisible(osdTile(OsdFlag.progress));
    await settle(tester);
    await tester.tap(osdTile(OsdFlag.progress));
    await settleIo(tester);

    await tester.ensureVisible(osdTile(OsdFlag.diagnostics));
    await settle(tester);
    await tester.tap(osdTile(OsdFlag.diagnostics));
    await settleIo(tester);

    // 精确整表：两个目标各自翻转，其余 5 个**必须原封不动**。
    expect(state.osdFlags, {
      OsdFlag.title: true,
      OsdFlag.size: true,
      OsdFlag.time: true,
      OsdFlag.progress: false, // 点过 → 关
      OsdFlag.traffic: false,
      OsdFlag.mini: false, // 从未点过 → 保持默认
      OsdFlag.diagnostics: true, // 点过 → 开
    });
    // 反向断言：`mini` 不得被顺带改掉——那正是「写死 mini」的实现会做的事。
    expect(
      state.osdFlags[OsdFlag.mini],
      isFalse,
      reason: '点 progress/diagnostics 不得影响 mini（写死 id 的实现会在这里露馅）',
    );
  });

  testWidgets('播放器按钮入口可进入配置页（断言页内特征，不只断言路由类型）', (tester) async {
    await pumpSettings(tester);

    final entry = find.byKey(const ValueKey('settings-player-buttons'));
    expect(entry, findsOneWidget, reason: '设置页必须有播放器按钮入口');
    expect(
      find.descendant(of: entry, matching: find.text('播放器按钮排版')),
      findsOneWidget,
      reason: '入口文案应说明它做什么',
    );

    await tester.tap(entry);
    await settle(tester);

    expect(find.byType(PlayerButtonConfigPage), findsOneWidget);
    // 只断言路由类型的话，「push 了一个空壳页」也会通过。
    // 这里断言配置页**自己的**特征控件（`phase4_tmdb_entry_reachability_test`
    // 的既有纪律：断言页内特征，而非仅断言类型）。
    expect(
      find.byKey(const ValueKey('player-buttons-preview')),
      findsOneWidget,
      reason: '未真正进入按钮配置页',
    );
    expect(find.byKey(const ValueKey('player-buttons-reset')), findsOneWidget);
    expect(find.text('播放器按钮'), findsOneWidget, reason: '配置页的 AppBar 标题');
    // 设置页已被不透明路由盖住（`skipOffstage` 默认 true）。
    expect(osdBlock(), findsNothing, reason: 'push 之后设置页不应仍在渲染');
  });

  testWidgets('800×600 默认视口下两个入口仍可滚动到达', (tester) async {
    // brief 的原始形态：默认 800×600 + `scrollUntilVisible`。
    // 这条用例证明新区块没有把入口藏到「滚不到」的地方。
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.dark),
        home: Scaffold(body: SettingsPage(state: state)),
      ),
    );
    await tester.pump();
    await selectSettingsCategory(tester, 'playback');

    await tester.scrollUntilVisible(
      osdBlock(),
      200,
      scrollable: settingsScrollable(),
    );
    expect(osdBlock(), findsOneWidget);
    for (final id in OsdFlag.values) {
      expect(osdTile(id), findsOneWidget, reason: '缺少屏显开关「$id」');
    }

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('settings-player-buttons')),
      200,
      scrollable: settingsScrollable(),
    );
    expect(
      find.byKey(const ValueKey('settings-player-buttons')),
      findsOneWidget,
    );
  });

  testWidgets('既有设置页入口在各既有视口下选类后可达（design/05 §5 回归）', (tester) async {
    // 保留七种既有真实视口；不同类别的入口改为选类后逐项可达。
    const viewports = <String, Size>{
      'phase5_sync_ui 1400x2600': Size(1400, 2600),
      'phase4_tmdb_entry 1400x2400': Size(1400, 2400),
      'ui_redesign_visual 1440x2400': Size(1440, 2400),
      'tmdb_shell_entry 1600x1600': Size(1600, 1600),
      'phase6_history_page 1200x1600': Size(1200, 1600),
      'phase6_ai_settings 1200x1800': Size(1200, 1800),
      'phase5_sync_refresh 1280x2000': Size(1280, 2000),
    };

    const targets = <String, List<String>>{
      'phase5_sync_ui 1400x2600': [
        'settings-android-open',
        'settings-android-summary',
      ],
      'phase4_tmdb_entry 1400x2400': ['settings-tmdb-open'],
      'ui_redesign_visual 1440x2400': [
        'settings-theme-mode',
        'settings-site-health-open',
      ],
      'tmdb_shell_entry 1600x1600': ['settings-tmdb-open'],
      'phase6_history_page 1200x1600': ['settings-history-click-action'],
      'phase6_ai_settings 1200x1800': ['settings-ai-open'],
      'phase5_sync_refresh 1280x2000': ['settings-android-summary'],
    };

    const categories = <String, String>{
      'settings-theme-mode': 'preferences',
      'settings-history-click-action': 'preferences',
      'settings-ai-open': 'connections',
      'settings-tmdb-open': 'connections',
      'settings-android-open': 'connections',
      'settings-android-summary': 'connections',
      'settings-site-health-open': 'maintenance',
    };

    for (final entry in viewports.entries) {
      await pumpSettings(tester, size: entry.value, category: 'preferences');
      final height = entry.value.height;
      for (final key in targets[entry.key]!) {
        await selectSettingsCategory(tester, categories[key]!);
        final finder = find.byKey(ValueKey(key));
        await tester.scrollUntilVisible(
          finder,
          200,
          scrollable: settingsScrollable(),
        );
        expect(finder, findsOneWidget, reason: '${entry.key}：$key 选类并滚动后必须可达');
        final rect = tester.getRect(finder);
        expect(
          rect.top,
          greaterThanOrEqualTo(0),
          reason: '${entry.key}：$key 滚动后仍在视口上方',
        );
        expect(
          rect.bottom,
          lessThanOrEqualTo(height),
          reason: '${entry.key}：$key 选类并滚动后仍在视口下方',
        );
      }

      await selectSettingsCategory(tester, 'playback');
      for (final key in const ['settings-osd', 'settings-player-buttons']) {
        final finder = find.byKey(ValueKey(key));
        await tester.scrollUntilVisible(
          finder,
          200,
          scrollable: settingsScrollable(),
        );
        expect(
          finder,
          findsOneWidget,
          reason: '${entry.key}：新增入口 $key 选播放类并滚动后仍不可达',
        );
      }
    }
  });

  testWidgets('高级设置入口可进入并渲染 Phase 9 区块', (tester) async {
    await pumpSettings(tester);
    final entry = find.byKey(const ValueKey('settings-advanced-open'));
    expect(entry, findsOneWidget, reason: '设置页必须有高级设置入口');
    await tester.scrollUntilVisible(
      entry,
      200,
      scrollable: settingsScrollable(),
    );
    await tester.tap(entry);
    await settle(tester);

    for (final key in const [
      'settings-live-source-fallback',
      'settings-live-change-line',
      'settings-ad-block',
      'settings-parse-failover',
      'settings-site-health-sort',
      'settings-group-rules',
      'settings-danmaku-auto-search',
      'settings-subtitle-open',
      'settings-injected-sites-open',
      'settings-pan-check-open',
      'settings-ai-assist-open',
      'settings-outbound-proxy-enabled',
      'settings-player-options',
      'settings-backup-open',
    ]) {
      expect(
        find.byKey(ValueKey(key)),
        findsOneWidget,
        reason: '高级设置缺少区块：$key',
      );
    }
  });
}
