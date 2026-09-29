/// 应用状态：编排配置导入、站点浏览、详情与播放（§4.2 Application Service 层）。
///
/// 约束：
/// - UI 不直接发网络请求，全部经由此处的服务；
/// - 任何失败都转为 [AppError]，由 UI 展示可定位提示，不阻塞界面；
/// - 存储不可用时降级为“无历史/无缓存”，不影响播放（§16.3）。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../core/app_error.dart';
import '../core/cat_http.dart';
import '../core/config_loader.dart';
import '../core/http_api.dart';
import '../core/playback.dart';
import '../core/playback_diagnostics.dart';
import '../core/protocol.dart';
import '../core/proxy_policy.dart';
import '../services/app_paths.dart';
import '../services/log_service.dart';
import '../services/live_service.dart';
import '../services/proxy_server.dart';
import '../services/site_service.dart';
import '../services/spider_process.dart';
import '../services/spider_registry.dart';
import '../services/spider_router.dart';
import '../services/storage.dart';
import 'search_state.dart';

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
class AppState extends ChangeNotifier {
  AppState({
    AppPaths? paths,
    LogService? log,
    String? sidecarHostPath,
    LiveService? liveService,
  }) : paths = paths ?? AppPaths.resolve(),
       log = log ?? LogService(),
       _injectedLiveService = liveService {
    final cacheDir = this.paths.cacheDir;
    _supervisor = SpiderHostSupervisor(
      workRoot: p.join(cacheDir, 'sidecars'),
      log: this.log,
    );
    _spiderRegistry = SpiderManifestRegistry(
      root: p.join(this.paths.configDir, 'spiders'),
      log: this.log,
    );
    _proxy = LocalProxyServer(log: this.log);
    _router = SpiderRouter(
      client: _httpClient,
      globalHeaders: const [],
      catHttpClient: _catHttpClient,
      registry: _spiderRegistry,
      supervisor: _supervisor,
      log: this.log,
      hostPath: sidecarHostPath ?? defaultSidecarHostPath(),
    );
  }

  final AppPaths paths;
  final LogService log;

  final ConfigImportService _importService = ConfigImportService();
  final HttpApiClient _httpClient = HttpApiClient();
  final CatHttpClient _catHttpClient = CatHttpClient();
  late final SpiderRouter _router;

  /// 测试注入的直播服务（用于避免 UI 测试在 fake-async 区做真实 socket I/O）。
  final LiveService? _injectedLiveService;

  /// 直播源加载服务（§13.1）。懒加载：未打开直播页前不建立连接。
  LiveService? _liveService;

  /// sidecar 宿主（§9.8）。按站点隔离进程、限制资源并按指数退避重试。
  late final SpiderHostSupervisor _supervisor;

  /// 本地 Spider manifest 注册表（§9.7）。
  late final SpiderManifestRegistry _spiderRegistry;

  /// 本地代理(§11)。默认只监听 127.0.0.1,按需启动。
  late final LocalProxyServer _proxy;

  /// 本次播放的代理会话（§11.3.1）。
  ProxySession? _proxySession;

  AppDatabase? _database;
  ConfigRecord? _activeRecord;
  AppConfig? _config;
  SiteService? _siteService;

  StartupInfo? _startupInfo;
  LoadPhase _configPhase = LoadPhase.idle;
  LoadPhase _contentPhase = LoadPhase.idle;
  LoadPhase _detailPhase = LoadPhase.idle;
  AppError? _lastError;
  String? _notice;

  Site? _selectedSite;
  SiteResult? _homeResult;
  SiteResult? _categoryResult;
  SiteResult? _detailResult;
  Vod? _selectedVod;
  String? _selectedTypeId;

  List<ConfigRecord> _configs = const [];
  String? _importDiagnosticsSummary;

  /// 并发搜索：递增的运行号，用于丢弃被取代批次的结果。
  int _searchRunId = 0;
  MultiSiteSearchOutcome? _activeSearch;
  List<String> _searchHistory = const [];

  /// 最近一次播放决策，供播放器页与日志页展示。
  PlaybackDecision? _lastDecision;

