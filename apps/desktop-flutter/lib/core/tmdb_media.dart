/// TMDB 剧集、人物、相关视频与图片选择（`docs/phase4/design/03` §4.3/§4.4、
/// `04` §7.1）。
///
/// 这一层是**纯逻辑**：不依赖 Flutter，也不依赖 `dart:io`。
///
/// 上游对应实现：`bean/TmdbEpisode`、`bean/TmdbPerson`、`bean/TmdbVideo`、
/// `utils/TmdbImageSelector`。
library;

import 'tmdb_identity.dart';
import 'tmdb_title.dart';

// ---------------------------------------------------------------------------
// §4.3 TmdbEpisode
// ---------------------------------------------------------------------------

final RegExp _placeholderEpisodeTitle = RegExp(
  r'^(?:Episode|EP|E)\s*0*\d+$',
  caseSensitive: false,
);

/// TMDB 单集（`03` §4.3）。
class TmdbEpisode {
  const TmdbEpisode({
    required this.number,
    this.title = '',
    this.date = '',
    this.overview,
    this.stillUrl,
    this.voteAverage = 0,
    this.runtime = 0,
    this.tmdbId = 0,
    this.seasonNumber = 0,
  });

  /// 季内集号。
  final int number;
  final String title;
  final String date;
  final String? overview;
  final String? stillUrl;
  final double voteAverage;
  final int runtime;
  final int tmdbId;
  final int seasonNumber;

  /// 剧集卡片标题（`03` §4.3）。
  ///
  /// 1. `title` 非空且不是 `Episode N` 之类占位 → `E{number} {title}`
  /// 2. 否则若 `date` 非空 → `E{number} · {date}`
  /// 3. 否则 → `第 {number} 集`
  String get displayTitle {
    final clean = title.trim();
    if (clean.isNotEmpty && !_placeholderEpisodeTitle.hasMatch(clean)) {
      return 'E$number $clean';
    }
    final trimmedDate = date.trim();
    if (trimmedDate.isNotEmpty) return 'E$number · $trimmedDate';
    return '第 $number 集';
  }

  /// 从 TMDB `episodes[]` 条目构造。
  static TmdbEpisode? fromJson(
    Object? value, {
    String Function(String base, String? path)? image,
    String imageBase = '',
    int fallbackSeasonNumber = 0,
  }) {
    if (value is! Map) return null;
    final map = value.cast<Object?, Object?>();
    final number = _asInt(map['episode_number']);
    if (number == null || number <= 0) return null;
    final stillPath = _asString(map['still_path']);
    return TmdbEpisode(
      number: number,
      title: _asString(map['name']) ?? '',
      date: _asString(map['air_date']) ?? '',
      overview: _asString(map['overview']),
      stillUrl: image?.call(imageBase, stillPath),
      voteAverage: _asDouble(map['vote_average']),
      runtime: _asInt(map['runtime']) ?? 0,
      tmdbId: _asInt(map['id']) ?? 0,
      seasonNumber: _asInt(map['season_number']) ?? fallbackSeasonNumber,
    );
  }

  /// 解析 `season.episodes[]` 列表。
  static List<TmdbEpisode> listFromSeason(
    Object? season, {
    String Function(String base, String? path)? image,
    String imageBase = '',
    int fallbackSeasonNumber = 0,
  }) {
    if (season is! Map) return const [];
    final raw = season['episodes'];
    if (raw is! List) return const [];
    final seasonNumber = _asInt(season['season_number']) ?? fallbackSeasonNumber;
    return raw
        .map(
          (item) => TmdbEpisode.fromJson(
            item,
            image: image,
            imageBase: imageBase,
            fallbackSeasonNumber: seasonNumber,
          ),
        )
        .whereType<TmdbEpisode>()
        .toList();
  }

  @override
  bool operator ==(Object other) =>
      other is TmdbEpisode &&
      other.number == number &&
      other.seasonNumber == seasonNumber &&
      other.title == title;

  @override
  int get hashCode => Object.hash(number, seasonNumber, title);

  @override
  String toString() => 'TmdbEpisode(S$seasonNumber E$number $title)';
}

// ---------------------------------------------------------------------------
// §4.3 TmdbPerson
// ---------------------------------------------------------------------------

/// TMDB 人物（`03` §4.3）。
class TmdbPerson {
  const TmdbPerson({
    required this.personId,
    required this.name,
    this.subtitle = '',
    this.profileUrl,
    this.knownForDepartment = '',
    this.biography,
  });

