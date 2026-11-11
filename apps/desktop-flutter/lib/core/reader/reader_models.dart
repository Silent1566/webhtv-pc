import 'dart:typed_data';

enum TtsSource { system, edge, baidu, custom }

enum ReaderTtsState { playing, paused, stopped, error }

class TtsVoice {
  const TtsVoice(this.id, this.name, this.language);
  final String id;
  final String name;
  final String language;
}

class TtsOptions {
  TtsOptions({double rate = 1, double pitch = 1, this.voice = ''})
    : rate = _clamp(rate, .5, 2),
      pitch = _clamp(pitch, .5, 1.5);
  final double rate;
  final double pitch;
  final String voice;
  static double _clamp(double value, double min, double max) =>
      (!value.isFinite || value <= 0 ? 1.0 : value).clamp(min, max);
  TtsOptions copyWith({double? rate, double? pitch, String? voice}) =>
      TtsOptions(
        rate: rate ?? this.rate,
        pitch: pitch ?? this.pitch,
        voice: voice ?? this.voice,
      );
  String get pitchHz {
    final n = ((pitch - 1) * 100).round();
    return '${n >= 0 ? '+' : ''}${n}Hz';
  }

  String get ratePercent {
    final n = ((rate - 1) * 100).round();
    return '${n >= 0 ? '+' : ''}$n%';
  }

  Map<String, Object?> toJson() => {
    'rate': rate,
    'pitch': pitch,
    'voice': voice,
  };
}

class TtsCustomConfig {
  const TtsCustomConfig({
    this.name = '',
    required this.url,
    this.contentType = 'audio/mpeg',
    this.header = '',
  });
  final String name;
  final String url;
  final String contentType;
  final String header;
  factory TtsCustomConfig.fromJson(Map<String, dynamic> json) =>
      TtsCustomConfig(
        name: json['name'] as String? ?? '',
        url: json['url'] as String? ?? '',
        contentType: json['contentType'] as String? ?? 'audio/mpeg',
        header: json['header'] as String? ?? '',
      );
  Map<String, Object?> toJson() => {
    'name': name,
    'url': url,
    'contentType': contentType,
    'header': header,
  };
}

class ReaderPreferences {
  ReaderPreferences({
    this.source = TtsSource.system,
    TtsOptions? options,
    int timerMinutes = 0,
    this.custom,
  }) : options = options ?? TtsOptions(),
       timerMinutes = timerMinutes.clamp(0, 600);
  final TtsSource source;
  final TtsOptions options;
  final int timerMinutes;
  final TtsCustomConfig? custom;
  ReaderPreferences copyWith({
    TtsSource? source,
    TtsOptions? options,
    int? timerMinutes,
    TtsCustomConfig? custom,
  }) => ReaderPreferences(
    source: source ?? this.source,
    options: options ?? this.options,
    timerMinutes: timerMinutes ?? this.timerMinutes,
    custom: custom ?? this.custom,
  );
  Map<String, Object?> toJson() => {
    'source': source.name,
    ...options.toJson(),
    'timer': timerMinutes,
    'custom': custom?.toJson(),
  };
  factory ReaderPreferences.fromJson(Map<String, dynamic> json) =>
      ReaderPreferences(
        source:
            TtsSource.values
                .where((s) => s.name == json['source'])
                .firstOrNull ??
            TtsSource.system,
        options: TtsOptions(
          rate: (json['rate'] as num?)?.toDouble() ?? 1,
          pitch: (json['pitch'] as num?)?.toDouble() ?? 1,
          voice: json['voice'] as String? ?? '',
        ),
        timerMinutes: (json['timer'] as num?)?.toInt() ?? 0,
        custom: json['custom'] is Map<String, dynamic>
            ? TtsCustomConfig.fromJson(json['custom'] as Map<String, dynamic>)
            : null,
      );
}

class TtsAudio {
  TtsAudio(this.bytes, this.extension);
  final Uint8List bytes;
  final String extension;
}

class TtsChunk {
  const TtsChunk(this.text, this.paragraph);
  final String text;
  final int paragraph;
}

List<TtsChunk> splitTtsText(List<String> paragraphs, {required bool online}) {
  final chunks = <TtsChunk>[];
  for (var index = 0; index < paragraphs.length; index++) {
    final text = paragraphs[index]
        .replaceAll(RegExp(r'[\r\t\u00a0\u3000]'), ' ')
        .replaceAll(RegExp(r'[\x00-\x09\x0b-\x1f]'), '')
        .trim();
    final parts = online
        ? RegExp(r'[^。！？!?；;…\n]+[。！？!?；;…\n]*')
              .allMatches(text)
              .map((m) => m.group(0)!)
        : [text];
    for (final part in parts) {
      var remaining = part;
      while (remaining.isNotEmpty) {
        var end = online && remaining.length > 160 ? 160 : remaining.length;
        if (online && end == 160) {
          final prefix = remaining.substring(0, 160);
          final breaks = RegExp(r'[，,、：:]').allMatches(prefix).toList();
          if (breaks.isNotEmpty && breaks.last.end >= 80) end = breaks.last.end;
        }
        if (end > 0 &&
            end < remaining.length &&
            remaining.codeUnitAt(end - 1) >= 0xd800 &&
            remaining.codeUnitAt(end - 1) <= 0xdbff &&
            remaining.codeUnitAt(end) >= 0xdc00 &&
            remaining.codeUnitAt(end) <= 0xdfff) {
          end--;
        }
        final chunk = remaining.substring(0, end).trim();
        remaining = remaining.substring(end);
        if (RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(chunk)) {
          chunks.add(TtsChunk(chunk, index));
        }
      }
    }
  }
  return chunks;
}
