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

import '../core/episode_range.dart';
import '../core/app_error.dart';
import '../core/person_work_filters.dart';
import '../core/tmdb_detail_model.dart';
import '../core/tmdb_identity.dart';
import '../core/protocol.dart';
import '../core/tmdb_media.dart';
import '../services/tmdb_service.dart';
import 'app.dart' show PosterImage;
import 'common.dart';
import 'tmdb_episode_detail.dart';
import 'scroll_behavior.dart';
import 'source_field.dart';
import 'tokens.dart';
import 'tmdb_widgets.dart' show TmdbLoadPhase, TmdbVideoTile, SeasonChipStrip;

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
    this.paintImage = true,
    this.scrim = TmdbBackdropScrim.hero,
    this.interval = TmdbBackdropRotation.interval,
    this.fallbackUrl,
    this.child,
  });

  final List<String> urls;

  /// **图片框**的高度。
  ///
  /// 取整个视口高度（用户反馈 2026-10-13：「我要的是全屏」）。这不只是观感问题，
  /// 它直接决定原图能显示多大：`BoxFit.contain` 下图片尺寸由**框的短边**决定——
  /// 427px 高、1312 宽的框（约 3.07:1）里，16:9 的原图只能按高度适配，
  /// 结果只有 759px 宽（两侧各留 276px 空白）；换成整屏 1312x791（约 1.66:1）
  /// 才能按宽度适配，得到 **1312x738 的完整原图、零裁切、几乎不放大**。
  final double height;

  /// 内容（标题/简介/按钮）**贴 [height] 的底部**，只有 `24` 的上内边距与
  /// `44` 的底部内边距（给轮播指示点留位置）。
  ///
  /// 曾经有过一个独立的「内容带」（内容只占视口 80%，图片框仍整屏），结果是
  /// 内容块停在视口 80% 处、**下面还空着 20% 背景**——用户 2026-10-23 反馈
  /// 「位置不对，预期应该是靠近底部，包括全屏的时候」。内容带因此退场：
  /// 图片框多大，内容的落点就是它的底部，两者不再各算各的。

  /// 是否绘制背景图本身（图片、遮罩、轮播指示点）。
  ///
  /// 传 `false` 用于**页面级固定背景**：那种场景下图片由页面底层的
  /// [TmdbDetailPageBackdrop] 负责，头部只负责内容。两处都画会重复解码，
  /// 而且两张同图不同框比会在交界处错位。
  final bool paintImage;

  /// 遮罩力度（见 [TmdbBackdropScrim]）。
  final TmdbBackdropScrim scrim;

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
      // 键名如实反映"这块是什么"：画图时它是**背景轮播**；只画内容时
      // （页面级固定背景接管了图片）它是**头部内容块**。
      //
      // 必须分开：两种用法会同时出现在同一棵树上（页面背景 + 头部），
      // 共用一个 key 会让 `findsOneWidget` / `getRect` 直接失败。
      key: ValueKey(
        widget.paintImage ? 'tmdb-backdrop-slideshow' : 'tmdb-detail-hero',
      ),
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
          if (widget.paintImage)
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 600),
              child: current == null
                  ? SizedBox.expand(
                      key: const ValueKey('tmdb-backdrop-empty'),
                      // 无背景图时用**页面底色**而不是 `surfaceContainerHighest`：
                      // 后者会在头部留一大块比页面亮得多的灰底（用户反馈
                      // 「无效的背景色区域太丑」）。页面底色下直接与内容融为一体。
                      child: ColoredBox(color: theme.colorScheme.surface),
                    )
                  : SizedBox.expand(
                      key: ValueKey('tmdb-backdrop-$index'),
                      // V1（用户选型 2026-10-13）：`cover` 铺满 + 渐变遮罩。
                      //
                      // 为什么回到单层 `cover`，而不是"模糊垫底 + contain 主体"：
                      // 那个方案即使把色洗修对，锐利图与背景**缩放比不同**，
                      // 交界处就必然有一道可见的竖直分界——几何上消不掉。
                      // 而 `cover` 永远"看起来是有意的"：背景图被裁边是照片式的
                      // 自然结果，Emby / Jellyfin / Netflix 都这么做。
                      //
                      // 当初"裁切很丑"的真正原因是**框太扁**：hero 只有 427px 高
                      // （3.07:1），16:9 素材被迫纵向裁掉约 42%，把人的头顶从脸中间
                      // 切掉。现在图片框是**整个视口**（见 [TmdbBackdropSlideshow.height]），
                      // 用户的 2.35:1 窗口下只裁约 24%、16:9 窗口下只裁约 7%。
                      // 同一个 `cover`，框比不同，观感完全不同。
                      // 裁切重心取**顶部**：窗口比素材更宽（全屏 2.35:1 对 16:9
                      // 素材）时 cover 纵向裁掉约 24%，居中裁＝上下各切一半，
                      // 人物头顶常被切到（用户反馈 2026-10-23：「同一个海报背景
                      // 全屏的时候被截取了不好看」）。顶部对齐后裁切全部落在下方，
                      // 而下方本来就被渐变遮罩压到不透明、被标题/简介盖住。
                      child: PosterImage(
                        url: current,
                        fit: BoxFit.cover,
                        alignment: Alignment.topCenter,
                      ),
                    ),
            ),
          // 渐变遮罩：保证文字在任何图片上都可读（不依赖图片亮度）。
          //
          // 上半部刻意保留较低不透明度（0.42）：用户要求「用剧集海报/剧照当动态
          // 背景」，遮罩太厚就把背景彻底洗成一片纯色，等于没有背景。
          // 下半部压到接近不透明：hero 改成**满屏**后，标题/海报落在屏幕底部，
          // 那里必须够暗才能保证白字可读。
          if (widget.paintImage)
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  // 两种力度见 [TmdbBackdropScrim]：头部要压到不透明保证标题可读；
                  // 页面级背景必须**轻且大体均匀**，否则正文滚到下半屏时图片就没了。
                  colors: widget.scrim == TmdbBackdropScrim.hero
                      ? [
                          theme.colorScheme.surface.withValues(alpha: 0.42),
                          theme.colorScheme.surface.withValues(alpha: 0.40),
                          theme.colorScheme.surface.withValues(alpha: 0.78),
                          theme.colorScheme.surface,
                        ]
                      : [
                          theme.colorScheme.surface.withValues(alpha: 0.62),
                          theme.colorScheme.surface.withValues(alpha: 0.66),
                          theme.colorScheme.surface.withValues(alpha: 0.74),
                          theme.colorScheme.surface.withValues(alpha: 0.84),
                        ],
                  stops: const [0, 0.45, 0.78, 1],
                ),
              ),
            ),
          if (widget.child != null)
            Padding(
              // 内容贴**图片框底部**（= 视口底部，窗口与全屏一致）。
              //
              // 底部 44 是留给轮播指示点（`bottom: 16` + 6px 圆点）的安全区：
              // 内容再往下压就会和那几个小圆点撞在一起。
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 44),
              // 内容贴底对齐：动态背景在上方露出更多画面，
              // 标题/海报靠近信息区，视觉上不会出现「背景里飘着一小块内容」。
              child: Align(
                alignment: Alignment.bottomLeft,
                child: widget.child,
              ),
            ),
          // 指示点放在**图片框底部**（= 视口右下角）。
          //
          // 历史：曾放在内容带底部＝屏幕正中间，用户反馈「跑马灯的小点点
          // 显示在中间区域不好看」（2026-10-13）。图片框铺满整屏后，
          // 底部才是常规位置；内容块也贴底，所以底部 44 的内边距就是
          // 给它让出的空间。
          if (widget.paintImage &&
              TmdbBackdropRotation.shouldRotate(urls.length))
            Positioned(
              right: 20,
              bottom: 16,
              top: null,
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

/// 背景遮罩力度。
enum TmdbBackdropScrim {
  /// 头部背景：底部要压到接近不透明，保证标题/简介在任意图上都读得清。
  hero,

  /// 页面级固定背景：**整页内容都浮在图上**，遮罩必须轻且大体均匀。
  ///
  /// 用 [hero] 的重遮罩会把下半屏压成不透明，正文滚到那里图片就消失了——
  /// 实测正是如此（2026-10-13 第一次接页面级背景时，图片只在屏幕顶部约 20%
  /// 可见，用户要的「后续内容也显示在图片上」等于没做到）。
  page,
}

/// 详情页的**页面级固定背景**：整页内容都浮在它上面。
///
/// 为什么单独一个组件（用户反馈 2026-10-13：「后续内容也应该显示在图片上」）：
/// 背景原先长在头部里，于是它的高度＝头部的高度，图片只覆盖首屏；往下滚动，
/// 正文就落回纯色页面底色，像是"图片没铺完"。
/// 这里由调用方放进 `Stack` 的 `Positioned.fill` ——**脱离滚动**，
/// 因此图片固定不动，正文在它上面滚过去。
///
/// 尺寸取整个视口：`Positioned.fill` 给的是紧约束，但
/// [TmdbBackdropSlideshow] 需要一个显式高度来决定内容带位置，所以这里传视口高。
class TmdbDetailBackdrop extends StatelessWidget {
  const TmdbDetailBackdrop({super.key, required this.urls, this.fallbackUrl});

  final List<String> urls;

  /// 无背景图时的兜底（通常是海报）。
  final String? fallbackUrl;

  @override
  Widget build(BuildContext context) => TmdbBackdropSlideshow(
    urls: urls,
    fallbackUrl: fallbackUrl,
    height: MediaQuery.sizeOf(context).height,
    scrim: TmdbBackdropScrim.page,
  );
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
    this.height,
    this.heroOverview,
    this.heroActions,
    this.paintImage = true,
  });

  final TmdbDetailData data;
  final Widget? statusBar;
  final String? metadataBadge;

  /// 站点详情页可把来源简介提升到首屏；纯 TMDB 详情页保持旧布局。
  final String? heroOverview;

  /// 首屏主动作（例如“播放第一集”）。
  final Widget? heroActions;

  /// 是否由本头部绘制背景图，默认 `true`。
  ///
  /// 传 `false` 用于**页面级固定背景**（见 [TmdbDetailBackdrop]）：那时图片由页面
  /// 底层负责，头部只留内容。两处都画会重复解码，且同图不同框比会在交界处错位。
  final bool paintImage;

  /// 背景框高度；为 `null` 时取整屏视口。
  ///
  /// 只在「父级已经给了确定高度」时才需要传（例如内嵌到 `SizedBox` 里）。
  /// 首屏 hero 一律留 `null`，让图片框 = 视口高度（用户反馈 2026-10-13：
  /// 「我要的是全屏」）。
  final double? height;

  @override
  Widget build(BuildContext context) =>
      // 在**本 widget 自身**拿到父级约束（而不是在 Column 的子项里）。
      //
      // 为什么不能把 LayoutBuilder 放在 Column 里面：`Column` 的子项拿到的是
      // **无界高度**（实测 `maxHeight=Infinity`），夹不到任何东西；必须包在
      // Column 外层，才能拿到调用方真正给的约束（如 `SizedBox(height: 400)`）。
      // 实测：不夹的话在 400px 高的容器里会 `overflowed by 200 pixels`。
      LayoutBuilder(
        builder: (context, constraints) {
          // 图片框 = **整屏**（用户反馈 2026-10-13：「我要的是全屏」）。
          // 这同时是"原图能显示多大"的前提，见 [TmdbBackdropSlideshow.height]。
          final screen = MediaQuery.sizeOf(context).height;
          final available = constraints.maxHeight;
          final target = height ?? screen;
          final frame = available.isFinite && available < target
              ? available
              : target;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ?statusBar,
              TmdbBackdropSlideshow(
                urls: data.backdropUrls,
                fallbackUrl: data.posterUrl,
                height: frame,
                paintImage: paintImage,
                child: _HeaderContent(
                  data: data,
                  metadataBadge: metadataBadge,
                  overview: heroOverview,
                  actions: heroActions,
                ),
              ),
            ],
          );
        },
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
    this.recommendationBottom,
    this.videos = const [],
    this.onPersonTap,
    this.onRecommendationTap,
    this.onOpenVideo,
    this.onCopyVideo,
  });

  final TmdbDetailData data;
  final List<TmdbItem> recommendations;

  /// 底部推荐行（猜你喜欢 / 个性推荐）。非空时替代旧的"相关推荐"海报墙，
  /// 由调用方注入共享推荐组件（本视图不认识 controller / 反馈存储）。
  final Widget? recommendationBottom;
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
          SectionHeader(
            title: '剧照（${data.photoUrls.length}）',
            keyValue: 'tmdb-section-photos',
          ),
          _PhotoWall(urls: data.photoUrls, title: data.title),
          const SizedBox(height: 16),
        ],
        // 海报墙（对齐上游 `@id/tmdbPosters` 的 Posters 区块）。
        // 与剧照是**不同语义**的两组图：剧照是剧中画面，海报是宣发图。
        if (data.posterUrls.length > 1) ...[
          SectionHeader(
            title: '海报（${data.posterUrls.length}）',
            keyValue: 'tmdb-section-posters',
          ),
          _PhotoWall(
            urls: data.posterUrls,
            title: data.title,
            keyPrefix: 'tmdb-poster',
            // 海报是 2:3 竖图：用窄框装竖图，避免横框里两侧露灰底。
            itemWidth: 110,
            aspectRatio: 2 / 3,
          ),
          const SizedBox(height: 16),
        ],
        if (data.allPeople.isNotEmpty || data.directors.isNotEmpty) ...[
          SectionHeader(
            title: '演职人员（${data.allPeople.length}）',
            keyValue: 'tmdb-section-people',
          ),
          _PeopleWall(
            people: data.allPeople.take(20).toList(),
            onTap: onPersonTap,
          ),
          const SizedBox(height: 16),
        ],
        // 制作团队**紧跟演职人员**（用户反馈 2026-10-10：「制作团队应该放在演员
        // 下方」）。对齐默影视 `activity_tmdb_detail.xml` 的区块顺序：
        // `castTitle`（演员）→ `creatorTitle`（制作团队）→ `relatedTitle`（相关推荐）。
        // 原先它排在相关视频之后，被两个大区块隔开，用户要滚很久才看得到。
        if (data.creatorTeam.isNotEmpty) ...[
          SectionHeader(
            title: '制作团队（${data.creatorTeam.length}）',
            keyValue: 'tmdb-section-crew',
          ),
          _PeopleWall(
            people: data.creatorTeam,
            onTap: onPersonTap,
            keyPrefix: 'tmdb-crew',
            keyValue: 'tmdb-crew-wall',
          ),
          const SizedBox(height: 16),
        ],
        if (recommendationBottom == null && recommendations.isNotEmpty) ...[
          SectionHeader(
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
          SectionHeader(
            title: '相关视频（${videos.length}）',
            keyValue: 'tmdb-section-videos',
          ),
          for (final video in videos.take(8))
            TmdbVideoTile(
              video: video,
              onOpen: onOpenVideo,
              onCopy: onCopyVideo,
            ),
        ],
        ?recommendationBottom,
      ],
    );
  }
}

