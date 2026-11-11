import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

void main() {
  test('真实官方Windows sherpa C API及ONNX runtime依赖可加载', () {
    const path =
        'C:\\Users\\Maple\\AppData\\Local\\Pub\\Cache\\hosted\\pub.dev\\sherpa_onnx_windows-2.0.1\\windows\\x64';
    expect(File('$path/onnxruntime.dll').existsSync(), isTrue);
    DynamicLibrary.open('$path/onnxruntime.dll');
    sherpa.initBindings(path);
    expect(sherpa.getVersion(), isNotEmpty);
  });
}
