import 'package:flutter/material.dart';

import 'app.dart' show PosterImage;
import 'tokens.dart';

/// 推荐详情弹窗的展示数据。
///
/// 只承载调用方**已经拿到**的字段：来源、海报、年份/评分等元信息、简介、
/// 推荐理由、数据状态。弹窗不做任何额外查询——没有的字段就不显示，
/// 宁缺不伪造。
class RecommendationInfo {
  const RecommendationInfo({
    required this.title,
    required this.sourceLabel,
    this.posterUrl,
    this.meta = const [],
    this.overview,
    this.reason,
    this.status,
    this.credit,
  });

  final String title;

  /// 来源标签：`AI 推荐` / `TMDB` / `豆瓣`。
  final String sourceLabel;

  final String? posterUrl;

  /// 年份、类型、评分等短标签（逐个小胶囊展示）。
  final List<String> meta;

  final String? overview;

  /// 为什么推荐这部（豆瓣/历史/TMDB 的理由或 AI 的推荐说明）。
  final String? reason;

  /// 数据状态，例如「TMDB #1234」「仅元数据（未匹配 TMDB）」。
  final String? status;

  /// 演职员等附加信息（有才显示）。
  final String? credit;
}

/// 所有推荐行共用的详情弹窗。
///
/// 交互与推荐卡片单击严格一致：[onOpen] 就是卡片 `onTap` 的去向
/// （有身份开作品详情，没有就按标题搜站源）。[onOpen] 是主按钮；
/// 「不感兴趣」只负责负反馈，不影响其它入口。
Future<void> showRecommendationInfo(
  BuildContext context, {
  required RecommendationInfo info,
  VoidCallback? onOpen,
  Future<void> Function()? onNotInterested,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => RecommendationInfoDialog(
      info: info,
      onOpen: onOpen,
      onNotInterested: onNotInterested,
    ),
  );
}

class RecommendationInfoDialog extends StatelessWidget {
  const RecommendationInfoDialog({
    super.key,
    required this.info,
    this.onOpen,
    this.onNotInterested,
  });

  final RecommendationInfo info;
  final VoidCallback? onOpen;
  final Future<void> Function()? onNotInterested;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final media = MediaQuery.of(context).size;
    final overview = (info.overview ?? '').trim();
    final reason = (info.reason ?? '').trim();
    return Dialog(
      key: const ValueKey('recommendation-info-dialog'),
      clipBehavior: Clip.antiAlias,
      insetPadding: const EdgeInsets.all(AppSpace.xl),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 720,
          // 长简介在弹窗内部滚动，不把窗口顶出屏幕。
          maxHeight: media.height * 0.82,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpace.xl,
            AppSpace.lg,
            AppSpace.xl,
            AppSpace.lg,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Header(info: info),
              const SizedBox(height: AppSpace.md),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _Hero(info: info),
                      const SizedBox(height: AppSpace.lg),
                      _SectionLabel(text: '简介'),
                      const SizedBox(height: AppSpace.xs),
                      Text(
                        overview.isEmpty ? '暂无可用简介' : overview,
                        key: const ValueKey('recommendation-info-overview'),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          height: 1.55,
                          color: overview.isEmpty
                              ? theme.colorScheme.onSurfaceVariant
                              : null,
                        ),
                      ),
                      if (reason.isNotEmpty) ...[
                        const SizedBox(height: AppSpace.lg),
                        _SectionLabel(text: '推荐理由'),
                        const SizedBox(height: AppSpace.xs),
                        Text(
                          reason,
                          key: const ValueKey('recommendation-info-reason'),
                          style: theme.textTheme.bodyMedium?.copyWith(
                            height: 1.55,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: AppSpace.lg),
              _Actions(
                onOpen: onOpen,
                onNotInterested: onNotInterested,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.info});

  final RecommendationInfo info;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Container(
          key: const ValueKey('recommendation-info-source'),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            info.sourceLabel,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onPrimaryContainer,
            ),
          ),
        ),
        const Spacer(),
        IconButton(
          key: const ValueKey('recommendation-info-close-icon'),
          tooltip: '关闭',
          visualDensity: VisualDensity.compact,
          onPressed: () => Navigator.of(context).maybePop(),
          icon: const Icon(Icons.close, size: 18),
        ),
      ],
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero({required this.info});

  final RecommendationInfo info;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.md),
            boxShadow: [
              BoxShadow(
                color: theme.colorScheme.shadow.withValues(alpha: 0.18),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.md),
            child: PosterImage(
              key: const ValueKey('recommendation-info-poster'),
              url: info.posterUrl,
              width: 140,
              height: 210,
              cacheWidth: 360,
            ),
          ),
        ),
        const SizedBox(width: AppSpace.lg),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                info.title,
                key: const ValueKey('recommendation-info-title'),
                style: theme.textTheme.titleLarge,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              if (info.meta.isNotEmpty) ...[
                const SizedBox(height: AppSpace.sm),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final value in info.meta) _Pill(text: value),
                  ],
                ),
              ],
              if ((info.status ?? '').trim().isNotEmpty) ...[
                const SizedBox(height: AppSpace.sm),
                Text(
                  info.status!.trim(),
                  key: const ValueKey('recommendation-info-status'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              if ((info.credit ?? '').trim().isNotEmpty) ...[
                const SizedBox(height: AppSpace.xs),
                Text(
                  info.credit!.trim(),
                  key: const ValueKey('recommendation-info-credit'),
                  style: theme.textTheme.bodySmall,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(text, style: Theme.of(context).textTheme.titleSmall);
  }
}

class _Actions extends StatelessWidget {
  const _Actions({this.onOpen, this.onNotInterested});

  final VoidCallback? onOpen;
  final Future<void> Function()? onNotInterested;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        if (onNotInterested != null)
          TextButton(
            key: const ValueKey('recommendation-info-hide'),
            // 去掉 TextButton 的默认横向内边距：按钮文字与简介/推荐理由同一条左边缘。
            style: TextButton.styleFrom(
              padding: EdgeInsets.zero,
              minimumSize: const Size(0, 42),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              foregroundColor: theme.colorScheme.onSurfaceVariant,
            ),
            onPressed: () {
              // 与卡片单击同一条时序：先关弹窗，再发起负反馈（真实文件 IO）。
              Navigator.of(context).pop();
              onNotInterested!.call();
            },
            child: const Text('不感兴趣'),
          ),
        const Spacer(),
        TextButton(
          key: const ValueKey('recommendation-info-close'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
        const SizedBox(width: AppSpace.sm),
        FilledButton.icon(
          key: const ValueKey('recommendation-info-open'),
          onPressed: onOpen == null
              ? null
              : () {
                  // 与推荐卡片单击完全一致的去向：先关弹窗再调用同一回调。
                  Navigator.of(context).pop();
                  onOpen!.call();
                },
          icon: const Icon(Icons.arrow_forward, size: 18),
          label: const Text('详情'),
        ),
      ],
    );
  }
}
