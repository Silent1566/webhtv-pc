/// 本地 Spider manifest 注册表（设计文档 §9.7、§17.2、§18.2）。
///
/// Phase 2 的安全边界：只加载**本机已存在**的 manifest 与站源代码，不下载远程脚本，
/// 因此不存在「首次执行远程脚本前必须由用户确认来源和权限」的确认流程——该流程属于
/// Phase 3 远程分发，此时才需要。
///
/// manifest 与代码分离：宿主只信任 manifest 声明的 capability / permission / limits，
/// 站源自报的能力超出 manifest 时以 manifest 为准（§9.7）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/ipc_protocol.dart';
import 'log_service.dart';
import 'spider_process.dart';

/// 一个已发现的本地 Spider。
class LocalSpider {
  const LocalSpider({
    required this.manifest,
    required this.manifestPath,
    required this.rootDir,
    required this.entryPath,
  });

  final SpiderManifest manifest;
  final String manifestPath;

  /// manifest 所在目录；`entry` 相对该目录解析。
  final String rootDir;
  final String entryPath;

  String get key => manifest.key;

  bool get entryExists => File(entryPath).existsSync();
}

/// 注册表：扫描 Spider 目录，加载并校验 manifest（§9.7）。
class SpiderManifestRegistry {
  SpiderManifestRegistry({required this.root, required this.log});

  /// Spider 根目录（`%APPDATA%/webhtv-pc/spiders`）。
  final String root;
  final LogService log;

  final Map<String, LocalSpider> _spiders = {};

  Map<String, LocalSpider> get spiders => Map.unmodifiable(_spiders);

  List<LocalSpider> get sortedSpiders {
    final list = _spiders.values.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return list;
  }

  /// 扫描根目录。每次调用都会重读 manifest，使手工编辑后无需重启。
  Future<List<LocalSpider>> scan() async {
    _spiders.clear();
    final directory = Directory(root);
    if (!await directory.exists()) return const [];

    await for (final entity in directory.list(followLinks: false)) {
      final manifestFile = entity is Directory
          ? File(p.join(entity.path, 'manifest.json'))
          : (entity is File && p.basename(entity.path).endsWith('.json')
                ? entity
                : null);
      if (manifestFile == null || !await manifestFile.exists()) continue;
      final loaded = await _load(manifestFile);
      if (loaded == null) continue;
      if (_spiders.containsKey(loaded.key)) {
        log.warning(
          '忽略重复的 Spider key=${loaded.key}（已存在 ${_spiders[loaded.key]!.manifestPath}）',
          scope: 'spider',
        );
        continue;
      }
      _spiders[loaded.key] = loaded;
    }
    log.info(
      'Spider manifest 扫描完成 root=$root found=${_spiders.length}',
      scope: 'spider',
    );
    return sortedSpiders;
  }

  /// 注册单个 manifest 文件；供测试与「手动添加」路径使用。
  Future<LocalSpider?> register(String manifestPath) async {
    final loaded = await _load(File(manifestPath));
    if (loaded == null) return null;
    _spiders[loaded.key] = loaded;
    return loaded;
  }

  LocalSpider? byKey(String key) => _spiders[key];

  Future<LocalSpider?> _load(File file) async {
    final String text;
    try {
      text = await file.readAsString();
    } catch (error) {
      log.error('读取 manifest 失败 ${file.path}：$error', scope: 'spider');
      return null;
    }

    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (error) {
      log.error('manifest 不是合法 JSON ${file.path}：$error', scope: 'spider');
      return null;
    }

    final manifest = SpiderManifest.fromJson(decoded);
    final problems = manifest.problems;
    if (problems.isNotEmpty) {
      // §9.7：未声明权限的能力在进程层拒绝；manifest 非法则不得加载。
      log.error(
        'manifest 校验失败 ${file.path}：${problems.join("; ")}',
        scope: 'spider',
      );
      return null;
    }
    if (manifest.missingRequired.isNotEmpty) {
      log.error(
        'manifest 缺少必需方法 key=${manifest.key}：${manifest.missingRequired.join(",")}',
        scope: 'spider',
      );
      return null;
    }

    final rootDir = p.dirname(file.path);
    final entryPath = p.isAbsolute(manifest.entry)
        ? manifest.entry
        : p.normalize(p.join(rootDir, manifest.entry));
    // §9.8：远程脚本只在工作目录内运行；本地路径也必须落在 manifest 目录内。
    if (!p.isWithin(rootDir, entryPath) && entryPath != rootDir) {
      log.error(
        'manifest entry 越出 Spider 目录 key=${manifest.key} entry=$entryPath',
        scope: 'spider',
      );
      return null;
    }

    return LocalSpider(
      manifest: manifest,
      manifestPath: file.path,
      rootDir: rootDir,
      entryPath: entryPath,
    );
  }
}

