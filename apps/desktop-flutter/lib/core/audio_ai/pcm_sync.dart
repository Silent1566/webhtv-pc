/// PCM 帧、播放媒体时钟与会话代际。
///
/// 合同：`mediaStart` 必须由播放器真实媒体时钟提供，不能由累计采样数反推——
/// 暂停时不应前进、倍速时按倍数前进、seek/换集后代际改变使旧帧失效。
library;

import 'dart:typed_data';
import 'dart:async';

/// 一帧单声道浮点 PCM，携带它在媒体时间轴上的起点。
class PcmFrame {
  const PcmFrame({
    required this.samples,
    required this.sampleRate,
    required this.mediaStart,
    required this.sessionId,
    required this.generation,
    this.mediaRate = 1,
  });

  final Float32List samples;
  final int sampleRate;

  /// 该帧第一个采样点对应的媒体时间位置。
  final Duration mediaStart;
  final int sessionId;
  final int generation;
  final double mediaRate;

  Duration get duration => Duration(
    microseconds: samples.isEmpty
        ? 0
        : (samples.length * Duration.microsecondsPerSecond / sampleRate)
              .round(),
  );

  Duration get mediaEnd =>
      mediaStart +
      Duration(microseconds: (duration.inMicroseconds * mediaRate).round());
}

/// 播放媒体时钟：`position` 只在播放时按 `rate` 前进，暂停即冻结。
///
/// `reset` 递增 [generation]；控制器据此丢弃旧会话/旧位置的帧，避免 seek 后
/// 过期文本继续上屏。
class AudioSessionClock {
  AudioSessionClock({
    int sessionId = 0,
    Duration position = Duration.zero,
    bool playing = false,
    double rate = 1.0,
    DateTime Function()? now,
  }) : _sessionId = sessionId,
       _generation = 0,
       _anchorPosition = position,
       _playing = playing,
       _rate = rate <= 0 ? 1.0 : rate,
       _now = now ?? DateTime.now,
       _anchorAt = (now ?? DateTime.now)();

  final DateTime Function() _now;
  final _changes = StreamController<int>.broadcast();
  Stream<int> get changes => _changes.stream;
  Future<void> dispose() => _changes.close();

  int _sessionId;
  int _generation;
  Duration _anchorPosition;
  DateTime _anchorAt;
  bool _playing;
  double _rate;

  int get sessionId => _sessionId;
  int get generation => _generation;
  bool get playing => _playing;
  double get rate => _rate;

  Duration get position {
    if (!_playing) return _anchorPosition;
    final elapsed = _now().difference(_anchorAt);
    final scaled = (elapsed.inMicroseconds * _rate).round();
    return _anchorPosition + Duration(microseconds: scaled);
  }

  /// 播放器上报新位置/状态：吸收到锚点，之后按 playing/rate 外推。
  void update({Duration? position, bool? playing, double? rate}) {
    final current = this.position;
    _anchorPosition = position ?? current;
    _anchorAt = _now();
    if (!_changes.isClosed) _changes.add(_generation);
    if (playing != null) _playing = playing;
    if (rate != null) _rate = rate <= 0 ? 1.0 : rate;
  }

  /// seek / 换集：位置重设且代际 +1，旧代际的帧与识别结果一律失效。
  void reset({Duration position = Duration.zero, int? sessionId}) {
    _sessionId = sessionId ?? _sessionId + 1;
    _generation++;
    _anchorPosition = position;
    _anchorAt = _now();
    if (!_changes.isClosed) _changes.add(_generation);
  }

  bool isCurrent({required int sessionId, required int generation}) =>
      sessionId == _sessionId && generation == _generation;
}
