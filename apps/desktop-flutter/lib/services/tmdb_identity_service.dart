/// TMDB 媒体身份匹配编排（`docs/phase4/design/01` §4/§5/§7）。
///
/// 把纯逻辑（`tmdb_title` / `tmdb_identity` / `tmdb_config`）与 `TmdbService`
/// 串成一条可测的匹配流程，并负责缓存的持久化读写。
///
/// 关键契约：
/// - 未配置 / 站点禁用时**零网络请求**（`01` §4 步骤 0）；
/// - 手动结论**不被自动匹配覆盖**（`01` §2.5）；
/// - 匹配失败**不抛异常**，返回结构化 `TmdbMatchMiss`（`01` §4 约束）；
/// - 鉴权失败与取消**向上传播**（`01` §4 约束）。
library;

import '../core/app_error.dart';
import '../core/tmdb_config.dart';
import '../core/tmdb_identity.dart';
import '../core/tmdb_media.dart';
import '../core/tmdb_title.dart';
import 'tmdb_service.dart';

/// 站点身份（供站点策略判定，`01` §6.3）。
class TmdbSiteRef {
  const TmdbSiteRef({required this.key, this.name = ''});

  final String key;
  final String name;

  bool get isEmpty => key.isEmpty && name.isEmpty;
}

/// 匹配缓存持久化接口（由 `TmdbMatchStore` 或内存实现提供）。
abstract interface class TmdbMatchStore {
  /// 读取匹配记录（三层键，按顺序）。未命中返回 `null`。
  TmdbMatchRecord? find({
    required String siteKey,
    required String vodId,
    String? sourceTitle,
  });

  /// 写入自动结论。
  void putAuto({
    required String siteKey,
    required String vodId,
    required TmdbItem item,
    String? sourceTitle,
    required int matchedAt,
  });

  /// 写入手动结论（含全部别名）。
  void putManual({
    required String siteKey,
    required String vodId,
    required List<String> sourceTitles,
    required TmdbItem item,
    required int matchedAt,
  });

  /// 删除条目的全部键。
  void remove({required String siteKey, required String vodId});
}

/// 内存实现（单测与降级用）。
class InMemoryTmdbMatchStore implements TmdbMatchStore {
  InMemoryTmdbMatchStore({TmdbMatchCache? cache})
    : _cache = cache ?? TmdbMatchCache();

  final TmdbMatchCache _cache;

  TmdbMatchCache get cache => _cache;

  @override
  TmdbMatchRecord? find({
    required String siteKey,
    required String vodId,
    String? sourceTitle,
  }) => _cache.findScoped(siteKey, vodId, sourceTitle);

  @override
  void putAuto({
    required String siteKey,
    required String vodId,
    required TmdbItem item,
    String? sourceTitle,
    required int matchedAt,
  }) => _cache.put(
    siteKey,
    vodId,
    item,
    sourceTitle: sourceTitle,
    matchedAt: matchedAt,
  );

  @override
  void putManual({
    required String siteKey,
    required String vodId,
    required List<String> sourceTitles,
    required TmdbItem item,
    required int matchedAt,
  }) => _cache.putManual(
    siteKey,
    vodId,
    sourceTitles,
    item,
    matchedAt: matchedAt,
  );

  @override
  void remove({required String siteKey, required String vodId}) =>
      _cache.remove(siteKey, vodId);
}

/// 匹配输入（`01` §4）。
class TmdbMatchRequest {
  const TmdbMatchRequest({
    required this.siteKey,
    required this.vodId,
    required this.sourceTitle,
    this.siteName = '',
    this.searchKeyword,
    this.vodName,
    this.vodRemarks,
    this.vodYear,
    this.expectedMediaType,
  });

  final String siteKey;
  final String vodId;
  final String sourceTitle;
  final String siteName;
  final String? searchKeyword;
  final String? vodName;
  final String? vodRemarks;
  final String? vodYear;
  final TmdbMediaType? expectedMediaType;

