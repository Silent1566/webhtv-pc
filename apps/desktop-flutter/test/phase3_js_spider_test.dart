/// JS（Node）sidecar 宿主门禁测试（设计文档 §9.7、§9.8、§18.3）。
///
/// 覆盖范围：
/// - `LocalSpiderCommand.resolve` 对 `runtime=node` 的 manifest 返回
///   `node host.js --entry ... --manifest ...`，Windows 下解析出 `node.exe`；
/// - 真实 Node 子进程经 stdio 帧与 Dart 宿主完成 `webhtv-ipc-v1` 握手；
/// - home/category/detail/search/play 五方法返回结构化 Result（§9.2 最小子集）；
/// - capability 门禁：未声明的方法返回 `SPIDER_UNSUPPORTED`（§9.7）；
/// - JS fixture 站源用同步 `req()` 访问进程内 fixture 服务（§9.3 沙箱语义）；
/// - 站源抛异常归一化为 `SPIDER_PARSE_ERROR`（§9.5 错误信封）。
///
/// 与 `phase2_ipc_test.dart` 对称：Python sidecar 用同一份 `webhtv-ipc-v1`
/// 契约测试，这份是第三份实现（`tvbox-js-v1`）的进程级验证（§19「契约测试」）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/core/ipc_protocol.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/spider_process.dart';
import 'package:webhtv_pc/services/spider_registry.dart';

import 'fixture_support.dart';
import 'support/test_fixture_server.dart';

