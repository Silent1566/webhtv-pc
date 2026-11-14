/// 实时同步与保活的**纯逻辑**层（`docs/phase7/design/01` §6、`design/02` §3–§5）。
///
/// 本文件**只放可离线单测的判定函数与值对象**：不做 I/O、不引 HTTP 客户端、
/// 不碰 `settings.json`、不碰数据库。定时器编排在
/// `lib/services/realtime_sync_engine.dart`（T6），状态持久化在
/// `lib/state/sync_state.dart`（T7）。
///
/// 为什么先抽纯逻辑：本阶段最容易悄悄写错的恰恰是这些**边界判定**
/// （游标该不该推进、退避倍数、三态归类、`duration<=0` 算不算播完）。
/// 把它们与 I/O 隔离后，可以用 `test()` 直接锁死，且
/// `tools/phase7/verify_reverse_checks.py` 的 8 项反向破坏能在秒级验证。
library;

import 'android_sync.dart';
import 'app_error.dart';

// ---------------------------------------------------------------------------
// 周期与开关（`design/01` §6.1、§6.2；`design/02` §3.4）
// ---------------------------------------------------------------------------

/// 轮询周期可选档位（秒）。`design/01` §6.1 的「15/30/60/300 四选一」。
const List<int> realtimeIntervalChoices = [15, 30, 60, 300];

/// 轮询周期默认值（秒）。`design/01` §6.1。
const int realtimeDefaultIntervalSeconds = 60;

/// 轮询周期下限（秒）。`design/02` §3.4：低于此值在移动端是电量事故。
const int realtimeMinIntervalSeconds = 15;

/// 轮询周期上限（秒）。`design/02` §3.4：超过 1 h 已不是「实时」。
const int realtimeMaxIntervalSeconds = 3600;

/// 心跳周期默认值（秒）。`design/02` §3.4。
const int keepAliveDefaultHeartbeatSeconds = 30;

/// 心跳周期下限（秒）。
const int keepAliveMinHeartbeatSeconds = 10;

/// 心跳周期上限（秒）。
///
/// **必须 < `ManageService.IDLE_TIMEOUT`（600 s）的一半**（`design/02` §3.4）：
/// 300 s 给重试留出一次余量；否则安卓会在心跳间隙里 `stopSelf()`，
/// 表现为「心跳全红但其实刚成功过」。
const int keepAliveMaxHeartbeatSeconds = 300;

/// 默认只轮询「最近活跃」的站点数（`design/01` §3.1、R2）。
///
/// 为什么要有上限：安卓把 `siteKey` 逐个读，站点上百时一轮就是上百个请求；
/// 移动端电量与本机负载都不允许（`design/01` §3.1）。
const int realtimeDefaultSiteLimit = 20;

/// 把任意输入归一化到最近的合法轮询周期档位。
///
/// 语义：**非法值不静默接受**（`design/02` §3.4），而是吸附到合法值；
/// UI 用返回值回显，用户能看到自己填的值被规整成了什么。
///
/// 规则（与 `test/phase7_realtime_core_test.dart` 逐条对应）：
/// - `null` / 非有限 → 默认 60 s；
/// - 超出 `[15, 3600]` → 夹到边界；
/// - 落在档位之间 → 取**最近**档位（并列时取**较大**值：同样贴近，
///   但请求更稀疏、更省电，且与默认值 60 s 的方向一致）。
int normalizeRealtimeIntervalSeconds(int? value) {
  if (value == null) return realtimeDefaultIntervalSeconds;
  final clamped = value.clamp(
    realtimeMinIntervalSeconds,
    realtimeMaxIntervalSeconds,
  );
  // 升序遍历，`<=` 让“并列时取较大档位”：45 s 的 30/60 距离都是 15，
  // 取 60（请求更稀疏、与默认值同向）。
  var best = realtimeIntervalChoices.first;
  var bestDistance = (clamped - best).abs();
  for (final choice in realtimeIntervalChoices.skip(1)) {
    final distance = (clamped - choice).abs();
    if (distance <= bestDistance) {
      best = choice;
      bestDistance = distance;
    }
  }
  return best;
}

/// 把任意输入归一化到合法心跳周期（秒）。
///
/// 与 [normalizeRealtimeIntervalSeconds] 的两个区别：
/// 1. 心跳不是「四选一」，而是区间 `[10, 300]`（`design/02` §3.4）；
/// 2. 还需满足「心跳 ≤ 轮询」——该约束由
///    [normalizeHeartbeatWithIntervalSeconds] 施加，本函数只做区间夹取。
int normalizeHeartbeatSeconds(int? value) {
  if (value == null) return keepAliveDefaultHeartbeatSeconds;
  if (value < keepAliveMinHeartbeatSeconds) return keepAliveMinHeartbeatSeconds;
  if (value > keepAliveMaxHeartbeatSeconds) return keepAliveMaxHeartbeatSeconds;
  return value;
}

/// 保活心跳周期：先夹区间，再保证 `心跳 <= 轮询`（`design/02` §3.4）。
///
/// **为什么必须强制 `心跳 <= 轮询`**：心跳的作用之一是给「现在能不能发请求」
/// 提供前置结论（H2）。若心跳比轮询还慢，可达性判定会滞后于轮询——
/// 轮询会先撞上不可达的墙，然后再由心跳去解释原因。
int normalizeHeartbeatWithIntervalSeconds({
  required int? heartbeatSeconds,
  required int intervalSeconds,
}) {
  final normalized = normalizeHeartbeatSeconds(heartbeatSeconds);
  // 轮询本身可能被配成 15 s，而心跳下限是 10 s，所以两者并不冲突；
  // 但若轮询被归一化到低于心跳下限（调用方传了未归一化的值），
  // 这里也必须收敛，不能返回一个大于轮询的心跳。
  final ceiling = intervalSeconds < keepAliveMinHeartbeatSeconds
      ? keepAliveMinHeartbeatSeconds
      : intervalSeconds;
  return normalized > ceiling ? ceiling : normalized;
}

/// 实时同步开关矩阵（`design/01` §6.1）。**全部默认关闭**（P1）。
///
/// 不可变值对象：任何修改都必须产生新实例，避免「就地改开关导致 UI 与
/// 引擎读到的不是同一份状态」。
class RealtimeSyncSwitches {
  const RealtimeSyncSwitches({
    this.enabled = false,
    this.pullEnabled = false,
    this.pushEnabled = false,
    this.settingsEnabled = false,
    this.intervalSeconds = realtimeDefaultIntervalSeconds,
    this.heartbeatSeconds = keepAliveDefaultHeartbeatSeconds,
    this.pollAllSites = false,
  });

  /// 总开关。关闭后所有子开关失效且定时器/心跳停止。
  final bool enabled;

  /// 路径 A：PC 主动轮询安卓。
  final bool pullEnabled;

  /// 路径 B：把 PC 的增量端点暴露给安卓远端同步源。
  final bool pushEnabled;

  /// 设置（TMDB / AI）实时同步。含凭据项参与实时需它显式开启。
  final bool settingsEnabled;

  final int intervalSeconds;
  final int heartbeatSeconds;

  /// 是否轮询全部站点（默认只轮询最近活跃的 [realtimeDefaultSiteLimit] 个）。
  final bool pollAllSites;

  /// 归一化后的周期（`design/02` §3.4）。
  RealtimeSyncSwitches normalized() {
    final interval = normalizeRealtimeIntervalSeconds(intervalSeconds);
    return RealtimeSyncSwitches(
      enabled: enabled,
      pullEnabled: pullEnabled,
      pushEnabled: pushEnabled,
      settingsEnabled: settingsEnabled,
      intervalSeconds: interval,
      heartbeatSeconds: normalizeHeartbeatWithIntervalSeconds(
        heartbeatSeconds: heartbeatSeconds,
        intervalSeconds: interval,
      ),
      pollAllSites: pollAllSites,
    );
  }

  /// 是否需要跑轮询定时器：总开关 + 拉取方向。
  bool get shouldPoll => enabled && pullEnabled;

