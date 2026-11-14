/// DoH 用户设置（Phase 9 · P2-8）。
///
/// 存在 `settings.json` 顶层 `doh` 段（与安卓 pref 键 `doh` 同名）：
/// `{enabled, url, cacheMinutes}`。缺席 = 关闭 = 行为与 Phase 0–8 一致。
///
/// 与配置文件的 `doh` 是两件事：配置提供**服务商列表**，这里存**用户的选择**
/// （是否启用、自定义端点、缓存时长）。自定义端点优先于配置里的第一个服务商。
library;

class DohSettings {
  const DohSettings({
    this.enabled = false,
    this.url = '',
    this.cacheMinutes = 60,
  });

  static const DohSettings defaults = DohSettings();

  /// 最短缓存时长（分钟）：太小会让每个请求都打 DoH。
  static const int minCacheMinutes = 1;

  /// 最长缓存时长（分钟）：太大则 DNS 变更迟迟不生效。
  static const int maxCacheMinutes = 1440;

  final bool enabled;

  /// 自定义 DoH 端点；空表示用配置里的第一个有效服务商。
  final String url;

  final int cacheMinutes;

  bool get isDefault => this == defaults;

  /// 端点可用（必须是 https）。
  bool get hasCustomUrl => isUsableDohUrl(url);

  DohSettings copyWith({bool? enabled, String? url, int? cacheMinutes}) =>
      DohSettings(
        enabled: enabled ?? this.enabled,
        url: (url ?? this.url).trim(),
        cacheMinutes: _clampMinutes(cacheMinutes ?? this.cacheMinutes),
      );

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    if (url.trim().isNotEmpty) 'url': url.trim(),
    'cacheMinutes': cacheMinutes,
  };

  factory DohSettings.fromJson(Object? raw) {
    final map = raw is Map ? raw : const {};
    return DohSettings(
      enabled: map['enabled'] is bool ? map['enabled'] as bool : false,
      url: map['url'] is String ? (map['url'] as String).trim() : '',
      cacheMinutes: _clampMinutes(
        map['cacheMinutes'] is num
            ? (map['cacheMinutes'] as num).toInt()
            : 60,
      ),
    );
  }

  static int _clampMinutes(int value) {
    if (value < minCacheMinutes) return minCacheMinutes;
    if (value > maxCacheMinutes) return maxCacheMinutes;
    return value;
  }

  @override
  bool operator ==(Object other) =>
      other is DohSettings &&
      other.enabled == enabled &&
      other.url == url &&
      other.cacheMinutes == cacheMinutes;

  @override
  int get hashCode => Object.hash(enabled, url, cacheMinutes);

  @override
  String toString() =>
      'DohSettings(enabled=$enabled, url="${redactDohUrl(url)}", '
      'cache=$cacheMinutes)';
}

/// DoH 端点是否可用（只接受 https；http 明文 DoH 不叫 DoH）。
bool isUsableDohUrl(String url) {
  final text = url.trim();
  if (!text.startsWith('https://')) return false;
  final parsed = Uri.tryParse(text);
  return parsed != null && parsed.host.isNotEmpty;
}

/// 日志/证据里只保留 host，避免把带 token 的查询串写进日志。
String redactDohUrl(String url) {
  final parsed = Uri.tryParse(url.trim());
  if (parsed == null || parsed.host.isEmpty) return '';
  return '${parsed.scheme}://${parsed.host}${parsed.path}';
}
