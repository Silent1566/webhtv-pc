/// 弹幕库设置（`docs/phase9/design/02` §2）。
///
/// 默认关闭：未配置地址时不发任何请求，行为与 Phase 3–8 一致。
library;

class DanmakuSettings {
  const DanmakuSettings({this.autoSearch = false, this.apiUrl = ''});

  const DanmakuSettings.defaults() : this();

  /// 播放结果没有弹幕时是否自动搜索弹幕库。
  final bool autoSearch;

  /// 弹幕库搜索地址；空表示未配置。
  final String apiUrl;

  bool get hasLibrary => apiUrl.trim().isNotEmpty;

  bool get isEnabled => autoSearch && hasLibrary;

  DanmakuSettings copyWith({bool? autoSearch, String? apiUrl}) =>
      DanmakuSettings(
        autoSearch: autoSearch ?? this.autoSearch,
        apiUrl: apiUrl ?? this.apiUrl,
      );

  Map<String, Object?> toJson() => <String, Object?>{
    'autoSearch': autoSearch,
    if (apiUrl.trim().isNotEmpty) 'apiUrl': apiUrl.trim(),
  };

  factory DanmakuSettings.fromJson(Object? raw) {
    final map = raw is Map ? raw : const {};
    return DanmakuSettings(
      autoSearch: map['autoSearch'] is bool
          ? map['autoSearch'] as bool
          : false,
      apiUrl: map['apiUrl'] is String ? (map['apiUrl'] as String).trim() : '',
    );
  }

  @override
  bool operator ==(Object other) =>
      other is DanmakuSettings &&
      other.autoSearch == autoSearch &&
      other.apiUrl == apiUrl;

  @override
  int get hashCode => Object.hash(autoSearch, apiUrl);

  @override
  String toString() => 'DanmakuSettings(auto=$autoSearch, api="$apiUrl")';
}
