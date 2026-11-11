/// AI 配置模型与端点归一化（`docs/phase6/design/04` §3）。
///
/// 纯逻辑层：不依赖 Flutter，也不依赖 `dart:io`。上游对应实现是
/// `AiConfig`（`app/src/main/java/com/fongmi/android/tv/bean/AiConfig.java`）。
///
/// 安卓 5 套提示词（推荐 / 标题提取 / 观影报告 / 去广 / 分组规则）的原文与
/// 版本 3/2/2/2/2 在 `ai_prompts.dart`：已知旧内置升级到当前版，未知自定义
/// 原样保留并标记 `*PromptCustom`。JSON 里不认识的键经 `additionalFields`
/// 往返写回，避免旧版字段被本次读改写抹掉。
library;

import 'ai_prompts.dart';

import 'tmdb_config.dart' show redactCredential;

/// AI 补全协议（`docs/phase6/design/04` §3.2）。
abstract final class AiProtocol {
  static const String openAiResponses = 'openai_responses';
  static const String openAiChat = 'openai_chat';
  static const String anthropicMessages = 'anthropic_messages';
  static const String geminiNative = 'gemini_native';

  static const String defaultProtocol = openAiResponses;

  /// 默认模型（对齐上游 `AiConfig.DEFAULT_MODEL`）。
  static const String defaultModel = 'gpt-4.1-mini';

  static const List<String> values = [
    openAiResponses,
    openAiChat,
    anthropicMessages,
    geminiNative,
  ];

  static bool isSupported(String? protocol) =>
      protocol != null && values.contains(protocol);

  static String defaultEndpoint(String protocol) => switch (protocol) {
    openAiChat => 'https://api.openai.com/v1/chat/completions',
    anthropicMessages => 'https://api.anthropic.com/v1/messages',
    geminiNative => 'https://generativelanguage.googleapis.com/v1beta',
    _ => 'https://api.openai.com/v1/responses',
  };
}

/// 去掉 `?query` 与 `#fragment`，并去掉尾部 `/`。
String cleanBaseEndpoint(String endpoint) {
  var value = endpoint.trim();
  final query = value.indexOf('?');
  if (query >= 0) value = value.substring(0, query);
  final fragment = value.indexOf('#');
  if (fragment >= 0) value = value.substring(0, fragment);
  while (value.endsWith('/')) {
    value = value.substring(0, value.length - 1);
  }
  return value;
}

/// 末段是否是 `vN` 形态（`v1`、`v1beta`）。
///
/// 公开而不是文件私有：端点归一化（`AiConfig.completionUrl`）与模型列表拉取
/// （`fetchAiModelList`）必须对「版本段」有一致判断，否则两处会给出不同的基址。
bool endsWithVersionSegment(String url) {
  final last = url.substring(url.lastIndexOf('/') + 1);
  if (last.length < 2 || last[0] != 'v') return false;
  var i = 1;
  while (i < last.length && _isDigit(last.codeUnitAt(i))) {
    i++;
  }
  if (i == 1) return false;
  final suffix = last.substring(i);
  return suffix.isEmpty || suffix == 'beta' || suffix == 'alpha';
}

bool _isDigit(int code) => code >= 0x30 && code <= 0x39;

String _stripGeminiPrefix(String model) =>
    model.startsWith('models/') ? model.substring('models/'.length) : model;

class AiConfig {
  const AiConfig({
    this.enabled = false,
    this.protocol = AiProtocol.defaultProtocol,
    this.endpoint = '',
    this.apiKey = '',
    this.model = '',
    this.customUserAgent = '',
    this.timeoutSeconds = AiConfig.defaultTimeoutSeconds,
    this.recommendPrompt = AiPrompts.defaultRecommendPrompt,
    this.recommendPromptVersion = 3,
    this.recommendPromptCustom = false,
    this.titleExtractionPrompt = AiPrompts.defaultTitleExtractionPrompt,
    this.titleExtractionPromptVersion = 2,
    this.titleExtractionPromptCustom = false,
    this.viewingReportPrompt = AiPrompts.defaultViewingReportPrompt,
    this.viewingReportPromptVersion = 2,
    this.viewingReportPromptCustom = false,
    this.adDetectionPrompt = AiPrompts.defaultAdDetectionPrompt,
    this.adDetectionPromptVersion = 2,
    this.adDetectionPromptCustom = false,
    this.groupRulePrompt = AiPrompts.defaultGroupRulePrompt,
    this.groupRulePromptVersion = 2,
    this.groupRulePromptCustom = false,
    this.additionalFields = const {},
  });
  final bool enabled;
  final String protocol;
  final String endpoint;
  final String apiKey;
  final String model;
  final String customUserAgent;