  /// 是否需要跑心跳定时器。
  ///
  /// 与 [`shouldPoll`] 的区别：**心跳在只开推送方向时也要跑**——
  /// 路径 B 依赖安卓来拉 PC，而「安卓还在不在、服务还活着吗」仍需心跳判定
  /// 才能在 UI 上给出可信状态（H2/H3）。
  bool get shouldHeartbeat => enabled && (pullEnabled || pushEnabled);

  RealtimeSyncSwitches copyWith({
    bool? enabled,
    bool? pullEnabled,
    bool? pushEnabled,
    bool? settingsEnabled,
    int? intervalSeconds,
    int? heartbeatSeconds,
    bool? pollAllSites,
  }) => RealtimeSyncSwitches(
    enabled: enabled ?? this.enabled,
    pullEnabled: pullEnabled ?? this.pullEnabled,
    pushEnabled: pushEnabled ?? this.pushEnabled,
    settingsEnabled: settingsEnabled ?? this.settingsEnabled,
    intervalSeconds: intervalSeconds ?? this.intervalSeconds,
    heartbeatSeconds: heartbeatSeconds ?? this.heartbeatSeconds,
    pollAllSites: pollAllSites ?? this.pollAllSites,
  );

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'pullEnabled': pullEnabled,
    'pushEnabled': pushEnabled,
    'settingsEnabled': settingsEnabled,
    'intervalSeconds': intervalSeconds,
    'heartbeatSeconds': heartbeatSeconds,
    'pollAllSites': pollAllSites,
  };

  @override
  String toString() =>
      'RealtimeSyncSwitches(enabled=$enabled pull=$pullEnabled '
      'push=$pushEnabled settings=$settingsEnabled '
      'interval=${intervalSeconds}s heartbeat=${heartbeatSeconds}s '
      'pollAll=$pollAllSites)';
}

/// 开关联动的裁决结果（`design/01` §6.2）。
class RealtimeSwitchDecision {
  const RealtimeSwitchDecision({
    required this.switches,
    this.autoEnabledServer = false,
    this.rejected = false,
    this.error,
  });

  /// 裁决后的开关状态（可能已被自动修正）。
  final RealtimeSyncSwitches switches;

  /// 是否因联动而自动开启了 PC 服务端（需要在 UI 上提示用户）。
  final bool autoEnabledServer;

  /// 是否**拒绝**了本次修改（开关保持原值）。
  final bool rejected;

  /// 拒绝原因（`rejected == true` 时必然非空）。
  final AppError? error;
}

/// 应用「实时同步」开关联动规则（`design/01` §6.2）。
///
/// 输入是**用户想要的状态**与当前 PC 服务端/设置同步开关。返回实际生效的状态。
///
/// 三条规则：
/// 1. `pushEnabled=true` 但 `serverEnabled=false` → **自动开启服务端**并提示
///    （否则路径 B 不可能工作：安卓来拉时端口没人监听）；
/// 2. `settingsEnabled=true` 但 `settingsSyncEnabled=false` → **拒绝**，
///    开关保持 false（避免绕过 Phase 5 的凭据确认）；
/// 3. `enabled=false` → 定时器与心跳全停，但 `realtime.*` 子开关值**保留**
///    （下次开启沿用用户上次的选择，不重置成默认）。
RealtimeSwitchDecision applyRealtimeSwitchRules({
  required RealtimeSyncSwitches desired,
  required bool serverEnabled,
  required bool settingsSyncEnabled,
}) {
  final normalized = desired.normalized();

  if (normalized.settingsEnabled && !settingsSyncEnabled) {
    // 规则 2 优先于规则 1：直接拒绝，不产生任何副作用。
    // 理由：设置实时同步会把含凭据的 `ai_config` / `tmdb_config` 明文过 HTTP，
    // 必须先让用户在 Phase 5 的「同步设置」处显式确认过（P1）。
    return RealtimeSwitchDecision(
      switches: normalized.copyWith(settingsEnabled: false),
      rejected: true,
      error: AppError(
        AppErrorKind.realtimeSyncDisabled,
        '请先在「同步设置」中开启「允许同步设置（含凭据）」',
      ),
    );
  }

  var needsServer = normalized.pushEnabled && !serverEnabled;
  // 关闭总开关时不自动开服务端：用户正在关掉同步，不该顺手拉起监听端口。
  if (!normalized.enabled) needsServer = false;

  return RealtimeSwitchDecision(
    switches: normalized,
    autoEnabledServer: needsServer,
  );
}

// ---------------------------------------------------------------------------
// 增量游标（`design/01` §4.2、§7；`design/00` §3.1 契约 9）
// ---------------------------------------------------------------------------

/// 一轮拉取/推送的结果分类。决定游标是否推进。
enum RealtimeBatchOutcome {
  /// 整批成功（含「0 条」这种合法空结果）。
  success,

  /// 部分条目失败（合并阶段的单条异常）。**不得推进游标**。
  partial,

  /// 连接/协议级失败。**不得推进游标**。
  failure,

  /// 鉴权失败。立即停止该方向。
  unauthorized,
}

/// 游标推进裁决（P3：失败不破坏本地 → 游标只在整批成功后推进）。
class RealtimeCursorDecision {
  const RealtimeCursorDecision({
    required this.nextCursor,
    required this.advance,
    this.stopDirection = false,
  });

  /// 下一轮的游标值（`advance == false` 时等于原值）。
  final int nextCursor;

  /// 是否推进。
  final bool advance;

  /// 是否应立即停止该方向的定时器（403 等重试无意义的情况）。
  final bool stopDirection;
}

/// 依据本轮结果裁决游标（`design/01` §4.2、§7）。
///
/// **不变式**：只有 [RealtimeBatchOutcome.success] 才推进，且
/// `nextCursor` 只能**单调不减**——游标回退会让安卓侧把已同步的记录再推一遍，
/// 进而与本地删除墓碑产生难查的交互（`design/00` §3.6）。
///
/// [remoteMaxCursor] 是响应里对端给出的「最新游标」。
/// 当它**小于**当前游标时，说明安卓重装/清数据了（`realtimeCursorStale`）：
/// 此时**回到远端值**是正确行为——那不是"回退"，而是承认对端换了数据源。
RealtimeCursorDecision decideCursor({
  required int currentCursor,
  required RealtimeBatchOutcome outcome,
  int? remoteMaxCursor,
}) {
  if (outcome == RealtimeBatchOutcome.unauthorized) {
    // 鉴权失败：既不动游标，也停止该方向（重试只会一直 403）。
    return RealtimeCursorDecision(
      nextCursor: currentCursor,
      advance: false,
      stopDirection: true,
    );
  }
  if (outcome != RealtimeBatchOutcome.success) {
    return RealtimeCursorDecision(nextCursor: currentCursor, advance: false);
  }
  final remote = remoteMaxCursor;
  if (remote == null) {
    // 成功但响应没给游标：保持不动（宁可不推进，也不猜一个值）。
    return RealtimeCursorDecision(nextCursor: currentCursor, advance: false);
  }
  if (remote < currentCursor) {
    // 对端重装/清数据 → 游标比远端还新。接受远端值（见上文不变式的例外）。
    return RealtimeCursorDecision(nextCursor: remote, advance: true);
  }
  return RealtimeCursorDecision(
    nextCursor: remote,
    advance: remote > currentCursor,
  );
}

/// 游标是否「陈旧」（`realtimeCursorStale`，`design/01` §8）。
///
/// 触发条件：远端给出的最大游标**严格小于**本地已推进到的游标。
/// 等于是陈旧——安卓重装后第一条记录可能正好是同一个数值。
bool isCursorStale({required int currentCursor, required int remoteMaxCursor}) =>
    remoteMaxCursor < currentCursor;

