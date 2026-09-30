/// EPG 加载服务（设计文档 §13.1「EPG」、§13.3「EPG 可加载、刷新、显示当前节目」）。
///
/// 职责：
/// - 从直播清单声明的 `url-tvg` 拉取 XMLTV（HTTP/本地文件），复用
///   [decodeTextAndCharset] 的编码探测（BOM → 声明 charset → UTF-8 → GBK 兜底）；
/// - **gzip 支持**：EPG 文件常以 `.xml.gz` 分发（对齐 Android `EpgParser.isGzip`
///   的魔数检测 `0x1F 0x8B`）；
/// - **缓存与刷新**（对齐 Android `EpgParser.refreshReason`）：缓存文件缺失、
///   不是今天的、或超过 6 小时 → 重新拉取；否则直接用缓存；
/// - 失败归一化为 [AppError]（`epg*` 分类），**不得阻断直播播放**（§13.3 EPG 是
///   直播的增强项，不是播放前置条件）。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../core/app_error.dart';
import '../core/epg.dart';
import '../core/protocol.dart';
import '../core/text_codec.dart';

/// EPG 缓存有效期（对齐 Android 的 6 小时）。
const Duration epgCacheTtl = Duration(hours: 6);

/// 单份 EPG 大小上限（XMLTV 可达数 MB；给 32 MiB 余量）。
const int maxEpgBytes = 32 * 1024 * 1024;

/// 一次 EPG 加载结果。
class EpgLoadResult {
  const EpgLoadResult({
    required this.guide,
    required this.url,
    required this.fromCache,
    required this.latency,
    this.bytes = 0,
  });

  final EpgGuide guide;
  final String url;

  /// 是否直接使用缓存（未重新下载）。
  final bool fromCache;

  final Duration latency;

  /// 下载/读取的原始字节数（缓存命中时为缓存大小）。
  final int bytes;

  String get logLine =>
      '${guide.logLine} fromCache=$fromCache bytes=$bytes '
      'elapsed=${latency.inMilliseconds}ms url=${redactUrl(url)}';
}

/// EPG 服务。
class EpgService {
  EpgService({
    HttpClient? httpClient,
    required this.cacheDir,
    this.maxBytes = maxEpgBytes,
    this.timeout = const Duration(seconds: 20),
    this.cacheTtl = epgCacheTtl,
    this.userAgent = 'WebHTV-PC/0.1 (Windows)',
    this.maxRedirects = 3,
    DateTime Function()? clock,
  }) : _client = httpClient ?? HttpClient(),
       _now = clock ?? DateTime.now {
    _client.autoUncompress = false;
    _client.connectionTimeout = timeout;
  }

  /// 缓存目录（`AppPaths.cacheDir` 下的 `epg/`）。
  final String cacheDir;
  final int maxBytes;
  final Duration timeout;
  final Duration cacheTtl;
  final String userAgent;
  final int maxRedirects;
  final HttpClient _client;
  final DateTime Function() _now;

  void close() => _client.close(force: true);

  /// 加载一份 EPG。
  ///
  /// [liveChannels] 用于把 XMLTV channel id 匹配到直播频道；
  /// [forceRefresh] 为 true 时忽略缓存（UI「刷新」入口）。
  Future<EpgLoadResult> load({
    required String url,
    List<LiveChannel> liveChannels = const [],
    String sourceName = '',
    bool forceRefresh = false,
  }) async {
    final target = url.trim();
    if (target.isEmpty) {
      throw AppError(
        AppErrorKind.epgUnsupported,
        'EPG 地址为空',
        detail: 'source=$sourceName',
      );
    }

    final stopwatch = Stopwatch()..start();
    final cacheFile = _cacheFileFor(target);

    // 1) 缓存命中判定（对齐 Android refreshReason）。
    if (!forceRefresh) {
      final cached = await _readCache(cacheFile);
      if (cached != null) {
        final guide = _parse(cached, liveChannels, target, sourceName);
        return EpgLoadResult(
          guide: guide,
          url: target,
          fromCache: true,
          latency: stopwatch.elapsed,
          bytes: cached.length,
        );
      }
    }

    // 2) 下载/读取。
    final raw = await _fetch(target);
    if (raw.isEmpty) {
      throw AppError(
        AppErrorKind.epgEmpty,
        'EPG 内容为空',
        detail: redactUrl(target),
      );
    }
    await _writeCache(cacheFile, raw);
    final decompressed = _decompressIfGzip(raw, target);
    final guide = _parse(decompressed, liveChannels, target, sourceName);
    return EpgLoadResult(
      guide: guide,
      url: target,
      fromCache: false,
      latency: stopwatch.elapsed,
      bytes: raw.length,
    );
  }

