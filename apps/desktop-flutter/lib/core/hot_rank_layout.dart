/// 热门推荐网格的「恰好铺满」布局计算。
///
/// 为什么需要它（用户 2026-10-14）：
/// > 「能否自动基于高宽计算显示多少个推荐条目也就是刚好铺满的那种」
///
/// 改造前固定展示榜单前 10 条，而 `Wrap` 按窗口宽度换行：窄窗口一行放 7 个时
/// 会出现「第一行 7 个 + 第二行 3 个 + 右侧一大片空白」的半行（用户附了截图）。
/// 这里把「几个一行、几行、共显示几条」变成**由可用宽高算出的确定值**，
/// 保证显示条数恰好是整数行（除非榜单池子本身不够铺满）。
///
/// 纯 Dart、无 Flutter 依赖，因此可以被单元测试直接覆盖边界
/// （窗口极窄、极矮、池子不足一行、尺寸给 0 等）。
library;

import 'dart:math' as math;

/// 热门推荐网格的尺寸常量。
///
/// 卡片宽度与搜索结果区保持一致（[posterWidth] 140），否则同一页面里两块
/// 卡片密度不同会显得凌乱；结果区是固定 140，这里也一样。
abstract final class HotRankMetrics {
  /// 海报卡片宽度（与搜索结果卡片一致）。
  static const double posterWidth = 140;

  /// 卡片间距（横向与纵向相同，对齐 `AppSpace.md`）。
  static const double spacing = 12;

  /// 海报与文字区之间的间隙（= `AppSpace.xs`）。
  static const double posterGap = 4;

  /// 海报的理想高度（现状值，也是搜索结果墙卡片的高度）。
  static const double posterIdealHeight = 190;

  /// 海报高度下限：再矮就认不出是哪部片了，宁可让网格底部留白。
  static const double posterMinHeight = 150;

  /// 海报高度上限：140×210 恰好 2:3（全站海报比例，见 DESIGN.md「固定比例」）。
  ///
  /// 「铺满」不能把海报拉过这个上限——2:3 是比对的前提，比例一变，
  /// 同屏两张海报就不能直接比大小了。
  static const double posterMaxHeight = 210;

  /// 文字区下限：标题一行 + 留白（DESIGN.md「海报下方文字区 40」）。
  static const double captionMin = 40;

  /// 文字区理想高：片名两行 + 副标题。
  static const double captionIdeal = 60;

  /// 最矮的卡片 = 海报下限 + 间隙 + 文字区下限。
  ///
  /// 行数按这个「最省卡高」算：它是「这一行还塞得下一个完整卡片」的门槛，
  /// 用理想卡高（254）算会少算一行——那正是这次要修的现象（用户窗口
  /// 1273×821 时 483 的可用高按 254 只够 1 行，实际 2 行放得下）。
  static const double minCardHeight =
      posterMinHeight + posterGap + captionMin;

  /// 最高的卡片 = 海报上限 + 间隙 + 文字区理想高。
  static const double maxCardHeight =
      posterMaxHeight + posterGap + captionIdeal;

  /// 默认（理想）卡高：海报 190 + 间隙 4 + 文字区 60。
  ///
  /// 保留它作为「一屏放不下一行最省卡高、或者高度无限」时的退路；
  /// 搜索结果墙的 `PosterCard` 默认高也正是这个值，两块网格才对得齐。
  static const double cardHeight =
      posterIdealHeight + posterGap + captionIdeal;

  /// 同一行两张海报之间的**视觉列缝**上限（格子宽 − 海报宽 + 格间距）。
  ///
  /// 为什么会为了「凑整行」把列数往下调：30 条池子在 1811 宽上按 11 列排不出
  /// 整 3 行（11 × 3 > 30），而 10 列正好 3 行 = 30 条铺满。但列数不能无限
  /// 下探——同一行散成 8 列、格子宽 226 而海报仍 140 时，行内会留出 74px 的
  /// 空档，看起来像「这一行没对齐」。48 是「还能看出是一行」的上限，
  /// 超过宁可留白（用户全屏 1920×1080 只看这个门槛内的整行）。
  static const double maxColumnGap = 48;
}

/// 一次布局解析的结果。
class HotRankLayout {
  const HotRankLayout({
    required this.columns,
    required this.rows,
    required this.capacity,
    required this.itemCount,
    required this.poolSize,
    required this.cardHeight,
    required this.posterHeight,
    required this.captionHeight,
    required this.titleLines,
  });

  /// 每行能放几个（≥1）。
  final int columns;

