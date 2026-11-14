/// Phase 5 · 安卓 T4 站点桥接纯逻辑（`docs/phase5/design/01`）。
///
/// 对应门禁：`docs/phase5/design/03` §3.1「网关地址规范化 / 设备 JSON 解析 /
/// T4 配置转换 / 主机一致性三态 / 站点保真 / 自引用防护」。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/android_bridge.dart';
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/core/config_parser.dart';
import 'package:webhtv_pc/core/http_api.dart';
import 'package:webhtv_pc/core/protocol.dart';

import 'fixture_support.dart';

/// 解析 fixture JSON 文本。
Object? decodeFixture(String text) => jsonDecode(text);

/// 把内联测试数据编码为 JSON 文本。
String encodeFixture(Object? value) => jsonEncode(value);

/// 把 fixture 里的 `__HOST__` 占位符替换成给定主机（保留端口写法）。
String withHost(String json, String host) =>
    json.replaceAll('http://__HOST__', host);

/// 断言抛出指定类别的 [AppError]。
AppError throwsKind(void Function() body, AppErrorKind kind) {
  try {
    body();
  } on AppError catch (error) {
    expect(
      error.kind,
      kind,
      reason: '期望 $kind，实际 ${error.kind}（${error.message}）',
    );
    return error;
  }
  fail('期望抛出 AppError($kind)，但没有抛出任何错误');
}

const String reachable = 'http://192.168.1.5:9978';