  /// 单次 AI 请求的超时（秒）。默认 5 分钟：推荐/画像这类任务输出较长，
  /// 旧默认 105 秒在小模型或慢中转上会稳定超时。
  final int timeoutSeconds;

  static const int defaultTimeoutSeconds = 300;
  static const int minTimeoutSeconds = 30;
  static const int maxTimeoutSeconds = 1800;

  /// 生效的超时时长（已夹取到 [minTimeoutSeconds]..[maxTimeoutSeconds]）。
  Duration get timeout => Duration(
    seconds: timeoutSeconds < minTimeoutSeconds
        ? minTimeoutSeconds
        : (timeoutSeconds > maxTimeoutSeconds
              ? maxTimeoutSeconds
              : timeoutSeconds),
  );

  final Map<String, Object?> additionalFields;
  final String recommendPrompt;
  final int recommendPromptVersion;
  final bool recommendPromptCustom;
  final String titleExtractionPrompt;
  final int titleExtractionPromptVersion;
  final bool titleExtractionPromptCustom;
  final String viewingReportPrompt;
  final int viewingReportPromptVersion;
  final bool viewingReportPromptCustom;
  final String adDetectionPrompt;
  final int adDetectionPromptVersion;
  final bool adDetectionPromptCustom;
  final String groupRulePrompt;
  final int groupRulePromptVersion;
  final bool groupRulePromptCustom;
  AiConfig sanitized() {
    final safeProtocol = AiProtocol.isSupported(protocol.trim())
        ? protocol.trim()
        : AiProtocol.defaultProtocol;
    final values = <String, Object?>{};
    final recommendPromptBuiltIn =
        recommendPrompt.trim().isEmpty ||
        [
          AiPrompts.legacyRecommendPromptV1,
          AiPrompts.defaultRecommendPrompt,
          AiPrompts.legacyRecommendPromptV2,
        ].contains(recommendPrompt.trim());
    values['recommendPrompt'] = recommendPromptBuiltIn
        ? AiPrompts.defaultRecommendPrompt
        : recommendPrompt.trim();
    values['recommendPromptVersion'] =
        recommendPromptBuiltIn || recommendPromptVersion <= 0
        ? 3
        : recommendPromptVersion;
    values['recommendPromptCustom'] = !recommendPromptBuiltIn;

    final titleExtractionPromptBuiltIn =
        titleExtractionPrompt.trim().isEmpty ||
        [
          AiPrompts.legacyTitleExtractionPromptV1,
          AiPrompts.defaultTitleExtractionPrompt,
        ].contains(titleExtractionPrompt.trim());
    values['titleExtractionPrompt'] = titleExtractionPromptBuiltIn
        ? AiPrompts.defaultTitleExtractionPrompt
        : titleExtractionPrompt.trim();
    values['titleExtractionPromptVersion'] =
        titleExtractionPromptBuiltIn || titleExtractionPromptVersion <= 0
        ? 2
        : titleExtractionPromptVersion;
    values['titleExtractionPromptCustom'] = !titleExtractionPromptBuiltIn;

    final viewingReportPromptBuiltIn =
        viewingReportPrompt.trim().isEmpty ||
        [
          AiPrompts.defaultViewingReportPrompt,
          AiPrompts.legacyViewingReportPromptV1,
        ].contains(viewingReportPrompt.trim());
    values['viewingReportPrompt'] = viewingReportPromptBuiltIn
        ? AiPrompts.defaultViewingReportPrompt
        : viewingReportPrompt.trim();
    values['viewingReportPromptVersion'] =
        viewingReportPromptBuiltIn || viewingReportPromptVersion <= 0
        ? 2
        : viewingReportPromptVersion;
    values['viewingReportPromptCustom'] = !viewingReportPromptBuiltIn;

    final adDetectionPromptBuiltIn =
        adDetectionPrompt.trim().isEmpty ||
        [
          AiPrompts.defaultAdDetectionPrompt,
          AiPrompts.defaultAdDetectionPromptV1,
        ].contains(adDetectionPrompt.trim());
    values['adDetectionPrompt'] = adDetectionPromptBuiltIn
        ? AiPrompts.defaultAdDetectionPrompt
        : adDetectionPrompt.trim();
    values['adDetectionPromptVersion'] =
        adDetectionPromptBuiltIn || adDetectionPromptVersion <= 0
        ? 2
        : adDetectionPromptVersion;
    values['adDetectionPromptCustom'] = !adDetectionPromptBuiltIn;

    final groupRulePromptBuiltIn =
        groupRulePrompt.trim().isEmpty ||
        [
          AiPrompts.legacyGroupRulePromptV1,
          AiPrompts.defaultGroupRulePrompt,
        ].contains(groupRulePrompt.trim());
    values['groupRulePrompt'] = groupRulePromptBuiltIn
        ? AiPrompts.defaultGroupRulePrompt
        : groupRulePrompt.trim();
    values['groupRulePromptVersion'] =
        groupRulePromptBuiltIn || groupRulePromptVersion <= 0
        ? 2
        : groupRulePromptVersion;
    values['groupRulePromptCustom'] = !groupRulePromptBuiltIn;
    // 超时夹取放在净化里：存到磁盘/备份里的值本身就是合法范围内的值。
    values['timeoutSeconds'] = timeoutSeconds < minTimeoutSeconds
        ? minTimeoutSeconds
        : (timeoutSeconds > maxTimeoutSeconds
              ? maxTimeoutSeconds
              : timeoutSeconds);
    return _fromMap({
      ..._rawJson(),
      ...values,
      'protocol': safeProtocol,
      'endpoint': endpoint.trim().isEmpty
          ? AiProtocol.defaultEndpoint(safeProtocol)
          : endpoint.trim(),
      'apiKey': apiKey.trim(),
      'model': model.trim().isEmpty ? AiProtocol.defaultModel : model.trim(),
      'customUserAgent': customUserAgent.trim(),
    });
  }