  /// **实际用到**几行（≥1）。
  ///
  /// 精确铺满时就是凑整行选出的行数；退路下等于按最省卡高算出的行数，
  /// 候选池装不满那些行时再退化为池子占的行数——空着的整行比多一点留白
  /// 更难看（见 [HotRankLayout.resolve]）。
  final int rows;

  /// 本批**实际显示**几条。
  ///
  /// 正常情况等于 `columns × rows`（恰好铺满）；榜单池子不够时退化为池子大小，
  /// 否则会出现「铺不满的半行」——那正是这次要消除的现象。
  final int itemCount;

  /// 可用候选池大小（榜单解析出的条目数）。
  final int poolSize;

  /// 每格的高度（= 海报高 + 间隙 + 文字区高）。
  ///
  /// 它由可用高**摊**出来（池子装不满一屏时摊给实际行数），并夹在
  /// `[0, maxCardHeight]`：格子能比理想卡高更高一点，但海报不许超过 2:3。
  final double cardHeight;

  /// 海报实际高度（夹在 `[posterMinHeight, posterMaxHeight]`，且不超出格子）。
  final double posterHeight;

  /// 海报下方的文字区高度（= `cardHeight - posterGap - posterHeight`）。
  final double captionHeight;

  /// 片名最多画几行：文字区够 56（两行 + 副标题）给 2 行，够 36 给 1 行，
  /// 再窄就不画文字（画出来也是被裁掉一半的字）。
  final int titleLines;

  /// 一屏能铺满的容量（`columns × 按最省卡高数出来的行数`），与 [itemCount]
  /// 的区别见其注释。
  ///
  /// 行数用的是**按最省卡高数出来的行数**，不是 [rows]：精确铺满选了 3 行、
  /// 而最省卡高下能放 4 行时，「一屏能放多少」仍是 4 行——两者混用会让
  /// [fillsScreen] 永远为真。
  final int capacity;

  /// 本批是否恰好铺满（池子够用时为 true）。
  ///
  /// `false` 表示池子本身就填不满一屏，或者卡高已被 2:3 截顶
  /// （超宽屏底部留白属预期）。
  bool get fillsScreen => itemCount >= capacity;

  /// 是否还有**换一批**的余地：屏上没摆下的条目才算「可换」。
  ///
  /// 用 [itemCount] 而不是 [capacity] 判断：池子 30 条、屏上 22 条时，
  /// 轮转确实能换出新条目；而池子 12 条、屏上 12 条时一条都换不出来。
  bool get canShuffle => poolSize > itemCount;

  @override
  String toString() =>
      'HotRankLayout(columns: $columns, rows: $rows, '
      'itemCount: $itemCount, poolSize: $poolSize, '
      'cardHeight: $cardHeight, posterHeight: $posterHeight, '
      'captionHeight: $captionHeight, titleLines: $titleLines)';

