import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../services/tmdb_service.dart';
import '../services/tmdb_recommendation_service.dart';
import '../services/douban_recommendation_service.dart';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/detail_recommendation.dart';
import '../core/watched_recommendation.dart';
import '../services/recommendation_feedback_store.dart';
import '../services/recommendation_watch_store.dart';

/// Providers behind the bottom recommendation rows.
///
/// Two lifetimes:
/// - **page lease** ([acquire] / [release]): providers only live while at least
///   one page shows the rows. The last release closes the owned Douban client,
///   so its 750ms rate-spacing timer cannot outlive the widget tree (a pending
///   `Timer` fails `flutter_test` even when the UI already dropped the result).
/// - **final close** ([close]): drops the shared feedback store. It must survive
///   acquire/release cycles so persisted and in-memory feedback is never lost.
class DetailRecommendationDependencies {
  DetailRecommendationDependencies({
    required Map<RecommendationRow, RecommendationLoader> loaders,
    required this.feedback,
    this.history = _emptyHistory,
    this.historyChanges,
    VoidCallback? onClose,
  }) : _fixedBundle = _RecommendationBundle(loaders, null),
       watched = RecommendationWatchStore() {
    _finalClose = () {
      watched.dispose();
      onClose?.call();
    };
  }

  DetailRecommendationDependencies._leased({
    required this.feedback,
    required this.watched,
    required this.history,
    required this.historyChanges,
    required this._build,
  }) : _fixedBundle = null;

  factory DetailRecommendationDependencies.fromServices({
    required TmdbService service,
    Directory? cacheDirectory,
    File? feedbackFile,
    File? watchedFile,
    http.Client? doubanClient,
    List<RecommendationSeed> Function()? history,
    Listenable? historyChanges,
  }) {
    final feedback = RecommendationFeedbackStore(file: feedbackFile);
    final watched = RecommendationWatchStore(file: watchedFile);
    final dependencies = DetailRecommendationDependencies._leased(
      feedback: feedback,
      watched: watched,
      history: history ?? _emptyHistory,
      historyChanges: historyChanges,
      build: () {
        // Each lease owns both operation lifetimes; the shared HTTP service and
        // persistent caches remain reusable after provider cancellation.
        final tmdb = TmdbRecommendationService(
          service,
          cacheDirectory: cacheDirectory,
        );
        final douban = DoubanRecommendationService(
          client: doubanClient,
          tmdb: service,
          cacheDirectory: cacheDirectory,
        );
        return _RecommendationBundle(
          {
            RecommendationRow.related: (r) => tmdb.related(
              current: r.current,
              detail: r.detail,
              sourceOnly: r.sourceOnly,
              offset: r.offset,
              pageSize: r.pageSize,
              blockedTitles: r.blockedTitles,
            ),
            RecommendationRow.tmdb: (r) => tmdb.personal(
              current: r.current,
              history: r.history,
              detail: r.detail,
              offset: r.offset,
              pageSize: r.pageSize,
              blockedTitles: r.blockedTitles,
            ),
            RecommendationRow.douban: (r) => douban.personal(
              current: r.current,
              history: r.history,
              offset: r.offset,
              pageSize: r.pageSize,
              blockedTitles: r.blockedTitles,
            ),
          },
          () {
            tmdb.close();
            douban.close();
          },
        );
      },
    );
    dependencies._finalClose = () {
      watched.dispose();
      feedback.dispose();
    };
    return dependencies;
  }

  final _RecommendationBundle? _fixedBundle;
  final RecommendationFeedbackStore feedback;
  final RecommendationWatchStore watched;
  final List<RecommendationSeed> Function() history;
  final Listenable? historyChanges;
  _RecommendationBundle Function()? _build;
  _RecommendationBundle? _ownedBundle;
  VoidCallback? _finalClose;
  int _leases = 0;
  bool _closed = false;

  /// Loaders for the current lease (owned providers are created lazily).
  Map<RecommendationRow, RecommendationLoader> get loaders =>
      (_fixedBundle ?? (_ownedBundle ??= _build!())).loaders;

  /// True while at least one page shows the rows.
  bool get isLeased => _leases > 0;

  /// Take a page lease; owned providers stay alive until [release].
  Map<RecommendationRow, RecommendationLoader> acquire() {
    _leases++;
    _closed = false;
    return loaders;
  }

