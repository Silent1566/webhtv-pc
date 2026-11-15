/// 设置分类页「行 → 明细页」的测试导航助手。
///
/// 为什么集中在 support 里：分类页上的行入口（播放参数 / 屏显 / 弹幕源 /
/// 分组规则 / 出站代理 / DoH / 直播 / 浏览器内核 / 关于与数据 / 运行环境 …）
/// 在四个套件里都要走一遍。直接 `Navigator.push` 会绕过行的 `onTap` 与滚动
/// 可达性，行 key 失效后测试仍然绿——所以只走「真实点击行 + 真实点返回」。
///
/// 旧形态（「高级设置」中枢整页）已被删除：它的 18 行散进五个分类，任意设置
/// 最多两级可达。于是助手从「中枢滚动 → 行」改为「**某个分类的滚动视图内**
/// 滚到行 → 行」，并保留「返回后回到原分类页」的口径。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 有界 `pumpAndSettle`（超时 5 秒）。
///
/// 理由与 `phase8_settings_entries_test.dart` 同：写盘续体落在真实事件循环上，
/// 假时钟只能推进路由动画；有界超时让将来的挂起是几秒失败而不是 10 分钟。
Future<void> pumpSettingsSettled(WidgetTester tester) => tester.pumpAndSettle(
  const Duration(milliseconds: 50),
  EnginePhase.sendSemanticsUpdate,
  const Duration(seconds: 5),
);

/// 某个分类正文的滚动视图（`settings-category-content-<id>` 的 `ListView`）。
///
/// 按**内容区 key** 取而不是 `find.byType(Scrollable).first`：明细页被 push 上来
/// 后旧路由仍然在树里，按类型取会命中明细页自己的滚动视图；分类正文里还可能有
/// `SelectableText` 这类自带 `Scrollable` 的控件。
Finder categoryScrollable(String category) => find
    .descendant(
      of: find.byKey(ValueKey('settings-category-content-$category')),
      matching: find.byType(Scrollable),
    )
    .first;

/// 把某个分类里的某一行滚进视口（不点击）。
///
/// 拆出来是因为「返回后保留滚动位置」那类断言必须在**这一行已滚到位之后**
/// 再记录偏移：`ensureVisible` 本身会小幅调整滚动，早记录会得到假失败。
Future<void> revealCategoryRow(
  WidgetTester tester, {
  required String category,
  required String rowKey,
}) async {
  final row = find.byKey(ValueKey(rowKey));
  await tester.scrollUntilVisible(
    row,
    200,
    scrollable: categoryScrollable(category),
  );
  await tester.ensureVisible(row);
  await pumpSettingsSettled(tester);
  expect(row, findsOneWidget, reason: '分类 $category 缺少入口行：$rowKey');
}

/// 真实点击分类页上的一行：滚进视口 → `ensureVisible` → `tap`。
Future<void> tapCategoryRow(
  WidgetTester tester, {
  required String category,
  required String rowKey,
}) async {
  await revealCategoryRow(tester, category: category, rowKey: rowKey);
  await tester.tap(find.byKey(ValueKey(rowKey)));
  await pumpSettingsSettled(tester);
}

/// 把分类正文滚回顶部（真实拖拽，不直接改 `ScrollPosition`）。
///
/// `ListView` 懒构建：当前视口以下的行走下去找得到，视口**以上**的行却永远
/// 拖不到。同一用例里要先后访问两端时，先回到顶部再向下扫。
Future<void> scrollCategoryToTop(WidgetTester tester, String category) async {
  await tester.drag(categoryScrollable(category), const Offset(0, 4000));
  await pumpSettingsSettled(tester);
}

/// 真实点击明细页 AppBar 的返回按钮，回到分类页。
Future<void> backFromSettingsDetail(WidgetTester tester) async {
  final back = find.byType(BackButton);
  expect(back, findsOneWidget, reason: '明细页必须有可点的返回按钮');
  await tester.tap(back);
  await pumpSettingsSettled(tester);
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
Future<void> settleSettingsIo(WidgetTester tester, {int rounds = 12}) async {
  for (var round = 0; round < rounds; round++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 16)),
    );
  }
  await pumpSettingsSettled(tester);
}
