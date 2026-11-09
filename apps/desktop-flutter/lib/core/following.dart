/// 追番的纯逻辑层（Phase 9 · P2-1）。
///
/// 对齐安卓 `following/`：
/// - 身份键：`source:<cid>:<siteKey>:<vodId>:s<season>`；PC 没有配置记录 id 的
///   上下文时 cid 固定 0，仍保持同一格式（便于与安卓备份互认）；
/// - 更新判定：`released > max(watched, readWatermark)` → 有更新；
///   通知额外受 `enabled/notifyEnabled/lastNotifiedEpisode` 约束；
/// - 调度：连载中 6h、未开播 24h、完结/腰斩 7d；首播时间后 30min 追一次；
///   失败按 15m→30m→1h→2h→6h→1d 退避。
///
/// 与安卓的差异（PC 边界）：
/// - 没有 TMDB 元数据探测：更新检测用「站点详情里该线路的集数」；
/// - 因此 `trackedSeason` 固定 0，`latestReleasedSeason` 固定 0，
///   季概念只在数据模型里保留（为后续 TMDB 接入留位，不伪造）。
library;

import 'dart:math' as math;

/// 追番状态（安卓 `FollowingMetadataSnapshot` 同名字符串）。
abstract final class FollowingStatus {
  static const String returning = 'returning';
  static const String planned = 'planned';
  static const String ended = 'ended';
  static const String canceled = 'canceled';
  static const String unknown = 'unknown';

  static const List<String> values = [
    returning,
    planned,
    ended,
    canceled,
    unknown,
  ];

  static String normalize(String? raw) {
    final value = (raw ?? '').trim().toLowerCase();
    return values.contains(value) ? value : unknown;
  }

  static String label(String raw) => switch (normalize(raw)) {
    returning => '连载中',
    planned => '未开播',
    ended => '已完结',
    canceled => '已腰斩',
    _ => '未知',
  };
}

/// 追番调度常量（与安卓 `FollowingSchedulePolicy` 一致）。
abstract final class FollowingSchedule {
  static const Duration periodicInterval = Duration(hours: 6);
  static const Duration foregroundInterval = Duration(minutes: 15);
  static const Duration minOneShotDelay = Duration(minutes: 15);
  static const Duration minOneShotAfterCheck = Duration(hours: 1);
  static const Duration nextAirGrace = Duration(minutes: 30);

  /// 下一次检查时刻（毫秒）。
  static int nextCheckAt({
    required int nowMs,
    required String status,
    required int nextAirAtMs,
    bool foreground = false,
  }) {
    final normalized = FollowingStatus.normalize(status);
    final nextAirCheckAt = _nextAirCheckAt(nowMs, nextAirAtMs);
    if (normalized == FollowingStatus.returning) {
      final interval =
          nowMs +
          (foreground
              ? foregroundInterval.inMilliseconds
              : periodicInterval.inMilliseconds);
      return nextAirCheckAt > 0 ? math.min(interval, nextAirCheckAt) : interval;
    }
    if (normalized == FollowingStatus.planned) {
      final daily = nowMs + const Duration(hours: 24).inMilliseconds;
      return nextAirCheckAt > 0 ? math.min(daily, nextAirCheckAt) : daily;
    }
    if (normalized == FollowingStatus.ended ||
        normalized == FollowingStatus.canceled) {
      return nowMs + const Duration(days: 7).inMilliseconds;
    }
    return nowMs +
        (foreground
            ? foregroundInterval.inMilliseconds
            : periodicInterval.inMilliseconds);
  }

  static int _nextAirCheckAt(int nowMs, int nextAirAtMs) {
    if (nextAirAtMs <= 0) return 0;
    final minimum = nowMs + minOneShotAfterCheck.inMilliseconds;
    if (nextAirAtMs <= nowMs) return minimum;
    return math.max(
      minimum,
      nextAirAtMs + nextAirGrace.inMilliseconds,
    );
  }

  /// 失败退避（毫秒纪元）。
  static int backoffAt(int nowMs, int failureCount) {
    final delay = switch (math.max(1, failureCount)) {
      1 => const Duration(minutes: 15),
      2 => const Duration(minutes: 30),
      3 => const Duration(hours: 1),
      4 => const Duration(hours: 2),
      5 => const Duration(hours: 6),
      _ => const Duration(days: 1),
    };
    return nowMs + delay.inMilliseconds;
  }
}

