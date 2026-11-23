/// 配置导入：URL / 本地文件 / 纯 JSON 文本（§7.3、§7.4.1、§7.4.2）。
///
/// 关键约束：
/// - 只允许 `http(s)`、本地文件或纯 JSON 文本；禁止降级到 `file://`、`ftp://` 等；
/// - HTTP 3xx 最多跟随 5 次，且每次跳转都必须仍是 http(s)；
/// - 响应大小上限默认 8 MiB，超限拒绝并保留原配置；
/// - 支持 gzip / br / UTF-8 BOM / 明确声明的 GBK、GB18030；
/// - URL 内容在明文 JSON 无法解析时，兜底识别「前缀**Base64」或纯 Base64；
/// - 解析失败或 `msg` 非空时不得覆盖最后一个可用配置（由调用方保证）；
/// - `urls` 仓库按条目展开，默认第一项，失败回退（§7.4.2）；
/// - **增量刷新**：带上上一轮的 `ETag`/`Last-Modified` 发条件请求，服务端
///   答 `304` 时按「没变」返回（[FetchedConfigText.notModified]），调用方
///   连下载带解析一起省掉；没有校验值可用的来源由调用方按内容摘要比对。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

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

/// 条件请求的校验值：上一轮响应给的 `ETag` / `Last-Modified`。
///
/// 两者都空 = 没有可用校验值（首次刷新、或服务端没给头），此时只能整份拉取
/// 再按 [configContentDigest] 判断内容有没有变。
class ConfigValidators {
  const ConfigValidators({this.etag = '', this.lastModified = ''});

  final String etag;
  final String lastModified;
}

/// 配置内容的稳定摘要（增量刷新用）。
///
/// 为什么是摘要而不是逐字节比较：解析后的配置是一棵 Map，同一份来源内容每次
/// 解析出的文本一致，摘要因此稳定；存进数据库只有一列，比留整份原文便宜。
String configContentDigest(Object? json) =>
    sha256.convert(utf8.encode(jsonEncode(json))).toString();

/// 抓取结果。
class FetchedConfigText {
  const FetchedConfigText({
    required this.text,
    required this.origin,
    required this.contentType,
    this.contentEncoding = 'identity',
    this.notModified = false,
    this.etag = '',
    this.lastModified = '',
  });

  final String text;

  /// 最终来源 URL 或文件路径，用于记录 config record 与错误定位。
  final String origin;
  final String? contentType;
  final String contentEncoding;

  /// 服务端回了 `304 Not Modified`：内容与上一次完全相同，[text] 为空。
  final bool notModified;

  /// 本轮的 `ETag` / `Last-Modified`，下一轮原样带回做条件请求。
  ///
  /// 304 响应也必须记住：有的服务端只在 200 上给 `ETag`，那时沿用上一轮的。
  final String etag;
  final String lastModified;
}

/// 配置加载器。
class ConfigLoader {
  ConfigLoader({
    HttpClient? httpClient,
    this.maxBytes = 8 * 1024 * 1024,
    this.maxRedirects = 5,
    this.timeout = const Duration(seconds: 20),
  }) : _client = httpClient ??
           (HttpClient()..userAgent = configUserAgent) {
    _client.autoUncompress = false;
    _client.connectionTimeout = timeout;
  }

  /// 配置下载使用的 UA。
  ///
  /// 为什么不用应用 UA（`WebHTV-PC/0.1`）：TVBox 生态里大量站点**按 UA 分流**
  /// ——常规 / 浏览器 UA 收到 HTTP 200 的落地页或广告页，只有 okhttp UA 才给真
  /// 配置 JSON。此时导入会以「JSON 解析失败」收场，而不是任何网络错误，用户看到
  /// 的就是「这个接口导不进来」。
  /// 取值与实测依据见 `docs/reference/win-box-borrowings.md` §4.3（`UA_OKHTTP`，
  /// 原文注明「不要臆造其它 UA」）；安卓端 `Decoder.getJson` 走
  /// `OkHttp.newCall`，发出的同样是 okhttp 系 UA。
  ///
  /// 只作用于本类自建的客户端：调用方注入 [httpClient] 时保留其原有 UA。
  static const String configUserAgent = 'okhttp/3.12.0';

