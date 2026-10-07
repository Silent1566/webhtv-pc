/// TMDB 元数据应用（`docs/phase4/design/04` §3.2、`02` §9）。
///
/// 两件事：
/// 1. **头部补位**：把 TMDB 元数据写入 `Vod`，严格遵守「仅补位不覆盖」（`04` §3.2）；
/// 2. **剧集元数据应用**：把 TMDB 集数标题应用到来源剧集，且**未知季度不应用**
///    （`02` §9.1 的硬约束）。
///
/// 关键契约：
/// - 来源已有非空字段**一律不改**（`04` §3.2）；
/// - 未知季度**不应用**剧集元数据（`02` §9.1）；
/// - 应用前必须校验代数与季集数快照（`02` §9.2）。
///
/// `Vod` / `VodEpisode` 在 `lib/core/protocol.dart` 中是**不可变**的，
/// 因此本服务返回新对象而不是就地修改。
library;

import '../core/protocol.dart';
import '../core/tmdb_config.dart';
import '../core/tmdb_identity.dart';
import '../core/tmdb_media.dart';
import '../core/tmdb_season.dart';
import '../core/tmdb_title.dart';
import 'tmdb_service.dart';

/// 头部补位结果（便于断言"哪些字段被补了"）。
class TmdbEnrichmentResult {
  const TmdbEnrichmentResult({
    required this.vod,
    this.applied = const {},
    this.skipped = const {},
  });

  /// 补位后的 `Vod`（未变更时与输入等价）。
  final Vod vod;

  /// 被补位的字段名。
  final Set<String> applied;

  /// 因来源已有值而跳过的字段名。
  final Set<String> skipped;

  bool get isEmpty => applied.isEmpty;

  bool get hasChanges => applied.isNotEmpty;
}

/// 一个剧集元数据应用请求。
class TmdbEpisodeEnrichment {
  const TmdbEpisodeEnrichment({
    required this.seasonNumber,
    required this.tmdbEpisodes,
    required this.generation,
    required this.metadataGeneration,
    this.seasonEpisodeCount,
  });

  /// 目标季度（**必须 >= 0**，未知季度由调用方直接跳过）。
  final int seasonNumber;
  final List<TmdbEpisode> tmdbEpisodes;

  /// 当前请求代数与元数据代数（防迟到响应，`02` §9.2）。
  final int generation;
  final int metadataGeneration;

  /// 该季 TMDB 集数（用于快照校验）。
  final int? seasonEpisodeCount;
}

/// 剧集元数据应用结果。
class TmdbEpisodeEnrichmentResult {
  const TmdbEpisodeEnrichmentResult({
    required this.line,
    required this.changed,
    required this.appliedCount,
    this.rejectedReason,
  });

  /// 应用后的线路（未应用时与输入等价）。
  final VodPlayLine line;

  final bool changed;
  final int appliedCount;

  /// 被拒绝的原因（`null` 表示已应用）。
  final String? rejectedReason;
}

/// 元数据应用服务。
class TmdbEnrichmentService {
  TmdbEnrichmentService({
    required TmdbService service,
    required TmdbConfig Function() config,
  }) : _service = service,
       _config = config;

  // ignore_for_file: prefer_initializing_formals
  final TmdbService _service;

  /// 配置访问（供语言相关的元数据挑选使用）。
  final TmdbConfig Function() _config;

  /// 当前 TMDB 配置（只读）。
  TmdbConfig get config => _config();

