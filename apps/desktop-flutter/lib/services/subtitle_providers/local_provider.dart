/// 本地目录字幕源：扫用户配置的目录，按文件名与标题的归一化包含关系匹配。
library;

import 'dart:io';

import '../../core/subtitle_provider.dart';
import '../../core/subtitle_settings.dart';
import 'provider.dart';

class LocalSubtitleProvider extends SubtitleProvider {
  const LocalSubtitleProvider({this.maxFiles = 500});

  @override
  String get id => 'local';

  @override
  String get name => '本地目录';

  @override
  int get priority => 50;

  /// 单次扫描的文件上限（防止用户把整个磁盘加进来）。
  final int maxFiles;

  static const Set<String> _extensions = {'srt', 'ass', 'ssa', 'vtt', 'sub'};

  @override
  Future<List<SubtitleCandidate>> search(
    SubtitleQuery query,
    SubtitleSettings settings,
  ) async {
    final target = normalizeSubtitleTitle(query.title);
    if (target.isEmpty) return const [];
    final results = <SubtitleCandidate>[];
    var scanned = 0;

    for (final rawDir in settings.localDirectories) {
      final dir = Directory(rawDir.trim());
      if (!await dir.exists()) continue;
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        if (scanned >= maxFiles) break;
        scanned += 1;
        final path = entity.path;
        final extension = path.split('.').last.toLowerCase();
        if (!_extensions.contains(extension)) continue;
        final stem = path.split(Platform.pathSeparator).last;
        final normalized = normalizeSubtitleTitle(stem);
        if (normalized.isEmpty) continue;
        if (!normalized.contains(target) && !target.contains(normalized)) {
          continue;
        }
        final language = _languageFromName(stem);
        results.add(
          SubtitleCandidate(
            providerId: id,
            assetId: path,
            title: stem,
            language: language,
            format: extension,
            url: path,
          ),
        );
        if (results.length >= 30) break;
      }
    }
    return results;
  }

  static String _languageFromName(String filename) {
    final lower = filename.toLowerCase();
    bool any(List<String> tokens) => tokens.any(lower.contains);
    if (any(['chs', 'zh-hans', 'zh_cn', '简体', '简中'])) return 'zh-Hans';
    if (any(['cht', 'zh-hant', 'zh_tw', '繁体', '繁中'])) return 'zh-Hant';
    if (any(['eng', 'english', '英文', '英语'])) return 'en';
    return '';
  }
}
