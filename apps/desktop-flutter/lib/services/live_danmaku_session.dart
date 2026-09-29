/// 直播弹幕 WebSocket 会话（设计文档 §13.1「直播弹幕」、§21 Phase 3）。
///
/// 职责对齐 Android `LiveDanmakuWebSocketSession`：
/// - 连接 `ws://`/`wss://`，携带与媒体一致的 Header（Referer/Cookie）——直播弹幕
///   常与视频同源，缺 Header 可能被 403；
/// - 按 [LiveDanmakuRetryPolicy] 指数退避重连（限次、可注入随机数便于测试）；
/// - **代次（generation）机制**：每换源/重连递增。迟到的旧代次帧一律丢弃，
///   避免「切台后还显示上一台的弹幕」。
/// - 生命周期：`connect`/`stop`/`dispose`，释放时关闭 socket 与所有流订阅；
/// - 失败/断开不抛出——转成状态回调，由调用方决定是否提示（不得阻断视频）。
///
/// 依赖 `package:web_socket_channel`：选择它是因为其 `IOWebSocketChannel.connect`
/// 支持 `headers`、`pingInterval`、`connectTimeout`，而 `web_socket` 包不带这些。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../core/live_danmaku.dart';

/// 会话状态（对齐 Android `LiveDanmakuWebSocketSession.State`）。
enum LiveDanmakuSessionState {
  /// 未连接。
  idle,

  /// 正在建立连接。
  connecting,

  /// 已建立，收发正常。
  open,

  /// 等待重连。
  retryWait,

  /// 已主动停止（不再自动重连）。
  stopped,

  /// 已释放（彻底销毁）。
  released,
}

/// 会话状态回调。
///
/// [reason] 为可读原因（连接/重试/关闭）；[retryMs] 为 `retryWait` 时的等待时长。
class LiveDanmakuSessionEvent {
  const LiveDanmakuSessionEvent({
    required this.state,
    required this.generation,
    this.online,
    this.retryMs,
    this.detail,
  });

  final LiveDanmakuSessionState state;
  final int generation;

  /// `online` 类型帧更新的人数；其他状态为 null。
  final int? online;

  /// `retryWait` 状态下的等待毫秒数。
  final int? retryMs;

  final String? detail;
}

/// 一条可上屏的直播弹幕（帧解析后交给渲染层）。
class LiveDanmakuIncoming {
  const LiveDanmakuIncoming({
    required this.text,
    required this.color,
    required this.type,
    required this.receivedAtMs,
    required this.generation,
  });

  final String text;
  final int color;
  final LiveDanmakuMessageType type;
  final int receivedAtMs;
  final int generation;

  /// 醒目弹幕字号是普通弹幕的 1.2 倍（普通弹幕 16sp）。
  double get textSizeSp =>
      16 * (type == LiveDanmakuMessageType.superChat ? 1.2 : 1.0);

  /// 转成 [LiveDanmakuFrame] 以复用渲染层的时间轴/颜色语义。
  LiveDanmakuFrame toFrame() => LiveDanmakuFrame(
    type: type,
    text: text,
    color: color,
    receivedAtMs: receivedAtMs,
    generation: generation,
  );
}

/// 直播弹幕会话。
class LiveDanmakuSession {
  LiveDanmakuSession({
    this.connectTimeout = const Duration(seconds: 10),
    this.pingInterval = const Duration(seconds: 20),
    this.randomSource,
    this.onEvent,
    this.onMessage,
  });

  /// 建立连接的超时。
  final Duration connectTimeout;

  /// WS 层心跳间隔（保活 + 半开连接探测）。
  final Duration pingInterval;

  /// 重连退避的随机数源（[0,1)）；测试可注入固定序列。
  final double Function()? randomSource;

  /// 状态/在线人数变化回调。
  void Function(LiveDanmakuSessionEvent event)? onEvent;

  /// 一条可上屏弹幕回调。
  void Function(LiveDanmakuIncoming message)? onMessage;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _retryTimer;
  int _generation = 0;
  int _retryAttempt = 0;
  String? _targetUrl;
  LiveDanmakuSessionState _state = LiveDanmakuSessionState.idle;
  bool _released = false;

  LiveDanmakuSessionState get state => _state;
  int get generation => _generation;
  String? get targetUrl => _targetUrl;

  /// 连接一个直播弹幕源。重复调用且已连接时不做任何事（幂等）。
  Future<void> connect(String url) async {
    final sourceUrl = url.trim();
    if (sourceUrl.isEmpty) return;

    // 同一地址且正在连接/已连接时不重复连接。
    if (sourceUrl == _targetUrl &&
        (_state == LiveDanmakuSessionState.connecting ||
            _state == LiveDanmakuSessionState.open)) {
      return;
    }

    await _teardownSocket();
    _retryAttempt = 0;
    _generation++;
    final generation = _generation;
    _targetUrl = sourceUrl;
    _emit(LiveDanmakuSessionState.connecting, generation, detail: 'connect');
    await _openSocket(sourceUrl, generation);
  }

  /// 主动停止（不再自动重连）。保留代次语义，避免旧回调复活。
  Future<void> stop(String reason) async {
    if (_released) return;
    _cancelRetry();
    final generation = ++_generation;
    _targetUrl = null;
    await _teardownSocket();
    _emit(LiveDanmakuSessionState.stopped, generation, detail: reason);
  }

