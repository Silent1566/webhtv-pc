import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/ui_preferences_store.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/settings_detail_pages.dart';
import 'package:webhtv_pc/ui/following_page.dart';
import 'package:webhtv_pc/ui/theme.dart';
import 'package:webhtv_pc/core/reader/reader_models.dart';
import 'package:webhtv_pc/services/reader/reader_preferences_store.dart';
import 'package:webhtv_pc/services/reader/reader_tts_controller.dart';
import 'package:webhtv_pc/services/reader/tts_engines.dart';
import 'package:webhtv_pc/ui/reader/reader_page.dart';

Future<AppState> isolatedState(
  WidgetTester tester, {
  AppState Function(AppPaths, LogService)? create,
}) async {
  final temp = Directory.systemTemp.createTempSync('forms-immediate-');
  final paths = AppPaths.resolve(
    overrides: {
      'config': '${temp.path}/config',
      'data': '${temp.path}/data',
      'cache': '${temp.path}/cache',
      'state': '${temp.path}/logs',
    },
  );
  final previous = LogService.logDirectoryOverride;
  LogService.logDirectoryOverride = paths.logDir;
  final state =
      create?.call(paths, LogService()) ??
      AppState(
        paths: paths,
        log: LogService(),
        externalPlayerDetector: () => const [],
      );
  addTearDown(() {
    state.dispose();
    LogService.logDirectoryOverride = previous;
    temp.deleteSync(recursive: true);
  });
  await tester.runAsync(state.bootstrap);
  return state;
}

Future<void> settleWrites(WidgetTester tester) async {
  for (var round = 0; round < 30; round++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 16)),
    );
  }
  await tester.pumpAndSettle();
}

Future<void> openForm(WidgetTester tester, Widget page) async {
  tester.view.physicalSize = const Size(560, 720);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(theme: buildAppTheme(Brightness.dark), home: page),
  );
  await tester.pumpAndSettle();
}

class _Engine implements TtsEngine {
  int voiceCalls = 0;
  int synthCalls = 0;
  @override
  Future<List<TtsVoice>> voices() async {
    voiceCalls++;
    return const [];
  }

  @override
  Future<TtsAudio> synthesize(String text, TtsOptions options) async {
    synthCalls++;
    return TtsAudio(Uint8List(0), 'wav');
  }

  @override
  void cancel() {}
  @override
  Future<void> dispose() async {}
}

class _Audio implements ReaderAudioOutput {
  @override
  Future<void> play(TtsAudio audio) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}