  /// 最近一次播放诊断（§23），供日志页展示与复制。
  PlaybackDiagnostics? _lastDiagnostics;

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
  AppDatabase? get database => _database;
  ConfigRecord? get activeRecord => _activeRecord;
  List<ConfigRecord> get configs => _configs;
  Site? get selectedSite => _selectedSite;
  SiteResult? get homeResult => _homeResult;
  SiteResult? get categoryResult => _categoryResult;
  SiteResult? get detailResult => _detailResult;
  Vod? get selectedVod => _selectedVod;
  String? get selectedTypeId => _selectedTypeId;
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
          _config = parseConfigRecord(record.json);
          _attachSiteService();
          log.info(
            '恢复配置：${record.name} sites=${_config!.sites.length} '
            'origin=${redactUrl(record.origin)}',
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
    // 64 位 Windows 上 Dart 只提供 x64/arm64 两种主要形态；用 PROCESSOR_ARCHITECTURE
    // 覆盖并保留 Dart 的兜底结果。
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
      ),
      database: _database,
    );
    _selectedSite ??= config.defaultSite();
  }

  void clearError() {
    _lastError = null;
    notifyListeners();
  }

  void clearNotice() {
    _notice = null;
    notifyListeners();
  }

  /// 回到站点首页的“默认推荐”列表：清空当前分类筛选，显示首页结果。
  void selectDefaultListing() {
    _selectedTypeId = null;
    _categoryResult = null;
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
      _attachSiteService();

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
      _config = parseConfigRecord(record.json);
      _attachSiteService();
      _homeResult = null;
      _categoryResult = null;
      _detailResult = null;
      _configPhase = LoadPhase.ready;
      log.info('切换配置：${record.name}', scope: 'config');
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
      } else {
        _config = null;
        _siteService = null;
        _selectedSite = null;
        _homeResult = null;
        _categoryResult = null;
        _detailResult = null;
        _configPhase = LoadPhase.idle;
      }
    }
    notifyListeners();
  }

  /// 选择站点并加载首页。
  Future<void> selectSite(Site site) async {
    _selectedSite = site;
    _categoryResult = null;
    _detailResult = null;
    _selectedTypeId = null;
    notifyListeners();
    await loadHome(site);
  }

  /// 加载首页（§8.1、§8.4）。
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

  /// 加载分类（§7.4.7 分页与筛选）。
  Future<void> loadCategory(
    String typeId, {
    int page = 1,
    Map<String, String> filters = const {},
  }) async {
    final service = _siteService;
    final site = _selectedSite;
    if (service == null || site == null) return;
    _selectedTypeId = typeId;
    _contentPhase = LoadPhase.loading;
    _lastError = null;
    notifyListeners();
    try {
      final outcome = await service.category(
        site,
        typeId: typeId,
        page: page,
        filters: filters,
      );
      _categoryResult = outcome.value;
      _contentPhase = LoadPhase.ready;
      log.info(
        '分类加载成功 site=${site.key} t=$typeId page=$page '
        'list=${outcome.value.list.length} '
        'pagecount=${outcome.value.pageCount ?? "-"} '
        'elapsed=${outcome.latency.inMilliseconds}ms',
        scope: 'site',
      );
    } catch (error) {
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
  Future<void> loadDetail(Vod vod) async {
    final service = _siteService;
    final site = _selectedSite;
    if (service == null || site == null) return;
    _selectedVod = vod;
    _detailPhase = LoadPhase.loading;
    _lastError = null;
    notifyListeners();
    try {
      final outcome = await service.detail(site, vod.vodId);
      _detailResult = outcome.value;
      _detailPhase = LoadPhase.ready;
      final first = outcome.value.list.isEmpty ? null : outcome.value.list.first;
      if (first != null) _selectedVod = first;
      log.info(
        '详情加载成功 site=${site.key} vod=${vod.vodId} '
        'lines=${first == null ? 0 : playLinesOf(first).length} '
        'elapsed=${outcome.latency.inMilliseconds}ms',
        scope: 'site',
      );
    } catch (error) {
      final failure = error is AppError
          ? error
          : AppError(AppErrorKind.unknown, '$error', cause: error);
      _lastError = failure;
      _detailPhase = LoadPhase.failed;
      log.error('详情加载失败 site=${site.key} vod=${vod.vodId} ${failure.logLine}',
          scope: 'site');
    }
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
    // §22.2:退出后 sidecar 与代理端口全部释放。
    unawaited(_supervisor.shutdownAll());
    unawaited(_proxy.stop());
    _database?.dispose();
    log.dispose();
    super.dispose();
  }
}
