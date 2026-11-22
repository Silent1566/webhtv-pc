/// 侧栏容量与入口集合回归：8 个入口必须能放进应用自报的最小窗口（1024×640）。
///
/// 为什么要有这条用例：app.dart 的 minimumSize 是 1024×640，顶栏吃掉 64px
/// 之后内容区只有 576px。实测（2026-11-19，加首页之前）**10 项就已经溢出 8px**，
/// 加第 11 项溢 72px。修法是 NavigationRail(scrollable: true)——这条用例把
/// 「溢出会变成异常」这件事钉住，避免以后再加入口时无声破图。
///
/// 2026-11-22 用户决策把 Spider / 日志 / AI·阅读器收进设置（11 → 8 项）：入口
/// 集合本身也成了契约，所以这里同时钉住「侧栏只有这 8 个、且顺序与
/// `ShellSection` 一致」。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/ui/app.dart';
import 'package:webhtv_pc/ui/theme.dart';

void main() {
  Future<void> pumpSideBar(WidgetTester tester, Size window) async {
    tester.view.physicalSize = window;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.dark),
        home: Scaffold(
          body: Column(
            children: [
              // 顶栏：外壳里真实存在的 64px。
              const SizedBox(height: 64),
              Expanded(
                child: Row(
                  children: [
                    AppSideBar(
                      section: ShellSection.home,
                      onSelect: (_) {},
                      updateCount: 0,
                    ),
                    const Expanded(child: SizedBox()),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  test('首页排在第一位（selectedIndex 与 destinations 顺序强耦合）', () {
    expect(ShellSection.home.index, 0);
    expect(ShellSection.values.first, ShellSection.home);
  });

  testWidgets('最小窗口 1024×640 下 8 个入口真的放得下（不是靠滚动兜底）', (tester) async {
    await pumpSideBar(tester, const Size(1024, 640));
    expect(tester.takeException(), isNull, reason: '侧栏在最小窗口下溢出');
    final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
    expect(rail.destinations.length, ShellSection.values.length);
    expect(rail.scrollable, isTrue, reason: '放不下时必须可滚动，而不是溢出');
    // `scrollable: true` 让「放不下」变成滚动而不是 overflow 异常，所以
    // `takeException` 对多少个入口都恒为 null——真正能变红的断言是位置：
    // 最后一项必须整个落在侧栏矩形内，加回入口时它会掉到 rect.bottom 之下。
    final railRect = tester.getRect(find.byType(NavigationRail));
    final last = tester.getRect(
      find.descendant(
        of: find.byType(NavigationRail),
        matching: find.text('设置'),
      ),
    );
    expect(
      last.bottom,
      lessThanOrEqualTo(railRect.bottom),
      reason: '第 8 项被挤出可视区：入口集合又长回去了',
    );
    expect(last.top, greaterThanOrEqualTo(railRect.top));
  });

  testWidgets('上一条真的会红：更矮的窗口下最后一项确实落到侧栏外', (tester) async {
    // 红-绿自检：证明「最后一项必须在侧栏矩形内」不是恒真断言。
    // 320px 高装不下 8 项，最后一项必须掉到 rect.bottom 之下。
    await pumpSideBar(tester, const Size(1024, 320));
    final railRect = tester.getRect(find.byType(NavigationRail));
    final last = tester.getRect(
      find.descendant(
        of: find.byType(NavigationRail),
        matching: find.text('设置'),
      ),
    );
    expect(last.bottom, greaterThan(railRect.bottom));
  });

  testWidgets('改名与新增都在位：首页 + 点播', (tester) async {
    await pumpSideBar(tester, const Size(1280, 800));
    expect(find.text('首页'), findsOneWidget);
    expect(find.text('点播'), findsOneWidget);
    final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
    expect(rail.selectedIndex, ShellSection.home.index);
  });

  testWidgets('侧栏只放看片链路 + 设置：顺序与 ShellSection 一一对应', (tester) async {
    await pumpSideBar(tester, const Size(1280, 800));
    expect(ShellSection.values.map((section) => section.name).toList(), [
      'home',
      'browse',
      'live',
      'search',
      'history',
      'favorites',
      'following',
      'settings',
    ]);
    const labels = ['首页', '点播', '直播', '搜索', '最近观看', '收藏', '追剧', '设置'];
    final rail = find.byType(NavigationRail);
    expect(
      [
        for (final label in labels)
          tester.widget<Text>(
            find.descendant(of: rail, matching: find.text(label)),
          ).data,
      ],
      labels,
    );
    // 低频入口一律进设置：Spider / 日志 / AI·阅读器 不得回到侧栏。
    for (final gone in ['Spider', '日志', 'AI / 阅读器']) {
      expect(
        find.descendant(of: rail, matching: find.text(gone)),
        findsNothing,
        reason: '$gone 已收进设置，不得再占一个侧栏入口',
      );
    }
  });
}
