/// 片名学习库：用户确认过的片名映射，可导出，最多 500 例。
///
/// 对齐安卓 `title/MediaTitleLearningStore`：上限 500 条、同站点同 vodId
/// 的确定命中给 1.0 分、相似标题才作为上下文，最多 5 条进入提示词。
/// 这是**用户数据**（不是可丢缓存）：丢了就等于把用户教过的东西清空。
library;

import 'title_resolution.dart';

/// 学习库对外同时导出决议层的数据形状（查询、命中、只读视图），
/// 这样「记录一次学习」只需要依赖本文件。
export 'title_resolution.dart'
    show TitleLearningExampleRef, TitleLearningHit, TitleMediaTypeHint, TitleQuery;

/// 一条学习例子。
class TitleLearningExample extends TitleLearningExampleRef {
  const TitleLearningExample({
    required super.rawTitle,
    required super.resolvedTitle,
    super.year,
    super.mediaType,
    this.siteKey = '',
    this.vodId = '',
    this.hitCount = 1,
    this.updatedAtMs = 0,
  });

  final String siteKey;
  final String vodId;
  final int hitCount;
  final int updatedAtMs;

  String get key =>
      '${normalizeTitleKey(rawTitle)}|${siteKey.trim().toLowerCase()}|'
      '${vodId.trim()}';

  TitleLearningExample bumped({required int updatedAtMs}) => TitleLearningExample(
    rawTitle: rawTitle,
    resolvedTitle: resolvedTitle,
    year: year,
    mediaType: mediaType,
    siteKey: siteKey,
    vodId: vodId,
    hitCount: hitCount + 1,
    updatedAtMs: updatedAtMs,
  );

  Map<String, Object?> toJson() => {
    'rawTitle': rawTitle,
    'resolvedTitle': resolvedTitle,
    'year': year,
    'mediaType': mediaType?.wireName,
    'siteKey': siteKey,
    'vodId': vodId,
    'hitCount': hitCount,
    'updatedAtMs': updatedAtMs,
  };

  static TitleLearningExample? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final rawTitle = raw['rawTitle'];
    final resolvedTitle = raw['resolvedTitle'];
    if (rawTitle is! String || rawTitle.trim().isEmpty) return null;
    if (resolvedTitle is! String || resolvedTitle.trim().isEmpty) return null;
    return TitleLearningExample(
      rawTitle: rawTitle.trim(),
      resolvedTitle: resolvedTitle.trim(),
      year: raw['year'] is int ? raw['year']! as int : null,
      mediaType: TitleMediaTypeHint.parse(raw['mediaType']),
      siteKey: raw['siteKey'] is String ? raw['siteKey']! as String : '',
      vodId: raw['vodId'] is String ? raw['vodId']! as String : '',
      hitCount: raw['hitCount'] is int && (raw['hitCount']! as int) > 0
          ? raw['hitCount']! as int
          : 1,
      updatedAtMs: raw['updatedAtMs'] is int ? raw['updatedAtMs']! as int : 0,
    );
  }
}

/// 学习库（不可变集合）。
class TitleLearningCollection {
  const TitleLearningCollection._(this.examples);

  static const int maxItems = 500;
  static const int maxContexts = 5;

  /// 按 `updatedAtMs` 降序（最近学的在前）。
  final List<TitleLearningExample> examples;

  factory TitleLearningCollection.empty() =>
      const TitleLearningCollection._([]);

  factory TitleLearningCollection.fromJson(Object? raw) {
    final list = raw is Map ? raw['examples'] : raw;
    if (list is! List) return TitleLearningCollection.empty();
    final parsed = <TitleLearningExample>[];
    for (final item in list) {
      final example = TitleLearningExample.fromJson(item);
      if (example != null) parsed.add(example);
    }
    parsed.sort((a, b) => b.updatedAtMs.compareTo(a.updatedAtMs));
    final limited = parsed.length > maxItems
        ? parsed.sublist(0, maxItems)
        : parsed;
    return TitleLearningCollection._(List.unmodifiable(limited));
  }

