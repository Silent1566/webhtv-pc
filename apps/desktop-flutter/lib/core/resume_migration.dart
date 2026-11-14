/// 跨源续播的**进度迁移策略**（纯逻辑，可无窗口单测）。
///
/// 对应上游安卓 `ResumePositionPolicy`（`docs/global-history-resume-design.md` §13.3），
/// 逐条对齐后做了两处 PC 侧收敛：
///
/// 1. **不收 `History` 对象**：只收毫秒与时长标量，避免 `core/` 依赖
///    `services/storage.dart`（与 `history_view.dart` 同一分层理由）；
/// 2. **不发起任何请求**：时长由调用方先取到再传进来。
///
/// ## 规则（顺序固定）
///
/// 1. 目标集与源集**不是同一集** → 返回 `null`（清空进度，绝不错续播）；
/// 2. 源时长为 0（未取到）→ 沿用绝对位置（没有比例可算）；
/// 3. 时长差异 ≤ `max(10 分钟, 20%)` → 沿用**绝对毫秒**；
/// 4. 差异更大但身份与集数为高置信 → 按 `position / duration` **比例换算**；
/// 5. 结果夹取到 `[0, targetDuration - 5s]`；
/// 6. 接近结尾（源记录 completed，或换算后落在结尾 5s 内）→ 返回 `null`
///    （从头开始，对齐既有 `resumePositionFor` 与 `History.isNearEnding`）。
library;

/// 迁移结果。
class ResumeMigration {
  const ResumeMigration({
    required this.positionMs,
    required this.strategy,
  });

  /// 迁移到目标源后的**绝对毫秒**位置。
  final int positionMs;

  /// 采用的策略：`absolute` / `ratio` / `none`（`none` 表示不迁移）。
  final String strategy;

  static const String absolute = 'absolute';
  static const String ratio = 'ratio';
  static const String none = 'none';

  @override
  String toString() => 'ResumeMigration($positionMs ms, $strategy)';
}

/// 进度迁移策略（无状态工具类）。
abstract final class ResumePositionPolicy {
  /// 时长差异的绝对下限：10 分钟。
  static const Duration durationToleranceFloor = Duration(minutes: 10);

  /// 时长差异的相对比例：20%。
  static const double durationToleranceRatio = 0.2;

  /// 结尾保护区间：距结尾 5 秒内视为已看完。
  static const Duration endingGuard = Duration(seconds: 5);

  /// 位置下限：不足 5 秒不恢复（与 `AppState.resumeThreshold` 同值）。
  static const Duration resumeThreshold = Duration(seconds: 5);

  /// 迁移进度。
  ///
  /// [sourcePositionMs] / [sourceDurationMs]：原记录的进度与时长。
  /// [targetDurationMs]：目标源的时长；`<= 0` 表示未取到。
  /// [sameEpisode]：是否**已确证**是同一集（由调用方按 TMDB 季集 / 集名 / 集号
  /// 判定）。为 `false` 时一律不迁移——这是「宁可不续播，不可错续播」的
  /// 硬闸门（`docs/phase6/design/01` §4.1）。
  /// [sourceCompleted]：原记录是否已播完。
  static ResumeMigration? migrate({
    required int sourcePositionMs,
    required int sourceDurationMs,
    required int targetDurationMs,
    required bool sameEpisode,
    bool sourceCompleted = false,
  }) {
    if (!sameEpisode) return null;
    if (sourceCompleted) return null;
    if (sourcePositionMs < resumeThreshold.inMilliseconds) return null;

    // 源时长未知：没有比例可算，只能沿用绝对位置（再用目标时长夹取）。
    if (sourceDurationMs <= 0) {
      return _clampToTarget(
        sourcePositionMs,
        targetDurationMs,
        ResumeMigration.absolute,
      );
    }
    // 源记录已接近结尾：视为看完，从头开始。
    if (sourcePositionMs >
        sourceDurationMs - endingGuard.inMilliseconds) {
      return null;
    }
    // 目标时长未知：同样只能沿用绝对位置。
    if (targetDurationMs <= 0) {
      return ResumeMigration(
        positionMs: sourcePositionMs,
        strategy: ResumeMigration.absolute,
      );
    }

    final delta = (targetDurationMs - sourceDurationMs).abs();
    final toleranceFloor = durationToleranceFloor.inMilliseconds;
    final toleranceRatio = sourceDurationMs * durationToleranceRatio;
    if (delta <= toleranceFloor || delta <= toleranceRatio) {
      return _clampToTarget(
        sourcePositionMs,
        targetDurationMs,
        ResumeMigration.absolute,
      );
    }
    // 时长差异过大：按比例换算，避免把 40 分钟的进度落到 20 分钟的目标中段。
    final ratio = sourcePositionMs / sourceDurationMs;
    final scaled = (ratio * targetDurationMs).round();
    return _clampToTarget(scaled, targetDurationMs, ResumeMigration.ratio);
  }

  /// 夹取到 `[0, targetDuration - 5s]`；落在结尾保护区间时返回 `null`。
  static ResumeMigration? _clampToTarget(
    int positionMs,
    int targetDurationMs,
    String strategy,
  ) {
    if (positionMs <= 0) return null;
    if (targetDurationMs <= 0) {
      return ResumeMigration(positionMs: positionMs, strategy: strategy);
    }
    final ceiling = targetDurationMs - endingGuard.inMilliseconds;
    if (ceiling <= 0) return null;
    if (positionMs > ceiling) {
      // 换算后落到结尾：视为看完，从头开始，而不是停在结尾几秒。
      return null;
    }
    return ResumeMigration(positionMs: positionMs, strategy: strategy);
  }
}
