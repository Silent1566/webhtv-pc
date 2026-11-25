/// 把一份 PC 原始配置执行到选中的 Android 环境：发布快照、连接、reverse、导入、叠加。
///
/// 只编排冻结模块；不写配置库、不切换 Android 激活配置、不接管用户设备。
library;

// 构造参数名 runtime/bridge/store/publisher/log/connections 是冻结公开接口。
// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../core/android_adb_profile.dart';
import '../core/android_bridge.dart';
import '../core/android_config_execution.dart';
import '../core/app_error.dart';
import '../core/protocol.dart';
import 'android_adb_runtime.dart';
import 'android_bridge_service.dart';
import 'android_config_execution_store.dart';
import 'android_connection_store.dart';
import 'log_service.dart';
import 'pc_config_snapshot_server.dart';
import 'storage.dart';

/// 一次成功执行的结果：持久绑定、内存叠加配置与本次连接的设备。
class AndroidConfigExecutionResult {
  const AndroidConfigExecutionResult({
    required this.binding,
    required this.overlay,
    required this.device,
  });

  final AndroidConfigExecutionBinding binding;
  final AppConfig overlay;
  final AndroidDevice device;
}

enum _OperationKind { prepare, refresh }

class _FlightSpec {
  const _FlightSpec(this.payloadHash, this.launchAvd, this.kind);
  final String payloadHash;
  final bool launchAvd;
  final _OperationKind kind;
}

class _ServiceLease {
  _ServiceLease(this.lease);
  final AndroidReverseLease lease;
  final Set<String> users = <String>{};
}

/// 执行编排器。
class AndroidConfigExecutionService {
  AndroidConfigExecutionService({
    required AndroidAdbRuntime runtime,
    required AndroidBridgeService bridge,
    required AndroidConfigExecutionStore store,
    required AndroidConnectionStore connections,
    required PcConfigSnapshotServer publisher,
    required LogService log,
  }) : _runtime = runtime,
       _bridge = bridge,
       _store = store,
       _connections = connections,
       _publisher = publisher,
       _log = log;

  static const String _scope = 'android';

  final AndroidAdbRuntime _runtime;
  final AndroidBridgeService _bridge;
  final AndroidConfigExecutionStore _store;
  final AndroidConnectionStore _connections;
  final PcConfigSnapshotServer _publisher;
  final LogService _log;

  final Map<String, Future<AndroidConfigExecutionResult>> _flights =
      <String, Future<AndroidConfigExecutionResult>>{};
  final Map<String, _FlightSpec> _flightSpecs = <String, _FlightSpec>{};
  final Set<Future<void>> _active = <Future<void>>{};

  /// 本服务建立的 reverse 租约：uuid|guestPort。
  final Map<String, _ServiceLease> _leases = <String, _ServiceLease>{};

  /// 最近一次发布的正文：token → snapshot。
  final Map<String, Map<String, Object?>> _published =
      <String, Map<String, Object?>>{};

  /// 源 → 用户显式停用次数；在途准备用它识别「飞行中用户改了主意」。
  final Map<String, int> _selectionEpochs = <String, int>{};
  final Map<String, int> _forgetEpochs = <String, int>{};

  /// 在途操作：flightKey → 归属（源、环境、起飞时的意图 epoch）。
  final Map<
    String,
    ({String sourceKey, String profileConnectionKey, int epoch})
  >
  _flightOwners =
      <String, ({String sourceKey, String profileConnectionKey, int epoch})>{};

  bool _closed = false;

  /// 建立（或复用）绑定并启用一次 Android 执行。
  Future<AndroidConfigExecutionResult> prepare({
    required String sourceKey,
    required ConfigRecord record,
    required AppConfig originalConfig,
    required AndroidAdbProfile profile,
    bool launchAvd = false,
  }) {
    if (_closed) return _closedError();
    final source = _prepareIdentity(sourceKey, record);
    final snapshot = _snapshotFor(record);
    final payloadHash = _hashOfText(jsonEncode(snapshot));
    final flightKey = _flightKey(source, profile.connectionKey);
    final pending = _flights[flightKey];
    if (pending != null) {
      final spec = _flightSpecs[flightKey]!;
      if (spec.kind == _OperationKind.prepare &&
          spec.payloadHash == payloadHash &&
          spec.launchAvd == launchAvd) {
        return pending;
      }
      return _conflict();
    }

    late final Future<AndroidConfigExecutionResult> future;
    final owner = (
      sourceKey: source,
      profileConnectionKey: profile.connectionKey,
      epoch: _selectionEpochs[source] ?? 0,
    );
    future =
        _prepareOnce(
          sourceKey: source,
          record: record,
          originalConfig: originalConfig,
          profile: profile,
          snapshot: snapshot,
          payloadHash: payloadHash,
          launchAvd: launchAvd,
        ).whenComplete(() async {
          _clearFlight(flightKey, future);
          await _settleFlight(owner);
        });
    _flights[flightKey] = future;
    _flightOwners[flightKey] = owner;
    _flightSpecs[flightKey] = _FlightSpec(
      payloadHash,
      launchAvd,
      _OperationKind.prepare,
    );
    _track(future);
    return future;
  }

