/// 全局浮动通知（toast）。
///
/// 为什么需要它：改造前「错误 / 通知 / 详情错误」三条通道各页面自己拼横幅
/// （`ErrorBanner` 实底红块、`_NoticeBanner` 淡底发丝线），横幅插在内容流里，
/// 于是同一条提示在不同页面上高度不同、会把列表往下顶、详情页叠在浏览页之上时
/// 两条横幅还会同时出现。这里把它们收成**一个浮在所有路由与对话框之上的角标栈**：
/// 右下角、从下往上堆叠、带一条倒计时进度条。
///
/// 层级沿用既有的视觉语言（见 `browse_pages.dart` 的 `_NoticeBanner` 注释）：
/// **错误是实底 `errorContainer`，信息/成功是 `surfaceContainerHigh` + 发丝边**。
/// 通知是"信息"，不是"警报"，两者的重量必须能一眼分开。
library;

import 'package:flutter/material.dart';

import 'tokens.dart';

// ---------------------------------------------------------------------------
// 类型
// ---------------------------------------------------------------------------

/// 通知的语义类型。
enum ToastKind {
  /// 中性信息。
  info,

  /// 操作成功。
  success,

  /// 出错：驻留时间最长（见 [kToastErrorDuration]），但仍会自己让开右下角。
  error,
}

/// info / success 通知的默认驻留时长（约 4 秒）。
const Duration kToastDefaultDuration = Duration(seconds: 4);

/// 错误通知的默认驻留时长：15 秒。
///
/// 为什么是 15 秒而不是 4 秒 / 永不关闭：
/// - 4 秒读不完一条带错误码的失败原因，用户只能去日志里翻；
/// - 但「永不关闭」已被证伪——常驻的错误通知**物理压住**了右下角的集数卡片网格
///   和换源浮层的「并入」按钮，它们是右下角唯一的点击目标，被盖住就等于功能不可用
///   （相关测试只能先 `dismissAllToasts()` 再点，等于要求用户先手动收提示）。
/// 15 秒是这两端之间取的值：足够读完一整条错误，又不至于一直占着那个角。
///
/// 注意这**不改变** [AppToast.duration] 的契约：`Duration.zero` 依旧是「永不自动关闭」，
/// 只是错误类型不再取到 zero 这个默认值。
const Duration kToastErrorDuration = Duration(seconds: 15);

/// 可见栈上限。超出时丢弃**最旧**的一条：新的通知永远离用户最近。
const int kToastMaxVisible = 4;

/// 通知卡片的最大宽度。
///
/// 固定量级（320-360）：长消息换行，而不是把卡片拉成一条横贯屏幕的横幅——
/// 右下角的窄卡才是通知的形状。
const double kToastMaxWidth = 336;

/// 卡片距屏幕右/下边缘的留白（安全区在它之上再加）。
const double kToastInset = AppSpace.xl;

/// 倒计时进度条高度。
const double _kProgressBarHeight = 3;

/// 入场位移幅度（占卡片高度的比例）：从下方轻微上浮，不做弹跳。
const double _kSlideFraction = 0.08;

/// 关闭按钮的点击区：默认尺寸会把紧凑的通知卡撑大。
const double _kCloseButtonSize = 26;

// ---------------------------------------------------------------------------
// 数据
// ---------------------------------------------------------------------------

/// 通知里的一条动作（例如「换源」）。
///
/// 为什么动作属于通知：错误文案里常写着「请刷新重试或换源」，而那个「换源」
/// 在界面上本不存在——提示必须能就地被执行，否则等于空话。
class AppToastAction {
  const AppToastAction({
    required this.label,
    required this.onPressed,
    this.icon,
    this.key,
  });

  /// 按钮文字。
  final String label;

  /// 点击回调。
  final VoidCallback onPressed;

  /// 可选图标。
  final IconData? icon;

  /// 可选 widget key。
  ///
  /// 为什么动作要能带 key：详情页的「换源」按钮有既有的测试契约
  /// （`ValueKey('detail-swap-source')`，跨 5 个测试文件按 key 定位）。通知把
  /// 这个按钮从页面搬进了浮层，但**契约不能跟着搬家**——否则测试要么改成
  /// 按文案匹配（同屏可能有多处「换源」），要么整批失效。
  final Key? key;
}

/// 一条浮动通知。
@immutable
class AppToast {
  const AppToast({
    required this.id,
    required this.message,
    this.detail,
    this.kind = ToastKind.info,
    this.action,
    this.duration = kToastDefaultDuration,
    this.onDismiss,
  });