  /// 记录一次确认（同 key 累加命中数），并裁剪到 [maxItems]。
  TitleLearningCollection record(
    TitleQuery query,
    TitleLearningExample example, {
    required DateTime now,
  }) {
    final nextUpdatedAt = now.millisecondsSinceEpoch;
    final key = example.key;
    final next = <TitleLearningExample>[];
    var replaced = false;
    for (final existing in examples) {
      if (existing.key != key) {
        next.add(existing);
        continue;
      }
      replaced = true;
      next.add(
        TitleLearningExample(
          rawTitle: example.rawTitle,
          resolvedTitle: example.resolvedTitle,
          year: example.year ?? existing.year,
          mediaType: example.mediaType ?? existing.mediaType,
          siteKey: example.siteKey,
          vodId: example.vodId,
          hitCount: existing.hitCount + 1,
          updatedAtMs: nextUpdatedAt,
        ),
      );
    }
    if (!replaced) {
      next.add(
        TitleLearningExample(
          rawTitle: example.rawTitle,
          resolvedTitle: example.resolvedTitle,
          year: example.year,
          mediaType: example.mediaType,
          siteKey: example.siteKey,
          vodId: example.vodId,
          hitCount: example.hitCount,
          updatedAtMs: nextUpdatedAt,
        ),
      );
    }
    next.sort((a, b) => b.updatedAtMs.compareTo(a.updatedAtMs));
    final limited = next.length > maxItems
        ? next.sublist(0, maxItems)
        : next;
    return TitleLearningCollection._(List.unmodifiable(limited));
  }

  /// 查找可作为上下文的例子：分数降序，最多 [limit] 条。
  List<TitleLearningHit> find(TitleQuery query, {int limit = maxContexts}) {
    final capped = limit <= 0 ? maxContexts : limit;
    final scored = <TitleLearningHit>[];
    for (final example in examples) {
      final score = _score(query, example);
      if (score <= 0.15) continue;
      scored.add(
        TitleLearningHit(
          example: TitleLearningExampleRef(
            rawTitle: example.rawTitle,
            resolvedTitle: example.resolvedTitle,
            year: example.year,
            mediaType: example.mediaType,
          ),
          score: score,
        ),
      );
    }
    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored.length > capped ? scored.sublist(0, capped) : scored;
  }

  Map<String, Object?> toJson() => {
    'examples': [for (final example in examples) example.toJson()],
  };

  bool get isEmpty => examples.isEmpty;

  int get length => examples.length;

  static double _score(TitleQuery query, TitleLearningExample example) {
    final querySite = query.siteKey.trim().toLowerCase();
    final queryVodId = query.vodId.trim();
    if (querySite.isNotEmpty &&
        queryVodId.isNotEmpty &&
        querySite == example.siteKey.trim().toLowerCase() &&
        queryVodId == example.vodId.trim()) {
      return 1.0;
    }
    final left = normalizeTitleKey(query.rawTitle);
    final right = normalizeTitleKey(example.rawTitle);
    if (left.isEmpty || right.isEmpty) return 0;
    if (left == right) return 1.0;
    if (left.contains(right) || right.contains(left)) return 0.85;

    final leftTokens = _tokens(query.rawTitle);
    final rightTokens = _tokens(example.rawTitle);
    if (leftTokens.isEmpty || rightTokens.isEmpty) return 0;
    final shared = leftTokens.intersection(rightTokens).length;
    final union = leftTokens.union(rightTokens).length;
    if (union == 0) return 0;
    return (shared / union).clamp(0.0, 0.84);
  }

  static Set<String> _tokens(String raw) => raw
      .toLowerCase()
      .split(RegExp(r'[\s·•:：\-_/\\|｜()（）\[\]【】,，、;；.。]+'))
      .where((token) => token.isNotEmpty)
      .toSet();
}
