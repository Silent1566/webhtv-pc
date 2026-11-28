/// 首页轨道的卡片与横向轨道（`docs/phase11/design/01-home-hero.md` §4）。
///
/// 为什么单独一层：轨道是首页里唯一被三条数据线共用的结构。续播、追剧、
/// 推荐三类卡片在**尺寸与文字区**上完全相同，差别只在「副信息行放什么」
/// 与「有没有进度条」——把它们拆成三个私有实现，就会重演改造前
/// 「同一视觉模式反复重写」的老路（见 `common.dart` 文件头）。
///
/// 尺寸口径（§4）：海报 2:3 + 至少 40px 文字区；文字区随系统字号扩展。
/// 轨道不做右内边距——卡片溢出到窗口右缘之外，靠滚动暴露"还有更多"。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';

import '../core/home_feed.dart';
import 'poster_image.dart';
import 'common.dart';
import 'layout_scale.dart';
import 'scroll_behavior.dart';
import 'tokens.dart';

const double _minCaptionHeight = 40;
const double _captionTitleSize = 13;
const double _captionSecondarySize = 11;
const double _captionLineHeight = 1.2;
const double _captionLineGap = 2;

// 轨道与卡片共用文字区高度，让海报尺寸始终独立于字号。每行向上取整，
// 为 Flutter 的段落高度取整留出空间，默认字号仍保留原来的 40px。
double _captionHeight(BuildContext context) {
  final scaler = MediaQuery.textScalerOf(context);
  double lineHeight(double size) =>
      (scaler.scale(size) * _captionLineHeight).ceilToDouble();
  return math.max(
    _minCaptionHeight,
    AppSpace.sm +
        lineHeight(_captionTitleSize) +
        _captionLineGap +
        lineHeight(_captionSecondarySize),
  );
}

/// 一张首页轨道卡片：2:3 海报 + 标题 + 副信息行。
///
/// [width] 由调用方给（轨道按密度档算好），卡片只负责**按宽度推出**海报高。
class HomePosterCard extends StatelessWidget {
  const HomePosterCard({
    super.key,
    required this.item,
    required this.onTap,
    required this.width,
    this.onLongPress,
  });

  final HomeItem item;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final double width;

  /// 2:3 海报框的测试定位键（也是"高 = 宽 × 1.5"的唯一测量对象）。
  static const ValueKey<String> posterFrameKey = ValueKey(
    'home-card-poster-frame',
  );

  /// 续播进度条的测试定位键。
  static const ValueKey<String> progressKey = ValueKey('home-card-progress');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final secondary = _secondaryText(item);
    final resume = item.kind == HomeItemKind.resume;

