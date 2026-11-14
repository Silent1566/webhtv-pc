/// 历史记录相关的纯逻辑：详情页从历史恢复播放的解析。
///
/// 纯逻辑层：不依赖 Flutter，也不依赖 `dart:io`，也不依赖 `services/`。
/// 理由与 `hot_rank_layout.dart`、`search_result_filter.dart` 一致——线路三级
/// 匹配与「歧义就不猜」是本轮最容易写错的语义，必须在无窗口环境下可单测。
///
/// 因此 [resolveHistoryTarget] 收标量而不是 `PlaybackHistory`：后者定义在
/// `services/storage.dart`，收它会新开一条 `core/` → `services/` 的依赖方向。
library;

import 'protocol.dart';
import 'resume_migration.dart';
import 'tmdb_title.dart';

/// 详情页从历史恢复播放的目标（`docs/phase6/design/02` §2）。
class HistoryResumeTarget {
  const HistoryResumeTarget({
    required this.flag,
    required this.episodeIndex,
    required this.episodeName,
    required this.matched,
  });

  /// 命中的线路 flag（展示用）。空串表示没有任何线路。
  final String flag;

  /// 该线路内剧集的**原始下标**（`VodPlayLine.episodes` 的下标）。
  ///
  /// 必须用原始下标：播放要的是它，而渲染下标经过季度过滤与倒序。
  final int episodeIndex;

  /// 命中的集名（用于按钮文案）。
  final String episodeName;

  /// 是否**完整**命中（线路与集都对上）。
  ///
  /// 只有完整命中才允许把按钮改成「继续播放」。
  final bool matched;

  /// 无历史时的目标：第一条线路第 0 集。
  factory HistoryResumeTarget.firstEpisodeOf(List<VodPlayLine> lines) {
    if (lines.isEmpty) {
      return const HistoryResumeTarget(
        flag: '',
        episodeIndex: 0,
        episodeName: '',
        matched: false,
      );
    }
    final first = lines.first;
    return HistoryResumeTarget(
      flag: first.flag,
      episodeIndex: 0,
      episodeName: first.episodes.isEmpty ? '' : first.episodes.first.name,
      matched: false,
    );
  }
}

/// 解析「用哪条线路、第几集」（`docs/phase6/design/02` §2.1、§2.2）。
///
/// 线路匹配三级顺序，任一级命中即返回；集匹配两级顺序。
/// **任何一级出现歧义都不猜**（对齐上游 `uniqueFlagForEpisodeUrl`）。
///
/// 收标量而不是 `PlaybackHistory`：后者在 `services/storage.dart`，
/// 而本模块属于纯逻辑层（`core/` 不得依赖 `services/`）。
HistoryResumeTarget resolveHistoryTarget({
  required String historyFlag,
  required String historyEpisodeId,
  required String historyEpisodeName,
  required List<VodPlayLine> lines,
}) {
  if (lines.isEmpty) return HistoryResumeTarget.firstEpisodeOf(lines);
  final hasHistory =
      historyFlag.isNotEmpty ||
      historyEpisodeId.isNotEmpty ||
      historyEpisodeName.isNotEmpty;
  if (!hasHistory) return HistoryResumeTarget.firstEpisodeOf(lines);

  // 第一级：flag 精确命中，且该线路**包含**这一集。
  for (final line in lines) {
    if (line.playbackFlag != historyFlag && line.flag != historyFlag) continue;
    final index = _episodeIndexOf(line, historyEpisodeId, historyEpisodeName);
    if (index >= 0) {
      return HistoryResumeTarget(
        flag: line.flag,
        episodeIndex: index,
        episodeName: line.episodes[index].name,
        matched: true,
      );
    }
  }

  // 第二级：集 URL 在所有线路里**唯一**命中。
  if (historyEpisodeId.isNotEmpty) {
    final hits = <(VodPlayLine, int)>[];
    for (final line in lines) {
      final index = _indexOfUrl(line, historyEpisodeId);
      if (index >= 0) hits.add((line, index));
    }
    if (hits.length == 1) {
      final (line, index) = hits.first;
      return HistoryResumeTarget(
        flag: line.flag,
        episodeIndex: index,
        episodeName: line.episodes[index].name,
        matched: true,
      );
    }
  }

  // 第三级：线路名命中——**仅当历史没有集入口目标**（旧数据）。
  //
  // 为什么必须加这个前提：历史带着集入口却一条线路都找不到时，说明那一集已
  // 从所有线路里消失，此时按线路名"猜"第 0 集会把用户送到错误的集上；按
  // 「歧义就不猜」退回第一条线路。只有历史**没有**集入口（`episodeId` 为空，
  // 旧数据）时，线路名命中才是可信的线路级命中。
  if (historyEpisodeId.isEmpty) {
    for (final line in lines) {
      if (line.playbackFlag != historyFlag && line.flag != historyFlag) continue;
      final index = _episodeIndexOf(line, historyEpisodeId, historyEpisodeName);
      return HistoryResumeTarget(
        flag: line.flag,
        episodeIndex: index < 0 ? 0 : index,
        episodeName: index < 0
            ? (line.episodes.isEmpty ? '' : line.episodes.first.name)
            : line.episodes[index].name,
        // 线路命中但集没命中 → 不是完整命中。
        matched: false,
      );
    }
  }

  return HistoryResumeTarget.firstEpisodeOf(lines);
}

