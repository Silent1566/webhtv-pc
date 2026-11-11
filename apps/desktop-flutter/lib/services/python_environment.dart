import 'dart:async';
import 'dart:convert';
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
    final checker = probe ?? _probePython;
    final candidates = systemCandidates;
    final environment = processEnvironment;
    final launcher = launcherRunner;
    final launcherLimit = launcherTimeout;
    final writeStamp = clock?.call().microsecondsSinceEpoch;
    final future =
        Isolate.run(
              () => _operateEnvironment(
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
              ),
            )
            .then(
              (result) {
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
            .whenComplete(() {
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

Future<PythonEnvironmentStatus> _probePython(
  String executable,
  List<String> arguments,
  PythonEnvironmentSource source,
  Map<String, String>? environment,
) async {
  try {
    final process = await Process.start(
      executable,
      [
        ...arguments,
        '-B',
        '-c',
        'import sys,json,importlib; ms=["requests","Crypto","lxml","bs4"]; d={}; '
            '\nfor m in ms:\n try: importlib.import_module(m); d[m]=True\n except Exception: d[m]=False\n'
            'print(json.dumps({"version":".".join(map(str,sys.version_info[:3])),"dependencies":d}))',
      ],
      environment: environment,
      includeParentEnvironment: environment == null,
    );
    final output =
        await Future.wait<Object>([
          process.exitCode,
          _readProbeOutput(process.stdout, process),
          _readProbeOutput(process.stderr, process),
        ]).timeout(
          const Duration(seconds: 30),
          onTimeout: () {
            process.kill();
            throw TimeoutException('Python 探测超过 30 秒');
          },
        );
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
    return PythonEnvironmentStatus(
      executable: executable,
      source: source,
      error: '解释器探测失败：$e',
    );
  }
}

Future<_EnvironmentResult> _operateEnvironment(
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
) async {
  try {
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
      store.saveSelection({'custom': executable}, recover: preferenceDamaged);
      return _EnvironmentResult(status);
    }
    String? bundleError;
    var installed = store.installed();
    if (store.metadataError != null && operation == 'refresh') {
      return _EnvironmentResult(null, error: store.metadataError);
    }
    if (operation == 'repair' ||
        installed == null && (custom == null || operation == 'default')) {
      final directory = bundleOverride ?? _findPythonBundle();
      if (directory != null && allowPrepare) {
        try {
          installed = await store.prepare(directory, probe, environment);
        } catch (e) {
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
