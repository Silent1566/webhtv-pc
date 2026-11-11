import 'dart:math' as math;

import '../audio_ai/pitch_track.dart';
import 'models.dart';

class KaraokeFreeSingScorer {
  KaraokeFreeSingScorer([this.config = const KaraokeScoringConfig()]);
  final KaraokeScoringConfig config;
  int _last = -1, _warmup = 3000, _line = -1;
  double _total = 0,
      _hit = 0,
      _voiced = 0,
      _combo = 0,
      _best = 0,
      _lineActive = 0,
      _lineVoiced = 0,
      _lineTotal = 0,
      _lineHit = 0;
  int _completed = 0, _completedSum = 0, _bestLine = 0;
  double _lastMidi = double.nan;
  final List<double> _recent = [];
  KaraokeScoreSnapshot snapshot = const KaraokeScoreSnapshot();

  KaraokeScoreSnapshot update(
    int positionMs,
    KaraokePitchSample sample,
    List<TimedLyricLine> lyrics,
  ) {
    final position = math.max(0, positionMs - config.inputLatencyMs);
    final window = _findWindow(lyrics, position);
    final voiced = config.voiced(
      sample.frequencyHz,
      sample.volume,
      sample.confidence,
    );
    final midi = voiced ? frequencyToMidi(sample.frequencyHz) : double.nan;
    var slice = 0;
    if (_last < 0)
      _warmup = position + 3000;
    else {
      final delta = position - _last;
      if (delta < -1000 || delta > 2000) {
        _warmup = position + 3000;
        _line = -1;
        _lineActive = _lineVoiced = _lineTotal = _lineHit = 0;
        _lastMidi = double.nan;
        _recent.clear();
        _combo = 0;
      } else if (delta > 0)
        slice = math.min(delta, math.max(20, config.maxSliceMs));
    }
    if (slice > 0 && position >= _warmup && window >= 0) {
      if (_line != window) {
        if (_lineTotal > 0) {
          final s = scorePercent(_lineHit, _lineTotal);
          _completed++;
          _completedSum += s;
          _bestLine = math.max(_bestLine, s);
        }
        _line = window;
        _lineActive = _lineVoiced = _lineTotal = _lineHit = 0;
        _lastMidi = double.nan;
        _recent.clear();
      }
      _lineActive += slice;
      if (voiced) {
        _lineVoiced += slice;
        _recent.add(midi);
        if (_recent.length > 18) _recent.removeAt(0);
      }
      final score = _freeScore(voiced, midi, sample.volume, sample.confidence);
      _total += slice;
      _hit += slice * score;
      _lineTotal += slice;
      _lineHit += slice * score;
      if (voiced) {
        _voiced += slice;
        _combo += slice;
        _best = math.max(_best, _combo);
        _lastMidi = midi;
      } else
        _combo = 0;
    }
    _last = position;
    final count = _completed + (_lineTotal > 0 ? 1 : 0);
    return snapshot = KaraokeScoreSnapshot(
      positionMs: position,
      totalWeightMs: _total,
      hitWeightMs: _hit,
      voicedWeightMs: _voiced,
      currentComboMs: _combo,
      bestComboMs: _best,
      sungMidi: midi,
      voiced: voiced,
      hit: voiced,
      lineIndex: _line,
      lineCount: count,
      scoredLineCount: count,
      currentLineScorePercent: scorePercent(_lineHit, _lineTotal),
      bestLineScorePercent: math.max(
        _bestLine,
        scorePercent(_lineHit, _lineTotal),
      ),
      averageLineScorePercent: count <= 0
          ? 0
          : ((_completedSum +
                        (_lineTotal > 0
                            ? scorePercent(_lineHit, _lineTotal)
                            : 0)) /
                    count)
                .round(),
    );
  }

  double _freeScore(
    bool voiced,
    double midi,
    double volume,
    double confidence,
  ) {
    if (!voiced) return 0;
    final cConfidence =
        ((confidence - config.minConfidence.clamp(0, 1)) /
                math.max(.1, 1 - config.minConfidence.clamp(0, 1)))
            .clamp(0.0, 1.0);
    var v = volume <= config.minVolume ? 0.0 : volume / .16;
    if (volume > .86) v -= (volume - .86) * 1.5;
    final vScore = v.clamp(0.0, 1.0);
    final diff = _lastMidi.isNaN ? double.nan : (midi - _lastMidi).abs();
    final stability = diff.isNaN
        ? 0.72
        : diff <= .75
        ? 1.0
        : diff <= 2.5
        ? 0.82
        : diff <= 5
        ? 0.55
        : 0.28;
    final tolerance = math.max(.35, config.toleranceSemitones / 3);
    final snap =
        (1 - (midi - midi.round()).abs() / tolerance).clamp(0.0, 1.0) *
        cConfidence;
    double musicality;
    if (_recent.length < 5)
      musicality = .42;
    else {
      final range = _recent.reduce(math.max) - _recent.reduce(math.min);
      final rangeScore = range < 0.5
          ? 0.18
          : range <= 6
          ? (range / 6).clamp(0.0, 1.0)
          : math.max(0.28, 1 - (range - 6) / 10);
      final interval = diff;
      final intervalScore = interval.isNaN
          ? 0.55
          : interval < 0.3
          ? 0.62
          : interval <= 5
          ? 1.0
          : interval <= 8
          ? 0.42
          : 0.12;
      musicality = rangeScore * .5 + intervalScore * .5;
    }
    final phrase = _lineActive <= 0
        ? 0.5
        : (_lineVoiced / _lineActive).clamp(0.0, 1.0);
    return .18 +
        cConfidence * .20 +
        vScore * .13 +
        stability * .16 +
        snap * .13 +
        musicality * .15 +
        phrase * .05;
  }

  int _findWindow(List<TimedLyricLine> lines, int position) {
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final nextStart = i + 1 < lines.length
          ? lines[i + 1].startMs
          : line.startMs + 8000;
      var start = line.startMs, end = nextStart;
      if (line.words.isNotEmpty) {
        var wordEnd = 0;
        for (final w in line.words)
          wordEnd = math.max(wordEnd, w.startOffsetMs + w.durationMs);
        start += math.max(0, line.words.first.startOffsetMs - 250);
        end = line.startMs + wordEnd + 250;
        if (nextStart > line.startMs) end = math.min(end, nextStart);
      } else
        end = math.min(end, line.startMs + 8000);
      if (position >= start && position < end && end > start + 300)
        return line.index;
    }
    return -1;
  }

  /// 恢复评分的媒体时间锚；累计分数、行统计与 combo 均保留。
  void reanchor(int positionMs) {
    final position = math.max(0, positionMs - config.inputLatencyMs);
    if (_last < 0) _warmup = position + 3000;
    _last = position;
  }

  void reset() {
    _last = -1;
    _warmup = 3000;
    _line = -1;
    _total = _hit = _voiced = _combo = _best = _lineActive = _lineVoiced =
        _lineTotal = _lineHit = 0;
    _completed = 0;
    _completedSum = 0;
    _bestLine = 0;
    _lastMidi = double.nan;
    _recent.clear();
    snapshot = const KaraokeScoreSnapshot();
  }
}
