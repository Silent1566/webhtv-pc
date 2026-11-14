/// 弹幕显示设置（Phase 9 · P0-7 显示参数扩展）。
///
/// 从 `ui/danmaku_overlay.dart` 抽到 core：渲染层、播放器页与偏好存储都要用它，
/// 但 core 不能反向依赖 UI。旧的 `DanmakuStyle` 引用仍然可用
/// （`danmaku_overlay.dart` 继续 `export` 本文件）。
///
/// 语义对齐安卓 `setting/DanmakuSetting.java` 的显示项，但只保留 PC 端真正
/// 有渲染行为的字段：
/// - `scrollDurationMs`：滚动弹幕从进入到离开的时长（越小越快）；
/// - `fixedDurationMs`：顶部/底部弹幕的停留时长；
/// - `areaRatio`：滚动弹幕最多占画面的比例（防挡的核心手段）；
/// - `maxTracks`：最多占用几条轨道，0 表示只受 `areaRatio` 限制；
/// - `timeOffsetMs`：时间偏移，正数表示弹幕整体延后出现；
/// - `strokeWidth`：描边宽度，0 表示关闭描边。
library;

import 'dart:math' as math;

/// 弹幕显示设置。
class DanmakuStyle {
  const DanmakuStyle({
    this.enabled = true,
    this.opacity = 0.9,
    this.textScale = 1.0,
    this.showScroll = true,
    this.showTop = true,
    this.showBottom = true,
    this.strokeWidth = 1.2,
    this.scrollDurationMs = 8000,
    this.fixedDurationMs = 4000,
    this.areaRatio = 0.6,
    this.maxTracks = 0,
    this.timeOffsetMs = 0,
  });

  /// 与 Phase 3–8 完全等价的默认值（未知字段一律回落到这里）。
  static const DanmakuStyle defaults = DanmakuStyle();

  /// 总开关。
  final bool enabled;

  /// 整体不透明度（0.1..1）。
  final double opacity;

  /// 字号缩放（0.5..2.5）。
  final double textScale;

  final bool showScroll;
  final bool showTop;
  final bool showBottom;

  /// 描边宽度（0..3，0 = 关闭描边）。
  final double strokeWidth;

  /// 滚动弹幕时长（2000..20000 ms）。
  final int scrollDurationMs;

  /// 顶部/底部弹幕停留时长（1000..10000 ms）。
  final int fixedDurationMs;

  /// 滚动区域占画面高度的比例（0.2..0.9）。
  final double areaRatio;

  /// 最大轨道数（0..10，0 = 不限，只受 [areaRatio] 限制）。
  final int maxTracks;

  /// 时间偏移（-10000..10000 ms，正数＝弹幕延后）。
  final int timeOffsetMs;

  /// 作用在播放位置上的偏移后的毫秒数（永不为负）。
  ///
  /// 正偏移＝延后：同一播放位置下应该展示「更早」的弹幕，
  /// 因此用 `position - offset` 去查询弹幕时间轴。
  int offsetPositionMs(int positionMs) =>
      math.max(0, positionMs - timeOffsetMs);

