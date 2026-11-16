import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/subtitle_style.dart';

/// 字幕显示样式模型（\`docs/reference/potplayer-checklist.md\` P1-4）。
///
/// 本文件只锁**模型层**的行为：默认值 / 区间夹取 / 宽松解析 / 往返。
/// 它与渲染投影（\`player_page.dart\` 的 \`SubtitleStyleView\`，见
/// \`phase3_player_display_test.dart\`）和落盘（见
/// \`player_style_persistence_test.dart\`）是三个不同的事实，分开锁。
///
/// **这条断言链的源头是「默认值 == Phase 3–8 的表现」**：默认值一改，
/// 所有没碰过设置的用户外观都会静默变化，所以第一条用例把五个字段的
/// 具体数字钉死，而不是拿 \`defaults\` 跟 \`defaults\` 自比。
void main() {
  group('默认值等于既有外观', () {
    test('白字 / 全透明底 / 2px 描边 / 100% 字号 / 底部 24dp', () {
      const defaults = SubtitleStyle.defaults;
      // 0xFFFFFFFF = \`Colors.white\` 的 ARGB（core 不依赖 Flutter，故存 int）。
      expect(defaults.textColorValue, 0xFFFFFFFF);
      expect(defaults.backgroundOpacity, 0);
      expect(defaults.outlineWidth, 2);
      expect(defaults.textScale, 1);
      expect(defaults.bottomPadding, 24);
      expect(defaults.isDefault, isTrue);
    });

    test('区间常量与弹层 slider 同源（0.6–1.8 / 0–4 / 0–120 / 0–0.8）', () {
      // 这些数字被菜单与底部弹层当上下限用；模型若单独改一处，
      // 就会出现「拖到头却落盘成别的值」（\`subtitle_style.dart:31-42\` 的注释）。
      expect(SubtitleStyle.minTextScale, 0.6);
      expect(SubtitleStyle.maxTextScale, 1.8);
      expect(SubtitleStyle.minOutlineWidth, 0);
      expect(SubtitleStyle.maxOutlineWidth, 4);
      expect(SubtitleStyle.minBottomPadding, 0);
      expect(SubtitleStyle.maxBottomPadding, 120);
      expect(SubtitleStyle.minBackgroundOpacity, 0);
      expect(SubtitleStyle.maxBackgroundOpacity, 0.8);
    });

    test('端点值本身不被夹（夹取只处理越界，不缩区间）', () {
      final style = SubtitleStyle(
        textScale: SubtitleStyle.maxTextScale,
        outlineWidth: SubtitleStyle.maxOutlineWidth,
        bottomPadding: SubtitleStyle.maxBottomPadding,
        backgroundOpacity: SubtitleStyle.maxBackgroundOpacity,
      ).normalized();
      expect(style.textScale, 1.8);
      expect(style.outlineWidth, 4);
      expect(style.bottomPadding, 120);
      expect(style.backgroundOpacity, 0.8);
      // 反向端点同样原样保留，而不是被当作「缺省」回落到默认值。
      final low = SubtitleStyle(
        textScale: SubtitleStyle.minTextScale,
        outlineWidth: SubtitleStyle.minOutlineWidth,
        bottomPadding: SubtitleStyle.minBottomPadding,
        backgroundOpacity: SubtitleStyle.minBackgroundOpacity,
      ).normalized();
      expect(low.textScale, 0.6);
      expect(low.outlineWidth, 0);
      expect(low.bottomPadding, 0);
      expect(low.backgroundOpacity, 0);
    });
  });

  group('越界与非法值', () {
    test('上越界夹到上限：1.8 / 4 / 120 / 0.8', () {
      final style = SubtitleStyle(
        textScale: 9,
        outlineWidth: 10,
        bottomPadding: 999,
        backgroundOpacity: 5,
      ).normalized();
      expect(style.textScale, 1.8);
      expect(style.outlineWidth, 4);
      expect(style.bottomPadding, 120);
      expect(style.backgroundOpacity, 0.8);
    });

    test('下越界夹到下限：0.6 / 0 / 0 / 0（负值不得穿过 0）', () {
      final style = SubtitleStyle(
        textScale: 0.1,
        outlineWidth: -3,
        bottomPadding: -40,
        backgroundOpacity: -0.5,
      ).normalized();
      expect(style.textScale, 0.6);
      expect(style.outlineWidth, 0);
      expect(style.bottomPadding, 0);
      expect(style.backgroundOpacity, 0);
    });

    test('非有限值回落默认（NaN / ±Infinity 没有「夹」的意义）', () {
      final style = SubtitleStyle(
        textScale: double.nan,
        outlineWidth: double.infinity,
        bottomPadding: double.negativeInfinity,
        backgroundOpacity: double.nan,
      ).normalized();
      expect(style, SubtitleStyle.defaults);
    });

    test('单字段非有限时只回落该字段，其余照旧', () {
      final style = SubtitleStyle(textScale: 1.5, outlineWidth: double.nan).normalized();
      expect(style.textScale, 1.5, reason: '合法字段不得被邻居的 NaN 带偏');
      expect(style.outlineWidth, SubtitleStyle.defaults.outlineWidth);
    });

    test('文字色被掩到 32 位：负数值等于 0xAARRGGBB', () {
      // \`Color(-1)\` 与 \`Color(0xFFFFFFFF)\` 是同一个白；落盘只存 32 位，
      // 掩码在这里做，读回来才不会出现「同一个颜色两种写法」。
      expect(SubtitleStyle(textColorValue: -1).normalized().textColorValue, 0xFFFFFFFF);
    });
  });

  group('copyWith / isDefault', () {
    test('copyWith 也走 normalized：拖到越界值不会落成非法值', () {
      final style = SubtitleStyle.defaults.copyWith(
        textScale: 5,
        outlineWidth: -2,
        bottomPadding: 400,
        backgroundOpacity: 3,
      );
      expect(style.textScale, SubtitleStyle.maxTextScale);
      expect(style.outlineWidth, SubtitleStyle.minOutlineWidth);
      expect(style.bottomPadding, SubtitleStyle.maxBottomPadding);
      expect(style.backgroundOpacity, SubtitleStyle.maxBackgroundOpacity);
    });

    test('copyWith 只改传入的字段', () {
      final style = SubtitleStyle.defaults.copyWith(textColorValue: 0xFFFFEB3B);
      expect(style.textColorValue, 0xFFFFEB3B);
      expect(style.outlineWidth, 2);
      expect(style.textScale, 1);
      expect(style.bottomPadding, 24);
      expect(style.backgroundOpacity, 0);
    });

    test('任一字段偏离默认即 isDefault == false，改回默认又成立', () {
      // 偏好存储靠这一位决定「写不写盘」：漏判一个字段，
      // 默认值就会被固化进 settings.json，再也回不到「键不存在」。
      const samples = <SubtitleStyle>[
        SubtitleStyle(textColorValue: 0xFFFFEB3B),
        SubtitleStyle(backgroundOpacity: 0.25),
        SubtitleStyle(outlineWidth: 0),
        SubtitleStyle(textScale: 1.25),
        SubtitleStyle(bottomPadding: 48),
      ];
      for (final sample in samples) {
        expect(sample.isDefault, isFalse, reason: '$sample 偏离默认却没被识别');
      }
      expect(
        const SubtitleStyle(
          textColorValue: 0xFFFFEB3B,
          backgroundOpacity: 0.25,
        ).copyWith(textColorValue: 0xFFFFFFFF, backgroundOpacity: 0),
        SubtitleStyle.defaults,
      );
      expect(SubtitleStyle.defaults.isDefault, isTrue);
    });

    test('== / hashCode 同源：同值可比较，可作 Set 成员', () {
      const a = SubtitleStyle(textScale: 1.25, textColorValue: 0xFFFFEB3B);
      // 同值的另一个实例（不走 const 折叠，刻意让分析器看见两个对象）。
      final b = a.copyWith();
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(<SubtitleStyle>{a, b}, hasLength(1));
      expect(a == a.copyWith(), isTrue, reason: 'copyWith() 不带参数必须等于自身');
      expect(a == SubtitleStyle.defaults, isFalse);
    });
  });

  group('JSON 往返与宽松解析', () {
    test('toJson / fromJson 不丢字段', () {
      const style = SubtitleStyle(
        textColorValue: 0xFF18FFFF,
        backgroundOpacity: 0.5,
        outlineWidth: 3,
        textScale: 1.5,
        bottomPadding: 72,
      );
      final json = style.toJson();
      expect(json, {
        'textColorValue': 0xFF18FFFF,
        'backgroundOpacity': 0.5,
        'outlineWidth': 3.0,
        'textScale': 1.5,
        'bottomPadding': 72.0,
      });
      expect(SubtitleStyle.fromJson(json), style);
    });

    test('缺失键 / 类型不对 / 非 Map 全部回落默认，不抛异常', () {
      // 设置文件可能被手改或来自旧版本，解析必须宽松（\`subtitle_style.dart:113\`）。
      expect(SubtitleStyle.fromJson(null), SubtitleStyle.defaults);
      expect(SubtitleStyle.fromJson('不是对象'), SubtitleStyle.defaults);
      expect(SubtitleStyle.fromJson(const <String, Object?>{}), SubtitleStyle.defaults);
      expect(
        SubtitleStyle.fromJson(const <String, Object?>{
          'textScale': '大',
          'outlineWidth': true,
          'bottomPadding': <String>['x'],
          'backgroundOpacity': null,
          'textColorValue': 'yellow',
        }),
        SubtitleStyle.defaults,
      );
    });

    test('只缺一个键时其余字段照常读回', () {
      final style = SubtitleStyle.fromJson(const <String, Object?>{'textScale': 1.25});
      expect(style.textScale, 1.25);
      expect(style.textColorValue, SubtitleStyle.defaults.textColorValue);
      expect(style.outlineWidth, SubtitleStyle.defaults.outlineWidth);
    });

    test('手改文件里的越界值读回时仍被夹取', () {
      final style = SubtitleStyle.fromJson(const <String, Object?>{
        'textScale': 5,
        'outlineWidth': -3,
        'bottomPadding': 999,
        'backgroundOpacity': 3,
      });
      expect(style.textScale, SubtitleStyle.maxTextScale);
      expect(style.outlineWidth, SubtitleStyle.minOutlineWidth);
      expect(style.bottomPadding, SubtitleStyle.maxBottomPadding);
      expect(style.backgroundOpacity, SubtitleStyle.maxBackgroundOpacity);
    });

    test('整数形式的 double 字段（132 而非 132.0）也能读回', () {
      // JSON 里 \`24\` 解出来是 int，\`value is num\` 必须接住它。
      final style = SubtitleStyle.fromJson(const <String, Object?>{
        'outlineWidth': 3,
        'bottomPadding': 48,
        'textScale': 2,
        'backgroundOpacity': 1,
      });
      expect(style.outlineWidth, 3);
      expect(style.bottomPadding, 48);
      expect(style.textScale, SubtitleStyle.maxTextScale, reason: '2 越界应夹到 1.8');
      expect(style.backgroundOpacity, 0.8, reason: '1 越界应夹到 0.8');
    });
  });
}
