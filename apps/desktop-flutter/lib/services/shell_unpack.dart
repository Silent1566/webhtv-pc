/// 加固壳解包：把一个「壳 jar」通过 unidbg 运行时解出可转译的 payload jar。
///
/// 分工（与 `dex_translate.dart` 同形）：
/// - 调用方是 `csp_jar_probe.dart`：它把 [ShellUnpack.run] 作为 `shellUnpack` 注入，
///   并负责 payload 的缓存、二次判定与落盘；
/// - `jar_intake.dart` **不** import 本文件（只收结论），避免 import 环；
/// - 本文件只负责「起一次 CLI + 解析一行 JSON」，不做任何可用性判定/文案。
///
/// 进程契约（固定，见 `sidecars/spider-host-jvm/shell-unpack/ShellUnpack.java`）：
/// 命令形如 `java -cp 解包运行时目录/* sidecar目录/shell-unpack/ShellUnpack.java
/// --shell 壳jar --out payload.jar [--work 工作目录] [--timeout 秒]`，
/// stdout **恰好一行** JSON：
/// 成功 `ok:true` + `payload/sha256/bytes/recipe/asset/elapsedMs`，失败 `ok:false` +
/// `stage` + `message`；stderr 是人类日志；退出码 0 成功 / 1 失败。
///
/// 进度（同一个 stderr，行首是标记，与人话日志互不影响）：
/// `[progress] <stageIndex>/7 <stage>`，由 [run] 边读边解析成 [ShellUnpackProgress]
/// 并回调 `onProgress`；解析失败只是少一条进度事件，**绝不**影响返回值。
///
/// 纪律：[run] **任何路径都不抛异常**——它是导入期的注入点，抛出去会让整次导入失败，
/// 而「解包失败」本身只是一条需要如实上报的结论（含**失败阶段**）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'log_service.dart';
import 'spider_registry.dart';

/// 一次解包所处的阶段（[ShellUnpack.run] 的 `onProgress` 事件体）。
///
/// 之所以只有这四个字段：UI 侧的「进度条 + 预计剩余时间」只需要阶段名、阶段序号、
/// 总阶段数和加权进度；把时间戳塞进来会让 ETA 的时钟基准分散到两处。
class ShellUnpackProgress {
  const ShellUnpackProgress({
    required this.stage,
    required this.stageIndex,
    required this.stageCount,
    required this.fraction,
  });

  /// 七个阶段之一（名字与 CLI 的 `STAGES` 一字不差）。
  final String stage;

  /// 0-based 阶段序号。
  final int stageIndex;

  /// 固定 7。
  final int stageCount;

  /// 0..1，按 [ShellUnpack.stageWeights] 加权累加的进度。
  final double fraction;

  @override
  String toString() =>
      'ShellUnpackProgress($stage $stageIndex/$stageCount '
      '${(fraction * 100).toStringAsFixed(0)}%)';
}

/// 一次解包调用的命令行（注入 [ShellUnpackRunner] 时的输入）。
///
/// 单测只断言这个结构：既验证了「`-cp` 用 unidbg 通配符、源码模式类名、
/// `--timeout` 用 180」，也不必真的起 java。
class ShellUnpackInvocation {
  const ShellUnpackInvocation({
    required this.executable,
    required this.arguments,
    required this.timeout,
    this.onStderrLine,
    this.cancelled,
  });

  final String executable;
  final List<String> arguments;
  final Duration timeout;
  final Future<void>? cancelled;

  /// 子进程 stderr 的**逐行**入口：真进程边读边回调，注入的假 runner 直接调它。
  ///
  /// 之所以挂在 invocation 上、而不是给 [ShellUnpackRunner] 加可选参数：那个 typedef
  /// 是别人正在实现的函数类型，加参数等于逼所有实现改签名；把出口放在入参里，
  /// 假 runner 一句 `invocation.onStderrLine?.call(line)` 就能播进度。
  final void Function(String line)? onStderrLine;
}

/// 子进程的三样输出（stdout / stderr / 退出码）。
class ShellUnpackOutput {
  const ShellUnpackOutput({
    required this.stdout,
    required this.stderr,
    required this.exitCode,
  });

  final String stdout;
  final String stderr;
  final int exitCode;
}

/// 进程抽象：缺省真的 `Process.start`；单测注入假实现（不联网、不起 java）。
typedef ShellUnpackRunner = Future<ShellUnpackOutput> Function(
  ShellUnpackInvocation invocation,
);

/// 加固壳解包服务（无状态；同一壳 jar 的重复解包由调用方按 SHA-256 缓存）。
class ShellUnpack {
  const ShellUnpack._();

