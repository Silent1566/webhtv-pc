import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/osd_style.dart';

/// 屏显（OSD）样式模型（\`docs/reference/potplayer-checklist.md\` P1-4）。
///
/// 两个字段都有直接的渲染后果，所以「默认值 == 今天」是硬约束：
/// - \`textScale\` 1 → 正文 14dp / 诊断面板 10dp（\`ui/player_osd.dart:33,306\`）；
/// - \`opacity\` 1 → 整层 \`Opacity(1.0)\`，与新增这一层之前完全一致。
/// 字号生效点在 \`phase8_osd_layer_test.dart\` 里锁（那里能读到真实 TextStyle），
/// 本文件只锁模型。
void main() {
  group('默认值等于既有外观', () {
    test('100% 字号 + 100% 不透明', () {
      const defaults = OsdStyle.defaults;
      expect(defaults.textScale, 1);
      expect(defaults.opacity, 1);
      expect(defaults.isDefault, isTrue);
    });

    test('区间常量：0.8–1.6 / 0.4–1.0（菜单档位与模型同源）', () {
      expect(OsdStyle.minTextScale, 0.8);
      expect(OsdStyle.maxTextScale, 1.6);
      expect(OsdStyle.minOpacity, 0.4);
      expect(OsdStyle.maxOpacity, 1);
    });

    test('端点值本身不被夹（菜单能选到的档位必须能原样落盘）', () {
      final high = const OsdStyle(
        textScale: OsdStyle.maxTextScale,
        opacity: OsdStyle.maxOpacity,
      ).normalized();
      expect(high.textScale, 1.6);
      expect(high.opacity, 1);
      final low = const OsdStyle(
        textScale: OsdStyle.minTextScale,
        opacity: OsdStyle.minOpacity,
      ).normalized();
      expect(low.textScale, 0.8);
      expect(low.opacity, 0.4);
      expect(low.isDefault, isFalse);
    });
  });

  group('越界与非法值', () {
    test('上越界夹到上限：1.6 / 1.0', () {
      final style = const OsdStyle(textScale: 9, opacity: 3).normalized();
      expect(style.textScale, 1.6);
      expect(style.opacity, 1);
    });

    test('下越界夹到下限：0.8 / 0.4（不能淡到看不见）', () {
      final style = const OsdStyle(textScale: 0.1, opacity: 0).normalized();
      expect(style.textScale, 0.8);
      expect(style.opacity, 0.4);
    });

    test('非有限值回落默认，不把 NaN 传进 TextStyle/Opacity', () {
      // NaN 字号会让整层布局塌掉、NaN 不透明度会抛断言——这是「回落」而非「夹」。
      final style = const OsdStyle(
        textScale: double.nan,
        opacity: double.infinity,
      ).normalized();
      expect(style, OsdStyle.defaults);
    });

    test('单字段非有限时只回落该字段', () {
      final style = const OsdStyle(textScale: 1.25, opacity: double.nan).normalized();
      expect(style.textScale, 1.25);
      expect(style.opacity, OsdStyle.defaults.opacity);
    });
  });

  group('copyWith / isDefault', () {
    test('copyWith 也走 normalized', () {
      expect(
        OsdStyle.defaults.copyWith(textScale: 5).textScale,
        OsdStyle.maxTextScale,
      );
      expect(
        OsdStyle.defaults.copyWith(opacity: 0.05).opacity,
        OsdStyle.minOpacity,
      );
    });

    test('copyWith 只改传入的字段', () {
      final style = OsdStyle.defaults.copyWith(textScale: 1.25);
      expect(style.textScale, 1.25);
      expect(style.opacity, 1);
    });

    test('任一字段偏离默认即 isDefault == false，改回默认又成立', () {
      // 与字幕样式同一口径：默认值不写盘，靠这一位判断。
      expect(const OsdStyle(textScale: 1.25).isDefault, isFalse);
      expect(const OsdStyle(opacity: 0.5).isDefault, isFalse);
      expect(
        const OsdStyle(textScale: 1.25, opacity: 0.5).copyWith(
          textScale: 1,
          opacity: 1,
        ),
        OsdStyle.defaults,
      );
    });

    test('== / hashCode 同源', () {
      const a = OsdStyle(textScale: 1.25, opacity: 0.7);
      // 同值的另一个实例（不走 const 折叠，刻意让分析器看见两个对象）。
      final b = a.copyWith();
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(<OsdStyle>{a, b}, hasLength(1));
      expect(a == a.copyWith(), isTrue);
      expect(a == const OsdStyle(textScale: 1.25), isFalse);
    });
  });

  group('JSON 往返与宽松解析', () {
    test('toJson / fromJson 不丢字段', () {
      const style = OsdStyle(textScale: 1.25, opacity: 0.7);
      expect(style.toJson(), {'textScale': 1.25, 'opacity': 0.7});
      expect(OsdStyle.fromJson(style.toJson()), style);
    });

    test('缺失键 / 类型不对 / 非 Map 全部回落默认，不抛异常', () {
      expect(OsdStyle.fromJson(null), OsdStyle.defaults);
      expect(OsdStyle.fromJson(42), OsdStyle.defaults);
      expect(OsdStyle.fromJson(const <String, Object?>{}), OsdStyle.defaults);
      expect(
        OsdStyle.fromJson(const <String, Object?>{
          'textScale': '大字',
          'opacity': <String>['x'],
        }),
        OsdStyle.defaults,
      );
    });

    test('手改文件里的越界值读回时仍被夹取', () {
      final style = OsdStyle.fromJson(const <String, Object?>{
        'textScale': 5,
        'opacity': 0,
      });
      expect(style.textScale, OsdStyle.maxTextScale);
      expect(style.opacity, OsdStyle.minOpacity);
    });

    test('整数形式的字段（opacity: 1）也能读回', () {
      expect(
        OsdStyle.fromJson(const <String, Object?>{'textScale': 1, 'opacity': 1}),
        OsdStyle.defaults,
      );
    });
  });
}