  /// 头部补位（`04` §3.2）。
  ///
  /// 严格遵守「仅补位不覆盖」：来源已有非空字段一律不改。
  TmdbEnrichmentResult enrichVod({
    required Vod vod,
    required TmdbItem item,
    Map<String, Object?>? detail,
    String? sourceTitle,
  }) {
    final applied = <String>{};
    final skipped = <String>{};
    final extra = Map<String, Object?>.from(vod.extra);

    // 1. 标题（唯一例外：来源标题已含明确季度时保留来源标题，`01` §3.1）
    var vodName = vod.vodName;
    final title = item.title.trim();
    if (title.isNotEmpty) {
      final effectiveSource = sourceTitle ?? vod.vodName;
      final next = sourceAwareTitle(effectiveSource, item, title);
      if (next != vodName) {
        vodName = next;
        applied.add('vodName');
      } else {
        skipped.add('vodName');
      }
    } else {
      skipped.add('vodName');
    }

    // 2. 简介：仅当 TMDB 翻译简介**更长**时替换
    var vodContent = vod.vodContent;
    final overview = detail == null ? null : _service.translatedOverview(detail);
    if (overview != null && overview.trim().isNotEmpty) {
      final current = vodContent ?? '';
      if (overview.length > current.length) {
        vodContent = overview;
        applied.add('vodContent');
      } else {
        skipped.add('vodContent');
      }
    } else {
      skipped.add('vodContent');
    }

    // 3. 海报：仅当来源为空时补位
    var vodPic = vod.vodPic;
    final poster = item.posterUrl;
    if ((vodPic ?? '').isEmpty && poster != null && poster.isNotEmpty) {
      vodPic = poster;
      applied.add('vodPic');
    } else {
      skipped.add('vodPic');
    }

    // 4. 年份
    var vodYear = vod.vodYear;
    if ((vodYear ?? '').isEmpty && detail != null) {
      final year = firstYear(
        _string(detail['first_air_date']) ?? _string(detail['release_date']),
      );
      if (year > 0) {
        vodYear = '$year';
        applied.add('vodYear');
      } else {
        skipped.add('vodYear');
      }
    } else {
      skipped.add('vodYear');
    }

    // 5. 地区
    var vodArea = vod.vodArea;
    if ((vodArea ?? '').isEmpty && detail != null) {
      final area = _productionArea(detail);
      if (area.isNotEmpty) {
        vodArea = area;
        applied.add('vodArea');
      } else {
        skipped.add('vodArea');
      }
    } else {
      skipped.add('vodArea');
    }

    // 6. 类型（`Vod` 没有 typeName 字段，用 extra 承载）
    if (detail != null) {
      final genres = _genresText(detail);
      if (genres.isNotEmpty && !extra.containsKey('type_name')) {
        extra['type_name'] = genres;
        applied.add('typeName');
      } else {
        skipped.add('typeName');
      }
    } else {
      skipped.add('typeName');
    }

    // 7. 演员（最多 5 位）
    var vodActor = vod.vodActor;
    if ((vodActor ?? '').isEmpty && detail != null) {
      final names = _service
          .cast(detail)
          .map((person) => person.name)
          .where((name) => name.isNotEmpty)
          .take(5)
          .toList();
      if (names.isNotEmpty) {
        vodActor = names.join(' / ');
        applied.add('vodActor');
      } else {
        skipped.add('vodActor');
      }
    } else {
      skipped.add('vodActor');
    }

    // 8. 导演/主创（最多 5 位）
    var vodDirector = vod.vodDirector;
    if ((vodDirector ?? '').isEmpty && detail != null) {
      final names = _service
          .creators(detail)
          .map((person) => person.name)
          .where((name) => name.isNotEmpty)
          .take(5)
          .toList();
      if (names.isNotEmpty) {
        vodDirector = names.join(' / ');
        applied.add('vodDirector');
      } else {
        skipped.add('vodDirector');
      }
    } else {
      skipped.add('vodDirector');
    }

    return TmdbEnrichmentResult(
      vod: Vod(
        vodId: vod.vodId,
        vodName: vodName,
        vodPic: vodPic,
        vodRemarks: vod.vodRemarks,
        vodContent: vodContent,
        vodArea: vodArea,
        vodYear: vodYear,
        vodDirector: vodDirector,
        vodActor: vodActor,
        vodPlayFrom: vod.vodPlayFrom,
        vodPlayUrl: vod.vodPlayUrl,
        extra: extra,
      ),
      applied: applied,
      skipped: skipped,
    );
  }

  /// 评分文案（`04` §3.2）。
  ///
  /// PC 端 `douban` 恒为 0，因此实际只显示 TMDB 一侧；四种分支保留以兼容未来扩展。
  static String ratingText({
    required double tmdbRating,
    double doubanRating = 0,
    bool matched = true,
  }) {
    final tmdb = tmdbRating > 0 ? 'TMDB ${tmdbRating.toStringAsFixed(1)}' : '';
    final douban = doubanRating > 0
        ? '豆瓣 ${doubanRating.toStringAsFixed(1)}'
        : '';
    if (tmdb.isNotEmpty && douban.isNotEmpty) return '$tmdb · $douban';
    if (tmdb.isNotEmpty) return tmdb;
    if (douban.isNotEmpty) return douban;
    return matched ? 'TMDB — · 豆瓣 —' : '';
  }