/// 身份键：与安卓 `FollowingIdentity` 同格式。
String followingSeriesKey(String siteKey, String vodId, {int configId = 0}) =>
    'source:$configId:${_normalize(siteKey)}:${_normalize(vodId)}';

String followingIdentityKey(String seriesKey, int season) =>
    '${seriesKey.trim()}:s${math.max(0, season)}';

String _normalize(String value) => value.trim().toLowerCase();

/// 一次元数据快照（目前来自站点详情）。
class FollowingSnapshot {
  const FollowingSnapshot({
    required this.status,
    required this.latestReleasedSeason,
    required this.latestReleasedEpisode,
    required this.seasonReleasedEpisodes,
    required this.seasonTotalEpisodes,
    required this.fetchedAtMs,
    this.nextAirAtMs = 0,
    this.latestEpisodeName = '',
    this.latestEpisodeTarget = '',
  });

  final String status;
  final int latestReleasedSeason;
  final int latestReleasedEpisode;
  final int seasonReleasedEpisodes;
  final int seasonTotalEpisodes;
  final int fetchedAtMs;
  final int nextAirAtMs;

  /// 最新一集的展示名与站点入口目标（用于「播放最新集」直接续播）。
  final String latestEpisodeName;
  final String latestEpisodeTarget;
}

/// 从站点详情的线路里取「已更新集数」。
///
/// 线路匹配优先 `sourceFlag`（展示名与请求名可能不同），再退回 `flag`，
/// 最后退回第一条线路；找不到返回 null（不猜）。
FollowingSnapshot? followingSnapshotFromLines(
  List<FollowingLineEpisodes> lines, {
  required String flag,
  required String sourceFlag,
  required int nowMs,
}) {
  if (lines.isEmpty) return null;
  FollowingLineEpisodes? line;
  for (final candidate in lines) {
    if (sourceFlag.isNotEmpty && candidate.sourceFlag == sourceFlag) {
      line = candidate;
      break;
    }
    if (flag.isNotEmpty && candidate.flag == flag) {
      line = candidate;
      break;
    }
  }
  line ??= lines.first;
  final released = math.max(0, line.episodeCount);
  return FollowingSnapshot(
    status: FollowingStatus.unknown,
    latestReleasedSeason: 0,
    latestReleasedEpisode: released,
    seasonReleasedEpisodes: released,
    seasonTotalEpisodes: released,
    fetchedAtMs: nowMs,
    latestEpisodeName: line.latestEpisodeName,
    latestEpisodeTarget: line.latestEpisodeTarget,
  );
}

/// 线路与集数（避免 core 依赖 `protocol.dart` 的具体类型）。
class FollowingLineEpisodes {
  const FollowingLineEpisodes({
    required this.flag,
    required this.sourceFlag,
    required this.episodeCount,
    this.latestEpisodeName = '',
    this.latestEpisodeTarget = '',
  });

  final String flag;
  final String sourceFlag;
  final int episodeCount;
  final String latestEpisodeName;
  final String latestEpisodeTarget;
}

/// 一条追番（一部剧的一季）。
class Following {
  Following({
    required this.seriesKey,
    required this.season,
    required this.siteKey,
    required this.vodId,
    required this.vodName,
    this.vodPic,
    this.flag = '',
    this.sourceFlag = '',
    this.trackedSeason = 0,
    this.latestReleasedSeason = 0,
    this.latestReleasedEpisode = 0,
    this.seasonReleasedEpisodes = 0,
    this.seasonTotalEpisodes = 0,
    this.watchedEpisode = 0,
    this.readWatermarkEpisode = 0,
    this.lastNotifiedEpisode = 0,
    this.lastNotifiedAtMs = 0,
    this.status = FollowingStatus.unknown,
    this.nextAirAtMs = 0,
    this.nextCheckAtMs = 0,
    this.failureCount = 0,
    this.lastError = '',
    this.metadataUpdatedAtMs = 0,
    this.lastCheckedAtMs = 0,
    this.latestEpisodeName = '',
    this.latestEpisodeTarget = '',
    this.enabled = true,
    this.notifyEnabled = true,
    this.createdAtMs = 0,
    this.updatedAtMs = 0,
  });

  final String seriesKey;
  final int season;
  final String siteKey;
  final String vodId;
  final String vodName;
  final String? vodPic;

  /// 展示用线路名与站点请求用 flag。
  final String flag;
  final String sourceFlag;

  /// 当前追踪季（PC 目前恒为 0）。
  final int trackedSeason;

