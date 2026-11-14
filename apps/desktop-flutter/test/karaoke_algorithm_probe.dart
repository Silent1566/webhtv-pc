import 'dart:math' as math;
import 'dart:typed_data';
import 'package:webhtv_pc/core/karaoke/karaoke.dart';

void check(bool value, String name) {
  if (!value) throw StateError('FAIL: $name');
  print('PASS: $name');
}

Float32List tone(double hz, [int rate = 44100]) => Float32List.fromList(
  List.generate(2048, (i) => .3 * math.sin(2 * math.pi * hz * i / rate)),
);

void main() {
  final detector = YinPitchDetector(44100);
  final pitch = detector.detect(tone(440), timestampMs: 0);
  check((pitch.frequencyHz - 440).abs() < 2 && pitch.confidence > .98, 'YIN A4 frequency/confidence');
  check((pitch.volume - .212).abs() < .01, 'PCM RMS');
  check(detector.detect(Float32List(2048), timestampMs: 0).frequencyHz == 0, 'silence not pitched');
  final track = UltraStarParser.parse('#TITLE:fixture\n#BPM:60\n#GAP:0\n: 0 10 69 la\n-\n* 10 3 72 next\nE');
  check(track.notes[1].lineIndex == 1 && track.notes[1].type.weight == 2, 'UltraStar timing/golden/line');
  final scorer = KaraokeScorer(track);
  for (var t = 0; t <= 2000; t += 100) { scorer.update(t, 440, .3, 1); }
  check(scorer.snapshot.scorePercent == 100 && scorer.snapshot.grade == 'S+', 'same note score');
  check(scorer.snapshot.totalWeightMs == 900 && scorer.snapshot.currentLineScorePercent == 100, 'warmup and line weight');
  check(scorer.evaluate(2000, 466.1638, .3, 1).hit, 'default semitone tolerated');
  check(scorer.evaluate(2000, 880, .3, 1).perfect, 'octave ignored');
  final strict = KaraokeScorer(track, const KaraokeScoringConfig(toleranceSemitones: .4, ignoreOctave: false));
  check(!strict.evaluate(2000, 466.1638, .3, 1).hit && !strict.evaluate(2000, 880, .3, 1).hit, 'strict semitone/octave miss');
  check(!strict.evaluate(2000, 440, 0, 1).hit, 'silent miss');
  final before = scorer.snapshot.totalWeightMs;
  scorer.update(6000, 440, .3, 1);
  check(scorer.snapshot.totalWeightMs == before && scorer.snapshot.currentComboMs == 0, 'late discontinuity warmup');
  scorer.reset();
  check(scorer.snapshot.totalWeightMs == 0, 'seek reset');
  final delayed = KaraokeScorer(track, const KaraokeScoringConfig(inputLatencyMs: 100));
  check(delayed.evaluate(10100, 440, .3, 1).targetNote?.pitch == 72, 'latency calibrated boundary');
  final free = KaraokeFreeSingScorer();
  const lyrics = [TimedLyricLine(index: 0, startMs: 0, endMs: 8000, text: 'la')];
  for (var t = 0; t <= 4000; t += 100) {
    free.update(t, KaraokePitchSample(timestampMs: t, frequencyHz: 440, volume: .3, confidence: 1), lyrics);
  }
  check(free.snapshot.scorePercent == 91 && free.snapshot.totalWeightMs == 1100, 'free sing seven weighted metrics, not reference ratio');
  final silentFree = KaraokeFreeSingScorer();
  for (var t = 0; t <= 4000; t += 100) { silentFree.update(t, const KaraokePitchSample.empty(), lyrics); }
  check(silentFree.snapshot.scorePercent == 0, 'free silence scores zero');
  final vibrato = KaraokeScorer(track);
  for (var t = 0; t <= 2400; t += 50) {
    final midi = 69 + .4 * math.sin(2 * math.pi * 5 * t / 1000);
    vibrato.update(t, midiToFrequency(midi), .3, 1);
  }
  check(vibrato.snapshot.vibratoWeightMs > 0, 'regular vibrato detected');
}