  /// 剧集元数据应用（`02` §9）。
  ///
  /// **未知季度不应用**：`seasonNumber < 0` 时直接返回未变更。
  TmdbEpisodeEnrichmentResult applyEpisodeMetadata({
    required VodPlayLine line,
    required TmdbEpisodeEnrichment request,
    required int currentGeneration,
    required int currentMetadataGeneration,
  }) {
    // 1. 未知季度 → 不应用（`02` §9.1 硬约束）
    if (request.seasonNumber < 0) {
      return TmdbEpisodeEnrichmentResult(
        line: line,
        changed: false,
        appliedCount: 0,
        rejectedReason: 'unknown_season',
      );
    }

    // 2. 代数校验（防迟到响应，`02` §9.2）
    if (request.generation != currentGeneration ||
        request.metadataGeneration != currentMetadataGeneration) {
      return TmdbEpisodeEnrichmentResult(
        line: line,
        changed: false,
        appliedCount: 0,
        rejectedReason: 'stale_generation',
      );
    }

    // 3. 季集数快照校验（`02` §9.2）
    final expectedCount = request.seasonEpisodeCount;
    if (expectedCount != null && expectedCount != request.tmdbEpisodes.length) {
      return TmdbEpisodeEnrichmentResult(
        line: line,
        changed: false,
        appliedCount: 0,
        rejectedReason: 'season_count_changed',
      );
    }

    if (request.tmdbEpisodes.isEmpty || line.episodes.isEmpty) {
      return TmdbEpisodeEnrichmentResult(
        line: line,
        changed: false,
        appliedCount: 0,
        rejectedReason: 'no_metadata',
      );
    }

    // 4. 集号对齐（`02` §9.3）
    final usePosition = shouldUseEpisodePosition(
      line.episodes.map((e) => e.name).toList(),
      request.tmdbEpisodes,
    );
    final byNumber = <int, TmdbEpisode>{
      for (final episode in request.tmdbEpisodes) episode.number: episode,
    };

    var changed = false;
    var applied = 0;
    final episodes = <VodEpisode>[];
    for (var index = 0; index < line.episodes.length; index++) {
      final source = line.episodes[index];
      final number = resolveEpisodeNumber(
        episodeName: source.name,
        position: index,
        usePosition: usePosition,
      );
      final metadata = byNumber[number];
      if (metadata == null) {
        episodes.add(source);
        continue;
      }
      final next = _applyToEpisode(source, metadata, request.seasonNumber);
      episodes.add(next);
      if (!identical(next, source)) {
        changed = true;
        applied++;
      }
    }
    return TmdbEpisodeEnrichmentResult(
      line: VodPlayLine(flag: line.flag, episodes: episodes),
      changed: changed,
      appliedCount: applied,
    );
  }

  /// 分段应用（`MultiSeason`，`02` §9.4）。
  ///
  /// 每段只应用本段的 TMDB 集数。
  TmdbEpisodeEnrichmentResult applySegmentedEpisodeMetadata({
    required VodPlayLine line,
    required MultiSeason scope,
    required Map<int, List<TmdbEpisode>> episodesBySeason,
    required int generation,
    required int metadataGeneration,
    required int currentGeneration,
    required int currentMetadataGeneration,
  }) {
    if (generation != currentGeneration ||
        metadataGeneration != currentMetadataGeneration) {
      return TmdbEpisodeEnrichmentResult(
        line: line,
        changed: false,
        appliedCount: 0,
        rejectedReason: 'stale_generation',
      );
    }
    var changed = false;
    var applied = 0;
    final episodes = List<VodEpisode>.from(line.episodes);
    for (final segment in scope.segments) {
      final metadata = episodesBySeason[segment.seasonNumber];
      if (metadata == null || metadata.isEmpty) continue;
      final start = segment.sourceEpisodeStartIndex;
      final end = segment.sourceEpisodeEndIndex;
      if (start < 0 || end >= episodes.length) continue;
      final byNumber = <int, TmdbEpisode>{
        for (final episode in metadata) episode.number: episode,
      };
      for (var index = start; index <= end; index++) {
        final source = episodes[index];
        // 段内按相对位置映射到 TMDB 集号
        final relative = index - start;
        final tmdbNumber = segment.tmdbEpisodeStartNumber + relative;
        final meta = byNumber[tmdbNumber];
        if (meta == null) continue;
        final next = _applyToEpisode(source, meta, segment.seasonNumber);
        if (!identical(next, source)) {
          episodes[index] = next;
          changed = true;
          applied++;
        }
      }
    }
    return TmdbEpisodeEnrichmentResult(
      line: VodPlayLine(flag: line.flag, episodes: episodes),
      changed: changed,
      appliedCount: applied,
    );
  }

  /// 清除线路上的 TMDB 元数据（保留原始剧集名）。
  static VodPlayLine clearEpisodeMetadata(VodPlayLine line) => VodPlayLine(
    flag: line.flag,
    episodes: line.episodes
        .map(
          (episode) => VodEpisode(
            name: episode.name,
            url: episode.url,
          ),
        )
        .toList(),
  );