  /// Drop a page lease; the last release closes owned providers.
  void release() {
    if (_leases > 0) _leases--;
    if (_leases > 0) return;
    _ownedBundle?.close?.call();
    _ownedBundle = null;
  }

  /// Final teardown. Closes owned providers, then the shared feedback store.
  void close() {
    if (_closed) return;
    _closed = true;
    release();
    _finalClose?.call();
    _finalClose = null;
  }

  static List<RecommendationSeed> _emptyHistory() => const [];
}

class _RecommendationBundle {
  const _RecommendationBundle(this.loaders, this.close);

  final Map<RecommendationRow, RecommendationLoader> loaders;
  final VoidCallback? close;
}

enum RecommendationRow { related, tmdb, douban }

String recommendationRowKey(RecommendationRow row, RecommendationEntry entry) {
  final id = entry.doubanId?.trim();
  return row == RecommendationRow.douban && id != null && id.isNotEmpty
      ? 'douban:$id'
      : entry.key;
}

typedef RecommendationLoader = Future<RecommendationPage> Function(
  RecommendationRequest request,
);

class RecommendationRequest {
  const RecommendationRequest({
    required this.current,
    this.history = const [],
    this.detail,
    this.sourceOnly = false,
    this.embeddedRelated = false,
    this.offset = 0,
    this.pageSize = 12,
    this.blockedTitles = const {},
  });
  final RecommendationSeed current;
  final List<RecommendationSeed> history;
  final Map<String, Object?>? detail;
  final bool sourceOnly, embeddedRelated;
  final int offset, pageSize;
  final Set<String> blockedTitles;

  RecommendationRequest atOffset(int value) => RecommendationRequest(
    current: current,
    history: history,
    detail: detail,
    sourceOnly: sourceOnly,
    embeddedRelated: embeddedRelated,
    offset: value,
    pageSize: pageSize,
    blockedTitles: blockedTitles,
  );
}

/// Skip watched works without moving the provider cursor by a filtered count.
Future<RecommendationPage> loadUnwatchedRecommendationPage({
  required RecommendationLoader loader,
  required RecommendationRequest request,
  required RecommendationWatchStore? watched,
  int? Function()? visibleTarget,
  bool Function()? isCurrent,
}) async {
  final items = <RecommendationEntry>[];
  var offset = request.offset;
  var hasMore = false;
  for (var batch = 0; batch < 8; batch++) {
    final RecommendationPage page;
    try {
      page = await loader(request.atOffset(offset));
    } catch (_) {
      if (isCurrent?.call() == false) return const RecommendationPage();
      if (items.isEmpty) rethrow;
      break;
    }
    if (isCurrent?.call() == false) return const RecommendationPage();
    items.addAll(page.items);
    hasMore = page.hasMore && page.nextOffset > offset;
    offset = page.nextOffset;
    if (!hasMore || watched == null || watched.works.isEmpty) break;
    final visible = items
        .where(
          (entry) => !watched.contains(RecommendationWork.fromEntry(entry)),
        )
        .length;
    final target = visibleTarget?.call();
    if (visible >= (target ?? request.pageSize) ||
        (target == null && visible == items.length)) {
      break;
    }
  }
  return RecommendationPage(items: items, nextOffset: offset, hasMore: hasMore);
}

class RecommendationRowState {
  List<RecommendationEntry> _candidates = const [];
  List<RecommendationEntry> items = const [];
  bool loading = false, hasMore = false;
  int nextOffset = 0;
  int _refillTo = 0;
  Object? error;
}

class DetailRecommendationState extends ChangeNotifier {
  DetailRecommendationState({
    required this.loaders,
    required this.feedback,
    this.watched,
  }) {
    feedback.addListener(_filterFeedback);
    watched?.addListener(_filterWatched);
  }
  final Map<RecommendationRow, RecommendationLoader> loaders;
  final RecommendationFeedbackStore feedback;
  final RecommendationWatchStore? watched;
  final Map<RecommendationRow, RecommendationRowState> _rows = {
    for (final row in RecommendationRow.values) row: RecommendationRowState(),
  };
  RecommendationRowState row(RecommendationRow row) => _rows[row]!;
  String? _fingerprint;
  RecommendationRequest? _request;
  int _generation = 0;
  bool _disposed = false;
  Future<void> refresh({
    required RecommendationSeed current,
    List<RecommendationSeed> history = const [],
    Map<String, Object?>? detail,
    bool sourceOnly = false,
    bool embeddedRelated = false,
  }) async {
    if (_disposed) return;
    List<Object?> encode(RecommendationSeed seed) => [
      seed.title,
      seed.year,
      seed.tmdbId,
      seed.mediaType?.name,
      seed.isAudio,
      seed.isShortDrama,
    ];
    final fingerprint = jsonEncode([
      encode(current),
      history.map(encode).toList(),
      detail,
      sourceOnly,
      embeddedRelated,
    ]);
    if (_fingerprint == fingerprint) return;
    _fingerprint = fingerprint;
    _request = RecommendationRequest(
      current: current,
      history: List.unmodifiable(history),
      detail: detail,
      sourceOnly: sourceOnly,
      embeddedRelated: embeddedRelated,
    );
    final generation = ++_generation;
    for (final key in RecommendationRow.values) {
      _rows[key] = RecommendationRowState();
    }
    notifyListeners();
    await Future.wait([
      for (final key in RecommendationRow.values)
        if (!sourceOnly || key == RecommendationRow.related)
          _load(key, generation),
    ]);
  }

