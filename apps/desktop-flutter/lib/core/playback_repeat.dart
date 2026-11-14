/// 连播 / 循环的纯决策逻辑（`docs/phase9/design/01` §4）。
///
/// 不改播放器：只回答「这一集真正播完之后该做什么」。真正播完的判定由
/// Phase 7 的 `isGenuineEnd` 提供（缓存耗尽导致的提前 EOF **不算**）。
library;

/// 循环模式。
enum PlaybackRepeat {
  /// 关闭循环：按「自动连播」开关决定是否进下一集。
  off('off', '不循环'),

  /// 单集循环：EOF 后回到开头重播。
  one('one', '单集循环'),

  /// 列表循环：播到最后一集后回到第一集。
  all('all', '列表循环');

  const PlaybackRepeat(this.id, this.label);

  /// 落盘标识，**不得改名**。
  final String id;

  /// UI 中文名。
  final String label;

  static PlaybackRepeat fromId(String? raw) {
    final value = raw?.trim().toLowerCase() ?? '';
    for (final item in values) {
      if (item.id == value) return item;
    }
    return PlaybackRepeat.off;
  }

  static PlaybackRepeat fromIndex(int? raw) {
    if (raw == null || raw < 0 || raw >= values.length) return PlaybackRepeat.off;
    return values[raw];
  }
}

/// 播完一集后的动作。
enum PlaybackAdvanceAction {
  /// 重播当前集（单集循环）。
  replay,

  /// 播放指定下标的剧集。
  playIndex,

  /// 停止（不连播）。
  stop,
}

/// 连播裁决结果。
class PlaybackAdvance {
  const PlaybackAdvance._(this.action, this.nextIndex);

  const PlaybackAdvance.replay() : this._(PlaybackAdvanceAction.replay, null);

  const PlaybackAdvance.play(int index)
    : this._(PlaybackAdvanceAction.playIndex, index);

  const PlaybackAdvance.stop() : this._(PlaybackAdvanceAction.stop, null);

  final PlaybackAdvanceAction action;

  /// 仅 [action] == [PlaybackAdvanceAction.playIndex] 时非空。
  final int? nextIndex;

  @override
  String toString() => switch (action) {
    PlaybackAdvanceAction.replay => 'replay',
    PlaybackAdvanceAction.playIndex => 'play($nextIndex)',
    PlaybackAdvanceAction.stop => 'stop',
  };
}

/// 决定「真正播完」之后做什么。
///
/// 优先级：**循环模式 > 自动连播开关**。
/// - 非真正结束（失败/提前 EOF）→ [PlaybackAdvance.stop]，由失败路径处理；
/// - `one` → 重播当前集；
/// - `all` → 下一集，末集回到第 0 集；
/// - `off` → `autoNext` 为真才进下一集，否则停止。
///
/// 空列表返回 stop（不得构造非法下标）。
PlaybackAdvance decidePlaybackAdvance({
  required PlaybackRepeat repeat,
  required bool autoNext,
  required int currentIndex,
  required int episodeCount,
  required bool genuineEnd,
}) {
  if (!genuineEnd) return const PlaybackAdvance.stop();
  if (episodeCount <= 0) return const PlaybackAdvance.stop();
  if (currentIndex < 0 || currentIndex >= episodeCount) {
    return const PlaybackAdvance.stop();
  }

  switch (repeat) {
    case PlaybackRepeat.one:
      return const PlaybackAdvance.replay();
    case PlaybackRepeat.all:
      final next = currentIndex + 1;
      return PlaybackAdvance.play(next < episodeCount ? next : 0);
    case PlaybackRepeat.off:
      if (!autoNext) return const PlaybackAdvance.stop();
      final next = currentIndex + 1;
      return next < episodeCount
          ? PlaybackAdvance.play(next)
          : const PlaybackAdvance.stop();
  }
}
