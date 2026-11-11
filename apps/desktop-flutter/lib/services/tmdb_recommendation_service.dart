// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/detail_recommendation.dart';
import '../core/tmdb_identity.dart';
import '../core/tmdb_title.dart';
import 'tmdb_service.dart';

class TmdbRecommendationService {
  TmdbRecommendationService(
    this._service, {
    Directory? cacheDirectory,
    DateTime Function()? clock,
  }) : _cacheDirectory = cacheDirectory,
       _clock = clock ?? DateTime.now;

  final TmdbService _service;
  final TmdbCancellationToken _cancel = TmdbCancellationToken();
  final Directory? _cacheDirectory;
  final DateTime Function() _clock;
  final Map<String, _Pool> _memory = {};
  final Map<String, Future<_Pool>> _pending = {};
  static const _ttl = Duration(days: 7);

  void close() => _cancel.cancel();

  Future<RecommendationPage> related({
    required RecommendationSeed current,
    Map<String, Object?>? detail,
    bool sourceOnly = false,
    int offset = 0,
    int pageSize = 12,
    Set<String> blockedTitles = const {},
  }) async {
    _cancel.throwIfCancelled();
    if (sourceOnly) {
      final type =
          current.mediaType ?? TmdbMediaType.parse(detail?['media_type']);
      final entries = _firstSeen([
        ..._service.recommendationsFromDetail(
          detail ?? const {},
          fallbackMediaType: type,
        ),
        ..._service.similarFromDetail(
          detail ?? const {},
          fallbackMediaType: type,
        ),
      ], current.title);
      final identity = TmdbIdentity.of(type, current.tmdbId);
      final titleFields = type == TmdbMediaType.tv
          ? ['name', 'title']
          : ['title', 'name'];
      final canonicalTitle = titleFields
          .map((field) => detail?[field])
          .whereType<String>()
          .map((title) => title.trim())
          .firstWhere((title) => title.isNotEmpty, orElse: () => current.title);
      final blocked = {
        ...blockedTitles,
        recommendationTitleKey(current.title),
        recommendationTitleKey(canonicalTitle),
      };
      final filtered = _visible(
        entries,
        blocked,
        blockedIdentities: {if (identity != null) identity.key},
      ).take(40).toList();
      return _page(filtered, offset, pageSize, blocked);
    }
    if (!_service.config.isReady) return const RecommendationPage();
    final key = _key('related', current, const [], detail);
    final pool = await _obtain(key, () async {
      final data = await _seedData(current, detail: detail);
      return _Pool(
        entries: _rank(
          data.recommendations,
          data.similar,
          data.detail,
          current.title,
        ),
        created: _clock(),
        item: data.item,
        blockedIdentities: {
          if (data.item?.identity != null) data.item!.identity!.key,
        },
        context: _context(data.detail),
        recommendationsDone: data.recommendations.isEmpty,
        similarDone: data.similar.isEmpty,
        failed: data.failed,
      );
    });
    final blocked = {
      ...blockedTitles,
      recommendationTitleKey(current.title),
      if (pool.item != null) recommendationTitleKey(pool.item!.title),
    };
    final blockedIdentities = {
      ...pool.blockedIdentities,
      if (current.identity != null) current.identity!.key,
    };
    final target = offset.clamp(0, 1 << 30) + _size(pageSize) + 1;
    while (_visible(
              pool.entries,
              blocked,
              blockedIdentities: blockedIdentities,
            ).length <
            target &&
        pool.hasMore &&
        !pool.failed) {
      await _extend(key, pool);
    }
    return _page(
      pool.entries,
      offset,
      pageSize,
      blocked,
      hasMore: pool.hasMore && !pool.failed,
      blockedIdentities: blockedIdentities,
    );
  }

