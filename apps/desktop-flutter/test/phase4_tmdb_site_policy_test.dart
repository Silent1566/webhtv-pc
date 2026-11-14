/// Phase 4 · TMDB 站点策略（`docs/phase4/design/01` §6）。
///
/// 对应门禁：`docs/phase4/design/05` §3.3 用例组 1–6。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/tmdb_config.dart';

void main() {
  group('站点策略 7 步判定顺序（§6.1）', () {
    test('1. 黑名单精确命中 → 禁用（优先级最高，压过白名单与启用规则）', () {
      const config = TmdbConfig(
        enabledSites: ['csp_A'],
        allowedSites: ['csp_A'],
        disabledSites: ['csp_A'],
      );
      expect(config.isSiteEnabled('csp_A', ''), isFalse);
      // name 命中同样生效
      expect(config.isSiteEnabled('other', 'csp_A'), isFalse);
    });

    test('2. 白名单精确命中 → 启用（压过黑名单子串）', () {
      const config = TmdbConfig(
        disabledSites: ['[书]'],
        allowedSites: ['[书]csp_B'],
      );
      // 精确白名单命中 → 启用，尽管黑名单子串也命中
      expect(config.isSiteEnabled('[书]csp_B', ''), isTrue);
    });

    test('3. 启用规则精确命中 → 启用（压过黑名单子串）', () {
      const config = TmdbConfig(
        enabledSites: ['[书]csp_B'],
        disabledSites: ['[书]'],
      );
      expect(config.isSiteEnabled('[书]csp_B', ''), isTrue);
    });

    test('4. 黑名单子串命中 → 禁用', () {
      const config = TmdbConfig(disabledSites: ['[书]']);
      expect(config.isSiteEnabled('csp_某书[书]源', ''), isFalse);
      expect(config.isSiteEnabled('x', '我的[书]库'), isFalse);
    });

    test('5. 启用规则为空 → 允许', () {
      const config = TmdbConfig(disabledSites: [], enabledSites: []);
      expect(config.isSiteEnabled('csp_任意', ''), isTrue);
      expect(config.isSiteEnabled('x', '任意名'), isTrue);
    });

    test('6. 启用规则子串命中 → 允许', () {
      const config = TmdbConfig(enabledSites: ['csp_'], disabledSites: []);
      expect(config.isSiteEnabled('csp_PianDan', ''), isTrue);
      expect(config.isSiteEnabled('x', 'csp_站点'), isTrue);
    });

    test('7. 否则拒绝（启用规则非空且都未命中）', () {
      const config = TmdbConfig(enabledSites: ['csp_'], disabledSites: []);
      expect(config.isSiteEnabled('木偶', ''), isFalse);
      expect(config.isSiteEnabled('x', '木偶'), isFalse);
    });
  });

  group('括号归一（§6.2）', () {
    test('五种全角写法归一到半角', () {
      expect(normalizeBrackets('「音」'), '[音]');
      expect(normalizeBrackets('【音】'), '[音]');
      expect(normalizeBrackets('〔音〕'), '[音]');
      expect(normalizeBrackets('［音］'), '[音]');
      expect(normalizeBrackets('[音]'), '[音]');
    });

    test('猫源全角括号可被半角规则命中（不做归一则一条也匹配不上）', () {
      const config = TmdbConfig(disabledSites: ['[音]']);
      expect(config.isSiteEnabled('csp_有声「音」站', ''), isFalse);
      expect(config.isSiteEnabled('csp_有声【音】站', ''), isFalse);
      expect(config.isSiteEnabled('csp_有声〔音〕站', ''), isFalse);
    });

    test('「设」配置 被无括号规则「配置」命中', () {
      const config = TmdbConfig(disabledSites: ['配置']);
      expect(config.isSiteEnabled('csp_「设」配置', ''), isFalse);
      expect(config.isSiteEnabled('csp_[配置]站', ''), isFalse);
      expect(config.isSiteEnabled('csp_配置站', ''), isFalse);
    });
  });

  group('不可互换的写法（§6.2 子串包含语义）', () {
    test('[书] 不命中 [小说]xxx', () {
      const config = TmdbConfig(disabledSites: ['[书]']);
      // `[书]` 命中 `[书]xxx`
      expect(config.isSiteEnabled('[书]某站', ''), isFalse);
      // 但不命中 `[小说]xxx`——`[小说]` 里 `[书` 后面跟的是 `说` 而非 `]`
      expect(config.isSiteEnabled('[小说]某站', ''), isTrue);
    });

    test('[漫] 不命中 [漫画]xxx', () {
      const config = TmdbConfig(disabledSites: ['[漫]']);
      expect(config.isSiteEnabled('[漫]某站', ''), isFalse);
      expect(config.isSiteEnabled('[漫画]某站', ''), isTrue);
    });

    test('同时保留 [书] 与 [小说] 时两者都被命中', () {
      const config = TmdbConfig(disabledSites: ['[书]', '[小说]']);
      expect(config.isSiteEnabled('[书]某站', ''), isFalse);
      expect(config.isSiteEnabled('[小说]某站', ''), isFalse);
    });

    test('同时保留 [漫] 与 [漫画] 时两者都被命中', () {
      const config = TmdbConfig(disabledSites: ['[漫]', '[漫画]']);
      expect(config.isSiteEnabled('[漫]某站', ''), isFalse);
      expect(config.isSiteEnabled('[漫画]某站', ''), isFalse);
    });
  });

  group('默认禁用规则（§6.2）', () {
    test('未配置时启用 11 条默认规则', () {
      final config = const TmdbConfig().sanitize();
      expect(config.disabledSites.length, 11);
      for (final rule in tmdbDefaultDisabledRules) {
        expect(config.disabledSites, contains(rule));
      }
      // 规则内容逐条核对（含 [书]/[小说]、[漫]/[漫画] 并存）
      expect(
        config.disabledSites,
        containsAll(['[音]', '[听]', '[书]', '[漫]', '[短]', '[设]', '[画]', '[漫画]', '[小说]', '配置', '[配]']),
      );
    });

    test('默认规则能拦住非影视站点', () {
      final config = const TmdbConfig().sanitize();
      for (final site in [
        '[音]某音频站',
        '[听]有声站',
        '[书]小说站',
        '[漫]漫画站',
        '[短]短剧站',
        '[设]配置站',
        '[画]画站',
        '[漫画]漫画站2',
        '[小说]小说站2',
        '某配置站',
        '[配]配置站2',
      ]) {
        expect(config.isSiteEnabled(site, ''), isFalse, reason: site);
      }
      // 影视站点放行
      expect(config.isSiteEnabled('csp_PianDan', ''), isTrue);
      expect(config.isSiteEnabled('木偶', ''), isTrue);
    });

    test('显式配置 disabledSites 时不注入默认规则', () {
      final config = const TmdbConfig(disabledSites: ['[广告]']).sanitize();
      expect(config.disabledSites, ['[广告]']);
      expect(config.disabledSites, isNot(contains('[音]')));
    });

    test('显式配置 excludeKeywordsConfigured = false 且 disabledSites 为空时用默认规则', () {
      final config = TmdbConfig.fromMap({
        'excludeKeywordsConfigured': false,
      });
      expect(config.disabledSites.length, 11);
    });

    test('withDefaultDisabledRules 重置规则', () {
      final custom = const TmdbConfig(disabledSites: ['[x]']).sanitize();
      expect(custom.disabledSites, ['[x]']);
      final reset = custom.withDefaultDisabledRules();
      expect(reset.disabledSites.length, 11);
      expect(reset.excludeKeywordsConfigured, isTrue);
    });
  });

  group('hasSiteRules', () {
    test('任一规则非空即视为有规则', () {
      expect(const TmdbConfig(disabledSites: []).hasSiteRules, isFalse);
      expect(const TmdbConfig(disabledSites: ['[音]']).hasSiteRules, isTrue);
      expect(const TmdbConfig(enabledSites: ['a'], disabledSites: []).hasSiteRules, isTrue);
      expect(const TmdbConfig(allowedSites: ['a'], disabledSites: []).hasSiteRules, isTrue);
    });
  });
}
