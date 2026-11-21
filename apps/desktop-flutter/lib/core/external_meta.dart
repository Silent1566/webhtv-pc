/// 外部元数据源（豆瓣 / Bangumi）的身份、检索查询与候选打分。
///
/// 这一层是**纯逻辑**：不依赖 Flutter、不依赖 `dart:io`、不发起任何请求，
/// 因此可以在 `flutter test` 里无副作用地把「匹配」这件事单独测。
/// 服务层只负责把网络结果填成
/// [MetaCandidate]，UI 只负责把 [MetaCandidate] 渲染出来。
///
/// 关键契约：
/// - 只在 TMDB 不可用时使用（用户决策 2026-11-17）；
/// - **宁可不匹配也不猜错**：候选之间分差不足时返回 `null`，与 TMDB 匹配层
///   的「歧义即未匹配」口径一致（`docs/phase4/design/01` §8）；
/// - 身份 id `<= 0` 一律视为无身份，不得构造 [MetaIdentity]。
library;

import 'meta_source.dart';
import 'tmdb_identity.dart';
import 'tmdb_title.dart';

// ---------------------------------------------------------------------------
// §1 身份
// ---------------------------------------------------------------------------

/// `MetaIdentity = kind + mediaType + id`。
///
/// 构造器私有，只能经 [of] / [parse] 创建，从类型层面挡住 `id <= 0`。
class MetaIdentity {
  const MetaIdentity._(this.kind, this.mediaType, this.id);

  /// 来源站点。
  final MetaSourceKind kind;

  /// 作品类型（沿用 TMDB 的 movie / tv 二分，外部源只有这两类值得兜底）。
  final TmdbMediaType mediaType;

  /// 该来源内的**原始**作品 id（豆瓣 subject id / Bangumi subject id）。
  final int id;

  /// 稳定字符串键，形如 `douban:tv:26359270` / `bangumi:tv:187187`。
  String get key => '${kind.key}:${mediaType.name}:$id';

  bool get isTv => mediaType == TmdbMediaType.tv;
  bool get isMovie => mediaType == TmdbMediaType.movie;

  /// 唯一合法入口：`id <= 0` 或类型无法识别时返回 `null`。
  static MetaIdentity? of(
    MetaSourceKind? kind,
    TmdbMediaType? mediaType,
    int? id,
  ) {
    if (kind == null ||
        kind == MetaSourceKind.source ||
        mediaType == null ||
        id == null ||
        id <= 0) {
      return null;
    }
    return MetaIdentity._(kind, mediaType, id);
  }

  /// 从 [key] 反解（形如 `douban:tv:26359270`）。
  static MetaIdentity? parse(String? key) {
    if (key == null) return null;
    final parts = key.split(':');
    if (parts.length != 3) return null;
    final kind = MetaSourceKind.parse(parts[0]);
    final mediaType = TmdbMediaType.parse(parts[1]);
    final id = int.tryParse(parts[2]);
    return of(kind, mediaType, id);
  }

  /// 该作品的来源页面地址；没有可打开的地址时为空串。
  String get url => switch (kind) {
    MetaSourceKind.douban => 'https://movie.douban.com/subject/$id/',
    MetaSourceKind.bangumi => 'https://bgm.tv/subject/$id',
    MetaSourceKind.wikidata => 'https://www.wikidata.org/wiki/Q$id',
    MetaSourceKind.tmdb || MetaSourceKind.source => '',
  };

  @override
  bool operator ==(Object other) =>
      other is MetaIdentity &&
      other.kind == kind &&
      other.mediaType == mediaType &&
      other.id == id;

  @override
  int get hashCode => Object.hash(kind, mediaType, id);

  @override
  String toString() => key;
}

// ---------------------------------------------------------------------------
// §2 检索查询
// ---------------------------------------------------------------------------

/// 一次外部检索的输入。
///
/// [aliases] 用来喂「来源标题」与「原名」：站源的 `vodName` 常带季号或清晰度
/// 尾巴，而外部站的主标题是干净的中文名，两者都要能命中。
class MetaQuery {
  const MetaQuery({
    required this.title,
    this.year = 0,
    this.isTv,
    this.episodeCount = 0,
    this.aliases = const [],
  });

