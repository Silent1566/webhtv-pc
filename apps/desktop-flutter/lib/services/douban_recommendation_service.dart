import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../core/detail_recommendation.dart';
import '../core/tmdb_identity.dart';
import 'app_paths.dart';
import 'tmdb_service.dart';

/// Credential-free Douban recommendations. Failures retain any usable stale
/// response; all network requests share one serialized rate-limited queue.
class DoubanRecommendationService {
  DoubanRecommendationService({
    http.Client? client,
    TmdbService? tmdb,
    Directory? cacheDirectory,
    DateTime Function()? clock,
    Future<void> Function(Duration)? delay,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       // `tmdb` is a frozen public named parameter; a private field cannot be
       // an initializing formal here.
       // ignore: prefer_initializing_formals
       _tmdb = tmdb,
       _directory =
           cacheDirectory ??
           Directory(
             '${AppPaths.resolve().cacheDir}${Platform.pathSeparator}douban_rec',
           ),
       _clock = clock ?? DateTime.now,
       // ignore: prefer_initializing_formals
       _delay = delay;

  final http.Client _client;
  final bool _ownsClient;
  final TmdbService? _tmdb;
  final Directory _directory;
  final DateTime Function() _clock;
  final Future<void> Function(Duration)? _delay;
  Timer? _spacingTimer;
  Completer<void>? _spacingComplete;
  final _closedSignal = Completer<void>();
  final _tmdbCancel = TmdbCancellationToken();
  bool _closed = false;
  final _memory = <String, _CachedResponse>{};
  final _snapshots = <String, _CandidateSnapshot>{};
  Future<void> _queue = Future<void>.value();
  DateTime? _lastRequest, _blockedUntil;
  bool _cooldownLoaded = false;

  Future<RecommendationPage> personal({
    required RecommendationSeed current,
    List<RecommendationSeed> history = const [],
    int offset = 0,
    int pageSize = 12,
    Set<String> blockedTitles = const {},
  }) async {
    if (_closed) return const RecommendationPage();
    final start = math.max(0, offset);
    final limit = pageSize <= 0 ? 12 : pageSize;
    final excluded = <String>{
      ...blockedTitles,
      recommendationTitleKey(current.title),
      for (final seed in history) recommendationTitleKey(seed.title),
    };
    final seeds = <RecommendationSeed>[];
    final seedTitles = <String>{};
    for (final seed in [current, ...history]) {
      final key = recommendationTitleKey(seed.title);
      if (!seed.isAudio && key.isNotEmpty && seedTitles.add(key)) {
        seeds.add(seed);
      }
    }
    final related = <_Candidate>[];
    final fallback = <_Candidate>[];
    final lookedUp = <String>{};
    var historyIndex = 0;
    var loadedSeeds = 0;
    var seedLimit = math.min(seeds.length, (start ~/ limit + 1) * 8);
    // A paging session keeps one pool kind: related items or suggestion
    // fallbacks, never a mix. The kind is committed by the first page and read
    // back here so later pages neither switch kinds nor move delivered items.
    final snapshotKey = jsonEncode([
      for (final seed in seeds)
        [seed.title, seed.year, seed.mediaType?.name, seed.tmdbId],
      (excluded.toList()..sort()),
      limit,
    ]);
    final locked = _snapshot(snapshotKey)?.usesFallback;
    final wantsFallback = locked ?? false;
    List<_Candidate> pool() => locked == null
        ? (related.isEmpty ? fallback : related)
        : (wantsFallback ? fallback : related);
    List<_Candidate> ranked = [];
    while (loadedSeeds < seedLimit) {
      final seed = seeds[loadedSeeds];
      final suggestions = _subjects(
        await _request(
          Uri.https('movie.douban.com', '/j/subject_suggest', {
            'q': seed.title.trim(),
          }),
        ),
      );
      final isCurrent =
          recommendationTitleKey(seed.title) ==
          recommendationTitleKey(current.title);
      final score = isCurrent ? 110.0 : 88.0 - 7 * historyIndex;
      _add(
        fallback,
        suggestions,
        45.0 - loadedSeeds,
        '与「${seed.title}」相近的豆瓣作品',
        excluded,
      );
      // Already committed to suggestion fallbacks: skip paid related lookups.
      for (final subject
          in wantsFallback ? const <_Subject>[] : _matches(seed, suggestions)) {
        if (subject.id.isEmpty || !lookedUp.add(subject.key)) continue;
        var subjects = _subjects(await _related('movie', subject.id));
        if (subjects.isEmpty) {
          subjects = _subjects(await _related('tv', subject.id));
        }
        if (subjects.isEmpty) continue;
        _add(
          related,
          subjects,
          score,
          '因为你${isCurrent ? '正在浏览' : '看过'}「${seed.title}」',
          excluded,
        );
        break;
      }
      if (!isCurrent) historyIndex++;
      loadedSeeds++;
      if (loadedSeeds == seedLimit) {
        ranked = _rank(pool());
        if (ranked.length <= start && seedLimit < seeds.length) {
          seedLimit = math.min(seeds.length, seedLimit + 8);
        }
      }
    }
    // Commit atomically against the snapshot that actually wins: a concurrent
    // call for the same fingerprint may have committed the other pool kind
    // while this call was awaiting HTTP, so re-select the committed pool here
    // instead of appending whatever this call ranked on its own.
    final snapshot = _snapshot(snapshotKey, usesFallback: related.isEmpty)!;
    for (final candidate in _rank(snapshot.usesFallback ? fallback : related)) {
      if (snapshot.keys.add(_rowKey(candidate.entry))) {
        snapshot.items.add(candidate);
      }
    }
    ranked = snapshot.items;
    final end = math.min(ranked.length, start + limit);
    final selected = start < end ? ranked.sublist(start, end) : <_Candidate>[];
    final entries = <RecommendationEntry>[];
    final entryKeys = <String>{};
    for (final candidate in selected) {
      var entry = candidate.entry;
      if (entry.doubanRating <= 0 && entry.doubanId != null) {
        final abstract = await _request(
          Uri.https('movie.douban.com', '/j/subject_abstract', {
            'subject_id': entry.doubanId!,
          }),
        );
        final root = _map(abstract);
        final rating = _rating(_map(root['subject'] ?? root));
        if (rating > 0) {
          entry = RecommendationEntry(
            item: entry.item.copyWith(rating: rating),
            source: entry.source,
            reason: entry.reason,
            doubanId: entry.doubanId,
            doubanRating: rating,
          );
        }
      }
      entry = await _enrich(entry);
      if (_closed) return const RecommendationPage();
      if (!excluded.contains(recommendationTitleKey(entry.item.title)) &&
          entryKeys.add(_rowKey(entry))) {
        entries.add(entry);
      }
    }
    return RecommendationPage(
      items: entries,
      nextOffset: start + selected.length,
      hasMore: end < ranked.length || loadedSeeds < seeds.length,
    );
  }

  Future<Object?> _related(String type, String id) => _request(
    Uri.https('m.douban.com', '/rexxar/api/v2/$type/$id/related_items', {
      'start': '0',
      'count': '10',
    }),
    referer: 'https://m.douban.com/movie/subject/$id/',
  );

  void _add(
    List<_Candidate> pool,
    List<_Subject> subjects,
    double base,
    String reason,
    Set<String> excluded,
  ) {
    for (final subject in subjects) {
      if (excluded.contains(recommendationTitleKey(subject.title))) continue;
      final item = TmdbItem(
        tmdbId: 0,
        mediaType: subject.type,
        title: subject.title,
        subtitle: [
          if (subject.year > 0) '${subject.year}',
          if (subject.rating > 0) '豆瓣 ${subject.rating.toStringAsFixed(1)}',
        ].join(' · '),
        posterUrl: subject.poster.isEmpty ? null : subject.poster,
        rating: subject.rating,
      );
      pool.add(
        _Candidate(
          RecommendationEntry(
            item: item,
            source: RecommendationSource.douban,
            doubanId: subject.id.isEmpty ? null : subject.id,
            doubanRating: subject.rating,
            reason: reason,
          ),
          base + math.min(subject.rating, 10) * .8,
          pool.length,
        ),
      );
    }
  }

  String _rowKey(RecommendationEntry entry) {
    final id = entry.doubanId?.trim() ?? '';
    return id.isNotEmpty
        ? 'douban:$id'
        : 'title:${recommendationTitleKey(entry.item.title)}';
  }

  List<_Candidate> _rank(List<_Candidate> pool) {
    final merged = <String, _Candidate>{};
    for (final candidate in pool) {
      final key = _rowKey(candidate.entry);
      final previous = merged[key];
      if (previous == null) {
        merged[key] = _Candidate(
          candidate.entry,
          candidate.score,
          candidate.order,
        );
      } else {
        if (candidate.score > previous.score) previous.entry = candidate.entry;
        previous.score = math.max(previous.score, candidate.score) + 12;
      }
    }
    return merged.values.toList()..sort((a, b) {
      final score = b.score.compareTo(a.score);
      return score == 0 ? a.order.compareTo(b.order) : score;
    });
  }

  List<_Subject> _matches(RecommendationSeed seed, List<_Subject> subjects) {
    final year = _year(seed.year);
    final matches = subjects
        .where(
          (s) =>
              recommendationTitleKey(s.title) ==
                  recommendationTitleKey(seed.title) &&
              (seed.mediaType == null || seed.mediaType == s.type) &&
              (year == 0 || s.year == 0 || year == s.year),
        )
        .toList();
    matches.sort(
      (a, b) => (year > 0 && b.year == year ? 1 : 0).compareTo(
        year > 0 && a.year == year ? 1 : 0,
      ),
    );
    return matches;
  }

  Future<RecommendationEntry> _enrich(RecommendationEntry entry) async {
    final tmdb = _tmdb;
    if (_closed || tmdb == null || !tmdb.config.isReady) return entry;
    try {
      final results = await tmdb
          .search(entry.item.title, cancel: _tmdbCancel)
          .timeout(const Duration(seconds: 15));
      if (_closed) return entry;
      final year = _year(entry.item.subtitle);
      for (final match in results.take(20)) {
        final matchYear = _year(match.subtitle);
        if (match.identity == null ||
            match.mediaType != entry.item.mediaType ||
            recommendationTitleKey(match.title) !=
                recommendationTitleKey(entry.item.title) ||
            (year > 0 && (matchYear == 0 || matchYear != year))) {
          continue;
        }
        return RecommendationEntry(
          item: match.copyWith(
            title: entry.item.title,
            subtitle: match.subtitle.isEmpty
                ? entry.item.subtitle
                : match.subtitle,
            posterUrl: (match.posterUrl ?? '').isEmpty
                ? entry.item.posterUrl
                : match.posterUrl,
            overview: (match.overview ?? '').isEmpty
                ? entry.item.overview
                : match.overview,
            rating: match.tmdbRating > 0 ? match.tmdbRating : entry.item.rating,
          ),
          source: RecommendationSource.douban,
          reason: entry.reason,
          doubanId: entry.doubanId,
          doubanRating: entry.doubanRating,
        );
      }
    } catch (_) {
      // Enrichment is optional; the unresolved title remains searchable.
    }
    return entry;
  }

  Future<Object?> _request(
    Uri uri, {
    String referer = 'https://movie.douban.com/',
  }) {
    final result = _queue.then((_) => _requestSerial(uri, referer));
    _queue = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<Object?> _requestSerial(Uri uri, String referer) async {
    if (_closed) return null;
    final key = uri.toString();
    final cached = _read(key);
    if (cached != null &&
        !_clock().isBefore(cached.time) &&
        _clock().difference(cached.time) < const Duration(days: 7)) {
      return cached.body;
    }
    _loadCooldown();
    if (_blockedUntil?.isAfter(_clock()) ?? false) return cached?.body;
    try {
      final last = _lastRequest;
      if (last != null) {
        final wait = last
            .add(const Duration(milliseconds: 750))
            .difference(_clock());
        if (wait > Duration.zero) await _waitForSpacing(wait);
      }
      if (_closed) return null;
      _lastRequest = _clock();
      final request = _client.get(
        uri,
        headers: {
          'User-Agent': 'Mozilla/5.0 (Linux; Android 10) AppleWebKit/537.36 Chrome/120.0 Mobile Safari/537.36',
          'Referer': referer,
          'Accept': 'application/json,text/plain;q=0.9,*/*;q=0.8',
          'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
        },
      );
      final response = await Future.any<http.Response?>([
        request,
        _closedSignal.future.then((_) => null),
      ]).timeout(const Duration(seconds: 15));
      if (_closed || response == null) return null;
      if ([403, 418, 429].contains(response.statusCode) ||
          _challenge(response.body)) {
        _blockedUntil = _clock().add(const Duration(minutes: 30));
        _writeFile('request_cooldown.json', {
          'until': _blockedUntil!.millisecondsSinceEpoch,
        });
        return cached?.body;
      }
      if (response.statusCode < 200 ||
          response.statusCode >= 300 ||
          response.bodyBytes.length > 2 * 1024 * 1024) {
        return cached?.body;
      }
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      if (body is! List && body is! Map) return cached?.body;
      if (body is Map &&
          (body.containsKey('error') ||
              body.containsKey('msg') ||
              body.containsKey('message'))) {
        return cached?.body;
      }
      final saved = _CachedResponse(_clock(), body);
      _memory[key] = saved;
      _writeFile(_fileName(key), {
        'url': key,
        'time': saved.time.millisecondsSinceEpoch,
        'body': body,
      });
      return body;
    } catch (_) {
      return cached?.body;
    }
  }

  bool _challenge(String text) {
    if (!text.trimLeft().startsWith('<')) {
      try {
        final map = _map(jsonDecode(text));
        text =
            '${map['message'] ?? ''} ${map['msg'] ?? ''} ${map['error'] ?? ''}';
      } catch (_) {
        return false;
      }
    }
    return RegExp(
      r'captcha|验证码|驗證碼|异常请求|异常访问|访问过于频繁|sec\.douban\.com|检测到有异常',
      caseSensitive: false,
    ).hasMatch(text);
  }

  String _fileName(String key) =>
      'response_${md5.convert(utf8.encode(key))}.json';

  _CachedResponse? _read(String key) {
    final memory = _memory[key];
    if (memory != null) return memory;
    try {
      final file = File(
        '${_directory.path}${Platform.pathSeparator}${_fileName(key)}',
      );
      if (file.lengthSync() > 3 * 1024 * 1024) return null;
      final data = _map(jsonDecode(file.readAsStringSync()));
      final time = data['time'], body = data['body'];
      if (data['url'] != key ||
          time is! int ||
          (body is! Map && body is! List)) {
        return null;
      }
      final saved = _CachedResponse(
        DateTime.fromMillisecondsSinceEpoch(time, isUtc: true),
        body,
      );
      _memory[key] = saved;
      return saved;
    } catch (_) {
      return null;
    }
  }

  void _loadCooldown() {
    if (_cooldownLoaded) return;
    _cooldownLoaded = true;
    try {
      final data = _map(
        jsonDecode(
          File(
            '${_directory.path}${Platform.pathSeparator}request_cooldown.json',
          ).readAsStringSync(),
        ),
      );
      if (data['until'] is int) {
        _blockedUntil = DateTime.fromMillisecondsSinceEpoch(
          data['until'] as int,
          isUtc: true,
        );
      }
    } catch (_) {
      /* A missing or damaged cache is nonfatal. */
    }
  }

  void _writeFile(String name, Object data) {
    try {
      _directory.createSync(recursive: true);
      final file = File('${_directory.path}${Platform.pathSeparator}$name');
      final temporary = File('${file.path}.$pid.${identityHashCode(this)}.tmp');
      temporary.writeAsStringSync(jsonEncode(data), flush: true);
      temporary.renameSync(file.path);
    } catch (_) {
      /* Memory caching still works when disk is unavailable. */
    }
  }

  /// Live snapshot for [key]; expires after a week or on clock rollback.
  _CandidateSnapshot? _snapshot(String key, {bool? usesFallback}) {
    final existing = _snapshots[key];
    if (existing != null &&
        !_clock().isBefore(existing.created) &&
        _clock().difference(existing.created) < const Duration(days: 7)) {
      return existing;
    }
    // A null kind only looks the snapshot up; anything else commits that pool
    // kind for the pages that follow.
    if (usesFallback == null) return null;
    _snapshots.remove(key);
    final created = _CandidateSnapshot(_clock(), usesFallback);
    _snapshots[key] = created;
    if (_snapshots.length > 32) _snapshots.remove(_snapshots.keys.first);
    return created;
  }

  Future<void> _waitForSpacing(Duration duration) async {
    if (_delay != null) {
      await Future.any<void>([_delay(duration), _closedSignal.future]);
      return;
    }
    final complete = Completer<void>();
    _spacingComplete = complete;
    _spacingTimer = Timer(duration, complete.complete);
    await complete.future;
    _spacingComplete = null;
    _spacingTimer = null;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _tmdbCancel.cancel();
    _closedSignal.complete();
    _spacingTimer?.cancel();
    final complete = _spacingComplete;
    if (complete != null && !complete.isCompleted) complete.complete();
    _snapshots.clear();
    if (_ownsClient) _client.close();
  }
}

class _CachedResponse {
  const _CachedResponse(this.time, this.body);
  final DateTime time;
  final Object? body;
}

/// One committed paging session: the pool kind and delivered positions.
class _CandidateSnapshot {
  _CandidateSnapshot(this.created, this.usesFallback);
  final DateTime created;

  /// Pool kind chosen by the first batch. Locked for the snapshot lifetime so a
  /// paging sequence never mixes related items with suggestion fallbacks.
  final bool usesFallback;
  final items = <_Candidate>[];
  final keys = <String>{};
}

class _Candidate {
  _Candidate(this.entry, this.score, this.order);
  RecommendationEntry entry;
  double score;
  final int order;
}

class _Subject {
  const _Subject(
    this.id,
    this.title,
    this.type,
    this.year,
    this.poster,
    this.rating,
  );
  final String id, title, poster;
  final TmdbMediaType type;
  final int year;
  final double rating;
  String get key =>
      id.isEmpty ? 'title:${recommendationTitleKey(title)}' : 'douban:$id';
}

Map<Object?, Object?> _map(Object? value) =>
    value is Map ? value.cast<Object?, Object?>() : const {};
String _text(Map<Object?, Object?> map, List<String> keys) {
  for (final key in keys) {
    final value = map[key];
    if (value is String && value.trim().isNotEmpty) return value.trim();
    if (value is num) return value.toString();
  }
  return '';
}

int _year(String text) =>
    int.tryParse(RegExp(r'(?:19|20)\d{2}').firstMatch(text)?.group(0) ?? '') ??
    0;
double _number(Object? value) => value is num
    ? value.toDouble()
    : double.tryParse(value is String ? value : '') ?? 0;
double _rating(Map<Object?, Object?> map) {
  final nested = _map(map['rating']);
  final value = nested.isEmpty
      ? _number(map['rating'] ?? map['rate'])
      : _number(nested['value'] ?? nested['average'] ?? nested['rating']);
  return value.isFinite && value > 0 ? math.min(value, 10) : 0;
}

List<_Subject> _subjects(Object? body) {
  final root = _map(body);
  final values = <Object?>[];
  void append(Object? list) {
    if (list is List) values.addAll(list);
  }

  if (body is List) append(body);
  append(root['smart_box']);
  final subjects = root['subjects'];
  append(subjects is Map ? subjects['items'] : subjects);
  append(root['items']);
  final result = <_Subject>[];
  for (final value in values) {
    final wrapper = _map(value);
    final layout = _text(wrapper, ['layout']);
    if (layout.isNotEmpty && layout != 'subject') continue;
    final map = wrapper['target'] is Map ? _map(wrapper['target']) : wrapper;
    final title = _text(map, ['title', 'name']);
    if (recommendationTitleKey(title).isEmpty) continue;
    final rawType = _text(map, ['type', 'subtype']).toLowerCase();
    final typeText =
        (rawType.isEmpty ? _text(wrapper, ['target_type']) : rawType)
            .toLowerCase();
    if ([
      'book',
      'music',
      'person',
      'celebrity',
      'collection',
    ].contains(typeText)) {
      continue;
    }
    final labels = map['labels'];
    final moreUrl = _text(map, ['more_url']).toLowerCase();
    final tv =
        RegExp(r'tv|series|电视剧|剧集|劇集|电视').hasMatch(typeText) ||
        ['true', '1'].contains(map['is_tv']?.toString().toLowerCase()) ||
        moreUrl.contains('is_tv=1') ||
        moreUrl.contains("is_tv:'1'") ||
        moreUrl.contains('is_tv%3a%271%27') ||
        _number(map['episode'] ?? map['episodes_count']) > 0 ||
        RegExp(r'剧集|电视剧|電視劇')
            .hasMatch(_text(map, ['card_subtitle', 'sub_title'])) ||
        (labels is List &&
            labels.any(
              (v) => RegExp(r'tv|series|剧集|电视剧|劇集').hasMatch(
                v is String ? v : _text(_map(v), ['text', 'name', 'title']),
              ),
            ));
    final poster = _text(map, ['img', 'cover_url', 'cover']);
    final pic = _text(_map(map['pic']), ['large', 'normal', 'url']);
    result.add(
      _Subject(
        _text(map, ['id']),
        title,
        tv ? TmdbMediaType.tv : TmdbMediaType.movie,
        _year(
          _text(map, ['year', 'release_year', 'sub_title', 'card_subtitle']),
        ),
        (poster.isEmpty ? pic : poster).replaceAll(
          's_ratio_poster',
          'm_ratio_poster',
        ),
        _rating(map),
      ),
    );
  }
  return result;
}