  /// 整体上限，同时作为 CLI 的 `--timeout`。
  ///
  /// 解包要起 unidbg 的 ARM 模拟器并跑壳的 native 初始化，实测远慢于 dex 预转译；
  /// 180 s 只兜住「壳卡死」这类情况，绝不让导入无限等。
  static const Duration timeout = Duration(seconds: 180);

  /// stderr 只保留**尾部**这么多字符：CLI 会打大量人类日志。
  static const int stderrTailChars = 2000;

  /// 失败提示里保留的 stdout 前缀长度。
  static const int stdoutHeadChars = 400;

  /// 七个阶段的名字（顺序即进度顺序，与 Java 侧 `STAGES` 一字不差）。
  static const List<String> stages = <String>[
    'shell-读取',
    'recipe-识别',
    'emulator-启动',
    'native-注册',
    '解包-调用',
    'payload-校验',
    'payload-落盘',
  ];

  /// 每个阶段占的整体权重（与 [stages] 同序，合计 1.0）。
  ///
  /// 权重不是均分：起模拟器与跑 native 解包才是 180 s 里的绝大部分墙钟时间，
  /// 按阶段数平均会让进度条在这两段里骗人。
  static const List<double> stageWeights = <double>[
    0.05, // 读壳
    0.05, // 认配方
    0.25, // 起模拟器
    0.15, // 注册 native
    0.40, // 调 getLoader 解包
    0.05, // 校验 payload
    0.05, // 落盘
  ];

  /// 阶段总数（CLI 进度行的分母，契约固定 7）。
  static const int stageCount = 7;

  /// 进度行的行首标记（Java 侧 `System.err.println("[progress] ...")` 的原文对齐）。
  static const String progressPrefix = '[progress] ';

  /// 进入 [stageIndex] 阶段时的加权进度（含该阶段权重，0..1）。
  ///
  /// 含当前阶段而不是「只算已完成的阶段」：`elapsed / fraction` 是 ETA 最直白的算法，
  /// 首个事件若给 0 就会除零；而真到「落盘」时重活早已做完，报满比报 0.95 更贴近体感。
  /// 真正的 100% 由调用方拿到 `ok:true` 时收尾，不靠进度事件。
  static double fractionAt(int stageIndex) {
    var sum = 0.0;
    for (var i = 0; i <= stageIndex && i < stageWeights.length; i++) {
      sum += stageWeights[i];
    }
    return sum > 1.0 ? 1.0 : sum;
  }

  /// 失败阶段（与 CLI 契约同一套词）：模拟器起不来。
  static const String stageEmulator = 'emulator-启动';

  /// 失败阶段：CLI 调用本身失败（找不到 CLI / 超时 / 输出不可解析）。
  static const String stageInvoke = '解包-调用';