  /// 匹配时用于判定分季变体的源文本（`01` §5.4）。
  String get matchSourceText => [
    ?searchKeyword,
    sourceTitle,
    ?vodName,
    ?vodRemarks,
  ].join(' ');
}

/// 匹配编排结果（含诊断字段）。
class TmdbMatchOutcome {
  const TmdbMatchOutcome({
    required this.result,
    this.level,
    this.queryCount = 0,
    this.requestCount = 0,
  });

  final TmdbMatchResult result;

  /// 命中的选择级别（`strict` / `containedYear` / `smart`）。
  final String? level;

  /// 实际使用的候选查询词数量（上限 3，`01` §4）。
  final int queryCount;

  /// 实际发出的网络请求数（用于断言"未配置/禁用时零请求"）。
  final int requestCount;

  TmdbItem? get item => switch (result) {
    TmdbMatchHit(:final record) => record.toItem(),
    _ => null,
  };
}

/// 媒体身份匹配服务。
class TmdbIdentityService {
  TmdbIdentityService({
    required TmdbConfig Function() config,
    required TmdbService service,
    required TmdbMatchStore store,
    DateTime Function()? clock,
    this.maxQueries = 3,
  }) : _config = config,
       _service = service,
       _store = store,
       _clock = clock ?? DateTime.now;

  // ignore_for_file: prefer_initializing_formals
  final TmdbConfig Function() _config;
  final TmdbService _service;
  final TmdbMatchStore _store;
  final DateTime Function() _clock;

  /// 候选查询词数量上限（`01` §4）。
  final int maxQueries;

  /// 执行匹配（`01` §4）。
  ///
  /// 不抛网络异常：失败返回 `TmdbMatchMiss`。
  /// 但**鉴权失败与取消向上传播**（`01` §4 约束）。
  Future<TmdbMatchOutcome> match(TmdbMatchRequest request) async {
    final config = _config();

    // 步骤 0：前置检查（零请求）
    if (!config.isReady) {
      return const TmdbMatchOutcome(
        result: TmdbMatchDisabled(TmdbMissReason.notConfigured),
      );
    }
    if (!config.isSiteEnabled(request.siteKey, request.siteName)) {
      return const TmdbMatchOutcome(
        result: TmdbMatchDisabled(TmdbMissReason.siteDisabled),
      );
    }

    // 步骤 1：缓存查询
    final cached = _store.find(
      siteKey: request.siteKey,
      vodId: request.vodId,
      sourceTitle: request.sourceTitle,
    );
    if (cached != null) {
      // 缓存命中同样要校验分季变体防护（`01` §4 步骤 1）
      if (!cached.isManual &&
          await _isUnwantedSplitVariant(cached.toItem(), request.matchSourceText)) {
        _store.remove(siteKey: request.siteKey, vodId: request.vodId);
      } else {
        return TmdbMatchOutcome(
          result: TmdbMatchHit(cached),
          level: cached.isManual ? 'manual' : 'cache',
          requestCount: 0,
        );
      }
    }

    // 步骤 2/3：标题清洗 + 候选查询词（上限 3）
    final queries = _candidateQueries(request);

    var requests = 0;
    // 记录最后一次可恢复错误，用于区分「无候选」与「网络失败」（`01` §8）。
    AppError? lastError;
    for (final query in queries) {
      requests++;
      List<TmdbItem> results;
      try {
        results = await _service.search(query);
      } on TmdbAuthException {
        rethrow;
      } on TmdbCancelledException {
        rethrow;
      } on AppError catch (error) {
        // 未配置/站点禁用之外的可恢复错误 → 记录后继续尝试下一个查询词
        if (error.kind == AppErrorKind.tmdbNotConfigured) rethrow;
        lastError = error;
        continue;
      } catch (_) {
        continue;
      }

      // 步骤 4：过滤媒体类型
      final filtered = _filterByMediaType(results, request.expectedMediaType);
      if (filtered.isEmpty) continue;

      // 步骤 5：三级选择
      final picked = await _chooseBest(filtered, query, request);
      if (picked == null) continue;

      // 步骤 6：落盘（不覆盖手动）
      _store.putAuto(
        siteKey: request.siteKey,
        vodId: request.vodId,
        item: picked.item,
        sourceTitle: request.sourceTitle,
        matchedAt: _clock().millisecondsSinceEpoch,
      );
      return TmdbMatchOutcome(
        result: TmdbMatchHit(
          TmdbMatchRecord.fromItem(
            picked.item,
            manual: false,
            matchedAt: _clock().millisecondsSinceEpoch,
          ),
        ),
        level: picked.level,
        queryCount: queries.length,
        requestCount: requests,
      );
    }

    // 全部失败 → 区分「网络失败」与「无候选」（`01` §8）
    return TmdbMatchOutcome(
      result: lastError == null
          ? const TmdbMatchMiss(TmdbMissReason.noCandidates)
          : TmdbMatchMiss(
              TmdbMissReason.networkFailure,
              detail: lastError.detail,
            ),
      queryCount: queries.length,
      requestCount: requests,
    );
  }

