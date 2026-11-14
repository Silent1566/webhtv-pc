/// Phase 7 · 实时引擎（`docs/phase7/design/01` §4/§6.3、`design/02` §3–§5、
/// `design/04` §3.1 的 `phase7_realtime_engine_test.dart`）。
///
/// ## 假时钟
///
/// 引擎的定时器经 [ManualScheduler] 注入：它**不创建任何真实 `Timer`**，
/// 只把回调排进一个列表，由测试 `advance()` 手动触发。这样既避开了
/// 「fake-async zone 与真实 I/O 跨 zone 挂死」的老问题，也让
/// 「退避到第几次」「恢复后立刻补一轮」这类时序断言变成确定性的。
///
/// ## G12：用例结束时活动定时器数 = 0
///
/// 每个 group 的 `tearDown` 都断言一次 `engine.activeTimerCount == 0`
/// （`design/04` §6 G12）。这条断言会把「忘了 cancel」的泄漏变成测试失败，
/// 而不是等到用户机器上出现幽灵定时器。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/android_sync.dart';
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/core/realtime_sync.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/realtime_sync_engine.dart';

// ---------------------------------------------------------------------------
// 测试替身
// ---------------------------------------------------------------------------

/// 手动调度器：记录待触发回调，由测试逐个触发。
class ManualScheduler {
  final List<PendingFire> pending = [];

  /// 每次排程的延迟（秒），按顺序记录——退避断言直接读它。
  final List<int> delaysSeconds = [];

  RealtimeTimerHandle call(Duration delay, void Function() onFire) {
    final handle = PendingFire(delay, onFire);
    pending.add(handle);
    delaysSeconds.add(delay.inSeconds);
    return handle;
  }

  /// 最近一次排程的延迟（秒）。
  int get lastDelaySeconds => delaysSeconds.isEmpty ? -1 : delaysSeconds.last;

  /// 当前仍活动的回调数。
  int get activeCount => pending.where((item) => item.isActive).length;

  /// 触发最早的一个待触发回调（并让它离开队列）。
  ///
  /// 返回是否真的触发了。
  bool fireNext() {
    for (final item in List<PendingFire>.of(pending)) {
      if (!item.isActive) continue;
      item.fire();
      return true;
    }
    return false;
  }

  /// 按延迟值触发（用于区分轮询与心跳：两者周期不同）。
  ///
  /// **为什么不用位置**：引擎每次触发后会重新排程，新句柄追加在尾部，
  /// 位置不稳定；而延迟值本来就是可读的语义（60 s = 轮询，30 s = 心跳）。
  bool fireByDelay(int seconds) {
    for (final item in List<PendingFire>.of(pending)) {
      if (!item.isActive || item.delay.inSeconds != seconds) continue;
      item.fire();
      return true;
    }
    return false;
  }

  /// 是否有指定延迟的待触发回调。
  bool hasDelay(int seconds) =>
      pending.any((item) => item.isActive && item.delay.inSeconds == seconds);

  /// 触发全部当前待触发的回调（**快照**：新排程的不会在本轮触发）。
  int fireAll() {
    var count = 0;
    for (final item in List<PendingFire>.of(pending)) {
      if (!item.isActive) continue;
      item.fire();
      count++;
    }
    return count;
  }

  void clear() {
    for (final item in pending) {
      item.cancel();
    }
    pending.clear();
    delaysSeconds.clear();
  }
}

class PendingFire implements RealtimeTimerHandle {
  PendingFire(this.delay, this._onFire);

  final Duration delay;
  final void Function() _onFire;
  bool _active = true;

  @override
  bool get isActive => _active;

  @override
  void cancel() => _active = false;

  void fire() {
    if (!_active) return;
    _active = false;
    _onFire();
  }
}