/// 计算本轮要轮询的站点清单（`design/01` §3.1、R2）。
///
/// 返回 null 表示「轮询全部」（`pollAllSites = true`）。
/// 非 null 时优先取 [recentlyActive]（最新在前），再按 [known] 补齐。
List<String>? selectPollSites({
  required List<String> known,
  required bool pollAllSites,
  List<String> recentlyActive = const [],
  int limit = realtimeDefaultSiteLimit,
}) {
  if (pollAllSites) return null;
  return prioritizePollSites(
    recentlyActive: recentlyActive,
    known: known,
    limit: limit,
  );
}

// ---------------------------------------------------------------------------
// 失败退避（`design/01` §6.3；`design/02` §5.2）
// ---------------------------------------------------------------------------

/// 退避倍数序列上限（`design/01` §6.3：1× → 2× → 4× → 8×）。
const int realtimeMaxBackoffMultiplier = 8;

/// 连续失败多少次后暂停自动重试（`design/01` §6.3 / `design/02` §5.2）。
const int realtimePauseAfterFailures = 5;

/// 依据连续失败次数给出退避倍数。
///
/// 序列：0/1 → 1×，2 → 2×，3 → 4×，4 → 8×，≥5 → 8×（并由
/// [shouldPauseRealtime] 决定是否直接暂停）。
int realtimeBackoffMultiplier(int consecutiveFailures) {
  if (consecutiveFailures <= 1) return 1;
  var multiplier = 1;
  for (var i = 1; i < consecutiveFailures && multiplier < realtimeMaxBackoffMultiplier; i++) {
    multiplier *= 2;
  }
  return multiplier > realtimeMaxBackoffMultiplier
      ? realtimeMaxBackoffMultiplier
      : multiplier;
}

/// 连续失败次数是否已达「暂停自动重试」阈值（`design/01` §6.3）。
bool shouldPauseRealtime(int consecutiveFailures) =>
    consecutiveFailures >= realtimePauseAfterFailures;

/// 计算下一次尝试的间隔（秒）。
///
/// [baseSeconds] 是当前方向的基准周期（轮询或心跳），
/// 结果夹到 [keepAliveMaxHeartbeatSeconds]（上限与 heartbeat 一致：
/// 超过 300 s 的等待已经等于「用户以为坏了」）。
int realtimeNextDelaySeconds({
  required int baseSeconds,
  required int consecutiveFailures,
}) {
  final base = baseSeconds <= 0 ? realtimeDefaultIntervalSeconds : baseSeconds;
  final delay = base * realtimeBackoffMultiplier(consecutiveFailures);
  return delay > keepAliveMaxHeartbeatSeconds
      ? keepAliveMaxHeartbeatSeconds
      : delay;
}

/// 判断一次失败是否应参与退避计数（`design/01` §6.3）。
///
/// **404 不算失败**：`/api/playback/current` 在未播放时恒 404，
/// 那是「该站点当前无记录」的合法形态（`design/00` §3.1 契约 3）。
/// 把它计入退避会让正常使用时的退避计数无意义地涨上去。
bool countsTowardBackoff({required int? statusCode, required bool isNetworkError}) {
  if (statusCode == 404) return false;
  if (statusCode == 403) return true; // 立即停止，由调用方处理
  if (isNetworkError) return true;
  if (statusCode == null) return false;
  return statusCode >= 500;
}

/// 连续失败后的动作裁决（`design/01` §6.3）。
class RealtimeFailureDecision {
  const RealtimeFailureDecision({
    required this.nextConsecutiveFailures,
    required this.multiplier,
    required this.paused,
    required this.stopDirection,
    required this.error,
  });

  final int nextConsecutiveFailures;
  final int multiplier;
  final bool paused;
  final bool stopDirection;
  final AppError? error;
}

/// 依据一次失败事件裁决下一步（`design/01` §6.3）。
///
/// [peerFrozen] 为 true 时错误分类改用 `keepAlivePeerFrozen`
/// （`design/02` §7）——同样一次失败，用户看到的指引完全不同。
RealtimeFailureDecision decideRealtimeFailure({
  required int consecutiveFailures,
  required int? statusCode,
  required bool isNetworkError,
  bool peerFrozen = false,
  String? detail,
}) {
  if (statusCode == 403) {
    // 重试无意义：服务端未开启或未授权。**不**增加失败计数（计数是给退避用的，
    // 而这里已经不再重试了，涨上去只会污染 UI 上的"重试中"提示）。
    return RealtimeFailureDecision(
      nextConsecutiveFailures: consecutiveFailures,
      multiplier: 1,
      paused: false,
      stopDirection: true,
      error: AppError(
        AppErrorKind.syncDisabled,
        '对端未开启服务端或未授权本机',
        detail: detail,
        statusCode: statusCode,
      ),
    );
  }

  if (!countsTowardBackoff(statusCode: statusCode, isNetworkError: isNetworkError)) {
    // 404 等「非失败」形态：计数不变，也不退避。
    return RealtimeFailureDecision(
      nextConsecutiveFailures: consecutiveFailures,
      multiplier: realtimeBackoffMultiplier(consecutiveFailures),
      paused: false,
      stopDirection: false,
      error: null,
    );
  }

  final next = consecutiveFailures + 1;
  final paused = shouldPauseRealtime(next);
  return RealtimeFailureDecision(
    nextConsecutiveFailures: next,
    multiplier: realtimeBackoffMultiplier(next),
    paused: paused,
    stopDirection: false,
    error: AppError(
      peerFrozen ? AppErrorKind.keepAlivePeerFrozen : AppErrorKind.realtimePartialFailure,
      peerFrozen ? '安卓进程可能被冻结' : '实时同步请求失败',
      detail: detail,
      retryable: !paused,
      statusCode: statusCode,
    ),
  );
}

// ---------------------------------------------------------------------------
// 可达性三态判定（`design/02` §4）
// ---------------------------------------------------------------------------

/// 可达性三态（`design/02` §4）。
///
/// **为什么必须三态而不是 bool**：把「连不上」拆成可操作的三态是本设计的
/// 核心——用户看到「SERVICE_STOPPED」会去开安卓管理页，看到「PEER_FROZEN」
/// 会去改电池设置，看到「NETWORK_UNREACHABLE」会去查 WiFi。合成一个
/// 「不可达」等于什么都没说（`design/02` §4 引文）。
enum RealtimePeerState {
  /// 可达：`/manage/session` 或 `/device` 返回了 200。
  ok,

  /// 端口无人监听（连接被拒）。指向安卓「管理页」。
  serviceStopped,

  /// TCP 可连但 HTTP 无响应（进程被系统冻结）。指向安卓电池/自启动设置。
  peerFrozen,

  /// 完全不通（TCP 超时）。指向网络。
  networkUnreachable,
}

/// 单次探测的结果（由 I/O 层填，纯逻辑层只消费）。
enum RealtimeProbeStep {
  /// `GET /manage/session` 成功（200）。
  manageOk,

  /// `/manage/session` 返回 404/405（老版本安卓无此端点）→ 需降级探测。
  manageMissing,

  /// 连接被拒（端口没人监听）。
  connectionRefused,

  /// 请求超时。
  timeout,

  /// `GET /device` 成功（200）。
  deviceOk,

  /// TCP connect 成功但 HTTP 无响应。
  tcpConnectedNoHttp,
}

/// 三态判定（`design/02` §4）。
///
/// 输入是按 S1→S2→S3 顺序得到的探测步，输出状态。测试用它断言「探测步数」，
/// 从而证明 200 时**没有**多做无谓请求（K4/K5）。
///
/// **空列表归为 [RealtimePeerState.networkUnreachable]**：
/// 调用方只有真探测过才会传非空列表；空列表等同于「什么都没通」，
/// 而不能等同于「可达」。
RealtimePeerState classifyProbeSteps(List<RealtimeProbeStep> steps) {
  for (final step in steps) {
    switch (step) {
      case RealtimeProbeStep.manageOk:
      case RealtimeProbeStep.deviceOk:
        // S1 或 S2 成功即可达，且不再往下探测。
        return RealtimePeerState.ok;
      case RealtimeProbeStep.connectionRefused:
        // 「拒绝」在三步里的含义一致：**端口没人监听**。
        // 注意 S3 的「拒绝」也是 SERVICE_STOPPED，不是 FROZEN——
        // 进程被冻结时内核仍会完成 TCP 握手，不会拒绝。
        return RealtimePeerState.serviceStopped;
      case RealtimeProbeStep.tcpConnectedNoHttp:
        return RealtimePeerState.peerFrozen;
      case RealtimeProbeStep.manageMissing:
      case RealtimeProbeStep.timeout:
        // 继续看下一步。
        continue;
    }
  }
  // 走到这里说明：manage 缺失/超时 + device 缺失/超时 + TCP 也超时。
  return RealtimePeerState.networkUnreachable;
}

