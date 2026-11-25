// 夹具沿用与被测代码一致的可读参数名，故私有字段用显式赋值。
// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/services/android_adb_runtime.dart';
import 'package:webhtv_pc/services/android_bridge_service.dart';
import 'package:webhtv_pc/services/log_service.dart';

/// 一次受控 SDK 进程启动的参数记录。
class FakeSpawn {
  FakeSpawn(this.executable, this.arguments, this.environment);

  final String executable;
  final List<String> arguments;
  final Map<String, String>? environment;
}

/// 受控 SDK 进程宿主：记录参数，不执行真实二进制。
class FakeProcessHost implements AdbProcessHost {
  FakeProcessHost({this.onStart});

  final List<FakeSpawn> spawns = <FakeSpawn>[];
  final List<int> forcedKills = <int>[];
  Future<AdbRuntimeProcess> Function(
    String executable,
    List<String> arguments,
    Map<String, String>? environment,
  )?
  onStart;
  Object? startError;

  @override
  void forceKill(int pid) {
    forcedKills.add(pid);
  }

  @override
  Future<AdbRuntimeProcess> start(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
  }) async {
    spawns.add(FakeSpawn(executable, List<String>.of(arguments), environment));
    final error = startError;
    if (error != null) throw error;
    final handler = onStart;
    if (handler != null) return handler(executable, arguments, environment);
    return FakeProcess();
  }
}

/// 受控进程：可选自动退出，或只在 [kill] 时结束（模拟长期 ADB 服务）。
class FakeProcess implements AdbRuntimeProcess {
  FakeProcess({String stdout = '', String stderr = '', int exitCode = 0})
    : _onKill = null,
      _stubborn = false,
      _stdout = Stream<List<int>>.value(utf8.encode(stdout)),
      _stderr = Stream<List<int>>.value(utf8.encode(stderr)) {
    _exit.complete(exitCode);
  }

  /// 收到 SIGTERM 也不结束（模拟真实 adb 卡死），只有 [kill] 记录被调用。
  FakeProcess.stubborn()
    : _onKill = null,
      _stubborn = true,
      _stdout = const Stream<List<int>>.empty(),
      _stderr = const Stream<List<int>>.empty();

  FakeProcess.detached({Future<void> Function()? onKill})
    : _onKill = onKill,
      _stubborn = false,
      _stdout = const Stream<List<int>>.empty(),
      _stderr = const Stream<List<int>>.empty();

  final Stream<List<int>> _stdout;
  final Stream<List<int>> _stderr;
  final Future<void> Function()? _onKill;
  final Completer<int> _exit = Completer<int>();
  bool killed = false;
  final bool _stubborn;

  @override
  int get pid => 4242;

  @override
  Future<int> get exitCode => _exit.future;

  @override
  Stream<List<int>> get stdout => _stdout;

  @override
  Stream<List<int>> get stderr => _stderr;

  @override
  bool kill() {
    killed = true;
    final hook = _onKill;
    if (hook != null) unawaited(hook());
    if (!_stubborn && !_exit.isCompleted) _exit.complete(0);
    return true;
  }
}

/// 按真实 ADB 主机协议应答的受控服务器（每条请求一个连接）。
class FakeAdbServer {
  FakeAdbServer._(this._server) {
    _server.listen(_handle);
  }

  final ServerSocket _server;
  final List<String> requests = <String>[];

  /// transport 之后发出的 device 服务请求（shell / reverse:...）。
  final List<String> deviceRequests = <String>[];
  final List<String> shellRequests = <String>[];
  final List<String> killRequests = <String>[];

  /// 设备侧 reverse 规则：[guestPort, localPort]（真实 adbd 的 --list 顺序）。
  final List<List<String>> reverseRows = <List<String>>[];
  int nextReversePort = 38001;

  /// 把 reverse 应答拆成两个 TCP 分片，验证客户端重组。
  bool fragmentReverseFrames = false;
  bool reverseForwardFails = false;
  Future<void> Function()? beforeReverseForward;
  Future<void> Function()? afterReverseForward;
  Future<void> Function()? beforeReverseKill;
  Future<void> Function()? afterReverseKill;

  /// 模拟「列表之后、绑定之前」别人插入了一条同 guest 端口的行。
  bool reverseRaceInsertRow = false;
  final Map<String, String> devices = <String, String>{};
  final Map<String, String> avdNames = <String, String>{};

  /// [serial, localPort, remotePort]
  final List<List<String>> forwards = <List<String>>[];
  final List<Socket> _open = <Socket>[];

  String version = '0029';
  bool failConnect = false;
  bool brokenFrame = false;
  String? forwardReply;
  int nextPort = 34001;

  static Future<FakeAdbServer> bind({int port = 0}) async => FakeAdbServer._(
    await ServerSocket.bind(InternetAddress.loopbackIPv4, port),
  );

  int get port => _server.port;

  Future<void> close() async {
    for (final socket in _open) {
      socket.destroy();
    }
    _open.clear();
    await _server.close();
  }