  /// 最新发布季/集（季概念保留，PC 恒为 0）。
  final int latestReleasedSeason;
  final int latestReleasedEpisode;

  /// 本季已发布/总集数。
  final int seasonReleasedEpisodes;
  final int seasonTotalEpisodes;

  /// 已看集数：**只**由播放历史回写（`FollowingProgressService`），
  /// 0 = 未开始看；历史被清理时也不回退。
  final int watchedEpisode;

  /// 已读/已通知水位：只用于「新集提示」去重（刚追番时写成已发布集数，
  /// 避免一追就提示有新集），**不代表已看**，不参与已看/未看计算。
  final int readWatermarkEpisode;

  final int lastNotifiedEpisode;
  final int lastNotifiedAtMs;

  final String status;
  final int nextAirAtMs;
  final int nextCheckAtMs;
  final int failureCount;
  final String lastError;
  final int metadataUpdatedAtMs;
  final int lastCheckedAtMs;

  /// 最新一集的展示名与站点入口目标（空 = 未知，播放时退回详情页）。
  final String latestEpisodeName;
  final String latestEpisodeTarget;

  final bool enabled;
  final bool notifyEnabled;
  final int createdAtMs;
  final int updatedAtMs;

  String get identityKey => followingIdentityKey(seriesKey, season);

  /// 已发布集数：当前追踪季等于最新发布季时用最新集，否则用本季发布数。
  int get releasedEpisode => latestReleasedSeason == trackedSeason
      ? latestReleasedEpisode
      : seasonReleasedEpisodes;

  /// 未看集数：已发布 − 已看（水位不参与），至少 0。
  int get unwatchedCount =>
      math.max(0, releasedEpisode - math.max(0, watchedEpisode)).toInt();

  /// 是否有未确认的更新消息：发送通知不等于已读。
  bool get hasUnreadUpdate =>
      releasedEpisode > math.max(0, readWatermarkEpisode);

  /// 是否有未看的发布集（只看已看，不看水位）。
  ///
  /// 「刚追番不提示新集」由水位在 `shouldNotifyFollowing` 里单独判断，
  /// 与这里无关。
  bool get hasUpdate => releasedEpisode > math.max(0, watchedEpisode);

  Following copyWith({
    String? seriesKey,
    int? season,
    String? siteKey,
    String? vodId,
    String? vodName,
    String? vodPic,
    String? flag,
    String? sourceFlag,
    int? trackedSeason,
    int? latestReleasedSeason,
    int? latestReleasedEpisode,
    int? seasonReleasedEpisodes,
    int? seasonTotalEpisodes,
    int? watchedEpisode,
    int? readWatermarkEpisode,
    int? lastNotifiedEpisode,
    int? lastNotifiedAtMs,
    String? status,
    int? nextAirAtMs,
    int? nextCheckAtMs,
    int? failureCount,
    String? lastError,
    int? metadataUpdatedAtMs,
    int? lastCheckedAtMs,
    String? latestEpisodeName,
    String? latestEpisodeTarget,
    bool? enabled,
    bool? notifyEnabled,
    int? createdAtMs,
    int? updatedAtMs,
  }) => Following(
    seriesKey: seriesKey ?? this.seriesKey,
    season: season ?? this.season,
    siteKey: siteKey ?? this.siteKey,
    vodId: vodId ?? this.vodId,
    vodName: vodName ?? this.vodName,
    vodPic: vodPic ?? this.vodPic,
    flag: flag ?? this.flag,
    sourceFlag: sourceFlag ?? this.sourceFlag,
    trackedSeason: trackedSeason ?? this.trackedSeason,
    latestReleasedSeason: latestReleasedSeason ?? this.latestReleasedSeason,
    latestReleasedEpisode: latestReleasedEpisode ?? this.latestReleasedEpisode,
    seasonReleasedEpisodes:
        seasonReleasedEpisodes ?? this.seasonReleasedEpisodes,
    seasonTotalEpisodes: seasonTotalEpisodes ?? this.seasonTotalEpisodes,
    watchedEpisode: watchedEpisode ?? this.watchedEpisode,
    readWatermarkEpisode:
        readWatermarkEpisode ?? this.readWatermarkEpisode,
    lastNotifiedEpisode:
        lastNotifiedEpisode ?? this.lastNotifiedEpisode,
    lastNotifiedAtMs: lastNotifiedAtMs ?? this.lastNotifiedAtMs,
    status: status ?? this.status,
    nextAirAtMs: nextAirAtMs ?? this.nextAirAtMs,
    nextCheckAtMs: nextCheckAtMs ?? this.nextCheckAtMs,
    failureCount: failureCount ?? this.failureCount,
    lastError: lastError ?? this.lastError,
    metadataUpdatedAtMs: metadataUpdatedAtMs ?? this.metadataUpdatedAtMs,
    lastCheckedAtMs: lastCheckedAtMs ?? this.lastCheckedAtMs,
    latestEpisodeName: latestEpisodeName ?? this.latestEpisodeName,
    latestEpisodeTarget: latestEpisodeTarget ?? this.latestEpisodeTarget,
    enabled: enabled ?? this.enabled,
    notifyEnabled: notifyEnabled ?? this.notifyEnabled,
    createdAtMs: createdAtMs ?? this.createdAtMs,
    updatedAtMs: updatedAtMs ?? this.updatedAtMs,
  );

