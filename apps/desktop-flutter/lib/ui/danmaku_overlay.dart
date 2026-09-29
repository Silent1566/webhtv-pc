/// 弹幕渲染层（设计文档 §21 Phase 3「字幕/弹幕可开启和关闭」、§10.3、§17.3）。
///
/// 实现方式：Flutter `CustomPaint` 叠加在 `Video` 之上，按播放位置逐帧绘制。
/// 之所以不用引擎原生渲染，是因为 media-kit（libmpv）并未暴露弹幕渲染入口，
/// 而设计文档的参考实现（Flutter + media-kit）也正是用叠加层做弹幕 UI。
///
/// 职责边界：
/// - 本文件只做「给定播放位置与弹幕列表 → 画在哪儿」；
///   轨道分配与可见性判定在 `lib/core/danmaku.dart`（纯逻辑，可单测）；
/// - 不做网络、不持有配置：数据由播放器页拉好后传入；
/// - 关闭时（[enabled] 为 false）完全不绘制，这就是「弹幕可开启和关闭」。
library;

import 'package:flutter/material.dart';

import '../core/danmaku.dart';

/// 弹幕显示设置（§17.5 弹幕可调项）。
class DanmakuStyle {
  const DanmakuStyle({
    this.enabled = true,
    this.opacity = 0.9,
    this.textScale = 1.0,
    this.showScroll = true,
    this.showTop = true,
    this.showBottom = true,
    this.strokeWidth = 1.2,
  });

  /// 总开关。
  final bool enabled;

  /// 整体不透明度（0..1）。
  final double opacity;

  /// 字号缩放（相对弹幕自带字号）。
  final double textScale;

  final bool showScroll;
  final bool showTop;
  final bool showBottom;

  /// 描边宽度（保证浅色弹幕在亮画面上也能看清）。
  final double strokeWidth;

  DanmakuStyle copyWith({
    bool? enabled,
    double? opacity,
    double? textScale,
    bool? showScroll,
    bool? showTop,
    bool? showBottom,
    double? strokeWidth,
  }) {
    return DanmakuStyle(
      enabled: enabled ?? this.enabled,
      opacity: (opacity ?? this.opacity).clamp(0.1, 1.0),
      textScale: (textScale ?? this.textScale).clamp(0.5, 2.5),
      showScroll: showScroll ?? this.showScroll,
      showTop: showTop ?? this.showTop,
      showBottom: showBottom ?? this.showBottom,
      strokeWidth: strokeWidth ?? this.strokeWidth,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is DanmakuStyle &&
      other.enabled == enabled &&
      other.opacity == opacity &&
      other.textScale == textScale &&
      other.showScroll == showScroll &&
      other.showTop == showTop &&
      other.showBottom == showBottom &&
      other.strokeWidth == strokeWidth;

  @override
  int get hashCode => Object.hash(
    enabled,
    opacity,
    textScale,
    showScroll,
    showTop,
    showBottom,
    strokeWidth,
  );
}

/// 按 [style] 过滤出允许显示的弹幕类型。
List<DanmakuItem> filterDanmakuItems(
  List<DanmakuItem> items,
  DanmakuStyle style,
) {
  if (!style.enabled) return const [];
  return items.where((item) {
    switch (item.type) {
      case DanmakuType.scroll:
      case DanmakuType.reverse:
        return style.showScroll;
      case DanmakuType.top:
        return style.showTop;
      case DanmakuType.bottom:
        return style.showBottom;
    }
  }).toList();
}

/// 弹幕叠加层。
class DanmakuOverlay extends StatelessWidget {
  const DanmakuOverlay({
    super.key,
    required this.items,
    required this.position,
    required this.style,
    this.liveItems = const [],
    this.liveNowMs,
    this.scrollDuration = const Duration(milliseconds: 8000),
    this.fixedDuration = const Duration(milliseconds: 4000),
  });

  /// 全部静态弹幕（按时间轴驱动：位置 = [position]）。
  final List<DanmakuItem> items;

  /// 当前播放位置（驱动静态弹幕）。
  final Duration position;

  /// 直播弹幕（实时追加：位置 = 当前时刻 [liveNowMs] − 接收时刻）。
  ///
  /// [DanmakuItem.timeMs] 即直播弹幕的接收时刻（ms），
  /// 渲染时用「当前时刻」作为位置，弹幕在 [scrollDurationMs] 内完成移动后自然消失。
  final List<DanmakuItem> liveItems;

  /// 直播弹幕的当前时刻（ms）。null 时退化为 0，直播弹幕立即全部显示一次。
  final int? liveNowMs;

  final DanmakuStyle style;
  final Duration scrollDuration;
  final Duration fixedDuration;

  @override
  Widget build(BuildContext context) {
    if (!style.enabled || (items.isEmpty && liveItems.isEmpty)) {
      return const SizedBox.shrink();
    }
    return IgnorePointer(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final height = constraints.maxHeight;
          if (width <= 0 || height <= 0) return const SizedBox.shrink();

          final visible = <VisibleDanmaku>[];
          // 静态弹幕：按播放位置驱动。
          final filtered = filterDanmakuItems(items, style);
          visible.addAll(
            DanmakuTrackAllocator.visibleAt(
              items: filtered,
              positionMs: position.inMilliseconds,
              enabled: style.enabled,
              scrollDurationMs: scrollDuration.inMilliseconds,
              fixedDurationMs: fixedDuration.inMilliseconds,
              width: width,
              height: height,
              trackHeight: danmakuTrackHeight * style.textScale,
              gap: danmakuTrackGap,
            ),
          );

          // 直播弹幕：按当前时刻驱动（接收时刻作为开始时刻）。
          final nowMs = liveNowMs ?? 0;
          if (liveItems.isNotEmpty && nowMs > 0) {
            final liveVisible = DanmakuTrackAllocator.visibleAt(
              items: filterDanmakuItems(liveItems, style),
              positionMs: nowMs,
              enabled: style.enabled,
              scrollDurationMs: scrollDuration.inMilliseconds,
              fixedDurationMs: fixedDuration.inMilliseconds,
              width: width,
              height: height,
              trackHeight: danmakuTrackHeight * style.textScale,
              gap: danmakuTrackGap,
            );
            visible.addAll(liveVisible);
          }

          if (visible.isEmpty) return const SizedBox.shrink();
          return CustomPaint(
            size: Size(width, height),
            painter: DanmakuPainter(
              visible: visible,
              style: style,
              scrollDurationMs: scrollDuration.inMilliseconds,
              fixedDurationMs: fixedDuration.inMilliseconds,
            ),
          );
        },
      ),
    );
  }
}

