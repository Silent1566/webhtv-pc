/// 控制浮层（`docs/phase8/design/01` §4）。
///
/// **它不参与布局。** 调用方必须把它作为 `Stack` 的 `Positioned.fill` 子项，
/// 与画面层平级。任何把它放进 `Column`/`Row` 的写法都会让画面重新缩放
/// ——那正是本轮要修的根因（`design/01` §2）。
///
/// 组件根是 `Stack` 且**只含 `Positioned` 子项**：这种情况下 `RenderStack`
/// 取 `constraints.biggest`，于是浮层的大小完全由调用方给的约束决定，
/// 与它内部三段内容的高矮无关。换成 `Column`/`Wrap`/`Align` 都会让
/// 「浮层占多少」重新变成内容的函数。
///
/// 顶栏由调用方传入（`player_page.dart` 传 `AppBar`），因为
/// `integration_test/ui_redesign_visual_flow_test.dart:677-681` 用
/// `find.descendant(of: find.byType(AppBar), ...)` 断言「更多」按钮的位置，
/// **必须保留 `AppBar` widget 类型**（`design/01` §4.1）。
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show ClipOp;

import 'package:flutter/material.dart';

import '../core/player_buttons.dart';
import '../core/skip_plan.dart';
import '../core/skip_segment_colors.dart';
import 'common.dart';
import 'player_controller.dart' show formatByteRate;
import 'scroll_behavior.dart';
import 'glass_widgets.dart';
import 'tokens.dart';

/// Keeps the native modal route, focus, drag and outside-dismiss behavior,
/// without letting the route's fill conceal the player pane.
Future<T?> showPlayerGlassSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = false,
  BoxConstraints? constraints,
}) => showModalBottomSheet<T>(
  context: context,
  isScrollControlled: isScrollControlled,
  constraints: constraints,
  backgroundColor: Colors.transparent,
  elevation: 0,
  showDragHandle: false,
  builder: (context) => GlassPane(
    blurBackdrop: false,
    borderRadius: const BorderRadius.vertical(
      top: Radius.circular(AppRadius.lg),
    ),
    child: Material(
      type: MaterialType.transparency,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            label: MaterialLocalizations.of(context).modalBarrierDismissLabel,
            onTap: () => Navigator.of(context).maybePop(),
            child: SizedBox(
              height: kMinInteractiveDimension,
              child: Center(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.onSurfaceVariant
                        .withValues(alpha: .4),
                    borderRadius: AppRadius.smAll,
                  ),
                  child: const SizedBox(width: 32, height: 4),
                ),
              ),
            ),
          ),
          Flexible(child: Builder(builder: builder)),
        ],
      ),
    ),
  ),
);

/// An anchored Material menu with one non-sampling pane for the whole list.
class PlayerGlassDropdown<T> extends StatelessWidget {
  const PlayerGlassDropdown({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.decoration,
  });

  final T value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?>? onChanged;
  final InputDecoration? decoration;

  @override
  Widget build(BuildContext context) {
    final current = items.where((item) => item.value == value).first;
    final button = PopupMenuButton<T>(
      enabled: onChanged != null,
      initialValue: value,
      onSelected: onChanged,
      color: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      elevation: 0,
      menuPadding: EdgeInsets.zero,
      itemBuilder: (context) => [
        _PlayerDropdownEntry(items: items, value: value),
      ],
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: kMinInteractiveDimension),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(child: current.child),
            const SizedBox(width: AppSpace.xs),
            const Icon(Icons.arrow_drop_down),
          ],
        ),
      ),
    );
    return decoration == null
        ? button
        : InputDecorator(
            decoration: decoration!,
            isEmpty: false,
            child: button,
          );
  }
}

class _PlayerDropdownEntry<T> extends PopupMenuEntry<T> {
  const _PlayerDropdownEntry({required this.items, required this.value});
  final List<DropdownMenuItem<T>> items;
  final T value;

  @override
  double get height => items.length * kMinInteractiveDimension;

  @override
  bool represents(T? value) => items.any((item) => item.value == value);

  @override
  State<_PlayerDropdownEntry<T>> createState() =>
      _PlayerDropdownEntryState<T>();
}

class _PlayerDropdownEntryState<T> extends State<_PlayerDropdownEntry<T>> {
  final _selectedKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final selected = _selectedKey.currentContext;
      if (selected != null) Scrollable.ensureVisible(selected, alignment: .5);
    });
  }

  @override
  Widget build(BuildContext context) => GlassPane(
    blurBackdrop: false,
    padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
    child: Material(
      type: MaterialType.transparency,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final item in widget.items)
            MenuItemButton(
              key: item.value == widget.value ? _selectedKey : null,
              autofocus: item.enabled && item.value == widget.value,
              requestFocusOnHover: false,
              style: const ButtonStyle(
                minimumSize: WidgetStatePropertyAll(
                  Size(0, kMinInteractiveDimension),
                ),
              ),
              onPressed: item.enabled
                  ? () {
                      Navigator.pop<T>(context, item.value);
                      item.onTap?.call();
                    }
                  : null,
              trailingIcon: item.value == widget.value
                  ? const Icon(Icons.check, size: 18)
                  : null,
              child: item.child,
            ),
        ],
      ),
    ),
  );
}

