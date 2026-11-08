/// 结构化日志与脱敏（§9.3.1、§11.3.1、§17.2 日志页、§18.2）。
///
/// 约束：
/// - 日志默认不记录 Cookie、Authorization、完整 query 和媒体签名；
/// - stdout 不属于日志通道，日志写入状态目录并按大小轮转；
/// - 日志页展示的是同一份内存视图，方便用户复制诊断信息。
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import '../core/protocol.dart';

enum LogLevel { debug, info, warning, error }

class LogEntry {
  const LogEntry({
    required this.time,
    required this.level,
    required this.scope,
    required this.message,
  });

  final DateTime time;
  final LogLevel level;
  final String scope;
  final String message;

  String get line =>
      '${time.toIso8601String()} ${level.name.toUpperCase().padRight(5)} '
      '[$scope] $message';

  Map<String, Object?> toJson() => {
    'time': time.toIso8601String(),
    'level': level.name,
    'scope': scope,
    'message': message,
  };
}

/// 日志服务：内存环形缓冲 + 文件轮转。
///
/// **落盘策略：内存即时、文件异步批量**（性能缺陷修复 2026-10-12）。
///
/// 早期实现每条日志都 `writeAsStringSync(mode: append)`。实测（本机 Windows，
/// Dart 3.13.4）**单条同步追加约 8.5ms**：站点选择器打开时写入 170 条站点明细
/// 就要 **1.45 秒**，真实日志里 21 次点击全部落在 1.28~2.44s —— 这正是用户
/// 反馈的「点击选择站点每次都会卡一会」。
///
/// 为什么慢：Windows 上每次 `FileMode.append` 都要重新打开文件、定位到末尾、
/// 写入并关闭；170 次开关文件的系统调用开销远大于 28KB 数据本身（一次性追加
/// 同一批内容只需 1ms）。
///
/// 因此：[log] 只做内存操作（环形缓冲 + 广播流），文件写入进队列、由**单次**
/// 定时器按批追加。约束：
/// - 首条日志用 0 延迟定时器立即刷出，日志的**时效性**不退化；
/// - 批次内只开一次文件、一次 `flush: true`，等价于「攒批 + 原子落盘」；
/// - 刷盘是**同步**的（单批只 1ms）：不给进程留悬空的异步文件句柄，
///   否则退出/删目录时会出现 `OS Error 32 另一个程序正在使用此文件`
///   （`AppState.dispose()` 不等待异步写入，测试的 `tearDown` 紧接着删目录）；
/// - 与 `LogsPage` 刷新、进程退出、日志轮转的可见性约定见 [flush] / [dispose]；
/// - 写失败与早期一致：`_fileDisabled = true`，静默降级为纯内存日志。
class LogService {
  LogService({
    this.scope,
    this.maxEntries = 500,
    this.maxFileBytes = standardMaxFileBytes,
    this.maxFiles = 3,
  });

  /// 常规单文件上限（2MB）：详细调试日志关闭时的档位。
  static const int standardMaxFileBytes = 2 * 1024 * 1024;

  /// 详细调试日志打开时的单文件上限（20MB）。
  ///
  /// 入参/出参全量打印后 2MB 会被几小时内轮转掉，排查现场时正好缺那一段。
  static const int verboseMaxFileBytes = 20 * 1024 * 1024;

  /// 详细调试日志开关对应的档位值（单测按此断言档位）。
  static int maxFileBytesFor({required bool verbose}) =>
      verbose ? verboseMaxFileBytes : standardMaxFileBytes;

  /// 日志根目录（`~/.local/state/webhtv-pc/logs` 或平台等价目录）。
  static String? logDirectoryOverride;

  final String? scope;
  final int maxEntries;

  /// 单文件上限（字节）。
  ///
  /// 可变：详细调试日志开关在运行中切换档位。已打开的文件句柄不重建，
  /// 下一次 [_rotateIfNeeded] 判断才用新档位，因此切换无需重启。
  int maxFileBytes;

  final int maxFiles;

  final ListQueue<LogEntry> _entries = ListQueue<LogEntry>();
  final StreamController<LogEntry> _controller =
      StreamController<LogEntry>.broadcast();
  File? _file;
  String? _directory;
  bool _fileDisabled = false;

  /// 待落盘的行（不含换行符）。
  final List<String> _pending = <String>[];
  Timer? _flushTimer;

  Stream<LogEntry> get stream => _controller.stream;

  List<LogEntry> get entries => List.unmodifiable(_entries);

