import 'dart:async';

import 'package:flutter/material.dart';

import '../core/detail_recommendation.dart';
import '../core/recommendation_meta.dart';
import '../core/tmdb_identity.dart';
import '../state/detail_recommendation_state.dart';
import 'app.dart' show PosterImage;
import 'common.dart';
import 'recommendation_info_dialog.dart';
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
    this.trailing,
  });
  final DetailRecommendationDependencies dependencies;
  final RecommendationSeed current;
  final Map<String, Object?>? detail;
  final bool sourceOnly, embeddedRelated;
  final ValueChanged<TmdbItem>? onOpenItem;
  final ValueChanged<String>? onSearchTitle;

  /// 推荐行为后的附加区块（详情页用它挂 AI 推荐行）。
  ///
  /// 放在本组件内部而不是页面里拼：AI 行要占「推荐区最下方」这一格，
  /// 并且和上面三行共用同一套区块节奏（[SectionHeader] 的上 24 留白）。
  final Widget? trailing;

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

  /// 长按 / 右键：与 AI 行共用同一个详情弹窗（海报、简介、理由、详情主按钮）。
  Future<void> _info(RecommendationEntry entry) {
    final item = entry.item;
    return showRecommendationInfo(
      context,
      info: RecommendationInfo(
        title: item.title,
        sourceLabel: entry.source == RecommendationSource.douban
            ? '豆瓣'
            : 'TMDB',
        posterUrl: item.posterUrl,
        meta: [
          ...item.subtitle.split(' · ').where((part) => part.trim().isNotEmpty),
          if (entry.doubanRating > 0)
            '豆瓣 ${entry.doubanRating.toStringAsFixed(1)}',
        ],
        overview: item.overview,
        reason: entry.reason,
        credit: item.credit,
      ),
      // 与卡片单击完全一致的去向。
      onOpen: () => _open(entry),
      onNotInterested: () async =>
          widget.dependencies.feedback.block(item.title),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _state,
    builder: (context, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final row in RecommendationRow.values)
          if (_state.row(row).items.isNotEmpty || _state.row(row).hasMore)
            Offstage(
              key: ValueKey('recommendation-section-${row.name}'),
              offstage: _state.row(row).items.isEmpty,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SectionHeader(
                    title: switch (row) {
                      RecommendationRow.related => '猜你喜欢',
                      RecommendationRow.tmdb => '个性推荐·TMDB',
                      RecommendationRow.douban => '个性推荐·豆瓣',
                    },
                    keyValue: 'recommendation-heading-${row.name}',
                  ),
                  SizedBox(
                    height: detailRecommendationRowHeight(context),
                    child: _RecommendationPagination(
                      key: ObjectKey(_state.row(row)),
                      row: _state.row(row),
                      loadMore: () => _state.loadMore(row),
                      builder: (controller) => HorizontalMouseDrag(
                        child: ListView.separated(
                          controller: controller,
                          key: ValueKey('recommendation-row-${row.name}'),
                          scrollDirection: Axis.horizontal,
                          physics: const AlwaysScrollableScrollPhysics(),
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
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      ClipRRect(
                                        borderRadius: BorderRadius.circular(8),
                                        child: SizedBox(
                                          height: 180,
                                          child: PosterImage(
                                            url: item.posterUrl,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        item.title,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      Text(
                                        // 三条推荐行统一「年份 · 评分」；来源由区块
                                        // 标题承担（见 core/recommendation_meta.dart）。
                                        recommendationMeta(
                                          item.subtitle,
                                          doubanRating: entry.doubanRating,
                                        ),
                                        style: Theme.of(context)
                                            .textTheme
                                            .labelSmall,
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
                  ),
                ],
              ),
            ),
        ?widget.trailing,
      ],
    ),
  );
}

/// 推荐行的固定高度：海报 180 + 标题/元信息两行。
///
/// 详情页所有推荐行（含最下面的 AI 行）共用同一个值，行与行之间才不会
/// 因为字号/换行差出几像素。
double detailRecommendationRowHeight(BuildContext context) {
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

class _RecommendationPagination extends StatefulWidget {
  const _RecommendationPagination({
    super.key,
    required this.row,
    required this.loadMore,
    required this.builder,
  });

  final RecommendationRowState row;
  final Future<void> Function() loadMore;
  final Widget Function(ScrollController) builder;

  @override
  State<_RecommendationPagination> createState() =>
      _RecommendationPaginationState();
}

class _RecommendationPaginationState extends State<_RecommendationPagination> {
  final _controller = ScrollController();
  bool _queued = false;
  bool _deliberatePending = false;
  bool _retryAllowed = false;
  bool _autoFillBlocked = false;
  bool _requesting = false;

  void _queueLoad({bool deliberate = false}) {
    _deliberatePending |= deliberate;
    if (_queued) return;
    _queued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _queued = false;
      final deliberate = _deliberatePending;
      _deliberatePending = false;
      if (!mounted || !_controller.hasClients) return;
      final position = _controller.position;
      final row = widget.row;
      if (!position.hasContentDimensions ||
          row.loading ||
          !row.hasMore ||
          _requesting) {
        return;
      }
      if (deliberate) {
        if (position.extentAfter > 130 ||
            (row.error != null && !_retryAllowed)) {
          return;
        }
      } else if (position.maxScrollExtent > 0 ||
          row.error != null ||
          _autoFillBlocked) {
        return;
      }
      _retryAllowed = false;
      unawaited(_load());
    });
  }

  Future<void> _load() async {
    _requesting = true;
    final count = widget.row.items.length;
    await widget.loadMore();
    if (!mounted) return;
    _requesting = false;
    _autoFillBlocked = widget.row.items.length <= count;
    if (!_autoFillBlocked && widget.row.error == null) _queueLoad();
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification.depth != 0 ||
        notification.metrics.axis != Axis.horizontal) {
      return false;
    }
    if (notification is ScrollStartNotification) _retryAllowed = true;
    if (notification is ScrollUpdateNotification &&
            (notification.scrollDelta ?? 0) > 0 ||
        notification is OverscrollNotification && notification.overscroll > 0) {
      _queueLoad(deliberate: true);
    }
    return false;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _queueLoad();
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (notification) {
        if (notification.depth == 0 &&
            notification.metrics.axis == Axis.horizontal) {
          _queueLoad();
        }
        return false;
      },
      child: NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        child: widget.builder(_controller),
      ),
    );
  }
}
