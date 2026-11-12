/// 窗口形态（全屏 / 窗口态）的唯一入口。
///
/// 为什么单独成文件：全屏是**窗口级**副作用，退出它的时机却不只属于
/// 播放器页（返回、路由被替换、页面销毁、全局 Esc）。把「进入」与「恢复」
/// 收在一处，才能保证任何退出路径都成对收尾——window_manager 的
/// setFullScreen(true) 会去边框铺满显示器；漏掉一次恢复，用户就再也
/// 看不到标题栏按钮，也关不掉窗口。
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

/// 进入全屏：先隐藏标题栏，再铺满。
///
/// 顺序不能反：Windows 上 window_manager 的铺满分支只在标题栏样式已切到
/// hidden 时执行（见 test/phase8_player_fullscreen_test.dart 的调用序列断言）。
/// 这里**不能**调 setAsFrameless：它会把插件内的 is_frameless_ 置 true，
/// 铺满分支整体被跳过，窗口停在原尺寸只是变成无边框小窗。
Future<void> enterPlayerFullscreen() async {
  await windowManager.setTitleBarStyle(
    TitleBarStyle.hidden,
    windowButtonVisibility: false,
  );
  await windowManager.setFullScreen(true);
  await windowManager.focus();
}

/// 恢复「窗口态」：退出原生全屏，并保证标题栏与最小化/最大化/关闭按钮回来。
///
/// 幂等：已经处于窗口态时只做标题栏兜底。平台调用失败不向上抛——调用点可能
/// 是 dispose()，那里没有 UI 可以报错，也绝不能让一次恢复失败挡住其余清理。
Future<void> restoreWindowedMode() async {
  try {
    if (await windowManager.isFullScreen()) {
      await windowManager.setFullScreen(false);
    }
  } catch (error) {
    debugPrint('恢复窗口态失败（setFullScreen）：$error');
  } finally {
    await restoreWindowTitleBar();
  }
}

/// 只恢复标题栏与窗口按钮，不碰全屏标志。
///
/// 用于「窗口已从别处退出全屏」的场景：window_manager 的
/// onWindowLeaveFullScreen 只通知状态变化，不会替调用方把
/// TitleBarStyle.hidden 改回来。
Future<void> restoreWindowTitleBar() async {
  try {
    await windowManager.setTitleBarStyle(
      TitleBarStyle.normal,
      windowButtonVisibility: true,
    );
  } catch (error) {
    debugPrint('恢复标题栏失败：$error');
  }
}

/// 当前是全屏才退出；否则不产生任何平台调用。
Future<void> exitFullscreenIfNeeded() async {
  try {
    if (!await windowManager.isFullScreen()) return;
  } catch (error) {
    debugPrint('查询全屏状态失败：$error');
    return;
  }
  await restoreWindowedMode();
}

/// 应用壳层的全屏逃生口：任何页面按 Esc 退出全屏、F11 切换全屏。
///
/// 为什么挂在 Navigator 之上：键盘事件从主焦点沿祖先冒泡，播放器/菜单/
/// 对话框自己的 Esc 会先被消费；这里只兜住「页面已经 pop、全屏却没恢复」
/// 这类没有页面负责的残局。
///
/// 只有**当前确实处于全屏**时才消费 Esc；窗口态下返回 ignored，把 Esc
/// 留给对话框/菜单等默认的 DismissIntent——否则这个兜底会把所有页面的
/// Esc 都吞掉。
class WindowEscapeShortcuts extends StatefulWidget {
  const WindowEscapeShortcuts({super.key, required this.child});

  final Widget child;

  @override
  State<WindowEscapeShortcuts> createState() => _WindowEscapeShortcutsState();
}

class _WindowEscapeShortcutsState extends State<WindowEscapeShortcuts>
    with WindowListener {
  bool _fullscreen = false;
  bool _exiting = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    // 启动参数 / 上一帧的窗口状态可能已经是全屏，先回读一次。
    unawaited(_syncFullscreen());
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  Future<void> _syncFullscreen() async {
    try {
      final value = await windowManager.isFullScreen();
      if (!mounted || value == _fullscreen) return;
      setState(() => _fullscreen = value);
    } catch (error) {
      debugPrint('查询全屏状态失败：$error');
    }
  }

  @override
  void onWindowEnterFullScreen() {
    if (!mounted) return;
    setState(() => _fullscreen = true);
  }

  @override
  void onWindowLeaveFullScreen() {
    if (!mounted) return;
    setState(() => _fullscreen = false);
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (!_fullscreen || _exiting) return KeyEventResult.ignored;
      _exiting = true;
      unawaited(_exit());
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.f11) {
      unawaited(_toggleFromShell());
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _exit() async {
    await exitFullscreenIfNeeded();
    _exiting = false;
  }

  Future<void> _toggleFromShell() async {
    try {
      if (await windowManager.isFullScreen()) {
        await restoreWindowedMode();
      } else {
        await enterPlayerFullscreen();
      }
    } catch (error) {
      debugPrint('全局全屏切换失败：$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onKeyEvent,
      child: widget.child,
    );
  }
}
