/// 海报角标取值（纯逻辑，供浏览页网格与测试共用）。
///
/// 参考实现（用户提供截图 2026-10-09）：海报**左上角年份**、**右下角评分**，
/// 标题在图片下方。webhtv-pc 原先只在标题下渲染一行 `vod_remarks` 纯文本。
///
/// **关键约束：不能把 `vod_remarks` 一律当评分。** 实测同一批站点里它是两类东西：
/// - 豆瓣类站点：`7.2` / `8.7`（**评分**）；
/// - 网盘聚合类站点：`全29集` / `已完结` / `更新至第10集`（**更新状态**）。
///
/// 因此评分角标只在 `vod_remarks` 确实是一个 0~10 的数值时才渲染；否则保持原有的
/// 文字备注渲染（它本身是有用信息，不能丢）。年份同理：只在能取出 4 位年份时才画。
library;

import 'protocol.dart';

/// 海报角标取值。
abstract final class PosterBadge {
  /// 年份角标：`vod_year` 里的 4 位年份；取不到时返回 `null`。
  ///
  /// 兼容 `2024`、`2024-01-01`、`2024年` 等形态，统一取前 4 位数字。
  static String? yearOf(Vod vod) {
    final raw = vod.vodYear?.trim();
    if (raw == null || raw.isEmpty) return null;
    final match = RegExp(r'(\d{4})').firstMatch(raw);
    return match?.group(1);
  }

  /// 评分角标：仅当 [Vod.vodRemarks] 是 **0~10 的数值**时返回一位小数字符串。
  ///
  /// 返回 `null` 表示「remarks 不是评分」（如 `全29集`），调用方应改渲染原始备注。
  ///
  /// 边界：
  /// - `7.2` → `7.2`；`8` → `8.0`（统一一位小数，避免同屏两种精度）；
  /// - `0` / `10` 视为合法（0 分与满分都可能出现）；
  /// - `2024`（年份误入 remarks）、`11.5`（越界）、`全29集`、`已完结` → `null`。
  static String? scoreOf(Vod vod) {
    final raw = vod.vodRemarks?.trim();
    if (raw == null || raw.isEmpty) return null;
    // 只接受纯数值（允许前后空白），`全29集` / `已完结` / `更新至第10集` 都会被排除。
    if (!RegExp(r'^\d+(\.\d+)?$').hasMatch(raw)) return null;
    final value = double.tryParse(raw);
    if (value == null || value < 0 || value > 10) return null;
    return value.toStringAsFixed(1);
  }

  /// 文字备注：`remarks` 不是评分时才作为文字展示；是评分则返回 `null`
  /// （评分已由角标呈现，再重复一行文字是冗余）。
  static String? textRemarkOf(Vod vod) {
    final raw = vod.vodRemarks?.trim();
    if (raw == null || raw.isEmpty) return null;
    if (scoreOf(vod) != null) return null;
    return raw;
  }
}
