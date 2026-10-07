/// TMDB 标题清洗、年份与季度信号解析、匹配评分（`docs/phase4/design/01` §3/§5）。
///
/// 这一层是**纯逻辑**：不依赖 Flutter，也不依赖 `dart:io`，可在 `flutter test`
/// 中无副作用运行（`docs/phase4/design/04` §2.1 约束）。
///
/// 上游对应实现：
/// - `TmdbMatcher.cleanVideoName`（清洗）
/// - `MediaTitleParser.cleanTitle` / `parse`（清洗与信号）
/// - `TmdbMatcher.chooseStrictMatch` / `chooseContainedYearMatch` / `chooseSmartMatch`
/// - `TmdbMatcher.sortSearchResults`（相似度与语言偏好）
/// - `TmdbMatchPolicy`（分季变体防护）
///
/// 设计文档明确要求：清洗步骤**顺序固定，不可调换**（`01` §3.3）。
library;

// ---------------------------------------------------------------------------
// 正则常量（与 `01` §3.3–§3.5 一一对应）
// ---------------------------------------------------------------------------

final RegExp _fileExtension = RegExp(
  r'\.(mkv|mp4|avi|mov|wmv|flv|rmvb|ts|m2ts)$',
  caseSensitive: false,
);

/// 噪声括号段：`[...]`、`【...】`、`「...」`、`『...』`、`(...)`、`（...）`。
final RegExp _bracketPattern = RegExp(
  r'[\[【「『(（]([^\]】」』)）]{1,60})[\]】」』)）]',
);

/// 书名号内的标题要被**提取**而不是丢弃（`01` §3.3 步骤 2 的例外）。
final RegExp _bookTitlePattern = RegExp(r'《([^》]{1,80})》');

final RegExp _seasonEpisodeMark = RegExp(
  r'S\d+E\d+'
  r'|\b(S\d{1,2}|Season\s*\d{1,2})\b'
  r'|第\d+季'
  r'|第\d+集'
  r'|第\s*[一二三四五六七八九十百零〇两0-9]+\s*[季部]'
  r'|第\s*[一二三四五六七八九十百零〇两0-9]+\s*[集话話回期章节節]'
  r'|\b(EP|E|Episode)\s*0*\d{1,5}\b',
  caseSensitive: false,
);

final RegExp _qualityMark = RegExp(
  r'\b(HD|4K|8K|1080P|2160P|720P|HDR|HDR10|DV|BluRay|WEB[- ]?DL|HDTV|BDRip'
  r'|Remux|HEVC|H\.?265|H\.?264|x265|x264|AAC|DTS|DDP|Atmos|NF|Netflix|AMZN|DSNP)\b',
  caseSensitive: false,
);

final RegExp _frameRateMark = RegExp(
  r'(?<!\d)(?:24|25|30|50|60|120)\s*(?:fps|帧)(?![\u4e00-\u9fffA-Za-z0-9])',
  caseSensitive: false,
);

final RegExp _updateTail = RegExp('(更新至|更至|连载至|連載至)');

final RegExp _editionTail = RegExp(
  '国语版|国配版|普通话版|粤语版|台语版|闽南语版|原声版|配音版|中字版|字幕版'
  '|台版|台灣版|台湾版|港版|港澳版|大陆版|內地版|内地版|中国版|中國版'
  '|泰版|泰国版|泰國版|韩版|韩国版|韓國版|日版|日本版|美版|美国版|美國版'
  '|英版|英国版|英國版',
);

final RegExp _qualityWord = RegExp(
  // 「高码率」必须排在「高码」之前，否则短备选会先吃掉前缀留下「率」。
  '真彩|臻彩|高码率|高码|无水印|无台标|国语|国配|国粤|粤语|中字|字幕'
  '|内封|简繁|双语|官中|杜比|合集|全集|完结|未删减|加长版|修复版',
);

final RegExp _hashMark = RegExp('[#＃]+');

final RegExp _genreWord = RegExp('(^|\\s)(动漫|动画|电视剧|剧集|电影|综艺)(\\s|\$)');

final RegExp _separatorRun = RegExp(r'[._\-+]+');

final RegExp _leadingSingleLatin = RegExp(r'^[a-z]\s+(?=.*[\u4e00-\u9fff])');

final RegExp _cjkWithTrailingLatin = RegExp(r'.*[\u4e00-\u9fff].*\s+[a-z]$');