  Map<String, Object?> toJson() => {
    'seriesKey': seriesKey,
    'season': season,
    'siteKey': siteKey,
    'vodId': vodId,
    'vodName': vodName,
    if (vodPic != null) 'vodPic': vodPic,
    'flag': flag,
    'sourceFlag': sourceFlag,
    'trackedSeason': trackedSeason,
    'latestReleasedSeason': latestReleasedSeason,
    'latestReleasedEpisode': latestReleasedEpisode,
    'seasonReleasedEpisodes': seasonReleasedEpisodes,
    'seasonTotalEpisodes': seasonTotalEpisodes,
    'watchedEpisode': watchedEpisode,
    'readWatermarkEpisode': readWatermarkEpisode,
    'lastNotifiedEpisode': lastNotifiedEpisode,
    'lastNotifiedAt': lastNotifiedAtMs,
    'status': status,
    'nextAirAt': nextAirAtMs,
    'nextCheckAt': nextCheckAtMs,
    'failureCount': failureCount,
    'lastError': lastError,
    'metadataUpdatedAt': metadataUpdatedAtMs,
    'lastCheckedAt': lastCheckedAtMs,
    'latestEpisodeName': latestEpisodeName,
    'latestEpisodeTarget': latestEpisodeTarget,
    'enabled': enabled,
    'notifyEnabled': notifyEnabled,
    'createdAt': createdAtMs,
    'updatedAt': updatedAtMs,
  };

  static Following? tryParse(Map<String, Object?> map) {
    final seriesKey = map['seriesKey'] as String?;
    final siteKey = map['siteKey'] as String?;
    final vodId = map['vodId'] as String?;
    final vodName = map['vodName'] as String?;
    if (seriesKey == null ||
        siteKey == null ||
        vodId == null ||
        vodName == null) {
      return null;
    }
    int number(String key) {
      final value = map[key];
      return value is num ? value.toInt() : 0;
    }

    bool flag(String key, bool fallback) {
      final value = map[key];
      return value is bool ? value : fallback;
    }

    return Following(
      seriesKey: seriesKey,
      season: number('season'),
      siteKey: siteKey,
      vodId: vodId,
      vodName: vodName,
      vodPic: map['vodPic'] as String?,
      flag: map['flag'] as String? ?? '',
      sourceFlag: map['sourceFlag'] as String? ?? '',
      trackedSeason: number('trackedSeason'),
      latestReleasedSeason: number('latestReleasedSeason'),
      latestReleasedEpisode: number('latestReleasedEpisode'),
      seasonReleasedEpisodes: number('seasonReleasedEpisodes'),
      seasonTotalEpisodes: number('seasonTotalEpisodes'),
      watchedEpisode: number('watchedEpisode'),
      readWatermarkEpisode: number('readWatermarkEpisode'),
      lastNotifiedEpisode: number('lastNotifiedEpisode'),
      lastNotifiedAtMs: number('lastNotifiedAt'),
      status: FollowingStatus.normalize(map['status'] as String?),
      nextAirAtMs: number('nextAirAt'),
      nextCheckAtMs: number('nextCheckAt'),
      failureCount: number('failureCount'),
      lastError: map['lastError'] as String? ?? '',
      metadataUpdatedAtMs: number('metadataUpdatedAt'),
      lastCheckedAtMs: number('lastCheckedAt'),
      latestEpisodeName: map['latestEpisodeName'] as String? ?? '',
      latestEpisodeTarget: map['latestEpisodeTarget'] as String? ?? '',
      enabled: flag('enabled', true),
      notifyEnabled: flag('notifyEnabled', true),
      createdAtMs: number('createdAt'),
      updatedAtMs: number('updatedAt'),
    );
  }
}