  /// 是否可用于补全（四项齐备）。
  bool get isReady {
    final safe = sanitized();
    return safe.enabled &&
        safe.endpoint.isNotEmpty &&
        safe.apiKey.isNotEmpty &&
        safe.model.isNotEmpty;
  }

  /// 是否可用于拉取模型列表（不需要 model）。
  bool get isModelFetchReady {
    final safe = sanitized();
    return safe.endpoint.isNotEmpty && safe.apiKey.isNotEmpty;
  }

  /// 展示用的脱敏 key。复用 TMDB 凭据的脱敏实现，行为一致。
  String get redactedApiKey => redactCredential(apiKey);

  /// 归一化后的补全端点（`docs/phase6/design/04` §3.5）。
  ///
  /// 用户填基址也能用：按协议补路径段；已是完整端点则原样。
  String get completionUrl {
    final safe = sanitized();
    final base = cleanBaseEndpoint(safe.endpoint);
    switch (safe.protocol) {
      case AiProtocol.openAiChat:
        return _appendCompletionPath(base, 'chat/completions');
      case AiProtocol.anthropicMessages:
        return _appendCompletionPath(base, 'messages');
      case AiProtocol.geminiNative:
        return _geminiGenerateContentUrl(base, safe.model);
      default:
        return _appendCompletionPath(base, 'responses');
    }
  }

  static String _appendCompletionPath(String endpoint, String path) {
    if (endpoint.isEmpty) return '';
    if (endpoint.endsWith('/$path')) return endpoint;
    if (endsWithVersionSegment(endpoint)) return '$endpoint/$path';
    return '$endpoint/v1/$path';
  }

