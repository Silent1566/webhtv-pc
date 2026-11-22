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
    this.year,
    required this.siteKey,
    required this.vodId,
    required this.episodeName,
  });

  final String title;
  final String? episode;

  /// 作品年份（来自详情页 `Vod.vodYear`，见 `PlaybackRequest.vodYear`）。
  ///
  /// 为什么由调用方给而不是从 [title] 里解析：站点的 `vod_year` 是结构化字段，
  /// 标题里的 `(2026)` 只是弹幕库自己的写法；两者都有时以站点为准。
  /// 默认 null = 不知道，打分时按「中性」处理，既有构造点一行都不用改。
  final int? year;
  final String siteKey;
  final String vodId;
  final String episodeName;

  String get normalizedTitle => normalizeSubtitleTitle(title);

  @override
  String toString() => 'DanmakuQuery("$title", ep=$episode, $siteKey/$vodId)';
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
    this.libraryId = '',
    this.libraryName = '',
    this.channel = '',
    this.episodeNumber,
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

  /// 命中的弹幕源 id（`DanmakuSourceConfig.id`）。
  ///
  /// 多源并行后必须能回答「这条来自哪」，否则 UI 的来源筛选只能靠猜；
  /// 单源调用方不填，默认空串让旧构造点一行都不用改。
  final String libraryId;

  /// 弹幕源显示名，与 [libraryId] 同源。
  final String libraryName;

  /// 渠道（bilibili / dandan / qq…），由 `danmakuChannelOf` 解析。
  final String channel;

  /// 集号（数值）。在**协议转换时**从弹幕名解析一次，之后排序/过滤只读它。
  ///
  /// 为什么不排序时再解析 `episode` 字符串：那串是给人看的
  /// （`【qq】 一马当先 第1集`），格式随上游变的概率远高于数值本身；
  /// 一旦某个源换了写法，解析失败就会让整组退化成「按上游原始顺序」，
  /// 看起来就像按字符串排序。字段化之后，解析只在入口做一次、可单测、可回退。
  final int? episodeNumber;

  String get normalizedTitle => normalizeSubtitleTitle(title);

  DanmakuLibraryEntry copyWithScore(double value) => copyWith(score: value);

  /// 复制并替换字段；多源合并时用它带上归属信息。
  DanmakuLibraryEntry copyWith({
    double? score,
    String? libraryId,
    String? libraryName,
    String? channel,
    int? episodeNumber,
  }) => DanmakuLibraryEntry(
    providerId: providerId,
    id: id,
    title: title,
    episode: episode,
    url: url,
    count: count,
    score: score ?? this.score,
    libraryId: libraryId ?? this.libraryId,
    libraryName: libraryName ?? this.libraryName,
    channel: channel ?? this.channel,
    episodeNumber: episodeNumber ?? this.episodeNumber,
  );

  @override
  String toString() =>
      'DanmakuLibraryEntry($providerId/$id "$title" ep=$episode '
      '${score.toStringAsFixed(3)}'
      '${libraryId.isEmpty ? '' : ' @$libraryId'}'
      '${channel.isEmpty ? '' : ' [$channel]'}'
      '${episodeNumber == null ? '' : ' #$episodeNumber'})';
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

/// 复合题分的权重（集中一处：调权重只改这里）。
///
/// 为什么是这个分配：题名仍是「是不是这部片」的主证据，其它维度只在名字
/// 相似时做**裁决**，不能反客为主。
/// - 名称 0.70：最可信，但最容易被平台后缀污染（`from X`、`【来源N】`），
///   所以只留 0.30 给能「判死」的硬信息；
/// - 年份 0.12：同名不同年是最常见的假命中（《一马当先》2026 电视剧 vs
///   2023 短剧），必须大过季与类型，又小于「名字差一截」的代价；
/// - 季 0.10：第二季/第一季的题名去掉季标记后完全同形，不单独计分就永远分不开；
/// - 类型 0.08：动漫/电视剧/短剧区分同名不同形态，但上游经常不标类型
///   （查询侧尤其常缺），命中率最低，权重也最小。
const double kDanmakuTitleWeightBase = 0.70;
const double kDanmakuTitleWeightYear = 0.12;
const double kDanmakuTitleWeightSeason = 0.10;
const double kDanmakuTitleWeightType = 0.08;

