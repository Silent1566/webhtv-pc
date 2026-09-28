/// 深色/浅色主题（§17.4 支持深色模式、中文优先）。
library;

import 'package:flutter/material.dart';

/// 中文字体优先的字体族回退链。
///
/// Windows 使用微软雅黑，Linux 使用 Noto Sans CJK，macOS 使用苹方；
/// 这样既满足“中文优先”，又避免在缺少字体的机器上出现方块字。
const List<String> _fontFallback = [
  'Microsoft YaHei UI',
  'Microsoft YaHei',
  'Noto Sans CJK SC',
  'Source Han Sans SC',
  'PingFang SC',
  'Segoe UI',
  'Roboto',
];

ThemeData buildAppTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF3E7BFA),
    brightness: brightness,
  );
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    brightness: brightness,
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamilyFallback: _fontFallback),
    primaryTextTheme: base.primaryTextTheme.apply(
      fontFamilyFallback: _fontFallback,
    ),
    listTileTheme: const ListTileThemeData(dense: false),
    dividerTheme: const DividerThemeData(space: 1, thickness: 1),
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      showCloseIcon: true,
    ),
  );
}