  Future<RecommendationPage> personal({
    required RecommendationSeed current,
    List<RecommendationSeed> history = const [],
    Map<String, Object?>? detail,
    int offset = 0,
    int pageSize = 12,
    Set<String> blockedTitles = const {},
  }) async {
    _cancel.throwIfCancelled();
    if (!_service.config.isReady) return const RecommendationPage();
    final blocked = {
      ...blockedTitles,
      recommendationTitleKey(current.title),
      ...history.map((s) => recommendationTitleKey(s.title)),
    };
    final seen = {recommendationTitleKey(current.title)};
    final seeds = history.where((s) {
      final title = recommendationTitleKey(s.title);
      return !s.isAudio &&
          !s.isShortDrama &&
          title.isNotEmpty &&
          !blockedTitles.contains(title) &&
          seen.add(title);
    }).toList();
    final key = _key('personal', current, seeds, detail);
    final pool = await _obtain(key, () async {
      final anchor = current.isAudio || current.isShortDrama
          ? _SeedData(null, const {}, const [], const [])
          : await _seedData(current, detail: detail);
      final historyData = <_SeedData>[];
      for (final seed in seeds) {
        _cancel.throwIfCancelled();
        historyData.add(await _seedData(seed));
      }
      final excluded = {
        recommendationTitleKey(current.title),
        ...history.map((s) => recommendationTitleKey(s.title)),
        if (anchor.item != null) recommendationTitleKey(anchor.item!.title),
        ...historyData
            .where((d) => d.item != null)
            .map((d) => recommendationTitleKey(d.item!.title)),
      };
      final historyCandidates = <_Candidate>[];
      var seedIndex = 0;
      for (var i = 0; i < historyData.length; i++) {
        final data = historyData[i];
        if (data.item == null) continue;
        final base = 92.0 - seedIndex++ * 8;
        _addCandidates(
          historyCandidates,
          data.recommendations,
          base,
          anchor.detail,
          seeds[i].title,
          excluded,
          fromHistory: true,
        );
        _addCandidates(
          historyCandidates,
          data.similar,
          base - 10,
          anchor.detail,
          seeds[i].title,
          excluded,
          fromHistory: true,
        );
      }
      final historyEntries = _rankCandidates(historyCandidates);
      final currentEntries = _rank(
        anchor.recommendations,
        anchor.similar,
        anchor.detail,
        current.title,
        blocked: excluded,
      );
      final identities = historyEntries.map((e) => e.key).toSet();
      return _Pool(
        entries: [
          ...historyEntries,
          ...currentEntries.where((e) => identities.add(e.key)),
        ],
        created: _clock(),
        blockedIdentities: {
          if (anchor.item?.identity != null) anchor.item!.identity!.key,
          for (final data in historyData)
            if (data.item?.identity != null) data.item!.identity!.key,
        },
        failed: anchor.failed || historyData.any((d) => d.failed),
      );
    });
    return _page(
      pool.entries,
      offset,
      pageSize,
      blocked,
      blockedIdentities: {
        ...pool.blockedIdentities,
        if (current.identity != null) current.identity!.key,
        for (final seed in history)
          if (seed.identity != null) seed.identity!.key,
      },
    );
  }

  Future<_SeedData> _seedData(
    RecommendationSeed seed, {
    Map<String, Object?>? detail,
  }) async {
    _cancel.throwIfCancelled();
    var failed = false;
    TmdbItem? item;
    Map<String, Object?> data = detail ?? const {};
    try {
      final resolved = await _resolve(seed, detail: detail);
      item = resolved.item;
      data = resolved.detail;
      failed = resolved.failed;
      if (item == null) return _SeedData(null, data, const [], const []);
    } on TmdbCancelledException {
      rethrow;
    } on TmdbAuthException {
      rethrow;
    } catch (_) {
      failed = true;
    }
    if (item == null) {
      return _SeedData(null, data, const [], const [], failed: failed);
    }
    Future<List<TmdbItem>> items(bool recommendations) async {
      _cancel.throwIfCancelled();
      final name = recommendations ? 'recommendations' : 'similar';
      if (data[name] is Map) {
        return recommendations
            ? _service.recommendationsFromDetail(
                data,
                fallbackMediaType: item!.mediaType,
              )
            : _service.similarFromDetail(
                data,
                fallbackMediaType: item!.mediaType,
              );
      }
      try {
        return await _service.related(
          item!,
          recommendations: recommendations,
          cancel: _cancel,
        );
      } on TmdbCancelledException {
        rethrow;
      } on TmdbAuthException {
        rethrow;
      } catch (_) {
        failed = true;
        return const [];
      }
    }

    final recommendations = await items(true);
    final similar = await items(false);
    return _SeedData(item, data, recommendations, similar, failed: failed);
  }