  /// 起一次解包，返回 CLI 的结论（成功与失败的 Map 形态见文件头契约）。
  ///
  /// [unidbgClasspath] 是解包运行时目录的 classpath 通配项（`<dir>/*`，由调用方
  /// 从 `UnidbgRuntime.classpathWildcard` 传入——本文件不 import 运行时，
  /// 这样「解包」和「运行时安装」两件事可以各自单测、各自演化）。
  static Future<Map<String, Object?>> run({
    required String shellJar,
    required String outJar,
    LogService? log,
    String? unidbgClasspath,
    String? sidecarHostPath,
    JavaRuntimeProbe? javaProbe,
    ShellUnpackRunner? runner,
    void Function(ShellUnpackProgress)? onProgress,
    Future<void>? cancelled,
  }) async {
    // 进度解析只影响「看得见」，不影响「结论」：坏行、乱序、回调抛异常都在 [_StderrTap] 内部消化。
    final clock = Stopwatch()..start();
    final tap = _StderrTap((progress) {
      log?.info(
        '加固壳解包阶段 stage=${progress.stage} elapsed=${clock.elapsedMilliseconds}ms',
        scope: 'spider',
      );
      onProgress?.call(progress);
    });
    try {
      final classpath = (unidbgClasspath ?? '').trim();
      if (classpath.isEmpty) {
        return <String, Object?>{
          'ok': false,
          'stage': stageEmulator,
          'message':
              '未安装 ARM 解包运行时（unidbg）：无法启动壳的模拟器进程，'
              '请先下载解包运行时。',
        };
      }

      final probe = javaProbe ?? LocalSpiderCommand.probeJavaRuntime(log: log);
      final java = probe.command;
      if (java == null) {
        return <String, Object?>{
          'ok': false,
          'stage': stageEmulator,
          'message': '未找到可用 Java 运行时（需要 JDK/JRE 17+）：${probe.issue ?? '原因未知'}',
        };
      }

      // sidecar 目录由 host.jar 的位置推导（两者同属 spider-host-jvm）。
      final hostJar = sidecarHostPath ?? defaultJvmSidecarHostPath();
      if (hostJar.isEmpty) {
        return <String, Object?>{
          'ok': false,
          'stage': stageInvoke,
          'message': '未找到 spider-host-jvm/host.jar（无法定位 shell-unpack/ShellUnpack.java）',
        };
      }
      final cli = p.join(
        p.dirname(hostJar),
        'shell-unpack',
        'ShellUnpack.java',
      );
      if (!File(cli).existsSync()) {
        return <String, Object?>{
          'ok': false,
          'stage': stageInvoke,
          'message': '未找到解包 CLI：$cli',
        };
      }

      final invocation = ShellUnpackInvocation(
        executable: java.executable,
        arguments: <String>[
          // 堆参数等必须在 -cp 之前（JVM 自己的选项，不能跑到源文件后面）。
          ...java.arguments,
          '-cp',
          classpath,
          // 单文件源码模式：JDK 11+ 直接编译并运行 .java，不需要预编译。
          cli,
          '--shell',
          shellJar,
          '--out',
          outJar,
          '--timeout',
          '${timeout.inSeconds}',
        ],
        timeout: timeout,
        onStderrLine: tap.addLine,
        cancelled: cancelled,
      );

      final output = await (runner ?? runProcess)(invocation);
      // 尾部优先来自「边读边收」的 tap；假 runner 只填 stderr 字段时照样兜住。
      final stderrText = _suffix(
        '${tap.tail}${output.stderr}',
        stderrTailChars,
      );
      if (stderrText.trim().isNotEmpty) {
        log?.info(
          '加固壳解包日志（exit=${output.exitCode}，stderr 尾 $stderrTailChars 字）：'
          '$stderrText',
          scope: 'spider',
        );
      }

      final decoded = _decodeLastLine(output.stdout);
      if (decoded != null) {
        // 退出码非 0 时**以 JSON 为准**：CLI 的失败路径就是 ok:false + stage，
        // 那比退出码本身信息量大得多（用户要看的是「哪个阶段」）。
        if (decoded['ok'] == true) return decoded;
        final stage = '${decoded['stage'] ?? ''}'.trim();
        return <String, Object?>{
          ...decoded,
          'stage': stage.isEmpty ? stageInvoke : stage,
        };
      }
      // 没有可解析的 JSON：绝不能当成功——payload 状态未知。
      return <String, Object?>{
        'ok': false,
        'stage': stageInvoke,
        'message':
            '解包输出无法解析（exit=${output.exitCode}）：'
            '${_head(output.stdout, stdoutHeadChars)}',
      };
    } on TimeoutException {
      return <String, Object?>{
        'ok': false,
        'stage': stageInvoke,
        'message': '解包超时（>${timeout.inSeconds}s）',
      };
    } catch (error) {
      // 注入点的最终兜底：异常一律转成结论，不让导入因解包崩掉。
      return <String, Object?>{
        'ok': false,
        'stage': stageInvoke,
        'message': '$error',
      };
    }
  }

  /// 缺省进程实现：真的起 java，超时则杀进程并让 [run] 统一转成结论。
  static Future<ShellUnpackOutput> runProcess(
    ShellUnpackInvocation invocation,
  ) async {
    final process = await Process.start(
      invocation.executable,
      invocation.arguments,
    );
    final stdoutDone = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
    final stderrDone = _pumpStderr(process.stderr, invocation.onStderrLine);
    final exitDone = process.exitCode;
    try {
      final completed = Future.wait<Object>([stdoutDone, exitDone]);
      final cancelled = invocation.cancelled;
      final result =
          await (cancelled == null
                  ? completed
                  : Future.any<List<Object>>([
                      completed,
                      cancelled.then<List<Object>>(
                        (_) => throw StateError('解包已取消'),
                      ),
                    ]))
              .timeout(invocation.timeout);
      await stderrDone;
      return ShellUnpackOutput(
        stdout: result[0] as String,
        stderr: '',
        exitCode: result[1] as int,
      );
    } catch (_) {
      process.kill();
      await exitDone.timeout(const Duration(seconds: 5), onTimeout: () => -1);
      await Future.wait<Object?>([stdoutDone, stderrDone]).timeout(const Duration(seconds: 2), onTimeout: () => []);
      rethrow;
    }
  }

