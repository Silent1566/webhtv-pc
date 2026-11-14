/// 屏显层（`docs/phase8/design/02`）。
///
/// 上游依据：`PlayerOsdController.java` 与 `view_player_osd.xml`。
///
/// 职责边界：
/// - 本文件只做「给定一组值 → 画在四角与面板上」；
/// - 取数在 `lib/core/osd_diagnostics.dart`（纯函数，可单测）；
/// - 刷新循环在 `player_page.dart`（它持有 controller 与 Timer）。
///
/// **整层 `IgnorePointer`**：屏显是纯信息层，任何情况下都不接收指针
/// （对齐上游 `view_player_osd.xml:6-7` 的 `clickable=false focusable=false`）。
library;

import 'package:flutter/material.dart';

import '../core/osd_config.dart';
import '../core/osd_diagnostics.dart';
import 'player_controller.dart' show formatByteRate;
import 'tokens.dart';

/// 屏显文本样式。
///
/// **字号显式指定 14**，不通过 `textTheme`：`DESIGN.md` 的 The Metric-Neutral Rule
/// 记录了实测——改 `textTheme` 会移动所有页面里不带 `ensureVisible` 的 `tap`。
///
/// **必须描边**：背景是任意视频帧（实测 fixture 是高饱和彩条），
/// 纯白字在亮画面上不可读。上游同做法（`view_player_osd.xml:26-29` 的 shadow）。
///
/// **必须 `tabular`**：时钟与进度每秒刷新，比例字形会让整行左右抖动。
TextStyle _osdTextStyle() => const TextStyle(
  fontSize: 14,
  height: 1.3,
  color: Colors.white,
  fontFeatures: kTabularFigures,
  shadows: [
    Shadow(color: Colors.black, offset: Offset(1.5, 1.5), blurRadius: 2),
  ],
);

String _formatDuration(Duration value) {
  final total = value.inSeconds;
  final hours = total ~/ 3600;
  final minutes = (total % 3600) ~/ 60;
  final seconds = total % 60;
  String two(int number) => number.toString().padLeft(2, '0');
  return hours > 0
      ? '$hours:${two(minutes)}:${two(seconds)}'
      : '${two(minutes)}:${two(seconds)}';
}

/// 屏显层。
class PlayerOsdLayer extends StatelessWidget {
  const PlayerOsdLayer({
    super.key,
    required this.flags,
    required this.controlsVisible,
    required this.title,
    required this.resolution,
    required this.position,
    required this.duration,
    required this.isLive,
    required this.now,
    required this.bytesPerSecond,
    required this.diagnostics,
    required this.environment,
  });

  final Map<String, bool> flags;

  /// 控制栏是否可见。可见时强制显示时钟、强制隐藏其余
  /// （`docs/phase8/design/02` §4.2）。
  final bool controlsVisible;

  final String title;
  final String? resolution;
  final Duration position;
  final Duration duration;
  final bool isLive;
  final DateTime now;

  /// 下右网速（字节/秒）；null 表示取不到，显示 `—`。
  ///
  /// 由调用方（`player_page.dart` 的屏显刷新循环）采样后传入，
  /// 本层不做 IO：屏显层是纯渲染层（见文件头「职责边界」）。
  final double? bytesPerSecond;
  final List<OsdDiagnosticsRow> diagnostics;
  final List<OsdDiagnosticsRow> environment;

  /// 控制栏可见时，时钟**无视开关**强制显示。
  ///
  /// 为什么只强制时钟而不强制标题（与上游的差异）：PC 顶栏已经显示了
  /// `vodName · episodeName`，再显示一遍是噪音。
  /// 详见 `docs/phase8/design/05` §7 第 3 条。
  bool get _clockVisible => controlsVisible || (flags[OsdFlag.time] ?? false);

  bool get _titleVisible => !controlsVisible && (flags[OsdFlag.title] ?? false);

  bool get _sizeVisible => !controlsVisible && (flags[OsdFlag.size] ?? false);

