/// 加固壳解包 CLI 的**解析与失败映射**单测（不起 java、不联网、不起 ARM 模拟器）。
///
/// 覆盖点：
/// - 命令拼装：`java.arguments + -cp 解包运行时目录/* sidecar/shell-unpack/
///   ShellUnpack.java --shell … --out … --timeout 180`；
/// - stdout 最后一行 JSON 的解析（成功原样返回；失败保留 `stage`）；
/// - 契约外的输出（无 JSON / 空 stage / 抛异常 / 超时）一律兜底成 `ok:false` + 阶段，
///   且 `run` **永不抛**；
/// - 缺 unidbg 运行时或 JDK 17+ 时在 `emulator-启动` 阶段如实失败，不去起进程。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/shell_unpack.dart';
import 'package:webhtv_pc/services/spider_process.dart';
import 'package:webhtv_pc/services/spider_registry.dart';

void main() {
  late Directory tempRoot;
  late String sidecarHostPath;
  late LogService log;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('webhtv-shell-unpack');
    // sidecar 目录由 host.jar 的位置推导：<dir>/host.jar + <dir>/shell-unpack/ShellUnpack.java
    sidecarHostPath = p.join(tempRoot.path, 'spider-host-jvm', 'host.jar');
    File(sidecarHostPath)
      ..createSync(recursive: true)
      ..writeAsBytesSync(const [0x50, 0x4b, 0x03, 0x04]);
    File(p.join(p.dirname(sidecarHostPath), 'shell-unpack', 'ShellUnpack.java'))
      ..createSync(recursive: true)
      ..writeAsStringSync('// fixture');
    log = LogService();
  });

  tearDown(() async {
    try {
      await tempRoot.delete(recursive: true);
    } catch (_) {}
  });

  const classpath = r'C:\runtime\unidbg-0.9.9\*';

  /// 假 java：带一个 JVM 自有参数，用来断言它排在 `-cp` 之前。
  final javaProbe = JavaRuntimeProbe(
    command: const SidecarCommand(
      executable: 'java',
      arguments: ['-Xmx256m'],
    ),
    major: 21,
    hasCompiler: true,
  );

  Future<Map<String, Object?>> runWith(
    ShellUnpackRunner runner, {
    String? unidbgClasspath = classpath,
    JavaRuntimeProbe? probe,
    String? hostPath,
    void Function(ShellUnpackProgress)? onProgress,
  }) => ShellUnpack.run(
    shellJar: p.join(tempRoot.path, 'shell.jar'),
    outJar: p.join(tempRoot.path, 'payload.jar'),
    log: log,
    unidbgClasspath: unidbgClasspath,
    sidecarHostPath: hostPath ?? sidecarHostPath,
    javaProbe: probe ?? javaProbe,
    runner: runner,
    onProgress: onProgress,
  );

  /// 假 runner 的「stderr 推送器」：真进程逐行回调，假进程直接调同一个入口，
  /// 所以进度解析与 ETA 的数据流都能在不启 java 的前提下被验证。
  ShellUnpackRunner emitting(
    List<String> lines, {
    String stdout = '{"ok":true,"payload":"payload.jar","bytes":1}',
    int exitCode = 0,
  }) => (invocation) async {
    for (final line in lines) {
      invocation.onStderrLine?.call(line);
    }
    return ShellUnpackOutput(stdout: stdout, stderr: '', exitCode: exitCode);
  };

  test('命令按契约拼装：-cp 用 unidbg 通配符，源码模式跑 ShellUnpack.java', () async {
    ShellUnpackInvocation? seen;
    final result = await runWith((invocation) async {
      seen = invocation;
      return const ShellUnpackOutput(
        stdout:
            '{"ok":true,"payload":"payload.jar","sha256":"abc","bytes":12,"recipe":"wex","asset":"assets/wexshinidie.guard","elapsedMs":7}',
        stderr: 'unidbg 启动日志',
        exitCode: 0,
      );
    });

    expect(result['ok'], isTrue);
    expect(result['recipe'], 'wex');
    expect(seen, isNotNull);
    expect(seen!.executable, 'java');
    expect(seen!.arguments, [
      '-Xmx256m',
      '-cp',
      classpath,
      p.join(p.dirname(sidecarHostPath), 'shell-unpack', 'ShellUnpack.java'),
      '--shell',
      p.join(tempRoot.path, 'shell.jar'),
      '--out',
      p.join(tempRoot.path, 'payload.jar'),
      '--timeout',
      '180',
    ]);
    expect(seen!.timeout, const Duration(seconds: 180));
    expect(ShellUnpack.timeout.inSeconds, 180);
  });

  test('失败原样保留 stage：CLI 说卡在哪就报哪一阶段', () async {
    final result = await runWith(
      (_) async => const ShellUnpackOutput(
        stdout:
            '{"ok":false,"stage":"native-注册","message":"未找到 libwex.so"}',
        stderr: '',
        exitCode: 1,
      ),
    );

    expect(result['ok'], isFalse);
    expect(result['stage'], 'native-注册');
    expect(result['message'], contains('libwex.so'));
  });

  test('失败但没有 stage 时兜底为解包-调用（不让阶段为空）', () async {
    final result = await runWith(
      (_) async => const ShellUnpackOutput(
        stdout: '{"ok":false,"message":"炸了"}',
        stderr: '',
        exitCode: 1,
      ),
    );

    expect(result['ok'], isFalse);
    expect(result['stage'], ShellUnpack.stageInvoke);
  });

  test('stdout 没有 JSON 时绝不当成功：如实报退出码与前缀', () async {
    final result = await runWith(
      (_) async => const ShellUnpackOutput(
        stdout: 'Exception in thread "main" java.lang.IllegalStateException',
        stderr: '',
        exitCode: 1,
      ),
    );

    expect(result['ok'], isFalse);
    expect(result['stage'], ShellUnpack.stageInvoke);
    expect('${result['message']}', contains('exit=1'));
  });

  test('只看最后一行 JSON（前面的噪音行不影响结论）', () async {
    final result = await runWith(
      (_) async => const ShellUnpackOutput(
        stdout:
            'unidbg: loading libc\n{"ok":false,"stage":"payload-落盘","message":"磁盘满"}\n',
        stderr: '',
        exitCode: 1,
      ),
    );

    expect(result['ok'], isFalse);
    expect(result['stage'], 'payload-落盘');
  });

  test('超时不会抛出去：转成 解包-调用 阶段的结论', () async {
    final result = await runWith(
      (_) async => throw TimeoutException('超时', const Duration(seconds: 180)),
    );

    expect(result['ok'], isFalse);
    expect(result['stage'], ShellUnpack.stageInvoke);
    expect('${result['message']}', contains('超时'));
  });

  test('进程本身抛异常也不会抛出去（注入点纪律）', () async {
    final result = await runWith(
      (_) async => throw const ProcessException('java', ['-cp']),
    );

    expect(result['ok'], isFalse);
    expect(result['stage'], ShellUnpack.stageInvoke);
  });

  test('缺 unidbg 运行时：emulator-启动 阶段失败，且不起进程', () async {
    var calls = 0;
    final result = await runWith((invocation) async {
      calls++;
      return const ShellUnpackOutput(stdout: '', stderr: '', exitCode: 0);
    }, unidbgClasspath: '  ');

    expect(result['ok'], isFalse);
    expect(result['stage'], ShellUnpack.stageEmulator);
    expect(calls, 0, reason: '没有模拟器就没有可跑的命令，不能白起一次 java');
  });

  test('缺 JDK 17+：emulator-启动 阶段带原因，不抛异常', () async {
    final result = await runWith(
      (_) async => const ShellUnpackOutput(stdout: '', stderr: '', exitCode: 0),
      probe: const JavaRuntimeProbe(command: null, issue: '只找到 Java 8'),
    );

    expect(result['ok'], isFalse);
    expect(result['stage'], ShellUnpack.stageEmulator);
    expect('${result['message']}', contains('只找到 Java 8'));
  });

  test('sidecar 里没有 ShellUnpack.java 时如实报 解包-调用', () async {
    File(p.join(p.dirname(sidecarHostPath), 'shell-unpack', 'ShellUnpack.java'))
        .deleteSync();
    var calls = 0;
    final result = await runWith((invocation) async {
      calls++;
      return const ShellUnpackOutput(stdout: '', stderr: '', exitCode: 0);
    });

    expect(result['ok'], isFalse);
    expect(result['stage'], ShellUnpack.stageInvoke);
    expect('${result['message']}', contains('ShellUnpack.java'));
    expect(calls, 0);
  });

  test('进度行解析：七个阶段按权重换算成单调递增的 fraction', () async {
    final events = <ShellUnpackProgress>[];
    final lines = <String>[
      for (var i = 0; i < ShellUnpack.stages.length; i++)
        '[progress] $i/7 ${ShellUnpack.stages[i]}',
    ];
    final result = await runWith(emitting(lines), onProgress: events.add);

    expect(result['ok'], isTrue);
    expect(events.map((e) => e.stage).toList(), ShellUnpack.stages);
    expect(events.map((e) => e.stageIndex).toList(), [0, 1, 2, 3, 4, 5, 6]);
    expect(events.every((e) => e.stageCount == 7), isTrue);

    // 权重：读取 5 / 识别 5 / 模拟器启动 25 / 原生注册 15 / 解包调用 40 / 校验 5 / 落盘 5
    const expected = <double>[0.05, 0.10, 0.35, 0.50, 0.90, 0.95, 1.0];
    for (var i = 0; i < expected.length; i++) {
      expect(events[i].fraction, closeTo(expected[i], 1e-9));
    }
    for (var i = 1; i < events.length; i++) {
      expect(events[i].fraction, greaterThanOrEqualTo(events[i - 1].fraction));
    }
    // 首条进度不能是 0：ETA 用 elapsed / fraction，除零会让剩余时间直接崩。
    expect(events.first.fraction, greaterThan(0));
  });

  test('onProgress 由 stderr 实时驱动，人类日志行不会被当成进度', () async {
    final events = <ShellUnpackProgress>[];
    Future<ShellUnpackOutput> runner(ShellUnpackInvocation invocation) async {
      invocation.onStderrLine?.call('unidbg: loading libc');
      invocation.onStderrLine?.call('[progress] 0/7 shell-读取');
      invocation.onStderrLine?.call('[shell-unpack] RegisterNatives proxyInvoke');
      invocation.onStderrLine?.call('[progress] 2/7 emulator-启动');
      return const ShellUnpackOutput(
        stdout: '{"ok":true,"bytes":1}',
        stderr: '',
        exitCode: 0,
      );
    }
    final result = await runWith(runner, onProgress: events.add);

    expect(result['ok'], isTrue);
    expect(events.map((e) => e.stage).toList(), ['shell-读取', 'emulator-启动']);
    // 人类日志照旧进日志尾部，进度行不进（否则真正有用的几行会被挤掉）。
    final logged = log.entries.map((e) => e.message).join();
    expect(logged, contains('unidbg: loading libc'));
    expect(logged, contains('RegisterNatives proxyInvoke'));
    expect(logged, isNot(contains('[progress] ')));
  });

  test('乱序进度行原样上报：解析层不做单调裁剪（平滑留给 UI/ETA）', () async {
    final events = <ShellUnpackProgress>[];
    final result = await runWith(
      emitting([
        '[progress] 3/7 native-注册',
        '[progress] 1/7 recipe-识别',
      ]),
      onProgress: events.add,
    );

    expect(result['ok'], isTrue);
    expect(events.map((e) => e.stage).toList(), ['native-注册', 'recipe-识别']);
    expect(events.map((e) => e.stageIndex).toList(), [3, 1]);
    expect(events[0].fraction, closeTo(0.50, 1e-9));
    expect(events[1].fraction, closeTo(0.10, 1e-9));
  });

  test('未知阶段容忍：名字原样保留、顺带序号兜底，序号越界才丢弃', () async {
    final events = <ShellUnpackProgress>[];
    final result = await runWith(
      emitting([
        '[progress] 2/7 shell-新配方阶段',
        '[progress] 9/7 越界阶段',
        '[progress] -1/7 负数阶段',
      ]),
      onProgress: events.add,
    );

    expect(result['ok'], isTrue);
    expect(events, hasLength(1));
    expect(events.single.stage, 'shell-新配方阶段');
    expect(events.single.stageIndex, 2);
    expect(events.single.fraction, closeTo(0.35, 1e-9));
  });

  test('序号与名字矛盾时以名字为准（名字才是契约词表）', () async {
    final events = <ShellUnpackProgress>[];
    final result = await runWith(
      emitting(['[progress] 5/7 shell-读取']),
      onProgress: events.add,
    );

    expect(result['ok'], isTrue);
    expect(events.single.stageIndex, 0);
    expect(events.single.fraction, closeTo(0.05, 1e-9));
  });

  test('缺字段 / 分母不是 7 的进度行只当普通日志，不影响结论', () async {
    final events = <ShellUnpackProgress>[];
    final result = await runWith(
      emitting([
        '[progress]',
        '[progress] 3/7',
        '[progress] native-注册',
        '[progress] 2/9 native-注册',
        '[progress] x/7 native-注册',
      ]),
      onProgress: events.add,
    );

    expect(result['ok'], isTrue);
    expect(events, isEmpty);
    // 坏行不许被静默吞掉：它们要留在日志尾部，否则排错时无从下手。
    final logged = log.entries.map((e) => e.message).join();
    expect(logged, contains('[progress] 2/9 native-注册'));
    expect(logged, contains('[progress] x/7 native-注册'));
  });

  test('进度回调自己抛异常也不影响 run()（解析失败不改结论）', () async {
    var calls = 0;
    final result = await runWith(
      emitting([
        '[progress] 0/7 shell-读取',
        '[progress] 1/7 recipe-识别',
      ]),
      onProgress: (_) {
        calls++;
        throw StateError('UI 侧炸了');
      },
    );

    expect(calls, 2);
    expect(result['ok'], isTrue);
    expect(result['bytes'], 1);
  });

  test('进度行与失败结论并存：失败照旧如实报阶段', () async {
    var events = <ShellUnpackProgress>[];
    final result = await runWith(
      emitting(
        [
          '[progress] 0/7 shell-读取',
          '[progress] 2/7 emulator-启动',
        ],
        stdout: '{"ok":false,"stage":"emulator-启动","message":"没有 unidbg"}',
        exitCode: 1,
      ),
      onProgress: events.add,
    );

    expect(result['ok'], isFalse);
    expect(result['stage'], 'emulator-启动');
    expect(events.map((e) => e.stage).toList(), ['shell-读取', 'emulator-启动']);
  });

  test('stderr 只取尾部，且不影响 JSON 结论', () async {
    final noisy = List<String>.filled(ShellUnpack.stderrTailChars, '日志').join();
    final result = await runWith(
      (_) async => ShellUnpackOutput(
        stdout: jsonEncode({'ok': true, 'bytes': 1}),
        stderr: noisy,
        exitCode: 0,
      ),
    );

    expect(result['ok'], isTrue);
    expect(ShellUnpack.stderrTailChars, 2000);
  });
}