final RegExp _cjkSpace = RegExp(r'([\u4e00-\u9fff])\s+([\u4e00-\u9fff])');

final RegExp _edgePunctuation = RegExp(
  r'^[\s:：,，.。·|/\\]+|[\s:：,，.。·|/\\]+$',
);

/// 年份（归一化用）：前后非数字边界，范围 1900–2099。
final RegExp yearPattern = RegExp(r'(?<!\d)(19\d{2}|20\d{2})(?!\d)');

/// 完整上映日期形态，必须先剥离再取年份（避免把 `20240115` 当标题）。
final RegExp releaseDatePattern = RegExp(
  r'(?<!\d)(?:19|20)\d{2}'
  r'(?:[-./_](?:0?[1-9]|1[0-2])[-./_](?:0?[1-9]|[12]\d|3[01])'
  r'|(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01]))'
  r'(?!\d)',
);

/// 季度信号（`01` §3.5）。三个捕获组分别对应中文季度、`season N`、`sNNeMM`。
final RegExp sourceSeasonPattern = RegExp(
  '(?:第\\s*([零〇一二三四五六七八九十两0-9]+)\\s*[季部]'
  '|season\\s*([0-9]{1,2})'
  '|s([0-9]{1,2})(?:[-._\\s]*e[0-9]{1,3})?)',
  caseSensitive: false,
);

/// 分季变体判定用的显式季度标记（`01` §5.4）。
final RegExp _explicitSeasonPattern = RegExp(
  '(第\\s*[零〇一二三四五六七八九十两0-9]+\\s*[季部]'
  '|season\\s*[0-9]{1,2}'
  '|s[0-9]{1,2}(?:[-._\\s]*e[0-9]{1,3})?)',
  caseSensitive: false,
  dotAll: true,
);

/// 推送 URL（`01` §5.4 推送标题守卫）。
final RegExp pushUrlPattern = RegExp(
  r'^(?:https?|rtsp|rtmp|mms|magnet|ed2k|thunder|video|file):\S+$',
  caseSensitive: false,
);

/// 推送通用标题（`01` §5.4 推送标题守卫）。
final RegExp pushGenericTitlePattern = RegExp(
  '(?:online\\s*video|network\\s*video|web\\s*video|video|push|cast'
  '|在线视频|网络视频|网页视频|推送|投屏|视频)'
  '(?:\\s*(?:[-_#.]?\\s*\\d{1,4}))?\$',
  caseSensitive: false,
);

final RegExp _hasCjkOrLatin = RegExp(r'[\u4e00-\u9fffA-Za-z]');

final RegExp _pureDigits = RegExp(r'^(?:0*\d{1,4})$');

final RegExp _normalizeStrip = RegExp(r'[\s·•:：\-_/\\|()（）\[\]【】]+');

/// 中文数字 → 阿拉伯数字（`01` §3.5 要求）。
const Map<String, int> _chineseDigits = {
  '零': 0, '〇': 0, '一': 1, '二': 2, '两': 2, '三': 3, '四': 4,
  '五': 5, '六': 6, '七': 7, '八': 8, '九': 9,
};

/// 把中文数字串（`零〇一二三四五六七八九十两` 与阿拉伯数字混排）转为整数。
///
/// 支持 `二`、`十二`、`二十`、`二十三`、`〇`、`0`–`99`。
/// 无法解析时返回 `null`。
int? parseChineseNumber(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return null;
  if (RegExp(r'^\d+$').hasMatch(text)) return int.tryParse(text);

  var total = 0;
  var current = 0;
  var sawAny = false;
  for (final rune in text.runes) {
    final char = String.fromCharCode(rune);
    if (char == '十') {
      // 单独的「十」表示 10；「二十」表示 2*10；「二十三」表示 20+3。
      total += (current == 0 ? 1 : current) * 10;
      current = 0;
      sawAny = true;
      continue;
    }
    final digit = _chineseDigits[char];
    if (digit == null) return null;
    current = digit;
    sawAny = true;
  }
  if (!sawAny) return null;
  return total + current;
}

