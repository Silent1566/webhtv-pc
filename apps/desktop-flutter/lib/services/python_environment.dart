import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'app_paths.dart';
import 'spider_process.dart';
import 'python_runtime_provision.dart' show venvPythonPath, managedPythonRoot;

part 'python_bundle_store.dart';

enum PythonEnvironmentSource { bundled, custom, system, missing }

class PythonEnvironmentStatus {
  const PythonEnvironmentStatus({
    this.executable = '',
    this.version = '',
    this.source = PythonEnvironmentSource.missing,
    this.dependencies = const {},
    this.error,
  });
  final String executable;
  final String version;
  final PythonEnvironmentSource source;
  final Map<String, bool> dependencies;
  final String? error;
  bool get ready =>
      executable.isNotEmpty &&
      version.isNotEmpty &&
      source != PythonEnvironmentSource.missing &&
      error == null &&
      const [
        'requests',
        'Crypto',
        'lxml',
        'bs4',
      ].every((m) => dependencies[m] == true);
}

typedef PythonEnvironmentProbe = FutureOr<PythonEnvironmentStatus> Function(
  String executable,
  List<String> arguments,
  PythonEnvironmentSource source,
  Map<String, String>? environment,
);

class PythonEnvironment {
  PythonEnvironment({
    required this.paths,
    this.bundleDirectory,
    this.probe,
    this.systemCandidates,
    this.processEnvironment,
    this.launcherRunner,
    this.clock,
    this.launcherTimeout = const Duration(seconds: 5),
  });
  final AppPaths paths;
  final String? bundleDirectory;
  final PythonEnvironmentProbe? probe;
  final List<String>? systemCandidates;
  final Map<String, String>? processEnvironment;
  final Future<ProcessResult> Function(String, List<String>)? launcherRunner;
  final Duration launcherTimeout;
  final DateTime Function()? clock;
  PythonEnvironmentStatus? status;
  List<String> arguments = const [];
  bool busy = false;
  String? error;
  Future<bool>? _pending;
  SendPort? _cancellation;
  bool _closed = false;

  static bool _changing = false;
  static int _users = 0;
  static Map<String, String>? _launchEnvironment;
  static Map<String, String> sidecarEnvironment(Map<String, String> base) => {
    ...base,
    ...?_launchEnvironment,
  };

  /// Acquired before the first asynchronous launch step, released only on exit.
  static void acquireSidecar() {
    if (_changing) throw StateError('Python 环境正在准备/切换，请稍后启动源');
    _users++;
  }

  static void releaseSidecar() {
    if (_users > 0) _users--;
  }

  Future<void> get idle async {
    await _pending;
  }

  Future<void> close() async {
    _closed = true;
    _cancellation?.send(null);
    await idle;
  }

  Future<void> refresh() async {
    final pending = _pending;
    if (pending != null) {
      await pending;
      return;
    }
    await _run('refresh');
  }

  Future<bool> repair() => _run('repair');
  Future<bool> setCustom(String executable) =>
      _run('custom', executable.trim());
  Future<bool> useDefault() => _run('default');

  Future<bool> _run(String operation, [String executable = '']) {
    if (_closed) {
      error = const _PythonEnvironmentCancelled().toString();
      return Future.value(false);
    }
    if (busy || _changing || (operation != 'refresh' && _users > 0)) {
      error = _users > 0 ? 'Python 源正在运行，请先停止后再修复或切换' : 'Python 环境操作正在进行';
      return Future.value(false);
    }
    // A refresh may inspect an in-use environment, but must not replace it.
    final allowPrepare = _users == 0;
    busy = true;
    _changing = true;
    error = null;
    final data = paths.dataDir;
    final config = paths.configDir;
    final cache = paths.cacheDir;
    final bundle = bundleDirectory;
    final checker = probe;
    final candidates = systemCandidates;
    final environment = processEnvironment;
    final launcher = launcherRunner;
    final launcherLimit = launcherTimeout;
    final writeStamp = clock?.call().microsecondsSinceEpoch;
    final control = ReceivePort();
    final subscription = control.listen((message) {
      _cancellation = message as SendPort;
      if (_closed) _cancellation!.send(null);
    });
    final future =
        _operateEnvironment(
              operation,
              executable,
              data,
              config,
              cache,
              bundle,
              checker,
              candidates,
              environment,
              allowPrepare,
              launcher,
              launcherLimit,
              writeStamp,
              control.sendPort,
            )
            .then(
              (result) {
                if (_closed) {
                  error =
                      result.error ??
                      const _PythonEnvironmentCancelled().toString();
                  return false;
                }
                if (result.status != null) {
                  status = result.status;
                  arguments = result.arguments;
                  _launchEnvironment = environment == null
                      ? null
                      : Map.unmodifiable({
                          for (final key in const [
                            'PATH',
                            'SystemRoot',
                            'TEMP',
                            'TMP',
                          ])
                            if (environment.containsKey(key))
                              key: environment[key]!,
                        });
                }
                error = result.error;
                return result.error == null;
              },
              onError: (Object failure, StackTrace stack) {
                error = '$failure';
                return false;
              },
            )
            .whenComplete(() async {
              _cancellation = null;
              control.close();
              await subscription.cancel();
              busy = false;
              _changing = false;
              _pending = null;
            });
    _pending = future;
    return future;
  }
}

