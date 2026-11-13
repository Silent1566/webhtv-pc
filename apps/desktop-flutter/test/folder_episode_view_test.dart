import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'multi_folder_ui_test.dart' show FolderFixture, openFolder;
import 'support/test_fonts.dart';

void main() {
  setUpAll(loadFixtureFonts);
  late FolderFixture fixture;
  setUp(() async {
    fixture = FolderFixture();
    await fixture.initialize();
  });
  tearDown(() => fixture.state.dispose());

  testWidgets(
    'explicit episode mode shows directory title file titles and browseable children',
    (tester) async {
      await openFolder(tester, fixture);
      expect(find.byKey(const ValueKey('folder-list')), findsOneWidget);
      await tester.tap(find.text('剧集模式'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('folder-episodes')), findsOneWidget);
      expect(find.text('资料库'), findsWidgets);
      expect(find.text('影片 1'), findsOneWidget);
      expect(find.text('影片 2'), findsOneWidget);
      expect(find.text('影片 10'), findsOneWidget);
      expect(
        fixture.calls.where((u) => u.queryParameters['ids'] != null),
        isEmpty,
      );
      await tester.tap(find.text('影集'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('folder-list')),
        findsOneWidget,
        reason: '进入子目录不自动强制剧集模式',
      );
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('folder-episodes')),
        findsOneWidget,
        reason: '父目录模式在路由返回后保留',
      );
      await tester.tap(find.text('文件列表'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('folder-list')), findsOneWidget);
    },
  );
}
