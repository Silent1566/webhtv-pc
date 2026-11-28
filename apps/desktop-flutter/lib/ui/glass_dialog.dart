/// dialog / sheet 的玻璃包装器：一条 barrier 策略 + 两个内容包装器 + 两个
/// 打开函数 + 一个玻璃专用文字角色。
///
/// 三条已经量过的结论决定了这个文件长这样：
///  1. **玻璃必须由 widget 带来**：dialogTheme 只能装 Color，把填色改成
///     半透明得到的是"背景原样透出来"的塑料片（pilot-1 §1）。
///  2. **barrier 是玻璃的采样底**：默认 Colors.black54 先把页面压暗 54%，
///     玻璃再染底，12px 说明文字掉到 2.76:1（pilot-1 §4-1）。所以亮色必须换
///     一层更轻的遮罩，玻璃才采得到未压暗的页面。
///  3. **暗色也上玻璃（本阶段）**：卡点从来不是材料参数，而是玻璃上的文字角色。
///     同一块暗色玻璃面板上，onSurfaceVariant 只有 3.16:1，换成
///     glassInkSecondary 是 4.90:1（实测见 ink-1/probes.json）。
///
library;

import 'dart:ui' show SemanticsRole;

import 'package:flutter/material.dart';

import 'glass_surface.dart';
import 'glass_widgets.dart';
import 'tokens.dart';

// 调用点只 import 本文件就够：包装器、遮罩色与玻璃文字角色都在这里。
export 'glass_chrome.dart' show GlassTopBar, GlassTopBarBackdrop;

/// 弹层的遮罩色（= 玻璃的采样底）。
abstract final class AppGlassBarrier {
  /// 暗色 dialog 遮罩：与 Material `DialogRoute` 的默认值完全相同，
  /// 所以暗色路径上"换成我们的取值"等于没换。
  static const Color dialogDark = Colors.black54;

  /// 亮色 dialog 遮罩：0.54 → 0.18。
  ///
  /// 数字（`shell-1/probes.json`，1440×900、深色条纹底 + 玻璃面板）：
  /// 默认 0.54 把采样底压掉一半，12px 说明文字 2.76:1（pilot-1 实测）；
  /// 0.18 时面板底 `#a3aab4`、同样的文字仍是 2.95:1 —— **遮罩不是根因**，
  /// 根因是"玻璃上的次要文字用了 onSurfaceVariant"（见 [glassSecondaryInk]）。
  /// 遮罩只负责分出层级，不负责把页面关灯。
  static const Color dialogLight = Color(0x2E000000);

  /// 暗色 sheet 遮罩 alpha：沿用 `showSourceSwapSheet` 改动前的 `scrim@0.42`，
  /// 暗色浮层的遮罩也逐像素不变。
  static const double sheetScrimAlpha = 0.42;
}

