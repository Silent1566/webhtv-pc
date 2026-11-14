import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:webhtv_pc/core/doh.dart';
import 'package:webhtv_pc/core/doh_settings.dart';
import 'package:webhtv_pc/services/doh_resolver.dart';

/// 构造一条最简 DNS 应答（问题段 + A/AAAA 答案，答案名用压缩指针）。
Uint8List dnsResponse({
  required String host,
  required List<String> ips,
  int ttl = 300,
  int rcode = 0,
  bool aaaa = false,
}) {
  final builder = BytesBuilder();
  builder.add([0x12, 0x34]);
  builder.add([0x81, 0x80 | rcode]);
  builder.add([0x00, 0x01]); // QDCOUNT
  builder.add([0x00, ips.length]); // ANCOUNT
  builder.add([0x00, 0x00]);
  builder.add([0x00, 0x00]);
  for (final label in host.split('.')) {
    final bytes = utf8.encode(label);
    builder.addByte(bytes.length);
    builder.add(bytes);
  }
  builder.addByte(0);
  builder.add([0x00, 0x01]); // A
  builder.add([0x00, 0x01]); // IN
  for (final ip in ips) {
    builder.add([0xc0, 0x0c]); // 指向问题段的名字
    builder.add([0x00, aaaa ? 0x1c : 0x01]);
    builder.add([0x00, 0x01]);
    builder.add([
      (ttl >> 24) & 0xff,
      (ttl >> 16) & 0xff,
      (ttl >> 8) & 0xff,
      ttl & 0xff,
    ]);
    final address = InternetAddress(ip);
    final data = address.rawAddress;
    builder.add([0x00, data.length]);
    builder.add(data);
  }
  return builder.toBytes();
}

class _FakeClient extends http.BaseClient {
  _FakeClient(this.onPost);

  final http.Response Function(http.Request request) onPost;
  int calls = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    calls += 1;
    final body = request is http.Request ? request.bodyBytes : Uint8List(0);
    final response = onPost(
      http.Request(request.method, request.url)..bodyBytes = body,
    );
    return http.StreamedResponse(
      Stream.value(response.bodyBytes),
      response.statusCode,
      headers: response.headers,
    );
  }
}

