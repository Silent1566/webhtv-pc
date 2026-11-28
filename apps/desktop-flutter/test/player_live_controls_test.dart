// ignore_for_file: invalid_use_of_protected_member
import 'dart:async';
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
import 'package:webhtv_pc/core/osd_config.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/ui/ai_integration_widgets.dart';
import 'package:webhtv_pc/ui/player_context_menu.dart';
import 'package:webhtv_pc/ui/player_page.dart';
import 'package:webhtv_pc/ui/player_controller.dart';
import 'package:webhtv_pc/ui/player_osd.dart';
import 'package:webhtv_pc/ui/player_overlay.dart';
import 'package:webhtv_pc/ui/theme.dart';
import 'package:webhtv_pc/ui/player_live_panel.dart';
import 'package:webhtv_pc/ui/glass_widgets.dart';

import 'live_playback_session_test.dart' show fixture;
import 'support/player_page_harness.dart';
import 'support/test_fonts.dart';

class MediaJournal {
  final opened = <String>[];
  final openedHeaders = <Map<String, String>>[];
  final failed = <String>{};
  final gates = <String, Completer<void>>{};
  final failureMessages = <String, String>{};
}

class MediaIO extends PlatformPlayer {
  MediaIO(this.original, this.journal)
    : super(configuration: original.configuration) {
    stream = original.stream;
  }
  final MediaJournal journal;
  bool disposed = false;
  final PlatformPlayer original;
  List<String> get opened => journal.opened;
  List<Map<String, String>> get openedHeaders => journal.openedHeaders;
  Set<String> get failed => journal.failed;
  Map<String, Completer<void>> get gates => journal.gates;
  Map<String, String> get failureMessages => journal.failureMessages;
  @override
  Future<int> get handle => original.handle;
  void progress(int seconds, {bool completed = false}) {
    state = state.copyWith(
      position: Duration(seconds: seconds),
      duration: const Duration(seconds: 1000),
      playing: !completed,
      completed: completed,
    );
    if (disposed) return;
    original.durationController.add(state.duration);
    original.positionController.add(state.position);
    original.playingController.add(state.playing);
    original.completedController.add(completed);
  }

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    final media = playable as Media;
    opened.add(media.uri);
    openedHeaders.add(media.httpHeaders ?? {});
    final gate = gates.remove(media.uri);
    if (gate != null) await gate.future;
    if (failureMessages[media.uri] case final message?) {
      throw StateError(message);
    }
    if (failed.contains(media.uri)) throw StateError('404 missing channel');
    progress(1);
  }

  @override
  Future<void> seek(Duration position) async => progress(position.inSeconds);
  @override
  Future<void> play() async => progress(state.position.inSeconds);
  @override
  Future<void> pause() async {}
  @override
  Future<void> setVolume(double volume) async {
    state = state.copyWith(volume: volume);
    if (!disposed) original.volumeController.add(volume);
  }

  @override
  Future<void> setRate(double rate) async {
    state = state.copyWith(rate: rate);
    if (!disposed) original.rateController.add(rate);
  }

  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) async {}
  @override
  Future<void> dispose() async {
    disposed = true;
    unawaited(original.dispose());
    await super.dispose();
  }
}

Future<MediaIO> mount(
  WidgetTester tester,
  PlayerPage page, {
  Size size = const Size(1024, 640),
  Set<String> failed = const {},
  GlobalKey? capture,
  ThemeData? theme,
}) async {
  await tester.runAsync(page.state.bootstrap);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  installMediaKitMocks(tester);
  installWindowManagerMocks(tester);
  MediaIO? media;
  final journal = MediaJournal()..failed.addAll(failed);
  final seen = <Player>{};
  var active = true;
  addTearDown(() => active = false);
  tester.binding.addPersistentFrameCallback((_) {
    if (!active || find.byType(Video).evaluate().isEmpty) return;
    final player = tester.widget<Video>(find.byType(Video)).controller.player;
    if (!seen.add(player)) return;
    final next = MediaIO(player.platform!, journal);
    media ??= next;
    player.platform = next;
  });
  final app = MaterialApp(
    theme: theme,
    debugShowCheckedModeBanner: capture == null,
    home: page,
  );
  await tester.pumpWidget(
    capture == null ? app : RepaintBoundary(key: capture, child: app),
  );
  await flush(tester);
  expect(tester.takeException(), isNull);
  return media!;
}

