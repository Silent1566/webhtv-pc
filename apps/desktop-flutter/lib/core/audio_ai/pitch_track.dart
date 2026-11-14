/// 卡拉 OK 音高评分轨：安卓 `KaraokePitchTrackGenerator` 的逐条移植。
///
/// 常量、分段压缩（520ms/单元、最多 10 单元）、全局动态规划候选路径、
/// 八度归一化以及 stabilize→merge→key→octave→outlier→tiny 后处理链
/// 都来自只读源 `app/src/main/java/com/fongmi/android/tv/player/karaoke/
/// KaraokePitchTrackGenerator.java`，不使用贪心近似。
library;

import 'dart:math' as math;

const double kUltraStarBpm = 6000;
const int kBeatMs = 10;
const int kRapPitch = 60;
const int kMaxNotes = 900;
const int kMinNoteMs = 120;
const int kMinStableNoteMs = 180;
const int kDefaultLastLineMs = 3000;
const int kLineUnitMs = 520;
const int kMaxLineUnits = 10;
const int kWordCompactMs = 280;
const double kMinRawPitchRatio = 0.08;
const double kMinTrackPitchRatio = 0.18;
const int kMinMidi = 40;
const int kMaxMidi = 84;
const int kGapFillMaxNotes = 8;
const int kOutlierStep = 9;
const int kTinyRunMs = 220;
const int kMergeStrongDelta = 1;
const int kMergeWeakDelta = 2;
const int kMergeGapMs = 140;
const int kMergeMaxMs = 2600;
const int kRapMergeMaxMs = 5200;
const double kKeyCorrectionMaxQuality = 0.68;
const int kMaxPathCandidates = 4;
const double kPathMissingPenalty = 0.22;
const double kPathLineBreakRelax = 0.56;

/// 伪调性表（源 `KEY_TABLE` 原值）。
const List<List<double>> kKeyTable = [
  [0.19, 0.00, 0.21, 0.00, 0.21, 0.08, 0.00, 0.13, 0.00, 0.11, 0.00, 0.07],
  [0.09, 0.21, 0.00, 0.17, 0.00, 0.18, 0.08, 0.00, 0.13, 0.00, 0.14, 0.00],
  [0.00, 0.07, 0.19, 0.00, 0.18, 0.00, 0.17, 0.08, 0.00, 0.19, 0.00, 0.12],
  [0.11, 0.00, 0.10, 0.26, 0.00, 0.16, 0.00, 0.17, 0.07, 0.00, 0.13, 0.00],
  [0.00, 0.14, 0.00, 0.07, 0.28, 0.00, 0.17, 0.00, 0.13, 0.06, 0.00, 0.15],
  [0.15, 0.00, 0.16, 0.00, 0.13, 0.17, 0.00, 0.16, 0.00, 0.13, 0.10, 0.00],
  [0.00, 0.15, 0.00, 0.16, 0.00, 0.12, 0.17, 0.00, 0.14, 0.00, 0.14, 0.12],
  [0.09, 0.00, 0.16, 0.00, 0.16, 0.00, 0.11, 0.17, 0.00, 0.16, 0.00, 0.15],
  [0.18, 0.07, 0.00, 0.15, 0.00, 0.14, 0.00, 0.09, 0.19, 0.00, 0.18, 0.00],
  [0.00, 0.18, 0.10, 0.00, 0.14, 0.00, 0.15, 0.00, 0.10, 0.17, 0.00, 0.16],
  [0.13, 0.00, 0.15, 0.09, 0.00, 0.16, 0.00, 0.18, 0.00, 0.12, 0.17, 0.00],
  [0.00, 0.11, 0.00, 0.19, 0.13, 0.00, 0.16, 0.00, 0.12, 0.00, 0.08, 0.21],
];

class KaraokePitchException implements Exception {
  KaraokePitchException(this.message);

  final String message;

  @override
  String toString() => 'KaraokePitchException: $message';
}

/// 逐词时间戳（源 `LyricsWord` 的 offset/duration），不丢失不均匀 timing。
class TimedLyricWord {
  const TimedLyricWord({
    required this.text,
    required this.startOffsetMs,
    required this.durationMs,
  });

  final String text;
  final int startOffsetMs;
  final int durationMs;
}

