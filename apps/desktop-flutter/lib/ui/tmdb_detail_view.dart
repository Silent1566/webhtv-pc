/// TMDB 详情页视图（`docs/phase4/design/04` §3、§6、§11）。
///
/// 这是**站点详情页**与**纯 TMDB 详情页**共用的渲染层：
///
/// ```text
/// ┌ 动态背景（剧集海报/剧照轮播 + 渐变遮罩）────────────────────┐
/// │ [海报] 标题 / 原名 / 标语                                    │
/// │        评分 · 年份 · 时长 · 季集数 · 类型 · 地区              │
/// │        导演：…                                               │
/// │        简介（折叠 + 展开）                                    │
/// ├ 季度（海报卡片 + 集数）──────────────────────────────────────┤
/// ├ 剧集（每集一张海报卡片：剧照 + 标题 + 播出日期）───────────────┤
/// ├ 剧照墙（点击 → 大图查看器，可翻页）───────────────────────────┤
/// ├ 演职人员（点击 → 人物页：简介 / 照片 / 作品）──────────────────┤
/// ├ 相关推荐（点击 → 进入该作品详情）─────────────────────────────┤
/// └ 相关视频（浏览器打开 / 复制链接）─────────────────────────────┘
/// ```
///
/// 关键约束：
/// - 纯 TMDB 详情页的剧集卡片**不得**显示为可播放（`04` §6.2）；
///   由调用方通过 [TmdbDetailView.episodeActionLabel] 与 [onEpisodeTap] 决定行为；
/// - 失败隔离：任一区块为空时整块隐藏，不留空态占位（`04` §3.4）；
/// - 深色模式使用 `Theme.of(context)` 语义色，不硬编码颜色（`04` §11）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;

import '../core/app_error.dart';
import '../core/tmdb_detail_model.dart';
import '../core/tmdb_identity.dart';
import '../core/tmdb_media.dart';
import '../services/tmdb_service.dart';
import 'app.dart' show PosterImage;
import 'tmdb_widgets.dart' show TmdbLoadPhase, TmdbVideoTile;

/// 动态背景轮播（`04` §3.1：用剧集海报/剧照当动态背景）。
///
/// 节奏与上游 `TmdbHeaderView` 一致（5 秒一张）。**只有一张图时不启动轮播**，
/// 且仅在「当前路由 + TickerMode 启用」时运行——页面被覆盖或不可见时停止，
/// 既不浪费解码，也避免测试里的无限帧调度。
class TmdbBackdropSlideshow extends StatefulWidget {
  const TmdbBackdropSlideshow({
    super.key,
    required this.urls,
    this.height = 320,
    this.interval = TmdbBackdropRotation.interval,
    this.fallbackUrl,
    this.child,
  });

  final List<String> urls;
  final double height;
  final Duration interval;

  /// 无背景图时使用的兜底图（通常是海报）。
  final String? fallbackUrl;

  /// 覆盖在背景之上的内容（标题、简介等）。
  final Widget? child;

  @override
  State<TmdbBackdropSlideshow> createState() => _TmdbBackdropSlideshowState();
}

class _TmdbBackdropSlideshowState extends State<TmdbBackdropSlideshow> {
  Timer? _timer;
  int _index = 0;

  List<String> get _effective {
    if (widget.urls.isNotEmpty) return widget.urls;
    final fallback = widget.fallbackUrl;
    if (fallback != null && fallback.isNotEmpty) return [fallback];
    return const [];
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncTimer();
  }

