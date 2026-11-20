/// 首页 hero 幻灯片：全幅背景 + 贴底内容 + 琥珀指示点。
///
/// 为什么不复用 `TmdbBackdropSlideshow`：那个组件的 `child` 是**静态**的、索引私有，
/// 且 `tmdb-backdrop-*` 这些 key 被集成测试按名查找（见
/// `docs/phase11/design/02-home-feed-contract.md` §6）。首页要的是「每张自带标题与
/// 按钮 + 悬停停表」，硬塞进去等于把一个已锁死的组件改成双模式。
///
/// 但**遮罩配方与切换节奏是逐字继承它的**：顶部 0.42 保画面、底部压到不透明保
/// 白字可读；600ms 交叉淡入。差别只在单张停留：这里 8 秒，因为每张要读两行中文。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show KeyDownEvent, LogicalKeyboardKey;

import '../core/home_feed.dart';
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

  /// 指针是否停在 hero 上。桌面端（尤其触控板）很常见：鼠标只是路过就把
  /// 幻灯片换掉，等于读一半被抽走。
  bool _pointerInside = false;

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
          NetworkImage(url, headers: imageHeadersOrNull(context, url)),
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
    // 条目换了（推荐后到、播放返回）就回到第一张：停在旧下标上会指向另一部作品。
    if (oldWidget.items.length != widget.items.length) {
      _index = 0;
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

  void _setPointerInside(bool value) {
    if (_pointerInside == value) return;
    setState(() => _pointerInside = value);
    _restart();
  }

  void _goTo(int index) {
    if (index == _index || index < 0 || index >= widget.items.length) return;
    _setIndex(index);
    _restart();
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

    // 竖版海报的尺寸跟 hero 高走：约 52%（夹在 160–320 之间），保证它**不被放大**
    // ——站点海报常见 300×450，按 320 高的框渲染接近 1:1，看起来才是原图。
    final double tileHeight = (widget.height * 0.52).clamp(160.0, 320.0);
    final double tileWidth = tileHeight * 2 / 3;
    return Focus(
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
                // 悬停停表**只挂内容块**（用户 2026-11-19 反馈「不会自动切换」）：
                // 整块 hero 都算悬停的话，鼠标只要停在窗口里就永远不轮播——桌面
                // 用户的指针大半时间在窗口内。会挡住阅读的只有这块文字与按钮，
                // 所以只让这一块停表；画面上其余地方照常轮播。
                child: MouseRegion(
                  onEnter: (_) => _setPointerInside(true),
                  onExit: (_) => _setPointerInside(false),
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
            if (items.length > 1)
              Positioned(
                right: 20,
                bottom: 16,
                child: Row(
                  key: const ValueKey('home-hero-dots'),
                  children: [
                    for (var i = 0; i < items.length; i++)
                      MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: GestureDetector(
                          onTap: () => _goTo(i),
                          child: Container(
                            width: 6,
                            height: 6,
                            margin: const EdgeInsets.only(left: 4),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: i == index
                                  ? semantic.magnitude
                                  : scheme.onSurface.withValues(alpha: 0.3),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
          ],
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

String? _nonEmpty(String? value) {
  final trimmed = value?.trim() ?? '';
  return trimmed.isEmpty ? null : trimmed;
}
