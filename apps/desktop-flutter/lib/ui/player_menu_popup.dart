/// Flutter-hosted Windows popup menu. Playback actions stay on the player isolate.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'player_context_menu.dart';
import 'theme.dart';

class PlayerMenuPopup {
  PlayerMenuPopup({required this.onDismiss});

  static const _channel = MethodChannel('webhtv/player_menu_host');
  static bool _enabled = false;
  static bool get enabled => _enabled && Platform.isWindows;

  // Widget and integration fixtures that don't boot the desktop runner use the in-page menu.
  static void enable() => _enabled = true;

  static int _nextSession = 0;
  static PlayerMenuPopup? _active;
  final int _session = ++_nextSession;
  final VoidCallback onDismiss;
  final _shown = Completer<bool>();
  final _actions = <String, VoidCallback>{};
  String? _lastSnapshot;

  Future<bool> show(
    Offset anchor,
    List<PlayerMenuSection> sections, {
    bool reserveFlyoutSpace = true,
    double pixelRatio = 1.0,
  }) async {
    _active?.close();
    _active = this;
    _channel.setMethodCallHandler(_onNativeEvent);
    final snapshot = _snapshot(sections);
    _lastSnapshot = jsonEncode(snapshot);
    if (!await _send('open', {
      'x': anchor.dx * pixelRatio,
      'y': anchor.dy * pixelRatio,
      'reserveFlyoutSpace': reserveFlyoutSpace,
      'sections': snapshot,
    })) {
      close();
      return false;
    }
    return _shown.future.timeout(
      const Duration(seconds: 3),
      onTimeout: () {
        close();
        return false;
      },
    );
  }

  void update(List<PlayerMenuSection> sections) {
    if (_active != this) return;
    final snapshot = _snapshot(sections);
    final key = jsonEncode(snapshot);
    if (key == _lastSnapshot) return;
    _lastSnapshot = key;
    unawaited(_send('update', {'sections': snapshot}));
  }

  void close() {
    if (_active != this) return;
    _active = null;
    if (!_shown.isCompleted) _shown.complete(false);
    unawaited(_send('close'));
  }

  static Future<void> _onNativeEvent(MethodCall call) async {
    final popup = _active;
    final data = call.arguments as Map<Object?, Object?>;
    if (popup == null || data['session'] != popup._session) return;
    switch (call.method) {
      case 'shown':
        if (!popup._shown.isCompleted) popup._shown.complete(true);
      case 'select':
        popup._actions[data['item']]?.call();
      case 'dismiss':
        _active = null;
        if (!popup._shown.isCompleted) popup._shown.complete(false);
        popup.onDismiss();
    }
  }

  Future<bool> _send(
    String method, [
    Map<String, Object?> data = const {},
  ]) async {
    try {
      return await _channel.invokeMethod<bool>(method, {
            'session': _session,
            ...data,
          }) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  List<Object?> _snapshot(List<PlayerMenuSection> sections) {
    _actions.clear();
    Map<String, Object?> encode(PlayerMenuItem item, List<String> parent) {
      final path = [...parent, item.id];
      final actionId = jsonEncode(path);
      final action = item.onSelect;
      if (item.enabled && item.children.isEmpty && action != null) {
        _actions[actionId] = action;
      }
      return {
        'id': item.id,
        'label': item.label,
        'enabled': item.enabled,
        'selected': item.selected,
        if (item.icon case final icon?) 'icon': icon.codePoint,
        if (_actions.containsKey(actionId)) 'action': actionId,
        if (item.children.isNotEmpty)
          'children': [for (final child in item.children) encode(child, path)],
      };
    }

    return [
      for (final section in sections)
        if (section.items.isNotEmpty)
          {
            'title': section.title,
            'items': [
              for (final item in section.items) encode(item, [section.title]),
            ],
          },
    ];
  }
}

void runPlayerMenuPopup() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    MaterialApp(
      theme: buildAppTheme(Brightness.dark),
      home: const _PopupSurface(),
    ),
  );
}

class _PopupSurface extends StatefulWidget {
  const _PopupSurface();

