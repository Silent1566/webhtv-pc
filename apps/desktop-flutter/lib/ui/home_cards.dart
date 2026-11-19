/// 首页轨道的卡片与横向轨道（`docs/phase11/design/01-home-hero.md` §4）。
///
/// 为什么单独一层：轨道是首页里唯一被三条数据线共用的结构。续播、追剧、
/// 推荐三类卡片在**尺寸与文字区**上完全相同，差别只在「副信息行放什么」
/// 与「有没有进度条」——把它们拆成三个私有实现，就会重演改造前
/// 「同一视觉模式反复重写」的老路（见 `common.dart` 文件头）。
///
/// 尺寸口径（§4）：高度一律由宽度推，海报 2:3 + 固定 40px 文字区；
/// 轨道不做右内边距——卡片溢出到窗口右缘之外，靠滚动暴露"还有更多"。
library;

import 'package:flutter/material.dart';

import '../core/home_feed.dart';
import 'poster_image.dart';
import 'common.dart';
import 'layout_scale.dart';
import 'scroll_behavior.dart';
import 'tokens.dart';

/// 卡片文字区高度（§4：`_posterCaptionHeight`，与海报网格同口径）。
///
/// 给死高度而不是自适应：卡片总高由「海报 2:3 + 本值」精确算出，文字区一旦
/// 浮动，海报就会被压成非 2:3。
const double _captionHeight = 40;

/// 一张首页轨道卡片：2:3 海报 + 标题 + 副信息行。
///
/// [width] 由调用方给（轨道按密度档算好），卡片只负责**按宽度推出**海报高。
class HomePosterCard extends StatelessWidget {
  const HomePosterCard({
    super.key,
    required this.item,
    required this.onTap,
    required this.width,
  });

  final HomeItem item;
  final VoidCallback onTap;
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
    // 发丝边与主题里 `dividerColor` 同一个口径：层级靠一条线，不靠阴影。
    final hairline = scheme.outlineVariant.withValues(alpha: 0.72);
    final secondary = _secondaryText(item);
    final resume = item.kind == HomeItemKind.resume;

    return SizedBox(
      width: width,
      child: InkWell(
        onTap: onTap,
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
                    // 发丝边画在图的**前景**而不是给容器加 padding：后者会把
                    // 海报缩进 1px，2:3 就不再精确。
                    DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: AppRadius.mdAll,
                        border: Border.all(color: hairline),
                      ),
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
              height: _captionHeight,
              child: Padding(
                padding: const EdgeInsets.only(top: AppSpace.sm),
                child: ClipRect(
                  // `Align` 不做溢出断言 + 外层 `ClipRect`：用户把系统字号调大
                  // 时超出的部分被裁掉，而不是让整条轨道变成 RenderFlex overflow。
                  child: Align(
                    alignment: Alignment.topLeft,
                    heightFactor: 1,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontSize: 13,
                            height: 1.2,
                          ),
                        ),
                        if (secondary.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            secondary,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontSize: 11,
                              height: 1.2,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ],
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

  /// 副信息行：理由行优先，没有理由时退回「年份 · 评分」。
  ///
  /// 40px 的文字区只放得下一行副信息，所以必须排优先级：理由行回答的是
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
class HomeRailView extends StatelessWidget {
  const HomeRailView({
    super.key,
    required this.rail,
    required this.onTap,
    this.onSeeAll,
  });

  final HomeRail rail;

  /// 卡片点击：把整条 [HomeItem] 交回页面，卡片自己不去猜"该打开什么"。
  final ValueChanged<HomeItem> onTap;

  /// 「查看全部」的去向；[HomeRail.seeAll] 为 null（推荐行）时不会渲染入口。
  final VoidCallback? onSeeAll;

  @override
  Widget build(BuildContext context) {
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
            height: cardWidth * 1.5 + _captionHeight,
            // 横向条**不接管滚轮**（用户 2026-11-19 反馈：滚页面时这些卡片也在
            // 往右翻）。指针信号会同时到达外层纵向滚动与这里的横向滚动，两条都动
            // 就成了双击滚动的观感；浏览器/Netflix 的横向条也只认拖拽与触控板横扫。
            child: HorizontalMouseDrag(
              child: ListView.separated(
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
                      width: cardWidth,
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
