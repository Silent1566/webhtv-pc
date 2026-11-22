/// 弹幕渲染层（设计文档 §21 Phase 3「字幕/弹幕可开启和关闭」、§10.3、§17.3，
/// `docs/phase9/design/02-subtitle-danmaku.md` §2.4「渲染时钟」）。
///
/// 实现方式：Flutter `CustomPaint` 叠加在 `Video` 之上，按播放位置逐帧绘制。
/// 之所以不用引擎原生渲染，是因为 media-kit（libmpv）并未暴露弹幕渲染入口，
/// 而设计文档的参考实现（Flutter + media-kit）也正是用叠加层做弹幕 UI。
///
/// 职责边界：
/// - 本文件只做「给定播放位置与弹幕列表 → 画在哪儿」；
///   轨道分配与可见性判定在 `lib/core/danmaku.dart`（纯逻辑，可单测）；
/// - 不做网络、不持有配置：数据由播放器页拉好后传入；
/// - 关闭时（[DanmakuStyle.enabled] 为 false）完全不绘制，这就是「弹幕可开启和关闭」。
///
/// ## 为什么要自带渲染时钟
///
/// 播放器上报的 `position` 是**事件驱动的离散值**，两次上报之间整页不重建，
/// 弹幕就停在原地看着像「一格一格跳」。这里用 [DanmakuMotionClock] 把离散位置
/// 插值成每帧连续位置，并用 [Ticker] 驱动重绘——**只重绘这一层，不 setState**，
/// 于是弹幕每帧都有位移，而播放器页不必为此重建。
library;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../core/danmaku.dart';
import '../core/danmaku_motion.dart';
import '../core/danmaku_style.dart';

// 兼容旧引用：Phase 3–8 的代码/测试一直从本文件取 `DanmakuStyle`。
export '../core/danmaku_style.dart';

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

/// 单条弹幕占用的轨道高度（基准值，会按字号缩放）。
const double danmakuTrackHeight = 28;

/// 轨道内相邻弹幕的水平间距。
const double danmakuTrackGap = 12;

/// 顶部弹幕起始留白（避开播放器顶部控件）。
const double danmakuTopPadding = 8;

/// 底部弹幕距离画面底部的留白。
const double danmakuBottomPadding = 12;

/// 弹幕叠加层。
class DanmakuOverlay extends StatefulWidget {
  const DanmakuOverlay({
    super.key,
    required this.items,
    required this.position,
    required this.style,
    this.liveItems = const [],
    this.liveNowMs,
    this.playing = false,
    this.rate = 1,
    this.clockNow,
  });

  /// 全部静态弹幕（按时间轴驱动：位置 = [position]）。
  final List<DanmakuItem> items;

  /// 当前播放位置（驱动静态弹幕）。
  final Duration position;

  /// 直播弹幕（实时追加：位置 = 当前时刻 [liveNowMs] − 接收时刻）。
  ///
  /// [DanmakuItem.timeMs] 即直播弹幕的接收时刻（ms），
  /// 渲染时用「当前时刻」作为位置，弹幕在 scrollDurationMs 内完成移动后自然消失。
  final List<DanmakuItem> liveItems;

  /// 直播弹幕的当前时刻（ms）。null 时用墙钟逐帧取，直播弹幕同样每帧移动。
  final int? liveNowMs;

  final DanmakuStyle style;

  /// 播放器是否正在播放：只有播放中才逐帧推进，暂停时弹幕停在原地。
  final bool playing;

  /// 播放倍速（1.0 = 原速）。倍速下弹幕位移按同一倍率放大。
  final double rate;

  /// 时间源（测试注入用）。默认 [DateTime.now]。
  final DateTime Function()? clockNow;

  @override
  State<DanmakuOverlay> createState() => _DanmakuOverlayState();
}

