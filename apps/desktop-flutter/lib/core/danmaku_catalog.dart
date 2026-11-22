/// 弹幕搜索结果的展示用纯逻辑（安卓 `bean/DanmakuTitle.java` 的 Dart 版）。
///
/// 为什么单独一层：中转返回的 name 是一整行
/// 「剧名(年份)【类型】from 来源 - 【来源N】 第N话 集名」，
/// 「按渠道筛选」「按剧名折叠」「集号倒序」都只能从字符串里推。
/// 抽成纯函数才能拿真实样例做确定性单测；UI（S2/S3）只负责摆。
library;

import 'danmaku_match.dart';

/// 「未分类」分组的标题：解析不出剧名的条目都归到这里。
const String kDanmakuUnclassifiedTitle = '未分类';

/// 渠道解析不出来时的兜底标签。
///
/// 不能直接拿 providerId 兜底：中转/通用契约没给来源时，适配层会填 'tvbox'
/// 这类占位值，它出现在渠道筛选里就是一个既不可读也不可点的假渠道。
const String kUnknownDanmakuChannel = '未知';

/// `from X` 形式的来源标记（对齐安卓 `SOURCE_INLINE`）。
final RegExp _channelFromPattern = RegExp(
  r'\bfrom\s+([^\s\-－—~～\[\]【】]+)',
  caseSensitive: false,
);

/// 【】/[] 包裹的来源或类型标记（对齐安卓 `SOURCE_MARK`）。
final RegExp _channelMarkPattern = RegExp(r'[【\[]([^】\]]{1,24})[】\]]');

/// 从弹幕名里认出渠道（bilibili / dandan / qq / tencent…）。
///
/// 优先 `from X`（中转下发的权威标记），否则取第一个【】/[] 里的内容
/// （'【qq】' → 'qq'）；都没有就用 [fallback]——调用方应传条目的 providerId，
/// 避免 UI 的渠道筛选里出现空分组。
String? danmakuChannelOf(String name, {String? fallback}) {
  final text = name.trim();
  if (text.isNotEmpty) {
    final from = _channelFromPattern.firstMatch(text);
    final raw =
        from?.group(1) ?? _channelMarkPattern.firstMatch(text)?.group(1);
    final channel = _normalizeChannel(raw);
    if (channel != null) return channel;
  }
  return _normalizeChannel(fallback);
}

/// 归一化渠道名：trim、小写、去掉尾部数字与分隔符。
///
/// 'bilibili1'（中转在渠道后面挂了序号）必须与 'bilibili' 归成同一个渠道，
/// 否则按渠道筛选会被这些序号切成一堆互不相认的分组。
String? _normalizeChannel(String? raw) {
  var value = raw?.trim().toLowerCase() ?? '';
  if (value.isEmpty) return null;
  value = value.replaceFirst(RegExp(r'[0-9]+$'), '');
  value = value.replaceFirst(RegExp(r'[\s\-－—~～_.,，。:：;；]+$'), '');
  return value.isEmpty ? null : value;
}

/// URL（安卓 `URL` 同款，`https?://\S+`）。
final RegExp _urlPattern = RegExp(r'https?://\S+', caseSensitive: false);

/// `from` 关键字（对齐安卓 `SOURCE_FROM`）。
final RegExp _fromPattern = RegExp(r'\bfrom\b', caseSensitive: false);

/// 剧名与集数/来源之间的分隔符（对齐安卓 `DASH`）。
final RegExp _dashPattern = RegExp(r'\s*[-－—~～]\s*');

/// 连续空白（对齐安卓 `BLANK`）。
final RegExp _blankPattern = RegExp(r'\s{2,}');

/// 剧名分组键：清洗来源/集数/类型/URL 标记后取剧名前缀；解析不出返回 null。
///
/// **年份括注必须保留**：`(2026)`/`(2023)` 是「同名不同剧」唯一的区分依据。
/// 一旦洗掉，2026 电视剧《一马当先》与 2023 短剧《一马当先》会被折叠进同一个组
/// （24 行混在一起，用户看到的就是「排序乱了」）；同一年的同一部剧即便来自多个
/// 弹幕源，仍然共用一个键、照旧合并。
///
/// 真实样例：
/// - '灵笼 第二季(2025)【动漫】from bilibili - 【bilibili1】 第1话 末世桃源'
///   → '灵笼 第二季(2025)'
/// - '灵笼:INCARNATION 终章(2021)【3D网络放送】from dandan - 【dandan】 第1话 上'
///   → '灵笼:INCARNATION 终章(2021)'
/// - '一马当先(2026)【电视剧】from tencent - 【qq】 一马当先 第1集'
///   → '一马当先(2026)'
///
/// 返回 null 表示「这条没有稳定剧名」，调用方归入 [kDanmakuUnclassifiedTitle]。
String? danmakuTitleKeyOf(String name) {
  var value = name.replaceAll(_urlPattern, ' ');
  final cut = _titleCutIndex(value);
  if (cut >= 0) value = value.substring(0, cut);
  // 只清【】/[] 里的类型与来源标记；年份括注是分组依据，不能动。
  value = value
      .replaceAll(_channelMarkPattern, ' ')
      .replaceAll(_blankPattern, ' ')
      .trim();
  return value.isEmpty ? null : value;
}