/// 站点与本地 Spider 的绑定（`api` 形态 `spider-local:<key>` 或 manifest 相对路径）。
///
/// 使用独立的 `spider-local:` scheme 而不是猜测 `api` 内容，避免把普通 URL 误判为
/// 本地 Spider，也避免把本地路径误当作远端接口（§8.1、§9.9）。
class SpiderLocalBinding {
  const SpiderLocalBinding({required this.registry});

  static const String scheme = 'spider-local:';

  final SpiderManifestRegistry registry;

  /// 从站点 `api` 解析本地 Spider。
  ///
  /// 返回 null 表示该站点不是本地 Spider 形态。
  LocalSpider? resolve(String api) {
    final trimmed = api.trim();
    if (!trimmed.toLowerCase().startsWith(scheme)) return null;
    final target = trimmed.substring(scheme.length).trim();
    if (target.isEmpty) return null;
    // 允许 `spider-local:<key>` 与 `spider-local:<相对路径>/manifest.json` 两种写法。
    final key = p.basename(target).replaceAll(RegExp(r'\.json$'), '');
    return registry.byKey(target) ??
        registry.byKey(key) ??
        registry.byKey(target.replaceAll('/', '-'));
  }

  /// 该站点是否声明为本地 Spider。
  static bool matches(String api) =>
      api.trim().toLowerCase().startsWith(scheme);
}

/// 本地 Spider 的运行命令解析（§9.7 `runtime` 字段）。
class LocalSpiderCommand {
  const LocalSpiderCommand({
    required this.executable,
    required this.arguments,
  });

  final String executable;
  final List<String> arguments;

  static const String _hostRelative = 'host.py';

  /// 解析成可执行命令（§9.7 `runtime` 字段）。
  ///
  /// - `python*` 用本机 Python 启动 `sidecars/spider-host-python/host.py`；
  /// - `node*` 用本机 Node 启动 `sidecars/spider-host-js/host.js`（§9.1
  ///   `tvbox-js-v1` 沙箱，与 Python 宿主同一份 `webhtv-ipc-v1` 帧契约）。
  ///
  /// [hostPath] 是 Python 宿主路径（`defaultSidecarHostPath()` 或测试覆盖）；
  /// [jsHostPath] 是 JS 宿主路径。未显式给出时按发行包布局从 [hostPath]
  /// 推导（`sidecars/` 下两个兄弟运行时目录），使单一路径参数在仓库与发行包
  /// 两种布局下都成立。
  ///
  /// 运行时未安装/不受支持时返回 null，调用方必须显示「运行时未安装」
  /// 而不是静默失败。
  static LocalSpiderCommand? resolve({
    required LocalSpider spider,
    required String hostPath,
    String? jsHostPath,
    LogService? log,
  }) {
    final runtime = spider.manifest.runtime.toLowerCase();

    if (runtime.startsWith('python')) {
      if (!File(hostPath).existsSync()) {
        log?.error('sidecar 宿主不存在：$hostPath', scope: 'spider');
        return null;
      }
      // Python 命令统一由 host.py 决定具体解释器，避免宿主与 sidecar 猜测不一致；
      // 这里用宿主自身的解释器探测逻辑（`py -3` 优先，其次 `python3`/`python`）。
      final python = _pythonCommand();
      if (python == null) {
        log?.warning('未找到 Python 运行时，无法启动 sidecar', scope: 'spider');
        return null;
      }
      return LocalSpiderCommand(
        executable: python.executable,
        arguments: [
          ...python.arguments,
          hostPath,
          '--entry',
          spider.entryPath,
          '--manifest',
          spider.manifestPath,
        ],
      );
    }

    if (runtime.startsWith('node')) {
      // 显式给出的 JS 宿主优先；否则由 Python 宿主路径推导（兄弟目录）。
      final resolvedJsHost = (jsHostPath != null && jsHostPath.isNotEmpty)
          ? jsHostPath
          : (hostPath.isNotEmpty ? jsHostPathFor(hostPath) : '');
      if (resolvedJsHost.isEmpty || !File(resolvedJsHost).existsSync()) {
        log?.error('JS sidecar 宿主不存在：$resolvedJsHost', scope: 'spider');
        return null;
      }
      final node = _nodeCommand();
      if (node == null) {
        log?.warning('未找到 Node 运行时，无法启动 JS sidecar', scope: 'spider');
        return null;
      }
      return LocalSpiderCommand(
        executable: node.executable,
        arguments: [
          ...node.arguments,
          resolvedJsHost,
          '--entry',
          spider.entryPath,
          '--manifest',
          spider.manifestPath,
        ],
      );
    }

    log?.warning(
      'runtime=${spider.manifest.runtime} 不受支持（已实现 python*/node*）',
      scope: 'spider',
    );
    return null;
  }

  /// 由 Python 宿主路径推导 JS 宿主路径：`sidecars/` 下两个兄弟运行时目录。
  ///
  /// `.../sidecars/spider-host-python/host.py` →
  /// `.../sidecars/spider-host-js/host.js`
  static String jsHostPathFor(String pythonHostPath) {
    final sidecarsDir = p.dirname(p.dirname(pythonHostPath));
    return p.join(sidecarsDir, 'spider-host-js', 'host.js');
  }

