import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/audio_ai/model_catalog.dart';
import 'package:webhtv_pc/core/audio_ai/pcm_sync.dart';
import 'package:webhtv_pc/core/audio_ai/pitch_track.dart';
import 'package:webhtv_pc/services/audio_ai/audio_model_manager.dart';
import 'package:webhtv_pc/services/audio_ai/basic_pitch_service.dart';
import 'package:webhtv_pc/services/audio_ai/realtime_subtitle_controller.dart';
import 'package:webhtv_pc/services/audio_ai/windows_audio_capture.dart';

File silenceWav(String path, int sampleCount) {
  final header = ByteData(44);
  void text(int offset, String value) {
    for (var i = 0; i < value.length; i++) {
      header.setUint8(offset + i, value.codeUnitAt(i));
    }
  }
  text(0, 'RIFF');
  header.setUint32(4, 36 + sampleCount * 2, Endian.little);
  text(8, 'WAVEfmt ');
  header.setUint32(16, 16, Endian.little);
  header.setUint16(20, 1, Endian.little);
  header.setUint16(22, 1, Endian.little);
  header.setUint32(24, 16000, Endian.little);
  header.setUint32(28, 32000, Endian.little);
  header.setUint16(32, 2, Endian.little);
  header.setUint16(34, 16, Endian.little);
  text(36, 'data');
  header.setUint32(40, sampleCount * 2, Endian.little);
  final file = File(path);
  final handle = file.openSync(mode: FileMode.write);
  try {
    handle.writeFromSync(header.buffer.asUint8List());
    handle.truncateSync(44 + sampleCount * 2);
  } finally {
    handle.closeSync();
  }
  return file;
}

class VerifiedManager extends AudioModelManager {
  VerifiedManager({required super.root});
  @override
  Future<List<String>> verify(RealtimeModelSpec spec) async => const [];
}

class EndpointEngine implements SpeechEngine {
  final started = Completer<void>();
  final result = Completer<List<EngineUtterance>>();
  @override
  Future<List<EngineUtterance>> accept(PcmFrame frame, {required int targetRate}) {
    if (!started.isCompleted) started.complete();
    return result.future;
  }
  @override
  void reset() {}
  @override
  Future<void> dispose() async {}
}

