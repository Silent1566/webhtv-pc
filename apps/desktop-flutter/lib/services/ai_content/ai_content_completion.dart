// ignore_for_file: prefer_initializing_formals
/// 内容智能域的补全执行器：一处负责「取消 / 未配置 / 失败 / 日志」。
///
/// 底座 `AiCompletionClient.complete({config, prompt, timeout, cancellationToken})`
/// 向下兼容：本层只传前三个命名参数，因此底座新增 `cancellationToken` 之前
/// 也能编译；底座落地后，取消仍由本层在调用边界前后判定——取消结果一律是
/// `ok=false / statusCode=0`，与底座 token 语义一致。
library;

import '../../core/ai_config.dart';
import '../../core/ai_content/ai_content_contracts.dart';
import '../ai_completion_client.dart';
import '../log_service.dart';

/// 一次补全调用的最小函数形状（测试可注入不联网的实现）。
typedef AiContentCompleteFn =
    Future<AiCompletionResult> Function({
      required AiConfig config,
      required String prompt,
      Duration timeout,
    });

class AiContentCompletion {
  AiContentCompletion({AiContentCompleteFn? complete, LogService? log})
    : _complete = complete,
      _log = log;

  final AiContentCompleteFn? _complete;
  final LogService? _log;

  /// 不显式指定就用 AI 配置里的超时（默认 5 分钟，用户可改）。
  Duration timeoutOf(AiConfig config) => config.sanitized().timeout;

  AiCompletionClient? _client;

  /// 发一次补全；任何异常都收敛成失败结果，不向 UI 抛。
  Future<AiContentOutcome<String>> run({
    required AiConfig config,
    required String prompt,
    AiContentCancellation? cancellation,
    String logTag = 'ai-content',
  }) async {
    if (cancellation?.isCancelled ?? false) {
      return const AiContentOutcome<String>.cancelled();
    }
    if (!config.sanitized().isReady) {
      _log?.warning('$logTag 跳过：AI 未配置完成', scope: 'ai');
      return const AiContentOutcome<String>.failed(
        message: 'AI 服务未配置完成（需要启用、端点、API Key、模型）',
      );
    }
    // 把本域取消信号桥接成底座的 token：换集/关窗会**真正中断**这次 HTTP。
    final token = AiCancellationToken();
    if (cancellation != null) {
      cancellation.whenCancelled.then((_) => token.cancel());
    }
    final AiCompletionResult result;
    try {
      result = await _call(
        config: config,
        prompt: prompt,
        cancellationToken: token,
        logTask: logTag,
      );
    } catch (error) {
      _log?.warning('$logTag 调用异常：$error', scope: 'ai');
      return AiContentOutcome<String>.failed(message: '$error');
    }
    // 请求期间用户换了集/关了窗口：结果作废，不落缓存、不展示。
    if ((cancellation?.isCancelled ?? false) || token.isCancelled) {
      _log?.info('$logTag 已取消（结果丢弃）', scope: 'ai');
      return const AiContentOutcome<String>.cancelled();
    }
    if (!result.ok) {
      _log?.warning(
        '$logTag 失败 status=${result.statusCode} ${result.message}',
        scope: 'ai',
      );
      return AiContentOutcome<String>.failed(
        message: result.message.isEmpty ? 'AI 请求失败' : result.message,
        statusCode: result.statusCode,
      );
    }
    _log?.info('$logTag 完成 chars=${result.text.length}', scope: 'ai');
    return AiContentOutcome<String>.value(result.text);
  }

  Future<AiCompletionResult> _call({
    required AiConfig config,
    required String prompt,
    required AiCancellationToken cancellationToken,
    required String logTask,
  }) {
    final injected = _complete;
    if (injected != null) {
      // 注入实现（测试）不需要 token：取消已在调用前后判定。
      return injected(
        config: config,
        prompt: prompt,
        timeout: timeoutOf(config),
      );
    }
    final client = _client ??= AiCompletionClient(log: _log);
    return client.complete(
      config: config,
      prompt: prompt,
      cancellationToken: cancellationToken,
      task: logTask,
    );
  }

  void close() {
    _client?.close();
    _client = null;
  }
}
