/// AI 分组规则的类型合同与「不可信正则」校验。
///
/// 对齐安卓 `AiGroupRuleService`：最多 6 条规则、正则最长 256 字符、
/// 规则名最长 40、分组名最长 48，并要求「重复覆盖 ≥ 50%」——分组名（第 1 个
/// 捕获组）必须被至少两个站点共用，且「捕获整串站点名」的规则不过半，
/// 否则它只是给单站点改名的噪音。
///
/// 关键安全性：AI 给的正则**不能直接应用**。这里只做「Java 与 Dart 都支持
/// 的安全子集」判定，通过后仍然要由用户确认（UI 职责）。
library;

import '../ai_assist.dart' show decodeJsonObject, extractJsonObject;

/// 一条待确认的分组规则。
class GroupRuleProposal {
  const GroupRuleProposal({
    required this.name,
    required this.regex,
    required this.reason,
  });

  final String name;
  final String regex;
  final String reason;

  Map<String, Object?> toJson() => {
    'name': name,
    'regex': regex,
    'reason': reason,
  };

  static GroupRuleProposal? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final name = raw['name'];
    final regex = raw['regex'];
    if (name is! String || name.trim().isEmpty) return null;
    if (regex is! String || regex.trim().isEmpty) return null;
    final pattern = regex.trim();
    // 落盘/导入的内容同样不可信：安全子集与长度上限必须重新校验，
    // 否则手工编辑或导入的 JSON 会绕过 AI 路径的校验直接进入应用。
    if (pattern.length > GroupRuleLimits.maxRegexLength) return null;
    if (!isJavaCompatibleSafeRegex(pattern)) return null;
    final safeName = name.trim();
    return GroupRuleProposal(
      name: safeName.length > GroupRuleLimits.maxRuleNameLength
          ? safeName.substring(0, GroupRuleLimits.maxRuleNameLength)
          : safeName,
      regex: pattern,
      reason: raw['reason'] is String ? raw['reason']! as String : '',
    );
  }
}

/// 被拒的一条（原文 + 原因，供 UI 如实展示）。
class GroupRuleRejection {
  const GroupRuleRejection({required this.reason, this.raw});

  final String reason;
  final Object? raw;

  Map<String, Object?> toJson() => {'reason': reason};
}

/// 校验结果。
class GroupRuleValidation {
  const GroupRuleValidation({
    required this.accepted,
    required this.rejected,
  });

  static const GroupRuleValidation empty = GroupRuleValidation(
    accepted: [],
    rejected: [],
  );

  final List<GroupRuleProposal> accepted;
  final List<GroupRuleRejection> rejected;

  bool get ok => accepted.isNotEmpty;

  /// 有接受项也有拒绝项时，UI 必须同时展示（不能只显示成功的那部分）。
  bool get partiallyRejected => rejected.isNotEmpty;
}

/// 上限（与安卓一致）。
abstract final class GroupRuleLimits {
  static const int maxRules = 6;
  static const int maxRegexLength = 256;
  static const int maxRuleNameLength = 40;
  static const int maxGroupNameLength = 48;

  /// 重复覆盖阈值（百分比）。
  static const int minRepeatedCoveragePercent = 50;
}