/// 标题清洗（`01` §3.3）。步骤顺序固定，不可调换。
///
/// 兜底：清洗结果为空时返回**原始输入**，不得返回空串（否则搜索必失败）。
String cleanTitle(String input) {
  final raw = input.trim();
  if (raw.isEmpty) return '';

  var text = raw;

  // 1. 去文件扩展名
  text = text.replaceAll(_fileExtension, '');

  // 2. 书名号内容优先提取（例外：提取而不是丢弃）
  final book = _bookTitlePattern.firstMatch(text);
  if (book != null) {
    final inner = book.group(1)!.trim();
    if (inner.isNotEmpty) text = inner;
  }

  // 3. 去噪声括号段
  text = text.replaceAll(_bracketPattern, ' ');

  // 4. 去季集标记
  text = text.replaceAll(_seasonEpisodeMark, ' ');

  // 5. 去清晰度/编码标记
  text = text.replaceAll(_qualityMark, ' ');

  // 6. 去帧率标记
  text = text.replaceAll(_frameRateMark, ' ');

  // 7. 去更新尾巴（非锚定：`更新至` 在尾部噪声之前出现时也要能被清除）
  text = text.replaceAll(_updateTail, ' ');

  // 8. 去版本/语言尾巴
  text = text.replaceAll(_editionTail, '');

  // 9. 去质量词
  text = text.replaceAll(_qualityWord, '');

  // 10. 去 `#` / `＃`
  text = text.replaceAll(_hashMark, '');

  // 11. 去独立出现的体裁词
  text = text.replaceAll(_genreWord, ' ');

  // 12. 分隔符归一与空白压缩
  text = text.replaceAll(_separatorRun, ' ');
  text = text.trim().replaceAll(RegExp(r'\s+'), ' ');

  // 13. 中英混排清理
  text = text.replaceAll(_leadingSingleLatin, '');
  if (_cjkWithTrailingLatin.hasMatch(text)) {
    text = text.replaceAll(RegExp(r'\s+[a-z]$'), '');
  }
  // Dart 的 `replaceAll` 不解释 `$1` 分组引用，必须用 `replaceAllMapped`。
  text = text.replaceAllMapped(_cjkSpace, (match) => '${match[1]}${match[2]}');

  // 14. 去首尾标点
  text = text.replaceAll(_edgePunctuation, '');
  text = text.trim();

  return text.isEmpty ? raw : text;
}

/// 归一化：去掉 `[\s·•:：\-_/\\|()（）\[\]【】]+` 后小写（`01` §5.4）。
String normalizeTitle(String input) {
  final text = input.trim().toLowerCase();
  return text.replaceAll(_normalizeStrip, '').trim();
}

/// 提取年份（`01` §3.4）。
///
/// 先识别完整日期形态（`20240115` / `2024-01-15` / `2024.01.15`）并取其年份，
/// 再回退到独立的 1900–2099 年份。这样既不会把 `20240115` 的 `2024` 当成标题年份
/// 误删后丢失，也不会把 8 位日期整体当作年份。
int firstYear(String? input) {
  final text = input ?? '';
  if (text.isEmpty) return 0;

  final date = releaseDatePattern.firstMatch(text);
  if (date != null) {
    final year = int.tryParse(date.group(0)!.substring(0, 4));
    if (year != null && year >= 1900 && year <= 2099) return year;
  }

  for (final match in yearPattern.allMatches(text)) {
    final value = int.tryParse(match.group(1)!);
    if (value != null && value >= 1900 && value <= 2099) return value;
  }
  return 0;
}

/// 从标题中移除指定年份（用于年份拆分重试，`01` §5.5）。
String removeYearFromTitle(String input, int year) {
  var text = year > 0
      ? input.replaceAll(RegExp('(?<!\\d)$year(?!\\d)'), ' ')
      : input;
  text = text.replaceAll(RegExp(r'[\[【「『(（]\s*[\]】」』)）]'), ' ');
  text = text.replaceAll(_separatorRun, ' ');
  text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  text = text.replaceAll(_edgePunctuation, '');
  return cleanTitle(text);
}

/// 提取季度信号（`01` §3.5）。无法解析返回 `-1`（不是 `0`）。
int sourceSeasonNumber(String? input) {
  final text = input ?? '';
  if (text.isEmpty) return -1;
  for (final match in sourceSeasonPattern.allMatches(text)) {
    final raw = [match.group(1), match.group(2), match.group(3)]
        .whereType<String>()
        .firstWhere((value) => value.isNotEmpty, orElse: () => '');
    if (raw.isEmpty) continue;
    final number = parseChineseNumber(raw);
    if (number != null && number > 0) return number;
  }
  return -1;
}

