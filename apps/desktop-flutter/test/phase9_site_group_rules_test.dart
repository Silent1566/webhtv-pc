import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/site_group.dart';
import 'package:webhtv_pc/core/site_group_rules.dart';

void main() {
  group('P1-5 分组规则（README §4.2）', () {
    test('4 条内置规则都能抽取', () {
      expect(siteGroupsWithRules('木偶[盘]', rules: builtinSiteGroupRules), ['盘']);
      expect(
        siteGroupsWithRules('在线之家[采][盘]', rules: builtinSiteGroupRules),
        ['采', '盘'],
      );
      expect(
        siteGroupsWithRules('影视 | 高清', rules: builtinSiteGroupRules),
        ['高清'],
      );
      expect(
        siteGroupsWithRules('某站 ┆ 蓝光', rules: builtinSiteGroupRules),
        ['蓝光'],
      );
      expect(
        siteGroupsWithRules('某站 • 官', rules: builtinSiteGroupRules),
        ['官'],
      );
    });

    test('关闭某条内置规则后不再命中', () {
      final rules = [
        for (final rule in builtinSiteGroupRules)
          if (rule.id == 'builtin_bracket_tag')
            rule.copyWith(enabled: false)
          else
            rule,
      ];
      expect(siteGroupsWithRules('木偶[盘]', rules: rules), isEmpty);
      expect(siteGroupsWithRules('影视 | 高清', rules: rules), ['高清']);
    });

    test('自定义规则生效且保持顺序、去重', () {
      final rules = [
        ...builtinSiteGroupRules,
        const SiteGroupRule(
          id: 'custom-hash',
          name: '井号标签',
          pattern: r'#([^#]+)#',
        ),
      ];
      expect(
        siteGroupsWithRules('木偶[盘] #采# #盘#', rules: rules),
        ['盘', '采'],
      );
    });

    test('非法正则被跳过，不影响其他规则', () {
      final rules = [
        const SiteGroupRule(id: 'bad', name: '坏规则', pattern: '('),
        ...builtinSiteGroupRules,
      ];
      expect(siteGroupsWithRules('木偶[盘]', rules: rules), ['盘']);
    });

    test('旧入口 siteGroupsOf 默认使用内置规则', () {
      expect(siteGroupsOf('木偶[盘]'), ['盘']);
      expect(siteInGroup('木偶[盘]', '盘'), isTrue);
      expect(siteInGroup('木偶[盘]', '采'), isFalse);
    });
  });

  group('P1-5 规则配置序列化', () {
    test('默认 4 条内置全开', () {
      const settings = SiteGroupSettings.defaults();
      expect(settings.rules, hasLength(4));
      expect(settings.rules.every((r) => r.enabled), isTrue);
    });

    test('缺失的内置规则补默认、关闭状态保留、自定义保留', () {
      final parsed = SiteGroupSettings.fromJson({
        'rules': [
          {
            'id': 'builtin_bracket_tag',
            'name': '方括号标签',
            'pattern': r'\[([^\]]+)\]',
            'enabled': false,
          },
          {
            'id': 'custom-x',
            'name': '自定义',
            'pattern': r'<([^>]+)>',
            'enabled': true,
          },
          {'id': 'bad', 'name': '坏', 'pattern': '('},
        ],
      });
      expect(parsed.rules.first.enabled, isFalse);
      expect(
        parsed.rules.firstWhere((r) => r.id == 'builtin_pipe_quality').enabled,
        isTrue,
      );
      expect(parsed.rules.where((r) => r.id == 'custom-x'), hasLength(1));
      expect(parsed.rules.where((r) => r.id == 'bad'), isEmpty);
      expect(
        parsed.enabledRules.any((r) => r.id == 'builtin_bracket_tag'),
        isFalse,
      );
    });

    test('toJson 往返', () {
      const settings = SiteGroupSettings(
        rules: [
          SiteGroupRule(
            id: 'custom-a',
            name: 'A',
            pattern: r'#([^#]+)#',
            enabled: false,
          ),
        ],
      );
      final restored = SiteGroupSettings.fromJson(settings.toJson());
      expect(
        restored.rules.firstWhere((r) => r.id == 'custom-a').enabled,
        isFalse,
      );
    });
  });
}
