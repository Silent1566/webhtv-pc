/// `webhtv-ipc-v1` 传输层契约（设计文档 §9.3、§9.3.1、§9.5、§9.7）。
///
/// 设计要求：
/// - 帧格式为 `Content-Length` 头、空行和指定字节数的 UTF-8 JSON，禁止依赖
///   “一行一个 JSON”（§9.3.1）。§9.5 里的“一行一消息”是同一 envelope 的历史
///   描述，本实现以 §9.3.1 的长度前缀为准。
/// - stdout 只承载协议帧，运行时日志只能写入 stderr（§9.3.1）。
/// - `initialize` 交换 ABI major/minor、capabilities、权限和限制；major 不匹配
///   拒绝加载（§9.3、§9.3.1）。
/// - requestId 使用非空字符串，同一进程生命周期内不得复用未完成 ID。
/// - 统一错误对象至少包含 `code`、`category`、`message`、`retryable`、
///   `userVisible`、`siteKey`、`requestId`、`details`、`diagnosticId`（§9.3.1）。
///
/// 本文件是纯数据层，不启动进程、不做 IO，便于契约测试直接覆盖帧编解码与信封。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'app_error.dart';

/// ABI 名称与版本。
abstract final class SpiderAbi {
  /// 宿主与 sidecar 的 stdio JSON-RPC 通信 ABI（§9.3）。
  static const String ipc = 'webhtv-ipc-v1';

  /// 兼容 `POST <api>/home` 等路由的 HTTP 子集（§9.3、§9.4）。
  static const String catHttp = 'webhtv-cat-http-v1';

  /// CatSpider HTTP 的兼容标签（§9.4）。
  static const String catHttpCompatLabel = 'tvbox-http-v1';

  /// 宿主支持的 major 版本；sidecar major 不一致必须拒绝加载。
  static const int major = 1;

  /// 宿主支持的 minor 版本；minor 只增加可选能力。
  static const int minor = 0;
}

/// JSON-RPC 方法名（§9.2、§9.3 最低方法集）。
abstract final class SpiderMethod {
  static const String initialize = 'initialize';
  static const String init = 'init';
  static const String home = 'home';
  static const String homeVod = 'homeVod';
  static const String category = 'category';
  static const String detail = 'detail';
  static const String search = 'search';
  static const String play = 'play';
  static const String live = 'live';
  static const String proxy = 'proxy';
  static const String action = 'action';
  static const String destroy = 'destroy';
  static const String shutdown = 'shutdown';
  static const String heartbeat = 'heartbeat';

  /// 取消通知；设计文档 §9.5 使用 `$/cancelRequest`，历史 Schema 记为 `$/cancel`，
  /// 宿主两者都接受，sidecar 必须至少实现 `$/cancelRequest`。
  static const String cancelRequest = r'$/cancelRequest';
  static const String cancelLegacy = r'$/cancel';

  /// 必需方法集（§9.3）。
  static const List<String> required = [
    init,
    home,
    category,
    detail,
    search,
    play,
    destroy,
  ];

  /// 可选方法集（§9.3）。
  static const List<String> optional = [homeVod, live, proxy, action];

  static bool isCancel(String method) =>
      method == cancelRequest || method == cancelLegacy;
}

/// 统一错误码（§9.5）。
abstract final class SpiderErrorCode {
  static const String initFailed = 'SPIDER_INIT_FAILED';
  static const String unsupported = 'SPIDER_UNSUPPORTED';
  static const String badRequest = 'SPIDER_BAD_REQUEST';
  static const String httpError = 'SPIDER_HTTP_ERROR';
  static const String parseError = 'SPIDER_PARSE_ERROR';
  static const String timeout = 'SPIDER_TIMEOUT';
  static const String cancelled = 'SPIDER_CANCELLED';
  static const String crashed = 'SPIDER_CRASHED';
  static const String resourceLimit = 'SPIDER_RESOURCE_LIMIT';

