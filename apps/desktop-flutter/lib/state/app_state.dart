/// 应用状态：编排配置导入、站点浏览、详情与播放（§4.2 Application Service 层）。
///
/// 约束：
/// - UI 不直接发网络请求，全部经由此处的服务；
/// - 任何失败都转为 [AppError]，由 UI 展示可定位提示，不阻塞界面；
/// - 存储不可用时降级为“无历史/无缓存”，不影响播放（§16.3）。
library;

import 'dart:async';

import '../core/detail_recommendation.dart';
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
import '../services/ai_content_title_bridge.dart';
import '../services/ai_episode_season_service.dart';
import '../core/app_error.dart';
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
import '../services/doh_resolver.dart';
import '../services/following_progress_service.dart';
import '../services/following_service.dart';
import '../services/following_air_time_service.dart';
import '../services/notification_service.dart';
import '../services/session_recovery_store.dart';
import '../core/history_aggregation.dart';
import '../core/history_grouping.dart';
import '../core/history_scope.dart';
import '../core/history_view.dart';
import '../core/live_settings.dart';
import '../core/http_api.dart';
import '../core/osd_config.dart';
import '../core/playback.dart';
import '../core/playback_diagnostics.dart';
import '../core/player_buttons.dart';
import '../core/outbound_proxy.dart';
import '../core/parse_failover.dart';
import '../core/player_options.dart';
import '../core/player_tracks.dart';
import '../core/protocol.dart';
import '../core/proxy_policy.dart';
import '../core/realtime_sync.dart';
import '../core/source_key.dart';
import '../core/site_group.dart';
import '../core/site_injection.dart';
import '../core/site_group_rules.dart';
import '../core/site_order.dart';
import '../core/skip_segments.dart';
import '../core/subtitle_provider.dart';
import '../core/subtitle_settings.dart';
import '../core/tmdb_config.dart';
import '../core/tmdb_identity.dart';
import '../core/tmdb_playback.dart';
import '../core/tmdb_season.dart';
import '../services/app_paths.dart';
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
import '../services/site_service.dart';
import '../services/spider_process.dart';
import '../services/spider_registry.dart';
import '../services/spider_router.dart';
import '../services/ai_config_store.dart';
import '../services/detail_rating_service.dart';
import '../services/storage.dart';
import '../services/sync_client.dart';
import '../services/sync_server.dart';
import '../services/tmdb_cache.dart';
import '../services/tmdb_config_store.dart';
import '../services/ui_preferences_store.dart';
import '../services/web_home_store.dart';
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
const String appBuildFlavor = 'MVP-A (Windows)';

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
    PythonEnvironment? pythonEnvironment,
  }) : paths = paths ?? AppPaths.resolve(),
       _injectedPythonEnvironment = pythonEnvironment,
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
        TmdbService(config: () => _tmdbConfigStore.config, cache: _tmdbCache);
    final node = SidecarRuntimeResolver.resolve('node');
    if (node != null) {
      _catRuntime = CatNodeRuntime(nodeCommand: node, log: this.log);
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

  /// 本地源扫描器（只读、不执行）。无状态，参数取自 [LocalSpiderScanner] 默认值。
  final LocalSpiderScanner _localScanner = const LocalSpiderScanner();

  /// 上次扫描的文件夹（仅本次会话记忆，避免用户每次重新选）。
  String _lastLocalScanFolder = '';

  /// 本地代理(§11)。默认只监听 127.0.0.1,按需启动。
  late final LocalProxyServer _proxy;

  /// 本次播放的代理会话（§11.3.1）。
  ProxySession? _proxySession;

  AppDatabase? _database;

  /// 直连 js/py 站点自动注册器（Phase 9 P1-7）。每次调用新建，内部无状态。
  DirectSpiderRegistrar _directRegistrar() => DirectSpiderRegistrar(
    root: _spiderRegistry.root,
    registry: _spiderRegistry,
    log: log,
  );

  /// 扫描配置里的直连 js/py 站点并注册（幂等；哈希一致不重复下载）。
  Future<int> registerDirectSpiders() async {
    final config = effectiveConfig;
    if (config == null) return 0;
    final result = await _directRegistrar().materialize(config);
    _router.setDirectSpiders(result);
    _attachSiteService();
    notifyListeners();
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

  /// 登记表严格读取失败的原因；内部降级不代表登记表为空，也不会写回。
  String? get webHomeLoadError => _webHomeLoadError;

  Map<String, WebHomeSource> _safeWebHomeSources() {
    final cached = _webHomeSourcesCache;
    if (cached != null) return cached;
    try {
      final sources = _webHomeStore.list();
      _webHomeLoadError = null;
      return _webHomeSourcesCache = {
        for (final source in sources)
          if (source.enabled) source.key: source,
      };
    } on FormatException catch (error) {
      _webHomeLoadError = '载入HTML源失败：$error';
    } on FileSystemException catch (error) {
      _webHomeLoadError = '载入HTML源失败：$error';
    }
    log.error(_webHomeLoadError!, scope: 'site');
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

  late TmdbConfigStore _tmdbConfigStore;

  /// AI 配置（`docs/phase6/design/04` §4）。
  ///
  /// 与 `_tmdbConfigStore` 同构（两者都是 `settings.json` 里带凭据的独立段）。
  /// `late final`：在 `bootstrap` 里装配；未 bootstrap 时访问会抛
  /// `LateInitializationError`——与 TMDB 一致（单测走 `attachAiConfigStore`
  /// 或 `bootstrap`）。
  late AiConfigStore _aiConfigStore;

  /// UI 偏好（最近使用的站点）。在 [bootstrap] 里装配。
  ///
  /// 可空而不是 `late final`：单元测试/工具可能**不调 bootstrap** 就直接
  /// `importConfig` + `selectSite`（实测 `phase2_search_test.dart` 就是这样），
  /// 用 `late final` 会在 `selectSite` 里抛 `LateInitializationError`。
  /// 记住站点只是**锦上添花**，它不可用时应安静降级，而不是把选站点弄崩。
  UiPreferencesStore? _uiPreferences;
  final List<ExternalPlayer> Function() _externalPlayerDetector;
  late final TmdbService _tmdbService;

  /// TMDB 磁盘缓存（文件落在 `TmdbCache.directory` = `<cache>/tmdb`）。
  ///
  /// 为什么在这里留一份引用：`TmdbService` 不暴露它手里的缓存实例，而「缓存到底
  /// 接没接上」正是这次修复的核心——历史上就是构造服务时漏了 `cache` 参数，
  /// 整个磁盘缓存静默失效而没人发现。测试只能从这里断言接线真的发生了。
  late final TmdbCache _tmdbCache;

  /// 仅供测试：断言 TMDB 服务确实拿到了磁盘缓存（目录指向 [paths] 的缓存根）。
  @visibleForTesting
  TmdbCache get tmdbCacheForTest => _tmdbCache;
  TmdbIdentityService? _tmdbIdentityService;
  TmdbSeasonService? _tmdbSeasonService;
  TmdbEnrichmentService? _tmdbEnrichmentService;
  TmdbState? _tmdbState;

  /// TMDB 设置（当前生效）。
  TmdbConfig get tmdbConfig => _tmdbConfigStore.config;

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
    notifyListeners();
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
    notifyListeners();
    return ok;
  }

  Future<bool> setAiAdDetectionEnabled(bool enabled) async {
    final ok =
        await _uiPreferences?.rememberAiIntegrationSettings({
          'ai_ad_detection': enabled,
        }) ??
        false;
    if (!enabled) clearAiAdApplication();
    notifyListeners();
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
    notifyListeners();
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
  String _aiLineKey(Vod vod, VodPlayLine line) =>
      '$tmdbConfigId|$_aiTmdbSiteKey|${vod.vodId}|${vod.vodName}|${line.flag}';
  VodPlayLine applyAiMappingsToLine(Vod vod, VodPlayLine line) {
    final result = aiMappingsFor(vod, line);
    if (result == null) return line;
    return applyAiEpisodeBindings(line, {
      for (final binding in result.bindings)
        binding.sourceIndex: (
          season: binding.seasonNumber,
          episode: binding.episodeNumber,
        ),
    });
  }

  bool hasAiMappings(Vod vod, VodPlayLine line) =>
      aiMappingsFor(vod, line)?.bindings.isNotEmpty ?? false;
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
      _aiSeasonBindings[_aiLineKey(vod, line)] = result;
      _aiSeasonSnapshots[_aiLineKey(vod, line)] = seasonBindingsSnapshot(
        line.episodes,
        tmdb.seasonEpisodeCounts,
      );
    }
    notifyListeners();
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
  /// **API Key 不得进日志**（Global Constraints）：只记脱敏值与就绪状态。
  Future<bool> saveAiConfig(AiConfig config) async {
    final saved = await _aiConfigStore.save(config);
    if (!config.isReady) clearAiAdApplication();
    if (saved) {
      log.info(
        'AI 设置已更新 enabled=${config.enabled} '
        'protocol=${config.protocol} ready=${config.isReady} '
        'key=${config.redactedApiKey}',
        scope: 'ai',
      );
    } else {
      log.warning('AI 设置保存失败（内存已生效）', scope: 'ai');
    }
    notifyListeners();
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
                _recommendationSeedForHistory(row),
            ],
          );

  RecommendationSeed _recommendationSeedForHistory(PlaybackHistory row) {
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
  AppDatabase? get database => _database;
  ConfigRecord? get activeRecord => _activeRecord;
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
    notifyListeners();
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
    notifyListeners();
    return ok;
  }

  /// 持久化播放器按钮隐藏集。
  Future<bool> setPlayerButtonHidden(Set<String> hidden) async {
    final store = _uiPreferences;
    if (store == null) return false;
    final ok = await store.rememberButtonHidden(hidden);
    notifyListeners();
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
    if (ok) notifyListeners();
    return ok;
  }

  /// 外部播放器是否已配置可用。
  bool get hasExternalPlayer => externalPlayerPath != null;

  /// 持久化外部播放器路径。传空串等于清除配置。
  Future<bool> setExternalPlayerPath(String? path) async {
    final store = _uiPreferences;
    if (store == null) return false;
    final ok = await store.rememberExternalPlayerPath(path);
    notifyListeners();
    return ok;
  }

  /// 恢复播放器按钮排版默认。
  Future<bool> resetPlayerButtons() async {
    final store = _uiPreferences;
    if (store == null) return false;
    final ok = await store.resetPlayerButtons();
    notifyListeners();
    return ok;
  }

  /// 生效的播放参数（Phase 9）。
  ///
  /// `_uiPreferences` 为 null（未 bootstrap）时返回默认值，不让播放器失败。
  PlayerOptions get playerOptions =>
      _uiPreferences?.playerOptions ?? const PlayerOptions.defaults();

  /// 生效的弹幕显示样式（Phase 9 P0-7）。
  DanmakuStyle get danmakuStyle =>
      _uiPreferences?.danmakuStyle ?? DanmakuStyle.defaults;

  /// 生效的直播设置（Phase 9）。
  LiveSettings get liveSettings =>
      _uiPreferences?.liveSettings ?? const LiveSettings.defaults();

  /// 生效的字幕源设置（Phase 9）。
  SubtitleSettings get subtitleSettings =>
      _uiPreferences?.subtitleSettings ?? SubtitleSettings();

  /// 生效的站点排序偏好（Phase 9）。
  SiteOrderSettings get siteOrder =>
      _uiPreferences?.siteOrder ?? const SiteOrderSettings.defaults();

  /// 直连站源注册的进行中 Future（null 表示未发起或已作废）。
  ///
  /// 首屏抢跑缺陷（2026-10-24 实测）：[_attachSiteService] 先 unawaited 发起注册，
  /// 紧接着就装配好 [_siteService]，首页在注册落定前就发 home。此时
  /// classifySite 对 csp_PyProxy 这类站点会落到「PC Java Spider 未支持」，
  /// 用户看到一次红横幅，而注册完成后**没有任何代码重放首页**。
  /// 修复：注册发起时保存 Future，首页在这类站点上等它落定（等待是顺序问题，
  /// 不是耗时问题——实测注册只要 116 ms 也照样抢跑）。
  Future<void>? _directReady;

  /// 等待直连站源注册的上限。超时后按现状继续（不得把真实崩溃伪装成等待）。
  static const Duration _directReadyTimeout = Duration(seconds: 8);

  bool _disposed = false;

  /// 发起直连站源注册并保存 Future（幂等：已有进行中的注册沿用同一 Future）。
  void _kickDirectRegistration() {
    final pending = _directReady;
    if (pending != null) {
      unawaited(pending);
      return;
    }
    final future = _registerDirectSpidersQuietly();
    _directReady = future;
    unawaited(future);
  }

  /// 等直连站源注册落定（仅当该站点确实依赖注册结果时调用）。
  Future<void> _waitForDirectRegistration() async {
    final pending = _directReady;
    if (pending == null) return;
    try {
      await pending.timeout(_directReadyTimeout);
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
  /// host.py 记一行 stderr 后 return 3，用户只会看到「sidecar 意外退出 code=3」。
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
      notifyListeners();
    }
  }

  Future<bool> _changePythonEnvironment(Future<bool> Function() action) async {
    final pending = action();
    if (!_disposed) notifyListeners();
    final ok = await pending;
    if (!_disposed) {
      if (ok) _applyPythonEnvironment();
      notifyListeners();
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

  Future<void> _registerDirectSpidersQuietly() async {
    try {
      final config = effectiveConfig;
      if (config == null) return;
      final hasDirect = config.sites.any(
        (site) => directSpiderKind(site) != null,
      );
      if (!hasDirect) {
        _router.setDirectSpiders(const {});
        return;
      }
      final result = await _directRegistrar().materialize(config);
      _router.setDirectSpiders(result);
      // 站点可用性变了：重算列表（不重建路由缓存之外的状态）。
      notifyListeners();
    } catch (error) {
      log.warning('直连站源注册失败：$error', scope: 'spider');
    } finally {
      // 注册落定后清空：下一次配置装配/数据交换要能重新发起（幂等缓存由注册器
      // 自己的哈希比对保证），同时让首屏等待者立刻放行。
      _directReady = null;
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
    notifyListeners();
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
    notifyListeners();
    return ok;
  }

  /// 隐身模式（Phase 9 P2-8）：不写播放历史与搜索记录。
  bool get incognito => _uiPreferences?.incognito ?? false;

  /// 持久化隐身模式。
  Future<bool> setIncognito(bool value) async {
    final store = _uiPreferences;
    if (store == null) return false;
    final ok = await store.rememberIncognito(value);
    notifyListeners();
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
    notifyListeners();
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
    notifyListeners();
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
    _localSitesCache = null;
    _webHomeSourcesCache = null;
    _effectiveConfigCache = null;
    // 站点服务与分类判定都读 effectiveConfig：重建它，本地源才能立刻可选/可用。
    _attachSiteService();
    notifyListeners();
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
    notifyListeners();
    return ok;
  }

  /// 持久化站点排序偏好。
  Future<bool> setSiteOrder(SiteOrderSettings settings) async {
    final store = _uiPreferences;
    if (store == null) return false;
    final ok = await store.rememberSiteOrder(settings);
    notifyListeners();
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
    notifyListeners();
    return ok;
  }

  /// 持久化字幕源设置。
  Future<bool> setSubtitleSettings(SubtitleSettings settings) async {
    final store = _uiPreferences;
    if (store == null) return false;
    final ok = await store.rememberSubtitleSettings(settings);
    notifyListeners();
    return ok;
  }

  /// 持久化直播设置。
  Future<bool> setLiveSettings(LiveSettings settings) async {
    final store = _uiPreferences;
    if (store == null) return false;
    final ok = await store.rememberLiveSettings(settings);
    notifyListeners();
    return ok;
  }

  /// 持久化播放参数。写盘失败不影响当前会话，但都通知 UI 重建。
  Future<bool> setPlayerOptions(PlayerOptions options) async {
    final store = _uiPreferences;
    if (store == null) return false;
    final ok = await store.rememberPlayerOptions(options);
    notifyListeners();
    return ok;
  }

  /// 持久化弹幕显示样式（Phase 9 P0-7）。写盘失败不影响当前会话。
  Future<bool> setDanmakuStyle(DanmakuStyle style) async {
    final store = _uiPreferences;
    if (store == null) return false;
    final ok = await store.rememberDanmakuStyle(style);
    notifyListeners();
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
    notifyListeners();
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
    notifyListeners();
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
    notifyListeners();
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
    notifyListeners();
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
    notifyListeners();
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

  /// 站点列表(含运行时可用性),隐藏 `hide=1` 的站点。
  ///
  /// 使用实例级 [SpiderRouter.classifySite] 而非静态 [SpiderRouter.classify],
  /// 才能对 `spider-local:` 站点给出真实可用性(§8.1、§9.7)。
  List<SiteListItem> get siteItems {
    final config = effectiveConfig;
    if (config == null) return const [];
    return config.sites
        .where((site) => !site.hide)
        .map(
          (site) => SiteListItem(
            site: site,
            // HTML 首页不是爬虫：不能交给路由判可用性（会报「manifest 未注册」，
            // 而真实原因是它由 WebView2 承载）。走路由前先识别这一形态。
            availability: webHomeSourceForSite(site) != null
                ? webHomeSiteAvailability
                // §8.1:可用性判定必须区分「运行时未安装」与「站点不可用」,
                // 因此这里用带注册表的实例方法，而不是静态 `classify`。
                : _router.classifySite(site),
          ),
        )
        .toList();
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
    _tmdbConfigStore = TmdbConfigStore(path: paths.settingsPath, log: log);
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
    var architecture = Platform.version.split(' ').first;
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
    // 追番调度：应用运行期间生效；关闭时不会创建定时器（测试也不会残留 Timer）。
    _restartFollowingTimer();
    notifyListeners();
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
      notifyListeners();
      return failures.isEmpty
          ? '写入恢复文件失败：$error'
          : '写入恢复文件失败：$error；回滚未完成：${failures.join(',')}'
                '（原始副本：${recovery.path}）';
    }
    await recovery.delete();

    await bootstrap();
    notifyListeners();
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
      notifyListeners();
      return '删除本地数据失败：$error';
    }
    await bootstrap();
    notifyListeners();
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
    config: () => _tmdbConfigStore.config,
    service: _tmdbService,
    identityService: _ensureTmdbIdentityService(),
    seasonService: _ensureTmdbSeasonService(),
    enrichmentService: _ensureTmdbEnrichmentService(),
    isCurrentRun: () => _tmdbRunId == _detailRunId,
  );

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
    if (vod == null || site == null || _database == null) return;
    _tmdbRunId = _detailRunId;
    await _loadTmdbWithAi(
      vod,
      siteKey: site.key,
      siteName: site.name,
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
  bool _navSourceFor(Site site, Vod vod) =>
      site.indexs == 1 || vod.vodId.isEmpty;

  TmdbIdentity? _knownIdentityWithoutPlayback(Site site, Vod vod) {
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
              siteKey: site.key,
              sourceTitle: vod.vodName,
            )
        ? tmdb.identity
        : null;
  }

  TmdbIdentityService _ensureTmdbIdentityService() =>
      _tmdbIdentityService ??= TmdbIdentityService(
        config: () => _tmdbConfigStore.config,
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
      isConfigured: () => _tmdbConfigStore.config.isReady,
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
        config: () => _tmdbConfigStore.config,
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

  /// 保存 TMDB 设置（设置页「保存」；原子写，`03` §5.5）。
  Future<bool> saveTmdbConfig(TmdbConfig config) async {
    final saved = await _tmdbConfigStore.save(config);
    if (saved) {
      _tmdbConfigRevision++;
      log.info(
        'TMDB 设置已更新 enabled=${config.enabled} ready=${config.isReady} '
        'lang=${config.language} '
        'key=${config.redactedApiKey} token=${config.redactedAccessToken}',
        scope: 'tmdb',
      );
    } else {
      _lastError = AppError(AppErrorKind.storage, 'TMDB 设置保存失败');
    }
    notifyListeners();
    return saved;
  }

  /// 测试连接（`04` §10.2）：调 `/configuration`，返回结构化结果。
  Future<String> testTmdbConnection() async {
    final config = _tmdbConfigStore.config;
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

  /// 手动匹配（`01` §7、`04` §5.1）。成功后刷新详情页 TMDB 区块。
  Future<TmdbMatchOutcome?> matchTmdbManual({
    required TmdbItem item,
    String? sourceTitle,
  }) async {
    final identityService = _tmdbIdentityService;
    final vod = _selectedVod;
    final site = _selectedSite;
    if (identityService == null || vod == null || site == null) return null;
    try {
      final outcome = await identityService.matchManual(
        request: TmdbMatchRequest(
          siteKey: site.key,
          vodId: vod.vodId,
          sourceTitle: sourceTitle ?? vod.vodName,
        ),
        item: item,
      );
      await learnBusinessTitle(
        rawTitle: vod.vodName,
        confirmedTitle: item.title,
        siteKey: site.key,
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
    // 配置/注入变化后重新合并（缓存只在同一次装配内有效）。
    _effectiveConfigCache = null;
    // 配置可能带来新的 `doh`/`hosts`：先刷新出站传输（内部有输入签名，未变不重建）。
    _applyOutboundProxy();
    final config = effectiveConfig;
    if (config == null) {
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
    // csp_* 站点：配置里声明的 jar 若指向远端地址，自动取回并静态检测。
    // 能加载的自动装好；不能加载的把结论写进 probe.json，列表与详情直接回显
    // 原因（用户诉求 2026-10-24「迁移不该让用户自己做」）。同样不阻塞首屏。
    unawaited(_probeCspJarsQuietly());
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
      if (remembered != null && webHomeKeyOfSite(remembered) == null) {
        _selectedSite = remembered;
        log.info(
          '恢复上次使用的站点 site=${remembered.key.isEmpty ? remembered.name : remembered.key}',
          scope: 'site',
        );
      }
    }
    final defaultSite = config.defaultSite();
    _selectedSite ??=
        defaultSite != null && webHomeKeyOfSite(defaultSite) == null
        ? defaultSite
        : config.sites
              .where((site) => !site.hide && webHomeKeyOfSite(site) == null)
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
    notifyListeners();

    try {
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

      _config = config;
      _importDiagnosticsSummary = imported.diagnostics.isEmpty
          ? null
          : imported.diagnostics.join('；');
      // 旧配置的详情请求必须作废：配置换了之后返回的详情属于另一个站点
      // （§7.4.1 导入即切换）。
      _detailRunId++;
      // 选中站点必须属于新配置（§7.4.1 导入即切换）：`_attachSiteService` 会按 key
      // 校验归属，不属于当前配置的选中项退回新配置的默认站点。
      //
      // 注意不能无条件置空：用户重新导入**同一份**配置（刷新）时应留在原站点；
      // 也不能继续用 `??=`：实测导入猫源后仍选中旧配置的 `csp_PianDan`，首页直接
      // siteUnsupported，用户看到「一个站点都加载不出数据」。
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

      final name = displayName ?? config.name ?? source.displayName;
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
        sourceKey: LocalSourceKey.of(imported.origin),
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

      _notice = config.notice ?? '配置导入成功：${config.sites.length} 个站点';
      _configPhase = LoadPhase.ready;
      log.info(
        '配置导入成功 name=$name sites=${config.sites.length} '
        'lives=${config.lives.length} headers=${config.headers.length} '
        'origin=${redactUrl(imported.origin)}',
        scope: 'config',
      );
      if (_importDiagnosticsSummary != null) {
        log.warning('导入诊断：$_importDiagnosticsSummary', scope: 'config');
      }
      notifyListeners();

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
      notifyListeners();
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
      notifyListeners();
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
    final config = imported.config;
    if (config == null) {
      _lastError = AppError(
        AppErrorKind.configInvalid,
        '新地址没有可用配置',
        detail: redactUrl(trimmedOrigin),
      );
      notifyListeners();
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
    );
    database.saveConfigSites(id, config.sites);
    _configs = database.listConfigs();
    _activeRecord = database.activeConfig();
    if (_activeRecord?.id == id) {
      _rememberLastConfig(_activeRecord!);
      await _reloadActiveConfigContent(config);
    }
    notifyListeners();
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
      notifyListeners();
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

    final interfaceKey = record.bridgeInterfaceKey.trim();
    if (interfaceKey.isNotEmpty) {
      // 桥接源的内容在安卓设备上：先找设备地址，再按 interfaceKey 精确重拉。
      // 不探测整台设备的全部源，否则刷新一条会顺带改写别的源。
      final deviceUuid = record.bridgeDevice.trim();
      final address = deviceUuid.isEmpty
          ? ''
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
        interfaceKey: interfaceKey,
      );
      if (!ok) {
        // 失败时数据库里那条记录仍然完好（importSites 只在成功时才 upsert）。
        _lastError =
            syncState.lastError ??
            AppError(
              AppErrorKind.bridgeUnreachable,
              '该播放源刷新失败',
              detail: redactUrl(address),
            );
        notifyListeners();
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
      notifyListeners();
      return true;
    }

    final imported = await _fetchConfigForRefresh(record.origin);
    if (imported == null) return false;
    final config = imported.config;
    if (config == null) {
      _lastError = AppError(
        AppErrorKind.configInvalid,
        '来源没有可用配置',
        detail: redactUrl(record.origin),
      );
      notifyListeners();
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
    );
    database.saveConfigSites(id, config.sites);
    _configs = database.listConfigs();
    _activeRecord = database.activeConfig();
    if (_activeRecord?.id == id) {
      await _reloadActiveConfigContent(config);
    }
    notifyListeners();
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

  /// 当前生效配置的内容变了：重建配置与站点服务，并重挂首页。
  ///
  /// 只在**改动打到生效记录**时调用——否则会把用户正在看的站点列表清空。
  Future<void> _reloadActiveConfigContent(AppConfig config) async {
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
    database.deleteConfig(id);
    _configs = database.listConfigs();
    if (_activeRecord?.id == id) {
      _activeRecord = database.activeConfig();
      final record = _activeRecord;
      if (record != null && record.json.isNotEmpty) {
        _config = parseConfigRecord(record.json);
        _attachSiteService();
        _detailRunId++;
        _detailResult = null;
        _detailError = null;
      } else {
        _config = null;
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
    final service = _siteService;
    if (service == null) return;
    final runId = ++_homeRunId;
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
      await _waitForDirectRegistration();
      if (!current()) return;
    }
    await _waitForPythonSite(site);
    if (!current()) return;
    _contentPhase = LoadPhase.loading;
    _lastError = null;
    if (current()) notifyListeners();
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
    if (current()) notifyListeners();
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
    notifyListeners();
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
    notifyListeners();
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
        notifyListeners();
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

  /// 换源解析：拿一个**指定站点**的详情，解析出它自己的线路。
  ///
  /// 找不到站点或详情里没有线路时如实抛错/返回空列表，由浮层显示「无分集」；
  /// 绝不伪造一条线路——用户点下去播放会直接失败，比当下说清楚更难排查。
  Future<List<VodPlayLine>> swapProbe({
    required String siteKey,
    required String vodId,
    String vodName = '',
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
    if (_disposed) return const [];
    final outcome = await service.detail(
      site,
      vodId,
      identity: VodIdentityHint(vodId: vodId, vodName: vodName),
    );
    if (outcome.value.list.isEmpty) return const [];
    return playLinesOf(outcome.value.list.first);
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
    final allItems = [
      for (final item in siteItems)
        if (_inSearchScope(item.site, scopeSiteKey, scopeGroup)) item,
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
    );
    // 新批次从第 1 页开始：分页状态必须清空，否则会沿用上一批次的页码。
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
          final value = await service
              .search(site, keyword: keyword, quick: quick, useCache: true)
              .timeout(timeout);
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
          notifyListeners();
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
    notifyListeners();
    return outcome;
  }

  /// 取消当前并发搜索（§14.1「可取消搜索」）。
  ///
  /// 只让批次失效；在途请求由各自的 timeout 兜底，且其完成结果不再投递。
  /// 保留 [_activeSearch] 指针，UI 才能显示“已取消”而不是退回空白提示。
  void cancelSearch() {
    final active = _activeSearch;
    if (active == null || active.finished) return;
    active.cancelled = true;
    active.finished = true;
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

    try {
      final value = await service
          .search(
            site,
            keyword: outcome.keyword,
            page: requestedPage,
            useCache: true,
            // 分页请求**不得**参与 `(关键词, 站点)` 搜索缓存：那个键只代表第 1 页。
            // 走缓存时实测两个真缺陷：命中第 1 页缓存 → 内容指纹重复被误判
            // 「已耗尽」；以及把第 N 页结果写进第 1 页的缓存键。
            cache: false,
          )
          .timeout(timeout);
      // 批次被取代 / 取消：丢弃结果，但**必须**把在途登记清掉，
      // 否则该站点永远被当成「有在途请求」而无法再翻页。
      if (outcome.cancelled || !identical(_activeSearch, outcome)) {
        _searchPaging.cancelPending();
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
        notifyListeners();
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
      notifyListeners();
      return true;
    } catch (error) {
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
      notifyListeners();
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
    final service = serviceOverride ?? _siteService;
    final site = siteOverride ?? _selectedSite;
    if (site == null) return;
    // 合成条目（推荐回退页）没有任何站源身份：拿空 `vod_id` 去请求详情只会换来
    // 一条业务错误，所以干脆不发请求，只跑 TMDB 链（见下面的 early return）。
    final synthetic = vod.vodId.isEmpty;
    if (service == null && !synthetic) return;
    final runId = ++_detailRunId;
    await _waitForPythonSite(site);
    if (_disposed || runId != _detailRunId) return;
    _detailRequestVodId = vod.vodId;
    _selectedVod = vod;
    _detailResult = null;
    _detailError = null;
    _detailPhase = LoadPhase.loading;
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
      siteKey: site.key,
      siteName: site.name,
      configId: tmdbConfigId,
      lines: playLinesOf(vod),
      // `indexs == 1` 是用户拍板的导航源判据（`Site.indexs`）；合成条目另算，
      // 见 [_navSourceFor]。其余站点一律按普通站点加载，行为与以前逐字一致。
      navSource: _navSourceFor(site, vod),
      knownIdentity: _knownIdentityWithoutPlayback(site, vod),
    );
    notifyListeners();
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
      notifyListeners();
      return;
    }
    if (service == null) return;
    try {
      // folder 先取 t=<vod_id> 的资源，再逐个取 ids=<分享链> 的分集。
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
      _detailResult = outcome.value;
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
      final effective = outcome.value.list.firstOrNull ?? vod;
      _selectedVod = effective;
      // 站源详情已经可用：先推一次通知，让线路/选集立刻渲染出来。后面的 TMDB 收尾
      // 即使要等，也不能把列表压在「加载中」里（那就等于把并行的收益又交回去了）。
      notifyListeners();
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
    notifyListeners();
  }

  /// 清空详情错误（详情页「重试」后的提示关闭）。
  void clearDetailError() {
    if (_detailError == null) return;
    _detailError = null;
    notifyListeners();
  }

  List<VodPlayLine> playLinesOf(Vod vod) => parseVodPlayLines(vod);

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

    /// 用哪份配置的服务解析。`null` = 生效配置（既有行为）；原来源续播时传
    /// 那份配置自己的服务（见 [playbackContextFor]），这样请求头/解析规则/
    /// 运行时都来自它，不会串到当前配置。
    SiteService? serviceOverride,
  }) async {
    final service = serviceOverride ?? _siteService;
    // 本次解析用的站点：覆盖优先，之后所有分支（service/proxy/日志）共用它。
    final site = siteOverride ?? _selectedSite;
    if (service == null || site == null) return null;
    await _waitForPythonSite(site);
    if (_disposed) return null;
    try {
      final outcome = await service.resolvePlayback(
        site: site,
        episodeTarget: episodeTarget,
        flag: flag,
        vodId: vodId,
        qualityIndex: qualityIndex,
        parseFailover: parseFailoverSettings,
      );
      // 过期响应（用户已切到别的画质/线路）不得改动全局播放状态：撤销旧 token 会
      // 连带把**新**会话作废，写 lastDecision 会把播放器指回旧画质。
      if (_isStale(isCurrent)) return null;
      // 退出旧会话并接入本地代理：Header 注入与 Range 都经同一 token 校验（§9.6、§11.3.1）。
      revokeProxySession();
      final decision = await proxyDecision(
        outcome.value,
        siteKey: site.key,
        isCurrent: isCurrent,
      );
      if (_isStale(isCurrent)) return null;
      _lastDecision = decision;
      _lastError = null;
      log.info(
        '播放决策 ${decision.logLine} site=${site.key} '
        'elapsed=${outcome.latency.inMilliseconds}ms',
        scope: 'playback',
      );
      notifyListeners();
      return decision;
    } catch (error) {
      // 过期请求的失败同样不是「当前播放失败」，交给 UI 丢弃（不写 lastError）。
      if (_isStale(isCurrent)) return null;
      final failure = error is AppError
          ? error
          : AppError(AppErrorKind.unknown, '$error', cause: error);
      _lastError = failure;
      log.error(
        '播放决策失败 site=${site.key} ${failure.logLine}',
        scope: 'playback',
      );
      notifyListeners();
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

  /// 按 `source_key` 取那份配置（只读）。
  ///
  /// 历史补图要用记录**自己的**配置找站点：跨源记录挂在非生效配置上，拿
  /// [config] 会找不到站点，补图永远不执行。空 `sourceKey`（迁移前老记录）
  /// 返回 null，由调用方退回生效配置。
  AppConfig? configForSourceKey(String sourceKey) {
    final key = sourceKey.trim();
    if (key.isEmpty) return null;
    try {
      return _database?.configBySourceKey(key)?.config;
    } catch (_) {
      return null;
    }
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
        return null;
      }
      record = found;
    } catch (error) {
      log.warning('读取来源配置失败 source=$key error=$error', scope: 'history');
      return null;
    }
    final cached = _playbackContexts[key];
    if (cached != null &&
        cached.record.id == record.id &&
        cached.record.updatedAt == record.updatedAt) {
      return cached;
    }
    final config = record.config;
    if (config == null || config.sites.isEmpty) {
      _playbackContexts.remove(key);
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
      cspBinding: _cspBinding,
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
      final result = await _directRegistrar().materialize(config);
      router.setDirectSpiders(result);
    } catch (error) {
      log.warning('原来源配置的直连站源注册失败：$error', scope: 'spider');
    }
  }

  /// 某条历史所属配置里的站点（找不到返回 `null`，调用方据此回退）。
  Site? siteForSourceKey(String sourceKey, String siteKey) =>
      playbackContextFor(sourceKey)?.siteByKey(siteKey);

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
  }) async {
    final context = playbackContextFor(sourceKey);
    final site = context?.siteByKey(siteKey);
    if (context == null || site == null) return null;
    await _waitForPythonSite(site);
    if (_disposed || _isStale(isCurrent)) return null;
    final outcome = await context.service.resolvePlayback(
      site: site,
      episodeTarget: episodeTarget,
      flag: flag,
      vodId: vodId,
      qualityIndex: qualityIndex,
      parseFailover: parseFailoverSettings,
    );
    if (_isStale(isCurrent)) return null;
    revokeProxySession();
    final decision = await proxyDecision(
      outcome.value,
      siteKey: site.key,
      isCurrent: isCurrent,
    );
    if (_isStale(isCurrent)) return null;
    log.info(
      '原来源播放决策 ${decision.logLine} source=$sourceKey site=${site.key} '
      'elapsed=${outcome.latency.inMilliseconds}ms',
      scope: 'playback',
    );
    return decision;
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
    try {
      database.upsertHistory(
        siteKey: effectiveSiteKey,
        vodId: vod.vodId,
        vodName: vod.vodName,
        vodPic: vod.vodPic,
        flag: flag,
        episodeName: episodeName,
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
    final currentTmdb = tmdbConfig;
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
    var next = tmdbConfig;

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
    notifyListeners();
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
  String cspDirectoryFor(String siteKey) => _cspBinding.directoryFor(siteKey);

  /// 已导入的 T3 桌面站源（含静态检测结论，供设置页回显）。
  List<InstalledJar> get installedCspJars =>
      JarIntake.describeInstalled(_cspBinding.root);

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
      log: log,
      // 转译失败不影响落盘结论（`ok` 只表示落盘）：结论写进 intake.json 的
      // `dexTranslation`，可用性文案由 spider_router 的 `_classifyCsp` 决定。
      translateDex: ({required siteDir, required archive}) =>
          DexTranslate.run(siteDir: siteDir, archive: archive, log: log),
    );
    // 分类结果不经过 SpiderRouter 的 _cache，磁盘变化后 classifySite 立即反映；
    // 这里只需刷新 UI（站点列表的可用性文案会跟着变）。
    notifyListeners();
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
  Future<CspProbeReport> probeCspJars() async {
    final config = effectiveConfig;
    if (config == null) return const CspProbeReport();
    final report = await _cspProbe().materialize(config);
    if (!report.isEmpty) notifyListeners();
    return report;
  }

  /// 某站点上次的自动探测结论（设置页/站点页回显）；未探测过为 null。
  Map<String, Object?>? cspProbeRecordFor(String siteKey) =>
      CspJarProbe.recordFor(_cspBinding, siteKey);

  CspJarProbe _cspProbe() =>
      CspJarProbe(root: _spiderRegistry.root, binding: _cspBinding, log: log);

  /// 启动/换配置后异步探测（不阻塞首屏；失败只记日志）。
  Future<void> _probeCspJarsQuietly() async {
    try {
      final config = effectiveConfig;
      if (config == null) return;
      if (!config.sites.any((site) => CspJvmBinding.matches(site.api))) return;
      final report = await _cspProbe().materialize(config);
      if (!report.isEmpty) notifyListeners();
    } catch (error) {
      log.warning('CSP jar 自动探测失败：$error', scope: 'spider');
    }
  }

  /// 移除已导入的 T3 桌面站源（回滚到「缺少桌面 JVM 站源」）。
  Future<bool> removeCspJar(String siteKey) async {
    final removed = await JarIntake.remove(
      targetDir: _cspBinding.directoryFor(siteKey),
      log: log,
    );
    if (removed) notifyListeners();
    return removed;
  }

  // -------------------------------------------------------------------------
  // 本地爬虫源（文件夹扫描 → 预览勾选 → 导入 → 长期保留）
  // -------------------------------------------------------------------------

  /// Spider 根目录（`<config>/spiders`）；本地源落在其 `local/` 子目录。
  String get spiderRoot => _spiderRegistry.root;

  /// 上次扫描的文件夹（本会话记忆，供页面回填）。
  String get lastLocalScanFolder => _lastLocalScanFolder;

  /// 已导入的 HTML 首页注入源（webHome）。
  List<WebHomeSource> get webHomeSources => _webHomeStore.list();

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
    if (_supervisor.statuses().any(
      (status) =>
          status.state == SpiderRuntimeState.running &&
          (status.manifest?.key == key || status.siteKey == key),
    )) {
      log.warning('本地源仍在运行，拒绝删除 key=$key，请先停止运行时', scope: 'spider');
      return false;
    }
    try {
      if (!removeLocalSpiderDirectory(root: root, key: key)) return false;
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

  /// 删除某个 webHome 源（连同其资源目录）。
  Future<bool> removeWebHome(String key) async {
    final ok = _webHomeStore.remove(key);
    if (ok) _invalidateLocalSites();
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

  /// 当前播放会话的代理 token 指纹（供设置页显示，不回显完整 token）。
  String? get proxySessionFingerprint => _proxySession?.fingerprint;

  /// 启动本地代理（只监听 127.0.0.1）。
  Future<void> startProxy({int port = 0}) async {
    if (_proxy.isRunning) return;
    await _proxy.start(port: port);
    notifyListeners();
  }

  /// 停止本地代理并释放端口（§11.4）。
  Future<void> stopProxy() async {
    _proxySession = null;
    await _proxy.stop();
    notifyListeners();
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
    notifyListeners();
    // 走代理后 Header 由代理注入，播放器不再重复携带（避免 Header 泄漏到直连请求）。
    return PlaybackDecision(
      action: decision.action,
      url: proxied,
      headers: HeaderMap(),
      format: decision.format,
      reason: decision.reason,
      flag: decision.flag,
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

  /// 停止当前播放会话的代理授权（§11.3.1「停止播放即失效」）。
  void revokeProxySession() {
    final session = _proxySession;
    if (session == null) return;
    _proxy.sessions.revoke(session.token);
    _proxySession = null;
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
    notifyListeners();
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
    notifyListeners();
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
    notifyListeners();
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
    notifyListeners();
    return summary;
  }

  /// 站点详情 → 线路集数（供 `FollowingService` 调用）。
  Future<List<FollowingLineEpisodes>?> _resolveFollowingLines(
    Following item,
  ) async {
    final config = effectiveConfig;
    final service = _siteService;
    if (config == null || service == null) return null;
    final site = config.sites
        .where((candidate) => candidate.key == item.siteKey)
        .firstOrNull;
    if (site == null) return null;
    await _waitForPythonSite(site);
    if (_disposed) return null;
    final result = await service.detail(
      site,
      item.vodId,
      identity: VodIdentityHint(vodId: item.vodId, vodName: item.vodName),
    );
    if (result.value.list.isEmpty) return null;
    final vod = result.value.list.first;
    return [
      for (final line in playLinesOf(vod))
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
    _disposed = true;
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
    _tmdbService.close();
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
    log.dispose();
    super.dispose();
  }
}
