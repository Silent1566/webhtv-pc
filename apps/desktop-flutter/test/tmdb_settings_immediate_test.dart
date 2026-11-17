import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/tmdb_config.dart';
import 'package:webhtv_pc/ui/config_pages.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';

import 'settings_immediate_forms_test.dart'
    show isolatedState, settleWrites, openForm;

Future<void> reach(
  WidgetTester tester,
  String key, {
  double delta = 300,
}) async {
  final target = find.byKey(ValueKey(key));
  await tester.scrollUntilVisible(
    target,
    delta,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.ensureVisible(target);
  await tester.pump();
}

Future<void> tapRuleAdd(WidgetTester tester, String key) async {
  final button = find.byKey(ValueKey(key));
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.tap(button);
}

class ControlledState extends AppState {
  ControlledState(AppPaths paths, LogService log)
    : super(paths: paths, log: log, externalPlayerDetector: () => const []);
  Completer<void>? gate;
  Completer<String>? connection;
  int saves = 0;
  int requests = 0;
  @override
  Future<bool> saveTmdbConfig(TmdbConfig config) async {
    saves++;
    await gate?.future;
    return super.saveTmdbConfig(config);
  }

  @override
  Future<String> testTmdbConnection() {
    requests++;
    return (connection = Completer<String>()).future;
  }
}

void main() {
  for (final pending in [false, true]) {
    testWidgets(
      'TMDB write failure survives reentry pending=$pending and equivalent retry recovers',
      (tester) async {
        final state = (await isolatedState(
          tester,
          create: ControlledState.new,
        )) as ControlledState;
        final file = File(state.paths.settingsPath);
        expect(file.absolute.path, contains('forms-immediate-'));
        final initial = file.readAsStringSync();
        file.deleteSync();
        final blocked = Directory(file.path)..createSync();
        if (pending) state.gate = Completer<void>();
        await openForm(tester, TmdbSettingsPage(state: state));
        await tester.enterText(
          find.byKey(const ValueKey('tmdb-api-key')),
          'failed-reentry-key',
        );
        await tester.pump();
        if (!pending) await settleWrites(tester);
        await tester.pumpWidget(const SizedBox());
        await openForm(tester, TmdbSettingsPage(state: state));
        expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('tmdb-api-key')))
              .controller!
              .text,
          'failed-reentry-key',
        );
        if (pending) state.gate!.complete();
        await settleWrites(tester);
        await reach(tester, 'tmdb-test');
        expect(find.textContaining('自动保存失败'), findsOneWidget);
        expect(blocked.absolute.path, file.absolute.path);
        blocked.deleteSync();
        file.writeAsStringSync(initial);
        await reach(tester, 'tmdb-api-key', delta: -300);
        await tester.enterText(
          find.byKey(const ValueKey('tmdb-api-key')),
          ' failed-reentry-key ',
        );
        await settleWrites(tester);
        expect(
          (jsonDecode(file.readAsStringSync()) as Map)['tmdb']['apiKey'],
          'failed-reentry-key',
        );
        await reach(tester, 'tmdb-test');
        expect(find.textContaining('自动保存失败'), findsNothing);
        expect(find.textContaining('已自动保存'), findsOneWidget);
      },
    );
  }

  testWidgets(
    'rapid edits survive busy persistence and page reopen without losing fields',
    (tester) async {
      final state = (await isolatedState(
        tester,
        create: ControlledState.new,
      )) as ControlledState;
      final file = File(state.paths.settingsPath);
      final root = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      root['unknownFutureSetting'] = {'keep': 'untouched'};
      file.writeAsStringSync(jsonEncode(root));
      state.gate = Completer<void>();
      await openForm(tester, TmdbSettingsPage(state: state));
      expect(state.saves, 0);
      await tester.enterText(
        find.byKey(const ValueKey('tmdb-api-key')),
        'rapid-last-key',
      );
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('tmdb-access-token')),
        'rapid-last-token',
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        MaterialApp(home: TmdbSettingsPage(state: state)),
      );
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('tmdb-omdb-key')),
        'rapid-omdb',
      );
      state.gate!.complete();
      await settleWrites(tester);
      expect(state.tmdbUserConfig.apiKey, 'rapid-last-key');
      expect(state.tmdbUserConfig.accessToken, 'rapid-last-token');
      expect(state.tmdbUserConfig.omdbApiKey, 'rapid-omdb');
      expect(
        (jsonDecode(file.readAsStringSync()) as Map)['unknownFutureSetting'],
        {'keep': 'untouched'},
      );
      expect(state.requests, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'connection testing is explicit and stale result cannot replace new edit status',
    (tester) async {
      final state = (await isolatedState(
        tester,
        create: ControlledState.new,
      )) as ControlledState;
      await openForm(tester, TmdbSettingsPage(state: state));
      await tester.enterText(find.byKey(const ValueKey('tmdb-api-key')), 'key');
      await settleWrites(tester);
      expect(state.requests, 0);
      await reach(tester, 'tmdb-test');
      await tester.tap(find.byKey(const ValueKey('tmdb-test')));
      await tester.pump();
      expect(state.requests, 1);
      await reach(tester, 'tmdb-enabled', delta: -300);
      await tester.tap(find.byKey(const ValueKey('tmdb-enabled')));
      await settleWrites(tester);
      state.connection!.complete('obsolete result');
      await tester.pump();
      await reach(tester, 'tmdb-test');
      expect(find.text('obsolete result'), findsNothing);
      expect(find.textContaining('已自动保存'), findsOneWidget);
    },
  );

  testWidgets(
    'TMDB fields, switches and rule operations persist without Save',
    (tester) async {
      final state = await isolatedState(tester);
      await openForm(tester, TmdbSettingsPage(state: state));
      await tester.enterText(
        find.byKey(const ValueKey('tmdb-api-key')),
        'first',
      );
      await settleWrites(tester);
      expect(state.tmdbUserConfig.apiKey, 'first');
      await tester.enterText(
        find.byKey(const ValueKey('tmdb-api-key')),
        'last',
      );
      await tester.enterText(
        find.byKey(const ValueKey('tmdb-access-token')),
        'token',
      );
      await settleWrites(tester);
      expect(state.tmdbUserConfig.apiKey, 'last');
      expect(state.tmdbUserConfig.accessToken, 'token');
      await reach(tester, 'tmdb-smart-match');
      final initial = state.tmdbUserConfig.smartMatch;
      await tester.tap(find.byKey(const ValueKey('tmdb-smart-match')));
      await settleWrites(tester);
      expect(state.tmdbUserConfig.smartMatch, !initial);
      await reach(tester, 'tmdb-enabled-sites-input');
      await tester.enterText(
        find.byKey(const ValueKey('tmdb-enabled-sites-input')),
        'site',
      );
      await tapRuleAdd(tester, 'tmdb-enabled-sites-add');
      await settleWrites(tester);
      expect(state.tmdbUserConfig.enabledSites, ['site']);
      await tester.tap(
        find.byKey(const ValueKey('tmdb-enabled-sites-chip-site')),
      );
      // Deletion uses InputChip's delete icon rather than its body.
      final chip = tester.widget<InputChip>(
        find.byKey(const ValueKey('tmdb-enabled-sites-chip-site')),
      );
      chip.onDeleted!();
      await settleWrites(tester);
      expect(state.tmdbUserConfig.enabledSites, isEmpty);
      await reach(tester, 'tmdb-reset-rules');
      await tester.tap(find.byKey(const ValueKey('tmdb-reset-rules')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('重置').last);
      await settleWrites(tester);
      expect(state.tmdbUserConfig.disabledSites, tmdbDefaultDisabledRules);
      await reach(tester, 'tmdb-test');
      expect(find.byKey(const ValueKey('tmdb-save')), findsNothing);
      final root =
          jsonDecode(File(state.paths.settingsPath).readAsStringSync()) as Map;
      expect((root['tmdb'] as Map)['apiKey'], 'last');
    },
  );
  testWidgets('TMDB every text toggle and rule list commits independently', (
    tester,
  ) async {
    final state = await isolatedState(tester);
    await openForm(tester, TmdbSettingsPage(state: state));
    for (final field in {
      'tmdb-api-key': ' key ',
      'tmdb-access-token': ' token ',
      'tmdb-omdb-key': ' omdb ',
      'tmdb-api-base': 'https://example.test/3',
      'tmdb-image-base': 'https://images.example.test/w342',
      'tmdb-language': ' en-US ',
    }.entries) {
      await reach(tester, field.key);
      await tester.enterText(find.byKey(ValueKey(field.key)), field.value);
      await settleWrites(tester);
    }
    expect(state.tmdbUserConfig.apiKey, 'key');
    expect(state.tmdbUserConfig.accessToken, 'token');
    expect(state.tmdbUserConfig.omdbApiKey, 'omdb');
    expect(state.tmdbUserConfig.imageBase, 'https://images.example.test/w342');
    expect(state.tmdbUserConfig.language, 'en-US');
    await reach(tester, 'tmdb-enabled', delta: -300);
    final enabled = state.tmdbUserConfig.enabled;
    await tester.tap(find.byKey(const ValueKey('tmdb-enabled')));
    await settleWrites(tester);
    expect(state.tmdbUserConfig.enabled, !enabled);
    await reach(tester, 'tmdb-smart-match');
    final smart = state.tmdbUserConfig.smartMatch;
    await tester.tap(find.byKey(const ValueKey('tmdb-smart-match')));
    await settleWrites(tester);
    expect(state.tmdbUserConfig.smartMatch, !smart);
    await reach(tester, 'tmdb-heuristic');
    final heuristic = state.tmdbUserConfig.heuristicSeasonGuessing;
    await tester.tap(find.byKey(const ValueKey('tmdb-heuristic')));
    await settleWrites(tester);
    expect(state.tmdbUserConfig.heuristicSeasonGuessing, !heuristic);
    for (final prefix in [
      'tmdb-enabled-sites',
      'tmdb-allowed-sites',
      'tmdb-disabled-sites',
    ]) {
      final input = find.byKey(ValueKey('$prefix-input'));
      await reach(tester, '$prefix-input');
      await tester.enterText(input, 'custom-one');
      await tapRuleAdd(tester, '$prefix-add');
      await tester.enterText(input, 'custom-two');
      await tester.tap(find.byKey(ValueKey('$prefix-add')));
      await settleWrites(tester);
      List<String> current() => switch (prefix) {
        'tmdb-enabled-sites' => state.tmdbUserConfig.enabledSites,
        'tmdb-allowed-sites' => state.tmdbUserConfig.allowedSites,
        _ => state.tmdbUserConfig.disabledSites,
      };
      expect(current(), containsAll(['custom-one', 'custom-two']));
      final chip = find.byKey(ValueKey('$prefix-chip-custom-one'));
      await tester.ensureVisible(chip);
      await tester.tap(
        find.descendant(of: chip, matching: find.byTooltip('Delete')),
      );
      await settleWrites(tester);
      expect(current(), isNot(contains('custom-one')));
      expect(current(), contains('custom-two'));
    }
    await reach(tester, 'tmdb-reset-rules');
    await tester.tap(find.byKey(const ValueKey('tmdb-reset-rules')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(state.tmdbUserConfig.allowedSites, ['custom-two']);
    await tester.tap(find.byKey(const ValueKey('tmdb-reset-rules')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重置').last);
    await settleWrites(tester);
    expect(state.tmdbUserConfig.allowedSites, isEmpty);
    expect(state.tmdbUserConfig.enabledSites, isEmpty);
    expect(state.tmdbUserConfig.disabledSites, tmdbDefaultDisabledRules);
  });
  testWidgets('TMDB write failure is visible and a later edit retries', (
    tester,
  ) async {
    final state = await isolatedState(tester);
    final file = File(state.paths.settingsPath);
    final saved = file.readAsStringSync();
    expect(file.absolute.path, contains('forms-immediate-'));
    file.deleteSync();
    final blocked = Directory(file.path)..createSync();
    await openForm(tester, TmdbSettingsPage(state: state));
    await tester.enterText(
      find.byKey(const ValueKey('tmdb-api-key')),
      'failed-key',
    );
    await settleWrites(tester);
    await reach(tester, 'tmdb-save-result');
    expect(find.textContaining('自动保存失败'), findsOneWidget);
    await reach(tester, 'tmdb-api-base', delta: -300);
    await tester.enterText(
      find.byKey(const ValueKey('tmdb-api-base')),
      'https://',
    );
    await settleWrites(tester);
    await reach(tester, 'tmdb-test');
    expect(find.textContaining('自动保存失败'), findsOneWidget);
    expect(blocked.absolute.path, file.absolute.path);
    blocked.deleteSync();
    file.writeAsStringSync(saved);
    await reach(tester, 'tmdb-api-key', delta: -300);
    await tester.enterText(
      find.byKey(const ValueKey('tmdb-api-key')),
      'recovered-key',
    );
    await settleWrites(tester);
    expect(
      (jsonDecode(file.readAsStringSync()) as Map)['tmdb']['apiKey'],
      'recovered-key',
    );
    await reach(tester, 'tmdb-save-result');
    expect(find.textContaining('已自动保存'), findsOneWidget);
  });
  testWidgets(
    'TMDB valid endpoint persists and invalid draft keeps last endpoint',
    (tester) async {
      final state = await isolatedState(tester);
      await openForm(tester, TmdbSettingsPage(state: state));
      await reach(tester, 'tmdb-api-base');
      final input = find.byKey(const ValueKey('tmdb-api-base'));
      await tester.enterText(input, 'https://example.test/3');
      await settleWrites(tester);
      expect(state.tmdbUserConfig.apiBase, 'https://example.test/3');
      for (final invalid in [
        'https://',
        'https://bad host/3',
        'https://example.test:0/3',
      ]) {
        await tester.enterText(input, invalid);
        await settleWrites(tester);
        expect(state.tmdbUserConfig.apiBase, 'https://example.test/3');
        expect(
          tester.widget<TextField>(input).decoration!.errorText,
          isNotNull,
        );
      }
      expect(state.tmdbUserConfig.apiBase, 'https://example.test/3');
      expect(tester.widget<TextField>(input).decoration!.errorText, isNotNull);
      await tester.enterText(input, '');
      await settleWrites(tester);
      expect(state.tmdbUserConfig.apiBase, tmdbDefaultApiBase);
    },
  );
}
