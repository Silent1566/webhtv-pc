/// 高级设置「中枢行 → 三级明细页」的真实路由回归。
///
/// ## 这一组用例锁什么
///
/// 1. 六条三级路由（播放参数 / 弹幕源 / 分组规则 / 出站代理 / DoH / 浏览器内核）
///    都能通过中枢上**真实点击一行**进入，并用 AppBar 返回带回中枢；
/// 2. 中枢不再挂载任何明细控件——旧版把整页控件堆在同一个长页里，改回旧形态
///    时下面「明细控件不得出现在中枢」的断言会红；
/// 3. 明细页里的开关拨动后**界面回显**且**真的落盘** `settings.json`；
/// 4. 480×640 / 1072×728 × 暗亮都不溢出（窄窗与桌面窗各一档）；
/// 5. 行可用键盘激活，明细页可用返回按钮键盘返回；
/// 6. 从明细页返回后中枢保留自己的滚动位置。
///
/// ## 为什么写盘断言都包在 `runAsync` / 条件轮询里
///
/// `UiPreferencesStore._persistQueue` 在 `setUp` 的**真实** zone 里创建，续体落在
/// 真实事件循环上，`FakeAsync` 推不动它。详见
/// `phase8_settings_entries_test.dart` 的文件头注释与 `docs/phase8/design/05` §1.2。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/advanced_settings_page.dart';
import 'package:webhtv_pc/ui/settings_layout.dart';
import 'package:webhtv_pc/ui/theme.dart';

import 'support/advanced_settings_navigation.dart';

/// 六条三级路由：中枢行 key → 明细页 AppBar 标题 → 页面独有的特征 key。
const advancedRoutes = <({String rowKey, String title, String marker})>[
  (
    rowKey: 'settings-player-options-open',
    title: '播放参数',
    marker: 'settings-player-options',
  ),
  (
    rowKey: 'settings-danmaku-open',
    title: '弹幕源',
    marker: 'settings-danmaku-auto-search',
  ),
  (
    rowKey: 'settings-group-rules-open',
    title: '站点分组规则',
    marker: 'settings-group-rules',
  ),
  (
    rowKey: 'settings-outbound-proxy-open',
    title: '出站代理',
    marker: 'settings-outbound-proxy-enabled',
  ),
  (
    rowKey: 'settings-doh-open',
    title: '加密 DNS（DoH）',
    marker: 'settings-doh-enabled',
  ),
  (
    rowKey: 'settings-browser-open',
    title: '浏览器内核',
    marker: 'browser-component-section',
  ),
];

/// 代表四个明细页的开关：进入后拨动 → 回显 + 落盘。
const advancedSwitches =
    <
      ({
        String rowKey,
        String switchKey,
        bool before,
        bool after,
        String section,
        String field,
      })
    >[
      (
        rowKey: 'settings-player-options-open',
        switchKey: 'settings-player-hardware-decoding',
        before: true,
        after: false,
        section: 'player',
        field: 'hardwareDecoding',
      ),
      (
        rowKey: 'settings-danmaku-open',
        switchKey: 'settings-danmaku-auto-search',
        before: false,
        after: true,
        section: 'danmaku',
        field: 'autoSearch',
      ),
      (
        rowKey: 'settings-outbound-proxy-open',
        switchKey: 'settings-outbound-proxy-enabled',
        before: false,
        after: true,
        section: 'outboundProxy',
        field: 'enabled',
      ),
      (
        rowKey: 'settings-doh-open',
        switchKey: 'settings-doh-enabled',
        before: false,
        after: true,
        section: 'doh',
        field: 'enabled',
      ),
    ];

