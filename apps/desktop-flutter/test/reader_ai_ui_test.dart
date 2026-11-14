import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/reader/reader_models.dart';
import 'package:webhtv_pc/services/reader/reader_preferences_store.dart';
import 'package:webhtv_pc/services/reader/reader_tts_controller.dart';
import 'package:webhtv_pc/services/reader/tts_engines.dart';
import 'package:webhtv_pc/services/speech_search_service.dart';
import 'package:webhtv_pc/ui/reader/reader_page.dart';
import 'package:webhtv_pc/ui/speech_search_button.dart';

class _Engine implements TtsEngine {
  int calls = 0;
  @override
  Future<List<TtsVoice>> voices() async => const [];
  @override
  Future<TtsAudio> synthesize(String text, TtsOptions options) async {
    calls++;
    return TtsAudio(Uint8List.fromList([1]), 'wav');
  }

  @override
  void cancel() {}
  @override
  Future<void> dispose() async {}
}

class _Audio implements ReaderAudioOutput {
  int plays = 0;
  @override
  Future<void> play(TtsAudio audio) async => plays++;
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}

class _BlockingAudio implements ReaderAudioOutput {
  Completer<void>? pending;
  @override
  Future<void> play(TtsAudio audio) => (pending = Completer<void>()).future;
  @override
  Future<void> stop() async {
    if (pending?.isCompleted == false) pending!.complete();
  }

  @override
  Future<void> dispose() => stop();
}

class _Host implements SpeechRecognitionHost {
  @override
  Future<List<String>> recognize({String? language}) async => [
    language == 'en-US' ? 'Dune' : '流浪地球',
  ];
  @override
  void cancel() {}
}

void main() {
  testWidgets('阅读器入口渲染正文并可开始段落朗读', (tester) async {
    final directory = Directory.systemTemp.createTempSync('reader-ui-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final engine = _Engine();
    final audio = _Audio();
    final controller = ReaderTtsController(
      engines: TtsEngines(factory: (_) => engine),
      store: ReaderPreferencesStore(
        '${directory.path}${Platform.pathSeparator}reader.json',
      ),
      audio: audio,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ReaderPage(
          controller: controller,
          initialText: '第一段\n第二段',
          title: '测试书',
        ),
      ),
    );
    expect(find.text('第一段'), findsOneWidget);
    expect(find.text('测试书'), findsOneWidget);
    await tester.tap(find.byTooltip('开始朗读'));
    await tester.pump();
    expect(engine.calls, greaterThanOrEqualTo(1));
    expect(controller.paragraphCount, 2);
    await controller.close();
  });
  testWidgets('阅读器暂停后显示继续入口并重放当前段落', (tester) async {
    final directory = Directory.systemTemp.createTempSync('reader-resume-ui-');
    final engine = _Engine();
    final controller = ReaderTtsController(
      engines: TtsEngines(factory: (_) => engine),
      store: ReaderPreferencesStore('${directory.path}/reader.json'),
      audio: _BlockingAudio(),
    );
    addTearDown(() async {
      await controller.close();
      directory.deleteSync(recursive: true);
    });
    await tester.pumpWidget(
      MaterialApp(
        home: ReaderPage(controller: controller, initialText: '第一段\n第二段'),
      ),
    );
    await tester.tap(find.byTooltip('开始朗读'));
    await tester.pump();
    await tester.tap(find.byTooltip('暂停'));
    await tester.pump();
    expect(controller.state, ReaderTtsState.paused);
    expect(find.byTooltip('继续朗读'), findsOneWidget);
    expect(find.textContaining('已暂停'), findsOneWidget);
    await tester.tap(find.byTooltip('继续朗读'));
    await tester.pump();
    expect(controller.state, ReaderTtsState.playing);
    expect(controller.currentParagraph, 0);
    expect(engine.calls, 2);
    expect(find.byTooltip('暂停'), findsOneWidget);
  });
  testWidgets('语音搜索入口消费指定语言的识别文本', (tester) async {
    String? received;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SpeechSearchButton(
            service: SpeechSearchService(host: _Host()),
            language: 'en-US',
            onRecognized: (text) => received = text,
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('语音搜索'));
    await tester.pumpAndSettle();
    expect(find.text('Dune'), findsOneWidget);
    await tester.tap(find.text('使用该文本'));
    await tester.pumpAndSettle();
    expect(received, 'Dune');
  });
  testWidgets('语音搜索按钮回传首条识别文本', (tester) async {
    String? received;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SpeechSearchButton(
            service: SpeechSearchService(host: _Host()),
            onRecognized: (text) => received = text,
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('语音搜索'));
    await tester.pumpAndSettle();
    expect(find.text('流浪地球'), findsOneWidget);
    await tester.tap(find.text('使用该文本'));
    await tester.pumpAndSettle();
    expect(received, '流浪地球');
  });
}
