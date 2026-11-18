/// 热门推荐「恰好铺满」布局与「换一批」取窗口的测试。
///
/// 这两个是纯计算，放在 `core/` 就是为了能被这样直接覆盖边界：
/// 窗口极窄/极矮、候选池不足一整屏、池子为空、尺寸为 0 或无限。
///
/// 2026-11-18 第二轮（用户窗口 1273×821 只显示 7 条，下面空 200 多像素）：
/// 条数不再按固定卡高 254 数行，而是按「最省卡高」194 数行、再把可用高摊给
/// 实际行数。因此下面的用例同时锁定**条数**与**卡高/海报高/文字区/片名行数**——
/// 只断言条数的话，「卡片被拉成畸形」「海报不是 2:3」都测不出来。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/hot_rank_layout.dart';

void main() {
  const w = HotRankMetrics.posterWidth;
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

  group('HotRankMetrics：常量之间的关系', () {
    test('最省卡高 = 海报下限 + 间隙 + 文字区下限', () {
      expect(HotRankMetrics.posterGap, 4, reason: '= AppSpace.xs');
      expect(HotRankMetrics.minCardHeight, 194);
      expect(
        HotRankMetrics.minCardHeight,
        HotRankMetrics.posterMinHeight +
            HotRankMetrics.posterGap +
            HotRankMetrics.captionMin,
      );
    });

    test('最高卡高 = 海报上限 + 间隙 + 文字区理想高（海报封顶 2:3）', () {
      expect(HotRankMetrics.maxCardHeight, 274);
      expect(
        HotRankMetrics.posterMaxHeight / HotRankMetrics.posterWidth,
        1.5,
        reason: '140×210 恰好 2:3，海报不许比这更高',
      );
    });

    test('默认卡高仍是海报 190 + 间隙 4 + 文字区 60（搜索结果墙的卡片高）', () {
      expect(HotRankMetrics.cardHeight, 254);
      expect(HotRankMetrics.captionIdeal, 60);
      expect(HotRankMetrics.posterIdealHeight, 190);
    });

    test('视觉列缝上限 48 → 列数下限 ceil((W + s) / (140 + 48))', () {
      expect(HotRankMetrics.maxColumnGap, 48);
      int minColumns(double width) =>
          ((width + s) / (HotRankMetrics.posterWidth + HotRankMetrics.maxColumnGap))
              .ceil();
      expect(minColumns(1811), 10, reason: '全屏 1920 宽：最少 10 列，列缝才 ≤ 48');
      expect(minColumns(1164), 7, reason: '本机默认窗口：与按宽度能放的 7 列相同');
      expect(minColumns(2451), 14, reason: '超宽屏：最少 14 列');
    });
  });

  group('HotRankLayout.resolve：用户窗口 / 全屏 / 超宽屏（数字逐条锁定）', () {
    // 「可用宽×高 / pool / 列 / 行 / 条数 / 卡高 / 海报高 / 文字区 / 片名行数 / 一屏容量」
    const cases = [
      (
        label: '用户全屏 1920×1080（网格 1811×673）→ 30 条凑成 10 列 × 3 行',
        width: 1811.0,
        height: 673.0,
        pool: 30,
        columns: 10,
        rows: 3,
        itemCount: 30,
        cardHeight: (673 - 2 * 12) / 3,
        posterHeight: (673 - 2 * 12) / 3 - 44,
        captionHeight: 40.0,
        titleLines: 1,
        capacity: 30,
      ),
      (
        label: '2.35:1 1811×742 → 同样 10 列 × 3 行',
        width: 1811.0,
        height: 742.0,
        pool: 30,
        columns: 10,
        rows: 3,
        itemCount: 30,
        cardHeight: (742 - 2 * 12) / 3,
        posterHeight: (742 - 2 * 12) / 3 - 44,
        captionHeight: 40.0,
        titleLines: 1,
        capacity: 30,
      ),
      (
        label: '本机复刻 1273×789（网格 1164×453，回归：列数不许变）',
        width: 1164.0,
        height: 453.0,
        pool: 30,
        columns: 7,
        rows: 2,
        itemCount: 14,
        cardHeight: 220.5,
        posterHeight: 176.5,
        captionHeight: 40.0,
        titleLines: 1,
        capacity: 14,
      ),
      (
        label: '用户默认窗口 1273×821（网格 1167×483，回归）',
        width: 1167.0,
        height: 483.0,
        pool: 30,
        columns: 7,
        rows: 2,
        itemCount: 14,
        cardHeight: 235.5,
        posterHeight: 191.5,
        captionHeight: 40.0,
        titleLines: 1,
        capacity: 14,
      ),
      (
        label: '1.6:1 1280×600（无精确候选 → 退路不变）',
        width: 1280.0,
        height: 600.0,
        pool: 30,
        columns: 8,
        rows: 2,
        itemCount: 16,
        cardHeight: 274.0,
        posterHeight: 210.0,
        captionHeight: 60.0,
        titleLines: 2,
        capacity: 16,
      ),
      (
        label: '超宽屏 2451×1072 + 池子 300 → 16 列 × 4 行（不是 5 行）',
        width: 2451.0,
        height: 1072.0,
        pool: 300,
        columns: 16,
        rows: 4,
        itemCount: 64,
        cardHeight: (1072 - 3 * 12) / 4,
        posterHeight: 210.0,
        captionHeight: (1072 - 3 * 12) / 4 - 4 - 210,
        titleLines: 1,
        capacity: 80,
      ),
    ];

    for (final c in cases) {
      test(c.label, () {
        final layout = resolve(width: c.width, height: c.height, pool: c.pool);
        expect(layout.columns, c.columns, reason: '列');
        expect(layout.rows, c.rows, reason: '行');
        expect(layout.itemCount, c.itemCount, reason: '条数');
        expect(layout.cardHeight, closeTo(c.cardHeight, 1e-9), reason: '卡高');
        expect(
          layout.posterHeight,
          closeTo(c.posterHeight, 1e-9),
          reason: '海报高',
        );
        expect(
          layout.captionHeight,
          closeTo(c.captionHeight, 1e-9),
          reason: '文字区高',
        );
        expect(layout.titleLines, c.titleLines, reason: '片名行数');
        expect(layout.capacity, c.capacity, reason: '一屏容量（列 × 最省卡高行数）');
        expect(
          layout.itemCount,
          lessThanOrEqualTo(layout.capacity),
          reason: '一条都不该超过一屏容量',
        );
        // 卡高恰好等于「海报 + 间隙 + 文字区」（三块拼起来必须等于格子）。
        expect(
          layout.posterHeight + HotRankMetrics.posterGap + layout.captionHeight,
          closeTo(layout.cardHeight, 1e-9),
        );
        // 卡片连起来不能超出可用高（「铺满」的分母）。
        expect(
          layout.rows * layout.cardHeight + (layout.rows - 1) * s,
          lessThanOrEqualTo(c.height + 1e-9),
        );
      });
    }

    test('1273×821 的窗口由 7 张变 14 张（回归：按 254 数行只会有一行）', () {
      // 483 高按旧卡高 254 数：floor((483+12)/266) = 1 行 → 7 张（用户看到的）。
      expect(((483 + s) / (HotRankMetrics.cardHeight + s)).floor(), 1);
      // 按最省卡高 194 数：2 行 → 14 张，底部不再空 200 多像素。
      final layout = resolve(width: 1167, height: 483, pool: 30);
      expect(layout.rows, 2);
      expect(layout.itemCount, 14);
      expect(
        layout.cardHeight,
        closeTo((483 - s) / 2, 1e-9),
        reason: '两行平分「可用高减去一行间距」',
      );
    });

    test('全屏 1811×673 / 30：三行正好铺满，底部一格不空（回归：曾 11×2=22）', () {
      // 旧规则按宽度取 11 列：30 条排不出整 3 行（11×3 > 30）→ 2 整行 22 条，
      // 卡高又被 274 截顶，底部空 113px（用户全屏截图）。
      expect((30 ~/ 11), 2, reason: '11 列时池子只够 2 整行');
      final layout = resolve(width: 1811, height: 673, pool: 30);
      expect(layout.columns, 10);
      expect(layout.rows, 3);
      expect(layout.itemCount, 30);
      expect(layout.fillsScreen, isTrue);
      expect(
        layout.canShuffle,
        isFalse,
        reason: '整个池子都在屏上，换一批换不出新条目',
      );
      // 三行卡片 + 两个间距**正好**等于可用高：底部不留白。
      expect(
        layout.rows * layout.cardHeight + (layout.rows - 1) * s,
        closeTo(673, 1e-9),
      );
      // 列缝 = 格子宽 − 海报宽 + 间距，必须 ≤ 48。
      final cell = (1811 - (layout.columns - 1) * s) / layout.columns;
      expect(cell - HotRankMetrics.posterWidth + s, lessThanOrEqualTo(48));
    });

    test('精确铺满按「卡高最接近 254」取舍：2451×1072 取 4 行而不是 5 行', () {
      // r=4 → h=259（|259-254|=5）；r=5 → h=204.8（|204.8-254|=49.2）。
      // 取 5 行能多摆 16 条，但会把海报从 210 压到 160.8——观感优先。
      final layout = resolve(width: 2451, height: 1072, pool: 300);
      expect(layout.rows, 4);
      expect(layout.cardHeight, closeTo(259, 1e-9));
      expect(layout.capacity, 80, reason: '一屏在最省卡高下能放 16 × 5');
      expect(layout.itemCount, 64);
      expect(layout.canShuffle, isTrue, reason: '池子 300 > 屏上 64');
    });

    test('池子凑不出整行且列数会压到列缝下限之下 → 不凑，走退路', () {
      // 1811 / 673 想要 3 行只能 9 列（27 条），而列缝下限要求至少 10 列 →
      // 退回按宽度取 11 列、2 整行 22 条（11 列时 27 条只够 22）。
      final layout = resolve(width: 1811, height: 673, pool: 27);
      expect(layout.columns, 11, reason: '不为了凑整行把列数压到 9');
      expect(layout.itemCount, 22);
      expect(layout.rows, 2);
    });

    test('密度下限：池子 12 条时不许把列数压成 4 列', () {
      // 3 行要 c = 12 ~/ 3 = 4 列才凑整，但 4 列会让列缝远大于 48 → 走退路：
      // 11 列 × 1 行 = 11 条（12 条装不满 2 整行）。
      final layout = resolve(width: 1811, height: 673, pool: 12);
      expect(layout.columns, 11);
      expect(layout.itemCount, 11);
      expect(layout.rows, 1);
    });
  });

  group('HotRankLayout.resolve：海报高度与片名行数', () {
    test('海报高夹在 [150, 210] 之间，文字区永不为负', () {
      for (final height in [80.0, 120.0, 194.0, 220.0, 300.0, 400.0, 900.0]) {
        final layout = resolve(width: 1167, height: height, pool: 30);
        expect(
          layout.posterHeight,
          inInclusiveRange(0, HotRankMetrics.posterMaxHeight),
        );
        expect(layout.captionHeight, greaterThanOrEqualTo(0));
        expect(
          layout.posterHeight + HotRankMetrics.posterGap + layout.captionHeight,
          closeTo(layout.cardHeight, 1e-9),
        );
        expect(layout.titleLines, inInclusiveRange(0, 2));
      }
    });

    test('片名行数随文字区走：≥56 两行、36~56 一行、再窄不画', () {
      // 1280×600 → 卡高 274、文字区 60 → 两行。
      expect(resolve().titleLines, 2);
      // 1167×483 → 卡高 235.5、文字区 40 → 一行。
      expect(resolve(width: 1167, height: 483).titleLines, 1);
      // 1280×420 → 卡高被摊到 204、文字区 40 → 一行。
      expect(resolve(width: 1280, height: 420).titleLines, 1);
      // 极矮：格子连一行标题都放不下时不画文字（最多牺牲文字，不溢出）。
      expect(resolve(width: 1167, height: 150).titleLines, 0);
    });
  });

  group('HotRankLayout.resolve：按可用宽高算行列', () {
    test('每行数量按「整卡 + 间距」算，行数按最省卡高算', () {
      final layout = resolve();
      expect(layout.columns, ((1280 + s) / (w + s)).floor());
      expect(layout.columns, 8);
      expect(layout.rows, 2);
      expect(
        layout.capacity,
        layout.columns *
            ((600 + s) / (HotRankMetrics.minCardHeight + s)).floor(),
        reason: 'capacity 用最省卡高数出的行数（= 一屏最多能放几张）',
      );
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

    test('高度无限（父级没给约束）时退化为 1 行、卡高回到默认值', () {
      final layout = resolve(width: double.infinity, height: double.infinity);
      expect(layout.columns, 1, reason: '宽度也无限时列数退化为 1');
      expect(layout.rows, 1);
      expect(layout.cardHeight, HotRankMetrics.cardHeight);
      expect(layout.itemCount, 1, reason: '1 列 1 行 → 1 条');
    });

    test('宽度无限但高度有限时，列按 1 算、行照可用高摊', () {
      final layout = resolve(width: double.infinity, height: 483);
      expect(layout.columns, 1);
      expect(layout.rows, 2);
      expect(layout.itemCount, 2);
      expect(layout.cardHeight, closeTo(235.5, 1e-9));
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
      expect(layout.rows, 1, reason: '实际只用 1 行');
      expect(layout.capacity, 16, reason: '一屏仍能放 16 张');
      expect(layout.fillsScreen, isFalse);
      expect(
        layout.canShuffle,
        isTrue,
        reason: '屏上 8 条、池子 10 条，换一批能换出另外 8 条（新语义）',
      );
    });

    test('候选池连一整行都铺不满 → 全显示（没有更好的选择）', () {
      final layout = resolve(pool: 5);
      expect(layout.itemCount, 5);
      expect(layout.rows, 1);
      expect(layout.fillsScreen, isFalse);
      expect(layout.canShuffle, isFalse, reason: '屏上已摆下全部 5 条');
    });

    test('候选池恰好等于一屏容量 → 铺满但不可换', () {
      final layout = resolve(pool: 16);
      expect(layout.itemCount, 16);
      expect(layout.fillsScreen, isTrue);
      expect(layout.canShuffle, isFalse, reason: '再多一条才换得动');
    });

    test('候选池为空 → 不显示任何卡片，但卡高仍按可用高算好', () {
      final layout = resolve(pool: 0);
      expect(layout.itemCount, 0);
      expect(layout.rows, 2, reason: '没有数据时行数就是「能放几行」');
      expect(layout.cardHeight, 274, reason: '高度照算，空态文字也按这个区排版');
      expect(layout.fillsScreen, isFalse);
      expect(layout.canShuffle, isFalse);
      expect(resolve(pool: -3).itemCount, 0);
    });

    test('窄窗口 + 池子够 → 列少但仍是整数行', () {
      // 400 宽 → 2 列；600 高 → 2 行。
      final layout = resolve(width: 400, height: 600, pool: 30);
      expect(layout.columns, 2);
      expect(layout.rows, 2);
      expect(layout.itemCount, 4);
      expect(layout.itemCount % layout.columns, 0);
    });

    test('池子只够部分行时，高度摊给实际行数（不留整行空档）', () {
      // 8 列；820 高按最省卡高能放 4 行（4×194+3×12 = 812 ≤ 820），
      // 池子 24 条只够 3 行 → 高度摊给 3 行：(820 - 2×12) / 3 ≈ 265.33。
      final layout = resolve(width: 1280, height: 820, pool: 24);
      expect(layout.capacity, 32);
      expect(layout.rows, 3);
      expect(layout.itemCount, 24);
      expect(layout.cardHeight, closeTo((820 - 2 * s) / 3, 1e-9));
      expect(layout.cardHeight, lessThan(HotRankMetrics.maxCardHeight));
      expect(layout.posterHeight, 210, reason: '海报已顶到 2:3 上限');
      expect(
        layout.captionHeight,
        closeTo(layout.cardHeight - 4 - 210, 1e-9),
        reason: '多出来的高度全给文字区',
      );
      expect(layout.titleLines, 1);
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
