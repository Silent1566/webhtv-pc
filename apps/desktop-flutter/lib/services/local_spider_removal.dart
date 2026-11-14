import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

/// Windows-only：锁住根、local 和整棵源树后按句柄删除，拒绝链接/替换竞态。
bool removeLocalSpiderDirectory({required String root, required String key}) {
  if (!Platform.isWindows) return false;
  final normalizedRoot = p.normalize(p.absolute(root));
  final local = p.join(normalizedRoot, 'local');
  final target = p.join(local, key);
  if (!p.isWithin(local, target) || p.dirname(target) != local) return false;
  final parents = <_LockedEntry>[];
  final entries = <_LockedEntry>[];
  try {
    for (final path in [normalizedRoot, local]) {
      parents.add(_LockedEntry.open(path, directory: true, deleting: false));
    }
    // 系统解析回来的一律是**长名**路径，而调用方传入的可能是 8.3 短名
    // （Windows CI 的临时目录就是 `C:\Users\RUNNER~1\...`）。拿规范路径和
    // 传入字符串比相等，会把「自身没有重定向」的普通目录误判成越界，于是
    // 删除被静默拒绝（用户视角：点了删除，目录还在）。两边都规范到同一口径
    // 再比较，语义不变——仍然拒绝 junction/符号链接（那是 local 解析后与
    // 「根规范路径/local」不一致的唯一情形）。
    final canonicalRoot = _canonical(normalizedRoot);
    if (!p.equals(canonicalRoot, _unredirectedCanonical(normalizedRoot))) {
      return false;
    }
    final canonicalLocal = _canonical(local);
    if (!p.equals(canonicalLocal, p.join(canonicalRoot, 'local'))) return false;
    void lockTree(String path, {required bool directory}) {
      entries.add(
        _LockedEntry.open(path, directory: directory, deleting: true),
      );
      if (!p.isWithin(
        canonicalLocal,
        FileSystemEntity.isDirectorySync(path)
            ? Directory(path).resolveSymbolicLinksSync()
            : File(path).resolveSymbolicLinksSync(),
      )) {
        throw FileSystemException('资源越出本地源目录', path);
      }
      if (directory) {
        for (final child in Directory(path).listSync(followLinks: false)) {
          if (child is Link) {
            throw FileSystemException('本地源含链接，拒绝删除', child.path);
          }
          lockTree(child.path, directory: child is Directory);
        }
      }
    }

    lockTree(target, directory: true);
    // 全树已确认并锁定之后才删除；不按可替换的路径递归删除。
    for (final entry in entries.reversed) {
      entry.deleteOnClose();
      entry.close();
    }
    return FileSystemEntity.typeSync(target, followLinks: false) ==
        FileSystemEntityType.notFound;
  } finally {
    for (final entry in entries.reversed) {
      entry.close();
    }
    for (final entry in parents.reversed) {
      entry.close();
    }
  }
}

/// 系统口径的规范路径（长名、大小写按磁盘记录）。
String _canonical(String path) => Directory(path).resolveSymbolicLinksSync();

/// `path` **自身不是重定向**时应得的规范路径。
///
/// 用「父目录的规范路径 + 自身字面名」表示，父目录可以是 8.3 短名也能对上；
/// 一旦 `path` 本身被解析成别处（junction/符号链接），结果就与
/// [_canonical] 不一致。
String _unredirectedCanonical(String path) {
  final parent = p.dirname(path);
  if (p.equals(parent, path)) return _canonical(path);
  return p.join(_canonical(parent), p.basename(path));
}

class _LockedEntry {
  _LockedEntry(this.handle);
  final int handle;
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
  static final _close = _kernel
      .lookupFunction<ffi.Int32 Function(ffi.IntPtr), int Function(int)>(
        'CloseHandle',
      );
  static final _error = _kernel
      .lookupFunction<ffi.Uint32 Function(), int Function()>('GetLastError');

  static _LockedEntry open(
    String path, {
    required bool directory,
    required bool deleting,
  }) {
    final name = path.toNativeUtf16(allocator: calloc);
    final info = calloc<ffi.Uint32>(13);
    var handle = -1;
    try {
      // 不共享 DELETE，阻止锁持有期间的目录重命名/替换；不跟随 reparse point。
      handle = _create(
        name,
        deleting ? 0x10080 : 0x80,
        3,
        ffi.nullptr,
        3,
        0x02200000,
        0,
      );
      if (handle == -1 || handle == 0 || _information(handle, info) == 0) {
        throw FileSystemException('锁定本地源失败 win32=${_error()}', path);
      }
      if ((info[0] & 0x400) != 0 || ((info[0] & 0x10) != 0) != directory) {
        throw FileSystemException('不是预期普通文件/目录，拒绝删除', path);
      }
      if (deleting && !directory && (info[0] & 1) != 0) {
        throw FileSystemException('本地源含只读文件，删除前请解除只读属性', path);
      }
      return _LockedEntry(handle);
    } catch (_) {
      if (handle != -1 && handle != 0) _close(handle);
      rethrow;
    } finally {
      calloc.free(name);
      calloc.free(info);
    }
  }

  void deleteOnClose() {
    final flag = calloc<ffi.Uint8>()..value = 1;
    try {
      if (_setInformation(handle, 4, flag.cast(), 1) == 0) {
        throw FileSystemException('本地源句柄删除失败 win32=${_error()}');
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