/// 标题是否提到「分季」（`01` §5.4）。
bool mentionsSplitSeason(String? input) => normalizeTitle(input ?? '').contains('分季');

/// 标题是否含显式季度标记（`01` §5.4）。
bool mentionsExplicitSeason(String? input) =>
    _explicitSeasonPattern.hasMatch(input ?? '');

/// 源文本是否允许分季变体（`01` §5.4）。
bool allowsSplitSeasonVariant(String? sourceText) =>
    mentionsSplitSeason(sourceText) || mentionsExplicitSeason(sourceText);

/// TMDB 详情标题是否形如「分季变体」（`01` §5.4）。
///
/// `detailTitle` = `name + original_name + title + original_title` 拼接后归一。
bool isSplitSeasonDetail(String? detailTitle) =>
    normalizeTitle(detailTitle ?? '').contains('分季');

/// 分季变体得分（`01` §5.4 的四档）。
///
/// | 场景 | 得分 |
/// | --- | --- |
/// | 详情不含「分季」+ 源不允许分季 | `+140` |
/// | 详情不含「分季」+ 源允许分季 | `0` |
/// | 详情含「分季」+ 源显式提到分季 | `+160` |
/// | 详情含「分季」+ 源未提分季 | `-240` |
int splitSeasonDetailScore(String? sourceText, String? detailTitle) {
  final split = isSplitSeasonDetail(detailTitle);
  if (!split) return allowsSplitSeasonVariant(sourceText) ? 0 : 140;
  if (mentionsSplitSeason(sourceText)) return 160;
  return allowsSplitSeasonVariant(sourceText) ? 0 : -240;
}

/// 该候选是否为「不应接受的分季变体」（`01` §5.4）。
///
/// 含分季**且**源文本不允许分季 → 该候选**直接丢弃**（不是降分）。
bool isUnwantedSplitSeasonVariant(String? sourceText, String? detailTitle) =>
    isSplitSeasonDetail(detailTitle) && !allowsSplitSeasonVariant(sourceText);

/// 推送标题守卫（`01` §5.4）。
///
/// 全部条件满足才允许自动匹配：非 URL、非通用标题、含中英文字符、
/// 归一后长度 ≥ 2 且不是纯数字。
bool shouldAutoMatchPushTitle(String? title) {
  final value = (title ?? '').trim();
  if (value.isEmpty) return false;
  if (pushUrlPattern.hasMatch(value)) return false;
  if (pushGenericTitlePattern.hasMatch(value)) return false;
  if (!_hasCjkOrLatin.hasMatch(value)) return false;
  final normalized = normalizeTitle(value);
  return normalized.length >= 2 && !_pureDigits.hasMatch(normalized);
}

// ---------------------------------------------------------------------------
// 相似度与排序（`01` §5.6）
// ---------------------------------------------------------------------------

/// 编辑距离（Levenshtein）。
int levenshteinDistance(String first, String second) {
  if (first.isEmpty) return second.length;
  if (second.isEmpty) return first.length;
  var previous = List<int>.generate(second.length + 1, (i) => i);
  var current = List<int>.filled(second.length + 1, 0);
  for (var i = 1; i <= first.length; i++) {
    current[0] = i;
    for (var j = 1; j <= second.length; j++) {
      final cost = first.codeUnitAt(i - 1) == second.codeUnitAt(j - 1) ? 0 : 1;
      final delete = current[j - 1] + 1;
      final insert = previous[j] + 1;
      final substitute = previous[j - 1] + cost;
      current[j] = delete < insert
          ? (delete < substitute ? delete : substitute)
          : (insert < substitute ? insert : substitute);
    }
    final swap = previous;
    previous = current;
    current = swap;
  }
  return previous[second.length];
}

/// 标题相似度得分（`01` §5.6）。
///
/// - 归一后完全相等 → `1000`
/// - 一方包含另一方 → `800 + round(200 * min/max)`
/// - 其他 → `max(0, 700 - round(700 * levenshtein / max))`
int titleSimilarityScore(String title, String keyword) {
  final query = normalizeTitle(keyword);
  final target = normalizeTitle(title);
  if (query.isEmpty || target.isEmpty) return 0;
  if (target == query) return 1000;
  if (target.contains(query) || query.contains(target)) {
    final min = target.length < query.length ? target.length : query.length;
    final max = target.length > query.length ? target.length : query.length;
    return 800 + (200 * min / (max == 0 ? 1 : max)).round();
  }
  final max = target.length > query.length ? target.length : query.length;
  final distance = levenshteinDistance(target, query);
  return (700 - (700 * distance / (max == 0 ? 1 : max)).round()).clamp(0, 700);
}

