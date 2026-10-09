/// `webhtv-cat-http-v1` 客户端（兼容标签 `tvbox-http-v1`，设计文档 §9.3、§9.4）。
///
/// 该 ABI 是 WebHTV 当前 `CatSpider` 可验证的 HTTP 子集，**不代表**通用或官方
/// TVBox ABI。所有请求使用 `POST` + `Content-Type: application/json; charset=utf-8`。
///
/// 兼容规则（逐条对应设计文档 §9.4）：
/// - `api` 以 `/` 结尾时先归一化，再追加具体路由；
/// - HTTP 状态非 2xx → `SPIDER_HTTP_ERROR`，不返回空字符串冒充成功；
/// - `{code:0,data}` 解包 `data`；`data` 为数组时包装为 `{list:[...]}`；
/// - `{code:非0,msg}` → 业务错误；
/// - `page` 空值或非法值按 1 处理，但记录诊断；
/// - 404/501 或明确的业务错误 → `SPIDER_UNSUPPORTED`，**不转成空列表**。
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'http_api.dart';
import 'ipc_protocol.dart';
import 'protocol.dart';

/// CatSpider HTTP 路由（§9.4）。
abstract final class CatHttpRoute {
  static const String init = '/init';
  static const String home = '/home';
  static const String category = '/category';
  static const String detail = '/detail';
  static const String search = '/search';
  static const String play = '/play';

  static const List<String> all = [
    init,
    home,
    category,
    detail,
    search,
    play,
  ];
}

/// 一次请求的描述，便于契约测试断言路由与请求体（§19.3）。
class CatHttpCall {
  const CatHttpCall({
    required this.route,
    required this.uri,
    required this.body,
    required this.headers,
  });

  final String route;
  final Uri uri;
  final Map<String, Object?> body;
  final Map<String, String> headers;

  String get summary =>
      'POST ${redactUrl(uri.toString())} route=$route keys=${body.keys.toList()..sort()}';
}

/// 请求构造器：归一化 `api`、装配路由与请求体（§9.4）。
class CatHttpRequestBuilder {
  const CatHttpRequestBuilder({
    required this.api,
    this.globalHeaders = const [],
    this.userAgent = HttpApiRequestBuilder.defaultUserAgent,
    this.pageFallback = 1,
  });

  final String api;
  final List<HeaderRule> globalHeaders;
  final String userAgent;

  /// `page` 空值或非法值时的兜底页码（§9.4）。
  final int pageFallback;

  /// 诊断：本次构造中 `page` 被兜底修正。
  static const String pageDiagnostic = 'page 缺失或非法，已按 1 处理';

  /// 归一化基础地址：去掉末尾 `/`，并校验 scheme。
  static Uri normalize(String api) {
    final trimmed = api.trim();
    if (trimmed.isEmpty) {
      throw SpiderError(
        code: SpiderErrorCode.badRequest,
        message: '站点未配置 cat http api',
        userVisible: true,
      );
    }
    final uri = Uri.tryParse(trimmed);
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      throw SpiderError(
        code: SpiderErrorCode.badRequest,
        message: 'cat http api 不是有效的 http(s) 地址',
        details: {'api': redactUrl(trimmed)},
        userVisible: true,
      );
    }
    return uri;
  }

  /// 归一化后的路由地址。
  Uri endpoint(String route) {
    final base = normalize(api);
    final path = base.path.endsWith('/')
        ? base.path.substring(0, base.path.length - 1)
        : base.path;
    return base.replace(path: '$path$route');
  }

  Map<String, String> headersFor(Uri endpoint) {
    final merged = HeaderMap.merge([
      globalHeadersFor(globalHeaders, endpoint.host),
    ]);
    if (!merged.containsKey('Content-Type')) {
      merged.put('Content-Type', 'application/json; charset=utf-8');
    }
    if (!merged.containsKey('User-Agent')) {
      merged.put('User-Agent', userAgent);
    }
    // 猫源站点 `api` 带 `user:pass@host` 凭据时，`package:http` 不会解码 userinfo 的
    // 百分号编码（密码里的 `%3A` 被字面发出 → 401）。解码后显式注入 Basic 头，
    // 请求 URI 则由 [build] 去掉 userinfo。
    if (!merged.containsKey('Authorization')) {
      final auth = basicAuthHeader(endpoint);
      if (auth != null) merged.put('Authorization', auth);
    }
    return merged.asRequestHeaders;
  }

  /// `page` 归一化（§9.4）。
  static (int, bool) normalizePage(Object? value) {
    final parsed = asInt(value);
    if (parsed == null || parsed < 1) return (1, true);
    return (parsed, false);
  }

  CatHttpCall build(
    String route, {
    String? typeId,
    Object? page,
    String? vodId,
    String? playId,
    String? keyword,
    Map<String, String> filters = const {},
    String? flag,
  }) {
    final endpoint = this.endpoint(route);
    final body = <String, Object?>{};
    switch (route) {
      case CatHttpRoute.init:
        break;
      case CatHttpRoute.home:
        break;
      case CatHttpRoute.category:
        body['id'] = typeId ?? '';
        final (pageValue, _) = normalizePage(page);
        body['page'] = pageValue;
        body['filters'] = filters;
        break;
      case CatHttpRoute.detail:
        body['id'] = vodId ?? '';
        break;
      case CatHttpRoute.search:
        body['wd'] = keyword ?? '';
        final (pageValue, _) = normalizePage(page);
        body['page'] = pageValue;
        break;
      case CatHttpRoute.play:
        // §9.4：`/play` 的 `id` 是**剧集目标串**（`vod_play_url` 里该集的值，
        // 猫源形如 URL 编码 JSON `%7B%22vodId%22...%7D`），不是纯 `vod_id`。
        // 实测：把数字 `vod_id` 当 `id` 传给 jinpai/muou/huban 等猫源子站会返回
        // 空 `url`，而传剧集目标串能拿到真实 m3u8。故优先用 [playId]。
        body['flag'] = flag ?? '';
        body['id'] = playId ?? vodId ?? '';
        break;
      default:
        throw SpiderError(
          code: SpiderErrorCode.badRequest,
          message: '未知的 cat http 路由：$route',
        );
    }
    return CatHttpCall(
      route: route,
      // 凭据已由 headersFor 注入 Authorization 头；URI 里不带 userinfo，
      // 避免 package:http 再发一次错误编码的凭据。
      uri: uriWithoutUserInfo(endpoint),
      body: body,
      headers: headersFor(endpoint),
    );
  }
}