/// 校验 AI 输出的分组规则。
///
/// 接受原始模型文本（`String`）或已解析的 `Map`/`List`：模型文本按外部不可信
/// 数据处理，抽 JSON 失败即整体拒绝，绝不「尽量猜」出一条规则去应用。
GroupRuleValidation validateGroupRuleProposals(
  Object? raw, {
  int maxRules = GroupRuleLimits.maxRules,
  int maxRegexLength = GroupRuleLimits.maxRegexLength,
}) {
  var source = raw;
  if (source is String) {
    final jsonText = extractJsonObject(source);
    source = jsonText == null ? null : decodeJsonObject(jsonText);
  }
  if (source is! Map && source is! List) {
    return const GroupRuleValidation(
      accepted: [],
      rejected: [
        GroupRuleRejection(reason: 'AI 输出不是可解析的规则对象'),
      ],
    );
  }
  final list = source is Map ? source['rules'] : source;
  if (list is! List) {
    return const GroupRuleValidation(
      accepted: [],
      rejected: [
        GroupRuleRejection(reason: 'AI 输出缺少 rules 数组'),
      ],
    );
  }

  final accepted = <GroupRuleProposal>[];
  final rejected = <GroupRuleRejection>[];
  for (final entry in list) {
    if (accepted.length >= maxRules) {
      rejected.add(
        GroupRuleRejection(
          reason: '超过最多 $maxRules 条规则的上限',
          raw: entry,
        ),
      );
      continue;
    }
    final parsed = _parseOne(entry, maxRegexLength: maxRegexLength);
    if (parsed is String) {
      rejected.add(GroupRuleRejection(reason: parsed, raw: entry));
      continue;
    }
    accepted.add(parsed as GroupRuleProposal);
  }
  return GroupRuleValidation(accepted: accepted, rejected: rejected);
}

Object _parseOne(Object? entry, {required int maxRegexLength}) {
  if (entry is! Map) return '规则不是对象';
  final name = entry['name'];
  if (name is! String || name.trim().isEmpty) return '规则名称不能为空';
  final regex = entry['regex'];
  if (regex is! String || regex.trim().isEmpty) return '规则正则不能为空';
  final pattern = regex.trim();
  if (pattern.length > maxRegexLength) {
    return '正则长度超过 $maxRegexLength 字符上限';
  }
  if (!isJavaCompatibleSafeRegex(pattern)) {
    return '正则不在 Java/Dart 兼容的安全子集内（含后行断言/原子组/'
        '占有量词/命名组/Unicode 属性等，或无法编译）';
  }
  final safeName = name.trim();
  return GroupRuleProposal(
    name: safeName.length > GroupRuleLimits.maxRuleNameLength
        ? safeName.substring(0, GroupRuleLimits.maxRuleNameLength)
        : safeName,
    regex: pattern,
    reason: entry['reason'] is String ? entry['reason']! as String : '',
  );
}

/// 是否属于「Java 与 Dart 都支持、且不易造成灾难性回溯」的正则子集。
bool isJavaCompatibleSafeRegex(String pattern) {
  final text = pattern.trim();
  if (text.isEmpty) return false;
  const forbidden = <(String, String)>[
    ('(?<=', '后行断言'),
    ('(?<!', '后行断言'),
    ('(?>', '原子组'),
    ('*+', '占有量词'),
    ('++', '占有量词'),
    ('?+', '占有量词'),
    ('\\p{', 'Unicode 属性类'),
    ('\\P{', 'Unicode 属性类'),
    ('\\Q', '引用块'),
    ('\\E', '引用块'),
  ];
  for (final (needle, _) in forbidden) {
    if (text.contains(needle)) return false;
  }
  // 命名捕获组 `(?<name>`：Dart 支持但 Java 语义不同，统一拒绝。
  if (RegExp(r'\(\?<[A-Za-z_]').hasMatch(text)) return false;
  // 数字区间量词后的占有量词 `{1,3}+`。
  if (RegExp(r'\}\s*\+').hasMatch(text)) return false;
  var escaped = false;
  var inClass = false;
  for (var i = 0; i < text.length; i++) {
    final char = text[i];
    if (escaped) {
      escaped = false;
      continue;
    }
    if (char == r'\') {
      escaped = true;
      continue;
    }
    if (char == '[' && !inClass) {
      inClass = true;
      continue;
    }
    if (char == ']' && inClass) {
      inClass = false;
      continue;
    }
    if (!inClass && char == ')' && i + 1 < text.length) {
      final next = text[i + 1];
      if (next == '*' || next == '+' || next == '?' || next == '{') {
        return false;
      }
    }
  }
  try {
    RegExp(text);
  } catch (_) {
    return false;
  }
  return true;
}