  Future<AndroidConfigExecutionResult> _prepareOnce({
    required String sourceKey,
    required ConfigRecord record,
    required AppConfig originalConfig,
    required AndroidAdbProfile profile,
    required Map<String, Object?> snapshot,
    required String payloadHash,
    required bool launchAvd,
  }) async {
    final bindingKey = _bindingKey(sourceKey, profile.connectionKey);
    // 起飞时刻的选择状态：落盘启用前必须与它一致，否则会把用户的停用/关闭盖回去。
    final enabledAtStart = _store.enabledFor(sourceKey)?.bindingKey;
    final selectionEpochAtStart = _selectionEpochs[sourceKey] ?? 0;
    final previous = _store.forSourceProfile(sourceKey, profile.connectionKey);
    final token = previous?.snapshotToken ?? _newToken();
    final tokenIsNew = previous == null;
    final storedPort = _store.guestPortForProfile(profile.connectionKey) ?? 0;
    final configHash = _hashOfText(jsonEncode(snapshot));

    await _ensurePublisher();
    final previousBody = _published[token];
    final bodyChanged =
        previousBody == null ||
        jsonEncode(previousBody) != jsonEncode(snapshot);
    _publish(token, snapshot);

    AndroidReverseLease? lease;
    var leaseIsNew = false;
    String? uuid;
    var pendingCommitted = false;
    var pendingCreated = false;
    // 一旦进入 importPcConfig，设备可能已建副本（收据可能丢失），预留不能删。
    var importEntered = false;
    AndroidConfigExecutionBinding? written;
    AndroidPcConfigImportResult? imported;
    try {
      final device = await _runtime.connect(
        profile,
        expectedUuid: previous?.deviceUuid,
        launchAvd: launchAvd,
      );
      uuid = device.uuid;
      final acquired = await _acquire(
        device.uuid,
        localPort: _publisher.port,
        guestPort: storedPort,
      );
      lease = acquired.lease;
      leaseIsNew = acquired.isNew;
      final actualPort = lease.guestPort;
      final leaseKey = _leaseKey(device.uuid, actualPort);
      final serviceLease = _leases[leaseKey]!;

      if (previous == null || !previous.isReady) {
        final pending = AndroidConfigExecutionBinding(
          sourceKey: sourceKey,
          profileConnectionKey: profile.connectionKey,
          deviceUuid: device.uuid,
          configHash: configHash,
          snapshotToken: token,
          guestPort: actualPort,
          interfaceKey: previous?.interfaceKey ?? '',
        );
        await _store.putBinding(pending, enable: false);
        written = pending;
        pendingCommitted = true;
        pendingCreated = previous == null;
      }
      serviceLease.users.add(bindingKey);

      importEntered = true;
      imported = await _bridge.importPcConfig(
        device.reachableBase,
        snapshotUrl: _publisher.deviceUri(token, actualPort),
        name: record.name,
      );
      _requireUsableImport(imported);
      final conversion = await _bridge.fetchGatewayConfig(
        device.reachableBase,
        interfaceKey: imported.interfaceKey,
      );
      final overlay = overlayAndroidExecution(
        originalConfig,
        conversion.config,
      );

      final completed = AndroidConfigExecutionBinding(
        sourceKey: sourceKey,
        profileConnectionKey: profile.connectionKey,
        deviceUuid: device.uuid,
        configHash: configHash,
        snapshotToken: token,
        guestPort: actualPort,
        interfaceKey: imported.interfaceKey.trim(),
      );
      if (!completed.isReady) {
        throw AppError(AppErrorKind.bridgeNotAndroid, 'Android 执行绑定尚未就绪，未启用');
      }
      // 落盘启用前再查一次：飞行中被停用/删除/关闭就不能替用户宣布已启用。
      final desiredAtCommit =
          _intentUnchanged(sourceKey, selectionEpochAtStart) &&
          _store.enabledFor(sourceKey)?.bindingKey == enabledAtStart;
      await _store.putBinding(completed, enable: desiredAtCommit);
      written = completed;
      // 提交本身是异步的：只撤销自己的启用，不能清掉后来选中的其它环境。
      final stillSelected =
          desiredAtCommit &&
          _intentUnchanged(sourceKey, selectionEpochAtStart) &&
          _store.enabledFor(sourceKey)?.bindingKey == bindingKey;
      if (!stillSelected) {
        await _forgetIfRequested(completed, selectionEpochAtStart);
        await _disableIfSelected(sourceKey, bindingKey);
        await _releaseBindingResources(completed, bindingKey);
        _log.info(
          'Android 执行已准备但未启用 source=${_fingerprint(sourceKey)} '
          'device=${device.maskedUuid} guestPort=$actualPort '
          'copy=${imported.created ? 'created' : 'reused'} '
          'reason=${_closed ? 'service-closed' : 'selection-changed'}',
          scope: _scope,
        );
        return AndroidConfigExecutionResult(
          binding: completed,
          overlay: overlay,
          device: device,
        );
      }
      _log.info(
        'Android 执行已启用 source=${_fingerprint(sourceKey)} '
        'device=${device.maskedUuid} guestPort=$actualPort '
        'copy=${imported.created ? 'created' : 'reused'}',
        scope: _scope,
      );
      return AndroidConfigExecutionResult(
        binding: completed,
        overlay: overlay,
        device: device,
      );
    } catch (error) {
      await _rollbackPrepare(
        sourceKey: sourceKey,
        profileConnectionKey: profile.connectionKey,
        bindingKey: bindingKey,
        token: token,
        tokenIsNew: tokenIsNew,
        previous: previous,
        pendingCommitted: pendingCommitted,
        pendingCreated: pendingCreated,
        importEntered: importEntered,
        lease: lease,
        leaseIsNew: leaseIsNew,
        uuid: uuid,
        bodyChanged: bodyChanged,
        previousBody: previousBody,
        imported: imported,
      );
      if (await _forgetIfRequested(written, selectionEpochAtStart)) {
        await _releaseBindingResources(written!, bindingKey);
      }
      rethrow;
    }
  }

