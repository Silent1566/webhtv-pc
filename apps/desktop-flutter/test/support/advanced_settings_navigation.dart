/// 高级设置「中枢行 → 三级明细页」的测试导航助手。
///
/// 为什么集中在 support 里：六条明细路由的进入/返回在三个既有套件与新增的
/// 导航套件里都要用。直接 `Navigator.push` 会绕过行的 `onTap` 与滚动可达性，
/// 行 key 失效后测试仍然绿——所以只走「真实点击行 + 真实点返回」。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/ui/advanced_settings_page.dart';

/// 有界 `pumpAndSettle`（超时 5 秒）。
///
/// 理由与 `phase8_settings_entries_test.dart` 同：写盘续体落在真实事件循环上，
/// 假时钟只能推进路由动画；有界超时让将来的挂起是几秒失败而不是 10 分钟。
Future<void> pumpAdvanced(WidgetTester tester) => tester.pumpAndSettle(
  const Duration(milliseconds: 50),
  EnginePhase.sendSemanticsUpdate,
  const Duration(seconds: 5),
);

/// 中枢自己的滚动视图。
///
/// 明细页被 push 上来后旧路由变成离屏；按页面类型取子孙视图既避开明细页里
/// 自己的 `ListView`，也不会在回到中枢后命中两个 `Scrollable`。
Finder advancedHubScrollable() => find
    .descendant(
      of: find.byType(AdvancedSettingsPage),
      matching: find.byType(Scrollable),
    )
    .first;

/// 把中枢上的某一行滚进视口（不点击）。
///
/// 拆出来是因为「返回后中枢保留滚动位置」那类断言必须在**这一行已滚到位之后**
/// 再记录偏移：`ensureVisible` 本身会小幅调整滚动，早记录会得到假失败。
Future<void> revealAdvancedRow(WidgetTester tester, String rowKey) async {
  final row = find.byKey(ValueKey(rowKey));
  await tester.scrollUntilVisible(
    row,
    200,
    scrollable: advancedHubScrollable(),
  );
  await tester.ensureVisible(row);
  await pumpAdvanced(tester);
  expect(row, findsOneWidget, reason: '高级设置中枢缺少入口行：$rowKey');
}

/// 真实点击中枢上的一行：滚进视口 → `ensureVisible` → `tap`。
Future<void> tapAdvancedRow(WidgetTester tester, String rowKey) async {
  await revealAdvancedRow(tester, rowKey);
  await tester.tap(find.byKey(ValueKey(rowKey)));
  await pumpAdvanced(tester);
}

/// 把中枢滚回顶部（真实拖拽，不直接改 `ScrollPosition`）。
///
/// 中枢的 `ListView` 懒构建：当前视口以下的行走下去找得到，视口**以上**的行
/// 却永远拖不到。同一用例里要先后访问两端时，先回到顶部再向下扫。
Future<void> scrollHubToTop(WidgetTester tester) async {
  await tester.drag(advancedHubScrollable(), const Offset(0, 4000));
  await pumpAdvanced(tester);
}

/// 真实点击明细页 AppBar 的返回按钮，回到中枢。
Future<void> backFromAdvancedDetail(WidgetTester tester) async {
  final back = find.byType(BackButton);
  expect(back, findsOneWidget, reason: '明细页必须有可点的返回按钮');
  await tester.tap(back);
  await pumpAdvanced(tester);
}

/// 真实 I/O 放行：写盘续体落在真实事件循环，假时钟推不动，按条件轮询。
Future<void> waitForRealIo(WidgetTester tester, bool Function() done) async {
  await tester.runAsync(() async {
    for (var i = 0; i < 200 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  });
}

/// 交替「推进一帧 → 给真实 I/O 一点时间」，直到界面收敛。
///
/// 开关的形状是「同步改内存 → `await _persist()` → `notifyListeners()`」，
/// 界面刷新挂在通知上，而通知要等写盘完成。
Future<void> settleAdvancedIo(WidgetTester tester, {int rounds = 12}) async {
  for (var round = 0; round < rounds; round++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 16)),
    );
  }
  await pumpAdvanced(tester);
}
