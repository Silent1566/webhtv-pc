/// 直播源加载服务（设计文档 §13.1、§13.3）。
///
/// 职责边界：
/// - 按 [LiveSource] 拉取直播清单（HTTP/本地文件），解码后交给
///   [parseLivePlaylist] 解析；不涉及 UI，也不改变播放策略；
/// - 失败统一归一化为 [AppError]，由调用方决定是否阻塞（单源失败不得阻塞其他源）；
/// - 复用 [decodeConfigText] 的编码探测（UTF-8 → GBK 兜底），与配置导入一致；
/// - 简单内存缓存：同一 URL 在 TTL 内复用，避免频繁拉取（§14.1 缓存风格）。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../core/app_error.dart';
import '../core/live_playlist.dart';
import '../core/protocol.dart';
import '../core/text_codec.dart';

/// 一次直播清单加载结果。
class LiveLoadResult {
  const LiveLoadResult({
    required this.playlist,
    required this.source,
    required this.latency,
    this.fromCache = false,
  });

  final LivePlaylist playlist;
  final LiveSource source;
  final Duration latency;

  /// 是否命中内存缓存。
  final bool fromCache;
}

/// 直播源加载服务。
class LiveService {
  LiveService({
    HttpClient? httpClient,
    this.maxBytes = 8 * 1024 * 1024,
    this.timeout = const Duration(seconds: 15),
    this.cacheTtl = const Duration(minutes: 5),
    this.userAgent = 'WebHTV-PC/0.1 (Windows)',
  }) : _client = httpClient ?? HttpClient() {
    _client.autoUncompress = true;
    _client.connectionTimeout = timeout;
  }

  /// 单份清单大小上限（§7.4.1 同量级 8 MiB）。
  final int maxBytes;
  final Duration timeout;
  final Duration cacheTtl;
  final String userAgent;
  final HttpClient _client;

  final Map<String, _CacheEntry> _cache = {};

  void close() => _client.close(force: true);

  /// 清空内存缓存（配置切换或手动刷新时调用）。
  void invalidate([String? url]) {
    if (url == null) {
      _cache.clear();
    } else {
      _cache.remove(url);
    }
  }

  /// 加载并解析一个直播源。
  ///
  /// [useCache] 为 false 时跳过缓存（手动刷新）。
  Future<LiveLoadResult> load(LiveSource source, {bool useCache = true}) async {
    final url = source.url?.trim() ?? '';
    if (url.isEmpty) {
      throw AppError(
        AppErrorKind.liveUnsupported,
        '直播源「${source.name}」未配置 url',
        detail: 'name=${source.name} type=${source.type}',
      );
    }

    if (useCache) {
      final cached = _cache[url];
      if (cached != null && !cached.isExpired(cacheTtl)) {
        return LiveLoadResult(
          playlist: cached.playlist,
          source: source,
          latency: Duration.zero,
          fromCache: true,
        );
      }
    }

    final stopwatch = Stopwatch()..start();
    final text = await _readText(url, source);
    final playlist = parseLivePlaylist(
      source.name,
      text,
      declaredType: source.type,
    );
    _cache[url] = _CacheEntry(playlist: playlist, storedAt: DateTime.now());
    return LiveLoadResult(
      playlist: playlist,
      source: source,
      latency: stopwatch.elapsed,
    );
  }

  Future<String> _readText(String url, LiveSource source) async {
    // Windows 盘符路径（`C:\...` / `C:/...`）不是 URI，必须先于 URI 解析判定，
    // 否则 `Uri.parse` 会把盘符当成 scheme（§7.4.1 本地文件分支同理）。
    if (RegExp(r'^[A-Za-z]:[\\/]').hasMatch(url)) {
      return _readFile(url);
    }
    if (url.toLowerCase().startsWith('file://')) {
      final fileUri = Uri.tryParse(url);
      if (fileUri == null) {
        throw AppError(
          AppErrorKind.liveInvalid,
          '直播源地址非法',
          detail: redactUrl(url),
        );
      }
      return _readFile(fileUri.toFilePath());
    }

    final uri = Uri.tryParse(url);
    if (uri == null) {
      throw AppError(
        AppErrorKind.liveInvalid,
        '直播源地址非法',
        detail: redactUrl(url),
      );
    }

    final scheme = uri.scheme.toLowerCase();
    if (scheme == 'http' || scheme == 'https') {
      return _fetchUrl(uri, source);
    }
    if (scheme.isEmpty) {
      // 裸路径（相对/绝对）视为本地文件（与配置导入的 file 分支同语义）。
      return _readFile(url);
    }
    throw AppError(
      AppErrorKind.liveUnsupported,
      '直播源地址协议不受支持：$scheme',
      detail: redactUrl(url),
    );
  }

  Future<String> _readFile(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw AppError(
        AppErrorKind.liveInvalid,
        '直播清单文件不存在',
        detail: path,
      );
    }
    final bytes = await file.readAsBytes();
    if (bytes.length > maxBytes) {
      throw AppError(
        AppErrorKind.liveDecode,
        '直播清单超过大小上限（${maxBytes ~/ (1024 * 1024)} MiB）',
        detail: '${bytes.length} bytes',
      );
    }
    return _decode(bytes, null);
  }

  Future<String> _fetchUrl(Uri uri, LiveSource source) async {
    final request = await _client.getUrl(uri).timeout(timeout);
    request.headers.set(HttpHeaders.acceptHeader, '*/*');
    request.headers.set(HttpHeaders.userAgentHeader, source.userAgent ?? userAgent);
    if (source.referer != null && source.referer!.isNotEmpty) {
      request.headers.set(HttpHeaders.refererHeader, source.referer!);
    }

    final response = await request.close().timeout(timeout);
    final status = response.statusCode;
    if (status < 200 || status >= 300) {
      await response.drain<void>();
      throw AppError(
        AppErrorKind.liveHttp,
        '直播清单下载返回 HTTP $status',
        detail: redactUrl(uri.toString()),
        statusCode: status,
        retryable: status >= 500,
      );
    }

    final declaredLength = response.headers.contentLength;
    if (declaredLength > maxBytes) {
      await response.drain<void>();
      throw AppError(
        AppErrorKind.liveDecode,
        '直播清单声明长度超过上限',
        detail: 'Content-Length=$declaredLength',
      );
    }

    final bytes = await _readBounded(response, uri);
    final charset = charsetFromContentType(
      response.headers.value(HttpHeaders.contentTypeHeader),
    );
    return _decode(bytes, charset);
  }

  Future<List<int>> _readBounded(HttpClientResponse response, Uri uri) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(timeout)) {
      builder.add(chunk);
      if (builder.length > maxBytes) {
        throw AppError(
          AppErrorKind.liveDecode,
          '直播清单超过大小上限（${maxBytes ~/ (1024 * 1024)} MiB）',
          detail: redactUrl(uri.toString()),
        );
      }
    }
    return builder.takeBytes();
  }

  String _decode(List<int> bytes, String? charset) {
    try {
      return decodeConfigText(bytes, declaredCharset: charset);
    } on AppError catch (error) {
      // 编码失败归一到直播错误分类，保留原始 detail。
      throw AppError(
        AppErrorKind.liveDecode,
        error.message,
        detail: error.detail,
        cause: error,
      );
    }
  }
}

class _CacheEntry {
  _CacheEntry({required this.playlist, required this.storedAt});

  final LivePlaylist playlist;
  final DateTime storedAt;

  bool isExpired(Duration ttl) => DateTime.now().difference(storedAt) > ttl;
}
