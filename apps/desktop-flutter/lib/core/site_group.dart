/// 站点名分组规则（对齐上游「默影视」`GroupRuleConfig`）。
///
/// 上游站点列表并不依赖配置里的显式分组字段，而是**从站点名里抽取标记**：
/// `木偶[盘]` → 分组「盘」、`金牌影视[采]` → 「采」、`BiliBili[官]` → 「官」。
/// 这符合 TVBox 生态的事实约定——170 个站点里绝大多数用方括号后缀标来源类型，
/// 配置里没有 group 字段可用。
///
/// 只实现上游 4 条内置规则里的前两条（方括号标签、竖线后缀）：后两条（框线分隔
/// `┆`、圆点后缀 `•`/`·`）在本机实测的 170 个站点里零命中，先不做。
library;

/// 从站点名抽取的全部分组（保序、去重）。无标记时返回空表。
///
/// 例：`木偶[盘]` → `['盘']`；`在线之家[采][盘]` → `['采', '盘']`；
/// `1234影视` → `[]`。
List<String> siteGroupsOf(String name) {
  final text = name.trim();
  if (text.isEmpty) return const [];
  final groups = <String>[];
  void add(String? value) {
    final tag = value?.trim() ?? '';
    if (tag.isEmpty || groups.contains(tag)) return;
    groups.add(tag);
  }

  // 规则 1：方括号标签 `[盘]` / `[采]`（可以有多个）。
  for (final match in _bracket.allMatches(text)) {
    add(match.group(1));
  }
  // 规则 2：竖线后缀 `影视 | 高清`（取末尾一段）。
  add(_pipe.firstMatch(text)?.group(1));
  return groups;
}

/// 站点是否命中分组过滤。[group] 为空表示「全部」。
bool siteInGroup(String name, String group) {
  final tag = group.trim();
  if (tag.isEmpty) return true;
  return siteGroupsOf(name).contains(tag);
}

/// 站点是否命中搜索关键字（名称或 key，大小写不敏感）。
///
/// 名称优先：用户看到的是名称，也只会按名称找；带上 key 是为了兼容「按 key
/// 精确找一个站点」的调试场景。
bool siteMatchesQuery({
  required String name,
  required String key,
  required String query,
}) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  return name.toLowerCase().contains(q) || key.toLowerCase().contains(q);
}

/// 方括号标签：`[盘]`。
final RegExp _bracket = RegExp(r'\[([^\]]+)\]');

/// 竖线后缀：`影视 | 高清` 取 `高清`。
final RegExp _pipe = RegExp(r'[|｜]\s*([^|｜]+?)\s*$');