class TimedLyricLine {
  const TimedLyricLine({
    required this.index,
    required this.startMs,
    required this.endMs,
    required this.text,
    this.words = const [],
  });

  final int index;
  final int startMs;
  final int endMs;
  final String text;

  /// 逐词 timing；为空表示该行只有整行时间，按字符/词均分。
  final List<TimedLyricWord> words;
}

class KaraokeLyricSegment {
  const KaraokeLyricSegment({
    required this.startMs,
    required this.endMs,
    required this.text,
    this.lineEnd = false,
  });

  final int startMs;
  final int endMs;
  final String text;
  final bool lineEnd;

  KaraokeLyricSegment copyWith({bool? lineEnd}) => KaraokeLyricSegment(
    startMs: startMs,
    endMs: endMs,
    text: text,
    lineEnd: lineEnd ?? this.lineEnd,
  );
}

/// 一个歌词片段的音高候选；[midi] 为 -1 表示该片段没有被检出音高。
class PitchCandidate {
  const PitchCandidate({required this.midi, required this.quality});

  static const PitchCandidate empty = PitchCandidate(midi: -1, quality: 0);

  final int midi;
  final double quality;

  bool get observed => midi >= 0 && quality > 0;
}

class KaraokePitchTrack {
  const KaraokePitchTrack({
    required this.text,
    required this.noteCount,
    required this.observed,
    required this.pitched,
  });

  final String text;
  final int noteCount;
  final int observed;
  final int pitched;
}

int clampMidi(int pitch) => math.max(kMinMidi, math.min(kMaxMidi, pitch));

int pitchClass(int pitch) => ((pitch % 12) + 12) % 12;

/// 八度归一化：在 ±24 半音内选择离参考最近的同音高类值。
int normalizeOctave(int pitch, int reference) {
  var best = pitch;
  var bestDistance = (best - reference).abs();
  for (var candidate = pitch - 24; candidate <= pitch + 24; candidate += 12) {
    if (candidate < kMinMidi || candidate > kMaxMidi) continue;
    final distance = (candidate - reference).abs();
    if (distance < bestDistance) {
      best = candidate;
      bestDistance = distance;
    }
  }
  return clampMidi(best);
}

/// 把带时间戳歌词切成评分单元（源 `segments`/`appendWordSegments`/
/// `appendLineSegments`）。
List<KaraokeLyricSegment> buildKaraokeSegments(
  List<TimedLyricLine> lines, {
  int maxNotes = kMaxNotes,
  int durationMs = 0,
}) {
  final segments = <KaraokeLyricSegment>[];
  for (var i = 0; i < lines.length && segments.length < maxNotes; i++) {
    final line = lines[i];
    if (line.text.trim().isEmpty) continue;
    final startMs = line.startMs;
    final endMs = _lineEndMs(lines, i, durationMs);
    if (endMs - startMs < kMinNoteMs) continue;
    final before = segments.length;
    if (line.words.isNotEmpty) {
      _appendWordSegments(segments, line, startMs, endMs);
    } else {
      _appendLineSegments(segments, line.text, startMs, endMs);
    }
    if (segments.length > before) {
      segments[segments.length - 1] = segments.last.copyWith(lineEnd: true);
    }
  }
  if (segments.length < 3) {
    throw KaraokePitchException('not enough lyric timing');
  }
  return segments;
}

int _lineEndMs(List<TimedLyricLine> lines, int index, int durationMs) {
  final startMs = lines[index].startMs;
  final nextMs = index + 1 < lines.length ? lines[index + 1].startMs : 0;
  final explicitEnd = lines[index].endMs;
  var end = explicitEnd > startMs
      ? explicitEnd
      : (nextMs > startMs ? nextMs : startMs + kDefaultLastLineMs);
  if (nextMs > startMs) end = math.min(end, nextMs);
  end = math.max(startMs + kMinNoteMs, end);
  if (durationMs > 0) end = math.min(end, durationMs);
  return end;
}

KaraokeLyricSegment _segment(int startMs, int endMs, String text) {
  final start = math.max(0, startMs);
  return KaraokeLyricSegment(
    startMs: start,
    endMs: math.max(start + kMinNoteMs, endMs),
    text: text,
  );
}