void main() {
  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('audio_tail_'));
  tearDown(() => temp.deleteSync(recursive: true));

  test('长视频36与60分钟真实SourceReader PTS不截断（N1）', () {
    final wav = silenceWav('${temp.path}/long.wav', 3602 * 16000);
    final api = NativeAudioApi(WindowsAudioCapture.resolveLibrary());
    final handle = api.openMedia(wav.path);
    expect(handle, isNot(nullptr));
    final samples = calloc<Float>(1600);
    final pts = calloc<Int64>();
    try {
      for (final seconds in [2160, 3600]) {
        expect(api.seek(handle, seconds * 1000000), 0);
        expect(api.read(handle, samples, 1600, pts), greaterThan(0));
        expect(pts.value, greaterThanOrEqualTo(seconds * 1000000));
      }
    } finally {
      api.close(handle);
      calloc.free(samples);
      calloc.free(pts);
    }
  });

  test('1.25秒真实WAV尾块800采样仍报告1.2秒PTS（N2）', () {
    final wav = silenceWav('${temp.path}/tail.wav', 20000);
    final api = NativeAudioApi(WindowsAudioCapture.resolveLibrary());
    final handle = api.openMedia(wav.path);
    final samples = calloc<Float>(1600);
    final pts = calloc<Int64>();
    var total = 0;
    var tailCount = 0;
    var tailPts = -1;
    try {
      for (var i = 0; i < 20; i++) {
        pts.value = -123;
        final count = api.read(handle, samples, 1600, pts);
        if (count == -2) break;
        expect(count, greaterThan(0));
        total += count;
        tailCount = count;
        tailPts = pts.value;
      }
      expect(total, 20000);
      expect(tailCount, 800);
      expect(tailPts, 1200000);
    } finally {
      api.close(handle);
      calloc.free(samples);
      calloc.free(pts);
    }
  });

  test('读取EOS不丢尚未到呈现时间的真实尾帧（N2）', () async {
    final wav = silenceWav('${temp.path}/capture.wav', 20000);
    var now = DateTime(2026);
    final clock = AudioSessionClock(sessionId: 91, playing: true, now: () => now);
    Timer? progress;
    final capture = WindowsAudioCapture();
    final frames = <PcmFrame>[];
    final completed = Completer<void>();
    var active = false;
    final pcm = capture.frames.listen(frames.add);
    final state = capture.states.listen((value) {
      if (value == AudioCaptureState.capturing) active = true;
      if (value == AudioCaptureState.off && active && !completed.isCompleted) {
        completed.complete();
      }
    });
    try {
      expect(await capture.start(clock: clock, mediaUri: wav.uri), isTrue);
      progress = Timer.periodic(const Duration(milliseconds: 20), (_) {
        now = now.add(const Duration(milliseconds: 20));
      });
      await completed.future.timeout(const Duration(seconds: 6));
      expect(frames.fold<int>(0, (sum, frame) => sum + frame.samples.length), 20000);
      expect(frames.last.mediaEnd.inMicroseconds, 1250000);
    } finally {
      progress?.cancel();
      await pcm.cancel();
      await state.cancel();
      await capture.dispose();
      await clock.dispose();
    }
  });

  test('旧seek样本和EOS不得推进新代际读取器（N3）', () {
    final scheduler = MediaPcmReadScheduler();
    scheduler.reset(const Duration(seconds: 1));
    expect(scheduler.received(pts: const Duration(seconds: 10), count: 1600,
      sampleRate: 16000, generation: 0, currentGeneration: 1), isFalse);
    expect(scheduler.nextPts, const Duration(seconds: 1));
    expect(scheduler.markEnd(generation: 0, currentGeneration: 1), isFalse);
    expect(scheduler.ended, isFalse);
    expect(scheduler.shouldRead(position: const Duration(seconds: 1), playing: true), isTrue);
    expect(scheduler.received(pts: const Duration(seconds: 1), count: 1600,
      sampleRate: 16000, generation: 1, currentGeneration: 1), isTrue);
    expect(scheduler.nextPts, const Duration(milliseconds: 1100));
    expect(scheduler.markEnd(generation: 1, currentGeneration: 1), isTrue);
    expect(scheduler.shouldRead(position: const Duration(seconds: 2), playing: true), isFalse);
    scheduler.reset(const Duration(milliseconds: 500));
    expect(scheduler.ended, isFalse);
  });

  test('自然1秒语音在端点到达后有限时可见（N4）', () async {
    final manager = VerifiedManager(root: temp);
    final engine = EndpointEngine();
    final translation = Completer<String>();
    final translating = Completer<void>();
    final controller = RealtimeSubtitleController(
      models: manager,
      engineFactory: (_, _) async => engine,
      runner: (_) {
        if (!translating.isCompleted) translating.complete();
        return translation.future;
      },
    );
    var now = DateTime(2026);
    final clock = AudioSessionClock(sessionId: 9, playing: true, now: () => now);
    final pcm = StreamController<PcmFrame>();
    try {
      expect(await controller.start(
        spec: const RealtimeModelSpec(
          id: 'endpoint', name: 'endpoint', directory: 'endpoint',
          engine: RealtimeSpeechEngine.onlineTransducer,
          minRamMb: 1, needsVad: false, files: [],
        ),
        pcm: pcm.stream,
        clock: clock,
      ), isTrue);
      pcm.add(PcmFrame(samples: Float32List(16000), sampleRate: 16000,
        mediaStart: Duration.zero, sessionId: 9, generation: 0));
      await engine.started.future;
      now = now.add(const Duration(seconds: 1));
      engine.result.complete(const [EngineUtterance(text: 'hello', start: Duration.zero, end: Duration(seconds: 1))]);
      await translating.future;
      expect(controller.currentCue?.text, 'hello');
      expect(controller.currentCue!.end - clock.position, greaterThanOrEqualTo(const Duration(milliseconds: 900)));
      final windowEnd = controller.currentCue!.end;
      now = now.add(const Duration(milliseconds: 600));
      translation.complete('你好');
      await Future<void>.delayed(Duration.zero);
      expect(controller.currentCue!.translatedText, '你好');
      expect(controller.currentCue!.end, windowEnd, reason: '有效译文沿用当前窗口，不延长也不按旧语音起点拒绝');
      now = now.add(const Duration(seconds: 8));
      controller.tickDisplay();
      expect(controller.currentCue, isNull);
    } finally {
      await controller.dispose();
      await pcm.close();
      await clock.dispose();
      manager.close();
    }
  });

  test('60ms短歌词按源120ms最小评分窗保留（O1）', () {
    final segments = buildKaraokeSegments(const [
      TimedLyricLine(index: 0, startMs: 0, endMs: 60, text: 'a'),
      TimedLyricLine(index: 1, startMs: 200, endMs: 260, text: 'b'),
      TimedLyricLine(index: 2, startMs: 400, endMs: 460, text: 'c'),
    ], durationMs: 1000);
    expect(segments.map((segment) => (segment.startMs, segment.endMs)).toList(),
      [(0, 120), (200, 320), (400, 520)]);
    final clipped = buildKaraokeSegments(const [
      TimedLyricLine(index: 0, startMs: 0, endMs: 200, text: 'a'),
      TimedLyricLine(index: 1, startMs: 300, endMs: 500, text: 'b'),
      TimedLyricLine(index: 2, startMs: 600, endMs: 800, text: 'c'),
      TimedLyricLine(index: 3, startMs: 1200, endMs: 1400, text: 'd'),
    ], durationMs: 1000);
    expect(clipped.map((segment) => segment.text).toList(), ['a','b','c']);
    expect(clipped.every((segment) => segment.endMs <= 1000), isTrue);
  });

  test('BasicPitch帧位置按源Math.round而非截断（O3）', () {
    expect(basicPitchFrameTimeMs(0, 0), 0);
    expect(basicPitchFrameTimeMs(0, 1), 12);
    expect(basicPitchFrameTimeMs(0, 2), 23);
    expect(basicPitchFrameTimeMs(12, 0), 1);
    expect(basicPitchFrameTimeMs(44100, 1), 2012);
  });

  test('显式歌词结束时间不被末行三秒默认值覆盖（N6）', () {
    final segments = buildKaraokeSegments(const [
      TimedLyricLine(index: 0, startMs: 0, endMs: 650, text: 'la'),
      TimedLyricLine(index: 1, startMs: 650, endMs: 1300, text: 'la'),
      TimedLyricLine(index: 2, startMs: 1300, endMs: 1800, text: 'la'),
    ]);
    expect(segments.every((segment) => segment.endMs <= 1800), isTrue);
  });
}

