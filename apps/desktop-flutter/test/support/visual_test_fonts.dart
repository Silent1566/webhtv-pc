/// 视觉用例的字体加载：按平台解析真实存在的字体文件。
///
/// 背景：`detail_recommendations*` 与 `recommendation_back_navigation` 曾把
/// `/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc` 与
/// `/tmp/webhtv-linux-sdk/.../MaterialIcons-Regular.otf` 写死，导致这三个用例
/// 在任何非该 Linux 布局的机器上 `setUpAll` 直接抛 `PathNotFoundException`，
/// 整份用例一条都跑不了。字体只是渲染素材，不该成为平台门槛。
///
/// 因此这里按「候选 → 首个存在」解析；某个字体缺失时静默跳过（用例仍按真实
/// widget 结构与文本断言），而不会把整份用例拖成 infra 失败。
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// 返回 [candidates] 中第一个真实存在的文件；都不存在时返回空串。
String firstExistingFont(List<String> candidates) {
  for (final path in candidates) {
    if (File(path).existsSync()) return path;
  }
  return '';
}

/// 中文（CJK）字体候选：Windows 用系统自带雅黑/宋体，Linux 用 Noto，macOS 用苹方。
List<String> cjkFontCandidates() {
  if (Platform.isWindows) {
    final windows = Platform.environment['WINDIR'] ?? r'C:\Windows';
    return [
      p.join(windows, 'Fonts', 'msyh.ttc'),
      p.join(windows, 'Fonts', 'msyhl.ttc'),
      p.join(windows, 'Fonts', 'simsun.ttc'),
    ];
  }
  if (Platform.isMacOS) {
    return [
      '/System/Library/Fonts/PingFang.ttc',
      '/System/Library/Fonts/Hiragino Sans GB.ttc',
    ];
  }
  return [
    '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
    '/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc',
    '/usr/share/fonts/opentype/noto/NotoSansCJK-VF.otf.ttc',
  ];
}

/// Flutter SDK 根目录：优先环境变量，其次由当前 dart 可执行文件位置推导。
String? flutterRoot() {
  final fromEnv = Platform.environment['FLUTTER_ROOT']?.trim();
  if (fromEnv != null && fromEnv.isNotEmpty) return fromEnv;
  // <flutter>/bin/cache/dart-sdk/bin/dart.exe
  final dartDir = File(Platform.resolvedExecutable).parent;
  final candidate = p.normalize(
    p.join(dartDir.path, '..', '..', '..', '..'),
  );
  return Directory(candidate).existsSync() ? candidate : null;
}

/// MaterialIcons 字体候选（随 Flutter SDK 分发）。
List<String> materialIconsCandidates() {
  final root = flutterRoot();
  if (root == null) return const [];
  return [
    p.join(
      root,
      'bin',
      'cache',
      'artifacts',
      'material_fonts',
      'MaterialIcons-Regular.otf',
    ),
  ];
}

Future<void> _load(String family, String path) async {
  final loader = FontLoader(family)
    ..addFont(
      File(path).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
    );
  await loader.load();
}

/// 为视觉用例加载 CJK 与 MaterialIcons 字体。
///
/// 字体缺失时跳过对应加载而不是失败：这是渲染素材，不是被测行为。
Future<void> loadVisualTestFonts({String cjkFamily = 'FixtureCJK'}) async {
  final cjk = firstExistingFont(cjkFontCandidates());
  if (cjk.isNotEmpty) await _load(cjkFamily, cjk);
  final icons = firstExistingFont(materialIconsCandidates());
  if (icons.isNotEmpty) await _load('MaterialIcons', icons);
}