void _appendWordSegments(
  List<KaraokeLyricSegment> segments,
  TimedLyricLine line,
  int lineStartMs,
  int lineEndMs,
) {
  final raw = <KaraokeLyricSegment>[];
  final words = line.words;
  for (var i = 0; i < words.length && segments.length < kMaxNotes; i++) {
    final word = words[i];
    if (word.text.isEmpty) continue;
    final startMs = lineStartMs + word.startOffsetMs;
    final endMs = word.durationMs > 0
        ? startMs + word.durationMs
        : (i + 1 < words.length
              ? lineStartMs + words[i + 1].startOffsetMs
              : lineEndMs);
    final safeStart = math.max(lineStartMs, startMs);
    final safeEnd = math.min(lineEndMs, math.max(safeStart + kMinNoteMs, endMs));
    if (safeEnd - safeStart < kMinNoteMs) continue;
    raw.add(_segment(safeStart, safeEnd, word.text));
  }
  if (raw.isEmpty) return;
  if (_shouldCompactWords(raw, lineEndMs - lineStartMs)) {
    _appendCompactedSegments(segments, raw, lineEndMs - lineStartMs);
  } else {
    for (final segment in raw) {
      if (segments.length < kMaxNotes) segments.add(segment);
    }
  }
}

bool _shouldCompactWords(List<KaraokeLyricSegment> raw, int durationMs) {
  if (raw.length <= 4) return false;
  final target = targetUnitCount(raw.length, durationMs);
  if (raw.length <= target) return false;
  var shortText = 0;
  var shortDuration = 0;
  for (final segment in raw) {
    if (segment.text.runes.length <= 1) shortText++;
    if (segment.endMs - segment.startMs <= kWordCompactMs) shortDuration++;
  }
  return shortText >= (raw.length * 0.7).round() ||
      shortDuration >= (raw.length * 0.65).round();
}

void _appendCompactedSegments(
  List<KaraokeLyricSegment> output,
  List<KaraokeLyricSegment> raw,
  int durationMs,
) {
  final target = math.max(
    1,
    math.min(raw.length, targetUnitCount(raw.length, durationMs)),
  );
  final groupSize = (raw.length / target).ceil();
  for (var i = 0; i < raw.length && output.length < kMaxNotes; i += groupSize) {
    final end = math.min(raw.length, i + groupSize);
    final text = StringBuffer();
    for (var j = i; j < end; j++) {
      text.write(raw[j].text);
    }
    output.add(_segment(raw[i].startMs, raw[end - 1].endMs, text.toString()));
  }
}

void _appendLineSegments(
  List<KaraokeLyricSegment> segments,
  String text,
  int startMs,
  int endMs,
) {
  final units = splitKaraokeUnits(
    text,
    durationMs: math.max(kMinNoteMs, endMs - startMs),
  );
  if (units.isEmpty) return;
  final duration = endMs - startMs;
  final unitMs = math.max(kMinNoteMs, duration ~/ units.length);
  for (var i = 0; i < units.length && segments.length < kMaxNotes; i++) {
    final unitStart = startMs + unitMs * i;
    final unitEnd = i == units.length - 1
        ? startMs + duration
        : unitStart + unitMs;
    final safeEnd = math.min(endMs, unitEnd);
    if (safeEnd - unitStart < kMinNoteMs) continue;
    segments.add(_segment(unitStart, safeEnd, units[i]));
  }
}

/// 源 `splitUnits`：含空白按词，否则按 code point；随后按
/// [targetUnitCount] 压缩（520ms/单元、上限 10 单元、最多减半）。
List<String> splitKaraokeUnits(String text, {int durationMs = 0}) {
  final clean = _lyric(text);
  if (clean.isEmpty) return const [];
  if (RegExp(r'\s').hasMatch(clean)) {
    final words = [
      for (final unit in clean.split(RegExp(r'\s+')))
        if (unit.isNotEmpty) unit,
    ];
    return _compactUnits(
      words,
      targetUnitCount(words.length, durationMs),
      ' ',
    );
  }
  final chars = <String>[];
  for (final rune in clean.runes) {
    chars.add(String.fromCharCode(rune));
  }
  return _compactUnits(chars, targetUnitCount(chars.length, durationMs), '');
}

