import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/subtitle_settings.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/ui_preferences_store.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/subtitle_settings_page.dart';

class _ObservedState extends AppState {
  _ObservedState(AppPaths paths)
    : super(
        paths: paths,
        log: LogService(),
        externalPlayerDetector: () => const [],
      );
  int saves = 0;
  bool holdResults = false;
  bool throwOnSave = false;
  final pending = <Completer<bool>>[];

  @override
  Future<bool> setSubtitleSettings(SubtitleSettings settings) {
    saves++;
    if (throwOnSave) return Future.error(StateError('secret must not leak'));
    final result = super.setSubtitleSettings(settings);
    if (!holdResults) return result;
    final held = Completer<bool>();
    pending.add(held);
    return result.then((_) => held.future);
  }
}

void main() {
  late Directory temp;
  late AppPaths paths;
  late _ObservedState state;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('subtitle-immediate-');
    paths = AppPaths.resolve(
      overrides: {
        'config': '${temp.path}/config',
        'data': '${temp.path}/data',
        'cache': '${temp.path}/cache',
        'state': '${temp.path}/logs',
      },
    );
    for (final dir in [
      paths.configDir,
      paths.dataDir,
      paths.cacheDir,
      paths.logDir,
    ]) {
      expect(dir.startsWith('${temp.path}/'), isTrue);
    }
    LogService.logDirectoryOverride = paths.logDir;
    state = _ObservedState(paths);
    await state.bootstrap();
  });
  tearDown(() async {
    for (final held in state.pending) {
      if (!held.isCompleted) held.complete(true);
    }
    state.dispose();
    LogService.logDirectoryOverride = null;
    await temp.delete(recursive: true);
  });

  Finder field(String suffix) => find.byKey(ValueKey('subtitle-$suffix'));
  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(560, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(home: SubtitleSettingsPage(state: state)),
    );
    await tester.pump();
  }

  Future<void> reveal(WidgetTester tester, Finder target) async {
    final scrollable = find.byType(Scrollable).first;
    tester.state<ScrollableState>(scrollable).position.jumpTo(0);
    await tester.pump();
    await tester.scrollUntilVisible(target, 180, scrollable: scrollable);
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
  }

  Future<UiPreferencesStore> reload(WidgetTester tester) async {
    final store = UiPreferencesStore(path: paths.settingsPath);
    await tester.runAsync(store.load);
    await tester.pump();
    return store;
  }

  Future<void> settleWrites(WidgetTester tester) async {
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump();
  }

  testWidgets(
    'all fields and switches persist immediately without focus loss or save',
    (tester) async {
      await mount(tester);
      expect(state.saves, 0);
      await reveal(tester, field('assrt-token'));
      await tester.enterText(field('assrt-token'), '  assrt-last  ');
      expect(state.subtitleSettings.assrtToken, 'assrt-last');
      for (final suffix in [
        'auto-match',
        'xunlei-enabled',
        'shooter-enabled',
      ]) {
        await reveal(tester, field(suffix));
        await tester.tap(field(suffix));
        await tester.pump();
      }
      await reveal(tester, field('local-directories'));
      await tester.enterText(field('local-directories'), ' /first \n\n /last ');
      await reveal(tester, field('http-endpoint'));
      await tester.enterText(
        field('http-endpoint'),
        ' https://example.test/search ',
      );
      expect(
        state.subtitleSettings.httpEndpoint,
        'https://example.test/search',
      );
      await reveal(tester, field('http-token'));
      await tester.enterText(field('http-token'), ' http-last ');
      expect(state.subtitleSettings.httpToken, 'http-last');
      await settleWrites(tester);
      final saved = (await reload(tester)).subtitleSettings;
      expect(saved.assrtToken, 'assrt-last');
      expect(saved.autoMatch, isTrue);
      expect(saved.xunleiEnabled, isTrue);
      expect(saved.shooterEnabled, isTrue);
      expect(saved.localDirectories, ['/first', '/last']);
      expect(saved.httpEndpoint, 'https://example.test/search');
      expect(saved.httpToken, 'http-last');
      await reveal(tester, field('status'));
      expect(find.textContaining('已启用 5 个源'), findsOneWidget);
      expect(field('save'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'adding default directory persists once; revealing tokens never saves',
    (tester) async {
      await mount(tester);
      await reveal(tester, field('assrt-token-reveal'));
      await tester.tap(field('assrt-token-reveal'));
      await reveal(tester, find.byTooltip('显示令牌'));
      await tester.tap(find.byTooltip('显示令牌'));
      expect(state.saves, 0);
      await reveal(tester, field('add-default-dir'));
      await tester.tap(field('add-default-dir'));
      await tester.pump();
      expect(state.subtitleSettings.localDirectories, [
        '${paths.configDir}${Platform.pathSeparator}subtitles',
      ]);
      await settleWrites(tester);
      expect((await reload(tester)).subtitleSettings.localDirectories, [
        '${paths.configDir}${Platform.pathSeparator}subtitles',
      ]);
      final count = state.saves;
      await tester.tap(field('add-default-dir'));
      await tester.pump();
      expect(state.saves, count);
    },
  );

  testWidgets(
    'invalid HTTP URL retains valid value while other fields persist; empty clears',
    (tester) async {
      await tester.runAsync(
        () => state.setSubtitleSettings(
          SubtitleSettings(httpEndpoint: 'https://old.test/s'),
        ),
      );
      await mount(tester);
      await reveal(tester, field('http-endpoint'));
      for (final invalid in [
        'not a url',
        'ftp://example.test/s',
        'https://',
        'https://example.test:bad',
        'https://exa mple.test/s',
      ]) {
        await tester.enterText(field('http-endpoint'), invalid);
        await tester.pump();
        expect(state.subtitleSettings.httpEndpoint, 'https://old.test/s');
        expect(
          tester
              .widget<TextField>(field('http-endpoint'))
              .decoration!
              .errorText,
          isNotNull,
        );
      }
      await reveal(tester, field('http-token'));
      await tester.enterText(field('http-token'), 'new-token');
      expect(state.subtitleSettings.httpToken, 'new-token');
      await reveal(tester, field('http-endpoint'));
      await tester.enterText(
        field('http-endpoint'),
        'http://localhost:4321/search?q=one',
      );
      expect(
        state.subtitleSettings.httpEndpoint,
        'http://localhost:4321/search?q=one',
      );
      await tester.pump();
      expect(
        tester.widget<TextField>(field('http-endpoint')).decoration!.errorText,
        isNull,
      );
      await tester.enterText(field('http-endpoint'), '   ');
      await settleWrites(tester);
      expect((await reload(tester)).subtitleSettings.httpEndpoint, '');
      expect(state.subtitleSettings.hasHttpProvider, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'rapid edits during save survive immediate page departure and reentry',
    (tester) async {
      await tester.runAsync(
        () => state.setSubtitleSettings(
          SubtitleSettings(preferredLanguages: ['ja', 'zh']),
        ),
      );
      final file = File(paths.settingsPath);
      final root = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      root['integrationSentinel'] = {'untouched': 7};
      file.writeAsStringSync(jsonEncode(root));
      await mount(tester);
      state.holdResults = true;
      await reveal(tester, field('assrt-token'));
      for (final token in ['a', 'ab', 'abc', 'latest']) {
        await tester.enterText(field('assrt-token'), token);
      }
      await reveal(tester, field('xunlei-enabled'));
      await tester.tap(field('xunlei-enabled'));
      await tester.pump();
      await reveal(tester, field('assrt-token'));
      await tester.enterText(field('assrt-token'), 'last-after-switch');
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await settleWrites(tester);
      final saved = (await reload(tester)).subtitleSettings;
      expect(saved.assrtToken, 'last-after-switch');
      expect(saved.xunleiEnabled, isTrue);
      expect(saved.preferredLanguages, ['ja', 'zh']);
      expect(
        (jsonDecode(file.readAsStringSync()) as Map)['integrationSentinel'],
        {'untouched': 7},
      );
      for (final held in state.pending) {
        held.complete(true);
      }
      await settleWrites(tester);
      await mount(tester);
      await reveal(tester, field('assrt-token'));
      expect(
        tester.widget<TextField>(field('assrt-token')).controller!.text,
        'last-after-switch',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('old save result cannot replace the newest failure status', (
    tester,
  ) async {
    await mount(tester);
    state.holdResults = true;
    await reveal(tester, field('assrt-token'));
    await tester.enterText(field('assrt-token'), 'first');
    await tester.enterText(field('assrt-token'), 'last');
    expect(state.pending.length, 2);
    state.pending.last.complete(false);
    await settleWrites(tester);
    await reveal(tester, field('save-message'));
    expect(find.textContaining('保存失败'), findsOneWidget);
    state.pending.first.complete(true);
    await settleWrites(tester);
    expect(find.textContaining('保存失败'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'thrown save failure is caught, redacted, and subsequent editing recovers',
    (tester) async {
      await mount(tester);
      state.throwOnSave = true;
      await reveal(tester, field('assrt-token'));
      await tester.enterText(field('assrt-token'), 'secret');
      await settleWrites(tester);
      await reveal(tester, field('save-message'));
      expect(find.textContaining('保存失败'), findsOneWidget);
      expect(find.textContaining('secret must not leak'), findsNothing);
      expect(tester.takeException(), isNull);
      state.throwOnSave = false;
      await reveal(tester, field('assrt-token'));
      await tester.enterText(field('assrt-token'), 'recovered');
      await settleWrites(tester);
      expect((await reload(tester)).subtitleSettings.assrtToken, 'recovered');
      await reveal(tester, field('save-message'));
      expect(find.textContaining('保存失败'), findsNothing);
    },
  );

  testWidgets('legacy endpoint survives initialization and unrelated edits', (
    tester,
  ) async {
    await tester.runAsync(
      () => state.setSubtitleSettings(
        SubtitleSettings(
          httpEndpoint: 'legacy-relative-search',
          httpToken: 'seeded-token',
          assrtToken: 'seeded-assrt',
          localDirectories: ['/seeded'],
        ),
      ),
    );
    final count = state.saves;
    await mount(tester);
    expect(state.saves, count);
    await reveal(tester, field('http-token'));
    await tester.enterText(field('http-token'), 'changed-token');
    await settleWrites(tester);
    expect(
      (await reload(tester)).subtitleSettings.httpEndpoint,
      'legacy-relative-search',
    );
    for (final suffix in ['http-token', 'assrt-token', 'local-directories']) {
      await reveal(tester, field(suffix));
      await tester.enterText(field(suffix), '   ');
    }
    await settleWrites(tester);
    final saved = (await reload(tester)).subtitleSettings;
    expect(saved.httpToken, '');
    expect(saved.assrtToken, '');
    expect(saved.localDirectories, isEmpty);
    expect(saved.httpEndpoint, 'legacy-relative-search');
    expect(tester.takeException(), isNull);
  });

  testWidgets('enabling configured sources never starts network requests', (
    tester,
  ) async {
    var requests = 0;
    await HttpOverrides.runZoned(
      () async {
        await mount(tester);
        await reveal(tester, field('auto-match'));
        await tester.tap(field('auto-match'));
        await reveal(tester, field('assrt-token'));
        await tester.enterText(field('assrt-token'), 'example-token');
        await reveal(tester, field('http-endpoint'));
        await tester.enterText(
          field('http-endpoint'),
          'https://example.test/search',
        );
        await settleWrites(tester);
        expect(state.subtitleSettings.isEnabled, isTrue);
        expect(requests, 0);
        expect(tester.takeException(), isNull);
      },
      createHttpClient: (_) {
        requests++;
        throw StateError('This settings page must remain offline');
      },
    );
  });

  Future<void> blockSettings(WidgetTester tester) async {
    expect(paths.settingsPath.startsWith('${temp.path}/'), isTrue);
    await tester.runAsync(() async {
      final file = File(paths.settingsPath);
      if (await file.exists()) await file.delete();
      await Directory(paths.settingsPath).create();
    });
  }

  Future<void> recoverSettings(WidgetTester tester) async {
    expect(paths.settingsPath.startsWith('${temp.path}/'), isTrue);
    await tester.runAsync(() async {
      await Directory(paths.settingsPath).delete();
      await File(paths.settingsPath).writeAsString('{}');
    });
  }

  testWidgets(
    'failed equivalent URL and token edits really retry until disk recovers',
    (tester) async {
      await mount(tester);
      await blockSettings(tester);
      await reveal(tester, field('http-endpoint'));
      await tester.enterText(
        field('http-endpoint'),
        'https://retry.test/search',
      );
      await settleWrites(tester);
      await reveal(tester, field('http-token'));
      await tester.enterText(field('http-token'), 'last-token');
      await settleWrites(tester);
      final attempts = state.saves;
      await tester.enterText(field('http-token'), ' last-token ');
      await settleWrites(tester);
      expect(state.saves, attempts + 1);
      await reveal(tester, field('save-message'));
      expect(find.textContaining('保存失败'), findsOneWidget);
      await reveal(tester, field('http-endpoint'));
      await tester.enterText(
        field('http-endpoint'),
        ' https://retry.test/search ',
      );
      await settleWrites(tester);
      expect(state.saves, attempts + 2);
      await recoverSettings(tester);
      await tester.enterText(
        field('http-endpoint'),
        'https://retry.test/search',
      );
      await settleWrites(tester);
      final saved = (await reload(tester)).subtitleSettings;
      expect(saved.httpEndpoint, 'https://retry.test/search');
      expect(saved.httpToken, 'last-token');
      await reveal(tester, field('save-message'));
      expect(find.textContaining('保存失败'), findsNothing);
      final recoveredAttempts = state.saves;
      await reveal(tester, field('http-token'));
      await tester.enterText(field('http-token'), ' last-token ');
      await settleWrites(tester);
      expect(state.saves, recoveredAttempts);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'invalid URL retains failure and reopening does not forget or automatically save it',
    (tester) async {
      await mount(tester);
      await blockSettings(tester);
      await reveal(tester, field('http-endpoint'));
      await tester.enterText(
        field('http-endpoint'),
        'https://valid.test/search',
      );
      await settleWrites(tester);
      await tester.enterText(field('http-endpoint'), 'invalid-input');
      await settleWrites(tester);
      await reveal(tester, field('save-message'));
      expect(find.textContaining('保存失败'), findsOneWidget);
      final attempts = state.saves;
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await mount(tester);
      expect(state.saves, attempts);
      await reveal(tester, field('save-message'));
      expect(find.textContaining('保存失败'), findsOneWidget);
      await reveal(tester, field('http-endpoint'));
      expect(
        tester.widget<TextField>(field('http-endpoint')).controller!.text,
        'https://valid.test/search',
      );
      await recoverSettings(tester);
      await tester.enterText(
        field('http-endpoint'),
        ' https://valid.test/search ',
      );
      await settleWrites(tester);
      expect(
        (await reload(tester)).subtitleSettings.httpEndpoint,
        'https://valid.test/search',
      );
      await reveal(tester, field('save-message'));
      expect(find.textContaining('保存失败'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'late failure after reopening remains visible and older completion cannot mask newer failure',
    (tester) async {
      await mount(tester);
      state.holdResults = true;
      await reveal(tester, field('assrt-token'));
      await tester.enterText(field('assrt-token'), 'first');
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await mount(tester);
      state.pending.first.complete(false);
      await settleWrites(tester);
      await reveal(tester, field('save-message'));
      expect(find.textContaining('保存失败'), findsOneWidget);
      await reveal(tester, field('assrt-token'));
      await tester.enterText(field('assrt-token'), 'second');
      await reveal(tester, field('save-message'));
      expect(find.textContaining('保存失败'), findsOneWidget);
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await mount(tester);
      await reveal(tester, field('assrt-token'));
      await tester.enterText(field('assrt-token'), 'latest');
      state.pending.last.complete(false);
      await settleWrites(tester);
      state.pending[1].complete(true);
      await settleWrites(tester);
      await reveal(tester, field('save-message'));
      expect(find.textContaining('保存失败'), findsOneWidget);
      expect((await reload(tester)).subtitleSettings.assrtToken, 'latest');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'real filesystem write failure is visible without unhandled async errors',
    (tester) async {
      await mount(tester);
      final file = File(paths.settingsPath);
      await tester.runAsync(() async {
        if (await file.exists()) await file.delete();
        await Directory(paths.settingsPath).create();
      });
      await reveal(tester, field('assrt-token'));
      await tester.enterText(field('assrt-token'), 'session-only');
      await settleWrites(tester);
      await reveal(tester, field('save-message'));
      expect(find.textContaining('保存失败'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
