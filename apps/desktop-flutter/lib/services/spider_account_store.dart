/// 应用级手动网盘账号存储：严格 UTF-8 JSON + 原子替换。
///
/// 文件契约（与 JVM 普通 JSON 读取一致，不是 properties 格式）：
/// {"version":1,"values":{"Wex_quark_cookie":"...","Wex_baidu_cookie":"..."}}
///
/// - 文件或键缺失：返回 null（站源继续回落到站内旧值，不写文件）；
/// - 空字符串：显式全局清理的墓碑，覆盖旧的站内值；
/// - 单值 <= 32 KiB，整份文档 <= 128 KiB，只允许两个已知偏好键；
/// - 写入串行化（同进程队列 + 文件锁）并经同目录 staging 文件原子替换；
/// - 错误只带固定说明，绝不包含 Cookie 值或解析器片段。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../core/spider_account.dart';

/// 账号文件不可用（格式/边界/IO）。消息不含任何账号值。
class SpiderAccountStoreException implements Exception {
  const SpiderAccountStoreException(this.message);

  final String message;

  @override
  String toString() => 'SpiderAccountStoreException: $message';
}

/// 两个已知 provider 共用的应用级账号文件。
class SpiderAccountStore {
  SpiderAccountStore({required String path})
    : _path = p.normalize(p.absolute(path));

  /// 整份文档上限：128 KiB。
  static const int maxDocumentBytes = 128 * 1024;

  /// 单个 Cookie 值上限：32 KiB。
  static const int maxValueBytes = 32 * 1024;

  // 锁文件与账号文件同目录且有意保留（进程间互斥需要稳定 inode）。
  static const String _lockSuffix = '.lock';
  static const String _partSuffix = '.part';

  static final Map<String, Future<void>> _writeTails = {};

  final String _path;

  String get path => _path;

  /// 读取全局值；文件/键缺失返回 null，显式清理返回空字符串。
  Future<String?> read(SpiderAccountProvider provider) async {
    final values = await _readDocument();
    return values?[provider.preferenceKey];
  }

  /// 保存一个已规范化的值；空内容只能走 [clear]。
  Future<void> save(SpiderAccountProvider provider, String value) async {
    final normalized = _normalizeValue(value);
    await _mutate((values) {
      values[provider.preferenceKey] = normalized;
    });
  }

  /// 显式全局清理：写空字符串墓碑（不是删除键/文件）。
  Future<void> clear(SpiderAccountProvider provider) async {
    await _mutate((values) {
      values[provider.preferenceKey] = '';
    });
  }

  Future<void> _mutate(void Function(Map<String, String> values) apply) {
    return _serialize(
      () => _withFileLock(() async {
        final values = await _readDocument() ?? <String, String>{};
        apply(values);
        await _writeDocument(values);
      }),
    );
  }

  /// 同一路径的写入排队，避免同进程内两个实例互相等锁。
  Future<void> _serialize(Future<void> Function() body) {
    final previous = _writeTails[_path] ?? Future<void>.value();
    final next = previous.then((_) => body());
    _writeTails[_path] = next.then((_) {}, onError: (Object _) {});
    return next;
  }

  /// JVM 侧可能同时读取：先文件锁（跨进程），再读-改-写。
  Future<void> _withFileLock(Future<void> Function() body) async {
    final lockFile = File('$_path$_lockSuffix');
    await Directory(p.dirname(_path)).create(recursive: true);
    final handle = await lockFile.open(mode: FileMode.append);
    try {
      await handle.lock(FileLock.exclusive);
      try {
        await body();
      } finally {
        await handle.unlock();
      }
    } finally {
      await handle.close();
    }
  }

  Future<Map<String, String>?> _readDocument() async {
    final file = File(_path);
    final List<int> bytes;
    try {
      if (!await file.exists()) return null;
      bytes = await _readBytes(file);
    } on FileSystemException {
      throw const SpiderAccountStoreException('读取账号文件失败');
    }
    final String text;
    try {
      text = utf8.decode(bytes);
    } catch (_) {
      throw const SpiderAccountStoreException('账号文件不是合法 UTF-8 文本');
    }

    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      throw const SpiderAccountStoreException('账号文件不是合法 JSON');
    }
    if (decoded is! Map) {
      throw const SpiderAccountStoreException('账号文件结构不符');
    }
    if (decoded.keys.any((key) => key != 'version' && key != 'values')) {
      throw const SpiderAccountStoreException('账号文件结构不符');
    }
    final version = decoded['version'];
    if (version is! int || version != 1) {
      throw const SpiderAccountStoreException('账号文件版本不受支持');
    }
    final rawValues = decoded['values'];
    if (rawValues is! Map) {
      throw const SpiderAccountStoreException('账号文件结构不符');
    }