  /// 进程内自增标识。既用于渲染的 `ValueKey`，也用于 [ToastCenter.dismiss]。
  final int id;

  /// 主文案。
  final String message;

  /// 次要说明（例如 `错误码：network`）。用该通知自身的色相染色，不是灰。
  final String? detail;

  /// 语义类型。
  final ToastKind kind;

  /// 可选动作按钮，渲染在正文与详情**之下**。
  final AppToastAction? action;

  /// 驻留时长；[Duration.zero] 表示**永不自动关闭**（这个契约独立于类型默认值，
  /// 调用方仍可用它把某条通知钉在屏幕上）。
  final Duration duration;

  /// 被**计时器超时**或**关闭按钮**收走时调用。
  ///
  /// 动作按钮不算：用户点的是「去做这件事」，不是「关掉这条提示」，
  /// 提前触发会让状态层把错误清掉、动作却还等着被人看见。
  final VoidCallback? onDismiss;
}

// ---------------------------------------------------------------------------
// 中心
// ---------------------------------------------------------------------------

/// 通知中心：一个进程级的队列 + 变更通知。
///
/// 形态对齐既有的 `ScaffoldMessenger` 用法（全局可达、无需 context），
/// 但把它放在一个独立的 [ChangeNotifier] 上，这样页面代码不必依赖 `AppState`。
class ToastCenter extends ChangeNotifier {
  final List<AppToast> _toasts = <AppToast>[];
  int _nextId = 1;

  /// 当前可见的通知，**从旧到新**。
  ///
  /// 渲染时最后一个离底边最近（新的在下、旧的向上堆），所以顺序即堆叠顺序。
  List<AppToast> get toasts => List<AppToast>.unmodifiable(_toasts);

  /// 推入一条通知，返回它的 id。
  ///
  /// [duration] 为 null 时按类型取默认值：info/success 约 4 秒，error 15 秒
  /// （为什么不是永不关闭，见 [kToastErrorDuration]）。
  int show(
    String message, {
    ToastKind kind = ToastKind.info,
    String? detail,
    AppToastAction? action,
    Duration? duration,
    VoidCallback? onDismiss,
  }) {
    final toast = AppToast(
      id: _nextId++,
      message: message,
      detail: detail,
      kind: kind,
      action: action,
      duration: duration ??
          (kind == ToastKind.error
              ? kToastErrorDuration
              : kToastDefaultDuration),
      onDismiss: onDismiss,
    );
    _toasts.add(toast);
    final dropped = <AppToast>[];
    while (_toasts.length > kToastMaxVisible) {
      dropped.add(_toasts.removeAt(0));
    }
    notifyListeners();
    // 被挤出栈的那条：它在界面上已经不存在了，状态层的对应字段也必须收走，
    // 否则"横幅没了但错误还在"的旧问题会以另一种形式回来。
    for (final toast in dropped) {
      toast.onDismiss?.call();
    }
    return toast.id;
  }

  /// 关掉一条通知；会触发它自己的 [AppToast.onDismiss]。
  void dismiss(int id) => _remove(id, notifyDismissal: true);

  /// 全部关掉；每条都会触发自己的 [AppToast.onDismiss]。
  void dismissAll() {
    if (_toasts.isEmpty) return;
    final closing = List<AppToast>.of(_toasts);
    _toasts.clear();
    notifyListeners();
    for (final toast in closing) {
      toast.onDismiss?.call();
    }
  }

  /// 内部移除。[notifyDismissal] 为 false 的情形只有一种：动作按钮
  /// （见 [AppToast.onDismiss] 的注释）。
  void _remove(int id, {required bool notifyDismissal}) {
    final index = _toasts.indexWhere((toast) => toast.id == id);
    if (index < 0) return;
    final removed = _toasts.removeAt(index);
    notifyListeners();
    if (notifyDismissal) removed.onDismiss?.call();
  }
}

final ToastCenter _toastCenter = ToastCenter();

/// 全局通知中心，形态对齐既有代码里的 `ScaffoldMessenger.of(context)`。
ToastCenter get toastCenter => _toastCenter;

/// 推入一条通知；返回值可直接交给 [dismissToast]。
int showToast(
  String message, {
  ToastKind kind = ToastKind.info,
  String? detail,
  AppToastAction? action,
  Duration? duration,
  VoidCallback? onDismiss,
}) {
  return toastCenter.show(
    message,
    kind: kind,
    detail: detail,
    action: action,
    duration: duration,
    onDismiss: onDismiss,
  );
}

/// 关掉一条通知。
void dismissToast(int id) => toastCenter.dismiss(id);

