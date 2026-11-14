/// 实时同步引擎（`docs/phase7/design/01` §4、§6.3；`design/02` §3–§5）。
///
/// 职责：**只做编排**——定时器、心跳→轮询联动、退避、游标推进裁决。
/// 所有 I/O 经 [RealtimeEngineHost] 注入，所有时间经 [RealtimeScheduler] 注入：
///
/// - 纯逻辑（退避序列、游标裁决、三态分类、唤醒阶梯）在
///   `lib/core/realtime_sync.dart`，本文件**不重复实现**它们；
/// - 网络在 `lib/services/android_read_client.dart`（路径 A 读取）与
///   `lib/services/sync_client.dart`（推送）；
/// - 落库经 `mergeHistory` 回调（状态层持有 `AppState`）。
///
/// ## 为什么时间与 I/O 都要注入
///
/// 本仓库有两条踩过的坑：`testWidgets` 的 fake-async zone 与
/// `tester.runAsync` 的真实 zone 不同，跨 zone 的 `Future` 链会永久挂起；
/// 真实定时器又让「退避到第几次」「恢复后立刻补一轮」无法确定性断言。
/// 把调度器做成可注入的一次性定时器工厂，测试既能手动推进时间，
/// 又**不会**创建任何真实 `Timer`——`design/04` G12「用例结束时活动定时器
/// 数 = 0」由此可以逐用例断言（[activeTimerCount]）。
///
/// ## 三条不变式（违反任一条都会静默出错）
///
/// 1. **失败不推进游标**（`design/04` §5 反向验证 #6）：游标只在整批
///    `success` 后推进，裁决交给 `decideCursor`；
/// 2. **403 立即停止该方向**：重试只会一直 403，留着定时器等于持续骚扰；
/// 3. **心跳失败暂停轮询，恢复后立刻补一轮**（`design/02` §3.3、§5.2）：
///    断线期间的记录仍在安卓侧，补一轮就能拿到最新状态。
library;

import 'dart:async';

import '../core/android_sync.dart';
import '../core/app_error.dart';
import '../core/realtime_sync.dart';
import 'log_service.dart';

// ---------------------------------------------------------------------------
// 调度器（时间注入）
// ---------------------------------------------------------------------------

/// 一次性定时器句柄。
abstract class RealtimeTimerHandle {
  /// 取消。已触发或已取消后再调必须无害。
  void cancel();

  /// 是否仍在等待触发。
  bool get isActive;
}

/// 定时器工厂（测试注入手动实现，见 `phase7_realtime_engine_test.dart`）。
///
/// **只提供一次性定时器**，不提供周期性定时器：周期语义由引擎在每次
/// 触发后重新排程表达，退避（1×/2×/4×/8×）因此只是一个不同的延迟参数，
/// 不需要「改周期」这种带状态的 API。
typedef RealtimeScheduler = RealtimeTimerHandle Function(
  Duration delay,
  void Function() onFire,
);

/// 真实调度器（`Timer`）。
RealtimeScheduler realtimeRealScheduler() =>
    (delay, onFire) => _DartTimerHandle(Timer(delay, onFire));

class _DartTimerHandle implements RealtimeTimerHandle {
  _DartTimerHandle(this._timer);

  final Timer _timer;

  @override
  void cancel() {
    if (_timer.isActive) _timer.cancel();
  }

  @override
  bool get isActive => _timer.isActive;
}

// ---------------------------------------------------------------------------
// I/O 端口
// ---------------------------------------------------------------------------

/// 一次心跳探测的结果（由 I/O 层填，引擎只消费）。
class RealtimeHeartbeatProbe {
  const RealtimeHeartbeatProbe({
    required this.state,
    this.statusCode,
    this.session = const {},
    this.usedDeviceFallback = false,
    this.detail,
  });

  /// 三态判定（`design/02` §4）。
  final RealtimePeerState state;

  final int? statusCode;

  /// `/manage/session` 的 JSON（降级到 `/device` 时为空）。
  final Map<String, Object?> session;

  /// 是否走了 `/device` 降级（老版本安卓无 `/manage`）。
  final bool usedDeviceFallback;

  final String? detail;

  /// 管理页进程是否在跑（`/manage/session` 的 `running`）。
  ///
  /// 未知（降级到 `/device`）时为 `null`——**不得**默认成 `true`，
  /// 否则「管理页未运行，息屏后可能失联」这条提示永远不出现。
  bool? get running => _flag('running');

  /// 局域网 `Server` 是否在跑。
  bool? get serverRunning => _flag('serverRunning');

