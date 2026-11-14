/// 本地爬虫源导入：把扫描候选落盘成宿主可识别的形态。
///
/// 三条落地路径（互不重叠，也不改动既有的远端直连登记 `direct_spider_registrar`）：
/// - `.py` → `<spiders>/local/<key>/`，写 `manifest.json`（`runtime` 为 `python`
///   或 `python-catvod`）。CatVod 壳按远端导入同一套策略包 `spider.py` 适配入口；
/// - `.js` → `<spiders>/local/<key>/`，`runtime` 记 `node-tvbox`；
/// - `.html` → `<webhome>/<key>/` + `registry.json` 一条记录（见 [WebHomeStore]）。
///
/// 纪律：
/// - 导入前**不执行**任何被导入文件；只做文本/字节层面的判定；
/// - key 冲突一律**拒绝**并提示改名（用户选择的安全侧），绝不静默覆盖既有源；
/// - 单文件与整目录都有大小上限，超限拒绝并如实返回原因；
/// - 失败只返回结构化原因，不影响其它候选。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../core/ipc_protocol.dart';
import 'direct_spider_registrar.dart' show catVodShellEntrySource;
import 'local_spider_scanner.dart';
import 'log_service.dart';
import 'spider_registry.dart';
import 'web_home_store.dart';

/// 单个候选的导入结论。
class LocalImportOutcome {
  const LocalImportOutcome({
    required this.key,
    required this.kind,
    required this.ok,
    this.targetDir = '',
    this.message = '',
  });

  final String key;
  final LocalSourceKind kind;
  final bool ok;
  final String targetDir;
  final String message;
}

/// 一批导入的汇总。
class LocalImportResult {
  const LocalImportResult({this.outcomes = const []});

  final List<LocalImportOutcome> outcomes;

  List<LocalImportOutcome> get imported =>
      outcomes.where((item) => item.ok).toList();

  List<LocalImportOutcome> get rejected =>
      outcomes.where((item) => !item.ok).toList();

  int get importedCount => imported.length;

  int get rejectedCount => rejected.length;

  bool get isEmpty => outcomes.isEmpty;
}

/// 本地源导入器。
class LocalSourceImporter {
  LocalSourceImporter({
    required this.spiderRoot,
    required this.registry,
    required this.webHomeStore,
    this.log,
    this.maxDirectoryBytes = 20 * 1024 * 1024,
  });

  /// Spider 根目录（`<configDir>/spiders`）；本地源落在其 `local/` 子目录。
  final String spiderRoot;
  final SpiderManifestRegistry registry;
  final WebHomeStore webHomeStore;
  final LogService? log;

  /// webHome 整目录复制上限（页面 + 资源）。
  final int maxDirectoryBytes;

  /// 本地源根目录。
  String get localRoot => p.join(spiderRoot, 'local');

  /// 导入勾选的候选；返回逐条结论（不抛异常）。
  Future<LocalImportResult> importSelected(
    Iterable<LocalSourceCandidate> picked,
  ) async {
    final outcomes = <LocalImportOutcome>[];
    for (final candidate in picked) {
      try {
        outcomes.add(await _importOne(candidate));
      } catch (error) {
        outcomes.add(
          LocalImportOutcome(
            key: candidate.key,
            kind: candidate.kind,
            ok: false,
            message: '导入异常：$error',
          ),
        );
      }
    }
    if (outcomes.any((item) => item.ok)) {
      log?.info(
        '本地源导入完成：成功 ${outcomes.where((e) => e.ok).length} / '
        '${outcomes.length}',
        scope: 'spider',
      );
    }
    return LocalImportResult(outcomes: outcomes);
  }

