import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/osd_config.dart';
import 'package:webhtv_pc/core/player_options.dart';
import 'package:webhtv_pc/ui/player_context_menu.dart';
import 'package:webhtv_pc/ui/player_page.dart';

import 'support/player_page_harness.dart';

/// 从真实的 `PlayerPage` 右键菜单里读出内容结构。
///
/// **为什么不用「找到几个 widget」这种断言**：本轮的交付物是**一棵菜单树**
/// （10 组 / 多层 / 每层的选中态），「找到 10 个 Text」既证明不了分组标题
/// 是哪些，也证明不了某组下面真的有子项。这里读的是引擎按
/// `PlayerMenuItem` 渲染出来的每一行（行 = `InkWell`），逐行比对文字、
/// 对勾与可点状态。
Finder get _menuRows => find.descendant(
  of: find.byType(PlayerContextMenu),
  matching: find.byType(InkWell),
);

/// 第 [level] 列（0 = 主列）的表面。
Finder _columnSurface(WidgetTester tester, int level) => find
    .descendant(
      of: find.byType(PlayerContextMenu),
      matching: find.byType(Material),
    )
    .at(level);

/// 第 [level] 列（0 = 主列）的所有行。
List<InkWell> _rowsAt(WidgetTester tester, int level) {
  final surfaces = find
      .descendant(
        of: find.byType(PlayerContextMenu),
        matching: find.byType(Material),
      );
  if (level >= surfaces.evaluate().length) return const [];
  return tester
      .widgetList<InkWell>(
        find.descendant(of: surfaces.at(level), matching: find.byType(InkWell)),
      )
      .toList();
}

/// 一行上的文字。
String _labelOf(WidgetTester tester, InkWell row) => tester
    .widgetList<Text>(
      find.descendant(of: find.byWidget(row), matching: find.byType(Text)),
    )
    .map((t) => t.data ?? '')
    .join();

/// 一行是否带对勾（= `PlayerMenuItem.selected`）。
bool _isChecked(WidgetTester tester, InkWell row) => tester
    .widgetList(
      find.descendant(of: find.byWidget(row), matching: find.byIcon(Icons.check)),
    )
    .isNotEmpty;

/// 一行是否灰掉（= 引擎的 `enabled: false`：`onTap` 压根没挂）。
bool _isDisabled(WidgetTester tester, InkWell row) => row.onTap == null;

/// 主列里某一行是否带「飞出」指示（= 有 children）。
bool _hasFlyout(WidgetTester tester, InkWell row) => tester
    .widgetList(
      find.descendant(
        of: find.byWidget(row),
        matching: find.byIcon(Icons.chevron_right),
      ),
    )
    .isNotEmpty;

/// 打开右键菜单。
Future<void> _openMenu(
  WidgetTester tester, {
  Map<String, bool>? osdFlags,
}) async {
  await pumpPlayerPage(tester, osdFlags: osdFlags);
  await tester.tapAt(const Offset(300, 260), buttons: kSecondaryButton);
  await settlePlayerPage(tester);
  expect(find.byType(PlayerContextMenu), findsOneWidget, reason: '右键没能打开菜单');
}

/// 点 [label] 让那一行飞出下一列。
///
/// 先 `ensureVisible`：分组之外的列仍可能装不下（例如「字幕样式」的 5 项里
/// 还套着 4 棵子树），引擎会把任何一列压到可用高度内部滚动（\`design/04\` §5.2）。
/// 不滚到可见处 `tap` 会点在窗口外静默失效——那是**测试的问题**，不是菜单的。
Future<void> _drill(WidgetTester tester, String label) async {
  final target = find.descendant(
    of: find.byType(PlayerContextMenu),
    matching: find.text(label),
  );
  expect(target, findsWidgets, reason: '菜单里找不到「$label」');
  await tester.ensureVisible(target.first);
  await settlePlayerPage(tester, times: 2);
  await tester.tap(target.first);
  await settlePlayerPage(tester, times: 3);
}

