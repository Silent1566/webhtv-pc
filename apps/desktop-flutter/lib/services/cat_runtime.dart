/// 猫源运行时：本机 Node 进程承载 CatPawOpen bundle，并提供 `/config` 就绪探测。
///
/// 参考实现：`Silent1566/webhtv@beta` 的
/// `app/src/main/java/com/fongmi/android/tv/node/NodeBoot.java` 与
/// `NodeService.java`。三处关键行为必须对齐：
///
/// 1. **宿主全局**：bundle 引用 `catServerFactory`（返回一个 http.Server）与
///    `catDartServerPort()`（宿主 HTTP 端口，bundle 用于 POST `/msg` 回调）。
///    PC 端实现 = `http.createServer(handler)` + 一个本机占位服务端口。
/// 2. **配置注入**：`index.config.js` 通过 `require()` 传入 `start(config)`。
/// 3. **端口发现**：bundle 可能起多个 HTTP 服务（魔改 bundle 会额外起弹幕服务等），
///    引导脚本把**全部**候选端口落盘，宿主逐个探 `/config` 用
///    [CatSource.isConfig] 认准真正的猫源服务，而不是只信第一个端口。
///
/// 进程生命周期跟随导入/换源：导入猫源时启动，换源或退出时终止整个子进程树
/// （Windows Job Object，`windows_job.dart`）。运行中的 bundle 成为站点请求的
/// 后端——站点 `api` 补上 `http://127.0.0.1:<port>` 前缀后走现有
/// `CatHttpSiteRuntime`（`webhtv-cat-http-v1`），无需新运行时。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../core/app_error.dart';
import '../core/cat_source.dart';
import '../core/config_loader.dart' show ResolvedCatConfig;
import '../core/protocol.dart';
import 'cat_bundle.dart';
import 'log_service.dart';
import 'spider_process.dart' show SidecarCommand;
import 'windows_job.dart';

/// 一个已就绪的猫源运行时实例。
class CatRuntimeSession {
  const CatRuntimeSession({
    required this.bundleDir,
    required this.port,
    required this.baseUrl,
    required this.sourceKey,
  });

  final String bundleDir;
  final int port;
  final String baseUrl;
  final String sourceKey;

  String get configUrl => '$baseUrl/config';
}

/// 猫源 Node 进程运行器。
///
/// [start] 一次调用完成：写 boot.js → 起 Node → 等候选端口 → 探 `/config`。
/// [stop] 终止进程树（幂等）。同一目录反复 [start] 会先杀旧的再起新的。
class CatNodeRuntime {
  CatNodeRuntime({
    required this.nodeCommand,
    required this.log,
    HttpClient? httpClient,
    this.httpTimeout = const Duration(seconds: 3),
    this.startTimeout = const Duration(seconds: 55),
    this.maxMemoryBytes = 256 * 1024 * 1024,
    this.maxCpuSeconds = 0,
  }) : _probe = httpClient ?? HttpClient() {
    _probe.connectionTimeout = httpTimeout;
  }

  final SidecarCommand nodeCommand;
  final LogService log;

  /// 就绪探测用 HttpClient：探 `/config` 只认 `CatSource.isConfig` 形状。
  final HttpClient _probe;
  final Duration httpTimeout;
  final Duration startTimeout;
  final int maxMemoryBytes;

  /// 0 = 不限 CPU 时间（bundle 是长驻服务，不能像 sidecar 一样限 CPU）。
  final int maxCpuSeconds;

  /// 当前运行的进程与 job。
  Process? _process;
  WindowsJobObject? _job;
  bool _stopRequested = false;

  /// 已就绪的会话；null 表示未启动/失败。
  CatRuntimeSession? _session;

  ServerSocket? _backingServer;
  StreamSubscription<Socket>? _backingSub;

  CatRuntimeSession? get session => _session;

  bool get isRunning => _session != null && _process != null && _process!.pid > 0;

  // ---------------------------------------------------------------------------
  // 启动
  // ---------------------------------------------------------------------------