  /// 传输层额外错误：非法帧、协议污染、未知 ID（§9.3.1）。
  static const String protocolViolation = 'SPIDER_PROTOCOL_VIOLATION';
  static const String unknownId = 'SPIDER_UNKNOWN_ID';

  static const List<String> all = [
    initFailed,
    unsupported,
    badRequest,
    httpError,
    parseError,
    timeout,
    cancelled,
    crashed,
    resourceLimit,
    protocolViolation,
    unknownId,
  ];
}

/// 错误分类，供 UI 决定提示语气与是否可重试（§9.3.1）。
abstract final class SpiderErrorCategory {
  static const String protocol = 'protocol';
  static const String transport = 'transport';
  static const String site = 'site';
  static const String resource = 'resource';
  static const String user = 'user';

  static String forCode(String code) {
    switch (code) {
      case SpiderErrorCode.protocolViolation:
      case SpiderErrorCode.unknownId:
      case SpiderErrorCode.badRequest:
        return protocol;
      case SpiderErrorCode.crashed:
        return transport;
      case SpiderErrorCode.resourceLimit:
        return resource;
      case SpiderErrorCode.cancelled:
        return user;
      case SpiderErrorCode.httpError:
      case SpiderErrorCode.parseError:
      case SpiderErrorCode.unsupported:
      case SpiderErrorCode.initFailed:
      case SpiderErrorCode.timeout:
        return site;
      default:
        return protocol;
    }
  }

  static bool retryable(String code) => switch (code) {
    SpiderErrorCode.timeout => true,
    SpiderErrorCode.httpError => true,
    SpiderErrorCode.crashed => true,
    SpiderErrorCode.initFailed => true,
    _ => false,
  };

  static bool userVisible(String code) =>
      code != SpiderErrorCode.unknownId && code != SpiderErrorCode.protocolViolation;
}

/// 统一错误对象（§9.3.1）。
///
/// 原始异常、敏感 URL 和凭据不得直接展示给用户，因此 [message] 只放可安全展示的
/// 文案，更多上下文放在 [details]，且写入日志前必须脱敏。
class SpiderError implements Exception {
  SpiderError({
    required this.code,
    required this.message,
    String? category,
    bool? retryable,
    bool? userVisible,
    this.siteKey,
    this.requestId,
    Map<String, Object?> details = const {},
    String? diagnosticId,
  }) : category = category ?? SpiderErrorCategory.forCode(code),
       retryable = retryable ?? SpiderErrorCategory.retryable(code),
       userVisible = userVisible ?? SpiderErrorCategory.userVisible(code),
       details = Map.unmodifiable(details),
       diagnosticId = diagnosticId ?? _newDiagnosticId();

  final String code;
  final String category;
  final String message;
  final bool retryable;
  final bool userVisible;
  final String? siteKey;
  final String? requestId;
  final Map<String, Object?> details;
  final String diagnosticId;

  static int _diagnosticCounter = 0;

  static String _newDiagnosticId() {
    _diagnosticCounter++;
    final stamp = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
    return 'diag-$stamp-$_diagnosticCounter';
  }

  factory SpiderError.fromJson(
    Object? value, {
    String? siteKey,
    String? requestId,
  }) {
    final map = value is Map ? value : const <String, Object?>{};
    final code = _string(map['code']) ?? SpiderErrorCode.protocolViolation;
    return SpiderError(
      code: code,
      message: _string(map['message']) ?? code,
      category: _string(map['category']),
      retryable: map['retryable'] is bool ? map['retryable'] as bool : null,
      userVisible: map['userVisible'] is bool ? map['userVisible'] as bool : null,
      siteKey: _string(map['siteKey']) ?? siteKey,
      requestId: _string(map['requestId']) ?? requestId,
      details: _map(map['details']),
      diagnosticId: _string(map['diagnosticId']),
    );
  }

