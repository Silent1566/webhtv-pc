/// 应用状态：编排配置导入、站点浏览、详情与播放（§4.2 Application Service 层）。
///
/// 约束：
/// - UI 不直接发网络请求，全部经由此处的服务；
/// - 任何失败都转为 [AppError]，由 UI 展示可定位提示，不阻塞界面；
/// - 存储不可用时降级为“无历史/无缓存”，不影响播放（§16.3）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'package:sqlite3/sqlite3.dart' show Row;

import '../core/android_sync.dart';
import '../core/app_error.dart';
import '../core/cat_http.dart';
import '../core/cat_source.dart';
import '../core/config_loader.dart';
import '../core/config_parser.dart';
import '../core/http_api.dart';
import '../core/playback.dart';
import '../core/playback_diagnostics.dart';
import '../core/protocol.dart';
import '../core/proxy_policy.dart';
import '../core/tmdb_config.dart';
import '../core/tmdb_identity.dart';
import '../core/tmdb_playback.dart';
import '../core/tmdb_season.dart';
import '../services/app_paths.dart';
import '../services/android_bridge_service.dart';
import '../services/cat_bundle.dart';
import '../services/cat_runtime.dart';
import '../services/epg_service.dart';
import '../services/log_service.dart';
import '../services/live_service.dart';
import '../services/proxy_server.dart';
import '../services/site_service.dart';
import '../services/spider_process.dart';
import '../services/spider_registry.dart';
import '../services/spider_router.dart';
import '../services/storage.dart';
import '../services/sync_client.dart';
import '../services/sync_server.dart';
import '../services/tmdb_config_store.dart';
import '../services/tmdb_enrichment_service.dart';
import '../services/tmdb_history.dart';
import '../services/tmdb_identity_service.dart';
import '../services/tmdb_season_service.dart';
import '../services/tmdb_service.dart';
import '../services/tmdb_stores.dart';
import 'search_state.dart';
import 'sync_state.dart';
import 'tmdb_state.dart';

const String appVersion = '0.1.0';
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
  ].join('\n');
}

/// 单个页面的加载状态。
enum LoadPhase { idle, loading, ready, failed }