  Future<LocalImportOutcome> _writeNewDirectory({
    required LocalSourceCandidate candidate,
    required String targetDir,
    required String allowedRoot,
    required Future<LocalImportOutcome> Function() write,
  }) async {
    if (!p.equals(p.dirname(p.absolute(targetDir)), p.absolute(allowedRoot))) {
      throw ArgumentError('目标不在允许的导入根目录内');
    }
    Directory(allowedRoot).createSync(recursive: true);
    if (FileSystemEntity.typeSync(targetDir, followLinks: false) !=
        FileSystemEntityType.notFound) {
      return LocalImportOutcome(
        key: candidate.key,
        kind: candidate.kind,
        ok: false,
        message: '目标目录已存在，请改名后再导入',
      );
    }
    final rootAtCreation = Directory(allowedRoot).resolveSymbolicLinksSync();
    final ownedRoot = _WinDirectory.open(rootAtCreation);
    _WinDirectory? ownership;
    final dir = Directory(targetDir);
    final pathAtCreation = p.join(rootAtCreation, p.basename(targetDir));
    try {
      dir.createSync();
      String failure;
      try {
        ownership = _WinDirectory.open(pathAtCreation);
        if (!p.equals(dir.resolveSymbolicLinksSync(), pathAtCreation)) {
          throw StateError('本次创建的目标目录已变化');
        }
        final result = await write();
        if (result.ok) return result;
        failure = result.message;
      } catch (error) {
        failure = '导入异常：$error';
      }
      final rollback = _rollbackNewDirectory(
        dir,
        rootAtCreation,
        pathAtCreation,
        ownedRoot,
        ownership,
      );
      return LocalImportOutcome(
        key: candidate.key,
        kind: candidate.kind,
        ok: false,
        targetDir: targetDir,
        message: '$failure；$rollback',
      );
    } finally {
      ownership?.close();
      ownedRoot.close();
    }
  }

  String _rollbackNewDirectory(
    Directory dir,
    String rootAtCreation,
    String pathAtCreation,
    _WinDirectory ownedRoot,
    _WinDirectory? ownership,
  ) {
    final ownedLocation = ownership?.currentPath() ?? '目录身份未取得';
    _WinDirectory? lockedRoot;
    _WinDirectory? lockedTarget;
    try {
      final type = FileSystemEntity.typeSync(dir.path, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        return '未撤回：原目录路径已消失，无法确认其是否已移走（原路径 $pathAtCreation）；本次原目录：$ownedLocation';
      }
      if (type != FileSystemEntityType.directory ||
          ownership == null ||
          !p.isWithin(rootAtCreation, pathAtCreation)) {
        return '未撤回：无法确认目录身份，残留目录 $pathAtCreation；本次原目录：$ownedLocation';
      }
      // 保留原句柄防止 file-id 重用；无 SHARE_DELETE 的现路径句柄阻止替换。
      lockedRoot = _WinDirectory.open(rootAtCreation, lock: true);
      lockedTarget = _WinDirectory.open(
        pathAtCreation,
        lock: true,
        deleting: true,
      );
      if (!ownedRoot.sameIdentity(lockedRoot) ||
          !ownership.sameIdentity(lockedTarget) ||
          !p.equals(dir.resolveSymbolicLinksSync(), pathAtCreation)) {
        return '未撤回：目录身份已变化，残留目录 $pathAtCreation；本次原目录：$ownedLocation';
      }
      for (final child in dir.listSync(followLinks: false)) {
        child.deleteSync(recursive: true);
      }
      lockedTarget.deleteOnClose();
      ownership.close();
      lockedTarget.close();
      if (FileSystemEntity.typeSync(dir.path, followLinks: false) ==
          FileSystemEntityType.notFound) {
        return '已撤回';
      }
      return '未撤回：残留目录 $pathAtCreation；本次原目录：$ownedLocation';
    } catch (error) {
      return '未撤回：回滚失败，残留目录 $pathAtCreation；本次原目录：$ownedLocation：$error';
    } finally {
      lockedTarget?.close();
      lockedRoot?.close();
    }
  }

  Future<LocalImportOutcome> _importOne(LocalSourceCandidate candidate) async {
    if (!WebHomeStore.isValidKey(candidate.key)) {
      return LocalImportOutcome(
        key: candidate.key,
        kind: candidate.kind,
        ok: false,
        message: '非法源 key，不允许目录穿越',
      );
    }
    if (candidate.kind == LocalSourceKind.webHome) {
      return _importWebHome(candidate);
    }
    return _importSpider(candidate);
  }

  // -------------------------------------------------------------------------
  // py / js：写 manifest 后交给既有注册表
  // -------------------------------------------------------------------------

