/// JVM（Java）sidecar 宿主门禁测试（设计文档 §9.3、§9.7、§9.8、§9.9，ADR-0002）。
///
/// 覆盖范围：
/// - `LocalSpiderCommand.resolve` 对 `runtime=jvm`/`java` 的 manifest 返回
///   `java -jar host.jar --entry ... --manifest ...`，Windows 下解析出 `java.exe`；
/// - `defaultJvmSidecarHostPath()` 能定位 `sidecars/spider-host-jvm/host.jar`；
/// - 真实 JVM 子进程经 stdio 帧与 Dart 宿主完成 `webhtv-ipc-v1` 握手；
/// - home/category/detail/search/play 五方法返回结构化 Result（§9.2 最小子集）；
/// - capability 门禁：未声明的方法返回 `SPIDER_UNSUPPORTED`（§9.7）；
/// - 参数非法归一化为 `SPIDER_BAD_REQUEST`（§9.5 错误信封）；
/// - `csp_*` 站点判定：无本地 jar → 不可用；Android jar（含 classes.dex）→ 明确
///   报「JVM 无法加载」而不是启动后崩溃（ADR-0002 §1.1）；
/// - 侧车崩溃隔离：坏 entry 只影响该站点，主程序存活并进入退避（§9.8）。
///
/// 与 `phase2_ipc_test.dart`（Python）、`phase3_js_spider_test.dart`（Node）对称：
/// 这是 `webhtv-ipc-v1` 的第四份实现（`tvbox-java-v1`）的进程级验证（§19）。
library;

import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/core/http_api.dart';
import 'package:webhtv_pc/core/ipc_protocol.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/spider_process.dart';
import 'package:webhtv_pc/services/spider_registry.dart';
import 'package:webhtv_pc/services/spider_router.dart';
import 'package:webhtv_pc/services/windows_job.dart';

import 'fixture_support.dart';
import 'support/test_fixture_server.dart';

