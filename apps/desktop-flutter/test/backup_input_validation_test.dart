import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/backup_manifest.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/backup_service.dart';
import 'package:webhtv_pc/services/backup_archive_reader.dart';

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

BackupManifest _manifest(Map<String, Uint8List> files) => buildBackupManifest(
  files: files,
  createdAt: 1,
  appVersion: 'old-v1',
  databaseSchema: 1,
);

Map<String, Uint8List> _backup({Map<String, Uint8List>? listed}) {
  final payload = listed ?? {backupDatabaseFile: _bytes('db')};
  return {
    backupManifestFile: _bytes(jsonEncode(_manifest(payload).toJson())),
    ...payload,
  };
}

Uint8List _zip(Map<String, Uint8List> files) {
  final archive = Archive();
  for (final file in files.entries) {
    archive.add(ArchiveFile(file.key, file.value.length, file.value));
  }
  return ZipEncoder().encodeBytes(archive);
}

// Independent ZIP fixture writer: Archive.add would hide duplicate names.
Uint8List _rawZip(List<_Entry> entries) {
  final output = OutputMemoryStream();
  final offsets = <int>[];
  final compressed = <List<int>>[];
  for (final entry in entries) {
    offsets.add(output.length);
    final name = utf8.encode(entry.name);
    final data = entry.deflate
        ? ZLibCodec(raw: true, level: entry.level).encode(entry.bytes)
        : entry.bytes;
    compressed.add(data);
    output
      ..writeUint32(0x04034b50)
      ..writeUint16(20)
      ..writeUint16(entry.flags)
      ..writeUint16(entry.method)
      ..writeUint32(0)
      ..writeUint32(getCrc32(entry.bytes))
      ..writeUint32(data.length)
      ..writeUint32(entry.declaredSize ?? entry.bytes.length)
      ..writeUint16(name.length)
      ..writeUint16(0)
      ..writeBytes(name)
      ..writeBytes(data);
    if (entry.flags & 8 != 0) {
      output
        ..writeUint32(0x08074b50)
        ..writeUint32(getCrc32(entry.bytes))
        ..writeUint32(data.length)
        ..writeUint32(entry.declaredSize ?? entry.bytes.length);
    }
  }
  final central = output.length;
  for (var i = 0; i < entries.length; i++) {
    final entry = entries[i];
    final name =
        entry.centralNameBytes ?? utf8.encode(entry.centralName ?? entry.name);
    output
      ..writeUint32(0x02014b50)
      ..writeUint16(0x0314)
      ..writeUint16(20)
      ..writeUint16(entry.flags)
      ..writeUint16(entry.method)
      ..writeUint32(0)
      ..writeUint32(getCrc32(entry.bytes))
      ..writeUint32(compressed[i].length)
      ..writeUint32(entry.declaredSize ?? entry.bytes.length)
      ..writeUint16(name.length)
      ..writeUint16(0)
      ..writeUint16(0)
      ..writeUint16(0)
      ..writeUint16(0)
      ..writeUint32(entry.mode << 16)
      ..writeUint32(offsets[i])
      ..writeBytes(name);
  }
  final centralSize = output.length - central;
  output
    ..writeUint32(0x06054b50)
    ..writeUint16(0)
    ..writeUint16(0)
    ..writeUint16(entries.length)
    ..writeUint16(entries.length)
    ..writeUint32(centralSize)
    ..writeUint32(central)
    ..writeUint16(0);
  return output.getBytes();
}

class _Entry {
  const _Entry(
    this.name,
    this.bytes, {
    this.centralName,
    this.centralNameBytes,
    this.mode = 0x8000,
    this.flags = 0,
    this.method = 0,
    this.declaredSize,
    this.level = 6,
  });
  final String name;
  final Uint8List bytes;
  final String? centralName;
  final List<int>? centralNameBytes;
  final int mode;
  final int flags;
  final int method;
  final int? declaredSize;
  final int level;
  bool get deflate => method == 8;
}

