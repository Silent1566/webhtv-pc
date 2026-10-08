/// TMDB 详情页展示模型（`docs/phase4/design/04` §3、§6）。
///
/// 这一层是**纯逻辑**：不依赖 Flutter，也不依赖 `dart:io`，因此可在
/// `flutter test` 里无副作用地断言。UI 只负责把这里的模型渲染出来。
///
/// 解决的三个真实缺陷（2026-10-07 用户反馈）：
/// 1. **每集没有对应的海报卡片**——来源剧集只有文字按钮，没有剧照卡片；
/// 2. **没有海报、导演等其他信息**——详情页头部只有标题/年份/演员；
/// 3. **剧照 / 演职人员 / 相关推荐点击无效**——纯展示，无点击行为。
///
/// 关键契约：
/// - 元数据 ≠ 播放事实源：本层只描述**展示**，不创建播放项（`00` §3）；
/// - 未分类的集必须保留（不得丢集，`02` §4.1）；
/// - 图片缺失时返回 `null`/空串，由 UI 决定占位，不得伪造地址。
library;

import 'tmdb_identity.dart';
import 'tmdb_media.dart';
import 'tmdb_title.dart';

/// 从任意 TMDB 响应取整数。
int tmdbInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? 0;
  return 0;
}

/// 从任意 TMDB 响应取小数。
double tmdbDouble(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? 0;
  return 0;
}

/// 从任意 TMDB 响应取字符串（`null` 安全）。
String? tmdbString(Object? value) {
  if (value == null) return null;
  if (value is String) return value;
  return value.toString();
}

/// 取第一个非空字符串。
String tmdbFirstNonEmpty(Iterable<Object?> values) {
  for (final value in values) {
    final text = tmdbString(value)?.trim() ?? '';
    if (text.isNotEmpty) return text;
  }
  return '';
}

// ---------------------------------------------------------------------------
// 背景图轮播（`04` §3.1 的动态背景）
// ---------------------------------------------------------------------------

/// 背景图轮播策略（纯逻辑，便于单测锁定节奏与边界）。
///
/// 上游 `TmdbHeaderView.setupBackdropSlideshow` 用 `Handler.postDelayed(..., 5000)`
/// 轮播背景图；PC 端用同一节奏（5 秒），并用「先取下一张、取不到就跳过」的
/// 策略保证**只有一张图时不启动轮播**（避免无意义的重绘与闪烁）。
abstract final class TmdbBackdropRotation {
  /// 单张停留时长（对齐上游 5000ms）。
  static const Duration interval = Duration(seconds: 5);

  /// 图片数 ≤ 1 时不轮播。
  static bool shouldRotate(int count) => count > 1;

  /// 下一张下标（环形）。`count <= 0` 返回 `-1`。
  static int next(int current, int count) {
    if (count <= 0) return -1;
    if (count == 1) return 0;
    final index = current % count;
    return (index + 1) % count;
  }

  /// 把任意下标夹到合法范围（`count <= 0` 返回 `-1`）。
  static int clamp(int index, int count) {
    if (count <= 0) return -1;
    if (index < 0) return 0;
    return index % count;
  }
}

// ---------------------------------------------------------------------------
// 详情模型
// ---------------------------------------------------------------------------

/// 一个季度的展示信息（含季海报）。
class TmdbSeasonInfo {
  const TmdbSeasonInfo({
    required this.number,
    required this.episodeCount,
    this.name = '',
    this.airDate = '',
    this.overview,
    this.posterUrl,
  });

  final int number;
  final int episodeCount;
  final String name;
  final String airDate;
  final String? overview;
  final String? posterUrl;

  bool get isSpecial => number == 0;

  /// 卡片标题：`特别篇` / `第 N 季`。
  String get label => isSpecial ? '特别篇' : '第 $number 季';

  /// 副标题：`12 集 · 2024`。
  String get subtitle {
    final year = firstYear(airDate);
    final parts = <String>[
      '$episodeCount 集',
      if (year > 0) '$year',
    ];
    return parts.join(' · ');
  }