  bool? get batteryOptimized => _flag('batteryOptimized');

  bool? get backgroundSettingsNeeded => _flag('backgroundSettingsNeeded');

  bool? get wakeLock => _flag('wakeLock');

  bool? get wifiLock => _flag('wifiLock');

  /// 安卓侧品牌自适应的后台设置指引（`design/02` §5.3：必须原样显示）。
  String? get backgroundGuide {
    final value = session['backgroundGuide'];
    return value is String && value.trim().isNotEmpty ? value : null;
  }

  int? get idleTimeout {
    final value = session['idleTimeout'];
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  bool? _flag(String key) {
    final value = session[key];
    if (value is bool) return value;
    if (value is String) {
      final text = value.trim().toLowerCase();
      if (text == 'true') return true;
      if (text == 'false') return false;
    }
    return null;
  }

  String describe() =>
      'heartbeat(state=${state.name} status=${statusCode ?? '-'} '
      'fallback=$usedDeviceFallback running=$running '
      'serverRunning=$serverRunning batteryOptimized=$batteryOptimized)';
}

/// 一轮轮询的站点级读取结果（引擎只要这几个数，不需要完整原始响应）。
class RealtimeSiteReadResult {
  const RealtimeSiteReadResult({
    required this.items,
    this.unmergeable = 0,
    this.skippedAsUnchanged = 0,
    this.endpoint = RealtimePullCapability.history,
    this.notFound = false,
  });

  /// 解析成功的条目。
  final List<SyncHistoryItem> items;

  /// **永久性**失败条数：记录本身不可合并（集名与地址双空、身份键不成段）。
  ///
  /// **为什么必须与「暂时性失败」分开**（L3 实测出来的真实缺陷）：
  /// 这类记录下轮、下下轮、永远都是同样的结果——重试无意义。
  /// 若把它当作「整轮部分失败」，引擎会**每轮**都归为 `partial`，
  /// 而 `partial` 按 `design/01` §6.3 不推进游标 → **游标永久卡死**，
  /// 增量语义彻底失效（每轮都在重拉同一批）。
  ///
  /// 它仍然要计入 `failed` 明细并披露（P5：不得静默丢弃），
  /// 只是不阻止游标推进。
  final int unmergeable;

  /// 时间戳不可靠时按「内容等价」跳过的条数。
  final int skippedAsUnchanged;

  /// 实际使用的端点（用于降级披露）。
  final RealtimePullCapability endpoint;

  /// 该站点当前无记录（`/current` 的 404）——**不是失败**。
  final bool notFound;
}

/// 引擎的 I/O 端口。
///
/// 用函数字段而不是抽象类：与 `SyncServerHost` 同一风格，测试直接构造
/// 一个记录调用的实例即可，不需要 `implements` 一整个接口。
class RealtimeEngineHost {
  const RealtimeEngineHost({
    required this.deviceBase,
    required this.siteKeys,
    required this.probeCapability,
    required this.readSite,
    required this.resolveSourceKey,
    required this.mergeHistory,
    required this.heartbeat,
    required this.localHistoryByMatchKey,
  });

  /// 安卓可达基址。为空 = 未接入设备 → 不排任何定时器。
  final String? Function() deviceBase;

  /// 本轮要轮询的 siteKey（默认最近活跃的 N 个；`pollAllSites` 时为全部）。
  final List<String> Function({required bool all}) siteKeys;

  /// 探测路径 A 的能力（实现方负责缓存 60 s，见 `RealtimeCapabilityCache`）。
  final Future<RealtimePullCapability> Function(String deviceBase)
  probeCapability;

  /// 读一个站点的历史。
  final Future<RealtimeSiteReadResult> Function({
    required String deviceBase,
    required String siteKey,
    required RealtimePullCapability capability,
    required Map<String, SyncHistoryItem> localByMatchKey,
  })
  readSite;

  /// 该设备本轮拉取的源归属；判不出来必须是空串（实现方不得猜）。
  ///
  /// 是**设备级**而不是「设备 + 站点」：安卓的 `/api/playback/history` 只按
  /// `VodConfig.getCid()`（设备的当前激活配置）查库，siteKey 只是站点过滤，
  /// 不参与选源——一轮里所有站点的记录都来自同一个源。
  ///
  /// 异步：归属要看 `/manage/configs` 的 `active`，那是一次设备请求。
  final Future<String> Function({required String deviceBase}) resolveSourceKey;

