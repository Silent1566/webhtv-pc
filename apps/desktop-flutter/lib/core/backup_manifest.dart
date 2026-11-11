/// 本地备份清单与校验（Phase 9 · P2-7）。
///
/// 备份是**普通 zip**：`manifest.json` + `settings.json` + 数据库快照。
/// 清单里记录每个文件的 SHA-256 与大小，恢复前逐项校验；任何一项不符
/// 都拒绝恢复（不拿半个备份去覆盖用户数据）。
///
/// 安全边界：
/// - 只接受相对路径，拒绝绝对路径、盘符、`..`、反斜杠与符号链接；
/// - 恢复只认白名单里的两个文件，zip 里的其它条目最多被校验、不会被写盘；
/// - 清单声明 `databaseSchema` 高于当前版本时拒绝（旧程序读不了新库）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// 备份格式标识。
const String backupFormatName = 'webhtv-pc-backup';

/// 当前备份格式版本。
const int backupFormatVersion = 1;

/// zip 内的清单文件名。
const String backupManifestFile = 'manifest.json';

/// zip 内的设置文件名。
const String backupSettingsFile = 'settings.json';

/// zip 内的数据库文件名。
const String backupDatabaseFile = 'webhtv-pc.sqlite3';

/// 恢复时允许写盘的文件（白名单）。
const Set<String> backupRestorableFiles = {
  backupSettingsFile,
  backupDatabaseFile,
  'ai-user-data.json',
  'reader.json',
  'karaoke-user-data.json',
};

class BackupEntry {
  const BackupEntry({
    required this.path,
    required this.size,
    required this.sha256,
  });

  final String path;
  final int size;
  final String sha256;

  Map<String, Object?> toJson() => {
    'path': path,
    'size': size,
    'sha256': sha256,
  };

  static BackupEntry? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final path = raw['path'];
    final size = raw['size'];
    final sha256Text = raw['sha256'];
    if (path is! String || path.isEmpty) return null;
    if (size is! num || size < 0) return null;
    if (sha256Text is! String || sha256Text.length != 64) return null;
    return BackupEntry(
      path: path,
      size: size.toInt(),
      sha256: sha256Text.toLowerCase(),
    );
  }
}

/// 备份时的库内容摘要（仅供确认页展示，不参与校验）。
class BackupStats {
  const BackupStats({
    required this.configs,
    required this.history,
    required this.favorites,
  });

  static const BackupStats empty = BackupStats(
    configs: 0,
    history: 0,
    favorites: 0,
  );

  final int configs;
  final int history;
  final int favorites;

  Map<String, Object?> toJson() => {
    'configs': configs,
    'history': history,
    'favorites': favorites,
  };

  static BackupStats fromJson(Object? raw) {
    if (raw is! Map) return BackupStats.empty;
    int read(String key) {
      final value = raw[key];
      return value is num && value >= 0 ? value.toInt() : 0;
    }

    return BackupStats(
      configs: read('configs'),
      history: read('history'),
      favorites: read('favorites'),
    );
  }
}

class BackupManifest {
  const BackupManifest({
    required this.format,
    required this.version,
    required this.createdAt,
    required this.appVersion,
    required this.databaseSchema,
    required this.entries,
    required this.stats,
  });

  final String format;
  final int version;
  final int createdAt;
  final String appVersion;
  final int databaseSchema;
  final List<BackupEntry> entries;
  final BackupStats stats;

  Map<String, Object?> toJson() => {
    'format': format,
    'version': version,
    'createdAt': createdAt,
    'appVersion': appVersion,
    'databaseSchema': databaseSchema,
    'entries': [for (final entry in entries) entry.toJson()],
    'stats': stats.toJson(),
  };

  /// 严格解析：任何一项缺失/类型不对都返回 null（不猜测）。
  static BackupManifest? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final format = raw['format'];
    final version = raw['version'];
    final createdAt = raw['createdAt'];
    final appVersion = raw['appVersion'];
    final databaseSchema = raw['databaseSchema'];
    final rawEntries = raw['entries'];
    if (format != backupFormatName) return null;
    if (version is! num) return null;
    if (createdAt is! num) return null;
    if (appVersion is! String) return null;
    if (databaseSchema is! num) return null;
    if (rawEntries is! List) return null;
    final entries = <BackupEntry>[];
    for (final item in rawEntries) {
      final entry = BackupEntry.tryParse(item);
      if (entry == null) return null;
      entries.add(entry);
    }
    return BackupManifest(
      format: format,
      version: version.toInt(),
      createdAt: createdAt.toInt(),
      appVersion: appVersion,
      databaseSchema: databaseSchema.toInt(),
      entries: entries,
      stats: BackupStats.fromJson(raw['stats']),
    );
  }
}

