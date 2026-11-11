import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import '../../core/karaoke/karaoke.dart';
import 'mic_source.dart';

/// 固定人声分析率，设备分包连续重采样后才形成完整分析窗。
class KaraokeMicAnalysis {
  KaraokeMicAnalysis(this.sampleRate, this.frameSize)
    : analysisRate = math.min(44100, sampleRate),
      _window = Float32List(frameSize) {
    _signal = KaraokeMicSignal(sampleRate: analysisRate);
    _detector = YinPitchDetector(analysisRate, sampleSize: frameSize);
  }
  final int sampleRate, frameSize, analysisRate;
  final Float32List _window;
  late final KaraokeMicSignal _signal;
  late final YinPitchDetector _detector;
  int _inputIndex = 0, _filled = 0;
  double _nextAt = 0;
  double? _previous;
  List<KaraokePitchSample> accept(Float32List pcm, int timestampMs) {
    final result = <KaraokePitchSample>[];
    for (var i = 0; i < pcm.length; i++) {
      final current = pcm[i];
      while (_nextAt <= _inputIndex) {
        final value = _previous == null
            ? current
            : _previous! +
                  (current - _previous!) * (_nextAt - (_inputIndex - 1));
        _window[_filled++] = value;
        _nextAt += sampleRate / analysisRate;
        if (_filled == frameSize) {
          final frame = Float32List.fromList(_window);
          final raw = KaraokeMicSignal.rms(frame);
          final filtered = _signal.process(frame);
          final end =
              timestampMs - ((pcm.length - i - 1) * 1000 / sampleRate).round();
          final pitch = _detector.detect(frame, timestampMs: end);
          result.add(_signal.apply(pitch, raw, filtered));
          _filled = 0;
        }
      }
      _previous = current;
      _inputIndex++;
    }
    return result;
  }
}

void karaokeMicAnalysisWorker(List<Object> input) {
  final output = input[0] as SendPort;
  final analysis = KaraokeMicAnalysis(input[1] as int, input[2] as int);
  final commands = ReceivePort();
  output.send(commands.sendPort);
  commands.listen((dynamic message) {
    try {
      final samples = analysis.accept(
        message[0] as Float32List,
        message[1] as int,
      );
      output.send([
        for (final s in samples)
          [s.timestampMs, s.frequencyHz, s.volume, s.confidence],
      ]);
    } catch (error) {
      output.send(error.toString());
    }
  });
}