class _EnvironmentResult {
  const _EnvironmentResult(
    this.status, {
    this.arguments = const [],
    this.error,
  });
  final PythonEnvironmentStatus? status;
  final List<String> arguments;
  final String? error;
}

class _PythonEnvironmentCancelled implements Exception {
  const _PythonEnvironmentCancelled();

  @override
  String toString() => 'Python 环境准备已取消';
}

class _PythonPreparation {
  bool cancelled = false;
  final Set<Process> _processes = {};
  Timer? _escalation;

  /// 取消时的宽限窗：先 SIGTERM 让进程自己收尾，超过这个时间才升级 SIGKILL。
  ///
  /// 这个窗口只用于**升级信号**，不是 idle 的完成条件——收尾处仍然要等到真实
  /// exitCode，否则「关闭完成」就可能是假的。
  static const _killGrace = Duration(seconds: 2);

  void cancel() {
    cancelled = true;
    for (final process in _processes.toList()) {
      _terminate(process);
    }
  }

  void _terminate(Process process) {
    try {
      process.kill();
    } catch (_) {
      // 已退出：下面的 exitCode 会立即完成。
    }
    if (Platform.isWindows) return;
    _escalation?.cancel();
    _escalation = Timer(_killGrace, () {
      for (final tracked in _processes.toList()) {
        try {
          tracked.kill(ProcessSignal.sigkill);
        } catch (_) {
          // 竞态退出。
        }
      }
    });
  }

  void check() {
    if (cancelled) throw const _PythonEnvironmentCancelled();
  }

  Future<void> checkpoint() async {
    await Future<void>.delayed(Duration.zero);
    check();
  }

  void track(Process process) {
    _processes.add(process);
    if (cancelled) _terminate(process);
  }

  void release(Process process) {
    _processes.remove(process);
    if (_processes.isEmpty) {
      _escalation?.cancel();
      _escalation = null;
    }
  }
}

/// 停止一个探测/启动子进程：先 SIGTERM 给一个宽限窗，必要时升级 SIGKILL，
/// 但**最终仍要等到真实 exitCode**。
///
/// 为什么需要宽限窗：POSIX 上自建/系统解释器的包装脚本可能忽略 SIGTERM，不升级
/// 就会把取消后的收尾挂住（实测过：dispose 后 10 秒仍在解包/等进程）。
/// 为什么最终不能「超时就放弃等待」：idle 的唯一证据是子进程真的退出；用超时
/// 替代它，等于把「关闭完成」变成假完成（本轮复审打回的正是那种写法）。
Future<void> _stopProcess(Process process) async {
  try {
    process.kill();
  } catch (_) {
    // 进程可能已经退出；继续等待 exitCode 即可。
  }
  if (await _waitProcessExit(process, const Duration(seconds: 2))) return;
  // SIGKILL 不能被忽略：发出去之后必须等到 exitCode，否则「idle 完成」就会
  // 变成「可能还有子进程在跑」的假证据。这里的无界等待由 SIGKILL 的语义兜底，
  // 不是原先那种「关着眼睛放弃等待」。
  if (!Platform.isWindows) {
    try {
      process.kill(ProcessSignal.sigkill);
    } catch (_) {
      // 竞态退出：下面的 exitCode 会立即完成。
    }
  }
  await process.exitCode;
}

Future<bool> _waitProcessExit(Process process, Duration limit) async {
  try {
    await process.exitCode.timeout(limit);
    return true;
  } on TimeoutException {
    return false;
  }
}

