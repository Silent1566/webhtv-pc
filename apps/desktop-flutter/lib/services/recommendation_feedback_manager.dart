import 'dart:convert';

import '../core/ai_content/recommendation_feedback.dart';
import '../core/tmdb_identity.dart';
import '../core/watched_recommendation.dart';
import 'ai_content/user_data_store.dart';
import 'recommendation_feedback_store.dart';
import 'recommendation_watch_store.dart';

enum RecommendationFeedbackKind { watched, notInterested }

class RecommendationFeedbackRecord {
  const RecommendationFeedbackRecord({
    required this.id,
    required this.title,
    required this.subtitle,
  });

  final String id, title, subtitle;
}

class RecommendationFeedbackManager {
  RecommendationFeedbackManager({
    required this._watched,
    required this._feedback,
    required this._aiData,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final RecommendationWatchStore _watched;
  final RecommendationFeedbackStore _feedback;
  final AiContentUserDataStore _aiData;
  final DateTime Function() _clock;

  static String _watchedId(RecommendationWork work) =>
      jsonEncode(work.toJson());

  Future<List<RecommendationFeedbackRecord>> load(
    RecommendationFeedbackKind kind,
  ) async {
    if (kind == RecommendationFeedbackKind.watched) {
      return [
        for (final work in _watched.works)
          RecommendationFeedbackRecord(
            id: _watchedId(work),
            title: work.title,
            subtitle: [
              if (work.year != null) work.year.toString(),
              work.mediaType == TmdbMediaType.tv ? '剧集' : '电影',
            ].join(' · '),
          ),
      ];
    }
    final ai = (await _aiData.loadFeedback()).trimmed(now: _clock());
    final entries = [
      for (final entry in _feedback.entries)
        (
          time: entry.createdAt.millisecondsSinceEpoch,
          record: RecommendationFeedbackRecord(
            id: 'local:${entry.key}',
            title: entry.title,
            subtitle: '首页／详情推荐',
          ),
        ),
      for (final entry in ai.entries)
        (
          time: entry.createdAtMs,
          record: RecommendationFeedbackRecord(
            id: 'ai:${entry.key}',
            title: entry.title,
            subtitle: [
              'AI 推荐',
              if (entry.year != null) entry.year.toString(),
              if (entry.mediaType != null) entry.mediaType!.label,
            ].join(' · '),
          ),
        ),
    ]..sort((a, b) => b.time.compareTo(a.time));
    final seen = <String>{};
    return [
      for (final entry in entries)
        if (seen.add(entry.record.id)) entry.record,
    ];
  }

  /// False means at least one store could not be updated; reload to reflect partial success.
  Future<bool> remove(RecommendationFeedbackKind kind, Set<String> ids) async {
    if (kind == RecommendationFeedbackKind.watched) {
      return _watched.removeWhere((work) => ids.contains(_watchedId(work)));
    }
    Set<String> keys(String prefix) => {
      for (final id in ids)
        if (id.startsWith(prefix)) id.substring(prefix.length),
    };
    final local = _feedback.removeKeys(keys('local:'));
    final aiKeys = keys('ai:');
    final ai =
        aiKeys.isEmpty ||
        await _aiData.updateFeedback(
              (feedback) => feedback.withoutKeys(aiKeys),
            ) !=
            null;
    return local && ai;
  }

  Future<bool> clear(RecommendationFeedbackKind kind) async {
    if (kind == RecommendationFeedbackKind.watched) return _watched.clear();
    final local = _feedback.clear();
    final ai = await _aiData.saveFeedback(
      RecommendationFeedbackCollection.empty(),
    );
    return local && ai;
  }
}