int targetUnitCount(int sourceCount, int durationMs) {
  if (sourceCount <= 0) return 0;
  if (sourceCount <= 4) return sourceCount;
  final byDuration = math.max(1, (durationMs / kLineUnitMs).round());
  final byText = math.max(1, (sourceCount / 2).ceil());
  return math.max(
    1,
    math.min(
      math.min(kMaxLineUnits, sourceCount),
      math.min(byDuration, byText),
    ),
  );
}

List<String> _compactUnits(
  List<String> source,
  int targetCount,
  String separator,
) {
  if (source.isEmpty) return const [];
  final count = math.max(1, math.min(source.length, targetCount));
  final groupSize = (source.length / count).ceil();
  final units = <String>[];
  for (var i = 0; i < source.length; i += groupSize) {
    final builder = StringBuffer();
    for (var j = i; j < math.min(source.length, i + groupSize); j++) {
      if (builder.isNotEmpty) builder.write(separator);
      builder.write(source[j]);
    }
    units.add(builder.toString());
  }
  return units;
}

/// 源 `smoothCandidatePath`：全局累计分数 + 回溯 + 路径八度归一化。
///
/// 与贪心不同：前段较弱的候选只要让整条路径更平顺，就会被选上。
List<PitchCandidate> smoothKaraokeCandidatePath(
  List<KaraokeLyricSegment> segments,
  List<List<PitchCandidate>> candidates,
) {
  if (segments.isEmpty) return const [];
  final count = segments.length;
  final rows = [
    for (var i = 0; i < count; i++) _safeCandidates(candidates[i]),
  ];
  final scores = [for (var i = 0; i < count; i++) List<double>.filled(rows[i].length, 0)];
  final previous = [
    for (var i = 0; i < count; i++) List<int>.filled(rows[i].length, -1),
  ];
  for (var i = 0; i < count; i++) {
    final row = rows[i];
    for (var j = 0; j < row.length; j++) {
      final emission = _emissionScore(row[j]);
      if (i == 0) {
        scores[i][j] = emission;
        previous[i][j] = -1;
        continue;
      }
      final prevRow = rows[i - 1];
      var best = -double.maxFinite;
      var bestIndex = 0;
      for (var k = 0; k < prevRow.length; k++) {
        final score =
            scores[i - 1][k] +
            emission -
            _transitionPenalty(
              prevRow[k],
              row[j],
              segments[i - 1].lineEnd,
            );
        if (score > best) {
          best = score;
          bestIndex = k;
        }
      }
      scores[i][j] = best;
      previous[i][j] = bestIndex;
    }
  }
  var bestIndex = 0;
  var bestScore = -double.maxFinite;
  for (var i = 0; i < scores[count - 1].length; i++) {
    if (scores[count - 1][i] > bestScore) {
      bestScore = scores[count - 1][i];
      bestIndex = i;
    }
  }
  final path = List<PitchCandidate?>.filled(count, null);
  for (var i = count - 1; i >= 0; i--) {
    final row = rows[i];
    if (bestIndex < 0 || bestIndex >= row.length) break;
    path[i] = row[bestIndex];
    bestIndex = previous[i][bestIndex];
    if (bestIndex < 0) break;
  }
  for (var i = 0; i < path.length; i++) {
    path[i] ??= PitchCandidate.empty;
  }
  _normalizePathOctaves(path);
  return path.cast<PitchCandidate>();
}

List<PitchCandidate> _safeCandidates(List<PitchCandidate>? candidates) =>
    candidates == null || candidates.isEmpty
    ? const [PitchCandidate.empty]
    : candidates.take(kMaxPathCandidates).toList();

double _emissionScore(PitchCandidate candidate) =>
    candidate.midi < 0 ? -kPathMissingPenalty : candidate.quality * 1.85;

double _transitionPenalty(
  PitchCandidate previous,
  PitchCandidate current,
  bool lineBreak,
) {
  if (previous.midi < 0 || current.midi < 0) return kPathMissingPenalty;
  final pitch = normalizeOctave(current.midi, previous.midi);
  final jump = (pitch - previous.midi).abs();
  double penalty;
  if (jump <= 1) {
    penalty = 0.015 * jump;
  } else if (jump <= 3) {
    penalty = 0.04 + (jump - 1) * 0.045;
  } else if (jump <= 7) {
    penalty = 0.18 + (jump - 3) * 0.075;
  } else {
    penalty = 0.50 + (jump - 7) * 0.16;
  }
  if (jump >= 11) penalty += 0.24;
  return lineBreak ? penalty * kPathLineBreakRelax : penalty;
}