/// 在线路内定位历史那一集：URL 精确优先，集名兜底。
int _episodeIndexOf(VodPlayLine line, String episodeId, String episodeName) {
  if (episodeId.isNotEmpty) {
    final byUrl = _indexOfUrl(line, episodeId);
    if (byUrl >= 0) return byUrl;
  }
  if (episodeName.isNotEmpty) {
    for (var i = 0; i < line.episodes.length; i++) {
      if (line.episodes[i].name == episodeName) return i;
    }
  }
  return -1;
}

int _indexOfUrl(VodPlayLine line, String url) {
  for (var i = 0; i < line.episodes.length; i++) {
    if (line.episodes[i].url == url) return i;
  }
  return -1;
}

/// 详情页首屏按钮的文案（`docs/phase6/design/02` §3.1）。
///
/// 对齐上游 `TmdbDetailActivity#updatePlayLabel`：命中当前集**且**有进度
/// 才叫"继续播放"，否则是"播放第一集"。
///
/// 为什么用 `resumePosition` 而不是自己判断 `completed` 与位置阈值：
/// [AppState.resumePositionFor] 已经把这两件事一起处理了，两处判断会漂移。
String historyPlayLabel({
  required HistoryResumeTarget target,
  required Duration? resumePosition,
  String fallback = '播放第一集',
}) {
  if (!target.matched) return fallback;
  if (resumePosition == null) return fallback;
  if (target.episodeName.isEmpty) return fallback;
  return '继续播放 · ${target.episodeName}';
}

/// 跨源 / 跨站点续播的**进度种子**：原记录的进度 + 原记录的集身份。
///
/// 为什么需要它：`AppState.resumePositionFor` 查历史时带 `sourceKey`
/// （默认 = 当前播放源），原记录属于**别的源**时那条查询必然落空
/// （`services/storage.dart` 的 `findHistory` 没有「唯一记录」兜底），
/// 于是跨源续播只能由调用方把原记录的进度**显式**带下来。
///
/// 收标量而不收 `PlaybackHistory`：后者定义在 `services/storage.dart`，
/// 本模块属于纯逻辑层（`core/` 不得依赖 `services/`）。
class ResumeSeed {
  const ResumeSeed({
    required this.flag,
    required this.episodeId,
    required this.episodeName,
    required this.positionMs,
    required this.durationMs,
    this.completed = false,
  });

  /// 原记录命中的线路 flag（可能是站点源线路名，也可能是展示名）。
  final String flag;

  /// 原记录的集入口目标（站点认的原始值；同步来的可能是不相等的哈希）。
  final String episodeId;

  /// 原记录的集名。跨源时它是**唯一**可信的集身份线索。
  final String episodeName;

  /// 原记录播放到的绝对毫秒位置。
  final int positionMs;

  /// 原记录那一集的总时长（0 = 未知，此时只能沿用绝对位置）。
  final int durationMs;

  /// 原记录是否已播完（播完则不迁移，从头开始）。
  final bool completed;