  final int personId;
  final String name;
  final String subtitle;
  final String? profileUrl;
  final String knownForDepartment;
  final String? biography;

  static TmdbPerson? fromJson(
    Object? value, {
    String Function(String base, String? path)? image,
    String imageBase = '',
    String? subtitle,
    String? biography,
  }) {
    if (value is! Map) return null;
    final map = value.cast<Object?, Object?>();
    final id = _asInt(map['id']);
    final name = _asString(map['name']);
    if (id == null || id <= 0 || name == null || name.isEmpty) return null;
    return TmdbPerson(
      personId: id,
      name: name,
      subtitle: subtitle ?? _personSubtitle(map) ?? '',
      profileUrl: image?.call(imageBase, _asString(map['profile_path'])),
      knownForDepartment: _asString(map['known_for_department']) ?? '',
      biography: biography ?? _asString(map['biography']),
    );
  }

  static List<TmdbPerson> listFrom(
    Object? value, {
    String Function(String base, String? path)? image,
    String imageBase = '',
  }) {
    if (value is! List) return const [];
    return value
        .map(
          (item) =>
              TmdbPerson.fromJson(item, image: image, imageBase: imageBase),
        )
        .whereType<TmdbPerson>()
        .toList();
  }

  @override
  bool operator ==(Object other) =>
      other is TmdbPerson && other.personId == personId;

  @override
  int get hashCode => personId.hashCode;

  @override
  String toString() => 'TmdbPerson($personId $name)';
}

String? _personSubtitle(Map<Object?, Object?> map) {
  // 演员取 character / roles[0].character；职员取 job。
  final character = _asString(map['character']);
  if (character != null && character.isNotEmpty) return character;
  final roles = map['roles'];
  if (roles is List && roles.isNotEmpty) {
    final first = roles.first;
    if (first is Map) {
      final role = _asString(first['character']);
      if (role != null && role.isNotEmpty) return role;
    }
  }
  final job = _asString(map['job']);
  if (job != null && job.isNotEmpty) return job;
  return null;
}

// ---------------------------------------------------------------------------
// §7.1 TmdbVideo（相关视频）
// ---------------------------------------------------------------------------

/// 相关视频的作用域（`04` §7.1）。
enum TmdbVideoScope {
  movie,
  tv,
  season,
  episode;

  static TmdbVideoScope? parse(Object? value) {
    switch (value) {
      case 'movie':
        return TmdbVideoScope.movie;
      case 'tv':
        return TmdbVideoScope.tv;
      case 'season':
        return TmdbVideoScope.season;
      case 'episode':
        return TmdbVideoScope.episode;
      default:
        return null;
    }
  }
}

/// 字段长度上限与 key 安全规则（`04` §7.1）。
const int tmdbVideoMaxIdLength = 128;
const int tmdbVideoMaxNameLength = 240;
const int tmdbVideoMaxTypeLength = 64;
const int tmdbVideoMaxLanguageLength = 16;
const int tmdbVideoMaxCountryLength = 16;

final RegExp tmdbVideoSafeKey = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

/// 相关视频（`04` §7.1）。
///
/// **只接受** `key` 匹配 `[A-Za-z0-9_-]{1,128}` 的条目（拒绝注入）。
class TmdbVideo {
  const TmdbVideo({
    required this.id,
    required this.key,
    required this.site,
    required this.name,
    required this.type,
    this.official = false,
    this.size = 0,
    this.iso6391 = '',
    this.iso31661 = '',
    this.publishedAt = '',
    this.scope = TmdbVideoScope.tv,
    this.seasonNumber = 0,
    this.episodeNumber = 0,
  });

  final String id;
  final String key;
  final String site;
  final String name;
  final String type;
  final bool official;
  final int size;
  final String iso6391;
  final String iso31661;
  final String publishedAt;
  final TmdbVideoScope scope;
  final int seasonNumber;
  final int episodeNumber;

  /// 去重标识：`site|key`。
  String get identity => '$site|$key';

  /// 浏览器打开地址。
  String get watchUrl => 'https://www.youtube.com/watch?v=$key';

  /// 缩略图地址。
  String get thumbnailUrl => 'https://i.ytimg.com/vi/$key/hqdefault.jpg';

