import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/config_parser.dart';
import 'package:webhtv_pc/core/danmaku_settings.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/site_injection.dart';
import 'package:webhtv_pc/state/local_site_sources.dart';

/// 站点配置最小骨架：解析器要求有 `sites`，弹幕地址与本用例无关。
Map<String, Object?> configJson({Object? danmaku}) => <String, Object?>{
  'name': 'danmaku-config',
  'sites': [
    {'key': 'demo', 'name': '演示', 'type': 1, 'api': 'https://demo.test/vod'},
  ],
  'danmaku': ?danmaku,
};

/// 用一串地址造用户源（id 依次 s1、s2…）。
DanmakuSettings settingsWith(List<String> urls, {bool autoSearch = false}) =>
    DanmakuSettings(
      autoSearch: autoSearch,
      sources: [
        for (var index = 0; index < urls.length; index++)
          DanmakuSourceConfig(
            id: 's${index + 1}',
            name: '源 ${index + 1}',
            url: urls[index],
          ),
      ],
    );

ResolvedDanmakuSources resolve({
  List<String> urls = const [],
  String? configDanmaku,
  String? bundleDanmaku,
}) => resolveDanmakuSources(
  settings: settingsWith(urls),
  configDanmaku: configDanmaku,
  bundleDanmaku: bundleDanmaku,
);

