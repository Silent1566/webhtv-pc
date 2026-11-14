import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/site_injection.dart';
import 'package:webhtv_pc/core/protocol.dart';

void main() {
  group('P1-2 站点注入识别（README §4.2）', () {
    test('单个对象', () {
      final sites = parseInjectedSites(
        '{"key":"a","name":"甲","type":1,"api":"https://a.test"}',
      );
      expect(sites, hasLength(1));
      expect(sites.single.key, 'a');
      expect(sites.single.api, 'https://a.test');
    });

    test('数组与 {sites:[...]} 信封', () {
      final array = parseInjectedSites('''
      [{"key":"a","name":"甲","api":"https://a"},
       {"key":"b","name":"乙","api":"https://b"}]
      ''');
      expect(array.map((s) => s.key), ['a', 'b']);

      final envelope = parseInjectedSites(
        '{"sites":[{"key":"c","name":"丙","api":"https://c"}]}',
      );
      expect(envelope.single.key, 'c');
    });

    test('首尾相接的多个片段（含尾随逗号）', () {
      final sites = parseInjectedSites('''
      {"key":"a","name":"甲","api":"https://a",}
      {"key":"b","name":"乙","api":"https://b"}
      ''');
      expect(sites.map((s) => s.key), ['a', 'b']);
    });

    test('空 api 的条目不收（key 可回退为 name，属协议允许）', () {
      final sites = parseInjectedSites('''
      {"key":"n","name":"没有 api","api":""}
      {"key":"ok","name":"可用","api":"https://ok"}
      ''');
      expect(sites.map((s) => s.key), ['ok']);
    });

    test('坏片段跳过但不影响好的片段', () {
      final sites = parseInjectedSites('''
      {"key": broken json
      {"key":"ok","name":"可用","api":"https://ok"}
      ''');
      expect(sites.map((s) => s.key), ['ok']);
    });

    test('同批重复 key：后者覆盖前者', () {
      final sites = parseInjectedSites('''
      {"key":"a","name":"旧","api":"https://old"}
      {"key":"a","name":"新","api":"https://new"}
      ''');
      expect(sites, hasLength(1));
      expect(sites.single.name, '新');
    });
  });

  group('P1-2 配置合并（README §4.2）', () {
    AppConfig config() => AppConfig(
      name: 'base',
      sites: [
        Site(key: 'a', name: '原甲', type: 1, api: 'https://a'),
        Site(key: 'b', name: '原乙', type: 1, api: 'https://b'),
      ],
    );

    InjectedSiteEntry entry(
      String key, {
      String? name,
      bool enabled = true,
      int updatedAt = 1,
    }) => InjectedSiteEntry(
      site: Site(
        key: key,
        name: name ?? key,
        type: 1,
        api: 'https://$key',
      ),
      enabled: enabled,
      updatedAt: updatedAt,
    );

    test('同 key 覆盖原站点、其余追加；原配置不变', () {
      final base = config();
      final merged = mergeInjectedSites(base, [
        entry('a', name: '注入甲'),
        entry('c'),
      ]);
      expect(merged.sites.map((s) => s.key), ['a', 'b', 'c']);
      expect(merged.sites.first.name, '注入甲');
      // 原配置对象未被改写。
      expect(base.sites.map((s) => s.key), ['a', 'b']);
      expect(base.sites.first.name, '原甲');
    });

    test('停用的注入不参与合并', () {
      final merged = mergeInjectedSites(config(), [
        entry('a', name: '注入甲', enabled: false),
        entry('c', enabled: false),
      ]);
      expect(merged.sites.map((s) => s.key), ['a', 'b']);
      expect(merged.sites.first.name, '原甲');
    });

    test('没有注入时返回同一配置对象', () {
      final base = config();
      expect(identical(mergeInjectedSites(base, const []), base), isTrue);
    });
  });

  group('P1-2 注入条目序列化', () {
    test('toJson/fromJson 往返', () {
      final entry = InjectedSiteEntry(
        site: Site(key: 'a', name: '甲', type: 4, api: 'https://a'),
        enabled: false,
        updatedAt: 123,
      );
      final restored = InjectedSiteEntry.fromJson(entry.toJson());
      expect(restored.key, 'a');
      expect(restored.enabled, isFalse);
      expect(restored.updatedAt, 123);
      expect(restored.site.type, 4);
    });

    test('损坏记录抛 FormatException（由存储层跳过）', () {
      expect(
        () => InjectedSiteEntry.fromJson({'site': {}}),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
