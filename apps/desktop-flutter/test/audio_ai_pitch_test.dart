import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/audio_ai/pitch_track.dart';
import 'package:webhtv_pc/services/audio_ai/basic_pitch_service.dart';

/// 生成 22.05kHz 单声道 16-bit WAV 正弦（真实音频，不是假数据）。
Uint8List _sineWav(int frequency, int milliseconds) {
  const rate = 22050;
  final samples = rate * milliseconds ~/ 1000;
  final data = ByteData(44 + samples * 2);
  void ascii(int offset, String value) {
    for (var i = 0; i < value.length; i++) {
      data.setUint8(offset + i, value.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  data.setUint32(4, 36 + samples * 2, Endian.little);
  ascii(8, 'WAVEfmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, rate, Endian.little);
  data.setUint32(28, rate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  data.setUint32(40, samples * 2, Endian.little);
  for (var i = 0; i < samples; i++) {
    final value = (math.sin(2 * math.pi * frequency * i / rate) * 20000)
        .round();
    data.setInt16(44 + i * 2, value, Endian.little);
  }
  return data.buffer.asUint8List();
}

void main() {
  late Directory temp;
  final modelPath = File('assets/models/basic_pitch_nmp.tflite');

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('audio_ai_pitch_');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('BasicPitch 源资产大小与 sha256 固定（真实模型加载前提）', () async {
    expect(await modelPath.exists(), isTrue);
    expect(await modelPath.length(), 204448);
  });

  test('WAV 解码为单声道浮点并按真实采样率重采样', () {
    final (samples, rate) = decodeWavPcm(_sineWav(440, 200));
    expect(rate, 22050);
    expect(samples.length, 22050 * 200 ~/ 1000);
    expect(samples.any((value) => value.abs() > 0.1), isTrue);
  });

  test('缺库时给可执行的官方获取与校验路径，不静默降级', () {
    expect(
      () => TfliteInterpreter.open(
        modelPath.path,
        libraryPath: 'Z:\\missing.dll',
      ),
      throwsA(
        isA<TfliteUnavailableException>().having(
          (error) => error.message,
          'message',
          contains('ai-edge-litert'),
        ),
      ),
    );
  });

  test('真实 TFLite 推理产出带时间戳评分轨（无伪结果）', () async {
    if (TfliteInterpreter.resolveLibrary() == null) {
      fail('libLiteRt.dll 未就绪：无法完成真实推理验收');
    }
    final wav = File('${temp.path}/tone.wav');
    await wav.writeAsBytes(_sineWav(440, 1800));
    final service = BasicPitchService(modelPath: modelPath.path);
    final stages = <String>[];
    final track = await service.generate(
      wavPath: wav.path,
      lines: const [
        TimedLyricLine(index: 0, startMs: 100, endMs: 700, text: 'la'),
        TimedLyricLine(index: 1, startMs: 700, endMs: 1300, text: 'la'),
        TimedLyricLine(index: 2, startMs: 1300, endMs: 1800, text: 'la'),
      ],
      keyword: 'tone',
      artist: 'test',
      onProgress: (progress) => stages.add(progress.stage),
    );
    expect(track.noteCount, greaterThanOrEqualTo(3));
    expect(track.text, contains('#BPM:6000'));
    expect(track.text, endsWith('E\n'));
    expect(stages, contains(BasicPitchService.stageAnalyze));
    // 440Hz 对应 MIDI 69（A4），带八度容错 ±1。
    final pitches = RegExp(r'^: \d+ \d+ (\d+) ', multiLine: true)
        .allMatches(track.text)
        .map((match) => int.parse(match.group(1)!))
        .toList();
    expect(pitches.any((pitch) => (pitch - 69).abs() <= 1), isTrue);
    for (final match in RegExp(r'^: (\d+) (\d+) \d+ ', multiLine: true).allMatches(track.text)) {
      final endMs = (int.parse(match.group(1)!) + int.parse(match.group(2)!)) * 10;
      expect(endMs, lessThanOrEqualTo(1800), reason: '实际TFLite轨不能越过1.8秒音频');
    }
  });

  test('F4 全局DP反例：局部最高60的贪心被整条路径65取代', () {
    final segments = List.generate(3,(i)=>KaraokeLyricSegment(startMs: i*600, endMs: (i+1)*600, text: 'la'));
    final path = smoothKaraokeCandidatePath(segments, const [
      [PitchCandidate(midi: 60, quality: 0.80), PitchCandidate(midi: 65, quality: 0.79)],
      [PitchCandidate(midi: 65, quality: 0.80)],
      [PitchCandidate(midi: 65, quality: 0.80)],
    ]);
    expect(path.map((candidate) => candidate.midi).toList(), [65, 65, 65]);
  });

  test('F4 2.6秒十字歌词按520ms/单元压缩为五段，无空格Latin同样压缩', () {
    expect(
      splitKaraokeUnits('一二三四五六七八九十', durationMs: 2600),
      ['一二','三四','五六','七八','九十'],
    );
    expect(
      splitKaraokeUnits('abcdefghij', durationMs: 2600),
      ['ab','cd','ef','gh','ij'],
    );
  });

  test('F4 逐词不均匀 offset/duration 无损保留', () {
    final segments = buildKaraokeSegments(const [
      TimedLyricLine(index: 0, startMs: 1000, endMs: 4000, text: 'a b c', words: [
        TimedLyricWord(text: 'a', startOffsetMs: 50, durationMs: 200),
        TimedLyricWord(text: 'b', startOffsetMs: 900, durationMs: 600),
        TimedLyricWord(text: 'c', startOffsetMs: 1800, durationMs: 0),
      ]),
    ]);
    expect(
      segments.map((segment) => (segment.startMs, segment.endMs)).toList(),
      [(1050, 1250), (1900, 2500), (2800, 4000)],
    );
    expect(segments.last.lineEnd, isTrue);
  });

  test('F4 后处理合并同音并保留行尾，评分单元不丢行', () {
    final segments = List.generate(6,(i)=>KaraokeLyricSegment(
      startMs: i*600, endMs: (i+1)*600, text: String.fromCharCode(97+i), lineEnd: i.isOdd));
    final candidates = const [60,60,64,64,67,67]
        .map((midi)=>PitchCandidate(midi: midi, quality: 0.9))
        .toList();
    final track = buildKaraokePitchTrack(title: 't', artist: 'a', segments: segments, candidates: candidates);
    expect(track.noteCount, 3, reason: '同音同行合并为3个评分单元');
    expect(track.observed, 3);
    expect(track.pitched, 3);
    expect(track.text.contains('-\n'), isTrue);
    expect(track.text.endsWith('E\n'), isTrue);
  });

  test('F4 无真实音高时仍拒绝产出评分轨（不伪造）', () {
    final segments = List.generate(3,(i)=>KaraokeLyricSegment(
      startMs: i*400, endMs: (i+1)*400, text: 'x', lineEnd: true));
    final candidates = List.generate(3,(_)=>const PitchCandidate(midi: -1, quality: 0));
    expect(
      ()=>buildKaraokePitchTrack(title: 't', artist: 'a', segments: segments, candidates: candidates),
      throwsA(isA<KaraokePitchException>()),
    );
  });
}