/// 线路选择器（`04` §3.1 ④）。
///
/// 对齐上游 `activity_video.xml` 的 `@id/flag`（`HorizontalGridView` 线路条）：
/// 点击一条线路就把该线路设为当前线路，下方剧集卡片随之切换成**该线路的集**。
///
/// 为什么必须是「点击切换」而不是「每条线路各渲染一屏卡片」：多线路站点动辄
/// 3–5 条线路，各渲染一屏卡片会把详情页拉成几屏长，用户还要自己找哪一屏是
/// 当前线路。上游同样只渲染当前线路的选集区。
class TmdbLineSelector extends StatelessWidget {
  const TmdbLineSelector({
    super.key,
    required this.lines,
    required this.selectedFlag,
    this.episodeCounts = const {},
    this.onChanged,
    this.recentFlag = '',
    this.externalOrigins = const <String, String>{},
    this.externalStatus = const <String, SourceStatus>{},
    this.onSwapSource,
  });

  /// 全部线路（按详情页顺序）。
  final List<VodPlayLine> lines;

  /// 当前线路的 `flag`（空串表示未选中）。
  final String selectedFlag;

  /// 历史命中的线路 `flag`（空串 = 无标记）。
  ///
  /// 标记**不抢**选中态：用户手动切走线路后标记仍在，能切回来
  /// （`docs/phase6/design/02` §5）。
  final String recentFlag;

