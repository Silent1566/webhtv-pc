/// 详情页外部评分与外部链接（对齐安卓 `TmdbHeaderView` 的评分区 + 外链区）。
///
/// 这一层是**纯逻辑**：不依赖 Flutter，也不依赖 `dart:io`，不发起任何请求。
/// 服务层（`DetailRatingService`）只负责把网络结果填进 `DetailRatingValues`，
/// UI 只负责把 `DetailRatings` 渲染成可点击的 chip。
///
/// 关键契约：
/// - 条目顺序**固定**：TMDB → 豆瓣 → IMDb → 烂番茄 → Metacritic。顺序在纯逻辑层
///   决定，UI 不得重排（安卓两处实现顺序漂移过，同一页出现两种排序）。
/// - `url` 为空串表示该平台**没有可打开的地址**（例如未匹配时的 IMDb），此时
///   chip 不可点，但仍可显示分值。
/// - 分值一律是**文案**（`8.4` / `87%` / `78/100`）：OMDb 直接给字符串，豆瓣与
///   TMDB 给小数，两种口径在这里归一，UI 不做数字格式化。
/// - 取不到分值时 `valueLabel` 为空串，条目**不占位**（用户决策 2026-11-11：
///   「只显示已拿到的评分」）。
library;

import 'tmdb_identity.dart';
import 'tmdb_title.dart';

/// 各平台的**用户可见品牌名**。
///
/// 只在这里定义一次：TMDB / IMDb 的品牌写法有历史变体（`TMDb` / `Imdb`），
/// 散在四处拼接时迟早漂成两种。界面上一律取这里的常量。
abstract final class RatingBrand {
  static const String tmdb = 'TMDB';
  static const String imdb = 'IMDb';
  static const String douban = '豆瓣';
  static const String rottenTomatoes = '烂番茄';
  static const String metacritic = 'Metacritic';
}

/// 评分/外链来源。枚举顺序即展示顺序。
enum RatingSource {
  tmdb,
  douban,
  imdb,
  rottenTomatoes,
  metacritic;

  /// 站点名（chip 文案与测试定位共用）。
  String get label => switch (this) {
    RatingSource.tmdb => RatingBrand.tmdb,
    RatingSource.douban => RatingBrand.douban,
    RatingSource.imdb => RatingBrand.imdb,
    RatingSource.rottenTomatoes => RatingBrand.rottenTomatoes,
    RatingSource.metacritic => RatingBrand.metacritic,
  };

  /// 稳定的机器名（widget key 后缀、日志用）。
  String get key => switch (this) {
    RatingSource.tmdb => 'tmdb',
    RatingSource.douban => 'douban',
    RatingSource.imdb => 'imdb',
    RatingSource.rottenTomatoes => 'rotten',
    RatingSource.metacritic => 'metacritic',
  };

  /// 该来源的评分口径（决定 [formatRating] 的后缀）。
  RatingScale get scale => switch (this) {
    RatingSource.tmdb => RatingScale.tenthsOutOfTen,
    RatingSource.douban => RatingScale.tenths,
    RatingSource.imdb => RatingScale.tenths,
    RatingSource.rottenTomatoes => RatingScale.percent,
    RatingSource.metacritic => RatingScale.outOfHundred,
  };
}

/// 评分的数字口径。OMDb 的字符串不经过这里（它自带单位）。
enum RatingScale { tenths, tenthsOutOfTen, percent, outOfHundred }

/// 把 0~10 的小数格式化成该来源的文案；`value <= 0` 返回空串。
String formatRating(RatingSource source, double value) {
  if (!value.isFinite || value <= 0) return '';
  final text = value.toStringAsFixed(1);
  return switch (source.scale) {
    RatingScale.tenths => text,
    RatingScale.tenthsOutOfTen => '$text/10',
    RatingScale.percent => '${(value * 10).round()}%',
    RatingScale.outOfHundred => '${(value * 10).round()}/100',
  };
}

/// 一个评分/外链条目。
class DetailRatingEntry {
  const DetailRatingEntry({
    required this.source,
    this.url = '',
    this.valueLabel = '',
    this.detail = '',
  });

  final RatingSource source;

  /// 打开的地址；空串表示不可点。
  final String url;

  /// 分值文案（`8.4` / `87%`）；空串表示暂未取得。
  final String valueLabel;

  /// 附注（`1.2M 人评分`）；空串表示无。
  final String detail;

