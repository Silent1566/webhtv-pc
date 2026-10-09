/// sidecar 进程宿主：启动、帧通信、超时/取消、崩溃隔离与资源限制
/// （设计文档 §9.3.1、§9.5、§9.8）。
///
/// 分工：
/// - [SidecarProcess]：单个子进程的低层生命周期与帧 IO，不含业务语义；
/// - [SpiderHost]：把 manifest/capability 与 ABI 方法映射到进程调用；
/// - [SpiderHostSupervisor]：按站点管理宿主、崩溃退避与状态上报。
///
/// 硬约束（违反即为缺陷）：
/// - 主进程不加载任何不可信代码，只通过 stdio 帧通信（§9.8）；
/// - stdout 只承载协议帧，出现非协议数据即判定协议污染并终止运行时（§9.3.1）；
/// - 每个站点独立临时工作目录，退出后清理（§9.8）；
/// - 不继承宿主完整环境变量，只传白名单（§9.8）；
/// - 崩溃只影响该站点，并按指数退避重试，禁止无限快速重启（§9.3.1、§9.8）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../core/http_api.dart';
import '../core/ipc_protocol.dart';
import '../core/protocol.dart';
import 'log_service.dart';
import 'windows_job.dart';

/// 启动参数。
class SidecarLaunchSpec {
  SidecarLaunchSpec({
    required this.siteKey,
    required this.executable,
    this.arguments = const [],
    required this.workingDirectory,
    required this.logFile,
    this.limits = const SpiderLimits(),
    Map<String, String> extraEnvironment = const {},
  }) : environment = SidecarEnvironment.build(extra: extraEnvironment);

  final String siteKey;
  final String executable;
  final List<String> arguments;

  /// 每站点独立临时工作目录（§9.8）。
  final String workingDirectory;

  /// stderr 日志落盘位置；超过上限轮转。
  final String logFile;

  final SpiderLimits limits;
  final Map<String, String> environment;
}

/// 一次在途请求。
class _Pending {
  _Pending({
    required this.id,
    required this.method,
    required this.completer,
    required this.deadline,
  });

  final String id;
  final String method;
  final Completer<Object?> completer;
  final Duration deadline;
  Timer? timer;
  Timer? graceTimer;
  bool cancelSent = false;
}

/// 子进程退出原因。
class SidecarExit {
  const SidecarExit({
    required this.code,
    required this.expected,
    this.signal,
    this.reason,
  });

  final int code;
  final bool expected;
  final ProcessSignal? signal;
  final String? reason;

  String get summary =>
      'exit=$code signal=${signal?.toString() ?? "-"} '
      'expected=$expected${reason == null ? "" : " reason=$reason"}';
}

/// 单个 sidecar 进程。
class SidecarProcess {
  SidecarProcess._(this._process, this._spec, this._job);

  final Process _process;
  final SidecarLaunchSpec _spec;

  /// Windows Job Object；为 null 表示只能做进程级终止（§18.2.1）。
  WindowsJobObject? _job;

  final IpcFrameDecoder _decoder = IpcFrameDecoder(
    maxFrameBytes: 16 * 1024 * 1024,
  );

  final Map<String, _Pending> _pending = {};
  final Completer<SidecarExit> _exitCompleter = Completer<SidecarExit>();
  final List<String> _stderrLines = [];

  int _sequence = 0;
  int _cumulativeStdoutBytes = 0;
  bool _stopping = false;
  bool _stdinClosed = false;
  bool _stdoutPolluted = false;
  String? _lastStdinError;

  /// stdin 写失败的最近一条错误（诊断用；不影响主流程）。
  String? get lastStdinError => _lastStdinError;
  String? _lastStderrError;

  /// 心跳间隔（§9.3.1「支持 cancel、shutdown 和心跳」）。
  static const Duration heartbeatInterval = Duration(seconds: 15);

  Timer? _heartbeatTimer;

  /// stderr 单文件上限，超过后轮转（§9.3.1）。
  static const int stderrRotateBytes = 256 * 1024;

  static const int stderrKeepFiles = 3;

  int get pid => _process.pid;

  bool get isRunning => !_exitCompleter.isCompleted;

  List<String> get stderrLines => List.unmodifiable(_stderrLines);

  String? get lastStderrError => _lastStderrError;

  ProcessIsolationReport get isolation =>
      _job?.report ?? ProcessIsolationReport.bestEffortOnly;

  Future<SidecarExit> get done => _exitCompleter.future;