  /// 合并一批条目并落库，返回统计。
  ///
  /// [sourceKey] 是本次拉取批次的源归属，为空表示无法判定（不猜）。
  final Future<SyncMergeStats> Function(
    List<SyncHistoryItem> items, {
    required String sourceKey,
  })
  mergeHistory;

  /// 心跳探测（`/manage/session` → `/device` 降级链由实现方负责）。
  final Future<RealtimeHeartbeatProbe> Function(String deviceBase) heartbeat;

  /// 本地已有记录（按 `matchKey` 索引）：时间戳不可靠时的幂等兜底需要它。
  final Map<String, SyncHistoryItem> Function() localHistoryByMatchKey;
}

// ---------------------------------------------------------------------------
// 快照与结果
// ---------------------------------------------------------------------------

/// 一轮轮询的结论（供 UI 与证据落盘）。
class RealtimePollResult {
  const RealtimePollResult({
    required this.stats,
    required this.siteCount,
    required this.outcome,
    required this.cursor,
    required this.cursorAdvanced,
    required this.stopped,
    this.unmergeable = 0,
    this.error,
    this.degradedSites = const [],
  });

  /// 本轮的合并统计（所有站点合计）。
  final SyncMergeStats stats;

  /// 本轮请求的站点数（`design/01` §7.2 要披露「本周期将请求 N 个站点」）。
  final int siteCount;

  /// 结果分类（决定游标是否推进）。
  final RealtimeBatchOutcome outcome;

  /// 本轮结束后的游标。
  final int cursor;

  /// 游标是否推进。
  final bool cursorAdvanced;

  /// 是否因 403 等不可恢复原因停止了该方向。
  final bool stopped;

  final AppError? error;

  /// 本轮因「记录本身不可合并」被永久跳过的条数（集名与地址双空、身份键不成段）。
  ///
  /// 它已计入 [stats] 的 `failed`（P5：不得静默丢弃），但**不**阻止游标推进
  /// ——这类记录下轮重试也是同样结果，若因此卡住游标，增量语义就失效了。
  /// UI 应把它作为「N 条记录无法同步」披露，而不是当成需要重试的失败。
  final int unmergeable;

  /// 走了 `/current` 降级端点的站点（UI 必须常驻披露）。
  final List<String> degradedSites;

  String describe() =>
      'poll(sites=$siteCount outcome=${outcome.name} ${stats.describe()} '
      'cursor=$cursor advanced=$cursorAdvanced stopped=$stopped '
      'unmergeable=$unmergeable degraded=${degradedSites.length})';
}

/// 一次心跳的结论。
class RealtimeHeartbeatOutcome {
  const RealtimeHeartbeatOutcome({
    required this.probe,
    required this.consecutiveFailures,
    required this.wakeLevel,
    required this.pollPaused,
    required this.stopped,
    required this.triggeredPoll,
    this.error,
  });

  final RealtimeHeartbeatProbe probe;
  final int consecutiveFailures;
  final RealtimeWakeLevel wakeLevel;

  /// 是否因此暂停了轮询。
  final bool pollPaused;

  /// 是否停止该方向（403 / 连续失败到上限）。
  final bool stopped;

  /// 是否因「恢复」而立刻补跑了一轮轮询（`design/02` §5.2）。
  final bool triggeredPoll;

  final AppError? error;

  String describe() =>
      'heartbeat(state=${probe.state.name} failures=$consecutiveFailures '
      'wake=${wakeLevel.name} paused=$pollPaused stopped=$stopped '
      'rePolled=$triggeredPoll)';
}

/// 引擎对外可读的状态快照（T7/T8 的 UI 直接读它）。
class RealtimeEngineSnapshot {
  const RealtimeEngineSnapshot({
    required this.running,
    required this.pollScheduled,
    required this.heartbeatScheduled,
    required this.pollPaused,
    required this.pollStopped,
    required this.heartbeatStopped,
    required this.pollFailures,
    required this.heartbeatFailures,
    required this.peerState,
    required this.cursor,
    required this.wakeLevel,
    required this.activeTimers,
    this.lastPoll,
    this.lastHeartbeat,
    this.lastPollAtMs,
    this.lastHeartbeatAtMs,
    this.lastError,
    this.backgroundGuide,
    this.pullCapability,
    this.degradedSites = const [],
  });

  final bool running;
  final bool pollScheduled;
  final bool heartbeatScheduled;

  /// 轮询被心跳失败暂停（不是用户关闭）。
  final bool pollPaused;

