/// 磨砂材质容器：背景模糊、饱和度与染底。
///
/// 默认不画装饰描边、洗光和扫光；显式参数仅供定向材质探针使用。
/// 结构为 ClipRRect → 可选 BackdropFilter → 染底 → child。
/// blurSigma=0 且 saturation=1 时不创建滤镜，供视频上的低成本面板使用。
/// Theme 的颜色键不能承载背景滤镜，因此实际模糊仍需挂载本组件。
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'tokens.dart';

/// 磨砂玻璃容器：背景模糊 + 提饱和 + 染色底 + 镜面扫光 + 边缘高光。
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.blurSigma,
    this.tintAlpha,
    this.rimAlpha,
    this.rimWash,
    this.rimWashSpan,
    this.sheenAlpha,
    this.saturation,
    this.radius = AppGlass.radius,
    this.rimWidth = AppGlass.rimWidth,
    this.borderRadius,
    this.padding = const EdgeInsets.all(16),
    this.clipBehavior = Clip.antiAlias,
  }) : assert(blurSigma == null || blurSigma >= 0),
       assert(tintAlpha == null || (tintAlpha >= 0 && tintAlpha <= 1)),
       assert(rimAlpha == null || (rimAlpha >= 0 && rimAlpha <= 1)),
       assert(rimWash == null || (rimWash >= 0 && rimWash <= 1)),
       assert(rimWashSpan == null || (rimWashSpan > 0 && rimWashSpan <= 1)),
       assert(sheenAlpha == null || (sheenAlpha >= 0 && sheenAlpha <= 1)),
       assert(saturation == null || saturation >= 0);

  final Widget child;

  /// 背景高斯模糊强度（px）。null = 按主题亮度取 AppGlass 的对应档。
  final double? blurSigma;

  /// 表面染色底的不透明度：底色取主题 surface，只改透明度，不引入新色相。
  /// null = 按主题亮度取对应档。
  final double? tintAlpha;

  /// 边缘高光强度（顶部最亮，向下衰减）。null = 按主题亮度取对应档。
  final double? rimAlpha;

  /// 边缘高光的**内衬权重**：竖向那层白光相对 [rimAlpha] 的比例（0..1）。
  ///
  /// 1px 描边（边缘线）用的是 [rimAlpha] 本身，不乘这个权重；这里只管**面板内部**
  /// 那层从上向下衰减的白光。为什么它要单独一个参数：那层白光是「加白」，
  /// 与染底无关，会把整块面板抬亮——暗色档上它会直接吃掉 12px 文字的可读性预算
  /// （浮层头部行 sRGB 89 → 111，正文墨色只有 4.14:1）。亮色档不需要区分
  /// （0.55 的既有值，冻结），暗色档必须低一档，见 [rimWashDark]。
  final double? rimWash;

  /// 内衬白光的**垂直跨度**：那层白光从顶部最亮，到面板高度的这个比例处衰减为 0。
  ///
  /// null = 按主题亮度取对应档（[rimWashSpanLight] / [rimWashSpanDark]）。
  /// 显式传则用你给的 —— 探针、对照实验用这条。
  final double? rimWashSpan;

  /// 镜面扫光强度：一道斜向白色高光，模拟玻璃折射的「一道光」。
  /// null = 按主题亮度取对应档。
  final double? sheenAlpha;

  /// 背景饱和度倍率；>1 提饱和，<1 去饱和。null = 按主题亮度取对应档。
  final double? saturation;

  /// 圆角，缺省走 `AppRadius.lg`（14）。
  final double radius;

  /// 边缘描边宽度。
  final double rimWidth;

  /// 显式圆角；给了就不看 [radius]。
  final BorderRadius? borderRadius;

  final EdgeInsetsGeometry padding;
  final Clip clipBehavior;

  /// 暗色档的内衬权重：0.34 —— 只在 [rimWashSpanDark] 收到 5% 时才成立。
  ///
  /// 权重本身没有意义，**权重 × 跨度**才决定「头部行吃到多少白」。
  /// ink-1 那一轮跨度是面板高度的 50%，所以只能压到 0.04：头部行 4.60/5.25，
  /// 代价是 rim 内衬 26.93 → 5.00、斜向扫光 34.86 → 5.00 ——「表面那层光没了」。
  /// glow-1 把跨度收到 5%（774px 面板 = 38.7px，头部行在 43px 处 —— 在归零点之外），
  /// 白光不再落在文字上，权重于是可以回到 0.34：顶部 4–28px 的抬升 24.14
  /// （round-1 的 26.93 就是它要找回的量级），头部行 4.75/5.41（既有 4.60/5.25
  /// 没掉，反而更好），浮层「换源」标题 4.87，1px 边缘线 85.86（既有 86.00）。
  /// 每一个数字都能用 glow-1/probes.json 与 glow-1/report.md 复算。
  static const double rimWashDark = 0.34;

  /// 亮色档的内衬权重：0.55（既有值，冻结 —— 亮色像素逐字节不变）。
  static const double rimWashLight = 0.55;

  /// 暗色档的内衬**垂直跨度**：白光从顶部衰减到面板高度的 5% 处归零。
  ///
  /// **实测域**（`glow-1/span-matrix.json`，3 视口 × 3 字号的真实浮层）：
  /// 1024×640（面板 H=550.4）、1440×900（H=774）、1440×1200（H=820，撞上高度封顶），
  /// 字号 1.0 / 1.5 / 2.0。头部行顶坐标 43px（字号 1.5 / 2.0 时为 53 / 65），
  /// 归零点 = 0.05×H = 27.5 / 38.7 / 41.0，余量 15.5 / 4.3 / **2.0**px：
  /// 最坏的一档不是最大的视口，而是 820px 封顶那一档。同一矩阵里 12px 次要文字
  /// 最坏行 4.74–4.89、16px w700 标题最坏行 4.72–5.47，9 组都无溢出。
  ///
  /// **这不是「按比例就永远安全」的保证**，它成立的前提只有两条：面板高度
  /// ≤ 820px 封顶、浮层头部上边距不变。浮层头部上边距若改小 ≥3px（或把 820
  /// 封顶调高），最坏那一档就会掉进渐变尾部。矩阵用例
  ///（`glow-1 · 跨度矩阵`）把这三个视口 × 三档字号钉住；跑到域外要先补测再改数。
  ///
  /// 亮色档仍是既有几何的 0.50（白光铺到面板高度一半），冻结。
  static const double rimWashSpanDark = 0.05;

  /// 亮色档的内衬垂直跨度：0.50（既有几何，冻结 —— 亮色像素逐字节不变）。
  static const double rimWashSpanLight = 0.50;

  Widget _sampleBackdrop({
    required bool enabled,
    required ui.ImageFilter filter,
    required Widget child,
  }) => enabled ? BackdropFilter(filter: filter, child: child) : child;

  BorderRadius get _resolvedRadius =>
      borderRadius ?? BorderRadius.all(Radius.circular(radius));

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final radius = _resolvedRadius;
    final dark = scheme.brightness == Brightness.dark;
    // 亮底用更低的高光 alpha：纯白 rim 在昼间星表上会读成塑料边。
    final rimScale = dark ? 1.0 : 0.85;
    final resolvedBlur =
        blurSigma ?? (dark ? AppGlass.blurSigmaDark : AppGlass.blurSigmaLight);
    final resolvedTint =
        tintAlpha ?? (dark ? AppGlass.tintAlphaDark : AppGlass.tintAlphaLight);
    final resolvedRim =
        rimAlpha ?? (dark ? AppGlass.rimAlphaDark : AppGlass.rimAlphaLight);
    final resolvedWash =
        rimWash ??
        (dark ? GlassSurface.rimWashDark : GlassSurface.rimWashLight);
    final resolvedWashSpan =
        rimWashSpan ??
        (dark ? GlassSurface.rimWashSpanDark : GlassSurface.rimWashSpanLight);
    final resolvedSheen =
        sheenAlpha ??
        (dark ? AppGlass.sheenAlphaDark : AppGlass.sheenAlphaLight);
    final resolvedSaturation =
        saturation ??
        (dark ? AppGlass.saturationDark : AppGlass.saturationLight);

    return ClipRRect(
      borderRadius: radius,
      clipBehavior: clipBehavior,
      child: _sampleBackdrop(
        enabled: resolvedBlur > 0 || resolvedSaturation != 1,
        filter: ui.ImageFilter.compose(
          outer: ui.ColorFilter.matrix(_saturationMatrix(resolvedSaturation)),
          inner: ui.ImageFilter.blur(
            sigmaX: resolvedBlur,
            sigmaY: resolvedBlur,
            tileMode: TileMode.mirror,
          ),
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: radius,
            color: scheme.surface.withValues(alpha: resolvedTint),
          ),
          child: Stack(
            children: [
              if (resolvedSheen > 0)
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: radius,
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        stops: const [0, 0.45, 1],
                        colors: [
                          Colors.white.withValues(alpha: resolvedSheen),
                          Colors.transparent,
                          Colors.white.withValues(alpha: resolvedSheen * 0.35),
                        ],
                      ),
                    ),
                  ),
                ),
              if (resolvedRim > 0)
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: radius,
                      border: Border.all(
                        color: Colors.white.withValues(
                          alpha: resolvedRim * 0.9 * rimScale,
                        ),
                        width: rimWidth,
                      ),
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        stops: <double>[0, resolvedWashSpan, 1],
                        colors: [
                          Colors.white.withValues(
                            alpha: resolvedRim * resolvedWash * rimScale,
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
/// 为什么用矩阵而不是 `ColorFilter.mode`：mode 只能混色，不能提饱和度；
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
