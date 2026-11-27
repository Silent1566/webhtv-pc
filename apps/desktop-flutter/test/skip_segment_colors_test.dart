import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/player_options.dart';
import 'package:webhtv_pc/core/skip_plan.dart';
import 'package:webhtv_pc/core/skip_segment_colors.dart';

void main() {
  group('片段颜色偏好', () {
    test('片尾与预告使用不同冷色，避免和已播琥珀混淆', () {
      const colors = SkipSegmentColors();
      expect(colors.colorFor(SkipKind.outro), 0xFFA78BFA);
      expect(colors.colorFor(SkipKind.preview), 0xFF4DABF7);
      expect(colors.colorFor(SkipKind.intro), 0xFF38D9A9);
      expect(SkipKind.values.map(colors.colorFor).toSet(), hasLength(7));
    });

    test('缺失或非法单色使用新版默认，明确保存的旧色和自定义色原样保留', () {
      final fallback = SkipSegmentColors.fromJson({
        'outro': 0,
        'preview': 'invalid',
        'intro': 0xFF123456,
      });
      expect(fallback.colorFor(SkipKind.outro), 0xFFA78BFA);
      expect(fallback.colorFor(SkipKind.preview), 0xFF4DABF7);
      expect(fallback.colorFor(SkipKind.intro), 0xFF123456);
      final saved = PlayerOptions.fromJson({
        'skipMode': 'auto',
        'skipKinds': SkipKindBits.all,
        'skipSegmentColors': {
          'outro': 0xFFFF922B,
          'preview': 0xFFB197FC,
          'intro': 0xFF123456,
        },
      });
      final restored = PlayerOptions.fromJson(saved.toJson());
      expect(restored.skipSegmentColors.colorFor(SkipKind.outro), 0xFFFF922B);
      expect(restored.skipSegmentColors.colorFor(SkipKind.preview), 0xFFB197FC);
      expect(restored.skipSegmentColors.colorFor(SkipKind.intro), 0xFF123456);
      expect(restored.skipMode, SkipMode.auto);
      expect(restored.skipKinds, SkipKindBits.all);
    });
    test('旧配置无颜色字段时七类均可见且彼此区分', () {
      final colors = PlayerOptions.fromJson(const {}).skipSegmentColors;
      final values = SkipKind.values.map(colors.colorFor).toList();
      expect(values.toSet(), hasLength(7));
      expect(values.every((value) => value >> 24 == 0xFF), isTrue);
      expect(const PlayerOptions().skipMode, SkipMode.off);
      expect(const PlayerOptions().skipKinds, SkipKindBits.defaults);
    });

    test('更改一种颜色不影响其他类型或原对象', () {
      const original = SkipSegmentColors();
      final changed = original.withColor(SkipKind.advertisement, 0xFF123456);
      expect(changed.colorFor(SkipKind.advertisement), 0xFF123456);
      expect(original.colorFor(SkipKind.advertisement), isNot(0xFF123456));
      for (final kind in SkipKind.values.where(
        (kind) => kind != SkipKind.advertisement,
      )) {
        expect(changed.colorFor(kind), original.colorFor(kind));
      }
    });

    test('自定义七类颜色经JSON和normalized完整往返', () {
      var colors = const SkipSegmentColors();
      for (final kind in SkipKind.values) {
        colors = colors.withColor(kind, 0xFF112230 + kind.index);
      }
      final options = PlayerOptions(
        skipMode: SkipMode.confirm,
        skipKinds: SkipKindBits.preview,
        skipSegmentColors: colors,
      );
      final json = jsonDecode(jsonEncode(options.toJson()));
      final restored = PlayerOptions.fromJson(json);
      expect(restored.skipSegmentColors, colors);
      expect(restored.skipMode, SkipMode.confirm);
      expect(restored.skipKinds, SkipKindBits.preview);
      expect(options.normalized().skipSegmentColors, colors);
      expect(options.copyWith(cache: false).skipSegmentColors, colors);
      expect((json['skipSegmentColors'] as Map)['postCredits'], 0xFF112234);
    });

    test('坏颜色只回退对应类型，不丢弃其他有效颜色', () {
      final colors = SkipSegmentColors.fromJson({
        'intro': 0xFF123456,
        'recap': -1,
        'outro': 0x00123456,
        'preview': 0x1FF123456,
        'postCredits': 'bad',
        'advertisement': double.nan,
        'intermission': 0xFF123456 + 0.5,
        'unknown': 0xFF000000,
      });
      const defaults = SkipSegmentColors();
      expect(colors.colorFor(SkipKind.intro), 0xFF123456);
      for (final kind in SkipKind.values.where(
        (kind) => kind != SkipKind.intro,
      )) {
        expect(colors.colorFor(kind), defaults.colorFor(kind));
      }
      for (final invalid in [null, 'bad', 42, <Object>[]]) {
        expect(SkipSegmentColors.fromJson(invalid), defaults);
      }
      expect(defaults.withColor(SkipKind.intro, 0), defaults);
    });

    test('颜色值参与PlayerOptions比较与哈希，不被无关更新吞掉', () {
      const defaults = PlayerOptions();
      final changed = defaults.copyWith(
        skipSegmentColors: const SkipSegmentColors().withColor(
          SkipKind.recap,
          0xFF123456,
        ),
      );
      expect(changed, isNot(defaults));
      expect({defaults, changed}, hasLength(2));
      final restored = PlayerOptions.fromJson(changed.toJson());
      expect(restored, changed);
      expect(restored.hashCode, changed.hashCode);
      expect(
        changed.copyWith(skipSegmentColors: const SkipSegmentColors()),
        defaults,
      );
    });
  });
}