  /// 用户手动匹配（`01` §7）。
  Future<TmdbMatchOutcome> matchManual({
    required TmdbMatchRequest request,
    required TmdbItem item,
    List<String>? aliases,
  }) async {
    final config = _config();
    if (!config.isReady) {
      return const TmdbMatchOutcome(
        result: TmdbMatchDisabled(TmdbMissReason.notConfigured),
      );
    }
    if (!config.isSiteEnabled(request.siteKey, request.siteName)) {
      return const TmdbMatchOutcome(
        result: TmdbMatchDisabled(TmdbMissReason.siteDisabled),
      );
    }
    final titles = aliases ?? [
      request.sourceTitle,
      if (request.searchKeyword != null) request.searchKeyword!,
      if (request.vodName != null) request.vodName!,
    ];
    _store.putManual(
      siteKey: request.siteKey,
      vodId: request.vodId,
      sourceTitles: titles,
      item: item,
      matchedAt: _clock().millisecondsSinceEpoch,
    );
    return TmdbMatchOutcome(
      result: TmdbMatchHit(
        TmdbMatchRecord.fromItem(
          item,
          manual: true,
          manualTitles: titles
              .map(TmdbCacheKey.normalizeSourceTitle)
              .where((t) => t.isNotEmpty)
              .toList(),
          matchedAt: _clock().millisecondsSinceEpoch,
        ),
      ),
      level: 'manual',
    );
  }

  /// Provider ID 直达（`01` §7.2）。
  ///
  /// 支持 `tmdb:12345` / `movie:12345` / `tv:12345`。
  Future<TmdbItem?> resolveProviderId(String input) async {
    final text = input.trim();
    final match = RegExp(
      r'^(tmdb|movie|tv)\s*[:：]\s*(\d+)$',
      caseSensitive: false,
    ).firstMatch(text);
    if (match == null) return null;
    final kind = match.group(1)!.toLowerCase();
    final id = int.tryParse(match.group(2)!);
    if (id == null || id <= 0) return null;

    TmdbMediaType? type = switch (kind) {
      'movie' => TmdbMediaType.movie,
      'tv' => TmdbMediaType.tv,
      _ => null,
    };

    if (type == null) {
      // 类型未知：先按 tv 查，失败再按 movie 查（对齐 Jellyfin 的"分步搜索"）。
      for (final candidate in [TmdbMediaType.tv, TmdbMediaType.movie]) {
        final item = await _fetchById(candidate, id);
        if (item != null) return item;
      }
      return null;
    }
    return _fetchById(type, id);
  }

  /// 手动匹配时搜索候选（`01` §7.2）。
  Future<List<TmdbItem>> searchCandidates(String keyword) async {
    final config = _config();
    if (!config.isReady) return const [];
    try {
      final results = await _service.search(cleanTitle(keyword));
      _sortSearchResults(results, keyword, config);
      return results;
    } on TmdbAuthException {
      rethrow;
    } on TmdbCancelledException {
      rethrow;
    } catch (_) {
      return const [];
    }
  }

