/// 启动系统 Chromium 内核浏览器，并读回它的 DevTools WebSocket 端点。
///
/// 为什么让内核自己选端口：`--remote-debugging-port=0` 会让它在
/// `user-data-dir/DevToolsActivePort` 里写下「真实端口 + WebSocket 路径」。
/// 自己探测空闲端口会和内核绑定时刻产生竞态，端口也可能被别的进程抢走。
///
/// 为什么清理只做「杀进程 + 删目录」：浏览器崩溃后能确定执行的动作只有这两件，
/// 窗口/标签页之类的状态在进程死亡后已无从操作。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'sniff_transport.dart';
import 'sniff_types.dart';

/// 启动参数（纯函数：单测不必真的起浏览器就能断言参数纪律）。
///
/// `--no-sandbox` 只在 root 时加：普通用户下平台自带的 setuid sandbox 是浏览器
/// 隔离的一部分，无条件关掉等于把解析页的任意 JS 放到与本机同权限的位置。
List<String> sniffBrowserArguments({
  required String userDataDir,
  required bool headless,
  int? width,
  int? height,
  bool root = false,
}) {
  return [
    '--remote-debugging-port=0',
    '--user-data-dir=$userDataDir',
    '--no-first-run',
    '--no-default-browser-check',
    '--disable-background-networking',
    '--disable-sync',
    '--disable-extensions',
    '--disable-features=Translate,MediaRouter',
    '--autoplay-policy=no-user-gesture-required',
    if (headless) '--headless=new',
    if (width != null && height != null) '--window-size=$width,$height',
    if (root) '--no-sandbox',
  ];
}

/// 探测结果的短期缓存：同一路径在 [probeCacheTtl] 内不重复起进程。
///
/// 用户连续点几集时，每次都重新 shell 一次 `--version` 只会重复同一条失败；
/// 又不能永久缓存——用户装好浏览器后不该逼他重启应用。30s 是这两者之间的折中。
final Map<String, _CachedProbe> _probeCache = {};
const Duration probeCacheTtl = Duration(seconds: 30);

class _CachedProbe {
  const _CachedProbe(this.issue, this.at);
  final String? issue;
  final DateTime at;
}

/// 清空探测缓存（测试用）。
void resetProbeCache() => _probeCache.clear();

/// 轻量探测：跑一次 `--version`，返回 null 表示可用，否则给出不可用原因。
///
/// 为什么值得多花一次进程启动：坏候选（snap 包装脚本在受限环境里
/// `snap-confine` 直接失败、架构不匹配的内核）如果直接进启动流程，要等满
/// 20s 端点超时才失败，用户看到的是"超时"而不是"这个浏览器不可用"。
///
/// 返回的原因被压成**单行**并截断：它最终进入 `AppError.detail` 与日志行，
/// 多行 stderr（如 `snap-confine` 后面跟着整段 capability 清单）会把一条日志
/// 撕成五行，既难读也破坏按行解析。
Future<String?> probeChromiumBrowser(
  BrowserCommand command, {
  Duration timeout = const Duration(seconds: 6),
  bool useCache = true,
}) async {
  final cached = _probeCache[command.executablePath];
  if (useCache && cached != null && DateTime.now().difference(cached.at) < probeCacheTtl) {
    return cached.issue;
  }
  final issue = await _probeChromiumBrowserUncached(command, timeout: timeout);
  _probeCache[command.executablePath] = _CachedProbe(issue, DateTime.now());
  return issue;
}

Future<String?> _probeChromiumBrowserUncached(
  BrowserCommand command, {
  required Duration timeout,
}) async {
  try {
    final process = await Process.start(command.executablePath, const ['--version']);
    final stdout = StringBuffer();
    final stderr = StringBuffer();
    final outDone = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(stdout.write)
        .asFuture<void>();
    final errDone = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(stderr.write)
        .asFuture<void>();
    final code = await process.exitCode.timeout(
      timeout,
      onTimeout: () {
        process.kill();
        return -1;
      },
    );
    await Future.wait<void>([outDone, errDone]).timeout(
      const Duration(seconds: 2),
      onTimeout: () => const <void>[],
    );
    if (code == 0) return null;
    return '退出码 $code；${compactProbeReason('${stderr.toString()}${stdout.toString()}')}';
  } on Object catch (error) {
    return compactProbeReason('$error');
  }
}

/// 把探测输出压成一行可读原因：取第一条有意义的行，折叠空白，限长 160。
String compactProbeReason(String raw) {
  final lines = raw
      .split(RegExp(r'[\r\n]+'))
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList(growable: false);
  if (lines.isEmpty) return '无输出';
  final first = lines.first.replaceAll(RegExp(r'\s+'), ' ');
  final truncated = first.length > 160 ? '${first.substring(0, 160)}…' : first;
  return lines.length > 1 ? '$truncated（另有 ${lines.length - 1} 行输出已折叠）' : truncated;
}

