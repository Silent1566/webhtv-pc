import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/player_options.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/ui_preferences_store.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/settings_detail_pages.dart';
import 'package:webhtv_pc/ui/theme.dart';
import 'package:webhtv_pc/ui/settings_layout.dart';

const _captureKey = ValueKey('double-click-settings-capture');
const _labels = <PlayerDoubleClickAction, String>{
  PlayerDoubleClickAction.toggleFullscreen: '切换全屏',
  PlayerDoubleClickAction.togglePlayback: '播放 / 暂停',
  PlayerDoubleClickAction.seekBackward: '快退',
  PlayerDoubleClickAction.seekForward: '快进',
  PlayerDoubleClickAction.volumeUp: '音量增加',
  PlayerDoubleClickAction.volumeDown: '音量减少',
  PlayerDoubleClickAction.none: '无动作',
};

Finder _menu(String side) =>
    find.byKey(ValueKey('settings-player-double-click-$side-menu'));

Future<void> _select(
  WidgetTester tester,
  String side,
  PlayerDoubleClickAction action,
) async {
  final menu = _menu(side);
  await tester.ensureVisible(menu);
  await tester.pumpAndSettle();
  await tester.tap(menu);
  await tester.pumpAndSettle();
  await tester.tap(find.text(_labels[action]!).last);
  await tester.pumpAndSettle();
}

