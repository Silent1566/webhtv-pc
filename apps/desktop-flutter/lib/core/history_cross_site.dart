/// 详情页「同一个配置里、另一个爬虫源的历史进度」的纯逻辑。
///
/// 对齐安卓 `History.findPlayback` + `findPlaybackCandidate` 的跨源语义：
/// 同一个 `source_key`（= 同一份配置）内按 TMDB 身份/同名找到别的站点的记录，
/// 再把那条记录**映射到当前站点自己的线路与集**上——标记「上次看到这里」、
/// 决定续播从哪一集哪一秒开始。
///
/// ## 为什么集对齐只认唯一命中
///
/// 换一个爬虫源之后，线路名、集名、集号写法全都不一样（`第5集` / `EP05` /
/// `05. 标题`）。任何「差不多对上」的启发式都可能把用户送到别的集，
/// 再叠加进度迁移就是**错续播**。所以本层每一步都要求唯一命中，
/// 歧义一律返回 `null`（`docs/phase6/design/01` §4.1「宁可不续播，不可错续播」）。
///
/// 本模块属于纯逻辑层：不依赖 Flutter、不依赖 `dart:io`、不依赖 `services/`，
/// 因此收标量投影 [HistoryCandidate] 而不是 `PlaybackHistory`。
library;

import 'history_view.dart';
import 'protocol.dart';
import 'tmdb_title.dart';

/// 续播位置的下限（与 `AppState.resumeThreshold` 同值）。
///
/// 两条规则必须同口径：卡片上标了进度、点进去却从头开始，是因为这里判「可续播」
/// 而 `AppState.resumePositionFor` 判「不可续播」（或反过来）。
const int resumeMinPositionMs = 5000;

/// 距离片尾的保护带：贴到这里视为已看完（与 `AppState.resumePositionFor` 同值）。
const int resumeEndingGuardMs = 5000;

/// 一条历史记录在纯逻辑层的标量投影。
///
/// 字段一一对应 `history` 表里详情页需要的那几列；不带 `vodName`/`sourceKey`
/// 是因为「哪些记录属于同一部作品」在查询层已经判完，映射层不该再猜一次。
class HistoryCandidate {
  const HistoryCandidate({
    required this.siteKey,
    required this.vodId,
    required this.flag,
    required this.episodeName,
    required this.episodeId,
    required this.positionMs,
    required this.durationMs,
    required this.updatedAt,
    this.completed = false,
  });

  /// 记录所属站点（同一份配置里的爬虫源）。
  final String siteKey;

  /// 记录所属条目 id（不同站点的 id 命名空间不同）。
  final String vodId;

  /// 记录里的线路标识（原站点的线路名，跨站点时**不可**用于定位线路）。
  final String flag;

  /// 记录里的集名。跨站点时它是**唯一**可信的集身份线索。
  final String episodeName;

  /// 记录里的集入口（原站点的 URL；跨站点时通常对不上）。
  final String episodeId;

  final int positionMs;
  final int durationMs;
  final int updatedAt;
  final bool completed;

  /// 0..100；时长未知时为 0（与 `PlaybackHistory.progress` 同口径）。
  int get progressPercent {
    if (durationMs <= 0) return 0;
    return ((positionMs / durationMs) * 100).round().clamp(0, 100);
  }

  /// 是否有可迁移的观看位置。
  ///
  /// 三条否决与 `AppState.resumePositionFor` 一字不差：已看完、位置过短、
  /// 贴着片尾。任一处漂移，卡片上的角标就会与点进去的行为对不上。
  bool get hasResumePosition =>
      hasResumePositionMs(
        positionMs: positionMs,
        durationMs: durationMs,
        completed: completed,
      );
}

/// 「这个位置值不值得续播」的唯一判定（三条否决）。
///
/// 收标量而不是 [HistoryCandidate]：本站记录在详情页里是 `PlaybackHistory`，
/// 两条路径都要用同一套门槛，不能各写一份。
bool hasResumePositionMs({
  required int positionMs,
  required int durationMs,
  required bool completed,
}) =>
    !completed &&
    positionMs >= resumeMinPositionMs &&
    !(durationMs > 0 && positionMs > durationMs - resumeEndingGuardMs);

