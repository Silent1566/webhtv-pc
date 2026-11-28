/// 首页 hero 幻灯片：全幅背景 + 贴底内容 + 琥珀指示点。
///
/// 为什么不复用 `TmdbBackdropSlideshow`：那个组件的 `child` 是**静态**的、索引私有，
/// 且 `tmdb-backdrop-*` 这些 key 被集成测试按名查找（见
/// `docs/phase11/design/02-home-feed-contract.md` §6）。首页要的是「每张自带标题与
/// 按钮 + 悬停停表」，硬塞进去等于把一个已锁死的组件改成双模式。
///
/// 但**遮罩配方与切换节奏是逐字继承它的**：顶部 0.42 保画面、底部压到不透明保
/// 白字可读；600ms 交叉淡入。差别只在单张停留：这里 8 秒，因为每张要读两行中文。
///
/// 手动切张有四条路（2026-11-22 补）：贴边左右箭头（主通道）、24×24 命中区的
/// 指示点、横向拖/甩、键盘 ←/→。原先只有 6px 的指示点——用户反馈「很难才点到」，
/// 那也是本仓 DESIGN.md 里登记过的已知取舍。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show KeyDownEvent, LogicalKeyboardKey;

import '../core/home_feed.dart';
import 'glass_widgets.dart';
import 'poster_image.dart';
import 'backdrop_scrim.dart';
import 'common.dart' show TagChip;
import 'image_header_scope.dart' show imageHeadersOrNull;
import 'app_motion.dart' show reducedMotionOf;
import 'tokens.dart';

/// 单张停留时长。
///
/// 比详情页背景的 5s（`TmdbBackdropRotation.interval`，纯图片）长 3 秒：
/// hero 上要读的是「标题 + 理由行 + 两个按钮」，5 秒没有读完的余量。
const Duration homeHeroInterval = Duration(seconds: 8);

/// 指示点的**命中区**边长。视觉圆点仍是 6（见 _HeroDot）。
///
/// 24 不是随手取的：WCAG 2.2 的 2.5.8（Target Size Minimum）把 24×24 CSS px
/// 定为下限，而原来的 6×6 命中区连它的四分之一都不到，这正是用户「很难才点到」
/// 的量化解释。源场那套点用的是 26×26，同一族取值。
const double _heroDotHitSize = 24;

/// 横向拖/甩的判定阈值：位移到 60 或速度到 300，任一满足就切一张。
///
/// 两个都要有——鼠标慢拖的 primaryVelocity 是 0，轨迹板快甩的位移又很小。
const double _heroDragDistance = 60;
const double _heroDragVelocity = 300;

/// 主按钮文案。三类的差别只在「马上能做什么」，不在措辞风格。
String homeHeroPrimaryLabel(HomeItemKind kind) => switch (kind) {
  HomeItemKind.resume => '继续播放',
  HomeItemKind.following => '从最新一集开始',
  HomeItemKind.recommend => '查看详情',
  HomeItemKind.hot => '查看详情',
};

String homeHeroSecondaryLabel(HomeItemKind kind) => switch (kind) {
  HomeItemKind.resume => '查看详情',
  HomeItemKind.following => '查看详情',
  HomeItemKind.recommend => '去找片源',
  HomeItemKind.hot => '去找片源',
};

class HomeHero extends StatefulWidget {
  const HomeHero({
    super.key,
    required this.items,
    required this.height,
    required this.onPrimary,
    required this.onSecondary,
    this.interval = homeHeroInterval,
    this.paintImage = true,
    this.onIndexChanged,
  });

  /// 非空。空的情况由页面画空态，不进来。
  final List<HomeItem> items;

  final double height;
  final ValueChanged<HomeItem> onPrimary;
  final ValueChanged<HomeItem> onSecondary;
  final Duration interval;

  /// 页面接管固定背景时，hero 只保留内容；无横图的夜空兜底仍由 hero 绘制。
  final bool paintImage;
  final ValueChanged<int>? onIndexChanged;

  @override
  State<HomeHero> createState() => _HomeHeroState();
}

class _HomeHeroState extends State<HomeHero> {
  Timer? _timer;
  int _index = 0;

  /// 指针停在**会挡住阅读或操作**的控件上的区域数。桌面端（尤其触控板）很常见：
  /// 鼠标只是路过就把幻灯片换掉，等于读一半被抽走。
  ///
  /// 计数而不是布尔：从内容块直接滑到箭头上时，两块会先 exit 再 enter，布尔会在
  /// 中间那一帧把轮播重新起表——用户看到的就是「停下来又走了」。
  int _hoverRegions = 0;