  bool get hasValue => valueLabel.isNotEmpty;
  bool get canOpen => url.isNotEmpty;

  /// chip 文案：`IMDb ★ 8.4`，无分值时只有站名。
  String get label => hasValue ? '${source.label} ★ $valueLabel' : source.label;

  /// 补上分值；传入空串时保留原值。
  DetailRatingEntry withValue(String valueLabel, {String detail = ''}) =>
      DetailRatingEntry(
        source: source,
        url: url,
        valueLabel: valueLabel.isEmpty ? this.valueLabel : valueLabel,
        detail: detail.isEmpty ? this.detail : detail,
      );

  @override
  String toString() =>
      'DetailRatingEntry(${source.key}, value=$valueLabel, url=$url)';
}

/// 服务层拿到的外部评分原始值。空串 = 该来源没拿到。
///
/// 刻意用扁平字段而不是 `Map<RatingSource, String>`：它只有一个生产者
/// （`DetailRatingService`）与一个消费者（[DetailRatingRules.withValues]），
/// 平坦结构让「哪几个来源可能出现」在类型上就固定下来。
class DetailRatingValues {
  const DetailRatingValues({
    this.doubanRating = 0,
    this.imdb = '',
    this.imdbVotes = '',
    this.rottenTomatoes = '',
    this.metacritic = '',
  });

  static const DetailRatingValues empty = DetailRatingValues();

  /// 豆瓣十分制评分；0 表示未取得。
  final double doubanRating;

  /// IMDb 分（`8.4`）与投票数（`1,234,567`）。
  final String imdb;
  final String imdbVotes;

  /// 烂番茄新鲜度（`87%`）。
  final String rottenTomatoes;

  /// Metacritic 分（`78/100`）。
  final String metacritic;

  bool get isEmpty =>
      doubanRating <= 0 &&
      imdb.isEmpty &&
      rottenTomatoes.isEmpty &&
      metacritic.isEmpty;

  /// 分来源补齐：同一字段已有值时保留旧值（先到的是优先来源）。
  DetailRatingValues merge(DetailRatingValues other) => DetailRatingValues(
    doubanRating: doubanRating > 0 ? doubanRating : other.doubanRating,
    imdb: imdb.isNotEmpty ? imdb : other.imdb,
    imdbVotes: imdbVotes.isNotEmpty ? imdbVotes : other.imdbVotes,
    rottenTomatoes: rottenTomatoes.isNotEmpty
        ? rottenTomatoes
        : other.rottenTomatoes,
    metacritic: metacritic.isNotEmpty ? metacritic : other.metacritic,
  );

  @override
  String toString() =>
      'DetailRatingValues(douban=$doubanRating imdb=$imdb '
      'rt=$rottenTomatoes mc=$metacritic)';
}

/// 评分区块的完整渲染数据。
class DetailRatings {
  const DetailRatings({
    this.entries = const [],
    this.loading = false,
    this.failed = false,
  });

  /// 顺序固定（[RatingSource] 的枚举顺序）。
  final List<DetailRatingEntry> entries;

  /// 外部评分仍在请求中（静态链接已可点）。
  final bool loading;

  /// 外部评分请求失败；链接仍然可用，因此区块照常显示。
  final bool failed;

  /// 真正要渲染的条目：**既没分值也没地址**的条目不出现。
  ///
  /// 这条规则来自安卓：外链区只在 `linkCount > 0` 时显示。没有 TMDB id、没有
  /// IMDb id、标题也拿不到时，五个站名全是死的，摆出来只会让人以为页面坏了。
  List<DetailRatingEntry> get visibleEntries => [
    for (final entry in entries)
      if (entry.canOpen || entry.hasValue) entry,
  ];

  DetailRatingEntry? entryOf(RatingSource source) {
    for (final entry in entries) {
      if (entry.source == source) return entry;
    }
    return null;
  }

  bool get isEmpty => visibleEntries.isEmpty;

  DetailRatings copyWith({
    List<DetailRatingEntry>? entries,
    bool? loading,
    bool? failed,
  }) => DetailRatings(
    entries: entries ?? this.entries,
    loading: loading ?? this.loading,
    failed: failed ?? this.failed,
  );
}

/// 一次评分查询的输入（不含凭据：OMDb key 由服务层自己取）。
class DetailRatingRequest {
  const DetailRatingRequest({
    this.tmdbId = 0,
    this.title = '',
    this.year = 0,
    this.mediaType = TmdbMediaType.movie,
    this.imdbId = '',
    this.originalTitle = '',
    this.englishTitle = '',
  });

