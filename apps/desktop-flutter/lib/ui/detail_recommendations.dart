import 'dart:async';

import 'package:flutter/material.dart';

import '../core/detail_recommendation.dart';
import '../core/tmdb_identity.dart';
import '../state/detail_recommendation_state.dart';
import 'app.dart' show PosterImage;
import 'common.dart';
import 'scroll_behavior.dart';

class DetailRecommendations extends StatefulWidget {
  const DetailRecommendations({
    super.key,
    required this.dependencies,
    required this.current,
    this.detail,
    this.sourceOnly = false,
    this.embeddedRelated = false,
    this.onOpenItem,
    this.onSearchTitle,
  });
  final DetailRecommendationDependencies dependencies;
  final RecommendationSeed current;
  final Map<String, Object?>? detail;
  final bool sourceOnly, embeddedRelated;
  final ValueChanged<TmdbItem>? onOpenItem;
  final ValueChanged<String>? onSearchTitle;
  @override
  State<DetailRecommendations> createState() => _DetailRecommendationsState();
}

class _DetailRecommendationsState extends State<DetailRecommendations> {
  late DetailRecommendationState _state;
  @override
  void initState() {
    super.initState();
    _attach();
  }

  void _attach() {
    _state = DetailRecommendationState(
      loaders: widget.dependencies.acquire(),
      feedback: widget.dependencies.feedback,
    );
    widget.dependencies.historyChanges?.addListener(_refresh);
    _refresh();
  }

  void _refresh() {
    unawaited(
      _state.refresh(
        current: widget.current,
        history: widget.dependencies.history(),
        detail: widget.detail,
        sourceOnly: widget.sourceOnly,
        embeddedRelated: widget.embeddedRelated,
      ),
    );
  }

  @override
  void didUpdateWidget(covariant DetailRecommendations oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.dependencies != widget.dependencies) {
      oldWidget.dependencies.historyChanges?.removeListener(_refresh);
      _state.dispose();
      oldWidget.dependencies.release();
      _attach();
    } else {
      _refresh();
    }
  }

  @override
  void dispose() {
    widget.dependencies.historyChanges?.removeListener(_refresh);
    _state.dispose();
    widget.dependencies.release();
    super.dispose();
  }

  void _open(RecommendationEntry entry) {
    if (entry.item.identity != null) {
      widget.onOpenItem?.call(entry.item);
    } else {
      widget.onSearchTitle?.call(entry.item.title);
    }
  }

  Future<void> _info(RecommendationEntry entry) async {
    final block = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(entry.item.title),
        content: Text(
          [
            '来源：${entry.source == RecommendationSource.douban ? '豆瓣' : 'TMDB'}',
            if (entry.reason.isNotEmpty) '推荐说明：${entry.reason}',
            if (entry.item.rating > 0)
              '评分：${entry.item.rating.toStringAsFixed(1)}',
            if (entry.doubanRating > 0)
              '豆瓣评分：${entry.doubanRating.toStringAsFixed(1)}',
          ].join('\n'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('关闭'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('不感兴趣'),
          ),
        ],
      ),
    );
    if (block == true && mounted) {
      widget.dependencies.feedback.block(entry.item.title);
    }
  }

  double _rowHeight(BuildContext context) {
    final theme = Theme.of(context);
    double lineHeight(TextStyle? style) {
      final painter = TextPainter(
        text: TextSpan(text: '国', style: style),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      )..layout();
      final height = painter.height;
      painter.dispose();
      return height;
    }

    return (188 +
            lineHeight(theme.textTheme.bodySmall) +
            lineHeight(theme.textTheme.labelSmall))
        .clamp(218.0, double.infinity)
        .ceilToDouble();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _state,
    builder: (context, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final row in RecommendationRow.values)
          if (_state.row(row).items.isNotEmpty) ...[
            SectionHeader(
              title: switch (row) {
                RecommendationRow.related => '猜你喜欢',
                RecommendationRow.tmdb => '个性推荐·TMDB',
                RecommendationRow.douban => '个性推荐·豆瓣',
              },
              keyValue: 'recommendation-heading-${row.name}',
            ),
            SizedBox(
              height: _rowHeight(context),
              child: HorizontalMouseDrag(
                child: ListView.separated(
                  key: ValueKey('recommendation-row-${row.name}'),
                  scrollDirection: Axis.horizontal,
                  itemCount: _state.row(row).items.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 10),
                  itemBuilder: (context, index) {
                    final entry = _state.row(row).items[index];
                    final item = entry.item;
                    return SizedBox(
                      width: 130,
                      child: GestureDetector(
                        onSecondaryTap: () => _info(entry),
                        child: InkWell(
                          key: ValueKey(
                            'recommendation-${row.name}-${recommendationRowKey(row, entry)}',
                          ),
                          onTap: () => _open(entry),
                          onLongPress: () => _info(entry),
                          borderRadius: BorderRadius.circular(8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: SizedBox(
                                  height: 180,
                                  child: PosterImage(url: item.posterUrl),
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                item.title,
                                style: Theme.of(context).textTheme.bodySmall,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              Text(
                                entry.source == RecommendationSource.douban &&
                                        entry.doubanRating > 0
                                    ? '豆瓣 ${entry.doubanRating.toStringAsFixed(1)}'
                                    : item.subtitle,
                                style: Theme.of(context).textTheme.labelSmall,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
            if (_state.row(row).hasMore)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  key: ValueKey('recommendation-more-${row.name}'),
                  onPressed: _state.row(row).loading
                      ? null
                      : () => _state.loadMore(row),
                  child: Text(_state.row(row).loading ? '加载中…' : '加载更多'),
                ),
              ),
            const SizedBox(height: 16),
          ],
      ],
    ),
  );
}
