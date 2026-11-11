part of 'python_environment.dart';

const _zipCap = 64 * 1024 * 1024;
const _expandedCap = 128 * 1024 * 1024;
const _fileCap = 10000;

class _PythonBundleStore {
  _PythonBundleStore(String data, String config, {this.writeStamp})
    : root = p.join(p.absolute(data), 'runtime', 'python'),
      configRoot = p.absolute(config);
  final String root;
  final String configRoot;
  final int? writeStamp;
  String get _pointer => p.join(root, 'active.json');
  String get _preferences => p.join(configRoot, 'python-environment.json');

  bool _pointerDamaged = false;
  String? metadataError;

  Map<String, dynamic> selection() => _readJson(_preferences);
  void saveSelection(Map<String, dynamic> selection, {bool recover = false}) =>
      _atomicJson(
        _preferences,
        selection,
        recover: recover,
        writeStamp: writeStamp,
      );

  String? installed() {
    try {
      final generation = _readJson(_pointer)['generation'];
      if (generation is! String ||
          !RegExp(r'^env-[a-z0-9-]+$').hasMatch(generation)) {
        if (File(_pointer).existsSync()) throw StateError('运行时指针结构无效');
        return null;
      }
      final directory = p.join(root, generation);
      _assertNoLinks(directory);
      final files = _manifestFiles(
        _readJson(p.join(directory, '.bundle.json')),
      );
      for (final item in files.values) {
        final file = File(
          p.joinAll([directory, ...(item['path'] as String).split('/')]),
        );
        _assertNoLinks(file.path);
        if (!file.existsSync() ||
            file.lengthSync() != item['size'] ||
            sha256.convert(file.readAsBytesSync()).toString() !=
                item['sha256']) {
          return null;
        }
      }
      return p.join(directory, 'python.exe');
    } catch (error) {
      _pointerDamaged = true;
      metadataError = '运行时元数据损坏：$error；请离线修复或恢复默认';
      return null;
    }
  }

