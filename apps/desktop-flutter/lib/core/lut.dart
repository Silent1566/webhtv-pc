/// LUT（.cube）解析与 mpv 过滤器构造（`docs/phase9/design/01` §6）。
///
/// 只做两件事：
/// 1. 判断一个文件是不是可用的 3D LUT（`LUT_3D_SIZE` + 恰好 `n³` 行数据）；
/// 2. 生成 mpv 的 `vf` 参数（`lavfi=[lut3d=file='...']`）。
///
/// **不做**：1D LUT、`.3dl`、`.m3d`——遇到就明确报「格式不支持」，不猜。
library;

/// 解析成功后的元信息。
class LutPreset {
  const LutPreset({
    required this.path,
    required this.name,
    required this.size,
  });

  /// 本地文件路径（原样保存，应用时转成 mpv 可读形式）。
  final String path;

  /// 显示名：优先 `TITLE`，否则文件名。
  final String name;

  /// `LUT_3D_SIZE`（2..129）。
  final int size;

  bool get is3d => size >= 2;

  Map<String, Object?> toJson() => <String, Object?>{
    'path': path,
    'name': name,
    'size': size,
  };

  static LutPreset? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final path = raw['path'];
    final name = raw['name'];
    final size = raw['size'];
    if (path is! String || path.trim().isEmpty) return null;
    final parsedSize = size is num ? size.toInt() : 0;
    if (parsedSize < 2 || parsedSize > maxLutSize) return null;
    return LutPreset(
      path: path.trim(),
      name: name is String && name.trim().isNotEmpty
          ? name.trim()
          : _basename(path),
      size: parsedSize,
    );
  }

  static String _basename(String path) {
    final normalized = path.replaceAll('\\', '/');
    final index = normalized.lastIndexOf('/');
    return index >= 0 ? normalized.substring(index + 1) : normalized;
  }
}

/// 3D LUT 的尺寸上限。
///
/// 128³ 已经是 200 万行，解析会明显卡顿；129 是 .cube 规范里的常见上限。
const int maxLutSize = 129;

/// 解析结果：成功给 [preset]，失败给 [error]（中文、可直接展示）。
class LutParseResult {
  const LutParseResult.success(this.preset) : error = null;

  const LutParseResult.failure(this.error) : preset = null;

  final LutPreset? preset;
  final String? error;

  bool get ok => preset != null;
}

/// 解析 `.cube` 文本。
///
/// [path] 用于生成 [LutPreset.path]；[displayName] 缺省时用 `TITLE` 或文件名。
LutParseResult parseCube(
  String text, {
  required String path,
  String? displayName,
}) {
  final trimmedPath = path.trim();
  if (trimmedPath.isEmpty) {
    return const LutParseResult.failure('LUT 路径为空');
  }

  int? size;
  var title = '';
  var dataLines = 0;
  var sawData = false;

  for (final rawLine in text.split(RegExp(r'\r?\n'))) {
    final line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#')) continue;

    final upper = line.toUpperCase();
    if (upper.startsWith('TITLE')) {
      title = _unquote(line.substring(5).trim());
      continue;
    }
    if (upper.startsWith('LUT_1D_SIZE')) {
      return const LutParseResult.failure('暂不支持 1D LUT（只支持 3D .cube）');
    }
    if (upper.startsWith('LUT_3D_SIZE')) {
      // `LUT_3D_SIZE` 共 11 个字符；用常量长度而不是魔数，避免再差一位。
      final value = int.tryParse(line.substring(11).trim());
      if (value == null || value < 2 || value > maxLutSize) {
        return LutParseResult.failure('LUT_3D_SIZE 非法（允许 2~$maxLutSize）');
      }
      size = value;
      continue;
    }
    if (upper.startsWith('DOMAIN_MIN') || upper.startsWith('DOMAIN_MAX')) {
      continue;
    }
    if (upper.startsWith('LUT_3D_INPUT_RANGE')) {
      continue;
    }

    // 数据行：三个浮点数。
    final parts = line.split(RegExp(r'\s+'));
    if (parts.length != 3) {
      return LutParseResult.failure('数据行不是 3 列：$line');
    }
    for (final part in parts) {
      if (double.tryParse(part) == null) {
        return LutParseResult.failure('数据行含非数字：$line');
      }
    }
    dataLines += 1;
    sawData = true;
  }

  final resolved = size;
  if (resolved == null) {
    return const LutParseResult.failure('缺少 LUT_3D_SIZE（不是 3D .cube）');
  }
  if (!sawData) {
    return const LutParseResult.failure('LUT 没有数据行');
  }
  final expected = resolved * resolved * resolved;
  if (dataLines != expected) {
    return LutParseResult.failure(
      'LUT 数据行数不符：期望 $expected，实际 $dataLines',
    );
  }

  final name = (displayName ?? '').trim().isNotEmpty
      ? displayName!.trim()
      : (title.isNotEmpty ? title : LutPreset._basename(trimmedPath));

  return LutParseResult.success(
    LutPreset(path: trimmedPath, name: name, size: resolved),
  );
}

/// 生成 mpv `vf` 参数值；[path] 为空时返回空串（表示不应用 LUT）。
///
/// mpv 侧等价命令：`vf set lavfi=[lut3d=file='...']`。
/// 路径转 `/` 并转义单引号，避免 Windows 反斜杠被 filter 语法吃掉。
String buildLutVfArgument(String? path) {
  final trimmed = path?.trim() ?? '';
  if (trimmed.isEmpty) return '';
  final normalized = trimmed.replaceAll('\\', '/').replaceAll("'", r"\'");
  return "lavfi=[lut3d=file='$normalized']";
}

/// 供测试/诊断使用的可读摘要。
String describeLutError(Object error) {
  final text = error.toString();
  return text.length > 200 ? '${text.substring(0, 200)}…' : text;
}

String _unquote(String raw) {
  final text = raw.trim();
  if (text.length >= 2 &&
      ((text.startsWith('"') && text.endsWith('"')) ||
          (text.startsWith("'") && text.endsWith("'")))) {
    return text.substring(1, text.length - 1);
  }
  return text;
}
