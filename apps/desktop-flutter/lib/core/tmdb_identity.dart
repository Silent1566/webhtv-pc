/// TMDB 媒体身份、匹配记录与三层缓存键（`docs/phase4/design/01` §2）。
///
/// 这一层是**纯逻辑**：不依赖 Flutter，也不依赖 `dart:io`。
/// 存储由 `TmdbIdentityService`（服务层）注入，便于用内存实现做单测。
///
/// 关键契约：
/// - `tmdbId <= 0` 一律视为无身份，不得构造 [TmdbIdentity]（§2.1）。
/// - **不引入** `tmdbId == -1` 冲突语义；冲突用 [TmdbMatchConflict] 显式表达（§7.4）。
/// - 手动结论**不得**被自动匹配覆盖（§2.5）。
library;

import 'tmdb_title.dart';

/// TMDB 媒体类型。只支持 `movie` 与 `tv`（`person` 等一律过滤掉）。
enum TmdbMediaType {
  movie,
  tv;

  /// 从 TMDB 的 `media_type` 字符串解析。无法识别返回 `null`。
  static TmdbMediaType? parse(Object? value) {
    if (value is! String) return null;
    switch (value.trim().toLowerCase()) {
      case 'movie':
        return TmdbMediaType.movie;
      case 'tv':
        return TmdbMediaType.tv;
      default:
        return null;
    }
  }

  String get wireName => name;
}

// ---------------------------------------------------------------------------
// §2.1 媒体身份
// ---------------------------------------------------------------------------

/// `MediaIdentity = mediaType + tmdbId`。
///
/// 构造器私有，只能经 [from] / [of] 创建，从而在类型层面挡住 `tmdbId <= 0`。
class TmdbIdentity {
  const TmdbIdentity._(this.mediaType, this.tmdbId);

  final TmdbMediaType mediaType;
  final int tmdbId;

  /// 稳定字符串键，形如 `tv:1399`。
  String get key => '${mediaType.name}:$tmdbId';

  bool get isTv => mediaType == TmdbMediaType.tv;
  bool get isMovie => mediaType == TmdbMediaType.movie;

  /// 唯一合法入口：`tmdbId <= 0` 或类型无法识别时返回 `null`。
  static TmdbIdentity? of(TmdbMediaType? mediaType, int? tmdbId) {
    if (mediaType == null || tmdbId == null || tmdbId <= 0) return null;
    return TmdbIdentity._(mediaType, tmdbId);
  }

  /// 从 TMDB 响应的 `media_type` + `id` 构造。
  static TmdbIdentity? from(Object? mediaType, Object? tmdbId) {
    final type = TmdbMediaType.parse(mediaType);
    final id = tmdbId is int ? tmdbId : (tmdbId is num ? tmdbId.toInt() : null);
    return of(type, id);
  }

  /// 从 [key] 反解（形如 `tv:1399`）。
  static TmdbIdentity? parse(String? key) {
    if (key == null) return null;
    final index = key.indexOf(':');
    if (index <= 0) return null;
    final type = TmdbMediaType.parse(key.substring(0, index));
    final id = int.tryParse(key.substring(index + 1));
    return of(type, id);
  }

  @override
  bool operator ==(Object other) =>
      other is TmdbIdentity &&
      other.mediaType == mediaType &&
      other.tmdbId == tmdbId;

  @override
  int get hashCode => Object.hash(mediaType, tmdbId);

  @override
  String toString() => key;
}

// ---------------------------------------------------------------------------
// §2.2 TmdbItem（列表项 / 搜索结果项）
// ---------------------------------------------------------------------------

/// TMDB 列表项 / 搜索结果项。
///
/// 对齐上游 `bean/TmdbItem`，去掉 Android 专有字段。
/// **PC 端不填充** `doubanRating` / `recommendationReason` / `personal*`（`00` §4.3）。
class TmdbItem {
  const TmdbItem({
    required this.tmdbId,
    required this.mediaType,
    required this.title,
    this.subtitle = '',
    this.overview,
    this.posterUrl,
    this.backdropUrl,
    this.credit,
    this.rating = 0,
    this.tmdbRating = 0,
    this.originalLanguage = '',
    this.originCountry = '',
    this.genreIds = const [],
    this.department,
  });

  final int tmdbId;
  final TmdbMediaType mediaType;
  final String title;
  final String subtitle;
  final String? overview;
  final String? posterUrl;
  final String? backdropUrl;
  final String? credit;

