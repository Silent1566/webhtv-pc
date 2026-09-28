/// Windows 进程隔离原语（设计文档 §9.8、§18.2.1）。
///
/// 设计文档要求「每个站点必须设置内存、CPU 时间、超时和并发限制」「Spider 崩溃只
/// 影响该站点」，并要求先**实测** Restricted Token / AppContainer / Job Object /
/// 子进程树终止的实际效果，无法可靠隔离时必须标记为「尽力隔离」。
///
/// 本文件只用 Job Object 做两件可验证的事：
/// 1. `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` + `TerminateJobObject`：可靠终止**整个
///    子进程树**，避免 sidecar 再启动的孙进程残留。
/// 2. `JOB_OBJECT_LIMIT_PROCESS_MEMORY` / `JOB_OBJECT_LIMIT_JOB_TIME`：内存与用户
///    CPU 时间上限，超限时由内核直接终止进程。
///
/// Job Object **不提供**文件系统或网络沙箱，因此本文件不会宣称强隔离；实际隔离
/// 等级由 [ProcessIsolationReport] 如实上报，并写入验收证据。
///
/// 非 Windows 平台没有等价实现时会返回 null，调用方退化为「仅进程隔离」。
library;

import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart' show calloc;

/// 实际生效的隔离机制与范围（§18.2.1 要求如实标记）。
class ProcessIsolationReport {
  const ProcessIsolationReport({
    required this.platform,
    required this.level,
    required this.mechanisms,
    required this.limitations,
  });

  final String platform;

  /// `job-object`、`process-only`。
  final String level;

  /// 实际生效的机制清单。
  final List<String> mechanisms;

  /// 明确的能力边界，禁止宣称超出实际效果的隔离。
  final List<String> limitations;

  /// 是否能够可靠终止整个子进程树。
  bool get canTerminateTree => mechanisms.contains('job-object:kill-on-close');

  String get summary =>
      'platform=$platform level=$level mechanisms=${mechanisms.join("+")} '
      'limitations=${limitations.join("; ")}';

  static const ProcessIsolationReport bestEffortOnly = ProcessIsolationReport(
    platform: 'unknown',
    level: 'process-only',
    mechanisms: ['process:terminate'],
    limitations: [
      '无法阻止 sidecar 读取同一用户可访问的文件或访问网络',
      '无法可靠终止 sidecar 自行派生的孙进程',
    ],
  );
}

/// Windows Job Object 封装。
///
/// 创建失败（例如宿主本身处于不允许嵌套的 Job 中）时返回 null，调用方必须
/// 退化为 [ProcessIsolationReport.bestEffortOnly]，不得静默宣称已隔离。
class WindowsJobObject {
  WindowsJobObject._(this._handle, this._report);

  final int _handle;
  ProcessIsolationReport _report;
  bool _disposed = false;

  ProcessIsolationReport get report => _report;

  static ffi.DynamicLibrary? _kernel32;

  /// 常量：来自 Windows SDK `winnt.h`。
  static const int _jobObjectExtendedLimitInformation = 9;
  static const int _limitJobTime = 0x00000004;
  static const int _limitProcessMemory = 0x00000100;
  static const int _limitJobMemory = 0x00000200;
  static const int _limitKillOnJobClose = 0x00002000;
  static const int _limitDieOnUnhandledException = 0x00000400;

  /// `JOBOBJECT_EXTENDED_LIMIT_INFORMATION` 在 x64 上为 144 字节。
  static const int _extendedLimitSize = 144;
  static const int _basicLimitFlagsOffset = 16;
  static const int _perJobUserTimeLimitOffset = 8;
  static const int _processMemoryLimitOffset = 112;
  static const int _jobMemoryLimitOffset = 120;

  static WindowsJobObject? create({
    required int memoryBytes,
    required int cpuSeconds,
  }) {
    if (!Platform.isWindows) return null;
    try {
      final kernel32 = _kernel32 ??= ffi.DynamicLibrary.open('kernel32.dll');
      final create = kernel32.lookupFunction<
        ffi.IntPtr Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>),
        int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>)
      >('CreateJobObjectW');
      final handle = create(ffi.nullptr, ffi.nullptr);
      if (handle == 0) return null;

      final setInfo = kernel32.lookupFunction<
        ffi.Int32 Function(
          ffi.IntPtr,
          ffi.Int32,
          ffi.Pointer<ffi.Void>,
          ffi.Uint32
        ),
        int Function(int, int, ffi.Pointer<ffi.Void>, int)
      >('SetInformationJobObject');

      final buffer = calloc<ffi.Uint8>(_extendedLimitSize);
      try {
        final bytes = buffer.asTypedList(_extendedLimitSize);
        final data = ByteData.view(bytes.buffer, bytes.offsetInBytes);
        data.setUint32(
          _basicLimitFlagsOffset,
          _limitKillOnJobClose |
              _limitDieOnUnhandledException |
              _limitProcessMemory |
              _limitJobMemory |
              _limitJobTime,
          Endian.little,
        );
        // 100ns 单位；只统计作业内进程的用户态 CPU 时间。
        data.setUint64(
          _perJobUserTimeLimitOffset,
          cpuSeconds * 10000000,
          Endian.little,
        );
        data.setUint64(
          _processMemoryLimitOffset,
          memoryBytes,
          Endian.little,
        );
        data.setUint64(_jobMemoryLimitOffset, memoryBytes, Endian.little);

        final ok = setInfo(
          handle,
          _jobObjectExtendedLimitInformation,
          buffer.cast<ffi.Void>(),
          _extendedLimitSize,
        );
        if (ok == 0) {
          _closeRaw(kernel32, handle);
          return null;
        }
      } finally {
        calloc.free(buffer);
      }