/// 把三态映射到错误类别（`design/02` §7）。
AppErrorKind keepAliveErrorKindFor(RealtimePeerState state) => switch (state) {
  RealtimePeerState.ok => throw ArgumentError(
    '可达到的状态不该映射为错误',
  ),
  RealtimePeerState.serviceStopped => AppErrorKind.keepAliveServiceStopped,
  RealtimePeerState.peerFrozen => AppErrorKind.keepAlivePeerFrozen,
  RealtimePeerState.networkUnreachable => AppErrorKind.keepAliveNetworkUnreachable,
};

/// 三态结果缓存（`design/02` §4.1：缓存 30 s）。
///
/// 做成显式值对象而不是藏在服务里的字段，是为了让「缓存是否生效」
/// 可以被纯逻辑测试直接锁定（K6）。
class RealtimePeerStateCache {
  RealtimePeerStateCache({this.ttl = const Duration(seconds: 30)});

  final Duration ttl;

  RealtimePeerState? _state;
  DateTime? _cachedAt;

  /// 当前缓存的状态；过期或未探测过返回 `null`。
  RealtimePeerState? read(DateTime now) {
    final cachedAt = _cachedAt;
    if (_state == null || cachedAt == null) return null;
    if (now.difference(cachedAt) >= ttl) return null;
    return _state;
  }

  /// 写入探测结果。
  void write(RealtimePeerState state, DateTime now) {
    _state = state;
    _cachedAt = now;
  }

  /// 主动失效（例如退避恢复后必须重新判定，不得沿用旧状态）。
  void invalidate() {
    _state = null;
    _cachedAt = null;
  }
}

// ---------------------------------------------------------------------------
// 唤醒阶梯（`design/02` §5.1）
// ---------------------------------------------------------------------------

/// 唤醒阶梯级别，由轻到重（`design/02` §5.1：**禁止跳级**）。
enum RealtimeWakeLevel {
  /// L0：什么都不做，等下一次心跳。
  none,

  /// L1：`GET /manage/session`（会 `touch()` 续命）。
  touchManage,

  /// L2：`GET /device`（老版本兼容）。
  touchDevice,

  /// L3：提示用户「请在安卓打开管理页」。**仅提示**。
  promptOpenManage,

  /// L4：提示用户「请点亮安卓屏幕一次」。**仅提示**。
  promptWakeScreen,

  /// L5：提供「打开安卓后台设置」按钮（需用户点击，会弹系统界面）。
  offerBackgroundSettings,
}

/// 依据连续失败次数与三态结果选择唤醒级别（`design/02` §5.1）。
///
/// 关键约束：
/// - **首次失败不动**（L0）——一次抖动就发请求是骚扰；
/// - **第 2 次失败起才 L1**；
/// - L3/L4 是**仅提示**，不得产生自动请求；
/// - L5 **只在** `backgroundSettingsNeeded=true` 时出现，且
///   `requireUserGesture` 恒为 true（`design/02` §5.1：L5 是唯一会改变
///   安卓侧状态的动作，必须由用户点击触发）。
RealtimeWakeLevel selectWakeLevel({
  required int consecutiveFailures,
  required RealtimePeerState state,
  bool backgroundSettingsNeeded = false,
}) {
  if (consecutiveFailures <= 1) return RealtimeWakeLevel.none;

  if (state == RealtimePeerState.peerFrozen) {
    // 冻结：能试的只有「让用户点亮屏幕」，且先提示再谈后台设置。
    return backgroundSettingsNeeded
        ? RealtimeWakeLevel.offerBackgroundSettings
        : RealtimeWakeLevel.promptWakeScreen;
  }

  if (state == RealtimePeerState.serviceStopped) {
    if (backgroundSettingsNeeded && consecutiveFailures >= 4) {
      return RealtimeWakeLevel.offerBackgroundSettings;
    }
    // L1：连续 2 次失败 → touch /manage/session（服务活着则续命）。
    if (consecutiveFailures == 2) return RealtimeWakeLevel.touchManage;
    // L2：L1 失败 → 老版本兼容探测。
    if (consecutiveFailures == 3) return RealtimeWakeLevel.touchDevice;
    // L3：L1/L2 都失败 → 仅提示。
    return RealtimeWakeLevel.promptOpenManage;
  }

  if (state == RealtimePeerState.networkUnreachable) {
    // 网络不通时任何 touch 都是徒劳（连不上就是连不上）；
    // 但帧率角度的「提示」必须有，否则用户只会看到一直转圈。
    return RealtimeWakeLevel.promptWakeScreen;
  }

  // OK 状态不该走到唤醒阶梯；返回 L0 而不是抛错，避免把状态机的小瑕疵
  // 升级成崩溃（调用点已有日志）。
  return RealtimeWakeLevel.none;
}

/// 该唤醒级别是否会向安卓发请求（`design/02` §5.1 的「仅提示」判定）。
///
/// 测试用它证明 L3/L4 **不产生请求**（K11）。
bool wakeLevelSendsRequest(RealtimeWakeLevel level) => switch (level) {
  RealtimeWakeLevel.touchManage || RealtimeWakeLevel.touchDevice => true,
  RealtimeWakeLevel.none ||
  RealtimeWakeLevel.promptOpenManage ||
  RealtimeWakeLevel.promptWakeScreen ||
  RealtimeWakeLevel.offerBackgroundSettings => false,
};

/// 该唤醒级别是否改变安卓侧状态（只有 L5 会）。
bool wakeLevelChangesPeerState(RealtimeWakeLevel level) =>
    level == RealtimeWakeLevel.offerBackgroundSettings;

/// 是否需要用户手势（只有 L5 需要，`design/02` §5.1）。
bool wakeLevelRequiresUserGesture(RealtimeWakeLevel level) =>
    level == RealtimeWakeLevel.offerBackgroundSettings;

// ---------------------------------------------------------------------------
// 手动操作语义（`design/01` §4.4、§4.5）
// ---------------------------------------------------------------------------

/// 手动拉取的三种语义（**必须分开标注**，`design/01` §4.4）。
///
/// 混成一个按钮会让用户在「服务端没开」时得到一个无法解释的失败。
enum RealtimeManualPullKind {
  /// 逐 `siteKey` 打 `/api/playback/history`。**不依赖**服务端与授权。
  recentRecords,

  /// `POST /action?do=sync&mode=2` 请求安卓推全量。需服务端 + 授权。
  requestAndroidPush,

  /// 清本地拉取游标后立刻跑一轮。用于游标错位/安卓重装后的恢复。
  resetCursorAndPull,
}

/// 手动推送的三种语义（`design/01` §4.5）。
enum RealtimeManualPushKind {
  /// Phase 5 的 `pushHistory`。需 `config.url` 非空。
  history,

  /// 推送删除墓碑（`design/01` §4.3）。
  deletions,

  /// 推送设置（`options.settings=true` 时才带凭据）。
  settings,

  /// 顺序执行历史 + 设置，任一失败即停并报明细。
  all,
}

/// 手动拉取的前置条件检查结果。
class RealtimeManualPullPrecheck {
  const RealtimeManualPullPrecheck({
    required this.allowed,
    this.error,
    this.requiresServer = false,
    this.requiresAuthorization = false,
  });

  final bool allowed;
  final AppError? error;
  final bool requiresServer;
  final bool requiresAuthorization;
}

