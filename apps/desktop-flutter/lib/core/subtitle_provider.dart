/// 字幕源匹配的纯逻辑与记忆模型（`docs/phase9/design/02` §1）。
///
/// 负责三件事：
/// 1. 标题/季集归一化（用于和字幕源返回的标题对比）；
/// 2. 候选打分与排序（语言优先级、季集一致、标题相似度）；
/// 3. 匹配记忆的数据结构（落库在 `AppDatabase.subtitle_match`）。
///
/// **不负责**网络：provider 的 HTTP 实现在 `services/subtitle_providers/`。
library;

import 'dart:convert';

/// 一次字幕查询。
class SubtitleQuery {
  const SubtitleQuery({
    required this.title,
    this.year,
    this.season,
    this.episode,
    required this.siteKey,
    required this.vodId,
    required this.episodeName,
  });

  final String title;
  final int? year;
  final int? season;
  final int? episode;
  final String siteKey;
  final String vodId;
  final String episodeName;

  String get normalizedTitle => normalizeSubtitleTitle(title);

  @override
  String toString() =>
      'SubtitleQuery("$title", s=$season e=$episode, $siteKey/$vodId)';
}

/// 字幕源返回的一条候选。
class SubtitleCandidate {
  const SubtitleCandidate({
    required this.providerId,
    required this.assetId,
    required this.title,
    required this.language,
    required this.format,
    required this.url,
    this.score = 0,
    this.season,
    this.episode,
    this.headers = const {},
  });

  final String providerId;
  final String assetId;
  final String title;

  /// `zh-Hans` / `zh-Hant` / `en` / 空串。
  final String language;

  /// `srt` / `ass` / `ssa` / `vtt` / `sub`。
  final String format;

  final String url;

  /// 0..1；由 [rankSubtitleCandidates] 计算。
  final double score;

  final int? season;
  final int? episode;
  final Map<String, String> headers;

  String get normalizedTitle => normalizeSubtitleTitle(title);

  SubtitleCandidate copyWithScore(double value) => SubtitleCandidate(
    providerId: providerId,
    assetId: assetId,
    title: title,
    language: language,
    format: format,
    url: url,
    score: value,
    season: season,
    episode: episode,
    headers: headers,
  );

  @override
  String toString() =>
      'SubtitleCandidate($providerId/$assetId "$title" $language '
      '${score.toStringAsFixed(3)})';
}

/// 匹配记忆（DB 行）。
class SubtitleMatchRecord {
  const SubtitleMatchRecord({
    required this.siteKey,
    required this.vodId,
    required this.episodeName,
    required this.providerId,
    required this.assetId,
    required this.title,
    required this.language,
    required this.url,
    required this.updatedAt,
  });

  final String siteKey;
  final String vodId;
  final String episodeName;
  final String providerId;
  final String assetId;
  final String title;
  final String language;
  final String url;
  final int updatedAt;

  factory SubtitleMatchRecord.fromRow(Map<String, Object?> row) =>
      SubtitleMatchRecord(
        siteKey: (row['site_key'] as String?) ?? '',
        vodId: (row['vod_id'] as String?) ?? '',
        episodeName: (row['episode_name'] as String?) ?? '',
        providerId: (row['provider_id'] as String?) ?? '',
        assetId: (row['asset_id'] as String?) ?? '',
        title: (row['title'] as String?) ?? '',
        language: (row['language'] as String?) ?? '',
        url: (row['url'] as String?) ?? '',
        updatedAt: (row['updated_at'] as int?) ?? 0,
      );

  factory SubtitleMatchRecord.fromCandidate({
    required String siteKey,
    required String vodId,
    required String episodeName,
    required SubtitleCandidate candidate,
    int? updatedAt,
  }) => SubtitleMatchRecord(
    siteKey: siteKey,
    vodId: vodId,
    episodeName: episodeName,
    providerId: candidate.providerId,
    assetId: candidate.assetId,
    title: candidate.title,
    language: candidate.language,
    url: candidate.url,
    updatedAt: updatedAt ?? DateTime.now().millisecondsSinceEpoch,
  );

  SubtitleCandidate toCandidate() => SubtitleCandidate(
    providerId: providerId,
    assetId: assetId,
    title: title,
    language: language,
    format: inferSubtitleFormatFromUrl(url),
    url: url,
  );
}

/// 默认语言优先级（与设计文档一致）。
const List<String> kDefaultSubtitleLanguages = ['zh-Hans', 'zh-Hant', 'en'];

/// 自动加载阈值：低于它不自动加载，改为让用户手选。
const double kSubtitleAutoPickThreshold = 0.75;