  /// 上游兼容字段；PC 端只在 `tmdbRating > 0` 时使用。
  final double rating;
  final double tmdbRating;
  final String originalLanguage;
  final String originCountry;
  final List<int> genreIds;
  final String? department;

  TmdbIdentity? get identity => TmdbIdentity.of(mediaType, tmdbId);

  bool get isTv => mediaType == TmdbMediaType.tv;
  bool get isMovie => mediaType == TmdbMediaType.movie;

  /// 从 TMDB 搜索结果条目构造（`01` §5.1）。
  ///
  /// - 跳过 `media_type` 不属于 `{movie, tv}` 的条目；
  /// - `title`：`movie` 取 `title`（回退 `name`），`tv` 取 `name`（回退 `title`）；
  /// - `date`：`movie` 取 `release_date`，`tv` 取 `first_air_date`；
  /// - `subtitle` = `buildSubtitle(mediaType, date, vote)`；
  /// - 海报/背景图地址由调用方注入的 [image] 拼接函数生成。
  static TmdbItem? fromSearchResult(
    Object? value, {
    String Function(String base, String? path)? image,
    String imageBase = '',
    String backdropBase = '',
  }) {
    if (value is! Map) return null;
    final map = value.cast<Object?, Object?>();
    final mediaType = TmdbMediaType.parse(map['media_type']);
    if (mediaType == null) return null;
    final rawId = map['id'];
    final tmdbId = rawId is int ? rawId : (rawId is num ? rawId.toInt() : null);
    final identity = TmdbIdentity.of(mediaType, tmdbId);
    if (identity == null) return null;

    final isMovie = mediaType == TmdbMediaType.movie;
    final title = isMovie
        ? _firstNonEmpty([map['title'], map['name']])
        : _firstNonEmpty([map['name'], map['title']]);
    if (title == null) return null;

    final date = isMovie
        ? _string(map['release_date'])
        : _string(map['first_air_date']);
    final voteAverage = _double(map['vote_average']);
    final posterPath = _string(map['poster_path']);
    final backdropPath = _string(map['backdrop_path']);
    final countries = map['origin_country'];
    final country = countries is List && countries.isNotEmpty
        ? _string(countries.first) ?? ''
        : '';

    return TmdbItem(
      tmdbId: identity.tmdbId,
      mediaType: mediaType,
      title: title,
      subtitle: buildSubtitle(date, voteAverage),
      overview: _string(map['overview']),
      posterUrl: image?.call(imageBase, posterPath),
      backdropUrl: image?.call(backdropBase, backdropPath),
      rating: voteAverage,
      tmdbRating: voteAverage,
      originalLanguage: _string(map['original_language']) ?? '',
      originCountry: country,
      genreIds: _intList(map['genre_ids']),
    );
  }

  /// 副标题：`<年份> · <评分>`；两者都缺时为空串。
  static String buildSubtitle(String? date, double voteAverage) {
    final year = firstYear(date);
    final vote = voteAverage > 0
        ? voteAverage.toStringAsFixed(1)
        : '';
    final parts = <String>[
      if (year > 0) '$year',
      if (vote.isNotEmpty) vote,
    ];
    return parts.join(' · ');
  }

  TmdbItem copyWith({
    String? title,
    String? subtitle,
    String? overview,
    String? posterUrl,
    String? backdropUrl,
    String? credit,
    double? rating,
    double? tmdbRating,
    String? originalLanguage,
    String? originCountry,
    List<int>? genreIds,
    String? department,
  }) {
    return TmdbItem(
      tmdbId: tmdbId,
      mediaType: mediaType,
      title: title ?? this.title,
      subtitle: subtitle ?? this.subtitle,
      overview: overview ?? this.overview,
      posterUrl: posterUrl ?? this.posterUrl,
      backdropUrl: backdropUrl ?? this.backdropUrl,
      credit: credit ?? this.credit,
      rating: rating ?? this.rating,
      tmdbRating: tmdbRating ?? this.tmdbRating,
      originalLanguage: originalLanguage ?? this.originalLanguage,
      originCountry: originCountry ?? this.originCountry,
      genreIds: genreIds ?? this.genreIds,
      department: department ?? this.department,
    );
  }

