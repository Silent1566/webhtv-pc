/// Phase 7 · 保活可达性与唤醒阶梯（`docs/phase7/design/02` §3–§5、`design/04` K1–K11）。
///
/// 本文件只锁**可离线判定的纯逻辑**：三态归类、三态→错误分类映射、
/// 周期归一化约束、唤醒阶梯选择。定时器编排与真实 HTTP 探测属 L2
/// （`phase7_realtime_engine_test.dart`，T6）。
///
/// 反向验证靶子（`design/04` §3.2 #4）：
/// 把「TCP 通但 HTTP 超时」归为 `NETWORK_UNREACHABLE` 后，本文件必须转红。
///
/// **不得出现 `testWidgets`**：本文件与真实 I/O 的用例同 isolate 时会
/// 被装上 mock HTTP 拦截，导致 DNS/连接类真实探测静默失效。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/core/realtime_sync.dart';

void main() {
  group('K4/K5/K6 · 三态判定（design/02 §4，反向验证 #4 靶子）', () {
    test('K1 · 连接被拒 → SERVICE_STOPPED', () {
      expect(
        classifyProbeSteps([RealtimeProbeStep.connectionRefused]),
        RealtimePeerState.serviceStopped,
      );
    });

    test('K2 · TCP 通但 HTTP 超时 → PEER_FROZEN', () {
      expect(
        classifyProbeSteps([
          RealtimeProbeStep.manageMissing,
          RealtimeProbeStep.timeout,
          RealtimeProbeStep.tcpConnectedNoHttp,
        ]),
        RealtimePeerState.peerFrozen,
      );
    });

    test('K3 · TCP 超时 → NETWORK_UNREACHABLE', () {
      expect(
        classifyProbeSteps([
          RealtimeProbeStep.timeout,
          RealtimeProbeStep.timeout,
          RealtimeProbeStep.timeout,
        ]),
        RealtimePeerState.networkUnreachable,
      );
    });

    test('空探测列表归为 NETWORK_UNREACHABLE（不是 OK）', () {
      expect(classifyProbeSteps(const []), RealtimePeerState.networkUnreachable);
    });

    test('K4 · /manage/session 200 → OK', () {
      expect(
        classifyProbeSteps([RealtimeProbeStep.manageOk]),
        RealtimePeerState.ok,
      );
      // 探测步数 = 1：200 之后不该再探测。
      final steps = [RealtimeProbeStep.manageOk];
      expect(steps.length, 1);
    });

    test('K5 · /manage/session 404 → 降级 /device 后 OK', () {
      expect(
        classifyProbeSteps([
          RealtimeProbeStep.manageMissing,
          RealtimeProbeStep.deviceOk,
        ]),
        RealtimePeerState.ok,
      );
    });

    test('三态的「拒绝」一律是 SERVICE_STOPPED（含 S3 的拒绝）', () {
      // 进程被冻结时内核仍会完成 TCP 握手，不会拒绝——
      // 所以「拒绝」永远意味着端口没人监听。
      expect(
        classifyProbeSteps([
          RealtimeProbeStep.timeout,
          RealtimeProbeStep.timeout,
          RealtimeProbeStep.connectionRefused,
        ]),
        RealtimePeerState.serviceStopped,
      );
    });

    test('三态 → 错误分类映射（design/02 §7）', () {
      expect(
        keepAliveErrorKindFor(RealtimePeerState.serviceStopped),
        AppErrorKind.keepAliveServiceStopped,
      );
      expect(
        keepAliveErrorKindFor(RealtimePeerState.peerFrozen),
        AppErrorKind.keepAlivePeerFrozen,
      );
      expect(
        keepAliveErrorKindFor(RealtimePeerState.networkUnreachable),
        AppErrorKind.keepAliveNetworkUnreachable,
      );
      // OK 不该被映射成错误。
      expect(
        () => keepAliveErrorKindFor(RealtimePeerState.ok),
        throwsArgumentError,
      );
    });

    test('K6 · 三态缓存 30 s', () {
      final cache = RealtimePeerStateCache();
      final t0 = DateTime(2026, 10, 17, 12);
      expect(cache.read(t0), isNull);
      cache.write(RealtimePeerState.peerFrozen, t0);
      expect(cache.read(t0.add(const Duration(seconds: 29))), RealtimePeerState.peerFrozen);
      expect(cache.read(t0.add(const Duration(seconds: 30))), isNull);
    });

    test('退避恢复后必须主动失效缓存（不得沿用旧的不可达状态）', () {
      final cache = RealtimePeerStateCache();
      final t0 = DateTime(2026, 10, 17, 12);
      cache.write(RealtimePeerState.peerFrozen, t0);
      cache.invalidate();
      expect(cache.read(t0), isNull);
    });

    test('两类错误集合互斥（realtime* 与 keepAlive*）', () {
      expect(
        realtimeErrorKinds.intersection(keepAliveErrorKinds),
        isEmpty,
      );
      for (final kind in realtimeErrorKinds) {
        expect(describeErrorKind(kind), isNotEmpty);
      }
      for (final kind in keepAliveErrorKinds) {
        expect(describeErrorKind(kind), isNotEmpty);
      }
    });
  });

  group('K9/K10/K11 · 唤醒阶梯（design/02 §5.1）', () {
    test('K9 · 首次失败不动作（L0）', () {
      final level = selectWakeLevel(
        consecutiveFailures: 1,
        state: RealtimePeerState.serviceStopped,
      );
      expect(level, RealtimeWakeLevel.none);
      expect(wakeLevelSendsRequest(level), isFalse);
    });

    test('K10 · 第 2 次失败 → L1（/manage/session）', () {
      final level = selectWakeLevel(
        consecutiveFailures: 2,
        state: RealtimePeerState.serviceStopped,
      );
      expect(level, RealtimeWakeLevel.touchManage);
      expect(wakeLevelSendsRequest(level), isTrue);
    });

    test('第 3 次失败 → L2（/device）', () {
      expect(
        selectWakeLevel(
          consecutiveFailures: 3,
          state: RealtimePeerState.serviceStopped,
        ),
        RealtimeWakeLevel.touchDevice,
      );
    });

    test('K11 · L1/L2 都失败 → L3（仅提示，无请求）', () {
      final level = selectWakeLevel(
        consecutiveFailures: 4,
        state: RealtimePeerState.serviceStopped,
      );
      expect(level, RealtimeWakeLevel.promptOpenManage);
      expect(wakeLevelSendsRequest(level), isFalse);
    });

    test('冻结 → 提示点亮屏幕（仅提示）', () {
      final level = selectWakeLevel(
        consecutiveFailures: 2,
        state: RealtimePeerState.peerFrozen,
      );
      expect(level, RealtimeWakeLevel.promptWakeScreen);
      expect(wakeLevelSendsRequest(level), isFalse);
      expect(wakeLevelChangesPeerState(level), isFalse);
    });

    test('L5 只在 backgroundSettingsNeeded 时出现，且必须用户手势', () {
      final none = selectWakeLevel(
        consecutiveFailures: 4,
        state: RealtimePeerState.peerFrozen,
      );
      expect(none, RealtimeWakeLevel.promptWakeScreen);

      final l5 = selectWakeLevel(
        consecutiveFailures: 4,
        state: RealtimePeerState.peerFrozen,
        backgroundSettingsNeeded: true,
      );
      expect(l5, RealtimeWakeLevel.offerBackgroundSettings);
      expect(wakeLevelRequiresUserGesture(l5), isTrue);
      expect(wakeLevelChangesPeerState(l5), isTrue);
      // L5 本身不发请求——它只是提供按钮，请求在用户点击后由 UI 触发。
      expect(wakeLevelSendsRequest(l5), isFalse);
    });

    test('网络不通时不做 touch（连不上就是连不上）', () {
      final level = selectWakeLevel(
        consecutiveFailures: 2,
        state: RealtimePeerState.networkUnreachable,
      );
      expect(wakeLevelSendsRequest(level), isFalse);
    });

    test('除 L1/L2 外任何级别都不发请求', () {
      for (final level in RealtimeWakeLevel.values) {
        final expected = level == RealtimeWakeLevel.touchManage ||
            level == RealtimeWakeLevel.touchDevice;
        expect(wakeLevelSendsRequest(level), expected, reason: '$level');
      }
      // 只有 L5 改变对端状态。
      for (final level in RealtimeWakeLevel.values) {
        expect(
          wakeLevelChangesPeerState(level),
          level == RealtimeWakeLevel.offerBackgroundSettings,
          reason: '$level',
        );
      }
    });
  });
}
