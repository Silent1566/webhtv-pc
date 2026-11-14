/// `TagChip` 的**选中态语义**回归锁。
///
/// 背景（真实缺陷，用户反馈 2026-10-11）：「筛选按钮貌似全是选中状态，点击也没反应」。
///
/// 根因是收敛三个私有 chip 实现时，把「`onTap == null`」当成了「静态标签」，
/// 于是筛选请求在途（`enabled == false`）时整排 chip 掉进静态分支：
/// **选中态被抹掉**、`InkWell` 也没了 —— 一排 chip 长得一模一样，点也不动。
///
/// 这里锁住的正是那条区分：
/// - **可选控件**（`selectable: true`）：`onTap == null` 只表示「当前禁用」，
///   **选中态必须照常渲染**，只是整体降透明度；
/// - **静态标签**（`selectable: false`）：本来就不该被当成控件，用填充底区分。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/ui/common.dart';
import 'package:webhtv_pc/ui/theme.dart';

/// 读某个 chip 的底色。
///
/// `TagChip.keyValue` 落在**装饰容器**上：可选控件是 `Material`，
/// 静态标签是 `Container`，所以两种都要能取到。
Color? _chipColor(WidgetTester tester, String key) {
  // 不能用 `tester.widgetList<Material>`：它会把命中的 widget **硬转**成
  // `Material`，遇到静态标签的 `Container` 直接抛 `_TypeError`。
  // 这里按运行时类型分派。
  final widget = tester.widget(find.byKey(ValueKey(key)));
  if (widget is Material) return widget.color;
  if (widget is Container) {
    final decoration = widget.decoration;
    if (decoration is BoxDecoration) return decoration.color;
  }
  return null;
}

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    MaterialApp(theme: buildAppTheme(Brightness.dark), home: Scaffold(body: child)),
  );
}

void main() {
  group('可选控件：选中态在禁用时也不能丢', () {
    testWidgets('启用时：选中与未选中底色不同，未选中为透明', (tester) async {
      await _pump(
        tester,
        const Row(
          children: [
            TagChip(
              keyValue: 'on-selected',
              label: '喜剧',
              selected: true,
              onTap: _noop,
              selectable: true,
            ),
            TagChip(
              keyValue: 'on-plain',
              label: '爱情',
              selected: false,
              onTap: _noop,
              selectable: true,
            ),
          ],
        ),
      );

      final selected = _chipColor(tester, 'on-selected');
      final plain = _chipColor(tester, 'on-plain');

      expect(selected, isNotNull);
      expect(selected, isNot(Colors.transparent), reason: '选中项必须有可见底色');
      expect(plain, Colors.transparent, reason: '未选中项用透明底（上百个 chip 全填色会糊成一片）');
      expect(selected, isNot(plain));
    });

    testWidgets('禁用（onTap == null）时：选中态仍然渲染，且与未选中仍可区分', (tester) async {
      await _pump(
        tester,
        const Row(
          children: [
            // onTap 为 null 表示「请求在途，暂时点不动」——不是静态标签。
            TagChip(
              keyValue: 'off-selected',
              label: '喜剧',
              selected: true,
              selectable: true,
            ),
            TagChip(
              keyValue: 'off-plain',
              label: '爱情',
              selected: false,
              selectable: true,
            ),
          ],
        ),
      );

      final selected = _chipColor(tester, 'off-selected');
      final plain = _chipColor(tester, 'off-plain');

      expect(
        selected,
        isNot(Colors.transparent),
        reason: '禁用的选中项仍必须有选中底色——这正是本次缺陷的核心：'
            '禁用抹掉了状态，一排 chip 看起来全被选中',
      );
      expect(plain, Colors.transparent);
      expect(
        selected,
        isNot(plain),
        reason: '禁用时选中与未选中必须仍能区分',
      );
    });

    testWidgets('禁用时仍然保留 InkWell（禁用不等于把控件变成静态文本）', (tester) async {
      await _pump(
        tester,
        const TagChip(
          keyValue: 'off-ink',
          label: '喜剧',
          selected: true,
          selectable: true,
        ),
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('off-ink')),
          matching: find.byType(InkWell),
        ),
        findsOneWidget,
      );
    });

    testWidgets('禁用时点击不触发回调', (tester) async {
      var taps = 0;
      await _pump(
        tester,
        TagChip(
          keyValue: 'off-tap',
          label: '喜剧',
          selected: true,
          selectable: true,
          onTap: null,
        ),
      );
      await tester.tap(find.byKey(const ValueKey('off-tap')));
      await tester.pump();
      expect(taps, 0);
    });

    testWidgets('启用时点击触发回调（筛选真的会生效）', (tester) async {
      var taps = 0;
      await _pump(
        tester,
        TagChip(
          keyValue: 'on-tap',
          label: '喜剧',
          selected: false,
          selectable: true,
          onTap: () => taps++,
        ),
      );
      await tester.tap(find.byKey(const ValueKey('on-tap')));
      await tester.pump();
      expect(taps, 1);
    });
  });

  group('静态标签：与可选控件区分开', () {
    testWidgets('静态标签用填充底（不是透明，也不是 Material）', (tester) async {
      await _pump(
        tester,
        const TagChip(keyValue: 'static', label: '2024'),
      );
      final color = _chipColor(tester, 'static');
      expect(color, isNotNull);
      expect(color, isNot(Colors.transparent));
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('static')),
          matching: find.byType(InkWell),
        ),
        findsNothing,
        reason: '静态标签不该带 InkWell',
      );
    });

    testWidgets('emphasized 静态标签用 primaryContainer', (tester) async {
      late Color expected;
      await _pump(
        tester,
        Builder(
          builder: (context) {
            expected = Theme.of(context).colorScheme.primaryContainer;
            return const TagChip(
              keyValue: 'static-emp',
              label: 'TMDB 8.2',
              emphasized: true,
            );
          },
        ),
      );
      expect(_chipColor(tester, 'static-emp'), expected);
    });
  });
}

void _noop() {}
