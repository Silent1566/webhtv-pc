import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/ai_config.dart';
import 'package:webhtv_pc/services/ai_completion_client.dart';

void main() {
  test('cancel before send makes no HTTP request', () async {
    final token = AiCancellationToken()..cancel();
    final client = AiCompletionClient();
    addTearDown(client.close);
    final result = await client.complete(
      config: const AiConfig(
        enabled: true,
        endpoint: 'http://127.0.0.1:1',
        apiKey: 'fixture',
      ),
      prompt: 'hi',
      cancellationToken: token,
    );
    expect(result.message, '请求已取消');
    expect(result.ok, false);
  });
  test('cancel pending headers and stalled body; sibling client request stays usable', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final received = <Completer<void>>[Completer<void>(), Completer<void>()];
    var index = 0;
    server.listen((request) async {
      final i = index++;
      if (i < 2) {
        if (i == 1) {
          request.response.write('data: ');
          await request.response.flush();
        }
        received[i].complete();
      } else {
        request.response.write('{"output_text":"next"}');
        await request.response.close();
      }
    });
    final config = AiConfig(
      enabled: true,
      endpoint: 'http://127.0.0.1:${server.port}',
      apiKey: 'fixture',
    );
    final client = AiCompletionClient();
    addTearDown(client.close);
    for (var i = 0; i < 2; i++) {
      final token = AiCancellationToken();
      final pending = client.complete(
        config: config,
        prompt: 'hi',
        cancellationToken: token,
      );
      await received[i].future;
      token.cancel();
      final result = await pending.timeout(const Duration(seconds: 2));
      expect(result.message, '请求已取消');
      expect(result.ok, false);
      expect(result.text, '');
    }
    expect(
      (await client.complete(config: config, prompt: 'next')).text,
      'next',
    );
  });
  test('whole-call timeout covers stalled body and returns failure', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) {
      request.response.write('data: ');
      request.response.flush();
    });
    final client = AiCompletionClient();
    addTearDown(client.close);
    final result = await client.complete(
      config: AiConfig(
        enabled: true,
        endpoint: 'http://127.0.0.1:${server.port}',
        apiKey: 'fixture',
      ),
      prompt: 'hi',
      timeout: const Duration(milliseconds: 100),
    );
    expect(result.message, '请求超时');
    expect(result.ok, false);
  });
  test(
    'HTTP failures, empty JSON, SSE error and malformed never become success',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var count = 0;
      server.listen((request) async {
        final i = count++;
        request.response.statusCode = i == 0 ? 401 : 200;
        request.response.write(
          i == 0
              ? 'secret'
              : i == 1
              ? '{}'
              : i == 2
              ? 'data: {"type":"response.output_text.delta","delta":"partial"}\n\ndata: {"error":{"message":"bad secret"}}\n\n'
              : 'broken',
        );
        await request.response.close();
      });
      final client = AiCompletionClient();
      addTearDown(client.close);
      for (var i = 0; i < 4; i++) {
        final result = await client.complete(
          config: AiConfig(
            enabled: true,
            endpoint: 'http://127.0.0.1:${server.port}',
            apiKey: 'secret',
          ),
          prompt: 'hi',
        );
        expect(result.ok, false);
        expect(result.text, '');
        expect(result.message, isNot(contains('secret')));
      }
    },
  );
  for (final kind in ['delta', 'message']) {
    test(
      'structured Chat SSE $kind follows Android first-alias paragraph extraction',
      () {
        // 期望来自 Android `appendText`/`appendTextValue`
        // （AiCompletionClient.java:423–433,457–460）：首个有效直接别名，结构字段
        // 递归，段落逐段 trim 后以 '\n' 连接。
        final cases = <(Map<String, Object?>, String, String)>[
          (
            {
              'text': '',
              'parts': [
                {'text': 'hello'},
              ],
            },
            'hello',
            '空 text 不再遮蔽 parts',
          ),
          (
            {
              'text': 'hello',
              'parts': [
                {'text': ' world'},
              ],
            },
            'hello\nworld',
            'text 与 parts 是两个段落，不是空格连接',
          ),
          (
            {
              'text': {},
              'output_text': {'value': 'hello'},
              'parts': [
                {'text': ' world'},
              ],
            },
            'hello\nworld',
            '结构化 text/output_text 先于 parts 递归',
          ),
          (
            {
              'text': 'hello',
              'output_text': 'hello',
              'value': 'second',
            },
            'hello',
            '只消费第一个有效直接别名，禁止拼成 hello\nhello',
          ),
          (
            {
              'output_text': 'hello',
              'arguments': 'hello',
            },
            'hello',
            'text 缺失时 output_text 优先，arguments 不重复追加',
          ),
        ];
        for (final (content, expected, reason) in cases) {
          final sse = extractAiCompletionText(
            'data: ${jsonEncode({
              'choices': [
                {
                  kind: {'content': [content]},
                },
              ],
            })}\n\ndata: [DONE]\n\n',
            const AiConfig(protocol: AiProtocol.openAiChat),
          );
          expect(sse, expected, reason: 'SSE $kind · $reason');
          // 同一包装走普通 JSON 必须等价：Android 与普通 JSON 共用 appendText。
          final plain = extractAiCompletionText(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': [content]},
                },
              ],
            }),
            const AiConfig(protocol: AiProtocol.openAiChat),
          );
          expect(plain, expected, reason: '普通 JSON · $reason');
        }
      },
    );
  }
  test('native Gemini SSE keeps increment whitespace across events', () {
    const config = AiConfig(protocol: AiProtocol.geminiNative);
    String events(List<Map<String, Object?>> contents) => contents
        .map((content) => 'data: ${jsonEncode({'candidates': [{'content': content}]})}\n\n')
        .join();

    Map<String, Object?> parts(List<String> texts) => {
      'parts': [
        for (final text in texts) {'text': text},
      ],
    };

    // 原生 parts 是增量分片：事件边界空白必须原样保留。
    expect(
      extractAiCompletionText(
        '${events([
          parts(['hello ']),
          parts(['world']),
        ])}data: [DONE]\n\n',
        config,
      ),
      'hello world',
    );
    expect(
      extractAiCompletionText(
        '${events([
          parts(['hello']),
          parts([' world']),
        ])}data: [DONE]\n\n',
        config,
      ),
      'hello world',
    );
    expect(
      extractAiCompletionText(
        '${events([
          parts(['a']),
          parts([' b']),
        ])}data: [DONE]\n\n',
        config,
      ),
      'a b',
    );
    // 同一事件内的多 part 同样是分片。
    expect(
      extractAiCompletionText(
        '${events([
          parts(['a ', 'b']),
        ])}data: [DONE]\n\n',
        config,
      ),
      'a b',
    );
    // 纯空白分片同样是一次增量，不能被当成「空叶子」丢弃。
    expect(
      extractAiCompletionText(
        '${events([
          parts(['hello']),
          parts([' ']),
          parts(['world']),
        ])}data: [DONE]\n\n',
        config,
      ),
      'hello world',
    );
    expect(
      extractAiCompletionText(
        '${events([
          parts(['{"title":"hello']),
          parts([' ']),
          parts(['world"}']),
        ])}data: [DONE]\n\n',
        config,
      ),
      '{"title":"hello world"}',
    );
    // 严格 JSON 字符串跨事件拼接不能被 trim 成 helloworld。
    expect(
      extractAiCompletionText(
        '${events([
          parts(['{"title":"hello ']),
          parts(['world"}']),
        ])}data: [DONE]\n\n',
        config,
      ),
      '{"title":"hello world"}',
    );
  });
  for (final afterHeaders in [false, true]) {
    test(
      'cancellation closes actual TCP connection afterHeaders=$afterHeaders before client.close',
      () async {
        final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final sockets = <Socket>[];
        addTearDown(() async {
          for (final socket in sockets) {
            socket.destroy();
          }
          await server.close();
        });
        final ready = Completer<void>();
        final disconnected = Completer<void>();
        server.listen((socket) {
          sockets.add(socket);
          final request = StringBuffer();
          // 一次连接只允许写一套响应：分片请求会多次回调，标记必须在任何
          // await 之前同步置位，否则重入会对同一个 socket 再写一次而抛
          // `StreamSink is bound to a stream`。
          var responded = false;
          socket.listen(
            (bytes) async {
              request.write(utf8.decode(bytes));
              if (responded ||
                  !request.toString().contains('\r\n\r\n')) {
                return;
              }
              responded = true;
              try {
                if (afterHeaders) {
                  socket.write(
                    'HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n6\r\ndata: \r\n',
                  );
                  await socket.flush();
                }
              } on SocketException {
                // 取消已中断连接：断连本身由 onDone 断言覆盖。
              } finally {
                if (!ready.isCompleted) ready.complete();
              }
            },
            onDone: () {
              if (!disconnected.isCompleted) disconnected.complete();
            },
            onError: (Object error) {
              if (!disconnected.isCompleted) disconnected.complete();
            },
          );
        });
        final client = AiCompletionClient();
        addTearDown(client.close);
        final token = AiCancellationToken();
        final pending = client.complete(
          config: AiConfig(
            enabled: true,
            endpoint: 'http://127.0.0.1:${server.port}',
            apiKey: 'fixture',
          ),
          prompt: 'hi',
          cancellationToken: token,
        );
        await ready.future.timeout(const Duration(seconds: 2));
        token.cancel();
        final result = await pending.timeout(const Duration(seconds: 2));
        expect(result.message, '请求已取消');
        await disconnected.future.timeout(const Duration(seconds: 2));
      },
    );
  }
  test('whole SSE chat joins raw deltas without adding spaces or newlines', () {
    final body =
        ': ping\r\nevent: message\r\ndata: ${jsonEncode({
          'choices': [
            {
              'delta': {'content': '{"items":'},
            },
          ],
        })}\r\n\r\ndata: ${jsonEncode({
          'choices': [
            {
              'delta': {'content': ' []}'},
            },
          ],
        })}\n\ndata: [DONE]\n\n';
    expect(
      extractAiCompletionText(
        body,
        const AiConfig(protocol: AiProtocol.openAiChat),
      ),
      '{"items": []}',
    );
  });
  test('responses SSE snapshot replaces rather than repeats deltas', () {
    const body =
        'data: {"type":"response.output_text.delta","delta":"你"}\n\ndata: {"type":"response.output_text.delta","delta":"好"}\n\ndata: {"type":"response.completed","response":{"output_text":"你好"}}\n\n';
    expect(extractAiCompletionText(body, const AiConfig()), '你好');
  });
  test('anthropic SSE extracts text only and Gemini SSE handles multiline data', () {
    const anthropic =
        'data: {"type":"content_block_start","content_block":{"type":"text","text":""}}\n\ndata: {"type":"content_block_delta","delta":{"type":"text_delta","text":" hello "}}\n\ndata: {"type":"content_block_delta","delta":{"type":"input_json_delta","partial_json":"bad"}}\n\ndata: {"type":"content_block_delta","delta":{"type":"text_delta","text":"world"}}\n\n';
    expect(
      extractAiCompletionText(
        anthropic,
        const AiConfig(protocol: AiProtocol.anthropicMessages),
      ),
      'hello world',
    );
    const gemini =
        'data: {"candidates": [\ndata: {"content":{"parts":[{"text":"你好"}]}}]}\n\n';
    expect(
      extractAiCompletionText(
        gemini,
        const AiConfig(protocol: AiProtocol.geminiNative),
      ),
      '你好',
    );
  });
  test('recursive structured content from Android compatible proxies', () {
    final body = jsonEncode({
      'output': [
        {
          'content': [
            {
              'text': {'value': 'first'},
            },
            {
              'parts': [
                {'text': 'second'},
              ],
            },
          ],
        },
      ],
    });
    expect(extractAiCompletionText(body, const AiConfig()), 'first\nsecond');
  });
  for (final protocol in AiProtocol.values) {
    test('HTTP 200 $protocol rejects valid delta followed by damaged SSE data', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final delta = switch (protocol) {
        AiProtocol.openAiChat => {
          'choices': [
            {
              'delta': {'content': '{"items":'},
            },
          ],
        },
        AiProtocol.anthropicMessages => {
          'type': 'content_block_delta',
          'delta': {'type': 'text_delta', 'text': '{"items":'},
        },
        AiProtocol.geminiNative => {
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': '{"items":'},
                ],
              },
            },
          ],
        },
        _ => {'type': 'response.output_text.delta', 'delta': '{"items":'},
      };
      server.listen((request) async {
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
        );
        request.response.write(
          'data: ${jsonEncode(delta)}\n\ndata: {"broken":\n\ndata: [DONE]\n\n',
        );
        await request.response.close();
      });
      final client = AiCompletionClient();
      addTearDown(client.close);
      final result = await client.complete(
        config: AiConfig(
          enabled: true,
          protocol: protocol,
          endpoint: 'http://127.0.0.1:${server.port}',
          apiKey: 'fixture',
        ),
        prompt: 'hello',
      );
      expect(result.ok, false);
      expect(result.statusCode, 200);
      expect(result.text, '');
      expect(result.message, isNotEmpty);
    });
    test(
      '$protocol never extracts residual text from malformed SSE before a valid snapshot',
      () {
        for (final damaged in ['{"broken":', 'null', '[]', '"not an event"']) {
          final body =
              'data: {"type":"response.output_text.delta","delta":"partial"}\n\ndata: $damaged\n\ndata: {"type":"response.completed","response":{"output_text":"complete"}}\n\ndata: [DONE]\n\n';
          expect(
            extractAiCompletionText(body, AiConfig(protocol: protocol)),
            '',
            reason: damaged,
          );
        }
      },
    );
    test(
      'real local HTTP $protocol sends protocol request and handles full SSE',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final captured = Completer<Map<String, dynamic>>();
        server.listen((request) async {
          captured.complete(
            jsonDecode(await utf8.decoder.bind(request).join())
                as Map<String, dynamic>,
          );
          request.response.headers.contentType = ContentType(
            'text',
            'event-stream',
          );
          request.response.write(
            'data: {"choices":[{"delta":{"content":"fixture"}}]}\n\ndata: [DONE]\n\n',
          );
          await request.response.close();
        });
        final client = AiCompletionClient();
        addTearDown(client.close);
        final result = await client.complete(
          config: AiConfig(
            enabled: true,
            protocol: protocol,
            endpoint: 'http://127.0.0.1:${server.port}',
            apiKey: 'fixture',
            model: 'fixture-model',
          ),
          prompt: 'hello',
        );
        expect(result.ok, true);
        expect(result.text, 'fixture');
        final body = await captured.future;
        expect(
          body[protocol == AiProtocol.openAiResponses
              ? 'input'
              : protocol == AiProtocol.geminiNative
              ? 'contents'
              : 'messages'],
          isNotNull,
        );
      },
    );
  }
}