void _normalizePathOctaves(List<PitchCandidate?> path) {
  int? anchor;
  for (var i = 0; i < path.length; i++) {
    final candidate = path[i];
    if (candidate == null || candidate.midi < 0) continue;
    final pitch = anchor == null
        ? candidate.midi
        : normalizeOctave(candidate.midi, anchor);
    path[i] = PitchCandidate(midi: pitch, quality: candidate.quality);
    anchor = pitch;
  }
}

class _KaraokeNote {
  _KaraokeNote(
    this.segment,
    int pitch,
    this.observed,
    double quality,
    this.estimated,
  ) : pitch = pitch >= 0 ? clampMidi(pitch) : -1,
      quality = quality.clamp(0.0, 1.0);

  factory _KaraokeNote.fromCandidate(
    KaraokeLyricSegment segment,
    PitchCandidate candidate,
  ) => _KaraokeNote(
    segment,
    candidate.midi,
    candidate.midi >= 0,
    candidate.quality,
    false,
  );

  KaraokeLyricSegment segment;
  int pitch;
  final bool observed;
  final double quality;
  bool estimated;
}

/// 由真实候选构建评分轨；候选路径与后处理与安卓逐条一致。
KaraokePitchTrack buildKaraokePitchTrack({
  required String title,
  required String artist,
  required List<KaraokeLyricSegment> segments,
  required List<PitchCandidate> candidates,
  String comment = 'Generated by Basic Pitch TFLite from local audio',
}) => buildKaraokePitchTrackFromCandidates(
  title: title,
  artist: artist,
  segments: segments,
  candidates: [
    for (final candidate in candidates) [candidate],
  ],
  comment: comment,
);

/// 每段多候选（BasicPitch 片段候选）→ 全局 DP → 后处理 → UltraStar 文本。
KaraokePitchTrack buildKaraokePitchTrackFromCandidates({
  required String title,
  required String artist,
  required List<KaraokeLyricSegment> segments,
  required List<List<PitchCandidate>> candidates,
  String comment = 'Generated by Basic Pitch TFLite from local audio',
}) {
  if (segments.length != candidates.length) {
    throw KaraokePitchException('candidate count mismatch');
  }
  final path = smoothKaraokeCandidatePath(segments, candidates);
  final notes = [
    for (var i = 0; i < segments.length; i++)
      _KaraokeNote.fromCandidate(segments[i], path[i]),
  ];
  _stabilize(notes);
  _smoothLineContour(notes);
  var working = _mergeNotes(notes);
  _applyPseudoKey(working);
  _correctOctaves(working);
  _smoothOutliers(working);
  _smoothLineContour(working);
  working = _mergeNotes(working);
  working = _absorbTinyRuns(working);
  working = _mergeNotes(working);

  final buffer = StringBuffer()
    ..writeln('#TITLE:${_tag(title, 'Generated pitch track')}')
    ..writeln('#ARTIST:${_tag(artist, 'Unknown')}')
    ..writeln('#BPM:${kUltraStarBpm.toStringAsFixed(0)}')
    ..writeln('#GAP:0')
    ..writeln(
      '#COMMENT:${_tag(comment, 'Generated pitch scoring track from local audio')}',
    );

  var count = 0;
  var observed = 0;
  var pitched = 0;
  for (final note in working) {
    if (count >= kMaxNotes) break;
    final prefix = note.pitch >= 0 ? ':' : 'R';
    if (note.observed) observed++;
    if (note.pitch >= 0) pitched++;
    _appendNote(
      buffer,
      prefix,
      note.segment.startMs,
      note.segment.endMs,
      note.pitch >= 0 ? note.pitch : kRapPitch,
      note.segment.text,
    );
    count++;
    if (note.segment.lineEnd) buffer.writeln('-');
  }
  if (count < 3) throw KaraokePitchException('not enough notes');
  if (observed < 3 || observed < (count * kMinRawPitchRatio).round()) {
    throw KaraokePitchException('pitch quality too low');
  }
  if (pitched < 3 || pitched < (count * kMinTrackPitchRatio).round()) {
    throw KaraokePitchException('pitch quality too low');
  }
  buffer.writeln('E');
  return KaraokePitchTrack(
    text: buffer.toString(),
    noteCount: count,
    observed: observed,
    pitched: pitched,
  );
}

