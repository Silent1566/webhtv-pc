/// Node 运行时解析测试：内置优先、PATH 兜底（§9.8）。
///
/// 全部场景用临时目录构造，占位文件只需存在、不要求可执行——解析层只做
/// 「候选文件是否存在」，真正能否启动由 sidecar 启动失败路径负责。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/services/node_runtime.dart';

const String _envVar = 'WEBHTV_NODE_RUNTIME';

/// Windows 上内置运行时文件叫 `node.exe`，其余平台叫 `node`。
String get _exeName => Platform.isWindows ? 'node.exe' : 'node';

/// 期望值归一化：解析器会对候选做 `p.join`/`p.normalize`，比较前统一形态。
String _norm(String path) => p.normalize(path);

/// 在 [dir] 下造一个占位可执行文件并返回其路径。
String _touch(String dirPath, String name) {
  final dir = Directory(dirPath);
  if (!dir.existsSync()) dir.createSync(recursive: true);
  final file = File(p.join(dirPath, name));
  file.writeAsStringSync('');
  return file.path;
}

/// 造一个「发行包布局」：`<exeDir>/runtime/node/node.exe`。
String _touchBuiltinNode(String exeDir) =>
    _touch(p.join(exeDir, 'runtime', 'node'), _exeName);

void main() {
  late Directory sandbox;
  // PATH 里那个「用户自己装的 node」所在的目录。
  late String pathDir;
  // 把环境变量与 repo 布局隔开的干净起点：既没有 runtime/node，也不会向上跳到
  // 仓库根部真实的 runtime/node（真有的话会污染「两者都没有」用例）。
  late String executableDir;

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync('webhtv_node_runtime_');
    pathDir = p.join(sandbox.path, 'path_bin');
    executableDir = p.join(sandbox.path, 'app', 'bin');
    Directory(pathDir).createSync(recursive: true);
    Directory(executableDir).createSync(recursive: true);
  });

  tearDown(() {
    if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
  });

  /// 统一用注入参数调用：不读进程环境、不依赖 cwd，测试之间不会互相污染。
  ///
  /// [startDirectory] 固定为空目录，向上查找也不会碰到仓库里的真实 runtime/node。
  /// [environment] 显式传入空表，等价于「没有设置 WEBHTV_NODE_RUNTIME」。
  String? resolveWith({
    List<String>? pathDirs,
    Map<String, String>? environment,
    String? overrideNode,
    String? builtinRoot,
  }) {
    final env = Map<String, String>.from(environment ?? const <String, String>{});
    if (overrideNode != null) env[_envVar] = overrideNode;
    final emptyStart = Directory(p.join(sandbox.path, 'empty_start'))
      ..createSync(recursive: true);
    return NodeRuntimeResolver.resolve(
      executableDir: builtinRoot ?? executableDir,
      searchPathDirs: pathDirs ?? const <String>[],
      environment: env,
      startDirectory: emptyStart,
    )?.executable;
  }

  test('内置 runtime/node 存在时优先于 PATH 里的 node', () {
    final builtinBin = p.join(sandbox.path, 'app', 'bin');
    final builtin = _touchBuiltinNode(builtinBin);
    final onPath = _touch(pathDir, _exeName);

    final resolved = resolveWith(builtinRoot: builtinBin, pathDirs: [pathDir]);

    expect(resolved, isNotNull, reason: '内置 node 存在时必须解析成功');
    expect(
      resolved,
      equals(_norm(builtin)),
      reason: '内置优先：即使 PATH 里有另一个 node（$onPath）也要用随包那个',
    );
  });

  test('内置不存在时回退到 PATH 里的 node', () {
    final onPath = _touch(pathDir, _exeName);

    final resolved = resolveWith(pathDirs: [pathDir]);

    expect(resolved, isNotNull);
    expect(resolved, equals(_norm(onPath)));
  });

  test('内置与 PATH 都没有时返回 null（不得静默跳过）', () {
    final elsewhere = p.join(sandbox.path, 'empty_bin');
    Directory(elsewhere).createSync(recursive: true);

    expect(resolveWith(pathDirs: [elsewhere]), isNull);
    expect(resolveWith(pathDirs: const <String>[]), isNull);
  });

  test('WEBHTV_NODE_RUNTIME 指向存在文件时优先于内置', () {
    final builtinBin = p.join(sandbox.path, 'app', 'bin');
    final builtin = _touchBuiltinNode(builtinBin);
    final onPath = _touch(pathDir, _exeName);
    final override = _touch(p.join(sandbox.path, 'custom'), _exeName);

    final resolved = resolveWith(
      builtinRoot: builtinBin,
      pathDirs: [pathDir],
      overrideNode: override,
    );

    expect(resolved, isNotNull);
    expect(resolved, equals(_norm(override)));
    expect(resolved, isNot(equals(_norm(builtin))));
    expect(resolved, isNot(equals(_norm(onPath))));
  });

  test('WEBHTV_NODE_RUNTIME 指向不存在的文件时继续用内置', () {
    final builtinBin = p.join(sandbox.path, 'app', 'bin');
    final builtin = _touchBuiltinNode(builtinBin);

    final resolved = resolveWith(
      builtinRoot: builtinBin,
      overrideNode: p.join(sandbox.path, 'custom', _exeName),
    );

    expect(resolved, isNotNull);
    expect(resolved, equals(_norm(builtin)));
  });
}
