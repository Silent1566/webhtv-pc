import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// 布局密度标度：让卡片尺寸随**窗口短边**有上限地放大，而不是随宽度无限拉伸。
///
/// 为什么不是「跟宽度走」：宽度衡量的是「一屏能放多少内容」，短边才近似
/// 「眼睛到屏幕的距离」（4K@150% 的逻辑短边与 1440p@100% 相同，物理观感也相同）。
/// 纯宽度驱动会把 3440 超宽屏变成「9 列 × 300px 巨卡」，而把 1280 的小窗
/// 压到 150px 的下限——同一张卡片，两种失败。
///
/// 为什么是**有上下限的阶梯**而不是连续缩放：连续缩放会让窗口拖动时卡片每帧
/// 抖 1px，也会把 16:9 / 2:3 的格子挤出非整数像素。量化到 0.05 档后，
/// 尺寸变化只发生在跨档那一下。
///
/// 字号**不参与**这个标度：`DESIGN.md` 的 Metric-Neutral Rule 要求字号与行高
/// 保持 Material 3 原值（改字号会把 800×600 测试视口里的 tap 全部错位）。
/// 所以这里只放大「盒子」——卡片宽、剧照高、间距、文字区高度；文字本身不变。
abstract final class LayoutScale {
  /// 基准短边：800 高的默认窗口落在 0.95 档（保底，不再变小）。
  static const double _referenceShortSide = 900;

  /// 卡片目标宽度基准。默认窗口（1280×800）≈ 185，1440p 全屏 ≈ 263。
  ///
  /// 这是全局唯一的「卡片多大」旋钮。176 是保守值（默认窗口 7 列）；
  /// 195 会让默认窗口掉到 6 列、卡片约 198px，视觉上一眼能看出变大。
  static const double _cardBase = 195;

  /// 下界：比默认窗口更小的窗口不再缩小卡片（字会被挤扁）。
  static const double _min = 0.95;

  /// 上界：1440p 以上不再涨；超宽屏多出来的宽应该给列数与留白。
  static const double _max = 1.35;

  /// 当前密度档（0.95–1.35，量化到 0.05）。
  static double of(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final shortSide = math.min(size.width, size.height);
    final raw = (shortSide / _referenceShortSide).clamp(_min, _max);
    return (raw * 20).roundToDouble() / 20;
  }

  /// 卡片目标宽度：首页海报网格与详情选集卡共用同一个基准，
  /// 避免同一屏出现 110 / 144 / 150 / 300 四种尺寸。
  static double cardWidth(BuildContext context) => _cardBase * of(context);

  /// 卡片间距：跟着卡片走。大卡配小缝会让网格「粘」在一起。
  static double gutter(BuildContext context) => 12 * of(context);

  /// 选集卡的目标宽：比海报网格再大一档（详情页的选集区是主操作入口），
  /// 但封顶 300——再宽就该换列数，而不是让一张剧照占掉半屏。
  static double episodeCardWidth(BuildContext context) =>
      math.min(cardWidth(context) * 1.25, 300);

  /// 只放大、不缩小：用于原本就合适的固定尺寸（头图海报、剧照墙、海报墙）。
  ///
  /// 小窗口已经够挤，再乘 0.95 只会把已有的东西做得更小；这一档只负责
  /// 大屏上「别显得像邮票」。
  static double upscale(BuildContext context, double base) =>
      base * math.max(1.0, of(context));

  /// 文字区高度：字号不变，所以文字区**不得随 scale 缩小**，只能持平或变大。
  static double caption(BuildContext context, double base) =>
      upscale(context, base);

  /// 由目标宽度反推列数，但**不允许实际列宽掉到目标的 92% 以下**。
  ///
  /// 原先的 `.round().clamp(2, 12)` 用 12 这个魔数封顶：1920 宽被夹成
  /// 12 列 × 144px，反而比 1366 宽的 154px 更小——窗口越宽卡片越小。
  /// 上限改由宽度反推，魔数退场。
  static int columnsFor(double usable, double target, double spacing) {
    final ideal = (usable / (target + spacing)).round();
    final maxColumns = ((usable + spacing) / (target * 0.92 + spacing)).floor();
    return math.max(2, math.min(ideal, maxColumns));
  }
}
