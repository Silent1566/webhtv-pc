/// `probe-cache` 的限额回收：这里只有**可重建**的共享缓存。
///
/// 边界（都是刻意写死的）：
/// - 只走 `probe-cache`，绝不碰 `<spiderRoot>/csp`、`<spiderRoot>/direct` 的已安装站点，
///   也不碰 `spiders/local` 的用户源；
/// - 版本目录按 `DexTranslate.repairVersion` 判定「旧口径」，口径常量不从本文件复制；
/// - 任何一次删除失败都只跳过并计数，绝不向上抛——回收是后台维护，不是用户操作的结果。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'dex_translate.dart';
import 'log_service.dart';

/// 一次回收的结果，只用于日志与测试断言。
class SpiderCachePruneResult {
  const SpiderCachePruneResult({
    this.deletedEntries = 0,
    this.deletedBytes = 0,
    this.keptBytes = 0,
    this.skippedActive = 0,
    this.skippedErrors = 0,
  });

  /// 被删掉的条目数（一个条目可能是一个目录，内含多个文件）。
  final int deletedEntries;

  /// 被删掉/保留下来的字节数。
  final int deletedBytes;
  final int keptBytes;

  /// 因为落在活动窗口内被跳过的条目数。
  final int skippedActive;

  /// 删除失败被跳过的条目数（被占用、权限、路径竞争）。
  final int skippedErrors;

  bool get changed => deletedEntries > 0;

  @override
  String toString() =>
      'shared-cache 回收：删除 $deletedEntries 项 / $deletedBytes 字节，'
      '保留 $keptBytes 字节，活动跳过 $skippedActive，失败跳过 $skippedErrors';
}

/// 按预算 + 闲置时长回收 `probe-cache`。
class SpiderCacheRetention {
  const SpiderCacheRetention._();

  /// 默认预算 512 MiB（用户选定）。
  static const int defaultBudgetBytes = 512 * 1024 * 1024;

  /// 活动窗口：这段时间内被读写过的条目一律不动，避免和正在进行的探测/转译抢文件。
  static const Duration defaultActiveWindow = Duration(minutes: 10);

  /// 旧口径产物闲置多久可以回收。
  static const Duration defaultStaleGenerationAge = Duration(days: 30);

  /// 单次遍历的文件上限：缓存目录异常膨胀时也不能把主线程拖住。
  static const int maxScannedFiles = 20000;

  static SpiderCachePruneResult prune(
    String probeCacheDir, {
    int budgetBytes = defaultBudgetBytes,
    Duration activeWindow = defaultActiveWindow,
    Duration staleGenerationAge = defaultStaleGenerationAge,
    DateTime Function()? now,
    LogService? log,
  }) {
    final clock = (now ?? DateTime.now)();
    try {
      final base = Directory(probeCacheDir);
      if (!base.existsSync()) return const SpiderCachePruneResult();
      var scanned = 0;
      final units = <_CacheUnit>[];
      _collect(base, units, () => ++scanned > maxScannedFiles);

      var deletedEntries = 0;
      var deletedBytes = 0;
      var keptBytes = 0;
      var skippedActive = 0;
      var skippedErrors = 0;

      bool isActive(_CacheUnit unit) =>
          clock.difference(unit.modifiedAt) < activeWindow;

      final remaining = <_CacheUnit>[];
      for (final unit in units) {
        final staleGeneration =
            unit.generation != null &&
            unit.generation != DexTranslate.repairVersion &&
            clock.difference(unit.modifiedAt) >= staleGenerationAge;
        if (!staleGeneration) {
          remaining.add(unit);
          continue;
        }
        if (isActive(unit)) {
          remaining.add(unit);
          skippedActive++;
          continue;
        }
        if (_delete(unit)) {
          deletedEntries++;
          deletedBytes += unit.sizeBytes;
        } else {
          remaining.add(unit);
          skippedErrors++;
        }
      }

      remaining.sort((a, b) => a.modifiedAt.compareTo(b.modifiedAt));
      var total = remaining.fold<int>(0, (sum, unit) => sum + unit.sizeBytes);
      for (var index = 0; index < remaining.length; index++) {
        if (total <= budgetBytes) break;
        final unit = remaining[index];
        if (isActive(unit)) {
          skippedActive++;
          continue;
        }
        if (_delete(unit)) {
          deletedEntries++;
          deletedBytes += unit.sizeBytes;
          total -= unit.sizeBytes;
        } else {
          skippedErrors++;
        }
      }

      keptBytes = total.clamp(0, 1 << 62).toInt();
      _dropEmptyGenerationParents(base);

      final result = SpiderCachePruneResult(
        deletedEntries: deletedEntries,
        deletedBytes: deletedBytes,
        keptBytes: keptBytes,
        skippedActive: skippedActive,
        skippedErrors: skippedErrors,
      );
      if (result.changed) log?.info('$result', scope: 'spider');
      return result;
    } catch (error) {
      log?.warning('shared-cache 回收跳过：$error', scope: 'spider');
      return const SpiderCachePruneResult();
    }
  }

