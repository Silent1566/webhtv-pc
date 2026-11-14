/// Task5 · AI 季集完整映射：应用、确认快照、持久化与身份回退。
///
/// 对照安卓合同：
/// - `AiEpisodeSeasonService`（四模式分析，映射应用在 `EpisodeSeasonPolicy`）；
/// - `EpisodeSeasonSnapshot.stableStructureFingerprint`（顺序无关的稳定指纹）；
/// - `EpisodeSeasonPolicy.mapFlatEpisodeNumber`（FLAT 按 parsedNumber 主键映射，
///   缺号不偏移、重复号同目标、越界/未知跳过）；
/// - `EpisodeSeasonPolicy.linearEpisodeNumber`（SINGLE_SEASON 保留解析集号，
///   缺号 fallback index+1）；
/// - KEEP_ORIGINAL 语义：清除此前 AI 覆写（安卓无此持久化模式，按"删除映射表
///   全行"实现）。
///
/// **确认前的快照校验**：`recognitionSnapshot` 是 AI 识别时的指纹，确认时
/// 现场指纹与它不一致 → `staleSnapshot`，**拒绝写入**。这是防"识别到确认
/// 之间源列表被换"的唯一闸门。
library;

import 'dart:convert';
import 'package:crypto/crypto.dart' as crypto;

import '../core/protocol.dart';
import 'ai_episode_season_service.dart';
import 'storage.dart';

/// 低置信度回退阈值（低于此值不写自动回退）。
const double aiIdentityFallbackMinConfidence = 0.8;

/// 一条逐集绑定。
class AiEpisodeBinding {
  const AiEpisodeBinding({
    required this.sourceIndex,
    required this.seasonNumber,
    required this.episodeNumber,
  });

  final int sourceIndex;
  final int seasonNumber;
  final int episodeNumber;

  Map<String, Object?> toJson() => {
    'sourceIndex': sourceIndex,
    'seasonNumber': seasonNumber,
    'episodeNumber': episodeNumber,
  };

  static AiEpisodeBinding? fromJson(Object? value) {
    if (value is! Map) return null;
    final map = value.cast<Object?, Object?>();
    final source = _asInt(map['sourceIndex']);
    final season = _asInt(map['seasonNumber']);
    final episode = _asInt(map['episodeNumber']);
    if (source == null || season == null || episode == null) return null;
    return AiEpisodeBinding(
      sourceIndex: source,
      seasonNumber: season,
      episodeNumber: episode,
    );
  }
}

int? _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

/// 应用状态。
enum AiSeasonApplyStatus {
  /// 成功映射全部（或 KEEP_ORIGINAL 清理完成）。
  applied,

  /// FLAT 部分集号越界/未知被跳过，其余已映射。
  partial,

  /// 校验不通过（EXPLICIT 不完整、SINGLE 超容量、分析失败）。
  rejected,

  /// 确认/读取时快照指纹与识别时不一致 → 拒绝写入或返回空。
  staleSnapshot,

  /// 无持久化绑定。
  missing,
}

/// 应用结果。
class AiSeasonApplyResult {
  const AiSeasonApplyResult({
    required this.status,
    this.bindings = const [],
    this.skippedSourceIndexes = const [],
    this.mappedCount = 0,
  });

  final AiSeasonApplyStatus status;
  final List<AiEpisodeBinding> bindings;
  final List<int> skippedSourceIndexes;
  final int mappedCount;
}

/// 读取结果（含快照判定）。
class AiSeasonBindingsResult {
  const AiSeasonBindingsResult({
    required this.status,
    this.bindings = const [],
    this.skippedSourceIndexes = const [],
    this.mappedCount = 0,
  });

  final AiSeasonApplyStatus status;
  final List<AiEpisodeBinding> bindings;
  final List<int> skippedSourceIndexes;
  final int mappedCount;
}

