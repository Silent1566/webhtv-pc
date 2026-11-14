/// Phase 7 · 实时同步纯逻辑（`docs/phase7/design/01` §4.2/§6.3、`design/04` S1–S13）。
///
/// 本文件只锁**可离线判定的纯逻辑**：周期归一化、开关联动、游标推进、
/// 站点选择、退避序列、集消歧、能力探测与降级、手动操作前置条件。
/// 它们全部来自 `lib/core/realtime_sync.dart`，不含 I/O，因此可以用普通
/// `test()`（**本文件不得出现 `testWidgets`**，否则整个 isolate 会被装上
/// mock HTTP 拦截，真实 I/O 的用例会静默失效）。
///
/// 保活/三态/唤醒阶梯的纯逻辑在 `phase7_keepalive_test.dart`
/// （K1–K11），按 `README.md` §3.1 的套件清单分文件。
///
/// 其中三组断言是**反向验证的靶子**（`design/04` §3.2）：
/// - 游标推进（#6 破坏点：部分失败时也推进）；
/// - 退避序列（#5 破坏点：改为恒定周期）；
/// - 含凭据项默认不实时（#8 破坏点：默认参与）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/core/realtime_sync.dart';

void main() {
  group('S13 · 轮询站点选择（design/01 §3.1）', () {
    test('默认只取最近活跃的 20 个', () {
      final known = List.generate(100, (i) => 'site_$i');
      final selected = selectPollSites(known: known, pollAllSites: false);

      expect(selected, isNotNull);
      expect(selected!.length, realtimeDefaultSiteLimit);
      expect(selected.first, 'site_0');
    });

    test('轮询全部站点时返回 null（表示不设上限）', () {
      final known = List.generate(100, (i) => 'site_$i');
      expect(selectPollSites(known: known, pollAllSites: true), isNull);
    });

    test('最近活跃优先，且不重复', () {
      final selected = prioritizePollSites(
        recentlyActive: ['hot_1', 'hot_2', 'site_0'],
        known: ['site_0', 'site_1', 'site_2'],
        limit: 4,
      );

      // hot_1、hot_2 先；site_0 已在最近活跃里出现过，不重复出现。
      expect(selected, ['hot_1', 'hot_2', 'site_0', 'site_1']);
    });

    test('已知站点少于上限时全取', () {
      final selected = selectPollSites(
        known: ['a', 'b'],
        pollAllSites: false,
      );
      expect(selected, ['a', 'b']);
    });

    test('limit 为 0 → 空清单（不是全量）', () {
      expect(
        selectPollSites(known: ['a', 'b'], pollAllSites: false, limit: 0),
        isEmpty,
      );
    });
  });

  group('S11 · 退避序列（design/01 §6.3）', () {
    test('连续失败 1/2/3/4 次 → 周期 ×1/2/4/8', () {
      expect(realtimeBackoffMultiplier(0), 1);
      expect(realtimeBackoffMultiplier(1), 1);
      expect(realtimeBackoffMultiplier(2), 2);
      expect(realtimeBackoffMultiplier(3), 4);
      expect(realtimeBackoffMultiplier(4), 8);
    });

    test('倍数封顶 8×，不继续翻倍', () {
      expect(realtimeBackoffMultiplier(5), 8);
      expect(realtimeBackoffMultiplier(50), 8);
    });

    test('下一次延迟 = 基准 × 倍数，并夹到 300 s', () {
      expect(realtimeNextDelaySeconds(baseSeconds: 60, consecutiveFailures: 1), 60);
      expect(realtimeNextDelaySeconds(baseSeconds: 60, consecutiveFailures: 2), 120);
      expect(realtimeNextDelaySeconds(baseSeconds: 60, consecutiveFailures: 3), 240);
      // 60 × 8 = 480 > 300 → 夹到 300。
      expect(realtimeNextDelaySeconds(baseSeconds: 60, consecutiveFailures: 4), 300);
    });

    test('第 5 次失败起暂停自动重试', () {
      expect(shouldPauseRealtime(4), isFalse);
      expect(shouldPauseRealtime(5), isTrue);
    });

    test('404 不计入退避（未播放是合法形态）', () {
      expect(countsTowardBackoff(statusCode: 404, isNetworkError: false), isFalse);
      final decision = decideRealtimeFailure(
        consecutiveFailures: 3,
        statusCode: 404,
        isNetworkError: false,
      );
      // 计数不变、不暂停、无错误。
      expect(decision.nextConsecutiveFailures, 3);
      expect(decision.paused, isFalse);
      expect(decision.error, isNull);
      expect(decision.stopDirection, isFalse);
    });

    test('5xx 与网络错误计入退避', () {
      expect(countsTowardBackoff(statusCode: 500, isNetworkError: false), isTrue);
      expect(countsTowardBackoff(statusCode: null, isNetworkError: true), isTrue);
      expect(countsTowardBackoff(statusCode: 200, isNetworkError: false), isFalse);
    });

    test('403 → 立即停止该方向，且不涨失败计数', () {
      final decision = decideRealtimeFailure(
        consecutiveFailures: 2,
        statusCode: 403,
        isNetworkError: false,
      );
      expect(decision.stopDirection, isTrue);
      expect(decision.paused, isFalse);
      expect(decision.nextConsecutiveFailures, 2);
      expect(decision.error!.kind, AppErrorKind.syncDisabled);
    });

    test('冻结对端的失败分类指向 keepAlivePeerFrozen', () {
      final decision = decideRealtimeFailure(
        consecutiveFailures: 1,
        statusCode: null,
        isNetworkError: true,
        peerFrozen: true,
      );
      expect(decision.error!.kind, AppErrorKind.keepAlivePeerFrozen);
      expect(decision.multiplier, 2);
    });
  });

  group('S8 · 游标推进（design/01 §4.2，反向验证 #6 靶子）', () {
    test('整批成功 → 推进到远端游标', () {
      final decision = decideCursor(
        currentCursor: 100,
        outcome: RealtimeBatchOutcome.success,
        remoteMaxCursor: 180,
      );
      expect(decision.advance, isTrue);
      expect(decision.nextCursor, 180);
    });

    test('部分失败 → 游标不变', () {
      final decision = decideCursor(
        currentCursor: 100,
        outcome: RealtimeBatchOutcome.partial,
        remoteMaxCursor: 180,
      );
      expect(decision.advance, isFalse);
      expect(decision.nextCursor, 100);
    });

    test('连接失败 → 游标不变', () {
      final decision = decideCursor(
        currentCursor: 100,
        outcome: RealtimeBatchOutcome.failure,
        remoteMaxCursor: 180,
      );
      expect(decision.advance, isFalse);
      expect(decision.nextCursor, 100);
    });

    test('鉴权失败 → 游标不变且停止该方向', () {
      final decision = decideCursor(
        currentCursor: 100,
        outcome: RealtimeBatchOutcome.unauthorized,
      );
      expect(decision.advance, isFalse);
      expect(decision.nextCursor, 100);
      expect(decision.stopDirection, isTrue);
    });

    test('成功但响应无游标 → 不猜值，保持不动', () {
      final decision = decideCursor(
        currentCursor: 100,
        outcome: RealtimeBatchOutcome.success,
      );
      expect(decision.advance, isFalse);
      expect(decision.nextCursor, 100);
    });

    test('成功且远端游标等于当前 → 不推进（也不回退）', () {
      final decision = decideCursor(
        currentCursor: 100,
        outcome: RealtimeBatchOutcome.success,
        remoteMaxCursor: 100,
      );
      expect(decision.advance, isFalse);
      expect(decision.nextCursor, 100);
    });

    test('远端游标更小 → 判定陈旧并接受远端值（安卓重装）', () {
      expect(isCursorStale(currentCursor: 100, remoteMaxCursor: 40), isTrue);
      final decision = decideCursor(
        currentCursor: 100,
        outcome: RealtimeBatchOutcome.success,
        remoteMaxCursor: 40,
      );
      expect(decision.advance, isTrue);
      expect(decision.nextCursor, 40);
    });

    test('远端游标相等不算陈旧', () {
      expect(isCursorStale(currentCursor: 100, remoteMaxCursor: 100), isFalse);
    });
  });

  group('S9/S10 · 开关矩阵与联动（design/01 §6.1/§6.2）', () {
    test('全部默认关闭', () {
      const switches = RealtimeSyncSwitches();
      expect(switches.enabled, isFalse);
      expect(switches.pullEnabled, isFalse);
      expect(switches.pushEnabled, isFalse);
      expect(switches.settingsEnabled, isFalse);
      expect(switches.pollAllSites, isFalse);
      expect(switches.intervalSeconds, 60);
      expect(switches.heartbeatSeconds, 30);
      expect(switches.shouldPoll, isFalse);
      expect(switches.shouldHeartbeat, isFalse);
    });

    test('S9 · pushEnabled=true 而 serverEnabled=false → 自动开服务端并提示', () {
      final decision = applyRealtimeSwitchRules(
        desired: const RealtimeSyncSwitches(enabled: true, pushEnabled: true),
        serverEnabled: false,
        settingsSyncEnabled: false,
      );
      expect(decision.rejected, isFalse);
      expect(decision.autoEnabledServer, isTrue);
    });

    test('服务端已开时不再重复提示', () {
      final decision = applyRealtimeSwitchRules(
        desired: const RealtimeSyncSwitches(enabled: true, pushEnabled: true),
        serverEnabled: true,
        settingsSyncEnabled: false,
      );
      expect(decision.autoEnabledServer, isFalse);
    });

    test('S10 · settingsEnabled=true 而 settingsSyncEnabled=false → 拒绝', () {
      final decision = applyRealtimeSwitchRules(
        desired: const RealtimeSyncSwitches(enabled: true, settingsEnabled: true),
        serverEnabled: true,
        settingsSyncEnabled: false,
      );
      expect(decision.rejected, isTrue);
      // 开关被强制收回，不得"先开了再补提示"。
      expect(decision.switches.settingsEnabled, isFalse);
      expect(decision.error!.kind, AppErrorKind.realtimeSyncDisabled);
    });

    test('两个开关都开时允许', () {
      final decision = applyRealtimeSwitchRules(
        desired: const RealtimeSyncSwitches(enabled: true, settingsEnabled: true),
        serverEnabled: true,
        settingsSyncEnabled: true,
      );
      expect(decision.rejected, isFalse);
      expect(decision.switches.settingsEnabled, isTrue);
    });

    test('关闭总开关时不自动拉起服务端（顺手开监听端口是越界）', () {
      final decision = applyRealtimeSwitchRules(
        desired: const RealtimeSyncSwitches(enabled: false, pushEnabled: true),
        serverEnabled: false,
        settingsSyncEnabled: false,
      );
      expect(decision.autoEnabledServer, isFalse);
    });

    test('关闭总开关时子开关值保留（下次开启沿用）', () {
      const desired = RealtimeSyncSwitches(
        enabled: false,
        pullEnabled: true,
        pushEnabled: true,
        intervalSeconds: 300,
      );
      final decision = applyRealtimeSwitchRules(
        desired: desired,
        serverEnabled: true,
        settingsSyncEnabled: false,
      );
      expect(decision.switches.enabled, isFalse);
      expect(decision.switches.pullEnabled, isTrue);
      expect(decision.switches.pushEnabled, isTrue);
      expect(decision.switches.intervalSeconds, 300);
    });

    test('只开推送方向时心跳仍要跑（路径 B 需要可达性判定）', () {
      const switches = RealtimeSyncSwitches(enabled: true, pushEnabled: true);
      expect(switches.shouldPoll, isFalse);
      expect(switches.shouldHeartbeat, isTrue);
    });
  });

  group('S11/S12 前置 · 周期归一化（design/02 §3.4）', () {
    test('轮询周期吸附到四档：15/30/60/300', () {
      expect(normalizeRealtimeIntervalSeconds(15), 15);
      expect(normalizeRealtimeIntervalSeconds(16), 15);
      expect(normalizeRealtimeIntervalSeconds(23), 30);
      expect(normalizeRealtimeIntervalSeconds(45), 60);
      expect(normalizeRealtimeIntervalSeconds(200), 300);
    });

    test('轮询周期夹到 [15, 3600]', () {
      expect(normalizeRealtimeIntervalSeconds(5), 15);
      expect(normalizeRealtimeIntervalSeconds(99999), 300);
    });

    test('null → 默认 60', () {
      expect(normalizeRealtimeIntervalSeconds(null), 60);
    });

    test('K7 · 心跳 5 s → 10 s；700 s → 300 s', () {
      expect(normalizeHeartbeatSeconds(5), 10);
      expect(normalizeHeartbeatSeconds(700), 300);
      expect(normalizeHeartbeatSeconds(null), 30);
      expect(normalizeHeartbeatSeconds(45), 45);
    });

    test('K8 · 心跳 > 轮询 → 收敛到轮询', () {
      expect(
        normalizeHeartbeatWithIntervalSeconds(
          heartbeatSeconds: 120,
          intervalSeconds: 30,
        ),
        30,
      );
      // 心跳 ≤ 轮询时不变。
      expect(
        normalizeHeartbeatWithIntervalSeconds(
          heartbeatSeconds: 30,
          intervalSeconds: 60,
        ),
        30,
      );
    });

    test('归一化不变量：心跳恒 ≤ 轮询，且都在合法区间', () {
      for (final interval in [5, 15, 45, 300, 99999]) {
        for (final heartbeat in [null, 5, 30, 120, 700]) {
          final normalized = RealtimeSyncSwitches(
            intervalSeconds: interval,
            heartbeatSeconds: heartbeat ?? 30,
          ).normalized();
          expect(
            normalized.heartbeatSeconds <= normalized.intervalSeconds,
            isTrue,
            reason: 'interval=$interval heartbeat=$heartbeat',
          );
          expect(normalized.heartbeatSeconds >= keepAliveMinHeartbeatSeconds, isTrue);
          expect(normalized.heartbeatSeconds <= keepAliveMaxHeartbeatSeconds, isTrue);
          expect(realtimeIntervalChoices.contains(normalized.intervalSeconds), isTrue);
        }
      }
    });
  });

  group('设置白名单与含凭据项（design/01 §5.1，反向验证 #7/#8 靶子）', () {
    test('S29 · 默认不含含凭据项', () {
      expect(realtimeIncludesSetting('tmdb_enabled', settingsEnabled: false), isTrue);
      expect(realtimeIncludesSetting('tmdb_config', settingsEnabled: false), isFalse);
      expect(realtimeIncludesSetting('ai_config', settingsEnabled: false), isFalse);
    });

    test('显式开启后才含凭据项', () {
      expect(realtimeIncludesSetting('ai_config', settingsEnabled: true), isTrue);
      expect(realtimeIncludesSetting('tmdb_config', settingsEnabled: true), isTrue);
    });

    test('白名单外的键一律不参与', () {
      expect(realtimeIncludesSetting('some_other', settingsEnabled: true), isFalse);
    });

    test('S28 · unsupportedKeys 与 skippedKeys 互斥', () {
      final partition = partitionRealtimeSettings([
        'tmdb_enabled',
        'tmdb_model',
        'ai_config',
        'ai_title_extraction',
        'ai_ad_detection',
        'unknown_key',
      ], settingsEnabled: true);

      expect(partition.supported, ['tmdb_enabled', 'ai_config']);
      expect(partition.unsupportedKeys, [
        'tmdb_model',
        'ai_title_extraction',
        'ai_ad_detection',
      ]);
      expect(partition.skippedKeys, ['unknown_key']);

      // 互斥性：任一个键不能同时出现在两个集合里。
      final all = [
        ...partition.supported,
        ...partition.unsupportedKeys,
        ...partition.skippedKeys,
      ];
      expect(all.length, all.toSet().length);
    });

    test('ai_config 关闭时进 skippedKeys 而不是 unsupportedKeys', () {
      final partition = partitionRealtimeSettings([
        'ai_config',
        'tmdb_model',
      ], settingsEnabled: false);
      expect(partition.supported, isEmpty);
      expect(partition.skippedKeys, ['ai_config']);
      expect(partition.unsupportedKeys, ['tmdb_model']);
    });
  });

  group('S6/S7 · episodeId 兜底（design/01 §4.1）', () {
    test('S30 · 有 episodeId 字段 → 直用，不被集名覆盖', () {
      final resolution = resolveEpisodeId(
        episodeIdField: 'a' * 64,
        episodeName: '第01集',
      );
      expect(resolution.source, EpisodeIdSource.field);
      expect(resolution.episodeId, 'a' * 64);
      expect(resolution.mergeable, isTrue);
    });

    test('S6 · 缺字段 → 用 episodeName 兜底', () {
      final resolution = resolveEpisodeId(
        episodeIdField: null,
        episodeName: '第01集',
      );
      expect(resolution.source, EpisodeIdSource.episodeName);
      expect(resolution.episodeId, '第01集');
      expect(resolution.mergeable, isTrue);
    });

    test('空串字段视为缺失（不是"有一个空身份"）', () {
      final resolution = resolveEpisodeId(
        episodeIdField: '   ',
        episodeName: '第02集',
      );
      expect(resolution.source, EpisodeIdSource.episodeName);
    });

    test('S7 · 两者都空 → 不合并', () {
      final resolution = resolveEpisodeId(episodeIdField: '', episodeName: '  ');
      expect(resolution.source, EpisodeIdSource.none);
      expect(resolution.mergeable, isFalse);
      expect(resolution.episodeId, isEmpty);
    });
  });

  group('S17 · 能力探测与降级（design/01 §4.1）', () {
    test('history 返回 200+JSON → 完整能力（含空数组）', () {
      expect(
        classifyPullCapability(
          history: EndpointProbeResult.ok,
          current: EndpointProbeResult.missing,
        ),
        RealtimePullCapability.history,
      );
    });

    test('history 不存在而 current 存在 → 降级为 currentOnly', () {
      expect(
        classifyPullCapability(
          history: EndpointProbeResult.missing,
          current: EndpointProbeResult.notFound,
        ),
        RealtimePullCapability.currentOnly,
      );
      expect(
        classifyPullCapability(
          history: EndpointProbeResult.missing,
          current: EndpointProbeResult.ok,
        ),
        RealtimePullCapability.currentOnly,
      );
    });

    test('两者都不可用 → unsupported', () {
      expect(
        classifyPullCapability(
          history: EndpointProbeResult.missing,
          current: EndpointProbeResult.missing,
        ),
        RealtimePullCapability.unsupported,
      );
      expect(
        classifyPullCapability(
          history: EndpointProbeResult.unreachable,
          current: EndpointProbeResult.unreachable,
        ),
        RealtimePullCapability.unsupported,
      );
    });

    test('第二种阻塞性发现 · 200+octet-stream 必须归为「端点不存在」', () {
      // 真机实测：安卓 Nano.serve() 对未匹配路径落到 getAssets()，
      // NanoHTTPD 对缺失资产返回 200 + application/octet-stream + 空体。
      // 只看状态码会把「不存在」当成「存在且无数据」。
      expect(
        classifyEndpointProbe(
          statusCode: 200,
          contentType: 'application/octet-stream',
          bodyLength: 0,
        ),
        EndpointProbeResult.missing,
      );
      // 对照：200 + JSON 才算存在。
      expect(
        classifyEndpointProbe(
          statusCode: 200,
          contentType: 'application/json; charset=utf-8',
          bodyLength: 41,
        ),
        EndpointProbeResult.ok,
      );
    });

    test('400+JSON 算端点存在（参数不对而非端点缺失）', () {
      expect(
        classifyEndpointProbe(
          statusCode: 400,
          contentType: 'application/json; charset=utf-8',
          bodyLength: 40,
        ),
        EndpointProbeResult.badRequest,
      );
      expect(endpointExists(EndpointProbeResult.badRequest), isTrue);
    });

    test('404+JSON 算端点存在（未播放是合法形态）', () {
      expect(
        classifyEndpointProbe(
          statusCode: 404,
          contentType: 'application/json; charset=utf-8',
          bodyLength: 39,
        ),
        EndpointProbeResult.notFound,
      );
      expect(endpointExists(EndpointProbeResult.notFound), isTrue);
    });

    test('404 但非 JSON → 保守归 missing（网关/代理的 404 不算端点存在）', () {
      expect(
        classifyEndpointProbe(statusCode: 404, contentType: 'text/html'),
        EndpointProbeResult.missing,
      );
    });

    test('405/501 算端点存在（方法不对但端点在那里）', () {
      expect(
        classifyEndpointProbe(statusCode: 405),
        EndpointProbeResult.methodNotAllowed,
      );
      expect(
        classifyEndpointProbe(statusCode: 501),
        EndpointProbeResult.methodNotAllowed,
      );
      expect(endpointExists(EndpointProbeResult.methodNotAllowed), isTrue);
    });

    test('连不上/超时 → unreachable 且不算端点存在', () {
      expect(
        classifyEndpointProbe(statusCode: null),
        EndpointProbeResult.unreachable,
      );
      expect(endpointExists(EndpointProbeResult.unreachable), isFalse);
    });

    test('5xx 保守归 missing（假装可用会让下轮读取失败）', () {
      expect(
        classifyEndpointProbe(
          statusCode: 500,
          contentType: 'application/json',
        ),
        EndpointProbeResult.missing,
      );
    });

    test('降级必须常驻披露，unsupported 提示升级', () {
      expect(pullCapabilityError(RealtimePullCapability.history), isNull);
      expect(
        pullCapabilityError(RealtimePullCapability.currentOnly)!.kind,
        AppErrorKind.realtimePullDegraded,
      );
      expect(
        pullCapabilityError(RealtimePullCapability.unsupported)!.kind,
        AppErrorKind.realtimePullUnsupported,
      );
    });

    test('S32 · 能力缓存 60 s 内只探测一次', () {
      final cache = RealtimeCapabilityCache();
      final t0 = DateTime(2026, 10, 17, 12);
      expect(cache.read(t0), isNull);

      cache.write(RealtimePullCapability.history, t0);
      expect(cache.read(t0.add(const Duration(seconds: 59))), RealtimePullCapability.history);
      // 60 s 到期即失效（>=，不是 >）。
      expect(cache.read(t0.add(const Duration(seconds: 60))), isNull);
    });

    test('S33 · 空数组不得被当成「端点缺失」', () {
      // 这是回归靶子：把 200 空数组当 404 会让"所有站点都没看过"的用户
      // 被永久降级到 currentOnly。
      final capability = classifyPullCapability(
        history: EndpointProbeResult.ok,
        current: EndpointProbeResult.notFound,
      );
      expect(capability, RealtimePullCapability.history);
      expect(pullCapabilityError(capability), isNull);
    });
  });

  group('S21/S22 · 手动操作前置条件（design/01 §4.4/§4.5）', () {
    test('S21 · 拉取最近记录不依赖服务端（实时总开关关闭也允许）', () {
      final precheck = precheckManualPull(
        kind: RealtimeManualPullKind.recentRecords,
        realtimeEnabled: false,
        serverEnabled: false,
        peerReachable: true,
        peerAddress: '192.168.1.5:9978',
      );
      expect(precheck.allowed, isTrue);
    });

    test('S22 · 请求安卓推送全量在服务端关闭时给出 syncDisabled', () {
      final precheck = precheckManualPull(
        kind: RealtimeManualPullKind.requestAndroidPush,
        realtimeEnabled: false,
        serverEnabled: false,
        peerReachable: true,
        peerAddress: '192.168.1.5:9978',
      );
      expect(precheck.allowed, isFalse);
      expect(precheck.error!.kind, AppErrorKind.syncDisabled);
      expect(precheck.requiresServer, isTrue);
    });

    test('重置游标需实时同步总开关', () {
      final precheck = precheckManualPull(
        kind: RealtimeManualPullKind.resetCursorAndPull,
        realtimeEnabled: false,
        serverEnabled: true,
        peerReachable: true,
        peerAddress: '192.168.1.5:9978',
      );
      expect(precheck.allowed, isFalse);
      expect(precheck.error!.kind, AppErrorKind.realtimeSyncDisabled);
    });

    test('地址为空时三种拉取都拒绝', () {
      for (final kind in RealtimeManualPullKind.values) {
        final precheck = precheckManualPull(
          kind: kind,
          realtimeEnabled: true,
          serverEnabled: true,
          peerReachable: true,
          peerAddress: '   ',
        );
        expect(precheck.allowed, isFalse, reason: '$kind');
        expect(precheck.error, isNotNull);
      }
    });

    test('推送设置需 settingsSyncEnabled（凭据确认不能绕过）', () {
      final denied = precheckManualPush(
        kind: RealtimeManualPushKind.settings,
        pushEnabled: true,
        settingsSyncEnabled: false,
        peerAddress: '192.168.1.5:9978',
      );
      expect(denied.allowed, isFalse);
      expect(denied.error!.kind, AppErrorKind.syncDisabled);

      final allowed = precheckManualPush(
        kind: RealtimeManualPushKind.settings,
        pushEnabled: true,
        settingsSyncEnabled: true,
        peerAddress: '192.168.1.5:9978',
      );
      expect(allowed.allowed, isTrue);
    });

    test('推送总开关关闭时四种推送都拒绝', () {
      for (final kind in RealtimeManualPushKind.values) {
        final precheck = precheckManualPush(
          kind: kind,
          pushEnabled: false,
          settingsSyncEnabled: true,
          peerAddress: '192.168.1.5:9978',
        );
        expect(precheck.allowed, isFalse, reason: '$kind');
      }
    });

    test('推送历史不要求 settingsSyncEnabled', () {
      final precheck = precheckManualPush(
        kind: RealtimeManualPushKind.history,
        pushEnabled: true,
        settingsSyncEnabled: false,
        peerAddress: '192.168.1.5:9978',
      );
      expect(precheck.allowed, isTrue);
    });
  });

  group('错误分类（design/01 §8）', () {
    test('realtime* 与 keepAlive* 各自可判定', () {
      final realtime = AppError(
        AppErrorKind.realtimePullDegraded,
        describeErrorKind(AppErrorKind.realtimePullDegraded),
      );
      final keepAlive = AppError(
        AppErrorKind.keepAlivePeerFrozen,
        describeErrorKind(AppErrorKind.keepAlivePeerFrozen),
      );
      expect(isRealtimeError(realtime), isTrue);
      expect(isKeepAliveError(realtime), isFalse);
      expect(isKeepAliveError(keepAlive), isTrue);
      expect(isRealtimeError(keepAlive), isFalse);
    });

    test('不得把「不支持」说成「0 条记录」', () {
      final message = describeErrorKind(AppErrorKind.realtimePullUnsupported);
      expect(message, contains('不支持'));
      // 必须提到升级，否则用户无从下手。
      expect(message, contains('升级'));
    });

    test('降级文案必须点明「息屏后无法同步」', () {
      final message = describeErrorKind(AppErrorKind.realtimePullDegraded);
      expect(message, contains('息屏'));
    });
  });
}
