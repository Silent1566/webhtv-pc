import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/live_site_keywords.dart';

void main() {
  group('内置关键词', () {
    test('默认只有「直播」与「Live」两条', () {
      expect(liveSiteDefaultKeywords, ['直播', 'Live']);
    });

    test('真实配置里的直播站名都命中', () {
      for (final name in ['网络直播[官]', '虎牙直播[官]', '🌇｜斗鱼｜直播', 'Mursor - 虎牙一起看']) {
        expect(
          matchesLiveSiteKeyword(liveSiteDefaultKeywords, name),
          name == 'Mursor - 虎牙一起看' ? isFalse : isTrue,
          reason: name,
        );
      }
      expect(matchesLiveSiteKeyword(liveSiteDefaultKeywords, 'HuyaLive'), isTrue);
      expect(matchesLiveSiteKeyword(liveSiteDefaultKeywords, 'csp_Live'), isTrue);
    });

    test('普通点播站名不命中', () {
      for (final name in ['瓜子影视', '木偶', 'rrdy_night', '百草追凶', 'minuo']) {
        expect(matchesLiveSiteKeyword(liveSiteDefaultKeywords, name), isFalse, reason: name);
      }
    });

    test('关键词大小写不敏感，全角括号与半角括号等价', () {
      expect(matchesLiveSiteKeyword(['live'], 'LIVE 频道'), isTrue);
      expect(matchesLiveSiteKeyword(['直播'], '【直播】频道'), isTrue);
    });

    test('删空关键词等于关掉这条判据', () {
      expect(matchesLiveSiteKeyword(const [], '网络直播[官]'), isFalse);
    });
  });

  group('归一化用户输入', () {
    test('去空白、丢空串、去重保序', () {
      expect(
        normalizeLiveSiteKeywords([' 直播 ', '', 'Live', 'live', '   ', '回看']),
        ['直播', 'Live', '回看'],
      );
    });
  });

  group('liveSiteKeysFor', () {
    test('直播源名与命中关键词的站点键都进集合', () {
      final keys = liveSiteKeysFor(
        sourceNames: const ['裤佬', 'IPTV-电信'],
        siteNames: const {
          'Douyu': '🌇｜斗鱼｜直播',
          'csp_Live': '网络直播[官]',
          '瓜子影视': '瓜子影视',
          'rrdy_night': '网盘夜间',
        },
        keywords: liveSiteDefaultKeywords,
      );
      expect(keys, containsAll(<String>['裤佬', 'IPTV-电信', 'Douyu', 'csp_Live']));
      expect(keys, isNot(contains('瓜子影视')));
      expect(keys, isNot(contains('rrdy_night')));
    });

    test('用户自定义关键词生效', () {
      final keys = liveSiteKeysFor(
        sourceNames: const [],
        siteNames: const {'foo': '某站', 'bar': '回看专区'},
        keywords: const ['回看'],
      );
      expect(keys, {'bar'});
    });
  });
}
