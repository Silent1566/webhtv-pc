/// 外壳与详情顶栏的玻璃材质。
///
/// 为什么外壳要单独一个文件：顶栏是全站唯一一处共享 chrome，它的材料
/// （实底 / 玻璃）必须能一处改、全站生效，也必须能单独挂载断言。
/// `GlassSurface` 负责「一块玻璃长什么样」，这里负责「这块地方该不该是玻璃」。
library;

import 'package:flutter/material.dart';

import 'glass_surface.dart';
import 'tokens.dart';

/// 外壳顶栏高度：与既有顶栏（`_TopBar` 的 64）一致，改这里就是改全站顶栏。
const double kGlassTopBarHeight = 64;

/// 内容区顶部内边距：内容不下穿时从顶栏下沿开始。
///
/// 从 [kGlassTopBarHeight] 派生而不是再写一个 64——顶栏高度一改，内容跟着改。
/// 这里**不**用 `MediaQuery` 全局注入：48 个页面里 30 个滚动容器自带显式
/// padding，会把注入值顶掉（layout-audit §G3），由各滚动视图声明。
const double kShellContentTopInset = kGlassTopBarHeight;

/// 栏背后是什么——玻璃能不能成立，取决于它。
///
/// 这不是配置项而是**事实声明**：`BackdropFilter` 对纯色背景是恒等变换
/// （模糊常量 = 常量，提饱和灰色 = 灰），所以「背后只有 Scaffold 实底」时，
/// 玻璃只会退化成一层半透明染色——那正是契约禁止的「用半透明色假装玻璃」。
enum GlassTopBarBackdrop {
  /// 栏背后确实有可视层（壁纸铺到栏后、或内容页的首屏底图压到栏下）：模糊有东西可采。
  content,

  /// 栏背后没有可视层可采样：没有壁纸、内容页也没有自己的首屏底图
  /// （例如无配置时的首页空态）。此时顶栏必须保持实底。
  flatSurface,
}

/// 外壳顶栏仅在有已解码底图时采样，其他场景保留实底。
class GlassTopBar extends StatelessWidget {
  const GlassTopBar({
    super.key,
    required this.child,
    this.backdrop = GlassTopBarBackdrop.flatSurface,
  });

  final Widget child;

  /// 栏背后有什么（见 [GlassTopBarBackdrop]）。由外壳按**这一帧的事实**声明：
  /// 有可视层才是 [GlassTopBarBackdrop.content]，没有就是
  /// [GlassTopBarBackdrop.flatSurface]——不按页面身份预设。
  final GlassTopBarBackdrop backdrop;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const padding = EdgeInsets.symmetric(horizontal: AppSpace.xl);
    if (backdrop == GlassTopBarBackdrop.content) {
      return GlassChromeSurface(
        showRim: false,
        child: SizedBox(
          height: kGlassTopBarHeight,
          child: Padding(
            padding: padding,
            child: Theme(
              data: glassChromeControlTheme(Theme.of(context)),
              child: child,
            ),
          ),
        ),
      );
    }
    return Container(
      height: kGlassTopBarHeight,
      padding: padding,
      decoration: BoxDecoration(
        // 无底图时仍用低一档表面分区，不再画外壳分隔线。
        color: scheme.surfaceContainerLowest,
      ),
      child: child,
    );
  }
}

/// Use only on active glass; the opaque bar keeps the standard control ink.
ThemeData glassChromeControlTheme(ThemeData theme) {
  final ink = theme.colorScheme.onSurface;
  final buttons = theme.textButtonTheme.style;
  final appBar = theme.appBarTheme;
  return theme.copyWith(
    iconTheme: theme.iconTheme.copyWith(color: ink),
    appBarTheme: appBar.copyWith(
      foregroundColor: ink,
      iconTheme: (appBar.iconTheme ?? const IconThemeData()).copyWith(
        color: ink,
      ),
      actionsIconTheme: (appBar.actionsIconTheme ?? const IconThemeData())
          .copyWith(color: ink),
    ),
    textButtonTheme: TextButtonThemeData(
      style: (buttons ?? const ButtonStyle()).copyWith(
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) {
            return buttons?.foregroundColor?.resolve(states);
          }
          return ink;
        }),
      ),
    ),
  );
}

/// One clipped filter for a bar whose caller has a decoded backdrop.
class GlassChromeSurface extends StatelessWidget {
  const GlassChromeSurface({
    super.key,
    required this.child,
    this.showRim = false,
  });

  final Widget child;
  final bool showRim;

  @override
  Widget build(BuildContext context) => GlassSurface(
    radius: 0,
    padding: EdgeInsets.zero,
    rimAlpha: showRim ? null : 0,
    tintAlpha: Theme.of(context).brightness == Brightness.dark
        ? AppGlass.tintAlphaDenseDark
        : null,
    child: child,
  );
}

/// Extends the scroll viewport up to the shell's top without moving fixed
/// controls. The builder adds the leading overflow to its scroll view's own padding.
class ShellScrollUnderlap extends StatelessWidget {
  const ShellScrollUnderlap({
    super.key,
    required this.viewportBottom,
    required this.builder,
  });

  final double? viewportBottom;
  final Widget Function(
    BuildContext context,
    BoxConstraints constraints,
    double leading,
  )
  builder;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final bottom = viewportBottom;
      if (bottom == null ||
          !bottom.isFinite ||
          bottom <= constraints.maxHeight) {
        return builder(context, constraints, 0);
      }
      final leading = bottom - constraints.maxHeight;
      // Paint in the top-bar strip and the original body, not over fixed controls.
      return OverflowBox(
        alignment: Alignment.bottomCenter,
        minHeight: bottom,
        maxHeight: bottom,
        child: ClipPath(
          clipBehavior: Clip.hardEdge,
          clipper: _ShellScrollClip(leading),
          child: builder(context, constraints, leading),
        ),
      );
    },
  );
}

class _ShellScrollClip extends CustomClipper<Path> {
  const _ShellScrollClip(this.leading);

  final double leading;

  @override
  Path getClip(Size size) => Path()
    ..addRect(Rect.fromLTRB(0, 0, size.width, kShellContentTopInset))
    ..addRect(Rect.fromLTRB(0, leading, size.width, size.height));

  @override
  bool shouldReclip(_ShellScrollClip oldClipper) =>
      oldClipper.leading != leading;
}
