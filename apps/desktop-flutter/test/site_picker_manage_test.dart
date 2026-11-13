/// 站点选择器的手动排序 + 屏蔽交互（参照安卓 `SiteDialog`）。
///
/// 这里钉住三条用户可见规则：
/// 1. 被屏蔽站点默认不出现，只有「屏蔽管理」里才显示并标注；
/// 2. 屏蔽管理里点一行是**切换屏蔽**，不会离开对话框；
/// 3. 排序模式拖动一行立即回写新顺序，「恢复默认」回写的是一份空顺序。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/spider_router.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/app.dart';
import 'package:webhtv_pc/ui/theme.dart';

SiteListItem _item(String key, String name) => SiteListItem(
  site: Site(key: key, name: name, type: 1, api: 'https://example.test/$key'),
  availability: const SiteAvailability(available: true, runtimeName: 'http'),
);

void main() {
  final items = [_item('a', '木偶[盘]'), _item('b', '金牌[采]'), _item('c', '备用[盘]')];

  Future<void> pumpDialog(
    WidgetTester tester, {
    Set<String> blockedKeys = const {},
    List<String> defaultOrderKeys = const [],
    Future<bool> Function(List<String>)? onReorder,
    Future<bool> Function(String, bool)? onBlockedChanged,
  }) async {
    tester.view.physicalSize = const Size(1000, 820);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.dark),
        home: SitePickerDialog(
          items: items,
          log: LogService(),
          blockedKeys: blockedKeys,
          defaultOrderKeys: defaultOrderKeys,
          onReorder: onReorder,
          onBlockedChanged: onBlockedChanged,
        ),
      ),
    );
    await tester.pump();
  }

  Finder row(String key) => find.byKey(ValueKey('site-option-$key'));

  testWidgets('被屏蔽站点默认不出现；屏蔽管理里显示并标注已屏蔽', (tester) async {
    final blockedCalls = <(String, bool)>[];
    await pumpDialog(
      tester,
      blockedKeys: {'b'},
      onBlockedChanged: (key, blocked) async {
        blockedCalls.add((key, blocked));
        return true;
      },
    );

    expect(row('a'), findsOneWidget);
    expect(row('b'), findsNothing, reason: '被屏蔽站点在普通列表里必须消失');
    expect(find.text('已屏蔽'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('site-block-toggle')));
    await tester.pumpAndSettle();

    expect(row('b'), findsOneWidget, reason: '屏蔽管理必须能看到已屏蔽站点');
    expect(find.text('已屏蔽'), findsOneWidget);
    final dim = tester.widget<Opacity>(
      find.ancestor(of: row('b'), matching: find.byType(Opacity)).first,
    );
    expect(dim.opacity, closeTo(0.55, 0.001), reason: '被屏蔽行必须压暗');

    // 屏蔽管理里点一行 = 切换屏蔽，不能离开对话框（Android onTextClick 同义）。
    await tester.tap(row('b'));
    await tester.pumpAndSettle();

    expect(blockedCalls, [('b', false)], reason: '取消屏蔽必须回写 AppState');
    expect(find.byType(SitePickerDialog), findsOneWidget);
    expect(find.text('已屏蔽'), findsNothing, reason: '取消屏蔽后标记立即消失');
  });

  testWidgets('屏蔽管理里点击正常站点会屏蔽它', (tester) async {
    final blockedCalls = <(String, bool)>[];
    await pumpDialog(
      tester,
      onBlockedChanged: (key, blocked) async {
        blockedCalls.add((key, blocked));
        return true;
      },
    );

    await tester.tap(find.byKey(const ValueKey('site-block-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(row('c'));
    await tester.pumpAndSettle();

    expect(blockedCalls, [('c', true)]);
    expect(find.byType(SitePickerDialog), findsOneWidget);
    expect(find.text('已屏蔽'), findsOneWidget);
  });

  testWidgets('排序模式：拖动一行立即回写新顺序，「恢复默认」回写空顺序', (tester) async {
    final orderCalls = <List<String>>[];
    await pumpDialog(
      tester,
      defaultOrderKeys: ['a', 'b', 'c'],
      onReorder: (keys) async {
        orderCalls.add(keys);
        return true;
      },
    );

    await tester.tap(find.byKey(const ValueKey('site-sort-toggle')));
    await tester.pumpAndSettle();

    expect(find.byType(ReorderableListView), findsOneWidget);
    expect(
      find.byIcon(Icons.drag_handle),
      findsNWidgets(items.length),
      reason: '每一行都要有拖动手柄',
    );

    // 把第一行（a）向下拖过一行：顺序变成 b, a, c。
    await tester.drag(
      find.byIcon(Icons.drag_handle).first,
      const Offset(0, 120),
    );
    await tester.pumpAndSettle();

    expect(orderCalls, isNotEmpty, reason: '拖动后必须回写顺序');
    expect(orderCalls.last, ['b', 'a', 'c']);
    expect(find.text('拖动右侧手柄调整顺序，改动自动保存（共 3 个站点）'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('site-sort-reset')));
    await tester.pumpAndSettle();

    expect(orderCalls.last, isEmpty, reason: '恢复默认 = 清掉保存的手动顺序');
  });

  testWidgets('未接回调时不出现排序/屏蔽入口（旧调用点保持原样）', (tester) async {
    await pumpDialog(tester);

    expect(find.byKey(const ValueKey('site-sort-toggle')), findsNothing);
    expect(find.byKey(const ValueKey('site-block-toggle')), findsNothing);
    expect(find.byType(ReorderableListView), findsNothing);
  });

  testWidgets('排序模式保存整份顺序，不受关键字筛选影响', (tester) async {
    final orderCalls = <List<String>>[];
    await pumpDialog(
      tester,
      defaultOrderKeys: ['a', 'b', 'c'],
      onReorder: (keys) async {
        orderCalls.add(keys);
        return true;
      },
    );

    await tester.enterText(find.byKey(const ValueKey('site-search')), '木偶');
    await tester.pumpAndSettle();
    expect(row('b'), findsNothing, reason: '前提：关键字已经筛掉两个站点');

    await tester.tap(find.byKey(const ValueKey('site-sort-toggle')));
    await tester.pumpAndSettle();

    expect(
      find.byIcon(Icons.drag_handle),
      findsNWidgets(items.length),
      reason: '排序模式必须给出整份配置，不能只排筛选后的子集',
    );

    await tester.drag(
      find.byIcon(Icons.drag_handle).first,
      const Offset(0, 120),
    );
    await tester.pumpAndSettle();

    expect(
      orderCalls.last,
      hasLength(items.length),
      reason: '整份顺序都要落盘，否则被筛掉的站点会丢掉位置',
    );
  });

  testWidgets('「完成排序」回到站点列表，而不是关掉对话框', (tester) async {
    await pumpDialog(
      tester,
      defaultOrderKeys: ['a', 'b', 'c'],
      onReorder: (_) async => true,
      onBlockedChanged: (_, _) async => true,
    );

    await tester.tap(find.byKey(const ValueKey('site-sort-toggle')));
    await tester.pumpAndSettle();
    expect(find.byType(ReorderableListView), findsOneWidget);

    await tester.tap(find.text('完成排序'));
    await tester.pumpAndSettle();

    expect(find.byType(ReorderableListView), findsNothing);
    expect(
      find.byKey(const ValueKey('site-search')),
      findsOneWidget,
      reason: '退出排序模式要能接着选站点，不能逼用户关掉对话框重开',
    );
    expect(find.byType(SitePickerDialog), findsOneWidget);
  });

  testWidgets('分组内的站点被全部屏蔽后，分组筛选自动复位', (tester) async {
    await pumpDialog(tester, onBlockedChanged: (_, _) async => true);

    await tester.tap(find.byKey(const ValueKey('site-group-采')));
    await tester.pumpAndSettle();
    expect(row('b'), findsOneWidget);
    expect(row('a'), findsNothing, reason: '前提：分组筛选生效');

    // 进屏蔽管理，把「采」组唯一剩下的站点屏蔽掉，再退出。
    await tester.tap(find.byKey(const ValueKey('site-block-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(row('b'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('site-block-toggle')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('site-group-采')),
      findsNothing,
      reason: '该分组只剩被屏蔽站点，chip 应当消失',
    );
    expect(
      find.text('没有匹配的站点'),
      findsNothing,
      reason: '分组筛选必须复位，而不是留下一个看不见的空分组',
    );
    expect(row('a'), findsOneWidget);
    expect(row('c'), findsOneWidget);
  });
}