  static TmdbSeasonInfo? fromJson(
    Object? value, {
    String Function(String base, String? path)? image,
    String imageBase = '',
  }) {
    if (value is! Map) return null;
    final map = value.cast<Object?, Object?>();
    final number = map.containsKey('season_number')
        ? tmdbInt(map['season_number'])
        : null;
    if (number == null) return null;
    return TmdbSeasonInfo(
      number: number,
      episodeCount: tmdbInt(map['episode_count']),
      name: tmdbFirstNonEmpty([map['name']]),
      airDate: tmdbFirstNonEmpty([map['air_date']]),
      overview: tmdbString(map['overview']),
      posterUrl: image?.call(imageBase, tmdbString(map['poster_path'])),
    );
  }
}

/// 详情页用到的全部 TMDB 展示数据。
///
/// 一次性从 `detail` 响应 + 图片基址构造，UI 只读不解析。
class TmdbDetailData {
  const TmdbDetailData({
    this.tmdbId = 0,
    this.mediaType = TmdbMediaType.tv,
    this.title = '',
    this.originalTitle = '',
    this.overview,
    this.tagline = '',
    this.posterUrl,
    this.backdropUrls = const [],
    this.posterUrls = const [],
    this.photoUrls = const [],
    this.stillUrls = const [],
    this.seasons = const [],
    this.cast = const [],
    this.creators = const [],
    this.crew = const [],
    this.directors = const [],
    this.writers = const [],
    this.genres = const [],
    this.countries = const [],
    this.languages = const [],
    this.rating = 0,
    this.voteCount = 0,
    this.releaseDate = '',
    this.runtime = 0,
    this.seasonCount = 0,
    this.episodeCount = 0,
    this.status = '',
    this.homepage = '',
  });

  final int tmdbId;
  final TmdbMediaType mediaType;
  final String title;
  final String originalTitle;
  final String? overview;
  final String tagline;
  final String? posterUrl;

  /// 背景图（横版，按清晰度排序）；动态背景按顺序轮播。
  final List<String> backdropUrls;

  /// 海报（竖版，按清晰度排序）。
  final List<String> posterUrls;

  /// 剧照墙（`images.stills`，缺失时回退背景图）。
  final List<String> photoUrls;

  /// 剧集剧照（`images.stills`，仅剧照，不回退背景图）。
  final List<String> stillUrls;

  /// 全部季度（含特别篇），按季号升序。
  final List<TmdbSeasonInfo> seasons;

  final List<TmdbPerson> cast;
  final List<TmdbPerson> creators;

  /// 剧组（`credits.crew`，含导演/编剧/制片）。
  final List<TmdbPerson> crew;

  /// 导演名（`crew.job == Director` 优先，缺失时回退 `created_by`）。
  final List<String> directors;

  /// 编剧名（`crew.department == Writing`）。
  final List<String> writers;

  final List<String> genres;
  final List<String> countries;
  final List<String> languages;
  final double rating;
  final int voteCount;
  final String releaseDate;
  final int runtime;
  final int seasonCount;
  final int episodeCount;
  final String status;
  final String homepage;

  bool get isTv => mediaType == TmdbMediaType.tv;

  /// 年份（`2024`），无日期时为空串。
  String get yearLabel {
    final year = firstYear(releaseDate);
    return year > 0 ? '$year' : '';
  }

  /// 评分文案（`TMDB 8.2`）；无评分时为空串。
  String get ratingLabel =>
      rating > 0 ? 'TMDB ${rating.toStringAsFixed(1)}' : '';

  /// 时长文案（`45 分钟` / `1 小时 52 分钟`）；为 0 时为空串。
  String get runtimeLabel {
    if (runtime <= 0) return '';
    if (runtime < 60) return '$runtime 分钟';
    final hours = runtime ~/ 60;
    final minutes = runtime % 60;
    return minutes == 0 ? '$hours 小时' : '$hours 小时 $minutes 分钟';
  }

  /// 季度/集数文案（`3 季 · 25 集` / `25 集`）。
  String get seasonEpisodeLabel {
    final parts = <String>[
      if (isTv && seasonCount > 0) '$seasonCount 季',
      if (episodeCount > 0) '$episodeCount 集',
    ];
    return parts.join(' · ');
  }

  /// 导演文案（`张三 / 李四`）；缺失时为空串。
  String get directorLabel => directors.join(' / ');