  Map<String, Object?> toJson() => {
    'tmdbId': tmdbId,
    'mediaType': mediaType.name,
    'title': title,
    'subtitle': subtitle,
    if (overview != null) 'overview': overview,
    if (posterUrl != null) 'posterUrl': posterUrl,
    if (backdropUrl != null) 'backdropUrl': backdropUrl,
    if (credit != null) 'credit': credit,
    'rating': rating,
    'tmdbRating': tmdbRating,
    'originalLanguage': originalLanguage,
    'originCountry': originCountry,
    'genreIds': genreIds,
    if (department != null) 'department': department,
  };

  @override
  String toString() => 'TmdbItem(${identity?.key ?? '?'} $title)';
}

// ---------------------------------------------------------------------------
// §2.3 匹配记录
// ---------------------------------------------------------------------------

/// 匹配来源：自动匹配或用户手动选定。
enum TmdbMatchSource {
  auto,
  manual;

  static TmdbMatchSource parse(Object? value) =>
      value == 'manual' ? TmdbMatchSource.manual : TmdbMatchSource.auto;
}

/// 匹配记录（`01` §2.3）。
///
/// 快照字段必须足以在 TMDB 不可用时**离线渲染详情页头部**（标题/海报/评分/简介）。
class TmdbMatchRecord {
  const TmdbMatchRecord({
    required this.identity,
    required this.title,
    this.subtitle = '',
    this.overview,
    this.posterUrl,
    this.backdropUrl,
    this.credit,
    this.rating = 0,
    this.tmdbRating = 0,
    this.originalLanguage = '',
    this.originCountry = '',
    this.manual = false,
    this.manualTitles = const [],
    this.matchedAt = 0,
  });

  final TmdbIdentity identity;
  final String title;
  final String subtitle;
  final String? overview;
  final String? posterUrl;
  final String? backdropUrl;
  final String? credit;
  final double rating;
  final double tmdbRating;
  final String originalLanguage;
  final String originCountry;
  final bool manual;

  /// 手动选择的标题别名（已归一）。自动记录为空。
  final List<String> manualTitles;

  final int matchedAt;

  TmdbMatchSource get source =>
      manual ? TmdbMatchSource.manual : TmdbMatchSource.auto;

  bool get isManual => manual && identity.tmdbId > 0;

  /// 是否与另一个记录指向同一 TMDB 身份。
  bool sameIdentity(TmdbMatchRecord? other) =>
      other != null && other.identity == identity;

  /// 手动记录的别名是否命中给定源标题（`01` §2.4 的条目级锚点判定）。
  ///
  /// 上游语义：别名为 `null` 只可能来自旧版本数据，放行；
  /// 由 `putManual` 写入的条目一定带列表，**即使清洗后为空串也不放行**
  /// （同一 `vodId` 下可能挂着多部作品，放行会让锚点变成通配符）。
  bool matchesManualTitle(String normalizedTitle) {
    if (!manual) return false;
    if (manualTitles.isEmpty) return false;
    return normalizedTitle.isNotEmpty && manualTitles.contains(normalizedTitle);
  }

  TmdbMatchRecord copyWith({
    bool? manual,
    List<String>? manualTitles,
    int? matchedAt,
    String? title,
    String? subtitle,
    String? overview,
    String? posterUrl,
    String? backdropUrl,
    String? credit,
    double? rating,
    double? tmdbRating,
    String? originalLanguage,
    String? originCountry,
  }) {
    return TmdbMatchRecord(
      identity: identity,
      title: title ?? this.title,
      subtitle: subtitle ?? this.subtitle,
      overview: overview ?? this.overview,
      posterUrl: posterUrl ?? this.posterUrl,
      backdropUrl: backdropUrl ?? this.backdropUrl,
      credit: credit ?? this.credit,
      rating: rating ?? this.rating,
      tmdbRating: tmdbRating ?? this.tmdbRating,
      originalLanguage: originalLanguage ?? this.originalLanguage,
      originCountry: originCountry ?? this.originCountry,
      manual: manual ?? this.manual,
      manualTitles: manualTitles ?? this.manualTitles,
      matchedAt: matchedAt ?? this.matchedAt,
    );
  }

  TmdbItem toItem() => TmdbItem(
    tmdbId: identity.tmdbId,
    mediaType: identity.mediaType,
    title: title,
    subtitle: subtitle,
    overview: overview,
    posterUrl: posterUrl,
    backdropUrl: backdropUrl,
    credit: credit,
    rating: rating,
    tmdbRating: tmdbRating,
    originalLanguage: originalLanguage,
    originCountry: originCountry,
  );

