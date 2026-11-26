/// 自动恢复换线时的「唯一同集」定位。
///
/// 为什么与 `locateEpisodeInLine` 分开：面板定位允许「找不到就回第 1 集」，那只是
/// 预览落点；**自动恢复**落错会让用户从头开始看另一集而毫无察觉。这里宁可跳过
/// 这条线路，也不猜、不按下标兜底。
///
/// 集号口径复用 `core/tmdb_title.dart` 的 [sourceEpisodeNumber]：跨站映射
/// （`core/history_cross_site.dart`）与进度迁移用的都是它，三处不能各写一份正则。
library;

import 'tmdb_title.dart';

/// 命中依据：集名相同。
const String lineMatchBasisEpisodeName = 'episode_name';

/// 命中依据：集号相同（命名习惯不同的常态）。
const String lineMatchBasisEpisodeNumber = 'episode_number';

/// 在目标线路里定位「正在看的这一集」的结果。
///
/// 只有**唯一**命中才算数：两条线路把预告命名成同一集号时，猜错比跳过更糟。
class LineEpisodeMatch {
  const LineEpisodeMatch.matched(this.index, this.basis) : skippedReason = null;

  const LineEpisodeMatch.skipped(this.skippedReason)
    : index = null,
      basis = null;

  /// 命中的集下标；未命中为 null。
  final int? index;

  /// 命中依据（日志用）。
  final String? basis;

  /// 未命中原因（日志用，不得用来拼用户提示）。
  final String? skippedReason;

  bool get matched => index != null;

  @override
  String toString() => matched
      ? 'LineEpisodeMatch(index=$index basis=$basis)'
      : 'LineEpisodeMatch.skipped($skippedReason)';
}

/// 唯一同集定位。
///
/// 判定顺序即优先级：集名完全相同 → 集号相同。两者都要求**恰好一处**命中。
LineEpisodeMatch locateUniqueEpisodeInLine({
  required List<String> names,
  required String currentName,
}) {
  if (names.isEmpty) {
    return const LineEpisodeMatch.skipped('目标线路没有剧集');
  }
  if (currentName.isEmpty) {
    return const LineEpisodeMatch.skipped('当前集没有名字，无法确认同一集');
  }
  final byName = <int>[
    for (var i = 0; i < names.length; i++)
      if (names[i] == currentName) i,
  ];
  if (byName.length == 1) {
    return LineEpisodeMatch.matched(byName.single, lineMatchBasisEpisodeName);
  }
  if (byName.length > 1) {
    return LineEpisodeMatch.skipped('集名在目标线路里重复 ${byName.length} 次，无法确定同一集');
  }
  final number = sourceEpisodeNumber(currentName);
  if (number <= 0) {
    return const LineEpisodeMatch.skipped('当前集名解析不出集号');
  }
  final season = sourceSeasonNumber(currentName);
  final byNumber = <int>[
    for (var i = 0; i < names.length; i++)
      if (sourceEpisodeNumber(names[i]) == number &&
          (season <= 0 ||
              sourceSeasonNumber(names[i]) <= 0 ||
              sourceSeasonNumber(names[i]) == season))
        i,
  ];
  if (byNumber.length == 1) {
    return LineEpisodeMatch.matched(
      byNumber.single,
      lineMatchBasisEpisodeNumber,
    );
  }
  if (byNumber.length > 1) {
    return LineEpisodeMatch.skipped(
      '集号 $number 在目标线路里命中 ${byNumber.length} 处，无法确定同一集',
    );
  }
  return LineEpisodeMatch.skipped('目标线路没有第 $number 集');
}
