/// 「设置 → 直播 → 直播站识别」的 UI 门禁：默认两条关键词、能加、能删、能恢复默认。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/live_site_keywords.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/settings_detail_pages.dart';
import 'package:webhtv_pc/ui/theme.dart';

import 'support/detail_test_seams.dart';

void main() {
  late Directory tempDir;
  late AppState state;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('webhtv-live-keywords-ui');
    state = AppState(
      paths: AppPaths.resolve(
        overrides: {
          'config': '${tempDir.path}/webhtv-pc',
          'data': '${tempDir.path}/webhtv-pc',
          'cache': '${tempDir.path}/webhtv-pc/cache',
          'state': '${tempDir.path}/webhtv-pc/logs',
        },
      ),
      log: MemoryOnlyLogService(),
    );
    await bootstrapWithoutExternalMeta(state);
  });

  tearDown(() async {
    state.dispose();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  /// 等真实 I/O：设置项的 notifyListeners 排在落盘之后，`pumpAndSettle` 不等真实异步。
  Future<void> settleWithIo(WidgetTester tester) async {
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pumpAndSettle();
  }

  Future<void> pumpPage(WidgetTester tester) async {
    // 这一页很长：给足高度，避免目标区块落在视口外而没被构建。
    tester.view.physicalSize = const Size(1280, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.dark),
        home: Scaffold(body: LiveSettingsPage(state: state)),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('默认两条关键词都在界面上，且能加能删能恢复默认', (tester) async {
    await pumpPage(tester);

    expect(find.text('直播站识别'), findsOneWidget);
    for (final keyword in liveSiteDefaultKeywords) {
      expect(
        find.byKey(ValueKey('live-site-keywords-chip-$keyword')),
        findsOneWidget,
        reason: keyword,
      );
    }

    await tester.enterText(
      find.byKey(const ValueKey('live-site-keywords-input')),
      '斗鱼',
    );
    await tester.tap(find.byKey(const ValueKey('live-site-keywords-add')));
    await settleWithIo(tester);
    expect(state.liveSiteKeywords, contains('斗鱼'));
    expect(find.byKey(const ValueKey('live-site-keywords-chip-斗鱼')), findsOneWidget);

    // InputChip 的删除是尾部的删除图标，点整块只会命中标签。
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('live-site-keywords-chip-斗鱼')),
        matching: find.byIcon(Icons.clear),
      ),
    );
    await settleWithIo(tester);
    expect(state.liveSiteKeywords, isNot(contains('斗鱼')));

    await tester.tap(find.byKey(const ValueKey('live-site-keywords-reset')));
    await settleWithIo(tester);
    expect(state.liveSiteKeywords, liveSiteDefaultKeywords);
    expect(tester.takeException(), isNull);
  });
}
