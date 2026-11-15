/// 字幕源设置（`docs/phase9/design/02` §3、`docs/superpowers/plans/2026-11-15-subtitle-online-search.md`）。
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
    this.assrtToken = '',
    this.xunleiEnabled = false,
    this.shooterEnabled = false,
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

  /// 本地字幕目录（递归两层）。
  final List<String> localDirectories;

  /// ASSRT 令牌（可选，**不得进日志**）；空 = 该源不启用。
  ///
  /// 与安卓 `AssrtSubtitleProvider.isEnabled()` 同语义：没有 token 就没有
  /// 该源，而不是「有源但永远 401」。
  final String assrtToken;

  /// 迅雷字幕源开关（免 token，按片名搜索）。
  final bool xunleiEnabled;

  /// 射手字幕源开关。
  ///
  /// 只在本地文件播放时有输入（按文件哈希搜索），网络流播放恒无结果；
  /// UI 必须写明这一点，否则看起来像源坏了。
  final bool shooterEnabled;

  bool get hasHttpProvider => httpEndpoint.trim().isNotEmpty;

  bool get hasLocalProvider => localDirectories.any((dir) => dir.trim().isNotEmpty);

  bool get hasAssrt => assrtToken.trim().isNotEmpty;

  bool get hasXunlei => xunleiEnabled;

  bool get hasShooter => shooterEnabled;

  bool get hasAnyProvider =>
      hasHttpProvider || hasLocalProvider || hasAssrt || hasXunlei || hasShooter;

  bool get isEnabled => autoMatch && hasAnyProvider;

  /// 未启用的源 id，按注册顺序；用于「说真话」的空态。
  List<String> get disabledSourceIds => [
    if (!hasLocalProvider) 'local',
    if (!hasHttpProvider) 'http',
    if (!hasAssrt) 'assrt',
    if (!hasXunlei) 'xunlei',
    if (!hasShooter) 'shooter',
  ];

  SubtitleSettings copyWith({
    bool? autoMatch,
    List<String>? preferredLanguages,
    String? httpEndpoint,
    String? httpToken,
    List<String>? localDirectories,
    String? assrtToken,
    bool? xunleiEnabled,
    bool? shooterEnabled,
  }) => SubtitleSettings(
    autoMatch: autoMatch ?? this.autoMatch,
    preferredLanguages: preferredLanguages ?? this.preferredLanguages,
    httpEndpoint: httpEndpoint ?? this.httpEndpoint,
    httpToken: httpToken ?? this.httpToken,
    localDirectories: localDirectories ?? this.localDirectories,
    assrtToken: assrtToken ?? this.assrtToken,
    xunleiEnabled: xunleiEnabled ?? this.xunleiEnabled,
    shooterEnabled: shooterEnabled ?? this.shooterEnabled,
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
    if (assrtToken.trim().isNotEmpty) 'assrtToken': assrtToken.trim(),
    if (xunleiEnabled) 'xunleiEnabled': true,
    if (shooterEnabled) 'shooterEnabled': true,
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
      assrtToken: map['assrtToken'] is String
          ? (map['assrtToken'] as String).trim()
          : '',
      xunleiEnabled: boolOf('xunleiEnabled', false),
      shooterEnabled: boolOf('shooterEnabled', false),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SubtitleSettings &&
      other.autoMatch == autoMatch &&
      _listEquals(other.preferredLanguages, preferredLanguages) &&
      other.httpEndpoint == httpEndpoint &&
      other.httpToken == httpToken &&
      _listEquals(other.localDirectories, localDirectories) &&
      other.assrtToken == assrtToken &&
      other.xunleiEnabled == xunleiEnabled &&
      other.shooterEnabled == shooterEnabled;

  @override
  int get hashCode => Object.hash(
    autoMatch,
    Object.hashAll(preferredLanguages),
    httpEndpoint,
    httpToken,
    Object.hashAll(localDirectories),
    assrtToken,
    xunleiEnabled,
    shooterEnabled,
  );

  static bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
