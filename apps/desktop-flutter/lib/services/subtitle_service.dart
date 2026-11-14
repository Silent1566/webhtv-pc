/// 外挂字幕加载服务（设计文档 §10.3「外挂字幕」「字幕轨选择」）。
///
/// 职责边界：
/// - 按 [SubtitleInfo] 拉取字幕文本（HTTP/本地文件），复用 [decodeConfigText]
///   的编码探测（BOM → 声明 charset → UTF-8 → GBK 兜底）；字幕样本在 TVBox
///   生态里 GBK 极常见，必须与配置导入同一套兜底规则；
/// - 失败一律归一化为 [AppError]（`subtitle*` 分类），但**调用方不得让它升级为
///   播放失败**：字幕拿不到只提示，视频照常播（§10.4、§13.3）；
/// - 网络请求由宿主自己发出并携带与媒体一致的 Header（Referer/UA/Cookie），
///   再把文本交给播放器，避免把 Header 泄漏到播放器的直连请求里（§11.3.1）。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../core/app_error.dart';
import '../core/protocol.dart';
import '../core/subtitle.dart';
import '../core/text_codec.dart';

/// 已解码的字幕文档。
class SubtitleDocument {
  const SubtitleDocument({
    required this.text,
    required this.format,
    required this.encoding,
    required this.sourceUrl,
    required this.byteLength,
  });

  /// 已转为 UTF-8 的文本（GBK 等已在加载阶段转码）。
  final String text;

  /// 归一化格式：`srt`/`ass`/`ssa`/`vtt`/`sub`。
  final String format;

  /// 实际使用的字符集（`utf-8`、`gbk`、`utf-16le`…）。
  final String encoding;

  final String sourceUrl;
  final int byteLength;

  String get logLine =>
      'format=$format encoding=$encoding bytes=$byteLength '
      'url=${redactUrl(sourceUrl)}';
}

/// 字幕加载器（便于测试注入替身）。
abstract class SubtitleLoader {
  Future<SubtitleDocument> load(
    SubtitleInfo sub, {
    Map<String, String> headers = const {},
  });
}

/// 默认实现：直接 HTTP/本地文件读取 + 编码兜底。
class SubtitleService implements SubtitleLoader {
  SubtitleService({
    HttpClient? httpClient,
    this.maxBytes = maxSubtitleBytes,
    this.timeout = const Duration(seconds: 15),
    this.userAgent = 'WebHTV-PC/0.1 (Windows)',
    this.maxRedirects = 3,
  }) : _client = httpClient ?? HttpClient() {
    _client.autoUncompress = true;
    _client.connectionTimeout = timeout;
  }

  final int maxBytes;
  final Duration timeout;
  final String userAgent;
  final int maxRedirects;
  final HttpClient _client;

  void close() => _client.close(force: true);

  @override
  Future<SubtitleDocument> load(
    SubtitleInfo sub, {
    Map<String, String> headers = const {},
  }) async {
    final url = sub.url.trim();
    if (url.isEmpty) {
      throw AppError(
        AppErrorKind.subtitleUnsupported,
        '字幕条目缺少地址',
        detail: 'name=${sub.name}',
      );
    }

    final format = inferSubtitleFormat(url, declared: sub.format);
    if (format.isEmpty) {
      throw AppError(
        AppErrorKind.subtitleUnsupported,
        '字幕格式不受支持',
        detail: '${redactUrl(url)} format=${sub.format}',
      );
    }

    final raw = await _read(url, headers);
    if (raw.bytes.isEmpty) {
      throw AppError(
        AppErrorKind.subtitleEmpty,
        '字幕内容为空',
        detail: redactUrl(url),
      );
    }

    final decoded = _decode(raw.bytes, raw.declaredCharset, url);
    if (decoded.text.trim().isEmpty) {
      throw AppError(
        AppErrorKind.subtitleEmpty,
        '字幕内容为空',
        detail: redactUrl(url),
      );
    }

    return SubtitleDocument(
      text: decoded.text,
      format: format,
      // 独立编码探测：字幕在 TVBox 生态里 GBK 极常见，必须如实记录用了哪个编码。
      encoding: decoded.charset,
      sourceUrl: url,
      byteLength: raw.bytes.length,
    );
  }

  ({String text, String charset}) _decode(
    List<int> bytes,
    String? declaredCharset,
    String url,
  ) {
    try {
      return decodeTextAndCharset(bytes, declaredCharset: declaredCharset);
    } on AppError catch (error) {
      // 复用配置解码的错误分类，但换成字幕语义，便于 UI 区分提示。
      throw AppError(
        AppErrorKind.subtitleDecode,
        '字幕解码失败：${error.message}',
        detail: redactUrl(url),
        cause: error,
      );
    }
  }

