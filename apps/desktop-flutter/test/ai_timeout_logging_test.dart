import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/ai_config.dart';
import 'package:webhtv_pc/services/ai_completion_client.dart';
import 'package:webhtv_pc/services/log_service.dart';

void main() {
  group('AI 超时可配置（默认 5 分钟）', () {
    test('默认 300 秒', () {
      expect(const AiConfig().timeoutSeconds, 300);
      expect(const AiConfig().timeout, const Duration(seconds: 300));
    });

    test('快照值被夹到 30–1800 秒', () {
      expect(
        const AiConfig(timeoutSeconds: 5).sanitized().timeoutSeconds,
        30,
      );
      expect(
        const AiConfig(timeoutSeconds: 99999).sanitized().timeoutSeconds,
        1800,
      );
      expect(const AiConfig(timeoutSeconds: 5).timeout, const Duration(seconds: 30));
    });

    test('JSON 往返保留，旧 JSON 缺字段回落默认', () {
      const config = AiConfig(timeoutSeconds: 420, apiKey: 'k');
      final restored = AiConfig.fromJson(config.toJson());
      expect(restored.timeoutSeconds, 420);
      // 旧配置（没有该键）必须仍然可用，且拿到新的默认值而不是 0。
      final legacy = AiConfig.fromJson({'apiKey': 'k', 'model': 'm'});
      expect(legacy.timeoutSeconds, 300);
      // copyWith 能改，且其它字段不动。
      expect(restored.copyWith(timeoutSeconds: 60).timeoutSeconds, 60);
      expect(restored.copyWith(timeoutSeconds: 60).apiKey, 'k');
    });
  });

  group('AI 调用留痕（脱敏）', () {
    test('成功调用写一条含任务/协议/状态/耗时的日志，且不含 Key 与正文', () async {
      final log = LogService();
      final client = AiCompletionClient(
        log: log,
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': 'secret-answer'},
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ),
        ),
      );
      final result = await client.complete(
        config: const AiConfig(
          enabled: true,
          protocol: AiProtocol.openAiChat,
          endpoint: 'https://api.example.test/v1/chat/completions',
          apiKey: 'sk-should-never-be-logged',
          model: 'm1',
        ),
        prompt: '不要出现在日志里的提示词正文',
        task: 'rec',
      );
      expect(result.ok, isTrue);
      expect(log.entries, isNotEmpty);
      final line = log.entries.last.message;
      expect(line, contains('ai[rec]'));
      expect(line, contains('protocol=openai_chat'));
      expect(line, contains('host=api.example.test'));
      expect(line, contains('model=m1'));
      expect(line, contains('status=200'));
      expect(line, contains('ms='));
      expect(line, isNot(contains('sk-should-never-be-logged')));
      expect(line, isNot(contains('不要出现在日志里的提示词正文')));
      expect(line, isNot(contains('chat/completions')));
    });

    test('失败调用同样留痕并带失败原因', () async {
      final log = LogService();
      final client = AiCompletionClient(
        log: log,
        client: MockClient((_) async => http.Response('boom', 500)),
      );
      final result = await client.complete(
        config: const AiConfig(
          enabled: true,
          protocol: AiProtocol.openAiChat,
          endpoint: 'https://api.example.test/v1',
          apiKey: 'k',
          model: 'm1',
        ),
        prompt: 'p',
        task: 'title',
      );
      expect(result.ok, isFalse);
      final line = log.entries.last.message;
      expect(line, contains('ai[title]'));
      expect(line, contains('ok=false'));
      expect(line, contains('status=500'));
    });

    test('真实异常被记录（不再只给"请检查端点与协议"）', () async {
      final log = LogService();
      final client = AiCompletionClient(
        log: log,
        client: MockClient((_) async => throw StateError('stream closed early')),
      );
      final result = await client.complete(
        config: const AiConfig(
          enabled: true,
          protocol: AiProtocol.openAiChat,
          endpoint: 'https://api.example.test/v1',
          apiKey: 'k',
          model: 'm1',
        ),
        prompt: 'p',
        task: 'rec',
      );
      expect(result.ok, isFalse);
      expect(result.detail, contains('StateError'));
      final line = log.entries.last.message;
      expect(line, contains('detail=StateError'));
      expect(line, contains('stream closed early'));
    });

    test('返回 HTML 错误页时日志写响应形状，提示可操作', () async {
      final log = LogService();
      final client = AiCompletionClient(
        log: log,
        client: MockClient(
          (_) async => http.Response(
            '<html><body>502 Bad Gateway</body></html>',
            200,
            headers: {'content-type': 'text/html'},
          ),
        ),
      );
      final result = await client.complete(
        config: const AiConfig(
          enabled: true,
          protocol: AiProtocol.openAiChat,
          endpoint: 'https://api.example.test/v1',
          apiKey: 'k',
          model: 'm1',
        ),
        prompt: 'p',
        task: 'rec',
      );
      expect(result.ok, isFalse);
      expect(result.message, contains('html'));
      final line = log.entries.last.message;
      expect(line, contains('shape=html'));
      expect(line, contains('content-type=text/html'));
      // 失败日志不能泄漏 Key。
      expect(line, isNot(contains('apiKey')));
    });
    test('未显式传 log 时用进程级默认 sink 留痕', () async {
      final log = LogService();
      final previous = AiCompletionClient.defaultLog;
      AiCompletionClient.defaultLog = log;
      addTearDown(() => AiCompletionClient.defaultLog = previous);
      final client = AiCompletionClient(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': 'x'},
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ),
        ),
      );
      await client.complete(
        config: const AiConfig(
          enabled: true,
          protocol: AiProtocol.openAiChat,
          endpoint: 'https://api.example.test/v1',
          apiKey: 'k',
          model: 'm1',
        ),
        prompt: 'p',
      );
      expect(log.entries, isNotEmpty, reason: '所有 AI 调用必须默认留痕');
      expect(log.entries.last.message, contains('ai[ai]'));
    });
  });
}
