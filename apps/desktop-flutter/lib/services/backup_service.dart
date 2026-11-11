/// 本地备份/恢复的 zip 读写（Phase 9 · P2-7）。
///
/// 只做「生成备份、校验备份、取出待恢复内容」三件事；替换文件、关闭/重开
/// 数据库、重建内存状态由 `AppState` 负责（它才知道当前有哪些资源在用库）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import '../core/backup_manifest.dart';
import 'app_paths.dart';
import 'log_service.dart';
import 'storage.dart';
import 'ai_integration.dart';

class BackupCreateResult {
  const BackupCreateResult({
    required this.ok,
    required this.path,
    required this.message,
    this.manifest,
  });

  final bool ok;
  final String path;
  final String message;
  final BackupManifest? manifest;
}

class BackupInspectionResult {
  const BackupInspectionResult({
    required this.ok,
    required this.message,
    this.manifest,
  });

  final bool ok;
  final String message;
  final BackupManifest? manifest;
}

/// 已校验、可直接落盘的备份内容。
class BackupContents {
  const BackupContents({
    required this.manifest,
    required this.settingsBytes,
    required this.databaseBytes,
    this.auxiliaryFiles = const {},
  });

  final BackupManifest manifest;
  final Uint8List settingsBytes;
  final Uint8List databaseBytes;
  final Map<String, Uint8List> auxiliaryFiles;
}

class BackupService {
  // 命名参数用 `log`、字段用 `_log`：与仓库其它 service 一致。
  // ignore: prefer_initializing_formals
  BackupService({required this.paths, LogService? log}) : _log = log;

  final AppPaths paths;
  final LogService? _log;

  /// 生成备份到 [outputPath]（父目录不存在时创建）。
  Future<BackupCreateResult> createBackup({
    required AppDatabase database,
    required String outputPath,
    required String appVersion,
    DateTime? now,
  }) async {
    final timestamp = now ?? DateTime.now();
    final target = outputPath.trim();
    if (target.isEmpty) {
      return const BackupCreateResult(ok: false, path: '', message: '备份路径为空');
    }
    final snapshot = p.join(
      paths.cacheDir,
      'backup-snapshot-${timestamp.microsecondsSinceEpoch}.sqlite3',
    );
    try {
      await Directory(paths.cacheDir).create(recursive: true);
      database.backupTo(snapshot);
      final databaseBytes = await File(snapshot).readAsBytes();
      final settingsFile = File(paths.settingsPath);
      final settingsBytes = await settingsFile.exists()
          ? await settingsFile.readAsBytes()
          : Uint8List(0);
      final reader = File(p.join(paths.configDir, 'reader_tts.json'));
      final auxiliary = <String, Uint8List>{
        karaokeBackupUserDataFile: Uint8List.fromList(
          utf8.encode(await exportKaraokeUserFiles(paths)),
        ),
        aiBackupUserDataFile: Uint8List.fromList(
          utf8.encode(await exportAiUserFiles(paths)),
        ),
        if (await reader.exists())
          aiBackupReaderFile: await reader.readAsBytes(),
      };
      final manifest = buildBackupManifest(
        files: {
          backupSettingsFile: settingsBytes,
          backupDatabaseFile: databaseBytes,
          ...auxiliary,
        },
        createdAt: timestamp.millisecondsSinceEpoch,
        appVersion: appVersion,
        databaseSchema: AppDatabase.schemaVersion,
        stats: BackupStats(
          configs: _count(database, 'configs'),
          history: _count(database, 'history'),
          favorites: _count(database, 'favorites'),
        ),
      );
      final archive = Archive()
        ..add(
          ArchiveFile.string(
            backupManifestFile,
            const JsonEncoder.withIndent('  ').convert(manifest.toJson()),
          ),
        )
        ..add(
          ArchiveFile(backupSettingsFile, settingsBytes.length, settingsBytes),
        )
        ..add(
          ArchiveFile(backupDatabaseFile, databaseBytes.length, databaseBytes),
        );
      for (final entry in auxiliary.entries) {
        archive.add(ArchiveFile(entry.key, entry.value.length, entry.value));
      }
      final bytes = ZipEncoder().encodeBytes(archive);
      final output = File(target);
      await output.parent.create(recursive: true);
      final temp = File('$target.tmp');
      await temp.writeAsBytes(bytes, flush: true);
      if (await output.exists()) await output.delete();
      await temp.rename(target);
      _log?.info(
        '备份完成 path=${p.basename(target)} bytes=${bytes.length} '
        '${describeBackupManifest(manifest)}',
        scope: 'backup',
      );
      return BackupCreateResult(
        ok: true,
        path: target,
        message: '备份完成（${bytes.length} 字节）',
        manifest: manifest,
      );
    } catch (error) {
      _log?.error('备份失败：$error', scope: 'backup');
      return BackupCreateResult(
        ok: false,
        path: target,
        message: '备份失败：$error',
      );
    } finally {
      try {
        final tempFile = File(snapshot);
        if (tempFile.existsSync()) tempFile.deleteSync();
      } catch (_) {}
    }
  }

