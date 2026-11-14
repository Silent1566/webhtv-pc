/// 定时关闭的纯状态模型（`docs/phase9/design/01` §4.2）。
///
/// 计时器本身由播放器页持有（`Timer` + 单调时钟校正），这里只定义
/// 「何时该停」的语义，便于用固定时钟穷举测试。
///
/// 语义（已确认）：**退出播放器即取消，不跨进程持久化**——避免「重启后
/// 突然暂停」这种用户无法解释的行为。
library;

/// 定时关闭模式。
enum SleepTimerMode {
  /// 从设置时刻起算的倒计时。
  duration('duration', '倒计时'),

  /// 当前集播完时停止（不连播下一集）。
  endOfEpisode('endOfEpisode', '本集结束');

  const SleepTimerMode(this.id, this.label);

  final String id;
  final String label;
}

/// 一次定时关闭计划。不可变；修改即生成新计划。
class SleepTimerPlan {
  const SleepTimerPlan._({
    required this.mode,
    this.duration,
    this.deadline,
  });

  /// 空闲（未开启定时）。
  const SleepTimerPlan.idle()
    : this._(mode: SleepTimerMode.duration, duration: null, deadline: null);

  /// 倒计时模式。[now] 可注入，便于测试。
  factory SleepTimerPlan.forDuration(Duration duration, {DateTime? now}) {
    final safe = duration < Duration.zero ? Duration.zero : duration;
    final base = now ?? DateTime.now();
    return SleepTimerPlan._(
      mode: SleepTimerMode.duration,
      duration: safe,
      deadline: base.add(safe),
    );
  }

  /// 本集结束模式。
  const SleepTimerPlan.untilEpisodeEnd()
    : this._(mode: SleepTimerMode.endOfEpisode);

  final SleepTimerMode mode;

  /// 倒计时总时长；[mode] != duration 时为 null。
  final Duration? duration;

  /// 到点时刻；[mode] != duration 时或空闲时为 null。
  final DateTime? deadline;

  /// 是否处于开启状态。
  bool get active =>
      mode == SleepTimerMode.endOfEpisode || deadline != null;

  /// 是否空闲（等价于 `!active`）。
  bool get idle => !active;

  /// 倒计时剩余时长。
  ///
  /// - 空闲或本集结束模式 → null；
  /// - 已过期 → [Duration.zero]（不返回负数）。
  Duration? remaining(DateTime now) {
    final target = deadline;
    if (target == null) return null;
    final left = target.difference(now);
    return left.isNegative ? Duration.zero : left;
  }

  /// 倒计时是否已到点。本集结束模式恒为 false（由剧集结束事件驱动）。
  bool isExpired(DateTime now) =>
      mode == SleepTimerMode.duration &&
      deadline != null &&
      !now.isBefore(deadline!);

  /// 本集播完时是否应停止（不再连播）。
  bool shouldStopOnEpisodeEnd() => mode == SleepTimerMode.endOfEpisode;

  /// 供 UI 显示的摘要。
  String get summary {
    if (idle) return '关闭';
    if (mode == SleepTimerMode.endOfEpisode) return '本集结束后关闭';
    final total = duration ?? Duration.zero;
    final minutes = total.inMinutes;
    if (minutes >= 1 && total.inSeconds % 60 == 0) return '$minutes 分钟后关闭';
    return '${total.inSeconds} 秒后关闭';
  }

  @override
  String toString() => 'SleepTimerPlan($summary)';
}

/// 预设时长（分钟）：与设计文档一致，UI 与测试共用，避免两处漂移。
const List<int> kSleepTimerMinutes = [15, 30, 60, 90];
