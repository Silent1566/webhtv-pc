/// 首页装配层：空态与 hero 高度公式。
///
/// 为什么只测这两件：排序/去重归 buildHomeFeed（test/home_feed_test.dart），
/// 卡片与轨道归 HomeRailView（test/home_cards_test.dart），轮播归 HomeHero
/// （test/home_hero_test.dart）。本页只剩「取数 → 折模型 → 装配」这一层，
/// 所以这里钉住的是它自己的行为：没有内容时不许留白屏、hero 高度必须按公式走。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/home_page.dart';
import 'package:webhtv_pc/ui/theme.dart';

import 'support/detail_test_seams.dart';

void main() {
  late Directory tempDir;
  late AppState state;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('webhtv-home-page');
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

  Future<void> pumpHome(
    WidgetTester tester, {
    required VoidCallback onOpenBrowse,
    required VoidCallback onImportConfig,
    ValueChanged<String>? onSearch,
  }) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.dark),
        home: Scaffold(
          body: HomePage(
            state: state,
            onOpenBrowse: onOpenBrowse,
            onOpenHistory: () {},
            onOpenFollowing: () {},
            onImportConfig: onImportConfig,
            onSearch: onSearch ?? (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('没有配置：首屏是占满 hero 高度的空态，不是白屏', (tester) async {
    var browsed = false;
    var imported = false;
    await pumpHome(
      tester,
      onOpenBrowse: () => browsed = true,
      onImportConfig: () => imported = true,
    );

    final hero = find.byKey(const ValueKey('home-empty-hero'));
    expect(hero, findsOneWidget);
    expect(find.text('还没有导入配置'), findsOneWidget);
    // 用例里的历史行没有 16:9 背景图 → 收到 62%：800 × 0.62 = 496。
    expect(tester.getSize(hero).height, closeTo(496, 0.5));
    expect(find.byKey(const ValueKey('home-scroll')), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const ValueKey('home-empty-action')));
    expect(imported, isTrue);
    expect(browsed, isFalse);
  });

  testWidgets('没有背景图时 hero 收到 62%，小窗口撞到 360 下限', (tester) async {
    await pumpHome(tester, onOpenBrowse: () {}, onImportConfig: () {});

    tester.view.physicalSize = const Size(1024, 560);
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byKey(const ValueKey('home-empty-hero'))).height,
      closeTo(360, 0.5),
      reason: '560 × 0.62 = 347，低于下限 360，必须夹到 360',
    );

    // 只有低于下限才夹：300 高的窗口里 hero 仍是 360（否则标题与按钮挤不下）。
    tester.view.physicalSize = const Size(1024, 300);
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byKey(const ValueKey('home-empty-hero'))).height,
      closeTo(360, 0.5),
    );
  });

  testWidgets('有配置但没看过任何东西：空态给出「去点播逛逛」这一条出路', (tester) async {
    await state.importConfig(
      '{"sites":[{"key":"demo","name":"示例","type":3,"api":"c1","searchable":1,'
      '"quickSearch":1,"filter":0}]}',
      displayName: 'demo',
    );
    var browsed = false;
    await pumpHome(
      tester,
      onOpenBrowse: () => browsed = true,
      onImportConfig: () {},
    );

    expect(find.text('还没有可续播的内容'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('home-empty-action')));
    expect(browsed, isTrue);
  });
}
