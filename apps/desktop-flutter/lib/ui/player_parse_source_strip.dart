/// 播放器控制区的解析源条。
///
/// 上游依据：安卓把解析列表放在播放器控制区（`view_control_vod.xml:258`），
/// 可见性由**本次播放结果**决定（`VideoActivity.java:3436-3447`），不在选集
/// 弹窗里，也不是全局设置。
///
/// 为什么独立成组件而不是塞回选集面板：解析是「这一次用哪个解析器拿到地址」，
/// 与「播哪条线路的哪一集」是两件事；混在一个弹窗里，用户在选集时会被一排与
/// 选集无关的 chip 干扰，直链播放还会凭空多出无效入口（用户反馈的那张截图）。
///
/// 可见性由调用方决定：本组件只负责画，`parseSources` 少于两项时调用方根本
/// 不构造它——只有一个解析源时「选不选都一样」。
library;

import 'package:flutter/material.dart';

import 'scroll_behavior.dart';
import 'tokens.dart';

class PlayerParseSourceStrip extends StatelessWidget {
  const PlayerParseSourceStrip({
    super.key,
    required this.sources,
    required this.selected,
    required this.onSelect,
  });

  /// 本次播放可切换的解析源名称（第一项通常是合成的「超级解析」）。
  final List<String> sources;

  /// 当前生效的解析源名称。
  final String selected;

  /// 点某个解析源：调用方负责重新解析当前集。
  final ValueChanged<String> onSelect;

  /// 与线路/区间 chip 行同高：同高的条带在浮层里不会跳行。
  static const double height = 40;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: HorizontalMouseDrag(
        child: ListView.separated(
          key: const ValueKey('player-parse-source-strip'),
          scrollDirection: Axis.horizontal,
          itemCount: sources.length,
          separatorBuilder: (_, _) => const SizedBox(width: AppSpace.sm),
          itemBuilder: (context, index) {
            final name = sources[index];
            return _chip(
              context: context,
              key: ValueKey('player-parse-source-$index'),
              label: name,
              selected: name == selected,
              onSelected: () => onSelect(name),
            );
          },
        ),
      ),
    );
  }

  /// 与选集面板的 chip 同一套取值：星等琥珀只用在「当前选中」，零阴影。
  Widget _chip({
    required BuildContext context,
    required Key key,
    required String label,
    required bool selected,
    required VoidCallback onSelected,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final accent = context.semanticColors.magnitude;
    return ChoiceChip(
      key: key,
      label: Text(label),
      selected: selected,
      // 勾选标记会把 chip 撑宽并推挤整排，选中态已经由描边与底色表达。
      showCheckmark: false,
      backgroundColor: scheme.surfaceContainer,
      selectedColor: accent.withValues(alpha: 0.18),
      side: BorderSide(color: selected ? accent : scheme.outlineVariant),
      labelStyle: theme.textTheme.labelLarge?.copyWith(
        color: selected ? scheme.onSurface : scheme.onSurfaceVariant,
      ),
      onSelected: (_) => onSelected(),
    );
  }
}