  /// 每条线路的**渲染集数**（已按当前季度过滤）。
  final Map<String, int> episodeCounts;

  final ValueChanged<VodPlayLine>? onChanged;

  /// 线路 `flag` → 外部来源站点名。
  ///
  /// 只装**跨站合并**进来的线路：这些线路来自别的站点，用户需要知道
  /// "这条线路是谁给的"，否则线路名只是一串站内自说自话的序号。
  /// 不在表里的线路（本站原生线路）不渲染色点、Tooltip 也不加来源前缀。
  final Map<String, String> externalOrigins;

  /// 线路 `flag` → 该来源站点的健康态（色点用）。
  ///
  /// 缺记录时按 [SourceStatus.unknown] 上色——**未知不等于好**，
  /// 与源场「没有采样记录就不假装它可用」同一套口径。
  final Map<String, SourceStatus> externalStatus;

  /// 换源入口的回调；为 `null` 时不渲染行尾按钮。
  ///
  /// 类型取 `VoidCallback?`，与本文件既有回调（[TmdbEpisodeHeader] 的
  /// `onToggleReversed` / `onToggleGridMode`）一致：动的是**这条线路**，
  /// 由调用方持有，不需要回传参数。
  final VoidCallback? onSwapSource;

  @override
  Widget build(BuildContext context) {
    if (lines.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      key: const ValueKey('tmdb-line-selector'),
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Text(
            '线路',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            // 线路多到溢出时用鼠标左右拖（`scroll_behavior.dart`）。
            child: HorizontalMouseDrag(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final line in lines) ...[
                      Tooltip(
                        // `message` 是字符串，**不**产生 `Text` widget，
                        // 因此不会干扰按文本断言的既有门禁。
                        //
                        // 优先级：最近播放 > 外部来源 > 线路名。「最近播放」优先
                        // 是因为它回答的是"我上次看到哪"这个更急的问题；来源
                        // 已经在色点旁边，不必再抢一次 Tooltip。
                        message: line.flag == recentFlag
                            ? '最近播放'
                            : externalOrigins.containsKey(line.flag)
                            ? '来自 ${externalOrigins[line.flag]}'
                            : line.displayName,
                        child: ChoiceChip(
                          key: ValueKey('tmdb-line-${line.flag}'),
                          label: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // 「最近播放」标记（`design/02` §5）：在标签**前**加
                              // 14px 图标。标记**不抢**选中态——用户手动切走后
                              // 标记仍在，能切回来。key 挂在 `Icon` 上（不是
                              // `ChoiceChip` 上），既有的 `tmdb-line-*` 门禁
                              // 按「chip 本身是 ChoiceChip」计数，不受影响。
                              if (line.flag == recentFlag) ...[
                                Icon(
                                  Icons.history,
                                  key: ValueKey(
                                    'tmdb-line-recent-${line.flag}',
                                  ),
                                  size: 14,
                                ),
                                const SizedBox(width: AppSpace.xs),
                              ],
                              // 外部来源色点：6px 方点，颜色是站点实测健康态。
                              // key 挂在 `Container` 上（不是 `ChoiceChip` 上），
                              // 与上面 `tmdb-line-recent-*` 同一套做法——既有
                              // `tmdb-line-*` 门禁按「chip 本身是 ChoiceChip」计数。
                              if (externalOrigins.containsKey(line.flag)) ...[
                                Container(
                                  key: ValueKey(
                                    'tmdb-line-external-${line.flag}',
                                  ),
                                  width: 6,
                                  height: 6,
                                  decoration: BoxDecoration(
                                    color: sourceStatusColor(
                                      context,
                                      externalStatus[line.flag] ??
                                          SourceStatus.unknown,
                                    ),
                                    borderRadius: BorderRadius.circular(2),
                                  ),
                                ),
                                const SizedBox(width: AppSpace.xs),
                              ],
                              Text(
                                episodeCounts.containsKey(line.flag)
                                    ? '${line.displayName}（${episodeCounts[line.flag]} 集）'
                                    : line.displayName,
                              ),
                            ],
                          ),
                          selected: line.flag == selectedFlag,
                          onSelected: onChanged == null
                              ? null
                              : (_) => onChanged!.call(line),
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                  ],
                ),
              ),
            ),
          ),
          // 换源入口：只在调用方给了回调时出现，因此既有调用点零改动。
          if (onSwapSource != null)
            TextButton.icon(
              key: const ValueKey('tmdb-line-swap'),
              onPressed: onSwapSource,
              icon: const Icon(Icons.swap_horiz, size: 16),
              label: const Text('换源'),
            ),
        ],
      ),
    );
  }
}

/// 剧集区块头：标题 + 集数 + 视图模式/正序倒序切换（`04` §3.1 ⑤）。
///
/// 对齐上游 `episodeHeader`（`episodeTitle` / `episodeReverse` /
/// `episodeViewMode`）与 `TmdbEpisodeGridPolicy`（列数策略）。
class TmdbEpisodeHeader extends StatelessWidget {
  const TmdbEpisodeHeader({
    super.key,
    required this.episodeCount,
    required this.reversed,
    required this.gridMode,
    this.onToggleReversed,
    this.onToggleGridMode,
    this.lineName,
    this.title = '选集',
  });

  final int episodeCount;

  /// 区块标题（站点页用「选集」，纯 TMDB 页用「剧集」）。
  final String title;
  final bool reversed;
  final bool gridMode;
  final VoidCallback? onToggleReversed;
  final VoidCallback? onToggleGridMode;

  /// 当前线路名（非空时拼进标题，使用户确认在看哪条线路）。
  final String? lineName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      key: const ValueKey('tmdb-episode-header'),
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Text(
            [
              title,
              if (lineName != null && lineName!.isNotEmpty) lineName!,
              '$episodeCount 集',
            ].join(' · '),
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          TextButton.icon(
            key: const ValueKey('tmdb-episode-reverse'),
            onPressed: onToggleReversed,
            icon: Icon(reversed ? Icons.swap_vert : Icons.swap_vert, size: 16),
            label: Text(reversed ? '倒序' : '正序'),
          ),
          TextButton.icon(
            key: const ValueKey('tmdb-episode-view-mode'),
            onPressed: onToggleGridMode,
            icon: Icon(gridMode ? Icons.view_list : Icons.grid_view, size: 16),
            label: Text(gridMode ? '网格' : '列表'),
          ),
        ],
      ),
    );
  }
}

