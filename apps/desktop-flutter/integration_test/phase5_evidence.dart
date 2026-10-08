/// Phase 5 集成测试的截图证据辅助（`docs/phase5/design/03` §7）。
///
/// 与 Phase 4 的 `captureEvidence` 同一实现口径：`RepaintBoundary` 层树
/// → `toImage` → PNG。用真实光栅化结果而不是"widget 树的重新描述"，
/// 因为要证明的是**用户看到的样子**（设备卡片、站点数、开关状态、明细行）。
///
/// [anchor] 用来指定「要拍哪一层」。不指定时取第一个 `RepaintBoundary`
/// （即整窗）。**对话框必须显式指定**：它在 Navigator 的 overlay 里，
/// 取第一个 boundary 会拍到被压在下面的页面。
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// 证据行输出（与各套件的 `evidence()` 同格式，便于 grep）。
void Function(String) evidenceWriter(String scope) =>
    (message) => debugPrint('PHASE5-EVIDENCE $scope $message');

/// 把当前渲染结果写成 PNG 证据（路径相对仓库根）。
Future<void> captureEvidence(
  WidgetTester tester, {
  required String relativePath,
  required void Function(String) evidence,
  Finder? anchor,
}) async {
  final binding = IntegrationTestWidgetsFlutterBinding.instance;
  final boundary = anchor ?? find.byType(RepaintBoundary);
  if (boundary.evaluate().isEmpty) {
    evidence('screenshot-skip reason=no-repaint-boundary path=$relativePath');
    return;
  }
  final object = boundary.evaluate().first.renderObject;
  if (object is! RenderRepaintBoundary) {
    evidence('screenshot-skip reason=not-repaint-boundary path=$relativePath');
    return;
  }
  final image = await object.toImage(pixelRatio: 1.0);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  if (bytes == null) {
    evidence('screenshot-skip reason=encode-failed path=$relativePath');
    return;
  }
  final repoRoot = repoRootOf(Directory.current);
  final output = File('${repoRoot.path}/$relativePath');
  output.parent.createSync(recursive: true);
  output.writeAsBytesSync(bytes.buffer.asUint8List());
  evidence(
    'screenshot path=$relativePath bytes=${bytes.lengthInBytes} '
    'size=${image.width}x${image.height} binding=${binding.runtimeType}',
  );
}

/// 从当前目录向上查找仓库根（以 `docs/phase5` 存在为判据）。
Directory repoRootOf(Directory start) {
  var current = start;
  for (var hop = 0; hop < 6; hop++) {
    if (Directory('${current.path}/docs/phase5').existsSync()) return current;
    final parent = current.parent;
    if (parent.path == current.path) break;
    current = parent;
  }
  return start;
}