  static TmdbMatchRecord fromItem(
    TmdbItem item, {
    required bool manual,
    List<String> manualTitles = const [],
    required int matchedAt,
  }) {
    final identity = item.identity;
    if (identity == null) {
      throw ArgumentError('TmdbItem 缺少有效身份，不能构造匹配记录');
    }
    return TmdbMatchRecord(
      identity: identity,
      title: item.title,
      subtitle: item.subtitle,
      overview: item.overview,
      posterUrl: item.posterUrl,
      backdropUrl: item.backdropUrl,
      credit: item.credit,
      rating: item.rating,
      tmdbRating: item.tmdbRating,
      originalLanguage: item.originalLanguage,
      originCountry: item.originCountry,
      manual: manual,
      manualTitles: List.unmodifiable(manualTitles),
      matchedAt: matchedAt,
    );
  }
}

// ---------------------------------------------------------------------------
// §7.4 匹配结果（显式类型，不用 tmdbId = -1）
// ---------------------------------------------------------------------------

/// 未匹配的原因（`01` §7.4）。
enum TmdbMissReason {
  notConfigured,
  siteDisabled,
  noCandidates,
  ambiguous,
  networkFailure,
  authFailure,
}

/// 匹配结果基类。
sealed class TmdbMatchResult {
  const TmdbMatchResult();
}

/// 命中。
class TmdbMatchHit extends TmdbMatchResult {
  const TmdbMatchHit(this.record);

  final TmdbMatchRecord record;

  TmdbItem get item => record.toItem();

  @override
  bool operator ==(Object other) =>
      other is TmdbMatchHit && other.record.identity == record.identity;

  @override
  int get hashCode => record.identity.hashCode;
}

/// 未匹配。
class TmdbMatchMiss extends TmdbMatchResult {
  const TmdbMatchMiss(this.reason, {this.detail});

  final TmdbMissReason reason;
  final String? detail;

  @override
  bool operator ==(Object other) =>
      other is TmdbMatchMiss && other.reason == reason;

  @override
  int get hashCode => reason.hashCode;

  @override
  String toString() => 'TmdbMatchMiss(${reason.name}${detail == null ? '' : ', $detail'})';
}

/// 同名歧义（两个**手动**结论指向不同作品）。
class TmdbMatchConflict extends TmdbMatchResult {
  const TmdbMatchConflict(this.sourceTitle);

  final String sourceTitle;

  @override
  bool operator ==(Object other) =>
      other is TmdbMatchConflict && other.sourceTitle == sourceTitle;

  @override
  int get hashCode => sourceTitle.hashCode;

  @override
  String toString() => 'TmdbMatchConflict($sourceTitle)';
}

/// TMDB 能力不可用（未配置 / 站点禁用）。UI 据此决定是否渲染 TMDB 区块。
class TmdbMatchDisabled extends TmdbMatchResult {
  const TmdbMatchDisabled(this.reason);

  final TmdbMissReason reason;

  bool get isNotConfigured => reason == TmdbMissReason.notConfigured;
  bool get isSiteDisabled => reason == TmdbMissReason.siteDisabled;

  @override
  bool operator ==(Object other) =>
      other is TmdbMatchDisabled && other.reason == reason;

  @override
  int get hashCode => reason.hashCode;

  @override
  String toString() => 'TmdbMatchDisabled(${reason.name})';
}

// ---------------------------------------------------------------------------
// §2.4 三层缓存键
// ---------------------------------------------------------------------------

/// 匹配缓存的键空间。
///
/// ```text
/// 条目级键      : <siteKey>@@@<vodId>
/// 条目+标题键   : <siteKey>@@@<vodId>@@@<normalizedSourceTitle>
/// 全局标题域键  : __title__@@@<normalizedSourceTitle>
/// ```
abstract final class TmdbCacheKey {
  /// 与 `history` 表一致的分隔符（`docs/webhtv-pc-design.md` §15）。
  static const String separator = '@@@';

  /// 全局标题域的 scope 前缀。
  static const String titleScope = '__title__';

  /// 条目级键（`sourceTitle` 为空时）。
  static String entry(String siteKey, String vodId) =>
      '$siteKey$separator$vodId';

  /// 条目+标题键。`normalizedTitle` 为空时退化为条目级键。
  static String scoped(String siteKey, String vodId, String normalizedTitle) {
    if (normalizedTitle.isEmpty) return entry(siteKey, vodId);
    return '${entry(siteKey, vodId)}$separator$normalizedTitle';
  }