  /// 全部演职人员（主创在前，用于「演职人员」区块与计数）。
  List<TmdbPerson> get allPeople => [...creators, ...cast];

  /// 动态背景是否应轮播。
  bool get shouldRotateBackdrop =>
      TmdbBackdropRotation.shouldRotate(backdropUrls.length);

  /// 首张背景图（无背景图时回退海报）。
  String? get heroBackdrop {
    if (backdropUrls.isNotEmpty) return backdropUrls.first;
    if (posterUrl != null && posterUrl!.isNotEmpty) return posterUrl;
    return null;
  }

  /// 取某个季度的信息；未找到返回 `null`。
  TmdbSeasonInfo? seasonOf(int number) {
    for (final season in seasons) {
      if (season.number == number) return season;
    }
    return null;
  }

  /// 从 TMDB 详情响应构造（`03` §4.2、§4.4）。
  ///
  /// 图片选择复用 [TmdbImageSelector] 的排序与去重规则：
  /// - 背景图优先 `images.backdrops`（`sourceRank = 0`），再回退根级 `backdrop_path`；
  /// - 剧照只取 `images.stills`（**不回退背景图**），因为「剧照」与「背景图」是
  ///   两个语义不同的区块，用背景图冒充剧照会误导用户。
  static TmdbDetailData fromDetail(
    Map<String, Object?> detail, {
    required String imageBase,
    required String backdropBase,
    TmdbItem? item,
    int runtimeFallback = 0,
  }) {
    final mediaType =
        TmdbMediaType.parse(detail['media_type']) ??
        item?.mediaType ??
        TmdbMediaType.tv;
    final isTv = mediaType == TmdbMediaType.tv;
    final title = tmdbFirstNonEmpty([
      isTv ? detail['name'] : detail['title'],
      isTv ? detail['title'] : detail['name'],
      item?.title,
    ]);
    final originalTitle = tmdbFirstNonEmpty([
      detail['original_name'],
      detail['original_title'],
    ]);
    final date = tmdbFirstNonEmpty([
      isTv ? detail['first_air_date'] : detail['release_date'],
      isTv ? detail['release_date'] : detail['first_air_date'],
    ]);
    final rating = tmdbDouble(detail['vote_average']);
    final seasons = _seasonsOf(detail, imageBase);
    final crew = _crewOf(detail, imageBase);
    final crewRaw = _crewRawOf(detail);
    final creators = _peopleOf(detail['created_by'], imageBase);
    final backdropUrls = _backdropUrls(detail, backdropBase, imageBase, item);
    final posterUrls = TmdbImageSelector.posters(detail, imageBase, limit: 12);
    // 剧照只取 `images.stills`：它是「本剧/本集的画面」，与作为页面背景的
    // `backdrops` 语义不同；用背景图冒充剧照会与动态背景重复。
    final stillUrls = TmdbImageSelector.urls(
      TmdbImageSelector.candidates(
        detail,
        kind: 'stills',
        base: imageBase,
        orientation: TmdbImageOrientation.landscape,
      ),
      24,
    );

    return TmdbDetailData(
      tmdbId: tmdbInt(detail['id']) == 0 ? (item?.tmdbId ?? 0) : tmdbInt(detail['id']),
      mediaType: mediaType,
      title: title,
      originalTitle: originalTitle == title ? '' : originalTitle,
      overview: tmdbString(detail['overview']) ?? item?.overview,
      tagline: tmdbFirstNonEmpty([detail['tagline']]),
      posterUrl: _firstOrNull(posterUrls) ?? item?.posterUrl,
      backdropUrls: backdropUrls,
      posterUrls: posterUrls,
      // 剧照墙：优先真实剧照；一部剧完全没有剧照时回退背景图，
      // 保证区块有内容（否则整块隐藏，用户看不到任何画面）。
      photoUrls: stillUrls.isNotEmpty ? stillUrls : backdropUrls,
      stillUrls: stillUrls,
      seasons: seasons,
      cast: _castOf(detail, imageBase),
      creators: creators,
      crew: crew,
      directors: _directorNames(crewRaw, creators),
      writers: _crewNamesByJobs(crewRaw, _writingJobs),
      genres: _namesOf(detail['genres']),
      countries: _productionCountries(detail),
      languages: _spokenLanguages(detail),
      rating: rating > 0 ? rating : (item?.tmdbRating ?? 0),
      voteCount: tmdbInt(detail['vote_count']),
      releaseDate: date,
      runtime: _runtimeOf(detail, isTv, runtimeFallback: runtimeFallback),
      seasonCount: tmdbInt(detail['number_of_seasons']) == 0
          ? seasons.where((season) => season.number > 0).length
          : tmdbInt(detail['number_of_seasons']),
      episodeCount: tmdbInt(detail['number_of_episodes']) == 0
          ? seasons.fold<int>(0, (sum, season) => sum + season.episodeCount)
          : tmdbInt(detail['number_of_episodes']),
      status: tmdbFirstNonEmpty([detail['status']]),
      homepage: tmdbFirstNonEmpty([detail['homepage']]),
    );
  }

