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

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import '../core/http_api.dart';
import '../core/ipc_protocol.dart';
import '../core/protocol.dart';
import 'log_service.dart';
import 'node_runtime.dart';
import 'python_environment.dart';
import 'windows_job.dart';

/// 把不可信标识（manifest key、siteKey）净化成**单个**路径段。
///
/// 为什么必须有：siteKey 取自源包 manifest，属于不可信输入。直接
/// `p.join(root, siteKey)` 时，`../`、绝对路径或平台分隔符都能把结果拼到
/// `root` 之外；而 sidecar 工作目录随后会被 [SidecarProcess.dispose] 递归删除，
/// 拼错一次就是删掉别人的目录。缓存目录（`SpiderRegistry.directoryFor`）与
/// sidecar 工作目录现在共用这一份规则，不再各写一套。
///
/// 放在本文件而不是 spider_registry.dart：registry 已经 import 本文件，
/// 反向 import 会形成循环依赖。
String sanitizePathSegment(String value) {
  final sanitized = value.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
  // `.` / `..` 不含被替换字符却仍能穿出父目录，空串则会让 join 退化成父目录本身；
  // 二者都是「净化后依然危险」的名字，单独兜底。
  if (sanitized.isEmpty || sanitized == '.' || sanitized == '..') return '_';
  return sanitized;
}

/// 启动参数。
class SidecarLaunchSpec {
  SidecarLaunchSpec({
    required this.siteKey,
    required this.executable,
    this.arguments = const [],
    this.pythonRuntime = false,
    required this.workingDirectory,
    required this.logFile,
    this.limits = const SpiderLimits(),
    Map<String, String> extraEnvironment = const {},
  }) : environment = SidecarEnvironment.build(extra: extraEnvironment);

  final String siteKey;
  final String executable;
  final List<String> arguments;
  final bool pythonRuntime;

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

/// sidecar 退出码的失败语义（`sidecars/spider-host-jvm/README.md`）。
///
/// 判定只存在这一处：退出码 → 语义，重试策略与用户文案都从这里派生。分散到
/// 多个分支里各写一套「算不算崩溃」，两边迟早分叉，而且改一处漏一处。
enum SidecarExitKind {
  /// `0`：正常退出（stdin EOF，或 `destroy`/`shutdown`）。
  normal,

  /// `2`/`3`：协议/manifest/入口非法，或站源初始化失败。
  ///
  /// **确定性失败**：同一个入口、同一份 manifest 下次启动必然同样失败。因此
  /// 不重试——退避重试只会反复拉起 JVM：既不可能成功，还会让用户觉得「像崩了」，
  /// 同时把机器拖慢。
  deterministic,

  /// 其余（被 kill、拿不到退出码、超时、其它异常退出）：可能是抖动，
  /// 保持既有指数退避重试。
  transient,
}

/// 退出码 → 失败语义；null 表示拿不到退出码，按瞬时失败处理。
SidecarExitKind sidecarExitKind(int? code) => switch (code) {
  0 => SidecarExitKind.normal,
  2 || 3 => SidecarExitKind.deterministic,
  _ => SidecarExitKind.transient,
};

/// 单行 stderr 的展示上限（JVM 栈信息一行可能几百字符）。
/// sidecar 进程的内存下限（MiB）。
///
/// 为什么需要兜底：加固壳站点**首次在进程内转译 payload** 时峰值 commit 约 257 MiB，
/// 而 manifest 里写的 `limits.memoryMiB` 可能是旧值（256）——2026-11-21 实测：磁盘上的
/// manifest 已被启动迁移改成 512，但作业对象仍按**启动扫描时缓存的 256** 建，于是照旧
/// 被 TerminateProcess 杀掉（stderr 空、退出码 1）。这里在作业对象边界再兜一次，
/// 不依赖「迁移是否早于扫描」这种时序条件。上限只是**上限**，调高不会真的占内存。
const int minimumSidecarMemoryMiB = 512;

int memoryFloorBytes(int memoryBytes) {
  const floor = minimumSidecarMemoryMiB * 1024 * 1024;
  return memoryBytes < floor ? floor : memoryBytes;
}

const int _stderrKeyMaxChars = 200;

final RegExp _stderrKeyPattern = RegExp(r'Exception|Error|Caused by|错误|异常');

/// stderr 里最值得展示给用户的一行：异常/错误行优先，否则取最后一条非空行。
///
/// 为什么不是直接取最后一行：JVM 因异常退出时最后一行常是栈帧表
/// （`\tat com.xxx.Yyy.zzz(...)`），真正能行动的 `ClassNotFoundException: ...`
/// 在它上面几行。
String? stderrKeyLine(Iterable<String> lines) {
  String? actionable;
  String? last;
  for (final raw in lines) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    last = line;
    if (_stderrKeyPattern.hasMatch(line)) actionable = line;
  }
  final picked = actionable ?? last;
  if (picked == null) return null;
  return picked.length <= _stderrKeyMaxChars
      ? picked
      : '${picked.substring(0, _stderrKeyMaxChars)}…';
}

/// 确定性启动失败的**用户文案**。
///
/// 为什么不说「sidecar 意外退出（code=2/3）」：2/3 是**可解释**的失败（入口类名
/// 对不上、manifest 非法、站源初始化抛异常），写成「意外退出/崩溃」会让用户以为
/// 程序坏了，还把唯一的行动线索（stderr 里的异常类名）埋掉。
String deterministicExitMessage(int code, Iterable<String> stderrLines) {
  final prefix = code == 3 ? '站源初始化失败' : '协议或 manifest 非法';
  final key = stderrKeyLine(stderrLines);
  return key == null ? '$prefix（无 stderr 输出）' : '$prefix：$key';
}

/// 非 0 退出（瞬时崩溃，`SPIDER_CRASHED`）的**用户文案**。
///
/// 为什么也要挂 stderr：2/3 早就带出了 stderr 关键行，而 exit=1 这类崩溃原先
/// 只有「sidecar 意外退出（code=1）」——用户拿不到任何线索，stderr 也只是记在
/// details 里没人看，等于让用户对着一个退出码猜。这里补上同一类关键行，
/// **分类不变**：瞬时崩溃仍是 `SPIDER_CRASHED`（可退避重试），不借用 2/3 的
/// `SPIDER_INIT_FAILED` 文案。
String crashExitMessage(int? code, Iterable<String> stderrLines) {
  final head = 'sidecar 意外退出（code=${code ?? "-"}）';
  final key = stderrKeyLine(stderrLines);
  return key == null ? '$head（无 stderr 输出）' : '$head：$key';
}

/// 进程内退出钩子在 stderr 里的标记（宿主 [Host] 收尾时打的那一行）。
const String _exitHookMarker = '进程退出钩子';

/// 这次退出是不是「进程被外部终止」——作业对象的内存/CPU 上限、宿主强杀。
///
/// 判据只有一条：**没有**看到进程内退出钩子。为什么：作业对象超限走的是
/// TerminateProcess，进程内没有任何收尾代码，stderr 停在崩溃前最后一条告警上，
/// 把它当死因就是误归因（实测：256 MiB 上限杀进程，文案却写成启动期那条可降级的
/// dex2jar 告警）。判定只留这一处：分散到多个分支各写一遍 `contains`，改一处漏一处。
bool isExternalTermination(Iterable<String> stderrLines) =>
    !stderrLines.any((line) => line.contains(_exitHookMarker));

/// 资源类死亡：被外部终止，**且**退出码不是站源自己选的那种。
///
/// 为什么必须一并看退出码：`os._exit(3)`（站源初始化失败、以及 phase2_ipc /
/// sidecar_idle_recycle 里的 CrashSpider）同样不会走到退出钩子——那是站源**故意**
/// 的退出，重试语义不许被这条判定改掉。所以用 [sidecarExitKind] 把 2/3 排除在外，
/// `null`（拿不到退出码）也按瞬时失败留给退避。
bool isResourceLimitTermination(int? code, Iterable<String> stderrLines) =>
    sidecarExitKind(code) == SidecarExitKind.transient &&
    isExternalTermination(stderrLines);

/// 资源类死亡的**可行动建议**：能给用户拧的旋钮只有 manifest 的资源上限。
String resourceLimitAdvice(int? memoryMiB) =>
    memoryMiB == null || memoryMiB <= 0
    ? '建议提高该站点的 limits.memoryMiB'
    : '建议提高该站点的 limits.memoryMiB（当前 $memoryMiB）';

/// 外部终止的用户文案：说清「不是站源代码崩了」，给出唯一能行动的旋钮，并把
/// 崩溃前的最后一条告警**降级成旁证**（它不是死因，只是死之前最后说的话）。
String externalTerminationMessage(
  int? memoryMiB, {
  Iterable<String> stderrLines = const <String>[],
}) {
  final base =
      '进程被外部终止（未见退出钩子：通常是作业对象的内存/CPU 上限或宿主强制结束）；'
      '${resourceLimitAdvice(memoryMiB)}';
  final key = stderrKeyLine(stderrLines);
  return key == null || key.isEmpty ? base : '$base；崩溃前最后一条告警=$key';
}

/// 爬虫 IPC 详细调试日志（入参/出参）的开关与落点。
///
/// 为什么是**可变共享对象**而不是一个 bool 参数：开关要能在设置页切换后立即对
/// 后续 RPC 生效，又不允许为了开关重建 sidecar 进程，因此进程持有的是这个对象
/// 的引用，设置页改的是对象里的字段。
///
/// 为什么挂在帧出口（[_send]）与响应入口（[_onStdout]）而不是 `request()`：
/// heartbeat、`$/cancelRequest` 这些帧不走 `request()`，只有帧层能覆盖全部方法。
///
/// 所有输出先抹掉敏感键、再经 [redactLogText]，并且吞掉写入异常——日志是旁路，
/// 既不能改变 IPC 帧，也不能影响主流程。
String redactSpiderProxyText(String value) => value.replaceAll(
  RegExp(r'/s/[A-Za-z0-9_-]+/proxy(?:\?[^\s"<>]*)?'), '/s/<redacted>/proxy',
);

