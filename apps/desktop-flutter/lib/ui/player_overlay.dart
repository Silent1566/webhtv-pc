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

import 'package:flutter/material.dart';

import '../core/player_buttons.dart';
import 'common.dart';
import 'scroll_behavior.dart';
import 'tokens.dart';

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

/// 分组之间的发丝竖线。
///
/// 不是按钮，不可配置、不可隐藏——它由分组边界自动插入
/// （`design/03` §5.1）。用户能隐藏的是按钮，不是分组本身。
class PlayerOverlayDivider extends StatelessWidget {
  const PlayerOverlayDivider({super.key});

  /// 发丝线的粗细与长度。
  static const double _thickness = 1;
  static const double _height = 20;

  @override
  Widget build(BuildContext context) {
    // 颜色取 `colorScheme.outline` 而**不是** `Theme.of(context).dividerColor`。
    //
    // 两者在本仓里是不同角色：`dividerColor` 被设成 `outlineVariant.withValues(alpha: 0.72)`
    // = `#232C46 @ 0.72`，那是「深色表面上再压一层更深的线」——在应用卡片里没问题，
    // 但这根线画在**视频**上：底栏纱到分隔线所在高度（约 y=552，纱从 440 开始渐变）
    // 只剩约 0.2 的不透明度，画面透出 80%。影片常见的黑边/暗场在这条位置接近纯黑，
    // 深色线压上去实测对比度约 1.2:1 ——**等于没画**。
    //
    // `outline`（暗色下 `#3A4560`）是调色板里「深色底上提亮一档」的那个角色，
    // 压在 `nightGround` 上约 1.9:1：仍是一条发丝线，但在暗场里读得出来。
    // 与亮场也兼容（浅色的线在亮画面上同样可见），所以两种画面都成立。
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.xs),
      child: Container(
        width: _thickness,
        height: _height,
        color: Theme.of(context).colorScheme.outline,
      ),
    );
  }
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
  });

  final Duration position;
  final Duration duration;

  /// 引擎上报的已缓冲位置（media_kit 的 `demuxer-cache-time`）。
  final Duration buffered;

  /// 拖动时连续回调（语义与改造前的 `Slider.onChanged` 一致）。
  final ValueChanged<Duration> onSeek;

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
    final value = widget.position.inMilliseconds.clamp(0, max.toInt()).toDouble();
    return Slider(
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
      // 分隔线用 `outline` 能成立是因为它画在**视频帧**上（见
      // [PlayerOverlayDivider] 的对比度论证），而这里是**深色轨道**之上，
      // 底色不同，结论不能照搬。
      //
      // `tertiary` (#9BB8E0) 对同底色是 **5.86:1**，过 WCAG AA 的 4.5:1；
      // 同时它与 `primary` 的琥珀在色相上明确分离，不会被读成"已经放到
      // 那儿了"。缓冲段仍低于已播放段的强调度（琥珀对浅蓝），层级不变。
      secondaryActiveColor: Theme.of(context).colorScheme.tertiary,
      onChanged: live
          ? null
          : (next) => widget.onSeek(Duration(milliseconds: next.round())),
      // 只在拖动期间置位：键盘/快捷键 seek 不该让缓冲段闪一下。
      onChangeStart: live ? null : (_) => setState(() => _dragging = true),
      onChangeEnd: live ? null : (_) => setState(() => _dragging = false),
    );
  }
}

/// 缓冲中提示是否出现。
///
/// **单独抽成纯函数**：这条判据是"两个圈不叠加"的唯一依据，而它在
/// widget 树上不可直接观测（`isLoading` 为 true 时两个条件都为真，
/// 差别只在渲染结果）。抽出来之后三种组合都能被直接断言。
///
/// 判据：`isBuffering && !isLoading`。
/// - 加载阶段已有全屏 [LoadingBlock]，再叠一个环等于画两个圈；
/// - 加载完成后才轮到"播放中途卡顿"这个场景，此时 `isLoading` 为 false。
bool showBufferingIndicator({
  required bool isBuffering,
  required bool isLoading,
}) => isBuffering && !isLoading;

/// 画面中央的缓冲中提示：环形 + 可选百分比。
///
/// 复用 [LoadingBlock]（"一处定义，全站同一个圈"）而不是另写一个
/// `CircularProgressIndicator`：描边宽度随直径缩放的规则已经在那边定过。
///
/// **不吃指针**（外层 `IgnorePointer`）：缓冲中用户仍可能想点画面唤出
/// 控制栏或右键菜单，提示层挡住中间那块等于把常用手势全废掉。
class PlayerBufferingIndicator extends StatelessWidget {
  const PlayerBufferingIndicator({super.key, this.percent});

  /// 0–100；null 表示引擎还没上报百分比（`cache-buffering-state` 未就绪）。
  ///
  /// 两种形态：有值 → 环中显示百分比数字；无值 → 只有一个无限旋转的环。
  final double? percent;

  /// 环的直径。44 不是间距 token 里的值，而是**尺寸**：比
  /// `LoadingBlock` 默认 36 大一圈，好让环中的百分比数字不显得拥挤。
  static const double _diameter = 44;

  @override
  Widget build(BuildContext context) {
    final label = percent;
    return IgnorePointer(
      child: Center(
        child: SizedBox(
          width: _diameter,
          height: _diameter,
          child: Stack(
            alignment: Alignment.center,
            children: [
              const LoadingBlock(size: _diameter),
              if (label != null)
                Text(
                  '${label.round()}%',
                  // 环内的数字压在任意视频帧上：必须浅色 + 描边（同
                  // `player_osd.dart` 的理由：fixture 是高饱和彩条）。
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurface,
                    fontFeatures: kTabularFigures,
                    shadows: const [
                      Shadow(
                        color: Colors.black,
                        offset: Offset(1, 1),
                        blurRadius: 2,
                      ),
                    ],
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
  });

  /// 顶栏。调用方传入 `AppBar`，类型必须保留（见本文件头注释）。
  final Widget topBar;

  /// 进度行（时间 + 滑杆 + 时长）。
  final Widget progressRow;

  final List<Widget> actionButtons;

  /// 与 [actionButtons] 一一对应，用于在分组边界插分隔线。
  final List<PlayerButtonGroup> actionGroups;

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
        Positioned(top: 0, left: 0, right: 0, child: topBar),
        // 底栏：进度行 + 动作行，贴着底边往上排。
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpace.md,
              vertical: AppSpace.sm,
            ),
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
      ],
    );
  }
}