  String get scopeLabel => switch (scope) {
    TmdbVideoScope.movie => '电影',
    TmdbVideoScope.tv => '剧集',
    TmdbVideoScope.season => '第 $seasonNumber 季',
    TmdbVideoScope.episode => '第 $seasonNumber 季第 $episodeNumber 集',
  };

  String get displayType {
    switch (type.toLowerCase()) {
      case 'trailer':
        return '预告';
      case 'teaser':
        return '先导';
      case 'clip':
        return '片段';
      case 'featurette':
        return '花絮';
      case 'behind the scenes':
        return '幕后';
      case 'bloopers':
        return '花絮';
      default:
        return type.isEmpty ? '视频' : type;
    }
  }

  /// 从 TMDB `videos.results[]` 条目构造。
  ///
  /// 返回 `null` 表示该条目不合法（`key` 不匹配安全规则，或必需字段缺失）。
  static TmdbVideo? fromJson(
    Object? value, {
    required TmdbVideoScope scope,
    int seasonNumber = 0,
    int episodeNumber = 0,
  }) {
    if (value is! Map) return null;
    final map = value.cast<Object?, Object?>();
    final key = _asString(map['key']) ?? '';
    if (!tmdbVideoSafeKey.hasMatch(key)) return null;
    final name = _asString(map['name']) ?? '';
    final site = _asString(map['site']) ?? '';
    if (name.isEmpty || site.isEmpty) return null;
    return TmdbVideo(
      id: _limit(_asString(map['id']) ?? '', tmdbVideoMaxIdLength),
      key: key,
      site: _limit(site, tmdbVideoMaxTypeLength),
      name: _limit(name, tmdbVideoMaxNameLength),
      type: _limit(_asString(map['type']) ?? '', tmdbVideoMaxTypeLength),
      official: _asBool(map['official']),
      size: _asInt(map['size']) ?? 0,
      iso6391: _limit(_asString(map['iso_639_1']) ?? '', tmdbVideoMaxLanguageLength),
      iso31661: _limit(_asString(map['iso_3166_1']) ?? '', tmdbVideoMaxCountryLength),
      publishedAt: _asString(map['published_at']) ?? '',
      scope: scope,
      seasonNumber: seasonNumber,
      episodeNumber: episodeNumber,
    );
  }

  /// 解析 `videos.results[]` 列表并过滤非法条目。
  static List<TmdbVideo> listFrom(
    Object? videos, {
    required TmdbVideoScope scope,
    int seasonNumber = 0,
    int episodeNumber = 0,
  }) {
    if (videos is! Map) return const [];
    final raw = videos['results'];
    if (raw is! List) return const [];
    return raw
        .map(
          (item) => TmdbVideo.fromJson(
            item,
            scope: scope,
            seasonNumber: seasonNumber,
            episodeNumber: episodeNumber,
          ),
        )
        .whereType<TmdbVideo>()
        .toList();
  }

  /// 合并与排序（`04` §7.1）。
  ///
  /// 排序键依次：`scopeRank` → `languageRank` → `typeRank` → `official` → `size` 降序。
  /// 去重按 [identity]。
  static List<TmdbVideo> mergeAndRank(
    List<TmdbVideo> values, {
    required String preferredLanguage,
    int limit = 0,
  }) {
    final seen = <String>{};
    final unique = <TmdbVideo>[];
    for (final video in values) {
      if (seen.add(video.identity)) unique.add(video);
    }
    final sorted = unique.toList()
      ..sort((a, b) {
        var compare = _scopeRank(a.scope).compareTo(_scopeRank(b.scope));
        if (compare != 0) return compare;
        compare = _languageRank(a.iso6391, preferredLanguage)
            .compareTo(_languageRank(b.iso6391, preferredLanguage));
        if (compare != 0) return compare;
        compare = _typeRank(a.type).compareTo(_typeRank(b.type));
        if (compare != 0) return compare;
        compare = (b.official ? 1 : 0).compareTo(a.official ? 1 : 0);
        if (compare != 0) return compare;
        return b.size.compareTo(a.size);
      });
    if (limit <= 0 || sorted.length <= limit) return sorted;
    return sorted.sublist(0, limit);
  }
}

/// `movie/episode` > `season` > `tv`（`04` §7.1）。
int _scopeRank(TmdbVideoScope scope) => switch (scope) {
  TmdbVideoScope.movie => 0,
  TmdbVideoScope.episode => 0,
  TmdbVideoScope.season => 1,
  TmdbVideoScope.tv => 2,
};

