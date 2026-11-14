/// 推荐卡副信息格式门禁（2026-11-12 统一为「年份 · 评分」）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/recommendation_meta.dart';

void main() {
  test('TMDB 形态原样保留', () {
    expect(recommendationMeta('2025 · 7.1'), '2025 · 7.1');
  });

  test('豆瓣：年份 + 结构化评分，去掉来源前缀', () {
    expect(recommendationMeta('2025 · 剧集', doubanRating: 8.2), '2025 · 8.2');
    expect(recommendationMeta('', doubanRating: 8.2), '8.2');
  });

  test('AI：去掉类型与「评分」二字', () {
    expect(recommendationMeta('2023 · 剧集 · 评分 7.4'), '2023 · 7.4');
  });

  test('只有年份或什么都没有时不补空格子', () {
    expect(recommendationMeta('2025'), '2025');
    expect(recommendationMeta(''), '');
    expect(recommendationMeta('   '), '');
  });

  test('结构化评分优先于副信息里的数字', () {
    expect(recommendationMeta('2025 · 6.0', doubanRating: 8.4), '2025 · 8.4');
  });
}