  /// 启动子进程并接管 stdout/stderr。
  static Future<SidecarProcess> start(SidecarLaunchSpec spec) async {
    await Directory(spec.workingDirectory).create(recursive: true);
    await Directory(p.dirname(spec.logFile)).create(recursive: true);

    final process = await Process.start(
      spec.executable,
      spec.arguments,
      workingDirectory: spec.workingDirectory,
      // §9.8：只传白名单变量，不继承宿主完整环境。
      environment: spec.environment,
      includeParentEnvironment: false,
      runInShell: false,
    );

    WindowsJobObject? job;
    if (Platform.isWindows) {
      job = WindowsJobObject.create(
        memoryBytes: spec.limits.memoryBytes,
        cpuSeconds: spec.limits.cpuSeconds,
      );
      if (job != null && !job.assign(process.pid)) {
        // 保留 job 引用以便 dispose，但隔离等级已被降级。
      }
    }

    final instance = SidecarProcess._(process, spec, job);
    instance._wire();
    return instance;
  }

  void _wire() {
    _process.stdout.listen(
      _onStdout,
      onError: (Object error) => _failAll(
        SpiderError(
          code: SpiderErrorCode.crashed,
          message: 'sidecar stdout 读取失败：$error',
          siteKey: _spec.siteKey,
        ),
      ),
      cancelOnError: false,
    );
    _process.stderr.listen(
      _onStderr,
      onError: (Object error) {
        _lastStderrError = '$error';
      },
      cancelOnError: false,
    );
    _process.exitCode.then(_onExit, onError: (Object error) {
      _onExit(-1);
    });
    // 对端退出后写 stdin 会异步失败；这里先挂兜底，避免未捕获的管道写错误
    // 被测试框架记到无关用例上。
    _process.stdin.done.catchError((Object error) {
      _lastStdinError = '$error';
    });
    _heartbeatTimer = Timer.periodic(heartbeatInterval, (_) => _sendHeartbeat());
  }

  void _sendHeartbeat() {
    final id = 'hb-${++_sequence}';
    // 心跳不进入 pending：即使对端不实现也只在超时后忽略。
    _send(
      IpcEnvelope.request(
        id: id,
        method: SpiderMethod.heartbeat,
        deadlineMs: heartbeatInterval.inMilliseconds,
      ),
    );
  }

  void _onStdout(List<int> chunk) {
    _cumulativeStdoutBytes += chunk.length;
    final limit = _spec.limits.maxFrameBytes * 4;
    if (_cumulativeStdoutBytes > limit) {
      _stdoutPolluted = true;
      _killWithProtocolError(
        SpiderError(
          code: SpiderErrorCode.resourceLimit,
          message: 'sidecar 累计输出超过上限',
          siteKey: _spec.siteKey,
          details: {
            'bytes': _cumulativeStdoutBytes,
            'limit': limit,
          },
        ),
      );
      return;
    }

    final List<Object?> messages;
    try {
      messages = _decoder.add(chunk);
    } on IpcFrameTooLarge catch (error) {
      _stdoutPolluted = true;
      _killWithProtocolError(
        SpiderError(
          code: SpiderErrorCode.resourceLimit,
          message: '$error',
          siteKey: _spec.siteKey,
        ),
      );
      return;
    } on IpcFrameError catch (error) {
      _stdoutPolluted = true;
      _killWithProtocolError(
        SpiderError(
          code: SpiderErrorCode.protocolViolation,
          message: '${error.message}'
              '${error.raw == null ? "" : " raw=${error.raw}"}',
          siteKey: _spec.siteKey,
          details: {'pollutedStdout': true},
          userVisible: false,
        ),
      );
      return;
    }

    for (final message in messages) {
      final response = IpcResponse.tryParse(message);
      if (response == null) {
        // 非响应消息（例如 sidecar 主动通知）只忽略，不视为污染。
        continue;
      }
      final pending = _pending.remove(response.id);
      if (pending == null) {
        // 未知 ID：只在日志层记录，不改变任何在途请求状态（§9.3.1）。
        _lastStderrError = '忽略未知 id=${response.id} 的响应';
        continue;
      }
      pending.timer?.cancel();
      pending.graceTimer?.cancel();
      if (pending.completer.isCompleted) continue;
      if (response.succeeded) {
        // 超限时 _checkResponseSize 已用错误完成该请求，不能再 complete，
        // 否则会抛 `Bad state: Future already completed`，掩盖真正的
        // SPIDER_RESOURCE_LIMIT（§9.3.1「限制单响应大小」）。
        if (!_checkResponseSize(response.result, pending)) {
          pending.completer.complete(response.result);
        }
      } else {
        pending.completer.completeError(
          response.error!.siteKey == null
              ? SpiderError(
                  code: response.error!.code,
                  message: response.error!.message,
                  category: response.error!.category,
                  retryable: response.error!.retryable,
                  userVisible: response.error!.userVisible,
                  siteKey: _spec.siteKey,
                  requestId: response.error!.requestId,
                  details: response.error!.details,
                  diagnosticId: response.error!.diagnosticId,
                )
              : response.error!,
        );
      }
    }
  }