class SpiderDebugLog {
  SpiderDebugLog({this.log, this.enabled = false});

  /// 落盘用的日志服务；null 时只保留开关状态（不发任何日志）。
  final LogService? log;

  /// 是否记录入参/出参；默认关闭（关闭时日志量与既有版本完全一致）。
  bool enabled;

  /// 记录一条出站帧：请求帧写 method/id/完整 params，取消帧写目标 id。
  void outbound(Map<String, Object?> envelope, {bool privatePlayback = false}) {
    if (!enabled) return;
    final method = '${envelope['method'] ?? "-"}';
    final params = privatePlayback && envelope['method'] == SpiderMethod.play
        ? '<proxyHttp playback redacted>' : envelope['params'];
    final id = envelope['id'];
    // `$/cancelRequest` 是通知帧：自身没有 id，被取消的 id 在 params 里。
    final target = id == null
        ? 'target=${_encode(params)}'
        : 'id=$id params=${_encode(params)}';
    _write('rpc→ method=$method $target');
  }

  /// 记录一条成功的响应出参（result 全量，不截断）。
  void inboundOk(String method, String requestId, Object? result, {bool privatePlayback = false}) {
    if (!enabled) return;
    final safe = privatePlayback && method == SpiderMethod.play ? '<proxyHttp playback redacted>' : result;
    _write('rpc← method=$method id=$requestId ok result=${_encode(safe)}');
  }

  /// 记录一条失败的响应出参（含错误码与 message）。
  void inboundError(String method, String requestId, SpiderError error) {
    if (!enabled) return;
    if (method == SpiderMethod.proxy) {
      _write('rpc← method=$method id=$requestId error code=${error.code}');
      return;
    }
    _write(
      'rpc← method=$method id=$requestId error code=${error.code} '
      'message=${error.message} retryable=${error.retryable} '
      'details=${_encode(error.details)}',
    );
  }

  void httpOutbound({
    required String method,
    required String action,
    required String siteKey,
    required Uri uri,
    Object? params,
    Map<String, String> headers = const {},
  }) {
    if (!enabled || log == null) return;
    try {
      log!.debug(
        'http→ site=${redactLogText(siteKey)} method=${redactLogText(method)} '
        'action=${redactLogText(action)} url=${_httpUrl(uri)} '
        'params=${jsonEncode(_sanitizeHttp(params))} '
        'headers=${jsonEncode(_sanitizeHttp(headers))}',
        scope: 'spider',
      );
    } catch (_) {
      // 脱敏、编码和写入都属于旁路，失败不能中断站点请求。
    }
  }

  void httpInbound({
    required String method,
    required String action,
    required String siteKey,
    required int statusCode,
    required String Function() body,
    Map<String, String> headers = const {},
  }) {
    if (!enabled || log == null) return;
    try {
      log!.debug(
        'http← site=${redactLogText(siteKey)} method=${redactLogText(method)} '
        'action=${redactLogText(action)} status=$statusCode '
        'headers=${jsonEncode(_sanitizeHttp(headers))} body=${_httpBody(body())}',
        scope: 'spider',
      );
    } catch (_) {
      // 延迟解码让关闭开关时没有额外的响应解码开销。
    }
  }

  void httpFailure({
    required String method,
    required String action,
    required String siteKey,
    required Object error,
  }) {
    if (!enabled || log == null) return;
    try {
      log!.debug(
        'http← site=${redactLogText(siteKey)} method=${redactLogText(method)} '
        'action=${redactLogText(action)} status=network_error '
        'error=${error.runtimeType}',
        scope: 'spider',
      );
    } catch (_) {}
  }

  static String _httpUrl(Uri uri) {
    final safe = uriWithoutUserInfo(uri);
    if (!safe.hasQuery) return redactLogText(safe.toString());
    return redactLogText(
      safe
          .replace(
            queryParameters: {
              for (final entry in safe.queryParametersAll.entries)
                entry.key: isSensitiveHeaderKey(entry.key)
                    ? ['<redacted>']
                    : [
                        for (final value in entry.value)
                          _sanitizeHttp(value) as String,
                      ],
            },
          )
          .toString(),
    );
  }

  static Object? _sanitizeHttp(Object? value) {
    if (value is String) {
      final text = value.trimLeft();
      if (text.startsWith('{') || text.startsWith('[')) {
        try {
          return jsonEncode(_sanitizeHttp(jsonDecode(value)));
        } on FormatException {
          // extend 等字段可能是 JSON 字符串，合法时也要抹掉其中的敏感键。
        }
      }
      final uri = Uri.tryParse(value);
      if (uri != null && (uri.isScheme('http') || uri.isScheme('https'))) {
        return _httpUrl(uri);
      }
      return redactLogText(value);
    }
    if (value is Map) {
      return <String, Object?>{
        for (final entry in value.entries)
          '${entry.key}': isSensitiveHeaderKey('${entry.key}')
              ? '<redacted>'
              : _sanitizeHttp(entry.value),
      };
    }
    if (value is List) return [for (final item in value) _sanitizeHttp(item)];
    return value;
  }

  static String _httpBody(String text) {
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      if (text.trimLeft().startsWith('<')) {
        try {
          final document = XmlDocument.parse(text);
          for (final node in document.descendants) {
            if (node is XmlAttribute) {
              node.value = isSensitiveHeaderKey(node.localName)
                  ? '<redacted>'
                  : _sanitizeHttp(node.value) as String;
            } else if (node is XmlText) {
              node.value = _httpXmlValue(node, node.value);
            } else if (node is XmlCDATA) {
              node.value = _httpXmlValue(node, node.value);
            }
          }
          return document.toXmlString();
        } catch (_) {
          // 解析或改写失败（非法 XML、超大文档、异常节点）一律降级为文本脱敏：
          // 「没有日志」比「脱敏不彻底的日志」更难排查，因此绝不吞掉整条记录。
        }
      }
      return redactLogText(text);
    }
    // 先逐值脱敏再序列化，否则自由文本规则会吞掉签名 URL 后面的 JSON 字段。
    return jsonEncode(_sanitizeHttp(decoded));
  }

  static String _httpXmlValue(XmlNode node, String value) {
    final parent = node.parent;
    if (parent is XmlElement && isSensitiveHeaderKey(parent.localName)) {
      return '<redacted>';
    }
    return _sanitizeHttp(value) as String;
  }

  void _write(String message) {
    final target = log;
    if (target == null) return;
    try {
      target.debug(redactLogText(redactSpiderProxyText(message)), scope: 'spider');
    } catch (_) {
      // 日志写入失败不得影响主流程。
    }
  }

  /// JSON 编码；含不可编码对象时退回 `toString()`，绝不让日志抛异常。
  static String _encode(Object? value) {
    try {
      return jsonEncode(_sanitize(value));
    } catch (_) {
      return '$value';
    }
  }

  /// 递归把敏感键的值替换为占位符。
  ///
  /// 为什么还要这一层：[redactLogText] 处理的是自由文本形态（`Cookie: xxx`、
  /// `?sign=xxx`），而入参是 JSON，敏感值形如 `"Cookie":"a=b"`，两者形态不同。
  /// 判定复用 [isSensitiveHeaderKey]，与 HTTP 头脱敏同一套规则，避免规则分叉。
  static Object? _sanitize(Object? value) {
    if (value is String) {
      return redactSpiderProxyText(value);
    }
    if (value is Map) {
      return <String, Object?>{
        for (final entry in value.entries)
          '${entry.key}': (isSensitiveHeaderKey('${entry.key}') || const {'token', 'entryUrl', 'sessionId'}.contains('${entry.key}'))
              ? '<redacted>'
              : _sanitize(entry.value),
      };
    }
    if (value is List) return [for (final item in value) _sanitize(item)];
    return value;
  }
}

/// 单个 sidecar 进程。
class SidecarProcess {
  SidecarProcess._(
    this._process,
    this._spec,
    this._job,
    this._debugLog,
    this._log,
  );

  final Process _process;
  final SidecarLaunchSpec _spec;

  /// 详细调试日志旁路；null 表示调用点没注入（既有行为与日志量不变）。
  final SpiderDebugLog? _debugLog;

  /// 诊断告警出口（现场日志保留/清理失败）；null 表示调用点没注入。
  final LogService? _log;

  /// Windows Job Object；为 null 表示只能做进程级终止（§18.2.1）。
  WindowsJobObject? _job;

  final IpcFrameDecoder _decoder = IpcFrameDecoder(
    maxFrameBytes: 16 * 1024 * 1024,
  );

  final Map<String, _Pending> _pending = {};
  void Function()? _activityChanged;

  /// 已向调用方交付过本机环回地址（取流/代理场景）。
  ///
  /// 这类地址可能直接被播放器当成流地址拉取：宿主此刻没有「播放依赖已释放」的信号，
  /// 因此这个进程不能被空闲回收（宁可多留一个进程也不能把正在播的流掐断）。
  bool _hasPlaybackDependency = false;
  bool _proxyHttpNegotiated = false;

  /// 是否已承载播放依赖（只读，供空闲回收判定）。
  bool get hasPlaybackDependency => _hasPlaybackDependency;

  /// 会返回取流地址的 ABI 方法。
  static const Set<String> playbackMethods = {
    SpiderMethod.play,
    SpiderMethod.live,
    SpiderMethod.proxy,
  };
  final Completer<SidecarExit> _exitCompleter = Completer<SidecarExit>();
  final List<String> _stderrLines = [];

  /// stderr 管道结束信号。
  ///
  /// 为什么需要它：退出回执（exitCode）与 stderr 管道的最后一批数据没有先后
  /// 保证。[_onExit] 若立刻读 [_stderrLines]，崩溃文案可能刚好错过那行唯一能
  /// 说明原因的异常——「只有退出码、没有 stderr」就是这么来的。
  final Completer<void> _stderrDone = Completer<void>();

