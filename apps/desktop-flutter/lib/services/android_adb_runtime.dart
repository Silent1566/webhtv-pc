/// 受控 ADB/AVD 连接与端口授权（Android 已有环境 MVP · Task2）。
///
/// 契约要点（见 `docs/superpowers/specs/2026-11-24-android-adb-mvp.md`）：
/// - 网络/显式 AVD 启动模式：本模块**拥有**一个只监听回环的 `nodaemon` ADB 服务
///   进程，并只用 `--one-device` 过滤无关 USB 设备；不碰默认 5037。
/// - 已有设备/已运行 AVD 模式：只**借用**配置的本地 ADB 服务，用直接的主机协议
///   socket 读写，不触发 CLI 自动启动/停止，也不删除别人的转发。
/// - 只创建/清理本模块自己的 forward 与进程；失败/关闭不留下资源。
/// - 网关可达地址永远是 `127.0.0.1:<本地端口>`；设备自报 IP 仅供诊断。
library;

// 构造参数名是已发布的冻结接口（bridge/log），私有字段因此不能做初始化形参。
// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../core/android_adb_profile.dart';
import '../core/android_bridge.dart';
import '../core/app_error.dart';
import 'android_bridge_service.dart';
import 'log_service.dart';

/// 连接 `127.0.0.1:<port>` 的方式（测试可替换）。
typedef AdbSocketConnector = Future<Socket> Function(
  String host,
  int port, {
  required Duration timeout,
});

/// 子进程句柄抽象：只暴露所有权证明所需的最小能力。
abstract class AdbRuntimeProcess {
  int get pid;
  Future<int> get exitCode;
  Stream<List<int>> get stdout;
  Stream<List<int>> get stderr;
  bool kill();
}

/// 子进程宿主抽象（真实实现是 [Process.start]）。
abstract class AdbProcessHost {
  Future<AdbRuntimeProcess> start(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
  });

  /// 兜底强制结束（真实宿主发 SIGKILL；测试宿主实现为记录，避免误杀真实进程）。
  void forceKill(int pid);
}

/// 一次 reverse 获取的收据；借用行没有释放权，创建行只释放原租约。
class AndroidReverseLease {
  AndroidReverseLease._({
    required this.guestPort,
    required this.created,
    required this.uuid,
    Future<void> Function()? release,
  }) : _release = release;

  final int guestPort;
  final bool created;
  final String uuid;
  final Future<void> Function()? _release;
  bool _released = false;

  Future<void> release() async {
    if (_released) return;
    _released = true;
    if (created) await _release?.call();
  }
}

/// 受控 ADB/AVD 运行时。
class AndroidAdbRuntime {
  AndroidAdbRuntime({
    required AndroidBridgeService bridge,
    required LogService log,
    AdbProcessHost? processes,
    AdbSocketConnector? connect,
    Duration commandTimeout = const Duration(seconds: 12),
    Duration connectTimeout = const Duration(seconds: 60),
    int maxOutputBytes = 64 * 1024,
  }) : _bridge = bridge,
       _log = log,
       _processes = processes ?? _IoProcessHost(),
       _connect = connect ?? _ioConnect,
       _commandTimeout = commandTimeout,
       _connectTimeout = connectTimeout,
       _maxOutputBytes = maxOutputBytes;

  static const String _scope = 'adb';
  static const String _loopback = '127.0.0.1';
  static const String _avdNameProperty = 'ro.kernel.qemu.avd_name';

  final AndroidBridgeService _bridge;
  final LogService _log;
  final AdbProcessHost _processes;
  final AdbSocketConnector _connect;
  final Duration _commandTimeout;
  final Duration _connectTimeout;
  final int _maxOutputBytes;

  /// uuid → 已建立且未关闭的连接。
  final Map<String, _Connection> _connections = <String, _Connection>{};

  /// 连接描述键 → 进行中的准备（同一描述只允许一次准备）。
  final Map<String, _PendingConnect> _pendingConnects =
      <String, _PendingConnect>{};

  /// `serverPort|serial|remote` → 进行中的转发创建（并发合并）。
  final Map<String, Future<int>> _pendingForwards = <String, Future<int>>{};

  /// 本模块创建的转发：`serial|local` → 租约。
  final Map<String, _Lease> _leases = <String, _Lease>{};

  /// 本模块创建的 **reverse** 转发：`serial|guestPort` → 租约（与 host 转发分开）。
  final Map<String, _ReverseLease> _reverseLeases = <String, _ReverseLease>{};

  /// `serverPort|serial|guestPort|localPort` → 进行中的 reverse 创建（并发合并）。
  final Map<String, _PendingReverse> _pendingReverse =
      <String, _PendingReverse>{};

  /// 本模块拥有的 ADB 服务进程（所有权证明）。
  final List<_OwnedServer> _servers = <_OwnedServer>[];

  /// 显式启动的 AVD 进程：只保留管道，绝不 kill。
  final List<AdbRuntimeProcess> _launchedAvds = <AdbRuntimeProcess>[];

  /// 显式启动且仍由本模块自有服务承载的 AVD：AVD 名 → 自有服务。
  ///
  /// 断开连接时不杀用户 VM、也不杀它依赖的自有服务；这些服务只在 [close] 回收，
  /// 这样「断开后按 AVD 名重连」不会再启动第二个模拟器进程。
  final Map<String, _OwnedServer> _launchedAvdServers =
      <String, _OwnedServer>{};

  /// 本模块建立过的网关身份（含已退役/已关闭），用于失败关闭而不是回退。
  final Map<String, _GatewayRef> _knownGateways = <String, _GatewayRef>{};

  bool _closed = false;
  Future<void>? _closeFuture;
  AppError? _reverseCleanupError;

  /// 列出**已运行** ADB 服务上的设备序列号；不存在服务时返回空表，绝不启动。
  Future<List<String>> listDevices({
    String adbPath = '',
    int serverPort = 5037,
  }) async {
    final Socket socket;
    try {
      socket = await _connect(_loopback, serverPort, timeout: _commandTimeout);
    } on SocketException {
      _log.debug('ADB：127.0.0.1:$serverPort 没有运行中的服务，未自动启动', scope: _scope);
      return const <String>[];
    }
    final wire = _AdbWire(socket, _maxOutputBytes);
    try {
      final reply = await wire.query('host:devices').timeout(_commandTimeout);
      return _parseDevices(reply)
          .map((device) => device.serial)
          .toList(growable: false);
    } on _AdbFailure catch (error) {
      throw _error('无法读取 ADB 设备列表', error.message);
    } on _AdbProtocolException catch (error) {
      throw _error('ADB 服务返回的设备列表无法解析', error.message);
    } on TimeoutException {
      throw _error('ADB 设备列表读取超时');
    } finally {
      await wire.dispose();
    }
  }

  /// 用已安装 SDK 的 `emulator -list-avds` 列出精确 AVD 名称。
  Future<List<String>> listAvds({
    String adbPath = '',
    String emulatorPath = '',
    String avdHome = '',
  }) async {
    final emulator = _resolveEmulator(
      adbPath: adbPath,
      emulatorPath: emulatorPath,
    );
    final result = await _runCli(emulator, const [
      '-list-avds',
    ], environment: _avdEnvironment(avdHome));
    final names = <String>[];
    for (final line in result.stdout.split(RegExp(r'[\r\n]+'))) {
      final name = line.trim();
      if (name.isEmpty || names.contains(name)) continue;
      names.add(name);
    }
    return names;
  }

  /// 按描述连接设备；成功返回已探明的 [AndroidDevice]。
  ///
  /// [expectedUuid] 用于阻止「同一 ADB 端口换了一台设备」后被当成同一来源；
  /// 不一致时只回滚**本次尝试**创建的资源并抛错。[launchAvd] 只对 AVD 模式生效，
  /// 且必须显式为 `true` 才会启动用户已有的 AVD。
  ///
  /// 同一连接描述同时只允许一次准备：期望兼容（至少一侧未指定）的并发调用共享
  /// 同一个 Future，并在返回前各自复核 UUID；期望冲突的调用被显式拒绝，绝不因此
  /// 启动第二个自有 ADB 服务。
  Future<AndroidDevice> connect(
    AndroidAdbProfile profile, {
    String? expectedUuid,
    bool launchAvd = false,
  }) {
    if (_closed) {
      return Future<AndroidDevice>.error(_error('ADB 运行时已关闭，请重新初始化后再连接'));
    }
    final key = profile.connectionKey;
    final pending = _pendingConnects[key];
    if (pending != null) {
      if (pending.launchAvd != launchAvd ||
          !_compatibleExpectation(pending.expectedUuid, expectedUuid)) {
        return Future<AndroidDevice>.error(
          _error(
            '同一连接描述正在以另一个设备标识建立连接，请等待它完成后再试',
            'pending=${pending.expectedUuid ?? '未指定'} expected=${expectedUuid ?? '未指定'}',
          ),
        );
      }
      return pending.future.then(
        (device) => _checkExpectation(device, expectedUuid),
      );
    }
    final future = _connectOrReuse(
      profile,
      expectedUuid: expectedUuid,
      launchAvd: launchAvd,
    );
    _pendingConnects[key] = _PendingConnect(future, expectedUuid, launchAvd);
    return future
        .whenComplete(() {
          if (identical(_pendingConnects[key]?.future, future)) {
            _pendingConnects.remove(key);
          }
        })
        .then((device) => _checkExpectation(device, expectedUuid));
  }

