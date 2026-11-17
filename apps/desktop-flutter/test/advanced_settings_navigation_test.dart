/// 设置分类页「行 → 明细页」的真实路由回归。
///
/// ## 这一组用例锁什么
///
/// 旧标题里的「高级设置中枢」整页已被**删除**（原 lib/ui/advanced_settings_page.dart）：
/// 它的 18 行按用途散进五个分类，任意设置最多两级可达。本套件是它的改造继承者，
/// 原来的六条锁一条没删，只把**落点**换到新结构：
///
/// 1. 十一条行入口都能通过分类页上**真实点击一行**进入自己的明细页，并用 AppBar
///    返回按钮带回分类页（且仍停在原分类）；
/// 2. 分类页不再挂载任何明细控件——明细控件只出现在各自页面里；
/// 3. 明细页里的开关拨动后**界面回显**且**真的落盘** settings.json
///    （播放参数 / 弹幕源 / 出站代理 / DoH / 直播的两个开关）；
/// 4. 480×640 / 720×900 / 1024×728 / 1440×900 × 暗亮都不溢出；
/// 5. 行可用键盘激活，明细页可用返回按钮键盘返回；
/// 6. 从明细页返回后分类页保留自己的滚动位置；
/// 7. 结构锁：分类页里凡是「进入下一级」的行都必须是 SettingsNavRow，
///    就地生效的只有五个 SwitchListTile，成组开关块不得回到分类页。
///
/// ## 为什么写盘断言都包在 runAsync / 条件轮询里
///
/// UiPreferencesStore._persistQueue 在 setUp 的**真实** zone 里创建，续体落在
/// 真实事件循环上，FakeAsync 推不动它。详见 phase8_settings_entries_test.dart
/// 的文件头注释与 docs/phase8/design/05 §1.2。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/diagnostics_pages.dart';
import 'package:webhtv_pc/ui/settings_layout.dart';
import 'package:webhtv_pc/ui/theme.dart';

import 'support/settings_row_navigation.dart';

/// 十一条「分类页行 → 明细页」：所在分类 / 行 key / 明细页 AppBar 标题 / 页面独有 key。
const settingsRoutes =
    <({String category, String rowKey, String title, String marker})>[
      (
        category: 'playback',
        rowKey: 'settings-player-options-open',
        title: '播放参数',
        marker: 'settings-player-options',
      ),
      (
        category: 'playback',
        rowKey: 'settings-danmaku-open',
        title: '弹幕源',
        marker: 'settings-danmaku-auto-search',
      ),
      (
        category: 'playback',
        rowKey: 'settings-subtitle-open',
        title: '字幕源',
        marker: 'subtitle-auto-match',
      ),
      (
        category: 'playback',
        rowKey: 'settings-osd-open',
        title: '屏显（OSD）',
        marker: 'settings-osd',
      ),
      (
        category: 'playback',
        rowKey: 'settings-live-open',
        title: '直播',
        marker: 'settings-live-source-fallback',
      ),
      (
        category: 'sites',
        rowKey: 'settings-group-rules-open',
        title: '站点分组规则',
        marker: 'settings-group-rules',
      ),
      (
        category: 'connections',
        rowKey: 'settings-outbound-proxy-open',
        title: '出站代理',
        marker: 'settings-outbound-proxy-enabled',
      ),
      (
        category: 'connections',
        rowKey: 'settings-doh-open',
        title: '加密 DNS（DoH）',
        marker: 'settings-doh-enabled',
      ),
      (
        category: 'maintenance',
        rowKey: 'settings-browser-open',
        title: '浏览器内核',
        marker: 'browser-component-section',
      ),
      (
        category: 'maintenance',
        rowKey: 'settings-python-environment-open',
        title: '运行环境',
        marker: 'python-environment-status',
      ),
      (
        category: 'maintenance',
        rowKey: 'settings-backup-open',
        title: '备份与恢复',
        marker: 'backup-output-path',
      ),
    ];

