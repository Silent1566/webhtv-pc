/// 详情页选集卡片的**集级手动匹配**纯逻辑。
///
/// 契约见 `docs/superpowers/specs/2026-11-21-episode-manual-match-design.md`：
/// - 粒度是**卡片**（[EpisodeGroup]），组内所有版本共享同一目标；
/// - 默认从锚点组起按**源顺序** +1 顺延，跨季按季集数走，季集数缺失即停；
/// - 冲突允许并存（同一目标可被多组占用），不跳号、不丢集；
/// - 锚点用 (sourceIndex, sourceName) 双锚，顺序变化后按名唯一找回，否则丢弃。
///
/// 这里不碰 IO、不碰 Flutter，也不读写 [VodEpisode.extra]——解析必须在
/// 任何绑定写回之前、对**原始线路**的组做（否则会拿已写 extra 的集自指）。
library;

import 'episode_aggregation.dart';

/// 一条手动匹配锚点：把「含有 [sourceIndex] 的那一组卡」固定到目标季集。
class EpisodeMatchAnchor {
  const EpisodeMatchAnchor({
    required this.sourceIndex,
    required this.sourceName,
    required this.seasonNumber,
    required this.episodeNumber,
    this.spread = true,
  });

  /// 锚点组内某一版本的原始线路下标（存储用的代表值）。
  final int sourceIndex;

  /// 该版本的源集名：顺序变化后靠它重定位。
  final String sourceName;

  final int seasonNumber;
  final int episodeNumber;

  /// `true` = 从此集起顺延；`false` = 仅此一集。
  final bool spread;

  EpisodeMatchAnchor copyWith({
    int? sourceIndex,
    String? sourceName,
    int? seasonNumber,
    int? episodeNumber,
    bool? spread,
  }) => EpisodeMatchAnchor(
    sourceIndex: sourceIndex ?? this.sourceIndex,
    sourceName: sourceName ?? this.sourceName,
    seasonNumber: seasonNumber ?? this.seasonNumber,
    episodeNumber: episodeNumber ?? this.episodeNumber,
    spread: spread ?? this.spread,
  );

  Map<String, Object?> toJson() => {
    'sourceIndex': sourceIndex,
    'sourceName': sourceName,
    'seasonNumber': seasonNumber,
    'episodeNumber': episodeNumber,
    'spread': spread,
  };

  static EpisodeMatchAnchor? fromJson(Object? value) {
    if (value is! Map) return null;
    final map = value.cast<Object?, Object?>();
    final sourceIndex = _asInt(map['sourceIndex']);
    final seasonNumber = _asInt(map['seasonNumber']);
    final episodeNumber = _asInt(map['episodeNumber']);
    if (sourceIndex == null || seasonNumber == null || episodeNumber == null) {
      return null;
    }
    return EpisodeMatchAnchor(
      sourceIndex: sourceIndex,
      sourceName: map['sourceName'] is String ? map['sourceName'] as String : '',
      seasonNumber: seasonNumber,
      episodeNumber: episodeNumber,
      spread: map['spread'] is bool ? map['spread'] as bool : true,
    );
  }

  static List<EpisodeMatchAnchor> listFromJson(Object? value) {
    if (value is! List) return const [];
    final anchors = <EpisodeMatchAnchor>[];
    for (final raw in value) {
      final anchor = fromJson(raw);
      if (anchor != null) anchors.add(anchor);
    }
    return anchors;
  }

  @override
  bool operator ==(Object other) =>
      other is EpisodeMatchAnchor &&
      other.sourceIndex == sourceIndex &&
      other.sourceName == sourceName &&
      other.seasonNumber == seasonNumber &&
      other.episodeNumber == episodeNumber &&
      other.spread == spread;

  @override
  int get hashCode =>
      Object.hash(sourceIndex, sourceName, seasonNumber, episodeNumber, spread);

  @override
  String toString() =>
      'EpisodeMatchAnchor($sourceIndex "$sourceName" -> S$seasonNumber'
      'E$episodeNumber${spread ? '' : ' single'})';
}

/// 一集的目标（季号 + 季内集号）。
class EpisodeMatchTarget {
  const EpisodeMatchTarget({
    required this.seasonNumber,
    required this.episodeNumber,
  });

  final int seasonNumber;
  final int episodeNumber;

  @override
  bool operator ==(Object other) =>
      other is EpisodeMatchTarget &&
      other.seasonNumber == seasonNumber &&
      other.episodeNumber == episodeNumber;

  @override
  int get hashCode => Object.hash(seasonNumber, episodeNumber);

  @override
  String toString() => 'S$seasonNumber E$episodeNumber';
}

int? _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

abstract final class EpisodeManualMatch {
  /// 判定综艺的类型集合（TMDB genres 会随配置语言本地化，中英都认）。
  static const Set<String> varietyGenres = {
    '真人秀',
    '脱口秀',
    'reality',
    'talk',
  };