  Map<String, Object?> toJson() => {
    'code': code,
    'category': category,
    'message': message,
    'retryable': retryable,
    'userVisible': userVisible,
    'siteKey': ?siteKey,
    'requestId': ?requestId,
    'details': details,
    'diagnosticId': diagnosticId,
  };

  /// 映射到宿主统一错误模型，供 UI 与日志复用（§8.4、§9.3.1）。
  AppError toAppError({String? detail}) => AppError(
    switch (code) {
      SpiderErrorCode.unsupported => AppErrorKind.siteUnsupported,
      SpiderErrorCode.httpError => AppErrorKind.siteHttp,
      SpiderErrorCode.parseError => AppErrorKind.siteParse,
      SpiderErrorCode.timeout => AppErrorKind.siteTimeout,
      SpiderErrorCode.cancelled => AppErrorKind.siteCancelled,
      SpiderErrorCode.badRequest => AppErrorKind.siteBusiness,
      _ => AppErrorKind.siteUnsupported,
    },
    message,
    detail: detail ?? '$code${siteKey == null ? "" : " site=$siteKey"}',
    retryable: retryable,
  );

  String get logLine =>
      '$code [$category] $message${siteKey == null ? "" : " site=$siteKey"}'
      '${requestId == null ? "" : " req=$requestId"} diag=$diagnosticId';

  @override
  String toString() => logLine;
}

/// sidecar 声明的能力（§9.7）。
///
/// 未声明 capability 的方法必须返回 [SpiderErrorCode.unsupported]（§9.7）。
class SpiderCapabilities {
  SpiderCapabilities(Iterable<String> values)
    : values = Set.unmodifiable(values.map((item) => item.trim()).where(_ok));

  final Set<String> values;

  static const Set<String> known = {
    SpiderMethod.home,
    SpiderMethod.category,
    SpiderMethod.detail,
    SpiderMethod.search,
    SpiderMethod.play,
    SpiderMethod.homeVod,
    SpiderMethod.live,
    SpiderMethod.proxy,
    SpiderMethod.action,
  };

  static bool _ok(String value) => value.isNotEmpty;

  bool supports(String method) {
    // `init`/`destroy` 是生命周期方法，不属于 capability 声明范围（§9.3）。
    if (!known.contains(method)) return true;
    return values.contains(method);
  }

  List<String> get sorted => values.toList()..sort();

  Map<String, Object?> toJson() => {'capabilities': sorted};
}

/// sidecar 申请的权限（§9.7、§18.1）。
class SpiderPermissions {
  const SpiderPermissions({
    this.network = false,
    this.localProxy = false,
    this.ui = false,
    this.storage = 'none',
    this.process = false,
    this.clipboard = false,
    this.browser = false,
  });

  final bool network;
  final bool localProxy;

  /// 设计文档 §18.1 要求 `ui` 默认禁止，因此这里只允许 false。
  final bool ui;

  /// `none` 或 `cache-only`。
  final String storage;

  /// §9.8：JS/Python/Java Spider 运行在独立子进程，不得再启动子进程。
  final bool process;
  final bool clipboard;
  final bool browser;

  static const List<String> forbidden = [
    'ui',
    'process',
    'clipboard',
    'browser',
  ];

  /// 违反硬性禁止项的权限声明（§9.7「未声明权限的能力在进程层拒绝」）。
  List<String> get violations => [
    if (ui) 'ui',
    if (process) 'process',
    if (clipboard) 'clipboard',
    if (browser) 'browser',
    if (storage != 'none' && storage != 'cache-only') 'storage=$storage',
  ];

  factory SpiderPermissions.fromJson(Object? value) {
    final map = value is Map ? value : const <String, Object?>{};
    return SpiderPermissions(
      network: map['network'] == true,
      localProxy: map['localProxy'] == true,
      ui: map['ui'] == true,
      storage: _string(map['storage']) ?? 'none',
      process: map['process'] == true,
      clipboard: map['clipboard'] == true,
      browser: map['browser'] == true,
    );
  }

