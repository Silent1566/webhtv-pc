import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/ai_content/ai_content_contracts.dart';
import '../../core/ai_content/recommendation.dart';
import '../../core/tmdb_identity.dart';
import '../../services/ai_content/recommendation_service.dart';
import '../../state/app_state.dart';
import '../app.dart' show PosterImage;
import '../common.dart';
import '../detail_recommendations.dart' show detailRecommendationRowHeight;
import '../recommendation_info_dialog.dart';
import '../scroll_behavior.dart';
import '../tokens.dart';

/// 详情页推荐区**最下面一行**的 AI 推荐：缓存优先 + 需要时自动刷新。
///
/// 与「猜你喜欢 / 个性推荐·TMDB / 个性推荐·豆瓣」同一套视觉与交互：
/// - 同一个 [SectionHeader]（上 24 留白）、130 宽海报卡、同样的两行文字；
/// - 点击交给调用方的 [onOpenItem] / [onSearchTitle]——和其它推荐行走同一个
///   「有 TMDB 身份就开详情，没有就按标题搜站源」的去向；
/// - 长按 / 右键打开同样的「关闭 / 不感兴趣」弹窗，选择后从本行移除。
///
/// 数据链路保持原先的缓存策略（对齐安卓 AiRecommendationService.load）：
/// 1. 进页面先只读缓存（不联网、不花 token），有内容立即上屏；
/// 2. 再按**输入指纹**判断是否需要刷新：一致且未过期直接复用，否则后台刷新一次；
/// 3. 刷新失败保留已显示的缓存内容，只在下方给一行提示，不清空。
class AiRecommendationSection extends StatefulWidget {
  const AiRecommendationSection({
    super.key,
    required this.state,
    this.seedTitle = '',
    this.onOpenItem,
    this.onSearchTitle,
    this.title = 'AI 推荐',
  });

  final AppState state;

  /// 当前详情页的影片名；为空时按「观看历史」推荐。
  final String seedTitle;

  /// 有 TMDB 身份的推荐卡点击后的去处（与其它推荐行同一个回调）。
  final ValueChanged<TmdbItem>? onOpenItem;

  /// 没有 TMDB 身份时按标题搜索站源（与其它推荐行同一个回调）。
  final ValueChanged<String>? onSearchTitle;

  /// 区块标题。带来源前缀，避免和其它推荐行的「推荐」混淆。
  final String title;

  @override
  State<AiRecommendationSection> createState() => _AiRecommendationSectionState();
}

