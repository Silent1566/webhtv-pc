import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/ui/ai_settings_page.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/ai_config.dart';
import 'package:webhtv_pc/services/ai_config_store.dart';
import 'package:webhtv_pc/services/settings_file.dart';

void main() {
  testWidgets(
    'AI settings edits and independently resets all five prompts without losing unknown fields',
    (tester) async {
      final dir = Directory.systemTemp.createTempSync('ai-parity-ui-');
      final state = AppState(
        paths: AppPaths.resolve(
          overrides: {'roaming': dir.path, 'local': dir.path},
        ),
        log: LogService(),
      );
      addTearDown(() {
        state.dispose();
        dir.deleteSync(recursive: true);
      });
      const fields = [
        'recommend',
        'titleExtraction',
        'viewingReport',
        'adDetection',
        'groupRule',
      ];
      await tester.runAsync(() async {
        await state.bootstrap();
        await state.saveAiConfig(
          AiConfig.fromJson({
            'futureField': 'keep',
            for (final f in fields) '${f}Prompt': 'custom $f',
          }),
        );
      });
      tester.view.physicalSize = const Size(1200, 3200);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(MaterialApp(home: AiSettingsPage(state: state)));
      await tester.pumpAndSettle();
      for (final field in fields) {
        final tile = find.byKey(ValueKey('ai-$field-prompt-section'));
        await tester.tap(tile);
        await tester.pumpAndSettle();
        final input = find.byKey(ValueKey('ai-$field-prompt'));
        await tester.enterText(input, 'edited $field');
        final save = find.byKey(const ValueKey('ai-save'));
        await tester.tap(save);
        await tester.pumpAndSettle();
        expect(state.aiConfig.toJson()['${field}Prompt'], 'edited $field');
        expect(state.aiConfig.toJson()['${field}PromptCustom'], true);
        final reset = find.byKey(ValueKey('ai-$field-prompt-reset'));
        await tester.tap(reset);
        await tester.pumpAndSettle();
        await tester.tap(save);
        await tester.pumpAndSettle();
        expect(state.aiConfig.toJson()['${field}PromptCustom'], false);
        expect(
          state.aiConfig.toJson()['${field}Prompt'],
          isNot('edited $field'),
        );
        expect(state.aiConfig.toJson()['futureField'], 'keep');
        await tester.tap(tile);
        await tester.pumpAndSettle();
      }
    },
  );
  test(
    'AI save shares transaction with ui/sync, restart preserves unknown keys',
    () async {
      final dir = await Directory.systemTemp.createTemp('ai-parity-store-');
      addTearDown(() => dir.delete(recursive: true));
      final path = '${dir.path}/settings.json';
      await File(path).writeAsString(
        jsonEncode({
          'unknownRoot': 7,
          'ai': {
            'future': {'revision': 9},
          },
        }),
      );
      final store = AiConfigStore(path: path);
      await store.load();
      final saving = store.save(
        store.config.copyWith(apiKey: 'local-secret', model: 'saved'),
      );
      expect(
        writeSettingsSectionSync(
          path: path,
          writer: SettingsWriter.sync,
          mutate: (root) {
            root['sync'] = {'enabled': true};
            return true;
          },
        ).ok,
        true,
      );
      expect(
        writeSettingsSectionSync(
          path: path,
          writer: SettingsWriter.uiPreferences,
          mutate: (root) {
            root['ui'] = {'themeMode': 'light'};
            return true;
          },
        ).ok,
        true,
      );
      expect(await saving, true);
      final root = jsonDecode(await File(path).readAsString());
      expect(root['ui'], {'themeMode': 'light'});
      expect(root['sync'], {'enabled': true});
      expect(root['unknownRoot'], 7);
      final restart = AiConfigStore(path: path);
      await restart.load();
      expect(restart.config.model, 'saved');
      expect(restart.config.toJson()['future'], {'revision': 9});
      expect(restart.config.toJson()['recommendPromptVersion'], 3);
      expect(restart.config.toString(), isNot(contains('local-secret')));
    },
  );
  test(
    'save failure returns false but sanitized config stays active',
    () async {
      final dir = await Directory.systemTemp.createTemp('ai-parity-fail-');
      addTearDown(() => dir.delete(recursive: true));
      final store = AiConfigStore(path: dir.path);
      expect(await store.save(const AiConfig(apiKey: ' key ')), false);
      expect(store.config.apiKey, 'key');
    },
  );
}