  /// 把 stderr 边读边拆行交给 [onLine]：进度要「实时」，不能等进程结束才一次性解析。
  ///
  /// 只做拆行与转发——尾部保留、进度解析都在 [_StderrTap] 里，本方法不碰结论。
  static Future<void> _pumpStderr(
    Stream<List<int>> stream,
    void Function(String line)? onLine,
  ) async {
    var pending = '';
    try {
      // allowMalformed：壳/unidbg 偶尔会往 stderr 吐非 UTF-8 字节，按默认的严格解码
      // 会在那一块直接抛异常、把后面的进度与日志全带走——解码错字总好过看不见进度。
      await for (final chunk in stream.transform(
        const Utf8Decoder(allowMalformed: true),
      )) {
        // 没人关心进度时也要把管道读空，否则子进程会因写满 stderr 而卡死。
        if (onLine == null) continue;
        pending += chunk;
        var index = pending.indexOf('\n');
        while (index >= 0) {
          onLine(pending.substring(0, index));
          pending = pending.substring(index + 1);
          index = pending.indexOf('\n');
        }
        if (pending.length > stderrTailChars) {
          // 半行也不许无限增长：截断到上限，剩下的等下一块的换行收尾。
          pending = _suffix(pending, stderrTailChars);
        }
      }
    } catch (_) {
      // 进程被杀或输出不是合法 UTF-8：日志缺失不影响结论。
    } finally {
      if (onLine != null && pending.trim().isNotEmpty) {
        onLine(pending);
      }
    }
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
      // 不要再去翻更早的行（那是 unidbg/壳自己的噪音，猜错了比报错更糟）。
      return null;
    }
    return null;
  }

  static String _suffix(String text, int limit) =>
      text.length <= limit ? text : text.substring(text.length - limit);

  static String _head(String text, int limit) =>
      text.length <= limit ? text : text.substring(0, limit);
}

/// stderr 的「边读边解析」漏斗：进度行变成事件，其余行按原样攒成日志尾部。
///
/// 为什么要有这一层：进度和人类日志共用 stderr，而 [ShellUnpack.run] 的旧实现是
/// 「读完取尾部」，那样进度只能在进程结束时才知道——对 180 s 的解包等于没有进度。
///
/// 容错纪律（任何一条坏行都不许影响返回值）：
/// - 认不出的行（含缺字段、分母不是 7、序号越界）一律当普通日志，不抛、不中断；
/// - 乱序事件原样上报，本层不做单调裁剪——平滑是 UI/ETA 的事，解析层隐瞒数据更难排错；
/// - `onProgress` 是外部代码，它抛的异常在这里吞掉。
class _StderrTap {
  _StderrTap(this._onProgress);

  final void Function(ShellUnpackProgress)? _onProgress;
  String _text = '';

  /// `[progress] 3/7 native-注册`：序号前后允许空白，阶段名取到行尾。
  static final RegExp _pattern = RegExp(
    r'^\[progress\]\s+(\d+)\s*/\s*(\d+)\s+(\S.*)$',
  );

  /// 人类日志的尾部。进度行**不**算日志：它们是机器约定，混进去只会把有用的几行挤掉。
  String get tail => ShellUnpack._suffix(_text, ShellUnpack.stderrTailChars);

  void addLine(String line) {
    final trimmed = line.trim();
    if (trimmed.startsWith(ShellUnpack.progressPrefix)) {
      final progress = _parse(trimmed);
      if (progress != null) {
        try {
          _onProgress?.call(progress);
        } catch (_) {
          // 回调是 UI 层：它炸了不该把「解包结论」一起拖下水。
        }
        return;
      }
    }
    _text += '$line\n';
    if (_text.length > ShellUnpack.stderrTailChars * 4) {
      // 长跑进程的日志可能上万行：随手裁掉前半，避免内存无限增长。
      _text = ShellUnpack._suffix(_text, ShellUnpack.stderrTailChars);
    }
  }

  /// 认不出就返回 null（调用方当普通日志处理），绝不为一条坏行中断解包。
  static ShellUnpackProgress? _parse(String trimmed) {
    final match = _pattern.firstMatch(trimmed);
    if (match == null) return null;
    final rawIndex = int.tryParse(match.group(1)!);
    final total = int.tryParse(match.group(2)!);
    final stage = match.group(3)!.trim();
    // 阶段数是契约的一部分：分母不对说明对面换了配方，贸然换算进度只会骗人。
    if (rawIndex == null || total != ShellUnpack.stageCount || stage.isEmpty) {
      return null;
    }
    // 名字才是契约里的词表：认得名字就按名字定位，免得对面数错序号让进度条乱跳；
    // 名字不认识（壳侧加了新阶段）时退回用序号——宁可名字陌生，也不丢这条进度。
    final canonical = ShellUnpack.stages.indexOf(stage);
    final index = canonical >= 0 ? canonical : rawIndex;
    if (index < 0 || index >= ShellUnpack.stageCount) return null;
    return ShellUnpackProgress(
      stage: stage,
      stageIndex: index,
      stageCount: ShellUnpack.stageCount,
      fraction: ShellUnpack.fractionAt(index),
    );
  }
}
