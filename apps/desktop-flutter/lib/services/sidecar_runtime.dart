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
import '../core/request_cancellation.dart';
import 'log_service.dart';
import 'spider_process.dart';
import 'spider_proxy_session.dart';
import 'spider_registry.dart';
import 'spider_router.dart';

/// 本地 sidecar 支持的站点运行时。
class SidecarRuntime implements SiteRuntime, CancellableSearchRuntime {
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
  ///
  /// 这份缓存**不是真源**：空闲回收或崩溃后宿主会消失，因此每次使用前都要向
  /// [SpiderHostSupervisor] 核对它是否仍然存活；否则调用会发给一个已退出的进程。
  SpiderHost? _host;
  SpiderProxySession? _proxySession;
  static final _hostContexts = Expando<SidecarRuntime>();
  static final _hostStarts = Expando<Map<String, Future<void>>>();

  Future<SpiderProxySession?> prepareProxySession(
    Object context, {
    bool Function()? isCurrent,
  }) async {
    final host = await _ensureHost();
    final owner = await SpiderProxySession.open(
      host: host,
      supervisor: supervisor,
      context: context,
      siteKey: site.key,
      isCurrent: isCurrent,
    );
    _proxySession = owner;
    return owner;
  }

  Future<T> withProxySession<T>(
    SpiderProxySession? owner,
    Future<T> Function() action,
  ) => runZoned(action, zoneValues: {this: owner});

  /// 每次调用递增，用于生成不重复的 requestId（§9.3.1）。
  static int _sequence = 0;

  /// 在途调用：requestId → 主机，供取消。
  final Map<String, SpiderHost> _inflight = {};

  String _nextRequestId() => '${site.key}-runtime-${++_sequence}';