  Future<String> prepare(
    String bundle,
    PythonEnvironmentProbe probe,
    Map<String, String>? environment,
  ) async {
    _assertNoLinks(bundle);
    final manifestFile = File(p.join(bundle, 'bundle.json'));
    _assertNoLinks(manifestFile.path);
    if (manifestFile.lengthSync() > 4 * 1024 * 1024) throw StateError('清单超出限制');
    final manifest =
        jsonDecode(manifestFile.readAsStringSync()) as Map<String, dynamic>;
    final expected = _manifestFiles(manifest);
    final zipFile = File(p.join(bundle, 'python-runtime.zip'));
    _assertNoLinks(zipFile.path);
    if (zipFile.lengthSync() > _zipCap) throw StateError('ZIP 超过 64MiB');
    final bytes = zipFile.readAsBytesSync();
    if (bytes.length > _zipCap ||
        sha256.convert(bytes).toString() != manifest['archiveSha256']) {
      throw StateError('ZIP SHA256 校验失败');
    }
    final directory = ZipDirectory()..read(InputMemoryStream(bytes));
    if (directory.fileHeaders.isEmpty ||
        directory.fileHeaders.length > _fileCap) {
      throw StateError('ZIP 文件数无效');
    }
    final seen = <String>{};
    var expanded = 0;
    for (final header in directory.fileHeaders) {
      final local = header.file;
      final path = header.filename;
      final isDir = path.endsWith('/');
      _safeRelative(isDir ? path.substring(0, path.length - 1) : path);
      if (!seen.add(path.toLowerCase())) throw StateError('ZIP 重复路径');
      final mode = header.externalFileAttributes >> 16;
      final type = mode & 0xf000;
      if (type != 0 && type != 0x8000 && type != 0x4000 ||
          header.externalFileAttributes & 0x400 != 0) {
        throw StateError('ZIP 链接或特殊文件被拒绝');
      }
      if (header.generalPurposeBitFlag & 1 != 0 ||
          ![0, 8].contains(header.compressionMethod)) {
        throw StateError('ZIP 加密/压缩方式不支持');
      }
      if (local == null ||
          local.filename != path ||
          local.uncompressedSize != header.uncompressedSize) {
        throw StateError('ZIP 本地/中央目录不一致');
      }
      if (isDir) {
        if (header.uncompressedSize != 0 ||
            !expected.keys.any((k) => k.startsWith(path.toLowerCase()))) {
          throw StateError('ZIP 目录无效');
        }
        continue;
      }
      final item = expected[path.toLowerCase()];
      if (item == null ||
          item['path'] != path ||
          item['size'] != header.uncompressedSize) {
        throw StateError('ZIP 文件清单/尺寸不匹配');
      }
      expanded += header.uncompressedSize;
      if (expanded > _expandedCap) throw StateError('展开超过 128MiB');
    }
    if (expected.keys.any((k) => !seen.contains(k))) {
      throw StateError('ZIP 缺少清单文件');
    }
    _assertNoLinks(root);
    Directory(root).createSync(recursive: true);
    final stage = Directory(
      p.join(root, 'env-${DateTime.now().microsecondsSinceEpoch}-$pid'),
    );
    if (stage.existsSync()) throw StateError('stage 已存在');
    stage.createSync();
    var committed = false;
    try {
      for (final header in directory.fileHeaders) {
        if (header.filename.endsWith('/')) continue;
        final item = expected[header.filename.toLowerCase()]!;
        final output = _CappedOutput(item['size'] as int);
        header.file!.decompress(output);
        final content = output.getBytes();
        if (content.length != item['size'] ||
            sha256.convert(content).toString() != item['sha256'] ||
            getCrc32(content) != header.crc32) {
          throw StateError('文件 SHA256/尺寸/CRC 校验失败：${header.filename}');
        }
        final file = File(
          p.joinAll([stage.path, ...header.filename.split('/')]),
        );
        file.parent.createSync(recursive: true);
        file.writeAsBytesSync(content, flush: true);
      }
      File(p.join(stage.path, '.bundle.json'))
          .writeAsStringSync(jsonEncode(manifest), flush: true);
      final executable = p.join(stage.path, 'python.exe');
      final status = await probe(
        executable,
        const [],
        PythonEnvironmentSource.bundled,
        environment,
      );
      if (!status.ready || status.version != manifest['pythonVersion']) {
        throw StateError('stage Python 未就绪/版本不匹配：${status.error}');
      }
      _atomicJson(
        _pointer,
        {'generation': p.basename(stage.path)},
        recover: _pointerDamaged,
        writeStamp: writeStamp,
      );
      committed = true;
      return executable;
    } finally {
      if (!committed) {
        _assertNoLinks(stage.path);
        if (p.isWithin(root, stage.path) && stage.existsSync()) {
          stage.deleteSync(recursive: true);
        }
      }
    }
  }
}

Map<String, Map<String, dynamic>> _manifestFiles(
  Map<String, dynamic> manifest,
) {
  if (manifest['schemaVersion'] != 1 ||
      manifest['platform'] != 'windows-x64' ||
      manifest['archive'] != 'python-runtime.zip' ||
      manifest['pythonVersion'] is! String ||
      !RegExp(r'^3\.\d+\.\d+$').hasMatch(manifest['pythonVersion'] as String) ||
      manifest['archiveSha256'] is! String ||
      !_hash(manifest['archiveSha256']) ||
      jsonEncode(manifest['probeModules']) !=
          jsonEncode(['requests', 'Crypto', 'lxml', 'bs4'])) {
    throw StateError('离线包 schema 无效');
  }
  final packages = manifest['packages'];
  if (packages is! List ||
      packages.isEmpty ||
      packages.any(
        (e) =>
            e is! Map ||
            e['name'] is! String ||
            (e['name'] as String).isEmpty ||
            e['version'] is! String ||
            (e['version'] as String).isEmpty,
      )) {
    throw StateError('包版本清单无效');
  }
  final files = manifest['files'];
  if (files is! List || files.isEmpty || files.length > _fileCap) {
    throw StateError('清单文件数无效');
  }
  final result = <String, Map<String, dynamic>>{};
  var size = 0;
  for (final entry in files) {
    if (entry is! Map<String, dynamic> ||
        entry['path'] is! String ||
        entry['size'] is! int ||
        entry['size'] < 0 ||
        entry['sha256'] is! String ||
        !_hash(entry['sha256'])) {
      throw StateError('文件清单无效');
    }
    final path = entry['path'] as String;
    _safeRelative(path);
    if (path.toLowerCase() == '.bundle.json' ||
        result.containsKey(path.toLowerCase())) {
      throw StateError('清单重复/保留路径');
    }
    size += entry['size'] as int;
    if (size > _expandedCap) throw StateError('清单展开超过 128MiB');
    result[path.toLowerCase()] = entry;
  }
  if (!result.containsKey('python.exe')) throw StateError('清单缺少 python.exe');
  for (final path in result.keys) {
    var parent = p.posix.dirname(path);
    while (parent != '.') {
      if (result.containsKey(parent)) throw StateError('文件/目录冲突');
      parent = p.posix.dirname(parent);
    }
  }
  return result;
}

