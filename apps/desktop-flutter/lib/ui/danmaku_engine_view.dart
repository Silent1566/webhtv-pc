/// 弹幕渲染层：把「播放事实 + 弹幕列表」翻译成 `canvas_danmaku` 引擎的调用。
///
/// ## 为什么换成引擎（ADR-0013 修订 5）
///
/// 旧实现用「自有墙钟插值播放器上报位置」驱动弹幕，为此堆了重复上报、迟到上报、
/// 小幅倒退、停滞冻结、追齐等待一整套判据；在 60Hz / DPR 1.0 的真实窗口上观感仍不达标。
/// 这里改为业界通行做法：**运动由引擎自己的动画时钟推进，播放器位置只决定「这一刻投放谁」**
/// （与 DRE、canvas_danmaku、ns_danmaku、weizhenye/Danmaku 同构）。
///
/// 于是「位置报告迟到/重复/倒退」不再可能让已动的弹幕倒退或冻住——它们只影响投放时机。
///
/// ## 两个踩过的坑（都写在这里，避免再犯）
///
/// 1. `DanmakuOption.fontWeight` 不是 CSS 字重，而是 **`FontWeight.values` 的下标**（0..8）。
///    传 400 会直接 `RangeError`，而且异常发生在 `addDanmaku` 内部——表现为「一条都不出来」。
///    要 w400 就传 `FontWeight.w400.index`（= 3）。
/// 2. 引擎的轨道数是按**已布局的视图高度**算的；布局之前投放会因为没有轨道被丢弃，
///    且游标已前移、不会重放。所以布局就绪前不改选项也不投放。
///
/// ## 保真度损失（如实记录）
///
/// 引擎没有反向滚动（B 站 mode 6）。这里把 reverse 归一到 scroll：文本/时间/颜色都对，
/// 只有移动方向变成常规的从右往左。
library;

import 'package:canvas_danmaku/canvas_danmaku.dart' as engine;
import 'package:flutter/material.dart';

import '../core/danmaku.dart';
import '../core/danmaku_style.dart';

/// 引擎要的是 `FontWeight.values` 的下标，不是 CSS 字重。
///
/// `FontWeight.values` = [w100, w200, w300, w400, w500, ...]，所以 w400 是 **3**。
/// 我们统一用 w400（微软雅黑没有真 Medium，w500 会合成加粗发糊，见 DESIGN.md）。
const int danmakuFontWeightIndex = 3;

/// 把 [DanmakuStyle] 翻译成引擎选项。
engine.DanmakuOption danmakuOptionFor(DanmakuStyle style, {double rate = 1}) {
  final speed = rate <= 0 ? 1.0 : rate;
  return engine.DanmakuOption(
    fontSize: DanmakuItem.defaultTextSizeSp * style.textScale,
    // 下标语义（见文件头）：3 = FontWeight.w400。绝不能用 400。
    fontWeight: danmakuFontWeightIndex,
    opacity: style.opacity,
    area: style.areaRatio.clamp(0.1, 1.0),
    duration: style.scrollDurationMs / 1000 / speed,
    staticDuration: style.fixedDurationMs / 1000 / speed,
    strokeWidth: style.strokeWidth,
    hideScroll: !style.showScroll,
    hideTop: !style.showTop,
    hideBottom: !style.showBottom,
    lineHeight: 1.2,
  );
}

/// 弹幕类型映射。反向滚动没有对应类型，归一到 scroll（见文件头）。
engine.DanmakuItemType danmakuItemTypeFor(DanmakuType type) {
  switch (type) {
    case DanmakuType.scroll:
    case DanmakuType.reverse:
      return engine.DanmakuItemType.scroll;
    case DanmakuType.top:
      return engine.DanmakuItemType.top;
    case DanmakuType.bottom:
      return engine.DanmakuItemType.bottom;
  }
}

engine.DanmakuContentItem<Object?> danmakuContentFor(DanmakuItem item) =>
    engine.DanmakuContentItem<Object?>(
      item.text,
      color: Color(item.color),
      type: danmakuItemTypeFor(item.type),
      extra: item,
    );

/// 投放游标：只负责「按播放位置决定投放谁」，与渲染完全解耦（纯逻辑，可单测）。
class DanmakuEmitCursor {
  DanmakuEmitCursor({List<DanmakuItem> items = const []})
    : _items = _sorted(items);

  List<DanmakuItem> _items;
  int _next = 0;
  int _positionMs = 0;

  /// 下一条待投放的数量（测试用）。
  int get pendingCount => _items.length - _next;

  static List<DanmakuItem> _sorted(List<DanmakuItem> items) {
    final copy = [...items];
    copy.sort((a, b) => a.timeMs.compareTo(b.timeMs));
    return copy;
  }

  void reset(List<DanmakuItem> items, {int positionMs = 0}) {
    _items = _sorted(items);
    _positionMs = positionMs;
    _next = _lowerBound(positionMs);
  }

  void seek(int positionMs) {
    _positionMs = positionMs;
    _next = _lowerBound(positionMs);
  }