  /// 该方向已停止（403 / 连续失败上限），需要用户手动重试。
  final bool pollStopped;
  final bool heartbeatStopped;

  final int pollFailures;
  final int heartbeatFailures;
  final RealtimePeerState peerState;
  final int cursor;
  final RealtimeWakeLevel wakeLevel;

  /// 当前活动定时器数（`design/04` G12：正常停止后必须为 0）。
  final int activeTimers;

  final RealtimePollResult? lastPoll;
  final RealtimeHeartbeatOutcome? lastHeartbeat;
  final int? lastPollAtMs;
  final int? lastHeartbeatAtMs;
  final AppError? lastError;
  final String? backgroundGuide;

  /// 路径 A 的读取能力（`history` / `currentOnly` / `unsupported`）。
  final RealtimePullCapability? pullCapability;

  /// 走降级端点的站点（P5 披露用）。
  final List<String> degradedSites;

  bool get needsUserAttention => pollStopped || heartbeatStopped;
}

// ---------------------------------------------------------------------------
// 引擎
// ---------------------------------------------------------------------------

/// 实时同步引擎。
class RealtimeSyncEngine {
  RealtimeSyncEngine({
    required this.log,
    required this.host,
    RealtimeScheduler? scheduler,
    DateTime Function()? clock,
    RealtimeSyncSwitches switches = const RealtimeSyncSwitches(),
    int pullCursorMs = 0,
  }) : _scheduler = scheduler ?? realtimeRealScheduler(),
       _clock = clock ?? DateTime.now,
       _switches = switches.normalized(),
       _cursor = pullCursorMs;

  final LogService log;
  final RealtimeEngineHost host;
  final RealtimeScheduler _scheduler;
  final DateTime Function() _clock;

  RealtimeSyncSwitches _switches;
  int _cursor;

  RealtimeTimerHandle? _pollTimer;
  RealtimeTimerHandle? _heartbeatTimer;

  bool _running = false;
  bool _pollPaused = false;
  bool _pollStopped = false;
  bool _heartbeatStopped = false;

  int _pollFailures = 0;
  int _heartbeatFailures = 0;

  RealtimePeerState _peerState = RealtimePeerState.ok;
  RealtimePullCapability? _pullCapability;
  List<String> _degradedSites = const [];

  int? _lastPollAtMs;
  int? _lastHeartbeatAtMs;
  AppError? _lastError;
  String? _backgroundGuide;
  RealtimeWakeLevel _wakeLevel = RealtimeWakeLevel.none;

  RealtimePollResult? _lastPoll;
  RealtimeHeartbeatOutcome? _lastHeartbeat;

  /// 是否已启动。
  bool get isRunning => _running;

  /// 当前活动定时器数（G12 判据）。
  int get activeTimerCount =>
      ((_pollTimer?.isActive ?? false) ? 1 : 0) +
      ((_heartbeatTimer?.isActive ?? false) ? 1 : 0);

  int get cursor => _cursor;

  RealtimeSyncSwitches get switches => _switches;

  RealtimeEngineSnapshot snapshot() => RealtimeEngineSnapshot(
    running: _running,
    pollScheduled: _pollTimer?.isActive ?? false,
    heartbeatScheduled: _heartbeatTimer?.isActive ?? false,
    pollPaused: _pollPaused,
    pollStopped: _pollStopped,
    heartbeatStopped: _heartbeatStopped,
    pollFailures: _pollFailures,
    heartbeatFailures: _heartbeatFailures,
    peerState: _peerState,
    cursor: _cursor,
    wakeLevel: _wakeLevel,
    activeTimers: activeTimerCount,
    lastPoll: _lastPoll,
    lastHeartbeat: _lastHeartbeat,
    lastPollAtMs: _lastPollAtMs,
    lastHeartbeatAtMs: _lastHeartbeatAtMs,
    lastError: _lastError,
    backgroundGuide: _backgroundGuide,
    pullCapability: _pullCapability,
    degradedSites: _degradedSites,
  );

  // -------------------------------------------------------------- 生命周期

  /// 启动（幂等）。未接入设备时不排任何定时器——空跑只会刷日志。
  void start() {
    if (_running) return;
    _running = true;
    // 用户显式启动 = 一次重新尝试：清掉之前的「已停止」标记。
    _pollStopped = false;
    _heartbeatStopped = false;
    _pollPaused = false;
    _schedulePoll();
    _scheduleHeartbeat();
    log.info(
      '实时引擎启动 $_switches device=${_deviceBase ?? '(未接入)'}',
      scope: 'realtime',
    );
  }

