/// 推荐卡副信息的统一口径：**年份 · 评分**。
///
/// 三条推荐行的来源不同，原始副信息也各不相同：
/// `2025 · 7.1`（TMDB）、`2025 · 剧集`（豆瓣，评分另存字段）、
/// `2023 · 剧集 · 评分 7.4`（AI）。
/// 来源本来就写在区块标题里（「个性推荐·豆瓣」「AI 推荐」），卡片上再写一遍
/// 只会让相邻三行互相不像。这里只保留年份与**一个**评分；
/// 两样都取不到时原样返回，绝不返回空串（那会让卡片下面平白多一条空行）。
library;

/// 从任意形态的副信息里抽出 `年份 · 评分`。
///
/// [doubanRating] 优先于副信息里的数字：豆瓣行的评分是结构化字段，
/// 副信息里可能只有一个年份。
String recommendationMeta(String subtitle, {double doubanRating = 0}) {
  final parts = subtitle
      .split('·')
      .map((part) => part.trim())
      .where((part) => part.isNotEmpty)
      .toList();
  final year = parts.firstWhere(_isYear, orElse: () => '');
  final rating = doubanRating > 0 ? doubanRating : _ratingIn(parts);
  if (year.isEmpty && rating <= 0) return subtitle.trim();
  return [
    if (year.isNotEmpty) year,
    if (rating > 0) rating.toStringAsFixed(1),
  ].join(' · ');
}

bool _isYear(String part) => RegExp(r'^\d{4}$').hasMatch(part);

/// 取第一个像评分的数字（10 分制）。年份片段跳过，避免把 2023 当成分数。
double _ratingIn(List<String> parts) {
  for (final part in parts) {
    if (_isYear(part)) continue;
    final match = RegExp(r'\d+(?:\.\d+)?').firstMatch(part);
    if (match == null) continue;
    final value = double.tryParse(match.group(0)!);
    if (value != null && value > 0 && value <= 10) return value;
  }
  return 0;
}
