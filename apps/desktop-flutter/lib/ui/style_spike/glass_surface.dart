// STYLE-SPIKE / THROWAWAY —— 液态玻璃可行性 spike 的一次性原语，不得被生产代码引用。
//
// 一支「真玻璃」需要：背景模糊、饱和度提升、底色染色、边缘高光与一道镜面扫光。
// 这里没有折射（FragmentProgram 属 B 档），所以它只会是「磨砂 + 染色」，不是液态玻璃。
// 刻意只用 Material / dart:ui：不依赖 AppState、services、网络或字体资源以外的东西。
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// 液态玻璃外观的容器。
///
/// 结构固定为：ClipRRect → BackdropFilter(blur + saturation) → 染色底 → sheen → rim → child。
///
/// 没有 elevation：DESIGN.md 的「全站 elevation 一律为 0」是硬规矩，玻璃的层次由
/// 边缘高光与背景模糊承担，而不是投影——这也是它与「发丝边卡片」的差别所在。
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.blurSigma = 22,
    this.tintAlpha = 0.18,
    this.rimAlpha = 0.32,
    this.sheenAlpha = 0.10,
    this.saturation = 1.35,
    this.radius = 14,
    this.rimWidth = 1,
    this.borderRadius,
    this.padding = const EdgeInsets.all(16),
    this.clipBehavior = Clip.antiAlias,
  })  : assert(blurSigma >= 0),
        assert(tintAlpha >= 0 && tintAlpha <= 1),
        assert(rimAlpha >= 0 && rimAlpha <= 1);

  final Widget child;

  /// 背景高斯模糊强度（px）。
  final double blurSigma;

  /// 表面染色底的不透明度：底色取主题 surface，只改透明度，不引入新色相。
  final double tintAlpha;

  /// 边缘高光强度（顶部最亮，向下衰减）。
  final double rimAlpha;

  /// 镜面扫光强度：一道斜向白色高光，模拟玻璃折射的「一道光」。
  final double sheenAlpha;

  /// 背景饱和度倍率；>1 提饱和，<1 去饱和。
  final double saturation;

  /// 圆角，缺省走 AppRadius.lg（14）。
  final double radius;

  /// 边缘描边宽度。
  final double rimWidth;

  /// 显式圆角；给了就不看 [radius]。
  final BorderRadius? borderRadius;

  final EdgeInsetsGeometry padding;
  final Clip clipBehavior;

  BorderRadius get _resolvedRadius =>
      borderRadius ?? BorderRadius.all(Radius.circular(radius));

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final radius = _resolvedRadius;
    // 亮底用更低的高光 alpha：纯白 rim 在昼间星表上会读成塑料边。
    final rimScale = scheme.brightness == Brightness.dark ? 1.0 : 0.85;

    return ClipRRect(
      borderRadius: radius,
      clipBehavior: clipBehavior,
      child: BackdropFilter(
        filter: ui.ImageFilter.compose(
          outer: ui.ColorFilter.matrix(_saturationMatrix(saturation)),
          inner: ui.ImageFilter.blur(
            sigmaX: blurSigma,
            sigmaY: blurSigma,
            tileMode: TileMode.mirror,
          ),
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: radius,
            color: scheme.surface.withValues(alpha: tintAlpha),
          ),
          child: Stack(
            children: [
              // 斜向镜面扫光：左上最亮、中段透明、右下留一点回光。
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: radius,
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      stops: const [0, 0.45, 1],
                      colors: [
                        Colors.white.withValues(alpha: sheenAlpha),
                        Colors.transparent,
                        Colors.white.withValues(alpha: sheenAlpha * 0.35),
                      ],
                    ),
                  ),
                ),
              ),
              // 边缘高光：1px 内描边 + 顶亮底灭的竖向渐变，读成「玻璃的厚度」。
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: radius,
                    border: Border.all(
                      color: Colors.white.withValues(
                        alpha: rimAlpha * 0.9 * rimScale,
                      ),
                      width: rimWidth,
                    ),
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      stops: const [0, 0.5, 1],
                      colors: [
                        Colors.white.withValues(
                          alpha: rimAlpha * 0.55 * rimScale,
                        ),
                        Colors.transparent,
                        Colors.transparent,
                      ],
                    ),
                  ),
                ),
              ),
              Padding(padding: padding, child: child),
            ],
          ),
        ),
      ),
    );
  }
}

/// 饱和度矩阵（5x4 彩色矩阵，sRGB 系数）。
///
/// 为什么用矩阵而不是 ColorFilter.mode：mode 只能混色，不能提饱和度；
/// 而玻璃下被放大的背景色，正是「下面有东西」的证据。
List<double> _saturationMatrix(double s) {
  const lumR = 0.2126;
  const lumG = 0.7152;
  const lumB = 0.0722;
  final inv = 1 - s;
  return <double>[
    lumR * inv + s, lumG * inv, lumB * inv, 0, 0, //
    lumR * inv, lumG * inv + s, lumB * inv, 0, 0, //
    lumR * inv, lumG * inv, lumB * inv + s, 0, 0, //
    0, 0, 0, 1, 0,
  ];
}
