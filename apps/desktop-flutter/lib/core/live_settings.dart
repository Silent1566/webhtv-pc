/// 直播行为设置（`docs/phase9/design/03` §5）。
///
/// 只包含桌面端有明确语义的项：
/// - `sourceFallback`：当前源所有线路都失败时，尝试其他直播源的同名频道；
/// - `changeLine`：当前线路失败自动换线（Phase 3 起是硬编码开启，这里暴露开关）。
///
/// **不迁移**安卓的列表皮肤与手势反转：桌面有自己的设计系统与输入模型。
library;

class LiveSettings {
  const LiveSettings({
    this.sourceFallback = true,
    this.changeLine = true,
  });

  const LiveSettings.defaults() : this();

  /// 源级失败回退。
  final bool sourceFallback;

  /// 线路失败自动换线。
  final bool changeLine;

  LiveSettings copyWith({
    bool? sourceFallback,
    bool? changeLine,
  }) => LiveSettings(
    sourceFallback: sourceFallback ?? this.sourceFallback,
    changeLine: changeLine ?? this.changeLine,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'sourceFallback': sourceFallback,
    'changeLine': changeLine,
  };

  /// 宽松解析：缺失/非法字段回落默认（默认与 Phase 0–8 行为一致）。
  factory LiveSettings.fromJson(Object? raw) {
    final map = raw is Map ? raw : const {};
    bool boolOf(String key, bool fallback) {
      final value = map[key];
      return value is bool ? value : fallback;
    }

    return LiveSettings(
      sourceFallback: boolOf('sourceFallback', true),
      changeLine: boolOf('changeLine', true),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is LiveSettings &&
      other.sourceFallback == sourceFallback &&
      other.changeLine == changeLine;

  @override
  int get hashCode => Object.hash(sourceFallback, changeLine);

  @override
  String toString() =>
      'LiveSettings(fallback=$sourceFallback changeLine=$changeLine)';
}