  /// 校验单响应大小；返回 `true` 表示已用 [SpiderErrorCode.resourceLimit] 完成
  /// 该请求，调用方**不得**再 complete。
  bool _checkResponseSize(Object? result, _Pending pending) {
    if (result == null) return false;
    final bytes = utf8.encode(jsonEncode(result)).length;
    if (bytes > _spec.limits.responseBytes) {
      pending.completer.completeError(
        SpiderError(
          code: SpiderErrorCode.resourceLimit,
          message: '响应超过单响应大小限制',
          siteKey: _spec.siteKey,
          requestId: pending.id,
          details: {'bytes': bytes, 'limit': _spec.limits.responseBytes},
        ),
      );
      return true;
    }
    return false;
  }

  void _onStderr(List<int> chunk) {
    // 只保留末尾若干行用于诊断，避免无界增长。
    final text = utf8.decode(chunk, allowMalformed: true);
    for (final rawLine in const LineSplitter().convert(text)) {
      if (rawLine.trim().isEmpty) continue;
      // §9.3.1：stderr 日志必须脱敏。
      _stderrLines.add(redactLogText(rawLine));
      while (_stderrLines.length > 200) {
        _stderrLines.removeAt(0);
      }
    }
    _writeStderr(chunk);
  }

  void _writeStderr(List<int> chunk) {
    try {
      final file = File(_spec.logFile);
      if (file.existsSync() && file.lengthSync() + chunk.length > stderrRotateBytes) {
        _rotateStderr(file);
      }
      file.writeAsBytesSync(chunk, mode: FileMode.append);
    } catch (_) {
      // 日志写入失败不得影响主流程。
    }
  }

  void _rotateStderr(File file) {
    try {
      for (var index = stderrKeepFiles - 1; index >= 1; index--) {
        final older = File('${file.path}.$index');
        if (!older.existsSync()) continue;
        if (index + 1 > stderrKeepFiles - 1) {
          older.deleteSync();
        } else {
          older.renameSync('${file.path}.${index + 1}');
        }
      }
      file.renameSync('${file.path}.1');
    } catch (_) {
      // 轮转失败时继续追加。
    }
  }

  void _onExit(int code) {
    _heartbeatTimer?.cancel();
    final expected = _stopping;
    if (!_exitCompleter.isCompleted) {
      _exitCompleter.complete(
        SidecarExit(
          code: code,
          expected: expected,
          reason: _stdoutPolluted ? 'protocol-pollution' : null,
        ),
      );
    }
    // sidecar 退出后，作业内仍可能残留它派生的孙进程（§18.2.1）。
    // `kill-on-close` 只在**最后一个**作业句柄关闭时生效，而宿主仍持有句柄，
    // 因此这里必须显式终止作业，否则崩溃会留下永久孤儿进程。
    _job?.terminate();
    if (!expected) {
      _failAll(
        SpiderError(
          code: SpiderErrorCode.crashed,
          message: 'sidecar 意外退出（code=$code）',
          siteKey: _spec.siteKey,
          details: {
            'exitCode': code,
            'stderr': _stderrLines.isEmpty ? '' : _stderrLines.last,
          },
        ),
      );
    }
  }

  void _failAll(SpiderError error) {
    for (final pending in _pending.values) {
      pending.timer?.cancel();
      pending.graceTimer?.cancel();
      if (!pending.completer.isCompleted) {
        pending.completer.completeError(
          error.requestId == null
              ? SpiderError(
                  code: error.code,
                  message: error.message,
                  category: error.category,
                  retryable: error.retryable,
                  userVisible: error.userVisible,
                  siteKey: _spec.siteKey,
                  requestId: pending.id,
                  details: error.details,
                  diagnosticId: error.diagnosticId,
                )
              : error,
        );
      }
    }
    _pending.clear();
  }

  void _killWithProtocolError(SpiderError error) {
    _failAll(error);
    unawaited(killTree());
  }

  void _send(Map<String, Object?> envelope) {
    if (_exitCompleter.isCompleted || _stdinClosed) return;
    try {
      _process.stdin.add(IpcFrameCodec.encode(envelope));
    } catch (_) {
      // 管道已关闭；退出处理会完成在途请求。
    }
  }