Future<PythonEnvironmentStatus> _probePython(
  String executable,
  List<String> arguments,
  PythonEnvironmentSource source,
  Map<String, String>? environment,
  _PythonPreparation preparation,
) async {
  Process? process;
  try {
    preparation.check();
    process = await Process.start(
      executable,
      [
        ...arguments,
        if (source == PythonEnvironmentSource.bundled) '-I',
        '-B',
        '-c',
        'import sys,json,importlib; ms=["requests","Crypto","lxml","bs4"]; d={}; '
            '\nfor m in ms:\n try: importlib.import_module(m); d[m]=True\n except Exception: d[m]=False\n'
            'print(json.dumps({"version":".".join(map(str,sys.version_info[:3])),"dependencies":d}))',
      ],
      environment: environment,
      includeParentEnvironment: environment == null,
    );
    preparation.track(process);
    final output =
        await Future.wait<Object>([
          process.exitCode,
          _readProbeOutput(process.stdout, process),
          _readProbeOutput(process.stderr, process),
        ]).timeout(
          const Duration(seconds: 30),
          onTimeout: () {
            process?.kill();
            throw TimeoutException('Python 探测超过 30 秒');
          },
        );
    preparation.check();
    if (output[0] != 0) throw StateError('${output[2]}'.trim());
    final payload = jsonDecode('${output[1]}'.trim()) as Map<String, dynamic>;
    final dependencies = Map<String, bool>.from(payload['dependencies'] as Map);
    final version = payload['version'] as String;
    return PythonEnvironmentStatus(
      executable: executable,
      version: version,
      source: source,
      dependencies: Map.unmodifiable(dependencies),
      error: !version.startsWith('3.')
          ? '需要 Python 3'
          : dependencies.values.every((v) => v)
          ? null
          : '缺少 CatVod 依赖',
    );
  } catch (e) {
    preparation.check();
    return PythonEnvironmentStatus(
      executable: executable,
      source: source,
      error: '解释器探测失败：$e',
    );
  } finally {
    if (process != null) {
      await _stopProcess(process);
      preparation.release(process);
    }
  }
}

Future<_EnvironmentResult> _operateEnvironment(
  String operation,
  String executable,
  String data,
  String config,
  String cache,
  String? bundle,
  /// 测试注入的探测回调：按 **trusted/finite** 处理——它本身不可取消，必须自己
  /// 有限完成。生产实现只在回调返回后的 checkpoint 检查取消，因此中途不会打断它。
  PythonEnvironmentProbe? injectedProbe,
  List<String>? candidates,
  Map<String, String>? environment,
  bool allowPrepare,
  Future<ProcessResult> Function(String, List<String>)? launcherRunner,
  Duration launcherTimeout,
  int? writeStamp,
  SendPort control,
) => Isolate.run(() async {
  final preparation = _PythonPreparation();
  final cancellation = ReceivePort();
  final subscription = cancellation.listen((_) => preparation.cancel());
  control.send(cancellation.sendPort);
  Future<PythonEnvironmentStatus> probe(
    String executable,
    List<String> arguments,
    PythonEnvironmentSource source,
    Map<String, String>? environment,
  ) async {
    await preparation.checkpoint();
    final result = await (injectedProbe == null
        ? _probePython(executable, arguments, source, environment, preparation)
        : injectedProbe(executable, arguments, source, environment));
    await preparation.checkpoint();
    return result;
  }

  Future<ProcessResult> launcher(
    String executable,
    List<String> arguments,
  ) async {
    await preparation.checkpoint();
    if (launcherRunner != null) {
      // 同 injectedProbe：注入的启动器是 trusted/finite 测试钩子，不可中途取消。
      final result = await launcherRunner(executable, arguments);
      preparation.check();
      return result;
    }
    final process = await Process.start(executable, arguments);
    preparation.track(process);
    try {
      final output = await Future.wait<Object>([
        process.exitCode,
        process.stdout.transform(systemEncoding.decoder).join(),
        process.stderr.transform(systemEncoding.decoder).join(),
      ]).timeout(launcherTimeout);
      preparation.check();
      return ProcessResult(process.pid, output[0] as int, output[1], output[2]);
    } finally {
      await _stopProcess(process);
      preparation.release(process);
    }
  }

  try {
    return await _performEnvironment(
      operation,
      executable,
      data,
      config,
      cache,
      bundle,
      probe,
      candidates,
      environment,
      allowPrepare,
      launcher,
      launcherTimeout,
      writeStamp,
      preparation,
    );
  } finally {
    cancellation.close();
    await subscription.cancel();
  }
});