  /// 停止并释放全部定时器（幂等）。端口/定时器泄漏在 G12 里一律算失败。
  void stop() {
    _running = false;
    _cancelPoll();
    _cancelHeartbeat();
    log.info('实时引擎已停止（活动定时器=$activeTimerCount）', scope: 'realtime');
  }

  /// 更新开关。子开关值变化只影响对应方向的定时器，不重建整个引擎。
  ///
  /// 总开关关闭时**不重置**子开关值与游标（`design/01` §6.2 规则 3：
  /// 下次开启沿用用户上次的选择）。
  void applySwitches(RealtimeSyncSwitches next) {
    final normalized = next.normalized();
    final previous = _switches;
    _switches = normalized;
    if (!_running) return;

    if (!normalized.shouldPoll) {
      _cancelPoll();
    } else if (!previous.shouldPoll || previous.intervalSeconds != normalized.intervalSeconds) {
      // 刚开启或周期变了：立刻具备可运行条件，但要等下一次心跳确认可达性
      // 才能在暂停态下运行（`_schedulePoll` 内部处理）。
      _schedulePoll();
    }

    if (!normalized.shouldHeartbeat) {
      _cancelHeartbeat();
    } else if (!previous.shouldHeartbeat ||
        previous.heartbeatSeconds != normalized.heartbeatSeconds) {
      _scheduleHeartbeat();
    }
    log.info('实时引擎开关更新 $normalized', scope: 'realtime');
  }

  /// 用户手动「立即重连」：清失败计数与停止标记，立刻跑一次心跳+轮询。
  ///
  /// 只在用户点击时调用——自动路径不得绕过退避（`design/02` §5.1）。
  Future<void> retryNow() async {
    _pollStopped = false;
    _heartbeatStopped = false;
    _pollPaused = false;
    _pollFailures = 0;
    _heartbeatFailures = 0;
    _lastError = null;
    _wakeLevel = RealtimeWakeLevel.none;
    if (!_running) return;
    await heartbeatNow();
    if (_pollPaused || !_switches.shouldPoll) return;
    await pollNow();
    _schedulePoll();
    _scheduleHeartbeat();
  }

  /// 重置拉取游标并立刻跑一轮（`design/01` §4.4 的 `resetCursorAndPull`）。
  Future<RealtimePollResult?> resetCursorAndPoll() async {
    _cursor = 0;
    _pollPaused = false;
    _pollStopped = false;
    final result = await pollNow();
    if (_running) _schedulePoll();
    return result;
  }

  // ---------------------------------------------------------------- 定时器

  String? get _deviceBase {
    final base = (host.deviceBase() ?? '').trim();
    return base.isEmpty ? null : base;
  }

  void _cancelPoll() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  void _cancelHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  /// 排下一轮轮询。
  ///
  /// 暂停（`_pollPaused`）与停止（`_pollStopped`）时**不排**：暂停是心跳
  /// 失败后的主动退避，排了也只会立刻再失败一次。
  void _schedulePoll({int? consecutiveFailures}) {
    _cancelPoll();
    if (!_running || !_switches.shouldPoll) return;
    if (_pollPaused || _pollStopped) return;
    if (_deviceBase == null) return;
    final failures = consecutiveFailures ?? _pollFailures;
    final delay = Duration(
      seconds: realtimeNextDelaySeconds(
        baseSeconds: _switches.intervalSeconds,
        consecutiveFailures: failures,
      ),
    );
    _pollTimer = _scheduler(delay, () {
      _pollTimer = null;
      unawaited(_pollTick());
    });
  }

  void _scheduleHeartbeat({int? consecutiveFailures}) {
    _cancelHeartbeat();
    if (!_running || !_switches.shouldHeartbeat) return;
    if (_heartbeatStopped) return;
    if (_deviceBase == null) return;
    final failures = consecutiveFailures ?? _heartbeatFailures;
    final delay = Duration(
      seconds: realtimeNextDelaySeconds(
        baseSeconds: _switches.heartbeatSeconds,
        consecutiveFailures: failures,
      ),
    );
    _heartbeatTimer = _scheduler(delay, () {
      _heartbeatTimer = null;
      unawaited(_heartbeatTick());
    });
  }

  Future<void> _pollTick() async {
    // 定时器已取消后仍可能被手动触发（测试的残留回调）：不产生请求。
    if (!_running) return;
    await pollNow();
    _schedulePoll();
  }

