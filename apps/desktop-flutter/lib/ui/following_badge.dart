/// 追剧页共用的药丸徽标：日历条目与列表卡用同一个组件，样式只有一处。
///
/// 两种语义靠 [emphasized] 区分：主色淡底 = 需要用户注意（未看），
/// 容器色 = 中性信息（播放平台、播出日期来源）。字号固定 11，不再各自实现。
library;

import 'package:flutter/material.dart';

import 'tokens.dart';

class FollowingBadge extends StatelessWidget {
  const FollowingBadge({
    super.key,
    required this.text,
    this.emphasized = false,
  });

  final String text;

  /// `true` 用主色淡底（未看），`false` 用容器色（来源/平台标记）。
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: emphasized
            ? scheme.primaryContainer
            : scheme.surfaceContainerHighest,
        borderRadius: AppRadius.pillAll,
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 11,
          color: emphasized
              ? scheme.onPrimaryContainer
              : scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