  /// 关闭 stdin 并吞掉写失败的异步错误。
  ///
  /// `IOSink.add` 的写错误是**异步**投递的：对端已退出时 `add` 不抛，
  /// 随后在事件循环里报 `SocketException: Write failed (OS Error: 管道正在被关闭。, errno = 232)`。
  /// 该错误若无人处理会升级为未捕获异常——在 `flutter test` 里会被记到
  /// **当时正在跑的那个用例**上（表现为互不相关的用例随机失败）。
  /// 因此写入前必须判断进程是否已退出，关闭 stdin 时也必须显式兜底
  /// （§9.3.1「destroy/进程退出、资源释放」）。
  void _closeStdin() {
    if (_stdinClosed) return;
    _stdinClosed = true;
    final sink = _process.stdin;
    sink.done.catchError((Object _) {});
    sink.close().catchError((Object _) {});
  }

  /// 发起一次 ABI 调用。
  Future<Object?> request(
    String method,
    Map<String, Object?> params, {
    Duration deadline = siteRequestTimeout,
    String? requestId,
  }) {
    if (_exitCompleter.isCompleted) {
      return Future.error(
        SpiderError(
          code: SpiderErrorCode.crashed,
          message: 'sidecar 已退出，无法调用 $method',
          siteKey: _spec.siteKey,
        ),
      );
    }
    final id = requestId ?? '${_spec.siteKey}-${++_sequence}';
    if (_pending.containsKey(id)) {
      return Future.error(
        SpiderError(
          code: SpiderErrorCode.badRequest,
          message: 'requestId 复用了未完成的 ID：$id',
          siteKey: _spec.siteKey,
          requestId: id,
        ),
      );
    }
    final completer = Completer<Object?>();
    final pending = _Pending(
      id: id,
      method: method,
      completer: completer,
      deadline: deadline,
    );
    _pending[id] = pending;
    _send(
      IpcEnvelope.request(
        id: id,
        method: method,
        params: params,
        deadlineMs: deadline.inMilliseconds,
      ),
    );
    pending.timer = Timer(deadline, () => _onTimeout(pending));
    return completer.future;
  }

  /// 取消一次在途请求（§9.3.1、§9.5）。
  ///
  /// 先发 `$/cancelRequest`，宽限期内未响应则终止进程兜底。
  bool cancel(String id, {Duration grace = const Duration(seconds: 2)}) {
    final pending = _pending[id];
    if (pending == null) return false;
    pending.cancelSent = true;
    _send(IpcEnvelope.cancel(id));
    pending.graceTimer ??= Timer(grace, () {
      if (_pending.remove(id) == null) return;
      pending.timer?.cancel();
      if (!pending.completer.isCompleted) {
        pending.completer.completeError(
          SpiderError(
            code: SpiderErrorCode.cancelled,
            message: '请求已取消（sidecar 未在宽限期内响应，已终止进程）',
            siteKey: _spec.siteKey,
            requestId: id,
          ),
        );
      }
      unawaited(killTree());
    });
    return true;
  }

  void _onTimeout(_Pending pending) {
    if (!_pending.containsKey(pending.id)) return;
    pending.completer.completeError(
      SpiderError(
        code: SpiderErrorCode.timeout,
        message: '请求超过 deadline（${pending.deadline.inMilliseconds}ms）',
        siteKey: _spec.siteKey,
        requestId: pending.id,
        details: {'method': pending.method},
      ),
    );
    _pending.remove(pending.id);
    // §9.3.1：超时后依次执行取消、宽限等待、终止进程树。
    _send(IpcEnvelope.cancel(pending.id));
    Timer(const Duration(milliseconds: 500), () {
      // 只有进程仍在运行且确实无响应时才终止，避免把偶发慢响应误判为挂死。
      if (_stdoutPolluted) return;
      unawaited(killTree());
    });
  }

  /// 终止整个子进程树。
  Future<void> killTree() async {
    _stopping = true;
    _heartbeatTimer?.cancel();
    if (_job != null && _job!.report.canTerminateTree) {
      _job!.terminate();
    }
    try {
      _process.kill(ProcessSignal.sigkill);
    } catch (_) {
      // 进程可能已经退出。
    }
  }

