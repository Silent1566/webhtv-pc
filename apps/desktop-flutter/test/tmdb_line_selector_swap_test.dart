/// 线路选择器的**外部来源徽标**与**换源入口**门禁。
///
/// 三条契约各自有独立的钉子，因为它们是三件不同的事：
/// 1. 默认参数必须让旧调用点零改动——没有外部来源就没有色点，没有回调就没有
///    换源按钮，渲染结果与改造前一致；
/// 2. 色点必须真的**读状态**上色（未知不等于好），而不是一律同一个颜色；
/// 3. 换源按钮必须真的**接回调**，而不只是挂了 key。
///
/// 既有 `tmdb-line-*` / `tmdb-line-recent-*` 的 key 与 widget 类型由
/// `phase4_tmdb_detail_view_test.dart` 与 `phase6_detail_resume_test.dart` 把关，
/// 本文件只补一条「加了色点之后 chip 仍是 ChoiceChip、标签文本格式未变」。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/ui/source_field.dart';
import 'package:webhtv_pc/ui/tmdb_detail_view.dart';

const List<VodPlayLine> _lines = [
  VodPlayLine(flag: '线路一', episodes: []),
  VodPlayLine(flag: '线路二', episodes: []),
];

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

/// 某条线路 chip 上那层 [Tooltip] 的文案。
String? _tooltipOf(WidgetTester tester, String flag) {
  final finder = find.ancestor(
    of: find.byKey(ValueKey('tmdb-line-$flag')),
    matching: find.byType(Tooltip),
  );
  expect(finder, findsOneWidget, reason: '每条线路 chip 都挂一层 Tooltip');
  return tester.widget<Tooltip>(finder).message;
}

/// 某条线路外部色点的填色。
Color _dotColor(WidgetTester tester, String flag) {
  final dot = tester.widget<Container>(
    find.byKey(ValueKey('tmdb-line-external-$flag')),
  );
  final decoration = dot.decoration! as BoxDecoration;
  return decoration.color!;
}

