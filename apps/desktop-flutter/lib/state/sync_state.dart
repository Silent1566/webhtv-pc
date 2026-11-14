/// 安卓接入与同步的状态层（`docs/phase5/design/00`–`02`）。
///
/// 边界（`design/02` §2）：
/// - UI **不**直接发请求、不解析协议；
/// - 本层持有服务端/客户端生命周期、开关状态、对端白名单、错误分类；
/// - 纯逻辑（编解码/裁决）在 `core/android_bridge.dart`、`core/android_sync.dart`；
/// - 网络在 `services/android_bridge_service.dart`、`services/sync_*.dart`；
/// - 落库经 [SyncStateHost] 回调，本层不直接操作 `AppState`。
///
/// ## 默认关闭（P3）
///
/// 三项开关（服务端监听、向安卓推送、同步设置）**全部默认关闭**，
/// 并在 `<configDir>/settings.json` 的 `sync` 段持久化。打开服务端是安全敏感
/// 操作，UI 必须先展示 [serverBindHint] 里的提示。
///
/// ## 一票否决的边界
///
/// - 不复制安卓的爬虫/站点配置（P1）；
/// - 站点地址以 PC 可达地址为基准并校验主机一致性（P2）；
/// - 不用 `force` 清表，导入不覆盖当前配置（P3）；
/// - 拒绝把本机自己当设备（P4）；
/// - 403/404/超时不得折叠成"0 个站点"或"同步成功"（P5）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../core/android_bridge.dart';
import '../core/android_sources.dart';
import '../core/android_sync.dart';
import '../core/app_error.dart';
import '../core/playback_identity.dart';
import '../core/protocol.dart';
import '../core/realtime_sync.dart';
import '../core/source_key.dart';
import '../services/android_bridge_service.dart';
import '../services/android_read_client.dart';
import '../services/log_service.dart';
import '../services/realtime_sync_engine.dart';
import '../services/storage.dart';
import '../services/settings_file.dart';
import '../services/sync_client.dart';
import '../services/sync_server.dart';

/// 本层需要的宿主能力（由 `AppState` 实现）。
///
/// 用接口而不是一堆回调：契约（读历史/读收藏/存桥接配置/取对齐配置/落盘设置）
/// 是显式的，调用点可读，且 `sync_state.dart` 不需要 import `app_state.dart`。
abstract class SyncStateHost {
  /// 数据库；未就绪时为 `null`（降级为"同步不可用"而不是崩溃）。
  AppDatabase? get syncDatabase;

  /// 本地历史（供推送）。
  List<SyncHistoryItem> syncHistoryItems({int limit = 2000});

  /// 本地收藏（供推送）。
  List<SyncFavoriteItem> syncFavoriteItems({int limit = 2000});

  /// 把桥接配置存为**新记录**并返回记录 id。
  ///
  /// 必须 `makeActive: false`：导入不切换当前配置（`design/00` Q10）。
  Future<int?> saveBridgeConfig({
    required String name,
    required String origin,
    required AppConfig config,
    required List<String> diagnostics,
    String deviceUuid = '',
    String interfaceKey = '',
    String configUrl = '',
  });

  /// 推送时要带的配置身份 JSON；无法确定时为 `null`。
  ///
  /// 桥接源送 `configKey`（= 安卓的 `interfaceKey`）：安卓据此**直接写目标源**，
  /// 不再经过 `Config.find(url)`（查不到会 insert 一行，凭空多出"桥接源"）。
  /// 本地导入的源没有 interfaceKey，仍按老协议送自己的 `url`。
  ///
  /// 带 `configKey` 时 `url` 只作展示，安卓不读它。
  String? syncConfigJson();

  /// 把白名单内的设置落到本地设置文件（调用方已确认 `settings` 开启）。
  Future<void> applySyncedSettings(SyncSettings settings);

  /// 本轮实时轮询要请求的 `siteKey`（`design/01` §6.1 的 `pollAllSites`）。
  ///
  /// [all] = true 返回全部站点；否则返回**最近活跃的** [limit] 个
  /// （由 `selectPollSites` 按「最近播放优先」取舍）。
  ///
  /// 为什么需要宿主提供：只有它知道当前配置里有哪些站点，以及本机
  /// 最近播过哪些站——后者才是「可能产生新记录」的真实候选集。
  List<String> syncSiteKeys({required bool all, int limit = 20});

  /// 实时同步已把新记录落库，请刷新内存视图。
  ///
  /// 不刷新的后果：历史页/详情页会一直显示旧数据，直到用户手动刷新或重启
  /// ——同步“成功”了但哪里都看不到，用户会以为没生效。
  void notifySyncedDataChanged();
}

/// 一条设备接入历史（用户反馈 2026-10-09：设备接入需要历史记录方便再次使用）。
///
/// 与 [SyncPeer]（白名单，管**同步**授权）分开：设备历史记的是**接入过哪些地址**
/// 及其最近使用时间，即使从未授权同步也要能一键重连（用户日常用法是「扫一次、
/// 以后直接点历史」）。
class DeviceHistoryEntry {
  const DeviceHistoryEntry({
    required this.uuid,
    required this.name,
    required this.address,
    required this.lastUsedMs,
  });

  /// 设备 uuid；未知时用规范化地址兼作标识。
  final String uuid;
  final String name;

  /// PC 视角的可达基址（已规范化，无尾随 `/`）。
  final String address;

  /// 最近一次成功接入的时间（毫秒时间戳），用于排序与「最近使用」判定。
  final int lastUsedMs;

  Map<String, Object?> toJson() => {
    'uuid': uuid,
    'name': name,
    'address': address,
    'lastUsed': lastUsedMs,
  };

  static DeviceHistoryEntry? fromJson(Object? value) {
    final map = asMap(value);
    final address = asNonEmptyString(map['address']);
    if (address == null) return null;
    return DeviceHistoryEntry(
      uuid: asNonEmptyString(map['uuid']) ?? address,
      name: asNonEmptyString(map['name']) ?? Uri.parse(address).host,
      address: address,
      lastUsedMs: asInt(map['lastUsed']) ?? 0,
    );
  }

  DeviceHistoryEntry copyWith({
    String? name,
    String? address,
    int? lastUsedMs,
  }) => DeviceHistoryEntry(
    uuid: uuid,
    name: name ?? this.name,
    address: address ?? this.address,
    lastUsedMs: lastUsedMs ?? this.lastUsedMs,
  );

  @override
  String toString() => 'DeviceHistoryEntry($name @ $address)';
}

/// 一台已授权对端（按 `uuid` 区分，`design/01` §9 Q1）。
class SyncPeer {
  const SyncPeer({
    required this.uuid,
    required this.name,
    required this.address,
  });

  final String uuid;
  final String name;

  /// PC 视角的可达基址（规范化后，无尾随 `/`）。
  final String address;

  /// 脱敏标识，只保留前 4 位（`design/02` §7）。
  String get maskedUuid =>
      uuid.length <= 4 ? '****' : '${uuid.substring(0, 4)}****';

  Map<String, Object?> toJson() => {
    'uuid': uuid,
    'name': name,
    'address': address,
  };

  static SyncPeer? fromJson(Object? value) {
    final map = asMap(value);
    final uuid = asNonEmptyString(map['uuid']);
    final address = asNonEmptyString(map['address']);
    if (uuid == null || address == null) return null;
    return SyncPeer(
      uuid: uuid,
      name: asNonEmptyString(map['name']) ?? '未知设备',
      address: address,
    );
  }

  SyncPeer copyWith({String? name, String? address}) => SyncPeer(
    uuid: uuid,
    name: name ?? this.name,
    address: address ?? this.address,
  );

  @override
  bool operator ==(Object other) =>
      other is SyncPeer && other.uuid == uuid && other.address == address;

  @override
  int get hashCode => Object.hash(uuid, address);

  @override
  String toString() => 'SyncPeer($name $maskedUuid @ $address)';
}

/// 安卓接入与同步状态。
class SyncState extends ChangeNotifier {
  SyncState({
    required this.log,
    required this.host,
    required this.settingsPath,
    this.settingsExporter,
    this.beginConfigMutation,
    this.onBridgeConfigSaved,
    AndroidBridgeService? bridgeService,
    SyncClient? client,
    SyncServer Function(SyncServerHost host)? serverFactory,
    AndroidReadClient? readClient,
    RealtimeScheduler? realtimeScheduler,
    Random? random,
  }) : _bridge = bridgeService ?? AndroidBridgeService(log: log),
       _client = client ?? SyncClient(log: log),
       _serverFactory = serverFactory ?? _defaultServerFactory(log),
       _readClient = readClient ?? AndroidReadClient(log: log),
       _realtimeScheduler = realtimeScheduler ?? realtimeRealScheduler(),
       _random = random ?? Random.secure() {
    _playbackIdentity = PlaybackIdentityStore(
      onChanged: () => unawaited(_persist()),
    );
  }

  final LogService log;
  final SyncStateHost host;

  /// 可选宿主配置代际门禁；既有独立同步宿主无需实现新接口。
  final bool Function() Function()? beginConfigMutation;
  final void Function(int recordId, String candidate)? onBridgeConfigSaved;

  /// `<configDir>/settings.json`（`sync` 段所在文件，与 TMDB 同一份）。
  final String settingsPath;
  final Future<Map<String, Object?>> Function(bool allowSensitive)?
  settingsExporter;
  final AndroidBridgeService _bridge;
  final SyncClient _client;
  final AndroidReadClient _readClient;

  /// 定时器工厂（测试注入手动调度器；生产用真实 `Timer`）。
  final RealtimeScheduler _realtimeScheduler;
  final SyncServer Function(SyncServerHost host) _serverFactory;
  final Random _random;