/// 剧集区块：区块头（选集/正序倒序/列表网格）+ 剧集海报卡片。
///
/// 站点详情页与纯 TMDB 详情页共用，避免两处各写一套导致行为漂移。
class TmdbEpisodeSection extends StatelessWidget {
  const TmdbEpisodeSection({
    super.key,
    required this.cards,
    required this.keyPrefix,
    this.actionLabel = '播放',
    this.onTap,
    this.onLongPress,
    this.lineName,
    this.cardWidth = 260,
    this.reversed = false,
    this.gridMode = false,
    this.onToggleReversed,
    this.onToggleGridMode,
    this.posterUrl,
    this.title = '选集',
  });

  final List<TmdbEpisodeCard> cards;

  /// 本剧海报：某集没有剧照（或剧照加载失败）时，卡片回退到它。
  final String? posterUrl;
  final String keyPrefix;
  final String actionLabel;
  final void Function(int index, TmdbEpisodeCard card)? onTap;
  final void Function(int index, TmdbEpisodeCard card)? onLongPress;
  final String? lineName;
  final double cardWidth;
  final bool reversed;
  final bool gridMode;
  final VoidCallback? onToggleReversed;
  final VoidCallback? onToggleGridMode;
  final String title;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      TmdbEpisodeHeader(
        title: title,
        episodeCount: cards.length,
        reversed: reversed,
        gridMode: gridMode,
        lineName: lineName,
        onToggleReversed: onToggleReversed,
        onToggleGridMode: onToggleGridMode,
      ),
      TmdbEpisodeStrip(
        key: ValueKey('$keyPrefix-section'),
        cards: cards,
        keyPrefix: keyPrefix,
        actionLabel: actionLabel,
        cardWidth: cardWidth,
        gridMode: gridMode,
        posterUrl: posterUrl,
        onTap: onTap,
        onLongPress: onLongPress,
      ),
    ],
  );
}

/// 剧集海报卡片条（横向滚动）。
///
/// 这是详情页**唯一**的选集入口（用户反馈 2026-10-08）：有卡片时不再渲染
/// 下方的文字版集按钮，二者取其一。理由：同一集出现两种控件既是重复信息，
/// 也让用户在「点哪个」上犹豫；卡片信息量更大（剧照/集号/标题/日期/时长）。
///
/// 卡片数量恒等于线路剧集数（不补集、不丢集）。
class TmdbEpisodeStrip extends StatefulWidget {
  const TmdbEpisodeStrip({
    super.key,
    required this.cards,
    this.keyPrefix = 'tmdb-episode-card',
    this.actionLabel = '播放',
    this.onTap,
    this.onLongPress,
    this.cardWidth = 260,
    this.height = 196,
    this.gridMode = false,
    this.recentIndex = -1,
    this.ranges = const [],
    this.rangeIndex = 0,
    this.onRangeChanged,
    this.posterUrl,
  });

  final List<TmdbEpisodeCard> cards;
  final String keyPrefix;
  final String actionLabel;

  /// 本剧海报（剧照缺失/失败时的回退图）。
  final String? posterUrl;

  /// 卡片点击。
  ///
  /// `index` 是**管线原始下标**（`cards` 的下标），**不是当前区间的下标**：
  /// 分页只切渲染（`docs/phase6/design/03` §4.5），调用方的「渲染下标 →
  /// 线路原始下标」换算必须拿到未切片的下标，否则会二次映射、静默播错集。
  final void Function(int index, TmdbEpisodeCard card)? onTap;
  final void Function(int index, TmdbEpisodeCard card)? onLongPress;

  /// 「最近播放」的卡片下标（-1 = 无）。
  ///
  /// 与 [onTap] 的下标同一口径：**管线原始下标**（`cards` 的下标），
  /// 因此区间切片后仍能正确标中（`docs/phase6/design/02` §6）。
  final int recentIndex;

  /// 单卡宽度。
  ///
  /// 站点详情页会按「一屏能放下几列」动态计算（`04` §4.4 的列数策略）：
  /// 集数多的线路把卡做窄一些，使一行能看到更多集，减少横向滚动。
  final double cardWidth;
  final double height;

  /// 网格模式（对齐上游 `episodeGrid`）：换行铺满而不是横向滚动。
  ///
  /// 为什么需要：长剧集（几十集）在横向条里要滚很久，网格模式一屏能看到
  /// 更多集；上游同样提供「列表/网格」两种模式切换。
  final bool gridMode;

  /// 区间分组（`docs/phase6/design/03` §4.3）。空或只有 1 个区间时不渲染区间条。
  final List<EpisodeRange> ranges;

  /// 当前区间下标。
  final int rangeIndex;

  final ValueChanged<int>? onRangeChanged;

  @override
  State<TmdbEpisodeStrip> createState() => _TmdbEpisodeStripState();
}

class _TmdbEpisodeStripState extends State<TmdbEpisodeStrip> {
  final ScrollController _rangeScroll = ScrollController();

  /// 单个区间 chip 的估算宽度（含间距）。用于把选中区间滚入视野。
  static const double _rangeChipExtent = 72;

  @override
  void initState() {
    super.initState();
    _scrollToRange();
  }