  /// 复用已有绑定/token/guestPort/interfaceKey 重新发布、重连、重导并叠加。
  Future<AndroidConfigExecutionResult> refresh(
    AndroidConfigExecutionBinding binding, {
    required ConfigRecord record,
    required AppConfig originalConfig,
  }) {
    if (_closed) return _closedError();
    final source = _refreshIdentity(binding, record);
    if (!binding.isReady) {
      throw AppError(
        AppErrorKind.storage,
        'Android 执行绑定尚未就绪，无法刷新',
        detail: 'source=${_fingerprint(source)}',
      );
    }
    final profile = _connections.forKey(binding.profileConnectionKey)?.profile;
    if (profile == null) {
      throw AppError(
        AppErrorKind.storage,
        'Android 环境连接描述已丢失，请重新选择环境并准备',
        detail: 'profile=${_fingerprint(binding.profileConnectionKey)}',
      );
    }
    final snapshot = _snapshotFor(record);
    final payloadHash = _hashOfText(jsonEncode(snapshot));
    final flightKey = _flightKey(source, profile.connectionKey);
    final pending = _flights[flightKey];
    if (pending != null) {
      final spec = _flightSpecs[flightKey]!;
      if (spec.kind == _OperationKind.refresh &&
          spec.payloadHash == payloadHash) {
        return pending;
      }
      return _conflict();
    }

    late final Future<AndroidConfigExecutionResult> future;
    final owner = (
      sourceKey: source,
      profileConnectionKey: profile.connectionKey,
      epoch: _selectionEpochs[source] ?? 0,
    );
    future =
        _refreshOnce(
          binding: binding,
          record: record,
          originalConfig: originalConfig,
          profile: profile,
          snapshot: snapshot,
          payloadHash: payloadHash,
        ).whenComplete(() async {
          _clearFlight(flightKey, future);
          await _settleFlight(owner);
        });
    _flights[flightKey] = future;
    _flightOwners[flightKey] = owner;
    _flightSpecs[flightKey] = _FlightSpec(
      payloadHash,
      false,
      _OperationKind.refresh,
    );
    _track(future);
    return future;
  }

