// ignore_for_file: invalid_use_of_protected_member

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:webhtv_pc/core/player_options.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/player_context_menu.dart';
import 'package:webhtv_pc/ui/player_page.dart';
import 'package:webhtv_pc/ui/toast.dart';

import 'live_playback_session_test.dart' show fixture;
import 'support/player_page_harness.dart';

// Replace only the media transport; the page, controller, whitelist/readback
// verification, menu callbacks and preference store remain production code.
class _ControlledNative implements NativePlayer {
  _ControlledNative(this.original) : _state = original.state;
  PlayerState _state;

  @override
  PlayerConfiguration get configuration => original.configuration;
  @override
  PlayerStream get stream => original.stream;
  @override
  PlayerState get state => _state;
  @override
  List<Future<void> Function()> get release => original.release;
  @override
  Completer<void> get videoControllerCompleter =>
      original.videoControllerCompleter;
  @override
  bool get isVideoControllerAttached => original.isVideoControllerAttached;
  @override
  set isVideoControllerAttached(bool value) =>
      original.isVideoControllerAttached = value;

  final PlatformPlayer original;
  final writes = <(String, String)>[];
  final volumes = <double>[];
  final properties = <String, String>{'af': ''};
  Completer<void>? gate;
  Completer<void>? nonAfGate;
  bool rejectEnable = false;
  bool throwEnable = false;
  int active = 0;
  int maxActive = 0;

  @override
  Future<int> get handle => original.handle;

  @override
  Future<void> setProperty(
    String property,
    String value, {
    bool waitForInitialization = true,
  }) async {
    if (property == 'af') {
      writes.add((property, value));
      active++;
      if (active > maxActive) maxActive = active;
      try {
        await gate?.future;
        if (value.isNotEmpty && throwEnable) {
          throw StateError('native af write failed');
        }
        if (value.isNotEmpty && rejectEnable) return;
        properties[property] = value;
      } finally {
        active--;
      }
    } else {
      await nonAfGate?.future;
      properties[property] = value;
    }
  }

  @override
  Future<String> getProperty(
    String property, {
    bool waitForInitialization = true,
  }) async => properties[property] ?? '';

  @override
  Future<void> open(
    Playable playable, {
    bool play = true,
    bool synchronized = true,
  }) async {
    _state = _state.copyWith(
      duration: const Duration(seconds: 100),
      position: const Duration(seconds: 1),
      playing: play,
    );
    original.durationController.add(_state.duration);
    original.positionController.add(_state.position);
    original.playingController.add(play);
  }

  @override
  Future<void> setRate(double rate, {bool synchronized = true}) async {}
  @override
  Future<void> setSubtitleTrack(
    SubtitleTrack track, {
    bool synchronized = true,
  }) async {}

  @override
  Future<void> setVolume(double value, {bool synchronized = true}) async {
    volumes.add(value);
    original.volumeController.add(value);
  }