Future<_EnvironmentResult> _performEnvironment(
  String operation,
  String executable,
  String data,
  String config,
  String cache,
  String? bundleOverride,
  PythonEnvironmentProbe probe,
  List<String>? candidatesOverride,
  Map<String, String>? environment,
  bool allowPrepare,
  Future<ProcessResult> Function(String, List<String>)? launcherRunner,
  Duration launcherTimeout,
  int? writeStamp,
  _PythonPreparation preparation,
) async {
  try {
    preparation.check();
    final store = _PythonBundleStore(data, config, writeStamp: writeStamp);
    String? custom;
    var preferenceDamaged = false;
    try {
      custom = store.selection()['custom'] as String?;
    } catch (error) {
      preferenceDamaged = true;
      if (operation != 'custom' && operation != 'default') {
        throw StateError('Python 偏好损坏：$error；请恢复默认或重新选择自定义解释器（原文件保留）');
      }
    }
    if (operation == 'custom') {
      if (!p.isAbsolute(executable) || !File(executable).existsSync()) {
        throw StateError('请选择有效的 Python 可执行文件绝对路径');
      }
      final status = await probe(
        executable,
        const [],
        PythonEnvironmentSource.custom,
        environment,
      );
      if (!status.ready) throw StateError(status.error ?? '自定义 Python 未就绪');
      await preparation.checkpoint();
      store.saveSelection({'custom': executable}, recover: preferenceDamaged);
      return _EnvironmentResult(status);
    }
    String? bundleError;
    var installed = await store.installed(preparation);
    if (store.metadataError != null && operation == 'refresh') {
      return _EnvironmentResult(null, error: store.metadataError);
    }
    if (operation == 'repair' ||
        installed == null && (custom == null || operation == 'default')) {
      final directory = bundleOverride ?? _findPythonBundle();
      if (directory != null && allowPrepare) {
        try {
          installed = await store.prepare(
            directory,
            probe,
            environment,
            preparation,
          );
        } catch (e) {
          preparation.check();
          bundleError = '$e';
          if (operation != 'refresh') rethrow;
        }
      } else {
        bundleError = allowPrepare
            ? '未找到内置离线 Python 包（runtime/python）'
            : 'Python 源运行中，无法准备环境';
        if (operation != 'refresh') throw StateError(bundleError);
      }
    }
    if (custom != null && operation != 'default') {
      final status = await probe(
        custom,
        const [],
        PythonEnvironmentSource.custom,
        environment,
      );
      return _EnvironmentResult(status, error: bundleError);
    }
    if (installed != null) {
      final status = await probe(
        installed,
        const [],
        PythonEnvironmentSource.bundled,
        environment,
      );
      if (operation == 'default') {
        if (!status.ready) throw StateError(status.error ?? '内置环境未就绪，请离线修复');
        await preparation.checkpoint();
        store.saveSelection({}, recover: preferenceDamaged);
      }
      return _EnvironmentResult(status, error: bundleError);
    }
    final candidates =
        candidatesOverride?.map(
          (e) => SidecarCommand(executable: e, arguments: const []),
        ) ??
        [
          SidecarCommand(
            executable: venvPythonPath(managedPythonRoot(cache)),
            arguments: const [],
          ),
          ...await SidecarRuntimeResolver.pythonCandidatesAsync(
            launcherRunner: launcherRunner,
            launcherTimeout: launcherTimeout,
          ),
        ];
    PythonEnvironmentStatus? degraded;
    List<String> degradedArgs = const [];
    for (final command in candidates) {
      final status = await probe(
        command.executable,
        command.arguments,
        PythonEnvironmentSource.system,
        environment,
      );
      if (status.ready) {
        return _EnvironmentResult(
          status,
          arguments: command.arguments,
          error: bundleError,
        );
      }
      if (degraded == null && status.version.startsWith('3.')) {
        degraded = status;
        degradedArgs = command.arguments;
      }
    }
    return _EnvironmentResult(
      degraded ??
          PythonEnvironmentStatus(error: bundleError ?? '没有可用的 Python 环境'),
      arguments: degradedArgs,
      error: bundleError,
    );
  } catch (e) {
    return _EnvironmentResult(null, error: '$e');
  }
}

String? _findPythonBundle() {
  final override = Platform.environment['WEBHTV_PYTHON_BUNDLE_DIR']?.trim();
  if (override != null && override.isNotEmpty) return p.absolute(override);
  final roots = [
    p.dirname(Platform.resolvedExecutable),
    Directory.current.path,
  ];
  for (final root in roots) {
    var dir = Directory(root);
    for (var hop = 0; hop < 10; hop++) {
      final candidate = p.join(dir.path, 'runtime', 'python');
      if (File(p.join(candidate, 'bundle.json')).existsSync()) return candidate;
      if (dir.parent.path == dir.path) break;
      dir = dir.parent;
    }
  }
  return null;
}

Future<String> _readProbeOutput(
  Stream<List<int>> stream,
  Process process,
) async {
  final bytes = <int>[];
  await for (final chunk in stream) {
    if (bytes.length + chunk.length > 64 * 1024) {
      process.kill();
      throw StateError('Python 探测输出超过 64KiB');
    }
    bytes.addAll(chunk);
  }
  return utf8.decode(bytes, allowMalformed: true);
}
