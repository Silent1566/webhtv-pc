/// 弹幕库匹配的纯逻辑与记忆模型（`docs/phase9/design/02` §2）。
///
/// 与字幕匹配同构，但更宽松：弹幕库的标题常常带平台后缀、集名格式也不统一，
/// 因此阈值更低（0.6），且「集号相同」比「标题完全一致」更重要。
library;

import 'subtitle_provider.dart' show normalizeSubtitleTitle;

/// 一次弹幕库查询。
class DanmakuQuery {
  const DanmakuQuery({
    required this.title,
    this.episode,
    required this.siteKey,
    required this.vodId,
    required this.episodeName,
  });

  final String title;
  final String? episode;
  final String siteKey;
  final String vodId;
  final String episodeName;

  String get normalizedTitle => normalizeSubtitleTitle(title);

  @override
  String toString() =>
      'DanmakuQuery("$title", ep=$episode, $siteKey/$vodId)';
}

/// 弹幕库返回的一条候选。
class DanmakuLibraryEntry {
  const DanmakuLibraryEntry({
    required this.providerId,
    required this.id,
    required this.title,
    required this.episode,
    required this.url,
    this.count = 0,
    this.score = 0,
  });

  final String providerId;
  final String id;
  final String title;
  final String episode;
  final String url;

  /// 条数；0 表示库没给。
  final int count;

  /// 0..1；由 [rankDanmakuEntries] 计算。
  final double score;

  String get normalizedTitle => normalizeSubtitleTitle(title);

  DanmakuLibraryEntry copyWithScore(double value) => DanmakuLibraryEntry(
    providerId: providerId,
    id: id,
    title: title,
    episode: episode,
    url: url,
    count: count,
    score: value,
  );

  @override
  String toString() =>
      'DanmakuLibraryEntry($providerId/$id "$title" ep=$episode '
      '${score.toStringAsFixed(3)})';
}

/// 匹配记忆（DB 行）。
class DanmakuMatchRecord {
  const DanmakuMatchRecord({
    required this.siteKey,
    required this.vodId,
    required this.episodeName,
    required this.providerId,
    required this.entryId,
    required this.title,
    required this.episode,
    required this.url,
    required this.updatedAt,
  });

  final String siteKey;
  final String vodId;
  final String episodeName;
  final String providerId;
  final String entryId;
  final String title;
  final String episode;
  final String url;
  final int updatedAt;

  factory DanmakuMatchRecord.fromRow(Map<String, Object?> row) =>
      DanmakuMatchRecord(
        siteKey: (row['site_key'] as String?) ?? '',
        vodId: (row['vod_id'] as String?) ?? '',
        episodeName: (row['episode_name'] as String?) ?? '',
        providerId: (row['provider_id'] as String?) ?? '',
        entryId: (row['entry_id'] as String?) ?? '',
        title: (row['title'] as String?) ?? '',
        episode: (row['episode'] as String?) ?? '',
        url: (row['url'] as String?) ?? '',
        updatedAt: (row['updated_at'] as int?) ?? 0,
      );

  factory DanmakuMatchRecord.fromEntry({
    required String siteKey,
    required String vodId,
    required String episodeName,
    required DanmakuLibraryEntry entry,
    int? updatedAt,
  }) => DanmakuMatchRecord(
    siteKey: siteKey,
    vodId: vodId,
    episodeName: episodeName,
    providerId: entry.providerId,
    entryId: entry.id,
    title: entry.title,
    episode: entry.episode,
    url: entry.url,
    updatedAt: updatedAt ?? DateTime.now().millisecondsSinceEpoch,
  );

  DanmakuLibraryEntry toEntry() => DanmakuLibraryEntry(
    providerId: providerId,
    id: entryId,
    title: title,
    episode: episode,
    url: url,
  );
}

/// 自动加载阈值。
const double kDanmakuAutoPickThreshold = 0.6;

/// 从「第12集 / EP12 / 12 / 第12-13集」里抽出第一个整数；抽不出返回 null。
int? extractEpisodeNumber(String? raw) {
  final text = raw?.trim() ?? '';
  if (text.isEmpty) return null;
  final match = RegExp(r'\d+').firstMatch(text);
  if (match == null) return null;
  return int.tryParse(match.group(0)!);
}

/// 集号一致性得分：任一侧缺失 0.5；相同 1；否则 0。
double _episodeScore(String? query, String? candidate) {
  final a = extractEpisodeNumber(query);
  final b = extractEpisodeNumber(candidate);
  if (a == null || b == null) return 0.5;
  return a == b ? 1 : 0;
}

/// 综合得分：标题 0.7 + 集号 0.3。
double scoreDanmakuEntry({
  required DanmakuLibraryEntry entry,
  required DanmakuQuery query,
}) {
  final title = titleScoreForDanmaku(query.title, entry.title);
  final episode = _episodeScore(query.episode, entry.episode);
  return title * 0.7 + episode * 0.3;
}

/// 弹幕标题相似度：完全相等 1；包含 0.9；否则按长度差衰减（最低 0）。
double titleScoreForDanmaku(String queryTitle, String candidateTitle) {
  final a = normalizeSubtitleTitle(queryTitle);
  final b = normalizeSubtitleTitle(candidateTitle);
  if (a.isEmpty || b.isEmpty) return 0;
  if (a == b) return 1;
  if (a.contains(b) || b.contains(a)) return 0.9;
  // 弹幕库常见「剧名 + 平台后缀」，用最长公共子串比例兜底。
  final common = _longestCommonSubstring(a, b);
  if (common == 0) return 0;
  return (common / a.length) * 0.8;
}

int _longestCommonSubstring(String a, String b) {
  var best = 0;
  final previous = List<int>.filled(b.length + 1, 0);
  for (var i = 1; i <= a.length; i++) {
    var diagonal = 0;
    for (var j = 1; j <= b.length; j++) {
      final temp = previous[j];
      if (a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1)) {
        previous[j] = diagonal + 1;
        if (previous[j] > best) best = previous[j];
      } else {
        previous[j] = 0;
      }
      diagonal = temp;
    }
  }
  return best;
}

/// 打分并稳定排序。
List<DanmakuLibraryEntry> rankDanmakuEntries({
  required Iterable<DanmakuLibraryEntry> entries,
  required DanmakuQuery query,
}) {
  final scored = [
    for (final entry in entries)
      entry.copyWithScore(scoreDanmakuEntry(entry: entry, query: query)),
  ]..sort((a, b) {
    final byScore = b.score.compareTo(a.score);
    if (byScore != 0) return byScore;
    final byProvider = a.providerId.compareTo(b.providerId);
    return byProvider != 0 ? byProvider : a.id.compareTo(b.id);
  });
  return scored;
}

/// 取最佳候选；低于阈值返回 null。
DanmakuLibraryEntry? pickDanmakuEntry({
  required Iterable<DanmakuLibraryEntry> entries,
  required DanmakuQuery query,
  double threshold = kDanmakuAutoPickThreshold,
}) {
  final ranked = rankDanmakuEntries(entries: entries, query: query);
  if (ranked.isEmpty) return null;
  return ranked.first.score >= threshold ? ranked.first : null;
}