Future<void> flush(WidgetTester tester) async {
  await settlePlayerPage(tester, times: 2);
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await settlePlayerPage(tester, times: 2);
}

Future<void> unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(Duration.zero);
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump(Duration.zero);
}

const _liveClockCapture = String.fromEnvironment('LIVE_CLOCK_CAPTURE');
const _playerTimeCapture = String.fromEnvironment('PLAYER_TIME_CAPTURE');
const _playerFocusCapture = String.fromEnvironment('PLAYER_FOCUS_CAPTURE');

const _playerIdle = Duration(seconds: 4);

bool _focusWithin(WidgetTester tester, Finder target) {
  final root = tester.element(target);
  final focus = FocusManager.instance.primaryFocus?.context;
  var inside = focus == root;
  focus?.visitAncestorElements((ancestor) {
    if (ancestor == root) inside = true;
    return !inside;
  });
  return inside;
}

Future<void> _capturePlayer(WidgetTester tester, GlobalKey key, String name) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    await File(
      '../../.local/ui-quality-sweep/$name.png',
    ).writeAsBytes(png!.buffer.asUint8List());
  });
}

void main() {
  if (_liveClockCapture.isNotEmpty ||
      _playerTimeCapture.isNotEmpty ||
      _playerFocusCapture.isNotEmpty) {
    setUpAll(() async {
      expect(_liveClockCapture, anyOf('', 'before', 'after'));
      expect(_playerTimeCapture, anyOf('', 'before', 'after'));
      expect(_playerFocusCapture, anyOf('', 'before', 'after'));
      await loadFixtureFonts(cjkFamily: 'Noto Sans CJK SC');
      await loadFixtureFonts(cjkFamily: 'Roboto');
      expectFontsAvailableOrSkip();
    });
  }
  for (final isLive in [true, false]) {
    for (final brightness in Brightness.values) {
      final mode = isLive ? 'live' : 'non-live';
      testWidgets(
        'Seek times are readable for $mode under a ${brightness.name} shell',
        (tester) async {
          debugOsdClockOverride = DateTime(2026, 11, 28, 12, 34, 56);
          addTearDown(() => debugOsdClockOverride = null);
          final capture =
              isLive &&
                  brightness == Brightness.light &&
                  _playerTimeCapture.isNotEmpty
              ? GlobalKey()
              : null;
          final f = fixture();
          final media = await mount(
            tester,
            PlayerPage(
              state: f.state,
              request: f.session.request,
              liveSession: isLive ? f.session : null,
            ),
            capture: capture,
            theme: buildAppTheme(brightness),
          );
          media.progress(83);
          await tester.pump();

          final page = find.byType(PlayerPage);
          final overlay = find.byType(PlayerControlOverlay);
          final playerTheme = Theme.of(tester.element(overlay));
          expect(Theme.of(tester.element(page)).brightness, brightness);
          expect(playerTheme.brightness, Brightness.dark);
          expect(
            tester
                .widget<PlayerOsdLayer>(find.byType(PlayerOsdLayer))
                .controlsVisible,
            isTrue,
          );
          final labels = [
            for (final time in ['01:23', '16:40'])
              find.descendant(of: overlay, matching: find.text(time)),
          ];
          final elapsed = tester.getRect(labels.first);
          final total = tester.getRect(labels.last);
          final slider = tester.getRect(find.byType(PlayerProgressSlider));
          final video = tester.getRect(find.byType(Video));
          expect(video, const Rect.fromLTWH(0, 0, 1024, 640));
          expect(elapsed.right, slider.left);
          expect(total.left, slider.right);
          expect(elapsed.center.dy, total.center.dy);

          final surface = playerTheme.colorScheme.surface;
          final foregrounds = [
            for (final label in labels)
              (tester
                          .renderObject<RenderParagraph>(
                            find.descendant(
                              of: label,
                              matching: find.byType(RichText),
                            ),
                          )
                          .text
                      as TextSpan)
                  .style!
                  .color!,
          ];
          final contrasts = [
            for (final foreground in foregrounds)
              (foreground.computeLuminance() + 0.05) /
                  (surface.computeLuminance() + 0.05),
          ];
          // ignore: avoid_print
          print(
            'seek-times $mode ${brightness.name}: foregrounds=$foregrounds '
            'surface=$surface contrast=$contrasts elapsed=$elapsed total=$total '
            'slider=$slider video=$video',
          );
          if (capture != null) {
            await _capturePlayer(
              tester,
              capture,
              'player-time/$_playerTimeCapture',
            );
          }
          await unmount(tester);
          expect(tester.takeException(), isNull);
          expect(contrasts, everyElement(greaterThanOrEqualTo(4.5)));
          expect(
            foregrounds,
            everyElement(playerTheme.textTheme.bodyMedium!.color),
          );
        },
      );
    }
  }

  for (final startsHidden in [false, true]) {
    testWidgets(
      'Player keyboard focus stays visible (startsHidden: $startsHidden)',
      (tester) async {
        debugOsdClockOverride = DateTime(2026, 11, 28, 12, 34, 56);
        addTearDown(() => debugOsdClockOverride = null);
        final f = fixture();
        final capture = startsHidden && _playerFocusCapture.isNotEmpty
            ? GlobalKey()
            : null;
        final media = await mount(
          tester,
          PlayerPage(state: f.state, request: f.session.request),
          capture: capture,
          theme: buildAppTheme(Brightness.dark),
        );
        final overlay = find.byType(PlayerControlOverlay);
        final osd = find.byType(PlayerOsdLayer);
        bool visible() => tester.widget<PlayerOsdLayer>(osd).controlsVisible;
        if (startsHidden) {
          await tester.pump(_playerIdle);
          await tester.pumpAndSettle();
        }
        expect(visible(), !startsHidden);
        final fullscreen = find.byTooltip('全屏（F11）');
        windowManagerCalls.clear();

        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pumpAndSettle();
        expect(_focusWithin(tester, overlay), isTrue);
        final visibleOnEntry = visible();
        for (var i = 0; i < 25 && !_focusWithin(tester, fullscreen); i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pump();
        }
        expect(_focusWithin(tester, fullscreen), isTrue);
        await tester.pump(_playerIdle);
        await tester.pumpAndSettle();
        if (capture != null) {
          await _capturePlayer(
            tester,
            capture,
            'player-focus/$_playerFocusCapture',
          );
        }
        expect(
          visibleOnEntry,
          isTrue,
          reason: 'first Tab needs a visible target',
        );
        expect(visible(), isTrue, reason: 'focused controls cannot fade away');
        expect(fullscreen.hitTestable(), findsOneWidget);
        expect(_focusWithin(tester, fullscreen), isTrue);
        expect(
          windowManagerCalls,
          isEmpty,
          reason: 'focus alone must not activate',
        );
        expect(media.opened, hasLength(1));
        expect(media.state.position, const Duration(seconds: 1));

        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(
          windowManagerCalls.map((c) => c.method),
          contains('setFullScreen'),
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.f10);
        await tester.pump(_playerIdle);
        await tester.pumpAndSettle();
        expect(find.byType(PlayerContextMenu), findsOneWidget);
        expect(visible(), isTrue);
        windowManagerCalls.clear();
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byType(PlayerContextMenu), findsNothing);
        expect(windowManagerCalls, isEmpty);
        expect(_focusWithin(tester, fullscreen), isTrue);
        await unmount(tester);
      },
    );
  }

  testWidgets('Mouse idle hides player controls and leaves video clickable', (
    tester,
  ) async {
    final f = fixture();
    await mount(tester, PlayerPage(state: f.state, request: f.session.request));
    final fullscreen = find.byTooltip('全屏（F11）');
    final target = tester.getCenter(fullscreen);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: target);
    addTearDown(mouse.removePointer);
    await tester.tapAt(target, kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(windowManagerCalls.map((c) => c.method), contains('setFullScreen'));
    expect(fullscreen.hitTestable(), findsOneWidget);
    await tester.pump(_playerIdle);
    await tester.pumpAndSettle();
    expect(fullscreen.hitTestable(), findsNothing);
    await tester.tapAt(
      target,
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
    expect(find.byType(PlayerContextMenu), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.pump(_playerIdle);
    await tester.pumpAndSettle();
    expect(fullscreen.hitTestable(), findsNothing);
    await mouse.moveTo(const Offset(550, 330));
    await tester.pumpAndSettle();
    expect(fullscreen.hitTestable(), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(_focusWithin(tester, find.byType(PlayerControlOverlay)), isTrue);
    await tester.tapAt(target, kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    await tester.pump(_playerIdle);
    await tester.pumpAndSettle();
    expect(fullscreen.hitTestable(), findsNothing);
    await unmount(tester);
  });

  testWidgets('Tab can leave player controls for the live chooser', (
    tester,
  ) async {
    final f = fixture();
    final media = await mount(
      tester,
      PlayerPage(
        state: f.state,
        request: f.session.request,
        liveSession: f.session,
      ),
    );
    final fullscreen = find.byTooltip('全屏（F11）');
    final chooser = find.byKey(const ValueKey('player-live-panel-toggle'));
    for (final target in [fullscreen, chooser]) {
      for (var i = 0; i < 25 && !_focusWithin(tester, target); i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
      }
      expect(_focusWithin(tester, target), isTrue);
    }
    await tester.pump(_playerIdle);
    await tester.pumpAndSettle();
    expect(fullscreen.hitTestable(), findsNothing);
    expect(chooser.hitTestable(), findsOneWidget);
    expect(media.opened, hasLength(1));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byType(PlayerLivePanel), findsOneWidget);
    expect(
      tester
          .widget<PlayerOsdLayer>(find.byType(PlayerOsdLayer))
          .controlsVisible,
      isTrue,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(PlayerLivePanel), findsNothing);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'player');
    await unmount(tester);
  });

  testWidgets('Player keyboard focus excludes the collapsed audio AI sheet', (
    tester,
  ) async {
    tester.platformDispatcher.textScaleFactorTestValue = 0.65;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final f = fixture();
    await mount(tester, PlayerPage(state: f.state, request: f.session.request));
    await tester.runAsync(
      () => tester.tap(find.byKey(const ValueKey('player-audio-ai'))),
    );
    final panel = find.byType(PlayerAudioAiPanel);
    for (var i = 0; i < 20 && panel.evaluate().isEmpty; i++) {
      await flush(tester);
    }
    expect(panel, findsOneWidget);
    final language = find.widgetWithText(TextFormField, '原音语言代码');
    await tester.enterText(language, 'ja');
    final editor = find.descendant(
      of: language,
      matching: find.byType(EditableText),
    );
    expect(tester.widget<EditableText>(editor).controller.text, 'ja');
    expect(_focusWithin(tester, editor), isTrue);

    final close = find.byTooltip('收起音频AI面板');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    try {
      for (var i = 0; i < 20 && !_focusWithin(tester, close); i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
      }
    } finally {
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    }
    expect(_focusWithin(tester, close), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(panel, findsNothing);
    final collapsedClose = find.byWidgetPredicate(
      (widget) => widget is IconButton && widget.tooltip == '收起音频AI面板',
      skipOffstage: false,
    );
    final collapsedPanel = find.byType(PlayerAudioAiPanel, skipOffstage: false);
    expect(collapsedPanel, findsOneWidget);
    expect(_focusWithin(tester, collapsedClose), isFalse);
    for (var i = 0; i < 25; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(_focusWithin(tester, collapsedClose), isFalse);
      expect(_focusWithin(tester, collapsedPanel), isFalse);
    }
    await tester.tap(find.byKey(const ValueKey('player-audio-ai')));
    await tester.pumpAndSettle();
    expect(panel, findsOneWidget);
    expect(tester.widget<EditableText>(editor).controller.text, 'ja');
    await tester.enterText(language, 'ko');
    expect(tester.widget<EditableText>(editor).controller.text, 'ko');
    expect(_focusWithin(tester, editor), isTrue);
    await unmount(tester);
  });

  testWidgets('Live clock stays clear of the always-available chooser', (
    tester,
  ) async {
    debugOsdClockOverride = DateTime(2026, 11, 28, 12, 34, 56);
    addTearDown(() => debugOsdClockOverride = null);
    final f = fixture();
    final page = PlayerPage(
      state: f.state,
      request: f.session.request,
      liveSession: f.session,
    );
    final capture = _liveClockCapture.isEmpty ? null : GlobalKey();
    await mount(tester, page, capture: capture);
    expect(
      await tester.runAsync(() => f.state.setOsdFlag(OsdFlag.time, true)),
      isTrue,
    );
    await tester.pump();

    final osd = find.byType(PlayerOsdLayer);
    final clock = find.descendant(of: osd, matching: find.text('12:34:56'));
    final chooser = find.byKey(const ValueKey('player-live-panel-toggle'));
    final video = find.byType(Video);
    final videoRect = tester.getRect(video);
    expect(videoRect, const Rect.fromLTWH(0, 0, 1024, 640));
    expect(tester.widget<PlayerOsdLayer>(osd).controlsVisible, isTrue);
    expect(tester.widget<PlayerOsdLayer>(osd).flags[OsdFlag.time], isTrue);
    expect(clock, findsOneWidget);
    expect(chooser.hitTestable(), findsOneWidget);
    if (capture != null) {
      await _capturePlayer(tester, capture, 'playback-clock/$_liveClockCapture');
    }

    final clockRect = tester.getRect(clock);
    final chooserRect = tester.getRect(chooser);
    // ignore: avoid_print
    print(
      'live-clock visible: clock=$clockRect chooser=$chooserRect video=$videoRect',
    );
    expect(
      clockRect.overlaps(chooserRect),
      isFalse,
      reason: 'clock=$clockRect chooser=$chooserRect',
    );

    await tester.tap(chooser);
    await tester.pump();
    expect(find.byType(PlayerLivePanel), findsOneWidget);
    expect(tester.getRect(video), videoRect);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byType(PlayerLivePanel), findsNothing);
    expect(tester.getRect(video), videoRect);

    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(tester.widget<PlayerOsdLayer>(osd).controlsVisible, isFalse);
    expect(tester.getRect(clock).overlaps(tester.getRect(chooser)), isFalse);
    expect(tester.getRect(chooser), chooserRect);
    expect(tester.getRect(video), videoRect);
    expect(chooser.hitTestable(), findsOneWidget);

    expect(
      await tester.runAsync(() => f.state.setOsdFlag(OsdFlag.time, false)),
      isTrue,
    );
    await tester.pump(const Duration(seconds: 1));
    expect(clock, findsNothing);
    expect(tester.getRect(chooser), chooserRect);
    expect(chooser.hitTestable(), findsOneWidget);
    expect(tester.getRect(video), videoRect);
    await unmount(tester);
    expect(tester.takeException(), isNull);
  });
  for (final size in [
    const Size(800, 600),
    const Size(1024, 640),
    const Size(1440, 900),
  ]) {
    testWidgets('${size.width}直播线路槽和常驻抽屉不改变画面尺寸，Esc恢复焦点', (tester) async {
      final f = fixture();
      await mount(
        tester,
        PlayerPage(
          state: f.state,
          request: f.session.request,
          liveSession: f.session,
        ),
        size: size,
      );
      final title = tester.widget<AppBar>(find.byType(AppBar)).title as Text;
      expect(title.data, 'CCTV-5');
      expect(
        tester.widget<PlayerOsdLayer>(find.byType(PlayerOsdLayer)).title,
        'CCTV-5',
      );
      expect(find.text('线路（2）'), findsOneWidget);
      expect(find.textContaining('选集（'), findsNothing);
      final launcher = find.byKey(const ValueKey('player-live-panel-toggle'));
      final launcherPane = find.ancestor(
        of: launcher,
        matching: find.byType(GlassPane),
      );
      expect(launcherPane, findsOneWidget);
      expect(tester.widget<GlassPane>(launcherPane).blurBackdrop, isFalse);
      final rect = tester.getRect(find.byType(Video));
      await tester.tap(find.byKey(const ValueKey('player-live-panel-toggle')));
      await tester.pump();
      expect(find.byType(PlayerLivePanel), findsOneWidget);
      expect(tester.getRect(find.byType(Video)), rect);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byType(PlayerLivePanel), findsNothing);
      await tester.tap(find.text('线路（2）'));
      await tester.pump();
      expect(find.byType(PlayerLivePanel), findsOneWidget);
      expect(
        find.byKey(const ValueKey('player-live-source-list')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('player-live-channel-list')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('live-line-1')), findsOneWidget);
      expect(tester.getRect(find.byType(Video)), rect);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byType(PlayerLivePanel), findsNothing);
      expect(
        windowManagerCalls.where((call) => call.method == 'setFullScreen'),
        isEmpty,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await flush(tester);
      expect(f.session.channel.name, '频道二');
      expect(tester.getRect(find.byType(Video)), rect);
      await unmount(tester);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('直播PgDown跨分组重建Header；弹窗输入时不误切台', (tester) async {
    final f = fixture();
    final media = await mount(
      tester,
      PlayerPage(
        state: f.state,
        request: f.session.request,
        liveSession: f.session,
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await flush(tester);
    expect(media.opened.last, 'https://fixture.test/c');
    expect(media.openedHeaders.last, {'User-Agent': 'second-agent'});
    expect(f.session.channel.name, '频道二');
    final context = tester.element(find.byType(PlayerPage));
    unawaited(
      showDialog<void>(
        context: context,
        builder: (_) => const AlertDialog(content: TextField(autofocus: true)),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.pump();
    expect(media.opened.last, 'https://fixture.test/c');
    Navigator.of(context).pop();
    await tester.pump();
    await unmount(tester);
    expect(tester.takeException(), isNull);
  });
  testWidgets('直播上下台和播完不轮播线路，点播选集保持', (tester) async {
    final f = fixture();
    final media = await mount(
      tester,
      PlayerPage(
        state: f.state,
        request: f.session.request,
        liveSession: f.session,
      ),
    );
    media.progress(1000, completed: true);
    await flush(tester);
    expect(media.opened.length, 1);
    await tester.tap(find.byTooltip('下一台（PgDn）'));
    await flush(tester);
    expect(media.opened.last, 'https://fixture.test/c');
    await unmount(tester);
  });
  testWidgets('没有session的directUrl仍按点播呈现，不自动当直播', (tester) async {
    debugOsdClockOverride = DateTime(2026, 11, 28, 12, 34, 56);
    addTearDown(() => debugOsdClockOverride = null);
    final f = fixture();
    await mount(tester, PlayerPage(state: f.state, request: f.session.request));
    final osd = find.byType(PlayerOsdLayer);
    final clock = find.descendant(of: osd, matching: find.text('12:34:56'));
    expect(tester.getRect(clock).topRight, const Offset(1008, 64));
    expect(find.text('选集（2）'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('player-live-panel-toggle')),
      findsNothing,
    );
    expect(find.byTooltip('下一集（]）'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(tester.widget<PlayerOsdLayer>(osd).controlsVisible, isFalse);
    expect(tester.getRect(clock).topRight, const Offset(1008, 16));
    await unmount(tester);
  });
  testWidgets('回看保持seek，不自动连播，回直播恢复原线路', (tester) async {
    final f = fixture(
      initialProgram: const EpgProgram(
        title: '回看节目',
        startMs: 1700000000000,
        stopMs: 1700003600000,
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
    final title = tester.widget<AppBar>(find.byType(AppBar)).title as Text;
    expect(title.data, 'CCTV-5 · 回看节目');
    expect(
      tester.widget<PlayerOsdLayer>(find.byType(PlayerOsdLayer)).title,
      'CCTV-5 · 回看节目',
    );
    expect(find.text('回到直播'), findsOneWidget);
    expect(find.text('线路（1）'), findsNothing);
    expect(find.text('选集（1）'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(media.state.position, const Duration(seconds: 11));
    media.progress(1000, completed: true);
    await flush(tester);
    expect(media.opened.length, 1);
    await tester.tap(find.text('回到直播'));
    await flush(tester);
    expect(media.opened.last, 'https://fixture.test/b');
    expect(f.session.program, isNull);
    expect(find.text('线路（2）'), findsOneWidget);
    await unmount(tester);
  });
  testWidgets('最后单线路失败跨源与标题抽屉同步，不误匹配CCTV5+', (tester) async {
    final f = fixture();
    final source = LiveSource(name: '替代源', type: 1);
    f.state.sources = [...f.state.sources, source];
    f.service.loads[source.name] = () async => LivePlaylist(
      sourceName: source.name,
      groups: [
        LiveGroup(
          name: '体育',
          channels: [
            LiveChannel(name: 'CCTV5+', urls: ['https://fixture.test/wrong']),
            LiveChannel(
              name: 'CCTV5',
              urls: ['https://fixture.test/fallback'],
              header: HeaderMap({'User-Agent': 'fallback-agent'}),
            ),
          ],
        ),
      ],
    );
    final media = await mount(
      tester,
      PlayerPage(
        state: f.state,
        request: f.session.request,
        liveSession: f.session,
      ),
      failed: {'https://fixture.test/b'},
    );
    await flush(tester);
    expect(media.opened, [
      'https://fixture.test/b',
      'https://fixture.test/fallback',
    ]);
    expect(media.openedHeaders.last, {'User-Agent': 'fallback-agent'});
    expect(f.session.source.name, '替代源');
    await tester.tap(find.byKey(const ValueKey('player-live-panel-toggle')));
    await tester.pump();
    expect(find.text('正在播放 · 替代源'), findsOneWidget);
    await unmount(tester);
  });
  testWidgets('过期跨源失败不能回滚新手动频道请求', (tester) async {
    final f = fixture();
    final source = LiveSource(name: '慢源', type: 1);
    f.state.sources = [...f.state.sources, source];
    final gate = Completer<LivePlaylist>();
    f.service.loads[source.name] = () => gate.future;
    final media = await mount(
      tester,
      PlayerPage(
        state: f.state,
        request: f.session.request,
        liveSession: f.session,
      ),
      failed: {'https://fixture.test/b'},
    );
    f.session.stepChannel(1);
    await flush(tester);
    expect(media.opened.last, 'https://fixture.test/c');
    gate.complete(LivePlaylist(sourceName: source.name));
    await flush(tester);
    expect(f.session.channel.name, '频道二');
    expect(find.textContaining('频道二'), findsWidgets);
    expect(find.textContaining('播放失败'), findsNothing);
    expect(media.opened.last, 'https://fixture.test/c');
    await unmount(tester);
    expect(tester.takeException(), isNull);
  });
  testWidgets('媒体open在途挂起不阻塞最新频道，迟到旧引擎不能覆盖', (tester) async {
    final f = fixture();
    final media = await mount(
      tester,
      PlayerPage(
        state: f.state,
        request: f.session.request,
        liveSession: f.session,
      ),
    );
    final gate = Completer<void>();
    media.gates['https://fixture.test/a'] = gate;
    f.session.selectLine(0);
    await tester.pump(const Duration(milliseconds: 100));
    f.session.stepChannel(1);
    await flush(tester);
    final whilePending = media.opened.last;
    gate.complete();
    await flush(tester);
    expect(whilePending, 'https://fixture.test/c');
    expect(media.opened.last, 'https://fixture.test/c');
    expect(f.session.channel.name, '频道二');
    expect(media.openedHeaders.last, {'User-Agent': 'second-agent'});
    await unmount(tester);
    expect(tester.takeException(), isNull);
  });
  testWidgets('网络失败重试窗口切台取消旧URL重试，最新请求立即播放', (tester) async {
    final f = fixture();
    final media = await mount(
      tester,
      PlayerPage(
        state: f.state,
        request: f.session.request,
        liveSession: f.session,
      ),
    );
    media.failureMessages['https://fixture.test/a'] = 'failed to connect';
    f.session.selectLine(0);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 100));
    f.session.stepChannel(1);
    await flush(tester);
    await tester.pump(const Duration(seconds: 1));
    await flush(tester);
    expect(media.opened, [
      'https://fixture.test/b',
      'https://fixture.test/a',
      'https://fixture.test/c',
    ]);
    expect(f.session.channel.name, '频道二');
    await unmount(tester);
    expect(tester.takeException(), isNull);
  });
  testWidgets('控制器原生open有界超时且释放后无残留timer', (tester) async {
    installMediaKitMocks(tester);
    final player = Player();
    final journal = MediaJournal();
    final media = MediaIO(player.platform!, journal);
    player.platform = media;
    final controller = PlayerController(player: player);
    final gate = Completer<void>();
    media.gates['https://fixture.test/native-timeout'] = gate;
    PlayerLoadOutcome? result;
    unawaited(
      controller
          .open(
            'https://fixture.test/native-timeout',
            timeout: const Duration(milliseconds: 100),
            awaitFirstFrame: false,
            isCurrent: () => true,
          )
          .then((outcome) => result = outcome),
    );
    await tester.pump(const Duration(milliseconds: 150));
    await flush(tester);
    expect(result?.failureKind, PlayerFailureKind.timeout);
    expect(controller.hasPendingNativeOpen, isTrue);
    controller.dispose();
    gate.complete();
    await flush(tester);
    expect(tester.takeException(), isNull);
  });
  testWidgets('控制器isCurrent过期直接取消重试而非依赖dispose', (tester) async {
    installMediaKitMocks(tester);
    final player = Player();
    final journal = MediaJournal()
      ..failureMessages['https://fixture.test/network'] = 'failed to connect';
    final media = MediaIO(player.platform!, journal);
    player.platform = media;
    final controller = PlayerController(player: player);
    var current = true;
    PlayerLoadOutcome? result;
    unawaited(
      controller
          .openWithRetry(
            'https://fixture.test/network',
            isCurrent: () => current,
          )
          .then((outcome) => result = outcome),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    current = false;
    await tester.pump(const Duration(seconds: 1));
    await flush(tester);
    expect(result?.succeeded, isFalse);
    expect(journal.opened, ['https://fixture.test/network']);
    controller.dispose();
    await flush(tester);
    expect(tester.takeException(), isNull);
  });
  testWidgets('同一帧连续PgDn合并到最新意图，不重复打开中间频道', (tester) async {
    final f = fixture();
    final media = await mount(
      tester,
      PlayerPage(
        state: f.state,
        request: f.session.request,
        liveSession: f.session,
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await flush(tester);
    expect(media.opened, ['https://fixture.test/b', 'https://fixture.test/a']);
    expect(f.session.channel.name, 'CCTV-5');
    await unmount(tester);
    expect(tester.takeException(), isNull);
  });
  testWidgets('dispose早于native timeout且gate永不完成，旧open Future仍终止', (
    tester,
  ) async {
    installMediaKitMocks(tester);
    final player = Player();
    final journal = MediaJournal();
    final media = MediaIO(player.platform!, journal);
    player.platform = media;
    final controller = PlayerController(player: player);
    final gate = Completer<void>();
    media.gates['https://fixture.test/never-completes'] = gate;
    PlayerLoadOutcome? result;
    unawaited(
      controller
          .open(
            'https://fixture.test/never-completes',
            timeout: const Duration(seconds: 1),
            awaitFirstFrame: false,
            isCurrent: () => true,
          )
          .then((outcome) => result = outcome),
    );
    await tester.pump(const Duration(milliseconds: 50));
    controller.dispose();
    await flush(tester);
    expect(gate.isCompleted, isFalse);
    expect(result?.succeeded, isFalse, reason: '取消timer不能使外部open永久挂起');
    await tester.pump(const Duration(seconds: 2));
    await flush(tester);
    expect(tester.takeException(), isNull);
  });
  testWidgets('静音前25音量在直播引擎隔离后取消静音仍恢复25', (tester) async {
    final f = fixture();
    final media = await mount(
      tester,
      PlayerPage(
        state: f.state,
        request: f.session.request,
        liveSession: f.session,
      ),
    );
    final volumeSlider = tester
        .widgetList<Slider>(find.byType(Slider))
        .singleWhere((slider) => slider.max == 100);
    volumeSlider.onChanged!(25);
    await flush(tester);
    await tester.tap(find.byTooltip('静音（M）'));
    await tester.pump();
    final gate = Completer<void>();
    media.gates['https://fixture.test/a'] = gate;
    f.session.selectLine(0);
    await tester.pump(const Duration(milliseconds: 100));
    f.session.stepChannel(1);
    await flush(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    await flush(tester);
    final restored = tester
        .widget<Video>(find.byType(Video))
        .controller
        .player
        .state
        .volume;
    gate.complete();
    await flush(tester);
    expect(restored, 25);
    await unmount(tester);
    expect(tester.takeException(), isNull);
  });
  test('直播状态与在线人数使用固定分隔符，不混入频道标题', () {
    expect(formatPlayerLiveStatus(status: '已连接', online: 100), '已连接 · 在线 100');
    expect(formatPlayerLiveStatus(online: 100), '在线 100');
    expect(formatPlayerLiveStatus(status: '连接中'), '连接中');
  });
}