  /// 是否有可迁移的位置（> 0）。
  bool get hasPosition => positionMs > 0;

  @override
  String toString() =>
      'ResumeSeed(flag=$flag, episode=$episodeName, '
      'position=$positionMs/$durationMs, completed=$completed)';
}

/// 原记录那一集在**目标线路列表**里的定位结果。
class ResumeEpisodeLocation {
  const ResumeEpisodeLocation({
    required this.line,
    required this.episodeIndex,
    required this.episodeName,
  });

  /// 原记录命中的线路（可能不是即将播放的那条）。
  final VodPlayLine line;

  /// 该集在 [line] 的 `episodes` 里的**原始下标**。
  final int episodeIndex;

  /// 该集的集名。
  final String episodeName;
}

/// 在目标线路列表里定位「原记录那一集」。
///
/// 两级顺序，与 [resolveHistoryTarget] 保持一致：
/// 1. 线路 flag（`playbackFlag` 或展示 `flag`）命中，且该线路包含这一集；
/// 2. 集入口目标在所有线路里**唯一**命中（跨源换站时的常见情形）。
///
/// 定位不到就返回 `null`——**不猜**。上层据此判定「不是同一集」，
/// 从而不迁移进度（`docs/phase6/design/01` §4.1「宁可不续播，不可错续播」）。
ResumeEpisodeLocation? locateResumeEpisode({
  required List<VodPlayLine> lines,
  required ResumeSeed seed,
}) {
  if (lines.isEmpty) return null;
  for (final line in lines) {
    if (line.playbackFlag != seed.flag && line.flag != seed.flag) continue;
    final index = _episodeIndexOf(line, seed.episodeId, seed.episodeName);
    if (index >= 0) {
      return ResumeEpisodeLocation(
        line: line,
        episodeIndex: index,
        episodeName: line.episodes[index].name,
      );
    }
  }
  if (seed.episodeId.isNotEmpty) {
    final hits = <ResumeEpisodeLocation>[];
    for (final line in lines) {
      final index = _indexOfUrl(line, seed.episodeId);
      if (index >= 0) {
        hits.add(
          ResumeEpisodeLocation(
            line: line,
            episodeIndex: index,
            episodeName: line.episodes[index].name,
          ),
        );
      }
    }
    if (hits.length == 1) return hits.first;
  }
  return null;
}

/// 判定「原记录那一集」与「即将播放的那一集」是否为**同一集**。
///
/// 这是进度迁移的硬闸门：只有同一集才允许把毫秒位置搬过去
/// （[ResumePositionPolicy.migrate] 的第一条规则）。
///
/// 判定顺序（任一成立即算同一集）：
/// 1. 两边都只有一集 → 单集作品，整部就是这一集（电影、单集剧）；
/// 2. 集号相同（[sourceEpisodeNumber] 解析，如 `S01E03`、`第3集`、`EP03`）；
/// 3. 集名完全相同；
/// 4. 同一线路 + 同一原始下标。
///
/// 为什么把集号排在集名前面：跨源换站后集名常带站点自己的前缀/后缀
/// （`第03集` vs `03`），但集号是作品本身的身份。
bool resumeEpisodeMatches({
  required List<VodPlayLine> lines,
  required ResumeSeed seed,
  required VodPlayLine targetLine,
  required int targetEpisodeIndex,
  required String targetEpisodeName,
}) {
  final targetName = targetEpisodeName.isNotEmpty
      ? targetEpisodeName
      : (targetEpisodeIndex >= 0 && targetEpisodeIndex < targetLine.episodes.length
            ? targetLine.episodes[targetEpisodeIndex].name
            : '');
  final located = locateResumeEpisode(lines: lines, seed: seed);
  // 定位不到原记录那一集：只能拿原记录自带的名字比一次，仍不知道就不迁移。
  if (located == null) {
    return _sameEpisodeByNumber(seed.episodeName, targetName);
  }
  if (located.line.episodes.length == 1 && targetLine.episodes.length == 1) {
    return true;
  }
  if (_sameEpisodeByNumber(located.episodeName, targetName)) return true;
  if (located.episodeName.isNotEmpty && located.episodeName == targetName) {
    return true;
  }
  return identical(located.line, targetLine) &&
      located.episodeIndex == targetEpisodeIndex;
}

