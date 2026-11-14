import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/direct_spider_registrar.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/spider_registry.dart';

void main() {
  late Directory temp;
  late SpiderManifestRegistry registry;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('webhtv-phase9-direct');
    registry = SpiderManifestRegistry(root: temp.path, log: LogService());
  });

  tearDown(() {
    try {
      temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Site site(
    String api, {
    String key = 'direct-a',
    int type = 3,
    Object? ext,
  }) => Site(key: key, name: '直连 $key', type: type, api: api, ext: ext);

  /// CatVod 壳站点的 ext：真正的蜘蛛地址在 loader 里。
  Map<String, Object?> shellExt(String loader) => {
    'api': 'https://pan.test',
    'loader': loader,
    'secret': 'x',
    'token': '2024',
  };

  /// CatVod 壳样本：`class Spider` + `*Content` 方法，没有 `create_spider`。
  const catVodShellSource = '''
class Spider:
    def init(self, extend=""):
        pass

    def homeContent(self, filter):
        return {}

    def categoryContent(self, tid, pg, filter, extend):
        return {}
''';

  group('P1-7 形态判定（README §4.2）', () {
    test('只认 type=3 且 .js/.py', () {
      expect(directSpiderKind(site('https://x.test/a.js')), DirectSpiderKind.js);
      expect(
        directSpiderKind(site('https://x.test/a.py?v=1')),
        DirectSpiderKind.py,
      );
      expect(directSpiderKind(site('https://x.test/api')), isNull);
      expect(
        directSpiderKind(site('https://x.test/a.js', type: 1)),
        isNull,
      );
      expect(directSpiderKind(site('spider-local:a')), isNull);
    });
  });

  group('CatVod 壳站点（方案 2）', () {
    test('api 只写壳名时按 ext.loader 认形态', () {
      final shell = site(
        'csp_PyProxy',
        key: 'shell-a',
        ext: shellExt('https://pan.test/Atvp.py?v=1'),
      );
      expect(directSpiderKind(shell), DirectSpiderKind.catVod);
      expect(catVodLoaderUrl(shell), 'https://pan.test/Atvp.py?v=1');

      // ext 是 JSON 字符串、以及 Base64 过的 JSON，都要认。
      final asJson = site(
        'csp_PyProxy',
        key: 'shell-b',
        ext: jsonEncode(shellExt('https://pan.test/a.py')),
      );
      expect(directSpiderKind(asJson), DirectSpiderKind.catVod);
      final asBase64 = site(
        'csp_PyProxy',
        key: 'shell-c',
        ext: base64Encode(
          utf8.encode(jsonEncode(shellExt('https://pan.test/b.py'))),
        ),
      );
      expect(catVodLoaderUrl(asBase64), 'https://pan.test/b.py');

      // 没有 loader、loader 不是 http(s)、或 ext 缺失 → 不认。
      expect(directSpiderKind(site('csp_PyProxy', ext: {'api': 'x'})), isNull);
      expect(
        directSpiderKind(
          site('csp_PyProxy', ext: shellExt(r'C:\spiders\a.py')),
        ),
        isNull,
      );
      expect(directSpiderKind(site('csp_PyProxy')), isNull);

      // 显式 .py/.js 后缀仍优先于壳判定。
      expect(
        directSpiderKind(
          site('https://x.test/a.py', ext: shellExt('https://pan.test/a.py')),
        ),
        DirectSpiderKind.py,
      );
    });

    test('下载 loader → 生成壳入口与 manifest → 注册成功', () async {
      var downloads = 0;
      final registrar = DirectSpiderRegistrar(
        root: temp.path,
        registry: registry,
        log: LogService(),
        client: MockClient((request) async {
          downloads += 1;
          expect(request.url.path, endsWith('Atvp.py'));
          return http.Response('class Spider:\n    pass\n', 200);
        }),
      );

      final result = await registrar.materialize(
        AppConfig(
          sites: [
            site(
              'csp_PyProxy',
              key: 'shell-a',
              ext: shellExt('https://pan.test/Atvp.py?v=1'),
            ),
          ],
        ),
      );

      expect(downloads, 1);
      final local = result['shell-a']!;
      // csp_* 壳站点就是 CatVod 方言：runtime 必须写 `python-catvod`，
      // host.py 据此自动进入 CatVod 模式（把 homeContent 等映射成宿主方法名）。
      expect(local.manifest.runtime, 'python-catvod');
      expect(local.manifest.entry, 'spider.py');
      expect(local.entryExists, isTrue);

      final dir = p.dirname(local.manifestPath);
      final entry = File(p.join(dir, 'spider.py')).readAsStringSync();
      expect(entry, contains('create_catvod_spider'));
      expect(entry, contains('create_spider'));
      expect(File(p.join(dir, 'loader.py')).existsSync(), isTrue);

      final stored = jsonDecode(File(local.manifestPath).readAsStringSync());
      expect(stored['key'], 'shell-a');
      expect(stored['runtime'], 'python-catvod');
    });

    test('同一 api 的多个壳站点互不覆盖', () async {
      final registrar = DirectSpiderRegistrar(
        root: temp.path,
        registry: registry,
        client: MockClient((_) async => http.Response('pass', 200)),
      );
      final result = await registrar.materialize(
        AppConfig(
          sites: [
            site(
              'csp_PyProxy',
              key: 'shell-a',
              ext: shellExt('https://pan.test/a.py'),
            ),
            site(
              'csp_PyProxy',
              key: 'shell-b',
              ext: shellExt('https://pan.test/b.py'),
            ),
          ],
        ),
      );
      expect(result.keys, ['shell-a', 'shell-b']);
      expect(
        p.dirname(result['shell-a']!.manifestPath),
        isNot(p.dirname(result['shell-b']!.manifestPath)),
      );
    });

    test('loader 哈希一致时不重复下载', () async {
      var downloads = 0;
      DirectSpiderRegistrar build() => DirectSpiderRegistrar(
        root: temp.path,
        registry: registry,
        client: MockClient((_) async {
          downloads += 1;
          return http.Response('same loader', 200);
        }),
      );
      final config = AppConfig(
        sites: [
          site(
            'csp_PyProxy',
            key: 'shell-a',
            ext: shellExt('https://pan.test/a.py'),
          ),
        ],
      );
      await build().materialize(config);
      await build().materialize(config);
      expect(downloads, 1);
    });
  });

  group('P1-7 自动注册（README §4.2）', () {
    test('下载 js → 生成 manifest → 注册成功', () async {
      var downloads = 0;
      final registrar = DirectSpiderRegistrar(
        root: temp.path,
        registry: registry,
        log: LogService(),
        client: MockClient((request) async {
          downloads += 1;
          return http.Response('module.exports = {};', 200);
        }),
      );

      final config = AppConfig(
        sites: [site('https://x.test/a.js')],
      );
      final result = await registrar.materialize(config);
      expect(result.keys, ['direct-a']);
      expect(downloads, 1);

      final local = result['direct-a']!;
      expect(local.manifest.runtime, 'node-tvbox');
      expect(local.manifest.entry, 'spider.js');
      expect(local.entryExists, isTrue);
      expect(File(local.manifestPath).existsSync(), isTrue);

      final stored = jsonDecode(File(local.manifestPath).readAsStringSync());
      expect(stored['key'], 'direct-a');
      expect((stored['hashes'] as Map)['entrySha256'], isNotEmpty);
    });

    test('非 CatVod 形态的 py 站点保持 python 运行时', () async {
      final registrar = DirectSpiderRegistrar(
        root: temp.path,
        registry: registry,
        client: MockClient((_) async => http.Response('pass', 200)),
      );
      final result = await registrar.materialize(
        AppConfig(sites: [site('https://x.test/a.py', key: 'py-a')]),
      );
      expect(result['py-a']!.manifest.runtime, 'python');
      expect(result['py-a']!.manifest.entry, 'spider.py');

      // 没包壳就不许出现 loader.json：分发层把它当「需要 requests/Crypto/lxml
      // 的解释器」的标记，写了会换掉一个本来能跑的解释器。
      final dir = p.dirname(result['py-a']!.manifestPath);
      expect(File(p.join(dir, 'loader.json')).existsSync(), isFalse);
    });

    test('哈希一致时不重复下载', () async {
      var downloads = 0;
      DirectSpiderRegistrar build() => DirectSpiderRegistrar(
        root: temp.path,
        registry: registry,
        client: MockClient((_) async {
          downloads += 1;
          return http.Response('same body', 200);
        }),
      );
      final config = AppConfig(sites: [site('https://x.test/a.js')]);
      await build().materialize(config);
      await build().materialize(config);
      expect(downloads, 1, reason: '第二次应命中已有文件与 manifest 哈希');
    });

    test('非 2xx / 超限 / 异常都跳过，不影响其他站点', () async {
      final registrar = DirectSpiderRegistrar(
        root: temp.path,
        registry: registry,
        maxBytes: 4,
        client: MockClient((request) async {
          final path = request.url.path;
          if (path.endsWith('bad.js')) return http.Response('x', 404);
          if (path.endsWith('huge.js')) return http.Response('0123456789', 200);
          if (path.endsWith('boom.js')) throw const SocketException('x');
          return http.Response('ok', 200);
        }),
      );
      final result = await registrar.materialize(
        AppConfig(
          sites: [
            site('https://x.test/bad.js', key: 'bad'),
            site('https://x.test/huge.js', key: 'huge'),
            site('https://x.test/boom.js', key: 'boom'),
            site('https://x.test/good.js', key: 'good'),
          ],
        ),
      );
      expect(result.keys, ['good']);
    });

    test('非 http(s) 的直连形态不注册', () async {
      final registrar = DirectSpiderRegistrar(
        root: temp.path,
        registry: registry,
        client: MockClient((_) async => http.Response('ok', 200)),
      );
      final result = await registrar.materialize(
        AppConfig(sites: [site(r'C:\spiders\a.js')]),
      );
      expect(result, isEmpty);
    });
  });

  group('`.py` 站点的 CatVod 包壳判定', () {
    test('只看方法面：CatVod 语义才包壳', () {
      expect(looksLikeCatVodShell(catVodShellSource), isTrue);
      // WebHTV 宿主 ABI：`create_spider(manifest)` 是原生入口，不需要壳。
      expect(
        looksLikeCatVodShell('def create_spider(manifest=None):\n    pass\n'),
        isFalse,
      );
      // 宿主侧方法名（home/category/search），不是 CatVod 的 *Content。
      expect(
        looksLikeCatVodShell(
          'class Spider:\n    def home(self, params, context):\n        pass\n',
        ),
        isFalse,
      );
      // 有 CatVod 方法但没有 Spider 类：create_catvod_spider 会直接 ValueError。
      expect(
        looksLikeCatVodShell('def homeContent(self, filter):\n    return {}\n'),
        isFalse,
      );
      expect(looksLikeCatVodShell('pass'), isFalse);
    });

    test('CatVod 形态的 py 站点包壳并写 loader.json', () async {
      var downloads = 0;
      final registrar = DirectSpiderRegistrar(
        root: temp.path,
        registry: registry,
        log: LogService(),
        client: MockClient((_) async {
          downloads += 1;
          return http.Response(catVodShellSource, 200);
        }),
      );

      final result = await registrar.materialize(
        AppConfig(
          sites: [site('https://x.test/Atvp.py?v=1', key: 'py-shell')],
        ),
      );

      expect(downloads, 1);
      final local = result['py-shell']!;
      expect(local.manifest.runtime, 'python-catvod');
      expect(local.manifest.entry, 'spider.py');
      expect(local.entryExists, isTrue);

      final dir = p.dirname(local.manifestPath);
      expect(
        File(p.join(dir, 'loader.py')).readAsStringSync(),
        catVodShellSource,
      );
      final entry = File(p.join(dir, 'spider.py')).readAsStringSync();
      expect(entry, contains('create_catvod_spider'));
      expect(entry, contains('entry="loader.py"'));

      final meta =
          jsonDecode(File(p.join(dir, 'loader.json')).readAsStringSync())
              as Map;
      expect(meta['loaderUrl'], 'https://x.test/Atvp.py?v=1');
      expect((meta['loaderSha256'] as String).length, 64);

      final stored = jsonDecode(File(local.manifestPath).readAsStringSync());
      expect(stored['runtime'], 'python-catvod');
    });

    test('包壳目录哈希一致时不重复下载', () async {
      var downloads = 0;
      DirectSpiderRegistrar build() => DirectSpiderRegistrar(
        root: temp.path,
        registry: registry,
        client: MockClient((_) async {
          downloads += 1;
          return http.Response(catVodShellSource, 200);
        }),
      );
      final config = AppConfig(
        sites: [site('https://x.test/Atvp.py?v=1', key: 'py-shell')],
      );
      await build().materialize(config);
      await build().materialize(config);
      expect(downloads, 1, reason: 'loader.json 里记的 loaderSha256 应命中');
    });

    // 91 是订阅里的真实规模，不缩减——缩到几个站点就测不到目录塌缩这个事故。
    // 每个站点要落 3~4 个文件，而 `_materializePy` 沿用既有的 `flush: true`
    // （每次写都 fsync），单机实测约 23s；全量测试并发压满时会被默认的 30s
    // 超时打掉，因此这里显式放宽——放宽的是时限，断言强度不变。
    test(
      '91 个 api 相同的 py 站点各占一个目录',
      () async {
        final registrar = DirectSpiderRegistrar(
          root: temp.path,
          registry: registry,
          client: MockClient((_) async => http.Response('pass', 200)),
        );
        // 生产事故复现：整份订阅里这 91 个站点的 api 逐字相同，只有 ext 不同。
        const sharedApi = 'http://192.168.50.50:4567/Atvp.py?v=t4-direct-v1';
        final result = await registrar.materialize(
          AppConfig(
            sites: [
              for (var i = 0; i < 91; i++)
                site(sharedApi, key: 'py-$i', ext: 'ext-$i'),
            ],
          ),
        );

        expect(result.length, 91);
        final dirs = {
          for (final local in result.values) p.dirname(local.manifestPath),
        };
        expect(dirs.length, 91, reason: '目录键必须含站点 key，不能只用 api');
        expect(registry.byKey('py-0'), isNotNull);
        expect(registry.byKey('py-90'), isNotNull);
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  });
}