/// 剧名截断点：`from` 关键字与第一个 `-` 类分隔符取**更早**的那个。
///
/// 安卓 `findCut` 只要有 `from` 就按它的位置截，'A - B from c' 会留下 'A - B'；
/// 这里取更早者，因为「分隔符之后是集名/来源」这个约定对两者都成立，
/// 而留下半截分隔符会凭空多出一个分组键。
int _titleCutIndex(String text) {
  var cut = -1;
  final from = _fromPattern.firstMatch(text);
  if (from != null) cut = from.start;
  final dash = _dashPattern.firstMatch(text);
  if (dash != null && (cut < 0 || dash.start < cut)) cut = dash.start;
  return cut;
}

/// 集号：复用 [extractEpisodeNumber] 的语义（第N集/话、EP、S0xE0y）；抽不出 null。
int? danmakuEpisodeOf(String name) => extractEpisodeNumber(name);

/// 一个剧名分组。
class DanmakuGroup {
  const DanmakuGroup({
    required this.title,
    required this.entries,
    this.hasRating = false,
    this.bestScore = 0,
  });

  /// 剧名；解析不出剧名时是 [kDanmakuUnclassifiedTitle]。
  final String title;

  /// 组内已排序的条目。
  final List<DanmakuLibraryEntry> entries;

  /// 组内是否有评分信息（占位：UI 想给「推荐」角标时读它）。
  final bool hasRating;

  /// 组内最高分（组间排序依据；UI 可用来高亮）。
  final double bestScore;

  bool get isUnclassified => title == kDanmakuUnclassifiedTitle;

  @override
  String toString() =>
      'DanmakuGroup($title, ${entries.length} 条, '
      'best=${bestScore.toStringAsFixed(3)})';
}

/// 组内存在与查询集号相同的条目时给组相似度的加分。
///
/// 为什么是 0.05 这么小：集号一致性在 [danmakuEntrySimilarity] 里已经按 0.3 权重
/// 算过了，这里只是「这一组覆盖了当前集」的额外证据。加太多会让「集号对上但
/// 片名不像」的组反超真正的主组——那正是用户抱怨的「排序乱了」。
const double kDanmakuGroupEpisodeBonus = 0.05;

