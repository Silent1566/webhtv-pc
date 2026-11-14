/// 出站代理（APP 代理，`docs/phase9/README.md` P1-9）。
///
/// 对齐安卓 `ProxySetting` 的语义：按**域名规则**把请求打到指定 HTTP 代理，
/// 未命中的走直连。安全约束：
/// - 默认关闭；关闭时不做任何代理（行为与 Phase 0–8 一致）；
/// - 只接受 `http://host:port` 形式（dart:io 的 `findProxy` 只支持 HTTP 代理）；
/// - 代理地址里的 userinfo 不写日志；
/// - **不影响本地回环代理**：那是播放通道，两者互不替代。
library;

/// 一条出站代理规则：命中 [patterns] 的域名走 [proxyUrl]。
class OutboundProxyRule {
  const OutboundProxyRule({required this.patterns, required this.proxyUrl});

  /// 域名模式：`example.com`（精确）、`*.example.com`（含子域）。
  final List<String> patterns;

  /// `http://127.0.0.1:7890`。
  final String proxyUrl;

  bool get isValid => patterns.isNotEmpty && proxyHostPort != null;

  /// 解析出的 `host:port`；非法返回 null。
  String? get proxyHostPort {
    final uri = Uri.tryParse(proxyUrl.trim());
    if (uri == null || uri.scheme != 'http' || uri.host.isEmpty) return null;
    final port = uri.hasPort ? uri.port : 80;
    if (port <= 0 || port > 65535) return null;
    return '${uri.host}:$port';
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'patterns': patterns,
    'proxyUrl': proxyUrl,
  };

  static OutboundProxyRule? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final rawPatterns = raw['patterns'];
    final patterns = <String>[];
    if (rawPatterns is List) {
      for (final item in rawPatterns) {
        if (item is String && item.trim().isNotEmpty) {
          patterns.add(item.trim().toLowerCase());
        }
      }
    }
    final proxyUrl = raw['proxyUrl'] is String
        ? (raw['proxyUrl'] as String).trim()
        : '';
    if (patterns.isEmpty || proxyUrl.isEmpty) return null;
    final rule = OutboundProxyRule(patterns: patterns, proxyUrl: proxyUrl);
    return rule.isValid ? rule : null;
  }

  @override
  bool operator ==(Object other) =>
      other is OutboundProxyRule &&
      other.proxyUrl == proxyUrl &&
      _listEquals(other.patterns, patterns);

  @override
  int get hashCode => Object.hash(proxyUrl, Object.hashAll(patterns));

  static bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  String toString() =>
      'OutboundProxyRule(${patterns.join(",")} → $proxyUrl)';
}

/// 出站代理设置。
class OutboundProxySettings {
  const OutboundProxySettings({
    this.enabled = false,
    this.defaultProxyUrl = '',
    this.rules = const [],
  });

  const OutboundProxySettings.defaults() : this();

  final bool enabled;

  /// 未命中任何规则时使用的代理；空表示直连。
  final String defaultProxyUrl;

  final List<OutboundProxyRule> rules;

  /// 实际生效的规则（过滤非法项）。
  List<OutboundProxyRule> get validRules =>
      [for (final rule in rules) if (rule.isValid) rule];

  String? get _defaultHostPort {
    final raw = defaultProxyUrl.trim();
    if (raw.isEmpty) return null;
    return OutboundProxyRule(patterns: const ['*'], proxyUrl: raw)
        .proxyHostPort;
  }

  bool get isEffective =>
      enabled && (_defaultHostPort != null || validRules.isNotEmpty);

  OutboundProxySettings copyWith({
    bool? enabled,
    String? defaultProxyUrl,
    List<OutboundProxyRule>? rules,
  }) => OutboundProxySettings(
    enabled: enabled ?? this.enabled,
    defaultProxyUrl: defaultProxyUrl ?? this.defaultProxyUrl,
    rules: rules ?? this.rules,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'enabled': enabled,
    if (defaultProxyUrl.trim().isNotEmpty)
      'defaultProxyUrl': defaultProxyUrl.trim(),
    if (rules.isNotEmpty)
      'rules': [for (final rule in rules) rule.toJson()],
  };

  factory OutboundProxySettings.fromJson(Object? raw) {
    final map = raw is Map ? raw : const {};
    final rawRules = map['rules'];
    final rules = <OutboundProxyRule>[];
    if (rawRules is List) {
      for (final item in rawRules) {
        final rule = OutboundProxyRule.fromJson(item);
        if (rule != null) rules.add(rule);
      }
    }
    return OutboundProxySettings(
      enabled: map['enabled'] is bool ? map['enabled'] as bool : false,
      defaultProxyUrl: map['defaultProxyUrl'] is String
          ? (map['defaultProxyUrl'] as String).trim()
          : '',
      rules: rules,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is OutboundProxySettings &&
      other.enabled == enabled &&
      other.defaultProxyUrl == defaultProxyUrl &&
      _listEquals(other.rules, rules);

  @override
  int get hashCode =>
      Object.hash(enabled, defaultProxyUrl, Object.hashAll(rules));

  static bool _listEquals(List<OutboundProxyRule> a, List<OutboundProxyRule> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  String toString() =>
      'OutboundProxySettings(enabled=$enabled, default="$defaultProxyUrl", '
      'rules=${rules.length})';
}

/// 域名是否命中规则模式。
///
/// 支持：`example.com`（精确或子域）、`*.example.com`（含子域）。
bool outboundProxyMatches(String host, String pattern) {
  final target = host.trim().toLowerCase();
  var value = pattern.trim().toLowerCase();
  if (target.isEmpty || value.isEmpty) return false;
  if (value.startsWith('*.')) {
    value = value.substring(2);
    return target == value || target.endsWith('.$value');
  }
  return target == value || target.endsWith('.$value');
}

/// 为某个主机选出代理的 `host:port`；返回 null 表示直连。
///
/// 规则按声明顺序取**第一条命中**；都没命中才用默认代理。
String? resolveOutboundProxy(
  OutboundProxySettings settings,
  String host,
) {
  if (!settings.enabled) return null;
  for (final rule in settings.validRules) {
    for (final pattern in rule.patterns) {
      if (outboundProxyMatches(host, pattern)) {
        return rule.proxyHostPort;
      }
    }
  }
  return settings._defaultHostPort;
}

/// 构造 `HttpClient.findProxy` 需要的字符串。
///
/// 注意：`dart:io` 的 findProxy 只支持 HTTP 代理（`PROXY host:port`）。
String findProxyValue(OutboundProxySettings settings, Uri uri) {
  final hostPort = resolveOutboundProxy(settings, uri.host);
  return hostPort == null ? 'DIRECT' : 'PROXY $hostPort';
}