/// 结构指纹（对照安卓 `EpisodeSeasonSnapshot.stableStructureFingerprint`：
/// 集排序无关，比较 (集号, 名称) 多重集合；外加 seasonCounts 排序列表）。
///
/// **只表达"集集合是否变了"，不能用于逐集绑定对齐**：`AiEpisodeBinding.sourceIndex`
/// 与列表位置绑定，重排后结构指纹不变但绑定会错位。持久化/读取必须用
/// [seasonBindingsSnapshot]。
String seasonMappingSnapshot(
  List<VodEpisode> episodes,
  Map<int, int> seasonCounts,
) {
  final entries = <String>[
    for (final episode in episodes)
      '${parseEpisodeNumber(episode.name)}|${episode.name}',
  ]..sort();
  final seasons = seasonCounts.keys.toList()..sort();
  final seasonPart = [
    for (final season in seasons) '$season=${seasonCounts[season]}',
  ].join(',');
  return crypto.sha256
      .convert(utf8.encode('episodes-stable|${entries.join('\u0001')}|seasons|$seasonPart'))
      .toString();
}

/// 逐集绑定指纹（**顺序敏感**，与 `sourceIndex` 语义一致）。
///
/// 逐集映射按列表位置存 `sourceIndex`，所以 `[E1, E2] → [E2, E1]` 必须判不一致；
/// 安卓的 `stableStructureFingerprint` 只用给"手动季度绑定"判定源结构是否变化，
/// 不能借来这里做逐集对齐。
String seasonBindingsSnapshot(
  List<VodEpisode> episodes,
  Map<int, int> seasonCounts,
) {
  final entries = <String>[
    for (var index = 0; index < episodes.length; index++)
      '$index|${parseEpisodeNumber(episodes[index].name)}|${episodes[index].name}',
  ];
  final seasons = seasonCounts.keys.toList()..sort();
  final seasonPart = [
    for (final season in seasons) '$season=${seasonCounts[season]}',
  ].join(',');
  return crypto.sha256
      .convert(utf8.encode('episodes-ordered|${entries.join('\u0001')}|seasons|$seasonPart'))
      .toString();
}

/// 把一次 AI 分析结果应用成逐集绑定（纯逻辑，无 IO）。
///
/// - FLAT_BY_COUNTS：按 parsedNumber 主键映射（`mapFlatEpisodeNumber` 语义）。
/// - SINGLE_SEASON：episodeNumber = 解析集号 > 0 ? 解析集号 : index+1。
/// - KEEP_ORIGINAL：空绑定（清理由 confirmAndPersist 落库时处理）。
/// - EXPLICIT_MAPPING：要求完整唯一（复用 `parseAiSeasonResponse` 已有的校验，
///   此处再校验一次防下游直接构造 analysis）。
AiSeasonApplyResult buildSeasonBindings({
  required AiSeasonAnalysis analysis,
  required List<VodEpisode> episodes,
  required Map<int, int> seasonCounts,
}) {
  if (!analysis.success) {
    return const AiSeasonApplyResult(status: AiSeasonApplyStatus.rejected);
  }
  switch (analysis.mode) {
    case AiSeasonMode.keepOriginal:
      return const AiSeasonApplyResult(status: AiSeasonApplyStatus.applied);
    case AiSeasonMode.singleSeason:
      return _buildSingleSeason(
        analysis: analysis,
        episodes: episodes,
        seasonCounts: seasonCounts,
      );
    case AiSeasonMode.flatByCounts:
      return _buildFlatByCounts(
        episodes: episodes,
        seasonCounts: seasonCounts,
      );
    case AiSeasonMode.explicitMapping:
      return _buildExplicit(
        analysis: analysis,
        episodes: episodes,
        seasonCounts: seasonCounts,
      );
    case null:
      return const AiSeasonApplyResult(status: AiSeasonApplyStatus.rejected);
  }
}

