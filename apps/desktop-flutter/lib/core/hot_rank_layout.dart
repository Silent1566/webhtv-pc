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

  /// 卡片总高：海报 190 + 间隙 4 + 文字区 60。
  ///
  /// 必须与 `_PosterCard` 的固定高一致（那里也取 `HotRankMetrics.cardHeight`）：
  /// 网格按这个值算行数，实际卡片又是这个高度，两边一致才能恰好铺满。
  ///
  /// 取「有副标题」的较高值：剧集/综艺有集数或期数，电影类目实测 `upinfo`
  /// 为空（文字区会剩一点空，但不影响对齐）。
  static const double cardHeight = 254;

  /// 卡片间距（横向与纵向相同，对齐 `AppSpace.md`）。
  static const double spacing = 12;
}

/// 一次布局解析的结果。
class HotRankLayout {
  const HotRankLayout({
    required this.columns,
    required this.rows,
    required this.itemCount,
    required this.poolSize,
  });

  /// 每行能放几个（≥1）。
  final int columns;

  /// 能放几行（≥1）。
  final int rows;

  /// 本批**实际显示**几条。
  ///
  /// 正常情况等于 `columns × rows`（恰好铺满）；榜单池子不够时退化为池子大小，
  /// 否则会出现「铺不满的半行」——那正是这次要消除的现象。
  final int itemCount;

  /// 可用候选池大小（榜单解析出的条目数）。
  final int poolSize;

  /// 一屏能铺满的容量（`columns × rows`），与 [itemCount] 的区别见其注释。
  int get capacity => columns * rows;

  /// 本批是否恰好铺满（池子够用时为 true）。
  ///
  /// `false` 表示池子本身就填不满一屏，这时不该提供「换一批」——
  /// 轮换也换不出新内容（全部条目已在屏上）。
  bool get fillsScreen => itemCount >= capacity;

  /// 是否还有**换一批**的余地：池子比一屏容量更大，才轮换得出新条目。
  bool get canShuffle => poolSize > capacity;

  @override
  String toString() =>
      'HotRankLayout(columns: $columns, rows: $rows, '
      'itemCount: $itemCount, poolSize: $poolSize)';

  /// 按可用宽高解析布局。
  ///
  /// - [availableWidth] / [availableHeight]：给网格的区域尺寸。非有限值
  ///   （父级没给约束，例如被放进无限高的滚动列表）按「放不下第二行」处理，
  ///   退化为 1 行，避免算出天文数字的行数。
  /// - [poolSize]：候选池条目数；0 表示没有数据。
  ///
  /// 列/行数用「能塞下几个整卡 + 间距」计算，与 `Wrap` 的换行规则一致：
  /// `n × w + (n - 1) × s ≤ available` ⟺ `n ≤ (available + s) / (w + s)`。
  static HotRankLayout resolve({
    required double availableWidth,
    required double availableHeight,
    required int poolSize,
    double posterWidth = HotRankMetrics.posterWidth,
    double cardHeight = HotRankMetrics.cardHeight,
    double spacing = HotRankMetrics.spacing,
  }) {
    final columns = _fitCount(availableWidth, posterWidth, spacing);
    final rows = _fitCount(availableHeight, cardHeight, spacing);
    if (poolSize <= 0) {
      return HotRankLayout(
        columns: columns,
        rows: rows,
        itemCount: 0,
        poolSize: 0,
      );
    }
    final capacity = columns * rows;
    // 池子够 → 铺满；不够 → 只显示能铺满的整数行（一行都铺不满则全显示）。
    var itemCount = poolSize >= capacity
        ? capacity
        : (poolSize ~/ columns) * columns;
    if (itemCount == 0) itemCount = math.min(poolSize, columns);
    return HotRankLayout(
      columns: columns,
      rows: rows,
      itemCount: itemCount,
      poolSize: poolSize,
    );
  }

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
