import 'dart:math' as math;
import 'dart:ui' show FrameTiming;

import 'log_service.dart';

/// Request-relative timings and app frame samples during detail loading.
class DetailLoadTrace {
  DetailLoadTrace({
    required this.log,
    required this.runId,
    Duration Function()? elapsed,
    String context = '',
  }) {
    final clock = Stopwatch()..start();
    _elapsed = elapsed ?? (() => clock.elapsed);
    mark('start', fields: context);
  }

  final LogService log;
  final int runId;
  late final Duration Function() _elapsed;
  final Set<String> _stages = {};
  int _lastStageMs = 0;
  int? _frameStart;
  int? _frameEnd;
  int _observedThrough = -1;
  int? _lastSampleFrame;
  int _samples = 0;
  int _slowFrames = 0;
  int _longFrames = 0;
  int _maxBuildUs = 0;
  int _maxRasterUs = 0;
  int _maxTotalUs = 0;
  String? _frameEndStage;
  bool _framesFinished = false;

  bool get framesFinished => _framesFinished;

  bool hasStage(String stage) => _stages.contains(stage);

  void mark(String stage, {String fields = ''}) {
    if (!_stages.add(stage)) return;
    final elapsedMs = _elapsed().inMilliseconds;
    final deltaMs = elapsedMs - _lastStageMs;
    _lastStageMs = elapsedMs;
    log.info(
      'run=$runId stage=$stage elapsedMs=$elapsedMs deltaMs=$deltaMs'
      '${fields.isEmpty ? '' : ' $fields'}',
      scope: 'detail-perf',
    );
  }

  void beginFrames(int frameNumber) {
    _frameStart ??= frameNumber;
  }

  void endFrames(int frameNumber, String stage) {
    _frameEnd ??= frameNumber;
    _frameEndStage ??= stage;
    if (_observedThrough >= _frameEnd!) finishFrames(_frameEndStage!);
  }

  void recordFrames(List<FrameTiming> timings) {
    final start = _frameStart;
    if (framesFinished || start == null) return;
    for (final frame in timings) {
      final number = frame.frameNumber;
      if (number <= _observedThrough) continue;
      _observedThrough = number;
      if (number < start || (_frameEnd != null && number > _frameEnd!)) {
        continue;
      }
      _lastSampleFrame = number;
      _samples++;
      final total = frame.totalSpan.inMicroseconds;
      if (total > 16667) _slowFrames++;
      if (total >= 50000) _longFrames++;
      _maxBuildUs = math.max(_maxBuildUs, frame.buildDuration.inMicroseconds);
      _maxRasterUs = math.max(
        _maxRasterUs,
        frame.rasterDuration.inMicroseconds,
      );
      _maxTotalUs = math.max(_maxTotalUs, total);
    }
    if (_frameEnd != null && _observedThrough >= _frameEnd!) {
      finishFrames(_frameEndStage!);
    }
  }

  void finishFrames(String reason) {
    if (framesFinished) return;
    _framesFinished = true;
    final status = _samples == 0
        ? 'unavailable'
        : _frameEnd != null && _lastSampleFrame == _frameEnd
        ? 'complete'
        : 'partial';
    mark(
      'frames',
      fields:
          'samples=$_samples slowFrames=$_slowFrames longFrames=$_longFrames '
          'budgetMs=16.667 longThresholdMs=50 '
          'maxBuildMs=${(_maxBuildUs / 1000).toStringAsFixed(1)} '
          'maxRasterMs=${(_maxRasterUs / 1000).toStringAsFixed(1)} '
          'maxTotalMs=${(_maxTotalUs / 1000).toStringAsFixed(1)} '
          'timingStatus=$status reason=$reason',
    );
  }
}