class _DanmakuOverlayState extends State<DanmakuOverlay>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final DanmakuMotionClock _clock = DanmakuMotionClock();

  /// 每帧自增，作为 [CustomPaint] 的 repaint 通道：重绘不重建。
  final ValueNotifier<int> _frame = ValueNotifier<int>(0);

  /// 排版缓存跨帧、跨重建复用（理由见 [DanmakuTextLayoutCache]）。
  final DanmakuTextLayoutCache _layoutCache = DanmakuTextLayoutCache();

  DanmakuScene? _staticScene;
  Object? _staticSceneKey;
  DanmakuScene? _liveScene;
  Object? _liveSceneKey;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    _syncClock();
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant DanmakuOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncClock();
    _syncTicker();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _frame.dispose();
    super.dispose();
  }

  DateTime _now() => (widget.clockNow ?? DateTime.now)();

  void _syncClock() {
    _clock.sync(
      position: widget.position,
      playing: widget.playing,
      rate: widget.rate,
      at: _now(),
    );
  }

  void _onTick(Duration _) {
    // 只推进重绘：这里若 setState，整页会跟着每帧重建。
    _frame.value = _frame.value + 1;
  }

  bool get _wantsTicker =>
      widget.playing &&
      widget.style.enabled &&
      (widget.items.isNotEmpty || widget.liveItems.isNotEmpty);

  void _syncTicker() {
    if (_wantsTicker) {
      if (!_ticker.isActive) _ticker.start();
    } else if (_ticker.isActive) {
      _ticker.stop();
    }
  }

  /// 静态弹幕场景：条目/样式/尺寸不变时复用，避免每次重建都重排轨道。
  DanmakuScene _staticSceneFor(double width, double height) {
    final style = widget.style;
    final key = (widget.items, style, width, height);
    final cached = _staticScene;
    if (cached != null && _staticSceneKey == key) return cached;
    final scene = DanmakuScene.plan(
      items: filterDanmakuItems(widget.items, style),
      enabled: style.enabled,
      scrollDurationMs: style.scrollDurationMs,
      fixedDurationMs: style.fixedDurationMs,
      width: width,
      height: height,
      trackHeight: danmakuTrackHeight * style.textScale,
      gap: danmakuTrackGap,
      maxTracksRatio: style.areaRatio,
      maxTracks: style.maxTracks,
    );
    _staticSceneKey = key;
    _staticScene = scene;
    return scene;
  }

  DanmakuScene _liveSceneFor(double width, double height) {
    final style = widget.style;
    final key = (widget.liveItems, style, width, height);
    final cached = _liveScene;
    if (cached != null && _liveSceneKey == key) return cached;
    final scene = DanmakuScene.plan(
      items: filterDanmakuItems(widget.liveItems, style),
      enabled: style.enabled,
      scrollDurationMs: style.scrollDurationMs,
      fixedDurationMs: style.fixedDurationMs,
      width: width,
      height: height,
      trackHeight: danmakuTrackHeight * style.textScale,
      gap: danmakuTrackGap,
      maxTracksRatio: style.areaRatio,
      maxTracks: style.maxTracks,
    );
    _liveSceneKey = key;
    _liveScene = scene;
    return scene;
  }

  @override
  Widget build(BuildContext context) {
    final style = widget.style;
    if (!style.enabled || (widget.items.isEmpty && widget.liveItems.isEmpty)) {
      return const SizedBox.shrink();
    }
    return IgnorePointer(
      // 单独成层：弹幕逐帧重绘时不连带重绘视频与控件层。
      child: RepaintBoundary(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final height = constraints.maxHeight;
            if (width <= 0 || height <= 0) return const SizedBox.shrink();

            final staticScene = _staticSceneFor(width, height);
            final liveScene = _liveSceneFor(width, height);
            if (staticScene.isEmpty && liveScene.isEmpty) {
              return const SizedBox.shrink();
            }

            final liveNowMs = widget.liveNowMs;
            return CustomPaint(
              size: Size(width, height),
              painter: DanmakuPainter(
                scene: staticScene,
                liveScene: liveScene,
                style: style,
                positionOf: () => _clock.sample(_now()),
                liveNowOf: liveNowMs == null
                    ? () => _now().millisecondsSinceEpoch
                    : () => liveNowMs,
                layoutCache: _layoutCache,
                repaint: _frame,
              ),
            );
          },
        ),
      ),
    );
  }
}

/// 文本排版缓存：按「文本 + 字号 + 颜色 + 描边」复用 [TextPainter]。
///
/// 必须挂在叠加层的 State 上（而不是每帧新建的 [DanmakuPainter]）：位置上报
/// 会导致整层重建，绘制器跟着换新，缓存若跟着绘制器走就等于没有缓存。
class DanmakuTextLayoutCache {
  /// 缓存条数上限；超出就整体清空（弹幕文本天然高重复，命中率足够）。
  static const int maxEntries = 512;

  final Map<(String, double, double, int, double), TextPainter> _layouts = {};
  int _layoutCount = 0;

  /// 累计真正做过的排版次数（测试用来确认命中缓存）。
  int get layoutCount => _layoutCount;

  TextPainter resolve({
    required (String, double, double, int, double) key,
    required TextPainter Function() build,
  }) {
    final cached = _layouts[key];
    if (cached != null) return cached;
    if (_layouts.length >= maxEntries) _layouts.clear();
    final painter = build()..layout();
    _layouts[key] = painter;
    _layoutCount++;
    return painter;
  }
}

/// 弹幕绘制器。
///
/// 每帧都要跑一遍，所以有两处「必须便宜」：
/// - 可见集合走预排场景（[DanmakuScene]），只碰屏幕上活跃的那几条；
/// - 文本排版按「文本 + 字号 + 颜色 + 描边」缓存，第二帧起不再重排。
class DanmakuPainter extends CustomPainter {
  DanmakuPainter({
    required this.scene,
    required this.liveScene,
    required this.style,
    required this.positionOf,
    required this.liveNowOf,
    this.layoutCache,
    super.repaint,
  });

  /// 静态弹幕场景（按播放位置查询）。
  final DanmakuScene scene;

  /// 直播弹幕场景（按墙钟查询）。
  final DanmakuScene liveScene;

