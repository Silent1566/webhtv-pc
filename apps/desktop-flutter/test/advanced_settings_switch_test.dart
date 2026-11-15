/// 设置分类页与「全部设置」页的开关回显回归。
///
/// 为什么需要这个测试：设置首页是外壳里的一个标签页，宿主（AppShell）会在
/// AppState.notifyListeners 之后重建它；但 **Navigator.push 出来的页面**
/// （全部设置页 / 屏显 / 直播 / 播放参数 / 关于与数据）是独立路由，
/// 宿主的重建到不了它。少掉 ListenableBuilder，受控开关拨动后父级不重建，
/// 视觉上就会弹回原值——整页所有开关同一根因。
///
/// 改造前这里锁的是「高级设置」中枢整页；该页已删除，同样的根因现在落在
/// 五个独立路由上，所以断言仍是同一个形状：
/// 1. 独立路由里的开关拨动后**界面回显**（不是弹回）且**真的落盘**；
/// 2. 拨两个不同页的开关，证明修的是这一整类页面而不是只给某一个打了补丁。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/settings_overview_page.dart';
import 'package:webhtv_pc/ui/theme.dart';

import 'support/settings_row_navigation.dart';

AppPaths tempPaths(Directory temp) => AppPaths.resolve(
  overrides: {
    'config': '${temp.path}${Platform.pathSeparator}config',
    'data': '${temp.path}${Platform.pathSeparator}data',
    'cache': '${temp.path}${Platform.pathSeparator}cache',
    'state': '${temp.path}${Platform.pathSeparator}logs',
  },
);

