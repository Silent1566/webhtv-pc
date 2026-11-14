import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/site_order.dart';

void main() {
  group('P1-3 站点健康排序（design/00 §5）', () {
    test('关闭时保持原顺序', () {
      expect(
        orderSiteKeysByHealth(
          keys: ['c', 'a', 'b'],
          enabled: false,
          scores: {'a': 1},
        ),
        ['c', 'a', 'b'],
      );
    });

    test('开启时按成功率降序，无样本排最后', () {
      expect(
        orderSiteKeysByHealth(
          keys: ['no-sample', 'low', 'high'],
          enabled: true,
          scores: {'low': 0.4, 'high': 0.95},
        ),
        ['high', 'low', 'no-sample'],
      );
    });

    test('同分保持原顺序（稳定）', () {
      expect(
        orderSiteKeysByHealth(
          keys: ['b', 'a', 'c'],
          enabled: true,
          scores: {'a': 0.8, 'b': 0.8, 'c': 0.8},
        ),
        ['b', 'a', 'c'],
      );
    });

    test('少于两个站点时原样返回', () {
      expect(
        orderSiteKeysByHealth(keys: ['only'], enabled: true, scores: {}),
        ['only'],
      );
    });
  });

  group('站点排序设置序列化', () {
    test('默认关闭，宽松解析', () {
      expect(const SiteOrderSettings.defaults().healthSort, isFalse);
      expect(SiteOrderSettings.fromJson(null).healthSort, isFalse);
      expect(
        SiteOrderSettings.fromJson({'healthSort': 'yes'}).healthSort,
        isFalse,
      );
      expect(
        SiteOrderSettings.fromJson({'healthSort': true}).healthSort,
        isTrue,
      );
    });

    test('toJson 往返', () {
      const settings = SiteOrderSettings(healthSort: true);
      expect(
        SiteOrderSettings.fromJson(settings.toJson()).healthSort,
        isTrue,
      );
    });
  });

  group('P1-3 站点手动排序（对齐安卓 SiteOrderStore）', () {
    test('没有保存过顺序时保持配置顺序', () {
      expect(
        orderSiteKeysByManual(keys: ['c', 'a', 'b'], savedOrder: const []),
        ['c', 'a', 'b'],
      );
    });

    test('按保存的顺序排列，未知站点保持原顺序追加在后', () {
      expect(
        orderSiteKeysByManual(
          keys: ['a', 'b', 'new-1', 'c', 'new-2'],
          savedOrder: ['c', 'a', 'deleted'],
        ),
        ['c', 'a', 'b', 'new-1', 'new-2'],
      );
    });

    test('稳定性：同一份输入两次调用给出同一份输出', () {
      final first = orderSiteKeysByManual(
        keys: ['x', 'y', 'z', 'w'],
        savedOrder: ['z'],
      );
      final second = orderSiteKeysByManual(
        keys: ['x', 'y', 'z', 'w'],
        savedOrder: ['z'],
      );
      expect(first, second);
    });

    test('只有一个站点时不重排', () {
      expect(
        orderSiteKeysByManual(keys: ['only'], savedOrder: ['other']),
        ['only'],
      );
    });
  });

  group('站点列表覆盖（顺序 + 屏蔽）序列化', () {
    test('空覆盖不写任何键', () {
      expect(SiteListOverrides.empty.isEmpty, isTrue);
      expect(SiteListOverrides.empty.toJson(), isEmpty);
      expect(SiteListOverrides.fromJson(null).isEmpty, isTrue);
      expect(SiteListOverrides.fromJson('garbage').isEmpty, isTrue);
    });

    test('toJson 往返，屏蔽集合排序后写盘', () {
      const overrides = SiteListOverrides(
        order: ['b', 'a'],
        blocked: {'z', 'a'},
      );
      final json = overrides.toJson();
      expect(json['order'], ['b', 'a']);
      expect(json['blocked'], ['a', 'z'], reason: '写盘顺序必须确定');
      final restored = SiteListOverrides.fromJson(json);
      expect(restored.order, ['b', 'a']);
      expect(restored.blocked, {'z', 'a'});
      expect(restored, overrides);
    });

    test('脏数据静默跳过：非字符串/空白/重复项', () {
      final restored = SiteListOverrides.fromJson({
        'order': [' b ', 'b', '', 3, null, 'a'],
        'blocked': [' a ', 'a'],
      });
      expect(restored.order, ['b', 'a']);
      expect(restored.blocked, {'a'});
    });
  });
}