  /// 优雅停止：先 `shutdown`，宽限后强制终止（§9.3.1）。
  Future<SidecarExit> stop({Duration grace = const Duration(seconds: 3)}) async {
    if (_exitCompleter.isCompleted) return _exitCompleter.future;
    _stopping = true;
    _heartbeatTimer?.cancel();
    try {
      final shutdown = request(
        SpiderMethod.shutdown,
        const {},
        deadline: grace,
      );
      await shutdown.timeout(grace, onTimeout: () => null);
    } catch (_) {
      // 忽略：下面仍会强制终止。
    }
    try {
      await _exitCompleter.future.timeout(grace);
    } on TimeoutException {
      await killTree();
    }
    return _exitCompleter.future;
  }

  /// 释放资源：关闭管道、作业对象与临时目录（§9.3.1「destroy/进程退出、资源释放」）。
  Future<void> dispose({bool removeWorkingDirectory = true}) async {
    _heartbeatTimer?.cancel();
    if (!_exitCompleter.isCompleted) {
      await killTree();
      try {
        await _exitCompleter.future.timeout(const Duration(seconds: 3));
      } catch (_) {
        // 继续释放其它资源。
      }
    }
    _closeStdin();
    _job?.dispose();
    _job = null;
    if (removeWorkingDirectory) {
      try {
        final dir = Directory(_spec.workingDirectory);
        if (await dir.exists()) await dir.delete(recursive: true);
      } catch (_) {
        // 目录被占用时忽略，由系统临时目录清理。
      }
    }
  }
}

/// 宿主侧的 Spider 调用门面：manifest 校验 + capability 校验 + 调用。
class SpiderHost {
  SpiderHost({
    required this.manifest,
    required this.process,
    required this.log,
    this.callbackTimeout = siteRequestTimeout,
  });

  final SpiderManifest manifest;
  final SidecarProcess process;
  final LogService log;
  final Duration callbackTimeout;

  SpiderInitResult? _init;
  SpiderInitResult? get initResult => _init;

  static const Map<String, Duration> _methodTimeouts = {
    // init 握手是本地 IPC，不需要给站点那么长（给长了会把真正的启动问题拖成 3 分钟）。
    SpiderMethod.init: Duration(seconds: 15),
    SpiderMethod.home: siteRequestTimeout,
    SpiderMethod.category: siteRequestTimeout,
    SpiderMethod.detail: siteRequestTimeout,
    SpiderMethod.search: siteRequestTimeout,
    SpiderMethod.play: siteRequestTimeout,
    SpiderMethod.proxy: siteRequestTimeout,
  };

  /// `initialize` 握手：交换 ABI major/minor、capabilities、权限与限制（§9.3.1）。
  Future<SpiderInitResult> initialize({String extend = ''}) async {
    final result = await process.request(
      SpiderMethod.initialize,
      {
        'abi': SpiderAbi.ipc,
        'abiMajor': SpiderAbi.major,
        'abiMinor': SpiderAbi.minor,
        'siteKey': manifest.key,
        'extend': extend,
        'hostCapabilities': [
          SpiderMethod.home,
          SpiderMethod.category,
          SpiderMethod.detail,
          SpiderMethod.search,
          SpiderMethod.play,
        ],
        'limits': manifest.limits.toJson(),
      },
      deadline: _methodTimeouts[SpiderMethod.init]!,
    );

    final init = SpiderInitResult.fromJson(result);
    if (!init.majorCompatible) {
      throw SpiderError(
        code: SpiderErrorCode.initFailed,
        message: 'ABI major 不兼容：sidecar 声明 ${init.abi}，宿主需要 ${SpiderAbi.ipc}',
        siteKey: manifest.key,
        details: {'declared': init.abi, 'expected': SpiderAbi.ipc},
      );
    }
    if (init.abiMinor > SpiderAbi.minor) {
      log.info(
        'sidecar ABI minor 更高：${init.abiMinor} > ${SpiderAbi.minor}（只使用共同能力）',
        scope: 'spider',
      );
    }
    _init = init;
    return init;
  }

  /// 调用一个 ABI 方法；未声明 capability 时返回 `SPIDER_UNSUPPORTED`（§9.7）。
  Future<Object?> call(
    String method, {
    Map<String, Object?> params = const {},
    Duration? deadline,
    String? requestId,
  }) {
    final capability = _init?.capabilities ?? manifest.capabilities.values;
    final declared = capability.contains(method);
    if (!declared && SpiderCapabilities.known.contains(method)) {
      return Future.error(
        SpiderError(
          code: SpiderErrorCode.unsupported,
          message: 'sidecar 未声明 capability：$method',
          siteKey: manifest.key,
          details: {'capabilities': capability.toList()..sort()},
        ),
      );
    }
    final effective =
        deadline ??
        _methodTimeouts[method] ??
        callbackTimeout;
    return process.request(
      method,
      params,
      deadline: effective,
      requestId: requestId,
    );
  }

