import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/audio_ai/cue_window.dart';
import 'package:webhtv_pc/core/audio_ai/model_catalog.dart';
import 'package:webhtv_pc/core/audio_ai/pcm_sync.dart';
import 'package:webhtv_pc/services/audio_ai/audio_model_manager.dart';
import 'package:webhtv_pc/services/audio_ai/realtime_subtitle_controller.dart';

/// 延迟引擎：每帧 accept 只有在测试放行后才完成，用来证明队列不被中途清空、
/// stop/seek 能作废在途结果。
class _Engine implements SpeechEngine {
  final starts = <int>[];
  final _pending = <Completer<List<EngineUtterance>>>[];
  int resets = 0;
  bool disposed = false;

  @override
  Future<List<EngineUtterance>> accept(
    PcmFrame frame, {
    required int targetRate,
  }) {
    starts.add(frame.mediaStart.inMilliseconds);
    final completer = Completer<List<EngineUtterance>>();
    _pending.add(completer);
    return completer.future;
  }

  void release(int index, [List<EngineUtterance>? utterances]) {
    if (!_pending[index].isCompleted) {
      _pending[index].complete(utterances ?? const []);
    }
  }

  int get calls => starts.length;

  @override
  void reset() {
    resets++;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

class _DelayedManager extends AudioModelManager {
  _DelayedManager(Directory root) : super(root: root);
  final verified = Completer<List<String>>();

  @override
  Future<List<String>> verify(RealtimeModelSpec spec) => verified.future;
}

const _spec = RealtimeModelSpec(
  id: 'test',
  name: 'test',
  directory: 'test',
  engine: RealtimeSpeechEngine.onlineTransducer,
  minRamMb: 1,
  needsVad: false,
  files: [],
);

PcmFrame _frame(int index) => PcmFrame(
  samples: Float32List(320),
  sampleRate: 16000,
  mediaStart: Duration(milliseconds: index * 20),
  sessionId: 7,
  generation: 0,
);

Future<void> _settle() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

void main() {
  test('实时翻译从非0代际开始，8秒超时契约短时注入回退原文', () async {
    final translator = RealtimeSubtitleTranslator(
      runner: (_) => Completer<String>().future,
      timeout: const Duration(milliseconds: 20),
    );
    final completed = Completer<TranslationResult>();
    translator.bind(completed.complete);
    translator.submit(
      text: 'hello',
      sourceLanguage: 'en',
      generation: 4,
      start: Duration.zero,
      end: const Duration(seconds: 1),
    );
    final result = await completed.future.timeout(const Duration(seconds: 1));
    expect(result.generation, 4);
    expect(result.translated, 'hello');
    translator.reset();
  });

  test('seek取消翻译队列且旧结果不显示', () async {
    final source = Completer<String>();
    final outputs = <TranslationResult>[];
    final translator = RealtimeSubtitleTranslator(runner: (_) => source.future);
    translator.bind(outputs.add);
    translator.submit(
      text: 'old',
      sourceLanguage: 'en',
      generation: 0,
      start: Duration.zero,
      end: const Duration(seconds: 1),
    );
    await Future<void>.delayed(Duration.zero);
    translator.reset();
    source.complete('旧译文');
    await Future<void>.delayed(Duration.zero);
    expect(outputs, isEmpty);
  });

  test('seek后旧PCM识别结果失效，不上屏；暂停帧不识别', () async {
    final temp = Directory.systemTemp.createTempSync('audio_ai_asr_');
    final manager = AudioModelManager(root: temp),
        clock = AudioSessionClock(sessionId: 7, playing: true);
    final engine = _Engine(), pcm = StreamController<PcmFrame>();
    final controller = RealtimeSubtitleController(
      models: manager,
      engineFactory: (_, _) async => engine,
    );
    final cues = <RealtimeSubtitleCue>[];
    final subscription = controller.cues.listen(cues.add);
    expect(
      await controller.start(spec: _spec, pcm: pcm.stream, clock: clock),
      isTrue,
    );
    pcm.add(_frame(0));
    await Future<void>.delayed(Duration.zero);
    controller.seek(position: const Duration(seconds: 8));
    engine.release(0, [
      const EngineUtterance(
        text: 'old',
        start: Duration.zero,
        end: Duration(seconds: 1),
      ),
    ]);
    await Future<void>.delayed(Duration.zero);
    expect(cues, isEmpty);
    expect(engine.resets, greaterThan(0));
    await controller.dispose();
    await subscription.cancel();
    await pcm.close();
    await clock.dispose();
    manager.close();
    temp.deleteSync(recursive: true);
  });

  test('F1 正常有界积压[A,B,C,D]按序全部识别，不中途清队列', () async {
    final temp = Directory.systemTemp.createTempSync('audio_ai_fifo_');
    final manager = AudioModelManager(root: temp);
    final clock = AudioSessionClock(sessionId: 7, playing: true);
    final engine = _Engine(), pcm = StreamController<PcmFrame>();
    final controller = RealtimeSubtitleController(
      models: manager,
      engineFactory: (_, _) async => engine,
    );
    expect(
      await controller.start(spec: _spec, pcm: pcm.stream, clock: clock),
      isTrue,
    );
    for (var i = 0; i < 4; i++) {
      pcm.add(_frame(i));
    }
    await _settle();
    expect(engine.starts, [0], reason: '串行消费一次只该进入一帧');
    for (var i = 0; i < 4; i++) {
      engine.release(i);
      await _settle();
    }
    expect(engine.starts, [0, 20, 40, 60], reason: 'B/C/D 不能被消费首帧时清掉');
    expect(engine.resets, 0, reason: '连续帧不触发识别器重置');
    await controller.dispose();
    await pcm.close();
    await clock.dispose();
    manager.close();
    temp.deleteSync(recursive: true);
  });

  test('F1 溢出才有界丢弃并重置识别基准，不是每帧清空', () async {
    final temp = Directory.systemTemp.createTempSync('audio_ai_overflow_');
    final manager = AudioModelManager(root: temp);
    final clock = AudioSessionClock(sessionId: 7, playing: true);
    final engine = _Engine(), pcm = StreamController<PcmFrame>();
    final controller = RealtimeSubtitleController(
      models: manager,
      engineFactory: (_, _) async => engine,
    );
    await controller.start(spec: _spec, pcm: pcm.stream, clock: clock);
    for (var i = 0; i < 40; i++) {
      pcm.add(_frame(i));
    }
    await _settle();
    var released = 0;
    while (released < engine.calls) {
      engine.release(released);
      released++;
      await _settle();
    }
    expect(engine.calls, lessThanOrEqualTo(17), reason: '队列上限16，超出才清空');
    expect(engine.resets, greaterThanOrEqualTo(1), reason: '丢帧必须重置识别基准');
    await controller.dispose();
    await pcm.close();
    await clock.dispose();
    manager.close();
    temp.deleteSync(recursive: true);
  });

  test('F1 PTS 不连续超过50ms才重置识别与翻译基准', () async {
    final temp = Directory.systemTemp.createTempSync('audio_ai_gap_');
    final manager = AudioModelManager(root: temp);
    final clock = AudioSessionClock(sessionId: 7, playing: true);
    final engine = _Engine(), pcm = StreamController<PcmFrame>();
    final controller = RealtimeSubtitleController(
      models: manager,
      engineFactory: (_, _) async => engine,
    );
    await controller.start(spec: _spec, pcm: pcm.stream, clock: clock);
    pcm.add(_frame(0));
    await _settle();
    engine.release(0);
    await _settle();
    pcm.add(_frame(20)); // 300ms 空洞，超出 50ms 连续阈值
    await _settle();
    engine.release(1);
    await _settle();
    expect(engine.resets, greaterThanOrEqualTo(1));
    await controller.dispose();
    await pcm.close();
    await clock.dispose();
    manager.close();
    temp.deleteSync(recursive: true);
  });

  test('F3 字幕按呈现时钟调度：未来窗口不上屏，到期 tickDisplay 清屏', () async {
    final temp = Directory.systemTemp.createTempSync('audio_ai_cue_');
    final manager = AudioModelManager(root: temp);
    var now = DateTime(2026, 1, 1);
    final clock = AudioSessionClock(
      sessionId: 7,
      playing: true,
      now: () => now,
    );
    final engine = _Engine(), pcm = StreamController<PcmFrame>();
    final controller = RealtimeSubtitleController(
      models: manager,
      engineFactory: (_, _) async => engine,
    );
    final display = <RealtimeSubtitleCue?>[];
    final sub = controller.display.listen(display.add);
    await controller.start(spec: _spec, pcm: pcm.stream, clock: clock);
    pcm.add(_frame(0));
    await _settle();
    engine.release(0, [
      const EngineUtterance(
        text: 'hello',
        start: Duration(seconds: 1),
        end: Duration(seconds: 2),
      ),
    ]);
    await _settle();
    final cue = display.whereType<RealtimeSubtitleCue>().single;
    expect(cue.start, const Duration(seconds: 1));
    expect(cue.end, const Duration(milliseconds: 2500));
    now = now.add(const Duration(milliseconds: 300));
    controller.tickDisplay();
    await _settle();
    expect(display.last, isNotNull, reason: '窗口未到期不清屏');
    now = now.add(const Duration(seconds: 3));
    controller.tickDisplay();
    await _settle();
    expect(display.last, isNull, reason: '窗口到期必须清屏');
    await controller.dispose();
    await sub.cancel();
    await pcm.close();
    await clock.dispose();
    manager.close();
    temp.deleteSync(recursive: true);
  });

  test('F5 stop 作废在途 accept：迟到结果零字幕，且不重启已取消会话', () async {
    final temp = Directory.systemTemp.createTempSync('audio_ai_stop_');
    final manager = AudioModelManager(root: temp);
    final clock = AudioSessionClock(sessionId: 7, playing: true);
    final engine = _Engine(), pcm = StreamController<PcmFrame>();
    final controller = RealtimeSubtitleController(
      models: manager,
      engineFactory: (_, _) async => engine,
    );
    final cues = <RealtimeSubtitleCue>[];
    final sub = controller.cues.listen(cues.add);
    await controller.start(spec: _spec, pcm: pcm.stream, clock: clock);
    pcm.add(_frame(0));
    await _settle();
    await controller.stop();
    engine.release(0, [
      const EngineUtterance(
        text: 'old',
        start: Duration.zero,
        end: Duration(seconds: 1),
      ),
    ]);
    await _settle();
    expect(cues, isEmpty);
    expect(controller.state, RealtimeSubtitleState.off);
    await controller.dispose();
    await sub.cancel();
    await pcm.close();
    await clock.dispose();
    manager.close();
    temp.deleteSync(recursive: true);
  });

  test('F6 取消启用：阻塞 verify 迟到完成不重新开启也不订阅 PCM', () async {
    final temp = Directory.systemTemp.createTempSync('audio_ai_verify_');
    final manager = _DelayedManager(temp);
    final clock = AudioSessionClock(sessionId: 7, playing: true);
    final engine = _Engine(), pcm = StreamController<PcmFrame>.broadcast();
    var factories = 0;
    final controller = RealtimeSubtitleController(
      models: manager,
      engineFactory: (_, _) async {
        factories++;
        return engine;
      },
    );
    final starting = controller.start(
      spec: _spec,
      pcm: pcm.stream,
      clock: clock,
    );
    await _settle();
    await controller.stop();
    manager.verified.complete(const []);
    expect(await starting, isFalse, reason: '被取消的启用必须返回 false');
    expect(controller.state, RealtimeSubtitleState.off);
    expect(factories, 0, reason: '取消后不得再创建引擎');
    pcm.add(_frame(0));
    await _settle();
    expect(engine.calls, 0);
    await controller.dispose();
    await pcm.close();
    await clock.dispose();
    manager.close();
    temp.deleteSync(recursive: true);
  });

  test('F6 取消启用：阻塞 engineFactory 迟到返回的引擎必须 dispose', () async {
    final temp = Directory.systemTemp.createTempSync('audio_ai_factory_');
    final manager = AudioModelManager(root: temp);
    final clock = AudioSessionClock(sessionId: 7, playing: true);
    final engine = _Engine(), pcm = StreamController<PcmFrame>.broadcast();
    final factory = Completer<SpeechEngine>();
    final controller = RealtimeSubtitleController(
      models: manager,
      engineFactory: (_, _) => factory.future,
    );
    final starting = controller.start(
      spec: _spec,
      pcm: pcm.stream,
      clock: clock,
    );
    await _settle();
    await controller.stop();
    factory.complete(engine);
    expect(await starting, isFalse);
    await _settle();
    expect(engine.disposed, isTrue, reason: '迟到引擎必须释放');
    expect(controller.state, RealtimeSubtitleState.off);
    pcm.add(_frame(0));
    await _settle();
    expect(engine.calls, 0, reason: '取消后不得订阅并识别 PCM');
    await controller.dispose();
    await pcm.close();
    await clock.dispose();
    manager.close();
    temp.deleteSync(recursive: true);
  });

  test('F3 字幕窗口：过期丢窗、到期清屏、seek 立即清屏', () {
    const planner = CueWindowPlanner();
    final early = planner.plan(
      start: const Duration(seconds: 1),
      end: const Duration(seconds: 2),
      presented: Duration.zero,
    );
    expect(early, isNotNull);
    expect(planner.plan(
      start: const Duration(seconds: 1),
      end: const Duration(seconds: 2),
      presented: const Duration(seconds: 20),
    ), isNull);
    expect(early!.end, const Duration(milliseconds: 2500));
    expect(planner.contains(early, const Duration(seconds: 2)), isTrue);
    expect(planner.contains(early, const Duration(seconds: 2, milliseconds: 600)), isFalse);
    const upcoming = CueWindow(start: Duration(seconds: 5), end: Duration(seconds: 6));
    expect(planner.contains(upcoming, Duration.zero), isFalse);
  });
}
