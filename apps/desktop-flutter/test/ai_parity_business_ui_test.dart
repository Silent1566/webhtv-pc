import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/ai_integration_widgets.dart';
import 'package:webhtv_pc/ui/diagnostics_pages.dart';
import 'package:webhtv_pc/ui/search_page.dart';
import 'package:webhtv_pc/core/reader/reader_models.dart';
import 'package:webhtv_pc/services/reader/reader_preferences_store.dart';
import 'package:webhtv_pc/services/reader/reader_tts_controller.dart';
import 'package:webhtv_pc/services/reader/tts_engines.dart';
import 'package:webhtv_pc/ui/theme.dart';

void main() {
  late Directory temp;
  late AppState state;
  setUp(() async {
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
    await state.bootstrap();
  });
  tearDown(() async {
    state.dispose();
    await temp.delete(recursive: true);
  });

  Widget host(Widget child) =>
      MaterialApp(theme: buildAppTheme(Brightness.dark), home: child);

  testWidgets('设置真实入口打开统一AI业务页，未配置不启动AI', (tester) async {
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
    expect(find.textContaining('未配置'), findsWidgets);
    expect(state.aiTitleExtractionEnabled, isFalse);
    expect(state.aiAdDetectionEnabled, isFalse);
  });

  testWidgets('搜索入口包含语音与关键词AI推荐，保留现有搜索输入', (tester) async {
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