  Future<({TmdbItem? item, Map<String, Object?> detail, bool failed})> _resolve(
    RecommendationSeed seed, {
    Map<String, Object?>? detail,
  }) async {
    _cancel.throwIfCancelled();
    final item = await _match(seed);
    _cancel.throwIfCancelled();
    if (item == null) {
      return (item: null, detail: detail ?? const {}, failed: false);
    }
    try {
      final data = detail ?? await _service.detail(item, cancel: _cancel);
      return (item: _canonical(item, data), detail: data, failed: false);
    } on TmdbCancelledException {
      rethrow;
    } on TmdbAuthException {
      rethrow;
    } catch (_) {
      return (item: item, detail: const <String, Object?>{}, failed: true);
    }
  }

  TmdbItem _canonical(TmdbItem item, Map<String, Object?> detail) {
    final canonical = TmdbItem.fromSearchResult({
      ...detail,
      'id': item.tmdbId,
      'media_type': item.mediaType.wireName,
    });
    return canonical == null ? item : item.copyWith(title: canonical.title);
  }

  Future<TmdbItem?> _match(RecommendationSeed seed) async {
    _cancel.throwIfCancelled();
    final identity = seed.identity;
    if (identity != null) {
      return TmdbItem(
        tmdbId: identity.tmdbId,
        mediaType: identity.mediaType,
        title: seed.title,
      );
    }
    final title = cleanTitle(seed.title);
    if (title.isEmpty || seed.isAudio || seed.isShortDrama) return null;
    final year = firstYear(seed.year.isNotEmpty ? seed.year : seed.title);
    final items = (await _service.search(title, cancel: _cancel))
        .where(
          (item) =>
              (seed.mediaType == null || item.mediaType == seed.mediaType) &&
              titleSimilarityScore(item.title, title) >= 800 &&
              (year <= 0 || firstYear(item.subtitle) == year),
        )
        .toList();
    items.sort((a, b) {
      var result = titleSimilarityScore(
        b.title,
        title,
      ).compareTo(titleSimilarityScore(a.title, title));
      if (result != 0) return result;
      result =
          localePreferenceScore(
            originalLanguage: b.originalLanguage,
            originCountry: b.originCountry,
            preferredLanguage: preferredLanguageOf(_service.config.language),
            preferredCountry: preferredCountryOf(_service.config.language),
          ).compareTo(
            localePreferenceScore(
              originalLanguage: a.originalLanguage,
              originCountry: a.originCountry,
              preferredLanguage: preferredLanguageOf(_service.config.language),
              preferredCountry: preferredCountryOf(_service.config.language),
            ),
          );
      return result != 0 ? result : b.rating.compareTo(a.rating);
    });
    return items.isEmpty ? null : items.first;
  }

  Future<void> _extend(String key, _Pool pool) async {
    _cancel.throwIfCancelled();
    if (pool.extending != null) return pool.extending!;
    final future = _extendOnce(key, pool);
    pool.extending = future;
    try {
      await future;
    } finally {
      pool.extending = null;
    }
  }

