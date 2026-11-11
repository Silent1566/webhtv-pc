import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/reader/reader_models.dart';
import 'package:webhtv_pc/core/reader/tts_http_rule.dart';
import 'package:webhtv_pc/services/reader/edge_tts_engine.dart'
    show EdgeTtsEngine, gec, ssmlFor;
import 'package:webhtv_pc/services/reader/http_tts_engine.dart';

List<int> frame(String id, List<int> data) {
  final header = utf8.encode('X-RequestId:$id\r\nPath:audio\r\n');
  return [header.length >> 8, header.length & 255, ...header, ...data];
}

void main() {
  test('Edge GEC固定300秒窗口，SSML参数和XML转义', () {
    final now = DateTime.utc(2026, 11, 10);
    const token = '6A5AA1D4EAFF4E9FB37E23D68491D6F4';
    expect(gec(now, token), gec(now.add(const Duration(seconds: 1)), token));
    expect(gec(now, token), matches(RegExp(r'^[A-F0-9]{64}$')));
    final ssml = ssmlFor(
      'id',
      '甲<&',
      TtsOptions(rate: 1.5, pitch: .5, voice: 'zh-CN-YunxiNeural'),
    );
    expect(ssml, contains("rate='+50%'"));
    expect(ssml, contains("pitch='-50Hz'"));
    expect(ssml, contains('&lt;&amp;'));
  });
  test('Edge真实WebSocket fixture过滤串音并完成音频', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((request) async {
      final ws = await WebSocketTransformer.upgrade(request);
      ws.listen((event) {
        final text = event as String;
        if (!text.contains('Path:ssml')) return;
        final id = RegExp(r'X-RequestId:(\w+)').firstMatch(text)!.group(1)!;
        ws.add(frame('wrong', [9]));
        ws.add(frame(id, [1, 2, 3]));
        ws.add('X-RequestId:$id\r\nPath:turn.end\r\n\r\n');
      });
    });
    final engine = EdgeTtsEngine(
      endpoint: Uri.parse('ws://127.0.0.1:${server.port}'),
    );
    try {
      final audio = await engine.synthesize('你好', TtsOptions());
      expect(audio.bytes, [1, 2, 3]);
    } finally {
      await engine.dispose();
      await subscription.cancel();
      await server.close(force: true);
    }
  });
  test('Edge累积多帧且等待turn.end，重复收尾和串音不改变音频', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final firstFrameSent = Completer<void>();
    WebSocket? socket;
    String? requestId;
    final subscription = server.listen((request) async {
      final ws = socket = await WebSocketTransformer.upgrade(request);
      ws.listen((event) {
        if (!'$event'.contains('Path:ssml')) return;
        final id = requestId = RegExp(r'X-RequestId:(\w+)')
            .firstMatch('$event')!
            .group(1)!;
        ws.add(frame('wrong', [9]));
        ws.add(frame(id, [1, 2]));
        firstFrameSent.complete();
      });
    });
    final engine = EdgeTtsEngine(
      endpoint: Uri.parse('ws://127.0.0.1:${server.port}'),
    );
    try {
      var completed = false;
      final pending = engine.synthesize('多帧正文', TtsOptions()).then((audio) {
        completed = true;
        return audio;
      });
      await firstFrameSent.future;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final completedBeforeEnd = completed;
      socket!.add(frame(requestId!, [3, 4, 5]));
      socket!.add(frame('wrong', [8]));
      socket!.add('X-RequestId:wrong\r\nPath:turn.end\r\n\r\n');
      socket!.add('X-RequestId:$requestId\r\nPath:turn.end\r\n\r\n');
      socket!.add('X-RequestId:$requestId\r\nPath:turn.end\r\n\r\n');
      final audio = await pending;
      expect(completedBeforeEnd, isFalse, reason: '必须等turn.end而非首帧就完成');
      expect(audio.bytes, [1, 2, 3, 4, 5]);
    } finally {
      await engine.dispose();
      await socket?.close();
      await subscription.cancel();
      await server.close(force: true);
    }
  });
  test('Edge没有音频的turn.end失败，不伪称成功', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final sub = server.listen((request) async {
      final ws = await WebSocketTransformer.upgrade(request);
      ws.listen((event) {
        final id = RegExp(r'X-RequestId:(\w+)').firstMatch('$event')?.group(1);
        if (id != null) ws.add('X-RequestId:$id\r\nPath:turn.end\r\n\r\n');
      });
    });
    final engine = EdgeTtsEngine(
      endpoint: Uri.parse('ws://127.0.0.1:${server.port}'),
    );
    try {
      await expectLater(
        engine.synthesize('正文', TtsOptions()),
        throwsStateError,
      );
    } finally {
      await engine.dispose();
      await sub.cancel();
      await server.close(force: true);
    }
  });
  test('Edge单轮超时不连带失败同连接其他轮，取消关闭连接', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final slowReceived = Completer<void>();
    final otherReceived = Completer<String>();
    final disconnected = Completer<void>();
    WebSocket? socket;
    var requests = 0;
    final sub = server.listen((request) async {
      final ws = socket = await WebSocketTransformer.upgrade(request);
      ws.listen((event) {
        if (!'$event'.contains('Path:ssml')) return;
        final id = RegExp(r'X-RequestId:(\w+)').firstMatch('$event')!.group(1)!;
        requests++;
        if (requests == 1) {
          ws.add(frame(id, [7]));
          ws.add('X-RequestId:$id\r\nPath:turn.end\r\n\r\n');
        } else if (requests == 2) {
          slowReceived.complete();
        } else {
          otherReceived.complete(id);
        }
      }, onDone: () => disconnected.complete());
    });
    final engine = EdgeTtsEngine(
      endpoint: Uri.parse('ws://127.0.0.1:${server.port}'),
      turnTimeout: const Duration(seconds: 2),
    );
    try {
      await engine.synthesize('预热连接', TtsOptions());
      final timedOut = expectLater(
        engine.synthesize('超时段落', TtsOptions()),
        throwsStateError,
      );
      await slowReceived.future;
      await Future<void>.delayed(const Duration(seconds: 1));
      final other = engine.synthesize('另一段落', TtsOptions());
      final otherCheck = expectLater(
        other.then((audio) => audio.bytes),
        completion([1, 2]),
      );
      final id = await otherReceived.future;
      await timedOut;
      socket!.add(frame(id, [1, 2]));
      socket!.add('X-RequestId:$id\r\nPath:turn.end\r\n\r\n');
      await otherCheck;
      engine.cancel();
      await disconnected.future.timeout(const Duration(seconds: 2));
    } finally {
      await engine.dispose();
      await socket?.close();
      await sub.cancel();
      await server.close(force: true);
    }
  });
  test('HTTP取消中止响应体传输，取消后可再次合成', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final started = Completer<void>();
    HttpResponse? held;
    var count = 0;
    final sub = server.listen((request) async {
      request.response.headers.contentType = ContentType('audio', 'mpeg');
      if (count++ == 0) {
        held = request.response;
        request.response.add([1]);
        await request.response.flush();
        started.complete();
      } else {
        request.response.add([2, 3]);
        await request.response.close();
      }
    });
    final engine = HttpTtsEngine(
      TtsCustomConfig(url: 'http://127.0.0.1:${server.port}'),
    );
    try {
      final cancelled = expectLater(
        engine
            .synthesize('中止正文', TtsOptions())
            .timeout(const Duration(seconds: 2)),
        throwsA(isNot(isA<TimeoutException>())),
      );
      await started.future;
      engine.cancel();
      await cancelled;
      expect((await engine.synthesize('新正文', TtsOptions())).bytes, [2, 3]);
    } finally {
      await engine.dispose();
      try {
        await held?.close();
      } on SocketException {
        // 取消会主动关闭客户端连接，fixture 收尾可能已无对端。
      } on HttpException {
        // 等待响应头的连接也可能已被强制关闭。
      }
      await sub.cancel();
      await server.close(force: true);
    }
  });
  test('HTTP dispose中止等待响应头的请求', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final started = Completer<void>();
    HttpResponse? held;
    final sub = server.listen((request) {
      held = request.response;
      started.complete();
    });
    final engine = HttpTtsEngine(
      TtsCustomConfig(url: 'http://127.0.0.1:${server.port}'),
    );
    try {
      final cancelled = expectLater(
        engine
            .synthesize('正文', TtsOptions())
            .timeout(const Duration(seconds: 2)),
        throwsA(isNot(isA<TimeoutException>())),
      );
      await started.future;
      await engine.dispose();
      await cancelled;
    } finally {
      await engine.dispose();
      try {
        await held?.close();
      } on SocketException {
        // 取消会主动关闭客户端连接，fixture 收尾可能已无对端。
      } on HttpException {
        // 等待响应头的连接也可能已被强制关闭。
      }
      await sub.cancel();
      await server.close(force: true);
    }
  });
  test('custom安全子集支持嵌套编码、算术、POST和headers', () {
    final rule = TtsHttpRule.parse(
      TtsCustomConfig(
        url: 'https://example.com, {"method":"POST","body":"tex={{java.encodeURI(java.encodeURI(speakText))}}&spd={{(speakSpeed + 5) / 10 + 4}}","headers":{"X-Test":"yes"}}',
      ),
    );
    final request = rule.build('中文 a', 5);
    expect(request.method, 'POST');
    expect(request.body, contains('%25E4%25B8%25AD'));
    expect(request.body, contains('spd=5'));
    expect(request.headers['X-Test'], 'yes');
    expect(
      () => TtsHttpRule.parse(TtsCustomConfig(url: '@js:evil()')),
      throwsFormatException,
    );
    expect(
      () => TtsHttpRule.render('{{evil()}}', '正文', 5),
      throwsFormatException,
    );
  });
  test('HTTP合成验证音频类型并传递真实参数到本地fixture', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var text = '';
    var speed = '';
    var valid = true;
    final sub = server.listen((req) async {
      text = req.uri.queryParameters['text']!;
      speed = req.uri.queryParameters['spd']!;
      req.response.headers.contentType = ContentType(
        valid ? 'audio' : 'text',
        valid ? 'mpeg' : 'plain',
      );
      req.response.add(valid ? [1, 2, 3] : utf8.encode('拒绝'));
      await req.response.close();
    });
    final engine = HttpTtsEngine(
      TtsCustomConfig(
        url:
            'http://127.0.0.1:${server.port}?text={{java.encodeURI(speakText)}}&spd={{speakSpeed}}',
      ),
    );
    try {
      expect((await engine.synthesize('中文', TtsOptions(rate: 2))).bytes, [
        1,
        2,
        3,
      ]);
      expect(text, '中文');
      expect(speed, '7');
      valid = false;
      await expectLater(
        engine.synthesize('失败', TtsOptions()),
        throwsStateError,
      );
    } finally {
      await engine.dispose();
      await sub.cancel();
      await server.close(force: true);
    }
  });
}