/// 偏好语言完全匹配 > `iso6391` 为空 > 其他（`04` §7.1）。
int _languageRank(String iso6391, String preferredLanguage) {
  final language = iso6391.trim().toLowerCase();
  final preferred = preferredLanguage.trim().toLowerCase();
  if (language.isEmpty) return 1;
  if (preferred.isNotEmpty && language == preferred) return 0;
  return 2;
}

/// `Trailer` > `Teaser` > `Clip` > `Featurette` > 其他（`04` §7.1）。
int _typeRank(String type) {
  switch (type.trim().toLowerCase()) {
    case 'trailer':
      return 0;
    case 'teaser':
      return 1;
    case 'clip':
      return 2;
    case 'featurette':
      return 3;
    default:
      return 4;
  }
}

// ---------------------------------------------------------------------------
// §4.4 图片选择
// ---------------------------------------------------------------------------

/// 图片方向。
enum TmdbImageOrientation { landscape, portrait }

/// 一个候选图片（内部排序用）。
class TmdbImageCandidate {
  const TmdbImageCandidate({
    required this.url,
    required this.sourceRank,
    required this.width,
    required this.height,
    required this.voteAverage,
    required this.voteCount,
  });

  final String url;

  /// `images.<kind>` = 0；根级 `poster_path` / `backdrop_path` = 1。
  final int sourceRank;
  final int width;
  final int height;
  final double voteAverage;
  final int voteCount;

  int get pixels => width * height;
}

final RegExp _imageSizeSuffix = RegExp(r'/(?:w\d+|h\d+|original)$');

/// 图片选择（`03` §4.4）。
abstract final class TmdbImageSelector {
  /// URL 拼接（`03` §4.4）。
  ///
  /// `base` 或 `path` 为空 → `""`；`path` 已是 http(s) → 原样返回；
  /// 否则 `base + path`（base 末尾斜杠去重）。
  static String image(String base, String? path) {
    final trimmedBase = base.trim();
    final trimmedPath = (path ?? '').trim();
    if (trimmedBase.isEmpty || trimmedPath.isEmpty) return '';
    if (trimmedPath.startsWith('http://') || trimmedPath.startsWith('https://')) {
      return trimmedPath;
    }
    var normalizedBase = trimmedBase;
    while (normalizedBase.endsWith('/')) {
      normalizedBase = normalizedBase.substring(0, normalizedBase.length - 1);
    }
    final normalizedPath = trimmedPath.startsWith('/')
        ? trimmedPath
        : '/$trimmedPath';
    return '$normalizedBase$normalizedPath';
  }

  /// `stripImageSize`：反复剥离 `/w\d+|/h\d+|/original` 结尾。
  static String stripImageSize(String value) {
    var image = value.trim();
    while (image.endsWith('/')) {
      image = image.substring(0, image.length - 1);
    }
    while (_imageSizeSuffix.hasMatch(image)) {
      image = image.substring(0, image.lastIndexOf('/'));
      while (image.endsWith('/')) {
        image = image.substring(0, image.length - 1);
      }
    }
    return image;
  }

  /// 候选排序 + 去重 + 截断（`03` §4.4）。
  ///
  /// 排序键依次：`sourceRank` 升序 → 像素面积降序 → `vote_average` 降序 →
  /// `vote_count` 降序。`limit <= 0` 表示不限制。
  static List<String> urls(List<TmdbImageCandidate> candidates, int limit) {
    final sorted = candidates.toList()
      ..sort((a, b) {
        var compare = a.sourceRank.compareTo(b.sourceRank);
        if (compare != 0) return compare;
        compare = b.pixels.compareTo(a.pixels);
        if (compare != 0) return compare;
        compare = b.voteAverage.compareTo(a.voteAverage);
        if (compare != 0) return compare;
        return b.voteCount.compareTo(a.voteCount);
      });
    final result = <String>[];
    final max = limit <= 0 ? 1 << 30 : limit;
    for (final candidate in sorted) {
      if (candidate.url.isEmpty) continue;
      if (result.contains(candidate.url)) continue;
      result.add(candidate.url);
      if (result.length >= max) break;
    }
    return result;
  }