  AndroidAdbProfile? profileForUuid(String uuid) {
    final connection = _connections[uuid];
    if (connection == null || connection.closed) return null;
    return connection.profile;
  }

  AndroidDevice? deviceForUuid(String uuid) {
    final connection = _connections[uuid];
    if (connection == null || connection.closed) return null;
    return connection.device;
  }

  /// 建立一条 **reverse** 转发：设备上的 `guestPort` → 本机 `localPort`。
  ///
  /// `reverse:` 是 transport 选择之后的**设备服务**（不是主机服务），所以这里不走
  /// host forward 解析器，而是 `host-serial:<serial>:transport` 后再发
  /// `reverse:forward:norebind:tcp:<guest>;tcp:<local>`（实测 adbd API 28 / adb 37.0.1
  /// 字节流；`norebind` 保证不会静默覆盖别人已占用的端口）。
  ///
  /// - [guestPort] 为 0 时由设备分配真实端口并返回（首次分配），调用方应持久化它；
  /// - [guestPort] 非 0 时用于**恢复**上次的固定端口（Android 侧 URL 不变）；
  /// - 设备上已有同端口且指向**当前**本机端口的行直接借用（不持有、不重绑）；
  /// - 同端口指向别的本机端口时**明确失败**，绝不隐式重绑或删除用户行。
  ///
  /// 每次操作都先用 [_verifySession] 复核服务/序列号/设备 UUID。
  Future<int> ensureReverse(
    String uuid, {
    required int localPort,
    int guestPort = 0,
  }) async => (await acquireReverse(
    uuid,
    localPort: localPort,
    guestPort: guestPort,
  )).guestPort;

  /// 获取 reverse 收据：只有本次绑定的行才返回 created=true 和释放权。
  /// 同一固定端口/本机端口的并发获取合并；其余调用仅借用，不共享释放权。
  Future<AndroidReverseLease> acquireReverse(
    String uuid, {
    required int localPort,
    int guestPort = 0,
  }) async {
    _guardOpen();
    if (localPort < 1 || localPort > 65535) {
      throw _error('reverse 本机端口无效', '本机端口必须在 1–65535 之间');
    }
    if (guestPort < 0 || guestPort > 65535) {
      throw _error('reverse 设备端口无效', '设备端口为 0（自动分配）或 1–65535');
    }
    final connection = _connections[uuid];
    if (connection == null || connection.closed) {
      throw _error('该安卓设备没有活动连接，无法建立 reverse 转发');
    }
    return _trackReverseOperation(
      connection,
      _prepareReverse(connection, guestPort, localPort),
    );
  }

  Future<T> _trackReverseOperation<T>(
    _Connection connection,
    Future<T> operation,
  ) async {
    final finished = operation.then<void>((_) {}, onError: (Object error) {});
    connection.reverseOperations.add(finished);
    try {
      return await operation;
    } finally {
      connection.reverseOperations.remove(finished);
    }
  }

  void _guardReverseConnection(_Connection connection) {
    _guardOpen();
    if (connection.closed ||
        !identical(_connections[connection.device.uuid], connection)) {
      throw _error('ADB 连接已关闭，reverse 获取已取消');
    }
  }

  Future<AndroidReverseLease> _prepareReverse(
    _Connection connection,
    int guestPort,
    int localPort,
  ) async {
    await _verifySession(connection);
    _guardReverseConnection(connection);

    if (guestPort != 0) {
      final key =
          '${connection.serverPort}|${connection.serial}|$guestPort|$localPort';
      final pending = _pendingReverse[key];
      if (pending != null) {
        if (pending.connection.closed) {
          throw _error('该 reverse 转发的原连接正在关闭，请等待清理完成后再试');
        }
        final receipt = await pending.future;
        _guardReverseConnection(connection);
        return AndroidReverseLease._(
          guestPort: receipt.guestPort,
          created: false,
          uuid: connection.device.uuid,
        );
      }
      final future = _acquireReverse(connection, guestPort, localPort);
      _pendingReverse[key] = _PendingReverse(connection, future);
      try {
        return await future;
      } finally {
        if (identical(_pendingReverse[key]?.future, future)) {
          _pendingReverse.remove(key);
        }
      }
    }
    // guest 0：每次调用都要一个新端口，不做并发合并。
    return _ownReverse(
      connection,
      _createReverse(connection, 0, localPort),
      localPort,
    );
  }

  Future<AndroidReverseLease> _acquireReverse(
    _Connection connection,
    int guestPort,
    int localPort,
  ) async {
    final existing = (await _listReverse(connection))
        .where((row) => row.guest == guestPort)
        .firstOrNull;
    _guardReverseConnection(connection);
    if (existing != null) {
      if (existing.local == localPort) {
        return AndroidReverseLease._(
          guestPort: guestPort,
          created: false,
          uuid: connection.device.uuid,
        );
      }
      throw _error(
        '设备上已有同一端口的 reverse 转发，但没有指向当前本机端口',
        '设备端口 $guestPort 已指向 127.0.0.1:${existing.local}，'
            '当前本机端口 $localPort；不会隐式重绑，也不会删除该行',
      );
    }
    return _ownReverse(
      connection,
      _createReverse(connection, guestPort, localPort),
      localPort,
    );
  }

  /// 释放本运行时为该设备 guest 端口创建的 reverse 转发。
  ///
  /// 只删除自己创建的行：借用行/用户行与其它配置的行一律保留。运行时已关闭或
  /// 该设备连接已失效时明确失败（不会悄悄重启客户端/服务）。
  Future<void> releaseReverse(String uuid, int guestPort) async {
    _guardOpen();
    if (guestPort < 1 || guestPort > 65535) {
      throw _error('reverse 设备端口无效', '设备端口必须在 1–65535 之间');
    }
    final connection = _connections[uuid];
    if (connection == null || connection.closed) {
      throw _error('该安卓设备没有活动连接，无法释放 reverse 转发');
    }
    return _trackReverseOperation(
      connection,
      _releaseReverseForConnection(connection, guestPort),
    );
  }

  Future<void> _releaseReverseForConnection(
    _Connection connection,
    int guestPort,
  ) async {
    await _verifySession(connection);
    _guardReverseConnection(connection);
    final key = '${connection.serial}|$guestPort';
    final lease = _reverseLeases[key];
    if (lease == null) return;
    if (!identical(lease.owner, connection.owner)) {
      _log.info('ADB：保留其它连接拥有的 reverse 行（设备端口 $guestPort）', scope: _scope);
      return;
    }
    _reverseLeases.remove(key);
    await _removeReverse(
      serverPort: connection.serverPort,
      serial: connection.serial,
      guestPort: guestPort,
    );
  }

  Future<AndroidReverseLease> _ownReverse(
    _Connection connection,
    Future<int> creation,
    int localPort,
  ) async {
    final actual = await creation;
    if (_closed ||
        connection.closed ||
        !identical(_connections[connection.device.uuid], connection)) {
      await _removeReverse(
        serverPort: connection.serverPort,
        serial: connection.serial,
        guestPort: actual,
      );
      throw _error('ADB 连接已关闭，已回滚本次 reverse 绑定');
    }
    final lease = _ReverseLease(
      serial: connection.serial,
      serverPort: connection.serverPort,
      guestPort: actual,
      localPort: localPort,
      owner: connection.owner,
    );
    _reverseLeases['${connection.serial}|$actual'] = lease;
    _log.info(
      'ADB：已建立 reverse 127.0.0.1:$localPort ← 设备端口 $actual'
      '（serial=${connection.serial}）',
      scope: _scope,
    );
    return AndroidReverseLease._(
      guestPort: actual,
      created: true,
      uuid: connection.device.uuid,
      release: () => _releaseReverseReceipt(connection, lease),
    );
  }

  Future<void> _releaseReverseReceipt(
    _Connection connection,
    _ReverseLease lease,
  ) => _trackReverseOperation(
    connection,
    _releaseOwnedReverseReceipt(connection, lease),
  );

  Future<void> _releaseOwnedReverseReceipt(
    _Connection connection,
    _ReverseLease lease,
  ) async {
    final key = '${lease.serial}|${lease.guestPort}';
    bool canRelease() =>
        !_closed &&
        !connection.closed &&
        identical(_connections[connection.device.uuid], connection) &&
        identical(lease.owner, connection.owner) &&
        identical(_reverseLeases[key], lease);
    if (!canRelease()) return;
    try {
      await _verifySession(connection);
    } on AppError {
      if (!canRelease()) return;
      rethrow;
    }
    if (!canRelease()) return;
    _reverseLeases.remove(key);
    await _removeReverse(
      serverPort: lease.serverPort,
      serial: lease.serial,
      guestPort: lease.guestPort,
    );
  }