void main() {
  for (final kind in ['danmaku', 'proxy', 'doh']) {
    testWidgets(
      '$kind address commits while typing, rejects invalid and clears',
      (tester) async {
        final state = await isolatedState(tester);
        final page = switch (kind) {
          'danmaku' => DanmakuSourcePage(state: state),
          'proxy' => OutboundProxyPage(state: state),
          _ => DohSettingsPage(state: state),
        };
        final key = switch (kind) {
          'danmaku' => 'settings-danmaku-api',
          'proxy' => 'settings-outbound-proxy-default',
          _ => 'settings-doh-endpoint',
        };
        String current() => switch (kind) {
          'danmaku' => state.danmakuSettings.apiUrl,
          'proxy' => state.outboundProxy.defaultProxyUrl,
          _ => state.dohSettings.url,
        };
        await openForm(tester, page);
        final before = File(state.paths.settingsPath).readAsStringSync();
        await tester.tap(find.byKey(ValueKey(key)));
        await tester.pumpAndSettle();
        expect(File(state.paths.settingsPath).readAsStringSync(), before);
        final input = find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        );
        final valid = kind == 'proxy'
            ? 'http://127.0.0.1:7890'
            : 'https://example.test/service';
        await tester.enterText(input, valid);
        await settleWrites(tester);
        expect(current(), valid);
        await tester.enterText(input, 'https://');
        await settleWrites(tester);
        expect(current(), valid);
        expect(
          tester.widget<TextField>(input).decoration!.errorText,
          isNotNull,
        );
        await tester.enterText(input, '');
        await settleWrites(tester);
        expect(current(), '');
        expect(find.text('取消'), findsNothing);
        expect(find.text('保存'), findsNothing);
        await tester.tap(find.text('关闭'));
        await settleWrites(tester);
        expect(current(), '');
      },
    );
  }
  for (final kind in ['danmaku', 'proxy', 'doh']) {
    testWidgets(
      '$kind write failure survives invalid drafts and equivalent retries',
      (tester) async {
        final state = await isolatedState(tester);
        final page = switch (kind) {
          'danmaku' => DanmakuSourcePage(state: state),
          'proxy' => OutboundProxyPage(state: state),
          _ => DohSettingsPage(state: state),
        };
        final key = switch (kind) {
          'danmaku' => 'settings-danmaku-api',
          'proxy' => 'settings-outbound-proxy-default',
          _ => 'settings-doh-endpoint',
        };
        await openForm(tester, page);
        await tester.tap(find.byKey(ValueKey(key)));
        await tester.pumpAndSettle();
        final file = File(state.paths.settingsPath);
        expect(file.absolute.path, contains('forms-immediate-'));
        final initial = file.readAsStringSync();
        file.deleteSync();
        final blocked = Directory(file.path)..createSync();
        final input = find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        );
        final valid = kind == 'proxy'
            ? 'http://127.0.0.1:7890'
            : 'https://example.test/service';
        await tester.enterText(input, valid);
        await settleWrites(tester);
        expect(find.textContaining('自动保存失败'), findsOneWidget);
        await tester.enterText(input, ' $valid ');
        await settleWrites(tester);
        expect(find.textContaining('自动保存失败'), findsOneWidget);
        await tester.enterText(input, 'https://');
        await settleWrites(tester);
        expect(
          tester.widget<TextField>(input).decoration!.errorText,
          isNotNull,
        );
        expect(find.textContaining('自动保存失败'), findsOneWidget);
        expect(blocked.absolute.path, file.absolute.path);
        blocked.deleteSync();
        file.writeAsStringSync(initial);
        await tester.enterText(input, valid);
        await settleWrites(tester);
        expect(file.readAsStringSync(), contains(valid));
        expect(find.textContaining('自动保存失败'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'rapid address edit and immediate close persist latest URL without extra submit',
    (tester) async {
      final state = await isolatedState(tester);
      await openForm(tester, DanmakuSourcePage(state: state));
      await tester.tap(find.byKey(const ValueKey('settings-danmaku-api')));
      await tester.pumpAndSettle();
      final input = find.byType(TextField);
      await tester.enterText(input, 'https://first.test');
      await tester.enterText(input, 'https://last.test');
      await tester.tap(find.text('关闭'));
      await settleWrites(tester);
      expect(state.danmakuSettings.apiUrl, 'https://last.test');
      final disk = File(state.paths.settingsPath).readAsStringSync();
      expect(disk, contains('https://last.test'));
      await tester.tap(find.byKey(const ValueKey('settings-danmaku-api')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('关闭'));
      await settleWrites(tester);
      expect(File(state.paths.settingsPath).readAsStringSync(), disk);
    },
  );
  testWidgets(
    'following identical preset never reports saved after a failed write',
    (tester) async {
      final state = await isolatedState(tester);
      await tester.runAsync(
        () => state.setFollowingSettings(
          state.followingSettings.copyWith(enabled: false),
        ),
      );
      await openForm(tester, Scaffold(body: FollowingPage(state: state)));
      await tester.tap(find.byKey(const ValueKey('following-interval')));
      await tester.pumpAndSettle();
      final file = File(state.paths.settingsPath);
      expect(file.absolute.path, contains('forms-immediate-'));
      final initial = file.readAsStringSync();
      file.deleteSync();
      final blocked = Directory(file.path)..createSync();
      final preset = find.byKey(const ValueKey('following-interval-60'));
      await tester.tap(preset);
      await settleWrites(tester);
      expect(find.textContaining('检查间隔自动保存失败'), findsOneWidget);
      await tester.tap(preset);
      await settleWrites(tester);
      expect(find.textContaining('检查间隔自动保存失败'), findsOneWidget);
      expect(find.textContaining('检查间隔已自动保存为'), findsNothing);
      expect(blocked.absolute.path, file.absolute.path);
      blocked.deleteSync();
      file.writeAsStringSync(initial);
      await tester.tap(preset);
      await settleWrites(tester);
      final restored = UiPreferencesStore(path: file.path);
      await tester.runAsync(restored.load);
      expect(restored.followingSettings.intervalMinutes, 60);
      expect(find.textContaining('检查间隔已自动保存为'), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
    },
  );
  testWidgets(
    'following presets and valid custom interval commit without clamping input',
    (tester) async {
      final state = await isolatedState(tester);
      await tester.runAsync(
        () => state.setFollowingSettings(
          state.followingSettings.copyWith(enabled: false),
        ),
      );
      await openForm(tester, Scaffold(body: FollowingPage(state: state)));
      await tester.tap(find.byKey(const ValueKey('following-interval')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('following-interval-30')));
      await settleWrites(tester);
      expect(state.followingSettings.intervalMinutes, 30);
      final input = find.byKey(const ValueKey('following-interval-input'));
      for (final invalid in ['', '1', '1441', 'bad']) {
        await tester.enterText(input, invalid);
        await settleWrites(tester);
        expect(state.followingSettings.intervalMinutes, 30);
        expect(tester.widget<TextField>(input).controller!.text, invalid);
      }
      await tester.enterText(input, '125');
      await settleWrites(tester);
      expect(state.followingSettings.intervalMinutes, 125);
      expect(
        find.byKey(const ValueKey('following-interval-save')),
        findsNothing,
      );
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
    },
  );
  testWidgets(
    'TTS template rule persists without Enter or network and preserves metadata',
    (tester) async {
      final state = await isolatedState(tester);
      final engine = _Engine();
      final store = ReaderPreferencesStore(
        '${state.paths.configDir}/reader-test.json',
      );
      store.save(
        ReaderPreferences(
          source: TtsSource.custom,
          custom: const TtsCustomConfig(
            url: 'old',
            name: 'name',
            contentType: 'audio/wav',
            header: 'X-Test: true',
          ),
        ),
      );
      final controller = ReaderTtsController(
        engines: TtsEngines(factory: (_) => engine),
        store: store,
        audio: _Audio(),
      )..loadPreferences();
      addTearDown(controller.close);
      await openForm(
        tester,
        Scaffold(body: ReaderTtsSettingsDialog(controller: controller)),
      );
      final calls = engine.voiceCalls;
      final input = find.byType(TextField);
      await tester.enterText(input, ' GET https://example.test/{{speakText}} ');
      await tester.pump();
      expect(
        controller.settings.custom!.url,
        'GET https://example.test/{{speakText}}',
      );
      expect(store.load().custom!.header, 'X-Test: true');
      expect(store.load().custom!.name, 'name');
      expect(store.load().custom!.contentType, 'audio/wav');
      expect(engine.voiceCalls, calls);
      expect(engine.synthCalls, 0);
      await tester.enterText(input, '');
      await tester.pump();
      expect(store.load().custom, isNull);
    },
  );
  testWidgets(
    'TTS custom rule disk failure stays visible instead of escaping onChanged',
    (tester) async {
      final state = await isolatedState(tester);
      final store = ReaderPreferencesStore(
        '${state.paths.configDir}/reader-failure.json',
      );
      store.save(
        ReaderPreferences(
          source: TtsSource.custom,
          custom: const TtsCustomConfig(url: 'initial'),
        ),
      );
      final controller = ReaderTtsController(
        engines: TtsEngines(factory: (_) => _Engine()),
        store: store,
        audio: _Audio(),
      )..loadPreferences();
      addTearDown(controller.close);
      final file = File(store.path);
      expect(file.absolute.path, contains('forms-immediate-'));
      final initial = file.readAsStringSync();
      file.deleteSync();
      final blocked = Directory(store.path)..createSync();
      await openForm(
        tester,
        Scaffold(body: ReaderTtsSettingsDialog(controller: controller)),
      );
      await tester.enterText(find.byType(TextField), 'edited');
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).decoration!.errorText,
        contains('自动保存失败'),
      );
      expect(tester.takeException(), isNull);
      await tester.enterText(find.byType(TextField), ' edited ');
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).decoration!.errorText,
        contains('自动保存失败'),
      );
      expect(blocked.absolute.path, file.absolute.path);
      blocked.deleteSync();
      file.writeAsStringSync(initial);
      await tester.enterText(find.byType(TextField), 'edited');
      await tester.pump();
      expect(store.load().custom!.url, 'edited');
      expect(
        tester.widget<TextField>(find.byType(TextField)).decoration!.errorText,
        isNull,
      );
    },
  );
}
