/// 观影报告「AI 解读」的结构化展示层。
///
/// 模型输出是一段 JSON（`summary/tags/badges/genreInsights/highlights/
/// recommendationHint`）。早期直接把原文贴进页面，用户看到的是一整坨
/// JSON——这里把它拆成可读的四段：摘要 / 标签 / 类型洞察 / 亮点 / 建议。
///
/// 容错优先：**解析失败或字段缺失时不能丢内容**，调用方回退显示原文。
library;

import 'ai_assist.dart' show decodeJsonObject, extractJsonObject;

class ViewingReportAiNarrative {
  const ViewingReportAiNarrative({
    this.summary = '',
    this.tags = const [],
    this.badges = const [],
    this.genreInsights = '',
    this.highlights = const [],
    this.recommendationHint = '',
  });

  final String summary;
  final List<String> tags;
  final List<String> badges;
  final String genreInsights;
  final List<String> highlights;
  final String recommendationHint;

  bool get isEmpty =>
      summary.isEmpty &&
      tags.isEmpty &&
      badges.isEmpty &&
      genreInsights.isEmpty &&
      highlights.isEmpty &&
      recommendationHint.isEmpty;

  static const int maxTags = 12;
  static const int maxBadges = 6;
  static const int maxHighlights = 8;
  static const int maxFieldLength = 1200;

  /// 解析模型输出；不是 JSON 或没有可用字段时返回 `null`（调用方回退原文）。
  static ViewingReportAiNarrative? parse(String raw) {
    final jsonText = extractJsonObject(raw);
    if (jsonText == null) return null;
    final map = decodeJsonObject(jsonText);
    if (map == null) return null;
    final narrative = ViewingReportAiNarrative(
      summary: _text(map['summary']),
      tags: _list(map['tags'], maxTags),
      badges: _list(map['badges'], maxBadges),
      genreInsights: _text(map['genreInsights']),
      highlights: _list(map['highlights'], maxHighlights),
      recommendationHint: _text(map['recommendationHint']),
    );
    return narrative.isEmpty ? null : narrative;
  }

  static String _text(Object? raw) {
    if (raw is! String) return '';
    final value = raw.trim();
    if (value.isEmpty) return '';
    return value.length > maxFieldLength
        ? '${value.substring(0, maxFieldLength)}…'
        : value;
  }

  static List<String> _list(Object? raw, int max) {
    if (raw is! List) return const [];
    final values = <String>[];
    for (final item in raw) {
      final value = _text(item);
      // 模型偶尔会塞空串/空对象占位（截图里出现过 `"badges":[],[]`），跳过。
      if (value.isEmpty || values.contains(value)) continue;
      values.add(value);
      if (values.length >= max) break;
    }
    return values;
  }
}