  final String title;
  final int year;
  /// null 表示站源没有可信的电影/剧集类型提示。
  final bool? isTv;

  /// 来源剧集数（`vod_play_url` 里可播集数）；`0` 表示未知。
  final int episodeCount;

  /// 其它可尝试的标题（原名、去掉季号的名字等）。
  final List<String> aliases;

  /// 归一化后的查询标题列表（去空、去重、保持顺序）。
  List<String> get queries {
    final result = <String>[];
    final seen = <String>{};
    for (final raw in <String>[title, ...aliases]) {
      final text = cleanTitle(raw);
      if (text.isEmpty) continue;
      if (!seen.add(normalizeTitle(text))) continue;
      result.add(text);
    }
    return result;
  }

  /// 该查询的类型。
  TmdbMediaType? get mediaType => switch (isTv) {
    true => TmdbMediaType.tv,
    false => TmdbMediaType.movie,
    null => null,
  };

  String get key => '${mediaType?.name ?? 'unknown'}|$year|$episodeCount|${normalizeTitle(title)}|${aliases.map(normalizeTitle).join('|')}';
}

// ---------------------------------------------------------------------------
// §3 候选
// ---------------------------------------------------------------------------

/// 一个外部源候选作品（搜索结果条目或详情摘要）。
class MetaCandidate {
  const MetaCandidate({
    required this.identity,
    required this.title,
    this.originalTitle = '',
    this.year = 0,
    this.episodeCount = 0,
    this.rating = 0,
    this.posterUrl,
    this.overview,
    this.seasonLabel = '',
    this.facts,
    this.people,
  });

  final MetaIdentity identity;

  /// 主标题（豆瓣 `title` / Bangumi `name_cn`，缺失时回退原名）。
  final String title;

  /// 原名（豆瓣 `original_title` / Bangumi `name`）。
  final String originalTitle;

  /// 首播/上映年份；`0` 表示未知。
  final int year;

  /// 本季集数；`0` 表示未知。
  final int episodeCount;

  /// 评分（10 分制）；`0` 表示无评分。
  final double rating;

  final String? posterUrl;
  final String? overview;

  /// 季号标记（`第一季` / `S2`）；无季号时为空串。
  final String seasonLabel;

  /// 一行补充事实（豆瓣 `card_subtitle` 前两段：`中国大陆 · 剧情 家庭 犯罪`）。
  ///
  /// 为什么是一整行而不是拆成地区 / 类型两个字段：各家能给的切分粒度不同
  /// （TMDB 的流派是 id 不是名字，Bangumi 的标签在详情里），拆开就要为每个
  /// 来源各写一套映射；这里只承载「能不能认出这部片」的补充信息。
  final String? facts;

  /// 一行主创信息，**已带标签**（如 `主演：范伟 / 秦昊 · 导演：辛爽`）。
  ///
  /// 为什么由来源拼成整行：三家的落点完全不同——豆瓣在 `card_subtitle` 的一段里，
  /// Bangumi 在 `infobox` 的「主演/导演」键里，TMDB 只能靠详情 credits。
  /// 统一成一行文本，候选行就不必认识三个来源的字段形状。
  final String? people;

  /// 列表副标题：`2023 · 第一季 · 豆瓣`；缺项自动省略。
  String get subtitleForList => [
    if (year > 0) '$year',
    if (seasonLabel.isNotEmpty) seasonLabel,
    identity.kind.label,
  ].join(' · ');

  @override
  String toString() => 'MetaCandidate(${identity.key} $title $year)';
}

// ---------------------------------------------------------------------------
// §4 打分与取舍
// ---------------------------------------------------------------------------