  /// 确保运行时已启动并完成 `initialize` 握手。
  Future<SpiderHost> _ensureHost() {
    if (spider.manifest.runtime != 'jvm' ||
        !spider.manifest.permissions.localProxy) {
      return _ensureHostNow();
    }
    final starts = _hostStarts[supervisor] ??= {};
    final previous = starts[site.key] ?? Future<void>.value();
    final result = previous.then((_) => _ensureHostNow());
    starts[site.key] = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<SpiderHost> _ensureHostNow() async {
    var live = supervisor.hostFor(site.key);
    if (live != null &&
        live.proxyHttp != null &&
        !identical(_hostContexts[live], this)) {
      await supervisor.stop(site.key);
      live = null;
    }
    if (live != null && identical(live, _host)) return live;
    _host = null;
    if (live != null) {
      _host = live;
      _hostContexts[live] = this;
      return live;
    }
    _host = await supervisor.ensureRunning(
      siteKey: site.key,
      executable: command.executable,
      arguments: command.arguments,
      manifest: spider.manifest,
      extend: _extendFor(site),
    );
    _hostContexts[_host!] = this;
    return _host!;
  }

  /// `extend` 传递站点 `ext`（对象按稳定 JSON 文本传递，§7.4.5）。
  ///
  /// **字符串一律原样透传，严禁归一化成对象**：订阅里大量 py 站点的 `ext` 是
  /// Base64 字符串，由站源自己解码（如 `Atvp.py` 先 base64 解码、随后立刻
  /// `.get("t4_play_type")`）。把它归一化成对象，这些站点会直接毁在
  /// `AttributeError: 'NoneType' object has no attribute 'get'`。
  static String _extendFor(Site site) {
    final ext = site.ext;
    if (ext == null) return '';
    if (ext is String) return ext;
    return jsonEncode(ext);
  }

  Future<SiteResult> _invoke(
    String method,
    Map<String, Object?> params, {
    VodIdentityHint? identity,
    RequestCancellation? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    final starting = _ensureHost();
    final host = await (cancellation == null
        ? starting
        : cancellation.bind(starting));
    cancellation?.throwIfCancelled();
    final requestId = _nextRequestId();
    _inflight[requestId] = host;
    var waiting = true;
    try {
      final operation = host.call(method, params: params, requestId: requestId);
      cancellation?.whenCancelled.then((_) {
        if (waiting && host.abandon(requestId)) {
          log?.info(
            '搜索已停止等待并发送取消通知 site=${site.key} id=$requestId；宿主仍运行，底层工作不保证终止',
            scope: 'spider',
          );
        }
      });
      final result = await (cancellation == null
          ? operation
          : cancellation.bind(operation));
      cancellation?.throwIfCancelled();
      return _toSiteResult(result, method: method, identity: identity);
    } on SpiderError catch (error) {
      log?.warning(
        'sidecar 调用失败 site=${site.key} method=$method ${error.logLine}',
        scope: 'spider',
      );
      throw error.toAppError(detail: '方法=$method site=${site.key}');
    } finally {
      waiting = false;
      _inflight.remove(requestId);
    }
  }

  /// 把 sidecar 返回的 Result 归一化为宿主模型（§8.3）。
  SiteResult _toSiteResult(
    Object? value, {
    required String method,
    VodIdentityHint? identity,
  }) {
    if (value is! Map) {
      throw AppError(
        AppErrorKind.siteParse,
        'sidecar 返回的 $method 结果不是对象',
        detail: '实际类型=${value.runtimeType} site=${site.key}',
      );
    }
    // 复用 HTTP API 的字段解释，保证两条链路语义一致。
    return HttpApiResponseParser.parse(
      jsonEncode(value),
      siteKey: site.key,
      identity: identity,
    );
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
    await _proxySession?.close();
    _proxySession = null;
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
  Future<SiteResult> detail(
    Site site,
    String vodId, {
    VodIdentityHint? identity,
  }) => _invoke(SpiderMethod.detail, {'id': vodId}, identity: identity);

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
  Future<SiteResult> searchCancellable(
    Site site, {
    required String keyword,
    int page = 1,
    bool quick = false,
    required RequestCancellation cancellation,
  }) => _invoke(SpiderMethod.search, {
    'keyword': keyword,
    'page': page,
    'quick': quick,
  }, cancellation: cancellation);

  @override
  Future<SiteResult> play(
    Site site, {
    required String episodeTarget,
    String? flag,
    String? vodId,
  }) async {
    final bound = Zone.current[this] as SpiderProxySession?;
    final owner = bound ?? await prepareProxySession(this);
    final params = <String, Object?>{'id': episodeTarget, 'flag': flag ?? ''};
    if (owner == null) return _invoke(SpiderMethod.play, params);
    try {
      return await owner.run((host) async {
        final requestId = _nextRequestId();
        _inflight[requestId] = host;
        try {
          final raw = await host.call(
            SpiderMethod.play,
            params: params,
            requestId: requestId,
          );
          return _toSiteResult(
            _scopeProxyUrls(raw, owner),
            method: SpiderMethod.play,
          );
        } finally {
          _inflight.remove(requestId);
        }
      });
    } catch (_) {
      await owner.close();
      rethrow;
    }
  }

  static Object? _scopeProxyUrls(Object? value, SpiderProxySession owner) {
    if (value is String) return owner.scopeUrl(value);
    if (value is List) {
      return [for (final item in value) _scopeProxyUrls(item, owner)];
    }
    if (value is Map) {
      return {
        for (final entry in value.entries)
          entry.key: _scopeProxyUrls(entry.value, owner),
      };
    }
    return value;
  }
}

/// 把 `webhtv-cat-http-v1` 接到站点运行时接口（§8.1、§9.4）。
class CatHttpSiteRuntime implements SiteRuntime, CancellableSearchRuntime {
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
    String? playId,
    String? keyword,
    Map<String, String> filters = const {},
    String? flag,
    VodIdentityHint? identity,
    RequestCancellation? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
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
      playId: playId,
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
      return await client.call(
        call,
        siteKey: site.key,
        identity: identity,
        cancellation: cancellation,
      );
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
  Future<SiteResult> detail(
    Site site,
    String vodId, {
    VodIdentityHint? identity,
  }) => _call(site, CatHttpRoute.detail, vodId: vodId, identity: identity);

  @override
  Future<SiteResult> search(
    Site site, {
    required String keyword,
    int page = 1,
    bool quick = false,
  }) => _call(site, CatHttpRoute.search, keyword: keyword, page: page);

  @override
  Future<SiteResult> searchCancellable(
    Site site, {
    required String keyword,
    int page = 1,
    bool quick = false,
    required RequestCancellation cancellation,
  }) => _call(
    site,
    CatHttpRoute.search,
    keyword: keyword,
    page: page,
    cancellation: cancellation,
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
    // §9.4：猫源 `/play` 的 `id` 是剧集目标串（`episodeTarget`），与
    // `SidecarRuntime` 及 CatPawOpen bundle 的 `/play` 契约一致。传纯 `vod_id`
    // 会让 jinpai/muou/huban 等子站返回空 `url`（实测缺陷，见 docs）。
    playId: episodeTarget,
    flag: flag,
  );
}