  Future<void> _extendOnce(String key, _Pool pool) async {
    _cancel.throwIfCancelled();
    if (pool.item == null || !pool.hasMore) return;
    Future<List<TmdbItem>> fetch(bool recommendations) async {
      _cancel.throwIfCancelled();
      if (recommendations ? pool.recommendationsDone : pool.similarDone) {
        return const [];
      }
      try {
        final items = await _service.related(
          pool.item!,
          recommendations: recommendations,
          page: pool.nextPage,
          cancel: _cancel,
        );
        if (recommendations) {
          pool.recommendationsDone = items.isEmpty;
        } else {
          pool.similarDone = items.isEmpty;
        }
        return items;
      } on TmdbCancelledException {
        rethrow;
      } on TmdbAuthException {
        rethrow;
      } catch (_) {
        pool.failed = true;
        return const [];
      }
    }

    final rec = await fetch(true);
    final sim = await fetch(false);
    final keys = pool.entries.map((e) => e.key).toSet();
    // Rank each new network batch once; later pages never reorder delivered items.
    final added = _rank(
      rec,
      sim,
      pool.context,
      pool.item!.title,
    ).where((e) => keys.add(e.key)).toList();
    pool.entries.addAll(added);
    if (added.isEmpty) {
      pool.recommendationsDone = true;
      pool.similarDone = true;
    }
    pool.nextPage++;
    if (!pool.failed) await _save(key, pool);
    if (rec.isEmpty && sim.isEmpty) {
      pool.recommendationsDone = true;
      pool.similarDone = true;
    }
  }

  Future<_Pool> _obtain(String key, Future<_Pool> Function() load) async {
    _cancel.throwIfCancelled();
    final pending = _pending[key];
    if (pending != null) return pending;
    final future = _load(key, load);
    _pending[key] = future;
    try {
      return await future;
    } finally {
      _pending.remove(key);
    }
  }

  Future<_Pool> _load(String key, Future<_Pool> Function() load) async {
    _cancel.throwIfCancelled();
    final stale = _memory[key] ?? await _read(key);
    _cancel.throwIfCancelled();
    if (stale != null && _clock().difference(stale.created) < _ttl) {
      _memory[key] = stale;
      return stale;
    }
    final pool = await load();
    _cancel.throwIfCancelled();
    if (pool.failed && stale != null) return stale;
    if (!pool.failed) {
      _memory[key] = pool;
      await _save(key, pool);
    }
    _cancel.throwIfCancelled();
    return pool;
  }

  String _key(
    String kind,
    RecommendationSeed current,
    List<RecommendationSeed> history,
    Map<String, Object?>? detail,
  ) {
    List<Object?> seed(RecommendationSeed s) => [
      recommendationTitleKey(s.title),
      s.year,
      s.mediaType?.name,
      s.tmdbId,
      s.isAudio,
      s.isShortDrama,
    ];
    final config = _service.config;
    return jsonEncode([
      2,
      kind,
      config.apiBase,
      config.language,
      config.imageBase,
      config.backdropBase,
      seed(current),
      history.map(seed).toList(),
      detail,
    ]);
  }

  File? _file(String key) {
    final directory = _cacheDirectory;
    if (directory == null) return null;
    var hash = 2166136261;
    for (final byte in utf8.encode(key)) {
      hash = ((hash ^ byte) * 16777619) & 0xffffffff;
    }
    return File(
      '${directory.path}/tmdb-recommendation-${hash.toRadixString(16)}-${key.length}.json',
    );
  }

  Future<_Pool?> _read(String key) async {
    _cancel.throwIfCancelled();
    final file = _file(key);
    if (file == null) return null;
    try {
      final body =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      _cancel.throwIfCancelled();
      if (body['key'] != key) return null;
      final entries = (body['entries'] as List).map((raw) {
        final value = raw as Map;
        return RecommendationEntry(
          item: _decodeItem(value['item'] as Map),
          source: RecommendationSource.tmdb,
          reason: value['reason'] as String,
        );
      }).toList();
      return _Pool(
        entries: entries,
        created: DateTime.parse(body['created'] as String),
        item: body['item'] is Map ? _decodeItem(body['item'] as Map) : null,
        context: (body['context'] as Map).cast<String, Object?>(),
        recommendationsDone: body['recommendationsDone'] as bool,
        similarDone: body['similarDone'] as bool,
        nextPage: body['nextPage'] as int,
        blockedIdentities: (body['blockedIdentities'] as List? ?? const [])
            .cast<String>()
            .toSet(),
      );
    } on TmdbCancelledException {
      rethrow;
    } catch (_) {
      return null;
    }
  }