/// 关掉全部通知。
void dismissAllToasts() => toastCenter.dismissAll();

// ---------------------------------------------------------------------------
// 渲染
// ---------------------------------------------------------------------------

/// 通知的渲染宿主。
///
/// **全局只能挂一次**，且要挂在 `MaterialApp.builder` 那种位于 `Navigator` 之上
/// 的位置，这样所有路由与 `showDialog`/`showModalBottomSheet` 都盖不住它。
///
/// 布局取右下角 `Align`：宿主自身（以及它外面的 `Padding`）不吸收指针事件，
/// 只有真正画出来的卡片吸收。于是通知之间的空隙、以及卡片左侧的整片区域，
/// 点击依然落到下面的页面上——"浮在上面"不等于"挡住操作"。
class ToastHost extends StatelessWidget {
  const ToastHost({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      key: const ValueKey('toast-host'),
      listenable: toastCenter,
      builder: (context, _) {
        final toasts = toastCenter.toasts;
        if (toasts.isEmpty) return const SizedBox.shrink();
        final media = MediaQuery.of(context);
        return Padding(
          // 安全区叠在固定留白之上：窗口贴边时通知不能被任务栏切掉。
          padding: EdgeInsets.fromLTRB(
            AppSpace.lg,
            AppSpace.lg,
            kToastInset + media.padding.right,
            kToastInset + media.padding.bottom,
          ),
          child: Align(
            alignment: Alignment.bottomRight,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final toast in toasts)
                  Padding(
                    padding: const EdgeInsets.only(top: AppSpace.sm),
                    child: _ToastCard(
                      // 必须按 id 打 key：丢弃最旧的一条时，若按位置复用 Element，
                      // 倒计时控制器会跟着"位置"而不是"这条通知"，倒计时就错位了。
                      key: ValueKey('app-toast-${toast.id}'),
                      toast: toast,
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ToastCard extends StatefulWidget {
  const _ToastCard({super.key, required this.toast});

  final AppToast toast;

  @override
  State<_ToastCard> createState() => _ToastCardState();
}

class _ToastCardState extends State<_ToastCard> with TickerProviderStateMixin {
  /// 入场/退场（淡入 + 上浮）。退场复用它反向播放。
  late final AnimationController _visual;
  late final CurvedAnimation _curve;

  /// 倒计时。`null`（即 `duration == Duration.zero`）表示这条通知永不自动关闭；
  /// 三种类型现在都有正的默认时长，所以默认路径下 `null` 不会出现。
  AnimationController? _countdown;

  bool _exiting = false;

  @override
  void initState() {
    super.initState();
    _visual = AnimationController(
      vsync: this,
      duration: AppMotion.base,
      value: 0,
    );
    _curve = CurvedAnimation(parent: _visual, curve: AppMotion.ease);
    _visual.forward();
    final duration = widget.toast.duration;
    if (duration > Duration.zero) {
      final controller = AnimationController(vsync: this, duration: duration);
      controller.addStatusListener(_onCountdownStatus);
      _countdown = controller..forward();
    }
  }

  @override
  void dispose() {
    _countdown?.dispose();
    _curve.dispose();
    _visual.dispose();
    super.dispose();
  }

  void _onCountdownStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      _beginExit(notifyDismissal: true);
    }
  }

  /// 悬停：暂停倒计时（进度条一起停，它们共用同一个控制器）。
  void _pauseCountdown() => _countdown?.stop();

  /// 离开：从停下的位置继续，剩余时间不变。
  void _resumeCountdown() {
    if (_exiting) return;
    _countdown?.forward();
  }

  /// 先播退场再移除，而不是立刻从列表里拿掉——否则通知会"啪"地消失。
  Future<void> _beginExit({required bool notifyDismissal}) async {
    if (_exiting) return;
    _exiting = true;
    _countdown?.stop();
    await _visual.reverse();
    if (!mounted) return;
    toastCenter._remove(widget.toast.id, notifyDismissal: notifyDismissal);
  }

  void _fireAction() {
    final action = widget.toast.action;
    if (action == null) return;
    // 动作按钮不是"关掉它"：按 onDismiss 的约定，这条路径不触发回调。
    _beginExit(notifyDismissal: false);
    action.onPressed();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final toast = widget.toast;
    final isError = toast.kind == ToastKind.error;
    final semantic = context.semanticColors;

    // 错误 = 实底 errorContainer；信息/成功 = 浅底 + 发丝边（层级更低一档）。
    final surface = isError
        ? scheme.errorContainer
        : scheme.surfaceContainerHigh;
    final ink = isError ? scheme.onErrorContainer : scheme.onSurface;
    // 彩色表面上的次级文字必须从该色相染色，不能用底色的墨。
    final muted = isError
        ? scheme.onErrorContainer.withValues(alpha: 0.72)
        : scheme.onSurfaceVariant;
    final icon = switch (toast.kind) {
      ToastKind.info => Icons.info_outline,
      ToastKind.success => Icons.check_circle_outline,
      ToastKind.error => Icons.error_outline,
    };
    final iconColor = switch (toast.kind) {
      ToastKind.info => scheme.onSurfaceVariant,
      ToastKind.success => semantic.statusOk,
      ToastKind.error => scheme.onErrorContainer,
    };
    final barColor = toast.kind == ToastKind.success
        ? semantic.statusOk
        : scheme.primary;
    final countdown = _countdown;
    // 有进度条时底部留白收窄：进度条自己占掉了那一条底边。
    final contentPadding = EdgeInsets.fromLTRB(
      AppSpace.md,
      AppSpace.md,
      AppSpace.xs,
      countdown == null ? AppSpace.md : AppSpace.sm,
    );

    return FadeTransition(
      opacity: _curve,
      // 上浮入场：从下往上一点点，不做弹跳（AppMotion 的缓动本身是指数缓出）。
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, _kSlideFraction),
          end: Offset.zero,
        ).animate(_curve),
        child: MouseRegion(
          onEnter: (_) => _pauseCountdown(),
          onExit: (_) => _resumeCountdown(),
          child: Semantics(
            container: true,
            liveRegion: true,
            child: Container(
              width: kToastMaxWidth,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: surface,
                borderRadius: AppRadius.mdAll,
                border: isError
                    ? null
                    : Border.all(
                        color: scheme.outlineVariant.withValues(alpha: 0.6),
                      ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: contentPadding,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(icon, size: AppSpace.lg, color: iconColor),
                        const SizedBox(width: AppSpace.sm),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                toast.message,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: ink,
                                ),
                              ),
                              if (toast.detail != null) ...[
                                const SizedBox(height: AppSpace.xs),
                                Text(
                                  toast.detail!,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: muted,
                                  ),
                                ),
                              ],
                              // 动作排在正文与详情之后：先把"怎么了"说完，
                              // 再给"现在做什么"。
                              if (toast.action != null) ...[
                                const SizedBox(height: AppSpace.xs),
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: TextButton.icon(
                                    key: toast.action!.key,
                                    onPressed: _fireAction,
                                    icon: toast.action!.icon == null
                                        ? null
                                        : Icon(
                                            toast.action!.icon,
                                            size: AppSpace.lg,
                                            color: ink,
                                          ),
                                    label: Text(toast.action!.label),
                                    style: TextButton.styleFrom(
                                      foregroundColor: ink,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: AppSpace.sm,
                                      ),
                                      visualDensity: VisualDensity.compact,
                                      textStyle: theme.textTheme.labelLarge,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        IconButton(
                          key: ValueKey('app-toast-close-${toast.id}'),
                          // 这里**不能用 `tooltip:`**：宿主挂在 `MaterialApp.builder`
                          // 里、与 Navigator 平级，因此位于 Overlay **之外**，而
                          // `RawTooltip.build` 无条件断言 `debugCheckHasOverlay`——
                          // 一条 toast 就足以在 debug/profile 构建里抛
                          // `No Overlay widget found`（release 把断言剥掉才看不见）。
                          // 无障碍语义用图标自带的 `semanticLabel` 保住：
                          // Windows 原生通知本来也没有 tooltip。
                          onPressed: () => _beginExit(notifyDismissal: true),
                          icon: const Icon(
                            Icons.close,
                            size: AppSpace.lg,
                            semanticLabel: '关闭提示',
                          ),
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: _kCloseButtonSize,
                            minHeight: _kCloseButtonSize,
                          ),
                          color: muted,
                        ),
                      ],
                    ),
                  ),
                  if (countdown != null)
                    _CountdownBar(controller: countdown, color: barColor),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 底边那条细进度条：从满宽缩到零。
///
/// 重建范围只包住这条 bar——倒计时每帧都会变，整张卡片跟着重建是白烧的。
class _CountdownBar extends StatelessWidget {
  const _CountdownBar({required this.controller, required this.color});

  final AnimationController controller;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: _kProgressBarHeight,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: color.withValues(alpha: 0.18)),
          AnimatedBuilder(
            animation: controller,
            builder: (context, _) => Align(
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: (1 - controller.value).clamp(0.0, 1.0),
                heightFactor: 1,
                child: ColoredBox(color: color),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
