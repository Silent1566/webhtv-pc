/// 解析器运行时服务（设计文档 §12「解析器设计」、§7.4.8）。
///
/// 网络执行层：按 [ParseKind] 构造请求并归一化结果，对齐 Android `ParseJob`。
/// 网络层使用 `package:http`（与 http_api.dart 一致），避免 dart:io 二进制 API
/// 的签名分叉。
///
/// | type | 请求形态（对齐 Android） | 响应解析 |
/// |---|---|---|
/// | 1 (json) | `GET 解析器url + 目标url`，带解析器 Header | `{url}` 或
///   `{data:{url}}`（可能附带 UA/Referer/Cookie header，§8.4 Header 注入） |
/// | 2 (jsonExtend) | POST 表单，携带全部 type=1 解析器 `extUrl()` 为查找表 | 完整
///   `Result`（`url`/`header`/`subs`…，§8.3） |
/// | 3 (jsonMix) | POST 表单，携带 flag 与全部解析器 `name->{type,ext,url}` | 完整
///   `Result` |
///
/// 超时、大小上限、编码兜底、错误归一化在这里完成；**解析失败不影响直接换源**
/// （§12.3：由调用方捕获错误后回退）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:fast_gbk/fast_gbk.dart';
import 'package:http/http.dart' as http;

import '../core/app_error.dart';
import '../core/http_api.dart';
import '../core/parse_runtime.dart';
import '../core/protocol.dart';

/// 解析器执行结果。
class ParseRunResult {
  const ParseRunResult({
    required this.url,
    required this.headers,
    required this.parseKind,
    required this.source,
    required this.entryName,
    this.format,
    this.subs = const [],
    this.danmaku = const [],
    this.latency = Duration.zero,
  });

  final String url;
  final Map<String, String> headers;

  /// 实际执行的解析器类型。
  final ParseKind parseKind;

  /// 来源标记（`jx` / `parse`），用于诊断与线路标识（对齐 `Result.jxFrom`）。
  final String source;

  final String entryName;
  final String? format;
  final List<SubtitleInfo> subs;
  final List<DanmakuSource> danmaku;
  final Duration latency;
}

/// 解析器错误分类（§12.3 解析失败不影响直接换源）。
const Set<AppErrorKind> parseErrorKinds = {
  AppErrorKind.parseNetwork,
  AppErrorKind.parseHttp,
  AppErrorKind.parseDecode,
  AppErrorKind.parseInvalid,
  AppErrorKind.parseEmpty,
};

/// 判断一个错误是否为解析器错误。
bool isParseError(Object? error) =>
    error is AppError && parseErrorKinds.contains(error.kind);