  Future<void> loadMore(RecommendationRow key) async {
    if (_disposed || _request == null) return;
    final state = row(key);
    if (state.loading || !state.hasMore) return;
    await _load(key, _generation);
  }

  Future<void> _load(RecommendationRow key, int generation) async {
    final loader = loaders[key];
    final request = _request;
    if (loader == null || request == null || _disposed) return;
    final state = row(key);
    state.loading = true;
    state.error = null;
    notifyListeners();
    final offset = state.nextOffset;
    try {
      final page = await loadUnwatchedRecommendationPage(
        loader: loader,
        watched: watched,
        visibleTarget: () => state.items.length < state._refillTo
            ? state._refillTo - state.items.length
            : null,
        isCurrent: () => !_disposed && generation == _generation,
        request: RecommendationRequest(
          current: request.current,
          history: request.history,
          detail: request.detail,
          sourceOnly:
              request.sourceOnly ||
              (key == RecommendationRow.related && request.embeddedRelated),
          embeddedRelated: request.embeddedRelated,
          offset: offset,
          blockedTitles: feedback.blockedTitles,
        ),
      );
      if (_disposed || generation != _generation) return;
      final keys = <String>{};
      final titles = <String>{};
      final blocked = feedback.blockedTitles;
      state._candidates = List.unmodifiable(
        [...state._candidates, ...page.items].where((entry) {
          final title = recommendationTitleKey(entry.item.title);
          return !blocked.contains(title) &&
              keys.add(recommendationRowKey(key, entry)) &&
              (key == RecommendationRow.douban &&
                      (entry.doubanId?.trim().isNotEmpty ?? false) ||
                  titles.add(title));
        }),
      );
      _projectWatched(state);
      state.nextOffset = page.nextOffset;
      state.hasMore = page.hasMore && page.nextOffset > offset;
    } catch (error) {
      if (!_disposed && generation == _generation) state.error = error;
    } finally {
      if (!_disposed && generation == _generation) {
        state.loading = false;
        state._refillTo = 0;
        notifyListeners();
      }
    }
  }

  void _filterFeedback() {
    if (_disposed) return;
    final blocked = feedback.blockedTitles;
    for (final state in _rows.values) {
      state._candidates = List.unmodifiable(
        state._candidates.where(
          (entry) =>
              !blocked.contains(recommendationTitleKey(entry.item.title)),
        ),
      );
      _projectWatched(state);
    }
    notifyListeners();
  }

  void _projectWatched(RecommendationRowState state) {
    final watched = this.watched;
    state.items = watched == null || watched.works.isEmpty
        ? state._candidates
        : List.unmodifiable(
            state._candidates.where(
              (entry) => !watched.contains(RecommendationWork.fromEntry(entry)),
            ),
          );
  }

  void _filterWatched() {
    if (_disposed) return;
    final refills = <RecommendationRow>[];
    for (final row in _rows.entries) {
      final state = row.value;
      final before = state.items.length;
      _projectWatched(state);
      if (state.items.length >= state._refillTo) state._refillTo = 0;
      if (state.items.length < before && state.hasMore) {
        if (before > state._refillTo) state._refillTo = before;
        if (!state.loading) refills.add(row.key);
      }
    }
    notifyListeners();
    for (final key in refills) {
      if (!row(key).loading) unawaited(_load(key, _generation));
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    feedback.removeListener(_filterFeedback);
    watched?.removeListener(_filterWatched);
    super.dispose();
  }
}