void main() {
  group('独立路由里的开关回显', () {
    late Directory temp;
    late AppState state;

    setUp(() async {
      temp = Directory.systemTemp.createTempSync('webhtv-settings-switch');
      state = AppState(paths: tempPaths(temp), log: LogService());
      await state.bootstrap();
    });

    tearDown(() {
      state.dispose();
      try {
        temp.deleteSync(recursive: true);
      } catch (_) {}
    });

    /// 挂载「全部设置」页：它由 Navigator.push 打开，宿主监听管不到它。
    Future<void> pumpOverview(WidgetTester tester) async {
      tester.view.physicalSize = const Size(900, 700);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.dark),
          home: SettingsOverviewPage(state: state),
        ),
      );
      await pumpSettingsSettled(tester);
    }

    SwitchListTile tile(WidgetTester tester, String key) =>
        tester.widget<SwitchListTile>(find.byKey(ValueKey(key)));

    // 开关的 onChanged 内部 await 真实写盘，假时钟的 pumpAndSettle 等不到
    // 它结束（notifyListeners 还没触发）；runAsync 放行真实 IO 与随后的通知，
    // 再用 pumpAndSettle 把重建落到帧上。
    Future<void> tapSwitch(WidgetTester tester, Finder finder) async {
      await tester.tap(finder);
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('既有开关与详细调试日志开关拨动后都回显，并落盘 settings.json', (tester) async {
      await pumpOverview(tester);
      // 两个开关现在都在「维护」分类（隐身模式 / 详细调试日志）。
      await tester.tap(
        find.byKey(const ValueKey('settings-category-maintenance')),
      );
      await pumpSettingsSettled(tester);

      // 既有开关：证明修的是整页监听，而不是只给报障的那个开关打了补丁。
      const incognitoKey = 'settings-incognito';
      final incognito = find.byKey(const ValueKey(incognitoKey));
      await revealCategoryRow(
        tester,
        category: 'maintenance',
        rowKey: incognitoKey,
      );
      expect(tile(tester, incognitoKey).value, isFalse);
      await tapSwitch(tester, incognito);
      expect(state.incognito, isTrue);
      expect(
        tile(tester, incognitoKey).value,
        isTrue,
        reason: '既有开关也必须回显为开',
      );

      // 报障开关：同一分类末尾的「详细调试日志（爬虫入参/出参）」。
      const logKey = 'settings-spider-debug-log';
      final logTile = find.byKey(const ValueKey(logKey));
      await revealCategoryRow(tester, category: 'maintenance', rowKey: logKey);
      expect(tile(tester, logKey).value, isFalse);
      await tapSwitch(tester, logTile);
      expect(state.spiderDebugLog, isTrue);
      expect(
        tile(tester, logKey).value,
        isTrue,
        reason: '拨动后必须回显为开，不能弹回',
      );

      final settingsFile = File(state.paths.settingsPath);
      await tester.runAsync(() async {
        // 写盘是异步的：轮询等待 ui 段出现，不靠固定 sleep。
        for (var i = 0; i < 100; i++) {
          if (uiSpiderDebugLog(settingsFile) == true &&
              uiIncognito(settingsFile) == true) {
            return;
          }
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      expect(
        uiSpiderDebugLog(settingsFile),
        isTrue,
        reason: 'settings.json 的 ui 段必须写入 spiderDebugLog',
      );
      expect(
        uiIncognito(settingsFile),
        isTrue,
        reason: '隐身模式必须真的落盘（不是只改内存）',
      );

      await tapSwitch(tester, logTile);
      expect(state.spiderDebugLog, isFalse);
      expect(tile(tester, logKey).value, isFalse, reason: '再拨一次必须回显为关');
    });

    testWidgets('长按画面倍速：默认 3×，改档后回显并落盘', (tester) async {
      await pumpOverview(tester);
      expect(state.playerOptions.longPressSpeed, 3, reason: '默认必须是 3×');

      // 「长按画面倍速」在「播放参数」明细页：业务断言原样保留，
      // 前面只多一步——经分类页上的行真实进入该页（不直接 push、不碰私有状态）。
      await tester.tap(
        find.byKey(const ValueKey('settings-category-playback')),
      );
      await pumpSettingsSettled(tester);
      await tapCategoryRow(
        tester,
        category: 'playback',
        rowKey: 'settings-player-options-open',
      );
      expect(
        find.widgetWithText(AppBar, '播放参数'),
        findsOneWidget,
        reason: '必须先进入播放参数明细页',
      );
      expect(
        find.byKey(const ValueKey('settings-player-options-open')),
        findsNothing,
        reason: '明细页必须盖住分类页（长按倍速在明细页里）',
      );

      final tile = find.byKey(
        const ValueKey('settings-player-long-press-speed'),
      );
      await tester.scrollUntilVisible(
        tile,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(tile);
      await pumpSettingsSettled(tester);

      final dropdown = find.descendant(
        of: tile,
        matching: find.byType(DropdownButton<double>),
      );
      expect(dropdown, findsOneWidget);
      expect(
        find.descendant(of: tile, matching: find.text('3×')),
        findsOneWidget,
        reason: '关闭态必须回显当前档位',
      );

      await tester.tap(dropdown);
      await tester.pumpAndSettle();
      await tester.tap(find.text('4×').last);
      await tester.pump();
      // onChanged 里 await 真实写盘：假时钟等不到，放行真实 IO 再重建。
      await tester.runAsync(() async {
        final file = File(state.paths.settingsPath);
        for (var i = 0; i < 100; i++) {
          if (playerLongPressSpeed(file) == 4) return;
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      await tester.pumpAndSettle();

      expect(state.playerOptions.longPressSpeed, 4);
      expect(
        find.descendant(of: tile, matching: find.text('4×')),
        findsOneWidget,
        reason: '改档后必须回显为 4×，不能弹回',
      );
      expect(
        playerLongPressSpeed(File(state.paths.settingsPath)),
        4,
        reason: 'settings.json 的 player.longPressSpeed 必须写入',
      );
    });
  });
}

/// 读 settings.json 的 player.longPressSpeed；文件/段/键缺失都返回 null。
double? playerLongPressSpeed(File file) {
  if (!file.existsSync()) return null;
  try {
    final root = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    final player = root['player'];
    if (player is! Map) return null;
    final value = player['longPressSpeed'];
    return value is num ? value.toDouble() : null;
  } catch (_) {
    return null;
  }
}

/// 读 settings.json 的 ui.spiderDebugLog；文件/段/键缺失都返回 null。
bool? uiSpiderDebugLog(File file) {
  if (!file.existsSync()) return null;
  try {
    final root = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    final ui = root['ui'];
    if (ui is! Map) return null;
    final value = ui['spiderDebugLog'];
    return value is bool ? value : null;
  } catch (_) {
    return null;
  }
}

/// 读 settings.json 顶层的 incognito；文件/键缺失都返回 null。
bool? uiIncognito(File file) {
  if (!file.existsSync()) return null;
  try {
    final root = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    final value = root['incognito'];
    return value is bool ? value : null;
  } catch (_) {
    return null;
  }
}