class _ObservedFile implements File {
  _ObservedFile(this.file, {this.growAfterFirstRead = false});
  final File file;
  final bool growAfterFirstRead;
  late _ObservedHandle handle;
  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) async {
    return handle = _ObservedHandle(await file.open(mode: mode), this);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ObservedHandle implements RandomAccessFile {
  _ObservedHandle(this.inner, this.owner);
  final RandomAccessFile inner;
  final _ObservedFile owner;
  int reads = 0;
  int bytesRead = 0;
  bool closed = false;
  @override
  Future<int> length() => inner.length();
  @override
  Future<Uint8List> read(int bytes) async {
    if (reads++ == 1 && owner.growAfterFirstRead) {
      owner.file.writeAsBytesSync([0, 0], mode: FileMode.append);
    }
    final result = await inner.read(bytes);
    bytesRead += result.length;
    return result;
  }

  @override
  Future<void> close() async {
    closed = true;
    await inner.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory temp;
  late BackupService service;
  setUp(() {
    temp = Directory.systemTemp.createTempSync('backup-validation-');
    service = BackupService(
      paths: AppPaths.resolve(
        overrides: {'roaming': temp.path, 'local': temp.path},
      ),
    );
  });
  tearDown(() => temp.deleteSync(recursive: true));

  Future<BackupInspectionResult> inspect(Uint8List zip) async {
    final file = File('${temp.path}/backup.zip');
    file.writeAsBytesSync(zip);
    return service.inspect(file.path);
  }

  for (final name in backupRestorableFiles) {
    test('unlisted restorable payload $name is rejected by validator', () {
      final listed = name == backupDatabaseFile
          ? {'metadata.txt': _bytes('legacy metadata')}
          : {backupDatabaseFile: _bytes('db')};
      final result = validateBackup(
        manifest: _manifest(listed),
        files: {...listed, name: _bytes('{}')},
        supportedSchema: 1,
      );
      expect(result.ok, isFalse);
      expect(result.issue, contains('清单'));
    });
    test(
      'unlisted restorable payload $name cannot reach restore contents',
      () async {
        final listed = name == backupDatabaseFile
            ? {'metadata.txt': _bytes('legacy metadata')}
            : {backupDatabaseFile: _bytes('db')};
        final file = File('${temp.path}/unlisted.zip')
          ..writeAsBytesSync(
            _zip({..._backup(listed: listed), name: _bytes('{}')}),
          );
        await expectLater(
          service.readForRestore(file.path),
          throwsFormatException,
        );
      },
    );
  }

  test(
    'legacy v1 may omit settings and unknown safe files remain unconsumed',
    () async {
      final file = File('${temp.path}/legacy.zip')
        ..writeAsBytesSync(
          _zip({..._backup(), 'future/safe.bin': _bytes('future')}),
        );
      final result = await service.readForRestore(file.path);
      expect(result.databaseBytes, [100, 98]);
      expect(result.settingsBytes, isEmpty);
      expect(result.auxiliaryFiles, isEmpty);
    },
  );

  test(
    'ZIP duplicate paths are rejected before Archive can merge them',
    () async {
      final files = _backup();
      final result = await inspect(
        _rawZip([
          for (final e in files.entries) _Entry(e.key, e.value),
          _Entry(backupDatabaseFile, files[backupDatabaseFile]!),
        ]),
      );
      expect(result.ok, isFalse);
      expect(result.message, contains('重复'));
    },
  );

  for (final mode in [0xa000, 0x1000, 0x2000, 0x6000, 0xc000]) {
    test(
      'ZIP special Unix type $mode is rejected before payload decode',
      () async {
        final result = await inspect(
          _rawZip([
            for (final e in _backup().entries) _Entry(e.key, e.value),
            _Entry('special', _bytes('target'), mode: mode),
          ]),
        );
        expect(result.ok, isFalse);
        expect(result.message, contains('特殊'));
      },
    );
  }

  for (final path in ['../escape', '/absolute', r'a\b', 'a/./b']) {
    test('unlisted unsafe ZIP path $path is rejected', () async {
      final result = await inspect(
        _rawZip([
          for (final e in _backup().entries) _Entry(e.key, e.value),
          _Entry(path, _bytes('bad')),
        ]),
      );
      expect(result.ok, isFalse);
      expect(result.message, contains('路径'));
    });
  }

  test('local and central ZIP names must agree', () async {
    final result = await inspect(
      _rawZip([
        for (final e in _backup().entries) _Entry(e.key, e.value),
        _Entry('local', _bytes('x'), centralName: 'central'),
      ]),
    );
    expect(result.ok, isFalse);
    expect(result.message, contains('不一致'));
  });

  test('local ZIP names are length-delimited, not NUL terminated', () async {
    final result = await inspect(
      _rawZip([
        for (final e in _backup().entries) _Entry(e.key, e.value),
        _Entry('name\x00hidden', _bytes('x'), centralName: 'name'),
      ]),
    );
    expect(result.ok, isFalse);
    expect(result.message, contains('不一致'));
  });

  test('ZIP count includes directories and rejects the 65th entry', () async {
    final result = await inspect(
      _rawZip([
        for (final e in _backup().entries) _Entry(e.key, e.value),
        for (var i = 0; i < 63; i++)
          _Entry('dir$i/', Uint8List(0), mode: 0x4000),
      ]),
    );
    expect(result.ok, isFalse);
    expect(result.message, contains('条目'));
  });

  test('manifest expansion is limited to 1 MiB', () async {
    final files = _backup();
    files[backupManifestFile] = _bytes(
      '${utf8.decode(files[backupManifestFile]!)}${' ' * (1024 * 1024)}',
    );
    final result = await inspect(_zip(files));
    expect(result.ok, isFalse);
    expect(result.message, contains('manifest'));
  });

  test(
    'dishonest deflate size is stopped during actual back-reference output',
    () async {
      final result = await inspect(
        _rawZip([
          for (final e in _backup().entries) _Entry(e.key, e.value),
          _Entry('bomb', Uint8List(1024 * 1024), method: 8, declaredSize: 64),
        ]),
      );
      expect(result.ok, isFalse);
      expect(result.message, contains('实际展开'));
    },
  );
  test(
    'compressed byte exact boundary passes and plus one is rejected',
    () async {
      final zip = _zip(_backup());
      service = BackupService(
        paths: service.paths,
        readLimits: BackupReadLimits(compressedBytes: zip.length),
      );
      expect((await inspect(zip)).ok, isTrue);
      service = BackupService(
        paths: service.paths,
        readLimits: BackupReadLimits(compressedBytes: zip.length - 1),
      );
      final result = await inspect(zip);
      expect(result.ok, isFalse);
      expect(result.message, contains('压缩体'));
    },
  );

  test(
    'single expansion exact boundary passes and plus one is rejected',
    () async {
      final files = {..._backup(), 'unknown': Uint8List(512)};
      service = BackupService(
        paths: service.paths,
        readLimits: const BackupReadLimits(entryBytes: 512),
      );
      expect((await inspect(_zip(files))).ok, isTrue);
      final result = await inspect(_zip({...files, 'unknown': Uint8List(513)}));
      expect(result.ok, isFalse);
      expect(result.message, contains('单项'));
    },
  );

  test(
    'total expansion exact boundary passes and plus one is rejected',
    () async {
      final files = {..._backup(), 'unknown': Uint8List(3)};
      final total = files.values.fold<int>(0, (sum, b) => sum + b.length);
      service = BackupService(
        paths: service.paths,
        readLimits: BackupReadLimits(expandedBytes: total),
      );
      expect((await inspect(_zip(files))).ok, isTrue);
      final result = await inspect(_zip({...files, 'unknown': Uint8List(4)}));
      expect(result.ok, isFalse);
      expect(result.message, contains('累计'));
    },
  );

  test('manifest exact boundary passes and plus one is rejected', () async {
    final files = _backup();
    final manifest = files[backupManifestFile]!;
    service = BackupService(
      paths: service.paths,
      readLimits: BackupReadLimits(manifestBytes: manifest.length),
    );
    expect((await inspect(_zip(files))).ok, isTrue);
    final result = await inspect(
      _zip({...files, backupManifestFile: _bytes('${utf8.decode(manifest)} ')}),
    );
    expect(result.ok, isFalse);
    expect(result.message, contains('manifest'));
  });

  test('entry count exact boundary includes directories', () async {
    final zip = _rawZip([
      for (final e in _backup().entries) _Entry(e.key, e.value),
      _Entry('dir/', Uint8List(0), mode: 0x4000),
    ]);
    service = BackupService(
      paths: service.paths,
      readLimits: const BackupReadLimits(entries: 3),
    );
    expect((await inspect(zip)).ok, isTrue);
    service = BackupService(
      paths: service.paths,
      readLimits: const BackupReadLimits(entries: 2),
    );
    final result = await inspect(zip);
    expect(result.ok, isFalse);
    expect(result.message, contains('条目'));
  });
  test(
    'oversize opened file is rejected without any payload read and closed',
    () async {
      final file = _ObservedFile(
        File('${temp.path}/large.zip')..writeAsBytesSync(_zip(_backup())),
      );
      await expectLater(
        const BackupArchiveReader(limits: BackupReadLimits(compressedBytes: 1))
            .read(file),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'diagnostic',
            contains('压缩体'),
          ),
        ),
      );
      expect(file.handle.reads, 0);
      expect(file.handle.closed, isTrue);
    },
  );

  test(
    'file growth after handle length check is bounded and handle closes',
    () async {
      final zip = _zip(_backup());
      final file = _ObservedFile(
        File('${temp.path}/growing.zip')..writeAsBytesSync(zip),
        growAfterFirstRead: true,
      );
      await expectLater(
        BackupArchiveReader(
          limits: BackupReadLimits(compressedBytes: zip.length),
        ).read(file),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'diagnostic',
            contains('增长'),
          ),
        ),
      );
      expect(file.handle.bytesRead, zip.length + 1);
      expect(file.handle.closed, isTrue);
    },
  );

  test('unknown listed files still receive SHA integrity checks', () async {
    final files = _backup(
      listed: {backupDatabaseFile: _bytes('db'), 'unknown': _bytes('good')},
    );
    files['unknown'] = _bytes('evil');
    final result = await inspect(_zip(files));
    expect(result.ok, isFalse);
    expect(result.message, contains('校验失败'));
  });

  test('valid listed settings and auxiliary semantics are preserved', () async {
    final files = _backup(
      listed: {
        backupDatabaseFile: _bytes('db'),
        backupSettingsFile: _bytes('{}'),
        'reader.json': _bytes('{}'),
      },
    );
    expect((await inspect(_zip(files))).ok, isTrue);
    final invalid = _backup(
      listed: {backupDatabaseFile: _bytes('db'), 'reader.json': _bytes('[]')},
    );
    final result = await inspect(_zip(invalid));
    expect(result.ok, isFalse);
    expect(result.message, contains('用户数据校验失败'));
  });

  for (final flags in [1, 0x40]) {
    test('encrypted ZIP flags $flags are rejected', () async {
      final result = await inspect(
        _rawZip([
          for (final e in _backup().entries) _Entry(e.key, e.value),
          _Entry('encrypted', _bytes('x'), flags: flags),
        ]),
      );
      expect(result.ok, isFalse);
      expect(result.message, contains('不支持'));
    });
  }

  test('unsupported compression method is rejected', () async {
    final result = await inspect(
      _rawZip([
        for (final e in _backup().entries) _Entry(e.key, e.value),
        _Entry('unsupported', _bytes('x'), method: 12),
      ]),
    );
    expect(result.ok, isFalse);
    expect(result.message, contains('不支持'));
  });

  test('local and central size must agree before inflate', () async {
    final zip = _rawZip([
      for (final e in _backup().entries) _Entry(e.key, e.value),
    ]);
    ByteData.sublistView(zip).setUint32(22, 1, Endian.little);
    final result = await inspect(zip);
    expect(result.ok, isFalse);
    expect(result.message, contains('不一致'));
  });

  test(
    'metadata rejection happens before an earlier dishonest inflate',
    () async {
      final result = await inspect(
        _rawZip([
          for (final e in _backup().entries) _Entry(e.key, e.value),
          _Entry('bomb', Uint8List(1024 * 1024), method: 8, declaredSize: 1),
          _Entry('special', _bytes('target'), mode: 0xa000),
        ]),
      );
      expect(result.ok, isFalse);
      expect(result.message, contains('特殊'));
      expect(result.message, isNot(contains('实际展开')));
    },
  );
  for (final field in [4, 10, 12]) {
    test(
      'local version/time field $field must agree with central metadata',
      () async {
        final zip = _rawZip([
          for (final e in _backup().entries) _Entry(e.key, e.value),
        ]);
        ByteData.sublistView(zip)
            .setUint16(field, field == 4 ? 21 : 1, Endian.little);
        final result = await inspect(zip);
        expect(result.ok, isFalse);
        expect(result.message, contains('不一致'));
      },
    );
  }

  for (final level in [0, 6]) {
    test(
      'deflate output path level $level stops before oversized write',
      () async {
        final result = await inspect(
          _rawZip([
            for (final e in _backup().entries) _Entry(e.key, e.value),
            _Entry(
              'bomb',
              Uint8List.fromList(List.generate(65536, (i) => i % 251)),
              method: 8,
              declaredSize: 0,
              level: level,
            ),
          ]),
        );
        expect(result.ok, isFalse);
        expect(result.message, contains('实际展开'));
      },
    );
  }

  test(
    'stored bytes with dishonest declared size are bounded before copy',
    () async {
      final result = await inspect(
        _rawZip([
          for (final e in _backup().entries) _Entry(e.key, e.value),
          _Entry('stored', Uint8List(8192), declaredSize: 1),
        ]),
      );
      expect(result.ok, isFalse);
      expect(result.message, contains('实际展开'));
    },
  );

  test('valid ZIP data descriptor remains compatible', () async {
    final result = await inspect(
      _rawZip([
        for (final e in _backup().entries)
          _Entry(e.key, e.value, method: 8, flags: 8),
      ]),
    );
    expect(result.ok, isTrue, reason: result.message);
  });

  test(
    'default entry budget accepts exactly 64 entries including directories',
    () async {
      final result = await inspect(
        _rawZip([
          for (final e in _backup().entries) _Entry(e.key, e.value),
          for (var i = 0; i < 62; i++)
            _Entry('dir$i/', Uint8List(0), mode: 0x4000),
        ]),
      );
      expect(result.ok, isTrue, reason: result.message);
    },
  );
  test(
    'local and central filenames must match bytes not just decoded text',
    () async {
      final result = await inspect(
        _rawZip([
          for (final e in _backup().entries) _Entry(e.key, e.value),
          _Entry('é', _bytes('x'), centralNameBytes: [0xe9]),
        ]),
      );
      expect(result.ok, isFalse);
      expect(result.message, contains('不一致'));
    },
  );
}
