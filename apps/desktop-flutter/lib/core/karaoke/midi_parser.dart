/// 标准 MIDI → UltraStar 文本（源 `MidiKaraokeParser`）。
///
/// 0 tick 起算，tempo 事件取首个非默认值，按每拍 10ms（BPM 6000）折算，
/// 与 Task2 生成轨的 beat 约定一致，便于同一评分器消费。
class MidiKaraokeParser {
  static const int _defaultTempoUs = 500000;
  static const int _maxNotes = 4000;

  static bool looksLikeMidi(List<int> data) =>
      data.length >= 14 &&
      data[0] == 0x4d &&
      data[1] == 0x54 &&
      data[2] == 0x68 &&
      data[3] == 0x64;

  static String toUltraStar(String name, List<int> data) {
    final reader = _Reader(data);
    reader.expect('MThd');
    final headerLength = reader.readInt();
    final headerEnd = reader.position + headerLength;
    if (headerLength < 6 || headerEnd > data.length)
      throw ArgumentError('bad MIDI header length');
    reader.readShort();
    final tracks = reader.readShort();
    final division = reader.readShort();
    reader.position = headerEnd;
    if (division <= 0 || (division & 0x8000) != 0)
      throw ArgumentError('unsupported midi timing');
    final parsed = <_TrackNotes>[];
    var tempoUs = _defaultTempoUs;
    for (var i = 0; i < tracks; i++) {
      reader.expect('MTrk');
      final length = reader.readInt();
      final track = _parseTrack(
        _Reader(reader.slice(reader.position, reader.position + length)),
      );
      reader.position = reader.position + length;
      if (track.tempoUs > 0 && tempoUs == _defaultTempoUs)
        tempoUs = track.tempoUs;
      if (track.notes.isNotEmpty) parsed.add(track);
    }
    if (parsed.isEmpty) throw ArgumentError('no midi notes');
    parsed.sort((a, b) => b.score.compareTo(a.score));
    final best = parsed.first;
    final beatMs = tempoUs / 1000.0 / division;
    final bpm = 60000.0 / beatMs;
    final title = name
        .split(RegExp(r'[\\/]'))
        .last
        .replaceAll(RegExp(r'\.[^.]*$'), '')
        .replaceAll(RegExp(r'[\r\n]'), ' ');
    final buffer = StringBuffer()
      ..writeln('#TITLE:$title')
      ..writeln('#ARTIST:')
      ..writeln('#BPM:${bpm.toStringAsFixed(3)}')
      ..writeln('#GAP:0');
    var count = 0;
    for (final note in best.notes) {
      if (++count > _maxNotes) break;
      if (note.startTick > 2147483647 ||
          note.endTick - note.startTick > 2147483647)
        continue;
      buffer.writeln(
        ': ${note.startTick} ${note.endTick - note.startTick} ${note.pitch}',
      );
    }
    buffer.writeln('E');
    return buffer.toString();
  }

  static _TrackNotes _parseTrack(_Reader reader) {
    final track = _TrackNotes();
    final open = <int, int>{};
    var tick = 0;
    var running = -1;
    while (reader.remaining > 0) {
      tick += reader.readVar();
      var status = reader.read();
      if (status < 0x80) {
        if (running < 0) throw ArgumentError('missing running status');
        reader.position = reader.position - 1;
        status = running;
      } else if (status < 0xf0) {
        running = status;
      }
      if (status == 0xff) {
        final type = reader.read();
        final length = reader.readVar();
        if (type == 0x51 && length == 3) {
          track.tempoUs =
              reader.read() * 65536 + reader.read() * 256 + reader.read();
        } else {
          reader.skip(length);
        }
        continue;
      }
      if (status == 0xf0 || status == 0xf7) {
        reader.skip(reader.readVar());
        continue;
      }
      if (status >= 0xf0) {
        reader.skip(_systemEventLength(status));
        continue;
      }
      final command = status & 0xf0;
      final channel = status & 0x0f;
      final p1 = reader.read();
      final p2 = command == 0xc0 || command == 0xd0 ? 0 : reader.read();
      if (channel == 9) continue;
      final key = channel * 128 + p1;
      if (command == 0x90 && p2 > 0) {
        open[key] = tick;
      } else if (command == 0x80 || command == 0x90) {
        final start = open.remove(key);
        if (start != null && tick > start)
          track.notes.add(_Note(start, tick, p1));
      }
    }
    return track;
  }

  static int _systemEventLength(int status) => switch (status) {
    0xf1 || 0xf3 => 1,
    0xf2 => 2,
    _ => 0,
  };
}

class _Note {
  _Note(this.startTick, this.endTick, this.pitch);
  final int startTick, endTick, pitch;
}

class _TrackNotes {
  final List<_Note> notes = [];
  var tempoUs = 0;
  double get score =>
      notes.where((n) => n.pitch >= 45 && n.pitch <= 84).length * 10.0 +
      notes.length +
      notes.fold<double>(0, (v, n) => v + (n.endTick - n.startTick)) / 1000;
}

class _Reader {
  _Reader(this.data);
  final List<int> data;
  var position = 0;
  int get remaining => data.length - position;
  void expect(String magic) {
    for (var i = 0; i < magic.length; i++) {
      if (read() != magic.codeUnitAt(i)) throw ArgumentError('bad magic');
    }
  }

  int read() {
    if (remaining <= 0) throw ArgumentError('unexpected end of midi');
    return data[position++];
  }

  int readShort() => read() * 256 + read();
  int readInt() => readShort() * 65536 + readShort();
  int readVar() {
    var value = 0;
    for (var i = 0; i < 4; i++) {
      final byte = read();
      value = (value << 7) | (byte & 0x7f);
      if (byte & 0x80 == 0) break;
    }
    return value;
  }

  void skip(int length) {
    if (length < 0) throw ArgumentError('negative skip');
    if (position + length > data.length)
      throw ArgumentError('truncated MIDI event');
    position += length;
  }

  List<int> slice(int start, int end) {
    if (start < 0 || end > data.length || end < start)
      throw ArgumentError('bad MIDI track length');
    return data.sublist(start, end);
  }
}
