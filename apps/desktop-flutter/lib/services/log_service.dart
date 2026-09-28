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
class LogService {
  LogService({
    this.scope,
    this.maxEntries = 500,
    this.maxFileBytes = 2 * 1024 * 1024,
    this.maxFiles = 3,
  });

  /// 日志根目录（`~/.local/state/webhtv-pc/logs` 或平台等价目录）。
  static String? logDirectoryOverride;

  final String? scope;
  final int maxEntries;
  final int maxFileBytes;
  final int maxFiles;

  final ListQueue<LogEntry> _entries = ListQueue<LogEntry>();
  final StreamController<LogEntry> _controller =
      StreamController<LogEntry>.broadcast();
  File? _file;
  bool _fileDisabled = false;

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
      _file = File('${folder.path}${Platform.pathSeparator}webhtv-pc.log');
      await _rotateIfNeeded();
    } catch (_) {
      _fileDisabled = true;
    }
  }

  Future<void> _rotateIfNeeded() async {
    final file = _file;
    if (file == null || !await file.exists()) return;
    final length = await file.length();
    if (length < maxFileBytes) return;
    // 只保留最近 maxFiles 份历史，避免日志无限增长。
    for (var index = maxFiles - 1; index >= 1; index--) {
      final older = File('${file.path}.$index');
      final newer = File('${file.path}.${index + 1}');
      if (await older.exists()) {
        if (index + 1 > maxFiles - 1) {
          await older.delete();
        } else {
          await older.rename(newer.path);
        }
      }
    }
    await file.rename('${file.path}.1');
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
    _write(entry);
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

  void _write(LogEntry entry) {
    final file = _file;
    if (file == null || _fileDisabled) return;
    try {
      file.writeAsStringSync('${entry.line}\n', mode: FileMode.append);
    } catch (_) {
      _fileDisabled = true;
    }
  }

  /// 导出为纯文本，供用户粘贴到问题报告（敏感信息已脱敏）。
  String export() => _entries.map((entry) => entry.line).join('\n');

  String exportJson() =>
      jsonEncode(_entries.map((entry) => entry.toJson()).toList());

  Future<void> dispose() async {
    await _controller.close();
  }
}