/// 条目总分里「题名 / 集号」的权重：保持旧值——[kDanmakuAutoPickThreshold]
/// 与已写下的匹配记忆都是按这组系数标定的，改了会让「以前能自动命中」的片
/// 悄悄降到阈值以下。
const double kDanmakuEntryWeightTitle = 0.7;
const double kDanmakuEntryWeightEpisode = 0.3;

/// 弹幕名前缀里的结构化信息（安卓 `DanmakuTitle` 的 Dart 版，但保留年份）。
class DanmakuTitleInfo {
  const DanmakuTitleInfo({
    required this.base,
    this.year,
    this.season,
    this.type,
  });

  /// 去掉年份/季/类型标记后的名称；**保留**原有空格与标点。
  ///
  /// 不在这里就清成「纯字母数字」：调用方还要把它写进日志与调试输出；
  /// 真正比较时由 [_baseTitleScore] 各自归一化。
  final String base;

  /// 年份：`(2026)` / `（2026）` / `【2026】`。
  final int? year;

  /// 季：`第二季` / `第2季` / `Season 2` / `S2`。
  ///
  /// `S02E07` 里的 `S02` **不算**季：那里的数字首先是集号。
  final int? season;

  /// 已知类型词：`电视剧`/`短剧`/`综艺`/`动漫`/`纪录片`/`电影`/`3D网络放送` 一类标记。
  final String? type;

  @override
  String toString() =>
      'DanmakuTitleInfo("$base", year=$year, season=$season, type=$type)';
}

/// 【】/[] 标记：同一种写法既可能是类型，也可能是来源。
final RegExp _titleMarkPattern = RegExp('[【\\[]([^】\\]]{1,24})[】\\]]');

/// 全角/半角括号里的四位年份。
final RegExp _parenYearPattern = RegExp('[（(]\\s*((?:19|20)\\d{2})\\s*[）)]');

/// 纯年份（`【2026】`）。
final RegExp _yearOnlyPattern = RegExp(r'^(?:19|20)\d{2}$');

/// 已知类型词。
///
/// 为什么用白名单而不是「【】里就是类型」：中转把**来源**也写成【】
/// （`【bilibili1】`、`【qq】`）。按位置猜会把来源当类型，类型维度就退化成
/// 「渠道不同 → 不像」，同一部剧来自两个源反而互相压低。
const Set<String> _danmakuTypeWords = {
  '电视剧',
  '短剧',
  '微短剧',
  '综艺',
  '动漫',
  '动画',
  '番剧',
  '纪录片',
  '电影',
  '剧场版',
  '真人秀',
  '3d网络放送',
  '2d网络放送',
};

final RegExp _seasonWordPattern = RegExp(r'第\s*([0-9]+|[一二三四五六七八九十]+)\s*季');
final RegExp _seasonEnglishPattern = RegExp(r'[Ss]eason\s*([0-9]{1,2})');

/// `S2`/`s02` 形式的季标记。
///
/// 两个负向前瞻缺一不可：`S02E07` 是「第 2 季第 7 集」的写法，但它首先表达的是
/// **集号**。少了 `(?!\s*[Ee]\s*\d)` 会把 `S02E07` 的 `S02` 当季；少了
/// `(?!\d)` 时正则会回溯到只剩 `S0` 也满足前一条，于是它被判成「第 0 季」——
/// 比误判成第 2 季更糟，连方向都错了。
final RegExp _seasonShortPattern = RegExp(r'[Ss]\s*(\d{1,2})(?!\d)(?!\s*[Ee]\s*\d)');