  @override
  void didUpdateWidget(TmdbBackdropSlideshow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.urls != widget.urls) {
      _index = 0;
    }
    _syncTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }

  void _syncTimer() {
    final route = ModalRoute.of(context);
    final isCurrent = route?.isCurrent ?? true;
    // `TickerMode.valuesOf` 同时给出 enabled 与 forceFrames（`of` 已废弃）。
    final animationsEnabled = TickerMode.valuesOf(context).enabled;
    final shouldRun =
        TmdbBackdropRotation.shouldRotate(_effective.length) &&
        isCurrent &&
        animationsEnabled;
    if (!shouldRun) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    _timer ??= Timer.periodic(widget.interval, (_) {
      if (!mounted) return;
      final urls = _effective;
      if (!TmdbBackdropRotation.shouldRotate(urls.length)) {
        _timer?.cancel();
        _timer = null;
        return;
      }
      setState(() => _index = TmdbBackdropRotation.next(_index, urls.length));
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final urls = _effective;
    final index = TmdbBackdropRotation.clamp(_index, urls.length);
    final current = index < 0 ? null : urls[index];
    return SizedBox(
      key: const ValueKey('tmdb-backdrop-slideshow'),
      height: widget.height,
      width: double.infinity,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 背景图：切换时淡入淡出（对齐上游「加载完成后切换」）。
          //
          // 必须用 `SizedBox.expand` 包住：`AnimatedSwitcher` 以**宽松约束**
          // 布局子节点，`Image.network` 在宽高均为 null 时会退回图片固有尺寸
          // （实测 160x160 的小方块居中，背景不铺满）。
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 600),
            child: current == null
                ? SizedBox.expand(
                    key: const ValueKey('tmdb-backdrop-empty'),
                    child: ColoredBox(
                      color: theme.colorScheme.surfaceContainerHighest,
                    ),
                  )
                : SizedBox.expand(
                    key: ValueKey('tmdb-backdrop-$index'),
                    child: PosterImage(url: current, fit: BoxFit.cover),
                  ),
          ),
          // 渐变遮罩：保证文字在任何图片上都可读（不依赖图片亮度）。
          //
          // 上半部刻意保留较低不透明度（0.42）：用户要求「用剧集海报/剧照当动态
          // 背景」，遮罩太厚就把背景彻底洗成一片纯色，等于没有背景。
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  theme.colorScheme.surface.withValues(alpha: 0.42),
                  theme.colorScheme.surface.withValues(alpha: 0.55),
                  theme.colorScheme.surface.withValues(alpha: 0.82),
                  theme.colorScheme.surface,
                ],
                stops: const [0, 0.35, 0.68, 1],
              ),
            ),
          ),
          if (widget.child != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
              // 内容贴底对齐：动态背景在上方露出更多画面，
              // 标题/海报靠近信息区，视觉上不会出现「背景里飘着一小块内容」。
              child: Align(
                alignment: Alignment.bottomLeft,
                child: widget.child,
              ),
            ),
          if (TmdbBackdropRotation.shouldRotate(urls.length))
            Positioned(
              right: 16,
              bottom: 10,
              child: Row(
                key: const ValueKey('tmdb-backdrop-dots'),
                children: [
                  for (var i = 0; i < urls.length; i++)
                    Container(
                      width: 6,
                      height: 6,
                      margin: const EdgeInsets.only(left: 4),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: i == index
                            ? theme.colorScheme.primary
                            : theme.colorScheme.onSurface.withValues(
                                alpha: 0.3,
                              ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// 详情页头部：动态背景（剧集海报/剧照轮播）+ 标题/评分/导演/简介。
///
/// 站点详情页与纯 TMDB 详情页共用；[statusBar] 用于插入站点页的 TMDB 6 态状态条。
class TmdbDetailHeader extends StatelessWidget {
  const TmdbDetailHeader({
    super.key,
    required this.data,
    this.statusBar,
    this.metadataBadge,
    this.height = 340,
  });

  final TmdbDetailData data;
  final Widget? statusBar;
  final String? metadataBadge;
  final double height;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      ?statusBar,
      TmdbBackdropSlideshow(
        urls: data.backdropUrls,
        fallbackUrl: data.posterUrl,
        height: height,
        child: _HeaderContent(data: data, metadataBadge: metadataBadge),
      ),
    ],
  );
}

/// 详情页附加区块（剧照墙 / 演职人员 / 相关推荐 / 相关视频 / 制作团队）。
///
/// 每个区块在数据为空时**整块隐藏**（`04` §3.4），不留空态占位。
class TmdbDetailSections extends StatelessWidget {
  const TmdbDetailSections({
    super.key,
    required this.data,
    this.recommendations = const [],
    this.videos = const [],
    this.onPersonTap,
    this.onRecommendationTap,
    this.onOpenVideo,
    this.onCopyVideo,
  });

  final TmdbDetailData data;
  final List<TmdbItem> recommendations;
  final List<TmdbVideo> videos;
  final ValueChanged<TmdbPerson>? onPersonTap;
  final ValueChanged<TmdbItem>? onRecommendationTap;
  final Future<bool> Function(String url)? onOpenVideo;
  final Future<void> Function(String url)? onCopyVideo;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (data.photoUrls.isNotEmpty) ...[
          _SectionHeader(
            title: '剧照（${data.photoUrls.length}）',
            keyValue: 'tmdb-section-photos',
          ),
          _PhotoWall(urls: data.photoUrls, title: data.title),
          const SizedBox(height: 16),
        ],
        if (data.allPeople.isNotEmpty || data.directors.isNotEmpty) ...[
          _SectionHeader(
            title: '演职人员（${data.allPeople.length}）',
            keyValue: 'tmdb-section-people',
          ),
          _PeopleWall(
            people: data.allPeople.take(20).toList(),
            onTap: onPersonTap,
          ),
          const SizedBox(height: 16),
        ],
        if (recommendations.isNotEmpty) ...[
          _SectionHeader(
            title: '相关推荐（${recommendations.length}）',
            keyValue: 'tmdb-section-recommendations',
          ),
          _RecommendationWall(
            items: recommendations,
            onTap: onRecommendationTap,
          ),
          const SizedBox(height: 16),
        ],
        if (videos.isNotEmpty) ...[
          _SectionHeader(
            title: '相关视频（${videos.length}）',
            keyValue: 'tmdb-section-videos',
          ),
          for (final video in videos.take(8))
            TmdbVideoTile(
              video: video,
              onOpen: onOpenVideo,
              onCopy: onCopyVideo,
            ),
          const SizedBox(height: 16),
        ],
        if (data.crew.isNotEmpty) ...[
          _SectionHeader(
            title: '制作团队（${data.crew.length}）',
            keyValue: 'tmdb-section-crew',
          ),
          _CrewGrid(crew: data.crew.take(24).toList()),
        ],
      ],
    );
  }
}