void _stabilize(List<_KaraokeNote> notes) {
  _correctOctaves(notes);
  _smoothOutliers(notes);
  _fillMissing(notes);
  _correctOctaves(notes);
  _smoothOutliers(notes);
}

void _smoothLineContour(List<_KaraokeNote> notes) {
  var start = 0;
  while (start < notes.length) {
    var end = start;
    while (end < notes.length && !notes[end].segment.lineEnd) {
      end++;
    }
    end = math.min(notes.length - 1, end);
    _smoothLineRange(notes, start, end);
    start = end + 1;
  }
}

void _smoothLineRange(List<_KaraokeNote> notes, int start, int end) {
  final pitches = <int>[];
  for (var i = start; i <= end; i++) {
    if (notes[i].pitch >= 0) pitches.add(notes[i].pitch);
  }
  if (pitches.length < 2) return;
  pitches.sort();
  final median = pitches[pitches.length ~/ 2];
  final low = pitches.first;
  final high = pitches.last;
  final mostlyFlat = high - low <= 2;
  for (var i = start; i <= end; i++) {
    final note = notes[i];
    if (note.pitch < 0) continue;
    final normalized = normalizeOctave(note.pitch, median);
    final microJitter = mostlyFlat && (normalized - median).abs() <= 1;
    if (microJitter ||
        (((normalized - median).abs() <= 1 || mostlyFlat) &&
            (note.quality < 0.55 || note.estimated))) {
      note.pitch = median;
      note.estimated = true;
    } else {
      note.pitch = normalized;
    }
  }
}

List<_KaraokeNote> _mergeNotes(List<_KaraokeNote> notes) {
  final merged = <_KaraokeNote>[];
  for (final note in notes) {
    if (merged.isNotEmpty && _canMerge(merged.last, note)) {
      merged[merged.length - 1] = _merge(merged.last, note);
    } else {
      merged.add(note);
    }
  }
  return merged;
}

bool _canMerge(_KaraokeNote previous, _KaraokeNote next) {
  if (previous.segment.lineEnd) return false;
  if (next.segment.startMs - previous.segment.endMs > kMergeGapMs) return false;
  final duration = next.segment.endMs - previous.segment.startMs;
  final previousDuration = previous.segment.endMs - previous.segment.startMs;
  final nextDuration = next.segment.endMs - next.segment.startMs;
  if (previous.pitch < 0 && next.pitch < 0) return duration <= kRapMergeMaxMs;
  if (previous.pitch < 0 || next.pitch < 0) {
    return duration <= kMergeMaxMs &&
        math.min(previousDuration, nextDuration) <= kTinyRunMs;
  }
  if (duration > kMergeMaxMs) return false;
  final delta = (normalizeOctave(next.pitch, previous.pitch) - previous.pitch)
      .abs();
  if (delta <= kMergeStrongDelta) return true;
  return delta <= kMergeWeakDelta &&
      (previous.estimated ||
          next.estimated ||
          previous.quality < 0.55 ||
          next.quality < 0.55 ||
          math.min(previousDuration, nextDuration) < kMinStableNoteMs);
}

_KaraokeNote _merge(_KaraokeNote previous, _KaraokeNote next) {
  final previousDuration = math.max(
    1,
    previous.segment.endMs - previous.segment.startMs,
  );
  final nextDuration = math.max(1, next.segment.endMs - next.segment.startMs);
  int pitch;
  var nextPitch = next.pitch;
  if (previous.pitch < 0 && next.pitch < 0) {
    pitch = -1;
  } else if (previous.pitch < 0) {
    pitch = next.pitch;
  } else if (next.pitch < 0) {
    pitch = previous.pitch;
  } else {
    nextPitch = normalizeOctave(next.pitch, previous.pitch);
    pitch = clampMidi(
      ((previous.pitch * previousDuration + nextPitch * nextDuration) /
              (previousDuration + nextDuration))
          .round(),
    );
  }
  final segment = KaraokeLyricSegment(
    startMs: previous.segment.startMs,
    endMs: next.segment.endMs,
    text: previous.segment.text + next.segment.text,
    lineEnd: next.segment.lineEnd,
  );
  final estimated =
      previous.estimated ||
      next.estimated ||
      previous.pitch != pitch ||
      nextPitch != pitch;
  return _KaraokeNote(
    segment,
    pitch,
    previous.observed || next.observed,
    math.max(previous.quality, next.quality),
    estimated,
  );
}

