/// 本地爬虫源扫描（只读、**绝不执行**被扫描文件）。
///
/// 目标：让用户指定一个文件夹，本类只做静态枚举与轻量文本探测，产出候选清单；
/// 导入由 `local_source_import.dart` 负责。扫描期间不启动任何解释器 / sidecar /
/// WebView，也不联网——纪律与 `direct_spider_registrar.dart` 的
/// `looksLikeCatVodShell`（只文本探测）一致。
///
/// 支持的三种形态：
/// - `.py`：Python 爬虫（CatVod 壳或 WebHTV 原生 ABI，按内容判定，只探测不执行）；
/// - `.js`：JavaScript 爬虫（TVBox 沙箱）；
/// - `.html` / `.htm`：站点首页注入（webHome），页面经宿主桥接取数据。
///
/// 扫描边界：深度、单文件大小、候选总数都有上限，避免误选整个磁盘时失控。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'direct_spider_registrar.dart' show looksLikeCatVodShell;

/// 本地源形态。
enum LocalSourceKind {
  /// Python 爬虫（`runtime` 记 `python` 或 `python-catvod`）。
  python,

  /// JavaScript 爬虫（`runtime` 记 `node-tvbox`）。
  javaScript,

  /// 站点首页注入：HTML 页面 + 资源目录。
  webHome;

  /// 展示用中文名。
  String get label => switch (this) {
    LocalSourceKind.python => 'Python 爬虫',
    LocalSourceKind.javaScript => 'JavaScript 爬虫',
    LocalSourceKind.webHome => 'HTML 首页注入',
  };

  /// 常见扩展名（用于 UI 过滤提示）。
  static const List<String> extensions = ['.py', '.js', '.html', '.htm'];
}

/// 一个扫描候选（尚未导入）。
class LocalSourceCandidate {
  const LocalSourceCandidate({
    required this.kind,
    required this.absPath,
    required this.sourceDir,
    required this.entryName,
    required this.key,
    required this.name,
    required this.bytes,
    required this.sha256,
    required this.modified,
    this.warnings = const [],
    this.looksCatVod = false,
  });

  final LocalSourceKind kind;

  /// 入口文件的绝对路径。
  final String absPath;

  /// 需要整体复制的目录（webHome 带资源；爬虫为其所在目录）。
  final String sourceDir;

  /// 入口文件名（相对 [sourceDir]）。
  final String entryName;

  /// 派生 key（小写、仅字母数字与 `-`/`_`）。
  final String key;

  /// 展示名（默认取 key，可被 UI 覆盖）。
  final String name;

  final int bytes;
  final String sha256;
  final DateTime modified;

  /// 预览阶段的警告（不阻止导入，但必须如实展示）。
  final List<String> warnings;

  /// Python 源是否为 CatVod 壳（需要 `webhtv_catvod` 适配层）。
  final bool looksCatVod;

  /// 建议的 manifest `runtime`。
  String get suggestedRuntime => switch (kind) {
    LocalSourceKind.python => looksCatVod ? 'python-catvod' : 'python',
    LocalSourceKind.javaScript => 'node-tvbox',
    LocalSourceKind.webHome => 'webhome',
  };
}

/// 一次扫描的结果。
class LocalScanReport {
  const LocalScanReport({
    required this.folder,
    this.candidates = const [],
    this.skipped = const [],
    this.truncated = false,
  });

  final String folder;

  /// 可导入的候选（按 key 去重）。
  final List<LocalSourceCandidate> candidates;

  /// 被跳过的条目与原因（超限、过大、目录不存在等）。
  final List<String> skipped;

  /// 是否因为命中上限而提前结束（UI 必须提示）。
  final bool truncated;

  bool get isEmpty => candidates.isEmpty;

  int countByKind(LocalSourceKind kind) =>
      candidates.where((item) => item.kind == kind).length;
}

/// 本地源扫描器。无状态、可复用，所有方法只读文件系统。
class LocalSpiderScanner {
  const LocalSpiderScanner({
    this.maxDepth = 4,
    this.maxBytes = 2 * 1024 * 1024,
    this.maxCandidates = 500,
  });

  /// 相对起始文件夹的最大递归深度（0 表示只看当前层）。
  final int maxDepth;

  /// 单入口文件大小上限。
  final int maxBytes;

  /// 候选总数上限，命中后提前结束并标记 `truncated`。
  final int maxCandidates;

  /// 不进入的目录名（构建产物 / 依赖 / 缓存）。
  static const Set<String> skipDirectoryNames = {
    'node_modules',
    '.git',
    '__pycache__',
    'build',
    'dist',
    '.dart_tool',
    '.gradle',
    '.idea',
    '.venv',
    'venv',
  };

