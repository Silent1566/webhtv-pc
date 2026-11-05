/// CatVod 方言站源经 Python sidecar 端到端跑通（方案 2）。
///
/// 覆盖：
/// - `ext.loader` 形态被 registrar 识别并落盘（loader.py + 生成的壳 spider.py）；
/// - 真实 Python 子进程加载壳 → 垫片 `base.spider` → CatVod 位置参数方法；
/// - home/category/detail/search/play 五方法返回结构化 Result；
/// - 站源自己的 `print()` 落到 stderr，不污染 stdio 协议帧；
/// - 站源未实现的方法如实报 `SPIDER_UNSUPPORTED`，而不是空列表。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/core/ipc_protocol.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/direct_spider_registrar.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/spider_process.dart';
import 'package:webhtv_pc/services/spider_registry.dart';
import 'package:webhtv_pc/services/windows_job.dart';

import 'fixture_support.dart';
import 'support/test_fixture_server.dart';

/// 探测一个**真的能跑**的 Python。
///
/// 不能直接用 `LocalSpiderCommand.resolve`：Windows 上它优先返回 `py.exe -3`，
/// 而 py launcher 可能指向已被删除/损坏的解释器（本机就是这种情况），
/// 于是进程一启动就 101 退出，测试失败原因会被伪装成「sidecar 崩溃」。
SidecarCommand? probePythonCommand() {
  final candidates = <SidecarCommand>[
    if (Platform.environment['WEBHTV_TEST_PYTHON'] case final explicit?)
      SidecarCommand(executable: explicit, arguments: const []),
  ];
  final path = Platform.environment['PATH'] ?? '';
  for (final dir in path.split(Platform.isWindows ? ';' : ':')) {
    if (dir.trim().isEmpty) continue;
    for (final name in Platform.isWindows
        ? const ['python.exe', 'py.exe']
        : const ['python3', 'python']) {
      candidates.add(
        SidecarCommand(
          executable: p.join(dir.trim(), name),
          arguments: name == 'py.exe' ? const ['-3'] : const [],
        ),
      );
    }
  }
  for (final command in candidates) {
    if (!File(command.executable).existsSync()) continue;
    try {
      final probe = Process.runSync(command.executable, [
        ...command.arguments,
        '-c',
        'import sys; print(sys.version.split()[0])',
      ]);
      // Windows 的 WindowsApps / Python\\bin 别名占位符会「成功启动」但不输出任何内容，
      // 必须要求真的打印出版本号才能用。
      final out = (probe.stdout as Object?).toString().trim();
      if (probe.exitCode == 0 && out.isNotEmpty && RegExp(r'^\d+').hasMatch(out)) {
        return command;
      }
    } catch (_) {
      // 继续试下一个候选。
    }
  }
  return null;
}