/// 亮色 0.18 / 暗色 `black54`（Material 默认）。
///
/// 遮罩按**亮度**分档，与"这块地方是不是玻璃"无关。
///
/// 这是红线 1 的支点：遮罩决定面板外那圈页面被压暗多少，动它就会动到面板外的
/// 每一个像素。所以暗色即便进了玻璃路径，遮罩仍是 Material 的默认 black54
/// （数值上与改动前完全相同）。
Color glassBarrierColor(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? AppGlassBarrier.dialogDark
    : AppGlassBarrier.dialogLight;

/// 浮层的遮罩：亮色同样用 0.18；暗色保持既有 `scrim@0.42`。
Color glassSheetBarrierColor(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? Theme.of(context).colorScheme.scrim
          .withValues(alpha: AppGlassBarrier.sheetScrimAlpha)
    : AppGlassBarrier.dialogLight;

/// 玻璃面板上的**次要文字**色。
///
/// 亮色玻璃的底由"页面内容 × 0.58 染底"合成，遇到深色剧照/海报时面板会一起变暗：
/// 实测（`shell-1/probes.json`，面板 `#a3aab4`）同一块面板上 `onSurfaceVariant`
/// 只有 **2.95:1**，换成 `onSurface` 是 **7.79:1**（门槛 4.5，见报告 §6）。
/// 暗色同理，只是方向相反：暗色玻璃的底是"页面内容 × 0.42 染底"，遇到亮海报
/// （剧照、封面）时面板会被顶起来，实测同一块面板上 onSurfaceVariant 只有
/// **3.16:1**。所以这个角色在暗色取 AppPalette.nightInkOnGlass（4.90）。
///
/// 也就是说：它不是"某一次调透明度"，而是一个**按亮度分档的语义角色**——
/// 亮色 onSurface、暗色 nightInkOnGlass，两档都记在 ink-1/probes.json 里。
Color glassSecondaryInk(BuildContext context) =>
    glassSecondaryInkOf(Theme.of(context));

/// 同上，但直接吃 [ThemeData]：给只在 build 里拿得到 theme 的私有小组件用。
///
/// 扩展缺失时按亮度回落，而不是抛异常：页面级测试大量用裸 MaterialApp
/// （见 tokens.dart 里 AppSemanticColorsX 的说明）。
Color glassSecondaryInkOf(ThemeData theme) =>
    theme.extension<AppSemanticColors>()?.glassInkSecondary ??
    defaultSemanticColors(theme.brightness).glassInkSecondary;

/// Bounded alert layout with one clipped glass panel and a Material dialog route.
///
/// Lazy content should scroll itself (the default). Set [scrollable] for long,
/// non-lazy content that needs to scroll together with the title.
class GlassAlertDialog extends StatelessWidget {
  const GlassAlertDialog({
    super.key,
    this.title,
    this.content,
    this.actions,
    this.scrollable = false,
    this.blurBackdrop = true,
    this.constraints,
    this.insetPadding,
    this.titlePadding,
    this.titleTextStyle,
    this.contentPadding,
    this.contentTextStyle,
    this.actionsPadding,
    this.actionsAlignment = MainAxisAlignment.end,
    this.actionsOverflowAlignment = OverflowBarAlignment.end,
    this.actionsOverflowDirection = VerticalDirection.down,
    this.actionsOverflowButtonSpacing = AppSpace.xs,
    this.buttonPadding,
    this.semanticLabel,
    this.alignment,
  });

  final Widget? title;
  final Widget? content;
  final List<Widget>? actions;
  final bool scrollable;
  final bool blurBackdrop;
  final BoxConstraints? constraints;
  final EdgeInsets? insetPadding;
  final EdgeInsetsGeometry? titlePadding;
  final TextStyle? titleTextStyle;
  final EdgeInsetsGeometry? contentPadding;
  final TextStyle? contentTextStyle;
  final EdgeInsetsGeometry? actionsPadding;
  final MainAxisAlignment actionsAlignment;
  final OverflowBarAlignment actionsOverflowAlignment;
  final VerticalDirection actionsOverflowDirection;
  final double actionsOverflowButtonSpacing;
  final EdgeInsetsGeometry? buttonPadding;
  final String? semanticLabel;
  final AlignmentGeometry? alignment;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dialogTheme = DialogTheme.of(context);
    final hasActions = actions?.isNotEmpty ?? false;
    final label =
        semanticLabel ??
        switch (theme.platform) {
          TargetPlatform.iOS || TargetPlatform.macOS => null,
          _ => MaterialLocalizations.of(context).alertDialogLabel,
        };
    final titleWidget = title == null
        ? null
        : Padding(
            padding:
                titlePadding ??
                EdgeInsets.fromLTRB(
                  AppSpace.xl,
                  AppSpace.xl,
                  AppSpace.xl,
                  content != null
                      ? AppSpace.lg
                      : (hasActions ? 0 : AppSpace.xl),
                ),
            child: DefaultTextStyle.merge(
              style:
                  titleTextStyle ??
                  dialogTheme.titleTextStyle ??
                  theme.textTheme.titleLarge,
              child: Semantics(
                container: true,
                namesRoute:
                    label == null && theme.platform != TargetPlatform.iOS,
                child: title,
              ),
            ),
          );
    final contentWidget = content == null
        ? null
        : Padding(
            padding:
                contentPadding ??
                EdgeInsets.fromLTRB(
                  AppSpace.xl,
                  title == null ? AppSpace.xl : 0,
                  AppSpace.xl,
                  hasActions ? 0 : AppSpace.xl,
                ),
            child: DefaultTextStyle.merge(
              style:
                  contentTextStyle ??
                  dialogTheme.contentTextStyle ??
                  theme.textTheme.bodyMedium,
              child: Semantics(
                container: true,
                explicitChildNodes: true,
                child: content,
              ),
            ),
          );
    final body = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (scrollable && (titleWidget != null || contentWidget != null))
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [?titleWidget, ?contentWidget],
              ),
            ),
          )
        else ...[
          ?titleWidget,
          if (contentWidget != null) Flexible(child: contentWidget),
        ],
        if (hasActions)
          Padding(
            padding:
                actionsPadding ??
                dialogTheme.actionsPadding ??
                const EdgeInsets.all(AppSpace.xl),
            child: OverflowBar(
              alignment: actionsAlignment,
              spacing: buttonPadding == null
                  ? AppSpace.sm
                  : buttonPadding!
                            .resolve(Directionality.of(context))
                            .horizontal /
                        2,
              overflowAlignment: actionsOverflowAlignment,
              overflowDirection: actionsOverflowDirection,
              overflowSpacing: actionsOverflowButtonSpacing,
              children: actions!,
            ),
          ),
      ],
    );
    final limits =
        constraints ??
        dialogTheme.constraints ??
        const BoxConstraints(minWidth: 280, maxWidth: 420);
    return glassDialogShell(
      context,
      insetPadding: insetPadding,
      alignment: alignment,
      constraints: limits,
      semanticsRole: SemanticsRole.alertDialog,
      blurBackdrop: blurBackdrop,
      child: ConstrainedBox(
        // Also cap themes specifying only a minimum. Layout stays constraint-
        // driven; measuring intrinsic width would throw for lazy viewports.
        constraints: BoxConstraints(
          maxWidth: limits.hasBoundedWidth ? limits.maxWidth : 420,
        ),
        child: label == null
            ? body
            : Semantics(
                scopesRoute: true,
                explicitChildNodes: true,
                namesRoute: true,
                label: label,
                child: body,
              ),
      ),
    );
  }
}