void main() {
  late Directory temp;
  late AppPaths paths;
  late AppState state;
  late UiPreferencesStore store;
  late String settingsPath;

  setUpAll(() async {
    final fontPath = Platform.environment['SETTINGS_CJK_FONT'];
    if (fontPath != null) {
      final bytes = File(fontPath).readAsBytesSync();
      final loader = FontLoader('Roboto')
        ..addFont(Future.value(ByteData.sublistView(bytes)));
      await loader.load();
      final icons = FontLoader('MaterialIcons')
        ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await icons.load();
    }
  });

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('webhtv-double-click-settings-');
    paths = AppPaths.resolve(
      overrides: {
        'config': '${temp.path}/config',
        'data': '${temp.path}/data',
        'cache': '${temp.path}/cache',
        'state': '${temp.path}/logs',
      },
    );
    settingsPath = '${temp.path}/settings.json';
    store = UiPreferencesStore(path: settingsPath);
    await store.load();
    state = AppState(paths: paths, log: LogService());
    state.attachUiPreferences(store);
  });

  tearDown(() {
    state.dispose();
    expect(temp.absolute.path, startsWith(Directory.systemTemp.absolute.path));
    expect(
      temp.path.split(Platform.pathSeparator).last,
      startsWith('webhtv-double-click-settings-'),
    );
    temp.deleteSync(recursive: true);
  });

  Future<void> pumpPage(
    WidgetTester tester, {
    Size size = const Size(1280, 800),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      RepaintBoundary(
        key: _captureKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(Brightness.dark),
          home: PlaybackOptionsPage(state: state),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> expectSaved(WidgetTester tester, PlayerOptions options) async {
    final reloaded = UiPreferencesStore(path: settingsPath);
    await tester.runAsync(() async {
      // Allow the real-zone write queue to finish before reading the file.
      await Future<void>.delayed(Duration.zero);
      await reloaded.load();
    });
    await tester.pumpAndSettle();
    expect(reloaded.playerOptions, options);
  }

  testWidgets('default side controls expose all seven actions and help', (
    tester,
  ) async {
    await pumpPage(tester);
    expect(find.text('左半屏双击'), findsOneWidget);
    expect(find.text('右半屏双击'), findsOneWidget);
    expect(find.textContaining('单击'), findsWidgets);
    expect(find.textContaining('直播'), findsWidgets);
    for (final side in ['left', 'right']) {
      final dropdown = tester.widget<DropdownButton<PlayerDoubleClickAction>>(
        _menu(side),
      );
      expect(dropdown.value, PlayerDoubleClickAction.toggleFullscreen);
      expect(dropdown.items!.map((item) => item.value), _labels.keys);
      await tester.tap(_menu(side));
      await tester.pumpAndSettle();
      for (final label in _labels.values) {
        expect(find.text(label), findsWidgets);
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'left and right changes save immediately without losing options',
    (tester) async {
      final initial = const PlayerOptions.defaults().copyWith(
        hardwareDecoding: false,
        autoNext: false,
        preloadNext: true,
        longPressSpeed: 3.5,
        demuxerMaxBytesMiB: 256,
        doubleClickRight: PlayerDoubleClickAction.volumeDown,
      );
      await tester.runAsync(() => state.setPlayerOptions(initial));
      await pumpPage(tester);

      await _select(tester, 'left', PlayerDoubleClickAction.seekBackward);
      final leftChanged = initial.copyWith(
        doubleClickLeft: PlayerDoubleClickAction.seekBackward,
      );
      expect(state.playerOptions.toJson(), leftChanged.toJson());
      await expectSaved(tester, leftChanged);
      expect(
        tester
            .widget<DropdownButton<PlayerDoubleClickAction>>(_menu('left'))
            .value,
        PlayerDoubleClickAction.seekBackward,
      );
      expect(
        tester
            .widget<DropdownButton<PlayerDoubleClickAction>>(_menu('right'))
            .value,
        PlayerDoubleClickAction.volumeDown,
      );

      await _select(tester, 'right', PlayerDoubleClickAction.seekForward);
      final bothChanged = leftChanged.copyWith(
        doubleClickRight: PlayerDoubleClickAction.seekForward,
      );
      expect(state.playerOptions.toJson(), bothChanged.toJson());
      await expectSaved(tester, bothChanged);
      final raw = jsonDecode(File(settingsPath).readAsStringSync()) as Map;
      expect((raw['player'] as Map)['doubleClickLeft'], 'seekBackward');
      expect((raw['player'] as Map)['doubleClickRight'], 'seekForward');
    },
  );

  testWidgets(
    'reopening page and reloading the real store keeps both choices',
    (tester) async {
      await pumpPage(tester);
      await _select(tester, 'left', PlayerDoubleClickAction.togglePlayback);
      await _select(tester, 'right', PlayerDoubleClickAction.none);
      await expectSaved(tester, state.playerOptions);
      await tester.pumpWidget(const SizedBox.shrink());
      await pumpPage(tester);
      expect(
        tester
            .widget<DropdownButton<PlayerDoubleClickAction>>(_menu('left'))
            .value,
        PlayerDoubleClickAction.togglePlayback,
      );
      expect(
        tester
            .widget<DropdownButton<PlayerDoubleClickAction>>(_menu('right'))
            .value,
        PlayerDoubleClickAction.none,
      );

      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
      store = UiPreferencesStore(path: settingsPath);
      await tester.runAsync(store.load);
      state = AppState(paths: paths, log: LogService())
        ..attachUiPreferences(store);
      await pumpPage(tester);
      expect(
        tester
            .widget<DropdownButton<PlayerDoubleClickAction>>(_menu('left'))
            .value,
        PlayerDoubleClickAction.togglePlayback,
      );
      expect(
        tester
            .widget<DropdownButton<PlayerDoubleClickAction>>(_menu('right'))
            .value,
        PlayerDoubleClickAction.none,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('every action is selectable on either side including seek', (
    tester,
  ) async {
    await pumpPage(tester);
    for (final side in ['left', 'right']) {
      for (final action in _labels.keys) {
        final otherBefore = side == 'left'
            ? state.playerOptions.doubleClickRight
            : state.playerOptions.doubleClickLeft;
        await _select(tester, side, action);
        expect(
          side == 'left'
              ? state.playerOptions.doubleClickLeft
              : state.playerOptions.doubleClickRight,
          action,
        );
        expect(
          side == 'left'
              ? state.playerOptions.doubleClickRight
              : state.playerOptions.doubleClickLeft,
          otherBefore,
        );
        await expectSaved(tester, state.playerOptions);
      }
    }
  });

  testWidgets('side labels are accessible and native menu accepts keyboard', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await pumpPage(tester);
      expect(find.bySemanticsLabel(RegExp('左半屏双击')), findsWidgets);
      expect(find.bySemanticsLabel(RegExp('右半屏双击')), findsWidgets);
      for (var tabs = 0; tabs < 12; tabs++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pumpAndSettle();
        final focused = FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<
              SettingsDropdown<PlayerDoubleClickAction>
            >();
        if (focused?.key ==
            const ValueKey('settings-player-double-click-left-menu')) {
          break;
        }
      }
      final focused = FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<
            SettingsDropdown<PlayerDoubleClickAction>
          >();
      expect(
        focused?.key,
        const ValueKey('settings-player-double-click-left-menu'),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(
        state.playerOptions.doubleClickLeft,
        PlayerDoubleClickAction.togglePlayback,
      );
      expect(
        state.playerOptions.doubleClickRight,
        PlayerDoubleClickAction.toggleFullscreen,
      );
      await expectSaved(tester, state.playerOptions);
    } finally {
      semantics.dispose();
    }
  });

  for (final size in [const Size(1280, 800), const Size(1024, 640)]) {
    testWidgets('dark render ${size.width.toInt()}x${size.height.toInt()}', (
      tester,
    ) async {
      await pumpPage(tester, size: size);
      expect(tester.takeException(), isNull);
      final phase = Platform.environment['SETTINGS_CAPTURE_PHASE'];
      if (phase == null) {
        expect(_menu('left').hitTestable(), findsOneWidget);
        expect(_menu('right').hitTestable(), findsOneWidget);
        await _select(tester, 'right', PlayerDoubleClickAction.volumeUp);
        await expectSaved(tester, state.playerOptions);
        expect(tester.takeException(), isNull);
        return;
      }
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(_captureKey),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1);
        try {
          expect(image.width, size.width.toInt());
          expect(image.height, size.height.toInt());
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final output = Directory(
            '../../.superpowers/sdd/double-click-areas/settings',
          )..createSync(recursive: true);
          File('${output.path}/$phase-${image.width}x${image.height}-dark.png')
              .writeAsBytesSync(bytes!.buffer.asUint8List());
        } finally {
          image.dispose();
        }
      });
    });
  }
}
