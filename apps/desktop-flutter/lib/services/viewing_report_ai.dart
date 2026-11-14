/// 观影报告的 AI 解读（Phase 9 · P2-2）。
///
/// 只做「在本地统计结果之上加一段文字」：失败不影响基础报告，
/// 未配置 AI 时不发任何请求。
///
/// 与内容智能域的衔接：提示词原文取自 `AiConfig.viewingReportPrompt`
/// （用户在设置页改了就立刻生效），数据块复用 `buildViewingReportPrompt`
/// 的不可信声明与 JSON 形状；取消桥接到底座 token。
library;

import '../core/ai_config.dart';
import '../core/ai_content/ai_content_contracts.dart';
import '../core/viewing_report.dart';
import 'ai_completion_client.dart';

class ViewingReportAiResult {
  const ViewingReportAiResult({
    required this.ok,
    required this.text,
    required this.message,
    this.cancelled = false,
  });

  final bool ok;
  final String text;

  /// 失败原因（用户可读）；成功时为空。
  final String message;

  /// 是否因为用户取消（换范围/关页面）而放弃。
  final bool cancelled;

  static const ViewingReportAiResult skipped = ViewingReportAiResult(
    ok: false,
    text: '',
    message: 'AI 未配置，基础报告已完整生成',
  );
}

class ViewingReportAiAnalyzer {
  ViewingReportAiAnalyzer({
    AiCompletionClient? client,
    this.timeout = AiCompletionClient.defaultTimeout,
  }) : _client = client ?? AiCompletionClient();

  final AiCompletionClient _client;
  final Duration timeout;

  /// 文本上限：防止模型输出极长内容把页面撑坏（不是安全边界，只是展示约束）。
  static const int maxTextLength = 2000;

  Future<ViewingReportAiResult> analyze({
    required AiConfig config,
    required ViewingReport report,
    AiContentCancellation? cancellation,
  }) async {
    if (cancellation?.isCancelled ?? false) {
      return const ViewingReportAiResult(
        ok: false,
        text: '',
        message: '已取消',
        cancelled: true,
      );
    }
    if (!config.sanitized().isReady) return ViewingReportAiResult.skipped;
    final token = AiCancellationToken();
    if (cancellation != null) {
      cancellation.whenCancelled.then((_) => token.cancel());
    }
    final result = await _client.complete(
      config: config,
      prompt: buildViewingReportPromptWith(config: config, report: report),
      timeout: timeout,
      cancellationToken: token,
    );
    if ((cancellation?.isCancelled ?? false) || token.isCancelled) {
      return const ViewingReportAiResult(
        ok: false,
        text: '',
        message: '已取消',
        cancelled: true,
      );
    }
    if (!result.ok) {
      return ViewingReportAiResult(
        ok: false,
        text: '',
        message: result.message,
      );
    }
    final text = result.text.trim();
    if (text.isEmpty) {
      return const ViewingReportAiResult(
        ok: false,
        text: '',
        message: 'AI 返回了空内容',
      );
    }
    return ViewingReportAiResult(
      ok: true,
      text: text.length > maxTextLength
          ? '${text.substring(0, maxTextLength)}…'
          : text,
      message: '',
    );
  }
}

/// 用 `AiConfig.viewingReportPrompt` 的原文替换内置指令头，
/// 数据块仍由 `buildViewingReportPrompt` 生成（保证不可信声明不丢）。
String buildViewingReportPromptWith({
  required AiConfig config,
  required ViewingReport report,
}) {
  final base = AiPromptCatalog.promptFor(config, AiContentKind.viewingReport);
  final data = buildViewingReportPrompt(report);
  final marker = data.indexOf('数据：');
  final payload = marker >= 0 ? data.substring(marker) : data;
  return '$base\n\n$payload';
}
