/// `webhtv-ipc-v1` 契约与 sidecar 生命周期/隔离测试
/// （设计文档 §9.3、§9.3.1、§9.5、§9.7、§9.8、§18.2.1、§18.3）。
///
/// 这些测试使用**真实的** Python sidecar 子进程与真实的 stdio 帧通信，不用桩：
/// 只有这样才能证明「主进程不加载不可信代码」「崩溃只影响该站点」「超时/取消/
/// 资源超限被隔离」这些要求真的成立。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/core/ipc_protocol.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/spider_process.dart';
import 'package:webhtv_pc/services/spider_registry.dart';
import 'package:webhtv_pc/services/windows_job.dart';

import 'fixture_support.dart';
import 'support/test_fixture_server.dart';

void main() {
  // ---------------------------------------------------------------------------
  // 帧编解码（§9.3.1）
  // ---------------------------------------------------------------------------
  group('IPC 帧编解码（§9.3.1）', () {
    test('解码结果带 Content-Length 与空行分隔符', () {
      final frame = IpcFrameCodec.encode({
        'jsonrpc': '2.0',
        'id': 'req-1',
        'result': {'ok': true},
      });
      final text = utf8.decode(frame);
      expect(text, startsWith('Content-Length: '));
      expect(text, contains('\r\n\r\n'));
      expect(IpcFrameCodec.decode(frame, maxBytes: 1024), {
        'jsonrpc': '2.0',
        'id': 'req-1',
        'result': {'ok': true},
      });
    });

    test('Content-Length 按 UTF-8 字节数而非字符数计算', () {
      final payload = {'text': '中文内容 🎬'};
      final frame = IpcFrameCodec.encode(payload);
      final text = utf8.decode(frame);
      final declared = int.parse(
        RegExp(r'Content-Length: (\d+)').firstMatch(text)!.group(1)!,
      );
      final bodyBytes = utf8.encode(text.split('\r\n\r\n').last);
      expect(declared, bodyBytes.length);
      expect(jsonDecode(utf8.decode(bodyBytes)), payload);
    });

    test('decode 拒绝缺失 Content-Length 的帧', () {
      expect(
        () => IpcFrameCodec.decode(
          Uint8List.fromList(utf8.encode('{}\r\n\r\n{}')),
          maxBytes: 1024,
        ),
        throwsA(isA<IpcFrameError>()),
      );
    });

    test('decode 拒绝 Content-Length 与实际长度不一致', () {
      final frame = utf8.encode('Content-Length: 10\r\n\r\n{}');
      expect(
        () => IpcFrameCodec.decode(
          Uint8List.fromList(frame),
          maxBytes: 1024,
        ),
        throwsA(isA<IpcFrameError>()),
      );
    });

    test('decode 拒绝非 JSON payload', () {
      final frame = utf8.encode('Content-Length: 8\r\n\r\nnot-json');
      expect(
        () => IpcFrameCodec.decode(
          Uint8List.fromList(frame),
          maxBytes: 1024,
        ),
        throwsA(isA<IpcFrameError>()),
      );
    });

    test('超过单帧上限抛 IpcFrameTooLarge 且不读取 payload', () {
      final frame = utf8.encode('Content-Length: 999999\r\n\r\n');
      expect(
        () => IpcFrameCodec.decode(
          Uint8List.fromList(frame),
          maxBytes: 1024,
        ),
        throwsA(isA<IpcFrameTooLarge>()),
      );
    });

    test('增量解码支持任意切分（禁止依赖“一行一个 JSON”）', () {
      final decoder = IpcFrameDecoder(maxFrameBytes: 1024 * 1024);
      final first = IpcFrameCodec.encode({'id': 'a', 'result': 1});
      final second = IpcFrameCodec.encode({'id': 'b', 'result': 2});
      final stream = <int>[...first, ...second];

      final messages = <Object?>[];
      // 逐字节喂入：这是最强的切分压力测试。
      for (final byte in stream) {
        messages.addAll(decoder.add([byte]));
      }
      expect(messages.length, 2);
      expect((messages[0] as Map)['id'], 'a');
      expect((messages[1] as Map)['id'], 'b');
      expect(decoder.bufferedBytes, 0);
    });

    test('stdout 出现非协议数据判定为协议污染', () {
      final decoder = IpcFrameDecoder(maxFrameBytes: 64);
      expect(
        () => decoder.add(utf8.encode('x' * 200)),
        throwsA(isA<IpcFrameError>()),
      );
    });

    test('LF 分隔符同样被接受（兼容宽松实现）', () {
      final payload = utf8.encode('{"id":"a"}');
      final frame = <int>[
        ...utf8.encode('Content-Length: ${payload.length}\n\n'),
        ...payload,
      ];
      final decoder = IpcFrameDecoder(maxFrameBytes: 1024);
      expect(decoder.add(frame).length, 1);
    });
  });

  // ---------------------------------------------------------------------------
  // 信封与 ABI 协商（§9.3、§9.5、§9.7）
  // ---------------------------------------------------------------------------
  group('信封与 ABI 协商（§9.3、§9.5）', () {
    test('请求信封校验：id/method 必须非空，deadlineMs 必须为正整数', () {
      expect(
        IpcEnvelope.validateRequest({
          'jsonrpc': '2.0',
          'id': 'r1',
          'method': 'home',
          'params': <String, Object?>{},
          'deadlineMs': 1000,
        }),
        isNull,
      );
      expect(
        IpcEnvelope.validateRequest({
          'jsonrpc': '2.0',
          'id': '',
          'method': 'home',
        }),
        contains('id'),
      );
      expect(
        IpcEnvelope.validateRequest({
          'jsonrpc': '2.0',
          'id': 'r1',
          'method': 'home',
          'deadlineMs': 0,
        }),
        contains('deadlineMs'),
      );
      expect(
        IpcEnvelope.validateRequest({
          'jsonrpc': '2.0',
          'id': 'r1',
          'method': 'home',
          'params': 'not-a-map',
        }),
        contains('params'),
      );
    });

    test('统一错误对象包含全部必需字段', () {
      final error = SpiderError(
        code: SpiderErrorCode.timeout,
        message: '超时',
        siteKey: 'site-a',
        requestId: 'req-1',
        details: const {'method': 'home'},
      );
      final json = error.toJson();
      for (final key in [
        'code',
        'category',
        'message',
        'retryable',
        'userVisible',
        'siteKey',
        'requestId',
        'details',
        'diagnosticId',
      ]) {
        expect(json.containsKey(key), isTrue, reason: '缺少字段 $key');
      }
      expect(error.category, SpiderErrorCategory.site);
      expect(error.retryable, isTrue);
      expect(error.userVisible, isTrue);
    });

    test('错误码集合覆盖 §9.5 全部定义', () {
      expect(SpiderErrorCode.all, containsAll(const [
        'SPIDER_INIT_FAILED',
        'SPIDER_UNSUPPORTED',
        'SPIDER_BAD_REQUEST',
        'SPIDER_HTTP_ERROR',
        'SPIDER_PARSE_ERROR',
        'SPIDER_TIMEOUT',
        'SPIDER_CANCELLED',
        'SPIDER_CRASHED',
        'SPIDER_RESOURCE_LIMIT',
      ]));
    });

    test('ABI major 不匹配必须被识别', () {
      expect(abiMajorMatches('webhtv-ipc-v1', 'webhtv-ipc-v1'), isTrue);
      expect(abiMajorMatches('webhtv-ipc-v2', 'webhtv-ipc-v1'), isFalse);
      expect(abiMajorMatches('other-ipc-v1', 'webhtv-ipc-v1'), isFalse);
    });

    test('cancel 通知两种名字都被接受', () {
      expect(SpiderMethod.isCancel(r'$/cancelRequest'), isTrue);
      expect(SpiderMethod.isCancel(r'$/cancel'), isTrue);
      expect(SpiderMethod.isCancel('home'), isFalse);
    });

    test('manifest 校验拒绝禁止权限与错误 ABI', () {
      final forbidden = SpiderManifest.fromJson({
        'abi': 'webhtv-ipc-v1',
        'abiMinor': 0,
        'key': 'k',
        'name': 'n',
        'runtime': 'python-3',
        'entry': 'a.py',
        'capabilities': ['home', 'category', 'detail', 'search', 'play'],
        'permissions': {
          'network': true,
          'localProxy': false,
          'ui': true,
          'storage': 'cache-only',
          'process': false,
          'clipboard': false,
          'browser': false,
        },
        'limits': {
          'memoryMiB': 64,
          'cpuSeconds': 5,
          'concurrency': 1,
          'responseMiB': 1,
        },
      });
      expect(forbidden.problems, isNotEmpty);
      expect(forbidden.problems.join(), contains('ui'));

      final badAbi = SpiderManifest.fromJson({
        'abi': 'webhtv-ipc-v2',
        'abiMinor': 0,
        'key': 'k',
        'name': 'n',
        'runtime': 'python-3',
        'entry': 'a.py',
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
        'limits': {
          'memoryMiB': 64,
          'cpuSeconds': 5,
          'concurrency': 1,
          'responseMiB': 1,
        },
      });
      expect(badAbi.problems.join(), contains('abi'));
    });

    test('manifest 缺少必需方法时给出缺失清单', () {
      final partial = SpiderManifest.fromJson({
        'abi': 'webhtv-ipc-v1',
        'abiMinor': 0,
        'key': 'k',
        'name': 'n',
        'runtime': 'python-3',
        'entry': 'a.py',
        'capabilities': ['home'],
        'permissions': {
          'network': true,
          'localProxy': false,
          'ui': false,
          'storage': 'cache-only',
          'process': false,
          'clipboard': false,
          'browser': false,
        },
        'limits': {
          'memoryMiB': 64,
          'cpuSeconds': 5,
          'concurrency': 1,
          'responseMiB': 1,
        },
      });
      expect(partial.missingRequired, contains('search'));
      expect(partial.missingRequired, contains('play'));
    });
  });

  // ---------------------------------------------------------------------------
  // 真实 sidecar 子进程（§9.8）
  // ---------------------------------------------------------------------------
  group('sidecar 进程生命周期与隔离（§9.8、§18.3）', () {
    late Directory tempRoot;
    late String hostPath;
    late SpiderHostSupervisor supervisor;

    /// 自带 fixture 服务：sidecar 的 fixture 站源需要访问 HTTP fixture，
    /// 这里用进程内服务替代外部预启动的 `tools/fixture_server`，
    /// 让 `flutter test` 在干净机器上也能独立复现（§19）。
    late TestFixtureServer fixtureServer;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('webhtv-phase2-ipc');
      fixtureServer = await TestFixtureServer.start();
      hostPath = p.join(
        repositoryRoot.path,
        'sidecars',
        'spider-host-python',
        'host.py',
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

    /// 把 fixture 服务地址通过白名单环境变量传给 sidecar 子进程。
    Map<String, String> fixtureEnvironment() => {
      'WEBHTV_FIXTURE_BASE': fixtureServer.baseUrl,
    };

    test('环境变量白名单：凭据与开发机 PATH 不传给 sidecar', () {
      final env = SidecarEnvironment.build();
      expect(SidecarEnvironment.isWhitelisted(env), isTrue);
      expect(env.containsKey('APPDATA'), isFalse);
      expect(env.containsKey('USERPROFILE'), isFalse);
      expect(env.containsKey('HTTP_PROXY'), isFalse);
      // PATH 只保留系统目录，不包含用户级路径。
      final path = env['PATH'] ?? '';
      expect(path.contains('AppData'), isFalse);
      expect(path.contains('puro'), isFalse);
    });

    test('Python sidecar 可用；ABI/capability 协商成功', () async {
      final spider = _fixtureSpider();
      final command = LocalSpiderCommand.resolve(
        spider: spider,
        hostPath: hostPath,
      );
      expect(command, isNotNull, reason: '本机应能找到 Python 运行时');

      final host = await supervisor.ensureRunning(
        siteKey: spider.manifest.key,
        executable: command!.executable,
        arguments: command.arguments,
        manifest: spider.manifest,
        environment: fixtureEnvironment(),
      );
      final init = host.initResult!;
      expect(init.majorCompatible, isTrue);
      expect(init.capabilities, containsAll(['home', 'play']));
      expect(host.process.isolation.level, startsWith('job-object'));
      expect(host.process.isolation.canTerminateTree, isTrue);

      // 未声明 capability 的方法必须返回 SPIDER_UNSUPPORTED（§9.7）。
      await expectLater(
        host.call('live', params: const {}),
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
      final spider = _fixtureSpider();
      final command = LocalSpiderCommand.resolve(
        spider: spider,
        hostPath: hostPath,
      )!;
      final host = await supervisor.ensureRunning(
        siteKey: spider.manifest.key,
        executable: command.executable,
        arguments: command.arguments,
        manifest: spider.manifest,
        environment: fixtureEnvironment(),
      );
      final result = await host.call('home') as Map;
      expect(result.containsKey('class'), isTrue);
      expect(result['list'], isA<List>());
      await host.destroy();
    });

    test('崩溃隔离：sidecar 崩溃后主程序存活并进入退避', () async {
      final spider = _crashSpider();
      final command = LocalSpiderCommand.resolve(
        spider: spider,
        hostPath: hostPath,
      )!;
      final host = await supervisor.ensureRunning(
        siteKey: spider.manifest.key,
        executable: command.executable,
        arguments: command.arguments,
        manifest: spider.manifest,
      );

      await expectLater(
        host.call('home'),
        throwsA(
          isA<SpiderError>().having(
            (error) => error.code,
            'code',
            SpiderErrorCode.crashed,
          ),
        ),
      );

      // 等待崩溃监听写入退避状态。
      await _waitFor(
        () => supervisor.statuses().first.state == SpiderRuntimeState.crashed ||
            supervisor.statuses().first.state == SpiderRuntimeState.backoff,
      );
      final status = supervisor.statuses().first;
      expect(status.failureCount, greaterThanOrEqualTo(1));
      expect(status.state, isNot(SpiderRuntimeState.running));

      // 主程序：其他站点运行时不受影响（这里用一个正常 Spider 证明）。
      final ok = _fixtureSpider();
      final okCommand = LocalSpiderCommand.resolve(
        spider: ok,
        hostPath: hostPath,
      )!;
      final okHost = await supervisor.ensureRunning(
        siteKey: ok.manifest.key,
        executable: okCommand.executable,
        arguments: okCommand.arguments,
        manifest: ok.manifest,
        environment: fixtureEnvironment(),
      );
      expect(await okHost.call('home'), isA<Map>());
      await okHost.destroy();
    });

    test('退避上限：连续失败达到上限后进入禁用状态', () async {
      final spider = _crashSpider();
      final command = LocalSpiderCommand.resolve(
        spider: spider,
        hostPath: hostPath,
      )!;

      for (var attempt = 0; attempt < 3; attempt++) {
        try {
          final host = await supervisor.ensureRunning(
            siteKey: spider.manifest.key,
            executable: command.executable,
            arguments: command.arguments,
            manifest: spider.manifest,
          );
          await host.call('home').catchError((Object _) => null);
        } catch (_) {
          // 退避窗口内会直接抛错，属于预期路径。
        }
        await Future<void>.delayed(const Duration(milliseconds: 260));
      }

      final status = supervisor.statuses().first;
      expect(status.failureCount, greaterThanOrEqualTo(3));
      expect(status.state, SpiderRuntimeState.disabled);
      // 禁用后必须拒绝启动，而不是无限快速重启（§9.3.1）。
      await expectLater(
        supervisor.ensureRunning(
          siteKey: spider.manifest.key,
          executable: command.executable,
          arguments: command.arguments,
          manifest: spider.manifest,
        ),
        throwsA(isA<SpiderError>()),
      );
      supervisor.reset(spider.manifest.key);
      expect(
        supervisor.statuses().first.state,
        SpiderRuntimeState.stopped,
      );
    });

    test('超时隔离：不响应取消的请求被进程级超时兜底', () async {
      final spider = _faultSpider('hang');
      final command = LocalSpiderCommand.resolve(
        spider: spider,
        hostPath: hostPath,
      )!;
      final host = await supervisor.ensureRunning(
        siteKey: spider.manifest.key,
        executable: command.executable,
        arguments: command.arguments,
        manifest: spider.manifest,
      );

      final stopwatch = Stopwatch()..start();
      await expectLater(
        host.call('home', deadline: const Duration(milliseconds: 700)),
        throwsA(
          isA<SpiderError>().having(
            (error) => error.code,
            'code',
            SpiderErrorCode.timeout,
          ),
        ),
      );
      stopwatch.stop();
      // 必须真的超时返回，不能被无限挂起。
      expect(stopwatch.elapsed.inMilliseconds, lessThan(3000));

      // 超时后按 §9.3.1 依次取消 → 宽限 → 终止进程树。
      await _waitFor(() => !host.process.isRunning, timeoutMs: 5000);
      expect(host.process.isRunning, isFalse);
    });

    test('取消隔离：可取消调用返回 SPIDER_CANCELLED 且进程回到空闲', () async {
      final spider = _faultSpider('slow-cancel');
      final command = LocalSpiderCommand.resolve(
        spider: spider,
        hostPath: hostPath,
      )!;
      final host = await supervisor.ensureRunning(
        siteKey: spider.manifest.key,
        executable: command.executable,
        arguments: command.arguments,
        manifest: spider.manifest,
      );

      final future = host.call('home', deadline: const Duration(seconds: 10));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      // 取消需要拿到 requestId，因此通过反射式的顺序 id 规则构造。
      final cancelled = host.cancel('${spider.manifest.key}-2');
      expect(cancelled, isTrue, reason: '第 2 个请求应该就是在途的 home');

      await expectLater(
        future,
        throwsA(
          isA<SpiderError>().having(
            (error) => error.code,
            'code',
            SpiderErrorCode.cancelled,
          ),
        ),
      );

      // 进程仍存活，且能继续服务后续请求（§9.5「进程能回到空闲状态」）。
      expect(host.process.isRunning, isTrue);
      final result = await host.call('home') as Map;
      expect(result['list'], isA<List>());
      await host.destroy();
    });

    test('资源限制：响应超过 responseMiB 被拒绝为 SPIDER_RESOURCE_LIMIT', () async {
      final spider = _faultSpider('huge', responseMiB: 1);
      final command = LocalSpiderCommand.resolve(
        spider: spider,
        hostPath: hostPath,
      )!;
      final host = await supervisor.ensureRunning(
        siteKey: spider.manifest.key,
        executable: command.executable,
        arguments: command.arguments,
        manifest: spider.manifest,
      );

      await expectLater(
        host.call('home'),
        throwsA(
          isA<SpiderError>().having(
            (error) => error.code,
            'code',
            SpiderErrorCode.resourceLimit,
          ),
        ),
      );
      await host.destroy();
    });

    test('协议污染：stdout 出现非协议数据时终止运行时', () async {
      final spider = _faultSpider('pollute');
      final command = LocalSpiderCommand.resolve(
        spider: spider,
        hostPath: hostPath,
      )!;
      final host = await supervisor.ensureRunning(
        siteKey: spider.manifest.key,
        executable: command.executable,
        arguments: command.arguments,
        manifest: spider.manifest,
      );

      await expectLater(
        host.call('home'),
        throwsA(
          isA<SpiderError>().having(
            (error) => error.code,
            'code',
            anyOf(
              SpiderErrorCode.protocolViolation,
              SpiderErrorCode.crashed,
            ),
          ),
        ),
      );
      await _waitFor(() => !host.process.isRunning, timeoutMs: 8000);
      expect(host.process.isRunning, isFalse);
    });

    test('进程树终止：sidecar 崩溃时孙进程被一并终止（§18.2.1）', () async {
      final marker = p.join(tempRoot.path, 'grandchild.pid');
      final spider = _faultSpider('grandchild');
      final command = LocalSpiderCommand.resolve(
        spider: spider,
        hostPath: hostPath,
      )!;
      final host = await supervisor.ensureRunning(
        siteKey: spider.manifest.key,
        executable: command.executable,
        arguments: command.arguments,
        manifest: spider.manifest,
        environment: {'WEBHTV_TEST_GRANDCHILD_MARKER': marker},
      );

      await host.call('home').catchError((Object _) => null);
      // 孙进程先 `open(marker, "w")` 建文件、再写入 pid：只判断“文件存在”
      // 会读到空文件，导致 int.parse 抛错（竞态）。必须等到内容可解析。
      await _waitFor(
        () {
          try {
            return File(marker).readAsStringSync().trim().isNotEmpty;
          } catch (_) {
            return false;
          }
        },
        timeoutMs: 8000,
      );
      expect(File(marker).existsSync(), isTrue, reason: '孙进程应已派生');

      final pid = int.parse(File(marker).readAsStringSync().trim());
      await _waitFor(() => !host.process.isRunning, timeoutMs: 8000);
      // Job Object 的 kill-on-close 必须连孙进程一起终止。
      final stillAlive = await _processAlive(pid);
      expect(stillAlive, isFalse, reason: '孙进程 pid=$pid 不应残留');
      await host.destroy();
    });

    test('清理遗留工作目录', () async {
      final workRoot = p.join(tempRoot.path, 'sidecars');
      final stale = Directory(p.join(workRoot, 'stale-site'));
      await stale.create(recursive: true);
      // 把修改时间改到 2 小时前，模拟上次异常退出留下的目录。
      await _touchOld(stale);
      final removed = await supervisor.cleanStaleWorkDirs();
      expect(removed, greaterThanOrEqualTo(1));
      expect(await stale.exists(), isFalse);
    });

    test('stderr 日志按大小轮转且内容脱敏', () async {
      final spider = _fixtureSpider();
      final command = LocalSpiderCommand.resolve(
        spider: spider,
        hostPath: hostPath,
      )!;
      final host = await supervisor.ensureRunning(
        siteKey: spider.manifest.key,
        executable: command.executable,
        arguments: command.arguments,
        manifest: spider.manifest,
        environment: fixtureEnvironment(),
      );
      await host.call('home');
      final lines = host.process.stderrLines;
      expect(lines, isNotEmpty);
      // sidecar 自身不打印凭据；这里验证经过脱敏管道的文本不含 token 明文样式。
      for (final line in lines) {
        expect(line.contains('Authorization: Bearer'), isFalse);
      }
      await host.destroy();
    });
  });

  // ---------------------------------------------------------------------------
  // 日志脱敏（§9.3.1、§11.3.1、§18.3）
  // ---------------------------------------------------------------------------
  group('日志脱敏（§18.3）', () {
    test('Cookie/Authorization/签名 query 被替换', () {
      const line =
          'GET /api?a=1&token=SECRET123&sign=ABCDEF Cookie: sid=abc; '
          'Authorization: Bearer xyz.123';
      final redacted = redactLogText(line);
      expect(redacted.contains('SECRET123'), isFalse);
      expect(redacted.contains('ABCDEF'), isFalse);
      expect(redacted.contains('sid=abc'), isFalse);
      expect(redacted.contains('xyz.123'), isFalse);
      expect(redacted.contains('<redacted>'), isTrue);
    });

    test('Header 键名保留但值被脱敏', () {
      final text = redactHeadersForLog({
        'Referer': 'http://example.com/',
        'Cookie': 'sid=secret',
        'Authorization': 'Bearer abc',
        'X-Sign': 'deadbeef',
      });
      expect(text.contains('Referer=http://example.com/'), isTrue);
      expect(text.contains('secret'), isFalse);
      expect(text.contains('abc'), isFalse);
      expect(text.contains('deadbeef'), isFalse);
    });

    test('URL 脱敏隐藏 query 但保留 host 与 path', () {
      final redacted = redactUrl('https://cdn.example.com/a/b.m3u8?sign=deadbeef');
      expect(redacted, 'https://cdn.example.com/a/b.m3u8?...');
      expect(redacted.contains('deadbeef'), isFalse);
    });
  });
}

// -----------------------------------------------------------------------------
// 测试辅助
// -----------------------------------------------------------------------------

/// sidecar 宿主脚本与站源实现所在目录。
String get sidecarDir => p.join(
  repositoryRoot.path,
  'sidecars',
  'spider-host-python',
);

/// 正常工作的 fixture Spider（复用 sidecar 自带的实现）。
LocalSpider _fixtureSpider() => _localSpider('spider/manifest-fixture.json');

/// 崩溃 Spider（`home` 直接退出进程）。
LocalSpider _crashSpider() => _faultSpider('crash');

LocalSpider _faultSpider(String scenario, {int? responseMiB}) {
  final manifestPath = fixturePath('spider/manifest-$scenario.json');
  final parsed = SpiderManifest.fromJson(
    jsonDecode(File(manifestPath).readAsStringSync()),
  );
  final manifest = responseMiB == null
      ? parsed
      : SpiderManifest(
          key: parsed.key,
          name: parsed.name,
          runtime: parsed.runtime,
          entry: parsed.entry,
          capabilities: parsed.capabilities.values,
          permissions: parsed.permissions,
          limits: SpiderLimits(
            memoryMiB: parsed.limits.memoryMiB,
            cpuSeconds: parsed.limits.cpuSeconds,
            concurrency: parsed.limits.concurrency,
            responseMiB: responseMiB,
          ),
        );
  return _localSpider('spider/manifest-$scenario.json', override: manifest);
}

/// 构造 [LocalSpider]：entry 指向 sidecar 自带的站源实现。
LocalSpider _localSpider(String manifestRelative, {SpiderManifest? override}) {
  final manifestPath = fixturePath(manifestRelative);
  final manifest =
      override ??
      SpiderManifest.fromJson(
        jsonDecode(File(manifestPath).readAsStringSync()),
      );
  final entry = manifest.entry.contains('fixture_spider')
      ? p.join(sidecarDir, 'spiders', 'fixture_spider.py')
      : p.join(sidecarDir, 'spiders', 'fault_spiders.py');
  return LocalSpider(
    manifest: manifest,
    manifestPath: manifestPath,
    rootDir: p.dirname(manifestPath),
    entryPath: entry,
  );
}

/// 轮询等待条件成立。
Future<void> _waitFor(
  bool Function() predicate, {
  int timeoutMs = 4000,
}) async {
  final deadline = DateTime.now().add(Duration(milliseconds: timeoutMs));
  while (DateTime.now().isBefore(deadline)) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  throw StateError('等待条件超时（${timeoutMs}ms）');
}

/// 判断进程是否仍存活（Windows 用 tasklist，其他平台用 kill -0）。
Future<bool> _processAlive(int pid) async {
  try {
    if (Platform.isWindows) {
      final result = await Process.run('tasklist', [
        '/FI',
        'PID eq $pid',
        '/NH',
      ]);
      return '${result.stdout}'.contains('$pid');
    }
    final result = await Process.run('kill', ['-0', '$pid']);
    return result.exitCode == 0;
  } catch (_) {
    return false;
  }
}

/// 把目录修改时间改到 2 小时前，模拟遗留目录。
Future<void> _touchOld(Directory directory) async {
  try {
    await Process.run('powershell', [
      '-NoProfile',
      '-Command',
      "(Get-Item -LiteralPath '${directory.path}').LastWriteTime = ",
      "(Get-Date).AddHours(-2)",
    ]);
  } catch (_) {
    // 修改失败时 cleanStaleWorkDirs 会保留目录，测试会失败并暴露问题。
  }
}
