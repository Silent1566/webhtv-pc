/// Phase 4 · TMDB 配置归一化（`docs/phase4/design/03` §5）。
///
/// 对应门禁：`docs/phase4/design/05` §3.9「sanitize() 13 条 / 别名键 / JWT 判定 /
/// imageBase 归一 / backdropBase 推导 / isReady / 往返幂等」。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/tmdb_config.dart';

void main() {
  group('sanitize() 13 条归一化规则（§5.2）', () {
    test('1. apiBase 补全协议并归一化为以 /3 结尾', () {
      expect(const TmdbConfig(apiBase: 'api.tmdb.org').sanitize().apiBase,
          'https://api.tmdb.org/3');
      expect(const TmdbConfig(apiBase: 'api.tmdb.org/3/').sanitize().apiBase,
          'https://api.tmdb.org/3');
      expect(
        const TmdbConfig(apiBase: 'http://192.168.50.50:3000').sanitize().apiBase,
        'http://192.168.50.50:3000/3',
      );
      expect(const TmdbConfig(apiBase: '').sanitize().apiBase, tmdbDefaultApiBase);
    });

    test('2. apiKey 去空白；空时回退默认空串', () {
      expect(const TmdbConfig(apiKey: '  abc  ').sanitize().apiKey, 'abc');
      expect(const TmdbConfig().sanitize().apiKey, '');
    });

    test('3. accessToken 与 apiKey 相同且不像 JWT 时被清空', () {
      // 非 JWT（无点分段）→ 清空
      final same = const TmdbConfig(apiKey: 'abc', accessToken: 'abc').sanitize();
      expect(same.apiKey, 'abc');
      expect(same.accessToken, '');
      // JWT（≥3 段）→ 保留
      final jwt = const TmdbConfig(
        apiKey: 'a.b.c',
        accessToken: 'a.b.c',
      ).sanitize();
      expect(jwt.accessToken, 'a.b.c');
    });

    test('4. language 缺省 zh-CN', () {
      expect(const TmdbConfig().sanitize().language, 'zh-CN');
      expect(const TmdbConfig(language: 'en-US').sanitize().language, 'en-US');
      expect(const TmdbConfig(language: '  ').sanitize().language, 'zh-CN');
    });

    test('5. imageBase 补协议', () {
      expect(const TmdbConfig(imageBase: 'images.tmdb.org').sanitize().imageBase,
          'https://images.tmdb.org/t/p/w342');
    });

    test('6. backdropBase 为空且 imageBase 是图片主机时推导 w1280', () {
      final config = const TmdbConfig(
        imageBase: 'https://images.tmdb.org/t/p/w500',
        backdropBase: '',
      ).sanitize();
      expect(config.backdropBase, 'https://images.tmdb.org/t/p/w1280');
    });

    test('7. imageBase 是图片主机时补 /t/p/w342', () {
      expect(
        const TmdbConfig(imageBase: 'https://images.tmdb.org').sanitize().imageBase,
        'https://images.tmdb.org/t/p/w342',
      );
      expect(
        const TmdbConfig(imageBase: 'https://images.tmdb.org/t/p/w500').sanitize().imageBase,
        'https://images.tmdb.org/t/p/w342',
      );
      expect(
        const TmdbConfig(imageBase: 'https://images.tmdb.org/t/p').sanitize().imageBase,
        'https://images.tmdb.org/t/p/w342',
      );
    });

    test('8. backdropBase 是图片主机但不含 /t/p/ 时补 w1280', () {
      expect(
        const TmdbConfig(backdropBase: 'https://images.tmdb.org').sanitize().backdropBase,
        'https://images.tmdb.org/t/p/w1280',
      );
      // 已含 /t/p/ 时不重复拼接
      expect(
        const TmdbConfig(backdropBase: 'https://images.tmdb.org/t/p/w1280').sanitize().backdropBase,
        'https://images.tmdb.org/t/p/w1280',
      );
    });

    test('14. 存量的官方 w780 后景自动升到 w1280（清晰度，用户反馈 2026-10-10）', () {
      // 早期默认就是 w780，用户配置里已持久化成 w780；不升级的话全屏背景必然发虚。
      expect(
        const TmdbConfig(
          backdropBase: 'https://images.tmdb.org/t/p/w780',
        ).sanitize().backdropBase,
        'https://images.tmdb.org/t/p/w1280',
      );
    });

    test('14b. 用户显式选定的其它尺寸不被改动（含 original / w300）', () {
      for (final size in const ['original', 'w300', 'w500']) {
        expect(
          TmdbConfig(backdropBase: 'https://images.tmdb.org/t/p/$size')
              .sanitize()
              .backdropBase,
          'https://images.tmdb.org/t/p/$size',
          reason: '只升级「官方图床的 w780」这一档，用户自选尺寸不得被改',
        );
      }
    });

    test('14c. 自建图床的 w780 不被改动（可能不是 TMDB 尺寸语义）', () {
      expect(
        const TmdbConfig(
          backdropBase: 'https://my.mirror/t/p/w780',
        ).sanitize().backdropBase,
        'https://my.mirror/t/p/w780',
      );
    });

    test('9. enabledSites 去空去重保序', () {
      final config = const TmdbConfig(
        enabledSites: ['a', ' ', 'b', 'a', 'c'],
      ).sanitize();
      expect(config.enabledSites, ['a', 'b', 'c']);
    });

    test('10. excludeKeywords 合并进 disabledSites（先兼容字段后显式）', () {
      final config = TmdbConfig.fromMap({
        'excludeKeywords': ['[A]', '[B]'],
        'disabledSites': ['[C]', '[A]'],
      });
      expect(config.disabledSites, ['[A]', '[B]', '[C]']);
    });

    test('11. allowedSites 去空去重保序', () {
      final config = const TmdbConfig(
        allowedSites: ['x', '', 'y', 'x'],
        disabledSites: [],
      ).sanitize();
      expect(config.allowedSites, ['x', 'y']);
    });

    test('12. excludeKeywordsConfigured 缺省时按 disabledSites 是否为空推导', () {
      final withRules = TmdbConfig.fromMap({'disabledSites': ['[A]']});
      expect(withRules.excludeKeywordsConfigured, isTrue);
      final withoutRules = TmdbConfig.fromMap({'disabledSites': []});
      expect(withoutRules.excludeKeywordsConfigured, isFalse);
      final explicit = TmdbConfig.fromMap({
        'excludeKeywordsConfigured': true,
        'disabledSites': [],
      });
      expect(explicit.excludeKeywordsConfigured, isTrue);
    });

    test('13. 未配置且 disabledSites 为空时注入默认规则', () {
      final config = TmdbConfig.fromMap({'disabledSites': []});
      expect(config.disabledSites.length, 11);
    });
  });

  group('别名键兼容（§5.1）', () {
    test('apiKey 的五种别名', () {
      for (final key in ['apiKey', 'apikey', 'api_key', 'tmdbApiKey', 'key']) {
        final config = TmdbConfig.fromMap({key: 'value-$key'});
        expect(config.apiKey, 'value-$key', reason: key);
      }
    });

    test('accessToken 的四种别名', () {
      for (final key in ['accessToken', 'token', 'readAccessToken', 'bearerToken']) {
        final config = TmdbConfig.fromMap({key: 'a.b.c'});
        expect(config.accessToken, 'a.b.c', reason: key);
      }
    });

    test('omdbApiKey 的三种别名', () {
      for (final key in ['omdbApiKey', 'omdbKey', 'imdbApiKey']) {
        final config = TmdbConfig.fromMap({key: 'omdb'});
        expect(config.omdbApiKey, 'omdb', reason: key);
      }
    });

    test('enabledSites 的四种别名', () {
      for (final key in ['enabledSites', 'siteKeys', 'sites', 'matchSites']) {
        final config = TmdbConfig.fromMap({key: ['csp_']});
        expect(config.enabledSites, ['csp_'], reason: key);
      }
    });

    test('allowedSites 的三种别名', () {
      for (final key in ['allowedSites', 'includeSites', 'whitelistSites']) {
        final config = TmdbConfig.fromMap({key: ['x'], 'disabledSites': []});
        expect(config.allowedSites, ['x'], reason: key);
      }
    });

    test('excludeKeywords 的四种别名', () {
      for (final key in ['excludeKeywords', 'exclude', 'blockedKeywords', 'skipKeywords']) {
        final config = TmdbConfig.fromMap({key: ['[A]']});
        expect(config.disabledSites, contains('[A]'), reason: key);
      }
    });

    test('别名优先级：apiKey 优先于 apikey', () {
      final config = TmdbConfig.fromMap({'apiKey': 'first', 'apikey': 'second'});
      expect(config.apiKey, 'first');
    });
  });

  group('isReady（§5.2）', () {
    test('仅 Key / 仅 Token / 都空 / enabled=false', () {
      expect(const TmdbConfig(apiKey: 'k').isReady, isTrue);
      expect(const TmdbConfig(accessToken: 'a.b.c').isReady, isTrue);
      expect(const TmdbConfig().isReady, isFalse);
      expect(const TmdbConfig(apiKey: 'k', enabled: false).isReady, isFalse);
    });

    test('纯空白不算已配置', () {
      expect(const TmdbConfig(apiKey: '   ').sanitize().isReady, isFalse);
    });
  });

  group('apiHost / imageHost（§5.1）', () {
    test('apiHost 去掉 /3 与末尾斜杠', () {
      expect(const TmdbConfig().apiHost, 'https://api.tmdb.org');
      expect(
        const TmdbConfig(apiBase: 'http://192.168.50.50:3000/3').apiHost,
        'http://192.168.50.50:3000',
      );
    });

    test('imageHost 去掉尺寸段与 /t/p', () {
      expect(const TmdbConfig().imageHost, 'https://images.tmdb.org');
      expect(
        const TmdbConfig(imageBase: 'https://images.tmdb.org/t/p/w500').imageHost,
        'https://images.tmdb.org',
      );
      expect(
        const TmdbConfig(imageBase: 'https://cdn.example.com/t/p').imageHost,
        'https://cdn.example.com',
      );
    });

    test('imageHost 非法输入回退默认主机', () {
      expect(const TmdbConfig(imageBase: '::bad::').imageHost, tmdbDefaultImageHost);
    });
  });

  group('往返幂等（§5.1）', () {
    test('toJson → fromJson → toJson 稳定', () {
      final original = TmdbConfig.fromMap({
        'apiKey': 'k',
        'accessToken': 'a.b.c',
        'language': 'en-US',
        'enabledSites': ['csp_'],
        'allowedSites': ['木偶'],
        'disabledSites': ['[音]', '[书]'],
        'smartMatch': false,
        'heuristicSeasonGuessing': false,
      });
      final once = original.toJson();
      final round = TmdbConfig.fromJson(jsonDecode(jsonEncode(once)));
      final twice = round.toJson();
      expect(twice, once);
      expect(round.apiKey, 'k');
      expect(round.accessToken, 'a.b.c');
      expect(round.language, 'en-US');
      expect(round.enabledSites, ['csp_']);
      expect(round.allowedSites, ['木偶']);
      expect(round.disabledSites, ['[音]', '[书]']);
      expect(round.smartMatch, isFalse);
      expect(round.heuristicSeasonGuessing, isFalse);
    });

    test('二次 sanitize 稳定（幂等）', () {
      final once = const TmdbConfig().sanitize();
      final twice = once.sanitize();
      expect(twice.apiBase, once.apiBase);
      expect(twice.imageBase, once.imageBase);
      expect(twice.backdropBase, once.backdropBase);
      expect(twice.disabledSites, once.disabledSites);
      expect(twice.excludeKeywordsConfigured, once.excludeKeywordsConfigured);
    });

    test('toJson(includeCredentials: false) 不含任何凭据', () {
      final config = const TmdbConfig(
        apiKey: 'secret-key',
        accessToken: 'a.b.c',
        omdbApiKey: 'omdb-secret',
      );
      final json = config.toJson(includeCredentials: false);
      final text = jsonEncode(json);
      expect(text, isNot(contains('secret-key')));
      expect(text, isNot(contains('a.b.c')));
      expect(text, isNot(contains('omdb-secret')));
      expect(json.containsKey('apiKey'), isFalse);
      expect(json.containsKey('accessToken'), isFalse);
    });
  });

  group('凭据脱敏（§5.4）', () {
    test('只保留末 4 位', () {
      expect(redactCredential('sk-test-1234567890'), '****7890');
      expect(redactCredential('abcd'), '****');
      expect(redactCredential('abc'), '****');
      expect(redactCredential(''), '');
      expect(redactCredential(null), '');
    });

    test('配置上的脱敏 getter 不泄露原文', () {
      const config = TmdbConfig(apiKey: 'sk-test-1234567890');
      expect(config.redactedApiKey, '****7890');
      expect(config.redactedApiKey, isNot(contains('sk-test')));
      expect(config.redactedAccessToken, '');
    });

    test('toString 不包含凭据', () {
      const config = TmdbConfig(apiKey: 'sk-secret', accessToken: 'a.b.c');
      final text = config.toString();
      expect(text, isNot(contains('sk-secret')));
      expect(text, isNot(contains('a.b.c')));
    });
  });

  group('JSON 输入健壮性', () {
    test('非 Map 输入返回默认配置', () {
      expect(TmdbConfig.fromJson(null).apiBase, tmdbDefaultApiBase);
      expect(TmdbConfig.fromJson('x').apiBase, tmdbDefaultApiBase);
      expect(TmdbConfig.fromJson([1, 2]).apiBase, tmdbDefaultApiBase);
    });

    test('非法类型不抛异常', () {
      expect(
        () => TmdbConfig.fromMap({
          'enabled': 'yes-please',
          'language': 42,
          'enabledSites': 'not-a-list',
          'disabledSites': [1, 2, 3],
          'smartMatch': 'maybe',
        }),
        returnsNormally,
      );
      final config = TmdbConfig.fromMap({
        'enabled': 'yes-please',
        'disabledSites': [1, 2, 3],
      });
      expect(config.enabled, isTrue); // 非布尔回退默认 true
      expect(config.disabledSites, ['1', '2', '3']);
    });

    test('未知字段被忽略但不抛异常', () {
      final config = TmdbConfig.fromMap({
        'futureField': {'must': 'be ignored'},
        'disabledSites': [],
      });
      expect(config.disabledSites.length, 11);
    });
  });

  group('copyWith', () {
    test('逐字段覆盖', () {
      const base = TmdbConfig();
      final updated = base.copyWith(
        apiKey: 'k',
        language: 'ja-JP',
        smartMatch: false,
      );
      expect(updated.apiKey, 'k');
      expect(updated.language, 'ja-JP');
      expect(updated.smartMatch, isFalse);
      // 未覆盖字段保持不变
      expect(updated.apiBase, base.apiBase);
      expect(updated.imageBase, base.imageBase);
    });
  });
}
