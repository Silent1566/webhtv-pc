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
import '../core/android_sync.dart';
import '../core/app_error.dart';
import '../core/protocol.dart';
import '../services/android_bridge_service.dart';
import '../services/log_service.dart';
import '../services/storage.dart';
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
  });

  /// 与安卓当前配置对齐的配置 JSON（含非空 `url`）；无法确定时为 `null`。
  ///
  /// 见 `design/02` §3.2：`config.url` 为空时安卓**静默忽略**整批记录却仍返回
  /// 200，因此宁可不发也不能发一个空 url。
  String? syncConfigJson();

  /// 把白名单内的设置落到本地设置文件（调用方已确认 `settings` 开启）。
  Future<void> applySyncedSettings(SyncSettings settings);
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

  DeviceHistoryEntry copyWith({String? name, String? address, int? lastUsedMs}) =>
      DeviceHistoryEntry(
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
    AndroidBridgeService? bridgeService,
    SyncClient? client,
    SyncServer Function(SyncServerHost host)? serverFactory,
    Random? random,
  }) : _bridge = bridgeService ?? AndroidBridgeService(log: log),
       _client = client ?? SyncClient(log: log),
       _serverFactory = serverFactory ?? _defaultServerFactory(log),
       _random = random ?? Random.secure();

  final LogService log;
  final SyncStateHost host;

  /// `<configDir>/settings.json`（`sync` 段所在文件，与 TMDB 同一份）。
  final String settingsPath;
  final AndroidBridgeService _bridge;
  final SyncClient _client;
  final SyncServer Function(SyncServerHost host) _serverFactory;
  final Random _random;

  /// 服务端默认端口区间（与安卓同策略，`design/02` §4.1）。
  static const int defaultPortStart = androidDefaultPort;
  static const int defaultPortEnd = androidPortRangeEnd;

  static SyncServer Function(SyncServerHost host) _defaultServerFactory(
    LogService log,
  ) => (host) => SyncServer(log: log, host: host);

  // ------------------------------------------------------------ 持久化状态

  bool _loaded = false;
  bool _serverEnabled = false;
  bool _pushEnabled = false;
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

  // ------------------------------------------------------------ 运行期状态

  SyncServer? _server;
  bool _busy = false;
  AppError? _lastError;
  String? _notice;
  SyncMergeStats? _lastStats;
  String? _lastOperation;
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
  String? get serverBaseUrl =>
      serverRunning ? _server!.baseUrl : null;

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

  bool get busy => _busy;
  BridgeStage? get stage => _stage;
  int get scanDone => _scanDone;
  int get scanTotal => _scanTotal;

  /// 某设备最近一次拉到的桥接转换结果（含诊断）。
  BridgeConversion? conversionFor(String deviceBase) =>
      _conversions[normalizeBase(deviceBase)];

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
      _deviceHistory = asList(section['devices'])
          .map(DeviceHistoryEntry.fromJson)
          .whereType<DeviceHistoryEntry>()
          .toList()
        ..sort((a, b) => b.lastUsedMs.compareTo(a.lastUsedMs));
      _lastBridgeAddress = asNonEmptyString(section['lastBridge']) ?? '';
      _loaded = true;
      if (section.isEmpty) {
        // 首次运行：把生成的 uuid 落盘，保证重启后安卓仍认同一台设备。
        await _persist();
      }
      log.info(
        '同步设置已读取：server=${_serverEnabled ? 'on' : 'off'} '
        'push=${_pushEnabled ? 'on' : 'off'} '
        'settings=${_settingsSyncEnabled ? 'on' : 'off'} '
        'peers=${_peers.length} devices=${_deviceHistory.length} '
        'lastBridge=${redactUrl(_lastBridgeAddress)}',
        scope: 'sync',
      );
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
      _notice = '同步服务已启动：${server.baseUrl}'
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
    _notice = value
        ? '将同步包含凭据的设置项（TMDB 等），请确认对端可信'
        : '已停止同步设置项';
    log.warning(
      '含凭据的设置同步：${value ? '已开启（用户显式确认）' : '已关闭'}',
      scope: 'sync',
    );
    await _persist();
    notifyListeners();
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
    log.info('移除同步对端 ${SyncPeer(uuid: uuid, name: '', address: '').maskedUuid}',
        scope: 'sync');
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
    if (persist) await _persist();
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
    log.info(
      '尝试自动接入最近使用的桥接线路 address=${redactUrl(target)}',
      scope: 'bridge',
    );
    // 自动接入**不弹错误**：探不通只是「上次那台设备不在」，不应该在启动时
    // 给用户一个红色错误横幅。因此这里不走 probe（它会写 _lastError）。
    _busy = true;
    _stage = BridgeStage.probingDevice;
    notifyListeners();
    try {
      final device = await _bridge.probeDevice(target);
      if (!_devices.any((item) => item.uuid == device.uuid)) {
        _devices = [..._devices, device];
      }
      await _rememberDevice(
        uuid: device.uuid,
        name: device.name,
        address: device.reachableBase,
      );
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

  /// 拉取并导入站点（`design/01` §5）。
  ///
  /// 导入产生**新配置记录**且**不覆盖当前配置**（Q10）。
  Future<bool> importSites(String address) async {
    _busy = true;
    _stage = BridgeStage.fetchingConfig;
    _lastError = null;
    _notice = null;
    notifyListeners();
    try {
      final base = normalizeBase(address);
      final device = _devices.firstWhere(
        (item) => item.reachableBase == base,
        orElse: () => AndroidDevice(
          uuid: base,
          name: Uri.parse(base).host,
          reachableBase: base,
        ),
      );
      final conversion = await _bridge.fetchGatewayConfig(
        base,
        // P4：把 PC 自己的服务端地址也交给转换层，拒绝指向本机的站点。
        selfBase: serverRunning ? _server!.baseUrl : null,
        onStage: (stage) {
          _stage = stage;
          notifyListeners();
        },
      );
      _conversions = {..._conversions, base: conversion};

      // 直播源：T4 网关的 `lives` 恒为空（`VodApi.java` 写死 `new JsonArray()`），
      // 必须另从设备当前启用的直播配置里取（用户反馈 2026-10-09：
      // 「安卓桥接没有同步直播源」）。取不到不报错——站点导入本身已成功。
      final liveSources = await _bridge.fetchLiveSources(base);
      final bridgedConfig = liveSources.isEmpty
          ? conversion.config
          : conversion.config.copyWith(lives: liveSources);

      final recordId = await host.saveBridgeConfig(
        name: bridgedConfig.name ?? '安卓桥接（${Uri.parse(base).host}）',
        origin: base,
        config: bridgedConfig,
        diagnostics: conversion.diagnostics,
      );
      if (recordId == null) {
        throw AppError(
          AppErrorKind.storage,
          '导入成功但保存配置记录失败（数据库不可用）',
          detail: base,
        );
      }

      // 先改内存里的设备历史与白名单，**最后只落一次盘**：
      // `_persist` 是「写 .tmp → 删旧 → rename」，同一流程里连写两次会放大文件锁
      // 窗口（测试环境下会让 `settleIo` 的固定帧数不够用）。
      // 因此 `_rememberDevice` 不落盘，由随后的 `authorizePeer` 一并写入。
      await _rememberDevice(
        uuid: device.uuid,
        name: device.name,
        address: device.reachableBase,
        persist: false,
      );
      // 顺带把设备加入白名单：用户刚刚显式接入它（并在这里落盘）。
      await authorizePeer(device);

      _notice = '已导入 ${conversion.siteCount} 个站点'
          '${liveSources.isEmpty ? '' : '、${liveSources.length} 个直播源'}'
          '（新配置记录 #$recordId，未切换当前配置）'
          '${conversion.diagnostics.isEmpty ? '' : '；${conversion.diagnostics.first}'}';
      _lastOperation =
          'bridge-import sites=${conversion.siteCount} '
          'lives=${liveSources.length} '
          'skipped=${conversion.skippedSites.length} '
          'rewrites=${conversion.hostRewrites.length}';
      log.info(
        '安卓桥接导入完成 sites=${conversion.siteCount} '
        'lives=${liveSources.length} '
        'skipped=${conversion.skippedSites.length} '
        'rewrites=${conversion.hostRewrites.length} record=$recordId',
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

  // ------------------------------------------------------------------ 推送

  /// 推送本地历史到指定对端（`design/02` §3.5）。
  Future<SyncPushResult?> pushHistoryTo(SyncPeer peer) => _guardedPush(
    peer,
    () {
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
    },
  );

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
    () => _client.pushBackup(
      deviceBase: peer.address,
      backup: const {'prefers': <String, Object?>{}},
      options: SyncOptions.pcDefault.copyWith(
        settings: _settingsSyncEnabled,
      ),
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
      _lastError = AppError(
        AppErrorKind.syncDisabled,
        '向安卓推送未开启，请先在设置中开启',
      );
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
    onHistory: (parsed) async {
      final stats = _mergeHistory(parsed);
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
  );

  SyncMergeStats _mergeHistory(SyncHistoryParseResult parsed) {
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
      localByMatchKey: database.historySyncIndex(),
      deletedAtByMatchKey: database.historyDeletionIndex(),
    );
    return database.applyHistoryMerge(plan);
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

  Future<void> _persist() async {
    try {
      final file = File(settingsPath);
      await file.parent.create(recursive: true);
      final root = <String, Object?>{};
      if (await file.exists()) {
        try {
          final decoded = jsonDecode(await file.readAsString());
          if (decoded is Map) {
            root.addAll(decoded.map((key, value) => MapEntry('$key', value)));
          }
        } catch (_) {
          // 旧文件损坏 → 直接覆盖，不把损坏内容带进新文件。
        }
      }
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
      };
      final temporary = File('$settingsPath.tmp');
      await temporary.writeAsString(
        const JsonEncoder.withIndent('  ').convert(root),
        flush: true,
      );
      if (await file.exists()) await file.delete();
      await temporary.rename(settingsPath);
    } catch (error) {
      log.warning('保存同步设置失败：$error', scope: 'sync');
    }
  }

  /// 稳定 uuid：16 字节十六进制（重启后不变，`design/02` §8 Q5）。
  String _generateUuid() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    return bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
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