  /// 配置响应大小上限，默认 8 MiB（§7.4.1）。
  final int maxBytes;
  final int maxRedirects;
  final Duration timeout;
  final HttpClient _client;

  void close() => _client.close(force: true);

  /// 读取来源文本并解包 URL 混淆内容；不做配置结构校验。
  ///
  /// [validators] 非空时按 HTTP 条件请求发送：服务端答 304 就直接结束，
  /// 连响应体都不读。本地文件与内联 JSON 没有条件请求语义，[validators] 被忽略。
  Future<FetchedConfigText> fetch(
    ConfigSource source, {
    ConfigValidators? validators,
  }) async {
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
        return _fetchUrl(source.value, validators: validators);
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

  Future<FetchedConfigText> _fetchUrl(
    String url, {
    ConfigValidators? validators,
  }) async {
    var current = Uri.parse(url);
    final visited = <String>{current.toString()};

    for (var hop = 0; hop <= maxRedirects; hop++) {
      final response = await _once(current, validators: validators);
      final status = response.statusCode;
      final etag = response.headers.value(HttpHeaders.etagHeader) ?? '';
      final lastModified =
          response.headers.value(HttpHeaders.lastModifiedHeader) ?? '';

      // 304 也落在 3xx 区间，但它**没有 Location**：必须排在跳转分支前面，
      // 否则「内容没变」会被报成「重定向缺少 Location 头」。
      if (status == HttpStatus.notModified) {
        await response.drain<void>();
        return FetchedConfigText(
          text: '',
          origin: current.toString(),
          contentType: null,
          notModified: true,
          etag: etag.isEmpty ? (validators?.etag ?? '') : etag,
          lastModified: lastModified.isEmpty
              ? (validators?.lastModified ?? '')
              : lastModified,
        );
      }

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
        text: _decodeUrlConfigContent(text),
        origin: current.toString(),
        contentType: contentType,
        contentEncoding: decoded.encoding,
        etag: etag,
        lastModified: lastModified,
      );
    }

    throw AppError(
      AppErrorKind.configRedirect,
      '配置重定向超过 $maxRedirects 次',
      detail: redactUrl(url),
    );
  }

