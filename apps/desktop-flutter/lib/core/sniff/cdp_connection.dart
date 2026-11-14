/// CDP（Chrome DevTools Protocol）连接：一条 WebSocket 上多路复用所有命令与事件。
///
/// 为什么不用现成的 cdp 包：需要的只是「JSON-RPC + 事件流」这三十行语义，
/// 而现成包会把 session、target 生命周期一并接管；嗅探只需能发命令、能收
/// `Network.requestWillBeSent`，多一层封装反而让超时与断线语义不可见。
///
/// 三条不可协商的语义：
/// - 每条命令独立 Future 与独立超时，某条挂住不拖累其它命令；
/// - 错误响应转 [CdpCallError]（带上内核给的 code）；
/// - socket 断开时所有 pending 立刻以 [CdpCallError] 失败——否则调用方会
///   永久等待一个已经不可能到来的响应。
library;

import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'sniff_transport.dart';

/// 默认单条命令超时（与启动就绪、导航等待同一量级）。
const Duration cdpDefaultTimeout = Duration(seconds: 20);

/// 连接 [webSocketUrl]；握手失败或超时都转成 [CdpCallError]。
Future<CdpConnection> connectCdp(
  Uri webSocketUrl, {
  Duration timeout = cdpDefaultTimeout,
}) async {
  final channel = WebSocketChannel.connect(webSocketUrl);
  try {
    await channel.ready.timeout(timeout);
  } on Object catch (error) {
    try {
      await channel.sink.close();
    } on Object {
      // 握手都没成，关闭失败没有需要上报的动作。
    }
    if (error is TimeoutException) {
      throw CdpCallError(
        'WebSocket.connect',
        '连接超时（${timeout.inMilliseconds}ms）：$webSocketUrl',
      );
    }
    throw CdpCallError('WebSocket.connect', '$webSocketUrl 连接失败：$error');
  }
  return WebSocketCdpConnection(channel);
}

/// 一条 WebSocket 上的 CDP 连接。
class WebSocketCdpConnection implements CdpConnection {
  WebSocketCdpConnection(this._channel) {
    _subscription = _channel.stream.listen(
      _handleMessage,
      onError: (Object error) => _failAll('连接异常：$error'),
      onDone: () => _failAll('连接已关闭'),
      cancelOnError: false,
    );
  }

  final WebSocketChannel _channel;
  final StreamController<CdpEvent> _events =
      StreamController<CdpEvent>.broadcast();
  final Map<int, _PendingCall> _pending = {};
  late final StreamSubscription<Object?> _subscription;

  int _nextId = 0;
  bool _closed = false;

  @override
  Stream<CdpEvent> get events => _events.stream;

  @override
  Future<Map<String, Object?>> send(
    String method, {
    Map<String, Object?>? params,
    String? sessionId,
    Duration timeout = cdpDefaultTimeout,
  }) {
    if (_closed) {
      return Future<Map<String, Object?>>.error(CdpCallError(method, '连接已关闭'));
    }
    final id = ++_nextId;
    final completer = Completer<Map<String, Object?>>();
    _pending[id] = _PendingCall(method: method, completer: completer);
    try {
      _channel.sink.add(
        jsonEncode({
          'id': id,
          'method': method,
          if (params != null && params.isNotEmpty) 'params': params,
          'sessionId': ?sessionId,
        }),
      );
    } on Object catch (error) {
      _pending.remove(id);
      return Future<Map<String, Object?>>.error(
        CdpCallError(method, '发送失败：$error'),
      );
    }
    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _pending.remove(id);
        throw CdpCallError(
          method,
          '等待响应超时（${timeout.inMilliseconds}ms）',
        );
      },
    );
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _failAll('连接已关闭');
    await _subscription.cancel();
    try {
      await _channel.sink.close();
    } on Object {
      // 对端已经断开时 sink 关闭会抛：close() 仍是幂等的成功。
    }
    if (!_events.isClosed) await _events.close();
  }

  void _handleMessage(Object? raw) {
    if (raw is! String) return;
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return;
    }
    if (decoded is! Map) return;
    final message = decoded.cast<String, Object?>();

    final id = message['id'];
    if (id is int) {
      final pending = _pending.remove(id);
      if (pending == null) return;
      final error = message['error'];
      if (error is Map) {
        final code = error['code'];
        pending.completer.completeError(
          CdpCallError(
            pending.method,
            '${error['message'] ?? '未知错误'}',
            code: code is int ? code : null,
          ),
        );
        return;
      }
      final result = message['result'];
      pending.completer.complete(
        result is Map ? result.cast<String, Object?>() : <String, Object?>{},
      );
      return;
    }

    final method = message['method'];
    if (method is! String || _events.isClosed) return;
    final params = message['params'];
    final sessionId = message['sessionId'];
    _events.add(
      CdpEvent(
        method: method,
        params: params is Map ? params.cast<String, Object?>() : const {},
        sessionId: sessionId is String ? sessionId : null,
      ),
    );
  }

  void _failAll(String reason) {
    if (_closed && _pending.isEmpty) return;
    final pending = _pending.values.toList(growable: false);
    _pending.clear();
    for (final call in pending) {
      if (call.completer.isCompleted) continue;
      call.completer.completeError(CdpCallError(call.method, reason));
    }
  }
}

class _PendingCall {
  _PendingCall({required this.method, required this.completer});

  final String method;
  final Completer<Map<String, Object?>> completer;
}
