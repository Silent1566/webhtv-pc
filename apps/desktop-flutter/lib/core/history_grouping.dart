/// 历史记录的**同名聚合投影**（纯逻辑，无 Flutter / 数据库依赖）。
///
/// 对应上游安卓 `GlobalHistoryEntry`（`docs/global-history-resume-design.md` §8），
/// 但按 PC 侧的既有分层做了两处收窄：
///
/// 1. **只做投影，不做查询**：输入是已经取到的历史行，输出是分组结果；
///    取数（按源过滤 / 全局）仍由 `AppDatabase` + `AppState` 负责。
/// 2. **不持有配置对象**：来源文案要解析「这个 `source_key` 是哪条配置」，
///    那是状态层的事（它才有 `configs` 列表）。这里只透传 `sourceKey`。
///
/// ## 聚合键（决定「哪些记录算同一部作品」）
///
/// | 模式 | 有 TMDB 身份 | 没有 TMDB 身份 |
/// | --- | --- | --- |
/// | `tmdb`（默认） | `(mediaType, tmdbId)` | 规范化片名（+ 年份消歧） |
/// | `title` | 规范化片名（+ 年份消歧） | 规范化片名（+ 年份消歧） |
/// | `none` | 不聚合，每条记录自成一组 | 同左 |
///
/// ## 为什么年份是「组内消歧」而不是键的一部分
///
/// 历史表里年份可能为空（安卓同步来的记录没有年份字段，本地播放才写）。
/// 若把年份直接拼进键，同一部剧「安卓推来的无年份记录」与「PC 本地播放的
/// 有年份记录」会分裂成两张卡——这正是用户抱怨的「同名作品散成好几张」。
/// 因此先按片名分桶，**只有当同一桶内出现 ≥2 个不同的非空年份时**才按年份
/// 拆开，无年份的记录归入单独的「年份未知」桶（不猜它属于哪一年）。
library;

import 'tmdb_identity.dart';

/// 参与聚合的一条历史（标量投影，避免 `core/` 依赖 `services/storage.dart`）。
class HistoryGroupInput {
  const HistoryGroupInput({
    required this.id,
    required this.sourceKey,
    required this.siteKey,
    required this.vodId,
    required this.vodName,
    required this.flag,
    required this.episodeName,
    required this.episodeId,
    required this.positionMs,
    required this.durationMs,
    required this.updatedAt,
    this.completed = false,
    this.vodPic,
    this.vodYear = '',
    this.tmdbId = 0,
    this.mediaType = '',
  });

  final int id;

  /// 归属播放源（`bridge|<设备>|<interfaceKey>` / `local|<origin>`）。
  final String sourceKey;

  final String siteKey;
  final String vodId;
  final String vodName;
  final String? vodPic;
  final String flag;
  final String episodeName;
  final String episodeId;
  final int positionMs;
  final int durationMs;
  final int updatedAt;
  final bool completed;

  /// 作品年份（可空串：安卓同步来的旧记录没有这个字段）。
  final String vodYear;

  /// TMDB 数字 ID；0 = 未绑定。
  final int tmdbId;

  /// `movie` / `tv`；空串 = 未绑定。
  final String mediaType;

  /// 已归一化的媒体类型；只认 `movie` / `tv`，其余回空串（对齐安卓
  /// `normalizeMediaType`：不认识的类型不参与 TMDB 聚合，避免
  /// 电影与剧集命名空间里相同的数字 ID 被误合并）。
  String get normalizedMediaType {
    final value = mediaType.trim().toLowerCase();
    return value == 'movie' || value == 'tv' ? value : '';
  }

  /// 是否带**可用**的 TMDB 身份（ID 与类型都齐）。
  bool get hasTmdbIdentity => tmdbId > 0 && normalizedMediaType.isNotEmpty;

  double get progress {
    if (durationMs <= 0) return 0;
    return (positionMs / durationMs).clamp(0.0, 1.0);
  }

  int get progressPercent => (progress * 100).round();
}

/// 一组同作品历史。
class HistoryGroup {
  const HistoryGroup({
    required this.key,
    required this.members,
    required this.aggregatedByTmdb,
  });

  /// 聚合键（调试与测试断言用，不展示）。
  final String key;

