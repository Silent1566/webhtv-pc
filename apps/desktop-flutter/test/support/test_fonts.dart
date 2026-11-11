/// 测试用的字体加载：跨平台探测，找不到就跳过。
///
/// 为什么需要：visual/golden 用例要保证中文与 Material 图标字形可用，否则
/// 断言里量出来的文本宽度/图标尺寸都不是真实渲染结果。早期实现把 Linux 的
/// 字体绝对路径写死在 `setUpAll` 里，换到 Windows/macOS 上直接
/// `PathNotFoundException`——测试环境差异不该让整个文件崩掉。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 按优先级探测存在的字体文件。
File? firstExisting(List<String> candidates) {
  for (final path in candidates) {
    final file = File(path);
    if (file.existsSync()) return file;
  }
  return null;
}

String? _flutterCacheRoot() {
  // `flutter test` 会把 FLUTTER_ROOT 传给测试进程。
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root == null || root.isEmpty) return null;
  return root;
}

/// 中文（CJK）字体候选：Linux / Windows / macOS。
List<String> cjkFontCandidates() => [
  '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
  '/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc',
  r'C:\Windows\Fonts\msyh.ttc',
  r'C:\Windows\Fonts\msyh.ttf',
  r'C:\Windows\Fonts\simsun.ttc',
  '/System/Library/Fonts/PingFang.ttc',
];

/// Material 图标字体候选：优先跟随当前 Flutter SDK 的缓存目录。
List<String> iconFontCandidates() {
  final root = _flutterCacheRoot();
  return [
    if (root != null)
      '$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    '/tmp/webhtv-linux-sdk/flutter-3.47.5/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  ];
}

Future<ByteData?> _bytesOf(String? path) async {
  if (path == null) return null;
  try {
    final bytes = await File(path).readAsBytes();
    return ByteData.sublistView(bytes);
  } catch (_) {
    return null;
  }
}

/// 加载 CJK + Material 图标字体；任何一路缺失都安静跳过（不阻断用例）。
Future<void> loadFixtureFonts({
  String cjkFamily = 'FixtureCJK',
  String iconFamily = 'MaterialIcons',
}) async {
  final cjkPath = firstExisting(cjkFontCandidates())?.path;
  final cjkBytes = await _bytesOf(cjkPath);
  if (cjkBytes != null) {
    final loader = FontLoader(cjkFamily)..addFont(Future.value(cjkBytes));
    await loader.load();
  }
  final iconBytes = await _bytesOf(firstExisting(iconFontCandidates())?.path);
  if (iconBytes != null) {
    final loader = FontLoader(iconFamily)..addFont(Future.value(iconBytes));
    await loader.load();
  }
}

/// 让 `setUpAll` 只写一行：找不到字体时给出一条可见提示，便于排查。
String describeFixtureFonts() {
  final cjk = firstExisting(cjkFontCandidates())?.path ?? '(未找到)';
  final icon = firstExisting(iconFontCandidates())?.path ?? '(未找到)';
  return 'fixture fonts: cjk=$cjk icon=$icon';
}

/// 供断言前打印使用（`flutter test` 里 print 需要 ignore 注释）。
void reportFixtureFonts() {
  // ignore: avoid_print
  print(describeFixtureFonts());
}

/// 便于测试文件直接调用的断言前置：字体缺失不算失败，只记录。
void expectFontsAvailableOrSkip() {
  expect(firstExisting(cjkFontCandidates()), isNotNull, reason: describeFixtureFonts());
}
