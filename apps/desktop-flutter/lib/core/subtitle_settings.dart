/// 字幕源设置（`docs/phase9/design/02` §3）。
///
/// 默认**全部关闭**：不配置就不发任何外部请求，行为与 Phase 3–8 一致。
library;

import 'subtitle_provider.dart' show kDefaultSubtitleLanguages;

class SubtitleSettings {
  SubtitleSettings({
    this.autoMatch = false,
    List<String>? preferredLanguages,
    this.httpEndpoint = '',
    this.httpToken = '',
    List<String>? localDirectories,
  }) : preferredLanguages = List.unmodifiable(
         preferredLanguages ?? kDefaultSubtitleLanguages,
       ),
       localDirectories = List.unmodifiable(localDirectories ?? const []);

  /// 播放结果没有字幕时是否自动匹配。
  final bool autoMatch;

  /// 语言优先级（越靠前越优先）。
  final List<String> preferredLanguages;

  /// 通用 HTTP 字幕源的搜索地址；空表示未配置。
  final String httpEndpoint;

  /// HTTP 源令牌（可选，**不得进日志**）。
  final String httpToken;

  /// 本地字幕目录（递归深度 2）。
  final List<String> localDirectories;

  bool get hasHttpProvider => httpEndpoint.trim().isNotEmpty;

  bool get hasLocalProvider => localDirectories.any((dir) => dir.trim().isNotEmpty);

  bool get hasAnyProvider => hasHttpProvider || hasLocalProvider;

  bool get isEnabled => autoMatch && hasAnyProvider;

  SubtitleSettings copyWith({
    bool? autoMatch,
    List<String>? preferredLanguages,
    String? httpEndpoint,
    String? httpToken,
    List<String>? localDirectories,
  }) => SubtitleSettings(
    autoMatch: autoMatch ?? this.autoMatch,
    preferredLanguages: preferredLanguages ?? this.preferredLanguages,
    httpEndpoint: httpEndpoint ?? this.httpEndpoint,
    httpToken: httpToken ?? this.httpToken,
    localDirectories: localDirectories ?? this.localDirectories,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'autoMatch': autoMatch,
    'preferredLanguages': preferredLanguages,
    if (httpEndpoint.trim().isNotEmpty) 'httpEndpoint': httpEndpoint.trim(),
    if (httpToken.trim().isNotEmpty) 'httpToken': httpToken.trim(),
    if (localDirectories.isNotEmpty)
      'localDirectories': [
        for (final dir in localDirectories)
          if (dir.trim().isNotEmpty) dir.trim(),
      ],
  };

  factory SubtitleSettings.fromJson(Object? raw) {
    final map = raw is Map ? raw : const {};
    bool boolOf(String key, bool fallback) {
      final value = map[key];
      return value is bool ? value : fallback;
    }

    final languages = <String>[];
    final rawLanguages = map['preferredLanguages'];
    if (rawLanguages is List) {
      for (final item in rawLanguages) {
        if (item is String && item.trim().isNotEmpty) {
          languages.add(item.trim());
        }
      }
    }

    final directories = <String>[];
    final rawDirs = map['localDirectories'];
    if (rawDirs is List) {
      for (final item in rawDirs) {
        if (item is String && item.trim().isNotEmpty) {
          directories.add(item.trim());
        }
      }
    }

    return SubtitleSettings(
      autoMatch: boolOf('autoMatch', false),
      preferredLanguages: languages.isEmpty
          ? kDefaultSubtitleLanguages
          : languages,
      httpEndpoint: map['httpEndpoint'] is String
          ? (map['httpEndpoint'] as String).trim()
          : '',
      httpToken: map['httpToken'] is String
          ? (map['httpToken'] as String).trim()
          : '',
      localDirectories: directories,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SubtitleSettings &&
      other.autoMatch == autoMatch &&
      _listEquals(other.preferredLanguages, preferredLanguages) &&
      other.httpEndpoint == httpEndpoint &&
      other.httpToken == httpToken &&
      _listEquals(other.localDirectories, localDirectories);

  @override
  int get hashCode => Object.hash(
    autoMatch,
    Object.hashAll(preferredLanguages),
    httpEndpoint,
    httpToken,
    Object.hashAll(localDirectories),
  );

  static bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
