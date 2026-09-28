/// sidecar 运行时适配器：把 `webhtv-ipc-v1` sidecar 接到站点运行时接口（§9.2、§9.3）。
///
/// 关键点：
/// - 只有 manifest 声明的 capability 才允许调用，未声明返回 `SPIDER_UNSUPPORTED`（§9.7）；
/// - sidecar 返回的 Result 结构与 HTTP API 一致，复用同一套字段解析（§8.3）；
/// - 所有 `SpiderError` 都映射到宿主 [AppError]，UI 才能给出可定位提示；
/// - 每个站点的调用必须可取消，取消后不投递结果（§9.5）。
library;

import 'dart:async';
import 'dart:convert';

import '../core/app_error.dart';
import '../core/cat_http.dart';
import '../core/http_api.dart';
import '../core/ipc_protocol.dart';
import '../core/protocol.dart';
import 'log_service.dart';
import 'spider_process.dart';
import 'spider_registry.dart';
import 'spider_router.dart';

/// 本地 sidecar 支持的站点运行时。
class SidecarRuntime implements SiteRuntime {
  SidecarRuntime({
    required this.site,
    required this.spider,
    required this.command,
    required this.supervisor,
    this.log,
    this.globalHeaders = const [],
  });

  final Site site;
  final LocalSpider spider;
  final LocalSpiderCommand command;
  final SpiderHostSupervisor supervisor;
  final LogService? log;
  final List<HeaderRule> globalHeaders;

  @override
  String get name => '本地 Spider (${spider.manifest.runtime})';

  /// 正在运行的主机；首次调用时建立。
  SpiderHost? _host;

  /// 每次调用递增，用于生成不重复的 requestId（§9.3.1）。
  int _sequence = 0;

  /// 在途调用：requestId → 主机，供取消。
  final Map<String, SpiderHost> _inflight = {};

  String _nextRequestId() => '${site.key}-${++_sequence}';

  /// 确保运行时已启动并完成 `initialize` 握手。
  Future<SpiderHost> _ensureHost() async {
    final existing = _host ?? supervisor.hostFor(site.key);
    if (existing != null) {
      _host = existing;
      return existing;
    }
    _host = await supervisor.ensureRunning(
      siteKey: site.key,
      executable: command.executable,
      arguments: command.arguments,
      manifest: spider.manifest,
      extend: _extendFor(site),
    );
    return _host!;
  }

  /// `extend` 传递站点 `ext`（对象按稳定 JSON 文本传递，§7.4.5）。
  static String _extendFor(Site site) {
    final ext = site.ext;
    if (ext == null) return '';
    if (ext is String) return ext;
    return jsonEncode(ext);
  }

  Future<SiteResult> _invoke(
    String method,
    Map<String, Object?> params,
  ) async {
    final host = await _ensureHost();
    final requestId = _nextRequestId();
    _inflight[requestId] = host;
    try {
      final result = await host.call(
        method,
        params: params,
        requestId: requestId,
      );
      return _toSiteResult(result, method: method);
    } on SpiderError catch (error) {
      log?.warning(
        'sidecar 调用失败 site=${site.key} method=$method ${error.logLine}',
        scope: 'spider',
      );
      throw error.toAppError(detail: '方法=$method site=${site.key}');
    } finally {
      _inflight.remove(requestId);
    }
  }

  /// 把 sidecar 返回的 Result 归一化为宿主模型（§8.3）。
  SiteResult _toSiteResult(Object? value, {required String method}) {
    if (value is! Map) {
      throw AppError(
        AppErrorKind.siteParse,
        'sidecar 返回的 $method 结果不是对象',
        detail: '实际类型=${value.runtimeType} site=${site.key}',
      );
    }
    // 复用 HTTP API 的字段解释，保证两条链路语义一致。
    return HttpApiResponseParser.parse(jsonEncode(value), siteKey: site.key);
  }