  /// 从详情对象提取候选（`images.<kind>` + 根级 `<kind>_path`）。
  static List<TmdbImageCandidate> candidates(
    Object? detail, {
    required String kind,
    required String base,
    required TmdbImageOrientation orientation,
  }) {
    if (detail is! Map) return const [];
    final map = detail.cast<Object?, Object?>();
    final result = <TmdbImageCandidate>[];

    final images = map['images'];
    if (images is Map) {
      final raw = images[kind];
      if (raw is List) {
        for (final item in raw) {
          if (item is! Map) continue;
          final itemMap = item.cast<Object?, Object?>();
          final url = image(base, _asString(itemMap['file_path']));
          if (url.isEmpty) continue;
          result.add(
            TmdbImageCandidate(
              url: url,
              sourceRank: 0,
              width: _asInt(itemMap['width']) ?? 0,
              height: _asInt(itemMap['height']) ?? 0,
              voteAverage: _asDouble(itemMap['vote_average']),
              voteCount: _asInt(itemMap['vote_count']) ?? 0,
            ),
          );
        }
      }
    }

    final rootKey = switch (kind) {
      'posters' => 'poster_path',
      'backdrops' => 'backdrop_path',
      'profiles' => 'profile_path',
      'stills' => 'still_path',
      _ => null,
    };
    if (rootKey != null) {
      final url = image(base, _asString(map[rootKey]));
      if (url.isNotEmpty) {
        result.add(
          TmdbImageCandidate(
            url: url,
            sourceRank: 1,
            width: orientation == TmdbImageOrientation.portrait ? 342 : 780,
            height: orientation == TmdbImageOrientation.portrait ? 513 : 439,
            voteAverage: 0,
            voteCount: 0,
          ),
        );
      }
    }
    return result;
  }

  /// 海报（竖版）。
  static List<String> posters(Object? detail, String base, {int limit = 0}) =>
      urls(
        candidates(
          detail,
          kind: 'posters',
          base: base,
          orientation: TmdbImageOrientation.portrait,
        ),
        limit,
      );

  /// 背景图（横版）。
  static List<String> backdrops(Object? detail, String base, {int limit = 0}) =>
      urls(
        candidates(
          detail,
          kind: 'backdrops',
          base: base,
          orientation: TmdbImageOrientation.landscape,
        ),
        limit,
      );

  /// 演职人员头像。
  static List<String> profiles(Object? person, String base, {int limit = 0}) =>
      urls(
        candidates(
          person,
          kind: 'profiles',
          base: base,
          orientation: TmdbImageOrientation.portrait,
        ),
        limit,
      );

  /// 剧集剧照。
  static List<String> stills(Object? episode, String base, {int limit = 0}) =>
      urls(
        candidates(
          episode,
          kind: 'stills',
          base: base,
          orientation: TmdbImageOrientation.landscape,
        ),
        limit,
      );

  /// 方向回退（`03` §4.4）：
  /// `preferLandscape` 为真时先取背景图，为空则回退海报；反亦反之。
  static List<String> backgrounds(
    Object? detail, {
    required String imageBase,
    required String backdropBase,
    required bool preferLandscape,
    int limit = 0,
  }) {
    final preferred = preferLandscape
        ? backdrops(detail, backdropBase, limit: limit)
        : posters(detail, imageBase, limit: limit);
    if (preferred.isNotEmpty) return preferred;
    return preferLandscape
        ? posters(detail, imageBase, limit: limit)
        : backdrops(detail, backdropBase, limit: limit);
  }
}

// ---------------------------------------------------------------------------
// 内部工具
// ---------------------------------------------------------------------------

int? _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

double _asDouble(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? 0;
  return 0;
}

String? _asString(Object? value) {
  if (value == null) return null;
  if (value is String) return value;
  return value.toString();
}

bool _asBool(Object? value) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) {
    final text = value.trim().toLowerCase();
    return text == 'true' || text == '1';
  }
  return false;
}

String _limit(String value, int maxLength) =>
    value.length <= maxLength ? value : value.substring(0, maxLength);

/// 供上层复用：TMDB 年份 → 展示用字符串。
String tmdbYearLabel(String? date) {
  final year = firstYear(date);
  return year > 0 ? '$year' : '';
}

/// 供上层复用：`TmdbItem` 列表去重（按身份）。
List<TmdbItem> dedupeItems(List<TmdbItem> items) {
  final seen = <String>{};
  final result = <TmdbItem>[];
  for (final item in items) {
    final key = item.identity?.key;
    if (key == null || seen.add(key)) result.add(item);
  }
  return result;
}
