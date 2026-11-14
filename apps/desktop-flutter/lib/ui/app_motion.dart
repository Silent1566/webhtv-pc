import 'package:flutter/material.dart';

import 'tokens.dart';

bool _reduceMotion(BuildContext context) {
  final media = MediaQuery.maybeOf(context);
  return media != null &&
      (media.disableAnimations || media.accessibleNavigation);
}

/// 桌面三平台的页面过渡（移动端沿用框架默认）。
PageTransitionsTheme appPageTransitionsTheme({bool reducedMotion = false}) {
  // 保持相同偏好的主题相等，避免状态通知反复重建播放器路由。
  final builder = reducedMotion
      ? const AppPageTransitionsBuilder(reducedMotion: true)
      : const AppPageTransitionsBuilder();
  return PageTransitionsTheme(
    builders: {
      ...const PageTransitionsTheme().builders,
      TargetPlatform.windows: builder,
      TargetPlatform.linux: builder,
      TargetPlatform.macOS: builder,
    },
  );
}

/// Navigator 上的稳定作用域：减动态同时去掉绘制动画和路由等待时长。
class AppMotionScope extends StatelessWidget {
  const AppMotionScope({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(
        pageTransitionsTheme: appPageTransitionsTheme(
          reducedMotion: _reduceMotion(context),
        ),
      ),
      child: child,
    );
  }
}

/// 桌面路由只做透明度过渡，不移动或缩放播放器视频表面。
class AppPageTransitionsBuilder extends PageTransitionsBuilder {
  const AppPageTransitionsBuilder({this.reducedMotion = false});

  final bool reducedMotion;

  @override
  Duration get transitionDuration =>
      reducedMotion ? Duration.zero : AppMotion.slow;

  @override
  Duration get reverseTransitionDuration =>
      reducedMotion ? Duration.zero : AppMotion.fast;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final reduced = reducedMotion || _reduceMotion(context);
    return DualTransitionBuilder(
      animation: animation,
      forwardBuilder: (context, animation, child) => FadeTransition(
        opacity: reduced
            ? const AlwaysStoppedAnimation(1.0)
            : animation.drive(
                Tween(
                  begin: 0.4,
                  end: 1.0,
                ).chain(CurveTween(curve: AppMotion.ease)),
              ),
        child: child,
      ),
      reverseBuilder: (context, animation, child) => FadeTransition(
        opacity: reduced
            ? const AlwaysStoppedAnimation(1.0)
            : ReverseAnimation(
                animation.drive(CurveTween(curve: AppMotion.ease)),
              ),
        child: child,
      ),
      child: child,
    );
  }
}

/// 单子树即时替换：离页当帧销毁，只为新页绘制方向性的归位反馈。
class AppShellTransition extends StatefulWidget {
  const AppShellTransition({
    super.key,
    required this.sectionIndex,
    required this.child,
  });

  final int sectionIndex;
  final Widget child;

  @override
  State<AppShellTransition> createState() => _AppShellTransitionState();
}

class _AppShellTransitionState extends State<AppShellTransition>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: AppMotion.base,
    value: 1,
  );
  late final Animation<double> _progress = _controller.drive(
    CurveTween(curve: AppMotion.ease),
  );
  late final Animation<double> _opacity = _progress.drive(
    Tween(begin: 0.72, end: 1.0),
  );
  bool _reducedMotion = false;
  double _direction = 1;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reducedMotion = _reduceMotion(context);
    if (_reducedMotion) _controller.value = 1;
  }

  @override
  void didUpdateWidget(AppShellTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.sectionIndex == oldWidget.sectionIndex) return;
    _direction = widget.sectionIndex > oldWidget.sectionIndex ? 1 : -1;
    if (_reducedMotion) {
      _controller.value = 1;
    } else {
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: AnimatedBuilder(
        animation: _progress,
        child: FadeTransition(
          opacity: _opacity,
          child: KeyedSubtree(
            key: ValueKey(widget.sectionIndex),
            child: widget.child,
          ),
        ),
        builder: (context, child) => Transform.translate(
          offset: Offset(18 * _direction * (1 - _progress.value), 0),
          child: child,
        ),
      ),
    );
  }
}