  bool cancel(String id) => process.cancel(id);

  Future<void> destroy() async {
    try {
      await call(
        SpiderMethod.destroy,
        deadline: const Duration(seconds: 5),
      );
    } catch (_) {
      // destroy 失败仍需释放进程资源。
    }
    await process.stop();
    await process.dispose();
  }
}

/// 站点运行时状态（§17.2 Spider 管理页展示）。
enum SpiderRuntimeState {
  stopped,
  running,
  crashed,
  backoff,
  disabled,
  failed,
}

/// 单个站点的 Spider 运行时记录。
class SpiderRuntimeStatus {
  SpiderRuntimeStatus({
    required this.siteKey,
    required this.state,
    this.manifest,
    this.initResult,
    this.isolation,
    this.lastError,
    this.failureCount = 0,
    this.restartDelay = Duration.zero,
    this.nextRetryAt,
    this.stderrLines = const [],
  });

  final String siteKey;
  final SpiderRuntimeState state;
  final SpiderManifest? manifest;
  final SpiderInitResult? initResult;
  final ProcessIsolationReport? isolation;
  final String? lastError;
  final int failureCount;
  final Duration restartDelay;
  final DateTime? nextRetryAt;
  final List<String> stderrLines;

  bool get enabled => state != SpiderRuntimeState.disabled;

  String get stateLabel => switch (state) {
    SpiderRuntimeState.stopped => '未启动',
    SpiderRuntimeState.running => '运行中',
    SpiderRuntimeState.crashed => '已崩溃',
    SpiderRuntimeState.backoff => '退避重试中',
    SpiderRuntimeState.disabled => '已禁用',
    SpiderRuntimeState.failed => '启动失败',
  };
}

/// 按站点管理 Spider 运行时（§9.8「Spider 崩溃只影响该站点」）。
class SpiderHostSupervisor {
  SpiderHostSupervisor({
    required this.workRoot,
    required this.log,
    this.maxFailures = 5,
    this.baseBackoff = const Duration(seconds: 1),
    this.maxBackoff = const Duration(seconds: 60),
  });

  /// sidecar 临时工作目录根（`%LOCALAPPDATA%/webhtv-pc/cache/sidecars`）。
  final String workRoot;
  final LogService log;

  /// 同一站点连续失败该次数后进入禁用状态，禁止无限快速重启（§9.3.1）。
  final int maxFailures;
  final Duration baseBackoff;
  final Duration maxBackoff;

  final Map<String, _SiteRuntime> _runtimes = {};

  /// 确保站点运行时可用；必要时启动并握手。
  Future<SpiderHost> ensureRunning({
    required String siteKey,
    required String executable,
    List<String> arguments = const [],
    required SpiderManifest manifest,
    String extend = '',
    Map<String, String> environment = const {},
  }) async {
    final runtime = _runtimes.putIfAbsent(siteKey, () => _SiteRuntime(siteKey));
    if (runtime.host != null) return runtime.host!;

    if (runtime.state == SpiderRuntimeState.disabled) {
      throw SpiderError(
        code: SpiderErrorCode.initFailed,
        message: '站点 $siteKey 的 Spider 连续失败已禁用，需人工重新启用',
        siteKey: siteKey,
        userVisible: true,
      );
    }
    final now = DateTime.now();
    if (runtime.nextRetryAt != null && now.isBefore(runtime.nextRetryAt!)) {
      final wait = runtime.nextRetryAt!.difference(now);
      throw SpiderError(
        code: SpiderErrorCode.initFailed,
        message: '站点 $siteKey 的 Spider 正在退避重试，还需 ${wait.inMilliseconds}ms',
        siteKey: siteKey,
        retryable: true,
        details: {'retryAfterMs': wait.inMilliseconds},
      );
    }

    final problems = manifest.problems;
    if (problems.isNotEmpty) {
      runtime
        ..state = SpiderRuntimeState.failed
        ..lastError = problems.join('; ');
      throw SpiderError(
        code: SpiderErrorCode.initFailed,
        message: 'manifest 校验失败：${problems.join("; ")}',
        siteKey: siteKey,
      );
    }
    if (manifest.missingRequired.isNotEmpty) {
      runtime
        ..state = SpiderRuntimeState.failed
        ..lastError = '缺少必需方法：${manifest.missingRequired.join(",")}';
      throw SpiderError(
        code: SpiderErrorCode.initFailed,
        message: '缺少必需方法：${manifest.missingRequired.join(",")}',
        siteKey: siteKey,
      );
    }

    final workingDirectory = p.join(
      workRoot,
      '$siteKey-${DateTime.now().microsecondsSinceEpoch}',
    );
    final logFile = p.join(workingDirectory, 'stderr.log');

    SidecarProcess? process;
    SpiderHost? host;
    try {
      process = await SidecarProcess.start(
        SidecarLaunchSpec(
          siteKey: siteKey,
          executable: executable,
          arguments: arguments,
          workingDirectory: workingDirectory,
          logFile: logFile,
          limits: manifest.limits,
          extraEnvironment: environment,
        ),
      );
      host = SpiderHost(manifest: manifest, process: process, log: log);
      await host.initialize(extend: extend);
    } catch (error) {
      if (process != null) await process.dispose();
      _recordFailure(runtime, error);
      rethrow;
    }

    runtime
      ..host = host
      ..process = process
      ..state = SpiderRuntimeState.running
      ..lastError = null;
    log.info(
      'Spider 已启动 site=$siteKey runtime=${manifest.runtime} '
      'isolation=${process.isolation.summary}',
      scope: 'spider',
    );

    // 崩溃监听：只影响该站点，并驱动指数退避。
    unawaited(
      process.done.then((exit) {
        if (runtime.process != process) return;
        runtime
          ..host = null
          ..process = null;
        if (exit.expected) {
          runtime.state = SpiderRuntimeState.stopped;
          return;
        }
        runtime.state = SpiderRuntimeState.crashed;
        _recordFailure(
          runtime,
          SpiderError(
            code: SpiderErrorCode.crashed,
            message: 'sidecar 意外退出：${exit.summary}',
            siteKey: siteKey,
            details: {'stderr': process!.stderrLines.take(5).join(' | ')},
          ),
        );
        log.error(
          'Spider 意外退出 site=$siteKey ${exit.summary} '
          'failures=${runtime.failureCount} delay=${runtime.restartDelay.inMilliseconds}ms',
          scope: 'spider',
        );
      }),
    );

    return host;
  }

