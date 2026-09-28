/// Spider 路由：按站点 `type` 与 `api` 形态分发到具体运行时（§8.1、§9.1）。
///
/// 已实现运行时：
/// - HTTP API（`type=0/1/2/4`，MVP-A）；
/// - `webhtv-cat-http-v1` / CatSpider HTTP（MVP-B，§9.4）；
/// - 本地 `webhtv-ipc-v1` sidecar（`api` 形如 `spider-local:<key>`，§9.3、§9.8）。
///
/// 未实现形态（`*.js`、`*.py`、`csp_*`、Android JAR）继续返回结构化不可用结论，
/// UI 显示运行时未安装/未支持，不得显示空列表（§8.1、§9.9）。
library;

import 'dart:async';

import '../core/app_error.dart';
import '../core/cat_http.dart';
import '../core/http_api.dart';
import '../core/protocol.dart';
import 'log_service.dart';
import 'sidecar_runtime.dart';
import 'spider_process.dart';
import 'spider_registry.dart';

/// 站点运行时可用性。
class SiteAvailability {
  const SiteAvailability({
    required this.available,
    required this.runtimeName,
    this.reason,
    this.stage,
  });

  final bool available;
  final String runtimeName;
  final String? reason;

  /// 设计文档中该运行时的所属阶段（`MVP-A`、`MVP-B`、`Phase 3`）。
  final String? stage;
}

/// 统一运行时接口（§9.2 的 Dart 侧最小子集）。
abstract class SiteRuntime {
  String get name;

  Future<SiteResult> home(Site site);

  Future<SiteResult> category(
    Site site, {
    required String typeId,
    required int page,
    Map<String, String> filters,
  });

  Future<SiteResult> detail(Site site, String vodId);

  Future<SiteResult> search(
    Site site, {
    required String keyword,
    int page,
    bool quick,
  });

  /// 从播放入口取回真实地址；直链站点不应调用到这里。
  Future<SiteResult> play(
    Site site, {
    required String episodeTarget,
    String? flag,
    String? vodId,
  });
}

/// 未实现运行时：明确报错，不伪装成功（§8.1、§9.4）。
class UnsupportedRuntime implements SiteRuntime {
  const UnsupportedRuntime({
    required this.runtimeName,
    required this.reason,
    this.stage,
  });

  final String runtimeName;

  final String reason;
  final String? stage;

  @override
  String get name => runtimeName;

  AppError _error(String siteKey, String operation) => AppError(
    AppErrorKind.siteUnsupported,
    '站点运行时「$runtimeName」未安装或未支持',
    detail: '站点=$siteKey 操作=$operation ${stage == null ? "" : "阶段=$stage"} $reason',
  );

  @override
  Future<SiteResult> home(Site site) async => throw _error(site.key, 'home');

  @override
  Future<SiteResult> category(
    Site site, {
    required String typeId,
    required int page,
    Map<String, String> filters = const {},
  }) async => throw _error(site.key, 'category');

  @override
  Future<SiteResult> detail(Site site, String vodId) async =>
      throw _error(site.key, 'detail');

  @override
  Future<SiteResult> search(
    Site site, {
    required String keyword,
    int page = 1,
    bool quick = false,
  }) async => throw _error(site.key, 'search');

  @override
  Future<SiteResult> play(
    Site site, {
    required String episodeTarget,
    String? flag,
    String? vodId,
  }) async => throw _error(site.key, 'play');
}

/// HTTP API 运行时（`type=0/1/2/4`）。
class HttpApiRuntime implements SiteRuntime {
  HttpApiRuntime({
    required this.client,
    required this.globalHeaders,
    this.userAgent = HttpApiRequestBuilder.defaultUserAgent,
  });

  final HttpApiClient client;
  final List<HeaderRule> globalHeaders;
  final String userAgent;

  @override
  String get name => 'HTTP API';

