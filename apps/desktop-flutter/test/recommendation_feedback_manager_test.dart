import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/ai_content/recommendation_feedback.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/core/watched_recommendation.dart';
import 'package:webhtv_pc/services/ai_content/ai_content_paths.dart';
import 'package:webhtv_pc/services/ai_content/user_data_store.dart';
import 'package:webhtv_pc/services/recommendation_feedback_manager.dart';
import 'package:webhtv_pc/services/recommendation_feedback_store.dart';
import 'package:webhtv_pc/services/recommendation_watch_store.dart';

void main() {
  const watchedKind = RecommendationFeedbackKind.watched;
  const dislikedKind = RecommendationFeedbackKind.notInterested;
  final now = DateTime.utc(2026, 1, 2);
  late Directory temp;
  late File watchedFile, localFile;
  late RecommendationWatchStore watched;
  late RecommendationFeedbackStore local;
  late AiContentUserDataStore ai;
  late RecommendationFeedbackManager manager;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('feedback_manager_');
    watchedFile = File('${temp.path}/watched.json');
    localFile = File('${temp.path}/negative.json');
    watched = RecommendationWatchStore(file: watchedFile);
    local = RecommendationFeedbackStore(file: localFile, clock: () => now);
    ai = AiContentUserDataStore(
      paths: AiContentPaths(
        dataDir: '${temp.path}/data',
        cacheDir: '${temp.path}/cache',
      ),
    );
    manager = RecommendationFeedbackManager(
      watched: watched,
      feedback: local,
      aiData: ai,
      clock: () => now,
    );
  });

  tearDown(() async {
    local.dispose();
    watched.dispose();
    await temp.delete(recursive: true);
  });

  test(
    'batch removes precise watched versions and clear leaves dislikes',
    () async {
      for (final year in [2001, 2010, 2024]) {
        watched.setWatched(
          RecommendationWork(
            title: '同一片名',
            mediaType: TmdbMediaType.movie,
            year: year,
            tmdbId: year,
          ),
          true,
        );
      }
      local.block('另一部片');
      final rows = await manager.load(watchedKind);
      expect(rows, hasLength(3));
      expect(rows.map((r) => r.id).toSet(), hasLength(3));
      expect(
        await manager.remove(watchedKind, {rows.first.id, rows.last.id}),
        isTrue,
      );
      final reloaded = RecommendationWatchStore(file: watchedFile);
      addTearDown(reloaded.dispose);
      expect(reloaded.works.single.year, 2010);
      expect(await manager.clear(watchedKind), isTrue);
      expect(await manager.load(watchedKind), isEmpty);
      expect(local.blockedTitles, {'另一部片'});
    },
  );

  test(
    'lists both dislike sources and removes selected in a single operation',
    () async {
      localFile.writeAsStringSync('{"遗留片":"2026-01-01T00:00:00.000Z"}');
      final legacy = RecommendationFeedbackStore(
        file: localFile,
        clock: () => now,
      );
      addTearDown(legacy.dispose);
      manager = RecommendationFeedbackManager(
        watched: watched,
        feedback: legacy,
        aiData: ai,
        clock: () => now,
      );
      legacy.block('保留：Local 片');
      final feedback = RecommendationFeedbackCollection.empty().add(
        RecommendationFeedbackEntry(
          title: 'AI 片',
          createdAtMs: now.millisecondsSinceEpoch,
        ),
        now: now,
      );
      expect(await ai.saveFeedback(feedback), isTrue);
      watched.setWatched(
        const RecommendationWork(title: '已看作品', mediaType: TmdbMediaType.tv),
        true,
      );
      final rows = await manager.load(dislikedKind);
      expect(
        rows.map((r) => r.title),
        unorderedEquals(['遗留片', '保留：Local 片', 'AI 片']),
      );
      expect(
        await manager.remove(dislikedKind, {
          for (final row in rows)
            if (row.title != '保留：Local 片') row.id,
        }),
        isTrue,
      );
      expect((await ai.loadFeedback()).isEmpty, isTrue);
      expect(legacy.blockedTitles, {'保留local片'});
      expect(await manager.clear(dislikedKind), isTrue);
      expect(await manager.load(dislikedKind), isEmpty);
      expect(watched.works.single.title, '已看作品');
    },
  );

  test(
    'dislike deletion reports partial failure without dropping unsaved rows',
    () async {
      local.block('本地片');
      expect(
        await ai.saveFeedback(
          RecommendationFeedbackCollection.empty().add(
            RecommendationFeedbackEntry(
              title: 'AI 片',
              createdAtMs: now.millisecondsSinceEpoch,
            ),
            now: now,
          ),
        ),
        isTrue,
      );
      Directory('${localFile.path}.tmp').createSync();
      expect(await manager.clear(dislikedKind), isFalse);
      expect((await manager.load(dislikedKind)).map((r) => r.title), ['本地片']);
    },
  );
}
