/// Spider 路由：按站点 `type` 与 `api` 形态分发到具体运行时（§8.1、§9.1）。
///
/// 已实现运行时：
/// - HTTP API（`type=0/1/2/4`，MVP-A）；
/// - `webhtv-cat-http-v1` / CatSpider HTTP（MVP-B，§9.4）；
/// - 本地 `webhtv-ipc-v1` sidecar（`api` 形如 `spider-local:<key>`，§9.3、§9.8），
///   manifest 的 `runtime` 决定具体宿主机：`python*` → `spider-host-python/host.py`，
///   `node*` → `spider-host-js/host.js`（`tvbox-js-v1`，§9.1），
///   `jvm*`/`java*` → `spider-host-jvm/host.jar`（`tvbox-java-v1`，§9.3）。
///
/// `csp_*` 站点（TVBox 生态的 Java 站源类名形态）在 PC 端映射到 `jvm` 运行时，
/// 但**只接受无 Android Context 的桌面 jar**：含**原生库**（`lib/*.so`）或 zip 结构
/// 损坏、无法确认原生库的入口一律如实报不可用；含 `classes.dex` 且**无**原生库的
/// 入口可先转译成桌面 class jar（导入期 `DexTranslate`），可用性按转译结论分级
/// （ADR-0002 §1.1）。
///
/// 未实现形态（`*.py`、Android JAR）继续返回结构化不可用结论，
/// UI 显示运行时未安装/未支持，不得显示空列表（§8.1、§9.9）。
///
/// `api` 直接指向 `*.js` / `*.py` 的站点由 [DirectSpiderRegistrar] 自动落地为
/// `spider-local` manifest（Phase 9 P1-7），再走同一条 sidecar 路径；
/// 自动注册失败时如实报「运行时未就绪」，不静默降级。
library;

import 'dart:async';

import 'package:path/path.dart' as p;

