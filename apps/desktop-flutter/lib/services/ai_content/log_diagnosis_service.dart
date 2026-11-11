// ignore_for_file: prefer_initializing_formals
/// 日志诊断服务：自动取**真实** LogService 日志 → 脱敏 → 28Ki 截尾 → AI →
/// 中文四段结构解析。
///
/// 用户不需要手动粘贴日志：默认直接读 `LogService.readPersisted()`
/// （磁盘上的真实日志）。发送前一律脱敏，且只发尾部 28Ki 字符。
library;

import '../../core/ai_config.dart';
import '../../core/ai_content/ai_content_contracts.dart';
import '../../core/ai_content/log_diagnosis.dart';
import '../log_service.dart';
import 'ai_content_completion.dart';

class LogDiagnosisService {
  LogDiagnosisService({
    required AiConfig Function() config,
    AiContentCompletion? completion,
    this.log,
    Future<String> Function()? logSource,
  }) : _config = config,
       _completion = completion ?? AiContentCompletion(log: log),
       _logSource = logSource;

  final AiConfig Function() _config;
  final AiContentCompletion _completion;
  final LogService? log;
  final Future<String> Function()? _logSource;

  /// 取真实日志：默认走 LogService 的持久化日志。
  Future<String> readLogs() async {
    final source = _logSource;
    if (source != null) return source();
    final service = log;
    if (service == null) return '';
    return service.readPersisted();
  }

  /// 诊断：返回结构化四段结果（失败时 message 说明原因）。
  Future<AiContentOutcome<LogDiagnosisResult>> diagnose({
    AiContentCancellation? cancellation,
  }) async {
    if (cancellation?.isCancelled ?? false) {
      return const AiContentOutcome<LogDiagnosisResult>.cancelled();
    }
    final raw = await readLogs();
    final payload = buildSanitizedLogPayload(raw);
    if (payload.isEmpty ||
        payload.contains('调试日志未开启') ||
        payload.contains('暂无调试日志')) {
      return const AiContentOutcome<LogDiagnosisResult>.failed(
        message: '暂无可诊断日志。请先开启调试日志，复现问题后再诊断。',
      );
    }
    final result = await _completion.run(
      config: _config(),
      prompt: buildLogDiagnosisPrompt(payload),
      cancellation: cancellation,
      logTag: 'ai-diagnosis chars=${payload.length}',
    );
    if (result.cancelled) {
      return const AiContentOutcome<LogDiagnosisResult>.cancelled();
    }
    if (!result.ok) {
      return AiContentOutcome<LogDiagnosisResult>.failed(
        message: result.message,
        statusCode: result.statusCode,
      );
    }
    // 结构不完整时也返回结果：UI 会显式标注缺段，而不是假装拿到了完整诊断。
    return AiContentOutcome<LogDiagnosisResult>.value(
      parseLogDiagnosis(result.value!),
    );
  }
}