/// 一条候选映射到某条线路后的结果。
class MappedHistoryCandidate {
  const MappedHistoryCandidate({
    required this.candidate,
    required this.episodeIndex,
    required this.episodeName,
  });

  final HistoryCandidate candidate;

  /// 目标线路 `episodes` 里的**原始下标**（不是渲染下标）。
  final int episodeIndex;

  /// 目标线路里那一集的集名（展示用）。
  final String episodeName;
}

/// 把一条候选映射到 [line] 的某一集；定位不到或多解时返回 `null`。
///
/// 四级顺序，越靠前越可信：
/// 1. **集入口 URL 精确命中**——同站点/同解析源时才可能命中，命中即唯一；
/// 2. **集名完全相同**且唯一；
/// 3. **集号相同**且唯一（跨站点命名不同：`第5集` vs `EP05`）；
/// 4. **单集线路**——电影/单集剧整部就是这一集。
///
/// 季度不同直接否决（两边都能判定季度时）：`S02E05` 不能落到 `S01E05` 上。
MappedHistoryCandidate? mapHistoryCandidateToLine({
  required HistoryCandidate candidate,
  required VodPlayLine line,
}) {
  final episodes = line.episodes;
  if (episodes.isEmpty) return null;

  final candidateSeason = sourceSeasonNumber(candidate.episodeName);
  bool sameSeason(String? targetName) {
    final target = sourceSeasonNumber(targetName);
    if (candidateSeason <= 0 || target <= 0) return true;
    return candidateSeason == target;
  }

  int? index;

  // 一级：集入口 URL 精确命中。
  if (candidate.episodeId.isNotEmpty) {
    final hits = <int>[
      for (var i = 0; i < episodes.length; i++)
        if (episodes[i].url == candidate.episodeId) i,
    ];
    if (hits.length == 1) index = hits.single;
  }

  // 二级：集名完全相同且唯一（季度不同的一律排除）。
  if (index == null && candidate.episodeName.isNotEmpty) {
    final hits = <int>[
      for (var i = 0; i < episodes.length; i++)
        if (episodes[i].name == candidate.episodeName && sameSeason(episodes[i].name))
          i,
    ];
    if (hits.length == 1) index = hits.single;
  }

  // 三级：集号相同且唯一。
  if (index == null) {
    final number = sourceEpisodeNumber(candidate.episodeName);
    if (number > 0) {
      final hits = <int>[
        for (var i = 0; i < episodes.length; i++)
          if (sourceEpisodeNumber(episodes[i].name) == number &&
              sameSeason(episodes[i].name))
            i,
      ];
      if (hits.length == 1) index = hits.single;
    }
  }

  // 四级：单集线路（电影/单集剧）——整部作品就是这一集。
  if (index == null && episodes.length == 1 && sameSeason(episodes.single.name)) {
    index = 0;
  }

  if (index == null) return null;
  return MappedHistoryCandidate(
    candidate: candidate,
    episodeIndex: index,
    episodeName: episodes[index].name,
  );
}

/// 详情页的跨站点进度投影。
class CrossSiteProgress {
  const CrossSiteProgress({required this.mapped, required this.resumable});

  /// 所有能映射到当前线路的候选，**按最近观看倒序**。
  final List<MappedHistoryCandidate> mapped;

  /// 其中真正可续播的那些（顺序同 [mapped]）。
  final List<MappedHistoryCandidate> resumable;

  /// 默认续播目标：最近的可续播记录；没有可续播的才回落到最近一条记录。
  ///
  /// 与安卓 `findPlaybackCandidate` 的排序同向：先「能续播」，再「最近」。
  MappedHistoryCandidate? get primary =>
      resumable.isNotEmpty ? resumable.first : (mapped.isEmpty ? null : mapped.first);

