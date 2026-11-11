import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/audio_ai/pcm_sync.dart';
import 'package:webhtv_pc/services/audio_ai/windows_audio_capture.dart';

void main() {
  test('不允许捕获当前进程的混合TTS，明确提供媒体解码 fallback', () {
    expect(
      () => WindowsAudioCapture.validateProcessId(100, 100),
      throwsA(isA<AudioCaptureException>()),
    );
    expect(
      () => WindowsAudioCapture.validateProcessId(101, 100),
      returnsNormally,
    );
  });
  test('暂停时不产帧，媒体帧保留 generation 且倍速时帧末点缩放', () {
    final clock = AudioSessionClock(
      sessionId: 3,
      position: const Duration(seconds: 8),
    );
    final chunk = NativePcmChunk(
      Float32List(1600),
      16000,
      const Duration(seconds: 8),
    );
    expect(
      WindowsAudioCapture.frameFor(chunk, clock, mediaDecoded: true),
      isNull,
    );
    clock.update(playing: true, rate: 2);
    final frame = WindowsAudioCapture.frameFor(
      chunk,
      clock,
      mediaDecoded: false,
    )!;
    expect(frame.sessionId, 3);
    expect(frame.generation, 0);
    expect(
      frame.mediaEnd - frame.mediaStart,
      const Duration(milliseconds: 200),
    );
    clock.reset(position: const Duration(seconds: 2), sessionId: 3);
    expect(
      clock.isCurrent(sessionId: frame.sessionId, generation: frame.generation),
      isFalse,
    );
  });

  test('F2 160/320短包与不规则尾包1x/2x按真实PTS排空且暂停/seek重置', () {
    for (final rate in [1.0, 2.0]) {
      final scheduler = MediaPcmReadScheduler();
      scheduler.reset(Duration.zero);
      var pts = Duration.zero, samples = 0;
      for (final count in [160, 320, 1600, 73]) {
        scheduler.received(pts: pts, count: count, sampleRate: 16000);
        pts += Duration(microseconds: (count * 1000000 / 16000).round());
        samples += count;
        expect(scheduler.nextPts, pts, reason: '进度必须等于真实pts+count/rate');
      }
      expect(samples, 2153);
      final position = Duration(microseconds: (200000 * rate).round());
      expect(scheduler.shouldRead(position: position, playing: true, rate: rate), isTrue);
      expect(scheduler.shouldRead(position: position, playing: false, rate: rate), isFalse);
      expect(scheduler.needsSeek(const Duration(seconds: 8)), isTrue);
      scheduler.reset(const Duration(seconds: 8));
      expect(scheduler.nextPts, const Duration(seconds: 8));
      expect(scheduler.needsSeek(const Duration(seconds: 8)), isFalse);
      expect(scheduler.shouldRead(position: const Duration(seconds: 8), playing: true, rate: rate), isTrue);
    }
  });

  test('F2 缓冲已领先时钟时停止读取，落后时（含2x）继续排空', () {
    final scheduler = MediaPcmReadScheduler();
    scheduler.reset(Duration.zero);
    scheduler.received(pts: Duration.zero, count: 32000, sampleRate: 16000);
    expect(scheduler.nextPts, const Duration(seconds: 2));
    const position = Duration(seconds: 1);
    expect(
      scheduler.shouldRead(position: position, playing: true, rate: 1),
      isFalse,
    );
    expect(
      scheduler.shouldRead(position: position, playing: true, rate: 2),
      isFalse,
    );
    scheduler.reset(Duration.zero);
    scheduler.received(pts: Duration.zero, count: 320, sampleRate: 16000);
    expect(
      scheduler.shouldRead(position: position, playing: true, rate: 2),
      isTrue,
    );
    expect(
      scheduler.needsSeek(position),
      isTrue,
      reason: '落后超过500ms才允许 catch-up seek',
    );
  });
}