/// Use for an already laid out panel, never for a child with its own Dialog.
Widget glassDialogShell(
  BuildContext context, {
  required Widget child,
  Key? key,
  EdgeInsets? insetPadding,
  AlignmentGeometry? alignment,
  BoxConstraints? constraints,
  SemanticsRole semanticsRole = SemanticsRole.dialog,
  bool blurBackdrop = true,
}) {
  return Dialog(
    key: key,
    backgroundColor: Colors.transparent,
    surfaceTintColor: Colors.transparent,
    elevation: 0,
    insetPadding:
        insetPadding ??
        DialogTheme.of(context).insetPadding ??
        const EdgeInsets.all(AppSpace.xl),
    alignment: alignment,
    constraints: constraints,
    shape: const RoundedRectangleBorder(borderRadius: AppRadius.lgAll),
    semanticsRole: semanticsRole,
    child: GlassPane(
      blurBackdrop: blurBackdrop,
      // A transparent Material keeps ink and debug ListTile checks inside the
      // decorated pane; the pane still paints every visible pixel.
      child: Material(type: MaterialType.transparency, child: child),
    ),
  );
}

/// 浮层（sheet）内容包装器：形状只保留上圆角，与既有浮层的
/// `BorderRadius.vertical(top: AppRadius.lg)` 对齐。
Widget glassSheetShell(BuildContext context, {required Widget child}) {
  return GlassSurface(
    padding: EdgeInsets.zero,
    borderRadius: const BorderRadius.vertical(
      top: Radius.circular(AppRadius.lg),
    ),
    child: child,
  );
}

/// Material dialog routing and focus, with a brightness-aware fallback scrim.
Future<T?> showGlassDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  Color? barrierColor,
  String? barrierLabel,
  bool useSafeArea = true,
  bool useRootNavigator = true,
  RouteSettings? routeSettings,
  Offset? anchorPoint,
  TraversalEdgeBehavior? traversalEdgeBehavior,
  bool fullscreenDialog = false,
  bool? requestFocus,
  AnimationStyle? animationStyle,
}) {
  return showDialog<T>(
    context: context,
    builder: builder,
    barrierDismissible: barrierDismissible,
    barrierColor:
        barrierColor ??
        DialogTheme.of(context).barrierColor ??
        Theme.of(context).dialogTheme.barrierColor ??
        glassBarrierColor(context),
    barrierLabel: barrierLabel,
    useSafeArea: useSafeArea,
    useRootNavigator: useRootNavigator,
    routeSettings: routeSettings,
    anchorPoint: anchorPoint,
    traversalEdgeBehavior: traversalEdgeBehavior,
    fullscreenDialog: fullscreenDialog,
    requestFocus: requestFocus,
    animationStyle: animationStyle,
  );
}

/// `showModalBottomSheet` 的玻璃版：参数照抄 `showSourceSwapSheet` 改动前的
/// 那一组（透明底 + 零阴影 + 不钉宽），只把遮罩色按明暗分档。
///
/// 收在一处的理由：这三个参数（透明底 / 零阴影 / 不钉宽）是"浮层是玻璃"的前提，
/// 散在各个调用点上迟早会漂移。
Future<T?> showGlassSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    // 零阴影：层级只靠表面阶梯与发丝边表达（DESIGN.md）。
    elevation: 0,
    constraints: const BoxConstraints(),
    barrierColor: glassSheetBarrierColor(context),
    builder: builder,
  );
}