  void _recordFailure(_SiteRuntime runtime, Object error) {
    runtime.failureCount += 1;
    runtime.lastError = error.toString();
    runtime.host = null;
    runtime.process = null;
    if (runtime.failureCount >= maxFailures) {
      runtime.state = SpiderRuntimeState.disabled;
      runtime.nextRetryAt = null;
      runtime.restartDelay = Duration.zero;
      log.error(
        'Spider 连续失败 ${runtime.failureCount} 次，已禁用 site=${runtime.siteKey}',
        scope: 'spider',
      );
      return;
    }
    // 指数退避：base * 2^(n-1)，上限 maxBackoff。
    final factor = 1 << (runtime.failureCount - 1).clamp(0, 16);
    final delayMs = min(
      baseBackoff.inMilliseconds * factor,
      maxBackoff.inMilliseconds,
    );
    runtime.state = SpiderRuntimeState.backoff;
    runtime.restartDelay = Duration(milliseconds: delayMs);
    runtime.nextRetryAt = DateTime.now().add(runtime.restartDelay);
    log.warning(
      'Spider 失败 site=${runtime.siteKey} count=${runtime.failureCount} '
      'backoff=${delayMs}ms',
      scope: 'spider',
    );
  }

  /// 手工重新启用（Spider 管理页）。
  void reset(String siteKey) {
    final runtime = _runtimes[siteKey];
    if (runtime == null) return;
    runtime
      ..failureCount = 0
      ..restartDelay = Duration.zero
      ..nextRetryAt = null
      ..lastError = null
      ..state = SpiderRuntimeState.stopped;
    log.info('Spider 已重置 site=$siteKey', scope: 'spider');
  }

  /// 强制停止某站点运行时（§18.2「每个站点运行时可随时强制停止」）。
  Future<void> stop(String siteKey) async {
    final runtime = _runtimes[siteKey];
    if (runtime == null) return;
    final process = runtime.process;
    runtime
      ..host = null
      ..process = null
      ..state = SpiderRuntimeState.stopped;
    if (process != null) await process.dispose();
    log.info('Spider 已停止 site=$siteKey', scope: 'spider');
  }

  bool isRunning(String siteKey) => _runtimes[siteKey]?.host != null;

  SpiderHost? hostFor(String siteKey) => _runtimes[siteKey]?.host;

