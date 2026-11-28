import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/ai_integration_widgets.dart';
import 'package:webhtv_pc/ui/diagnostics_pages.dart';
import 'package:webhtv_pc/ui/glass_dialog.dart';
import 'package:webhtv_pc/ui/search_page.dart';
import 'package:webhtv_pc/core/reader/reader_models.dart';
import 'package:webhtv_pc/services/reader/reader_preferences_store.dart';
import 'package:webhtv_pc/services/reader/reader_tts_controller.dart';
import 'package:webhtv_pc/services/reader/tts_engines.dart';
import 'package:webhtv_pc/ui/theme.dart';

void main() {
  late Directory temp;
  late AppState state;
  Future<void> bootstrapState() async {
    temp = await Directory.systemTemp.createTemp('parity-ui-');
    final paths = AppPaths.resolve(
      overrides: {
        'config': '${temp.path}/config',
        'data': '${temp.path}/data',
        'cache': '${temp.path}/cache',
        'state': '${temp.path}/log',
      },
    );
    state = AppState(paths: paths, log: LogService());
    addTearDown(() async {
      state.dispose();
      await temp.delete(recursive: true);
    });
    await state.bootstrap();
  }

  Widget host(Widget child) =>
      MaterialApp(theme: buildAppTheme(Brightness.dark), home: child);

  Future<void> openFromSettings(WidgetTester tester, AppState state) async {
    await tester.pumpWidget(host(SettingsPage(state: state)));
    // 设置页自 beta 起是分类导航：AI 入口在「连接与增强」分类里，
    // 必须先切到该分类，再在它的滚动区里找按钮。
    await tester.tap(
      find.byKey(const ValueKey('settings-category-connections')),
    );
    await tester.pumpAndSettle();
    final entry = find.byKey(const ValueKey('settings-ai-business-open'));
    final scrollable = find.descendant(
      of: find.byKey(
        const ValueKey('settings-category-content-connections'),
      ),
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(entry, 180, scrollable: scrollable);
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(find.byType(AiBusinessPage), findsOneWidget);
  }

  testWidgets('设置真实入口打开统一AI业务页，未配置不启动AI', (tester) async {
    await tester.runAsync(bootstrapState);
    await openFromSettings(tester, state);
    expect(find.textContaining('未配置'), findsWidgets);
    expect(state.aiTitleExtractionEnabled, isFalse);
    expect(state.aiAdDetectionEnabled, isFalse);
  });

  for (final (entry, action) in [
    ('导出AI用户数据', 'Cancel'),
    ('导出AI用户数据', 'Escape'),
    ('导入AI用户数据', 'Confirm path'),
    ('导入AI用户数据', 'Blank path'),
  ]) {
    testWidgets(
      'Settings $entry input stays usable while dismissing via $action',
      (tester) async {
        final fixture = Directory.systemTemp.createTempSync(
          'ai-path-settings-',
        );
        final state = _AiPathSettingsState(
          paths: AppPaths.resolve(
            overrides: {
              'config': '${fixture.path}/config',
              'data': '${fixture.path}/data',
              'cache': '${fixture.path}/cache',
              'state': '${fixture.path}/state',
            },
          ),
        );
        addTearDown(() {
          state.dispose();
          fixture.deleteSync(recursive: true);
        });
        await openFromSettings(tester, state);
        await tester.tap(find.text(entry));
        await tester.pumpAndSettle();

        final field = find.byType(EditableText, skipOffstage: false);
        final editable = tester.widget<EditableText>(field);
        final route = ModalRoute.of(tester.element(field))!;
        final fieldFocus = editable.focusNode;
        expect(
          editable.controller.text,
          endsWith('${Platform.pathSeparator}ai-user-data.json'),
        );
        await tester.enterText(
          field,
          action == 'Blank path' ? '  ' : ' fixture.json ',
        );
        await tester.pump();
        expect(fieldFocus.hasPrimaryFocus, isTrue);
        expect(tester.takeException(), isNull);

        if (action == 'Escape') {
          final visited = <FocusNode>{fieldFocus};
          for (var i = 0; i < 3; i++) {
            await tester.sendKeyEvent(LogicalKeyboardKey.tab);
            await tester.pump();
            final focused = FocusManager.instance.primaryFocus!;
            expect(ModalRoute.of(focused.context!), same(route));
            visited.add(focused);
          }
          expect(visited, hasLength(3));
          expect(fieldFocus.hasPrimaryFocus, isTrue);
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        } else {
          await tester.tap(find.text(action == 'Cancel' ? '取消' : '确定'));
        }
        final errors = <String>[];
        final reverseFrames = <(int, double)>[];
        final onError = FlutterError.onError!;
        FlutterError.onError = (details) {
          errors.add('${details.exceptionAsString()}\n${details.stack}');
          onError(details);
        };
        try {
          await tester.pump();
          for (final millis in [16, 32]) {
            await tester.pump(Duration(milliseconds: millis));
            reverseFrames.add((
              field.evaluate().length,
              route.animation!.value,
            ));
            tester.takeException();
          }
          await tester.pumpAndSettle();
          tester.takeException();
        } finally {
          FlutterError.onError = onError;
        }
        expect(errors, isEmpty, reason: '$action while reversing');
        for (final (fields, progress) in reverseFrames) {
          expect(fields, 1);
          expect(progress, allOf(greaterThan(0), lessThan(1)));
        }
        expect(field, findsNothing);
        expect(fieldFocus.hasFocus, isFalse);
        if (action == 'Confirm path') {
          expect(find.text('确认导入'), findsOneWidget);
          await tester.tap(find.text('取消'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
        expect(find.byType(GlassAlertDialog), findsNothing);
        final page = find.byType(AiBusinessPage);
        expect(page, findsOneWidget);
        if (action == 'Escape') {
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pump();
          final focused = FocusManager.instance.primaryFocus!;
          expect(
            ModalRoute.of(focused.context!),
            same(ModalRoute.of(tester.element(page))),
          );
          expect(tester.takeException(), isNull);
        }
      },
    );
  }

  testWidgets('搜索入口包含语音与关键词AI推荐，保留现有搜索输入', (tester) async {
    await tester.runAsync(bootstrapState);
    // 真实应用里 SearchPage 由 shell 的 Scaffold 承载；这里用同一个宿主，
    // 不对生产 SearchPage 做测试专用包装。
    await tester.pumpWidget(
      host(
        Scaffold(
          appBar: AppBar(title: const Text('搜索')),
          body: SearchPage(state: state),
        ),
      ),
    );
    expect(find.byTooltip('语音搜索'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('search-input')), '真实片名');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('search-ai-recommendations')));
    await tester.pumpAndSettle();
    expect(find.byType(AiBusinessPage), findsOneWidget);
    expect(find.textContaining('真实片名'), findsWidgets);
  });

  testWidgets('阅读器真实入口编辑正文后打开既有ReaderPage完整控件', (tester) async {
    await tester.runAsync(bootstrapState);
    final controller = ReaderTtsController(
      engines: TtsEngines(factory: (_) => _ReaderEngine()),
      store: ReaderPreferencesStore('${temp.path}/reader_tts.json'),
      audio: _ReaderAudio(),
    );
    addTearDown(controller.close);
    await tester.pumpWidget(
      host(
        Scaffold(
          body: AiBusinessPage(state: state, readerController: controller),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('ai-reader-open')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('ai-reader-text')),
      '第一段\n第二段',
    );
    await tester.tap(find.byKey(const ValueKey('ai-reader-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('第一段'), findsOneWidget);
    expect(find.byTooltip('开始朗读'), findsOneWidget);
    expect(find.byTooltip('定时朗读'), findsOneWidget);
    expect(find.byTooltip('朗读设置'), findsOneWidget);
  });
}

class _AiPathSettingsState extends AppState {
  _AiPathSettingsState({required super.paths});

  @override
  bool get aiReady => false;
}

class _ReaderEngine implements TtsEngine {
  @override
  Future<List<TtsVoice>> voices() async => const [];

  @override
  Future<TtsAudio> synthesize(String text, TtsOptions options) async =>
      TtsAudio(Uint8List.fromList([1]), 'wav');

  @override
  Future<void> cancel() async {}

  @override
  Future<void> dispose() async {}
}

class _ReaderAudio implements ReaderAudioOutput {
  @override
  Future<void> play(TtsAudio audio) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}
