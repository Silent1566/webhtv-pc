/// 片头/片尾跳过的纯决策逻辑（`docs/phase9/design/01` §3）。
///
/// 不碰播放器：只回答「现在该不该跳、跳到哪」。播放器负责调用 seek 并把
/// 「本集已经跳过一次」写回，避免用户手动拖回片头后又被自动跳走。
///
/// 语义：
/// - 每集**只自动跳一次**（由调用方的 `introDone`/`outroDone` 保证）；
/// - 续播位置已经在片头之后时**不跳**（否则会把用户拉回开头）；
/// - 片尾跳转的目标是 `durationMs`，随后由正常的「真正播完」判定走连播；
/// - 非法区间（负数、越界、intro >= outro）一律忽略，不抛异常。
library;

/// 跳转动作。
enum SkipAction {
  /// 不跳。
  none,

  /// 跳到片头结束点。
  intro,

  /// 跳到片尾（视频结尾）。
  outro,
}

/// 一次跳转决策。
class SkipDecision {
  const SkipDecision._(this.action, this.targetMs);

  const SkipDecision.none() : this._(SkipAction.none, 0);

  const SkipDecision.intro(int targetMs) : this._(SkipAction.intro, targetMs);

  const SkipDecision.outro(int targetMs) : this._(SkipAction.outro, targetMs);

  final SkipAction action;

  /// 目标位置（毫秒）；[action] == [SkipAction.none] 时为 0。
  final int targetMs;

  bool get shouldSeek => action != SkipAction.none;

  @override
  String toString() => 'SkipDecision($action, $targetMs)';
}

/// 某部影片的片头/片尾标记（毫秒）。
class SkipSegments {
  const SkipSegments({this.introEndMs, this.outroStartMs});

  /// 无标记。
  const SkipSegments.none() : this();

  /// 片头结束点（正片开始）。null = 未标记。
  final int? introEndMs;

  /// 片尾开始点（正片结束）。null = 未标记。
  final int? outroStartMs;

  bool get isEmpty => introEndMs == null && outroStartMs == null;

  bool get hasIntro => introEndMs != null;

  bool get hasOutro => outroStartMs != null;

  /// 是否真的有可跳的内容（至少一个有效标记）。
  bool get active => !isEmpty;

  /// 按当前视频时长归一化：越界或顺序颠倒的标记被丢弃。
  ///
  /// - 片头：必须在 `(1s, duration - 1s)` 内；
  /// - 片尾：必须在 `(片头 + 1s, duration - 1s)` 内（没有片头时下界为 1s）。
  ///
  /// 为什么留 1s：`duration <= 0` 表示时长未知，此时任何标记都不可靠；
  /// 贴边标记会让「一开播就结束」。
  SkipSegments normalizedFor(int durationMs) {
    if (durationMs <= 0) return const SkipSegments.none();
    final lower = 1000;
    final upper = durationMs - 1000;
    if (upper <= lower) return const SkipSegments.none();

    final intro = introEndMs;
    final validIntro =
        intro != null && intro > lower && intro < upper ? intro : null;

    final outro = outroStartMs;
    final outroLower = validIntro == null ? lower : validIntro + 1000;
    final validOutro =
        outro != null && outro > outroLower && outro < upper ? outro : null;

    return SkipSegments(introEndMs: validIntro, outroStartMs: validOutro);
  }

  /// 决策：现在要不要跳。
  ///
  /// [positionMs] 会被夹到 `>= 0`；[durationMs] `<= 0` 时一律不跳。
  SkipDecision decide({
    required int positionMs,
    required int durationMs,
    required bool autoIntro,
    required bool autoOutro,
    required bool introDone,
    required bool outroDone,
  }) {
    if (durationMs <= 0) return const SkipDecision.none();
    final position = positionMs < 0 ? 0 : positionMs;
    if (position >= durationMs) return const SkipDecision.none();
    final segments = normalizedFor(durationMs);

    final intro = segments.introEndMs;
    if (autoIntro &&
        !introDone &&
        intro != null &&
        position < intro) {
      return SkipDecision.intro(intro);
    }

    final outro = segments.outroStartMs;
    if (autoOutro && !outroDone && outro != null && position >= outro) {
      return SkipDecision.outro(durationMs);
    }

    return const SkipDecision.none();
  }

  SkipSegments copyWith({int? introEndMs, int? outroStartMs}) => SkipSegments(
    introEndMs: introEndMs ?? this.introEndMs,
    outroStartMs: outroStartMs ?? this.outroStartMs,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    if (introEndMs != null) 'openingMs': introEndMs,
    if (outroStartMs != null) 'endingMs': outroStartMs,
  };

  /// 从历史记录/同步字段解析。非法值（含安卓哨兵）由调用方先过滤；
  /// 这里只接受正数。
  factory SkipSegments.fromMs({Object? openingMs, Object? endingMs}) {
    int? pick(Object? raw) {
      final value = switch (raw) {
        int v => v,
        num v => v.toInt(),
        String v => int.tryParse(v.trim()),
        _ => null,
      };
      return value != null && value > 0 ? value : null;
    }

    return SkipSegments(
      introEndMs: pick(openingMs),
      outroStartMs: pick(endingMs),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SkipSegments &&
      other.introEndMs == introEndMs &&
      other.outroStartMs == outroStartMs;

  @override
  int get hashCode => Object.hash(introEndMs, outroStartMs);

  @override
  String toString() =>
      'SkipSegments(intro=$introEndMs, outro=$outroStartMs)';
}