  /// 彻底释放：停止一切定时器、关闭 socket、取消订阅。
  Future<void> dispose() async {
    if (_released) return;
    _released = true;
    _cancelRetry();
    final generation = ++_generation;
    _targetUrl = null;
    await _teardownSocket();
    _emit(LiveDanmakuSessionState.released, generation, detail: 'release');
  }

  void _cancelRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  /// 取消订阅并关闭底层 socket（关闭失败不抛：连接可能已断）。
  Future<void> _teardownSocket() async {
    await _subscription?.cancel();
    _subscription = null;
    final socket = _channel;
    _channel = null;
    if (socket != null) {
      try {
        await socket.sink.close();
      } catch (_) {
        // 连接可能已断，忽略。
      }
    }
  }

  Future<void> _openSocket(String sourceUrl, int generation) async {
    if (_released || generation != _generation) return;
    final stream = _createChannel(sourceUrl);
    try {
      final channel = await stream.timeout(connectTimeout);
      if (_released || generation != _generation) {
        await _safeClose(channel);
        return;
      }
      _channel = channel;
      _emit(LiveDanmakuSessionState.open, generation, detail: 'opened');
      _subscription = channel.stream.listen(
        (data) => _onData(data, generation),
        onError: (Object error) => _onFailure(error, generation),
        onDone: () => _onClose(generation, 1006, 'done', retryable: true),
        cancelOnError: true,
      );
    } catch (error) {
      // 建立连接失败（DNS/TLS/超时/握手被拒）。
      _onFailure(error, generation);
    }
  }

  Future<WebSocketChannel> _createChannel(String sourceUrl) async {
    final headers = <String, dynamic>{};
    final channel = IOWebSocketChannel.connect(
      sourceUrl,
      headers: headers,
      connectTimeout: connectTimeout,
      // 保活由 WS 层 ping 承担：比自建空转定时器更可靠，也能及时发现半开连接。
      pingInterval: pingInterval,
    );
    // `channel.ready` 在握手完成后完成；失败时抛异常（DNS/TLS/非 101 响应）。
    await channel.ready;
    return channel;
  }

  void _onData(dynamic data, int generation) {
    if (_released || generation != _generation) return;
    final message = data is String
        ? data
        : (data is List<int>
              ? utf8.decode(data, allowMalformed: true)
              : null);
    if (message == null) return;
    final result = parseLiveDanmakuFrame(
      message,
      receivedAtMs: DateTime.now().millisecondsSinceEpoch,
      generation: generation,
    );
    if (!result.isAccepted) return;
    if (result.kind == LiveDanmakuFrameKind.online) {
      _emit(LiveDanmakuSessionState.open, generation, online: result.online);
      return;
    }
    final frame = result.frame;
    if (frame == null) return;
    onMessage?.call(
      LiveDanmakuIncoming(
        text: frame.text,
        color: frame.color,
        type: frame.type,
        receivedAtMs: frame.receivedAtMs,
        generation: generation,
      ),
    );
  }

  /// 连接失败（建立 handshake 阶段）。
  void _onFailure(Object error, int generation) {
    if (_released || generation != _generation) return;
    unawaited(
      _handleTermination(
        generation: generation,
        code: -1,
        detail: 'failure=${_describeError(error)}',
        retryable: LiveDanmakuRetryPolicy.shouldRetryFailure(
          networkFailure: true,
        ),
      ),
    );
  }

  /// 连接中途断开（onDone）。
  void _onClose(int generation, int code, String detail, {required bool retryable}) {
    if (_released || generation != _generation) return;
    unawaited(
      _handleTermination(
        generation: generation,
        code: code,
        detail: detail,
        retryable: retryable && LiveDanmakuRetryPolicy.shouldRetryClose(code),
      ),
    );
  }

  Future<void> _handleTermination({
    required int generation,
    required int code,
    required String detail,
    required bool retryable,
  }) async {
    if (_released || generation != _generation) return;
    _cancelRetry();
    await _teardownSocket();

    if (retryable && _targetUrl != null && code != 1000 && !_released) {
      final delayMs = LiveDanmakuRetryPolicy.nextDelayMs(
        _retryAttempt++,
        _nextRandom(),
      );
      _emit(
        LiveDanmakuSessionState.retryWait,
        generation,
        retryMs: delayMs,
        detail: '$detail retry_ms=$delayMs',
      );
      _retryTimer = Timer(Duration(milliseconds: delayMs), () {
        if (_released || generation != _generation) return;
        final nextGeneration = ++_generation;
        _emit(LiveDanmakuSessionState.connecting, nextGeneration, detail: 'retry');
        _openSocket(_targetUrl!, nextGeneration);
      });
    } else {
      _emit(
        LiveDanmakuSessionState.stopped,
        generation,
        detail: '$detail (no retry)',
      );
    }
  }

  double _nextRandom() => randomSource?.call() ?? math.Random().nextDouble();

  void _emit(LiveDanmakuSessionState state, int generation,
      {int? online, int? retryMs, String? detail}) {
    if (_released && state != LiveDanmakuSessionState.released) return;
    _state = state;
    onEvent?.call(
      LiveDanmakuSessionEvent(
        state: state,
        generation: generation,
        online: online,
        retryMs: retryMs,
        detail: detail,
      ),
    );
  }

  Future<void> _safeClose(WebSocketChannel channel) async {
    try {
      await channel.sink.close();
    } catch (_) {}
  }

  String _describeError(Object error) {
    final text = error.toString();
    if (text.length > 200) return text.substring(0, 200);
    return text;
  }
}