  Future<void> _heartbeatTick() async {
    if (!_running) return;
    await heartbeatNow();
    _scheduleHeartbeat();
  }

  // ------------------------------------------------------------------ 轮询

  /// 立刻跑一轮轮询（手动操作与定时器共用）。
  ///
  /// 返回 `null` 表示条件不具备（未接入设备 / 方向已停止或暂停 / 未开启拉取）。
  ///
  /// **暂停态同样拒绝**：`design/02` §3.3 的暂停就是「不值得再发请求」，
  /// 绕过它（例如残留的定时器回调）只会把退避等成空转。
  /// [manual] 为 true 时跳过开关/暂停/停止判定——手动「拉取最近记录」
  /// 是用户在实时同步关着（或方向已被 403 停止）时唯一能读安卓历史的
  /// 通道（`design/01` §4.4：必须给用户留逃生口）。
  Future<RealtimePollResult?> pollNow({bool manual = false}) async {
    if (!manual && (!_switches.shouldPoll || _pollStopped || _pollPaused)) {
      return null;
    }
    final base = _deviceBase;
    if (base == null) return null;

    final keys = host.siteKeys(all: _switches.pollAllSites);
    if (keys.isEmpty) {
      // 没有站点可轮询：不是失败，但要留痕——否则用户看到「同步成功」
      // 而实际一条都没查（P5）。
      log.info('本轮无可轮询站点（尚未配置接口或历史为空）', scope: 'realtime');
      return null;
    }

    var applied = 0;
    var skipped = 0;
    var failed = 0;
    var total = 0;
    var unmergeable = 0;
    var maxCursor = _cursor;
    var unauthorized = false;
    var networkFailure = false;
    var partial = false;
    AppError? error;
    final degraded = <String>[];

    // 第一轮先探测能力（实现方缓存 60 s），避免每个站点都探一次。
    try {
      _pullCapability = await host.probeCapability(base);
    } on Object catch (cause) {
      _pullCapability = null;
      networkFailure = true;
      error = cause is AppError
          ? cause
          : AppError(
              AppErrorKind.realtimePullUnsupported,
              '读取能力探测失败',
              detail: '$cause',
            );
    }

    final capability = _pullCapability;
    if (capability == RealtimePullCapability.unsupported) {
      // 端点不可用：不是「0 条」，必须报错误类别（P5）。
      final unsupported = AppError(
        AppErrorKind.realtimePullUnsupported,
        '安卓端不支持历史读取接口（请升级安卓端）',
        detail: base,
        retryable: false,
      );
      log.warning('路径 A 不可用：${unsupported.logLine}', scope: 'realtime');
      _recordPollFailure(
        RealtimeBatchOutcome.failure,
        unsupported,
        countsTowardBackoff: true,
        siteCount: keys.length,
      );
      _lastPoll = RealtimePollResult(
        stats: const SyncMergeStats.empty(),
        siteCount: keys.length,
        outcome: RealtimeBatchOutcome.failure,
        cursor: _cursor,
        cursorAdvanced: false,
        stopped: false,
        error: unsupported,
      );
      return _lastPoll;
    }

    final localIndex = host.localHistoryByMatchKey();

    // 源归属是**设备级**的（安卓按当前激活配置的 cid 查库），整轮只解析一次：
    // 每个站点都去问一次既浪费一次设备请求，又可能在同一轮里得到两种答案。
    String? batchSourceKey;

    for (final siteKey in keys) {
      if (unauthorized) break;
      try {
        final read = await host.readSite(
          deviceBase: base,
          siteKey: siteKey,
          capability: capability ?? RealtimePullCapability.history,
          localByMatchKey: localIndex,
        );
        if (read.endpoint == RealtimePullCapability.currentOnly) {
          degraded.add(siteKey);
        }
        if (read.notFound) {
          // 404 = 该站点当前无记录（合法形态，`design/00` §3.1 契约 3）。
          continue;
        }
        // 口径：`total` = 原始返回条数（解析成功 + 内容等价跳过 + 永久不可合并），
        // 这样 `applied+skipped+failed == total` 恒成立（`isConsistent`）。
        total +=
            read.items.length + read.skippedAsUnchanged + read.unmergeable;
        skipped += read.skippedAsUnchanged;
        // **永久性失败**（记录本身不可合并）：计入 `failed` 明细并披露（P5），
        // 但**不**把整轮归为 `partial`。
        //
        // 为什么（L3 实测出来的真实缺陷）：这类记录下轮、下下轮永远同样结果，
        // 重试无意义；若算 `partial`，而 `partial` 不推进游标
        // （`design/01` §6.3）→ **游标永久卡死**，增量语义彻底失效。
        if (read.unmergeable > 0) {
          failed += read.unmergeable;
          unmergeable += read.unmergeable;
        }
        if (read.items.isEmpty) continue;

        // 真的拿到记录才解析归属：空轮（安卓没在播）不该付一次设备请求。
        batchSourceKey ??= await host.resolveSourceKey(deviceBase: base);
        final stats = await host.mergeHistory(
          read.items,
          sourceKey: batchSourceKey,
        );
        applied += stats.applied;
        skipped += stats.skipped;
        // 合并阶段的失败是**暂时性**的（写库异常，下轮重试有意义）→
        // 计入 `failed` 并且算 `partial`（不推进游标，整批下轮重试）。
        failed += stats.failed;
        if (stats.failed > 0) partial = true;
        for (final item in read.items) {
          if (item.updatedAt > maxCursor) maxCursor = item.updatedAt;
        }
      } on AppError catch (caught) {
        final status = caught.statusCode;
        if (status == 403 || caught.kind == AppErrorKind.syncDisabled) {
          unauthorized = true;
          error = caught;
        } else if (status == 404) {
          // 已由 readSite 转成 notFound；走到这里说明实现方没转，仍不算失败。
        } else if (countsTowardBackoff(
          statusCode: status,
          isNetworkError: caught.retryable,
        )) {
          networkFailure = true;
          error ??= caught;
        }
        log.warning(
          '站点读取失败 site=$siteKey ${caught.logLine}',
          scope: 'realtime',
        );
      } on Object catch (cause) {
        networkFailure = true;
        error ??= AppError(
          AppErrorKind.realtimePartialFailure,
          '读取安卓历史失败',
          detail: '$cause',
          retryable: true,
        );
        log.warning('站点读取异常 site=$siteKey $cause', scope: 'realtime');
      }
    }

    _degradedSites = List.unmodifiable(degraded);

    final outcome = unauthorized
        ? RealtimeBatchOutcome.unauthorized
        : networkFailure
        ? RealtimeBatchOutcome.failure
        : partial
        ? RealtimeBatchOutcome.partial
        : RealtimeBatchOutcome.success;

    // 游标裁决**只**发生在这一处（`design/04` 反向验证 #6）。
    final decision = decideCursor(
      currentCursor: _cursor,
      outcome: outcome,
      remoteMaxCursor: maxCursor > _cursor ? maxCursor : null,
    );
    _cursor = decision.nextCursor;
    if (outcome == RealtimeBatchOutcome.unauthorized) _pollStopped = true;

    final stats = SyncMergeStats(
      applied: applied,
      skipped: skipped,
      failed: failed,
      total: total,
    );
    _lastPoll = RealtimePollResult(
      stats: stats,
      siteCount: keys.length,
      outcome: outcome,
      cursor: _cursor,
      cursorAdvanced: decision.advance,
      stopped: decision.stopDirection,
      unmergeable: unmergeable,
      error: error,
      degradedSites: _degradedSites,
    );
    _recordPollFailure(
      outcome,
      error,
      countsTowardBackoff:
          outcome == RealtimeBatchOutcome.failure ||
          outcome == RealtimeBatchOutcome.unauthorized,
      siteCount: keys.length,
    );
    log.info(
      '轮询完成 ${_lastPoll!.describe()}'
      '${error == null ? '' : ' error=${error.logLine}'}',
      scope: 'realtime',
    );
    return _lastPoll;
  }

