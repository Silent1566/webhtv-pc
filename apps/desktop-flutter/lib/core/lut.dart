/// LUT（.cube）解析、内置预设目录与 mpv 过滤器构造（`docs/phase9/design/01` §6）。
///
/// 做四件事：
/// 1. 判断一个文件是不是可用的 3D LUT（`LUT_3D_SIZE` + 恰好 `n³` 行数据）；
/// 2. 生成 mpv 的 `vf` 参数（`lavfi=[lut3d=file='...']`）；
/// 3. 描述随安装包分发的内置预设（对齐安卓 `assets/lut_presets`）；
/// 4. 给「内置 / 用户 / 在线下载」三种来源一个统一的取值模型。
///
/// **不做**：1D LUT、`.3dl`、`.m3d`——遇到就明确报「格式不支持」，不猜；
/// 也不产出 `lut3d` 的附加参数（`interp=`/`mix=` 之类）——`vf` 白名单
/// 只认一种形态，见 `mpv_properties.dart` §5.2。
library;

/// LUT 的来源。决定「路径」是谁给的、以及能不能删。
enum LutSource {
  /// 随安装包分发的资源（`assets/lut/*.cube`）。播放前要先落到缓存目录。
  bundled,

  /// 用户自己的文件：手动导入、从链接下载，都算这一类。
  user,
}

/// 解析成功后的元信息。
class LutPreset {
  const LutPreset({
    required this.path,
    required this.name,
    required this.size,
    this.id = '',
    this.source = LutSource.user,
  });

  /// 稳定标识（内置项是资源 id，用户项是文件名派生）。
  ///
  /// 为空时**不猜**：调用方用 [resolvedId] 拿一个总能用的值。
  final String id;

  /// 本地文件路径；[LutSource.bundled] 时这里是 **asset key**（`assets/lut/x.cube`），
  /// 不是磁盘路径——必须经 `LutStore.materialize` 落地后才能交给 mpv。
  final String path;

  /// 显示名：内置项是中文名，用户项优先 `TITLE`，否则文件名。
  final String name;

  /// `LUT_3D_SIZE`（2..[maxLutSize]）。
  final int size;

  final LutSource source;

  bool get isBundled => source == LutSource.bundled;

  bool get is3d => size >= 2;

  /// 没有显式 [id] 时用文件名兜底；内置项必有 id。
  String get resolvedId => id.trim().isNotEmpty ? id : lutBaseName(path);

  /// 给界面看的尺寸文案（`33³`）。
  String get sizeLabel => is3d ? '$size³' : '未知';

  Map<String, Object?> toJson() => <String, Object?>{
    'path': path,
    'name': name,
    'size': size,
    'id': id,
    'source': source.name,
  };

  static LutPreset? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final path = raw['path'];
    final name = raw['name'];
    final size = raw['size'];
    if (path is! String || path.trim().isEmpty) return null;
    final parsedSize = size is num ? size.toInt() : 0;
    if (parsedSize < 2 || parsedSize > maxLutSize) return null;
    final id = raw['id'];
    final source = raw['source'];
    return LutPreset(
      id: id is String ? id.trim() : '',
      path: path.trim(),
      name: name is String && name.trim().isNotEmpty
          ? name.trim()
          : lutBaseName(path),
      size: parsedSize,
      source: source == LutSource.bundled.name
          ? LutSource.bundled
          : LutSource.user,
    );
  }
}

/// 3D LUT 的尺寸上限。
///
/// 128³ 已经是 200 万行，解析会明显卡顿；129 是 .cube 规范里的常见上限。
const int maxLutSize = 129;

/// 单个 LUT 文件的字节上限（8 MiB，`docs/phase9/design/01` §6.1）。
///
/// 33³ 的 .cube 约 1 MB；65³ 约 8.4 MB 会超限，所以下载侧必须在**读入前**
/// 就用 `Content-Length` 拦一次，读的时候再按累计字节拦一次。
const int lutFileBytesLimit = 8 * 1024 * 1024;

/// 内置预设所在的 asset 目录。
const String bundledLutAssetDir = 'assets/lut';

