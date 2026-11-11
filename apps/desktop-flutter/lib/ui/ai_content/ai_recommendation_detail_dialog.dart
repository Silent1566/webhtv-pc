import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/ai_content/recommendation.dart';
import '../app.dart' show PosterImage;
import '../tokens.dart';

/// 推荐详情弹窗：对齐安卓 `AiRecommendationInfoDialog` 的信息结构。
///
/// 安卓长按推荐卡会弹出：来源 + 片名 + 类型/评分 + 数据状态 + 简介 + 详细推荐
/// 理由 + 「不感兴趣」「关闭」两个按钮。PC 端保持同一批字段与同一顺序；
/// 安卓独有的字段（原始语言、出品国、豆瓣评分、演职员）本端卡片数据里**没有**
/// 可靠来源，就不显示——宁缺不伪造。
Future<void> showAiRecommendationDetails(
  BuildContext context, {
  required RecommendationCard card,
  String sourceLabel = 'AI 推荐',
  Future<void> Function()? onNotInterested,
}) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => _AiRecommendationDetailsDialog(
      card: card,
      sourceLabel: sourceLabel,
      onNotInterested: onNotInterested,
    ),
  );
}

class _AiRecommendationDetailsDialog extends StatefulWidget {
  const _AiRecommendationDetailsDialog({
    required this.card,
    required this.sourceLabel,
    this.onNotInterested,
  });

  final RecommendationCard card;
  final String sourceLabel;
  final Future<void> Function()? onNotInterested;

  @override
  State<_AiRecommendationDetailsDialog> createState() =>
      _AiRecommendationDetailsDialogState();
}

class _AiRecommendationDetailsDialogState
    extends State<_AiRecommendationDetailsDialog> {
  bool _busy = false;

  RecommendationCard get _card => widget.card;

  String get _meta => [
    if (_card.year != null) '${_card.year}',
    _card.mediaType.label,
    if (_card.rating != null) '评分 ${_card.rating!.toStringAsFixed(1)}',
  ].join(' · ');

  /// 「数据状态」：告诉用户这条推荐有多少真实数据，避免把降级卡当成完整资料。
  String get _dataStatus {
    final values = <String>[
      if (_card.tmdbId != null && _card.tmdbId! > 0)
        'TMDB #${_card.tmdbId}'
      else
        '仅元数据（未匹配 TMDB）',
      if ((_card.posterUrl ?? '').isEmpty) '无海报',
    ];
    return values.join(' · ');
  }

  Future<void> _notInterested() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.onNotInterested?.call();
    } finally {
      if (mounted) Navigator.of(context).maybePop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reason = _card.reason.trim();
    final overview = (_card.overview ?? '').trim();
    final media = MediaQuery.of(context).size;
    return Dialog(
      key: const ValueKey('ai-recommendation-details'),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 640,
          // 安卓按屏高的 82% 取高，这里同口径，长简介内部滚动。
          maxHeight: media.height * 0.82,
        ),
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text('推荐详情', style: theme.textTheme.titleMedium),
                  const SizedBox(width: AppSpace.sm),
                  Text(
                    widget.sourceLabel,
                    key: const ValueKey('ai-recommendation-details-source'),
                    style: theme.textTheme.bodySmall,
                  ),
                  const Spacer(),
                  IconButton(
                    key: const ValueKey('ai-recommendation-details-close-icon'),
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.close, size: 18),
                  ),
                ],
              ),
              const SizedBox(height: AppSpace.sm),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: PosterImage(
                              url: _card.posterUrl,
                              width: 120,
                              height: 180,
                              cacheWidth: 320,
                            ),
                          ),
                          const SizedBox(width: AppSpace.md),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _card.title,
                                  key: const ValueKey(
                                    'ai-recommendation-details-title',
                                  ),
                                  style: theme.textTheme.titleMedium,
                                ),
                                const SizedBox(height: 4),
                                Text(_meta, style: theme.textTheme.bodySmall),
                                const SizedBox(height: 6),
                                Text(
                                  _dataStatus,
                                  style: theme.textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: AppSpace.lg),
                      // 简介：安卓在缺失时显示占位文案并淡化，而不是整块消失。
                      Text('简介', style: theme.textTheme.titleSmall),
                      const SizedBox(height: 4),
                      Text(
                        overview.isEmpty ? '暂无可用简介' : overview,
                        key: const ValueKey('ai-recommendation-details-overview'),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: overview.isEmpty
                              ? theme.textTheme.bodySmall?.color
                              : null,
                        ),
                      ),
                      if (reason.isNotEmpty) ...[
                        const SizedBox(height: AppSpace.lg),
                        Text('推荐理由', style: theme.textTheme.titleSmall),
                        const SizedBox(height: 4),
                        Text(
                          reason,
                          key: const ValueKey(
                            'ai-recommendation-details-reason',
                          ),
                          style: theme.textTheme.bodyMedium,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: AppSpace.lg),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (widget.onNotInterested != null)
                    TextButton.icon(
                      key: const ValueKey('ai-recommendation-details-hide'),
                      onPressed: _busy ? null : _notInterested,
                      icon: const Icon(Icons.thumb_down_outlined, size: 18),
                      label: const Text('不感兴趣'),
                    ),
                  const SizedBox(width: AppSpace.sm),
                  FilledButton(
                    key: const ValueKey('ai-recommendation-details-confirm'),
                    onPressed: () => Navigator.of(context).maybePop(),
                    child: const Text('关闭'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