  Future<HttpClientResponse> _once(
    Uri uri, {
    ConfigValidators? validators,
  }) async {
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
      if (validators != null) {
        if (validators.etag.isNotEmpty) {
          request.headers.set(HttpHeaders.ifNoneMatchHeader, validators.etag);
        }
        if (validators.lastModified.isNotEmpty) {
          request.headers.set(
            HttpHeaders.ifModifiedSinceHeader,
            validators.lastModified,
          );
        }
      }
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

/// 只解包一层，且明文与候选内容都以 JSON 语法为准；结构与凭据仍由解析器校验。
String _decodeUrlConfigContent(String text) {
  try {
    jsonDecode(text);
    return text;
  } on FormatException {
    // 不把合法 JSON 中的 ** 或 Base64 字段误当作包裹。
  }

  final separator = text.lastIndexOf('**');
  final payload = (separator < 0 ? text : text.substring(separator + 2))
      .trim()
      .replaceAll(RegExp(r'\s+'), '');
  if (!RegExp(r'^[A-Za-z0-9+/_-]+={0,2}$').hasMatch(payload)) {
    return text;
  }
  try {
    var decoded = utf8.decode(base64.decode(base64.normalize(payload)));
    if (decoded.startsWith('\ufeff')) {
      decoded = decoded.substring(1);
    }
    jsonDecode(decoded);
    return decoded;
  } on FormatException {
    return text;
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
    this.notModified = false,
    this.etag = '',
    this.lastModified = '',
  });

  final String origin;
  final ConfigDocument document;
  final DateTime fetchedAt;
  final String? contentType;
  final String contentEncoding;

  /// 条件请求命中 304：来源没变，[document] 为空且**不得**用于覆盖本地内容。
  final bool notModified;

  /// 下一轮条件请求要带回去的校验值（见 [ConfigValidators]）。
  final String etag;
  final String lastModified;

  /// 猫源本机运行时地址（`http://127.0.0.1:port`）；非猫源导入为 null。
  final String? catRuntimeOrigin;

  AppConfig? get config => document.config;
  List<ConfigRepositoryEntry> get repositoryEntries =>
      document.repositoryEntries;
  List<String> get diagnostics => document.diagnostics;

  /// 导入成功后才由状态层接收的瞬时订阅凭据。
  String get tmdbApiKeyCandidate => document.tmdbApiKeyCandidate;
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

  /// 猫源解析钩子（§9 猫源 bundle）。未注入（本机没有 Node）时猫源地址在
  /// 解析前就报 [AppErrorKind.configCatRuntimeMissing]，而不是把 32 字节 md5
  /// 当配置去解析、再把「不是有效 JSON」摆在用户面前。
  final CatConfigResolver? catResolver;

  void close() => _loader.close();

  /// 导入一个来源。
  ///
  /// 返回的 [ImportedConfig] 若 `isRepository` 为真，调用方应让用户选择条目，
  /// 或直接使用 [ImportedConfig.repositoryEntries] 的第一项作为默认（§7.4.2）。
  ///
  /// 猫源 bundle 地址（`.../index.js.md5`、`.../index.js`）先经 [catResolver] 在本机
  /// 跑起 bundle 并读 `/config`，再进同一套解析路径；`origin` 保留**原始猫源地址**，
  /// 以便重启后按同一地址重新拉起 bundle。非猫源地址不碰 Node。
  ///
  /// [validators] 只对 HTTP 来源生效（本地文件没有条件请求语义）：命中 304 时返回
  /// `notModified = true` 的空结果，调用方据此跳过解析与写库。
  Future<ImportedConfig> import(
    ConfigSource source, {
    ConfigValidators? validators,
  }) async {
    if (CatSource.isBundle(source.value)) {
      // 猫源分支是唯一需要 Node 的路径：只有这里才拦「没有运行时」。
      final resolver = catResolver;
      if (resolver == null) {
        throw AppError(
          AppErrorKind.configCatRuntimeMissing,
          '未检测到随包 Node 运行时，无法导入猫源',
          detail: '该地址是猫源 JS bundle（index.js / index.js.md5）；普通 JSON / T4 '
              '配置无需 Node。发行包自带 Node，缺失说明安装不完整：请重新下载/重新'
              '解压完整发行包（应含 runtime\\node\\node.exe），或用环境变量 '
              'WEBHTV_NODE_RUNTIME 指定 node.exe 的绝对路径后重启应用',
        );
      }
      final resolved = await resolver(source.value);
      if (resolved == null) {
        // 运行时在，但没拿到配置：这是猫源自身的问题，不是「缺 Node」。
        throw AppError(
          AppErrorKind.configInvalid,
          '猫源 bundle 未返回配置',
          detail: redactUrl(source.value),
          retryable: true,
        );
      }
      final document = parseConfigDocument(resolved.configJson);
      return ImportedConfig(
        origin: source.value,
        document: document,
        fetchedAt: DateTime.now(),
        contentType: 'application/json',
        catRuntimeOrigin: resolved.origin,
      );
    }
    final fetched = await _loader.fetch(source, validators: validators);
    if (fetched.notModified) {
      // 304：内容与上一轮一致。绝不能拿空文本去解析（那是「配置非法」）。
      return ImportedConfig(
        origin: fetched.origin,
        document: const ConfigDocument(),
        fetchedAt: DateTime.now(),
        notModified: true,
        etag: fetched.etag,
        lastModified: fetched.lastModified,
      );
    }
    final document = parseConfigDocument(fetched.text);
    return ImportedConfig(
      origin: fetched.origin,
      document: document,
      fetchedAt: DateTime.now(),
      contentType: fetched.contentType,
      contentEncoding: fetched.contentEncoding,
      etag: fetched.etag,
      lastModified: fetched.lastModified,
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