/// 顶栏纱的高度。
///
/// 56（`AppBar` 高度）+ 64 的过渡带：纱到 120 处正好淡到全透明，
/// 画面从顶栏下沿开始重新露出来。写成常量而不是跟着 `topBar` 量，
/// 是因为量尺寸意味着浮层要读子项的固有高度——那正是要避免的耦合。
const double _topScrimExtent = 120;

/// 底栏纱的高度。
///
/// 底栏内容 92（32 进度行 + 4 缝 + 40 动作行 + 上下各 8 内边距）压在
/// 0.86 的最浓处，再往上 68 的过渡带：滑杆两侧的文字必须落在足够深的纱上。
const double _bottomScrimExtent = 160;

/// 浮层的渐变纱。
///
/// 用固定深色而不是 `Theme.of(context).colorScheme.surface`：
/// 播放器背景是**视频帧**，不是应用底色。主题给的 surface 在亮色主题下是浅色，
/// 浅色纱压在高饱和画面上会让文字对比度崩掉
/// （改造前 `player_page.dart` 的注释已经记录了这个问题，实测约 3.5:1）。
///
/// 播放器页整体走恒定暗色主题（`design/01` §4.3），
/// 所以这里的固定深色与页面主题是一致的。
class PlayerOverlayScrim extends StatelessWidget {
  const PlayerOverlayScrim({
    super.key,
    required this.alignment,
    required this.opacity,
  });

  /// 纱最浓的一侧：顶栏用 [Alignment.topCenter]，底栏用 [Alignment.bottomCenter]。
  final Alignment alignment;

  /// 最浓处的不透明度。
  ///
  /// 顶栏 0.72、底栏 0.86（`design/01` §4.3）。底栏更高，因为它承载
  /// 文字与滑杆；顶栏更低，因为从画面到纱的过渡要软，硬边会像贴了一条黑带。
  final double opacity;

  @override
  Widget build(BuildContext context) {
    final fromTop = alignment == Alignment.topCenter;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          // 最浓的一侧是 [alignment]，另一端淡到全透明。
          begin: alignment,
          end: fromTop ? Alignment.bottomCenter : Alignment.topCenter,
          colors: [
            AppPalette.nightGround.withValues(alpha: opacity),
            AppPalette.nightGround.withValues(alpha: 0),
          ],
        ),
      ),
    );
  }
}

/// 分组之间的留白，保留既有动作行几何。
class PlayerOverlayDivider extends StatelessWidget {
  const PlayerOverlayDivider({super.key});

  @override
  Widget build(BuildContext context) =>
      const SizedBox(width: 1 + 2 * AppSpace.xs, height: 20);
}

/// 动作行：单行 + 有富余宽度时**居中**，溢出时退回左对齐 + 横向拖动（`design/03` §5.4）。
///
/// 为什么不用 `Wrap`（改造前的写法）：`Wrap` 在窄窗口下换行，浮层高度随之
/// 从 1 行变 2 行，遮住画面的范围不可预测。上游同做法：
/// `view_control_vod_action.xml:2-9` 的 `HorizontalScrollView`。
///
/// 为什么居中：改造前内容无条件从左边排起，宽窗口下右侧空出近一半宽度，
/// 视觉重心全压在左下角；按钮组本身是「一组动作」，居中才和它承载的内容对齐。
class PlayerOverlayActionRow extends StatelessWidget {
  const PlayerOverlayActionRow({
    super.key,
    required this.buttons,
    required this.groups,
  });

  final List<Widget> buttons;

  /// 与 [buttons] 一一对应；相邻两项分组不同时插入分隔线。
  final List<PlayerButtonGroup> groups;

  @override
  Widget build(BuildContext context) {
    assert(
      buttons.length == groups.length,
      'actionButtons 与 actionGroups 必须一一对应（${buttons.length} != ${groups.length}）',
    );
    final children = <Widget>[];
    // 逐个下标取分组，且以 `buttons` 为长度基准：release 下断言不生效，
    // 这里也不能越界崩掉播放器（分隔线少画一条好过整页白屏）。
    for (var i = 0; i < buttons.length; i++) {
      if (i > 0 && i < groups.length && groups[i] != groups[i - 1]) {
        children.add(const PlayerOverlayDivider());
      }
      children.add(buttons[i]);
    }
    // 动作行溢出时用鼠标左右拖（横向条，§17.4）。
    //
    // 居中与「溢出时左对齐 + 可拖动」是**同一个写法**的两个分支，不要拆成
    // `Center` / `Row(start)` 两套：
    // - `ConstrainedBox(minWidth: 通栏宽度)` 把内容盒撑到至少通栏宽，
    //   装得下时 `Row` 的 `mainAxisSize.min` 仍取内容宽，但外层 minWidth 让
    //   内容盒保持通栏宽，于是 `mainAxisAlignment.center` 把按钮组居中；
    // - 装不下时内容盒被撑到内容宽（> 通栏），`mainAxisAlignment` 分配到的
    //   剩余空间为 0（`RenderFlex` 用 `math.max(0, freeSpace)` 钳过，
    //   不会出现负的 leading space），内容自然从左侧排起，剩下的交给
    //   `SingleChildScrollView` 横向滚动。
    //
    // 用 `LayoutBuilder` 而不是让 `Row` 自己 `MainAxisSize.max`：后者的
    // 子项在无限宽约束里永远居中不了（滚动视图给的正是无限宽）。
    return LayoutBuilder(
      builder: (context, constraints) => HorizontalMouseDrag(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          // 不需要显式关滚动条：`MaterialScrollBehavior.buildScrollbar` 对
          // `Axis.horizontal` 直接返回 child（只有纵向才包 `Scrollbar`），
          // 这正好等于上游 `view_control_vod_action.xml:9` 的 `scrollbars="none"`。
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: constraints.maxWidth),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: children,
            ),
          ),
        ),
      ),
    );
  }
}