      return WindowsJobObject._(
        handle,
        ProcessIsolationReport(
          platform: 'windows',
          level: 'job-object(limits)',
          mechanisms: [
            'job-object:kill-on-close',
            'job-object:process-memory-limit',
            'job-object:cpu-time-limit',
          ],
          limitations: [
            '不提供文件系统沙箱：sidecar 仍可读取同一用户可访问的文件',
            '不提供网络沙箱：sidecar 仍可发起任意出站连接',
          ],
        ),
      );
    } catch (_) {
      return null;
    }
  }

  /// 把已启动的子进程加入作业。失败时作业的终止能力也随之失效。
  bool assign(int processId) {
    if (_disposed || processId <= 0) return false;
    try {
      final kernel32 = _kernel32!;
      final openProcess = kernel32.lookupFunction<
        ffi.IntPtr Function(ffi.Uint32, ffi.Int32, ffi.Uint32),
        int Function(int, int, int)
      >('OpenProcess');
      const processSetQuota = 0x0100;
      const processTerminate = 0x0001;
      final processHandle = openProcess(
        processSetQuota | processTerminate,
        0,
        processId,
      );
      if (processHandle == 0) return false;

      try {
        final assign = kernel32.lookupFunction<
          ffi.Int32 Function(ffi.IntPtr, ffi.IntPtr),
          int Function(int, int)
        >('AssignProcessToJobObject');
        final ok = assign(_handle, processHandle);
        if (ok == 0) {
          _degrade('job-object:assign 失败，已退化为仅进程终止');
          return false;
        }
      } finally {
        _closeRaw(kernel32, processHandle);
      }
      return true;
    } catch (_) {
      _degrade('job-object:assign 异常，已退化为仅进程终止');
      return false;
    }
  }

  void _degrade(String reason) {
    _report = ProcessIsolationReport(
      platform: 'windows',
      level: 'process-only',
      mechanisms: const ['process:terminate'],
      limitations: [
        reason,
        '无法阻止 sidecar 读取同一用户可访问的文件或访问网络',
        '无法可靠终止 sidecar 自行派生的孙进程',
      ],
    );
  }

  /// 终止作业内全部进程（含孙进程）。
  bool terminate() {
    if (_disposed) return false;
    try {
      final kernel32 = _kernel32!;
      final terminate = kernel32.lookupFunction<
        ffi.Int32 Function(ffi.IntPtr, ffi.Uint32),
        int Function(int, int)
      >('TerminateJobObject');
      return terminate(_handle, 1) != 0;
    } catch (_) {
      return false;
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final kernel32 = _kernel32;
    if (kernel32 == null) return;
    _closeRaw(kernel32, _handle);
  }

  static void _closeRaw(ffi.DynamicLibrary kernel32, int handle) {
    try {
      final close = kernel32.lookupFunction<
        ffi.Int32 Function(ffi.IntPtr),
        int Function(int)
      >('CloseHandle');
      close(handle);
    } catch (_) {
      // 关闭失败不影响主流程。
    }
  }
}

/// 宿主传给 sidecar 的环境变量白名单（§9.8「不得继承宿主的完整环境变量」）。
///
/// 只保留进程启动本身必需的变量；凭据、代理配置、开发机 PATH 扩展一律不传递。
abstract final class SidecarEnvironment {
  static const List<String> whitelist = [
    'SystemRoot',
    'SystemDrive',
    'windir',
    'ComSpec',
    'PATHEXT',
    'TEMP',
    'TMP',
    'NUMBER_OF_PROCESSORS',
    'PROCESSOR_ARCHITECTURE',
    'OS',
    'LANG',
    'LC_ALL',
    'LC_NUMERIC',
  ];

  /// 构造白名单环境。`PATH` 只保留系统目录，避免把宿主开发机的可执行文件
  /// 暴露给 sidecar。
  static Map<String, String> build({
    Map<String, String> extra = const {},
    bool includePath = true,
  }) {
    final source = Platform.environment;
    final result = <String, String>{};
    for (final name in whitelist) {
      final value = source[name] ?? _caseInsensitive(source, name);
      if (value != null && value.isNotEmpty) result[name] = value;
    }
    if (includePath) {
      final systemRoot = result['SystemRoot'] ?? '';
      final systemDrive = result['SystemDrive'] ?? 'C:';
      final path = Platform.isWindows
          ? [
              if (systemRoot.isNotEmpty) '$systemRoot\\system32',
              if (systemRoot.isNotEmpty) systemRoot,
              '$systemDrive\\Windows\\system32\\WindowsPowerShell\\v1.0',
            ].join(';')
          : '/usr/local/bin:/usr/bin:/bin';
      result['PATH'] = path;
    }
    result.addAll(extra);
    return result;
  }

  static String? _caseInsensitive(Map<String, String> source, String name) {
    final lowered = name.toLowerCase();
    for (final entry in source.entries) {
      if (entry.key.toLowerCase() == lowered) return entry.value;
    }
    return null;
  }

  /// 用于测试与诊断：判断给定环境是否满足白名单约束。
  static bool isWhitelisted(Map<String, String> environment) {
    final allowed = {
      ...whitelist.map((name) => name.toLowerCase()),
      'path',
      'pathext',
    };
    return environment.keys.every((key) => allowed.contains(key.toLowerCase()));
  }
}
