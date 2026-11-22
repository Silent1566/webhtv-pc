/// 弹幕运动时钟（`docs/phase9/design/02-subtitle-danmaku.md` §2.4「渲染时钟」）。
///
/// 为什么需要它：弹幕位置原本直接取 `PlayerController.position`，而那是
/// **事件驱动的离散值**（播放器每上报一次位置，整页才重建一次）。两次上报之间
/// 画面上的弹幕是不动的，用户看到的就是「一格一格跳」，越慢的弹幕越明显。
/// 这里把离散位置按墙钟插值成每帧连续位置。
///
/// 三条边界（都有单测锁着）：
/// - 暂停不动：`playing == false` 时原样返回基准位置；
/// - 跳转立即跟随：上报位置与插值结果相差超过 [reanchorToleranceMs] 视为拖动
///   进度条/切集，直接对表；
/// - 断流不飞：上报停了（缓冲、卡住）时最多外插 [maxExtrapolationMs]，
///   之后停在原地等下一次上报，而不是按墙钟一路飘走。
library;

/// 把播放器的离散位置插值成每帧连续位置。
///
/// 时间源由调用方传入（[DateTime]），因此可以脱离真实时钟做确定性测试。
class DanmakuMotionClock {
  DanmakuMotionClock({
    this.maxExtrapolationMs = defaultMaxExtrapolationMs,
    this.reanchorToleranceMs = defaultReanchorToleranceMs,
  });

  /// 上报断流后最多外插多久（毫秒）。
  ///
  /// 取值大于常见上报间隔（~250ms）以免正常播放时被这个上限拖住，
  /// 又足够短，缓冲卡住时不会让弹幕飞出画面半天才对上。
  static const int defaultMaxExtrapolationMs = 600;

  /// 上报位置与插值结果在多大幅度内算「同一次播放」（毫秒）。
  static const int defaultReanchorToleranceMs = 120;

  final int maxExtrapolationMs;
  final int reanchorToleranceMs;

  Duration _anchor = Duration.zero;
  Duration? _lastReported;
  DateTime? _anchorAt;
  bool _playing = false;
  double _rate = 1;

  /// 最近一次对表的播放位置（暂停时就是它）。
  Duration get anchor => _anchor;

  /// 最近一次对表的播放器上报值（未收到上报前为 null）。
  Duration? get lastReported => _lastReported;

  bool get isPlaying => _playing;
  double get rate => _rate;

  /// 用播放器上报的位置对表。
  ///
  /// 播放器每次 `notifyListeners`（音量、缓冲、进度……）都会把同一个位置再传一遍；
  /// 这种情况**不能**把基准时间重置成「现在」，否则插值会一直停在原地。
  /// 只有位置、播放状态或倍速真的变了才重新对表。
  void sync({
    required Duration position,
    required bool playing,
    required double rate,
    required DateTime at,
  }) {
    final reported = position.isNegative ? Duration.zero : position;
    final motionChanged =
        _anchorAt == null || _playing != playing || this.rate != rate;
    _lastReported = reported;
    if (motionChanged) {
      _playing = playing;
      _rate = rate;
      _anchor = reported;
      _anchorAt = at;
      return;
    }
    _anchor = _reconcile(reported, at);
    _anchorAt = at;
  }

  /// 采样 [at] 时刻应使用的播放位置。
  Duration sample(DateTime at) {
    final anchorAt = _anchorAt;
    if (anchorAt == null) return Duration.zero;
    if (!_playing) return _anchor;
    return _extrapolate(at);
  }

  /// 把上报值揉进当前插值轨迹。
  Duration _reconcile(Duration reported, DateTime at) {
    if (!_playing || _anchorAt == null) return reported;
    final live = _extrapolate(at);
    final tolerance = Duration(milliseconds: reanchorToleranceMs);
    // 明显跳变（拖动进度条、切集、换源）：信上报值。
    if (reported < live - tolerance || reported > live + tolerance) {
      return reported;
    }
    // 上报值落在插值附近：保持轨迹连续，绝不往回退一格。
    return reported > live ? reported : live;
  }

  Duration _extrapolate(DateTime at) {
    final anchorAt = _anchorAt;
    if (anchorAt == null) return _anchor;
    var elapsedUs = (at.difference(anchorAt).inMicroseconds * _rate).round();
    if (elapsedUs <= 0) return _anchor;
    final capUs = maxExtrapolationMs * 1000;
    if (elapsedUs > capUs) elapsedUs = capUs;
    return Duration(microseconds: _anchor.inMicroseconds + elapsedUs);
  }
}