List<_KaraokeNote> _absorbTinyRuns(List<_KaraokeNote> notes) {
  final result = List<_KaraokeNote>.of(notes);
  var index = 0;
  while (index < result.length) {
    final note = result[index];
    if (note.segment.endMs - note.segment.startMs >= kTinyRunMs) {
      index++;
      continue;
    }
    final previousIndex = index > 0 && !result[index - 1].segment.lineEnd
        ? index - 1
        : -1;
    final nextIndex = index + 1 < result.length && !note.segment.lineEnd
        ? index + 1
        : -1;
    if (previousIndex < 0 && nextIndex < 0) {
      index++;
      continue;
    }
    final toPrevious = _shouldAbsorbToPrevious(
      result,
      previousIndex,
      nextIndex,
      note,
    );
    if (toPrevious) {
      result[previousIndex] = _merge(result[previousIndex], note);
      result.removeAt(index);
      index = math.max(0, previousIndex - 1);
    } else {
      result[index] = _merge(note, result[nextIndex]);
      result.removeAt(nextIndex);
    }
  }
  return result;
}

bool _shouldAbsorbToPrevious(
  List<_KaraokeNote> notes,
  int previousIndex,
  int nextIndex,
  _KaraokeNote note,
) {
  if (previousIndex < 0) return false;
  if (nextIndex < 0) return true;
  final previous = notes[previousIndex];
  final next = notes[nextIndex];
  final previousCost = _mergeCost(previous, note);
  final nextCost = _mergeCost(note, next);
  if (previousCost != nextCost) return previousCost < nextCost;
  final previousDuration = previous.segment.endMs - previous.segment.startMs;
  final nextDuration = next.segment.endMs - next.segment.startMs;
  return previousDuration >= nextDuration;
}

int _mergeCost(_KaraokeNote left, _KaraokeNote right) {
  if (left.pitch < 0 && right.pitch < 0) return 0;
  if (left.pitch < 0 || right.pitch < 0) return 2;
  return (normalizeOctave(right.pitch, left.pitch) - left.pitch).abs();
}

void _applyPseudoKey(List<_KaraokeNote> notes) {
  final key = _detectPseudoKey(notes);
  if (key < 0) return;
  for (final note in notes) {
    if (note.pitch < 0 ||
        (!note.estimated && note.quality > kKeyCorrectionMaxQuality)) {
      continue;
    }
    final pc = pitchClass(note.pitch);
    if (kKeyTable[key][pc] > 0) continue;
    final up = pitchClass(note.pitch + 1);
    final down = pitchClass(note.pitch - 1);
    final shift = kKeyTable[key][up] >= kKeyTable[key][down] ? 1 : -1;
    note.pitch = clampMidi(note.pitch + shift);
    note.estimated = true;
  }
}

int _detectPseudoKey(List<_KaraokeNote> notes) {
  final distribution = List<double>.filled(12, 0);
  var total = 0.0;
  for (final note in notes) {
    if (note.pitch < 0) continue;
    final duration = math.max(1, note.segment.endMs - note.segment.startMs);
    final weight = duration * math.max(0.25, note.quality);
    distribution[pitchClass(note.pitch)] += weight;
    total += weight;
  }
  if (total <= 0) return -1;
  var best = -1;
  var bestScore = 0.0;
  for (var key = 0; key < kKeyTable.length; key++) {
    var score = 0.0;
    for (var pc = 0; pc < distribution.length; pc++) {
      score += kKeyTable[key][pc] * distribution[pc];
    }
    if (score > bestScore) {
      bestScore = score;
      best = key;
    }
  }
  return best;
}