  /// 等 stderr 收尾的上限：正常情况管道随进程立即关闭，用不到这个上限；
  /// 留 200ms 只是不让一个不关的管道把错误回执拖住。
  static const Duration _stderrDrainTimeout = Duration(milliseconds: 200);

  /// 退出回执（进程退出后才有值）。
  ///
  /// 为什么要留一份：启动阶段握手还没回帧、进程就已经退出时，调用方拿到的
  /// 报错可能不带 exitCode。没有这份回执，exit=3 会被误判成瞬时失败又去重试。
  SidecarExit? _exitInfo;
  SidecarExit? get exitInfo => _exitInfo;

  int _sequence = 0;
  int _cumulativeStdoutBytes = 0;
  bool _stopping = false;
  bool _stdinClosed = false;
  bool _stdoutPolluted = false;
  String? _lastStdinError;

  /// stdin 写失败的最近一条错误（诊断用；不影响主流程）。
  String? get lastStdinError => _lastStdinError;
  String? _lastStderrError;

  /// 超时升级为终止进程树之前的宽限期守卫（§9.3.1「超时后依次执行取消、
  /// 宽限等待、终止进程树」）。
  ///
  /// 必须是字段而不是匿名 Timer：匿名 Timer 没有句柄，[dispose] 之后照样
  /// 到点触发，那时进程已经退出、pid 也可能被系统复用，这一刀根本不该落下。
  Timer? _killGuard;

  /// 已超时、迟到响应仍可能到达的请求 id。
  ///
  /// 用集合而不是单个 id：A 超时后 B 也超时，守卫会为 B 重新挂上；此时 A 的
  /// 迟到响应同样证明这一次超时不是进程挂死。集合在「证明存活」、进程退出和
  /// [dispose] 时清空，不会跨守卫周期堆积。
  final Set<String> _timedOutIds = {};

  int _killTreeCount = 0;

  /// 心跳间隔（§9.3.1「支持 cancel、shutdown 和心跳」）。
  static const Duration heartbeatInterval = Duration(seconds: 15);

  Timer? _heartbeatTimer;

  /// stderr 单文件上限，超过后轮转（§9.3.1）。
  static const int stderrRotateBytes = 256 * 1024;

  static const int stderrKeepFiles = 3;

  /// 正常停止/崩溃后保留的 sidecar 现场份数（按站点计）。
  ///
  /// 为什么是 10：[dispose] 默认会连工作目录一起删掉，而 stderr.log 就落在
  /// 工作目录里（见 [SpiderHostSupervisor] 里 logFile 与 workingDirectory
  /// 同目录），不复制就等于「一正常停止就销毁崩溃现场」。单份体积由 stderr
  /// 轮转封顶（([stderrKeepFiles] + 1) × [stderrRotateBytes] ≈ 1MB），10 份约
  /// 10MB/站点——足够回答「刚才那个源为什么打不开」的最近几次启停，再老的现场
  /// 已经和当下的版本/配置对不上了，留着只是占磁盘。
  static const int preservedStderrKeepFiles = 10;

  int get pid => _process.pid;

  bool get isRunning => !_exitCompleter.isCompleted;

  List<String> get stderrLines => List.unmodifiable(_stderrLines);

  String? get lastStderrError => _lastStderrError;

  /// 兜底终止守卫是否仍在等待（用例据此断言响应/退出/dispose 之后已撤销）。
  @visibleForTesting
  bool get killGuardArmed => _killGuard?.isActive ?? false;

  /// 已经发起的进程树终止次数（用例据此断言宽限期之后不再补刀）。
  @visibleForTesting
  int get killTreeCount => _killTreeCount;

  ProcessIsolationReport get isolation =>
      _job?.report ?? ProcessIsolationReport.bestEffortOnly;

  Future<SidecarExit> get done => _exitCompleter.future;