  Future<void> _save(String key, _Pool pool) async {
    _cancel.throwIfCancelled();
    final file = _file(key);
    if (file == null) return;
    try {
      await file.parent.create(recursive: true);
      _cancel.throwIfCancelled();
      await file.writeAsString(
        jsonEncode({
          'key': key,
          'created': pool.created.toIso8601String(),
          'entries': pool.entries
              .map((e) => {'item': e.item.toJson(), 'reason': e.reason})
              .toList(),
          'item': pool.item?.toJson(),
          'context': pool.context,
          'recommendationsDone': pool.recommendationsDone,
          'similarDone': pool.similarDone,
          'nextPage': pool.nextPage,
          'blockedIdentities': pool.blockedIdentities.toList(),
        }),
      );
    } on TmdbCancelledException {
      rethrow;
    } catch (_) {
      // An unwritable cache must not hide network results.
    }
    _cancel.throwIfCancelled();
  }
}

class _SeedData {
  _SeedData(
    this.item,
    this.detail,
    this.recommendations,
    this.similar, {
    this.failed = false,
  });
  final TmdbItem? item;
  final Map<String, Object?> detail;
  final List<TmdbItem> recommendations, similar;
  final bool failed;
}

class _Pool {
  _Pool({
    required this.entries,
    required this.created,
    this.item,
    this.context = const {},
    this.blockedIdentities = const {},
    this.recommendationsDone = true,
    this.similarDone = true,
    this.nextPage = 2,
    this.failed = false,
  });
  final List<RecommendationEntry> entries;
  final DateTime created;
  final TmdbItem? item;
  final Map<String, Object?> context;
  final Set<String> blockedIdentities;
  bool recommendationsDone, similarDone, failed;
  int nextPage;
  Future<void>? extending;
  bool get hasMore => item != null && (!recommendationsDone || !similarDone);
}

class _Candidate {
  _Candidate(this.entry, this.score, this.order);
  RecommendationEntry entry;
  double score;
  final int order;
}

List<RecommendationEntry> _firstSeen(List<TmdbItem> items, String title) {
  final keys = <String>{};
  return items
      .map(
        (item) => RecommendationEntry(
          item: item,
          source: RecommendationSource.tmdb,
          reason: '与《$title》相关',
        ),
      )
      .where((entry) => keys.add(entry.key))
      .toList();
}

List<RecommendationEntry> _rank(
  List<TmdbItem> rec,
  List<TmdbItem> sim,
  Map<String, Object?> context,
  String title, {
  Set<String> blocked = const {},
}) {
  final candidates = <_Candidate>[];
  _addCandidates(candidates, rec, 120, context, title, blocked);
  _addCandidates(candidates, sim, 105, context, title, blocked);
  return _rankCandidates(candidates);
}