  /// 扫描 [folder]，返回候选与跳过原因。**不启动任何进程、不联网。**
  Future<LocalScanReport> scan(String folder) async {
    final root = folder.trim();
    if (root.isEmpty) {
      return const LocalScanReport(folder: '', skipped: ['未指定文件夹']);
    }
    final directory = Directory(root);
    if (!await directory.exists()) {
      return LocalScanReport(folder: root, skipped: ['文件夹不存在：$root']);
    }

    final candidates = <LocalSourceCandidate>[];
    final skipped = <String>[];
    final seenKeys = <String>{};
    var truncated = false;

    Future<void> walk(Directory dir, int depth) async {
      if (truncated) return;
      List<FileSystemEntity> entries;
      try {
        entries = await dir.list(followLinks: false).toList();
      } catch (error) {
        skipped.add('无法读取 ${p.basename(dir.path)}：$error');
        return;
      }
      entries.sort((a, b) => a.path.compareTo(b.path));

      for (final entity in entries) {
        if (truncated) return;
        final name = p.basename(entity.path);
        if (entity is Directory) {
          if (skipDirectoryNames.contains(name)) {
            skipped.add('跳过目录 $name（构建/依赖/缓存）');
            continue;
          }
          if (depth >= maxDepth) {
            skipped.add('跳过 $name（超出深度 $maxDepth）');
            continue;
          }
          await walk(entity, depth + 1);
          continue;
        }
        if (entity is! File) continue;

        final ext = p.extension(name).toLowerCase();
        if (!LocalSourceKind.extensions.contains(ext)) continue;

        final candidate = await _inspect(entity, ext, skipped);
        if (candidate == null) continue;
        if (!seenKeys.add(candidate.key)) {
          skipped.add('跳过 ${p.basename(entity.path)}：key=${candidate.key} 重复');
          continue;
        }
        candidates.add(candidate);
        if (candidates.length >= maxCandidates) {
          truncated = true;
          skipped.add('候选达到上限 $maxCandidates，已停止扫描');
          return;
        }
      }
    }

    await walk(directory, 0);

    candidates.sort((a, b) {
      final byKind = a.kind.index.compareTo(b.kind.index);
      return byKind != 0 ? byKind : a.key.compareTo(b.key);
    });

    return LocalScanReport(
      folder: root,
      candidates: candidates,
      skipped: skipped,
      truncated: truncated,
    );
  }

  Future<LocalSourceCandidate?> _inspect(
    File file,
    String ext,
    List<String> skipped,
  ) async {
    final int size;
    try {
      size = await file.length();
    } catch (error) {
      skipped.add('无法读取 ${p.basename(file.path)}：$error');
      return null;
    }
    if (size > maxBytes) {
      skipped.add(
        '跳过 ${p.basename(file.path)}：${(size / 1024).toStringAsFixed(0)} KiB '
        '超过上限 ${(maxBytes / 1024).toStringAsFixed(0)} KiB',
      );
      return null;
    }

    final bytes = await file.readAsBytes();
    final digest = sha256.convert(bytes).toString();
    final warnings = <String>[];
    var looksCatVod = false;

    final kind = switch (ext) {
      '.py' => LocalSourceKind.python,
      '.js' => LocalSourceKind.javaScript,
      _ => LocalSourceKind.webHome,
    };

    if (kind == LocalSourceKind.python) {
      // 只按文本探测，绝不执行：与直接登记路径共用同一套判定。
      final text = _decodeText(bytes);
      if (text == null) {
        warnings.add('文件不是可识别的 UTF-8/GBK 文本');
      } else {
        looksCatVod = looksLikeCatVodShell(text);
        if (!looksCatVod &&
            !text.contains('class Spider') &&
            !text.contains('create_spider')) {
          warnings.add('未发现 Spider/create_spider，可能不是可用的 Python 源');
        }
      }
    } else if (kind == LocalSourceKind.javaScript) {
      final text = _decodeText(bytes);
      if (text == null) {
        warnings.add('文件不是可识别的 UTF-8/GBK 文本');
      } else if (!text.contains('init') && !text.contains('module.exports')) {
        warnings.add('未发现 init/module.exports，可能不是可用的 JS 源');
      }
    } else {
      final text = _decodeText(bytes);
      if (text == null) {
        warnings.add('文件不是可识别的 UTF-8/GBK 文本');
      } else if (!text.toLowerCase().contains('<html') &&
          !text.toLowerCase().contains('<!doctype')) {
        warnings.add('未发现 <html>/<!doctype>，可能不是完整页面');
      }
    }

    final isIndex = p.basenameWithoutExtension(file.path).toLowerCase() ==
        'index';
    final stem = isIndex ? p.basename(file.parent.path) : p.basenameWithoutExtension(file.path);
    final key = sanitizeKey(stem);
    if (key.isEmpty) {
      skipped.add('跳过 ${p.basename(file.path)}：无法从名称派生 key');
      return null;
    }

    return LocalSourceCandidate(
      kind: kind,
      absPath: file.path,
      sourceDir: file.parent.path,
      entryName: p.basename(file.path),
      key: key,
      name: stem.trim().isEmpty ? key : stem.trim(),
      bytes: size,
      sha256: digest,
      modified: await file.lastModified(),
      warnings: warnings,
      looksCatVod: looksCatVod,
    );
  }

  static String? _decodeText(List<int> bytes) {
    try {
      return utf8.decode(bytes);
    } catch (_) {
      // 源文件常有 GBK 注释，解码失败不影响大小/哈希结论。
      return null;
    }
  }
}

/// 把任意文件名压成安全 key：小写，只保留字母、数字、`-`、`_`，其余转 `-`。
String sanitizeKey(String raw) {
  final lowered = raw.trim().toLowerCase();
  final buffer = StringBuffer();
  for (final rune in lowered.runes) {
    final char = String.fromCharCode(rune);
    final keep =
        RegExp(r'[a-z0-9_-]').hasMatch(char) ||
        // 中文等非 ASCII 保留，避免站点名被清空。
        rune > 0x7f && char.trim().isNotEmpty;
    if (keep) {
      buffer.write(char);
    } else if (buffer.isNotEmpty && !buffer.toString().endsWith('-')) {
      buffer.write('-');
    }
  }
  var key = buffer.toString();
  while (key.endsWith('-')) {
    key = key.substring(0, key.length - 1);
  }
  return key;
}
