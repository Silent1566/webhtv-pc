/// 详情页「短评」区块：多来源短评 + 豆瓣式星级评分 + 分页。
///
/// 从 browse_pages.dart 的 _buildExternalComments 搬出来：那段渲染逻辑
/// 与页面状态（_externalComments 等四个字段）绑在一起，改动评分版式就要
/// 拉起整个详情页 —— 一个纯粹的数据 → 视图映射不该有这种代价。
library;

import 'package:flutter/material.dart';

import '../core/external_detail_meta.dart';
import 'common.dart';
import 'tokens.dart';

/// 短评列表。
///
/// 设计取舍（用户反馈 2026-11-22：「评分只有一段 8.0/10 文本，得逐条读才能
/// 看出高低」）：
/// - 星级行**独占一行**，不塞进元信息行。元信息是「作者 · N 有用 · 日期」这种
///   长短不一的灰字，星星跟在里面会被挤得忽左忽右；独占一行后每条的星星都从
///   同一个 x 起算，纵向连起来就是一张「评分表」，扫一眼就能比出高低。
/// - **未评分也占一行**（写「未评分」）。缺行会让同一页的正文起点上下错开，
///   读者会以为是自己看错了；占位把版式钉死，也把「没打分」这个事实说清楚。
/// - 分数文本用**表格字形**（tabular）：8.0 / 10.0 / 6.5 的宽度必须一样宽，
///   否则叠在星级右侧时整列数字会轻微抖动。这条只给数字，不给中文。
class ExternalCommentsSection extends StatelessWidget {
  const ExternalCommentsSection({
    super.key,
    required this.page,
    this.mixedSources = false,
    this.loadingMore = false,
    this.onLoadMore,
  });

  final ExternalCommentPage page;

  /// 本页短评是否来自多个来源（决定徽标放标题行还是逐条放）。
  final bool mixedSources;

  /// 「加载更多」请求是否在途。
  final bool loadingMore;

  final VoidCallback? onLoadMore;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (page.isEmpty) return const SizedBox.shrink();
    return Column(
      key: const ValueKey('detail-external-comments'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          title: page.total > page.comments.length
              ? '短评（${page.comments.length}/${page.total}）'
              : '短评（${page.comments.length}）',
          // 整页同源时徽标只出现一次：每条都挂一遍「豆瓣」纯属视觉噪音，
          // 只有**混源**（以后接了第二家评论源）才需要逐条标注。
          trailing: mixedSources
              ? null
              : TagChip(
                  keyValue: 'detail-comments-source',
                  label: page.comments.first.sourceLabel,
                  icon: Icons.forum_outlined,
                ),
        ),
        for (var i = 0; i < page.comments.length; i++)
          Padding(
            // 现状是 sm；多出一条星级行后，条与条之间需要更多呼吸感。
            padding: const EdgeInsets.only(bottom: AppSpace.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _ratingLine(context, page.comments[i], i),
                const SizedBox(height: AppSpace.xs),
                Text(
                  page.comments[i].text,
                  key: ValueKey('detail-comment-text-$i'),
                  style: theme.textTheme.bodyMedium,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: AppSpace.xs),
                _metaLine(context, page.comments[i], i),
              ],
            ),
          ),
        if (page.hasMore)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey('detail-comments-more'),
              onPressed: loadingMore ? null : onLoadMore,
              icon: loadingMore
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.expand_more, size: 18),
              label: Text(loadingMore ? '加载中…' : '加载更多短评'),
            ),
          ),
      ],
    );
  }

  /// 评分行：五颗星 + 数字分数，或一行「未评分」。
  ///
  /// 读屏时这一行会念成一串「star」——因此整行只暴露一句标签
  /// （「豆瓣评分 8.0 分（满分 10）」），星形本身 ExcludeSemantics 掉。
  Widget _ratingLine(BuildContext context, ExternalComment comment, int index) {
    final theme = Theme.of(context);
    final halfStars = comment.ratingHalfStars;
    final score = comment.ratingOutOfTen.toStringAsFixed(1);
    if (halfStars == 0) {
      return Semantics(
        label: '未评分',
        container: true,
        child: ExcludeSemantics(
          child: Text(
            '未评分',
            key: ValueKey('detail-comment-unrated-$index'),
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }

    final full = halfStars ~/ 2;
    final half = halfStars.isOdd ? 1 : 0;
    final empty = 5 - full - half;
    // 星等琥珀只用在「已经拿到的那部分星」上：半星也是实心的另一半，
    // 因此与实心星同色；空星用 outline，它只是「满格 5 颗」的刻度背景。
    final filledColor = context.semanticColors.magnitude;
    return Semantics(
      label: '${comment.sourceLabel}评分 $score 分（满分 10）',
      container: true,
      child: ExcludeSemantics(
        child: Row(
          key: ValueKey('detail-comment-rating-$index'),
          mainAxisSize: MainAxisSize.min,
          spacing: 6,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 2,
              children: [
                for (var s = 0; s < full; s++)
                  Icon(Icons.star_rounded, size: 15, color: filledColor),
                for (var s = 0; s < half; s++)
                  Icon(Icons.star_half_rounded, size: 15, color: filledColor),
                for (var s = 0; s < empty; s++)
                  Icon(
                    Icons.star_outline_rounded,
                    size: 15,
                    color: theme.colorScheme.outline,
                  ),
              ],
            ),
            Text(
              score,
              key: ValueKey('detail-comment-score-$index'),
              style: tabular(
                theme.textTheme.labelLarge!,
              ).copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  /// 元信息行：作者 · N 有用 · 日期（分数不在这里，它已经在星级行上，
  /// 出现两次只会让人多看一遍）。
  Widget _metaLine(BuildContext context, ExternalComment comment, int index) {
    final theme = Theme.of(context);
    return Row(
      key: ValueKey('detail-comment-meta-$index'),
      children: [
        if (mixedSources) ...[
          TagChip(
            keyValue: 'detail-comment-source-${comment.source.key}',
            label: comment.sourceLabel,
            icon: Icons.forum_outlined,
          ),
          const SizedBox(width: AppSpace.xs),
        ],
        Expanded(
          child: Text(
            [
              if (comment.author.isNotEmpty) comment.author,
              if (comment.votes > 0) '${comment.votes} 有用',
              if (comment.date.isNotEmpty) comment.date.split(' ').first,
            ].join(' · '),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}