  /// 启动运行在 [bundleDir] 的 bundle。[onProgress] 汇报阶段进度（UI 用）。
  ///
  /// 返回就绪会话；失败抛 [AppError]，错误文本可直接展示。
  Future<CatRuntimeSession> start(
    String bundleDir,
    String sourceKey, {
    void Function(String message)? onProgress,
  }) async {
    await stop();
    _stopRequested = false;
    _job = WindowsJobObject.create(
      memoryBytes: maxMemoryBytes,
      cpuSeconds: maxCpuSeconds,
    );

    // 1) 写 boot.js（复刻 NodeBoot.write；改动必须逐条对应参考实现）。
    final bootPath = await _writeBoot(bundleDir);

    // 2) 起 Node 进程。
    onProgress?.call('启动猫源 Node 进程');
    final process = await Process.start(
      nodeCommand.executable,
      [
        ...nodeCommand.arguments,
        '--max-old-space-size=256',
        bootPath,
      ],
      workingDirectory: bundleDir,
      includeParentEnvironment: false,
      environment: _environment(bundleDir),
    );
    _process = process;
    _job?.assign(process.pid);

    // 兜底：Node 进程立刻退出（bundle require 失败等）时报可定位错误。
    process.exitCode.then((code) {
      if (_stopRequested || _session != null) return;
      log.warning(
        '猫源 Node 进程提前退出 code=$code',
        scope: 'cat',
      );
      _session = null;
    });

    // stdout/stderr 只入日志（boot.js 的候选端口是写文件，不走 stdout）。
    process.stdout.listen(
      (chunk) =>
          log.debug(utf8.decode(chunk, allowMalformed: true).trim(), scope: 'cat'),
      onError: (Object e) => log.debug('猫源 stdout 读取失败：$e', scope: 'cat'),
    );
    process.stderr.listen(
      (chunk) =>
          log.debug(utf8.decode(chunk, allowMalformed: true).trim(), scope: 'cat'),
      onError: (Object e) => log.debug('猫源 stderr 读取失败：$e', scope: 'cat'),
    );

    // 3) 等端口就绪。
    final port = await _waitReady(bundleDir, onProgress: onProgress);
    if (port <= 0) {
      await stop();
      throw AppError(
        AppErrorKind.siteUnsupported,
        '猫源启动失败：服务未在预期时间内就绪',
        detail: 'bundleDir=\${p.basename(bundleDir)} 请检查日志',
        retryable: true,
      );
    }

    final session = CatRuntimeSession(
      bundleDir: bundleDir,
      port: port,
      baseUrl: 'http://127.0.0.1:$port',
      sourceKey: sourceKey,
    );
    _session = session;
    log.info('猫源就绪 port=$port sites=${await _probeSites(port)}', scope: 'cat');
    return session;
  }