  /// 校验备份（不落盘、不关闭数据库）。
  Future<BackupInspectionResult> inspect(String path) async {
    try {
      final decoded = await _decode(path);
      if (decoded.issue != null) {
        return BackupInspectionResult(ok: false, message: decoded.issue!);
      }
      return BackupInspectionResult(
        ok: true,
        message: '备份有效（${decoded.contents!.manifest.entries.length} 个文件）',
        manifest: decoded.contents!.manifest,
      );
    } catch (error) {
      return BackupInspectionResult(ok: false, message: '读取备份失败：$error');
    }
  }

  /// 校验并取出恢复所需内容。
  Future<BackupContents> readForRestore(String path) async {
    final decoded = await _decode(path);
    if (decoded.issue != null) {
      throw FormatException(decoded.issue!);
    }
    return decoded.contents!;
  }

  Future<_DecodedBackup> _decode(String path) async {
    final file = File(path.trim());
    if (!await file.exists()) {
      return const _DecodedBackup(issue: '备份文件不存在');
    }
    final bytes = await file.readAsBytes();
    if (bytes.length > 512 * 1024 * 1024) {
      return const _DecodedBackup(issue: '备份文件过大（>512 MiB）');
    }
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (error) {
      return _DecodedBackup(issue: '不是有效的 zip：$error');
    }
    final files = <String, Uint8List>{};
    for (final entry in archive) {
      if (!entry.isFile) continue;
      // 重复条目会让「校验的是 A、写盘的是 B」：直接拒绝。
      if (files.containsKey(entry.name)) {
        return _DecodedBackup(issue: 'zip 包含重复条目：${entry.name}');
      }
      files[entry.name] = Uint8List.fromList(entry.content);
    }
    final manifestBytes = files[backupManifestFile];
    if (manifestBytes == null) {
      return const _DecodedBackup(issue: '备份缺少 manifest.json');
    }
    final BackupManifest? manifest;
    try {
      manifest = BackupManifest.tryParse(
        jsonDecode(utf8.decode(manifestBytes, allowMalformed: true)),
      );
    } catch (_) {
      return const _DecodedBackup(issue: 'manifest.json 无法解析');
    }
    if (manifest == null) {
      return const _DecodedBackup(issue: 'manifest.json 字段不完整');
    }
    final check = validateBackup(
      manifest: manifest,
      files: files,
      supportedSchema: AppDatabase.schemaVersion,
    );
    if (!check.ok) return _DecodedBackup(issue: check.issue);
    final auxiliary = <String, Uint8List>{
      for (final name in [
        aiBackupUserDataFile,
        aiBackupReaderFile,
        karaokeBackupUserDataFile,
      ])
        if (files[name] != null && manifest.entries.any((e) => e.path == name))
          name: files[name]!,
    };
    try {
      if (auxiliary[karaokeBackupUserDataFile] case final bytes?) {
        decodeKaraokeUserFiles(utf8.decode(bytes));
      }
      if (auxiliary[aiBackupUserDataFile] case final bytes?) {
        decodeAiUserFiles(utf8.decode(bytes));
      }
      if (auxiliary[aiBackupReaderFile] case final bytes?) {
        if (jsonDecode(utf8.decode(bytes)) is! Map) {
          throw const FormatException('阅读器偏好损坏');
        }
      }
    } catch (error) {
      return _DecodedBackup(issue: 'AI用户数据校验失败：$error');
    }
    final databaseBytes = files[backupDatabaseFile]!;
    final settingsBytes = files[backupSettingsFile] ?? Uint8List(0);
    return _DecodedBackup(
      contents: BackupContents(
        manifest: manifest,
        settingsBytes: settingsBytes,
        databaseBytes: databaseBytes,
        auxiliaryFiles: auxiliary,
      ),
    );
  }

  static int _count(AppDatabase database, String table) {
    try {
      return database.count(table);
    } catch (_) {
      return 0;
    }
  }
}

class _DecodedBackup {
  const _DecodedBackup({this.contents, this.issue});

  final BackupContents? contents;
  final String? issue;
}
