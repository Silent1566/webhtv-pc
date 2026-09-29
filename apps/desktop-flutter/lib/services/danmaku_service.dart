/// 弹幕加载服务（设计文档 §21 Phase 3「字幕/弹幕可开启和关闭」）。
///
/// 职责边界：
/// - 按 [DanmakuSource] 拉取弹幕文件（HTTP/本地），解码后交给
///   [parseDanmakuContent] 解析；
/// - 复用 [decodeTextAndCharset] 的编码探测（BOM → 声明 charset → UTF-8 → GBK
///   兜底）：弹幕文件来自第三方站点，GBK 样本很常见，必须与配置/字幕同一套规则；
/// - 失败一律归一化为 [AppError]（`danmaku*` 分类），**调用方不得让它升级为
///   播放失败**：弹幕拿不到只提示，视频照常播（§10.4 同语义）；
/// - 网络请求由宿主发出并携带与媒体一致的 Header（Referer/UA/Cookie），
///   避免弹幕与视频同源却因缺 Header 被 403；
/// - 简单内存缓存：同一地址在 TTL 内复用（同一集重播不重复拉取）。
///
/// **不支持**：`ws`/`wss` 直播弹幕需要 WebSocket 会话与增量渲染，
/// 本阶段明确报 [AppErrorKind.danmakuUnsupported]，不静默成功。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../core/app_error.dart';
import '../core/danmaku.dart';
import '../core/protocol.dart';
import '../core/text_codec.dart';

/// 已解码的弹幕文档。
class DanmakuDocument {
  const DanmakuDocument({
    required this.items,
    required this.format,
    required this.encoding,
    required this.sourceUrl,
    required this.byteLength,
    required this.skipped,
  });

  final List<DanmakuItem> items;

  /// 识别出的格式：`xml` 或 `text`。
  final String format;

  /// 实际使用的字符集（`utf-8`、`gbk`…）。
  final String encoding;

  final String sourceUrl;
  final int byteLength;

  /// 被丢弃的条目数（非法行/不支持的弹幕类型）。
  final int skipped;

  String get logLine =>
      'format=$format items=${items.length} skipped=$skipped '
      'encoding=$encoding bytes=$byteLength url=${redactUrl(sourceUrl)}';
}

/// 弹幕加载器（便于测试注入替身）。
abstract class DanmakuLoader {
  Future<DanmakuDocument> load(
    DanmakuSource source, {
    Map<String, String> headers = const {},
    bool useCache = true,
  });

  /// 清空内存缓存（换集/换源时可选调用）。
  void invalidate([String? url]) {}
}

/// 默认实现：HTTP/本地文件读取 + 编码兜底 + 解析 + 内存缓存。
class DanmakuService implements DanmakuLoader {
  DanmakuService({
    HttpClient? httpClient,
    this.maxBytes = maxDanmakuBytes,
    this.timeout = const Duration(seconds: 15),
    this.cacheTtl = const Duration(minutes: 10),
    this.userAgent = 'WebHTV-PC/0.1 (Windows)',
    this.maxRedirects = 3,
  }) : _client = httpClient ?? HttpClient() {
    _client.autoUncompress = true;
    _client.connectionTimeout = timeout;
  }

  /// 单份弹幕大小上限。
  final int maxBytes;
  final Duration timeout;
  final Duration cacheTtl;
  final String userAgent;
  final int maxRedirects;
  final HttpClient _client;

  final Map<String, _CacheEntry> _cache = {};

  void close() => _client.close(force: true);

  @override
  void invalidate([String? url]) {
    if (url == null) {
      _cache.clear();
    } else {
      _cache.remove(url);
    }
  }