  int _lowerBound(int positionMs) {
    var lo = 0;
    var hi = _items.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_items[mid].timeMs < positionMs) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  /// 前进到 [positionMs]，返回这段区间内应当投放的弹幕。
  List<DanmakuItem> advanceTo(int positionMs, {int toleranceMs = 250}) {
    if (positionMs + toleranceMs < _positionMs) {
      // 明显倒退（拖动/切集）：重新定位，不补发中间那段。
      seek(positionMs);
      return const [];
    }
    final emit = <DanmakuItem>[];
    while (_next < _items.length && _items[_next].timeMs <= positionMs) {
      emit.add(_items[_next]);
      _next++;
    }
    if (positionMs > _positionMs) _positionMs = positionMs;
    return emit;
  }
}

/// 弹幕层：把播放事实翻译成引擎调用。
class DanmakuEngineView extends StatefulWidget {
  const DanmakuEngineView({
    super.key,
    required this.items,
    required this.position,
    required this.style,
    this.playing = false,
    this.held = false,
    this.seeking = false,
    this.seek,
    this.rate = 1,
    this.liveItems = const [],
  });

  final List<DanmakuItem> items;
  final Duration position;
  final DanmakuStyle style;
  final bool playing;
  final bool held;
  final bool seeking;
  final ({int revision, Duration target})? seek;
  final double rate;
  final List<DanmakuItem> liveItems;

  @override
  State<DanmakuEngineView> createState() => _DanmakuEngineViewState();
}

class _DanmakuEngineViewState extends State<DanmakuEngineView> {
  engine.DanmakuController<Object?>? _controller;
  final DanmakuEmitCursor _cursor = DanmakuEmitCursor();
  Object? _itemsKey;
  final Set<DanmakuItem> _liveEmitted = Set<DanmakuItem>.identity();
  bool _paused = false;
  ({int revision, Duration target})? _lastSeek;
  int? _pendingSeekTargetMs;
  int _seekOriginMs = 0;

  bool get _shouldPause => !widget.playing || widget.held || widget.seeking;

  @override
  void didUpdateWidget(covariant DanmakuEngineView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.style.enabled) {
      _controller = null;
      _liveEmitted.clear();
      return;
    }
    _sync(oldWidget);
  }

  void _sync(DanmakuEngineView? oldWidget) {
    final controller = _controller;
    if (controller == null) return;
    // 布局就绪前不投放、不改选项（见文件头第 2 条）。
    if (controller.viewHeight <= 0 || controller.viewWidth <= 0) return;

    if (widget.seek == null && _lastSeek != null) {
      _lastSeek = null;
      _pendingSeekTargetMs = null;
      _seekOriginMs = 0;
      _cursor.seek(widget.position.inMilliseconds);
    }

    if (oldWidget == null ||
        widget.style != oldWidget.style ||
        widget.rate != oldWidget.rate) {
      controller.updateOption(
        danmakuOptionFor(widget.style, rate: widget.rate),
      );
    }

    final pause = _shouldPause;
    if (pause != _paused) {
      _paused = pause;
      if (pause) {
        controller.pause();
      } else {
        controller.resume();
      }
    }

    if (!identical(widget.items, _itemsKey)) {
      _itemsKey = widget.items;
      controller.clear();
      _cursor.reset(
        widget.items,
        positionMs: _pendingSeekTargetMs ?? widget.position.inMilliseconds,
      );
    }

    final seek = widget.seek;
    if (seek != null && seek != _lastSeek) {
      _lastSeek = seek;
      _seekOriginMs =
          oldWidget?.position.inMilliseconds ?? widget.position.inMilliseconds;
      _pendingSeekTargetMs = seek.target.inMilliseconds;
      controller.clear();
      _cursor.seek(seek.target.inMilliseconds);
    }

    final retainedLive = Set<DanmakuItem>.identity()..addAll(widget.liveItems);
    for (final item in [
      ...controller.scrollDanmaku,
      ...controller.staticDanmaku,
    ]) {
      final arrival = item.content.extra;
      if (!item.expired && arrival is DanmakuItem) {
        retainedLive.add(arrival);
      }
    }
    _liveEmitted.retainAll(retainedLive);
    if (_shouldPause) return;
    final targetMs = _pendingSeekTargetMs;
    if (targetMs != null) {
      final positionMs = widget.position.inMilliseconds;
      // 请求之后的旧位置上报不能把已定位的游标再次拉回去。
      if (positionMs != targetMs && positionMs == _seekOriginMs) return;
      final reached =
          (positionMs - targetMs).abs() <= 250 ||
          (targetMs >= _seekOriginMs
              ? positionMs > targetMs
              : positionMs < targetMs);
      if (!reached) return;
      _pendingSeekTargetMs = null;
    }

    // 同一对象在滚动窗口或仍在屏幕上时只投放一次。
    for (final item in widget.liveItems) {
      if (_liveEmitted.add(item)) {
        controller.addDanmaku(danmakuContentFor(item));
      }
    }

    for (final item in _cursor.advanceTo(widget.position.inMilliseconds)) {
      controller.addDanmaku(danmakuContentFor(item));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.style.enabled) return const SizedBox.shrink();
    return engine.DanmakuScreen<Object?>(
      createdController: (controller) {
        _controller = controller;
        _itemsKey = widget.items;
        _cursor.reset(
          widget.items,
          positionMs: _pendingSeekTargetMs ?? widget.position.inMilliseconds,
        );
        _paused = _shouldPause;
        if (_paused) controller.pause();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && identical(_controller, controller)) _sync(null);
        });
      },
      option: danmakuOptionFor(widget.style, rate: widget.rate),
    );
  }
}
