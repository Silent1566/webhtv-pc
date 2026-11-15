/// 字幕下载与解包：把「候选」变成「播放器能直接读的本地文件」。
///
/// 为什么必须有这一层：ASSRT 的下载响应可能是 ZIP，且详情接口与下载地址是两跳；
/// 播放器侧的 `_subtitleLoader` 只认字幕文本或本地文件，不认 ZIP。
///
/// 约束（计划 §0.1）：
/// - 落盘扩展名按**最终文件真实扩展名**，不是候选上的声明值（D1）；
/// - ZIP 内没有字幕条目时显式失败，绝不把 ZIP 原样交给播放器（D2）；
/// - 缓存按文件数量裁剪（D3）；
/// - 任何异常收敛成 [SubtitleResolveException]，不把堆栈丢给播放器。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../core/subtitle_provider.dart';
import 'log_service.dart';

/// 解析失败的**原因码**：可读、可断言、不含 URL/token。
class SubtitleResolveException implements Exception {
  const SubtitleResolveException(this.code);

  final String code;

  @override
  String toString() => 'SubtitleResolveException($code)';
}

class SubtitleAssetStore {
  SubtitleAssetStore({
    required this.cacheDir,
    http.Client? client,
    this.log,
    this.timeout = const Duration(seconds: 15),
    this.maxFiles = 100,
    this.maxDownloadBytes = 32 * 1024 * 1024,
    this.maxEntryBytes = 32 * 1024 * 1024,
    this.maxTotalBytes = 64 * 1024 * 1024,
  }) : _client = client ?? http.Client();

  /// 字幕缓存目录（调用方给 `<cacheDir>/subtitles`）。
  final String cacheDir;

  final LogService? log;
  final Duration timeout;

  /// 缓存裁剪上限（保留最新 N 个文件）。
  final int maxFiles;

  final http.Client _client;

  static const Set<String> subtitleExtensions = {'srt', 'ass', 'ssa', 'vtt', 'sub'};

  /// 应用缓存目录 → 字幕缓存目录。
  ///
  /// 装配 provider 的地方（播放器页、服务）都用这一处，避免两处各拼一遍路径。
  static String defaultCacheDir(String appCacheDir) =>
      appCacheDir.trim().isEmpty ? '' : p.join(appCacheDir, 'subtitles');

  /// 单次下载上限；ZIP 解压后另有单条目/累计上限。
  /// 做成实例字段是为了让测试用极小值触发守卫，而不是真的造 32MB 数据。
  final int maxDownloadBytes;
  final int maxEntryBytes;
  final int maxTotalBytes;

  /// 下载一个候选并落到 [cacheDir]，返回可直接交给播放器的路径。
  ///
  /// [nameHint] 只用于生成文件名，不参与格式判断。
  Future<SubtitleResolvedAsset> download({
    required String url,
    Map<String, String> headers = const {},
    required String nameHint,
    String fallbackFormat = 'srt',
  }) async {
    if (cacheDir.trim().isEmpty) {
      throw const SubtitleResolveException('no_cache_dir');
    }
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.hasScheme) {
      throw const SubtitleResolveException('bad_url');
    }
    final bytes = await _fetch(uri, headers);
    final dir = Directory(cacheDir);
    await dir.create(recursive: true);
    await _prune(dir);

