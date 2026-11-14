/// 可配置的站点分组规则（`docs/phase9/README.md` P1-5）。
///
/// 站点列表不使用配置里的显式分组字段，而是从站点名抽取标记（`木偶[盘]` → 「盘」）。
/// 本文件把原来写死的两条规则升级为：
/// - 4 条内置规则（方括号/竖线/框线/圆点），可单独开关；
/// - 自定义正则规则（一个捕获组即分组名）。
///
/// 规则按顺序执行、分组保序去重；**非法正则被跳过**（不因一条坏规则让整页空掉）。
library;

class SiteGroupRule {
  const SiteGroupRule({
    required this.id,
    required this.name,
    required this.pattern,
    this.enabled = true,
    this.builtin = false,
  });

  /// 稳定标识；内置规则 id 不得改名。
  final String id;

  /// 展示名。
  final String name;

  /// 正则，必须含一个捕获组。
  final String pattern;

  final bool enabled;
  final bool builtin;

  SiteGroupRule copyWith({bool? enabled}) => SiteGroupRule(
    id: id,
    name: name,
    pattern: pattern,
    enabled: enabled ?? this.enabled,
    builtin: builtin,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'pattern': pattern,
    'enabled': enabled,
  };

  /// 宽松解析；缺 id/pattern 或正则非法时返回 null。
  static SiteGroupRule? fromJson(Object? raw, {bool builtin = false}) {
    if (raw is! Map) return null;
    final id = raw['id'] is String ? (raw['id'] as String).trim() : '';
    final pattern = raw['pattern'] is String
        ? (raw['pattern'] as String).trim()
        : '';
    if (id.isEmpty || pattern.isEmpty) return null;
    if (!isValidSiteGroupPattern(pattern)) return null;
    final name = raw['name'] is String && (raw['name'] as String).trim().isNotEmpty
        ? (raw['name'] as String).trim()
        : id;
    return SiteGroupRule(
      id: id,
      name: name,
      pattern: pattern,
      enabled: raw['enabled'] is bool ? raw['enabled'] as bool : true,
      builtin: builtin,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SiteGroupRule &&
      other.id == id &&
      other.name == name &&
      other.pattern == pattern &&
      other.enabled == enabled;

  @override
  int get hashCode => Object.hash(id, name, pattern, enabled);

  @override
  String toString() => 'SiteGroupRule($id, enabled=$enabled)';
}

/// 校验正则：能被编译即可。捕获组在运行时读取（无捕获组则抽不出分组）。
bool isValidSiteGroupPattern(String pattern) {
  if (pattern.trim().isEmpty) return false;
  try {
    RegExp(pattern);
    return true;
  } catch (_) {
    return false;
  }
}

/// 4 条内置规则（与安卓 `GroupRuleConfig.builtins()` 对齐）。
const List<SiteGroupRule> builtinSiteGroupRules = [
  SiteGroupRule(
    id: 'builtin_bracket_tag',
    name: '方括号标签',
    pattern: r'\[([^\]]+)\]',
    builtin: true,
  ),
  SiteGroupRule(
    id: 'builtin_pipe_quality',
    name: '竖线后缀',
    pattern: r'[|｜]\s*([^|｜]+?)\s*$',
    builtin: true,
  ),
  SiteGroupRule(
    id: 'builtin_box_separator',
    name: '框线分隔',
    pattern: r'┆\s*([^┆]+)\s*$',
    builtin: true,
  ),
  SiteGroupRule(
    id: 'builtin_bullet_suffix',
    name: '圆点后缀',
    pattern: r'[•·]\s*([^•·]+?)\s*$',
    builtin: true,
  ),
];

/// 生效规则集：内置（按用户开关）在前，自定义在后。
class SiteGroupSettings {
  const SiteGroupSettings({this.rules = builtinSiteGroupRules});

  const SiteGroupSettings.defaults() : this();

  final List<SiteGroupRule> rules;

  List<SiteGroupRule> get enabledRules =>
      [for (final rule in rules) if (rule.enabled) rule];

  SiteGroupSettings copyWith({List<SiteGroupRule>? rules}) =>
      SiteGroupSettings(rules: rules ?? this.rules);

  Map<String, Object?> toJson() => <String, Object?>{
    'rules': [for (final rule in rules) rule.toJson()],
  };

  factory SiteGroupSettings.fromJson(Object? raw) {
    final map = raw is Map ? raw : const {};
    final rawRules = map['rules'];
    if (rawRules is! List) return const SiteGroupSettings.defaults();

    final stored = <String, SiteGroupRule>{};
    final custom = <SiteGroupRule>[];
    for (final item in rawRules) {
      final parsed = SiteGroupRule.fromJson(item);
      if (parsed == null) continue;
      stored[parsed.id] = parsed;
      if (!builtinSiteGroupRules.any((rule) => rule.id == parsed.id)) {
        custom.add(parsed);
      }
    }
    // 内置规则始终存在：用户关掉的保持关闭，文件里缺失的用默认开启。
    final rules = <SiteGroupRule>[
      for (final builtin in builtinSiteGroupRules)
        stored[builtin.id]?.copyWith() ??
            builtin.copyWith(enabled: true),
      ...custom,
    ];
    return SiteGroupSettings(rules: rules);
  }

  @override
  bool operator ==(Object other) =>
      other is SiteGroupSettings &&
      _listEquals(other.rules, rules);

  @override
  int get hashCode => Object.hashAll(rules);

  static bool _listEquals(List<SiteGroupRule> a, List<SiteGroupRule> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// 按规则抽取分组（保序去重）。无启用规则或无命中时返回空表。
List<String> siteGroupsWithRules(
  String name, {
  required List<SiteGroupRule> rules,
}) {
  final text = name.trim();
  if (text.isEmpty) return const [];
  final groups = <String>[];
  for (final rule in rules) {
    if (!rule.enabled) continue;
    final RegExp regex;
    try {
      regex = RegExp(rule.pattern);
    } catch (_) {
      continue;
    }
    for (final match in regex.allMatches(text)) {
      final tag = (match.groupCount >= 1 ? match.group(1) : null)?.trim() ?? '';
      if (tag.isEmpty || groups.contains(tag)) continue;
      groups.add(tag);
    }
  }
  return groups;
}
