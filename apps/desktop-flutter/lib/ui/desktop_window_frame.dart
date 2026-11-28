import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'glass_widgets.dart';
import 'tokens.dart';
import 'window_mode.dart';

/// Places the desktop caption outside the Navigator without replacing its state.
class DesktopWindowFrame extends StatefulWidget {
  const DesktopWindowFrame({super.key, required this.child});

  final Widget child;

  @override
  State<DesktopWindowFrame> createState() => _DesktopWindowFrameState();
}

class _DesktopWindowFrameState extends State<DesktopWindowFrame>
    with WindowListener {
  final _minimizeFocus = FocusNode();
  final _captionFocus = FocusScopeNode();
  FocusNode? _previousFocus;
  bool _fullscreen = false;
  bool _maximized = false;
  int _fullscreenRead = 0;
  bool _receivedMaximizeEvent = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    fullscreenCommandRevision.addListener(_readFullscreen);
    _readFullscreen();
    unawaited(_readInitialMaximized());
  }

  @override
  void dispose() {
    fullscreenCommandRevision.removeListener(_readFullscreen);
    windowManager.removeListener(this);
    _minimizeFocus.dispose();
    _captionFocus.dispose();
    super.dispose();
  }

  void _readFullscreen() {
    final read = ++_fullscreenRead;
    unawaited(
      _tryWindowCommand(() async {
        final fullscreen = await windowManager.isFullScreen();
        if (mounted && read == _fullscreenRead) _setFullscreen(fullscreen);
      }),
    );
  }

  Future<void> _readInitialMaximized() => _tryWindowCommand(() async {
    final maximized = await windowManager.isMaximized();
    if (mounted && !_receivedMaximizeEvent) _setMaximized(maximized);
  });

  void _setFullscreen(bool fullscreen) {
    if (_fullscreen != fullscreen) setState(() => _fullscreen = fullscreen);
  }

  void _setMaximized(bool maximized) {
    if (_maximized != maximized) setState(() => _maximized = maximized);
  }

  @override
  void onWindowEnterFullScreen() {
    _fullscreenRead++;
    _setFullscreen(true);
  }

  @override
  void onWindowLeaveFullScreen() {
    _fullscreenRead++;
    _setFullscreen(false);
  }

  @override
  void onWindowMaximize() {
    _receivedMaximizeEvent = true;
    _setMaximized(true);
  }

  @override
  void onWindowUnmaximize() {
    _receivedMaximizeEvent = true;
    _setMaximized(false);
  }

  Future<void> _tryWindowCommand(Future<void> Function() command) async {
    try {
      await command();
    } on MissingPluginException {
      // Embeddings without desktop window controls keep rendering the app.
    } on PlatformException {
      // A window manager can reject operations unsupported in its current state.
    }
  }

  void _run(Future<void> Function() command) {
    if (!_fullscreen) unawaited(_tryWindowCommand(command));
  }

  void _toggleMaximize() =>
      _run(_maximized ? windowManager.unmaximize : windowManager.maximize);

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (_fullscreen ||
        event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.f6) {
      return KeyEventResult.ignored;
    }
    if (_captionFocus.hasFocus) {
      if (_previousFocus?.context != null) {
        _previousFocus!.requestFocus();
      } else {
        _captionFocus.unfocus(
          disposition: UnfocusDisposition.previouslyFocusedChild,
        );
      }
      _previousFocus = null;
    } else {
      _previousFocus = FocusManager.instance.primaryFocus;
      _minimizeFocus.requestFocus();
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      onKeyEvent: _onKeyEvent,
      child: Overlay.wrap(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!_fullscreen)
              FocusScope(node: _captionFocus, child: _buildCaption(context)),
            Expanded(child: widget.child),
          ],
        ),
      ),
    );
  }

  Widget _buildCaption(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return GlassPane(
      borderRadius: BorderRadius.zero,
      blurBackdrop: false,
      showRim: false,
      child: Material(
        type: MaterialType.transparency,
        child: Row(
          children: [
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                excludeFromSemantics: true,
                onPanStart: (_) => _run(windowManager.startDragging),
                onDoubleTap: _toggleMaximize,
                onSecondaryTapUp: (_) => _run(windowManager.popUpWindowMenu),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 44),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpace.lg,
                      vertical: AppSpace.sm,
                    ),
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: Text(
                        'WebHTV PC',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: colors.onSurface,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            _button(
              '最小化',
              Icons.remove,
              () => _run(windowManager.minimize),
              focusNode: _minimizeFocus,
            ),
            _button(
              _maximized ? '还原' : '最大化',
              _maximized ? Icons.filter_none : Icons.crop_square,
              _toggleMaximize,
            ),
            _button(
              '关闭',
              Icons.close,
              () => _run(windowManager.close),
              style: ButtonStyle(
                overlayColor: WidgetStateProperty.resolveWith((states) {
                  if (states.contains(WidgetState.focused) ||
                      states.contains(WidgetState.hovered) ||
                      states.contains(WidgetState.pressed)) {
                    return colors.error.withValues(alpha: .18);
                  }
                  return null;
                }),
              ),
            ),
            const SizedBox(width: AppSpace.xs),
          ],
        ),
      ),
    );
  }

  Widget _button(
    String tooltip,
    IconData icon,
    VoidCallback onPressed, {
    ButtonStyle? style,
    FocusNode? focusNode,
  }) {
    return IconButton(
      tooltip: tooltip,
      iconSize: 18,
      focusNode: focusNode,
      onPressed: onPressed,
      style: style,
      icon: Icon(icon),
    );
  }
}