/// 中文数字（季标记里的 `第二季`）。
const Map<String, int> _danmakuChineseDigits = {
  '一': 1,
  '二': 2,
  '三': 3,
  '四': 4,
  '五': 5,
  '六': 6,
  '七': 7,
  '八': 8,
  '九': 9,
};

/// 从弹幕名里解析出名称/年份/季/类型。
///
/// 真实样例：
/// - `一马当先(2026)【电视剧】from tencent` → base `一马当先`、2026、电视剧
/// - `灵笼 第二季(2025)【动漫】from bilibili` → base `灵笼`、2025、季 2、动漫
/// - `灵笼 S02E07` → base 原样、季 null（S02 是集号的一部分）
DanmakuTitleInfo parseDanmakuTitleInfo(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return const DanmakuTitleInfo(base: '');
  int? year;
  String? type;
  final removed = <({int start, int end})>[];
  for (final match in _titleMarkPattern.allMatches(text)) {
    final content = match.group(1)!.trim();
    if (content.isEmpty) continue;
    if (year == null && _yearOnlyPattern.hasMatch(content)) {
      year = int.tryParse(content);
      removed.add((start: match.start, end: match.end));
      continue;
    }
    if (type == null && _danmakuTypeWords.contains(content.toLowerCase())) {
      type = content;
      removed.add((start: match.start, end: match.end));
    }
  }
  if (year == null) {
    final paren = _parenYearPattern.firstMatch(text);
    if (paren != null) {
      year = int.tryParse(paren.group(1)!);
      removed.add((start: paren.start, end: paren.end));
    }
  }
  var base = _removeSpans(text, removed);
  // 季标记在「去掉标记之后」的串上找：标记里的数字（`【bilibili1】`）不参与季判断。
  final season = _seasonOf(base);
  if (season != null) base = base.replaceRange(season.start, season.end, '');
  return DanmakuTitleInfo(
    base: base.trim(),
    year: year,
    season: season?.value,
    type: type,
  );
}

String _removeSpans(String source, Iterable<({int start, int end})> spans) {
  final sorted = spans.toList()..sort((a, b) => a.start.compareTo(b.start));
  final buffer = StringBuffer();
  var cursor = 0;
  for (final span in sorted) {
    // 重叠的标记（理论上不会出现）直接跳过，避免把同一段删两次。
    if (span.start < cursor) continue;
    buffer.write(source.substring(cursor, span.start));
    cursor = span.end;
  }
  if (cursor < source.length) buffer.write(source.substring(cursor));
  return buffer.toString();
}

/// 季标记按可信度择序：中文/数字「第 N 季」→ `Season N` → `S2`。
({int value, int start, int end})? _seasonOf(String text) {
  for (final pattern in [
    _seasonWordPattern,
    _seasonEnglishPattern,
    _seasonShortPattern,
  ]) {
    final match = pattern.firstMatch(text);
    if (match == null) continue;
    final value = _danmakuNumber(match.group(1)!);
    if (value != null) {
      return (value: value, start: match.start, end: match.end);
    }
  }
  return null;
}

int? _danmakuNumber(String raw) {
  final text = raw.trim();
  final plain = int.tryParse(text);
  if (plain != null) return plain;
  if (text == '十') return 10;
  if (text.length == 1) return _danmakuChineseDigits[text];
  if (text.length == 2) {
    if (text.startsWith('十')) return 10 + (_danmakuChineseDigits[text[1]] ?? 0);
    if (text.endsWith('十')) return (_danmakuChineseDigits[text[0]] ?? 0) * 10;
  }
  if (text.length == 3 && text[1] == '十') {
    return (_danmakuChineseDigits[text[0]] ?? 0) * 10 +
        (_danmakuChineseDigits[text[2]] ?? 0);
  }
  return null;
}
/// 集号候选的识别顺序：越靠前越可信。
///
/// 首个整数不可靠——中转标题形如「【bilibili1】 第2话 波澜初起」，
/// 直接取首个整数会得到 1，让不同集互相撞车。
const List<String> _episodePatterns = [
  // 第12集 / 第 12 话 / 第12-13集（区间取首集）
  r'第\s*(\d+)\s*(?:[-~～－—]\s*\d+\s*)?[集话期回章部]',
  // S01E12 / s1 e12（安卓 `DanmakuTitle.EPISODE_SEASON` 同款）
  r'[Ss]\s*\d{1,2}\s*[Ee]\s*(\d{1,5})',
  // EP03 / E12 / ep 5
  r'[Ee][Pp]?\s*(\d+)',
  // 「2话」这类紧跟集单位、但没有「第」的写法
  r'(\d+)\s*[集话期回章部]',
];