/// 路径安全性：相对、无盘符/前导斜杠/反斜杠/`..`/符号链接形态。
bool isSafeBackupPath(String path) {
  if (path.isEmpty || path.length > 200) return false;
  if (path.startsWith('/') || path.startsWith('\\')) return false;
  if (RegExp(r'^[A-Za-z]:').hasMatch(path)) return false;
  if (path.contains('\\') || path.contains('\x00')) return false;
  for (final segment in path.split('/')) {
    if (segment.isEmpty || segment == '.' || segment == '..') return false;
  }
  return true;
}

String sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

/// 用文件内容构造清单（`files` 的键就是 zip 内路径）。
BackupManifest buildBackupManifest({
  required Map<String, Uint8List> files,
  required int createdAt,
  required String appVersion,
  required int databaseSchema,
  BackupStats stats = BackupStats.empty,
}) {
  final entries = <BackupEntry>[
    for (final entry in files.entries)
      BackupEntry(
        path: entry.key,
        size: entry.value.length,
        sha256: sha256Hex(entry.value),
      ),
  ]..sort((a, b) => a.path.compareTo(b.path));
  return BackupManifest(
    format: backupFormatName,
    version: backupFormatVersion,
    createdAt: createdAt,
    appVersion: appVersion,
    databaseSchema: databaseSchema,
    entries: entries,
    stats: stats,
  );
}

/// 校验结果。
class BackupCheck {
  const BackupCheck.ok() : issue = null;

  const BackupCheck.failed(this.issue);

  final String? issue;

  bool get ok => issue == null;
}

/// 逐项校验清单与文件内容。
///
/// [supportedSchema] 是当前程序能打开的数据库版本；备份版本更高时拒绝。
BackupCheck validateBackup({
  required BackupManifest manifest,
  required Map<String, Uint8List> files,
  required int supportedSchema,
}) {
  if (manifest.format != backupFormatName) {
    return const BackupCheck.failed('不是 WebHTV 备份文件');
  }
  if (manifest.version < 1 || manifest.version > backupFormatVersion) {
    return BackupCheck.failed(
      '备份格式版本 ${manifest.version} 不受支持（当前 $backupFormatVersion）',
    );
  }
  if (manifest.databaseSchema > supportedSchema) {
    return BackupCheck.failed(
      '备份来自更新的版本（库 v${manifest.databaseSchema}，当前 v$supportedSchema）',
    );
  }
  if (manifest.entries.isEmpty) {
    return const BackupCheck.failed('备份清单为空');
  }
  final seen = <String>{};
  for (final entry in manifest.entries) {
    if (!isSafeBackupPath(entry.path)) {
      return BackupCheck.failed('清单包含不安全路径：${entry.path}');
    }
    if (!seen.add(entry.path)) {
      return BackupCheck.failed('清单包含重复路径：${entry.path}');
    }
    final bytes = files[entry.path];
    if (bytes == null) {
      return BackupCheck.failed('备份缺少文件：${entry.path}');
    }
    if (bytes.length != entry.size) {
      return BackupCheck.failed('文件大小不符：${entry.path}');
    }
    if (sha256Hex(bytes) != entry.sha256) {
      return BackupCheck.failed('文件校验失败：${entry.path}');
    }
  }
  if (!files.containsKey(backupDatabaseFile)) {
    return const BackupCheck.failed('备份缺少数据库快照');
  }
  return const BackupCheck.ok();
}

/// 生成备份显示名（`webhtv-backup-20261021-231500.zip`）。
String defaultBackupFileName(DateTime now) {
  String two(int value) => value.toString().padLeft(2, '0');
  return 'webhtv-backup-${now.year}${two(now.month)}${two(now.day)}-'
      '${two(now.hour)}${two(now.minute)}${two(now.second)}.zip';
}

/// 便于诊断：把清单压成一行（不包含任何内容正文）。
String describeBackupManifest(BackupManifest manifest) =>
    'format=${manifest.format} v=${manifest.version} '
    'schema=${manifest.databaseSchema} '
    'createdAt=${manifest.createdAt} '
    'configs=${manifest.stats.configs} history=${manifest.stats.history} '
    'favorites=${manifest.stats.favorites} '
    'files=${manifest.entries.map((e) => e.path).join(",")}';

/// 供测试/诊断：从 JSON 文本解析清单。
BackupManifest? parseBackupManifestJson(String text) {
  try {
    return BackupManifest.tryParse(jsonDecode(text));
  } catch (_) {
    return null;
  }
}
