/// 弹幕运动时钟（`docs/phase9/design/02-subtitle-danmaku.md` §2.4「渲染时钟」）。
///
/// 为什么需要它：弹幕位置原本直接取 `PlayerController.position`，而那是
/// **事件驱动的离散值**（播放器每上报一次位置，整页才重建一次）。两次上报之间
/// 画面上的弹幕是不动的，用户看到的就是「一格一格跳」，越慢的弹幕越明显。
/// 这里把离散位置按墙钟插值成每帧连续位置。
///
/// 五条边界（都有单测锁着）：
/// - 暂停不动：`playing == false` 时原样返回基准位置；
/// - 跳转立即跟随：播放器明确报告的定位（[sync] 的 `seeking`）结束时立即对表，
///   前跳只要超过 [reanchorToleranceMs] 也直接对表；
/// - 普通播放不回头：没有定位信号的后退，小幅当抖动、中幅等上报追上、
///   超过 [maxExtrapolationMs] 才当时间轴整体重置——绝不因一个旧上报往回退一格；
/// - 断流不飞：上报停了（缓冲、卡住）时最多外插 [maxExtrapolationMs]，
///   之后停在原地等下一次上报，而不是按墙钟一路飘走；
/// - 重复上报不倒退：同一个位置再报一次不算新信息，不重新对表，也不刷新
///   外插截止时间（否则上限会被这些重复上报无限续期）；
/// - 停滞冻结：`held`（加载/缓冲/定位）期间停在当前画面位置不推进，恢复时
///   落后不到 [reanchorToleranceMs / maxExtrapolationMs] 就先等上报追上再对齐（追赶时长有界）。
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
  bool _held = false;
  bool _seeking = false;
  bool _awaitingCatchUp = false;

  /// 待确认的「时间轴整体重置」候选位置。
  ///
  /// 没有定位信号时，一个大幅后退可能是循环/断点（应当跟随），也可能是
  /// 迟到的旧上报（跟随就是回退）。两者靠**下一条上报**区分：先冻住，
  /// 下一条仍停在新位置才跟随，跳回原处就取消。
  Duration? _pendingReset;

  /// 当前画面位置：播放中是插值结果；暂停、停滞、追齐等待时就是钉住的那一帧。
  Duration get anchor => _anchor;

  /// 最近一次收到的播放器上报值（未必对过表，见 [sync]；未收到前为 null）。
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
    bool held = false,
    bool seeking = false,
  }) {
    final reported = position.isNegative ? Duration.zero : position;
    final previous = _lastReported;
    final motionChanged =
        _anchorAt == null || _playing != playing || this.rate != rate;
    // 结算点必须在改动播放状态/倍速之前取：这一段墙钟要用**旧**倍率算，
    // 否则「暂停的同时改倍速」这类事件会把已经过去的区间重算一遍。
    final wasPlaying = _playing;
    final renderedBeforeUpdate =
        _anchorAt == null ? null : (wasPlaying ? _extrapolate(at) : _anchor);
    _lastReported = reported;
    final wasHeld = _held;
    final catchingUp = _awaitingCatchUp;
    final wasSeeking = _seeking;
    _seeking = seeking;

    if (seeking || held) {
      // 画面停滞（加载/缓冲/定位）：冻结在当前**画面位置**上，不采纳上报值。
      // 只在进入停滞时钉一次，之后既不对表也不随时间推进。
      if (!wasHeld) {
        if (renderedBeforeUpdate == null) {
          // 还没画出过任何一帧（例如页面一进来就在加载）：没有「当前画面位置」
          // 可冻结，直接用上报值，别停在 0 再跳一次。
          _anchor = reported;
        } else if (wasPlaying && !catchingUp) {
          // 只把「上一次同步到现在」这段算成播放时间：暂停时墙钟不走，追齐等待
          // 期间画面本来就是钉住的。倍率用的是上面取好的旧值。
          _anchor = renderedBeforeUpdate;
        }
        _anchorAt = at;
      }
      _held = true;
      _awaitingCatchUp = false;
      _playing = playing;
      _rate = rate;
      return;
    }

    _held = false;
    _playing = playing;
    _rate = rate;

    if (wasSeeking) {
      // 播放器报告定位结束：上报值就是它跳到的位置，直接对表。
      // 这是「拖动立即跟随」的唯一入口——不去猜「倒退多少才算拖动」。
      _anchor = reported;
      _anchorAt = at;
      _awaitingCatchUp = false;
      _pendingReset = null;
      return;
    }

    if (wasHeld || catchingUp) {
      _reconcileRelease(at, reported);
      return;
    }

    if (motionChanged) {
      // 暂停 / 改倍速不是拖动：视频位置没有跳，画面也不该跳。按旧倍率把画面
      // 结算到此刻，只有上报值真的更靠前时才前进——否则一按暂停，弹幕就会被
      // 拉回最近一次上报（最多一个上报间隔，又是一次可见回退）。
      // `renderedBeforeUpdate` 在暂停时就是钉住的那一帧，所以这里不需要再判
      // 有没有在播放：有画面就用画面，没有才退回上报值。
      if (renderedBeforeUpdate != null) {
        _anchor = reported > renderedBeforeUpdate ? reported : renderedBeforeUpdate;
      } else {
        _anchor = reported;
      }
      _anchorAt = at;
      return;
    }
    // 同一个位置再报一次不是新信息：既不能重新对表（`_reconcile` 会把落后
    // 插值 120ms 以上的旧值当 seek，把已经走到前面的弹幕拉回去），也不能把
    // 基准时间推到现在（外插截止会被这些重复上报无限续期）。
    if (reported == previous) return;
    _anchor = _reconcile(reported, at);
    _anchorAt = at;
  }

  /// 解除停滞（或追帧中）收到的上报。
  ///
  /// 停滞把画面钉在 [_anchor]；恢复时上报若还落在它后面、且落后不到
  /// [reanchorToleranceMs / maxExtrapolationMs]，就地等上报追上再对齐——否则画面会倒退一格。
  /// 等待长度就是「落后幅度」本身：上报按媒体速率前进，追赶时间
  /// ≤ 落后幅度 / rate（1x 下 < 1s，因为能进这里的落后幅度都小于下限）。
  void _reconcileRelease(DateTime at, Duration reported) {
    final frozen = _anchor;
    final cap = Duration(milliseconds: maxExtrapolationMs);
    if (_awaitingCatchUp) {
      final pending = _pendingReset;
      if (pending != null) {
        // 确认窗口：下一条上报仍在候选位置附近 ⇒ 这是真的重置，跟随。
        final away = reported > pending ? reported - pending : pending - reported;
        if (away <= cap) {
          _anchor = reported;
          _anchorAt = at;
          _awaitingCatchUp = false;
          _pendingReset = null;
          return;
        }
        // 它又跳回去了：刚才那条只是迟到的旧上报，沿原轨迹继续前进。
        _pendingReset = null;
        _awaitingCatchUp = false;
        _anchorAt = at;
        return;
      }
      if (reported >= frozen) {
        _anchor = reported;
        _anchorAt = at;
        _awaitingCatchUp = false;
        return;
      }
      // 落后超过一次外插上限：可能整体重置，也可能只是一条迟到很久的旧上报。
      // 冻在这里等下一条件证——两种结局都不回退。
      if (frozen - reported > cap) _pendingReset = reported;
      return;
    }
    final behind = frozen - reported;
    if (reported < frozen && behind <= cap) {
      _awaitingCatchUp = true;
      _anchorAt = at;
      return;
    }
    // 追上了、超过了，或大幅重置：直接对表。
    // 停滞期间的墙钟时间不是播放时间，这里绝不能按墙钟外插。
    _anchor = reported;
    _anchorAt = at;
  }

  /// 采样 [at] 时刻应使用的播放位置。
  Duration sample(DateTime at) {
    final anchorAt = _anchorAt;
    if (anchorAt == null) return Duration.zero;
    if (_held || _awaitingCatchUp || !_playing) return _anchor;
    return _extrapolate(at);
  }

  /// 把上报值揉进当前插值轨迹。
  Duration _reconcile(Duration reported, DateTime at) {
    if (!_playing || _anchorAt == null) return reported;
    final live = _extrapolate(at);
    final tolerance = Duration(milliseconds: reanchorToleranceMs);
    final cap = Duration(milliseconds: maxExtrapolationMs);
    // 明显前跳（换源、直播回到最新）：信上报值。
    if (reported > live + tolerance) return reported;
    final behind = live - reported;
    if (behind <= tolerance) {
      // 落在抖动范围内：保持轨迹连续，绝不往回退一格。
      return live;
    }
    if (behind > cap) {
      // 落后超过一次外插上限：可能整体重置，也可能是一条迟到的旧上报。
      // 冻住并记下候选，由下一条上报确认——确认是重置才跟随。
      _pendingReset = reported;
      _awaitingCatchUp = true;
      _anchorAt = at;
      return live;
    }
    // 明显落后但还够不上「重置」：这是重缓冲/上报滞后留下的提前量。
    // 停在当前画面等上报追上来，而不是把这段差永久留在那里。
    _awaitingCatchUp = true;
    _anchorAt = at;
    return live;
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