    final stem = _fileStem(nameHint, url);
    if (_isZip(bytes)) {
      return _extractZip(
        bytes,
        dir,
        stem: stem,
        fallbackFormat: fallbackFormat,
      );
    }
    final extension = _extensionOf(uri.path, fallbackFormat);
    if (extension.isEmpty) {
      throw const SubtitleResolveException('unsupported_format');
    }
    final file = File(p.join(dir.path, '$stem.$extension'));
    await file.writeAsBytes(bytes, flush: true);
    return SubtitleResolvedAsset(
      path: file.path,
      format: extension,
      fileName: p.basename(file.path),
    );
  }

  Future<Uint8List> _fetch(Uri uri, Map<String, String> headers) async {
    final request = http.Request('GET', uri);
    request.headers.addAll({'Accept': '*/*', ...headers});
    final http.StreamedResponse response;
    try {
      response = await _client.send(request).timeout(timeout);
    } on TimeoutException {
      throw const SubtitleResolveException('timeout');
    } on http.ClientException {
      throw const SubtitleResolveException('network');
    } on SocketException {
      throw const SubtitleResolveException('network');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw SubtitleResolveException('http_${response.statusCode}');
    }
    final builder = BytesBuilder(copy: false);
    try {
      await for (final chunk in response.stream.timeout(timeout)) {
        builder.add(chunk);
        if (builder.length > maxDownloadBytes) {
          throw const SubtitleResolveException('too_large');
        }
      }
    } on TimeoutException {
      throw const SubtitleResolveException('timeout');
    }
    return builder.takeBytes();
  }

  Future<SubtitleResolvedAsset> _extractZip(
    Uint8List bytes,
    Directory dir, {
    required String stem,
    required String fallbackFormat,
  }) async {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw const SubtitleResolveException('zip_corrupt');
    }
    final picked = <ArchiveFile>[];
    var total = 0;
    for (final file in archive.files) {
      if (!file.isFile) continue;
      if (!_isSafeEntry(file.name)) {
        throw const SubtitleResolveException('zip_traversal');
      }
      if (file.size > maxEntryBytes) {
        throw const SubtitleResolveException('zip_entry_too_large');
      }
      total += file.size;
      if (total > maxTotalBytes) {
        throw const SubtitleResolveException('zip_too_large');
      }
      final extension = _extensionOf(file.name, '');
      if (!subtitleExtensions.contains(extension)) continue;
      picked.add(file);
    }
    if (picked.isEmpty) {
      // D2：ZIP 里没有字幕就让这次 resolve 失败，别把 ZIP 交给 mpv。
      throw const SubtitleResolveException('zip_no_subtitle');
    }
    picked.sort((a, b) {
      final aAss = _extensionOf(a.name, '') == 'ass' ? 0 : 1;
      final bAss = _extensionOf(b.name, '') == 'ass' ? 0 : 1;
      if (aAss != bAss) return aAss - bAss;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    final chosen = picked.first;
    final extension = _extensionOf(chosen.name, fallbackFormat);
    final file = File(p.join(dir.path, '$stem.$extension'));
    await file.writeAsBytes(chosen.content, flush: true);
    return SubtitleResolvedAsset(
      path: file.path,
      format: extension,
      fileName: p.basename(file.path),
    );
  }

  /// 缓存裁剪：保留最新 [maxFiles] 个文件，其余尽力删除（失败不抛出）。
  Future<void> _prune(Directory dir) async {
    try {
      final files = <File>[];
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is File) files.add(entity);
      }
      if (files.length <= maxFiles) return;
      final dated = <MapEntry<File, DateTime>>[];
      for (final file in files) {
        try {
          final stat = await file.stat();
          dated.add(MapEntry(file, stat.modified));
        } catch (_) {
          // 统计不到就不参与排序，交给下一轮。
        }
      }
      dated.sort((a, b) => b.value.compareTo(a.value));
      for (final entry in dated.skip(maxFiles)) {
        try {
          await entry.key.delete();
        } catch (_) {
          // 删不掉不是错误（可能被播放器占用）。
        }
      }
    } catch (error) {
      log?.warning('字幕缓存裁剪失败 $error', scope: 'subtitle');
    }
  }

  static bool _isZip(Uint8List bytes) {
    if (bytes.length < 4) return false;
    if (bytes[0] != 0x50 || bytes[1] != 0x4B) return false;
    // PK\x03\x04（普通归档）、PK\x05\x06（空归档）、PK\x07\x08（分卷）。
    return bytes[2] == 0x03 || bytes[2] == 0x05 || bytes[2] == 0x07;
  }

  static bool _isSafeEntry(String name) {
    final normalized = name.replaceAll('\\', '/');
    if (normalized.trim().isEmpty) return false;
    if (normalized.startsWith('/')) return false;
    if (RegExp(r'^[A-Za-z]:').hasMatch(normalized)) return false;
    return !normalized.split('/').any((segment) => segment == '..');
  }

  /// 从路径/URL 取扩展名；不在字幕白名单时回退 [fallback]。
  static String _extensionOf(String path, String fallback) {
    final dot = path.lastIndexOf('.');
    if (dot < 0 || dot == path.length - 1) return fallback;
    final extension = path.substring(dot + 1).toLowerCase();
    if (subtitleExtensions.contains(extension)) return extension;
    return fallback;
  }

  /// 文件名主干：保留 CJK，去掉路径分隔符与非法字符，附 URL 短哈希避免互相覆盖。
  static String _fileStem(String nameHint, String url) {
    final base = p.basenameWithoutExtension(nameHint.trim());
    final cleaned = base
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_')
        .trim();
    final clipped = cleaned.length > 60 ? cleaned.substring(0, 60) : cleaned;
    final digest = sha1.convert(url.codeUnits).toString().substring(0, 8);
    return clipped.isEmpty ? 'subtitle_$digest' : '${clipped}_$digest';
  }
}
