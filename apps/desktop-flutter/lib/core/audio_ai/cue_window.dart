/// PC 不延迟播放器：ASR 在语音端点返回，显示窗口从可呈现的位置开始。
/// 已超过语音结尾宽限的结果丢弃；有效端点结果保留有限的阅读时间。
library;

const Duration kCueEndGrace = Duration(milliseconds: 500);
const Duration kMaxCueDuration = Duration(milliseconds: 6500);
const Duration kMinCueVisible = Duration(milliseconds: 900);
const int kMinCueDurationPercent = 75;

class CueWindow {
  const CueWindow({required this.start, required this.end});
  final Duration start;
  final Duration end;
  @override
  bool operator ==(Object other) =>
      other is CueWindow && other.start == start && other.end == end;
  @override
  int get hashCode => Object.hash(start, end);
  @override
  String toString() => 'CueWindow($start..$end)';
}

class CueWindowPlanner {
  const CueWindowPlanner();

  CueWindow? plan({
    required Duration start,
    required Duration end,
    required Duration presented,
  }) {
    final safeStart = start.isNegative ? Duration.zero : start;
    final safeEnd = end < safeStart ? safeStart : end;
    if (presented > safeEnd + kCueEndGrace) return null;
    final rawEnd = safeEnd + kCueEndGrace;
    final capEnd = safeStart + kMaxCueDuration;
    final originalEnd = rawEnd < capEnd ? rawEnd : capEnd;
    final desired = originalEnd - safeStart;
    final percent = desired * kMinCueDurationPercent ~/ 100;
    final minimum = desired < (kMinCueVisible > percent ? kMinCueVisible : percent)
        ? desired
        : (kMinCueVisible > percent ? kMinCueVisible : percent);
    final visibleStart = safeStart > presented ? safeStart : presented;
    final readableEnd = visibleStart + minimum;
    final visibleEnd = originalEnd > readableEnd ? originalEnd : readableEnd;
    final maximumEnd = visibleStart + kMaxCueDuration;
    return CueWindow(
      start: visibleStart,
      end: visibleEnd < maximumEnd ? visibleEnd : maximumEnd,
    );
  }

  bool contains(CueWindow window, Duration position) =>
      position >= window.start && position < window.end;
}