/// 标题归一化：去括号标签、标点、空白，统一小写。
///
/// 例：`【4K】某剧 第二季 (2024)` → `某剧第二季`。
String normalizeSubtitleTitle(String raw) {
  var text = raw.trim().toLowerCase();
  if (text.isEmpty) return '';
  // 全角括号/书名号内的宣传词先整段去掉。
  text = text
      .replaceAll(RegExp(r'\[[^\]]*\]'), ' ')
      .replaceAll(RegExp(r'\([^)]*\)'), ' ')
      .replaceAll(RegExp(r'（[^）]*）'), ' ')
      .replaceAll(RegExp(r'【[^】]*】'), ' ')
      .replaceAll(RegExp(r'《|》'), ' ');
  text = text.replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), '');
  return text;
}

/// 从候选 URL 推断字幕格式；推断不出时返回空串。
String inferSubtitleFormatFromUrl(String url) {
  final lower = url.toLowerCase();
  for (final format in const ['srt', 'ass', 'ssa', 'vtt', 'sub']) {
    if (lower.endsWith('.$format') || lower.contains('.$format?')) {
      return format;
    }
  }
  return '';
}

/// 语言在优先级表中的得分：越靠前越高；未知语言给 0.4。
double languageScore(String language, List<String> preferred) {
  final value = language.trim().toLowerCase();
  if (value.isEmpty) return 0.4;
  for (var i = 0; i < preferred.length; i++) {
    final target = preferred[i].trim().toLowerCase();
    if (value == target) return 1 - i * 0.2;
  }
  return 0.4;
}

/// 季/集一致性：任一侧缺失视为「不提供证据」（0.5，不奖不罚）。
double _episodeScore(int? query, int? candidate) {
  if (query == null || candidate == null) return 0.5;
  return query == candidate ? 1 : 0;
}

/// 标题相似度：完全相等 1；包含 0.9；否则按字符二元组 Jaccard。
double titleScore(String queryTitle, String candidateTitle) {
  final a = normalizeSubtitleTitle(queryTitle);
  final b = normalizeSubtitleTitle(candidateTitle);
  if (a.isEmpty || b.isEmpty) return 0;
  if (a == b) return 1;
  if (a.contains(b) || b.contains(a)) return 0.9;
  return _jaccard(_bigrams(a), _bigrams(b));
}

Set<String> _bigrams(String text) {
  if (text.length < 2) return {text};
  return {
    for (var i = 0; i + 1 < text.length; i++) text.substring(i, i + 2),
  };
}

double _jaccard(Set<String> a, Set<String> b) {
  if (a.isEmpty || b.isEmpty) return 0;
  final intersection = a.where(b.contains).length;
  final union = a.length + b.length - intersection;
  return union == 0 ? 0 : intersection / union;
}

/// 计算综合得分。
double scoreSubtitleCandidate({
  required SubtitleCandidate candidate,
  required SubtitleQuery query,
  List<String> preferredLanguages = kDefaultSubtitleLanguages,
}) {
  final title = titleScore(query.title, candidate.title);
  final episode = _episodeScore(query.episode, candidate.episode);
  final season = _episodeScore(query.season, candidate.season);
  final language = languageScore(candidate.language, preferredLanguages);
  return (title * 0.65) + (episode * 0.15) + (season * 0.1) +
      (language * 0.1);
}

/// 打分并排序（分数相同按 providerId/assetId 稳定排序，避免列表跳动）。
List<SubtitleCandidate> rankSubtitleCandidates({
  required Iterable<SubtitleCandidate> candidates,
  required SubtitleQuery query,
  List<String> preferredLanguages = kDefaultSubtitleLanguages,
}) {
  final scored = [
    for (final candidate in candidates)
      candidate.copyWithScore(
        scoreSubtitleCandidate(
          candidate: candidate,
          query: query,
          preferredLanguages: preferredLanguages,
        ),
      ),
  ]..sort((a, b) {
    final byScore = b.score.compareTo(a.score);
    if (byScore != 0) return byScore;
    final byProvider = a.providerId.compareTo(b.providerId);
    return byProvider != 0 ? byProvider : a.assetId.compareTo(b.assetId);
  });
  return scored;
}

/// 取最佳候选；低于阈值返回 null（不自动加载）。
SubtitleCandidate? pickSubtitleCandidate({
  required Iterable<SubtitleCandidate> candidates,
  required SubtitleQuery query,
  List<String> preferredLanguages = kDefaultSubtitleLanguages,
  double threshold = kSubtitleAutoPickThreshold,
}) {
  final ranked = rankSubtitleCandidates(
    candidates: candidates,
    query: query,
    preferredLanguages: preferredLanguages,
  );
  if (ranked.isEmpty) return null;
  return ranked.first.score >= threshold ? ranked.first : null;
}

/// 把候选转成可落库的 JSON（provider 适配层调试用）。
String encodeSubtitleCandidate(SubtitleCandidate candidate) => jsonEncode({
  'providerId': candidate.providerId,
  'assetId': candidate.assetId,
  'title': candidate.title,
  'language': candidate.language,
  'format': candidate.format,
  'url': candidate.url,
  'season': candidate.season,
  'episode': candidate.episode,
});
