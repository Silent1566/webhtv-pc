/// 启动阶段追踪（§20.3 启动日志、§22.2 冷启动指标）。
///
/// §22.2 要求“从进程启动到首个可交互主界面”可测量、可复查，因此这里按顺序记录每个
/// 阶段的单调时间戳，而不是只给一个总数：只有分阶段数据才能区分“Dart 引导慢”和
/// “首帧渲染慢”。
///
/// 用法：
/// - `--startup-trace=<path>`：把阶段行写入文件，供验收脚本读取；
/// - 无论是否给出路径，阶段汇总都会进入应用日志的 `startup` 作用域。
library;

import 'dart:io';

/// 启动阶段记录器。
class StartupTrace {
  StartupTrace._();

  /// 进程内单调计时器。使用 [Stopwatch] 而不是墙钟，避免系统时间调整影响测量。
  static final Stopwatch _stopwatch = Stopwatch()..start();

  static final List<(String stage, int milliseconds)> _marks = [];

  /// 追踪文件路径；为空时只写日志。
  static String? sinkPath;

  /// 记录一个阶段。
  static void mark(String stage) {
    final milliseconds = _stopwatch.elapsedMilliseconds;
    _marks.add((stage, milliseconds));
    _writeLine('startup-trace $stage=${milliseconds}ms');
  }

  /// 阶段汇总，形如 `entry=0ms first-frame=612ms`。
  static String get summary =>
      _marks.map((mark) => '${mark.$1}=${mark.$2}ms').join(' ');

  static int? stageMilliseconds(String stage) {
    for (final mark in _marks) {
      if (mark.$1 == stage) return mark.$2;
    }
    return null;
  }

  /// 写出当前全部阶段（每次 mark 都会追加，保证进程被强杀时仍有数据）。
  static void _writeLine(String line) {
    final path = sinkPath;
    if (path == null || path.isEmpty) return;
    try {
      File(path).writeAsStringSync(
        '${DateTime.now().toIso8601String()} $line\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      // 追踪写入失败不能影响启动。
    }
  }
}
