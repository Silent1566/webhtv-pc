import 'dart:math' as math;

import 'skip_plan.dart';

enum EpisodePreloadBatch { early, ending }

EpisodePreloadBatch? episodePreloadBatch({
  required int positionMs,
  required int durationMs,
  required int bufferedMs,
  required double rate,
  required SkipPlan plan,
  required SkipMode mode,
  required int kinds,
  required Set<String> handled,
  required bool earlyStarted,
  required bool endingStarted,
  bool preparingForSeek = false,
}) {
  if (!rate.isFinite || rate <= 0 || positionMs <= 0 || durationMs <= 0) {
    return null;
  }
  final transitionMs = episodePreloadTransitionMs(
    positionMs: positionMs,
    durationMs: durationMs,
    plan: plan,
    mode: mode,
    kinds: kinds,
    handled: handled,
  );
  final remaining = transitionMs - positionMs;
  final speed = rate.clamp(0.25, 4.0);
  if (remaining <= 0 ||
      (!preparingForSeek &&
          bufferedMs - positionMs < math.min(3000 * speed, remaining))) {
    return null;
  }
  if (!preparingForSeek &&
      durationMs <= 300000 &&
      !earlyStarted &&
      !endingStarted &&
      positionMs >= 3000 &&
      remaining > 5000 * speed) {
    return EpisodePreloadBatch.early;
  }
  // Leave time for JVM startup and both HLS playlists before the cut-over.
  // The JVM lease allows some drift in the predicted cut-over time.
  if (!endingStarted && remaining <= 25000 * speed) {
    return EpisodePreloadBatch.ending;
  }
  return null;
}

int episodePreloadTransitionMs({
  required int positionMs,
  required int durationMs,
  required SkipPlan plan,
  required SkipMode mode,
  required int kinds,
  required Set<String> handled,
}) {
  var transitionMs = durationMs;
  if (mode == SkipMode.auto) {
    for (final segment in plan.endings) {
      final entry = math.max(positionMs, segment.startMs);
      if (entry >= transitionMs) continue;
      final decision = plan.decide(
        positionMs: entry,
        durationMs: durationMs,
        kinds: kinds,
        mode: mode,
        handled: handled,
      );
      if (decision.openEnd) transitionMs = entry;
    }
  }
  return transitionMs;
}

/// 预载起点只有在实际清单仍覆盖它时才可套用。
///
/// 预载读到的是当时那份清单；前台重新 GET 时上游可能已改动（同一 URL、仍在
/// 新鲜期内、正文不同）。时长变短时把旧起点交给播放器会直接越过片尾，所以只在
/// 时长对得上时沿用，否则回落到正常打开。
bool preloadedStartFits({
  required int startMs,
  required int prefetchedDurationMs,
  required int actualDurationMs,
}) {
  if (startMs < 0 || prefetchedDurationMs <= 0 || actualDurationMs <= 0) {
    return false;
  }
  if (startMs >= actualDurationMs) return false;
  if (startMs == 0) return true;
  final drift = (actualDurationMs - prefetchedDurationMs).abs();
  final tolerance = (prefetchedDurationMs * 0.1).round();
  return drift <= (tolerance < 5000 ? 5000 : tolerance);
}

int episodePreloadStart({
  required int durationMs,
  required SkipPlan plan,
  required SkipMode mode,
  required int kinds,
}) {
  if (mode != SkipMode.auto) return 0;
  final decision = plan.decide(
    positionMs: 0,
    durationMs: durationMs,
    kinds: kinds & SkipKind.intro.bit,
    mode: mode,
  );
  return decision.shouldSeek && decision.targetMs < durationMs
      ? decision.targetMs
      : 0;
}
