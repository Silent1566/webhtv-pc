import 'dart:math' as math;

int scorePercent(num hit, num total) => total <= 0 ? 0 : (hit * 100 / total).clamp(0, 100).round();
double frequencyToMidi(double hz) => hz > 0 && hz.isFinite ? 69 + 12 * math.log(hz / 440) / math.ln2 : double.nan;
double midiToFrequency(double midi) => 440 * math.pow(2, (midi - 69) / 12).toDouble();
double semitoneDistance(double sung, double target, bool ignoreOctave) {
  final delta = sung - target;
  return ignoreOctave ? (delta + 6) % 12 - 6 : delta;
}
String gradeFromScore(int score) => score >= 95 ? 'S+' : score >= 90 ? 'S' : score >= 80 ? 'A' : score >= 70 ? 'B' : score >= 60 ? 'C' : score >= 40 ? 'D' : 'E';

enum KaraokeNoteType {
  normal(':', true, true, 1), golden('*', true, true, 2), freestyle('F', false, false, 0), rap('R', true, false, 1), rapGolden('G', true, false, 2);
  const KaraokeNoteType(this.prefix, this.scored, this.pitchRequired, this.weight);
  final String prefix;
  final bool scored, pitchRequired;
  final double weight;
}

class KaraokeNote {
  const KaraokeNote({required this.startMs, required this.endMs, required this.pitch, this.startBeat = 0, this.lengthBeat = 0, this.text = '', this.type = KaraokeNoteType.normal, this.lineIndex = 0});
  final int startMs, endMs, pitch, startBeat, lengthBeat, lineIndex;
  final String text;
  final KaraokeNoteType type;
  bool get scored => type.scored && endMs > startMs;
  bool contains(int position) => position >= startMs && position < endMs;
}

class KaraokeTrack {
  KaraokeTrack({this.title = '', this.artist = '', this.bpm = 0, this.gapMs = 0, required List<KaraokeNote> notes}) : notes = List.unmodifiable(List<KaraokeNote>.of(notes)..sort((a,b) => a.startMs != b.startMs ? a.startMs.compareTo(b.startMs) : a.endMs.compareTo(b.endMs)));
  final String title, artist;
  final double bpm;
  final int gapMs;
  final List<KaraokeNote> notes;
  bool get hasScoredNotes => notes.any((n) => n.scored);
  bool get hasPitchRequiredNotes => notes.any((n) => n.scored && n.type.pitchRequired);
  int get durationMs => notes.fold(0, (v,n) => math.max(v,n.endMs));
  int get lineCount => notes.where((n) => n.scored).fold(-1, (v,n) => math.max(v,n.lineIndex)) + 1;
  double get weightedDurationMs => notes.where((n) => n.scored).fold(0, (v,n) => v + (n.endMs - n.startMs) * n.type.weight);
  KaraokeNote? findScoredNote(int position) {
    for (final n in notes) { if (n.startMs > position) break; if (n.scored && n.contains(position)) return n; }
    return null;
  }
}

class KaraokePitchSample {
  const KaraokePitchSample({required this.timestampMs, required this.frequencyHz, required this.volume, required this.confidence});
  const KaraokePitchSample.empty() : timestampMs = 0, frequencyHz = 0, volume = 0, confidence = 0;
  final int timestampMs;
  final double frequencyHz, volume, confidence;
}

class KaraokeScoringConfig {
  const KaraokeScoringConfig({this.toleranceSemitones = 2, this.ignoreOctave = true, this.minVolume = .05, this.minConfidence = .1, this.inputLatencyMs = 0, this.maxSliceMs = 250});
  final double toleranceSemitones, minVolume, minConfidence;
  final bool ignoreOctave;
  final int inputLatencyMs, maxSliceMs;
  KaraokeScoringConfig copyWith({double? toleranceSemitones, bool? ignoreOctave, int? inputLatencyMs}) => KaraokeScoringConfig(toleranceSemitones: toleranceSemitones ?? this.toleranceSemitones, ignoreOctave: ignoreOctave ?? this.ignoreOctave, minVolume: minVolume, minConfidence: minConfidence, inputLatencyMs: inputLatencyMs ?? this.inputLatencyMs, maxSliceMs: maxSliceMs);
  bool voiced(double hz, double volume, double confidence) => hz.isFinite && hz > 0 && volume.isFinite && volume >= minVolume.clamp(0,1) && confidence.isFinite && confidence >= minConfidence.clamp(0,1);
}

class KaraokeScoreSnapshot {
  const KaraokeScoreSnapshot({this.positionMs = 0, this.totalWeightMs = 0, this.hitWeightMs = 0, this.voicedWeightMs = 0, this.perfectWeightMs = 0, this.vibratoWeightMs = 0, this.currentComboMs = 0, this.bestComboMs = 0, this.targetNote, this.sungMidi = double.nan, this.distanceSemitones = double.nan, this.voiced = false, this.hit = false, this.perfect = false, this.vibrato = false, this.lineIndex = -1, this.lineCount = 0, this.scoredLineCount = 0, this.currentLineScorePercent = 0, this.bestLineScorePercent = 0, this.averageLineScorePercent = 0});
  final int positionMs, lineIndex, lineCount, scoredLineCount, currentLineScorePercent, bestLineScorePercent, averageLineScorePercent;
  final double totalWeightMs, hitWeightMs, voicedWeightMs, perfectWeightMs, vibratoWeightMs, currentComboMs, bestComboMs, sungMidi, distanceSemitones;
  final KaraokeNote? targetNote;
  final bool voiced, hit, perfect, vibrato;
  int get scorePercent => corePercent(hitWeightMs);
  int get voicedPercent => corePercent(voicedWeightMs);
  int get perfectPercent => corePercent(perfectWeightMs);
  int get vibratoPercent => corePercent(vibratoWeightMs);
  int corePercent(double value) => totalWeightMs <= 0 ? 0 : (value * 100 / totalWeightMs).clamp(0,100).round();
  String get grade => gradeFromScore(scorePercent);
}

class KaraokeResult {
  KaraokeResult.from(KaraokeTrack? track, this.snapshot) : title = track?.title ?? '', artist = track?.artist ?? '', freeSing = track == null;
  final String title, artist;
  final bool freeSing;
  final KaraokeScoreSnapshot snapshot;
  int get scorePercent => snapshot.scorePercent;
  String get grade => snapshot.grade;
}