  /// TMDB 作品 id（0 = 未匹配，TMDB 外链因此不可点）。
  final int tmdbId;
  final String title;
  final int year;
  final TmdbMediaType mediaType;
  final String imdbId;
  final String originalTitle;
  final String englishTitle;

  bool get isEmpty => title.trim().isEmpty && imdbId.trim().isEmpty;

  /// 缓存键：同一部作品的评分只应请求一次。
  String get cacheKey => [
    mediaType.name,
    tmdbId,
    imdbId.trim(),
    normalizeTitle(title),
    year,
  ].join('|');
}

/// 详情页评分与外链的构造规则（全部为纯函数）。
abstract final class DetailRatingRules {
  /// 静态外链（不含任何分值），顺序即展示顺序。
  ///
  /// 与安卓 `setupExternalLinks` / `bindExternalLinks` 一致：TMDB 有 id 才有
  /// 详情页；IMDb 只在拿到 `external_ids.imdb_id` 时才有直达页；豆瓣、烂番茄、
  /// Metacritic 没有稳定的 id，一律**按标题搜索**（PC 端不猜 id）。
  static List<DetailRatingEntry> links({
    required int tmdbId,
    required TmdbMediaType mediaType,
    required String imdbId,
    required String doubanTitle,
    required String westernQuery,
  }) {
    final imdb = imdbId.trim();
    final title = doubanTitle.trim();
    final query = westernQuery.trim();
    return [
      DetailRatingEntry(
        source: RatingSource.tmdb,
        url: tmdbId > 0 ? tmdbPageUrl(mediaType, tmdbId) : '',
      ),
      DetailRatingEntry(
        source: RatingSource.douban,
        url: title.isEmpty ? '' : doubanSearchUrl(title),
      ),
      DetailRatingEntry(
        source: RatingSource.imdb,
        url: imdb.isEmpty ? '' : imdbTitleUrl(imdb),
      ),
      DetailRatingEntry(
        source: RatingSource.rottenTomatoes,
        url: query.isEmpty ? '' : rottenTomatoesSearchUrl(query),
      ),
      DetailRatingEntry(
        source: RatingSource.metacritic,
        url: query.isEmpty ? '' : metacriticSearchUrl(query),
      ),
    ];
  }

  /// 从 TMDB 原始详情构造一次评分查询。
  ///
  /// [detail] 是 TMDB `/{movie,tv}/{id}` 的响应：英文译名（烂番茄检索键）、
  /// `external_ids.imdb_id`（OMDb 与 IMDb 直达页的键）与首播日期都在里面，
  /// 调用方不必自己再解析一遍。
  static DetailRatingRequest fromDetailMap(
    Map<String, Object?>? detail, {
    required int tmdbId,
    required String title,
    required TmdbMediaType mediaType,
    String fallbackTitle = '',
  }) {
    final isTv = mediaType == TmdbMediaType.tv;
    final date = detail == null
        ? ''
        : _firstNonEmpty([
            isTv ? detail['first_air_date'] : detail['release_date'],
            isTv ? detail['release_date'] : detail['first_air_date'],
          ]);
    final trimmed = title.trim();
    return DetailRatingRequest(
      tmdbId: tmdbId,
      title: trimmed.isEmpty ? fallbackTitle.trim() : trimmed,
      year: firstYear(date),
      mediaType: mediaType,
      imdbId: externalImdbId(detail),
      originalTitle: detail == null
          ? ''
          : _firstNonEmpty([detail['original_name'], detail['original_title']]),
      englishTitle: englishTranslationTitle(detail, mediaType),
    );
  }

  /// 组装整块渲染数据：静态外链 + 已拿到的分值。
  static DetailRatings build({
    required DetailRatingRequest request,
    DetailRatingValues values = DetailRatingValues.empty,
    bool loading = false,
    bool failed = false,
  }) {
    final links = DetailRatingRules.links(
      tmdbId: request.tmdbId,
      mediaType: request.mediaType,
      imdbId: request.imdbId,
      doubanTitle: request.title,
      westernQuery: westernSearchQuery(
        title: request.title,
        originalTitle: request.originalTitle,
        englishTitle: request.englishTitle,
        year: request.year,
      ),
    );
    return DetailRatings(
      entries: DetailRatingRules.withValues(links, values: values),
      loading: loading,
      failed: failed,
    );
  }