  /// 启动子进程并接管 stdout/stderr。
  ///
  /// [log] 只用于诊断告警（现场日志保留/清理失败）；null 时静默跳过，
  /// 既有的启动与停止行为不受影响。
  static Future<SidecarProcess> start(
    SidecarLaunchSpec spec, {
    SpiderDebugLog? debugLog,
    LogService? log,
  }) async {
    final pythonSidecar =
        spec.pythonRuntime ||
        RegExp(
          r'^(python[0-9.]*|py)(\.exe)?$',
          caseSensitive: false,
        ).hasMatch(p.basename(spec.executable));
    if (pythonSidecar) PythonEnvironment.acquireSidecar();
    try {
      await Directory(spec.workingDirectory).create(recursive: true);
      await Directory(p.dirname(spec.logFile)).create(recursive: true);

      final process = await Process.start(
        spec.executable,
        spec.arguments,
        workingDirectory: spec.workingDirectory,
        // §9.8：只传白名单变量，不继承宿主完整环境。
        environment: pythonSidecar
            ? PythonEnvironment.sidecarEnvironment(spec.environment)
            : spec.environment,
        includeParentEnvironment: false,
        runInShell: false,
      );

      WindowsJobObject? job;
      if (Platform.isWindows) {
        job = WindowsJobObject.create(
          memoryBytes: memoryFloorBytes(spec.limits.memoryBytes),
          cpuSeconds: spec.limits.cpuSeconds,
        );
        if (job != null && !job.assign(process.pid)) {
          // 保留 job 引用以便 dispose，但隔离等级已被降级。
        }
      }

      final instance = SidecarProcess._(process, spec, job, debugLog, log);
      instance._wire();
      if (pythonSidecar) {
        unawaited(
          instance.done.then((_) => PythonEnvironment.releaseSidecar()),
        );
      }
      return instance;
    } catch (_) {
      if (pythonSidecar) PythonEnvironment.releaseSidecar();
      rethrow;
    }
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
      // 管道关闭（进程退出）才说明 stderr 已经读全，[_onExit] 据此收尾。
      onDone: () {
        if (!_stderrDone.isCompleted) _stderrDone.complete();
      },
      cancelOnError: false,
    );
    _process.exitCode.then(
      _onExit,
      onError: (Object error) {
        unawaited(_onExit(-1));
      },
    );
    // 对端退出后写 stdin 会异步失败；这里先挂兜底，避免未捕获的管道写错误
    // 被测试框架记到无关用例上。
    _process.stdin.done.catchError((Object error) {
      _lastStdinError = '$error';
    });
    _heartbeatTimer = Timer.periodic(
      heartbeatInterval,
      (_) => _sendHeartbeat(),
    );
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
          details: {'bytes': _cumulativeStdoutBytes, 'limit': limit},
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
          message:
              '${error.message}'
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
      // 只有**超时的那个请求**自己回了帧，才证明进程没挂死。心跳与别的请求
      // 的应答只说明读循环还在转，站源可以照样卡死在工作线程里，不能拿它们
      // 当存活证据。超时请求的迟到响应已从 `_pending` 移出，会落到下面的未知
      // id 分支，因此同样在这里撤销守卫。
      if (_timedOutIds.remove(response.id)) _cancelKillGuard();
      final pending = _pending.remove(response.id);
      if (pending == null) {
        // 未知 ID：只在日志层记录，不改变任何在途请求状态（§9.3.1）。
        _lastStderrError = '忽略未知 id=${response.id} 的响应';
        continue;
      }
      pending.timer?.cancel();
      pending.graceTimer?.cancel();
      if (pending.completer.isCompleted) {
        _activityChanged?.call();
        continue;
      }
      if (response.succeeded) {
        // 超限时 _checkResponseSize 已用错误完成该请求，不能再 complete，
        // 否则会抛 `Bad state: Future already completed`，掩盖真正的
        // SPIDER_RESOURCE_LIMIT（§9.3.1「限制单响应大小」）。
        if (!_checkResponseSize(response.result, pending)) {
          // 出参日志只记真正交付给调用方的那份结果，与下面的 complete 同条件。
          _debugLog?.inboundOk(pending.method, pending.id, response.result, privatePlayback: _proxyHttpNegotiated);
          if (playbackMethods.contains(pending.method) &&
              _carriesLoopbackAddress(response.result)) {
            _hasPlaybackDependency = true;
          }
          pending.completer.complete(response.result);
        }
      } else {
        _debugLog?.inboundError(pending.method, pending.id, response.error!);
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
      _activityChanged?.call();
    }
  }

  /// 结果是否携带本机环回地址（127.0.0.1 / localhost）。
  static bool _carriesLoopbackAddress(Object? value) {
    switch (value) {
      case String():
        return _loopbackPattern.hasMatch(value);
      case Map():
        return value.values.any(_carriesLoopbackAddress);
      case Iterable():
        return value.any(_carriesLoopbackAddress);
      default:
        return false;
    }
  }

  static final RegExp _loopbackPattern = RegExp(
    r'(?:^|[/:])?(?:127\.0\.0\.1|localhost)(?::\d+)?(?:/|$)',
    caseSensitive: false,
  );

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
      if (file.existsSync() &&
          file.lengthSync() + chunk.length > stderrRotateBytes) {
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

  Future<void> _onExit(int code) async {
    _heartbeatTimer?.cancel();
    // 进程已经退出，宽限窗口失去意义：守卫绝不能等 [dispose] 之后再补一刀。
    _cancelKillGuard();
    final expected = _stopping;
    final exit = SidecarExit(
      code: code,
      expected: expected,
      reason: _stdoutPolluted ? 'protocol-pollution' : null,
    );
    _exitInfo = exit;
    if (!_exitCompleter.isCompleted) _exitCompleter.complete(exit);
    // sidecar 退出后，作业内仍可能残留它派生的孙进程（§18.2.1）。
    // `kill-on-close` 只在**最后一个**作业句柄关闭时生效，而宿主仍持有句柄，
    // 因此这里必须显式终止作业，否则崩溃会留下永久孤儿进程。
    _job?.terminate();
    // 崩溃文案要挂 stderr 尾部，而 stderr 管道可能晚于退出回执才关：先等它收尾
    // （有上限），再取关键行；否则拿到的是「半个 stderr」甚至空。
    if (!_stderrDone.isCompleted) {
      await _stderrDone.future.timeout(_stderrDrainTimeout, onTimeout: () {});
    }
    // 应期停机同样要结束在途请求：否则调用方会永远挂在一个已退出的子进程上。
    // 这里只陈述传输层事实（进程以哪个码退出），「算不算确定性失败、该不该
    // 重试、文案怎么说」由 [SpiderHostSupervisor] 按启动阶段判定——同一个
    // exit=3，启动阶段是「站源初始化失败」，运行中调用则是站源崩溃。
    _failAll(
      SpiderError(
        code: expected ? SpiderErrorCode.cancelled : SpiderErrorCode.crashed,
        message: expected ? 'sidecar 已停止' : _crashMessage(code),
        siteKey: _spec.siteKey,
        details: {
          'exitCode': code,
          'stderr': _stderrLines.isEmpty ? '' : _stderrLines.last,
        },
      ),
    );
  }

  /// 崩溃文案：**只有看到进程内退出钩子**时，才把 stderr 里那条异常当死因。
  ///
  /// 为什么：作业对象的内存/CPU 上限会直接 TerminateProcess，进程内没有任何收尾代码，
  /// stderr 停在崩溃前的最后一条告警上——把它当死因就是误归因（实测：256 MiB 上限杀进程，
  /// 文案却写成启动期那条**可降级**的 dex2jar AIOOBE 告警）。钩子是宿主在 `Host` 里打的
  /// `[webhtv] 进程退出钩子`，有它才说明 JVM 自己走到收尾。
  String _crashMessage(int? code) {
    if (!isExternalTermination(_stderrLines)) {
      return crashExitMessage(code, _stderrLines);
    }
    // 外部终止要带出可行动建议：这份安装里唯一能给用户拧的旋钮就是资源上限。
    return 'sidecar 意外退出（code=$code）：'
        '${externalTerminationMessage(_spec.limits.memoryMiB, stderrLines: _stderrLines)}';
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
    _activityChanged?.call();
  }

  void _killWithProtocolError(SpiderError error) {
    _failAll(error);
    unawaited(killTree());
  }

  void _send(Map<String, Object?> envelope) {
    if (_exitCompleter.isCompleted || _stdinClosed) return;
    // 入参日志挂在帧出口：全部出站帧（request / heartbeat / cancel）都经过这里，
    // 而帧内容一个字节都不改，日志纯旁路。
    _debugLog?.outbound(envelope, privatePlayback: _proxyHttpNegotiated);
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
    _activityChanged?.call();
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
    _armKillGuard(pending.id);
  }

  /// 撤销宽限期守卫。
  ///
  /// 三个撤销点缺一不可：超时的那个请求自己回了帧（进程没挂死）、[_onExit]
  /// 或 [dispose] 已经把进程收掉。少任何一个，都会留下「进程早已结束、守卫
  /// 仍然到点补刀」的窗口。
  void _cancelKillGuard() {
    _killGuard?.cancel();
    _killGuard = null;
    _timedOutIds.clear();
  }

  /// 挂上宽限期守卫：到期仍拿不到这个请求的任何帧，才升级为终止进程树。
  ///
  /// 升级条件（两条同时满足才 killTree）：
  /// 1. 到期时进程仍在运行、且未判协议污染（污染已由 [_killWithProtocolError]
  ///    终止，避免重复终止）；
  /// 2. 这个请求在宽限期内没有回帧（[_timedOutIds] 里还留着它），且
  ///    `_pending` 已空——还有别的调用方在途时，这次超时只说明**这一个**
  ///    请求慢，不代表整个进程挂死，杀进程等于替别人做决定（一次慢请求就能让
  ///    整站下线）。
  ///
  /// 因此「确实挂死才杀」的语义仍然成立：真挂死的进程一个帧都回不了，它的
  /// 第二次超时（届时通常已无其它在途请求）会重新挂上守卫并真正终止。
  void _armKillGuard(String requestId) {
    // 新的超时是更新的证据：重挂守卫，宽限期从这一刻重新计时。已超时的 id
    // 要留着——它们迟到的响应仍然算「进程没挂死」的证据。
    _killGuard?.cancel();
    _killGuard = null;
    _timedOutIds.add(requestId);
    _killGuard = Timer(const Duration(milliseconds: 500), () {
      _killGuard = null;
      if (_exitCompleter.isCompleted) return;
      if (_stdoutPolluted) return;
      if (_pending.isNotEmpty) return;
      unawaited(killTree());
    });
  }

  /// 终止整个子进程树。
  Future<void> killTree() async {
    _killTreeCount += 1;
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
  Future<SidecarExit> stop({
    Duration grace = const Duration(seconds: 3),
  }) async {
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
    // 释放之后不再有人等这一次宽限：先撤销守卫再终止进程。
    _cancelKillGuard();
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
      // 先留现场再删目录：stderr.log 与轮转文件就在工作目录里，删目录等于
      // 销毁崩溃现场。保留属于诊断设施，任何失败都只能告警——反过来阻断停止/
      // 空闲回收会是比丢日志严重得多的缺陷。
      try {
        await preserveStderrLog(
          logFile: _spec.logFile,
          siteKey: _spec.siteKey,
          log: _log,
        );
      } catch (error) {
        _log?.warning('sidecar 现场日志复制失败（不影响停止）：$error', scope: 'sidecar');
      }
      try {
        final dir = Directory(_spec.workingDirectory);
        if (await dir.exists()) await dir.delete(recursive: true);
      } catch (_) {
        // 目录被占用时忽略，由系统临时目录清理。
      }
    }
  }

  /// 把 stderr.log 及其轮转文件按时间顺序合并复制到应用日志目录，
  /// 落成 `sidecar-<siteKey>-<时间戳>.log`，并只保留最近
  /// [preservedStderrKeepFiles] 份。
  ///
  /// 返回写入的文件；没有 stderr 内容或日志目录未就绪时返回 null。
  /// 复制失败会抛出（由 [dispose] 兜住并告警），清理失败只在内部告警——已经
  /// 写好的现场不能因为「旧文件删不掉」而一起丢掉。
  static Future<File?> preserveStderrLog({
    required String logFile,
    required String siteKey,
    String? directory,
    LogService? log,
  }) async {
    final target = directory ?? LogService.logDirectoryOverride;
    // 日志目录尚未初始化（未开放落盘/纯单测）：没有可写的地方，也就无从保留。
    if (target == null) return null;
    // 轮转文件编号越大越旧（[_rotateStderr] 每次把 .1 往后挪），因此从大号往
    // 小号读、最后接主文件，拼出来的时间顺序与进程实际输出一致。
    final sources = <File>[
      for (var index = stderrKeepFiles; index >= 1; index--)
        File('$logFile.$index'),
      File(logFile),
    ];
    final existing = <File>[];
    for (final file in sources) {
      if (await file.exists()) existing.add(file);
    }
    // 进程还没往 stderr 写过任何东西：没有现场可留，不制造空文件。
    if (existing.isEmpty) return null;
    final segment = sanitizePathSegment(siteKey);
    final stamp = _fileTimestamp(DateTime.now());
    final out = File(p.join(target, 'sidecar-$segment-$stamp.log'));
    final bytes = <int>[];
    for (final file in existing) {
      final chunk = await file.readAsBytes();
      bytes.addAll(chunk);
      // 片段之间补换行：上一份的最后一行可能被轮转截断，直接粘下一份会把
      // 两条无关的日志并成一行。
      if (chunk.isEmpty || chunk.last != 10) bytes.add(10);
    }
    await Directory(target).create(recursive: true);
    await out.writeAsBytes(bytes, flush: true);
    await _prunePreservedStderrLogs(Directory(target), segment, log: log);
    return out;
  }

  /// 每个站点只保留最近 [preservedStderrKeepFiles] 份现场。
  ///
  /// 只清本站点前缀的文件：一个反复崩溃的源不该把其它源的现场挤掉。
  /// 清理失败只告警（下次保留时还会再试）。
  static Future<void> _prunePreservedStderrLogs(
    Directory directory,
    String segment, {
    LogService? log,
  }) async {
    try {
      final prefix = 'sidecar-$segment-';
      final kept = <File>[];
      await for (final entity in directory.list()) {
        if (entity is! File) continue;
        final name = p.basename(entity.path);
        if (name.startsWith(prefix) && name.endsWith('.log')) kept.add(entity);
      }
      if (kept.length <= preservedStderrKeepFiles) return;
      // 文件名里的时间戳定长，字典序即时间序（同秒内靠毫秒位仍然稳定）。
      kept.sort((a, b) => p.basename(b.path).compareTo(p.basename(a.path)));
      for (final stale in kept.skip(preservedStderrKeepFiles)) {
        try {
          await stale.delete();
        } catch (_) {
          // 单个文件被占用就先留着，下次再清。
        }
      }
    } catch (error) {
      log?.warning('清理旧 sidecar 现场日志失败：$error', scope: 'sidecar');
    }
  }

  /// 文件名用的时间戳（本地时间，定长可排序）。
  ///
  /// 不用 ISO8601：其中的 `:` 在 Windows 文件名里非法，写盘会直接失败。
  static String _fileTimestamp(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.year}${two(time.month)}${two(time.day)}'
        '-${two(time.hour)}${two(time.minute)}${two(time.second)}'
        '-${time.millisecond.toString().padLeft(3, '0')}';
  }
}

/// A bounded, releasable dependency on one exact host generation.
class SpiderPlaybackLease {
  SpiderPlaybackLease._(this.host, this.sessionId);
  final SpiderHost host;
  final String sessionId;
  Timer? _expiry;
  bool _released = false;
  bool get active => !_released && host.process.isRunning;
  void renew(Duration ttl) {
    if (!active) return;
    _expiry?.cancel();
    _expiry = host._leaseScheduler(ttl, release);
  }