void main() {
  group('默认参数不改变渲染（旧调用点零改动）', () {
    testWidgets('无外部来源时：不渲染色点、Tooltip 用线路名、行尾无换源按钮', (tester) async {
      await tester.pumpWidget(
        _host(const TmdbLineSelector(lines: _lines, selectedFlag: '线路一')),
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey('tmdb-line-external-线路一')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('tmdb-line-external-线路二')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('tmdb-line-swap')), findsNothing);
      expect(_tooltipOf(tester, '线路一'), '线路一');
    });

    testWidgets('外部来源不影响标签文本格式（既有断言按这个计数）', (tester) async {
      await tester.pumpWidget(
        _host(
          const TmdbLineSelector(
            lines: _lines,
            selectedFlag: '线路一',
            episodeCounts: {'线路一': 22, '线路二': 8},
            externalOrigins: {'线路二': '示例站点'},
          ),
        ),
      );
      await tester.pump();

      expect(find.text('线路一（22 集）'), findsOneWidget);
      expect(find.text('线路二（8 集）'), findsOneWidget);
      // chip 仍是 ChoiceChip：既有门禁用 `tester.widget<ChoiceChip>` 取它。
      final chip = tester.widget<ChoiceChip>(
        find.byKey(const ValueKey('tmdb-line-线路二')),
      );
      expect(chip.selected, isFalse);
    });
  });

  group('外部来源色点', () {
    testWidgets('只有带来源的线路渲染色点，且 key 按 flag 一一对应', (tester) async {
      await tester.pumpWidget(
        _host(
          const TmdbLineSelector(
            lines: _lines,
            selectedFlag: '线路一',
            externalOrigins: {'线路二': '示例站点'},
            externalStatus: {'线路二': SourceStatus.ok},
          ),
        ),
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey('tmdb-line-external-线路二')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('tmdb-line-external-线路一')),
        findsNothing,
        reason: '本站原生线路不得挂来源色点',
      );
    });

    testWidgets('色点是 6px 方点、圆角 2（不是图标也不是圆点）', (tester) async {
      await tester.pumpWidget(
        _host(
          const TmdbLineSelector(
            lines: _lines,
            selectedFlag: '线路一',
            externalOrigins: {'线路一': '示例站点'},
          ),
        ),
      );
      await tester.pump();

      final key = find.byKey(const ValueKey('tmdb-line-external-线路一'));
      expect(tester.getSize(key), const Size(6, 6));
      final dot = tester.widget<Container>(key);
      final decoration = dot.decoration! as BoxDecoration;
      expect(decoration.borderRadius, BorderRadius.circular(2));
    });

    testWidgets('颜色真的读健康态：ok 与 failed 必须不同色', (tester) async {
      await tester.pumpWidget(
        _host(
          const TmdbLineSelector(
            lines: _lines,
            selectedFlag: '线路一',
            externalOrigins: {'线路一': '甲站', '线路二': '乙站'},
            externalStatus: {
              '线路一': SourceStatus.ok,
              '线路二': SourceStatus.failed,
            },
          ),
        ),
      );
      await tester.pump();

      final ok = _dotColor(tester, '线路一');
      final failed = _dotColor(tester, '线路二');
      expect(
        ok,
        isNot(equals(failed)),
        reason: '色点必须按站点实测健康态上色，不能一律同色',
      );
    });

    testWidgets('没有健康记录时按「未知」上色，而不是按「可用」', (tester) async {
      await tester.pumpWidget(
        _host(
          const TmdbLineSelector(
            lines: _lines,
            selectedFlag: '线路一',
            externalOrigins: {'线路一': '甲站', '线路二': '乙站'},
            externalStatus: {'线路二': SourceStatus.ok},
          ),
        ),
      );
      await tester.pump();

      final unknown = _dotColor(tester, '线路一');
      final ok = _dotColor(tester, '线路二');
      expect(
        unknown,
        isNot(equals(ok)),
        reason: '未知不等于好：缺记录时不得借用「可用」色',
      );
    });
  });

  group('Tooltip 文案优先级：最近播放 > 外部来源 > 线路名', () {
    testWidgets('最近播放的线路即使有来源也显示「最近播放」', (tester) async {
      await tester.pumpWidget(
        _host(
          const TmdbLineSelector(
            lines: _lines,
            selectedFlag: '线路一',
            recentFlag: '线路二',
            externalOrigins: {'线路二': '示例站点'},
          ),
        ),
      );
      await tester.pump();

      expect(_tooltipOf(tester, '线路二'), '最近播放');
      // 最近标记本身不得被色点挤掉。
      expect(
        find.byKey(const ValueKey('tmdb-line-recent-线路二')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('tmdb-line-recent-线路一')),
        findsNothing,
      );
    });

    testWidgets('有来源的普通线路显示「来自 <站点名>」', (tester) async {
      await tester.pumpWidget(
        _host(
          const TmdbLineSelector(
            lines: _lines,
            selectedFlag: '线路一',
            externalOrigins: {'线路二': '示例站点'},
          ),
        ),
      );
      await tester.pump();

      expect(_tooltipOf(tester, '线路二'), '来自 示例站点');
      expect(_tooltipOf(tester, '线路一'), '线路一');
    });
  });

  group('换源入口', () {
    testWidgets('onSwapSource 为 null 时不渲染', (tester) async {
      await tester.pumpWidget(
        _host(const TmdbLineSelector(lines: _lines, selectedFlag: '线路一')),
      );
      await tester.pump();

      expect(find.byKey(const ValueKey('tmdb-line-swap')), findsNothing);
      expect(find.text('换源'), findsNothing);
    });

    testWidgets('onSwapSource 非 null 时渲染图标按钮，点击触发回调', (tester) async {
      var swaps = 0;
      await tester.pumpWidget(
        _host(
          TmdbLineSelector(
            lines: _lines,
            selectedFlag: '线路一',
            onSwapSource: () => swaps++,
          ),
        ),
      );
      await tester.pump();

      final swap = find.byKey(const ValueKey('tmdb-line-swap'));
      expect(swap, findsOneWidget);
      expect(find.text('换源'), findsOneWidget);

      final icon = tester.widget<Icon>(
        find.descendant(of: swap, matching: find.byType(Icon)),
      );
      expect(icon.icon, Icons.swap_horiz);
      expect(icon.size, 16);

      await tester.tap(swap);
      await tester.pump();
      expect(swaps, 1, reason: '点了换源必须真的调到调用方');
    });

    testWidgets('换源按钮在 Expanded 之后，不抢 chip 的点击', (tester) async {
      var swaps = 0;
      VodPlayLine? tapped;
      await tester.pumpWidget(
        _host(
          TmdbLineSelector(
            lines: _lines,
            selectedFlag: '线路一',
            onChanged: (line) => tapped = line,
            onSwapSource: () => swaps++,
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('tmdb-line-线路二')));
      await tester.pump();
      expect(tapped?.flag, '线路二');
      expect(swaps, 0, reason: '切线路不得误触换源');
    });
  });
}