  Future<int> _createReverse(
    _Connection connection,
    int guestPort,
    int localPort,
  ) async {
    final reply = await _reverseRequest(
      connection,
      (wire) => wire.reverseForward(connection.serial, guestPort, localPort),
      operation: 'reverse:forward:norebind',
      refusalMessage: '设备上该端口已被 reverse 占用，无法原子绑定',
      refusalHint: '不会退回可覆盖的重绑；请释放占用或改用自动分配端口（guestPort=0）',
    );
    if (guestPort != 0) return guestPort;
    final actual = int.tryParse(reply.trim());
    if (actual == null || actual < 1 || actual > 65535) {
      throw _latchReverseUncertainty(_error('ADB 未确认有效的 reverse 设备端口'));
    }
    return actual;
  }

  Future<List<_ReverseRow>> _listReverse(_Connection connection) async {
    final reply = await _reverseRequest(
      connection,
      (wire) => wire.reverseList(connection.serial),
      operation: 'reverse:list-forward',
    );
    return _parseReverseRows(reply);
  }

  Future<String> _reverseRequest(
    _Connection connection,
    Future<String> Function(_AdbWire wire) action, {
    required String operation,
    String? refusalMessage,
    String? refusalHint,
  }) async {
    final socket = await _tryOpenServer(connection.serverPort);
    if (socket == null) {
      throw _error(
        '未发现运行中的 ADB 服务（127.0.0.1:${connection.serverPort}）',
        '本模块不会自动启动共享 ADB 服务',
      );
    }
    final wire = _AdbWire(socket, _maxOutputBytes);
    try {
      return await action(wire).timeout(_commandTimeout);
    } on _AdbFailure catch (error) {
      final detail = _sanitize(error.message);
      throw _error(
        refusalMessage ?? '设备拒绝了 reverse 转发请求',
        refusalHint == null ? detail : '$refusalHint（设备消息：$detail）',
      );
    } on _AdbProtocolException catch (error) {
      if (operation == 'reverse:forward:norebind') {
        throw _latchReverseUncertainty(_error('reverse 绑定确认响应无效'));
      }
      throw _error('reverse 转发的响应无法解析', '$operation：${error.message}');
    } on TimeoutException {
      if (operation == 'reverse:forward:norebind') {
        throw _latchReverseUncertainty(_error('reverse 绑定确认超时'));
      }
      throw _error('reverse 转发超时（${_commandTimeout.inSeconds} 秒）', operation);
    } on SocketException {
      if (operation == 'reverse:forward:norebind') {
        throw _latchReverseUncertainty(_error('reverse 绑定确认连接中断'));
      }
      rethrow;
    } finally {
      await wire.dispose();
    }
  }

  /// 尽力清理一条 reverse 行（清理路径用：行已不存在/设备重置都视为成功）。
  Future<void> _removeReverse({
    required int serverPort,
    required String serial,
    required int guestPort,
  }) async {
    final socket = await _tryOpenServer(serverPort);
    if (socket == null) return;
    final wire = _AdbWire(socket, _maxOutputBytes);
    try {
      await wire.reverseKill(serial, guestPort).timeout(_commandTimeout);
    } on _AdbFailure {
      // 行已不存在（设备重置/已删除）：幂等成功。
    } on _AdbProtocolException {
      throw _latchReverseUncertainty(_error('reverse 清理确认响应无效'));
    } on TimeoutException {
      throw _latchReverseUncertainty(_error('reverse 清理确认超时'));
    } on SocketException {
      throw _latchReverseUncertainty(_error('reverse 清理确认连接中断'));
    } finally {
      await wire.dispose();
    }
  }

  /// 释放本模块创建的 reverse 行：给了 [owner] 时只释放该连接创建的。
  Future<void> _releaseReverseLeases({Object? owner}) async {
    final targets = _reverseLeases.values
        .where((lease) => owner == null || identical(lease.owner, owner))
        .toList();
    for (final lease in targets) {
      _reverseLeases.remove('${lease.serial}|${lease.guestPort}');
      await _removeReverse(
        serverPort: lease.serverPort,
        serial: lease.serial,
        guestPort: lease.guestPort,
      );
    }
  }

  /// 该网关是否属于本模块：在役连接的网关，或本模块建立过的已退役网关。
  ///
  /// 只认精确的 HTTP(S) 回环起点（scheme + 规范化回环主机 + 端口）；未知地址
  /// （例如普通公网/本机其他端口）一律 `false`，交给普通策略。
  bool recognizesGateway(Uri gateway) {
    final ref = _gatewayRefFor(gateway);
    if (ref == null) return false;
    if (_knownGateways.containsKey(ref.key)) return true;
    return _connections.values.any(
      (connection) => !connection.closed && connection.gatewayRef == ref,
    );
  }

  /// 为一个**已证明属于本模块**的网关返回受控解析闭包。
  ///
  /// 闭包在创建时冻结：服务命名空间（`127.0.0.1:<port>`）、选定序列号、期望的
  /// 网关转发（local/remote）、逻辑起点（scheme + guest 端口）。每次调用都会重新
  /// 校验「服务在线 + 序列号仍是同一台 READY 设备 + 网关转发行仍在 + 网关仍指向
  /// 同一台 WebHTV」，任何一项不成立都抛错而不是回退到本机端口。
  ///
  /// 已退役/已关闭的受管网关仍然**可识别**：此时返回一个必定抛错的闭包（失败
  /// 关闭），而不是 `null`（`null` 会退回普通策略并可能连到本机同名端口）。
  /// [Uri] 不属于该逻辑起点时返回 `null`，由普通代理策略处理。
  Future<int?> Function(Uri)? resolverForGateway(
    Uri gateway, {
    required Uri logicalOrigin,
  }) {
    final ref = _gatewayRefFor(gateway);
    if (ref == null) return null;
    final origin = _logicalOriginFor(logicalOrigin);
    if (origin == null) return null;
    if (!_closed) {
      final matches = _connections.values
          .where(
            (connection) => !connection.closed && connection.gatewayRef == ref,
          )
          .toList();
      if (matches.length == 1) {
        final session = matches.single;
        return (Uri target) => _resolveManaged(session, origin, target);
      }
      if (matches.length > 1) {
        // 同一网关端口被多个连接声明：归属不明，失败关闭。
        return (Uri target) => Future<int?>.error(_notManaged());
      }
    }
    if (_knownGateways.containsKey(ref.key)) {
      return (Uri target) => Future<int?>.error(_notManaged());
    }
    return null;
  }

  /// 断开一台设备：只清理**该连接**创建的资源。
  ///
  /// 借用服务与用户的 AVD 原样保留；显式启动的 AVD 依赖的自有服务也不会被杀
  /// （只登记为可重连），直到 [close] 才回收。已发出的解析闭包与退役网关都失败
  /// 关闭。
  Future<void> disconnect(String uuid) async {
    final connection = _connections.remove(uuid);
    if (connection == null) return;
    try {
      await _dropConnection(connection);
    } on AppError catch (error) {
      throw _reverseCleanupError ?? error;
    }
  }

  /// 关闭本模块拥有的一切（服务进程/转发），不触碰借用服务与用户的 AVD。
  Future<void> close() => _closeFuture ??= _close().catchError((Object error) {
    throw _reverseCleanupError ?? error;
  });

  Future<void> _close() async {
    if (_closed) {
      if (_reverseCleanupError != null) throw _reverseCleanupError!;
      return;
    }
    _closed = true;
    final sessions = _connections.values.toList();
    _connections.clear();
    for (final session in sessions) {
      session.closed = true;
    }
    for (final pending in _pendingConnects.values.toList()) {
      _discard(pending.future);
    }
    _pendingConnects.clear();
    for (final pending in _pendingForwards.values.toList()) {
      _discard(pending);
    }
    _pendingForwards.clear();
    for (final pending in _pendingReverse.values.toList()) {
      _discard(pending.future);
    }
    _pendingReverse.clear();
    try {
      await Future.wait(sessions.map(_drainReverseOperations));
    } finally {
      await _releaseLeases();
      await _releaseReverseLeases();
      for (final server in _servers.toList()) {
        await _stopServer(server);
      }
      _launchedAvdServers.clear();
    }
    if (_reverseCleanupError != null) throw _reverseCleanupError!;
    _log.debug(
      'ADB：运行时关闭，清理 ${sessions.length} 个连接、${_knownGateways.length} 个已知网关',
      scope: _scope,
    );
  }

  // ---------------------------------------------------------------- 连接流程

