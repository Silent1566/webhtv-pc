/// 推荐负反馈（「不感兴趣」）集合：用户数据，可导出，不是可丢缓存。
///
/// 对齐安卓 `RecommendationFeedbackStore`：最多 200 条、保留 90 天、
/// 超期条目在读取时自动失效；命中条目在推荐结果里被过滤掉。
library;

import 'recommendation.dart';

/// 一条负反馈。
class RecommendationFeedbackEntry {
  const RecommendationFeedbackEntry({
    required this.title,
    required this.createdAtMs,
    this.year,
    this.mediaType,
  });

  final String title;
  final int? year;
  final RecommendationMediaType? mediaType;
  final int createdAtMs;

  String get key => normalizeRecommendationKey(title);

  Map<String, Object?> toJson() => {
    'title': title,
    'year': year,
    'mediaType': mediaType?.wireName,
    'createdAtMs': createdAtMs,
  };

  static RecommendationFeedbackEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final title = raw['title'];
    if (title is! String || title.trim().isEmpty) return null;
    final mediaType = raw['mediaType'];
    return RecommendationFeedbackEntry(
      title: title.trim(),
      year: raw['year'] is int ? raw['year']! as int : null,
      mediaType: mediaType is String
          ? RecommendationMediaType.parse(mediaType)
          : null,
      createdAtMs: raw['createdAtMs'] is int ? raw['createdAtMs']! as int : 0,
    );
  }
}

/// 负反馈容量与保留期。
abstract final class RecommendationFeedbackPolicy {
  static const int maxItems = 200;
  static const Duration retention = Duration(days: 90);

  static bool isExpired(int createdAtMs, DateTime now) {
    if (createdAtMs <= 0) return true;
    return now.millisecondsSinceEpoch - createdAtMs >
        retention.inMilliseconds;
  }
}

/// 负反馈集合（不可变：每次变更返回新实例，便于 UI 与导出快照）。
class RecommendationFeedbackCollection {
  const RecommendationFeedbackCollection._(this.entries);

  factory RecommendationFeedbackCollection.empty() =>
      const RecommendationFeedbackCollection._([]);

  /// 按写入顺序（旧 → 新）保存；越界时丢弃最旧的。
  final List<RecommendationFeedbackEntry> entries;

  factory RecommendationFeedbackCollection.fromJson(Object? raw) {
    final list = raw is Map ? raw['entries'] : raw;
    if (list is! List) return RecommendationFeedbackCollection.empty();
    final parsed = <RecommendationFeedbackEntry>[];
    for (final item in list) {
      final entry = RecommendationFeedbackEntry.fromJson(item);
      if (entry == null) continue;
      parsed.add(entry);
    }
    // 只做容量裁剪：过期判定需要调用方注入的「现在」，加载时不做。
    final limited = parsed.length > RecommendationFeedbackPolicy.maxItems
        ? parsed.sublist(parsed.length - RecommendationFeedbackPolicy.maxItems)
        : parsed;
    return RecommendationFeedbackCollection._(List.unmodifiable(limited));
  }

  /// 追加一条：同 key 视为重复（刷新时间），并做过期与容量裁剪。
  RecommendationFeedbackCollection add(
    RecommendationFeedbackEntry entry, {
    required DateTime now,
  }) {
    if (entry.title.trim().isEmpty) return this;
    final next = <RecommendationFeedbackEntry>[
      for (final existing in entries)
        if (existing.key != entry.key &&
            !RecommendationFeedbackPolicy.isExpired(existing.createdAtMs, now))
          existing,
      entry,
    ];
    return RecommendationFeedbackCollection._(next).trimmed(now: now);
  }

  /// 去掉过期条目并裁剪到 [RecommendationFeedbackPolicy.maxItems]。
  RecommendationFeedbackCollection trimmed({required DateTime now}) {
    final kept = <RecommendationFeedbackEntry>[
      for (final entry in entries)
        if (!RecommendationFeedbackPolicy.isExpired(entry.createdAtMs, now))
          entry,
    ];
    final limited = kept.length > RecommendationFeedbackPolicy.maxItems
        ? kept.sublist(kept.length - RecommendationFeedbackPolicy.maxItems)
        : kept;
    return RecommendationFeedbackCollection._(List.unmodifiable(limited));
  }

  /// 是否命中负反馈（片名归一化后比较；年份都已知且不同则不算命中）。
  bool matches(String title, int? year, RecommendationMediaType? mediaType) {
    final key = normalizeRecommendationKey(title);
    if (key.isEmpty) return false;
    for (final entry in entries) {
      if (entry.key != key) continue;
      if (entry.year != null && year != null && entry.year != year) continue;
      if (entry.mediaType != null &&
          mediaType != null &&
          entry.mediaType != mediaType) {
        continue;
      }
      return true;
    }
    return false;
  }

  bool matchesCard(RecommendationCard card) =>
      matches(card.title, card.year, card.mediaType);

  Map<String, Object?> toJson() => {
    'entries': [for (final entry in entries) entry.toJson()],
  };

  bool get isEmpty => entries.isEmpty;

  int get length => entries.length;
}

/// 用负反馈过滤推荐卡（保留顺序，不重排）。
List<RecommendationCard> filterRecommendationsByFeedback(
  List<RecommendationCard> cards,
  RecommendationFeedbackCollection feedback, {
  required DateTime now,
}) {
  final active = feedback.trimmed(now: now);
  return [
    for (final card in cards)
      if (!active.matchesCard(card)) card,
  ];
}
