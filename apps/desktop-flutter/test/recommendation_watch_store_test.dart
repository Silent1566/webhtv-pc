import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/core/watched_recommendation.dart';
import 'package:webhtv_pc/services/recommendation_watch_store.dart';

void main() {
  const work = RecommendationWork(
    title: '一部 剧',
    mediaType: TmdbMediaType.tv,
    year: 2024,
    tmdbId: 33,
  );

  test('marks persist, match across sources, and can be removed', () {
    final dir = Directory.systemTemp.createTempSync('watched_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/watched.json');
    final store = RecommendationWatchStore(file: file);
    addTearDown(store.dispose);
    expect(store.setWatched(work, true), isTrue);
    final reloaded = RecommendationWatchStore(file: file);
    addTearDown(reloaded.dispose);
    expect(reloaded.contains(work), isTrue);
    expect(reloaded.setWatched(work, false), isTrue);
    final cleared = RecommendationWatchStore(file: file);
    addTearDown(cleared.dispose);
    expect(cleared.contains(work), isFalse);
  });

  test('different same-title versions do not inherit the mark', () {
    final store = RecommendationWatchStore();
    addTearDown(store.dispose);
    store.setWatched(work, true);
    expect(
      store.contains(
        const RecommendationWork(
          title: '一部剧',
          mediaType: TmdbMediaType.tv,
          year: 2024,
        ),
      ),
      isTrue,
    );
    expect(
      store.contains(
        const RecommendationWork(
          title: '海外发行译名',
          mediaType: TmdbMediaType.tv,
          tmdbId: 33,
        ),
      ),
      isTrue,
    );
    expect(
      store.contains(
        const RecommendationWork(
          title: '一部剧',
          mediaType: TmdbMediaType.tv,
          year: 2025,
        ),
      ),
      isFalse,
    );
    expect(
      store.contains(
        const RecommendationWork(
          title: '一部剧',
          mediaType: TmdbMediaType.movie,
          year: 2024,
          tmdbId: 33,
        ),
      ),
      isFalse,
    );
    expect(
      store.contains(
        const RecommendationWork(
          title: '一部剧',
          mediaType: TmdbMediaType.tv,
          year: 2024,
          tmdbId: 34,
        ),
      ),
      isFalse,
    );
  });

  test('a yearless chart mark does not hide or unmark same-title versions', () {
    final store = RecommendationWatchStore();
    addTearDown(store.dispose);
    const popular = RecommendationWork(
      title: '重名作品',
      mediaType: TmdbMediaType.tv,
    );
    const first = RecommendationWork(
      title: '重名作品',
      mediaType: TmdbMediaType.tv,
      year: 2018,
      tmdbId: 44,
    );
    const second = RecommendationWork(
      title: '重名作品',
      mediaType: TmdbMediaType.tv,
      year: 2024,
      tmdbId: 55,
    );
    expect(store.setWatched(popular, true), isTrue);
    expect(store.contains(first), isFalse);
    expect(store.contains(second), isFalse);
    expect(store.setWatched(first, true), isTrue);
    expect(store.setWatched(second, true), isTrue);
    expect(store.setWatched(popular, false), isTrue);
    expect(store.contains(first), isTrue);
    expect(store.contains(second), isTrue);
    expect(store.contains(popular), isFalse);
  });

  test('failed writes do not hide the work or notify listeners', () {
    final dir = Directory.systemTemp.createTempSync('watched_error_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = RecommendationWatchStore(file: File(dir.path));
    addTearDown(store.dispose);
    var notifications = 0;
    store.addListener(() => notifications++);
    expect(store.setWatched(work, true), isFalse);
    expect(store.contains(work), isFalse);
    expect(notifications, 0);
  });
}