/// 站点列表项的运行时可用性展示（§8.1）。
class SiteListItem {
  const SiteListItem({
    required this.site,
    required this.availability,
  });

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
    SyncClient? syncClient,
    SyncServer Function(SyncServerHost host)? syncServerFactory,
    /// 测试注入的站点 HTTP 客户端（widget/单测不可做真实 socket I/O）。
    /// 与 [liveService]/[epgService] 同一模式：只为可测性开一个口子。
    http.Client? httpClient,
  }) : paths = paths ?? AppPaths.resolve(),
       log = log ?? LogService(),
       _injectedLiveService = liveService,
       _injectedEpgService = epgService,
       _injectedBridgeService = androidBridgeService,
       _injectedSyncClient = syncClient,
       _injectedSyncServerFactory = syncServerFactory {
    if (httpClient != null) _httpClient = HttpApiClient(client: httpClient);
    final cacheDir = this.paths.cacheDir;
    _supervisor = SpiderHostSupervisor(
      workRoot: p.join(cacheDir, 'sidecars'),
      log: this.log,
    );
    _spiderRegistry = SpiderManifestRegistry(
      root: p.join(this.paths.configDir, 'spiders'),
      log: this.log,
    );
    // `csp_*` 站点的桌面 jar 缓存：`<config>/spiders/csp/<siteKey>/`（§9.3、ADR-0002）。
    // 与 manifest 注册表同根，但独立子目录：两种站源形态的入口解析规则不同。
    _cspBinding = CspJvmBinding(root: p.join(this.paths.configDir, 'spiders', 'csp'));
    _proxy = LocalProxyServer(log: this.log);
    // 安卓接入与同步（Phase 5）：只装配，不自动启动服务端（P3 默认关闭）。
    syncState = SyncState(
      log: this.log,
      host: this,
      settingsPath: this.paths.settingsPath,
      bridgeService: _injectedBridgeService,
      client: _injectedSyncClient,
      serverFactory: _injectedSyncServerFactory,
    );
    _catBundle = CatBundle(rootDir: p.join(this.paths.dataDir, 'catbundle'));
    // TMDB 服务：配置引用是函数（设置页保存后无需重建服务）。
    _tmdbService = TmdbService(config: () => _tmdbConfigStore.config);
    final node = SidecarRuntimeResolver.resolve('node');
    if (node != null) {
      _catRuntime = CatNodeRuntime(nodeCommand: node, log: this.log);
      _catPipeline = CatImportPipeline(
        bundle: _catBundle,
        runtime: _catRuntime!,
        log: this.log,
      );
      _importService = ConfigImportService(
        catResolver: _catPipeline!.resolve,
      );
    }
    _router = SpiderRouter(
      client: _httpClient,
      globalHeaders: const [],
      catHttpClient: _catHttpClient,
      registry: _spiderRegistry,
      supervisor: _supervisor,
      log: this.log,
      hostPath: sidecarHostPath ?? defaultSidecarHostPath(),
      jsHostPath: jsSidecarHostPath ?? defaultJsSidecarHostPath(),
      jvmHostPath: jvmSidecarHostPath ?? defaultJvmSidecarHostPath(),
      cspBinding: _cspBinding,
    );
  }

  final AppPaths paths;
  final LogService log;

  /// 猫源 bundle 下载/缓存（§9 猫源）。
  late final CatBundle _catBundle;

  /// 猫源 Node 运行时；未安装 Node 时为 null（UI 如实报错，不静默跳过）。
  CatNodeRuntime? _catRuntime;

  /// 猫源导入门面；未安装 Node 时为 null。
  CatImportPipeline? _catPipeline;

  late final ConfigImportService _importService;
  late HttpApiClient _httpClient = HttpApiClient();
  final CatHttpClient _catHttpClient = CatHttpClient();
  late final SpiderRouter _router;

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

  /// 本地代理(§11)。默认只监听 127.0.0.1,按需启动。
  late final LocalProxyServer _proxy;

  /// 本次播放的代理会话（§11.3.1）。
  ProxySession? _proxySession;

  AppDatabase? _database;
  ConfigRecord? _activeRecord;
  AppConfig? _config;
  SiteService? _siteService;

  /// 安卓接入与同步状态（`docs/phase5/design/02`）。
  ///
  /// 默认全部关闭（P3）；设置落在 `<configDir>/settings.json` 的 `sync` 段
  /// （与 TMDB 同一份文件，各自保留对方的值）。
  late final SyncState syncState;

  StartupInfo? _startupInfo;
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
  MultiSiteSearchOutcome? _activeSearch;
  List<String> _searchHistory = const [];

  /// 最近一次播放决策，供播放器页与日志页展示。
  PlaybackDecision? _lastDecision;

  /// 最近一次播放诊断（§23），供日志页展示与复制。
  PlaybackDiagnostics? _lastDiagnostics;

  // ---------------------------------------------------------------- TMDB
  //
  // 模块边界（`docs/phase4/design/04` §2）：UI 不直接发 TMDB 请求，全部经此处。
  // TMDB 配置落在 `<configDir>/settings.json`（`03` §5.3），**不进配置 JSON**。

  late final TmdbConfigStore _tmdbConfigStore;
  late final TmdbService _tmdbService;
  TmdbIdentityService? _tmdbIdentityService;
  TmdbSeasonService? _tmdbSeasonService;
  TmdbEnrichmentService? _tmdbEnrichmentService;
  TmdbState? _tmdbState;

  /// TMDB 设置（当前生效）。
  TmdbConfig get tmdbConfig => _tmdbConfigStore.config;

  /// TMDB 服务（纯 TMDB 详情页直接使用，`04` §6）。
  TmdbService get tmdbService => _tmdbService;

  /// 设置文件路径（设置页展示用）。
  String get tmdbSettingsPath => paths.settingsPath;

  /// TMDB 配置版本号（设置变更时递增，供 UI 重建）。
  int _tmdbConfigRevision = 0;
  int get tmdbConfigRevision => _tmdbConfigRevision;

  /// 当前生效的 TMDB 配置 ID（多配置隔离，`02` §14 Q2）。
  int get tmdbConfigId => _activeRecord?.id ?? 0;

  StartupInfo? get startupInfo => _startupInfo;
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
  LiveService get liveService => _liveService ??= _injectedLiveService ?? LiveService();

  /// EPG 服务（§13.1）。缓存落在 `paths.cacheDir/epg/`，与直播服务同域。
  EpgService get epgService =>
      _epgService ??=
          _injectedEpgService ?? EpgService(cacheDir: paths.cacheDir);
  AppDatabase? get database => _database;
  ConfigRecord? get activeRecord => _activeRecord;
  List<ConfigRecord> get configs => _configs;
  Site? get selectedSite => _selectedSite;
  SiteResult? get homeResult => _homeResult;
  SiteResult? get categoryResult => _categoryResult;
  SiteResult? get detailResult => _detailResult;
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

  bool get hasConfig => _config != null && _config!.sites.isNotEmpty;

  /// 站点列表(含运行时可用性),隐藏 `hide=1` 的站点。
  ///
  /// 使用实例级 [SpiderRouter.classifySite] 而非静态 [SpiderRouter.classify],
  /// 才能对 `spider-local:` 站点给出真实可用性(§8.1、§9.7)。
  List<SiteListItem> get siteItems {
    final config = _config;
    if (config == null) return const [];
    return config.sites
        .where((site) => !site.hide)
        .map(
          (site) => SiteListItem(
            site: site,
            // §8.1:可用性判定必须区分「运行时未安装」与「站点不可用」,
            // 因此这里用带注册表的实例方法，而不是静态 `classify`。
            availability: _router.classifySite(site),
          ),
        )
        .toList();
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

    LogService.logDirectoryOverride = paths.logDir;
    await log.open(paths.logDir);

    // 安卓接入与同步设置（Phase 5）：读取失败不阻塞启动，退回默认（全关）。
    await syncState.load();

    // TMDB 设置（`03` §5.3）：读取失败不阻塞启动，退回默认配置。
    _tmdbConfigStore = TmdbConfigStore(path: paths.settingsPath, log: log);
    await _tmdbConfigStore.load();

    final openResult = AppDatabase.open(paths.databasePath);
    _database = openResult.database;
    if (!openResult.succeeded) {
      log.error('数据库打开失败，降级为无历史模式：${openResult.error}');
    }

    var platform = Platform.operatingSystem;
    var architecture = Platform.version.split(' ').first;
    if (Platform.isWindows) {
      platform = 'windows';
      architecture = _windowsArchitecture();
    }

    if (_database != null) {
      try {
        _configs = _database!.listConfigs();
        _activeRecord = _database!.activeConfig();
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
      startupLatency: stopwatch.elapsed,
    );
    log.info(_startupInfo!.oneLine, scope: 'startup');
    log.info(_startupInfo!.detailLines.replaceAll('\n', ' | '), scope: 'startup');

    _configPhase = hasConfig ? LoadPhase.ready : LoadPhase.idle;
    notifyListeners();
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
  TmdbState get tmdb =>
      _tmdbState ??= TmdbState(
        config: () => _tmdbConfigStore.config,
        service: _tmdbService,
        identityService: _ensureTmdbIdentityService(),
        seasonService: _ensureTmdbSeasonService(),
        enrichmentService: _ensureTmdbEnrichmentService(),
        isCurrentRun: () => _tmdbRunId == _detailRunId,
      );

  /// 当前 TMDB 加载归属的详情运行号（`loadDetail` 每次自增）。
  int _tmdbRunId = 0;

  /// 清除鉴权熔断（仅供测试：注入 401 后需要先清掉上一次的熔断窗口）。
  void clearAuthBlocksForTest() => _tmdbService.clearAuthBlocks();

  /// 用当前详情页上下文重新加载 TMDB 区块（手动匹配 / 重新匹配后调用）。
  Future<void> reloadTmdb() async {
    final vod = _selectedVod;
    final site = _selectedSite;
    if (vod == null || site == null || _database == null) return;
    _tmdbRunId = _detailRunId;
    await tmdb.loadForVod(
      vod,
      siteKey: site.key,
      siteName: site.name,
      configId: tmdbConfigId,
      lines: playLinesOf(vod),
    );
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

  TmdbSeasonService _ensureTmdbSeasonService() =>
      _tmdbSeasonService ??= TmdbSeasonService(
        store: DatabaseTmdbSeasonStore(database: _database!),
      );

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
  /// 用 `explorer.exe` 而不是 `url_launcher`：后者会为 Windows 引入
  /// `url_launcher_windows` 插件（C++ 插件工程 + CMake 变更），而本阶段
  /// 只需「打开一个 http(s) 地址」，Windows 自带的 `explorer.exe <url>`
  /// 已由系统处理默认浏览器与协议。返回是否成功发起。
  Future<bool> openExternalUrl(String url) async {
    if (!Platform.isWindows) return false;
    try {
      await Process.start('explorer.exe', [url], mode: ProcessStartMode.detached);
      return true;
    } catch (error) {
      log.warning('打开外部链接失败：$error', scope: 'tmdb');
      return false;
    }
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
    final config = _config;
    if (config == null) {
      _siteService = null;
      return;
    }
    _siteService = SiteService(
      appConfig: config,
      router: SpiderRouter(
        client: _httpClient,
        globalHeaders: config.headers,
        catHttpClient: _catHttpClient,
        registry: _spiderRegistry,
        supervisor: _supervisor,
        log: log,
        hostPath: _router.hostPath ?? defaultSidecarHostPath(),
        jsHostPath: defaultJsSidecarHostPath(),
        jvmHostPath: defaultJvmSidecarHostPath(),
        cspBinding: _cspBinding,
      ),
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
    _selectedSite ??= config.defaultSite();
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
      log.warning(
        '猫源重启失败，回退到已保存配置：$error',
        scope: 'cat',
      );
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
    _selectedVod = vod;
    _detailPhase = phase;
    _detailError = error;
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
      final source = ConfigSource.parse(input);
      var imported = await _importService.import(source);
      var repositoryIndex = 0;

      if (imported.isRepository) {
        // §7.4.2：默认第一项；切换条目时保留各条目独立配置记录。
        log.info(
          '导入配置仓库 entries=${imported.repositoryEntries.length} '
          'origin=${redactUrl(imported.origin)}',
        );
        imported = await _importService.expandRepository(imported);
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

      final name =
          displayName ?? config.name ?? source.displayName;
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
      );
      if (recordId != null) {
        _database!.saveConfigSites(recordId, config.sites);
        _configs = _database!.listConfigs();
        _activeRecord = _database!.activeConfig();
      }

      _notice = config.notice ??
          '配置导入成功：${config.sites.length} 个站点';
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
    // TMDB 状态是页面级临时状态：不清会让下一次进入详情页先渲染上一部剧的元数据。
    _tmdbState?.clear();
    _detailPhase = LoadPhase.idle;
    _detailResult = null;
    _detailError = null;
    _selectedVod = null;
    notifyListeners();
  }

  /// 加载首页（§8.1、§8.4）。
  /// 加载首页（§8.1、§8.4）。
  ///
  /// 首页无推荐内容时**自动选第一个分类**（用户反馈 2026-10-09：「如果当前站点的
  /// 默认推荐分类无数据时自动隐藏选中显示第一个分类即可」）。
  ///
  /// 为什么：实测 126 个站点里 40 个只返回 `class` 而不返回 `list`，用户进入站点后
  /// 看到的是「请选择一个分类」的空态，必须先手动点一下才有内容——既然站点已经
  /// 给了分类列表，帮用户选第一个是零风险的行为。
  Future<void> loadHome(Site site) async {
    final service = _siteService;
    if (service == null) return;
    _contentPhase = LoadPhase.loading;
    _lastError = null;
    notifyListeners();
    try {
      final outcome = await service.home(site);
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
      if (outcome.value.list.isEmpty && first != null) {
        log.info(
          '首页无推荐内容，自动进入第一个分类 '
          't=${first.typeId} name=${first.typeName}',
          scope: 'site',
        );
        await loadCategory(first.typeId);
        return;
      }
    } catch (error) {
      final failure = error is AppError
          ? error
          : AppError(AppErrorKind.unknown, '$error', cause: error);
      _lastError = failure;
      _contentPhase = LoadPhase.failed;
      log.error('首页加载失败 site=${site.key} ${failure.logLine}', scope: 'site');
    }
    notifyListeners();
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
    final effective = filters ?? _categoryFilters;
    // 新一次加载：作废在途的“下一页”响应，避免把上一份列表追加到新列表后面。
    final runId = ++_categoryRunId;
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

  /// 多站点并发搜索（§14.1、§14.3）。
  ///
  /// 行为约束：
  /// - 并发数不超过 [maxConcurrency]，避免一次性打满网络与对端限流（§14.3）；
  /// - 单站点失败只把该站点标为失败，**不阻塞**其他站点；
  /// - 新查询会让旧查询的在途结果**不再投递**（靠 runId 与 [_activeSearch] 判定）；
  /// - 取消后不再投递任何结果（含在途结果），只保留取消前已发布的快照；
  /// - 结果按配置中的站点顺序稳定排序，重复搜索不改变顺序。
  Future<MultiSiteSearchOutcome> searchAll(
    String keyword, {
    int maxConcurrency = 4,
    Duration timeout = const Duration(seconds: 20),
    bool quick = false,
  }) async {
    final service = _siteService;
    final runId = ++_searchRunId;
    final allItems = siteItems;
    final sites = allItems
        .where((item) => item.availability.available && item.site.searchable)
        .map((item) => item.site)
        .toList();
    final outcome = MultiSiteSearchOutcome(
      runId: runId,
      keyword: keyword,
      results: const [],
      skippedUnsupported:
          allItems.where((item) => !item.availability.available).length,
      skippedNotSearchable: allItems
          .where((item) => item.availability.available && !item.site.searchable)
          .length,
    );
    _activeSearch = outcome;
    _searchHistory = [
      keyword,
      ..._searchHistory.where((item) => item != keyword),
    ].take(20).toList();
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
          entries.add(
            SiteSearchEntry(
              siteKey: site.key,
              siteName: site.name,
              result: value.value,
              latency: value.latency,
              fromCache: value.fromCache,
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

    final workerCount =
        sites.length < maxConcurrency ? sites.length : maxConcurrency;
    await Future.wait(List.generate(workerCount, (_) => worker()));

    if (outcome.cancelled) {
      log.info(
        '搜索批次 run=$runId 已取消，丢弃 ${entries.length} 个在途结果 keyword=$keyword',
        scope: 'search',
      );
      return outcome;
    }

    if (!identical(_activeSearch, outcome)) {
      log.info(
        '搜索批次 run=$runId 已被取代，结果不再投递 keyword=$keyword',
        scope: 'search',
      );
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
  Future<void> loadDetail(Vod vod) async {
    final service = _siteService;
    final site = _selectedSite;
    if (service == null || site == null) return;
    final runId = ++_detailRunId;
    _selectedVod = vod;
    _detailResult = null;
    _detailError = null;
    _detailPhase = LoadPhase.loading;
    notifyListeners();
    try {
      // `folder` 条目必须用 `t=<vod_id>` **展开**，不能走 `ids=` 详情接口。
      //
      // 实测（5559 真机，同一站点同一 id）：
      // - `ids=atvp_detail:131925` → 空壳（`vod_name` 与 `vod_play_url` 均为空）；
      // - `t=atvp_detail:131925`   → 返回 3 条真实资源（百度/夸克分享链）。
      //
      // 原因：`vod_id` 的 `atvp_detail:` 前缀是插件**分类阶段**自己加的
      // （`_encode_category_id`），只有 `categoryContent` 会把它剥回去
      // （插件第 1646 行）；详情接口没有这个语义。安卓 App 正是用 `t=` 展开的。
      final outcome = vod.isFolder
          ? await service.category(site, typeId: vod.vodId, page: 1)
          : await service.detail(site, vod.vodId);
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
      final first = outcome.value.list.isEmpty ? null : outcome.value.list.first;
      // folder 展开的子条目是分享链（无 `vod_play_url`），而**作品信息在被点的
      // folder 条目自身**（`vod_name`/`vod_pic`/`vod_remarks`，如「山花烂漫时 /
      // 全23集」）。因此只有「子条目确实可播」时才把选中条目切到子条目，
      // 否则保持 folder 条目——否则手动匹配会拿「百度#木偶」这种分享链名去搜 TMDB。
      final childPlayable = first != null && playLinesOf(first).isNotEmpty;
      final effective = vod.isFolder && !childPlayable ? vod : (first ?? vod);
      _selectedVod = effective;
      // TMDB 增强：详情就绪后异步加载。失败**不影响**线路与选集（§27 原则 3），
      // 因此不 await，也不把异常传播到详情加载。
      //
      // folder 展开也做 TMDB 匹配（用户反馈「桥接站点还是没有 tmdb 详情页」）：
      // 此时没有线路，`loadForVod` 会跳过季度解析与剧集元数据，只加载作品维度的
      // 背景/海报墙/演职人员/推荐。信息表缺失字段留空（folder 条目只有
      // 名称/海报/备注，没有年份/地区/演员/简介）。
      _tmdbRunId = runId;
      unawaited(
        tmdb.loadForVod(
          effective,
          siteKey: site.key,
          siteName: site.name,
          configId: tmdbConfigId,
          lines: playLinesOf(effective),
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
      log.error('详情加载失败 site=${site.key} vod=${vod.vodId} ${failure.logLine}',
          scope: 'site');
    }
    notifyListeners();
  }

  /// 清空详情错误（详情页「重试」后的提示关闭）。
  void clearDetailError() {
    if (_detailError == null) return;
    _detailError = null;
    notifyListeners();
  }

  List<VodPlayLine> playLinesOf(Vod vod) =>
      parsePlayLines(vod.vodPlayFrom, vod.vodPlayUrl);

  /// 解析播放请求（§10.2）。
  Future<PlaybackDecision?> resolvePlayback({
    required String episodeTarget,
    String? flag,
    String? vodId,
  }) async {
    final service = _siteService;
    final site = _selectedSite;
    if (service == null || site == null) return null;
    try {
      final outcome = await service.resolvePlayback(
        site: site,
        episodeTarget: episodeTarget,
        flag: flag,
        vodId: vodId,
      );
      // 退出旧会话并接入本地代理：Header 注入与 Range 都经同一 token 校验（§9.6、§11.3.1）。
      revokeProxySession();
      final decision = await proxyDecision(outcome.value, siteKey: site.key);
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

  /// 记录播放进度（§15.2）。
  ///
  /// `siteKey` 显式传入而不依赖当前选中站点：命令行播放、历史恢复等场景下
  /// 并不存在“当前站点”，但仍应记录进度。
  void recordProgress({
    required Vod vod,
    required String flag,
    required String episodeName,
    required String episodeId,
    required Duration position,
    required Duration duration,
    String? siteKey,
  }) {
    final database = _database;
    final effectiveSiteKey = siteKey ?? _selectedSite?.key ?? 'cli';
    if (database == null) return;
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
      );
    } catch (error) {
      log.warning('写入播放进度失败：$error', scope: 'history');
    }
  }

  /// 查询某剧集的历史记录（用于进入播放器时自动续播，§15.2）。
  PlaybackHistory? findHistory({
    required String siteKey,
    required String vodId,
    String? flag,
    String? episodeId,
  }) {
    final database = _database;
    if (database == null) return null;
    try {
      return database.findHistory(
        siteKey: siteKey,
        vodId: vodId,
        flag: flag,
        episodeId: episodeId,
      );
    } catch (error) {
      log.warning('读取播放进度失败:$error', scope: 'history');
      return null;
    }
  }

  /// 「继续播放」位置（§15.2）。
  ///
  /// 已播完或位置过短时返回 null：从零开始比从尾部几秒开始体验更好。
  Duration? resumePositionFor({
    required String siteKey,
    required String vodId,
    String? flag,
    String? episodeId,
  }) {
    final record = findHistory(
      siteKey: siteKey,
      vodId: vodId,
      flag: flag,
      episodeId: episodeId,
    );
    if (record == null || record.completed) return null;
    if (record.positionMs < resumeThreshold.inMilliseconds) return null;
    if (record.durationMs > 0 &&
        record.positionMs > record.durationMs - 5000) {
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
    for (final row in recentHistory(limit: limit))
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
  }) async {
    final database = _database;
    if (database == null) return null;
    try {
      final id = database.saveConfig(
        name: name,
        origin: origin,
        json: config.toJson(),
        contentType: 'android-t4-gateway',
        siteCount: config.sites.length,
        liveCount: config.lives.length,
        makeActive: false,
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
    return jsonEncode({
      'id': record.id,
      'type': 0,
      'name': record.name,
      'url': origin,
    });
  }

  /// 应用对端推来的设置（白名单子集，`design/02` §3.6）。
  ///
  /// 只有 `tmdb_enabled` 与 `tmdb_config` 在 PC 白名单内，其余键在解析阶段
  /// 已被 `SyncSettings` 丢弃。凭据类字段若对端未提供，**保留本机原值**
  /// ——把能用的凭据清空比不同步更糟。
  @override
  Future<void> applySyncedSettings(SyncSettings settings) async {
    if (settings.isEmpty) return;
    var next = tmdbConfig;

    final enabled = settings.values['tmdb_enabled'];
    if (enabled != null) next = next.copyWith(enabled: asFlag(enabled));

    final raw = settings.values['tmdb_config'];
    if (raw != null) {
      Object? decoded = raw;
      if (raw is String) {
        try {
          decoded = jsonDecode(raw);
        } on FormatException {
          decoded = null;
        }
      }
      if (decoded is Map) {
        final incoming = TmdbConfig.fromMap(
          decoded.map((key, value) => MapEntry('$key', value)),
        );
        next = incoming.copyWith(
          apiKey: incoming.apiKey.isEmpty ? next.apiKey : incoming.apiKey,
          accessToken: incoming.accessToken.isEmpty
              ? next.accessToken
              : incoming.accessToken,
        );
      }
    }

    await saveTmdbConfig(next);
    log.info(
      '已应用中端同步设置（TMDB）：keys=${settings.values.keys.join(',')} '
      'sensitive=${settings.sensitiveIncluded}',
      scope: 'sync',
    );
  }

  List<PlaybackHistory> recentHistory({int limit = 100}) {
    final database = _database;
    if (database == null) return const [];
    try {
      return database.recentHistory(limit: limit);
    } catch (error) {
      log.warning('读取播放历史失败：$error', scope: 'history');
      return const [];
    }
  }

  List<PlaybackHistory> searchHistory(String keyword) {
    final database = _database;
    if (database == null) return const [];
    try {
      return database.searchHistory(keyword);
    } catch (_) {
      return const [];
    }
  }

  void deleteHistory(int id) {
    _database?.deleteHistory(id);
    notifyListeners();
  }

  void clearHistory() {
    _database?.clearHistory();
    // 「清空历史」同时清季度进度，但**保留**匹配与绑定（`03` §6.5）。
    _database?.clearTmdbSeasonProgress();
    log.info('已清空播放历史（配置未受影响）', scope: 'history');
    notifyListeners();
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
    notifyListeners();
    return found;
  }

  /// 本地 Spider 列表（供管理页展示）。
  List<LocalSpider> get localSpiders => _spiderRegistry.sortedSpiders;

  /// 运行时状态列表（含崩溃、退避、隔离等级）。
  List<SpiderRuntimeStatus> spiderRuntimeStatuses() =>
      _supervisor.statuses();

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

    const credentialKeys = {
      'user-agent',
      'referer',
      'cookie',
      'authorization',
    };
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
    } catch (error) {
      _lastError = AppError(
        AppErrorKind.storage,
        '清理缓存失败',
        detail: '$error',
      );
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _router.dispose();
    _importService.close();
    _liveService?.close();
    _epgService?.close();
    _tmdbService.close();
    // §22.2:退出后 sidecar 与代理端口全部释放。
    unawaited(_supervisor.shutdownAll());
    unawaited(_proxy.stop());
    // 猫源 Node 进程树与 bundle 句柄同样必须随退出释放（§9.8）。
    _catPipeline?.close();
    // 同步服务端必须先停：退出后不得继续监听局域网端口（§28.4）。
    syncState.dispose();
    _database?.dispose();
    log.dispose();
    super.dispose();
  }
}