  Future<AndroidConfigExecutionResult> _refreshOnce({
    required AndroidConfigExecutionBinding binding,
    required ConfigRecord record,
    required AppConfig originalConfig,
    required AndroidAdbProfile profile,
    required Map<String, Object?> snapshot,
    required String payloadHash,
  }) async {
    final bindingKey = _bindingKey(binding.sourceKey, profile.connectionKey);
    final selectionEpochAtStart = _selectionEpochs[binding.sourceKey] ?? 0;
    final token = binding.snapshotToken;
    final configHash = _hashOfText(jsonEncode(snapshot));
    await _ensurePublisher();
    final previousBody = _published[token];
    final bodyChanged =
        previousBody == null ||
        jsonEncode(previousBody) != jsonEncode(snapshot);
    _publish(token, snapshot);

    AndroidReverseLease? lease;
    var leaseIsNew = false;
    var importEntered = false;
    AndroidConfigExecutionBinding? written;
    try {
      final device = await _runtime.connect(
        profile,
        expectedUuid: binding.deviceUuid,
      );
      final acquired = await _acquire(
        device.uuid,
        localPort: _publisher.port,
        guestPort: binding.guestPort,
      );
      lease = acquired.lease;
      leaseIsNew = acquired.isNew;
      final actualPort = lease.guestPort;
      _leases[_leaseKey(device.uuid, actualPort)]!.users.add(bindingKey);

      importEntered = true;
      final imported = await _bridge.importPcConfig(
        device.reachableBase,
        snapshotUrl: _publisher.deviceUri(token, actualPort),
        name: record.name,
      );
      _requireUsableImport(imported);
      final conversion = await _bridge.fetchGatewayConfig(
        device.reachableBase,
        interfaceKey: imported.interfaceKey,
      );
      final overlay = overlayAndroidExecution(
        originalConfig,
        conversion.config,
      );
      final wasEnabled =
          _intentUnchanged(binding.sourceKey, selectionEpochAtStart) &&
          _store.enabledFor(binding.sourceKey)?.bindingKey ==
              binding.bindingKey;
      final completed = binding.copyWith(
        deviceUuid: device.uuid,
        configHash: configHash,
        guestPort: actualPort,
        interfaceKey: imported.interfaceKey.trim(),
      );
      await _store.putBinding(completed, enable: wasEnabled);
      written = completed;
      final enabled =
          wasEnabled &&
          _intentUnchanged(binding.sourceKey, selectionEpochAtStart) &&
          _store.enabledFor(binding.sourceKey)?.bindingKey == bindingKey;
      if (!_intentUnchanged(binding.sourceKey, selectionEpochAtStart)) {
        await _forgetIfRequested(completed, selectionEpochAtStart);
        await _disableIfSelected(binding.sourceKey, bindingKey);
      }
      _log.info(
        'Android 执行已刷新 source=${_fingerprint(binding.sourceKey)} '
        'device=${device.maskedUuid} guestPort=$actualPort '
        'copy=${imported.created ? 'created' : 'reused'} enabled=$enabled',
        scope: _scope,
      );
      return AndroidConfigExecutionResult(
        binding: completed,
        overlay: overlay,
        device: device,
      );
    } catch (error) {
      await _rollbackRefresh(
        sourceKey: binding.sourceKey,
        bindingKey: bindingKey,
        token: token,
        previousBody: previousBody,
        bodyChanged: bodyChanged,
        importEntered: importEntered,
        lease: lease,
        leaseIsNew: leaseIsNew,
      );
      if (await _forgetIfRequested(written, selectionEpochAtStart)) {
        await _releaseBindingResources(written!, bindingKey);
      }
      rethrow;
    }
  }

