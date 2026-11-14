// ignore_for_file: prefer_initializing_formals
/// AI 辅助服务（`docs/phase9/README.md` P1-10）。
///
/// 只做「构造提示词 → 发一次补全 → 解析受限结构」。所有结果都返回给调用方，
/// 由 UI 展示并让用户确认；本层不写任何状态（不自动改标题/分组/播放地址）。
///
/// 与内容智能域的衔接：提示词头取自 `AiConfig` 五套原文；日志诊断在发送前
/// 脱敏；取消信号桥接到底座的 `AiCancellationToken`。
library;

import '../core/ai_assist.dart';
import '../core/ai_config.dart';
import '../core/ai_content/ai_content_contracts.dart';
import '../core/ai_content/log_diagnosis.dart';
import 'ai_completion_client.dart';
import 'log_service.dart';

class AiAssistService {
  AiAssistService({
    AiConfig? config,
    AiConfig Function()? configReader,
    AiCompletionClient? client,
    this.log,
    this.timeout = AiCompletionClient.defaultTimeout,
  }) : _configReader = configReader,
       _fixedConfig = (config ?? const AiConfig()).sanitized(),
       _client = client ?? AiCompletionClient(log: log);

  final AiConfig Function()? _configReader;
  final AiConfig _fixedConfig;
  final AiCompletionClient _client;
  final LogService? log;
  final Duration timeout;

  AiConfig get config => (_configReader?.call() ?? _fixedConfig).sanitized();

  bool get isReady => config.isReady;

  /// 执行一次辅助任务；配置未就绪、输出不合规或取消时返回失败（不抛异常）。
  Future<AiAssistResult> run({
    required AiAssistTask task,
    required String input,
    Map<String, String> extra = const {},
    AiContentCancellation? cancellation,
  }) async {
    if (cancellation?.isCancelled ?? false) {
      return const AiAssistResult.failure('已取消');
    }
    if (!isReady) {
      return const AiAssistResult.failure('未配置 AI：请先在设置页填写端点/密钥/模型');
    }
    // 日志诊断的输入是不可信日志：发送前必须脱敏（28Ki 截尾在提示词层）。
    final safeInput = task == AiAssistTask.logDiagnosis
        ? buildSanitizedLogPayload(input)
        : input;
    if (safeInput.trim().isEmpty) {
      return const AiAssistResult.failure('输入为空');
    }
    final prompt = buildAiAssistPrompt(
      task: task,
      input: safeInput,
      extra: extra,
      config: config,
    );
    final token = AiCancellationToken();
    if (cancellation != null) {
      cancellation.whenCancelled.then((_) => token.cancel());
    }
    final completion = await _client.complete(
      config: config,
      prompt: prompt,
      timeout: timeout,
      cancellationToken: token,
    );
    if ((cancellation?.isCancelled ?? false) || token.isCancelled) {
      log?.info('AI 辅助已取消 task=${task.id}', scope: 'ai');
      return const AiAssistResult.failure('已取消');
    }
    if (!completion.ok) {
      log?.warning(
        'AI 辅助失败 task=${task.id} status=${completion.statusCode} '
        '${completion.message}',
        scope: 'ai',
      );
      return AiAssistResult.failure(
        completion.message.isEmpty ? 'AI 请求失败' : completion.message,
      );
    }
    final parsed = parseAiAssistOutput(completion.text, task: task);
    if (!parsed.ok) {
      log?.warning(
        'AI 辅助输出不可用 task=${task.id} error=${parsed.error}',
        scope: 'ai',
      );
    } else {
      log?.info('AI 辅助完成 task=${task.id}', scope: 'ai');
    }
    return parsed;
  }
}
