/// 高级设置页开关回显回归测试。
///
/// 为什么需要这个测试：本页是 `Navigator.push` 出来的独立路由，`AppState`
/// 的通知到不了它，页面自己也不监听；一旦少掉 `ListenableBuilder`，受控开关
/// 拨动后父级不重建，视觉上就会弹回原值——整页所有开关同一根因，所以这里
/// 同时断言一个既有开关（隐身模式）和一个报障开关（详细调试日志）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/advanced_settings_page.dart';
import 'package:webhtv_pc/ui/theme.dart';

AppPaths tempPaths(Directory temp) => AppPaths.resolve(
  overrides: {
    'config': '${temp.path}${Platform.pathSeparator}config',
    'data': '${temp.path}${Platform.pathSeparator}data',
    'cache': '${temp.path}${Platform.pathSeparator}cache',
    'state': '${temp.path}${Platform.pathSeparator}logs',
  },
);

void main() {
  group('高级设置页开关回显', () {
    late Directory temp;
    late AppState state;

    setUp(() async {
      temp = Directory.systemTemp.createTempSync('webhtv-advanced-switch');
      state = AppState(paths: tempPaths(temp), log: LogService());
      await state.bootstrap();
    });

    tearDown(() {
      state.dispose();
      try {
        temp.deleteSync(recursive: true);
      } catch (_) {}
    });

    testWidgets('既有开关与详细调试日志开关拨动后都回显，并落盘 settings.json', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(900, 700);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.dark),
          home: AdvancedSettingsPage(state: state),
        ),
      );
      await tester.pump();

      final scrollable = find.byType(Scrollable).first;
      SwitchListTile tile(String key) =>
          tester.widget<SwitchListTile>(find.byKey(ValueKey(key)));

      // 开关的 onChanged 内部 `await` 真实写盘，假时钟的 pumpAndSettle 等不到
      // 它结束（notifyListeners 还没触发）；runAsync 放行真实 IO 与随后的通知，
      // 再用 pumpAndSettle 把重建落到帧上。
      Future<void> tapSwitch(Finder finder) async {
        await tester.tap(finder);
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pumpAndSettle();
      }

      // 既有开关：证明修的是整页监听，而不是只给报障的那个开关打了补丁。
      const incognitoKey = 'settings-incognito';
      final incognito = find.byKey(const ValueKey(incognitoKey));
      await tester.scrollUntilVisible(incognito, 200, scrollable: scrollable);
      expect(tile(incognitoKey).value, isFalse);
      await tapSwitch(incognito);
      expect(state.incognito, isTrue);
      expect(tile(incognitoKey).value, isTrue, reason: '既有开关也必须回显为开');

      // 报障开关：页面末尾的「详细调试日志（爬虫入参/出参）」。
      const logKey = 'settings-spider-debug-log';
      final logTile = find.byKey(const ValueKey(logKey));
      await tester.scrollUntilVisible(logTile, 200, scrollable: scrollable);
      expect(tile(logKey).value, isFalse);
      await tapSwitch(logTile);
      expect(state.spiderDebugLog, isTrue);
      expect(tile(logKey).value, isTrue, reason: '拨动后必须回显为开，不能弹回');

      final settingsFile = File(state.paths.settingsPath);
      await tester.runAsync(() async {
        // 写盘是异步的：轮询等待 ui 段出现，不靠固定 sleep。
        for (var i = 0; i < 100; i++) {
          if (uiSpiderDebugLog(settingsFile) == true) return;
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      expect(
        uiSpiderDebugLog(settingsFile),
        isTrue,
        reason: 'settings.json 的 ui 段必须写入 spiderDebugLog',
      );

      await tapSwitch(logTile);
      expect(state.spiderDebugLog, isFalse);
      expect(tile(logKey).value, isFalse, reason: '再拨一次必须回显为关');
    });
  });
}

/// 读 `settings.json` 的 `ui.spiderDebugLog`；文件/段/键缺失都返回 null。
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