/// 新追一部剧：把已发布集数写进水位，避免「刚追就提示有更新」。
///
/// 首次追番 = **未开始看**：`watchedEpisode` 这里不写（新条目本为 0，
/// 老条目保留原值），已看只由播放历史回写推进。
Following initializeFollowing(
  Following item, {
  required int releasedEpisode,
  required int nowMs,
}) {
  final released = math.max(0, releasedEpisode);
  return refreshFollowingDerived(
    item.copyWith(
      readWatermarkEpisode: released,
      lastNotifiedEpisode: released,
      lastNotifiedAtMs: nowMs,
      createdAtMs: item.createdAtMs > 0 ? item.createdAtMs : nowMs,
      updatedAtMs: nowMs,
      nextCheckAtMs: FollowingSchedule.nextCheckAt(
        nowMs: nowMs,
        status: item.status,
        nextAirAtMs: item.nextAirAtMs,
      ),
    ),
    nowMs: nowMs,
  );
}

/// 一次元数据应用的结果。
class FollowingApplyResult {
  const FollowingApplyResult(this.following, {required this.hasNewEpisode});

  final Following following;
  final bool hasNewEpisode;
}

/// 应用一次元数据：返回更新后的对象与「是否有新集」。
FollowingApplyResult applyFollowingSnapshot(
  Following item,
  FollowingSnapshot snapshot, {
  required int nowMs,
}) {
  final before = item.releasedEpisode;
  final previousLatestSeason = math.max(0, item.latestReleasedSeason);
  final previousLatestEpisode = math.max(0, item.latestReleasedEpisode);
  final latestSeason = math.max(0, snapshot.latestReleasedSeason);
  final latestEpisode = math.max(0, snapshot.latestReleasedEpisode);
  var next = item;
  if (latestSeason > previousLatestSeason) {
    next = next.copyWith(
      latestReleasedSeason: latestSeason,
      latestReleasedEpisode: latestEpisode,
    );
  } else if (latestSeason == previousLatestSeason) {
    next = next.copyWith(
      latestReleasedSeason: previousLatestSeason,
      latestReleasedEpisode: math.max(previousLatestEpisode, latestEpisode),
    );
  } else {
    next = next.copyWith(
      latestReleasedSeason: previousLatestSeason,
      latestReleasedEpisode: previousLatestEpisode,
    );
  }
  next = next.copyWith(
    status: FollowingStatus.normalize(snapshot.status),
    seasonTotalEpisodes: math.max(0, snapshot.seasonTotalEpisodes),
    seasonReleasedEpisodes: math.max(
      math.max(0, next.seasonReleasedEpisodes),
      math.max(0, snapshot.seasonReleasedEpisodes),
    ),
    nextAirAtMs: math.max(0, snapshot.nextAirAtMs),
    metadataUpdatedAtMs:
        snapshot.fetchedAtMs > 0 ? snapshot.fetchedAtMs : nowMs,
    failureCount: 0,
    lastError: '',
    lastCheckedAtMs: nowMs,
    latestEpisodeName: snapshot.latestEpisodeName.isNotEmpty
        ? snapshot.latestEpisodeName
        : next.latestEpisodeName,
    latestEpisodeTarget: snapshot.latestEpisodeTarget.isNotEmpty
        ? snapshot.latestEpisodeTarget
        : next.latestEpisodeTarget,
    updatedAtMs: nowMs,
  );
  final firstMetadata =
      item.metadataUpdatedAtMs <= 0 &&
      item.readWatermarkEpisode <= 0 &&
      item.lastNotifiedEpisode <= 0;
  next = refreshFollowingDerived(next, nowMs: nowMs);
  if (firstMetadata) {
    next = next.copyWith(
      readWatermarkEpisode: math.max(
        next.readWatermarkEpisode,
        next.releasedEpisode,
      ),
      lastNotifiedEpisode: math.max(
        next.lastNotifiedEpisode,
        next.releasedEpisode,
      ),
      lastNotifiedAtMs: nowMs,
    );
  }
  return FollowingApplyResult(
    next,
    // 第一次拿到元数据只是建立基线，不算「新集」。
    hasNewEpisode: !firstMetadata && next.releasedEpisode > before,
  );
}

/// 重算 `hasUpdate` / `unwatchedCount`（不持久化）。
Following refreshFollowingDerived(Following item, {required int nowMs}) {
  return item.copyWith(
    watchedEpisode: math.max(0, item.watchedEpisode),
    updatedAtMs: nowMs,
  );
}