void main() {
  group('JVM sidecar（Java 运行时，§9.3/§9.9）', () {
    late Directory tempRoot;
    late String pythonHostPath;
    late String jvmHostPath;
    late SpiderHostSupervisor supervisor;
    late TestFixtureServer fixtureServer;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('webhtv-phase3-jvm');
      fixtureServer = await TestFixtureServer.start();
      pythonHostPath = p.join(
        repositoryRoot.path,
        'sidecars',
        'spider-host-python',
        'host.py',
      );
      jvmHostPath = p.join(
        repositoryRoot.path,
        'sidecars',
        'spider-host-jvm',
        'host.jar',
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

    /// fixture 服务的动态基地址经 `extend` 传给 JVM 站源的 `init(extend)`。
    /// manifest 的 `config.base` 固定为 18080，而 `TestFixtureServer` 用随机端口，
    /// 因此必须显式注入，否则站源会请求 18080 拿到连接错误。
    String extendPayload() => jsonEncode({
      'base': fixtureServer.baseUrl,
      'playMedia': '/media/sample.m3u8',
    });

    /// JVM fixture Spider。
    ///
    /// manifest 位于 `manifests/`，`entry` 相对 sidecar 根目录解析为
    /// `spiders/fixture/FixtureSpider.java`（源码入口，宿主用 JDK 自带编译器编译）。
    /// 类名由 manifest `config.className` 给出（`fixture.FixtureSpider`）。
    LocalSpider jvmFixtureSpider() {
      final manifestPath = p.join(
        repositoryRoot.path,
        'sidecars',
        'spider-host-jvm',
        'manifests',
        'fixture.json',
      );
      final manifest = SpiderManifest.fromJson(
        jsonDecode(File(manifestPath).readAsStringSync()),
      );
      return LocalSpider(
        manifest: manifest,
        manifestPath: manifestPath,
        rootDir: p.join(repositoryRoot.path, 'sidecars', 'spider-host-jvm'),
        entryPath: p.join(
          repositoryRoot.path,
          'sidecars',
          'spider-host-jvm',
          'spiders',
          'fixture',
          'FixtureSpider.java',
        ),
      );
    }

    Future<SpiderHost> startJvm(
      SpiderHostSupervisor sup,
      LocalSpider spider,
    ) async {
      final command = LocalSpiderCommand.resolve(
        spider: spider,
        hostPath: pythonHostPath,
        jvmHostPath: jvmHostPath,
      )!;
      return sup.ensureRunning(
        siteKey: spider.manifest.key,
        executable: command.executable,
        arguments: command.arguments,
        manifest: spider.manifest,
        extend: extendPayload(),
      );
    }

    test('resolve 返回 java -jar host.jar 命令（Windows 严格用 java.exe）', () {
      final spider = jvmFixtureSpider();
      final command = LocalSpiderCommand.resolve(
        spider: spider,
        hostPath: pythonHostPath,
        jvmHostPath: jvmHostPath,
      );
      expect(command, isNotNull, reason: '本机应能找到 Java 运行时');
      final resolved = command!;
      if (Platform.isWindows) {
        expect(p.basename(resolved.executable).toLowerCase(), 'java.exe');
      } else {
        expect(p.basename(resolved.executable), 'java');
      }
      expect(resolved.arguments, contains('-jar'));
      expect(resolved.arguments, contains(jvmHostPath));
      final idxEntry = resolved.arguments.indexOf('--entry');
      expect(idxEntry, greaterThanOrEqualTo(0));
      expect(resolved.arguments[idxEntry + 1], contains('FixtureSpider.java'));
      final idxManifest = resolved.arguments.indexOf('--manifest');
      expect(File(resolved.arguments[idxManifest + 1]).existsSync(), isTrue);
    });

    test('resolve：JVM 宿主缺失时返回 null（不静默失败）', () {
      final spider = jvmFixtureSpider();
      final command = LocalSpiderCommand.resolve(
        spider: spider,
        hostPath: pythonHostPath,
        jvmHostPath: p.join(
          repositoryRoot.path,
          'sidecars',
          'spider-host-jvm',
          'missing-host.jar',
        ),
      );
      expect(command, isNull);
    });

    test('resolve：jvmHostPath 缺省时按发行包布局从 Python 宿主推导', () {
      final spider = jvmFixtureSpider();
      final command = LocalSpiderCommand.resolve(
        spider: spider,
        hostPath: pythonHostPath,
      );
      expect(command, isNotNull);
      expect(
        command!.arguments,
        contains(endsWith(p.join('spider-host-jvm', 'host.jar'))),
      );
    });

    test('defaultJvmSidecarHostPath 指向已构建的 host.jar', () {
      final resolved = defaultJvmSidecarHostPath();
      expect(resolved, isNotEmpty, reason: '应能定位 sidecars/spider-host-jvm/host.jar');
      expect(p.basename(resolved), 'host.jar');
      expect(File(resolved).existsSync(), isTrue,
          reason: 'host.jar 缺失，请先运行 sidecars/spider-host-jvm/build.ps1');
    });

    test('JVM sidecar 可用；ABI/capability 协商成功', () async {
      final spider = jvmFixtureSpider();
      final host = await startJvm(supervisor, spider);
      final init = host.initResult!;
      expect(init.majorCompatible, isTrue);
      expect(init.abi, 'webhtv-ipc-v1');
      expect(init.capabilities, containsAll(['home', 'category', 'detail', 'search', 'play']));
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
      final spider = jvmFixtureSpider();
      final host = await startJvm(supervisor, spider);
      final result = await host.call('home') as Map;
      expect(result.containsKey('class'), isTrue);
      expect(result['list'], isA<List>());
      expect((result['list'] as List), isNotEmpty);
      await host.destroy();
    });

    test('category/detail/search/play 五方法完整调用（§9.2 最小子集）', () async {
      final spider = jvmFixtureSpider();
      final host = await startJvm(supervisor, spider);

      final category = await host.call(
        'category',
        params: {'id': '1', 'page': 2, 'filters': const <String, String>{}},
      ) as Map;
      expect(category['list'], isA<List>());
      expect(category['page'], 2);

      final detail = await host.call('detail', params: {'id': 'fixture-1'}) as Map;
      expect(detail['list'], isA<List>());
      expect((detail['list'] as List), isNotEmpty);

      final search = await host.call(
        'search',
        params: {'keyword': '测试', 'page': 1, 'quick': false},
      ) as Map;
      expect(search['list'], isA<List>());
      expect((search['list'] as List), isNotEmpty);

      final play = await host.call(
        'play',
        params: {'id': '/media/sample.m3u8', 'flag': 'jvm-fixture'},
      ) as Map;
      expect(play['url'], isNotEmpty);
      expect(play['flag'], 'jvm-fixture');

      await host.destroy();
    });

    test('参数非法归一化为 SPIDER_BAD_REQUEST（§9.5 错误信封）', () async {
      final spider = jvmFixtureSpider();
      final host = await startJvm(supervisor, spider);
      // search 缺 keyword：宿主必须在进站源前拦下。
      await expectLater(
        host.call('search', params: {'page': 1}),
        throwsA(
          isA<SpiderError>().having(
            (error) => error.code,
            'code',
            SpiderErrorCode.badRequest,
          ),
        ),
      );
      await host.destroy();
    });

    test('侧车崩溃隔离：坏 entry 只影响该站点（§9.8）', () async {
      final spider = jvmFixtureSpider();
      final badSpider = LocalSpider(
        manifest: SpiderManifest.fromJson({
          'abi': 'webhtv-ipc-v1',
          'abiMinor': 0,
          'key': 'jvm-broken',
          'name': 'JVM Broken',
          'runtime': 'jvm',
          'entry': 'spiders/does_not_exist.java',
          'capabilities': ['home', 'category', 'detail', 'search', 'play'],
        }),
        manifestPath: spider.manifestPath,
        rootDir: spider.rootDir,
        entryPath: p.join(spider.rootDir, 'spiders', 'does_not_exist.java'),
      );

      await expectLater(startJvm(supervisor, badSpider), throwsA(isA<SpiderError>()));
      // 主程序存活：另一个正常 JVM 站点仍可启动。
      final okHost = await startJvm(supervisor, spider);
      expect(await okHost.call('home'), isA<Map>());
      await okHost.destroy();
    });

    test('stdin 一次性喂帧后关闭：响应必须写完再退出（§9.3.1）', () async {
      // 回归：宿主曾在 stdin EOF 时立即返回，把已派发但未及写回的请求一起丢掉。
      // 验收脚本的 jvm-host-preflight 用管道一次性喂 initialize 帧，正是这个形态。
      final spider = jvmFixtureSpider();
      final command = LocalSpiderCommand.resolve(
        spider: spider,
        hostPath: pythonHostPath,
        jvmHostPath: jvmHostPath,
      )!;

      final process = await Process.start(
        command.executable,
        command.arguments,
        environment: SidecarEnvironment.build(),
        includeParentEnvironment: false,
        runInShell: false,
      );
      // 写入 initialize 帧后立即关闭 stdin（不等待响应）。
      process.stdin.add(
        IpcFrameCodec.encode({
          'jsonrpc': '2.0',
          'id': 'eof-1',
          'method': 'initialize',
          'params': {
            'abi': 'webhtv-ipc-v1',
            'abiMajor': 1,
            'abiMinor': 0,
            'siteKey': spider.manifest.key,
            'extend': '',
          },
          'deadlineMs': 30000,
        }),
      );
      await process.stdin.flush();
      await process.stdin.close();

      final stdoutBytes = await process.stdout.fold<List<int>>(
        <int>[],
        (acc, chunk) => acc..addAll(chunk),
      );
      final exitCode = await process.exitCode;
      expect(exitCode, 0, reason: '正常 EOF 应以 0 退出');

      final text = utf8.decode(stdoutBytes);
      expect(
        text,
        contains('webhtv-ipc-v1'),
        reason: 'EOF 前派发的 initialize 必须写回响应，不能随退出一起丢失',
      );
      expect(text, contains('eof-1'));
      expect(text, contains('Content-Length:'));
    });
  });

  group('JVM 运行时探测与堆参数（ADR-0002）', () {
    test('parseJavaMajor 兼容 1.8 / 17 / 21 三种版本号形态', () {
      expect(
        LocalSpiderCommand.parseJavaMajor(
          'openjdk version "1.8.0_501"\nJava(TM) SE Runtime Environment',
        ),
        8,
        reason: 'Java 8 的 1.8.x 编号主版本在第二段',
      );
      expect(
        LocalSpiderCommand.parseJavaMajor('openjdk version "17.0.2" 2022-01-18'),
        17,
      );
      expect(
        LocalSpiderCommand.parseJavaMajor(
          'openjdk version "21.0.12" 2025-01-21 LTS\nOpenJDK 64-Bit Server VM',
        ),
        21,
      );
      expect(LocalSpiderCommand.parseJavaMajor(''), isNull);
      expect(LocalSpiderCommand.parseJavaMajor('garbage'), isNull);
    });

    test('probeJavaRuntime 选中的运行时必须能跑 host.jar', () {
      final probe = LocalSpiderCommand.probeJavaRuntime();
      if (!probe.available) {
        // 本机无 JDK 17+ 时如实报告，不静默通过。
        expect(probe.issue, isNotNull);
        markTestSkipped('本机无可用 JDK 17+：${probe.issue}');
        return;
      }
      expect(probe.major, greaterThanOrEqualTo(LocalSpiderCommand.minJavaMajor));
      // `.java` 源码入口需要 JDK（javax.tools 编译器），不是 JRE。
      expect(
        probe.hasCompiler,
        isTrue,
        reason: '选中的 Java 必须带 javac，否则无法编译 .java 站源入口',
      );
      final version = Process.runSync(probe.command!.executable, const ['-version']);
      expect(version.exitCode, 0);
    });

    test('jvmHeapFlags 让 JVM 落在作业对象内存限制内', () {
      // 默认 limits.memoryMiB = 256；JVM 不加参数会预留 640 MiB 而启动失败。
      final flags = LocalSpiderCommand.jvmHeapFlags(256);
      expect(flags, contains('-Xmx128m'));
      expect(flags, contains('-Xms16m'));
      expect(flags, contains('-XX:MaxMetaspaceSize=64m'));

      // 堆上限必须严格小于作业限制，给 Metaspace/栈/直接内存留出余量。
      final heap = int.parse(
        RegExp(r'-Xmx(\d+)m').firstMatch(flags.join(' '))!.group(1)!,
      );
      expect(heap, lessThan(256));

      // 内存限制过小时不给参数：JVM 无论如何都跑不起来，交由宿主报错。
      expect(LocalSpiderCommand.jvmHeapFlags(64), isEmpty);

      // 大内存站点：堆上限受夹取，不会无限放大。
      final big = LocalSpiderCommand.jvmHeapFlags(16384);
      final bigHeap = int.parse(
        RegExp(r'-Xmx(\d+)m').firstMatch(big.join(' '))!.group(1)!,
      );
      expect(bigHeap, lessThanOrEqualTo(2048));
    });
  });

  group('csp_* 站点到桌面 JVM 站源的映射（ADR-0002）', () {
    late Directory tempRoot;
    late String spidersRoot;
    late String jvmHostPath;
    late String pythonHostPath;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('webhtv-csp');
      spidersRoot = p.join(tempRoot.path, 'spiders');
      jvmHostPath = p.join(
        repositoryRoot.path,
        'sidecars',
        'spider-host-jvm',
        'host.jar',
      );
      pythonHostPath = p.join(
        repositoryRoot.path,
        'sidecars',
        'spider-host-python',
        'host.py',
      );
    });

    tearDown(() async {
      try {
        await tempRoot.delete(recursive: true);
      } catch (_) {}
    });

    SpiderRouter routerWith(String registryRoot) => SpiderRouter(
      client: HttpApiClient(),
      globalHeaders: const [],
      registry: SpiderManifestRegistry(
        root: registryRoot,
        log: LogService(),
      ),
      hostPath: pythonHostPath,
      jvmHostPath: jvmHostPath,
      cspBinding: CspJvmBinding(root: p.join(registryRoot, 'csp')),
    );

    Site cspSite({String key = 'csp_Demo'}) =>
        Site(key: key, name: 'Demo', type: 3, api: key);

    test('无本地 jar 时如实报不可用，并给出缓存目录', () {
      final router = routerWith(spidersRoot);
      final availability = router.classifySite(cspSite());
      expect(availability.available, isFalse);
      expect(availability.runtimeName, 'PC Java Spider');
      expect(availability.reason, contains('classes.dex'));
      expect(availability.reason, contains(p.join('csp', 'csp_Demo')));
    });

    test('Android jar（含 classes.dex）报「JVM 无法加载」而不是启动后崩溃', () async {
      final directory = Directory(p.join(spidersRoot, 'csp', 'csp_Demo'));
      await directory.create(recursive: true);
      // 构造最小 zip：只需目录项里出现 `classes.dex` 明文即可被识别。
      await _writeMinimalZip(
        File(p.join(directory.path, 'index.jar')),
        const ['classes.dex', 'AndroidManifest.xml'],
      );

      final router = routerWith(spidersRoot);
      final availability = router.classifySite(cspSite());
      expect(availability.available, isFalse);
      expect(availability.runtimeName, 'Android/JAR Spider');
      expect(availability.reason, contains('classes.dex'));
      expect(availability.reason, contains('ADR-0002'));
    });

    test('桌面 jar 存在且 Java 可用时判定为可用', () async {
      final directory = Directory(p.join(spidersRoot, 'csp', 'csp_Demo'));
      await directory.create(recursive: true);
      await _writeMinimalZip(
        File(p.join(directory.path, 'index.jar')),
        const ['fixture/FixtureSpider.class'],
      );

      final router = routerWith(spidersRoot);
      final availability = router.classifySite(cspSite());
      expect(availability.available, isTrue,
          reason: availability.reason ?? '');
      expect(availability.runtimeName, contains('tvbox-java-v1'));
      expect(availability.reason, contains('runtime=jvm'));
    });

    test('CspJvmBinding 类名解析与目录净化', () {
      expect(CspJvmBinding.matches('csp_Demo'), isTrue);
      expect(CspJvmBinding.matches(' CSP_Demo '), isTrue);
      expect(CspJvmBinding.matches('demo'), isFalse);
      expect(CspJvmBinding.classNameOf('csp_Demo'), 'Demo');
      expect(CspJvmBinding.classNameOf('demo'), 'demo');
      final binding = CspJvmBinding(root: p.join(spidersRoot, 'csp'));
      expect(
        binding.directoryFor('csp_a/b'),
        p.join(spidersRoot, 'csp', 'csp_a_b'),
        reason: '站点 key 含路径分隔符时必须净化，不得越出缓存目录',
      );
    });

    test('无注册表时 csp_* 仍返回结构化不可用结论（不显示空列表）', () {
      final availability = SpiderRouter.classify(cspSite());
      expect(availability.available, isFalse);
      expect(availability.runtimeName, 'PC Java Spider');
      expect(availability.stage, 'Phase 3');
    });
  });
}