/// 把搜索结果按剧名折叠成组。
///
/// 组间（传了 [query] 时）：组相似度降序 → 组内条目数多者优先 → 剧名升序；
/// 「未分类」永远最后（它不是一个剧，只是解析失败的兜底桶，按分数排会插到
/// 真剧中间去）。组相似度 = 组内最高 [danmakuEntrySimilarity]，组内存在与
/// 查询集号相同的条目时再加 [kDanmakuGroupEpisodeBonus]。
///
/// 组内：集号**数值**升序（第10集排在第2集之后，不是按字符串比）；[reverse]
/// 为 true 时降序。同集号（同一集的多条弹幕源）按原输入顺序，排序不会让它们
/// 在两帧之间互换位置；解析不出集号的条目按原顺序排在末尾，倒序时也一样——
/// 它们没法参与「第几集」的比较。
///
/// 为什么同分要比条目数：两个组都「像」时，条目多的那组通常才是正主——
/// 库里给每一集都建一条记录，而撞名的另一部片往往只被零散收录几集；按条数
/// 优先能把「看起来更全」的组摆在用户第一屏。
///
/// 为什么不传 [query] 时保持旧规则：旧调用方（UI 折叠前的预览、测试）拿到的
/// 顺序不能因为这次改动而抖动，且它们手上本来就没有查询上下文。
List<DanmakuGroup> groupDanmakuEntries({
  required Iterable<DanmakuLibraryEntry> entries,
  bool reverse = false,
  DanmakuQuery? query,
}) {
  // Dart 的 Map 保持插入顺序，组内「按原顺序」直接依赖这一点。
  final buckets = <String, List<({int index, DanmakuLibraryEntry entry})>>{};
  var index = 0;
  for (final entry in entries) {
    final key = danmakuTitleKeyOf(entry.title) ?? kDanmakuUnclassifiedTitle;
    buckets
        .putIfAbsent(key, () => <({int index, DanmakuLibraryEntry entry})>[])
        .add((index: index++, entry: entry));
  }

  final groups = <DanmakuGroup>[];
  for (final bucket in buckets.entries) {
    var best = 0.0;
    for (final item in bucket.value) {
      if (item.entry.score > best) best = item.entry.score;
    }
    groups.add(
      DanmakuGroup(
        title: bucket.key,
        entries: _sortGroupEntries(bucket.value, reverse: reverse),
        hasRating: best > 0,
        bestScore: best,
      ),
    );
  }

  if (query == null) {
    // 旧行为逐字保留：最高分降序 → 剧名升序。
    groups.sort(_legacyGroupOrder);
    return groups;
  }
  final queryEpisode = extractEpisodeNumber(query.episode);
  // 相似度算在排序外：comparator 里现算会把同一组的打分重复 O(n log n) 次。
  final ranked = [
    for (final group in groups)
      (group: group, similarity: _groupSimilarity(group, query, queryEpisode)),
  ];
  ranked.sort((a, b) {
    final byUnclassified = _unclassifiedOrder(a.group, b.group);
    if (byUnclassified != 0) return byUnclassified;
    final bySimilarity = b.similarity.compareTo(a.similarity);
    if (bySimilarity != 0) return bySimilarity;
    final byCount = b.group.entries.length.compareTo(a.group.entries.length);
    if (byCount != 0) return byCount;
    return a.group.title.compareTo(b.group.title);
  });
  return [for (final item in ranked) item.group];
}

int _unclassifiedOrder(DanmakuGroup a, DanmakuGroup b) =>
    (a.isUnclassified ? 1 : 0).compareTo(b.isUnclassified ? 1 : 0);

int _legacyGroupOrder(DanmakuGroup a, DanmakuGroup b) {
  final byUnclassified = _unclassifiedOrder(a, b);
  if (byUnclassified != 0) return byUnclassified;
  final byScore = b.bestScore.compareTo(a.bestScore);
  if (byScore != 0) return byScore;
  return a.title.compareTo(b.title);
}

/// 组相似度：组内最高条目相似度 + 覆盖本集时的加分。
double _groupSimilarity(
  DanmakuGroup group,
  DanmakuQuery query,
  int? queryEpisode,
) {
  var best = 0.0;
  var coversEpisode = false;
  for (final entry in group.entries) {
    final similarity = danmakuEntrySimilarity(entry: entry, query: query);
    if (similarity > best) best = similarity;
    if (coversEpisode || queryEpisode == null) continue;
    final episode = entry.episodeNumber ?? danmakuEpisodeOf(
      entry.episode.trim().isNotEmpty ? entry.episode : entry.title,
    );
    coversEpisode = episode == queryEpisode;
  }
  return coversEpisode ? best + kDanmakuGroupEpisodeBonus : best;
}

List<DanmakuLibraryEntry> _sortGroupEntries(
  List<({int index, DanmakuLibraryEntry entry})> items, {
  required bool reverse,
}) {
  final ranked = <({int index, int episode, DanmakuLibraryEntry entry})>[];
  final unknown = <({int index, DanmakuLibraryEntry entry})>[];
  for (final item in items) {
    // 集号优先读协议转换时算好的 [DanmakuLibraryEntry.episodeNumber]：
    // 那是一次解析、可单测的数值；只有旧构造点没填时才回退到现场解析。
    // 现场解析失败会让整组退化成「上游原始顺序」，看起来就像按字符串排序。
    final text = item.entry.episode.trim().isNotEmpty
        ? item.entry.episode
        : item.entry.title;
    final episode = item.entry.episodeNumber ?? danmakuEpisodeOf(text);
    if (episode == null) {
      unknown.add(item);
      continue;
    }
    ranked.add((index: item.index, episode: episode, entry: item.entry));
  }
  ranked.sort((a, b) {
    final byEpisode = reverse
        ? b.episode.compareTo(a.episode)
        : a.episode.compareTo(b.episode);
    // 同集号按原输入顺序（同一集的多条弹幕源）：排序不能让它们在两帧之间互换位置。
    return byEpisode != 0 ? byEpisode : a.index.compareTo(b.index);
  });
  return [
    for (final item in ranked) item.entry,
    for (final item in unknown) item.entry,
  ];
}