AiSeasonApplyResult _buildSingleSeason({
  required AiSeasonAnalysis analysis,
  required List<VodEpisode> episodes,
  required Map<int, int> seasonCounts,
}) {
  final season = analysis.seasonNumber;
  final count = seasonCounts[season] ?? 0;
  if (season < 0 || count <= 0 || episodes.length > count) {
    return const AiSeasonApplyResult(status: AiSeasonApplyStatus.rejected);
  }
  final bindings = <AiEpisodeBinding>[];
  for (var index = 0; index < episodes.length; index++) {
    final parsed = parseEpisodeNumber(episodes[index].name);
    // 对照 `EpisodeSeasonPolicy.linearEpisodeNumber`：解析集号优先，缺号 fallback
    final episodeNumber = parsed > 0 ? parsed : index + 1;
    bindings.add(
      AiEpisodeBinding(
        sourceIndex: index,
        seasonNumber: season,
        episodeNumber: episodeNumber,
      ),
    );
  }
  return AiSeasonApplyResult(
    status: AiSeasonApplyStatus.applied,
    bindings: bindings,
    mappedCount: bindings.length,
  );
}

AiSeasonApplyResult _buildFlatByCounts({
  required List<VodEpisode> episodes,
  required Map<int, int> seasonCounts,
}) {
  final seasons = seasonCounts.keys.where((s) => s > 0).toList()..sort();
  final bindings = <AiEpisodeBinding>[];
  final skipped = <int>[];
  for (var index = 0; index < episodes.length; index++) {
    final number = parseEpisodeNumber(episodes[index].name);
    final mapped = _mapFlatEpisodeNumber(number, seasons, seasonCounts);
    if (mapped == null) {
      skipped.add(index);
      continue;
    }
    bindings.add(
      AiEpisodeBinding(
        sourceIndex: index,
        seasonNumber: mapped.$1,
        episodeNumber: mapped.$2,
      ),
    );
  }
  if (bindings.isEmpty) {
    return const AiSeasonApplyResult(status: AiSeasonApplyStatus.rejected);
  }
  return AiSeasonApplyResult(
    status: skipped.isEmpty
        ? AiSeasonApplyStatus.applied
        : AiSeasonApplyStatus.partial,
    bindings: bindings,
    skippedSourceIndexes: skipped,
    mappedCount: bindings.length,
  );
}

/// 对照安卓 `EpisodeSeasonPolicy.mapFlatEpisodeNumber`：parsedNumber 主键
/// 累计映射；缺号/越界/未知（<=0）不偏移后续集，直接跳过。
(int, int)? _mapFlatEpisodeNumber(
  int number,
  List<int> seasons,
  Map<int, int> seasonCounts,
) {
  if (number <= 0) return null;
  var remaining = number;
  for (final season in seasons) {
    final count = seasonCounts[season] ?? 0;
    if (count <= 0) return null;
    if (remaining <= count) return (season, remaining);
    remaining -= count;
  }
  return null;
}

