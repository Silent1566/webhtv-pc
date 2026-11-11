/// 字幕翻译分块计划与并发上限（源 `AiSubtitleTranslationService`）。
library;

class CueRange {
  const CueRange(this.start, this.end);

  final int start;
  final int end;

  int get length => end - start;
}

const int defaultMaxConcurrency = 2;
const int maxConfiguredConcurrency = 8;
const int defaultChunkCount = 2;
const int maxConfiguredChunkCount = 32;
const int maxTranslationAttempts = 3;

int clampConcurrency(int value) => value < 1
    ? 1
    : (value > maxConfiguredConcurrency ? maxConfiguredConcurrency : value);

int clampChunkCount(int value) => value < 1
    ? 1
    : (value > maxConfiguredChunkCount ? maxConfiguredChunkCount : value);

/// 与源 `planRanges` 一致：均分，余数给前面的块，末尾多出的再补一块。
List<CueRange> planCueRanges(int cueCount, int targetChunkCount) {
  if (cueCount <= 0) return const [];
  final count = clampChunkCount(targetChunkCount) > cueCount
      ? cueCount
      : clampChunkCount(targetChunkCount);
  final base = cueCount ~/ count;
  final remainder = cueCount % count;
  final ranges = <CueRange>[];
  var offset = 0;
  for (var i = 0; i < count; i++) {
    final length = base + (i < remainder ? 1 : 0);
    final end = (offset + (length < 1 ? 1 : length)) > cueCount
        ? cueCount
        : offset + (length < 1 ? 1 : length);
    ranges.add(CueRange(offset, end));
    offset = end;
  }
  if (offset < cueCount) ranges.add(CueRange(offset, cueCount));
  return ranges;
}

/// 失败缩块：二分；长度为 1 时不再缩小。
CueRange? splitRange(CueRange range) {
  if (range.length <= 1) return null;
  final middle = range.start + (range.length ~/ 2 < 1 ? 1 : range.length ~/ 2);
  return CueRange(middle, range.end);
}