  final DanmakuStyle style;

  /// 采样当前播放位置（由渲染时钟插值得到）。
  final Duration Function() positionOf;

  /// 采样直播弹幕的「当前时刻」（epoch ms）。
  final int Function() liveNowOf;

  /// 排版缓存：由叠加层持有并跨帧、跨重建复用；不传则本绘制器自建一份。
  final DanmakuTextLayoutCache? layoutCache;

  late final DanmakuTextLayoutCache _cache =
      layoutCache ?? DanmakuTextLayoutCache();

  /// 当前采样到的播放位置（测试用）。
  int get debugPositionMs => positionOf().inMilliseconds;

  /// 累计做了多少次文本排版（测试用来确认命中缓存）。
  int get debugTextLayoutCount => _cache.layoutCount;

  /// 排版缓存本体（测试用来确认重建后仍在复用同一份）。
  DanmakuTextLayoutCache get debugLayoutCache => _cache;

  @override
  void paint(Canvas canvas, Size size) {
    if (!style.enabled) return;
    _paintEntries(
      canvas,
      size,
      scene.visibleAt(style.offsetPositionMs(positionOf().inMilliseconds)),
    );
    if (!liveScene.isEmpty) {
      final liveNowMs = liveNowOf();
      // 直播弹幕的时刻来自网络事件，0 表示还没收到任何消息。
      if (liveNowMs > 0) {
        _paintEntries(
          canvas,
          size,
          liveScene.visibleAt(style.offsetPositionMs(liveNowMs)),
        );
      }
    }
  }

  void _paintEntries(
    Canvas canvas,
    Size size,
    List<VisibleDanmaku> entries,
  ) {
    for (final entry in entries) {
      final item = entry.item;
      final fontSize = item.textSizeSp * style.textScale;
      final fill = _fillPainter(item, fontSize);
      final offset = _offsetFor(entry, size, fill.width);
      if (offset == null) continue;
      // 描边用真正的 stroke 画笔一次画完：旧实现沿 8 个方向各叠一遍文字，
      // 既贵（每条每帧多排 6 次版）又会在字边留下重影般的虚边。
      if (style.strokeWidth > 0) {
        _strokePainter(item, fontSize).paint(canvas, offset);
      }
      fill.paint(canvas, offset);
    }
  }

  TextPainter _fillPainter(DanmakuItem item, double fontSize) {
    final base = Color(item.color);
    final color = base.withValues(alpha: base.a * style.opacity);
    return _layout(
      key: (item.text, fontSize, -1, item.color, style.opacity),
      build: () => TextPainter(
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
      ),
    );
  }

  TextPainter _strokePainter(DanmakuItem item, double fontSize) {
    final strokeWidth = style.strokeWidth * 2;
    return _layout(
      key: (item.text, fontSize, strokeWidth, 0, style.opacity),
      build: () => TextPainter(
        text: TextSpan(
          text: item.text,
          style: TextStyle(
            fontSize: fontSize,
            fontWeight: FontWeight.w500,
            height: 1.2,
            foreground: Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = strokeWidth
              ..strokeJoin = StrokeJoin.round
              ..color = Colors.black.withValues(alpha: 0.75 * style.opacity),
          ),
        ),
        textDirection: TextDirection.ltr,
      ),
    );
  }

  TextPainter _layout({
    required (String, double, double, int, double) key,
    required TextPainter Function() build,
  }) => _cache.resolve(key: key, build: build);

  /// 计算某条弹幕的绘制位置。
  Offset? _offsetFor(VisibleDanmaku entry, Size size, double textWidth) {
    final item = entry.item;
    final trackHeight = danmakuTrackHeight * style.textScale;
    switch (item.type) {
      case DanmakuType.scroll:
        // 从右侧进入、向左移出：progress 0 → x = width，1 → x = -textWidth。
        final travel = size.width + textWidth;
        final x = size.width - travel * entry.progress;
        final y = danmakuTopPadding + entry.track * trackHeight;
        return Offset(x, y);
      case DanmakuType.reverse:
        // 反向：从左侧进入、向右移出。
        final travel = size.width + textWidth;
        final x = -textWidth + travel * entry.progress;
        final y = danmakuTopPadding + entry.track * trackHeight;
        return Offset(x, y);
      case DanmakuType.top:
        final x = (size.width - textWidth) / 2;
        final y = danmakuTopPadding + entry.track * trackHeight;
        return Offset(x, y);
      case DanmakuType.bottom:
        final x = (size.width - textWidth) / 2;
        final y =
            size.height - danmakuBottomPadding - (entry.track + 1) * trackHeight;
        return Offset(x, y);
    }
  }

  @override
  bool shouldRepaint(covariant DanmakuPainter oldDelegate) {
    // 逐帧推进走 repaint 通道（渲染时钟），这里只处理「场景/样式换了」。
    if (oldDelegate.style != style) return true;
    if (oldDelegate.scene != scene) return true;
    if (oldDelegate.liveScene != liveScene) return true;
    return false;
  }
}