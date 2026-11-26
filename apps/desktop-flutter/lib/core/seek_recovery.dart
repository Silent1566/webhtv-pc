/// seek 失败恢复的判据（`docs/reference/xiugou-tv-borrowings.md` §3.2）。
///
/// 页面上要回答的是三件事：这次跳转有没有真的到位、算不算失败、失败后给用户
/// 哪两个出口。判据全部放在这里，页面只负责记录与呈现，方便逐条断言。
///
/// 三条硬规则：
/// 1. **暂停/缓冲/引擎定位中既不算到位也不算失败**——这三种状态下位置本来就不
///    推进，或者引擎报了目标值却没解码出画面；拿它们当证据会得出反向结论。
/// 2. **只有真的播起来并停在目标附近才算成功**。
/// 3. **旧媒体代际的跳转一律作废**：上一部片的未落地跳转不得污染这一部。
library;

/// 一次跳转尝试。
class SeekRecovery {
  const SeekRecovery({
    required this.origin,
    required this.target,
    required this.generation,
    required this.startedAt,
  });

  /// 跳转前的位置：失败时「返回原位置」用它。
  final Duration origin;

  /// 用户要去的目标位置。
  final Duration target;

  /// 发起跳转时的媒体代际（`_PlayerPageState._mediaGeneration`）。
  final int generation;

  /// 发起跳转的时刻。
  final DateTime startedAt;

  /// 原位置与目标重合时没有可恢复的差异，不必给出口。
  bool get recoverable => origin != target;

  @override
  String toString() =>
      'SeekRecovery(generation=$generation origin=${origin.inMilliseconds}ms '
      'target=${target.inMilliseconds}ms)';
}

/// 一次跳转现在是什么状态。
enum SeekRecoveryVerdict {
  /// 还看不出来：窗口未到，或处于暂停/缓冲/定位中。
  pending,

  /// 真的播到了目标附近。
  settled,

  /// 窗口内始终没到目标。
  failed,
}

/// 「到了」的容差：跳转落点允许的毫秒级偏差。
const Duration seekSettleTolerance = Duration(seconds: 3);

/// 「没到」的观察窗口。与 `PlayerController.repositionGuardTimeout` 同量级：
/// 遮罩兜底撤除之后用户才可能看到这个出口，窗口比它短就等于对着还没落地的
/// 跳转报失败。
const Duration seekFailureWindow = Duration(seconds: 20);

/// 判定这次跳转的状态。
SeekRecoveryVerdict evaluateSeekRecovery({
  required SeekRecovery recovery,
  required int generation,
  required Duration enginePosition,
  Duration? previousEnginePosition,
  required bool enginePositionSeen,
  required bool playing,
  required bool buffering,
  required bool isSeeking,
  required DateTime now,
  bool pausedByUser = false,
  bool endOfMedia = false,
}) {
  // 换过媒体了：这条记录属于上一部片，任何结论都不成立。
  if (recovery.generation != generation) return SeekRecoveryVerdict.pending;
  // 缓冲/引擎定位中：位置不动是正常的，不能当失败，也不会真的到位。
  if (buffering || isSeeking) return SeekRecoveryVerdict.pending;
  // 用户暂停、自然片尾、错误后被替换的旧媒体：不走位置是这些状态本身造成的。
  if (pausedByUser || endOfMedia || !playing) {
    return SeekRecoveryVerdict.pending;
  }
  // 引擎还没上报过真实位置：拿占位值判断会在首帧上屏前就宣布结果。
  if (!enginePositionSeen) return SeekRecoveryVerdict.pending;
  final behind = recovery.target - enginePosition;
  final ahead = enginePosition - recovery.target;
  final delta = behind.isNegative ? ahead : behind;
  if (delta <= seekSettleTolerance) {
    // 单次上报目标值可能是 seek 前最后一帧的回声，必须看到继续推进才算到位。
    if (previousEnginePosition != null &&
        (previousEnginePosition - recovery.target).inMilliseconds.abs() <=
            seekSettleTolerance.inMilliseconds &&
        enginePosition > previousEnginePosition) {
      return SeekRecoveryVerdict.settled;
    }
    if (now.difference(recovery.startedAt) < seekFailureWindow) {
      return SeekRecoveryVerdict.pending;
    }
    return SeekRecoveryVerdict.failed;
  }
  if (now.difference(recovery.startedAt) >= seekFailureWindow) {
    return SeekRecoveryVerdict.failed;
  }
  return SeekRecoveryVerdict.pending;
}

extension SeekRecoveryRebase on SeekRecovery {
  /// 观察窗口只累计**可观察的播放时间**：暂停/缓冲期间不算数。
  SeekRecovery rebased(DateTime at, {int? generation}) => SeekRecovery(
    origin: origin,
    target: target,
    generation: generation ?? this.generation,
    startedAt: at,
  );
}