  HttpApiCall _build(
    Site site,
    HttpApiAction action, {
    String? typeId,
    int? page,
    String? vodId,
    String? keyword,
    bool quick = false,
    Map<String, String> filters = const {},
  }) {
    return HttpApiRequestBuilder(
      site: site,
      globalHeaders: globalHeaders,
      userAgent: userAgent,
    ).build(
      action,
      typeId: typeId,
      page: page,
      vodId: vodId,
      keyword: keyword,
      quick: quick,
      filters: filters,
    );
  }

  @override
  Future<SiteResult> home(Site site) {
    final call = _build(site, HttpApiAction.home);
    return client.execute(call, siteKey: site.key);
  }

  @override
  Future<SiteResult> category(
    Site site, {
    required String typeId,
    required int page,
    Map<String, String> filters = const {},
  }) {
    final call = _build(
      site,
      HttpApiAction.category,
      typeId: typeId,
      page: page,
      filters: filters,
    );
    return client.execute(call, siteKey: site.key);
  }

  @override
  Future<SiteResult> detail(Site site, String vodId) {
    final call = _build(site, HttpApiAction.detail, vodId: vodId);
    return client.execute(call, siteKey: site.key);
  }

  @override
  Future<SiteResult> search(
    Site site, {
    required String keyword,
    int page = 1,
    bool quick = false,
  }) async {
    // 站点不支持搜索时必须明确报错，而不是返回空列表（§8.4）。
    // 声明为 async 让错误以 Future 失败的形式暴露，调用方 `await` 即可捕获。
    if (!site.searchable) {
      throw AppError(
        AppErrorKind.siteUnsupported,
        '站点 ${site.name} 未声明 searchable',
        detail: 'key=${site.key}',
      );
    }
    final effectiveQuick = quick && site.quickSearch;
    final call = _build(
      site,
      HttpApiAction.search,
      keyword: keyword,
      page: page,
      quick: effectiveQuick,
    );
    return client.execute(call, siteKey: site.key);
  }

  @override
  Future<SiteResult> play(
    Site site, {
    required String episodeTarget,
    String? flag,
    String? vodId,
  }) {
    final call = HttpApiRequestBuilder(
      site: site,
      globalHeaders: globalHeaders,
      userAgent: userAgent,
    ).buildPlayRequest(episodeTarget);
    return client.execute(call, siteKey: site.key);
  }
}

/// 路由器。
///
/// 分发优先级（§8.1）：站点 `type` 决定 HTTP API 家族；`type=3` 再按 `api` 形态
/// 分派 CatSpider HTTP、本地 sidecar 或结构化不可用结论。
class SpiderRouter {
  SpiderRouter({
    required this.client,
    required this.globalHeaders,
    this.userAgent = HttpApiRequestBuilder.defaultUserAgent,
    this.catHttpClient,
    this.registry,
    this.supervisor,
    this.log,
    this.hostPath,
  });

  final HttpApiClient client;
  final List<HeaderRule> globalHeaders;
  final String userAgent;

  /// `webhtv-cat-http-v1` 客户端（§9.4）。
  final CatHttpClient? catHttpClient;

  /// 本地 Spider manifest 注册表（§9.7）。
  final SpiderManifestRegistry? registry;

  /// sidecar 宿主（§9.8）。
  final SpiderHostSupervisor? supervisor;

  final LogService? log;

  /// sidecar 宿主路径覆盖（测试用）。
  final String? hostPath;

  final Map<String, SiteRuntime> _cache = {};

  /// 运行时缓存键：同一 `type` 可能有不同 ABI，不能只用 type 做键。
  String _cacheKey(Site site) => '${site.type}:${site.api.trim().toLowerCase()}';