  Map<String, Object?> toJson() => {
    'network': network,
    'localProxy': localProxy,
    'ui': ui,
    'storage': storage,
    'process': process,
    'clipboard': clipboard,
    'browser': browser,
  };
}

/// 每站点资源限制（§9.7、§9.8）。
class SpiderLimits {
  const SpiderLimits({
    this.memoryMiB = 256,
    this.cpuSeconds = 30,
    this.concurrency = 2,
    this.responseMiB = 8,
    this.maxFrameMiB = 16,
    this.maxStderrMiB = 4,
  });

  final int memoryMiB;
  final int cpuSeconds;
  final int concurrency;
  final int responseMiB;

  /// 单帧上限（§9.3.1「限制单帧、单响应和累计输出大小」）。
  final int maxFrameMiB;

  /// stderr 日志上限，超过后轮转（§9.3.1「日志执行大小限制、轮转」）。
  final int maxStderrMiB;

  int get memoryBytes => memoryMiB * 1024 * 1024;
  int get responseBytes => responseMiB * 1024 * 1024;
  int get maxFrameBytes => maxFrameMiB * 1024 * 1024;
  int get maxStderrBytes => maxStderrMiB * 1024 * 1024;

  SpiderLimits clamped() => SpiderLimits(
    memoryMiB: memoryMiB.clamp(16, 2048),
    cpuSeconds: cpuSeconds.clamp(1, 600),
    concurrency: concurrency.clamp(1, 8),
    responseMiB: responseMiB.clamp(1, 64),
    maxFrameMiB: maxFrameMiB.clamp(1, 64),
    maxStderrMiB: maxStderrMiB.clamp(1, 64),
  );

  factory SpiderLimits.fromJson(Object? value) {
    final map = value is Map ? value : const <String, Object?>{};
    final base = const SpiderLimits();
    return SpiderLimits(
      memoryMiB: _int(map['memoryMiB']) ?? base.memoryMiB,
      cpuSeconds: _int(map['cpuSeconds']) ?? base.cpuSeconds,
      concurrency: _int(map['concurrency']) ?? base.concurrency,
      responseMiB: _int(map['responseMiB']) ?? base.responseMiB,
      maxFrameMiB: _int(map['maxFrameMiB']) ?? base.maxFrameMiB,
      maxStderrMiB: _int(map['maxStderrMiB']) ?? base.maxStderrMiB,
    ).clamped();
  }

  Map<String, Object?> toJson() => {
    'memoryMiB': memoryMiB,
    'cpuSeconds': cpuSeconds,
    'concurrency': concurrency,
    'responseMiB': responseMiB,
    'maxFrameMiB': maxFrameMiB,
    'maxStderrMiB': maxStderrMiB,
  };
}

/// Spider manifest（§9.7）。manifest 与代码分离并可被宿主校验。
class SpiderManifest {
  SpiderManifest({
    required this.key,
    required this.name,
    required this.runtime,
    required this.entry,
    required Iterable<String> capabilities,
    SpiderPermissions? permissions,
    SpiderLimits? limits,
    this.abi = SpiderAbi.ipc,
    this.abiMinor = SpiderAbi.minor,
    this.entrySha256,
    this.signature,
  }) : capabilities = SpiderCapabilities(capabilities),
       permissions = permissions ?? const SpiderPermissions(),
       limits = (limits ?? const SpiderLimits()).clamped();

  final String abi;
  final int abiMinor;
  final String key;
  final String name;
  final String runtime;
  final String entry;
  final SpiderCapabilities capabilities;
  final SpiderPermissions permissions;
  final SpiderLimits limits;

  /// 为后续签名验证保留的字段（§9.7「不要求 MVP 实现完整签名」）。
  final String? entrySha256;
  final String? signature;