/// 是否应该发通知。
bool shouldNotifyFollowing(Following item) {
  if (!item.enabled || !item.notifyEnabled) return false;
  final released = item.releasedEpisode;
  return released >
      math.max(
        math.max(0, item.readWatermarkEpisode),
        math.max(0, item.lastNotifiedEpisode),
      );
}

Following markFollowingNotified(Following item, {required int nowMs}) =>
    item.copyWith(
      lastNotifiedEpisode: item.releasedEpisode,
      lastNotifiedAtMs: nowMs,
      updatedAtMs: nowMs,
    );

/// 标记已读：只把已读水位抬到已发布集数（抑制新集提示），不改已看集数。
Following markFollowingRead(Following item, {required int nowMs}) =>
    refreshFollowingDerived(
      item.copyWith(
        readWatermarkEpisode: math.max(
          item.readWatermarkEpisode,
          item.releasedEpisode,
        ),
      ),
      nowMs: nowMs,
    );

Following markFollowingFailure(
  Following item, {
  required String error,
  required int nowMs,
}) {
  final failureCount = math.max(0, item.failureCount) + 1;
  final short = error.trim().isEmpty
      ? '检查失败'
      : (error.trim().length <= 160
            ? error.trim()
            : '${error.trim().substring(0, 160)}…');
  return item.copyWith(
    failureCount: failureCount,
    lastError: short,
    lastCheckedAtMs: nowMs,
    nextCheckAtMs: FollowingSchedule.backoffAt(nowMs, failureCount),
    updatedAtMs: nowMs,
  );
}

/// 追番设置（顶层 `following`）。
class FollowingSettings {
  const FollowingSettings({
    this.enabled = true,
    this.notifyEnabled = false,
    this.intervalMinutes = 360,
  });

  static const FollowingSettings defaults = FollowingSettings();

  /// 自动检查开关（应用运行期间生效；PC 没有后台服务）。
  ///
  /// 默认开启：从未显式设置过的用户（含老库升级、旧偏好里没有 `following`
  /// 键）直接进入自动检查；曾显式关闭的用户由偏好里存下的 `false` 保持关闭。
  final bool enabled;

  /// 发现新集时的通知开关（系统通知不可用时降级为应用内提示）。
  final bool notifyEnabled;

  /// 自动检查间隔（分钟），默认 6 小时，夹取 15–1440。
  final int intervalMinutes;

  /// 「每 N 小时 / 每 N 分钟」文案（非整小时显示分钟）。
  String get intervalLabel => formatInterval(intervalMinutes);

  /// 分钟数的展示文案，与 [intervalLabel] 同规则。
  static String formatInterval(int minutes) =>
      minutes % 60 == 0 ? '每 ${minutes ~/ 60} 小时' : '每 $minutes 分钟';

  bool get isDefault => this == defaults;

  FollowingSettings copyWith({
    bool? enabled,
    bool? notifyEnabled,
    int? intervalMinutes,
  }) => FollowingSettings(
    enabled: enabled ?? this.enabled,
    notifyEnabled: notifyEnabled ?? this.notifyEnabled,
    intervalMinutes: _clamp(intervalMinutes ?? this.intervalMinutes),
  );

  static int _clamp(int value) {
    if (value < 15) return 15;
    if (value > 1440) return 1440;
    return value;
  }

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'notifyEnabled': notifyEnabled,
    'intervalMinutes': intervalMinutes,
  };

  factory FollowingSettings.fromJson(Object? raw) {
    final map = raw is Map ? raw : const {};
    return FollowingSettings(
      // 缺键一律回落到默认值：默认开启，所以老偏好（没有 `following` 键或
      // 旧版写下的键里缺 `enabled`）同样视为「从未设置过 → 开启」。
      enabled: map['enabled'] is bool
          ? map['enabled'] as bool
          : defaults.enabled,
      notifyEnabled: map['notifyEnabled'] is bool
          ? map['notifyEnabled'] as bool
          : defaults.notifyEnabled,
      intervalMinutes: _clamp(
        map['intervalMinutes'] is num
            ? (map['intervalMinutes'] as num).toInt()
            : defaults.intervalMinutes,
      ),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is FollowingSettings &&
      other.enabled == enabled &&
      other.notifyEnabled == notifyEnabled &&
      other.intervalMinutes == intervalMinutes;

  @override
  int get hashCode => Object.hash(enabled, notifyEnabled, intervalMinutes);
}