  /// 一条新请求连接的建立与分派。
  Future<void> _handle(Socket socket) async {
    _open.add(socket);
    final wire = _Wire(socket);
    try {
      final service = await wire.readFrame();
      if (service == null) return;
      requests.add(service);
      await _serve(wire, service);
    } catch (_) {
      // 受控夹具：对端中途关闭不是被测行为。
    } finally {
      await wire.close();
      socket.destroy();
    }
  }

  Future<void> _serve(_Wire wire, String service) async {
    if (brokenFrame) {
      await wire.write('OKAY');
      return;
    }
    if (service == 'host:version') {
      await _okay(wire, version);
      return;
    }
    if (service == 'host:devices' || service == 'host:devices-l') {
      final lines = devices.entries
          .map((device) => '${device.key}\t${device.value}\n')
          .join();
      await _okay(wire, lines);
      return;
    }
    if (service == 'host:list-forward') {
      final lines = forwards
          .map((row) => '${row[0]} tcp:${row[1]} tcp:${row[2]}\n')
          .join();
      await _okay(wire, lines);
      return;
    }
    if (service.startsWith('host:connect:')) {
      final target = service
          .substring('host:connect:'.length)
          .replaceFirst('tcp:', '');
      if (failConnect) {
        await _fail(wire, 'unable to connect to $target');
        return;
      }
      devices[target] = 'device';
      await _okay(wire, 'connected to $target');
      return;
    }
    final forward = RegExp(r'^host-serial:(.+):forward:(tcp:\d+);(tcp:\d+)$')
        .firstMatch(service);
    if (forward != null) {
      // 实测 adb 37.0.1：外层状态 + 命令自身状态 + 裸端口号（无 tcp: 前缀）。
      final local = forwardReply ?? '${nextPort++}';
      forwards.add([forward.group(1)!, local, forward.group(3)!.substring(4)]);
      await _statusOnly(wire);
      await _okay(wire, local);
      return;
    }
    final kill = RegExp(r'^host(?:-serial:(.+))?:killforward:(tcp:\d+)$')
        .firstMatch(service);
    if (kill != null) {
      final serial = kill.group(1);
      final local = kill.group(2)!.substring(4);
      killRequests.add(service);
      forwards.removeWhere(
        (row) => row[1] == local && (serial == null || row[0] == serial),
      );
      // 实测 adb 37.0.1：外层状态 + 命令自身状态，无负载。
      await _statusOnly(wire);
      await _statusOnly(wire);
      return;
    }
    final transport = RegExp(r'^host-serial:(.+):transport$')
        .firstMatch(service);
    if (transport != null) {
      final serial = transport.group(1)!;
      if (!devices.containsKey(serial)) {
        await _fail(wire, "device '$serial' not found");
        return;
      }
      // 实测 adb 37.0.1：transport 只回 4 字节 OKAY；随后设备服务带长度帧。
      // 设备服务应答 = 服务状态(OKAY) + 命令自身载荷（见 _serveDevice）。
      await _statusOnly(wire);
      final command = await wire.readFrame();
      if (command == null) return;
      deviceRequests.add(command);
      await _serveDevice(wire, serial, command);
      return;
    }
    await _fail(wire, 'unknown host service');
  }

  /// 实测 adbd API 28 / adb 37.0.1（transport 的 OKAY 已由客户端消费，下面是之后的部分）：
  /// - `reverse:list-forward` → 设备服务 `OKAY` + `<len>` + 行（行首是 host 标识，不是序列号）
  /// - `reverse:forward:norebind:tcp:G;tcp:L` → 服务 `OKAY` + 命令 `OKAY`；仅 G=0 追加
  ///   `<len>`+端口。同 guest 已存在时命令段是 `FAIL`+长度+消息，且**不改写**已有行。
  /// - `reverse:killforward:tcp:G` → 服务 `OKAY` + 命令 `OKAY`（不存在时命令段是
  ///   `FAIL`+长度+消息）
  Future<void> _serveDevice(_Wire wire, String serial, String command) async {
    if (command.startsWith('shell:')) {
      shellRequests.add(command);
      await _send(wire, 'OKAY${avdNames[serial] ?? ''}\n');
      return;
    }
    if (command == 'reverse:list-forward') {
      final rows = reverseRows
          .map((row) => 'host-9 tcp:${row[0]} tcp:${row[1]}\n')
          .join();
      await _send(wire, 'OKAY${_frame(rows)}');
      return;
    }
    final forward = RegExp(r'^reverse:forward:(norebind:)?tcp:(\d+);tcp:(\d+)$')
        .firstMatch(command);
    if (forward != null) {
      await beforeReverseForward?.call();
      final noRebind = forward.group(1) != null;
      final requested = forward.group(2)!;
      final local = forward.group(3)!;
      if (reverseForwardFails) {
        await _send(wire, 'OKAYFAIL${_frame('cannot bind reverse')}');
        return;
      }
      if (reverseRaceInsertRow &&
          requested != '0' &&
          !reverseRows.any((row) => row[0] == requested)) {
        // 列表之后、绑定之前由别人插入：norebind 必须原子失败且不改写这行。
        reverseRows.add([requested, '49999']);
      }
      final exists =
          requested != '0' && reverseRows.any((row) => row[0] == requested);
      if (noRebind && exists) {
        // 实测 adbd（API 28）：同 guest 端口已存在时（即使 local 相同）拒绝。
        await _send(wire, 'OKAYFAIL${_frame('cannot rebind existing socket')}');
        return;
      }
      final guest = requested == '0' ? '${nextReversePort++}' : requested;
      reverseRows.removeWhere((row) => row[0] == guest);
      reverseRows.add([guest, local]);
      await afterReverseForward?.call();
      // 实测 37.0.1：tcp:0 回「服务+命令状态+长度帧端口」；显式端口只有两个状态行。
      await _send(
        wire,
        requested == '0' ? 'OKAYOKAY${_frame(guest)}' : 'OKAYOKAY',
      );
      return;
    }
    final kill = RegExp(r'^reverse:killforward:tcp:(\d+)$').firstMatch(command);
    if (kill != null) {
      await beforeReverseKill?.call();
      final guest = kill.group(1)!;
      final existed = reverseRows.any((row) => row[0] == guest);
      reverseRows.removeWhere((row) => row[0] == guest);
      await afterReverseKill?.call();
      await _send(
        wire,
        existed
            ? 'OKAYOKAY'
            : 'OKAYFAIL${_frame("listener 'tcp:$guest' not found")}',
      );
      return;
    }
    if (command == 'reverse:killforward-all') {
      reverseRows.clear();
      await _send(wire, 'OKAYOKAY');
      return;
    }
    await _send(wire, 'FAIL${_frame('unknown device service')}');
  }