  factory SpiderManifest.fromJson(Object? value) {
    final map = value is Map ? value : const <String, Object?>{};
    return SpiderManifest(
      abi: _string(map['abi']) ?? SpiderAbi.ipc,
      abiMinor: _int(map['abiMinor']) ?? 0,
      key: _string(map['key']) ?? '',
      name: _string(map['name']) ?? '',
      runtime: _string(map['runtime']) ?? '',
      entry: _string(map['entry']) ?? '',
      capabilities: _list(map['capabilities']).map((item) => '$item'),
      permissions: SpiderPermissions.fromJson(map['permissions']),
      limits: SpiderLimits.fromJson(map['limits']),
      entrySha256: _string(
        map['hashes'] is Map ? (map['hashes'] as Map)['entrySha256'] : null,
      ),
      signature: _string(map['signature']),
    );
  }

  /// 宿主要求的最小方法集（§9.3）。
  List<String> get missingRequired =>
      SpiderMethod.required.where((m) => !capabilities.supports(m)).toList();

  /// 加载前校验（§9.3、§9.7）。
  ///
  /// 返回错误列表；非空表示该 Spider 不得加载。
  List<String> get problems => [
    if (abi != SpiderAbi.ipc) 'abi=$abi 不受支持（需要 ${SpiderAbi.ipc}）',
    if (key.isEmpty) '缺少 key',
    if (name.isEmpty) '缺少 name',
    if (entry.isEmpty) '缺少 entry',
    ...permissions.violations.map((item) => '权限 $item 被禁止'),
  ];

  Map<String, Object?> toJson() => {
    'abi': abi,
    'abiMinor': abiMinor,
    'key': key,
    'name': name,
    'runtime': runtime,
    'entry': entry,
    'capabilities': capabilities.sorted,
    'permissions': permissions.toJson(),
    'limits': limits.toJson(),
    'hashes': {'entrySha256': entrySha256 ?? ''},
    'signature': signature,
  };
}

/// `initialize` 的协商结果（§9.3.1）。
class SpiderInitResult {
  const SpiderInitResult({
    required this.abi,
    required this.abiMinor,
    required this.capabilities,
    required this.permissions,
    required this.limits,
    this.key,
    this.runtime,
  });

  final String abi;
  final int abiMinor;
  final Set<String> capabilities;
  final SpiderPermissions permissions;
  final SpiderLimits limits;
  final String? key;
  final String? runtime;

  factory SpiderInitResult.fromJson(Object? value) {
    final map = value is Map ? value : const <String, Object?>{};
    final caps = SpiderCapabilities(_list(map['capabilities']).map((c) => '$c'));
    return SpiderInitResult(
      abi: _string(map['abi']) ?? SpiderAbi.ipc,
      abiMinor: _int(map['abiMinor']) ?? 0,
      capabilities: caps.values,
      permissions: SpiderPermissions.fromJson(map['permissions']),
      limits: SpiderLimits.fromJson(map['limits']),
      key: _string(map['key']),
      runtime: _string(map['runtime']),
    );
  }

  /// major 必须一致（§9.3「major 不兼容」）。
  bool get majorCompatible => abi == SpiderAbi.ipc;
}

/// 把 ABI 名称 `webhtv-ipc-v1` 解析为 (major, minor) 语义的兼容判断。
bool abiMajorMatches(String declared, String expected) {
  final pattern = RegExp(r'^(.*)-v(\d+)$');
  final declaredMatch = pattern.firstMatch(declared);
  final expectedMatch = pattern.firstMatch(expected);
  if (declaredMatch == null || expectedMatch == null) return false;
  if (declaredMatch.group(1) != expectedMatch.group(1)) return false;
  return declaredMatch.group(2) == expectedMatch.group(2);
}

// ---------------------------------------------------------------------------
// 长度前缀帧编解码（§9.3.1）
// ---------------------------------------------------------------------------

/// 单帧超过上限时不分配内存，直接判定为资源超限。
class IpcFrameTooLarge implements Exception {
  IpcFrameTooLarge(this.declaredBytes, this.limit);

  final int declaredBytes;
  final int limit;