import '../core/app_error.dart';
import '../core/cat_http.dart';
import '../core/http_api.dart';
import '../core/ipc_protocol.dart';
import '../core/protocol.dart';
import 'direct_spider_registrar.dart';
import 'jar_intake.dart';
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

  Future<SiteResult> detail(
    Site site,
    String vodId, {
    VodIdentityHint? identity,
  });

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
  Future<SiteResult> detail(
    Site site,
    String vodId, {
    VodIdentityHint? identity,
  }) async => throw _error(site.key, 'detail');

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
  Future<SiteResult> detail(
    Site site,
    String vodId, {
    VodIdentityHint? identity,
  }) {
    final call = _build(site, HttpApiAction.detail, vodId: vodId);
    return client.execute(call, siteKey: site.key, identity: identity);
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
    ).buildPlayRequest(episodeTarget, flag: flag);
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
    this.jsHostPath,
    this.jvmHostPath,
    this.cspBinding,
  });

  /// HTTP 客户端。可随出站代理/DoH 设置变化替换（见 [updateTransport]）。
  HttpApiClient client;

  /// 配置级请求头。与 [client] 一起随配置装配更新。
  List<HeaderRule> globalHeaders;

  final String userAgent;

  /// `webhtv-cat-http-v1` 客户端（§9.4）。
  final CatHttpClient? catHttpClient;

  /// 本地 Spider manifest 注册表（§9.7）。
  final SpiderManifestRegistry? registry;

  /// sidecar 宿主（§9.8）。
  final SpiderHostSupervisor? supervisor;

  final LogService? log;

  /// sidecar 宿主路径覆盖（测试用）。Python 宿主路径。
  final String? hostPath;

  /// JS（Node）sidecar 宿主路径覆盖（测试用）；为空时由 [hostPath] 推导。
  final String? jsHostPath;

  /// JVM（Java）sidecar 宿主路径覆盖（测试用）；为空时由 [hostPath] 推导。
  ///
  /// `jvm*`/`java*` 运行时需要 `sidecars/spider-host-jvm/host.jar`（§9.3
  /// `tvbox-java-v1`）。该路径**不**用于加载 Android jar（见 ADR-0002 §1.1）。
  final String? jvmHostPath;

  /// `csp_*` 站点的本地缓存绑定；为空时按注册表根目录推导（`<root>/csp`）。
  final CspJvmBinding? cspBinding;

  final Map<String, SiteRuntime> _cache = {};

  /// 运行时缓存键：同一 `type` 可能有不同 ABI，不能只用 type 做键。
  ///
  /// 还必须带 `site.key`：CatVod 壳站点（如几十个 `csp_PyProxy`）的 api 完全相同，
  /// 只用 api 做键会把它们塌缩成同一个 runtime（共享第一个站点的 ext）。
  String _cacheKey(Site site) =>
      '${site.type}:${site.key}:${site.api.trim().toLowerCase()}';

  /// 直连 js/py 站点自动注册结果（`site.key` → 已注册 spider）。
  ///
  /// 由 `AppState` 在导入配置后填充；为空时直连站点按「未注册」如实报错。
  Map<String, LocalSpider> directSpiders = const {};

  /// 更新直连站点注册结果（并清理旧缓存，使下次判定拿到新结论）。
  void setDirectSpiders(Map<String, LocalSpider> spiders) {
    directSpiders = spiders;
    _cache.clear();
  }

  /// 运行时缓存失效（解释器就绪后调用）。
  ///
  /// 每个 [SiteRuntime] 都**快照**了构造时解析出的执行命令。托管 Python 运行时
  /// 就绪、或解释器优先级变化后，必须让下次 [classifySite]/[runtimeFor] 重建，
  /// 否则站点会继续用当年那个「没有 requests 的解释器」启动。
  ///
  /// 不清空 [directSpiders]（注册结果与解释器无关），也不 dispose 旧 runtime：
  /// 在途调用仍持有它，宿主进程由 supervisor 按 siteKey 复用。
  void invalidateRuntimes() {
    _cache.clear();
  }

  /// 更新 HTTP 传输（出站代理 / DoH / 配置换源后调用）。
  ///
  /// 运行时会**快照**构造时的 client 与 globalHeaders（[_create]），所以只改字段
  /// 不够，必须同时清空 [_cache]，否则旧 runtime 会继续用上一代传输。
  ///
  /// 本方法**不关闭**旧 [client]：它会随 `AppState` 的重建流程统一释放
  /// （新客户端可能正被别处持有；早关会让在途请求直接失败）。
  void updateTransport({
    HttpApiClient? client,
    List<HeaderRule>? globalHeaders,
  }) {
    if (client != null && !identical(client, this.client)) {
      this.client = client;
    }
    if (globalHeaders != null && !identical(globalHeaders, this.globalHeaders)) {
      this.globalHeaders = globalHeaders;
    }
    _cache.clear();
  }

  /// 带注册表的可用性判定（§8.1）。
  ///
  /// 本地 `spider-local:` 站点必须能在注册表中找到合法 manifest 才可用；
  /// `csp_*` 站点需要本地缓存的**桌面** jar（含 dex 的 Android jar 明确不支持）；
  /// 未安装运行时（无 Python/Node/Java）也必须如实报告而不是静默失败。
  SiteAvailability classifySite(Site site) {
    // 直连/自动注册产物排在 csp_ 之前：CatVod 壳站点（api=csp_PyProxy）虽然
    // 名字像 JVM 绑定，实际由 Python sidecar 承载，必须先进直连分支。
    final registered = SpiderLocalBinding.matches(site.api)
        ? null
        : directSpiders[site.key];
    if (registered != null) return _classifyLocal(registered);
    if (CspJvmBinding.matches(site.api)) return _classifyCsp(site);
    if (!SpiderLocalBinding.matches(site.api)) {
      // 直连 js/py：已自动注册则按本地 spider 判定，否则如实报未就绪。
      final direct = directSpiders[site.key];
      if (direct != null) return _classifyLocal(direct);
      final kindReason = _directUnavailableReason(site);
      if (kindReason != null) {
        return SiteAvailability(
          available: false,
          runtimeName: kindReason,
          stage: 'Phase 3',
          reason: '直连站源尚未注册（需要先成功下载并生成 manifest）',
        );
      }
      return classify(site);
    }

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
      jsHostPath: jsHostPath,
      jvmHostPath: jvmHostPath,
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

  /// 直连 js/py/CatVod 壳站点的运行时可读名；非该形态返回 null。
  static String? _directUnavailableReason(Site site) {
    if (site.type != 3) return null;
    final api = site.api.trim().toLowerCase();
    if (api.endsWith('.js') || api.contains('.js?')) {
      return 'Node Spider (tvbox-js-v1)';
    }
    if (api.endsWith('.py') || api.contains('.py?')) {
      return 'Python Spider (tvbox-python-v1)';
    }
    if (catVodLoaderUrl(site) != null) {
      return 'CatVod Python Spider (catvod-python-v1)';
    }
    return null;
  }

  /// 已注册的本地 spider 的可用性判定（与 `spider-local:` 同一口径）。
  SiteAvailability _classifyLocal(LocalSpider local) {
    if (!local.entryExists) {
      return SiteAvailability(
        available: false,
        runtimeName: '本地 Spider (webhtv-ipc-v1)',
        stage: 'Phase 3',
        reason: 'manifest 声明的入口不存在：${local.manifest.entry}',
      );
    }
    final command = LocalSpiderCommand.resolve(
      spider: local,
      hostPath: _hostPath(),
      jsHostPath: jsHostPath,
      jvmHostPath: jvmHostPath,
      log: log,
    );
    if (command == null) {
      return SiteAvailability(
        available: false,
        runtimeName: '本地 Spider (webhtv-ipc-v1)',
        stage: 'Phase 3',
        reason: '运行时 ${local.manifest.runtime} 未安装或不受支持',
      );
    }
    return SiteAvailability(
      available: true,
      runtimeName: '本地 Spider (webhtv-ipc-v1)',
      stage: 'Phase 3',
      reason: 'runtime=${local.manifest.runtime} '
          'capabilities=${local.manifest.capabilities.sorted.join(",")}',
    );
  }

  String _hostPath() =>
      hostPath ??
      (supervisor == null ? '' : '');

  /// `csp_*` 站点的可用性判定（§9.3 `tvbox-java-v1`）。
  ///
  /// 判定顺序：本地缓存入口 → 原生库 → 不可转译的 Android jar → 「可转译 dex」的
  /// 导入期预转译结论 → Java 运行时与宿主。
  /// 每一步失败都给出**可定位**的原因，不得静默降级为空列表（§8.1、§9.9）。
  SiteAvailability _classifyCsp(Site site) {
    final binding = cspBinding;
    if (binding == null) {
      return const SiteAvailability(
        available: false,
        runtimeName: 'PC Java Spider',
        stage: 'Phase 3',
        reason: '需要本地 Spider 注册表才能判定',
      );
    }
    final entry = binding.entryFor(site.key);
    if (entry == null) {
      // 自动探测（方案 3）给过的结论必须原样带到用户面前：配置声明的 jar 若
      // 含 classes.dex / 原生库，程序已经试过并拒绝落盘，不能再让用户对着
      // 「请把 jar 放到 …」自己去猜（§12.9）。
      final probed = JarIntake.probeRecord(binding.directoryFor(site.key));
      final summary = (probed?['summary'] as String?)?.trim() ?? '';
      final sourceUrl = (probed?['sourceUrl'] as String?)?.trim() ?? '';
      if (summary.isNotEmpty) {
        final from = sourceUrl.isEmpty
            ? '配置声明的 jar'
            : '配置声明的 jar（${redactUrl(sourceUrl)}）';
        return SiteAvailability(
          available: false,
          runtimeName: 'Android/JAR Spider',
          stage: 'Phase 3',
          reason: '自动检测失败：$from 无法在桌面 JVM 加载。$summary',
        );
      }
      return SiteAvailability(
        available: false,
        runtimeName: 'PC Java Spider',
        stage: 'Phase 3',
        reason: '缺少桌面 JVM 站源：请把**无 Android Context** 的 jar 放到 '
            '${binding.directoryFor(site.key)}（Android jar 内含 classes.dex，JVM 无法加载）',
      );
    }
    // 静态结论只取一次：原生库判定必须显式在这里拒绝——`isAndroidJar` 现在只覆盖
    // 「zip 解析失败、按字节兜底看到 classes.dex」那一种（无法确认有无 lib/*.so），
    // 不含 [JarVerdict.nativeLibrary]；漏掉的话「dex + 原生库」的 jar 会一路滑到
    // 下面的「可加载」分支，被谎报成可用（§12.6.4 ①、ADR-0002）。
    final inspection = JarIntake.inspectPath(
      entry,
      expectedClass: JarIntake.classNameFor(site.key),
    );
    if (inspection.verdict == JarVerdict.nativeLibrary) {
      final native = inspection.nativeEntries.take(3).join('、');
      return SiteAvailability(
        available: false,
        runtimeName: 'Android/JAR Spider',
        stage: 'Phase 3',
        reason: '该 jar 含原生库（$native），桌面 JVM 无法加载；'
            'dex 预转译只解决字节码形态，不解决原生实现（ADR-0002）',
      );
    }
    if (CspJvmBinding.isAndroidJar(entry)) {
      return SiteAvailability(
        available: false,
        runtimeName: 'Android/JAR Spider',
        stage: 'Phase 3',
        reason: '该 jar 看起来是 Android 站源（内含 classes.dex），但 zip 结构已损坏、'
            '无法确认是否还含原生库（lib/*.so），因此不自动转译；JVM 无法加载。'
            '请重新获取完整的 jar（或桌面版 jar），或按 ADR-0002 启用 Android 兼容层',
      );
    }
    // 「可转译 dex」：可用性取决于导入期预转译的结论（`intake.json` 的
    // `dexTranslation`）。三种情形必须分开说，不能一律谎称已就绪：
    // 已转译 → 可用；转译失败 → 不可用；没有记录 → 可用但首次加载要现场转译。
    String? dexNote;
    if (inspection.verdict == JarVerdict.translatableDex) {
      final translation =
          JarIntake.intakeRecord(binding.directoryFor(site.key))?['dexTranslation'];
      if (translation is! Map) {
        dexNote = '该站点为 Android 站源（内含 classes.dex），尚未预转译，'
            '首次加载时会转译（约数秒）';
      } else if (translation['ok'] == true) {
        dexNote = '该站点为 Android 站源，dex 已转译 classCount='
            '${translation['classCount'] ?? 0}';
      } else {
        final stage = '${translation['stage'] ?? ''}'.trim();
        final message = '${translation['message'] ?? ''}'.trim();
        return SiteAvailability(
          available: false,
          runtimeName: 'Android/JAR Spider',
          stage: 'Phase 3',
          reason: '该站点为 Android 站源，dex 预转译失败'
              '${stage.isEmpty ? '' : '（$stage）'}'
              '${message.isEmpty ? '' : '：$message'}',
        );
      }
    }
    // 自愈：P1-2 前期导入的站点目录里没有 manifest.json（当时只有 index.jar +
    // intake.json），而 JVM 宿主对缺失的 manifest 直接退出码 2。判定前补写一次，
    // 避免用户必须删目录重导才能恢复。
    JarIntake.ensureLaunchManifest(
      targetDir: binding.directoryFor(site.key),
      siteKey: site.key,
    );
    final local = cspLocalSpider(
      site: site,
      entryPath: entry,
      binding: binding,
    );
    final command = LocalSpiderCommand.resolve(
      spider: local,
      hostPath: _hostPath(),
      jsHostPath: jsHostPath,
      jvmHostPath: jvmHostPath,
      log: log,
    );
    if (command == null) {
      return const SiteAvailability(
        available: false,
        runtimeName: 'PC Java Spider',
        stage: 'Phase 3',
        reason: '未找到 Java 运行时（JDK/JRE）或 spider-host-jvm/host.jar',
      );
    }
    return SiteAvailability(
      available: true,
      runtimeName: 'PC Java Spider (tvbox-java-v1)',
      stage: 'Phase 3',
      reason: '${dexNote == null ? '' : '$dexNote；'}'
          'runtime=jvm entry=${p.basename(entry)} '
          'capabilities=${local.manifest.capabilities.sorted.join(",")}',
    );
  }

  /// 为 `csp_*` 站点构造合成 [LocalSpider]（复用 `webhtv-ipc-v1` sidecar 运行时）。
  static LocalSpider cspLocalSpider({
    required Site site,
    required String entryPath,
    required CspJvmBinding binding,
  }) {
    final manifest = SpiderManifest(
      key: site.key,
      name: site.name,
      runtime: 'jvm',
      entry: entryPath,
      capabilities: const ['home', 'category', 'detail', 'search', 'play'],
      permissions: const SpiderPermissions(),
      limits: const SpiderLimits(),
    );
    return LocalSpider(
      manifest: manifest,
      manifestPath: p.join(binding.directoryFor(site.key), 'manifest.json'),
      rootDir: binding.directoryFor(site.key),
      entryPath: entryPath,
    );
  }

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
      // 有注册表时走 `classifySite` → `_classifyCsp`（会检查本地缓存 jar 与
      // Java 运行时）；无注册表时只能给出静态结论。
      return const SiteAvailability(
        available: false,
        runtimeName: 'PC Java Spider',
        stage: 'Phase 3',
        reason: '需要本地桌面 JVM 站源（tvbox-java-v1）与独立 JVM sidecar，'
            '主进程不得加载不可信 JAR',
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

  /// 执行一次站点搜索，可选择用**调用方给的**客户端发请求。
  ///
  /// 为什么需要它而不是直接 [runtimeFor]：缓存的运行时在构造时就把客户端
  /// 引用拷了进去，而并发搜索需要一个批次专属的客户端——批次结束/取消时
  /// 关掉它能立刻掐断在途连接。绝不能替换缓存里那份，否则详情页等其它
  /// 请求会跟着被掐断。
  ///
  /// 只有 HTTP API 运行时能被换客户端：sidecar（js/py/jvm）与 cat-http 走
  /// 各自的常驻进程或专属通道，换客户端对它们没有意义。
  Future<SiteResult> search(
    Site site, {
    required String keyword,
    int page = 1,
    bool quick = false,
    HttpApiClient? client,
  }) {
    final runtime = runtimeFor(site);
    if (client == null || runtime is! HttpApiRuntime) {
      return runtime.search(site, keyword: keyword, page: page, quick: quick);
    }
    return HttpApiRuntime(
      client: client,
      globalHeaders: globalHeaders,
      userAgent: userAgent,
    ).search(site, keyword: keyword, page: page, quick: quick);
  }

  SiteRuntime _create(Site site) {
    // 直连 js/py：已自动注册则复用本地 spider 运行时。
    final direct = directSpiders[site.key];
    if (direct != null && supervisor != null) {
      final command = LocalSpiderCommand.resolve(
        spider: direct,
        hostPath: _hostPath(),
        jsHostPath: jsHostPath,
        jvmHostPath: jvmHostPath,
        log: log,
      );
      if (command != null) {
        return SidecarRuntime(
          site: site,
          spider: direct,
          command: command,
          supervisor: supervisor!,
          log: log,
        );
      }
    }
    // `csp_*`：桌面 JVM 站源，复用同一份 `webhtv-ipc-v1` sidecar 运行时（§9.3）。
    if (CspJvmBinding.matches(site.api)) {
      final binding = cspBinding;
      final entry = binding?.entryFor(site.key);
      if (binding == null || entry == null || supervisor == null) {
        return UnsupportedRuntime(
          runtimeName: 'PC Java Spider',
          reason: '缺少本地桌面 JVM 站源或 sidecar 宿主不可用',
          stage: 'Phase 3',
        );
      }
      final local = cspLocalSpider(site: site, entryPath: entry, binding: binding);
      final command = LocalSpiderCommand.resolve(
        spider: local,
        hostPath: _hostPath(),
        jsHostPath: jsHostPath,
        jvmHostPath: jvmHostPath,
        log: log,
      );
      if (command == null) {
        return const UnsupportedRuntime(
          runtimeName: 'PC Java Spider',
          reason: '未找到 Java 运行时（JDK/JRE）或 spider-host-jvm/host.jar',
          stage: 'Phase 3',
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
        jsHostPath: jsHostPath,
        jvmHostPath: jvmHostPath,
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
