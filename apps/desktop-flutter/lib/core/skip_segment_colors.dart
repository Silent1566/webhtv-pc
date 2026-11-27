/// Per-kind timeline colors, stored as opaque ARGB integers without Flutter.
library;

import 'skip_plan.dart';

class SkipSegmentColors {
  const SkipSegmentColors({
    this.recap = 0xFF22B8CF,
    this.intro = 0xFF38D9A9,
    this.outro = 0xFFA78BFA,
    this.preview = 0xFF4DABF7,
    this.postCredits = 0xFFF783AC,
    this.advertisement = 0xFFFF6B6B,
    this.intermission = 0xFFFFD43B,
  });

  final int recap;
  final int intro;
  final int outro;
  final int preview;
  final int postCredits;
  final int advertisement;
  final int intermission;

  static int _opaque(Object? value, int fallback) =>
      value is int && value >= 0xFF000000 && value <= 0xFFFFFFFF
      ? value
      : fallback;

  int colorFor(SkipKind kind) => switch (kind) {
    SkipKind.recap => _opaque(recap, 0xFF22B8CF),
    SkipKind.intro => _opaque(intro, 0xFF38D9A9),
    SkipKind.outro => _opaque(outro, 0xFFA78BFA),
    SkipKind.preview => _opaque(preview, 0xFF4DABF7),
    SkipKind.postCredits => _opaque(postCredits, 0xFFF783AC),
    SkipKind.advertisement => _opaque(advertisement, 0xFFFF6B6B),
    SkipKind.intermission => _opaque(intermission, 0xFFFFD43B),
  };

  SkipSegmentColors withColor(SkipKind kind, int argb) =>
      SkipSegmentColors.fromJson({...toJson(), kind.name: argb});

  SkipSegmentColors normalized() => SkipSegmentColors.fromJson(toJson());

  Map<String, int> toJson() => {
    for (final kind in SkipKind.values) kind.name: colorFor(kind),
  };

  factory SkipSegmentColors.fromJson(Object? raw) {
    final map = raw is Map ? raw : const {};
    const defaults = SkipSegmentColors();
    return SkipSegmentColors(
      recap: _opaque(map['recap'], defaults.recap),
      intro: _opaque(map['intro'], defaults.intro),
      outro: _opaque(map['outro'], defaults.outro),
      preview: _opaque(map['preview'], defaults.preview),
      postCredits: _opaque(map['postCredits'], defaults.postCredits),
      advertisement: _opaque(map['advertisement'], defaults.advertisement),
      intermission: _opaque(map['intermission'], defaults.intermission),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SkipSegmentColors &&
      SkipKind.values.every((kind) => colorFor(kind) == other.colorFor(kind));

  @override
  int get hashCode => Object.hashAll(SkipKind.values.map(colorFor));
}
