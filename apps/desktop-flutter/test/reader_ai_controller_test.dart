import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/reader/reader_models.dart';
import 'package:webhtv_pc/services/reader/reader_preferences_store.dart';
import 'package:webhtv_pc/services/reader/reader_tts_controller.dart';
import 'package:webhtv_pc/services/reader/tts_engines.dart';

class FixtureEngine implements TtsEngine {
  final spoken = <String>[];
  Completer<TtsAudio>? pending;
  bool fail = false;
  Completer<void>? disposing;
  Completer<void>? disposeStarted;
  @override
  Future<List<TtsVoice>> voices() async => const [
    TtsVoice('fixture', '声音', 'zh-CN'),
  ];
  @override
  Future<TtsAudio> synthesize(String text, TtsOptions options) async {
    spoken.add(text);
    if (fail) throw StateError('系统TTS未安装');
    return pending == null
        ? TtsAudio(Uint8List.fromList([1, 2, 3]), 'mp3')
        : pending!.future;
  }

  @override
  void cancel() {}
  @override
  Future<void> dispose() async {
    if (disposeStarted?.isCompleted == false) disposeStarted!.complete();
    await disposing?.future;
  }
}

class FixtureAudio implements ReaderAudioOutput {
  Completer<void>? pending;
  int plays = 0;
  @override
  Future<void> play(TtsAudio audio) {
    plays++;
    return (pending = Completer<void>()).future;
  }

  void complete() {
    pending?.complete();
    pending = null;
  }

  @override
  Future<void> stop() async {
    if (pending != null && !pending!.isCompleted) complete();
  }

  @override
  Future<void> dispose() async => stop();
}

