import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> openAboutDataSettings(WidgetTester tester) async {
  await selectSettingsCategory(tester, 'maintenance');
  final entry = find.byKey(const ValueKey('settings-about-data-open'));
  await tester.scrollUntilVisible(
    entry,
    180,
    scrollable: find.descendant(
      of: find.byKey(const ValueKey('settings-category-content-maintenance')),
      matching: find.byType(Scrollable),
    ),
  );
  await tester.tap(entry);
  await tester.pumpAndSettle(
    const Duration(milliseconds: 50),
    EnginePhase.sendSemanticsUpdate,
    const Duration(seconds: 5),
  );
}

/// 设置页的分类开关（宽窗左栏与窄窗顶部分类条共用同一组 key）。
///
/// 五个分类是**公开契约**（`diagnostics_pages.dart` 的 `kSettingsCategories`）：
/// preferences / playback / sites / connections / maintenance。这里再列一次是为了
/// 让拼错类别名的用例在**选择之前**就红，而不是在后面一条无关的 findsNothing 上红。
Future<void> selectSettingsCategory(
  WidgetTester tester,
  String category,
) async {
  expect(
    const ['preferences', 'playback', 'sites', 'connections', 'maintenance'],
    contains(category),
    reason: '未知设置类别：$category',
  );
  final control = find.byKey(ValueKey('settings-category-$category'));
  expect(control, findsOneWidget, reason: '设置分类入口必须唯一：$category');
  await tester.ensureVisible(control);
  await tester.pump(const Duration(milliseconds: 100));
  await tester.tap(control);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}