/// 一条线路的**剧集海报卡片**条（横向滚动）。
///
/// 站点详情页在剧集按钮之上渲染它，使「每集都有对应的海报卡片」（用户反馈 1）。
/// 卡片数量恒等于线路剧集数（不补集、不丢集）。
class TmdbEpisodeStrip extends StatelessWidget {
  const TmdbEpisodeStrip({
    super.key,
    required this.cards,
    this.keyPrefix = 'tmdb-episode-card',
    this.actionLabel = '播放',
    this.onTap,
  });

  final List<TmdbEpisodeCard> cards;
  final String keyPrefix;
  final String actionLabel;
  final void Function(int index, TmdbEpisodeCard card)? onTap;

  @override
  Widget build(BuildContext context) {
    if (cards.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 196,
      child: ListView.separated(
        key: ValueKey('$keyPrefix-strip'),
        scrollDirection: Axis.horizontal,
        itemCount: cards.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, index) => SizedBox(
          width: 260,
          child: TmdbEpisodeCardTile(
            buttonKey: ValueKey('$keyPrefix-$index'),
            stillKey: ValueKey('$keyPrefix-still-${cards[index].number}'),
            card: cards[index],
            actionLabel: actionLabel,
            onTap: onTap == null
                ? null
                : () => onTap!.call(index, cards[index]),
          ),
        ),
      ),
    );
  }
}

/// 详情页主体（站点页与纯 TMDB 页共用）。
class TmdbDetailView extends StatelessWidget {
  const TmdbDetailView({
    super.key,
    required this.data,
    this.episodeCards = const [],
    this.recommendations = const [],
    this.videos = const [],
    this.seasons = const [],
    this.selectedSeason = -1,
    this.selectableSeasons = const [],
    this.onSeasonChanged,
    this.onSelectSeason,
    this.seasonKeyPrefix = 'tmdb-season-card',
    this.episodeKeyPrefix = 'tmdb-episode-card',
    this.episodeActionLabel = '播放',
    this.onEpisodeTap,
    this.onPersonTap,
    this.onRecommendationTap,
    this.onOpenVideo,
    this.onCopyVideo,
    this.statusBar,
    this.metadataBadge,
    this.padding = const EdgeInsets.all(16),
  });

  final TmdbDetailData data;
  final List<TmdbEpisodeCard> episodeCards;
  final List<TmdbItem> recommendations;
  final List<TmdbVideo> videos;

  /// 展示用季度（含海报）；为空时不渲染季度区块。
  final List<TmdbSeasonInfo> seasons;

  /// 当前选中的季度（`-1` 表示未确定）。
  final int selectedSeason;

  /// 可切换的季度号；为空但 [seasons] 非空时只展示不可切换。
  final List<int> selectableSeasons;
  final ValueChanged<int>? onSeasonChanged;

  /// 「选择季度」入口（未确定季度时，`04` §4.1）。
  final VoidCallback? onSelectSeason;

  /// 季度卡片的 key 前缀（纯 TMDB 页用 `tmdb-only-season`）。
  final String seasonKeyPrefix;
  final String episodeKeyPrefix;

  /// 剧集卡片的动作文案（`播放` / `搜索站源`）；空串表示无动作。
  final String episodeActionLabel;
  final void Function(int index, TmdbEpisodeCard card)? onEpisodeTap;
  final ValueChanged<TmdbPerson>? onPersonTap;
  final ValueChanged<TmdbItem>? onRecommendationTap;
  final Future<bool> Function(String url)? onOpenVideo;
  final Future<void> Function(String url)? onCopyVideo;

  /// 状态条（站点页的 TMDB 6 态状态条）插入在头部之上。
  final Widget? statusBar;

  /// 元数据徽标（纯 TMDB 页的「元数据季度 · 不可直接播放」）。
  final String? metadataBadge;

  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TmdbDetailHeader(
          data: data,
          statusBar: statusBar,
          metadataBadge: metadataBadge,
        ),
        Padding(
          padding: padding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (data.overview != null && data.overview!.trim().isNotEmpty)
                _ExpandableText(
                  key: const ValueKey('tmdb-detail-overview'),
                  title: '简介',
                  text: data.overview!.trim(),
                ),
              if (_seasonSectionVisible) ...[
                const SizedBox(height: 16),
                _SectionHeader(
                  title: '季度',
                  keyValue: 'tmdb-section-seasons',
                  trailing: selectedSeason < 0 && onSelectSeason != null
                      ? TextButton(
                          key: const ValueKey('tmdb-choose-season'),
                          onPressed: onSelectSeason,
                          child: const Text('选择季度'),
                        )
                      : null,
                ),
                SizedBox(
                  height: 214,
                  child: ListView.separated(
                    key: const ValueKey('tmdb-season-strip'),
                    scrollDirection: Axis.horizontal,
                    itemCount: seasons.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 10),
                    itemBuilder: (context, index) {
                      final season = seasons[index];
                      final selectable = selectableSeasons.contains(
                        season.number,
                      );
                      return _SeasonCard(
                        key: ValueKey('$seasonKeyPrefix-${season.number}'),
                        season: season,
                        selected: season.number == selectedSeason,
                        selectable: selectable && onSeasonChanged != null,
                        onTap: selectable && onSeasonChanged != null
                            ? () => onSeasonChanged!.call(season.number)
                            : null,
                      );
                    },
                  ),
                ),
              ],
              const SizedBox(height: 16),
              _SectionHeader(
                title: episodeCards.isEmpty
                    ? '剧集'
                    : '剧集（${episodeCards.length}）',
                keyValue: 'tmdb-section-episodes',
              ),
              if (episodeCards.isEmpty)
                Text(
                  '没有可展示的剧集',
                  key: const ValueKey('tmdb-episodes-empty'),
                  style: theme.textTheme.bodyMedium,
                )
              else
                GridView.builder(
                  key: const ValueKey('tmdb-episode-grid'),
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 260,
                    mainAxisExtent: 196,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                  ),
                  itemCount: episodeCards.length,
                  itemBuilder: (context, index) => TmdbEpisodeCardTile(
                    buttonKey: ValueKey('$episodeKeyPrefix-$index'),
                    card: episodeCards[index],
                    actionLabel: episodeActionLabel,
                    onTap: onEpisodeTap == null
                        ? null
                        : () => onEpisodeTap!.call(index, episodeCards[index]),
                  ),
                ),
              if (data.photoUrls.isNotEmpty ||
                  data.allPeople.isNotEmpty ||
                  recommendations.isNotEmpty ||
                  videos.isNotEmpty ||
                  data.crew.isNotEmpty)
                TmdbDetailSections(
                  data: data,
                  recommendations: recommendations,
                  videos: videos,
                  onPersonTap: onPersonTap,
                  onRecommendationTap: onRecommendationTap,
                  onOpenVideo: onOpenVideo,
                  onCopyVideo: onCopyVideo,
                ),
            ],
          ),
        ),
      ],
    );
  }

  bool get _seasonSectionVisible =>
      seasons.isNotEmpty && (data.isTv || selectedSeason >= 0);
}

