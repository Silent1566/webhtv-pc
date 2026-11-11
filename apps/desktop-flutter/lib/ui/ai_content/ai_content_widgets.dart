/// 内容智能的可嵌入组件（不改共享 shell，也不自带导航）。
///
/// 只消费类型化数据 + 回调：宿主页面（Task F 的统一接线）决定放在哪、
/// 什么时候调用服务；本层不发起任何 AI 请求、不写任何状态。
///
/// 风格沿用 PC 现有的 Material 度量与 [AppSemanticColors]；颜色一律从
/// 主题取，缺扩展时回落 `colorScheme`，不写死色值。
library;

import 'package:flutter/material.dart';

import '../../core/ai_content/ad_rule_validation.dart';
import '../../core/ai_content/group_rule_validation.dart';
import '../../core/ai_content/log_diagnosis.dart';
import '../../core/ai_content/recommendation.dart';
import '../tokens.dart';

/// 一张推荐卡（富集失败时就是降级片名卡）。
class AiRecommendationCardTile extends StatelessWidget {
  const AiRecommendationCardTile({
    super.key,
    required this.card,
    this.onNotInterested,
    this.onOpen,
  });

  final RecommendationCard card;
  final VoidCallback? onNotInterested;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = theme.extension<AppSemanticColors>();
    final meta = [
      if (card.year != null) '${card.year}',
      card.mediaType.label,
      if (card.rating != null) '评分 ${card.rating!.toStringAsFixed(1)}',
    ].join(' · ');
    return Card(
      margin: const EdgeInsets.only(bottom: AppSpace.sm),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.md),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (card.posterUrl != null)
                ClipRRect(
                  borderRadius: AppRadius.smAll,
                  child: Image.network(
                    card.posterUrl!,
                    width: 56,
                    height: 80,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const SizedBox(
                      width: 56,
                      height: 80,
                    ),
                  ),
                ),
              if (card.posterUrl != null) const SizedBox(width: AppSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      card.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: AppWeight.title,
                      ),
                    ),
                    const SizedBox(height: AppSpace.xs),
                    Text(
                      meta,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                    if (card.reason.isNotEmpty) ...[
                      const SizedBox(height: AppSpace.xs),
                      Text(
                        card.reason,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                    if (card.degraded) ...[
                      const SizedBox(height: AppSpace.xs),
                      Text(
                        '未富集（仅片名，可点开搜索）',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color:
                              semantic?.statusDegraded ??
                              theme.colorScheme.secondary,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (onNotInterested != null)
                IconButton(
                  key: ValueKey('ai-recommendation-not-interested-${card.title}'),
                  tooltip: '不感兴趣',
                  onPressed: onNotInterested,
                  icon: const Icon(Icons.thumb_down_outlined, size: 18),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 置信度徽章：低于 0.5 明确标注「低置信」。
class AiConfidenceBadge extends StatelessWidget {
  const AiConfidenceBadge({super.key, required this.confidence});

  final double confidence;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = theme.extension<AppSemanticColors>();
    final percent = (confidence.clamp(0.0, 1.0) * 100).round();
    final low = confidence < 0.5;
    final color = low
        ? (semantic?.statusDegraded ?? theme.colorScheme.error)
        : (semantic?.statusOk ?? theme.colorScheme.primary);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.sm,
        vertical: AppSpace.xs,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: AppRadius.pillAll,
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        low ? '低置信 $percent%' : '置信 $percent%',
        style: theme.textTheme.labelSmall?.copyWith(color: color),
      ),
    );
  }
}

/// 分组规则预览：AI 结果必须经用户确认后才交给应用层。
class AiGroupRulePreview extends StatelessWidget {
  const AiGroupRulePreview({
    super.key,
    required this.rules,
    this.rejected = const [],
    this.onConfirm,
    this.onCancel,
  });

  final List<GroupRuleProposal> rules;
  final List<GroupRuleRejection> rejected;
  final VoidCallback? onConfirm;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = theme.extension<AppSemanticColors>();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'AI 分组规则预览（需人工确认）',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: AppWeight.title,
              ),
            ),
            const SizedBox(height: AppSpace.sm),
            if (rules.isEmpty)
              Text('没有可用规则', style: theme.textTheme.bodySmall),
            for (final rule in rules)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpace.sm),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      rule.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium,
                    ),
                    Text(
                      rule.regex,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                      ),
                    ),
                    if (rule.reason.isNotEmpty)
                      Text(rule.reason, style: theme.textTheme.labelSmall),
                  ],
                ),
              ),
            if (rejected.isNotEmpty) ...[
              Text(
                '已拒绝 ${rejected.length} 条（如实列出原因）：',
                style: theme.textTheme.labelSmall?.copyWith(
                  color:
                      semantic?.statusDegraded ?? theme.colorScheme.secondary,
                ),
              ),
              for (final item in rejected)
                Text(
                  '· ${item.reason}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color:
                        semantic?.statusDegraded ?? theme.colorScheme.secondary,
                  ),
                ),
            ],
            const SizedBox(height: AppSpace.sm),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (onCancel != null)
                  TextButton(onPressed: onCancel, child: const Text('取消')),
                if (onConfirm != null) ...[
                  const SizedBox(width: AppSpace.sm),
                  FilledButton(
                    onPressed: rules.isEmpty ? null : onConfirm,
                    child: const Text('应用规则'),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 去广建议预览：`warningOnly` 只显示警告，不提供应用入口。
class AiAdRulePreview extends StatelessWidget {
  const AiAdRulePreview({
    super.key,
    required this.assessment,
    this.onConfirm,
    this.onCancel,
  });

  final AdRuleAssessment assessment;
  final VoidCallback? onConfirm;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = theme.extension<AppSemanticColors>();
    final proposal = assessment.proposal;
    final canApply = assessment.applicable && onConfirm != null;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'AI 去广建议（需人工确认）',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: AppWeight.title,
              ),
            ),
            if (proposal != null) ...[
              const SizedBox(height: AppSpace.xs),
              AiConfidenceBadge(confidence: proposal.confidence),
              if (proposal.hostsBlacklist.isNotEmpty)
                Text(
                  '域名：${proposal.hostsBlacklist.join('、')}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              if (proposal.regexPatterns.isNotEmpty)
                Text(
                  '广告正则：${proposal.regexPatterns.join(' | ')}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              if (proposal.excludePatterns.isNotEmpty)
                Text(
                  '正片保护：${proposal.excludePatterns.join(' | ')}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
            ],
            for (final warning in assessment.warnings)
              Text(
                warning,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color:
                      semantic?.statusDegraded ?? theme.colorScheme.secondary,
                ),
              ),
            for (final reason in assessment.reasons)
              Text(
                reason,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: semantic?.statusFailed ?? theme.colorScheme.error,
                ),
              ),
            const SizedBox(height: AppSpace.sm),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (onCancel != null)
                  TextButton(onPressed: onCancel, child: const Text('取消')),
                if (canApply) ...[
                  const SizedBox(width: AppSpace.sm),
                  FilledButton(
                    onPressed: onConfirm,
                    child: const Text('应用规则'),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 日志诊断四段展示（缺段显示占位，不假装有结论）。
class AiLogDiagnosisView extends StatelessWidget {
  const AiLogDiagnosisView({super.key, required this.result});

  final LogDiagnosisResult result;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = <(String, String)>[
      ('结论', result.conclusion),
      ('证据', result.evidence),
      ('建议', result.suggestion),
      ('还缺什么', result.missing),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final (label, value) in rows)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpace.sm),
                child: Text(
                  '$label：${value.isEmpty ? '—' : value}',
                  style: theme.textTheme.bodySmall,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
