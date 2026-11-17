// ignore_for_file: invalid_use_of_protected_member
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/ui/app.dart';
import 'package:webhtv_pc/ui/player_context_menu.dart';
import 'package:webhtv_pc/ui/player_overlay.dart';
import 'package:webhtv_pc/ui/player_page.dart';
import 'package:webhtv_pc/ui/toast.dart';

import 'live_playback_session_test.dart' show fixture;
import 'player_live_controls_test.dart' show mount, flush, unmount;

const previous = SingleActivator(
  LogicalKeyboardKey.arrowLeft,
  control: true,
  shift: true,
);
const next = SingleActivator(
  LogicalKeyboardKey.arrowRight,
  control: true,
  shift: true,
);

Future<void> keyframeKey(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await flush(tester);
}

PlayerMenuItem menuItem(WidgetTester tester, String id) {
  final menu = tester.widget<PlayerContextMenu>(find.byType(PlayerContextMenu));
  return menu.sections
      .expand((section) => section.items)
      .firstWhere((item) => item.id == id);
}

Future<void> openMenu(WidgetTester tester) async {
  await tester.sendKeyEvent(LogicalKeyboardKey.f10);
  await tester.pump();
}

void main() {
  setUp(dismissAllToasts);
  tearDown(dismissAllToasts);
  test(
    'keyframe shortcut callbacks are optional and ordinary arrows unchanged',
    () {
      var backwards = 0, forwards = 0, prevFrames = 0, nextFrames = 0;
      void noop() {}
      Map<ShortcutActivator, VoidCallback> shortcuts({bool frames = false}) =>
          buildPlayerShortcuts(
            togglePlay: noop,
            seekBackward: () => backwards++,
            seekForward: () => forwards++,
            volumeUp: noop,
            volumeDown: noop,
            toggleMute: noop,
            previousEpisode: noop,
            nextEpisode: noop,
            toggleFullscreen: noop,
            exitFullscreen: noop,
            previousKeyframe: frames ? () => prevFrames++ : null,
            nextKeyframe: frames ? () => nextFrames++ : null,
          );
      expect(shortcuts().containsKey(previous), false);
      expect(shortcuts().containsKey(next), false);
      final enabled = shortcuts(frames: true);
      enabled[previous]!();
      enabled[next]!();
      enabled[const SingleActivator(LogicalKeyboardKey.arrowLeft)]!();
      enabled[const SingleActivator(LogicalKeyboardKey.arrowRight)]!();
      expect([prevFrames, nextFrames, backwards, forwards], [1, 1, 1, 1]);
    },
  );

  testWidgets(
    'VOD menu toggle wires provider and keyboard keyframes retain 10s arrows',
    (tester) async {
      final f = fixture();
      final media = await mount(
        tester,
        PlayerPage(state: f.state, request: f.session.request),
      );
      debugRevealPlayerControls(
        tester.state<State<PlayerPage>>(find.byType(PlayerPage)),
      );
      await tester.pump();
      PlayerProgressSlider slider() => tester.widget<PlayerProgressSlider>(
        find.byType(PlayerProgressSlider),
      );
      expect(slider().thumbnailPreviewEnabled, false);
      await openMenu(tester);
      expect(menuItem(tester, 'previous_keyframe').enabled, true);
      expect(menuItem(tester, 'next_keyframe').label, contains('Ctrl+Shift+→'));
      await tester.tap(
        find.byKey(const ValueKey('player-menu-item-section:播放')),
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('player-menu-item-thumbnail_preview')),
      );
      await flush(tester);
      debugRevealPlayerControls(
        tester.state<State<PlayerPage>>(find.byType(PlayerPage)),
      );
      await tester.pump();
      expect(f.state.playerOptions.showThumbnailPreview, true);
      expect(slider().thumbnailPreviewEnabled, true);
      expect(slider().thumbnailProvider, isNotNull);
      expect(slider().previewSourceKey, isA<int>());
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await flush(tester);
      expect(media.state.position, const Duration(seconds: 11));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await flush(tester);
      expect(media.state.position, const Duration(seconds: 1));
      for (final key in [
        LogicalKeyboardKey.arrowLeft,
        LogicalKeyboardKey.arrowRight,
      ]) {
        await keyframeKey(tester, key);
        expect(toastCenter.toasts.last.message, '关键帧跳转不可用');
        expect(toastCenter.toasts.last.duration, const Duration(seconds: 3));
        expect(media.state.position, const Duration(seconds: 1));
      }
      await openMenu(tester);
      menuItem(tester, 'thumbnail_preview').onSelect!();
      await flush(tester);
      debugRevealPlayerControls(
        tester.state<State<PlayerPage>>(find.byType(PlayerPage)),
      );
      await tester.pump();
      expect(slider().thumbnailPreviewEnabled, false);
      expect(slider().thumbnailProvider, isNull);
      await unmount(tester);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('hiding control bar removes hover preview and late results', (
    tester,
  ) async {
    final f = fixture();
    await tester.runAsync(f.state.bootstrap);
    await tester.runAsync(
      () => f.state.setPlayerOptions(
        f.state.playerOptions.copyWith(showThumbnailPreview: true),
      ),
    );
    await mount(tester, PlayerPage(state: f.state, request: f.session.request));
    debugRevealPlayerControls(
      tester.state<State<PlayerPage>>(find.byType(PlayerPage)),
    );
    await tester.pump();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(
      tester.getCenter(
        find.descendant(
          of: find.byType(PlayerProgressSlider),
          matching: find.byType(Slider),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      find.byKey(const ValueKey('player-thumbnail-preview')),
      findsOneWidget,
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(
      debugPlayerControlsVisible(
        tester.state<State<PlayerPage>>(find.byType(PlayerPage)),
      ),
      false,
    );
    expect(
      find.byKey(const ValueKey('player-thumbnail-preview')),
      findsNothing,
    );
    await tester.pump(const Duration(seconds: 6));
    expect(
      find.byKey(const ValueKey('player-thumbnail-preview')),
      findsNothing,
    );
    await mouse.removePointer();
    await unmount(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'unknown duration disables keyframe actions and thumbnail provider',
    (tester) async {
      final f = fixture();
      final media = await mount(
        tester,
        PlayerPage(state: f.state, request: f.session.request),
      );
      media.original.durationController.add(Duration.zero);
      await flush(tester);
      await openMenu(tester);
      expect(menuItem(tester, 'previous_keyframe').enabled, false);
      expect(menuItem(tester, 'next_keyframe').enabled, false);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await keyframeKey(tester, LogicalKeyboardKey.arrowRight);
      expect(
        toastCenter.toasts.where((toast) => toast.message == '关键帧跳转不可用'),
        isEmpty,
      );
      debugRevealPlayerControls(
        tester.state<State<PlayerPage>>(find.byType(PlayerPage)),
      );
      await tester.pump();
      final slider = tester.widget<PlayerProgressSlider>(
        find.byType(PlayerProgressSlider),
      );
      expect(slider.thumbnailPreviewEnabled, false);
      expect(slider.thumbnailProvider, isNull);
      await unmount(tester);
    },
  );

  testWidgets(
    'live with nonzero duration disables both keyframe shortcuts and provider',
    (tester) async {
      final f = fixture();
      await tester.runAsync(f.state.bootstrap);
      await tester.runAsync(
        () => f.state.setPlayerOptions(
          f.state.playerOptions.copyWith(showThumbnailPreview: true),
        ),
      );
      final media = await mount(
        tester,
        PlayerPage(
          state: f.state,
          request: f.session.request,
          liveSession: f.session,
        ),
      );
      expect(media.state.duration, greaterThan(Duration.zero));
      await openMenu(tester);
      expect(menuItem(tester, 'previous_keyframe').enabled, false);
      expect(menuItem(tester, 'next_keyframe').enabled, false);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await keyframeKey(tester, LogicalKeyboardKey.arrowLeft);
      await keyframeKey(tester, LogicalKeyboardKey.arrowRight);
      expect(
        toastCenter.toasts.where((toast) => toast.message == '关键帧跳转不可用'),
        isEmpty,
      );
      debugRevealPlayerControls(
        tester.state<State<PlayerPage>>(find.byType(PlayerPage)),
      );
      await tester.pump();
      final slider = tester.widget<PlayerProgressSlider>(
        find.byType(PlayerProgressSlider),
      );
      expect(slider.thumbnailPreviewEnabled, false);
      expect(slider.thumbnailProvider, isNull);
      await unmount(tester);
    },
  );
}