  String _frame(String payload) =>
      '${utf8.encode(payload).length.toRadixString(16).padLeft(4, '0')}$payload';

  Future<void> _send(_Wire wire, String text) async {
    if (!fragmentReverseFrames) {
      await wire.write(text);
      return;
    }
    final head = text.substring(0, 2);
    await wire.write(head);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await wire.write(text.substring(2));
  }

  Future<void> _statusOnly(_Wire wire) async {
    await wire.write('OKAY');
  }

  Future<void> _okay(_Wire wire, [String payload = '']) async {
    final bytes = utf8.encode(payload);
    await wire.write(
      'OKAY${bytes.length.toRadixString(16).padLeft(4, '0')}$payload',
    );
  }

  Future<void> _fail(_Wire wire, [String payload = '']) async {
    final bytes = utf8.encode(payload);
    await wire.write(
      'FAIL${bytes.length.toRadixString(16).padLeft(4, '0')}$payload',
    );
  }
}

class _Wire {
  _Wire(this._socket) : _iterator = StreamIterator<List<int>>(_socket);

  final Socket _socket;
  final StreamIterator<List<int>> _iterator;
  final List<int> _buffer = <int>[];

  Future<void> write(String text) async {
    _socket.add(utf8.encode(text));
    await _socket.flush();
  }

  Future<bool> _fill(int need) async {
    while (_buffer.length < need) {
      if (!await _iterator.moveNext()) return false;
      _buffer.addAll(_iterator.current);
    }
    return true;
  }

  Future<String?> readFrame() async {
    if (!await _fill(4)) return null;
    final lengthHex = ascii.decode(_buffer.sublist(0, 4));
    _buffer.removeRange(0, 4);
    final length = int.tryParse(lengthHex, radix: 16);
    if (length == null) return null;
    if (length == 0) return '';
    if (!await _fill(length)) return null;
    final payload = utf8.decode(_buffer.sublist(0, length));
    _buffer.removeRange(0, length);
    return payload;
  }

  Future<String?> readUntil(bool Function(String text) done) async {
    final builder = BytesBuilder();
    while (true) {
      if (_buffer.isNotEmpty) {
        builder.add(_buffer);
        _buffer.clear();
        if (done(utf8.decode(builder.toBytes()))) {
          return utf8.decode(builder.takeBytes());
        }
      }
      if (!await _iterator.moveNext()) {
        return builder.isEmpty ? null : utf8.decode(builder.takeBytes());
      }
      _buffer.addAll(_iterator.current);
    }
  }

  Future<void> close() async {
    await _iterator.cancel();
  }
}

/// 受控 HTTP 桥接：只应答 `/device`。
AndroidBridgeService fakeBridge(
  LogService log, {
  required FutureOr<String> Function(Uri url) device,
}) {
  return AndroidBridgeService(
    log: log,
    timeout: const Duration(seconds: 3),
    client: MockClient((request) async {
      if (request.url.path == '/device') {
        return http.Response(
          await device(request.url),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      return http.Response('{}', 404);
    }),
  );
}

/// 一台设备的 `/device` 响应。
String deviceJson({
  String uuid = 'uuid-1',
  String name = '设备',
  String ip = '172.16.1.4',
  int type = 0,
}) => jsonEncode({
  'uuid': uuid,
  'name': name,
  'ip': ip,
  'type': type,
  'serial': '',
});

/// 一个当前没人监听的本地端口。
Future<int> unusedPort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}
