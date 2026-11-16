// ignore_for_file: invalid_use_of_protected_member
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:webhtv_pc/core/epg.dart';
import 'package:webhtv_pc/core/player_options.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/services/ui_preferences_store.dart';
import 'package:webhtv_pc/ui/player_context_menu.dart';
import 'package:webhtv_pc/ui/player_page.dart';

import 'live_playback_session_test.dart' show fixture;
import 'support/player_page_harness.dart';
import 'support/test_fonts.dart';

class _GestureMedia extends PlatformPlayer {
  _GestureMedia(this.original) : super(configuration: original.configuration) {
    stream = original.stream;
  }
  final PlatformPlayer original;
  final playback = <bool>[];
  final seeks = <Duration>[];
  final volumes = <double>[];
  bool holdSnapshot = false;
  @override
  Future<int> get handle => original.handle;
  void seed(bool playing, {int position = 50, double volume = 50}) {
    state = state.copyWith(
      playing: playing,
      position: Duration(seconds: position),
      duration: const Duration(seconds: 100),
      volume: volume,
    );
    original.playingController.add(playing);
    original.positionController.add(state.position);
    original.durationController.add(state.duration);
    original.volumeController.add(volume);
  }

  Future<void> _setPlaying(bool value) async {
    playback.add(value);
    state = state.copyWith(playing: value);
    if (!holdSnapshot) original.playingController.add(value);
  }

  @override
  Future<void> play() => _setPlaying(true);
  @override
  Future<void> pause() => _setPlaying(false);
  @override
  Future<void> seek(Duration position) async {
    seeks.add(position);
    state = state.copyWith(position: position);
    original.positionController.add(position);
  }

  @override
  Future<void> setVolume(double volume) async {
    volumes.add(volume);
    state = state.copyWith(volume: volume);
    original.volumeController.add(volume);
  }

  @override
  Future<void> dispose() async {
    await original.dispose();
    await super.dispose();
  }
}

Future<({AppState state, _GestureMedia media})> _mount(
  WidgetTester tester, {
  PlayerOptions options = const PlayerOptions(),
  bool live = false,
  bool catchup = false,
  bool inset = false,
  Size size = const Size(1280, 720),
}) async {
  late AppState state;
  if (live || catchup || inset) {
    final f = fixture(
      initialProgram: catchup
          ? const EpgProgram(title: '回看节目', startMs: 1000, stopMs: 2000)
          : null,
    );
    state = f.state;
    await tester.runAsync(() async {
      await state.bootstrap();
      await state.setPlayerOptions(options);
    });
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    installMediaKitMocks(tester);
    installWindowManagerMocks(tester, trackFullscreen: true);
    await tester.pumpWidget(
      RepaintBoundary(
        key: playerPageCaptureRootKey,
        child: MaterialApp(
          home: Padding(
            padding: inset
                ? const EdgeInsets.only(left: 200, right: 40)
                : EdgeInsets.zero,
            child: PlayerPage(
              state: state,
              request: f.session.request,
              liveSession: live || catchup ? f.session : null,
            ),
          ),
        ),
      ),
    );
    await settlePlayerPage(tester);
  } else {
    await pumpPlayerPage(
      tester,
      trackFullscreen: true,
      size: size,
      onStateReady: (s) async {
        state = s;
        await s.setPlayerOptions(options);
      },
    );
  }
  final player = tester.widget<Video>(find.byType(Video)).controller.player;
  final media = _GestureMedia(player.platform!);
  player.platform = media;
  media.seed(false);
  await tester.pump();
  windowManagerCalls.clear();
  return (state: state, media: media);
}

Rect _videoRect(WidgetTester tester) => tester.getRect(
  find
      .ancestor(of: find.byType(Video), matching: find.byType(GestureDetector))
      .first,
);
Future<void> _pair(WidgetTester tester, Offset point) async {
  await tester.tapAt(point);
  await tester.tapAt(point);
  await tester.pump();
}

int get _fullscreenCalls =>
    windowManagerCalls.where((c) => c.method == 'setFullScreen').length;
Future<void> _drill(WidgetTester tester, String id) async {
  final target = find.byKey(ValueKey('player-menu-item-$id'));
  expect(target, findsOneWidget);
  await tester.ensureVisible(target);
  await tester.pump(const Duration(milliseconds: 50));
  await tester.tap(target);
  await tester.pump(const Duration(milliseconds: 50));
}

Future<void> _openSettings(WidgetTester tester) async {
  await tester.tapAt(
    _videoRect(tester).topLeft + const Offset(60, 100),
    buttons: kSecondaryButton,
  );
  await tester.pump();
  await _drill(tester, 'section:设置');
  await _drill(tester, 'settings_player_options');
}