void main() {
  // 本文件锁定的是**内容结构**（哪一组、有哪些层、当前值），不是引擎的
  // 渲染细节——后者在 `test/phase8_context_menu_test.dart` 里。
  group('右键菜单内容结构', () {
    testWidgets('主列恰好 10 个分组行（不再是 43 个平铺的项）', (tester) async {
      await _openMenu(tester);

      const titles = [
        '播放',
        '速度',
        '字幕',
        '画面',
        '声音',
        '轨道',
        '显示',
        '片头片尾',
        '信息',
        '设置',
      ];
      // 主列 = 第 1 列：每组一行、每行一个分组项（id 前缀 `section:`）。
      final sectionRows = _rowsAt(tester, 0);
      expect(
        sectionRows.length,
        10,
        reason: '主列必须恰好 10 行（用户报的就是「43 行平铺、速度的档位没进子菜单」）',
      );
      final rendered = [for (final row in sectionRows) _labelOf(tester, row)];
      expect(
        rendered,
        titles,
        reason: '顶层分组必须是这 10 个、且顺序固定（${rendered.join("/")}）',
      );
      // 每一行都必须是**可飞出的父项**：带 `▸`，且 key 是分组命名空间。
      for (var i = 0; i < sectionRows.length; i++) {
        final row = sectionRows[i];
        final key = (row.key! as ValueKey).value as String;
        expect(
          key,
          'player-menu-item-section:${titles[i]}',
          reason: '主列第 $i 行不是分组项',
        );
        expect(
          _hasFlyout(tester, row),
          isTrue,
          reason: '分组「${titles[i]}」没有 `▸`，用户看不出它能飞出',
        );
      }
      // 主列的项 key 恰 10 个 `section:*`，一个别的都没有。
      expect(
        find.descendant(
          of: find.byType(PlayerContextMenu),
          matching: find.byWidgetPredicate(
            (w) => w.key is ValueKey<String> &&
                (w.key! as ValueKey<String>).value.startsWith('player-menu-item-section:'),
          ),
        ),
        findsNWidgets(10),
      );
    });

    // 主列不再是 43 行长列表——这正是本轮改动要解决的形状。分开成一条用例，
    // 因为它的断言对象是**几何**（高度不需要内部滚动），不是内容。
    testWidgets('主列一屏放得下：高度 < 视口高 - 16，不需要滚动', (tester) async {
      await _openMenu(tester);
      final main = tester.getSize(_columnSurface(tester, 0));
      final viewport = tester.view.physicalSize / tester.view.devicePixelRatio;
      expect(
        main.height,
        lessThan(viewport.height - 16),
        reason: '主列放不下就得滚动，用户又会看不见下面的分组（main=$main）',
      );
      // 10 行 × 36 + 上下 xs 内边距 = 368。
      expect(main.height, 10 * 36 + 2 * 4);
    });

    testWidgets('分组行本身没有 selected 勾（勾只属于组内的叶子）', (tester) async {
      await _openMenu(tester);
      final rows = _rowsAt(tester, 0);
      expect(rows.length, 10);
      final checked = [
        for (final row in rows)
          if (_isChecked(tester, row)) _labelOf(tester, row),
      ];
      expect(checked, isEmpty, reason: '分组是容器不是状态项，不许打勾');
      // 全窗口范围内也恰好只有那一处"必须显示已生效"的勾，且都在叶子/组内。
      // 主列里一个 check 图标都不该有。
      expect(
        find.descendant(
          of: _columnSurface(tester, 0),
          matching: find.byIcon(Icons.check),
        ),
        findsNothing,
      );
      // 反向：组内的叶子仍然打勾——「必须显示已生效」没有被这次改动削掉。
      await _drill(tester, '速度');
      final rateRows = _rowsAt(tester, 1);
      final checkedRates = [
        for (final row in rateRows)
          if (_isChecked(tester, row)) _labelOf(tester, row),
      ];
      expect(checkedRates, ['1.0×']);
    });

    testWidgets('点「速度 ▸」：第 2 列恰好 6 档，1.0× 带选中勾', (tester) async {
      await _openMenu(tester);
      // 点之前：档位一个都看不见（它们不在主列里）。
      expect(find.text('1.0×'), findsNothing);
      await _drill(tester, '速度');
      final rows = _rowsAt(tester, 1);
      expect(rows.length, 6, reason: '速度组必须是 6 档，且落在第 2 列');
      expect(
        [for (final row in rows) _labelOf(tester, row)],
        ['0.5×', '0.75×', '1.0×', '1.25×', '1.5×', '2.0×'],
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('player-menu-item-rate_1.0')),
          matching: find.byIcon(Icons.check),
        ),
        findsOneWidget,
      );
    });

    testWidgets('悬停「速度」也会展开（不点击）', (tester) async {
      await _openMenu(tester);
      expect(_rowsAt(tester, 1), isEmpty, reason: '初始只有主列');
      // 必须用真实鼠标指针：touch 在抬起状态发不出 move，也就造不出 hover。
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      final target = find.descendant(
        of: find.byType(PlayerContextMenu),
        matching: find.text('速度'),
      );
      await mouse.moveTo(tester.getCenter(target.first));
      await settlePlayerPage(tester, times: 3);
      // 备注：分组行复用现有行级 MouseRegion(onEnter: _hoverOpen)，没有另写。
      expect(
        _rowsAt(tester, 1).length,
        6,
        reason: '悬停分组行必须飞出 6 档，用户不该为了看一眼先点一下',
      );
      await mouse.moveTo(Offset.zero);
    });

    testWidgets('逐个展开每个分组：第 2 列的行数与内容表一致（共 44 项）', (tester) async {
      await _openMenu(tester);

      // 计数口径从「主列行数」改成「该组飞出列的行数」——数字一个没变。
      const expected = <String, int>{
        '播放': 7,
        '速度': 6,
        '字幕': 4,
        '画面': 2,
        '声音': 3,
        '轨道': 5,
        '显示': 2,
        '片头片尾': 7,
        '信息': 3,
        // 设置组已从「3 个跳转入口」改造成下钻树：播放参数 / 字幕源 /
        // 弹幕库 / 控制栏按钮 / 完整设置页。
        '设置': 5,
      };
      for (final entry in expected.entries) {
        expect(entry.value, greaterThan(0), reason: '分组「${entry.key}」不得为空');
      }
      expect(
        expected.values.reduce((a, b) => a + b),
        44,
        reason: '十个分组的项数之和必须仍是 44（「播放」组多了「用外部播放器打开…」）',
      );
      for (final entry in expected.entries) {
        await _drill(tester, entry.key);
        expect(
          _rowsAt(tester, 1).length,
          entry.value,
          reason: '「${entry.key}」飞出列的行数不对',
        );
      }
    });

    // 死项检查现在要**走遍所有层级**：分组行把它们的孩子藏进了第 2 列，
    // 只扫主列会漏掉全部 44 个叶子。
    testWidgets('所有层级都没有死项：分组必有 children，叶子必须可点', (tester) async {
      await _openMenu(tester);
      const titles = [
        '播放',
        '速度',
        '字幕',
        '画面',
        '声音',
        '轨道',
        '显示',
        '片头片尾',
        '信息',
        '设置',
      ];

      // 第 1 层：每个分组行都必须**真的能飞出**（不是空 children 的假箭头）。
      final sectionRows = _rowsAt(tester, 0);
      expect(sectionRows.length, titles.length);
      for (final row in sectionRows) {
        final label = _labelOf(tester, row);
        expect(_hasFlyout(tester, row), isTrue, reason: '分组「$label」不能飞出子菜单');
        expect(row.onTap, isNotNull, reason: '分组「$label」点不开');
      }

      final disabled = <String>[];
      var sawLeaf = 0;
      for (final title in titles) {
        await _drill(tester, title);
        final rows = _rowsAt(tester, 1);
        expect(rows, isNotEmpty, reason: '分组「$title」飞出了空列');
        for (final row in rows) {
          final label = _labelOf(tester, row);
          final flyout = _hasFlyout(tester, row);
          if (!flyout && row.onTap == null) disabled.add(label);
          if (!flyout) sawLeaf++;
          // 与改动前同一条口径：**已知不可用**的叶子（条件不满足）允许没有
          // onTap，它们在下面被逐一点名核对；其余一律不许是死项。
          expect(
            flyout || row.onTap != null || disabled.contains(label),
            isTrue,
            reason: '「$title」组内的「$label」既不能飞出也没有动作——这是死项',
          );
        }
      }
      // 反向锁：不可点的项必须是**已知的、条件不满足**的那几个，
      // 而且它们不许从菜单里消失（用「隐藏」代替「灰掉」也算失败）。
      // 本用例的环境：单一音轨、本集无片头片尾标记、还没拿到播放诊断。
      expect(
        disabled,
        ['音轨…', '跳过片头', '跳过片尾', '清除本片标记', '播放诊断'],
        reason: '不可点项集合变了：要么新增了死项，要么「该灰的」被藏起来了',
      );
      // 44 项里减去 5 个不可点的叶子，其余叶子都必须真的能点
      // （不是「有 children 就都以为能点」）。
      expect(sawLeaf, greaterThan(25), reason: '叶子项数量异常（$sawLeaf）');
    });

    testWidgets('至少一条 3 层路径可走通：字幕 → 字幕样式 → 字号', (tester) async {
      await _openMenu(tester);

      // 列序：0 主列（分组行）→ 1 「字幕」组 → 2 字幕样式 → 3 字号。
      await _drill(tester, '字幕');
      await _drill(tester, '字幕样式');
      expect(_rowsAt(tester, 2).length, 5, reason: '字幕样式应有 5 个二级项');
      for (final label in ['字号', '描边', '位置', '底色', '恢复默认样式']) {
        expect(find.text(label), findsWidgets, reason: '二级缺「$label」');
      }

      await _drill(tester, '字号');
      final sizeRows = _rowsAt(tester, 3);
      expect(sizeRows.length, 4, reason: '字号必须飞出更深一列且是 4 档');
      final labels = [for (final r in sizeRows) _labelOf(tester, r)];
      expect(labels, ['80%', '100%', '125%', '150%']);
      // 当前档（默认 textScale = 1.0 → 100%）必须打勾，且只有它。
      final checked = [
        for (var i = 0; i < sizeRows.length; i++)
          if (_isChecked(tester, sizeRows[i])) labels[i],
      ];
      expect(checked, ['100%'], reason: '字号当前值应只有一项被标记');
    });

    testWidgets('第二条 3 层路径：画面 → 画面比例与缩放（5 种模式）', (tester) async {
      await _openMenu(tester);
      await _drill(tester, '画面');
      await _drill(tester, '画面比例与缩放');
      final rows = _rowsAt(tester, 2);
      expect(rows.length, PlayerVideoFitMode.values.length);
      final labels = [for (final r in rows) _labelOf(tester, r)];
      expect(labels, [for (final m in PlayerVideoFitMode.values) m.label]);
      final checked = [
        for (var i = 0; i < rows.length; i++)
          if (_isChecked(tester, rows[i])) labels[i],
      ];
      expect(checked, [PlayerVideoFitMode.contain.label]);
    });

    testWidgets('第三条 3 层路径：显示 → 屏显 → 7 个开关', (tester) async {
      await _openMenu(
        tester,
        osdFlags: {OsdFlag.title: true, OsdFlag.time: true},
      );
      await _drill(tester, '显示');
      await _drill(tester, '屏显');
      final rows = _rowsAt(tester, 2);
      expect(rows.length, OsdFlag.values.length, reason: '屏显必须有 7 个开关');

      final checked = <String>{};
      for (final row in rows) {
        if (_isChecked(tester, row)) checked.add(_labelOf(tester, row));
      }
      // 「已开启的屏显项 selected 为 true」：逐项对照开关表。
      // harness 只覆盖了 title / time，其余四项保留默认值
      // （\`defaultOsdFlags\`: title/size/time/progress = true）。
      expect(checked, {'标题', '分辨率', '时钟', '播放进度'});
      expect(checked.length, lessThan(OsdFlag.values.length), reason: '不能全选');
    });

    testWidgets('当前倍速项 selected == true，其余档位 false', (tester) async {
      await _openMenu(tester);
      // 档位不再摊在主列里：点开「速度」组，6 档在第 2 列。
      await _drill(tester, '速度');
      final rateRows = _rowsAt(tester, 1);
      expect(rateRows.length, 6, reason: '速度组必须恰好 6 档');
      final checked = [
        for (var i = 0; i < rateRows.length; i++)
          if (_isChecked(tester, rateRows[i])) _labelOf(tester, rateRows[i]),
      ];
      // `PlayerController._rate` 初值 1.0（`player_controller.dart:171`）。
      expect(checked, ['1.0×']);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('player-menu-item-rate_1.0')),
          matching: find.byIcon(Icons.check),
        ),
        findsOneWidget,
      );
      for (final rate in ['0.5', '0.75', '1.25', '1.5', '2.0']) {
        expect(
          find.descendant(
            of: find.byKey(ValueKey('player-menu-item-rate_$rate')),
            matching: find.byIcon(Icons.check),
          ),
          findsNothing,
          reason: '$rate× 不该被标记为当前值',
        );
      }
    });

    testWidgets('禁用项保状态：不可点但仍留在菜单里', (tester) async {
      await _openMenu(tester);
      // 这三项在「片头片尾」组的飞出列里，先把组点开。
      await _drill(tester, '片头片尾');
      // 本集没有任何标记时，「跳过片头 / 跳过片尾 / 清除本片标记」三项禁用。
      for (final entry in {
        'skip_intro': '跳过片头',
        'skip_outro': '跳过片尾',
        'clear_skip': '清除本片标记',
      }.entries) {
        expect(
          find.text(entry.value),
          findsWidgets,
          reason: '「${entry.value}」被隐藏了，而不是灰掉',
        );
        final row = tester.widget<InkWell>(
          find.byKey(ValueKey('player-menu-item-${entry.key}')),
        );
        expect(
          _isDisabled(tester, row),
          isTrue,
          reason: '「${entry.value}」当前没有标记，应不可点',
        );
      }
      // 同一分组里的可用项必须仍可点（不是整组被禁）。
      expect(
        _isDisabled(
          tester,
          tester.widget<InkWell>(
            find.byKey(const ValueKey('player-menu-item-mark_intro')),
          ),
        ),
        isFalse,
      );
    });

    // ------------------------------------------------------------ 设置树下钻
    //
    // 这一组用例锁的是「设置不再是跳转入口」这件事本身：树存在、第 4 层
    // 可达、就地开关不关菜单、条件不满足时灰而不藏。上一版这三条全都失败
    // （设置组只有三个 `Navigator.push`）。
    //
    // **层级口径**：「设置」现在是主列里的一个**分组行**（可飞出），它的 5 个
    // 子项落在第 2 列。从这里往下数：
    //   主列分组（第 1 列）→ 设置组子项（第 2 列）→ 播放参数（第 3 列）
    //   → 失败回退/缓存上限（第 4 列）。
    // 用户看到的是 3 层下钻（设置 → 播放参数 → 失败回退），按「菜单层」算则是
    // 第 4 层。

    /// 设置组飞出的 5 行（第 2 列，顺序与 `_contextMenuSections` 里
    /// 「10. 设置」一致）。调用前必须先 [_drill] 点开「设置」组。
    List<InkWell> settingsRows(WidgetTester tester) {
      final rows = _rowsAt(tester, 1);
      expect(rows.length, 5, reason: '设置组必须飞出 5 行');
      return rows;
    }

    testWidgets('设置组展开为四棵子树 + 至少一个跳转项', (tester) async {
      await _openMenu(tester);
      await _drill(tester, '设置');

      final rows = settingsRows(tester);
      final parents = [
        for (final row in rows)
          if (_hasFlyout(tester, row)) _labelOf(tester, row),
      ];
      expect(
        parents,
        ['播放参数', '字幕源', '弹幕库', '控制栏按钮'],
        reason: '设置组下的四棵子树必须都在，且顺序固定',
      );

      // 至少一个**跳转项**：长文本表单留在专门页面（见 player_page 里的注释）。
      final leaves = [
        for (final row in rows)
          if (!_hasFlyout(tester, row)) _labelOf(tester, row),
      ];
      expect(
        leaves,
        containsAll(<String>['完整设置页…']),
        reason: '跳转入口「完整设置页…」不得被删掉（表单类设置仍需要它）',
      );

      // 每一棵子树都必须真的能下钻（不是空 `children` 的假箭头）。
      for (final label in parents) {
        await _drill(tester, label);
        expect(_rowsAt(tester, 2), isNotEmpty, reason: '「$label」飞出了空子列');
        final childLabels = [
          for (final row in _rowsAt(tester, 2)) _labelOf(tester, row),
        ];
        expect(
          childLabels.where((v) => v.isNotEmpty).length,
          greaterThanOrEqualTo(2),
          reason: '「$label」下钻列只有 $childLabels 这几行',
        );
      }
    });

    testWidgets('新增第 4 层路径：设置 → 播放参数 → 失败回退（4 档单选）', (tester) async {
      await _openMenu(tester);
      await _drill(tester, '设置');
      await _drill(tester, '播放参数');

      // 第 3 列 = 播放参数的下钻列：5 个就地开关 + 2 棵更深子树。
      final paramLabels = [
        for (final row in _rowsAt(tester, 2)) _labelOf(tester, row),
      ];
      expect(
        paramLabels,
        containsAll(<String>['硬件解码', '缓存', '预加载下一集', '音频直通', '自动连播']),
        reason: '播放参数下的 5 个就地开关必须都在',
      );

      await _drill(tester, '失败回退');
      final rows = _rowsAt(tester, 3);
      expect(
        rows.length,
        PlayerFailureFallback.values.length,
        reason: '失败回退必须是 ${PlayerFailureFallback.values.length} 档',
      );
      final labels = [for (final row in rows) _labelOf(tester, row)];
      expect(
        labels,
        [for (final mode in PlayerFailureFallback.values) mode.label],
      );
      final checked = [
        for (var i = 0; i < rows.length; i++)
          if (_isChecked(tester, rows[i])) labels[i],
      ];
      // 默认值 = `PlayerOptions.defaults().failureFallback`（PlayerFailureFallback.line）。
      expect(
        checked,
        [PlayerFailureFallback.line.label],
        reason: '回退档位必须恰有一项打勾，且是当前生效值',
      );
    });

    testWidgets('第二条新增第 4 层路径：设置 → 播放参数 → 缓存上限', (tester) async {
      await _openMenu(tester);
      await _drill(tester, '设置');
      await _drill(tester, '播放参数');
      await _drill(tester, '缓存上限');

      final rows = _rowsAt(tester, 3);
      final labels = [for (final row in rows) _labelOf(tester, row)];
      expect(labels, ['64 MiB', '128 MiB', '256 MiB', '512 MiB']);
      final checked = [
        for (var i = 0; i < rows.length; i++)
          if (_isChecked(tester, rows[i])) labels[i],
      ];
      expect(
        checked,
        ['${PlayerOptions.defaultDemuxerMaxMiB} MiB'],
        reason: '缓存上限当前值必须打勾（默认 ${PlayerOptions.defaultDemuxerMaxMiB} MiB）',
      );
    });

    testWidgets('就地开关不关菜单：点「硬件解码」后菜单仍在且勾选翻转', (tester) async {
      await _openMenu(tester);
      await _drill(tester, '设置');
      await _drill(tester, '播放参数');

      InkWell rowOf(String label) {
        for (final row in _rowsAt(tester, 2)) {
          if (_labelOf(tester, row) == label) return row;
        }
        fail('播放参数下钻列里找不到「$label」');
      }

      final before = _isChecked(tester, rowOf('硬件解码'));
      final target = find.descendant(
        of: find.byType(PlayerContextMenu),
        matching: find.text('硬件解码'),
      );
      await tester.ensureVisible(target.first);
      await settlePlayerPage(tester, times: 2);
      await tester.tap(target.first);
      await settlePlayerPage(tester, times: 3);

      // 1. 菜单**没被关掉**（就地生效的全部意义）。
      expect(
        find.byType(PlayerContextMenu),
        findsOneWidget,
        reason: '就地开关点完把菜单关了——这就退化成跳转了',
      );
      // 2. 展开路径还在（不是关了又开），勾选当场翻转。
      expect(_rowsAt(tester, 2), isNotEmpty, reason: '点完开关后下钻列消失了');
      expect(
        _isChecked(tester, rowOf('硬件解码')),
        !before,
        reason: '「硬件解码」的勾选状态没有翻转',
      );
    });

    testWidgets('未配置弹幕库时「自动搜索弹幕」置灰但仍在树里', (tester) async {
      await _openMenu(tester);
      await _drill(tester, '设置');
      await _drill(tester, '弹幕库');

      // harness 不写任何弹幕库设置 → `DanmakuSettings.defaults()`：
      // autoSearch=false、apiUrl 空 → hasLibrary=false → 该行禁用。
      expect(
        find.text('自动搜索弹幕'),
        findsWidgets,
        reason: '不可用时应灰掉，而不是从菜单里消失',
      );
      final row = tester.widget<InkWell>(
        find.byKey(const ValueKey('player-menu-item-settings_danmaku_auto_search')),
      );
      expect(_isDisabled(tester, row), isTrue, reason: '未配置弹幕库时应不可点');
      // 保留 selected（引擎把「选中 + 禁用」画成压暗琥珀）：
      // 默认 autoSearch=false，所以这里断言的是「选中态没被禁用抹掉」的实现
      // ——直接断言行里没有 check（false），再断言禁用能读出来。
      expect(_isChecked(tester, row), isFalse);

      // 同一棵子树里，「打开弹幕库设置…」必须**仍可点**（不是整组被禁）。
      final formRow = tester.widget<InkWell>(
        find.byKey(const ValueKey('player-menu-item-settings_danmaku_library_form')),
      );
      expect(_isDisabled(tester, formRow), isFalse);
    });

    testWidgets('菜单项 key 唯一（同 id 不得在多列里重复）', (tester) async {
      await _openMenu(tester);
      await _drill(tester, '字幕');
      await _drill(tester, '字幕样式');
      await _drill(tester, '字号');
      final keys = tester
          .widgetList<InkWell>(_menuRows)
          .map((w) => (w.key! as ValueKey).value)
          .toList();
      expect(
        keys.toSet().length,
        keys.length,
        reason: '同一 id 的菜单项在多列里重复渲染了：${keys.join(",")}',
      );
    });
  });

  // 顶栏「更多」的收敛：右键菜单收编全量设置后，两处不得大面积重复。
  // 这里锁死「更多」只剩五项，且被移走的那几项**确实不在**溢出菜单里。
  //
  // 集成测试（\`integration_test/ui_redesign_visual_flow_test.dart:711-733\`）
  // 断言的是同一件事，但它需要 fixture 服务；本用例在纯 widget 层给出
  // 同一份证据，改动「更多」时不必先起 fixture 才能发现回归。
  group('顶栏「更多」收敛', () {
    testWidgets('只剩 5 项，移走的项不再重复出现', (tester) async {
      await pumpPlayerPage(tester);
      expect(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.byTooltip('更多'),
        ),
        findsOneWidget,
        reason: '「更多」按钮本身不得删除（集成测试按此 tooltip 定位）',
      );
      // 不能用 \`pumpAndSettle\`：加载态有常驻 \`CircularProgressIndicator\`、
      // 控制器还有 180 秒加载超时定时器，\`transientCallbackCount\` 恒 ≥1
      // （\`test/support/player_page_harness.dart\` 文件头注释）。
      await tester.tap(find.byTooltip('更多'));
      await settlePlayerPage(tester, times: 4);
      for (final label in [
        '字幕样式',
        '弹幕设置',
        '画面比例与缩放',
        '媒体信息',
        '快捷键说明',
      ]) {
        expect(find.text(label), findsWidgets, reason: '溢出菜单缺少「$label」');
      }
      for (final label in ['播放诊断', '音轨', '视频轨', '循环与定时', 'LUT 滤镜']) {
        expect(
          find.text(label),
          findsNothing,
          reason: '「$label」已归右键菜单，不得在「更多」里重复',
        );
      }
    });
  });
}