void _correctOctaves(List<_KaraokeNote> notes) {
  int? anchor;
  for (final note in notes) {
    if (note.pitch < 0) continue;
    if (anchor != null) note.pitch = normalizeOctave(note.pitch, anchor);
    if (anchor != null &&
        (note.pitch - anchor).abs() > kOutlierStep &&
        note.quality < 0.45) {
      note.pitch = -1;
      note.estimated = true;
      continue;
    }
    anchor = note.pitch;
  }
  anchor = null;
  for (var i = notes.length - 1; i >= 0; i--) {
    final note = notes[i];
    if (note.pitch < 0) continue;
    if (anchor != null) note.pitch = normalizeOctave(note.pitch, anchor);
    anchor = note.pitch;
  }
}

void _smoothOutliers(List<_KaraokeNote> notes) {
  for (var i = 0; i < notes.length; i++) {
    final note = notes[i];
    if (note.pitch < 0) continue;
    final previous = _previousNote(notes, i);
    final next = _nextNote(notes, i);
    if (previous == null || next == null) continue;
    if (previous.distance > 3 || next.distance > 3) continue;
    final target = ((previous.note.pitch + next.note.pitch) / 2.0).round();
    note.pitch = normalizeOctave(note.pitch, target);
    if ((note.pitch - target).abs() > kOutlierStep && note.quality < 0.65) {
      note.pitch = clampMidi(target);
      note.estimated = true;
    }
  }
}

class _Neighbor {
  const _Neighbor(this.note, this.distance);

  final _KaraokeNote note;
  final int distance;
}

_Neighbor? _previousNote(List<_KaraokeNote> notes, int index) {
  for (var i = index - 1; i >= 0; i--) {
    if (notes[i].pitch >= 0) return _Neighbor(notes[i], index - i);
  }
  return null;
}

_Neighbor? _nextNote(List<_KaraokeNote> notes, int index) {
  for (var i = index + 1; i < notes.length; i++) {
    if (notes[i].pitch >= 0) return _Neighbor(notes[i], i - index);
  }
  return null;
}

void _fillMissing(List<_KaraokeNote> notes) {
  var index = 0;
  while (index < notes.length) {
    if (notes[index].pitch >= 0) {
      index++;
      continue;
    }
    final start = index;
    while (index < notes.length && notes[index].pitch < 0) {
      index++;
    }
    final end = index;
    final length = end - start;
    if (length > kGapFillMaxNotes) continue;
    final previous = start > 0 ? notes[start - 1] : null;
    final next = end < notes.length ? notes[end] : null;
    if (previous != null &&
        previous.pitch >= 0 &&
        next != null &&
        next.pitch >= 0) {
      final nextPitch = normalizeOctave(next.pitch, previous.pitch);
      for (var i = start; i < end; i++) {
        final progress = (i - start + 1) / (length + 1);
        final value =
            previous.pitch + (nextPitch - previous.pitch) * progress;
        notes[i].pitch = clampMidi(value.round());
        notes[i].estimated = true;
      }
    } else if (previous != null && previous.pitch >= 0) {
      for (var i = start; i < end; i++) {
        notes[i].pitch = previous.pitch;
        notes[i].estimated = true;
      }
    } else if (next != null && next.pitch >= 0) {
      for (var i = start; i < end; i++) {
        notes[i].pitch = next.pitch;
        notes[i].estimated = true;
      }
    }
  }
}

void _appendNote(
  StringBuffer buffer,
  String prefix,
  int startMs,
  int endMs,
  int pitch,
  String lyric,
) {
  final safeStart = math.max(0, startMs);
  final safeEnd = math.max(safeStart + kMinNoteMs, endMs);
  final startBeat = math.max(0, (safeStart / kBeatMs).round());
  final lengthBeat = math.max(1, ((safeEnd - safeStart) / kBeatMs).round());
  buffer.writeln(
    '$prefix $startBeat $lengthBeat $pitch ${_lyric(lyric)}',
  );
}

String _tag(String value, String fallback) {
  final text = _lyric(value);
  return text.isEmpty ? fallback : text;
}

String _lyric(String value) =>
    value.replaceAll('\r', ' ').replaceAll('\n', ' ').trim();
