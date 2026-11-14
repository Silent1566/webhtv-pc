/// 源标识与历史范围开关的纯逻辑测试。
///
/// 这两者都会被写进历史表的唯一键与 `settings.json` 的字面值：
/// 构造规则或归一化方向错了，用户看到的是"历史凭空消失/串源"，
/// 而不会报错。所以边界全部在这里钉住。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/history_scope.dart';
import 'package:webhtv_pc/core/source_key.dart';

void main() {
  group('LocalSourceKey：本地源标识', () {
    test('前缀固定为 local，且可被解析回 origin', () {
      final key = LocalSourceKey.of('https://example.com/config.json');
      expect(key, 'local|https://example.com/config.json');
      final parsed = parseSourceKey(key);
      expect(parsed.isLocal, isTrue);
      expect(parsed.isBridge, isFalse);
      expect(parsed.origin, 'https://example.com/config.json');
    });

    test('结尾斜杠被规范化掉：改地址不该丢历史', () {
      expect(
        LocalSourceKey.of('https://a.com/cfg.json/'),
        LocalSourceKey.of('https://a.com/cfg.json'),
      );
      expect(LocalSourceKey.of('  https://a.com/  '), 'local|https://a.com');
    });

    test('不改变大小写：path 是大小写敏感的', () {
      expect(
        LocalSourceKey.of('https://A.com/Cfg.JSON'),
        'local|https://A.com/Cfg.JSON',
      );
    });

    test('origin 里出现分隔符时仍能精确还原', () {
      // 本地源只用一段，解析时按"剩余全部"拼回，所以 `|` 不必被替换。
      final parsed = parseSourceKey(LocalSourceKey.of('https://a.com/a|b'));
      expect(parsed.isLocal, isTrue);
      expect(parsed.origin, 'https://a.com/a|b');
    });
  });

  group('BridgeSourceKey：安卓源标识', () {
    test('携带设备 uuid 与 interfaceKey 两段', () {
      final key = BridgeSourceKey.of(deviceUuid: 'dev-1', interfaceKey: 'uuid-abc');
      expect(key, 'bridge|dev-1|uuid-abc');
      final parsed = parseSourceKey(key);
      expect(parsed.isBridge, isTrue);
      expect(parsed.isLocal, isFalse);
      expect(parsed.deviceUuid, 'dev-1');
      expect(parsed.interfaceKey, 'uuid-abc');
    });

    test('任一坐标缺失返回空串，不退化成 bridge|| 分区', () {
      expect(BridgeSourceKey.of(deviceUuid: '', interfaceKey: 'k'), '');
      expect(BridgeSourceKey.of(deviceUuid: 'd', interfaceKey: '  '), '');
    });

    test('两台设备的同名 interfaceKey 是不同源', () {
      final a = BridgeSourceKey.of(deviceUuid: 'dev-a', interfaceKey: 'same');
      final b = BridgeSourceKey.of(deviceUuid: 'dev-b', interfaceKey: 'same');
      expect(a, isNot(b));
    });

    test('shortLabel 对长 interfaceKey 截断到 8 位', () {
      final parsed = parseSourceKey(
        BridgeSourceKey.of(
          deviceUuid: 'dev-1',
          interfaceKey: '0123456789abcdef',
        ),
      );
      expect(parsed.shortLabel, 'dev-1/01234567');
    });
  });

  group('parseSourceKey：未知输入不猜', () {
    test('空串是未知源', () {
      final parsed = parseSourceKey(null);
      expect(parsed.kind, sourceKeyKindUnknown);
      expect(parsed.isKnown, isFalse);
    });

    test('陌生前缀落 unknown 而不是 local', () {
      for (final raw in <String>[
        'https://a.com/cfg.json',
        'remote|https://a.com',
        'localhost',
      ]) {
        final parsed = parseSourceKey(raw);
        expect(parsed.kind, sourceKeyKindUnknown, reason: raw);
        expect(parsed.isKnown, isFalse, reason: raw);
      }
    });

    test('分段残缺也算未知', () {
      expect(parseSourceKey('local|').isKnown, isFalse);
      expect(parseSourceKey('bridge|dev-1').isKnown, isFalse);
      expect(parseSourceKey('bridge||key').isKnown, isFalse);
    });

    test('相等性按原始串比较，可作 Map 键', () {
      final a = parseSourceKey(LocalSourceKey.of('https://a.com/'));
      final b = parseSourceKey('local|https://a.com');
      expect(a, b);
      expect({a: 1}[b], 1);
    });
  });

  group('UiHistoryScope：历史范围开关', () {
    test('默认只看当前源', () {
      expect(UiHistoryScope.normalize(null), UiHistoryScope.source);
      expect(UiHistoryScope.normalize(''), UiHistoryScope.source);
      expect(UiHistoryScope.isGlobal(null), isFalse);
    });

    test('global 大小写与空白被归一化', () {
      expect(UiHistoryScope.normalize(' GLOBAL '), UiHistoryScope.global);
      expect(UiHistoryScope.isGlobal('global'), isTrue);
    });

    test('不认识的值回落到当前源，而不是全局', () {
      expect(UiHistoryScope.normalize('all'), UiHistoryScope.source);
      expect(UiHistoryScope.normalize('1'), UiHistoryScope.source);
    });

    test('values 恰好两项，供 UI 与反向解析使用', () {
      expect(UiHistoryScope.values, 
          [UiHistoryScope.source, UiHistoryScope.global]);
    });
  });
}