/// 读浏览器版本行（`--version` 的第一行），失败返回 null。
///
/// 组件安装器用它给目录/组件命名（例如 `Google Chrome 154.0.8037.0`）：
/// 没有版本号的组件目录会在升级后变成两个分不清的目录。
Future<String?> chromiumVersionOf(String executablePath) async {
  try {
    final process = await Process.start(executablePath, const ['--version']);
    final stdout = await process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .join()
        .timeout(const Duration(seconds: 6), onTimeout: () => '');
    unawaited(process.stderr.drain<void>());
    final code = await process.exitCode.timeout(
      const Duration(seconds: 6),
      onTimeout: () {
        process.kill();
        return -1;
      },
    );
    if (code != 0) return null;
    for (final line in stdout.split(RegExp(r'[\r\n]+'))) {
      final trimmed = line.trim();
      if (trimmed.isNotEmpty) return trimmed;
    }
    return null;
  } on Object {
    return null;
  }
}

/// 是否以 root 运行。root 下 Chromium 的 setuid sandbox 会直接拒绝启动，
/// 此时关掉它是「能跑」与「完全跑不起来」之间唯一的选择。
bool sniffRunningAsRoot([Map<String, String>? environment]) {
  if (Platform.isWindows) return false;
  final env = environment ?? Platform.environment;
  return env['USER'] == 'root' || env['LOGNAME'] == 'root';
}

/// 启动浏览器并等待 DevTools 端点就绪。
///
/// 超时或进程提前退出都会先 [ChromiumBrowserProcess.close] 再抛
/// [SniffException]，失败路径不留进程与临时目录。
Future<ChromiumBrowserProcess> launchChromiumBrowser(
  BrowserCommand command, {
  bool headless = true,
  Duration readyTimeout = const Duration(seconds: 20),
  int? width,
  int? height,
}) async {
  // Chromium 把 SingletonSocket 放在 $TMPDIR，而 UNIX socket 路径上限是 108 字节。
  // 桌面应用继承来的 TMPDIR 可能是很深的构建目录（实测 worktree 路径直接超限，
  // 浏览器以 "FATAL: Socket path too long" 退出，用户只看到「浏览器都不可用」）。
  // 因此给浏览器单独挑一个短目录，并把它作为子进程的 TMPDIR。
  final tempRoot = await _resolveBrowserTempRoot();
  final profile = await Directory(tempRoot).createTemp('whs-');
  final arguments = sniffBrowserArguments(
    userDataDir: profile.path,
    headless: headless,
    width: width,
    height: height,
    root: sniffRunningAsRoot(),
  );

  Process process;
  try {
    process = await Process.start(
      command.executablePath,
      arguments,
      environment: _childEnvironment(tempRoot),
    );
  } on ProcessException catch (error) {
    await _deleteTree(profile);
    throw SniffException(
      '浏览器启动失败',
      detail: '${command.executablePath}：${error.message}',
    );
  }

  final instance = ChromiumBrowserProcess._(command, process, profile);
  try {
    await instance._awaitEndpoint(readyTimeout);
  } catch (_) {
    await instance.close();
    rethrow;
  }
  return instance;
}

/// 给浏览器挑一个足够短的临时根目录。
///
/// 纯函数便于穷举：`maxLength` 按「`<root>/org.chromium.Chromium.XXXXXX/`
/// `SingletonSocket` ≈ root + 45 字节」留余量取 40。
String chooseBrowserTempRoot({
  required String systemTemp,
  required bool Function(String path) isUsable,
  String? xdgRuntimeDir,
  int maxLength = 40,
}) {
  for (final candidate in [xdgRuntimeDir, '/tmp', systemTemp]) {
    if (candidate == null || candidate.isEmpty) continue;
    if (candidate.length > maxLength) continue;
    if (!isUsable(candidate)) continue;
    return candidate;
  }
  // 全都不合条件就退回系统临时目录：宁可让浏览器自己报路径超长，
  // 也不要在这里猜一个不可写的位置。
  return systemTemp;
}

Future<String> _resolveBrowserTempRoot() async {
  final systemTemp = Directory.systemTemp.path;
  if (Platform.isWindows) return systemTemp;
  return chooseBrowserTempRoot(
    systemTemp: systemTemp,
    xdgRuntimeDir: Platform.environment['XDG_RUNTIME_DIR'],
    isUsable: (path) {
      try {
        final directory = Directory(path);
        if (!directory.existsSync()) return false;
        final probe = directory.createTempSync('whs-probe-');
        probe.deleteSync(recursive: true);
        return true;
      } on Object {
        return false;
      }
    },
  );
}

/// 子进程环境：POSIX 上把 TMPDIR 指向短目录（本轮根因），其余变量原样继承。
Map<String, String> _childEnvironment(String tempRoot) {
  final environment = Map<String, String>.from(Platform.environment);
  if (!Platform.isWindows) environment['TMPDIR'] = tempRoot;
  return environment;
}