void main() {
  group('JS sidecar（Node 运行时，§9.7/§9.8）', () {
    late Directory tempRoot;
    late String jsHostPath;
    late String pythonHostPath;
    late SpiderHostSupervisor supervisor;
    late TestFixtureServer fixtureServer;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('webhtv-phase3-js');
      fixtureServer = await TestFixtureServer.start();
      pythonHostPath = p.join(
        repositoryRoot.path,
        'sidecars',
        'spider-host-python',
        'host.py',
      );
      jsHostPath = p.join(
        repositoryRoot.path,
        'sidecars',
        'spider-host-js',
        'host.js',
      );
      supervisor = SpiderHostSupervisor(
        workRoot: p.join(tempRoot.path, 'sidecars'),
        log: LogService(),
        baseBackoff: const Duration(milliseconds: 40),
        maxBackoff: const Duration(milliseconds: 200),
        maxFailures: 3,
      );
    });

    tearDown(() async {
      await supervisor.shutdownAll();
      await fixtureServer.stop();
      try {
        await tempRoot.delete(recursive: true);
      } catch (_) {}
    });

    /// fixture 服务的动态基地址经 `extend` 传给 JS 站源的 `init(extend)`。
    /// 默认基地址是 `127.0.0.1:18080`，但 `TestFixtureServer` 用随机端口，
    /// 因此必须显式注入，否则站源会请求 18080 拿到 403/连接错误。
    String extendPayload() => jsonEncode({
      'base': fixtureServer.baseUrl,
      'playMedia': '/media/sample.m3u8',
    });

    /// JS fixture Spider。
    ///
    /// 注意：随包 fixture 的 `manifest.json` 位于 `manifests/`，而 `entry`
    /// 是相对 **sidecar 根目录** 的 `spiders/fixture_spider.js`（与 Python
    /// fixture 同布局）。产品路径下 manifest 与 entry 同目录（注册表按
    /// manifest 目录解析 entry），这里沿用 `phase2_ipc_test.dart` 的做法
    /// 显式给出 entryPath。
    LocalSpider jsFixtureSpider() {
      final manifestPath = p.join(
        repositoryRoot.path,
        'sidecars',
        'spider-host-js',
        'manifests',
        'fixture.json',
      );
      final manifest = SpiderManifest.fromJson(
        jsonDecode(File(manifestPath).readAsStringSync()),
      );
      return LocalSpider(
        manifest: manifest,
        manifestPath: manifestPath,
        rootDir: p.join(repositoryRoot.path, 'sidecars', 'spider-host-js'),
        entryPath: p.join(
          repositoryRoot.path,
          'sidecars',
          'spider-host-js',
          'spiders',
          'fixture_spider.js',
        ),
      );
    }

    Future<SpiderHost> startJs(SpiderHostSupervisor sup, LocalSpider spider) async {
      final command = LocalSpiderCommand.resolve(
        spider: spider,
        hostPath: pythonHostPath,
        jsHostPath: jsHostPath,
      )!;
      return sup.ensureRunning(
        siteKey: spider.manifest.key,
        executable: command.executable,
        arguments: command.arguments,
        manifest: spider.manifest,
        extend: extendPayload(),
        environment: {
          'WEBHTV_FIXTURE_BASE': fixtureServer.baseUrl,
        },
      );
    }

    test('resolve 返回 node host.js 命令（Windows 严格用 node.exe）', () {
      final spider = jsFixtureSpider();
      final command = LocalSpiderCommand.resolve(
        spider: spider,
        hostPath: pythonHostPath,
        jsHostPath: jsHostPath,
      );
      expect(command, isNotNull, reason: '本机应能找到 Node 运行时');
      final resolved = command!;
      if (Platform.isWindows) {
        expect(p.basename(resolved.executable).toLowerCase(), 'node.exe');
      } else {
        expect(p.basename(resolved.executable), 'node');
      }
      expect(resolved.arguments, contains(jsHostPath));
      final idxEntry = resolved.arguments.indexOf('--entry');
      expect(idxEntry, greaterThanOrEqualTo(0));
      expect(resolved.arguments[idxEntry + 1], contains('fixture_spider.js'));
      final idxManifest = resolved.arguments.indexOf('--manifest');
      expect(File(resolved.arguments[idxManifest + 1]).existsSync(), isTrue);
    });

    test('resolve：JS 宿主缺失时返回 null（不静默失败）', () {
      final spider = jsFixtureSpider();
      final command = LocalSpiderCommand.resolve(
        spider: spider,
        hostPath: pythonHostPath,
        jsHostPath: p.join(
          repositoryRoot.path,
          'sidecars',
          'spider-host-js',
          'missing-host.js',
        ),
      );
      expect(command, isNull);
    });

    test('resolve：jsHostPath 缺省时按发行包布局从 Python 宿主推导', () {
      final spider = jsFixtureSpider();
      final command = LocalSpiderCommand.resolve(
        spider: spider,
        hostPath: pythonHostPath,
      );
      expect(command, isNotNull);
      expect(command!.arguments.first, endsWith(p.join('spider-host-js', 'host.js')));
    });

    test('Node sidecar 可用；ABI/capability 协商成功', () async {
      final spider = jsFixtureSpider();
      final host = await startJs(supervisor, spider);
      final init = host.initResult!;
      expect(init.majorCompatible, isTrue);
      expect(init.abi, 'webhtv-ipc-v1');
      expect(init.capabilities, containsAll(['home', 'play']));
      expect(host.process.isolation.level, startsWith('job-object'));

      // 未声明 capability 的方法必须返回 SPIDER_UNSUPPORTED（§9.7）。
      await expectLater(
        host.call('live'),
        throwsA(
          isA<SpiderError>().having(
            (error) => error.code,
            'code',
            SpiderErrorCode.unsupported,
          ),
        ),
      );

      await host.destroy();
      expect(supervisor.statuses().first.state, SpiderRuntimeState.stopped);
    });

    test('home 调用返回结构化 Result', () async {
      final spider = jsFixtureSpider();
      final host = await startJs(supervisor, spider);
      final result = await host.call('home') as Map;
      expect(result.containsKey('class'), isTrue);
      expect(result['list'], isA<List>());
      expect((result['list'] as List), isNotEmpty);
      await host.destroy();
    });

    test('category/detail/search/play 五方法完整调用（§9.2 最小子集）', () async {
      final spider = jsFixtureSpider();
      final host = await startJs(supervisor, spider);

      // 参数名与 sidecar_runtime.dart 的真实调用一致。
      final category = await host.call(
        'category',
        params: {'id': '1', 'page': 2, 'filters': const <String, String>{}},
      ) as Map;
      expect(category['list'], isA<List>());
      expect(category['page'], 2);

      final detail = await host.call(
        'detail',
        params: {'id': 'fixture-1'},
      ) as Map;
      expect(detail['list'], isA<List>());

      final search = await host.call(
        'search',
        params: {'keyword': '测试', 'page': 1, 'quick': false},
      ) as Map;
      expect(search['list'], isA<List>());

      final play = await host.call(
        'play',
        params: {'id': 'fixture-1', 'flag': 'js-fixture'},
      ) as Map;
      expect(play['url'], isNotEmpty);

      await host.destroy();
    });

    test('站源异常归一化为 SPIDER_PARSE_ERROR（§9.5 错误信封）', () async {
      final spider = jsFixtureSpider();
      final host = await startJs(supervisor, spider);
      // fixture_spider.js 的 searchContent 在缺关键词时 throw。
      await expectLater(
        host.call('search', params: {'keyword': '', 'page': 1}),
        throwsA(
          isA<SpiderError>().having(
            (error) => error.code,
            'code',
            SpiderErrorCode.parseError,
          ),
        ),
      );
      await host.destroy();
    });

    test('侧车崩溃隔离：主程序存活并进入退避（§9.8）', () async {
      // JS 宿主目前只有一个成功路径 fixture；用不存在的 entry 触发 load 失败，
      // 验证「启动失败只影响该站点」而不是让主进程崩溃。
      final spider = jsFixtureSpider();
      final badSpider = LocalSpider(
        manifest: SpiderManifest.fromJson({
          'abi': 'webhtv-ipc-v1',
          'abiMinor': 0,
          'key': 'js-broken',
          'name': 'JS Broken',
          'runtime': 'node',
          'entry': 'spiders/does_not_exist.js',
          'capabilities': ['home', 'category', 'detail', 'search', 'play'],
          'permissions': {
            'network': true,
            'localProxy': false,
            'ui': false,
            'storage': 'cache-only',
            'process': false,
            'clipboard': false,
            'browser': false,
          },
        }),
        manifestPath: spider.manifestPath,
        rootDir: spider.rootDir,
        entryPath: p.join(spider.rootDir, 'spiders', 'does_not_exist.js'),
      );

      await expectLater(
        startJs(supervisor, badSpider),
        throwsA(isA<SpiderError>()),
      );
      // 主程序存活：另一个正常 JS 站点仍可启动。
      final okHost = await startJs(supervisor, spider);
      expect(await okHost.call('home'), isA<Map>());
      await okHost.destroy();
    });
  });
}