  /// 全局标题域键。
  static String title(String normalizedTitle) =>
      normalizedTitle.isEmpty ? '' : '$titleScope$separator$normalizedTitle';

  /// 归一化源标题：`normalize(cleanTitle(sourceTitle))`。
  ///
  /// 结果中的分隔符会被替换为空格，避免键被撑开（对齐上游 `sourceKey`）。
  static String normalizeSourceTitle(String? sourceTitle) {
    final cleaned = cleanTitle(sourceTitle ?? '');
    final normalized = normalizeTitle(cleaned);
    return normalized.replaceAll(separator, ' ').trim();
  }
}

/// 一个站源标题的匹配缓存视图（纯内存，可注入持久化）。
///
/// 对应上游 `TmdbMatchCache`，但**不引入** `tmdbId = -1` 冲突标记；
/// 冲突由 [conflict] 集合显式记录（`01` §2.4）。
class TmdbMatchCache {
  TmdbMatchCache();

  final Map<String, TmdbMatchRecord> _entries = {};

  /// 记录冲突的全局标题（归一化后）。
  final Set<String> _conflicts = {};

  Map<String, TmdbMatchRecord> get entries => Map.unmodifiable(_entries);
  Set<String> get conflicts => Set.unmodifiable(_conflicts);

  int get length => _entries.length;

  void clear() {
    _entries.clear();
    _conflicts.clear();
  }

  /// 两参数查询：条目级键（`01` §2.4）。
  TmdbMatchRecord? find(String siteKey, String vodId) {
    if (siteKey.isEmpty || vodId.isEmpty) return null;
    return _entries[TmdbCacheKey.entry(siteKey, vodId)];
  }

  /// 三参数查询：按读取顺序返回（手动锚点 → 条目+标题 → 条目级 → 标题域）。
  ///
  /// 标题域命中时若该标题已被标记冲突，返回 `null`（读取方按未匹配处理）。
  TmdbMatchRecord? findScoped(
    String siteKey,
    String vodId,
    String? sourceTitle,
  ) {
    if (siteKey.isEmpty || vodId.isEmpty) return null;
    final normalized = TmdbCacheKey.normalizeSourceTitle(sourceTitle);
    if (normalized.isEmpty) return find(siteKey, vodId);

    // 1. 手动条目级锚点：只在标题确实指向同一作品时生效。
    final anchor = find(siteKey, vodId);
    if (anchor != null && anchor.isManual && anchor.matchesManualTitle(normalized)) {
      return anchor;
    }

    // 2. 条目+标题键。
    final scoped = _entries[TmdbCacheKey.scoped(siteKey, vodId, normalized)];
    if (scoped != null) return scoped;

    // 3. 条目级键（需标题兼容）。
    if (_isCompatible(anchor, normalized)) return anchor;

    // 4. 全局标题域键（需标题兼容）。
    final titleKey = TmdbCacheKey.title(normalized);
    if (titleKey.isEmpty || _conflicts.contains(normalized)) return null;
    final byTitle = _entries[titleKey];
    return _isCompatible(byTitle, normalized) ? byTitle : null;
  }

  /// 手动结论是否命中（`01` §2.5）。
  bool isManual(String siteKey, String vodId, String? sourceTitle) =>
      findScoped(siteKey, vodId, sourceTitle)?.isManual ?? false;

  /// 写入自动结论。**存在手动条目时直接返回，不覆盖**（`01` §2.5）。
  ///
  /// 返回是否真的写入。
  bool put(
    String siteKey,
    String vodId,
    TmdbItem item, {
    String? sourceTitle,
    required int matchedAt,
  }) {
    final identity = item.identity;
    if (identity == null || siteKey.isEmpty || vodId.isEmpty) return false;
    final normalized = TmdbCacheKey.normalizeSourceTitle(sourceTitle);

    // 自动匹配不得覆盖用户的手动选择。
    if (normalized.isEmpty) {
      if (find(siteKey, vodId)?.isManual ?? false) return false;
    } else if (findScoped(siteKey, vodId, sourceTitle)?.isManual ?? false) {
      return false;
    }

    final record = TmdbMatchRecord.fromItem(
      item,
      manual: false,
      matchedAt: matchedAt,
    );

    if (normalized.isEmpty) {
      _entries[TmdbCacheKey.entry(siteKey, vodId)] = record;
      return true;
    }

    _entries[TmdbCacheKey.scoped(siteKey, vodId, normalized)] = record;
    _putTitle(normalized, record);
    return true;
  }