void main() {
  group('弹幕源优先级（design/02 §2.3 / S1 多源）', () {
    test('用户多源优先，忽略站点配置与本地猫源', () {
      final resolved = resolve(
        urls: [
          'http://user-a.test:9321/TOKEN',
          'http://user-b.test:9321/TOKEN',
        ],
        configDanmaku: 'http://config.test/danmaku',
        bundleDanmaku: 'http://bundle.test/danmaku',
      );
      expect(resolved.origin, DanmakuApiSource.user);
      expect(resolved.sources.map((source) => source.url), [
        'http://user-a.test:9321/TOKEN',
        'http://user-b.test:9321/TOKEN',
      ]);
      expect(resolved.label, '手填弹幕源');
      expect(resolved.isConfigured, isTrue);
    });

    test('没有用户源时用站点配置，逗号分隔的多地址逐个成源', () {
      final resolved = resolve(
        configDanmaku: ' http://config-a.test/danmaku , http://config-b.test/danmaku，ftp://bad.test/x ',
        bundleDanmaku: 'http://bundle.test/danmaku',
      );
      expect(resolved.origin, DanmakuApiSource.config);
      expect(resolved.sources.map((source) => source.id), [
        'config-1',
        'config-2',
      ]);
      expect(resolved.sources.map((source) => source.name), [
        '站点配置 1',
        '站点配置 2',
      ]);
      expect(resolved.sources.map((source) => source.url), [
        'http://config-a.test/danmaku',
        'http://config-b.test/danmaku',
      ]);
      expect(resolved.label, '站点配置 danmaku 字段');
    });

    test('站点配置非法时落到本地猫源', () {
      for (final invalid in [
        'ftp://config.test/danmaku', // 非 http(s)
        'http://', // 无 host
        'config.test/danmaku', // 无 scheme
        '   ', // 空白
      ]) {
        final resolved = resolve(
          configDanmaku: invalid,
          bundleDanmaku: 'http://bundle.test/danmaku',
        );
        expect(
          resolved.origin,
          DanmakuApiSource.bundle,
          reason: '候选 "$invalid" 应被判非法并跳过',
        );
        expect(resolved.sources.single.id, 'bundle');
        expect(resolved.sources.single.name, '本地猫源');
        expect(resolved.label, '本地猫源弹幕服务');
      }
    });

    test('全空 → none，且没有可用源', () {
      final resolved = resolve();
      expect(resolved.origin, DanmakuApiSource.none);
      expect(resolved.sources, isEmpty);
      expect(resolved.isConfigured, isFalse);
      expect(resolved.label, '未配置');
    });

    test('全非法 → none', () {
      final resolved = resolve(
        urls: ['ws://user.test/live'],
        configDanmaku: 'http://',
        bundleDanmaku: 'https://',
      );
      expect(resolved.origin, DanmakuApiSource.none);
      expect(resolved.isConfigured, isFalse);
    });

    test('禁用的源与非法地址跳过，重复 url 只留第一条', () {
      const settings = DanmakuSettings(
        sources: [
          DanmakuSourceConfig(
            id: 'off',
            name: '关掉的',
            url: 'http://off.test/danmaku',
            enabled: false,
          ),
          DanmakuSourceConfig(id: 'bad', name: '坏地址', url: 'not-a-url'),
          DanmakuSourceConfig(id: 'a', name: 'A', url: 'http://a.test/danmaku'),
          DanmakuSourceConfig(
            id: 'dup',
            name: '重复',
            url: '  http://a.test/danmaku  ',
          ),
          DanmakuSourceConfig(
            id: 'b',
            name: 'B',
            url: 'https://b.test/danmaku',
          ),
        ],
      );
      final resolved = resolveDanmakuSources(settings: settings);
      expect(resolved.sources.map((source) => source.id), ['a', 'b']);
    });

    test('url 归一到 trim，scheme 大小写不敏感', () {
      final trimmed = resolve(urls: ['  http://user.test/api  ']);
      expect(trimmed.sources.single.url, 'http://user.test/api');
      expect(trimmed.origin, DanmakuApiSource.user);

      final upper = resolve(configDanmaku: ' HTTP://Config.test/danmaku ');
      expect(upper.sources.single.url, 'HTTP://Config.test/danmaku');
      expect(upper.origin, DanmakuApiSource.config);
    });

    test('isValidDanmakuApiUrl 与安卓 isValidApiUrl 对齐', () {
      expect(isValidDanmakuApiUrl('http://a.test/x'), isTrue);
      expect(isValidDanmakuApiUrl('https://a.test'), isTrue);
      expect(isValidDanmakuApiUrl('HTTPS://a.test'), isTrue);
      expect(isValidDanmakuApiUrl('  http://a.test/x  '), isTrue);
      expect(isValidDanmakuApiUrl(null), isFalse);
      expect(isValidDanmakuApiUrl(''), isFalse);
      expect(isValidDanmakuApiUrl('   '), isFalse);
      expect(isValidDanmakuApiUrl('file:///tmp/x.xml'), isFalse);
      expect(isValidDanmakuApiUrl('http://'), isFalse);
      expect(isValidDanmakuApiUrl('example.test/danmaku'), isFalse);
    });

    test('resolveDanmakuApi 兼容包装仍返回首条', () {
      final user = resolveDanmakuApi(
        settings: settingsWith(['http://a.test/x', 'http://b.test/x']),
        configDanmaku: 'http://config.test/danmaku',
      );
      expect(user.source, DanmakuApiSource.user);
      expect(user.url, 'http://a.test/x');
      expect(user.label, '手填地址');

      final config = resolveDanmakuApi(
        settings: const DanmakuSettings(),
        configDanmaku: 'http://c1.test/danmaku, http://c2.test/danmaku',
      );
      expect(config.source, DanmakuApiSource.config);
      expect(config.url, 'http://c1.test/danmaku');

      final none = resolveDanmakuApi(settings: const DanmakuSettings());
      expect(none.source, DanmakuApiSource.none);
      expect(none.isConfigured, isFalse);
    });
  });

  group('多源设置的序列化与旧格式迁移', () {
    test('旧格式 apiUrl 迁移成一条 legacy 源', () {
      final settings = DanmakuSettings.fromJson({
        'autoSearch': true,
        'apiUrl': 'http://legacy.test/danmaku',
      });
      expect(settings.autoSearch, isTrue);
      expect(settings.sources, hasLength(1));
      final source = settings.sources.single;
      expect(source.id, 'legacy');
      expect(source.name, '默认');
      expect(source.url, 'http://legacy.test/danmaku');
      expect(source.enabled, isTrue);
      expect(settings.apiUrl, 'http://legacy.test/danmaku');
      expect(settings.isEnabled, isTrue);
    });

    test('新格式往返（id/name/enabled 都保住）', () {
      const settings = DanmakuSettings(
        autoSearch: true,
        sources: [
          DanmakuSourceConfig(
            id: 'bili',
            name: 'B站',
            url: 'http://bili.test/TOKEN',
            enabled: false,
          ),
          DanmakuSourceConfig(
            id: 'dd',
            name: '弹弹',
            url: 'http://dd.test/TOKEN',
          ),
        ],
      );
      final restored = DanmakuSettings.fromJson(
        jsonDecode(jsonEncode(settings.toJson())),
      );
      expect(restored.autoSearch, isTrue);
      expect(restored.sources, settings.sources);
    });

    test('sources 与 apiUrl 同时存在时以 sources 为准', () {
      final settings = DanmakuSettings.fromJson({
        'sources': [
          {'id': 'new', 'name': '新', 'url': 'http://new.test/danmaku'},
        ],
        'apiUrl': 'http://legacy.test/danmaku',
      });
      expect(settings.sources.single.id, 'new');
      expect(settings.sources.single.url, 'http://new.test/danmaku');

      // 新格式里空数组同样权威：不再回退 apiUrl。
      final empty = DanmakuSettings.fromJson({
        'sources': <Object?>[],
        'apiUrl': 'http://legacy.test/danmaku',
      });
      expect(empty.sources, isEmpty);
      expect(empty.apiUrl, isEmpty);
    });

    test('非法源条目跳过；缺 id/name 用地址兜底', () {
      final settings = DanmakuSettings.fromJson({
        'sources': [
          'not-a-map',
          {'id': 'no-url', 'name': '没有地址'},
          {'url': 'http://fallback.test/danmaku'},
        ],
      });
      expect(settings.sources, hasLength(1));
      final source = settings.sources.single;
      expect(source.url, 'http://fallback.test/danmaku');
      expect(source.id, 'http://fallback.test/danmaku');
      expect(source.name, 'http://fallback.test/danmaku');
      expect(source.enabled, isTrue);
    });

    test('apiUrl 兼容 getter 取第一条启用且合法的地址', () {
      const settings = DanmakuSettings(
        sources: [
          DanmakuSourceConfig(
            id: 'off',
            name: '关掉的',
            url: 'http://off.test/danmaku',
            enabled: false,
          ),
          DanmakuSourceConfig(id: 'bad', name: '坏地址', url: 'nope'),
          DanmakuSourceConfig(
            id: 'ok',
            name: '可用',
            url: '  http://ok.test/danmaku  ',
          ),
        ],
      );
      expect(settings.apiUrl, 'http://ok.test/danmaku');
      expect(settings.hasLibrary, isTrue);
      expect(settings.isEnabled, isFalse, reason: '自动搜索没开');
      expect(settings.copyWith(autoSearch: true).isEnabled, isTrue);
      expect(const DanmakuSettings().apiUrl, isEmpty);
      expect(const DanmakuSettings().hasLibrary, isFalse);
    });

    test('sources 为空时 toJson 不写 sources 键', () {
      final raw = const DanmakuSettings().toJson();
      expect(raw['autoSearch'], isFalse);
      expect(raw.containsKey('sources'), isFalse);
      expect(raw.containsKey('apiUrl'), isFalse);
    });

    test('copyWith(apiUrl:) 写回第一条启用的源（旧设置页入口）', () {
      const base = DanmakuSettings(
        autoSearch: true,
        sources: [
          DanmakuSourceConfig(
            id: 'bili',
            name: 'B站',
            url: 'http://bili.test/d',
          ),
          DanmakuSourceConfig(id: 'dd', name: '弹弹', url: 'http://dd.test/d'),
        ],
      );
      final next = base.copyWith(apiUrl: ' http://new.test/danmaku ');
      expect(next.sources.map((source) => source.url), [
        'http://new.test/danmaku',
        'http://dd.test/d',
      ]);
      expect(next.sources.first.id, 'bili');
      expect(next.sources.first.name, 'B站');
      expect(next.autoSearch, isTrue);
      expect(next.apiUrl, 'http://new.test/danmaku');

      // 还没有任何源时补一条 legacy 源，旧入口才能继续用。
      final created = const DanmakuSettings().copyWith(
        apiUrl: 'http://x.test/danmaku',
      );
      expect(created.sources.single.id, 'legacy');
      expect(created.sources.single.url, 'http://x.test/danmaku');
    });
  });

  group('站点配置 danmaku 字段（AppConfig）', () {
    test('解析后生效，且 extra 不再重复保留', () {
      final document = parseConfigDocument(
        jsonEncode(configJson(danmaku: '  http://relay.test:9321/TOKEN  ')),
      );
      final config = document.config!;
      expect(config.danmaku, 'http://relay.test:9321/TOKEN');
      expect(config.extra.containsKey('danmaku'), isFalse);
    });

    test('toJson 原样回写且只出现一次', () {
      final document = parseConfigDocument(
        jsonEncode(configJson(danmaku: 'http://relay.test:9321/TOKEN')),
      );
      final map = document.config!.toJson();
      expect(map['danmaku'], 'http://relay.test:9321/TOKEN');
      final encoded = jsonEncode(map);
      expect('"danmaku"'.allMatches(encoded).length, 1);
    });

    test('不含该字段时 danmaku 为 null 且不回写', () {
      final document = parseConfigDocument(jsonEncode(configJson()));
      final config = document.config!;
      expect(config.danmaku, isNull);
      expect(config.toJson().containsKey('danmaku'), isFalse);
    });

    test('空白字符串不算配置', () {
      final document = parseConfigDocument(
        jsonEncode(configJson(danmaku: '   ')),
      );
      expect(document.config!.danmaku, isNull);
    });

    test('非字符串值不提升，仍原样留在 extra（导入不丢字段）', () {
      final document = parseConfigDocument(
        jsonEncode(configJson(danmaku: ['http://a.test/x'])),
      );
      final config = document.config!;
      expect(config.danmaku, isNull);
      expect(config.extra['danmaku'], ['http://a.test/x']);
      expect(config.toJson()['danmaku'], ['http://a.test/x']);
    });

    test('copyWith 保留并可替换 danmaku', () {
      final document = parseConfigDocument(
        jsonEncode(configJson(danmaku: 'http://relay.test:9321/TOKEN')),
      );
      final config = document.config!;
      expect(config.copyWith(name: 'renamed').danmaku, config.danmaku);
      expect(
        config.copyWith(danmaku: 'http://other.test/danmaku').danmaku,
        'http://other.test/danmaku',
      );
    });

    test('配置里的 danmaku 进入统一解析（手填优先于它）', () {
      final document = parseConfigDocument(
        jsonEncode(configJson(danmaku: 'http://relay.test:9321/TOKEN')),
      );
      final fromConfig = resolveDanmakuApi(
        settings: const DanmakuSettings(),
        configDanmaku: document.config!.danmaku,
      );
      expect(fromConfig.source, DanmakuApiSource.config);
      expect(fromConfig.url, 'http://relay.test:9321/TOKEN');

      final handWritten = resolveDanmakuApi(
        settings: settingsWith(['http://user.test/api']),
        configDanmaku: document.config!.danmaku,
      );
      expect(handWritten.source, DanmakuApiSource.user);
    });
  });

  // 合并链（注入站 / 本地源）都是逐字段构造 AppConfig：漏一个新字段就会让
  // 「站点配置 danmaku」在装了本地源的机器上静默失效。
  group('配置合并链保留站点配置 danmaku 字段', () {
    const danmakuUrl = 'http://relay.test:9321/TOKEN';

    AppConfig baseConfig() => AppConfig(
      name: 'merged',
      danmaku: danmakuUrl,
      // 顺带放一个未知字段：合并后同样必须保留，防止逐字段构造继续漏项。
      extra: const {'futureTopLevel': 'keep-me'},
    );

    Site site(String key) => Site.fromJson({
      'key': key,
      'name': key,
      'type': 1,
      'api': 'https://$key.test/vod',
    })!;

    test('mergeInjectedSites 保留 danmaku', () {
      final merged = mergeInjectedSites(baseConfig(), [
        InjectedSiteEntry(site: site('inj'), updatedAt: 0),
      ]);
      expect(merged.danmaku, danmakuUrl);
      expect(merged.sites.map((item) => item.key), ['inj']);
      expect(merged.extra['futureTopLevel'], 'keep-me');
    });

    test('mergeLocalSourceSites 保留 danmaku', () {
      final merged = mergeLocalSourceSites(baseConfig(), [site('loc')]);
      expect(merged.config.danmaku, danmakuUrl);
      expect(merged.config.sites.map((item) => item.key), ['loc']);
      expect(merged.config.extra['futureTopLevel'], 'keep-me');
    });

    test('没有原始配置时不伪造 danmaku', () {
      final merged = mergeLocalSourceSites(null, [site('loc')]);
      expect(merged.config.danmaku, isNull);
      expect(merged.config.sites.map((item) => item.key), ['loc']);
    });
  });
}