  /// 带注册表的可用性判定（§8.1）。
  ///
  /// 本地 `spider-local:` 站点必须能在注册表中找到合法 manifest 才可用；
  /// 未安装运行时（无 Python）也必须如实报告而不是静默失败。
  SiteAvailability classifySite(Site site) {
    if (!SpiderLocalBinding.matches(site.api)) return classify(site);

    final local = SpiderLocalBinding(registry: registry!).resolve(site.api);
    if (local == null) {
      return const SiteAvailability(
        available: false,
        runtimeName: '本地 Spider (webhtv-ipc-v1)',
        stage: 'MVP-B',
        reason: 'manifest 未注册或校验失败，请检查 %APPDATA%/webhtv-pc/spiders',
      );
    }
    if (!local.entryExists) {
      return SiteAvailability(
        available: false,
        runtimeName: '本地 Spider (webhtv-ipc-v1)',
        stage: 'MVP-B',
        reason: 'manifest 声明的入口不存在：${local.manifest.entry}',
      );
    }
    final command = LocalSpiderCommand.resolve(
      spider: local,
      hostPath: _hostPath(),
      log: log,
    );
    if (command == null) {
      return SiteAvailability(
        available: false,
        runtimeName: '本地 Spider (webhtv-ipc-v1)',
        stage: 'MVP-B',
        reason: '运行时 ${local.manifest.runtime} 未安装或不受支持',
      );
    }
    return SiteAvailability(
      available: true,
      runtimeName: '本地 Spider (webhtv-ipc-v1)',
      stage: 'MVP-B',
      reason: 'runtime=${local.manifest.runtime} '
          'capabilities=${local.manifest.capabilities.sorted.join(",")}',
    );
  }

  String _hostPath() =>
      hostPath ??
      (supervisor == null ? '' : '');

  /// `type=3` 的 `api` 形态判定（§8.1）。
  static SiteAvailability classify(Site site) {
    switch (site.type) {
      case SiteType.xmlApi:
        return const SiteAvailability(
          available: true,
          runtimeName: 'HTTP API (XML)',
          stage: 'MVP-A',
        );
      case SiteType.jsonApi:
        return const SiteAvailability(
          available: true,
          runtimeName: 'HTTP API (JSON)',
          stage: 'MVP-A',
        );
      case SiteType.jsonApiCompat:
        return const SiteAvailability(
          available: true,
          runtimeName: 'HTTP API (JSON 兼容)',
          stage: 'MVP-A',
        );
      case SiteType.jsonApiBase64Ext:
        return const SiteAvailability(
          available: true,
          runtimeName: 'HTTP API (Base64 ext)',
          stage: 'MVP-A',
        );
      default:
        return _classifySpider(site);
    }
  }

  static SiteAvailability _classifySpider(Site site) {
    final api = site.api.trim().toLowerCase();
    final jar = (site.jar ?? '').trim();

    // 本地 sidecar 使用独立 scheme，必须先于其他形态判定（§9.9）。
    if (SpiderLocalBinding.matches(site.api)) {
      return const SiteAvailability(
        available: false,
        runtimeName: '本地 Spider (webhtv-ipc-v1)',
        stage: 'MVP-B',
        reason: '需要注册表实例才能判定（请使用 classifySite）',
      );
    }

    // 文件扩展名是比路径片段更强的信号：`.../spider/a.js` 必须判为 JS 运行时，
    // 否则会被 `/spider/` 片段误判为 CatSpider HTTP。
    if (api.endsWith('.js') || api.contains('.js?')) {
      return const SiteAvailability(
        available: false,
        runtimeName: 'Node/QuickJS Spider',
        stage: 'Phase 3',
        reason: '需要独立 sidecar 与 tvbox-js-v1 契约',
      );
    }
    if (api.endsWith('.py') || api.contains('.py?')) {
      return const SiteAvailability(
        available: false,
        runtimeName: 'Python Spider',
        stage: 'Phase 3',
        reason: '需要独立 sidecar 与 tvbox-python-v1 契约',
      );
    }
    if (api.contains('csp_')) {
      return const SiteAvailability(
        available: false,
        runtimeName: 'PC Java Spider',
        stage: 'Phase 3',
        reason: '需要独立 JVM sidecar，主进程不得加载不可信 JAR',
      );
    }
    if (api.contains('/spider/') || api.endsWith('/spider')) {
      // §9.4：`/spider/` 形态由 CatSpider HTTP 承担，已实现。
      // 末尾斜杠可缺省（`endpoint()` 会归一化后追加路由）。
      return const SiteAvailability(
        available: true,
        runtimeName: 'CatSpider HTTP (webhtv-cat-http-v1)',
        stage: 'MVP-B',
        reason: '兼容标签 tvbox-http-v1',
      );
    }
    if (jar.isNotEmpty) {
      return const SiteAvailability(
        available: false,
        runtimeName: 'Android/JAR Spider',
        stage: 'Phase 3',
        reason: '需要独立 JVM 兼容运行时，且需用户确认来源与权限',
      );
    }
    return const SiteAvailability(
      available: false,
      runtimeName: 'SpiderNull',
      reason: 'api 形态未匹配任何已实现运行时',
    );
  }