  /// 元数据季度（无响应时退化为 `item` 快照）。
  static TmdbDetailData fromItem(TmdbItem item) =>
      TmdbDetailData(
        tmdbId: item.tmdbId,
        mediaType: item.mediaType,
        title: item.title,
        overview: item.overview,
        posterUrl: item.posterUrl,
        backdropUrls: [
          if ((item.backdropUrl ?? '').isNotEmpty) item.backdropUrl!,
        ],
        posterUrls: [
          if ((item.posterUrl ?? '').isNotEmpty) item.posterUrl!,
        ],
        rating: item.tmdbRating,
      );
}

String? _firstOrNull(List<String> values) =>
    values.isEmpty ? null : values.first;

List<String> _backdropUrls(
  Map<String, Object?> detail,
  String backdropBase,
  String imageBase,
  TmdbItem? item,
) {
  final urls = TmdbImageSelector.backdrops(detail, backdropBase, limit: 12);
  if (urls.isNotEmpty) return urls;
  final fallback = item?.backdropUrl;
  if (fallback != null && fallback.isNotEmpty) return [fallback];
  // 无背景图时退化为海报，使动态背景至少有图（不得留白）。
  return TmdbImageSelector.posters(detail, imageBase, limit: 1);
}

List<TmdbSeasonInfo> _seasonsOf(
  Map<String, Object?> detail,
  String imageBase,
) {
  final raw = detail['seasons'];
  if (raw is! List) return const [];
  final seasons = <TmdbSeasonInfo>[];
  for (final value in raw) {
    final season = TmdbSeasonInfo.fromJson(
      value,
      image: (base, path) => TmdbImageSelector.image(base, path),
      imageBase: imageBase,
    );
    if (season != null) seasons.add(season);
  }
  seasons.sort((a, b) => a.number.compareTo(b.number));
  return seasons;
}

List<TmdbPerson> _castOf(
  Map<String, Object?> detail,
  String imageBase,
) {
  final aggregate = _mapOf(detail['aggregate_credits']);
  final credits = _mapOf(detail['credits']);
  final raw = _listOf(aggregate?['cast'] ?? credits?['cast']);
  return TmdbPerson.listFrom(
    raw,
    image: (base, path) => TmdbImageSelector.image(base, path),
    imageBase: imageBase,
  );
}

List<TmdbPerson> _crewOf(
  Map<String, Object?> detail,
  String imageBase,
) {
  final credits = _mapOf(detail['credits']);
  return TmdbPerson.listFrom(
    _listOf(credits?['crew']),
    image: (base, path) => TmdbImageSelector.image(base, path),
    imageBase: imageBase,
  );
}

/// `credits.crew` 的**原始条目**。
///
/// 为什么不用 `TmdbPerson`：`TmdbPerson` 只保留一个 `subtitle`（character/job 合并），
/// 无法区分「导演」与「编剧」。而这两个字段直接展示在详情页头部（用户反馈 2），
/// 必须精确，不能靠猜。
List<Map<Object?, Object?>> _crewRawOf(Map<String, Object?> detail) {
  final credits = _mapOf(detail['credits']);
  final raw = _listOf(credits?['crew']);
  return [
    for (final item in raw)
      if (item is Map) item.cast<Object?, Object?>(),
  ];
}

/// 导演职务（`job`）。
const Set<String> _directorJobs = {'Director'};

