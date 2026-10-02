/// 配置导入：URL / 本地文件 / 纯 JSON 文本（§7.3、§7.4.1、§7.4.2）。
///
/// 关键约束：
/// - 只允许 `http(s)`、本地文件或纯 JSON 文本；禁止降级到 `file://`、`ftp://` 等；
/// - HTTP 3xx 最多跟随 5 次，且每次跳转都必须仍是 http(s)；
/// - 响应大小上限默认 8 MiB，超限拒绝并保留原配置；
/// - 支持 gzip / br / UTF-8 BOM / 明确声明的 GBK、GB18030；
/// - 解析失败或 `msg` 非空时不得覆盖最后一个可用配置（由调用方保证）；
/// - `urls` 仓库按条目展开，默认第一项，失败回退（§7.4.2）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'app_error.dart';
import 'cat_source.dart';
import 'config_parser.dart';
import 'protocol.dart';
import 'text_codec.dart';

/// 导入来源。
enum ConfigSourceKind { url, file, inlineJson }

/// 已解析的导入来源。
class ConfigSource {
  const ConfigSource({required this.kind, required this.value, this.label});

  final ConfigSourceKind kind;
  final String value;
  final String? label;

  String get displayName {
    switch (kind) {
      case ConfigSourceKind.url:
        return label ?? redactUrl(value);
      case ConfigSourceKind.file:
        return label ?? value.split(RegExp(r'[\\/]')).last;
      case ConfigSourceKind.inlineJson:
        return label ?? '粘贴的 JSON 文本';
    }
  }

  static ConfigSource parse(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) {
      throw AppError(AppErrorKind.configInvalid, '配置输入为空');
    }
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      return ConfigSource(kind: ConfigSourceKind.inlineJson, value: trimmed);
    }
    final uri = Uri.tryParse(trimmed);
    final scheme = uri?.scheme.toLowerCase() ?? '';
    if (scheme == 'http' || scheme == 'https') {
      return ConfigSource(kind: ConfigSourceKind.url, value: trimmed);
    }
    if (scheme == 'file') {
      // file:// 只作为用户显式粘贴的绝对路径支持，绝不作为 HTTP 跳转目标。
      return ConfigSource(
        kind: ConfigSourceKind.file,
        value: uri!.toFilePath(windows: Platform.isWindows),
      );
    }
    if (scheme.isNotEmpty && scheme.length > 1) {
      throw AppError(
        AppErrorKind.configSchemeUnsupported,
        '不支持的配置地址协议：$scheme',
        detail: '仅允许 http、https、本地文件路径或 JSON 文本',
      );
    }
    return ConfigSource(kind: ConfigSourceKind.file, value: trimmed);
  }
}

/// 抓取结果。
class FetchedConfigText {
  const FetchedConfigText({
    required this.text,
    required this.origin,
    required this.contentType,
    this.contentEncoding = 'identity',
  });

  final String text;

  /// 最终来源 URL 或文件路径，用于记录 config record 与错误定位。
  final String origin;
  final String? contentType;
  final String contentEncoding;
}

/// 配置加载器。
class ConfigLoader {
  ConfigLoader({
    HttpClient? httpClient,
    this.maxBytes = 8 * 1024 * 1024,
    this.maxRedirects = 5,
    this.timeout = const Duration(seconds: 20),
  }) : _client = httpClient ?? HttpClient() {
    _client.autoUncompress = false;
    _client.connectionTimeout = timeout;
  }

  /// 配置响应大小上限，默认 8 MiB（§7.4.1）。
  final int maxBytes;
  final int maxRedirects;
  final Duration timeout;
  final HttpClient _client;

  void close() => _client.close(force: true);

  /// 读取来源文本。不做解析，便于“抓取”和“解析”分别测试。
  Future<FetchedConfigText> fetch(ConfigSource source) async {
    switch (source.kind) {
      case ConfigSourceKind.inlineJson:
        return FetchedConfigText(
          text: source.value,
          origin: 'inline://json',
          contentType: 'application/json',
        );
      case ConfigSourceKind.file:
        return _readFile(source.value);
      case ConfigSourceKind.url:
        return _fetchUrl(source.value);
    }
  }