  @override
  String toString() =>
      'IPC 帧声明 $declaredBytes 字节，超过上限 $limit 字节';
}

/// 帧格式非法（缺少 Content-Length、头字段非法、payload 不是 UTF-8 JSON）。
class IpcFrameError implements Exception {
  IpcFrameError(this.message, {this.raw});

  final String message;

  /// 触发错误的原始片段（已截断），用于协议污染诊断。
  final String? raw;

  @override
  String toString() => 'IPC 帧非法：$message';
}

/// `Content-Length: N\r\n\r\n<payload>` 编解码器。
abstract final class IpcFrameCodec {
  static const List<int> headerSeparatorCrLf = [13, 10, 13, 10];
  static const List<int> headerSeparatorLf = [10, 10];

  static const String contentTypeHeader = 'Content-Type';
  static const String contentTypeJson = 'application/json; charset=utf-8';

  /// 编码一帧。`payload` 必须是可 JSON 编码的对象。
  static Uint8List encode(Object? payload) {
    final body = utf8.encode(jsonEncode(payload));
    final header = utf8.encode(
      'Content-Length: ${body.length}\r\n'
      '$contentTypeHeader: $contentTypeJson\r\n'
      '\r\n',
    );
    final frame = Uint8List(header.length + body.length);
    frame.setRange(0, header.length, header);
    frame.setRange(header.length, frame.length, body);
    return frame;
  }

  /// 解析单个完整帧（用于测试与一次性校验）。
  ///
  /// 抛 [IpcFrameError] 表示帧非法；抛 [IpcFrameTooLarge] 表示超过 [maxBytes]。
  static Object? decode(Uint8List frame, {required int maxBytes}) {
    final separator = _findSeparator(frame);
    if (separator == null) {
      throw IpcFrameError('缺少 Content-Length 头或空行分隔符');
    }
    final headerText = utf8.decode(
      frame.sublist(0, separator.index),
      allowMalformed: true,
    );
    final length = _parseContentLength(headerText);
    if (length > maxBytes) throw IpcFrameTooLarge(length, maxBytes);
    final bodyStart = separator.index + separator.length;
    final bodyLength = frame.length - bodyStart;
    if (bodyLength != length) {
      throw IpcFrameError('Content-Length=$length 与实际 $bodyLength 字节不一致');
    }
    return _decodeBody(frame.sublist(bodyStart));
  }

  static Object? _decodeBody(List<int> bytes) {
    String text;
    try {
      text = utf8.decode(bytes);
    } on FormatException catch (error) {
      throw IpcFrameError('payload 不是 UTF-8：${error.message}');
    }
    try {
      return jsonDecode(text);
    } on FormatException catch (error) {
      throw IpcFrameError('payload 不是 JSON：${error.message}');
    }
  }

