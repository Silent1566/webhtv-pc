/// 命令行启动参数：纯数据 + 解析，不依赖 Flutter widget 层。
///
/// 为什么单独成文件：`AppShell` 与测试都要构造它，而它此前住在 `app.dart`——
/// 只为拿一个启动参数对象就得 import 整个 UI 外壳。
library;

import '../services/external_player.dart';

/// 命令行为参数，供冒烟验证与自动化使用：
/// - `--media=<url>`：启动后直接播放指定地址（本地路径见下一条）；
/// - `<绝对路径>`：裸参数形式的本地视频文件——把文件拖到可执行文件上就是这个
///   形态，Windows 会把拖入的文件路径作为唯一参数传进来；
/// - `--config=<path|url|json>`：启动后自动导入配置；
/// - `--fullscreen=true`：启动即全屏；
/// - `--screenshot-ready-file=<path>`：主界面可交互后写入标记文件，供外部脚本等待。
class StartupArguments {
  const StartupArguments({
    this.media,
    this.mediaIsLocal = false,
    this.config,
    this.fullscreen = false,
    this.readyFile,
    this.headers = const {},
    this.seekSeconds,
    this.traceFile,
  });

  final String? media;

  /// [media] 是本地文件路径而不是远程地址（决定构造哪种播放请求）。
  final bool mediaIsLocal;

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
    String? barePath;
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
      } else if (!argument.startsWith('--') &&
          ExternalPlayers.isLocalFilePath(argument)) {
        // 裸绝对路径（拖动文件到 exe）也当媒体；只认绝对路径，免得把
        // `flutter test test/foo_test.dart` 这类相对参数误当成待播文件。
        barePath ??= argument;
      }
    }
    media ??= barePath;
    return StartupArguments(
      media: media,
      mediaIsLocal: media != null && ExternalPlayers.isLocalFilePath(media),
      config: config,
      fullscreen: fullscreen,
      readyFile: readyFile,
      headers: headers,
      seekSeconds: seek,
      traceFile: traceFile,
    );
  }
}