  Future<LocalImportOutcome> _importSpider(
    LocalSourceCandidate candidate,
  ) async {
    final targetDir = p.join(localRoot, candidate.key);
    final manifestPath = p.join(targetDir, 'manifest.json');

    if (File(manifestPath).existsSync()) {
      return LocalImportOutcome(
        key: candidate.key,
        kind: candidate.kind,
        ok: false,
        message: '已存在同名源（key=${candidate.key}），请改名后再导入',
      );
    }
    // 同 key 可能已被手工目录占用（没有 manifest 也算占用）。
    if (Directory(targetDir).existsSync()) {
      return LocalImportOutcome(
        key: candidate.key,
        kind: candidate.kind,
        ok: false,
        message: '目标目录已存在（${p.basename(targetDir)}），请改名后再导入',
      );
    }

    return _writeNewDirectory(
      candidate: candidate,
      targetDir: targetDir,
      allowedRoot: localRoot,
      write: () async {
        final bytes = await File(candidate.absPath).readAsBytes();
        final entrySha256 = sha256.convert(bytes).toString();

        late final String entry;
        late final String runtime;
        if (candidate.kind == LocalSourceKind.javaScript) {
          entry = 'spider.js';
          runtime = 'node-tvbox';
          await File(p.join(targetDir, entry)).writeAsBytes(bytes, flush: true);
        } else if (candidate.looksCatVod) {
          // CatVod 壳：原始蜘蛛存 loader.py，宿主入口用统一壳模板。
          entry = 'spider.py';
          runtime = 'python-catvod';
          await File(p.join(targetDir, 'loader.py'))
              .writeAsBytes(bytes, flush: true);
          await File(p.join(targetDir, 'loader.json')).writeAsString(
            jsonEncode({
              'loaderName': 'loader.py',
              'loaderSha256': entrySha256,
            }),
            flush: true,
          );
          await File(p.join(targetDir, entry))
              .writeAsString(catVodShellEntrySource, flush: true);
        } else {
          entry = 'spider.py';
          runtime = 'python';
          await File(p.join(targetDir, entry)).writeAsBytes(bytes, flush: true);
        }

        final manifest = SpiderManifest(
          key: candidate.key,
          name: candidate.name,
          runtime: runtime,
          entry: entry,
          capabilities: const ['home', 'category', 'detail', 'search', 'play'],
          entrySha256: candidate.looksCatVod
              ? sha256.convert(utf8.encode(catVodShellEntrySource)).toString()
              : entrySha256,
        );
        // `localSource` 是本地来源的附加元信息；SpiderManifest.toJson 不认识它，
        // 因此写完基础字段后再合并，避免改动 core 协议。
        final json = manifest.toJson()
          ..['localSource'] = {
            'origin': 'folder-scan',
            'importedFrom': candidate.absPath,
            'importedAt': DateTime.now().toIso8601String(),
            'modifiedAt': candidate.modified.toIso8601String(),
            'sourceSha256': entrySha256,
            'kind': candidate.kind.name,
          };
        await File(manifestPath).writeAsString(
          const JsonEncoder.withIndent('  ').convert(json),
          flush: true,
        );

        final local = await registry.register(manifestPath);
        if (local == null) {
          return LocalImportOutcome(
            key: candidate.key,
            kind: candidate.kind,
            ok: false,
            targetDir: targetDir,
            message: 'manifest 校验未通过',
          );
        }
        return LocalImportOutcome(
          key: candidate.key,
          kind: candidate.kind,
          ok: true,
          targetDir: targetDir,
          message: '${candidate.kind.label} 已导入（runtime=$runtime）',
        );
      },
    );
  }

  // -------------------------------------------------------------------------
  // html：整目录复制 + webHome 登记
  // -------------------------------------------------------------------------

