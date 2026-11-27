/// 去广告统计的落盘（安卓 `AdBlockStatsStore` 的 PC 化）。
///
/// 风格对齐 `local_source_enable_store.dart`：临时目录内写整份文件，再 rename 到
/// 目标路径——目标文件要么是旧的完整内容、要么是新的完整内容，不会出现半份 JSON；
/// 带 `version` 字段；读失败只记 warning 并降级为空统计，绝不抛给调用方。
///
/// 一个域一个文件：路径由构造参数传入，不写共享 settings.json。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/ad_block_stats.dart';
import 'log_service.dart';

class AdBlockStatsStore {
  // ignore: prefer_initializing_formals
  AdBlockStatsStore({required this.path, LogService? log}) : _log = log;

  /// 文件格式版本。
  ///
  /// 2 起把终身命中时长写进 `stats.blockedDurationSeconds`；读 1 号文件时按当时
  /// 还留着的明细求和迁移（字段名容错，缺字段不会让整份文件作废）。
  static const int version = 2;

  final String path;
  final LogService? _log;
  AdBlockStats? _stats;
  String? _loadError;

  /// 当前统计（首次访问时才读盘；读失败返回空统计）。
  AdBlockStats get stats => _stats ??= _load();

  /// 最近一次读/写失败的原因；成功读写后清空。
  String? get loadError => _loadError;

  /// 丢掉内存视图并重新读盘（页面打开、或怀疑被别的实例写过时用）。
  void reload() {
    _stats = null;
    _load();
  }

  /// 追加一批日志并落盘。
  ///
  /// **写成功才提交内存**：先在副本上记账、写盘、再换掉内存视图。反过来做的话，
  /// 写失败时页面显示的数字已经变了，「清空」甚至会先把界面清零、再由下一次
  /// 成功的写入把清零落到磁盘——用户丢掉的是自己从没要求删掉的历史。
  bool record(List<AdBlockLog> logs) {
    if (logs.isEmpty) return true;
    final next = stats.copy()..addAll(logs);
    if (!_write(next)) return false;
    _stats = next;
    return true;
  }

  /// 清空统计并落盘（`lastResetAt` 由 [AdBlockStats.reset] 刷新）。
  ///
  /// 同样写成功才提交：写失败时连同 `lastResetAt` 一起回滚。
  bool reset() {
    final next = stats.copy()..reset();
    if (!_write(next)) return false;
    _stats = next;
    return true;
  }

  AdBlockStats _load() {
    try {
      final type = FileSystemEntity.typeSync(path, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        _loadError = null;
        return AdBlockStats.empty();
      }
      if (type != FileSystemEntityType.file) {
        throw FileSystemException('去广告统计路径不是普通文件', path);
      }
      final decoded = jsonDecode(File(path).readAsStringSync());
      _loadError = null;
      // 没有 `stats` 包的旧文件/手写文件，整份当统计读（字段容错在模型里）。
      return AdBlockStats.fromJson(
        decoded is Map ? decoded['stats'] ?? decoded : decoded,
      );
    } on FormatException catch (error) {
      _loadError = '去广告统计不是合法 JSON：$error';
    } on FileSystemException catch (error) {
      _loadError = '读取去广告统计失败：$error';
    }
    _log?.warning(_loadError!, scope: 'ad-block');
    return AdBlockStats.empty();
  }

  bool _write(AdBlockStats stats) {
    Directory? temporary;
    try {
      final type = FileSystemEntity.typeSync(path, followLinks: false);
      if (type != FileSystemEntityType.notFound &&
          type != FileSystemEntityType.file) {
        throw FileSystemException('去广告统计路径不是普通文件', path);
      }
      final directory = Directory(p.dirname(path))..createSync(recursive: true);
      temporary = directory.createTempSync('.ad-block-stats-');
      final file = File(p.join(temporary.path, 'stats.json'));
      file.writeAsStringSync(
        const JsonEncoder.withIndent('  ')
            .convert({'version': version, 'stats': stats.toJson()}),
        flush: true,
      );
      file.renameSync(path);
      _loadError = null;
      return true;
    } on FileSystemException catch (error) {
      _loadError = '保存去广告统计失败：$error';
      _log?.warning(_loadError!, scope: 'ad-block');
      return false;
    } on Object catch (error) {
      // 编码失败（NaN/Infinity、异常对象）同样收敛成「保存失败」：调用方是代理的
      // 清洗路径，它没有能力处理异常，抛出去就等于广告过滤整条链路断掉。
      _loadError = '保存去广告统计失败：$error';
      _log?.warning(_loadError!, scope: 'ad-block');
      return false;
    } finally {
      if (temporary != null) {
        try {
          temporary.deleteSync(recursive: true);
        } on FileSystemException catch (error) {
          _log?.warning('清理去广告统计临时文件失败：$error', scope: 'ad-block');
        }
      }
    }
  }
}