  @override
  void didUpdateWidget(covariant TmdbEpisodeStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.rangeIndex != widget.rangeIndex) _scrollToRange();
  }

  @override
  void dispose() {
    _rangeScroll.dispose();
    super.dispose();
  }

  /// 把选中区间滚入视野（对齐上游 `renderEpisodeRanges` 的 `smoothScrollTo`）。
  ///
  /// 在 post-frame 回调里做：`maxScrollExtent` 要等本帧布局完成才可用。
  ///
  /// 为什么不用 `GlobalKey` + `Scrollable.ensureVisible`：那要求把 `GlobalKey`
  /// 挂在**选中的那个** chip 上，而测试按 `ValueKey('<prefix>-range-<i>')`
  /// 定位区间 chip——一个 widget 只能有一个 key，两者不能同时满足。
  /// 用 `ScrollController` 算偏移则所有 chip 都能保留各自的 `ValueKey`。
  void _scrollToRange() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_rangeScroll.hasClients) return;
      final target = (widget.rangeIndex * _rangeChipExtent - 12).clamp(
        0.0,
        _rangeScroll.position.maxScrollExtent,
      );
      _rangeScroll.animateTo(
        target,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  /// 生效的区间下标（防越界）。
  int get _safeRangeIndex => widget.ranges.isEmpty
      ? 0
      : widget.rangeIndex.clamp(0, widget.ranges.length - 1);

  /// 当前要渲染的卡片与它们在 [TmdbEpisodeStrip.cards] 里的**原始下标**。
  ///
  /// 为什么要把原始下标一路带着走：分页只切**渲染**（§4.5），
  /// 卡片 key 后缀、`onTap` 回调、`isRecent` 判定全部要用原始下标，
  /// 否则第 2 区间会与第 1 区间撞 key、点卡会播错集。
  List<(int, TmdbEpisodeCard)> get _visibleEntries {
    if (widget.ranges.length <= 1) {
      return [
        for (var i = 0; i < widget.cards.length; i++) (i, widget.cards[i]),
      ];
    }
    final range = widget.ranges[_safeRangeIndex];
    // 与 `EpisodeRangePolicy.slice` 同一套夹取规则，保证下标与它切出的
    // 卡片**一一对应**（`slice` 会把 start 夹到 `[0, length]`）。
    final start = range.start.clamp(0, widget.cards.length);
    final end = range.end.clamp(start, widget.cards.length);
    return [for (var i = start; i < end; i++) (i, widget.cards[i])];
  }

  /// 区间 chip 条。**只在区间数 > 1 时渲染**（否则白占一行高度，
  /// 把控件挤出 800×600 测试视口）。
  Widget _buildRangeBar(BuildContext context) => SizedBox(
    height: 36,
    child: HorizontalMouseDrag(
      child: ListView.separated(
        key: ValueKey('${widget.keyPrefix}-range-strip'),
        controller: _rangeScroll,
        scrollDirection: Axis.horizontal,
        itemCount: widget.ranges.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) => ChoiceChip(
          key: ValueKey('${widget.keyPrefix}-range-$index'),
          label: Text(widget.ranges[index].label),
          selected: index == _safeRangeIndex,
          onSelected: widget.onRangeChanged == null
              ? null
              : (_) => widget.onRangeChanged!(index),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (widget.cards.isEmpty) return const SizedBox.shrink();
    final entries = _visibleEntries;
    final strip = _buildStrip(context, entries);
    if (widget.ranges.length <= 1) return strip;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [_buildRangeBar(context), const SizedBox(height: 8), strip],
    );
  }

  /// 网格模式或横向滚动条。
  ///
  /// [entries] 是 `(原始下标, 卡片)`：所有 key 与回调都用**原始下标**。
  Widget _buildStrip(
    BuildContext context,
    List<(int, TmdbEpisodeCard)> entries,
  ) {
    if (widget.gridMode) {
      return GridView.builder(
        key: ValueKey('${widget.keyPrefix}-grid'),
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: widget.cardWidth + 12,
          mainAxisExtent: widget.height,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
        ),
        itemCount: entries.length,
        itemBuilder: (context, index) =>
            _tile(originalIndex: entries[index].$1, card: entries[index].$2),
      );
    }
    return SizedBox(
      height: widget.height,
      // 集数多到溢出时用鼠标左右拖（用户反馈 2026-10-20）。
      child: HorizontalMouseDrag(
        child: ListView.separated(
          key: ValueKey('${widget.keyPrefix}-strip'),
          scrollDirection: Axis.horizontal,
          itemCount: entries.length,
          separatorBuilder: (_, _) => const SizedBox(width: 10),
          itemBuilder: (context, index) => SizedBox(
            width: widget.cardWidth,
            child: _tile(
              originalIndex: entries[index].$1,
              card: entries[index].$2,
            ),
          ),
        ),
      ),
    );
  }

  /// 单张卡片。[originalIndex] 是 `cards` 里的下标（不是区间内下标）。
  Widget _tile({required int originalIndex, required TmdbEpisodeCard card}) =>
      TmdbEpisodeCardTile(
        buttonKey: ValueKey('${widget.keyPrefix}-$originalIndex'),
        stillKey: ValueKey('${widget.keyPrefix}-still-${card.number}'),
        card: card,
        posterUrl: widget.posterUrl,
        actionLabel: widget.actionLabel,
        isRecent: originalIndex == widget.recentIndex,
        recentKey: ValueKey('${widget.keyPrefix}-recent-$originalIndex'),
        onTap: widget.onTap == null
            ? null
            : () => widget.onTap!.call(originalIndex, card),
        onLongPress: widget.onLongPress == null
            ? null
            : () => widget.onLongPress!.call(originalIndex, card),
      );
}

/// 详情页主体（站点页与纯 TMDB 页共用）。
class TmdbDetailView extends StatelessWidget {
  const TmdbDetailView({
    super.key,
    required this.data,
    this.episodeCards = const [],
    this.recommendations = const [],
    this.recommendationBottom,
    this.videos = const [],
    this.seasons = const [],
    this.selectedSeason = -1,
    this.selectableSeasons = const [],
    this.onSeasonChanged,
    this.onSelectSeason,
    this.episodeKeyPrefix = 'tmdb-episode-card',
    this.episodeActionLabel = '播放',
    this.onEpisodeTap,
    this.onEpisodeLongPress,
    this.onPersonTap,
    this.onRecommendationTap,
    this.onOpenVideo,
    this.onCopyVideo,
    this.statusBar,
    this.metadataBadge,
    this.paintBackdrop = true,
    this.padding = const EdgeInsets.all(16),
    this.infoRows = const [],
    this.reversed = false,
    this.gridMode = false,
    this.onToggleReversed,
    this.onToggleGridMode,
    this.episodeTitle = '剧集',
  });

  final TmdbDetailData data;

  /// 是否由本视图绘制背景图，默认 `true`。
  ///
  /// 传 `false` 用于**页面级固定背景**：调用方把本视图放进
  /// `Stack([Positioned.fill(背景), SingleChildScrollView(本视图)])`，
  /// 背景因此是视口大小且不随内容滚动（见 `tmdb_detail_page.dart` 的 `_buildContent`）。
  final bool paintBackdrop;

  final List<TmdbEpisodeCard> episodeCards;
  final List<TmdbItem> recommendations;

  /// 底部推荐行（猜你喜欢 / 个性推荐）。非空时替代旧的"相关推荐"海报墙。
  final Widget? recommendationBottom;
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

  final String episodeKeyPrefix;

  /// 剧集卡片的动作文案（`播放` / `搜索站源`）；空串表示无动作。
  final String episodeActionLabel;
  final void Function(int index, TmdbEpisodeCard card)? onEpisodeTap;
  final void Function(int index, TmdbEpisodeCard card)? onEpisodeLongPress;
  final ValueChanged<TmdbPerson>? onPersonTap;
  final ValueChanged<TmdbItem>? onRecommendationTap;
  final Future<bool> Function(String url)? onOpenVideo;
  final Future<void> Function(String url)? onCopyVideo;

  /// 状态条（站点页的 TMDB 6 态状态条）插入在头部之上。
  final Widget? statusBar;

  /// 元数据徽标（纯 TMDB 页的「元数据季度 · 不可直接播放」）。
  final String? metadataBadge;

  final EdgeInsets padding;

  /// 信息表行（标签 → 值）；为空时不渲染信息表。
  final List<(String, String?)> infoRows;

  /// 剧集是否倒序 / 网格模式（对齐上游 `episodeReverse` / `episodeViewMode`）。
  final bool reversed;
  final bool gridMode;
  final VoidCallback? onToggleReversed;
  final VoidCallback? onToggleGridMode;

