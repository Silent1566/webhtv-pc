import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/backup_manifest.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/backup_page.dart';
import 'package:webhtv_pc/ui/theme.dart';

void main() {
  group('备份清单与路径安全（P2-7）', () {
    test('只接受相对、无 .. 的路径', () {
      expect(isSafeBackupPath('settings.json'), isTrue);
      expect(isSafeBackupPath('data/webhtv-pc.sqlite3'), isTrue);
      expect(isSafeBackupPath('/etc/passwd'), isFalse);
      expect(isSafeBackupPath(r'C:\Windows\win.ini'), isFalse);
      expect(isSafeBackupPath('../escape'), isFalse);
      expect(isSafeBackupPath('a/../../b'), isFalse);
      expect(isSafeBackupPath(r'a\b'), isFalse);
      expect(isSafeBackupPath(''), isFalse);
    });

    test('清单往返与严格解析', () {
      final files = {
        backupSettingsFile: Uint8List.fromList(utf8.encode('{"ui":{}}')),
        backupDatabaseFile: Uint8List.fromList([1, 2, 3, 4]),
      };
      final manifest = buildBackupManifest(
        files: files,
        createdAt: 1700000000000,
        appVersion: '0.1.0',
        databaseSchema: 5,
        stats: const BackupStats(configs: 2, history: 9, favorites: 3),
      );
      final parsed = parseBackupManifestJson(jsonEncode(manifest.toJson()));
      expect(parsed, isNotNull);
      expect(parsed!.format, backupFormatName);
      expect(parsed.version, backupFormatVersion);
      expect(parsed.stats.history, 9);
      expect(parsed.entries, hasLength(2));

      expect(parseBackupManifestJson('not json'), isNull);
      expect(parseBackupManifestJson('{"format":"other"}'), isNull);
    });

    test('校验：正常通过，篡改/缺文件/未来库版本全部拒绝', () {
      final files = {
        backupSettingsFile: Uint8List.fromList([1, 2, 3]),
        backupDatabaseFile: Uint8List.fromList([4, 5, 6]),
      };
      final manifest = buildBackupManifest(
        files: files,
        createdAt: 1,
        appVersion: '0.1.0',
        databaseSchema: 5,
      );
      expect(
        validateBackup(
          manifest: manifest,
          files: files,
          supportedSchema: 5,
        ).ok,
        isTrue,
      );

      final tampered = <String, Uint8List>{
        ...files,
        backupDatabaseFile: Uint8List.fromList([4, 5, 7]),
      };
      expect(
        validateBackup(
          manifest: manifest,
          files: tampered,
          supportedSchema: 5,
        ).issue,
        contains('校验失败'),
      );

      expect(
        validateBackup(
          manifest: manifest,
          files: {backupSettingsFile: files[backupSettingsFile]!},
          supportedSchema: 5,
        ).issue,
        contains('缺少文件'),
      );

      expect(
        validateBackup(
          manifest: manifest,
          files: files,
          supportedSchema: 4,
        ).issue,
        contains('更新的版本'),
      );
    });

    test('清单重复路径/不安全路径被拒绝', () {
      final bytes = Uint8List.fromList([1]);
      final entry = BackupEntry(
        path: 'a',
        size: 1,
        sha256: sha256Hex(bytes),
      );
      final duplicated = BackupManifest(
        format: backupFormatName,
        version: 1,
        createdAt: 1,
        appVersion: 'x',
        databaseSchema: 5,
        entries: [entry, entry],
        stats: BackupStats.empty,
      );
      expect(
        validateBackup(
          manifest: duplicated,
          files: {'a': bytes, backupDatabaseFile: bytes},
          supportedSchema: 5,
        ).issue,
        contains('重复路径'),
      );

      final unsafe = BackupManifest(
        format: backupFormatName,
        version: 1,
        createdAt: 1,
        appVersion: 'x',
        databaseSchema: 5,
        entries: [
          BackupEntry(path: '../x', size: 1, sha256: sha256Hex(bytes)),
        ],
        stats: BackupStats.empty,
      );
      expect(
        validateBackup(
          manifest: unsafe,
          files: {'../x': bytes, backupDatabaseFile: bytes},
          supportedSchema: 5,
        ).issue,
        contains('不安全路径'),
      );
    });

    test('默认文件名可读且稳定', () {
      expect(
        defaultBackupFileName(DateTime(2026, 10, 21, 23, 15, 0)),
        'webhtv-backup-20261021-231500.zip',
      );
    });
  });

  group('备份/恢复/重置（真实 SQLite）', () {
    late Directory temp;
    late AppPaths paths;
    late AppState state;

    setUp(() async {
      temp = Directory.systemTemp.createTempSync('webhtv-backup');
      paths = AppPaths.resolve(
        overrides: {
          'config': '${temp.path}${Platform.pathSeparator}config',
          'data': '${temp.path}${Platform.pathSeparator}data',
          'cache': '${temp.path}${Platform.pathSeparator}cache',
          'state': '${temp.path}${Platform.pathSeparator}logs',
        },
      );
      state = AppState(paths: paths, log: LogService());
      await state.bootstrap();
    });

    tearDown(() {
      state.dispose();
      try {
        temp.deleteSync(recursive: true);
      } catch (_) {}
    });

    Future<void> importConfig(String name, {String key = 'site-a'}) async {
      final ok = await state.importConfig(
        '{"name":"$name","sites":[{"key":"$key","name":"甲站",'
        '"type":4,"api":"http://127.0.0.1:1/vod/api?key=$key"}]}',
      );
      expect(ok, isTrue, reason: state.lastError?.logLine);
    }

    void seedHistory() {
      state.database!.upsertHistory(
        siteKey: 'site-a',
        vodId: 'vod-1',
        vodName: '剧集甲',
        flag: '线路一',
        episodeName: 'E1',
        episodeId: 'E1',
        positionMs: 120000,
        durationMs: 240000,
        // 归属到当前生效源：importConfig 之后 activeSourceKey 非空，
        // 而按源隔离的视图不显示空来源记录（用户 2026-10-28 要求严格过滤）。
        sourceKey: state.activeSourceKey,
      );
    }

    test('备份 → 检查 → 恢复后配置与历史一致', () async {
      await importConfig('配置 A');
      seedHistory();
      final backupPath = '${temp.path}${Platform.pathSeparator}backup.zip';

      final created = await state.createBackup(outputPath: backupPath);
      expect(created.ok, isTrue, reason: created.message);
      expect(File(backupPath).existsSync(), isTrue);
      expect(created.manifest!.stats.configs, 1);
      expect(created.manifest!.stats.history, 1);

      final inspected = await state.inspectBackup(backupPath);
      expect(inspected.ok, isTrue, reason: inspected.message);
      expect(inspected.manifest!.format, backupFormatName);

      // 改坏当前数据：换配置 + 删历史。
      await importConfig('配置 B', key: 'site-b');
      final historyId = state.recentHistory().first.id;
      state.database!.deleteHistory(historyId);
      expect(state.recentHistory(), isEmpty);
      expect(state.config!.name, '配置 B');

      final error = await state.restoreBackup(backupPath);
      expect(error, isNull);
      expect(state.config, isNotNull);
      expect(state.config!.name, '配置 A');
      expect(state.recentHistory(), hasLength(1));
      expect(state.recentHistory().first.vodName, '剧集甲');
      expect(state.configs.map((c) => c.name), contains('配置 A'));
    });

    test('坏备份不覆盖当前数据', () async {
      await importConfig('配置 A');
      seedHistory();
      final backupPath = '${temp.path}${Platform.pathSeparator}bad.zip';
      final created = await state.createBackup(outputPath: backupPath);
      expect(created.ok, isTrue);

      // 篡改 zip 内的数据库字节（重新打包并保留旧清单）。
      final archive = ZipDecoder().decodeBytes(
        File(backupPath).readAsBytesSync(),
      );
      final rebuilt = Archive();
      for (final file in archive) {
        if (!file.isFile) continue;
        final content = file.name == backupDatabaseFile
            ? Uint8List.fromList([1, 2, 3])
            : Uint8List.fromList(file.content);
        rebuilt.add(ArchiveFile(file.name, content.length, content));
      }
      File(backupPath).writeAsBytesSync(ZipEncoder().encodeBytes(rebuilt));

      final error = await state.restoreBackup(backupPath);
      expect(error, isNotNull);
      expect(error, contains('校验失败'));
      // 当前数据没有被替换。
      expect(state.config!.name, '配置 A');
      expect(state.recentHistory(), hasLength(1));
    });

    test('重置删除设置与数据库，回到未导入配置', () async {
      await importConfig('配置 A');
      seedHistory();
      expect(state.config, isNotNull);

      final error = await state.resetAllData();
      expect(error, isNull);
      expect(state.config, isNull);
      expect(state.configs, isEmpty);
      expect(state.recentHistory(), isEmpty);
      expect(state.configPhase, LoadPhase.idle);
      // 设置文件可能被 bootstrap 以默认值重建；关键是不再包含重置前的数据。
      final settingsFile = File(paths.settingsPath);
      if (settingsFile.existsSync()) {
        expect(settingsFile.readAsStringSync(), isNot(contains('site-a')));
        expect(settingsFile.readAsStringSync(), isNot(contains('配置 A')));
      }

      // 重置后仍能正常导入新配置（库已重建）。
      await importConfig('配置 C', key: 'site-c');
      expect(state.config!.name, '配置 C');
    });
  });

  group('备份页', () {
    testWidgets('渲染备份/恢复/重置入口，默认路径可编辑', (tester) async {
      final temp = Directory.systemTemp.createTempSync('webhtv-backup-page');
      final paths = AppPaths.resolve(
        overrides: {
          'config': '${temp.path}/config',
          'data': '${temp.path}/data',
          'cache': '${temp.path}/cache',
          'state': '${temp.path}/logs',
        },
      );
      final state = AppState(paths: paths, log: LogService());
      addTearDown(() {
        state.dispose();
        try {
          temp.deleteSync(recursive: true);
        } catch (_) {}
      });

      tester.view.physicalSize = const Size(1200, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.dark),
          home: BackupPage(state: state),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('backup-create')), findsOneWidget);
      expect(find.byKey(const ValueKey('backup-inspect')), findsOneWidget);
      expect(find.byKey(const ValueKey('backup-restore')), findsOneWidget);
      expect(find.byKey(const ValueKey('backup-reset')), findsOneWidget);
      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('backup-output-path')),
      );
      expect(field.controller!.text, contains('webhtv-backup-'));
    });
  });
}