  /// 探测已就绪端口的站点数量（仅供日志，失败返回 0）。
  Future<int> _probeSites(int port) async {
    try {
      final config = await probeConfig(port);
      final root = jsonDecode(config);
      final object = CatSource.normalize('http://127.0.0.1:$port', root);
      return (object['sites'] as List?)?.length ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// 拉取 `/config` 原始文本。
  ///
  /// 公开给导入管线：启动就绪后取一次配置。失败抛 [AppError.kind=configNetwork]。
  Future<String> probeConfig([int? port]) async {
    final actualPort = port ?? _session?.port;
    if (actualPort == null) {
      throw AppError(AppErrorKind.configInvalid, '猫源未就绪', retryable: true);
    }
    return _fetchConfig(actualPort);
  }

  /// 轮询候选端口，逐个探 `/config` 认准猫源服务（§9 参考实现 NodeService.waitReady）。
  Future<int> _waitReady(
    String bundleDir, {
    void Function(String message)? onProgress,
  }) async {
    final portFile = File(p.join(bundleDir, 'port'));
    final deadline = DateTime.now().add(startTimeout);
    var reported = false;
    while (DateTime.now().isBefore(deadline)) {
      if (_stopRequested) return 0;
      final candidates = _readPorts(portFile);
      if (candidates.isEmpty) {
        if (!reported) {
          onProgress?.call('等待猫源就绪');
          reported = true;
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
        continue;
      }
      for (final port in candidates) {
        try {
          final config = await _fetchConfig(port).timeout(httpTimeout);
          if (CatSource.isConfig(config)) {
            log.info('猫源服务认准 port=$port', scope: 'cat');
            return port;
          }
        } catch (_) {
          // 端口有响应但不是配置；继续探下一个候选。
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    return 0;
  }

  /// GET `/config`，返回响应文本；任何非 2xx 抛错。
  Future<String> _fetchConfig(int port) async {
    final request = await _probe.getUrl(
      Uri.parse('http://127.0.0.1:$port/config'),
    );
    request.headers.set(HttpHeaders.acceptHeader, 'application/json, */*');
    final response = await request.close();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await response.drain<void>();
      throw HttpException('HTTP ${response.statusCode}');
    }
    final bytes = await _readBounded(response, 64 * 1024 * 1024);
    return utf8.decode(bytes, allowMalformed: true);
  }

  /// 读 port 文件：逗号分隔的候选端口（兼容单端口旧格式）。
  static List<int> _readPorts(File file) {
    try {
      if (!file.existsSync()) return const [];
      final raw = file.readAsBytesSync();
      final text = utf8.decode(raw, allowMalformed: true).trim();
      final ports = <int>[];
      for (final part in text.split(',')) {
        final value = int.tryParse(part.trim());
        if (value != null && value > 0 && !ports.contains(value)) {
          ports.add(value);
        }
      }
      return ports;
    } catch (_) {
      return const [];
    }
  }

  // ---------------------------------------------------------------------------
  // boot.js 生成（与 NodeBoot.java source() 逐条对齐）
  // ---------------------------------------------------------------------------

  Future<String> _writeBoot(String bundleDir) async {
    final bootPath = p.join(bundleDir, 'boot.js');
    final bundle = p.join(bundleDir, 'index.js');
    final config = p.join(bundleDir, 'index.config.js');
    final data = p.join(bundleDir, 'data');
    await Directory(data).create(recursive: true);
    final portFile = p.join(bundleDir, 'port');

    // 宿主占位服务：bundle 拿到端口后只用于构造 /msg 回调 URL，多数包不真正 POST；
    // 我们并不实现消息语义，启动一个 404 服务只为不让端口悬空。
    final backing = await _startBacking();

    final script = _bootSource(
      bundle: bundle,
      config: config,
      hostPort: backing,
      portFile: portFile,
      dataDir: data,
    );
    await File('$bootPath.tmp').writeAsString(script, flush: true);
    await File('$bootPath.tmp').rename(bootPath);
    return bootPath;
  }

  /// 启动宿主占位服务，返回其端口。
  Future<int> _startBacking() async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;
    _backingSub = server.listen((socket) async {
      try {
        socket.destroy();
      } catch (_) {}
    });
    _backingServer = server;
    return port;
  }

  /// boot.js 源码（严格对应 NodeBoot.java 的 source()）。
  static String _bootSource({
    required String bundle,
    required String config,
    required int hostPort,
    required String portFile,
    required String dataDir,
  }) {
    String escape(String value) =>
        value.replaceAll('\\', '\\\\').replaceAll("'", "\\'");
    final bundleE = escape(bundle);
    final configE = escape(config);
    final portE = escape(portFile);
    final dataE = escape(dataDir);
    return '''
'use strict';
const http = require('http');
globalThis.catServerFactory = (handler) => http.createServer(handler);
globalThis.catDartServerPort = () => $hostPort;
process.env.NODE_PATH = '$dataE';
process.on('uncaughtException', (e) => console.error('uncaught', e));
process.on('unhandledRejection', (e) => console.error('unhandled', e));
(async () => {
  try {
    const mod = require('$bundleE');
    const start = mod.start || (mod.default && mod.default.start);
    if (typeof start !== 'function') throw new Error('bundle has no start()');
    let conf = {};
    try {
      const raw = require('$configE');
      conf = raw && raw.default ? raw.default : (raw || {});
      console.log('config keys: ' + Object.keys(conf).length);
    } catch (e) { console.error('config load failed', e.message); }
    await start(conf);
    setInterval(() => {}, 60000);
    let last = '';
    const publish = () => {
      try {
        const handles = process._getActiveHandles ? process._getActiveHandles() : [];
        const ports = [];
        for (const h of handles) {
          if (h && typeof h.address === 'function' && h.constructor && h.constructor.name === 'Server') {
            const a = h.address();
            if (a && a.port && !ports.includes(a.port)) ports.push(a.port);
          }
        }
        if (!ports.length) return false;
        const text = ports.join(',');
        if (text === last) return true;
        const fs = require('fs');
        fs.writeFileSync('$portE.tmp', text);
        fs.renameSync('$portE.tmp', '$portE');
        last = text;
        console.log('cat bundle listening on ' + text);
        return true;
      } catch (e) { console.error('publish port failed', e.message); }
      return false;
    };
    let tries = 0;
    const timer = setInterval(() => { if (publish() || ++tries > 250) clearInterval(timer); }, 200);
    console.log('cat bundle started');
  } catch (e) {
    console.error('cat bundle failed', e && e.stack ? e.stack : e);
  }
})();
''';
  }

  /// 子进程环境：白名单（不继承宿主完整 env，§9.8）。
  Map<String, String> _environment(String bundleDir) {
    final source = Platform.environment;
    String? value(String key) {
      final direct = source[key];
      if (direct != null && direct.isNotEmpty) return direct;
      return _altCase(key) == null ? null : source[_altCase(key)!];
    }

    return <String, String>{
      if (value('SystemRoot') != null) 'SystemRoot': value('SystemRoot')!,
      if (value('windir') != null) 'windir': value('windir')!,
      if (value('TEMP') != null) 'TEMP': value('TEMP')!,
      if (value('TMP') != null) 'TMP': value('TMP')!,
      if (value('ComSpec') != null) 'ComSpec': value('ComSpec')!,
      if (value('PATH') != null) 'PATH': value('PATH')!,
      'NODE_PATH': p.join(bundleDir, 'data'),
    };
  }

  static String? _altCase(String key) {
    if (Platform.isWindows) {
      if (key == 'Path') return 'PATH';
      if (key == 'PATH') return 'Path';
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // 停止与生命周期
  // ---------------------------------------------------------------------------

  /// 终止当前进程树（幂等）。
  Future<void> stop() async {
    _stopRequested = true;
    _session = null;
    final process = _process;
    final job = _job;
    _process = null;
    _job = null;
    if (job != null) {
      job.terminate();
      job.dispose();
    }
    if (process != null) {
      try {
        await process.exitCode.timeout(
          const Duration(seconds: 3),
          onTimeout: () {
            process.kill(ProcessSignal.sigkill);
            return -1;
          },
        );
      } catch (_) {
        try {
          process.kill(ProcessSignal.sigkill);
        } catch (_) {}
      }
    }
    final backing = _backingServer;
    final backingSub = _backingSub;
    _backingServer = null;
    _backingSub = null;
    try {
      await backingSub?.cancel();
    } catch (_) {}
    if (backing != null) {
      try {
        await backing.close();
      } catch (_) {}
    }
  }

  /// 关闭底层资源（进程已由 [stop] 处理）。
  void close() {
    _probe.close(force: true);
  }

  static Future<Uint8List> _readBounded(
    HttpClientResponse response,
    int limit,
  ) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response) {
      builder.add(chunk);
      if (builder.length > limit) break;
    }
    return builder.takeBytes();
  }
}

/// 猫源导入门面：识别 → 下载缓存 → 启动 → 取 `/config` → normalize。
///
/// 供 [ConfigImportService] 的猫源分支挂接。返回已归一化的标准 TVBox 配置对象
/// （顶层带 `sites`），可直接喂给现有 `parseConfigDocument`。
class CatImportPipeline {
  CatImportPipeline({
    required this.bundle,
    required this.runtime,
    required this.log,
  });

  final CatBundle bundle;
  final CatNodeRuntime runtime;
  final LogService log;

  /// 当前已启动的猫源会话（供换源/退出时终止进程树）。
  CatRuntimeSession? get session => runtime.session;

  /// 走完整个猫源导入，产出可直接解析的配置文本。
  ///
  /// 与 [CatConfigResolver] 签名一致，可直接注入 [ConfigImportService]。
  /// 失败抛 [AppError]，错误文本可直接展示给用户。
  Future<ResolvedCatConfig?> resolve(
    String url, {
    void Function(String message)? onProgress,
  }) async {
    final (normalized, session) = await import(url, onProgress: onProgress);
    return ResolvedCatConfig(
      configJson: jsonEncode(normalized),
      origin: session.configUrl,
    );
  }

  /// 走完整个猫源导入。
  ///
  /// [url] 是用户填的猫源地址（`.../index.js.md5` 或本地包路径）。
  /// 返回 `(normalizedConfigJson, session)`；失败抛 AppError。
  Future<(Map<String, Object?>, CatRuntimeSession)> import(
    String url, {
    void Function(String message)? onProgress,
  }) async {
    // 1) 下载/校验/缓存。
    final installed = await bundle.ensure(url, onProgress: onProgress);
    if (!installed.ok) {
      throw AppError(
        AppErrorKind.configInvalid,
        installed.error ?? '猫源 bundle 安装失败',
        detail: redactUrl(url),
        retryable: true,
      );
    }

    // 2) 启动并等 /config 就绪。
    final session = await runtime.start(
      installed.bundleDir,
      'import:$url',
      onProgress: onProgress,
    );

    // 3) 取 /config 并 normalize。
    onProgress?.call('拉取猫源站点');
    final configText = await runtime.probeConfig(session.port);
    final root = jsonDecode(configText);
    final normalized = CatSource.normalize(session.baseUrl, root);
    return (normalized, session);
  }

  /// 终止运行中的猫源进程（幂等）。
  Future<void> stop() => runtime.stop();

  void close() {
    runtime.close();
    bundle.close();
  }
}