/// 确定性启动失败 vs 瞬时失败（退出码语义见 `sidecars/spider-host-jvm/README.md`）。
///
/// 退出码：`0` 正常；`2` 协议/manifest/入口非法；`3` 站源初始化失败。
/// 2 和 3 都是**确定性**的（同样的入口下次还会同样失败），必须直接进 failed、
/// 不进退避；超时/被 kill/没有明确退出码仍然退避重试。
///
/// 为什么不启真 java：退出码语义是宿主侧的事，与 JVM 无关。这里用 node 起一个
/// 「记一行启动标记就按给定退出码退出」的假 sidecar：不联网、不依赖 JDK，
/// 启动次数靠标记文件统计（比在 lib 里加计数器更接近真实观测）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/core/http_api.dart';
import 'package:webhtv_pc/core/ipc_protocol.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/node_runtime.dart';
import 'package:webhtv_pc/services/spider_process.dart';

void main() {
  group('退出码语义（sidecars/spider-host-jvm/README.md）', () {
    test('0 正常退出', () {
      expect(sidecarExitKind(0), SidecarExitKind.normal);
    });

    test('2/3 是确定性失败：同样的入口下次必然同样失败', () {
      expect(sidecarExitKind(2), SidecarExitKind.deterministic);
      expect(sidecarExitKind(3), SidecarExitKind.deterministic);
    });

    test('被 kill / 拿不到退出码 / 其它退出码仍是瞬时失败（保留退避重试）', () {
      expect(sidecarExitKind(1), SidecarExitKind.transient);
      expect(sidecarExitKind(9), SidecarExitKind.transient);
      expect(sidecarExitKind(-1), SidecarExitKind.transient);
      expect(sidecarExitKind(null), SidecarExitKind.transient);
    });
  });

  group('确定性失败文案：说原因，不说「崩溃」', () {
    test('exit=3 原样带出 stderr 里的异常类名', () {
      final message = deterministicExitMessage(3, [
        'host: loading entry',
        'java.lang.ClassNotFoundException: com.example.Site',
      ]);
      expect(
        message,
        '站源初始化失败：java.lang.ClassNotFoundException: com.example.Site',
      );
      expect(message, isNot(contains('意外退出')));
    });

    test('exit=3 且 stderr 为空', () {
      expect(deterministicExitMessage(3, const []), '站源初始化失败（无 stderr 输出）');
      // 只有空白行也等于没有输出。
      expect(
        deterministicExitMessage(3, const ['   ', '']),
        '站源初始化失败（无 stderr 输出）',
      );
    });

    test('exit=2 用协议/manifest 的说法，而不是站源初始化失败', () {
      final message = deterministicExitMessage(2, ['error: --entry 缺失']);
      expect(message, startsWith('协议或 manifest 非法：'));
      expect(message, contains('--entry 缺失'));
      expect(message, isNot(contains('意外退出')));
    });

    test('异常行优先于栈帧行，且过长时截断', () {
      final message = deterministicExitMessage(3, [
        'java.lang.UnsatisfiedLinkError: no webhtv in java.library.path',
        'at com.example.Native.<clinit>(Native.java:12)',
      ]);
      expect(message, contains('UnsatisfiedLinkError'));
      expect(message, isNot(contains('Native.java:12')));

      final long = deterministicExitMessage(3, [
        'Exception: ${List.filled(400, "x").join()}',
      ]);
      expect(long.length, lessThan(300));
      expect(long, endsWith('…'));
    });
  });

  group('崩溃文案：非 0 退出也带 stderr 尾部', () {
    test('exit=1 的文案挂上 stderr 关键行，不再只有退出码', () {
      expect(crashExitMessage(1, ['boom']), 'sidecar 意外退出（code=1）：boom');
    });

    test('stderr 为空时写明「无 stderr 输出」', () {
      expect(
        crashExitMessage(1, const []),
        'sidecar 意外退出（code=1）（无 stderr 输出）',
      );
      expect(
        crashExitMessage(7, const ['   ', '']),
        'sidecar 意外退出（code=7）（无 stderr 输出）',
      );
    });

    test('异常行优先于栈帧行，且不混用 2/3 的分类文案', () {
      final message = crashExitMessage(1, [
        'java.lang.OutOfMemoryError: Java heap space',
        'at com.example.Native.<clinit>(Native.java:12)',
      ]);
      expect(message, contains('OutOfMemoryError'));
      expect(message, isNot(contains('Native.java:12')));
      // 瞬时崩溃就是瞬时崩溃：不能借「站源初始化失败」的说法。
      expect(message, isNot(contains('站源初始化失败')));
      expect(message, isNot(contains('协议或 manifest 非法')));
    });
  });

  group('资源类死亡判定：集中在一处（isExternalTermination）', () {
    test('没有退出钩子 → 外部终止（作业对象/宿主把进程干掉）', () {
      expect(isExternalTermination(const []), isTrue);
      expect(isExternalTermination(['warning: dex2jar AIOOBE']), isTrue);
    });

    test('有退出钩子 → JVM 自己走到收尾，stderr 才是死因', () {
      expect(
        isExternalTermination(['[webhtv] 进程退出钩子：JVM 正在收尾退出', 'boom']),
        isFalse,
      );
    });

    test('os._exit(2/3) 同样没有钩子，但仍是站源自己选的退出码', () {
      // 这就是「不许改既有语义」的那条线：2/3 靠退出码排除，不靠钩子。
      expect(isResourceLimitTermination(2, const []), isFalse);
      expect(isResourceLimitTermination(3, const []), isFalse);
      expect(isResourceLimitTermination(0, const []), isFalse);
      expect(
        isResourceLimitTermination(1, const ['[webhtv] 进程退出钩子']),
        isFalse,
      );
    });

    test('exit=1/9 且没有钩子 → 资源类死亡', () {
      expect(isResourceLimitTermination(1, const []), isTrue);
      expect(isResourceLimitTermination(9, const ['boom']), isTrue);
    });

    test('可行动建议带出当前 manifest 的资源上限', () {
      expect(
        resourceLimitAdvice(512),
        '建议提高该站点的 limits.memoryMiB（当前 512）',
      );
      expect(resourceLimitAdvice(null), '建议提高该站点的 limits.memoryMiB');

      final message = externalTerminationMessage(512);
      expect(message, contains('外部终止'));
      expect(message, contains('limits.memoryMiB'));
      expect(message, contains('512'));
      // 崩溃前的最后一条告警只能当旁证：它不是死因（死因是外部终止）。
      expect(
        externalTerminationMessage(512, stderrLines: ['boom']),
        endsWith('；崩溃前最后一条告警=boom'),
      );
    });
  });

  group('SpiderHostSupervisor：2/3 不重试，其它仍退避', () {
    late Directory root;
    late String launchesFile;

    /// 假 sidecar 的启动参数：写一行启动标记，把 stderr 同步写出去，再按
    /// [code] 退出。stderr 用 `fs.writeSync` 而不是 `process.stderr.write`：
    /// 后者是异步的，`process.exit` 可能把最后一行截掉，用例会随机丢原因。
    List<String> fakeSidecar({
      required String marker,
      required int code,
      String stderr = '',
    }) => [
      '-e',
      'const fs = require("fs");'
          'fs.appendFileSync(${jsonEncode(marker)}, "launch\\n");'
          '${stderr.isEmpty ? '' : 'fs.writeSync(2, ${jsonEncode(stderr)});'}'
          'process.exit($code);',
    ];

    SpiderHostSupervisor supervisor({
      Duration baseBackoff = const Duration(milliseconds: 40),
    }) => SpiderHostSupervisor(
      workRoot: p.join(root.path, 'sidecars'),
      log: LogService(),
      baseBackoff: baseBackoff,
      maxBackoff: const Duration(milliseconds: 200),
      maxFailures: 3,
    );

    SpiderManifest fakeManifest(String key) => SpiderManifest.fromJson({
      'abi': SpiderAbi.ipc,
      'abiMinor': 0,
      'key': key,
      'name': key,
      'runtime': 'node-24',
      'entry': 'spiders/fake.js',
      'capabilities': ['home', 'category', 'detail', 'search', 'play'],
    });

    /// 统计真正启动过几次（每次启动写一行）。
    int launchCount() {
      final file = File(launchesFile);
      if (!file.existsSync()) return 0;
      return file
          .readAsLinesSync()
          .where((line) => line.trim().isNotEmpty)
          .length;
    }

    setUp(() async {
      root = await Directory.systemTemp.createTemp('webhtv-spider-retry');
      launchesFile = p.join(root.path, 'launches.log');
    });

    tearDown(() async {
      try {
        await root.delete(recursive: true);
      } catch (_) {}
    });

    test('exit=3：只启动一次、状态 failed、文案含 stderr 关键行', () async {
      final node = NodeRuntimeResolver.resolve();
      if (node == null) {
        markTestSkipped('本机没有可用的 node，跳过进程级用例');
        return;
      }
      final host = supervisor();
      addTearDown(host.shutdownAll);
      final manifest = fakeManifest('retry-exit3');
      final arguments = [
        ...node.arguments,
        ...fakeSidecar(
          marker: launchesFile,
          code: 3,
          stderr: 'java.lang.ClassNotFoundException: com.example.Site\n',
        ),
      ];

      Object? failure;
      try {
        await host.ensureRunning(
          siteKey: manifest.key,
          executable: node.executable,
          arguments: arguments,
          manifest: manifest,
        );
      } catch (error) {
        failure = error;
      }

      expect(failure, isA<SpiderError>());
      final error = failure! as SpiderError;
      // 文案：可解释的失败 + 唯一能行动的线索；不再说「意外退出」。
      expect(error.message, startsWith('站源初始化失败：'));
      expect(
        error.message,
        contains('ClassNotFoundException: com.example.Site'),
      );
      expect(error.message, isNot(contains('意外退出')));
      expect(error.message, isNot(contains('code=3')));
      // code 与 diagId 仍然保留，便于对日志。
      expect(error.code, SpiderErrorCode.initFailed);
      expect(error.details['exitCode'], 3);
      expect(error.diagnosticId, isNotEmpty);
      expect(error.retryable, isFalse);

      final status = host.statuses().single;
      expect(status.state, SpiderRuntimeState.failed);
      expect(status.nextRetryAt, isNull);
      expect(status.restartDelay, Duration.zero);
      expect(status.lastError, contains('ClassNotFoundException'));

      // 再拉一次：结论一样，且**不得再起进程**（这就是「不重试」）。
      await expectLater(
        host.ensureRunning(
          siteKey: manifest.key,
          executable: node.executable,
          arguments: arguments,
          manifest: manifest,
        ),
        throwsA(
          isA<SpiderError>()
              .having((error) => error.message, 'message', contains('站源初始化失败'))
              .having((error) => error.retryable, 'retryable', isFalse),
        ),
      );
      expect(launchCount(), 1);

      // 修好入口后走管理页「重置」才能重来：门闩必须被清掉。
      host.reset(manifest.key);
      expect(host.statuses().single.state, SpiderRuntimeState.stopped);
    });

    test('exit=2：同样不重试，文案是协议/manifest 非法', () async {
      final node = NodeRuntimeResolver.resolve();
      if (node == null) {
        markTestSkipped('本机没有可用的 node，跳过进程级用例');
        return;
      }
      final host = supervisor();
      addTearDown(host.shutdownAll);
      final manifest = fakeManifest('retry-exit2');
      final arguments = [
        ...node.arguments,
        ...fakeSidecar(
          marker: launchesFile,
          code: 2,
          stderr: 'error: manifest entry not readable\n',
        ),
      ];

      await expectLater(
        host.ensureRunning(
          siteKey: manifest.key,
          executable: node.executable,
          arguments: arguments,
          manifest: manifest,
        ),
        throwsA(
          isA<SpiderError>()
              .having(
                (error) => error.message,
                'message',
                startsWith('协议或 manifest 非法：'),
              )
              .having(
                (error) => error.message,
                'message',
                isNot(contains('意外退出')),
              )
              .having((error) => error.details['exitCode'], 'exitCode', 2),
        ),
      );
      expect(host.statuses().single.state, SpiderRuntimeState.failed);

      await expectLater(
        host.ensureRunning(
          siteKey: manifest.key,
          executable: node.executable,
          arguments: arguments,
          manifest: manifest,
        ),
        throwsA(isA<SpiderError>()),
      );
      expect(launchCount(), 1);
    });

    test('exit=1：没有 2/3 语义，仍然按退避重试', () async {
      final node = NodeRuntimeResolver.resolve();
      if (node == null) {
        markTestSkipped('本机没有可用的 node，跳过进程级用例');
        return;
      }
      final host = supervisor();
      addTearDown(host.shutdownAll);
      final manifest = fakeManifest('retry-exit1');
      final arguments = [
        ...node.arguments,
        // 带上进程内退出钩子：说明 JVM 自己走到了收尾，这时才允许把 stderr 里那条
        // 异常当死因（没有钩子 = 被作业对象/外部强制终止，文案要改成「外部终止」）。
        ...fakeSidecar(
          marker: launchesFile,
          code: 1,
          stderr: '[webhtv] 进程退出钩子：JVM 正在收尾退出\nboom\n',
        ),
      ];

      Future<void> attempt() => expectLater(
        host.ensureRunning(
          siteKey: manifest.key,
          executable: node.executable,
          arguments: arguments,
          manifest: manifest,
        ),
        throwsA(
          isA<SpiderError>()
              .having((error) => error.code, 'code', SpiderErrorCode.crashed)
              // 崩溃文案必须挂上 stderr 关键行：只有「（code=1）」等于让用户对着
              // 一个退出码猜。分类仍是 SPIDER_CRASHED（可退避重试）。
              .having(
                (error) => error.message,
                'message',
                'sidecar 意外退出（code=1）：boom',
              )
              .having((error) => error.diagnosticId, 'diagId', isNotEmpty),
        ),
      );

      await attempt();
      final first = host.statuses().single;
      expect(first.state, SpiderRuntimeState.backoff);
      expect(first.failureCount, 1);
      expect(first.restartDelay, greaterThan(Duration.zero));
      expect(first.nextRetryAt, isNotNull);
      expect(launchCount(), 1);

      // 退避窗口过去之后必须还会再起一次：瞬时失败的重试行为不变。
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await attempt();
      expect(launchCount(), 2);
      expect(host.statuses().single.failureCount, 2);
    });

    /// 带显式资源上限的 manifest：文案里要能读出「当前 512」。
    SpiderManifest limitedManifest(String key) => SpiderManifest.fromJson({
      'abi': SpiderAbi.ipc,
      'abiMinor': 0,
      'key': key,
      'name': key,
      'runtime': 'node-24',
      'entry': 'spiders/fake.js',
      'capabilities': ['home', 'category', 'detail', 'search', 'play'],
      'limits': {'memoryMiB': 512, 'cpuSeconds': 120},
    });

    test('无退出钩子的 exit=1：外部终止 → 只启动一次、failed、不可重试', () async {
      final node = NodeRuntimeResolver.resolve();
      if (node == null) {
        markTestSkipped('本机没有可用的 node，跳过进程级用例');
        return;
      }
      final host = supervisor();
      addTearDown(host.shutdownAll);
      final manifest = limitedManifest('retry-external-term');
      // 空 stderr 就是 257 MiB 峰值被杀时的真实观测：没有钩子，也没有任何 JVM 收尾输出。
      final arguments = [
        ...node.arguments,
        ...fakeSidecar(marker: launchesFile, code: 1),
      ];

      Object? failure;
      try {
        await host.ensureRunning(
          siteKey: manifest.key,
          executable: node.executable,
          arguments: arguments,
          manifest: manifest,
        );
      } catch (error) {
        failure = error;
      }

      final error = failure! as SpiderError;
      expect(error.message, contains('外部终止'));
      expect(error.message, contains('limits.memoryMiB'));
      expect(error.message, contains('512'), reason: '要读到当前 manifest 值');
      expect(error.retryable, isFalse);

      final status = host.statuses().single;
      expect(status.state, SpiderRuntimeState.failed);
      expect(status.nextRetryAt, isNull);
      expect(status.restartDelay, Duration.zero);
      expect(
        status.failureCount,
        0,
        reason: '资源类死亡不占「连续失败熔断」的预算',
      );

      // 再拉一次：结论一样，且**不得再起进程**（不重试）。
      await expectLater(
        host.ensureRunning(
          siteKey: manifest.key,
          executable: node.executable,
          arguments: arguments,
          manifest: manifest,
        ),
        throwsA(
          isA<SpiderError>()
              .having((error) => error.retryable, 'retryable', isFalse)
              .having(
                (error) => error.message,
                'message',
                contains('limits.memoryMiB'),
              ),
        ),
      );
      expect(launchCount(), 1);

      // 改好 manifest（抬高上限）后走管理页「重置」才能重来：门闩必须被清掉。
      host.reset(manifest.key);
      expect(host.statuses().single.state, SpiderRuntimeState.stopped);
    });
  });

  group('站点请求预算：play 独立 90s，其余不变', () {
    test('home/category/detail/proxy 的生效值是 30s', () {
      for (final method in [
        SpiderMethod.home,
        SpiderMethod.category,
        SpiderMethod.detail,
        SpiderMethod.proxy,
      ]) {
        expect(
          SpiderHost.declaredTimeout(method),
          const Duration(seconds: 30),
          reason:
              '$method 的兜底预算必须是 30s：15s 对镜像竞速太紧，180s 会把'
              '真正挂死的请求拖成白屏',
        );
      }
    });

    test('play 的默认预算是 90s', () {
      expect(
        SpiderHost.declaredTimeout(SpiderMethod.play),
        const Duration(seconds: 90),
      );
    });

    test('init 也是 30s（握手内含壳内现场转译，15s 会误判超时），search 本轮不动', () {
      // 依据：加固壳站点的站源对象在 initialize 里构造，壳内 DexNative 冷启动要现场
      // 转译载荷（实测 10.6 s / 1193 类）；15 s 会把健康的慢启动判成 SPIDER_TIMEOUT
      // （2026-11-21 用户日志 WexAiGuaZi / WexAiYueYue 就是这条）。
      expect(
        SpiderHost.declaredTimeout(SpiderMethod.init),
        const Duration(seconds: 30),
      );
      expect(
        SpiderHost.declaredTimeout(SpiderMethod.search),
        siteRequestTimeout,
      );
    });

    test('真实请求帧：play=90000，显式 deadline 优先，其他方法不变', () async {
      final node = NodeRuntimeResolver.resolve();
      if (node == null) {
        markTestSkipped('本机没有可用的 node，跳过进程级用例');
        return;
      }
      final root = await Directory.systemTemp.createTemp(
        'webhtv-spider-deadline',
      );
      addTearDown(() async {
        try {
          await root.delete(recursive: true);
        } catch (_) {}
      });
      final framesFile = p.join(root.path, 'frames.log');
      // 假 sidecar：只把收到的原始帧落盘，不回帧——用例只关心「发出去的是什么」，
      // 因此既不用等 30 秒，也不需要一套完整的 initialize 应答。
      const script =
          'const fs=require("fs");'
          'const out=fs.createWriteStream(process.argv[1]);'
          'process.stdin.on("data",(chunk)=>out.write(chunk));';
      final manifest = SpiderManifest.fromJson({
        'abi': SpiderAbi.ipc,
        'abiMinor': 0,
        'key': 'deadline-home',
        'name': 'deadline-home',
        'runtime': 'node-24',
        'entry': 'spiders/fake.js',
        'capabilities': [
          'home',
          'category',
          'detail',
          'proxy',
          'search',
          'play',
        ],
      });
      final process = await SidecarProcess.start(
        SidecarLaunchSpec(
          siteKey: manifest.key,
          executable: node.executable,
          arguments: [...node.arguments, '-e', script, framesFile],
          workingDirectory: root.path,
          logFile: p.join(root.path, 'stderr.log'),
        ),
      );
      addTearDown(process.dispose);
      final host = SpiderHost(
        manifest: manifest,
        process: process,
        log: LogService(),
      );

      // 不 await：帧发出后就不能等 30 秒的超时。
      final pending = <Future<void>>[];
      for (final (method, milliseconds) in [
        (SpiderMethod.play, 90000),
        (SpiderMethod.home, 30000),
        (SpiderMethod.category, 30000),
        (SpiderMethod.detail, 30000),
        (SpiderMethod.proxy, 30000),
        (SpiderMethod.search, 180000),
      ]) {
        pending.add(
          expectLater(
            host.call(method, requestId: method),
            throwsA(isA<SpiderError>()),
          ),
        );
        final frames = await _waitForText(framesFile, '"id":"$method"');
        final decoder = IpcFrameDecoder(maxFrameBytes: 1024 * 1024);
        final messages = decoder.add(utf8.encode(frames));
        final frame = messages.singleWhere(
          (frame) => (frame as Map)['id'] == method,
        );
        expect((frame as Map)['method'], method);
        expect(frame['deadlineMs'], milliseconds, reason: method);
      }
      pending.add(
        expectLater(
          host.call(
            SpiderMethod.play,
            deadline: const Duration(milliseconds: 12345),
            requestId: 'explicit',
          ),
          throwsA(isA<SpiderError>()),
        ),
      );
      final frames = await _waitForText(framesFile, '"id":"explicit"');
      final explicit = IpcFrameDecoder(maxFrameBytes: 1024 * 1024)
          .add(utf8.encode(frames))
          .singleWhere((frame) => (frame as Map)['id'] == 'explicit');
      expect((explicit as Map)['method'], 'play');
      expect(explicit['deadlineMs'], 12345);
      pending.add(expectLater(host.initialize(), throwsA(isA<SpiderError>())));
      final initFrames = await _waitForText(
        framesFile,
        '"method":"initialize"',
      );
      final init = IpcFrameDecoder(maxFrameBytes: 1024 * 1024)
          .add(utf8.encode(initFrames))
          .cast<Map>()
          .singleWhere((frame) => frame['method'] == 'initialize');
      expect(init['deadlineMs'], 30000);

      await process.killTree();
      await Future.wait(pending);
    });
  });
}

/// 轮询文件直到出现 [needle]，返回全文（找不到就失败）。
Future<String> _waitForText(
  String path,
  String needle, {
  int timeoutMs = 5000,
}) async {
  final deadline = DateTime.now().add(Duration(milliseconds: timeoutMs));
  while (DateTime.now().isBefore(deadline)) {
    final file = File(path);
    if (file.existsSync()) {
      final text = file.readAsStringSync();
      if (text.contains(needle)) return text;
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  throw StateError('等不到 $needle（$path）');
}