  /// 把分值填进静态条目。
  ///
  /// [values] 来自服务层。没拿到分值的条目保持空 `valueLabel`（UI 只渲染站名，
  /// 不画占位）。
  ///
  /// **TMDB 条目刻意不填分值**：hero 标签行就在本区块上方，那里已经显示了
  /// `TMDB 8.4`（`_MetaChips`）。同一屏里同一个数字出现两次不增加信息，只让人
  /// 怀疑两者是不是同一个数（安卓把评分区与外链区拆在两个位置，正因此两处都写过
  /// TMDB 分，用户看到的是同一行里两个「TMDB」）。这里它只承担「打开作品页」。
  static List<DetailRatingEntry> withValues(
    List<DetailRatingEntry> links, {
    required DetailRatingValues values,
  }) {
    return [
      for (final entry in links)
        switch (entry.source) {
          RatingSource.tmdb => entry,
          RatingSource.douban => entry.withValue(
            formatRating(RatingSource.douban, values.doubanRating),
          ),
          RatingSource.imdb => entry.withValue(
            values.imdb,
            detail: values.imdbVotes.isEmpty ? '' : '${values.imdbVotes} 人评分',
          ),
          RatingSource.rottenTomatoes => entry.withValue(values.rottenTomatoes),
          RatingSource.metacritic => entry.withValue(values.metacritic),
        },
    ];
  }
}

/// TMDB 作品页地址。
String tmdbPageUrl(TmdbMediaType mediaType, int tmdbId) =>
    'https://www.themoviedb.org/${mediaType.name}/$tmdbId';

/// 豆瓣按标题搜索（没有 subject id 时不猜 id）。
///
/// 空格编码成 `%20` 而不是 `+`：安卓用 `Uri.encode`（`%20`），两个站点对 `+`
/// 的还原口径不一致，与安卓逐字节对齐最省事。
String doubanSearchUrl(String title) =>
    'https://search.douban.com/movie/subject_search?search_text='
    '${Uri.encodeComponent(title.trim())}';

/// IMDb 标题页。
String imdbTitleUrl(String imdbId) =>
    'https://www.imdb.com/title/${imdbId.trim()}';

/// 烂番茄搜索页。
String rottenTomatoesSearchUrl(String query) =>
    'https://www.rottentomatoes.com/search?search='
    '${Uri.encodeComponent(query.trim())}';

/// Metacritic 搜索页（路径式搜索，与安卓一致）。
String metacriticSearchUrl(String query) =>
    'https://www.metacritic.com/search/${Uri.encodeComponent(query.trim())}/';

/// 是否含拉丁字母（判断标题能不能直接喂给英文站点）。
bool hasLatinLetter(String text) => RegExp(r'[A-Za-z]').hasMatch(text);

/// 烂番茄 / Metacritic 的搜索词。
///
/// 优先级与安卓 `preferredWesternSearchTitle` 一致：英文译名 → 原名（含拉丁
/// 字母时）→ 本地标题（含拉丁字母时）。年份在标题未自带时补上：这两个站点同名
/// 作品很多（重拍片），不带年份经常搜到错的那一部。
String westernSearchQuery({
  String title = '',
  String originalTitle = '',
  String englishTitle = '',
  int year = 0,
}) {
  String picked = '';
  for (final candidate in [englishTitle, originalTitle, title]) {
    final text = candidate.trim();
    if (text.isNotEmpty && hasLatinLetter(text)) {
      picked = text;
      break;
    }
  }
  if (picked.isEmpty) {
    for (final candidate in [originalTitle, title]) {
      final text = candidate.trim();
      if (text.isNotEmpty) {
        picked = text;
        break;
      }
    }
  }
  if (picked.isEmpty) return '';
  if (year <= 0 || picked.contains('$year')) return picked;
  return '$picked $year';
}

/// TMDB `translations` 里的英文标题（`en-US` 优先）。
///
/// 安卓 `englishTranslationTitle` 的等价物：烂番茄与 Metacritic 用中文标题
/// 搜不到任何东西，英文译名是那两个站点唯一可靠的检索键。
String englishTranslationTitle(
  Map<String, Object?>? detail,
  TmdbMediaType mediaType,
) {
  if (detail == null) return '';
  final translations = detail['translations'];
  if (translations is! Map) return '';
  final list = translations['translations'];
  if (list is! List) return '';
  final isTv = mediaType == TmdbMediaType.tv;
  String fallback = '';
  for (final value in list) {
    if (value is! Map) continue;
    if ('${value['iso_639_1'] ?? ''}'.toLowerCase() != 'en') continue;
    final data = value['data'];
    if (data is! Map) continue;
    final primary = data[isTv ? 'name' : 'title'];
    final secondary = data[isTv ? 'title' : 'name'];
    final raw = primary is String && primary.trim().isNotEmpty
        ? primary
        : secondary;
    final text = raw is String ? raw.trim() : '';
    if (text.isEmpty) continue;
    if ('${value['iso_3166_1'] ?? ''}'.toUpperCase() == 'US') return text;
    if (fallback.isEmpty) fallback = text;
  }
  return fallback;
}