/// 年份距离（未知年份记 9999，`01` §5.6）。
int yearDistance(int year, int sourceYear) =>
    year > 0 ? (year - sourceYear).abs() : 9999;

/// 语言/地区偏好得分（`01` §5.6）。
///
/// `+40` 地区完全匹配、`+25` 属偏好语种区、`+20` 语言匹配。
int localePreferenceScore({
  required String originalLanguage,
  required String originCountry,
  required String preferredLanguage,
  required String preferredCountry,
}) {
  final country = originCountry.toUpperCase();
  final language = originalLanguage.toLowerCase();
  var score = 0;
  if (preferredCountry.isNotEmpty && country == preferredCountry) score += 40;
  if (_isPreferredRegion(country, preferredLanguage)) score += 25;
  if (preferredLanguage.isNotEmpty && language == preferredLanguage) score += 20;
  return score;
}

bool _isPreferredRegion(String country, String preferredLanguage) {
  if (country.isEmpty || preferredLanguage.isEmpty) return false;
  switch (preferredLanguage) {
    case 'zh':
      return const {'CN', 'HK', 'TW', 'MO', 'SG'}.contains(country);
    case 'ja':
      return country == 'JP';
    case 'ko':
      return country == 'KR';
    default:
      return false;
  }
}

/// 从 `config.language`（如 `zh-CN`）推导偏好语言（`zh`）。
String preferredLanguageOf(String? language) {
  final text = (language ?? '').trim().toLowerCase();
  if (text.isEmpty) return '';
  final index = text.indexOf('-');
  return index > 0 ? text.substring(0, index) : text;
}

/// 从 `config.language`（如 `zh-CN`）推导偏好地区（`CN`）。
String preferredCountryOf(String? language) {
  final text = (language ?? '').trim();
  if (text.isEmpty) return '';
  final index = text.indexOf('-');
  return index > 0 && index < text.length - 1
      ? text.substring(index + 1).toUpperCase()
      : '';
}

/// 年份拆分重试的查询（`01` §5.5）。无法拆分时返回 `null`。
class SplitYearQuery {
  const SplitYearQuery(this.query, this.year);

  final String query;
  final int year;

  @override
  String toString() => 'SplitYearQuery($query, $year)';

  @override
  bool operator ==(Object other) =>
      other is SplitYearQuery && other.query == query && other.year == year;

  @override
  int get hashCode => Object.hash(query, year);
}

/// 生成年份拆分重试查询（`01` §5.5）。
///
/// ```text
/// splitYearQuery(keyword, sourceTitle, expectedYear):
///   year = expectedYear > 0 ? expectedYear : sourceYear(keyword, sourceTitle)
///   if year <= 0: return null
///   source = (keyword 含该年份) ? keyword : sourceTitle
///   if firstYear(source) != year: return null
///   query = removeYearFromTitle(source, year)
///   if query 为空 或 normalize(query) == normalize(source): return null
/// ```
SplitYearQuery? splitYearQuery({
  required String keyword,
  String? sourceTitle,
  int expectedYear = 0,
}) {
  final fallback = sourceTitle ?? '';
  var year = expectedYear > 0 ? expectedYear : firstYear(fallback);
  if (year <= 0) year = firstYear(keyword);
  if (year <= 0) return null;

  final source = (keyword.isNotEmpty && firstYear(keyword) == year)
      ? keyword
      : fallback;
  if (firstYear(source) != year) return null;

  final query = removeYearFromTitle(source, year);
  if (query.isEmpty || normalizeTitle(query) == normalizeTitle(source)) {
    return null;
  }
  return SplitYearQuery(query, year);
}

/// 源年份优先级：`vodYear` → `sourceTitle` → `keyword`（`01` §3.4）。
int sourceYear({
  String? vodYear,
  String? sourceTitle,
  String? keyword,
}) {
  final fromVod = firstYear(vodYear);
  if (fromVod > 0) return fromVod;
  final fromTitle = firstYear(sourceTitle);
  if (fromTitle > 0) return fromTitle;
  return firstYear(keyword);
}
