import 'models.dart';

class UltraStarParser {
  static KaraokeTrack parseStrict(String text) {
    double? bpm;
    double? gap;
    const max = 2147483647;
    for (final raw in text.replaceAll('\r', '').split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#')) {
        final colon = line.indexOf(':');
        if (colon < 0) continue;
        final key = line.substring(1, colon).trim().toUpperCase();
        if (key != 'BPM' && key != 'GAP') continue;
        final value = double.tryParse(
          line.substring(colon + 1).trim().replaceAll(',', '.'),
        );
        if (value == null ||
            !value.isFinite ||
            (key == 'BPM' && value <= 0) ||
            (key == 'GAP' && value.abs() > max))
          throw FormatException('invalid $key');
        if (key == 'BPM')
          bpm = value;
        else
          gap = value;
      } else if (KaraokeNoteType.values.any((n) => n.prefix == line[0])) {
        final parts = line.substring(1).trim().split(RegExp(r'\s+'));
        if (parts.length < 3 || bpm == null || gap == null)
          throw const FormatException('invalid note timing');
        final values = parts.take(3).map(int.tryParse).toList();
        if (values.any((v) => v == null || v.abs() > max) || values[1]! <= 0)
          throw const FormatException('invalid note numbers');
        final start = gap + values[0]! * 60000 / bpm;
        final end = gap + (values[0]! + values[1]!) * 60000 / bpm;
        if (!start.isFinite ||
            !end.isFinite ||
            end < start ||
            end > max)
          throw const FormatException('note time out of range');
      }
    }
    if (bpm == null || gap == null)
      throw const FormatException('missing timing');
    return parse(text);
  }

  static bool looksLikeUltraStar(String text) {
    final upper = text.toUpperCase();
    return upper.contains('#BPM:') &&
        upper.contains('#GAP:') &&
        text.split('\n').any((l) {
          final t = l.trim();
          return t.length > 2 &&
              KaraokeNoteType.values.any((type) => type.prefix == t[0]);
        });
  }

  static KaraokeTrack parse(String text) {
    var title = '', artist = '';
    var bpm = 0.0;
    var gap = 0;
    var lineIndex = 0;
    var sawNote = false;
    final notes = <KaraokeNote>[];
    for (final raw in text.replaceAll('\r', '').split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (line[0] == '#') {
        final index = line.indexOf(':');
        if (index <= 1) continue;
        final key = line.substring(1, index).trim().toUpperCase();
        final value = line.substring(index + 1).trim();
        if (key == 'TITLE')
          title = value;
        else if (key == 'ARTIST')
          artist = value;
        else if (key == 'BPM')
          bpm = double.tryParse(value.replaceAll(',', '.')) ?? bpm;
        else if (key == 'GAP')
          gap = (double.tryParse(value.replaceAll(',', '.')) ?? gap).round();
        continue;
      }
      if (line[0] == '-') {
        if (notes.isNotEmpty) lineIndex++;
        continue;
      }
      if (line[0] == 'E') continue;
      final type = KaraokeNoteType.values
          .where((t) => t.prefix == line[0])
          .firstOrNull;
      if (type == null) continue;
      final parts = line.substring(1).trim().split(RegExp(r'\s+'));
      if (parts.length < 3) continue;
      final startBeat = int.tryParse(parts[0]) ?? 0;
      final lengthBeat = int.tryParse(parts[1]) ?? 0;
      final pitch = int.tryParse(parts[2]) ?? 0;
      if (lengthBeat <= 0 || bpm < 1) continue;
      int beatToMs(int beat) =>
          (gap + beat * 60000 / bpm).round().clamp(0, 1 << 31);
      notes.add(
        KaraokeNote(
          startMs: beatToMs(startBeat),
          endMs: beatToMs(startBeat + lengthBeat),
          pitch: pitch,
          startBeat: startBeat,
          lengthBeat: lengthBeat,
          text: parts.length >= 4 ? parts.sublist(3).join(' ') : '',
          type: type,
          lineIndex: lineIndex,
        ),
      );
      sawNote = true;
    }
    if (!sawNote) lineIndex = 0;
    return KaraokeTrack(
      title: title,
      artist: artist,
      bpm: bpm,
      gapMs: gap,
      notes: notes,
    );
  }
}