  @override
  State<_PopupSurface> createState() => _PopupSurfaceState();
}

class _PopupSurfaceState extends State<_PopupSurface> {
  static const _channel = MethodChannel('webhtv/player_menu_view');
  int? _session;
  Offset _physicalAnchor = Offset.zero;
  bool _reserveFlyoutSpace = true;
  List<PlayerMenuSection> _sections = const [];
  List<Rect>? _lastBounds;
  double? _lastPixelRatio;

  @override
  void initState() {
    super.initState();
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'snapshot') throw MissingPluginException();
      final data = call.arguments as Map<Object?, Object?>;
      final session = data['session'] as int;
      final sections = data['sections'] as List<Object?>;
      setState(() {
        if (_session != session) _lastBounds = null;
        _session = session;
        _physicalAnchor = Offset(data['x'] as double, data['y'] as double);
        _reserveFlyoutSpace = data['reserveFlyoutSpace'] as bool;
        _sections = [
          for (final entry in sections) _decodeSection(entry as Map),
        ];
      });
    });
    unawaited(_channel.invokeMethod<void>('ready'));
  }

  PlayerMenuSection _decodeSection(Map data) => PlayerMenuSection(
    title: data['title'] as String,
    items: [for (final item in data['items'] as List) _decodeItem(item as Map)],
  );

  PlayerMenuItem _decodeItem(Map data) {
    final session = _session;
    final action = data['action'] as String?;
    return _PopupItem(
      id: data['id'] as String,
      label: data['label'] as String,
      selected: data['selected'] as bool,
      enabled: data['enabled'] as bool,
      iconCode: data['icon'] as int?,
      children: [
        for (final child in data['children'] as List? ?? const [])
          _decodeItem(child as Map),
      ],
      onSelect: action == null
          ? null
          : () => unawaited(
              _channel.invokeMethod<void>('select', {
                'session': session,
                'item': action,
              }),
            ),
    );
  }

  void _updateRegion(List<Rect> bounds) {
    final ratio = View.of(context).devicePixelRatio;
    if (_lastPixelRatio == ratio &&
        _lastBounds != null &&
        _lastBounds!.length == bounds.length &&
        Iterable<int>.generate(bounds.length)
            .every((i) => bounds[i] == _lastBounds![i])) {
      return;
    }
    _lastPixelRatio = ratio;
    _lastBounds = bounds;
    unawaited(
      _channel.invokeMethod<void>('layout', {
        'session': _session,
        'rects': [
          for (final r in bounds)
            [
              (r.left * ratio).round(),
              (r.top * ratio).round(),
              (r.right * ratio).round(),
              (r.bottom * ratio).round(),
            ],
        ],
      }),
    );
  }

  void _dismiss() =>
      unawaited(_channel.invokeMethod<void>('dismiss', {'session': _session}));

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {const SingleActivator(LogicalKeyboardKey.escape): _dismiss},
    child: Focus(
      autofocus: true,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            if (_session != null)
              PlayerContextMenu(
                key: ValueKey(_session),
                // Convert with the same view ratio used for the native hit region.
                anchor: _physicalAnchor / View.of(context).devicePixelRatio,
                viewport: MediaQuery.sizeOf(context),
                sections: _sections,
                onDismiss: _dismiss,
                onColumnBoundsChanged: _updateRegion,
                reserveFlyoutSpace: _reserveFlyoutSpace,
              ),
          ],
        ),
      ),
    ),
  );
}

class _PopupItem extends PlayerMenuItem {
  const _PopupItem({
    required super.id,
    required super.label,
    required super.selected,
    required super.enabled,
    required super.children,
    required super.onSelect,
    required this.iconCode,
  });

  final int? iconCode;

  @override
  Widget? leadingIcon(Color color) {
    final code = iconCode;
    if (code == null) return null;
    // Text uses the same font glyph without constructing non-const IconData in release builds.
    return Text(
      String.fromCharCode(code),
      style: TextStyle(
        inherit: false,
        fontFamily: 'MaterialIcons',
        fontSize: 18,
        height: 1,
        color: color,
      ),
    );
  }
}