// ---------------------------------------------------------------------------
// 头部
// ---------------------------------------------------------------------------

class _HeaderContent extends StatelessWidget {
  const _HeaderContent({required this.data, this.metadataBadge});

  final TmdbDetailData data;
  final String? metadataBadge;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 720;
        final poster = ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: SizedBox(
            key: const ValueKey('tmdb-detail-poster'),
            width: 150,
            height: 225,
            child: PosterImage(url: data.posterUrl),
          ),
        );
        final info = Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                data.title,
                key: const ValueKey('tmdb-detail-title'),
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              if (data.originalTitle.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  data.originalTitle,
                  style: theme.textTheme.bodySmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              if (data.tagline.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  data.tagline,
                  key: const ValueKey('tmdb-detail-tagline'),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontStyle: FontStyle.italic,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              const SizedBox(height: 10),
              _MetaChips(
                data: data,
                metadataBadge: metadataBadge,
                // 固定高度区域（动态背景 340px）内必须限制行数，否则窄窗口
                // 下 chips 换行会把标题挤出可视区并触发 overflow。
                maxChips: compact ? 4 : 7,
              ),
              if (data.directorLabel.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  '导演：${data.directorLabel}',
                  key: const ValueKey('tmdb-detail-director'),
                  style: theme.textTheme.bodyMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          ),
        );
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [poster, const SizedBox(width: 16), info],
        );
      },
    );
  }
}

class _MetaChips extends StatelessWidget {
  const _MetaChips({required this.data, this.metadataBadge, this.maxChips = 7});

  final TmdbDetailData data;
  final String? metadataBadge;

  /// 最多展示几个 chip（窄窗口下少展示，避免把标题挤出动态背景区）。
  final int maxChips;

  @override
  Widget build(BuildContext context) {
    final chips = <Widget>[];
    if (data.ratingLabel.isNotEmpty) {
      chips.add(
        _Chip(
          keyValue: 'tmdb-detail-rating',
          icon: Icons.star,
          label: data.ratingLabel,
          emphasized: true,
        ),
      );
    }
    if (data.yearLabel.isNotEmpty) {
      chips.add(_Chip(keyValue: 'tmdb-detail-year', label: data.yearLabel));
    }
    if (data.runtimeLabel.isNotEmpty) {
      chips.add(
        _Chip(keyValue: 'tmdb-detail-runtime', label: data.runtimeLabel),
      );
    }
    if (data.seasonEpisodeLabel.isNotEmpty) {
      chips.add(
        _Chip(keyValue: 'tmdb-detail-seasons', label: data.seasonEpisodeLabel),
      );
    }
    if (data.genres.isNotEmpty) {
      chips.add(
        _Chip(
          keyValue: 'tmdb-detail-genres',
          label: data.genres.take(3).join(' / '),
        ),
      );
    }
    if (data.countries.isNotEmpty) {
      chips.add(
        _Chip(
          keyValue: 'tmdb-detail-countries',
          label: data.countries.take(2).join(' / '),
        ),
      );
    }
    if (data.status.isNotEmpty) {
      chips.add(_Chip(keyValue: 'tmdb-detail-status', label: data.status));
    }
    if (metadataBadge != null && metadataBadge!.isNotEmpty) {
      chips.add(
        _Chip(
          keyValue: 'tmdb-only-metadata-badge',
          icon: Icons.info_outline,
          label: metadataBadge!,
        ),
      );
    }
    if (chips.isEmpty) return const SizedBox.shrink();
    final limited = chips.length <= maxChips
        ? chips
        : chips.sublist(0, maxChips);
    return Wrap(spacing: 8, runSpacing: 6, children: limited);
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.keyValue,
    required this.label,
    this.icon,
    this.emphasized = false,
  });

  final String keyValue;
  final String label;
  final IconData? icon;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      key: ValueKey(keyValue),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: emphasized
            ? theme.colorScheme.primaryContainer
            : theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: theme.colorScheme.primary),
            const SizedBox(width: 4),
          ],
          Text(label, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 区块通用
// ---------------------------------------------------------------------------

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.title,
    required this.keyValue,
    this.trailing,
  });

  final String title;
  final String keyValue;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: ValueKey(keyValue),
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
          const Spacer(),
          ?trailing,
        ],
      ),
    );
  }
}

