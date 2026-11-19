/// 命令行启动参数：纯数据 + 解析，不依赖 Flutter widget 层。
///
/// 为什么单独成文件：`AppShell` 与测试都要构造它，而它此前住在 `app.dart`——
/// 只为拿一个启动参数对象就得 import 整个 UI 外壳。
library;

/// 命令行为参数，供冒烟验证与自动化使用：
/// - `--media=<url>`：启动后直接播放指定地址；
/// - `--config=<path|url|json>`：启动后自动导入配置；
/// - `--fullscreen=true`：启动即全屏；
/// - `--screenshot-ready-file=<path>`：主界面可交互后写入标记文件，供外部脚本等待。
class StartupArguments {
  const StartupArguments({
    this.media,
    this.config,
    this.fullscreen = false,
    this.readyFile,
    this.headers = const {},
    this.seekSeconds,
    this.traceFile,
  });

  final String? media;
  final String? config;
  final bool fullscreen;
  final String? readyFile;
  final Map<String, String> headers;
  final double? seekSeconds;

  /// `--startup-trace=<path>`：启动阶段追踪输出文件。
  final String? traceFile;

  static StartupArguments parse(List<String> arguments) {
    String? media;
    String? config;
    String? readyFile;
    String? traceFile;
    var fullscreen = false;
    double? seek;
    final headers = <String, String>{};
    for (final argument in arguments) {
      if (argument.startsWith('--media=')) {
        media = argument.substring('--media='.length);
      } else if (argument.startsWith('--config=')) {
        config = argument.substring('--config='.length);
      } else if (argument.startsWith('--screenshot-ready-file=')) {
        readyFile = argument.substring('--screenshot-ready-file='.length);
      } else if (argument.startsWith('--startup-trace=')) {
        traceFile = argument.substring('--startup-trace='.length);
      } else if (argument.startsWith('--header=')) {
        final header = argument.substring('--header='.length);
        final separator = header.indexOf(':');
        if (separator > 0) {
          headers[header.substring(0, separator).trim()] = header
              .substring(separator + 1)
              .trim();
        }
      } else if (argument.startsWith('--seek=')) {
        seek = double.tryParse(argument.substring('--seek='.length));
      } else if (argument == '--fullscreen=true') {
        fullscreen = true;
      }
    }
    return StartupArguments(
      media: media,
      config: config,
      fullscreen: fullscreen,
      readyFile: readyFile,
      headers: headers,
      seekSeconds: seek,
      traceFile: traceFile,
    );
  }
}