/// 检查手动拉取是否可以执行（`design/01` §4.4）。
///
/// 关键点：[RealtimeManualPullKind.recentRecords] **不要求**实时同步总开关
/// 打开——它是用户在「实时同步关着」时唯一能读安卓历史的通道，
/// 把它也锁在总开关后面会让用户没有逃生口（`design/01` §4.4 的「为什么必须分开」）。
RealtimeManualPullPrecheck precheckManualPull({
  required RealtimeManualPullKind kind,
  required bool realtimeEnabled,
  required bool serverEnabled,
  required bool peerReachable,
  required String peerAddress,
}) {
  if (peerAddress.trim().isEmpty) {
    return RealtimeManualPullPrecheck(
      allowed: false,
      error: AppError(
        AppErrorKind.bridgeUnreachable,
        '尚未选择安卓设备地址',
      ),
    );
  }
  switch (kind) {
    case RealtimeManualPullKind.recentRecords:
      if (!peerReachable) {
        return const RealtimeManualPullPrecheck(
          allowed: false,
          error: null,
        );
      }
      return const RealtimeManualPullPrecheck(allowed: true);
    case RealtimeManualPullKind.requestAndroidPush:
      if (!serverEnabled) {
        return RealtimeManualPullPrecheck(
          allowed: false,
          requiresServer: true,
          error: AppError(
            AppErrorKind.syncDisabled,
            '需先开启「本机服务端」安卓才能把历史推过来',
          ),
        );
      }
      return const RealtimeManualPullPrecheck(allowed: true, requiresServer: true);
    case RealtimeManualPullKind.resetCursorAndPull:
      // 重置游标本身不改远端，但**需要实时拉取方向可跑**——
      // 否则「重置后立刻拉一轮」无处执行。
      if (!realtimeEnabled) {
        return RealtimeManualPullPrecheck(
          allowed: false,
          error: AppError(
            AppErrorKind.realtimeSyncDisabled,
            '需先开启实时同步总开关',
          ),
        );
      }
      return const RealtimeManualPullPrecheck(allowed: true);
  }
}

/// 手动推送的前置条件检查结果。
class RealtimeManualPushPrecheck {
  const RealtimeManualPushPrecheck({required this.allowed, this.error});

  final bool allowed;
  final AppError? error;
}

/// 检查手动推送是否可以执行（`design/01` §4.5）。
RealtimeManualPushPrecheck precheckManualPush({
  required RealtimeManualPushKind kind,
  required bool pushEnabled,
  required bool settingsSyncEnabled,
  required String peerAddress,
}) {
  if (peerAddress.trim().isEmpty) {
    return RealtimeManualPushPrecheck(
      allowed: false,
      error: AppError(AppErrorKind.syncPeerUnreachable, '尚未选择安卓设备地址'),
    );
  }
  if (!pushEnabled) {
    return RealtimeManualPushPrecheck(
      allowed: false,
      error: AppError(
        AppErrorKind.syncDisabled,
        '需先开启「允许向安卓推送」（在「同步设置」中）',
      ),
    );
  }
  if (kind == RealtimeManualPushKind.settings && !settingsSyncEnabled) {
    return RealtimeManualPushPrecheck(
      allowed: false,
      error: AppError(
        AppErrorKind.syncDisabled,
        '需先开启「允许同步设置（含凭据）」',
      ),
    );
  }
  return const RealtimeManualPushPrecheck(allowed: true);
}

// ---------------------------------------------------------------------------
// 能力探测与降级（`design/01` §4.1）
// ---------------------------------------------------------------------------

/// 路径 A 的读取端点能力（`design/01` §4.1 的探测矩阵）。
enum RealtimePullCapability {
  /// `/api/playback/history` 存在 → 路径 A 完整可用。
  history,

  /// 只有 `/api/playback/current` → 仅能同步正在播放的记录（需 UI 常驻提示）。
  currentOnly,

  /// 两者都不可用 → 路径 A 不可用，提示升级安卓端。
  unsupported,
}

/// 单个端点的探测结果（`design/01` §4.1，含 2026-10-17 的第二个阻塞性发现）。
///
/// **为什么不能只看状态码**：真机实测（`192.168.50.3:5561`）发现
/// 安卓 `Nano.serve()` 对**未匹配任何 `Process` 的路径**会落到
/// `getAssets()`，而 NanoHTTPD 对缺失资产返回
/// **`200 OK` + `application/octet-stream` + 空体**——**不是 404**。
///
/// 后果：只看状态码会把「端点不存在」当成「端点存在且无数据」，
/// 于是旧版安卓上路径 A 会“探测成功”但每次读取都静默拿到空结果。
/// 必须结合 **Content-Type 与响应体形态**判定。
enum EndpointProbeResult {
  /// 200 + JSON 体 → 端点存在且有数据。
  ok,

  /// 400 + JSON 体 → 端点存在，只是参数不对。
  badRequest,

  /// 404 + JSON 体 → 端点存在，但当前无该数据（合法形态）。
  notFound,

  /// 200 + 非 JSON（`octet-stream` / 空体）→ **端点不存在**（资产回退）。
  missing,

  /// 405 / 501 → 端点存在但不支持该方法。
  methodNotAllowed,

  /// 连不上 / 超时 / 非 HTTP 错误。
  unreachable,
}

/// 该探测结果是否说明端点**存在**。
bool endpointExists(EndpointProbeResult result) => switch (result) {
  EndpointProbeResult.ok ||
  EndpointProbeResult.badRequest ||
  EndpointProbeResult.notFound ||
  EndpointProbeResult.methodNotAllowed => true,
  EndpointProbeResult.missing || EndpointProbeResult.unreachable => false,
};

/// 由两个端点的探测结果推导能力（`design/01` §4.1）。
///
/// **注意**：`/api/playback/history` 返回 **200 + 空数组**同样是「可用」——
/// 「没有历史」与「端点不存在」必须可区分（`design/00` §3.1 契约 4）。
/// 把空数组当「端点缺失」会让所有站点都没看过的用户被永久降级。
RealtimePullCapability classifyPullCapability({
  required EndpointProbeResult history,
  required EndpointProbeResult current,
}) {
  if (endpointExists(history)) return RealtimePullCapability.history;
  if (endpointExists(current)) return RealtimePullCapability.currentOnly;
  return RealtimePullCapability.unsupported;
}

/// 由**状态码 + 响应体形态**归类单个端点（`design/01` §4.1）。
///
/// [statusCode] 为 `null` 表示连不上/超时。
/// [contentType] 是响应的 `Content-Type`（可能含 `; charset=utf-8`）。
/// [bodyLength] 是响应体字节数。
///
/// 判据（真机实测校正，见 [EndpointProbeResult] 的注释）：
/// - `200` + JSON → [EndpointProbeResult.ok]；
/// - `200` + 非 JSON（`octet-stream` 或空体）→ [EndpointProbeResult.missing]；
/// - `400` + JSON → [EndpointProbeResult.badRequest]；
/// - `404` + JSON → [EndpointProbeResult.notFound]；
/// - `405`/`501` → [EndpointProbeResult.methodNotAllowed]；
/// - 其他 → [EndpointProbeResult.missing]（保守：宁可降级也不假装可用）。
EndpointProbeResult classifyEndpointProbe({
  required int? statusCode,
  String? contentType,
  int bodyLength = 0,
}) {
  if (statusCode == null) return EndpointProbeResult.unreachable;
  final isJson = (contentType ?? '').toLowerCase().contains('json');
  switch (statusCode) {
    case 200:
      // 关键分支：安卓的资产回退就是 200 + octet-stream + 空体。
      return isJson ? EndpointProbeResult.ok : EndpointProbeResult.missing;
    case 400:
      return EndpointProbeResult.badRequest;
    case 404:
      // 404 是「端点存在但无数据」的合法形态（`/current` 未播放时）。
      // 但若 Content-Type 不是 JSON，说明是别的 404（如代理/网关），保守归 missing。
      return isJson ? EndpointProbeResult.notFound : EndpointProbeResult.missing;
    case 405:
    case 501:
      return EndpointProbeResult.methodNotAllowed;
    default:
      // 5xx 等：端点可能存在但服务异常。归 missing 而不是 exists——
      // 假装可用会让下一轮读取失败，而降级至少能给出明确提示。
      return EndpointProbeResult.missing;
  }
}

