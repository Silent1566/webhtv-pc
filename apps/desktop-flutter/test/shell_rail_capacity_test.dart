/// 侧栏容量回归：11 个入口必须能放进应用自报的最小窗口（1024×640）。
///
/// 为什么要有这条用例：app.dart 的 minimumSize 是 1024×640，顶栏吃掉 64px
/// 之后内容区只有 576px。实测（2026-11-19，加首页之前）**10 项就已经溢出 8px**，
/// 加第 11 项溢 72px。修法是 NavigationRail(scrollable: true)——这条用例把
/// 「溢出会变成异常」这件事钉住，避免以后再加入口时无声破图。
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

  testWidgets('最小窗口 1024×640 下 11 个入口不溢出', (tester) async {
    await pumpSideBar(tester, const Size(1024, 640));
    expect(tester.takeException(), isNull, reason: '侧栏在最小窗口下溢出');
    final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
    expect(rail.destinations.length, ShellSection.values.length);
    expect(rail.scrollable, isTrue, reason: '放不下时必须可滚动，而不是溢出');
  });

  testWidgets('改名与新增都在位：首页 + 点播', (tester) async {
    await pumpSideBar(tester, const Size(1280, 800));
    expect(find.text('首页'), findsOneWidget);
    expect(find.text('点播'), findsOneWidget);
    final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
    expect(rail.selectedIndex, ShellSection.home.index);
  });
}