bool _sameEpisodeByNumber(String source, String target) {
  final a = sourceEpisodeNumber(source);
  if (a < 0) return false;
  return a == sourceEpisodeNumber(target);
}

/// 目标站点某一部作品的集数（取最长那条线路的集数；0 = 无法判定）。
///
/// 只用于候选排序的次要权重与展示，**不参与**自动播放否决（PC 侧没有
/// 「集数不一致就拒绝」的规则，安卓 §10.4 同样不把集数当否决项）。
int episodeCountOf(List<VodPlayLine> lines) {
  var count = 0;
  for (final line in lines) {
    if (line.episodes.length > count) count = line.episodes.length;
  }
  return count;
}

/// 目标站点的这部剧里是否存在「原记录那一集」。
///
/// 这是跨源自动播放的**硬条件**（对齐安卓 §10.4 的 `hasTargetEpisode`）：
/// 集对不上的候选即使 TMDB 完全一致也不能自动播——否则用户点「继续观看」
/// 会被送到一部同名片的第一集，进度迁移也必然被 [resumeEpisodeMatches]
/// 拒掉，只剩一次白跑。
///
/// **实现刻意直接复用 [resumeEpisodeMatches]**，而不是另写一套「像不像同一集」
/// 的启发式：候选阶段说「有」，播放阶段就必须也判「是同一集」，否则用户会先
/// 被自动送进详情页、再在播放时被迁移规则拒掉（白跑一次，还从 0 开始）。
/// 逐集试一遍的代价可忽略（一部剧通常几十到几百集、一两次线路），而且
/// 这样两边判定才**永远不会**分叉。
///
/// 副作用是保守：单集作品（电影）若片名/集名/集号都对不上线索，这里判 false
/// ⇒ 不自动播，交给用户手动选。宁可少一次自动跳转，不可播错集。
bool candidateHasResumeEpisode({
  required List<VodPlayLine> lines,
  required ResumeSeed seed,
}) {
  for (final line in lines) {
    for (var index = 0; index < line.episodes.length; index++) {
      if (resumeEpisodeMatches(
        lines: lines,
        seed: seed,
        targetLine: line,
        targetEpisodeIndex: index,
        targetEpisodeName: line.episodes[index].name,
      )) {
        return true;
      }
    }
  }
  return false;
}

/// 把「原记录的进度」换算成**目标集**的起始位置（跨源续播的完整策略入口）。
///
/// [targetDurationMs] 传播放器已有的时长（0 = 未知）；未知时策略沿用绝对位置。
/// [fallback] 是同源场景下既有的精确查询结果，非空时优先返回它，保证
/// 「同一个源、同一个站点」的行为与改动前一致。
Duration? resolveResumeStart({
  required List<VodPlayLine> lines,
  required ResumeSeed? seed,
  required VodPlayLine targetLine,
  required int targetEpisodeIndex,
  required String targetEpisodeName,
  required int targetDurationMs,
  Duration? fallback,
}) {
  if (fallback != null) return fallback;
  if (seed == null || !seed.hasPosition) return null;
  final sameEpisode = resumeEpisodeMatches(
    lines: lines,
    seed: seed,
    targetLine: targetLine,
    targetEpisodeIndex: targetEpisodeIndex,
    targetEpisodeName: targetEpisodeName,
  );
  final migration = ResumePositionPolicy.migrate(
    sourcePositionMs: seed.positionMs,
    sourceDurationMs: seed.durationMs,
    targetDurationMs: targetDurationMs,
    sameEpisode: sameEpisode,
    sourceCompleted: seed.completed,
  );
  if (migration == null) return null;
  return Duration(milliseconds: migration.positionMs);
}

/// 历史页的三种模式。
enum HistoryViewMode {
  /// 默认：点卡片按「点击行为」设置分流。
  none,

  /// 长按进入的删除态：点卡片即删该条（对齐上游 `HistoryAdapter#setDelete`）。
  singleDelete,

  /// 「批量删除」按钮进入的多选态：点卡片切换勾选。
  multiSelect,
}