  Future<_RawSubtitle> _read(String url, Map<String, String> headers) async {
    // Windows 盘符路径不是 URI，必须先于 `Uri.parse` 判定（盘符会被当成 scheme）。
    if (RegExp(r'^[A-Za-z]:[\\/]').hasMatch(url)) {
      return _readFile(url);
    }
    if (url.toLowerCase().startsWith('file://')) {
      final fileUri = Uri.tryParse(url);
      if (fileUri == null) {
        throw AppError(
          AppErrorKind.subtitleUnsupported,
          '字幕地址非法',
          detail: redactUrl(url),
        );
      }
      return _readFile(fileUri.toFilePath());
    }

    final uri = Uri.tryParse(url);
    if (uri == null) {
      throw AppError(
        AppErrorKind.subtitleUnsupported,
        '字幕地址非法',
        detail: redactUrl(url),
      );
    }
    final scheme = uri.scheme.toLowerCase();
    if (scheme == 'http' || scheme == 'https') {
      return _fetch(uri, headers);
    }
    if (scheme.isEmpty) return _readFile(url);
    throw AppError(
      AppErrorKind.subtitleUnsupported,
      '字幕地址协议不受支持：$scheme',
      detail: redactUrl(url),
    );
  }

  Future<_RawSubtitle> _readFile(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw AppError(
        AppErrorKind.subtitleNetwork,
        '字幕文件不存在或无法读取',
        detail: path,
      );
    }
    final bytes = await file.readAsBytes();
    if (bytes.length > maxBytes) {
      throw AppError(
        AppErrorKind.subtitleTooLarge,
        '字幕文件超过大小上限（${maxBytes ~/ (1024 * 1024)} MiB）',
        detail: '${bytes.length} bytes',
      );
    }
    return _RawSubtitle(bytes: bytes, encoding: 'identity', declaredCharset: null);
  }

  Future<_RawSubtitle> _fetch(
    Uri uri,
    Map<String, String> headers,
  ) async {
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
            AppErrorKind.subtitleHttp,
            '字幕重定向目标非法',
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
          AppErrorKind.subtitleHttp,
          '字幕下载返回 HTTP $status',
          detail: redactUrl(current.toString()),
          statusCode: status,
          retryable: status >= 500,
        );
      }

      final declaredLength = response.headers.contentLength;
      if (declaredLength > maxBytes) {
        await response.drain<void>();
        throw AppError(
          AppErrorKind.subtitleTooLarge,
          '字幕响应超过大小上限（${maxBytes ~/ (1024 * 1024)} MiB）',
          detail: redactUrl(current.toString()),
        );
      }

      final bytes = await _readBounded(response, current);
      final contentEncoding = response.headers.value(
        HttpHeaders.contentEncodingHeader,
      );
      final decoded = decodeTransportBody(
        bytes,
        contentEncoding: contentEncoding,
      );
      return _RawSubtitle(
        bytes: decoded.bytes,
        encoding: decoded.encoding,
        declaredCharset: charsetFromContentType(
          response.headers.value(HttpHeaders.contentTypeHeader),
        ),
      );
    }
    throw AppError(
      AppErrorKind.subtitleHttp,
      '字幕重定向超过 $maxRedirects 次',
      detail: redactUrl(uri.toString()),
    );
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
      // 与媒体请求一致的 Header：字幕常与视频同源，需要同样的 Referer/UA/Cookie。
      for (final entry in headers.entries) {
        try {
          request.headers.set(entry.key, entry.value);
        } catch (_) {
          // 个别受限头（如 content-length）由 HttpClient 自行管理，忽略。
        }
      }
      // 自己处理 3xx：便于按大小/状态分类报错，也让 `subtitleHttp` 可定位。
      request.followRedirects = false;
      return await request.close().timeout(timeout);
    } on TimeoutException catch (error) {
      throw AppError(
        AppErrorKind.subtitleNetwork,
        '字幕下载超时（${timeout.inSeconds}s）',
        detail: redactUrl(uri.toString()),
        retryable: true,
        cause: error,
      );
    } on HandshakeException catch (error) {
      throw AppError(
        AppErrorKind.subtitleNetwork,
        '字幕下载 TLS 握手失败',
        detail: redactUrl(uri.toString()),
        cause: error,
      );
    } on SocketException catch (error) {
      throw AppError(
        AppErrorKind.subtitleNetwork,
        '字幕下载失败：DNS 解析或连接失败',
        detail: '${redactUrl(uri.toString())} '
            '(${error.osError?.message ?? error.message})',
        retryable: true,
        cause: error,
      );
    } on HttpException catch (error) {
      throw AppError(
        AppErrorKind.subtitleNetwork,
        '字幕下载失败：HTTP 层异常',
        detail: redactUrl(uri.toString()),
        cause: error,
      );
    }
  }

  /// 读取响应体并强制大小上限（超限时主动取消订阅，避免内存被占满）。
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
              AppErrorKind.subtitleTooLarge,
              '字幕响应超过大小上限（${maxBytes ~/ (1024 * 1024)} MiB）',
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

class _RawSubtitle {
  const _RawSubtitle({
    required this.bytes,
    required this.encoding,
    required this.declaredCharset,
  });

  final List<int> bytes;
  final String encoding;
  final String? declaredCharset;
}