  Future<AndroidDevice> _connectOrReuse(
    AndroidAdbProfile profile, {
    String? expectedUuid,
    required bool launchAvd,
  }) async {
    final existing = _connections.values
        .where(
          (connection) =>
              !connection.closed &&
              connection.profile.connectionKey == profile.connectionKey,
        )
        .firstOrNull;
    if (existing != null &&
        (expectedUuid == null || existing.device.uuid == expectedUuid)) {
      try {
        await _verifySession(existing);
        return existing.device;
      } on AppError {
        _connections.remove(existing.device.uuid);
        await _dropConnection(existing);
      }
    }
    return switch (profile.mode) {
      AndroidAdbMode.network => _connectNetwork(profile, expectedUuid),
      AndroidAdbMode.device => _connectDevice(profile, expectedUuid),
      AndroidAdbMode.avd => _connectAvd(
        profile,
        expectedUuid: expectedUuid,
        launchAvd: launchAvd,
      ),
    };
  }

  Future<AndroidDevice> _connectNetwork(
    AndroidAdbProfile profile,
    String? expectedUuid,
  ) async {
    final owned = await _startOwnedServer(profile.adbPath);
    final attempt = _Attempt(profile.target, owned.port);
    try {
      _guardOpen();
      await _hostConnect(owned.port, profile.target);
      await _waitForReady(owned.port, profile.target);
      final probe = await _probeGateway(
        profile,
        profile.target,
        owned.port,
        expectedUuid: expectedUuid,
        attempt: attempt,
      );
      return await _register(
        profile: profile,
        serial: profile.target,
        serverPort: owned.port,
        ownedServer: owned,
        probe: probe,
        attempt: attempt,
      );
    } catch (error) {
      await _releaseLeases(owner: attempt);
      await _stopServer(owned);
      rethrow;
    }
  }

  Future<AndroidDevice> _connectDevice(
    AndroidAdbProfile profile,
    String? expectedUuid,
  ) async {
    final serverPort = profile.serverPort;
    final devices = await _borrowedDevices(serverPort);
    final row = devices
        .where((device) => device.serial == profile.target)
        .firstOrNull;
    if (row == null) {
      throw _error(
        'ADB 服务中没有序列号为 ${profile.target} 的设备',
        '请确认设备已连接，或改用网络地址/AVD 名称模式',
      );
    }
    if (row.state != 'device') {
      throw _error(
        '设备 ${profile.target} 当前状态为 ${row.state}，无法连接',
        '请在设备上确认 USB 调试授权后重试',
      );
    }
    final attempt = _Attempt(profile.target, serverPort);
    final probe = await _probeGateway(
      profile,
      profile.target,
      serverPort,
      expectedUuid: expectedUuid,
      attempt: attempt,
    );
    return _register(
      profile: profile,
      serial: profile.target,
      serverPort: serverPort,
      ownedServer: null,
      probe: probe,
      attempt: attempt,
    );
  }

  Future<AndroidDevice> _connectAvd(
    AndroidAdbProfile profile, {
    String? expectedUuid,
    required bool launchAvd,
  }) async {
    // 先找**已经在运行**的同名 AVD：配置的借用服务 + 本模块显式启动后仍保留的服务。
    // 找到就复用，绝不因为上层的 launchAvd=true 再启动第二个模拟器进程。
    final found = await _findRunningAvd(profile, expectedUuid: expectedUuid);
    if (found.device != null) return found.device!;
    if (!launchAvd) {
      if (found.unreadable.isNotEmpty) {
        throw _error(
          '无法读取运行中 AVD 的名称，不能确认 ${profile.target}；请改用设备序列号模式',
          found.unreadable.join(', '),
        );
      }
      throw _error('没有发现名为 ${profile.target} 的运行中 AVD', '请先启动它，或改用设备序列号模式');
    }
    return _launchAvd(profile, expectedUuid);
  }

  /// 按**已核对的 AVD 名**查找运行中的设备（借用服务 + 保留的自有服务）。
  Future<({AndroidDevice? device, List<String> unreadable})> _findRunningAvd(
    AndroidAdbProfile profile, {
    String? expectedUuid,
  }) async {
    final ports = <int>{profile.serverPort};
    final retained = _launchedAvdServers[profile.target];
    if (retained != null && _servers.contains(retained)) {
      ports.add(retained.port);
    }
    final unreadable = <String>[];
    for (final serverPort in ports) {
      final List<_DeviceRow> devices;
      try {
        devices = await _borrowedDevices(serverPort);
      } on AppError {
        continue;
      }
      final matches = <String>[];
      for (final row in devices.where((device) => device.state == 'device')) {
        final name = await _readAvdName(serverPort, row.serial);
        if (name == null) {
          unreadable.add(row.serial);
          continue;
        }
        if (name == profile.target) matches.add(row.serial);
      }
      if (matches.length > 1) {
        throw _error(
          '同时存在多台名为 ${profile.target} 的运行中 AVD，无法确定目标',
          '请改用设备序列号模式',
        );
      }
      if (matches.isEmpty) continue;
      final serial = matches.single;
      final attempt = _Attempt(serial, serverPort);
      final probe = await _probeGateway(
        profile,
        serial,
        serverPort,
        expectedUuid: expectedUuid,
        attempt: attempt,
      );
      final device = await _register(
        profile: profile,
        serial: serial,
        serverPort: serverPort,
        ownedServer: retained != null && retained.port == serverPort
            ? retained
            : null,
        probe: probe,
        attempt: attempt,
        launchedAvdName: profile.target,
      );
      return (device: device, unreadable: unreadable);
    }
    return (device: null, unreadable: unreadable);
  }

  Future<AndroidDevice> _launchAvd(
    AndroidAdbProfile profile,
    String? expectedUuid,
  ) async {
    final names = await listAvds(
      adbPath: profile.adbPath,
      emulatorPath: profile.emulatorPath,
      avdHome: profile.avdHome,
    );
    if (!names.contains(profile.target)) {
      throw _error(
        '已安装的 SDK 中没有名为 ${profile.target} 的 AVD',
        names.isEmpty
            ? '请先在 SDK 中创建该 AVD，或改用设备序列号模式'
            : '可用 AVD：${names.join(', ')}',
      );
    }
    final owned = await _startOwnedServer(profile.adbPath);
    final attempt = _Attempt(profile.target, owned.port);
    try {
      _guardOpen();
      final emulator = _resolveEmulator(
        adbPath: profile.adbPath,
        emulatorPath: profile.emulatorPath,
      );
      final environment = <String, String>{
        'ANDROID_ADB_SERVER_PORT': '${owned.port}',
        if (profile.avdHome.trim().isNotEmpty)
          'ANDROID_AVD_HOME': profile.avdHome.trim(),
      };
      final AdbRuntimeProcess launched;
      try {
        launched = await _processes.start(emulator, [
          '-avd',
          profile.target,
        ], environment: environment);
      } on ProcessException catch (error) {
        throw _error('无法启动本机已安装的 AVD', _sanitize(error.message));
      }
      _trackLaunchedAvd(launched);
      final serial = await _waitForAvd(owned.port, profile.target);
      final probe = await _probeGateway(
        profile,
        serial,
        owned.port,
        expectedUuid: expectedUuid,
        attempt: attempt,
      );
      // 用户 VM 已启动：登记它依赖的自有服务，断开后可复用而不重启。
      _launchedAvdServers[profile.target] = owned;
      return await _register(
        profile: profile,
        serial: serial,
        serverPort: owned.port,
        ownedServer: owned,
        probe: probe,
        attempt: attempt,
        launchedAvdName: profile.target,
      );
    } catch (error) {
      await _releaseLeases(owner: attempt);
      _launchedAvdServers.remove(profile.target);
      await _stopServer(owned);
      rethrow;
    }
  }

  /// 注册新连接；同一 UUID 或同一连接描述的旧连接先被完整回收再替换。
  Future<AndroidDevice> _register({
    required AndroidAdbProfile profile,
    required String serial,
    required int serverPort,
    required _OwnedServer? ownedServer,
    required _GatewayProbe probe,
    required _Attempt attempt,
    String? launchedAvdName,
  }) async {
    final gatewayRef =
        _gatewayRefFor(Uri.parse(probe.device.reachableBase)) ??
        _GatewayRef(scheme: 'http', host: _loopback, port: probe.local);
    final connection = _Connection(
      profile: profile,
      serial: serial,
      serverPort: serverPort,
      ownedServer: ownedServer,
      device: probe.device,
      gatewayLocal: probe.local,
      gatewayRemote: profile.gatewayPort,
      gatewayRef: gatewayRef,
      owner: attempt,
      launchedAvdName: launchedAvdName,
    );
    final conflicts = _connections.values
        .where(
          (old) =>
              !old.closed &&
              (old.device.uuid == connection.device.uuid ||
                  old.profile.connectionKey == profile.connectionKey),
        )
        .toList();
    for (final old in conflicts) {
      _connections.remove(old.device.uuid);
      await _dropConnection(old);
    }
    _connections[connection.device.uuid] = connection;
    _knownGateways[gatewayRef.key] = gatewayRef;
    _log.info(
      'ADB：已连接 ${probe.device.name}（${probe.device.maskedUuid}）'
      ' serial=$serial gateway=127.0.0.1:${probe.local}'
      '${ownedServer == null ? ' 借用服务' : ' 自有服务'}',
      scope: _scope,
    );
    return probe.device;
  }

  // --------------------------------------------------------- 自有 ADB 服务

