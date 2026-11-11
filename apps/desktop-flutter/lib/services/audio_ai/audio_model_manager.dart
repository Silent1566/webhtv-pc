/// 实时字幕模型管理：固定目录布局、断点下载、SHA256 校验、本地导入、取消。
///
/// 合同（源 `RealtimeSubtitleController` + `RealtimeSubtitleModelCatalog`）：
/// 下载按 catalog 的 URL/size/sha256 校验，任何校验失败都不激活模型；只有整包
/// 全部文件通过后才把 `.part` 落成正式文件；取消时保留 `.part` 供下次续传。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../../core/audio_ai/model_catalog.dart';
import '../ai_completion_client.dart';

class ModelIntegrityException implements Exception {
  ModelIntegrityException(this.message);

  final String message;

  @override
  String toString() => 'ModelIntegrityException: $message';
}

class ModelDownloadCancelled implements Exception {
  const ModelDownloadCancelled();

  @override
  String toString() => 'ModelDownloadCancelled';
}

class ModelDownloadProgress {
  const ModelDownloadProgress({
    required this.modelId,
    required this.fileIndex,
    required this.fileCount,
    required this.file,
    required this.receivedBytes,
    required this.totalBytes,
    required this.fileBytes,
  });

  final String modelId;
  final int fileIndex;
  final int fileCount;
  final String file;
  final int receivedBytes;
  final int totalBytes;
  final int fileBytes;

  double get value => totalBytes <= 0 ? 0 : receivedBytes / totalBytes;
}

class AudioModelManager {
  AudioModelManager({
    required this.root,
    http.Client? client,
    this.chunkBytes = 1 << 16,
  }) : _client = client;

  /// 模型根目录（通常是 `%APPDATA%` 下的 audio_ai/models）。
  final Directory root;
  final int chunkBytes;
  http.Client? _client;

  http.Client get client => _client ??= http.Client();

  Directory modelDir(RealtimeModelSpec spec) =>
      Directory(p.join(root.path, spec.directory));

  File fileOf(RealtimeModelSpec spec, RealtimeModelFile file) =>
      File(p.join(modelDir(spec).path, file.relativePath));

  File partialOf(RealtimeModelSpec spec, RealtimeModelFile file) =>
      File(p.join(modelDir(spec).path, '${file.relativePath}.part'));

  /// 与源 `isModelReady` 同语义：文件存在且大小与 catalog 一致。
  bool isReadySync(RealtimeModelSpec spec) {
    for (final file in spec.downloads) {
      final target = fileOf(spec, file);
      if (!target.existsSync()) return false;
      if (target.lengthSync() != file.size) return false;
    }
    return true;
  }

  List<RealtimeModelFile> missingFilesSync(RealtimeModelSpec spec) => [
    for (final file in spec.downloads)
      if (!fileOf(spec, file).existsSync() ||
          fileOf(spec, file).lengthSync() != file.size)
        file,
  ];

  /// 逐文件 SHA256 校验；返回问题列表（空表示全部通过）。
  Future<List<String>> verify(RealtimeModelSpec spec) async {
    final problems = <String>[];
    for (final file in spec.downloads) {
      final target = fileOf(spec, file);
      if (!await target.exists()) {
        problems.add('${file.relativePath}: missing');
        continue;
      }
      if (await target.length() != file.size) {
        problems.add('${file.relativePath}: size mismatch');
        continue;
      }
      final digest = await _sha256Of(target);
      if (digest != file.sha256.toLowerCase()) {
        problems.add('${file.relativePath}: sha256 mismatch');
      }
    }
    return problems;
  }

  /// 按 catalog 下载全部文件；[isCancelled] 为真时抛 [ModelDownloadCancelled]
  /// 并保留 `.part`。只有每个文件都通过校验才会 rename 成正式文件。
  Future<void> download(
    RealtimeModelSpec spec, {
    void Function(ModelDownloadProgress progress)? onProgress,
    bool Function()? isCancelled,
    Uri Function(RealtimeModelFile file)? mirror,
    AiCancellationToken? cancellationToken,
  }) async {
    if ((isCancelled?.call() ?? false) ||
        (cancellationToken?.isCancelled ?? false)) {
      throw const ModelDownloadCancelled();
    }
    await modelDir(spec).create(recursive: true);
    final files = spec.downloads;
    final totalBytes = files.fold<int>(0, (sum, file) => sum + file.size);
    var completedBytes = 0;
    for (var index = 0; index < files.length; index++) {
      final file = files[index];
      final target = fileOf(spec, file);
      if (await target.exists() && await target.length() == file.size) {
        final digest = await _sha256Of(target);
        if (digest == file.sha256.toLowerCase()) {
          completedBytes += file.size;
          continue;
        }
        await target.delete();
      }
      final written = await _downloadOne(
        spec: spec,
        file: file,
        index: index,
        count: files.length,
        baseBytes: completedBytes,
        totalBytes: totalBytes,
        onProgress: onProgress,
        isCancelled: isCancelled,
        mirror: mirror,
        cancellationToken: cancellationToken,
      );
      completedBytes += written;
    }
    final problems = await verify(spec);
    if (problems.isNotEmpty) {
      throw ModelIntegrityException(problems.join('; '));
    }
  }