  /// 取消该站点全部在途调用（§9.5「UI 取消后不得再向已取消页面投递结果」）。
  int cancelInflight() {
    var count = 0;
    for (final entry in _inflight.entries.toList()) {
      if (entry.value.cancel(entry.key)) count++;
    }
    return count;
  }

  Future<void> dispose() async {
    cancelInflight();
    _host = null;
    await supervisor.stop(site.key);
  }

  @override
  Future<SiteResult> home(Site site) => _invoke(SpiderMethod.home, const {});

  @override
  Future<SiteResult> category(
    Site site, {
    required String typeId,
    required int page,
    Map<String, String> filters = const {},
  }) => _invoke(SpiderMethod.category, {
    'id': typeId,
    'page': page,
    'filters': filters,
  });

  @override
  Future<SiteResult> detail(Site site, String vodId) =>
      _invoke(SpiderMethod.detail, {'id': vodId});

  @override
  Future<SiteResult> search(
    Site site, {
    required String keyword,
    int page = 1,
    bool quick = false,
  }) => _invoke(SpiderMethod.search, {
    'keyword': keyword,
    'page': page,
    'quick': quick,
  });

  @override
  Future<SiteResult> play(
    Site site, {
    required String episodeTarget,
    String? flag,
    String? vodId,
  }) => _invoke(SpiderMethod.play, {
    'id': episodeTarget,
    'flag': flag ?? '',
  });
}

/// 把 `webhtv-cat-http-v1` 接到站点运行时接口（§8.1、§9.4）。
class CatHttpSiteRuntime implements SiteRuntime {
  CatHttpSiteRuntime({
    required this.client,
    required this.siteKey,
    this.globalHeaders = const [],
    this.userAgent = HttpApiRequestBuilder.defaultUserAgent,
  });

  final CatHttpClient client;
  final String siteKey;
  final List<HeaderRule> globalHeaders;
  final String userAgent;

  @override
  String get name => 'CatSpider HTTP (webhtv-cat-http-v1)';

  Future<SiteResult> _call(
    Site site,
    String route, {
    String? typeId,
    Object? page,
    String? vodId,
    String? keyword,
    Map<String, String> filters = const {},
    String? flag,
  }) async {
    final builder = CatHttpRequestBuilder(
      api: site.api,
      globalHeaders: globalHeaders,
      userAgent: userAgent,
    );
    final call = builder.build(
      route,
      typeId: typeId,
      page: page,
      vodId: vodId,
      keyword: keyword,
      filters: filters,
      flag: flag,
    );
    // `page` 兜底必须在诊断中留痕（§9.4「应记录诊断」）。
    if (page != null) {
      final (_, corrected) = CatHttpRequestBuilder.normalizePage(page);
      if (corrected) {
        client.diagnostics.add(
          '${site.key} $route: ${CatHttpRequestBuilder.pageDiagnostic}',
        );
      }
    }
    try {
      return await client.call(call, siteKey: site.key);
    } on SpiderError catch (error) {
      throw error.toAppError(detail: 'route=$route site=${site.key}');
    }
  }

  @override
  Future<SiteResult> home(Site site) => _call(site, CatHttpRoute.home);

  @override
  Future<SiteResult> category(
    Site site, {
    required String typeId,
    required int page,
    Map<String, String> filters = const {},
  }) => _call(
    site,
    CatHttpRoute.category,
    typeId: typeId,
    page: page,
    filters: filters,
  );

  @override
  Future<SiteResult> detail(Site site, String vodId) =>
      _call(site, CatHttpRoute.detail, vodId: vodId);

  @override
  Future<SiteResult> search(
    Site site, {
    required String keyword,
    int page = 1,
    bool quick = false,
  }) => _call(
    site,
    CatHttpRoute.search,
    keyword: keyword,
    page: page,
  );

  @override
  Future<SiteResult> play(
    Site site, {
    required String episodeTarget,
    String? flag,
    String? vodId,
  }) => _call(
    site,
    CatHttpRoute.play,
    vodId: vodId ?? episodeTarget,
    flag: flag,
  );
}