  /// 搜索列表排序（`01` §5.6）。
  void _sortSearchResults(
    List<TmdbItem> items,
    String keyword,
    TmdbConfig config,
  ) {
    if (items.length < 2) return;
    final sourceYearValue = firstYear(keyword);
    final preferredLanguage = preferredLanguageOf(config.language);
    final preferredCountry = preferredCountryOf(config.language);
    items.sort((a, b) {
      var compare = titleSimilarityScore(
        b.title,
        keyword,
      ).compareTo(titleSimilarityScore(a.title, keyword));
      if (compare != 0) return compare;
      compare = yearDistance(firstYear(a.subtitle), sourceYearValue).compareTo(
        yearDistance(firstYear(b.subtitle), sourceYearValue),
      );
      if (compare != 0) return compare;
      compare = localePreferenceScore(
        originalLanguage: b.originalLanguage,
        originCountry: b.originCountry,
        preferredLanguage: preferredLanguage,
        preferredCountry: preferredCountry,
      ).compareTo(
        localePreferenceScore(
          originalLanguage: a.originalLanguage,
          originCountry: a.originCountry,
          preferredLanguage: preferredLanguage,
          preferredCountry: preferredCountry,
        ),
      );
      if (compare != 0) return compare;
      return b.rating.compareTo(a.rating);
    });
  }

  // -------------------------------------------------------------------------
  // 内部
  // -------------------------------------------------------------------------

  Future<TmdbItem?> _fetchById(TmdbMediaType type, int id) async {
    try {
      final detail = await _service.detail(
        TmdbItem(tmdbId: id, mediaType: type, title: ''),
        includeRelated: false,
      );
      final config = _config();
      final title = type == TmdbMediaType.movie
          ? _string(detail['title']) ?? _string(detail['name']) ?? ''
          : _string(detail['name']) ?? _string(detail['title']) ?? '';
      if (title.isEmpty) return null;
      final vote = _double(detail['vote_average']);
      final date = type == TmdbMediaType.movie
          ? _string(detail['release_date'])
          : _string(detail['first_air_date']);
      return TmdbItem(
        tmdbId: id,
        mediaType: type,
        title: title,
        subtitle: TmdbItem.buildSubtitle(date, vote),
        overview: _string(detail['overview']),
        posterUrl: TmdbImageSelector.image(
          config.imageBase,
          _string(detail['poster_path']),
        ),
        backdropUrl: TmdbImageSelector.image(
          config.backdropBase,
          _string(detail['backdrop_path']),
        ),
        rating: vote,
        tmdbRating: vote,
        originalLanguage: _string(detail['original_language']) ?? '',
      );
    } on TmdbAuthException {
      rethrow;
    } on TmdbCancelledException {
      rethrow;
    } catch (_) {
      return null;
    }
  }

  /// 候选查询词（`01` §4 步骤 3，上限 [maxQueries]）。
  List<String> _candidateQueries(TmdbMatchRequest request) {
    final queries = <String>[];
    void add(String? raw) {
      if (queries.length >= maxQueries) return;
      final cleaned = cleanTitle(raw ?? '');
      if (cleaned.isEmpty) return;
      if (queries.contains(cleaned)) return;
      queries.add(cleaned);
    }

    add(request.searchKeyword);
    add(request.sourceTitle);
    add(request.vodName);
    add(request.vodRemarks);
    return queries;
  }

  List<TmdbItem> _filterByMediaType(
    List<TmdbItem> items,
    TmdbMediaType? expected,
  ) {
    if (expected == null) return items;
    return items.where((item) => item.mediaType == expected).toList();
  }