  /// 把锚点铺开成逐 `sourceIndex` 的目标表。
  ///
  /// [groups] 必须是**原始线路**（未套任何绑定）的聚合组，顺序即源顺序——
  /// UI 的倒序只影响渲染，不影响这里的「下一集」。
  /// 季集数缺失（或该季集数为 0）时顺延到此为止，超出部分不绑定。
  static Map<int, EpisodeMatchTarget> resolve({
    required List<EpisodeGroup> groups,
    required List<EpisodeMatchAnchor> anchors,
    required Map<int, int> seasonEpisodeCounts,
  }) {
    final resolved = <int, EpisodeMatchTarget>{};
    if (groups.isEmpty || anchors.isEmpty) return resolved;
    final index = _GroupIndex(groups);
    // 同一组只认最后一个锚点：后写的覆盖先写的。
    final byPosition = <int, EpisodeMatchAnchor>{};
    for (final anchor in anchors) {
      if (anchor.seasonNumber < 0 || anchor.episodeNumber <= 0) continue;
      final position = index.positionOf(anchor);
      if (position == null) continue;
      byPosition[position] = anchor;
    }
    if (byPosition.isEmpty) return resolved;
    final positions = byPosition.keys.toList()..sort();
    for (var i = 0; i < positions.length; i++) {
      final start = positions[i];
      final limit = i + 1 < positions.length ? positions[i + 1] : groups.length;
      final anchor = byPosition[start]!;
      var target = EpisodeMatchTarget(
        seasonNumber: anchor.seasonNumber,
        episodeNumber: anchor.episodeNumber,
      );
      for (var position = start; position < limit; position++) {
        if (position > start) {
          if (!anchor.spread) break;
          final next = _advance(target, seasonEpisodeCounts);
          if (next == null) break;
          target = next;
        }
        for (final version in groups[position].versions) {
          resolved[version.sourceIndex] = target;
        }
      }
    }
    return resolved;
  }

  /// 顺序/集名变化后重定位锚点；救不回来的写入 [dropped]（源下标）。
  static List<EpisodeMatchAnchor> relocate({
    required List<EpisodeGroup> groups,
    required List<EpisodeMatchAnchor> anchors,
    required Set<int> dropped,
  }) {
    if (anchors.isEmpty || groups.isEmpty) return const [];
    final index = _GroupIndex(groups);
    final byPosition = <int, EpisodeMatchAnchor>{};
    for (final anchor in anchors) {
      var position = index.positionOf(anchor);
      // 原来那一组里没有同名版本 = 源列表被换过，按名字重新找。
      if (position != null &&
          !groups[position].versions.any(
            (version) => version.episode.name == anchor.sourceName,
          )) {
        position = null;
      }
      position ??= index.positionByName(anchor.sourceName);
      if (position == null) {
        dropped.add(anchor.sourceIndex);
        continue;
      }
      final group = groups[position];
      final version = group.versions.firstWhere(
        (candidate) => candidate.episode.name == anchor.sourceName,
        orElse: () => group.versions.first,
      );
      byPosition[position] = anchor.copyWith(
        sourceIndex: version.sourceIndex,
        sourceName: version.episode.name,
      );
    }
    if (byPosition.isEmpty) return const [];
    final positions = byPosition.keys.toList()..sort();
    return [for (final position in positions) byPosition[position]!];
  }

  /// 落到同一目标的所有源下标（卡面「重复」标记用）。
  static Set<int> duplicateIndexes(Map<int, EpisodeMatchTarget> targets) {
    final grouped = <EpisodeMatchTarget, List<int>>{};
    for (final entry in targets.entries) {
      (grouped[entry.value] ??= <int>[]).add(entry.key);
    }
    final duplicates = <int>{};
    for (final indexes in grouped.values) {
      if (indexes.length > 1) duplicates.addAll(indexes);
    }
    return duplicates;
  }

  static bool isVariety(List<String> genres) => genres.any(
    (genre) => varietyGenres.contains(genre.trim().toLowerCase()),
  );

  /// 集号文案：综艺是「第 3 期」，多季带季号；非综艺沿用 `S1E3` / `E3`。
  static String unitLabel({
    required bool variety,
    required int seasonNumber,
    required int episodeNumber,
    bool compact = false,
  }) {
    if (!variety) {
      return seasonNumber > 0
          ? 'S${seasonNumber}E$episodeNumber'
          : 'E$episodeNumber';
    }
    if (seasonNumber > 1) {
      return compact
          ? 'S$seasonNumber 第$episodeNumber期'
          : '第 $seasonNumber 季 第 $episodeNumber 期';
    }
    return compact ? '第$episodeNumber期' : '第 $episodeNumber 期';
  }

  /// 顺延一格：本季还有下一集就 +1，否则进下一季第 1 集；无下一季返回 null。
  static EpisodeMatchTarget? _advance(
    EpisodeMatchTarget current,
    Map<int, int> seasonEpisodeCounts,
  ) {
    final count = seasonEpisodeCounts[current.seasonNumber] ?? 0;
    if (count <= 0) return null;
    if (current.episodeNumber < count) {
      return EpisodeMatchTarget(
        seasonNumber: current.seasonNumber,
        episodeNumber: current.episodeNumber + 1,
      );
    }
    var nextSeason = 0;
    for (final entry in seasonEpisodeCounts.entries) {
      if (entry.value <= 0 || entry.key <= current.seasonNumber) continue;
      if (nextSeason == 0 || entry.key < nextSeason) nextSeason = entry.key;
    }
    if (nextSeason == 0) return null;
    return EpisodeMatchTarget(seasonNumber: nextSeason, episodeNumber: 1);
  }
}

/// 组定位索引：按源下标、按源集名（唯一才算命中）。
class _GroupIndex {
  _GroupIndex(this.groups) {
    for (var position = 0; position < groups.length; position++) {
      for (final version in groups[position].versions) {
        _byIndex[version.sourceIndex] = position;
        (_byName[version.episode.name] ??= <int>{}).add(position);
      }
    }
  }

  final List<EpisodeGroup> groups;
  final Map<int, int> _byIndex = {};
  final Map<String, Set<int>> _byName = {};

  int? positionOf(EpisodeMatchAnchor anchor) =>
      _byIndex[anchor.sourceIndex] ?? positionByName(anchor.sourceName);

  int? positionByName(String name) {
    final positions = _byName[name];
    return positions != null && positions.length == 1
        ? positions.single
        : null;
  }
}
