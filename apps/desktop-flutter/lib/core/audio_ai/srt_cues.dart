/// SRT 解析/渲染与翻译响应校验。
///
/// 合同（源 `AiSubtitleTranslationService`）：译文只替换文本，序号与时间轴
/// 必须保持源 SRT 原值；任何缺失/重复/未知 cue ID 都视为该请求失败，交给
/// 上层重试与缩块，不允许静默丢行。
library;

class SrtCue {
  const SrtCue({
    required this.index,
    required this.startMs,
    required this.endMs,
    required this.text,
  });

  final int index;
  final int startMs;
  final int endMs;
  final String text;

  SrtCue withText(String value) =>
      SrtCue(index: index, startMs: startMs, endMs: endMs, text: value);
}

class SrtFormatException implements Exception {
  SrtFormatException(this.message);

  final String message;

  @override
  String toString() => 'SrtFormatException: $message';
}

class SrtDocument {
  const SrtDocument({required this.source, required this.cues});

  /// 原始 SRT 文本，翻译过程只读不改。
  final String source;
  final List<SrtCue> cues;

  static SrtDocument parse(String text) {
    final normalized = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final blocks = normalized.split(RegExp(r'\n{2,}'));
    final cues = <SrtCue>[];
    for (final block in blocks) {
      final lines = block.split('\n').where((line) => line.trim().isNotEmpty);
      final list = lines.toList();
      if (list.isEmpty) continue;
      var cursor = 0;
      var index = cues.length + 1;
      final first = list.first.trim();
      if (RegExp(r'^\d+$').hasMatch(first)) {
        index = int.parse(first);
        cursor = 1;
      }
      if (cursor >= list.length) continue;
      final range = _parseRange(list[cursor]);
      if (range == null) continue;
      cursor++;
      final body = list.sublist(cursor).join('\n');
      cues.add(
        SrtCue(
          index: index,
          startMs: range.$1,
          endMs: range.$2,
          text: body.trim(),
        ),
      );
    }
    if (cues.isEmpty) throw SrtFormatException('no cues');
    return SrtDocument(source: text, cues: cues);
  }

  static String render(List<SrtCue> cues) {
    final blocks = <String>[];
    for (final cue in cues) {
      blocks.add(
        '${cue.index}\n${_stamp(cue.startMs)} --> ${_stamp(cue.endMs)}\n${cue.text}',
      );
    }
    if (blocks.isEmpty) return '';
    return '${blocks.join('\n\n')}\n';
  }

  /// 用逐条译文重建 SRT；缺译文或空白译文回退源文本（原文保护）。
  String withTranslations(Map<int, String> byIndex) {
    final merged = <SrtCue>[];
    for (var i = 0; i < cues.length; i++) {
      final cue = cues[i];
      final translated = byIndex[cue.index];
      final text = (translated ?? '').trim();
      merged.add(cue.withText(text.isEmpty ? cue.text : text));
    }
    return render(merged);
  }

  /// 当前播放位置对应的字幕（供播放器叠加层与搜索候选使用，不改既有字幕轨）。
  SrtCue? cueAt(int positionMs) {
    for (final cue in cues) {
      if (positionMs >= cue.startMs && positionMs < cue.endMs) return cue;
    }
    return null;
  }

  static (int, int)? _parseRange(String line) {
    final match = RegExp(
      r'(\d{1,2}):(\d{2}):(\d{2})[,.](\d{3})\s*-->\s*(\d{1,2}):(\d{2}):(\d{2})[,.](\d{3})',
    ).firstMatch(line);
    if (match == null) return null;
    return (_toMs(match, 1), _toMs(match, 5));
  }

  static int _toMs(RegExpMatch match, int offset) {
    final hours = int.parse(match.group(offset)!);
    final minutes = int.parse(match.group(offset + 1)!);
    final seconds = int.parse(match.group(offset + 2)!);
    final millis = int.parse(match.group(offset + 3)!);
    return ((hours * 60 + minutes) * 60 + seconds) * 1000 + millis;
  }

  static String _stamp(int milliseconds) {
    final value = milliseconds < 0 ? 0 : milliseconds;
    final hours = value ~/ 3600000;
    final minutes = (value % 3600000) ~/ 60000;
    final seconds = (value % 60000) ~/ 1000;
    final millis = value % 1000;
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(hours)}:${two(minutes)}:${two(seconds)},'
        '${millis.toString().padLeft(3, '0')}';
  }
}

/// 一次分块请求的译文解析结果。
///
/// 模型输出是外部不可信数据：必须覆盖本块全部 cue ID 且不夹带块外 ID，
/// 否则抛 [SrtChunkFormatException]，由调用方重试（每请求最多 3 次）后缩块。
class SrtChunkFormatException implements Exception {
  SrtChunkFormatException(this.message);

  final String message;

  @override
  String toString() => 'SrtChunkFormatException: $message';
}

Map<int, String> parseChunkTranslations(
  String raw, {
  required Iterable<int> expected,
}) {
  final wanted = expected.toSet();
  final lines = raw.replaceAll('\r\n', '\n').split('\n');
  final result = <int, String>{};
  for (final line in lines) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    final separator = trimmed.indexOf('||');
    if (separator <= 0) {
      throw SrtChunkFormatException('malformed line: $trimmed');
    }
    final idText = trimmed.substring(0, separator).trim();
    final id = int.tryParse(idText);
    if (id == null) {
      throw SrtChunkFormatException('non numeric cue id: $idText');
    }
    if (!wanted.contains(id)) {
      throw SrtChunkFormatException('unexpected cue id: $id');
    }
    final text = trimmed.substring(separator + 2).trim();
    if (text.isEmpty) {
      throw SrtChunkFormatException('empty translation for $id');
    }
    if (result.containsKey(id)) {
      throw SrtChunkFormatException('duplicate cue id: $id');
    }
    result[id] = text;
  }
  final missing = wanted.where((id) => !result.containsKey(id)).toList()
    ..sort();
  if (missing.isNotEmpty) {
    throw SrtChunkFormatException('missing cue ids: $missing');
  }
  return result;
}