  /// 轮询失败后的状态推进（退避计数 / 暂停 / 停止）。
  void _recordPollFailure(
    RealtimeBatchOutcome outcome,
    AppError? error, {
    required bool countsTowardBackoff,
    required int siteCount,
  }) {
    _lastPollAtMs = _clock().millisecondsSinceEpoch;
    if (outcome == RealtimeBatchOutcome.success) {
      _pollFailures = 0;
      _lastError = null;
      return;
    }
    if (outcome == RealtimeBatchOutcome.partial) {
      // 部分失败：不推进游标（已由 decideCursor 保证），不涨退避计数
      // ——下一轮就会重试同一批（`design/01` §6.3 最后一行）。
      _lastError = error;
      return;
    }
    if (!countsTowardBackoff) return;

    final frozen = _peerState == RealtimePeerState.peerFrozen;
    final decision = decideRealtimeFailure(
      consecutiveFailures: _pollFailures,
      statusCode: error?.statusCode,
      isNetworkError: true,
      peerFrozen: frozen,
      detail: error?.detail ?? '站点数=$siteCount',
    );
    _pollFailures = decision.nextConsecutiveFailures;
    _lastError = decision.error ?? error;
    if (decision.stopDirection) {
      _pollStopped = true;
      _cancelPoll();
    }
    if (decision.paused) {
      _pollPaused = true;
      _cancelPoll();
      log.warning(
        '连续 $_pollFailures 次失败，已暂停自动轮询（等用户手动重试或心跳恢复）',
        scope: 'realtime',
      );
    }
  }