  static String _geminiGenerateContentUrl(String endpoint, String model) {
    if (endpoint.contains(':generateContent')) return endpoint;
    final modelPath = 'models/${_stripGeminiPrefix(model)}';
    // 端点已写到 `/models`：只补模型段**并保留 `:generateContent` 方法后缀**。
    //
    // 【brief 缺陷】原文写的是
    //     return '$endpoint/$modelPath'.replaceFirst('/models/models/', '/models/');
    // 它**漏掉了 `:generateContent`**，于是 `https://x/v1beta/models` 会算出
    // `https://x/v1beta/models/gemini-2.0-flash`——一个不是补全接口的地址。
    // brief 自己的用例「端点以 /models 结尾只补模型段」期望的是
    // `.../gemini-2.0-flash:generateContent`，即**实现与它的测试矛盾**。
    // 这里按测试（= 正确行为）修正。
    if (endpoint.endsWith('/models')) {
      return '$endpoint/${_stripGeminiPrefix(model)}:generateContent';
    }
    var value = endpoint;
    if (!endsWithVersionSegment(value)) value = '$value/v1beta';
    return '$value/$modelPath:generateContent';
  }

  AiConfig copyWith({
    int? timeoutSeconds,
    bool? enabled,
    String? protocol,
    String? endpoint,
    String? apiKey,
    String? model,
    String? customUserAgent,
    String? recommendPrompt,
    int? recommendPromptVersion,
    bool? recommendPromptCustom,
    String? titleExtractionPrompt,
    int? titleExtractionPromptVersion,
    bool? titleExtractionPromptCustom,
    String? viewingReportPrompt,
    int? viewingReportPromptVersion,
    bool? viewingReportPromptCustom,
    String? adDetectionPrompt,
    int? adDetectionPromptVersion,
    bool? adDetectionPromptCustom,
    String? groupRulePrompt,
    int? groupRulePromptVersion,
    bool? groupRulePromptCustom,
  }) => AiConfig(
    enabled: enabled ?? this.enabled,
    protocol: protocol ?? this.protocol,
    endpoint: endpoint ?? this.endpoint,
    apiKey: apiKey ?? this.apiKey,
    model: model ?? this.model,
    customUserAgent: customUserAgent ?? this.customUserAgent,
    timeoutSeconds: timeoutSeconds ?? this.timeoutSeconds,
    additionalFields: additionalFields,
    recommendPrompt: recommendPrompt ?? this.recommendPrompt,
    recommendPromptVersion:
        recommendPromptVersion ?? this.recommendPromptVersion,
    recommendPromptCustom: recommendPromptCustom ?? this.recommendPromptCustom,
    titleExtractionPrompt: titleExtractionPrompt ?? this.titleExtractionPrompt,
    titleExtractionPromptVersion:
        titleExtractionPromptVersion ?? this.titleExtractionPromptVersion,
    titleExtractionPromptCustom:
        titleExtractionPromptCustom ?? this.titleExtractionPromptCustom,
    viewingReportPrompt: viewingReportPrompt ?? this.viewingReportPrompt,
    viewingReportPromptVersion:
        viewingReportPromptVersion ?? this.viewingReportPromptVersion,
    viewingReportPromptCustom:
        viewingReportPromptCustom ?? this.viewingReportPromptCustom,
    adDetectionPrompt: adDetectionPrompt ?? this.adDetectionPrompt,
    adDetectionPromptVersion:
        adDetectionPromptVersion ?? this.adDetectionPromptVersion,
    adDetectionPromptCustom:
        adDetectionPromptCustom ?? this.adDetectionPromptCustom,
    groupRulePrompt: groupRulePrompt ?? this.groupRulePrompt,
    groupRulePromptVersion:
        groupRulePromptVersion ?? this.groupRulePromptVersion,
    groupRulePromptCustom: groupRulePromptCustom ?? this.groupRulePromptCustom,
  );
  Map<String, Object?> toJson() => sanitized()._rawJson();
  Map<String, Object?> _rawJson() => {
    ...additionalFields,
    'enabled': enabled,
    'protocol': protocol,
    'endpoint': endpoint,
    'apiKey': apiKey,
    'model': model,
    'customUserAgent': customUserAgent,
    'timeoutSeconds': timeoutSeconds,
    'recommendPrompt': recommendPrompt,
    'recommendPromptVersion': recommendPromptVersion,
    'recommendPromptCustom': recommendPromptCustom,
    'titleExtractionPrompt': titleExtractionPrompt,
    'titleExtractionPromptVersion': titleExtractionPromptVersion,
    'titleExtractionPromptCustom': titleExtractionPromptCustom,
    'viewingReportPrompt': viewingReportPrompt,
    'viewingReportPromptVersion': viewingReportPromptVersion,
    'viewingReportPromptCustom': viewingReportPromptCustom,
    'adDetectionPrompt': adDetectionPrompt,
    'adDetectionPromptVersion': adDetectionPromptVersion,
    'adDetectionPromptCustom': adDetectionPromptCustom,
    'groupRulePrompt': groupRulePrompt,
    'groupRulePromptVersion': groupRulePromptVersion,
    'groupRulePromptCustom': groupRulePromptCustom,
  };
  static AiConfig fromJson(Object? value) {
    if (value is! Map) return const AiConfig().sanitized();
    return _fromMap(value.map((key, value) => MapEntry('$key', value)))
        .sanitized();
  }