  /// 打开日志文件。失败不阻塞应用启动（§16.3 “数据库异常不影响播放器启动”
  /// 的同类原则：诊断设施不得成为启动阻断项）。
  Future<void> open([String? directory]) async {
    final dir = directory ?? logDirectoryOverride;
    if (dir == null) return;
    try {
      final folder = Directory(dir);
      if (!await folder.exists()) {
        await folder.create(recursive: true);
      }
      _directory = folder.path;
      _file = File('${folder.path}${Platform.pathSeparator}webhtv-pc.log');
      await _rotateIfNeeded();
      flush();
    } catch (_) {
      _fileDisabled = true;
    }
  }

  Future<void> _rotateIfNeeded() async {
    final file = _file;
    if (file == null || !await file.exists()) return;
    final length = await file.length();
    if (length < maxFileBytes) return;
    _rotateSync(file);
  }

  /// 本批追加后将超过当前档位就先轮转（`flush()` 的运行期判断入口）。
  ///
  /// 为什么运行期也必须判断：`open()` 只在启动时判一次，而详细调试日志会在
  /// 运行中把文件写大——没有调用点就等于「单份上限」这个语义失效（文件无限增长）。
  ///
  /// 读长度失败按 0 处理：读不到就当不需要轮转，绝不能因此丢掉本条日志。
  void _rotateIfFullSync(File file, int incomingBytes) {
    var length = 0;
    try {
      if (file.existsSync()) length = file.lengthSync();
    } catch (_) {
      return;
    }
    if (length + incomingBytes <= maxFileBytes) return;
    _rotateSync(file);
  }

  /// 同步轮转：`.1` 最旧、按索引滚动，保留 [maxFiles] 份（含主文件）。
  ///
  /// 与异步路径共用同一套滚动规则，避免两份实现分叉。失败时**不抛**：
  /// 轮转失败也要能照常追加，日志可以变大但不可以丢。
  void _rotateSync(File file) {
    try {
      // 只保留最近 maxFiles 份历史，避免日志无限增长。
      for (var index = maxFiles - 1; index >= 1; index--) {
        final older = File('${file.path}.$index');
        final newer = File('${file.path}.${index + 1}');
        if (!older.existsSync()) continue;
        if (index + 1 > maxFiles - 1) {
          older.deleteSync();
        } else {
          older.renameSync(newer.path);
        }
      }
      file.renameSync('${file.path}.1');
    } catch (_) {
      // 轮转失败时继续追加：上限失守好过丢日志。
    }
  }

  void log(LogLevel level, String message, {String? scope}) {
    final entry = LogEntry(
      time: DateTime.now(),
      level: level,
      scope: scope ?? this.scope ?? 'app',
      message: message,
    );
    _entries.addLast(entry);
    while (_entries.length > maxEntries) {
      _entries.removeFirst();
    }
    if (!_controller.isClosed) _controller.add(entry);
    _enqueue(entry.line);
  }

  void debug(String message, {String? scope}) =>
      log(LogLevel.debug, message, scope: scope);

  void info(String message, {String? scope}) =>
      log(LogLevel.info, message, scope: scope);

  void warning(String message, {String? scope}) =>
      log(LogLevel.warning, message, scope: scope);

  void error(String message, {String? scope}) =>
      log(LogLevel.error, message, scope: scope);

  /// 记录 HTTP 请求摘要（不含 Cookie / Authorization / 完整 query）。
  void httpRequest({
    required String method,
    required String url,
    Map<String, String> headers = const {},
    int? statusCode,
    Duration? elapsed,
    String? siteKey,
    String? note,
  }) {
    final parts = <String>[
      method,
      redactUrl(url),
      if (statusCode != null) 'status=$statusCode',
      if (elapsed != null) 'elapsed=${elapsed.inMilliseconds}ms',
      if (siteKey != null) 'site=$siteKey',
      if (headers.isNotEmpty) 'headers={${redactHeadersForLog(headers)}}',
      ?note,
    ];
    final level = statusCode != null && statusCode >= 400
        ? LogLevel.warning
        : LogLevel.debug;
    log(level, parts.join(' '), scope: 'http');
  }

  /// 入队一行并安排刷盘。
  ///
  /// 首条（队列原本为空）用 0 延迟：日志落盘的**时效性**与逐条同步写一致，
  /// 验收脚本轮询日志文件、排查播放问题时不必等一个批次周期。
  void _enqueue(String line) {
    if (_file == null || _fileDisabled) return;
    _pending.add(line);
    if (_flushTimer != null) return;
    _flushTimer = Timer(
      _pending.length == 1 ? Duration.zero : _flushDelay,
      flush,
    );
  }