void main() {
  group('DNS wire format（P2-8）', () {
    test('查询报文：头/标签/QTYPE 正确', () {
      final bytes = buildDnsQuery(host: 'a.b.com', type: DnsRecordType.a);
      expect(bytes.sublist(0, 2), [0, 0]);
      expect(bytes[3] & 0x01, 1, reason: 'RD=1（flags 低字节）');
      expect(bytes.sublist(4, 6), [0, 1], reason: 'QDCOUNT=1');
      // 1 a 1 b 3 com 0
      expect(bytes[12], 1);
      expect(bytes[13], 0x61);
      expect(bytes[14], 1);
      expect(bytes[15], 0x62);
      expect(bytes[16], 3);
      expect(bytes.sublist(17, 20), utf8.encode('com'));
      expect(bytes[20], 0);
      expect(bytes.sublist(21, 23), [0, 1]);
      expect(bytes.sublist(23, 25), [0, 1]);
    });

    test('A 应答解析（压缩指针 + TTL）', () {
      final data = dnsResponse(host: 'example.com', ips: ['1.2.3.4'], ttl: 120);
      final result = parseDnsResponse(data, host: 'example.com');
      expect(result.ok, isTrue, reason: result.error);
      expect(result.answer!.addresses, ['1.2.3.4']);
      expect(result.answer!.ttlSeconds, 120);
    });

    test('AAAA 应答解析', () {
      final data = dnsResponse(
        host: 'example.com',
        ips: ['2001:db8::1'],
        aaaa: true,
      );
      final result = parseDnsResponse(data, host: 'example.com');
      expect(result.ok, isTrue, reason: result.error);
      expect(result.answer!.addresses.single, contains(':'));
    });

    test('rcode 非 0 / 无记录 / 截断都失败（不猜）', () {
      final nxdomain = dnsResponse(
        host: 'nope.test',
        ips: const [],
        rcode: 3,
      );
      expect(
        parseDnsResponse(nxdomain, host: 'nope.test').error,
        contains('rcode=3'),
      );
      final empty = dnsResponse(host: 'nope.test', ips: const []);
      expect(parseDnsResponse(empty, host: 'nope.test').ok, isFalse);
      expect(
        parseDnsResponse(Uint8List.fromList([0, 1]), host: 'x').ok,
        isFalse,
      );
    });

    test('TTL 夹取：<60s 提到 60，>24h 压到 24h', () {
      expect(clampDohTtl(5), 60);
      expect(clampDohTtl(120), 120);
      expect(clampDohTtl(86400 * 30), 86400);
    });
  });

  group('配置解析（doh / hosts）', () {
    test('DoH 端点：对象/字符串/去重/拒绝明文 http', () {
      final list = DohEndpoint.parseList([
        {'name': 'Cloudflare', 'url': 'https://dns.cloudflare.com/dns-query'},
        'https://dns.google/dns-query',
        'http://insecure.test/dns-query',
        {'url': ''},
        'https://dns.cloudflare.com/dns-query',
      ]);
      expect(list, hasLength(2));
      expect(list.first.name, 'Cloudflare');
      expect(list.first.isValid, isTrue);
      expect(list.last.url, 'https://dns.google/dns-query');
    });

    test('hosts 映射：精确/后缀/通配/IPv6/非法项', () {
      final map = DohHostMap.parse([
        'api.example.com=1.2.3.4',
        'cdn.example.com:443=5.6.7.8',
        '*.wild.test=9.9.9.9',
        'v6.test=[2001:db8::2]',
        'bad=not-an-ip',
        'no-equals',
      ]);
      expect(map.lookup('api.example.com'), '1.2.3.4');
      expect(map.lookup('cdn.example.com'), '5.6.7.8');
      expect(map.lookup('a.wild.test'), '9.9.9.9');
      expect(map.lookup('v6.test'), '2001:db8::2');
      expect(map.lookup('bad'), isNull);
      expect(map.lookup('unknown.test'), isNull);
    });

    test('设置：缺省关闭、URL 必须 https、缓存分钟夹取', () {
      expect(DohSettings.defaults.enabled, isFalse);
      expect(DohSettings.defaults.isDefault, isTrue);
      expect(isUsableDohUrl('http://x/dns-query'), isFalse);
      expect(isUsableDohUrl('https://x/dns-query'), isTrue);
      expect(
        DohSettings.fromJson({'enabled': true, 'cacheMinutes': 99999})
            .cacheMinutes,
        1440,
      );
      expect(
        DohSettings.fromJson({'enabled': true, 'cacheMinutes': -1})
            .cacheMinutes,
        1,
      );
      expect(
        DohSettings.fromJson({'enabled': true, 'url': ' https://x '}).url,
        'https://x',
      );
    });

    test('缓存文件：往返、过期裁剪、损坏兜底', () {
      final cache = DohCacheFile(
        entries: {
          'alive.test': DohCacheEntry(
            addresses: ['1.1.1.1'],
            expiresAtMs: 2000,
          ),
          'dead.test': DohCacheEntry(
            addresses: ['2.2.2.2'],
            expiresAtMs: 500,
          ),
        },
      );
      final decoded = DohCacheFile.decode(cache.encode());
      expect(decoded.entries, hasLength(2));
      expect(decoded.pruned(1000).entries.keys, ['alive.test']);
      expect(DohCacheFile.decode('not json').entries, isEmpty);
      expect(DohCacheFile.decode('{"version":9}').entries, isEmpty);
    });
  });

  group('DohResolver', () {
    late Directory temp;
    late _FakeClient client;
    late DohResolver resolver;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('webhtv-doh');
      client = _FakeClient(
        (request) => http.Response.bytes(
          dnsResponse(host: 'site.test', ips: ['10.0.0.1'], ttl: 300),
          200,
          headers: {'content-type': 'application/dns-message'},
        ),
      );
      resolver = DohResolver(
        settings: DohSettings.defaults.copyWith(
          enabled: true,
          url: 'https://doh.test/dns-query',
        ),
        endpoints: const [],
        cachePath: '${temp.path}/doh_cache.json',
        clientFactory: (_) => client,
      );
    });

    tearDown(() {
      resolver.close();
      try {
        temp.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('查询成功并按 TTL 缓存（第二次不请求）', () async {
      final first = await resolver.resolve('site.test');
      expect(first, isNotNull);
      expect(first!.single.address, '10.0.0.1');
      expect(client.calls, 1);
      final second = await resolver.resolve('site.test');
      expect(second, isNotNull);
      expect(client.calls, 1, reason: '缓存命中不应再发 DoH 请求');
    });

    test('静态 hosts 优先，不发 DoH 请求', () async {
      final pinned = DohResolver(
        settings: DohSettings.defaults.copyWith(
          enabled: true,
          url: 'https://doh.test/dns-query',
        ),
        endpoints: const [],
        hostMap: DohHostMap.parse(['site.test=127.0.0.9']),
        cachePath: '${temp.path}/pinned.json',
        clientFactory: (_) => client,
      );
      addTearDown(pinned.close);
      final result = await pinned.resolve('site.test');
      expect(result!.single.address, '127.0.0.9');
      expect(client.calls, 0);
    });

    test('DoH 失败 → 返回 null（回落系统 DNS）', () async {
      final failing = _FakeClient(
        (_) => http.Response('nope', 500),
      );
      final fallback = DohResolver(
        settings: DohSettings.defaults.copyWith(
          enabled: true,
          url: 'https://doh.test/dns-query',
        ),
        endpoints: const [],
        cachePath: '${temp.path}/fail.json',
        clientFactory: (_) => failing,
      );
      addTearDown(fallback.close);
      expect(await fallback.resolve('site.test'), isNull);
    });

    test('多端点失败切换：第一个 500，第二个成功', () async {
      var calls = 0;
      final multi = DohResolver(
        settings: DohSettings.defaults.copyWith(enabled: true),
        endpoints: const [
          DohEndpoint(url: 'https://bad.test/dns-query'),
          DohEndpoint(url: 'https://good.test/dns-query'),
        ],
        cachePath: '${temp.path}/multi.json',
        clientFactory: (_) => _FakeClient((request) {
          calls += 1;
          if (request.url.host == 'bad.test') {
            return http.Response('boom', 500);
          }
          return http.Response.bytes(
            dnsResponse(host: 'site.test', ips: ['10.0.0.2']),
            200,
          );
        }),
      );
      addTearDown(multi.close);
      final result = await multi.resolve('site.test');
      expect(result!.single.address, '10.0.0.2');
      // 坏端点先试 A、再试 AAAA（各一次失败），好端点的 A 成功：共 3 次。
      expect(calls, 3);
    });

    test('并发写盘不会让缓存文件消失', () async {
      await resolver.resolve('site.test');
      final path = '${temp.path}/doh_cache.json';
      // resolve() 里的写盘是 fire-and-forget，调用方还会再 flush 一次：两个写盘者
      // 一旦共用同一个 tmp 并交错，后者会删掉前者刚 rename 出来的文件、自己的
      // rename 又因 tmp 已被搬走而失败——缓存文件静默消失（CI 上「跨实例复用」
      // 这条用例就是这样红的）。写盘必须是同步临界区，任何一轮都不许丢文件。
      for (var i = 0; i < 40; i++) {
        unawaited(resolver.flushCache());
        await resolver.flushCache();
        expect(
          File(path).existsSync(),
          isTrue,
          reason: '第 $i 轮并发写盘把缓存文件弄丢了',
        );
      }
    });

    test('磁盘缓存可跨实例复用', () async {
      await resolver.resolve('site.test');
      await resolver.flushCache();
      final reloaded = DohResolver(
        settings: DohSettings.defaults.copyWith(
          enabled: true,
          url: 'https://doh.test/dns-query',
        ),
        endpoints: const [],
        cachePath: '${temp.path}/doh_cache.json',
        clientFactory: (_) => client,
      );
      addTearDown(reloaded.close);
      final result = await reloaded.resolve('site.test');
      expect(result, isNotNull);
      expect(client.calls, 1, reason: '磁盘缓存命中不应再请求');
    });

    test('未启用且无 hosts 时 isUsable=false（不接管 DNS）', () {
      final disabled = DohResolver(
        settings: DohSettings.defaults,
        endpoints: const [],
        cachePath: '${temp.path}/x.json',
      );
      addTearDown(disabled.close);
      expect(disabled.isUsable, isFalse);
    });
  });
}