  Future<_OwnedServer> _startOwnedServer(String adbPath) async {
    final executable = _resolveAdb(adbPath);
    final port = await _freePort();
    final filter = 'webhtv-unmatched-${DateTime.now().microsecondsSinceEpoch}';
    final AdbRuntimeProcess process;
    try {
      process = await _processes.start(executable, [
        '-L',
        'tcp:$port',
        '--one-device',
        filter,
        'server',
        'nodaemon',
      ]);
    } on ProcessException catch (error) {
      throw _error(
        '无法启动本机 ADB 服务，请检查 SDK 路径',
        _sanitize(error.message.isEmpty ? executable : error.message),
      );
    }
    final owned = _OwnedServer(port, process);
    _servers.add(owned);
    final tail = _Tail();
    _drainInto(process.stderr, tail);
    _drainTrash(process.stdout);
    var exited = false;
    int? exitCode;
    unawaited(
      process.exitCode.then((code) {
        exited = true;
        exitCode = code;
      }),
    );
    final deadline = DateTime.now().add(_connectTimeout);
    while (true) {
      if (_closed) {
        await _stopServer(owned);
        throw _error('ADB 运行时已关闭，连接已取消');
      }
      if (await _portReady(port)) return owned;
      if (exited) {
        await _stopServer(owned);
        throw _error('ADB 服务进程启动失败（exit=$exitCode）', tail.text);
      }
      if (DateTime.now().isAfter(deadline)) {
        await _stopServer(owned);
        throw _error('ADB 服务启动超时', '127.0.0.1:$port');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  Future<void> _stopServer(_OwnedServer owned) async {
    _servers.remove(owned);
    owned.process.kill();
    try {
      await owned.process.exitCode.timeout(const Duration(milliseconds: 200));
      return;
    } on TimeoutException {
      // 真实 adb 在异常状态下可能不响应 SIGTERM：升级为强制结束，保证不残留自有进程。
      _log.warning('ADB：自有服务进程未在期限内核退，强制结束', scope: _scope);
    }
    _processes.forceKill(owned.process.pid);
    try {
      await owned.process.exitCode.timeout(const Duration(milliseconds: 500));
    } on TimeoutException {
      _log.error('ADB：自有服务进程无法结束（pid=${owned.process.pid}）', scope: _scope);
    }
  }

  Future<bool> _portReady(int port) async {
    try {
      final socket = await _connect(
        _loopback,
        port,
        timeout: const Duration(milliseconds: 500),
      );
      socket.destroy();
      return true;
    } on SocketException {
      return false;
    }
  }

  Future<int> _freePort() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    return port;
  }

  Future<void> _hostConnect(int serverPort, String target) async {
    // 实测 adb 37.0.1：host:connect:<host>:<port>（带 tcp: 前缀会被拒绝）。
    final reply = await _request(serverPort, 'host:connect:$target');
    if (!reply.startsWith('connected to') &&
        !reply.startsWith('already connected to')) {
      throw _error('无法连接到 ADB 网络设备 $target', _sanitize(reply));
    }
  }

  Future<void> _waitForReady(int serverPort, String serial) async {
    final deadline = DateTime.now().add(_connectTimeout);
    while (true) {
      _guardOpen();
      final devices = await _borrowedDevices(serverPort);
      final row = devices
          .where((device) => device.serial == serial)
          .firstOrNull;
      if (row != null && row.state == 'device') return;
      if (row != null && row.state == 'unauthorized') {
        throw _error('设备 $serial 未授权，无法连接', '请在设备上确认 USB 调试授权后重试');
      }
      if (DateTime.now().isAfter(deadline)) {
        throw _error(
          '等待 ADB 设备就绪超时',
          row == null ? '$serial 未出现在设备列表中' : '当前状态 ${row.state}',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  Future<String> _waitForAvd(int serverPort, String name) async {
    final deadline = DateTime.now().add(_connectTimeout);
    while (true) {
      _guardOpen();
      final devices = await _borrowedDevices(serverPort);
      for (final row in devices.where((device) => device.state == 'device')) {
        if (await _readAvdName(serverPort, row.serial) == name) {
          return row.serial;
        }
      }
      if (DateTime.now().isAfter(deadline)) {
        throw _error('等待 AVD $name 启动超时', '若它已在别处运行，请改用设备序列号模式');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  // ------------------------------------------------------------- 主机协议

  Future<String> _request(int serverPort, String service) async {
    final socket = await _openServer(serverPort);
    final wire = _AdbWire(socket, _maxOutputBytes);
    try {
      return await wire.query(service).timeout(_commandTimeout);
    } on _AdbFailure catch (error) {
      throw _error('ADB 服务拒绝了请求', _sanitize(error.message));
    } on _AdbProtocolException catch (error) {
      throw _error('ADB 服务的响应无法解析', error.message);
    } on TimeoutException {
      throw _error('ADB 命令超时（${_commandTimeout.inSeconds} 秒）');
    } finally {
      await wire.dispose();
    }
  }

  Future<Socket> _openServer(int serverPort) async {
    try {
      return await _connect(_loopback, serverPort, timeout: _commandTimeout);
    } on SocketException {
      throw _error(
        '未发现运行中的 ADB 服务（127.0.0.1:$serverPort）',
        '本模块不会自动启动共享 ADB 服务',
      );
    }
  }

  Future<List<_DeviceRow>> _borrowedDevices(int serverPort) async =>
      _parseDevices(await _request(serverPort, 'host:devices'));

  Future<List<_ForwardRow>> _listForwards(int serverPort) async =>
      _parseForwards(await _request(serverPort, 'host:list-forward'));

  /// 复用已有转发行（不持有），否则创建并由本次尝试/连接持有。
  ///
  /// [owner] 把租约归属到「这次尝试或这个连接」：失败回滚与断开只清理自己的
  /// 租约，同序列号上其他连接（甚至同一台设备的另一模式）的转发不受影响。
  Future<int> _ensureForward(
    int serverPort,
    String serial,
    int remote, {
    required Object owner,
  }) async {
    _guardOpen();
    for (final row in await _listForwards(serverPort)) {
      if (row.serial == serial && row.remote == remote) return row.local;
    }
    final key = '$serverPort|$serial|$remote';
    final pending = _pendingForwards[key];
    if (pending != null) return pending;
    final future = _createForward(serverPort, serial, remote);
    _pendingForwards[key] = future;
    try {
      final local = await future;
      _leases['$serial|$local'] = _Lease(
        serial: serial,
        local: local,
        serverPort: serverPort,
        remote: remote,
        owner: owner,
      );
      return local;
    } finally {
      if (identical(_pendingForwards[key], future)) {
        _pendingForwards.remove(key);
      }
    }
  }

  Future<int> _createForward(int serverPort, String serial, int remote) async {
    final reply = await _forwardRequest(
      serverPort,
      'host-serial:$serial:forward:tcp:0;tcp:$remote',
    );
    final local = int.tryParse(reply.trim().replaceFirst('tcp:', ''));
    if (local == null || local < 1 || local > 65535) {
      throw _error('ADB 未返回有效的本地转发端口', _sanitize(reply));
    }
    return local;
  }

  Future<bool> _removeForward(int serverPort, String serial, int local) async {
    final socket = await _tryOpenServer(serverPort);
    if (socket == null) return false;
    final wire = _AdbWire(socket, _maxOutputBytes);
    try {
      await wire
          .killForward('host-serial:$serial:killforward:tcp:$local')
          .timeout(_commandTimeout);
      return true;
    } on _AdbFailure {
      return false;
    } on _AdbProtocolException {
      return false;
    } on TimeoutException {
      return false;
    } finally {
      await wire.dispose();
    }
  }

  Future<String> _forwardRequest(int serverPort, String service) async {
    final socket = await _openServer(serverPort);
    final wire = _AdbWire(socket, _maxOutputBytes);
    try {
      return await wire.forward(service).timeout(_commandTimeout);
    } on _AdbFailure catch (error) {
      throw _error('ADB 服务拒绝了转发请求', _sanitize(error.message));
    } on _AdbProtocolException catch (error) {
      throw _error('ADB 转发的响应无法解析', error.message);
    } on TimeoutException {
      throw _error('ADB 转发超时');
    } finally {
      await wire.dispose();
    }
  }

  Future<Socket?> _tryOpenServer(int serverPort) async {
    try {
      return await _connect(_loopback, serverPort, timeout: _commandTimeout);
    } on SocketException {
      return null;
    }
  }

  /// 释放租约：默认全部；给了 [owner] 时只释放该次尝试/连接创建的租约。
  Future<void> _releaseLeases({Object? owner}) async {
    final targets = _leases.values
        .where((lease) => owner == null || identical(lease.owner, owner))
        .toList();
    for (final lease in targets) {
      _leases.remove('${lease.serial}|${lease.local}');
      await _removeForward(lease.serverPort, lease.serial, lease.local);
    }
  }

  Future<String?> _readAvdName(int serverPort, String serial) async {
    final Socket socket;
    try {
      socket = await _connect(_loopback, serverPort, timeout: _commandTimeout);
    } on SocketException {
      return null;
    }
    final wire = _AdbWire(socket, _maxOutputBytes);
    try {
      await wire.selectTransport(serial).timeout(_commandTimeout);
      final text = await wire
          .shell('getprop $_avdNameProperty')
          .timeout(_commandTimeout);
      final name = text.trim();
      return name.isEmpty ? null : name;
    } on _AdbFailure {
      return null;
    } on _AdbProtocolException {
      return null;
    } on TimeoutException {
      return null;
    } finally {
      await wire.dispose();
    }
  }

  // ------------------------------------------------------------- 受控解析

  Future<int?> _resolveManaged(
    _Connection session,
    _Origin origin,
    Uri target,
  ) async {
    if (_closed || session.closed) throw _notManaged();
    if (!_authorized(origin, target)) return null;
    try {
      await _verifySession(session);
      if (_closed || session.closed) throw _notManaged();
      for (final row in await _listForwards(session.serverPort)) {
        if (row.serial == session.serial && row.remote == origin.port) {
          return row.local;
        }
      }
      final local = await _ensureForward(
        session.serverPort,
        session.serial,
        origin.port,
        owner: session.owner,
      );
      if (_closed || session.closed) throw _notManaged();
      return local;
    } catch (_) {
      throw _notManaged();
    }
  }

  /// 只授权**同一个**逻辑起点：scheme 相同、目标端口等于起点端口（含默认
  /// 80/443）、且主机是严格解析出来的回环别名。[Uri] 的其他部分（path/query/
  /// header）由上层保留，本模块不重写。
  bool _authorized(_Origin origin, Uri target) {
    if (!_isHttpScheme(target.scheme) || target.scheme != origin.scheme) {
      return false;
    }
    if (target.userInfo.isNotEmpty) return false;
    if (_canonicalLoopback(target.host) == null) return false;
    if (target.port < 1 || target.port > 65535) return false;
    return target.port == origin.port;
  }

  bool _isHttpScheme(String scheme) => scheme == 'http' || scheme == 'https';

  /// 严格解析回环主机：`localhost`、`::1`、合法的 `127.a.b.c`（0–255，无前导零）。
  ///
  /// 不采用「以 127 开头就算回环」的宽松判断：`127.999.0.1` 之类的伪地址必须被
  /// 拒绝，否则会为不受控地址发放转发。
  String? _canonicalLoopback(String host) {
    final lower = host.toLowerCase();
    if (lower == 'localhost') return 'localhost';
    if (lower == '::1') return '::1';
    final parts = lower.split('.');
    if (parts.length != 4 || parts.first != '127') return null;
    for (final part in parts) {
      if (part.isEmpty || part.length > 3) return null;
      if (part.length > 1 && part.startsWith('0')) return null;
      final value = int.tryParse(part);
      if (value == null || value < 0 || value > 255) return null;
    }
    return parts.join('.');
  }

  /// guest 逻辑起点：scheme + 端口（缺省端口按 scheme 归一，:80/:443 与省略等价）。
  _Origin? _logicalOriginFor(Uri uri) {
    if (!_isHttpScheme(uri.scheme) || uri.userInfo.isNotEmpty) return null;
    final host = _canonicalLoopback(uri.host);
    if (host == null) return null;
    final port = uri.port;
    if (port < 1 || port > 65535) return null;
    return _Origin(scheme: uri.scheme, host: host, port: port);
  }

  /// 网关身份：精确的 http(s) 回环起点。
  _GatewayRef? _gatewayRefFor(Uri uri) {
    if (!_isHttpScheme(uri.scheme) || uri.userInfo.isNotEmpty) return null;
    final host = _canonicalLoopback(uri.host);
    if (host == null) return null;
    final port = uri.port;
    if (port < 1 || port > 65535) return null;
    return _GatewayRef(scheme: uri.scheme, host: host, port: port);
  }

  bool _compatibleExpectation(String? pending, String? wanted) =>
      pending == null || wanted == null || pending == wanted;

  AndroidDevice _checkExpectation(AndroidDevice device, String? expectedUuid) {
    if (expectedUuid == null ||
        expectedUuid.isEmpty ||
        device.uuid == expectedUuid) {
      return device;
    }
    throw _error(
      '该 ADB 设备上的 WebHTV 与已保存的设备不一致，请重新选择设备',
      '实际设备 ${device.maskedUuid}',
    );
  }

  AppError _notManaged() =>
      _error('已保存的 Android 网关转发已失效，请重新连接该设备', '不会回退到本机端口，以免读取到错误设备或本机其他服务');

  // --------------------------------------------------------------- 网关探测

  Future<_GatewayProbe> _probeGateway(
    AndroidAdbProfile profile,
    String serial,
    int serverPort, {
    String? expectedUuid,
    required _Attempt attempt,
  }) async {
    final local = await _ensureForward(
      serverPort,
      serial,
      profile.gatewayPort,
      owner: attempt,
    );
    AndroidDevice device;
    try {
      device = await _bridge.probeDevice('http://$_loopback:$local');
    } catch (_) {
      // 只回滚本次尝试创建的租约：同序列号上已有连接的转发必须保留。
      await _releaseLeases(owner: attempt);
      rethrow;
    }
    if (expectedUuid != null &&
        expectedUuid.isNotEmpty &&
        device.uuid != expectedUuid) {
      await _releaseLeases(owner: attempt);
      throw _error(
        '该 ADB 设备上的 WebHTV 与已保存的设备不一致，请重新选择设备',
        '实际设备 ${device.maskedUuid}',
      );
    }
    _guardOpen();
    return _GatewayProbe(device, local);
  }

  Future<void> _verifySession(_Connection connection) async {
    _guardOpen();
    if (connection.closed) throw _error('ADB 连接已关闭');
    final devices = await _borrowedDevices(connection.serverPort);
    final row = devices
        .where((device) => device.serial == connection.serial)
        .firstOrNull;
    if (row == null || row.state != 'device') {
      throw _error('ADB 设备 ${connection.serial} 已断开');
    }
    final forwards = await _listForwards(connection.serverPort);
    final alive = forwards.any(
      (row) =>
          row.serial == connection.serial &&
          row.local == connection.gatewayLocal &&
          row.remote == connection.gatewayRemote,
    );
    if (!alive) throw _error('ADB 网关转发已失效');
    // 序列号仍是 READY 不代表网关后面还是同一台 WebHTV：同一 ADB 端口/序列号可能被
    // 换成另一台设备（或换了应用实例）。这里重新核对 /device 的 UUID，不一致即失败
    // 关闭，绝不复用旧的本地端口。（不涉及签名/加密层面的 TOCTOU 保证。）
    final current = await _bridge.probeDevice(connection.device.reachableBase);
    if (current.uuid != connection.device.uuid) {
      throw _error(
        '该 ADB 网关现在指向另一台 WebHTV 设备，已停止使用旧端点',
        '实际设备 ${current.maskedUuid}',
      );
    }
  }

  Future<void> _dropConnection(_Connection connection) async {
    connection.closed = true;
    try {
      await _drainReverseOperations(connection);
    } finally {
      await _releaseLeases(owner: connection.owner);
      await _releaseReverseLeases(owner: connection.owner);
      final owned = connection.ownedServer;
      if (owned != null) {
        if (connection.launchedAvdName != null) {
          _launchedAvdServers[connection.launchedAvdName!] = owned;
        } else {
          await _stopServer(owned);
        }
      }
    }
  }

  Future<void> _drainReverseOperations(_Connection connection) async {
    final pending = connection.reverseOperations.toList();
    try {
      await Future.wait(pending).timeout(_connectTimeout + _commandTimeout * 6);
    } on TimeoutException {
      _latchReverseUncertainty(_error('reverse 操作未在清理期限内完成'));
    }
    if (_reverseCleanupError != null) throw _reverseCleanupError!;
  }

  AppError _latchReverseUncertainty(AppError cause) {
    _reverseCleanupError ??= AppError(
      AppErrorKind.bridgeUnreachable,
      'reverse 绑定或清理状态未确认，不能声明已清理',
      detail: '请手动检查设备 reverse 列表；不会删除归属未证明的规则',
      retryable: false,
      cause: cause,
    );
    return cause;
  }

  void _guardOpen() {
    if (_closed) throw _error('ADB 运行时已关闭，连接已取消');
  }

  // ---------------------------------------------------------------- 内部工具

  void _trackLaunchedAvd(AdbRuntimeProcess process) {
    // 用户 VM：只保留管道（避免写满阻塞），关闭时不 kill。
    _launchedAvds.add(process);
    _drainTrash(process.stdout);
    _drainTrash(process.stderr);
  }

  void _drainInto(Stream<List<int>> stream, _Tail tail) {
    stream.listen(
      (chunk) => tail.add(utf8.decode(chunk, allowMalformed: true)),
      onError: (Object _) {},
      cancelOnError: false,
    );
  }

  void _drainTrash(Stream<List<int>> stream) {
    stream.listen((chunk) {}, onError: (Object _) {}, cancelOnError: false);
  }

  AppError _error(String message, [String? detail]) => AppError(
    AppErrorKind.bridgeUnreachable,
    message,
    detail: detail,
    retryable: true,
  );

  List<_DeviceRow> _parseDevices(String reply) {
    final rows = <_DeviceRow>[];
    for (final line in reply.split(RegExp(r'[\r\n]+'))) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final fields = trimmed.split(RegExp(r'\s+'));
      if (fields.length < 2) continue;
      rows.add(_DeviceRow(fields.first, fields[1]));
    }
    return rows;
  }

  List<_ForwardRow> _parseForwards(String reply) {
    final rows = <_ForwardRow>[];
    for (final line in reply.split(RegExp(r'[\r\n]+'))) {
      final fields = line.trim().split(RegExp(r'\s+'));
      if (fields.length != 3) continue;
      if (!fields[1].startsWith('tcp:') || !fields[2].startsWith('tcp:')) {
        continue;
      }
      final local = int.tryParse(fields[1].substring(4));
      final remote = int.tryParse(fields[2].substring(4));
      if (local == null || remote == null) continue;
      rows.add(_ForwardRow(fields[0], local, remote));
    }
    return rows;
  }

  /// 解析 reverse 列表行：只取其中的两个 `tcp:` 字段（guest, local）。
  ///
  /// 真实 adbd 的行首是 host 标识（实测为 `host-<pid>`），不是设备序列号，所以
  /// 不能复用 host forward 的「三列 = serial local remote」解析。
  List<_ReverseRow> _parseReverseRows(String reply) {
    final rows = <_ReverseRow>[];
    for (final line in reply.split(RegExp(r'[\r\n]+'))) {
      final ports = <int>[];
      for (final token in line.trim().split(RegExp(r'\s+'))) {
        if (!token.startsWith('tcp:')) continue;
        final port = int.tryParse(token.substring(4));
        if (port != null && port >= 1 && port <= 65535) ports.add(port);
      }
      if (ports.length != 2) continue;
      rows.add(_ReverseRow(ports[0], ports[1]));
    }
    return rows;
  }

  String _resolveAdb(String adbPath) {
    final explicit = adbPath.trim();
    if (explicit.isNotEmpty) return explicit;
    for (final key in const ['ANDROID_SDK_ROOT', 'ANDROID_HOME']) {
      final value = Platform.environment[key];
      if (value == null || value.isEmpty) continue;
      final candidate = p.join(value, 'platform-tools', _adbExecutable);
      if (File(candidate).existsSync()) return candidate;
    }
    return _adbExecutable;
  }

  String _resolveEmulator({
    required String adbPath,
    required String emulatorPath,
  }) {
    final explicit = emulatorPath.trim();
    if (explicit.isNotEmpty) return explicit;
    final adb = adbPath.trim();
    if (adb.isNotEmpty) {
      final sibling = p.join(
        p.dirname(p.dirname(adb)),
        'emulator',
        _emulatorExecutable,
      );
      if (File(sibling).existsSync()) return sibling;
    }
    for (final key in const ['ANDROID_SDK_ROOT', 'ANDROID_HOME']) {
      final value = Platform.environment[key];
      if (value == null || value.isEmpty) continue;
      final candidate = p.join(value, 'emulator', _emulatorExecutable);
      if (File(candidate).existsSync()) return candidate;
    }
    return _emulatorExecutable;
  }

  Map<String, String>? _avdEnvironment(String avdHome) {
    final home = avdHome.trim();
    if (home.isEmpty) return null;
    return {'ANDROID_AVD_HOME': home};
  }

  String get _adbExecutable => Platform.isWindows ? 'adb.exe' : 'adb';

  String get _emulatorExecutable =>
      Platform.isWindows ? 'emulator.exe' : 'emulator';

  /// 有界执行一次本机 SDK 命令：超时/超限都杀掉自有进程并报错。
  Future<_CliResult> _runCli(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
  }) async {
    final AdbRuntimeProcess process;
    try {
      process = await _processes.start(
        executable,
        arguments,
        environment: environment,
      );
    } on ProcessException catch (error) {
      throw _error(
        '无法启动本机已安装的 Android 工具，请检查 SDK 路径',
        _sanitize(error.message.isEmpty ? executable : error.message),
      );
    } on FileSystemException catch (error) {
      throw _error(
        '无法启动本机已安装的 Android 工具，请检查 SDK 路径',
        _sanitize(error.message),
      );
    }
    final stdoutFuture = _collect(process.stdout);
    final stderrFuture = _collect(process.stderr);
    final work = () async {
      final stdoutText = await stdoutFuture;
      final stderrText = await stderrFuture;
      final code = await process.exitCode;
      return _CliResult(stdoutText, stderrText, code);
    }();
    try {
      final result = await work.timeout(_commandTimeout);
      if (result.exitCode != 0) {
        throw _error(
          'Android 工具命令失败（exit=${result.exitCode}）',
          _sanitize(result.stderr),
        );
      }
      return result;
    } on TimeoutException {
      process.kill();
      _discard(stdoutFuture);
      _discard(stderrFuture);
      throw _error('Android 工具命令超时（${_commandTimeout.inSeconds} 秒）');
    } on _OutputTooLarge catch (error) {
      process.kill();
      _discard(stdoutFuture);
      _discard(stderrFuture);
      throw _error('Android 工具输出超出上限', '${error.limit} 字节');
    }
  }

  Future<String> _collect(Stream<List<int>> stream) {
    final completer = Completer<String>();
    final builder = BytesBuilder();
    late StreamSubscription<List<int>> subscription;
    subscription = stream.listen(
      (chunk) {
        builder.add(chunk);
        if (builder.length > _maxOutputBytes && !completer.isCompleted) {
          completer.completeError(_OutputTooLarge(_maxOutputBytes));
          unawaited(subscription.cancel());
        }
      },
      onError: (Object error) {
        if (!completer.isCompleted) completer.completeError(error);
      },
      onDone: () {
        if (!completer.isCompleted) {
          completer.complete(
            utf8.decode(builder.takeBytes(), allowMalformed: true),
          );
        }
      },
      cancelOnError: true,
    );
    return completer.future;
  }

  void _discard(Future<Object?> future) {
    unawaited(future.then<void>((_) {}, onError: (Object _) {}));
  }

  String _sanitize(String text) {
    final flattened = text.replaceAll(RegExp(r'[\x00-\x1f\x7f]+'), ' ').trim();
    if (flattened.length <= 200) return flattened;
    return '${flattened.substring(0, 200)}…';
  }
}

class _Connection {
  _Connection({
    required this.profile,
    required this.serial,
    required this.serverPort,
    required this.ownedServer,
    required this.device,
    required this.gatewayLocal,
    required this.gatewayRemote,
    required this.gatewayRef,
    required this.owner,
    required this.launchedAvdName,
  });

  final AndroidAdbProfile profile;
  final String serial;
  final int serverPort;
  final _OwnedServer? ownedServer;
  final AndroidDevice device;
  final int gatewayLocal;
  final int gatewayRemote;

  /// 该连接的网关身份（精确 http(s) 回环起点）。
  final _GatewayRef gatewayRef;

  /// 该连接创建的转发的租约归属。
  final _Attempt owner;

  /// 显式启动的 AVD 名（含按名复用已启动者）；非 AVD 模式为 null。
  final String? launchedAvdName;

  /// 关闭/断开后置位：已发出的授权闭包据此失败关闭（墓碑）。
  bool closed = false;

  final Set<Future<void>> reverseOperations = <Future<void>>{};
}

class _PendingReverse {
  const _PendingReverse(this.connection, this.future);

  final _Connection connection;
  final Future<AndroidReverseLease> future;
}

/// 一次连接尝试：租约与回滚的归属标识（按对象身份比较）。
class _Attempt {
  const _Attempt(this.serial, this.serverPort);

  final String serial;
  final int serverPort;
}

/// 同一连接描述的进行中准备（用于合并并发调用）。
class _PendingConnect {
  const _PendingConnect(this.future, this.expectedUuid, this.launchAvd);

  final Future<AndroidDevice> future;
  final String? expectedUuid;
  final bool launchAvd;
}

/// 网关身份：精确的 http(s) 回环起点。
class _GatewayRef {
  const _GatewayRef({
    required this.scheme,
    required this.host,
    required this.port,
  });

  final String scheme;
  final String host;
  final int port;

  String get key => '$scheme://$host:$port';

  @override
  bool operator ==(Object other) =>
      other is _GatewayRef &&
      other.scheme == scheme &&
      other.host == host &&
      other.port == port;

  @override
  int get hashCode => Object.hash(scheme, host, port);

  @override
  String toString() => key;
}

class _OwnedServer {
  const _OwnedServer(this.port, this.process);

  final int port;
  final AdbRuntimeProcess process;
}

class _Lease {
  const _Lease({
    required this.serial,
    required this.local,
    required this.serverPort,
    required this.remote,
    required this.owner,
  });

  final String serial;
  final int local;
  final int serverPort;
  final int remote;

  /// 创建它的尝试/连接：回滚与断开只按它清理。
  final Object owner;
}

/// 本模块创建的 reverse 转发租约（设备 guest 端口 → 本机端口）。
class _ReverseLease {
  const _ReverseLease({
    required this.serial,
    required this.serverPort,
    required this.guestPort,
    required this.localPort,
    required this.owner,
  });

  final String serial;
  final int serverPort;
  final int guestPort;
  final int localPort;

  /// 创建它的连接：断开/关闭时只按它清理。
  final Object owner;
}

/// 设备侧一条 reverse 规则（列表顺序：guest, local）。
class _ReverseRow {
  const _ReverseRow(this.guest, this.local);

  final int guest;
  final int local;
}

/// 创建闭包时冻结的 guest 逻辑起点（scheme + 规范化回环主机 + 端口）。
class _Origin {
  const _Origin({required this.scheme, required this.host, required this.port});

  final String scheme;
  final String host;
  final int port;
}

class _GatewayProbe {
  const _GatewayProbe(this.device, this.local);

  final AndroidDevice device;
  final int local;
}

class _DeviceRow {
  const _DeviceRow(this.serial, this.state);

  final String serial;
  final String state;
}

class _ForwardRow {
  const _ForwardRow(this.serial, this.local, this.remote);

  final String serial;
  final int local;
  final int remote;
}

class _Tail {
  String _text = '';

  void add(String chunk) {
    _text += chunk;
    if (_text.length > 2048) _text = _text.substring(_text.length - 2048);
  }

  String get text => _text.replaceAll(RegExp(r'[\x00-\x1f\x7f]+'), ' ').trim();
}

class _CliResult {
  const _CliResult(this.stdout, this.stderr, this.exitCode);

  final String stdout;
  final String stderr;
  final int exitCode;
}

class _OutputTooLarge implements Exception {
  const _OutputTooLarge(this.limit);

  final int limit;
}

class _AdbFailure implements Exception {
  const _AdbFailure(this.message);

  final String message;
}

class _AdbProtocolException implements Exception {
  const _AdbProtocolException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 一条 ADB 主机协议连接（4 位十六进制长度帧）。
class _AdbWire {
  _AdbWire(this._socket, this._limit)
    : _iterator = StreamIterator<List<int>>(_socket);

  final Socket _socket;
  final int _limit;
  final StreamIterator<List<int>> _iterator;
  final List<int> _pending = <int>[];

  Future<void> send(String service) async {
    final bytes = utf8.encode(service);
    if (bytes.length > _limit) {
      throw const _AdbProtocolException('ADB 请求超出上限');
    }
    _socket.add(ascii.encode(bytes.length.toRadixString(16).padLeft(4, '0')));
    _socket.add(bytes);
    await _socket.flush();
  }

  /// 主机服务查询：状态行 + 长度帧负载。
  ///
  /// 实测 adb 37.0.1：成功时先写 4 字节 `OKAY`（无长度），随后再由具体命令
  /// 写 `<4 位十六进制长度><负载>`；失败时写 `FAIL<长度><消息>`。
  Future<String> query(String service) async {
    await send(service);
    await _status();
    return _framed();
  }

  /// `forward`：状态行 + 命令自身状态行 + 长度帧端口。
  Future<String> forward(String service) async {
    await send(service);
    await _status();
    await _status();
    return _framed();
  }

  /// `killforward`：状态行 + 命令自身状态行（无负载）。
  Future<void> killForward(String service) async {
    await send(service);
    await _status();
    await _status();
  }

  /// 选定 transport 后，后续设备服务必须**带长度帧**（实测 37.0.1）。
  Future<void> selectTransport(String serial) async {
    await send('host-serial:$serial:transport');
    await _status();
  }

  /// 设备侧 shell：状态行 + 原始输出（无长度帧，读到 EOF）。
  Future<String> shell(String command) async {
    await send('shell:$command');
    await _status();
    return drain();
  }

  /// 设备侧 reverse 转发，**原子 no-rebind**（实测 adbd API 28 / adb 37.0.1）：
  ///
  /// 应答（`selectTransport` 已消费 transport 的 OKAY）：
  /// - `tcp:0` → 设备服务 OKAY + 命令 OKAY + 长度帧（设备分配的端口）；
  /// - 显式 guest 端口 → 设备服务 OKAY + 命令 OKAY，**没有**端口帧；
  /// - 该 guest 端口已存在（即使 local 相同）→ 设备服务 OKAY + 命令 `FAIL<len>消息`
  ///   （实测消息 `cannot rebind existing socket`），且**不改写**已有行。
  ///
  /// 因此创建一律带 `norebind:`：绝不用会被 adbd 静默覆盖的 `reverse:forward:tcp:…`，
  /// 也不在失败后回退成可覆盖形式。
  Future<String> reverseForward(String serial, int guest, int local) async {
    await selectTransport(serial);
    await send('reverse:forward:norebind:tcp:$guest;tcp:$local');
    await _status(); // 设备服务已接受
    await _status(); // reverse 命令状态（已存在 → FAIL 消息）
    return guest == 0 ? _framed() : '';
  }

  /// 设备侧 reverse 列表：服务状态 + 长度帧行（行首是 host 标识，不是设备序列号）。
  Future<String> reverseList(String serial) async {
    await selectTransport(serial);
    await send('reverse:list-forward');
    await _status();
    return _framed();
  }

  /// 设备侧 reverse 删除：设备服务 OKAY + 命令状态，无负载。
  ///
  /// transport 的 OKAY 已由 [selectTransport] 消费；实测 adb 37.0.1 行已不存在时
  /// 命令状态是 `FAIL<len>消息`（`listener 'tcp:G' not found`）。必须读完命令状态
  /// 再关闭，避免在共享 ADB 服务上留下半读连接。
  Future<void> reverseKill(String serial, int guest) async {
    await selectTransport(serial);
    await send('reverse:killforward:tcp:$guest');
    await _status();
    await _status();
  }

  Future<void> _status() async {
    final status = ascii.decode(await _readExact(4));
    if (status == 'OKAY') return;
    if (status == 'FAIL') {
      throw _AdbFailure(await _framed());
    }
    throw const _AdbProtocolException('ADB 响应不是 OKAY');
  }

  Future<String> _framed() async {
    final length = int.tryParse(ascii.decode(await _readExact(4)), radix: 16);
    if (length == null || length < 0) {
      throw const _AdbProtocolException('ADB 帧长度非法');
    }
    if (length > _limit) {
      throw const _AdbProtocolException('ADB 响应超出上限');
    }
    final payload = length == 0 ? const <int>[] : await _readExact(length);
    return utf8.decode(payload, allowMalformed: true);
  }

  /// 读到对端关闭为止（shell 输出无长度帧）。
  Future<String> drain() async {
    final builder = BytesBuilder();
    if (_pending.isNotEmpty) {
      builder.add(_pending);
      _pending.clear();
    }
    while (true) {
      if (builder.length > _limit) {
        throw const _AdbProtocolException('ADB 输出超出上限');
      }
      if (!await _iterator.moveNext()) break;
      builder.add(_iterator.current);
    }
    if (builder.length > _limit) {
      throw const _AdbProtocolException('ADB 输出超出上限');
    }
    return utf8.decode(builder.takeBytes(), allowMalformed: true);
  }

  Future<List<int>> _readExact(int count) async {
    while (_pending.length < count) {
      if (!await _iterator.moveNext()) {
        throw const _AdbProtocolException('ADB 服务提前关闭连接');
      }
      _pending.addAll(_iterator.current);
    }
    final bytes = _pending.sublist(0, count);
    _pending.removeRange(0, count);
    return bytes;
  }

  Future<void> dispose() async {
    try {
      await _iterator.cancel();
    } on StateError {
      // 已经取消/结束：没有需要释放的订阅。
    }
    try {
      // 优先正常关闭（FIN），避免共享/借用 ADB 服务收到突兀的 RST。
      await _socket.close();
    } on SocketException {
      _socket.destroy();
    }
  }
}

Future<Socket> _ioConnect(String host, int port, {required Duration timeout}) =>
    Socket.connect(host, port, timeout: timeout);

class _IoProcessHost implements AdbProcessHost {
  @override
  void forceKill(int pid) {
    try {
      Process.killPid(pid, ProcessSignal.sigkill);
    } on Object {
      // 进程已不存在，或平台不支持：没有可强杀的对象。
    }
  }

  @override
  Future<AdbRuntimeProcess> start(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
  }) async => _IoProcess(
    await Process.start(
      executable,
      arguments,
      environment: environment,
      runInShell: Platform.isWindows,
    ),
  );
}

class _IoProcess implements AdbRuntimeProcess {
  _IoProcess(this._process);

  final Process _process;

  @override
  int get pid => _process.pid;

  @override
  Future<int> get exitCode => _process.exitCode;

  @override
  Stream<List<int>> get stdout => _process.stdout;

  @override
  Stream<List<int>> get stderr => _process.stderr;

  @override
  bool kill() => _process.kill();
}