/// 从「第12集 / EP12 / 12 / 第12-13集」里抽出集号；抽不出返回 null。
int? extractEpisodeNumber(String? raw) {
  // 全角数字先归一成半角：上游偶尔下发「第１２集」，正则不认全角，
  // 解析失败会退化成「按上游原始顺序」，表现就像按字符串排序。
  final text = (raw ?? '')
      .replaceAllMapped(
        RegExp(r'[０-９]'),
        (match) => String.fromCharCode(match.group(0)!.codeUnitAt(0) - 0xFEE0),
      )
      .trim();
  if (text.isEmpty) return null;
  for (final pattern in _episodePatterns) {
    final match = RegExp(pattern).firstMatch(text);
    if (match == null) continue;
    final value = int.tryParse(match.group(1)!);
    if (value != null) return value;
  }
  final fallback = RegExp(r'\d+').firstMatch(text);
  if (fallback == null) return null;
  return int.tryParse(fallback.group(0)!);
}

/// 集号一致性得分：任一侧缺失 0.5（不奖不罚）；相同 1；否则 0。
double _episodeScore(DanmakuQuery query, DanmakuLibraryEntry entry) {
  // 候选侧优先读协议转换时算好的数值字段：展示串（`【qq】 一马当先 第1集`）
  // 的写法随上游变，字段不会；字段为空才回退到现场解析。
  final candidate = entry.episodeNumber ?? extractEpisodeNumber(entry.episode);
  final target = extractEpisodeNumber(query.episode);
  if (target == null || candidate == null) return 0.5;
  return target == candidate ? 1 : 0;
}

/// 一条候选与查询的相似度（0..1）：复合题分 × 0.7 + 集号一致性 × 0.3。
///
/// 为什么单独暴露：分组要按「组内最像的那条」排序（`danmaku_catalog.dart` 的
/// 组间排序），UI 也要能直接展示「这条有多像」。打分只有这一处，避免两套算法
/// 慢慢跑偏。
double danmakuEntrySimilarity({
  required DanmakuLibraryEntry entry,
  required DanmakuQuery query,
}) {
  final title = titleScoreForDanmaku(query.title, entry.title, year: query.year);
  final episode = _episodeScore(query, entry);
  return title * kDanmakuEntryWeightTitle +
      episode * kDanmakuEntryWeightEpisode;
}

/// 综合得分：复合题分 0.7 + 集号 0.3（旧名字，行为等于 [danmakuEntrySimilarity]）。
double scoreDanmakuEntry({
  required DanmakuLibraryEntry entry,
  required DanmakuQuery query,
}) => danmakuEntrySimilarity(entry: entry, query: query);

