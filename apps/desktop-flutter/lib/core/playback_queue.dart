import 'package:flutter/foundation.dart';

import 'app_error.dart';
import 'playback_request.dart';

class PlaybackQueueItem {
  const PlaybackQueueItem({required this.key, required this.title});

  final String key;
  final String title;
}

class PlaybackQueueSnapshot {
  PlaybackQueueSnapshot({
    required List<PlaybackQueueItem> items,
    required this.hasMore,
    this.loading = false,
    this.error,
  }) : items = List.unmodifiable(items);

  final List<PlaybackQueueItem> items;
  final bool hasMore;
  final bool loading;
  final AppError? error;
}

/// A lazy queue of file identities, not media URLs or episodes of one VOD.
/// The route that creates the queue owns its lifetime.
abstract class PlaybackQueue implements Listenable {
  PlaybackQueueSnapshot get snapshot;

  /// Append the next page; failures remain observable, never masquerading as EOF.
  Future<void> loadMore();

  /// Resolve one file into a complete request, preserving its own source identity.
  /// Check [isCurrent] before any playback/proxy side effect.
  Future<PlaybackRequest> resolve(
    String itemKey, {
    bool Function()? isCurrent,
  });
}
