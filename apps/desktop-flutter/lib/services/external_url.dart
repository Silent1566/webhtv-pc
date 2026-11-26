/// 相关视频外链的系统浏览器启动（`04` §7.2）。
///
/// Windows 使用 ShellExecuteW，Linux 使用 xdg-open，macOS 使用 /usr/bin/open。
/// 只接受合法 http(s) 地址，作为独立参数交给系统默认浏览器。
library;

import 'dart:async';
import 'dart:io';

import 'windows_shell_open.dart';

/// 成功表示已交给操作系统，不代表浏览器已加载页面。
class ExternalUrlOpenResult {
  const ExternalUrlOpenResult.success() : ok = true, error = null;

  const ExternalUrlOpenResult.failure(this.error) : ok = false;

  final bool ok;
  final String? error;
}

/// 用系统默认浏览器打开外链。
abstract final class ExternalUrl {
  /// [operatingSystem]、[starter]、[shellOpen] 可注入，便于测试平台交接。
  static Future<ExternalUrlOpenResult> open(
    String url, {
    String? operatingSystem,
    Future<Process> Function(String executable, List<String> arguments)?
    starter,
    int Function(String url)? shellOpen,
  }) async {
    final target = url.trim();
    final uri = Uri.tryParse(target);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty ||
        uri.port > 65535 ||
        RegExp(r'[\s\x00-\x1f\x7f\\]|%(?![0-9a-fA-F]{2})').hasMatch(target)) {
      return const ExternalUrlOpenResult.failure('当前地址不是合法 http(s)，无法打开');
    }
    final os = operatingSystem ?? Platform.operatingSystem;
    if (os == 'windows') {
      try {
        final code = (shellOpen ?? windowsShellOpen)(target);
        if (code > 32) return const ExternalUrlOpenResult.success();
        final reason = switch (code) {
          0 => '内存或系统资源不足',
          5 => '系统拒绝访问',
          31 => '未关联默认浏览器',
          _ => '系统无法打开链接',
        };
        return ExternalUrlOpenResult.failure('浏览器启动失败：$reason（错误码 $code）');
      } catch (error) {
        return ExternalUrlOpenResult.failure('打开外部链接失败：$error');
      }
    }
    final String executable;
    if (os == 'linux') {
      executable = 'xdg-open';
    } else if (os == 'macos') {
      executable = '/usr/bin/open';
    } else {
      return ExternalUrlOpenResult.failure('当前平台不支持打开浏览器：$os');
    }
    try {
      final process =
          await (starter ??
              (executable, arguments) => Process.start(
                executable,
                arguments,
                mode: ProcessStartMode.normal,
              ))(executable, [target]);
      final stdout = process.stdout.listen((_) {});
      final stderr = process.stderr.listen((_) {});
      try {
        final exitCode = await process.exitCode.timeout(
          const Duration(seconds: 5),
          onTimeout: () {
            process.kill();
            throw TimeoutException('浏览器启动命令超时');
          },
        );
        if (exitCode != 0) {
          return ExternalUrlOpenResult.failure('浏览器启动命令失败：退出码 $exitCode');
        }
        return const ExternalUrlOpenResult.success();
      } finally {
        unawaited(stdout.cancel());
        unawaited(stderr.cancel());
      }
    } catch (error) {
      return ExternalUrlOpenResult.failure('打开外部链接失败：$error');
    }
  }
}