/// 候选打分与取舍规则。
///
/// 打分复用 TMDB 匹配层的 [titleSimilarityScore]（归一后相等 1000、包含
/// 800–1000、其它按编辑距离衰减），再叠加年份信号；阈值口径见各常量。
abstract final class MetaMatchRules {
  /// 标题相似度下限：低于这个分数的候选一律不采纳。
  ///
  /// 820 对应「名字完全一致」或「长度相近的包含关系」——外部站对**真人剧**的
  /// 同名片（重制版、剧场版、续作）很多，放宽到这个分数以下就会把续作当正片。
  static const int acceptScore = 820;

  /// 年份不匹配的惩罚（相差 3 年以上）。
  static const int yearMismatchPenalty = 200;

  /// 年份完全一致 / 相差 1 年的加分。
  static const int yearExactBonus = 120;
  static const int yearNearBonus = 40;

  /// 冠军与亚军的**最小**分差；不足即判歧义，返回 `null`。
  ///
  /// 与 TMDB 匹配层「歧义即未匹配」同一取向：外部兜底宁可不显示，
  /// 也不能把「第一季」的数据铺到「第二季」的详情页上。
  static const int ambiguityGap = 60;

  /// 给单个候选打分（越大越像）。
  static int score(
    MetaCandidate candidate, {
    required List<String> queries,
    int year = 0,
  }) {
    var best = 0;
    for (final query in queries) {
      if (query.trim().isEmpty) continue;
      var value = titleSimilarityScore(candidate.title, query);
      if (candidate.originalTitle.isNotEmpty) {
        final alt = titleSimilarityScore(candidate.originalTitle, query);
        if (alt > value) value = alt;
      }
      if (value > best) best = value;
    }
    if (best == 0) return 0;

    // 年份：查得到且候选也查得到才比，两边有一边未知就不加分也不扣分
    // （未知不是「不匹配」，扣分会让老片/新片一律掉线）。
    if (year > 0 && candidate.year > 0) {
      final delta = (candidate.year - year).abs();
      if (delta == 0) {
        best += yearExactBonus;
      } else if (delta == 1) {
        best += yearNearBonus;
      } else if (delta >= 3) {
        best -= yearMismatchPenalty;
      }
    }
    return best;
  }

  /// 从候选里选一个；无可信候选时返回 `null`。
  ///
  /// 取舍顺序：总分降序 → 年份距离升序 → 保持原始顺序（外部站的相关度排序）。
  static MetaCandidate? choose(
    List<MetaCandidate> candidates, {
    required MetaQuery query,
  }) {
    if (candidates.isEmpty) return null;
    final queries = query.queries;
    if (queries.isEmpty) return null;

    final scored = <({MetaCandidate candidate, int score, int index})>[];
    final seen = <String>{};
    final season = sourceSeasonNumber(query.title);
    for (var index = 0; index < candidates.length; index++) {
      final candidate = candidates[index];
      // 类型不符的候选直接出局：电影不该顶替剧集，反之亦然。
      if (query.mediaType != null && candidate.identity.mediaType != query.mediaType) continue;
      if (!seen.add(candidate.identity.key)) continue;
      final candidateSeason = sourceSeasonNumber(candidate.title) > 0
          ? sourceSeasonNumber(candidate.title)
          : sourceSeasonNumber(candidate.originalTitle);
      if (season > 0 && candidateSeason > 0 && season != candidateSeason) continue;
      if (score(candidate, queries: queries) < acceptScore) continue;
      final value = score(candidate, queries: queries, year: query.year);
      if (value <= 0) continue;
      scored.add((candidate: candidate, score: value, index: index));
    }
    if (scored.isEmpty) return null;

    scored.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      if (byScore != 0) return byScore;
      final byYear = yearDistance(
        a.candidate.year,
        query.year,
      ).compareTo(yearDistance(b.candidate.year, query.year));
      if (byYear != 0) return byYear;
      return a.index.compareTo(b.index);
    });

    final top = scored.first;
    if (top.score < acceptScore) return null;
    if (scored.length > 1 && top.score - scored[1].score < ambiguityGap) {
      // 分差不足：两条都像，谁都可能是正片 → 不猜。
      return null;
    }
    return top.candidate;
  }
}
