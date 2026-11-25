/// PC 原始配置 → Android 执行：绑定、快照与纯内存叠加。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/android_config_execution.dart';
import 'package:webhtv_pc/core/protocol.dart';

/// 32 字节随机量的 base64url 文本（128 bit 下限之上）。
const String token32 = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

/// 64 位十六进制摘要。
const String hash64 =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

AndroidConfigExecutionBinding binding({
  String sourceKey = 'src-1',
  String profileConnectionKey = 'profile-1',
  String deviceUuid = 'device-1',
  String configHash = hash64,
  String snapshotToken = token32,
  int guestPort = 19000,
  String interfaceKey = 'site-key',
}) => AndroidConfigExecutionBinding(
  sourceKey: sourceKey,
  profileConnectionKey: profileConnectionKey,
  deviceUuid: deviceUuid,
  configHash: configHash,
  snapshotToken: snapshotToken,
  guestPort: guestPort,
  interfaceKey: interfaceKey,
);

Site site(
  String key, {
  String? name,
  int type = 3,
  String api = '',
  String? jar,
  Object? ext,
  Map<String, String> header = const {'User-Agent': 'pc-agent'},
  Map<String, Object?> extra = const {},
}) => Site(
  key: key,
  name: name ?? key,
  type: type,
  api: api,
  jar: jar,
  ext: ext,
  header: HeaderMap(header),
  extra: extra,
);