/// 随安装包分发的预设，顺序即界面顺序（对齐安卓 `assets/lut_presets`）。
///
/// 安卓把 13 个 .cube 放在 `assets/lut_presets/` 下；这里沿用同一套效果，
/// 但文件名换成 ASCII（`乌托邦.cube` → `utopia.cube`），显示名仍用中文——
/// 资源键要跨 Windows/Linux/macOS 三套构建脚本，非 ASCII 文件名在
/// Windows 的 CI 上出现过解压编码问题。
const List<LutPreset> builtinLutPresets = <LutPreset>[
  LutPreset(
    id: 'utopia',
    path: '$bundledLutAssetDir/utopia.cube',
    name: '乌托邦',
    size: 33,
    source: LutSource.bundled,
  ),
  LutPreset(
    id: 'low_contrast',
    path: '$bundledLutAssetDir/low_contrast.cube',
    name: '低对比',
    size: 16,
    source: LutSource.bundled,
  ),
  LutPreset(
    id: 'vintage_brown',
    path: '$bundledLutAssetDir/vintage_brown.cube',
    name: '复古深棕',
    size: 33,
    source: LutSource.bundled,
  ),
  LutPreset(
    id: 'leica_film',
    path: '$bundledLutAssetDir/leica_film.cube',
    name: '徕卡胶片',
    size: 17,
    source: LutSource.bundled,
  ),
  LutPreset(
    id: 'bright_fresh',
    path: '$bundledLutAssetDir/bright_fresh.cube',
    name: '明亮清新',
    size: 33,
    source: LutSource.bundled,
  ),
  LutPreset(
    id: 'soft_neutral',
    path: '$bundledLutAssetDir/soft_neutral.cube',
    name: '柔和中性',
    size: 33,
    source: LutSource.bundled,
  ),
  LutPreset(
    id: 'romantic_soft',
    path: '$bundledLutAssetDir/romantic_soft.cube',
    name: '浪漫柔美',
    size: 33,
    source: LutSource.bundled,
  ),
  LutPreset(
    id: 'color_restore',
    path: '$bundledLutAssetDir/color_restore.cube',
    name: '色彩还原',
    size: 33,
    source: LutSource.bundled,
  ),
  LutPreset(
    id: 'teal_bright',
    path: '$bundledLutAssetDir/teal_bright.cube',
    name: '蓝绿带亮',
    size: 33,
    source: LutSource.bundled,
  ),
  LutPreset(
    id: 'cyberpunk',
    path: '$bundledLutAssetDir/cyberpunk.cube',
    name: '赛博朋克',
    size: 33,
    source: LutSource.bundled,
  ),
  LutPreset(
    id: 'vivid_clear',
    path: '$bundledLutAssetDir/vivid_clear.cube',
    name: '通透鲜艳',
    size: 33,
    source: LutSource.bundled,
  ),
  LutPreset(
    id: 'tungsten',
    path: '$bundledLutAssetDir/tungsten.cube',
    name: '钨丝灯',
    size: 33,
    source: LutSource.bundled,
  ),
  LutPreset(
    id: 'premium_texture',
    path: '$bundledLutAssetDir/premium_texture.cube',
    name: '高级质感',
    size: 33,
    source: LutSource.bundled,
  ),
];

/// 按 id 找内置预设；找不到返回 null（**不**回落到第一个）。
LutPreset? findBuiltinLut(String? id) {
  final trimmed = id?.trim() ?? '';
  if (trimmed.isEmpty) return null;
  for (final preset in builtinLutPresets) {
    if (preset.id == trimmed) return preset;
  }
  return null;
}

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
  String id = '',
  LutSource source = LutSource.user,
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
      : (title.isNotEmpty ? title : lutBaseName(trimmedPath));

  return LutParseResult.success(
    LutPreset(
      id: id,
      path: trimmedPath,
      name: name,
      size: resolved,
      source: source,
    ),
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

/// 去掉目录、只留文件名（`a/b/c.cube` → `c.cube`）。
String lutBaseName(String path) {
  final normalized = path.replaceAll('\\', '/');
  final index = normalized.lastIndexOf('/');
  return index >= 0 ? normalized.substring(index + 1) : normalized;
}

/// 去掉扩展名后的文件名（`a/b/c.cube` → `c`）；用于派生 id。
String lutIdFromPath(String path) {
  final base = lutBaseName(path);
  final dot = base.lastIndexOf('.');
  return dot > 0 ? base.substring(0, dot) : base;
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
