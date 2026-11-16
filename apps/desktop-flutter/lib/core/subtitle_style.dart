/// 字幕显示样式的落盘模型（`docs/reference/potplayer-checklist.md` P1-4）。
///
/// 纯数据 + 校验：不依赖 Flutter、不碰磁盘。字段与播放器页「字幕样式」面板
/// 一一对应（字号 / 描边 / 位置 / 底色不透明度 / 文字颜色），渲染层把本模型
/// 翻译成 media-kit 的 `SubtitleViewConfiguration`（见 `ui/player_page.dart`
/// 的 `SubtitleStyleView`）。
///
/// **颜色为什么是 int**：core 必须能脱离 Flutter 单测（同 `core/danmaku_style.dart`
/// 的口径），所以存 0xAARRGGBB，而不是 `Color`。
///
/// **默认值必须等于 Phase 3–8 的表现**：白字、全透明底、2px 描边、100% 字号、
/// 底部 24dp。改默认值等于静默改变既有手感，不是本模型该做的事。
library;

/// 字幕显示样式。
class SubtitleStyle {
  const SubtitleStyle({
    this.textColorValue = defaultTextColorValue,
    this.backgroundOpacity = 0,
    this.outlineWidth = 2,
    this.textScale = 1,
    this.bottomPadding = 24,
  });

  /// 与 Phase 3–8 完全等价的默认值。
  static const SubtitleStyle defaults = SubtitleStyle();

  /// 默认文字色：白（`Colors.white` 的 ARGB）。
  static const int defaultTextColorValue = 0xFFFFFFFF;

  /// 合法区间：与播放器页底部弹层的 slider 上下限一致。
  ///
  /// 两处必须同源：弹层允许拖到的值，`normalized()` 不能再夹一次，
  /// 否则会出现「拖到头却落盘成别的值」。
  static const double minTextScale = 0.6;
  static const double maxTextScale = 1.8;
  static const double minOutlineWidth = 0;
  static const double maxOutlineWidth = 4;
  static const double minBottomPadding = 0;
  static const double maxBottomPadding = 120;
  static const double minBackgroundOpacity = 0;
  static const double maxBackgroundOpacity = 0.8;

  /// 文字颜色（0xAARRGGBB）。
  ///
  /// 底色固定黑色，只让不透明度可调：整块彩色底框会把字幕变成「色带」，
  /// 与「去掉黑框」的产品意图相反。
  final int textColorValue;

  /// 底色不透明度（0 = 全透明）。
  final double backgroundOpacity;

  /// 描边宽度（0 = 无描边）。
  final double outlineWidth;

  /// 字号缩放（1 = 32dp 基准字号）。
  final double textScale;

  /// 字幕距画面底边的内边距（dp）。
  final double bottomPadding;

  /// 夹到合法区间；非有限值回落默认。
  SubtitleStyle normalized() => SubtitleStyle(
    textColorValue: textColorValue & 0xFFFFFFFF,
    backgroundOpacity: _clamp(
      backgroundOpacity,
      minBackgroundOpacity,
      maxBackgroundOpacity,
      defaults.backgroundOpacity,
    ),
    outlineWidth: _clamp(
      outlineWidth,
      minOutlineWidth,
      maxOutlineWidth,
      defaults.outlineWidth,
    ),
    textScale: _clamp(
      textScale,
      minTextScale,
      maxTextScale,
      defaults.textScale,
    ),
    bottomPadding: _clamp(
      bottomPadding,
      minBottomPadding,
      maxBottomPadding,
      defaults.bottomPadding,
    ),
  );

  SubtitleStyle copyWith({
    int? textColorValue,
    double? backgroundOpacity,
    double? outlineWidth,
    double? textScale,
    double? bottomPadding,
  }) => SubtitleStyle(
    textColorValue: textColorValue ?? this.textColorValue,
    backgroundOpacity: backgroundOpacity ?? this.backgroundOpacity,
    outlineWidth: outlineWidth ?? this.outlineWidth,
    textScale: textScale ?? this.textScale,
    bottomPadding: bottomPadding ?? this.bottomPadding,
  ).normalized();

  Map<String, Object?> toJson() => <String, Object?>{
    'textColorValue': textColorValue,
    'backgroundOpacity': backgroundOpacity,
    'outlineWidth': outlineWidth,
    'textScale': textScale,
    'bottomPadding': bottomPadding,
  };

  /// 宽松解析：缺失/类型不对回落默认，越界按 [normalized] 夹取，
  /// **不抛异常**（设置文件可能被手改）。
  factory SubtitleStyle.fromJson(Object? raw) {
    final map = raw is Map ? raw : const {};
    int intOf(String key, int fallback) {
      final value = map[key];
      return value is num ? value.toInt() : fallback;
    }

    double doubleOf(String key, double fallback) {
      final value = map[key];
      return value is num && value.isFinite ? value.toDouble() : fallback;
    }

    const fallback = SubtitleStyle.defaults;
    return SubtitleStyle(
      textColorValue: intOf('textColorValue', fallback.textColorValue),
      backgroundOpacity: doubleOf(
        'backgroundOpacity',
        fallback.backgroundOpacity,
      ),
      outlineWidth: doubleOf('outlineWidth', fallback.outlineWidth),
      textScale: doubleOf('textScale', fallback.textScale),
      bottomPadding: doubleOf('bottomPadding', fallback.bottomPadding),
    ).normalized();
  }

  /// 是否为默认值：偏好存储据此决定「不写盘」，避免把默认值固化进设置文件。
  bool get isDefault => this == defaults;

  @override
  bool operator ==(Object other) =>
      other is SubtitleStyle &&
      other.textColorValue == textColorValue &&
      other.backgroundOpacity == backgroundOpacity &&
      other.outlineWidth == outlineWidth &&
      other.textScale == textScale &&
      other.bottomPadding == bottomPadding;

  @override
  int get hashCode => Object.hash(
    textColorValue,
    backgroundOpacity,
    outlineWidth,
    textScale,
    bottomPadding,
  );

  @override
  String toString() =>
      'SubtitleStyle(color=0x${textColorValue.toRadixString(16)}, '
      'bg=$backgroundOpacity, outline=$outlineWidth, '
      'scale=$textScale, bottom=$bottomPadding)';
}

/// 非有限值（NaN/Infinity）没有「夹」的意义，直接回落默认。
double _clamp(double value, double min, double max, double fallback) =>
    value.isFinite ? value.clamp(min, max).toDouble() : fallback;