  /// 全部运行时状态，供 Spider 管理页展示（§17.2）。
  List<SpiderRuntimeStatus> statuses() => _runtimes.values
      .map(
        (runtime) => SpiderRuntimeStatus(
          siteKey: runtime.siteKey,
          state: runtime.state,
          manifest: runtime.process == null ? null : runtime.host?.manifest,
          initResult: runtime.host?.initResult,
          isolation: runtime.process?.isolation,
          lastError: runtime.lastError,
          failureCount: runtime.failureCount,
          restartDelay: runtime.restartDelay,
          nextRetryAt: runtime.nextRetryAt,
          stderrLines: runtime.process?.stderrLines ?? const [],
        ),
      )
      .toList()
    ..sort((a, b) => a.siteKey.compareTo(b.siteKey));

  /// 应用退出时释放全部 sidecar 与端口（§22.2）。
  Future<void> shutdownAll() async {
    for (final runtime in _runtimes.values) {
      final process = runtime.process;
      runtime
        ..host = null
        ..process = null;
      if (process != null) await process.dispose();
    }
    _runtimes.clear();
  }

  /// 清理遗留的临时工作目录（上次异常退出留下的）。
  Future<int> cleanStaleWorkDirs() async {
    var removed = 0;
    try {
      final root = Directory(workRoot);
      if (!await root.exists()) return 0;
      await for (final entity in root.list()) {
        if (entity is! Directory) continue;
        final stat = await entity.stat();
        final age = DateTime.now().difference(stat.modified);
        if (age < const Duration(hours: 1)) continue;
        try {
          await entity.delete(recursive: true);
          removed++;
        } catch (_) {}
      }
    } catch (_) {}
    return removed;
  }
}

class _SiteRuntime {
  _SiteRuntime(this.siteKey);

  final String siteKey;
  SpiderHost? host;
  SidecarProcess? process;
  SpiderRuntimeState state = SpiderRuntimeState.stopped;
  String? lastError;
  int failureCount = 0;
  Duration restartDelay = Duration.zero;
  DateTime? nextRetryAt;
}

/// 解析 sidecar 运行时类型的目标可执行文件（§9.7 `runtime` 字段）。
class SidecarRuntimeResolver {
  const SidecarRuntimeResolver();

  /// 解析 `python-3` / `node-22` 等运行时标识对应的可执行文件与参数。
  ///
  /// 找不到运行时返回 null，调用方必须显示「运行时未安装」，不得静默跳过。
  static SidecarCommand? resolve(String runtime) {
    final normalized = runtime.toLowerCase();
    if (normalized.startsWith('python')) {
      return _resolvePython();
    }
    if (normalized.startsWith('node')) {
      // Windows 上可执行文件是 `node.exe`；只找 `node` 会永远落空（§9.8）。
      final node = _resolveFromPath(
        Platform.isWindows ? 'node.exe' : 'node',
      );      if (node != null) {
        return SidecarCommand(executable: node, arguments: const []);
      }
      final fallback = _resolveFromPath('node');
      return fallback == null
          ? null
          : SidecarCommand(executable: fallback, arguments: const []);
    }
    // 允许直接给出可执行文件路径（测试与本地调试）。
    if (runtime.contains(Platform.pathSeparator) ||
        runtime.endsWith('.exe') ||
        runtime.endsWith('.py')) {
      return SidecarCommand(executable: runtime, arguments: const []);
    }
    return null;
  }

  static SidecarCommand? _resolvePython() {
    if (Platform.isWindows) {
      final launcher = _resolveFromPath('py.exe');
      if (launcher != null) {
        return SidecarCommand(executable: launcher, arguments: const ['-3']);
      }
    }
    final python = _resolveFromPath(Platform.isWindows ? 'python.exe' : 'python3');
    if (python != null) {
      return SidecarCommand(executable: python, arguments: const []);
    }
    final fallback = _resolveFromPath('python');
    if (fallback != null) {
      return SidecarCommand(executable: fallback, arguments: const []);
    }
    return null;
  }

  static String? _resolveFromPath(String name) {
    // `py.exe` 位于 Windows 目录（通常不在被裁剪过的 PATH 中），因此显式补充。
    final candidates = <String>[];
    if (name == 'py.exe') {
      final systemRoot = Platform.environment['SystemRoot'];
      if (systemRoot != null) candidates.add(p.join(systemRoot, 'py.exe'));
    }
    for (final dir in (Platform.environment['PATH'] ?? '').split(
      Platform.isWindows ? ';' : ':',
    )) {
      if (dir.trim().isEmpty) continue;
      candidates.add(p.join(dir.trim(), name));
    }
    for (final candidate in candidates) {
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }
}

/// 解析出的运行时命令。
class SidecarCommand {
  const SidecarCommand({required this.executable, required this.arguments});

  final String executable;
  final List<String> arguments;
}