void main() {
  group('网关地址规范化（design/01 §4.2）', () {
    test('缺 scheme 补 http://，缺端口补 9978', () {
      expect(normalizeBase('192.168.1.5'), 'http://192.168.1.5:9978');
    });

    test('带路径只取 scheme+host+port', () {
      expect(
        normalizeBase('http://192.168.1.5:9978/vod/api?ac=config'),
        'http://192.168.1.5:9978',
      );
    });

    test('去尾随斜杠', () {
      expect(normalizeBase('http://192.168.1.5:9978/'), 'http://192.168.1.5:9978');
    });

    test('localhost 保留原样（不改写成 127.0.0.1）', () {
      expect(normalizeBase('localhost:19978'), 'http://localhost:19978');
    });

    test('保留 https 与显式端口', () {
      expect(normalizeBase('https://example.com:8443'), 'https://example.com:8443');
    });

    test('拒绝非法 scheme', () {
      throwsKind(
        () => normalizeBase('ftp://192.168.1.5:9978'),
        AppErrorKind.bridgeUnreachable,
      );
    });

    test('拒绝空地址', () {
      throwsKind(() => normalizeBase('   '), AppErrorKind.bridgeUnreachable);
    });

    test('hostPortOf 取 host:port；isLoopbackHost 覆盖 127/8 与 localhost', () {
      expect(hostPortOf('192.168.1.5'), '192.168.1.5:9978');
      expect(isLoopbackHost('127.0.0.1'), isTrue);
      expect(isLoopbackHost('127.9.9.9'), isTrue);
      expect(isLoopbackHost('localhost'), isTrue);
      expect(isLoopbackHost('::1'), isTrue);
      expect(isLoopbackHost('192.168.1.5'), isFalse);
    });
  });

  group('设备身份（design/01 §4.3）', () {
    final deviceJson = readFixture('android/device.json');

    test('解析 8 个字段', () {
      final device = AndroidDevice.fromJson(
        decodeFixture(deviceJson),
        reachableBase: reachable,
      );
      expect(device.uuid, isNotEmpty);
      expect(device.name, isNotEmpty);
      expect(device.reachableBase, reachable);
      expect(device.type, 0);
      expect(device.typeLabel, '电视');
      expect(device.isApp, isTrue);
      expect(device.reportedIp, isNotEmpty);
    });

    test('reachableBase 来自调用方，不来自响应的 ip 字段', () {
      final device = AndroidDevice.fromJson(
        decodeFixture(deviceJson),
        reachableBase: 'http://127.0.0.1:19978',
      );
      // 实测：设备自报 172.16.1.4，但 PC 只能经 adb forward 访问回环地址。
      expect(device.reachableBase, 'http://127.0.0.1:19978');
      expect(device.reportedIp, isNot(device.reachableBase));
    });

    test('相等性只比 uuid（端口漂移不产生重复设备）', () {
      final a = AndroidDevice.fromJson(
        decodeFixture(deviceJson),
        reachableBase: 'http://127.0.0.1:19978',
      );
      final b = AndroidDevice.fromJson(
        decodeFixture(deviceJson),
        reachableBase: 'http://127.0.0.1:29978',
      );
      expect(a, b);
      expect({a, b}.length, 1);
    });

    test('非法设备 JSON 抛 bridgeNotAndroid', () {
      throwsKind(
        () => AndroidDevice.fromJson(
          {'hello': 'world'},
          reachableBase: reachable,
        ),
        AppErrorKind.bridgeNotAndroid,
      );
    });

    test('uuid 掩码只保留前 4 位', () {
      final device = AndroidDevice.fromJson(
        decodeFixture(deviceJson),
        reachableBase: reachable,
      );
      expect(device.maskedUuid, endsWith('****'));
      expect(device.maskedUuid.length, 8);
      expect(device.toString(), isNot(contains(device.uuid)));
    });
  });

  group('T4 配置转换（design/01 §5）', () {
    late String raw;
    late String json;
    late AppConfig source;

    setUp(() {
      raw = readFixture('android/gateway-config.json');
      json = withHost(raw, 'http://192.168.1.5:9978');
      source = parseConfigDocument(json).config!;
    });

    test('站点全部归一化为 type=4', () {
      final conversion = convertGatewayConfig(
        jsonText: json,
        reachableBase: reachable,
      );
      expect(conversion.config.sites, isNotEmpty);
      for (final site in conversion.config.sites) {
        expect(site.type, SiteType.jsonApiBase64Ext);
      }
    });

    test('170 个站点保真：数量 / key / name / api path / 标志位', () {
      final conversion = convertGatewayConfig(
        jsonText: json,
        reachableBase: reachable,
      );
      final report = checkSiteFidelity(
        source: source,
        conversion: conversion,
        skippedSites: conversion.skippedSites,
      );
      expect(conversion.siteCount, 170);
      expect(report.isFidelityOk, isTrue, reason: report.summary);
      expect(report.actualKeys.length, 170);
    });

    test('站点中文名与方括号逐字节保留', () {
      final conversion = convertGatewayConfig(
        jsonText: json,
        reachableBase: reachable,
      );
      final names = conversion.config.sites.map((site) => site.name).toList();
      expect(names, contains('片单导航[导]'));
      expect(names, contains('丫仙女[盘]'));
    });

    test('主机一致时不重写、无诊断', () {
      final conversion = convertGatewayConfig(
        jsonText: json,
        reachableBase: reachable,
      );
      expect(conversion.hostRewrites, isEmpty);
      expect(conversion.config.sites.first.api, startsWith(reachable));
    });

    test('未知字段不丢失（Site.extra）', () {
      final payload = {
        'sites': [
          {
            'key': 'k1',
            'name': '站点一',
            'type': '4',
            'api': '$reachable/vod/api?key=k1',
            'futureField': {'nested': 1},
          },
        ],
      };
      final conversion = convertGatewayConfig(
        jsonText: encodeFixture(payload),
        reachableBase: reachable,
      );
      expect(conversion.config.sites.single.extra['futureField'], isNotNull);
    });

    test('空 sites 抛 bridgeEmptySites', () {
      throwsKind(
        () => convertGatewayConfig(
          jsonText: readFixture('android/gateway-config-empty.json'),
          reachableBase: reachable,
        ),
        AppErrorKind.bridgeEmptySites,
      );
    });

    test('带 urls 仓库抛 bridgeNoGateway（该端点不是 T4 网关）', () {
      throwsKind(
        () => convertGatewayConfig(
          jsonText: readFixture('android/gateway-config-repo.json'),
          reachableBase: reachable,
        ),
        AppErrorKind.bridgeNoGateway,
      );
    });

    test('msg 键保留 configMsg 类别（不被折叠）', () {
      throwsKind(
        () => convertGatewayConfig(
          jsonText: '{"msg":"配置已失效"}',
          reachableBase: reachable,
        ),
        AppErrorKind.configMsg,
      );
    });

    test('非 T4 站点被跳过并记诊断，其余保留', () {
      final payload = {
        'sites': [
          {'key': 'ok', 'name': '好站点', 'type': '4', 'api': '$reachable/vod/api?key=ok'},
          {'key': 'bad', 'name': '坏站点', 'type': '1', 'api': '$reachable/api?key=bad'},
        ],
      };
      final conversion = convertGatewayConfig(
        jsonText: encodeFixture(payload),
        reachableBase: reachable,
      );
      expect(conversion.config.sites.map((site) => site.key), ['ok']);
      expect(conversion.skippedSites, ['bad']);
      expect(conversion.diagnostics, isNotEmpty);
    });

    test('顶层 spider/lives 非空时被忽略并记诊断，站点数不变', () {
      final payload = {
        'spider': 'http://example.com/spider.jar',
        'lives': [{'name': '直播源', 'url': 'http://example.com/live.m3u'}],
        'sites': [
          {'key': 'ok', 'name': '好站点', 'type': '4', 'api': '$reachable/vod/api?key=ok'},
        ],
      };
      final conversion = convertGatewayConfig(
        jsonText: encodeFixture(payload),
        reachableBase: reachable,
      );
      expect(conversion.config.sites.length, 1);
      expect(conversion.ignoredTopLevelFields, containsAll(['spider', 'lives']));
      expect(conversion.hasNotes, isTrue);
    });
  });

  group('主机一致性三态（design/01 §5.3 · P2）', () {
    test('响应回环 + 请求非回环 → 重写为请求主机并记诊断', () {
      final raw = readFixture('android/gateway-config-loopback.json');
      final conversion = convertGatewayConfig(
        jsonText: raw,
        reachableBase: reachable,
      );
      expect(conversion.hostRewrites, hasLength(1));
      expect(conversion.hostRewrites.single.from, '127.0.0.1:9978');
      expect(
        conversion.config.sites.single.api,
        '$reachable/vod/api?key=csp_Media',
      );
      expect(conversion.diagnostics, isNotEmpty);
    });

    test('重写保留 path 与 query（只有主机变化）', () {
      final raw = readFixture('android/gateway-config-loopback.json');
      final conversion = convertGatewayConfig(
        jsonText: raw,
        reachableBase: reachable,
      );
      final api = Uri.parse(conversion.config.sites.single.api);
      expect(api.path, '/vod/api');
      expect(api.queryParameters['key'], 'csp_Media');
    });

    test('响应第三方主机 → 抛 bridgeHostMismatch，拒绝导入', () {
      throwsKind(
        () => convertGatewayConfig(
          jsonText: readFixture('android/gateway-config-mismatch.json'),
          reachableBase: reachable,
        ),
        AppErrorKind.bridgeHostMismatch,
      );
    });

    test('响应回环 + 请求也是回环 → 不重写（本就一致）', () {
      final raw = readFixture('android/gateway-config-loopback.json');
      final conversion = convertGatewayConfig(
        jsonText: raw,
        reachableBase: 'http://127.0.0.1:9978',
      );
      expect(conversion.hostRewrites, isEmpty);
    });
  });

  group('自引用防护（design/01 §5.5 · P4）', () {
    test('目标就是 PC 自己 → bridgeSelfReference', () {
      throwsKind(
        () => convertGatewayConfig(
          jsonText: readFixture('android/gateway-config.json').replaceAll(
            'http://__HOST__',
            'http://192.168.1.5:9978',
          ),
          reachableBase: reachable,
          selfBase: reachable,
        ),
        AppErrorKind.bridgeSelfReference,
      );
    });

    test('单个站点指向 PC 自己 → 跳过该站点，其余保留', () {
      final payload = {
        'sites': [
          {'key': 'self', 'name': '自己', 'type': '4', 'api': '$reachable/vod/api?key=self'},
          {'key': 'ok', 'name': '好站点', 'type': '4', 'api': 'http://192.168.1.9:9978/vod/api?key=ok'},
        ],
      };
      final conversion = convertGatewayConfig(
        jsonText: encodeFixture(payload),
        reachableBase: 'http://192.168.1.9:9978',
        selfBase: reachable,
      );
      expect(conversion.config.sites.map((site) => site.key), ['ok']);
      expect(conversion.skippedSites, ['self']);
    });
  });
}