    final values = <String, String>{};
    for (final entry in rawValues.entries) {
      final key = entry.key;
      if (key is! String || !_knownKeys.contains(key)) {
        throw const SpiderAccountStoreException('账号文件包含未知偏好键');
      }
      final value = entry.value;
      if (value is! String || utf8.encode(value).length > maxValueBytes) {
        throw const SpiderAccountStoreException('账号值类型或大小不符');
      }
      values[key] = value;
    }
    return values;
  }

  /// rename 期间 JVM 可能正在读同一文件（Windows 共享冲突），短重试即可。
  ///
  /// 先 stat 再按块读取：上限必须在分配之前生效，不能把任意大的文件整个读进内存
  /// 再判断。stat 之后文件仍可能变大（TOCTOU），所以流式读取过程中一旦超过上限
  /// 也立即中止。
  Future<List<int>> _readBytes(File file) async {
    FileSystemException? last;
    for (var attempt = 0; attempt < 5; attempt++) {
      try {
        if (await file.length() > maxDocumentBytes) {
          throw const SpiderAccountStoreException('账号文件超过大小上限');
        }
        final builder = BytesBuilder(copy: false);
        final handle = await file.open();
        try {
          while (true) {
            final chunk = await handle.read(64 * 1024);
            if (chunk.isEmpty) break;
            builder.add(chunk);
            if (builder.length > maxDocumentBytes) {
              throw const SpiderAccountStoreException('账号文件超过大小上限');
            }
          }
        } finally {
          await handle.close();
        }
        return builder.takeBytes();
      } on FileSystemException catch (error) {
        last = error;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }
    throw last!;
  }

  Future<void> _writeDocument(Map<String, String> values) {
    final ordered = <String, String>{};
    for (final key in _knownKeys) {
      final value = values[key];
      if (value != null) ordered[key] = value;
    }
    final bytes = utf8.encode(
      jsonEncode(<String, Object?>{'version': 1, 'values': ordered}),
    );
    if (bytes.length > maxDocumentBytes) {
      throw const SpiderAccountStoreException('账号文件超过大小上限');
    }
    return _atomicReplace(bytes);
  }

  Future<void> _atomicReplace(List<int> bytes) async {
    _partCounter++;
    final dir = p.dirname(_path);
    final part = File(p.join(dir, '.accounts.json.$pid-$_partCounter$_partSuffix'));
    try {
      await part.writeAsBytes(bytes, flush: true);
      FileSystemException? last;
      for (var attempt = 0; attempt < 10; attempt++) {
        try {
          await part.rename(_path);
          return;
        } on FileSystemException catch (error) {
          last = error;
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      }
      throw last!;
    } on FileSystemException {
      throw const SpiderAccountStoreException('写入账号文件失败');
    } finally {
      try {
        if (await part.exists()) await part.delete();
      } catch (_) {}
    }
  }

  static int _partCounter = 0;

  static const List<String> _knownKeys = [
    'Wex_quark_cookie',
    'Wex_baidu_cookie',
  ];

  static String _normalizeValue(String raw) {
    var value = raw.trim();
    if (value.isEmpty) {
      throw const SpiderAccountStoreException('账号内容为空，请使用清除操作');
    }
    if (value.contains('\r') || value.contains('\n')) {
      throw const SpiderAccountStoreException('账号内容不能包含换行');
    }
    const prefix = 'cookie:';
    if (value.toLowerCase().startsWith(prefix)) {
      value = value.substring(prefix.length).trim();
      if (value.isEmpty) {
        throw const SpiderAccountStoreException('账号内容为空，请使用清除操作');
      }
    }
    if (utf8.encode(value).length > maxValueBytes) {
      throw const SpiderAccountStoreException('账号内容超过大小上限');
    }
    return value;
  }
}