/// 能力探测缓存（`design/01` §4.1：探测结果**必须缓存 60 s**）。
class RealtimeCapabilityCache {
  RealtimeCapabilityCache({this.ttl = const Duration(seconds: 60)});

  final Duration ttl;

  RealtimePullCapability? _capability;
  DateTime? _cachedAt;

  RealtimePullCapability? read(DateTime now) {
    final cachedAt = _cachedAt;
    if (_capability == null || cachedAt == null) return null;
    if (now.difference(cachedAt) >= ttl) return null;
    return _capability;
  }

  void write(RealtimePullCapability capability, DateTime now) {
    _capability = capability;
    _cachedAt = now;
  }

  void invalidate() {
    _capability = null;
    _cachedAt = null;
  }
}

/// 能力对应的错误分类（`design/01` §8）。
///
/// `history` → 无错误；`currentOnly` → `realtimePullDegraded`（必须常驻显示）；
/// `unsupported` → `realtimePullUnsupported`。
AppError? pullCapabilityError(RealtimePullCapability capability) => switch (capability) {
  RealtimePullCapability.history => null,
  RealtimePullCapability.currentOnly => AppError(
    AppErrorKind.realtimePullDegraded,
    describeErrorKind(AppErrorKind.realtimePullDegraded),
  ),
  RealtimePullCapability.unsupported => AppError(
    AppErrorKind.realtimePullUnsupported,
    describeErrorKind(AppErrorKind.realtimePullUnsupported),
  ),
};

// ---------------------------------------------------------------------------
// 集消歧兜底（`design/01` §4.1 的「处置（两层）」）
// ---------------------------------------------------------------------------

/// `episodeId` 的来源，写入 `raw['_episodeIdSource']` 以便诊断。
enum EpisodeIdSource {
  /// 安卓侧直接提供了 `episodeId`（哈希）。**首选**。
  field,

  /// 用 `episodeName` 兜底（旧安卓 / 第三方服务端）。
  episodeName,

  /// 两者都没有 → 该条**不参与合并**（宁可不合，不可错合）。
  none,
}

/// 集消歧裁决结果。
class EpisodeIdResolution {
  const EpisodeIdResolution({required this.episodeId, required this.source});

  final String episodeId;
  final EpisodeIdSource source;

  /// 是否可以参与合并（`source == none` 时不可）。
  bool get mergeable => source != EpisodeIdSource.none;
}

/// 裁决一条记录的集标识（`design/01` §4.1）。
///
/// **优先级**：安卓的 `episodeId` 字段 > `episodeName` 兜底 > 不合并。
///
/// 为什么 `episodeId` 存在时**不得**被 `episodeName` 覆盖：安卓侧算的是
/// `episodeUrl` 的 SHA-256，PC 用集名会让同名的两条线路（“第01集”出现两次）
/// 重新塌缩——那正是这个字段要解决的问题。
EpisodeIdResolution resolveEpisodeId({
  required String? episodeIdField,
  required String? episodeName,
}) {
  final fromField = (episodeIdField ?? '').trim();
  if (fromField.isNotEmpty) {
    return EpisodeIdResolution(
      episodeId: fromField,
      source: EpisodeIdSource.field,
    );
  }
  final fromName = (episodeName ?? '').trim();
  if (fromName.isNotEmpty) {
    return EpisodeIdResolution(
      episodeId: fromName,
      source: EpisodeIdSource.episodeName,
    );
  }
  return const EpisodeIdResolution(
    episodeId: '',
    source: EpisodeIdSource.none,
  );
}

// ---------------------------------------------------------------------------
// 分集/设置同步范围（`design/01` §5.1）
// ---------------------------------------------------------------------------

/// 实时同步下**参与推送**的白名单（`design/01` §5.1）。
///
/// 是 Phase 5 `pcSettingsWhitelist` 的**超集**：Phase 5 的键必须保留，
/// 否则手动推送路径会静默丢键。
const List<String> realtimeSettingsWhitelist = [
  'tmdb_enabled',
  'tmdb_config',
  'tmdb_model',
  'ai_config',
  'ai_title_extraction',
  'ai_ad_detection',
];

/// 含凭据的键（`design/01` §5.1）：实时同步下**默认不参与**；
/// 用户显式开启 `settingsEnabled` 时 UI 必须警告「明文 HTTP 传输」。
const Set<String> realtimeSensitiveSettingsKeys = {'tmdb_config', 'ai_config'};

/// 「安卓有、PC 无」的键（`design/01` §5.2 注）：
/// 留在白名单内（推送时不丢）但**不落库**，与「未授权同步」区分开。
const Set<String> realtimeUnsupportedSettingsKeys = {
  'tmdb_model',
  'ai_title_extraction',
  'ai_ad_detection',
};

/// 判断某个设置键在当前开关下是否参与实时同步。
///
/// [settingsEnabled] 为 false 时含凭据项被排除（P1：默认关闭）。
bool realtimeIncludesSetting(String key, {required bool settingsEnabled}) {
  if (!realtimeSettingsWhitelist.contains(key)) return false;
  if (realtimeSensitiveSettingsKeys.contains(key)) return settingsEnabled;
  return true;
}

/// 把一批设置键分区（`design/01` §5.2 注：`unsupportedKeys` 与
/// `skippedKeys` **互斥**）。
class RealtimeSettingPartition {
  const RealtimeSettingPartition({
    required this.supported,
    required this.unsupportedKeys,
    required this.skippedKeys,
  });

  /// 会落库的键。
  final List<String> supported;

  /// 白名单内但 PC 不支持落库的键（推送时不丢，披露时区分）。
  final List<String> unsupportedKeys;

  /// 白名单外的键。
  final List<String> skippedKeys;
}

/// 按白名单与「PC 不支持」集合给设置键分区（`design/01` §5.2）。
RealtimeSettingPartition partitionRealtimeSettings(
  Iterable<String> keys, {
  required bool settingsEnabled,
}) {
  final supported = <String>[];
  final unsupported = <String>[];
  final skipped = <String>[];
  for (final key in keys) {
    if (!realtimeSettingsWhitelist.contains(key)) {
      skipped.add(key);
      continue;
    }
    if (realtimeSensitiveSettingsKeys.contains(key) && !settingsEnabled) {
      skipped.add(key);
      continue;
    }
    if (realtimeUnsupportedSettingsKeys.contains(key)) {
      unsupported.add(key);
      continue;
    }
    supported.add(key);
  }
  return RealtimeSettingPartition(
    supported: supported,
    unsupportedKeys: unsupported,
    skippedKeys: skipped,
  );
}

// ---------------------------------------------------------------------------
// 轮询站点排序（`design/01` §3.1）
// ---------------------------------------------------------------------------

/// 选出一轮要轮询的站点：优先「最近活跃」，其余按传入顺序补齐。
///
/// [recentlyActive] 是最近有播放/同步活动的 siteKey（最新在前）；
/// [known] 是全部已知站点。返回去重后的清单，长度不超过 [limit]。
///
/// 为什么「最近活跃优先」是必要的：站点上百时只有少数几个是用户真在用的，
/// 按字母序取前 20 个几乎必然全是无关站点（`design/01` §3.1、R2）。
List<String> prioritizePollSites({
  required List<String> recentlyActive,
  required List<String> known,
  int limit = realtimeDefaultSiteLimit,
}) {
  if (limit <= 0) return const [];
  final result = <String>[];
  final seen = <String>{};
  for (final key in [...recentlyActive, ...known]) {
    if (key.isEmpty) continue;
    if (!seen.add(key)) continue;
    result.add(key);
    if (result.length >= limit) break;
  }
  return result;
}