  /// 上左：标题 + 分辨率（分辨率缺失时只显示标题一行，§3.1）。
  ///
  /// **必须把「有内容可显示」也算进来**：`size` 开而 `title` 关、且
  /// `resolution == null` 时，两段都为空 → `join('\n')` 得到空串 →
  /// 会渲染一个 `data == ''` 的 `Text`。那违反全站「`.data` 非空」的约束
  /// （`Text.rich` 会在遍历 `allWidgets` 取 `.data` 的测试里静默消失，
  /// 空串虽非 null 但同样是无内容占位）。
  bool get _cornerTopLeftVisible =>
      (_titleVisible && title.isNotEmpty) ||
      (_sizeVisible && (resolution?.isNotEmpty ?? false));

  /// 进度：控制栏可见时强制隐藏；直播或时长未知时也隐藏。
  bool get _progressVisible =>
      !controlsVisible &&
      (flags[OsdFlag.progress] ?? false) &&
      !isLive &&
      duration > Duration.zero;

  /// 下右网速：控制栏可见时强制隐藏（与其余各项一致，§4.2）。
  ///
  /// **直播不隐藏**：直播恰恰是最需要看网速的场景（缓冲/掉帧时
  /// 用户要判断是网络还是源）。开关是唯一判据。
  bool get _trafficVisible =>
      !controlsVisible && (flags[OsdFlag.traffic] ?? false);

  /// 迷你进度条：控制栏可见时强制隐藏；直播或时长未知时也隐藏。
  bool get _miniVisible =>
      !controlsVisible &&
      (flags[OsdFlag.mini] ?? false) &&
      !isLive &&
      duration > Duration.zero;

  /// 诊断面板：控制栏可见时强制隐藏。
  ///
  /// `diagnostics.isNotEmpty` 是防御性判据：`buildOsdDiagnostics` 至少返回
  /// **5** 行（视频/音频/网络/状态/播放是无条件的），最多 7 行
  /// （结论与来源是条件行，见 `osd_diagnostics.dart:120,126`）；
  /// 但**空面板**（只有附加列或什么都没有）是比不显示更糟的噪音。
  bool get _diagnosticsVisible =>
      !controlsVisible &&
      (flags[OsdFlag.diagnostics] ?? false) &&
      diagnostics.isNotEmpty;

  String _clockText() {
    String two(int number) => number.toString().padLeft(2, '0');
    return '${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
  }

  double get _miniProgress => duration.inMilliseconds <= 0
      ? 0
      : (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Stack(
        children: [
          Padding(
            // 内边距用 AppSpace.lg（16px）而不是上游的 14dp：
            // 14 会成为全站第 17 个间距值（`docs/phase8/design/02` §3.4）。
            padding: const EdgeInsets.all(AppSpace.lg),
            // 竖排而不是「四个 `Positioned` 各占一角」：
            // - 诊断面板也贴顶，若与上左标题都 `top: 0`，两段文字会**互相叠印**
            //   （标题 14px 两行压在「结论」行上）；排在标题之下则不重叠；
            // - 标题与时钟之间不需要写死 96px 空档（那会引入 `AppSpace` 之外的
            //   散值），`Row` 让标题自己量出剩余宽度并用省略号收尾。
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_cornerTopLeftVisible || _clockVisible)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: _cornerTopLeftVisible
                            ? Text(
                                [
                                  if (_titleVisible) title,
                                  if (_sizeVisible && resolution != null)
                                    resolution!,
                                ].join('\n'),
                                style: _osdTextStyle(),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              )
                            : const SizedBox.shrink(),
                      ),
                      if (_clockVisible) ...[
                        const SizedBox(width: AppSpace.xl),
                        Text(_clockText(), style: _osdTextStyle()),
                      ],
                    ],
                  ),
                if (_diagnosticsVisible)
                  Padding(
                    padding: const EdgeInsets.only(top: AppSpace.sm),
                    child: _DiagnosticsPanel(
                      rows: diagnostics,
                      environment: environment,
                    ),
                  ),
                const Spacer(),
                // 底部一行：下左进度 + 下右网速（§3.5、§3.6）。
                //
                // 两段各自独立判据，左右分置：竖排的其余各行都贴左，
                // 只有这一行是左右两端各一段。
                //
                // **两个分支都要占住剩余宽度**，否则「只开网速、关进度」时
                // 网速会贴到左缘——那正是 `Expanded` 缺席、`Row` 里没有弹性
                // 子项时的排法。所以进度不可见时补一个 `Spacer`。
                if (_progressVisible || _trafficVisible)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      if (_progressVisible)
                        Expanded(
                          child: Text(
                            '${_formatDuration(position)} / '
                            '${_formatDuration(duration)}',
                            style: _osdTextStyle(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        )
                      else
                        const Spacer(),
                      if (_trafficVisible) ...[
                        const SizedBox(width: AppSpace.md),
                        Text(
                          formatByteRate(bytesPerSecond),
                          style: _osdTextStyle(),
                          maxLines: 1,
                        ),
                      ],
                    ],
                  ),
              ],
            ),
          ),
          // 迷你进度条**在 Padding 之外**：§3.4 的例外——它贴底、无内边距。
          //
          // 不能靠 `Positioned(left: -16, ...)` 把内层 Stack 顶出去取巧：
          // `Stack` 默认 `Clip.hardEdge`，负偏移只会被裁掉——实测那种写法下
          // 整条落在内层裁剪框之外，画面上**什么都看不到**。
          if (_miniVisible)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: PlayerOsdMiniProgress(progress: _miniProgress),
            ),
        ],
      ),
    );
  }
}

