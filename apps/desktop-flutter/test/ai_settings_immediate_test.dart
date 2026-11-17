library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/ai_config.dart';
import 'package:webhtv_pc/services/ai_config_store.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/ai_settings_page.dart';

class RecordingStore extends AiConfigStore {
  RecordingStore({required super.path});
  final writes = <AiConfig>[];
  Completer<void>? firstWrite;
  @override
  Future<bool> save(AiConfig config) async {
    writes.add(config);
    if (writes.length == 1 && firstWrite != null) await firstWrite!.future;
    return super.save(config);
  }
}

void main() {
  late Directory temp;
  late AppState state;
  late RecordingStore store;
  setUp(() async {
    temp = Directory.systemTemp.createTempSync('ai-immediate-test');
    final paths = AppPaths.resolve(
      overrides: {
        'config': '${temp.path}/config',
        'data': '${temp.path}/data',
        'cache': '${temp.path}/cache',
        'state': '${temp.path}/logs',
      },
    );
    LogService.logDirectoryOverride = paths.logDir;
    File(paths.settingsPath)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(
        jsonEncode({
          'other': {'untouched': true},
          'ai': {
            ...const AiConfig().toJson(),
            'unknownAi': {'future': 42},
          },
        }),
      );
    store = RecordingStore(path: paths.settingsPath);
    await store.load();
    state = AppState(paths: paths, log: LogService())
      ..attachAiConfigStore(store);
  });
  tearDown(() {
    state.dispose();
    LogService.logDirectoryOverride = null;
    temp.deleteSync(recursive: true);
  });
  Finder field(String key) => find.byKey(ValueKey('ai-$key'));
  Future<void> pumpPage(
    WidgetTester tester, {
    Future<List<String>> Function(AiConfig)? fetch,
  }) async {
    tester.view.physicalSize = const Size(1200, 3600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: AiSettingsPage(state: state, fetchModelList: fetch),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> edit(WidgetTester tester, String key, String value) async {
    await tester.ensureVisible(field(key));
    await tester.enterText(field(key), value);
    await tester.pumpAndSettle();
  }

  Future<AiConfig> reload(WidgetTester tester) async {
    final fresh = AiConfigStore(path: store.path);
    await tester.runAsync(fresh.load);
    return fresh.config;
  }

  testWidgets(
    'initialization and key visibility do not write or fetch; no Save gate',
    (tester) async {
      var requests = 0;
      await pumpPage(
        tester,
        fetch: (_) async {
          requests++;
          return ['local'];
        },
      );
      expect(store.writes, isEmpty);
      await tester.tap(find.byTooltip('显示'));
      await tester.pumpAndSettle();
      expect(store.writes, isEmpty);
      expect(requests, 0);
      expect(field('save'), findsNothing);
    },
  );

  testWidgets(
    'valid text edits persist without blur and survive navigation and real store reload',
    (tester) async {
      await pumpPage(tester);
      await edit(tester, 'endpoint', ' https://example.test/v1 ');
      await edit(tester, 'api-key', ' sk-test ');
      await edit(tester, 'model', 'custom-model');
      await edit(tester, 'user-agent', ' custom-agent ');
      await edit(tester, 'timeout', '480');
      expect(state.aiConfig.endpoint, 'https://example.test/v1');
      expect(state.aiConfig.apiKey, 'sk-test');
      expect(state.aiConfig.model, 'custom-model');
      expect(state.aiConfig.customUserAgent, 'custom-agent');
      expect(state.aiConfig.timeoutSeconds, 480);
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      final saved = await reload(tester);
      expect(saved.model, 'custom-model');
      expect(saved.timeoutSeconds, 480);
      final root = jsonDecode(File(store.path).readAsStringSync()) as Map;
      expect(root['other'], {'untouched': true});
      expect((root['ai'] as Map)['unknownAi'], {'future': 42});
      await pumpPage(tester);
      expect(
        tester.widget<TextField>(field('model')).controller!.text,
        'custom-model',
      );
    },
  );

  testWidgets(
    'toggle and protocol immediately persist default endpoint but preserve custom endpoint',
    (tester) async {
      await pumpPage(tester);
      await tester.tap(field('enabled'));
      await tester.pumpAndSettle();
      expect(state.aiConfig.enabled, isTrue);
      await tester.tap(field('protocol'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Anthropic Messages').last);
      await tester.pumpAndSettle();
      expect(state.aiConfig.protocol, AiProtocol.anthropicMessages);
      expect(
        state.aiConfig.endpoint,
        AiProtocol.defaultEndpoint(AiProtocol.anthropicMessages),
      );
      await edit(tester, 'endpoint', 'https://proxy.test/messages');
      await tester.tap(field('protocol'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Gemini Native').last);
      await tester.pumpAndSettle();
      expect(state.aiConfig.endpoint, 'https://proxy.test/messages');
      expect((await reload(tester)).enabled, isTrue);
    },
  );

  testWidgets(
    'invalid URL and timeout keep last valid values while other edits persist',
    (tester) async {
      await pumpPage(tester);
      await edit(tester, 'timeout', '480');
      await edit(tester, 'endpoint', 'https://valid.test/v1');
      for (final invalid in ['abc', '29', '1801', '-10']) {
        await edit(tester, 'timeout', invalid);
        expect(state.aiConfig.timeoutSeconds, 480);
        expect(
          tester.widget<TextField>(field('timeout')).decoration!.errorText,
          isNotNull,
        );
      }
      for (final invalid in [
        'https://',
        'relative/path',
        'ftp://files.test',
        'https://bad host/v1',
      ]) {
        await edit(tester, 'endpoint', invalid);
        expect(
          tester.widget<TextField>(field('endpoint')).decoration!.errorText,
          isNotNull,
        );
        expect(state.aiConfig.endpoint, 'https://valid.test/v1');
      }
      await edit(tester, 'api-key', 'latest-key');
      expect(state.aiConfig.endpoint, 'https://valid.test/v1');
      expect(state.aiConfig.timeoutSeconds, 480);
      expect((await reload(tester)).apiKey, 'latest-key');
      await edit(tester, 'timeout', '');
      await edit(tester, 'endpoint', '');
      await edit(tester, 'model', '');
      await edit(tester, 'api-key', '');
      await edit(tester, 'user-agent', '');
      expect(state.aiConfig.timeoutSeconds, AiConfig.defaultTimeoutSeconds);
      expect(
        state.aiConfig.endpoint,
        AiProtocol.defaultEndpoint(state.aiConfig.protocol),
      );
      expect(state.aiConfig.model, AiProtocol.defaultModel);
      expect(state.aiConfig.apiKey, isEmpty);
      expect(state.aiConfig.customUserAgent, isEmpty);
    },
  );

  for (final prompt in [
    'recommend',
    'titleExtraction',
    'viewingReport',
    'adDetection',
    'groupRule',
  ]) {
    testWidgets('$prompt prompt edit and reset immediately persist', (
      tester,
    ) async {
      await pumpPage(tester);
      await tester.ensureVisible(field('$prompt-prompt-section'));
      await tester.tap(field('$prompt-prompt-section'));
      await tester.pumpAndSettle();
      await edit(tester, '$prompt-prompt', 'custom $prompt');
      expect(state.aiConfig.toJson()['${prompt}Prompt'], 'custom $prompt');
      expect(state.aiConfig.toJson()['${prompt}PromptCustom'], isTrue);
      await tester.ensureVisible(field('$prompt-prompt-reset'));
      await tester.tap(field('$prompt-prompt-reset'));
      await tester.pumpAndSettle();
      expect(
        (await reload(tester)).toJson()['${prompt}Prompt'],
        const AiConfig().toJson()['${prompt}Prompt'],
      );
      expect(state.aiConfig.toJson()['${prompt}PromptCustom'], isFalse);
    });
  }

  testWidgets(
    'model selection persists but expanding fetched list does not write',
    (tester) async {
      var requests = 0;
      await pumpPage(
        tester,
        fetch: (_) async {
          requests++;
          return ['a', 'b'];
        },
      );
      await tester.ensureVisible(field('fetch-models'));
      await tester.tap(field('fetch-models'));
      await tester.pumpAndSettle();
      expect(requests, 1);
      expect(store.writes, isEmpty);
      await tester.ensureVisible(field('model'));
      await tester.tap(field('model-toggle'));
      await tester.pumpAndSettle();
      await tester.tap(field('model-toggle'));
      await tester.pumpAndSettle();
      expect(store.writes, isEmpty);
      await tester.tap(field('model-option-b'));
      await tester.pumpAndSettle();
      expect((await reload(tester)).model, 'b');
      expect(requests, 1);
    },
  );

  testWidgets(
    'edits during model fetch invalidate old results without changing current draft',
    (tester) async {
      final response = Completer<List<String>>();
      await pumpPage(tester, fetch: (_) => response.future);
      await tester.ensureVisible(field('fetch-models'));
      await tester.tap(field('fetch-models'));
      await tester.pump();
      await edit(tester, 'endpoint', 'https://latest.test/v1');
      await edit(tester, 'model', 'latest-model');
      response.complete(['obsolete-model']);
      await tester.pumpAndSettle();
      expect(field('model-options'), findsNothing);
      expect(state.aiConfig.model, 'latest-model');
      expect(find.textContaining('取到 1 个模型'), findsNothing);
      expect(
        tester.widget<TextField>(field('model')).controller!.text,
        'latest-model',
      );
    },
  );

  testWidgets(
    'rapid edits queued behind save persist last snapshot even after page disposal',
    (tester) async {
      store.firstWrite = Completer<void>();
      await pumpPage(tester);
      await edit(tester, 'model', 'first');
      await edit(tester, 'model', 'second');
      await edit(tester, 'model', 'last');
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      store.firstWrite!.complete();
      await tester.pumpAndSettle();
      expect((await reload(tester)).model, 'last');
      expect(state.aiConfig.model, 'last');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('old save success cannot mask later invalid input', (
    tester,
  ) async {
    store.firstWrite = Completer<void>();
    await pumpPage(tester);
    await edit(tester, 'model', 'first');
    await edit(tester, 'timeout', 'invalid');
    store.firstWrite!.complete();
    await tester.pumpAndSettle();
    expect(find.text('已生效并保存'), findsNothing);
    expect(
      tester.widget<TextField>(field('timeout')).decoration!.errorText,
      isNotNull,
    );
  });

  testWidgets(
    'write failure is visible and later editing retries real persistence',
    (tester) async {
      await pumpPage(tester);
      final blocked = File('${temp.path}/blocked')
        ..writeAsStringSync('not a directory');
      final failedStore = RecordingStore(path: '${blocked.path}/settings.json');
      state.attachAiConfigStore(failedStore);
      failedStore.firstWrite = Completer<void>();
      await edit(tester, 'model', 'unpersisted');
      await edit(tester, 'timeout', 'invalid');
      failedStore.firstWrite!.complete();
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(field('timeout')).decoration!.errorText,
        isNotNull,
      );
      await tester.ensureVisible(field('settings-status'));
      await tester.pumpAndSettle();
      expect(find.textContaining('保存失败'), findsOneWidget);
      expect(find.text('已生效并保存'), findsNothing);
      expect(state.aiConfig.model, 'unpersisted');
      await edit(tester, 'model', ' unpersisted ');
      expect(
        find.textContaining('保存失败'),
        findsOneWidget,
        reason: '归一化相同的编辑不能隐藏未写盘的失败',
      );
      await edit(tester, 'timeout', 'invalid');
      await edit(tester, 'timeout', '300');
      expect(find.textContaining('保存失败'), findsOneWidget);
      state.attachAiConfigStore(store);
      await edit(tester, 'model', 'retried');
      expect((await reload(tester)).model, 'retried');
      expect(find.text('已生效并保存'), findsOneWidget);
    },
  );
  testWidgets(
    'returning invalid text to last valid value clears obsolete validation status without writing',
    (tester) async {
      await pumpPage(tester);
      await edit(tester, 'timeout', 'invalid');
      await edit(tester, 'timeout', '300');
      expect(store.writes, isEmpty);
      expect(
        tester.widget<TextField>(field('timeout')).decoration!.errorText,
        isNull,
      );
      await tester.ensureVisible(field('test'));
      await tester.pumpAndSettle();
      expect(find.text('输入无效，已保留上次有效值'), findsNothing);
    },
  );

  testWidgets(
    'fetch exceptions visibly fail and do not block subsequent explicit fetch',
    (tester) async {
      var calls = 0;
      await pumpPage(
        tester,
        fetch: (_) async {
          if (++calls == 1) throw StateError('fixture fetch failure');
          return ['retry-model'];
        },
      );
      await tester.ensureVisible(field('fetch-models'));
      await tester.tap(field('fetch-models'));
      await tester.pumpAndSettle();
      expect(find.textContaining('拉取模型列表失败'), findsOneWidget);
      expect(calls, 1);
      await tester.tap(field('fetch-models'));
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(find.textContaining('取到 1 个模型'), findsOneWidget);
      expect(store.writes, isEmpty);
    },
  );

  testWidgets(
    'explicit connection test uses snapshot and old response cannot mask later edit',
    (tester) async {
      await state.saveAiConfig(
        state.aiConfig.copyWith(enabled: true, apiKey: 'fixture-key'),
      );
      store.writes.clear();
      final response = Completer<http.Response>();
      final requests = <http.Request>[];
      await http.runWithClient(
        () async {
          await pumpPage(tester);
          expect(requests, isEmpty);
          await tester.ensureVisible(field('test'));
          await tester.tap(field('test'));
          await tester.pump();
          expect(requests, hasLength(1));
          expect(store.writes, isEmpty);
          final requestedModel =
              (jsonDecode(requests.single.body) as Map)['model'];
          await edit(tester, 'model', 'new-model');
          expect(requestedModel, AiProtocol.defaultModel);
          response.complete(
            http.Response(
              jsonEncode({'output_text': 'obsolete-connected'}),
              200,
            ),
          );
          await tester.pumpAndSettle();
          expect(
            tester.widget<OutlinedButton>(field('test')).onPressed,
            isNotNull,
          );
          expect(find.textContaining('obsolete-connected'), findsNothing);
          expect(state.aiConfig.model, 'new-model');
          expect((await reload(tester)).model, 'new-model');
        },
        () => MockClient((request) {
          requests.add(request);
          return response.future;
        }),
      );
    },
  );
  Future<File> blockSettingsFile() async {
    final settings = File(store.path);
    final original = settings.readAsStringSync();
    // Preserve the owned path before replacing the file with an unwritable directory.
    expect(settings.path.startsWith(temp.path), isTrue);
    settings.deleteSync();
    Directory(settings.path).createSync();
    return File('${temp.path}/settings-backup')..writeAsStringSync(original);
  }

  void recoverSettingsFile(File backup) {
    expect(store.path.startsWith(temp.path), isTrue);
    Directory(store.path).deleteSync();
    File(store.path).writeAsStringSync(backup.readAsStringSync());
  }

  testWidgets(
    'review equivalent valid edits retry only after real failed write and actual disk recovery',
    (tester) async {
      await pumpPage(tester);
      final backup = await blockSettingsFile();
      await edit(tester, 'api-key', 'retry-key');
      expect(find.textContaining('保存失败'), findsOneWidget);
      final failedWrites = store.writes.length;
      await edit(tester, 'api-key', ' retry-key ');
      expect(
        store.writes.length,
        failedWrites + 1,
        reason: 'unchanged normalized value must retry after failure',
      );
      expect(find.textContaining('保存失败'), findsOneWidget);
      recoverSettingsFile(backup);
      await edit(tester, 'api-key', 'retry-key');
      expect((await reload(tester)).apiKey, 'retry-key');
      expect(find.textContaining('保存失败'), findsNothing);
      final healthyWrites = store.writes.length;
      await edit(tester, 'api-key', ' retry-key ');
      expect(
        store.writes.length,
        healthyWrites,
        reason: 'healthy equivalent edit must not write',
      );
    },
  );

  testWidgets(
    'review reopened page retains real write failure and retries same credential after recovery',
    (tester) async {
      await pumpPage(tester);
      final backup = await blockSettingsFile();
      await edit(tester, 'api-key', 'reopen-key');
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      final writesBeforeReopen = store.writes.length;
      await pumpPage(tester);
      expect(
        store.writes.length,
        writesBeforeReopen,
        reason: 'reopening does not write',
      );
      expect(
        tester.widget<TextField>(field('api-key')).controller!.text,
        'reopen-key',
      );
      expect(find.textContaining('保存失败'), findsOneWidget);
      await edit(tester, 'timeout', 'invalid');
      expect(find.textContaining('保存失败'), findsOneWidget);
      await edit(tester, 'timeout', '300');
      recoverSettingsFile(backup);
      await edit(tester, 'api-key', ' reopen-key ');
      expect((await reload(tester)).apiKey, 'reopen-key');
      expect(find.textContaining('保存失败'), findsNothing);
    },
  );

  testWidgets(
    'review page replacement inherits pending last fields and serializes another field behind prior page',
    (tester) async {
      store.firstWrite = Completer<void>();
      await pumpPage(tester);
      await edit(tester, 'model', 'first-model');
      await edit(tester, 'model', 'last-model');
      await edit(tester, 'api-key', 'last-key');
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await pumpPage(tester);
      expect(
        tester.widget<TextField>(field('model')).controller!.text,
        'last-model',
      );
      expect(
        tester.widget<TextField>(field('api-key')).controller!.text,
        'last-key',
      );
      expect(find.text('正在保存…'), findsOneWidget);
      await edit(tester, 'user-agent', 'second-page-agent');
      expect(
        store.writes,
        hasLength(1),
        reason: 'new page write must wait for prior instance',
      );
      store.firstWrite!.complete();
      await tester.pumpAndSettle();
      final saved = await reload(tester);
      expect(saved.model, 'last-model');
      expect(saved.apiKey, 'last-key');
      expect(saved.customUserAgent, 'second-page-agent');
      expect(saved.toJson()['unknownAi'], {'future': 42});
      expect(find.text('已生效并保存'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'review reopened pending page observes failure completed by disposed original page',
    (tester) async {
      final backup = await blockSettingsFile();
      store.firstWrite = Completer<void>();
      await pumpPage(tester);
      await edit(tester, 'model', 'pending-model');
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await pumpPage(tester);
      store.firstWrite!.complete();
      await tester.pumpAndSettle();
      expect(find.textContaining('保存失败'), findsOneWidget);
      expect(
        tester.widget<TextField>(field('model')).controller!.text,
        'pending-model',
      );
      recoverSettingsFile(backup);
      await edit(tester, 'model', ' pending-model ');
      expect((await reload(tester)).model, 'pending-model');
      expect(find.textContaining('保存失败'), findsNothing);
    },
  );
  testWidgets(
    'review healthy equivalent edit during pending write preserves progress without another write',
    (tester) async {
      store.firstWrite = Completer<void>();
      await pumpPage(tester);
      await edit(tester, 'model', 'pending-model');
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await pumpPage(tester);
      await edit(tester, 'model', ' pending-model ');
      expect(store.writes, hasLength(1));
      expect(find.text('正在保存…'), findsOneWidget);
      store.firstWrite!.complete();
      await tester.pumpAndSettle();
      expect(find.text('已生效并保存'), findsOneWidget);
      expect(store.writes, hasLength(1));
      expect((await reload(tester)).model, 'pending-model');
    },
  );

  testWidgets(
    'review valid equivalent credential retries failed snapshot while another field remains invalid',
    (tester) async {
      await pumpPage(tester);
      final backup = await blockSettingsFile();
      await edit(tester, 'api-key', 'retry-key');
      final failedWrites = store.writes.length;
      await edit(tester, 'timeout', 'invalid');
      expect(
        store.writes.length,
        failedWrites,
        reason: 'invalid field alone must not retry',
      );
      expect(find.textContaining('保存失败'), findsOneWidget);
      recoverSettingsFile(backup);
      await edit(tester, 'api-key', ' retry-key ');
      final saved = await reload(tester);
      expect(saved.apiKey, 'retry-key');
      expect(saved.timeoutSeconds, 300);
      expect(
        tester.widget<TextField>(field('timeout')).controller!.text,
        'invalid',
      );
      expect(
        tester.widget<TextField>(field('timeout')).decoration!.errorText,
        isNotNull,
      );
      expect(find.textContaining('保存失败'), findsNothing);
    },
  );
}