/// 解析器运行时。
class ParseService {
  ParseService({
    http.Client? client,
    this.maxBytes = 8 * 1024 * 1024,
    this.timeout = const Duration(seconds: 20),
    this.userAgent = 'WebHTV-PC/0.1 (Windows)',
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final int maxBytes;
  final Duration timeout;
  final String userAgent;

  void close() => _client.close();

  /// 执行一次解析。
  ///
  /// [selection] 为 [ParseRuntime.select] 的产物；[webUrl] 为播放结果的
  /// `playUrl`（尚未解析时是剧集目标）；[flag] 为线路标识（type=3 携带）。
  /// [entries] 为配置的**全部**解析器（type=2/3 需要做查找表，对齐 Android
  /// `jsonExt`/`jsonExtMix` 传 `VodConfig.get().getParses()`）。
  Future<ParseRunResult> run({
    required ParseSelection selection,
    required List<ParseEntry> entries,
    required String webUrl,
    String? flag,
    String? source,
  }) async {
    final stopwatch = Stopwatch()..start();
    final url = selection.entry.url?.trim() ?? '';
    if (url.isEmpty) {
      throw AppError(
        AppErrorKind.parseInvalid,
        '解析器 ${selection.entry.name} 未配置 url',
      );
    }

    final ParseRunResult result;
    switch (selection.kind) {
      case ParseKind.json:
        result = await _jsonParse(url, webUrl, selection, stopwatch);
      case ParseKind.jsonExtend:
        result = await _jsonExtend(url, webUrl, entries, selection, stopwatch);
      case ParseKind.jsonMix:
        result = await _jsonMix(url, webUrl, flag, entries, selection, stopwatch);
      case ParseKind.webSniff:
      case ParseKind.superParse:
      case ParseKind.unknown:
        throw AppError(
          AppErrorKind.parseUnsupportedType,
          '解析器 ${selection.entry.name} 类型不支持'
          '（type=${selection.entry.type}；PC 端支持 JSON 类 type=1/2/3）',
        );
    }
    return result;
  }

  /// type=1：`GET 解析器url + 目标url`（对齐 `jsonParse`）。
  Future<ParseRunResult> _jsonParse(
    String parseUrl,
    String webUrl,
    ParseSelection selection,
    Stopwatch stopwatch,
  ) async {
    final target = (parseUrl + webUrl).trim();
    final payload = await _getText(target, selection.entry);
    final decoded = jsonDecodeLoose(payload);
    if (decoded is! Map) {
      throw AppError(
        AppErrorKind.parseInvalid,
        '解析器 ${selection.entry.name} 响应不是 JSON 对象',
        detail: _hint(payload),
      );
    }
    final map = decoded;

    // `url` 或 `data.url`。
    final url = asNonEmptyString(map['url']) ?? _nestedUrl(map['data']);
    if (url == null) {
      throw AppError(
        AppErrorKind.parseEmpty,
        '解析器 ${selection.entry.name} 没有返回可用地址',
        detail: _hint(payload),
      );
    }

    // 响应顶层可能带 UA/Referer/Cookie（对齐 `getHeader`）。
    final headers = _headersFromMap(map, selection.entry);
    return ParseRunResult(
      url: url,
      headers: headers,
      parseKind: ParseKind.json,
      source: 'parse:${selection.entry.name}',
      entryName: selection.entry.name,
      latency: stopwatch.elapsed,
    );
  }

  /// type=2：POST 表单，携带全部 type=1 解析器 `extUrl()`（对齐 `jsonExt`）。
  Future<ParseRunResult> _jsonExtend(
    String parseUrl,
    String webUrl,
    List<ParseEntry> entries,
    ParseSelection selection,
    Stopwatch stopwatch,
  ) async {
    final jxs = <String, String>{};
    for (final entry in entries) {
      if (parseKindOf(entry.type) == ParseKind.json && entry.url != null) {
        jxs[entry.name] = _extUrl(entry);
      }
    }
    final payload = await _postText(parseUrl, selection.entry, jxs, webUrl);
    return _toResult(payload, selection, 'jx:${selection.entry.name}', stopwatch);
  }

  /// type=3：POST 表单，携带 flag 与全部解析器 `name->{type,ext,url}`（对齐
  /// `jsonExtMix`）。
  Future<ParseRunResult> _jsonMix(
    String parseUrl,
    String webUrl,
    String? flag,
    List<ParseEntry> entries,
    ParseSelection selection,
    Stopwatch stopwatch,
  ) async {
    final jxs = <String, Map<String, Object?>>{};
    for (final entry in entries) {
      jxs[entry.name] = {
        'type': '${entry.type}',
        'ext': entry.ext ?? const {},
        'url': entry.url ?? '',
      };
    }
    final payload = await _postText(
      parseUrl,
      selection.entry,
      {'jx': flag ?? '', 'name': selection.entry.name, 'ext': jsonEncode(jxs)},
      webUrl,
    );
    return _toResult(payload, selection, 'jx:${selection.entry.name}', stopwatch);
  }

  /// type=2/3 响应是完整 `Result`（§8.3），复用 [HttpApiResponseParser] 归一化。
  ParseRunResult _toResult(
    String payload,
    ParseSelection selection,
    String source,
    Stopwatch stopwatch,
  ) {
    final result = HttpApiResponseParser.parse(
      payload,
      siteKey: 'parse:${selection.entry.name}',
    );
    final url = result.playUrl;
    if (url == null || url.isEmpty) {
      throw AppError(
        AppErrorKind.parseEmpty,
        '解析器 ${selection.entry.name} 没有返回可用地址',
        detail: _hint(payload),
      );
    }
    return ParseRunResult(
      url: url,
      headers: result.header?.asRequestHeaders ?? const {},
      parseKind: selection.kind,
      source: source,
      entryName: selection.entry.name,
      format: result.format,
      subs: result.subs,
      danmaku: result.danmaku,
      latency: stopwatch.elapsed,
    );
  }

  /// Android `Parse.extUrl()`：url 带 query 时注入 `cat_ext=<base64>`。
  String _extUrl(ParseEntry entry) {
    final url = entry.url?.trim() ?? '';
    final ext = entry.ext;
    if (ext == null) return url;
    final index = url.indexOf('?');
    if (index == -1) return url;
    final encoded = base64UrlEncode(jsonEncode(ext));
    return '${url.substring(0, index + 1)}cat_ext=$encoded&'
        '${url.substring(index + 1)}';
  }

  /// 响应顶层带响应的 UA/Referer/Cookie（对齐 `getHeader`），否则用解析器自身。
  Map<String, String> _headersFromMap(
    Map map,
    ParseEntry fallback,
  ) {
    final result = <String, String>{};
    for (final key in <String>['User-Agent', 'Referer', 'Cookie', 'ua']) {
      final value = asNonEmptyString(map[key]);
      if (value != null) result[key] = value;
    }
    if (result.isNotEmpty) return result;
    return _parseEntryHeaders(fallback);
  }

  Map<String, String> _parseEntryHeaders(ParseEntry entry) {
    final ext = entry.ext;
    if (ext is Map) {
      final header = ext['header'];
      if (header is Map) {
        final result = <String, String>{};
        for (final entry in header.entries) {
          if (entry.value is String) {
            result['${entry.key}'] = entry.value as String;
          }
        }
        return result;
      }
    }
    return const {};
  }

  static String? _nestedUrl(Object? data) {
    if (data is! Map) return null;
    return asNonEmptyString(data['url']);
  }

  String _hint(String payload) {
    final trimmed = payload.trim();
    return trimmed.length > 120
        ? '${trimmed.substring(0, 120)}…'
        : trimmed;
  }

  Future<String> _getText(String url, ParseEntry entry) =>
      _exchange(url, entry, method: 'GET').then((body) => body.text);

  Future<String> _postText(
    String url,
    ParseEntry entry,
    Map<String, Object?> form,
    String webUrl,
  ) =>
      _exchange(
        url,
        entry,
        method: 'POST',
        form: form,
        webUrl: webUrl,
      ).then((body) => body.text);

  Future<_Body> _exchange(
    String url,
    ParseEntry entry, {
    required String method,
    Map<String, Object?>? form,
    String? webUrl,
  }) async {
    final uri = Uri.tryParse(url);
    if (uri == null) {
      throw AppError(AppErrorKind.parseInvalid, '解析器地址非法：$url');
    }
    final headers = _requestHeaders(entry);
    final http.Response response;
    try {
      if (method == 'POST') {
        final body = _formBody(entry, form, webUrl);
        // §12.2：解析器表单必须是 form-urlencoded（对齐 Android
        // `OkHttp.toBody`）；`package:http` 默认 text/plain，会错过解析器解析。
        final formHeaders = {
          ...headers,
          'Content-Type': 'application/x-www-form-urlencoded; charset=utf-8',
        };
        response = await _client
            .post(uri, headers: formHeaders, body: body)
            .timeout(timeout);
      } else {
        response = await _client.get(uri, headers: headers).timeout(timeout);
      }
    } on TimeoutException catch (error) {
      throw AppError(
        AppErrorKind.parseNetwork,
        '解析器请求超时（${timeout.inSeconds}s）',
        detail: redactUrl(uri.toString()),
        retryable: true,
        cause: error,
      );
    } catch (error) {
      throw AppError(
        AppErrorKind.parseNetwork,
        '解析器请求失败：DNS 或连接失败',
        detail: redactUrl(uri.toString()),
        retryable: true,
        cause: error,
      );
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AppError(
        AppErrorKind.parseHttp,
        '解析器请求返回 HTTP ${response.statusCode}',
        detail: redactUrl(uri.toString()),
        statusCode: response.statusCode,
        retryable: response.statusCode >= 500,
      );
    }
    if (response.bodyBytes.length > maxBytes) {
      throw AppError(
        AppErrorKind.parseInvalid,
        '解析响应超过大小上限（${maxBytes ~/ (1024 * 1024)} MiB）',
        detail: redactUrl(uri.toString()),
      );
    }
    return _Body(text: _decodeResponse(response));
  }

  /// 解析器 Header：`ext.header` + 缺 UA 时补默认（对齐 Android
  /// `Parse.Ext.header`）。
  Map<String, String> _requestHeaders(ParseEntry entry) {
    final result = <String, String>{};
    for (final headerEntry in _parseEntryHeaders(entry).entries) {
      result[headerEntry.key] = headerEntry.value;
    }
    if (!result.keys.any((key) => key.toLowerCase() == 'user-agent')) {
      result['User-Agent'] = userAgent;
    }
    return result;
  }

  /// POST 表单体（§7.4.7 同语义：URL 编码键值；webUrl 追加 `url=`）。
  String _formBody(
    ParseEntry entry,
    Map<String, Object?>? form,
    String? webUrl,
  ) {
    final pairs = <String>[];
    for (final item in (form ?? const {}).entries) {
      pairs.add(
        '${Uri.encodeQueryComponent(item.key)}='
            '${Uri.encodeQueryComponent(_formValue(item.value))}',
      );
    }
    if (webUrl != null) {
      pairs.add('url=${Uri.encodeQueryComponent(webUrl)}');
    }
    return pairs.join('&');
  }

  /// 响应解码：声明 charset → UTF-8 → GBK 兜底（与 http_api 同规则）。
  String _decodeResponse(http.Response response) {
    final contentType = response.headers['content-type'];
    final declared = RegExp(
      r'''charset\s*=\s*"?([\w\-]+)"?''',
      caseSensitive: false,
    ).firstMatch(contentType ?? '')?.group(1);
    final bytes = response.bodyBytes;
    if (declared != null) {
      final charset = declared.toLowerCase();
      if (charset.startsWith('gb')) {
        try {
          return gbk.decode(bytes, allowMalformed: false);
        } on FormatException {
          // 落到下方 UTF-8 判定。
        }
      }
    }
    try {
      return utf8.decode(bytes);
    } on FormatException {
      try {
        return gbk.decode(bytes, allowMalformed: true);
      } on FormatException {
        throw AppError(
          AppErrorKind.parseDecode,
          '解析响应无法按 UTF-8 或 GBK 解码',
          detail: 'charset=${declared ?? "未声明"}',
        );
      }
    }
  }

  static String _formValue(Object? value) {
    if (value is String) return value;
    if (value is num) return '$value';
    if (value is bool) return '$value';
    return jsonEncode(value);
  }
}

class _Body {
  const _Body({required this.text});
  final String text;
}

/// 宽松 JSON 解码（顶层数组也接受，返回原结构）。
Object? jsonDecodeLoose(String text) {
  try {
    return jsonDecode(text);
  } catch (_) {
    return null;
  }
}

/// URL-safe base64（对齐 Android `Util.base64(..., URL_SAFE)`）。
String base64UrlEncode(String input) {
  final encoded = base64.encode(utf8.encode(input));
  return encoded
      .replaceAll('+', '-')
      .replaceAll('/', '_')
      .replaceAll('=', '');
}