/// 内容智能域与公共底座之间的唯一契约层。
///
/// 1. **五套提示词**：直接读 `AiConfig` 的真实字段
///    （`recommendPrompt` / `titleExtractionPrompt` / `viewingReportPrompt` /
///    `adDetectionPrompt` / `groupRulePrompt` 及各自的版本号与自定义标志）。
///    底座已经把内置原文、旧版升级与 `sanitized()` 保真做完，本层**不自造
///    近似文本**：空串才回落到底座的内置原文。
/// 2. **取消与结果**：取消一律是 `ok=false / statusCode=0`，与底座
///    `AiCompletionResult` 对齐，跨任务边界不出现第二种取消表达。
library;

import 'dart:async';

import '../ai_config.dart';
import '../ai_prompts.dart';

/// 内容智能用到的五种提示词。
enum AiContentKind {
  recommend('recommend', '推荐'),
  title('titleExtraction', '片名提取'),
  viewingReport('viewingReport', '观影报告'),
  ad('adDetection', '去广规则'),
  group('groupRule', '分组规则');

  const AiContentKind(this.id, this.label);

  final String id;
  final String label;
}

/// 提示词原文与元信息的读取入口。
abstract final class AiPromptCatalog {
  /// 提示词原文：用户自定义优先；空串回落底座内置原文。
  static String promptFor(AiConfig config, AiContentKind kind) {
    final text = _rawPrompt(config, kind).trim();
    return text.isEmpty ? builtin(kind) : text;
  }

  /// 提示词版本：片名缓存必须按它失效。
  static int versionFor(AiConfig config, AiContentKind kind) {
    final version = switch (kind) {
      AiContentKind.recommend => config.recommendPromptVersion,
      AiContentKind.title => config.titleExtractionPromptVersion,
      AiContentKind.viewingReport => config.viewingReportPromptVersion,
      AiContentKind.ad => config.adDetectionPromptVersion,
      AiContentKind.group => config.groupRulePromptVersion,
    };
    return version > 0 ? version : 1;
  }

  /// 底座内置原文（单一来源：`AiPrompts`，不在本域复制一份）。
  static String builtin(AiContentKind kind) => switch (kind) {
    AiContentKind.recommend => AiPrompts.defaultRecommendPrompt,
    AiContentKind.title => AiPrompts.defaultTitleExtractionPrompt,
    AiContentKind.viewingReport => AiPrompts.defaultViewingReportPrompt,
    AiContentKind.ad => AiPrompts.defaultAdDetectionPrompt,
    AiContentKind.group => AiPrompts.defaultGroupRulePrompt,
  };

  static String _rawPrompt(AiConfig config, AiContentKind kind) =>
      switch (kind) {
        AiContentKind.recommend => config.recommendPrompt,
        AiContentKind.title => config.titleExtractionPrompt,
        AiContentKind.viewingReport => config.viewingReportPrompt,
        AiContentKind.ad => config.adDetectionPrompt,
        AiContentKind.group => config.groupRulePrompt,
      };
}

/// 一次内容智能任务的取消信号。
///
/// 内容智能域内自持（不依赖 services 层），由服务层桥接成底座的
/// `AiCancellationToken` 真正中断 HTTP 请求。
class AiContentCancellation {
  final _completer = Completer<void>();

  bool get isCancelled => _completer.isCompleted;

  /// 取消发生时完成（`await` 它即可等待「已被取消」）。
  Future<void> get whenCancelled => _completer.future;

  void cancel() {
    if (!_completer.isCompleted) _completer.complete();
  }
}

/// 内容智能任务结果的统一形状。
///
/// 取消一律 `ok=false / statusCode=0`；调用方据此区分「取消」「配置缺失」
/// 「网络失败」。
class AiContentOutcome<T> {
  const AiContentOutcome.value(T this.value, {this.statusCode = 200})
    : message = '',
      cancelled = false;

  const AiContentOutcome.failed({required this.message, this.statusCode = 0})
    : value = null,
      cancelled = false;

  const AiContentOutcome.cancelled()
    : value = null,
      message = '已取消',
      statusCode = 0,
      cancelled = true;

  final bool cancelled;
  final int statusCode;
  final String message;
  final T? value;

  bool get ok => value != null;
}