/// 不可变的历史页视图状态。
class HistoryViewState {
  const HistoryViewState({
    required this.mode,
    required this.selectedIds,
    required this.keyword,
  });

  /// 初始态。
  static const HistoryViewState initial = HistoryViewState(
    mode: HistoryViewMode.none,
    selectedIds: <int>{},
    keyword: '',
  );

  final HistoryViewMode mode;

  /// 已勾选的历史记录 id。仅 [HistoryViewMode.multiSelect] 有意义。
  final Set<int> selectedIds;

  /// **上一次已知的**搜索词。
  ///
  /// 它同时是 [withKeyword] 的比较基准：**任何**转移都不得重置它，
  /// 否则基准漂移会导致每次 `setState` 都清空用户的勾选。
  final String keyword;

  HistoryViewState copyWith({
    HistoryViewMode? mode,
    Set<int>? selectedIds,
    String? keyword,
  }) => HistoryViewState(
    mode: mode ?? this.mode,
    selectedIds: selectedIds ?? this.selectedIds,
    keyword: keyword ?? this.keyword,
  );

  /// 进入删除态（长按）。清空选中集——删除态没有"选中集"概念。
  HistoryViewState enterSingleDelete() =>
      copyWith(mode: HistoryViewMode.singleDelete, selectedIds: const <int>{});

  /// 进入多选态（批量删除按钮）。清空选中集，避免带上上一次的残留。
  HistoryViewState enterMultiSelect() =>
      copyWith(mode: HistoryViewMode.multiSelect, selectedIds: const <int>{});

  /// 退出到默认态。保留 [keyword]。
  HistoryViewState exitMode() =>
      copyWith(mode: HistoryViewMode.none, selectedIds: const <int>{});

  /// 切换某条记录的勾选。非多选态下**不产生**选中。
  HistoryViewState toggleSelection(int id) {
    if (mode != HistoryViewMode.multiSelect) return this;
    final next = <int>{...selectedIds};
    if (!next.remove(id)) next.add(id);
    return copyWith(selectedIds: next);
  }

  /// 全选：只勾选传入的**可见** id，不动已有的其他勾选。
  HistoryViewState selectAll(List<int> visibleIds) {
    if (mode != HistoryViewMode.multiSelect) return this;
    return copyWith(selectedIds: {...selectedIds, ...visibleIds});
  }

  /// 清空勾选。
  HistoryViewState clearSelection() =>
      copyWith(selectedIds: const <int>{});

  /// 更新搜索词。**变化时清空勾选**，未变化时返回同一实例。
  ///
  /// 为什么变化时必须清空：用户可能在多选态下搜索缩小范围，此时已勾选但
  /// **已不可见**的条目若仍留在 [selectedIds] 里，点「删除选中(N)」会删掉
  /// 用户看不见的条目。
  ///
  /// 为什么未变化时必须返回 `this`：调用方在 `setState` 里无条件调它，
  /// 每次都返回新实例会让用户刚勾的项被清空。
  HistoryViewState withKeyword(String next) {
    if (next == keyword) return this;
    return copyWith(keyword: next, selectedIds: const <int>{});
  }

  /// 是否可以执行批量删除。
  bool get canDeleteSelected =>
      mode == HistoryViewMode.multiSelect && selectedIds.isNotEmpty;

  /// 已勾选的 id，**升序**。稳定顺序便于测试断言与"全选"的幂等性。
  List<int> get selectedInOrder => selectedIds.toList()..sort();
}

/// 「点击历史记录」的行为（`docs/phase6/design/01` §4.1）。
///
/// 存字符串而不是 enum：本层是纯逻辑层，且要与 `settings.json` 的
/// 字面值一一对应（与 `UiThemeMode` 同样的分层理由）。
abstract final class UiHistoryClickAction {
  /// 打开该条对应的详情页（默认）。
  static const String detail = 'detail';

  /// 直接续播（既有行为）。
  static const String play = 'play';

  static const List<String> values = [detail, play];

  /// 把任意输入归一化成合法值；不认识的值回落到默认 [detail]。
  static String normalize(String? raw) {
    final value = raw?.trim().toLowerCase() ?? '';
    return values.contains(value) ? value : detail;
  }
}