/// 写一个只含目录项的最小 zip（无需压缩数据，`classes.dex` 明文出现在条目名中）。
Future<void> _writeMinimalZip(File file, List<String> entryNames) async {
  final builder = BytesBuilder();
  final central = <List<int>>[];
  for (final name in entryNames) {
    final nameBytes = utf8.encode(name);
    final offset = builder.length;
    // local file header
    builder.add(_le32(0x04034b50));
    builder.add(_le16(20)); // version needed
    builder.add(_le16(0)); // flags
    builder.add(_le16(0)); // method = stored
    builder.add(_le16(0)); // mtime
    builder.add(_le16(0)); // mdate
    builder.add(_le32(0)); // crc32
    builder.add(_le32(0)); // compressed size
    builder.add(_le32(0)); // uncompressed size
    builder.add(_le16(nameBytes.length));
    builder.add(_le16(0)); // extra length
    builder.add(nameBytes);
    central.add([
      ..._le32(0x02014b50),
      ..._le16(20), // version made by
      ..._le16(20), // version needed
      ..._le16(0), // flags
      ..._le16(0), // method
      ..._le16(0), // mtime
      ..._le16(0), // mdate
      ..._le32(0), // crc32
      ..._le32(0), // compressed size
      ..._le32(0), // uncompressed size
      ..._le16(nameBytes.length),
      ..._le16(0), // extra
      ..._le16(0), // comment
      ..._le16(0), // disk
      ..._le16(0), // internal attrs
      ..._le32(0), // external attrs
      ..._le32(offset),
      ...nameBytes,
    ]);
  }
  final centralStart = builder.length;
  for (final record in central) {
    builder.add(record);
  }
  final centralSize = builder.length - centralStart;
  builder.add(_le32(0x06054b50));
  builder.add(_le16(0));
  builder.add(_le16(0));
  builder.add(_le16(central.length));
  builder.add(_le16(central.length));
  builder.add(_le32(centralSize));
  builder.add(_le32(centralStart));
  builder.add(_le16(0));
  await file.writeAsBytes(builder.takeBytes());
}

List<int> _le16(int value) => [value & 0xff, (value >> 8) & 0xff];

List<int> _le32(int value) => [
  value & 0xff,
  (value >> 8) & 0xff,
  (value >> 16) & 0xff,
  (value >> 24) & 0xff,
];