  /// 按可用宽高解析布局。
  ///
  /// - [availableWidth] / [availableHeight]：给网格的区域尺寸。非有限值
  ///   （父级没给约束，例如被放进无限高的滚动列表）按「放不下第二行」处理，
  ///   退化为 1 行，避免算出天文数字的行数。
  /// - [poolSize]：候选池条目数；0 表示没有数据。
  ///
  /// 列数用「能塞下几个整卡 + 间距」计算，与 `Wrap` 的换行规则一致：
  /// `n × w + (n - 1) × s ≤ available` ⟺ `n ≤ (available + s) / (w + s)`。
  ///
  /// 行数则用 [HotRankMetrics.minCardHeight] 而非理想卡高：一屏的高度该由
  /// **最省卡高**来数「最多能放几行」，再把这个高度摊回实际行数，于是卡片
  /// 会随窗口变高变矮，而条数始终是整数行。
  ///
  /// 在这之上还有一层「精确铺满」：先找一组 `(列, 行)` 让候选池排成**整行**
  /// 且卡高仍落在 [HotRankMetrics.minCardHeight, HotRankMetrics.maxCardHeight]，
  /// 找到了就直接用（列数允许低于按宽度能放的最大列数，只要视觉列缝不超过
  /// [HotRankMetrics.maxColumnGap]）。为什么需要它：用户全屏 1920×1080
  /// （网格 1811×673）按 11 列排 30 条只能排 2 整行 = 22 条、底部空 113px；
  /// 换成 10 列 × 3 行正好 30 条铺满。找不到这样的组合时，仍走下面那套
  /// 「按宽度铺满 + 摊高」的退路。
  static HotRankLayout resolve({
    required double availableWidth,
    required double availableHeight,
    required int poolSize,
    double posterWidth = HotRankMetrics.posterWidth,
    double spacing = HotRankMetrics.spacing,
  }) {
    final maxColumns = _fitCount(availableWidth, posterWidth, spacing);
    final heightKnown = availableHeight.isFinite && availableHeight > 0;
    // 高度无限（或给 0 / 负数）时只画一行：行数没有上界就没有「铺满」可言。
    final fitRows = heightKnown
        ? _fitCount(availableHeight, HotRankMetrics.minCardHeight, spacing)
        : 1;
    final capacity = maxColumns * fitRows;
    if (heightKnown && poolSize > 0) {
      final exact = _exactFill(
        availableWidth: availableWidth,
        availableHeight: availableHeight,
        poolSize: poolSize,
        maxColumns: maxColumns,
        maxRowCount: fitRows,
        posterWidth: posterWidth,
        spacing: spacing,
      );
      if (exact != null) return exact;
    }
    double cardHeightFor(int usedRows) => heightKnown
        ? _clamp(
            (availableHeight - (usedRows - 1) * spacing) / usedRows,
            0,
            HotRankMetrics.maxCardHeight,
          )
        : HotRankMetrics.cardHeight;

    // 池子够 → 铺满；不够 → 只显示能铺满的整数行（一行都铺不满则全显示）。
    var itemCount = 0;
    if (poolSize > 0) {
      itemCount = poolSize >= capacity
          ? capacity
          : (poolSize ~/ maxColumns) * maxColumns;
      if (itemCount == 0) itemCount = math.min(poolSize, maxColumns);
    }
    // 池子装不满那些行时，行数退到池子用得到的行数，并把高度摊给它：
    // 只画两行却按三行分高，底部就会空出一整行（「铺满」的反面）。
    final usedRows = itemCount > 0 ? (itemCount / maxColumns).ceil() : fitRows;
    final cardHeight = cardHeightFor(usedRows);
    final posterHeight = _posterHeightFor(cardHeight);
    final captionHeight = _captionHeightFor(cardHeight, posterHeight);
    return HotRankLayout(
      columns: maxColumns,
      rows: usedRows,
      capacity: capacity,
      itemCount: itemCount,
      poolSize: math.max(0, poolSize),
      cardHeight: cardHeight,
      posterHeight: posterHeight,
      captionHeight: captionHeight,
      titleLines: _titleLinesFor(captionHeight),
    );
  }

  /// 精确铺满：找 `(列, 行)` 让候选池排成整行、卡高落在 [194, 274]。
  ///
  /// 行数 r 的可行区间：
  /// - `rLo = ceil((H + s) / (maxCardHeight + s))`——保证卡高不超过 274（海报 2:3）；
  /// - `rHi` = 按最省卡高数出的行数——保证卡高不低于 194。
  /// 每行 r 要求 `列 × r ≤ 池子`（整行、不留半行），列数还要 ≥ 列缝允许的下限。
  /// 多个可行解时「卡高最接近理想 [HotRankMetrics.cardHeight]（254）」优先，
  /// 其次条数多、再其次列数多：精确铺满的解都填满高度，卡片越接近 254 观感越
  /// 统一；反过来（条数优先）会在超宽屏 + 大池子上为多摆几条把海报压到 160。
  static HotRankLayout? _exactFill({
    required double availableWidth,
    required double availableHeight,
    required int poolSize,
    required int maxColumns,
    required int maxRowCount,
    required double posterWidth,
    required double spacing,
  }) {
    final minColumns = math.min(
      maxColumns,
      _minColumnCount(availableWidth, posterWidth, spacing),
    );
    final rowLow = math.max(
      1,
      ((availableHeight + spacing) /
              (HotRankMetrics.maxCardHeight + spacing))
          .ceil(),
    );
    var bestColumns = 0;
    var bestRows = 0;
    var bestHeight = 0.0;
    for (var rows = rowLow; rows <= maxRowCount; rows += 1) {
      final columns = math.min(maxColumns, poolSize ~/ rows);
      if (columns < 1 || columns < minColumns) continue;
      final cardHeight = (availableHeight - (rows - 1) * spacing) / rows;
      if (cardHeight < HotRankMetrics.minCardHeight ||
          cardHeight > HotRankMetrics.maxCardHeight) {
        continue;
      }
      final better = bestColumns == 0 ||
          _exactPreferred(
            cardHeight: cardHeight,
            columns: columns,
            rows: rows,
            bestHeight: bestHeight,
            bestColumns: bestColumns,
            bestRows: bestRows,
          );
      if (!better) continue;
      bestColumns = columns;
      bestRows = rows;
      bestHeight = cardHeight;
    }
    if (bestColumns == 0) return null;
    final posterHeight = _posterHeightFor(bestHeight);
    final captionHeight = _captionHeightFor(bestHeight, posterHeight);
    return HotRankLayout(
      columns: bestColumns,
      rows: bestRows,
      capacity: bestColumns * maxRowCount,
      itemCount: bestColumns * bestRows,
      poolSize: poolSize,
      cardHeight: bestHeight,
      posterHeight: posterHeight,
      captionHeight: captionHeight,
      titleLines: _titleLinesFor(captionHeight),
    );
  }

