/// 右键菜单「画面 → LUT 滤镜」的飞出子列（A1 方案）。
///
/// 为什么是飞出子列而不是单个入口：LUT 切换是即时生效的（改 mpv 的 vf，
/// 不重开播放器），属于「边看边调」。走子列 = 选完仍在画面上，
/// 不需要先跳一层页面再返回。
///
/// 三个部分：
/// 1. 「关闭 LUT」——否则启用后没有对等的关闭动作；
/// 2. 13 个内置预设——同构列表，扫视比「猜最近使用」的排序便宜；
/// 3. 「更多 LUT…」——导入/删除/在线搜索放不下，交给底部面板。
///
/// 单独成文件是为了能直接单测：菜单本身是 240 宽的飞出列，
/// 用组件测试验证它得先搭一整套播放器状态，成本远高于测这个纯函数。
library;

import 'package:flutter/material.dart';

import '../core/lut.dart';
import '../core/player_options.dart';
import 'player_context_menu.dart';

/// 构造 LUT 子列。顺序固定：关闭 → 13 个内置 → 更多。
List<PlayerMenuItem> buildLutMenuItems({
  required PlayerOptions options,
  required VoidCallback onOff,
  required ValueChanged<LutPreset> onPick,
  required VoidCallback onMore,
}) {
  final currentId = options.lutPresetId.trim();
  return <PlayerMenuItem>[
    PlayerMenuItem(
      id: 'lut_off',
      label: '关闭 LUT',
      icon: Icons.block,
      // 用户直接选了某个 .cube 文件（没有 preset id）时，「关闭」也不打勾：
      // 那说明当前生效的不是内置项，但仍然是「开着」的。
      selected: !options.hasLut,
      onSelect: onOff,
    ),
    for (final preset in builtinLutPresets)
      PlayerMenuItem(
        id: 'lut_${preset.id}',
        label: preset.name,
        selected: currentId == preset.id,
        onSelect: () => onPick(preset),
      ),
    PlayerMenuItem(
      id: 'lut_more',
      label: '更多 LUT…',
      icon: Icons.tune,
      onSelect: onMore,
    ),
  ];
}
