/// 内容智能域的落盘位置：用户数据与缓存**分目录**存放。
///
/// - 用户数据（负反馈 / 分组规则 / 去广规则 / 片名学习）落在 `dataDir`，
///   随备份一起迁移，不允许当作可丢缓存；
/// - 可重建的缓存（推荐列表 / 画像）落在 `cacheDir`，删除后自动重算。
///
/// 每个域一个专属文件，绝不写共享 `settings.json`（避免与其他消费者互相覆盖）。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import '../app_paths.dart';

class AiContentPaths {
  AiContentPaths({required this.dataDir, required this.cacheDir});

  factory AiContentPaths.of(AppPaths paths) => AiContentPaths(
    dataDir: p.join(paths.dataDir, 'ai_content'),
    cacheDir: p.join(paths.cacheDir, 'ai_content'),
  );

  /// 用户数据目录（可备份）。
  final String dataDir;

  /// 缓存目录（可重建）。
  final String cacheDir;

  String get feedbackPath =>
      p.join(dataDir, 'recommendation_feedback.json');

  String get learningPath => p.join(dataDir, 'title_learning.json');

  String get groupRulesPath => p.join(dataDir, 'group_rules.json');

  String get adRulesPath => p.join(dataDir, 'ad_rules.json');

  /// 导出快照：**导出产物**，不是用户数据的一份额外来源。
  /// 它由四个域重新导出即可获得，因此不进入 [existingUserDataFiles]。
  String get exportPath => p.join(dataDir, 'ai_content_export.json');

  String profileCachePath(String rangeId) =>
      p.join(cacheDir, 'profile_${_safe(rangeId)}.json');

  String recommendationCachePath(String key) =>
      p.join(cacheDir, 'rec_${_safe(key)}.json');

  /// 用户数据文件清单（只列出真实存在的域文件，用于备份枚举）。
  Future<List<String>> existingUserDataFiles() async => _existing([
    feedbackPath,
    learningPath,
    groupRulesPath,
    adRulesPath,
  ]);

  /// 推荐缓存文件清单（只含 `rec_*.json`，用于容量裁剪）。
  Future<List<String>> existingRecommendationCacheFiles() =>
      _cacheFilesWithPrefix('rec_');

  Future<List<String>> _cacheFilesWithPrefix(String prefix) async {
    final directory = Directory(cacheDir);
    if (!await directory.exists()) return const [];
    final files = <String>[];
    await for (final entity in directory.list()) {
      if (entity is! File) continue;
      if (!p.basename(entity.path).startsWith(prefix)) continue;
      files.add(entity.path);
    }
    files.sort();
    return files;
  }

  Future<List<String>> _existing(List<String> candidates) async {
    final result = <String>[];
    for (final path in candidates) {
      if (await File(path).exists()) result.add(path);
    }
    return result;
  }

  static String _safe(String value) =>
      value.replaceAll(RegExp(r'[^A-Za-z0-9_\-]'), '_');
}