  Future<FetchedConfigText> _readFile(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw AppError(
        AppErrorKind.configNotFound,
        '配置文件不存在',
        detail: path,
      );
    }
    final bytes = await file.readAsBytes();
    if (bytes.length > maxBytes) {
      throw AppError(
        AppErrorKind.configTooLarge,
        '配置文件超过大小上限（${maxBytes ~/ (1024 * 1024)} MiB）',
        detail: '${bytes.length} bytes',
      );
    }
    // 本地文件不做传输解压，但允许 .gz 后缀的 gzip 内容。
    final decoded = path.toLowerCase().endsWith('.gz')
        ? decodeTransportBody(bytes, contentEncoding: 'gzip')
        : DecodedBody(bytes: bytes, encoding: 'identity');
    return FetchedConfigText(
      text: decodeConfigText(decoded.bytes),
      origin: file.absolute.path,
      contentType: null,
      contentEncoding: decoded.encoding,
    );
  }

  Future<FetchedConfigText> _fetchUrl(String url) async {
    var current = Uri.parse(url);
    final visited = <String>{current.toString()};

    for (var hop = 0; hop <= maxRedirects; hop++) {
      final response = await _once(current);
      final status = response.statusCode;

      if (status >= 300 && status < 400) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        if (location == null || location.isEmpty) {
          await response.drain<void>();
          throw AppError(
            AppErrorKind.configHttp,
            '配置重定向缺少 Location 头',
            detail: 'status=$status ${redactUrl(current.toString())}',
            statusCode: status,
          );
        }
        final next = current.resolve(location);
        final scheme = next.scheme.toLowerCase();
        if (scheme != 'http' && scheme != 'https') {
          await response.drain<void>();
          throw AppError(
            AppErrorKind.configSchemeUnsupported,
            '配置重定向到不支持的协议：$scheme',
            detail: redactUrl(next.toString()),
          );
        }
        if (!visited.add(next.toString())) {
          await response.drain<void>();
          throw AppError(
            AppErrorKind.configRedirect,
            '配置重定向出现循环',
            detail: redactUrl(next.toString()),
          );
        }
        if (hop == maxRedirects) {
          await response.drain<void>();
          throw AppError(
            AppErrorKind.configRedirect,
            '配置重定向超过 $maxRedirects 次',
            detail: redactUrl(next.toString()),
          );
        }
        current = next;
        await response.drain<void>();
        continue;
      }

      if (status < 200 || status >= 300) {
        await response.drain<void>();
        throw AppError(
          AppErrorKind.configHttp,
          '配置下载返回 HTTP $status',
          detail: redactUrl(current.toString()),
          statusCode: status,
        );
      }

      final declaredLength =
          response.headers.contentLength;
      if (declaredLength > maxBytes) {
        await response.drain<void>();
        throw AppError(
          AppErrorKind.configTooLarge,
          '配置响应声明长度超过上限（${maxBytes ~/ (1024 * 1024)} MiB）',
          detail: 'Content-Length=$declaredLength',
        );
      }

      final bytes = await _readBounded(response, current);
      final contentEncoding = response.headers.value(
        HttpHeaders.contentEncodingHeader,
      );
      final contentType = response.headers.value(HttpHeaders.contentTypeHeader);
      final decoded = decodeTransportBody(
        bytes,
        contentEncoding: contentEncoding,
      );
      final text = decodeConfigText(
        decoded.bytes,
        declaredCharset: charsetFromContentType(contentType),
      );
      return FetchedConfigText(
        text: text,
        origin: current.toString(),
        contentType: contentType,
        contentEncoding: decoded.encoding,
      );
    }

    throw AppError(
      AppErrorKind.configRedirect,
      '配置重定向超过 $maxRedirects 次',
      detail: redactUrl(url),
    );
  }

  Future<HttpClientResponse> _once(Uri uri) async {
    try {
      // `HttpClient` 不会解码 URI userinfo 的百分号编码（如密码里的 `%3A`），
      // 而大量订阅地址带 `user:pass@host` 凭据；这里解码后显式设 Authorization 头，
      // 并把 URI 里的 userinfo 去掉，与 `CatBundle` 的出站请求同一套规则。
      final auth = basicAuthHeader(uri);
      final target = uriWithoutUserInfo(uri);
      final request = await _client.getUrl(target).timeout(timeout);
      if (auth != null) {
        request.headers.set(HttpHeaders.authorizationHeader, auth);
      }
      request.headers.set(HttpHeaders.acceptHeader, '*/*');
      // 必须自己处理 3xx：否则 dart:io 会用默认上限自动跟随，既无法按设计
      // 文档报告 `configRedirect`，也无法校验“禁止降级到 file:// 等非 HTTP(S)
      // 方案”。`autoUncompress=false` 也只对不自动跳转的请求可控。
      request.followRedirects = false;
      final response = await request.close().timeout(timeout);
      return response;
    } on TimeoutException catch (error) {
      throw AppError(
        AppErrorKind.configNetwork,
        '配置下载超时（${timeout.inSeconds}s）',
        detail: redactUrl(uri.toString()),
        retryable: true,
        cause: error,
      );
    } on HandshakeException catch (error) {
      throw AppError(
        AppErrorKind.configNetwork,
        '配置下载 TLS 握手失败',
        detail: redactUrl(uri.toString()),
        retryable: true,
        cause: error,
      );
    } on SocketException catch (error) {
      throw AppError(
        AppErrorKind.configNetwork,
        '配置下载失败：DNS 解析或连接失败',
        detail: '${redactUrl(uri.toString())} (${error.osError?.message ?? error.message})',
        retryable: true,
        cause: error,
      );
    } on HttpException catch (error) {
      throw AppError(
        AppErrorKind.configNetwork,
        '配置下载失败：HTTP 层异常',
        detail: redactUrl(uri.toString()),
        retryable: true,
        cause: error,
      );
    }
  }

  /// 读取响应体并强制大小上限，避免超限响应把内存占满。
  ///
  /// 超限时必须主动取消订阅而不是 `drain`：流已被监听后再次 drain 会抛
  /// `Stream has already been listened to`。
  Future<List<int>> _readBounded(HttpClientResponse response, Uri uri) async {
    final builder = BytesBuilder(copy: false);
    final completer = Completer<void>();
    late StreamSubscription<List<int>> subscription;
    subscription = response.listen(
      (chunk) {
        builder.add(chunk);
        if (builder.length > maxBytes) {
          completer.completeError(
            AppError(
              AppErrorKind.configTooLarge,
              '配置响应超过大小上限（${maxBytes ~/ (1024 * 1024)} MiB）',
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
        if (!completer.isCompleted) {
          completer.completeError(error, stackTrace);
        }
      },
      cancelOnError: true,
    );
    await completer.future;
    return builder.takeBytes();
  }
}

/// 导入结果：一份单配置，或一个需要用户选择的配置仓库。
class ImportedConfig {
  const ImportedConfig({
    required this.origin,
    required this.document,
    required this.fetchedAt,
    this.contentType,
    this.contentEncoding = 'identity',
    this.catRuntimeOrigin,
  });

  final String origin;
  final ConfigDocument document;
  final DateTime fetchedAt;
  final String? contentType;
  final String contentEncoding;

  /// 猫源本机运行时地址（`http://127.0.0.1:port`）；非猫源导入为 null。
  final String? catRuntimeOrigin;

  AppConfig? get config => document.config;
  List<ConfigRepositoryEntry> get repositoryEntries =>
      document.repositoryEntries;
  List<String> get diagnostics => document.diagnostics;
  bool get isRepository => document.isRepository;

  /// 站点与直播数量摘要（§7.5 “记录配置名称、URL、更新时间、站点数、直播数”）。
  int get siteCount => document.config?.sites.length ?? 0;
  int get liveCount =>
      document.config?.lives.length ?? document.repositoryEntries.length;
}

/// 猫源 bundle 解析结果：已归一化的标准 TVBox 配置文本 + 展示用来源。
///
/// 由 services 层（`CatImportPipeline`）产出，core 层不依赖进程管理，
/// 因此这里只描述数据。
class ResolvedCatConfig {
  const ResolvedCatConfig({required this.configJson, required this.origin});

  /// 已归一化的标准 TVBox 配置 JSON 文本（顶层带 `sites`），可直接 `parseConfigDocument`。
  final String configJson;

  /// 展示/日志用来源（本机 `/config` 地址）。
  final String origin;
}

/// 猫源 bundle 解析钩子：把 `.../index.js.md5` 一类地址变成可解析的配置文本。
///
/// 返回 `null` 表示该地址不是猫源 bundle（回退常规配置抓取）。
typedef CatConfigResolver =
    Future<ResolvedCatConfig?> Function(
      String url, {
      void Function(String message)? onProgress,
    });

/// 配置导入服务：抓取 + 解析，并在仓库形态下展开默认条目。
class ConfigImportService {
  ConfigImportService({ConfigLoader? loader, this.catResolver})
    : _loader = loader ?? ConfigLoader();

  final ConfigLoader _loader;

  /// 猫源解析钩子（§9 猫源 bundle）。未注入时猫源地址走常规抓取，会因 32 字节
  /// md5 不是 JSON 而明确报错，而不是静默失败。
  final CatConfigResolver? catResolver;

  void close() => _loader.close();

  /// 导入一个来源。
  ///
  /// 返回的 [ImportedConfig] 若 `isRepository` 为真，调用方应让用户选择条目，
  /// 或直接使用 [ImportedConfig.repositoryEntries] 的第一项作为默认（§7.4.2）。
  ///
  /// 猫源 bundle 地址（`.../index.js.md5`、`.../index.js`）先经 [_catResolver] 在本机
  /// 跑起 bundle 并读 `/config`，再进同一套解析路径；`origin` 保留**原始猫源地址**，
  /// 以便重启后按同一地址重新拉起 bundle。
  Future<ImportedConfig> import(ConfigSource source) async {
    final resolver = catResolver;
    if (resolver != null && CatSource.isBundle(source.value)) {
      final resolved = await resolver(source.value);
      if (resolved != null) {
        final document = parseConfigDocument(resolved.configJson);
        return ImportedConfig(
          origin: source.value,
          document: document,
          fetchedAt: DateTime.now(),
          contentType: 'application/json',
          catRuntimeOrigin: resolved.origin,
        );
      }
    }
    final fetched = await _loader.fetch(source);
    final document = parseConfigDocument(fetched.text);
    return ImportedConfig(
      origin: fetched.origin,
      document: document,
      fetchedAt: DateTime.now(),
      contentType: fetched.contentType,
      contentEncoding: fetched.contentEncoding,
    );
  }

  /// 展开配置仓库的指定条目。
  ///
  /// `index` 越界时回退到第一项；展开失败时抛出错误，**不覆盖**调用方已有配置
  /// （由 [ConfigService] 保证）。
  Future<ImportedConfig> expandRepository(
    ImportedConfig repository, {
    int index = 0,
  }) async {
    final entries = repository.repositoryEntries;
    if (entries.isEmpty) {
      throw AppError(
        AppErrorKind.configRepository,
        '配置仓库没有可用条目',
        detail: repository.origin,
      );
    }
    final safeIndex = (index >= 0 && index < entries.length) ? index : 0;
    final entry = entries[safeIndex];
    final source = ConfigSource.parse(entry.url);
    if (source.kind != ConfigSourceKind.url) {
      throw AppError(
        AppErrorKind.configSchemeUnsupported,
        '配置仓库条目必须是 http(s) 地址',
        detail: '${entry.name ?? ""} ${redactUrl(entry.url)}',
      );
    }
    final ImportedConfig expanded;
    try {
      expanded = await import(source);
    } on AppError catch (error) {
      // 保留原始错误码（404 仍是 configHttp、内容非法仍是 configInvalid），
      // 但补上“哪个仓库条目失败”，否则用户无法定位是哪个条目。
      throw AppError(
        error.kind,
        error.message,
        detail: [
          '条目=${entry.name ?? ""} ${redactUrl(entry.url)}',
          if (error.detail != null && error.detail!.isNotEmpty) error.detail,
        ].join(' | '),
        retryable: error.retryable,
        statusCode: error.statusCode,
        cause: error,
      );
    }
    if (expanded.isRepository) {
      throw AppError(
        AppErrorKind.configRepository,
        '配置仓库条目的内容仍是仓库，已停止递归展开',
        detail: entry.name ?? redactUrl(entry.url),
      );
    }
    if (expanded.config?.sites.isEmpty ?? true) {
      throw AppError(
        AppErrorKind.configRepository,
        '配置仓库条目没有可用站点',
        detail: entry.name ?? redactUrl(entry.url),
      );
    }
    return expanded;
  }
}

/// 供 UI 展示的导入错误分类（§7.5）。
bool isImportRecoverable(AppError error) => error.retryable;

/// 便于测试与诊断：把导入结果转成稳定的单行摘要。
String summarizeImportedConfig(ImportedConfig imported) {
  final config = imported.config;
  return jsonEncode({
    'origin': redactUrl(imported.origin),
    'repository': imported.isRepository,
    'entries': imported.repositoryEntries.length,
    'sites': config?.sites.length ?? 0,
    'lives': config?.lives.length ?? 0,
    'parses': config?.parses.length ?? 0,
    'headersRules': config?.headers.length ?? 0,
    'diagnostics': imported.diagnostics.length,
    'contentEncoding': imported.contentEncoding,
  });
}