/// 编剧职务（`job` 或 `department` 任一命中即算）。
const Set<String> _writingJobs = {
  'Writer',
  'Screenplay',
  'Story',
  'Teleplay',
  'Author',
  'Novel',
  'Characters',
};

/// 按 `job` / `department` 取剧组姓名（去重，保持原顺序）。
List<String> _crewNamesByJobs(
  List<Map<Object?, Object?>> crew,
  Set<String> jobs,
) {
  final names = <String>[];
  for (final person in crew) {
    final job = tmdbFirstNonEmpty([person['job']]);
    final department = tmdbFirstNonEmpty([person['department']]);
    if (!jobs.contains(job) && !jobs.contains(department)) continue;
    final name = tmdbFirstNonEmpty([person['name']]);
    if (name.isEmpty || names.contains(name)) continue;
    names.add(name);
  }
  return names;
}

/// 导演名：先 `credits.crew` 的 `Director`，再回退 `created_by`（剧集主创）。
List<String> _directorNames(
  List<Map<Object?, Object?>> crew,
  List<TmdbPerson> creators,
) {
  final names = _crewNamesByJobs(crew, _directorJobs);
  if (names.isNotEmpty) return names;
  for (final person in creators) {
    if (person.name.isEmpty) continue;
    if (!names.contains(person.name)) names.add(person.name);
  }
  return names;
}

List<TmdbPerson> _peopleOf(Object? value, String imageBase) =>
    TmdbPerson.listFrom(
      _listOf(value),
      image: (base, path) => TmdbImageSelector.image(base, path),
      imageBase: imageBase,
    );

List<String> _namesOf(Object? value) {
  if (value is! List) return const [];
  final names = <String>[];
  for (final raw in value) {
    if (raw is! Map) continue;
    final name = tmdbFirstNonEmpty([raw['name']]);
    if (name.isNotEmpty) names.add(name);
  }
  return names;
}

List<String> _productionCountries(Map<String, Object?> detail) {
  final countries = detail['production_countries'];
  if (countries is List) {
    final names = _namesOf(countries);
    if (names.isNotEmpty) return names;
  }
  final origin = detail['origin_country'];
  if (origin is List) {
    return origin
        .map((value) => tmdbString(value)?.trim() ?? '')
        .where((value) => value.isNotEmpty)
        .toList();
  }
  return const [];
}

List<String> _spokenLanguages(Map<String, Object?> detail) {
  final languages = detail['spoken_languages'];
  if (languages is List) {
    final names = _namesOf(languages);
    if (names.isNotEmpty) return names;
  }
  final original = tmdbFirstNonEmpty([detail['original_language']]);
  return original.isEmpty ? const [] : [original];
}

/// 时长：电影取 `runtime`；剧集取 `episode_run_time[0]`。
///
/// 两者都为空时回退 [runtimeFallback]（通常是已加载剧集的平均时长）。
/// 为什么需要：TMDB 的剧集详情在**未播出/新剧**上 `episode_run_time` 经常为空，
/// 而分季剧集接口的每集 `runtime` 是有的。不回退就会让「时长」这项信息永远
/// 显示不出来（用户反馈的「没有其他信息」）。
int _runtimeOf(
  Map<String, Object?> detail,
  bool isTv, {
  int runtimeFallback = 0,
}) {
  final direct = tmdbInt(detail['runtime']);
  if (direct > 0) return direct;
  final list = detail['episode_run_time'];
  if (list is List && list.isNotEmpty) {
    final first = tmdbInt(list.first);
    if (first > 0) return first;
  }
  return runtimeFallback > 0 ? runtimeFallback : 0;
}

/// 从已加载的 TMDB 剧集列表取代表性单集时长（众数，平局取较短者）。
///
/// 用众数而不是平均：剧集里偶尔会有「特别长集」（首播集 70 分钟），
/// 平均值会把常规集时长抬得不准。
int tmdbTypicalRuntime(List<TmdbEpisode> episodes) {
  final counts = <int, int>{};
  for (final episode in episodes) {
    if (episode.runtime <= 0) continue;
    counts[episode.runtime] = (counts[episode.runtime] ?? 0) + 1;
  }
  if (counts.isEmpty) return 0;
  final entries = counts.entries.toList()
    ..sort((a, b) {
      final byCount = b.value.compareTo(a.value);
      return byCount != 0 ? byCount : a.key.compareTo(b.key);
    });
  return entries.first.key;
}