  Future<LocalImportOutcome> _importWebHome(
    LocalSourceCandidate candidate,
  ) async {
    if (webHomeStore.contains(candidate.key)) {
      return LocalImportOutcome(
        key: candidate.key,
        kind: candidate.kind,
        ok: false,
        message: '已存在同名源（key=${candidate.key}），请改名后再导入',
      );
    }

    final sourceDir = Directory(candidate.sourceDir);
    final entryName = _pickWebHomeEntry(sourceDir, candidate);
    if (entryName == null) {
      return LocalImportOutcome(
        key: candidate.key,
        kind: candidate.kind,
        ok: false,
        message: '目录内没有可用的入口页面（需要 index.html 或所选 .html 文件）',
      );
    }

    final plan = await _planCopy(sourceDir);
    if (plan.bytes > maxDirectoryBytes) {
      return LocalImportOutcome(
        key: candidate.key,
        kind: candidate.kind,
        ok: false,
        message:
            '资源总量 ${(plan.bytes / 1024 / 1024).toStringAsFixed(1)} MiB '
            '超过上限 ${(maxDirectoryBytes / 1024 / 1024).toStringAsFixed(0)} MiB',
      );
    }
    if (plan.files.isEmpty) {
      return LocalImportOutcome(
        key: candidate.key,
        kind: candidate.kind,
        ok: false,
        message: '目录内没有可复制的文件',
      );
    }

    final targetDir = webHomeStore.directoryFor(candidate.key);
    return _writeNewDirectory(
      candidate: candidate,
      targetDir: targetDir,
      allowedRoot: webHomeStore.root,
      write: () async {
        for (final file in plan.files) {
          final relative = p.relative(file.path, from: sourceDir.path);
          final target = File(p.join(targetDir, relative));
          await target.parent.create(recursive: true);
          await file.copy(target.path);
        }

        final entryFile = File(p.join(targetDir, entryName));
        final entrySha256 = sha256
            .convert(await entryFile.readAsBytes())
            .toString();

        webHomeStore.upsert(
          WebHomeSource(
            key: candidate.key,
            name: candidate.name,
            entry: entryName,
            importedAt: DateTime.now().toIso8601String(),
            entrySha256: entrySha256,
            modifiedAt: candidate.modified.toIso8601String(),
          ),
        );

        return LocalImportOutcome(
          key: candidate.key,
          kind: candidate.kind,
          ok: true,
          targetDir: targetDir,
          message: 'HTML 首页已导入（${plan.files.length} 个文件，入口 $entryName）',
        );
      },
    );
  }

  /// 选入口：优先 `index.html`，否则用户扫到的那个 `.html`。
  String? _pickWebHomeEntry(
    Directory sourceDir,
    LocalSourceCandidate candidate,
  ) {
    final index = File(p.join(sourceDir.path, 'index.html'));
    if (index.existsSync()) return 'index.html';
    final indexUpper = File(p.join(sourceDir.path, 'Index.html'));
    if (indexUpper.existsSync()) return 'Index.html';
    if (candidate.entryName.toLowerCase().endsWith('.htm') ||
        candidate.entryName.toLowerCase().endsWith('.html')) {
      return candidate.entryName;
    }
    return null;
  }

  /// 递归收集要复制的文件与总量（跳过隐藏目录与依赖目录）。
  Future<({List<File> files, int bytes})> _planCopy(Directory sourceDir) async {
    final files = <File>[];
    var bytes = 0;
    await for (final entity in sourceDir.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) continue;
      final relative = p.relative(entity.path, from: sourceDir.path);
      if (relative
          .split(p.separator)
          .any(
            (part) =>
                part.startsWith('.') ||
                LocalSpiderScanner.skipDirectoryNames.contains(part),
          )) {
        continue;
      }
      bytes += await entity.length();
      files.add(entity);
      if (bytes > maxDirectoryBytes) break;
    }
    return (files: files, bytes: bytes);
  }
}

/// Windows 目录句柄与卷/file-index 身份；不把可复制的路径标记当作身份。
class _WinDirectory {
  _WinDirectory(this.handle, this.identity);

  final int handle;
  final String identity;
  bool _closed = false;