void main() {
  test('decoded config survives mislabelled HTML transport MIME', () {
    final raw = <String, Object?>{
      'spider': 'https://cfg.example/spider.jar;md5;abc123',
      'sites': [
        {
          'key': 'csp_A',
          'name': '原站点',
          'type': 3,
          'api': 'csp_Alpha',
          'ext': {'token': 'opaque'},
        },
      ],
      'warningText': 'preserved',
    };
    final before = jsonEncode(raw);
    for (final mime in [
      'text/html',
      'text/html; charset=utf-8',
      'application/xhtml+xml',
    ]) {
      final snapshot = androidExecutionSnapshot(
        raw,
        origin: 'https://cfg.example/config',
        contentType: mime,
      );
      expect(snapshot, raw);
      expect((snapshot['sites'] as List).single['api'], 'csp_Alpha');
    }
    expect(jsonEncode(raw), before);
  });
  group('AndroidConfigExecutionBinding', () {
    test('json round-trip preserves identity and pending state', () {
      final ready = binding();
      final json = ready.toJson();
      expect(json['version'], 1);
      final back = AndroidConfigExecutionBinding.fromJson(json)!;
      expect(back.toJson(), json);
      expect(back.bindingKey, jsonEncode(<String>['src-1', 'profile-1']));
      expect(back.isReady, isTrue);

      final pending = ready.copyWith(interfaceKey: '');
      final pendingBack = AndroidConfigExecutionBinding.fromJson(
        pending.toJson(),
      )!;
      expect(pendingBack.isReady, isFalse);
      expect(pendingBack.toJson(), pending.toJson());
    });

    test('binding key differs by source and profile only', () {
      expect(
        binding(profileConnectionKey: 'profile-2').bindingKey,
        isNot(binding().bindingKey),
      );
      expect(
        binding(sourceKey: 'src-2').bindingKey,
        isNot(binding().bindingKey),
      );
      expect(
        binding(deviceUuid: 'other', guestPort: 20000).bindingKey,
        binding().bindingKey,
      );
    });

    test('rejects future versions and malformed ready fields', () {
      final base = binding().toJson();
      expect(
        AndroidConfigExecutionBinding.fromJson({...base, 'version': 2}),
        isNull,
      );
      expect(
        AndroidConfigExecutionBinding.fromJson({
          ...base,
          'snapshotToken': 'dG9vLXNob3J0',
        }),
        isNull,
      );
      expect(
        AndroidConfigExecutionBinding.fromJson({...base, 'guestPort': 0}),
        isNull,
      );
      expect(
        AndroidConfigExecutionBinding.fromJson({...base, 'configHash': 'abc'}),
        isNull,
      );
      expect(
        AndroidConfigExecutionBinding.fromJson({...base, 'sourceKey': ''}),
        isNull,
      );
    });

    test('toString never exposes the token or device uuid', () {
      final ready = binding(
        snapshotToken: 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB',
        deviceUuid: 'device-secret-uuid',
      );
      expect(ready.toString().contains(ready.snapshotToken), isFalse);
      expect(ready.toString().contains(ready.deviceUuid), isFalse);
    });

    test('copyWith replaces execution fields but never identity', () {
      final copy = binding().copyWith(
        deviceUuid: 'device-2',
        configHash: 'b' * 64,
        snapshotToken: 'C' * 43,
        guestPort: 19001,
        interfaceKey: '',
      );
      expect(copy.sourceKey, 'src-1');
      expect(copy.profileConnectionKey, 'profile-1');
      expect(copy.deviceUuid, 'device-2');
      expect(copy.configHash, 'b' * 64);
      expect(copy.guestPort, 19001);
      expect(copy.interfaceKey, '');
      expect(copy.isReady, isFalse);
    });
  });

  group('androidExecutionSnapshot', () {
    test('preserves CSP and opaque API symbols byte-exact', () {
      final snapshot = androidExecutionSnapshot({
        'sites': [
          {'api': 'csp_X', 'ext': 'opaque-value'},
          {'api': ' csp_Example ', 'ext': 'plain'},
          {'api': 'com.example.Spider', 'ext': ''},
          {'api': 'opaque-symbol', 'ext': 'opaque'},
        ],
      }, origin: 'https://cfg.example/dir/config.json');
      expect((snapshot['sites'] as List).map((item) => (item as Map)['api']), [
        'csp_X',
        ' csp_Example ',
        'com.example.Spider',
        'opaque-symbol',
      ]);
    });

    test('preserves JSON ext strings and nested opaque escapes byte-exact', () {
      const opaque = [
        r'{"regex":"\d+"}',
        r'{"nested":{"path":"C:\\opaque","regex":"\s+"}}',
        r'["file:///private","http://127.0.0.1:12345/ext.json"]',
        r'custom\escaped\opaque',
        r'custom\escaped\opaque;md5;not-a-resource',
        r'{"regex":";md5;","path":"C:\\opaque"}',
        '  {"provider":"opaque"}  ',
      ];
      final snapshot = androidExecutionSnapshot({
        'sites': [
          for (final ext in opaque) {'api': 'csp_X', 'ext': ext},
        ],
        'unknown': {
          'nested': [
            r'\d+',
            {'data': r'\escaped'},
          ],
        },
      }, origin: 'https://cfg.example/config.json');
      expect(
        (snapshot['sites'] as List).map((item) => (item as Map)['ext']),
        opaque,
      );
      expect(snapshot['unknown'], {
        'nested': [
          r'\d+',
          {'data': r'\escaped'},
        ],
      });
    });

    test('resolves known JAR resources with MD5 while preserving CSP APIs', () {
      final snapshot = androidExecutionSnapshot({
        'spider': 'lib/main.jar;md5;deadbeef',
        'sites': [
          {
            'api': 'csp_X',
            'jar': '../lib/site.jar;md5;abc123',
            'ext': 'ext/options.json;md5;123abc',
          },
          {'api': './api/catalog.php;md5;deed', 'ext': 'opaque'},
        ],
      }, origin: 'https://cfg.example/dir/config.json;md5;abcd');
      expect(
        snapshot['spider'],
        'https://cfg.example/dir/lib/main.jar;md5;deadbeef',
      );
      final sites = (snapshot['sites'] as List).cast<Map>();
      expect(sites[0]['api'], 'csp_X');
      expect(sites[0]['jar'], 'https://cfg.example/lib/site.jar;md5;abc123');
      expect(
        sites[0]['ext'],
        'https://cfg.example/dir/ext/options.json;md5;123abc',
      );
      expect(
        sites[1]['api'],
        'https://cfg.example/dir/api/catalog.php;md5;deed',
      );
    });

    test('rejects PC-loopback HTTP origins before resolving relative refs', () {
      for (final host in [
        '127.0.0.1',
        '127.20.30.40',
        'localhost',
        'LOCALHOST',
        '[::1]',
      ]) {
        expect(
          () => androidExecutionSnapshot({
            'spider': './spider.jar',
            'sites': [
              {'api': './api.php'},
            ],
          }, origin: 'http://$host:12345/config.json'),
          throwsFormatException,
        );
      }
    });

    test('rejects loopback HTTP JAR explicit API and ext resources', () {
      for (final host in ['127.0.0.1', '127.20.30.40', 'localhost', '[::1]']) {
        for (final field in ['spider', 'jar', 'api', 'ext']) {
          final ref = 'http://$host:12345/resource.json;md5;abcd';
          final raw = <String, Object?>{
            if (field == 'spider') 'spider': ref,
            'sites': [
              {if (field != 'spider') field: ref},
            ],
          };
          expect(
            () => androidExecutionSnapshot(
              raw,
              origin: 'https://cfg.example/config.json',
            ),
            throwsFormatException,
          );
        }
      }
    });

    test('keeps valid non-loopback LAN HTTP resources and opaque URL maps', () {
      final snapshot = androidExecutionSnapshot({
        'spider': 'http://192.168.10.20/lib.jar',
        'sites': [
          {
            'api': 'http://10.20.30.40/catalog',
            'jar': 'http://192.168.10.30/site.jar',
            'ext': 'http://192.168.10.40/ext.json',
          },
          {
            'api': 'http://10.20.30.50/catalog',
            'ext': {'url': 'http://127.0.0.1:12345/opaque'},
          },
          {'api': '//172.16.1.20/api', 'ext': 'opaque'},
        ],
      }, origin: 'http://192.168.10.20/dir/config.json');
      expect(snapshot['spider'], 'http://192.168.10.20/lib.jar');
      final sites = (snapshot['sites'] as List).cast<Map>();
      expect(sites[0]['api'], 'http://10.20.30.40/catalog');
      expect(sites[0]['jar'], 'http://192.168.10.30/site.jar');
      expect(sites[0]['ext'], 'http://192.168.10.40/ext.json');
      expect(sites[1]['ext'], {'url': 'http://127.0.0.1:12345/opaque'});
      expect(sites[2]['api'], 'http://172.16.1.20/api');
    });

    test('deep copies raw JSON without mutating unknown fields', () {
      final original = <String, Object?>{
        'name': 'pc-config',
        'unknown': {
          'nested': [1, true, null, 'keep'],
        },
      };
      final snapshot = androidExecutionSnapshot(
        original,
        origin: 'https://cfg.example/dir/config.json',
      );

      expect(jsonEncode(snapshot['unknown']), jsonEncode(original['unknown']));
      expect(identical(snapshot['unknown'], original['unknown']), isFalse);
      final nested = (snapshot['unknown'] as Map)['nested'] as List;
      expect(
        identical(nested, (original['unknown'] as Map)['nested']),
        isFalse,
      );
      expect(original, {
        'name': 'pc-config',
        'unknown': {
          'nested': [1, true, null, 'keep'],
        },
      });
    });

    test(
      'resolves HTTP-relative jar, api and ext against origin with md5 suffix',
      () {
        final original = <String, Object?>{
          'sites': [
            {
              'key': 'a',
              'name': 'A',
              'type': 4,
              'api': './api/a.php;md5;deadbeef',
              'jar': 'spider.jar',
              'ext': './ext/a.json',
              'custom': 'stay',
            },
            {
              'key': 'b',
              'name': 'B',
              'type': 4,
              'api': '/root/api.php',
              'extends': ['unknown'],
            },
          ],
        };

        final snapshot = androidExecutionSnapshot(
          original,
          origin: 'https://cfg.example/dir/config.json;md5;abcd',
        );
        final sites = (snapshot['sites'] as List).cast<Map>();
        expect(
          sites[0]['api'],
          'https://cfg.example/dir/api/a.php;md5;deadbeef',
        );
        expect(sites[0]['jar'], 'https://cfg.example/dir/spider.jar');
        expect(sites[0]['ext'], 'https://cfg.example/dir/ext/a.json');
        expect(sites[0]['custom'], 'stay');
        expect(sites[1]['api'], 'https://cfg.example/root/api.php');
        expect(sites[1]['extends'], ['unknown']);

        final before = (original['sites'] as List)[0] as Map;
        expect(before['api'], './api/a.php;md5;deadbeef');
        expect(before['jar'], 'spider.jar');
        expect(before['ext'], './ext/a.json');
      },
    );

    test('leaves opaque ext strings and maps untouched', () {
      final original = <String, Object?>{
        'sites': [
          {
            'key': 'a',
            'type': 4,
            'api': 'https://api.example/v1',
            'ext': 'c2VjcmV0LWNvbmZpZw==',
          },
          {
            'key': 'b',
            'type': 4,
            'api': 'https://api.example/v1',
            'ext': {'provider': 'opaque'},
          },
        ],
      };
      final snapshot = androidExecutionSnapshot(
        original,
        origin: 'https://cfg.example/dir/config.json',
      );
      final sites = (snapshot['sites'] as List).cast<Map>();
      expect(sites[0]['ext'], 'c2VjcmV0LWNvbmZpZw==');
      expect(sites[1]['ext'], {'provider': 'opaque'});
      expect(sites[0]['api'], 'https://api.example/v1');
    });

    test('rejects PC-local and bundle origins with sanitized diagnostics', () {
      for (final origin in [
        'file:///tmp/config.json',
        'bundle://pc-assets/config.json',
        'web-home:demo',
        'spider-local:demo',
        r'C:\Users\me\config.json',
        'content://provider/config.json',
      ]) {
        try {
          androidExecutionSnapshot({'name': 'x'}, origin: origin);
          fail('origin should be rejected');
        } on FormatException catch (error) {
          expect(error.message.contains('file:'), isFalse);
          expect(error.message.contains(r'C:\Users'), isFalse);
          expect(error.message.contains('bundle:'), isFalse);
          expect(error.message.contains('web-home:'), isFalse);
        }
      }
    });

    test('rejects local JAR/ext references instead of uploading them', () {
      for (final ref in [
        'file:///tmp/spider.jar',
        'bundle://pc-assets/spider.jar',
        'web-home:demo',
        'spider-local:demo',
        r'C:\spiders\spider.jar',
        '/Users/me/spider.jar',
      ]) {
        final original = <String, Object?>{
          'sites': [
            {'key': 'a', 'type': 3, 'api': 'https://api.example', 'jar': ref},
            {'key': 'b', 'type': 3, 'api': 'https://api.example', 'ext': ref},
          ],
        };
        try {
          androidExecutionSnapshot(
            original,
            origin: 'https://cfg.example/dir/config.json',
          );
          fail('local reference should be rejected');
        } on FormatException catch (error) {
          expect(error.message.contains('spider.jar'), isFalse);
          expect(error.message.contains('/Users/me'), isFalse);
          expect(error.message.contains('web-home:'), isFalse);
        }
      }
    });

    test('rejects a snapshot above 2 MiB and HTML content types', () {
      final oversized = <String, Object?>{'name': 'x' * (2 * 1024 * 1024)};
      expect(
        () => androidExecutionSnapshot(
          oversized,
          origin: 'https://cfg.example/dir/config.json',
        ),
        throwsFormatException,
      );
      expect(
        () => androidExecutionSnapshot(
          {'name': 'small'},
          origin: 'https://cfg.example/dir/config.json',
          contentType: 'text/html; charset=utf-8',
        ),
        throwsFormatException,
      );
    });
  });

  group('overlayAndroidExecution', () {
    AppConfig originalConfig() => AppConfig(
      name: 'PC record',
      spider: 'https://cfg.example/spider.jar',
      sites: [
        site(
          'a',
          name: 'A display',
          type: 3,
          api: 'https://pc.example/a',
          jar: 'https://cfg.example/a.jar',
          ext: 'pc-ext',
          extra: {'jar': 'legacy', 'custom': 'keep'},
        ),
        site('b', name: 'B display', type: 3, api: 'https://pc.example/b'),
      ],
      flags: ['pc-flag'],
      headers: [
        HeaderRule(host: 'pc.example', header: HeaderMap({'X-PC': '1'})),
      ],
      rules: [
        {'rule': 'pc'},
      ],
      wallpaper: 'pc.png',
      parse: 'pc-parse',
      danmaku: 'pc-danmaku',
      urls: [ConfigRepositoryEntry(url: 'https://repo.example/list.json')],
      extra: {'top-unknown': 'keep'},
    );

    AppConfig gatewayConfig() => AppConfig(
      name: 'Android injected',
      spider: 'https://android.example/spider.jar',
      sites: [
        site(
          'b',
          name: 'B android',
          type: 4,
          api: 'https://gateway.example/b',
          ext: 'gateway-b',
          extra: {'androidInjected': 'b'},
        ),
        site(
          'a',
          name: 'A android',
          type: 4,
          api: 'https://gateway.example/a',
          ext: 'gateway-a',
          extra: {'androidInjected': 'a'},
        ),
        site('android-only', name: 'Injected', type: 4),
      ],
      flags: ['android-flag'],
      extra: {'android-top': true},
    );

    test('keeps original 93-key order metadata and top-level fields', () {
      final original = originalConfig();
      final result = overlayAndroidExecution(original, gatewayConfig());

      expect(result.sites.map((item) => item.key), ['a', 'b']);
      expect(result.sites[0].name, 'A display');
      expect(result.sites[0].header.toJson(), {'User-Agent': 'pc-agent'});
      expect(result.sites[0].extra, {'custom': 'keep'});
      expect(result.sites[1].name, 'B display');
      expect(result.name, 'PC record');
      expect(result.spider, 'https://cfg.example/spider.jar');
      expect(result.flags, ['pc-flag']);
      expect(result.rules, original.rules);
      expect(result.wallpaper, 'pc.png');
      expect(result.parse, 'pc-parse');
      expect(result.danmaku, 'pc-danmaku');
      expect(result.urls, original.urls);
      expect(result.headers, original.headers);
      expect(result.extra, {'top-unknown': 'keep'});
      expect(original.sites[0].api, 'https://pc.example/a');
      expect(original.sites[0].jar, 'https://cfg.example/a.jar');
    });

    test(
      'maps type 4 api and ext from the same-key gateway site and drops jar',
      () {
        final result = overlayAndroidExecution(
          originalConfig(),
          gatewayConfig(),
        );
        final a = result.sites[0];
        expect(a.type, 4);
        expect(a.api, 'https://gateway.example/a');
        expect(a.ext, 'gateway-a');
        expect(a.jar, isNull);
        expect(a.extra.containsKey('jar'), isFalse);
        final b = result.sites[1];
        expect(b.type, 4);
        expect(b.api, 'https://gateway.example/b');
        expect(b.ext, 'gateway-b');
        expect(b.extra, isEmpty);
      },
    );

    test('fails closed when an original key is missing from the gateway', () {
      final gateway = gatewayConfig();
      final reduced = AppConfig(
        name: gateway.name,
        sites: [gateway.sites[0], gateway.sites[2]],
        flags: gateway.flags,
        extra: gateway.extra,
      );
      try {
        overlayAndroidExecution(originalConfig(), reduced);
        fail('missing original site must fail the whole overlay');
      } on FormatException catch (error) {
        expect(error.message.contains('a'), isTrue);
        expect(error.message.contains('pc.example'), isFalse);
        expect(error.message.contains('https://'), isFalse);
      }
    });

    test('fails closed when the gateway site is not a T4 site', () {
      final gateway = gatewayConfig();
      final wrong = AppConfig(
        name: gateway.name,
        sites: [
          site('a', type: 3, api: 'https://gateway.example/a'),
          gateway.sites[0],
        ],
      );
      expect(
        () => overlayAndroidExecution(originalConfig(), wrong),
        throwsFormatException,
      );
    });
  });
}