/// 诊断面板：主列 + 附加列（`docs/phase8/design/02` §3.2）。
///
/// 与上游同构：主列权重 1.25、附加列权重 1；上游 `view_player_osd.xml:108,127`。
///
/// 每一行由**两个 `Text`**（标签、取值）组成，而不是拼成一条字符串：
/// - 两列各自用 `Table` 的 `IntrinsicColumnWidth` 对齐标签，标签宽度由数据量出，
///   不写死像素（写死值会引入 `AppSpace` 之外的新散值）；
/// - 拼成一条字符串时标签与取值之间没有可对齐的边界，多行看起来是锯齿。
class _DiagnosticsPanel extends StatelessWidget {
  const _DiagnosticsPanel({required this.rows, required this.environment});

  final List<OsdDiagnosticsRow> rows;
  final List<OsdDiagnosticsRow> environment;

  @override
  Widget build(BuildContext context) {
    // 诊断面板是密集信息：字号压到 10，等宽字体。
    //
    // 上游的取值分两处：XML 默认 **9sp**（`view_player_osd.xml:118`），
    // 运行时按横竖屏夹取 **10.2sp / 8.0sp**
    // （`PlayerOsdController.java:343-347` 的 `land ? 10.2f : 8.0f`）。
    // 本层取 10，落在两者之间，且是「小字号 + 等宽」这一意图的实现。
    //
    // 注：安卓的 `textScaleX`（横向压字，`view_player_osd.xml:117,139` 的 0.92/0.96）
    // 在 Flutter 的 `TextStyle` 里没有对应字段（只有 `letterSpacing`），
    // 用 `letterSpacing` 近似会改变**字距**语义而非压缩**字形宽度**，属于伪造；
    // 因此本层不压字宽，靠 `maxLines` 与省略号兜底。
    const style = TextStyle(
      fontSize: 10,
      height: 1.35,
      color: Colors.white,
      fontFamily: 'monospace',
      shadows: [
        Shadow(color: Colors.black, offset: Offset(1.2, 1.2), blurRadius: 1.5),
      ],
    );
    Widget table(List<OsdDiagnosticsRow> data) => Table(
      columnWidths: const {
        0: IntrinsicColumnWidth(),
        1: FlexColumnWidth(),
      },
      children: [
        for (final row in data)
          TableRow(
            children: [
              Padding(
                padding: const EdgeInsets.only(right: AppSpace.sm),
                child: Text(row.label, style: style),
              ),
              Text(row.value, style: style),
            ],
          ),
      ],
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(flex: 125, child: table(rows)),
        if (environment.isNotEmpty) ...[
          const SizedBox(width: AppSpace.sm),
          Expanded(flex: 100, child: table(environment)),
        ],
      ],
    );
  }
}

/// 底部 2dp 迷你进度条（`docs/phase8/design/02` §3.3）。
///
/// 颜色用星等琥珀：`DESIGN.md` 的 The One Accent Rule 明确把「进度条」
/// 列为琥珀的合法用途之一。
class PlayerOsdMiniProgress extends StatelessWidget {
  const PlayerOsdMiniProgress({super.key, required this.progress});

  final double progress;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 2,
      child: Align(
        alignment: Alignment.centerLeft,
        child: FractionallySizedBox(
          widthFactor: progress.clamp(0.0, 1.0),
          child: Container(color: context.semanticColors.magnitude),
        ),
      ),
    );
  }
}