  /// 是否要弹「选择续播记录」：两条以上**不同记录**都能续播。
  ///
  /// 只数可续播的记录：已看完/没位置的记录不能作为续播起点，让用户去选
  /// 一条点了就从头开始的记录，比不弹更糟。
  bool get needsChoice => resumable.length >= 2;
}

/// 把候选投影成当前线路上的进度视图。
CrossSiteProgress buildCrossSiteProgress({
  required Iterable<HistoryCandidate> candidates,
  required VodPlayLine line,
}) {
  final mapped = <MappedHistoryCandidate>[];
  for (final candidate in candidates) {
    final hit = mapHistoryCandidateToLine(candidate: candidate, line: line);
    if (hit != null) mapped.add(hit);
  }
  mapped.sort((a, b) {
    final byTime = b.candidate.updatedAt.compareTo(a.candidate.updatedAt);
    if (byTime != 0) return byTime;
    // 同一毫秒的并列：按集号稳定排序，避免每次 build 顺序抖动。
    return a.episodeIndex.compareTo(b.episodeIndex);
  });
  final resumable = [
    for (final item in mapped)
      if (item.candidate.hasResumePosition) item,
  ];
  return CrossSiteProgress(mapped: mapped, resumable: resumable);
}

/// 跨站点续播的种子：把原记录的身份**改写**成目标线路自己的身份。
///
/// 只改身份、不改进度：`flag/episodeId/episodeName` 必须是目标线路自己的值，
/// 否则 `resolveResumeStart` → `locateResumeEpisode` 会定位不到「原记录那一集」
/// 而拒绝迁移——那正是「卡片标了进度、点进去却从头播」的根因。
/// 这与安卓 `History.copyForPlaybackKey` / `rebindPlaybackRoute` 同一手法。
ResumeSeed? reboundResumeSeed({
  required MappedHistoryCandidate mapped,
  required VodPlayLine line,
}) {
  final index = mapped.episodeIndex;
  if (index < 0 || index >= line.episodes.length) return null;
  final episode = line.episodes[index];
  return ResumeSeed(
    flag: line.playbackFlag,
    episodeId: episode.url,
    episodeName: episode.name,
    positionMs: mapped.candidate.positionMs,
    durationMs: mapped.candidate.durationMs,
    completed: mapped.candidate.completed,
  );
}

/// 毫秒 → `MM:SS` / `H:MM:SS`（负数按 0 处理）。
String clockText(int milliseconds) {
  final total = milliseconds < 0 ? 0 : milliseconds ~/ 1000;
  final hours = total ~/ 3600;
  String two(int value) => value.toString().padLeft(2, '0');
  final minutes = two(total ~/ 60 % 60);
  final seconds = two(total % 60);
  return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
}

/// 观看时间 → 相对说法（`刚刚` / `N 分钟前` / `N 小时前` / `N 天前` / 日期）。
///
/// 超过一周退化成绝对日期：`9 天前` 不如 `2026-11-20` 好判断是哪一次观看。
/// [updatedAtMs] 为 0（未知）时返回空串，调用方据此省略这一段，而不是编一个时间。
String watchedAgoLabel(int updatedAtMs, {required int nowMs}) {
  if (updatedAtMs <= 0) return '';
  final delta = nowMs - updatedAtMs;
  if (delta < 60 * 1000) return '刚刚';
  if (delta < 60 * 60 * 1000) return '${delta ~/ (60 * 1000)} 分钟前';
  if (delta < 24 * 60 * 60 * 1000) return '${delta ~/ (60 * 60 * 1000)} 小时前';
  if (delta < 7 * 24 * 60 * 60 * 1000) {
    return '${delta ~/ (24 * 60 * 60 * 1000)} 天前';
  }
  final moment = DateTime.fromMillisecondsSinceEpoch(updatedAtMs);
  String two(int value) => value.toString().padLeft(2, '0');
  return '${moment.year}-${two(moment.month)}-${two(moment.day)}';
}
