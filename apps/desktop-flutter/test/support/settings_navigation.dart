import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> selectSettingsCategory(
  WidgetTester tester,
  String category,
) async {
  expect(
    const ['preferences', 'playback', 'connections', 'maintenance'],
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