  void release() {
    if (_released) return;
    _released = true;
    _expiry?.cancel();
    host._playbackLeases.remove(this);
    host.process._activityChanged?.call();
  }
}

/// 宿主侧的 Spider 调用门面：manifest 校验 + capability 校验 + 调用。
class SpiderHost {
  SpiderHost({
    required this.manifest,
    required this.process,
    required this.log,
    this.callbackTimeout = siteRequestTimeout,
  }) {
    unawaited(process.done.then((_) => clearPlaybackLeases()));
  }

  final SpiderManifest manifest;
  final SidecarProcess process;
  final LogService log;
  final Duration callbackTimeout;

  final Set<SpiderPlaybackLease> _playbackLeases = {};
  Timer Function(Duration, void Function()) _leaseScheduler = Timer.new;
  int get activePlaybackLeaseCount => _playbackLeases.length;
  SpiderProxyHttpExtension? get proxyHttp =>
      manifest.runtime == 'jvm' &&
          manifest.permissions.localProxy &&
          manifest.capabilities.values.contains(SpiderMethod.proxy) &&
          (_init?.capabilities.contains(SpiderMethod.proxy) ?? false)
      ? _init?.proxyHttp
      : null;

  SpiderPlaybackLease acquirePlaybackLease(
    String sessionId, {
    Duration ttl = const Duration(seconds: 120),
  }) {
    if (proxyHttp == null || !process.isRunning) {
      throw StateError('proxyHttp host unavailable');
    }
    final lease = SpiderPlaybackLease._(this, sessionId);
    _playbackLeases.add(lease);
    lease.renew(ttl);
    process._activityChanged?.call();
    return lease;
  }

  void clearPlaybackLeases() {
    for (final lease in _playbackLeases.toList()) {
      lease.release();
    }
  }

  SpiderInitResult? _init;
  SpiderInitResult? get initResult => _init;

  /// 站点请求预算：init/home/category/detail/proxy 30 秒，play 单独 90 秒。
  /// play 的预算容纳已观测到约 70 秒才返回的慢请求，不表示播放性能已优化。
  ///
  /// 为什么是 30 秒而不是 `siteRequestTimeout`(180s)：
  /// - 30 秒正是 sidecar 宿主自己的缺省预算（`sidecars/spider-host-js/host.js`
  ///   的 `_deadlineOf` 兜底 `30000`、`sidecars/spider-host-python/webhtv_ipc.py`
  ///   的 `DEFAULT_DEADLINE_MS = 30000`）。宿主与站源对齐到同一个上限，才不会
  ///   出现「站源早已放弃、宿主还挂着等」——那种等待只会变成用户眼前的白屏。
  /// - 给 180s 不行：真正挂死的请求会把首页按住 3 分钟，用户既看不到错误也点不动。
  ///
  /// 为什么不更短：JVM 壳站点的 home/category 常由站源内部**逐个试镜像**，
  /// 单个镜像慢一点整页就超时；15 秒对竞速型站点是硬伤（实测 15s 必挂）。
  static const Duration jvmShellRequestTimeout = Duration(seconds: 30);

  static const Map<String, Duration> _methodTimeouts = {
    // init 握手**不只是本地 IPC**：加固壳站点的站源对象就是在 `initialize` 里构造的，
    // 而壳内 `DexNative` 首次会现场转译载荷（实测冷启动 10.6 s，1193 类），再加上
    // payload 类加载与镜像初始化。给 15 s 会把「健康的慢启动」误判成 SPIDER_TIMEOUT
    //（2026-11-21 用户日志：WexAiGuaZi / WexAiYueYue 首页报 deadline 15000ms，其实是握手）。
    // 30 s 与 sidecar 宿主自身缺省预算一致（host.js / webhtv_ipc.py 都是 30 s）。
    SpiderMethod.init: jvmShellRequestTimeout,
    SpiderMethod.home: jvmShellRequestTimeout,
    SpiderMethod.category: jvmShellRequestTimeout,
    SpiderMethod.detail: jvmShellRequestTimeout,
    // search 本轮不动：它的站点侧预算仍是 `siteRequestTimeout`（不在改动范围）。
    SpiderMethod.search: siteRequestTimeout,
    SpiderMethod.play: Duration(seconds: 90),
    SpiderMethod.proxy: jvmShellRequestTimeout,
  };

  /// 某方法在未显式传 `deadline` 时的生效预算；null 表示按 [callbackTimeout]。
  ///
  /// 抽成静态函数是为了让用例能断言「生效值」，而不必真等 30 秒。
  static Duration? declaredTimeout(String method) => _methodTimeouts[method];

  /// `initialize` 握手：交换 ABI major/minor、capabilities、权限与限制（§9.3.1）。
  Future<SpiderInitResult> initialize({String extend = ''}) async {
    final result = await process.request(SpiderMethod.initialize, {
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
    }, deadline: _methodTimeouts[SpiderMethod.init]!);

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
    process._proxyHttpNegotiated = proxyHttp != null;
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
    final effective = deadline ?? declaredTimeout(method) ?? callbackTimeout;
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
      await call(SpiderMethod.destroy, deadline: const Duration(seconds: 5));
    } catch (_) {
      // destroy 失败仍需释放进程资源。
    }
    await process.stop();
    await process.dispose();
  }
}