void _addCandidates(
  List<_Candidate> candidates,
  List<TmdbItem> items,
  double base,
  Map<String, Object?> context,
  String title,
  Set<String> blocked, {
  bool fromHistory = false,
}) {
  final genres = <int>{
    for (final value
        in (context['genres'] is List ? context['genres'] as List : const []))
      if (value is Map && value['id'] is int) value['id'] as int,
  };
  final language = (context['original_language'] as String? ?? '')
      .trim()
      .toLowerCase();
  final countries = <String>{
    for (final value
        in (context['origin_country'] is List
            ? context['origin_country'] as List
            : const []))
      if (value is String) value.toUpperCase(),
    for (final value
        in (context['production_countries'] is List
            ? context['production_countries'] as List
            : const []))
      if (value is Map && value['iso_3166_1'] is String)
        (value['iso_3166_1'] as String).toUpperCase(),
  };
  for (final item in items) {
    final key = recommendationTitleKey(item.title);
    if (key.isEmpty || blocked.contains(key)) continue;
    final score =
        base +
        item.rating.clamp(0, 10) * .8 +
        item.genreIds.where(genres.contains).length * 18 +
        (language.isNotEmpty && item.originalLanguage.toLowerCase() == language
            ? 10
            : 0) +
        (countries.contains(item.originCountry.toUpperCase()) ? 8 : 0);
    candidates.add(
      _Candidate(
        RecommendationEntry(
          item: item,
          source: RecommendationSource.tmdb,
          reason: fromHistory ? '因为你看过《$title》' : '与《$title》相关',
        ),
        score,
        candidates.length,
      ),
    );
  }
}

List<RecommendationEntry> _rankCandidates(List<_Candidate> candidates) {
  final merged = <String, _Candidate>{};
  for (final candidate in candidates) {
    final old = merged[candidate.entry.key];
    if (old == null) {
      merged[candidate.entry.key] = candidate;
    } else {
      if (candidate.score > old.score) {
        old.entry = candidate.entry;
        old.score = candidate.score;
      }
      old.score += 12;
    }
  }
  final sorted = merged.values.toList()
    ..sort((a, b) {
      final score = b.score.compareTo(a.score);
      return score != 0 ? score : a.order.compareTo(b.order);
    });
  return sorted.map((c) => c.entry).toList();
}

Map<String, Object?> _context(Map<String, Object?> detail) => {
  for (final key in [
    'genres',
    'original_language',
    'origin_country',
    'production_countries',
  ])
    if (detail.containsKey(key)) key: detail[key],
};

List<RecommendationEntry> _visible(
  List<RecommendationEntry> items,
  Set<String> blocked, {
  Set<String> blockedIdentities = const {},
}) => items
    .where(
      (e) =>
          !blocked.contains(recommendationTitleKey(e.item.title)) &&
          !blockedIdentities.contains(e.item.identity?.key),
    )
    .toList();

int _size(int size) => size <= 0 ? 12 : size;

RecommendationPage _page(
  List<RecommendationEntry> entries,
  int offset,
  int size,
  Set<String> blocked, {
  bool hasMore = false,
  Set<String> blockedIdentities = const {},
}) {
  final items = _visible(
    entries,
    blocked,
    blockedIdentities: blockedIdentities,
  );
  final start = offset.clamp(0, items.length);
  final end = (start + _size(size)).clamp(start, items.length);
  return RecommendationPage(
    items: List.unmodifiable(items.sublist(start, end)),
    nextOffset: end,
    hasMore: end < items.length || hasMore,
  );
}

TmdbItem _decodeItem(Map value) {
  final identity = TmdbIdentity.from(value['mediaType'], value['tmdbId']);
  if (identity == null) {
    throw const FormatException('Invalid cached TMDB identity');
  }
  return TmdbItem(
    tmdbId: identity.tmdbId,
    mediaType: identity.mediaType,
    title: value['title'] as String,
    subtitle: value['subtitle'] as String? ?? '',
    overview: value['overview'] as String?,
    posterUrl: value['posterUrl'] as String?,
    backdropUrl: value['backdropUrl'] as String?,
    rating: (value['rating'] as num?)?.toDouble() ?? 0,
    tmdbRating: (value['tmdbRating'] as num?)?.toDouble() ?? 0,
    originalLanguage: value['originalLanguage'] as String? ?? '',
    originCountry: value['originCountry'] as String? ?? '',
    genreIds: (value['genreIds'] as List? ?? const []).cast<int>(),
  );
}