  /// 枚举条目：`dex/<sha>/v<N>/` 每个生成目录算一个条目，其余目录整体算一个条目。
  static void _collect(
    Directory base,
    List<_CacheUnit> units,
    bool Function() limitReached,
  ) {
    for (final child in base.listSync(followLinks: false)) {
      if (limitReached()) return;
      final name = p.basename(child.path);
      if (child is! Directory) {
        units.add(_CacheUnit.ofEntity(child, generation: null));
        continue;
      }
      if (!_structuralDirs.contains(name)) {
        units.add(_CacheUnit.ofEntity(child, generation: null));
        continue;
      }
      if (name != 'dex') {
        for (final entry in child.listSync(followLinks: false)) {
          if (limitReached()) return;
          units.add(_CacheUnit.ofEntity(entry, generation: null));
        }
        continue;
      }
      for (final entry in child.listSync(followLinks: false)) {
        if (limitReached()) return;
        if (entry is! Directory) {
          units.add(_CacheUnit.ofEntity(entry, generation: null));
          continue;
        }
        var hasGeneration = false;
        for (final inner in entry.listSync(followLinks: false)) {
          if (limitReached()) return;
          final generation = _generationOf(p.basename(inner.path));
          if (generation != null && inner is Directory) {
            hasGeneration = true;
            units.add(_CacheUnit.ofEntity(inner, generation: generation));
          } else {
            units.add(_CacheUnit.ofEntity(inner, generation: null));
          }
        }
        if (!hasGeneration) continue;
      }
    }
  }

  /// 内部按「一层子项 = 一个条目」处理的容器目录。其余目录整体算一个条目。
  static const Set<String> _structuralDirs = <String>{'dex', 'shell', 'jar'};

  /// `v<N>` → N；不是这个形状返回 null。
  static int? _generationOf(String name) {
    if (!name.startsWith('v') || name.length < 2) return null;
    return int.tryParse(name.substring(1));
  }

  /// 删掉空的 `<sha>/` 目录：只在 `dex` 下、且确实为空时才删。
  static void _dropEmptyGenerationParents(Directory base) {
    try {
      final dexDir = Directory(p.join(base.path, 'dex'));
      if (!dexDir.existsSync()) return;
      for (final entry in dexDir.listSync(followLinks: false)) {
        if (entry is! Directory) continue;
        try {
          if (entry.listSync(followLinks: false).isEmpty) entry.deleteSync();
        } catch (_) {}
      }
    } catch (_) {}
  }

  static bool _delete(_CacheUnit unit) {
    try {
      final entity = unit.isDirectory
          ? Directory(unit.path)
          : File(unit.path);
      if (!entity.existsSync()) return true;
      entity.deleteSync(recursive: unit.isDirectory);
      return true;
    } catch (_) {
      return false;
    }
  }
}

/// 一个可回收条目：目录整体，或 `dex/<sha>/v<N>/` 这样的单个生成目录。
class _CacheUnit {
  _CacheUnit._({
    required this.path,
    required this.isDirectory,
    required this.generation,
    required this.sizeBytes,
    required this.modifiedAt,
  });

  final String path;
  final bool isDirectory;
  final int? generation;
  final int sizeBytes;
  final DateTime modifiedAt;

  factory _CacheUnit.ofEntity(FileSystemEntity entity, {int? generation}) {
    var size = 0;
    var modified = _mtimeOf(entity);
    if (entity is Directory) {
      // 目录自身的 mtime 在 Windows 上等于「创建/子项变更」时间，拿它当 LRU 会把刚建的
      // 目录一直判成「正在使用」。这里只用内部文件的最新 mtime，空目录才退回归属目录。
      var byContent = false;
      for (final inner in entity.listSync(recursive: true, followLinks: false)) {
        if (inner is! File) continue;
        try {
          size += inner.lengthSync();
        } catch (_) {}
        final innerMtime = _mtimeOf(inner);
        if (!byContent || innerMtime.isAfter(modified)) modified = innerMtime;
        byContent = true;
      }
    } else if (entity is File) {
      try {
        size = entity.lengthSync();
      } catch (_) {}
    }
    return _CacheUnit._(
      path: entity.path,
      isDirectory: entity is Directory,
      generation: generation,
      sizeBytes: size,
      modifiedAt: modified,
    );
  }

  static DateTime _mtimeOf(FileSystemEntity entity) {
    try {
      return entity.statSync().modified;
    } catch (_) {
      return DateTime.fromMillisecondsSinceEpoch(0);
    }
  }
}
