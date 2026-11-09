/// 追番检查服务（Phase 9 · P2-1）。
///
/// 只做「拿站点详情 → 取线路集数 → 应用更新策略 → 持久化」这一条链；
/// 调度（何时调用）与 UI 通知由 `AppState`/页面负责，便于离线单测。
library;

import 'dart:async';
import 'dart:math' as math;

import '../core/following.dart';
import 'log_service.dart';
import 'storage.dart';

/// 解析一部剧在站点详情里的线路与集数。
typedef FollowingDetailResolver =
    Future<List<FollowingLineEpisodes>?> Function(Following item);

class FollowingCheckOutcome {
  const FollowingCheckOutcome({
    required this.following,
    required this.changed,
    required this.error,
  });

  final Following following;

  /// 是否发现新集。
  final bool changed;

  /// 失败原因（成功为空）。
  final String error;

  bool get ok => error.isEmpty;
}

class FollowingCheckSummary {
  const FollowingCheckSummary({
    required this.checked,
    required this.changed,
    required this.failed,
  });

  final int checked;
  final int changed;
  final int failed;

  static const FollowingCheckSummary empty = FollowingCheckSummary(
    checked: 0,
    changed: 0,
    failed: 0,
  );
}

class FollowingService {
  FollowingService({
    required this.database,
    required this.resolveLines,
    this.log,
    this.timeout = const Duration(seconds: 25),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final AppDatabase database;
  final FollowingDetailResolver resolveLines;
  final Duration timeout;
  /// 失败日志（可为 null）。
  final LogService? log;
  final DateTime Function() _now;

  bool _checking = false;

  bool get isChecking => _checking;

  List<Following> all() => database.followings();

  Following? byVod(String siteKey, String vodId) =>
      database.followingByVod(siteKey, vodId);

  Following? byKey(String seriesKey, int season) =>
      database.following(seriesKey, season);

  /// 添加追番：首次把已发布集数写进水位（避免刚追就提示更新）。
  ///
  /// 首次追番一律是「未开始看」：新条目的 `watchedEpisode` 保持 0，
  /// 之后只由播放历史回写（见 `FollowingProgressService`）。
  ///
  /// 同时把调用方给的「该线路可播集数」落进 `latestReleasedEpisode` /
  /// `seasonReleasedEpisodes`：否则首次检查前 `releasedEpisode` 为 0，
  /// 列表会显示「已更新 0 集」。单调取大，重新追番不会把集数改小。
  /// `seasonTotalEpisodes` 不在这里写——线路可播集数不等于官方总集数。
  Following add({
    required String siteKey,
    required String vodId,
    required String vodName,
    String? vodPic,
    String flag = '',
    String sourceFlag = '',
    int releasedEpisode = 0,
    int trackedSeason = 0,
    bool notifyEnabled = true,
  }) {
    final nowMs = _now().millisecondsSinceEpoch;
    final existing = database.followingByVod(siteKey, vodId);
    final base =
        existing ??
        Following(
          seriesKey: followingSeriesKey(siteKey, vodId),
          season: trackedSeason,
          siteKey: siteKey,
          vodId: vodId,
          vodName: vodName,
          vodPic: vodPic,
          flag: flag,
          sourceFlag: sourceFlag,
          trackedSeason: trackedSeason,
          status: FollowingStatus.unknown,
          notifyEnabled: notifyEnabled,
          createdAtMs: nowMs,
        );
    final released = math.max(0, releasedEpisode);
    final item = initializeFollowing(
      base.copyWith(
        vodName: vodName,
        vodPic: vodPic ?? base.vodPic,
        flag: flag.isEmpty ? base.flag : flag,
        sourceFlag: sourceFlag.isEmpty ? base.sourceFlag : sourceFlag,
        latestReleasedEpisode: math.max(base.latestReleasedEpisode, released),
        seasonReleasedEpisodes: math.max(base.seasonReleasedEpisodes, released),
      ),
      releasedEpisode: releasedEpisode,
      nowMs: nowMs,
    );
    database.upsertFollowing(item);
    return item;
  }

  void remove(Following item) => database.deleteFollowing(item.seriesKey, item.season);

  /// per-item 新集通知开关：只改这一条记录并落库。
  ///
  /// 不改 `updatedAt`，否则列表顺序会被一次开关洗牌；值没变时不写库。
  /// 全局 `FollowingSettings.notifyEnabled` 语义不变：真正发通知仍需两处都开
  /// （见 `shouldNotifyFollowing`）。
  Following setNotifyEnabled(Following item, bool enabled) {
    final latest = byKey(item.seriesKey, item.season);
    if (latest == null) return item;
    if (latest.notifyEnabled == enabled) return latest;
    final next = latest.copyWith(notifyEnabled: enabled);
    database.upsertFollowing(next);
    return next;
  }

  Following markRead(Following item) {
    final latest = byKey(item.seriesKey, item.season);
    if (latest == null) return item;
    final next = markFollowingRead(
      latest,
      nowMs: _now().millisecondsSinceEpoch,
    );
    database.upsertFollowing(next);
    return next;
  }

  /// 检查一条。失败不抛：返回带 error 的结果并写退避。
  Future<FollowingCheckOutcome> check(Following item) async {
    final nowMs = _now().millisecondsSinceEpoch;
    try {
      final lines = await resolveLines(item).timeout(timeout);
      if (lines == null || lines.isEmpty) {
        throw StateError('详情里没有可用线路');
      }
      final latest = byKey(item.seriesKey, item.season);
      if (latest == null) {
        return FollowingCheckOutcome(following: item, changed: false, error: '');
      }
      final snapshot = followingSnapshotFromLines(
        lines,
        flag: latest.flag,
        sourceFlag: latest.sourceFlag,
        nowMs: nowMs,
      );
      if (snapshot == null) throw StateError('线路不存在');
      final applied = applyFollowingSnapshot(latest, snapshot, nowMs: nowMs);
      final updated = _withNextCheck(applied.following, nowMs: nowMs);
      database.upsertFollowing(updated);
      return FollowingCheckOutcome(
        following: updated,
        changed: applied.hasNewEpisode,
        error: '',
      );
    } catch (error) {
      final latest = byKey(item.seriesKey, item.season);
      final next = markFollowingFailure(
        latest ?? item,
        error: '$error',
        nowMs: nowMs,
      );
      if (latest != null) database.upsertFollowing(next);
      log?.warning(
        '追番检查失败 ${item.vodName}（${item.siteKey}）：$error',
        scope: 'following',
      );
      return FollowingCheckOutcome(
        following: next,
        changed: false,
        error: '$error',
      );
    }
  }

  /// 依次检查（并发 1，避免一次刷新打爆站点）。
  ///
  /// [onlyDue] 为 true 时只检查 `nextCheckAt <= now` 的条目（自动调度用）。
  Future<FollowingCheckSummary> checkAll({bool onlyDue = false}) async {
    if (_checking) return FollowingCheckSummary.empty;
    _checking = true;
    var changed = 0;
    var failed = 0;
    var checked = 0;
    try {
      final nowMs = _now().millisecondsSinceEpoch;
      for (final item in database.followings()) {
        if (!item.enabled) continue;
        if (onlyDue) {
          final neverChecked = item.metadataUpdatedAtMs <= 0;
          final notDue = item.nextCheckAtMs > 0 && item.nextCheckAtMs > nowMs;
          if (!neverChecked && notDue) continue;
        }
        final outcome = await check(item);
        checked += 1;
        if (outcome.ok && outcome.changed) changed += 1;
        if (!outcome.ok) failed += 1;
      }
    } finally {
      _checking = false;
    }
    return FollowingCheckSummary(
      checked: checked,
      changed: changed,
      failed: failed,
    );
  }

  Following _withNextCheck(Following item, {required int nowMs}) => item.copyWith(
    nextCheckAtMs: FollowingSchedule.nextCheckAt(
      nowMs: nowMs,
      status: item.status,
      nextAirAtMs: item.nextAirAtMs,
    ),
  );
}