/// 进度滑杆：在轨道上叠加「已缓冲区间」。
///
/// **缓冲段用 `Slider.secondaryTrackValue` 画，不自己 `CustomPaint` 一条**：
/// 轨道矩形由 `SliderTrackShape.getPreferredRect` 算出（两侧内缩取
/// `max(thumbWidth, overlayWidth) / 2`），任何自绘的条都要把那段内缩量
/// 复制一遍——主题一改（描边半径、`trackHeight`）缓冲段就与轨道错位，
/// 而且错位是**静默**的（看起来只是"缓冲条有点歪"）。
/// `secondaryTrackValue` 走框架同一个 `trackRect`，天然对齐；它还自带两条
/// 我们本来就要写的判据：
/// - 只有 `secondaryOffset.dx > thumbCenter.dx` 才画
///   （`slider_parts.dart:512-514`）——即**永远不会画出一条负数长度的条**；
/// - 值必须落在 `[min, max]` 内，否则 `Slider` 自己的断言先炸
///   （`slider.dart:206`），所以我们先把 `buffered` 钳进区间。
///
/// 高度与改造前**完全一致**：`Slider` 仍是唯一决定高度的子项，没有新增层
/// （进度行 32 是浮层几何断言的一部分，不能因为多画一条缓冲段而变高）。
class PlayerProgressSlider extends StatefulWidget {
  const PlayerProgressSlider({
    super.key,
    required this.position,
    required this.duration,
    required this.buffered,
    required this.onSeek,
    this.onSeekStart,
    this.onSeekEnd,
    this.thumbnailPreviewEnabled = false,
    this.thumbnailProvider,
    this.previewSourceKey,
    this.skipSegments = const [],
    this.skipSegmentColors = const SkipSegmentColors(),
    this.showSkipSegmentHighlights = true,
  });

  final Duration position;
  final Duration duration;

  /// 引擎上报的已缓冲位置（media_kit 的 `demuxer-cache-time`）。
  final Duration buffered;

  /// 拖动时连续回调（语义与改造前的 `Slider.onChanged` 一致）。
  ///
  /// 回调频率没有变，但**页面把它当"预览"用**：拖动期间只更新拇指与时间，
  /// 松手时（[onSeekEnd] 之后）才真正落一次引擎 seek。别在这里加"每格都 seek"
  /// 的期待——那正是画面长时间静止的根因（单次 seek 1–3 秒，逐格排队）。
  final ValueChanged<Duration> onSeek;

  /// 用户**按下滑杆开始拖动**时回调；直播时为 null（没有可拖的值域）。
  ///
  /// 与 [onSeek] 分开是关键：只有真拖动才发，键盘/快捷键 seek 不发，
  /// 页面据此暂停也绝不会误伤程序化 seek。
  final VoidCallback? onSeekStart;

  /// 用户**松手结束拖动**时回调；与 [onSeekStart] 成对，直播时同样为 null。
  final VoidCallback? onSeekEnd;

  final bool thumbnailPreviewEnabled;
  final Future<Uint8List?> Function(Duration)? thumbnailProvider;
  final Object? previewSourceKey;
  final List<SkipSegment> skipSegments;
  final SkipSegmentColors skipSegmentColors;
  final bool showSkipSegmentHighlights;

  @override
  State<PlayerProgressSlider> createState() => _PlayerProgressSliderState();
}

class _PlayerProgressSliderState extends State<PlayerProgressSlider> {
  /// 拖动中：此时**不画**缓冲段。
  ///
  /// 为什么：拖动期间拇指位置代表"用户想去的地方"，缓冲段却仍指向
  /// "引擎已经拿到的地方"，两者画在同一根轨道上会被读成"这一段已经被
  /// 播放覆盖了"。松手后缓冲段立刻回来，代价只是一次重建。
  bool _dragging = false;
  final _previewPortal = OverlayPortalController();
  final _sliderKey = GlobalKey();
  Timer? _previewDebounce;
  int _request = 0;
  Rect? _trackRect;
  Duration? _previewTarget;
  Uint8List? _previewBytes;
  bool _previewLoading = false;
  double _previewX = 0;
  List<_TimelineSegment> _hoveredSegments = const [];

  List<_TimelineSegment> get _timelineSegments =>
      _TimelineSegment.resolve(widget.skipSegments, widget.duration);

  bool get _canPreview =>
      widget.thumbnailPreviewEnabled &&
      widget.thumbnailProvider != null &&
      widget.duration > Duration.zero;

