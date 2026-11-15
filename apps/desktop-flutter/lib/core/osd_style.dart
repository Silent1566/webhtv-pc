/// 屏显（OSD）样式的落盘模型（`docs/reference/potplayer-checklist.md` P1-4）。
///
/// 纯数据 + 校验：不依赖 Flutter、不碰磁盘。只保留两个真正有渲染行为的字段：
/// - [textScale]：字号缩放（屏显正文 14dp、诊断面板 10dp 同比例放大）；
/// - [opacity]：整层不透明度（背景是任意视频帧，压淡是为了不挡画面）。
///
/// 上游依据：PotPlayer 240618「Added the ability to set the font for OSD
/// playback information」（B 级，官方更新日志原文）。
///
/// **默认值必须等于今天**：100% 字号、100% 不透明（`ui/player_osd.dart`
/// 原本写死 `fontSize: 14`）。
library;

/// 屏显样式。
class OsdStyle {
  const OsdStyle({this.textScale = 1, this.opacity = 1});

  /// 与既有实现完全等价的默认值。
  static const OsdStyle defaults = OsdStyle();

  /// 合法区间：字号再小就看不清（14dp 基准），再大会糊住画面；
  /// 不透明度下限留 0.4，再低等于「开了跟没开一样」。
  static const double minTextScale = 0.8;
  static const double maxTextScale = 1.6;
  static const double minOpacity = 0.4;
  static const double maxOpacity = 1;

  /// 字号缩放（1 = 14dp 基准字号）。
  final double textScale;

  /// 整层不透明度（1 = 完全不透明）。
  final double opacity;

  /// 夹到合法区间；非有限值回落默认。
  OsdStyle normalized() => OsdStyle(
    textScale: _clamp(textScale, minTextScale, maxTextScale, 1),
    opacity: _clamp(opacity, minOpacity, maxOpacity, 1),
  );

  OsdStyle copyWith({double? textScale, double? opacity}) => OsdStyle(
    textScale: textScale ?? this.textScale,
    opacity: opacity ?? this.opacity,
  ).normalized();

  Map<String, Object?> toJson() => <String, Object?>{
    'textScale': textScale,
    'opacity': opacity,
  };

  /// 宽松解析：缺失/类型不对回落默认，越界按 [normalized] 夹取。
  factory OsdStyle.fromJson(Object? raw) {
    final map = raw is Map ? raw : const {};
    double doubleOf(String key, double fallback) {
      final value = map[key];
      return value is num && value.isFinite ? value.toDouble() : fallback;
    }

    const fallback = OsdStyle.defaults;
    return OsdStyle(
      textScale: doubleOf('textScale', fallback.textScale),
      opacity: doubleOf('opacity', fallback.opacity),
    ).normalized();
  }

  /// 是否为默认值：偏好存储据此决定「不写盘」。
  bool get isDefault => this == defaults;

  @override
  bool operator ==(Object other) =>
      other is OsdStyle &&
      other.textScale == textScale &&
      other.opacity == opacity;

  @override
  int get hashCode => Object.hash(textScale, opacity);

  @override
  String toString() => 'OsdStyle(scale=$textScale, opacity=$opacity)';
}

double _clamp(double value, double min, double max, double fallback) =>
    value.isFinite ? value.clamp(min, max).toDouble() : fallback;