  static AiConfig _fromMap(Map<String, Object?> map) {
    String text(String key, [String fallback = '']) =>
        map[key] is String ? map[key]! as String : fallback;
    int number(String key) => map[key] is int ? map[key]! as int : 0;
    return AiConfig(
      enabled: map['enabled'] == true,
      protocol: text(
        'protocol',
        text('apiFormat', text('format', AiProtocol.defaultProtocol)),
      ),
      endpoint: text('endpoint'),
      apiKey: text('apiKey'),
      model: text('model'),
      customUserAgent: text('customUserAgent', text('userAgent', text('ua'))),
      timeoutSeconds: number('timeoutSeconds') > 0
          ? number('timeoutSeconds')
          : defaultTimeoutSeconds,
      additionalFields: Map.unmodifiable(
        {...map}..removeWhere((key, value) => _knownKeys.contains(key)),
      ),
      recommendPrompt: text('recommendPrompt'),
      recommendPromptVersion: number('recommendPromptVersion'),
      recommendPromptCustom: map['recommendPromptCustom'] == true,
      titleExtractionPrompt: text('titleExtractionPrompt'),
      titleExtractionPromptVersion: number('titleExtractionPromptVersion'),
      titleExtractionPromptCustom: map['titleExtractionPromptCustom'] == true,
      viewingReportPrompt: text('viewingReportPrompt'),
      viewingReportPromptVersion: number('viewingReportPromptVersion'),
      viewingReportPromptCustom: map['viewingReportPromptCustom'] == true,
      adDetectionPrompt: text('adDetectionPrompt'),
      adDetectionPromptVersion: number('adDetectionPromptVersion'),
      adDetectionPromptCustom: map['adDetectionPromptCustom'] == true,
      groupRulePrompt: text('groupRulePrompt'),
      groupRulePromptVersion: number('groupRulePromptVersion'),
      groupRulePromptCustom: map['groupRulePromptCustom'] == true,
    );
  }

  static const _knownKeys = <String>{
    'enabled',
    'protocol',
    'apiFormat',
    'format',
    'endpoint',
    'apiKey',
    'model',
    'customUserAgent',
    'userAgent',
    'ua',
    'timeoutSeconds',
    'recommendPrompt',
    'recommendPromptVersion',
    'recommendPromptCustom',
    'titleExtractionPrompt',
    'titleExtractionPromptVersion',
    'titleExtractionPromptCustom',
    'viewingReportPrompt',
    'viewingReportPromptVersion',
    'viewingReportPromptCustom',
    'adDetectionPrompt',
    'adDetectionPromptVersion',
    'adDetectionPromptCustom',
    'groupRulePrompt',
    'groupRulePromptVersion',
    'groupRulePromptCustom',
  };
  @override
  String toString() =>
      'AiConfig(enabled=$enabled, protocol=$protocol, endpoint=$endpoint, apiKey=$redactedApiKey, model=$model)';
}