  DanmakuStyle copyWith({
    bool? enabled,
    double? opacity,
    double? textScale,
    bool? showScroll,
    bool? showTop,
    bool? showBottom,
    double? strokeWidth,
    int? scrollDurationMs,
    int? fixedDurationMs,
    double? areaRatio,
    int? maxTracks,
    int? timeOffsetMs,
  }) {
    return DanmakuStyle(
      enabled: enabled ?? this.enabled,
      opacity: _clampDouble(opacity ?? this.opacity, 0.1, 1.0),
      textScale: _clampDouble(textScale ?? this.textScale, 0.5, 2.5),
      showScroll: showScroll ?? this.showScroll,
      showTop: showTop ?? this.showTop,
      showBottom: showBottom ?? this.showBottom,
      strokeWidth: _clampDouble(strokeWidth ?? this.strokeWidth, 0, 3),
      scrollDurationMs: _clampInt(
        scrollDurationMs ?? this.scrollDurationMs,
        2000,
        20000,
      ),
      fixedDurationMs: _clampInt(
        fixedDurationMs ?? this.fixedDurationMs,
        1000,
        10000,
      ),
      areaRatio: _clampDouble(areaRatio ?? this.areaRatio, 0.2, 0.9),
      maxTracks: _clampInt(maxTracks ?? this.maxTracks, 0, 10),
      timeOffsetMs: _clampInt(
        timeOffsetMs ?? this.timeOffsetMs,
        -10000,
        10000,
      ),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'enabled': enabled,
    'opacity': opacity,
    'textScale': textScale,
    'showScroll': showScroll,
    'showTop': showTop,
    'showBottom': showBottom,
    'strokeWidth': strokeWidth,
    'scrollDurationMs': scrollDurationMs,
    'fixedDurationMs': fixedDurationMs,
    'areaRatio': areaRatio,
    'maxTracks': maxTracks,
    'timeOffsetMs': timeOffsetMs,
  };

  /// 宽松解析：缺字段/类型不对回落到默认值；数值越界按 `copyWith` 的规则夹取。
  factory DanmakuStyle.fromJson(Object? raw) {
    final map = raw is Map ? raw : const {};
    bool readBool(String key, bool fallback) {
      final value = map[key];
      return value is bool ? value : fallback;
    }

    double readDouble(String key, double fallback) {
      final value = map[key];
      if (value is num) return value.toDouble();
      return fallback;
    }

    int readInt(String key, int fallback) {
      final value = map[key];
      if (value is num) return value.round();
      return fallback;
    }

    const defaults = DanmakuStyle.defaults;
    return DanmakuStyle.defaults.copyWith(
      enabled: readBool('enabled', defaults.enabled),
      opacity: readDouble('opacity', defaults.opacity),
      textScale: readDouble('textScale', defaults.textScale),
      showScroll: readBool('showScroll', defaults.showScroll),
      showTop: readBool('showTop', defaults.showTop),
      showBottom: readBool('showBottom', defaults.showBottom),
      strokeWidth: readDouble('strokeWidth', defaults.strokeWidth),
      scrollDurationMs: readInt(
        'scrollDurationMs',
        defaults.scrollDurationMs,
      ),
      fixedDurationMs: readInt('fixedDurationMs', defaults.fixedDurationMs),
      areaRatio: readDouble('areaRatio', defaults.areaRatio),
      maxTracks: readInt('maxTracks', defaults.maxTracks),
      timeOffsetMs: readInt('timeOffsetMs', defaults.timeOffsetMs),
    );
  }

  /// 是否为默认值（偏好存储据此决定是否写盘）。
  bool get isDefault => this == DanmakuStyle.defaults;

  @override
  bool operator ==(Object other) =>
      other is DanmakuStyle &&
      other.enabled == enabled &&
      other.opacity == opacity &&
      other.textScale == textScale &&
      other.showScroll == showScroll &&
      other.showTop == showTop &&
      other.showBottom == showBottom &&
      other.strokeWidth == strokeWidth &&
      other.scrollDurationMs == scrollDurationMs &&
      other.fixedDurationMs == fixedDurationMs &&
      other.areaRatio == areaRatio &&
      other.maxTracks == maxTracks &&
      other.timeOffsetMs == timeOffsetMs;

  @override
  int get hashCode => Object.hash(
    enabled,
    opacity,
    textScale,
    showScroll,
    showTop,
    showBottom,
    strokeWidth,
    scrollDurationMs,
    fixedDurationMs,
    areaRatio,
    maxTracks,
    timeOffsetMs,
  );

  @override
  String toString() =>
      'DanmakuStyle(enabled=$enabled, opacity=$opacity, '
      'textScale=$textScale, scroll=$scrollDurationMs, '
      'area=$areaRatio, tracks=$maxTracks, offset=$timeOffsetMs)';
}

double _clampDouble(double value, double min, double max) =>
    value.isNaN ? min : value.clamp(min, max).toDouble();

int _clampInt(int value, int min, int max) => value < min
    ? min
    : (value > max ? max : value);