  // ------------------------------------------------------------------ 心跳

  /// 立刻跑一次心跳（手动操作与定时器共用）。
  Future<RealtimeHeartbeatOutcome?> heartbeatNow() async {
    if (!_switches.shouldHeartbeat || _heartbeatStopped) return null;
    final base = _deviceBase;
    if (base == null) return null;

    RealtimeHeartbeatProbe probe;
    try {
      probe = await host.heartbeat(base);
    } on AppError catch (caught) {
      probe = RealtimeHeartbeatProbe(
        state: caught.kind == AppErrorKind.keepAlivePeerFrozen
            ? RealtimePeerState.peerFrozen
            : caught.kind == AppErrorKind.keepAliveServiceStopped
            ? RealtimePeerState.serviceStopped
            : RealtimePeerState.networkUnreachable,
        statusCode: caught.statusCode,
        detail: caught.message,
      );
    } on Object catch (cause) {
      probe = RealtimeHeartbeatProbe(
        state: RealtimePeerState.networkUnreachable,
        detail: '$cause',
      );
    }

    final previousState = _peerState;
    _peerState = probe.state;
    _lastHeartbeatAtMs = _clock().millisecondsSinceEpoch;
    _backgroundGuide = probe.backgroundGuide ?? _backgroundGuide;

    final wasPaused = _pollPaused;
    AppError? error;
    var stopped = false;
    var triggeredPoll = false;

    if (probe.state == RealtimePeerState.ok) {
      // 恢复：清计数、解除暂停、回到配置周期，并**立刻补一轮**。
      final recovered = wasPaused || _heartbeatFailures > 0;
      _heartbeatFailures = 0;
      _pollFailures = 0;
      _pollPaused = false;
      _wakeLevel = RealtimeWakeLevel.none;
      _lastError = null;
      if (previousState != RealtimePeerState.ok) {
        log.info(
          '安卓可达性恢复：${previousState.name} → ok'
          '${recovered ? '（补一轮轮询）' : ''}',
          scope: 'realtime',
        );
      }
      if (recovered && _switches.shouldPoll && !_pollStopped) {
        await pollNow();
        _schedulePoll();
        triggeredPoll = true;
      }
    } else {
      final failures = _heartbeatFailures + 1;
      _heartbeatFailures = failures;
      final wake = selectWakeLevel(
        consecutiveFailures: failures,
        state: probe.state,
        backgroundSettingsNeeded: probe.backgroundSettingsNeeded ?? false,
      );
      _wakeLevel = wake;
      // 心跳失败 → 暂停轮询（`design/02` §3.3）：不可达时轮询全是超时。
      _pollPaused = true;
      _cancelPoll();
      final decision = decideRealtimeFailure(
        consecutiveFailures: failures - 1,
        statusCode: probe.statusCode,
        isNetworkError: true,
        peerFrozen: probe.state == RealtimePeerState.peerFrozen,
        detail: probe.detail ?? probe.state.name,
      );
      error = decision.error;
      _lastError = decision.error;
      if (decision.stopDirection) {
        _heartbeatStopped = true;
        stopped = true;
        _cancelHeartbeat();
      }
      if (decision.paused) {
        _heartbeatStopped = true;
        stopped = true;
        _cancelHeartbeat();
        log.warning(
          '连续 $failures 次心跳失败，已停止自动心跳（等用户「立即重连」）',
          scope: 'realtime',
        );
      }
      log.warning(
        '心跳失败 ${probe.describe()} wake=${wake.name} failures=$failures',
        scope: 'realtime',
      );
    }

    _lastHeartbeat = RealtimeHeartbeatOutcome(
      probe: probe,
      consecutiveFailures: _heartbeatFailures,
      wakeLevel: _wakeLevel,
      pollPaused: _pollPaused,
      stopped: stopped,
      triggeredPoll: triggeredPoll,
      error: error,
    );
    return _lastHeartbeat;
  }
}