/// 详情里的 IMDb id（`external_ids.imdb_id`）。
String externalImdbId(Map<String, Object?>? detail) {
  if (detail == null) return '';
  final ids = detail['external_ids'];
  if (ids is! Map) return '';
  final value = ids['imdb_id'];
  return value is String ? value.trim() : '';
}

/// 上映/首播年份。
int releaseYear(String date) => firstYear(date);

/// 取第一个非空字符串。
///
/// 与 `tmdb_detail_model.dart` 的同名工具同义，但那个文件依赖本层（详情模型要
/// 带评分字段），反向导入会形成环，因此这一层留一份等价实现。
String _firstNonEmpty(Iterable<Object?> values) {
  for (final value in values) {
    if (value is String && value.trim().isNotEmpty) return value.trim();
    if (value is num) return value.toString();
  }
  return '';
}

/// OMDb 返回体里的评分（对齐安卓 `TmdbHeaderView.buildRatingChips`）。
///
/// OMDb 是**字符串口径**的数据源：IMDb 是 `"8.4"`、烂番茄是 `"87%"`、
/// Metacritic 是 `"78/100"` 或只有裸 `Metascore` `"78"`。这里归一成
/// [DetailRatingValues]，UI 不再判断单位。
///
/// `N/A` 与 `Response=false` 一律当「没拿到」：OMDb 大量返回 `"N/A"`，直接显示
/// 会变成「烂番茄 ★ N/A」。
DetailRatingValues parseOmdbRatings(Map<String, Object?> json) {
  if (json.isEmpty) return DetailRatingValues.empty;
  if ('${json['Response'] ?? ''}'.trim().toLowerCase() == 'false') {
    return DetailRatingValues.empty;
  }
  String field(Object? value) {
    final text = switch (value) {
      String text => text.trim(),
      num number => number.toString(),
      _ => '',
    };
    return text.toLowerCase() == 'n/a' ? '' : text;
  }

  String ratingOf(String source) {
    final ratings = json['Ratings'];
    if (ratings is! List) return '';
    for (final value in ratings) {
      if (value is! Map) continue;
      final name = '${value['Source'] ?? ''}'.trim().toLowerCase();
      if (name != source.toLowerCase()) continue;
      return field(value['Value']);
    }
    return '';
  }

  final metascore = field(json['Metascore']);
  final metacritic = ratingOf('Metacritic');
  return DetailRatingValues(
    imdb: field(json['imdbRating']),
    imdbVotes: compactVoteCount(field(json['imdbVotes'])),
    rottenTomatoes: ratingOf('Rotten Tomatoes'),
    // `Ratings` 自带 `/100` 后缀；只有裸 `Metascore` 时补上同一口径。
    metacritic: metacritic.isNotEmpty
        ? metacritic
        : (metascore.isEmpty ? '' : '$metascore/100'),
  );
}

/// 把 `1,234,567` 压成 `1.2M`；无法解析时原样返回。
///
/// 安卓 `compactOmdbVoteCount` 的等价物：chip 宽度有限，七位数原样写进去会把
/// 整行评分挤成两行。
String compactVoteCount(String votes) {
  final text = votes.trim();
  if (text.isEmpty) return '';
  final value = double.tryParse(text.replaceAll(RegExp(r'[,\s]'), ''));
  if (value == null || !value.isFinite || value <= 0) return text;
  const units = <(double, String)>[(1e9, 'B'), (1e6, 'M'), (1e3, 'K')];
  for (final (size, suffix) in units) {
    if (value < size) continue;
    final scaled = value / size;
    final label = scaled >= 100
        ? scaled.toStringAsFixed(0)
        : scaled.toStringAsFixed(1);
    return '${label.endsWith('.0') ? label.substring(0, label.length - 2) : label}$suffix';
  }
  return text;
}