AiSeasonApplyResult _buildExplicit({
  required AiSeasonAnalysis analysis,
  required List<VodEpisode> episodes,
  required Map<int, int> seasonCounts,
}) {
  final mappings = analysis.mappings;
  // 完整唯一性在此再校验（不信任上游 parseAiSeasonResponse 之外的构造路径）。
  // **必须按 sourceIndex 顺序**校验季集号严格递增：直接构造的乱序列表
  // （如 source1→S1E1、source0→S1E2）不能被当作合法映射。
  if (episodes.isEmpty || mappings.length != episodes.length) {
    return const AiSeasonApplyResult(status: AiSeasonApplyStatus.rejected);
  }
  final ordered = [...mappings]
    ..sort((a, b) => a.sourceIndex.compareTo(b.sourceIndex));
  final seenSources = List<bool>.filled(episodes.length, false);
  final targets = <String>{};
  var previousSeason = -1;
  var previousEpisode = -1;
  for (final mapping in ordered) {
    if (mapping.sourceIndex < 0 ||
        mapping.sourceIndex >= episodes.length ||
        seenSources[mapping.sourceIndex]) {
      return const AiSeasonApplyResult(status: AiSeasonApplyStatus.rejected);
    }
    final count = seasonCounts[mapping.seasonNumber] ?? 0;
    if (mapping.seasonNumber < 0 ||
        count <= 0 ||
        mapping.episodeNumber <= 0 ||
        mapping.episodeNumber > count) {
      return const AiSeasonApplyResult(status: AiSeasonApplyStatus.rejected);
    }
    if (!targets.add('${mapping.seasonNumber}:${mapping.episodeNumber}')) {
      return const AiSeasonApplyResult(status: AiSeasonApplyStatus.rejected);
    }
    if (previousSeason > mapping.seasonNumber ||
        (previousSeason == mapping.seasonNumber &&
            previousEpisode >= mapping.episodeNumber)) {
      return const AiSeasonApplyResult(status: AiSeasonApplyStatus.rejected);
    }
    seenSources[mapping.sourceIndex] = true;
    previousSeason = mapping.seasonNumber;
    previousEpisode = mapping.episodeNumber;
  }
  if (seenSources.any((seen) => !seen)) {
    return const AiSeasonApplyResult(status: AiSeasonApplyStatus.rejected);
  }
  return AiSeasonApplyResult(
    status: AiSeasonApplyStatus.applied,
    bindings: [
      for (final mapping in ordered)
        AiEpisodeBinding(
          sourceIndex: mapping.sourceIndex,
          seasonNumber: mapping.seasonNumber,
          episodeNumber: mapping.episodeNumber,
        ),
    ],
    mappedCount: mappings.length,
  );
}

/// 低置信度回退判定（Task5.3，对照调度合同："不让弱信心自动覆盖既有强匹配"）。
bool shouldWriteIdentityFallback({
  required int existingTmdbId,
  required bool existingIsManual,
  required double confidence,
}) {
  // 既有任何匹配（manual 或 auto）→ 不覆盖（不猜 ID）
  if (existingTmdbId > 0) return false;
  return confidence >= aiIdentityFallbackMinConfidence;
}

/// TMDB 身份回退时的 typed 片名解析注入点（Task4 typed resolver 公开接口后，
/// Task5 adapter 把其 typed 结果转换成 [SeasonTitleResolution] 注入）。
class SeasonTitleQuery {
  const SeasonTitleQuery({required this.rawTitle, this.vodYear});
  final String rawTitle;
  final String? vodYear;
}

class SeasonTitleResolution {
  const SeasonTitleResolution({
    required this.title,
    required this.confidence,
    this.year,
    this.mediaType,
  });

  /// 清洗后的片名（**不是 TMDB ID**：ID 只能由 TMDB 命中给出）。
  final String title;
  final double confidence;
  final int? year;

  /// `movie` / `tv`；未知为 `null`。
  final String? mediaType;
}

abstract interface class SeasonTitleResolver {
  Future<SeasonTitleResolution?> resolve(SeasonTitleQuery query);
}

/// AI 季集映射持久化编排（Task5.2）。
class AiSeasonMappingService {
  // ignore_for_file: prefer_initializing_formals
  AiSeasonMappingService({required AppDatabase database})
    : _database = database;

  final AppDatabase _database;