  /// 获取站点运行时。不可用时返回 [UnsupportedRuntime]，调用后抛出可定位错误。
  SiteRuntime runtimeFor(Site site) {
    final availability = classifySite(site);
    if (!availability.available) {
      return UnsupportedRuntime(
        runtimeName: availability.runtimeName,
        reason: availability.reason ?? '',
        stage: availability.stage,
      );
    }
    return _cache.putIfAbsent(_cacheKey(site), () => _create(site));
  }

  SiteRuntime _create(Site site) {
    if (SpiderLocalBinding.matches(site.api)) {
      final local = SpiderLocalBinding(registry: registry!).resolve(site.api);
      if (local == null || supervisor == null) {
        return UnsupportedRuntime(
          runtimeName: '本地 Spider (webhtv-ipc-v1)',
          reason: 'manifest 未注册或 sidecar 宿主不可用',
          stage: 'MVP-B',
        );
      }
      final command = LocalSpiderCommand.resolve(
        spider: local,
        hostPath: _hostPath(),
        log: log,
      );
      if (command == null) {
        return UnsupportedRuntime(
          runtimeName: '本地 Spider (webhtv-ipc-v1)',
          reason: '运行时 ${local.manifest.runtime} 未安装或不受支持',
          stage: 'MVP-B',
        );
      }
      return SidecarRuntime(
        site: site,
        spider: local,
        command: command,
        supervisor: supervisor!,
        log: log,
      );
    }

    if (site.type == SiteType.spider) {
      final catClient = catHttpClient;
      if (catClient == null) {
        return UnsupportedRuntime(
          runtimeName: 'CatSpider HTTP (webhtv-cat-http-v1)',
          reason: 'cat http 客户端未初始化',
          stage: 'MVP-B',
        );
      }
      return CatHttpSiteRuntime(
        client: catClient,
        globalHeaders: globalHeaders,
        siteKey: site.key,
        userAgent: userAgent,
      );
    }

    return HttpApiRuntime(
      client: client,
      globalHeaders: globalHeaders,
      userAgent: userAgent,
    );
  }

  /// 可运行站点数量，供站点列表页展示。
  int get runnableSiteCount => _cache.length;

  void dispose() {
    client.close();
    catHttpClient?.close();
  }
}

/// [SiteResult] → 可缓存的 JSON 结构（§14.1 搜索缓存）。
extension SiteResultCache on SiteResult {
  Map<String, Object?> toCacheJson() => {
    'class': classes
        .map((item) => {'type_id': item.typeId, 'type_name': item.typeName})
        .toList(),
    'filters': filters.map(
      (key, groups) => MapEntry(
        key,
        groups
            .map(
              (group) => {
                'key': group.key,
                'name': group.name,
                'value': group.options
                    .map((option) => {'n': option.name, 'v': option.value})
                    .toList(),
              },
            )
            .toList(),
      ),
    ),
    'list': list.map((vod) => vod.toJson()).toList(),
    if (page != null) 'page': page,
    if (pageCount != null) 'pagecount': pageCount,
    if (total != null) 'total': total,
  };
}