/// 客户端：执行请求并把响应归一化为 [SiteResult]（§9.4）。
class CatHttpClient {
  CatHttpClient({
    http.Client? client,
    this.timeout = siteRequestTimeout,
    this.userAgent = HttpApiRequestBuilder.defaultUserAgent,
    this.maxResponseBytes = 8 * 1024 * 1024,
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final Duration timeout;
  final String userAgent;
  final int maxResponseBytes;

  /// 诊断信息：本次客户端生命周期内发生的兼容性修正（例如 page 兜底）。
  final List<String> diagnostics = [];

  void close() => _client.close();

  /// 按 `api` 与动作发起请求。
  Future<SiteResult> call(
    CatHttpCall call, {
    required String siteKey,
  }) async {
    final http.Response response;
    try {
      response = await _client
          .post(
            call.uri,
            headers: call.headers,
            body: jsonEncode(call.body),
          )
          .timeout(timeout);
    } on TimeoutException {
      throw SpiderError(
        code: SpiderErrorCode.timeout,
        message: 'cat http 请求超时（${timeout.inSeconds}s）',
        siteKey: siteKey,
        requestId: call.route,
      );
    } catch (error) {
      throw SpiderError(
        code: SpiderErrorCode.httpError,
        message: 'cat http 请求失败：${error.runtimeType}',
        siteKey: siteKey,
        details: {'route': call.route},
      );
    }

    if (response.bodyBytes.length > maxResponseBytes) {
      throw SpiderError(
        code: SpiderErrorCode.resourceLimit,
        message: 'cat http 响应超过大小上限',
        siteKey: siteKey,
        details: {
          'bytes': response.bodyBytes.length,
          'limit': maxResponseBytes,
        },
      );
    }

    // §9.4：404/501 表示该路由未实现，必须映射为 SPIDER_UNSUPPORTED。
    if (response.statusCode == 404 || response.statusCode == 501) {
      throw SpiderError(
        code: SpiderErrorCode.unsupported,
        message: 'cat http 路由未实现（HTTP ${response.statusCode}）',
        siteKey: siteKey,
        details: {'route': call.route, 'status': response.statusCode},
        userVisible: true,
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw SpiderError(
        code: SpiderErrorCode.httpError,
        message: 'cat http 上游返回 HTTP ${response.statusCode}',
        siteKey: siteKey,
        retryable: response.statusCode >= 500,
        details: {'route': call.route, 'status': response.statusCode},
      );
    }

    final text = utf8.decode(response.bodyBytes, allowMalformed: true);
    return decode(text, siteKey: siteKey, route: call.route);
  }

  /// 解析响应信封（§9.4）。
  SiteResult decode(
    String body, {
    required String siteKey,
    required String route,
  }) {
    final trimmed = body.trim();
    if (trimmed.isEmpty) {
      throw SpiderError(
        code: SpiderErrorCode.parseError,
        message: 'cat http 响应为空',
        siteKey: siteKey,
        details: {'route': route},
      );
    }
    Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } catch (error) {
      throw SpiderError(
        code: SpiderErrorCode.parseError,
        message: 'cat http 响应不是合法 JSON',
        siteKey: siteKey,
        details: {
          'route': route,
          'hint': trimmed.length > 60 ? trimmed.substring(0, 60) : trimmed,
        },
      );
    }

    if (decoded is List) {
      // §9.4：`data` 为数组时包装为 `{list: [...]}`；顶层数组同理。
      return _toResult({'list': decoded}, siteKey: siteKey, route: route);
    }
    if (decoded is! Map) {
      throw SpiderError(
        code: SpiderErrorCode.parseError,
        message: 'cat http 响应既不是对象也不是数组',
        siteKey: siteKey,
        details: {'route': route},
      );
    }

    final map = asMap(decoded);
    if (map.containsKey('code')) {
      final code = asInt(map['code']) ?? -1;
      final message = asNonEmptyString(map['msg']) ??
          asNonEmptyString(map['message']);
      if (code != 0) {
        // §9.4：明确的业务错误 → 业务错误，不得空列表化。
        throw SpiderError(
          code: SpiderErrorCode.parseError,
          message: message ?? 'cat http 业务错误 code=$code',
          siteKey: siteKey,
          userVisible: true,
          details: {'route': route, 'code': code},
        );
      }
      final data = map['data'];
      if (data is List) {
        return _toResult({'list': data}, siteKey: siteKey, route: route);
      }
      if (data is Map) {
        return _toResult(asMap(data), siteKey: siteKey, route: route);
      }
      if (data == null) {
        return const SiteResult();
      }
    }

    final message = asNonEmptyString(map['msg']);
    final hasList = map.containsKey('list');
    final hasClass = map.containsKey('class');
    if (message != null && !hasList && !hasClass && !map.containsKey('url')) {
      throw SpiderError(
        code: SpiderErrorCode.parseError,
        message: message,
        siteKey: siteKey,
        userVisible: true,
        details: {'route': route},
      );
    }
    return _toResult(map, siteKey: siteKey, route: route);
  }

  SiteResult _toResult(
    Map<String, Object?> map, {
    required String siteKey,
    required String route,
  }) {
    // 复用 HTTP API 的 Result 解析语义，保证两条链路的字段解释一致（§8.3）。
    return HttpApiResponseParser.parse(jsonEncode(map), siteKey: siteKey);
  }
}

/// 便捷门面：把一个站点 `api` 当作 cat http 端点使用。
class CatHttpRuntime {
  CatHttpRuntime({
    required this.client,
    this.globalHeaders = const [],
  });

  final CatHttpClient client;
  final List<HeaderRule> globalHeaders;

  CatHttpRequestBuilder builderFor(Site site) => CatHttpRequestBuilder(
    api: site.api,
    globalHeaders: globalHeaders,
  );

  /// 判断站点是否属于 CatSpider HTTP（§9.4）。
  ///
  /// 判定与 `SpiderRouter` 保持一致：文件扩展名与 `csp_` 是比路径片段更强的
  /// 信号，`.../spider/a.js` 必须判为独立运行时，而不是 CatSpider HTTP（§8.1）。
  static bool looksLikeCatHttp(Site site) {
    final api = site.api.trim().toLowerCase();
    if (api.isEmpty) return false;
    if (hasStrongNonCatHttpSignal(api)) return false;
    return api.contains('/spider/') ||
        api.endsWith('/spider') ||
        api.contains('catspider');
  }

  /// 更强于 `/spider/` 片段的前缀信号：显式脚本或 Android 形态。
  ///
  /// 这些形态属于 Phase 3 的独立运行时，禁止被 `/spider/` 片段误判为 cat http。
  static bool hasStrongNonCatHttpSignal(String api) {
    final lowered = api.trim().toLowerCase();
    return lowered.endsWith('.js') ||
        lowered.contains('.js?') ||
        lowered.endsWith('.py') ||
        lowered.contains('.py?') ||
        lowered.contains('csp_');
  }

  /// 可选：探测站点是否真的实现该 ABI（非 2xx/404 视为不支持）。
  ///
  /// 探测失败不写任何状态，只返回结论与原因，避免把「探测失败」误当作「站点失败」。
  Future<CatHttpProbe> probe(Site site) async {
    final builder = builderFor(site);
    try {
      final call = builder.build(CatHttpRoute.init);
      await client.call(call, siteKey: site.key);
      return const CatHttpProbe(supported: true, reason: 'init 成功');
    } on SpiderError catch (error) {
      if (error.code == SpiderErrorCode.unsupported) {
        return CatHttpProbe(supported: false, reason: error.message);
      }
      // init 不是必需路由：业务错误/解析错误不否定 ABI 支持，但需要记录。
      return CatHttpProbe(
        supported: true,
        reason: 'init 返回 ${error.code}，按可选路由处理',
      );
    } catch (error) {
      return CatHttpProbe(supported: false, reason: '$error');
    }
  }
}

/// 探测结论。
class CatHttpProbe {
  const CatHttpProbe({required this.supported, required this.reason});

  final bool supported;
  final String reason;
}
