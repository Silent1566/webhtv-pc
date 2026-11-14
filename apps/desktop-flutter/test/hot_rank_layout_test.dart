/// 热门推荐「恰好铺满」布局与「换一批」取窗口的测试。
///
/// 这两个是纯计算，放在 `core/` 就是为了能被这样直接覆盖边界：
/// 窗口极窄/极矮、候选池不足一整屏、池子为空、尺寸为 0 或无限。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/hot_rank_layout.dart';

void main() {
  // 度量默认值：海报宽 140、卡片高 254、间距 12 → 每列占 152、每行占 266。
  const w = HotRankMetrics.posterWidth;
  const h = HotRankMetrics.cardHeight;
  const s = HotRankMetrics.spacing;

  HotRankLayout resolve({
    double width = 1280,
    double height = 600,
    int pool = 30,
  }) => HotRankLayout.resolve(
    availableWidth: width,
    availableHeight: height,
    poolSize: pool,
  );

  group('HotRankLayout.resolve：按可用宽高算行列', () {
    test('每行数量与能放的行数都按「整卡 + 间距」算', () {
      final layout = resolve();
      expect(layout.columns, ((1280 + s) / (w + s)).floor());
      expect(layout.rows, ((600 + s) / (h + s)).floor());
      expect(layout.columns, 8);
      expect(layout.rows, 2);
    });

    test('窗口极窄时每行至少 1 个（不能算出 0 列）', () {
      expect(resolve(width: 100).columns, 1);
      expect(resolve(width: 1).columns, 1);
      expect(resolve(width: 0).columns, 1);
      expect(resolve(width: -50).columns, 1);
    });

    test('高度不足一行时行数至少 1（避免算出 0 行什么都不画）', () {
      expect(resolve(height: 10).rows, 1);
      expect(resolve(height: 0).rows, 1);
      expect(resolve(height: -10).rows, 1);
    });

    test('尺寸为无限（父级没给约束）时退化为 1，而不是天文数字', () {
      final layout = resolve(width: double.infinity, height: double.infinity);
      expect(layout.columns, 1);
      expect(layout.rows, 1);
    });
  });

  group('HotRankLayout.resolve：恰好铺满', () {
    test('候选池比一屏大 → 显示满一屏（列 × 行）', () {
      final layout = resolve(pool: 30);
      expect(layout.capacity, layout.columns * layout.rows);
      expect(layout.itemCount, layout.capacity);
      expect(layout.fillsScreen, isTrue);
      expect(layout.canShuffle, isTrue, reason: '池子还有一屏之外的条目可换');
    });

    test('候选池不足一屏 → 只显示能铺满的整数行（不出现半行）', () {
      // 8 列 2 行 = 16 容量，池子只有 10 条。
      final layout = resolve(pool: 10);
      expect(layout.itemCount, 8, reason: '退到 1 个整行，而不是画 8 + 2 的半行');
      expect(layout.itemCount % layout.columns, 0);
      expect(layout.fillsScreen, isFalse);
      expect(layout.canShuffle, isFalse, reason: '池子不比一屏大，换一批换不出新内容');
    });

    test('候选池连一整行都铺不满 → 全显示（没有更好的选择）', () {
      final layout = resolve(pool: 5);
      expect(layout.itemCount, 5);
      expect(layout.fillsScreen, isFalse);
    });

    test('候选池恰好等于一屏容量 → 铺满但不可换', () {
      final layout = resolve(pool: 16);
      expect(layout.itemCount, 16);
      expect(layout.fillsScreen, isTrue);
      expect(layout.canShuffle, isFalse, reason: '再多一条才换得动');
    });

    test('候选池为空 → 不显示任何卡片', () {
      final layout = resolve(pool: 0);
      expect(layout.itemCount, 0);
      expect(layout.fillsScreen, isFalse);
      expect(layout.canShuffle, isFalse);
    });

    test('窄窗口 + 池子够 → 列少但仍是整数行', () {
      // 400 宽 → 2 列；600 高 → 2 行。
      final layout = resolve(width: 400, height: 600, pool: 30);
      expect(layout.columns, 2);
      expect(layout.rows, 2);
      expect(layout.itemCount, 4);
      expect(layout.itemCount % layout.columns, 0);
    });
  });

  group('hotRankWindow：换一批的取窗口（回绕）', () {
    final pool = ['a', 'b', 'c', 'd'];

    test('第一批从头部取', () {
      expect(hotRankWindow(pool, offset: 0, count: 3), ['a', 'b', 'c']);
    });

    test('越界时回绕（不会因为剩余不足而变少）', () {
      expect(hotRankWindow(pool, offset: 3, count: 3), ['d', 'a', 'b']);
      expect(
        hotRankWindow(pool, offset: 3, count: 3).length,
        3,
        reason: '每批条数恒定，否则又会出现半行',
      );
    });

    test('offset 超过池子长度时按取模归一', () {
      expect(hotRankWindow(pool, offset: 5, count: 2), ['b', 'c']);
      expect(hotRankWindow(pool, offset: 8, count: 2), ['a', 'b']);
      expect(hotRankWindow(pool, offset: 9, count: 2), ['b', 'c']);
    });

    test('负 offset 也能归一（不会越界取）', () {
      expect(hotRankWindow(pool, offset: -1, count: 2), ['d', 'a']);
      expect(hotRankWindow(pool, offset: -5, count: 2), ['d', 'a']);
    });

    test('要的条数不少于池子时返回整个池子（忽略 offset，保持名次自然顺序）', () {
      // 这种情况出现在「池子不比一屏大」时（例如 8 列而池子只有 5 条）：
      // 整批显示，且按真实名次排，不做轮转——否则 TOP1 会跑到中间去。
      expect(hotRankWindow(pool, offset: 2, count: 4), pool);
      expect(hotRankWindow(pool, offset: 3, count: 99), pool);
      expect(
        hotRankWindow(pool, offset: -1, count: 4),
        pool,
        reason: '要满一池时 offset 无意义，应保持原顺序',
      );
    });

    test('空池或条数为 0 时返回空', () {
      expect(hotRankWindow(<String>[], offset: 0, count: 3), isEmpty);
      expect(hotRankWindow(pool, offset: 0, count: 0), isEmpty);
      expect(hotRankWindow(pool, offset: 0, count: -1), isEmpty);
    });

    test('返回的是副本：调用方改动不回写候选池', () {
      final window = hotRankWindow(pool, offset: 0, count: 2);
      window[0] = 'X';
      expect(pool.first, 'a');
    });
  });
}