    return SizedBox(
      width: width,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        onSecondaryTap: onLongPress,
        // hover 取主题的 `hoverColor`（不覆盖）：交互态由主题统一给出，
        // 卡片若自定一层，全站就会出现第二种"鼠标悬停"的样子。
        borderRadius: AppRadius.mdAll,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              key: posterFrameKey,
              height: width * 1.5,
              child: ClipRRect(
                borderRadius: AppRadius.mdAll,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    PosterImage(
                      url: item.poster,
                      // 解码宽度按逻辑宽度 × DPR：图位尺寸固定，按 DPR 取样
                      // 既不欠采样也不保留原尺寸位图。
                      cacheWidth:
                          (width * MediaQuery.devicePixelRatioOf(context))
                              .round(),
                    ),
                    if (resume)
                      Positioned(
                        left: 0,
                        bottom: 0,
                        child: Container(
                          key: progressKey,
                          height: 3,
                          // 钳到 0..1：输入越界时进度条不该画到海报之外。
                          width: width * item.progress.clamp(0.0, 1.0),
                          color: context.semanticColors.magnitude,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            SizedBox(
              height: _captionHeight(context),
              child: Padding(
                padding: const EdgeInsets.only(top: AppSpace.sm),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontSize: _captionTitleSize,
                        height: _captionLineHeight,
                      ),
                    ),
                    if (secondary.isNotEmpty) ...[
                      const SizedBox(height: _captionLineGap),
                      Text(
                        secondary,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontSize: _captionSecondarySize,
                          height: _captionLineHeight,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 副信息行：理由行优先，没有理由时退回「年份 · 评分」。
  ///
  /// 文字区只保留一行副信息，所以必须排优先级：理由行回答的是
  /// 「这张卡为什么在这儿」（剩多少时间、更新到第几集、因为你看过什么），
  /// 年份与评分只是补充；推荐卡尤其如此（§4 要求那一行放推荐理由）。
  String _secondaryText(HomeItem item) {
    if (item.reason.isNotEmpty) return item.reason;
    return item.subtitle;
  }
}

/// 一条横向轨道：区块标题 + 可鼠标拖拽的横向卡片条。
///
/// 空轨道**不占位**（§4「空则隐藏该轨道」）：返回 `SizedBox.shrink()`，
/// 而不是画一个"暂无内容"的占位块——空块会教用户这里本来该有东西。
class HomeRailView extends StatefulWidget {
  const HomeRailView({
    super.key,
    required this.rail,
    required this.onTap,
    this.onSeeAll,
    this.onLongPress,
    this.loadMore,
    this.hasMore = false,
    this.isLoading,
    this.paginationError,
    this.onPagination,
  });

  final HomeRail rail;

  /// 卡片点击：把整条 [HomeItem] 交回页面，卡片自己不去猜"该打开什么"。
  final ValueChanged<HomeItem> onTap;
  final ValueChanged<HomeItem>? onLongPress;

  /// 「查看全部」的去向；[HomeRail.seeAll] 为 null（推荐行）时不会渲染入口。
  final VoidCallback? onSeeAll;

  final Future<void> Function()? loadMore;
  final bool hasMore;
  final bool Function()? isLoading;
  final Object? paginationError;
  final ValueChanged<String>? onPagination;

  @override
  State<HomeRailView> createState() => _HomeRailViewState();
}

class _HomeRailViewState extends State<HomeRailView> {
  final _controller = ScrollController();
  bool _queued = false;
  bool _deliberatePending = false;
  bool _retryAllowed = false;
  bool _autoFillBlocked = false;
  bool _requesting = false;
  bool _userScrolling = false;
  String _pendingTrigger = 'autofill';
  int _gesture = 0;
  Duration? _lastWheel;
  double? _lastViewport;
  final _decisions = <String, String>{};

  void _diagnose(String event, String trigger, String reason) {
    final state =
        '$reason-$trigger-$_gesture-${widget.rail.items.length}-${widget.hasMore}-${widget.isLoading?.call()}';
    if (_decisions[event] == state) return;
    _decisions[event] = state;
    widget.onPagination?.call(
      'event=$event trigger=$trigger gesture=$_gesture reason=$reason count=${widget.rail.items.length} hasMore=${widget.hasMore}',
    );
  }

  void _queueLoad({bool deliberate = false, String trigger = 'autofill'}) {
    if (widget.loadMore == null) return;
    if (deliberate || !_deliberatePending) _pendingTrigger = trigger;
    _deliberatePending |= deliberate;
    if (_queued) return;
    _queued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _queued = false;
      final deliberate = _deliberatePending;
      final trigger = _pendingTrigger;
      _deliberatePending = false;
      if (!mounted || !_controller.hasClients) return;
      final position = _controller.position;
      if (!position.hasContentDimensions ||
          (widget.isLoading?.call() ?? false) ||
          !widget.hasMore ||
          _requesting) {
        _diagnose(
          'ui_suppressed',
          trigger,
          !widget.hasMore ? 'no_cursor_or_terminal' : 'loading',
        );
        return;
      }
      if (deliberate) {
        if (position.extentAfter > 130 ||
            (widget.paginationError != null && !_retryAllowed)) {
          _diagnose(
            'ui_suppressed',
            trigger,
            position.extentAfter > 130
                ? 'not_near_end'
                : 'retry_requires_new_gesture',
          );
          return;
        }
      } else if (position.maxScrollExtent > 0 ||
          widget.paginationError != null ||
          _autoFillBlocked) {
        _diagnose(
          'ui_suppressed',
          trigger,
          widget.paginationError != null
              ? 'retry_requires_new_gesture'
              : _autoFillBlocked
              ? 'no_visible_growth'
              : 'scrollable_waiting_horizontal_input',
        );
        return;
      }
      _retryAllowed = false;
      _diagnose('ui_trigger', trigger, 'accepted');
      unawaited(_load());
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _load() async {
    _requesting = true;
    final count = widget.rail.items.length;
    try {
      await widget.loadMore!();
    } finally {
      if (mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _requesting = false;
          _autoFillBlocked = widget.rail.items.length <= count;
          if (!_autoFillBlocked && widget.paginationError == null) _queueLoad();
        });
        WidgetsBinding.instance.ensureVisualUpdate();
      }
    }
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification.depth != 0 ||
        notification.metrics.axis != Axis.horizontal) {
      return false;
    }
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _userScrolling = true;
      _gesture++;
      _retryAllowed = true;
    }
    if (_userScrolling &&
        (notification is ScrollUpdateNotification &&
                (notification.scrollDelta ?? 0) > 0 ||
            notification is OverscrollNotification &&
                notification.overscroll > 0)) {
      _queueLoad(deliberate: true, trigger: 'forward_drag');
    }
    if (notification is ScrollEndNotification) _userScrolling = false;
    return false;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rail = widget.rail;
    final onTap = widget.onTap;
    final onLongPress = widget.onLongPress;
    final onSeeAll = widget.onSeeAll;
    _queueLoad();
    if (rail.items.isEmpty) return const SizedBox.shrink();

    // 所有轨道同宽（用户 2026-11-19：「各推荐栏目的卡片大小不一需要统一」）。
    // 曾经推荐卡比海报卡窄一档（0.86），理由是「与详情页推荐行同口径」——但那是
    // 详情页的规矩：那一屏有五种卡片在抢注意力，首页一屏只有横向条，窄一档只会
    // 让每一行看起来像没对齐。
    final cardWidth = LayoutScale.cardWidth(context);
    // 「两件都齐」才放入口：只有去处而没有去向的按钮是死按钮。
    final seeAll = rail.seeAll == null ? null : onSeeAll;

    // 左边距与 hero 的内容对齐（24），右边**不**加：横向条要能一路溢出到窗口
    // 右缘之外，靠滚动暴露「还有更多」，右内边距会把它截在离边缘一截的地方。
    // 标题行单独补右内边距，让「查看全部」与页面右缘对齐。
    return Padding(
      padding: const EdgeInsets.only(left: AppSpace.xl),
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(right: AppSpace.xl),
              child: SectionHeader(
                title: rail.title,
                trailing: seeAll == null
                    ? null
                    : TextButton(onPressed: seeAll, child: const Text('查看全部')),
              ),
            ),
            SizedBox(
              // 横向列表必须有界高：高度由卡宽推出（海报 2:3 + 文字区），
              // 所以这里算的是"最高那一列"，不是某一个写死的数字。
              height: cardWidth * 1.5 + _captionHeight(context),
              // 横向条**不接管滚轮**（用户 2026-11-19 反馈：滚页面时这些卡片也在
              // 往右翻）。指针信号会同时到达外层纵向滚动与这里的横向滚动，两条都动
              // 就成了双击滚动的观感；浏览器/Netflix 的横向条也只认拖拽与触控板横扫。
              child: NotificationListener<ScrollMetricsNotification>(
                onNotification: (notification) {
                  if (notification.depth == 0 &&
                      notification.metrics.axis == Axis.horizontal) {
                    final resized =
                        _lastViewport != null &&
                        _lastViewport != notification.metrics.viewportDimension;
                    _lastViewport = notification.metrics.viewportDimension;
                    _queueLoad(trigger: resized ? 'resize' : 'autofill');
                  }
                  return false;
                },
                child: NotificationListener<ScrollNotification>(
                  onNotification: _onScroll,
                  child: Listener(
                    onPointerSignal: (event) {
                      if (event is PointerScrollEvent &&
                          event.scrollDelta.dx > 0 &&
                          event.scrollDelta.dx.abs() >=
                              event.scrollDelta.dy.abs()) {
                        final now = event.timeStamp;
                        if (_lastWheel == null ||
                            now - _lastWheel! >
                                const Duration(milliseconds: 250)) {
                          _gesture++;
                          _retryAllowed = true;
                        }
                        _lastWheel = now;
                        _queueLoad(
                          deliberate: true,
                          trigger: 'horizontal_wheel',
                        );
                      }
                    },
                    child: HorizontalMouseDrag(
                      child: ListView.separated(
                        controller: _controller,
                        physics: widget.loadMore == null
                            ? null
                            : const AlwaysScrollableScrollPhysics(),
                        scrollDirection: Axis.horizontal,
                        // 不做右内边距：最后一张卡要能被滚到贴住右缘，而不是永远差一截。
                        padding: EdgeInsets.zero,
                        itemCount: rail.items.length,
                        separatorBuilder: (_, _) =>
                            SizedBox(width: LayoutScale.gutter(context)),
                        itemBuilder: (context, index) {
                          final item = rail.items[index];
                          // `Align` 把卡片放到行首：横向列表给的是紧高度，卡片比列高矮时
                          // 不拉伸，点击热区才不会多出一块看不见的空白。
                          return Align(
                            alignment: Alignment.topLeft,
                            child: HomePosterCard(
                              item: item,
                              onTap: () => onTap(item),
                              onLongPress: onLongPress == null
                                  ? null
                                  : () => onLongPress(item),
                              width: cardWidth,
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
