/// 运行中引擎错误的确认闸门（`docs/reference/xiugou-tv-borrowings.md` §3.3）。
///
/// 引擎的 `error` 流里既有致命失败，也有「无声卡」「无 GPU」「字幕轨缺失」这类
/// 非致命告警；直接拿第一条当播放失败会把正常播放判死，完全忽略又会让真正的
/// 断流只剩一句没头没尾的日志。这里先形成**可信诊断**，再交给页面做一次动作：
///
/// 1. **待定期新错误只换文本，不延长计时**——错误风暴不该把结论越推越远；
/// 2. **同一条错误重复上报不重启计时**；
/// 3. **位置仍在推进 → 不提交**，已提交的结论要撤销（recovered）；
/// 4. **暂停/缓冲/用户定位中 → 不提交**：位置不动是用户造成的，不是失败证据；
/// 5. **换媒体（代际变化）→ 全部清空**：上一部片的错误不得判这一部失败。
library;

/// 一次 `offer`/`observe` 的结论。
enum PlaybackErrorGateAction {
  /// 没有待定错误，也没有结论。
  idle,

  /// 有错误但还不构成失败证据。
  pending,

  /// 已确认：位置停住了且过了观察窗口。
  committed,

  /// 之前提交过的结论被推翻（位置又推进了）。
  recovered,
}

class PlaybackErrorGate {
  PlaybackErrorGate({this.window = const Duration(seconds: 8)});

  /// 从「开始报错」到「允许判定失败」的观察窗口。
  final Duration window;

  /// 位置要推进这么多才算「还在播」：毫秒级抖动不是证据。
  static const Duration progressGrace = Duration(seconds: 1);

  String? _message;
  DateTime? _since;
  Duration? _positionAtStart;
  Duration? _lastPosition;
  int? _generation;
  bool _committed = false;

  /// 最近一条错误文本；未提交时它只是诊断材料。
  String? get message => _message;

  /// 是否有待定错误（还没形成结论）。
  bool get pending => _message != null;

  /// 是否已确认失败。
  bool get committed => _committed;

  /// 清空一切（用户手动重试/关闭后调用）。
  void dismiss() {
    _message = null;
    _since = null;
    _positionAtStart = null;
    _lastPosition = null;
    _committed = false;
  }

  /// 引擎报了新错误。
  PlaybackErrorGateAction offer({
    required String message,
    required int generation,
    required Duration position,
    required DateTime at,
    required bool playing,
    required bool buffering,
    required bool seeking,
  }) {
    if (_generation != generation) {
      _generation = generation;
      dismiss();
    }
    if (message.trim().isNotEmpty) _message = message;
    if (_message == null) return PlaybackErrorGateAction.idle;
    return _evaluate(
      position: position,
      at: at,
      playing: playing,
      buffering: buffering,
      seeking: seeking,
    );
  }

  /// 位置/状态采样（由播放通知驱动）。
  PlaybackErrorGateAction observe({
    required int generation,
    required Duration position,
    required DateTime at,
    required bool playing,
    required bool buffering,
    required bool seeking,
  }) {
    if (_generation != generation) {
      _generation = generation;
      dismiss();
      return PlaybackErrorGateAction.idle;
    }
    if (_message == null) return PlaybackErrorGateAction.idle;
    return _evaluate(
      position: position,
      at: at,
      playing: playing,
      buffering: buffering,
      seeking: seeking,
    );
  }

  PlaybackErrorGateAction _evaluate({
    required Duration position,
    required DateTime at,
    required bool playing,
    required bool buffering,
    required bool seeking,
  }) {
    final regressed = _lastPosition != null && position < _lastPosition!;
    _lastPosition = position;
    if (!playing || buffering || seeking) {
      _since = null;
      _positionAtStart = position;
      return _committed
          ? PlaybackErrorGateAction.committed
          : PlaybackErrorGateAction.pending;
    }
    if (regressed) {
      _since = at;
      _positionAtStart = position;
    }
    _positionAtStart ??= position;
    final baseline = _positionAtStart!;
    if (position - baseline >= progressGrace) {
      final wasCommitted = _committed;
      dismiss();
      return wasCommitted
          ? PlaybackErrorGateAction.recovered
          : PlaybackErrorGateAction.idle;
    }
    if (_committed) return PlaybackErrorGateAction.committed;
    // 只累计连续可观察的播放窗口；错误风暴只更新文本。
    _since ??= at;
    if (at.difference(_since!) >= window) {
      _committed = true;
      return PlaybackErrorGateAction.committed;
    }
    return PlaybackErrorGateAction.pending;
  }
}