void main() {
  group('CatVod 方言站源（Python sidecar，方案 2）', () {
    late Directory tempRoot;
    late TestFixtureServer fixtureServer;
    late SpiderHostSupervisor supervisor;
    late SpiderManifestRegistry registry;
    late LogService log;
    late String pythonHostPath;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('webhtv-catvod');
      fixtureServer = await TestFixtureServer.start();
      log = LogService();
      registry = SpiderManifestRegistry(root: tempRoot.path, log: log);
      pythonHostPath = p.join(
        repositoryRoot.path,
        'sidecars',
        'spider-host-python',
        'host.py',
      );
      supervisor = SpiderHostSupervisor(
        workRoot: p.join(tempRoot.path, 'sidecars'),
        log: log,
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

    /// 用真实的 CatVod 形状 fixture 当 loader：注册表看到的仍是 ext.loader 形态。
    Future<LocalSpider> registerShell() async {
      final fixture = File(
        p.join(
          repositoryRoot.path,
          'sidecars',
          'spider-host-python',
          'spiders',
          'fixture_catvod.py',
        ),
      ).readAsStringSync();
      final registrar = DirectSpiderRegistrar(
        root: tempRoot.path,
        registry: registry,
        log: log,
        // 必须用 Response.bytes：http.Response(String) 默认按 latin1 编码，
        // 含中文的 Python 源码会抛 'Contains invalid characters'。
        client: MockClient(
          (_) async => http.Response.bytes(utf8.encode(fixture), 200),
        ),
      );
      final site = Site(
        key: 'catvod-fixture',
        name: 'CatVod 样本',
        type: 3,
        api: 'csp_PyProxy',
        ext: {
          'loader': '${fixtureServer.baseUrl}/Atvp.py?v=1',
          'source': '${fixtureServer.baseUrl}/plugins/1.txt',
          'secret': 'x',
        },
      );
      final result = await registrar.materialize(AppConfig(sites: [site]));
      expect(
        result.keys,
        ['catvod-fixture'],
        reason: '注册失败，日志：\n${log.export()}',
      );
      return result['catvod-fixture']!;
    }

    Future<SpiderHost> start(LocalSpider spider, {String extend = ''}) async {
      // 只替换解释器为探测到的可用 Python：LocalSpiderCommand.resolve 会优先给出
      // py.exe -3，而本机 py launcher 指向坏解释器；解释器参数由探测结果自带，
      // 宿主参数必须自己拼，不能把 resolve 的解释器参数一起带过来。
      final resolved = probePythonCommand();
      expect(resolved, isNotNull, reason: '本机应能找到可用的 Python 运行时');
      final command = SidecarCommand(
        executable: resolved!.executable,
        arguments: <String>[
          ...resolved.arguments,
          pythonHostPath,
          '--entry',
          spider.entryPath,
          '--manifest',
          spider.manifestPath,
        ],
      );
      try {
        return await supervisor.ensureRunning(
          siteKey: spider.manifest.key,
          executable: command.executable,
          arguments: command.arguments,
          manifest: spider.manifest,
          extend: extend,
        );
      } catch (error) {
        final status = supervisor.statuses().firstOrNull;
        fail(
          'ensureRunning 失败：$error\n'
          'executable=${command.executable} args=${command.arguments}\n'
          'stderr=\n${(status?.stderrLines ?? const <String>[]).join("\n")}',
        );
      }
    }

    test('ext.loader 被识别并生成 CatVod 壳入口', () async {
      final spider = await registerShell();
      final dir = p.dirname(spider.manifestPath);
      expect(File(p.join(dir, 'loader.py')).existsSync(), isTrue);
      final entry = File(p.join(dir, 'spider.py')).readAsStringSync();
      expect(entry, contains('create_catvod_spider'));
      expect(spider.manifest.runtime, 'python-catvod');
    });

    test('启动后五方法经 CatVod 签名适配返回结构化 Result', () async {
      final spider = await registerShell();
      // extend 传 sidecar 的 initialize 入参，Crawler.init() 保存后供 homeContent 使用：
      // 这样同时验证了「Dart 侧 extend 原样透传」这条链路。
      final host = await start(spider, extend: fixtureServer.baseUrl);
      expect(host.initResult!.abi, 'webhtv-ipc-v1');

      final home = await host.call('home') as Map;
      final classes = home['class'] as List;
      expect(classes, isNotEmpty);
      // 垫片 self.fetch() 走的是 fixture 服务，说明 verify/TLS 默认路径可用。
      expect(
        (classes.first as Map)['type_name'],
        contains('/api/echo'),
        reason: 'homeContent 里的 self.fetch 应真的访问到测试服务',
      );

      final category = await host.call(
        'category',
        params: {'id': '1', 'page': 2, 'filters': const <String, String>{}},
      ) as Map;
      expect(category['page'], 2);
      expect((category['list'] as List), isNotEmpty);

      final detail = await host.call(
        'detail',
        params: {'id': 'vod-1'},
      ) as Map;
      expect(((detail['list'] as List).first as Map)['vod_id'], 'vod-1');

      final search = await host.call(
        'search',
        params: {'keyword': '测试', 'page': 1, 'quick': false},
      ) as Map;
      expect(((search['list'] as List).first as Map)['vod_name'], '测试');

      final play = await host.call(
        'play',
        params: {'id': 'vod-1-1', 'flag': 'line'},
      ) as Map;
      expect(play['url'], contains('vod-1-1'));

      await host.destroy();
    });

    test('站源 print() 落到 stderr，协议帧不受污染', () async {
      final spider = await registerShell();
      final host = await start(spider);
      // 多个并发调用：若站源 print 写进了 stdout，帧会被截断/解析失败。
      final results = await Future.wait([
        host.call('home'),
        host.call('category', params: {'id': '1', 'page': 1}),
        host.call('search', params: {'keyword': 'a', 'page': 1}),
      ]);
      expect(results, hasLength(3));
      await host.destroy();
    });

    test('站源未实现的方法如实报 SPIDER_UNSUPPORTED', () async {
      final spider = await registerShell();
      final host = await start(spider);
      // fixture 继承了垫片的 liveContent 默认实现（返回空 class/list），
      // 但 manifest 未声明 live capability → 必须被门禁拒绝。
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
    });

    test('destroy 之后 sidecar 以 0 退出（stdout 常驻重定向必须撤销）', () async {
      // 回归：曾把 sys.stdout 常驻指向 sys.stderr 且从不撤销 → 解释器 finalize
      // 时 stderr 的 BufferedWriter 要承担两份引用 + daemon 线程仍持锁，
      // 于是出现 "Fatal Python error: _enter_buffered_busy ... finalizing"，
      // 进程以 0xC0000005 退出，宿主把正常关闭误判成崩溃。
      final spider = await registerShell();
      final resolved = probePythonCommand();
      expect(resolved, isNotNull, reason: '本机应能找到可用的 Python 运行时');

      for (var round = 0; round < 3; round += 1) {
        final tag = 'exit-$round';
        final process = await Process.start(
          resolved!.executable,
          <String>[
            ...resolved.arguments,
            pythonHostPath,
            '--entry',
            spider.entryPath,
            '--manifest',
            spider.manifestPath,
          ],
          environment: SidecarEnvironment.build(),
          includeParentEnvironment: false,
          runInShell: false,
        );
        final messages = <Map<String, Object?>>[
          {
            'jsonrpc': '2.0',
            'id': '$tag-init',
            'method': 'initialize',
            'params': {
              'abi': 'webhtv-ipc-v1',
              'abiMajor': 1,
              'abiMinor': 0,
              'siteKey': spider.manifest.key,
              'extend': '',
            },
            'deadlineMs': 30000,
          },
          {
            'jsonrpc': '2.0',
            'id': '$tag-home',
            'method': 'home',
            'params': const <String, Object?>{},
            'deadlineMs': 30000,
          },
          {
            'jsonrpc': '2.0',
            'id': '$tag-destroy',
            'method': 'destroy',
            'params': const <String, Object?>{},
            'deadlineMs': 30000,
          },
        ];
        for (final message in messages) {
          process.stdin.add(IpcFrameCodec.encode(message));
        }
        await process.stdin.flush();
        await process.stdin.close();

        final stdoutBytes = await process.stdout.fold<List<int>>(
          <int>[],
          (acc, chunk) => acc..addAll(chunk),
        );
        final stderrBytes = await process.stderr.fold<List<int>>(
          <int>[],
          (acc, chunk) => acc..addAll(chunk),
        );
        final exitCode = await process.exitCode;
        expect(
          exitCode,
          0,
          reason:
              '第 $round 轮：正常 destroy 后必须以 0 退出，实际 $exitCode\n'
              'stderr=\n${utf8.decode(stderrBytes, allowMalformed: true)}',
        );
        expect(
          utf8.decode(stdoutBytes),
          contains('$tag-home'),
          reason: '退出前派发的 home 必须写回响应',
        );
      }
    });
  });
}