  /// 写入手动结论（`01` §2.5）。
  ///
  /// 同时写入：条目级锚点、每个别名的条目+标题键、TMDB 标题别名。
  /// 返回是否真的写入。
  bool putManual(
    String siteKey,
    String vodId,
    List<String> sourceTitles,
    TmdbItem item, {
    required int matchedAt,
  }) {
    final identity = item.identity;
    if (identity == null || siteKey.isEmpty || vodId.isEmpty) return false;

    final aliases = <String>{};
    for (final sourceTitle in sourceTitles) {
      final normalized = TmdbCacheKey.normalizeSourceTitle(sourceTitle);
      if (normalized.isNotEmpty) aliases.add(normalized);
    }
    // TMDB 标题本身也是别名：富集会把 vodName 改写成它，下次进场用它读回。
    final tmdbTitle = TmdbCacheKey.normalizeSourceTitle(item.title);
    if (tmdbTitle.isNotEmpty) aliases.add(tmdbTitle);

    final record = TmdbMatchRecord.fromItem(
      item,
      manual: true,
      manualTitles: aliases.toList(),
      matchedAt: matchedAt,
    );

    _entries[TmdbCacheKey.entry(siteKey, vodId)] = record;
    for (final alias in aliases) {
      _entries[TmdbCacheKey.scoped(siteKey, vodId, alias)] = record;
      _putTitle(alias, record);
    }
    return true;
  }

  /// 移除一个条目的全部键（`01` §2.5 媒体重新匹配时使用）。
  bool remove(String siteKey, String vodId) {
    if (siteKey.isEmpty || vodId.isEmpty) return false;
    final prefix = '${TmdbCacheKey.entry(siteKey, vodId)}${TmdbCacheKey.separator}';
    final entryKey = TmdbCacheKey.entry(siteKey, vodId);
    var changed = false;
    if (_entries.remove(entryKey) != null) changed = true;
    for (final key in _entries.keys.toList()) {
      if (key.startsWith(prefix)) {
        _entries.remove(key);
        changed = true;
      }
    }
    return changed;
  }

  /// 维护全局标题域（`01` §2.4）。
  ///
  /// - 同身份 → 覆盖；
  /// - 手动 vs 自动 → 手动优先，自动不得覆盖手动；
  /// - 手动 vs 手动且身份不同 → 记冲突。
  void _putTitle(String normalizedTitle, TmdbMatchRecord record) {
    final key = TmdbCacheKey.title(normalizedTitle);
    if (key.isEmpty) return;
    final cached = _entries[key];
    if (cached == null || cached.sameIdentity(record)) {
      _entries[key] = record;
      _conflicts.remove(normalizedTitle);
      return;
    }
    if (record.isManual && !cached.isManual) {
      _entries[key] = record;
      _conflicts.remove(normalizedTitle);
      return;
    }
    if (cached.isManual && !record.isManual) {
      // 保留手动结论，别让自动猜测把它冲掉。
      return;
    }
    // 两个都是手动且身份不同 → 真正的同名歧义。
    _conflicts.add(normalizedTitle);
  }

  /// 标题兼容（`01` §2.4）：源标题与缓存标题归一后相等，或源标题为空。
  bool _isCompatible(TmdbMatchRecord? record, String normalizedTitle) {
    if (record == null || record.identity.tmdbId <= 0) return false;
    if (normalizedTitle.isEmpty) return true;
    final cached = TmdbCacheKey.normalizeSourceTitle(record.title);
    return cached.isEmpty || cached == normalizedTitle;
  }
}

// ---------------------------------------------------------------------------
// 内部工具
// ---------------------------------------------------------------------------

String? _string(Object? value) {
  if (value == null) return null;
  if (value is String) return value;
  return value.toString();
}

String? _firstNonEmpty(List<Object?> values) {
  for (final value in values) {
    final text = _string(value)?.trim();
    if (text != null && text.isNotEmpty) return text;
  }
  return null;
}

double _double(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? 0;
  return 0;
}

List<int> _intList(Object? value) {
  if (value is! List) return const [];
  final result = <int>[];
  for (final item in value) {
    if (item is int) {
      result.add(item);
    } else if (item is num) {
      result.add(item.toInt());
    } else if (item is String) {
      final parsed = int.tryParse(item);
      if (parsed != null) result.add(parsed);
    }
  }
  return List.unmodifiable(result);
}