void main() {
  late Directory temp;
  late AppState state;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('webhtv-advanced-navigation');
    state = AppState(
      paths: AppPaths.resolve(
        overrides: {
          'config': '${temp.path}/config',
          'data': '${temp.path}/data',
          'cache': '${temp.path}/cache',
          'state': '${temp.path}/logs',
        },
      ),
      log: LogService(),
    );
    await state.bootstrap();
  });

  tearDown(() {
    state.dispose();
    try {
      temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> pumpHub(
    WidgetTester tester, {
    Size size = const Size(1072, 728),
    Brightness brightness = Brightness.dark,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(brightness),
        home: AdvancedSettingsPage(state: state),
      ),
    );
    await pumpAdvanced(tester);
  }

  Map<String, Object?> readSettings() {
    final file = File(state.paths.settingsPath);
    if (!file.existsSync()) return const {};
    return jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
  }

  Map<String, Object?> sectionOf(String section) {
    final raw = readSettings()[section];
    return raw is Map ? raw.cast<String, Object?>() : const {};
  }

  testWidgets('六条三级路由都能从中枢真实进入，并由返回按钮带回中枢', (tester) async {
    await pumpHub(tester);
    expect(find.widgetWithText(AppBar, '高级设置'), findsOneWidget);

    for (final route in advancedRoutes) {
      await tapAdvancedRow(tester, route.rowKey);

      // 只断言路由类型的话，「push 了一个空壳页」也会通过：这里断言明细页
      // 自己的 AppBar 标题与页面内独有控件。
      expect(
        find.widgetWithText(AppBar, route.title),
        findsOneWidget,
        reason: '${route.rowKey} 未进入「${route.title}」明细页',
      );
      expect(
        find.byKey(ValueKey(route.marker)),
        findsOneWidget,
        reason: '「${route.title}」缺少页面内独有控件 ${route.marker}',
      );
      expect(
        find.byKey(ValueKey(route.rowKey)),
        findsNothing,
        reason: '明细页打开后中枢行不得仍可见（路由必须真的盖住中枢）',
      );

      await backFromAdvancedDetail(tester);
      expect(
        find.widgetWithText(AppBar, '高级设置'),
        findsOneWidget,
        reason: '从「${route.title}」返回后必须回到高级设置中枢',
      );
      expect(find.byKey(ValueKey(route.marker)), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('明细控件不得挂载在中枢：设置只出现在各自的三级页面里', (tester) async {
    await pumpHub(tester);
    final hub = find.byType(AdvancedSettingsPage);

    // 这些 key 在改造前都直接挂在中枢上（同一页长表单）。现在它们属于明细页，
    // 中枢里**连离屏形态都不该存在**——否则等于把旧页又挂了回来。
    for (final key in const [
      'settings-player-options',
      'settings-player-long-press-speed',
      'settings-danmaku-auto-search',
      'settings-group-rules',
      'settings-outbound-proxy-enabled',
      'settings-doh-enabled',
      'browser-component-section',
    ]) {
      expect(
        find.descendant(
          of: hub,
          matching: find.byKey(ValueKey(key)),
          skipOffstage: false,
        ),
        findsNothing,
        reason: '明细控件 $key 不得出现在中枢里（应只在三级页面）',
      );
    }

    // 反向：中枢保留的仍然是「入口行 + 就地生效的开关」。
    // 先扫入口行（自上而下），再回顶部扫留在中枢的开关：ListView 懒构建，
    // 视口以上的行拖不回来。
    for (final route in advancedRoutes) {
      final row = find.byKey(ValueKey(route.rowKey));
      await tester.scrollUntilVisible(
        row,
        200,
        scrollable: advancedHubScrollable(),
      );
      expect(row, findsOneWidget, reason: '中枢缺少入口行 ${route.rowKey}');
      expect(
        tester.widget(row),
        isA<SettingsNavRow>(),
        reason: '${route.rowKey} 应是「进入下一级」的行，而不是内联控件',
      );
    }
    await scrollHubToTop(tester);
    for (final key in const [
      'settings-live-source-fallback',
      'settings-parse-failover',
      'settings-ad-block',
      'settings-incognito',
      'settings-spider-debug-log',
    ]) {
      final finder = find.byKey(ValueKey(key));
      await tester.scrollUntilVisible(
        finder,
        200,
        scrollable: advancedHubScrollable(),
      );
      expect(
        tester.widget(finder),
        isA<SwitchListTile>(),
        reason: '就地生效的开关 $key 必须留在中枢',
      );
    }
  });

  testWidgets('四个代表明细页：开关拨动后回显，并真的落盘 settings.json', (tester) async {
    await pumpHub(tester);

    for (final item in advancedSwitches) {
      await tapAdvancedRow(tester, item.rowKey);
      final toggle = find.byKey(ValueKey(item.switchKey));
      expect(
        toggle,
        findsOneWidget,
        reason: '${item.rowKey} 缺少开关 ${item.switchKey}',
      );
      expect(
        tester.widget<SwitchListTile>(toggle).value,
        item.before,
        reason: '${item.switchKey} 的初值必须来自 AppState（默认 ${item.before}）',
      );

      await tester.tap(toggle);
      await settleAdvancedIo(tester);

      expect(
        tester.widget<SwitchListTile>(toggle).value,
        item.after,
        reason: '${item.switchKey} 拨动后必须回显为 ${item.after}，不能弹回',
      );
      await waitForRealIo(
        tester,
        () => sectionOf(item.section)[item.field] == item.after,
      );
      expect(
        sectionOf(item.section)[item.field],
        item.after,
        reason:
            'settings.json 的 ${item.section}.${item.field} 必须写入 ${item.after}',
      );

      // 往返：再拨一次必须回到初值（「永远写 true」的实现会在这里露馅）。
      await tester.tap(toggle);
      await settleAdvancedIo(tester);
      expect(
        tester.widget<SwitchListTile>(toggle).value,
        item.before,
        reason: '${item.switchKey} 再拨一次必须回到 ${item.before}',
      );

      await backFromAdvancedDetail(tester);
      expect(tester.takeException(), isNull);
    }
  });

  for (final brightness in Brightness.values) {
    for (final size in const [Size(480, 640), Size(1072, 728)]) {
      testWidgets(
        '中枢与六个明细页不溢出 ${brightness.name} ${size.width.toInt()}x${size.height.toInt()}',
        (tester) async {
          await pumpHub(tester, size: size, brightness: brightness);
          expect(
            tester.takeException(),
            isNull,
            reason: '高级设置中枢在 $size 溢出（RenderFlex overflow）',
          );

          for (final route in advancedRoutes) {
            await tapAdvancedRow(tester, route.rowKey);
            expect(
              find.widgetWithText(AppBar, route.title),
              findsOneWidget,
              reason: '${route.rowKey} 未进入明细页',
            );
            expect(
              tester.takeException(),
              isNull,
              reason: '「${route.title}」在 $size 溢出（RenderFlex overflow）',
            );
            await backFromAdvancedDetail(tester);
            expect(
              tester.takeException(),
              isNull,
              reason: '从「${route.title}」返回中枢后在 $size 溢出',
            );
          }
        },
      );
    }
  }

  testWidgets('键盘：Tab 走到入口行，回车进入，返回按钮回车回到中枢', (tester) async {
    await pumpHub(tester);

    /// 当前焦点落在哪一行（走真实焦点树，不碰私有状态）。
    String? focusedRow() {
      final context = FocusManager.instance.primaryFocus?.context;
      final row = context?.findAncestorWidgetOfExactType<SettingsNavRow>();
      final key = row?.key;
      return key is ValueKey<String> ? key.value : null;
    }

    const target = 'settings-player-options-open';
    for (var i = 0; i < 16 && focusedRow() != target; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
    }
    expect(focusedRow(), target, reason: 'Tab 必须能把焦点带到「播放参数」入口行');

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await pumpAdvanced(tester);
    expect(
      find.widgetWithText(AppBar, '播放参数'),
      findsOneWidget,
      reason: '回车必须真的进入明细页（只移动焦点不激活 = 键盘半残）',
    );

    /// 焦点是否落在 AppBar 的返回按钮上。
    bool focusIsBackButton() {
      final context = FocusManager.instance.primaryFocus?.context;
      if (context == null) return false;
      return context.findAncestorWidgetOfExactType<BackButton>() != null;
    }

    for (var i = 0; i < 8 && !focusIsBackButton(); i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
    }
    expect(focusIsBackButton(), isTrue, reason: 'Tab 必须能把焦点带到返回按钮');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await pumpAdvanced(tester);
    expect(
      find.widgetWithText(AppBar, '高级设置'),
      findsOneWidget,
      reason: '返回按钮上的回车必须回到中枢',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('明细页返回后中枢保留自己的滚动位置', (tester) async {
    await pumpHub(tester);
    final scrollable = advancedHubScrollable();

    // 中枢末尾的入口行：从这里进入再返回，才有「返回后是否归零」的区分力。
    await revealAdvancedRow(tester, 'settings-browser-open');
    final before = tester.state<ScrollableState>(scrollable).position.pixels;
    expect(before, greaterThan(0), reason: '前置：中枢必须真的滚下去了');
    await tester.tap(find.byKey(const ValueKey('settings-browser-open')));
    await pumpAdvanced(tester);
    expect(find.widgetWithText(AppBar, '浏览器内核'), findsOneWidget);
    await backFromAdvancedDetail(tester);

    expect(
      tester.state<ScrollableState>(scrollable).position.pixels,
      closeTo(before, 0.5),
      reason: '返回中枢后滚动位置必须保留（不得回到顶部）',
    );
    expect(
      find.byKey(const ValueKey('settings-browser-open')).hitTestable(),
      findsOneWidget,
      reason: '返回后末尾的入口行必须仍在视口内可点',
    );
  });
}
