/// 嗅探内核的测试替身：解析层与真实浏览器测试共用同一份假实现。
///
/// 纪律：这里的假实现只复述契约（事件顺序、停止语义），不实现任何"聪明"
/// 逻辑——否则测试断言的是假实现，而不是被考察的代码。
library;

import 'dart:async';

import 'package:webhtv_pc/core/sniff/sniff_types.dart';

/// 可编排的假引擎。
class FakeSniffEngine implements SniffEngine {
  FakeSniffEngine({
    required this.script,
    this.delay,
    this.startError,
    this.sessionCanReveal = true,
  });

  /// 立即成功的引擎。
  factory FakeSniffEngine.success(
    String url, {
    Map<String, String> headers = const {},
    String via = 'network',
  }) => FakeSniffEngine(
    script: (request) => [
      SniffCandidate(url: url, headers: headers, via: via),
    ],
  );

  /// 始终抛 [SniffUnavailableException]（模拟本机没有浏览器）。
  factory FakeSniffEngine.unavailable({String message = '本机没有可用的浏览器内核'}) =>
      FakeSniffEngine(
        startError: SniffUnavailableException(message),
        script: (request) => const [],
      );

  /// 永不产出事件（用于超时断言）。
  factory FakeSniffEngine.hanging() =>
      FakeSniffEngine(script: (request) => const []);

  /// 每个请求要发出的事件序列。
  final List<SniffEvent> Function(SniffRequest request) script;

  /// 事件发出前的延迟（用于竞速/超时用例）。
  final Duration? delay;

  /// 会话是否具备亮窗口的能力（无头用例传 `false`）。
  final bool sessionCanReveal;

  /// `start` 直接抛出。
  final Object? startError;

  final List<SniffRequest> requests = [];
  final List<FakeSniffSession> sessions = [];
  int disposeCount = 0;

  @override
  Future<SniffSession> start(SniffRequest request) async {
    requests.add(request);
    final error = startError;
    if (error != null) throw error;
    final session = FakeSniffSession(
      events: script(request),
      delay: delay,
      canReveal: sessionCanReveal,
    );
    sessions.add(session);
    return session;
  }

  @override
  Future<void> dispose() async => disposeCount++;
}

/// 假会话：记录 click/reveal/stop 次数，事件由构造参数给定。
class FakeSniffSession implements SniffSession {
  FakeSniffSession({
    required List<SniffEvent> events,
    Duration? delay,
    this.canReveal = true,
  }) {
    if (delay == null) {
      for (final event in events) {
        _controller.add(event);
      }
      _controller.close();
    } else {
      unawaited(_emitSlowly(events, delay));
    }
  }

  /// 是否具备亮出窗口的能力（无头实现应传 `false`）。
  @override
  final bool canReveal;

  final StreamController<SniffEvent> _controller = StreamController<SniffEvent>();
  int clickCount = 0;
  int revealCount = 0;
  int stopCount = 0;
  bool _closed = false;

  Future<void> _emitSlowly(List<SniffEvent> events, Duration delay) async {
    await Future<void>.delayed(delay);
    if (_closed) return;
    for (final event in events) {
      if (_closed) return;
      _controller.add(event);
    }
    await _controller.close();
  }

  @override
  Stream<SniffEvent> get events => _controller.stream;

  @override
  Future<void> click() async => clickCount++;

  @override
  Future<void> reveal() async => revealCount++;

  @override
  Future<void> stop() async {
    stopCount++;
    if (_closed) return;
    _closed = true;
    await _controller.close();
  }
}