  @override
  void didUpdateWidget(PlayerProgressSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.previewSourceKey != widget.previewSourceKey ||
        oldWidget.thumbnailPreviewEnabled != widget.thumbnailPreviewEnabled ||
        oldWidget.thumbnailProvider != widget.thumbnailProvider ||
        oldWidget.duration != widget.duration ||
        oldWidget.skipSegments != widget.skipSegments) {
      _hidePreview(duringBuild: true);
    }
  }

  @override
  void dispose() {
    _previewDebounce?.cancel();
    _request++;
    super.dispose();
  }

  void _hidePreview({bool duringBuild = false}) {
    _previewDebounce?.cancel();
    _request++;
    _previewTarget = null;
    _hoveredSegments = const [];
    _previewBytes = null;
    _previewLoading = false;
    if (duringBuild) {
      final request = _request;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && request == _request) _previewPortal.hide();
      });
    } else {
      _previewPortal.hide();
    }
  }

  void _hoverPreview(Offset globalPosition) {
    final rect = _trackRect;
    if (widget.duration <= Duration.zero || rect == null || rect.width <= 0) {
      return;
    }
    if (!_canPreview &&
        (globalPosition.dx < rect.left || globalPosition.dx > rect.right)) {
      _hidePreview();
      return;
    }
    var fraction = ((globalPosition.dx - rect.left) / rect.width).clamp(
      0.0,
      1.0,
    );
    if (Directionality.of(context) == TextDirection.rtl) {
      fraction = 1 - fraction;
    }
    _showPreview(
      Duration(
        milliseconds: (widget.duration.inMilliseconds * fraction).round(),
      ),
    );
  }

  void _showPreview(Duration target) {
    final rect = _trackRect;
    if (widget.duration <= Duration.zero || rect == null) return;
    final matches = _timelineSegments
        .where((segment) => segment.contains(target.inMilliseconds))
        .toList();
    if (!_canPreview && matches.isEmpty) {
      _hidePreview();
      return;
    }
    var fraction = target.inMilliseconds / widget.duration.inMilliseconds;
    if (Directionality.of(context) == TextDirection.rtl) {
      fraction = 1 - fraction;
    }
    _previewX = rect.left + rect.width * fraction;
    if (_previewTarget == target && _previewPortal.isShowing) return;
    _previewDebounce?.cancel();
    final request = ++_request;
    final provider = widget.thumbnailProvider;
    setState(() {
      _previewTarget = target;
      _previewBytes = null;
      _previewLoading = _canPreview;
      _hoveredSegments = matches;
    });
    _previewPortal.show();
    if (!_canPreview) return;
    _previewDebounce = Timer(const Duration(milliseconds: 200), () async {
      Uint8List? bytes;
      try {
        bytes = await provider!(target);
      } catch (_) {
        bytes = null;
      }
      if (!mounted || request != _request || !_canPreview) return;
      setState(() {
        _previewBytes = bytes == null || bytes.isEmpty ? null : bytes;
        _previewLoading = false;
      });
    });
  }

  Widget _buildPreview(BuildContext context) {
    if (_previewTarget == null) return const SizedBox.shrink();
    final overlayBox =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final sliderBox =
        _sliderKey.currentContext!.findRenderObject()! as RenderBox;
    final sliderTop = overlayBox
        .globalToLocal(sliderBox.localToGlobal(Offset.zero))
        .dy;
    final width = math.min(
      192.0,
      math.max(0.0, overlayBox.size.width - AppSpace.lg),
    );
    final segmentHeight = _hoveredSegments.length * 28.0;
    final height = _canPreview
        ? width * 9 / 16 + 28 + segmentHeight
        : segmentHeight + AppSpace.sm;
    final x = overlayBox.globalToLocal(Offset(_previewX, 0)).dx;
    final left = (x - width / 2).clamp(
      0.0,
      math.max(0.0, overlayBox.size.width - width),
    );
    final top = math.max(0.0, sliderTop - height - AppSpace.sm);
    final theme = Theme.of(context);
    final time = _timelineTime(_previewTarget!.inMilliseconds);
    final segmentRows = [
      for (final segment in _hoveredSegments)
        SizedBox(
          height: 28,
          child: Center(
            child: Text(
              '${segment.kind.label}  '
              '${_timelineTime(segment.startMs)}–${_timelineTime(segment.endMs)}',
              style: theme.textTheme.labelSmall,
            ),
          ),
        ),
    ];
    if (!_canPreview) {
      return Positioned(
        left: left.toDouble(),
        top: top,
        width: width,
        height: height,
        child: IgnorePointer(
          child: GlassPane(
            key: const ValueKey('player-skip-segment-preview'),
            blurBackdrop: false,
            borderRadius: AppRadius.smAll,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
              child: Column(children: segmentRows),
            ),
          ),
        ),
      );
    }
    Widget feedback(String text) => Center(
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
    return Positioned(
      left: left.toDouble(),
      top: top,
      width: width,
      height: height,
      child: IgnorePointer(
        child: GlassPane(
          key: const ValueKey('player-thumbnail-preview'),
          blurBackdrop: false,
          borderRadius: AppRadius.smAll,
          child: ClipRRect(
            borderRadius: AppRadius.smAll,
            child: Column(
              children: [
                SizedBox(
                  width: width,
                  height: width * 9 / 16,
                  child: _previewLoading
                      ? feedback('加载中…')
                      : _previewBytes == null
                      ? feedback('预览不可用')
                      : Image.memory(
                          _previewBytes!,
                          fit: BoxFit.contain,
                          errorBuilder: (_, error, stack) => feedback('预览不可用'),
                        ),
                ),
                SizedBox(
                  height: 28,
                  child: Center(
                    child: Text(
                      time,
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ),
                ...segmentRows,
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 缓冲段在滑杆值域里的位置；不需要画时为 null。
  ///
  /// 三条判据（顺序即语义）：
  /// 1. 直播/时长未知（`duration <= 0`）——没有值域，画不出来；
  /// 2. 拖动中——见 [_dragging]；
  /// 3. `buffered <= position`——没有"前方已缓冲"可言，画出来会是一条
  ///    负数长度的条（框架不会画，但我们也不该把值传下去：
  ///    `secondaryTrackValue` 非 null 会参与断言与 `Slider` 的相等判定）。
  double? get _bufferedValue {
    if (_dragging) return null;
    final maxMs = widget.duration.inMilliseconds;
    if (maxMs <= 0) return null;
    final positionMs = widget.position.inMilliseconds.clamp(0, maxMs);
    final bufferedMs = widget.buffered.inMilliseconds;
    if (bufferedMs <= positionMs) return null;
    return bufferedMs.clamp(positionMs, maxMs).toDouble();
  }

  @override
  Widget build(BuildContext context) {
    final maxMs = widget.duration.inMilliseconds;
    final live = maxMs <= 0;
    final max = live ? 1.0 : maxMs.toDouble();
    final value = widget.position.inMilliseconds
        .clamp(0, max.toInt())
        .toDouble();
    final slider = Slider(
      key: _sliderKey,
      value: value,
      max: max,
      secondaryTrackValue: _bufferedValue,
      // 缓冲段颜色取 `tertiary`（浅蓝），**不是** `outline`（初版）也不是
      // `primary`（琥珀，已播放段在用）。
      //
      // 初版写的是 `outline`，理由是"它是调色板里深色底上提亮一档的角色，
      // 压在未播放轨道上仍读得出来"。**这个判断被实测推翻了**：`outline`
      // (#3A4560) 画在 `surfaceContainerHighest` (#2C3654) 上算出来只有
      // **1.25:1**——比一条发丝线还难分辨，用户反馈"基本看不清"。
      //
      // `tertiary` (#9BB8E0) 对同底色是 **5.86:1**，过 WCAG AA 的 4.5:1；
      // 同时它与 `primary` 的琥珀在色相上明确分离，不会被读成"已经放到
      // 那儿了"。缓冲段仍低于已播放段的强调度（琥珀对浅蓝），层级不变。
      secondaryActiveColor: Theme.of(context).colorScheme.tertiary,
      onChanged: live
          ? null
          : (next) {
              final target = Duration(milliseconds: next.round());
              widget.onSeek(target);
              if (_dragging) _showPreview(target);
            },
      // 只在拖动期间置位：键盘/快捷键 seek 不该让缓冲段闪一下。
      //
      // 注意：**单击轨道**同样会走 start → seek → end（Flutter 的 `Slider`
      // 先安置拇指再结束交互）。对上面两个回调就是"点一下进度条 = 一次导航，
      // 暂停随即恢复"——这是既定语义，不是漏判：点击本来就要 seek，暂停只是
      // 让这次 seek 落在"停住"的状态上。
      onChangeStart: live
          ? null
          : (value) {
              setState(() => _dragging = true);
              _showPreview(Duration(milliseconds: value.round()));
              widget.onSeekStart?.call();
            },
      onChangeEnd: live
          ? null
          : (_) {
              setState(() => _dragging = false);
              _hidePreview();
              widget.onSeekEnd?.call();
            },
    );
    final theme = SliderTheme.of(context);
    // Mirror the native Slider default while honoring the existing theme.
    // ignore: deprecated_member_use
    final legacyAppearance = theme.year2023 != false;
    final SliderTrackShape shape =
        theme.trackShape ??
        (Theme.of(context).useMaterial3 && !legacyAppearance
            ? const GappedSliderTrackShape()
            : const RoundedRectSliderTrackShape());
    return OverlayPortal(
      controller: _previewPortal,
      overlayChildBuilder: _buildPreview,
      child: MouseRegion(
        onHover: (event) => _hoverPreview(event.position),
        onExit: (_) => _hidePreview(),
        child: SliderTheme(
          data: theme.copyWith(
            trackShape: _MeasuredPreviewTrack(
              shape,
              (rect) => _trackRect = rect,
              widget.showSkipSegmentHighlights ? _timelineSegments : const [],
              widget.skipSegmentColors,
              Theme.of(context).colorScheme.onSurface,
            ),
          ),
          child: slider,
        ),
      ),
    );
  }
}

String _timelineTime(int milliseconds) {
  final seconds = milliseconds ~/ 1000;
  final mm = (seconds ~/ 60 % 60).toString().padLeft(2, '0');
  final ss = (seconds % 60).toString().padLeft(2, '0');
  return seconds >= 3600
      ? '${seconds ~/ 3600}:$mm:$ss'
      : '${(seconds ~/ 60).toString().padLeft(2, '0')}:$ss';
}

class _TimelineSegment {
  const _TimelineSegment(this.kind, this.startMs, this.endMs, this.durationMs);
  final SkipKind kind;
  final int startMs;
  final int endMs;
  final int durationMs;
  double get startFraction => startMs / durationMs;
  double get endFraction => endMs / durationMs;

  bool contains(int targetMs) =>
      targetMs >= startMs &&
      (targetMs < endMs || targetMs == durationMs && endMs == durationMs);

  static List<_TimelineSegment> resolve(
    List<SkipSegment> segments,
    Duration duration,
  ) {
    final durationMs = duration.inMilliseconds;
    if (durationMs <= 0) return const [];
    return [
      for (final segment in segments)
        if ((segment.openEnded ? durationMs : segment.endMs).clamp(
              0,
              durationMs,
            ) >
            segment.startMs.clamp(0, durationMs))
          _TimelineSegment(
            segment.kind,
            segment.startMs.clamp(0, durationMs),
            (segment.openEnded ? durationMs : segment.endMs).clamp(
              0,
              durationMs,
            ),
            durationMs,
          ),
    ];
  }
}

/// Delegates drawing unchanged and observes the framework's actual track rectangle.
class _MeasuredPreviewTrack extends SliderTrackShape {
  const _MeasuredPreviewTrack(
    this.delegate,
    this.onRect,
    this.segments,
    this.colors,
    this.outlineColor,
  );
  final SliderTrackShape delegate;
  final ValueChanged<Rect> onRect;
  final List<_TimelineSegment> segments;
  final SkipSegmentColors colors;
  final Color outlineColor;

  @override
  bool get isRounded => delegate.isRounded;

  @override
  Rect getPreferredRect({
    required RenderBox parentBox,
    Offset offset = Offset.zero,
    required SliderThemeData sliderTheme,
    bool isEnabled = false,
    bool isDiscrete = false,
  }) {
    final rect = delegate.getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    onRect(rect.shift(parentBox.localToGlobal(Offset.zero) - offset));
    return rect;
  }

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isEnabled = false,
    bool isDiscrete = false,
    required TextDirection textDirection,
  }) {
    final rect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    Rect segmentRect(_TimelineSegment segment) {
      final start = segment.startFraction;
      final end = segment.endFraction;
      final left = textDirection == TextDirection.rtl ? 1 - end : start;
      final right = textDirection == TextDirection.rtl ? 1 - start : end;
      return Rect.fromLTRB(
        rect.left + rect.width * left,
        rect.top,
        rect.left + rect.width * right,
        rect.bottom,
      );
    }

    final visible = segments;
    if (visible.isNotEmpty) {
      context.canvas.save();
      for (final segment in visible) {
        final band = segmentRect(segment);
        context.canvas.clipRect(
          Rect.fromLTRB(
            band.left,
            offset.dy,
            band.right,
            offset.dy + parentBox.size.height,
          ),
          clipOp: ClipOp.difference,
          doAntiAlias: false,
        );
      }
    }
    void paintTrack(SliderThemeData theme, {bool withBuffer = true}) {
      final nativePainter = switch (delegate) {
        RoundedRectSliderTrackShape shape => shape.paint,
        GappedSliderTrackShape shape => shape.paint,
        _ => null,
      };
      if (visible.isNotEmpty && nativePainter != null) {
        nativePainter(
          context,
          offset,
          parentBox: parentBox,
          sliderTheme: theme,
          enableAnimation: enableAnimation,
          thumbCenter: thumbCenter,
          secondaryOffset: withBuffer ? secondaryOffset : null,
          isEnabled: isEnabled,
          isDiscrete: isDiscrete,
          textDirection: textDirection,
          additionalActiveTrackHeight: 0,
        );
      } else {
        delegate.paint(
          context,
          offset,
          parentBox: parentBox,
          sliderTheme: theme,
          enableAnimation: enableAnimation,
          thumbCenter: thumbCenter,
          secondaryOffset: withBuffer ? secondaryOffset : null,
          isEnabled: isEnabled,
          isDiscrete: isDiscrete,
          textDirection: textDirection,
        );
      }
    }

    paintTrack(sliderTheme);
    if (visible.isNotEmpty) context.canvas.restore();
    if (rect.width <= 0 || rect.height <= 0) return;
    // Native colors must not remain beneath antialiased segment edges.
    for (final segment in visible) {
      final band = segmentRect(segment);
      context.canvas.save();
      // Only clip horizontally: clipping the rail's fractional Y edges would
      // apply coverage twice and make highlights thinner than the native rail.
      context.canvas.clipRect(
        Rect.fromLTRB(
          band.left,
          offset.dy,
          band.right,
          offset.dy + parentBox.size.height,
        ),
        doAntiAlias: false,
      );
      final color = Color(colors.colorFor(segment.kind));
      // Buffer must not composite with the marker at the band edge.
      paintTrack(
        withBuffer: false,
        sliderTheme.copyWith(
          activeTrackColor: color,
          inactiveTrackColor: color,
          secondaryActiveTrackColor: color,
          disabledActiveTrackColor: color,
          disabledInactiveTrackColor: color,
          disabledSecondaryActiveTrackColor: color,
        ),
      );
      final luminance = color.computeLuminance();
      final trackLuminance = sliderTheme.inactiveTrackColor!.computeLuminance();
      final contrast =
          (math.max(luminance, trackLuminance) + 0.05) /
          (math.min(luminance, trackLuminance) + 0.05);
      if (contrast < 3) {
        final edgePaint = Paint()..color = outlineColor;
        context.canvas.drawRect(
          Rect.fromLTRB(
            band.left,
            band.top,
            math.min(band.right, band.left + 1),
            band.bottom,
          ),
          edgePaint,
        );
        context.canvas.drawRect(
          Rect.fromLTRB(
            math.max(band.left, band.right - 1),
            band.top,
            band.right,
            band.bottom,
          ),
          edgePaint,
        );
      }
      context.canvas.restore();
    }
  }
}

/// 缓冲中提示是否出现。
///
/// **单独抽成纯函数**：这条判据是"两个圈不叠加"的唯一依据，而它在
/// widget 树上不可直接观测（`isLoading` 为 true 时两个条件都为真，
/// 差别只在渲染结果）。抽出来之后三种组合都能被直接断言。
///
/// 判据：`(isBuffering || isSeeking) && !isLoading`。
/// - 加载阶段已有全屏 [LoadingBlock]，再叠一个环等于画两个圈；
/// - 加载完成后才轮到"播放中途卡顿"这个场景，此时 `isLoading` 为 false。
///
/// **为什么把 [isSeeking] 也当成缓冲态**：mpv 在 seek 期间不上报 buffering
/// （`paused-for-cache` 恒为 no、`cache-buffering-state` 甚至还是 100），
/// 只有 `seeking=yes` 会持续十几秒。只看缓冲流的话，拖动进度条后用户
/// 看到的就是「画面静止 + 什么都没转」——同一次等待，只是上报口径不同。
bool showBufferingIndicator({
  required bool isBuffering,
  bool isSeeking = false,
  required bool isLoading,
}) => (isBuffering || isSeeking) && !isLoading;

/// 画面中央的加载/缓冲提示：环形 + 可选百分比，环下显示网速。
///
/// 复用 [LoadingBlock]（"一处定义，全站同一个圈"）而不是另写一个
/// `CircularProgressIndicator`：描边宽度随直径缩放的规则已经在那边定过。
///
/// **不吃指针**（外层 `IgnorePointer`）：缓冲中用户仍可能想点画面唤出
/// 控制栏或右键菜单，提示层挡住中间那块等于把常用手势全废掉。
class PlayerBufferingIndicator extends StatelessWidget {
  const PlayerBufferingIndicator({
    super.key,
    this.percent,
    this.bytesPerSecond,
    this.size = 44,
  });

  /// 0–100；null 表示引擎还没上报百分比。
  final double? percent;

  /// 与屏显共用的最近一次网速采样；null 显示 `—`。
  final double? bytesPerSecond;

  /// 起播沿用 36，缓冲时用 44 为环内百分比留空间。
  final double size;

  @override
  Widget build(BuildContext context) {
    final label = percent;
    final theme = Theme.of(context);
    return IgnorePointer(
      child: Center(
        child: GlassPane(
          blurBackdrop: false,
          padding: const EdgeInsets.all(AppSpace.md),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: size,
                height: size,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    LoadingBlock(size: size),
                    if (label != null)
                      Text(
                        '${label.round()}%',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurface,
                          fontFeatures: kTabularFigures,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpace.sm),
              Text(
                formatByteRate(bytesPerSecond),
                textAlign: TextAlign.center,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurface,
                  fontFeatures: kTabularFigures,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 控制浮层：顶栏 + 进度行 + 动作行。
///
/// 三段都贴边，中间留空给画面——**中间是真的空的**：没有铺满的容器，
/// 所以画面上的单击/双击手势能穿过浮层中部打到下层（`design/01` §7 A3 的前提）。
class PlayerControlOverlay extends StatelessWidget {
  const PlayerControlOverlay({
    super.key,
    required this.topBar,
    required this.progressRow,
    required this.actionButtons,
    required this.actionGroups,
    this.extraRow,
  });

  /// 顶栏。调用方传入 `AppBar`，类型必须保留（见本文件头注释）。
  final Widget topBar;

  /// 进度行（时间 + 滑杆 + 时长）。
  final Widget progressRow;

  final List<Widget> actionButtons;

  /// 与 [actionButtons] 一一对应，用于在分组边界插分隔线。
  final List<PlayerButtonGroup> actionGroups;

  /// 底栏之上的可选附加行（当前是解析源条）。
  ///
  /// 为什么放在底栏 Column 里而不是另起一层浮层：它属于「这一行控制」，
  /// 必须跟控制栏一起显隐、一起被 `IgnorePointer` 关掉命中测试；独立成层会
  /// 出现「控制栏已隐藏、解析条还能点」的错位。列高变化不影响视频区——整个
  /// 浮层是 `Positioned.fill`，不参与布局（`DESIGN.md:391-410`）。
  final Widget? extraRow;

  @override
  Widget build(BuildContext context) {
    return Stack(
      // 顶栏、纱、滚动中的动作行都不该画到浮层框外。`Clip.hardEdge` 是
      // `Stack` 的默认值，这里显式写出来：它不是可选装饰，而是行为约定。
      clipBehavior: Clip.hardEdge,
      children: [
        // 顶栏纱：从顶部渐隐。纯装饰，不接收指针。
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: IgnorePointer(
            child: SizedBox(
              height: _topScrimExtent,
              child: const PlayerOverlayScrim(
                alignment: Alignment.topCenter,
                opacity: 0.72,
              ),
            ),
          ),
        ),
        // 底栏纱：从底部渐隐。底栏承载文字与滑杆，需要更高对比度。
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: IgnorePointer(
            child: SizedBox(
              height: _bottomScrimExtent,
              child: const PlayerOverlayScrim(
                alignment: Alignment.bottomCenter,
                opacity: 0.86,
              ),
            ),
          ),
        ),
        // 顶栏。放在两条纱之后 = 画在纱之上。
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: GlassPane(
            blurBackdrop: false,
            borderRadius: const BorderRadius.vertical(
              bottom: Radius.circular(AppRadius.lg),
            ),
            child: SizedBox(width: double.infinity, child: topBar),
          ),
        ),
        // 底栏：进度行 + 动作行，贴着底边往上排。
        //
        // 整块再包一层 [_BottomBarHitArea]：底栏的空白（上下 padding、行间
        // 留白）也是底栏，点它必须什么都不发生。缺这一层时那些像素会继续
        // 落到下层画面手势上——画面单击是播放/暂停，用户看到的就是
        // 「点进度条差几像素 → 没跳进度，反而暂停了」。
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: _BottomBarHitArea(
            child: GlassPane(
              blurBackdrop: false,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(AppRadius.lg),
              ),
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpace.md,
                vertical: AppSpace.sm,
              ),
              child: Material(
                type: MaterialType.transparency,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  // **必须 stretch**：`Column` 的默认 `crossAxisAlignment` 是
                  // `center`，那样两个孩子都只拿到松散宽度——进度行（一个
                  // `SizedBox(height: 32)` 之类的空盒子）会缩成 0 宽并被水平居中。
                  // `design/03` §5.4 要求「进度行是独立的 Row，始终占满宽度」。
                  //
                  // 动作行的**内容**居中是这个 `Column` 之外的事（见
                  // [PlayerOverlayActionRow] 的 `LayoutBuilder` + `minWidth`）：
                  // 靠这里松弛居中做不到——那样动作行的盒子本身会缩成内容宽，
                  // 溢出时连滚动视口都不存在了。所以这里保持 stretch，
                  // 让动作行自己拿到通栏宽度、自己决定内容怎么排。
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (extraRow != null) ...[
                      extraRow!,
                      const SizedBox(height: AppSpace.xs),
                    ],
                    progressRow,
                    const SizedBox(height: AppSpace.xs),
                    PlayerOverlayActionRow(
                      buttons: actionButtons,
                      groups: actionGroups,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 底栏的命中底板：整块吸收指针，但不参与任何手势竞争。
///
/// 用 `Listener` 而不是 `GestureDetector(onTap: () {})`：后者会往手势竞技场
/// 里塞一个 TapRecognizer，滑杆的点击/拖动与按钮的 InkWell 都要先跟它抢；
/// `Listener` 只做命中测试、不消费事件，子节点语义零变化。
///
/// 也不能用 `AbsorbPointer`：它把**子树**一起吃掉，进度条就点不动了。
///
/// 只盖底栏自己的盒子，浮层中部仍是空的——`design/01` §7 A3 要求画面上的
/// 单击/双击能穿过浮层中部打到下层，这条约束不受影响。
class _BottomBarHitArea extends StatelessWidget {
  const _BottomBarHitArea({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      Listener(behavior: HitTestBehavior.opaque, child: child);
}

/// 跳转失败后的两个恢复出口（`docs/reference/xiugou-tv-borrowings.md` §3.2）。
///
/// 位置：盖在画面之上、底栏控制区之上，**不接管整屏输入**——用户仍然可以直接
/// 再拖一次进度条、使用恢复操作，或关闭提示继续播放。文案必须点明「跳转没成功」，否则
/// 用户会以为片子本身坏了。
class PlayerSeekRecoveryBanner extends StatelessWidget {
  const PlayerSeekRecoveryBanner({
    super.key,
    required this.onRetry,
    required this.onReturn,
    required this.onDismiss,
  });

  /// 出口一：再跳一次同一个目标。
  final VoidCallback onRetry;

  /// 出口二：回到跳转前的位置。
  final VoidCallback onReturn;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = context.semanticColors;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 520),
      child: GlassPane(
        blurBackdrop: false,
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpace.lg,
          vertical: AppSpace.md,
        ),
        child: Material(
          type: MaterialType.transparency,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.error_outline,
                    size: 18,
                    color: semantic.statusDegraded,
                  ),
                  const SizedBox(width: AppSpace.sm),
                  Expanded(
                    child: Text(
                      '跳转没成功',
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: theme.colorScheme.onSurface,
                        fontWeight: AppWeight.title,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭跳转提示（Esc）',
                    onPressed: onDismiss,
                    icon: const Icon(Icons.close, size: 18),
                    style: IconButton.styleFrom(
                      foregroundColor: theme.colorScheme.onSurfaceVariant,
                      minimumSize: const Size.square(36),
                      padding: EdgeInsets.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpace.xs),
              Text(
                '画面没有停在你要的位置。可以再试一次，或回到跳转前的位置。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: AppSpace.sm),
              Wrap(
                spacing: AppSpace.sm,
                runSpacing: AppSpace.xs,
                children: [
                  OutlinedButton.icon(
                    key: const ValueKey('player-seek-recovery-retry'),
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('重试跳转'),
                  ),
                  TextButton(
                    key: const ValueKey('player-seek-recovery-return'),
                    onPressed: onReturn,
                    child: const Text('回到原位置'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