/// 题名相似度：名称 + 年份 + 季 + 类型 的加权复合分（0..1）。
///
/// 为什么不再只比字符串：同名不同年/不同季/不同形态的片在弹幕库里同时存在
/// （《一马当先》2026 电视剧 vs 2023 短剧、《灵笼》第一季 vs 第二季），
/// 只看名称会把它们打成同分，自动匹配和用户的首屏顺序就只能靠到达顺序。
///
/// 任一维度只有一侧有值时给**中性分**而不是 0：上游漏标年份/类型是常态，
/// 当成「不匹配」会把大半候选一棍子打死，阈值 0.6 的自动匹配也随之失灵。
///
/// [year] 是查询侧的外部年份（`PlaybackRequest.vodYear`），优先于查询标题里
/// 解析出的年份——详情页拿得到站点的 `vod_year`，比库标题里的括号更权威。
double titleScoreForDanmaku(
  String queryTitle,
  String candidateTitle, {
  int? year,
}) {
  final query = parseDanmakuTitleInfo(queryTitle);
  final candidate = parseDanmakuTitleInfo(candidateTitle);
  final queryYear = year ?? query.year;
  return _baseTitleScore(query.base, candidate.base) *
          kDanmakuTitleWeightBase +
      _yearScore(queryYear, candidate.year) * kDanmakuTitleWeightYear +
      _seasonScore(query.season, candidate.season) *
          kDanmakuTitleWeightSeason +
      _typeScore(query.type, candidate.type) * kDanmakuTitleWeightType;
}

/// 名称相似度：完全相等 1；候选包含查询 0.9；查询包含候选 0.85；否则按
/// 最长公共子串占查询长度的比例 × 0.8 衰减。
///
/// 两个包含方向不再同分：库标题整体比查询长是常态（带平台后缀），说明「候选
/// 是这部剧的一个更长写法」；反过来查询更长则更像「查询是这句话的一部分」，
/// 证据弱一点，所以 0.85。
double _baseTitleScore(String queryBase, String candidateBase) {
  final a = normalizeSubtitleTitle(queryBase);
  final b = normalizeSubtitleTitle(candidateBase);
  if (a.isEmpty || b.isEmpty) return 0;
  if (a == b) return 1;
  if (b.contains(a)) return 0.9;
  if (a.contains(b)) return 0.85;
  // 弹幕库常见「剧名 + 平台后缀」，用最长公共子串比例兜底。
  final common = _longestCommonSubstring(a, b);
  if (common == 0) return 0;
  return (common / a.length) * 0.8;
}

/// 年份一致性：两边都有才判；相同 1、不同 0，否则 0.5。
double _yearScore(int? query, int? candidate) {
  if (query == null || candidate == null) return 0.5;
  return query == candidate ? 1 : 0;
}

/// 季一致性：两边都没有季标记 → 1（都是「正片」，不是缺证据）；只有一侧有 →
/// 0.6（一部剧的正片与它有季标记的分集通常仍是同一部，不该判死）；都有 → 同 1 异 0。
double _seasonScore(int? query, int? candidate) {
  if (query == null && candidate == null) return 1;
  if (query == null || candidate == null) return 0.6;
  return query == candidate ? 1 : 0;
}

/// 类型一致性：查询侧没有类型（最常见）→ 0.5 中性；有类型时同 1 异 0。
double _typeScore(String? query, String? candidate) {
  final a = (query ?? '').trim().toLowerCase();
  if (a.isEmpty) return 0.5;
  return a == (candidate ?? '').trim().toLowerCase() ? 1 : 0;
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
///
/// 同分保留来源顺序：弹幕中转（danmu_api 一类）返回的顺序就是相关度顺序。
/// Dart 的 [List.sort] 不稳定，所以用「下标 + 条目」装饰后排序再还原。
List<DanmakuLibraryEntry> rankDanmakuEntries({
  required Iterable<DanmakuLibraryEntry> entries,
  required DanmakuQuery query,
}) {
  final scored = <MapEntry<int, DanmakuLibraryEntry>>[];
  var index = 0;
  for (final entry in entries) {
    final scoredEntry = entry.copyWithScore(
      scoreDanmakuEntry(entry: entry, query: query),
    );
    scored.add(MapEntry(index++, scoredEntry));
  }
  scored.sort((a, b) {
    final byScore = b.value.score.compareTo(a.value.score);
    return byScore != 0 ? byScore : a.key.compareTo(b.key);
  });
  return [for (final item in scored) item.value];
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