  /// 把 TMDB 集信息写入 `VodEpisode.extra`，返回新对象。
  VodEpisode _applyToEpisode(
    VodEpisode episode,
    TmdbEpisode metadata,
    int seasonNumber,
  ) {
    final displayName = metadata.displayTitle;
    final previous = episode.extra['display_name'];
    final previousSeason = episode.extra['tmdb_season_number'];
    final previousNumber = episode.extra['tmdb_episode_number'];
    if (previous == displayName &&
        previousSeason == seasonNumber &&
        previousNumber == metadata.number) {
      return episode;
    }
    final extra = Map<String, Object?>.from(episode.extra)
      ..['display_name'] = displayName
      ..['tmdb_season_number'] = seasonNumber
      ..['tmdb_episode_number'] = metadata.number
      ..['tmdb_episode'] = metadata;
    return VodEpisode(name: episode.name, url: episode.url, extra: extra);
  }
}

/// `sourceAwareTitle`（`01` §3.1）：来源标题已含明确季度时保留来源标题。
String sourceAwareTitle(String sourceTitle, TmdbItem item, String tmdbTitle) {
  if (item.isTv && sourceSeasonNumber(sourceTitle) >= 0) return sourceTitle;
  return tmdbTitle;
}

/// `shouldUseEpisodePosition`（`02` §9.3）：
/// 来源集号存在重复、缺失或越界时按原始顺序对齐；否则按集号对齐。
bool shouldUseEpisodePosition(
  List<String> sourceEpisodeNames,
  List<TmdbEpisode> tmdbEpisodes,
) {
  if (sourceEpisodeNames.isEmpty || tmdbEpisodes.isEmpty) return true;
  final numbers = <int>[];
  for (final name in sourceEpisodeNames) {
    numbers.add(episodeNumberFromName(name));
  }
  // 任一集号缺失 → 按位
  if (numbers.any((n) => n <= 0)) return true;
  // 有重复 → 按位
  if (numbers.toSet().length != numbers.length) return true;
  // 越界 → 按位
  final maxTmdb = tmdbEpisodes
      .map((e) => e.number)
      .fold<int>(0, (a, b) => a > b ? a : b);
  if (numbers.any((n) => n > maxTmdb)) return true;
  return false;
}

/// `resolveEpisodeNumber`（`02` §9.3）：按位或按号取 TMDB 集号。
int resolveEpisodeNumber({
  required String episodeName,
  required int position,
  required bool usePosition,
}) => usePosition ? position + 1 : episodeNumberFromName(episodeName);

/// 从剧集名解析集号（`01` §3.5 的集数形态）。无法解析返回 `-1`。
int episodeNumberFromName(String name) {
  final text = name.trim();
  if (text.isEmpty) return -1;
  final patterns = <RegExp>[
    RegExp(r'[Ss]\d{1,2}[-._\s]*[Ee](\d{1,3})'),
    RegExp(r'第\s*([0-9零〇一二三四五六七八九十两百]+)\s*[集话話回期章节節]'),
    RegExp(r'\b(?:EP|E|Episode)\s*0*(\d{1,5})\b', caseSensitive: false),
  ];
  for (final pattern in patterns) {
    final match = pattern.firstMatch(text);
    if (match == null) continue;
    final number = parseChineseNumber(match.group(1)!);
    if (number != null && number > 0) return number;
  }
  // 纯数字（如 "01" / "12"）
  final plain = RegExp(r'^0*(\d{1,4})$').firstMatch(text);
  if (plain != null) {
    final number = int.tryParse(plain.group(1)!);
    if (number != null && number > 0) return number;
  }
  return -1;
}

/// 供上层复用：从详情对象取类型名拼接。
String _genresText(Map<String, Object?> detail) {
  final genres = detail['genres'];
  if (genres is! List) return '';
  final names = <String>[];
  for (final raw in genres) {
    if (raw is! Map) continue;
    final name = raw['name'];
    if (name is String && name.trim().isNotEmpty) names.add(name.trim());
  }
  return names.join(' / ');
}

/// 供上层复用：从详情对象取制片地区。
String _productionArea(Map<String, Object?> detail) {
  final countries = detail['production_countries'];
  if (countries is List) {
    final names = <String>[];
    for (final raw in countries) {
      if (raw is! Map) continue;
      final name = raw['name'];
      if (name is String && name.trim().isNotEmpty) names.add(name.trim());
    }
    if (names.isNotEmpty) return names.join(' / ');
  }
  final origin = detail['origin_country'];
  if (origin is List) {
    return origin.whereType<String>().join(' / ');
  }
  return '';
}

String? _string(Object? value) {
  if (value == null) return null;
  if (value is String) return value;
  return value.toString();
}
