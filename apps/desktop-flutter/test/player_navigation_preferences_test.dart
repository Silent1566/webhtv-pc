import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/player_options.dart';
import 'package:webhtv_pc/services/ui_preferences_store.dart';
import 'package:webhtv_pc/ui/settings_detail_pages.dart';
import 'package:webhtv_pc/ui/theme.dart';

import 'live_playback_session_test.dart' show fixture;
import 'support/test_fonts.dart';

const evidence = '../../.superpowers/sdd/12-player-navigation-plan/task-3';

Future<void> loadCaptureFonts() async {
  await loadFixtureFonts(cjkFamily: 'Noto Sans CJK SC');
  final cjk = firstExisting(cjkFontCandidates());
  if (cjk == null) throw StateError('Capture requires a readable CJK font');
  final bytes = ByteData.sublistView(await cjk.readAsBytes());
  for (final family in ['Roboto', 'Ahem', 'monospace']) {
    await (FontLoader(family)..addFont(Future.value(bytes))).load();
  }
}

ThemeData captureTheme() {
  final theme = buildAppTheme(Brightness.dark);
  TextStyle? readable(TextStyle? style) => style?.copyWith(
    fontFamily: 'Noto Sans CJK SC',
    fontFamilyFallback: const ['Noto Sans CJK SC'],
  );
  return theme.copyWith(
    textTheme: theme.textTheme.apply(fontFamily: 'Noto Sans CJK SC'),
    primaryTextTheme: theme.primaryTextTheme.apply(
      fontFamily: 'Noto Sans CJK SC',
    ),
    appBarTheme: theme.appBarTheme.copyWith(
      titleTextStyle: readable(theme.appBarTheme.titleTextStyle),
      toolbarTextStyle: readable(theme.appBarTheme.toolbarTextStyle),
    ),
    listTileTheme: theme.listTileTheme.copyWith(
      titleTextStyle: readable(theme.listTileTheme.titleTextStyle),
      subtitleTextStyle: readable(theme.listTileTheme.subtitleTextStyle),
      leadingAndTrailingTextStyle: readable(
        theme.listTileTheme.leadingAndTrailingTextStyle,
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadCaptureFonts);
  test('thumbnail defaults off for new, old and malformed preferences', () {
    for (final raw in [
      null,
      'invalid',
      {},
      {'cache': false},
      for (final value in [null, 'true', 1, [], {}])
        {'showThumbnailPreview': value},
    ]) {
      expect(
        PlayerOptions.fromJson(raw).toJson()['showThumbnailPreview'],
        false,
      );
    }
    expect(
      const PlayerOptions.defaults().toJson()['showThumbnailPreview'],
      false,
    );
  });

  test(
    'thumbnail and normalization survive round trip and hash set lookup',
    () {
      const selected = PlayerOptions(
        showThumbnailPreview: true,
        audioNormalization: true,
      );
      final restored = PlayerOptions.fromJson(selected.toJson()).normalized();
      expect(restored.showThumbnailPreview, true);
      expect(restored.audioNormalization, true);
      expect(restored, selected);
      expect({selected}.contains(restored), true);
      expect(
        {selected}.contains(restored.copyWith(showThumbnailPreview: false)),
        false,
      );
      expect(
        {selected}.contains(restored.copyWith(audioNormalization: false)),
        false,
      );
      final changedCache = restored.copyWith(cache: false);
      expect(changedCache.showThumbnailPreview, true);
      expect(changedCache.audioNormalization, true);
    },
  );

  test('thumbnail survives normalize, copy, equality and JSON round trip', () {
    final enabled = PlayerOptions.fromJson({'showThumbnailPreview': true});
    expect(enabled.toJson()['showThumbnailPreview'], true);
    expect(enabled.normalized().toJson()['showThumbnailPreview'], true);
    expect(
      enabled
          .copyWith(
            cache: false,
            longPressSpeed: 4,
            doubleClickLeft: PlayerDoubleClickAction.seekBackward,
            skipRemoteEnabled: false,
            lutPath: 'test.cube',
          )
          .toJson()['showThumbnailPreview'],
      true,
    );
    expect(PlayerOptions.fromJson(enabled.toJson()), enabled);
    expect(enabled, isNot(const PlayerOptions.defaults()));
    expect({enabled, const PlayerOptions.defaults()}, hasLength(2));
  });

  test('real preference store saves and reloads thumbnail without dropping other JSON', () async {
    final temp = Directory.systemTemp.createTempSync('navigation-preferences');
    addTearDown(() => temp.deleteSync(recursive: true));
    final path = '${temp.path}/settings.json';
    await File(path).writeAsString(
      jsonEncode({
        'ui': {'themeMode': 'dark'},
        'keep': 17,
      }),
    );
    final store = UiPreferencesStore(path: path);
    await store.load();
    expect(
      await store.rememberPlayerOptions(
        PlayerOptions.fromJson({'showThumbnailPreview': true}),
      ),
      true,
    );
    expect(
      await store.rememberPlayerOptions(
        store.playerOptions.copyWith(cache: false),
      ),
      true,
    );
    final disk = jsonDecode(await File(path).readAsString()) as Map;
    expect((disk['player'] as Map)['showThumbnailPreview'], true);
    expect(disk['keep'], 17);
    final reopened = UiPreferencesStore(path: path);
    await reopened.load();
    expect(reopened.playerOptions.toJson()['showThumbnailPreview'], true);
    expect(reopened.playerOptions.cache, false);
    await Directory(evidence).create(recursive: true);
    await File('$evidence/persisted-settings.json')
        .writeAsString(const JsonEncoder.withIndent('  ').convert(disk));
  });

  testWidgets('settings toggle uses AppState and other changes preserve it', (
    tester,
  ) async {
    final f = fixture();
    await tester.runAsync(f.state.bootstrap);
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const capture = ValueKey('navigation-settings-capture');
    await tester.pumpWidget(
      RepaintBoundary(
        key: capture,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: captureTheme(),
          home: PlaybackOptionsPage(state: f.state),
        ),
      ),
    );
    expect(find.text('导航栏缩略图'), findsOneWidget);
    expect(find.textContaining('可能增加网络请求'), findsOneWidget);
    final tile = find.byKey(
      const ValueKey('settings-player-thumbnail-preview'),
    );
    final toggle = find.descendant(of: tile, matching: find.byType(Switch));
    expect(tester.widget<Switch>(toggle).value, false);
    await tester.tap(toggle);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    expect(f.state.playerOptions.toJson()['showThumbnailPreview'], true);
    expect(tester.widget<Switch>(toggle).value, true);
    final hardware = find.descendant(
      of: find.byKey(const ValueKey('settings-player-hardware-decoding')),
      matching: find.byType(Switch),
    );
    await tester.tap(hardware);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    expect(f.state.playerOptions.toJson()['showThumbnailPreview'], true);
    await tester.tap(hardware);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(capture),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory(evidence).create(recursive: true);
      await File('$evidence/settings-after.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