  static int _parseContentLength(String headerText) {
    var found = false;
    var length = -1;
    for (final rawLine in headerText.split(RegExp(r'\r?\n'))) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      final colon = line.indexOf(':');
      if (colon <= 0) {
        // 允许 status line（HTTP 风格），但其他字段必须合法。
        if (RegExp(r'^HTTP/\d').hasMatch(line)) continue;
        throw IpcFrameError('头字段缺少冒号：$line');
      }
      final name = line.substring(0, colon).trim().toLowerCase();
      final value = line.substring(colon + 1).trim();
      // stdout 只承载协议帧（§9.3.1）：只接受契约定义的头字段。
      // 含冒号的非协议行（例如被写到 stdout 的 `{"note": ...}` JSON 日志）
      // 必须判定为协议污染，否则会被静默当成合法帧头而放过真实故障。
      if (name != 'content-length' && name != 'content-type') {
        throw IpcFrameError('未知头字段：$name', raw: line);
      }
      if (name == 'content-length') {
        final parsed = int.tryParse(value);
        if (parsed == null || parsed < 0) {
          throw IpcFrameError('Content-Length 不是合法整数：$value');
        }
        found = true;
        length = parsed;
      }
    }
    if (!found) throw IpcFrameError('缺少 Content-Length 头');
    return length;
  }

  static _Separator? _findSeparator(List<int> bytes) {
    for (var index = 0; index < bytes.length; index++) {
      if (bytes[index] != 10) continue;
      // 优先匹配 CRLFCRLF，避免在 \r\n 的前一个 \n 上错判为 LFLF。
      if (index >= 3 &&
          bytes[index - 1] == 13 &&
          bytes[index - 2] == 10 &&
          bytes[index - 3] == 13) {
        return _Separator(index - 3, 4);
      }
      if (index >= 1 && bytes[index - 1] == 10) {
        return _Separator(index - 1, 2);
      }
    }
    return null;
  }

  /// 从字节流中切出一个完整的长度前缀片段；不完整时返回 null。
  ///
  /// 返回结果包含帧的字节区间（含头），调用方负责移除。
  static IpcFrameSlice? slice(List<int> buffer, {required int maxBytes}) {
    final separator = _findSeparator(buffer);
    if (separator == null) return null;
    final headerText = utf8.decode(
      buffer.sublist(0, separator.index),
      allowMalformed: true,
    );
    final length = _parseContentLength(headerText);
    if (length > maxBytes) throw IpcFrameTooLarge(length, maxBytes);
    final bodyStart = separator.index + separator.length;
    if (buffer.length < bodyStart + length) return null;
    return IpcFrameSlice(bodyStart, length);
  }
}

class _Separator {
  const _Separator(this.index, this.length);

  final int index;
  final int length;
}

class IpcFrameSlice {
  const IpcFrameSlice(this.bodyStart, this.bodyLength);

  final int bodyStart;
  final int bodyLength;
}

/// 增量帧解码器：喂入任意切分的字节块，产出完整消息对象。
///
/// 用于 stdout 解析。非协议数据必须被识别为协议污染（§9.3.1）。
class IpcFrameDecoder {
  IpcFrameDecoder({required this.maxFrameBytes});

  final int maxFrameBytes;
  final List<int> _buffer = <int>[];

  /// 已丢弃的字节数（用于“累计输出大小”限制与诊断）。
  int get bufferedBytes => _buffer.length;

  /// 喂入字节块；返回本次能完整解析出的消息。
  ///
  /// 抛 [IpcFrameTooLarge]、[IpcFrameError] 时调用方必须终止当前运行时。
  List<Object?> add(List<int> chunk) {
    if (chunk.isNotEmpty) _buffer.addAll(chunk);
    final messages = <Object?>[];
    while (true) {
      final IpcFrameSlice? slice;
      try {
        slice = IpcFrameCodec.slice(_buffer, maxBytes: maxFrameBytes);
      } on IpcFrameError {
        rethrow;
      }
      if (slice == null) {
        // 没有任何空行分隔符时，如果缓冲区已经远超单帧上限，说明对端在
        // 输出非协议数据（例如把日志写到 stdout），直接判定协议污染。
        if (_buffer.length > maxFrameBytes) {
          throw IpcFrameError(
            'stdout 缓冲区超过 $_buffer.length 字节仍无合法帧头',
            raw: _previewOf(_buffer),
          );
        }
        return messages;
      }
      final bodyBytes = _buffer.sublist(
        slice.bodyStart,
        slice.bodyStart + slice.bodyLength,
      );
      final message = IpcFrameCodec._decodeBody(bodyBytes);
      messages.add(message);
      _buffer.removeRange(0, slice.bodyStart + slice.bodyLength);
    }
  }

  static String _previewOf(List<int> bytes) {
    final head = bytes.length > 120 ? bytes.sublist(0, 120) : bytes;
    return utf8.decode(head, allowMalformed: true).replaceAll('\n', r'\n');
  }
}

// ---------------------------------------------------------------------------
// 信封构造与校验（§9.5）
// ---------------------------------------------------------------------------