  /// 服务端默认端口区间（与安卓同策略，`design/02` §4.1）。
  static const int defaultPortStart = androidDefaultPort;
  static const int defaultPortEnd = androidPortRangeEnd;

  static SyncServer Function(SyncServerHost host) _defaultServerFactory(
    LogService log,
  ) =>
      (host) => SyncServer(log: log, host: host);

  // ------------------------------------------------------------ 持久化状态

  bool _loaded = false;
  bool _serverEnabled = false;
  bool _pushEnabled = false;

  /// 路径 B 的可选 token（`design/01` §3.2.2）。
  ///
  /// 为空时只允许 uuid 白名单内的对端（局域网默认形态）。
  /// 持久化键为 `sync.realtime.pullToken`。
  String _realtimePullToken = '';

  /// 身份解析注册表（`design/01` §3.2.1）。
  ///
  /// 变更后立即落盘：安卓的 `adopt` 结论决定它把哪把键当正式身份，
  /// 丢了注册表就会在下次解析时「新造一个身份」，两端键永久错开。
  late PlaybackIdentityStore _playbackIdentity;
  bool _settingsSyncEnabled = false;
  String _deviceUuid = '';
  String _deviceName = '';
  List<SyncPeer> _peers = const [];

  /// 设备接入历史（按最近使用倒序，上限 [maxDeviceHistory] 条）。
  List<DeviceHistoryEntry> _deviceHistory = const [];

  /// 最近一次**成功接入**的地址（自动接入的候选，见 [tryAutoConnect]）。
  String _lastBridgeAddress = '';

  /// 设备历史上限：防异常配置把设置文件撞大。
  static const int maxDeviceHistory = 20;

  // ------------------------------------------------------- 实时同步（T7）

  /// 实时同步开关矩阵与周期（`design/01` §6.1）。全部默认关闭。
  RealtimeSyncSwitches _realtime = const RealtimeSyncSwitches();

  /// 路径 A 的拉取游标（毫秒；`0` = 从头）。
  ///
  /// 与路径 B 的游标**无关**：路径 B 的游标由安卓侧保存（`design/01` §3.3）。
  int _realtimePullCursorMs = 0;

  /// 读取能力探测缓存（`design/01` §4.1：缓存 60 s）。
  final RealtimeCapabilityCache _realtimeCapability = RealtimeCapabilityCache();

  RealtimeSyncEngine? _realtimeEngine;

  /// 最近一次（实时或手动）拉取结果（UI 披露用）。
  RealtimePollResult? _lastPollResult;

  // ------------------------------------------------------------ 运行期状态

  SyncServer? _server;
  bool _busy = false;
  AppError? _lastError;
  String? _notice;
  SyncMergeStats? _lastStats;
  String? _lastOperation;

  /// 最近一次成功导入桥接站点所创建的配置记录 id（无导入时为 `null`）。
  ///
  /// 供 UI 在导入成功后询问用户「是否切换到该配置」：
  /// 导入本身受 Q10 约束**不**切换当前配置，但用户导入往往就是想用它，
  /// 让他再去配置页手动点一次「启用」是多余的一步（用户反馈 2026-10-09：
  /// 「导入站点成功后应该自动切换或者弹出确认框让用户确认是否切换到该配置」）。
  int? _lastImportRecordId;

  /// 最近一次导入**成功落库的全部**配置记录 id（一台设备多个源时有多条）。
  List<int> _importRecordIds = const [];
  List<AndroidDevice> _devices = const [];
  Map<String, BridgeConversion> _conversions = const {};
  BridgeStage? _stage;
  int _scanDone = 0;
  int _scanTotal = 0;

  // ---------------------------------------------------------------- 只读视图

  /// 是否已从磁盘读完设置。
  bool get loaded => _loaded;

  /// PC 的设备名（`/device` 与 `device` 参数用）。
  String get deviceName => _deviceName;

  /// PC 的稳定 uuid（`design/02` §8 Q5）。
  String get deviceUuid => _deviceUuid;

  String get maskedDeviceUuid =>
      _deviceUuid.length <= 4 ? '****' : '${_deviceUuid.substring(0, 4)}****';

  /// 同步服务端是否开启（默认 **false**，P3）。
  bool get serverEnabled => _serverEnabled;

  /// 是否允许向安卓推送（默认 **false**）。
  bool get pushEnabled => _pushEnabled;

  /// 是否同步含凭据的设置项（默认 **false**）。
  bool get settingsSyncEnabled => _settingsSyncEnabled;

  /// 服务端是否真的在监听（`serverEnabled` 且已成功绑定端口）。
  bool get serverRunning => _server?.isRunning ?? false;

  /// 实际监听端口；未启动时为 0。
  int get serverPort => _server?.port ?? 0;

  /// 服务端对外的可达基址。
  String? get serverBaseUrl => serverRunning ? _server!.baseUrl : null;

  /// 开启服务端前必须向用户展示的提示（P3，`design/02` §5）。
  String get serverBindHint =>
      '将监听 ${_server?.bindAddressHint ?? '0.0.0.0'}:'
      '$defaultPortStart–$defaultPortEnd（取首个可用端口），'
      '同局域网设备可访问；仅接受"已授权对端"的推送；可随时关闭，关闭后端口立即释放。';

  List<SyncPeer> get peers => List.unmodifiable(_peers);

  /// 已探测到的安卓设备（含桥接写入结果）。
  List<AndroidDevice> get devices => List.unmodifiable(_devices);

  AppError? get lastError => _lastError;
  String? get notice => _notice;

  /// 最近一次同步的明细（`applied/skipped/failed/total`）。
  SyncMergeStats? get lastStats => _lastStats;

  /// 最近一次操作的机器可读摘要（证据落盘与 UI 展示共用）。
  String? get lastOperation => _lastOperation;

  /// 最近一次成功导入桥接站点所创建的配置记录 id；无导入时为 `null`。
  int? get lastImportRecordId => _lastImportRecordId;

  /// 最近一次导入**成功落库的全部**记录 id（一台设备多个源时有多条）。
  List<int> get importRecordIds => _importRecordIds;

  bool get busy => _busy;
  BridgeStage? get stage => _stage;
  int get scanDone => _scanDone;
  int get scanTotal => _scanTotal;

  /// 某设备最近一次拉到的桥接转换结果（含诊断）。
  ///
  /// 多源导入时按设备只能给出"该设备最后一个源"的结果；要精确到源用
  /// [conversionOf]。
  BridgeConversion? conversionFor(String deviceBase) {
    final base = normalizeBase(deviceBase);
    final direct = _conversions[base];
    if (direct != null) return direct;
    // 多源导入只按 `base#interfaceKey` 存；设备卡片要的是"这台设备的最近一次
    // 转换结果"，因此回退到该设备任一源（用于展示主机修正与诊断）。
    final prefix = '$base#';
    for (final entry in _conversions.entries) {
      if (entry.key.startsWith(prefix)) return entry.value;
    }
    return null;
  }

  /// 某设备上**某一个源**的桥接转换结果（多源导入后按 interfaceKey 取）。
  BridgeConversion? conversionOf(String deviceBase, String interfaceKey) {
    final base = normalizeBase(deviceBase);
    final key = interfaceKey.trim();
    if (key.isEmpty) return _conversions[base];
    return _conversions['$base#$key'] ?? _conversions[base];
  }

  // ------------------------------------------------------------------ 加载

  /// 从 `<configDir>/settings.json` 的 `sync` 段读取设置。
  ///
  /// 读取失败（文件不存在/损坏）一律退回**默认关闭**，不阻塞启动
  /// （同 `TmdbConfigStore` 的口径）。
  Future<void> load() async {
    try {
      final file = File(settingsPath);
      Map<String, Object?> root = const {};
      if (await file.exists()) {
        final raw = await file.readAsString();
        if (raw.trim().isNotEmpty) {
          final decoded = jsonDecode(raw);
          if (decoded is Map) {
            root = decoded.map((key, value) => MapEntry('$key', value));
          }
        }
      }
      final section = asMap(root['sync']);
      _deviceUuid = asNonEmptyString(section['deviceUuid']) ?? _generateUuid();
      _deviceName =
          asNonEmptyString(section['deviceName']) ?? _defaultDeviceName();
      // 默认关闭：即使文件里写着 true，也要在显式 `save()` 之后才生效——
      // 这里直接读回用户上次的选择（用户已确认过），但**服务端不自动启动**。
      _serverEnabled = asFlag(section['serverEnabled']);
      _pushEnabled = asFlag(section['pushEnabled']);
      _settingsSyncEnabled = asFlag(section['settingsSyncEnabled']);
      _peers = asList(section['peers'])
          .map(SyncPeer.fromJson)
          .whereType<SyncPeer>()
          .toList();
      _deviceHistory =
          asList(section['devices'])
              .map(DeviceHistoryEntry.fromJson)
              .whereType<DeviceHistoryEntry>()
              .toList()
            ..sort((a, b) => b.lastUsedMs.compareTo(a.lastUsedMs));
      _lastBridgeAddress = asNonEmptyString(section['lastBridge']) ?? '';
      // 实时同步开关与游标（`design/01` §6.1、§9.1）。
      // 旧文件缺 `realtime` 段 → 全部默认关闭（“缺席 = 默认”，不写盘）。
      final realtime = asMap(section['realtime']);
      _realtime = RealtimeSyncSwitches(
        enabled: asFlag(realtime['enabled']),
        pullEnabled: asFlag(realtime['pullEnabled']),
        pushEnabled: asFlag(realtime['pushEnabled']),
        settingsEnabled: asFlag(realtime['settingsEnabled']),
        intervalSeconds:
            asInt(realtime['intervalSeconds']) ??
            realtimeDefaultIntervalSeconds,
        heartbeatSeconds:
            asInt(realtime['heartbeatSeconds']) ??
            keepAliveDefaultHeartbeatSeconds,
        pollAllSites: asFlag(realtime['pollAllSites']),
      ).normalized();
      _realtimePullCursorMs = asInt(realtime['pullCursorMs']) ?? 0;
      _realtimePullToken = asNonEmptyString(realtime['pullToken']) ?? '';
      // 身份注册表（`design/01` §3.2.1）。读不出来就当空表开始：
      // 空表最坏只会退化成「重新走一次 create」，不会错配身份。
      _playbackIdentity = PlaybackIdentityStore.fromJson(
        section['identity'],
        onChanged: () => unawaited(_persist()),
      );
      _loaded = true;
      if (section.isEmpty) {
        // 首次运行：把生成的 uuid 落盘，保证重启后安卓仍认同一台设备。
        await _persist();
      }
      log.info(
        '同步设置已读取：server=${_serverEnabled ? 'on' : 'off'} '
        'push=${_pushEnabled ? 'on' : 'off'} '
        'settings=${_settingsSyncEnabled ? 'on' : 'off'} '
        'realtime=$_realtime '
        'pullCursor=$_realtimePullCursorMs '
        'peers=${_peers.length} devices=${_deviceHistory.length} '
        'lastBridge=${redactUrl(_lastBridgeAddress)}',
        scope: 'sync',
      );
      // 用户上次已显式开启过实时同步 → 恢复定时器（与 `serverEnabled` 不同：
      // 路径 A 是**入站拉取**，不监听任何端口，恢复它不扩大攻击面）。
      if (_realtime.enabled) _syncRealtimeEngine();
    } catch (error) {
      _loaded = true;
      log.warning('读取同步设置失败，使用默认（全部关闭）：$error', scope: 'sync');
    }
    notifyListeners();
  }