class _AiRecommendationSectionState extends State<AiRecommendationSection> {
  List<RecommendationCard> _cards = const [];
  AiContentCancellation? _cancellation;
  bool _loading = false;
  String _message = '';
  int _run = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_bootstrap());
  }

  @override
  void didUpdateWidget(covariant AiRecommendationSection old) {
    super.didUpdateWidget(old);
    // 换作品＝换上下文：旧请求作废，重新走「缓存优先 + 刷新」。
    if (old.seedTitle != widget.seedTitle) {
      _run++;
      _cancellation?.cancel();
      _cards = const [];
      _message = '';
      unawaited(_bootstrap());
    }
  }

  @override
  void dispose() {
    _cancellation?.cancel();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    if (!widget.state.aiReady) return;
    final request = _request();
    RecommendationCacheLookup lookup;
    try {
      lookup = await widget.state.aiIntegration.recommendation.loadCached(
        request: request,
      );
    } catch (_) {
      lookup = RecommendationCacheLookup.empty;
    }
    if (!mounted) return;
    if (lookup.hasItems) {
      setState(() => _cards = lookup.cards);
    }
    // 指纹一致且缓存新鲜：直接用缓存，不发起付费调用（省 token）。
    if (!lookup.needsRefresh) return;
    await _refresh(request);
  }

  Future<void> _refresh(RecommendationRequest request) async {
    final run = ++_run;
    final cancellation = AiContentCancellation();
    _cancellation = cancellation;
    setState(() {
      _loading = true;
      _message = '';
    });
    final result = await widget.state.aiIntegration.recommendation.recommend(
      request: request,
      cancellation: cancellation,
    );
    if (!mounted || run != _run) return;
    setState(() {
      _loading = false;
      if (result.ok) {
        _cards = result.value ?? const [];
      } else if (!result.cancelled) {
        // 失败不清空：保留缓存内容，只提示失败原因。
        _message = result.message;
      } else {
        _message = '已取消刷新';
      }
    });
  }

  RecommendationRequest _request() {
    final state = widget.state;
    final mediaType = state.tmdb.identity?.mediaType.name == 'movie'
        ? RecommendationMediaType.movie
        : RecommendationMediaType.tv;
    return RecommendationRequest(
      source: widget.seedTitle.isEmpty
          ? RecommendationSource.history
          : RecommendationSource.current,
      siteKey: state.selectedSite?.key ?? '',
      seed: widget.seedTitle.isEmpty
          ? null
          : WatchContextItem(title: widget.seedTitle, mediaType: mediaType),
      contexts: [
        for (final row in state.recentHistory(limit: 24))
          WatchContextItem(
            title: row.vodName,
            mediaType: row.mediaType == 'movie'
                ? RecommendationMediaType.movie
                : RecommendationMediaType.tv,
            year: int.tryParse(row.vodYear),
            lastWatchedAtMs: row.updatedAt,
            sourceLabel: row.siteKey,
          ),
      ],
    );
  }

  /// 与其它推荐行同一套去向：有 TMDB 身份开详情，没有就按标题搜站源。
  void _open(RecommendationCard card) {
    final open = widget.onOpenItem;
    final tmdbId = card.tmdbId;
    if (tmdbId != null && open != null) {
      open(
        TmdbItem(
          tmdbId: tmdbId,
          mediaType: card.mediaType == RecommendationMediaType.movie
              ? TmdbMediaType.movie
              : TmdbMediaType.tv,
          title: card.title,
          subtitle: _meta(card),
          overview: card.overview,
          posterUrl: card.posterUrl,
          rating: card.rating ?? 0,
        ),
      );
      return;
    }
    widget.onSearchTitle?.call(card.title);
  }

  /// 长按 / 右键：与其它推荐行共用同一个详情弹窗。
  ///
  /// 「不感兴趣」在按下的同一帧就发起写入（不等弹窗 future 回来）：
  /// 负反馈是真实文件 IO，与旧实现的时序保持一致。
  Future<void> _info(RecommendationCard card) {
    return showRecommendationInfo(
      context,
      info: RecommendationInfo(
        title: card.title,
        sourceLabel: 'AI 推荐',
        posterUrl: card.posterUrl,
        meta: _metaParts(card),
        overview: card.overview,
        reason: card.reason,
        status: _status(card),
      ),
      // 与卡片单击完全一致的去向。
      onOpen: () => _open(card),
      onNotInterested: () => _notInterested(card),
    );
  }

  Future<void> _notInterested(RecommendationCard card) async {
    final result = await widget.state.aiIntegration.recommendation
        .markNotInterested(card);
    if (!mounted) return;
    setState(() {
      _cards = _cards.where((item) => item.title != card.title).toList();
      if (!result.ok) _message = result.message;
    });
  }

  static List<String> _metaParts(RecommendationCard card) => [
    if (card.year != null) card.year!.toString(),
    card.mediaType.label,
    if (card.rating != null && card.rating! > 0)
      '评分 ${card.rating!.toStringAsFixed(1)}',
  ];

  /// 卡片副信息：只留 `年份 · 评分`（与详情页其它推荐行一致）。
  ///
  /// 类型（剧集/电影）与「评分」二字在卡片上属于冗余——区块标题已经说明
  /// 这是「AI 推荐」，相邻两行也都只写「年份 · 分数」。
  /// 详情弹窗仍用 [_metaParts] 的完整口径。
  static String _meta(RecommendationCard card) => [
    if (card.year != null) '${card.year}',
    if (card.rating != null && card.rating! > 0)
      card.rating!.toStringAsFixed(1),
  ].join(' · ');

  /// 数据状态：只描述本端**已经拿到**的事实，不额外查询。
  static String? _status(RecommendationCard card) {
    if (card.degraded) return '仅元数据（未匹配 TMDB）';
    final id = card.tmdbId;
    return id == null || id <= 0 ? null : 'TMDB #$id';
  }

  @override
  Widget build(BuildContext context) {
    // 未配置 AI：整块不渲染，也不发任何请求。
    if (!widget.state.aiReady) return const SizedBox.shrink();
    // 与其它推荐行一致：没有内容就不占位（生成中只留一行提示）。
    if (_cards.isEmpty && !_loading && _message.isEmpty) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    return Column(
      key: const ValueKey('recommendation-section-ai'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(
          title: widget.title,
          keyValue: 'recommendation-heading-ai',
        ),
        if (_cards.isEmpty && _loading)
          Text(
            '正在生成推荐…',
            key: const ValueKey('recommendation-ai-loading'),
            style: theme.textTheme.labelSmall,
          ),
        if (_cards.isNotEmpty)
          SizedBox(
            height: detailRecommendationRowHeight(context),
            child: HorizontalMouseDrag(
              child: ListView.separated(
                key: const ValueKey('recommendation-row-ai'),
                scrollDirection: Axis.horizontal,
                physics: const AlwaysScrollableScrollPhysics(),
                itemCount: _cards.length,
                separatorBuilder: (_, _) => const SizedBox(width: 10),
                itemBuilder: (context, index) {
                  final card = _cards[index];
                  return SizedBox(
                    width: 130,
                    child: GestureDetector(
                      onSecondaryTap: () => _info(card),
                      child: InkWell(
                        key: ValueKey('recommendation-ai-${card.title}'),
                        onTap: () => _open(card),
                        onLongPress: () => _info(card),
                        borderRadius: BorderRadius.circular(8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: SizedBox(
                                height: 180,
                                child: PosterImage(url: card.posterUrl),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              card.title,
                              style: theme.textTheme.bodySmall,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              _meta(card),
                              style: theme.textTheme.labelSmall,
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
        if (_message.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: AppSpace.xs),
            child: Text(
              _message,
              key: const ValueKey('recommendation-ai-message'),
              style: theme.textTheme.labelSmall,
            ),
          ),
      ],
    );
  }
}
