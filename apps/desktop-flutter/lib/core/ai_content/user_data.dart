/// 内容智能域的用户数据封装：反馈 / 分组规则 / 去广规则 / 片名学习。
///
/// 这四类是**用户数据**（丢了就是丢用户教过的东西），必须可枚举、可导出、
/// 可随备份迁移；推荐缓存与画像缓存不在这里——它们按模型输出重建即可。
///
/// 每个域各存一个专属文件（不写共享 `settings.json`），本层只负责
/// 「一份可备份的 JSON 快照」这一件事。
library;

import 'ad_rule_validation.dart';
import 'group_rule_validation.dart';
import 'recommendation_feedback.dart';
import 'title_learning.dart';

/// 导出格式版本：只在结构不兼容时递增。
const int aiContentUserDataSchemaVersion = 1;

/// 一份内容智能用户数据快照。
class AiContentUserData {
  AiContentUserData({
    required this.exportedAtMs,
    RecommendationFeedbackCollection? feedback,
    List<GroupRuleProposal>? groupRules,
    List<AdRuleProposal>? adRules,
    TitleLearningCollection? learning,
  }) : feedback = feedback ?? RecommendationFeedbackCollection.empty(),
       groupRules = List.unmodifiable(groupRules ?? const <GroupRuleProposal>[]),
       adRules = List.unmodifiable(adRules ?? const <AdRuleProposal>[]),
       learning = learning ?? TitleLearningCollection.empty();

  /// 参与导出的域（顺序稳定，便于测试与备份 diff）。
  static const List<String> exportedKeys = [
    'feedback',
    'groupRules',
    'adRules',
    'learning',
  ];

  final int exportedAtMs;
  final RecommendationFeedbackCollection feedback;
  final List<GroupRuleProposal> groupRules;
  final List<AdRuleProposal> adRules;
  final TitleLearningCollection learning;

  bool get isEmpty =>
      feedback.isEmpty && groupRules.isEmpty && adRules.isEmpty && learning.isEmpty;

  Map<String, Object?> toJson() => {
    'schemaVersion': aiContentUserDataSchemaVersion,
    'exportedAtMs': exportedAtMs,
    'feedback': feedback.toJson(),
    'groupRules': [for (final rule in groupRules) rule.toJson()],
    'adRules': [for (final rule in adRules) rule.toJson()],
    'learning': learning.toJson(),
  };

  /// 容错读取：任一域损坏只丢该域，不影响其他用户数据。
  /// 规则域接受两种形状：导出用的数组，和落盘用的 `{"rules":[...]}`。
  static AiContentUserData fromJson(Object? raw) {
    if (raw is! Map) {
      return AiContentUserData(exportedAtMs: 0);
    }
    final groupRules = <GroupRuleProposal>[];
    for (final item in _ruleList(raw['groupRules'])) {
      final rule = GroupRuleProposal.fromJson(item);
      if (rule != null) groupRules.add(rule);
    }
    final adRules = <AdRuleProposal>[];
    for (final item in _ruleList(raw['adRules'])) {
      final rule = AdRuleProposal.fromJson(item);
      if (rule != null) adRules.add(rule);
    }
    return AiContentUserData(
      exportedAtMs: raw['exportedAtMs'] is int
          ? raw['exportedAtMs']! as int
          : 0,
      feedback: RecommendationFeedbackCollection.fromJson(raw['feedback']),
      groupRules: groupRules,
      adRules: adRules,
      learning: TitleLearningCollection.fromJson(raw['learning']),
    );
  }

  static List<Object?> _ruleList(Object? raw) {
    if (raw is List) return raw;
    if (raw is Map && raw['rules'] is List) return raw['rules']! as List;
    return const [];
  }
}