SyncHistoryItem item({
  String siteKey = 'CupFox',
  String vodId = '/v/1',
  String episodeId = 'e1',
  int positionMs = 1000,
  int durationMs = 10000,
  int updatedAt = 1000,
}) => SyncHistoryItem(
  siteKey: siteKey,
  vodId: vodId,
  vodName: '扫毒风暴',
  flag: '线路1',
  episodeName: '第01集',
  episodeId: episodeId,
  positionMs: positionMs,
  durationMs: durationMs,
  updatedAt: updatedAt,
);

/// 引擎 I/O 替身：所有行为由测试逐项设定。
class FakeHost {
  FakeHost({
    this.deviceBase = 'http://127.0.0.1:19978',
    this.siteKeys = const ['CupFox'],
  });

  String? deviceBase;
  List<String> siteKeys;

  RealtimePullCapability capability = RealtimePullCapability.history;

  /// 每个站点的读取结果（缺省为空结果）。
  final Map<String, RealtimeSiteReadResult> reads = {};

  /// 每个站点抛出的异常（优先于 [reads]）。
  final Map<String, Object> readErrors = {};

  /// 每个站点的合并统计（缺省把条目全算 applied）。
  final Map<String, SyncMergeStats> mergeStats = {};

  /// 能力探测抛出的异常。
  Object? probeError;

  /// 心跳结果队列（空时返回可达）。
  final List<RealtimeHeartbeatProbe> heartbeats = [];

  final List<String> readCalls = [];
  final List<String> heartbeatCalls = [];
  int probeCalls = 0;
  final List<List<SyncHistoryItem>> merged = [];

  /// 这一轮要归属的源：测试按需给出，缺省为空串（不归属）。
  ///
  /// 归属是设备级的（安卓按当前激活配置查库），所以每轮只解析一次。
  String resolvedSourceKey = '';

  /// 解析归属的次数：用来断言「整轮只问一次设备」。
  int resolveSourceKeyCalls = 0;

  /// 每次合并时收到的来源，按调用顺序记录。
  final List<String> mergedSourceKeys = [];
  Map<String, SyncHistoryItem> localByMatchKey = const {};

/// 用真实日历毫秒值（引擎只把它当"现在"打点）。
  int nowMs = 1_700_000_000_000;
  DateTime Function() get clock =>
      () => DateTime.fromMillisecondsSinceEpoch(nowMs);

  RealtimeEngineHost get port => RealtimeEngineHost(
    deviceBase: () => deviceBase,
    siteKeys: ({required bool all}) => siteKeys,
    probeCapability: (base) async {
      probeCalls++;
      final failure = probeError;
      if (failure != null) throw failure;
      return capability;
    },
    readSite:
        ({
          required String deviceBase,
          required String siteKey,
          required RealtimePullCapability capability,
          required Map<String, SyncHistoryItem> localByMatchKey,
        }) async {
          readCalls.add(siteKey);
          final failure = readErrors[siteKey];
          if (failure != null) throw failure;
          return reads[siteKey] ??
              RealtimeSiteReadResult(
                items: const [],
                endpoint: capability,
              );
        },
    resolveSourceKey: ({required String deviceBase}) async {
      resolveSourceKeyCalls++;
      return resolvedSourceKey;
    },
    mergeHistory: (items, {required String sourceKey}) async {
      merged.add(items);
      mergedSourceKeys.add(sourceKey);
      final stats = mergeStats[items.first.siteKey];
      if (stats != null) return stats;
      return SyncMergeStats(
        applied: items.length,
        skipped: 0,
        failed: 0,
        total: items.length,
      );
    },
    heartbeat: (base) async {
      heartbeatCalls.add(base);
      if (heartbeats.isEmpty) {
        return const RealtimeHeartbeatProbe(state: RealtimePeerState.ok);
      }
      return heartbeats.removeAt(0);
    },
    localHistoryByMatchKey: () => localByMatchKey,
  );
}