  /// 清除选择，但**保留**绑定、token、端口与 Android 副本给下次启用。
  ///
  /// spec 要求同时清理本服务自己的 reverse/引用计数/发布：只放掉本源的租约用户，
  /// 没有别的绑定再用该 profile/guest 端口时才真正释放；发布同理按 token 引用计数。
  Future<void> disable(String sourceKey) async {
    _guardOpen();
    // 先抬 epoch：在途准备下一次检查就会看到「用户改主意」，不留中间窗口。
    _selectionEpochs[sourceKey] = (_selectionEpochs[sourceKey] ?? 0) + 1;
    final selected = _store.enabledFor(sourceKey);
    await _store.disable(sourceKey);
    if (selected != null && !_isBusy(sourceKey)) {
      await _releaseBindingResources(
        selected,
        _bindingKey(sourceKey, selected.profileConnectionKey),
      );
    }
    _log.info(
      'Android 执行已停用 source=${_fingerprint(sourceKey)}'
      '（绑定与副本保留，本服务 reverse 与快照已按引用计数清理）',
      scope: _scope,
    );
  }

  Future<void> _disableIfSelected(String sourceKey, String bindingKey) async {
    if (_store.enabledFor(sourceKey)?.bindingKey == bindingKey) {
      await _store.disable(sourceKey);
    }
  }

  Future<bool> _forgetIfRequested(
    AndroidConfigExecutionBinding? written,
    int epochAtStart,
  ) async {
    if (written == null ||
        (_forgetEpochs[written.bindingKey] ?? 0) <= epochAtStart ||
        !identical(
          _store.forSourceProfile(
            written.sourceKey,
            written.profileConnectionKey,
          ),
          written,
        )) {
      return false;
    }
    await _store.forget(written.sourceKey, written.profileConnectionKey);
    return true;
  }

  /// 该源是否有在途准备/刷新；有的话资源不能从它脚下抽走。
  bool _isBusy(String sourceKey) =>
      _flightOwners.values.any((owner) => owner.sourceKey == sourceKey);

  /// 飞行结束后结算迟到的绑定：用户已改主意就别让它继续占着 reverse/发布。
  Future<void> _settleFlight(
    ({String sourceKey, String profileConnectionKey, int epoch}) owner,
  ) async {
    if (_closed) return;
    if ((_selectionEpochs[owner.sourceKey] ?? 0) != owner.epoch &&
        !_isBusy(owner.sourceKey)) {
      try {
        final binding = _store.forSourceProfile(
          owner.sourceKey,
          owner.profileConnectionKey,
        );
        if (binding != null &&
            _store.enabledFor(owner.sourceKey)?.bindingKey !=
                binding.bindingKey) {
          await _releaseBindingResources(
            binding,
            _bindingKey(owner.sourceKey, owner.profileConnectionKey),
          );
        }
      } catch (error) {
        _log.warning(
          'Android 执行清理已取消绑定的资源失败: ${_sanitizeError(error)}',
          scope: _scope,
        );
      }
    }
    await _releaseIdleLeases();
  }

  /// 没有绑定再引用的 reverse 租约就是垃圾（停用/删除与在途操作交错后的收尾）。
  Future<void> _releaseIdleLeases() async {
    for (final entry in _leases.entries.toList()) {
      if (entry.value.users.isNotEmpty) continue;
      _leases.remove(entry.key);
      await _releaseLease(entry.value);
    }
  }

  /// 起飞后用户意图是否仍未变（停用/删除算变，服务关闭算变）。
  ///
  /// 只比选择值不够：首个 pending 的起点和「飞行中停用」都是 null。
  bool _intentUnchanged(String sourceKey, int epochAtStart) =>
      !_closed && (_selectionEpochs[sourceKey] ?? 0) == epochAtStart;

  /// 放弃某条绑定的执行资源：reverse 用户与发布，绑定记录本身保留以便复用。
  Future<void> _releaseBindingResources(
    AndroidConfigExecutionBinding binding,
    String bindingKey,
  ) async {
    final leaseKey = _leaseKey(binding.deviceUuid, binding.guestPort);
    final lease = _leases[leaseKey];
    if (lease != null) {
      lease.users.remove(bindingKey);
      if (lease.users.isEmpty) {
        _leases.remove(leaseKey);
        await _releaseLease(lease);
      }
    }
    final tokenStillUsed = _store.bindings.any(
      (other) =>
          other.bindingKey != binding.bindingKey &&
          other.snapshotToken == binding.snapshotToken,
    );
    if (!tokenStillUsed) {
      _publisher.removeSnapshot(binding.snapshotToken);
      _published.remove(binding.snapshotToken);
    }
  }

