/// 相似度过滤核心测试（移植自上游安卓 `SearchResultFilter.java` 行为）。
///
/// 关键语义必须与上游一致：
/// - 完全相等 → 100；
/// - 候选包含查询 → 覆盖率打分（`庆余年` 命中 `庆余年第二季`）；
/// - 数字不一致 → 0（`庆余年2` 不匹配 `庆余年3`）；
/// - 季数中文/阿拉伯数字归一（`第二季` == `S2` == `第2季`）；
/// - 阈值 0 = 不过滤。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/search_result_filter.dart';

void main() {
  group('searchScore 打分语义', () {
    test('完全相等得 100', () {
      expect(searchScore('庆余年', '庆余年'), 100);
    });

    test('包含查询按覆盖率打分且封顶 99', () {
      expect(searchScore('庆余年', '庆余年第二季'), greaterThan(0));
      expect(searchScore('庆余年', '庆余年第二季'), lessThan(100));
    });

    test('数字不一致得 0（庆余年2 ≠ 庆余年3）', () {
      expect(searchScore('庆余年2', '庆余年3'), 0);
    });

    test('数字一致才可能通过编辑距离（庆余年2 ≈ 庆余年 第2季）', () {
      // 季数归一后两边都是「庆余年2」，相等。
      expect(searchScore('庆余年2', '庆余年 第2季'), 100);
      expect(searchScore('庆余年第二季', '庆余年 S2'), 100);
    });

    test('中文季数数字解析（第十一季 → 11）', () {
      expect(searchScore('庆余年 第十一季', '庆余年 第11季'), 100);
      expect(searchScore('庆余年第十一季', '庆余年 第2季'), 0);
    });

    test('完全无关的标题得 0 或极低分', () {
      expect(searchScore('庆余年', '斗罗大陆'), 0);
    });

    test('大小写与标点不敏感', () {
      expect(searchScore('Attack on Titan', 'attack   on titan!'), 100);
    });
  });

  group('searchResultMatches 阈值语义', () {
    test('阈值 0 恒匹配（不过滤）', () {
      expect(searchResultMatches('庆余年', '随便什么', 0), isTrue);
    });

    test('阈值 100 只允许完全一致', () {
      expect(searchResultMatches('庆余年', '庆余年', 100), isTrue);
      expect(searchResultMatches('庆余年', '庆余年第二季', 100), isFalse);
    });

    test('中等阈值放行包含关系', () {
      expect(searchResultMatches('庆余年', '庆余年第二季', 30), isTrue);
    });
  });

  group('filterSearchResults 列表过滤', () {
    test('按阈值过滤列表且保持顺序', () {
      final items = ['庆余年', '庆余年第二季', '斗罗大陆', '庆余年 特别版'];
      final result = filterSearchResults(
        items,
        '庆余年',
        30,
        titleOf: (item) => item,
      );
      expect(result, ['庆余年', '庆余年第二季', '庆余年 特别版']);
    });

    test('阈值 0 返回全部', () {
      final items = ['a', 'b'];
      final result = filterSearchResults(
        items,
        'x',
        0,
        titleOf: (item) => item,
      );
      expect(result.length, 2);
    });

    test('空查询不过滤（避免搜索词归一化为空时全灭）', () {
      final items = ['a', 'b'];
      final result = filterSearchResults(
        items,
        '  ',
        100,
        titleOf: (item) => item,
      );
      expect(result.length, 2);
    });
  });
}
