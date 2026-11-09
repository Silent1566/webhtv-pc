import 'package:flutter/material.dart';

import 'common.dart';
import 'tokens.dart';

/// 只覆盖入口的异步准备阶段；导航前 dismiss，所有退出路径 close。
class AsyncActionFeedback {
  AsyncActionFeedback._(this._context, this._route, this._owner);

  static final _pending = Expando<AsyncActionFeedback>();
  final BuildContext _context;
  final ModalRoute<dynamic>? _route;
  final Object _owner;
  OverlayEntry? _entry;
  bool _closed = false;
  bool _watching = true;

  static AsyncActionFeedback? begin(BuildContext context, String message) {
    if (!context.mounted) return null;
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return null;
    final owner = context;
    final previous = _pending[owner];
    if (previous != null && previous.isCurrent) return null;
    final feedback = AsyncActionFeedback._(context, route, owner);
    _pending[owner] = feedback;
    feedback._entry = OverlayEntry(
      builder: (_) => Positioned.fill(
        child: IgnorePointer(
          child: Center(child: _ActionFeedback(message: message)),
        ),
      ),
    );
    Overlay.of(context).insert(feedback._entry!);
    route?.animation?.addListener(feedback._checkOrigin);
    route?.secondaryAnimation?.addListener(feedback._checkOrigin);
    feedback._watchOrigin();
    return feedback;
  }

  bool get isCurrent {
    if (_closed) return false;
    if (!_context.mounted ||
        (_route != null &&
            (!_route.isCurrent ||
                _route.animation?.status == AnimationStatus.reverse))) {
      close();
      return false;
    }
    return true;
  }

  void _checkOrigin() {
    if (_watching) isCurrent;
  }

  // 不主动请求帧，只在应用已有帧后检查同路由内的发起组件是否被卸载。
  void _watchOrigin() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_watching || !isCurrent) return;
      _watchOrigin();
    });
  }

  void dismiss() {
    _watching = false;
    _route?.animation?.removeListener(_checkOrigin);
    _route?.secondaryAnimation?.removeListener(_checkOrigin);
    final entry = _entry;
    _entry = null;
    entry?.remove();
    entry?.dispose();
  }

  void close() {
    if (_closed) return;
    _closed = true;
    dismiss();
    if (identical(_pending[_owner], this)) _pending[_owner] = null;
  }
}

/// 只有一个转圈：不上屏文字、不加底色面板。
///
/// 文案仍留在 [Semantics] 上——屏读要能说出「在准备哪一集」，而这一层
/// 没有视觉负担。转圈沿用全站同一个 [LoadingBlock]（[AppMotion] 不参与，
/// 它是真实的进度指示）。
class _ActionFeedback extends StatelessWidget {
  const _ActionFeedback({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final reduced = media.disableAnimations || media.accessibleNavigation;
    final theme = Theme.of(context);
    return Semantics(
      key: const ValueKey('async-action-feedback'),
      liveRegion: true,
      label: message,
      // 语义在淡入外面：屏读不必等动画，也不被 `Opacity: 0` 抹掉。
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: reduced ? 1 : 0, end: 1),
        duration: reduced ? Duration.zero : AppMotion.fast,
        curve: AppMotion.ease,
        builder: (context, value, child) =>
            Opacity(opacity: value, child: child),
        // 减动态时停掉无限旋转，改成静态沙漏：状态照旧可见。
        child: reduced
            ? Icon(
                Icons.hourglass_top_rounded,
                size: 36,
                color: theme.colorScheme.primary,
              )
            // `center: false`：转圈的盒子就该是转圈本身那么大，否则它会撑满
            // 整屏，语义框与命中区都跟着变成整屏。
            : const LoadingBlock(center: false),
      ),
    );
  }
}