  /// 删除绑定；只在没有其它绑定需要该 profile/快照时释放本服务资源。
  Future<void> forget(String sourceKey, String profileConnectionKey) async {
    _guardOpen();
    _selectionEpochs[sourceKey] = (_selectionEpochs[sourceKey] ?? 0) + 1;
    _forgetEpochs[_bindingKey(sourceKey, profileConnectionKey)] =
        _selectionEpochs[sourceKey]!;
    final removed = _store.forSourceProfile(sourceKey, profileConnectionKey);
    await _store.forget(sourceKey, profileConnectionKey);
    if (removed == null) return;

    final bindingKey = _bindingKey(sourceKey, profileConnectionKey);
    final leaseKey = _leaseKey(removed.deviceUuid, removed.guestPort);
    final lease = _leases[leaseKey];
    lease?.users.remove(bindingKey);
    final profileStillUsed = _store.bindings.any(
      (binding) => binding.profileConnectionKey == profileConnectionKey,
    );
    if (!profileStillUsed && lease != null && !_isBusy(sourceKey)) {
      if (lease.users.isEmpty) {
        await _releaseLease(lease);
        _leases.remove(leaseKey);
      }
    }

    final tokenStillUsed = _store.bindings.any(
      (binding) => binding.snapshotToken == removed.snapshotToken,
    );
    if (!tokenStillUsed) {
      _publisher.removeSnapshot(removed.snapshotToken);
      _published.remove(removed.snapshotToken);
    }
    _log.info(
      'Android 执行绑定已删除 source=${_fingerprint(sourceKey)} '
      'profile=${_fingerprint(profileConnectionKey)}',
      scope: _scope,
    );
  }