/// 浏览器进程句柄：DevTools 端点、进程号、幂等的终止与目录清理。
class ChromiumBrowserProcess implements BrowserSession {
  ChromiumBrowserProcess._(this._command, this._process, this._profile) {
    _process.exitCode.then(
      (code) {
        _exitCode = code;
        if (!_exited.isCompleted) _exited.complete(true);
      },
      onError: (Object _) {
        if (!_exited.isCompleted) _exited.complete(true);
      },
    );
    _drain(_process.stdout);
    _drain(_process.stderr);
  }

  /// 保留的日志行数：只够诊断「为什么没起来」，多于它就是日志噪声。
  static const int _logTailLimit = 60;

  final BrowserCommand _command;
  final Process _process;
  final Directory _profile;
  final Completer<bool> _exited = Completer<bool>();
  final List<String> _logTail = [];

  Uri? _endpoint;
  int? _exitCode;
  bool _closed = false;

  /// 被定位并启动的可执行文件（诊断用）。
  BrowserCommand get command => _command;

  /// 本次运行的临时 profile 目录（测试断言清理用）。
  String get profileDirectory => _profile.path;

  /// stderr/stdout 尾部（启动失败时的报错细节）。
  String get logTail => _logTail.join(' | ');

  @override
  Uri get webSocketUrl {
    final endpoint = _endpoint;
    if (endpoint == null) {
      throw StateError('DevTools 端点尚未就绪');
    }
    return endpoint;
  }

  @override
  int get pid => _process.pid;

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (_exitCode == null) {
      _kill(force: false);
      final exited = await _exited.future.timeout(
        const Duration(seconds: 3),
        onTimeout: () => false,
      );
      // 3s 内没退：内核卡在调试器或子进程回收上，SIGKILL 是唯一的兜底。
      if (!exited && _exitCode == null) {
        _kill(force: true);
        await _exited.future.timeout(
          const Duration(seconds: 3),
          onTimeout: () => false,
        );
      }
    }
    await _deleteTree(_profile);
  }

  Future<void> _awaitEndpoint(Duration timeout) async {
    final portFile = File('${_profile.path}${Platform.pathSeparator}DevToolsActivePort');
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final code = _exitCode;
      if (code != null) {
        throw SniffException(
          '浏览器在 DevTools 端点就绪前退出',
          detail: '退出码 $code${_logTail.isEmpty ? '' : '；$logTail'}',
        );
      }
      final endpoint = _readEndpoint(portFile);
      if (endpoint != null) {
        _endpoint = endpoint;
        return;
      }
      await Future.any([_exited.future, Future<void>.delayed(const Duration(milliseconds: 100))]);
    }
    throw SniffException(
      '等待浏览器 DevTools 端点超时',
      detail: '${timeout.inSeconds}s${_logTail.isEmpty ? '' : '；$logTail'}',
    );
  }

  /// 读 [DevToolsActivePort]：第一行端口、第二行 browser 路径。
  ///
  /// 内核先写端口再写路径，读到只有一行的中间态必须当「还没就绪」。
  Uri? _readEndpoint(File file) {
    String raw;
    try {
      raw = file.readAsStringSync();
    } on FileSystemException {
      return null;
    }
    final lines = raw
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    if (lines.length < 2) return null;
    final port = int.tryParse(lines[0]);
    if (port == null || port <= 0) return null;
    final path = lines[1].startsWith('/')
        ? lines[1]
        : '/devtools/browser/${lines[1]}';
    return Uri.parse('ws://127.0.0.1:$port$path');
  }

  void _drain(Stream<List<int>> stream) {
    stream
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen((line) {
          final trimmed = line.trim();
          if (trimmed.isEmpty) return;
          _logTail.add(trimmed);
          if (_logTail.length > _logTailLimit) _logTail.removeAt(0);
        }, onError: (Object _) {}, cancelOnError: false);
  }

  void _kill({required bool force}) {
    try {
      _process.kill(force ? ProcessSignal.sigkill : ProcessSignal.sigterm);
    } on Object {
      // Windows 只接受终止（sigterm 语义），并且进程可能已经自己退出。
      try {
        _process.kill();
      } on Object {
        // 进程已消失：close() 的语义是幂等，不在这里报错。
      }
    }
  }
}

/// 删除临时 profile：目录里可能还有正在收尾的子进程句柄，
/// 首次删除失败就短等重试——清理是 best-effort，绝不因此让 close() 失败。
Future<void> _deleteTree(Directory directory) async {
  for (var attempt = 0; attempt < 3; attempt++) {
    try {
      if (!directory.existsSync()) return;
      await directory.delete(recursive: true);
      return;
    } on FileSystemException {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }
}