  /// 清空 EPG 缓存（配置切换或手动清理时）。
  Future<void> clearCache() async {
    final dir = Directory(cacheDir);
    if (!await dir.exists()) return;
    // 缓存文件落在 `<cacheDir>/epg/` 子目录，必须递归列举；
    // 只删本服务写的 `.epg` 文件，不动目录里的其他内容。
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File && entity.path.endsWith('.epg')) {
        try {
          await entity.delete();
        } catch (_) {
          // 单个文件删不掉不阻塞清理。
        }
      }
    }
  }

  // ------------------------------------------------------------------ 内部

  EpgGuide _parse(
    Uint8List bytes,
    List<LiveChannel> liveChannels,
    String url,
    String sourceName,
  ) {
    final text = _decode(bytes, url);
    final guide = parseXmlTv(
      text,
      liveChannels: liveChannels,
      sourceName: sourceName.isEmpty ? redactUrl(url) : sourceName,
    );
    if (guide.isEmpty) {
      throw AppError(
        AppErrorKind.epgEmpty,
        'EPG 没有匹配到任何频道的节目'
        '（节目 ${guide.totalPrograms} 条，丢弃 ${guide.skippedPrograms} 条）',
        detail: redactUrl(url),
      );
    }
    return guide;
  }

  String _decode(Uint8List bytes, String url) {
    try {
      return decodeTextAndCharset(bytes).text;
    } on AppError catch (error) {
      throw AppError(
        AppErrorKind.epgDecode,
        'EPG 解码失败：${error.message}',
        detail: redactUrl(url),
        cause: error,
      );
    }
  }

  /// gzip 魔数检测 + 解压（对齐 Android `EpgParser.isGzip`）。
  Uint8List _decompressIfGzip(Uint8List bytes, String url) {
    if (bytes.length < 2 || bytes[0] != 0x1F || bytes[1] != 0x8B) {
      return bytes;
    }
    try {
      return Uint8List.fromList(gzip.decode(bytes));
    } catch (error) {
      throw AppError(
        AppErrorKind.epgDecode,
        'EPG gzip 解压失败',
        detail: redactUrl(url),
        cause: error,
      );
    }
  }

  /// 缓存文件路径：`<cacheDir>/epg/<hash>.epg`。
  File _cacheFileFor(String url) {
    final digest = url.hashCode.toRadixString(16);
    return File(
      '$cacheDir${Platform.pathSeparator}epg'
      '${Platform.pathSeparator}$digest.epg',
    );
  }

  /// 读取缓存；过期/缺失/损坏时返回 null（触发重新下载）。
  Future<Uint8List?> _readCache(File file) async {
    try {
      if (!await file.exists()) return null;
      final stat = await file.stat();
      final now = _now();
      final modified = stat.modified;
      // 不是今天修改的 → 过期（对齐 Android `isToday`）。
      if (modified.year != now.year ||
          modified.month != now.month ||
          modified.day != now.day) {
        return null;
      }
      // 超过 TTL → 过期。
      if (now.difference(modified) > cacheTtl) return null;
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty || bytes.length > maxBytes) return null;
      return bytes;
    } catch (_) {
      // 缓存不可用一律按未命中处理（不得让缓存故障成为播放阻断项）。
      return null;
    }
  }

  Future<void> _writeCache(File file, Uint8List bytes) async {
    try {
      final dir = file.parent;
      if (!await dir.exists()) await dir.create(recursive: true);
      await file.writeAsBytes(bytes, flush: true);
    } catch (_) {
      // 缓存写入失败不影响本次使用。
    }
  }

  Future<Uint8List> _fetch(String url) async {
    // Windows 盘符路径先于 URI 解析判定。
    if (RegExp(r'^[A-Za-z]:[\\/]').hasMatch(url)) {
      return _readFile(url);
    }
    if (url.toLowerCase().startsWith('file://')) {
      final fileUri = Uri.tryParse(url);
      if (fileUri == null) {
        throw AppError(
          AppErrorKind.epgUnsupported,
          'EPG 地址非法',
          detail: redactUrl(url),
        );
      }
      return _readFile(fileUri.toFilePath());
    }

    final uri = Uri.tryParse(url);
    if (uri == null) {
      throw AppError(
        AppErrorKind.epgUnsupported,
        'EPG 地址非法',
        detail: redactUrl(url),
      );
    }
    final scheme = uri.scheme.toLowerCase();
    if (scheme == 'http' || scheme == 'https') return _fetchHttp(uri);
    if (scheme.isEmpty) return _readFile(url);
    throw AppError(
      AppErrorKind.epgUnsupported,
      'EPG 地址协议不受支持：$scheme',
      detail: redactUrl(url),
    );
  }

  Future<Uint8List> _readFile(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw AppError(
        AppErrorKind.epgNetwork,
        'EPG 文件不存在或无法读取',
        detail: path,
      );
    }
    final bytes = await file.readAsBytes();
    if (bytes.length > maxBytes) {
      throw AppError(
        AppErrorKind.epgDecode,
        'EPG 文件超过大小上限（${maxBytes ~/ (1024 * 1024)} MiB）',
        detail: '${bytes.length} bytes',
      );
    }
    return bytes;
  }

  Future<Uint8List> _fetchHttp(Uri uri) async {
    var current = uri;
    for (var redirect = 0; redirect <= maxRedirects; redirect++) {
      final response = await _request(current);
      final status = response.statusCode;
      if (status >= 300 && status < 400) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        await response.drain<void>();
        final next = location == null ? null : current.resolve(location);
        if (next == null ||
            !(next.isScheme('http') || next.isScheme('https'))) {
          throw AppError(
            AppErrorKind.epgHttp,
            'EPG 重定向目标非法',
            detail: redactUrl(current.toString()),
            statusCode: status,
          );
        }
        current = next;
        continue;
      }
      if (status < 200 || status >= 300) {
        await response.drain<void>();
        throw AppError(
          AppErrorKind.epgHttp,
          'EPG 下载返回 HTTP $status',
          detail: redactUrl(current.toString()),
          statusCode: status,
          retryable: status >= 500,
        );
      }
      final declaredLength = response.headers.contentLength;
      if (declaredLength > maxBytes) {
        await response.drain<void>();
        throw AppError(
          AppErrorKind.epgDecode,
          'EPG 响应超过大小上限（${maxBytes ~/ (1024 * 1024)} MiB）',
          detail: redactUrl(current.toString()),
        );
      }
      return await _readBounded(response, current);
    }
    throw AppError(
      AppErrorKind.epgHttp,
      'EPG 重定向超过 $maxRedirects 次',
      detail: redactUrl(uri.toString()),
    );
  }

  Future<HttpClientResponse> _request(Uri uri) async {
    try {
      final request = await _client.getUrl(uri).timeout(timeout);
      request.headers.set(HttpHeaders.acceptHeader, '*/*');
      request.headers.set(HttpHeaders.userAgentHeader, userAgent);
      request.followRedirects = false;
      return await request.close().timeout(timeout);
    } on TimeoutException catch (error) {
      throw AppError(
        AppErrorKind.epgNetwork,
        'EPG 下载超时（${timeout.inSeconds}s）',
        detail: redactUrl(uri.toString()),
        retryable: true,
        cause: error,
      );
    } on SocketException catch (error) {
      throw AppError(
        AppErrorKind.epgNetwork,
        'EPG 下载失败：DNS 或连接失败',
        detail: '${redactUrl(uri.toString())} '
            '(${error.osError?.message ?? error.message})',
        retryable: true,
        cause: error,
      );
    } on HttpException catch (error) {
      throw AppError(
        AppErrorKind.epgNetwork,
        'EPG 下载失败：HTTP 层异常',
        detail: redactUrl(uri.toString()),
        cause: error,
      );
    }
  }

  Future<Uint8List> _readBounded(
    HttpClientResponse response,
    Uri uri,
  ) async {
    final builder = BytesBuilder(copy: false);
    final completer = Completer<void>();
    late StreamSubscription<List<int>> subscription;
    subscription = response.listen(
      (chunk) {
        builder.add(chunk);
        if (builder.length > maxBytes) {
          completer.completeError(
            AppError(
              AppErrorKind.epgDecode,
              'EPG 响应超过大小上限（${maxBytes ~/ (1024 * 1024)} MiB）',
              detail: redactUrl(uri.toString()),
            ),
          );
          subscription.cancel();
        }
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete();
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!completer.isCompleted) completer.completeError(error, stackTrace);
      },
      cancelOnError: true,
    );
    await completer.future;
    return builder.takeBytes();
  }
}