  /// 剧集区块标题。
  final String episodeTitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TmdbDetailHeader(
          // 页面级固定背景接管时传 `false`（见 `paintBackdrop` 的说明）。
          paintImage: paintBackdrop,
          data: data,
          statusBar: statusBar,
          metadataBadge: metadataBadge,
          heroOverview: data.overview,
        ),
        Padding(
          padding: padding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_seasonSectionVisible) ...[
                const SizedBox(height: 16),
                SectionHeader(
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
                // 季度 UI 统一为 chip 条（`docs/phase6/design/03` §3）：
                // 原先这里的海报卡片条与站点页的 chip 条是两套实现，
                // 同一概念两种视觉。现在两页共用 `SeasonChipStrip`。
                //
                // `padding: EdgeInsets.zero`：本视图的外层已用 `padding`（`AppSpace.lg`）
                // 缩进过，这里再缩一次会与上方 `SectionHeader` 不对齐。
                SeasonChipStrip(
                  seasons: [for (final season in seasons) season.number],
                  selectedSeason: selectedSeason,
                  selectableSeasons: selectableSeasons,
                  onChanged: onSeasonChanged,
                  padding: EdgeInsets.zero,
                  switcherKey: 'tmdb-detail-season-switcher',
                  chipKeyPrefix: 'tmdb-detail-season',
                ),
              ],
              if (infoRows.isNotEmpty) ...[
                const SizedBox(height: 16),
                TmdbInfoTable(rows: infoRows),
              ],
              const SizedBox(height: 16),
              if (episodeCards.isNotEmpty)
                EpisodeDurationStrip(cards: episodeCards),
              if (episodeCards.isEmpty)
                // 与其他页面的空态同一套结构（图标 + 标题），而不是一行裸文本。
                // 这是详情页截图里唯一看出来的不一致。
                const SizedBox(
                  width: double.infinity,
                  child: EmptyState(
                    key: ValueKey('tmdb-episodes-empty'),
                    icon: Icons.playlist_remove_outlined,
                    title: '没有可展示的剧集',
                  ),
                )
              else
                TmdbEpisodeSection(
                  key: const ValueKey('tmdb-section-episodes'),
                  title: episodeTitle,
                  cards: episodeCards,
                  keyPrefix: episodeKeyPrefix,
                  actionLabel: episodeActionLabel,
                  reversed: reversed,
                  gridMode: gridMode,
                  onToggleReversed: onToggleReversed,
                  onToggleGridMode: onToggleGridMode,
                  onTap: onEpisodeTap,
                  onLongPress: onEpisodeLongPress,
                  posterUrl: data.posterUrl,
                ),
              if (data.photoUrls.isNotEmpty ||
                  data.allPeople.isNotEmpty ||
                  recommendations.isNotEmpty ||
                  recommendationBottom != null ||
                  videos.isNotEmpty ||
                  data.crew.isNotEmpty)
                TmdbDetailSections(
                  data: data,
                  recommendations: recommendations,
                  recommendationBottom: recommendationBottom,
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
  const _HeaderContent({
    required this.data,
    this.metadataBadge,
    this.overview,
    this.actions,
  });

  final TmdbDetailData data;
  final String? metadataBadge;
  final String? overview;
  final Widget? actions;

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
                // chips 换行会挤占简介的高度：宽屏上限 8（新增语言后正好 8 个），
                // 窄屏维持 5，避免把标题挤出内容带。
                maxChips: compact ? 5 : 8,
              ),
              // 导演行已移除（2026-10-22 用户反馈：把这一行让给简介）。
              // 导演信息不丢：下方「制作团队」区块带头像与「导演」职务；
              // 来源侧的 vodDirector 与 TMDB 的导演仍由模型层保留。
              if ((overview ?? '').trim().isNotEmpty) ...[
                const SizedBox(height: 10),
                Flexible(
                  // 简介吃掉内容带里**剩余的全部高度**：行数由实际可用高度
                  // 反推，而不是写死 3 行 + 「查看简介」按钮（2026-10-22
                  // 用户反馈：这么大一块地方简介显示不全）。
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 760),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final style = theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.9,
                          ),
                          height: 1.35,
                        );
                        // 行高口径必须与 Text 实际排版一致：TextScaler 作用在
                        // 字号上，`height` 再乘到行高上。
                        final scaledFont = MediaQuery.textScalerOf(context)
                            .scale(style?.fontSize ?? 14);
                        final lineHeight = scaledFont * (style?.height ?? 1.35);
                        final maxLines = constraints.maxHeight.isFinite
                            ? (constraints.maxHeight / lineHeight)
                                  .floor()
                                  .clamp(1, 40)
                            : 6;
                        return Text(
                          overview!.trim(),
                          key: const ValueKey('tmdb-detail-hero-overview'),
                          style: style,
                          maxLines: maxLines,
                          overflow: TextOverflow.ellipsis,
                        );
                      },
                    ),
                  ),
                ),
              ],
              if (actions != null) ...[const SizedBox(height: 12), actions!],
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
  const _MetaChips({required this.data, this.metadataBadge, this.maxChips = 8});

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
    // 语言进标签行（2026-10-22 用户反馈：「语言改到上面的标签去吧」）。
    // 来源是 TMDB `spoken_languages`；源详情页与纯 TMDB 页共用这份渲染。
    if (data.languages.isNotEmpty) {
      chips.add(
        _Chip(
          keyValue: 'tmdb-detail-languages',
          label: data.languages.take(2).join(' / '),
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
    return TagChip(
      keyValue: keyValue,
      label: label,
      icon: icon,
      emphasized: emphasized,
    );
  }
}

// ---------------------------------------------------------------------------
// 区块通用
// ---------------------------------------------------------------------------

/// 详情信息表（`04` §3.1 ①）。
///
/// 为什么需要：上游 `activity_video.xml` 把 `site/year/area/type/director/actor`
/// 排成独立的元信息行，信息密度高且一眼可扫。早期 PC 端只用单列文字行，
/// 字段一多就显得「简陋」且占满纵向空间。这里改为两列对齐的表格：
/// 标签定宽、值自动换行，同一行放两组，字段多也不散。
class TmdbInfoTable extends StatelessWidget {
  const TmdbInfoTable({super.key, required this.rows});

  /// 标签 → 值；值为空或空串的行**自动跳过**（不留空行）。
  final List<(String, String?)> rows;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final visible = [
      for (final (label, value) in rows)
        if ((value ?? '').trim().isNotEmpty) (label, value!.trim()),
    ];
    if (visible.isEmpty) return const SizedBox.shrink();
    // 两列排布：奇数项时最后一行只有一个格子，右侧留白。
    final pairs = <List<(String, String?)>>[];
    for (var i = 0; i < visible.length; i += 2) {
      pairs.add([visible[i], if (i + 1 < visible.length) visible[i + 1]]);
    }
    return Container(
      key: const ValueKey('tmdb-info-table'),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < pairs.length; i++) ...[
            if (i > 0) const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var slot = 0; slot < 2; slot++) ...[
                  if (slot > 0) const SizedBox(width: 16),
                  Expanded(
                    child: pairs[i].length > slot
                        ? _InfoCell(
                            label: pairs[i][slot].$1,
                            value: pairs[i][slot].$2 ?? '',
                          )
                        : const SizedBox.shrink(),
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _InfoCell extends StatelessWidget {
  const _InfoCell({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 52,
          child: Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: theme.textTheme.bodyMedium,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
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
/// 线路时长预算 + **按真实时长成比例**的剧集条。
///
/// 这是方向契约里从 Labanotation 借来的那条纪律「长度编码时长」——
/// 剧集不是等宽胶囊，条宽按真实时长成比例，"哪几集更长"一眼看得出来。
///
/// **位置是翻译过的**：契约原文写「右侧 348px」栏，但详情页 hero 的几何被测试
/// 锁死（背景必须铺满整窗宽，1200 视口下 `rect.width == 1200`），整页加右栏会
/// 直接打破它。所以这条纪律落在内容区、紧贴剧集区上方，而不是右栏。
///
/// 数据来自 [TmdbEpisodeCard.runtime]（分钟）。**`runtime == 0` 时如实显示
/// 「时长未知」**，不按平均值假装——编造比例就是编造数据。
class EpisodeDurationStrip extends StatelessWidget {
  const EpisodeDurationStrip({super.key, required this.cards});

  final List<TmdbEpisodeCard> cards;

  static String _formatTotal(int minutes) {
    final hours = minutes ~/ 60;
    final rest = minutes % 60;
    return hours > 0 ? '${hours}h ${rest}m' : '${rest}m';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final known = cards.where((card) => card.runtime > 0).toList();
    if (known.isEmpty) {
      return Row(
        children: [
          Icon(
            Icons.timelapse_outlined,
            size: 15,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: AppSpace.sm),
          Text(
            '各集时长未知',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      );
    }

    var maxRuntime = 0;
    var totalMinutes = 0;
    for (final card in known) {
      if (card.runtime > maxRuntime) maxRuntime = card.runtime;
      totalMinutes += card.runtime;
    }
    final unknownCount = cards.length - known.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              '时长分布',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: AppSpace.sm),
            Text(
              '本线路共 ${_formatTotal(totalMinutes)}',
              style: tabular(
                theme.textTheme.bodySmall!.copyWith(color: scheme.onSurface),
              ),
            ),
            if (unknownCount > 0) ...[
              const SizedBox(width: AppSpace.sm),
              Text('（$unknownCount 集时长未知）', style: theme.textTheme.labelSmall),
            ],
          ],
        ),
        const SizedBox(height: AppSpace.sm),
        // 条宽 = 该集时长 / 最长集：比例是真实的，不是均分。
        Wrap(
          spacing: 4,
          runSpacing: 4,
          children: [
            for (final card in cards)
              Tooltip(
                message: card.runtime > 0
                    ? 'E${card.number} · ${card.runtime} 分钟'
                    : 'E${card.number} · 时长未知',
                waitDuration: const Duration(milliseconds: 300),
                child: Container(
                  width: card.runtime > 0
                      ? 18 + (card.runtime / maxRuntime) * 62
                      : 8,
                  height: 18,
                  decoration: BoxDecoration(
                    // 中性数据墨色，**不用星等琥珀**：琥珀在本系统里只表示
                    // "星等/选中"（唯一强调色规则）。时长是数据，不是选中态——
                    // 给数据也上强调色会稀释强调色本身的含义。
                    // 未知集靠"更窄 + 更暗"区分，不靠颜色。
                    color: card.runtime > 0
                        ? scheme.onSurfaceVariant.withValues(alpha: 0.5)
                        : scheme.surfaceContainerHighest,
                    borderRadius: AppRadius.smAll,
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class TmdbEpisodeCardTile extends StatelessWidget {
  const TmdbEpisodeCardTile({
    super.key,
    this.buttonKey,
    this.stillKey,
    this.recentKey,
    required this.card,
    this.actionLabel = '播放',
    this.onTap,
    this.onLongPress,
    this.isRecent = false,
    this.posterUrl,
  });

  /// 本剧海报：剧照缺失或加载失败时回退到它；它也不可用时保留占位。
  final String? posterUrl;

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

  /// 「最近播放」角标的 key。
  ///
  /// 与 [stillKey] 分开：角标的位置/存在性由**渲染下标**决定，
  /// 而 `stillKey` 用的是集号（可能缺失或重复）。
  ///
  /// 必须挂在 [Container] 而**不是**外壳 [OutlinedButton] 上：既有集成门禁按
  /// `widget is OutlinedButton && key.startsWith('<prefix>-')` 计数（断言
  /// 「不补集」），角标 key 也带同一前缀，挂错层会让计数多出一张卡。
  final Key? recentKey;

  /// 是否是「最近播放」那一集（`docs/phase6/design/02` §6）。
  final bool isRecent;

  final TmdbEpisodeCard card;
  final String actionLabel;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

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
        onLongPress:
            onLongPress ??
            () => unawaited(
              showTmdbEpisodeDetails(
                context,
                card: card,
                actionLabel: actionLabel,
                onAction: onTap,
              ),
            ),
        style: OutlinedButton.styleFrom(
          padding: EdgeInsets.zero,
          minimumSize: const Size(0, 0),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          alignment: Alignment.centerLeft,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          side: isRecent
              ? BorderSide(color: theme.colorScheme.primary, width: 2)
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 剧照（16:9）优先，缺失/失败回退本剧海报；都不可用时占位，不丢集。
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
                      fallbackUrl: posterUrl,
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
                    // 「最近播放」角标（`design/02` §6）。
                    //
                    // key 挂在 `Container` 上而**不是**外壳 `OutlinedButton`
                    // 上：角标 key 与卡片 key 同前缀（`<prefix>-recent-<index>`），
                    // 既有「不补集」门禁按 `widget is OutlinedButton &&
                    // key.startsWith('<prefix>-')` 计数，挂到外壳上会让计数多出
                    // 一张卡。
                    //
                    // 内边距/圆角与同 Stack 里的 `E<n>`、评分角标保持一致
                    // （6/2、4）——它们是同一处徽标惯例，不引入新的散值。
                    if (isRecent)
                      Positioned(
                        left: 6,
                        bottom: 6,
                        child: Container(
                          key: recentKey,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primaryContainer,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.history,
                                size: 12,
                                color: theme.colorScheme.onPrimaryContainer,
                              ),
                              const SizedBox(width: 2),
                              Text(
                                '上次看到这里',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.onPrimaryContainer,
                                ),
                              ),
                            ],
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
  const _PhotoWall({
    required this.urls,
    required this.title,
    this.keyPrefix = 'tmdb-photo',
    this.itemWidth = 220,
    this.aspectRatio = 16 / 9,
  });

  final List<String> urls;
  final String title;

  /// 缩略图 key 前缀。
  ///
  /// 剧照墙与海报墙是两组不同的图，若共用 `tmdb-photo-N` 会出现重复 key，
  /// 点击定位也会歧义。因此由调用方给出各自前缀。
  final String keyPrefix;

  /// 单项宽度（高度由 [aspectRatio] 推出）。
  final double itemWidth;

  /// 单项宽高比。
  ///
  /// **必须按素材类型给**：剧照是 16:9 横图，海报是 2:3 竖图。早期实现对两者
  /// 都用同一个 220×140 的横框，竖版海报在横框里被缩成一条窄图居中，两侧露出
  /// 大片灰底——正是用户反馈「无效的背景色区域太丑」的来源之一
  /// （2026-10-09）。现在框比与素材一致，`BoxFit.cover` 就能恰好铺满。
  final double aspectRatio;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: itemWidth / aspectRatio,
      // 剧照/海报同样用鼠标左右拖（用户反馈 2026-10-20）。
      child: HorizontalMouseDrag(
        child: ListView.separated(
          key: const ValueKey('tmdb-photo-wall'),
          scrollDirection: Axis.horizontal,
          itemCount: urls.length,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (context, index) => InkWell(
            key: ValueKey('$keyPrefix-$index'),
            onTap: () => showTmdbPhotoViewer(
              context,
              urls: urls,
              url: urls[index],
              title: title,
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: itemWidth,
                child: PosterImage(url: urls[index], fit: BoxFit.cover),
              ),
            ),
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

/// 演职人员与制作团队共用的姓名字标。
///
/// 中文等表意文字取首字，外文取首尾词的大写首字母；按 grapheme 切分。
/// 空白或纯符号名称用人物图标，不生成虚构人像。
class PersonMonogram extends StatelessWidget {
  const PersonMonogram({super.key, required this.name});

  final String? name;

  static final RegExp _letter = RegExp(r'\p{L}', unicode: true);
  static final RegExp _ideograph = RegExp(
    r'[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Hangul}]',
    unicode: true,
  );

  /// 计算字标；返回空串表示「没有可用字母」（调用方改画人物图标）。
  static String labelOf(String? name) {
    final trimmed = (name ?? '').trim();
    if (trimmed.isEmpty) return '';
    final graphemes = trimmed.characters.toList();
    // 中日韩表意文字/假名/谚文：首字本身就是「一个字」，不取首字母。
    if (_ideograph.hasMatch(graphemes.first)) {
      return graphemes.first.toUpperCase();
    }
    final words = trimmed
        .split(RegExp(r'\s+'))
        .map((word) => word.characters.toList())
        .where((word) => word.isNotEmpty && _letter.hasMatch(word.first))
        .toList();
    if (words.isEmpty) {
      // 没有词首字母（例如以数字/符号开头）：退到第一个真正的字母。
      for (final grapheme in graphemes) {
        if (_letter.hasMatch(grapheme)) return grapheme.toUpperCase();
      }
      return '';
    }
    final firstLetter = words.first.first.toUpperCase();
    if (words.length == 1) return firstLetter;
    final lastLetter = words.last.first.toUpperCase();
    return firstLetter == lastLetter ? firstLetter : firstLetter + lastLetter;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final label = labelOf(name);
    return Container(
      key: const ValueKey('person-monogram'),
      color: scheme.surfaceContainerHigh,
      alignment: Alignment.center,
      child: label.isEmpty
          ? Icon(Icons.person_outline, size: 28, color: scheme.onSurfaceVariant)
          : Text(
              label,
              style: theme.textTheme.headlineSmall?.copyWith(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
                letterSpacing: 0,
              ),
              maxLines: 1,
              overflow: TextOverflow.clip,
              textAlign: TextAlign.center,
            ),
    );
  }
}

class _PeopleWall extends StatelessWidget {
  const _PeopleWall({
    required this.people,
    this.onTap,
    this.keyPrefix = 'tmdb-person',
    this.keyValue = 'tmdb-people-wall',
  });

  final List<TmdbPerson> people;
  final ValueChanged<TmdbPerson>? onTap;

  /// 卡片 key 前缀。
  ///
  /// 演员墙与制作团队墙是两组不同的人，若共用 `tmdb-person-<id>` 会出现重复
  /// key（同一个人可能既在 cast 又在 crew），点击回调也会歧义。
  final String keyPrefix;
  final String keyValue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 178,
      // 人多到溢出时用鼠标左右拖。
      child: HorizontalMouseDrag(
        child: ListView.separated(
          key: ValueKey(keyValue),
          scrollDirection: Axis.horizontal,
          itemCount: people.length,
          separatorBuilder: (_, _) => const SizedBox(width: 10),
          itemBuilder: (context, index) {
            final person = people[index];
            return SizedBox(
              width: 104,
              child: InkWell(
                key: ValueKey('$keyPrefix-${person.personId}'),
                onTap: onTap == null ? null : () => onTap!.call(person),
                borderRadius: BorderRadius.circular(8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: SizedBox(
                        height: 116,
                        child: PosterImage(
                          url: person.profileUrl,
                          // 缺图/坏图：演职人员与制作团队共用同一套姓名字标。
                          placeholder: PersonMonogram(name: person.name),
                        ),
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
      ),
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
      // 推荐位多到溢出时用鼠标左右拖。
      child: HorizontalMouseDrag(
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

/// 人物页的一行筛选 chip（部门 / 类型）。
///
/// 横向可滚动：部门可能多达十几个（导演/编剧/制片/摄影/剪辑…），窄窗口下必须能滚。
/// 选项带计数，选中态用主色淡底 + 主色文字（与浏览页筛选条同一视觉语言）。
class PersonWorkFilterRow extends StatelessWidget {
  const PersonWorkFilterRow({
    super.key,
    required this.keyValue,
    required this.options,
    required this.selected,
    required this.onSelected,
  });

  final String keyValue;
  final List<PersonWorkFilterOption> options;
  final String selected;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SizedBox(
      height: 34,
      // 筛选项多到溢出时用鼠标左右拖。
      child: HorizontalMouseDrag(
        child: ListView.separated(
          key: ValueKey(keyValue),
          scrollDirection: Axis.horizontal,
          itemCount: options.length,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (context, index) {
            final option = options[index];
            final isSelected = option.key == selected;
            return InkWell(
              key: ValueKey('$keyValue-${option.key}'),
              onTap: () => onSelected(option.key),
              borderRadius: BorderRadius.circular(16),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: isSelected
                      ? scheme.primary.withValues(alpha: 0.18)
                      : scheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(
                  '${option.label} ${option.count}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: isSelected
                        ? scheme.primary
                        : scheme.onSurfaceVariant,
                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

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

  /// 作品筛选器（两个维度：部门 / 类型），对齐默影视 `TmdbPersonWorkFilters`。
  ///
  /// 用户反馈 2026-10-10：「人员介绍页也不支持按分类筛选：电视，电影，参演，
  /// 导演等」。默认两个维度都是「全部」。
  PersonWorkFilters? _workFilters;
  String _departmentFilter = PersonWorkDepartment.all;
  String _mediaFilter = PersonWorkMedia.all;
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
      final castWorks = TmdbPersonWork.listFrom(
        creditMap['cast'],
        image: TmdbImageSelector.image,
        imageBase: config.imageBase,
        backdropBase: config.backdropBase,
        cast: true,
      );
      final crewWorks = TmdbPersonWork.listFrom(
        creditMap['crew'],
        image: TmdbImageSelector.image,
        imageBase: config.imageBase,
        backdropBase: config.backdropBase,
        cast: false,
      );
      // 作品默认按上映/首播日期倒序（用户反馈「人员介绍页的作品默认应该倒序
      // 排列」）；筛选器的每个维度也各自有序，故这里只影响 _works 本身。
      final works = PersonWorkFilters.sortByDateDesc(<TmdbPersonWork>[
        ...castWorks,
        ...crewWorks,
      ]);
      setState(() {
        _detail = detail;
        _photos = TmdbImageSelector.profiles(
          detail,
          config.imageBase,
          limit: 12,
        );
        _works = works;
        // 筛选器由 cast/crew **分开**构造：`cast` 一律算「出演」，`crew` 按
        // job/department 归一后的中文身份归类（对齐默影视）。
        _workFilters = PersonWorkFilters.from(castWorks, crewWorks);
        _departmentFilter = PersonWorkDepartment.all;
        _mediaFilter = PersonWorkMedia.all;
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

  /// 当前筛选下的作品（筛选器未就绪时退化为全部）。
  List<TmdbPersonWork> get _filteredWorks =>
      _workFilters?.filter(
        department: _departmentFilter,
        media: _mediaFilter,
      ) ??
      _works;

  /// 两行筛选 chip：部门 / 类型（对齐默影视 `filterGroup`）。
  List<Widget> _buildWorkFilters(BuildContext context) {
    final filters = _workFilters!;
    return [
      const SizedBox(height: 8),
      PersonWorkFilterRow(
        keyValue: 'tmdb-person-filter-department',
        options: filters.departmentOptions(),
        selected: _departmentFilter,
        onSelected: (key) => setState(() => _departmentFilter = key),
      ),
      const SizedBox(height: 6),
      PersonWorkFilterRow(
        keyValue: 'tmdb-person-filter-media',
        options: filters.mediaOptions(),
        selected: _mediaFilter,
        onSelected: (key) => setState(() => _mediaFilter = key),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final person = widget.person;
    return Scaffold(
      key: const ValueKey('tmdb-person-page'),
      appBar: AppBar(title: Text(person.name)),
      body: switch (_phase) {
        TmdbLoadPhase.idle || TmdbLoadPhase.loading => const LoadingBlock(),
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
            height: 150,
            // 人物照片条：鼠标左右拖。
            child: HorizontalMouseDrag(
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
                      // 人物照片是 2:3 竖图：框比与素材一致，不让两侧露灰底。
                      width: 100,
                      height: 150,
                      child: PosterImage(
                        url: _photos[index],
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
        if (_works.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text(
            '作品（${_filteredWorks.length}'
            '${_filteredWorks.length == _works.length ? '' : ' / ${_works.length}'}）',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          // 筛选条（对齐默影视 `activity_tmdb_person.xml` 的 `filterGroup`）：
          // 两行 chip——部门（全部部门/出演/导演/编剧/…）与类型（全部类型/电影/剧集）。
          // 每个选项带计数，无作品的选项不出现（避免选了没结果）。
          if (_workFilters != null) ..._buildWorkFilters(context),
          const SizedBox(height: 8),
          if (_filteredWorks.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Text(
                  '该筛选下没有作品',
                  key: const ValueKey('tmdb-person-works-empty'),
                  style: theme.textTheme.bodySmall,
                ),
              ),
            )
          else
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
              itemCount: _filteredWorks.length,
              itemBuilder: (context, index) {
                final work = _filteredWorks[index];
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