/// 代表六个明细页的开关：进入后拨动 → 回显 + 落盘 + 往返。
const settingsSwitches =
    <
      ({
        String category,
        String rowKey,
        String switchKey,
        bool before,
        bool after,
        String section,
        String field,
      })
    >[
      (
        category: 'playback',
        rowKey: 'settings-player-options-open',
        switchKey: 'settings-player-hardware-decoding',
        before: true,
        after: false,
        section: 'player',
        field: 'hardwareDecoding',
      ),
      (
        category: 'playback',
        rowKey: 'settings-danmaku-open',
        switchKey: 'settings-danmaku-auto-search',
        before: false,
        after: true,
        section: 'danmaku',
        field: 'autoSearch',
      ),
      (
        category: 'connections',
        rowKey: 'settings-outbound-proxy-open',
        switchKey: 'settings-outbound-proxy-enabled',
        before: false,
        after: true,
        section: 'outboundProxy',
        field: 'enabled',
      ),
      (
        category: 'connections',
        rowKey: 'settings-doh-open',
        switchKey: 'settings-doh-enabled',
        before: false,
        after: true,
        section: 'doh',
        field: 'enabled',
      ),
      (
        category: 'playback',
        rowKey: 'settings-live-open',
        switchKey: 'settings-live-source-fallback',
        before: true,
        after: false,
        section: 'live',
        field: 'sourceFallback',
      ),
      (
        category: 'playback',
        rowKey: 'settings-live-open',
        switchKey: 'settings-live-change-line',
        before: true,
        after: false,
        section: 'live',
        field: 'changeLine',
      ),
    ];

/// 分类页上允许**就地生效**的开关（其余一切都必须是「进入下一级」的行）。
const inlineSwitchKeys = <String>{
  'settings-ad-block',
  'settings-parse-failover',
  'settings-site-health-sort',
  'settings-incognito',
  'settings-spider-debug-log',
};