/// JSON-RPC 信封。
abstract final class IpcEnvelope {
  static const String version = '2.0';

  static Map<String, Object?> request({
    required String id,
    required String method,
    Map<String, Object?> params = const {},
    required int deadlineMs,
    String? traceId,
  }) => {
    'jsonrpc': version,
    'id': id,
    'method': method,
    'params': params,
    'deadlineMs': deadlineMs,
    'traceId': ?traceId,
  };

  static Map<String, Object?> success({
    required String id,
    required Object? result,
  }) => {'jsonrpc': version, 'id': id, 'result': result};

  static Map<String, Object?> failure({
    required String id,
    required SpiderError error,
  }) => {
    'jsonrpc': version,
    'id': id,
    'error': {
      'code': error.code,
      'category': error.category,
      'message': error.message,
      'retryable': error.retryable,
      'userVisible': error.userVisible,
      'details': error.details,
      'diagnosticId': error.diagnosticId,
      'siteKey': ?error.siteKey,
    },
  };

  static Map<String, Object?> cancel(String targetId) => {
    'jsonrpc': version,
    'method': SpiderMethod.cancelRequest,
    'params': {'id': targetId},
  };

  static Map<String, Object?> heartbeat(String id) => {
    'jsonrpc': version,
    'id': id,
    'method': SpiderMethod.heartbeat,
    'params': const <String, Object?>{},
  };

  /// 校验请求信封是否合法（§9.3.1）。
  static String? validateRequest(Object? value) {
    if (value is! Map) return '请求不是 JSON 对象';
    if (value['jsonrpc'] != version) return 'jsonrpc 必须是 "2.0"';
    final id = value['id'];
    if (id is! String || id.isEmpty) return 'id 必须是非空字符串';
    final method = value['method'];
    if (method is! String || method.isEmpty) return 'method 必须是非空字符串';
    if (value.containsKey('params') && value['params'] is! Map) {
      return 'params 必须是对象';
    }
    if (value.containsKey('deadlineMs')) {
      final deadline = value['deadlineMs'];
      if (deadline is! int || deadline < 1) return 'deadlineMs 必须是正整数';
    }
    return null;
  }

  /// 判断一个下游消息是成功响应还是错误响应。
  static bool isResponse(Object? value) =>
      value is Map && value.containsKey('id') && !value.containsKey('method');
}

/// 解析 [IpcFrameDecoder] 输出的一条消息为响应。
class IpcResponse {
  const IpcResponse({required this.id, this.result, this.error});

  final String id;
  final Object? result;
  final SpiderError? error;

  bool get succeeded => error == null;

  /// 从消息构造；不是响应时返回 null。
  static IpcResponse? tryParse(Object? value) {
    if (value is! Map) return null;
    final id = value['id'];
    if (id is! String || id.isEmpty) return null;
    if (value.containsKey('error')) {
      final raw = value['error'];
      final error = SpiderError.fromJson(raw, requestId: id);
      return IpcResponse(id: id, error: error);
    }
    if (!value.containsKey('result')) {
      return IpcResponse(
        id: id,
        error: SpiderError(
          code: SpiderErrorCode.protocolViolation,
          message: '响应既没有 result 也没有 error',
          requestId: id,
          userVisible: false,
        ),
      );
    }
    return IpcResponse(id: id, result: value['result']);
  }
}

// ---------------------------------------------------------------------------
// 取值工具（本文件内使用，避免依赖 protocol.dart 的模型）
// ---------------------------------------------------------------------------

String? _string(Object? value) {
  if (value is String) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
  if (value is num || value is bool) return '$value';
  return null;
}

int? _int(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim());
  return null;
}

Map<String, Object?> _map(Object? value) {
  if (value is Map) {
    return {for (final entry in value.entries) '${entry.key}': entry.value};
  }
  return const {};
}

List<Object?> _list(Object? value) {
  if (value is List) return value;
  if (value == null) return const [];
  return [value];
}