  // ------------------------------------------------------------------ 开关

  /// 开启/关闭 PC 服务端监听（P3：只有用户显式开启才启动）。
  Future<bool> setServerEnabled(bool value) async {
    if (_serverEnabled == value && serverRunning == value) return true;
    _serverEnabled = value;
    _lastError = null;
    if (!value) {
      await _server?.stop();
      _server = null;
      _notice = '同步服务已关闭，端口已释放';
      log.info('同步服务已关闭', scope: 'sync');
      await _persist();
      notifyListeners();
      return true;
    }
    return _startServer();
  }

  Future<bool> _startServer() async {
    _busy = true;
    notifyListeners();
    try {
      final server = _server ??= _serverFactory(_buildServerHost());
      final port = await server.start();
      _notice =
          '同步服务已启动：${server.baseUrl}'
          '（仅接受已授权对端，可在设置中关闭）';
      log.info(
        '同步服务已启动 port=$port uuid=$maskedDeviceUuid'
        '（同局域网可访问，仅接受已授权对端）',
        scope: 'sync',
      );
      await _persist();
      return true;
    } on AppError catch (error) {
      _serverEnabled = false;
      _server = null;
      _lastError = error;
      log.error('同步服务启动失败：${error.logLine}', scope: 'sync');
      return false;
    } catch (error) {
      _serverEnabled = false;
      _server = null;
      _lastError = AppError(
        AppErrorKind.syncPortUnavailable,
        '同步服务无法启动：$error',
        cause: error,
      );
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// 开启/关闭向安卓推送（P3：数据外发默认关闭）。
  Future<void> setPushEnabled(bool value) async {
    _pushEnabled = value;
    _notice = value ? '已允许向已授权设备推送' : '已停止向安卓推送';
    log.info('向安卓推送：${value ? '已开启' : '已关闭'}', scope: 'sync');
    await _persist();
    notifyListeners();
  }

  /// 开启/关闭含凭据的设置同步（P3 + §19）。
  Future<void> setSettingsSyncEnabled(bool value) async {
    _settingsSyncEnabled = value;
    _notice = value ? '将同步包含凭据的设置项（TMDB 等），请确认对端可信' : '已停止同步设置项';
    log.warning('含凭据的设置同步：${value ? '已开启（用户显式确认）' : '已关闭'}', scope: 'sync');
    await _persist();
    notifyListeners();
  }

  // ------------------------------------------------------------- 实时同步

  /// 实时同步开关矩阵（`design/01` §6.1）。
  RealtimeSyncSwitches get realtime => _realtime;

  /// 引擎状态快照（未启动时为 `null`，UI 据此展示「未开启」）。
  RealtimeEngineSnapshot? get realtimeSnapshot => _realtimeEngine?.snapshot();

  /// 路径 A 的拉取游标（毫秒）。
  int get realtimePullCursorMs => _realtimePullCursorMs;

  /// 实时同步当前指向的安卓基址（优先最近接入的线路，其次已授权对端）。
  String? get realtimeDeviceBase {
    if (_lastBridgeAddress.isNotEmpty) return _lastBridgeAddress;
    for (final peer in _peers) {
      if (peer.address.isNotEmpty) return peer.address;
    }
    return null;
  }

  /// 开关实时同步总开关。
  ///
  /// 关闭时**保留**子开关值与游标（`design/01` §6.2 规则 3：下次开启沿用）。
  Future<bool> setRealtimeEnabled(bool value) =>
      _applyRealtime(_realtime.copyWith(enabled: value));

  /// 开关实时拉取（路径 A）。
  Future<bool> setRealtimePull(bool value) =>
      _applyRealtime(_realtime.copyWith(pullEnabled: value));

  /// 开关实时推送（路径 B：把 PC 的拉取端点暴露给安卓）。
  Future<bool> setRealtimePush(bool value) =>
      _applyRealtime(_realtime.copyWith(pushEnabled: value));

  /// 开关设置实时同步（含凭据项，必须已开启 Phase 5 的设置同步）。
  Future<bool> setRealtimeSettings(bool value) =>
      _applyRealtime(_realtime.copyWith(settingsEnabled: value));

  /// 设置轮询周期（非法值吸附到最近合法档位并在 UI 回显）。
  Future<bool> setRealtimeIntervalSeconds(int seconds) =>
      _applyRealtime(_realtime.copyWith(intervalSeconds: seconds));

  /// 设置心跳周期（同上，且不得大于轮询周期）。
  Future<bool> setRealtimeHeartbeatSeconds(int seconds) =>
      _applyRealtime(_realtime.copyWith(heartbeatSeconds: seconds));

  /// 是否轮询全部站点（否则只轮询最近活跃的 N 个）。
  Future<bool> setRealtimePollAllSites(bool value) =>
      _applyRealtime(_realtime.copyWith(pollAllSites: value));

  /// 设置路径 B 的可选 token（空串 = 只靠 uuid 白名单）。
  Future<void> setRealtimePullToken(String token) async {
    _realtimePullToken = token.trim();
    _notice = _realtimePullToken.isEmpty
        ? '已清除 pull token（仅接受已授权设备）'
        : '已设置 pull token（安卓远端同步源需填同一个）';
    log.info(
      'pull token：${_realtimePullToken.isEmpty ? '已清除' : '已设置'}',
      scope: 'realtime',
    );
    // 服务端 host 里的 token 是构造时快照的：必须重建才能生效。
    await _rebuildServerForTokenChange();
    await _persist();
    notifyListeners();
  }

  /// 应用一组开关变更（联动规则 → 持久化 → 同步引擎）。
  ///
  /// 返回 `false` 表示被联动规则**拒绝**（开关值不变，`lastError` 已置位）。
  Future<bool> _applyRealtime(RealtimeSyncSwitches desired) async {
    final decision = applyRealtimeSwitchRules(
      desired: desired,
      serverEnabled: _serverEnabled || serverRunning,
      settingsSyncEnabled: _settingsSyncEnabled,
    );
    if (decision.rejected) {
      _lastError = decision.error;
      _notice = decision.error?.message;
      log.warning('实时同步开关被拒绝：${decision.error?.message}', scope: 'realtime');
      notifyListeners();
      return false;
    }

    _lastError = null;
    _realtime = decision.switches;
    log.info('实时同步开关：$_realtime', scope: 'realtime');

    // 规则 1：路径 B 需要服务端在听，否则安卓拉不到。
    if (decision.autoEnabledServer) {
      final started = await setServerEnabled(true);
      if (!started) {
        // 服务端起不来 → 推送方向不直说已开启，避免给用户假预期。
        _realtime = _realtime.copyWith(pushEnabled: false);
        _notice = '「实时推送」需要局域网同步服务，但服务启动失败，已关闭该方向';
        await _persist();
        _syncRealtimeEngine();
        notifyListeners();
        return false;
      }
      _notice = '已自动开启局域网同步服务（「实时推送」需要它）';
    }

    await _persist();
    _syncRealtimeEngine();
    notifyListeners();
    return true;
  }

  /// 手动「立即重连」（`design/02` §5.2：失败上限后只能手动恢复）。
  Future<void> retryRealtimeNow() async {
    final engine = _realtimeEngine;
    if (engine == null) {
      _syncRealtimeEngine();
      await _realtimeEngine?.retryNow();
    } else {
      await engine.retryNow();
    }
    await _persist();
    notifyListeners();
  }

  /// 重置拉取游标并立即重跑一轮（游标错位 / 安卓重装后的恢复手段）。
  Future<void> resetRealtimeCursor() async {
    final engine = _realtimeEngine;
    if (engine == null) return;
    await engine.resetCursorAndPoll();
    _realtimePullCursorMs = engine.cursor;
    await _persist();
    notifyListeners();
  }

  /// 手动「拉取最近记录」（`design/01` §4.4 的 [RealtimeManualPullKind.recentRecords]）。
  ///
  /// **不依赖服务端、不要求实时总开关**：它只读安卓的 HTTP 端点，
  /// 是用户在实时同步关着、或拉取方向被 403 停止时的逃生口。
  ///
  /// 引擎没跑时临时建一个（不排定时器），跑完立即停。
  Future<RealtimePollResult?> manualPullRecentRecords() async {
    final base = realtimeDeviceBase;
    final precheck = precheckManualPull(
      kind: RealtimeManualPullKind.recentRecords,
      realtimeEnabled: _realtime.enabled,
      serverEnabled: _serverEnabled || serverRunning,
      peerReachable: base != null,
      peerAddress: base ?? '',
    );
    if (!precheck.allowed) {
      _lastError = precheck.error;
      _notice = precheck.error?.message ?? '尚未接入安卓设备';
      notifyListeners();
      return null;
    }

    _busy = true;
    _lastError = null;
    _notice = null;
    notifyListeners();
    final engine = _realtimeEngine;
    final temporary = engine == null;
    final runner =
        engine ??
        RealtimeSyncEngine(
          log: log,
          host: _buildRealtimeHost(),
          scheduler: _realtimeScheduler,
          switches: _realtime,
          pullCursorMs: _realtimePullCursorMs,
        );
    try {
      final result = await runner.pollNow(manual: true);
      _lastPollResult = result;
      _realtimePullCursorMs = runner.cursor;
      _notice = result == null
          ? '没有可拉取的站点（请先导入安卓站源）'
          : '手动拉取完成：${result.stats.describe()}'
                '${result.degradedSites.isEmpty ? '' : '（${result.degradedSites.length} 个站点仅能取当前播放）'}';
      if (result?.error != null) _lastError = result!.error;
      return result;
    } on AppError catch (error) {
      _lastError = error;
      return null;
    } finally {
      // 临时引擎必须立即释放：它身上的定时器一个都不能留（G12）。
      if (temporary) runner.stop();
      _busy = false;
      await _persist();
      notifyListeners();
    }
  }

  /// 手动「请求安卓推送全量」（`Request Android push`）。
  ///
  /// 与 [manualPullRecentRecords] 的区别：这条是**让安卓主动推**，
  /// 因此必须有本机服务端在听、且对端已授权（`design/01` §4.4）。
  Future<SyncPushResult?> requestAndroidPushFull() async {
    final base = realtimeDeviceBase;
    final precheck = precheckManualPull(
      kind: RealtimeManualPullKind.requestAndroidPush,
      realtimeEnabled: _realtime.enabled,
      serverEnabled: _serverEnabled || serverRunning,
      peerReachable: base != null,
      peerAddress: base ?? '',
    );
    if (!precheck.allowed) {
      // S22：必须给 `syncDisabled` 而不是网络错误（用户要能看懂该怎么办）。
      _lastError = precheck.error;
      _notice = precheck.error?.message;
      notifyListeners();
      return null;
    }
    final peer = _peerForAddress(base!);
    if (peer == null) {
      _lastError = AppError(
        AppErrorKind.syncPeerUnreachable,
        '目标设备尚未授权，请先在「已授权对端」中授权',
        detail: redactUrl(base),
      );
      _notice = _lastError!.message;
      notifyListeners();
      return null;
    }
    return pullFrom(peer);
  }

  /// 按地址找已授权对端（手动操作需要它的 uuid 与名称）。
  SyncPeer? _peerForAddress(String address) {
    final normalized = normalizeBase(address);
    for (final peer in _peers) {
      if (normalizeBase(peer.address) == normalized) return peer;
    }
    return null;
  }

  /// 最近一次实时/手动拉取的结果（UI 披露用）。
  RealtimePollResult? get lastPullResult => _lastPollResult;

  /// 路径 A 当前的能力探测结论（缓存 60 s；未探测过为 `null`）。
  ///
  /// 单独暴露：手动拉取用的是**临时**引擎，它的快照不会留在
  /// `realtimeSnapshot` 里，但「降级/不支持」的披露必须照样上屏（P5）。
  RealtimePullCapability? get realtimePullCapability =>
      _realtimeCapability.read(DateTime.now());

  /// 最近一轮走过 `/current` 降级端点的站点。
  List<String> get realtimeDegradedSites =>
      _realtimeEngine?.snapshot().degradedSites ??
      _lastPollResult?.degradedSites ??
      const [];

  /// 按当前开关与设备可用性启动/停止引擎，并把变更交给运行中的引擎。
  ///
  /// **不在这里做安全判定**：能不能跑完全由 [RealtimeSyncSwitches] 决定
  /// （总开关 + 方向），避免两处各有一套“什么时候该跑”的逻辑。
  void _syncRealtimeEngine() {
    final shouldRun =
        _realtime.enabled && realtimeDeviceBase != null && _loaded;
    final engine = _realtimeEngine;
    if (!shouldRun) {
      engine?.stop();
      return;
    }
    if (engine == null) {
      _realtimeEngine = RealtimeSyncEngine(
        log: log,
        host: _buildRealtimeHost(),
        scheduler: _realtimeScheduler,
        switches: _realtime,
        pullCursorMs: _realtimePullCursorMs,
      )..start();
      return;
    }
    engine.applySwitches(_realtime);
    if (!engine.isRunning) engine.start();
  }

  /// 判定这次实时拉取的历史该归属哪个源。
  ///
  /// 归属是**设备级**的，不是「设备 + 站点」：安卓的 `/api/playback/history`
  /// 只按 `VodConfig.getCid()`（设备**当前激活**的那份配置）查库，站点只是
  /// 过滤条件，响应里也没有任何配置标识。所以唯一可靠的答案是「设备此刻
  /// 激活的是哪个源」，也就是 `/manage/configs` 里 `active=true` 的那一项。
  ///
  /// 判不出来就返回空串（**不猜**）：空来源的记录只会在「全部来源」里出现，
  /// 而猜错会把进度写进别的源——那是串源，比如实显示的「来源未知」严重得多。
  ///
  /// 三种情况都会返回空串：
  /// - 基址对不上任何已知设备（用户手填了别的地址）；
  /// - 设备连不上，或老安卓没有 `/manage/configs`（清单里没有 `active`）；
  /// - 归属本身无法成立（缺设备 uuid 或接口标识）。
  Future<String> _resolveRealtimeSourceKey({required String deviceBase}) async {
    final base = normalizeBase(deviceBase);
    if (base.isEmpty) return '';
    final deviceUuid = _deviceUuidOfBase(base);
    if (deviceUuid.isEmpty) return '';
    final AndroidSourceCatalog catalog;
    try {
      catalog = await _bridge.fetchSources(base);
    } on AppError catch (error) {
      // 设备掉线是常态（手机可能关着）：这轮不归属，下轮再判，
      // 不能因为一次取不到清单就把整轮拉取打断。
      log.debug('实时归属：取配置清单失败 ${error.logLine}', scope: 'realtime');
      return '';
    }
    final active = catalog.active;
    if (active == null) return '';
    return BridgeSourceKey.of(
      deviceUuid: deviceUuid,
      interfaceKey: active.interfaceKey,
    );
  }

  /// 设备基址 → 已登记设备的 uuid；对不上返回空串。
  String _deviceUuidOfBase(String base) {
    for (final entry in _deviceHistory) {
      if (normalizeBase(entry.address) == base) return entry.uuid.trim();
    }
    for (final peer in _peers) {
      if (normalizeBase(peer.address) == base) return peer.uuid.trim();
    }
    return '';
  }

  /// 引擎的 I/O 端口（`design/01` §4、`design/02` §3）。
  RealtimeEngineHost _buildRealtimeHost() => RealtimeEngineHost(
    deviceBase: () => realtimeDeviceBase,
    siteKeys: ({required bool all}) =>
        host.syncSiteKeys(all: all, limit: realtimeDefaultSiteLimit),
    resolveSourceKey: ({required String deviceBase}) =>
        _resolveRealtimeSourceKey(deviceBase: deviceBase),
    probeCapability: (base) async {
      // 缓存 60 s（`design/01` §4.1）：默认 60 s 轮询下，等于每轮只探一次。
      final cached = _realtimeCapability.read(DateTime.now());
      if (cached != null) return cached;
      final probe = await _readClient.probePullCapability(base);
      _realtimeCapability.write(probe.capability, DateTime.now());
      final disclosure = pullCapabilityError(probe.capability);
      if (disclosure != null) {
        log.warning(
          '${probe.describe()} ${disclosure.logLine}',
          scope: 'realtime',
        );
      }
      return probe.capability;
    },
    readSite:
        ({
          required String deviceBase,
          required String siteKey,
          required RealtimePullCapability capability,
          required Map<String, SyncHistoryItem> localByMatchKey,
        }) async {
          final result = await _readClient.readHistory(
            deviceBase: deviceBase,
            siteKey: siteKey,
            capability: capability,
            localByMatchKey: localByMatchKey,
          );
          return RealtimeSiteReadResult(
            items: result.items,
            // 解析失败 = 记录本身不可合并（集名与地址双空、身份键不成段）：
            // **永久性**失败，下轮重试也是同样结果 → 计入 `unmergeable`
            // （仍披露，但不阻止游标推进）。
            unmergeable: result.failures.length,
            skippedAsUnchanged: result.skippedAsUnchanged,
            endpoint: result.endpoint,
            // 降级端点返回空 = 「当前没在放」的合法形态（不是失败）。
            notFound:
                result.endpoint == RealtimePullCapability.currentOnly &&
                result.items.isEmpty &&
                result.failures.isEmpty,
          );
        },
    mergeHistory: (items, {required String sourceKey}) async {
      final stats = _mergeHistory(
        SyncHistoryParseResult(items: items, failures: const []),
        // 必须带来源：不带就落成空 source_key，历史页「当前来源」里会冒出
        // 一堆「来源未知」卡片（用户 2026-10-28 反馈的缺陷）。
        sourceKey: sourceKey,
      );
      if (stats.applied > 0) {
        // 落库后要把内存视图刷新：否则历史页要等用户手动刷新才看得到。
        host.notifySyncedDataChanged();
      }
      _persistRealtimeCursor();
      return stats;
    },
    heartbeat: (base) => _readClient.heartbeat(base),
    localHistoryByMatchKey: () =>
        host.syncDatabase?.historySyncIndex() ?? const {},
  );

  /// 把引擎的游标回写本地并落盘（节流：只在变化时写）。
  void _persistRealtimeCursor() {
    final engine = _realtimeEngine;
    if (engine == null) return;
    if (engine.cursor == _realtimePullCursorMs) return;
    _realtimePullCursorMs = engine.cursor;
    unawaited(_persist());
  }

  /// token / 身份注册表变化后重建服务端：`SyncServerHost` 是构造时快照的。
  Future<void> _rebuildServerForTokenChange() async {
    if (_server == null) return;
    await _server?.stop();
    _server = null;
    if (_serverEnabled) await _startServer();
  }

  // ------------------------------------------------------------- 对端白名单

  /// 授权一台对端（同 uuid 视为同一设备，`design/01` §4.3）。
  Future<void> authorizePeer(AndroidDevice device) async {
    final peer = SyncPeer(
      uuid: device.uuid,
      name: device.name,
      address: device.reachableBase,
    );
    _peers = [..._peers.where((item) => item.uuid != peer.uuid), peer];
    _notice = '已授权设备 ${device.name}（${peer.maskedUuid}）';
    log.info(
      '授权同步对端 ${device.name} ${peer.maskedUuid} @ ${device.reachableBase}',
      scope: 'sync',
    );
    await _persist();
    notifyListeners();
  }

  Future<void> revokePeer(String uuid) async {
    _peers = _peers.where((peer) => peer.uuid != uuid).toList();
    _notice = '已移除设备授权';
    log.info(
      '移除同步对端 ${SyncPeer(uuid: uuid, name: '', address: '').maskedUuid}',
      scope: 'sync',
    );
    await _persist();
    notifyListeners();
  }

  /// 对端是否已授权：[identity] 可以是 uuid，也可以是 IP。
  ///
  /// 为什么允许 IP：安卓推送历史/收藏的 `FormBody` 只带 `config`/`targets`
  /// （`Action.sendHistory` 源码），**不带**设备标识，只认 uuid 会让接收永远 403。
  bool isPeerAuthorized(String identity) {
    if (identity.isEmpty) return false;
    for (final peer in _peers) {
      if (peer.uuid == identity) return true;
      final host = Uri.tryParse(peer.address)?.host;
      if (host != null && host == identity) return true;
    }
    return false;
  }

  // ------------------------------------------------------------- 设备探测

  /// 设备接入历史（最近使用倒序）。
  List<DeviceHistoryEntry> get deviceHistory =>
      List.unmodifiable(_deviceHistory);

  /// 最近一次成功接入的地址（未接入过时为空串）。
  String get lastBridgeAddress => _lastBridgeAddress;

  /// 记录一次**成功接入**（探测成功或导入成功时调用）。
  ///
  /// 同一设备（按 uuid，未知时按地址）只保留最新一条，并把它提到最前；
  /// 同时把地址记为「最近使用的桥接线路」，供下次启动自动接入。
  ///
  /// [persist] 为 false 时只改内存（调用方随后会自己落盘，避免同一流程里连写两次
  /// 设置文件——`_persist` 是「写 .tmp → 删旧 → rename」，连写会放大文件锁窗口）。
  Future<void> _rememberDevice({
    required String uuid,
    required String name,
    required String address,
    bool persist = true,
  }) async {
    final base = normalizeBase(address);
    if (base.isEmpty) return;
    final id = uuid.trim().isEmpty ? base : uuid.trim();
    final entry = DeviceHistoryEntry(
      uuid: id,
      name: name.trim().isEmpty ? Uri.parse(base).host : name.trim(),
      address: base,
      lastUsedMs: DateTime.now().millisecondsSinceEpoch,
    );
    final next = <DeviceHistoryEntry>[
      entry,
      for (final item in _deviceHistory)
        if (item.uuid != id && item.address != base) item,
    ];
    _deviceHistory = next.length > maxDeviceHistory
        ? next.sublist(0, maxDeviceHistory)
        : next;
    _lastBridgeAddress = base;
    log.info(
      '已记录设备接入历史 name=${entry.name} address=${redactUrl(base)} '
      'history=${_deviceHistory.length}',
      scope: 'bridge',
    );
    // 设备变了 → 实时引擎的轮询目标跟着变（否则会一直打旧设备）。
    _realignRealtimeDevice();
    if (persist) await _persist();
  }

  /// 设备基址变化后重新对齐引擎。
  ///
  /// `RealtimeEngineHost.deviceBase` 是回调，引擎会实时读到新值；但引擎
  /// 若因为「之前没接入设备」而停着，就需要重新启动一次。另外能力缓存
  /// 必须失效：换设备后旧设备的降级结论不适用（`design/01` §4.1）。
  void _realignRealtimeDevice() {
    _realtimeCapability.invalidate();
    final engine = _realtimeEngine;
    if (engine != null && engine.isRunning) {
      // 正在跑：先停再起，让心跳马上用新地址，而不是等到下个周期。
      engine.stop();
    }
    _syncRealtimeEngine();
  }

  /// 删除一条设备历史（用户在接入页手动清理）。
  Future<void> forgetDevice(String uuid) async {
    final next = _deviceHistory.where((item) => item.uuid != uuid).toList();
    if (next.length == _deviceHistory.length) return;
    _deviceHistory = next;
    // 删掉的正好是「最近使用」时，把指针移到新的第一条，避免自动接入一个
    // 用户已经删掉的地址。
    if (!next.any((item) => item.address == _lastBridgeAddress)) {
      _lastBridgeAddress = next.isEmpty ? '' : next.first.address;
      _realignRealtimeDevice();
    }
    await _persist();
    notifyListeners();
  }

  /// 探测一个地址并（成功时）记录下来（`design/01` §4.3）。
  Future<AndroidDevice?> probe(String address) async {
    _busy = true;
    _stage = BridgeStage.probingDevice;
    _lastError = null;
    _notice = null;
    notifyListeners();
    try {
      final device = await _bridge.probeDevice(address);
      if (!_devices.any((item) => item.uuid == device.uuid)) {
        _devices = [..._devices, device];
      }
      await _rememberDevice(
        uuid: device.uuid,
        name: device.name,
        address: device.reachableBase,
      );
      _notice = '已识别设备 ${device.name}（${device.typeLabel}）';
      return device;
    } on AppError catch (error) {
      _lastError = error;
      log.warning('设备探测失败：${error.logLine}', scope: 'bridge');
      return null;
    } catch (error) {
      _lastError = AppError(
        AppErrorKind.bridgeUnreachable,
        '设备探测失败：$error',
        cause: error,
      );
      return null;
    } finally {
      _busy = false;
      _stage = null;
      notifyListeners();
    }
  }

  /// 启动时尝试自动接入最近使用的桥接线路。
  ///
  /// 用户需求（2026-10-09）：「如果最近使用的是桥接线路且该线路还能连上应该
  /// 自动接入」。因此这里只**探测**一个地址（即历史里最近使用的那条），
  /// 探不通就安静放弃——不扫描、不轮询、不打扰用户（扫描是用户显式动作，
  /// `design/01` §4.4）。
  ///
  /// 返回探到的设备；未接入过、不可达或已在运行都返回 `null`。
  /// 调用方（UI）拿到非空结果后再决定是否导入站点。
  Future<AndroidDevice?> tryAutoConnect() async {
    final target = _lastBridgeAddress.isNotEmpty
        ? _lastBridgeAddress
        : (_deviceHistory.isEmpty ? '' : _deviceHistory.first.address);
    if (target.isEmpty) return null;
    if (_busy) return null;
    log.info('尝试自动接入最近使用的桥接线路 address=${redactUrl(target)}', scope: 'bridge');
    // 自动接入**不弹错误**：探不通只是「上次那台设备不在」，不应该在启动时
    // 给用户一个红色错误横幅。因此这里不写 _lastError。
    _busy = true;
    _stage = BridgeStage.probingDevice;
    notifyListeners();
    try {
      final device = await _probeAndRemember(target);
      log.info(
        '自动接入成功 name=${device.name} address=${redactUrl(device.reachableBase)}',
        scope: 'bridge',
      );
      return device;
    } catch (error) {
      log.info('自动接入未成功（按预期安静放弃）：$error', scope: 'bridge');
      return null;
    } finally {
      _busy = false;
      _stage = null;
      notifyListeners();
    }
  }

  /// 探测一个**点名**的历史地址（上次使用的桥接源所属设备）。
  ///
  /// 与 [tryAutoConnect] 的区别只有一个关键的：目标不是「历史里最近那条」，
  /// 而是上次真正在用的那台设备。用户可能中途接过别的设备，按「最近」接入会
  /// 把他带到他并不想用的那一台上。
  ///
  /// 失败时把**分类**写进 [lastError] 并返回 `null`：这条路径的调用方要用分类
  /// 给出一条可解释的非阻塞横幅，而不是猜「大概是连不上」。
  Future<AndroidDevice?> probeAutoConnectTarget(String address) async {
    final target = normalizeBase(address);
    if (target.isEmpty) {
      _lastError = AppError(
        AppErrorKind.bridgeUnreachable,
        '找不到上次使用的安卓设备地址（设备接入历史里没有这台设备）',
        detail: address,
      );
      log.warning('自动接入无法定位设备地址：deviceHistory 里没有该设备', scope: 'bridge');
      notifyListeners();
      return null;
    }
    if (_busy) return null;
    log.info('尝试恢复上次使用的桥接源 address=${redactUrl(target)}', scope: 'bridge');
    _busy = true;
    _stage = BridgeStage.probingDevice;
    _lastError = null;
    notifyListeners();
    try {
      final device = await _probeAndRemember(target);
      log.info(
        '恢复桥接源成功 name=${device.name} '
        'address=${redactUrl(device.reachableBase)}',
        scope: 'bridge',
      );
      return device;
    } on AppError catch (error) {
      _lastError = error;
      log.warning('恢复桥接源失败：${error.logLine}', scope: 'bridge');
      return null;
    } catch (error) {
      _lastError = AppError(
        AppErrorKind.bridgeUnreachable,
        '设备探测失败：$error',
        cause: error,
      );
      log.warning('恢复桥接源失败：$error', scope: 'bridge');
      return null;
    } finally {
      _busy = false;
      _stage = null;
      notifyListeners();
    }
  }

  /// 探测并记住设备（[tryAutoConnect] 与 [probeAutoConnectTarget] 共用）。
  Future<AndroidDevice> _probeAndRemember(String target) async {
    final device = await _bridge.probeDevice(target);
    if (!_devices.any((item) => item.uuid == device.uuid)) {
      _devices = [..._devices, device];
    }
    await _rememberDevice(
      uuid: device.uuid,
      name: device.name,
      address: device.reachableBase,
    );
    return device;
  }

  /// 扫描局域网（仅用户显式触发，`design/01` §4.4）。
  Future<List<AndroidDevice>> scan({bool Function()? shouldStop}) async {
    _busy = true;
    _lastError = null;
    _scanDone = 0;
    _scanTotal = 0;
    notifyListeners();
    try {
      final found = await _bridge.scan(
        onFound: (device) {
          if (!_devices.any((item) => item.uuid == device.uuid)) {
            _devices = [..._devices, device];
          }
          notifyListeners();
        },
        onProgress: (done, total) {
          _scanDone = done;
          _scanTotal = total;
          notifyListeners();
        },
        shouldStop: () async => shouldStop?.call() ?? false,
      );
      _notice = found.isEmpty
          ? '未发现安卓设备（请确认手机与 PC 在同一局域网，'
                '或在手机上打开 WebHTV 的局域网服务）'
          : '发现 ${found.length} 台安卓设备';
      return found;
    } catch (error) {
      _lastError = AppError(
        AppErrorKind.bridgeUnreachable,
        '局域网扫描失败：$error',
        cause: error,
      );
      return const [];
    } finally {
      _busy = false;
      _scanDone = 0;
      _scanTotal = 0;
      notifyListeners();
    }
  }

  // ------------------------------------------------------------- 站点导入

  /// 拉取并导入站点（`design/01` §5；用户反馈 2026-10-26 后改为**全量源**）。
  ///
  /// 桥接的正确语义是「安卓只是运行容器」：把它上面**所有**点播源都拉过来，
  /// 每个源各成一条 PC 配置记录（可切换），而不是造一条"桥接源"。
  /// 因此这里先读 `/manage/configs` 拿到源清单，再对每条源用
  /// `/vod/api?ac=config&configKey=<interfaceKey>` 取**该源自己的**站点，
  /// 全程不切换安卓的当前配置（对齐 P3）。
  ///
  /// 导入产生/更新**本机记录**且**不覆盖当前配置**（Q10）。
  /// 取「本次导入要归属的设备」：已探测过就直接用，否则**补一次探测**。
  ///
  /// 为什么要补探测：源标识里的设备段必须是设备的稳定 uuid。以前这里在
  /// 找不到已探测设备时退化用地址当 uuid，导入出来的 source_key 就变成
  /// `bridge|http://192.168.50.9:9978|a`——设备换个 IP 就与自己的历史断链，
  /// 而且和 UI 先探测再导入的路径产生两套标识（同一台设备两条记录）。
  /// 探测失败仍退回地址，保证「设备能连但 /device 不可用」的旧形态不被打断。
  Future<AndroidDevice> _deviceForImport(String base) async {
    for (final item in _devices) {
      if (item.reachableBase == base) return item;
    }
    AndroidDevice device;
    try {
      device = await _bridge.probeDevice(base);
    } on AppError {
      device = AndroidDevice(
        uuid: base,
        name: Uri.parse(base).host,
        reachableBase: base,
      );
    }
    if (!_devices.any((item) => item.uuid == device.uuid)) {
      _devices = [..._devices, device];
    }
    return device;
  }

  /// [interfaceKey] 非空时只导入该源（单源重拉）。
  Future<bool> importSites(
    String address, {
    String? interfaceKey,
    bool Function()? isCurrent,
    void Function(int recordId, String candidate)? onSaved,
  }) async {
    final current = isCurrent ?? beginConfigMutation?.call() ?? () => true;
    final saved = onSaved ?? onBridgeConfigSaved;

    _busy = true;
    _stage = BridgeStage.probingDevice;
    _lastError = null;
    _notice = null;
    _lastImportRecordId = null;
    _importRecordIds = const [];
    notifyListeners();
    try {
      final base = normalizeBase(address);
      final device = await _deviceForImport(base);
      final selfBase = serverRunning ? _server!.baseUrl : null;

      // 1) 源清单：拿不到（老安卓）就退化为"只导入当前激活源"的老路径。
      _stage = BridgeStage.fetchingSources;
      notifyListeners();
      AndroidSourceCatalog catalog;
      try {
        catalog = await _bridge.fetchSources(base);
      } on AppError catch (error) {
        // 404/网关缺失 = 老安卓没有 `/manage/configs`：退回只导入当前激活源，
        // 而不是把「设备上多个源」这个新能力变成整条导入失败的理由。
        if (error.kind != AppErrorKind.bridgeNoGateway) rethrow;
        catalog = const AndroidSourceCatalog();
      }
      final wanted = interfaceKey?.trim() ?? '';
      final targets = wanted.isEmpty
          ? catalog.sources
          : [
              for (final source in catalog.sources)
                if (source.interfaceKey == wanted) source,
            ];
      if (targets.isEmpty) {
        if (wanted.isNotEmpty) {
          throw AppError(
            AppErrorKind.bridgeUnreachable,
            '安卓设备上找不到该配置（$wanted），可能已被删除',
            detail: base,
          );
        }
        // 老安卓：没有 /manage/configs，退回只导入当前激活源。
        return await _importActiveSourceOnly(
          base,
          device,
          selfBase,
          catalog,
          current,
          saved,
        );
      }

      // 2) 直播源只取一次（设备级），每条源记录都共享它。
      final liveSources = await _bridge.fetchLiveSources(base);

      // 3) 逐源取站点并落库：一台设备多个源时，origin 全是网关地址，
      //    只有 sourceKey 能把它们区分开（见 storage.saveConfig 去重键）。
      final savedIds = <int>[];
      final failures = <String>[];
      // 每个源的失败分类都要留着：设备级故障（网关 404、站点为空、主机不匹配）
      // 会让**所有**源以同一分类失败，此时必须原样冒泡那个分类，而不是把
      // 「站点为空」折叠成 bridgeUnreachable —— 后者会让用户无法区分
      // 「设备上有源但都取不到」和「设备根本连不上」。
      final failureKinds = <AppErrorKind>[];
      AppError? singleFailure;
      var totalSites = 0;
      var totalLive = 0;
      for (final source in targets) {
        _stage = BridgeStage.fetchingConfig;
        notifyListeners();
        try {
          final conversion = await _bridge.fetchGatewayConfig(
            base,
            selfBase: selfBase,
            interfaceKey: source.interfaceKey,
            onStage: (stage) {
              _stage = stage;
              notifyListeners();
            },
          );
          final candidate = conversion.tmdbApiKeyCandidate;
          _conversions = {
            ..._conversions,
            '$base#${source.interfaceKey}': conversion
                .withoutTmdbApiKeyCandidate(),
          };
          var bridgedConfig = conversion.config;
          if (liveSources.isNotEmpty && bridgedConfig.lives.isEmpty) {
            bridgedConfig = bridgedConfig.copyWith(lives: liveSources);
          }
          if (!current()) return false;
          final recordId = await host.saveBridgeConfig(
            name: source.displayName,
            origin: base,
            config: bridgedConfig,
            diagnostics: [
              ...conversion.diagnostics,
              if (catalog.diagnostics.isNotEmpty) catalog.diagnostics.first,
            ],
            deviceUuid: device.uuid,
            interfaceKey: source.interfaceKey,
            configUrl: source.url,
          );
          if (!current()) return false;
          if (recordId == null) {
            failures.add('${source.displayName}：保存配置记录失败（数据库不可用）');
            continue;
          }
          saved?.call(recordId, candidate);
          savedIds.add(recordId);
          totalSites += conversion.siteCount;
          totalLive += bridgedConfig.lives.length;
        } on AppError catch (error) {
          failures.add('${source.displayName}：${error.message}');
          failureKinds.add(error.kind);
          if (targets.length == 1) singleFailure = error;
        }
      }

      if (savedIds.isEmpty && singleFailure != null) throw singleFailure;

      // 全部失败且分类一致 → 这是**设备级**故障，冒泡原始分类（P5：能力缺口
      // 必须披露，不得折叠）。只有分类混杂时才退化成汇总错误。
      if (savedIds.isEmpty &&
          failureKinds.length == targets.length &&
          failureKinds.toSet().length == 1) {
        throw AppError(
          failureKinds.first,
          '安卓桥接导入失败：${failures.first}',
          detail: base,
        );
      }

      if (savedIds.isEmpty) {
        throw AppError(
          failures.isEmpty
              ? AppErrorKind.storage
              : AppErrorKind.bridgeUnreachable,
          '安卓桥接导入失败：${failures.isEmpty ? '没有可保存的源' : failures.first}',
          detail: base,
        );
      }

      if (!current()) return false;
      // 4) 设备历史与白名单：最后只落一次盘。
      // `_persist` 是「写 .tmp → 删旧 → rename」，同一流程里连写两次会放大文件锁
      // 窗口（测试环境下会让 `settleIo` 的固定帧数不够用）。
      await _rememberDevice(
        uuid: device.uuid,
        name: device.name,
        address: device.reachableBase,
        persist: false,
      );
      await authorizePeer(device);
      if (!current()) return false;

      _importRecordIds = List.unmodifiable(savedIds);
      // 供 UI 在导入后询问「是否切换到该配置」（单源重拉时就是该源）。
      _lastImportRecordId = savedIds.first;
      _notice =
          '已从 ${_hostOf(base)} 导入 ${savedIds.length} 个播放源'
          '（$totalSites 个站点${totalLive == 0 ? '' : '、$totalLive 个直播源'}）'
          '${failures.isEmpty ? '' : '；${failures.length} 个源失败：${failures.first}'}';
      _lastOperation =
          'bridge-import sources=${savedIds.length}/${targets.length} '
          'sites=$totalSites lives=$totalLive failed=${failures.length}';
      log.info(
        '安卓桥接导入完成 sources=${savedIds.length}/${targets.length} '
        'sites=$totalSites lives=$totalLive failed=${failures.length} '
        'records=${savedIds.join(",")}',
        scope: 'bridge',
      );
      return true;
    } on AppError catch (error) {
      _lastError = error;
      log.warning('安卓桥接导入失败：${error.logLine}', scope: 'bridge');
      return false;
    } catch (error) {
      _lastError = AppError(
        AppErrorKind.bridgeUnreachable,
        '安卓桥接导入失败：$error',
        cause: error,
      );
      return false;
    } finally {
      _busy = false;
      _stage = null;
      notifyListeners();
    }
  }

  /// 老安卓退路：没有 `/manage/configs` 时只能拉当前激活源。
  Future<bool> _importActiveSourceOnly(
    String base,
    AndroidDevice device,
    String? selfBase,
    AndroidSourceCatalog catalog,
    bool Function() isCurrent,
    void Function(int recordId, String candidate)? onSaved,
  ) async {
    _stage = BridgeStage.fetchingConfig;
    notifyListeners();
    final conversion = await _bridge.fetchGatewayConfig(
      base,
      selfBase: selfBase,
      onStage: (stage) {
        _stage = stage;
        notifyListeners();
      },
    );
    final candidate = conversion.tmdbApiKeyCandidate;
    _conversions = {
      ..._conversions,
      base: conversion.withoutTmdbApiKeyCandidate(),
    };
    final liveSources = await _bridge.fetchLiveSources(base);
    final bridgedConfig = liveSources.isEmpty
        ? conversion.config
        : conversion.config.copyWith(lives: liveSources);
    // 老安卓拿不到 interfaceKey：记录不带 sourceKey，去重退回按 origin（老语义）。
    if (!isCurrent()) return false;
    final recordId = await host.saveBridgeConfig(
      name: bridgedConfig.name ?? '安卓桥接（${_hostOf(base)}）',
      origin: base,
      config: bridgedConfig,
      diagnostics: [...catalog.diagnostics, ...conversion.diagnostics],
    );
    if (!isCurrent()) return false;
    if (recordId == null) {
      throw AppError(
        AppErrorKind.storage,
        '导入成功但保存配置记录失败（数据库不可用）',
        detail: base,
      );
    }
    onSaved?.call(recordId, candidate);
    _lastImportRecordId = recordId;
    _importRecordIds = List.unmodifiable([recordId]);
    await _rememberDevice(
      uuid: device.uuid,
      name: device.name,
      address: device.reachableBase,
      persist: false,
    );
    await authorizePeer(device);
    if (!isCurrent()) return false;
    _notice =
        '已导入 ${conversion.siteCount} 个站点'
        '${liveSources.isEmpty ? '' : '、${liveSources.length} 个直播源'}'
        '（新配置记录 #$recordId，未切换当前配置）'
        '${conversion.diagnostics.isEmpty ? '' : '；${conversion.diagnostics.first}'}';
    _lastOperation =
        'bridge-import sites=${conversion.siteCount} '
        'lives=${liveSources.length} '
        'skipped=${conversion.skippedSites.length} '
        'rewrites=${conversion.hostRewrites.length}';
    log.info(
      '安卓桥接导入完成（老安卓，仅当前源） sites=${conversion.siteCount} '
      'lives=${liveSources.length} record=$recordId',
      scope: 'bridge',
    );
    return true;
  }

  /// 取 host:port 用于提示文案。
  static String _hostOf(String base) {
    final uri = Uri.tryParse(base);
    if (uri == null || uri.host.isEmpty) return base;
    return uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
  }

  // ------------------------------------------------------------------ 推送

  /// 推送本地历史到指定对端（`design/02` §3.5）。
  Future<SyncPushResult?> pushHistoryTo(SyncPeer peer) =>
      _guardedPush(peer, () {
        final config = host.syncConfigJson();
        if (config == null || config.trim().isEmpty) {
          throw AppError(
            AppErrorKind.syncPayloadInvalid,
            '推送历史前必须选择与安卓当前一致的配置'
            '（config.url 为空时安卓会静默忽略全部记录，却仍返回成功）',
            detail: 'config.url',
          );
        }
        return _client.pushHistory(
          deviceBase: peer.address,
          configJson: config,
          items: host.syncHistoryItems(),
        );
      });

  /// 推送本地收藏到指定对端。
  Future<SyncPushResult?> pushKeepTo(SyncPeer peer) => _guardedPush(
    peer,
    () => _client.pushKeep(
      deviceBase: peer.address,
      items: host.syncFavoriteItems(),
    ),
  );

  /// 推送设置到指定对端（`settings` 未开启时不带凭据项）。
  Future<SyncPushResult?> pushSettingsTo(SyncPeer peer) => _guardedPush(
    peer,
    () async => _client.pushBackup(
      deviceBase: peer.address,
      backup: {
        'prefers':
            await settingsExporter?.call(_settingsSyncEnabled) ??
            const <String, Object?>{},
      },
      options: SyncOptions.pcDefault.copyWith(settings: _settingsSyncEnabled),
    ),
  );

  /// 请求对端主动把数据推给 PC（`mode=2` + `device`，§3.2 便利路径）。
  Future<SyncPushResult?> pullFrom(SyncPeer peer, {String type = 'history'}) =>
      _guardedPush(
        peer,
        () => _client.requestPull(
          deviceBase: peer.address,
          type: type,
          pcDeviceJson: _selfDeviceJson(peer.address),
        ),
      );

  Future<SyncPushResult?> _guardedPush(
    SyncPeer peer,
    Future<SyncPushResult> Function() action,
  ) async {
    if (!_pushEnabled) {
      _lastError = AppError(AppErrorKind.syncDisabled, '向安卓推送未开启，请先在设置中开启');
      notifyListeners();
      return null;
    }
    _busy = true;
    _lastError = null;
    _notice = null;
    notifyListeners();
    try {
      final result = await action();
      _lastStats = result.stats;
      _lastOperation = result.describe();
      _notice = result.stats == null
          ? '已推送到 ${peer.name}（对端未返回明细）'
          : '已推送到 ${peer.name}：${result.stats!.describe()}';
      return result;
    } on AppError catch (error) {
      _lastError = error;
      log.warning('推送失败：${error.logLine}', scope: 'sync');
      return null;
    } catch (error) {
      _lastError = AppError(
        AppErrorKind.syncPeerError,
        '推送失败：$error',
        cause: error,
      );
      return null;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  // ------------------------------------------------------------------ 收尾

  void clearMessages() {
    _lastError = null;
    _notice = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _realtimeEngine?.stop();
    _realtimeEngine = null;
    _readClient.close();
    final server = _server;
    _server = null;
    if (server != null) {
      // 退出时必须释放端口（`design/02` §4.1）。
      unawaited(server.stop());
    }
    _bridge.close();
    _client.close();
    super.dispose();
  }

  // ------------------------------------------------------------- 服务端装配

  SyncServerHost _buildServerHost() => SyncServerHost(
    deviceUuid: _deviceUuid,
    deviceName: _deviceName,
    isEnabled: () => _serverEnabled,
    isPeerAuthorized: isPeerAuthorized,
    onHistory: (parsed, {String sourceKey = ''}) async {
      final stats = _mergeHistory(parsed, sourceKey: sourceKey);
      _recordMerge('history', stats);
      return stats;
    },
    onKeep: (parsed) async {
      final stats = _mergeKeep(parsed);
      _recordMerge('keep', stats);
      return stats;
    },
    onBackup: (backup, allowSensitive) async {
      final settings = SyncSettings.fromBackup(
        backup,
        // 用户没开启设置同步时，即使对端说 `settings=true` 也不接受（P3）。
        allowSensitive: allowSensitive && _settingsSyncEnabled,
      );
      await host.applySyncedSettings(settings);
      log.info('同步设置已落盘 ${settings.describe()}', scope: 'sync');
      return settings;
    },
    onPullRequest: (deviceJson) async {
      // 对端要求 PC 主动推给它（安卓 `mode=0/2` + `device`）。
      // 推送默认关闭：按 P3 不推，并留下可见记录。
      if (!_pushEnabled) {
        _notice = '对端请求回推数据，但"向安卓推送"未开启，已跳过';
        log.warning('对端请求回推但推送未开启，已跳过', scope: 'sync');
        notifyListeners();
        return;
      }
      final peer = _peerFromDeviceJson(deviceJson);
      if (peer == null) {
        log.warning('对端 device JSON 无法解析，跳过回推', scope: 'sync');
        return;
      }
      await _guardedPush(
        peer,
        () => _client.pushHistory(
          deviceBase: peer.address,
          configJson: host.syncConfigJson() ?? '{}',
          items: host.syncHistoryItems(),
        ),
      );
    },
    // 路径 B（`design/01` §3.2.2）：安卓的「远端同步源」来拉增量。
    //
    // 游标由安卓侧保存，PC **不推进任何本地游标**。
    //
    // 门禁：`realtime.pushEnabled`（`design/01` §6.2/D6）。它已经隐含
    // 「允许数据离开 PC」的意图（开启时还会自动拉起服务端），
    // 因此不再叠 Phase 5 的 `pushEnabled`——否则用户明明开了实时推送，
    // 却因为没开手动推送而拿到 403。
    realtimePull: _realtime.pushEnabled
        ? ({required int since, required int limit}) => buildSyncPullBatch(
            history: host.syncHistoryItems(),
            deletions: _realtimeDeletions(),
            since: since,
            limit: limit,
          )
        : null,
    pullToken: _realtimePullToken,
    // 身份解析（`design/01` §3.2.1）。不注入会让安卓把 PC 标记成
    // `unsupported`（跨设备身份匹配永久失效）。
    playbackIdentity: _playbackIdentity,
    playbackCounts: _realtimeCounts,
  );

  /// `sync/status` 的本地计数（`design/01` §3.2.1）。
  ///
  /// 游标取**历史与墓碑的最大值**（与 [buildSyncPullBatch] 的 `nextSince`
  /// 同口径）：它告诉客户端「本机最新变更到哪了」。
  SyncPlaybackCounts _realtimeCounts() {
    final database = host.syncDatabase;
    var nextSince = 0;
    final history = host.syncHistoryItems();
    for (final item in history) {
      if (item.updatedAt > nextSince) nextSince = item.updatedAt;
    }
    var tombstones = 0;
    if (database != null) {
      final index = database.historyDeletionIndex();
      tombstones = index.length;
      for (final deletedAt in index.values) {
        if (deletedAt > nextSince) nextSince = deletedAt;
      }
    }
    return (
      items: history.length,
      tombstones: tombstones,
      nextSince: nextSince,
    );
  }

  /// 删除墓碑 → 安卓形态的 `historyKey`（`design/01` §3.2.2）。
  ///
  /// 墓碑表存的是 `matchKey`（`\x00` 分隔：siteKey/vodId/flag/episodeId），
  /// 而路径 B 要的是安卓形态的 `historyKey`（`@@@` 分隔：siteKey/vodId/cid）。
  /// 两者只有前两段共享，因此必须**重建**而不是直接透传——
  /// 直接透传会让安卓认不出这条删除属于哪条记录。
  List<({String historyKey, int deletedAt})> _realtimeDeletions() {
    final database = host.syncDatabase;
    if (database == null) return const [];
    final result = <({String historyKey, int deletedAt})>[];
    for (final entry in database.historyDeletionIndex().entries) {
      final parts = entry.key.split('\x00');
      if (parts.length < 2) continue;
      result.add((
        historyKey:
            '${parts[0]}$androidHistoryKeySeparator${parts[1]}'
            '${androidHistoryKeySeparator}0',
        deletedAt: entry.value,
      ));
    }
    return result;
  }

  /// 把对端推来的一批历史合并进本地。
  ///
  /// [sourceKey] 非空时**整体限定在该源内**：既只和该源已有记录比对，
  /// 写回也带该源标识。否则一台设备上的多个源会互相覆盖（站点 key 重复）。
  SyncMergeStats _mergeHistory(
    SyncHistoryParseResult parsed, {
    String sourceKey = '',
  }) {
    final database = host.syncDatabase;
    if (database == null) {
      return SyncMergeStats(
        applied: 0,
        skipped: 0,
        failed: parsed.total,
        total: parsed.total,
      );
    }
    final plan = buildHistoryMergePlan(
      parsed: parsed,
      localByMatchKey: database.historySyncIndex(sourceKey: sourceKey),
      deletedAtByMatchKey: database.historyDeletionIndex(sourceKey: sourceKey),
    );
    return database.applyHistoryMerge(plan, sourceKey: sourceKey);
  }

  SyncMergeStats _mergeKeep(SyncFavoriteParseResult parsed) {
    final database = host.syncDatabase;
    if (database == null) {
      return SyncMergeStats(
        applied: 0,
        skipped: 0,
        failed: parsed.total,
        total: parsed.total,
      );
    }
    final plan = buildFavoriteMergePlan(
      parsed: parsed,
      localUpdatedAtByKey: database.favoriteSyncIndex(),
    );
    return database.applyFavoriteMerge(plan);
  }

  void _recordMerge(String type, SyncMergeStats stats) {
    _lastStats = stats;
    _lastOperation = 'sync-receive type=$type ${stats.describe()}';
    _notice = stats.isConsistent
        ? '已接收 $type：${stats.describe()}'
        : '同步明细不闭合（实现缺陷）：${stats.describe()}';
    log.info('同步接收 type=$type ${stats.describe()}', scope: 'sync');
    notifyListeners();
  }

  SyncPeer? _peerFromDeviceJson(String deviceJson) {
    final decoded = _tryDecode(deviceJson);
    final map = asMap(decoded);
    final address = asNonEmptyString(map['ip']);
    if (address == null) return null;
    var base = address;
    try {
      base = normalizeBase(address);
    } on AppError {
      return null;
    }
    return SyncPeer(
      uuid: asNonEmptyString(map['uuid']) ?? base,
      name: asNonEmptyString(map['name']) ?? Uri.parse(base).host,
      address: base,
    );
  }

  /// PC 自己的 `Device` JSON（`mode=0/2` 的 `device` 参数）。
  String _selfDeviceJson(String peerAddress) => jsonEncode({
    'uuid': _deviceUuid,
    'name': _deviceName,
    'ip': serverRunning ? _server!.baseUrl : peerAddress,
    'type': 1,
  });

  // ---------------------------------------------------------------- 持久化

  /// 写入串行化：`_writeSettings` 是「写 .tmp → 删旧 → rename」，两个并发的
  /// 写会互相踩：后一个的 `delete` 会把前一个刚 rename 出来的文件删掉，
  /// 结果**文件直接消失**（不是内容旧）。身份注册表的 `onChanged` 是
  /// fire-and-forget（不能阻塞 HTTP 响应），与开关变更天然会并发。
  ///
  /// **为什么用标志位而不是 `Future` 链**：链式 `then` 会把回调调度到
  /// 「创建该 Future 的 zone」，而 widget 测试的 fake-async zone 与
  /// `tester.runAsync` 的真实 zone 不同——一跳区就永久挂起（本仓库踩过多次）。
  /// 标志位 + 循环保持每次调用在自己的 zone 里 await。
  bool _persisting = false;
  bool _persistPending = false;

  Future<void> _persist() async {
    if (_persisting) {
      // 已有写在跑：置位待重写，让最后的状态是被写完的。
      _persistPending = true;
      return;
    }
    _persisting = true;
    try {
      do {
        _persistPending = false;
        await _writeSettings();
      } while (_persistPending);
    } catch (error) {
      log.warning('保存同步设置失败：$error', scope: 'sync');
    } finally {
      _persisting = false;
    }
  }

  Future<void> _writeSettings() async {
    // 写盘经共享工具（`settings_file.dart`）：
    // - **同步临界区**：`UiPreferencesStore` 同时也在写同一个 `settings.json`。
    //   Dart 单线程，所以「读→改→写 tmp→rename」之间只要没有 `await`
    //   就不可能交错——同时堵住「文件丢失」与更隐蔽的「丢更新」
    //   （对方刚写的段被自己的陈旧读覆盖回去）。
    // - **独占临时名**：两者原先共用 `$settingsPath.tmp`，会互相覆盖。
    // - **只改 `sync` 段**：读回时保留 `ui` 段。
    final result = writeSettingsSectionSync(
      path: settingsPath,
      writer: SettingsWriter.sync,
      mutate: (root) {
        root['sync'] = {
          'version': 1,
          'deviceUuid': _deviceUuid,
          'deviceName': _deviceName,
          'serverEnabled': _serverEnabled,
          'pushEnabled': _pushEnabled,
          'settingsSyncEnabled': _settingsSyncEnabled,
          'peers': _peers.map((peer) => peer.toJson()).toList(),
          'devices': _deviceHistory.map((item) => item.toJson()).toList(),
          'lastBridge': _lastBridgeAddress,
          // 身份注册表（`design/01` §3.2.1）：`adopt` 的结论必须跨重启可用。
          'identity': _playbackIdentity.toJson(),
          // 实时同步开关与游标（`design/01` §9.1）。
          'realtime': {
            ..._realtime.toJson(),
            'pullCursorMs': _realtimePullCursorMs,
            'pullToken': _realtimePullToken,
            'lastPullAt': _realtimeEngine?.snapshot().lastPollAtMs ?? 0,
            'lastHeartbeatAt':
                _realtimeEngine?.snapshot().lastHeartbeatAtMs ?? 0,
          },
        };
        return true;
      },
    );
    if (!result.ok) {
      log.warning('保存同步设置失败：${result.error}', scope: 'sync');
    }
  }

  /// 稳定 uuid：16 字节十六进制（重启后不变，`design/02` §8 Q5）。
  String _generateUuid() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }

  String _defaultDeviceName() {
    final hostName = Platform.localHostname;
    return hostName.isEmpty ? 'WebHTV PC' : 'WebHTV PC（$hostName）';
  }

  Object? _tryDecode(String text) {
    try {
      return jsonDecode(text);
    } on FormatException {
      return null;
    }
  }
}