  /// 确认并持久化。`recognitionSnapshot` 是识别时指纹；
  /// 确认时现场指纹与它不一致 → `staleSnapshot` 拒写。
  Future<AiSeasonApplyResult> confirmAndPersist({
    int configId = 0,
    required String siteKey,
    required String vodId,
    required String sourceTitle,
    required String flagKey,
    required AiSeasonAnalysis analysis,
    required List<VodEpisode> episodes,
    required Map<int, int> seasonCounts,
    required String recognitionSnapshot,
    int tmdbId = 0,
    String mediaType = '',
    AiSeasonMode? mode,
  }) async {
    final current = seasonBindingsSnapshot(episodes, seasonCounts);
    if (current != recognitionSnapshot) {
      return const AiSeasonApplyResult(
        status: AiSeasonApplyStatus.staleSnapshot,
      );
    }
    final result = buildSeasonBindings(
      analysis: analysis,
      episodes: episodes,
      seasonCounts: seasonCounts,
    );
    if (result.status == AiSeasonApplyStatus.rejected) return result;
    // KEEP_ORIGINAL：删除既有 AI 映射（清理语义，不落新行）
    if (analysis.mode == AiSeasonMode.keepOriginal) {
      _database.removeAiSeasonMappings(
        configId: configId,
        siteKey: siteKey,
        vodId: vodId,
        sourceTitle: sourceTitle,
        flagKey: flagKey,
      );
      return result;
    }
    _database.upsertAiSeasonMappings(
      configId: configId,
      siteKey: siteKey,
      vodId: vodId,
      sourceTitle: sourceTitle,
      flagKey: flagKey,
      tmdbId: tmdbId,
      mediaType: mediaType,
      mode: (mode ?? analysis.mode ?? AiSeasonMode.keepOriginal).name,
      seasonNumber: analysis.seasonNumber,
      confidence: analysis.confidence,
      mappings: result.bindings,
      snapshot: current,
      status: result.status.name,
      skippedSourceIndexes: result.skippedSourceIndexes,
    );
    return result;
  }

  /// 读取并校验持久化绑定（重启后查询）。
  Future<AiSeasonBindingsResult> bindingsFor({
    int configId = 0,
    required String siteKey,
    required String vodId,
    required String sourceTitle,
    required String flagKey,
    required List<VodEpisode> episodes,
    required Map<int, int> seasonCounts,
  }) async {
    final row = _database.findAiSeasonMappings(
      configId: configId,
      siteKey: siteKey,
      vodId: vodId,
      sourceTitle: sourceTitle,
      flagKey: flagKey,
    );
    if (row == null) {
      return const AiSeasonBindingsResult(
        status: AiSeasonApplyStatus.missing,
      );
    }
    final storedSnapshot = row['snapshot'] as String? ?? '';
    final current = seasonBindingsSnapshot(episodes, seasonCounts);
    if (storedSnapshot != current) {
      return const AiSeasonBindingsResult(
        status: AiSeasonApplyStatus.staleSnapshot,
      );
    }
    final mappings = _decodeMappings(row['mappings'] as String?);
    if (mappings.isEmpty) {
      return const AiSeasonBindingsResult(status: AiSeasonApplyStatus.missing);
    }
    // 读回保持保存时的准确状态：FLAT 部分跳过不能谎报为完整 applied。
    final storedStatus = _statusOf(row['status'] as String?);
    final skipped = _decodeIntList(row['skipped_source_indexes'] as String?);
    return AiSeasonBindingsResult(
      status: storedStatus,
      bindings: mappings,
      skippedSourceIndexes: skipped,
      mappedCount: mappings.length,
    );
  }

  /// 清除一条线路的 AI 映射。
  void clearMappings({
    int configId = 0,
    required String siteKey,
    required String vodId,
    required String sourceTitle,
    required String flagKey,
  }) {
    _database.removeAiSeasonMappings(
      configId: configId,
      siteKey: siteKey,
      vodId: vodId,
      sourceTitle: sourceTitle,
      flagKey: flagKey,
    );
  }

  static AiSeasonApplyStatus _statusOf(String? raw) => switch (raw) {
    'partial' => AiSeasonApplyStatus.partial,
    _ => AiSeasonApplyStatus.applied,
  };

  List<int> _decodeIntList(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded.whereType<int>().toList();
    } catch (_) {
      return const [];
    }
  }

  List<AiEpisodeBinding> _decodeMappings(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded.map(AiEpisodeBinding.fromJson).whereType<AiEpisodeBinding>().toList();
    } catch (_) {
      return const [];
    }
  }
}