  /// 组内全部成员，**按 `updatedAt` 降序**。
  final List<HistoryGroupInput> members;

  /// 该组的键是否来自 TMDB 身份（否则来自片名）。
  final bool aggregatedByTmdb;

  /// 代表记录 = 最近一次播放（安卓 §8.1：**不是取最大进度**——
  /// 用户主动回看前一集时，最新行为应当优先）。
  HistoryGroupInput get representative => members.first;

  /// 组内出现的全部播放源（去重，按首次出现顺序）。
  List<String> get sourceKeys {
    final seen = <String>[];
    for (final member in members) {
      if (!seen.contains(member.sourceKey)) seen.add(member.sourceKey);
    }
    return seen;
  }

  /// 是否跨源（多于一个来源）。
  bool get crossSource => sourceKeys.length > 1;

  /// 是否聚合卡（组内多于一条记录）。
  bool get aggregated => members.length > 1;
}

/// 把历史行投影成分组列表。
///
/// [mode] 取 `UiHistoryAggregation` 的字面值（这里收字符串，避免 `core/`
/// 内部文件互相依赖成环）。
///
/// 输出顺序：按每组代表记录的 `updatedAt` 降序（与 `recentHistory` 一致，
/// 保证「最近看的在最前」）。
List<HistoryGroup> groupHistory(
  List<HistoryGroupInput> records, {
  required String mode,
}) {
  if (records.isEmpty) return const [];

  // 不聚合：每条记录自成一组，保持输入顺序（调用方已按 updatedAt 降序排好）。
  if (mode == 'none') {
    return [
      for (final record in records)
        HistoryGroup(
          key: 'record|${record.id}',
          members: [record],
          aggregatedByTmdb: false,
        ),
    ];
  }

  final useTmdb = mode != 'title';
  final tmdbBuckets = <String, List<HistoryGroupInput>>{};
  final titleBuckets = <String, List<HistoryGroupInput>>{};

  for (final record in records) {
    if (useTmdb && record.hasTmdbIdentity) {
      final key = 'tmdb|${record.normalizedMediaType}|${record.tmdbId}';
      (tmdbBuckets[key] ??= []).add(record);
      continue;
    }
    final title = TmdbCacheKey.normalizeSourceTitle(record.vodName);
    // 片名为空/归一化后为空：无法可靠判定同名，单独成组（不猜）。
    final key = title.isEmpty ? 'raw|${record.vodName}' : 'title|$title';
    (titleBuckets[key] ??= []).add(record);
  }

  final result = <HistoryGroup>[];
  for (final entry in tmdbBuckets.entries) {
    result.add(
      HistoryGroup(
        key: entry.key,
        members: _sorted(entry.value),
        aggregatedByTmdb: true,
      ),
    );
  }
  for (final entry in titleBuckets.entries) {
    for (final sub in _splitByYear(entry.key, entry.value)) {
      result.add(
        HistoryGroup(
          key: sub.key,
          members: _sorted(sub.members),
          aggregatedByTmdb: false,
        ),
      );
    }
  }

  result.sort(
    (a, b) => b.representative.updatedAt.compareTo(a.representative.updatedAt),
  );
  return result;
}

List<HistoryGroupInput> _sorted(List<HistoryGroupInput> members) =>
    members.toList()..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

/// 片名桶内按年份消歧（见文件头「为什么年份是组内消歧」）。
List<({String key, List<HistoryGroupInput> members})> _splitByYear(
  String baseKey,
  List<HistoryGroupInput> members,
) {
  final years = <String>{};
  for (final member in members) {
    final year = member.vodYear.trim();
    if (year.isNotEmpty) years.add(year);
  }
  // 只有一个年份（或全都没有）：不拆。
  if (years.length <= 1) {
    return [(key: baseKey, members: members)];
  }
  final buckets = <String, List<HistoryGroupInput>>{};
  for (final member in members) {
    final year = member.vodYear.trim();
    final key = year.isEmpty
        ? '$baseKey|year-unknown'
        : '$baseKey|y:$year';
    (buckets[key] ??= []).add(member);
  }
  return [
    for (final entry in buckets.entries)
      (key: entry.key, members: entry.value),
  ];
}