Future<void> _capture(WidgetTester tester, String name) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(playerPageCaptureRootKey),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final dir = Directory('../../.superpowers/sdd/double-click-areas/gesture');
    await dir.create(recursive: true);
    await File('${dir.path}/$name.png')
        .writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  setUpAll(() async {
    await loadFixtureFonts(cjkFamily: 'Roboto');
    await loadFixtureFonts(cjkFamily: 'Microsoft YaHei UI');
  });
  tearDown(() => debugOsdClockOverride = null);

  for (final initial in [false, true]) {
    for (final sample in [
      ('LR', PlayerDoubleClickAction.toggleFullscreen, [!initial, initial]),
      (
        'LLL',
        PlayerDoubleClickAction.togglePlayback,
        [!initial, !initial, initial],
      ),
      (
        'LLL',
        PlayerDoubleClickAction.toggleFullscreen,
        [!initial, initial, !initial],
      ),
    ]) {
      testWidgets(
        'stale sequence ${sample.$1} ${sample.$2.id} initial=$initial preserves every command',
        (tester) async {
          final f = await _mount(
            tester,
            options: PlayerOptions(doubleClickLeft: sample.$2),
          );
          f.media.seed(initial);
          await tester.pump();
          f.media.holdSnapshot = true;
          final rect = _videoRect(tester);
          for (final side in sample.$1.split('')) {
            await tester.tapAt(
              side == 'L'
                  ? rect.centerLeft + const Offset(100, 0)
                  : rect.centerRight - const Offset(100, 0),
            );
          }
          await tester.pump();
          debugPrint(
            'stale initial=$initial ${sample.$1} ${sample.$2.id} commands=${f.media.playback}',
          );
          expect(f.media.playback, sample.$3);
          expect(f.media.state.playing, sample.$3.last);
          await settlePlayerPage(tester);
        },
      );
    }
    for (final action in PlayerDoubleClickAction.values) {
      for (final sequence in ['LRR', 'LLLL']) {
        testWidgets(
          'stale sequence $sequence ${action.id} initial=$initial preserves pair baseline and new rounds',
          (tester) async {
            final f = await _mount(
              tester,
              options: PlayerOptions(
                doubleClickLeft: action,
                doubleClickRight: action,
              ),
            );
            f.media.seed(initial);
            await tester.pump();
            f.media.holdSnapshot = true;
            final rect = _videoRect(tester);
            for (final side in sequence.split('')) {
              await tester.tapAt(
                side == 'L'
                    ? rect.centerLeft + const Offset(100, 0)
                    : rect.centerRight - const Offset(100, 0),
              );
            }
            await tester.pump();
            final want = sequence == 'LRR'
                ? [
                    !initial,
                    initial,
                    action == PlayerDoubleClickAction.togglePlayback
                        ? initial
                        : !initial,
                  ]
                : action == PlayerDoubleClickAction.togglePlayback
                ? [!initial, !initial, initial, initial]
                : [!initial, initial, !initial, initial];
            debugPrint(
              'stale initial=$initial $sequence ${action.id} commands=${f.media.playback}',
            );
            expect(f.media.playback, want);
            expect(f.media.state.playing, want.last);
            await settlePlayerPage(tester);
          },
        );
      }
    }
    testWidgets('stale click intent initial=$initial expires at click window', (
      tester,
    ) async {
      final f = await _mount(
        tester,
        options: const PlayerOptions(
          doubleClickLeft: PlayerDoubleClickAction.togglePlayback,
        ),
      );
      f.media.seed(initial);
      await tester.pump();
      f.media.holdSnapshot = true;
      final point = _videoRect(tester).centerLeft + const Offset(100, 0);
      await _pair(tester, point);
      await tester.pump(
        kPlayerDoubleClickWindow + const Duration(milliseconds: 50),
      );
      await tester.tapAt(point);
      await tester.pump();
      expect(
        f.media.playback,
        [!initial, !initial, !initial],
        reason:
            'new window uses current engine snapshot, not prior local intent',
      );
      await settlePlayerPage(tester);
    });
    testWidgets(
      'fresh external engine transitions initial=$initial supersede click intent before window expires',
      (tester) async {
        final f = await _mount(
          tester,
          options: const PlayerOptions(
            doubleClickLeft: PlayerDoubleClickAction.togglePlayback,
          ),
        );
        f.media.seed(initial);
        await tester.pump();
        f.media.holdSnapshot = true;
        final point = _videoRect(tester).centerLeft + const Offset(100, 0);
        await _pair(tester, point);
        f.media.seed(!initial);
        await tester.pump();
        f.media.seed(initial);
        await tester.pump();
        await tester.tapAt(point);
        await tester.pump();
        expect(f.media.playback, [
          !initial,
          !initial,
          !initial,
        ], reason: 'fresh engine event is authoritative over cached target');
        await settlePlayerPage(tester);
      },
    );
  }

  for (final initial in [false, true]) {
    testWidgets(
      'keyboard playback transitions initial=$initial supersede prior stale tap target',
      (tester) async {
        final f = await _mount(
          tester,
          options: const PlayerOptions(
            doubleClickLeft: PlayerDoubleClickAction.togglePlayback,
          ),
        );
        f.media.seed(initial);
        await tester.pump();
        f.media.holdSnapshot = true;
        final point = _videoRect(tester).centerLeft + const Offset(100, 0);
        await _pair(tester, point);
        f.media.holdSnapshot = false;
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.pump();
        await tester.tapAt(point);
        await tester.pump();
        expect(f.media.playback, [
          !initial,
          !initial,
          !initial,
          initial,
          !initial,
        ]);
        expect(f.media.state.playing, !initial);
        await settlePlayerPage(tester);
      },
    );
  }

  for (final playing in [false, true]) {
    for (final stale in [false, true]) {
      for (final action in PlayerDoubleClickAction.values) {
        testWidgets(
          '${action.id}: original=$playing stale=$stale keeps exact playback intent',
          (tester) async {
            final f = await _mount(
              tester,
              options: PlayerOptions(doubleClickLeft: action),
            );
            f.media.seed(playing);
            await tester.pump();
            f.media.holdSnapshot = stale;
            final point = _videoRect(tester).centerLeft + const Offset(100, 0);
            await tester.tapAt(point);
            expect(f.media.playback, [
              !playing,
            ], reason: 'first click must be immediate');
            if (!stale) await tester.pump();
            await tester.tapAt(point);
            await tester.pump();
            final target = action == PlayerDoubleClickAction.togglePlayback
                ? !playing
                : playing;
            expect(f.media.state.playing, target);
            expect(f.media.playback.last, target);
            expect(
              _fullscreenCalls,
              action == PlayerDoubleClickAction.toggleFullscreen ? 1 : 0,
            );
            expect(
              f.media.seeks,
              action == PlayerDoubleClickAction.seekBackward
                  ? [const Duration(seconds: 40)]
                  : action == PlayerDoubleClickAction.seekForward
                  ? [const Duration(seconds: 60)]
                  : isEmpty,
            );
            expect(
              f.media.volumes,
              action == PlayerDoubleClickAction.volumeUp
                  ? [55.0]
                  : action == PlayerDoubleClickAction.volumeDown
                  ? [45.0]
                  : isEmpty,
            );
            await settlePlayerPage(tester);
          },
        );
      }
    }
  }

  for (final playing in [false, true]) {
    for (final stale in [false, true]) {
      testWidgets(
        'right default original=$playing stale=$stale only toggles fullscreen',
        (tester) async {
          final f = await _mount(
            tester,
            options: const PlayerOptions(
              doubleClickLeft: PlayerDoubleClickAction.none,
            ),
          );
          f.media.seed(playing);
          await tester.pump();
          f.media.holdSnapshot = stale;
          final point = _videoRect(tester).centerRight - const Offset(100, 0);
          await tester.tapAt(point);
          if (!stale) await tester.pump();
          await tester.tapAt(point);
          await tester.pump();
          expect(f.media.state.playing, playing);
          expect(f.media.playback, [!playing, playing]);
          expect(_fullscreenCalls, 1);
          await settlePlayerPage(tester);
        },
      );
    }
  }

  testWidgets(
    'local render box splits left, midpoint and right; third tap is new',
    (tester) async {
      final f = await _mount(
        tester,
        inset: true,
        options: const PlayerOptions(
          doubleClickLeft: PlayerDoubleClickAction.volumeDown,
          doubleClickRight: PlayerDoubleClickAction.volumeUp,
        ),
      );
      final rect = _videoRect(tester);
      expect(rect.left, 200);
      await _pair(tester, rect.center - const Offset(1, 0));
      expect(f.media.volumes, [45.0]);
      await tester.tapAt(rect.center);
      await tester.pump();
      expect(f.media.volumes, [45.0], reason: 'third tap starts a new pair');
      await tester.tapAt(rect.center);
      await tester.pump();
      expect(f.media.volumes, [
        45.0,
        50.0,
      ], reason: 'midpoint belongs to right');
      await _pair(tester, rect.centerRight - const Offset(100, 0));
      expect(f.media.volumes, [45.0, 50.0, 55.0]);
      await settlePlayerPage(tester);
    },
  );

  testWidgets('cross-side clicks never combine, next same-side click pairs', (
    tester,
  ) async {
    await _mount(tester);
    final rect = _videoRect(tester);
    await tester.tapAt(rect.centerLeft + const Offset(100, 0));
    await tester.tapAt(rect.centerRight - const Offset(100, 0));
    await tester.pump();
    expect(_fullscreenCalls, 0);
    await tester.tapAt(rect.centerRight - const Offset(100, 0));
    await tester.pump();
    expect(_fullscreenCalls, 1);
    await settlePlayerPage(tester);
  });

  for (final sample in [
    (PlayerDoubleClickAction.seekBackward, 3, 50.0, 0),
    (PlayerDoubleClickAction.seekForward, 98, 50.0, 100),
    (PlayerDoubleClickAction.volumeDown, 50, 2.0, 0),
    (PlayerDoubleClickAction.volumeUp, 50, 98.0, 100),
  ]) {
    testWidgets('${sample.$1.id} clamps at media boundary', (tester) async {
      final f = await _mount(
        tester,
        options: PlayerOptions(doubleClickLeft: sample.$1),
      );
      f.media.seed(false, position: sample.$2, volume: sample.$3);
      await tester.pump();
      await _pair(tester, _videoRect(tester).centerLeft + const Offset(100, 0));
      if (sample.$1.isSeek) {
        expect(f.media.seeks, [Duration(seconds: sample.$4)]);
      } else {
        expect(f.media.volumes, [sample.$4.toDouble()]);
      }
      await settlePlayerPage(tester);
    });
  }

  for (final catchup in [false, true]) {
    for (final action in [
      PlayerDoubleClickAction.seekBackward,
      PlayerDoubleClickAction.seekForward,
      PlayerDoubleClickAction.volumeUp,
    ]) {
      testWidgets(
        'live catchup=$catchup ${action.id}: seek becomes none, other action works',
        (tester) async {
          final f = await _mount(
            tester,
            live: !catchup,
            catchup: catchup,
            options: PlayerOptions(doubleClickLeft: action),
          );
          await _pair(
            tester,
            _videoRect(tester).centerLeft + const Offset(100, 0),
          );
          expect(f.media.seeks, isEmpty);
          expect(
            f.media.volumes,
            action == PlayerDoubleClickAction.volumeUp ? [55.0] : isEmpty,
          );
          expect(f.media.state.playing, false);
          expect(f.state.playerOptions.doubleClickLeft, action);
          await settlePlayerPage(tester);
        },
      );
    }
  }

  testWidgets(
    'menu persists independent selections and reflects current checks',
    (tester) async {
      final f = await _mount(tester);
      await _openSettings(tester);
      await _drill(tester, 'settings_double_click_left');
      await _drill(tester, 'settings_double_click_left_seekBackward');
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      expect(
        f.state.playerOptions.doubleClickLeft,
        PlayerDoubleClickAction.seekBackward,
      );
      expect(
        f.state.playerOptions.doubleClickRight,
        PlayerDoubleClickAction.toggleFullscreen,
      );
      await _drill(tester, 'settings_double_click_right');
      await _drill(tester, 'settings_double_click_right_volumeUp');
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      expect(
        f.state.playerOptions.doubleClickRight,
        PlayerDoubleClickAction.volumeUp,
      );
      expect(
        f.state.playerOptions.doubleClickLeft,
        PlayerDoubleClickAction.seekBackward,
      );
      final persisted = UiPreferencesStore(path: f.state.paths.settingsPath);
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await persisted.load();
      });
      expect(
        persisted.playerOptions.doubleClickLeft,
        PlayerDoubleClickAction.seekBackward,
      );
      expect(
        persisted.playerOptions.doubleClickRight,
        PlayerDoubleClickAction.volumeUp,
      );
      final menu = tester.widget<PlayerContextMenu>(
        find.byType(PlayerContextMenu),
      );
      final settings = menu.sections.firstWhere((s) => s.title == '设置');
      final playback = settings.items.firstWhere(
        (i) => i.id == 'settings_player_options',
      );
      for (final side in ['left', 'right']) {
        final items = playback.children
            .firstWhere((i) => i.id == 'settings_double_click_$side')
            .children;
        expect(items.where((i) => i.selected), hasLength(1));
        expect(
          items.firstWhere((i) => i.selected).id,
          side == 'left'
              ? 'settings_double_click_left_seekBackward'
              : 'settings_double_click_right_volumeUp',
        );
      }
      await settlePlayerPage(tester);
    },
  );

  for (final size in [const Size(1024, 640), const Size(1280, 720)]) {
    for (final mode in ['vod', 'live', 'catchup']) {
      for (final side in ['left', 'right']) {
        testWidgets(
          'central four columns ${size.width} $mode $side: no overlap, disabled seeks and bottom leaf persists',
          (tester) async {
            debugOsdClockOverride = DateTime(2026, 11, 14, 12, 34, 56);
            final f = await _mount(
              tester,
              size: size,
              live: mode == 'live',
              catchup: mode == 'catchup',
              options: const PlayerOptions(
                doubleClickLeft: PlayerDoubleClickAction.seekBackward,
                doubleClickRight: PlayerDoubleClickAction.volumeUp,
              ),
            );
            await tester.tapAt(
              _videoRect(tester).center,
              buttons: kSecondaryButton,
            );
            await tester.pump();
            for (final id in [
              'section:设置',
              'settings_player_options',
              'settings_double_click_$side',
            ]) {
              await _drill(tester, id);
            }
            if (size.width == 1280 && mode == 'vod' && side == 'left') {
              const phase = String.fromEnvironment(
                'GESTURE_REWORK_CAPTURE',
                defaultValue: 'after',
              );
              await _capture(tester, 'run2-central-$phase-vod');
            }
            final surfaces = find.descendant(
              of: find.byType(PlayerContextMenu),
              matching: find.byType(Material),
            );
            expect(surfaces, findsNWidgets(4));
            final rects = [
              for (var i = 0; i < 4; i++) tester.getRect(surfaces.at(i)),
            ];
            debugPrint('central ${size.width} $mode $side columns=$rects');
            for (var i = 0; i < 4; i++) {
              expect(rects[i].left, greaterThanOrEqualTo(8));
              expect(rects[i].right, lessThanOrEqualTo(size.width - 8));
              expect(rects[i].bottom, lessThanOrEqualTo(size.height - 8));
              for (var j = 0; j < i; j++) {
                expect(
                  rects[i].overlaps(rects[j]),
                  isFalse,
                  reason: 'visible column $i overlaps column $j: $rects',
                );
              }
            }
            for (final action in ['seekBackward', 'seekForward']) {
              final row = find.byKey(
                ValueKey(
                  'player-menu-item-settings_double_click_${side}_$action',
                ),
              );
              expect(tester.widget<InkWell>(row).onTap == null, mode != 'vod');
            }
            await _drill(tester, 'settings_double_click_${side}_none');
            final persisted = UiPreferencesStore(
              path: f.state.paths.settingsPath,
            );
            await tester.runAsync(() async {
              await Future<void>.delayed(const Duration(milliseconds: 50));
              await persisted.load();
            });
            expect(
              side == 'left'
                  ? persisted.playerOptions.doubleClickLeft
                  : persisted.playerOptions.doubleClickRight,
              PlayerDoubleClickAction.none,
            );
            expect(
              side == 'left'
                  ? persisted.playerOptions.doubleClickRight
                  : persisted.playerOptions.doubleClickLeft,
              side == 'left'
                  ? PlayerDoubleClickAction.volumeUp
                  : PlayerDoubleClickAction.seekBackward,
            );
            await settlePlayerPage(tester);
          },
        );
      }
    }
  }

  for (final live in [false, true]) {
    testWidgets(
      'menu live=$live renders and disables seek without removing selection',
      (tester) async {
        debugOsdClockOverride = DateTime(2026, 11, 14, 12, 34, 56);
        await _mount(
          tester,
          live: live,
          options: const PlayerOptions(
            doubleClickLeft: PlayerDoubleClickAction.seekBackward,
          ),
        );
        await _openSettings(tester);
        const phase = String.fromEnvironment(
          'GESTURE_CAPTURE',
          defaultValue: 'after',
        );
        if (phase == 'before') {
          await _capture(tester, live ? 'before-live' : 'before-vod');
        } else {
          await _drill(tester, 'settings_double_click_left');
          for (final id in ['seekBackward', 'seekForward']) {
            final row = find.byKey(
              ValueKey('player-menu-item-settings_double_click_left_$id'),
            );
            expect(tester.widget<InkWell>(row).onTap == null, live);
          }
          await _capture(tester, live ? 'after-live' : 'after-vod');
        }
        await settlePlayerPage(tester);
      },
    );
  }
}