  /// 本次横向拖拽累计的位移。onHorizontalDragEnd 只给速度，慢拖的人速度为 0。
  double _dragDx = 0;

  bool get _pointerInside => _hoverRegions > 0;

  bool _reduced = false;

  /// 已经发过预载的图片地址。按 URL 去重：同一张图不会重复预载，
  /// 条目换掉时也不会把整套再拉一遍。
  final Set<String> _preloaded = <String>{};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = reducedMotionOf(context);
    _syncTimer();
    _preloadAround(_index);
  }

  /// 预载「当前这张 + 下一张」（用户 2026-11-19 反馈：切到那张才开始加载）。
  ///
  /// 只预载相邻两张而不是全部：hero 现在最多 12 张，一次性把 12 张图拉下来
  /// 会把首屏带宽吃光，反而让第一张更慢。相邻预载在用户看完一张（默认 8 秒）
  /// 的时间里足够下完下一张。
  ///
  /// 只预载图片、不预建 widget：`AnimatedSwitcher` 仍在切换时才建子树，
  /// 但 `ImageProvider` 已在缓存里，切换是**解码**而不是**下载**。
  /// 必须用与 `PosterImage` 相同的 headers 规则取 provider，否则预载的和要用的
  /// 是两个不同 key，等于没预载。
  void _preloadAround(int index) {
    final items = widget.items;
    if (items.isEmpty) return;
    final targets = {index % items.length, (index + 1) % items.length};
    for (final at in targets) {
      final item = items[at];
      final url = _nonEmpty(item.backdrop) ?? _nonEmpty(item.poster);
      if (url == null || !_preloaded.add(url)) continue;
      unawaited(
        precacheImage(
          posterImageProvider(url, headers: imageHeadersOrNull(context, url)),
          context,
          // 预载失败**必须**就地吞掉：图本身有 `PosterImage` 的兜底，预载只是
          // 提前暖缓存；不吞的话一次网络抖动会在控制台（以及 widget 测试里）
          // 变成一条「未处理的图片异常」。
          onError: (_, _) {},
        ),
      );
    }
  }

  @override
  void didUpdateWidget(HomeHero oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 后台补充候选时保持正在看的作品，不能每加一张就跳回第一张。
    if (oldWidget.items.isNotEmpty) {
      final key = oldWidget.items[_index % oldWidget.items.length].key;
      final next = widget.items.indexWhere((item) => item.key == key);
      _index = next < 0 ? 0 : next;
    }
    _syncTimer();
    _preloadAround(_index);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// 轮播条件。
  ///
  /// **减少动效不停止轮播**，只把切换变成硬切（`AnimatedSwitcher` 的 duration 归零，
  /// 见 build）：无障碍要治的是「持续运动」，不是「内容会换」。整块停掉等于把这个
  /// 功能对这类用户直接关死（用户 2026-11-19 反馈「不会自动切换」，这也可能是
  /// 其中一条原因）。
  bool get _rotatable => widget.items.length > 1 && !_pointerInside;

  void _syncTimer() {
    final route = ModalRoute.of(context);
    final isCurrent = route?.isCurrent ?? true;
    final animationsEnabled = TickerMode.valuesOf(context).enabled;
    if (!_rotatable || !isCurrent || !animationsEnabled) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    _timer ??= Timer.periodic(widget.interval, (_) {
      if (!mounted) return;
      _setIndex((_index + 1) % widget.items.length);
    });
  }

  /// 从零重新计时（不是「恢复剩余时间」）。
  ///
  /// 剩余时间会制造「刚把鼠标挪开就立刻跳下一张」，而用户挪开鼠标通常正是
  /// 想继续读这一张。
  void _restart() {
    _timer?.cancel();
    _timer = null;
    _syncTimer();
  }

  void _reportHover(bool inside) {
    final was = _pointerInside;
    _hoverRegions += inside ? 1 : -1;
    if (_hoverRegions < 0) _hoverRegions = 0;
    if (was == _pointerInside) return;
    setState(() {});
    _restart();
  }

  void _goTo(int index) {
    if (index == _index || index < 0 || index >= widget.items.length) return;
    _setIndex(index);
    _restart();
  }

  /// 手动切一张（±1），两端回卷——和键盘 ←/→ 同一条规则。
  void _step(int delta) =>
      _goTo((_index + delta + widget.items.length) % widget.items.length);

  void _onDragEnd(DragEndDetails details) {
    final dx = _dragDx;
    final vx = details.primaryVelocity ?? 0;
    _dragDx = 0;
    // 向左拖（内容被推向左）= 看下一张，与轨迹板横扫同一方向。
    if (dx <= -_heroDragDistance || vx <= -_heroDragVelocity) {
      _step(1);
    } else if (dx >= _heroDragDistance || vx >= _heroDragVelocity) {
      _step(-1);
    }
  }

  void _setIndex(int index) {
    setState(() => _index = index);
    _preloadAround(index);
    widget.onIndexChanged?.call(index);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final semantic = context.semanticColors;
    final items = widget.items;
    if (items.isEmpty) return SizedBox(height: widget.height);
    final index = _index % items.length;
    final item = items[index];
    final backdrop = _nonEmpty(item.backdrop);
    final poster = _nonEmpty(item.poster);
    final paintField = widget.paintImage || backdrop == null;
    // 背景只有两种形态（用户 2026-11-19 反馈：模糊底「基本看不清」，像是在加载）：
    // - 有 16:9 背景图 → 满幅铺开，这是唯一能当「大海报」用的素材；
    // - 没有 → 夜空渐变 + 左侧一张**大而锐利**的竖版海报（下面 tileHeight 那段）。
    //   把 2:3 的图拉成 2.4:1 的宽幅只会得到一张糊图，"放大"不产生信息。
    final Widget field = backdrop != null
        ? PosterImage(
            url: backdrop,
            fit: BoxFit.cover,
            alignment: Alignment.topCenter,
          )
        : const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0xFF0B0E1A),
                  Color(0xFF141A2E),
                  Color(0xFF0B0E1A),
                ],
              ),
            ),
          );

    // 竖版海报的尺寸跟 hero 高走：约 62%（夹在 240–560 之间）。
    //
    // 下限 240 是用户 2026-11-25 的要求：「每张都是大海报」。旧版 hero 本身只有
    // 62% 高、海报再取 52%，小窗口下只剩一张 160 高的缩略图。上限 560 仍是「别把
    // 站点海报放大成糊图」——常见 300×450 的海报按 560 高渲染约 1.9 倍，再多就看得出
    // 像素了。
    final double tileHeight = (widget.height * 0.62).clamp(240.0, 560.0);
    final double tileWidth = tileHeight * 2 / 3;
    return GestureDetector(
      // 横向拖/甩切张。必须 opaque：没有背景图时 hero 的 Stack 只有内容块可命中，
      // 「在画面上横扫一把」会落空。纵向滚动不会被抢——纵向 drag 一启动就赢下
      // 竞技场，横向识别器自己退出。
      behavior: HitTestBehavior.opaque,
      onHorizontalDragUpdate: (details) => _dragDx += details.delta.dx,
      onHorizontalDragCancel: () => _dragDx = 0,
      onHorizontalDragEnd: _onDragEnd,
      child: Focus(
        // 键盘：←/→ 切张、Enter/Space 执行主操作。autofocus 让首屏一打开就能用
        // 方向键（hero 是这一屏的主体）；skipTraversal 让它不占 Tab 序——Tab 该先
        // 落在真按钮上，而不是落在一个看不见的焦点框上。
        autofocus: true,
        skipTraversal: true,
        onKeyEvent: _onKey,
        child: SizedBox(
          key: const ValueKey('home-hero'),
          height: widget.height,
          width: double.infinity,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (paintField) ...[
                AnimatedSwitcher(
                  duration: _reduced
                      ? Duration.zero
                      : const Duration(milliseconds: 600),
                  child: SizedBox.expand(
                    key: ValueKey('home-hero-backdrop-$index'),
                    child: field,
                  ),
                ),
                const BackdropScrim(),
              ],
              if (item.kind == HomeItemKind.resume && item.progress > 0)
                Positioned(
                  // 与内容同一左右内边距：贴到窗口左右缘时它读起来像一条分隔线，
                  // 而不是「这部剧的进度」。下面那条暗轨负责说明「全长多少」。
                  left: AppSpace.xl,
                  right: AppSpace.xl,
                  bottom: 0,
                  child: SizedBox(
                    height: 2,
                    child: LayoutBuilder(
                      builder: (context, constraints) => Stack(
                        children: [
                          Positioned.fill(
                            child: ColoredBox(
                              color: scheme.onSurface.withValues(alpha: 0.14),
                            ),
                          ),
                          SizedBox(
                            key: const ValueKey('home-hero-progress'),
                            height: 2,
                            width:
                                constraints.maxWidth *
                                item.progress.clamp(0.0, 1.0),
                            child: ColoredBox(color: semantic.magnitude),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpace.xl,
                  AppSpace.xl,
                  AppSpace.xl,
                  44,
                ),
                child: Align(
                  alignment: Alignment.bottomLeft,
                  // 悬停停表挂在**会挡住阅读或操作的控件**上（用户 2026-11-19 反馈
                  // 「不会自动切换」）：整块 hero 都算悬停的话，鼠标只要停在窗口里就
                  // 永远不轮播——桌面用户的指针大半时间在窗口内。停表区因此是内容块
                  // + 左右箭头 + 指示点这三块；画面其余地方照常轮播。
                  child: MouseRegion(
                    onEnter: (_) => _reportHover(true),
                    onExit: (_) => _reportHover(false),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // 只有「没有背景图」时才需要这块海报：那时它是画面里唯一的
                        // 图像，也是这张幻灯片的主体；有 backdrop 时它只是重复。
                        if (backdrop == null && poster != null)
                          Padding(
                            padding: const EdgeInsets.only(right: AppSpace.xl),
                            child: ClipRRect(
                              borderRadius: AppRadius.mdAll,
                              child: SizedBox(
                                key: const ValueKey('home-hero-poster-tile'),
                                width: tileWidth,
                                height: tileHeight,
                                child: PosterImage(
                                  url: poster,
                                  // 按显示尺寸解码：既不欠采样，也不留原图尺寸的位图。
                                  cacheWidth:
                                      (tileWidth *
                                              MediaQuery.devicePixelRatioOf(
                                                context,
                                              ))
                                          .round(),
                                ),
                              ),
                            ),
                          ),
                        Flexible(
                          child: _HeroCopy(
                            item: item,
                            theme: theme,
                            onPrimary: () => widget.onPrimary(item),
                            onSecondary: () => widget.onSecondary(item),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (items.length > 1) ...[
                // 左右大箭头：手动切张的主通道。贴边垂直居中而不是挤在指示点旁边，
                // 是因为贴边是 Fitts 定律里的「无限大目标」——鼠标甩到边缘就必然命中，
                // 不需要瞄准；44×44 也是桌面端能舒适点击的下限。
                //
                // ExcludeFocus：它们不进 Tab 序。hero 的键盘操作已经是 ←/→，再让 Tab
                // 落在箭头上，Enter 会被 _onKey 先吃掉当主操作，反倒说不清按了什么。
                Positioned(
                  left: AppSpace.md,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: ExcludeFocus(
                      child: _arrow(
                        key: const ValueKey('home-hero-prev'),
                        icon: Icons.chevron_left,
                        tooltip: '上一张',
                        onPressed: () => _step(-1),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  right: AppSpace.md,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: ExcludeFocus(
                      child: _arrow(
                        key: const ValueKey('home-hero-next'),
                        icon: Icons.chevron_right,
                        tooltip: '下一张',
                        onPressed: () => _step(1),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  right: 20,
                  bottom: 16,
                  child: MouseRegion(
                    // 指针压在指示点上时也要停表：8 秒一到画面被抽走，「正在瞄」的
                    // 那一下就成了白瞄——这也是原先「点不到」体感的一半来源。
                    onEnter: (_) => _reportHover(true),
                    onExit: (_) => _reportHover(false),
                    child: Row(
                      key: const ValueKey('home-hero-dots'),
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (var i = 0; i < items.length; i++)
                          _HeroDot(
                            key: ValueKey('home-hero-dot-$i'),
                            active: i == index,
                            label: items[i].title,
                            onTap: () => _goTo(i),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 左右箭头。常驻低透明度而不是「悬停才出现」：悬停才出现的控件对新用户等于
  /// 不存在，而这颗按钮要解决的正是「找不到怎么换」。
  Widget _arrow({
    required Key key,
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return MouseRegion(
      onEnter: (_) => _reportHover(true),
      onExit: (_) => _reportHover(false),
      child: GlassPane(
        blurBackdrop: false,
        borderRadius: BorderRadius.circular(22),
        child: IconButton(
          key: key,
          tooltip: tooltip,
          iconSize: 22,
          onPressed: onPressed,
          icon: Icon(icon),
          style: IconButton.styleFrom(
            fixedSize: const Size(44, 44),
            shape: const CircleBorder(),
            padding: EdgeInsets.zero,
            foregroundColor: scheme.onSurface,
            overlayColor: scheme.onSurface.withValues(alpha: 0.14),
          ),
        ),
      ),
    );
  }

  /// ←/→ 切张；Enter/Space 等于主按钮。
  ///
  /// 返回 `ignored` 而不是 `handled` 的那些键要能继续冒泡：按钮自己处理 Enter/Space，
  /// 滚动容器自己处理 PageUp/PageDown，hero 不该把它们吃掉。
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final items = widget.items;
    if (items.isEmpty) return KeyEventResult.ignored;
    final current = items[_index % items.length];
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowRight) {
      _goTo((_index + 1) % items.length);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      _goTo((_index - 1 + items.length) % items.length);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.space) {
      widget.onPrimary(current);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }
}

class _HeroCopy extends StatelessWidget {
  const _HeroCopy({
    required this.item,
    required this.theme,
    required this.onPrimary,
    required this.onSecondary,
  });

  final HomeItem item;
  final ThemeData theme;
  final VoidCallback onPrimary;
  final VoidCallback onSecondary;

  @override
  Widget build(BuildContext context) {
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          item.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.headlineMedium?.copyWith(
            fontWeight: AppWeight.title,
            color: scheme.onSurface,
          ),
        ),
        if (item.subtitle.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: AppSpace.xs),
            child: Text(
              item.subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        // 类型标签：同样是那一次 `detail()` 里的 `genres`。与详情页同一套静态
        // `TagChip`（底色 surfaceContainerHighest、不可点），不另造一种「首页标签」。
        if (item.tags.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: AppSpace.sm),
            child: Wrap(
              spacing: AppSpace.sm,
              runSpacing: AppSpace.xs,
              children: [for (final tag in item.tags) TagChip(label: tag)],
            ),
          ),
        // 简介：随取图那次 `detail()` 一起回来的，没有就不画（不占位）。
        if (item.overview.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: AppSpace.sm),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Text(
                item.overview,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.92),
                  height: 1.45,
                ),
              ),
            ),
          ),
        if (item.reason.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: AppSpace.xs),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _reasonIcon(item.kind),
                  size: 14,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: AppSpace.xs),
                Flexible(
                  child: Text(
                    item.reason,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(top: AppSpace.md),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              FilledButton(
                key: const ValueKey('home-hero-primary'),
                onPressed: onPrimary,
                child: Text(homeHeroPrimaryLabel(item.kind)),
              ),
              const SizedBox(width: AppSpace.md),
              OutlinedButton(
                key: const ValueKey('home-hero-secondary'),
                onPressed: onSecondary,
                child: Text(homeHeroSecondaryLabel(item.kind)),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

IconData _reasonIcon(HomeItemKind kind) => switch (kind) {
  HomeItemKind.resume => Icons.play_circle_outline,
  HomeItemKind.following => Icons.new_releases_outlined,
  HomeItemKind.recommend => Icons.auto_awesome_outlined,
  HomeItemKind.hot => Icons.local_fire_department_outlined,
};

/// 指示点：视觉仍是小圆点，**命中区**是 24×24。
///
/// 6×6 的命中区是这块唯一被用户点名「很难才点到」的地方，也正好落在 WCAG 2.2
/// 2.5.8 的 24×24 下限之下。只撑命中区、不动视觉半径，是为了一排 12 颗点仍然读
/// 作「一段指示」而不是「一组按钮」：它们现在占 288px，依然贴右下角。
///
/// 当前点画成 18×6 的胶囊——12 张时「我在第几张」靠一排等大的圆点是数不出来的。
/// 悬停 350ms 出片名（与源场同一延迟）：不用盲点，先看名字再决定。
class _HeroDot extends StatelessWidget {
  const _HeroDot({
    super.key,
    required this.active,
    required this.label,
    required this.onTap,
  });

  final bool active;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final semantic = context.semanticColors;
    return Tooltip(
      message: label,
      waitDuration: const Duration(milliseconds: 350),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          // opaque：命中区比圆点大得多，`deferToChild` 会把它缩回那 6px。
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: SizedBox(
            width: _heroDotHitSize,
            height: _heroDotHitSize,
            child: Center(
              child: AnimatedContainer(
                duration: AppMotion.base,
                curve: AppMotion.ease,
                width: active ? 18 : 6,
                height: 6,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(3),
                  color: active
                      ? semantic.magnitude
                      : scheme.onSurface.withValues(alpha: 0.3),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String? _nonEmpty(String? value) {
  final trimmed = value?.trim() ?? '';
  return trimmed.isEmpty ? null : trimmed;
}