void main() {
  late Directory temp;
  late AppState state;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('webhtv-settings-detail-nav');
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

  Future<void> pumpSettings(
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
        home: ListenableBuilder(
          listenable: state,
          builder: (context, _) => Scaffold(body: SettingsPage(state: state)),
        ),
      ),
    );
    await pumpSettingsSettled(tester);
  }

  Future<void> openCategory(WidgetTester tester, String category) async {
    final control = find.byKey(ValueKey('settings-category-$category'));
    expect(control, findsOneWidget, reason: '缺少分类入口：$category');
    await tester.tap(control);
    await pumpSettingsSettled(tester);
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

  testWidgets('十一条分类页行都能真实进入明细页，并由返回按钮带回原分类', (tester) async {
    await pumpSettings(tester);

    for (final route in settingsRoutes) {
      await openCategory(tester, route.category);
      await tapCategoryRow(
        tester,
        category: route.category,
        rowKey: route.rowKey,
      );

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
        reason: '明细页打开后分类页的行不得仍可见（路由必须真的盖住分类页）',
      );

      await backFromSettingsDetail(tester);
      expect(
        find.byKey(ValueKey('settings-category-content-${route.category}')),
        findsOneWidget,
        reason: '从「${route.title}」返回后必须回到 ${route.category} 分类页',
      );
      expect(
        find.byKey(ValueKey(route.marker)),
        findsNothing,
        reason: '返回后明细页控件必须已经卸载',
      );
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('明细控件不得挂载在分类页：设置只出现在各自的明细页里', (tester) async {
    // 高视口：每个分类的行都能一次性建出来，结构锁才有区分力。
    await pumpSettings(tester, size: const Size(1440, 1000));

    // 这些 key 在改造前都直接挂在「高级设置」中枢上（同一页长表单），
    // 现在它们属于明细页，分类页里**连离屏形态都不该存在**。
    const detailOnlyKeys = <String>[
      'settings-player-options',
      'settings-player-long-press-speed',
      'settings-danmaku-auto-search',
      'settings-group-rules',
      'settings-outbound-proxy-enabled',
      'settings-doh-enabled',
      'browser-component-section',
      'settings-live-source-fallback',
      'settings-live-change-line',
      'settings-osd',
      'settings-osd-title',
      'settings-osd-traffic',
    ];

    for (final category in const [
      'preferences',
      'playback',
      'sites',
      'connections',
      'maintenance',
    ]) {
      await openCategory(tester, category);
      final content = find.byKey(
        ValueKey('settings-category-content-$category'),
      );
      expect(content, findsOneWidget);

      for (final key in detailOnlyKeys) {
        expect(
          find.descendant(
            of: content,
            matching: find.byKey(ValueKey(key)),
            skipOffstage: false,
          ),
          findsNothing,
          reason: '明细控件 $key 不得出现在分类页 $category 里（应只在明细页）',
        );
      }

      // 结构锁：正文里的开关**只能**是那五个就地生效的。
      //
      // 屏显那 7 个开关曾经就地摊在「播放」类里；把任何一个成组开关块搬回
      // 分类页，都会在这里多出一个不在白名单里的 key。
      final switches = tester
          .widgetList<SwitchListTile>(
            find.descendant(
              of: content,
              matching: find.byType(SwitchListTile),
              skipOffstage: false,
            ),
          )
          .map((tile) => (tile.key! as ValueKey<String>).value)
          .toSet();
      expect(
        switches.difference(inlineSwitchKeys),
        isEmpty,
        reason:
            '分类页 $category 里有不在白名单里的就地开关：'
            '${switches.difference(inlineSwitchKeys)}（成组开关必须进明细页）',
      );

      // 反向：这一分类里的行入口都必须是 SettingsNavRow（不是内联控件）。
      final expectedRows = settingsRoutes
          .where((route) => route.category == category)
          .map((route) => route.rowKey)
          .toList();
      for (final rowKey in expectedRows) {
        final row = find.byKey(ValueKey(rowKey));
        expect(row, findsOneWidget, reason: '分类 $category 缺少入口行 $rowKey');
        expect(
          tester.widget(row),
          isA<SettingsNavRow>(),
          reason: '$rowKey 应是「进入下一级」的行，而不是内联控件',
        );
      }
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('六个代表明细页：开关拨动后回显，并真的落盘 settings.json', (tester) async {
    await pumpSettings(tester);

    for (final item in settingsSwitches) {
      await openCategory(tester, item.category);
      await tapCategoryRow(
        tester,
        category: item.category,
        rowKey: item.rowKey,
      );
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
      await settleSettingsIo(tester);

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
      await settleSettingsIo(tester);
      expect(
        tester.widget<SwitchListTile>(toggle).value,
        item.before,
        reason: '${item.switchKey} 再拨一次必须回到 ${item.before}',
      );

      await backFromSettingsDetail(tester);
      expect(tester.takeException(), isNull);
    }
  });

  // 「关于与数据」是把三块长文本（本机目录 / 运行信息 / 隐私与合规）收进独立页
  // 的那一页：两个复制类动作必须仍在、仍可直接点到；文案不得随搬家丢失。
  testWidgets('关于与数据明细页：缓存与日志按钮仍在，运行信息与隐私文本仍在', (tester) async {
    await pumpSettings(tester);
    await openCategory(tester, 'maintenance');
    await tapCategoryRow(
      tester,
      category: 'maintenance',
      rowKey: 'settings-about-data-open',
    );

    expect(find.widgetWithText(AppBar, '关于与数据'), findsOneWidget);
    expect(find.text('本地数据'), findsOneWidget);
    expect(find.text('运行信息'), findsOneWidget);

    // 两个动作必须是仍在树里、且可点的按钮（不要求真的写盘：清理缓存与复制
    // 剪贴板都依赖平台通道，widget 测试里只锁「入口还在」）。
    for (final label in const ['清理缓存目录', '复制脱敏日志']) {
      final button = find.widgetWithText(OutlinedButton, label);
      await tester.ensureVisible(button);
      await pumpSettingsSettled(tester);
      expect(button, findsOneWidget, reason: '「关于与数据」缺少动作：$label');
      expect(
        button.hitTestable(),
        findsOneWidget,
        reason: '动作「$label」必须真实可点（不是被长文本挤出视口的摆设）',
      );
      expect(
        tester.widget<OutlinedButton>(button).onPressed,
        isNotNull,
        reason: '动作「$label」不得被置灰',
      );
    }

    // 明细页懒构建屏外段落；先滚到隐私段，再检查两条硬事实。
    await tester.scrollUntilVisible(
      find.text('隐私与合规'),
      200,
      scrollable: find
          .descendant(
            of: find.byType(SettingsDetailScaffold),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await pumpSettingsSettled(tester);
    expect(find.text('隐私与合规'), findsOneWidget);
    expect(find.textContaining('遥测与崩溃上报：关闭'), findsOneWidget);
    expect(find.textContaining('站点配置同步：关闭'), findsOneWidget);

    await backFromSettingsDetail(tester);
    expect(
      find.byKey(const ValueKey('settings-category-content-maintenance')),
      findsOneWidget,
    );
  });

  for (final brightness in Brightness.values) {
    for (final size in const [
      Size(480, 640),
      Size(720, 900),
      Size(1024, 728),
      Size(1440, 900),
    ]) {
      testWidgets('分类页与明细页不溢出 ${brightness.name} '
          '${size.width.toInt()}x${size.height.toInt()}', (tester) async {
        await pumpSettings(tester, size: size, brightness: brightness);
        expect(
          tester.takeException(),
          isNull,
          reason: '分类页在 $size 溢出（RenderFlex overflow）',
        );

        // 每类都扫一遍（分类栏在 5 类之后最容易在矮窗里先溢出）。
        for (final category in const [
          'playback',
          'sites',
          'connections',
          'maintenance',
        ]) {
          await openCategory(tester, category);
          expect(
            tester.takeException(),
            isNull,
            reason: '分类 $category 在 $size 溢出（RenderFlex overflow）',
          );
        }
      });
    }
  }

  for (final brightness in Brightness.values) {
    testWidgets('代表明细页不溢出 ${brightness.name}', (tester) async {
      for (final size in const [Size(480, 640), Size(1440, 900)]) {
        await pumpSettings(tester, size: size, brightness: brightness);
        for (final route in settingsRoutes) {
          await openCategory(tester, route.category);
          await tapCategoryRow(
            tester,
            category: route.category,
            rowKey: route.rowKey,
          );
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
          await backFromSettingsDetail(tester);
          expect(
            tester.takeException(),
            isNull,
            reason: '从「${route.title}」返回分类页后在 $size 溢出',
          );
        }
      }
    });
  }

  testWidgets('键盘：Tab 走到入口行，回车进入，返回按钮回车回到分类页', (tester) async {
    await pumpSettings(tester);
    await openCategory(tester, 'playback');

    /// 当前焦点落在哪一行（走真实焦点树，不碰私有状态）。
    String? focusedRow() {
      final context = FocusManager.instance.primaryFocus?.context;
      final row = context?.findAncestorWidgetOfExactType<SettingsNavRow>();
      final key = row?.key;
      return key is ValueKey<String> ? key.value : null;
    }

    const target = 'settings-player-options-open';
    for (var i = 0; i < 24 && focusedRow() != target; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
    }
    expect(focusedRow(), target, reason: 'Tab 必须能把焦点带到「播放参数」入口行');

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await pumpSettingsSettled(tester);
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
    await pumpSettingsSettled(tester);
    expect(
      find.byKey(const ValueKey('settings-category-content-playback')),
      findsOneWidget,
      reason: '返回按钮上的回车必须回到分类页',
    );
    expect(
      find.widgetWithText(AppBar, '播放参数'),
      findsNothing,
      reason: '返回后明细页必须已经卸载',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('明细页返回后分类页保留自己的滚动位置', (tester) async {
    // 矮视口：播放类的内容明显高过它，滚到底才有非零偏移。
    await pumpSettings(tester, size: const Size(1440, 460));
    await openCategory(tester, 'playback');

    // 分类页末尾的入口行：从这里进入再返回，才有「返回后是否归零」的区分力。
    await revealCategoryRow(
      tester,
      category: 'playback',
      rowKey: 'settings-live-open',
    );
    final scrollable = categoryScrollable('playback');
    final before = tester.state<ScrollableState>(scrollable).position.pixels;
    expect(before, greaterThan(0), reason: '前置：分类页必须真的滚下去了');
    await tester.tap(find.byKey(const ValueKey('settings-live-open')));
    await pumpSettingsSettled(tester);
    expect(find.widgetWithText(AppBar, '直播'), findsOneWidget);
    await backFromSettingsDetail(tester);

    expect(
      tester.state<ScrollableState>(scrollable).position.pixels,
      closeTo(before, 0.5),
      reason: '返回分类页后滚动位置必须保留（不得回到顶部）',
    );
    expect(
      find.byKey(const ValueKey('settings-live-open')).hitTestable(),
      findsOneWidget,
      reason: '返回后末尾的入口行必须仍在视口内可点',
    );
  });
}