void main() {
  late Directory dir;
  late FixtureEngine engine;
  late FixtureAudio output;
  late ReaderTtsController controller;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('reader-test-');
    engine = FixtureEngine();
    output = FixtureAudio();
    controller = ReaderTtsController(
      engines: TtsEngines(factory: (settings) => engine),
      store: ReaderPreferencesStore('${dir.path}/reader.json'),
      audio: output,
    );
  });
  tearDown(() async {
    await controller.close();
    dir.deleteSync(recursive: true);
  });
  test('暂停即时通知监听者并保留当前段落', () async {
    await controller.start(paragraphs: ['正文', '后文']);
    await Future<void>.delayed(Duration.zero);
    final states = <ReaderTtsState>[];
    controller.addListener(() => states.add(controller.state));
    await controller.pause();
    expect(states, [ReaderTtsState.paused]);
    expect(controller.currentParagraph, 0);
  });
  test('追加定时与直接设置统一600分钟上限并持久化', () async {
    await controller.setTimer(590);
    await controller.addTimer(30);
    expect(controller.timerMinutes, 600);
    expect(
      ReaderPreferencesStore('${dir.path}/reader.json').load().timerMinutes,
      600,
    );
    await controller.addTimer(-900);
    expect(controller.timerMinutes, 0);
  });
  test('定时监听者收到的是同一次更新的提示与分钟', () async {
    final updates = <(int, String)>[];
    controller.addListener(
      () => updates.add((controller.timerMinutes, controller.message)),
    );
    await controller.setTimer(30);
    expect(updates.last, (30, '朗读定时 30 分钟'));
    await controller.setTimer(0);
    expect(updates.last, (0, ''));
  });
  test('章末释放延迟不覆盖新一轮朗读状态', () async {
    await controller.start(paragraphs: ['旧正文']);
    await Future<void>.delayed(Duration.zero);
    engine.disposing = Completer<void>();
    engine.disposeStarted = Completer<void>();
    output.complete();
    await engine.disposeStarted!.future;
    await controller.stop();
    await controller.start(paragraphs: ['新正文']);
    await Future<void>.delayed(Duration.zero);
    engine.disposing!.complete();
    await Future<void>.delayed(Duration.zero);
    expect(controller.state, ReaderTtsState.playing);
    expect(controller.currentParagraph, 0);
    expect(engine.spoken.last, '新正文');
  });
  test('章末清理期间暂停恢复不进入无引擎playing（N1）', () async {
    await controller.start(paragraphs: ['正文']);
    await Future<void>.delayed(Duration.zero);
    engine.disposing = Completer<void>();
    engine.disposeStarted = Completer<void>();
    output.complete();
    await engine.disposeStarted!.future;
    try {
      await controller.pause();
      await controller.resume();
    } finally {
      engine.disposing!.complete();
    }
    await Future<void>.delayed(Duration.zero);
    expect(controller.state, ReaderTtsState.stopped);
    expect(controller.currentParagraph, -1);
    expect(output.plays, 1);
  });
  test('章末清理期间跳段不复活空引擎或重复章末通知（N1）', () async {
    var ended = 0;
    controller.onChapterEnd = () => ended++;
    await controller.start(paragraphs: ['正文']);
    await Future<void>.delayed(Duration.zero);
    engine.disposing = Completer<void>();
    engine.disposeStarted = Completer<void>();
    output.complete();
    await engine.disposeStarted!.future;
    try {
      await controller.seekParagraph(0);
      await controller.next();
    } finally {
      engine.disposing!.complete();
    }
    await Future<void>.delayed(Duration.zero);
    expect(controller.state, ReaderTtsState.stopped);
    expect(ended, 1);
    expect(output.plays, 1);
  });
  test('末段下一段停止在途播放并阻止旧pump推进', () async {
    await controller.start(paragraphs: ['正文']);
    await Future<void>.delayed(Duration.zero);
    await controller.next();
    await Future<void>.delayed(Duration.zero);
    expect(output.pending, isNull);
    expect(controller.currentParagraph, -1);
    expect(controller.state, ReaderTtsState.stopped);
  });
  test('代理对在硬边界与软停顿后完整保留', () {
    for (final text in [
      '${'甲' * 159}𠮷${'乙' * 170}',
      '${'甲' * 90}，${'乙' * 68}𠮷${'丙' * 170}',
    ]) {
      final chunks = splitTtsText([text], online: true);
      expect(chunks.map((chunk) => chunk.text).join(), text);
      expect(chunks.every((chunk) => chunk.text.length <= 160), isTrue);
      for (final chunk in chunks) {
        expect(
          chunk.text.codeUnitAt(0),
          isNot(inInclusiveRange(0xdc00, 0xdfff)),
        );
        expect(
          chunk.text.codeUnitAt(chunk.text.length - 1),
          isNot(inInclusiveRange(0xd800, 0xdbff)),
        );
      }
    }
  });
  test('首段上一段重放首段而不是停到负索引', () async {
    await controller.start(paragraphs: ['第一段', '第二段']);
    await Future<void>.delayed(Duration.zero);
    await controller.previous();
    await Future<void>.delayed(Duration.zero);
    expect(controller.currentParagraph, 0);
    expect(engine.spoken, ['第一段', '第一段']);
  });
  test('损坏偏好恢复默认值且下一次保存可用', () async {
    File('${dir.path}/reader.json').writeAsStringSync('{broken');
    controller.loadPreferences();
    expect(controller.source, TtsSource.system);
    expect(controller.timerMinutes, 0);
    await controller.setRate(1.5);
    expect(
      ReaderPreferencesStore('${dir.path}/reader.json').load().options.rate,
      1.5,
    );
  });
  test('偏好重启恢复并夹取源参数范围', () async {
    await controller.setSource(TtsSource.edge);
    await controller.setRate(9);
    await controller.setPitch(0.1);
    await controller.setVoice('zh-CN-YunxiNeural');
    await controller.setTimer(900);
    final saved = ReaderPreferencesStore('${dir.path}/reader.json').load();
    expect(saved.source, TtsSource.edge);
    expect(saved.options.rate, 2);
    expect(saved.options.pitch, .5);
    expect(saved.options.voice, 'zh-CN-YunxiNeural');
    expect(saved.timerMinutes, 600);
  });
  test('段落推进、章末事件先于停止', () async {
    final states = <ReaderTtsState>[];
    controller.onChapterEnd = () => states.add(controller.state);
    await controller.start(paragraphs: ['第一段', '第二段']);
    await Future<void>.delayed(Duration.zero);
    expect(controller.currentParagraph, 0);
    output.complete();
    await Future<void>.delayed(Duration.zero);
    expect(controller.currentParagraph, 1);
    output.complete();
    await Future<void>.delayed(Duration.zero);
    expect(states, [ReaderTtsState.playing]);
    expect(controller.state, ReaderTtsState.stopped);
  });
  test('暂停停止与下一段清除过期合成', () async {
    engine.pending = Completer<TtsAudio>();
    await controller.start(paragraphs: ['第一段', '第二段']);
    await controller.pause();
    engine.pending!.complete(TtsAudio(Uint8List.fromList([1]), 'wav'));
    await Future<void>.delayed(Duration.zero);
    expect(output.plays, 0);
    await controller.resume();
    await Future<void>.delayed(Duration.zero);
    expect(output.plays, 1);
    await controller.stop();
    expect(controller.currentParagraph, -1);
    expect(controller.state, ReaderTtsState.stopped);
  });
  test('真实引擎失败公开原因而非虚假播放成功', () async {
    engine.fail = true;
    await controller.start(paragraphs: ['正文']);
    await Future<void>.delayed(Duration.zero);
    expect(controller.state, ReaderTtsState.error);
    expect(controller.message, contains('系统TTS未安装'));
    expect(output.plays, 0);
  });
  testWidgets('定时只消耗播放分钟，暂停不消耗', (tester) async {
    await controller.setTimer(1);
    await controller.start(paragraphs: ['正文']);
    await tester.pump();
    await controller.pause();
    await tester.pump(const Duration(minutes: 1));
    expect(controller.timerMinutes, 1);
    await controller.resume();
    await tester.pump(const Duration(minutes: 1));
    expect(controller.state, ReaderTtsState.stopped);
    expect(controller.message, contains('定时'));
  });
  test('在线分句保留段落索引与160字上限，静音片段跳过', () {
    final chunks = splitTtsText(['……', '第一句。第二句！', '长' * 400], online: true);
    expect(chunks.take(2).map((c) => c.paragraph), [1, 1]);
    expect(chunks.every((c) => c.text.length <= 160), isTrue);
  });
}