/// 站点运行时状态（§17.2 Spider 管理页展示）。
enum SpiderRuntimeState { stopped, running, crashed, backoff, disabled, failed }

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
    this.debugLog,
    this.isSourceEnabled,
    this.maxFailures = 5,
    this.baseBackoff = const Duration(seconds: 1),
    this.maxBackoff = const Duration(seconds: 60),
    this.idleTimeout = const Duration(minutes: 5),
    Timer Function(Duration, void Function())? idleScheduler,
    DateTime Function()? clock,
  }) : _idleScheduler = idleScheduler ?? Timer.new,
       _clock = clock ?? DateTime.now;

  /// sidecar 临时工作目录根（`%LOCALAPPDATA%/webhtv-pc/cache/sidecars`）。
  final String workRoot;
  final LogService log;

  /// 详细调试日志旁路；由 `AppState` 注入，缺省不影响既有行为。
  final SpiderDebugLog? debugLog;

  /// 用户停用源的入口门禁，与连续失败触发的熔断分开（停用是用户的决定，
  /// 不该被算成「源失败」而推进指数退避）。
  final bool Function(String sourceKey)? isSourceEnabled;

  void _checkSourceEnabled(String siteKey, SpiderManifest manifest) {
    if (isSourceEnabled?.call(manifest.key) ?? true) return;
    throw _sourceDisabled(siteKey, manifest.key);
  }

  SpiderError _sourceDisabled(String siteKey, String sourceKey) => SpiderError(
    code: SpiderErrorCode.initFailed,
    message: '本地源 $sourceKey 已停用，请在本地源页启用后重试',
    siteKey: siteKey,
    userVisible: true,
  );

  /// 同一站点连续失败该次数后进入禁用状态，禁止无限快速重启（§9.3.1）。
  final int maxFailures;
  final Duration baseBackoff;
  final Duration maxBackoff;

  /// 空闲回收期限。不存在用户面板设置：工程上的保守默认值。
  final Duration idleTimeout;
  final Timer Function(Duration, void Function()) _idleScheduler;
  final DateTime Function() _clock;

  final Map<String, _SiteRuntime> _runtimes = {};
  Future<void>? _shutdown;
  int _workSequence = 0;

  /// 确保站点运行时可用；必要时启动并握手。
  ///
  /// 并发调用共用同一次启动（_SiteRuntime.starting），不会各起一个进程；
  /// 正在停机的站点先等停机收尾再重新启动，调用方拿到的永远是可用宿主。
  Future<SpiderHost> ensureRunning({
    required String siteKey,
    required String executable,
    List<String> arguments = const [],
    required SpiderManifest manifest,
    String extend = '',
    Map<String, String> environment = const {},
  }) {
    if (_shutdown != null) return Future.error(_cancelled(siteKey));
    if (!(isSourceEnabled?.call(manifest.key) ?? true)) {
      return Future.error(_sourceDisabled(siteKey, manifest.key));
    }
    final runtime = _runtimes.putIfAbsent(siteKey, () => _SiteRuntime(siteKey));
    final stopping = runtime.stopping;
    if (stopping != null) {
      return stopping.then(
        (_) => ensureRunning(
          siteKey: siteKey,
          executable: executable,
          arguments: arguments,
          manifest: manifest,
          extend: extend,
          environment: environment,
        ),
      );
    }
    final existing = hostFor(siteKey);
    if (existing != null) {
      _updateIdleTimer(runtime);
      return Future.value(existing);
    }
    final previous = runtime.process;
    if (previous != null && !previous.isRunning) {
      // 退出回执还没结算：等它落定再启动，绝不能把已退出的进程当作可用宿主。
      return previous.done.then(
        (_) => ensureRunning(
          siteKey: siteKey,
          executable: executable,
          arguments: arguments,
          manifest: manifest,
          extend: extend,
          environment: environment,
        ),
      );
    }
    final inFlight = runtime.starting;
    if (inFlight != null) return inFlight;

    final starting = _startRuntime(
      runtime,
      runtime.generation,
      executable: executable,
      arguments: arguments,
      manifest: manifest,
      extend: extend,
      environment: environment,
    );
    runtime.starting = starting;
    void clearStart() {
      if (identical(runtime.starting, starting)) runtime.starting = null;
    }

    unawaited(
      starting.then<void>(
        (_) => clearStart(),
        onError: (Object error, StackTrace stack) => clearStart(),
      ),
    );
    return starting;
  }

  SpiderError _cancelled(String siteKey) => SpiderError(
    code: SpiderErrorCode.cancelled,
    message: '站点 $siteKey 的 Spider 已停止',
    siteKey: siteKey,
  );

  Future<SpiderHost> _startRuntime(
    _SiteRuntime runtime,
    int generation, {
    required String executable,
    required List<String> arguments,
    required SpiderManifest manifest,
    required String extend,
    required Map<String, String> environment,
  }) async {
    final siteKey = runtime.siteKey;
    // 记录这次启动属于哪个源：删除源时要据此判断「还有进程占着目录」。
    runtime.sourceKey = manifest.key;
    _checkSourceEnabled(siteKey, manifest);
    // 确定性启动失败（exit=2/3）是终态：同样的入口/manifest 再启动必然同样失败。
    // 这里直接回放上次的结论，不再拉起进程；用户修好入口/manifest 后走管理页的
    // reset() 才允许重来。
    final fatal = runtime.fatalFailure;
    if (fatal != null && runtime.state == SpiderRuntimeState.failed) {
      throw SpiderError(
        code: fatal.code,
        message: fatal.message,
        siteKey: siteKey,
        retryable: false,
        userVisible: true,
        details: fatal.details,
      );
    }
    if (runtime.state == SpiderRuntimeState.disabled) {
      throw SpiderError(
        code: SpiderErrorCode.initFailed,
        message: '站点 $siteKey 的 Spider 连续失败已禁用，需人工重新启用',
        siteKey: siteKey,
        userVisible: true,
      );
    }
    final now = _clock();
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

    // siteKey 来自 manifest key（源包内容，不可信）：先净化成单个路径段再拼，
    // 否则 `../../x` 这类 key 会把工作目录拼到 workRoot 之外，而 dispose() 会
    // 递归删除这个目录。
    final workSegment = sanitizePathSegment(
      '$siteKey-${_clock().microsecondsSinceEpoch}-${++_workSequence}',
    );
    final workingDirectory = p.join(workRoot, workSegment);
    // 净化之后仍要断言：这个目录随后会被递归删除，宁可在启动阶段就报错，
    // 也绝不能静默回退到 workRoot（回退会把删除范围放大到全部站点）。
    if (!p.isWithin(workRoot, workingDirectory)) {
      throw SpiderError(
        code: SpiderErrorCode.initFailed,
        message: 'sidecar 工作目录越界：$workingDirectory 不在 $workRoot 内，拒绝启动',
        siteKey: siteKey,
      );
    }
    final logFile = p.join(workingDirectory, 'stderr.log');

    SidecarProcess? process;
    SpiderHost? host;
    try {
      process = await SidecarProcess.start(
        SidecarLaunchSpec(
          siteKey: siteKey,
          executable: executable,
          arguments: arguments,
          pythonRuntime: manifest.runtime.toLowerCase().startsWith('python'),
          workingDirectory: workingDirectory,
          logFile: logFile,
          limits: manifest.limits,
          extraEnvironment: environment,
        ),
        debugLog: debugLog,
        log: log,
      );
      // 先挂到 runtime 上：停机才能在启动过程中收掉这个进程。
      runtime.process = process;
      if (runtime.generation != generation) throw _cancelled(siteKey);
      // 握手期间用户可能已经停用该源：那样这次启动必须作废，
      // 而不是等握手完成后把进程登记成「运行中」。
      _checkSourceEnabled(siteKey, manifest);
      host = SpiderHost(manifest: manifest, process: process, log: log)
        .._leaseScheduler = _idleScheduler;
      await host.initialize(extend: extend);
      if (runtime.generation != generation) throw _cancelled(siteKey);
      _checkSourceEnabled(siteKey, manifest);
    } catch (error) {
      if (process != null) {
        if (identical(runtime.process, process)) runtime.process = null;
        await process.dispose();
      }
      // 停机/停用打断的启动不是站点失败，不能计进崩溃退避。
      if (runtime.generation != generation) throw _cancelled(siteKey);
      if (!(isSourceEnabled?.call(manifest.key) ?? true)) {
        throw _sourceDisabled(siteKey, manifest.key);
      }
      // 退出码 2/3 是确定性失败（语义见 sidecars/spider-host-jvm/README.md）：
      // 退避重试对它只是反复起 JVM，日志里 count=1/2/3 的连续启动就是这么来的。
      final exitCode = _startupExitCode(error, process);
      if (exitCode != null &&
          sidecarExitKind(exitCode) == SidecarExitKind.deterministic) {
        final fatal = _deterministicStartupError(siteKey, exitCode, process);
        _recordFatal(runtime, fatal, reason: '确定性');
        throw fatal;
      }
      // 资源类死亡（作业对象的内存/CPU 上限 → TerminateProcess）同样是终态：
      // 上限没改，重启只会再被杀一次，日志里 count=1/2/3 的连续启动就是这么来的。
      // 判定要同时带退出码和「确实有进程」——起不来（拿不到退出码）不是外部终止。
      if (exitCode != null &&
          process != null &&
          !_hostInitiatedExit(process.exitInfo) &&
          isResourceLimitTermination(exitCode, process.stderrLines)) {
        final fatal = _resourceLimitError(
          siteKey,
          exitCode,
          process.stderrLines,
          manifest.limits.memoryMiB,
        );
        _recordFatal(runtime, fatal, reason: '资源上限外部终止');
        throw fatal;
      }
      _recordFailure(runtime, error);
      rethrow;
    }

    final liveProcess = process;
    final liveHost = host;
    runtime
      ..host = liveHost
      ..process = liveProcess
      ..state = SpiderRuntimeState.running
      ..lastError = null
      ..fatalFailure = null;
    log.info(
      'Spider 已启动 site=$siteKey runtime=${manifest.runtime} '
      'isolation=${liveProcess.isolation.summary}',
      scope: 'spider',
    );

    // 崩溃监听：只影响该站点，并驱动指数退避。
    unawaited(
      liveProcess.done.then((exit) {
        if (!identical(runtime.process, liveProcess)) return;
        _cancelIdleTimer(runtime);
        liveProcess._activityChanged = null;
        runtime
          ..host = null
          ..process = null;
        if (exit.expected) {
          runtime.state = SpiderRuntimeState.stopped;
          return;
        }
        // 握手成功之后被作业对象/宿主干掉，与启动期是同一个结论：上限没改，重启只是
        // 换个时间再死一次。因此同样直接进 failed、不进退避、不消耗重试预算。
        if (!_hostInitiatedExit(exit) &&
            isResourceLimitTermination(exit.code, liveProcess.stderrLines)) {
          final fatal = _resourceLimitError(
            siteKey,
            exit.code,
            liveProcess.stderrLines,
            manifest.limits.memoryMiB,
          );
          _recordFatal(runtime, fatal, reason: '资源上限外部终止');
          log.error(
            'Spider 被外部终止（资源上限）site=$siteKey ${exit.summary}',
            scope: 'spider',
          );
          return;
        }
        runtime.state = SpiderRuntimeState.crashed;
        // 管理页的 `lastError` 直接展示 message：崩溃原因（stderr 关键行）必须写进
        // message 本身，只放 details 等于让用户看不到原因。
        final keyLine = stderrKeyLine(liveProcess.stderrLines) ?? '';
        _recordFailure(
          runtime,
          SpiderError(
            code: SpiderErrorCode.crashed,
            message: keyLine.isEmpty
                ? 'sidecar 意外退出：${exit.summary}（无 stderr 输出）'
                : 'sidecar 意外退出：${exit.summary}：$keyLine',
            siteKey: siteKey,
            details: {'stderr': liveProcess.stderrLines.take(5).join(' | ')},
          ),
        );
        log.error(
          'Spider 意外退出 site=$siteKey ${exit.summary} '
          'failures=${runtime.failureCount} delay=${runtime.restartDelay.inMilliseconds}ms',
          scope: 'spider',
        );
      }),
    );

    liveProcess._activityChanged = () => _updateIdleTimer(runtime);
    _updateIdleTimer(runtime);
    return liveHost;
  }

  /// 宿主自己结束的进程（目前只有协议污染）不算「外部终止」：那是宿主按规矩处置，
  /// 不是作业对象/系统把进程干掉，重试语义也不该跟着资源上限一起改。
  static bool _hostInitiatedExit(SidecarExit? exit) =>
      exit != null && exit.reason != null;

  void _cancelIdleTimer(_SiteRuntime runtime) {
    runtime.idleTimer?.cancel();
    runtime.idleTimer = null;
  }

  /// 只有真正空闲的宿主才允许被回收。
  ///
  /// 在途请求、初始化中的进程、自托管取流的站点，以及已经交付过环回播放地址的
  /// 宿主都不在回收范围内：它们身上还有调用方正在使用的资源。
  bool _canRecycle(SpiderHost host) {
    final process = host.process;
    return process.isRunning &&
        !process._stopping &&
        process._pending.isEmpty &&
        (host.proxyHttp != null
          ? host.activePlaybackLeaseCount == 0
          : !process.hasPlaybackDependency && !host.manifest.permissions.localProxy);
  }

  void _updateIdleTimer(_SiteRuntime runtime) {
    final host = runtime.host;
    if (host == null || _shutdown != null || !_canRecycle(host)) {
      _cancelIdleTimer(runtime);
      return;
    }
    if (runtime.idleTimer?.isActive ?? false) return;
    runtime.idleTimer = _idleScheduler(idleTimeout, () {
      runtime.idleTimer = null;
      // 到点时再确认一次：期间可能又来了调用或播放地址。
      if (identical(runtime.host, host) && _canRecycle(host)) {
        unawaited(_stopRuntime(runtime));
      }
    });
  }

  /// 启动阶段的 sidecar 退出码：优先用错误里带出的，其次用进程退出回执。
  ///
  /// 两处都要看：握手失败会把 exitCode 放进 details，而「进程先退出、请求随后
  /// 才发」时错误里没有 exitCode，只有 [_exitInfo] 知道真实退出码——漏了这条
  /// exit=3 会被误判成瞬时失败，又去重试。
  int? _startupExitCode(Object error, SidecarProcess? process) {
    final declared = error is SpiderError ? error.details['exitCode'] : null;
    return declared is int ? declared : process?.exitInfo?.code;
  }

  /// 把「启动阶段以 2/3 退出」翻译成面向用户的确定性失败。
  ///
  /// 为什么在这里翻译而不是在 [_onExit]：同样的 exit=3，启动阶段是站源初始化
  /// 失败（可解释、重试无用），运行中调用则是站源崩溃（仍按退避重试）。
  SpiderError _deterministicStartupError(
    String siteKey,
    int code,
    SidecarProcess? process,
  ) {
    final stderrLines = process?.stderrLines ?? const <String>[];
    return SpiderError(
      code: SpiderErrorCode.initFailed,
      message: deterministicExitMessage(code, stderrLines),
      siteKey: siteKey,
      // 确定性失败重试也没用，别让上层把它当成可重试故障。
      retryable: false,
      details: {
        'exitCode': code,
        'exitKind': 'deterministic',
        'stderr': stderrLines.isEmpty ? '' : stderrLines.last,
      },
    );
  }

  /// 资源类死亡的**面向用户**错误：说清不是站源代码崩了，并给出唯一能行动的旋钮。
  ///
  /// `retryable: false` 是这条错误的一半语义：上限没改，上层任何一次重试都只会
  /// 再被杀一次；剩下的一半由 [_recordFatal] 落成 failed 状态。
  SpiderError _resourceLimitError(
    String siteKey,
    int code,
    Iterable<String> stderrLines,
    int memoryMiB,
  ) => SpiderError(
    code: SpiderErrorCode.crashed,
    message:
        'sidecar 意外退出（code=$code）：'
        '${externalTerminationMessage(memoryMiB, stderrLines: stderrLines)}',
    siteKey: siteKey,
    retryable: false,
    details: {
      'exitCode': code,
      'exitKind': 'resource',
      'memoryMiB': memoryMiB,
      'stderr': stderrLines.isEmpty ? '' : stderrLines.last,
    },
  );

  /// 终态失败（确定性失败 / 资源类死亡）：直接进 failed，不进退避，也不消耗重试预算。
  ///
  /// 为什么不动 failureCount：它记的是「连续失败触发熔断」的预算，而这两类失败
  /// 重试多少次都是一个结论，把它算进去只会更快禁用站点、掩盖真实原因。
  /// 为什么还要记 [fatalFailure]：下一次 ensureRunning 必须回放同一结论而不是再起
  /// 一次进程——「不重试」若只体现在数字上，用户点开站点就又是一次 JVM。
  void _recordFatal(
    _SiteRuntime runtime,
    Object error, {
    required String reason,
  }) {
    final fatal = error is SpiderError ? error : null;
    runtime
      ..host = null
      ..process = null
      ..state = SpiderRuntimeState.failed
      ..lastError = fatal?.message ?? error.toString()
      ..nextRetryAt = null
      ..restartDelay = Duration.zero
      ..fatalFailure = fatal;
    log.error(
      'Spider 已停止（$reason，不重试）site=${runtime.siteKey} '
      'code=${fatal?.code ?? "-"} diag=${fatal?.diagnosticId ?? "-"} '
      'reason=${fatal?.message ?? error}',
      scope: 'spider',
    );
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
    _cancelIdleTimer(runtime);
    runtime
      ..failureCount = 0
      ..restartDelay = Duration.zero
      ..nextRetryAt = null
      ..lastError = null
      ..state = SpiderRuntimeState.stopped
      // 人工重置是「我改好了，再试一次」的唯一出口：确定性失败的门闩必须一起清掉。
      ..fatalFailure = null;
    log.info('Spider 已重置 site=$siteKey', scope: 'spider');
  }

  /// 强制停止某站点运行时（第18.2节「每个站点运行时可随时强制停止」）。
  ///
  /// 在途启动会被一起去掉：调用方收到 SPIDER_CANCELLED，不会留下孤儿进程。
  Future<void> stop(String siteKey) {
    final runtime = _runtimes[siteKey];
    return runtime == null ? Future<void>.value() : _stopRuntime(runtime);
  }

  Future<void> _stopRuntime(_SiteRuntime runtime) {
    final stopping = runtime.stopping;
    if (stopping != null) return stopping;
    final process = runtime.process;
    final starting = runtime.starting;
    // 递增代号：正在进行的启动在握手后立刻发现自己已过期。
    runtime.generation += 1;
    _cancelIdleTimer(runtime);
    if (process != null) process._activityChanged = null;
    runtime.host?.clearPlaybackLeases();
    runtime
      ..host = null
      ..process = null
      ..state = SpiderRuntimeState.stopped
      ..fatalFailure = null;
    return _trackStop(runtime, _drainRuntime(runtime, process, starting));
  }

  Future<void> _trackStop(_SiteRuntime runtime, Future<void> stopping) {
    runtime.stopping = stopping;
    void clearStop() {
      if (identical(runtime.stopping, stopping)) runtime.stopping = null;
    }

    unawaited(
      stopping.then<void>(
        (_) => clearStop(),
        onError: (Object error, StackTrace stack) => clearStop(),
      ),
    );
    return stopping;
  }

  Future<void> _drainRuntime(
    _SiteRuntime runtime,
    SidecarProcess? process,
    Future<SpiderHost>? starting,
  ) async {
    if (process != null) await process.dispose();
    if (starting != null) {
      try {
        await starting;
      } catch (_) {
        // 停机打断的启动由 ensureRunning 用 SPIDER_CANCELLED 报给调用方。
      }
    }
    log.info('Spider 已停止 site=${runtime.siteKey}', scope: 'spider');
  }

  bool isRunning(String siteKey) => hostFor(siteKey) != null;

  /// 某个源是否还有活着的运行时：主机在、进程在、或正在启动/停机收尾。
  ///
  /// 删除源时用它而不是 [isRunning]：握手中与收尾中的进程仍然占着源目录里的
  /// 文件，那时删目录会失败或留下半删除状态。
  bool isSourceActive(String sourceKey) => _runtimes.values.any(
    (runtime) =>
        runtime.sourceKey == sourceKey &&
        (runtime.host != null ||
            runtime.process != null ||
            runtime.starting != null ||
            runtime.stopping != null),
  );

  /// 按源停止全部站点别名（一个源可能被多个配置站点引用），含握手中的进程。
  Future<void> stopSources(Iterable<String> sourceKeys) async {
    final keys = sourceKeys.toSet();
    final siteKeys = [
      for (final runtime in _runtimes.values)
        if (keys.contains(runtime.sourceKey)) runtime.siteKey,
    ];
    for (final siteKey in siteKeys) {
      await stop(siteKey);
    }
  }

  /// 当前可用宿主；已退出或正在退出的进程不再返回（否则调用方会往死进程发帧）。
  SpiderHost? hostFor(String siteKey) {
    final host = _runtimes[siteKey]?.host;
    if (host == null) return null;
    final process = host.process;
    return process.isRunning && !process._stopping ? host : null;
  }

  /// 全部运行时状态，供 Spider 管理页展示（§17.2）。
  List<SpiderRuntimeStatus> statuses() =>
      _runtimes.values
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

  /// 应用退出时释放全部 sidecar 与端口（第22.2节）。
  Future<void> shutdownAll() {
    final running = _shutdown;
    if (running != null) return running;
    final shutdown = _shutdownAll();
    _shutdown = shutdown;
    unawaited(
      shutdown.then<void>(
        (_) => _shutdown = null,
        onError: (Object error, StackTrace stack) => _shutdown = null,
      ),
    );
    return shutdown;
  }

  Future<void> _shutdownAll() async {
    await Future.wait(_runtimes.values.toList().map(_stopRuntime));
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

  /// 该运行时对应的 manifest key（一个源可能被多个配置站点别名引用）。
  String sourceKey = '';
  SpiderHost? host;
  SidecarProcess? process;
  Future<SpiderHost>? starting;
  Future<void>? stopping;
  Timer? idleTimer;
  int generation = 0;
  SpiderRuntimeState state = SpiderRuntimeState.stopped;
  String? lastError;
  int failureCount = 0;
  Duration restartDelay = Duration.zero;
  DateTime? nextRetryAt;

  /// 终态失败的结论（确定性失败 exit=2/3、资源类外部终止）；非 null 表示重试没有意义。
  SpiderError? fatalFailure;
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
      // 内置优先、PATH 兜底：候选顺序只由 [NodeRuntimeResolver] 决定，这里不再
      // 自己遍历 PATH（否则两份实现分叉时「内置 node 已随包发」会被悄悄绕过）。
      return NodeRuntimeResolver.resolve();
    }
    // 允许直接给出可执行文件路径（测试与本地调试）。
    if (runtime.contains(Platform.pathSeparator) ||
        runtime.endsWith('.exe') ||
        runtime.endsWith('.py')) {
      return SidecarCommand(executable: runtime, arguments: const []);
    }
    return null;
  }

  /// Python 候选解释器，按优先级排列（Windows 上 `py.exe` 在前）。
  ///
  /// `py.exe` 是 Windows 的 launcher，正常会自己挑一个已安装的版本；但它也可能
  /// 指向**已被删除/迁移**的解释器（本机实测 `py -3` 直接以 101 退出）。因此候选
  /// 必须逐个验证后再采用（见 [firstUsablePython]），否则这个错误会被伪装成
  /// 「sidecar 崩溃」，并且把「本机没装 Python」这种可行动结论也搅浑。
  /// 优先使用的解释器（托管运行时；null 表示没用托管运行时）。
  ///
  /// 存在的理由：CatVod 站源要第三方依赖（requests/Crypto/lxml），而 PATH 上的
  /// 解释器常常没有；托管 venv 建好后必须排在所有候选之前，否则站点又会退回
  /// 「缺依赖 → exit 3」。仍然要过 [pythonWorks] 验证，坏路径不会把整条链带崩。
  static String? _preferredPython;

  static List<String> _preferredPythonArguments = const [];
  static void preferPythonExecutable(
    String? path, {
    List<String> arguments = const [],
    bool verified = false,
  }) {
    final trimmed = path?.trim();
    final next = (trimmed == null || trimmed.isEmpty) ? null : trimmed;
    _preferredPython = next;
    _preferredPythonArguments = List.unmodifiable(arguments);
    _pythonProbed = verified;
    _pythonResolved = verified && next != null
        ? SidecarCommand(executable: next, arguments: _preferredPythonArguments)
        : null;
  }

  static List<SidecarCommand> pythonCandidates({
    bool queryLauncher = true,
    String? launcherExecutable,
    ProcessResult Function(String, List<String>)? synchronousLauncherRunner,
  }) {
    final candidates = <SidecarCommand>[];
    void add(String executable, List<String> arguments) {
      if (candidates.any(
        (item) =>
            item.executable.toLowerCase() == executable.toLowerCase() &&
            item.arguments.join(' ') == arguments.join(' '),
      )) {
        return;
      }
      candidates.add(
        SidecarCommand(executable: executable, arguments: arguments),
      );
    }

    final preferred = _preferredPython;
    if (preferred != null && File(preferred).existsSync()) {
      add(preferred, _preferredPythonArguments);
    }

    if (Platform.isWindows) {
      final launcher = launcherExecutable ?? _resolveFromPath('py.exe');
      if (launcher != null) add(launcher, const ['-3']);
    }
    for (final name
        in Platform.isWindows
            ? const ['python.exe', 'python3.exe', 'python']
            : const ['python3', 'python']) {
      final resolved = _resolveFromPath(name);
      if (resolved != null) add(resolved, const []);
    }
    if (Platform.isWindows && queryLauncher) {
      final launcher = launcherExecutable ?? _resolveFromPath('py.exe');
      if (launcher != null) {
        try {
          final result = synchronousLauncherRunner == null
              ? _boundedLauncherSync(launcher)
              : synchronousLauncherRunner(launcher, const ['-0p']);
          if (result.exitCode == 0) {
            final output = '${result.stdout ?? ''}\n${result.stderr ?? ''}';
            for (final executable in pythonExecutablesFromLauncherOutput(
              output,
            )) {
              if (File(executable).existsSync()) add(executable, const []);
            }
          }
        } catch (_) {
          // launcher 不可用时保留 PATH 与显式解释器候选。
        }
      }
    }
    return candidates;
  }

  static Future<List<SidecarCommand>> pythonCandidatesAsync({
    String? launcherExecutable,
    List<SidecarCommand>? pathCandidates,
    Future<ProcessResult> Function(String, List<String>)? launcherRunner,
    Duration launcherTimeout = const Duration(seconds: 5),
    ProcessResult Function(String, List<String>)? synchronousLauncherRunner,
  }) async {
    final candidates = [...?pathCandidates];
    if (pathCandidates == null) {
      candidates.addAll(
        pythonCandidates(
          queryLauncher: false,
          launcherExecutable: launcherExecutable,
          synchronousLauncherRunner: synchronousLauncherRunner,
        ),
      );
    }
    final launcher =
        launcherExecutable ??
        (Platform.isWindows ? _resolveFromPath('py.exe') : null);
    if (launcher == null) return candidates;
    try {
      final result = await (launcherRunner == null
          ? _runLauncher(launcher, launcherTimeout)
          : launcherRunner(launcher, const ['-0p']).timeout(launcherTimeout));
      if (result.exitCode == 0) {
        for (final executable in pythonExecutablesFromLauncherOutput(
          '${result.stdout}\n${result.stderr}',
        )) {
          if (File(executable).existsSync() &&
              !candidates.any(
                (c) =>
                    c.executable.toLowerCase() == executable.toLowerCase() &&
                    c.arguments.isEmpty,
              )) {
            candidates.add(
              SidecarCommand(executable: executable, arguments: const []),
            );
          }
        }
      }
    } catch (_) {}
    return candidates;
  }

  static Future<ProcessResult> _runLauncher(
    String launcher,
    Duration timeout,
  ) async {
    final process = await Process.start(launcher, const ['-0p']);
    try {
      final output = await Future.wait<Object>([
        process.exitCode,
        process.stdout.transform(systemEncoding.decoder).join(),
        process.stderr.transform(systemEncoding.decoder).join(),
      ]).timeout(timeout);
      return ProcessResult(process.pid, output[0] as int, output[1], output[2]);
    } catch (_) {
      process.kill();
      await process.exitCode.timeout(
        const Duration(seconds: 1),
        onTimeout: () => -1,
      );
      rethrow;
    }
  }

  static ProcessResult _boundedLauncherSync(String launcher) {
    final shell = p.join(
      Platform.environment['SystemRoot'] ?? r'C:\Windows',
      'System32',
      'WindowsPowerShell',
      'v1.0',
      'powershell.exe',
    );
    final escaped = launcher.replaceAll("'", "''");
    final command =
        r'$s=[Diagnostics.ProcessStartInfo]::new();'
        "\$s.FileName='$escaped';"
        r'$s.Arguments="-0p";$s.UseShellExecute=$false;'
        r'$s.RedirectStandardOutput=$true;$s.RedirectStandardError=$true;'
        r'$p=[Diagnostics.Process]::new();$p.StartInfo=$s;[void]$p.Start();'
        r'$o=$p.StandardOutput.ReadToEndAsync();$e=$p.StandardError.ReadToEndAsync();'
        r'if(!$p.WaitForExit(5000)){$p.Kill();exit 124};'
        r'if(!$o.Wait(500)){exit 124};$o.Result;exit $p.ExitCode';
    return Process.runSync(shell, [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      command,
    ]);
  }

  static List<String> pythonExecutablesFromLauncherOutput(String output) {
    final paths = <String>[];
    final seen = <String>{};
    final pattern = RegExp(
      r'^\s*-(?:V:)?\S+\s+(?:\*\s+)?(.+\.exe)\s*$',
      caseSensitive: false,
    );
    for (final line in const LineSplitter().convert(output)) {
      final path = pattern.firstMatch(line)?.group(1)?.trim();
      if (path == null ||
          !p.windows.isAbsolute(path) ||
          p.windows.basename(path).toLowerCase() != 'python.exe' ||
          !seen.add(p.windows.normalize(path).toLowerCase())) {
        continue;
      }
      paths.add(path);
    }
    return paths;
  }

  /// 候选是否**真的能启动**：`--version` 退出码为 0 且输出 `Python 3.x`。
  ///
  /// 只做文件存在性检查是不够的：launcher 可能指向坏解释器，WindowsApps 的
  /// App Execution Alias 也可能「启动成功但不输出任何内容」。
  static bool pythonWorks(SidecarCommand command) {
    if (!File(command.executable).existsSync()) return false;
    try {
      final result = Process.runSync(
        command.executable,
        [...command.arguments, '--version'],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      final output = '${result.stdout ?? ''}${result.stderr ?? ''}';
      return result.exitCode == 0 && RegExp(r'Python\s+3\.').hasMatch(output);
    } catch (_) {
      return false;
    }
  }

  /// CatVod 壳站点在**模块顶层**就 import 的第三方模块。
  ///
  /// 与 [python_runtime_provision.catVodPythonProbeModules] 同清单。这里复制字面量
  /// 而不是 import 该模块：services/ 之间不引入反向依赖，且真正的安装逻辑仍只有
  /// 一处（python_runtime_provision.dart）。
  static const List<String> catVodDependencyModules = <String>[
    'requests',
    'Crypto',
    'lxml',
  ];

  /// 依赖探测脚本：只在有缺失时输出 MISSING:a,b，否则输出 OK。
  ///
  /// 用 importlib.util.find_spec 而不是 import：只查模块能否被解析，不执行模块
  /// 顶层代码（CatVod 壳的顶层代码本身就会解析配置并发网络请求）。
  static const String dependencyProbeScript =
      "import importlib.util as u,sys;"
      "ms=[m for m in sys.argv[1:] if u.find_spec(m) is None];"
      "print('MISSING:'+','.join(ms) if ms else 'OK')";

  /// 候选是否既「能启动」（[pythonWorks]）又带齐 CatVod 依赖。
  ///
  /// 缺陷（2026-10-25 实测）：只验 `--version` 会让一个**没有 requests** 的 3.14
  /// 通过，而 CatVod 壳在 import 阶段就会失败 —— host.py 记一行 stderr 后 return 3，
  /// 用户只看到「sidecar 意外退出（code=3）」。带依赖的候选优先；依赖探测与
  /// `--version` 同量级（实测 50–76 ms），因此只在「本机解释器」这一档付出成本。
  static bool pythonWorksForCatVod(
    SidecarCommand command, {
    List<String> modules = catVodDependencyModules,
  }) {
    if (!pythonWorks(command)) return false;
    if (modules.isEmpty) return true;
    try {
      final result = Process.runSync(
        command.executable,
        [...command.arguments, '-c', dependencyProbeScript, ...modules],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      if (result.exitCode != 0) return false;
      final output = '${result.stdout ?? ''}${result.stderr ?? ''}';
      return output.contains('OK');
    } catch (_) {
      return false;
    }
  }

  /// 从候选里挑第一个真正可用的；全部不可用时返回 null（调用方必须显示
  /// 「运行时未安装或不受支持」，不得静默跳过站点）。
  ///
  /// [probe] 可注入，便于单测直接覆盖「第一个候选是坏的」这类真实场景。
  static SidecarCommand? firstUsablePython(
    List<SidecarCommand> candidates, {
    bool Function(SidecarCommand)? probe,
  }) {
    final check = probe ?? pythonWorks;
    for (final command in candidates) {
      if (check(command)) return command;
    }
    return null;
  }

  static bool _pythonProbed = false;
  static SidecarCommand? _pythonResolved;

  static SidecarCommand? _resolvePython() {
    // 探测要真的拉起子进程（每个候选约 60–120 ms），因此结果按进程缓存：
    // 站点启动是热路径，不能每次 ensureRunning 都重探一遍。
    if (_pythonProbed) return _pythonResolved;
    _pythonProbed = true;
    _pythonResolved = firstUsablePython(pythonCandidates());
    return _pythonResolved;
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