/// 单条弹幕占用的轨道高度（基准值，会按字号缩放）。
const double danmakuTrackHeight = 28;

/// 轨道内相邻弹幕的水平间距。
const double danmakuTrackGap = 12;

/// 顶部弹幕起始留白（避开播放器顶部控件）。
const double danmakuTopPadding = 8;

/// 底部弹幕距离画面底部的留白。
const double danmakuBottomPadding = 12;

/// 弹幕绘制器。
class DanmakuPainter extends CustomPainter {
  DanmakuPainter({
    required this.visible,
    required this.style,
    required this.scrollDurationMs,
    required this.fixedDurationMs,
  });

  final List<VisibleDanmaku> visible;
  final DanmakuStyle style;
  final int scrollDurationMs;
  final int fixedDurationMs;

  @override
  void paint(Canvas canvas, Size size) {
    for (final entry in visible) {
      final item = entry.item;
      final fontSize = item.textSizeSp * style.textScale;
      final painter = _textPainter(item, fontSize);
      final offset = _offsetFor(entry, size, painter);
      if (offset == null) continue;

      painter.paint(canvas, offset);

      // 描边：先画一圈深色轮廓，再叠原文，保证在亮画面上仍可读。
      if (style.strokeWidth > 0) {
        _paintStroke(canvas, painter, offset, fontSize);
      }
      painter.paint(canvas, offset);
    }
  }

  TextPainter _textPainter(DanmakuItem item, double fontSize) {
    final color = Color(item.color).withValues(
      alpha: (Color(item.color).a) * style.opacity,
    );
    return TextPainter(
      text: TextSpan(
        text: item.text,
        style: TextStyle(
          fontSize: fontSize,
          color: color,
          fontWeight: FontWeight.w500,
          height: 1.2,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
  }

  /// 用描边绘制器给文字加深色轮廓（低成本近似：偏移 4 个方向各画一次）。
  void _paintStroke(
    Canvas canvas,
    TextPainter painter,
    Offset offset,
    double fontSize,
  ) {
    final strokeColor = Colors.black.withValues(alpha: 0.75 * style.opacity);
    final strokeStyle = TextStyle(
      fontSize: fontSize,
      color: strokeColor,
      fontWeight: FontWeight.w500,
      height: 1.2,
    );
    final radius = style.strokeWidth;
    for (final delta in [
      Offset(-radius, 0),
      Offset(radius, 0),
      Offset(0, -radius),
      Offset(0, radius),
      Offset(-radius, -radius),
      Offset(radius, radius),
    ]) {
      final strokePainter = TextPainter(
        text: TextSpan(text: painter.plainText, style: strokeStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      strokePainter.paint(canvas, offset + delta);
    }
  }

  /// 计算某条弹幕的绘制位置。
  Offset? _offsetFor(VisibleDanmaku entry, Size size, TextPainter painter) {
    final item = entry.item;
    final trackHeight = danmakuTrackHeight * style.textScale;
    switch (item.type) {
      case DanmakuType.scroll:
        // 从右侧进入、向左移出：progress 0 → x = width，1 → x = -textWidth。
        final travel = size.width + painter.width;
        final x = size.width - travel * entry.progress;
        final y = danmakuTopPadding + entry.track * trackHeight;
        return Offset(x, y);
      case DanmakuType.reverse:
        // 反向：从左侧进入、向右移出。
        final travel = size.width + painter.width;
        final x = -painter.width + travel * entry.progress;
        final y = danmakuTopPadding + entry.track * trackHeight;
        return Offset(x, y);
      case DanmakuType.top:
        final x = (size.width - painter.width) / 2;
        final y = danmakuTopPadding + entry.track * trackHeight;
        return Offset(x, y);
      case DanmakuType.bottom:
        final x = (size.width - painter.width) / 2;
        final y = size.height -
            danmakuBottomPadding -
            (entry.track + 1) * trackHeight;
        return Offset(x, y);
    }
  }

  @override
  bool shouldRepaint(covariant DanmakuPainter oldDelegate) {
    // 位置随播放推进，每帧都可能不同；只要输入变了就重绘。
    if (oldDelegate.style != style) return true;
    if (oldDelegate.scrollDurationMs != scrollDurationMs) return true;
    if (oldDelegate.fixedDurationMs != fixedDurationMs) return true;
    if (oldDelegate.visible.length != visible.length) return true;
    for (var index = 0; index < visible.length; index++) {
      final a = visible[index];
      final b = oldDelegate.visible[index];
      if (a.item != b.item || a.track != b.track || a.progress != b.progress) {
        return true;
      }
    }
    return false;
  }
}