/// 等待引擎内部 `unawaited` 的异步链跑完。
///
/// 引擎的定时器回调是 `unawaited(_tick())`，`fireNext()` 同步返回时
/// 内部 `await` 还没走完，必须让出若干次微任务/事件循环。
Future<void> settle() async {
  for (var i = 0; i < 12; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

RealtimeSyncEngine buildEngine(
  FakeHost host,
  ManualScheduler scheduler, {
  RealtimeSyncSwitches switches = const RealtimeSyncSwitches(
    enabled: true,
    pullEnabled: true,
  ),
  int pullCursorMs = 0,
}) => RealtimeSyncEngine(
  log: LogService(),
  host: host.port,
  scheduler: scheduler.call,
  clock: host.clock,
  switches: switches,
  pullCursorMs: pullCursorMs,
);

void main() {
  late FakeHost host;
  late ManualScheduler scheduler;
  late RealtimeSyncEngine engine;

  setUp(() {
    host = FakeHost();
    scheduler = ManualScheduler();
    engine = buildEngine(host, scheduler);
  });

  tearDown(() {
    engine.stop();
    scheduler.clear();
    // G12：用例结束时活动定时器必须为 0。
    expect(engine.activeTimerCount, 0, reason: 'G12：引擎停止后不得残留定时器');
  });

  group('定时器编排（design/01 §6、G12）', () {
    test('E1 · 开启拉取 → 轮询与心跳各一个定时器', () {
      engine.start();
      expect(engine.activeTimerCount, 2);
      expect(engine.snapshot().pollScheduled, isTrue);
      expect(engine.snapshot().heartbeatScheduled, isTrue);
    });

    test('E2 · 总开关关闭 → 不排任何定时器', () {
      final off = RealtimeSyncSwitches(enabled: false, pullEnabled: true);
      final local = buildEngine(host, scheduler, switches: off);
      local.start();
      expect(local.activeTimerCount, 0);
      local.stop();
    });

    test('E3 · 只开推送 → 只有心跳（路径 B 也要知道安卓在不在）', () {
      final pushOnly = RealtimeSyncSwitches(
        enabled: true,
        pullEnabled: false,
        pushEnabled: true,
      );
      final local = buildEngine(host, scheduler, switches: pushOnly);
      local.start();
      expect(local.snapshot().pollScheduled, isFalse);
      expect(local.snapshot().heartbeatScheduled, isTrue);
      local.stop();
    });

    test('E4 · 未接入设备（deviceBase 为空）→ 不排定时器（空跑只刷日志）', () {
      host.deviceBase = null;
      engine.start();
      expect(engine.activeTimerCount, 0);
    });

    test('E5 · 关闭拉取后轮询定时器被取消，心跳保留', () {
      engine.start();
      engine.applySwitches(
        const RealtimeSyncSwitches(enabled: true, pushEnabled: true),
      );
      expect(engine.snapshot().pollScheduled, isFalse);
      expect(engine.snapshot().heartbeatScheduled, isTrue);
    });

    test('E6 · 总开关关闭但保留子开关值（下次开启沿用）', () {
      engine.start();
      engine.applySwitches(
        const RealtimeSyncSwitches(
          enabled: false,
          pullEnabled: true,
          intervalSeconds: 30,
        ),
      );
      expect(engine.activeTimerCount, 0);
      expect(engine.switches.pullEnabled, isTrue);
      expect(engine.switches.intervalSeconds, 30);
    });

    test('E7 · stop() 后再触发残留回调不产生任何请求（防僵尸）', () async {
      engine.start();
      final stale = List.of(scheduler.pending);
      engine.stop();
      // 直接调用残留回调（模拟「已 cancel 但被外部 fire」的极端情况）。
      for (final pending in stale) {
        pending.fire();
      }
      await settle();
      expect(host.readCalls, isEmpty);
      expect(host.heartbeatCalls, isEmpty);
    });

    test('E8 · 定时器触发后按配置周期重新排程', () async {
      engine.start();
      scheduler.delaysSeconds.clear();
      expect(scheduler.fireNext(), isTrue); // 触发轮询
      await settle();
      expect(scheduler.lastDelaySeconds, realtimeDefaultIntervalSeconds);
    });
  });

  group('心跳 → 轮询联动（design/02 §3.3、§5.2）', () {
    test('E9 · 心跳失败 → 暂停轮询（不可达时轮询全是超时）', () async {
      host.heartbeats.add(
        const RealtimeHeartbeatProbe(
          state: RealtimePeerState.serviceStopped,
        ),
      );
      engine.start();
      await engine.heartbeatNow();

      expect(engine.snapshot().pollPaused, isTrue);
      expect(engine.snapshot().pollScheduled, isFalse, reason: '暂停期间不排轮询');
      expect(engine.snapshot().peerState, RealtimePeerState.serviceStopped);
    });

    test('E10 · 暂停期间定时器触发也不发读取请求', () async {
      host.heartbeats.add(
        const RealtimeHeartbeatProbe(
          state: RealtimePeerState.networkUnreachable,
        ),
      );
      engine.start();
      await engine.heartbeatNow();
      host.readCalls.clear();

      // 引擎在暂停时已 cancel；即便强推一轮也不该发请求。
      final result = await engine.pollNow();
      expect(result, isNull);
      expect(host.readCalls, isEmpty);
    });

    test('E11 · 心跳恢复 → 立刻补一轮轮询（断线期间的增量）', () async {
      host.heartbeats.addAll([
        const RealtimeHeartbeatProbe(
          state: RealtimePeerState.serviceStopped,
        ),
        const RealtimeHeartbeatProbe(state: RealtimePeerState.ok),
      ]);
      host.reads['CupFox'] = RealtimeSiteReadResult(
        items: [item(updatedAt: 5000)],
      );
      engine.start();

      await engine.heartbeatNow(); // 失败
      expect(engine.snapshot().pollPaused, isTrue);

      final recovered = await engine.heartbeatNow(); // 恢复
      expect(recovered!.triggeredPoll, isTrue);
      expect(host.readCalls, ['CupFox'], reason: '恢复后必须补一轮');
      expect(engine.snapshot().pollPaused, isFalse);
      expect(engine.snapshot().pollFailures, 0);
      expect(engine.snapshot().pollScheduled, isTrue);
    });

    test('E12 · 恢复时若拉取方向已停止，不补跑（403 重试无意义）', () async {
      host.readErrors['CupFox'] = AppError(
        AppErrorKind.syncDisabled,
        '对端未开启服务端',
        statusCode: 403,
      );
      host.heartbeats.add(
        const RealtimeHeartbeatProbe(
          state: RealtimePeerState.serviceStopped,
        ),
      );
      engine.start();
      await engine.pollNow(); // → 403，方向停止
      expect(engine.snapshot().pollStopped, isTrue);

      await engine.heartbeatNow();
      host.readCalls.clear();
      final recovered = await engine.heartbeatNow(); // 假设心跳恢复
      expect(recovered!.triggeredPoll, isFalse);
      expect(host.readCalls, isEmpty);
    });

    test('E13 · 连续 2 次失败 → 唤醒阶梯到 L1（touch /manage/session）', () async {
      host.heartbeats.addAll([
        const RealtimeHeartbeatProbe(
          state: RealtimePeerState.serviceStopped,
        ),
        const RealtimeHeartbeatProbe(
          state: RealtimePeerState.serviceStopped,
        ),
      ]);
      engine.start();
      await engine.heartbeatNow();
      expect(engine.snapshot().wakeLevel, RealtimeWakeLevel.none, reason: '首次失败不动');
      final second = await engine.heartbeatNow();
      expect(second!.wakeLevel, RealtimeWakeLevel.touchManage);
      expect(
        wakeLevelSendsRequest(second.wakeLevel),
        isTrue,
        reason: 'L1 是唯一允许发请求的轻量级',
      );
    });

    test('E14 · backgroundGuide 原样透传（PC 不得自造文案）', () async {
      host.heartbeats.add(
        const RealtimeHeartbeatProbe(
          state: RealtimePeerState.peerFrozen,
          session: {
            'backgroundSettingsNeeded': true,
            'backgroundGuide': '请在 设置→电池→应用启动管理 中允许后台运行',
          },
        ),
      );
      engine.start();
      await engine.heartbeatNow();
      expect(
        engine.snapshot().backgroundGuide,
        '请在 设置→电池→应用启动管理 中允许后台运行',
      );
    });

    test('E15 · 冻结态走 L4（提示点亮屏幕），不是「网络不可达」', () async {
      host.heartbeats.addAll([
        const RealtimeHeartbeatProbe(state: RealtimePeerState.peerFrozen),
        const RealtimeHeartbeatProbe(state: RealtimePeerState.peerFrozen),
      ]);
      engine.start();
      await engine.heartbeatNow(); // 首次失败 → L0
      await engine.heartbeatNow(); // 第 2 次 → L4
      final snapshot = engine.snapshot();
      expect(snapshot.peerState, RealtimePeerState.peerFrozen);
      expect(snapshot.wakeLevel, RealtimeWakeLevel.promptWakeScreen);
      expect(
        wakeLevelChangesPeerState(snapshot.wakeLevel),
        isFalse,
        reason: 'L4 仅提示，不得改变安卓侧状态',
      );
    });
  });

  group('失败、退避与停止（design/01 §6.3）', () {
    test('E16 · 403 → 立即停止该方向并清掉轮询定时器', () async {
      host.readErrors['CupFox'] = AppError(
        AppErrorKind.syncDisabled,
        '对端未开启服务端',
        statusCode: 403,
      );
      engine.start();
      final result = await engine.pollNow();

      expect(result!.outcome, RealtimeBatchOutcome.unauthorized);
      expect(engine.snapshot().pollStopped, isTrue);
      expect(engine.snapshot().pollScheduled, isFalse, reason: '重试只会一直 403');
      expect(engine.snapshot().lastError?.kind, AppErrorKind.syncDisabled);
    });

    test('E17 · 403 不涨退避计数（已经不再重试，涨了只会污染 UI）', () async {
      host.readErrors['CupFox'] = AppError(
        AppErrorKind.syncDisabled,
        '未授权',
        statusCode: 403,
      );
      engine.start();
      await engine.pollNow();
      expect(engine.snapshot().pollFailures, 0);
    });

    test('E18 · 网络失败退避 1×/2×/4×（不是恒定周期）', () async {
      host.readErrors['CupFox'] = AppError(
        AppErrorKind.realtimePartialFailure,
        '连接被拒',
        retryable: true,
      );
      engine.start();
      final base = realtimeDefaultIntervalSeconds;

      // 第 1 次失败：退避计数 1 → 仍是 1×。
      expect(scheduler.fireByDelay(base), isTrue, reason: '首轮应按基准周期排程');
      await settle();
      expect(engine.snapshot().pollFailures, 1);
      expect(scheduler.hasDelay(base), isTrue, reason: '1 次失败仍是 1× 周期');

      // 第 2 次失败：2×。
      expect(scheduler.fireByDelay(base), isTrue);
      await settle();
      expect(engine.snapshot().pollFailures, 2);
      expect(scheduler.hasDelay(base * 2), isTrue, reason: '2 次失败应退避到 2×');

      // 第 3 次失败：4×。
      expect(scheduler.fireByDelay(base * 2), isTrue);
      await settle();
      expect(engine.snapshot().pollFailures, 3);
      expect(scheduler.hasDelay(base * 4), isTrue, reason: '3 次失败应退避到 4×');
    });

    test('E19 · 连续 5 次失败 → 暂停自动轮询并置错误', () async {
      host.readErrors['CupFox'] = AppError(
        AppErrorKind.realtimePartialFailure,
        '连接被拒',
        retryable: true,
      );
      engine.start();
      for (var i = 0; i < realtimePauseAfterFailures; i++) {
        await engine.pollNow();
      }
      final snapshot = engine.snapshot();
      expect(snapshot.pollFailures, greaterThanOrEqualTo(realtimePauseAfterFailures));
      expect(snapshot.pollPaused, isTrue);
      expect(snapshot.pollScheduled, isFalse);
      expect(snapshot.lastError, isNotNull);
      expect(snapshot.needsUserAttention, isFalse, reason: '暂停等手动重试，不是停止');
    });

    test('E20 · retryNow() 清计数并立刻跑心跳+轮询', () async {
      host.readErrors['CupFox'] = AppError(
        AppErrorKind.realtimePartialFailure,
        '连接被拒',
        retryable: true,
      );
      engine.start();
      for (var i = 0; i < realtimePauseAfterFailures; i++) {
        await engine.pollNow();
      }
      expect(engine.snapshot().pollPaused, isTrue);

      host.readErrors.clear();
      host.reads['CupFox'] = RealtimeSiteReadResult(items: [item()]);
      await engine.retryNow();

      expect(engine.snapshot().pollFailures, 0);
      expect(engine.snapshot().pollPaused, isFalse);
      expect(host.readCalls, isNotEmpty);
      expect(host.heartbeatCalls, isNotEmpty);
    });

    test('E21 · 404（该站点无记录）不算失败、不参与退避', () async {
      host.reads['CupFox'] = const RealtimeSiteReadResult(
        items: [],
        notFound: true,
        endpoint: RealtimePullCapability.currentOnly,
      );
      engine.start();
      final result = await engine.pollNow();

      expect(result!.outcome, RealtimeBatchOutcome.success);
      expect(engine.snapshot().pollFailures, 0);
      expect(engine.snapshot().lastError, isNull);
    });

    test('E22 · 路径 A 不可用（unsupported）→ 报错误类别而不是「0 条」', () async {
      host.capability = RealtimePullCapability.unsupported;
      engine.start();
      final result = await engine.pollNow();

      expect(result!.outcome, RealtimeBatchOutcome.failure);
      expect(result.error?.kind, AppErrorKind.realtimePullUnsupported);
      expect(host.readCalls, isEmpty, reason: '端点不可用时不该再逐站点空打');
    });
  });

  group('游标推进（design/04 反向验证 #6）', () {
    test('E23 · 成功一轮 → 游标推进到本批最大 updatedAt', () async {
      host.reads['CupFox'] = RealtimeSiteReadResult(
        items: [item(vodId: '/a', updatedAt: 1500), item(vodId: '/b', updatedAt: 2500)],
      );
      engine.start();
      final result = await engine.pollNow();

      expect(result!.outcome, RealtimeBatchOutcome.success);
      expect(result.cursorAdvanced, isTrue);
      expect(result.cursor, 2500);
      expect(engine.cursor, 2500);
    });

    test('E24 · 失败一轮 → 游标**不推进**', () async {
      host.reads['CupFox'] = RealtimeSiteReadResult(
        items: [item(updatedAt: 2500)],
      );
      engine.start();
      await engine.pollNow();
      expect(engine.cursor, 2500);

      host.readErrors['CupFox'] = AppError(
        AppErrorKind.realtimePartialFailure,
        '连接被拒',
        retryable: true,
      );
      host.reads['CupFox'] = RealtimeSiteReadResult(
        items: [item(updatedAt: 9999)],
      );
      await engine.pollNow();
      expect(
        engine.cursor,
        2500,
        reason: '失败时推进游标会让断线期间的增量永久丢失',
      );
    });

    test('E25 · 不可合并的记录不阻止游标推进（但仍计入 failed 明细）', () async {
      // 这是 L3 集成测试抓出来的**真实缺陷**的回归：
      // 「记录本身不可合并」（集名与地址双空、身份键不成段）是**永久性**失败
      // ——下轮、下下轮永远同样结果。若把整轮归为 `partial`，而 `partial`
      // 按 `design/01` §6.3 不推进游标，游标就**永久卡死**，增量语义失效。
      //
      // 正确行为：计入 `failed` 明细并披露（P5），但**照常推进游标**。
      host.reads['CupFox'] = RealtimeSiteReadResult(
        items: [item(updatedAt: 4000)],
        unmergeable: 1,
      );
      engine.start();
      final result = await engine.pollNow();

      expect(result!.outcome, RealtimeBatchOutcome.success);
      expect(result.cursorAdvanced, isTrue, reason: '永久失败不该卡住游标');
      expect(engine.cursor, 4000);
      expect(result.stats.failed, 1, reason: 'P5：不可合并的条数必须披露');
      expect(result.unmergeable, 1);
      expect(result.stats.isConsistent, isTrue);
    });

    test('E26 · 合并阶段（写库）失败算 partial → 游标不推进（暂时性失败可重试）', () async {
      host.reads['CupFox'] = RealtimeSiteReadResult(
        items: [item(updatedAt: 4000)],
      );
      host.mergeStats['CupFox'] = const SyncMergeStats(
        applied: 0,
        skipped: 0,
        failed: 1,
        total: 1,
      );
      engine.start();
      final result = await engine.pollNow();

      expect(result!.outcome, RealtimeBatchOutcome.partial);
      expect(result.cursorAdvanced, isFalse);
      expect(engine.cursor, 0);
    });

    test('E27 · 游标单调不减：空批次保持原值', () async {
      host.reads['CupFox'] = RealtimeSiteReadResult(
        items: [item(updatedAt: 5000)],
      );
      engine.start();
      await engine.pollNow();
      host.reads['CupFox'] = const RealtimeSiteReadResult(items: []);
      final second = await engine.pollNow();
      expect(second!.cursor, 5000);
      expect(second.cursorAdvanced, isFalse);
    });

    test('E28 · resetCursorAndPoll 把游标归零并重跑', () async {
      host.reads['CupFox'] = RealtimeSiteReadResult(
        items: [item(updatedAt: 5000)],
      );
      engine.start();
      await engine.pollNow();
      expect(engine.cursor, 5000);

      host.reads['CupFox'] = const RealtimeSiteReadResult(items: []);
      await engine.resetCursorAndPoll();
      expect(engine.cursor, 0, reason: '空批次时不回填，游标保持被重置后的 0');
    });

    test('E29 · 降级站点被记录（P5 披露「仅能同步正在播放的记录」）', () async {
      host.reads['CupFox'] = RealtimeSiteReadResult(
        items: [item(updatedAt: 1000)],
        endpoint: RealtimePullCapability.currentOnly,
      );
      engine.start();
      final result = await engine.pollNow();
      expect(result!.degradedSites, ['CupFox']);
      expect(engine.snapshot().degradedSites, ['CupFox']);
    });
  });

  group('统计闭合与披露（design/02 §6、P5）', () {
    test('E30 · applied+skipped+failed == total（明细必须闭合）', () async {
      host.reads['CupFox'] = RealtimeSiteReadResult(
        items: [item(vodId: '/a'), item(vodId: '/b')],
        skippedAsUnchanged: 1,
      );
      host.mergeStats['CupFox'] = const SyncMergeStats(
        applied: 1,
        skipped: 1,
        failed: 0,
        total: 2,
      );
      engine.start();
      final result = await engine.pollNow();

      expect(result!.stats.isConsistent, isTrue);
      expect(result.stats.total, 3, reason: '2 条解析成功 + 1 条内容等价跳过');
      expect(result.stats.applied, 1);
      expect(result.stats.skipped, 2);
    });

    test('E31 · 多站点合计（每站点各读一次）', () async {
      host.siteKeys = ['A', 'B', 'C'];
      host.reads['A'] = RealtimeSiteReadResult(items: [item(siteKey: 'A')]);
      host.reads['B'] = RealtimeSiteReadResult(items: [item(siteKey: 'B')]);
      host.reads['C'] = const RealtimeSiteReadResult(items: []);
      engine.start();
      final result = await engine.pollNow();

      expect(host.readCalls, ['A', 'B', 'C']);
      expect(result!.siteCount, 3);
      expect(result.stats.applied, 2);
    });

    test('E32 · 单站点失败不影响其它站点（不整轮放弃）', () async {
      host.siteKeys = ['A', 'B'];
      host.readErrors['A'] = AppError(
        AppErrorKind.realtimePartialFailure,
        '超时',
        retryable: true,
      );
      host.reads['B'] = RealtimeSiteReadResult(items: [item(siteKey: 'B')]);
      engine.start();
      final result = await engine.pollNow();

      expect(host.readCalls, ['A', 'B']);
      expect(result!.stats.applied, 1);
      // 有站点网络失败 → 整轮按 failure 处理，游标不推进（宁可不推进）。
      expect(result.outcome, RealtimeBatchOutcome.failure);
      expect(engine.cursor, 0);
    });

    test('E33 · 无站点可轮询 → 不发请求也不推进游标', () async {
      host.siteKeys = const [];
      engine.start();
      final result = await engine.pollNow();
      expect(result, isNull);
      expect(host.readCalls, isEmpty);
      expect(engine.cursor, 0);
    });
  });

  group('源归属（用户 2026-10-28：历史页出现「来源未知」）', () {
    test('E37 · 归属透传给合并，且整轮只解析一次（设备级）', () async {
      host.resolvedSourceKey = 'bridge|dev-uuid-0001|a';
      host.siteKeys = ['A', 'B'];
      host.reads['A'] = RealtimeSiteReadResult(items: [item(siteKey: 'A')]);
      host.reads['B'] = RealtimeSiteReadResult(items: [item(siteKey: 'B')]);
      engine.start();
      await engine.pollNow();

      expect(host.mergedSourceKeys, [
        'bridge|dev-uuid-0001|a',
        'bridge|dev-uuid-0001|a',
      ]);
      expect(
        host.resolveSourceKeyCalls,
        1,
        reason: '同一轮里两个站点问两次设备，既浪费请求又可能得到两种答案',
      );
    });

    test('E38 · 全轮无记录 → 不解析归属（不白付一次设备请求）', () async {
      host.resolvedSourceKey = 'bridge|dev-uuid-0001|a';
      host.siteKeys = ['A'];
      host.reads['A'] = const RealtimeSiteReadResult(items: []);
      engine.start();
      await engine.pollNow();

      expect(host.resolveSourceKeyCalls, 0);
      expect(host.mergedSourceKeys, isEmpty);
    });

    test('E39 · 解析不出归属 → 透传空串（不猜，落到「全部来源」）', () async {
      host.siteKeys = ['A'];
      host.reads['A'] = RealtimeSiteReadResult(items: [item(siteKey: 'A')]);
      engine.start();
      await engine.pollNow();

      expect(host.mergedSourceKeys, ['']);
    });
  });

  group('引擎生命周期', () {
    test('E34 · start 幂等（重复调用不叠加定时器）', () {
      engine.start();
      engine.start();
      expect(engine.activeTimerCount, 2);
    });

    test('E35 · stop 幂等，且活动定时器归零', () {
      engine.start();
      engine.stop();
      engine.stop();
      expect(engine.activeTimerCount, 0);
      expect(engine.isRunning, isFalse);
    });

    test('E36 · 启动时清掉上一次的停止标记（用户显式重新开启）', () async {
      host.readErrors['CupFox'] = AppError(
        AppErrorKind.syncDisabled,
        '未授权',
        statusCode: 403,
      );
      engine.start();
      await engine.pollNow();
      expect(engine.snapshot().pollStopped, isTrue);

      engine.stop();
      host.readErrors.clear();
      engine.start();
      expect(engine.snapshot().pollStopped, isFalse);
      expect(engine.snapshot().pollScheduled, isTrue);
    });
  });
}
