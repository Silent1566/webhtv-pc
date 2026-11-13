import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

/// 官方 `sherpa_onnx_windows` 包自带的 `windows/x64` 目录。
///
/// 包根从 `.dart_tool/package_config.json` 解析：硬编码某台开发机的 pub cache
/// 绝对路径时，CI runner（pub cache 在 `%LOCALAPPDATA%\Pub\Cache`）必然找不到库。
String _sherpaWindowsX64Dir() {
  final config = File(
    p.join(Directory.current.path, '.dart_tool', 'package_config.json'),
  );
  final packages =
      (jsonDecode(config.readAsStringSync())
              as Map<String, dynamic>)['packages']
          as List<dynamic>;
  final entry = packages.cast<Map<String, dynamic>>().firstWhere(
    (package) => package['name'] == 'sherpa_onnx_windows',
  );
  final rootUri = Uri.parse(entry['rootUri'] as String);
  // package_config.json 的相对 rootUri 以该文件所在目录为基准。
  final rootDir = rootUri.isScheme('file')
      ? rootUri
      : config.parent.absolute.uri.resolve(rootUri.toString());
  return p.join(rootDir.toFilePath(), 'windows', 'x64');
}

void main() {
  test('真实官方Windows sherpa C API及ONNX runtime依赖可加载', () {
    final path = _sherpaWindowsX64Dir();
    expect(File('$path/onnxruntime.dll').existsSync(), isTrue);
    DynamicLibrary.open('$path/onnxruntime.dll');
    sherpa.initBindings(path);
    expect(sherpa.getVersion(), isNotEmpty);
  });
}