class _ExpandableText extends StatefulWidget {
  const _ExpandableText({super.key, required this.title, required this.text});

  final String title;
  final String text;

  @override
  State<_ExpandableText> createState() => _ExpandableTextState();
}

class _ExpandableTextState extends State<_ExpandableText> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final long = widget.text.length > 120 || widget.text.contains('\n');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.title,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          widget.text,
          key: const ValueKey('tmdb-overview-text'),
          style: theme.textTheme.bodyMedium,
          maxLines: _expanded ? null : 4,
          overflow: _expanded ? null : TextOverflow.ellipsis,
        ),
        if (long)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: const ValueKey('tmdb-overview-toggle'),
              onPressed: () => setState(() => _expanded = !_expanded),
              child: Text(_expanded ? '收起' : '展开'),
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 季度卡片
// ---------------------------------------------------------------------------

class _SeasonCard extends StatelessWidget {
  const _SeasonCard({
    super.key,
    required this.season,
    required this.selected,
    required this.selectable,
    this.onTap,
  });

  final TmdbSeasonInfo season;
  final bool selected;
  final bool selectable;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 128,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              height: 170,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  width: selected ? 2 : 1,
                  color: selected
                      ? theme.colorScheme.primary
                      : theme.colorScheme.outlineVariant,
                ),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(7),
                child: PosterImage(url: season.posterUrl),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              season.label,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selectable ? null : theme.colorScheme.onSurfaceVariant,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              season.subtitle,
              style: theme.textTheme.bodySmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 剧集卡片
// ---------------------------------------------------------------------------

/// 单集卡片：**剧照 + 集号 + 标题 + 播出日期**（`04` §4.2）。
///
/// 使用 [OutlinedButton] 作为外壳：既有集成门禁按
/// `OutlinedButton` + `episode-<flag>-<index>` 计数（不得补集），
/// 换成裸 `InkWell` 会让那条门禁失效。
class TmdbEpisodeCardTile extends StatelessWidget {
  const TmdbEpisodeCardTile({
    super.key,
    this.buttonKey,
    this.stillKey,
    required this.card,
    this.actionLabel = '播放',
    this.onTap,
  });

  /// 剧照图片的 key。
  ///
  /// 必须由调用方带上**线路标识**：多条线路的同一集号是合法重复
  /// （`第 2 季第 1 集` 与 `第 1 季第 1 集` 都是 `E1`），共用同一个 key
  /// 会在同一棵树里产生重复 key，既影响查找也影响框架的 key 复用。
  final Key? stillKey;

  /// 外壳按钮的 key。
  ///
  /// 必须落在 [OutlinedButton] 上：既有集成门禁按
  /// `widget is OutlinedButton && widget.key is ValueKey<String> && key.startsWith('episode-<flag>-')`
  /// 计数（断言「不补集」），把 key 放在包装 widget 上会让那条门禁失效。
  final Key? buttonKey;

  final TmdbEpisodeCard card;
  final String actionLabel;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tooltip = actionLabel.isEmpty
        ? card.title
        : '$actionLabel · ${card.title}';
    return Tooltip(
      message: tooltip,
      child: OutlinedButton(
        key: buttonKey,
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          padding: EdgeInsets.zero,
          minimumSize: const Size(0, 0),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          alignment: Alignment.centerLeft,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 剧照（16:9）；无剧照时显示占位（不隐藏卡片，否则会丢集）。
            SizedBox(
              height: 110,
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(7),
                ),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    PosterImage(
                      key:
                          stillKey ??
                          ValueKey('tmdb-episode-still-${card.number}'),
                      url: card.stillUrl,
                    ),
                    Positioned(
                      left: 6,
                      top: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surface.withValues(
                            alpha: 0.78,
                          ),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          card.seasonNumber > 0
                              ? 'S${card.seasonNumber}E${card.number}'
                              : 'E${card.number}',
                          style: theme.textTheme.labelSmall,
                        ),
                      ),
                    ),
                    if (card.rating > 0)
                      Positioned(
                        right: 6,
                        bottom: 6,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surface.withValues(
                              alpha: 0.78,
                            ),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            card.rating.toStringAsFixed(1),
                            style: theme.textTheme.labelSmall,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    card.title,
                    style: theme.textTheme.bodyMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    [
                      if (card.date.isNotEmpty) card.date,
                      if (card.runtime > 0) '${card.runtime} 分钟',
                    ].join(' · '),
                    style: theme.textTheme.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 剧照墙（点击 → 大图查看器）
// ---------------------------------------------------------------------------

class _PhotoWall extends StatelessWidget {
  const _PhotoWall({required this.urls, required this.title});

  final List<String> urls;
  final String title;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 140,
      child: ListView.separated(
        key: const ValueKey('tmdb-photo-wall'),
        scrollDirection: Axis.horizontal,
        itemCount: urls.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) => InkWell(
          key: ValueKey('tmdb-photo-$index'),
          onTap: () => showTmdbPhotoViewer(
            context,
            urls: urls,
            url: urls[index],
            title: title,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(width: 220, child: PosterImage(url: urls[index])),
          ),
        ),
      ),
    );
  }
}