  /// 精确铺满的候选取舍：卡高离 254 最近 → 条数最多 → 列数最多。
  static bool _exactPreferred({
    required double cardHeight,
    required int columns,
    required int rows,
    required double bestHeight,
    required int bestColumns,
    required int bestRows,
  }) {
    final delta = (cardHeight - HotRankMetrics.cardHeight).abs();
    final bestDelta = (bestHeight - HotRankMetrics.cardHeight).abs();
    if ((delta - bestDelta).abs() > 1e-9) return delta < bestDelta;
    final items = columns * rows;
    final bestItems = bestColumns * bestRows;
    if (items != bestItems) return items > bestItems;
    return columns > bestColumns;
  }

  /// 列数下限：让同一行的视觉列缝不超过 [HotRankMetrics.maxColumnGap]。
  ///
  /// 格子宽 `(W - (c - 1) × s) / c`，扣掉海报宽、补上格间距就是列缝；
  /// 要求它 ≤ 48 反解得 `c >= (W + s) / (posterWidth + 48)`。
  static int _minColumnCount(
    double available,
    double posterWidth,
    double spacing,
  ) {
    if (!available.isFinite) return 1;
    final perColumn = posterWidth + HotRankMetrics.maxColumnGap;
    if (perColumn <= 0) return 1;
    final count = ((available + spacing) / perColumn).ceil();
    return count < 1 ? 1 : count;
  }

  /// 海报高：先取「把文字区压到下限后剩下的高度」，夹在
  /// `[posterMinHeight, posterMaxHeight]`，最后再保证它不超出格子
  /// （极矮的窗口里格子可能连 4px 的间隙都不到）。
  static double _posterHeightFor(double cardHeight) => math.max(
    0,
    math.min(
      _clamp(
        cardHeight - HotRankMetrics.posterGap - HotRankMetrics.captionMin,
        HotRankMetrics.posterMinHeight,
        HotRankMetrics.posterMaxHeight,
      ),
      cardHeight - HotRankMetrics.posterGap,
    ),
  );

  /// 文字区吃掉海报之外的格子高度（负数一律按 0：格子太矮时先牺牲文字）。
  static double _captionHeightFor(double cardHeight, double posterHeight) =>
      math.max(0, cardHeight - HotRankMetrics.posterGap - posterHeight);

  static int _titleLinesFor(double captionHeight) =>
      captionHeight >= 56 ? 2 : (captionHeight >= 36 ? 1 : 0);

  static double _clamp(double value, double min, double max) =>
      value < min ? min : (value > max ? max : value);

  /// `available` 内能放下几个 [itemExtent]（含 [spacing] 间距），至少 1 个。
  static int _fitCount(double available, double itemExtent, double spacing) {
    if (!available.isFinite || available <= 0) return 1;
    final perItem = itemExtent + spacing;
    if (perItem <= 0) return 1;
    final count = ((available + spacing) / perItem).floor();
    return count < 1 ? 1 : count;
  }
}

/// 「换一批」的取窗口逻辑：从 [pool] 里以 [offset] 为起点取 [count] 条，**回绕**。
///
/// 为什么回绕而不是直接截断：换到池子尾部时剩余不足一批，截断会让这一批
/// 变少、又出现「半行」；回绕保证每批条数恒定（名次角标用的是条目自带的
/// 真实名次，不重新编号，所以回绕不会出现「两个 TOP1」）。
List<T> hotRankWindow<T>(List<T> pool, {required int offset, required int count}) {
  if (pool.isEmpty || count <= 0) return const [];
  // 要满一池时直接整批返回、**忽略 offset**：这是「池子不比一屏大」的情形
  // （8 列而池子只有 5 条），此时 offset 无意义；保持原顺序才能让名次角标
  // 仍是升序的 TOP1..TOPn，而不是被轮转到中间去。
  if (count >= pool.length) return List<T>.of(pool);
  final start = ((offset % pool.length) + pool.length) % pool.length;
  return [
    for (var i = 0; i < count; i++) pool[(start + i) % pool.length],
  ];
}
