/// 站点名分组与搜索规则（对齐上游「默影视」`GroupRuleConfig`）。
///
/// 用户反馈 2026-10-09：站点选择界面需要搜索和分组，「数据上也不用显示什么
/// key=啥，名称即可」。分组数据来自**站点名里的方括号标记**（TVBox 生态的事实
/// 约定），配置里没有 group 字段可用，因此这里锁住抽取规则本身。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/site_group.dart';

void main() {
  group('分组抽取（站点名标记）', () {
    test('方括号后缀是分组', () {
      expect(siteGroupsOf('木偶[盘]'), ['盘']);
      expect(siteGroupsOf('金牌影视[采]'), ['采']);
      expect(siteGroupsOf('BiliBili[官]'), ['官']);
    });

    test('多个标记按出现顺序全部保留', () {
      expect(siteGroupsOf('在线之家[采][盘]'), ['采', '盘']);
      expect(siteGroupsOf('Emby[4K]'), ['4K']);
    });

    test('无标记的站点没有分组（不得凭空造「其他」）', () {
      expect(siteGroupsOf('1234影视'), isEmpty);
      expect(siteGroupsOf('片单导航'), isEmpty);
      expect(siteGroupsOf(''), isEmpty);
    });

    test('竖线后缀也是分组（上游第 2 条内置规则）', () {
      expect(siteGroupsOf('影视 | 高清'), ['高清']);
      expect(siteGroupsOf('站点｜备用'), ['备用']);
    });

    test('重复标记只算一个分组', () {
      expect(siteGroupsOf('[盘][盘]'), ['盘']);
    });

    test('inGroup：空分组 = 全部', () {
      expect(siteInGroup('木偶[盘]', ''), isTrue);
      expect(siteInGroup('木偶[盘]', '盘'), isTrue);
      expect(siteInGroup('木偶[盘]', '采'), isFalse);
      expect(siteInGroup('1234影视', '盘'), isFalse);
    });
  });

  group('搜索匹配', () {
    test('按名称子串匹配，大小写不敏感', () {
      expect(
        siteMatchesQuery(name: 'BiliBili[官]', key: 'csp_BiliBili', query: 'bili'),
        isTrue,
      );
      expect(
        siteMatchesQuery(name: '木偶[盘]', key: '02544b32', query: '木偶'),
        isTrue,
      );
    });

    test('空关键字匹配全部', () {
      expect(siteMatchesQuery(name: '任意', key: 'k', query: ''), isTrue);
      expect(siteMatchesQuery(name: '任意', key: 'k', query: '   '), isTrue);
    });

    test('不命中时返回 false', () {
      expect(
        siteMatchesQuery(name: '木偶[盘]', key: '02544b32', query: '不存在'),
        isFalse,
      );
    });

    test('按 key 也能搜到（调试场景）', () {
      expect(
        siteMatchesQuery(name: '木偶[盘]', key: '02544b32', query: '02544b'),
        isTrue,
      );
    });
  });
}
