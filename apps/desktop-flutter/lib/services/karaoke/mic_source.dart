import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import '../../core/karaoke/karaoke.dart';

/// 采集信号前处理：人声带通 + 自适应门限（源 `KaraokeMicRecorder` 的
/// `VoiceBandpassFilter` / `AdaptiveVoiceGate`），纯 Dart 便于合成 PCM 验证。
class KaraokeMicSignal {
  KaraokeMicSignal({required this.sampleRate}) {
    _high = _Biquad.highPass(200, sampleRate.toDouble());
    _low = _Biquad.lowPass(3500, sampleRate.toDouble());
  }
  static const int warmupFrames = 24;
  final int sampleRate;
  late final _Biquad _high, _low;
  double _filteredFloor = 0, _rawFloor = 0;
  int _frames = 0;

  /// 原地带通后返回滤波后音量；输入是 [-1,1] 的单声道 PCM。
  double process(Float32List pcm) {
    var power = 0.0;
    for (var i = 0; i < pcm.length; i++) {
      var value = _low.process(_high.process(pcm[i]));
      if (!value.isFinite) value = 0;
      pcm[i] = value.clamp(-1.0, 1.0);
      power += pcm[i] * pcm[i];
    }
    return pcm.isEmpty ? 0 : math.sqrt(power / pcm.length).clamp(0.0, 1.0);
  }

  static double rms(Float32List pcm) {
    var power = 0.0;
    for (final value in pcm) {
      power += value * value;
    }
    return pcm.isEmpty ? 0 : math.sqrt(power / pcm.length).clamp(0.0, 1.0);
  }

  /// 门限回调：安静或弱置信度帧清空频率，避免静音被当成发声。
  KaraokePitchSample apply(
    KaraokePitchSample sample,
    double rawVolume,
    double filteredVolume,
  ) {
    _frames++;
    _filteredFloor = _nextFloor(
      _filteredFloor,
      filteredVolume,
      sample.confidence,
    );
    _rawFloor = _nextFloor(_rawFloor, rawVolume, sample.confidence);
    final warmup = _frames < warmupFrames;
    final filteredGate = math.max(
      0.006,
      _filteredFloor * (warmup ? 1.08 : 1.32),
    );
    final rawGate = math.max(0.012, _rawFloor * (warmup ? 1.05 : 1.18));
    final quiet = filteredVolume < filteredGate && rawVolume < rawGate;
    final weak =
        sample.confidence < 0.12 && filteredVolume < filteredGate * 1.15;
    if (quiet || weak) {
      return KaraokePitchSample(
        timestampMs: sample.timestampMs,
        frequencyHz: 0,
        volume: rawVolume,
        confidence: 0,
      );
    }
    return KaraokePitchSample(
      timestampMs: sample.timestampMs,
      frequencyHz: sample.frequencyHz,
      volume: rawVolume,
      confidence: sample.confidence,
    );
  }

  static double _nextFloor(double floor, double value, double confidence) {
    if (value <= 0) return floor;
    if (floor <= 0) return value;
    final alpha = value < floor ? 0.18 : (confidence < 0.2 ? 0.035 : 0.006);
    return floor + (value - floor) * alpha;
  }
}

class _Biquad {
  _Biquad(this.b0, this.b1, this.b2, this.a1, this.a2);
  final double b0, b1, b2, a1, a2;
  double _x1 = 0, _x2 = 0, _y1 = 0, _y2 = 0;
  static _Biquad highPass(double cutoff, double sampleRate) {
    final w0 = 2 * math.pi * cutoff / sampleRate;
    final cos = math.cos(w0);
    final alpha = math.sin(w0) / (2 * 0.707);
    final a0 = 1 + alpha;
    return _Biquad(
      (1 + cos) / 2 / a0,
      -(1 + cos) / a0,
      (1 + cos) / 2 / a0,
      -2 * cos / a0,
      (1 - alpha) / a0,
    );
  }

  static _Biquad lowPass(double cutoff, double sampleRate) {
    final w0 = 2 * math.pi * cutoff / sampleRate;
    final cos = math.cos(w0);
    final alpha = math.sin(w0) / (2 * 0.707);
    final a0 = 1 + alpha;
    return _Biquad(
      (1 - cos) / 2 / a0,
      (1 - cos) / a0,
      (1 - cos) / 2 / a0,
      -2 * cos / a0,
      (1 - alpha) / a0,
    );
  }

  double process(double x) {
    final y = b0 * x + b1 * _x1 + b2 * _x2 - a1 * _y1 - a2 * _y2;
    _x2 = _x1;
    _x1 = x;
    _y2 = _y1;
    _y1 = y;
    return y;
  }
}

/// 麦克风生产适配接口：默认不启用，只有 控制器的 start 才打开设备。
abstract class KaraokeMicSource {
  bool get isAvailable;
  String get unavailableReason;
  Stream<KaraokePitchSample> get samples;
  Future<bool> start();
  Future<void> stop();
}

/// 注入式假麦（测试/无设备平台）：不触碰任何真实设备。
class SilentKaraokeMic implements KaraokeMicSource {
  @override
  bool get isAvailable => false;
  @override
  String get unavailableReason => 'no microphone source configured';
  @override
  Stream<KaraokePitchSample> get samples => const Stream.empty();
  @override
  Future<bool> start() async => false;
  @override
  Future<void> stop() async {}
}
