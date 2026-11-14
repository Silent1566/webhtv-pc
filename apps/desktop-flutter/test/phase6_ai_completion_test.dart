/// AI 补全客户端的请求形态与响应抽取（`docs/phase6/design/04` §5）。
///
/// L2：用注入的假 `http.Client` 捕获请求，**不发真实请求**。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:webhtv_pc/core/ai_config.dart';
import 'package:webhtv_pc/services/ai_completion_client.dart';

/// 记录最后一次请求，并返回预置响应。
class _CapturingClient extends http.BaseClient {
  _CapturingClient({this.responseBody = '{}', this.statusCode = 200});

  final String responseBody;
  final int statusCode;
  http.BaseRequest? lastRequest;
  String? lastBody;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    lastRequest = request;
    if (request is http.Request) lastBody = request.body;
    return http.StreamedResponse(
      Stream.value(utf8.encode(responseBody)),
      statusCode,
      headers: const {'content-type': 'application/json'},
    );
  }
}

void main() {
  group('请求规格：4 协议（§5.1）', () {
    test('openai_responses：body 用 input + max_output_tokens', () {
      final config = const AiConfig(
        enabled: true,
        protocol: 'openai_responses',
        endpoint: 'https://api.openai.com/v1/responses',
        apiKey: 'sk-x',
        model: 'gpt-4.1-mini',
      ).sanitized();
      final spec = buildAiRequestSpec(config, '分析这些集');

      expect(spec.url, 'https://api.openai.com/v1/responses');
      expect(spec.body['model'], 'gpt-4.1-mini');
      expect(spec.body['input'], '分析这些集');
      expect(spec.body['max_output_tokens'], 4096);
      expect(spec.headers['Authorization'], 'Bearer sk-x');
      expect(spec.headers['Content-Type'], 'application/json');
    });

    test('openai_chat：body 用 messages', () {
      final config = const AiConfig(
        enabled: true,
        protocol: 'openai_chat',
        endpoint: 'https://api.deepseek.com/v1',
        apiKey: 'sk-y',
        model: 'deepseek-chat',
      ).sanitized();
      final spec = buildAiRequestSpec(config, '分析这些集');

      expect(spec.url, 'https://api.deepseek.com/v1/chat/completions');
      expect(spec.body['model'], 'deepseek-chat');
      final messages = spec.body['messages']! as List;
      expect(messages.length, 1);
      expect((messages.first as Map)['role'], 'user');
      expect((messages.first as Map)['content'], '分析这些集');
      expect(spec.headers['Authorization'], 'Bearer sk-y');
    });

    test('anthropic_messages：body 用 max_tokens + messages，鉴权用 x-api-key', () {
      final config = const AiConfig(
        enabled: true,
        protocol: 'anthropic_messages',
        endpoint: 'https://api.anthropic.com/v1',
        apiKey: 'sk-z',
        model: 'claude-3-5-sonnet',
      ).sanitized();
      final spec = buildAiRequestSpec(config, '分析这些集');

      expect(spec.url, 'https://api.anthropic.com/v1/messages');
      expect(spec.body['max_tokens'], 4096);
      expect(spec.headers['x-api-key'], 'sk-z');
      expect(spec.headers['anthropic-version'], '2023-06-01');
      expect(spec.headers.containsKey('Authorization'), isFalse);
    });

    test('gemini_native：body 用 contents + generationConfig，鉴权用 x-goog-api-key', () {
      final config = const AiConfig(
        enabled: true,
        protocol: 'gemini_native',
        endpoint: 'https://generativelanguage.googleapis.com',
        apiKey: 'g-key',
        model: 'gemini-2.0-flash',
      ).sanitized();
      final spec = buildAiRequestSpec(config, '分析这些集');

      expect(
        spec.url,
        contains('/v1beta/models/gemini-2.0-flash:generateContent'),
      );
      final contents = spec.body['contents']! as List;
      expect((contents.first as Map)['role'], 'user');
      final parts = (contents.first as Map)['parts']! as List;
      expect((parts.first as Map)['text'], '分析这些集');
      final generation = spec.body['generationConfig']! as Map;
      expect(generation['maxOutputTokens'], 4096);
      expect(spec.headers['x-goog-api-key'], 'g-key');
    });

    test('customUserAgent 非空时带 User-Agent', () {
      final config = const AiConfig(
        protocol: 'openai_chat',
        endpoint: 'https://x/v1',
        apiKey: 'k',
        customUserAgent: 'MyUA/1.0',
      ).sanitized();
      final spec = buildAiRequestSpec(config, 'p');
      expect(spec.headers['User-Agent'], 'MyUA/1.0');
    });

    test('customUserAgent 含控制字符时不带', () {
      final config = const AiConfig(
        protocol: 'openai_chat',
        endpoint: 'https://x/v1',
        apiKey: 'k',
        customUserAgent: 'bad\u0001ua',
      ).sanitized();
      final spec = buildAiRequestSpec(config, 'p');
      expect(spec.headers.containsKey('User-Agent'), isFalse);
    });
  });

  group('响应文本抽取（§5.2）', () {
    AiConfig configOf(String protocol) => AiConfig(
      protocol: protocol,
      endpoint: 'https://x/v1',
      apiKey: 'k',
      model: 'm',
    ).sanitized();

    test('openai_responses：output_text', () {
      final body = jsonEncode({'output_text': '结果 A'});
      expect(
        extractAiCompletionText(body, configOf('openai_responses')),
        '结果 A',
      );
    });

    test('openai_responses：output[].content[].text', () {
      final body = jsonEncode({
        'output': [
          {
            'content': [
              {'text': '结果 B'},
            ],
          },
        ],
      });
      expect(
        extractAiCompletionText(body, configOf('openai_responses')),
        '结果 B',
      );
    });

    test('openai_chat：choices[].message.content', () {
      final body = jsonEncode({
        'choices': [
          {
            'message': {'content': '结果 C'},
          },
        ],
      });
      expect(extractAiCompletionText(body, configOf('openai_chat')), '结果 C');
    });

    test('anthropic_messages：content[].text', () {
      final body = jsonEncode({
        'content': [
          {'text': '结果 D'},
        ],
      });
      expect(
        extractAiCompletionText(body, configOf('anthropic_messages')),
        '结果 D',
      );
    });

    test('gemini_native：candidates[].content.parts[].text', () {
      final body = jsonEncode({
        'candidates': [
          {
            'content': {
              'parts': [
                {'text': '结果 E'},
              ],
            },
          },
        ],
      });
      expect(
        extractAiCompletionText(body, configOf('gemini_native')),
        '结果 E',
      );
    });

    test('协议选错时交叉兜底（§5.2）', () {
      // 协议选 openai_responses，但服务端返回 anthropic 结构。
      final body = jsonEncode({
        'content': [
          {'text': '兜底结果'},
        ],
      });
      expect(
        extractAiCompletionText(body, configOf('openai_responses')),
        '兜底结果',
        reason: '中转站常返回异构结构，必须交叉兜底',
      );
    });

    test('都抽不到时返回空串，不抛异常', () {
      expect(extractAiCompletionText('{}', configOf('openai_chat')), '');
      expect(extractAiCompletionText('not json', configOf('openai_chat')), '');
      expect(extractAiCompletionText('', configOf('openai_chat')), '');
    });
  });

  group('发送（不发真实请求）', () {
    test('成功时返回抽取到的文本', () async {
      final client = _CapturingClient(
        responseBody: jsonEncode({
          'choices': [
            {
              'message': {'content': 'AI 输出'},
            },
          ],
        }),
      );
      final completion = AiCompletionClient(client: client);
      final result = await completion.complete(
        config: const AiConfig(
          enabled: true,
          protocol: 'openai_chat',
          endpoint: 'https://x/v1',
          apiKey: 'k',
          model: 'm',
        ),
        prompt: 'p',
      );

      expect(result.ok, isTrue);
      expect(result.text, 'AI 输出');
      expect(client.lastRequest!.method, 'POST');
      expect(
        client.lastRequest!.headers['Authorization'],
        'Bearer k',
        reason: '鉴权头必须发出',
      );
      completion.close();
    });

    test('HTTP 非 2xx 时 ok=false 且带状态码', () async {
      // **必须用一个「能解析出文本」的响应体**（变异自检抓到的缺口）：
      // 若用不可解析的 `boom`，则「非 2xx 被拒绝」与「解析不到文本」两条路
      // 都会得到 `ok=false`，断言分不出二者——把非 2xx 检查删掉也照样绿。
      // 用一份**合法的 chat 响应体** + 500 状态码，就能唯一区分：
      //   正确实现 → ok=false（状态码先拒）
      //   删掉检查 → ok=true（文本解析成功）
      const validChatBody =
          '{"choices":[{"message":{"content":"[{\\"season\\":1}]"}}]}';
      final client = _CapturingClient(
        responseBody: validChatBody,
        statusCode: 500,
      );
      final completion = AiCompletionClient(client: client);
      final result = await completion.complete(
        config: const AiConfig(
          enabled: true,
          protocol: 'openai_chat',
          endpoint: 'https://x/v1',
          apiKey: 'k',
          model: 'm',
        ),
        prompt: 'p',
      );

      expect(
        result.ok,
        isFalse,
        reason: '状态码非 2xx 必须被拒，即使响应体能解析出文本',
      );
      expect(result.statusCode, 500);
      expect(result.text, isEmpty, reason: '被拒时不得把文本交出去');
      completion.close();
    });

    test('配置未就绪时不发请求', () async {
      final client = _CapturingClient();
      final completion = AiCompletionClient(client: client);
      final result = await completion.complete(
        config: const AiConfig(),
        prompt: 'p',
      );

      expect(result.ok, isFalse);
      expect(client.lastRequest, isNull, reason: '未就绪必须短路，不发请求');
      completion.close();
    });

    test('超时 → ok=false，message 说明超时', () async {
      final client = _SlowClient();
      final completion = AiCompletionClient(client: client);
      final result = await completion.complete(
        config: const AiConfig(
          enabled: true,
          protocol: 'openai_chat',
          endpoint: 'https://x/v1',
          apiKey: 'k',
          model: 'm',
        ),
        prompt: 'p',
        timeout: const Duration(milliseconds: 50),
      );

      expect(result.ok, isFalse);
      expect(result.message, contains('超时'));
      completion.close();
    });
  });
}

/// 永不返回的客户端，用于验证超时。
class _SlowClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    await Future<void>.delayed(const Duration(seconds: 30));
    return http.StreamedResponse(const Stream.empty(), 200);
  }
}
