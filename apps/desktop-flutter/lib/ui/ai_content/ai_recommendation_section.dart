import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/ai_content/ai_content_contracts.dart';
import '../../services/ai_content/recommendation_service.dart';
import '../../core/ai_content/recommendation.dart';
import '../../state/app_state.dart';
import '../ai_integration_widgets.dart' show aiSearchRouteHost;
import '../app.dart' show PosterImage;
import 'ai_recommendation_detail_dialog.dart';
import '../scroll_behavior.dart';
import '../tokens.dart';

/// 详情页的 AI 推荐区块：**缓存优先 + 异步刷新**。
///
/// 与安卓 `TmdbDetailActivity` + `AiRecommendationService.load/loadCached`
/// 同一条链路：
/// 1. 进页面先只读缓存（不联网、不花 token），有内容立即上屏（旧内容带「缓存」标记）；
/// 2. 然后按**输入指纹**判断是否需要刷新——指纹一致且未过期就直接复用，
///    否则后台刷新一次，成功后原地替换；
/// 3. 刷新失败保留已显示的缓存内容，只在下方给一行提示，不清空。
class AiRecommendationSection extends StatefulWidget {
  const AiRecommendationSection({
    super.key,
    required this.state,
    this.seedTitle = '',
    this.title = 'AI 推荐',
  });

  final AppState state;

  /// 当前详情页的影片名；为空时按「观看历史」推荐。
  final String seedTitle;

  /// 区块标题。后续会接入其它来源的推荐，所以标题带来源前缀，
  /// 不能写成笼统的「推荐」。
  final String title;

  @override
  State<AiRecommendationSection> createState() => _AiRecommendationSectionState();
}

class _AiRecommendationSectionState extends State<AiRecommendationSection> {
  List<RecommendationCard> _cards = const [];
  AiContentCancellation? _cancellation;
  bool _loading = false;
  bool _stale = false;
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
    // 换作品＝换上下文：旧请求作废，重新走"缓存优先 + 刷新"。
    if (old.seedTitle != widget.seedTitle) {
      _run++;
      _cancellation?.cancel();
      _cards = const [];
      _stale = false;
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
      setState(() {
        _cards = lookup.cards;
        _stale = lookup.needsRefresh;
      });
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
        _stale = false;
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

  Future<void> _open(RecommendationCard card) async {
    final outcome = await widget.state.searchRecommendation(card.title);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => aiSearchRouteHost(widget.state, card.title),
      ),
    );
    if (!mounted) return;
    if (outcome == null) setState(() => _message = '当前未配置可搜索站点');
  }

  /// 长按/右键：显示详细推荐理由与简介（对齐安卓 `AiRecommendationInfoDialog`）。
  Future<void> _showDetails(RecommendationCard card) => showAiRecommendationDetails(
    context,
    card: card,
    sourceLabel: 'AI 推荐',
    onNotInterested: () => _notInterested(card),
  );

  Future<void> _notInterested(RecommendationCard card) async {
    final result = await widget.state.aiIntegration.recommendation
        .markNotInterested(card);
    if (!mounted) return;
    setState(() {
      _cards = _cards.where((item) => item.title != card.title).toList();
      if (!result.ok) _message = result.message;
    });
  }

  @override
  Widget build(BuildContext context) {
    // 未配置 AI：整块不渲染，也不发任何请求（保持已有播放与手动路径）。
    if (!widget.state.aiReady) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Column(
      key: const ValueKey('ai-detail-recommendations'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              widget.title,
              key: const ValueKey('ai-detail-recommendations-title'),
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(width: AppSpace.sm),
            if (_stale)
              Text(
                '缓存',
                key: const ValueKey('ai-detail-recommendations-stale'),
                style: theme.textTheme.bodySmall,
              ),
            const Spacer(),
            if (_loading)
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
          ],
        ),
        const SizedBox(height: AppSpace.sm),
        if (_cards.isEmpty && _loading)
          Text(
            '正在生成推荐…',
            key: const ValueKey('ai-detail-recommendations-loading'),
            style: theme.textTheme.bodySmall,
          ),
        if (_cards.isNotEmpty)
          SizedBox(
            // 海报 2:3（160×240）+ 标题/元信息/理由两行。
            height: 330,
            child: HorizontalMouseDrag(
              child: ListView.separated(
                key: const ValueKey('ai-detail-recommendations-strip'),
                scrollDirection: Axis.horizontal,
                itemCount: _cards.length,
                separatorBuilder: (_, _) => const SizedBox(width: AppSpace.md),
                itemBuilder: (context, index) {
                  final card = _cards[index];
                  return _AiRecommendationPosterCard(
                    key: ValueKey('ai-detail-recommendation-${card.title}'),
                    card: card,
                    onOpen: () => _open(card),
                    onNotInterested: () => _notInterested(card),
                    onShowDetails: () => _showDetails(card),
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
              key: const ValueKey('ai-detail-recommendations-message'),
              style: theme.textTheme.bodySmall,
            ),
          ),
      ],
    );
  }
}

/// 横向海报卡：与详情页其它「相关推荐」条一致（可左右拖/滚），
/// 右侧角标提供"不感兴趣"，标题/元信息/理由各占固定行数避免高度跳动。
class _AiRecommendationPosterCard extends StatelessWidget {
  const _AiRecommendationPosterCard({
    super.key,
    required this.card,
    this.onOpen,
    this.onNotInterested,
    this.onShowDetails,
  });

  final RecommendationCard card;
  final VoidCallback? onOpen;
  final VoidCallback? onNotInterested;

  /// 长按 / 右键打开详情（安卓的长按效果）。
  final VoidCallback? onShowDetails;

  static const double _posterWidth = 160;
  static const double _posterHeight = 240;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final meta = [
      if (card.year != null) '${card.year}',
      card.mediaType.label,
      if (card.rating != null) '评分 ${card.rating!.toStringAsFixed(1)}',
    ].join(' · ');
    return SizedBox(
      width: _posterWidth,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Stack(
            children: [
              GestureDetector(
                // PC 上"长按"= 按住不放；右键是桌面端更顺手的等价入口。
                onLongPress: onShowDetails,
                onSecondaryTap: onShowDetails,
                child: InkWell(
                  onTap: onOpen,
                  borderRadius: BorderRadius.circular(8),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: PosterImage(
                      url: card.posterUrl,
                      width: _posterWidth,
                      height: _posterHeight,
                      cacheWidth: 320,
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 0,
                right: 0,
                child: IconButton(
                  key: ValueKey('ai-detail-recommendation-hide-${card.title}'),
                  tooltip: '不感兴趣',
                  iconSize: 18,
                  visualDensity: VisualDensity.compact,
                  onPressed: onNotInterested,
                  icon: const Icon(Icons.thumb_down_outlined),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            card.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall,
          ),
          const SizedBox(height: 2),
          Text(
            meta,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
          if (card.reason.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              card.reason,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }
}