  @override
  Future<DanmakuDocument> load(
    DanmakuSource source, {
    Map<String, String> headers = const {},
    bool useCache = true,
  }) async {
    final url = source.url.trim();
    if (url.isEmpty) {
      throw AppError(
        AppErrorKind.danmakuUnsupported,
        '弹幕源「${source.displayName}」未配置地址',
        detail: 'name=${source.name}',
      );
    }

    final kind = source.classify();
    if (kind == DanmakuSourceKind.live) {
      // 直播弹幕需要 WebSocket 会话，本阶段不做；明确报错而不是给空弹幕。
      throw AppError(
        AppErrorKind.danmakuUnsupported,
        '直播弹幕（${Uri.tryParse(url)?.scheme ?? "ws"}）本阶段尚未支持',
        detail: redactUrl(url),
      );
    }
    if (kind == DanmakuSourceKind.unsupported) {
      throw AppError(
        AppErrorKind.danmakuUnsupported,
        '弹幕地址协议不受支持',
        detail: redactUrl(url),
      );
    }

    if (useCache) {
      final cached = _cache[url];
      if (cached != null && !cached.isExpired(cacheTtl)) {
        return cached.document;
      }
    }

    final raw = await _read(url, headers);
    if (raw.text.trim().isEmpty) {
      throw AppError(
        AppErrorKind.danmakuEmpty,
        '弹幕内容为空',
        detail: redactUrl(url),
      );
    }

    final DanmakuParseResult parsed;
    try {
      parsed = parseDanmakuContent(raw.text);
    } on DanmakuFormatException catch (error) {
      throw AppError(
        AppErrorKind.danmakuInvalid,
        '弹幕内容非法：${error.message}',
        detail: redactUrl(url),
        cause: error,
      );
    }

    if (parsed.items.isEmpty) {
      // 能识别格式但一条可用弹幕都没有：按空处理并保留丢弃计数供诊断。
      throw AppError(
        AppErrorKind.danmakuEmpty,
        '弹幕文件没有可用条目（丢弃 ${parsed.skipped} 条）',
        detail: redactUrl(url),
      );
    }

    final document = DanmakuDocument(
      items: parsed.items,
      format: parsed.format,
      encoding: raw.charset,
      sourceUrl: url,
      byteLength: raw.byteLength,
      skipped: parsed.skipped,
    );
    _cache[url] = _CacheEntry(document: document, storedAt: DateTime.now());
    return document;
  }

  Future<_RawDanmaku> _read(String url, Map<String, String> headers) async {
    // Windows 盘符路径（`C:\...`）不是 URI，必须先于 `Uri.parse` 判定。
    if (RegExp(r'^[A-Za-z]:[\\/]').hasMatch(url)) {
      return _readFile(url);
    }
    if (url.toLowerCase().startsWith('file://')) {
      final fileUri = Uri.tryParse(url);
      if (fileUri == null) {
        throw AppError(
          AppErrorKind.danmakuUnsupported,
          '弹幕地址非法',
          detail: redactUrl(url),
        );
      }
      return _readFile(fileUri.toFilePath());
    }

    final uri = Uri.tryParse(url);
    if (uri == null) {
      throw AppError(
        AppErrorKind.danmakuUnsupported,
        '弹幕地址非法',
        detail: redactUrl(url),
      );
    }
    final scheme = uri.scheme.toLowerCase();
    if (scheme == 'http' || scheme == 'https') return _fetch(uri, headers);
    if (scheme.isEmpty) return _readFile(url);
    throw AppError(
      AppErrorKind.danmakuUnsupported,
      '弹幕地址协议不受支持：$scheme',
      detail: redactUrl(url),
    );
  }

