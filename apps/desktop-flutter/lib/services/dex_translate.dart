/// dex 预转译：把 Android 站源的 `classes.dex` 在**导入期**转成桌面 JVM 可加载的
/// class jar（`docs/reference/win-box-borrowings.md` §12.6）。
///
/// 分工：
/// - 调用方是 `csp_jar_probe.dart` 的自动探测——它在判定为「可转译 dex」
///   落盘后把 [DexTranslate.run] 作为 `JarIntake.install` 的 `translateDex` 钩子注入；
/// - `jar_intake.dart` **不** import 本文件（只收结果），避免 import 环；
/// - 本文件只负责「起一次 CLI + 解析一行 JSON」，不做任何可用性判定/文案。
///
/// 进程契约（固定，见 `sidecars/spider-host-jvm/src/webhtv/spider/DexIntakeCli.java`）：
/// `java -cp "host.jar;lib/*" webhtv.spider.DexIntakeCli --site <站点目录> [--archive <jar>]`；
/// stdout **恰好一行** UTF-8 JSON（成功 `ok:true`，失败 `ok:false` + `stage` + `message`），
/// stderr 是人类日志（UTF-8），退出码 0 成功 / 1 失败。
///
/// 纪律：[run] **任何路径都不抛异常**——它是导入期的注入点，抛出去会让整次导入失败，
/// 而「转译失败」本身只是一条需要如实上报的结论。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'log_service.dart';
import 'spider_registry.dart';

/// 预转译服务（无状态；同一站点目录重复调用是幂等的，命中缓存时很快）。
class DexTranslate {
  const DexTranslate._();

  /// 整体上限。首次转译实测约 4.6 s、缓存命中约 0.4 s；120 s 只兜住
  /// 「dex2jar 遇到畸形 dex 卡住」这类情况，绝不让导入无限等。
  static const Duration timeout = Duration(seconds: 120);

  /// stderr 日志只保留**尾部**这么多字符：CLI 会打大量人类日志，整段塞进日志会
  /// 淹掉真正的原因，也撑爆日志文件。
  static const int stderrTailChars = 2000;

  /// 失败提示里保留的 stdout 前缀长度。
  static const int stdoutHeadChars = 200;

  /// 起一次预转译，返回 CLI 的结论（成功与失败的 Map 形态见文件头契约）。
  ///
  /// [siteDir] 必须已存在（CLI 在读取阶段就会校验）；[archive] 缺失/不存在时
  /// 由 CLI 如实报 `stage: 'dex-读取'`。
  static Future<Map<String, Object?>> run({
    required String siteDir,
    required String archive,
    LogService? log,
  }) async {
    try {
      final probe = LocalSpiderCommand.probeJavaRuntime(log: log);
      final java = probe.command;
      if (java == null) {
        return <String, Object?>{
          'ok': false,
          'stage': 'dex-读取',
          'message':
              '未找到可用 Java 运行时（需要 JDK/JRE 17+）：'
              '${probe.issue ?? '原因未知'}',
        };
      }

      final hostJar = defaultJvmSidecarHostPath();
      if (hostJar.isEmpty || !File(hostJar).existsSync()) {
        return <String, Object?>{
          'ok': false,
          'stage': 'dex-读取',
          'message': '未找到 spider-host-jvm/host.jar',
        };
      }

      // `lib/*` 的通配符由 **JVM 自己**展开（`<dir>\*` 是 JVM 的类路径语法），
      // 这里只拼路径、不枚举 jar：lib 里有近 20 个第三方依赖，枚举会随版本漂移。
      final separator = Platform.isWindows ? ';' : ':';
      final classpath = <String>[
        hostJar,
        p.join(p.dirname(hostJar), 'lib', '*'),
      ].join(separator);

      final process = await Process.start(java.executable, <String>[
        // 堆参数等必须在 -cp 之前（JVM 自己的选项，不能跑到类名后面）。
        ...java.arguments,
        '-cp',
        classpath,
        'webhtv.spider.DexIntakeCli',
        '--site',
        siteDir,
        '--archive',
        archive,
      ]);

      // stderr 与 stdout 必须**同时**读：任一管道写满就会把子进程堵死，
      // 表现为「看起来在转译、其实谁也没动」。
      final stderrTail = _collectStderrTail(process.stderr);
      String stdoutText;
      int exitCode;
      try {
        stdoutText = await process.stdout
            .transform(utf8.decoder)
            .join()
            .timeout(timeout);
        exitCode = await process.exitCode.timeout(const Duration(seconds: 10));
      } on TimeoutException {
        process.kill();
        return <String, Object?>{
          'ok': false,
          'stage': 'dex-转译',
          'message': '预转译超时（>${timeout.inSeconds}s）',
        };
      }

      final stderrText = await stderrTail.timeout(
        const Duration(seconds: 5),
        onTimeout: () => '',
      );
      if (stderrText.trim().isNotEmpty) {
        log?.info(
          'dex 预转译日志（exit=$exitCode，stderr 尾 $stderrTailChars 字）：$stderrText',
          scope: 'spider',
        );
      }

      final decoded = _decodeLastLine(stdoutText);
      if (decoded != null) {
        // 退出码非 0 时**以 JSON 为准**：CLI 的失败路径就是 ok:false + stage，
        // 那比退出码本身信息量大得多。
        return decoded;
      }
      // 退出码 0 但没有可解析的 JSON：绝不能当成功——落盘/缓存状态未知。
      return <String, Object?>{
        'ok': false,
        'stage': 'dex-转译',
        'message':
            '预转译输出无法解析：'
            '${_head(stdoutText, stdoutHeadChars)}',
      };
    } catch (error) {
      // 注入点的最终兜底：异常一律转成结论，不让导入因转译崩掉。
      return <String, Object?>{'ok': false, 'stage': '', 'message': '$error'};
    }
  }

  /// 只保留 stderr 的尾部；超过 4 倍上限时随手裁掉前半，避免无限增长。
  static Future<String> _collectStderrTail(Stream<List<int>> stream) async {
    var text = '';
    try {
      await for (final chunk in stream.transform(utf8.decoder)) {
        text += chunk;
        if (text.length > stderrTailChars * 4) {
          text = _suffix(text, stderrTailChars);
        }
      }
    } catch (_) {
      // 进程被杀或输出不是合法 UTF-8：日志缺失不影响结论。
    }
    return _suffix(text, stderrTailChars);
  }

  /// 取 stdout **最后一行非空**内容解析成 Map。不可解析时返回 null。
  static Map<String, Object?>? _decodeLastLine(String text) {
    for (final line in const LineSplitter().convert(text).reversed) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is Map) return Map<String, Object?>.from(decoded);
      } catch (_) {}
      // 契约规定 stdout 只有一行 JSON：最后一行非空却不是 JSON，就是没拿到结论，
      // 不要再去翻更早的行（那是第三方库的噪音，猜错了比报错更糟）。
      return null;
    }
    return null;
  }

  static String _suffix(String text, int limit) =>
      text.length <= limit ? text : text.substring(text.length - limit);

  static String _head(String text, int limit) =>
      text.length <= limit ? text : text.substring(0, limit);
}
