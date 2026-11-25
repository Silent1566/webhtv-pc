/// 应用状态：编排配置导入、站点浏览、详情与播放（§4.2 Application Service 层）。
///
/// 约束：
/// - UI 不直接发网络请求，全部经由此处的服务；
/// - 任何失败都转为 [AppError]，由 UI 展示可定位提示，不阻塞界面；
/// - 存储不可用时降级为“无历史/无缓存”，不影响播放（§16.3）。
library;

import 'dart:async';

import '../core/external_meta.dart';
import '../core/meta_override.dart';
import '../core/meta_pipeline.dart';
import '../core/meta_source.dart';
import '../core/detail_recommendation.dart';
import '../core/detail_source_merge.dart';
import '../core/episode_aggregation.dart';
import '../core/episode_manual_match.dart';
import 'detail_recommendation_state.dart';

import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import '../services/external_player.dart';
import '../services/external_url.dart';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'package:sqlite3/sqlite3.dart' show Row;

import '../core/ad_rules.dart';
import '../core/android_bridge.dart';
import '../core/android_sync.dart';
import '../core/ai_config.dart';
import '../core/ai_content/ad_rule_validation.dart';
import '../core/ai_content/group_rule_validation.dart';
import '../core/ai_content/recommendation.dart';
import '../core/ai_content/title_learning.dart';
import '../services/ai_content/ad_rule_service.dart';
import '../services/ai_content/ai_content_completion.dart';
import '../services/ai_completion_client.dart';
import '../services/ai_integration.dart';
import '../services/ai_season_mapping_service.dart';
import '../services/episode_manual_match_service.dart';
import '../services/ai_content_title_bridge.dart';
import '../services/ai_episode_season_service.dart';
import '../core/app_error.dart';
import '../core/request_cancellation.dart';
import '../core/app_update.dart';
import '../core/cat_http.dart';
import '../core/cat_source.dart';
import '../core/config_loader.dart';
import '../core/config_parser.dart';
import '../core/danmaku_match.dart';
import '../core/danmaku_settings.dart';
import '../core/danmaku_style.dart';
import '../core/doh.dart';
import '../core/doh_settings.dart';
import '../core/following.dart';
import '../core/following_calendar.dart';
import '../core/session_recovery.dart';
import '../core/backup_manifest.dart';
import '../services/backup_service.dart';
import '../services/bangumi_service.dart';
import '../services/doh_resolver.dart';
import '../services/following_progress_service.dart';
import '../services/following_service.dart';
import '../services/following_air_time_service.dart';
import '../services/notification_service.dart';
import '../services/session_recovery_store.dart';
import '../services/push_site_service.dart';
import '../services/sniff_runtime.dart';
import '../core/history_aggregation.dart';
import '../core/history_grouping.dart';
import '../core/history_scope.dart';
import '../core/history_view.dart';
import '../core/live_settings.dart';
import '../core/live_site_keywords.dart';
import '../core/http_api.dart';
import '../core/osd_config.dart';
import '../core/osd_style.dart';
import '../core/playback.dart';
import '../core/playback_diagnostics.dart';
import '../core/playback_request.dart';
import '../core/playback_lines.dart';
import '../core/playback_platform.dart';
import '../core/player_buttons.dart';
import '../core/outbound_proxy.dart';
import '../core/parse_failover.dart';
import '../core/player_options.dart';
import '../core/player_tracks.dart';
import '../core/protocol.dart';
import '../core/proxy_policy.dart';
import '../core/realtime_sync.dart';
import '../core/spider_account.dart';
import '../core/source_key.dart';
import '../core/source_swap.dart';
import '../core/site_group.dart';
import '../core/site_injection.dart';
import '../core/site_group_rules.dart';
import '../core/site_order.dart';
import '../core/skip_segments.dart';
import '../core/subtitle_provider.dart';
import '../core/subtitle_settings.dart';
import '../core/subtitle_style.dart';
import '../core/tmdb_config.dart';
import '../core/tmdb_route.dart';
import '../services/tmdb_route_health.dart';
import '../services/tmdb_route_selector.dart';
import '../core/viewing_metadata.dart';
import '../core/tmdb_subscription.dart';
import '../core/push_parser.dart';
import '../core/tmdb_identity.dart';
import '../core/tmdb_playback.dart';
import '../core/tmdb_title.dart';
import '../core/tmdb_season.dart';
import '../services/app_paths.dart';
import '../services/lut_store.dart';
import '../services/config_source_status.dart';
import '../services/android_bridge_service.dart';
import '../services/android_playback_bridge.dart';
import '../services/android_read_client.dart';
import '../services/cat_bundle.dart';
import '../services/cat_runtime.dart';
import '../services/csp_jar_probe.dart';
import '../services/dex_translate.dart';
import '../services/direct_spider_registrar.dart';
import '../services/epg_service.dart';
import '../services/jar_intake.dart';
import '../services/last_config_store.dart';
import '../services/local_source_import.dart';
import '../services/local_spider_removal.dart';
import '../services/local_spider_scanner.dart';
import '../services/log_service.dart';
import '../services/outbound_proxy.dart';
import '../services/live_service.dart';
import '../services/proxy_server.dart';
import '../services/python_environment.dart';
import '../services/realtime_sync_engine.dart';
import '../services/search_suggest_service.dart';
import '../services/parse_service.dart';
import '../services/site_service.dart';
import '../services/spider_process.dart';
import '../services/spider_proxy_session.dart';
import '../services/sidecar_runtime.dart';
import '../services/spider_account_store.dart';
import '../services/spider_registry.dart';
import '../services/unidbg_runtime.dart';
import '../services/spider_router.dart';
import '../services/ai_config_store.dart';
import '../services/detail_rating_service.dart';
import '../services/douban_recommendation_service.dart';
import '../services/external_meta_service.dart';
import '../services/storage.dart';
import '../services/viewing_report_metadata.dart';
import '../services/sync_client.dart';
import '../services/sync_server.dart';
import '../services/tmdb_cache.dart';
import '../services/tmdb_config_store.dart';
import '../services/ui_preferences_store.dart';
import '../services/app_update_service.dart';
import '../services/update_preferences_store.dart';
import '../services/local_source_enable_store.dart';
import '../services/web_home_store.dart';
import '../ui/shell_unpack_dialogs.dart' show ShellTargetItem;
import '../services/tmdb_enrichment_service.dart';
import '../services/tmdb_history.dart';
import '../services/tmdb_identity_service.dart';
import '../services/tmdb_season_service.dart';
import '../services/tmdb_service.dart';
import '../services/tmdb_stores.dart';
import 'local_site_sources.dart';
import 'playback_source_context.dart';
import 'search_state.dart';
import 'sync_state.dart';
import 'tmdb_state.dart';

/// 版本号：CI 用 `--dart-define=APP_VERSION=<pubspec version>` 注入，
/// 使 exe 文件版本、启动日志、备份/恢复清单与发布 tag 同一口径（§20.1）；
/// 本地构建与测试保留默认值 `0.1.0`，行为不变。
const String appVersion = String.fromEnvironment(
  'APP_VERSION',
  defaultValue: '0.1.0',
);

/// 发布 tag：CI 用 --dart-define=APP_TAG=「v0.1.0-202611231630」注入，
/// 更新检查靠它判断「本机是发布构建」还是「开发构建」（ADR-0015）。
const String appBuildTag = String.fromEnvironment('APP_TAG', defaultValue: '');
final String appBuildFlavor =
    'MVP-A (${switch (Platform.operatingSystem) {
      'windows' => 'Windows',
      'linux' => 'Linux',
      'macos' => 'macOS',
      final other => other,
    }})';

/// 启动诊断信息，用于日志页与验收证据（§20.3 “启动日志记录版本、平台、
/// 架构、播放器引擎和运行时版本”）。
class StartupInfo {
  const StartupInfo({
    required this.version,
    required this.flavor,
    required this.platform,
    required this.architecture,
    required this.playerEngine,
    required this.dartVersion,
    required this.configDir,
    required this.cacheDir,
    required this.logDir,
    required this.databasePath,
    this.databaseError,
    this.storageWarnings = const [],
    this.startupLatency = Duration.zero,
  });

  final String version;
  final String flavor;
  final String platform;
  final String architecture;
  final String playerEngine;
  final String dartVersion;
  final String configDir;
  final String cacheDir;
  final String logDir;
  final String databasePath;
  final String? databaseError;

  /// 启动时实测不可写的目录，形如 `目录: 错误`。空表示全部可写。
  ///
  /// 与 [databaseError] 分开：数据库只读往往只是**同一个原因的一个结果**，
  /// 把目录级探测结果单独带出来，用户与排障者才能一眼看出「整个目录写不了」，
  /// 而不是去反复删库重建。
  final List<String> storageWarnings;
  final Duration startupLatency;

  String get oneLine =>
      'WebHTV PC $version ($flavor) platform=$platform arch=$architecture '
      'player=$playerEngine dart=$dartVersion '
      'startup=${startupLatency.inMilliseconds}ms';

  String get detailLines => [
    oneLine,
    'config=$configDir',
    'cache=$cacheDir',
    'logs=$logDir',
    'db=$databasePath${databaseError == null ? "" : " (降级: $databaseError)"}',
    if (storageWarnings.isNotEmpty)
      'writable=NO: ${storageWarnings.join("; ")}',
  ].join('\n');
}

/// 单个页面的加载状态。
enum LoadPhase { idle, loading, ready, failed }

/// 站点列表项的运行时可用性展示（§8.1）。
class SiteListItem {
  const SiteListItem({required this.site, required this.availability});

  final Site site;
  final SiteAvailability availability;
}

/// 后台刷新一条配置的结局（只用于启动刷新的汇总统计）。
enum _ConfigRefreshOutcome {
  /// 内容真的变了，已落库。
  changed,

  /// 服务端 304 或内容摘要与库里一致：本地内容原样可用。
  unchanged,

  /// 这一轮失败：本地缓存与已注册/已编译的站源保持不动。
  failed,

  /// 用户在这几秒里改过配置（导入/切换/编辑/删除）：本轮作废。
  skipped,
}

typedef CspProbeRunner = Future<CspProbeReport> Function(AppConfig config);

/// 后台自动安装 runner：除报告外还要把逐 jar 的 [onProgress]、逐站点的 [onEntry]
/// 交回状态层（导入页据此显示真实进度）。
typedef CspProvisionRunner =
    Future<CspProbeReport> Function(
      AppConfig config, {
      void Function(ShellUnpackTick tick)? onProgress,
      void Function(CspProbeEntry entry)? onEntry,
    });

/// 后台自动安装的**只读**进度（导入页按它显示「正在自动安装站源 12/78」）。
///
/// 为什么单独一个值类型：UI 只读、状态层只在站点结论或阶段变化时换一个新实例，
/// 于是「每 tick 都 notify」这种会打爆重建的写法从类型上就被挡住了。
class CspProvisionProgress {
  const CspProvisionProgress({
    this.active = false,
    this.done = 0,
    this.total = 0,
    this.stage = '',
    this.installed = 0,
    this.rejected = 0,
    this.failed = 0,
    this.label = '',
  });

  /// 本轮是否仍在安装。
  final bool active;

  /// 已得出结论的站点数（按 [onEntry] 递增）。
  final int done;

  /// 本轮要装的站点数（即本轮 selected 站点数）。
  final int total;

  /// 当前阶段（来自 [ShellUnpackTick.stage]）；未知时为空串。
  final String stage;

  /// 已装好（含解包装好）的站点数。
  final int installed;

  /// 被拒（静态检测不通过等）的站点数。
  final int rejected;

  /// 失败（取回/解包）的站点数。
  final int failed;

  /// 给用户看的整行文案：含进度与阶段/估算时由状态层拼好，UI 原样显示。
  final String label;

  /// 进度条取值；[total] 为 0 时返回 null（UI 走 indeterminate）。
  double? get fraction => total <= 0 ? null : (done / total).clamp(0.0, 1.0);

  @override
  bool operator ==(Object other) =>
      other is CspProvisionProgress &&
      other.active == active &&
      other.done == done &&
      other.total == total &&
      other.stage == stage &&
      other.installed == installed &&
      other.rejected == rejected &&
      other.failed == failed &&
      other.label == label;

  @override
  int get hashCode => Object.hash(
    active,
    done,
    total,
    stage,
    installed,
    rejected,
    failed,
    label,
  );
}

typedef DirectProbeRunner = Future<Map<String, LocalSpider>> Function(
  AppConfig config,
);

/// 应用状态。
class AppState extends ChangeNotifier implements SyncStateHost {
  AppState({
    AppPaths? paths,
    LogService? log,
    String? sidecarHostPath,
    String? jsSidecarHostPath,
    String? jvmSidecarHostPath,
    LiveService? liveService,
    EpgService? epgService,
    AndroidBridgeService? androidBridgeService,
    AndroidPlaybackBridge? androidPlaybackBridge,
    SyncClient? syncClient,
    SyncServer Function(SyncServerHost host)? syncServerFactory,

    /// 测试注入的实时定时器工厂（`null` = 真实 `Timer`）。
    ///
    /// 与 `syncServerFactory` 同一模式：单测不能创建真实定时器，
    /// 否则用例结束就残留（`design/04` G12）。
    RealtimeScheduler? realtimeScheduler,

    /// 测试注入的安卓只读客户端（`null` = 真实 HTTP）。
    ///
    /// widget 测试不得做真实局域网 I/O，只能靠它接管路径 A 的读取与心跳。
    AndroidReadClient? androidReadClient,

    /// 测试注入的站点 HTTP 客户端（widget/单测不可做真实 socket I/O）。
    /// 与 [liveService]/[epgService] 同一模式：只为可测性开一个口子。
    http.Client? httpClient,

    /// 测试注入的联想/热搜服务（避免单测打真实外网）。
    SearchSuggestService? searchSuggestService,

    /// 测试注入的外部播放器扫描器（`null` = 真实注册表与安装目录探测）。
    List<ExternalPlayer> Function()? externalPlayerDetector,

    /// 测试注入的追番通知器（`null` = 真实 Windows 系统通知）。
    FollowingNotifier? followingNotifier,
    AiContentCompletion? aiContentCompletion,
    AiCompletionClient? aiSeasonClient,
    TmdbService? tmdbService,
    this.warmAutoRoutes = true,
    ExternalMetaService? externalMetaService,
    PythonEnvironment? pythonEnvironment,
    AppUpdateService? updateService,
  }) : paths = paths ?? AppPaths.resolve(),
       _injectedPythonEnvironment = pythonEnvironment,
       _injectedUpdateService = updateService,
       _externalPlayerDetector =
           externalPlayerDetector ?? ExternalPlayers.detect,
       // AI 调用日志的默认 sink：底座持有多处调用点，不能靠每处记得传 log。
       log = AiCompletionClient.defaultLog = log ?? LogService(),
       _injectedLiveService = liveService,
       _injectedEpgService = epgService,
       _injectedBridgeService = androidBridgeService,
       _injectedSyncClient = syncClient,
       _injectedSyncServerFactory = syncServerFactory,
       _injectedReadClient = androidReadClient,
       _injectedSearchSuggestService = searchSuggestService,
       _injectedFollowingNotifier = followingNotifier,
       // ignore: prefer_initializing_formals
       _aiContentCompletion = aiContentCompletion,
       // ignore: prefer_initializing_formals
       _aiSeasonClient = aiSeasonClient,
       // 宿主路径在这里定一次：生效配置与**其它配置**（原来源续播）的
       // `SpiderRouter` 必须用同一套宿主，否则同一站点在两条路径下会落到
       // 两个不同的 sidecar 入口。
       _sidecarHostPath = sidecarHostPath ?? defaultSidecarHostPath(),
       _jsSidecarHostPath = jsSidecarHostPath ?? defaultJsSidecarHostPath(),
       _jvmSidecarHostPath = jvmSidecarHostPath ?? defaultJvmSidecarHostPath() {
    _externalMetaService = externalMetaService;
    // 同一开关在客户端构造前就绪，HTTP 与 IPC 都持有共享引用。
    _spiderDebugLog = SpiderDebugLog(log: this.log);
    if (httpClient != null) {
      // 记住注入的客户端：`bootstrap()` 里的 `_applyOutboundProxy()` 过去会无条件
      // 重建 `_httpClient`，把测试注入的捕获客户端丢掉，导致真实 400。
      // 出站代理未生效时必须保留它；生效时才按代理设置重建。
      _injectedHttpClient = httpClient;
      _httpClient = HttpApiClient(
        client: httpClient,
        debugLog: _spiderDebugLog,
      );
    }
    final cacheDir = this.paths.cacheDir;
    _supervisor = SpiderHostSupervisor(
      workRoot: p.join(cacheDir, 'sidecars'),
      log: this.log,
      debugLog: _spiderDebugLog,
      isSourceEnabled: (key) {
        final spider = _spiderRegistry.byKey(key);
        return spider == null ||
            !isImportedLocalSpider(spider, spiderRoot) ||
            _localSourceEnable.isEnabled(key);
      },
    );
    _spiderRegistry = SpiderManifestRegistry(
      root: p.join(this.paths.configDir, 'spiders'),
      log: this.log,
    );
    // `csp_*` 站点的桌面 jar 缓存：`<config>/spiders/csp/<siteKey>/`（§9.3、ADR-0002）。
    // 与 manifest 注册表同根，但独立子目录：两种站源形态的入口解析规则不同。
    _cspBinding = CspJvmBinding(
      root: p.join(this.paths.configDir, 'spiders', 'csp'),
    );
    _webHomeStore = WebHomeStore(root: p.join(this.paths.configDir, 'webhome'));
    _localSourceEnable = LocalSourceEnableStore(
      path: p.join(this.paths.configDir, 'local_sources.json'),
      log: this.log,
    );
    _spiderAccounts = SpiderAccountStore(
      path: p.join(this.paths.configDir, 'spiders', 'accounts.json'),
    );
    _proxy = LocalProxyServer(log: this.log);
    _androidPlaybackBridge =
        androidPlaybackBridge ?? AndroidPlaybackBridge(log: this.log);
    // 安卓接入与同步（Phase 5）：只装配，不自动启动服务端（P3 默认关闭）。
    syncState = SyncState(
      log: this.log,
      host: this,
      settingsPath: this.paths.settingsPath,
      settingsExporter: (allowSensitive) =>
          exportSyncedSettings(allowSensitive: allowSensitive),
      beginConfigMutation: () {
        final epoch = ++_configMutationEpoch;
        return () => epoch == _configMutationEpoch;
      },
      onBridgeConfigSaved: _acceptCurrentBridgeTmdbCredential,
      bridgeService: _injectedBridgeService,
      client: _injectedSyncClient,
      serverFactory: _injectedSyncServerFactory,
      readClient: _injectedReadClient,
      realtimeScheduler: realtimeScheduler,
    );
    // 把同步状态的变化**转发**到 AppState 自己的监听者。
    //
    // 为什么必须转发：`SettingsPage` 是 `StatelessWidget`，只读 `state.syncState`
    // 但自身不监听；壳层只监听 `AppState`。若不同步，启动时的**自动接入**（在壳层
    // post-frame 里异步完成）不会触发任何重建，用户看到的是设置页还写着「未接入」
    // 而顶栏已经切到「安卓桥接」（用户反馈 2026-10-09：
    // 「重新打开后是自动接入了但是设置页面的状态没有及时更新」）。
    // `AndroidSettingsPage` 自己 `addListener` 所以它是新的，正是这个差异暴露了缺口。
    syncState.addListener(notifyListeners);
    _catBundle = CatBundle(rootDir: p.join(this.paths.dataDir, 'catbundle'));
    // TMDB 服务：配置引用是函数（设置页保存后无需重建服务）。
    //
    // **必须显式传 `cache`**：`TmdbService` 里 `cache == null` 时 `_request` 的
    // `readFirstFresh/readFirstAny/write` 分支全部恒不生效，磁盘缓存等于不存在
    // （用户反馈：「进入详情页貌似没有 TMDB 缓冲，感觉每次都重新查询了」）。
    // 存储根与 EPG 一致，都是 [AppPaths.cacheDir]。
    _tmdbCache = TmdbCache(cacheDir: cacheDir);
    _tmdbService =
        tmdbService ??
        TmdbService(
          config: () => tmdbConfig,
          cache: _tmdbCache,
          routeSelector: _tmdbRoutes,
        );
    // 图片位出错时由 `PosterImage` 回报到这里，判断「单张坏图还是整条线路坏了」。
    // 只装回调，不读配置：构造函数阶段 `settings.json` 还没加载。
    _imageHealthSink = reportTmdbImageFailure;
    TmdbImageHealth.onFailure = _imageHealthSink;
    final node = SidecarRuntimeResolver.resolve('node');
    if (node != null) {
      // 猫源 bundle 自带弹幕服务时自动接上（对齐安卓 `NodeRuntime.danmakuApiUrl()`）：
      // 探测归运行时、优先级归 `resolveDanmakuApi`，这里只转手。
      _catRuntime = CatNodeRuntime(
        nodeCommand: node,
        log: this.log,
        onDanmakuReady: setBundleDanmakuApiUrl,
      );
      _catPipeline = CatImportPipeline(
        bundle: _catBundle,
        runtime: _catRuntime!,
        log: this.log,
      );
    }
    // 导入门面**始终**创建：Node 只服务猫源 bundle 那一条分支（见
    // `ConfigImportService.import`），普通 JSON / T4 配置完全不依赖 Node。
    // 曾经这里跟着 `node != null` 一起创建，于是没有 Node 的机器连普通配置都
    // 被「未检测到 Node 运行时」挡在解析之前（2026-10-31 用户实测）。
    _importService = ConfigImportService(catResolver: _catPipeline?.resolve);
    _router = SpiderRouter(
      client: _httpClient,
      globalHeaders: const [],
      catHttpClient: _catHttpClient,
      registry: _spiderRegistry,
      supervisor: _supervisor,
      log: this.log,
      hostPath: _sidecarHostPath,
      jsHostPath: _jsSidecarHostPath,
      jvmHostPath: _jvmSidecarHostPath,
      cspBinding: _cspBinding,
    );
  }

  final AppPaths paths;

  /// LUT 预设仓库（内置落盘 / 用户目录 / 在线下载）。
  ///
  /// 应用级单例：播放页、底部面板与设置页共用同一个 http.Client 与同一份
  /// 缓存目录，避免三处各自建客户端、各自重扫目录。
  LutStore? _lutStoreInstance;

  LutStore get lutStore => _lutStoreInstance ??= LutStore(paths: paths);
  final LogService log;

  /// 爬虫 IPC 详细调试日志（入参/出参）的开关载体。
  ///
  /// sidecar 进程持有同一个对象，所以切换开关即时生效，不需要重建进程。
  late final SpiderDebugLog _spiderDebugLog;

  /// sidecar 宿主路径（构造时定死，供生效配置与其它配置的路由共用）。
  final String _sidecarHostPath;
  final String _jsSidecarHostPath;
  final String _jvmSidecarHostPath;

  /// 猫源 bundle 下载/缓存（§9 猫源）。
  late final CatBundle _catBundle;

  /// 猫源 Node 运行时；未安装 Node 时为 null（UI 如实报错，不静默跳过）。
  CatNodeRuntime? _catRuntime;

  /// 猫源导入门面；未安装 Node 时为 null（导入门面据此退化为「无猫源分支」）。
  CatImportPipeline? _catPipeline;

  /// 配置导入门面。构造时**无条件**创建——只有猫源 bundle 需要 Node，
  /// 普通 JSON / T4 配置直接走 HTTP 抓取或本地文件读取。
  late final ConfigImportService _importService;
  late HttpApiClient _httpClient = HttpApiClient(debugLog: _spiderDebugLog);

  /// 构造时注入的原始 HTTP 客户端（测试/诊断）。见 `_applyOutboundProxy`。
  http.Client? _injectedHttpClient;

  /// 生效中的 DoH 解析器（Phase 9 P2-8）；未启用时为 null。
  DohResolver? _dohResolver;

  /// 出站传输（代理 + DoH + hosts）的输入签名，用于避免重复重建。
  String? _httpStackSignature;

  /// 隐身模式只提示一次，避免每次进度上报都写日志。
  bool _incognitoNoticeLogged = false;

  /// 会话恢复存储（Phase 9 P2-8）；bootstrap 时创建。
  SessionRecoveryStore? _sessionRecovery;

  /// 「最后一次使用的配置」记忆；bootstrap 时创建。
  LastConfigStore? _lastConfigStore;

  /// bootstrap 读到的记忆（UI 首帧后才据此决定要不要探测桥接设备）。
  LastConfigRecord? _lastConfigRecord;

  /// 恢复桥接源时锁定的设备（横幅要展示设备名与地址）。
  ///
  /// 为什么不回读 deviceHistory：用户重试之前可能清理过历史，而横幅描述的
  /// 是「刚才探测的那台设备」，两者可能是两回事。
  AndroidDevice? _lastConfigPin;

  /// 上一次未正常退出留下的标记；用户处理前一直保留。
  SessionMarker? _pendingRecovery;

  /// 播放上下文的写盘节流（毫秒纪元 + 上一条集标识）。
  int _recoveryWrittenAtMs = 0;
  String _recoveryEpisodeKey = '';

  /// 追番检查服务与调度定时器（Phase 9 P2-1）。
  FollowingService? _followingService;

  /// 播放历史 → 已看集数回写（Phase 9 · 已看口径修正）。
  FollowingProgressService? _followingProgressService;
  Timer? _followingTimer;
  Timer? _followingKickTimer;

  /// 追番新集系统通知（懒建；首次发通知才初始化平台通道）。
  FollowingNotifier? _followingNotifier;

  /// 系统通知降级/发送结果提示（追番页提示条）。
  String _followingNotice = '';

  /// 点击系统通知后待打开的追番身份键（空 = 无待处理请求）。
  String _followingOpenRequestKey = '';

  /// 追剧页上次停留的视角（0 = 列表，1 = 日历）。
  ///
  /// 只存会话内存：合并后两个视角共用一个侧栏入口，壳层切页会重建页面，离开再回来
  /// 不该每次都被打回列表；不落盘——重启回到列表，与合并前的默认口径一致。
  int followingViewIndex = 0;

  late final CatHttpClient _catHttpClient = CatHttpClient(
    debugLog: _spiderDebugLog,
  );
  late final SpiderRouter _router;
  late final AndroidPlaybackBridge _androidPlaybackBridge;

  /// 测试注入的直播服务（用于避免 UI 测试在 fake-async 区做真实 socket I/O）。
  final LiveService? _injectedLiveService;

  /// 测试注入的 EPG 服务（同上：widget 测试不可做真实 socket I/O）。
  final EpgService? _injectedEpgService;

  /// 测试注入的安卓桥接服务（widget 测试不可做真实 socket I/O）。
  final AndroidBridgeService? _injectedBridgeService;

  /// 测试注入的同步客户端（同上）。
  final SyncClient? _injectedSyncClient;

  /// 测试注入的服务端工厂（widget 测试需固定到回环与测试端口区间）。
  final SyncServer Function(SyncServerHost host)? _injectedSyncServerFactory;

  /// 测试注入的安卓只读客户端（widget 测试不得做真实局域网 I/O）。
  final AndroidReadClient? _injectedReadClient;

  /// 测试注入的追番通知器（`null` = 真实 Windows 系统通知）。
  final FollowingNotifier? _injectedFollowingNotifier;

  /// 直播源加载服务（§13.1）。懒加载：未打开直播页前不建立连接。
  LiveService? _liveService;

  /// EPG（电子节目单）服务（§13.1、§13.3）。懒加载，与直播页同生命周期。
  EpgService? _epgService;

  /// sidecar 宿主（§9.8）。按站点隔离进程、限制资源并按指数退避重试。
  late final SpiderHostSupervisor _supervisor;

  /// 本地 Spider manifest 注册表（§9.7）。
  late final SpiderManifestRegistry _spiderRegistry;

  /// `csp_*` 站点的桌面 jar 缓存绑定（§9.3 `tvbox-java-v1`、ADR-0002）。
  late final CspJvmBinding _cspBinding;

  /// 本地 HTML 首页注入（webHome）登记表：`<config>/webhome`。
  ///
  /// 与 `spiders/` 分开：webHome 由 WebView2 承载，不是 `webhtv-ipc-v1`
  /// 运行时，混进 manifest 注册表会让站点可用性判定出现「未知 runtime」。
  late final WebHomeStore _webHomeStore;

  /// 本地 py/js 源的启用状态（`<configDir>/local_sources.json`）。
  ///
  /// HTML 源的启用状态不在这里：它是 `webhome/registry.json` 的一部分。
  /// 两套存储由 [localSourceEnabled]/[setLocalSourceEnabled] 统一成一个接缝。
  late final LocalSourceEnableStore _localSourceEnable;

  /// 应用级手动网盘账号：`<configDir>/spiders/accounts.json`。
  ///
  /// 与 JVM 站源启动参数 `-Dwebhtv.accountStore` 指向同一文件。
  late final SpiderAccountStore _spiderAccounts;

  /// 本地源扫描器（只读、不执行）。无状态，参数取自 [LocalSpiderScanner] 默认值。
  final LocalSpiderScanner _localScanner = const LocalSpiderScanner();

  /// 上次扫描的文件夹（仅本次会话记忆，避免用户每次重新选）。
  String _lastLocalScanFolder = '';

  /// 本地代理(§11)。默认只监听 127.0.0.1,按需启动。
  late final LocalProxyServer _proxy;

  /// 本次播放的代理会话（§11.3.1）。
  ProxySession? _proxySession;
  SpiderProxySession? _jvmProxySession;
  int _proxyPlaybackEpoch = 0;

  AppDatabase? _database;

  /// 直连 js/py 站点自动注册器（Phase 9 P1-7）。每次调用新建，内部无状态。
  DirectSpiderRegistrar _directRegistrar() => DirectSpiderRegistrar(
    root: _spiderRegistry.root,
    registry: _spiderRegistry,
    log: log,
  );

  /// 扫描配置里的直连 js/py 站点并注册（幂等；哈希一致不重复下载）。
  Future<int> registerDirectSpiders() async {
    final result = await _kickDirectRegistration();
    return result.length;
  }

  /// 注入站点（`README.md` P1-2）：与配置记录分开存放，读取时合并。
  List<InjectedSiteEntry> _injectedSites = const [];

  /// 本地导入源（`spiders/local/<key>/` + 启用的 `webhome/<key>/`）构造出的站点
  /// 条目缓存。注册表或 webHome 登记表变化时由 [_invalidateLocalSites] 置空。
  List<Site>? _localSitesCache;
  final Set<String> _pendingLocalImports = {};
  Map<String, WebHomeSource>? _webHomeSourcesCache;
  String? _webHomeLoadError;
  String? _webHomeLoadErrorDetail;

  /// 登记表严格读取失败的原因；内部降级不代表登记表为空，也不会写回。
  String? get webHomeLoadError => _webHomeLoadError;

  /// 失败原因原文（不含前缀）：页面需要按自己的措辞展示，避免两处前缀叠加。
  String? get webHomeLoadErrorDetail => _webHomeLoadErrorDetail;

  Map<String, WebHomeSource> _safeWebHomeSources() {
    final cached = _webHomeSourcesCache;
    if (cached != null) return cached;
    try {
      final sources = _webHomeStore.list();
      _webHomeLoadError = null;
      _webHomeLoadErrorDetail = null;
      return _webHomeSourcesCache = {
        for (final source in sources)
          if (source.enabled) source.key: source,
      };
    } on FormatException catch (error) {
      _recordWebHomeLoadError(error);
    } on FileSystemException catch (error) {
      _recordWebHomeLoadError(error);
    }
    return _webHomeSourcesCache = const {};
  }

  /// 因同 key 冲突被拒绝的本地 key（用户配置 / JSON 注入优先），供界面如实报告。
  List<String> _localSourceConflicts = const [];

  /// 合并后的配置缓存；配置或注入变化时置空。
  AppConfig? _effectiveConfigCache;
  ConfigRecord? _activeRecord;
  AppConfig? _config;
  SiteService? _siteService;

  /// 安卓接入与同步状态（`docs/phase5/design/02`）。
  ///
  /// 默认全部关闭（P3）；设置落在 `<configDir>/settings.json` 的 `sync` 段
  /// （与 TMDB 同一份文件，各自保留对方的值）。
  late final SyncState syncState;

  StartupInfo? _startupInfo;
  List<String> _storageWarnings = const [];
  LoadPhase _configPhase = LoadPhase.idle;
  LoadPhase _contentPhase = LoadPhase.idle;
  LoadPhase _detailPhase = LoadPhase.idle;
  AppError? _lastError;
  AppError? _detailError;
  String? _notice;

  Site? _selectedSite;
  SiteResult? _homeResult;
  SiteResult? _categoryResult;
  SiteResult? _detailResult;
  Vod? _selectedVod;
  String? _selectedTypeId;

  /// 当前分类的筛选条件（`filter.key → 选中值`，`§7.4.7`）。
  ///
  /// **切分类时保留**（TVBox/猫影视惯例）：用户选了「2024 年」，换一个分类后
  /// 仍按 2024 筛，而不是让他重新选一遍。仅当**换站点**或**回首页**时清空。
  Map<String, String> _categoryFilters = const {};

  /// 分类分页状态（滚动加载，§7.4.7 分页）。
  ///
  /// 早期实现用「上一页/下一页」按钮，每加载一页就把 `_categoryResult` **整体
  /// 替换**；改成滚动加载后必须把多页**累加**在同一份结果里，否则滚到底加载第 2
  /// 页会把第 1 页从屏幕上抹掉（用户看到列表“跳回顶部且内容变了”）。
  int _categoryPage = 1;
  bool _categoryHasMore = false;
  bool _categoryLoadingMore = false;

  /// 分类请求运行号：切分类 / 换筛选 / 换站点后，在途的下一页响应必须丢弃。
  ///
  /// 没有它时，用户「切到别的分类」与「上一分类第 2 页的响应」会赛跑：迟到
  /// 的追加会把旧分类的内容拼到新分类列表后面。
  int _homeRunId = 0;
  int _categoryRunId = 0;

  List<ConfigRecord> _configs = const [];
  String? _importDiagnosticsSummary;

  /// 并发搜索：递增的运行号，用于丢弃被取代批次的结果。
  int _searchRunId = 0;

  /// 详情请求：递增的运行号，用于丢弃被取代请求的结果（§8.3）。
  ///
  /// 详情页是唯一一处把**页面状态放在全局 AppState** 里的地方，用户又经常
  /// 「返回列表 → 立刻点另一部剧」，于是详情请求天然会并发。没有运行号时，
  /// 先返回的响应会被后返回的覆盖，而详情页读的是全局结果，用户就会看到
  /// 上一部剧的信息。
  int _detailRunId = 0;

  /// 站源可能重写 vod_id，返回条目的 ID 不能作为页面归属依据；
  /// 保留请求目标，只有本页发起的详情才认领，避免上一部剧串入。
  String _detailRequestVodId = '';
  MultiSiteSearchOutcome? _activeSearch;
  final Set<RequestCancellation> _searchRequests = {};
  List<String> _searchHistory = const [];

  /// 分页状态：站点 key → 已加载页数 / 总页数 / 已见页指纹（§14.1 分页搜索）。
  ///
  /// 单个实例跨站点统一管理（上游 `SearchPageState` 同样的形态）：页码与
  /// 「内容重复即耗尽」的判定需要按站点隔离，但生命周期与搜索批次一致。
  final SearchPagingState _searchPaging = SearchPagingState();

  /// 测试注入的联想/热搜服务；null 时懒构造真实实例。
  final SearchSuggestService? _injectedSearchSuggestService;

  /// 联想/热搜服务：首次访问时构造，缓存目录与站点缓存同域。
  SearchSuggestService? _searchSuggestService;

  /// 联想/热搜服务（懒构造，测试可注入）。
  SearchSuggestService get searchSuggestService => _searchSuggestService ??=
      _injectedSearchSuggestService ??
      SearchSuggestService(
        log: log,
        cacheDir: p.join(paths.cacheDir, 'search'),
      );

  /// 当前生效的搜索相似度阈值（0~100；0 = 不过滤）。
  ///
  /// 默认取 UI 偏好里存的值（未设置时 30，对齐上游安卓）；测试注入也不受影响。
  int get searchSimilarity => _uiPreferences?.searchSimilarity ?? 30;

  /// 当前生效的**搜索并发线程数**（1~100）。
  ///
  /// 对齐上游安卓 `Setting.getSearchThread()`（默认 20，夹在 1~100）：
  /// 并发度直接决定「搜一轮要等多久」，但太高会打满对端或触发限流，
  /// 所以做成设置项而不是写死。
  int get searchThread => _uiPreferences?.searchThread ?? 20;

  /// 最近一次播放决策，供播放器页与日志页展示。
  PlaybackDecision? _lastDecision;

  /// 最近一次播放诊断（§23），供日志页展示与复制。
  PlaybackDiagnostics? _lastDiagnostics;

  // ---------------------------------------------------------------- TMDB
  //
  // 模块边界（`docs/phase4/design/04` §2）：UI 不直接发 TMDB 请求，全部经此处。
  // TMDB 配置落在 `<configDir>/settings.json`（`03` §5.3），**不进配置 JSON**。

  late final TmdbConfigStore _tmdbConfigStore = TmdbConfigStore(
    path: paths.settingsPath,
    log: log,
  );

  /// 订阅级 TMDB 凭据（仅进程内存，按配置身份/代际隔离）。
  final TmdbSubscriptionCredentials _tmdbSubscription =
      TmdbSubscriptionCredentials();
  int _configMutationEpoch = 0;

  /// 启动后台刷新的「同一进程只跑一轮」闸门（null = 还没发起）。
  Future<void>? _startupConfigRefresh;

  /// AI 配置（`docs/phase6/design/04` §4）。
  ///
  /// 与 `_tmdbConfigStore` 同构（两者都是 `settings.json` 里带凭据的独立段）。
  /// `late final`：在 `bootstrap` 里装配；未 bootstrap 时访问会抛
  /// `LateInitializationError`（单测走 `attachAiConfigStore`
  /// 或 `bootstrap`）。
  late AiConfigStore _aiConfigStore;

  /// UI 偏好（最近使用的站点）。在 [bootstrap] 里装配。
  ///
  /// 可空而不是 `late final`：单元测试/工具可能**不调 bootstrap** 就直接
  /// `importConfig` + `selectSite`（实测 `phase2_search_test.dart` 就是这样），
  /// 用 `late final` 会在 `selectSite` 里抛 `LateInitializationError`。
  /// 记住站点只是**锦上添花**，它不可用时应安静降级，而不是把选站点弄崩。
  UiPreferencesStore? _uiPreferences;

  // --- 应用更新（ADR-0015） ---
  /// 测试注入的更新服务（null = 真实 GitHub 客户端，按当前出站代理构造）。
  final AppUpdateService? _injectedUpdateService;
  AppUpdateService? _updateService;
  UpdatePreferencesStore? _updatePreferencesStore;
  AppUpdatePreferences _updatePreferences = AppUpdatePreferences.defaults;
  AppUpdateCheck? _updateCheck;
  Future<AppUpdateCheck>? _updateCheckFuture;
  bool _updateChecking = false;
  String? _updateNotice;
  AppUpdateDownload? _updateDownload;
  bool _updateDownloading = false;
  int _updateDownloadReceived = 0;
  int? _updateDownloadTotal;
  int _updateProgressNotifiedBytes = -1;
  String? _updateDownloadError;
  AppUpdateInstallResult? _updateInstallResult;
  bool _updateInstalling = false;
  static const int _updateProgressStepBytes = 256 * 1024;
  final List<ExternalPlayer> Function() _externalPlayerDetector;
  late final TmdbService _tmdbService;

  /// TMDB 磁盘缓存（文件落在 `TmdbCache.directory` = `<cache>/tmdb`）。
  ///
  /// 为什么在这里留一份引用：`TmdbService` 不暴露它手里的缓存实例，而「缓存到底
  /// 接没接上」正是这次修复的核心——历史上就是构造服务时漏了 `cache` 参数，
  /// 整个磁盘缓存静默失效而没人发现。测试只能从这里断言接线真的发生了。
  late final TmdbCache _tmdbCache;

  /// 启动时是否真的去测速自动线路（测试可关；生产恒为 true）。
  final bool warmAutoRoutes;

  /// 本实例装进 [TmdbImageHealth] 的回调：dispose 时只摘自己那一个，
  /// 不把同进程里另一个 AppState（测试常这么做）的回报口一起清掉。
  void Function(String url)? _imageHealthSink;

  /// TMDB 线路健康表（自动线路用）。API 与图片各自独立计健康。
  final TmdbRouteSelector _tmdbRoutes = TmdbRouteSelector();

  /// 自动图片线路的解析缓存：按 [TmdbRouteSelector.version] 失效。
  String _resolvedImageRoute = tmdbImageAutoCandidates.first;
  int _resolvedImageRouteVersion = -1;

  /// 图片失败回报的时间窗（自动线路的失败切换防抖）。
  final Map<String, List<DateTime>> _imageRouteFailures = {};
  DateTime? _lastAutoProbeAt;

  /// 仅供测试：断言 TMDB 服务确实拿到了磁盘缓存（目录指向 [paths] 的缓存根）。
  @visibleForTesting
  TmdbCache get tmdbCacheForTest => _tmdbCache;
  TmdbIdentityService? _tmdbIdentityService;
  TmdbSeasonService? _tmdbSeasonService;
  TmdbEnrichmentService? _tmdbEnrichmentService;
  TmdbState? _tmdbState;

  /// 用户设置中的 TMDB 配置；设置页、导出与同步只能读写这一份。
  TmdbConfig get tmdbUserConfig => _tmdbConfigStore.config;

  /// 所有实际 TMDB 消费者使用的有效配置。
  ///
  /// 用户 apiKey/accessToken 已就绪时完全优先；否则只读地叠加当前配置作用域内的
  /// 订阅凭据。订阅凭据不进入设置、配置记录、导出或日志。
  TmdbConfig get tmdbConfig {
    final user = tmdbUserConfig;
    if (user.apiKey.trim().isNotEmpty || user.accessToken.trim().isNotEmpty) {
      return _withResolvedAutoRoutes(user);
    }
    final record = _activeRecord;
    final key = _tmdbSubscription.snapshot(
      record?.id ?? 0,
      record == null ? '' : sourceKeyOfRecord(record),
      _tmdbSubscription.epoch,
    );
    if (key.isEmpty) return _withResolvedAutoRoutes(user);
    return _withResolvedAutoRoutes(user.withSubscriptionApiKey(key));
  }

  /// 自动图片线路在**读取时**解析成具体地址。
  ///
  /// 为什么放在这一处：海报与后景的 URL 都由 `config.imageBase` /
  /// `backdropBase` 直接拼出来，消费点有十几处；解析放在这里，所有消费者
  /// （服务、详情、首页取图、推荐）拿到的就已经是同一条线路，不必各自认识「自动」。
  TmdbConfig _withResolvedAutoRoutes(TmdbConfig config) {
    if (!tmdbIsAutoRoute(config.imageBase)) return config;
    if (_resolvedImageRouteVersion != _tmdbRoutes.version) {
      _resolvedImageRouteVersion = _tmdbRoutes.version;
      _resolvedImageRoute = _tmdbRoutes.preferred(
        TmdbRouteKind.image,
        tmdbImageAutoCandidates,
      );
    }
    return config.copyWith(
      imageBase: tmdbImageBaseOf(_resolvedImageRoute, 'w342'),
      backdropBase: tmdbImageBaseOf(
        _resolvedImageRoute,
        tmdbDefaultBackdropSize,
      ),
    );
  }

  /// 设置页要显示的「当前实际线路」（自动模式是已解析的那一条）。
  TmdbRouteStatus tmdbRouteStatus() {
    final configured = tmdbUserConfig;
    final effective = tmdbConfig;
    final apiAuto = tmdbIsAutoRoute(configured.apiBase);
    return TmdbRouteStatus(
      apiBase: apiAuto
          ? tmdbApiBaseOf(
              _tmdbRoutes.preferred(TmdbRouteKind.api, tmdbApiAutoCandidates),
            )
          : effective.apiBase,
      imageBase: effective.imageBase,
      apiAuto: apiAuto,
      imageAuto: tmdbIsAutoRoute(configured.imageBase),
    );
  }

  /// 自动线路测速：给图片候选各取一张公共海报，把延迟与可达性记进选择器。
  ///
  /// 只测图片：API 的延迟来自真实请求（成功即记账、失败进冷却），单独探一次
  /// 还要凭据，意义不大。返回一句人话给设置页。
  Future<String> refreshTmdbAutoRoutes() async {
    if (!_tmdbConfigStore.loaded) return 'TMDB 设置尚未加载';
    if (!tmdbIsAutoRoute(tmdbUserConfig.imageBase)) return '当前不是自动线路';
    for (final route in tmdbImageAutoCandidates) {
      final probe = await _tmdbService.probeImageRoute(route);
      if (probe.ok) {
        _tmdbRoutes.success(TmdbRouteKind.image, route, probe.elapsed);
      } else {
        _tmdbRoutes.failure(TmdbRouteKind.image, route);
      }
    }
    _lastAutoProbeAt = DateTime.now();
    _notifyIfAlive();
    final best = _tmdbRoutes.preferred(
      TmdbRouteKind.image,
      tmdbImageAutoCandidates,
    );
    final latency = _tmdbRoutes.latencyOf(TmdbRouteKind.image, best);
    final host = Uri.tryParse(best)?.host ?? best;
    final ms = latency == null ? '未测到' : '${latency.inMilliseconds} ms';
    log.info('TMDB 图片自动线路：$host（$ms）', scope: 'tmdb');
    return '自动线路已测速：$host · $ms';
  }

  /// 图片加载失败的回报入口（自动线路的失败切换）。
  ///
  /// 单张坏图（被删掉的海报、404）不代表线路坏，因此要求 **60 秒内同一线路
  /// 连续两张**失败才切换；切换后异步重测一次，让排序反映真实延迟。
  void reportTmdbImageFailure(String url) {
    if (!_tmdbConfigStore.loaded) return;
    if (!tmdbIsAutoRoute(tmdbUserConfig.imageBase)) return;
    final route = tmdbImageRouteOfUrl(url, tmdbImageAutoCandidates);
    if (route == null) return;
    final now = DateTime.now();
    final failures = _imageRouteFailures.putIfAbsent(route, () => <DateTime>[]);
    failures.add(now);
    failures.removeWhere(
      (at) => now.difference(at) > const Duration(seconds: 60),
    );
    if (failures.length < 2) return;
    failures.clear();
    _tmdbRoutes.failure(TmdbRouteKind.image, route);
    _notifyIfAlive();
    final last = _lastAutoProbeAt;
    if (last != null && now.difference(last) < const Duration(seconds: 30)) {
      return;
    }
    unawaited(refreshTmdbAutoRoutes());
  }

  void _beginCurrentTmdbCredentialScope() {
    final record = _activeRecord;
    _tmdbSubscription.beginScope(
      record?.id ?? 0,
      record == null ? '' : sourceKeyOfRecord(record),
    );
  }

  /// 只在配置已成功提交后接收候选；写入相同作用域后才对外可见。
  void _acceptImportedTmdbCredential(
    ImportedConfig imported,
    int configId,
    String sourceKey,
  ) {
    final epoch = _tmdbSubscription.beginScope(configId, sourceKey);
    final accepted = _tmdbSubscription.accept(
      imported.tmdbApiKeyCandidate,
      configId,
      sourceKey,
      epoch,
    );
    if (imported.tmdbApiKeyCandidate.isNotEmpty) {
      log.info(
        'TMDB 订阅凭据已接收 accepted=$accepted scope=$configId',
        scope: 'tmdb',
      );
    }
  }

  void _acceptCurrentBridgeTmdbCredential(int recordId, String candidate) {
    if (_activeRecord?.id != recordId) return;
    final current = _database?.activeConfig();
    if (current == null || current.id != recordId) return;
    final sourceKey = sourceKeyOfRecord(current);
    final epoch = _tmdbSubscription.beginScope(recordId, sourceKey);
    _tmdbSubscription.accept(candidate, recordId, sourceKey, epoch);
    _activeRecord = current;
  }

  AppError _staleConfigMutation() =>
      AppError(AppErrorKind.configInvalid, '配置操作已被更新的操作取代', retryable: true);

  /// AI 配置（`docs/phase6/design/04` §4）。
  AiConfig get aiConfig => _aiConfigStore.config;

  /// AI 服务是否就绪（季度弹窗据此决定 AI 项是分析还是引导去设置）。
  bool get aiReady => aiConfig.isReady;
  bool get aiTitleExtractionEnabled =>
      _uiPreferences?.aiTitleExtractionEnabled ?? false;
  Map<String, Object?> get audioAiSettings =>
      _uiPreferences?.androidAiRaw ?? const {};
  Future<bool> saveAudioAiSettings(Map<String, Object?> values) async {
    final ok =
        await _uiPreferences?.rememberAiIntegrationSettings(values) ?? false;
    _notifyIfAlive();
    return ok;
  }

  bool get aiAdDetectionEnabled =>
      _uiPreferences?.aiAdDetectionEnabled ?? false;
  final AiContentCompletion? _aiContentCompletion;
  final AiCompletionClient? _aiSeasonClient;
  AiEpisodeSeasonService createAiSeasonService() =>
      AiEpisodeSeasonService(config: aiConfig, client: _aiSeasonClient);
  AiIntegration? _aiIntegration;
  AiIntegration get aiIntegration => _aiIntegration ??= AiIntegration(
    paths: paths,
    config: () => aiConfig,
    titleEnabled: () => aiTitleExtractionEnabled,
    completion: _aiContentCompletion,
    log: log,
    enricher: (items) async {
      final result = <RecommendationEnrichment?>[];
      for (final item in items) {
        try {
          final type = item.mediaType == RecommendationMediaType.tv
              ? TmdbMediaType.tv
              : TmdbMediaType.movie;
          final match = pickRecommendationTmdbItem(
            await _tmdbService.search(item.title),
            item.title,
            type,
            item.year,
          );
          result.add(
            match == null
                ? null
                : RecommendationEnrichment(
                    tmdbId: match.tmdbId,
                    mediaType: item.mediaType,
                    posterUrl: match.posterUrl,
                    overview: match.overview,
                    rating: match.tmdbRating,
                  ),
          );
        } catch (error) {
          log.warning('推荐富集失败 title=${item.title} error=$error', scope: 'ai');
          result.add(null);
        }
      }
      return result;
    },
  );

  Future<bool> setAiTitleExtractionEnabled(bool enabled) async {
    final ok =
        await _uiPreferences?.rememberAiIntegrationSettings({
          'ai_title_extraction': enabled,
        }) ??
        false;
    _notifyIfAlive();
    return ok;
  }

  Future<bool> setAiAdDetectionEnabled(bool enabled) async {
    final ok =
        await _uiPreferences?.rememberAiIntegrationSettings({
          'ai_ad_detection': enabled,
        }) ??
        false;
    if (!enabled) clearAiAdApplication();
    _notifyIfAlive();
    return ok;
  }

  Future<String?> resolveBusinessTitle(
    String rawTitle, {
    String siteKey = '',
    String vodId = '',
    String vodRemarks = '',
  }) async {
    if (!aiTitleExtractionEnabled || !aiReady) return null;
    final result = await aiIntegration.title.resolve(
      TitleQuery(
        rawTitle: rawTitle,
        siteKey: siteKey,
        vodId: vodId,
        vodRemarks: vodRemarks,
      ),
    );
    final title = result.value;
    return result.ok &&
            title != null &&
            title.confidence >= .8 &&
            title.title.trim().isNotEmpty
        ? title.title
        : null;
  }

  Future<bool> learnBusinessTitle({
    required String rawTitle,
    required String confirmedTitle,
    required String siteKey,
    required String vodId,
    String? mediaType,
    int? year,
  }) async {
    if (rawTitle.trim().isEmpty || confirmedTitle.trim().isEmpty) return false;
    final old = await aiIntegration.userData.loadLearning();
    final query = TitleQuery(
      rawTitle: rawTitle,
      siteKey: siteKey,
      vodId: vodId,
    );
    final updated = old.record(
      query,
      TitleLearningExample(
        rawTitle: rawTitle,
        resolvedTitle: confirmedTitle,
        siteKey: siteKey,
        vodId: vodId,
        mediaType: TitleMediaTypeHint.parse(mediaType),
        year: year,
      ),
      now: DateTime.now(),
    );
    return aiIntegration.userData.saveLearning(updated);
  }

  Future<bool> applyAiGroupRules(List<GroupRuleProposal> proposals) async {
    final approved = await aiIntegration.group.approve(proposals);
    if (!approved.ok || approved.value == null) return false;
    return setSiteGroupSettings(
      mergeAiGroupRules(siteGroupSettings, approved.value!),
    );
  }

  List<AdRuleProposal> _sessionAiAdRules = const [];
  void clearAiAdApplication() {
    _aiAdApplyTicket++;
    _sessionAiAdRules = const [];
    _proxy.aiSessionFingerprint = null;
    _proxy.aiSessionRules = const AdRuleSet.empty();
    _applyAdRulesToProxy();
  }

  int _aiAdApplyTicket = 0;

  /// 开始在途的广告确认提交；返回本次提交票据。
  int startAiAdApply() => ++_aiAdApplyTicket;

  /// 撤销所有在途提交（关闭/取消对话框时调用）。
  void cancelAiAdApply() => _aiAdApplyTicket++;

  bool _aiAdTicketValid(int ticket) => ticket == _aiAdApplyTicket;

  AiPlaylistSnapshot? aiPlaylistFor(String siteKey) {
    final fingerprint = _proxySession?.fingerprint;
    if (fingerprint == null) return null;
    final snapshot = _proxy.mediaPlaylistFor(fingerprint);
    return snapshot?.siteKey == siteKey ? snapshot : null;
  }

  Future<void> importAiUserData(String raw) async {
    await importAiUserFiles(paths, raw);
    _aiIntegration = null;
    clearAiAdApplication();
    _notifyIfAlive();
  }

  Future<MultiSiteSearchOutcome?> searchRecommendation(String title) async {
    if (_siteService == null) return null;
    final site = selectedSite;
    if (site != null) {
      final outcome = await searchAll(title, siteKey: site.key);
      if (outcome.cancelled || !identical(outcome, _activeSearch)) {
        return outcome;
      }
      if (outcome.totalItems > 0) return outcome;
    }
    return searchAll(title);
  }

  Future<bool> applyAiAdRule(
    AdRuleAssessment assessment, {
    required AdDetectionContext context,
    required AdPlaylistEvidence evidence,
    required Uri playlist,
    required int ticket,
  }) async {
    if (!_aiAdTicketValid(ticket)) return false;
    if (!aiAdDetectionEnabled ||
        !aiReady ||
        context.urlHost != playlist.host ||
        context.urlPath != playlist.path) {
      return false;
    }
    final snapshot = aiPlaylistFor(context.siteKey);
    if (snapshot == null ||
        snapshot.playlist != playlist ||
        jsonEncode(snapshot.evidence.segments) !=
            jsonEncode(evidence.segments)) {
      return false;
    }
    final approved = await aiIntegration.ad.approve(
      assessment,
      context: context,
      evidence: evidence,
    );
    // 用户在 approve 在途期间关闭/取消、换集或关掉开关：结果作废，
    // 不得在 await 之后悄悄把规则装进代理。
    if (!_aiAdTicketValid(ticket) ||
        !aiAdDetectionEnabled ||
        !aiReady ||
        aiPlaylistFor(context.siteKey)?.signature != snapshot.signature) {
      return false;
    }
    if (!approved.ok || approved.value == null) return false;
    // Other stored candidates have not been approved for this playback.
    final checked = aiIntegration.ad.assessForApplication(
      assessment.proposal!,
      context: context,
      evidence: evidence,
    );
    if (!checked.applicable || !_aiAdTicketValid(ticket)) return false;
    _sessionAiAdRules = [checked.proposal!];
    _proxy.aiSessionFingerprint = snapshot.sessionFingerprint;
    _proxy.aiSessionRules = mergeAiAdRules(
      const AdRuleSet.empty(),
      _sessionAiAdRules,
      playlist,
    );
    _applyAdRulesToProxy();
    return true;
  }

  String _aiTmdbSiteKey = '';
  String get tmdbSiteKeyForAi => _aiTmdbSiteKey;
  int _aiLoadRun = 0;
  final Map<String, AiSeasonBindingsResult> _aiSeasonBindings = {};
  final Map<String, String> _aiSeasonSnapshots = {};

  /// AI 季度绑定的容量上限。
  ///
  /// 为什么是这个量级：键里带「配置|站点|影片|线路」，一个详情页实测最多十几条
  /// 线路，128 条足够覆盖同一会话里来回切线路、换源、几部剧来回比较的全部记录，
  /// 同时挡住异常配置（比如线路 flag 每帧都变）把两张表撑成无界内存。
  static const int _aiSeasonBindingCapacity = 128;

  /// 集级手动匹配的内存缓存：键与 AI 绑定同口径（配置|站点|影片|标题|线路）。
  ///
  /// 与 AI 表不同，这里**不做整批快照失效**：锚点自带 `sourceName`，
  /// 每次刷新按名重定位、逐条判定失效（见 `EpisodeManualMatch.relocate`），
  /// 因此线路小改（后段加集）不会把用户的人工结论整批丢掉。
  final Map<String, List<EpisodeMatchAnchor>> _manualEpisodeAnchors = {};
  final Map<String, int> _manualEpisodeDropped = {};

  /// 手动锚点缓存容量：与 [_aiSeasonBindingCapacity] 同一量级与淘汰口径。
  static const int _manualEpisodeCapacity = 128;

  /// 记一对「绑定结果 + 线路快照」，超限时按写入顺序淘汰最旧的一条。
  ///
  /// 两张表必须同进同出：只淘汰一张会留下没有绑定的快照，读侧
  /// （[aiMappingsFor]）虽然仍能判出「快照变了」，但会积累永远命中不到的死数据。
  /// 淘汰的永远是最早写入的键——当前影片是刚写进来的，不会被淘汰，
  /// 所以正在看的这部剧的季/集判定不受影响。
  void _rememberAiSeasonBinding(
    String key,
    AiSeasonBindingsResult result,
    String snapshot,
  ) {
    if (_aiSeasonBindings.length >= _aiSeasonBindingCapacity &&
        !_aiSeasonBindings.containsKey(key)) {
      final oldest = _aiSeasonBindings.keys.first;
      _aiSeasonBindings.remove(oldest);
      _aiSeasonSnapshots.remove(oldest);
    }
    _aiSeasonBindings[key] = result;
    _aiSeasonSnapshots[key] = snapshot;
  }

  String _aiLineKey(Vod vod, VodPlayLine line) =>
      '$tmdbConfigId|$_aiTmdbSiteKey|${vod.vodId}|${vod.vodName}|${line.flag}';

  /// 原始线路的聚合组：手动锚点的**身份口径**。
  ///
  /// 必须用未套任何绑定的线路算：锚点靠 `sourceName` 定位，先写 extra 再算组
  /// 会让分组依赖绑定结果（自指）。聚合开关、倒序、区间都不改变这里的结果。
  List<EpisodeGroup> _rawGroupsOf(VodPlayLine line) =>
      EpisodeAggregation.build(line.episodes, scope: line.flag);

  List<EpisodeMatchAnchor> manualEpisodeAnchorsFor(Vod vod, VodPlayLine line) =>
      _manualEpisodeAnchors[_aiLineKey(vod, line)] ?? const [];

  int manualEpisodeDroppedFor(Vod vod, VodPlayLine line) =>
      _manualEpisodeDropped[_aiLineKey(vod, line)] ?? 0;

  /// 手动锚点铺开后的逐集目标（未命中任何锚点的集不出现）。
  Map<int, EpisodeMatchTarget> manualEpisodeTargetsFor(
    Vod vod,
    VodPlayLine line,
  ) {
    final anchors = manualEpisodeAnchorsFor(vod, line);
    if (anchors.isEmpty) return const {};
    return EpisodeManualMatch.resolve(
      groups: _rawGroupsOf(line),
      anchors: anchors,
      seasonEpisodeCounts: tmdb.seasonEpisodeCounts,
    );
  }

  /// 生效的逐集绑定：**手动锚点 > AI 逐集绑定**（AI 没覆盖到的集才用 AI）。
  Map<int, ({int season, int episode})> episodeBindingsFor(
    Vod vod,
    VodPlayLine line,
  ) {
    final bindings = <int, ({int season, int episode})>{
      for (final entry in manualEpisodeTargetsFor(vod, line).entries)
        entry.key: (
          season: entry.value.seasonNumber,
          episode: entry.value.episodeNumber,
        ),
    };
    final ai = aiMappingsFor(vod, line);
    if (ai != null) {
      for (final binding in ai.bindings) {
        bindings.putIfAbsent(
          binding.sourceIndex,
          () => (season: binding.seasonNumber, episode: binding.episodeNumber),
        );
      }
    }
    return bindings;
  }

  bool hasEpisodeBindings(Vod vod, VodPlayLine line) =>
      episodeBindingsFor(vod, line).isNotEmpty;

  VodPlayLine applyEpisodeBindingsToLine(Vod vod, VodPlayLine line) {
    final bindings = episodeBindingsFor(vod, line);
    if (bindings.isEmpty) return line;
    return applyAiEpisodeBindings(line, bindings);
  }

  /// 旧名兼容：绑定现在是「手动 + AI」的合并结果，语义比原来更宽。
  VodPlayLine applyAiMappingsToLine(Vod vod, VodPlayLine line) =>
      applyEpisodeBindingsToLine(vod, line);

  bool hasAiMappings(Vod vod, VodPlayLine line) =>
      hasEpisodeBindings(vod, line);
  AiSeasonBindingsResult? aiMappingsFor(Vod vod, VodPlayLine line) {
    final key = _aiLineKey(vod, line);
    if (_aiSeasonSnapshots[key] !=
        seasonBindingsSnapshot(line.episodes, tmdb.seasonEpisodeCounts)) {
      return null;
    }
    return _aiSeasonBindings[key];
  }

  Future<void> refreshAiSeasonMappings(
    Vod vod, {
    required String siteKey,
  }) async {
    final db = _database;
    if (db == null || !tmdb.belongsTo(vod.vodId)) return;
    final generation = tmdb.generation;
    final detailGeneration = _detailRunId;
    final service = AiSeasonMappingService(database: db);
    final lines = playLinesOf(vod);
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final flagKey = TmdbState.sourceLineOf(
        line,
        i,
        unique: lines.where((l) => l.flag == line.flag).length == 1,
      ).flagKey;
      final row = db.findAiSeasonMappings(
        configId: tmdbConfigId,
        siteKey: siteKey,
        vodId: vod.vodId,
        sourceTitle: vod.vodName,
        flagKey: flagKey,
      );
      if (row != null &&
          (row['tmdb_id'] != (tmdb.identity?.tmdbId ?? 0) ||
              row['media_type'] != (tmdb.identity?.mediaType.name ?? ''))) {
        service.clearMappings(
          configId: tmdbConfigId,
          siteKey: siteKey,
          vodId: vod.vodId,
          sourceTitle: vod.vodName,
          flagKey: flagKey,
        );
      }
      final result = await service.bindingsFor(
        configId: tmdbConfigId,
        siteKey: siteKey,
        vodId: vod.vodId,
        sourceTitle: vod.vodName,
        flagKey: flagKey,
        episodes: line.episodes,
        seasonCounts: tmdb.seasonEpisodeCounts,
      );
      if (generation != tmdb.generation ||
          detailGeneration != _detailRunId ||
          _disposed) {
        return;
      }
      _rememberAiSeasonBinding(
        _aiLineKey(vod, line),
        result,
        seasonBindingsSnapshot(line.episodes, tmdb.seasonEpisodeCounts),
      );
    }
    // 手动锚点与 AI 绑定同批刷新：详情页只调一个入口，两条链路就不会不同步。
    await refreshManualEpisodeMatches(vod, siteKey: siteKey);
    _notifyIfAlive();
  }

  /// 线路在库里的 `flagKey`：与 [refreshAiSeasonMappings] 同一套口径。
  String _dbFlagKeyOf(Vod vod, VodPlayLine line) {
    final lines = playLinesOf(vod);
    final unique = lines.where((item) => item.flag == line.flag).length == 1;
    var index = lines.indexWhere((item) => identical(item, line));
    if (index < 0) {
      index = lines.indexWhere((item) => item.flag == line.flag);
    }
    return TmdbState.sourceLineOf(
      line,
      index < 0 ? 0 : index,
      unique: unique,
    ).flagKey;
  }

  void _rememberManualEpisodeAnchors(
    String key,
    List<EpisodeMatchAnchor> anchors,
  ) {
    if (anchors.isEmpty) {
      _manualEpisodeAnchors.remove(key);
      _manualEpisodeDropped.remove(key);
      return;
    }
    if (_manualEpisodeAnchors.length >= _manualEpisodeCapacity &&
        !_manualEpisodeAnchors.containsKey(key)) {
      final oldest = _manualEpisodeAnchors.keys.first;
      _manualEpisodeAnchors.remove(oldest);
      _manualEpisodeDropped.remove(oldest);
    }
    _manualEpisodeAnchors[key] = List.unmodifiable(anchors);
  }

  void _writeManualEpisodeAnchors(
    AppDatabase db,
    Vod vod,
    VodPlayLine line,
    List<EpisodeMatchAnchor> anchors, {
    String? siteKey,
  }) {
    final service = EpisodeManualMatchService(database: db);
    final flagKey = _dbFlagKeyOf(vod, line);
    final resolvedSiteKey = siteKey ?? _aiTmdbSiteKey;
    if (anchors.isEmpty) {
      service.clear(
        configId: tmdbConfigId,
        siteKey: resolvedSiteKey,
        vodId: vod.vodId,
        sourceTitle: vod.vodName,
        flagKey: flagKey,
      );
      return;
    }
    service.save(
      configId: tmdbConfigId,
      siteKey: resolvedSiteKey,
      vodId: vod.vodId,
      sourceTitle: vod.vodName,
      flagKey: flagKey,
      tmdbId: tmdb.identity?.tmdbId ?? 0,
      mediaType: tmdb.identity?.mediaType.name ?? '',
      anchors: anchors,
    );
  }

  Future<void> _saveManualEpisodeAnchors(
    Vod vod,
    VodPlayLine line,
    List<EpisodeMatchAnchor> anchors, {
    String? siteKey,
  }) async {
    final db = _database;
    if (db == null) return;
    _writeManualEpisodeAnchors(db, vod, line, anchors, siteKey: siteKey);
    _rememberManualEpisodeAnchors(_aiLineKey(vod, line), anchors);
    _notifyIfAlive();
  }

  /// 手动把某一张卡片匹配到 `(season, episode)`，默认从此集起顺延。
  Future<void> matchEpisodeManually({
    required Vod vod,
    required VodPlayLine line,
    required int sourceIndex,
    required String sourceName,
    required int seasonNumber,
    required int episodeNumber,
    bool spread = true,
    String? siteKey,
  }) async {
    final groups = _rawGroupsOf(line);
    final position = groups.indexWhere(
      (group) =>
          group.versions.any((version) => version.sourceIndex == sourceIndex),
    );
    if (position < 0) return;
    // 同一组只留一个锚点：整组替换（组内多版本共享一条结论）。
    final anchors = <EpisodeMatchAnchor>[
      for (final existing in manualEpisodeAnchorsFor(vod, line))
        if (!groups[position].versions.any(
          (version) => version.sourceIndex == existing.sourceIndex,
        ))
          existing,
      EpisodeMatchAnchor(
        sourceIndex: sourceIndex,
        sourceName: sourceName,
        seasonNumber: seasonNumber,
        episodeNumber: episodeNumber,
        spread: spread,
      ),
    ];
    await _saveManualEpisodeAnchors(vod, line, anchors, siteKey: siteKey);
  }

  /// 撤销手动匹配：`sourceIndex` 为 null 时清掉**整条线路**。
  Future<void> clearManualEpisodeMatch({
    required Vod vod,
    required VodPlayLine line,
    int? sourceIndex,
    String? siteKey,
  }) async {
    final anchors = manualEpisodeAnchorsFor(vod, line);
    if (anchors.isEmpty) return;
    if (sourceIndex == null) {
      await _saveManualEpisodeAnchors(vod, line, const [], siteKey: siteKey);
      return;
    }
    final groups = _rawGroupsOf(line);
    final position = groups.indexWhere(
      (group) =>
          group.versions.any((version) => version.sourceIndex == sourceIndex),
    );
    if (position < 0) return;
    final groupIndexes = {
      for (final version in groups[position].versions) version.sourceIndex,
    };
    await _saveManualEpisodeAnchors(vod, line, [
      for (final existing in anchors)
        if (!groupIndexes.contains(existing.sourceIndex)) existing,
    ], siteKey: siteKey);
  }

  /// 读库并重定位手动锚点（与 [refreshAiSeasonMappings] 同一代际守卫）。
  Future<void> refreshManualEpisodeMatches(
    Vod vod, {
    required String siteKey,
  }) async {
    final db = _database;
    if (db == null || !tmdb.belongsTo(vod.vodId)) return;
    final generation = tmdb.generation;
    final detailGeneration = _detailRunId;
    final service = EpisodeManualMatchService(database: db);
    final lines = playLinesOf(vod);
    final tmdbId = tmdb.identity?.tmdbId ?? 0;
    final mediaType = tmdb.identity?.mediaType.name ?? '';
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final key = _aiLineKey(vod, line);
      final flagKey = TmdbState.sourceLineOf(
        line,
        i,
        unique: lines.where((item) => item.flag == line.flag).length == 1,
      ).flagKey;
      final scope = service.loadScope(
        configId: tmdbConfigId,
        siteKey: siteKey,
        vodId: vod.vodId,
        sourceTitle: vod.vodName,
        flagKey: flagKey,
      );
      // 作品身份变了（用户重新匹配了整部作品）：旧锚点指向另一部剧，整行清掉。
      // 身份**未知**时不动：TMDB 这次没拿到身份（网络/额度）不能被当成"换了作品"，
      // 否则一次抖动就删掉用户的人工结论。
      final identityKnown = tmdbId > 0;
      if (identityKnown &&
          scope != null &&
          (scope.tmdbId != tmdbId || scope.mediaType != mediaType)) {
        service.clear(
          configId: tmdbConfigId,
          siteKey: siteKey,
          vodId: vod.vodId,
          sourceTitle: vod.vodName,
          flagKey: flagKey,
        );
        _manualEpisodeAnchors.remove(key);
        _manualEpisodeDropped.remove(key);
        continue;
      }
      final stored = service.load(
        configId: tmdbConfigId,
        siteKey: siteKey,
        vodId: vod.vodId,
        sourceTitle: vod.vodName,
        flagKey: flagKey,
      );
      if (stored.isEmpty) {
        _manualEpisodeAnchors.remove(key);
        _manualEpisodeDropped.remove(key);
        continue;
      }
      final dropped = <int>{};
      final relocated = EpisodeManualMatch.relocate(
        groups: _rawGroupsOf(line),
        anchors: stored,
        dropped: dropped,
      );
      if (dropped.isNotEmpty) {
        // 失效锚点写回：不让库里挂着一批永远命中不到的结论。
        if (relocated.isEmpty) {
          service.clear(
            configId: tmdbConfigId,
            siteKey: siteKey,
            vodId: vod.vodId,
            sourceTitle: vod.vodName,
            flagKey: flagKey,
          );
        } else {
          service.save(
            configId: tmdbConfigId,
            siteKey: siteKey,
            vodId: vod.vodId,
            sourceTitle: vod.vodName,
            flagKey: flagKey,
            tmdbId: tmdbId,
            mediaType: mediaType,
            anchors: relocated,
          );
        }
      }
      _rememberManualEpisodeAnchors(key, relocated);
      if (dropped.isEmpty) {
        _manualEpisodeDropped.remove(key);
      } else {
        _manualEpisodeDropped[key] = dropped.length;
      }
    }
    if (generation != tmdb.generation ||
        detailGeneration != _detailRunId ||
        _disposed) {
      return;
    }
    _notifyIfAlive();
  }

  Future<AiSeasonApplyResult?> confirmAiSeasonMapping({
    required AiSeasonAnalysis analysis,
    required Vod vod,
    required String flagKey,
    required List<VodEpisode> episodes,
    required Map<int, int> seasonCounts,
    required String snapshot,
  }) async {
    final db = _database;
    if (db == null ||
        !tmdb.belongsTo(vod.vodId) ||
        tmdb.sourceLine?.flagKey != flagKey) {
      return null;
    }
    final currentEpisodes = [
      for (var i = 0; i < tmdb.sourceLine!.episodeNames.length; i++)
        VodEpisode(
          name: tmdb.sourceLine!.episodeNames[i],
          url: i < tmdb.sourceLine!.episodeUrls.length
              ? tmdb.sourceLine!.episodeUrls[i]
              : '',
        ),
    ];
    final result = await AiSeasonMappingService(database: db).confirmAndPersist(
      configId: tmdbConfigId,
      siteKey: _aiTmdbSiteKey,
      vodId: vod.vodId,
      sourceTitle: vod.vodName,
      flagKey: flagKey,
      analysis: analysis,
      episodes: currentEpisodes,
      seasonCounts: tmdb.seasonEpisodeCounts,
      recognitionSnapshot: snapshot,
      tmdbId: tmdb.identity?.tmdbId ?? 0,
      mediaType: tmdb.identity?.mediaType.name ?? '',
    );
    await refreshAiSeasonMappings(vod, siteKey: _aiTmdbSiteKey);
    return result;
  }

  Future<void> _loadTmdbWithAi(
    Vod vod, {
    required String siteKey,
    String siteName = '',
    int configId = 0,
    List<VodPlayLine>? lines,
    bool navSource = false,
    // beta 起 `TmdbState.loadForVod` 支持「已知身份」提示（导航源/无线路时
    // 直接用站点声明的身份），这里原样透传上去。
    TmdbIdentity? knownIdentity,
  }) async {
    // 推送标题守卫：推送源返回的名字常是网盘地址/文件名，不要拿它去自动匹配，
    // 否则会把垃圾名字写进匹配表、还可能顶掉用户手动指定的结论。
    // 已经有手动结论时仍然放行（详情页要显示用户选的那一部）。
    if (siteKey == pushSiteKey && !shouldAutoMatchPushTitle(vod.vodName)) {
      var manual = false;
      try {
        manual =
            _database != null &&
            _ensureTmdbIdentityService().cachedManual(
                  siteKey: siteKey,
                  vodId: vod.vodId,
                  sourceTitle: vod.vodName,
                ) !=
                null;
      } catch (error) {
        log.debug('推送手动匹配查询失败：$error', scope: 'tmdb');
      }
      if (!manual) return;
    }
    final run = ++_aiLoadRun;
    _aiTmdbSiteKey = siteKey;
    await tmdb.loadForVod(
      vod,
      siteKey: siteKey,
      siteName: siteName,
      configId: configId,
      lines: lines,
      navSource: navSource,
      knownIdentity: knownIdentity,
    );
    final generation = tmdb.generation;
    final detailGeneration = _detailRunId;
    if (run != _aiLoadRun || !tmdb.belongsTo(vod.vodId)) return;
    if (!tmdb.hasMatch &&
        tmdbConfig.isReady &&
        aiTitleExtractionEnabled &&
        aiReady) {
      final typed = await aiIntegration.title.resolve(
        TitleQuery(
          rawTitle: vod.vodName,
          siteKey: siteKey,
          vodId: vod.vodId,
          vodRemarks: vod.vodRemarks ?? '',
        ),
      );
      if (generation != tmdb.generation ||
          detailGeneration != _detailRunId ||
          _disposed) {
        return;
      }
      final value = typed.value;
      final keyword = identityFallbackRequest(
        rawTitle: vod.vodName,
        existingTmdbId: tmdb.identity?.tmdbId ?? 0,
        existingIsManual: false,
        resolution: value == null
            ? null
            : SeasonTitleResolution(
                title: value.title,
                confidence: value.confidence,
                year: value.year,
                mediaType: value.mediaType?.wireName,
              ),
      );
      if (keyword != null) {
        await tmdb.loadMatch(
          generation: generation,
          sourceTitle: vod.vodName,
          siteName: siteName,
          searchKeyword: keyword,
          vodName: vod.vodName,
          vodRemarks: vod.vodRemarks,
          vodYear: vod.vodYear,
        );
        if (generation != tmdb.generation ||
            detailGeneration != _detailRunId ||
            _disposed) {
          return;
        }
        if (tmdb.hasMatch) {
          await tmdb.loadForVod(
            vod,
            siteKey: siteKey,
            siteName: siteName,
            configId: configId,
            lines: lines,
            navSource: navSource,
          );
        }
      }
    }
    if (tmdb.belongsTo(vod.vodId)) {
      await refreshAiSeasonMappings(vod, siteKey: siteKey);
    }
  }

  /// 持久化 AI 配置。
  ///
  /// 与 `saveTmdbConfig` 同构：写盘失败**不影响**当前会话（store 的内存值已
  /// 生效），但无论如何都通知 UI 重建。
  ///
  /// **API Key 不得进日志**：只记配置与就绪状态，不记逐字保存的凭据片段。
  Future<bool> saveAiConfig(AiConfig config) async {
    final saved = await _aiConfigStore.save(config);
    if (!config.isReady) clearAiAdApplication();
    if (saved) {
      log.info(
        'AI 设置已更新 enabled=${config.enabled} '
        'protocol=${config.protocol} ready=${config.isReady} '
        'keyConfigured=${config.apiKey.isNotEmpty}',
        scope: 'ai',
      );
    } else {
      log.warning('AI 设置保存失败（内存已生效）', scope: 'ai');
    }
    _notifyIfAlive();
    return saved;
  }

  /// 测试口子：不经 bootstrap 直接装配 AI 配置 store。
  ///
  /// 与 [attachUiPreferences] 同理（单测不调 bootstrap）。
  /// 生产代码不得调用；bootstrap 是唯一的正规装配点。
  @visibleForTesting
  void attachAiConfigStore(AiConfigStore store) {
    _aiConfigStore = store;
  }

  /// TMDB 服务（纯 TMDB 详情页直接使用，`04` §6）。
  TmdbService get tmdbService => _tmdbService;

  /// 详情页外部评分（豆瓣 + 可选 OMDb）。
  ///
  /// 惰性创建：没进过详情页的会话不持有任何评分客户端。
  DetailRatingService get detailRatingService =>
      _detailRatingService ??= DetailRatingService.fromServices(
        cacheDirectory: Directory(paths.cacheDir),
        log: log,
      );

  DetailRatingService? _detailRatingService;

  /// 外部元数据兜底（TMDB 不可用时：豆瓣 → Bangumi）。
  ///
  /// 惰性创建：没进过「无 TMDB」详情页的会话不会发出任何外部请求。
  /// 默认开启（用户决策 2026-11-17）；两个客户端各自串行限速并落盘缓存，
  /// 失败一律退化成「取不到」，详情页保持站源字段的样子。
  ExternalMetaService get externalMetaService =>
      _externalMetaService ??= ExternalMetaService(
        enabled: () => externalMetaEnabled,
        pipeline: () => metaPipeline,
        // 只用于按 IMDb 编号做确定性跨源映射（只读，不抓内容）。
        tmdb: tmdbService,
        // TMDB 快照只读：已匹配的详情直接进优先链，不额外发请求。
        tmdbDetail: () => tmdb.detailData,
        tmdbIdentity: () {
          final identity = tmdb.identity;
          if (identity == null) return null;
          return MetaIdentity.of(
            MetaSourceKind.tmdb,
            identity.mediaType,
            identity.tmdbId,
          );
        },
        log: (message) => log.info(message, scope: 'metadata'),
        douban: DoubanRecommendationService(
          cacheDirectory: Directory(
            '${paths.cacheDir}${Platform.pathSeparator}douban_meta',
          ),
        ),
        bangumi: BangumiService(
          cacheDirectory: Directory(
            '${paths.cacheDir}${Platform.pathSeparator}bangumi_meta',
          ),
        ),
      );

  ExternalMetaService? _externalMetaService;

  bool get externalMetaEnabled => _uiPreferences?.externalMetaEnabled ?? true;

  /// 多来源元数据管线（逐字段优先/聚合）。
  MetaPipeline get metaPipeline =>
      _uiPreferences?.metaPipeline ?? MetaPipeline.defaults;

  /// 用户手动钉住的来源身份（vod → MetaIdentity）。
  MetaOverrideStore get metaOverrides =>
      _uiPreferences?.metaOverrides ?? MetaOverrideStore();

  /// 钉住一条来源身份：优先于自动匹配，取不到时自动回退。
  Future<bool> pinMetaOverride(String vodId, MetaIdentity identity) async {
    final store = _uiPreferences;
    if (store == null) return false;
    final saved = await store.pinMetaOverride(vodId, identity);
    _externalMetaService?.clearCache(preserveComments: true);
    _notifyIfAlive();
    return saved;
  }

  Future<bool> unpinMetaOverride(String vodId) async {
    final store = _uiPreferences;
    if (store == null) return false;
    final saved = await store.unpinMetaOverride(vodId);
    _externalMetaService?.clearCache(preserveComments: true);
    _notifyIfAlive();
    return saved;
  }

  Future<bool> setMetaPipeline(MetaPipeline pipeline) async {
    final store = _uiPreferences;
    if (store == null) return false;
    final commentsChanged =
        metaPipeline.ruleOf(MetaField.comments) !=
        pipeline.ruleOf(MetaField.comments);
    final saved = store.rememberMetaPipeline(pipeline);
    _externalMetaService?.clearCache(preserveComments: !commentsChanged);
    notifyListeners();
    return saved;
  }

  Future<bool> setExternalMetaEnabled(bool enabled) async {
    final store = _uiPreferences;
    if (store == null) return false;
    final saved = store.rememberExternalMetaEnabled(enabled);
    _externalMetaService?.clearCache();
    notifyListeners();
    return saved;
  }

  DetailRecommendationDependencies? _recommendationDependencies;
  DetailRecommendationDependencies get recommendationDependencies =>
      _recommendationDependencies ??=
          DetailRecommendationDependencies.fromServices(
            service: tmdbService,
            cacheDirectory: Directory(paths.cacheDir),
            feedbackFile: File(
              '${paths.configDir}/recommendation-feedback.json',
            ),
            historyChanges: this,
            history: () => [
              for (final row in recentHistory(sourceKey: ''))
                recommendationSeedForHistory(row),
            ],
          );

  /// 把一条历史行映射成推荐种子。
  ///
  /// 公开而不是私有：详情页用它拼「个性推荐」，首页也用它拼（同一个口径，
  /// 否则两处对「这部片适合当种子吗」会给出不同答案）。
  RecommendationSeed recommendationSeedForHistory(PlaybackHistory row) {
    final sourceConfig = configForSourceKey(row.sourceKey) ?? config;
    final site = sourceConfig == null
        ? null
        : _siteByKey(sourceConfig, row.siteKey);
    return _recommendationSeed(
      title: row.vodName,
      year: row.vodYear,
      tmdbId: row.tmdbId,
      mediaType: TmdbMediaType.parse(row.mediaType),
      site: site,
    );
  }

  RecommendationSeed recommendationSeedForVod(
    Vod vod, {
    Site? site,
    TmdbItem? tmdbItem,
  }) => _recommendationSeed(
    title: vod.vodName,
    year: vod.vodYear ?? '',
    tmdbId: tmdbItem?.tmdbId ?? 0,
    mediaType:
        tmdbItem?.mediaType ?? TmdbMediaType.parse(vod.extra['media_type']),
    site: site,
    typeLabel: asString(vod.extra['type_name']) ?? '',
  );

  RecommendationSeed _recommendationSeed({
    required String title,
    required String year,
    required int tmdbId,
    required TmdbMediaType? mediaType,
    Site? site,
    String typeLabel = '',
  }) {
    // Canonical content tags and bracket forms come from tmdb_config.dart.
    final labels = normalizeBrackets(
      '${site?.key ?? ''} ${site?.name ?? ''} $typeLabel',
    );
    return RecommendationSeed(
      title: title,
      year: year,
      tmdbId: tmdbId,
      mediaType: mediaType,
      isAudio: const ['[音]', '[听]', '[书]', '[小说]'].any(labels.contains),
      isShortDrama: labels.contains('[短]'),
    );
  }

  /// 设置文件路径（设置页展示用）。
  String get tmdbSettingsPath => paths.settingsPath;

  /// TMDB 配置版本号（设置变更时递增，供 UI 重建）。
  int _tmdbConfigRevision = 0;
  int get tmdbConfigRevision => _tmdbConfigRevision;

  /// 当前生效的 TMDB 配置 ID（多配置隔离，`02` §14 Q2）。
  int get tmdbConfigId => _activeRecord?.id ?? 0;

  StartupInfo? get startupInfo => _startupInfo;

  /// 启动时实测不可写的目录（`目录: 错误`）。空表示全部可写。
  ///
  /// UI 用它决定是否显示「数据目录不可写」横幅——这类故障以前是静默的：
  /// 用户只看到历史没了，日志里那条错误还写不进日志文件。
  List<String> get storageWarnings => _storageWarnings;
  LoadPhase get configPhase => _configPhase;
  LoadPhase get contentPhase => _contentPhase;
  LoadPhase get detailPhase => _detailPhase;
  AppError? get lastError => _lastError;
  String? get notice => _notice;

  /// 后台自动安装的只读进度；[CspProvisionProgress.active] 为 false 时导入页只显示
  /// [cspProvisionSummary]。
  CspProvisionProgress get cspProvisionProgress =>
      identical(_cspProvisionConfig, effectiveConfig)
          ? _cspProvisionProgress
          : const CspProvisionProgress();

  /// 最近一轮自动安装的结果摘要（结束后保留一条，下一轮开始时覆盖）。
  String? get cspProvisionSummary =>
      identical(_cspProvisionConfig, effectiveConfig) ? _cspProvisionSummary : null;
  AppConfig? get config => _config;
  SiteService? get siteService => _siteService;

  /// 当前配置声明的直播源（§7.1 `lives`）。
  List<LiveSource> get liveSources => _config?.lives ?? const [];

  /// 直播服务（§13.1）。首次访问时构造，复用同一个 HttpClient 与缓存。
  LiveService get liveService =>
      _liveService ??= _injectedLiveService ?? LiveService();

  /// EPG 服务（§13.1）。缓存落在 `paths.cacheDir/epg/`，与直播服务同域。
  EpgService get epgService => _epgService ??=
      _injectedEpgService ?? EpgService(cacheDir: paths.cacheDir);

  /// Offline only; the provider tolerates absent stores and damaged cache rows.
  Map<int, ViewingMetadata> viewingReportMetadata(
    List<PlaybackHistory> records,
  ) => ViewingReportMetadata(
    database: _database,
    tmdbService: _tmdbService,
  ).forRecords(records);

  AppDatabase? get database => _database;
  ConfigRecord? get activeRecord => _activeRecord;
  ConfigSourceStatus? _restoredConfigSourceStatus;
  int _restoredConfigSourceCheck = 0;
  int? _restoredConfigSourceRecordId;
  String? _restoredConfigSourceOrigin;

  ConfigSourceStatus? get restoredConfigSourceStatus {
    final status = _restoredConfigSourceStatus;
    if (_disposed || status == null) return null;
    final active = _database?.activeConfig();
    return active?.id == status.recordId &&
            active?.origin == _restoredConfigSourceOrigin
        ? status
        : null;
  }

  void dismissRestoredConfigSourceWarning() {
    _clearRestoredConfigSourceWarning();
    notifyListeners();
  }

  void _clearRestoredConfigSourceWarning({int? recordId}) {
    if (recordId != null && recordId != _restoredConfigSourceRecordId) return;
    _restoredConfigSourceCheck++;
    _restoredConfigSourceRecordId = null;
    _restoredConfigSourceOrigin = null;
    _restoredConfigSourceStatus = null;
  }

  Future<void> _inspectRestoredConfigSource(ConfigRecord record) async {
    final check = ++_restoredConfigSourceCheck;
    _restoredConfigSourceRecordId = record.id;
    _restoredConfigSourceOrigin = record.origin;
    final status = await inspectConfigSource(record);
    if (_disposed || check != _restoredConfigSourceCheck) return;
    final active = _database?.activeConfig();
    if (_activeRecord?.id != record.id ||
        active?.id != record.id ||
        active?.origin != record.origin) {
      return;
    }
    if (!status.needsAttention) return;
    _restoredConfigSourceStatus = status;
    _notifyIfAlive();
  }

  List<ConfigRecord> get configs => _configs;

  /// bootstrap 读到的「最后一次使用的配置」记忆（没有记录时为 `null`）。
  LastConfigRecord? get lastConfigRecord => _lastConfigRecord;

  Site? get selectedSite => _selectedSite;
  SiteResult? get homeResult => _homeResult;
  SiteResult? get categoryResult => _categoryResult;
  SiteResult? get detailResult => _detailResult;
  String get detailRequestVodId => _detailRequestVodId;
  Vod? get selectedVod => _selectedVod;
  String? get selectedTypeId => _selectedTypeId;

  /// 应用级手动网盘账号存储（显式 UI 保存/清除的唯一入口）。
  SpiderAccountStore get spiderAccounts => _spiderAccounts;

  /// 当前生效的分类筛选条件（供 UI 高亮选中项）。
  Map<String, String> get categoryFilters => _categoryFilters;

  /// 当前分类已加载到第几页（滚动加载下一页的基准）。
  int get categoryPage => _categoryPage;

  /// 当前分类是否还有下一页（false 时滚动到底不再请求）。
  bool get categoryHasMore => _categoryHasMore;

  /// 是否正在加载「下一页」（滚动时防止同一页码被并发请求多次）。
  bool get categoryLoadingMore => _categoryLoadingMore;

  /// 详情错误（与首页/分类/搜索共用的 [lastError] 分开）。
  ///
  /// 详情页可能叠在浏览页之上，而浏览页会渲染 `lastError`：详情失败若写进
  /// 同一个字段，用户返回列表时会看到一条与当前列表无关的详情错误横幅。
  AppError? get detailError => _detailError;
  String? get importDiagnosticsSummary => _importDiagnosticsSummary;
  PlaybackDecision? get lastDecision => _lastDecision;

  /// 最近一次播放诊断快照（§23）。
  PlaybackDiagnostics? get lastDiagnostics => _lastDiagnostics;

  /// 记录一次播放诊断（由播放器页在加载完成后调用），供日志页展示。
  void recordPlaybackDiagnostics(PlaybackDiagnostics diagnostics) {
    _lastDiagnostics = diagnostics;
    notifyListeners();
  }

  /// 当前（或最近一次）并发搜索批次。
  MultiSiteSearchOutcome? get activeSearch => _activeSearch;

  /// 最近搜索关键词（去重、最新在前）。
  ///
  /// 命名与 [searchHistory]（按关键词查播放历史的方法）区分，避免两者混淆。
  List<String> get recentSearchKeywords => _searchHistory;

  /// 读取某部作品上次使用的播放器画面模式。
  String? playerVideoFitModeFor({
    required String siteKey,
    required String vodId,
  }) {
    final value = _uiPreferences?.videoFitMode(siteKey: siteKey, vodId: vodId);
    return value == null || value.isEmpty ? null : value;
  }

  /// 持久化某部作品的播放器画面模式，失败不影响当前播放。
  void rememberPlayerVideoFitMode({
    required String siteKey,
    required String vodId,
    required String mode,
  }) {
    unawaited(
      _uiPreferences?.rememberVideoFitMode(
            siteKey: siteKey,
            vodId: vodId,
            mode: mode,
          ) ??
          Future<void>.value(),
    );
  }

  /// 读取某部作品某线路某集记下的轨道选择；没有记录时返回 null。
  ///
  /// 键由 `trackChoiceKey` 统一拼装：线路（[flag]）与集都在键里，
  /// 所以换线路、换集拿不到同一条记忆（用户明确要求的口径——不同线路的
  /// 资源本身可能不同，跨线路沿用只会切成错误的轨）。
  TrackChoice? playerTrackChoiceFor({
    required PlayerTrackSlot slot,
    required String siteKey,
    required String vodId,
    required String flag,
    required String episodeId,
    required String episodeName,
  }) {
    final key = trackChoiceKey(
      siteKey: siteKey,
      vodId: vodId,
      flag: flag,
      episodeId: episodeId,
      episodeName: episodeName,
      slot: slot,
    );
    return _uiPreferences?.trackChoice(key);
  }

  /// 持久化用户**显式**选中的轨道；写盘失败不影响当前播放。
  ///
  /// 只允许显式选择调用：自动回落的结果写进来，一次失配就会把用户的选择冲掉。
  void rememberPlayerTrackChoice({
    required PlayerTrackSlot slot,
    required String siteKey,
    required String vodId,
    required String flag,
    required String episodeId,
    required String episodeName,
    required TrackChoice choice,
  }) {
    final key = trackChoiceKey(
      siteKey: siteKey,
      vodId: vodId,
      flag: flag,
      episodeId: episodeId,
      episodeName: episodeName,
      slot: slot,
    );
    unawaited(
      _uiPreferences?.rememberTrackChoice(key, choice) ?? Future<void>.value(),
    );
  }

  /// 生效的屏显开关。
  ///
  /// `_uiPreferences` 为 null（未 bootstrap）时返回默认表，不让屏显失败——
  /// 与 [themeMode] 同一口径。
  Map<String, bool> get osdFlags =>
      _uiPreferences?.osdFlags ?? defaultOsdFlags();

  /// 持久化单项屏显开关。
  ///
  /// 写盘失败不影响当前会话（内存里已生效），但无论如何都通知 UI 重建——
  /// 用户刚点了开关，界面必须立刻反映选择（与 [setThemeMode] 同语义）。
  Future<bool> setOsdFlag(String id, bool enabled) async {
    final store = _uiPreferences;
    if (store == null) return false;
    final ok = await store.rememberOsdFlag(id, enabled);
    _notifyIfAlive();
    return ok;
  }

  /// 生效的播放器按钮顺序。
  List<String> get playerButtonOrder =>
      _uiPreferences?.buttonOrder ?? defaultButtonOrder();

  /// 生效的播放器按钮隐藏集。
  Set<String> get playerButtonHidden =>
      _uiPreferences?.buttonHidden ?? const <String>{};

  /// 持久化播放器按钮顺序。
  Future<bool> setPlayerButtonOrder(List<String> order) async {
    final store = _uiPreferences;
    if (store == null) return false;
    final ok = await store.rememberButtonOrder(order);
    _notifyIfAlive();
    return ok;
  }

  /// 持久化播放器按钮隐藏集。
  Future<bool> setPlayerButtonHidden(Set<String> hidden) async {
    final store = _uiPreferences;
    if (store == null) return false;
    final ok = await store.rememberButtonHidden(hidden);
    _notifyIfAlive();
    return ok;
  }

  /// 外部播放器可执行文件路径；`null` = 还没配置过。
  ///
  /// 配置过才认为「外部播放器」能力可用（控制栏按钮与菜单项都以此为准）。
  String? get externalPlayerPath => _uiPreferences?.externalPlayerPath;

  Future<List<ExternalPlayer>> listExternalPlayers() async {
    final scanned = _externalPlayerDetector();
    return _uiPreferences?.listExternalPlayers(scanned) ??
        List<ExternalPlayer>.unmodifiable(scanned);
  }

  Future<bool> saveExternalPlayer({
    String? originalExecutable,
    required String name,
    required String executable,
  }) async {
    final store = _uiPreferences;
    if (store == null) return false;
    final ok = await store.saveExternalPlayer(
      originalExecutable: originalExecutable,
      name: name,
      executable: executable,
      scanned: _externalPlayerDetector(),
    );
    if (ok) _notifyIfAlive();
    return ok;
  }

  /// 外部播放器是否已配置可用。
  bool get hasExternalPlayer => externalPlayerPath != null;

  /// 持久化外部播放器路径。传空串等于清除配置。
  Future<bool> setExternalPlayerPath(String? path) async {
    final store = _uiPreferences;
    if (store == null) return false;
    final ok = await store.rememberExternalPlayerPath(path);
    _notifyIfAlive();
    return ok;
  }

  /// 恢复播放器按钮排版默认。
  Future<bool> resetPlayerButtons() async {
    final store = _uiPreferences;
    if (store == null) return false;
    final ok = await store.resetPlayerButtons();
    _notifyIfAlive();
    return ok;
  }

  double get playerVolume => _uiPreferences?.playerVolume ?? 100;
  bool get hasExplicitPlayerVolume =>
      _uiPreferences?.hasExplicitPlayerVolume ?? false;
  double get playerResumeVolume => _uiPreferences?.playerResumeVolume ?? 100;

  /// 落盘不广播全局变化，避免音量拖动重建播放、字幕与手势状态。
  Future<bool> setPlayerVolume(double volume, {double? resumeVolume}) {
    final store = _uiPreferences;
    if (store == null) return Future.value(false);
    return store.rememberPlayerVolume(volume, resumeVolume: resumeVolume);
  }

  /// 生效的播放参数（Phase 9）。
  ///
  /// `_uiPreferences` 为 null（未 bootstrap）时返回默认值，不让播放器失败。
  PlayerOptions get playerOptions =>
      _uiPreferences?.playerOptions ?? const PlayerOptions.defaults();

  /// 生效的弹幕显示样式（Phase 9 P0-7）。
  DanmakuStyle get danmakuStyle =>
      _uiPreferences?.danmakuStyle ?? DanmakuStyle.defaults;

  /// 生效的字幕显示样式（P1-4）。
  ///
  /// `_uiPreferences` 为 null（未 bootstrap）时返回默认样式，不让播放器失败。
  SubtitleStyle get subtitleStyle =>
      _uiPreferences?.subtitleStyle ?? SubtitleStyle.defaults;

  /// 生效的屏显样式（P1-4）。
  OsdStyle get osdStyle => _uiPreferences?.osdStyle ?? OsdStyle.defaults;

  /// 生效的直播设置（Phase 9）。
  LiveSettings get liveSettings =>
      _uiPreferences?.liveSettings ?? const LiveSettings.defaults();

  List<String> get liveSiteKeywords =>
      _uiPreferences?.liveSiteKeywords ?? liveSiteDefaultKeywords;

  /// 生效的字幕源设置（Phase 9）。
  SubtitleSettings get subtitleSettings =>
      _uiPreferences?.subtitleSettings ?? SubtitleSettings();

  /// 生效的站点排序偏好（Phase 9）。
  SiteOrderSettings get siteOrder =>
      _uiPreferences?.siteOrder ?? const SiteOrderSettings.defaults();

  /// 站点列表覆盖（手动顺序 + 屏蔽）的持久化作用域。
  ///
  /// 用配置**记录 id**，与 `config_sites` / `tmdb_*` 等既有表同一口径：同一份
  /// 配置重新拉取（刷新接口地址）后顺序与屏蔽仍然生效，换到另一份配置则各自一套。
  /// 没有配置记录时（未 bootstrap、纯内存路径）落到 `default`，不同配置会共用——
  /// 这只是降级路径，不是生产口径。
  String get siteListScopeKey {
    final record = _activeRecord;
    if (record != null) return 'config:${record.id}';
    return 'default';
  }

  /// 生效的站点列表覆盖（手动顺序 + 屏蔽）。
  SiteListOverrides get siteListOverrides =>
      _uiPreferences?.siteListOverrides(siteListScopeKey) ??
      SiteListOverrides.empty;

  /// 被屏蔽的站点 key：从站点列表隐去，且不参与搜索/换源候选。
  Set<String> get blockedSiteKeys => siteListOverrides.blocked;

  /// 配置原始顺序的站点 key（`hide=1` 的站点不算）。
  ///
  /// 只给「恢复默认排序」用：站点选择器收到的 [siteItems] 已经按手动顺序排过，
  /// 没法从它反推默认顺序。
  List<String> get siteConfigOrderKeys {
    final config = effectiveConfig;
    if (config == null) return const [];
    return [
      for (final site in config.sites)
        if (!site.hide) site.key,
    ];
  }

  bool isSiteBlocked(String siteKey) => siteListOverrides.isBlocked(siteKey);

  /// 直连站源注册的进行中 Future（null 表示未发起或已作废）。
  ///
  /// 首屏抢跑缺陷（2026-10-24 实测）：[_attachSiteService] 先 unawaited 发起注册，
  /// 紧接着就装配好 [_siteService]，首页在注册落定前就发 home。此时
  /// classifySite 对 csp_PyProxy 这类站点会落到「PC Java Spider 未支持」，
  /// 用户看到一次红横幅，而注册完成后**没有任何代码重放首页**。
  /// 修复：注册发起时保存 Future，首页在这类站点上等它落定（等待是顺序问题，
  /// 不是耗时问题——实测注册只要 116 ms 也照样抢跑）。
  Future<Map<String, LocalSpider>>? _directReady;
  AppConfig? _directReadyConfig;
  final Expando<Future<Map<String, LocalSpider>>> _directRegistrationFlights =
      Expando();
  AppConfig? _directHomeRetryConfig;
  Site? _directHomeRetrySite;

  @visibleForTesting
  DirectProbeRunner? debugDirectProbeOverride;

  @visibleForTesting
  Duration? debugDirectReadyTimeout;

  @visibleForTesting
  Map<String, LocalSpider> get debugDirectSpiders =>
      Map.unmodifiable(_router.directSpiders);

  @visibleForTesting
  Future<void> debugRegisterDirectSpidersFor(
    AppConfig config,
    SpiderRouter router,
  ) => _registerDirectSpidersFor(config, router);

  /// 等待直连站源注册的上限。超时后按现状继续（不得把真实崩溃伪装成等待）。
  static const Duration _directReadyTimeout = Duration(seconds: 8);

  bool _disposed = false;
  final Map<Timer, Completer<void>> _backgroundYields = {};

  Future<void> _yieldBackgroundWork() {
    if (_disposed) return Future<void>.value();
    final ready = Completer<void>();
    late final Timer timer;
    timer = Timer(Duration.zero, () {
      _backgroundYields.remove(timer);
      ready.complete();
    });
    _backgroundYields[timer] = ready;
    return ready.future;
  }

  /// 播放进度写库的修订号：每次 [recordProgress] 成功落库后自增。
  ///
  /// 为什么不是 [notifyListeners]：进度在播放中每 5 秒写一次，全局通知会让首页、
  /// 侧栏、历史页等**所有**监听者在播放期间反复重建；而真正需要「刚才播到哪」
  /// 的只有当前这页详情。订阅一个计数器，代价只落在它的监听者身上。
  ///
  /// 订阅方必须**重新查库**而不是缓存上一次的结果：写入与通知之间有微小窗口。
  final ValueNotifier<int> progressRevision = ValueNotifier<int>(0);

  /// 通知监听者的**统一出口**：已 dispose 就安静返回。
  ///
  /// 为什么要有它：`await` 之后回到同步段时，widget 树可能已经拆掉
  /// （[dispose] 把 [_disposed] 置真）。此时直接 `notifyListeners()` 会向已
  /// 释放的监听者派发，Flutter 侧表现为「dispose 之后仍在触发重建」的报错；
  /// 而在 await **之前**发通知是安全的，所以同步路径保持原样、不改变通知时序。
  void _notifyIfAlive() {
    if (_disposed) return;
    notifyListeners();
  }

  /// 同一配置实例共享注册，换配置则允许新一轮并清掉旧路由映射。
  Future<Map<String, LocalSpider>> _kickDirectRegistration() {
    final config = effectiveConfig;
    if (_disposed) return Future.value(const {});
    if (config == null ||
        !config.sites.any((site) => directSpiderKind(site) != null)) {
      _directReady = null;
      _directReadyConfig = config;
      _router.setDirectSpiders(const {});
      _directHomeRetryConfig = null;
      _directHomeRetrySite = null;
      return Future.value(const {});
    }
    final pending = _directReady;
    if (pending != null && identical(_directReadyConfig, config)) {
      return pending;
    }
    if (!identical(_directReadyConfig, config)) {
      _router.setDirectSpiders(const {});
      _directHomeRetryConfig = null;
      _directHomeRetrySite = null;
    }
    _directReadyConfig = config;
    final future = _registerDirectSpidersQuietly(config);
    _directReady = future;
    unawaited(future);
    return future;
  }

  /// 三个注册入口共用这把闸门；只缓存进行中的工作，不改变手动重探测语义。
  Future<Map<String, LocalSpider>> _materializeDirectSpiders(AppConfig config) {
    if (_disposed ||
        !config.sites.any((site) => directSpiderKind(site) != null)) {
      return Future.value(const {});
    }
    final pending = _directRegistrationFlights[config];
    if (pending != null) return pending;
    late final Future<Map<String, LocalSpider>> future;
    future = () async {
      try {
        await _yieldBackgroundWork();
        if (_disposed) return <String, LocalSpider>{};
        final runner =
            debugDirectProbeOverride ?? _directRegistrar().materialize;
        return await runner(config);
      } finally {
        if (identical(_directRegistrationFlights[config], future)) {
          _directRegistrationFlights[config] = null;
        }
      }
    }();
    _directRegistrationFlights[config] = future;
    return future;
  }

  /// 等直连站源注册落定（仅当该站点确实依赖注册结果时调用）。
  Future<void> _waitForDirectRegistration() async {
    final pending = _directReady;
    if (pending == null) return;
    try {
      await pending.timeout(debugDirectReadyTimeout ?? _directReadyTimeout);
    } on TimeoutException {
      log.warning('直连站源注册超时，按当前状态继续', scope: 'spider');
    } catch (_) {
      // 注册失败已由 _registerDirectSpidersQuietly 记日志；这里不吞掉后续加载。
    }
  }

  /// CatVod 站源（Atvp 壳）需要的第三方依赖。
  ///
  /// 壳在**模块顶层**就 import 它们（实测 C:/dev/Atvp.py:18-23 的 requests /
  /// Crypto / lxml），因此缺依赖不是「某个方法不可用」而是**启动即失败**：
  /// host.py 记一行 stderr 后 return 3；宿主现在会把它读成「站源初始化失败：<缺的模块>」
  /// 并直接判定为确定性失败（不重试）。
  static const List<String> catVodPythonModules = <String>[
    'requests',
    'Crypto',
    'lxml',
  ];

  final PythonEnvironment? _injectedPythonEnvironment;
  late final PythonEnvironment _pythonEnvironment =
      _injectedPythonEnvironment ?? PythonEnvironment(paths: paths);
  PythonEnvironmentStatus? get pythonEnvironmentStatus =>
      _pythonEnvironment.status;
  bool get pythonEnvironmentBusy => _pythonEnvironment.busy;
  String? get pythonEnvironmentError => _pythonEnvironment.error;

  Future<void>? _sidecarShutdown;

  Future<void> get pythonEnvironmentIdle async {
    final pending = _pythonReady;
    if (pending != null) await pending;
    await _pythonEnvironment.idle;
    await _sidecarShutdown;
  }

  Future<void> refreshPythonEnvironment() async {
    final pending = _pythonEnvironment.refresh();
    if (!_disposed) notifyListeners();
    await pending;
    if (!_disposed) {
      _applyPythonEnvironment();
      _notifyIfAlive();
    }
  }

  Future<bool> _changePythonEnvironment(Future<bool> Function() action) async {
    final pending = action();
    if (!_disposed) notifyListeners();
    final ok = await pending;
    if (!_disposed) {
      if (ok) _applyPythonEnvironment();
      _notifyIfAlive();
    }
    return ok;
  }

  Future<bool> repairPythonEnvironment() =>
      _changePythonEnvironment(_pythonEnvironment.repair);
  Future<bool> setCustomPythonExecutable(String executable) =>
      _changePythonEnvironment(() => _pythonEnvironment.setCustom(executable));
  Future<bool> useDefaultPythonEnvironment() =>
      _changePythonEnvironment(_pythonEnvironment.useDefault);

  bool _pythonRuntimeTried = false;
  Future<void>? _pythonReady;
  bool get _pythonProvisionDisabled =>
      _injectedPythonEnvironment == null &&
      Platform.environment['WEBHTV_DISABLE_PYTHON_PROVISION'] == '1';

  void _applyPythonEnvironment() {
    if (_disposed) return;
    final status = pythonEnvironmentStatus;
    LocalSpiderCommand.preferPythonExecutable(
      status != null && status.version.startsWith('3.')
          ? status.executable
          : null,
      arguments: [..._pythonEnvironment.arguments, '-B'],
      verified: status != null,
      catVodReady: status?.ready ?? false,
    );
    _router.invalidateRuntimes();
    for (final context in _playbackContexts.values) {
      context.service.router.invalidateRuntimes();
    }
    if (status?.ready ?? false) {
      log.info('Python 运行时就绪：${status!.executable}', scope: 'spider');
    } else if (status?.error != null) {
      log.warning('Python 运行时准备失败：${status!.error}', scope: 'spider');
    }
  }

  Future<void> _preparePythonRuntimeQuietly({bool force = false}) {
    final pending = _pythonReady;
    if (pending != null) return pending;
    if (_pythonRuntimeTried || _pythonProvisionDisabled || _disposed) {
      return Future.value();
    }
    final config = effectiveConfig;
    final needsPython =
        config?.sites.any((site) {
              final kind = directSpiderKind(site);
              return kind == DirectSpiderKind.py ||
                  kind == DirectSpiderKind.catVod;
            }) ==
            true ||
        _spiderRegistry.spiders.values.any(
          (spider) =>
              spider.manifest.runtime.toLowerCase().startsWith('python'),
        );
    if (!needsPython && !force) return Future.value();
    _pythonRuntimeTried = true;
    if (pythonEnvironmentStatus == null) {
      LocalSpiderCommand.preferPythonExecutable(null, verified: true);
      _router.invalidateRuntimes();
    }
    final future = refreshPythonEnvironment().whenComplete(() {
      _pythonReady = null;
    });
    _pythonReady = future;
    return future;
  }

  Future<void> _waitForPythonSite(Site site) async {
    final kind = directSpiderKind(site);
    final local = SpiderLocalBinding(registry: _spiderRegistry)
        .resolve(site.api);
    if (kind != DirectSpiderKind.py &&
        kind != DirectSpiderKind.catVod &&
        local?.manifest.runtime.toLowerCase().startsWith('python') != true) {
      return;
    }
    if (kind != null) await _waitForDirectRegistration();
    await _preparePythonRuntimeQuietly(force: true);
    if (pythonEnvironmentBusy) await _pythonEnvironment.refresh();
  }

  Future<Map<String, LocalSpider>> _registerDirectSpidersQuietly(
    AppConfig config,
  ) async {
    try {
      final result = await _materializeDirectSpiders(config);
      if (_disposed || !identical(effectiveConfig, config)) return result;
      _router.setDirectSpiders(result);
      _notifyIfAlive();
      final retrySite = _directHomeRetrySite;
      final selected = _selectedSite;
      if (identical(_directHomeRetryConfig, config) &&
          retrySite != null &&
          selected != null &&
          selected.key == retrySite.key &&
          selected.api == retrySite.api &&
          result.containsKey(selected.key)) {
        // 冷注册实测 37.3 秒：8 秒首屏等待只是让行，完成后补回一次抢跑的首页。
        _directHomeRetryConfig = null;
        _directHomeRetrySite = null;
        unawaited(
          loadHome(selected).catchError((Object error) {
            if (!_disposed && identical(effectiveConfig, config)) {
              log.warning('直连站源注册后首页重载失败：$error', scope: 'spider');
            }
          }),
        );
      }
      return result;
    } catch (error) {
      if (!_disposed && identical(effectiveConfig, config)) {
        log.warning('直连站源注册失败：$error', scope: 'spider');
      }
      return const {};
    } finally {
      if (identical(_directReadyConfig, config)) {
        _directReady = null;
      }
    }
  }

  /// 生效的出站代理设置（Phase 9 P1-9）。
  OutboundProxySettings get outboundProxy =>
      _uiPreferences?.outboundProxy ?? const OutboundProxySettings.defaults();

  /// 持久化出站代理设置，并按新设置重建 HTTP 客户端。
  Future<bool> setOutboundProxy(OutboundProxySettings settings) async {
    final store = _uiPreferences;
    if (store == null) return false;
    final ok = await store.rememberOutboundProxy(settings);
    _applyOutboundProxy();
    // 站点服务持有上一代客户端：必须重建，否则新设置不生效。
    _attachSiteService();
    _notifyIfAlive();
    return ok;
  }

  void _applyOutboundProxy() {
    final settings = outboundProxy;
    final preferences = _uiPreferences?.dohSettings ?? DohSettings.defaults;
    final config = _config;
    final endpoints = DohEndpoint.parseList(config?.doh);
    final hostMap = DohHostMap.parse(config?.hosts);
    // 内容也进签名：只比数量时，改了 hosts 的值不会触发重建。
    final endpointSignature = endpoints.map((e) => e.url).join(',');
    final hostSignature = hostMap.entries.entries
        .map((e) => '${e.key}=${e.value}')
        .join(',');
    // 输入没变就不重建：`_attachSiteService` 每次配置装配都会调用本方法，
    // 不设签名会反复关闭/新建客户端与解析器。
    final signature = [
      settings.enabled,
      settings.defaultProxyUrl,
      settings.validRules.length,
      preferences.enabled,
      preferences.url,
      preferences.cacheMinutes,
      endpointSignature,
      hostSignature,
      _injectedHttpClient != null,
    ].join('|');
    if (signature == _httpStackSignature) return;
    _httpStackSignature = signature;

    _disposeDohResolver();
    final resolver = _buildDohResolver();
    _dohResolver = resolver;
    final injected = _injectedHttpClient;
    final clientRebuilt = settings.isEffective || (resolver?.isUsable ?? false);
    if (!clientRebuilt && injected != null) {
      // 测试注入的客户端优先：不能因为一次 bootstrap 就换成真实 HttpClient。
      // 不调用 close()，否则会把注入的客户端一并关掉。
      _httpClient = HttpApiClient(client: injected, debugLog: _spiderDebugLog);
    } else if (!clientRebuilt) {
      _httpClient.close();
      _httpClient = HttpApiClient(debugLog: _spiderDebugLog);
    } else {
      _httpClient.close();
      _httpClient = HttpApiClient(
        client: createOutboundHttpClient(settings, doh: resolver),
        debugLog: _spiderDebugLog,
      );
    }
    log.info(
      '出站传输：代理=${settings.isEffective ? "开启" : "关闭"} '
      'DoH=${resolver?.isActive == true ? "开启" : "关闭"} '
      'hosts=${hostMap.entries.length} endpoints=${endpoints.length}',
      scope: 'proxy',
    );
    // 更新检查也走同一套出站设置：代理变了，旧客户端必须换掉。
    _resetUpdateService();
  }

  /// 构造 DoH 解析器：配置提供端点与 hosts，偏好提供开关/自定义端点/缓存时长。
  DohResolver? _buildDohResolver() {
    final preferences = _uiPreferences;
    final config = _config;
    final settings = preferences?.dohSettings ?? DohSettings.defaults;
    final endpoints = DohEndpoint.parseList(config?.doh);
    final hostMap = DohHostMap.parse(config?.hosts);
    if (!settings.enabled && hostMap.isEmpty) return null;
    if (settings.enabled &&
        !settings.hasCustomUrl &&
        endpoints.isEmpty &&
        hostMap.isEmpty) {
      return null;
    }
    return DohResolver(
      settings: settings,
      endpoints: endpoints,
      hostMap: hostMap,
      cachePath: p.join(paths.cacheDir, 'doh_cache.json'),
      log: log,
    );
  }

  void _disposeDohResolver() {
    _dohResolver?.close();
    _dohResolver = null;
  }

  /// 生效的 DoH 设置（Phase 9 P2-8）。
  DohSettings get dohSettings =>
      _uiPreferences?.dohSettings ?? DohSettings.defaults;

  /// 生效的 DoH 解析器；未启用时为 null。
  DohResolver? get dohResolver => _dohResolver;

  /// 持久化 DoH 设置并重建 HTTP 客户端/站点服务。
  Future<bool> setDohSettings(DohSettings settings) async {
    final store = _uiPreferences;
    if (store == null) return false;
    final ok = await store.rememberDohSettings(settings);
    _applyOutboundProxy();
    _attachSiteService();
    _notifyIfAlive();
    return ok;
  }

  /// 隐身模式（Phase 9 P2-8）：不写播放历史与搜索记录。
  bool get incognito => _uiPreferences?.incognito ?? false;

  /// 持久化隐身模式。
  Future<bool> setIncognito(bool value) async {
    final store = _uiPreferences;
    if (store == null) return false;
    final ok = await store.rememberIncognito(value);
    _notifyIfAlive();
    return ok;
  }

  /// 详细调试日志（爬虫入参/出参）开关；默认关闭。
  bool get spiderDebugLog => _spiderDebugLog.enabled;

  /// 切换详细调试日志：内存里立即生效，再异步写盘。
  ///
  /// 顺序是有意的：先应用后写盘，写盘失败也不会让开关看起来没生效。
  Future<bool> setSpiderDebugLog(bool value) async {
    _applySpiderDebugLog(value);
    final store = _uiPreferences;
    notifyListeners();
    if (store == null) return false;
    return store.rememberSpiderDebugLog(value);
  }

  /// 把开关落到两处：sidecar 日志旁路 + 日志单文件上限档位。
  ///
  /// 档位只在下次 `LogService._rotateIfNeeded` 判断时用新值，文件句柄不重建，
  /// 因此切换不需要重启（见 `LogService.maxFileBytes`）。
  void _applySpiderDebugLog(bool value) {
    _spiderDebugLog.enabled = value;
    log.maxFileBytes = LogService.maxFileBytesFor(verbose: value);
    log.info(value ? '详细调试日志已开启（爬虫入参/出参全量打印）' : '详细调试日志已关闭', scope: 'spider');
  }

  // ------------------------------------------------------------ 崩溃恢复 P2-8

  /// 上一次未正常退出的标记；用户点「继续/忽略」前一直保留。
  SessionMarker? get pendingRecovery => _pendingRecovery;

  /// 崩溃日志（最近一段，有界）；没有则为 null。
  String? get recoveryCrashLog => _sessionRecovery?.readCrashLog();

  SessionRecoveryStore? get sessionRecovery => _sessionRecovery;

  /// 用户已处理崩溃提示（继续播放或忽略）：删除标记。
  Future<void> dismissRecovery() async {
    _sessionRecovery?.acknowledgeRecovery();
    if (_pendingRecovery == null) return;
    _pendingRecovery = null;
    notifyListeners();
  }

  /// 正常退出路径：删除会话标记（同步写，进程可能马上结束）。
  void endSessionCleanly() {
    _sessionRecovery?.endSessionCleanly();
  }

  /// 记录崩溃时的播放上下文：只存标识与进度，**不存 URL/Header**。
  ///
  /// 节流：同一条集 5 秒内不重复写盘（播放器每秒都会上报进度）。
  void _recordRecoveryPlayback({
    required String siteKey,
    required Vod vod,
    required String flag,
    required String episodeName,
    required String episodeId,
    required Duration position,
    required Duration duration,
  }) {
    final store = _sessionRecovery;
    if (store == null) return;
    final key = '$siteKey|${vod.vodId}|$episodeId';
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (key == _recoveryEpisodeKey && nowMs - _recoveryWrittenAtMs < 5000) {
      return;
    }
    _recoveryEpisodeKey = key;
    _recoveryWrittenAtMs = nowMs;
    store.updatePlayback(
      SessionPlaybackContext(
        siteKey: siteKey,
        vodId: vod.vodId,
        vodName: vod.vodName,
        flag: flag,
        episodeName: episodeName,
        episodeId: episodeId,
        positionMs: position.inMilliseconds,
        durationMs: duration.inMilliseconds,
        updatedAtMs: nowMs,
      ),
      appVersion: appVersion,
    );
  }

  /// 生效的站点分组规则（Phase 9 P1-5）。
  SiteGroupSettings get siteGroupSettings =>
      _uiPreferences?.siteGroupSettings ?? const SiteGroupSettings.defaults();

  /// 持久化站点分组规则。
  Future<bool> setSiteGroupSettings(SiteGroupSettings settings) async {
    final store = _uiPreferences;
    if (store == null) return false;
    final ok = await store.rememberSiteGroupSettings(settings);
    _notifyIfAlive();
    return ok;
  }

  /// 广告过滤总开关（默认开启；配置没有规则时无效果）。
  bool get adBlockEnabled => _uiPreferences?.adBlockEnabled ?? true;

  /// 持久化广告过滤开关，并立即更新代理规则。
  Future<bool> setAdBlockEnabled(bool enabled) async {
    final store = _uiPreferences;
    if (store == null) return false;
    final ok = await store.rememberAdBlockEnabled(enabled);
    _applyAdRulesToProxy();
    // 直连 js/py 站点：每次配置装配后异步注册（不阻塞首页；失败只记日志）。
    _kickDirectRegistration();
    _notifyIfAlive();
    return ok;
  }

  /// 合并了注入站点的配置；没有注入时就是原配置对象。
  ///
  /// 注意：**不是** `_config`。任何需要“用户配置 + 注入”的地方都用它；
  /// 写回配置记录时必须用 [_config]，否则会把注入固化进用户配置。
  AppConfig? get effectiveConfig {
    final config = _config;
    final local = localSourceSites;
    // 没有任何配置、也没有本地源：保持既有语义（null = 还没配置）。
    if (config == null && local.isEmpty) return null;
    if (config != null && local.isEmpty && _injectedSites.isEmpty) {
      return config;
    }
    final cached = _effectiveConfigCache;
    if (cached != null) return cached;

    // 合并链：用户配置 → JSON 注入 → 本地源。前两级沿用既有语义（注入同 key
    // 覆盖配置），本地只**追加**、同 key 让位并记入 conflicts。
    AppConfig? base = config;
    if (base != null && _injectedSites.isNotEmpty) {
      base = mergeInjectedSites(base, _injectedSites);
    }
    final merged = mergeLocalSourceSites(base, local);
    _localSourceConflicts = merged.rejectedKeys;
    if (_localSourceConflicts.isNotEmpty) {
      log.warning(
        '本地源与既有站点同 key，已保留既有站点并跳过：${_localSourceConflicts.join(", ")}',
        scope: 'site',
      );
    }
    return _effectiveConfigCache = merged.config;
  }

  /// 本地导入源对应的站点条目（py/js 用 `spider-local:`，html 用 `web-home:`）。
  ///
  /// 停用的 webHome 源不出现在这里（用户停用即从选择列表消失）。
  List<Site> get localSourceSites => _localSitesCache ??= buildLocalSourceSites(
    // 只认 `spiders/local/<key>/`：根级 manifest 是被配置/直连注册引用的
    // 存在，自动变成站点会让站点集合与配置不一致（见 isImportedLocalSpider）。
    spiders: _spiderRegistry.sortedSpiders.where(
      (spider) => isImportedLocalSpider(spider, _spiderRegistry.root),
    ),
    webHomeSources: _safeWebHomeSources().values,
    // 停用的源不进站点列表：选择器、搜索与换源都不该再看见它。
    isEnabled: _localSourceEnable.isEnabled,
  );

  /// 被既有站点占用的本地 key（同 key 冲突的如实记录）。
  List<String> get localSourceConflicts =>
      List<String>.unmodifiable(_localSourceConflicts);

  /// 站点对应的本地 HTML 首页源；不是 HTML 形态或已停用/已删除时返回 null。
  ///
  /// 这是「HTML 条目点击后打开页面而不是加载首页」的识别接缝：调用方只需
  /// 判断返回值，不必自己解析 `api`。
  WebHomeSource? webHomeSourceForSite(Site site) {
    final key = webHomeKeyOfSite(site);
    if (key == null) return null;
    return _safeWebHomeSources()[key];
  }

  /// 本地源集合变化后统一失效缓存并重建站点服务/路由。
  ///
  /// 导入、刷新、启停、删除都必须走这里：只 `notifyListeners()` 不会让
  /// [effectiveConfig]/[siteItems] 重新合并（缓存还在），用户看到的是导入前后一样的列表。
  void _invalidateLocalSites() {
    if (_disposed) return;
    _localSitesCache = null;
    _webHomeSourcesCache = null;
    _allWebHomeSourcesCache = null;
    _effectiveConfigCache = null;
    // 站点服务与分类判定都读 effectiveConfig：重建它，本地源才能立刻可选/可用。
    _attachSiteService();
    _notifyIfAlive();
  }

  /// 当前注入站点（供设置页展示）。
  List<InjectedSiteEntry> get injectedSites =>
      List<InjectedSiteEntry>.unmodifiable(_injectedSites);

  /// 从粘贴文本识别并保存注入站点；返回新增/更新的条数。
  Future<int> addInjectedSites(String text) async {
    final db = _database;
    if (db == null) return 0;
    final sites = parseInjectedSites(text);
    if (sites.isEmpty) return 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final site in sites) {
      db.upsertInjectedSite(InjectedSiteEntry(site: site, updatedAt: now));
    }
    _reloadInjectedSites();
    log.info('站点注入：写入 ${sites.length} 个站点', scope: 'config');
    return sites.length;
  }

  /// 启用/停用一条注入站点。
  Future<bool> setInjectedSiteEnabled(String key, bool enabled) async {
    final db = _database;
    if (db == null) return false;
    final existing = _injectedSites.where((entry) => entry.key == key).toList();
    if (existing.isEmpty) return false;
    db.upsertInjectedSite(
      existing.first.copyWith(
        enabled: enabled,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    _reloadInjectedSites();
    return true;
  }

  /// 删除一条注入站点（不影响用户配置里的同名站点）。
  Future<bool> removeInjectedSite(String key) async {
    final db = _database;
    if (db == null) return false;
    db.deleteInjectedSite(key);
    _reloadInjectedSites();
    return true;
  }

  void _reloadInjectedSites() {
    final db = _database;
    if (db != null) {
      try {
        _injectedSites = db.injectedSites();
      } catch (error) {
        log.warning('重新读取注入站点失败：$error', scope: 'config');
      }
    }
    _effectiveConfigCache = null;
    _attachSiteService();
    notifyListeners();
  }

  void _applyAdRulesToProxy() {
    final config = _config;
    final manual = config == null || !adBlockEnabled
        ? const AdRuleSet.empty()
        : AdRuleSet.fromConfig(config);
    _proxy.setAdRules(manual);
    if (!adBlockEnabled || !aiAdDetectionEnabled) {
      _proxy.aiSessionRules = const AdRuleSet.empty();
      _proxy.aiSessionFingerprint = null;
    }
  }

  /// 生效的解析接口失败切换设置（Phase 9）。
  ParseFailoverSettings get parseFailoverSettings =>
      _uiPreferences?.parseFailover ?? const ParseFailoverSettings.defaults();

  /// 持久化解析接口失败切换设置。
  Future<bool> setParseFailoverSettings(ParseFailoverSettings settings) async {
    final store = _uiPreferences;
    if (store == null) return false;
    final ok = await store.rememberParseFailover(settings.normalized());
    _notifyIfAlive();
    return ok;
  }

  /// 持久化站点排序偏好。
  Future<bool> setSiteOrder(SiteOrderSettings settings) async {
    final store = _uiPreferences;
    if (store == null) return false;
    final ok = await store.rememberSiteOrder(settings);
    _notifyIfAlive();
    return ok;
  }

  /// 保存站点列表的手动顺序（当前配置全部站点 key 的先后）。
  ///
  /// 传空列表等于「恢复默认」：清掉手动顺序，列表回到配置顺序。屏蔽集合不受影响。
  Future<bool> setSiteManualOrder(List<String> orderedKeys) async {
    final store = _uiPreferences;
    if (store == null) return false;
    final current = siteListOverrides;
    final next = SiteListOverrides(
      order: normalizeSiteKeys(orderedKeys),
      blocked: current.blocked,
    );
    final ok = await store.rememberSiteListOverrides(siteListScopeKey, next);
    if (ok) _notifyIfAlive();
    return ok;
  }

  /// 屏蔽/取消屏蔽一个站点（[blocked] 为 true 表示屏蔽）。
  ///
  /// 被屏蔽站点从站点列表隐去，且不参与多站点搜索与换源候选；当前正在使用的
  /// 站点被屏蔽时**本次会话照常使用**，只是下次选择时看不到它。
  Future<bool> setSiteBlocked(String siteKey, bool blocked) async {
    final store = _uiPreferences;
    final key = siteKey.trim();
    if (store == null || key.isEmpty) return false;
    final current = siteListOverrides;
    final next = {...current.blocked};
    final changed = blocked ? next.add(key) : next.remove(key);
    if (!changed) return true;
    final ok = await store.rememberSiteListOverrides(
      siteListScopeKey,
      current.copyWith(blocked: next),
    );
    if (ok) _notifyIfAlive();
    return ok;
  }

  /// 站点健康分：成功次数 / 总次数；没有样本的站点不出现在表里。
  Map<String, double> siteHealthScores() {
    final db = _database;
    if (db == null) return const {};
    final scores = <String, double>{};
    for (final health in db.siteHealth()) {
      final ok =
          health.homeOk + health.categoryOk + health.detailOk + health.playOk;
      final total =
          health.homeTotal +
          health.categoryTotal +
          health.detailTotal +
          health.playTotal;
      if (total <= 0) continue;
      scores[health.siteKey] = ok / total;
    }
    return scores;
  }

  /// 生效的弹幕库设置（Phase 9）。
  DanmakuSettings get danmakuSettings =>
      _uiPreferences?.danmakuSettings ?? const DanmakuSettings.defaults();

  /// 持久化弹幕库设置。
  Future<bool> setDanmakuSettings(DanmakuSettings settings) async {
    final store = _uiPreferences;
    if (store == null) return false;
    final ok = await store.rememberDanmakuSettings(settings);
    _notifyIfAlive();
    return ok;
  }

  /// 本地猫源内置的弹幕服务地址。
  ///
  /// 由 [CatNodeRuntime.onDanmakuReady] 写入：猫源启动后后台探到弹幕服务就填，
  /// 猫源停止（换源/退出）时清空。空表示没有。它排在站点配置之后，因为站点配置
  /// 是用户显式选择的默认值，猫源只是「随装随带」的便利。
  String _bundleDanmakuApiUrl = '';

  void setBundleDanmakuApiUrl(String url) {
    final next = url.trim();
    if (next == _bundleDanmakuApiUrl) return;
    _bundleDanmakuApiUrl = next;
    _notifyIfAlive();
  }

  /// 当前生效的全部弹幕源与来源（用户启用的源 > 站点配置 danmaku 字段 > 本地猫源）。
  ///
  /// 播放器、设置页与搜索对话框只能从这里取：优先级只允许有一份实现。
  ResolvedDanmakuSources get resolvedDanmakuSources => resolveDanmakuSources(
    settings: danmakuSettings,
    // 刻意读**原始配置**而不是合并结果：合并链（注入/本地源）是逐字段构造
    // `AppConfig`，不能保证顺带保留每个字段；漏一个字段的后果是站点配置的
    // `danmaku` 被静默丢掉、优先级掉到猫源。语义上也与安卓
    // `VodConfig.getConfig().getDanmaku()` 一致：读的是配置原文。
    configDanmaku: _config?.danmaku,
    bundleDanmaku: _bundleDanmakuApiUrl,
  );

  /// 当前生效的首条弹幕库地址与来源（旧单地址 API）。
  ///
  /// 由 [resolvedDanmakuSources] 派生而不是自己再算一遍：播放器这一轮仍只认
  /// 单地址，两份实现早晚会在「哪档优先」上分叉。
  ResolvedDanmakuApi get resolvedDanmakuApi {
    final resolved = resolvedDanmakuSources;
    if (!resolved.isConfigured) {
      return const ResolvedDanmakuApi(url: '', source: DanmakuApiSource.none);
    }
    return ResolvedDanmakuApi(
      url: resolved.sources.first.url,
      source: resolved.origin,
    );
  }

  /// 搜索弹幕库时要用的地址；空表示没有可用地址。
  String get danmakuApiUrl => resolvedDanmakuApi.url;

  /// 自动搜索是否真的会发起请求：开关打开 **且** 有可用地址。
  bool get canAutoSearchDanmaku =>
      danmakuSettings.autoSearch && resolvedDanmakuSources.isConfigured;

  /// 持久化字幕源设置。
  Future<bool> setSubtitleSettings(SubtitleSettings settings) async {
    final store = _uiPreferences;
    if (store == null) return false;
    final ok = await store.rememberSubtitleSettings(settings);
    _notifyIfAlive();
    return ok;
  }

  Future<void> setLiveSiteKeywords(List<String> value) async {
    final store = _uiPreferences;
    if (store == null) return;
    await store.setLiveSiteKeywords(value);
    _notifyIfAlive();
  }

  /// 持久化直播设置。
  Future<bool> setLiveSettings(LiveSettings settings) async {
    final store = _uiPreferences;
    if (store == null) return false;
    final ok = await store.rememberLiveSettings(settings);
    _notifyIfAlive();
    return ok;
  }

  /// 持久化播放参数。写盘失败不影响当前会话，但都通知 UI 重建。
  Future<bool> setPlayerOptions(PlayerOptions options) async {
    final store = _uiPreferences;
    if (store == null) return false;
    final ok = await store.rememberPlayerOptions(options);
    _notifyIfAlive();
    return ok;
  }

  /// 持久化弹幕显示样式（Phase 9 P0-7）。写盘失败不影响当前会话。
  Future<bool> setDanmakuStyle(DanmakuStyle style) async {
    final store = _uiPreferences;
    if (store == null) return false;
    final ok = await store.rememberDanmakuStyle(style);
    _notifyIfAlive();
    return ok;
  }

  /// 持久化字幕显示样式（P1-4）。写盘失败不影响当前会话。
  Future<bool> setSubtitleStyle(SubtitleStyle style) async {
    final store = _uiPreferences;
    if (store == null) return false;
    final ok = await store.rememberSubtitleStyle(style);
    _notifyIfAlive();
    return ok;
  }

  /// 持久化屏显样式（P1-4）。写盘失败不影响当前会话。
  Future<bool> setOsdStyle(OsdStyle style) async {
    final store = _uiPreferences;
    if (store == null) return false;
    final ok = await store.rememberOsdStyle(style);
    _notifyIfAlive();
    return ok;
  }

  // ---------------------------------------------------------------- 片头片尾

  /// 某部影片的片头/片尾标记（Phase 9）。
  SkipSegments skipSegmentsFor({
    required String siteKey,
    required String vodId,
  }) {
    final db = _database;
    if (db == null) return const SkipSegments.none();
    try {
      return db.skipSegmentsFor(siteKey: siteKey, vodId: vodId);
    } catch (error) {
      log.warning('读取片头片尾失败：$error', scope: 'player');
      return const SkipSegments.none();
    }
  }

  /// 写入片头/片尾标记；null 表示清除该侧。
  Future<bool> saveSkipSegments({
    required String siteKey,
    required String vodId,
    int? introEndMs,
    int? outroStartMs,
  }) async {
    final db = _database;
    if (db == null) return false;
    try {
      db.upsertSkipSegments(
        siteKey: siteKey,
        vodId: vodId,
        introEndMs: introEndMs,
        outroStartMs: outroStartMs,
      );
      notifyListeners();
      return true;
    } catch (error) {
      log.error('保存片头片尾失败：$error', scope: 'player');
      return false;
    }
  }

  // ---------------------------------------------------------- 字幕/弹幕记忆

  SubtitleMatchRecord? subtitleMatchFor({
    required String siteKey,
    required String vodId,
    required String episodeName,
  }) {
    final db = _database;
    if (db == null) return null;
    try {
      return db.subtitleMatchFor(
        siteKey: siteKey,
        vodId: vodId,
        episodeName: episodeName,
      );
    } catch (error) {
      log.warning('读取字幕记忆失败：$error', scope: 'subtitle');
      return null;
    }
  }

  Future<bool> rememberSubtitleMatch(SubtitleMatchRecord record) async {
    final db = _database;
    if (db == null) return false;
    try {
      db.upsertSubtitleMatch(record);
      return true;
    } catch (error) {
      log.error('保存字幕记忆失败：$error', scope: 'subtitle');
      return false;
    }
  }

  Future<bool> forgetSubtitleMatch({
    required String siteKey,
    required String vodId,
    required String episodeName,
  }) async {
    final db = _database;
    if (db == null) return false;
    try {
      db.deleteSubtitleMatch(
        siteKey: siteKey,
        vodId: vodId,
        episodeName: episodeName,
      );
      return true;
    } catch (error) {
      log.error('删除字幕记忆失败：$error', scope: 'subtitle');
      return false;
    }
  }

  DanmakuMatchRecord? danmakuMatchFor({
    required String siteKey,
    required String vodId,
    required String episodeName,
  }) {
    final db = _database;
    if (db == null) return null;
    try {
      return db.danmakuMatchFor(
        siteKey: siteKey,
        vodId: vodId,
        episodeName: episodeName,
      );
    } catch (error) {
      log.warning('读取弹幕记忆失败：$error', scope: 'danmaku');
      return null;
    }
  }

  Future<bool> rememberDanmakuMatch(DanmakuMatchRecord record) async {
    final db = _database;
    if (db == null) return false;
    try {
      db.upsertDanmakuMatch(record);
      return true;
    } catch (error) {
      log.error('保存弹幕记忆失败：$error', scope: 'danmaku');
      return false;
    }
  }

  Future<bool> forgetDanmakuMatch({
    required String siteKey,
    required String vodId,
    required String episodeName,
  }) async {
    final db = _database;
    if (db == null) return false;
    try {
      db.deleteDanmakuMatch(
        siteKey: siteKey,
        vodId: vodId,
        episodeName: episodeName,
      );
      return true;
    } catch (error) {
      log.error('删除弹幕记忆失败：$error', scope: 'danmaku');
      return false;
    }
  }

  /// 主题模式（`dark` / `light` / `system`）。
  ///
  /// 这一层只暴露原始字符串、不暴露 Flutter 的 `ThemeMode`：状态层目前只依赖
  /// `foundation`，不为一个枚举把 `material` 拉进来。映射放在 `app.dart`。
  ///
  /// `_uiPreferences` 为 null（未 bootstrap）时退回默认暗色，不让主题失败。
  String get themeMode => _uiPreferences?.themeMode ?? UiThemeMode.dark;

  /// 用户是否**显式选过**主题。设置页据此区分"跟随系统"与"从未选过"。
  bool get hasExplicitThemeMode =>
      _uiPreferences?.hasExplicitThemeMode ?? false;

  /// 持久化主题模式。
  ///
  /// 写盘失败不影响当前会话（内存里已生效），但无论如何都通知 UI 重建——
  /// 用户刚点了开关，界面必须立刻反映选择。
  Future<bool> setThemeMode(String mode) async {
    final store = _uiPreferences;
    if (store == null) return false;
    final ok = await store.rememberThemeMode(mode);
    _notifyIfAlive();
    return ok;
  }

  /// 点击历史记录的行为（`docs/phase6/design/01` §4）：`detail` 进详情页 /
  /// `play` 直接播放。
  ///
  /// 与 [themeMode] 同构：这一层只暴露原始字符串，归一化由 store 负责，
  /// UI 只依赖 `AppState`。
  ///
  /// `_uiPreferences` 为 null（未 bootstrap）时退回默认 `detail`，
  /// 不让历史页因偏好未装配而崩。
  String get historyClickAction =>
      _uiPreferences?.historyClickAction ?? UiHistoryClickAction.detail;

  /// 持久化点击历史行为。
  ///
  /// 与 [setThemeMode] 同构：`store` 会把非法值归一到 `detail`，写盘失败不影响
  /// 当前会话（内存里已生效），但无论如何都通知 UI 重建。
  Future<bool> setHistoryClickAction(String mode) async {
    final store = _uiPreferences;
    if (store == null) return false;
    final ok = await store.rememberHistoryClickAction(mode);
    _notifyIfAlive();
    return ok;
  }

  /// 播放历史的可见范围（[UiHistoryScope]）：`source` 只看当前源，
  /// `global` 看全部源（对齐安卓 `Setting.isGlobalHistoryEnabled` 的开关位）。
  ///
  /// 默认 `source`：桥接后每台设备上的每个源都会成为一条配置记录，它们的
  /// 站点 key 会重名（都是 `csp_xxx`），不按源隔离就会出现"看了 A 源的剧、
  /// B 源的同一部剧也显示进度"的串源问题。
  String get historyScope =>
      _uiPreferences?.historyScope ?? UiHistoryScope.source;

  bool get historyScopeIsGlobal => historyScope == UiHistoryScope.global;

  /// 持久化历史范围偏好。
  Future<bool> setHistoryScope(String scope) async {
    final store = _uiPreferences;
    if (store == null) return false;
    final ok = await store.rememberHistoryScope(scope);
    _notifyIfAlive();
    return ok;
  }

  /// 历史记录的**同名聚合模式**（[UiHistoryAggregation]）：`tmdb` 优先按
  /// TMDB 身份合并、缺失时按片名+年份；`title` 只按片名；`none` 每集独立。
  ///
  /// 默认 `tmdb`：用户 2026-10-27 明确要求「默认这种模式，同时保留现在
  /// 每集独立的历史记录格式允许用户手动切换」。
  String get historyAggregation =>
      _uiPreferences?.historyAggregation ?? UiHistoryAggregation.tmdb;

  bool get historyAggregationIsOff =>
      historyAggregation == UiHistoryAggregation.off;

  /// 持久化历史聚合模式。
  Future<bool> setHistoryAggregation(String mode) async {
    final store = _uiPreferences;
    if (store == null) return false;
    final ok = await store.rememberHistoryAggregation(mode);
    _notifyIfAlive();
    return ok;
  }

  /// 选集视图模式（[UiEpisodeViewMode]）：`grid` 网格 / `list` 列表。
  ///
  /// 全局一份，两个详情页（浏览页与 TMDB 详情页）共享；默认网格。
  /// `_uiPreferences` 为 null（未 bootstrap）时退回默认，不让详情页崩。
  String get episodeViewMode =>
      _uiPreferences?.episodeViewMode ?? UiEpisodeViewMode.grid;

  /// 持久化选集视图模式；归一化由 store 负责。
  ///
  /// 未装配偏好（单测未 bootstrap）时安静跳过，不抛异常。
  Future<void> setEpisodeViewMode(String mode) async {
    final store = _uiPreferences;
    if (store == null) return;
    await store.rememberEpisodeViewMode(mode);
    _notifyIfAlive();
  }

  bool get episodeAggregateVersions =>
      _uiPreferences?.episodeAggregateVersions ?? true;

  Future<void> setEpisodeAggregateVersions(bool enabled) async {
    final store = _uiPreferences;
    if (store == null) return;
    await store.rememberEpisodeAggregateVersions(enabled);
    _notifyIfAlive();
  }

  bool get episodeShowScrapedName =>
      _uiPreferences?.episodeShowScrapedName ?? true;

  Future<void> setEpisodeShowScrapedName(bool showScraped) async {
    final store = _uiPreferences;
    if (store == null) return;
    await store.rememberEpisodeShowScrapedName(showScraped);
    _notifyIfAlive();
  }

  /// 当前生效配置的来源标识（见 `core/source_key.dart`）。
  ///
  /// 桥接源为 `bridge|<deviceUuid>|<interfaceKey>`，本地导入为
  /// `local|<origin>`；没有生效配置时为空串。
  String get activeSourceKey {
    final record = _activeRecord;
    return record == null ? '' : sourceKeyOfRecord(record);
  }

  /// 一条配置记录的播放源标识。
  ///
  /// 与 [activeSourceKey] 必须**同源**：启动恢复时按这个标识判断「记忆里那条
  /// 是不是现在这条」，两处规则一旦漂移就会恢复错配置。
  static String sourceKeyOfRecord(ConfigRecord record) {
    final interfaceKey = record.bridgeInterfaceKey.trim();
    if (interfaceKey.isNotEmpty) {
      final key = BridgeSourceKey.of(
        deviceUuid: record.bridgeDevice.trim(),
        interfaceKey: interfaceKey,
      );
      if (key.isNotEmpty) return key;
    }
    if (record.sourceKey.isNotEmpty) return record.sourceKey;
    return LocalSourceKey.of(record.origin);
  }

  /// 读历史时的来源过滤：空串表示**不**过滤（全局历史）。
  String get historySourceFilter => historyScopeIsGlobal ? '' : activeSourceKey;

  /// 测试口子：不经 bootstrap 直接装配 UI 偏好 store。
  ///
  /// 与 `_uiPreferences` 可空的原因相同（见字段注释）：单测不调 bootstrap。
  /// 生产代码不得调用；bootstrap 是唯一的正规装配点。
  @visibleForTesting
  void attachUiPreferences(UiPreferencesStore store) {
    _uiPreferences = store;
    // 搜索历史与偏好同源（bootstrap 里同此逻辑）。
    _searchHistory = store.searchKeywords;
  }

  bool get hasConfig => effectiveConfig?.sites.isNotEmpty ?? false;

  /// 当前配置里**真正能用**的站点数（与站点选择器同一套判定）。
  ///
  /// 只报总数会误导：一份 111 站点的配置可能全指向同一个带原生库的 jar，
  /// 导入成功但一个都用不了（用户 2026-11 反馈）。
  int get usableSiteCount =>
      siteItems.where((item) => item.availability.available).length;

  /// 站点列表(含运行时可用性),隐藏 `hide=1` 的站点。
  ///
  /// 使用实例级 [SpiderRouter.classifySite] 而非静态 [SpiderRouter.classify],
  /// 才能对 `spider-local:` 站点给出真实可用性(§8.1、§9.7)。
  List<SiteListItem> get siteItems {
    final config = effectiveConfig;
    if (config == null) return const [];
    final order = siteListOverrides.order;
    final cached = _siteItemsCache;
    if (cached != null &&
        identical(_siteItemsCacheConfig, config) &&
        _siteItemsCacheRevision == _router.siteRevision &&
        _sameSiteOrder(_siteItemsCacheOrder, order)) {
      return cached;
    }
    final items = <SiteListItem>[
      for (final site in config.sites)
        if (!site.hide)
          SiteListItem(
            site: site,
            // HTML 首页不是爬虫：不能交给路由判可用性（会报「manifest 未注册」，
            // 而真实原因是它由 WebView2 承载）。走路由前先识别这一形态。
            availability: webHomeSourceForSite(site) != null
                ? webHomeSiteAvailability
                // §8.1:可用性判定必须区分「运行时未安装」与「站点不可用」,
                // 因此这里用带注册表的实例方法，而不是静态 `classify`。
                : _router.classifySite(site),
          ),
    ];
    // 手动顺序是**本地覆盖**，不改配置文件：未列入顺序的站点保持配置顺序
    // 追加在后，所以新增站点不会插队，列表也不会每次打开都换位置。
    _rememberSiteItems(config, order, items);
    if (order.isEmpty || items.length <= 1) return items;
    final byKey = {for (final item in items) item.site.key: item};
    final ordered = [
      for (final key in orderSiteKeysByManual(
        keys: [for (final item in items) item.site.key],
        savedOrder: order,
      ))
        byKey[key]!,
    ];
    _rememberSiteItems(config, order, ordered);
    return ordered;
  }

  /// 站点表缓存（按配置实例 + 手动顺序 + [SpiderRouter.siteRevision] 失效）。
  ///
  /// 为什么必须缓存：`csp_*`（加固壳）站点的可用性判定要读磁盘——
  /// `probeRecord`/`intakeRecord` 各一次同步读 + `jsonDecode`，再按入口 jar
  /// 做静态检测。本机实测 111 个加固壳站点**一遍 350 ms（冷 927 ms，单站
  /// 3.2–8.4 ms）**；而搜索页一次 build 会读 2–3 遍（`searchScopeGroups`、
  /// `_siteNameOf`、站点选择器），于是每次重建都要在主 isolate 上烧
  /// 0.7–2.8 s——用户看到的就是「首页和搜索来回点都卡、整个 App 都卡」。
  ///
  /// 与判定本身的分工：磁盘状态一改，写入方调
  /// [SpiderRouter.notifySiteFilesChanged]；运行时/直连/换配置由路由自己 +1。
  /// 因此缓存**不会**让判定落后于磁盘。
  List<SiteListItem>? _siteItemsCache;
  AppConfig? _siteItemsCacheConfig;
  int _siteItemsCacheRevision = -1;
  List<String>? _siteItemsCacheOrder;

  void _rememberSiteItems(
    AppConfig config,
    List<String> order,
    List<SiteListItem> items,
  ) {
    _siteItemsCache = items;
    _siteItemsCacheConfig = config;
    _siteItemsCacheOrder = List<String>.of(order);
    _siteItemsCacheRevision = _router.siteRevision;
  }

  static bool _sameSiteOrder(List<String>? a, List<String> b) {
    if (a == null || a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// 当前配置里可用于**搜索范围限定**的分组（按站点顺序去重）。
  ///
  /// 与结果页的分组筛选不同：范围选择发生在搜索**之前**，因此分组来源必须是
  /// 整个配置（上游 `Site.getGroups(VodConfig.get().getSites())`），不能只从
  /// 上次结果里推导。只统计可搜索且未隐藏的站点。
  List<String> get searchScopeGroups {
    final seen = <String>[];
    for (final item in siteItems) {
      if (!item.site.searchable) continue;
      // 被屏蔽站点不参与搜索：只剩屏蔽站点才存在的分组不该留在范围选择里，
      // 否则用户会选中一个「一个站点都不会发请求」的范围。
      if (isSiteBlocked(item.site.key)) continue;
      for (final group in siteGroupsOf(
        item.site.name,
        rules: siteGroupSettings.enabledRules,
      )) {
        if (!seen.contains(group)) seen.add(group);
      }
    }
    return seen;
  }

  /// 启动：目录、日志、数据库、上一个配置。
  ///
  /// 任一步骤失败都记录日志并继续，保证“数据库异常不影响播放器启动”（§16.3）。
  Future<void> bootstrap() async {
    _clearRestoredConfigSourceWarning();
    final stopwatch = Stopwatch()..start();
    final directoryFailures = await paths.ensureDirectories();
    if (directoryFailures.isNotEmpty) {
      log.warning('部分目录创建失败：${directoryFailures.join("; ")}');
    }

    // 目录「存在」不代表「可写」：Windows 强制完整性控制下，低完整性进程
    // 对中等完整性目录只读，而 DACL 看起来完全正常。先实测一次，否则后面
    // 只能看到一个 SQLITE_READONLY，看不出根因（2026-10-20 现场故障）。
    final writeFailures = <String>[];
    for (final dir in [paths.configDir, paths.dataDir, paths.logDir]) {
      final error = await paths.probeWritable(dir);
      if (error != null) writeFailures.add('$dir: $error');
    }
    _storageWarnings = writeFailures;
    if (writeFailures.isNotEmpty) {
      // 日志文件本身很可能就在这批不可写的目录里，必须同时打 stderr：
      // 否则这条唯一的线索只留在内存缓冲里，随进程退出一起消失。
      stderr.writeln('[storage] 数据目录不可写：${writeFailures.join("; ")}');
    }

    LogService.logDirectoryOverride = paths.logDir;
    await log.open(paths.logDir);

    // 解析器 type=0/4 的浏览器组件接线：显式环境变量 → 已安装组件 → 系统浏览器。
    // 只是登记引擎，不启动浏览器（每次嗅探起一个、结束即回收），启动耗时可忽略。
    initializeSniffRuntime(paths);
    // 解析轨迹：骨架永远记录（哪个源、什么目标、结果/失败）；逐请求细节复用
    // 详细调试日志开关，关闭时只留骨架，不刷嗅探/HTTP 事件。
    installParseTrace(
      trace: (line) => log.info(line, scope: 'parse'),
      verbose: (line) {
        if (_spiderDebugLog.enabled) log.info(line, scope: 'parse');
      },
    );
    for (final failure in writeFailures) {
      log.error('数据目录不可写，本次运行不会保存历史/设置：$failure', scope: 'storage');
    }

    // 崩溃恢复（Phase 9 P2-8）：读上一次会话标记，再写本次标记。
    // 标记存在且 pid 不是自己 → 上次进程没有走正常退出路径。
    final recovery = _sessionRecovery ??= SessionRecoveryStore(
      dataDir: paths.dataDir,
      log: log,
    );
    final previousSession = recovery.readMarker();
    if (previousSession != null &&
        previousSession.pid != SessionRecoveryStore.currentPid) {
      _pendingRecovery = previousSession;
      log.warning(
        '检测到上次未正常退出：${describeRecoveredSession(previousSession, DateTime.now())}',
        scope: 'recovery',
      );
    }
    recovery.beginSession(appVersion: appVersion);

    // 本地导入源（`spiders/local/<key>/`，见 [SpiderManifestRegistry.scan]）必须在
    // 恢复配置**之前**进注册表：`_attachSiteService` 用 effectiveConfig 建站点服务，
    // 晚扫描会让重启后的首屏站点列表缺掉用户上次导入的本地源
    // （用户看到的是「导入的源重启就不见了」）。
    await _spiderRegistry.scan();
    _localSitesCache = null;
    _webHomeSourcesCache = null;
    _effectiveConfigCache = null;

    // 「最后一次使用的配置」记忆（Phase 10）：必须早于设备历史读取之后的
    // 任何决定，但**读取本身不探测**——探测等 UI 首帧之后再做（不能拖慢启动）。
    _lastConfigStore = LastConfigStore(dataDir: paths.dataDir, log: log);
    _lastConfigRecord = _lastConfigStore!.read();

    // 安卓接入与同步设置（Phase 5）：读取失败不阻塞启动，退回默认（全关）。
    await syncState.load();

    // TMDB 设置（`03` §5.3）：读取失败不阻塞启动，退回默认配置。
    await _tmdbConfigStore.load();

    // AI 配置（`docs/phase6/design/04` §4）：同样不阻塞启动。
    _aiConfigStore = AiConfigStore(path: paths.settingsPath, log: log);
    await _aiConfigStore.load();

    // UI 偏好（最近使用的站点）：同样不阻塞启动。
    final uiPreferences = UiPreferencesStore(
      path: paths.settingsPath,
      log: log,
    );
    await uiPreferences.load();
    _uiPreferences = uiPreferences;
    // 搜索历史与偏好同源：启动时从磁盘恢复（上游安卓每次进搜索页都读
    // `Setting.getKeyword()`；PC 端在 bootstrap 恢复一次，后续增删走 store）。
    _searchHistory = uiPreferences.searchKeywords;
    // 详细调试日志：从设置恢复后立即应用（含 2MB/20MB 档位）。
    _applySpiderDebugLog(uiPreferences.spiderDebugLog);
    // 出站代理：从设置恢复后立即重建 HTTP 客户端（未开启时等价于默认客户端）。
    _applyOutboundProxy();

    // 应用更新偏好（ADR-0015）：读取失败只回落默认值，不阻塞启动；
    // 真正的检查由壳层首帧之后调 maybeAutoCheckForUpdates 发起。
    final updatePreferencesStore = UpdatePreferencesStore(
      path: paths.settingsPath,
      log: log,
    );
    await updatePreferencesStore.load();
    _updatePreferencesStore = updatePreferencesStore;
    _updatePreferences = updatePreferencesStore.preferences;

    final openResult = AppDatabase.open(paths.databasePath);
    _database = openResult.database;
    if (!openResult.succeeded) {
      log.error('数据库打开失败，降级为无历史模式：${openResult.error}');
    }
    if (_database != null) {
      try {
        _injectedSites = _database!.injectedSites();
      } catch (error) {
        log.warning('读取注入站点失败：$error', scope: 'config');
      }
    }

    var platform = Platform.operatingSystem;
    var architecture = _abiArchitecture();
    if (Platform.isWindows) {
      platform = 'windows';
      architecture = _windowsArchitecture();
    } else if (Platform.isLinux) {
      architecture = switch (Abi.current()) {
        Abi.linuxIA32 => 'x86',
        final abi => abi.toString().split('_').last,
      };
    }

    if (_database != null) {
      try {
        _configs = _database!.listConfigs();
        _activeRecord = _database!.activeConfig();
        // 启动恢复以「最后一次使用的配置」为准：`is_active` 只由本机路径维护，
        // 而交换/恢复数据目录时它可能指向一条并不是用户最后在用的记录。
        // 只认**已存在的记录**：记忆指向已删除的记录时不改任何东西（静默回落）。
        final memory = _lastConfigRecord;
        if (memory != null) {
          final remembered = _recordBySourceKey(
            memory.sourceKey,
            memory.recordId,
          );
          if (remembered != null && remembered.id != _activeRecord?.id) {
            try {
              _database!.activateConfig(remembered.id);
              _configs = _database!.listConfigs();
              _activeRecord = _database!.activeConfig();
              log.info('按上次使用的配置恢复当前配置 #${remembered.id}', scope: 'config');
            } catch (error) {
              log.warning('按上次使用的配置恢复失败：$error', scope: 'config');
            }
          }
        }
        final record = _activeRecord;
        if (record != null && record.json.isNotEmpty) {
          // 猫源配置的站点 `api` 指向本机随机端口，重启后端口已变；必须按保存的
          // 原始猫源地址重新拉起 bundle，而不是直接复用旧 JSON。
          final reserved = await _reserveCatConfig(record.origin);
          _config = reserved ?? parseConfigRecord(record.json);
          _attachSiteService();
          log.info(
            '恢复配置：${record.name} sites=${_config!.sites.length} '
            'cat=${reserved != null} origin=${redactUrl(record.origin)}',
          );
        }
      } catch (error) {
        log.error('恢复已保存配置失败：$error');
        _config = null;
        _activeRecord = null;
      }
    }

    if (_siteService == null && effectiveConfig != null) {
      _attachSiteService();
    }

    stopwatch.stop();
    _startupInfo = StartupInfo(
      version: appVersion,
      flavor: appBuildFlavor,
      platform: platform,
      architecture: architecture,
      playerEngine: 'media-kit (libmpv)',
      dartVersion: Platform.version,
      configDir: paths.configDir,
      cacheDir: paths.cacheDir,
      logDir: paths.logDir,
      databasePath: paths.databasePath,
      databaseError: openResult.error,
      storageWarnings: _storageWarnings,
      startupLatency: stopwatch.elapsed,
    );
    log.info(_startupInfo!.oneLine, scope: 'startup');
    log.info(
      _startupInfo!.detailLines.replaceAll('\n', ' | '),
      scope: 'startup',
    );

    _configPhase = hasConfig ? LoadPhase.ready : LoadPhase.idle;
    final restoredRecord = _activeRecord;
    if (_config != null && restoredRecord != null) {
      unawaited(_inspectRestoredConfigSource(restoredRecord));
    }
    // 追番调度：应用运行期间生效；关闭时不会创建定时器（测试也不会残留 Timer）。
    _restartFollowingTimer();
    _notifyIfAlive();
  }

  // ---------------------------------------------------------------- 备份/恢复

  BackupService get backupService => BackupService(paths: paths, log: log);

  /// 默认备份路径：`<data>/backups/webhtv-backup-<时间>.zip`。
  String defaultBackupPath({DateTime? now}) => p.join(
    paths.dataDir,
    'backups',
    defaultBackupFileName(now ?? DateTime.now()),
  );

  /// 生成备份（数据库用 `VACUUM INTO` 快照，避免复制到半个事务）。
  Future<BackupCreateResult> createBackup({String? outputPath, DateTime? now}) {
    final database = _database;
    if (database == null) {
      return Future.value(
        const BackupCreateResult(ok: false, path: '', message: '本地存储不可用，无法备份'),
      );
    }
    return backupService.createBackup(
      database: database,
      outputPath: outputPath?.trim().isNotEmpty == true
          ? outputPath!.trim()
          : defaultBackupPath(now: now),
      appVersion: appVersion,
      now: now,
    );
  }

  Future<BackupInspectionResult> inspectBackup(String path) =>
      backupService.inspect(path);

  /// 应用备份；成功返回 null，失败返回用户可读原因。
  ///
  /// 流程：校验 → 关闭数据库 → 写设置与库（失败回滚）→ 重新 bootstrap。
  /// **校验在关闭数据库之前**：坏备份不会让当前会话先失去本地存储。
  Future<String?> restoreBackup(String path) async {
    final BackupContents contents;
    try {
      contents = await backupService.readForRestore(path);
    } catch (error) {
      log.warning('备份校验失败：$error', scope: 'backup');
      return '备份校验失败：$error';
    }

    // 回滚副本：逐域保存**原始字节**（settings/DB/AI 用户域/卡拉OK用户轨/
    // Reader 偏好），这样旧数据即使已经损坏也能原样回来。快照同时落在缓存目录，
    // 回滚本身失败时仍有可恢复副本。
    final recovery = await captureBackupRecovery(paths);
    final dbPath = paths.databasePath;
    final settingsFile = File(paths.settingsPath);
    final dbFile = File(dbPath);
    final readerFile = File(p.join(paths.configDir, 'reader_tts.json'));

    await _prepareForDataSwap();
    try {
      await _writeFileAtomic(settingsFile, contents.settingsBytes);
      // 旧库的 WAL/SHM 必须删掉：它们属于旧库，留着会让新库读到旧事务。
      for (final suffix in ['-wal', '-shm']) {
        final sidecar = File('$dbPath$suffix');
        if (await sidecar.exists()) await sidecar.delete();
      }
      await _writeFileAtomic(dbFile, contents.databaseBytes);
      if (contents.auxiliaryFiles[karaokeBackupUserDataFile]
          case final bytes?) {
        await importKaraokeUserFiles(paths, utf8.decode(bytes));
      }
      if (contents.auxiliaryFiles[aiBackupUserDataFile] case final bytes?) {
        await importAiUserFiles(paths, utf8.decode(bytes), replace: true);
      }
      if (contents.auxiliaryFiles[aiBackupReaderFile] case final bytes?) {
        await _writeFileAtomic(readerFile, bytes);
      }
    } catch (error) {
      log.error('写入恢复文件失败，尝试回滚：$error', scope: 'backup');
      // 逐域独立回滚：任一域失败（含读不了的旧用户轨）都不阻断其它域，
      // 尤其不能阻断 settings/DB 的恢复。
      final failures = await restoreBackupRecovery(paths, recovery);
      if (failures.isEmpty) {
        await recovery.delete();
      } else {
        log.error(
          '回滚未完成：${failures.join(',')}；原始副本保留在 ${recovery.path}',
          scope: 'backup',
        );
      }
      await bootstrap();
      _notifyIfAlive();
      return failures.isEmpty
          ? '写入恢复文件失败：$error'
          : '写入恢复文件失败：$error；回滚未完成：${failures.join(',')}'
                '（原始副本：${recovery.path}）';
    }
    await recovery.delete();

    await bootstrap();
    _notifyIfAlive();
    log.info(
      '备份恢复完成 ${describeBackupManifest(contents.manifest)}',
      scope: 'backup',
    );
    _afterDataSwap();
    return null;
  }

  /// 重置全部本地数据（设置 + 数据库），回到「未导入配置」状态。
  Future<String?> resetAllData() async {
    await _prepareForDataSwap();
    try {
      await importAiUserFiles(
        paths,
        '{"schemaVersion":1,"files":{}}',
        replace: true,
      );
      await importKaraokeUserFiles(paths, '{"schemaVersion":1,"files":{}}');
      final reader = File(p.join(paths.configDir, 'reader_tts.json'));
      if (await reader.exists()) await reader.delete();
      final dbPath = paths.databasePath;
      for (final path in [
        dbPath,
        '$dbPath-wal',
        '$dbPath-shm',
        paths.settingsPath,
      ]) {
        final file = File(path);
        if (await file.exists()) await file.delete();
      }
    } catch (error) {
      log.error('删除本地数据失败：$error', scope: 'backup');
      await bootstrap();
      _notifyIfAlive();
      return '删除本地数据失败：$error';
    }
    await bootstrap();
    _notifyIfAlive();
    log.info('本地数据已重置（设置与数据库已删除）', scope: 'backup');
    _afterDataSwap();
    return null;
  }

  /// 数据交换后重建依赖配置的附属状态（代理广告规则、直连站源注册）。
  void _afterDataSwap() {
    _applyAdRulesToProxy();
    if (_config != null) {
      _kickDirectRegistration();
    }
  }

  /// 数据交换前清空所有引用旧库/旧配置的内存状态。
  Future<void> _prepareForDataSwap() async {
    _cancelSearchWork();
    _tmdbSubscription.clear();
    _configMutationEpoch++;
    _followingTimer?.cancel();
    _followingKickTimer?.cancel();
    _followingService = null;
    _followingProgressService = null;
    _sessionAiAdRules = const [];
    _aiLoadRun++;
    _proxy.aiSessionFingerprint = null;
    _proxy.aiSessionRules = const AdRuleSet.empty();
    _aiSeasonBindings.clear();
    _aiSeasonSnapshots.clear();
    _aiIntegration = null;
    _clearRestoredConfigSourceWarning();
    _database?.dispose();
    _database = null;
    _configs = const [];
    _activeRecord = null;
    _config = null;
    _siteService = null;
    _selectedSite = null;
    _injectedSites = const [];
    _effectiveConfigCache = null;
    _configPhase = LoadPhase.idle;
    _contentPhase = LoadPhase.idle;
    _detailPhase = LoadPhase.idle;
    _lastError = null;
    _homeResult = null;
    _categoryResult = null;
    _detailResult = null;
    _detailError = null;
    _categoryFilters = const {};
    _resetCategoryPaging();
    _resetTmdbServices();
    _searchHistory = const [];
    _lastDecision = null;
    _router.setDirectSpiders(const {});
    // 换代必须让首屏等待者看到「没有进行中的注册」，否则会一直等到超时。
    _directReady = null;
    _directReadyConfig = null;
    _directHomeRetryConfig = null;
    _directHomeRetrySite = null;
    _cspHomeRetryConfig = null;
    _cspHomeRetrySite = null;
    _applyAdRulesToProxy();
    notifyListeners();
  }

  Future<void> _writeFileAtomic(File target, List<int> bytes) async {
    await target.parent.create(recursive: true);
    final temp = File('${target.path}.restore.tmp');
    await temp.writeAsBytes(bytes, flush: true);
    if (await target.exists()) await target.delete();
    await temp.rename(target.path);
  }

  /// 运行时架构取自 ABI；`Platform.version` 是 Dart 版本串，不含架构。
  String _abiArchitecture() => switch (Abi.current()) {
    Abi.linuxX64 ||
    Abi.macosX64 ||
    Abi.windowsX64 ||
    Abi.androidX64 ||
    Abi.iosX64 => 'x64',
    Abi.linuxArm64 ||
    Abi.macosArm64 ||
    Abi.windowsArm64 ||
    Abi.androidArm64 ||
    Abi.iosArm64 => 'arm64',
    Abi.linuxIA32 || Abi.windowsIA32 || Abi.androidIA32 => 'x86',
    Abi.linuxArm || Abi.androidArm => 'arm',
    Abi.linuxRiscv64 => 'riscv64',
    Abi.linuxRiscv32 => 'riscv32',
    _ => 'unknown',
  };

  String _windowsArchitecture() {
    final env = Platform.environment['PROCESSOR_ARCHITECTURE'];
    if (env == null || env.isEmpty) return 'x64';
    switch (env.toLowerCase()) {
      case 'amd64':
        return 'x64';
      case 'arm64':
        return 'arm64';
      case 'x86':
        return 'x86';
      default:
        return env.toLowerCase();
    }
  }

  /// TMDB 状态（`04` §2.2）。首次访问时构造；未配置时构造出的实例
  /// 会进入 `disabled` 阶段，不发起任何请求。
  TmdbState get tmdb => _tmdbState ??= TmdbState(
    config: () => tmdbConfig,
    service: _tmdbService,
    identityService: _ensureTmdbIdentityService(),
    seasonService: _ensureTmdbSeasonService(),
    enrichmentService: _ensureTmdbEnrichmentService(),
    isCurrentRun: () => _tmdbRunId == _detailRunId,
    onMatched: _rememberDetailIdentity,
  );

  /// 详情页匹配命中 → 把身份回写历史行（[rememberHistoryIdentity]）。
  ///
  /// 不写的话，这次匹配只活在 `tmdb_matches` 里：首页 hero 与历史页聚合读的是
  /// 历史行，会一直显示「没有 TMDB 身份」——用户 2026-11-22 反馈的正是这个。
  void _rememberDetailIdentity(String siteKey, String vodId, TmdbItem item) {
    if (siteKey.trim().isEmpty || vodId.trim().isEmpty) return;
    rememberHistoryIdentity(siteKey: siteKey, vodId: vodId, item: item);
  }

  /// 当前 TMDB 加载归属的详情运行号（`loadDetail` 每次自增）。
  int _tmdbRunId = 0;

  /// 与站源详情**并行**启动的那一轮 TMDB 加载（在 [loadDetail] 里创建）。
  ///
  /// 为什么留句柄而不是 `unawaited` 丢掉：站源详情回来后要先等它收尾，再用权威
  /// 线路补一次映射；丢掉句柄就只能重复发起请求或干脆不等。它的契约是不抛异常，
  /// 但状态层一旦抛异常会吃掉已经成功的站源详情，所以那里仍用 try/catch 兜底。
  Future<void>? _pendingTmdbLoad;

  /// 清除鉴权熔断（仅供测试：注入 401 后需要先清掉上一次的熔断窗口）。
  void clearAuthBlocksForTest() => _tmdbService.clearAuthBlocks();

  /// 用当前详情页上下文重新加载 TMDB 区块（手动匹配 / 重新匹配后调用）。
  Future<void> reloadTmdb() async {
    final vod = _selectedVod;
    final site = _selectedSite;
    if (vod == null ||
        (site == null && vod.vodId.isNotEmpty) ||
        _database == null) {
      return;
    }
    _tmdbRunId = _detailRunId;
    await _loadTmdbWithAi(
      vod,
      siteKey: site?.key ?? '',
      siteName: site?.name ?? '',
      configId: tmdbConfigId,
      lines: playLinesOf(vod),
      navSource: _navSourceFor(site, vod),
      knownIdentity: _knownIdentityWithoutPlayback(site, vod),
    );
  }

  /// 本次详情加载是否按「导航源」处理。
  ///
  /// 判据仍是 `site.indexs == 1`；推荐回退页的**合成条目**（`vodId` 为空）也走
  /// 这一条：它本来就没有站点索引条目，剧集卡片只能来自 TMDB 全季聚合。
  bool _navSourceFor(Site? site, Vod vod) =>
      site?.indexs == 1 || vod.vodId.isEmpty;

  TmdbIdentity? _knownIdentityWithoutPlayback(Site? site, Vod vod) {
    if (!_navSourceFor(site, vod) &&
        playLinesOf(vod).any((line) => line.episodes.isNotEmpty)) {
      return null;
    }
    final declared = TmdbIdentity.from(
      vod.extra['media_type'],
      vod.extra['tmdb_id'],
    );
    if (declared != null) return declared;
    // 真实条目的权威响应可能不回传身份字段；只复用仍绑定于该条目的已验证身份。
    return vod.vodId.isNotEmpty &&
            tmdb.belongsTo(
              vod.vodId,
              siteKey: site?.key ?? '',
              sourceTitle: vod.vodName,
            )
        ? tmdb.identity
        : null;
  }

  TmdbIdentityService _ensureTmdbIdentityService() =>
      _tmdbIdentityService ??= TmdbIdentityService(
        config: () => tmdbConfig,
        service: _tmdbService,
        store: DatabaseTmdbMatchStore(
          database: _database!,
          configId: tmdbConfigId,
        ),
      );

  TmdbSeasonService _ensureTmdbSeasonService() => _tmdbSeasonService ??=
      TmdbSeasonService(store: DatabaseTmdbSeasonStore(database: _database!));

  /// 追番真实播出时间服务（懒构造；测试可经 [attachFollowingAirTimeService] 替换）。
  FollowingAirTimeService? _followingAirTimeService;

  /// 测试口子：注入假服务，避免单测打真实 TMDB 网络。
  @visibleForTesting
  void attachFollowingAirTimeService(FollowingAirTimeService service) {
    _followingAirTimeService = service;
  }

  FollowingAirTimeService? _ensureFollowingAirTimeService() {
    if (_database == null) return null;
    return _followingAirTimeService ??= FollowingAirTimeService(
      isConfigured: () => tmdbConfig.isReady,
      resolveTmdbId: _resolveFollowingTmdbId,
      fetchEpisodes: (tmdbId, seasonNumber) => _tmdbService.seasonEpisodes(
        TmdbItem(tmdbId: tmdbId, mediaType: TmdbMediaType.tv, title: ''),
        seasonNumber,
      ),
    );
  }

  /// 仅解析追番的剧集身份，不切换站点或当前详情的 TMDB 状态。
  Future<TmdbItem?> followingTmdbItem(Following item) async {
    final id = await _resolveFollowingTmdbId(item);
    if (id == null || id <= 0) return null;
    return TmdbItem(
      tmdbId: id,
      mediaType: TmdbMediaType.tv,
      title: item.vodName,
      posterUrl: item.vodPic,
    );
  }

  /// 仅解析一条历史行的 TMDB 身份，不切换站点或当前详情的 TMDB 状态。
  ///
  /// 先读**已落盘的匹配结论**：详情页（`state/tmdb_state.dart`）早就匹配过的
  /// 作品在这里零请求，也不会再触发分季变体探测；只有从未匹配过才按片名走一次
  /// [TmdbIdentityService.match]。两种命中都回写历史行（[rememberHistoryIdentity]），
  /// 于是下一次读历史（首页取图、历史页聚合）直接就有身份，不必再匹配。
  ///
  /// 匹配不到返回 `null`，调用方保留站点海报，不编造元数据。
  Future<TmdbItem?> historyTmdbItem(
    PlaybackHistory row, {
    bool Function()? isCurrent,
  }) async {
    final database = _database;
    if (database == null || row.vodId.trim().isEmpty) return null;
    bool current() {
      if (_disposed || !(isCurrent?.call() ?? true)) return false;
      final latest = database.findHistory(
        siteKey: row.siteKey, vodId: row.vodId, sourceKey: row.sourceKey,
        flag: row.flag, episodeId: row.episodeId,
      );
      // UI尚未重建时generation可能没变，数据库中的新身份仍必须优先。
      return latest == null ||
          (latest.tmdbId == row.tmdbId && latest.mediaType == row.mediaType);
    }
    if (!current()) return null;
    final sourceKey = row.sourceKey.trim();
    final record = sourceKey.isEmpty || sourceKey == activeSourceKey
        ? activeRecord
        : database.configBySourceKey(sourceKey);
    final TmdbMatchStore store = record == null && sourceKey.isNotEmpty
        ? InMemoryTmdbMatchStore()
        : DatabaseTmdbMatchStore(database: database, configId: record?.id ?? tmdbConfigId);
    final scoped = configForSourceKey(sourceKey);
    final siteName = scoped?.sites.where((site) => site.key == row.siteKey).firstOrNull?.name ?? '';
    TmdbItem? item;
    try {
      item = store.find(siteKey: row.siteKey, vodId: row.vodId, sourceTitle: row.vodName)?.toItem();
    } catch (_) {
      // 读匹配表失败时仍可按标题解析。
    }
    if (item == null) {
      try {
        final outcome = await TmdbIdentityService(
          config: () => tmdbConfig, service: _tmdbService, store: store,
        ).match(
          TmdbMatchRequest(
            siteKey: row.siteKey, vodId: row.vodId, sourceTitle: row.vodName,
            siteName: siteName, vodName: row.vodName, vodYear: row.vodYear,
            expectedMediaType: TmdbMediaType.parse(row.mediaType),
          ),
          isCurrent: current,
        );
        item = outcome.item;
      } catch (_) {
        return null;
      }
    }
    if (item == null || !current()) return null;
    rememberHistoryIdentity(siteKey: row.siteKey, vodId: row.vodId, item: item, sourceKey: row.sourceKey);
    return item;
  }

  /// 追番 → TMDB 剧集 id：优先用已落盘的匹配结论（同步、零请求），
  /// 没命中再走身份服务的自动匹配；都失败返回 `null`。
  Future<int?> _resolveFollowingTmdbId(Following item) async {
    final database = _database;
    if (database == null) return null;
    final record = DatabaseTmdbMatchStore(
      database: database,
      configId: tmdbConfigId,
    ).find(siteKey: item.siteKey, vodId: item.vodId, sourceTitle: item.vodName);
    if (record != null) {
      return record.identity.isTv ? record.identity.tmdbId : null;
    }
    final outcome = await _ensureTmdbIdentityService().match(
      TmdbMatchRequest(
        siteKey: item.siteKey,
        vodId: item.vodId,
        sourceTitle: item.vodName,
        vodName: item.vodName,
        expectedMediaType: TmdbMediaType.tv,
      ),
    );
    final matched = outcome.item;
    if (matched == null || !matched.isTv) return null;
    return matched.tmdbId;
  }

  TmdbEnrichmentService _ensureTmdbEnrichmentService() =>
      _tmdbEnrichmentService ??= TmdbEnrichmentService(
        service: _tmdbService,
        config: () => tmdbConfig,
      );

  /// 切换配置后重建 TMDB 服务，使 `config_id` 隔离生效（`02` §14 Q2）。
  void _resetTmdbServices() {
    _tmdbIdentityService = null;
    _tmdbSeasonService = null;
    _tmdbEnrichmentService = null;
    _followingAirTimeService = null;
    _tmdbState?.clear();
    _tmdbState = null;
  }

  /// 保存 TMDB 设置（修改即生效；原子写，`03` §5.5）。
  Future<bool> saveTmdbConfig(TmdbConfig config) async {
    final safeConfig = config.userSettings;
    final saved = await _tmdbConfigStore.save(safeConfig);
    if (saved) {
      _tmdbConfigRevision++;
      log.info(
        'TMDB 设置已更新 enabled=${safeConfig.enabled} ready=${safeConfig.isReady} '
        'lang=${safeConfig.language} '
        'keyConfigured=${safeConfig.apiKey.isNotEmpty} '
        'tokenConfigured=${safeConfig.accessToken.isNotEmpty}',
        scope: 'tmdb',
      );
    } else {
      _lastError = AppError(AppErrorKind.storage, 'TMDB 设置保存失败');
    }
    _notifyIfAlive();
    return saved;
  }

  /// 测试连接（`04` §10.2）：调 `/configuration`，返回结构化结果。
  Future<String> testTmdbConnection() async {
    final config = tmdbConfig;
    if (!config.isReady) return '请先填写 API Key 或 Access Token';
    try {
      final detail = await _tmdbService.configuration();
      final images = detail['images'];
      final hasImages = images is Map && images.isNotEmpty;
      return '连接正常（配置字段 ${detail.length} 项'
          '${hasImages ? '，含图片主机配置' : ''}）';
    } on TmdbAuthException catch (error) {
      return '鉴权失败（HTTP ${error.statusCode}）：请检查 Key/Token';
    } on AppError catch (error) {
      return '连接失败：${error.userMessage}';
    } catch (error) {
      return '连接失败：$error';
    }
  }

  /// 测试当前图片线路（设置页「测试图片线路」）：取一张公共海报并报出耗时。
  ///
  /// 与 [testTmdbConnection] 互补：那个测 API（Key/Token 与 apiBase），这个测
  /// 海报与背景走的图片域名——换反代之后要确认的正是这一条。
  Future<String> testTmdbImageRoute() async {
    final config = tmdbConfig;
    final probe = await _tmdbService.probeImageRoute(config.imageBase);
    return tmdbImageProbeSummary(probe);
  }

  /// 手动匹配（`01` §7、`04` §5.1）。成功后刷新详情页 TMDB 区块。
  Future<TmdbMatchOutcome?> matchTmdbManual({
    required TmdbItem item,
    String? sourceTitle,
  }) async {
    final identityService = _ensureTmdbIdentityService();
    final vod = _selectedVod;
    final site = _selectedSite;
    // 合成条目没有站点 key，但仍需要能改 TMDB 身份（导航详情的手动匹配）。
    if (vod == null || (site == null && vod.vodId.isNotEmpty)) return null;
    final siteKey = site?.key ?? '';
    try {
      final outcome = await identityService.matchManual(
        request: TmdbMatchRequest(
          siteKey: siteKey,
          vodId: vod.vodId,
          sourceTitle: sourceTitle ?? vod.vodName,
        ),
        item: item,
      );
      await learnBusinessTitle(
        rawTitle: vod.vodName,
        confirmedTitle: item.title,
        siteKey: siteKey,
        vodId: vod.vodId,
        mediaType: item.mediaType.name,
      );
      // 重新加载详情页 TMDB 区块（手动结论必须立刻可见）。
      await reloadTmdb();
      return outcome;
    } catch (error) {
      log.warning('手动匹配失败：$error', scope: 'tmdb');
      return null;
    }
  }

  /// 手动季度绑定（`04` §5.2、`02` §8.4）。
  ///
  /// 返回是否真的写入了绑定（参数非法时为 `false`）。
  Future<bool> bindTmdbSeason(TmdbSeasonChoice choice) async {
    final seasonService = _tmdbSeasonService;
    final tmdb = _tmdbState;
    final site = _selectedSite;
    if (seasonService == null || tmdb == null || site == null) return false;
    final item = tmdb.item;
    final line = tmdb.sourceLine;
    final vod = tmdb.vod;
    if (item == null || line == null || vod == null) return false;

    final configId = tmdbConfigId;
    void clear() => seasonService.clearBinding(
      configId: configId,
      siteKey: site.key,
      vodId: vod.vodId,
      sourceTitle: vod.vodName,
      flagKey: line.flagKey,
    );

    if (choice is TmdbSeasonAuto) {
      clear();
      log.info('TMDB 季度绑定已清除（回到自动解析）', scope: 'tmdb');
      return true;
    }

    final decoded = bindingModeOf(choice);
    if (decoded == null) {
      clear();
      return true;
    }
    final mode = decoded.mode;
    final seasonNumber = decoded.seasonNumber;
    final binding = seasonService.bindSeason(
      configId: configId,
      siteKey: site.key,
      vodId: vod.vodId,
      sourceTitle: vod.vodName,
      flagKey: line.flagKey,
      sourceFlag: line.sourceFlag,
      tmdbId: item.tmdbId,
      mediaType: item.mediaType,
      mode: mode,
      seasonNumber: seasonNumber,
      line: line,
      seasonCounts: tmdb.seasonEpisodeCounts,
      tmdbSeasonEpisodeCount: seasonNumber == null
          ? 0
          : (tmdb.seasonEpisodeCounts[seasonNumber] ?? 0),
    );
    if (binding == null) {
      log.warning('TMDB 季度绑定参数非法，已忽略', scope: 'tmdb');
      return false;
    }
    log.info(
      'TMDB 季度绑定已写入 mode=${mode.name} season=$seasonNumber',
      scope: 'tmdb',
    );
    return true;
  }

  /// 用系统默认浏览器打开外部链接（相关视频，`04` §7.2）。
  ///
  /// 平台命令集中在 `ExternalUrl`：Windows `explorer.exe`、Linux `xdg-open`、
  /// macOS `/usr/bin/open`。不用 `url_launcher` 是为了避开 Windows 插件工程
  /// 与 CMake 变更（Windows 自带的 `explorer.exe <url>` 已处理默认浏览器）。
  /// 返回是否已交给操作系统，不保证页面已加载；失败时 UI 复制链接兜底。
  Future<bool> openExternalUrl(String url) async {
    final result = await ExternalUrl.open(url);
    if (!result.ok) {
      log.warning('打开外部链接失败：${result.error ?? '未知原因'}', scope: 'tmdb');
      return false;
    }
    return true;
  }

  /// TMDB 搜索（手动匹配弹窗用）。
  Future<List<TmdbItem>> searchTmdb(String keyword) async {
    final identityService = _tmdbIdentityService;
    if (identityService == null) return const [];
    try {
      return await identityService.searchCandidates(keyword);
    } catch (error) {
      log.warning('TMDB 搜索失败：$error', scope: 'tmdb');
      return const [];
    }
  }

  /// Provider ID 直达（`tmdb:12345` / `movie:12345` / `tv:12345`）。
  Future<TmdbItem?> resolveTmdbProviderId(String input) async {
    final identityService = _tmdbIdentityService;
    if (identityService == null) return null;
    try {
      return await identityService.resolveProviderId(input);
    } catch (_) {
      return null;
    }
  }

  /// 写入季度进度（`02` §6.2）。
  ///
  /// 来源 `history` 永远写（既有行为不变）；季度投影只在已确证季度时写。
  void recordSeasonProgress({
    required TmdbPlaybackIdentity identity,
    required SeasonScope scope,
    required String siteKey,
    required String vodId,
    required String sourceFlag,
    required String sourceEpisodeName,
    required String sourceEpisodeUrl,
    required int positionMs,
    required int durationMs,
    int segmentSeason = -1,
  }) {
    final seasonService = _tmdbSeasonService;
    final media = identity.identity;
    if (seasonService == null || media == null) return;
    // 隐身模式：季度进度是历史的投影，同样不写。
    if (incognito) return;
    try {
      seasonService.recordProgress(
        configId: tmdbConfigId,
        identity: media,
        scope: scope,
        episodeNumber: identity.episodeNumber,
        positionMs: positionMs,
        durationMs: durationMs,
        sourceFlag: sourceFlag,
        sourceEpisodeName: sourceEpisodeName,
        sourceEpisodeUrl: sourceEpisodeUrl,
        sourceHistoryKey: TmdbHistoryKey.of(
          siteKey: siteKey,
          vodId: vodId,
          flag: sourceFlag,
          episodeUrl: sourceEpisodeUrl,
        ),
        sourceBindingKey: identity.flagKey,
        segmentSeason: segmentSeason < 0 ? null : segmentSeason,
      );
    } catch (error) {
      // 进度写失败不影响播放（§15.2）
      log.warning('写入季度进度失败：$error', scope: 'tmdb');
    }
  }

  /// 读取季度进度（续播，`02` §6.3）。
  TmdbSeasonProgressRecord? findSeasonProgress({
    required TmdbIdentity media,
    required int seasonNumber,
  }) {
    final seasonService = _tmdbSeasonService;
    if (seasonService == null) return null;
    try {
      return seasonService.progressFor(
        configId: tmdbConfigId,
        identity: media,
        seasonNumber: seasonNumber,
      );
    } catch (_) {
      return null;
    }
  }

  /// 全部季度进度（历史投影，`02` §7.1）。
  List<TmdbSeasonProgressRecord> seasonProgressFor(TmdbIdentity media) {
    final seasonService = _tmdbSeasonService;
    if (seasonService == null) return const [];
    try {
      return seasonService.progressList(
        configId: tmdbConfigId,
        identity: media,
      );
    } catch (_) {
      return const [];
    }
  }

  /// 当前配置下的全部季度历史卡片（历史页展示，`02` §7.1）。
  List<SeasonHistoryCard> seasonHistoryCards() {
    final database = _database;
    if (database == null) return const [];
    try {
      final records = database
          .tmdbSeasonProgressAll(configId: tmdbConfigId)
          .map((row) => _seasonProgressFromRow(row))
          .toList();
      return projectSeasonHistory(records);
    } catch (error) {
      log.warning('读取季度历史失败：$error', scope: 'tmdb');
      return const [];
    }
  }

  static TmdbSeasonProgressRecord _seasonProgressFromRow(Row row) =>
      TmdbSeasonProgressRecord(
        configId: row['config_id'] as int? ?? 0,
        mediaType: row['media_type'] as String? ?? 'tv',
        tmdbId: row['tmdb_id'] as int? ?? 0,
        seasonNumber: row['season_number'] as int? ?? 0,
        episodeNumber: row['episode_number'] as int? ?? 0,
        positionMs: row['position_ms'] as int? ?? 0,
        durationMs: row['duration_ms'] as int? ?? 0,
        sourceFlag: row['source_flag'] as String? ?? '',
        sourceEpisodeName: row['source_episode_name'] as String? ?? '',
        sourceEpisodeUrl: row['source_episode_url'] as String? ?? '',
        sourceHistoryKey: row['source_history_key'] as String? ?? '',
        sourceBindingKey: row['source_binding_key'] as String? ?? '',
        updatedAt: row['updated_at'] as int? ?? 0,
      );

  /// 同季度换源候选（`02` §7.3）。
  List<RouteBinding> seasonRouteCandidates({
    required TmdbIdentity media,
    required int seasonNumber,
  }) {
    final seasonService = _tmdbSeasonService;
    if (seasonService == null) return const [];
    try {
      return seasonService.candidatesForSeason(
        configId: tmdbConfigId,
        identity: media,
        seasonNumber: seasonNumber,
      );
    } catch (_) {
      return const [];
    }
  }

  /// 删除某一季度历史（`02` §7.4 一级操作）。
  int deleteSeasonProgress({
    required TmdbIdentity media,
    required int seasonNumber,
  }) {
    final seasonService = _tmdbSeasonService;
    if (seasonService == null) return 0;
    final removed = seasonService.deleteSeasonHistory(
      configId: tmdbConfigId,
      identity: media,
      seasonNumber: seasonNumber,
    );
    notifyListeners();
    return removed;
  }

  /// 删除整部节目历史（`02` §7.4 **二级操作**）。
  int deleteMediaProgress(TmdbIdentity media) {
    final seasonService = _tmdbSeasonService;
    if (seasonService == null) return 0;
    final removed = seasonService.deleteMediaHistory(
      configId: tmdbConfigId,
      identity: media,
    );
    notifyListeners();
    return removed;
  }

  void _attachSiteService() {
    _cancelSearchWork();
    revokeProxySession();
    // 配置/注入变化后重新合并（缓存只在同一次装配内有效）。
    _effectiveConfigCache = null;
    // 配置可能带来新的 `doh`/`hosts`：先刷新出站传输（内部有输入签名，未变不重建）。
    _applyOutboundProxy();
    final config = effectiveConfig;
    if (config == null) {
      _kickDirectRegistration();
      _kickCspProvisioning(null);
      _siteService = null;
      _proxy.setAdRules(const AdRuleSet.empty());
      return;
    }
    // 广告规则随配置生效；总开关关闭时注入空集（行为等价于未配置）。
    _applyAdRulesToProxy();
    // 直连 js/py 站点：每次配置装配后异步注册（不阻塞首页；失败只记日志）。
    _kickDirectRegistration();
    // CatVod 壳站点（api=csp_PyProxy + ext.loader 指向 .py）在模块顶层就 import
    // requests/Crypto/lxml。用户诉求（2026-10-24）「如果需要迁移啥的不应该程序
    // 自己做嘛？」——让程序自己把带依赖的解释器准备好（本机已有就直接用，否则
    // 从离线 ZIP 准备专用环境），而不是让用户撞一句 code=3。同样不阻塞首屏。
    unawaited(_preparePythonRuntimeQuietly());
    // 加固壳发现保持只读；缺失的 CSP jar 则按配置实例在后台限量安装。
    unawaited(_probeShellTargetsQuietlyForStartup());
    // 不 await：实测 jar 下载/转译可能耗时数十秒，不能阻塞导入或首屏。
    _kickCspProvisioning(config);
    // 站点服务必须复用**同一个** [_router] 实例。
    //
    // 缺陷（2026-10-24 实测）：这里曾每次新建一个匿名 SpiderRouter 交给
    // SiteService，而 `setDirectSpiders`（直连/自动注册结果）与站点列表的
    // `classifySite` 都作用于字段 [_router]。于是同一次启动内出现
    // 「站点列表显示可用（本地 Spider），首页却报 PC Java Spider 未支持」——
    // 列表读 [_router]，业务调用读匿名 Router，后者的 directSpiders 永远为空。
    //
    // 换代（出站代理/DoH/换配置）通过 [SpiderRouter.updateTransport] 完成，
    // 它会清空 runtime 缓存，等价于过去「新建 Router」的效果。
    _router.updateTransport(client: _httpClient, globalHeaders: config.headers);
    _router.setCspConfig(config);
    _siteService = SiteService(
      appConfig: config,
      playbackBridge: _androidPlaybackBridge,
      router: _router,
      database: _database,
    );
    // 选中站点必须属于当前配置：`??=` 会在导入新配置时保留上一个配置的站点
    // （实测：导入猫源后仍选中旧配置的 `csp_PianDan`，首页直接 siteUnsupported，
    // 用户看到「一个站点都加载不出数据」）。因此按 key 校验归属，不属于当前配置
    // 的选中项一律作废，退回当前配置的默认站点。
    final selected = _selectedSite;
    if (selected != null && !_configContainsSite(config, selected)) {
      _selectedSite = null;
    }
    // 恢复**最近一次使用的站点**（用户需求 2026-10-10）：重启后默认回到它，
    // 而不是每次都被重置到配置里的第一个站点。
    //
    // 三重守卫，避免「恢复出一个不该用的站点」：
    // - 该 key 必须仍存在于**当前配置**（换了配置就作废，否则首页必然 siteUnsupported）；
    // - 只在尚未选中时生效（不抢已恢复的 `_selectedSite`）；
    // - 找不到就退回 `config.defaultSite()`（首次使用即此分支）。
    if (_selectedSite == null) {
      final remembered = _siteByKey(config, _uiPreferences?.lastSiteKey ?? '');
      // 被屏蔽的站点不当「下次选择的起点」：屏蔽的语义就是它不该再被选中。
      // 本次会话里屏蔽当前站点仍然照常使用（见 setSiteBlocked），那是另一条路径。
      if (remembered != null &&
          !isSiteBlocked(remembered.key) &&
          webHomeKeyOfSite(remembered) == null) {
        _selectedSite = remembered;
        log.info(
          '恢复上次使用的站点 site=${remembered.key.isEmpty ? remembered.name : remembered.key}',
          scope: 'site',
        );
      }
    }
    final defaultSite = config.defaultSite();
    _selectedSite ??=
        defaultSite != null &&
            !isSiteBlocked(defaultSite.key) &&
            webHomeKeyOfSite(defaultSite) == null
        ? defaultSite
        : config.sites
              .where(
                (site) =>
                    !site.hide &&
                    !isSiteBlocked(site.key) &&
                    webHomeKeyOfSite(site) == null,
              )
              .firstOrNull;
  }

  /// 按 key（或名称兜底）在当前配置里找站点；找不到返回 `null`。
  ///
  /// 播放器与详情页的「定向换源」需要它：外部线路只带站点 key，播放时把那
  /// 一个 [Site] 交给 [resolvePlayback] 的 `siteOverride`，**不**切换全局站源。
  Site? siteByKey(String key) {
    final config = effectiveConfig;
    return config == null ? null : _siteByKey(config, key);
  }

  /// 按 key（或名称兜底）在当前配置里找站点；找不到返回 `null`。
  static Site? _siteByKey(AppConfig config, String key) {
    final target = key.trim();
    if (target.isEmpty) return null;
    for (final candidate in config.sites) {
      if (candidate.hide) continue;
      if (candidate.key == target || candidate.name == target) return candidate;
    }
    return null;
  }

  /// 当前配置里是否存在同一个站点（按 key 比对；key 为空时按 name）。
  static bool _configContainsSite(AppConfig config, Site site) {
    for (final candidate in config.sites) {
      if (candidate.key.isNotEmpty && candidate.key == site.key) return true;
      if (candidate.key.isEmpty && candidate.name == site.name) return true;
    }
    return false;
  }

  /// 若保存的配置来源是猫源 bundle，则按原始地址重新拉起本机 Node 并取回新端口配置。
  ///
  /// 猫源站点 `api` 指向本机随机端口，重启后端口必变，因此**不能**直接复用旧 JSON
  /// 里的 api（会指向已经关掉的旧端口）。重拉失败时返回 null，调用方回退到旧 JSON，
  /// 由站点页如实报告不可用，而不是把整次启动拖垮。
  Future<AppConfig?> _reserveCatConfig(String origin) async {
    final pipeline = _catPipeline;
    if (pipeline == null || !CatSource.isBundle(origin)) return null;
    try {
      final resolved = await pipeline.resolve(origin);
      if (resolved == null) return null;
      final document = parseConfigDocument(resolved.configJson);
      return document.config;
    } catch (error) {
      log.warning('猫源重启失败，回退到已保存配置：$error', scope: 'cat');
      return null;
    }
  }

  void clearError() {
    _lastError = null;
    notifyListeners();
  }

  void clearNotice() {
    _notice = null;
    notifyListeners();
  }

  /// 注入一份详情状态，仅供 widget 测试使用（fake-async 区无法跑真实网络）。
  ///
  /// 详情页渲染归属的 UI 门禁需要「全局残留一份属于别的剧的结果」或「正在加载」
  /// 这类前提，而 `testWidgets` 的 fake-async 区推不动真实 HTTP（框架会把请求
  /// 固定返回 400），因此提供一个显式的测试注入点，而不是让生产代码为测试妥协。
  @visibleForTesting
  void seedDetailForTest({
    Vod? vod,
    LoadPhase phase = LoadPhase.ready,
    AppError? error,
  }) {
    _detailResult = vod == null ? null : SiteResult(list: [vod]);
    _detailRequestVodId = vod?.vodId ?? '';
    _selectedVod = vod;
    _detailPhase = phase;
    _detailError = error;
    notifyListeners();
  }

  /// 注入一份首页/分类结果，仅供 widget 测试使用（同 [seedDetailForTest]）。
  ///
  /// 海报网格的门禁需要「给定一批条目 → 断言卡片渲染了什么」这类前提，
  /// 而 fake-async 区拿不到真实站点数据，因此提供显式注入点。
  @visibleForTesting
  void seedListingForTest(List<Vod> list) {
    _homeResult = SiteResult(list: list);
    _selectedTypeId = null;
    _contentPhase = LoadPhase.ready;
    _lastError = null;
    notifyListeners();
  }

  /// 回到站点首页的“默认推荐”列表：清空当前分类筛选，显示首页结果。
  void selectDefaultListing() {
    _selectedTypeId = null;
    _categoryResult = null;
    _resetCategoryPaging();
    // 回首页意味着离开分类上下文，筛选条件随之作废（否则回到首页再选分类会带着旧筛选）。
    _categoryFilters = const {};
    notifyListeners();
  }

  /// 导入配置（URL / 文件路径 / JSON 文本）。
  ///
  /// 失败时**不覆盖**已有配置（§7.4.1、§7.5），并保留可定位错误。
  Future<bool> importConfig(String input, {String? displayName}) async {
    _configPhase = LoadPhase.loading;
    _lastError = null;
    _importDiagnosticsSummary = null;
    // 上一份配置的加固壳结论必须作废：提示/确认框都是按「这份配置的站点」算的，
    // 留着会让新配置弹出旧配置的框。
    _shellTargets = const [];
    _pendingShellUnpack.clear();
    notifyListeners();

    try {
      final mutationEpoch = ++_configMutationEpoch;
      // 这里**不再**做 Node 运行时门禁：缺 Node 只影响猫源 bundle，由
      // `ConfigImportService.import` 在猫源分支上单独报 configCatRuntimeMissing。
      final importService = _importService;
      final source = ConfigSource.parse(input);
      var imported = await importService.import(source);
      var repositoryIndex = 0;

      if (imported.isRepository) {
        // §7.4.2：默认第一项；切换条目时保留各条目独立配置记录。
        log.info(
          '导入配置仓库 entries=${imported.repositoryEntries.length} '
          'origin=${redactUrl(imported.origin)}',
        );
        imported = await importService.expandRepository(imported);
      }

      final config = imported.config;
      if (config == null) {
        throw AppError(
          AppErrorKind.configInvalid,
          '导入结果没有可用配置',
          detail: redactUrl(imported.origin),
        );
      }
      if (mutationEpoch != _configMutationEpoch) throw _staleConfigMutation();

      _clearRestoredConfigSourceWarning();
      _config = config;
      _importDiagnosticsSummary = imported.diagnostics.isEmpty
          ? null
          : imported.diagnostics.join('；');
      // 旧配置的详情请求必须作废：配置换了之后返回的详情属于另一个站点
      // （§7.4.1 导入即切换）。
      _detailRunId++;
      // 先落库、把生效记录切到新配置，再 attach 站点服务：`_attachSiteService`
      // 选当前站点时会按**记录 id** 取本配置的手动顺序/屏蔽集合（`siteListScopeKey`），
      // 记录还停在上一份时就会读到别人的屏蔽——表现为「刚导入的配置里，被屏蔽站点
      // 被选成当前站点」，而且本次会话不会自愈。
      final name = displayName ?? config.name ?? source.displayName;
      final importSourceKey = LocalSourceKey.of(imported.origin);
      final recordId = _database?.saveConfig(
        name: name,
        origin: imported.origin,
        json: config.toJson(),
        contentType: imported.contentType,
        repositoryIndex: repositoryIndex,
        repositoryEntries: imported.repositoryEntries,
        siteCount: config.sites.length,
        liveCount: config.lives.length,
        makeActive: true,
        // 本机源的身份必须在导入时就写进去：历史行一直按 `local|<origin>`
        // 记录来源，配置这边不带身份就永远查不到「这条记录属于哪份配置」，
        // 表现为来源标成「其他来源」、点进去还被告知原播放源已删除
        // （用户 2026-11 反馈）。
        sourceKey: importSourceKey,
      );
      if (recordId != null) {
        _database!.saveConfigSites(recordId, config.sites);
        _configs = _database!.listConfigs();
        _activeRecord = _database!.activeConfig();
        // 导入即切换（`makeActive: true`）也是「用户显式选了这个源」。不记的话，
        // 下次启动会按旧记忆把用户刚导入的配置又换掉。
        final active = _activeRecord;
        if (active != null) _rememberLastConfig(active);
      }
      _acceptImportedTmdbCredential(
        imported,
        recordId ?? _activeRecord?.id ?? 0,
        importSourceKey,
      );

      // 选中站点必须属于新配置（§7.4.1 导入即切换）：`_attachSiteService` 会按 key
      // 校验归属，不属于当前配置的选中项退回新配置的默认站点。
      //
      // 注意不能无条件置空：用户重新导入**同一份**配置（刷新）时应留在原站点；
      // 也不能继续用 `??=`：实测导入猫源后仍选中旧配置的 `csp_PianDan`，首页直接
      // siteUnsupported，用户看到一个站点都加载不出数据。
      final previousSiteKey = _selectedSite?.key;
      _attachSiteService();
      // 浏览结果绑定在选中站点上：站点换了就必须丢弃，否则拿旧站点列表渲染新配置。
      if (_selectedSite?.key != previousSiteKey) {
        _selectedTypeId = null;
        _homeResult = null;
        _categoryResult = null;
        _detailResult = null;
        _detailError = null;
        _activeSearch = null;
        // 筛选维度是**站点相关**的（不同站点的 key/取值完全不同），换站点必须
        // 一并作废：留着旧站点的筛选会让新站点的第一个分类请求带着无效的 ext。
        _categoryFilters = const {};
        _resetCategoryPaging();
      }

      // 摘要必须同时报「多少个站点」和「多少个真能用」：只报总数会让用户
      // 以为导入即可用，实际整份配置可能没有一个站点能跑。
      final usableSites = usableSiteCount;
      _notice =
          config.notice ??
          '配置导入成功：${config.sites.length} 个站点（可用 $usableSites 个）';
      _configPhase = LoadPhase.ready;
      log.info(
        '配置导入成功 name=$name sites=${config.sites.length} '
        'usable=$usableSites '
        'lives=${config.lives.length} headers=${config.headers.length} '
        'origin=${redactUrl(imported.origin)}',
        scope: 'config',
      );
      if (_importDiagnosticsSummary != null) {
        log.warning('导入诊断：$_importDiagnosticsSummary', scope: 'config');
      }
      _notifyIfAlive();

      // 加固壳：导入成功后异步探测，命中只**暂存**一条待确认提示——不弹 UI、
      // 不下载运行时；弹不弹、什么时候弹由 UI 决定。
      // 句柄留给 UI：导入页要在「导入成功」这一刻弹提示，必须能等到探测 settle。
      _shellTargetsProbe = _probeShellTargetsQuietly(config);
      unawaited(_shellTargetsProbe!);
      _kickCspProvisioning(effectiveConfig ?? config);

      // 导入后自动加载默认站点首页，形成“导入 → 首页”的闭环。
      final site = _selectedSite;
      if (site != null) {
        await loadHome(site);
      }
      return true;
    } catch (error) {
      final failure = error is AppError
          ? error
          : AppError(AppErrorKind.unknown, '$error', cause: error);
      _lastError = failure;
      _configPhase = hasConfig ? LoadPhase.ready : LoadPhase.failed;
      log.error('配置导入失败：${failure.logLine}', scope: 'config');
      _notifyIfAlive();
      return false;
    }
  }

  /// 切换到已保存的配置（§7.5 多配置切换）。
  Future<bool> activateConfigRecord(int id) async {
    final database = _database;
    if (database == null) {
      _lastError = AppError(AppErrorKind.storage, '本地存储不可用，无法切换配置');
      notifyListeners();
      return false;
    }
    try {
      final mutationEpoch = ++_configMutationEpoch;
      database.activateConfig(id);
      _configs = database.listConfigs();
      _activeRecord = database.activeConfig();
      final record = _activeRecord;
      if (record == null || record.json.isEmpty) {
        throw AppError(AppErrorKind.configInvalid, '该配置记录没有可恢复内容');
      }
      // 换源时先终止上一个猫源进程树，再按新记录的原始地址重拉（§9）。
      await _catPipeline?.stop();
      _selectedSite = null;
      final reserved = await _reserveCatConfig(record.origin);
      if (mutationEpoch != _configMutationEpoch) throw _staleConfigMutation();
      _clearRestoredConfigSourceWarning();
      _config = reserved ?? parseConfigRecord(record.json);
      _attachSiteService();
      _detailRunId++;
      _homeResult = null;
      _categoryResult = null;
      _detailResult = null;
      _detailError = null;
      _categoryFilters = const {};
      _resetCategoryPaging();
      _configPhase = LoadPhase.ready;
      _beginCurrentTmdbCredentialScope();
      // 切换配置 → 重建 TMDB 服务，使 `config_id` 隔离生效（`02` §14 Q2）。
      _resetTmdbServices();
      // 用户显式切换成功 = 「这次用的就是它」：只有这里（以及导入成功路径，
      // 它最终也会走激活）才更新记忆，自动接入之类的后台动作不写，否则一次
      // 探测失败就会把用户的真实选择覆盖成别的源。
      _rememberLastConfig(record);
      log.info('切换配置：${record.name} cat=${reserved != null}', scope: 'config');
      notifyListeners();
      final site = _selectedSite;
      if (site != null) await loadHome(site);
      return true;
    } catch (error) {
      final failure = error is AppError
          ? error
          : AppError(AppErrorKind.unknown, '$error', cause: error);
      _lastError = failure;
      log.error('切换配置失败：${failure.logLine}', scope: 'config');
      _notifyIfAlive();
      return false;
    }
  }

  /// 配置管理页要展示的记录列表。
  ///
  /// 与 [configs] 的差别只在**数据来源**：`_configs` 是内存快照，桥接导入、
  /// 安卓恢复等路径直接写库时它不会跟着变。配置页是「用户来核对库里到底有
  /// 哪几条」的地方，必须读库；sqlite 是同步接口，一页几十行不构成负担。
  List<ConfigRecord> get savedConfigs => _database?.listConfigs() ?? _configs;

  /// 在已保存的配置记录里按 id 找一条。
  ///
  /// 内存列表可能落后于库（桥接导入、其它页面直接写库都会绕过它），所以
  /// 查不到时回读一次数据库：编辑/刷新这类「按 id 精确操作」的入口绝不能
  /// 因为一个陈旧的缓存就报「记录已不存在」。
  ConfigRecord? configRecordById(int id) {
    for (final item in _configs) {
      if (item.id == id) return item;
    }
    for (final item in _database?.listConfigs() ?? const <ConfigRecord>[]) {
      if (item.id == id) return item;
    }
    return null;
  }

  /// 编辑一条配置的名称/地址。
  ///
  /// 本地源**改了地址时必须先按新地址完整拉取一遍**再落库：地址写错时用户
  /// 期望的是"改失败、原来那条还在"，而不是库里出现一条拉不下来的坏记录。
  /// 拉取成功后直接用新内容覆盖这一条 —— 改地址本身就等于一次刷新，
  /// 再让用户额外点一次刷新是没有意义的动作。
  ///
  /// 桥接源的地址由安卓设备决定（网关地址），只允许改名。
  Future<bool> editConfigRecord(
    int id, {
    required String name,
    required String origin,
  }) async {
    final database = _database;
    if (database == null) {
      _lastError = AppError(AppErrorKind.storage, '本地存储不可用，无法编辑配置');
      notifyListeners();
      return false;
    }
    final record =
        configRecordById(id) ??
        (_activeRecord?.id == id ? _activeRecord : null);
    if (record == null) {
      _lastError = AppError(AppErrorKind.storage, '该配置记录已不存在');
      notifyListeners();
      return false;
    }
    final trimmedName = name.trim();
    final trimmedOrigin = origin.trim();
    _lastError = null;

    final isBridge = record.bridgeInterfaceKey.trim().isNotEmpty;
    if (isBridge) {
      if (trimmedName.isEmpty) {
        _lastError = AppError(AppErrorKind.storage, '配置名称不能为空');
        notifyListeners();
        return false;
      }
      database.updateConfigIdentity(id, name: trimmedName);
      _configs = database.listConfigs();
      if (_activeRecord?.id == id) _activeRecord = database.activeConfig();
      notifyListeners();
      return true;
    }

    if (trimmedOrigin.isEmpty) {
      _lastError = AppError(AppErrorKind.configInvalid, '配置地址不能为空');
      notifyListeners();
      return false;
    }
    // 名称留空时保留原名：改地址不该顺手把用户起的名也抹掉。
    final nextName = trimmedName.isEmpty ? record.name : trimmedName;
    final mutationEpoch = ++_configMutationEpoch;
    if (trimmedOrigin == record.origin.trim()) {
      database.updateConfigIdentity(id, name: nextName);
      _configs = database.listConfigs();
      if (_activeRecord?.id == id) _activeRecord = database.activeConfig();
      notifyListeners();
      return true;
    }

    // 地址变了：先验证，验证通过才动库。
    final imported = await _fetchConfigForRefresh(trimmedOrigin);
    if (imported == null) return false;
    if (mutationEpoch != _configMutationEpoch) {
      _lastError = _staleConfigMutation();
      _notifyIfAlive();
      return false;
    }
    final config = imported.config;
    if (config == null) {
      _lastError = AppError(
        AppErrorKind.configInvalid,
        '新地址没有可用配置',
        detail: redactUrl(trimmedOrigin),
      );
      _notifyIfAlive();
      return false;
    }
    final sourceKey = LocalSourceKey.of(imported.origin);
    database.updateConfigIdentity(
      id,
      name: nextName,
      origin: imported.origin,
      sourceKey: sourceKey,
    );
    database.refreshConfigContent(
      id,
      json: config.toJson(),
      siteCount: config.sites.length,
      liveCount: config.lives.length,
      contentType: imported.contentType,
      origin: imported.origin,
      sourceKey: sourceKey,
      etag: imported.etag,
      lastModified: imported.lastModified,
    );
    database.saveConfigSites(id, config.sites);
    _configs = database.listConfigs();
    _activeRecord = database.activeConfig();
    if (_activeRecord?.id == id) {
      _rememberLastConfig(_activeRecord!);
      _acceptImportedTmdbCredential(imported, id, sourceKey);
      await _reloadActiveConfigContent(config);
    }
    _notifyIfAlive();
    return true;
  }

  /// 重新拉取一条配置的内容（不落库）。失败时把错误写进 [lastError] 并返回 null。
  Future<ImportedConfig?> _fetchConfigForRefresh(String input) async {
    try {
      final source = ConfigSource.parse(input);
      var imported = await _importService.import(source);
      if (imported.isRepository) {
        // 与导入路径一致：仓库默认用第一项（§7.4.2）。
        imported = await _importService.expandRepository(imported);
      }
      return imported;
    } catch (error) {
      _lastError = error is AppError
          ? error
          : AppError(AppErrorKind.unknown, '$error', cause: error);
      log.warning('刷新配置失败：${_lastError!.logLine}', scope: 'config');
      _notifyIfAlive();
      return null;
    }
  }

  /// 刷新一条已保存配置的内容，**原地更新同一条记录**（id 不变）。
  ///
  /// 为什么必须原地更新：刷新是"让这条记录追上它的来源"，不是"再导入一份"。
  /// 走导入路径会按 origin/sourceKey 去重并在地址变更时新插一条，用户每点一次
  /// 刷新列表就长一条重复配置。
  Future<bool> refreshConfigRecord(int id) async {
    final database = _database;
    if (database == null) {
      _lastError = AppError(AppErrorKind.storage, '本地存储不可用，无法刷新配置');
      notifyListeners();
      return false;
    }
    final record = configRecordById(id);
    if (record == null) {
      _lastError = AppError(AppErrorKind.storage, '该配置记录已不存在');
      notifyListeners();
      return false;
    }
    _lastError = null;
    final mutationEpoch = ++_configMutationEpoch;

    final interfaceKey = record.bridgeInterfaceKey.trim();
    if (interfaceKey.isNotEmpty || record.contentType == 'android-t4-gateway') {
      // 桥接源的内容在安卓设备上：先找设备地址，再按 interfaceKey 精确重拉。
      // 不探测整台设备的全部源，否则刷新一条会顺带改写别的源。
      final deviceUuid = record.bridgeDevice.trim();
      final address = deviceUuid.isEmpty
          ? record.origin
          : deviceAddressForUuid(deviceUuid);
      if (address.isEmpty) {
        _lastError = AppError(
          AppErrorKind.bridgeUnreachable,
          '找不到该源所属设备的接入地址，请先在「安卓设备接入」里连一次',
          detail: redactUrl(record.origin),
        );
        notifyListeners();
        return false;
      }
      final ok = await syncState.importSites(
        address,
        interfaceKey: interfaceKey.isEmpty ? null : interfaceKey,
        isCurrent: () => mutationEpoch == _configMutationEpoch,
        onSaved: _acceptCurrentBridgeTmdbCredential,
      );
      if (mutationEpoch != _configMutationEpoch) return false;
      if (!ok) {
        // 失败时数据库里那条记录仍然完好（importSites 只在成功时才 upsert）。
        _lastError =
            syncState.lastError ??
            AppError(
              AppErrorKind.bridgeUnreachable,
              '该播放源刷新失败',
              detail: redactUrl(address),
            );
        _notifyIfAlive();
        return false;
      }
      _configs = database.listConfigs();
      _activeRecord = database.activeConfig();
      if (_activeRecord?.id == id) {
        final refreshed = configRecordById(id);
        final json = refreshed?.json ?? const <String, Object?>{};
        if (json.isNotEmpty) {
          await _reloadActiveConfigContent(parseConfigRecord(json));
        }
      }
      _notifyIfAlive();
      return true;
    }

    final imported = await _fetchConfigForRefresh(record.origin);
    if (imported == null) return false;
    if (mutationEpoch != _configMutationEpoch) {
      _lastError = _staleConfigMutation();
      _notifyIfAlive();
      return false;
    }
    final config = imported.config;
    if (config == null) {
      _lastError = AppError(
        AppErrorKind.configInvalid,
        '来源没有可用配置',
        detail: redactUrl(record.origin),
      );
      _notifyIfAlive();
      return false;
    }
    database.refreshConfigContent(
      id,
      json: config.toJson(),
      siteCount: config.sites.length,
      liveCount: config.lives.length,
      contentType: imported.contentType,
      origin: imported.origin,
      sourceKey: LocalSourceKey.of(imported.origin),
      etag: imported.etag,
      lastModified: imported.lastModified,
    );
    database.saveConfigSites(id, config.sites);
    _configs = database.listConfigs();
    _activeRecord = database.activeConfig();
    if (_activeRecord?.id == id) {
      final active = _activeRecord!;
      _acceptImportedTmdbCredential(
        imported,
        active.id,
        sourceKeyOfRecord(active),
      );
      await _reloadActiveConfigContent(config);
    }
    _notifyIfAlive();
    return true;
  }

  /// 刷新全部配置；返回失败条目（空表示全部成功）。
  ///
  /// 串行而不是并发：这些来源可能指向同一台安卓设备或同一个订阅站，
  /// 并发只会让设备侧排队超时，还会把失败原因搅成一团。
  Future<List<String>> refreshAllConfigs() async {
    // 以数据库为准而不是内存列表：桥接导入等路径会直接写库，
    // 用陈旧的 `_configs` 会让「全部刷新」漏掉刚导入的那几条。
    final targets = _database?.listConfigs() ?? [..._configs];
    final failures = <String>[];
    for (final record in targets) {
      final ok = await refreshConfigRecord(record.id);
      if (!ok) {
        failures.add('${record.name}（${_lastError?.message ?? '刷新失败'}）');
      }
    }
    return failures;
  }

  /// 启动后自动刷新各条配置（§7.5 多配置）：增量、串行、静默。
  ///
  /// 触发点是应用壳层首帧之后（ui/app.dart），与启动恢复并行、但**不抢先**：
  /// 启动要的是本地缓存立刻可用，网络更新什么时候回来都不影响首屏。
  ///
  /// 为什么串行：这些来源可能指向同一台设备或同一个订阅站，并发会把失败原因
  /// 搅成一团（与 [refreshAllConfigs] 同一条理由）。
  ///
  /// 同一进程内只跑一轮：重复调用返回同一个 Future，壳层重建不会再打一轮网络。
  Future<void> startupConfigRefresh() {
    final pending = _startupConfigRefresh;
    if (pending != null) return pending;
    final future = refreshConfigsInBackground();
    _startupConfigRefresh = future;
    return future;
  }

  /// 后台刷新一轮的落定信号（测试与退出路径用）。
  Future<void> get startupConfigRefreshDone =>
      _startupConfigRefresh ?? Future<void>.value();

  // --- 应用更新（ADR-0015）-----------------------------------------------

  /// 本机这份构建的身份：版本名 + CI 注入的发布 tag。
  AppUpdateIdentity get appUpdateIdentity =>
      AppUpdateIdentity(version: appVersion, tag: appBuildTag);

  /// 更新偏好：自动检查开关、通道、上次检查时间与失败原因。
  AppUpdatePreferences get updatePreferences => _updatePreferences;

  /// 最近一次检查结果（null = 本进程还没查过）。
  AppUpdateCheck? get updateCheck => _updateCheck;

  /// 是否有检查在飞（按钮禁用与状态回显用）。
  bool get updateChecking => _updateChecking;

  /// 已下载并通过校验的更新包。
  AppUpdateDownload? get updateDownload => _updateDownload;

  bool get updateDownloading => _updateDownloading;

  int get updateDownloadReceived => _updateDownloadReceived;

  int? get updateDownloadTotal => _updateDownloadTotal;

  /// 下载进度 [0,1]；总大小未知时为 null。
  double? get updateDownloadProgress {
    final total = _updateDownloadTotal;
    if (total == null || total <= 0) return null;
    return (_updateDownloadReceived / total).clamp(0.0, 1.0);
  }

  /// 下载失败原因（页面直接显示）。
  String? get updateDownloadError => _updateDownloadError;

  /// 安装结果（成功与失败都由页面回显）。
  AppUpdateInstallResult? get updateInstallResult => _updateInstallResult;

  bool get updateInstalling => _updateInstalling;

  /// 后台检查发现新版本时的一次性提示（tag）；壳层投影成 toast 后清空。
  String? get updateNotice => _updateNotice;

  /// 发布页：优先用这条发布自己的页面，否则仓库 Releases 列表。
  Uri get updateReleasePage =>
      _updateCheck?.release?.pageUri ?? appUpdateReleasePageUri;

  void clearUpdateNotice() {
    if (_updateNotice == null) return;
    _updateNotice = null;
    _notifyIfAlive();
  }

  /// 打开/关闭「启动时自动检查」（每 24 小时最多一次）。
  ///
  /// 打开时立刻查一次：用户拨开关的动作本身就是「现在给我看看」。
  Future<void> setUpdateAutoCheck(bool enabled) async {
    if (_updatePreferences.autoCheck == enabled) return;
    await _saveUpdatePreferences(
      _updatePreferences.copyWith(autoCheck: enabled),
    );
    if (enabled) unawaited(checkForUpdates());
  }

  Future<bool> setUpdateGithubProxy(AppUpdateProxySettings settings) async {
    if (_updateChecking || _updateDownloading || _updateInstalling) {
      return false;
    }
    final baseUrl = AppUpdateProxySettings.normalizeBaseUrl(settings.baseUrl);
    if (baseUrl == null) return false;
    final normalized = AppUpdateProxySettings(
      enabled: settings.enabled,
      baseUrl: baseUrl,
    );
    if (normalized == _updatePreferences.githubProxy) return true;
    final store = _updatePreferencesStore;
    if (store == null) return false;
    final saved = await store.persist(
      _updatePreferences.copyWith(githubProxy: normalized),
    );
    if (!saved) return false;
    _updatePreferences = _updatePreferences.copyWith(githubProxy: normalized);
    _notifyIfAlive();
    return true;
  }

  /// 切换更新通道；切完清掉上一次结果，免得把别的通道的版本当成「可更新」。
  Future<void> setUpdateChannel(AppUpdateChannel channel) async {
    if (_updateChecking || _updateDownloading || _updateInstalling) return;
    if (_updatePreferences.channel == channel) return;
    await _saveUpdatePreferences(
      _updatePreferences.copyWith(
        channel: channel,
        lastCheckedAt: null,
        lastCheckError: null,
      ),
    );
    _updateCheck = null;
    _updateDownload = null;
    _updateDownloadError = null;
    _updateInstallResult = null;
    _updateNotice = null;
    _notifyIfAlive();
  }

  /// 查一次更新。同一时刻只允许一个请求在飞（重复点击返回同一个 Future）。
  ///
  /// **永不抛异常**：失败落成 [AppUpdateVerdict.failed] 的结果。
  Future<AppUpdateCheck> checkForUpdates() {
    final pending = _updateCheckFuture;
    if (pending != null) return pending;
    if ((_updateDownloading || _updateInstalling) && _updateCheck != null) {
      return Future.value(_updateCheck);
    }
    final future = _runUpdateCheck();
    _updateCheckFuture = future;
    return future;
  }

  Future<AppUpdateCheck> _runUpdateCheck() async {
    final identity = appUpdateIdentity;
    final channel = _updatePreferences.channel;
    _updateChecking = true;
    _notifyIfAlive();
    AppUpdateCheck check;
    try {
      check = await _updates.check(identity: identity, channel: channel);
    } on Object catch (error) {
      final message = error.toString();
      check = AppUpdateCheck(
        verdict: AppUpdateVerdict.failed,
        identity: identity,
        checkedAt: DateTime.now(),
        message: '检查更新失败：$message',
      );
    } finally {
      _updateChecking = false;
      _updateCheckFuture = null;
    }
    if (_disposed) return check;
    if (channel != _updatePreferences.channel) {
      _notifyIfAlive();
      return check;
    }
    final downloaded = _updateDownload;
    final asset = check.release?.preferredAsset(
      operatingSystem: Platform.operatingSystem,
      runningAsAppImage: (Platform.environment['APPIMAGE'] ?? '').isNotEmpty,
    );
    if (check.failed ||
        downloaded?.release.tag != check.release?.tag ||
        (downloaded != null &&
            (downloaded.asset.name != asset?.name ||
                downloaded.asset.downloadUri != asset?.downloadUri ||
                downloaded.asset.sha256 != asset?.sha256 ||
                downloaded.asset.size != asset?.size))) {
      _updateDownload = null;
      _updateDownloadError = null;
      _updateInstallResult = null;
    }
    _updateCheck = check;
    _updateNotice = check.hasUpdate ? check.release?.tag : null;
    final failure = check.message;
    await _saveUpdatePreferences(
      _updatePreferences.copyWith(
        lastCheckedAt: check.checkedAt,
        lastCheckError: check.failed ? failure : null,
      ),
    );
    final tag = check.release?.tag ?? '-';
    final channelName = channel.name;
    final verdictName = check.verdict.name;
    log.info('检查更新：通道=$channelName 结论=$verdictName 最新=$tag', scope: 'update');
    _notifyIfAlive();
    return check;
  }

  /// 启动路径：壳层首帧之后调一次。间隔不到 24 小时就一个请求都不发。
  Future<void> maybeAutoCheckForUpdates() async {
    if (_disposed || _updateChecking) return;
    if (!_updatePreferences.shouldAutoCheck(DateTime.now())) return;
    await checkForUpdates();
  }

  /// 下载并校验当前可用的安装包；失败返回 null，原因进 [updateDownloadError]。
  Future<AppUpdateDownload?> downloadUpdate() async {
    if (_updateDownloading) return _updateDownload;
    final check = _updateCheck;
    final release = check?.release;
    if (_updateChecking ||
        _updateInstalling ||
        release == null ||
        !(check!.hasUpdate ||
            check.verdict == AppUpdateVerdict.developmentBuild)) {
      _updateDownloadError = '还没有可安装的版本，请先检查更新';
      _notifyIfAlive();
      return null;
    }
    final appImagePath = Platform.environment['APPIMAGE'];
    final asset = release.preferredAsset(
      operatingSystem: Platform.operatingSystem,
      runningAsAppImage: (appImagePath ?? '').isNotEmpty,
    );
    if (asset == null) {
      _updateDownloadError = '这次发布没有适合当前平台和发行形态的安装包';
      _notifyIfAlive();
      return null;
    }
    _updateDownloading = true;
    _updateDownloadError = null;
    _updateInstallResult = null;
    _updateDownloadReceived = 0;
    _updateDownloadTotal = asset.size > 0 ? asset.size : null;
    _updateProgressNotifiedBytes = -1;
    _notifyIfAlive();
    final destination = Directory(
      p.join(paths.cacheDir, 'updates', _updateToken(release.tag)),
    );
    try {
      final download = await _updates.download(
        release,
        asset,
        destination: destination,
        onProgress: (received, total) {
          _updateDownloadReceived = received;
          _updateDownloadTotal = total ?? _updateDownloadTotal;
          final notified = _updateProgressNotifiedBytes;
          final enough =
              notified < 0 ||
              received - notified >= _updateProgressStepBytes ||
              (total != null && received >= total);
          if (enough) {
            _updateProgressNotifiedBytes = received;
            _notifyIfAlive();
          }
        },
      );
      _updateDownload = download;
      _updateDownloadReceived = download.size;
      _updateDownloadTotal = download.size;
      final path = download.file.path;
      log.info('更新包已下载并校验：$path', scope: 'update');
      return download;
    } on AppUpdateException catch (error) {
      final message = error.message;
      _updateDownloadError = message;
      log.warning('下载更新包失败：$message', scope: 'update');
      return null;
    } on Object catch (error) {
      final message = error.toString();
      _updateDownloadError = '下载更新包失败：$message';
      log.warning('下载更新包失败：$message', scope: 'update');
      return null;
    } finally {
      _updateDownloading = false;
      _notifyIfAlive();
    }
  }

  /// 安装已下载的更新包（AppImage 原地替换 / Windows 换装脚本 / 仅下载）。
  Future<AppUpdateInstallResult?> applyDownloadedUpdate() async {
    final download = _updateDownload;
    final check = _updateCheck;
    if (download == null ||
        _updateChecking ||
        check == null ||
        !(check.hasUpdate ||
            check.verdict == AppUpdateVerdict.developmentBuild) ||
        download.release.tag != check.release?.tag) {
      return null;
    }
    if (_updateInstalling) return _updateInstallResult;
    _updateInstalling = true;
    _notifyIfAlive();
    try {
      final result = await _updates.install(
        download,
        environment: _updateInstallEnvironment(),
      );
      _updateInstallResult = result;
      final outcome = result.outcome.name;
      final message = result.message;
      if (message == null || message.isEmpty) {
        log.info('更新安装：$outcome', scope: 'update');
      } else {
        log.info('更新安装：$outcome · $message', scope: 'update');
      }
      return result;
    } finally {
      _updateInstalling = false;
      _notifyIfAlive();
    }
  }

  /// 一次点击完成「下载 → 校验 → 安装」。
  Future<AppUpdateInstallResult?> downloadAndInstallUpdate() async {
    final download = _updateDownload ?? await downloadUpdate();
    if (download == null) return null;
    return applyDownloadedUpdate();
  }

  AppUpdateService get _updates {
    final injected = _injectedUpdateService;
    if (injected != null) return injected;
    return _updateService ??= AppUpdateService(
      client: createOutboundHttpClient(outboundProxy, doh: _dohResolver),
      cacheDirectory: Directory(p.join(paths.cacheDir, 'updates', 'metadata')),
      proxySettings: () => updatePreferences.githubProxy,
      ownsClient: true,
    );
  }

  /// 出站传输重建后调用：下一次检查按新设置重新构造客户端。
  void _resetUpdateService() {
    if (_injectedUpdateService != null) return;
    _updateService?.close();
    _updateService = null;
  }

  AppUpdateInstallEnvironment _updateInstallEnvironment() =>
      AppUpdateInstallEnvironment(
        operatingSystem: Platform.operatingSystem,
        executablePath: Platform.resolvedExecutable,
        updatesRoot: p.join(paths.cacheDir, 'updates'),
        processId: pid,
        appImagePath: Platform.environment['APPIMAGE'],
      );

  Future<void> _saveUpdatePreferences(AppUpdatePreferences next) async {
    if (next == _updatePreferences) return;
    _updatePreferences = next;
    _notifyIfAlive();
    await _updatePreferencesStore?.persist(next);
  }

  String _updateToken(String value) {
    final token = value.replaceAll(RegExp(r'[^0-9A-Za-z._-]'), '_');
    return token.isEmpty ? 'update' : token;
  }

  /// 跑一轮后台增量刷新（不带 one-shot 闸门）。
  ///
  /// 启动路径经 [startupConfigRefresh] 调一次；单测可以直接跑多轮来锁住
  /// 「第二轮不该再写库」这类增量性质。
  Future<void> refreshConfigsInBackground() async {
    try {
      final database = _database;
      if (database == null || _disposed) return;
      final targets = [
        for (final record in database.listConfigs())
          if (_isStartupRefreshTarget(record)) record,
      ];
      if (targets.isEmpty) return;
      final stopwatch = Stopwatch()..start();
      var changed = 0;
      var unchanged = 0;
      var failed = 0;
      var skipped = 0;
      for (final record in targets) {
        if (_disposed) return;
        switch (await _refreshConfigInBackground(record)) {
          case _ConfigRefreshOutcome.changed:
            changed++;
          case _ConfigRefreshOutcome.unchanged:
            unchanged++;
          case _ConfigRefreshOutcome.failed:
            failed++;
          case _ConfigRefreshOutcome.skipped:
            skipped++;
        }
      }
      // 检查时间/失败原因都落在库里，界面要能看见：统一刷新一次列表再通知。
      if (_disposed) return;
      _configs = database.listConfigs();
      _activeRecord = database.activeConfig();
      _notifyIfAlive();
      log.info(
        '启动配置刷新：$changed 条有更新，$unchanged 条未变，$failed 条失败，'
        '$skipped 条作废（${stopwatch.elapsedMilliseconds} ms）',
        scope: 'config',
      );
    } catch (error) {
      // 后台刷新绝不能把启动路径或调用方拖挂：这里兜最后一次底。
      log.warning('启动配置刷新中断：$error', scope: 'config');
    }
  }

  /// 这条记录该不该进「启动自动刷新」。
  ///
  /// 三类排除，各有硬理由：
  /// - 猫源 bundle：内容由本机 Node 运行时现场生成，重拉会先停掉正在服务当前
  ///   配置的那个进程（端口随之变化）——启动时刷它等于把用户正在用的站点打断；
  ///   它的新鲜度由启动恢复/激活时的 bundle md5 比对负责。
  /// - 安卓桥接源：内容在设备上，启动恢复路径已经按记忆精确重拉过一次；设备
  ///   离线时后台再打一轮只会产生一堆无意义的失败。
  /// - 粘贴的 JSON 文本：origin 是 inline://json，没有可刷新的来源。
  bool _isStartupRefreshTarget(ConfigRecord record) {
    if (record.json.isEmpty) return false;
    if (record.bridgeInterfaceKey.trim().isNotEmpty) return false;
    if (record.contentType == 'android-t4-gateway') return false;
    // 旧协议桥接记录没有 interfaceKey：设备地址、安卓侧配置地址与
    // bridge| 来源标识同样说明「内容在安卓设备上」，一个都不能漏。
    if (record.bridgeDevice.trim().isNotEmpty) return false;
    if (record.bridgeConfigUrl.trim().isNotEmpty) return false;
    if (record.sourceKey.startsWith('bridge|')) return false;
    if (CatSource.isBundle(record.origin)) return false;
    try {
      return ConfigSource.parse(record.origin).kind !=
          ConfigSourceKind.inlineJson;
    } on AppError {
      return false;
    }
  }

  /// 后台刷新一条配置：条件请求 → 304 或摘要一致就只记「检查过」。
  ///
  /// 失败时**只写检查结果**，内容、站点数与 updated_at 一律不动：远端拉不下来
  /// 时，本地缓存与已注册/已编译的站源继续照常可用——这正是增量刷新要保住的东西。
  Future<_ConfigRefreshOutcome> _refreshConfigInBackground(
    ConfigRecord record,
  ) async {
    final database = _database;
    if (database == null) return _ConfigRefreshOutcome.failed;
    final epoch = _configMutationEpoch;
    try {
      final source = ConfigSource.parse(record.origin);
      var imported = await _importService.import(
        source,
        validators: ConfigValidators(
          etag: record.etag,
          lastModified: record.lastModified,
        ),
      );
      if (imported.notModified) {
        database.markConfigChecked(
          record.id,
          etag: imported.etag.isEmpty ? null : imported.etag,
          lastModified: imported.lastModified.isEmpty
              ? null
              : imported.lastModified,
        );
        return _ConfigRefreshOutcome.unchanged;
      }
      final fromRepository = imported.isRepository;
      if (fromRepository) {
        // 仓库记录要展开的是用户当初选的那一条，不是「永远第一项」。
        imported = await _importService.expandRepository(
          imported,
          index: record.repositoryIndex ?? 0,
        );
      }
      // 仓库记录的 origin 是**仓库**地址，而展开后的校验值属于**条目**地址；
      // 存回去等于下一轮拿条目 ETag 去问仓库，永远对不上。仓库记录只靠摘要判断。
      final etag = fromRepository ? '' : imported.etag;
      final lastModified = fromRepository ? '' : imported.lastModified;
      final config = imported.config;
      if (config == null) {
        throw AppError(
          AppErrorKind.configInvalid,
          '来源没有可用配置',
          detail: redactUrl(record.origin),
        );
      }
      final hash = configRecordContentHash(config.toJson());
      if (hash == record.contentHash) {
        // 服务端没给校验值也能增量：内容摘要是最终判据。
        database.markConfigChecked(
          record.id,
          etag: etag.isEmpty ? null : etag,
          lastModified: lastModified.isEmpty ? null : lastModified,
          contentHash: hash,
        );
        return _ConfigRefreshOutcome.unchanged;
      }
      if (epoch != _configMutationEpoch) {
        // 用户在这几秒里导入/切换/编辑过配置：这一轮作废，别把刚写的东西盖回去。
        return _ConfigRefreshOutcome.skipped;
      }
      database.refreshConfigContent(
        record.id,
        json: config.toJson(),
        siteCount: config.sites.length,
        liveCount: config.lives.length,
        contentType: imported.contentType,
        origin: imported.origin,
        sourceKey: LocalSourceKey.of(imported.origin),
        etag: etag,
        lastModified: lastModified,
      );
      database.saveConfigSites(record.id, config.sites);
      if (_activeRecord?.id == record.id) {
        if (_userStillOnStartupHome) {
          await _reloadActiveConfigContent(config);
        } else {
          // 用户已经走进详情/分类：库已经是新的，内存里的站点列表等下一次切换
          // 配置或重启再换，免得把正在看的页面连根拔掉。
          log.info(
            '当前配置已后台更新：${record.name}（保留当前页面，'
            '下次切换配置或重启生效）',
            scope: 'config',
          );
        }
      }
      return _ConfigRefreshOutcome.changed;
    } on AppError catch (error) {
      _recordConfigCheckFailure(database, record, error);
      return _ConfigRefreshOutcome.failed;
    } catch (error) {
      _recordConfigCheckFailure(database, record, error);
      return _ConfigRefreshOutcome.failed;
    }
  }

  /// 用户是否还停在「启动后没动过」的首页。
  ///
  /// 只看确凿的导航状态（有没有打开详情、有没有进分类）。判偏的代价只是一次
  /// 多余的首页重载或一次延后生效，不值得为它引入更细的「用户是否正在操作」判断。
  bool get _userStillOnStartupHome =>
      _selectedVod == null && _categoryResult == null;

  /// 把一轮失败记在记录上（静默：不写 [lastError]，不弹横幅）。
  void _recordConfigCheckFailure(
    AppDatabase database,
    ConfigRecord record,
    Object error,
  ) {
    final message = error is AppError ? error.userMessage : '$error';
    final oneLine = message.replaceAll(RegExp(r'\s+'), ' ').trim();
    final stored = oneLine.length > 200
        ? '${oneLine.substring(0, 200)}…'
        : oneLine;
    try {
      database.markConfigChecked(record.id, error: stored);
    } catch (writeError) {
      log.warning('记录配置检查结果失败：$writeError', scope: 'config');
    }
    log.warning(
      '后台刷新配置失败：${record.name}（${redactUrl(record.origin)}）：$oneLine',
      scope: 'config',
    );
  }

  /// 当前生效配置的内容变了：重建配置与站点服务，并重挂首页。
  ///
  /// 只在**改动打到生效记录**时调用——否则会把用户正在看的站点列表清空。
  Future<void> _reloadActiveConfigContent(AppConfig config) async {
    _clearRestoredConfigSourceWarning(recordId: _activeRecord?.id);
    _config = config;
    // 交给 _attachSiteService 收尾：它会按 key 校验选中站点仍属于新配置，
    // 并优先恢复用户上次使用的站点，找不到才退回默认站点。
    _attachSiteService();
    _detailRunId++;
    _homeResult = null;
    _categoryResult = null;
    _detailResult = null;
    _detailError = null;
    _categoryFilters = const {};
    _resetCategoryPaging();
    _configPhase = LoadPhase.ready;
    _resetTmdbServices();
    notifyListeners();
    final site = _selectedSite;
    if (site != null) await loadHome(site);
  }

  /// 记住「最后一次使用的配置」（写 `<data>/last-config.json`）。
  ///
  /// 只记身份不记内容：内容已在 `configs` 表里，再存一份就是两份真相。
  void _rememberLastConfig(ConfigRecord record) {
    final store = _lastConfigStore;
    if (store == null) return;
    final sourceKey = sourceKeyOfRecord(record);
    final written = store.remember(sourceKey: sourceKey, recordId: record.id);
    _lastConfigRecord = written;
    if (written == null) {
      log.warning('无法记住上次使用的配置 #${record.id}（来源标识无效或写盘失败）', scope: 'config');
    }
  }

  /// 记忆里的桥接源要探测的地址：按 **deviceUuid** 在设备接入历史里找。
  ///
  /// 不用 `lastBridgeAddress`：那是「最近一次成功接入」的地址，用户中途接过
  /// 别的设备时它指向的是**另一台**设备，与他上次在用的源无关。
  String lastConfigDeviceAddress() {
    final memory = _lastConfigRecord;
    if (memory == null || !memory.isBridge) return '';
    return deviceAddressForUuid(memory.deviceUuid);
  }

  /// 按设备 uuid 找接入地址。
  ///
  /// 单独开一个入口，是因为「没有记忆时按 is_active 兜底推断」那条路径手里
  /// 只有设备 uuid（推断出来的记录不写盘，也不进 lastConfigRecord）。
  String deviceAddressForUuid(String uuid) {
    final key = uuid.trim();
    if (key.isEmpty) return '';
    for (final entry in syncState.deviceHistory) {
      if (entry.uuid == key) return entry.address;
    }
    return '';
  }

  /// 记忆里那台设备的名字（横幅要在**探测失败时**也能说出是哪台设备）。
  ///
  /// 探测失败就拿不到 `AndroidDevice`，此时只能回读设备接入历史：
  /// 「未知设备」对用户没有任何帮助，他还得自己去接入页猜。
  String lastConfigDeviceName() {
    final memory = _lastConfigRecord;
    if (memory == null || !memory.isBridge) return '';
    return deviceNameForUuid(memory.deviceUuid);
  }

  /// 按设备 uuid 找设备名；历史里没有这台设备时回退成 uuid 本身。
  ///
  /// 回退成 uuid 而不是「未知设备」：横幅要让用户认得出是哪台设备，哪怕只能
  /// 给出机器标识，也比他回接入页一台台去猜强。
  String deviceNameForUuid(String uuid) {
    final key = uuid.trim();
    if (key.isEmpty) return '';
    for (final entry in syncState.deviceHistory) {
      if (entry.uuid == key) return entry.name;
    }
    return key;
  }

  /// 恢复桥接源时锁定的设备（无则 `null`）。
  AndroidDevice? get lastConfigDevice => _lastConfigPin;

  void pinLastConfigDevice(AndroidDevice? device) {
    _lastConfigPin = device;
    notifyListeners();
  }

  /// 恢复「最后一次使用的配置」（Phase 10）。
  ///
  /// 三条语义，缺一不可：
  /// - **本地源**：内容在库里，直接切过去即可，不发任何网络请求；
  /// - **桥接源**：本机只有上次落库的内容，设备上的源可能改名/改地址，所以
  ///   必须由调用方先探测，这里只认 [activateLastConfig]；
  /// - **记录已不存在**：静默回落默认配置并写一条日志——这是「用户删过配置」，
  ///   不是故障，不该弹窗（用户明确要求）。
  ///
  /// 返回是否真的切换成功。调用方负责首页加载。
  Future<bool> restoreLastConfig() async {
    final store = _lastConfigStore;
    final memory = _lastConfigRecord;
    if (store == null || memory == null) return false;
    final record = _recordBySourceKey(memory.sourceKey, memory.recordId);
    if (record == null) {
      log.info(
        '上次使用的配置已不存在（sourceKey=${memory.sourceKey} '
        '#${memory.recordId}），保持当前配置',
        scope: 'config',
      );
      store.clear();
      _lastConfigRecord = null;
      return false;
    }
    // 已经是它：bootstrap 按 `is_active` 恢复出来的就是这条，不必再切一遍
    // （再切一次会重建猫源、重发首页请求，纯属放大启动开销）。
    if (_activeRecord?.id == record.id) return true;
    return activateConfigRecord(record.id);
  }

  /// 激活记忆里那条**指定来源**的配置（桥接源探测成功后调用）。
  ///
  /// 为什么必须按 sourceKey 而不是按 origin：同一台安卓设备上的多个源 origin
  /// 全是同一个网关地址，按 origin 挑只会命中「最后导入的那条」，而用户上次
  /// 用的是哪条只有 sourceKey 记得住。
  Future<bool> activateLastConfig() async {
    final memory = _lastConfigRecord;
    if (memory == null) return false;
    return activateConfigBySourceKey(
      memory.sourceKey,
      recordId: memory.recordId,
    );
  }

  /// 按来源标识精确激活一条记录。
  ///
  /// 与 [activateLastConfig] 的差别只在**坐标从哪来**：这里由调用方给。兜底
  /// 推断（没有 last-config.json、但 is_active 仍是桥接源）手里是一条临时构造
  /// 的记忆，它不住在 lastConfigRecord 里，走不了那个按记忆取坐标的入口。
  Future<bool> activateConfigBySourceKey(
    String sourceKey, {
    int recordId = 0,
  }) async {
    final record = _recordBySourceKey(sourceKey, recordId);
    if (record == null) {
      log.info(
        '上次使用的配置已不存在（sourceKey=$sourceKey '
        '#$recordId），保持当前配置',
        scope: 'config',
      );
      return false;
    }
    if (_activeRecord?.id == record.id) return true;
    return activateConfigRecord(record.id);
  }

  /// 记忆里的记录是否还活着（桥接源探测成功后、导入之前先查一次）。
  bool get lastConfigRecordAlive {
    final memory = _lastConfigRecord;
    if (memory == null) return false;
    return lastConfigRecordAliveFor(memory);
  }

  /// 指定的这条记忆指向的记录是否还活着。
  ///
  /// 单独开一个入口的理由同 [activateConfigBySourceKey]：兜底推断的临时记忆
  /// 不在 lastConfigRecord 里。
  bool lastConfigRecordAliveFor(LastConfigRecord memory) =>
      _recordBySourceKey(memory.sourceKey, memory.recordId) != null;

  /// 删除失效的记忆（记录已被用户删掉时调用，避免下次启动再查一遍）。
  void forgetLastConfig() {
    _lastConfigStore?.clear();
    _lastConfigRecord = null;
  }

  ConfigRecord? _recordBySourceKey(String sourceKey, int fallbackId) {
    final database = _database;
    if (database != null) {
      final bySource = database.configBySourceKey(sourceKey);
      if (bySource != null) return bySource;
      for (final item in database.listConfigs()) {
        if (item.id == fallbackId) return item;
      }
      return null;
    }
    for (final item in _configs) {
      if (item.id == fallbackId) return item;
      if (sourceKeyOfRecord(item) == sourceKey) return item;
    }
    return null;
  }

  Future<void> deleteConfigRecord(int id) async {
    final database = _database;
    if (database == null) return;
    _configMutationEpoch++;
    database.deleteConfig(id);
    _clearRestoredConfigSourceWarning(recordId: id);
    _configs = database.listConfigs();
    if (_activeRecord?.id == id) {
      _activeRecord = database.activeConfig();
      _beginCurrentTmdbCredentialScope();
      final record = _activeRecord;
      if (record != null && record.json.isNotEmpty) {
        _config = parseConfigRecord(record.json);
        _attachSiteService();
        _detailRunId++;
        _detailResult = null;
        _detailError = null;
      } else {
        _cancelSearchWork();
        _config = null;
        _effectiveConfigCache = null;
        _kickDirectRegistration();
        _kickCspProvisioning(effectiveConfig);
        _siteService = null;
        _selectedSite = null;
        _homeResult = null;
        _categoryResult = null;
        _categoryFilters = const {};
        _resetCategoryPaging();
        _detailResult = null;
        _detailError = null;
        _configPhase = LoadPhase.idle;
      }
    }
    notifyListeners();
  }

  /// 选择站点并加载首页。
  Future<void> selectSite(Site site) async {
    _homeRunId++;
    // 换站点时作废在途详情请求：旧站点的响应不得覆盖新站点的详情（§8.3）。
    _detailRunId++;
    _selectedSite = site;
    _categoryResult = null;
    _detailResult = null;
    _detailError = null;
    _selectedVod = null;
    _selectedTypeId = null;
    // 筛选与分页都是**站点/分类相关**的，换站点必须一起作废（见 _resetCategoryPaging）。
    _categoryFilters = const {};
    _resetCategoryPaging();
    // 加固壳：登记「这个站点要不要确认解包」的信号（单槽、幂等），
    // 由壳层在选完站点后读取并弹框；state 层不弹 UI。
    _noteShellUnpackForSite(site);
    // 本地 HTML 首页不是爬虫站点：内容由 `WebHomePage`（WebView2）承载，走
    // [loadHome] 只会得到一次假「站点不可用」。这里只登记选中态，也**不**写
    // 「最近使用站点」——否则下次启动会把一个不能加载首页的条目当成默认站点。
    if (webHomeKeyOfSite(site) != null) {
      _homeResult = null;
      notifyListeners();
      return;
    }
    // 记住本次选择：重启后默认回到这个站点（用户需求 2026-10-10）。
    // 写盘失败不影响当前会话（内存已生效），因此不 await 结果。
    // `_uiPreferences` 为 null（未 bootstrap）时安静跳过，不让选站点失败。
    unawaited(
      _uiPreferences?.rememberSite(site.key.isEmpty ? site.name : site.key) ??
          Future<void>.value(),
    );
    notifyListeners();
    await loadHome(site);
  }

  /// 清空详情页状态（离开详情页时调用，§8.3）。
  ///
  /// 详情结果与所选影片是**绑定在详情页上的临时状态**：不清理的话，用户返回
  /// 列表后再点另一部剧，详情页会先渲染上一个条目的线路，点播即串剧（实测：
  /// 「返回后点其他剧看到的还是这部剧的信息」）。这里同时作废在途请求，避免
  /// 刚离开页面时返回的响应又把状态写回去。
  void clearDetail() {
    _detailRunId++;
    _tmdbRunId = _detailRunId;
    // TMDB **故意不清**（以前这里 `_tmdbState?.clear()`）。
    //
    // 为什么改：作品维度的 TMDB 数据（匹配/详情/演职人员/推荐/视频/季集映射）被清掉
    // 后，第二次进同一部剧必然先渲染一帧站源「原始模式」，等 TMDB 重新匹配、重发请求
    // 回来才换成 TMDB 版本——用户反馈「点第二次还是会先显示原始模式后再等于会渲染成
    // tmdb 版本」就是这个。留着，重进同一部剧首帧就能直出。
    // 为什么这样安全（换了作品也不会串剧）：
    // 1) `_tmdbRunId = _detailRunId` 照旧作废在途 TMDB 请求，旧响应不会写回状态；
    // 2) 详情页渲染前先过归属门 `TmdbState.belongsTo`，保留的数据不属于本页影片时
    //    所有 TMDB 渲染点按「无 TMDB」降级（browse_pages.dart 的 _tmdbOwnsThisPage）；
    // 3) `loadDetail` 发现保留数据属于别的作品时也会先 `clear()`。
    _detailPhase = LoadPhase.idle;
    _detailResult = null;
    _detailError = null;
    _selectedVod = null;
    notifyListeners();
  }

  /// 加载首页（§8.1、§8.4）。
  ///
  /// 首页无推荐内容时**自动选第一个分类**（用户反馈 2026-10-09：「如果当前站点的
  /// 默认推荐分类无数据时自动隐藏选中显示第一个分类即可」）。
  ///
  /// 为什么：实测 126 个站点里 40 个只返回 `class` 而不返回 `list`，用户进入站点后
  /// 看到的是「请选择一个分类」的空态，必须先手动点一下才有内容——既然站点已经
  /// 给了分类列表，帮用户选第一个是零风险的行为。
  Future<void> loadHome(Site site) async {
    if (webHomeKeyOfSite(site) != null) return;
    final config = effectiveConfig;
    final missingCsp = CspJvmBinding.matches(site.api) &&
        directSpiderKind(site) == null &&
        JarSourceSpec.parse(site.effectiveJar(config?.spider)) != null &&
        _router.cspBinding?.entryFor(site.key) == null;
    final provisioningCurrent = identical(_cspProvisionConfig, config);
    if (missingCsp && provisioningCurrent && _cspProvisionInFlight &&
        (_cspProvisionPreparing || _router.provisioningSiteKeys.contains(site.key))) {
      ++_homeRunId;
      _cspHomeRetryConfig = config;
      _cspHomeRetrySite = site;
      _contentPhase = LoadPhase.loading;
      _lastError = null;
      _notice = '站点正在后台安装站源，完成后会自动加载';
      _notifyIfAlive();
      return;
    }
    if (missingCsp && provisioningCurrent && _cspDeferredSiteKeys.contains(site.key)) {
      ++_homeRunId;
      _contentPhase = LoadPhase.failed;
      _lastError = AppError(AppErrorKind.siteUnsupported, _cspDeferredReason);
      _notifyIfAlive();
      return;
    }
    final service = _siteService;
    if (service == null) return;
    final runId = ++_homeRunId;
    if (CspJvmBinding.matches(site.api) &&
        directSpiderKind(site) == null &&
        _router.cspBinding?.entryFor(site.key) == null) {
      _cspHomeRetryConfig = effectiveConfig;
      _cspHomeRetrySite = site;
    }
    bool current() =>
        !_disposed &&
        runId == _homeRunId &&
        identical(service, _siteService) &&
        _selectedSite?.key == site.key &&
        _selectedSite?.api == site.api &&
        _selectedSite?.name == site.name;
    // 直连站源（.js/.py/CatVod 壳）要先等注册落定，否则首页会拿到一次
    // 假「运行时未支持」（真实原因只是注册还没写完）。真 Android jar 不在
    // 这一集合里，仍然立即如实报「不支持」。
    if (directSpiderKind(site) != null &&
        _router.directSpiders[site.key] == null) {
      // 先登记补载：8 秒只是让行上限，注册可能在此后才完成。
      if (_directReady != null && _router.directSpiders[site.key] == null) {
        _directHomeRetryConfig = effectiveConfig;
        _directHomeRetrySite = site;
      }
      await _waitForDirectRegistration();
      if (!current()) return;
      // 等待期间已就绪：本次请求自己会加载成功，撤掉补载避免重复请求。
      if (_router.directSpiders[site.key] != null) {
        _directHomeRetryConfig = null;
        _directHomeRetrySite = null;
      }
    }
    await _waitForPythonSite(site);
    if (!current()) return;
    _contentPhase = LoadPhase.loading;
    _lastError = null;
    if (current()) _notifyIfAlive();
    try {
      final outcome = await service.home(site);
      if (!current()) return;
      _homeResult = outcome.value;
      _contentPhase = LoadPhase.ready;
      log.info(
        '首页加载成功 site=${site.key} class=${outcome.value.classes.length} '
        'list=${outcome.value.list.length} '
        'elapsed=${outcome.latency.inMilliseconds}ms',
        scope: 'site',
      );
      // 只在「确实没有推荐内容」且「有分类可选」时才自动选：有推荐内容时不得
      // 抢走用户看到的首页；无分类可退时也不得反复空请求。
      final first = outcome.value.classes.isEmpty
          ? null
          : outcome.value.classes.first;
      if (current() && outcome.value.list.isEmpty && first != null) {
        log.info(
          '首页无推荐内容，自动进入第一个分类 '
          't=${first.typeId} name=${first.typeName}',
          scope: 'site',
        );
        await loadCategory(first.typeId);
        return;
      }
    } catch (error) {
      if (!current()) return;
      final failure = error is AppError
          ? error
          : AppError(AppErrorKind.unknown, '$error', cause: error);
      _lastError = failure;
      _contentPhase = LoadPhase.failed;
      log.error('首页加载失败 site=${site.key} ${failure.logLine}', scope: 'site');
    }
    if (current()) _notifyIfAlive();
  }

  /// 作废分类分页状态（换站点 / 换配置 / 回首页时调用）。
  ///
  /// 递增运行号是必须的：不递增时，「上一个分类下一页」的迟到响应仍会被判定为
  /// 当前请求，把旧列表写回 [_categoryResult]（用户在别的站点上看到旧站点的片单）。
  void _resetCategoryPaging() {
    _categoryRunId++;
    _categoryPage = 1;
    _categoryHasMore = false;
    _categoryLoadingMore = false;
  }

  /// 显式保存/清除账号后刷新「当前选中的分类」。
  ///
  /// 只重跑当前分类列表：不切站点/配置、不进入详情、不触发 TMDB/AI。
  /// 未选中分类或已卸载时什么都不做（迟到写入不得改界面）。
  /// 失败时抛 [SpiderAccountRefreshException]：`loadCategory` 自己只把失败写进
  /// [contentPhase]/[lastError]（普通分类页的错误横幅，语义不变），UI 从这次
  /// 调用的返回值分不清「刷新完成」和「刷新失败」，会误报刷新成功。
  /// 只有当源与分类仍是发起时那一个（且没有新的分类加载顶替）才抛；否则视为
  /// 过期请求，静默返回。
  Future<void> refreshSpiderAccountCategory() async {
    if (_disposed) return;
    final site = _selectedSite;
    final typeId = _selectedTypeId;
    if (site == null || typeId == null) return;
    final runIdBefore = _categoryRunId;
    await loadCategory(typeId);
    if (_disposed) return;
    final current = _selectedSite;
    final sameContext =
        current != null &&
        current.key == site.key &&
        current.api == site.api &&
        _selectedTypeId == typeId &&
        _categoryRunId == runIdBefore + 1;
    if (!sameContext) return;
    if (_contentPhase == LoadPhase.failed && _lastError != null) {
      throw const SpiderAccountRefreshException();
    }
  }

  /// 加载分类（§7.4.7 分页与筛选）。
  ///
  /// 这是「重新开始」路径（[page] 默认 1）：**清空并替换**已有结果。用户实际翻页
  /// 走 [loadMoreCategory]（滚动到底自动追加）。
  ///
  /// [filters] 省略时沿用当前 [_categoryFilters]（**切分类保留筛选**）；
  /// 显式传入（含空表）则覆盖。
  Future<void> loadCategory(
    String typeId, {
    int page = 1,
    Map<String, String>? filters,
  }) async {
    final service = _siteService;
    final site = _selectedSite;
    if (service == null || site == null) return;
    final runId = ++_categoryRunId;
    await _waitForPythonSite(site);
    if (_disposed || runId != _categoryRunId) return;
    final effective = filters ?? _categoryFilters;
    // 新一次加载：作废在途的“下一页”响应，避免把上一份列表追加到新列表后面。
    _selectedTypeId = typeId;
    _categoryFilters = effective;
    _categoryResult = null;
    _categoryPage = page;
    _categoryHasMore = false;
    _categoryLoadingMore = false;
    _contentPhase = LoadPhase.loading;
    _lastError = null;
    _notifyIfAlive();
    try {
      final outcome = await service.category(
        site,
        typeId: typeId,
        page: page,
        filters: effective,
      );
      if (runId != _categoryRunId) return;
      _categoryResult = outcome.value;
      _categoryPage = page;
      _categoryHasMore = _hasNextPage(outcome.value);
      _contentPhase = LoadPhase.ready;
      log.info(
        '分类加载成功 site=${site.key} t=$typeId page=$page '
        'filters=${effective.isEmpty ? "-" : effective.length} '
        'list=${outcome.value.list.length} '
        'pagecount=${outcome.value.pageCount ?? "-"} '
        'elapsed=${outcome.latency.inMilliseconds}ms',
        scope: 'site',
      );
    } catch (error) {
      if (runId != _categoryRunId) return;
      final failure = error is AppError
          ? error
          : AppError(AppErrorKind.unknown, '$error', cause: error);
      _lastError = failure;
      _contentPhase = LoadPhase.failed;
      log.error(
        '分类加载失败 site=${site.key} t=$typeId ${failure.logLine}',
        scope: 'site',
      );
    }
    _notifyIfAlive();
  }

  /// 追加下一页（滚动到底自动触发，§7.4.7）。
  ///
  /// 与 [loadCategory] 的关键差异：
  /// - 旧列表**保留**并追加新页（不先清空），滚动位置不会跳；
  /// - 不加 `_contentPhase = loading`（那是页面级骨架屏），而是置
  ///   [categoryLoadingMore]，避免滚到底时整个网格闪成空白；
  /// - 失败**不写入** `lastError`（不把已经看得见的列表换成错误横幅），
  ///   只记日志并把 `categoryHasMore` 收矮，避免滚动到底反复重试。
  Future<void> loadMoreCategory() async {
    if (_categoryLoadingMore || !_categoryHasMore) return;
    if (_contentPhase == LoadPhase.loading) return;
    final service = _siteService;
    final site = _selectedSite;
    final typeId = _selectedTypeId;
    final current = _categoryResult;
    if (service == null || site == null || typeId == null || current == null) {
      return;
    }
    final runId = _categoryRunId;
    final nextPage = _categoryPage + 1;
    _categoryLoadingMore = true;
    notifyListeners();
    try {
      final outcome = await service.category(
        site,
        typeId: typeId,
        page: nextPage,
        filters: _categoryFilters,
      );
      // 切分类 / 换筛选 / 换站点后到达的响应：直接丢弃（不得拼接）。
      if (runId != _categoryRunId) return;
      final merged = _mergeVods(current.list, outcome.value.list);
      _categoryResult = outcome.value.copyWith(
        list: merged,
        // 分类没有筛选时，站点可能只在首页响应里给筛选维度。追加页的响应
        // 不带 filters，套用会把已有的筛选条抹掉（用户看到“筛选行突然消失”）。
        filters: outcome.value.filters.isEmpty
            ? current.filters
            : outcome.value.filters,
      );
      _categoryPage = nextPage;
      // 到底的判据：本页为空，或本页没有带来任何**新**条目。后者是站点忽略
      // `pg`（反复回同一页）的唯一可靠信号，不接就会无限循环请求同一页。
      _categoryHasMore =
          outcome.value.list.isNotEmpty && merged.length > current.list.length;
      log.info(
        '分类追加成功 site=${site.key} t=$typeId page=$nextPage '
        'added=${outcome.value.list.length} total=${merged.length} '
        'hasMore=$_categoryHasMore elapsed=${outcome.latency.inMilliseconds}ms',
        scope: 'site',
      );
    } catch (error) {
      if (runId != _categoryRunId) return;
      // 追加失败不抛、不报警：把 hasMore 关掉，用户不再反复触发同一页。
      _categoryHasMore = false;
      log.warning(
        '分类追加失败 site=${site.key} t=$typeId page=$nextPage $error',
        scope: 'site',
      );
    } finally {
      if (runId == _categoryRunId) {
        _categoryLoadingMore = false;
        _notifyIfAlive();
      }
    }
  }

  /// 分类响应是否还有下一页。
  ///
  /// **不得用 `pagecount` / `total`**（实测 2026-10-09，桥接的网盘聚合站
  /// `闪电[盘]`）：同一个分类连续翻页，站点每次回的 `pagecount` 都是
  /// `当前页 + 1`（pg=1 → 2、pg=2 → 3、pg=3 → 4），`total` 同步从 92 涨到
  /// 112、132。这两个字段是上游插件**按当前页现算**的，不表示真实总页数；
  /// 拿它们当判据会让「还有下一页」永远为真，滚动永远加载不完。
  ///
  /// 因此只信内容：拿到非空列表就先假定还有下一页，真正的终止由追加阶段的
  /// 「页面为空 / 没有新增条目」负责。
  static bool _hasNextPage(SiteResult result) => result.list.isNotEmpty;

  /// 合并两页列表，按 `vod_id` 去重（保序：旧页在前）。
  ///
  /// 为什么必须去重：部分站点忽略 `pg` 参数、或末页与前一页有重叠，直接拼接会
  /// 让同一部片重复出现（用户看到列表里“同一张海报连着两张”）。
  static List<Vod> _mergeVods(List<Vod> existing, List<Vod> incoming) {
    final seen = <String>{};
    final merged = <Vod>[];
    for (final vod in [...existing, ...incoming]) {
      if (!seen.add(vod.vodId)) continue;
      merged.add(vod);
    }
    return merged;
  }

  /// 设置/清除单个筛选维度，并**立即重载当前分类**（筛选是即时生效的）。
  ///
  /// [value] 为空串表示清除该维度（对应「全部」选项）。
  Future<void> setCategoryFilter(String key, String value) async {
    final typeId = _selectedTypeId;
    if (typeId == null) return;
    final next = Map<String, String>.from(_categoryFilters);
    if (value.isEmpty) {
      next.remove(key);
    } else {
      next[key] = value;
    }
    if (_sameFilters(next, _categoryFilters)) return;
    await loadCategory(typeId, filters: next);
  }

  /// 清空全部筛选并重载当前分类。
  Future<void> clearCategoryFilters() async {
    final typeId = _selectedTypeId;
    if (typeId == null || _categoryFilters.isEmpty) return;
    await loadCategory(typeId, filters: const {});
  }

  static bool _sameFilters(Map<String, String> a, Map<String, String> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }

  /// 搜索（§14.1）。
  Future<SiteResult?> search(
    Site site, {
    required String keyword,
    int page = 1,
    bool quick = false,
  }) async {
    final service = _siteService;
    if (service == null) return null;
    try {
      await _waitForPythonSite(site);
      if (_disposed) return null;
      final outcome = await service.search(
        site,
        keyword: keyword,
        page: page,
        quick: quick,
      );
      log.info(
        '搜索完成 site=${site.key} wd=$keyword list=${outcome.value.list.length} '
        'cache=${outcome.fromCache} elapsed=${outcome.latency.inMilliseconds}ms',
        scope: 'search',
      );
      return outcome.value;
    } catch (error) {
      final failure = error is AppError
          ? error
          : AppError(AppErrorKind.unknown, '$error', cause: error);
      log.warning('搜索失败 site=${site.key} ${failure.logLine}', scope: 'search');
      rethrow;
    }
  }

  /// 换源取数与普通详情共用站点服务、目录展开和线路解析，不写全局详情槽。
  /// [listing] 保留搜索条目的目录标记及自带线路；只在详情 list 为空时回退它。
  Future<PlaybackLines> swapProbe({
    required String siteKey,
    required String vodId,
    String vodName = '',
    Vod? listing,
  }) async {
    final site = siteByKey(siteKey);
    if (site == null) {
      throw AppError(AppErrorKind.siteUnsupported, '换源目标站点不存在：$siteKey');
    }
    final service = _siteService;
    if (service == null) {
      throw AppError(AppErrorKind.siteUnsupported, '站点服务不可用：$siteKey');
    }
    await _waitForPythonSite(site);
    if (_disposed) return PlaybackLines.empty;
    final seed = listing ?? Vod(vodId: vodId, vodName: vodName);
    if (seed.isFolder) {
      if (!isBridgeFolderVodId(seed.vodId)) {
        throw AppError(AppErrorKind.siteUnsupported, '该结果是目录，请先进入详情选择可播放条目');
      }
      final expanded = await service.folderPlaybackLines(
        site,
        seed,
        isCurrent: () => !_disposed,
      );
      return _disposed ? PlaybackLines.empty : expanded;
    }
    final outcome = await service.detail(
      site,
      vodId,
      identity: VodIdentityHint(vodId: vodId, vodName: seed.vodName),
    );
    if (_disposed) return PlaybackLines.empty;
    final effective = outcome.value.list.firstOrNull ?? seed;
    final lines = playLinesOf(effective);
    final routes = <String, SwapLineRoute>{
      for (final line in lines)
        line.flag: SwapLineRoute(
          siteKey: site.key,
          siteName: site.name,
          vodId: effective.vodId,
        ),
    };
    return PlaybackLines(
      lines: lines,
      warnings: outcome.warnings,
      routes: routes,
    );
  }

  /// 多站点并发搜索（§14.1、§14.3）。
  ///
  /// 行为约束：
  /// - 并发数不超过 [maxConcurrency]（默认取用户的「搜索线程」设置，
  ///   对齐上游 `Setting.getSearchThread`），避免一次性打满网络与对端限流（§14.3）；
  /// - 单站点失败只把该站点标为失败，**不阻塞**其他站点；
  /// - 新查询会让旧查询的在途结果**不再投递**（靠 runId 与 [_activeSearch] 判定）；
  /// - 取消后不再投递任何结果（含在途结果），只保留取消前已发布的快照；
  /// - 结果按配置中的站点顺序稳定排序，重复搜索不改变顺序。
  ///
  /// [siteKey] / [group] 限定搜索范围（对齐上游 SearchFragment 的
  /// 「全部 / 当前站点 / 某分组」）：范围外的站点**既不参与也不算跳过**。
  ///
  /// [quick] 对齐上游「快速搜索」（安卓 searchContent(sites, keyword, true)）：
  /// 站点声明了 quickSearch 时请求带上 quick=true，由站点侧少翻页/少解析。
  /// 换源浮层走的就是这条路径——它是安卓既有的限流语义，不是新增开关。
  Future<MultiSiteSearchOutcome> searchAll(
    String keyword, {
    String? siteKey,
    String? group,
    int? maxConcurrency,
    Duration timeout = const Duration(seconds: 20),
    bool quick = false,
  }) async {
    final service = _siteService;
    final runId = ++_searchRunId;
    final concurrency = maxConcurrency ?? searchThread;
    final scopeSiteKey = siteKey?.trim() ?? '';
    final scopeGroup = group?.trim() ?? '';
    // 被屏蔽的站点不进「范围」：它们不发起请求，也不该被统计成「跳过」——
    // 对用户来说它们已经不在列表里（与安卓 SiteBlockSetting.filter 同口径）。
    final allItems = [
      for (final item in siteItems)
        if (_inSearchScope(item.site, scopeSiteKey, scopeGroup) &&
            !isSiteBlocked(item.site.key))
          item,
    ];
    var sites = allItems
        .where((item) => item.availability.available && item.site.searchable)
        .map((item) => item.site)
        .toList();
    // Phase 9 P1-3：健康排序只影响搜索顺序，不改变配置本身。
    if (siteOrder.healthSort && sites.length > 1) {
      final byKey = {for (final site in sites) site.key: site};
      final ordered = orderSiteKeysByHealth(
        keys: [for (final site in sites) site.key],
        enabled: true,
        scores: siteHealthScores(),
      );
      sites = [for (final key in ordered) byKey[key]!];
    }
    final outcome = MultiSiteSearchOutcome(
      runId: runId,
      keyword: keyword,
      results: const [],
      siteKey: scopeSiteKey,
      group: scopeGroup,
      skippedUnsupported: allItems
          .where((item) => !item.availability.available)
          .length,
      skippedNotSearchable: allItems
          .where((item) => item.availability.available && !item.site.searchable)
          .length,
      totalSites: sites.length,
    );
    // 新批次从第 1 页开始：分页状态必须清空，否则会沿用上一批次的页码。
    _cancelSearchWork(markCancelled: false);
    _searchPaging.clear();
    _activeSearch = outcome;
    _searchHistory = [
      keyword,
      ..._searchHistory.where((item) => item != keyword),
    ].take(20).toList();
    // 持久化搜索历史（上游安卓 `RecordAdapter.add` 落 `Setting.putKeyword`）。
    // 写盘失败不影响当前会话；未 bootstrap（测试路径）时安静跳过。
    // 隐身模式下只在本次会话内存里保留，不落盘（P2-8）。
    if (!incognito) {
      unawaited(
        _uiPreferences
                ?.rememberSearchKeyword(keyword)
                .then((_) => null)
                .catchError((_) => null) ??
            Future<void>.value(),
      );
    }
    notifyListeners();

    if (service == null || sites.isEmpty) {
      outcome.finished = true;
      notifyListeners();
      return outcome;
    }

    final entries = <SiteSearchEntry>[];
    var nextIndex = 0;
    final stopwatch = Stopwatch()..start();

    Future<void> worker() async {
      while (true) {
        final index = nextIndex++;
        if (index >= sites.length) return;
        // 被取消或被更新的查询取代时立即收工：不再发起新请求。
        if (outcome.cancelled || !identical(_activeSearch, outcome)) return;
        final site = sites[index];
        try {
          final value = await _searchRequest(
            service,
            site,
            keyword: keyword,
            quick: quick,
            timeout: timeout,
          );
          // 记录初始页的页数与内容指纹（上游 CollectFragment 的
          // `mPaging.recordInitial`）。批次已被取代时不得污染新批次的
          // 分页状态——`_searchPaging` 是跨批次共享的。
          if (!outcome.cancelled && identical(_activeSearch, outcome)) {
            _searchPaging.recordInitial(
              site.key,
              value.value.pageCount ?? 0,
              SearchPagingState.pageTokenOf(value.value.list),
            );
          }
          entries.add(
            SiteSearchEntry(
              siteKey: site.key,
              siteName: site.name,
              groups: siteGroupsOf(
                site.name,
                rules: siteGroupSettings.enabledRules,
              ),
              result: value.value,
              latency: value.latency,
              fromCache: value.fromCache,
              pageCount: value.value.pageCount ?? 0,
              hasMore: _searchPaging.canLoadMore(site.key),
            ),
          );
        } catch (error) {
          if (outcome.cancelled || !identical(_activeSearch, outcome)) return;
          final failure = error is AppError
              ? error
              : AppError(AppErrorKind.unknown, '$error', cause: error);
          entries.add(
            SiteSearchEntry(
              siteKey: site.key,
              siteName: site.name,
              groups: siteGroupsOf(
                site.name,
                rules: siteGroupSettings.enabledRules,
              ),
              error: failure,
            ),
          );
          log.warning(
            '并发搜索失败 site=${site.key} ${failure.logLine}',
            scope: 'search',
          );
        }
        // 每完成一个站点就更新快照，让 UI 边到边显示。
        // 取消后即便请求刚好返回也**不得投递**（§9.5、§14.1）。
        if (!outcome.cancelled && identical(_activeSearch, outcome)) {
          outcome.update(entries);
          _notifyIfAlive();
        }
      }
    }

    final concurrencyApplied = sites.length < concurrency
        ? sites.length
        : concurrency;
    await Future.wait(List.generate(concurrencyApplied, (_) => worker()));

    if (outcome.cancelled) {
      log.info(
        '搜索批次 run=$runId 已取消，丢弃 ${entries.length} 个在途结果 keyword=$keyword',
        scope: 'search',
      );
      return outcome;
    }

    if (!identical(_activeSearch, outcome)) {
      log.info('搜索批次 run=$runId 已被取代，结果不再投递 keyword=$keyword', scope: 'search');
      return outcome;
    }

    // 按配置顺序稳定排序，避免并发完成顺序导致列表跳动。
    final order = {for (var i = 0; i < sites.length; i++) sites[i].key: i};
    entries.sort(
      (a, b) => (order[a.siteKey] ?? 0).compareTo(order[b.siteKey] ?? 0),
    );
    outcome.update(entries);
    outcome.finished = true;
    outcome.totalElapsed = stopwatch.elapsed;
    log.info(
      '并发搜索完成 run=$runId wd=$keyword sites=${sites.length} '
      'quick=$quick '
      'concurrency=$concurrencyApplied '
      'ok=${entries.where((item) => item.succeeded).length} '
      'failed=${entries.where((item) => !item.succeeded).length} '
      'elapsed=${stopwatch.elapsedMilliseconds}ms',
      scope: 'search',
    );
    _notifyIfAlive();
    return outcome;
  }

  Future<SiteCallResult<SiteResult>> _searchRequest(
    SiteService service,
    Site site, {
    required String keyword,
    required Duration timeout,
    int page = 1,
    bool quick = false,
    bool cache = true,
  }) async {
    final cancellation = RequestCancellation();
    _searchRequests.add(cancellation);
    final timer = Timer(timeout, () {
      cancellation.cancel(
        AppError(AppErrorKind.siteTimeout, '搜索超时 site=${site.key}'),
      );
    });
    try {
      return await service.search(
        site,
        keyword: keyword,
        page: page,
        quick: quick,
        useCache: true,
        cache: cache,
        cancellation: cancellation,
      );
    } finally {
      timer.cancel();
      _searchRequests.remove(cancellation);
    }
  }

  void _cancelSearchWork({bool markCancelled = true}) {
    final active = _activeSearch;
    if (active != null) {
      if (markCancelled) active.cancelled = true;
      active.finished = true;
      for (final entry in active.results) {
        if (entry.loadingMore) {
          active.replaceEntry(entry.copyWith(loadingMore: false));
        }
      }
    }
    for (final cancellation in _searchRequests.toList()) {
      cancellation.cancel();
    }
    _searchRequests.clear();
    _searchPaging.cancelPending();
  }

  /// 取消首轮和分页在途请求，保留已发布结果快照。
  void cancelSearch() {
    final active = _activeSearch;
    if (active == null ||
        (active.finished &&
            _searchRequests.isEmpty &&
            !_searchPaging.hasPending)) {
      return;
    }
    _cancelSearchWork();
    log.info('并发搜索已取消 run=${active.runId}', scope: 'search');
    notifyListeners();
  }

  /// 清空当前搜索结果，回到「未搜索」状态。
  ///
  /// 为什么需要它（用户 2026-10-14：「搜索之后貌似没办法返回到搜索页面
  /// 默认状态——就是能看到推荐的那些，切换到其他页面再切回来也不行」）：
  /// [_activeSearch] 是**跨页面存活**的（搜索页销毁重建后仍在），而搜索页
  /// 靠它判断要不要显示结果区——于是搜过一次就再也回不到推荐落地页了。
  ///
  /// 与 [cancelSearch] 的区别：后者只把在途批次标为已取消（UI 显示「搜索已
  /// 取消」），而这里把批次整个丢掉，回到干净的未搜索状态。
  void clearSearch() {
    if (_activeSearch == null && !_searchPaging.hasPending) return;
    // 递增运行号：在途批次的结果即便返回也不再投递（否则清空后又被写回）。
    _searchRunId++;
    final runId = _activeSearch?.runId;
    _cancelSearchWork();
    _activeSearch = null;
    _searchPaging.clear();
    log.info('已清空搜索结果 run=${runId ?? "-"}', scope: 'search');
    notifyListeners();
  }

  /// 站点是否落在本次搜索范围内（空条件 = 不限定）。
  bool _inSearchScope(Site site, String siteKey, String group) {
    if (siteKey.isNotEmpty && site.key != siteKey) return false;
    if (group.isNotEmpty && !siteInGroup(site.name, group)) return false;
    return true;
  }

  /// 按 key 取站点（加载更多需要重新拿到站点对象才能发请求）。
  ///
  /// 复用既有的静态 [`_siteByKey`]（它已包含 hide 与名称兜底规则）。
  Site? _searchSiteByKey(String key) {
    final config = _config;
    return config == null ? null : _siteByKey(config, key);
  }

  /// 加载某站点的下一页结果（§14.1「分页搜索」）。
  ///
  /// 对齐上游 `CollectFragment.onLoadMore` + `SearchPageState`：
  /// - 只有当前批次还有效、且该站点已成功且有条目时才允许翻页；
  /// - 同一时刻只允许一个在途翻页（[SearchPagingState.begin] 拒绝重入）；
  /// - **内容与已见过的页重复即判定该站点耗尽**——上游站点常见「越界页码
  ///   返回末页内容」，只看 `page < pageCount` 会永远翻下去；
  /// - 上游未声明总页数（pageCount = 0）时允许一直翻，同样靠内容重复兜底。
  ///
  /// 返回：这次翻页是否**被接受并追加了条目**。UI 用它判断要不要在「相似度
  /// 过滤把整页都滤掉」时自动续翻下一页（上游 `shouldContinue`）。
  Future<bool> loadMoreSearch(
    String siteKey, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final outcome = _activeSearch;
    final service = _siteService;
    if (outcome == null || service == null || outcome.cancelled) return false;
    final entry = outcome.entryOf(siteKey);
    if (entry == null || !entry.succeeded || entry.itemCount == 0) return false;

    final requestedPage = _searchPaging.pageOf(siteKey) + 1;
    if (!_searchPaging.begin(siteKey, requestedPage)) return false;
    final site = _searchSiteByKey(siteKey);
    if (site == null) {
      _searchPaging.cancelPending();
      return false;
    }

    outcome.replaceEntry(entry.copyWith(loadingMore: true));
    notifyListeners();
    if (outcome.cancelled || !identical(_activeSearch, outcome)) return false;

    try {
      final value = await _searchRequest(
        service,
        site,
        keyword: outcome.keyword,
        page: requestedPage,
        timeout: timeout,
        // 分页请求**不得**参与 `(关键词, 站点)` 搜索缓存：那个键只代表第 1 页。
        // 走缓存时实测两个真缺陷：命中第 1 页缓存 → 内容指纹重复被误判
        // 「已耗尽」；以及把第 N 页结果写进第 1 页的缓存键。
        cache: false,
      );
      if (outcome.cancelled || !identical(_activeSearch, outcome)) {
        return false;
      }
      final completion = _searchPaging.complete(
        hasItems: value.value.list.isNotEmpty,
        pageCount: value.value.pageCount ?? 0,
        pageToken: SearchPagingState.pageTokenOf(value.value.list),
      );
      if (!completion.handled) return false;

      final current = outcome.entryOf(siteKey) ?? entry;
      final hasMore = _searchPaging.canLoadMore(siteKey);
      if (!completion.accepted) {
        // 空页 / 重复页：结果不变，只结束加载态（重复页已在 paging 里标耗尽）。
        outcome.replaceEntry(
          current.copyWith(loadingMore: false, hasMore: hasMore),
        );
        log.info(
          '搜索翻页未追加 site=$siteKey page=$requestedPage '
          'repeated=${completion.repeated} items=${value.value.list.length} '
          'hasMore=$hasMore',
          scope: 'search',
        );
        _notifyIfAlive();
        return false;
      }

      // 追加到已有条目（保留 classes/filters 等无关字段，只换 list 与页码）。
      final merged = (current.result ?? const SiteResult()).copyWith(
        list: [...?current.result?.list, ...value.value.list],
        page: completion.page,
        pageCount: value.value.pageCount ?? current.result?.pageCount,
      );
      outcome.replaceEntry(
        current.copyWith(
          result: merged,
          page: completion.page,
          pageCount: value.value.pageCount ?? current.pageCount,
          loadingMore: false,
          hasMore: hasMore,
        ),
      );
      log.info(
        '搜索翻页成功 site=$siteKey page=${completion.page}'
        '/${value.value.pageCount ?? "?"} added=${value.value.list.length} '
        'total=${merged.list.length} hasMore=$hasMore',
        scope: 'search',
      );
      _notifyIfAlive();
      return true;
    } catch (error) {
      if (outcome.cancelled || !identical(_activeSearch, outcome)) return false;
      _searchPaging.cancelPending();
      final failure = error is AppError
          ? error
          : AppError(AppErrorKind.unknown, '$error', cause: error);
      final current = outcome.entryOf(siteKey) ?? entry;
      outcome.replaceEntry(current.copyWith(loadingMore: false));
      log.warning(
        '搜索翻页失败 site=$siteKey page=$requestedPage ${failure.logLine}',
        scope: 'search',
      );
      _notifyIfAlive();
      return false;
    }
  }

  /// 某站点当前已加载的页数（UI 显示「第 N/M 页」）。
  int searchPageOf(String siteKey) => _searchPaging.pageOf(siteKey);

  // ---------------------------------------------------------------- 搜索辅助
  //
  // 联想 / 热门推荐 / 历史管理（对齐上游安卓默影视 SearchFragment）。UI 只经
  // 这里访问，不直接持 SearchSuggestService。

  /// 搜索联想：输入过程调用，结果含两个上游（爱奇艺 + 腾讯）合并去重。
  Future<List<SearchSuggestItem>> searchSuggest(String keyword) =>
      searchSuggestService.suggest(keyword);

  /// 热门推荐榜单（360kan 电影/剧集/综艺）。
  Future<List<SearchSuggestItem>> searchHotRank(HotRankCategory category) =>
      searchSuggestService.hotRank(category);

  /// 删除单条搜索历史（未 bootstrap 时安静跳过）。
  ///
  /// 先通知、后落盘（乐观更新）：内存是唯一真相，写盘只影响下次启动。
  /// 若把 `notifyListeners` 放在 `await` 之后，落盘一慢/一阻塞 UI 就不更新
  /// （widget 测试里直接表现为删除后 chip 仍在）。
  Future<void> removeSearchKeyword(String keyword) async {
    _searchHistory = [
      for (final item in _searchHistory)
        if (item != keyword) item,
    ];
    notifyListeners();
    final store = _uiPreferences;
    if (store != null) await store.removeSearchKeyword(keyword);
  }

  /// 清空搜索历史。同样先通知、后落盘。
  Future<void> clearSearchHistory() async {
    _searchHistory = const [];
    notifyListeners();
    final store = _uiPreferences;
    if (store != null) await store.clearSearchKeywords();
  }

  /// 设置搜索相似度阈值（0~100）。持久化失败不影响当前会话。
  Future<void> setSearchSimilarity(int value) async {
    final store = _uiPreferences;
    if (store == null) return;
    await store.rememberSearchSimilarity(value);
    notifyListeners();
  }

  /// 设置搜索并发线程数（夹到 1~100）。持久化失败不影响当前会话。
  ///
  /// 下一次搜索立即生效（[searchAll] 每次读 [searchThread]）；
  /// 已经在跑的批次不受影响——中途改并发会让「同一轮搜索」的节流语义变得
  /// 不可预测，也会让日志里那一行 concurrency 失去意义。
  Future<void> setSearchThread(int value) async {
    final store = _uiPreferences;
    if (store == null) return;
    await store.rememberSearchThread(value);
    notifyListeners();
  }

  /// 加载详情（§8.3）。
  ///
  /// 并发安全性（实测缺陷：详情页「点三次才进得去」、返回后点其他剧仍显示
  /// 上一部剧的信息）：
  /// - 每次调用取一个新的 [_detailRunId]，只有**最新**请求的结果才允许写回状态。
  ///   详情页在 `initState` 的 post-frame 回调里发请求，用户「返回 → 立刻点
  ///   另一部剧」时前一个请求往往还没回来（本机实测 3.9~7.1s），旧响应覆盖
  ///   新响应就会把 A 剧的线路渲染到 B 剧的页面上，点播即串剧；
  /// - 失败写入独立的 [detailError]，不污染浏览页共用的 [lastError]；
  /// - 新请求一律先清掉上一次的详情结果，避免「正在加载」时把上一个条目的
  ///   线路当成当前条目的线路显示出来。
  Future<void> loadDetail(
    Vod vod, {

    /// 用哪份配置的服务与站点取详情。都给 `null` 时用生效配置与当前选中站点
    /// （既有行为）。历史记录按「原来源配置」看详情时传
    /// [playbackContextFor] 里的这一对——**不**切换生效配置，也不改选中站点。
    SiteService? serviceOverride,
    Site? siteOverride,
  }) async {
    // 普通目录由独立目录路由加载，不能占用全局影片详情槽。
    if (vod.isFolder && !isBridgeFolderVodId(vod.vodId)) return;
    final service = serviceOverride ?? _siteService;
    final site = siteOverride ?? _selectedSite;
    // 合成条目不依赖站点：原站点或最后一份配置被删除后仍可加载元数据。
    final synthetic = vod.vodId.isEmpty;
    if (site == null && !synthetic) return;
    // 推送手填的剧名（Vod.extra）：压过推送源返回的片名，避免名字被网盘地址覆盖、
    // 进而让 TMDB 拿 URL 再匹配一次把已有匹配清掉。
    final pushNameOverride =
        (vod.extra[pushDisplayNameExtraKey] as String?)?.trim() ?? '';
    if (service == null && !synthetic) return;
    final runId = ++_detailRunId;
    final captureAllowed = !incognito;
    final activeSourceAtStart = activeSourceKey;
    final originalContext = _playbackContexts.values
        .where((context) => identical(context.service, service))
        .firstOrNull;
    final captureSource = identical(service, _siteService)
        ? activeSourceAtStart
        : originalContext?.sourceKey ?? '';
    // 先清状态，**再**等站点运行时：python/catVod 的运行时重刷可能要几秒，
    // 清空排在它后面会让新页面在这段时间里继续拿上一部剧的 `detailResult`
    // 渲染线路（phase 还是 ready）——那正是下面注释说要消灭的串剧。
    if (_disposed) return;
    _detailRequestVodId = vod.vodId;
    _selectedVod = vod;
    _detailResult = null;
    _detailError = null;
    _detailPhase = LoadPhase.loading;
    // 必须在这里推一次：等待运行时可能很长，不推的话监听方还停留在上一部剧的
    // 渲染上，「正在加载」根本显示不出来。
    notifyListeners();
    if (site != null) await _waitForPythonSite(site);
    if (_disposed || runId != _detailRunId) return;
    // TMDB 与站源详情**并行**启动：整条 TMDB 链（匹配→详情→季度→剧集→视频）以前排在
    // 站源详情之后（本机实测站源详情 3.9~7.1s），首屏必然是站源「原始模式」，用户要等
    // 两段时间相加才见到 TMDB 版本。元数据不依赖站源详情的结果，先跑起来。
    // 这里只能用列表条目自带的线路（folder 还没展开）；站源详情回来后会再用 effective
    // 的权威线路补一次映射，见下面的串行等待。
    final tmdb = this.tmdb;
    if (!tmdb.belongsTo(vod.vodId)) {
      // 保留的数据属于别的作品：先清掉。归属门是渲染侧的防线，这里清状态本身，
      // 保证新作品页连一帧旧标题/旧海报的机会都没有。
      tmdb.clear();
    }
    _tmdbRunId = runId;
    _pendingTmdbLoad = tmdb.loadForVod(
      vod,
      siteKey: site?.key ?? '',
      siteName: site?.name ?? '',
      configId: tmdbConfigId,
      lines: playLinesOf(vod),
      // `indexs == 1` 是用户拍板的导航源判据（`Site.indexs`）；合成条目另算，
      // 见 [_navSourceFor]。其余站点一律按普通站点加载，行为与以前逐字一致。
      navSource: _navSourceFor(site, vod),
      knownIdentity: _knownIdentityWithoutPlayback(site, vod),
    );
    _notifyIfAlive();
    if (synthetic) {
      // 只等并行的 TMDB 链落地：合成条目的剧集卡片、换源入口与播放入口全部来自它。
      final pending = _pendingTmdbLoad;
      _pendingTmdbLoad = null;
      if (pending != null) {
        try {
          await pending;
        } catch (error) {
          log.debug(
            '并行 TMDB 加载异常（已忽略）vod=${vod.vodId} error=$error',
            scope: 'tmdb',
          );
        }
      }
      if (runId != _detailRunId) return;
      _detailPhase = LoadPhase.ready;
      _notifyIfAlive();
      return;
    }
    if (service == null || site == null) return;
    try {
      // 已知 atvp_detail 桥接协议先取资源，再逐个取分享链分集。
      // 在服务层合并成普通详情后，一次交给标准线路 UI 和 TMDB。
      final outcome = vod.isFolder
          ? await service.folderDetail(
              site,
              vod,
              isCurrent: () => runId == _detailRunId,
            )
          : await service.detail(
              site,
              vod.vodId,
              // 详情请求自带 ids：上游漏填 vod_id/vod_name 时用它兜底，
              // 否则整条被丢弃、详情页报「列表条目缺少 vod_id/vod_name」。
              identity: VodIdentityHint(vodId: vod.vodId, vodName: vod.vodName),
            );
      if (runId != _detailRunId) {
        // 已被更新的请求（或已离开详情页）取代：结果直接丢弃，不写回状态。
        log.debug(
          '详情结果已作废 site=${site.key} vod=${vod.vodId} run=$runId',
          scope: 'site',
        );
        return;
      }
      final returnedDetail = outcome.value.list.firstOrNull;
      final effective = returnedDetail == null
          ? vod
          : mergeSourceDetailDisplay(
              detail: returnedDetail,
              listing: vod,
              nameOverride: pushNameOverride,
              // 推送身份固定用推送时的 id（见 merge 的注释）。
              idOverride: site.key == pushSiteKey ? vod.vodId : null,
            );
      _detailResult = returnedDetail == null
          ? outcome.value
          : outcome.value.copyWith(
              list: [effective, ...outcome.value.list.skip(1)],
            );
      _detailPhase = LoadPhase.ready;
      _detailError = outcome.warnings.isEmpty
          ? null
          : AppError(
              AppErrorKind.siteNetwork,
              '${outcome.warnings.length} 条线路加载失败，可刷新详情重试',
              detail: outcome.warnings.map((e) => e.message).join('；'),
              retryable: true,
            );
      for (final warning in outcome.warnings) {
        log.warning(
          '分集加载失败 site=${site.key} ${warning.logLine}',
          scope: 'site',
        );
      }
      _selectedVod = effective;
      if (!_disposed &&
          captureAllowed &&
          !incognito &&
          activeSourceAtStart == activeSourceKey &&
          captureSource.isNotEmpty &&
          returnedDetail != null &&
          effective.vodId == vod.vodId &&
          effective.vodName.trim().toLowerCase() ==
              vod.vodName.trim().toLowerCase() &&
          (identical(service, _siteService) ||
              identical(_playbackContexts[captureSource], originalContext))) {
        ViewingReportMetadata(
          database: _database,
        ).capture(sourceKey: captureSource, siteKey: site.key, vod: effective);
      }
      // 站源详情已经可用：先推一次通知，让线路/选集立刻渲染出来。后面的 TMDB 收尾
      // 即使要等，也不能把列表压在「加载中」里（那就等于把并行的收益又交回去了）。
      _notifyIfAlive();
      // 等并行启动的那一轮 TMDB 收尾，再用权威线路补一次映射。为什么要等而不是
      // 直接发第二次：同一作品换线路会清掉季度解析，两次调用叠在一起会互相覆盖。
      // 只在「句柄仍属于本次 run」时取走并等待：这段时间里用户可能已经进了另一部剧，
      // 那时字段里放的是**新 run** 的句柄，抢过来会既 wait 错对象又把它的收尾顺序
      // 打乱（新 run 会读不到句柄而跳过等待）。
      final pendingTmdbLoad = runId == _detailRunId ? _pendingTmdbLoad : null;
      if (runId == _detailRunId) _pendingTmdbLoad = null;
      if (pendingTmdbLoad != null) {
        try {
          await pendingTmdbLoad;
        } catch (error) {
          // 契约上它不抛（内部自行降级），但这里绝不能把已经成功的站源详情拖进
          // 失败分支：元数据只是锦上添花。
          log.debug(
            '并行 TMDB 加载异常（已忽略）vod=${vod.vodId} error=$error',
            scope: 'tmdb',
          );
        }
      }
      // 等待期间用户可能已经离开详情页或换了作品：runId 被取代就不再写回状态。
      if (runId != _detailRunId) return;
      // TMDB 与标准站点共用完整线路；元数据失败不阻塞选集和播放。
      // 这一次用 effective（folder 展开后的条目）的权威线路：季/集映射依赖它。它命中
      // 同一作品 → 保留内存数据复用，详情/视频不会再打一次网络。
      _tmdbRunId = runId;
      unawaited(
        _loadTmdbWithAi(
          effective,
          siteKey: site.key,
          siteName: site.name,
          configId: tmdbConfigId,
          lines: playLinesOf(effective),
          navSource: _navSourceFor(site, vod),
          knownIdentity:
              _knownIdentityWithoutPlayback(site, effective) ??
              _knownIdentityWithoutPlayback(site, vod),
        ),
      );
      log.info(
        '详情加载成功 site=${site.key} vod=${vod.vodId} '
        'folder=${vod.isFolder} entries=${outcome.value.list.length} '
        'tmdbVod=${effective.vodId} '
        'lines=${playLinesOf(effective).length} '
        'elapsed=${outcome.latency.inMilliseconds}ms',
        scope: 'site',
      );
    } catch (error) {
      if (runId != _detailRunId) return;
      final failure = error is AppError
          ? error
          : AppError(AppErrorKind.unknown, '$error', cause: error);
      _detailError = failure;
      _detailPhase = LoadPhase.failed;
      log.error(
        // 失败路径用多行诊断（动作 + 脱敏请求 + 堆栈）：只给分类文案时，
        // 用户和开发者都无法判断是哪一次请求、为什么失败（2026-10-20 反馈）。
        '详情加载失败 site=${site.key} vod=${vod.vodId} '
        'folder=${vod.isFolder} ${failure.logBlock}',
        scope: 'site',
      );
    }
    _notifyIfAlive();
  }

  /// 清空详情错误（详情页「重试」后的提示关闭）。
  void clearDetailError() {
    if (_detailError == null) return;
    _detailError = null;
    notifyListeners();
  }

  List<VodPlayLine> playLinesOf(Vod vod) => parseVodPlayLines(vod);

  /// 取「站点详情里的线路」+ 该线路该用哪个站点/vod_id 解析，只读：不写详情槽、
  /// 不跑 TMDB、不动选中站点。
  ///
  /// 历史续播先起播，再按需补线路：详情可能等几秒，不能阻塞播放主操作。
  ///
  /// 两条路径合流后返回同一个值类型：
  /// - 普通记录走 [SiteService.detail]，线路来自详情（无额外路由：换集仍用记录
  ///   自己的 `siteKey`/`vodId`）；
  /// - 目录记录（`atvp_detail:` 前缀，见 [isBridgeFolderVodId]）走
  ///   [SiteService.folderPlaybackLines]，因为拿目录 id 去 `ids=` 会被站源判为
  ///   业务错误，必须用 `t=<folder_id>` 展开，且每条合并线路要带回**条目自己的
  ///   **`vod_id`，否则换集会拿父目录 id 去问站点。
  Future<PlaybackLines?> playLinesForRecord({
    required String siteKey,
    required String vodId,
    String vodName = '',
    String sourceKey = '',
    bool Function()? isCurrent,
  }) async {
    try {
      final context = sourceKey.isNotEmpty
          ? playbackContextFor(sourceKey)
          : null;
      final service = sourceKey.isNotEmpty ? context?.service : _siteService;
      final site = sourceKey.isNotEmpty
          ? context?.siteByKey(siteKey)
          : siteByKey(siteKey);
      if (service == null || site == null) return null;
      await _waitForPythonSite(site);
      if (_disposed || _isStale(isCurrent)) return null;
      if (isBridgeFolderVodId(vodId)) {
        // 目录条目自己不是影片：只用它当作「展开哪个目录」的入口，标题仅供
        // 详情页合并显示，不参与解析。
        final expanded = await service.folderPlaybackLines(
          site,
          Vod(vodId: vodId, vodName: vodName),
          isCurrent: isCurrent,
        );
        if (_disposed || _isStale(isCurrent)) return null;
        return expanded;
      }
      final outcome = await service.detail(
        site,
        vodId,
        identity: VodIdentityHint(vodId: vodId, vodName: vodName),
      );
      if (_disposed || _isStale(isCurrent)) return null;
      final vod = outcome.value.list.firstOrNull;
      return vod == null ? null : PlaybackLines(lines: playLinesOf(vod));
    } on AppError catch (error) {
      // 取消不是失败：`_expandFolder` 用 siteCancelled 表达「用户已离开」，
      // 这条路径本来就该静默返回——但**必须留痕**，否则「没有选集按钮」既可能
      // 是取消也可能是失败，排查时无法区分。
      if (error.kind == AppErrorKind.siteCancelled) {
        log.debug('历史续播线路补齐已取消 vod=$vodId kind=siteCancelled', scope: 'player');
        return null;
      }
      _logPlayLinesFailure(vodId, error);
      return null;
    } catch (error) {
      _logPlayLinesFailure(vodId, error);
      return null;
    }
  }

  void _logPlayLinesFailure(String vodId, Object error) {
    // 异常文本可能带完整站点 URL/Header；只记错误分类，避免泄露配置凭据。
    log.warning(
      '历史续播线路补齐失败 vod=$vodId '
      'kind=${error is AppError ? error.kind.name : error.runtimeType}',
      scope: 'player',
    );
  }

  /// 解析播放请求（§10.2）。
  ///
  /// [siteOverride] 只对**这一次调用**生效：给了就用它，不给仍用当前选中站点
  /// （[selectedSite]）。「播放外部站点的线路」必须走这条路——[selectSite] 会
  /// 连带改顶栏站源、触发整页重建，而调用方只想要一次定向解析。
  Future<PlaybackDecision?> resolvePlayback({
    required String episodeTarget,
    String? flag,
    String? vodId,
    int? qualityIndex,
    bool Function()? isCurrent,
    Site? siteOverride,

    /// 本次播放手动指定的解析源名称（播放器解析源切换栏，仅本次生效）。
    String? preferredParseName,

    /// 用哪份配置的服务解析。`null` = 生效配置（既有行为）；原来源续播时传
    /// 那份配置自己的服务（见 [playbackContextFor]），这样请求头/解析规则/
    /// 运行时都来自它，不会串到当前配置。
    SiteService? serviceOverride,
  }) async {
    final service = serviceOverride ?? _siteService;
    // 本次解析用的站点：覆盖优先，之后所有分支（service/proxy/日志）共用它。
    final site = siteOverride ?? _selectedSite;
    if (service == null || site == null || _disposed || _isStale(isCurrent)) {
      return null;
    }
    final epoch = ++_proxyPlaybackEpoch;
    final previousOwner = _jvmProxySession;
    _jvmProxySession = null;
    unawaited(previousOwner?.close());
    bool current() =>
        !_disposed && epoch == _proxyPlaybackEpoch && !_isStale(isCurrent);
    await _waitForPythonSite(site);
    if (!current()) return null;
    SpiderProxySession? owner;
    try {
      final runtime = service.router.runtimeFor(site);
      if (runtime is SidecarRuntime) {
        owner = await runtime.prepareProxySession(service, isCurrent: current);
        if (!current()) {
          unawaited(owner?.close());
          return null;
        }
        _jvmProxySession = owner;
      }
      Future<SiteCallResult<PlaybackDecision>> resolve() =>
          service.resolvePlayback(
            site: site,
            episodeTarget: episodeTarget,
            flag: flag,
            vodId: vodId,
            qualityIndex: qualityIndex,
            parseFailover: parseFailoverSettings,
            preferredParseName: preferredParseName,
          );
      final outcome = runtime is SidecarRuntime
          ? await runtime.withProxySession(owner, resolve)
          : await resolve();
      // 过期响应（用户已切到别的画质/线路）不得改动全局播放状态：撤销旧 token 会
      // 连带把**新**会话作废，写 lastDecision 会把播放器指回旧画质。
      if (!current()) {
        unawaited(owner?.close());
        return null;
      }
      _revokeHttpProxySession();
      final decision = await proxyDecision(
        outcome.value,
        siteKey: site.key,
        isCurrent: current,
      );
      if (!current()) {
        unawaited(owner?.close());
        return null;
      }
      _lastDecision = decision;
      _lastError = null;
      log.info(
        '播放决策 ${SpiderProxySession.redact(decision.logLine)} site=${site.key} '
        'elapsed=${outcome.latency.inMilliseconds}ms',
        scope: 'playback',
      );
      _notifyIfAlive();
      return decision;
    } catch (error) {
      unawaited(owner?.close());
      if (identical(_jvmProxySession, owner)) _jvmProxySession = null;
      // 过期请求的失败同样不是「当前播放失败」，交给 UI 丢弃（不写 lastError）。
      if (!current()) return null;
      final failure = error is AppError
          ? error
          : AppError(AppErrorKind.unknown, '$error', cause: error);
      _lastError = failure;
      log.error(
        '播放决策失败 site=${site.key} ${SpiderProxySession.redact(failure.logLine)}',
        scope: 'playback',
      );
      _notifyIfAlive();
      rethrow;
    }
  }

  /// 调用方的时效检查（`null` = 无检查，保持既有行为）。
  static bool _isStale(bool Function()? isCurrent) =>
      isCurrent != null && !isCurrent();

  /// 用详情结果补齐旧历史记录缺失的海报，不改变进度和更新时间。
  void updateHistoryPoster(PlaybackHistory item, String posterUrl) {
    final database = _database;
    final poster = posterUrl.trim();
    if (database == null || poster.isEmpty || item.vodPic == poster) return;
    // 隐身模式不写历史，也不做历史回填。
    if (incognito) return;
    try {
      database.upsertHistory(
        siteKey: item.siteKey,
        vodId: item.vodId,
        vodName: item.vodName,
        vodPic: poster,
        flag: item.flag,
        episodeName: item.episodeName,
        episodeId: item.episodeId,
        positionMs: item.positionMs,
        durationMs: item.durationMs,
        completed: item.completed,
        updatedAt: item.updatedAt,
        // 补图必须写回**该行自己的源**：全局历史模式下列表里混着别的源，
        // 写当前源会造出一条重复记录。
        sourceKey: item.sourceKey,
      );
      notifyListeners();
      // 历史刚以这条记录写回库：走同一条「播放历史 → 已看」回写入口，
      // 免得补图成了唯一不触发已看回写的历史写入点。
      _syncFollowingProgressAfterHistory(
        siteKey: item.siteKey,
        vodId: item.vodId,
      );
    } catch (error) {
      log.warning('补齐历史海报失败：$error', scope: 'history');
    }
  }

  /// 把已定的 TMDB 身份回写到历史行（`storage.updateHistoryIdentity`）。
  ///
  /// 详情页匹配成功后，身份只落在 `tmdb_matches`；历史行的 `tmdb_id` 仍是 0。
  /// 首页与历史页读的都是历史行，于是出现「详情页明明匹配上了，首页却既没有
  /// 16:9 背景也没有简介」。这里补上回写（推送那条 `_applyPushMatch` 一直有），
  /// 让身份在整条读链路上都可见。
  ///
  /// 只改身份两列：进度、集名与更新时间保持不动，播放中调用也安全。
  void rememberHistoryIdentity({
    required String siteKey,
    required String vodId,
    required TmdbItem item,
    String sourceKey = '',
  }) {
    final database = _database;
    final identity = TmdbIdentity.of(item.mediaType, item.tmdbId);
    // 隐身模式不写历史（与 `updateHistoryPoster` 同一条闸门）。
    if (database == null || identity == null || incognito) return;
    try {
      final changed = database.updateHistoryIdentity(
        siteKey: siteKey,
        vodId: vodId,
        tmdbId: identity.tmdbId,
        mediaType: identity.mediaType.wireName,
        sourceKey: sourceKey,
      );
      if (changed > 0) notifyListeners();
    } catch (error) {
      log.warning('回写历史 TMDB 身份失败：$error', scope: 'history');
    }
  }

  /// 按 `source_key` 取那份配置（只读），**含本地导入源**。
  ///
  /// 历史补图与推荐种子要用记录**自己的**配置找站点：跨源记录挂在非生效配置上，
  /// 拿 [config] 会找不到站点，补图永远不执行。
  ///
  /// 本地爬虫源（`spiders/local/<key>/`）只并入 [effectiveConfig]，从不写进配置
  /// 记录（见 `state/local_site_sources.dart`）；照记录原样返回就是一份缺站的
  /// 配置，本地源播出来的历史一律解析不出站点（用户反馈「最近观看不支持本地
  /// 爬虫源」）。因此：
  /// - 生效源直接返回 [effectiveConfig]（与站点选择器、首页同一份）；
  /// - 其它源在记录配置上**追加**启用中的本地源，同 key 让位给记录自己的站点；
  /// - 空 `sourceKey`（迁移前老记录）按生效源解析。
  AppConfig? configForSourceKey(String sourceKey) {
    final key = sourceKey.trim();
    final active = effectiveConfig;
    if (key.isEmpty || key == activeSourceKey) return active;
    try {
      final config = _database?.configBySourceKey(key)?.config;
      if (config == null) return null;
      return _withLocalSources(config);
    } catch (_) {
      return null;
    }
  }

  /// 把启用中的本地导入源追加到一份配置上（只追加，不覆盖）。
  ///
  /// 与 [effectiveConfig] 的合并链同一优先级：同 key 时既有站点优先，本地条目
  /// 被拒绝并记入 conflicts，因此不会把别的配置的站点 api 换掉（那是串源）。
  AppConfig _withLocalSources(AppConfig config) {
    final local = localSourceSites;
    if (local.isEmpty) return config;
    return mergeLocalSourceSites(config, local).config;
  }

  /// 跨配置读 TMDB 缓存海报（只读，不暴露数据库）。
  String? cachedTmdbPosterUrl({
    required String siteKey,
    required String vodId,
  }) {
    try {
      return _database?.tmdbPosterUrlAcrossConfigs(
        siteKey: siteKey,
        vodId: vodId,
      );
    } catch (_) {
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // 原来源播放上下文（历史记录按「它所属的那份配置」解析，不切配置）
  // ---------------------------------------------------------------------------

  /// `sourceKey` → 该配置的播放上下文。按记录 id 与更新时间做签名，
  /// 配置被重新导入/删除后自动重建，不会拿旧站点去请求。
  final Map<String, PlaybackSourceContext> _playbackContexts = {};

  /// 建上下文时的「合并源」签名（见 [_mergedSourcesSignature]）。
  ///
  /// 本地导入源与 JSON 注入站点都**不改配置记录**，只看记录签名会把缺站的旧
  /// 上下文当成新鲜货；而**不能**改成「装配时清空整张表」：这张表同时是
  /// `SiteService → 所属 sourceKey` 的身份索引（[loadDetail] 用它给在途详情
  /// 补来源归属，见那里的 `captureSource`），清掉会让原来源的详情记不出源。
  final Map<String, String> _playbackContextSignatures = {};

  /// 本地导入源与注入站点的当前形态（`key@api`，排序后拼接）。
  ///
  /// 只在导入/启停/删除本地源、增删注入站点时变化——这正是要触发上下文重建的
  /// 全部时机，且与配置记录的更新时间无关。
  String get _mergedSourcesSignature {
    final parts = <String>[
      for (final site in localSourceSites) 'L:${site.key}@${site.api}',
      for (final entry in _injectedSites)
        'I:${entry.site.key}@${entry.site.api}',
    ]..sort();
    return parts.join('|');
  }

  /// 取一份**非生效配置**的播放上下文；配置不存在或无法解析时返回 `null`。
  ///
  /// 调用方（历史页）据 `null` 决定回退到「当前源匹配」的老路径，所以这里
  /// **不抛异常**，只把原因写进日志。
  ///
  /// 上下文里的 [SiteService] 与生效配置的服务**互不共享可变状态**：
  /// - 请求头/解析规则来自那份配置自己的 `AppConfig`；
  /// - 直连 spider 注册结果按那份配置重新 materialize；
  /// - 运行时走它自己的 [SpiderRouter]，因此同名站点 key 不会命中当前配置的
  ///   运行时（`_cache` 键含 api，且 headers 快照也来自本路由）。
  PlaybackSourceContext? playbackContextFor(String sourceKey) {
    final key = sourceKey.trim();
    if (key.isEmpty) return null;
    final database = _database;
    if (database == null) return null;
    final ConfigRecord record;
    try {
      final found = database.configBySourceKey(key);
      if (found == null) {
        _playbackContexts.remove(key);
        _playbackContextSignatures.remove(key);
        return null;
      }
      record = found;
    } catch (error) {
      log.warning('读取来源配置失败 source=$key error=$error', scope: 'history');
      return null;
    }
    // 记录签名 + 合并源签名：本地源导入/启停/删除不改记录，必须靠后者才失效。
    final signature =
        '${record.id}\n${record.updatedAt}\n$_mergedSourcesSignature';
    final cached = _playbackContexts[key];
    if (cached != null &&
        cached.record.id == record.id &&
        cached.record.updatedAt == record.updatedAt &&
        _playbackContextSignatures[key] == signature) {
      return cached;
    }
    // 合并本地导入源：历史行可能是本地爬虫源播出来的，而记录所属配置里没有它。
    // 生效源拿 [effectiveConfig]，其它源在记录配置上追加本地源（见
    // [configForSourceKey]）。
    final config = configForSourceKey(key) ?? record.config;
    if (config == null || config.sites.isEmpty) {
      _playbackContexts.remove(key);
      _playbackContextSignatures.remove(key);
      return null;
    }
    // 独立路由：生效配置的 `_router` 会被 `updateTransport` 改写
    // （换源/换出站代理时 `_attachSiteService` 直接覆盖 globalHeaders），
    // 复用它会让「原来源」的请求带上当前配置的头。
    final router = SpiderRouter(
      client: _httpClient,
      globalHeaders: config.headers,
      catHttpClient: _catHttpClient,
      registry: _spiderRegistry,
      supervisor: _supervisor,
      log: log,
      hostPath: _sidecarHostPath,
      jsHostPath: _jsSidecarHostPath,
      jvmHostPath: _jvmSidecarHostPath,
      cspBinding: _cspBinding.forConfig(config),
    );
    final context = PlaybackSourceContext(
      sourceKey: key,
      record: record,
      config: config,
      service: SiteService(
        appConfig: config,
        playbackBridge: _androidPlaybackBridge,
        router: router,
        database: _database,
      ),
    );
    _playbackContexts[key] = context;
    _playbackContextSignatures[key] = signature;
    // 直连 js/py 站点要按**这份配置**注册：生效配置那次注册的结果只对生效配置
    // 的站点有效，直接借过来会把同 key 的站点认错。
    unawaited(_registerDirectSpidersFor(config, router));
    return context;
  }

  /// 为任意配置补一次直连 spider 注册（失败只记日志，不阻塞调用）。
  Future<void> _registerDirectSpidersFor(
    AppConfig config,
    SpiderRouter router,
  ) async {
    try {
      final hasDirect = config.sites.any(
        (site) => directSpiderKind(site) != null,
      );
      if (!hasDirect) return;
      final result = await _materializeDirectSpiders(config);
      if (_disposed ||
          (identical(router, _router) && !identical(effectiveConfig, config))) {
        return;
      }
      router.setDirectSpiders(result);
    } catch (error) {
      log.warning('原来源配置的直连站源注册失败：$error', scope: 'spider');
    }
  }

  /// 某条历史所属配置里的站点（找不到返回 `null`，调用方据此回退）。
  Site? siteForSourceKey(String sourceKey, String siteKey) =>
      playbackContextFor(sourceKey)?.siteByKey(siteKey);

  /// 在**当前生效源**里按 key 找站点（含本地导入源与 JSON 注入站点）。
  ///
  /// 历史、收藏、追剧都只存 `site_key`，解析时必须查 [effectiveConfig]：本地爬虫
  /// 源只存在于那里，用 [config]（配置记录的原文）找必然落空，界面就会弹
  /// 「该记录所属站点已不在当前配置中」（用户反馈「最近观看不支持本地爬虫源」）。
  /// 隐藏站点同样算找到：隐藏只影响列表展示，不影响已有记录能不能续播。
  Site? siteInActiveSource(String siteKey) {
    final target = siteKey.trim();
    if (target.isEmpty) return null;
    final config = effectiveConfig;
    if (config == null) return null;
    for (final site in config.sites) {
      if (site.key == target) return site;
    }
    return null;
  }

  /// 用**记录所属配置**解析播放（原来源续播）。
  ///
  /// 与 [resolvePlayback] 的区别只有一处：站点服务换成那份配置自己的，
  /// 生效配置、选中站点、[activeSourceKey] 全程不动。返回 `null` 表示
  /// 「这份配置里没有这个站点 / 配置已不可用」，由调用方回退。
  Future<PlaybackDecision?> resolvePlaybackForSource({
    required String sourceKey,
    required String siteKey,
    required String episodeTarget,
    String? flag,
    String? vodId,
    int? qualityIndex,
    bool Function()? isCurrent,
    String? preferredParseName,
  }) async {
    final context = playbackContextFor(sourceKey);
    final site = context?.siteByKey(siteKey);
    if (context == null || site == null) return null;
    return resolvePlayback(
      episodeTarget: episodeTarget,
      flag: flag,
      vodId: vodId,
      qualityIndex: qualityIndex,
      isCurrent: isCurrent,
      preferredParseName: preferredParseName,
      siteOverride: site,
      serviceOverride: context.service,
    );
  }

  /// 记录播放进度（§15.2）。
  ///
  /// `siteKey` 显式传入而不依赖当前选中站点：命令行播放、历史恢复等场景下
  /// 并不存在“当前站点”，但仍应记录进度。
  ///
  /// [sourceKey] 同理：用**原来源配置**播放（历史记录来自别的配置）时必须把
  /// 进度写回那条记录自己的源，否则用户点开一条「其他来源」的记录续播一次，
  /// 进度就会分裂到当前源上（历史页从此同一集出现两条）。默认 `null` 保持
  /// 既有行为——写当前生效源。
  void recordProgress({
    required Vod vod,
    required String flag,
    required String episodeName,
    required String episodeId,
    required Duration position,
    required Duration duration,
    String? siteKey,
    String? sourceKey,
    // TMDB 身份（movie / tv 与数字 ID）。历史同名聚合优先用它分组，
    // 缺失时回退按片名。由播放器从 PlaybackRequest.tmdb 透传。
    int tmdbId = 0,
    String mediaType = '',
  }) {
    final database = _database;
    final effectiveSiteKey = siteKey ?? _selectedSite?.key ?? 'cli';
    if (database == null) return;
    // 隐身模式（Phase 9 P2-8）：不写任何播放历史（对齐安卓
    // `PlaybackProgressWriter` 的 `isIncognito` 闸门）。
    if (incognito) {
      if (!_incognitoNoticeLogged) {
        _incognitoNoticeLogged = true;
        log.info('隐身模式：本次会话不记录播放历史与搜索记录', scope: 'privacy');
      }
      return;
    }
    ViewingReportMetadata(database: database).capture(
      sourceKey: (sourceKey != null && sourceKey.trim().isNotEmpty)
          ? sourceKey.trim()
          : activeSourceKey,
      siteKey: effectiveSiteKey,
      vod: vod,
    );
    // 推送记录：海报与集名写**刮削后**的（对齐安卓 getInitialArtwork / 集数展示）。
    // 推送源返回的往往是网盘 logo 与 "[2.44G] S01E01" 这类原始标签。
    var historyPic = vod.vodPic;
    var historyEpisodeName = episodeName;
    if (effectiveSiteKey == pushSiteKey) {
      final match = pushMatchedItem(vodId: vod.vodId, title: vod.vodName);
      final poster = match?.posterUrl?.trim() ?? '';
      if (poster.isNotEmpty) historyPic = poster;
      final label = pushEpisodeLabel(episodeName);
      if (label.isNotEmpty) historyEpisodeName = label;
    }
    try {
      database.upsertHistory(
        siteKey: effectiveSiteKey,
        vodId: vod.vodId,
        vodName: vod.vodName,
        vodPic: historyPic,
        flag: flag,
        episodeName: historyEpisodeName,
        episodeId: episodeId,
        positionMs: position.inMilliseconds,
        durationMs: duration.inMilliseconds,
        // 写入永远带**具体源**：全局历史只是读视图，不能把新进度写成
        // "无源"的老记录（否则切回按源隔离时就看不见了）。
        // 用原来源配置播放时以调用方给的 sourceKey 为准（见参数注释）。
        sourceKey: (sourceKey != null && sourceKey.trim().isNotEmpty)
            ? sourceKey.trim()
            : activeSourceKey,
        // 作品身份：年份来自站点条目（可能为空），TMDB 身份来自播放请求。
        // 三者都「有值才生效」：upsert 的 ON CONFLICT 分支只在非空/非 0 时
        // 覆盖，因此同步来的无身份记录不会抹掉这里刚写好的身份。
        vodYear: vod.vodYear?.trim() ?? '',
        tmdbId: tmdbId,
        mediaType: mediaType,
      );
      // 写库成功：通知订阅者（详情页角标/首屏文案）。放在这里而不是方法末尾，
      // 是为了让「恢复上下文 / 追番回写」这些副作用不挡住界面刷新。
      if (!_disposed) progressRevision.value++;
      // 崩溃恢复上下文（P2-8）：与历史同源，但只存标识与进度。
      _recordRecoveryPlayback(
        siteKey: effectiveSiteKey,
        vod: vod,
        flag: flag,
        episodeName: episodeName,
        episodeId: episodeId,
        position: position,
        duration: duration,
      );
      // 播放历史已经落库：针对**这一部剧**回写已看集数（见方法注释）。
      _syncFollowingProgressAfterHistory(
        siteKey: effectiveSiteKey,
        vodId: vod.vodId,
      );
    } catch (error) {
      log.warning('写入播放进度失败：$error', scope: 'history');
    }
  }

  /// 播放历史写入后的单剧已看回写。
  ///
  /// 三个约束：
  /// - 只按 `siteKey + vodId` 查这一条追番，不做全量扫描：这个方法随每次进度
  ///   写入（播放中每 5 秒一次）触发，全量扫库会把播放写盘拖慢；
  /// - 排到下一次事件循环执行，播放/写库主流程不等它；
  /// - 任何失败都只是「不推进」，异常在服务内被吞掉，不影响播放。
  void _syncFollowingProgressAfterHistory({
    required String siteKey,
    required String vodId,
  }) {
    if (_disposed || _database == null) return;
    unawaited(
      Future<void>(() {
        if (_disposed) return;
        try {
          final service = _followingProgress;
          if (service == null) return;
          final result = service.syncVod(siteKey: siteKey, vodId: vodId);
          if (result.updated == 0 || _disposed) return;
          log.info(
            '播放历史回写已看：updated=${result.updated} site=$siteKey',
            scope: 'following',
          );
          // 追番页/侧栏徽标都挂在 AppState 的监听上：回写后通知一次，
          // 页面重建时就从库里读到新的「已看/未看」。
          notifyListeners();
        } catch (error) {
          log.warning('播放历史回写已看失败：$error', scope: 'following');
        }
      }),
    );
  }

  /// 查询某剧集的历史记录（用于进入播放器时自动续播，§15.2）。
  ///
  /// [episodeName] 可选：同步来的记录 `episode_id` 存的是安卓哈希
  /// （`episodeUrl` 的 SHA-256），用站点入口 URL 查不到，需要集名兜底。
  /// 详见 `AppDatabase.findHistory` 的三级匹配说明。
  ///
  /// [sourceKey] 默认按当前历史范围过滤；用原来源配置看一部作品的详情时传
  /// 那条记录自己的 `sourceKey`，否则会去查当前源的行、结果永远是「没有历史」
  /// （详情页于是从 0 开始，用户点的「继续观看」被丢掉）。
  PlaybackHistory? findHistory({
    required String siteKey,
    required String vodId,
    String? flag,
    String? episodeId,
    String? episodeName,
    String? sourceKey,
  }) {
    final database = _database;
    if (database == null) return null;
    try {
      return database.findHistory(
        siteKey: siteKey,
        vodId: vodId,
        flag: flag,
        episodeId: episodeId,
        episodeName: episodeName,
        sourceKey: sourceKey ?? historySourceFilter,
      );
    } catch (error) {
      log.warning('读取播放进度失败:$error', scope: 'history');
      return null;
    }
  }

  /// 同一个配置里、其它爬虫源的历史候选（详情页跨爬虫源进度用）。
  ///
  /// 与 [findHistory] 的分工：那条回答「本站点这一集播到哪了」，这条回答
  /// 「同一部作品在别的爬虫源上有没有记录」。两者都只认**当前播放源**
  /// （sourceKey），跨配置的记录归历史页的「用原来源打开」。
  ///
  /// TMDB 身份匹配跟随 ui.historyAggregation：逐集模式（none）下不按身份查、
  /// 只按片名查（对齐安卓 isHistoryAggregationEffective）；title 模式同理——
  /// 用户选了「只按片名」，就不该被 TMDB 身份合并。
  List<PlaybackHistory> findHistoryCandidatesAcrossSites({
    required String siteKey,
    required String vodId,
    required String vodName,
    int tmdbId = 0,
    String mediaType = '',
    String? sourceKey,
  }) {
    final database = _database;
    if (database == null) return const [];
    final key = (sourceKey ?? activeSourceKey).trim();
    // 空串 = 没有具体播放源。宁可不标，不可猜源（docs/phase5/design/05 §6.1）。
    if (key.isEmpty) return const [];
    final usesTmdb = UiHistoryAggregation.usesTmdb(historyAggregation);
    try {
      return database.findHistoryCandidatesAcrossSites(
        sourceKey: key,
        siteKey: siteKey,
        vodId: vodId,
        vodName: vodName,
        tmdbId: usesTmdb ? tmdbId : 0,
        mediaType: usesTmdb ? mediaType : '',
      );
    } catch (error) {
      log.warning('读取跨站点历史候选失败:$error', scope: 'history');
      return const [];
    }
  }

  /// 「继续播放」位置（§15.2）。
  ///
  /// 已播完或位置过短时返回 null：从零开始比从尾部几秒开始体验更好。
  ///
  /// [episodeName] 参与集消歧（见 [findHistory]）：同步来的记录靠它才能对到集。
  Duration? resumePositionFor({
    required String siteKey,
    required String vodId,
    String? flag,
    String? episodeId,
    String? episodeName,
    String? sourceKey,
  }) {
    final record = findHistory(
      siteKey: siteKey,
      vodId: vodId,
      flag: flag,
      episodeId: episodeId,
      episodeName: episodeName,
      sourceKey: sourceKey,
    );
    if (record == null || record.completed) return null;
    if (record.positionMs < resumeThreshold.inMilliseconds) return null;
    if (record.durationMs > 0 && record.positionMs > record.durationMs - 5000) {
      // 距离结尾不足 5 秒视为已看完。
      return null;
    }
    return Duration(milliseconds: record.positionMs);
  }

  /// 续播位置下限：小于 5 秒不恢复，避免“刚打开就跳”。
  static const Duration resumeThreshold = Duration(seconds: 5);

  // -------------------------------------------------------------------------
  // 推送接收（局域网推送 + 本机「推送…」输入）
  // -------------------------------------------------------------------------
  //
  // 两条入口收同一个概念：安卓/手机经局域网推地址，以及 PC 上直接粘贴地址或
  // 选本地文件。落地方式相同：解析 → 合成播放请求 → 壳层起播 → 异步匹配剧名。

  /// 待播放的推送请求。
  ///
  /// 为什么不在状态层直接导航：状态层不碰 `Navigator`（与崩溃恢复
  /// `pendingRecovery` 同一口径）。请求先落成数据，由 `AppShell` 投影成路由。
  PlaybackRequest? _pendingPush;

  /// 最近一次推送的原始解析结果：落点要区分"剧名是显式填的"还是地址兜底。
  PushParsed? _pendingPushParsed;

  PlaybackRequest? get pendingPush => _pendingPush;

  PushParsed? get pendingPushParsed => _pendingPushParsed;

  void clearPendingPush() {
    if (_pendingPush == null && _pendingPushParsed == null) return;
    _pendingPush = null;
    _pendingPushParsed = null;
    notifyListeners();
  }

  /// 站点在当前环境是否跑得起来（不联网，由 SpiderRouter 判定）。
  SiteAvailability siteAvailabilityOf(Site site) => _router.classifySite(site);

  /// 选一个「推送源」：先当前配置，再其它已保存配置（最近更新的优先）。
  ///
  /// 为什么放宽到跨配置：安卓只认当前配置里 key 恰为 push_agent 的站点，而用户的
  /// 推送爬虫源经常配在别的配置里（实测："唐三的猫源" → nodejs_push）。选源时
  /// **可用的优先**（安卓 JAR 站点在 PC 上不可用），同可用性下当前配置优先。
  /// 返回 null 表示哪里都没有推送源，只能走合成详情。
  PushSourceCandidate? pushSourceCandidate() {
    final candidates = <PushSourceCandidate>[];
    void collect(AppConfig? config, PlaybackSourceContext? context) {
      if (config == null || context == null) return;
      final site = pushSiteInConfig(config);
      if (site == null) return;
      var available = false;
      try {
        available = siteAvailabilityOf(site).available;
      } catch (error) {
        log.debug('推送源可用性判定失败：$error', scope: 'site');
      }
      candidates.add(
        PushSourceCandidate(
          site: site,
          context: context,
          active: identical(config, effectiveConfig),
          available: available,
        ),
      );
    }

    final activeConfig = effectiveConfig;
    final record = _activeRecord;
    final service = _siteService;
    if (activeConfig != null && record != null && service != null) {
      collect(
        activeConfig,
        PlaybackSourceContext(
          sourceKey: activeSourceKey,
          record: record,
          config: activeConfig,
          service: service,
        ),
      );
    }
    final records = [..._configs]
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    for (final other in records) {
      if (other.id == record?.id) continue;
      final context = playbackContextFor(other.sourceKey);
      collect(context?.config, context);
    }
    if (candidates.isEmpty) return null;
    candidates.sort((a, b) {
      if (a.available != b.available) return a.available ? -1 : 1;
      if (a.active != b.active) return a.active ? -1 : 1;
      return 0;
    });
    return candidates.first;
  }

  /// 推送用的**合成站点上下文**（安卓 `SiteApi.pushDetail` 的 PC 对应物）。
  ///
  /// 配置里没有「推送」源时用它：把推送包成 `push_agent` 站点上的一条普通 vod，
  /// 详情/播放都交给 [PushSiteService]。返回 `null` 表示连配置都没有——那种情况
  /// 只能落到极简兜底页。
  PlaybackSourceContext? pushSiteContext(PushParsed parsed) {
    final base = effectiveConfig;
    final record = activeRecord;
    if (base == null || record == null) return null;
    final site = Site(
      key: pushSiteKey,
      name: pushSourceName,
      type: 1,
      api: 'push://agent',
    );
    final config = base.copyWith(
      sites: [...base.sites.where((item) => item.key != pushSiteKey), site],
    );
    return PlaybackSourceContext(
      sourceKey: activeSourceKey,
      record: record,
      config: config,
      service: PushSiteService(
        appConfig: config,
        router: _router,
        database: _database,
        parsed: parsed,
      ),
    );
  }

  /// 本机「推送…」（地址 + 剧名）：与局域网推送走同一条链路。
  Future<bool> submitPush({required String url, String title = ''}) =>
      _acceptPush(
        parsePushFields(url: url, title: title),
        from: '本机输入',
      );

  /// 局域网推送到达（`SyncStateHost` 的宿主能力，由 `SyncState` 调用）。
  @override
  Future<bool> onPushReceived(PushParsed parsed) =>
      _acceptPush(parsed, from: '局域网推送');

  /// 推送落地：本地路径走既有本地播放，地址走推送合成站点，随后异步匹配剧名。
  Future<bool> _acceptPush(PushParsed parsed, {required String from}) async {
    final raw = parsed.url.trim();
    if (raw.isEmpty) {
      _lastError = AppError(AppErrorKind.playbackUrlMissing, '推送需要一个播放地址');
      notifyListeners();
      return false;
    }
    var localPath = '';
    if (looksLikeLocalMediaPath(raw)) {
      final path = raw.toLowerCase().startsWith('file://')
          ? (Uri.tryParse(raw)?.toFilePath() ?? raw)
          : raw;
      if (!File(path).existsSync()) {
        _lastError = AppError(AppErrorKind.playbackUrlMissing, '本地文件不存在：$path');
        notifyListeners();
        return false;
      }
      localPath = path;
    }
    final request = pushPlaybackRequest(
      parsed: PushParsed(url: raw, title: parsed.title),
      localPath: localPath.isEmpty ? null : localPath,
    );
    _pendingPush = request;
    _pendingPushParsed = parsed;
    _lastError = null;
    _notice = '收到（$from）：${request.title}';
    // 日志不写地址（可能带签名参数）：只记"本地/远程"与是否有剧名。
    log.info(
      '推送已接收（$from）：本地=${localPath.isNotEmpty} '
      '剧名=${parsed.hasExplicitTitle ? '有' : '无'}',
      scope: 'player',
    );
    notifyListeners();
    // 只有用户手填了剧名才做这一发预匹配：没填时用推送源解析出的名字，交给
    // 常规 TMDB 管线（含标题清理与推送标题守卫），不要拿地址/文件名去搜。
    if (parsed.hasExplicitTitle) unawaited(_autoMatchPush(request));
    return true;
  }

  /// 推送剧名的一次自动匹配（`01` §5.4 推送标题守卫）。
  ///
  /// 只有「显式剧名 + 守卫放行 + TMDB 已配置」才发请求，否则**零请求**：拿地址
  /// 或文件名去搜 TMDB 是纯浪费，还会把不该有的结论写进匹配表。
  Future<void> _autoMatchPush(PlaybackRequest request) async {
    if (_database == null || request.siteKey != pushSiteKey) return;
    final title = request.vodName.trim();
    if (!tmdbConfig.isReady || !shouldAutoMatchPushTitle(title)) return;
    try {
      final outcome = await _ensureTmdbIdentityService().match(
        TmdbMatchRequest(
          siteKey: pushSiteKey,
          vodId: request.vodId,
          sourceTitle: title,
          vodName: title,
          siteName: pushSourceName,
        ),
      );
      final item = outcome.item;
      if (item == null) {
        log.info('推送剧名未匹配到元数据', scope: 'tmdb');
        return;
      }
      _applyPushMatch(vodId: request.vodId, item: item);
      _notice = '已匹配元数据：${item.title}';
      log.info(
        '推送剧名已匹配 tmdbId=${item.tmdbId} type=${item.mediaType.name}',
        scope: 'tmdb',
      );
      notifyListeners();
    } catch (error) {
      log.warning('推送剧名匹配失败：$error', scope: 'tmdb');
    }
  }

  /// 手动修正推送的元数据（历史页点推送记录时用，`04` §5.1 的入口之一）。
  Future<void> manualMatchPush({
    required String vodId,
    required String title,
    required TmdbItem item,
  }) async {
    if (_database == null) return;
    try {
      final outcome = await _ensureTmdbIdentityService().matchManual(
        request: TmdbMatchRequest(
          siteKey: pushSiteKey,
          vodId: vodId,
          sourceTitle: title,
          vodName: title,
          siteName: pushSourceName,
        ),
        item: item,
      );
      final matched = outcome.item ?? item;
      _applyPushMatch(vodId: vodId, item: matched);
      _notice = '已匹配元数据：${matched.title}';
      log.info('推送手动匹配已写入 tmdbId=${matched.tmdbId}', scope: 'tmdb');
      notifyListeners();
    } catch (error) {
      log.warning('推送手动匹配失败：$error', scope: 'tmdb');
    }
  }

  /// 推送内容当前的元数据匹配结论（只读，供推送详情页展示）。
  ///
  /// 与 [cachedTmdbPosterUrl] 分开：那张图只服务历史卡片补图，详情页还要标题、
  /// 副标题与简介。没有匹配记录时返回 `null`（详情页就用推送时的剧名）。
  TmdbItem? pushMatchedItem({required String vodId, required String title}) {
    final database = _database;
    final id = vodId.trim();
    if (database == null || id.isEmpty) return null;
    // 旧记录/站源改写会让 id 少掉 scheme，片名也可能带后缀（"罪蓝之路 4K内嵌中字"）：
    // 两种变体都试一次，避免"明明匹配过却查不到"。
    final ids = <String>{id};
    if (!id.contains('://')) ids.add('https://$id');
    final titles = <String>{title.trim()};
    final head = title.trim().split(RegExp(r'\s+')).first;
    if (head.isNotEmpty) titles.add(head);
    try {
      final store = DatabaseTmdbMatchStore(
        database: database,
        configId: tmdbConfigId,
      );
      for (final candidateId in ids) {
        for (final candidateTitle in titles) {
          final record = store.find(
            siteKey: pushSiteKey,
            vodId: candidateId,
            sourceTitle: candidateTitle,
          );
          if (record != null) return record.toItem();
        }
      }
      return null;
    } catch (error) {
      log.warning('读取推送匹配结论失败：$error', scope: 'tmdb');
      return null;
    }
  }

  /// 把匹配结论落进历史行（海报 + 身份）。
  ///
  /// 历史页另有一层懒补图（`HistoryPosterRepair` 读 TMDB 缓存），这里写是为了
  /// "匹配完立刻看到"，而不是等用户打开历史页。行还不存在（刚起播，进度尚未
  /// 落库）时什么都不做——下一次进度写入会带上剧名，海报由懒补图接上。
  void _applyPushMatch({required String vodId, required TmdbItem item}) {
    final row = findHistory(siteKey: pushSiteKey, vodId: vodId);
    if (row == null) return;
    final poster = (item.posterUrl ?? '').trim();
    try {
      _database?.upsertHistory(
        siteKey: row.siteKey,
        vodId: row.vodId,
        vodName: row.vodName,
        vodPic: poster.isEmpty ? row.vodPic : poster,
        flag: row.flag,
        episodeName: row.episodeName,
        episodeId: row.episodeId,
        positionMs: row.positionMs,
        durationMs: row.durationMs,
        completed: row.completed,
        updatedAt: row.updatedAt,
        sourceKey: row.sourceKey,
        tmdbId: item.tmdbId,
        mediaType: item.mediaType.name,
      );
    } catch (error) {
      log.warning('推送匹配结论写回历史失败：$error', scope: 'history');
    }
  }

  // -------------------------------------------------------------------------
  // Phase 5 · 安卓同步的宿主能力（`SyncStateHost`，`design/02` §2）
  // -------------------------------------------------------------------------
  //
  // 这五个成员是“状态层 ↔ 同步层”的唯一接口：同步层不直接改 `AppState`，
  // 而 `app_state.dart` 不 import `sync_state.dart` 的具体实现细节以外的网络层。

  @override
  AppDatabase? get syncDatabase => _database;

  @override
  List<SyncHistoryItem> syncHistoryItems({int limit = 2000}) => [
    // 推送落到**某一个**源，所以只送当前源的历史；全局历史只是读视图。
    for (final row in recentHistory(limit: limit, sourceKey: activeSourceKey))
      SyncHistoryItem.fromLocal(
        siteKey: row.siteKey,
        vodId: row.vodId,
        vodName: row.vodName,
        vodPic: row.vodPic,
        flag: row.flag,
        episodeName: row.episodeName,
        episodeId: row.episodeId,
        positionMs: row.positionMs,
        durationMs: row.durationMs,
        updatedAt: row.updatedAt,
      ),
  ];

  @override
  List<SyncFavoriteItem> syncFavoriteItems({int limit = 2000}) => [
    for (final row in favorites().take(limit))
      SyncFavoriteItem(
        kind: row.kind,
        siteKey: row.siteKey,
        targetId: row.targetId,
        title: row.title,
        subtitle: row.subtitle,
        updatedAt: row.updatedAt,
      ),
  ];

  /// 保存安卓桥接配置为**新记录**，且 `makeActive: false`
  /// （`design/00` Q10：导入**不**覆盖/切换当前配置）。
  @override
  Future<int?> saveBridgeConfig({
    required String name,
    required String origin,
    required AppConfig config,
    required List<String> diagnostics,
    String deviceUuid = '',
    String interfaceKey = '',
    String configUrl = '',
  }) async {
    final database = _database;
    if (database == null) return null;
    try {
      // 同一台设备上的多个源 origin 全是设备网关地址，按 origin 去重会把第二个源
      // 覆盖成第一个；因此桥接记录一律带 sourceKey，去重改按 source_key。
      final sourceKey = BridgeSourceKey.of(
        deviceUuid: deviceUuid,
        interfaceKey: interfaceKey,
      );
      final id = database.saveConfig(
        name: name,
        origin: origin,
        json: config.toJson(),
        contentType: 'android-t4-gateway',
        siteCount: config.sites.length,
        liveCount: config.lives.length,
        makeActive: false,
        sourceKey: sourceKey,
        bridgeDevice: deviceUuid,
        bridgeInterfaceKey: interfaceKey,
        bridgeConfigUrl: configUrl,
      );
      database.saveConfigSites(id, config.sites);
      _configs = database.listConfigs();
      _importDiagnosticsSummary = diagnostics.isEmpty
          ? null
          : diagnostics.join('；');
      log.info(
        '安卓桥接配置已存为记录 #$id（未切换当前配置）'
        ' sites=${config.sites.length} origin=${redactUrl(origin)}',
        scope: 'bridge',
      );
      notifyListeners();
      return id;
    } catch (error) {
      log.error('保存安卓桥接配置失败：$error', scope: 'bridge');
      return null;
    }
  }

  /// 与安卓当前配置对齐的配置 JSON（`design/02` §3.5）。
  ///
  /// **保守策略**：只有当当前生效配置的 `origin` 就是某台**已授权**安卓设备的
  /// 地址时（即用户是通过安卓 T4 网关导入的站点）才返回它；否则返回 `null`。
  ///
  /// 为什么保守：`config.url` 为空或不匹配时，安卓会
  /// `if (config.getUrl() == null) return;` **静默忽略**整批记录却仍返回 200；
  /// 而不匹配时还会 `VodConfig.load(config)` **切换安卓当前配置**。
  /// 宁可不发并把原因告诉用户，也不能发一个可能改掉安卓配置的值
  /// （对齐 P3 + P5）。
  @override
  String? syncConfigJson() {
    final record = _activeRecord;
    if (record == null) return null;
    final origin = record.origin.trim();
    if (!origin.startsWith('http://') && !origin.startsWith('https://')) {
      return null;
    }
    final uri = Uri.tryParse(origin);
    if (uri == null || uri.host.isEmpty) return null;
    if (!syncState.isPeerAuthorized(uri.host)) return null;
    // 桥接记录的 origin 是**设备网关地址**，绝不能当 config.url 发给安卓——
    // 老协议下安卓会 Config.find(url) 查不到就 insert 一行，凭空多出"桥接源"，
    // 还会顺带 VodConfig.load 切走当前配置。改为只发该源的 interfaceKey，
    // 安卓据此直接写目标源的 cid（见 dev5 Action.syncHistory）。
    final configKey = record.bridgeInterfaceKey.trim();
    if (configKey.isNotEmpty) {
      // 桥接源：只认源标识，url 留该源自己的订阅地址（可能为空，安卓不读它）。
      return jsonEncode({
        'id': record.id,
        'type': 0,
        'name': record.name,
        'configKey': configKey,
        'url': record.bridgeConfigUrl.trim(),
      });
    }
    // 本地导入的配置：origin 本身就是该源自己的订阅地址，沿用老协议。
    return jsonEncode({
      'id': record.id,
      'type': 0,
      'name': record.name,
      'url': origin,
    });
  }

  /// 应用对端推来的设置（白名单子集，`design/02` §3.6；Phase 7 `design/01` §5 扩展）。
  ///
  /// Phase 7 后白名单含 AI 段四个键。其中三个（`tmdb_model` /
  /// `ai_title_extraction` / `ai_ad_detection`）是「安卓有、PC 无」——
  /// 它们不在这里落库，只保留在 `settings.raw` 里供回推（`design/01` §5.2）。
  ///
  /// 凭据类字段若对端未提供，**保留本机原值**——把能用的凭据清空比不同步更糟。
  Future<Map<String, Object?>> exportSyncedSettings({
    required bool allowSensitive,
  }) async {
    final raw = _uiPreferences?.androidAiRaw ?? const <String, Object?>{};
    final currentTmdb = tmdbUserConfig;
    return {
      // 先铺已授权 raw 的**全部**键（含 PC 尚不认识的顶层设置键），
      // 只排除被下面本机当前值覆盖的键；敏感项仍受设置同步闸门约束。
      for (final entry in raw.entries)
        if (entry.key != 'tmdb_enabled' &&
            entry.key != 'tmdb_config' &&
            entry.key != 'ai_config' &&
            entry.key != 'ai_user_data' &&
            entry.key != 'ai_title_extraction' &&
            entry.key != 'ai_ad_detection' &&
            (allowSensitive || !pcSensitiveSettingsKeys.contains(entry.key)))
          entry.key: entry.value,
      // 本机当前值覆盖历史接收值：回推的是「现在生效的设置」。
      'tmdb_enabled': currentTmdb.enabled,
      if (allowSensitive) 'tmdb_config': jsonEncode(currentTmdb.toJson()),
      'ai_title_extraction': aiTitleExtractionEnabled,
      'ai_ad_detection': aiAdDetectionEnabled,
      if (allowSensitive) 'ai_config': jsonEncode(aiConfig.toJson()),
      if (allowSensitive) 'ai_user_data': await exportAiUserFiles(paths),
    };
  }

  @override
  Future<void> applySyncedSettings(SyncSettings settings) async {
    if (settings.isEmpty) return;
    var next = tmdbUserConfig;

    final enabled = settings.values['tmdb_enabled'];
    if (enabled != null) next = next.copyWith(enabled: asFlag(enabled));

    // `tmdb_config` 的值是 **JSON 字符串**（`design/00` §3.1 契约 11），
    // 必须解字符串再映射，不能当对象读。
    final raw = settings.values['tmdb_config'];
    if (raw != null) {
      final decoded = decodeAndroidJsonSetting(raw);
      if (decoded != null) {
        final incoming = TmdbConfig.fromMap(decoded);
        next = incoming.copyWith(
          apiKey: incoming.apiKey.isEmpty ? next.apiKey : incoming.apiKey,
          accessToken: incoming.accessToken.isEmpty
              ? next.accessToken
              : incoming.accessToken,
        );
      }
    }

    await saveTmdbConfig(next);

    // 已授权的全量 prefers（含 PC 未知的顶层键）都要留存，回推时原样带回。
    final retained = {...settings.all};
    await _uiPreferences?.rememberAiIntegrationSettings(retained);
    final titleFlag = settings.values['ai_title_extraction'];
    if (titleFlag != null) await setAiTitleExtractionEnabled(asFlag(titleFlag));
    final adFlag = settings.values['ai_ad_detection'];
    if (adFlag != null) await setAiAdDetectionEnabled(asFlag(adFlag));
    final aiRaw = decodeAndroidJsonSetting(settings.values['ai_config']);
    if (aiRaw != null) {
      final local = aiConfig;
      final incoming = AiConfig.fromJson({...local.toJson(), ...aiRaw});
      await saveAiConfig(
        incoming.copyWith(
          apiKey: incoming.apiKey.isEmpty ? local.apiKey : incoming.apiKey,
        ),
      );
    }
    final userData = settings.values['ai_user_data'];
    if (userData != null) {
      try {
        await importAiUserFiles(
          paths,
          userData is String ? userData : jsonEncode(userData),
        );
        _aiIntegration = null;
        clearAiAdApplication();
      } catch (error) {
        log.warning('AI用户数据导入失败：$error', scope: 'sync');
        rethrow;
      }
    }

    log.info(
      '已应用中端同步设置：keys=${settings.values.keys.join(',')} '
      'unsupported=${settings.unsupportedKeys.join(',')} '
      'sensitive=${settings.sensitiveIncluded}',
      scope: 'sync',
    );
  }

  /// 实时同步已把新记录落库（`design/01` §4.2）：刷新内存历史视图。
  ///
  /// 历史页是每次 build 直接读 `recentHistory()` 的，因此这里只需要
  /// 通知监听者重建；不通知的后果是「库里有了但页面上一直看不到」。
  @override
  void notifySyncedDataChanged() {
    notifyListeners();
  }

  /// 本轮实时轮询要请求的 `siteKey`（`design/01` §6.1）。
  ///
  /// 取舍交给纯逻辑 `selectPollSites`（已有 L1 用例锁定）：
  /// - `pollAllSites` → 返回当前配置的**全部**站点；
  /// - 否则 → 「最近播过的站点」优先，不足时用配置里的站点补齐。
  ///
  /// **为什么不能只返回配置里的前 20 个**：历史记录只会在「最近看过」的
  /// 站点上产生，轮询冷站点等于白发请求；而用户可能配了几百个站点。
  @override
  List<String> syncSiteKeys({required bool all, int limit = 20}) {
    final known = [
      for (final site in _config?.sites ?? const <Site>[]) site.key,
    ];
    final recentlyActive = <String>[];
    // 轮询要的是"这台设备上最近播过的站点"，与历史可见范围无关 → 显式不过滤。
    for (final row in recentHistory(limit: 200, sourceKey: '')) {
      if (!recentlyActive.contains(row.siteKey)) {
        recentlyActive.add(row.siteKey);
      }
    }
    final selected = selectPollSites(
      known: known,
      pollAllSites: all,
      recentlyActive: recentlyActive,
      limit: limit,
    );
    // `null` = 轮询全部（`pollAllSites` 的语义由 `selectPollSites` 表达）。
    return selected ?? known;
  }

  /// 按 [historyScope] 过滤的播放历史（默认只看当前源）。
  ///
  /// [sourceKey] 传空串表示"不过滤"，用于明确要看全部源的场景
  /// （例如给安卓轮询站点 key 时判断"最近播过哪些站点"）。
  List<PlaybackHistory> recentHistory({int limit = 100, String? sourceKey}) {
    final database = _database;
    if (database == null) return const [];
    try {
      return database.recentHistory(
        limit: limit,
        sourceKey: sourceKey ?? historySourceFilter,
      );
    } catch (error) {
      log.warning('读取播放历史失败：$error', scope: 'history');
      return const [];
    }
  }

  /// 历史行数；[sourceKey] 传空串表示"数全部源"。
  ///
  /// 与 [recentHistory] 的区别只在用途：这里要回答的是"到底有没有历史"，
  /// 不是"要显示哪些历史"。空态需要后者——按源视图为空时，页面得知道
  /// 全部来源里还剩多少条，才说得清"不是没记录，是这些记录归属不到源"。
  int historyCount({String? sourceKey}) {
    final database = _database;
    if (database == null) return 0;
    try {
      return database.historyCount(sourceKey: sourceKey ?? historySourceFilter);
    } catch (error) {
      log.warning('统计播放历史失败：$error', scope: 'history');
      return 0;
    }
  }

  /// 归属不到任何源的历史行数（迁移前老记录 + 判不出来源的同步记录）。
  int unclaimedHistoryCount() {
    final database = _database;
    if (database == null) return 0;
    try {
      return database.unclaimedHistoryCount();
    } catch (error) {
      log.warning('统计无来源历史失败：$error', scope: 'history');
      return 0;
    }
  }

  List<PlaybackHistory> searchHistory(String keyword, {String? sourceKey}) {
    final database = _database;
    if (database == null) return const [];
    try {
      return database.searchHistory(
        keyword,
        sourceKey: sourceKey ?? historySourceFilter,
      );
    } catch (_) {
      return const [];
    }
  }

  void deleteHistory(int id) {
    _database?.deleteHistory(id);
    notifyListeners();
  }

  /// 清空播放历史。
  ///
  /// 按源隔离时只清当前源（别的源的记录不该被顺手抹掉）；
  /// 全局历史模式下清全部。`clearAll` 供「清空全部」入口显式指定。
  void clearHistory({bool clearAll = false}) {
    final scope = clearAll ? '' : historySourceFilter;
    _database?.clearHistory(sourceKey: scope);
    // 「清空历史」同时清季度进度，但**保留**匹配与绑定（`03` §6.5）。
    _database?.clearTmdbSeasonProgress();
    log.info('已清空播放历史（配置未受影响）', scope: 'history');
    notifyListeners();
  }

  // -------------------------------------------------------------------------
  // 历史同名聚合（读视图）
  // -------------------------------------------------------------------------

  /// 历史页的**分组视图**：把 [recentHistory] / [searchHistory] 的结果按
  /// [historyAggregation] 投影成一张卡一组。
  ///
  /// 关键约束（对应 `docs/phase5/design/05`）：
  /// - 聚合只是**读视图**：写入仍是一集一条记录，切回 `none` 立刻恢复原样；
  /// - 组内代表记录取 `updatedAt` 最新（安卓 §8.1）；
  /// - 搜索关键词命中组内**任一成员**即保留该组（否则「搜某集搜不到」）。
  List<HistoryGroup> historyGroups({String keyword = ''}) {
    final records = keyword.isEmpty ? recentHistory() : searchHistory(keyword);
    return groupHistory([
      for (final record in records) _historyGroupInputOf(record),
    ], mode: historyAggregation);
  }

  /// 把一条历史映射成聚合投影的输入（补上作品身份）。
  HistoryGroupInput _historyGroupInputOf(PlaybackHistory record) =>
      HistoryGroupInput(
        id: record.id,
        sourceKey: record.sourceKey,
        siteKey: record.siteKey,
        vodId: record.vodId,
        vodName: record.vodName,
        vodPic: record.vodPic,
        flag: record.flag,
        episodeName: record.episodeName,
        episodeId: record.episodeId,
        positionMs: record.positionMs,
        durationMs: record.durationMs,
        updatedAt: record.updatedAt,
        completed: record.completed,
        vodYear: record.vodYear,
        tmdbId: record.tmdbId,
        mediaType: record.mediaType,
      );

  /// `source_key` → 用户可读的来源名（用于历史卡片上的「非当前源」标注）。
  ///
  /// 空串（迁移前的老记录）返回 `null`：那不是「别的源」，而是「不知道来源」，
  /// 由调用方单独标注为「来源未知」。
  ///
  /// **只给可读名称**（用户 2026-11 反馈：「应该显示其他线路的名称，现在显示的是
  /// URL」）。布局名/来源地址（`origin`、`bridge|<uuid>|<key>` 的裸标识）都不是
  /// 名称：前者是给设置页排查用的长串，后者对用户没有意义。两者一律归到
  /// 「其他来源」，且**绝不**回落到 `origin`——那正是这次要修的表现。
  String? historySourceLabel(String sourceKey) {
    final key = sourceKey.trim();
    if (key.isEmpty) return null;
    if (key == activeSourceKey) return null;
    final record = _database?.configBySourceKey(key);
    if (record != null) {
      final name = record.name.trim();
      if (name.isNotEmpty && !_looksLikeUrl(name)) return name;
    }
    return '其他来源';
  }

  /// 名称是否其实是地址（导入时把 URL 当名字存下的老记录）。
  ///
  /// 只认「带 scheme」与「像主机:端口/路径」两类：中文配置名、带空格的名字
  /// 一律不判成地址（`配置名称` 里出现点与斜杠并不稀奇）。
  static bool _looksLikeUrl(String value) {
    final text = value.trim();
    if (text.isEmpty) return false;
    if (text.contains('://')) return true;
    final uri = Uri.tryParse(text);
    if (uri != null && uri.hasScheme) return true;
    return RegExp(r'^\d{1,3}(\.\d{1,3}){3}(:\d+)?(/|$)').hasMatch(text) ||
        RegExp(
          r'^[\w.-]+\.[a-z]{2,}(:\d+)?(/|$)',
          caseSensitive: false,
        ).hasMatch(text);
  }

  /// 某条历史是否属于**非当前播放源**。
  bool isHistoryFromOtherSource(PlaybackHistory record) {
    if (record.sourceKey.isEmpty) return false;
    return record.sourceKey != activeSourceKey;
  }

  List<FavoriteEntry> favorites({String? kind}) {
    final database = _database;
    if (database == null) return const [];
    try {
      return database.listFavorites(kind: kind);
    } catch (_) {
      return const [];
    }
  }

  bool isFavorite({required String kind, required String targetId}) {
    final database = _database;
    final site = _selectedSite;
    if (database == null || site == null) return false;
    try {
      return database.isFavorite(
        kind: kind,
        siteKey: site.key,
        targetId: targetId,
      );
    } catch (_) {
      return false;
    }
  }

  void toggleFavorite({
    required String kind,
    required String targetId,
    required String title,
    String? subtitle,
    String vodPic = '',
  }) {
    final database = _database;
    final site = _selectedSite;
    if (database == null || site == null) return;
    if (isFavorite(kind: kind, targetId: targetId)) {
      database.removeFavorite(
        kind: kind,
        siteKey: site.key,
        targetId: targetId,
      );
    } else {
      database.upsertFavorite(
        kind: kind,
        siteKey: site.key,
        targetId: targetId,
        title: title,
        subtitle: subtitle,
        vodPic: vodPic,
      );
    }
    notifyListeners();
  }

  List<SiteHealth> siteHealth() {
    final database = _database;
    if (database == null) return const [];
    try {
      return database.siteHealth();
    } catch (_) {
      return const [];
    }
  }

  /// 清理缓存目录，验证“删除缓存目录后应用可重建”（§16.3）。
  // -------------------------------------------------------------------------
  // Spider 运行时管理（§9.7、§9.8、§17.2）
  // -------------------------------------------------------------------------

  /// 本地 Spider manifest 注册表。
  SpiderManifestRegistry get spiderRegistry => _spiderRegistry;

  /// Spider 宿主监控器。
  SpiderHostSupervisor get spiderSupervisor => _supervisor;

  /// 重新扫描本地 Spider（设置页/管理页调用）。
  Future<List<LocalSpider>> rescanSpiders() async {
    final found = await _spiderRegistry.scan();
    await _supervisor.cleanStaleWorkDirs();
    log.info('本地 Spider 已扫描：${found.length} 个', scope: 'spider');
    // 手工往 `spiders/local/` 放源后重新扫描，站点列表也要跟着更新。
    _invalidateLocalSites();
    return found;
  }

  /// 本地 Spider 列表（供管理页展示）。
  List<LocalSpider> get localSpiders => _spiderRegistry.sortedSpiders;

  /// 运行时状态列表（含崩溃、退避、隔离等级）。
  List<SpiderRuntimeStatus> spiderRuntimeStatuses() => _supervisor.statuses();

  /// 强制停止某站点的 Spider（§18.2「每个站点运行时可随时强制停止」）。
  Future<void> stopSpider(String siteKey) async {
    await _supervisor.stop(siteKey);
    _notifyIfAlive();
  }

  /// 重置站点 Spider 失败计数，允许重新启动（§9.3.1 退避的人工退出）。
  void resetSpider(String siteKey) {
    _supervisor.reset(siteKey);
    notifyListeners();
  }

  // -------------------------------------------------------------------------
  // T3（csp_*）桌面 JAR 站源导入（ADR-0002、docs/reference/win-box-borrowings.md §12.6）
  // -------------------------------------------------------------------------

  /// csp_* 站点的桌面 jar 缓存根：`<config>/spiders/csp`。
  String get cspRoot => _cspBinding.root;

  /// 站点 key 对应的缓存目录。
  CspJvmBinding get _currentCspBinding =>
      _cspBinding.forConfig(effectiveConfig ?? AppConfig());

  String cspDirectoryFor(String siteKey) =>
      _currentCspBinding.directoryFor(siteKey);

  /// 已导入的 T3 桌面站源（含静态检测结论，供设置页回显）。
  List<InstalledJar> get installedCspJars {
    final config = effectiveConfig;
    if (config == null) {
      return JarIntake.describeInstalled(_currentCspBinding.root);
    }
    final binding = _currentCspBinding;
    final installed = <InstalledJar>[];
    for (final site in config.sites) {
      if (!CspJvmBinding.matches(site.api) || directSpiderKind(site) != null) {
        continue;
      }
      final entry = binding.entryFor(site.key);
      if (entry == null) continue;
      installed.add(
        InstalledJar(
          siteKey: site.key,
          directory: binding.directoryFor(site.key),
          entryPath: entry,
          inspection: JarIntake.inspectPath(
            entry,
            expectedClass: CspJarProbe.entryClassNameOf(site),
          ),
        ),
      );
    }
    installed.sort((a, b) => a.siteKey.compareTo(b.siteKey));
    return installed;
  }

  /// 静态检测一个候选入口，**不落盘**（设置页在导入前预览结论）。
  JarInspection inspectCspSource(String sourcePath, {String? siteKey}) =>
      JarIntake.inspectPath(
        sourcePath,
        expectedClass: siteKey == null ? null : JarIntake.classNameFor(siteKey),
      );

  /// 导入 T3 桌面站源：静态检测 → 通过才落盘到 `<config>/spiders/csp/<siteKey>/`。
  ///
  /// 纪律：含**原生库**（`lib/*.so`）或无法解析的入口**一律不落盘**，也不覆盖
  /// 既有文件。含 `classes.dex` 且**无**原生库的入口**可以落盘**，落盘后由
  /// [DexTranslate] 在**独立进程**里做字节码预转译（`webhtv.spider.DexIntakeCli`）：
  /// 不加载类、不调用站源方法、不联网，因此不违反 PRODUCT.md 的「UI 层不得直接
  /// 执行网络请求、Spider 或代理逻辑」——转译不执行 Spider。预转译不做的话，首次
  /// sidecar 加载要现场转译（实测 4.6–9.2 s），会撞上 `initialize` 的 15 s 截止
  /// （spider_process.dart）；导入期做一次，之后命中缓存（约 0.4 s）。
  /// 依据：PRODUCT.md、ADR-0002。
  Future<JarInstallResult> importCspJar({
    required String siteKey,
    required String sourcePath,
  }) async {
    final result = await JarIntake.install(
      sourcePath: sourcePath,
      targetDir: _cspBinding.directoryFor(siteKey),
      siteKey: siteKey,
      manualOverride: true,
      log: log,
      // 转译失败不影响落盘结论（`ok` 只表示落盘）：结论写进 intake.json 的
      // `dexTranslation`，可用性文案由 spider_router 的 `_classifyCsp` 决定。
      translateDex: ({required siteDir, required archive}) =>
          DexTranslate.run(siteDir: siteDir, archive: archive, log: log),
    );
    // 分类结果不经过 SpiderRouter 的 _cache，磁盘变化后 classifySite 立即反映；
    // 这里只需刷新 UI（站点列表的可用性文案会跟着变）。
    _notifyIfAlive();
    return result;
  }

  /// 自动探测配置里声明的 csp_* jar（方案 3，§12.9）。
  ///
  /// 配置能把 `jar`/`spider` 写成远端地址（AT 就是
  /// `http://192.168.50.50:4567/spring.jar`），可 PC 端只认本机缓存。这里把
  /// 「取回 → 静态检测 → 允许才导入」自动化：**能加载的自动装好，不能加载的
  /// 自动说清原因**，不再让用户自己去「迁移」。
  ///
  /// 纪律不变：含**原生库**（`lib/*.so`）或无法解析的入口一律**不落盘**，只写结论
  /// （`probe.json`）；含 `classes.dex` 且无原生库的入口可以落盘，并在这里顺带做
  /// 导入期字节码预转译（[DexTranslate]，独立进程、不加载类、不调用站源方法、不联网；
  /// 因此不违反 PRODUCT.md 的「UI 层不得直接执行网络请求、Spider 或代理逻辑」）。
  /// 依据：PRODUCT.md、ADR-0002。
  Future<CspProbeReport> probeCspJars({
    void Function(ShellUnpackTick)? onProgress,
  }) async {
    final config = effectiveConfig;
    if (config == null) return const CspProbeReport();
    final report = await _cspProbe().materialize(
      config,
      onProgress: onProgress,
    );
    if (!report.isEmpty) _notifyIfAlive();
    return report;
  }

  @visibleForTesting
  CspProbeRunner? debugCspProbeOverride;

  @visibleForTesting
  CspJarProbe Function(CspJvmBinding binding, bool allowShellUnpack)?
  debugCspProbeFactoryOverride;

  final Expando<bool> _cspAutoProvisionRuns = Expando<bool>();
  AppConfig? _cspHomeRetryConfig;
  Site? _cspHomeRetrySite;

  /// 本轮自动安装的只读进度；[CspProvisionProgress.active] 为 false 时导出摘要。
  CspProvisionProgress _cspProvisionProgress = const CspProvisionProgress();
  String? _cspProvisionSummary;

  /// 本轮运行号：迟到的回调与收尾不得改写新一代的进度，也不得清掉新一代登记
  /// 的 provisioning key。
  int _cspProvisionRunId = 0;
  AppConfig? _cspProvisionConfig;
  bool _cspProvisionInFlight = false;
  bool _cspProvisionPreparing = false;
  Set<String> _cspDeferredSiteKeys = const {};

  @visibleForTesting
  CspProvisionRunner? debugCspProvisionOverride;

  @visibleForTesting
  Set<String> get debugProvisioningSiteKeys => _router.provisioningSiteKeys;

  void _resetCspProvisionContext(AppConfig? config) {
    ++_cspProvisionRunId;
    _cspProvisionConfig = config;
    _cspProvisionInFlight = false;
    _cspProvisionPreparing = false;
    _cspDeferredSiteKeys = const {};
    _router.setProvisioningSiteKeys(const {});
    _cspProvisionProgress = const CspProvisionProgress();
    _cspProvisionSummary = null;
    _cspHomeRetryConfig = null;
    _cspHomeRetrySite = null;
  }

  void _kickCspProvisioning(AppConfig? config) {
    if (_disposed) return;
    final eligible = config?.sites.any(
      (site) =>
          CspJvmBinding.matches(site.api) &&
          directSpiderKind(site) == null &&
          JarSourceSpec.parse(site.effectiveJar(config.spider)) != null,
    ) ?? false;
    if (!eligible) {
      _resetCspProvisionContext(config);
      return;
    }
    unawaited(provisionCspJarsQuietly(config!));
  }

  /// 导入/装配后的后台安装；同一配置实例只尝试一轮，失败不影响前台。
  ///
  /// 进度契约（用户实测 2026-11-24：后台在装，界面只报「缺少 jar」）：安装期间
  /// 界面必须看得见进度，这些站点在装好之前也不得被说成「缺少桌面 JVM 站源」。
  Future<void> provisionCspJarsQuietly(AppConfig config) async {
    if (_disposed) return;
    if (!identical(_cspProvisionConfig, config)) {
      _resetCspProvisionContext(config);
    }
    if (_cspAutoProvisionRuns[config] == true) return;
    _cspAutoProvisionRuns[config] = true;
    final runId = ++_cspProvisionRunId;
    _cspProvisionInFlight = true;
    _cspProvisionPreparing = true;
    _cspProvisionSummary = null;
    _cspProvisionProgress = const CspProvisionProgress(
      active: true, stage: '检查站源', label: '正在检查站源（后台进行中）',
    );
    bool current() => !_disposed && runId == _cspProvisionRunId &&
        identical(_cspProvisionConfig, config) && identical(effectiveConfig, config);
    if (current()) _notifyIfAlive();
    final selected = <Site>[];
    var started = false;
    var installed = 0;
    var rejected = 0;
    var failed = 0;
    var needsRuntime = 0;
    var done = 0;
    var accepted = 0;
    var refused = 0;
    var broken = 0;
    String? failure;
    final entriesByKey = <String, CspProbeEntry>{};
    try {
      // 扫描也有同步读盘：先让出调用栈，再处理配置与站点目录。
      await _yieldBackgroundWork();
      if (!current()) return;
      final binding = _cspBinding.forConfig(config);
      final missing = config.sites
          .where(
            (site) =>
                CspJvmBinding.matches(site.api) &&
                directSpiderKind(site) == null &&
                JarSourceSpec.parse(site.effectiveJar(config.spider)) != null &&
                binding.entryFor(site.key) == null,
          )
          .toList();
      if (!current() || missing.isEmpty) return;
      started = true;
      final urls = <String>{};
      var deferredSites = 0;
      final deferredKeys = <String>{};
      // 限 4 个唯一 URL：实测 78 站共享 1 jar，限量覆盖常见配置并避免后台批量下载失控。
      for (final site in missing) {
        final spec = JarSourceSpec.parse(site.effectiveJar(config.spider));
        if (spec == null) continue;
        if (!urls.contains(spec.url)) {
          if (urls.length >= 4) {
            deferredSites++;
            deferredKeys.add(site.key);
            continue;
          }
          urls.add(spec.url);
        }
        selected.add(site);
      }
      if (deferredSites > 0) {
        log.info(
          'CSP 自动安装：本轮仅处理前 4 个 jar，剩余 $deferredSites 个站点，其余请用站点页自动探测',
          scope: 'spider',
        );
      }
      // 先登记「这些站点正在装」，再启动：站点列表/首页据此给出如实文案，而不是
      // 「缺少桌面 JVM 站源」——那是装完仍然失败才成立的结论。
      _cspProvisionPreparing = false;
      _cspDeferredSiteKeys = Set.unmodifiable(deferredKeys);
      _router.setProvisioningSiteKeys(<String>{
        for (final site in selected) site.key,
      });
      final waiting = _cspHomeRetrySite;
      if (identical(_cspHomeRetryConfig, config) && waiting != null &&
          deferredKeys.contains(waiting.key)) {
        _finishCspHomeWaiting(config, reason: _cspDeferredReason);
      }
      _cspProvisionSummary = null;
      _cspProvisionProgress = CspProvisionProgress(
        active: true,
        total: selected.length,
        label: _cspProvisionLabel(0, selected.length, ''),
      );
      // 开轮通知一次：导入结果行要立刻换成「站源正在后台安装」，不能等首个
      // 站点结论回来才更新（首站转译实测十几秒）。
      _notifyIfAlive();
      void onProgress(ShellUnpackTick tick) {
        if (!current()) return;
        final progress = _cspProvisionProgress;
        final stageChanged = tick.stage != progress.stage;
        _cspProvisionProgress = CspProvisionProgress(
          active: true,
          done: progress.done,
          total: progress.total,
          stage: tick.stage,
          installed: progress.installed,
          rejected: progress.rejected,
          failed: progress.failed,
          label: _cspProvisionLabel(
            progress.done,
            progress.total,
            tick.stage,
            eta: tick.eta,
          ),
        );
        // 节流：逐 jar 的 tick 只更新阶段，不每次都把整页重建推一遍。
        if (stageChanged) _notifyIfAlive();
      }

      void onEntry(CspProbeEntry entry) {
        if (_disposed || runId != _cspProvisionRunId) return;
        final progress = _cspProvisionProgress;
        entriesByKey[entry.siteKey] = entry;
        done = progress.done + 1;
        switch (entry.outcome) {
          case CspProbeOutcome.installed:
          case CspProbeOutcome.unpacked:
            accepted++;
          case CspProbeOutcome.rejected:
            refused++;
          case CspProbeOutcome.failed:
          case CspProbeOutcome.unpackFailed:
            broken++;
          case CspProbeOutcome.skippedInstalled:
          case CspProbeOutcome.noSource:
          case CspProbeOutcome.needsShellRuntime:
          case CspProbeOutcome.unsupportedShell:
            break;
        }
        _cspProvisionProgress = CspProvisionProgress(
          active: true,
          done: done,
          total: progress.total,
          stage: progress.stage,
          installed: accepted,
          rejected: refused,
          failed: broken,
          label: _cspProvisionLabel(done, progress.total, progress.stage),
        );
        // 站点结论是用户最关心的刻度：每站通知一次，tick 才节流。
        _notifyIfAlive();
      }

      final legacyOverride = debugCspProbeOverride;
      final CspProvisionRunner runner =
          debugCspProvisionOverride ??
          (legacyOverride != null
              ? (config, {onProgress, onEntry}) => legacyOverride(config)
              : _cspProbe(config: config, allowShellUnpack: false).materialize);
      final report = await runner(
        config.copyWith(sites: selected),
        onProgress: onProgress,
        onEntry: onEntry,
      );
      if (!current()) return;
      entriesByKey.addEntries(report.entries.map((entry) => MapEntry(entry.siteKey, entry)));
      installed = report.installed + report.unpacked;
      rejected = report.rejected;
      failed = report.failed + report.unpackFailed;
      needsRuntime = report.needsShellRuntime;
    } catch (error) {
      started = true;
      failed = selected.isEmpty ? 1 : selected.length;
      failure = '$error';
    } finally {
      if (!_disposed && runId == _cspProvisionRunId && identical(_cspProvisionConfig, config)) {
        _cspProvisionInFlight = false;
        _cspProvisionPreparing = false;
        _router.setProvisioningSiteKeys(const {});
      }
      if (current()) {
        final settled = started
            ? _cspProvisionSummaryLine(installed: installed, rejected: rejected,
                failed: failed, needsRuntime: needsRuntime)
            : '站源检查完成，无需自动安装';
        _cspProvisionSummary = settled;
        _cspProvisionProgress = CspProvisionProgress(
          done: done, total: selected.length, installed: installed,
          rejected: rejected, failed: failed, label: settled,
        );
        if (started) {
          final summary = 'CSP 自动安装：已装 $installed 个、拒绝 $rejected、失败 $failed、需解包运行时 $needsRuntime';
          if (failed > 0) {
            log.warning(failure == null ? summary : '$summary（$failure）', scope: 'spider');
          } else {
            log.info(summary, scope: 'spider');
          }
        }
        final waiting = _cspHomeRetrySite;
        _finishCspHomeWaiting(config,
          entry: waiting == null ? null : entriesByKey[waiting.key],
          reason: failure,
        );
        _notifyIfAlive();
      }
    }
  }

  static const _cspDeferredReason =
      '本轮仅自动安装前 4 个 jar，本站点未参与；请在站点页运行自动探测';

  void _finishCspHomeWaiting(AppConfig config, {CspProbeEntry? entry, String? reason}) {
    if (!identical(_cspHomeRetryConfig, config)) return;
    final waiting = _cspHomeRetrySite;
    final selected = _selectedSite;
    _cspHomeRetryConfig = null;
    _cspHomeRetrySite = null;
    if (waiting == null || selected == null || selected.key != waiting.key ||
        selected.api != waiting.api || !identical(effectiveConfig, config)) {
      return;
    }
    if (_currentCspBinding.entryFor(selected.key) != null) {
      unawaited(loadHome(selected).catchError((Object error) {
        if (!_disposed && identical(effectiveConfig, config)) {
          log.warning('CSP 自动安装后首页重载失败：$error', scope: 'spider');
        }
      }));
      return;
    }
    final message = reason ?? (entry?.message.isNotEmpty == true ? entry!.message : null) ??
        _cspTerminalReason(selected, entry);
    _contentPhase = LoadPhase.failed;
    _lastError = AppError(AppErrorKind.siteUnsupported, message);
    if (_notice?.contains('正在后台安装站源') == true) _notice = null;
  }

  String _cspTerminalReason(Site site, CspProbeEntry? entry) {
    if (_cspDeferredSiteKeys.contains(site.key)) return _cspDeferredReason;
    final record = cspProbeRecordFor(site.key);
    final recordedReason = record == null ? null : _router.classifySite(site).reason;
    if (recordedReason != null) return recordedReason;
    return switch (entry?.outcome) {
      CspProbeOutcome.needsShellRuntime => '本站源需要解包运行时，请在站点页显式确认解包',
      CspProbeOutcome.rejected => '本站源未通过桌面兼容性检测，请在站点页查看自动探测结论',
      CspProbeOutcome.unsupportedShell => '本站源的加固壳尚未支持，请使用其他站源',
      _ => '本站源自动安装未完成，请在站点页运行自动探测查看原因',
    };
  }

  /// 安装进度整行文案：进度 + 阶段 + 可信时才给的估算剩余时间。
  static String _cspProvisionLabel(
    int done,
    int total,
    String stage, {
    Duration? eta,
  }) {
    final buffer = StringBuffer(
      total <= 0 ? '正在检查站源' : '正在自动安装站源 $done/$total',
    );
    // 阶段与上面那句前缀重复时不再拼一遍（准备阶段的服务层阶段也叫「检查站源」）。
    if (stage.isNotEmpty && !buffer.toString().endsWith(stage)) {
      buffer.write(' · $stage');
    }
    final seconds = eta?.inSeconds ?? 0;
    if (seconds > 0) buffer.write(' · 预计剩余约 $seconds 秒');
    return buffer.toString();
  }

  /// 结束后的摘要（保留到下一轮开始）：已装多少，以及失败时如实报数量。
  static String _cspProvisionSummaryLine({
    required int installed,
    required int rejected,
    required int failed,
    int needsRuntime = 0,
  }) {
    final buffer = StringBuffer('已自动安装 $installed 个站源');
    if (rejected > 0) buffer.write('，拒绝 $rejected 个');
    if (failed > 0) buffer.write('，失败 $failed 个');
    if (needsRuntime > 0) buffer.write('，$needsRuntime 个需在站点页确认解包');
    return buffer.toString();
  }

  /// 某站点上次的自动探测结论（设置页/站点页回显）；未探测过为 null。
  Map<String, Object?>? cspProbeRecordFor(String siteKey) =>
      CspJarProbe.recordFor(_currentCspBinding, siteKey);

  CspJarProbe _cspProbe({AppConfig? config, bool allowShellUnpack = true}) {
    final scoped = config ?? effectiveConfig;
    final binding = scoped == null
        ? _cspBinding
        : _cspBinding.forConfig(scoped);
    final factory = debugCspProbeFactoryOverride;
    if (factory != null) return factory(binding, allowShellUnpack);
    return CspJarProbe(
      root: _spiderRegistry.root,
      binding: binding,
      allowShellUnpack: allowShellUnpack,
      log: log,
    );
  }

  UnidbgRuntime? _unidbgRuntime;

  /// 加固壳解包运行时（unidbg）。**只在用户点下载时才联网**；
  /// 探测链路只读 [shellRuntimeInstalled]，绝不隐式触发 40.7 MB 下载。
  UnidbgRuntime get shellRuntime => _unidbgRuntime ??= UnidbgRuntime(log: log);

  /// 解包运行时是否已安装（读目录，不联网）。
  bool get shellRuntimeInstalled => shellRuntime.isInstalledSync;

  /// 下载并安装解包运行时（四镜像回退、逐文件 SHA-256 校验）。
  ///
  /// 安装完不自动重跑探测：调用方（设置页/站点页）决定何时重试；`needsShellRuntime`
  /// 在 `probe.json` 里是非终态，下一轮探测会自己重跑。
  Future<UnidbgRuntimeInstall> installShellRuntime({
    void Function(UnidbgRuntimeProgress)? onProgress,
  }) async {
    final result = await shellRuntime.install(onProgress: onProgress);
    log.info(
      result.installed
          ? '加固壳解包运行时已安装：${result.dir}（${result.bytes} B）'
          : '加固壳解包运行时安装失败：${result.error ?? '原因未知'}',
      scope: 'spider',
    );
    if (result.installed) _notifyIfAlive();
    return result;
  }

  /// 删除解包运行时。**不动已解包的 payload 缓存**：删掉只是不能再解新壳，
  /// 已经解出来的站点仍可运行。
  Future<void> removeShellRuntime() async {
    await shellRuntime.remove();
    log.info('加固壳解包运行时已删除', scope: 'spider');
    _notifyIfAlive();
  }

  /// 最近一次加固壳探测的原始结论（`csp_jar_probe` 契约对象）。
  List<ShellJarTarget> _shellTargets = const [];

  /// 「导入后 / 选站点后」两处待弹框信号。state 层只登记，不弹 UI。
  final PendingShellUnpack _pendingShellUnpack = PendingShellUnpack();

  /// 导入配置后待确认的解包提示（没有待弹框时为 null）。
  List<ShellTargetItem>? get pendingShellUnpackPrompt =>
      _pendingShellUnpack.prompt;

  /// 待弹「确认解包」的站点 key（没有待弹框时为 null）。
  String? get pendingShellUnpackForSite => _pendingShellUnpack.siteKey;

  /// 取走导入提示：弹过一次就没了，同一条提示不会被连弹。
  List<ShellTargetItem>? takePendingShellUnpackPrompt() =>
      _pendingShellUnpack.takePrompt();

  /// 取走站点级确认：同上。
  String? takePendingShellUnpackForSite() => _pendingShellUnpack.takeSite();

  /// 对话框顶部那一行运行时状态文案。
  String? get shellUnpackRuntimeStateLabel =>
      shellRuntimeInstalled ? '解包运行时已安装。' : '解包运行时未安装：开始解包时会先下载约 40.7 MB。';

  /// 探测结论 → 对话框条目。
  ///
  /// 已解包的条目置灰、不勾选（重解没有意义）；给了 [preferSiteKey] 就只勾选它
  /// 所属的 jar——用户点的是某个站点，不是整份配置。
  List<ShellTargetItem> shellUnpackItems({String? preferSiteKey}) => [
    for (final target in _shellTargets)
      if (target.state != ShellTargetState.installed)
        ShellTargetItem(
          jarUrl: target.jarUrl,
          label: _shellTargetLabel(target),
          siteCount: target.siteKeys.length,
          stateLabel: _shellTargetStateLabel(target),
          selected:
              target.state != ShellTargetState.unpacked &&
              (preferSiteKey == null ||
                  target.siteKeys.contains(preferSiteKey)),
          disabled: target.state == ShellTargetState.unpacked,
        ),
  ];

  /// 导入/切配置后异步探测加固壳。
  ///
  /// 只探测、只暂存：**不弹 UI、不下载运行时**。命中需要解包的站源时登记一条
  /// 待确认提示，弹不弹、什么时候弹由 UI 决定。
  Future<void>? _shellTargetsProbe;

  /// 导入后加固壳探测的句柄（未导入过时为已完成的 Future）。
  ///
  /// 为什么需要：`importConfig` 里探测是 `unawaited` 的（不拖慢导入），但导入页要在
  /// 「导入成功」这一刻决定弹不弹确认框，只能等它 settle 再读暂存提示。
  Future<void> get shellTargetsProbe =>
      _shellTargetsProbe ?? Future<void>.value();

  Future<void> _probeShellTargetsQuietly(
    AppConfig config, {
    bool stagePrompt = true,
  }) async {
    try {
      final targets = await _cspProbe().discoverShellTargets(config);
      // 探测期间配置又换了：这批结论属于旧配置，丢掉。
      if (!identical(_config, config)) return;
      _shellTargets = targets;
      final pending = targets.where(_shellTargetNeedsUnpack).toList();
      if (pending.isEmpty) {
        log.info('加固壳探测：没有需要解包的站源', scope: 'spider');
        return;
      }
      if (stagePrompt && _pendingShellUnpack.stagePrompt(shellUnpackItems())) {
        log.info('加固壳探测：${pending.length} 个 jar 待解包，已登记导入提示', scope: 'spider');
        _notifyIfAlive();
      }
    } catch (error) {
      log.warning('加固壳探测失败：$error', scope: 'spider');
    }
  }

  /// 解包用户选中的加固壳：运行时没装先装，解完刷新探测结论。
  ///
  /// 进度经 [onTick] 外抛，state 层不弹 UI；失败直接抛出（运行时装不上 / 解包报错），
  /// 由进度对话框显示阶段与原因——失败不许静默。
  Future<void> unpackShellTargets(
    Set<String> jarUrls, {
    void Function(ShellUnpackTick)? onTick,
  }) async {
    if (jarUrls.isEmpty) return;
    final config = effectiveConfig;
    if (config == null) {
      throw AppError(AppErrorKind.configInvalid, '没有可用配置，无法解包加固壳');
    }
    // 运行时只在用户点了「下载并解包」之后才下载：40.7 MB 不跟着探测走。
    if (!shellRuntimeInstalled) {
      // 解包流还没开始，但它同样是用户要等的阶段：先发一条，进度条上不至于
      // 停在「准备中」一动不动（这一段能占掉整个流程的一大半墙钟时间）。
      onTick?.call(
        ShellUnpackTick(
          jarIndex: 0,
          jarCount: jarUrls.length,
          jarUrl: '',
          fraction: 0,
          stage: '下载解包运行时',
        ),
      );
      final install = await installShellRuntime();
      if (!install.installed) {
        final reason = install.error ?? '未知原因';
        throw AppError(AppErrorKind.unknown, '解包运行时安装失败：$reason');
      }
    }
    await _cspProbe().unpackSelected(
      config,
      jarUrls: jarUrls,
      onProgress: onTick,
    );
    log.info('加固壳解包完成：${jarUrls.length} 个 jar', scope: 'spider');
    // 结论刷新 + 清掉待弹信号：解完再点同一个站点不该再被问一次。
    await _probeShellTargetsQuietly(config, stagePrompt: false);
    _pendingShellUnpack.clear();
    _notifyIfAlive();
  }

  bool _shellTargetNeedsUnpack(ShellJarTarget target) =>
      target.state == ShellTargetState.needsRuntime ||
      target.state == ShellTargetState.needsUnpack ||
      target.state == ShellTargetState.failed;

  String _shellTargetStateLabel(ShellJarTarget target) {
    switch (target.state) {
      case ShellTargetState.installed:
        return '可直接运行';
      case ShellTargetState.needsRuntime:
        return '需下载运行时';
      case ShellTargetState.needsUnpack:
        return '需解包';
      case ShellTargetState.unpacked:
        return '已解包';
      case ShellTargetState.failed:
        final stage = target.stage;
        return stage == null || stage.isEmpty ? '上次失败' : '上次失败（$stage）';
    }
  }

  String _shellTargetLabel(ShellJarTarget target) {
    final path = Uri.tryParse(target.jarUrl)?.path ?? '';
    final name = p.basename(path);
    return name.isEmpty ? target.jarUrl : name;
  }

  /// 站点进入后登记「确认解包」信号。
  void _noteShellUnpackForSite(Site site) {
    if (site.key.isEmpty) return;
    _stageShellUnpackForSiteKey(site.key);
  }

  /// 幂等：同一站点重复点击只留一个待弹框（见 [PendingShellUnpack]）；
  /// 站点不在最近一次探测的结论里就什么都不做。
  void _stageShellUnpackForSiteKey(String siteKey) {
    final needs = _shellTargets.any(
      (target) =>
          target.siteKeys.contains(siteKey) && _shellTargetNeedsUnpack(target),
    );
    if (!needs) return;
    if (_pendingShellUnpack.stageSite(siteKey)) _notifyIfAlive();
  }

  /// 测试入口：直接注入一份探测结论（真实路径由 [_probeShellTargetsQuietly] 填）。
  @visibleForTesting
  void debugSetShellTargets(List<ShellJarTarget> targets) {
    _shellTargets = targets;
  }

  /// 测试入口：模拟「用户点进某个站点」后登记待弹信号（与 [selectSite] 同一段逻辑）。
  @visibleForTesting
  void debugStageShellUnpackForSite(String siteKey) {
    _stageShellUnpackForSiteKey(siteKey);
  }

  /// 启动/换配置后异步探测（不阻塞首屏；失败只记日志）。
  /// 启动阶段的加固壳发现：**只读**，不下载、不装配、不起 JVM。
  ///
  /// 与 [provisionCspJarsQuietly] 的分工：后者限量安装缺失 jar，这里只发现加固壳。
  Future<void> _probeShellTargetsQuietlyForStartup() async {
    try {
      final config = effectiveConfig;
      if (config == null) return;
      if (!config.sites.any((site) => CspJvmBinding.matches(site.api))) return;
      final clock = Stopwatch()..start();
      await _probeShellTargetsQuietly(config, stagePrompt: false);
      // 可观测：启动阶段只读发现的耗时必须留在日志里，卡顿时才有据可查。
      log.info(
        '启动阶段加固壳发现完成 elapsed=${clock.elapsedMilliseconds}ms',
        scope: 'spider',
      );
      // 这里**不做**批量预热：JVM 只认同它自己口径的 payload 产物，启动阶段
      // 再起一次 CLI 转译会让同一份产物被写两遍（2026-11-24 实测：同一 Douban
      // 产物 17.1 s + 16.7 s，叠加前台首页 elapsed 24.8 s）。转译仍由 JVM 首次
      // 开站时做一次，成功后由 SidecarRuntime 收进共享缓存（毫秒级复制）。
    } catch (error) {
      log.warning('启动阶段加固壳发现失败：$error', scope: 'spider');
    }
  }

  /// 移除已导入的 T3 桌面站源（回滚到「缺少桌面 JVM 站源」）。
  Future<bool> removeCspJar(String siteKey, {String? directory}) async {
    final targetDir = directory ?? _currentCspBinding.directoryFor(siteKey);
    final root = p.normalize(p.absolute(_currentCspBinding.root));
    final target = p.normalize(p.absolute(targetDir));
    if (!p.equals(p.dirname(target), root)) return false;
    try {
      if (Directory(target).existsSync() &&
          !p.equals(
            p.dirname(Directory(target).resolveSymbolicLinksSync()),
            Directory(root).resolveSymbolicLinksSync(),
          )) {
        return false;
      }
    } on FileSystemException {
      return false;
    }
    final removed = await JarIntake.remove(targetDir: targetDir, log: log);
    if (removed) _notifyIfAlive();
    return removed;
  }

  // -------------------------------------------------------------------------
  // 本地爬虫源（文件夹扫描 → 预览勾选 → 导入 → 长期保留）
  // -------------------------------------------------------------------------

  /// Spider 根目录（`<config>/spiders`）；本地源落在其 `local/` 子目录。
  String get spiderRoot => _spiderRegistry.root;

  /// 上次扫描的文件夹（本会话记忆，供页面回填）。
  String get lastLocalScanFolder => _lastLocalScanFolder;

  /// 已导入的 HTML 首页注入源（webHome，含已停用的源）。
  ///
  /// 走 [_allWebHomeSources] 的缓存而非直读 [_webHomeStore]：`LocalSourcesPage.build`
  /// 会直接读它，而登记表是磁盘上的 JSON——每次 build 同步读盘既慢，又会在登记表
  /// 损坏时把异常抛进 build。缓存统一在 [_invalidateLocalSites] 失效，导入/启停/
  /// 删除后立刻可见；读数失败的原因仍由 [webHomeLoadError] 如实上报。
  List<WebHomeSource> get webHomeSources => _allWebHomeSources();

  /// 某个 webHome 源的资源目录（WebView2 虚拟主机映射用）。
  String webHomeDirectory(String key) => _webHomeStore.directoryFor(key);

  /// 扫描文件夹里的本地源候选。**只读，不执行任何被扫描文件。**
  Future<LocalScanReport> scanLocalSources(String folder) async {
    final report = await _localScanner.scan(folder);
    if (report.folder.isNotEmpty) _lastLocalScanFolder = report.folder;
    log.info(
      '本地源扫描 folder=${report.folder} candidates=${report.candidates.length} '
      'skipped=${report.skipped.length} truncated=${report.truncated}',
      scope: 'spider',
    );
    return report;
  }

  /// 导入勾选的候选：`.py`/`.js` 落 `spiders/local/<key>/`，
  /// `.html` 落 `webhome/<key>/` 并登记。同名 key 一律拒绝。
  Future<LocalImportResult> importLocalSources(
    List<LocalSourceCandidate> picked,
  ) async {
    final importer = LocalSourceImporter(
      spiderRoot: _spiderRegistry.root,
      registry: _spiderRegistry,
      webHomeStore: _webHomeStore,
      log: log,
    );
    final outcomes = <LocalImportOutcome>[];
    for (final candidate in picked) {
      if (!_pendingLocalImports.add(candidate.key)) {
        outcomes.add(
          LocalImportOutcome(
            key: candidate.key,
            kind: candidate.kind,
            ok: false,
            message: '源 key=${candidate.key} 正在导入，请等待完成后重试',
          ),
        );
        continue;
      }
      try {
        // 写盘前统一检查两套导入空间；逐个导入使同批次新占用也可见。
        if (_spiderRegistry.byKey(candidate.key) != null ||
            _webHomeStore.contains(candidate.key)) {
          outcomes.add(
            LocalImportOutcome(
              key: candidate.key,
              kind: candidate.kind,
              ok: false,
              message: '源 key=${candidate.key} 已被既有源占用，请改名后导入',
            ),
          );
          continue;
        }
        outcomes.addAll((await importer.importSelected([candidate])).outcomes);
      } on FormatException catch (error) {
        outcomes.add(
          LocalImportOutcome(
            key: candidate.key,
            kind: candidate.kind,
            ok: false,
            message: 'HTML登记表读取失败，未导入：$error',
          ),
        );
      } on FileSystemException catch (error) {
        outcomes.add(
          LocalImportOutcome(
            key: candidate.key,
            kind: candidate.kind,
            ok: false,
            message: '登记表或源文件读取失败，未导入：$error',
          ),
        );
      } finally {
        _pendingLocalImports.remove(candidate.key);
      }
    }
    final result = LocalImportResult(outcomes: outcomes);
    // 导入成功后必须重建站点列表：注册表已多出条目，缓存还在的话首页依旧看不到
    // 刚导入的源（用户视角就是「导入成功但列表没变化」）。
    if (result.importedCount > 0) _invalidateLocalSites();
    return result;
  }

  /// 重新载入已导入源（磁盘被手工改动后刷新界面）。
  Future<void> reloadLocalSources() async {
    await _spiderRegistry.scan();
    _localSourceEnable.reload();
    _invalidateLocalSites();
  }

  /// 只删除已注册的 `local/<key>` 普通目录；运行中的源必须先由运行时页停止。
  Future<bool> removeLocalSpider(String key) async {
    if (!WebHomeStore.isValidKey(key)) return false;
    final spider = _spiderRegistry.byKey(key);
    if (spider == null) return false;
    final root = p.normalize(p.absolute(spiderRoot));
    final localRoot = p.join(root, 'local');
    final target = p.join(localRoot, key);
    if (!p.equals(p.normalize(p.absolute(spider.rootDir)), target) ||
        !p.isWithin(localRoot, target)) {
      return false;
    }
    // Supervisor 按配置站点 key 管理，同一 manifest 可能由多个站点引用。
    if (_supervisor.isSourceActive(key)) {
      log.warning('本地源仍在运行，拒绝删除 key=$key，请先停止运行时', scope: 'spider');
      return false;
    }
    try {
      if (!removeLocalSpiderDirectory(root: root, key: key)) return false;
      // 同 key 重新导入不得继承旧的停用状态：删除时一并清掉残留。
      _localSourceEnable.forget(key);
      await _spiderRegistry.scan();
      _invalidateLocalSites();
      return true;
    } on FileSystemException catch (error) {
      log.error('删除本地源失败 key=$key：$error', scope: 'spider');
      return false;
    }
  }

  /// 启用/停用某个 webHome 源。
  Future<bool> setWebHomeEnabled(String key, bool enabled) async {
    final ok = _webHomeStore.setEnabled(key, enabled);
    if (ok) _invalidateLocalSites();
    return ok;
  }

  /// 全部已登记的 webHome 源（含已停用）；读取失败时保留原因并降级为空表。
  ///
  /// 与 [_safeWebHomeSources] 的区别：那份只含**启用**的源（站点列表用），
  /// 这里要能看见停用的源，否则「再启用」会提示源不存在。
  List<WebHomeSource>? _allWebHomeSourcesCache;

  List<WebHomeSource> _allWebHomeSources() {
    final cached = _allWebHomeSourcesCache;
    if (cached != null) return cached;
    try {
      final sources = _webHomeStore.list();
      _webHomeLoadError = null;
      _webHomeLoadErrorDetail = null;
      return _allWebHomeSourcesCache = sources;
    } on FormatException catch (error) {
      _recordWebHomeLoadError(error);
    } on FileSystemException catch (error) {
      _recordWebHomeLoadError(error);
    }
    return _allWebHomeSourcesCache = const [];
  }

  /// 两套读取（启用集 / 全量集）共用一份失败记账：原因必须对界面可见，
  /// 否则 `webHomeSources` 不再抛异常后，坏登记表会被读成「没有本地源」。
  void _recordWebHomeLoadError(Object error) {
    _webHomeLoadError = '载入HTML源失败：$error';
    _webHomeLoadErrorDetail = '$error';
    log.error(_webHomeLoadError!, scope: 'site');
  }

  /// 启用状态文件读坏时的原因（界面必须显示，不能静默当成全部启用）。
  String? get localSourceEnableError {
    _localSourceEnable.disabledKeys;
    return _localSourceEnable.loadError;
  }

  /// 本地源当前是否启用（py/js 与 HTML 统一口径，不存在的源返回 false）。
  ///
  /// HTML 的启用状态在 `webhome/registry.json`，py/js 在 `local_sources.json`：
  /// 两套存储的差异只在这里出现一次，界面与调用方不必知道 key 属于哪种源。
  bool localSourceEnabled(String key) {
    final trimmed = key.trim();
    // 先按 manifest 判定：`spiders/local/<key>/` 的源归 local_sources.json 管，
    // 其余（含根级 manifest 与直连注册）不是「本地源」，一律视为启用。
    final spider = _spiderRegistry.byKey(trimmed);
    if (spider != null && isImportedLocalSpider(spider, spiderRoot)) {
      return _localSourceEnable.isEnabled(trimmed);
    }
    for (final source in _allWebHomeSources()) {
      if (source.key == trimmed) return source.enabled;
    }
    return false;
  }

  /// 启用/停用单个本地源；返回是否已持久化。
  ///
  /// 停用的语义（用户已确认）：**从站点列表隐藏 + 立即停止该源运行中的 sidecar**。
  /// 只隐藏不停运行时，用户已经关掉的源仍在后台跑；只停运行时不停用列表，
  /// 下次打开又看到它可选——两者都不到「停用」。
  Future<bool> setLocalSourceEnabled(String key, bool enabled) async {
    final result = await setLocalSourcesEnabled([key], enabled);
    return result.results[key.trim()] ?? false;
  }

  /// 批量启用/停用；逐 key 返回成败，绝不把部分失败写成整体成功。
  Future<LocalSourceEnabledOutcome> setLocalSourcesEnabled(
    Iterable<String> keys,
    bool enabled,
  ) async {
    final wanted = <String>[];
    for (final key in keys) {
      final trimmed = key.trim();
      if (trimmed.isNotEmpty && !wanted.contains(trimmed)) wanted.add(trimmed);
    }
    // 先按「失败」初始化：不存在的 key 必须如实报 false，不能顺手把状态写进去。
    final results = <String, bool>{for (final key in wanted) key: false};
    if (wanted.isEmpty) return LocalSourceEnabledOutcome(results: results);
    final htmlKeys = <String>{
      for (final source in _allWebHomeSources()) source.key,
    };
    final spiderKeys = <String>[];
    for (final key in wanted) {
      final spider = _spiderRegistry.byKey(key);
      if (spider != null && isImportedLocalSpider(spider, spiderRoot)) {
        spiderKeys.add(key);
      } else if (htmlKeys.contains(key)) {
        try {
          results[key] = _webHomeStore.setEnabled(key, enabled);
        } on FormatException catch (error) {
          log.error('更新 HTML 源 key=$key 失败：$error', scope: 'site');
        } on FileSystemException catch (error) {
          log.error('保存 HTML 源 key=$key 失败：$error', scope: 'site');
        }
      }
    }
    if (spiderKeys.isNotEmpty) {
      // 一次写盘：逐个写会在中途失败时留下「部分停用」，且每次都要重读文件。
      final stored = _localSourceEnable.setEnabledAll(spiderKeys, enabled);
      for (final key in spiderKeys) {
        results[key] = stored;
      }
    }
    if (!enabled) {
      await _supervisor.stopSources(
        spiderKeys.where((key) => results[key] == true),
      );
    }
    _invalidateLocalSites();
    final failed = [
      for (final entry in results.entries)
        if (!entry.value) entry.key,
    ];
    final action = enabled ? '启用' : '停用';
    log.info('本地源$action keys=$wanted failed=$failed', scope: 'spider');
    return LocalSourceEnabledOutcome(results: results);
  }

  /// 删除某个 webHome 源（连同其资源目录）。
  Future<bool> removeWebHome(String key) async {
    final ok = _webHomeStore.remove(key);
    if (ok) {
      _localSourceEnable.forget(key);
      _invalidateLocalSites();
    }
    return ok;
  }

  /// 增加一个在线 HTML 首页源（只登记网址，**不**抓取页面）。
  ///
  /// 供「本地源」设置页与站点选择流程共用；登记（URL 非法、key 冲突）失败会
  /// 抛异常，调用方必须如实回显，不得当成成功。成功后立即刷新站点列表与路由，
  /// 新条目与本地导入的 HTML 源同形态（`web-home:<key>`，不可搜索）。
  Future<WebHomeSource> addOnlineWebHome(String url, {String? name}) async {
    final source = _webHomeStore.addRemote(url, name: name);
    _invalidateLocalSites();
    log.info('在线 HTML 首页已登记 key=${source.key}', scope: 'site');
    return source;
  }

  // -------------------------------------------------------------------------
  // 本地代理（§11）
  // -------------------------------------------------------------------------

  bool get proxyRunning => _proxy.isRunning;

  int get proxyPort => _proxy.port;

  String get proxyBaseUrl => _proxy.baseUrl;

  ProxySessionManager get proxySessions => _proxy.sessions;

  /// 播放地址对应的代理会话流量快照；非代理地址返回 null（直连走引擎读数）。
  ProxyTrafficSnapshot? proxyTrafficFor(String playbackUrl) =>
      _proxy.trafficFor(playbackUrl);

  /// 当前播放会话的代理 token 指纹（供设置页显示，不回显完整 token）。
  String? get proxySessionFingerprint => _proxySession?.fingerprint;

  /// 启动本地代理（只监听 127.0.0.1）。
  ///
  /// 端口**优先用 9978**，与 Android 宿主一致：安卓参考实现就是
  /// `com.github.catvod.Proxy.set(9978)` 后 `server.start(5000, true)`，
  /// 而加固壳/第三方站源返回的播放地址里写死了
  /// `http://127.0.0.1:9978/proxy?...`。桌面端此前从 0（随机端口）起，
  /// 那个地址就指向没人监听的端口——播放决策成功、播放器却拿不到流
  /// （2026-11-21 实测：本机 9978 无监听，WexHanXiaoQuan 返回的正是 9978 地址）。
  ///
  /// 9978 被占用时退回随机端口，并**如实记一条日志**：这种情况下壳源播放会失败，
  /// 不要静默降级成「能点但没画面」。
  Future<void> startProxy({int port = 9978}) async {
    if (_proxy.isRunning) return;
    try {
      await _proxy.start(port: port);
    } catch (error) {
      if (port == 0) rethrow;
      log.warning(
        '本地代理无法绑定 $port（$error），退回随机端口：壳源返回的 9978 代理地址将不可用',
        scope: 'proxy',
      );
      await _proxy.start(port: 0);
    }
    log.info('本地代理已监听 ${_proxy.baseUrl}', scope: 'proxy');
    _notifyIfAlive();
  }

  /// 停止本地代理并释放端口（§11.4）。
  Future<void> stopProxy() async {
    revokeProxySession();
    await _proxy.stop();
    _notifyIfAlive();
  }

  /// 为一次播放开启代理会话，并把媒体地址重写为代理 URL（§9.6、§11.3.1）。
  ///
  /// 无需重写的情况直接返回原决策：
  /// - 目标不是 http(s)；
  /// - 决策没有 Header（播放器可直接访问，少一跳开销）；
  /// - 目标被代理策略拒绝（否则会把可直连的地址换成永远 403 的死地址）。
  Future<PlaybackDecision> proxyDecision(
    PlaybackDecision decision, {
    required String siteKey,
    bool Function()? isCurrent,
  }) async {
    final url = decision.url;
    if (url == null || url.isEmpty) return decision;
    if (_jvmProxySession?.ownsUrl(url) ?? false) return decision;
    final target = Uri.tryParse(url);
    if (target == null ||
        !(target.isScheme('http') || target.isScheme('https'))) {
      return decision;
    }

    final headers = decision.headers;
    if (headers == null || headers.isEmpty) return decision;

    // 代理只应接管它**确实能代理**的目标：
    // - 策略会拒绝的目标（本机回环、私网、链路本地、云元数据）直接保持直连，
    //   否则会把本来可播放的地址换成永远 403 的地址，造成播放彻底失败；
    // - 会话主机白名单只放行该目标主机，防止被当成任意目标代理。
    final policyDecision = _proxy.policy.evaluateStatic(target);
    if (!policyDecision.allowed) {
      log.info(
        '目标不在代理策略允许范围内，保持直连 '
        'target=${LocalProxyServer.redactProxyTarget(target)} '
        'reason=${policyDecision.reason}',
        scope: 'proxy',
      );
      return decision;
    }

    try {
      if (!_proxy.isRunning) await _proxy.start();
    } catch (error) {
      log.warning('代理启动失败，回退为直连：$error', scope: 'proxy');
      return decision;
    }

    const credentialKeys = {'user-agent', 'referer', 'cookie', 'authorization'};
    // 启动代理是真实 await：期间用户可能已切画质，此时建会话会让新会话的 token
    // 被后续 revoke 顶掉，且 notify 会把播放器指回旧画质。
    if (_isStale(isCurrent)) return decision;
    final session = _proxy.sessions.create(
      siteKey: siteKey,
      allowedHosts: {target.host},
      userAgent: headers['User-Agent'] ?? headers['user-agent'],
      referer: headers['Referer'] ?? headers['referer'],
      cookie: headers['Cookie'] ?? headers['cookie'],
      authorization: headers['Authorization'] ?? headers['authorization'],
      extraHeaders: {
        for (final entry in headers.entries)
          if (!credentialKeys.contains(entry.key.toLowerCase()))
            entry.key: entry.value,
      },
    );
    _proxySession = session;
    final proxied = _proxy.urlFor(session, target);
    log.info(
      '播放转为本地代理 token=${session.fingerprint} '
      'target=${LocalProxyServer.redactProxyTarget(target)}',
      scope: 'proxy',
    );
    _notifyIfAlive();
    // 走代理后 Header 由代理注入，播放器不再重复携带（避免 Header 泄漏到直连请求）。
    return PlaybackDecision(
      action: decision.action,
      url: proxied,
      headers: HeaderMap(),
      format: decision.format,
      reason: decision.reason,
      flag: decision.flag,
      // 解析选项不是地址的一部分，代理换 url 后必须原样带过：丢了它，
      // 走代理的解析播放就再也没有解析入口。
      parseSources: decision.parseSources,
      parseSource: decision.parseSource,
      // 字幕不随代理地址变化：原样透传（§10.3）。
      subs: decision.subs,
      // 弹幕不随代理地址变化：原样透传（§21 Phase 3）。
      danmaku: decision.danmaku,
      // 候选画质是**未代理**原始列表，代理换 url 后仍保留，供 UI 切画质。
      qualities: decision.qualities,
      qualityIndex: decision.qualityIndex,
      // 代理前的原始 Header 留给宿主自己的附加请求（外挂字幕/弹幕）使用。
      upstreamHeaders: decision.headers,
    );
  }

  /// Capture exact authorization now; a stale page cannot release its successor.
  VoidCallback captureProxySessionRelease(String mediaUrl) {
    final owner = _jvmProxySession;
    final jvm =
        owner != null &&
            (owner.ownsUrl(mediaUrl) || _lastDecision?.url == mediaUrl)
        ? owner
        : null;
    final session = _proxySession;
    final http =
        session != null &&
            mediaUrl.startsWith('${_proxy.baseUrl}/p/${session.token}/')
        ? session
        : null;
    return () {
      var released = false;
      if (jvm != null && identical(_jvmProxySession, jvm)) {
        _jvmProxySession = null;
        unawaited(jvm.close());
        released = true;
      }
      if (http != null && identical(_proxySession, http)) {
        _revokeHttpProxySession();
        released = true;
      }
      if (released) _proxyPlaybackEpoch++;
    };
  }

  /// 停止当前播放会话的代理授权（§11.3.1「停止播放即失效」）。
  void revokeProxySession() {
    _proxyPlaybackEpoch++;
    final owner = _jvmProxySession;
    _jvmProxySession = null;
    unawaited(owner?.close());
    _revokeHttpProxySession();
  }

  void _revokeHttpProxySession() {
    final session = _proxySession;
    _proxySession = null;
    if (session != null) _proxy.sessions.revoke(session.token);
  }

  Future<void> resetCache() async {
    try {
      await resetCacheDirectory(paths.cacheDir);
      log.info('缓存目录已重建：${paths.cacheDir}', scope: 'storage');
      _notice = '缓存已清理';
      // The offline runtime lives in dataDir, independently of disposable cache.
      _applyPythonEnvironment();
    } catch (error) {
      _lastError = AppError(AppErrorKind.storage, '清理缓存失败', detail: '$error');
    }
    _notifyIfAlive();
  }

  // ---------------------------------------------------------------- 追番 P2-1

  FollowingSettings get followingSettings =>
      _uiPreferences?.followingSettings ?? FollowingSettings.defaults;

  /// 自动检查定时器是否在运行（默认开启语义的可观察出口）。
  bool get followingAutoCheckActive => _followingTimer != null;

  /// 系统通知降级/发送结果提示（空 = 无提示）。
  String get followingNotice => _followingNotice;

  /// 系统通知是否可用（首次尝试发通知后才有意义）。
  bool get followingSystemNotificationAvailable =>
      _followingNotifier?.systemAvailable ?? false;

  /// 点击系统通知后待打开的追番身份键（空 = 无待处理请求）。
  String get followingOpenRequest => _followingOpenRequestKey;

  /// 消费待打开的追番请求（追番页处理完调用）。
  void clearFollowingOpenRequest() => _followingOpenRequestKey = '';

  /// TMDB 季服务只读入口（后续日历页使用；`null` = 数据库未就绪）。
  TmdbSeasonService? get tmdbSeasonService =>
      _database == null ? null : _ensureTmdbSeasonService();

  /// 持久化追番设置并重启调度定时器（改间隔后立即补一次到期检查）。
  Future<bool> setFollowingSettings(FollowingSettings settings) async {
    final store = _uiPreferences;
    if (store == null) return false;
    final ok = await store.rememberFollowingSettings(settings);
    _restartFollowingTimer(
      kickDelay: followingSettings.enabled ? Duration.zero : null,
    );
    _notifyIfAlive();
    return ok;
  }

  FollowingNotifier get _notifier => _followingNotifier ??=
      _injectedFollowingNotifier ??
      FollowingNotifier(log: log, onOpen: _onFollowingNotificationOpen);

  /// 系统通知点击：记录待打开项，追番页据此打开最新集。
  void _onFollowingNotificationOpen(String payload) {
    final key = payload.trim();
    if (key.isEmpty) return;
    final item = _following
        ?.all()
        .where((candidate) => candidate.identityKey == key)
        .firstOrNull;
    if (item == null) return;
    _following?.markRead(item);
    _followingOpenRequestKey = key;
    notifyListeners();
  }

  /// 新集 → 系统通知；系统侧失败自动降级为应用内提示（不影响检查结果）。
  Future<void> _notifyFollowingNewEpisodes(List<Following> items) async {
    if (items.isEmpty || !followingSettings.notifyEnabled) return;
    final batch = await _notifier.notifyNewEpisodes(items);
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    // 通知（或降级提示）已经给过，写回水位避免下一轮重复提示。
    for (final item in items) {
      final latest = _database?.following(item.seriesKey, item.season);
      if (latest == null) continue;
      _database?.upsertFollowing(
        latest.copyWith(
          lastNotifiedEpisode: latest.lastNotifiedEpisode > item.releasedEpisode
              ? latest.lastNotifiedEpisode
              : item.releasedEpisode,
          lastNotifiedAtMs: nowMs,
          updatedAtMs: nowMs,
        ),
      );
    }
    if (batch.notice.isNotEmpty) {
      _followingNotice = batch.notice;
    } else if (_followingNotice.isNotEmpty) {
      // 发送恢复正常，清掉上一次的降级提示。
      _followingNotice = '';
    }
  }

  FollowingService? get _following {
    final database = _database;
    if (database == null) return null;
    return _followingService ??= FollowingService(
      database: database,
      resolveLines: _resolveFollowingLines,
      log: log,
    );
  }

  /// 追番列表。
  ///
  /// 会话内**首次**读取时补一次全量回写（见 [_primeFollowingProgressOnce]）：
  /// 上次运行留下的历史（含安卓同步写入的行）只有这一步能补成「已看」。
  List<Following> get followings {
    _primeFollowingProgressOnce();
    return _following?.all() ?? const [];
  }

  /// 会话内只跑一次的全量已看回写。
  ///
  /// 为什么放在「首次读列表」而不是每次 getter 都扫：这个 getter 每帧都会被
  /// 调到，全表扫描就是每帧一次库查询；一次性闸门让整条链路只扫一次。
  /// 为什么不用页面 `initState`：追番页不是唯一入口（侧栏徽标同样读列表），
  /// 闸门放在状态层才覆盖得住，UI 也不需要知道这件事。
  ///
  /// 同步执行：调用方紧接着读到的就是回写后的行，不需要再通知一次重建。
  bool _followingProgressPrimed = false;

  void _primeFollowingProgressOnce() {
    if (_followingProgressPrimed || _disposed || _database == null) return;
    _followingProgressPrimed = true;
    syncFollowingProgress();
  }

  /// 播放历史 → 已看集数回写服务（懒构造；只读本地库）。
  FollowingProgressService? get _followingProgress {
    final database = _database;
    if (database == null) return null;
    return _followingProgressService ??= FollowingProgressService(
      database: database,
      log: log,
    );
  }

  /// 把播放历史反推的「已看到第几集」写回追番（只增不减，不联网、不抛）。
  ///
  /// 触发点：`checkAllFollowings`（检查/刷新按钮）、`followingAirTimes`
  /// （追番列表、追剧日历读取前的刷新路径）、会话内首次读列表
  /// （[_primeFollowingProgressOnce]）与播放写库后的单剧回写
  /// （[_syncFollowingProgressAfterHistory]）。
  /// **不要**让 `followings` 每次调用都走到这里——那是每帧扫库。
  /// [items] 仅选择身份；回写前取最新库行，已删除的条目跳过。
  FollowingProgressSyncResult syncFollowingProgress({List<Following>? items}) {
    final service = _followingProgress;
    if (service == null) return FollowingProgressSyncResult.empty;
    final currentItems = items
        ?.map((item) => _database?.following(item.seriesKey, item.season))
        .whereType<Following>()
        .toList();
    final result = service.syncAll(items: currentItems);
    if (result.updated > 0) {
      log.info(
        '追番已看回写：updated=${result.updated}/scanned=${result.scanned}',
        scope: 'following',
      );
    }
    return result;
  }

  /// 当前追番的真实播出时间（TMDB 每集 `air_date`），供追剧日历归日使用。
  ///
  /// 未配置 TMDB、数据库未就绪或任何查询失败时返回空列表（日历退回本地推算），
  /// **不抛异常**；结果在服务内缓存，重复调用不会重复请求。
  Future<List<FollowingAirTime>> followingAirTimes() async {
    // 日历/列表读取前的刷新路径：先把历史里的已看进度落到库里，
    // 页面这一次 build 就能看到正确的「已看/未看」。
    syncFollowingProgress();
    final items = followings;
    if (items.isEmpty) return const [];
    final service = _ensureFollowingAirTimeService();
    if (service == null) return const [];
    try {
      return await service.airTimesFor(items);
    } catch (_) {
      return const [];
    }
  }

  /// 当前追番**官方该季总集数**（TMDB 该季剧集条数），供日历进度分母使用。
  ///
  /// 与 [followingAirTimes] 共享同一次取集请求与缓存；未配置 TMDB、数据库未
  /// 就绪或任何失败时返回空列表（调用方退回「线路可播集数」并标注来源），
  /// **不抛异常**。
  Future<List<FollowingSeasonTotal>> followingSeasonTotals() async {
    final items = followings;
    if (items.isEmpty) return const [];
    final service = _ensureFollowingAirTimeService();
    if (service == null) return const [];
    try {
      return await service.seasonTotalsFor(items);
    } catch (_) {
      return const [];
    }
  }

  /// 追剧日历平台徽标用的播放平台名（TMDB `networks`，与站点/站源无关）。
  ///
  /// 每部追番一次 `/tv/{id}` 剧集详情（磁盘缓存 7 天）；未配置 TMDB、无匹配、
  /// 超时或任何失败都只跳过该条，**不抛异常**，没拿到台名的条目也不进结果。
  Future<Map<String, List<String>>> followingNetworksFor(
    List<Following> items,
  ) async {
    if (items.isEmpty || !tmdbConfig.isReady) return const {};
    final result = <String, List<String>>{};
    for (var start = 0; start < items.length; start += _networksBatch) {
      final batch = items.skip(start).take(_networksBatch);
      final found = await Future.wait(batch.map(_followingNetworksForOne));
      for (final entry in found) {
        if (entry.value.isNotEmpty) result[entry.key] = entry.value;
      }
    }
    return result;
  }

  /// 兜底平台名的小并发上限：串行的 TMDB 请求会把日历拖到几十秒。
  static const int _networksBatch = 2;

  Future<MapEntry<String, List<String>>> _followingNetworksForOne(
    Following item,
  ) async {
    try {
      final tmdb = await followingTmdbItem(item);
      if (tmdb == null) return MapEntry(item.identityKey, const []);
      final detail = await tmdbService.detail(tmdb, includeRelated: false);
      return MapEntry(item.identityKey, tmdbNetworkNames(detail['networks']));
    } catch (_) {
      return MapEntry(item.identityKey, const []);
    }
  }

  /// 有未读更新消息的追番数量（侧栏红点）；发送通知不算已读。
  ///
  /// 方法名保留兼容 UI；卡片未看集数仍按已发布 − 已看计算。
  int get followingUpdateCount =>
      followings.where((item) => item.hasUnreadUpdate).length;

  bool isFollowing({required String siteKey, required String vodId}) =>
      _following?.byVod(siteKey, vodId) != null;

  Following? followingForVod({
    required String siteKey,
    required String vodId,
  }) => _following?.byVod(siteKey, vodId);

  /// 从详情页追番；已存在时只更新线路/海报/标题。
  Following? followFromDetail({
    required Site site,
    required Vod vod,
    String flag = '',
    String sourceFlag = '',
    int releasedEpisode = 0,
  }) {
    final service = _following;
    if (service == null) return null;
    final item = service.add(
      siteKey: site.key,
      vodId: vod.vodId,
      vodName: vod.vodName,
      vodPic: vod.vodPic,
      flag: flag,
      sourceFlag: sourceFlag,
      releasedEpisode: releasedEpisode,
      notifyEnabled: followingSettings.notifyEnabled,
    );
    log.info(
      '追番：${vod.vodName} site=${site.key} 已发布=$releasedEpisode',
      scope: 'following',
    );
    notifyListeners();
    return item;
  }

  Future<void> unfollowFollowing(Following item) async {
    _following?.remove(item);
    notifyListeners();
  }

  Future<void> markFollowingRead(Following item) async {
    _following?.markRead(item);
    notifyListeners();
  }

  /// per-item「新集通知」开关（UI 直接调用）。
  ///
  /// 只改这一条记录并落库；全局 `FollowingSettings.notifyEnabled` 的语义不变：
  /// 真正发通知仍需全局与条目同时开启（见 `shouldNotifyFollowing`）。
  Future<void> setFollowingNotifyEnabled(Following item, bool enabled) async {
    _following?.setNotifyEnabled(item, enabled);
    notifyListeners();
  }

  /// 用户从追番页/日历打开最新集后调用：只压已读水位，**不再冒充已看**。
  ///
  /// 已看集数改由播放历史回写（见 [syncFollowingProgress]）：真正播完会写
  /// 历史，这里顺手立刻回写一次，让列表马上反映进度。
  Future<void> markFollowingWatched(Following item) async {
    final read = _following?.markRead(item) ?? item;
    syncFollowingProgress(items: [read]);
    notifyListeners();
  }

  Future<FollowingCheckOutcome?> checkFollowing(Following item) async {
    final service = _following;
    if (service == null) return null;
    final outcome = await service.check(item);
    if (outcome.ok &&
        outcome.changed &&
        shouldNotifyFollowing(outcome.following)) {
      await _notifyFollowingNewEpisodes([outcome.following]);
    }
    _notifyIfAlive();
    return outcome;
  }

  Future<FollowingCheckSummary> checkAllFollowings({
    bool onlyDue = false,
  }) async {
    final service = _following;
    if (service == null) return FollowingCheckSummary.empty;
    // 检查流程本来就要读库：「检查更新」同时把历史里的已看进度回写，
    // 用户点一次按钮就能看到「已看 N / 未看 M」刷新。
    syncFollowingProgress();
    // 检查前后比较已发布集数：`checkAll` 只回计数，通知需要具体条目。
    final before = {
      for (final item in service.all()) item.identityKey: item.releasedEpisode,
    };
    final summary = await service.checkAll(onlyDue: onlyDue);
    if (summary.checked > 0) {
      log.info(
        '追番检查：checked=${summary.checked} changed=${summary.changed} '
        'failed=${summary.failed}',
        scope: 'following',
      );
      await _notifyFollowingNewEpisodes([
        for (final item in service.all())
          if (item.releasedEpisode > (before[item.identityKey] ?? 0) &&
              shouldNotifyFollowing(item))
            item,
      ]);
    }
    _notifyIfAlive();
    return summary;
  }

  /// 只读取追剧的原始站源详情，不切换当前站点或详情页状态。
  ///
  /// 目录条目（网盘聚合 `atvp_detail:`）按 folder 展开：拿壳去 `ids=` 只能拿到
  /// 没有线路的空壳，家页/追剧卡片的站源元数据就永远补不上。
  Future<Vod?> followingVod(Following item) => _readSiteVod(
    config: effectiveConfig,
    siteKey: item.siteKey,
    vodId: item.vodId,
    vodName: item.vodName,
    expandFolder: isBridgeFolderVodId(item.vodId),
  );

  /// 只读取一条历史行归属站点的详情，不切换当前站点或详情页状态。
  ///
  /// 首页读的是**全源**历史：跨源记录要按行自己的源找配置，用生效配置会找不到
  /// 那条记录所属的站点（历史补图踩过同一个坑，见 `HistoryPosterRepair`）。
  Future<Vod?> historyVod(PlaybackHistory row) => _readSiteVod(
    config: configForSourceKey(row.sourceKey) ?? effectiveConfig,
    siteKey: row.siteKey,
    vodId: row.vodId,
    vodName: row.vodName,
  );

  /// 按站点读一次详情（只读，不切站点）：历史元数据与追剧共用的取数口。
  ///
  /// [expandFolder] 为 true 时按目录条目（`t=<vod_id>`）展开成合并后的普通
  /// 详情：网盘聚合的 `atvp_detail:` 壳拿 `ids=` 去问只会得到没有线路的空壳
  /// （见 [isBridgeFolderVodId]）。
  Future<Vod?> _readSiteVod({
    required AppConfig? config,
    required String siteKey,
    required String vodId,
    required String vodName,
    bool expandFolder = false,
  }) async {
    final service = _siteService;
    if (config == null || service == null) return null;
    final site = config.sites
        .where((candidate) => candidate.key == siteKey)
        .firstOrNull;
    if (site == null) return null;
    await _waitForPythonSite(site);
    if (_disposed) return null;
    final result = expandFolder
        ? await service.folderDetail(site, Vod(vodId: vodId, vodName: vodName))
        : await service.detail(
            site,
            vodId,
            identity: VodIdentityHint(vodId: vodId, vodName: vodName),
          );
    // 部分线路失败只出现在 warnings 里：详情页据此报错并可重试，这条路径以前
    // 整段吞掉，追剧就会「静默换源」，日志里也查不到原因。
    for (final warning in result.warnings) {
      log.warning('站源详情部分线路加载失败 vod=$vodId ${warning.logLine}', scope: 'site');
    }
    return result.value.list.firstOrNull;
  }

  /// 站点详情 → 线路集数（供 `FollowingService` 调用）。
  ///
  /// 目录条目的展开由 [followingVod] 负责：追剧是从详情页追的，存下来的
  /// `vod_id` 就是网盘聚合的 `atvp_detail:` 壳，拿它去 `ids=` 详情只能拿到
  /// 没有线路的空壳——检查更新会据此误报「详情里没有可用线路」（真机日志
  /// 2026-11-22：详情页能播 5 条线路，追剧检查却报没线路）。
  Future<List<FollowingLineEpisodes>?> _resolveFollowingLines(
    Following item,
  ) async {
    final vod = await followingVod(item);
    if (vod == null) return null;
    final lines = playLinesOf(vod);
    // 追的那条线路不在最新详情里（换 provider 或重命名）时不再完全静默：
    // followingSnapshotFromLines 会退回第一条线路，日志必须留下这次换源。
    if (lines.isNotEmpty &&
        (item.flag.isNotEmpty || item.sourceFlag.isNotEmpty) &&
        !lines.any((line) => _isFollowedLine(item, line))) {
      log.warning(
        '追剧取数：追的线路已不在详情里 ${item.vodName} '
        'flag="${item.flag}" sourceFlag="${item.sourceFlag}" '
        'lines=${lines.map((line) => line.flag).join('|')}',
        scope: 'following',
      );
    }
    return [
      for (final line in lines)
        FollowingLineEpisodes(
          flag: line.flag,
          sourceFlag: line.sourceFlag ?? line.playbackFlag,
          episodeCount: line.episodes.length,
          latestEpisodeName: line.episodes.isEmpty
              ? ''
              : line.episodes.last.name,
          latestEpisodeTarget: line.episodes.isEmpty
              ? ''
              : line.episodes.last.url,
        ),
    ];
  }

  /// 该线路是否就是追剧记录里的那一条（展示名精确匹配优先，退回原始 flag）。
  bool _isFollowedLine(Following item, VodPlayLine line) =>
      (item.flag.isNotEmpty && line.flag == item.flag) ||
      (item.sourceFlag.isNotEmpty && line.sourceFlag == item.sourceFlag);

  /// 重启追番调度：应用运行期间按设置间隔检查到期条目。
  ///
  /// PC 没有后台服务/WorkManager，应用关闭后不会检查——这是与安卓的已知差异。
  /// [kickDelay] 是启动后补一次到期检查的延迟；`null` 表示不补（关闭自动检查时）。
  void _restartFollowingTimer({
    Duration? kickDelay = const Duration(seconds: 10),
  }) {
    _followingTimer?.cancel();
    _followingTimer = null;
    _followingKickTimer?.cancel();
    _followingKickTimer = null;
    if (!followingSettings.enabled || _database == null) return;
    final interval = Duration(minutes: followingSettings.intervalMinutes);
    _followingTimer = Timer.periodic(interval, (_) {
      unawaited(checkAllFollowings(onlyDue: true));
    });
    if (kickDelay == null) return;
    // 启动后延迟 10s 补一次到期检查，不阻塞首屏；改间隔时立即补。
    _followingKickTimer = Timer(kickDelay, () {
      unawaited(checkAllFollowings(onlyDue: true));
    });
  }

  @override
  void dispose() {
    _cancelSearchWork();
    _disposed = true;
    for (final entry in _backgroundYields.entries) {
      entry.key.cancel();
      entry.value.complete();
    }
    _backgroundYields.clear();
    progressRevision.dispose();
    revokeProxySession();
    unawaited(_pythonEnvironment.close());
    _detailRunId++;
    _followingTimer?.cancel();
    _followingKickTimer?.cancel();
    _followingService = null;
    _followingProgressService = null;
    _router.dispose();
    _importService.close();
    _liveService?.close();
    _epgService?.close();
    _recommendationDependencies?.close();
    _detailRatingService?.close();
    _externalMetaService?.close();
    _tmdbService.close();
    if (identical(TmdbImageHealth.onFailure, _imageHealthSink)) {
      TmdbImageHealth.onFailure = null;
    }
    _imageHealthSink = null;
    _lutStoreInstance?.dispose();
    // 联想/热搜的 HTTP 客户端同样要释放。
    _searchSuggestService?.close();
    // §22.2:退出后 sidecar 与代理端口全部释放。
    _sidecarShutdown = _supervisor.shutdownAll();
    unawaited(_sidecarShutdown);
    unawaited(_androidPlaybackBridge.close());
    unawaited(_proxy.stop());
    // 猫源 Node 进程树与 bundle 句柄同样必须随退出释放（§9.8）。
    _catPipeline?.close();
    // 同步服务端必须先停：退出后不得继续监听局域网端口（§28.4）。
    // 先摘掉转发监听再 dispose，避免 dispose 过程中的通知回调打到已释放的 AppState。
    syncState.removeListener(notifyListeners);
    syncState.dispose();
    _database?.dispose();
    if (_injectedUpdateService == null) _updateService?.close();
    log.dispose();
    super.dispose();
  }
}

/// 两处「待弹框」信号的单槽登记簿。
///
/// 单槽而不是队列：同一站点重复点击、同一批结果重复登记都只该剩下一个待弹框；
/// 排队就会变成「连点三次，弹三次」。state 层只登记，弹框时机归 UI。
class PendingShellUnpack {
  List<ShellTargetItem>? _prompt;
  String? _siteKey;

  /// 导入后待确认的解包提示。
  List<ShellTargetItem>? get prompt => _prompt;

  /// 待弹「确认解包」的站点 key。
  String? get siteKey => _siteKey;

  /// 登记导入提示；同一批条目重复登记返回 false（幂等，不叠加）。
  bool stagePrompt(List<ShellTargetItem> items) {
    if (items.isEmpty) return false;
    final current = _prompt;
    if (current != null && _sameTargets(current, items)) return false;
    _prompt = List<ShellTargetItem>.unmodifiable(items);
    return true;
  }

  /// 登记站点级确认；同一站点重复登记返回 false（幂等，不叠加）。
  bool stageSite(String key) {
    if (key.isEmpty || _siteKey == key) return false;
    _siteKey = key;
    return true;
  }

  List<ShellTargetItem>? takePrompt() {
    final prompt = _prompt;
    _prompt = null;
    return prompt;
  }

  String? takeSite() {
    final key = _siteKey;
    _siteKey = null;
    return key;
  }

  void clear() {
    _prompt = null;
    _siteKey = null;
  }

  static bool _sameTargets(List<ShellTargetItem> a, List<ShellTargetItem> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].jarUrl != b[i].jarUrl || a[i].stateLabel != b[i].stateLabel) {
        return false;
      }
    }
    return true;
  }
}