/// 「重复覆盖」判定：一条规则至少命中两个站点，并且命中站点中重复命中的
/// 占比达到 50%。单站点命中永远不算（那是改名，不是分组）。
bool hasEnoughRepeatedCoverage({
  required int matchedSources,
  required int repeatedSources,
}) {
  if (matchedSources < 2 || repeatedSources < 2) return false;
  if (repeatedSources > matchedSources) return false;
  return repeatedSources * 100 >=
      matchedSources * GroupRuleLimits.minRepeatedCoveragePercent;
}

/// 一条规则对真实站点名的覆盖统计（对齐安卓
/// `AiGroupRuleService.validate`：捕获值 → 站点集合）。
class GroupRuleCoverage {
  const GroupRuleCoverage({
    required this.matchedSources,
    required this.repeatedSources,
    required this.fullNameCaptures,
    this.repeatedValues = const [],
  });

  static const GroupRuleCoverage none = GroupRuleCoverage(
    matchedSources: 0,
    repeatedSources: 0,
    fullNameCaptures: 0,
  );

  /// 至少抽出一个分组名的站点数。
  final int matchedSources;

  /// 抽出的分组名中至少有一个被 ≥2 个站点共用的站点数（真实「重复」）。
  final int repeatedSources;

  /// 抽出的分组名等于站点全名的站点数（截取整串名字 = 改名噪音）。
  final int fullNameCaptures;

  /// 被 ≥2 个站点共用的分组名（诊断/展示用）。
  final List<String> repeatedValues;

  /// 是否达到合同要求：命中 ≥2 站点、重复覆盖 ≥50%，且全名捕获不过半。
  bool get sufficient =>
      hasEnoughRepeatedCoverage(
        matchedSources: matchedSources,
        repeatedSources: repeatedSources,
      ) &&
      fullNameCaptures * 4 < matchedSources * 3;

  /// 给 UI/日志看的一句话说明。
  String describe() =>
      '命中 $matchedSources 个站点，其中重复覆盖 $repeatedSources 个，'
      '全名捕获 $fullNameCaptures 个';
}

/// 用**真实站点名**计算覆盖：分组名取第 1 个捕获组，没有捕获组时取整体命中
/// （与安卓 `GroupRule.capture` 一致）；超过分组名长度上限的值不算数。
GroupRuleCoverage computeGroupRuleCoverage({
  required String pattern,
  required List<String> sourceNames,
  int maxGroupNameLength = GroupRuleLimits.maxGroupNameLength,
}) {
  final RegExp regex;
  try {
    regex = RegExp(pattern);
  } catch (_) {
    return GroupRuleCoverage.none;
  }
  final sourcesByValue = <String, Set<int>>{};
  final valuesBySource = <int, Set<String>>{};
  final fullNameSources = <int>{};
  for (var i = 0; i < sourceNames.length; i++) {
    final name = sourceNames[i];
    for (final match in regex.allMatches(name)) {
      final value =
          (match.groupCount >= 1 && match.group(1) != null
                  ? match.group(1)!
                  : (match.group(0) ?? ''))
              .trim();
      if (value.isEmpty || value.length > maxGroupNameLength) continue;
      valuesBySource.putIfAbsent(i, () => <String>{}).add(value);
      sourcesByValue.putIfAbsent(value, () => <int>{}).add(i);
      if (normalizeGroupName(value) == normalizeGroupName(name)) {
        fullNameSources.add(i);
      }
    }
  }
  final repeatedValues = <String>[
    for (final entry in sourcesByValue.entries)
      if (entry.value.length >= 2) entry.key,
  ];
  final repeatedSources = <int>{
    for (final entry in valuesBySource.entries)
      if (entry.value.any(repeatedValues.contains)) entry.key,
  };
  return GroupRuleCoverage(
    matchedSources: valuesBySource.length,
    repeatedSources: repeatedSources.length,
    fullNameCaptures: fullNameSources.length,
    repeatedValues: List.unmodifiable(repeatedValues),
  );
}

/// 分组名比较口径（对齐安卓 `normalize`：去空白、大小写不敏感）。
String normalizeGroupName(String value) =>
    value.replaceAll(RegExp(r'[\s\u3000]+'), '').toLowerCase();

