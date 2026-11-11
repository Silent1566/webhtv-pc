import 'dart:math' as math;

import 'models.dart';

class KaraokeScorer {
  KaraokeScorer(this.track, [this.config = const KaraokeScoringConfig()])
    : _lineTotal = List.filled(math.max(1, track.lineCount), 0),
      _lineHit = List.filled(math.max(1, track.lineCount), 0);
  final KaraokeTrack track;
  final KaraokeScoringConfig config;
  final List<double> _lineTotal, _lineHit;
  final List<(int, double)> _history = [];
  int _last = -1, _warmup = 1200, _noteStart = -1;
  double _total = 0,
      _hit = 0,
      _voiced = 0,
      _perfect = 0,
      _vibrato = 0,
      _combo = 0,
      _best = 0;
  KaraokeScoreSnapshot snapshot = const KaraokeScoreSnapshot();

  KaraokeScoreSnapshot update(
    int positionMs,
    double hz,
    double volume,
    double confidence,
  ) => _evaluate(positionMs, hz, volume, confidence, true);
  KaraokeScoreSnapshot evaluate(
    int positionMs,
    double hz,
    double volume,
    double confidence,
  ) => _evaluate(positionMs, hz, volume, confidence, false);
  KaraokeScoreSnapshot _evaluate(
    int positionMs,
    double hz,
    double volume,
    double confidence,
    bool accumulate,
  ) {
    final position = math.max(0, positionMs - config.inputLatencyMs);
    final note = track.findScoredNote(position);
    final voiced = config.voiced(hz, volume, confidence);
    final midi = voiced ? frequencyToMidi(hz) : double.nan;
    final distance = note != null && voiced
        ? semitoneDistance(midi, note.pitch.toDouble(), config.ignoreOctave)
        : double.nan;
    final hit =
        note != null &&
        voiced &&
        (!note.type.pitchRequired ||
            distance.abs() <= math.max(0, config.toleranceSemitones));
    final perfect = hit && note.type.pitchRequired && distance.abs() <= .38;
    final vibrato =
        hit &&
        note.type.pitchRequired &&
        accumulate &&
        _recordVibrato(position, note, midi);
    if (accumulate) {
      var slice = 0;
      if (_last < 0) {
        _warmup = position + 1200;
      } else {
        final delta = position - _last;
        if (delta < -1000 || delta > 2000) {
          _warmup = position + 1200;
          _combo = 0;
          _history.clear();
          _noteStart = -1;
        } else if (delta <= 0) {
          _combo = 0;
        } else {
          slice = math.min(delta, math.max(20, config.maxSliceMs));
        }
      }
      if (slice > 0 && position >= _warmup && note != null) {
        final weight = slice * note.type.weight;
        _total += weight;
        if (voiced) _voiced += weight;
        if (hit) _hit += weight;
        if (perfect) _perfect += weight;
        if (vibrato) _vibrato += weight;
        _lineTotal[note.lineIndex] += weight;
        if (hit) _lineHit[note.lineIndex] += weight;
        _combo = hit ? _combo + slice : 0;
        _best = math.max(_best, _combo);
      }
      _last = position;
    }
    final scores = [
      for (var i = 0; i < _lineTotal.length; i++)
        if (_lineTotal[i] > 0) scorePercent(_lineHit[i], _lineTotal[i]),
    ];
    final result = KaraokeScoreSnapshot(
      positionMs: position,
      totalWeightMs: _total,
      hitWeightMs: _hit,
      voicedWeightMs: _voiced,
      perfectWeightMs: _perfect,
      vibratoWeightMs: _vibrato,
      currentComboMs: _combo,
      bestComboMs: _best,
      targetNote: note,
      sungMidi: midi,
      distanceSemitones: distance,
      voiced: voiced,
      hit: hit,
      perfect: perfect,
      vibrato: vibrato,
      lineIndex: note?.lineIndex ?? -1,
      lineCount: _lineTotal.length,
      scoredLineCount: scores.length,
      currentLineScorePercent: note == null
          ? 0
          : scorePercent(_lineHit[note.lineIndex], _lineTotal[note.lineIndex]),
      bestLineScorePercent: scores.isEmpty ? 0 : scores.reduce(math.max),
      averageLineScorePercent: scores.isEmpty
          ? 0
          : (scores.reduce((a, b) => a + b) / scores.length).round(),
    );
    if (accumulate) snapshot = result;
    return result;
  }

  bool _recordVibrato(int position, KaraokeNote note, double midi) {
    if (_noteStart != note.startMs ||
        (_history.isNotEmpty && position - _history.last.$1 > 260)) {
      _history.clear();
      _noteStart = note.startMs;
    }
    _history.add((position, midi));
    if (_history.length > 24) _history.removeAt(0);
    final points = _history.where((p) => p.$1 >= position - 1300).toList();
    if (points.length < 7) return false;
    var low = double.infinity, high = -double.infinity;
    var changes = 0, lastDirection = 0, lastChange = 0;
    final intervals = <int>[];
    for (var i = 0; i < points.length; i++) {
      low = math.min(low, points[i].$2);
      high = math.max(high, points[i].$2);
      if (i == 0) continue;
      final delta = points[i].$2 - points[i - 1].$2;
      if (delta.abs() < .08) continue;
      final direction = delta > 0 ? 1 : -1;
      if (lastDirection != 0 && direction != lastDirection) {
        changes++;
        if (lastChange > 0) intervals.add(points[i].$1 - lastChange);
        lastChange = points[i].$1;
      } else if (lastDirection == 0) {
        lastChange = points[i].$1;
      }
      lastDirection = direction;
    }
    if (changes < 4 ||
        high - low < .35 ||
        high - low > 2.4 ||
        intervals.length < 2)
      return false;
    final avg = intervals.reduce((a, b) => a + b) / intervals.length;
    return intervals.reduce(math.max) < avg * 1.9 &&
        intervals.reduce(math.min) > avg / 1.9;
  }

  /// 评分恢复只换时间锚，不补算暂停区间、不清除已得分。
  void reanchor(int positionMs) {
    final position = math.max(0, positionMs - config.inputLatencyMs);
    if (_last < 0) _warmup = position + 1200;
    _last = position;
    _history.clear();
    _noteStart = -1;
  }

  void reset() {
    _last = -1;
    _warmup = 1200;
    _total = _hit = _voiced = _perfect = _vibrato = _combo = _best = 0;
    _history.clear();
    _noteStart = -1;
    _lineTotal.fillRange(0, _lineTotal.length, 0);
    _lineHit.fillRange(0, _lineHit.length, 0);
    snapshot = const KaraokeScoreSnapshot();
  }
}
