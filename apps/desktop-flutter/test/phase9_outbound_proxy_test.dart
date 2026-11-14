import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/outbound_proxy.dart';
import 'package:webhtv_pc/services/outbound_proxy.dart';

void main() {
  group('P1-9 出站代理裁决（README §4.2）', () {
    const settings = OutboundProxySettings(
      enabled: true,
      defaultProxyUrl: 'http://127.0.0.1:7891',
      rules: [
        OutboundProxyRule(
          patterns: ['example.com', '*.example.org'],
          proxyUrl: 'http://127.0.0.1:7890',
        ),
      ],
    );

    test('关闭时一律直连', () {
      const off = OutboundProxySettings(
        defaultProxyUrl: 'http://127.0.0.1:7890',
      );
      expect(resolveOutboundProxy(off, 'example.com'), isNull);
      expect(
        findProxyValue(off, Uri.parse('https://example.com/a')),
        'DIRECT',
      );
    });

    test('规则命中：精确与通配子域', () {
      expect(
        resolveOutboundProxy(settings, 'example.com'),
        '127.0.0.1:7890',
      );
      expect(
        resolveOutboundProxy(settings, 'a.example.com'),
        '127.0.0.1:7890',
      );
      expect(
        resolveOutboundProxy(settings, 'x.example.org'),
        '127.0.0.1:7890',
      );
    });

    test('未命中走默认代理；默认空则直连', () {
      expect(
        resolveOutboundProxy(settings, 'other.test'),
        '127.0.0.1:7891',
      );
      const noDefault = OutboundProxySettings(
        enabled: true,
        rules: [
          OutboundProxyRule(
            patterns: ['example.com'],
            proxyUrl: 'http://127.0.0.1:7890',
          ),
        ],
      );
      expect(resolveOutboundProxy(noDefault, 'other.test'), isNull);
    });

    test('主机名大小写与前后空格无关', () {
      expect(outboundProxyMatches('EXAMPLE.com', ' example.com '), isTrue);
      expect(outboundProxyMatches('a.example.com', 'example.com'), isTrue);
      expect(outboundProxyMatches('badexample.com', 'example.com'), isFalse);
    });

    test('非法代理地址被丢弃，且不影响其他规则', () {
      const broken = OutboundProxySettings(
        enabled: true,
        rules: [
          OutboundProxyRule(patterns: ['bad.test'], proxyUrl: 'socks5://x'),
          OutboundProxyRule(
            patterns: ['ok.test'],
            proxyUrl: 'http://127.0.0.1:7890',
          ),
        ],
      );
      expect(broken.validRules, hasLength(1));
      expect(resolveOutboundProxy(broken, 'bad.test'), isNull);
      expect(resolveOutboundProxy(broken, 'ok.test'), '127.0.0.1:7890');
    });

    test('isEffective：需要开启且至少一条可用规则/默认', () {
      expect(const OutboundProxySettings().isEffective, isFalse);
      expect(
        const OutboundProxySettings(enabled: true).isEffective,
        isFalse,
      );
      expect(settings.isEffective, isTrue);
    });
  });

  group('P1-9 设置序列化与客户端工厂', () {
    test('toJson/fromJson 往返', () {
      const settings = OutboundProxySettings(
        enabled: true,
        defaultProxyUrl: 'http://127.0.0.1:7891',
        rules: [
          OutboundProxyRule(
            patterns: ['a.test'],
            proxyUrl: 'http://127.0.0.1:7890',
          ),
        ],
      );
      final restored = OutboundProxySettings.fromJson(settings.toJson());
      expect(restored, settings);
    });

    test('非法条目在解析时被过滤', () {
      final parsed = OutboundProxySettings.fromJson({
        'enabled': true,
        'rules': [
          {'patterns': <String>[], 'proxyUrl': 'http://127.0.0.1:1'},
          {'patterns': ['a.test'], 'proxyUrl': 'not-a-url'},
          {'patterns': ['b.test'], 'proxyUrl': 'http://127.0.0.1:2'},
        ],
      });
      expect(parsed.rules, hasLength(1));
      expect(parsed.rules.single.proxyUrl, 'http://127.0.0.1:2');
    });

    test('关闭时返回普通客户端；开启时返回可用客户端', () {
      final off = createOutboundHttpClient(const OutboundProxySettings());
      expect(off, isNotNull);
      off.close();

      final on = createOutboundHttpClient(
        const OutboundProxySettings(
          enabled: true,
          defaultProxyUrl: 'http://127.0.0.1:7890',
        ),
      );
      expect(on, isNotNull);
      on.close();
    });
  });
}
