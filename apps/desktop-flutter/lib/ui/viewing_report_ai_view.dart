import 'package:flutter/material.dart';

import '../../core/viewing_report_ai_narrative.dart';
import 'tokens.dart';

/// 「AI 解读」的结构化展示：摘要 / 标签 / 类型洞察 / 亮点 / 建议。
///
/// 解析不出结构时退回原文（`viewing-report-ai-text`），保证任何情况下
/// 都不丢模型给的内容。
class ViewingReportAiNarrativeView extends StatelessWidget {
  const ViewingReportAiNarrativeView({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final narrative = ViewingReportAiNarrative.parse(text);
    if (narrative == null) {
      return SelectableText(
        text,
        key: const ValueKey('viewing-report-ai-text'),
      );
    }
    return Column(
      key: const ValueKey('viewing-report-ai-narrative'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (narrative.summary.isNotEmpty) ...[
          SelectableText(
            narrative.summary,
            key: const ValueKey('viewing-report-ai-text'),
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: AppSpace.md),
        ],
        if (narrative.tags.isNotEmpty) ...[
          Wrap(
            key: const ValueKey('viewing-report-ai-tags'),
            spacing: AppSpace.sm,
            runSpacing: AppSpace.xs,
            children: [
              for (final tag in narrative.tags)
                Chip(
                  label: Text(tag),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
            ],
          ),
          const SizedBox(height: AppSpace.md),
        ],
        if (narrative.badges.isNotEmpty) ...[
          Wrap(
            key: const ValueKey('viewing-report-ai-badges'),
            spacing: AppSpace.sm,
            runSpacing: AppSpace.xs,
            children: [
              for (final badge in narrative.badges)
                Chip(
                  avatar: const Icon(Icons.workspace_premium_outlined, size: 16),
                  label: Text(badge),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
            ],
          ),
          const SizedBox(height: AppSpace.md),
        ],
        if (narrative.genreInsights.isNotEmpty) ...[
          _Block(
            title: '类型偏好',
            child: SelectableText(
              narrative.genreInsights,
              key: const ValueKey('viewing-report-ai-genres'),
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ],
        if (narrative.highlights.isNotEmpty) ...[
          _Block(
            title: '值得注意',
            child: Column(
              key: const ValueKey('viewing-report-ai-highlights'),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final item in narrative.highlights)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('· '),
                        Expanded(
                          child: SelectableText(
                            item,
                            style: theme.textTheme.bodyMedium,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
        if (narrative.recommendationHint.isNotEmpty)
          _Block(
            title: '下一步建议',
            child: SelectableText(
              narrative.recommendationHint,
              key: const ValueKey('viewing-report-ai-hint'),
              style: theme.textTheme.bodyMedium,
            ),
          ),
      ],
    );
  }
}

class _Block extends StatelessWidget {
  const _Block({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          child,
        ],
      ),
    );
  }
}
