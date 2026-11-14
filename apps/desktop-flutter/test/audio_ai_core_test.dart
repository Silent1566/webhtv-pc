import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/audio_ai/model_catalog.dart';
import 'package:webhtv_pc/core/audio_ai/pcm_sync.dart';
import 'package:webhtv_pc/core/audio_ai/pitch_track.dart';
import 'package:webhtv_pc/core/audio_ai/srt_cues.dart';
import 'package:webhtv_pc/core/audio_ai/translation_plan.dart';

void main() {
  group('模型目录对齐源 catalog', () {
    test('8 个模型与固定 VAD 哈希', () {
      expect(RealtimeModelCatalog.models, hasLength(8));
      expect(RealtimeModelCatalog.vad.size, 643854);
      expect(
        RealtimeModelCatalog.vad.sha256,
        '9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6',
      );
      final zh = RealtimeModelCatalog.find('zh');
      expect(zh.engine, RealtimeSpeechEngine.onlineTransducer);
      expect(zh.downloads.map((file) => file.relativePath), [
        'encoder-epoch-99-avg-1.int8.onnx',
        'decoder-epoch-99-avg-1.onnx',
        'joiner-epoch-99-avg-1.int8.onnx',
        'tokens.txt',
      ]);
    });

    test('需要 VAD 的模型把 VAD 排在下载首位', () {
      final yue = RealtimeModelCatalog.find('yue');
      expect(yue.needsVad, isTrue);
      expect(yue.engine, RealtimeSpeechEngine.offlineWenetCtc);
      expect(yue.downloads.first.relativePath, 'silero_vad.onnx');
      expect(yue.downloads, hasLength(yue.files.length + 1));
    });

    test('未知 id 回落第一个模型（与源 find 同语义）', () {
      expect(RealtimeModelCatalog.find('nope').id, 'zh');
      expect(RealtimeModelCatalog.byId('nope'), isNull);
    });
  });

  group('媒体时钟与代际', () {
    test('暂停时位置冻结，播放时按倍速前进', () {
      var now = DateTime(2026);
      final clock = AudioSessionClock(
        position: const Duration(seconds: 10),
        playing: false,
        now: () => now,
      );
      now = now.add(const Duration(seconds: 5));
      expect(clock.position, const Duration(seconds: 10));

      clock.update(playing: true, rate: 2);
      now = now.add(const Duration(seconds: 3));
      expect(clock.position, const Duration(seconds: 16));
    });

    test('seek 重置位置并使旧代际失效', () {
      final clock = AudioSessionClock(
        sessionId: 7,
        position: const Duration(seconds: 90),
      );
      final stale = (sessionId: clock.sessionId, generation: clock.generation);
      clock.reset(position: const Duration(seconds: 4));
      expect(clock.position, const Duration(seconds: 4));
      expect(clock.sessionId, 8);
      expect(
        clock.isCurrent(
          sessionId: stale.sessionId,
          generation: stale.generation,
        ),
        isFalse,
      );
      expect(
        clock.isCurrent(
          sessionId: clock.sessionId,
          generation: clock.generation,
        ),
        isTrue,
      );
    });

    test('PCM 帧时长按采样率换算', () {
      final frame = PcmFrame(
        samples: Float32List(16000),
        sampleRate: 16000,
        mediaStart: const Duration(seconds: 2),
        sessionId: 1,
        generation: 3,
      );
      expect(frame.duration, const Duration(seconds: 1));
      expect(frame.mediaEnd, const Duration(seconds: 3));
    });
  });

  group('SRT 时轴与 ID 校验', () {
    const sample =
        '1\n'
        '00:00:01,000 --> 00:00:02,500\n'
        'Hello\n\n'
        '2\n'
        '00:00:03,000 --> 00:00:04,000\n'
        'World\n';

    test('解析/渲染保持原序号与时间轴', () {
      final document = SrtDocument.parse(sample);
      expect(document.cues, hasLength(2));
      expect(document.cues.first.startMs, 1000);
      expect(SrtDocument.render(document.cues), sample);

      final translated = document.withTranslations({1: '你好', 2: '世界'});
      expect(
        translated,
        '1\n'
        '00:00:01,000 --> 00:00:02,500\n'
        '你好\n\n'
        '2\n'
        '00:00:03,000 --> 00:00:04,000\n'
        '世界\n',
      );
    });

    test('缺失或空译文回退原文（原文保护）', () {
      final document = SrtDocument.parse(sample);
      final translated = document.withTranslations({1: '  '});
      expect(translated.contains('Hello'), isTrue);
      expect(translated.contains('World'), isTrue);
    });

    test('分块响应必须覆盖全部 ID 且不夹带块外 ID', () {
      expect(parseChunkTranslations('1||你好\n2||世界', expected: [1, 2]), {
        1: '你好',
        2: '世界',
      });
      expect(
        () => parseChunkTranslations('1||你好', expected: [1, 2]),
        throwsA(isA<SrtChunkFormatException>()),
      );
      expect(
        () => parseChunkTranslations('3||多出来的', expected: [1, 2]),
        throwsA(isA<SrtChunkFormatException>()),
      );
      expect(
        () => parseChunkTranslations('1||', expected: [1]),
        throwsA(isA<SrtChunkFormatException>()),
      );
    });

    test('当前字幕按播放位置命中', () {
      final document = SrtDocument.parse(sample);
      expect(document.cueAt(1500)?.text, 'Hello');
      expect(document.cueAt(2600), isNull);
    });
  });

  group('分块计划', () {
    test('并发与块数上限 8 / 32', () {
      expect(clampConcurrency(0), 1);
      expect(clampConcurrency(9), 8);
      expect(clampChunkCount(40), 32);
      expect(clampConcurrency(2), 2);
    });

    test('均分且覆盖全部 cue', () {
      final ranges = planCueRanges(10, 4);
      expect(ranges.map((r) => (r.start, r.end)), [
        (0, 3),
        (3, 6),
        (6, 8),
        (8, 10),
      ]);
      expect(planCueRanges(2, 32).map((r) => (r.start, r.end)), [
        (0, 1),
        (1, 2),
      ]);
      expect(planCueRanges(0, 2), isEmpty);
    });

    test('缩块二分，单 cue 不再缩小', () {
      final half = splitRange(const CueRange(0, 8))!;
      expect((half.start, half.end), (4, 8));
      expect(splitRange(const CueRange(5, 6)), isNull);
    });
  });

  group('歌词分段与评分轨门槛', () {
    test('分段保持歌词时间戳并标记行尾', () {
      final segments = buildKaraokeSegments(const [
        TimedLyricLine(index: 0, startMs: 1000, endMs: 2000, text: '你好'),
        TimedLyricLine(index: 1, startMs: 2000, endMs: 3000, text: '世界'),
        TimedLyricLine(index: 2, startMs: 3000, endMs: 4000, text: '再见'),
      ]);
      expect(segments, hasLength(6));
      expect(segments.first.startMs, 1000);
      expect(segments[1].lineEnd, isTrue);
      expect(segments[1].text, '好');
    });

    test('真实评分不足时生成失败（不伪造轨道）', () {
      final segments = buildKaraokeSegments(const [
        TimedLyricLine(index: 0, startMs: 0, endMs: 400, text: 'ab'),
        TimedLyricLine(index: 1, startMs: 400, endMs: 800, text: 'cd'),
        TimedLyricLine(index: 2, startMs: 800, endMs: 1200, text: 'ef'),
      ]);
      final silent = List.generate(
        segments.length,
        (index) => const PitchCandidate(midi: -1, quality: 0),
      );
      expect(
        () => buildKaraokePitchTrack(
          title: 't',
          artist: 'a',
          segments: segments,
          candidates: silent,
        ),
        throwsA(isA<KaraokePitchException>()),
      );
    });

    test('有真实候选时输出带时间戳的 UltraStar 轨', () {
      final segments = buildKaraokeSegments(const [
        TimedLyricLine(index: 0, startMs: 0, endMs: 600, text: 'ab'),
        TimedLyricLine(index: 1, startMs: 600, endMs: 1200, text: 'cd'),
        TimedLyricLine(index: 2, startMs: 1200, endMs: 1800, text: 'ef'),
      ]);
      final candidates = List.generate(
        segments.length,
        (index) => PitchCandidate(midi: 60 + index, quality: 0.8),
      );
      final track = buildKaraokePitchTrack(
        title: 't',
        artist: 'a',
        segments: segments,
        candidates: candidates,
      );
      expect(
        track.text.startsWith('#TITLE:t\n#ARTIST:a\n#BPM:6000\n#GAP:0\n'),
        isTrue,
      );
      // 显式三行各600ms，BPM6000对应每拍10ms，不能把末行扩到3秒。
      final timing = RegExp(r'^: (\d+) (\d+) \d+ ', multiLine: true)
          .allMatches(track.text)
          .map((match) => (int.parse(match.group(1)!), int.parse(match.group(2)!)))
          .toList();
      expect(timing, [(0, 60), (60, 60), (120, 60)]);
      expect(track.noteCount, 3);
      expect(track.pitched, track.noteCount);
      expect(track.text.endsWith('E\n'), isTrue);
    });
  });
}