  /// 三级选择（`01` §5.3）+ 年份拆分重试（`01` §5.5）。
  Future<({TmdbItem item, String level})?> _chooseBest(
    List<TmdbItem> items,
    String keyword,
    TmdbMatchRequest request,
  ) async {
    final config = _config();
    final sourceYearValue = sourceYear(
      vodYear: request.vodYear,
      sourceTitle: request.sourceTitle,
      keyword: keyword,
    );
    final matchText = request.matchSourceText;

    final strict = await _chooseStrict(items, keyword, matchText, sourceYearValue);
    if (strict != null) return (item: strict, level: 'strict');

    final contained = await _chooseContainedYear(
      items,
      keyword,
      matchText,
      sourceYearValue,
    );
    if (contained != null) return (item: contained, level: 'containedYear');

    if (!config.smartMatch) return null;

    final smart = await _chooseSmart(
      items,
      keyword,
      matchText,
      sourceYearValue,
    );
    if (smart != null) return (item: smart, level: 'smart');

    // 年份拆分重试（只做一次）
    final split = splitYearQuery(
      keyword: keyword,
      sourceTitle: request.sourceTitle,
    );
    if (split == null) return null;
    List<TmdbItem> retry;
    try {
      retry = await _service.search(split.query);
    } on TmdbAuthException {
      rethrow;
    } on TmdbCancelledException {
      rethrow;
    } catch (_) {
      return null;
    }
    final filtered = _filterByMediaType(retry, request.expectedMediaType);
    if (filtered.isEmpty) return null;
    final picked = await _chooseStrict(
      filtered,
      split.query,
      matchText,
      split.year,
    );
    return picked == null ? null : (item: picked, level: 'strict');
  }

  /// 1 级：strict（`01` §5.3）。
  Future<TmdbItem?> _chooseStrict(
    List<TmdbItem> items,
    String keyword,
    String matchText,
    int sourceYearValue,
  ) async {
    final normalized = normalizeTitle(keyword);
    final season = sourceSeasonNumber(matchText);
    final matches = <TmdbItem>[];
    for (final item in items) {
      if (normalizeTitle(item.title) != normalized) continue;
      if (sourceYearValue <= 0) {
        matches.add(item);
        continue;
      }
      final itemYear = firstYear(item.subtitle);
      if (itemYear == sourceYearValue) {
        matches.add(item);
        continue;
      }
      if (await _seasonYearMatches(item, season, sourceYearValue)) {
        matches.add(item);
      }
    }
    if (matches.isEmpty) return null;

    final viable = <TmdbItem>[];
    for (final item in matches) {
      if (!await _isUnwantedSplitVariant(item, matchText)) viable.add(item);
    }
    if (viable.isEmpty) return null;
    if (viable.length == 1) return viable.first;

    // 多个候选标题相同 → 用详情分季评分裁决（分差 ≥ 200 才采纳）
    final decided = await _chooseBySplitSeasonDetails(viable, matchText);
    return decided ?? viable.first;
  }

  /// 2 级：containedYear（`01` §5.3）。
  Future<TmdbItem?> _chooseContainedYear(
    List<TmdbItem> items,
    String keyword,
    String matchText,
    int sourceYearValue,
  ) async {
    if (sourceYearValue <= 0) return null;
    final normalized = normalizeTitle(keyword);
    if (normalized.length < 4) return null;
    for (final item in items) {
      final itemYear = firstYear(item.subtitle);
      if (itemYear != sourceYearValue) continue;
      final title = normalizeTitle(removeYearFromTitle(item.title, itemYear));
      if (title.length < 4 || normalized.length < 4) continue;
      if (!title.contains(normalized) && !normalized.contains(title)) continue;
      if (await _isUnwantedSplitVariant(item, matchText)) continue;
      return item;
    }
    return null;
  }