  /// 批次间隔：把连续产生的日志合并成一次文件追加。
  static const Duration _flushDelay = Duration(milliseconds: 200);

  /// 把待落盘日志一次性追加到文件。
  ///
  /// 同批只做一次「打开 → 追加 → 关闭」，这是性能修复的核心：实测 170 行
  /// 一次性追加 1ms，逐条追加 1452ms。
  ///
  /// 用**同步**写入而不是 `writeAsString`：单批成本已降到 1ms 量级，而异步写会
  /// 在进程退出/删目录时留下未完成的文件句柄（Windows 报 OS Error 32）。
  ///
  /// 取消在途定时器：定时器只负责「触发」，真正的刷盘动作由这里统一收口，
  /// 否则 `dispose()`/显式 `flush()` 与定时器会并发写同一批行。
  void flush() {
    _flushTimer?.cancel();
    _flushTimer = null;
    final file = _file;
    if (file == null || _fileDisabled) return;
    if (_pending.isEmpty) return;
    final batch = '${_pending.join('\n')}\n';
    _pending.clear();
    try {
      // 把本批 UTF-8 字节也算进去，避免既有文件未满却被一次追加推过档位。
      _rotateIfFullSync(file, utf8.encode(batch).length);
      // `flush: true` 保证数据已交给操作系统，进程被强杀时日志不丢。
      file.writeAsStringSync(batch, mode: FileMode.append, flush: true);
    } catch (_) {
      _fileDisabled = true;
    }
  }

  /// 导出为纯文本，供用户粘贴到问题报告（敏感信息已脱敏）。
  String export() => _entries.map((entry) => entry.line).join('\n');

  String exportJson() =>
      jsonEncode(_entries.map((entry) => entry.toJson()).toList());

  /// 日志落盘目录；`open()` 之前或目录不可用时为 null。
  String? get directory => _directory;

  /// 轮转历史文件，**旧 → 新**（`.3` 最旧、主文件最新）。
  List<File> _rotatedFiles(File file) => [
    for (var index = maxFiles - 1; index >= 1; index--)
      File('${file.path}.$index'),
  ];

  /// 汇总全部落盘日志（轮转历史 + 主文件，旧 → 新）。
  ///
  /// 文件不可用时退回内存视图（`export()`），保证「下载」永远有内容可给。
  Future<String> readPersisted() async {
    flush();
    final file = _file;
    if (file == null || _fileDisabled) return export();
    final buffer = StringBuffer();
    for (final rotated in _rotatedFiles(file)) {
      if (await rotated.exists()) buffer.write(await rotated.readAsString());
    }
    if (await file.exists()) buffer.write(await file.readAsString());
    final text = buffer.toString();
    return text.isEmpty ? export() : text;
  }

  /// 把全部日志写到 [directory] 下的新文件，返回该文件。
  ///
  /// 文件名默认 `webhtv-pc-<yyyyMMdd-HHmmss>.log`（与备份文件同一口径），
  /// 内容与日志页展示的同一份脱敏日志一致（§18.2）。
  Future<File> exportToDirectory(String directory, {String? fileName}) async {
    final text = await readPersisted();
    final folder = Directory(directory);
    if (!await folder.exists()) {
      await folder.create(recursive: true);
    }
    final target = File(
      '${folder.path}${Platform.pathSeparator}'
      '${fileName ?? 'webhtv-pc-${_stamp(DateTime.now())}.log'}',
    );
    await target.writeAsString(text, flush: true);
    return target;
  }

  static String _stamp(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.year}${two(time.month)}${two(time.day)}'
        '-${two(time.hour)}${two(time.minute)}${two(time.second)}';
  }

  /// 清理日志：丢弃待落盘队列、删除落盘文件（含轮转历史）、清空内存环形缓冲。
  ///
  /// 保留 `_file` 句柄：清理后继续产生的新日志照常落盘（下一次 `flush()` 会
  /// 重新创建文件）。删除失败才降级为纯内存日志。
  Future<void> clear() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    _pending.clear();
    _entries.clear();
    final file = _file;
    if (file == null) return;
    try {
      for (final rotated in _rotatedFiles(file)) {
        if (await rotated.exists()) await rotated.delete();
      }
      if (await file.exists()) await file.delete();
    } catch (_) {
      _fileDisabled = true;
    }
  }

  Future<void> dispose() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    flush();
    await _controller.close();
  }
}
