import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/player_options.dart';
import 'package:webhtv_pc/core/skip_plan.dart';
import 'package:webhtv_pc/core/skip_segment_colors.dart';

void main() {
  test('旧配置默认显示片段高亮，坏值不关闭已有标记', () {
    for (final raw in [
      null,
      const {},
      {'showSkipSegmentHighlights': 'false'},
    ]) {
      expect(PlayerOptions.fromJson(raw).showSkipSegmentHighlights, isTrue);
    }
    expect(const PlayerOptions().showSkipSegmentHighlights, isTrue);
  });

  test('关闭高亮独立持久化，不影响跳过模式、类型与自定义颜色', () {
    final colors = const SkipSegmentColors().withColor(
      SkipKind.outro,
      0xFF123456,
    );
    final original = PlayerOptions(
      skipMode: SkipMode.auto,
      skipKinds: SkipKindBits.all,
      skipSegmentColors: colors,
    );
    final hidden = original.copyWith(showSkipSegmentHighlights: false);
    final restored = PlayerOptions.fromJson(
      jsonDecode(jsonEncode(hidden.toJson())),
    );
    expect(restored.showSkipSegmentHighlights, isFalse);
    expect(restored.skipMode, SkipMode.auto);
    expect(restored.skipKinds, SkipKindBits.all);
    expect(restored.skipSegmentColors, colors);
    expect(restored.normalized().showSkipSegmentHighlights, isFalse);
    expect(restored.copyWith(cache: false).showSkipSegmentHighlights, isFalse);
    expect(restored.copyWith(showSkipSegmentHighlights: true), original);
    expect(hidden, isNot(original));
    expect({hidden, original}, hasLength(2));
    expect(restored.hashCode, hidden.hashCode);
  });
}