  @override
  Future<void> dispose({bool synchronized = true}) async {
    await original.dispose();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<({AppState state, _ControlledNative media})> _mount(
  WidgetTester tester, {
  PlayerOptions options = const PlayerOptions(),
  PlayerPage? livePage,
}) async {
  late AppState state;
  late _ControlledNative media;
  var active = true;
  final seen = <Player>{};
  addTearDown(() => active = false);
  tester.binding.addPersistentFrameCallback((_) {
    if (!active || find.byType(Video).evaluate().isEmpty) return;
    final player = tester.widget<Video>(find.byType(Video)).controller.player;
    if (!seen.add(player)) return;
    media = _ControlledNative(player.platform!);
    player.platform = media;
  });
  if (livePage == null) {
    await pumpPlayerPage(
      tester,
      onStateReady: (s) async {
        state = s;
        await s.setPlayerOptions(options);
      },
    );
  } else {
    state = livePage.state;
    await tester.runAsync(() async {
      await state.bootstrap();
      await state.setPlayerOptions(options);
    });
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    installMediaKitMocks(tester);
    installWindowManagerMocks(tester);
    await tester.pumpWidget(MaterialApp(home: livePage));
    await settlePlayerPage(tester);
  }
  await _flush(tester);
  media.writes.clear();
  media.volumes.clear();
  dismissAllToasts();
  addTearDown(dismissAllToasts);
  return (state: state, media: media);
}

Future<void> _flush(WidgetTester tester) async {
  await tester.runAsync(() async {
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  });
  await tester.pump();
}

Future<void> _shiftN(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.pump();
}

/// 打开 设置 → 播放参数 里的「缓存」开关，触发一次**整表** mpv 参数写入。
Future<void> _toggleCache(WidgetTester tester) async {
  if (find.byType(PlayerContextMenu).evaluate().isEmpty) {
    await tester.tapAt(const Offset(300, 260), buttons: kSecondaryButton);
    await tester.pump();
  }
  await tester.tap(find.text('设置'));
  await tester.pump();
  await tester.tap(find.text('播放参数'));
  await tester.pump();
  await tester.tap(find.text('缓存'));
  await tester.pump();
}

Future<void> _openVolume(WidgetTester tester) async {
  if (find.byType(PlayerContextMenu).evaluate().isEmpty) {
    await tester.tapAt(const Offset(300, 260), buttons: kSecondaryButton);
    await tester.pump();
  }
  await tester.tap(find.text('声音'));
  await tester.pump();
  await tester.tap(find.text('音量'));
  await tester.pump();
}

PlayerMenuItem _item(WidgetTester tester, String id) {
  final menu = tester.widget<PlayerContextMenu>(find.byType(PlayerContextMenu));
  PlayerMenuItem? search(List<PlayerMenuItem> items) {
    for (final item in items) {
      if (item.id == id) return item;
      final nested = search(item.children);
      if (nested != null) return nested;
    }
    return null;
  }

  return search(menu.sections.expand((s) => s.items).toList())!;
}

Future<Map<String, dynamic>> _persistedOptions(AppState state) async {
  final files = Directory(state.paths.configDir)
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.json'));
  for (final file in files) {
    final json = jsonDecode(await file.readAsString());
    if (json is Map<String, dynamic> && json['player'] is Map) {
      return Map<String, dynamic>.from(json['player'] as Map);
    }
  }
  throw StateError('No persisted playerOptions');
}

void _pageTest(String description, Future<void> Function(WidgetTester) body) {
  testWidgets(description, (tester) async {
    try {
      await body(tester);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(Duration.zero);
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(Duration.zero);
    }
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  _pageTest('volume submenu toggles real af, checkmark and persisted options', (
    tester,
  ) async {
    final f = await _mount(
      tester,
      options: const PlayerOptions(cache: false, autoNext: false),
    );
    await _openVolume(tester);
    expect(find.text('音量归一（Shift+N）'), findsOneWidget);
    expect(_item(tester, 'audio_normalization').selected, isFalse);
    await tester.tap(find.text('音量归一（Shift+N）'));
    await _flush(tester);
    expect(f.state.playerOptions.audioNormalization, isTrue);
    expect(_item(tester, 'audio_normalization').selected, isTrue);
    expect(f.media.writes, [('af', 'dynaudnorm')]);
    expect(f.state.playerOptions.cache, isFalse);
    expect(f.state.playerOptions.autoNext, isFalse);
    final saved = await tester.runAsync(() => _persistedOptions(f.state));
    expect(saved!['audioNormalization'], isTrue);
    await tester.tap(find.text('音量归一（Shift+N）'));
    await _flush(tester);
    expect(f.state.playerOptions.audioNormalization, isFalse);
    expect(_item(tester, 'audio_normalization').selected, isFalse);
    expect(f.media.writes, [('af', 'dynaudnorm'), ('af', '')]);
    expect(f.media.volumes, isEmpty);
  });

  _pageTest(
    'Shift+N shares page operation and ignores key repeats and plain N',
    (tester) async {
      final f = await _mount(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.pump();
      expect(f.state.playerOptions.audioNormalization, isFalse);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyN);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyN);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyN);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyN);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await _flush(tester);
      expect(f.state.playerOptions.audioNormalization, isTrue);
      expect(f.media.writes, [('af', 'dynaudnorm')]);
      await _openVolume(tester);
      expect(_item(tester, 'audio_normalization').selected, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _shiftN(tester);
      await _flush(tester);
      expect(f.state.playerOptions.audioNormalization, isFalse);
      expect(f.media.properties['af'], '');
    },
  );

  _pageTest(
    'rapid toggles serialize af and retain concurrent unrelated preferences and mute',
    (tester) async {
      final f = await _mount(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
      await tester.pump();
      f.media.volumes.clear();
      f.media.gate = Completer<void>();
      await _shiftN(tester);
      await _shiftN(tester);
      await _shiftN(tester);
      await _shiftN(tester);
      await tester.runAsync(
        () => f.state.setPlayerOptions(
          f.state.playerOptions.copyWith(cache: false),
        ),
      );
      expect(f.state.playerOptions.audioNormalization, isFalse);
      expect(f.media.active, 1);
      f.media.gate!.complete();
      await _flush(tester);
      expect(f.media.maxActive, 1);
      expect(f.media.writes, [
        ('af', 'dynaudnorm'),
        ('af', ''),
        ('af', 'dynaudnorm'),
        ('af', ''),
      ]);
      expect(f.media.properties['af'], '');
      expect(f.state.playerOptions.cache, isFalse);
      expect(f.media.volumes, isEmpty);
      await _openVolume(tester);
      expect(_item(tester, 'mute').selected, isTrue);
      final saved = await tester.runAsync(() => _persistedOptions(f.state));
      expect(saved!['audioNormalization'], isFalse);
      expect(saved['cache'], isFalse);
    },
  );

  _pageTest(
    'whole-map write stalled behind a later af toggle keeps kernel and preference aligned',
    (tester) async {
      final f = await _mount(tester);
      // 整表写入卡在第一笔非 af 属性上：此时按下 Shift+N，归一写入排在后面。
      f.media.nonAfGate = Completer<void>();
      await _toggleCache(tester);
      await tester.pump();
      expect(f.state.playerOptions.cache, isFalse);
      await _shiftN(tester);
      expect(f.state.playerOptions.audioNormalization, isTrue);
      f.media.nonAfGate!.complete();
      await _flush(tester);
      // 整表写入带的是**发起时**的 af（空串），不能盖掉之后那次开启。
      expect(f.state.playerOptions.audioNormalization, isTrue);
      expect(f.state.playerOptions.cache, isFalse);
      expect(f.media.properties['af'], 'dynaudnorm');
      final saved = await tester.runAsync(() => _persistedOptions(f.state));
      expect(saved!['audioNormalization'], isTrue);
    },
  );

  _pageTest(
    'live Shift+N does not disturb channel shortcuts or current request',
    (tester) async {
      final live = fixture();
      final request = live.session.request;
      final f = await _mount(
        tester,
        livePage: PlayerPage(
          state: live.state,
          request: request,
          liveSession: live.session,
        ),
      );
      final shortcuts = tester
          .widgetList<CallbackShortcuts>(find.byType(CallbackShortcuts))
          .expand((widget) => widget.bindings.keys)
          .whereType<SingleActivator>()
          .toList();
      expect(
        shortcuts.any((key) => key.trigger == LogicalKeyboardKey.pageUp),
        isTrue,
      );
      expect(
        shortcuts.any((key) => key.trigger == LogicalKeyboardKey.pageDown),
        isTrue,
      );
      expect(
        shortcuts.any(
          (key) => key.trigger == LogicalKeyboardKey.bracketRight && !key.alt,
        ),
        isFalse,
      );
      await _shiftN(tester);
      await _flush(tester);
      expect(f.state.playerOptions.audioNormalization, isTrue);
      expect(f.media.properties['af'], 'dynaudnorm');
      expect(live.session.request.url, request.url);
      expect(live.session.request.headers, request.headers);
    },
  );

  _pageTest('kernel readback rejection is visible and off remains available', (
    tester,
  ) async {
    final f = await _mount(tester);
    f.media.rejectEnable = true;
    await _shiftN(tester);
    await _flush(tester);
    expect(f.state.playerOptions.audioNormalization, isTrue);
    expect(f.media.properties['af'], '');
    expect(
      toastCenter.toasts.any(
        (t) => t.kind == ToastKind.error && t.message.contains('音量归一'),
      ),
      isTrue,
    );
    expect(f.state.log.export(), contains('内核未接受写入'));
    await _shiftN(tester);
    await _flush(tester);
    expect(f.state.playerOptions.audioNormalization, isFalse);
    expect(f.media.writes.last, ('af', ''));
    expect(f.media.properties['af'], '');
  });

  _pageTest('native exception does not break later off operation', (
    tester,
  ) async {
    final f = await _mount(tester);
    f.media.throwEnable = true;
    await _shiftN(tester);
    await _flush(tester);
    expect(
      toastCenter.toasts.any(
        (t) => t.kind == ToastKind.error && t.message.contains('音量归一'),
      ),
      isTrue,
    );
    expect(f.state.log.export(), contains('native af write failed'));
    await _shiftN(tester);
    await _flush(tester);
    expect(f.state.playerOptions.audioNormalization, isFalse);
    expect(f.media.properties['af'], '');
  });

  _pageTest(
    'passthrough enabled warns visibly without changing independent preference',
    (tester) async {
      final f = await _mount(
        tester,
        options: const PlayerOptions(audioPassthrough: true),
      );
      await _shiftN(tester);
      await _flush(tester);
      expect(f.state.playerOptions.audioNormalization, isTrue);
      expect(f.state.playerOptions.audioPassthrough, isTrue);
      expect(f.media.properties['af'], 'dynaudnorm');
      expect(
        toastCenter.toasts.any(
          (t) => t.message.contains('音频直通时不生效') && t.kind != ToastKind.success,
        ),
        isTrue,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: Stack(children: [const ToastHost()])),
        ),
      );
      await tester.pump();
      expect(find.textContaining('音频直通时不生效'), findsOneWidget);
    },
  );
}