// ---------------------------------------------------------------------------
// 剧集卡片（每集的海报卡片，`04` §4.2）
// ---------------------------------------------------------------------------

/// 一张剧集卡片（**展示用**，不携带播放决策）。
class TmdbEpisodeCard {
  const TmdbEpisodeCard({
    required this.number,
    required this.title,
    this.date = '',
    this.overview,
    this.stillUrl,
    this.runtime = 0,
    this.rating = 0,
    this.seasonNumber = 0,
  });

  /// 季内集号（无法确定时为线路下标 + 1）。
  final int number;
  final String title;
  final String date;
  final String? overview;
  final String? stillUrl;
  final int runtime;
  final double rating;
  final int seasonNumber;

  bool get hasStill => (stillUrl ?? '').isNotEmpty;

  /// 副标题：`S1E3 · 2024-03-01`。
  String get subtitle {
    final year = firstYear(date);
    final parts = <String>[
      if (seasonNumber > 0) 'S${seasonNumber}E$number' else 'E$number',
      if (year > 0 && date.isNotEmpty) date,
    ];
    return parts.join(' · ');
  }

  static TmdbEpisodeCard fromEpisode(TmdbEpisode episode) => TmdbEpisodeCard(
    number: episode.number,
    title: episode.displayTitle,
    date: episode.date,
    overview: episode.overview,
    stillUrl: episode.stillUrl,
    runtime: episode.runtime,
    rating: episode.voteAverage,
    seasonNumber: episode.seasonNumber,
  );
}

/// 剧集卡片解析：把**线路剧集**与 TMDB 元数据对齐（`02` §9.3、`04` §4.2）。
///
/// 严格「不补集、不丢集」：输出数量**必须**等于输入线路剧集数。
abstract final class TmdbEpisodeCards {
  /// 把线路剧集映射为卡片列表。
  ///
  /// - `metadataByNumber`：TMDB 集号 → 集元数据（当前季度的 `episodes[]`）；
  /// - `usePosition`：集号不可靠时按**原始顺序**对齐（`02` §9.3）；
  /// - 未匹配到元数据的集仍产出卡片（只有来源集名，不丢集）。
  static List<TmdbEpisodeCard> build({
    required List<String> sourceNames,
    required Map<int, TmdbEpisode> metadataByNumber,
    bool usePosition = false,
    int seasonNumber = 0,
    List<String> fallbackStills = const [],
  }) {
    final cards = <TmdbEpisodeCard>[];
    for (var index = 0; index < sourceNames.length; index++) {
      final name = sourceNames[index];
      final number = usePosition
          ? index + 1
          : _numberOrFallback(name, index);
      final metadata = metadataByNumber[number];
      // 元数据缺失剧照时才按顺序回退；回退只影响**图片**，
      // 不影响集号与标题（标题仍用来源集名，不猜测）。
      final still = metadata?.stillUrl ??
          (index < fallbackStills.length ? fallbackStills[index] : null);
      cards.add(
        TmdbEpisodeCard(
          number: number,
          title: metadata?.displayTitle ?? name,
          date: metadata?.date ?? '',
          overview: metadata?.overview,
          stillUrl: still,
          runtime: metadata?.runtime ?? 0,
          rating: metadata?.voteAverage ?? 0,
          seasonNumber: metadata?.seasonNumber ?? seasonNumber,
        ),
      );
    }
    return cards;
  }

  /// 季集数快照校验（`02` §9.2）：输出必须等于线路集数。
  static bool matchesSourceCount({
    required List<TmdbEpisodeCard> cards,
    required int sourceEpisodeCount,
  }) => cards.length == sourceEpisodeCount;

  /// 纯 TMDB 详情页用：直接把 TMDB 剧集列表转为卡片（**不涉及线路**）。
  static List<TmdbEpisodeCard> fromMetadata(List<TmdbEpisode> episodes) =>
      episodes.map(TmdbEpisodeCard.fromEpisode).toList();

  static int _numberOrFallback(String name, int index) {
    final number = sourceEpisodeNumber(name);
    return number > 0 ? number : index + 1;
  }
}

