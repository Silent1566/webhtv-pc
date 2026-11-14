/// Node 运行时的**唯一**解析实现（设计文档 §9.8）。
///
/// 产品策略：桌面发行包随包内置 `node.exe`，用户永远不需要自己装 Node。因此解析
/// 顺序是「内置优先、PATH 兜底」：
///
/// 1. `WEBHTV_NODE_RUNTIME` 显式覆盖（调试与非常规安装布局）；
/// 2. 可执行文件同级的 `runtime/node/node.exe`（发行包目标布局）；
/// 3. 从当前目录向上最多 10 跳的 `runtime/node/node.exe`（仓库开发态同构）；
/// 4. PATH 里的 `node.exe`；
/// 5. PATH 里的 `node`。
///
/// 全部落空返回 null：调用方必须显示「运行时缺失」，不得静默跳过。
///
/// 之所以把它抽成独立文件：此前 `SidecarRuntimeResolver.resolve` 与
/// `SpiderRegistry._nodeCommand` 各自写了一份 PATH 查找，两份实现一旦分叉，
/// 「内置 node 存在但站点仍报缺运行时」这类问题就没有单一可断言的地方。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'spider_process.dart';

/// 显式指定 node.exe 绝对路径的环境变量（与 `WEBHTV_SIDECAR_HOST` 同族约定）。
const String nodeRuntimeEnvVar = 'WEBHTV_NODE_RUNTIME';

/// 内置运行时相对「可执行文件目录」或「仓库根」的路径片段。
const List<String> builtinNodeRelative = ['runtime', 'node'];

/// 向上查找仓库布局的最大跳数。
///
/// 必须覆盖开发布局：可执行文件在 `build/windows/x64/runner/Release`，到仓库根
/// 需要 7 跳——与 `spider_registry.dart` 的 `_locateSidecarHost` 同一约束。
const int maxUpwardHops = 10;

/// 解析 Node 可执行文件的候选链。
class NodeRuntimeResolver {
  const NodeRuntimeResolver();

  /// 按「内置优先、PATH 兜底」的顺序解析 Node。
  ///
  /// [executableDir]、[searchPathDirs]、[environment]、[startDirectory] 都是为单测
  /// 注入的：默认取 `Platform.resolvedExecutable` 的目录、`PATH`、`Platform.environment`
  /// 与 `Directory.current`。注入只是为了可测，不读也不写任何全局状态。
  static SidecarCommand? resolve({
    String? executableDir,
    List<String>? searchPathDirs,
    Map<String, String>? environment,
    Directory? startDirectory,
  }) {
    final env = environment ?? Platform.environment;
    final names = _executableNames();

    final override = (env[nodeRuntimeEnvVar] ?? '').trim();
    if (override.isNotEmpty) {
      final candidate = p.normalize(override);
      if (File(candidate).existsSync()) return _command(candidate);
      // 覆盖值无效时继续走后续候选：单点配置错误不该让整个运行时「消失」。
    }

    final resolvedDir = executableDir ?? _resolvedExecutableDir();
    if (resolvedDir != null) {
      final builtin = _findIn(
        p.joinAll([resolvedDir, ...builtinNodeRelative]),
        names,
      );
      if (builtin != null) return _command(builtin);
    }

    var current = startDirectory ?? Directory.current;
    for (var hop = 0; hop < maxUpwardHops; hop++) {
      final builtin = _findIn(
        p.joinAll([current.path, ...builtinNodeRelative]),
        names,
      );
      if (builtin != null) return _command(builtin);
      final parent = current.parent;
      if (parent.path == current.path) break;
      current = parent;
    }

    for (final dir in searchPathDirs ?? _platformSearchDirs(env)) {
      final found = _findIn(dir, names);
      if (found != null) return _command(found);
    }
    return null;
  }

  /// Windows 上是 `node.exe`（只找 `node` 会永远落空），其余平台是 `node`。
  static List<String> _executableNames() =>
      Platform.isWindows ? const ['node.exe', 'node'] : const ['node'];

  static String? _findIn(String dir, List<String> names) {
    for (final name in names) {
      final candidate = p.join(dir, name);
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  static String? _resolvedExecutableDir() {
    try {
      return p.dirname(Platform.resolvedExecutable);
    } catch (_) {
      // `Platform.resolvedExecutable` 在极端环境下可能不可用。
      return null;
    }
  }

  static List<String> _platformSearchDirs(Map<String, String> env) {
    final raw = env['PATH'] ?? env['Path'] ?? '';
    return raw
        .split(Platform.isWindows ? ';' : ':')
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList();
  }

  static SidecarCommand _command(String executable) =>
      SidecarCommand(executable: executable, arguments: const []);
}
