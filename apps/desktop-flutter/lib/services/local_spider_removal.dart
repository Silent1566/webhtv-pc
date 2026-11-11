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
      if (!p.equals(Directory(path).resolveSymbolicLinksSync(), path)) {
        return false;
      }
    }
    void lockTree(String path, {required bool directory}) {
      entries.add(
        _LockedEntry.open(path, directory: directory, deleting: true),
      );
      if (!p.isWithin(
        local,
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