  /// 关闭：先等待在途准备/刷新，再释放本服务自己创建的 reverse 并关闭发布器。
  ///
  /// reverse 释放未确认时**不宣布成功**：发布器照常关闭后抛出脱敏的 [AppError]，
  /// 让调用方知道设备上可能残留端口转发（运行时已经把不确定性锁死在这里）。
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final active in _active.toList()) {
      await active;
    }
    Object? releaseFailure;
    for (final lease in _leases.values.toList()) {
      releaseFailure = await _releaseLease(lease) ?? releaseFailure;
    }
    _leases.clear();
    _published.clear();
    await _publisher.close();
    if (releaseFailure != null) {
      _log.warning(
        'Android 执行服务已关闭，但 reverse 清理未确认（设备上可能残留端口转发）: '
        '${_sanitizeError(releaseFailure)}',
        scope: _scope,
      );
      throw AppError(
        AppErrorKind.bridgeUnreachable,
        '安卓 reverse 清理未确认完成：设备上可能仍残留端口转发，请在安卓端手动检查',
        detail: 'reverse=${_sanitizeError(releaseFailure)}',
        cause: releaseFailure,
      );
    }
    _log.info('Android 执行服务已关闭（用户设备与 Android 副本未改动）', scope: _scope);
  }

  void _guardOpen() {
    if (_closed) {
      throw AppError(AppErrorKind.storage, 'Android 执行服务已关闭，请重新初始化');
    }
  }

  Future<AndroidConfigExecutionResult> _closedError() =>
      Future<AndroidConfigExecutionResult>.error(
        AppError(AppErrorKind.storage, 'Android 执行服务已关闭，请重新初始化'),
      );

  Future<AndroidConfigExecutionResult> _conflict() =>
      Future<AndroidConfigExecutionResult>.error(
        AppError(AppErrorKind.storage, '同一配置源正在以另一份内容准备，请稍后重试'),
      );

  void _clearFlight(String key, Future<AndroidConfigExecutionResult> future) {
    if (identical(_flights[key], future)) {
      _flights.remove(key);
      _flightSpecs.remove(key);
      _flightOwners.remove(key);
    }
  }

  void _track(Future<AndroidConfigExecutionResult> future) {
    late final Future<void> tracked;
    tracked = future
        .then<void>((_) {}, onError: (Object error, StackTrace stack) {})
        .whenComplete(() => _active.remove(tracked));
    _active.add(tracked);
  }

  Future<void> _ensurePublisher() async {
    if (!_publisher.running) await _publisher.start();
  }

  void _publish(String token, Map<String, Object?> snapshot) {
    _publisher.putSnapshot(token, snapshot);
    _published[token] = snapshot;
  }

  ({AndroidReverseLease lease, bool isNew}) _acquireResult(
    AndroidReverseLease lease,
    String uuid,
  ) {
    final key = _leaseKey(uuid, lease.guestPort);
    final existing = _leases[key];
    if (existing != null) return (lease: existing.lease, isNew: false);
    _leases[key] = _ServiceLease(lease);
    return (lease: lease, isNew: true);
  }

  Future<({AndroidReverseLease lease, bool isNew})> _acquire(
    String uuid, {
    required int localPort,
    required int guestPort,
  }) async {
    final lease = await _runtime.acquireReverse(
      uuid,
      localPort: localPort,
      guestPort: guestPort,
    );
    return _acquireResult(lease, uuid);
  }

  /// 释放一条租约；返回脱敏后的失败（null 表示已释放或本来不该释放）。
  ///
  /// 保留每条告警便于排障，但不再把失败吞掉：由调用方决定是否上报。
  Future<Object?> _releaseLease(_ServiceLease lease) async {
    if (!lease.lease.created) return null;
    try {
      await lease.lease.release();
      return null;
    } catch (error) {
      _log.warning(
        'Android 执行释放 reverse 失败（保留原状态）: ${_sanitizeError(error)}',
        scope: _scope,
      );
      return error;
    }
  }

  Future<void> _rollbackPrepare({
    required String sourceKey,
    required String profileConnectionKey,
    required String bindingKey,
    required String token,
    required bool tokenIsNew,
    required AndroidConfigExecutionBinding? previous,
    required bool pendingCommitted,
    required bool pendingCreated,
    required bool importEntered,
    required AndroidReverseLease? lease,
    required bool leaseIsNew,
    required String? uuid,
    required bool bodyChanged,
    required Map<String, Object?>? previousBody,
    required AndroidPcConfigImportResult? imported,
  }) async {
    // 设备可能已建副本（收据丢失/超时/被截断）：只有「请求还没发出去」的失败才敢删预留。
    final keepPending = importEntered || imported != null;
    if (pendingCreated && pendingCommitted && !keepPending) {
      try {
        await _store.forget(sourceKey, profileConnectionKey);
      } catch (error) {
        _log.warning(
          'Android 执行回滚 pending 绑定失败: ${_sanitizeError(error)}',
          scope: _scope,
        );
      }
    }
    if (previous == null && !keepPending) {
      final leaseKey = uuid == null || lease == null
          ? null
          : _leaseKey(uuid, lease.guestPort);
      final serviceLease = leaseKey == null ? null : _leases[leaseKey];
      serviceLease?.users.remove(bindingKey);
      if (serviceLease != null && serviceLease.users.isEmpty) {
        await _releaseLease(serviceLease);
        _leases.remove(leaseKey);
      }
    }
    if (bodyChanged) {
      if (importEntered) {
        // 设备侧可能已经按新正文建/改过副本（收据丢失也算）：把发布恢复成旧正文只能让
        // PC 自己看起来一致，证明不了设备一致。失败关闭：清掉选择，保留本次发布的正文。
        await _disableIfSelected(sourceKey, bindingKey);
        _log.warning(
          'Android 执行导入后失败且正文已变化：本次绑定失败关闭，'
          '不恢复旧正文以免与设备侧内容不一致',
          scope: _scope,
        );
      } else if (previousBody != null) {
        _publish(token, previousBody);
      } else if (previous?.isReady == true) {
        await _disableIfSelected(sourceKey, bindingKey);
        _log.warning('Android 执行内容已更新但旧正文不可恢复，本次绑定失败关闭', scope: _scope);
      } else if (!keepPending && tokenIsNew) {
        _publisher.removeSnapshot(token);
        _published.remove(token);
      }
    }
    if (imported != null) {
      _log.warning(
        'Android 执行失败，但设备上已创建非激活配置副本 '
        'id=${imported.id} key=#${_fingerprint(imported.interfaceKey)}（保留，未删除）',
        scope: _scope,
      );
    } else if (keepPending) {
      _log.warning(
        'Android 执行失败且未收到导入收据，设备上可能已创建副本；'
        '保留 pending 预留（同一 URL/端口）供重试复用',
        scope: _scope,
      );
    }
    if (leaseIsNew) {
      _log.debug('Android 执行回滚仅处理本次新建的反向租约', scope: _scope);
    }
  }

  Future<void> _rollbackRefresh({
    required String sourceKey,
    required String bindingKey,
    required String token,
    required Map<String, Object?>? previousBody,
    required bool bodyChanged,
    required bool importEntered,
    required AndroidReverseLease? lease,
    required bool leaseIsNew,
  }) async {
    if (bodyChanged) {
      if (importEntered) {
        await _disableIfSelected(sourceKey, bindingKey);
        _log.warning(
          'Android 执行刷新导入后失败且正文已变化：本次绑定失败关闭，'
          '不恢复旧正文以免与设备侧内容不一致',
          scope: _scope,
        );
      } else if (previousBody != null) {
        _publish(token, previousBody);
      } else {
        await _disableIfSelected(sourceKey, bindingKey);
        _log.warning('Android 执行刷新失败且旧正文不可恢复，本次绑定失败关闭', scope: _scope);
      }
    }
    if (leaseIsNew && lease != null) {
      final serviceLease = _leases[_leaseKey(lease.uuid, lease.guestPort)];
      if (serviceLease != null && serviceLease.users.isEmpty) {
        await _releaseLease(serviceLease);
        _leases.remove(_leaseKey(lease.uuid, lease.guestPort));
      }
    }
  }

  void _requireUsableImport(AndroidPcConfigImportResult imported) {
    if (imported.interfaceKey.trim().isEmpty) {
      throw AppError(
        AppErrorKind.bridgeNotAndroid,
        '安卓设备返回的配置副本缺少 interfaceKey，未启用',
      );
    }
    if (imported.active) {
      throw AppError(AppErrorKind.bridgeNotAndroid, '安卓设备把导入的配置设为了激活配置，已拒绝启用');
    }
  }

  Map<String, Object?> _snapshotFor(ConfigRecord record) =>
      androidExecutionSnapshot(
        record.json,
        origin: record.origin,
        contentType: record.contentType ?? '',
      );

  String _prepareIdentity(String sourceKey, ConfigRecord record) {
    final key = sourceKey.trim();
    if (key.isEmpty) {
      throw AppError(AppErrorKind.configInvalid, 'Android 执行缺少原始配置身份');
    }
    final recordKey = record.sourceKey.trim();
    if (recordKey.isNotEmpty && recordKey != key) {
      throw AppError(
        AppErrorKind.configInvalid,
        '原始配置身份与记录不一致，已拒绝执行',
        detail: 'source=${_fingerprint(key)}',
      );
    }
    _rejectIneligibleSource(key);
    return key;
  }

  String _refreshIdentity(
    AndroidConfigExecutionBinding binding,
    ConfigRecord record,
  ) {
    final recordKey = record.sourceKey.trim();
    if (recordKey.isNotEmpty && recordKey != binding.sourceKey) {
      throw AppError(AppErrorKind.configInvalid, '原始配置身份与绑定不一致，已拒绝刷新');
    }
    final key = binding.sourceKey.trim();
    if (key.isEmpty) {
      throw AppError(AppErrorKind.configInvalid, 'Android 执行绑定缺少原始配置身份');
    }
    _rejectIneligibleSource(key);
    return key;
  }

  void _rejectIneligibleSource(String sourceKey) {
    for (final prefix in const <String>['bridge|', 'bundle|']) {
      if (sourceKey.startsWith(prefix)) {
        throw AppError(
          AppErrorKind.configInvalid,
          'V1 不接受已由 Android/SDK 导入或本地 bundle 的配置来源',
        );
      }
    }
  }

  static String _bindingKey(String sourceKey, String profileKey) =>
      jsonEncode(<String>[sourceKey, profileKey]);

  static String _flightKey(String sourceKey, String profileKey) =>
      jsonEncode(<String>[sourceKey, profileKey]);

  static String _leaseKey(String uuid, int guestPort) => '$uuid|$guestPort';

  static String _newToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  static String _hashOfText(String text) =>
      sha256.convert(utf8.encode(text)).toString();

  static String _fingerprint(String text) => _hashOfText(text).substring(0, 8);

  static String _sanitizeError(Object error) => switch (error) {
    AppError(:final kind) => 'kind=${kind.name}',
    FormatException(:final message) => 'format=${message.split('\n').first}',
    _ => 'type=${error.runtimeType}',
  };
}