bool _hash(String value) => RegExp(r'^[a-f0-9]{64}$').hasMatch(value);
void _safeRelative(String path) {
  if (path.isEmpty ||
      path.contains('\\') ||
      path.startsWith('/') ||
      path.contains(':')) {
    throw StateError('不安全路径');
  }
  for (final part in path.split('/')) {
    if (part.isEmpty ||
        part == '.' ||
        part == '..' ||
        part.endsWith('.') ||
        part.endsWith(' ') ||
        RegExp(r'[<>:"|?*\x00-\x1f]').hasMatch(part) ||
        RegExp(
          r'^(con|prn|aux|nul|com[1-9¹²³]|lpt[1-9¹²³])(?:\.|$)',
          caseSensitive: false,
        ).hasMatch(part)) {
      throw StateError('Windows 保留/穿越路径被拒绝');
    }
  }
}

void _assertNoLinks(String path) {
  var current = p.absolute(path);
  while (true) {
    if (FileSystemEntity.typeSync(current, followLinks: false) ==
        FileSystemEntityType.link) {
      throw StateError('根路径含链接：$current');
    }
    final parent = p.dirname(current);
    if (parent == current) break;
    current = parent;
  }
}

Map<String, dynamic> _readJson(String path) {
  _assertNoLinks(path);
  final file = File(path);
  if (!file.existsSync()) return {};
  if (file.lengthSync() > 4 * 1024 * 1024) throw StateError('JSON 文件超出限制');
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

void _atomicJson(
  String path,
  Map<String, dynamic> value, {
  bool recover = false,
  int? writeStamp,
}) {
  _assertNoLinks(path);
  final file = File(path);
  file.parent.createSync(recursive: true);
  final suffix = writeStamp ?? DateTime.now().microsecondsSinceEpoch;
  final temporary = File('$path-$suffix.tmp');
  File? backup;
  var committed = false;
  try {
    temporary.writeAsStringSync(jsonEncode(value), flush: true);
    _assertNoLinks(path);
    if (recover && file.existsSync()) {
      var target = '$path.invalid-$suffix';
      var collisions = 0;
      while (FileSystemEntity.typeSync(target, followLinks: false) !=
          FileSystemEntityType.notFound) {
        if (++collisions >= _fileCap) throw StateError('备份名称冲突过多，原文件保留');
        target = '$path.invalid-$suffix-$collisions';
      }
      _assertNoLinks(target);
      backup = file.renameSync(target);
    }
    temporary.renameSync(path);
    committed = true;
  } finally {
    if (!committed && backup != null && backup.existsSync()) {
      _assertNoLinks(path);
      backup.renameSync(path);
    }
    if (temporary.existsSync()) temporary.deleteSync();
  }
}

class _CappedOutput extends OutputMemoryStream {
  _CappedOutput(this.cap);
  final int cap;
  void _check(int count) {
    if (length + count > cap) throw StateError('实际展开超过清单尺寸');
  }

  @override
  void writeByte(int value) {
    _check(1);
    super.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    _check(length ?? bytes.length);
    super.writeBytes(bytes, length: length);
  }

  @override
  void writeStream(InputStream stream) {
    _check(stream.length);
    super.writeStream(stream);
  }

  @override
  void writeBackReference(int distance, int count) {
    _check(count);
    super.writeBackReference(distance, count);
  }
}