/// 打开图片查看器（`04` §3.1 ⑥）。返回后无需刷新任何状态。
Future<void> showTmdbPhotoViewer(
  BuildContext context, {
  required List<String> urls,
  required String url,
  String title = '',
}) {
  final viewer = TmdbPhotoViewer.open(urls: urls, url: url, title: title);
  if (viewer.isEmpty) return Future<void>.value();
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black87,
    builder: (_) => TmdbPhotoViewerDialog(viewer: viewer),
  );
}

/// 图片查看器：大图 + 左右翻页 + 键盘（`←/→` 翻页、`Esc` 关闭）。
class TmdbPhotoViewerDialog extends StatefulWidget {
  const TmdbPhotoViewerDialog({super.key, required this.viewer});

  final TmdbPhotoViewer viewer;

  @override
  State<TmdbPhotoViewerDialog> createState() => _TmdbPhotoViewerDialogState();
}

class _TmdbPhotoViewerDialogState extends State<TmdbPhotoViewerDialog> {
  late TmdbPhotoViewer _viewer = widget.viewer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dialog(
      key: const ValueKey('tmdb-photo-viewer'),
      backgroundColor: Colors.black,
      insetPadding: const EdgeInsets.all(24),
      // 独立 `RepaintBoundary`：使查看器可以被单独光栅化（截图证据需要
      // 「只拍对话框」；对话框在 overlay 里，取整窗会拍到被压在下面的页面）。
      child: RepaintBoundary(
        key: const ValueKey('tmdb-photo-viewer-boundary'),
        // 显式限定尺寸：`Dialog` 只给宽松约束，不限高会让查看器铺满整屏高度
        // （截图证据里就是一张 1552x5952 的怪图）。这里给一个「大图窗口」的
        // 合理上限，既符合桌面观感，也让证据可读。
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1100, maxHeight: 820),
          child: Shortcuts(
            shortcuts: const {
              SingleActivator(LogicalKeyboardKey.arrowRight): _NextIntent(),
              SingleActivator(LogicalKeyboardKey.arrowLeft): _PreviousIntent(),
              SingleActivator(LogicalKeyboardKey.escape): _CloseIntent(),
            },
            child: Actions(
              actions: {
                _NextIntent: CallbackAction<_NextIntent>(
                  onInvoke: (_) {
                    setState(() => _viewer = _viewer.next());
                    return null;
                  },
                ),
                _PreviousIntent: CallbackAction<_PreviousIntent>(
                  onInvoke: (_) {
                    setState(() => _viewer = _viewer.previous());
                    return null;
                  },
                ),
                _CloseIntent: CallbackAction<_CloseIntent>(
                  onInvoke: (_) {
                    Navigator.of(context).pop();
                    return null;
                  },
                ),
              },
              child: Focus(
                autofocus: true,
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${_viewer.title.isEmpty ? '图片' : _viewer.title}'
                              ' · ${_viewer.index + 1}/${_viewer.count}',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: Colors.white,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          IconButton(
                            key: const ValueKey('tmdb-photo-viewer-close'),
                            tooltip: '关闭',
                            onPressed: () => Navigator.of(context).pop(),
                            icon: const Icon(Icons.close, color: Colors.white),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          InteractiveViewer(
                            child: PosterImage(
                              key: const ValueKey('tmdb-photo-viewer-image'),
                              url: _viewer.currentUrl,
                              fit: BoxFit.contain,
                            ),
                          ),
                          if (_viewer.hasPrevious)
                            Align(
                              alignment: Alignment.centerLeft,
                              child: IconButton.filledTonal(
                                key: const ValueKey('tmdb-photo-viewer-prev'),
                                tooltip: '上一张',
                                onPressed: () => setState(
                                  () => _viewer = _viewer.previous(),
                                ),
                                icon: const Icon(Icons.chevron_left),
                              ),
                            ),
                          if (_viewer.hasNext)
                            Align(
                              alignment: Alignment.centerRight,
                              child: IconButton.filledTonal(
                                key: const ValueKey('tmdb-photo-viewer-next'),
                                tooltip: '下一张',
                                onPressed: () =>
                                    setState(() => _viewer = _viewer.next()),
                                icon: const Icon(Icons.chevron_right),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NextIntent extends Intent {
  const _NextIntent();
}

class _PreviousIntent extends Intent {
  const _PreviousIntent();
}

class _CloseIntent extends Intent {
  const _CloseIntent();
}

// ---------------------------------------------------------------------------
// 演职人员墙（点击 → 人物页）
// ---------------------------------------------------------------------------

class _PeopleWall extends StatelessWidget {
  const _PeopleWall({required this.people, this.onTap});

  final List<TmdbPerson> people;
  final ValueChanged<TmdbPerson>? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 178,
      child: ListView.separated(
        key: const ValueKey('tmdb-people-wall'),
        scrollDirection: Axis.horizontal,
        itemCount: people.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, index) {
          final person = people[index];
          return SizedBox(
            width: 104,
            child: InkWell(
              key: ValueKey('tmdb-person-${person.personId}'),
              onTap: onTap == null ? null : () => onTap!.call(person),
              borderRadius: BorderRadius.circular(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: SizedBox(
                      height: 116,
                      child: PosterImage(url: person.profileUrl),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    person.name,
                    style: theme.textTheme.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    person.subtitle,
                    style: theme.textTheme.labelSmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _CrewGrid extends StatelessWidget {
  const _CrewGrid({required this.crew});

  final List<TmdbPerson> crew;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Wrap(
      spacing: 12,
      runSpacing: 8,
      children: [
        for (final person in crew)
          SizedBox(
            width: 150,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  person.name,
                  style: theme.textTheme.bodyMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  person.subtitle,
                  style: theme.textTheme.bodySmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 相关推荐墙（点击 → 进入该作品详情）
// ---------------------------------------------------------------------------

class _RecommendationWall extends StatelessWidget {
  const _RecommendationWall({required this.items, this.onTap});

  final List<TmdbItem> items;
  final ValueChanged<TmdbItem>? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 218,
      child: ListView.separated(
        key: const ValueKey('tmdb-recommendation-wall'),
        scrollDirection: Axis.horizontal,
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, index) {
          final item = items[index];
          final key = item.identity?.key ?? 'item-$index';
          return SizedBox(
            width: 130,
            child: InkWell(
              key: ValueKey('tmdb-recommendation-$key'),
              onTap: onTap == null ? null : () => onTap!.call(item),
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
                    style: theme.textTheme.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    item.subtitle,
                    style: theme.textTheme.labelSmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 单集详情弹窗
// ---------------------------------------------------------------------------

/// 打开单集详情弹窗（剧照 + 简介 + 动作）。
Future<void> showTmdbEpisodeSheet(
  BuildContext context, {
  required TmdbEpisodeCard card,
  String actionLabel = '播放',
  VoidCallback? onAction,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => TmdbEpisodeSheet(
      card: card,
      actionLabel: actionLabel,
      onAction: onAction,
    ),
  );
}

/// 单集详情弹窗（`04` §4.2：剧照 + 标题 + 播出日期 + 简介）。
class TmdbEpisodeSheet extends StatelessWidget {
  const TmdbEpisodeSheet({
    super.key,
    required this.card,
    this.actionLabel = '播放',
    this.onAction,
  });

  final TmdbEpisodeCard card;
  final String actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      key: const ValueKey('tmdb-episode-sheet'),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  height: 260,
                  width: double.infinity,
                  child: PosterImage(
                    key: const ValueKey('tmdb-episode-sheet-still'),
                    url: card.stillUrl,
                    fit: BoxFit.cover,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                card.title,
                key: const ValueKey('tmdb-episode-sheet-title'),
                style: theme.textTheme.titleLarge,
              ),
              const SizedBox(height: 6),
              Text(
                [
                  card.subtitle,
                  if (card.runtime > 0) '${card.runtime} 分钟',
                  if (card.rating > 0) '★ ${card.rating.toStringAsFixed(1)}',
                ].join(' · '),
                style: theme.textTheme.bodySmall,
              ),
              if (card.overview != null &&
                  card.overview!.trim().isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  card.overview!.trim(),
                  key: const ValueKey('tmdb-episode-sheet-overview'),
                  style: theme.textTheme.bodyMedium,
                ),
              ],
              const SizedBox(height: 16),
              Row(
                children: [
                  if (actionLabel.isNotEmpty)
                    FilledButton.icon(
                      key: const ValueKey('tmdb-episode-sheet-action'),
                      onPressed: onAction == null
                          ? null
                          : () {
                              Navigator.of(context).pop();
                              onAction!.call();
                            },
                      icon: const Icon(Icons.play_arrow),
                      label: Text(actionLabel),
                    ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
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

// ---------------------------------------------------------------------------
// 人物页（演职人员点击）
// ---------------------------------------------------------------------------

/// 人物页：简介 + 照片 + 作品列表（`04` §6.1 的演职人员作品入口）。
class TmdbPersonPage extends StatefulWidget {
  const TmdbPersonPage({
    super.key,
    required this.service,
    required this.person,
    this.onOpenItem,
    this.onOpenPhoto,
  });

  final TmdbService service;
  final TmdbPerson person;

  /// 点击作品：进入该作品的 TMDB 详情。
  final ValueChanged<TmdbItem>? onOpenItem;

  /// 点击照片（默认打开内置查看器）。
  final void Function(List<String> urls, String url)? onOpenPhoto;

  @override
  State<TmdbPersonPage> createState() => _TmdbPersonPageState();
}

class _TmdbPersonPageState extends State<TmdbPersonPage> {
  TmdbLoadPhase _phase = TmdbLoadPhase.loading;
  AppError? _error;
  Map<String, Object?>? _detail;
  List<String> _photos = const [];
  List<TmdbPersonWork> _works = const [];
  bool _biographyExpanded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _phase = TmdbLoadPhase.loading;
      _error = null;
    });
    try {
      final detail = await widget.service.person(widget.person.personId);
      if (!mounted) return;
      final config = widget.service.config;
      final credits = detail['combined_credits'];
      final creditMap = credits is Map
          ? credits.cast<Object?, Object?>()
          : const <Object?, Object?>{};
      final works = <TmdbPersonWork>[
        ...TmdbPersonWork.listFrom(
          creditMap['cast'],
          image: TmdbImageSelector.image,
          imageBase: config.imageBase,
          backdropBase: config.backdropBase,
          cast: true,
        ),
        ...TmdbPersonWork.listFrom(
          creditMap['crew'],
          image: TmdbImageSelector.image,
          imageBase: config.imageBase,
          backdropBase: config.backdropBase,
          cast: false,
        ),
      ];
      setState(() {
        _detail = detail;
        _photos = TmdbImageSelector.profiles(
          detail,
          config.imageBase,
          limit: 12,
        );
        _works = works;
        _phase = TmdbLoadPhase.ready;
      });
    } on TmdbAuthException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = AppError(
          AppErrorKind.tmdbAuth,
          'TMDB 鉴权失败',
          detail: error.message,
          statusCode: error.statusCode,
        );
        _phase = TmdbLoadPhase.failed;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error is AppError
            ? error
            : AppError(
                AppErrorKind.tmdbNetwork,
                'TMDB 请求失败',
                detail: '$error',
                retryable: true,
              );
        _phase = TmdbLoadPhase.failed;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final person = widget.person;
    return Scaffold(
      key: const ValueKey('tmdb-person-page'),
      appBar: AppBar(title: Text(person.name)),
      body: switch (_phase) {
        TmdbLoadPhase.idle || TmdbLoadPhase.loading => const Center(
          child: CircularProgressIndicator(),
        ),
        TmdbLoadPhase.disabled => Center(
          child: Text('未配置 TMDB（不影响站源浏览与播放）', style: theme.textTheme.bodyLarge),
        ),
        TmdbLoadPhase.failed => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                describeTmdbFailure(_error),
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge,
              ),
              const SizedBox(height: 12),
              FilledButton(
                key: const ValueKey('tmdb-person-retry'),
                onPressed: _load,
                child: const Text('重试'),
              ),
            ],
          ),
        ),
        TmdbLoadPhase.ready => _buildContent(context),
      },
    );
  }

  Widget _buildContent(BuildContext context) {
    final theme = Theme.of(context);
    final detail = _detail ?? const <String, Object?>{};
    final biography = tmdbFirstNonEmpty([
      detail['biography'],
      widget.person.biography,
    ]);
    final department = tmdbFirstNonEmpty([
      detail['known_for_department'],
      widget.person.knownForDepartment,
    ]);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 150,
                height: 225,
                child: PosterImage(url: widget.person.profileUrl),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tmdbFirstNonEmpty([detail['name'], widget.person.name]),
                    key: const ValueKey('tmdb-person-name'),
                    style: theme.textTheme.headlineSmall,
                  ),
                  if (department.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(department, style: theme.textTheme.bodyMedium),
                  ],
                  if (widget.person.subtitle.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      widget.person.subtitle,
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
        if (biography.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text(
            '简介',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            biography,
            key: const ValueKey('tmdb-person-biography'),
            style: theme.textTheme.bodyMedium,
            maxLines: _biographyExpanded ? null : 6,
            overflow: _biographyExpanded ? null : TextOverflow.ellipsis,
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: const ValueKey('tmdb-person-biography-toggle'),
              onPressed: () =>
                  setState(() => _biographyExpanded = !_biographyExpanded),
              child: Text(_biographyExpanded ? '收起' : '展开'),
            ),
          ),
        ],
        if (_photos.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            '照片（${_photos.length}）',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 140,
            child: ListView.separated(
              key: const ValueKey('tmdb-person-photos'),
              scrollDirection: Axis.horizontal,
              itemCount: _photos.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) => InkWell(
                key: ValueKey('tmdb-person-photo-$index'),
                onTap: () {
                  if (widget.onOpenPhoto != null) {
                    widget.onOpenPhoto!(_photos, _photos[index]);
                    return;
                  }
                  showTmdbPhotoViewer(
                    context,
                    urls: _photos,
                    url: _photos[index],
                    title: widget.person.name,
                  );
                },
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: SizedBox(
                    width: 100,
                    child: PosterImage(url: _photos[index]),
                  ),
                ),
              ),
            ),
          ),
        ],
        if (_works.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text(
            '作品（${_works.length}）',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          GridView.builder(
            key: const ValueKey('tmdb-person-works'),
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 220,
              mainAxisExtent: 280,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
            ),
            itemCount: _works.length,
            itemBuilder: (context, index) {
              final work = _works[index];
              final key = work.item.identity?.key ?? 'work-$index';
              return InkWell(
                key: ValueKey('tmdb-person-work-$key'),
                onTap: widget.onOpenItem == null
                    ? null
                    : () => widget.onOpenItem!.call(work.item),
                borderRadius: BorderRadius.circular(8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: SizedBox(
                        height: 220,
                        child: PosterImage(url: work.item.posterUrl),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      work.item.title,
                      style: theme.textTheme.bodyMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      work.subtitle,
                      style: theme.textTheme.bodySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ],
    );
  }
}