  static final _kernel = ffi.DynamicLibrary.open('kernel32.dll');
  static final _create = _kernel
      .lookupFunction<
        ffi.IntPtr Function(
          ffi.Pointer<Utf16>,
          ffi.Uint32,
          ffi.Uint32,
          ffi.Pointer<ffi.Void>,
          ffi.Uint32,
          ffi.Uint32,
          ffi.IntPtr,
        ),
        int Function(
          ffi.Pointer<Utf16>,
          int,
          int,
          ffi.Pointer<ffi.Void>,
          int,
          int,
          int,
        )
      >('CreateFileW');
  static final _information = _kernel
      .lookupFunction<
        ffi.Int32 Function(ffi.IntPtr, ffi.Pointer<ffi.Uint32>),
        int Function(int, ffi.Pointer<ffi.Uint32>)
      >('GetFileInformationByHandle');
  static final _identityInformation = _kernel
      .lookupFunction<
        ffi.Int32 Function(
          ffi.IntPtr,
          ffi.Int32,
          ffi.Pointer<ffi.Void>,
          ffi.Uint32,
        ),
        int Function(int, int, ffi.Pointer<ffi.Void>, int)
      >('GetFileInformationByHandleEx');
  static final _close = _kernel
      .lookupFunction<ffi.Int32 Function(ffi.IntPtr), int Function(int)>(
        'CloseHandle',
      );
  static final _setInformation = _kernel
      .lookupFunction<
        ffi.Int32 Function(
          ffi.IntPtr,
          ffi.Int32,
          ffi.Pointer<ffi.Void>,
          ffi.Uint32,
        ),
        int Function(int, int, ffi.Pointer<ffi.Void>, int)
      >('SetFileInformationByHandle');
  static final _finalPath = _kernel
      .lookupFunction<
        ffi.Uint32 Function(
          ffi.IntPtr,
          ffi.Pointer<Utf16>,
          ffi.Uint32,
          ffi.Uint32,
        ),
        int Function(int, ffi.Pointer<Utf16>, int, int)
      >('GetFinalPathNameByHandleW');
  static final _error = _kernel
      .lookupFunction<ffi.Uint32 Function(), int Function()>('GetLastError');

  static _WinDirectory open(
    String path, {
    bool lock = false,
    bool deleting = false,
  }) {
    if (!Platform.isWindows) {
      throw UnsupportedError('当前平台没有可靠的目录身份回滚实现');
    }
    final name = p.absolute(path).toNativeUtf16(allocator: calloc);
    final info = calloc<ffi.Uint32>(
      13,
    ); // BY_HANDLE_FILE_INFORMATION: 13 DWORD。
    final id = calloc<ffi.Uint8>(24); // FILE_ID_INFO: uint64卷号 + 128-bit ID。
    var handle = -1;
    try {
      // OPEN_EXISTING、BACKUP_SEMANTICS、OPEN_REPARSE_POINT；不跟随目录链接。
      handle = _create(
        name,
        deleting ? 0x10080 : 0,
        lock ? 3 : 7,
        ffi.nullptr,
        3,
        0x02200000,
        0,
      );
      if (handle == -1 || handle == 0) {
        throw FileSystemException('打开目录句柄失败 win32=${_error()}', path);
      }
      if (_information(handle, info) == 0) {
        throw FileSystemException('读取目录身份失败 win32=${_error()}', path);
      }
      if ((info[0] & 0x10) == 0 || (info[0] & 0x400) != 0) {
        throw FileSystemException('不能确认普通目录身份', path);
      }
      if (_identityInformation(handle, 18, id.cast(), 24) == 0 ||
          id.asTypedList(24).skip(8).every((byte) => byte == 0)) {
        throw FileSystemException('读取128-bit目录身份失败 win32=${_error()}', path);
      }
      return _WinDirectory(handle, id.asTypedList(24).join(','));
    } catch (_) {
      if (handle != -1 && handle != 0) _close(handle);
      rethrow;
    } finally {
      calloc.free(name);
      calloc.free(info);
      calloc.free(id);
    }
  }

  bool sameIdentity(_WinDirectory other) => identity == other.identity;

  String currentPath() {
    final capacity = _finalPath(handle, ffi.nullptr, 0, 0) + 1;
    if (capacity <= 1) return '句柄路径不可读(file-id=$identity)';
    final buffer = calloc<ffi.Uint16>(capacity).cast<Utf16>();
    try {
      final written = _finalPath(handle, buffer, capacity, 0);
      if (written == 0 || written >= capacity) {
        return '句柄路径不可读(file-id=$identity)';
      }
      return buffer.toDartString();
    } finally {
      calloc.free(buffer);
    }
  }

  void deleteOnClose() {
    final flag = calloc<ffi.Uint8>()..value = 1;
    try {
      // FileDispositionInfo=4，FILE_DISPOSITION_INFO 的 BOOLEAN 大小为1。
      if (_setInformation(handle, 4, flag.cast(), 1) == 0) {
        throw FileSystemException('目录句柄删除失败 win32=${_error()}');
      }
    } finally {
      calloc.free(flag);
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _close(handle);
  }
}
