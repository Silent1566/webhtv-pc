/// 自动恢复换线时的「唯一同集」定位。
///
/// 为什么与 `locateEpisodeInLine` 分开：面板定位允许「找不到就回第 1 集」，
/// 那只是预览落点；**自动恢复**一旦落错，用户会从第 1 集重新开始并且没察觉。
/// 这里宁可跳过这条线路，也不猜。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/playback_line_match.dart';

void main() {
  test('唯一集号不能跨季度错配', () {
    expect(
      locateUniqueEpisodeInLine(
        names: const ['S01E03'],
        currentName: 'S02E03',
      ).matched,
      isFalse,
    );
  });

  group('集名精确且唯一 → 命中', () {
    test('同名唯一时按集名命中', () {
      final match = locateUniqueEpisodeInLine(
        names: const ['第01集', '第02集', '第03集'],
        currentName: '第02集',
      );
      expect(match.matched, isTrue);
      expect(match.index, 1);
      expect(match.basis, lineMatchBasisEpisodeName);
      expect(match.skippedReason, isNull);
    });

    test('集名重复出现时视为歧义，不选任何一个', () {
      final match = locateUniqueEpisodeInLine(
        names: const ['第02集', '第02集', '第03集'],
        currentName: '第02集',
      );
      expect(match.matched, isFalse);
      expect(match.index, isNull);
      expect(match.skippedReason, contains('重复'));
    });
  });

  group('集号唯一 → 命中（跨线路命名习惯不同）', () {
    test('“第3集”命中目标线路的“03”', () {
      final match = locateUniqueEpisodeInLine(
        names: const ['01', '02', '03'],
        currentName: '第3集',
      );
      expect(match.matched, isTrue);
      expect(match.index, 2);
      expect(match.basis, lineMatchBasisEpisodeNumber);
    });

    test('同集号命中两处（正片与预告）→ 歧义', () {
      final match = locateUniqueEpisodeInLine(
        names: const ['第03集', '第03集 预告', '第04集'],
        currentName: '03',
      );
      expect(match.matched, isFalse);
      expect(match.skippedReason, contains('集号'));
    });

    test('目标线路没有这一集 → 跳过，绝不回第 1 集', () {
      final match = locateUniqueEpisodeInLine(
        names: const ['第01集', '第02集'],
        currentName: '第08集',
      );
      expect(match.matched, isFalse);
      expect(match.index, isNull);
      expect(match.skippedReason, isNotNull);
    });
  });

  group('无法确认同一集 → 一律跳过', () {
    test('当前集名解析不出集号且不同名', () {
      final match = locateUniqueEpisodeInLine(
        names: const ['正片', '花絮'],
        currentName: '彩蛋',
      );
      expect(match.matched, isFalse);
      expect(match.skippedReason, isNotNull);
    });

    test('当前集名为空', () {
      final match = locateUniqueEpisodeInLine(
        names: const ['第01集'],
        currentName: '',
      );
      expect(match.matched, isFalse);
    });

    test('目标线路没有剧集', () {
      final match = locateUniqueEpisodeInLine(
        names: const [],
        currentName: '第01集',
      );
      expect(match.matched, isFalse);
    });
  });
}