  Future<int> _downloadOne({
    required RealtimeModelSpec spec,
    required RealtimeModelFile file,
    required int index,
    required int count,
    required int baseBytes,
    required int totalBytes,
    void Function(ModelDownloadProgress progress)? onProgress,
    bool Function()? isCancelled,
    Uri Function(RealtimeModelFile file)? mirror,
    AiCancellationToken? cancellationToken,
  }) async {
    final partial = partialOf(spec, file);
    var existing = await partial.exists() ? await partial.length() : 0;
    if (existing > file.size) {
      await partial.delete();
      existing = 0;
    }
    final uri = mirror?.call(file) ?? Uri.parse(file.url);
    final request = http.AbortableRequest(
      'GET',
      uri,
      abortTrigger: cancellationToken?.whenCancelled,
    );
    // 固定 revision 的 HF 直链支持 Range；服务端忽略时按整包重下。
    if (existing > 0) request.headers['Range'] = 'bytes=$existing-';
    http.StreamedResponse response;
    try {
      response = await client.send(request);
    } on http.RequestAbortedException {
      throw const ModelDownloadCancelled();
    }
    if (response.statusCode != 200 && response.statusCode != 206) {
      throw ModelIntegrityException(
        'http ${response.statusCode} for ${file.relativePath}',
      );
    }
    if (response.statusCode == 200) existing = 0;
    final sink = partial.openWrite(
      mode: existing > 0 ? FileMode.append : FileMode.write,
    );
    var received = existing;
    try {
      await for (final chunk in response.stream) {
        if ((isCancelled?.call() ?? false) ||
            (cancellationToken?.isCancelled ?? false)) {
          throw const ModelDownloadCancelled();
        }
        if (received + chunk.length > file.size) {
          throw ModelIntegrityException(
            '${file.relativePath}: server sent more bytes than catalog size',
          );
        }
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(
          ModelDownloadProgress(
            modelId: spec.id,
            fileIndex: index,
            fileCount: count,
            file: file.relativePath,
            receivedBytes: baseBytes + received,
            totalBytes: totalBytes,
            fileBytes: received,
          ),
        );
      }
    } finally {
      await sink.flush();
      await sink.close();
    }
    if (received != file.size) {
      throw ModelIntegrityException(
        '${file.relativePath}: size ${received} != ${file.size}',
      );
    }
    final digest = await _sha256Of(partial);
    if (digest != file.sha256.toLowerCase()) {
      await partial.delete();
      throw ModelIntegrityException('${file.relativePath}: sha256 mismatch');
    }
    if ((isCancelled?.call() ?? false) ||
        (cancellationToken?.isCancelled ?? false)) {
      throw const ModelDownloadCancelled();
    }
    await partial.rename(fileOf(spec, file).path);
    return received;
  }

  /// 本地导入：校验哈希后复制到模型目录，任一失败整包不生效。
  Future<void> importLocal(
    RealtimeModelSpec spec,
    Map<String, String> sourcePathByRelative,
  ) async {
    final missing = spec.downloads
        .where((file) => !sourcePathByRelative.containsKey(file.relativePath))
        .map((file) => file.relativePath)
        .toList();
    if (missing.isNotEmpty) {
      throw ModelIntegrityException(
        'missing local files: ${missing.join(',')}',
      );
    }
    final staging = Directory('${modelDir(spec).path}.import');
    if (await staging.exists()) await staging.delete(recursive: true);
    await staging.create(recursive: true);
    try {
      for (final file in spec.downloads) {
        final source = File(sourcePathByRelative[file.relativePath]!);
        if (!await source.exists()) {
          throw ModelIntegrityException('${file.relativePath}: source missing');
        }
        if (await source.length() != file.size) {
          throw ModelIntegrityException('${file.relativePath}: size mismatch');
        }
        final digest = await _sha256Of(source);
        if (digest != file.sha256.toLowerCase()) {
          throw ModelIntegrityException(
            '${file.relativePath}: sha256 mismatch',
          );
        }
        await source.copy(p.join(staging.path, file.relativePath));
      }
      final target = modelDir(spec);
      if (await target.exists()) await target.delete(recursive: true);
      await staging.rename(target.path);
    } finally {
      if (await staging.exists()) await staging.delete(recursive: true);
    }
  }

  Future<void> delete(RealtimeModelSpec spec) async {
    final dir = modelDir(spec);
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  /// 模型目录导出清单（供诊断与 UI 展示真实来源）。
  Future<Map<String, Object?>> describe(RealtimeModelSpec spec) async {
    final problems = await verify(spec);
    return {
      'modelId': spec.id,
      'directory': spec.directory,
      'engine': spec.engine.name,
      'ready': problems.isEmpty,
      'problems': problems,
      'files': [
        for (final file in spec.downloads)
          {
            'path': file.relativePath,
            'url': file.url,
            'size': file.size,
            'sha256': file.sha256,
            'present': await fileOf(spec, file).exists(),
          },
      ],
    };
  }

  static Future<String> _sha256Of(File file) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }

  static String cacheKeyOf(String text) =>
      sha256.convert(utf8.encode(text)).toString();

  void close() {
    _client?.close();
    _client = null;
  }
}