// ---------------------------------------------------------------------------
// 图片查看器（剧照 / 海报点击，`04` §3.1 ⑥）
// ---------------------------------------------------------------------------

/// 图片查看器的选中与翻页（纯逻辑）。
///
/// 用户点击第 N 张剧照时，查看器必须**定位到第 N 张**（而不是永远第一张），
/// 并支持左右翻页与首尾环绕。上游对应 `PhotoViewerDialog.show(this, photos, selected, null)`。
class TmdbPhotoViewer {
  const TmdbPhotoViewer({
    required this.urls,
    this.selectedIndex = 0,
    this.title = '',
  });

  final List<String> urls;
  final int selectedIndex;
  final String title;

  bool get isEmpty => urls.isEmpty;

  int get count => urls.length;

  /// 合法化后的选中下标。
  int get index => TmdbBackdropRotation.clamp(selectedIndex, urls.length);

  String? get currentUrl => isEmpty ? null : urls[index];

  bool get hasPrevious => count > 1;

  bool get hasNext => count > 1;

  TmdbPhotoViewer goTo(int index) => TmdbPhotoViewer(
    urls: urls,
    selectedIndex: TmdbBackdropRotation.clamp(index, urls.length),
    title: title,
  );

  TmdbPhotoViewer next() => count <= 0
      ? this
      : goTo(TmdbBackdropRotation.next(index, count));

  TmdbPhotoViewer previous() => count <= 0
      ? this
      : goTo((index - 1 + count) % count);

  /// 点击某个 URL 时构造查看器；URL 不在列表时定位到第一张。
  static TmdbPhotoViewer open({
    required List<String> urls,
    required String url,
    String title = '',
  }) {
    final index = urls.indexOf(url);
    return TmdbPhotoViewer(
      urls: urls,
      selectedIndex: index < 0 ? 0 : index,
      title: title,
    );
  }
}

// ---------------------------------------------------------------------------
// 人物作品（演职人员点击 → 人物页，`04` §6.1）
// ---------------------------------------------------------------------------

/// 人物作品条目（`person.combined_credits`）。
class TmdbPersonWork {
  const TmdbPersonWork({
    required this.item,
    this.character = '',
    this.job = '',
    this.department = '',
    this.episodeCount = 0,
  });

  final TmdbItem item;

  /// 饰演角色（演员）。
  final String character;

  /// 职务（职员）。
  final String job;
  final String department;
  final int episodeCount;

  bool get isCast => character.isNotEmpty || department == 'Acting';

  /// 副标题：`饰 角色 · 2019` / `导演 · 2019`。
  String get subtitle {
    final parts = <String>[
      if (character.isNotEmpty) '饰 $character',
      if (job.isNotEmpty) job,
      if (item.subtitle.isNotEmpty) item.subtitle,
    ];
    return parts.join(' · ');
  }

  /// 从 `combined_credits.cast/crew` 列表构造（按身份去重，保留首次出现）。
  static List<TmdbPersonWork> listFrom(
    Object? value, {
    String Function(String base, String? path)? image,
    String imageBase = '',
    String backdropBase = '',
    bool cast = true,
  }) {
    if (value is! List) return const [];
    final result = <TmdbPersonWork>[];
    final seen = <String>{};
    for (final raw in value) {
      final item = TmdbItem.fromSearchResult(
        raw,
        image: image,
        imageBase: imageBase,
        backdropBase: backdropBase,
      );
      if (item == null) continue;
      final key = item.identity?.key ?? item.title;
      if (!seen.add(key)) continue;
      final map = raw is Map ? raw.cast<Object?, Object?>() : const <Object?, Object?>{};
      result.add(
        TmdbPersonWork(
          item: item,
          character: tmdbFirstNonEmpty([map['character']]),
          job: tmdbFirstNonEmpty([map['job']]),
          department: tmdbFirstNonEmpty([map['department']]),
          episodeCount: tmdbInt(map['episode_count']),
        ),
      );
    }
    return result;
  }
}

// ---------------------------------------------------------------------------
// 内部工具
// ---------------------------------------------------------------------------

Map<String, Object?>? _mapOf(Object? value) {
  if (value is! Map) return null;
  return value.cast<String, Object?>();
}

List<Object?> _listOf(Object? value) {
  if (value is! List) return const [];
  return value;
}
