/// 提示词执行器：把「一次补全」抽象成可注入函数，便于测试与 Task1 接线。
///
/// 默认实现直接复用既有 [AiCompletionClient]（四协议 + 交叉兜底），并保留
/// Task1 新增的取消/超时能力：注入的 runner 可以直接调用带 token 的
/// `complete`，字幕服务只依赖本接口，不复制底座逻辑。
library;

import '../../core/ai_config.dart';
import '../ai_completion_client.dart';
import '../log_service.dart';

typedef AiPromptRunner = Future<String> Function(String prompt);

class AiPrompt {
  const AiPrompt._();

  /// 用当前配置构造 runner；[timeout] 与取消判据由调用方按源合同给出。
  static AiPromptRunner fromConfig(
    AiConfig config, {
    Duration? timeout,
    bool Function()? isCancelled,
    AiCancellationToken? cancellationToken,
    LogService? log,
    String task = 'ai',
  }) {
    final client = AiCompletionClient(log: log);
    return (prompt) async {
      if ((isCancelled?.call() ?? false) ||
          (cancellationToken?.isCancelled ?? false)) {
        throw const AiPromptCancelled('cancelled');
      }
      final result = await client.complete(
        config: config,
        prompt: prompt,
        timeout: timeout,
        task: task,
        cancellationToken: cancellationToken,
      );
      if ((isCancelled?.call() ?? false) ||
          (cancellationToken?.isCancelled ?? false)) {
        throw const AiPromptCancelled('cancelled');
      }
      if (!result.ok) {
        throw AiPromptFailure(
          result.message.isEmpty ? 'ai_failed' : result.message,
        );
      }
      final text = result.text.trim();
      if (text.isEmpty) throw const AiPromptFailure('empty_completion');
      return text;
    };
  }
}

class AiPromptCancelled implements Exception {
  const AiPromptCancelled(this.reason);

  final String reason;

  @override
  String toString() => 'AiPromptCancelled: $reason';
}

class AiPromptFailure implements Exception {
  const AiPromptFailure(this.reason);

  final String reason;

  @override
  String toString() => 'AiPromptFailure: $reason';
}