  /// 查找本机 Node。返回 null 表示未安装，UI 必须提示而不是静默跳过。
  static SidecarCommand? _nodeCommand() {
    final names = Platform.isWindows ? ['node.exe', 'node'] : ['node'];
    for (final name in names) {
      for (final dir in platformSearchDirs()) {
        final candidate = p.join(dir, name);
        if (File(candidate).existsSync()) {
          return SidecarCommand(executable: candidate, arguments: const []);
        }
      }
    }
    return null;
  }

  /// 查找本机 Python。返回 null 表示未安装，UI 必须提示而不是静默跳过。
  static SidecarCommand? _pythonCommand() {
    final pathDirs = (Platform.environment['PATH'] ?? '').split(';');
    final candidates = <String>[];
    // `py.exe` 位于 Windows 系统目录之外的 Launcher 目录，但也在 PATH 中；
    // 这里同时补充 SystemRoot，覆盖 PATH 被裁剪的情况。
    final systemRoot = Platform.environment['SystemRoot'];
    if (Platform.isWindows && systemRoot != null) {
      candidates.add(p.join(systemRoot, 'py.exe'));
    }
    candidates.addAll(pathDirs.where((dir) => dir.trim().isNotEmpty).map(
      (dir) => p.join(dir.trim(), 'py.exe'),
    ));
    for (final candidate in candidates) {
      if (File(candidate).existsSync()) {
        return SidecarCommand(executable: candidate, arguments: const ['-3']);
      }
    }
    final fallbacks = Platform.isWindows
        ? ['python3.exe', 'python.exe']
        : ['python3', 'python'];
    final dirs = platformSearchDirs();
    for (final name in fallbacks) {
      for (final dir in dirs) {
        final candidate = p.join(dir, name);
        if (File(candidate).existsSync()) {
          return SidecarCommand(executable: candidate, arguments: const []);
        }
      }
    }
    return null;
  }

  static List<String> platformSearchDirs() {
    // sidecar 的 PATH 被裁剪为系统目录（§9.8），但宿主解析运行时时仍需要用户 PATH。
    final source = Platform.environment;
    final path = source['PATH'] ?? source['Path'] ?? '';
    final dirs = path
        .split(Platform.isWindows ? ';' : ':')
        .where((item) => item.trim().isNotEmpty)
        .map((item) => item.trim())
        .toList();
    return dirs;
  }

  static String get hostRelative => _hostRelative;
}

/// 定位仓库/发行包内的 Python sidecar 宿主脚本。
///
/// 查找顺序（§20.5「不依赖开发机上的 PATH、HOME 或预装 libmpv 才能启动」）：
/// 1. `WEBHTV_SIDECAR_HOST` 显式覆盖（测试与调试）；
/// 2. 与可执行文件同级的 `sidecars/`（发行包布局）；
/// 3. 从当前目录向上查找的仓库布局。
///
/// 找不到时返回空串；调用方必须显示「sidecar 宿主缺失」而不是静默跳过站点。
String defaultSidecarHostPath() {
  return _locateSidecarHost(
    const ['sidecars', 'spider-host-python', 'host.py'],
    'WEBHTV_SIDECAR_HOST',
  );
}

/// 定位仓库/发行包内的 JS（Node）sidecar 宿主脚本（§9.1 `tvbox-js-v1`）。
///
/// 与 [defaultSidecarHostPath] 同语义：`node*` 运行时需要 `spider-host-js/host.js`。
/// 发行包可能只带其中一种运行时，因此两个入口各自独立解析。
String defaultJsSidecarHostPath() {
  return _locateSidecarHost(
    const ['sidecars', 'spider-host-js', 'host.js'],
    'WEBHTV_SIDECAR_JS_HOST',
  );
}

/// 共享的宿主脚本定位逻辑（环境变量覆盖 → 可执行文件同级 → 向上查找仓库）。
String _locateSidecarHost(List<String> relative, String envVar) {
  final override = Platform.environment[envVar];
  if (override != null && override.trim().isNotEmpty) {
    final candidate = p.normalize(override.trim());
    if (File(candidate).existsSync()) return candidate;
  }

  try {
    final executableDir = p.dirname(Platform.resolvedExecutable);
    final candidate = p.joinAll([executableDir, ...relative]);
    if (File(candidate).existsSync()) return candidate;
  } catch (_) {
    // Platform.resolvedExecutable 在极端环境下可能不可用。
  }

  var current = Directory.current;
  for (var hop = 0; hop < 6; hop++) {
    final candidate = p.joinAll([current.path, ...relative]);
    if (File(candidate).existsSync()) return candidate;
    final parent = current.parent;
    if (parent.path == current.path) break;
    current = parent;
  }
  return '';
}