// ---------------------------------------------------------------------------
// 路径 A 的记录映射（`design/01` §4.1，含 2026-10-17 的阻塞性发现）
// ---------------------------------------------------------------------------

/// `updatedAt` 的取值来源（`design/01` §4.1「阻塞性发现」）。
///
/// 实测（设备 `192.168.50.3:5561`）：`/api/playback/history` 的响应里
/// **没有** `createTime` / `updatedAt`，只有 `timestamp`——而 `timestamp`
/// 是「这份 JSON 何时生成」（`PlaybackRecord` 构造器里
/// `System.currentTimeMillis()`），**不是**「这条记录何时更新」。
///
/// 按优先级探测，并留痕来源，让降级可见（P5）。
enum UpdatedAtSource {
  /// 响应直接给了 `updatedAt`（安卓侧修复后的形态，或第三方服务端）。
  updatedAt,

  /// 响应给了 `createTime`（安卓 `History` 的落库时间）。
  createTime,

  /// 只有 `timestamp`（响应生成时刻）——**不可靠**，必须披露。
  timestamp,

  /// 三个都没有 → 无法判定新旧。
  none,
}

/// `updatedAt` 的裁决结果。
class UpdatedAtResolution {
  const UpdatedAtResolution({required this.value, required this.source});

  /// 解析出的毫秒时间戳（[UpdatedAtSource.none] 时为 0）。
  final int value;
  final UpdatedAtSource source;

  /// 是否可用于「旧不覆盖新」的比较。
  ///
  /// **只有 [UpdatedAtSource.timestamp] 与 [UpdatedAtSource.none] 不可靠**：
  /// 前者是响应生成时刻（每轮都变，恒「更新」），后者干脆没有。
  bool get isReliable =>
      source == UpdatedAtSource.updatedAt || source == UpdatedAtSource.createTime;

  /// 是否应披露降级。
  bool get isDegraded => !isReliable;
}

/// 解析一条记录的时间戳（`design/01` §4.1「阻塞性发现」的处置第 1 条）。
///
/// 优先级：`updatedAt` → `createTime` → `timestamp`。
///
/// **为什么不能只用 `timestamp`**：实测同一次响应里 4 条记录的 `timestamp`
/// 全部落在 30 ms 内，而它们库里真实的 `createTime` 跨度 16 小时；间隔 6 s
/// 再请求，每条 `timestamp` 都前进了 ≈ 6 s。用它当 `updatedAt` 会让
/// `incoming.updatedAt > local.updatedAt` **恒成立** → 每轮全量 upsert，
/// 永不幂等，且游标每次跳到「现在」。
UpdatedAtResolution resolveUpdatedAt(Map<String, Object?> record) {
  int? pick(String key) {
    final value = record[key];
    if (value is int) return value > 0 ? value : null;
    if (value is String) {
      final parsed = int.tryParse(value.trim());
      return parsed != null && parsed > 0 ? parsed : null;
    }
    return null;
  }

  final updatedAt = pick('updatedAt');
  if (updatedAt != null) {
    return UpdatedAtResolution(value: updatedAt, source: UpdatedAtSource.updatedAt);
  }
  final createTime = pick('createTime');
  if (createTime != null) {
    return UpdatedAtResolution(value: createTime, source: UpdatedAtSource.createTime);
  }
  final timestamp = pick('timestamp');
  if (timestamp != null) {
    return UpdatedAtResolution(value: timestamp, source: UpdatedAtSource.timestamp);
  }
  return const UpdatedAtResolution(value: 0, source: UpdatedAtSource.none);
}

/// 内容是否等价（`design/01` §4.1「阻塞性发现」的处置第 2 条）。
///
/// **为什么必须有它**：时间戳不可靠时，幂等不能只靠 `updatedAt` 判等。
/// 只要「进度/时长/完播」三项全等，就认为这条记录没有实质变化 → skip。
///
/// 这三项是**用户可见的进度语义**：位置、总时长、是否看完。
/// 不含 `vodName`/`vodPic` 等展示字段——它们变化不构成「新进度」。
bool isSameProgress({
  required int positionMsA,
  required int durationMsA,
  required bool completedA,
  required int positionMsB,
  required int durationMsB,
  required bool completedB,
}) =>
    positionMsA == positionMsB &&
    durationMsA == durationMsB &&
    completedA == completedB;

/// 时间戳不可靠时，是否应跳过这条记录（保住幂等）。
///
/// 仅当**本地已存在**且**进度内容等价**时跳过。
/// 本地不存在时仍要 insert（否则首次同步会丢记录）。
bool shouldSkipAsUnchanged({
  required bool localExists,
  required bool sameProgress,
}) => localExists && sameProgress;

/// 路径 A 一轮拉取的降级状态汇总（供 UI 常驻披露）。
class RealtimePullDegradation {
  const RealtimePullDegradation({
    required this.capability,
    required this.updatedAtSource,
    required this.recordCount,
    required this.skippedAsUnchanged,
  });

  const RealtimePullDegradation.none()
    : capability = RealtimePullCapability.history,
      updatedAtSource = UpdatedAtSource.updatedAt,
      recordCount = 0,
      skippedAsUnchanged = 0;

  /// 端点能力（`history` / `currentOnly` / `unsupported`）。
  final RealtimePullCapability capability;

  /// 本轮记录的 `updatedAt` 来源（取最差的那个）。
  final UpdatedAtSource updatedAtSource;

  final int recordCount;

  /// 因「内容等价」被跳过的条数（时间戳不可靠时的幂等兜底）。
  final int skippedAsUnchanged;

  /// 是否需要常驻披露（`design/01` §4.1 的 P5 要求）。
  bool get needsDisclosure =>
      capability != RealtimePullCapability.history ||
      updatedAtSource != UpdatedAtSource.updatedAt;

  /// 需要披露的错误分类（无需披露时为 `null`）。
  ///
  /// 优先级：端点能力问题 > 时间戳问题——前者更严重（会丢记录），
  /// 后者只是「判定不准」。
  AppError? get disclosureError {
    final capabilityError = pullCapabilityError(capability);
    if (capabilityError != null) return capabilityError;
    if (updatedAtSource == UpdatedAtSource.timestamp) {
      return AppError(
        AppErrorKind.realtimePullTimestampUnreliable,
        describeErrorKind(AppErrorKind.realtimePullTimestampUnreliable),
      );
    }
    return null;
  }

  String describe() =>
      'pull(capability=${capability.name} updatedAt=${updatedAtSource.name} '
      'records=$recordCount skippedUnchanged=$skippedAsUnchanged '
      'disclosure=$needsDisclosure)';
}

// ---------------------------------------------------------------------------
// 路径 B：PC 拉取端点（`design/01` §3.2.2）
// ---------------------------------------------------------------------------

/// 路径 B 的游标上限（`design/01` §3.2.2：`limit` 默认 100、上限 500）。
const int realtimeSyncDefaultLimit = 100;
const int realtimeSyncMaxLimit = 500;

/// 解析 `X-WebHTV-Since` / `?since=` 游标（`design/01` §3.2.2）。
///
/// 游标是**单调递增的 sequence 整数**（`design/00` §3.1 契约 9），不是时间戳。
/// 空/缺省 = `0`；非法（非数字或负数）→ `null`，调用方必须回 **400**
/// （对齐 Go 参考实现：`Invalid X-WebHTV-Since cursor`）。
///
/// **为什么非法游标必须报错而不是回落 0**：回落到 0 会让安卓把全部历史
/// 再拉一遍。数据不会错（幂等合并），但用户会看到一次莫名的全量传输；
/// 而 400 能让它立刻发现自己的游标坏了。
int? parseSyncCursor(String? raw) {
  if (raw == null) return 0;
  final text = raw.trim();
  if (text.isEmpty) return 0;
  final parsed = int.tryParse(text);
  if (parsed == null || parsed < 0) return null;
  return parsed;
}

