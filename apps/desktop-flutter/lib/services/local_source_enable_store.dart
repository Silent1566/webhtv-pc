/// 本地 Spider 的启用覆盖；不改写用户 manifest，缺席的 key 默认启用。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'log_service.dart';

class LocalSourceEnableStore {
  // ignore: prefer_initializing_formals
  LocalSourceEnableStore({required this.path, LogService? log}) : _log = log;

  final String path;
  final LogService? _log;
  Set<String>? _disabled;
  String? _loadError;

  String? get loadError => _loadError;
  Set<String> get disabledKeys => Set<String>.unmodifiable(_load());
  bool isEnabled(String key) => !_load().contains(key.trim());

  void reload() {
    _disabled = null;
    _load();
  }

  bool setEnabled(String key, bool enabled) =>
      key.trim().isNotEmpty && setEnabledAll([key], enabled);

  bool setEnabledAll(Iterable<String> keys, bool enabled) {
    final current = _load();
    if (_loadError != null) return false;
    final next = Set<String>.of(current);
    for (final key
        in keys.map((key) => key.trim()).where((key) => key.isNotEmpty)) {
      if (enabled) {
        next.remove(key);
      } else {
        next.add(key);
      }
    }
    if (next.length == current.length && next.containsAll(current)) return true;
    return _write(next);
  }

  /// 同 key 重新导入不应继承已删除源的停用状态。
  bool forget(String key) => key.trim().isEmpty || setEnabled(key, true);

  Set<String> _load() {
    final cached = _disabled;
    if (cached != null) return cached;
    try {
      final type = FileSystemEntity.typeSync(path, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        _loadError = null;
        return _disabled = <String>{};
      }
      if (type != FileSystemEntityType.file) {
        throw FileSystemException('本地源启用状态不是普通文件', path);
      }
      final decoded = jsonDecode(File(path).readAsStringSync());
      final raw = decoded is Map ? decoded['disabled'] : decoded;
      if (raw is! List || raw.any((item) => item is! String)) {
        throw const FormatException('disabled 必须是字符串列表');
      }
      _loadError = null;
      return _disabled = {
        for (final item in raw.cast<String>())
          if (item.trim().isNotEmpty) item.trim(),
      };
    } on FormatException catch (error) {
      _loadError = '本地源启用状态不是合法 JSON 或列表：$error';
    } on FileSystemException catch (error) {
      _loadError = '读取本地源启用状态失败：$error';
    }
    _log?.error(_loadError!, scope: 'spider');
    return _disabled = <String>{};
  }

  bool _write(Set<String> disabled) {
    Directory? temporary;
    try {
      final type = FileSystemEntity.typeSync(path, followLinks: false);
      if (type != FileSystemEntityType.notFound &&
          type != FileSystemEntityType.file) {
        throw FileSystemException('启用状态路径不是普通文件', path);
      }
      final directory = Directory(p.dirname(path))..createSync(recursive: true);
      temporary = directory.createTempSync('.local-sources-');
      final file = File(p.join(temporary.path, 'state.json'));
      final sorted = disabled.toList()..sort();
      file.writeAsStringSync(
        const JsonEncoder.withIndent('  ')
            .convert({'version': 1, 'disabled': sorted}),
        flush: true,
      );
      file.renameSync(path);
      _disabled = disabled;
      _loadError = null;
      return true;
    } on FileSystemException catch (error) {
      _loadError = '保存本地源启用状态失败：$error';
      _log?.error(_loadError!, scope: 'spider');
      return false;
    } finally {
      if (temporary != null) {
        try {
          temporary.deleteSync(recursive: true);
        } on FileSystemException catch (error) {
          _log?.warning('清理启用状态临时文件失败：$error', scope: 'spider');
        }
      }
    }
  }
}