  Future<_RawDanmaku> _readFile(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw AppError(
        AppErrorKind.danmakuNetwork,
        '弹幕文件不存在或无法读取',
        detail: path,
      );
    }
    final bytes = await file.readAsBytes();
    if (bytes.length > maxBytes) {
      throw AppError(
        AppErrorKind.danmakuTooLarge,
        '弹幕文件超过大小上限（${maxBytes ~/ (1024 * 1024)} MiB）',
        detail: '${bytes.length} bytes',
      );
    }
    return _decode(bytes, null);
  }

  Future<_RawDanmaku> _fetch(Uri uri, Map<String, String> headers) async {
    var current = uri;
    for (var redirect = 0; redirect <= maxRedirects; redirect++) {
      final response = await _request(current, headers);
      final status = response.statusCode;
      if (status >= 300 && status < 400) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        await response.drain<void>();
        final next = location == null ? null : current.resolve(location);
        if (next == null ||
            !(next.isScheme('http') || next.isScheme('https'))) {
          throw AppError(
            AppErrorKind.danmakuHttp,
            '弹幕重定向目标非法',
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
          AppErrorKind.danmakuHttp,
          '弹幕下载返回 HTTP $status',
          detail: redactUrl(current.toString()),
          statusCode: status,
          retryable: status >= 500,
        );
      }

      final declaredLength = response.headers.contentLength;
      if (declaredLength > maxBytes) {
        await response.drain<void>();
        throw AppError(
          AppErrorKind.danmakuTooLarge,
          '弹幕响应超过大小上限（${maxBytes ~/ (1024 * 1024)} MiB）',
          detail: redactUrl(current.toString()),
        );
      }

      final bytes = await _readBounded(response, current);
      final decoded = decodeTransportBody(
        bytes,
        contentEncoding: response.headers.value(
          HttpHeaders.contentEncodingHeader,
        ),
      );
      return _decode(
        decoded.bytes,
        charsetFromContentType(
          response.headers.value(HttpHeaders.contentTypeHeader),
        ),
      );
    }
    throw AppError(
      AppErrorKind.danmakuHttp,
      '弹幕重定向超过 $maxRedirects 次',
      detail: redactUrl(uri.toString()),
    );
  }

  /// 字节 → 文本，复用配置导入的编码探测并换成弹幕语义的错误分类。
  _RawDanmaku _decode(List<int> bytes, String? declaredCharset) {
    if (bytes.isEmpty) {
      throw AppError(AppErrorKind.danmakuEmpty, '弹幕内容为空');
    }
    try {
      final decoded = decodeTextAndCharset(
        bytes,
        declaredCharset: declaredCharset,
      );
      return _RawDanmaku(
        text: decoded.text,
        charset: decoded.charset,
        byteLength: bytes.length,
      );
    } on AppError catch (error) {
      throw AppError(
        AppErrorKind.danmakuDecode,
        '弹幕解码失败：${error.message}',
        cause: error,
      );
    }
  }

  Future<HttpClientResponse> _request(
    Uri uri,
    Map<String, String> headers,
  ) async {
    try {
      final request = await _client.getUrl(uri).timeout(timeout);
      request.headers.set(HttpHeaders.acceptHeader, '*/*');
      if (!headers.keys.any((key) => key.toLowerCase() == 'user-agent')) {
        request.headers.set(HttpHeaders.userAgentHeader, userAgent);
      }
      // 与媒体请求一致的 Header：弹幕常与视频同源，需要同样的 Referer/UA/Cookie。
      for (final entry in headers.entries) {
        try {
          request.headers.set(entry.key, entry.value);
        } catch (_) {
          // 个别受限头由 HttpClient 自行管理，忽略。
        }
      }
      // 自己处理 3xx：便于按状态/大小分类报错。
      request.followRedirects = false;
      return await request.close().timeout(timeout);
    } on TimeoutException catch (error) {
      throw AppError(
        AppErrorKind.danmakuNetwork,
        '弹幕下载超时（${timeout.inSeconds}s）',
        detail: redactUrl(uri.toString()),
        retryable: true,
        cause: error,
      );
    } on HandshakeException catch (error) {
      throw AppError(
        AppErrorKind.danmakuNetwork,
        '弹幕下载 TLS 握手失败',
        detail: redactUrl(uri.toString()),
        cause: error,
      );
    } on SocketException catch (error) {
      throw AppError(
        AppErrorKind.danmakuNetwork,
        '弹幕下载失败：DNS 解析或连接失败',
        detail: '${redactUrl(uri.toString())} '
            '(${error.osError?.message ?? error.message})',
        retryable: true,
        cause: error,
      );
    } on HttpException catch (error) {
      throw AppError(
        AppErrorKind.danmakuNetwork,
        '弹幕下载失败：HTTP 层异常',
        detail: redactUrl(uri.toString()),
        cause: error,
      );
    }
  }

  Future<List<int>> _readBounded(
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
              AppErrorKind.danmakuTooLarge,
              '弹幕响应超过大小上限（${maxBytes ~/ (1024 * 1024)} MiB）',
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

class _RawDanmaku {
  const _RawDanmaku({
    required this.text,
    required this.charset,
    required this.byteLength,
  });

  final String text;
  final String charset;
  final int byteLength;
}

class _CacheEntry {
  const _CacheEntry({required this.document, required this.storedAt});

  final DanmakuDocument document;
  final DateTime storedAt;

  bool isExpired(Duration ttl) =>
      DateTime.now().difference(storedAt) > ttl;
}

/// 弹幕相关错误分类（§10.4 同语义）。
const Set<AppErrorKind> danmakuErrorKinds = {
  AppErrorKind.danmakuNetwork,
  AppErrorKind.danmakuHttp,
  AppErrorKind.danmakuTooLarge,
  AppErrorKind.danmakuDecode,
  AppErrorKind.danmakuInvalid,
  AppErrorKind.danmakuEmpty,
  AppErrorKind.danmakuUnsupported,
};

/// 判断一个错误是否为弹幕错误（用于「弹幕失败不阻断播放」的隔离判定）。
bool isDanmakuError(Object? error) =>
    error is AppError && danmakuErrorKinds.contains(error.kind);

/// 弹幕失败的用户提示文案：必须显式说明“不影响播放”。
String describeDanmakuFailure(Object? error) {
  if (error is AppError) {
    return '弹幕加载失败：${describeErrorKind(error.kind)}';
  }
  return '弹幕加载失败：${error ?? "未知错误"}（不影响视频播放）';
}