/// 解析 `limit`（`design/01` §3.2.2：默认 100、上限 500）。
///
/// 非法值回落默认而不是报 400——与游标不同：limit 只是「一次要多少」，
/// 给个坏值不该让整次拉取失败（对齐安卓 `PlaybackRemoteSyncPayload` 的宽容）。
int parseSyncLimit(String? raw) {
  if (raw == null) return realtimeSyncDefaultLimit;
  final parsed = int.tryParse(raw.trim());
  if (parsed == null || parsed <= 0) return realtimeSyncDefaultLimit;
  return parsed > realtimeSyncMaxLimit ? realtimeSyncMaxLimit : parsed;
}

/// 路径 B 的鉴权结论（`design/01` §3.2.2）。
class SyncPullAuthCheck {
  const SyncPullAuthCheck({required this.allowed, this.status = 403, this.message});

  const SyncPullAuthCheck.ok() : allowed = true, status = 200, message = null;

  final bool allowed;
  final int status;
  final String? message;
}

/// 校验路径 B 的鉴权（`design/01` §3.2.2）。
///
/// 规则（按顺序）：
/// 1. 「实时推送」未开启 → `403`（P1：端点只在显式开启后返回数据）；
/// 2. 配置了 token 时：请求头 token 必须匹配，否则 `403`；
/// 3. 未配置 token 时：只允许 `uuid` 白名单内的对端（复用 Phase 5
///    `isPeerAuthorized`）。
///
/// - **为什么 token 与白名单是「或」而不是「与」**：token 是给
/// 「PC 与安卓不在同一网段 / 用户想显式带凭据」的场景；白名单是局域网
/// 默认形态。两者都要求会让默认配置无法工作。
///
/// [disabledMessage] 用于区分端点：路径 B 拉数据时叫「实时推送未开启」，
/// 而身份解析/能力声明不返回播放数据，文案必须不同（否则用户会看到
/// 「实时推送未开启」却想不通为何已经开了）。
SyncPullAuthCheck validateSyncPullAuth({
  required bool pushEnabled,
  required String? configuredToken,
  required String? providedToken,
  required bool peerAuthorized,
  String? disabledMessage,
}) {
  if (!pushEnabled) {
    return SyncPullAuthCheck(
      allowed: false,
      message:
          disabledMessage ?? '实时推送未开启（请在 WebHTV PC 的「实时同步」中开启）',
    );
  }
  final expected = (configuredToken ?? '').trim();
  if (expected.isNotEmpty) {
    if ((providedToken ?? '').trim() != expected) {
      return const SyncPullAuthCheck(allowed: false, message: 'token 不匹配');
    }
    return const SyncPullAuthCheck.ok();
  }
  if (!peerAuthorized) {
    return const SyncPullAuthCheck(
      allowed: false,
      message: '对端未授权（未配置 token 时只允许已授权设备）',
    );
  }
  return const SyncPullAuthCheck.ok();
}

/// 一批待推给安卓的变更（`design/01` §3.2.2 的响应素材）。
class SyncPullBatch {
  const SyncPullBatch({
    required this.items,
    required this.deletions,
    required this.nextSince,
    required this.hasMore,
  });

  /// upsert 条目（`PlaybackProgressInput` 兼容 JSON）。
  final List<Map<String, Object?>> items;

  /// 删除条目（`{historyKey, deletedAt}`）。
  final List<Map<String, Object?>> deletions;

  /// 本批最大游标。
  final int nextSince;

  /// 是否还有未返回的变更。
  final bool hasMore;

  int get total => items.length + deletions.length;

  /// 转成安卓解析器接受的响应体（`design/01` §3.2.2 的兼容点）。
  ///
  /// 用**主名**（`nextSince`/`items`/`deleted`）而不是别名：别名是给
  /// 「服务端可能用别的名字」的容错，PC 自己实现时用主名最清晰。
  Map<String, Object?> toJson() => {
    'nextSince': nextSince,
    'items': items,
    if (deletions.isNotEmpty) 'deleted': deletions,
    'hasMore': hasMore,
  };

  String describe() =>
      'pull(items=${items.length} deleted=${deletions.length} '
      'nextSince=$nextSince hasMore=$hasMore)';
}

/// 按游标切出一批变更（`design/01` §3.2.2 的游标语义）。
///
/// - [since] 为 `0`（空游标）→ 返回**最近 N 条**（不做全量，见 P2）；
/// - [since] 有值 → 只返回 `updatedAt > since` 的记录；
/// - `nextSince` = 本批最大 `updatedAt`（空批时保持 `since`，**不回退**）；
/// - 删除从 [deletions] 里取 `deletedAt > since` 的。
///
/// **不推进任何本地游标**——游标由安卓侧保存（`RemoteSyncConfig.cursors`）。
SyncPullBatch buildSyncPullBatch({
  required List<SyncHistoryItem> history,
  required List<({String historyKey, int deletedAt})> deletions,
  required int since,
  required int limit,
}) {
  final effectiveLimit = limit <= 0 ? realtimeSyncDefaultLimit : limit;

  final upserts = history.where((item) => item.updatedAt > since).toList()
    ..sort((a, b) => a.updatedAt.compareTo(b.updatedAt));
  final tombstones = deletions.where((d) => d.deletedAt > since).toList()
    ..sort((a, b) => a.deletedAt.compareTo(b.deletedAt));

  // 空游标（首次同步）时只给最近 N 条：P2「增量优先，全量必须显式」。
  final isFirstSync = since <= 0;

  final selectedItems = <SyncHistoryItem>[];
  final selectedDeletions = <({String historyKey, int deletedAt})>[];
  var remaining = effectiveLimit;

  for (final item in upserts) {
    if (remaining <= 0) break;
    selectedItems.add(item);
    remaining--;
  }
  for (final tombstone in tombstones) {
    if (remaining <= 0) break;
    selectedDeletions.add(tombstone);
    remaining--;
  }

  // nextSince 取本批最大游标；空批时**保持 since**（回退会让安卓重复拉取）。
  var nextSince = since;
  for (final item in selectedItems) {
    if (item.updatedAt > nextSince) nextSince = item.updatedAt;
  }
  for (final tombstone in selectedDeletions) {
    if (tombstone.deletedAt > nextSince) nextSince = tombstone.deletedAt;
  }

  final hasMore =
      upserts.length > selectedItems.length ||
      tombstones.length > selectedDeletions.length;

  return SyncPullBatch(
    items: selectedItems.map(_historyToProgressInput).toList(growable: false),
    deletions: selectedDeletions
        .map((d) => <String, Object?>{
              'historyKey': d.historyKey,
              'deletedAt': d.deletedAt,
            })
        .toList(growable: false),
    nextSince: nextSince,
    hasMore: hasMore || (isFirstSync && hasMore),
  );
}

/// 把一条本地历史映射成安卓 `PlaybackProgressInput` 兼容 JSON
/// （`design/01` §3.2.2 的字段别名表）。
///
/// 与 `SyncHistoryItem.toAndroidJson()` 的区别：后者是
/// **`History` 形态**（给 `/action?do=sync` 用，`key` 带 `@@@` 分隔），
/// 这里是 **`PlaybackProgressInput` 形态**（给 `/api/playback/sync` 用，
/// 用 `historyKey` + `updatedAt`）。
Map<String, Object?> _historyToProgressInput(SyncHistoryItem item) => {
  'historyKey': item.historyKey,
  'siteKey': item.siteKey,
  'vodId': item.vodId,
  'vodName': item.vodName,
  if (item.vodPic != null) 'vodPic': item.vodPic,
  'flag': item.flag,
  'episodeName': item.episodeName,
  'episodeId': item.episodeId,
  'positionMs': item.positionMs,
  'durationMs': item.durationMs,
  // PC 侧一律按自己的公式重算（`design/03` §4.2），不采信同步来的值。
  'completed': item.completed,
  'speed': 1.0,
  // 关键：`updatedAt` 必须显式给。安卓的 `PlaybackProgressWriter`
  // 用它做 `setCreateTime` 与冲突裁决（`PlaybackProgressWriter.java:200,227`）。
  'updatedAt': item.updatedAt,
};