  /// 3 级：smart（`01` §5.3）。
  Future<TmdbItem?> _chooseSmart(
    List<TmdbItem> items,
    String keyword,
    String matchText,
    int sourceYearValue,
  ) async {
    final normalized = normalizeTitle(keyword);
    TmdbItem? sameTitle;
    TmdbItem? closeYear;
    for (final item in items) {
      final title = normalizeTitle(item.title);
      if (title.isEmpty || normalized.isEmpty) continue;
      final itemYear = firstYear(item.subtitle);
      final titleMatch = title == normalized;
      final cleanedMatch =
          normalizeTitle(removeYearFromTitle(item.title, itemYear)) ==
          normalized;
      if (!titleMatch && !cleanedMatch) continue;

      if (sourceYearValue <= 0) {
        if (await _isUnwantedSplitVariant(item, matchText)) continue;
        return item;
      }
      if (itemYear == sourceYearValue) {
        if (await _isUnwantedSplitVariant(item, matchText)) continue;
        return item;
      }
      if (itemYear > 0 &&
          (itemYear - sourceYearValue).abs() <= 1 &&
          closeYear == null) {
        closeYear = item;
      }
      sameTitle ??= item;
    }
    if (closeYear != null) {
      return await _isUnwantedSplitVariant(closeYear, matchText)
          ? null
          : closeYear;
    }
    if (sourceYearValue <= 0 && sameTitle != null) {
      return await _isUnwantedSplitVariant(sameTitle, matchText)
          ? null
          : sameTitle;
    }
    return null;
  }

  /// 详情分季评分裁决（`01` §5.3）：分差 ≥ 200 才采纳。
  Future<TmdbItem?> _chooseBySplitSeasonDetails(
    List<TmdbItem> matches,
    String matchText,
  ) async {
    TmdbItem? best;
    var bestScore = -1 << 30;
    var secondScore = -1 << 30;
    for (final item in matches) {
      int score;
      try {
        final detail = await _service.detail(item, includeRelated: false);
        score = splitSeasonDetailScore(
          matchText,
          _detailTitle(detail),
        );
      } catch (_) {
        continue;
      }
      if (score > bestScore) {
        secondScore = bestScore;
        bestScore = score;
        best = item;
      } else if (score > secondScore) {
        secondScore = score;
      }
    }
    if (best == null || bestScore <= 0) return null;
    return bestScore - secondScore >= 200 ? best : null;
  }

  /// `detailTitle` = `name + original_name + title + original_title`（`01` §5.4）。
  String _detailTitle(Map<String, Object?> detail) => [
    _string(detail['name']) ?? '',
    _string(detail['original_name']) ?? '',
    _string(detail['title']) ?? '',
    _string(detail['original_title']) ?? '',
  ].join(' ');

  Future<bool> _isUnwantedSplitVariant(
    TmdbItem item,
    String matchText,
  ) async {
    try {
      final detail = await _service.detail(item, includeRelated: false);
      return isUnwantedSplitSeasonVariant(matchText, _detailTitle(detail));
    } on TmdbAuthException {
      rethrow;
    } on TmdbCancelledException {
      rethrow;
    } catch (_) {
      // 详情取不到时不做分季惩罚（保守：不因网络问题丢弃候选）
      return false;
    }
  }

  /// 分季 `air_date` 年份是否等于源年份（`01` §5.3 的 strict 分支）。
  Future<bool> _seasonYearMatches(
    TmdbItem item,
    int seasonNumber,
    int sourceYearValue,
  ) async {
    if (item.mediaType != TmdbMediaType.tv ||
        seasonNumber <= 0 ||
        sourceYearValue <= 0) {
      return false;
    }
    try {
      final detail = await _service.detail(item, includeRelated: false);
      final seasons = detail['seasons'];
      if (seasons is! List) return false;
      for (final raw in seasons) {
        if (raw is! Map) continue;
        final map = raw.cast<String, Object?>();
        if (_int(map['season_number']) != seasonNumber) continue;
        final year = firstYear(_string(map['air_date']));
        return year == sourceYearValue;
      }
      return false;
    } on TmdbAuthException {
      rethrow;
    } on TmdbCancelledException {
      rethrow;
    } catch (_) {
      return false;
    }
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

int? _int(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

double _double(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? 0;
  return 0;
}
