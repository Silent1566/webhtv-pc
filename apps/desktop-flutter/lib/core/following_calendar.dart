/// 追剧日历的纯逻辑层（Phase 9 · P2-1 配套）。
///
/// 只依赖 `dart:math` 与 `core/following.dart`：不碰 IO、不联网、不依赖 Flutter。
/// 调用方把追番列表与（可选的）TMDB 排期喂进来，这一层只负责归日、逐集装配
/// 条目与生成展示文案——**本层不发起任何网络/DB 调用**。
///
/// ## 归日规则（渐进式）
///
/// 每部剧的**每一集**各自成一条 [CalendarEntry]（同一天更新多集就多条），来源见
/// [CalendarSource]：
/// 1. `real`：调用方在 [FollowingAirTime] 里给出了 TMDB 排期 → 按排期日归日；
/// 2. `real`：否则若 `Following.nextAirAtMs` 落在可信窗口内 → 按它归日，
///    集号取该线路可播集数；
/// 3. `local`：都没有 → 降级为本地数据，时间按
///    `lastCheckedAtMs → metadataUpdatedAtMs → updatedAtMs → nowMs` 取第一个可用值
///    归日，**只出一条最新一集**（日期是假日期，不逐集展开，见 `_collectItem`）。
///
/// 排期可能落在未来：这类条目照常留在日历里（用户要知道哪天更新），但
/// [CalendarEntry.aired] 为 false，算「待播」而不是未看。
///
/// 「一集一条」只用于日期可信的前两条路径；降级路径靠 `unwatchedCount` /
/// `progressLabel` / 日汇总表达未看量。
///
/// 时间统一是**本地时区**的毫秒纪元；自然日一律用 `DateTime(y, m, d)` 构造切分
/// （不用 `Duration` 加减，避免夏令时把 0:00 拨成 23:00）。
///
/// 本层**不**按 `enabled` / `notifyEnabled` 过滤：日历回答的是「这部剧哪天有更新」，
/// 是否展示由调用方决定。
library;

import 'dart:math' as math;

import 'following.dart';

/// 归日时的时间可信窗口（相对 `nowMs`）。
abstract final class FollowingCalendarPolicy {
  /// 真实播出时间最多允许超前 1 年；更远视为脏数据。
  static const Duration maxAirLead = Duration(days: 365);

  /// 真实播出时间最多允许回溯 5 年（长篇连载的老播出日仍可信）；更久视为脏数据。
  static const Duration maxAirAge = Duration(days: 1825);

  /// 本地时间（检查/更新时间）不允许落在未来，只容忍 1 天的时钟偏差。
  static const Duration maxLocalSkew = Duration(days: 1);
}

/// 条目日期的数据来源。
enum CalendarSource {
  /// 日期来自平台排期（数据取自 TMDB 等元数据源汇总的播出信息；排期日可能在
  /// 未来，**不代表这一集已经播出**，是否已播出见 [CalendarEntry.aired]）。
  real('平台排期'),

  /// 本地数据降级（最近检查/更新时间 + 已发布集数），不保证是真实播出日。
  local('本地推算');

  const CalendarSource(this.label);

  /// 徽标文案。
  final String label;
}

/// 一种「真实播出时间」的输入（由调用方从 TMDB 等来源查到后传入）。
class FollowingAirTime {
  const FollowingAirTime({
    required this.seriesKey,
    required this.season,
    required this.episode,
    required this.airAtMs,
    this.episodeTitle = '',
  });

  final String seriesKey;

  /// 数据层的季下标（0 基，与 `followingIdentityKey` 的 `:s<season>` 一致）。
  final int season;

  /// 集号；`<= 0` 表示未知，归日时退回该剧的已发布集数。
  final int episode;

  /// 播出时刻（本地时区毫秒纪元）。
  final int airAtMs;

  /// 该集的标题（来自 TMDB 的集名）；空串表示未知。
  final String episodeTitle;

  /// `followingIdentityKey` 格式的身份键。
  String get identityKey => followingIdentityKey(seriesKey, season);
}

/// 进度分母的来源（决定 UI 要不要显示百分比、要不要标注「约」）。
enum CalendarTotalSource {
  /// 官方该季总集数（调用方从 TMDB 的 `seasonEpisodeCounts` 查来）。
  official('官方总集数'),

  /// 降级：本线路可播集数（`Following.releasedEpisode`），不等于官方总集数。
  line('线路可播集数'),

  /// 两者都拿不到 → [CalendarEntry.totalEpisodes] 为 0，进度不可用。
  unknown('集数未知');

  const CalendarTotalSource(this.label);

  /// 徽标文案。
  final String label;
}

/// 日历里的一条条目：**一集一条**，不再把同日的多集合并成区间。
class CalendarEntry {
  const CalendarEntry({
    required this.seriesKey,
    required this.season,
    required this.vodName,
    required this.vodPic,
    required this.episode,
    required this.totalEpisodes,
    required this.watchedEpisode,
    required this.unwatchedCount,
    required this.ongoing,
    required this.source,
    required this.totalSource,
    this.episodeTitle = '',
    this.aired = true,
    this.airingThroughEpisode = 0,
  });

  final String seriesKey;

  /// 数据层的季下标（0 基）。
  final int season;

  final String vodName;
  final String? vodPic;

  /// 单集集号（1 基）；`< 1` 表示集号未知。
  final int episode;

  /// 进度分母：该季总集数，`0` 表示未知。
  ///
  /// 取值由调用方给的官方总集数优先，拿不到才降级为本线路可播集数；
  /// 来源见 [totalSource]。
  final int totalEpisodes;

  /// 真实已看集数（`Following.watchedEpisode`；水位不代表看过，这里不用它）。
  final int watchedEpisode;

  /// 本条是否还没看：已播出且 `episode > watchedEpisode` 时为 1，否则 0。
  final int unwatchedCount;

  /// 是否还有未看的集；由 [unwatchedCount] 推导，避免两套真值。
  bool get unwatched => unwatchedCount > 0;

  /// 该集的标题（透传自 [FollowingAirTime.episodeTitle]）；空串表示未知。
  final String episodeTitle;

  /// 这一集是否**已经播出**（排期日不晚于今天）。
  ///
  /// [CalendarSource.real] 只说明日期来自 TMDB 排期，排期日可能在未来；
  /// 未来集仍留在日历里（用户要能看到哪天更新），但不算未看。本地降级路径
  /// 的日期是「已发布」的推断，恒为 true。
  final bool aired;

  /// 该剧该季 TMDB 排期的最大集号（`0` 表示未知）；用于「TMDB 排期至 E14」。
  final int airingThroughEpisode;

  /// 这一集已播出（集号未知不算）。
  bool get episodeAired => episode >= 1 && aired;

  /// 这一集还没播出（集号已知且排期在未来）。
  bool get episodePending => episode >= 1 && !aired;

  /// 这一集是否已看：集号已知且不高于真实已看集数。
  bool get episodeWatched => episode >= 1 && watchedEpisode >= episode;

  /// 这一集是否未看：**已播出**且高于真实已看集数。
  ///
  /// 与 [unwatchedCount] 的区别：后者是按条目算的未看标记，这里只看本集集号。
  bool get episodeUnwatched => episodeAired && !episodeWatched;

  /// 是否连载中（`FollowingStatus.returning`）。
  final bool ongoing;

  final CalendarSource source;

  /// [totalEpisodes] 的来源。
  final CalendarTotalSource totalSource;

  /// 兼容旧调用方：一集一条后「区间」起止就是同一集。
  int get episodeStart => episode;

  /// 兼容旧调用方：见 [episodeStart]。
  int get episodeEnd => episode;

  /// `followingIdentityKey` 格式的身份键。
  String get identityKey => followingIdentityKey(seriesKey, season);

  /// 本条包含的集数：集号已知为 1，未知为 0。
  int get episodeCount => episode >= 1 ? 1 : 0;

  /// 观看进度 = 已看 / [totalEpisodes]，clamp 到 `0..1`；分母未知时为 0。
  double get progress {
    if (totalEpisodes <= 0) return 0;
    final ratio = math.max(0, watchedEpisode) / totalEpisodes;
    return ratio > 1 ? 1 : ratio;
  }

  /// 分母是否来自官方总集数；false 时进度只是近似值，UI 不宜显示百分比。
  bool get hasOfficialTotal => totalSource == CalendarTotalSource.official;

  /// 还剩多少集没看（`totalEpisodes - watchedEpisode`，不小于 0）。
  ///
  /// 降级路径一天只出一条最新一集，未看总量靠这个 getter 表达，不靠条数堆。
  int get remainingEpisodes {
    final watched = watchedEpisode < 0 ? 0 : watchedEpisode;
    final remaining = totalEpisodes - watched;
    return remaining < 0 ? 0 : remaining;
  }

  /// 紧凑集号 `S01E23`（季、集各补到两位）；集号未知时只给季 `S01`。
  String get code {
    final seasonCode =
        'S${(math.max(0, season) + 1).toString().padLeft(2, '0')}';
    if (episode < 1) return seasonCode;
    return '${seasonCode}E${episode.toString().padLeft(2, '0')}';
  }

  /// 集号展示文案，规则见 [followingCalendarEpisodeLabel]。
  String get episodeLabel => followingCalendarEpisodeLabel(
    season: season,
    startEpisode: episode,
    endEpisode: episode,
  );

  /// 「已看 / 未看」文案，规则见 [followingCalendarProgressLabel]。
  String get progressLabel => followingCalendarProgressLabel(
    watchedEpisode: watchedEpisode,
    unwatchedCount: unwatchedCount,
    episodeKnown: episode >= 1,
  );
}

/// 一个自然日的聚合结果。
class CalendarDay {
  const CalendarDay({required this.date, this.entries = const []});

  /// 本地自然日 0:00。
  final DateTime date;

  /// 已按「剧名 → 季 → 集号」排好序。
  final List<CalendarEntry> entries;

  bool get isEmpty => entries.isEmpty;

  bool get isNotEmpty => entries.isNotEmpty;

  /// 未看的集数（只算已播出、一集一条）。
  int get unwatchedCount => entries.where((entry) => entry.unwatched).length;

  /// 待播的集数（排期在未来、尚未播出）。
  int get pendingCount => entries.where((entry) => entry.episodePending).length;

  /// 当天更新的剧数（按 `identityKey` 去重）。
  int get seriesCount =>
      entries.map((entry) => entry.identityKey).toSet().length;
}

/// 月历格子；前后月补齐的格子 `inMonth == false`。
class CalendarCell {
  const CalendarCell({required this.date, required this.inMonth});

  /// 本地自然日 0:00。
  final DateTime date;

  /// 是否属于本月。
  final bool inMonth;

  int get dayOfMonth => date.day;

  /// `DateTime.monday`…`DateTime.sunday`。
  int get weekday => date.weekday;
}

/// 一个月的月历网格：每行 7 格，周一或周日起始。
class CalendarMonth {
  const CalendarMonth({
    required this.year,
    required this.month,
    required this.mondayFirst,
    required this.weeks,
  });

  final int year;
  final int month;
  final bool mondayFirst;

  /// 按行分组的 7 格一行。
  final List<List<CalendarCell>> weeks;

  /// 展开成一维格子（`weeks.length * 7` 个）。
  List<CalendarCell> get cells => [for (final week in weeks) ...week];

  /// 本月天数（闰年 2 月为 29）。
  int get dayCount => DateTime(year, month + 1, 0).day;
}

/// 一周的条带视图数据：固定 7 天，周一 → 周日。
///
/// 跨月/跨年由 `DateTime(y, m, d + i)` 归一，因此 `spansTwoMonths` 可能为真
/// （例如 2026-10-26 ~ 2026-11-01）。
class CalendarWeek {
  const CalendarWeek({required this.anchor, required this.days});

  /// 查询用的锚点日（已归一到 0:00），通常是选中日。
  final DateTime anchor;

  /// 7 天，`days.first` 是周一、`days.last` 是周日。
  final List<CalendarDay> days;

  DateTime get start => days.first.date;

  DateTime get end => days.last.date;

  /// 是否横跨两个月（周一起始的一周必然可能跨月）。
  bool get spansTwoMonths => start.year != end.year || start.month != end.month;

  /// 本周有更新的天数。
  int get activeDayCount => days.where((day) => day.isNotEmpty).length;

  /// 本周还有未看的天数。
  int get unwatchedDayCount =>
      days.where((day) => day.unwatchedCount > 0).length;
}

// ---------------------------------------------------------------------------
// 纯函数
// ---------------------------------------------------------------------------

/// 毫秒纪元 → 本地自然日 0:00（`<= 0` 按纪元 0 处理）。
DateTime followingCalendarDateOf(int epochMs) {
  final time = DateTime.fromMillisecondsSinceEpoch(epochMs < 0 ? 0 : epochMs);
  return DateTime(time.year, time.month, time.day);
}

/// 集号区间文案。
///
/// - 单集（`start == end`）：`S1E16 · 共 1 集`
/// - 连续多集：`S1E16-E17 · 共 2 集`
/// - 两端颠倒先归一（`17, 16` → `S1E16-E17 · 共 2 集`）
/// - 集号未知（两端都 `< 1`）：`S1 · 集号未知`
/// - 只有一端 `< 1` 时按 1 起算（`0, 17` → `S1E1-E17 · 共 17 集`）
///
/// 季号：数据层 `season` 是 0 基（`followingIdentityKey` 的 `:s0` 是默认季），
/// 展示时 +1；PC 目前只会是 0 → 恒为 `S1`。
String followingCalendarEpisodeLabel({
  required int season,
  required int startEpisode,
  required int endEpisode,
}) {
  final seasonLabel = 'S${math.max(0, season) + 1}';
  final high = math.max(startEpisode, endEpisode);
  if (high < 1) return '$seasonLabel · 集号未知';
  final low = math.max(1, math.min(startEpisode, endEpisode));
  if (low == high) return '${seasonLabel}E$low · 共 1 集';
  return '${seasonLabel}E$low-E$high · 共 ${high - low + 1} 集';
}

/// 「已看 / 未看」文案。
///
/// - 集号未知：`集号未知`
/// - 一集未看（`watchedEpisode == 0`）：`未开始看 · 未看 7 集`
/// - 看了一部分：`已看 15 集 · 未看 2 集`
/// - 全部看完：`已看 17 集 · 已看完`
String followingCalendarProgressLabel({
  required int watchedEpisode,
  required int unwatchedCount,
  bool episodeKnown = true,
}) {
  if (!episodeKnown) return '集号未知';
  final watched = math.max(0, watchedEpisode);
  final unwatched = math.max(0, unwatchedCount);
  if (unwatched <= 0) return '已看 $watched 集 · 已看完';
  if (watched <= 0) return '未开始看 · 未看 $unwatched 集';
  return '已看 $watched 集 · 未看 $unwatched 集';
}

/// 周几的单字中文：周一 `一` … 周日 `日`。
const List<String> followingCalendarWeekdayLabels = [
  '一',
  '二',
  '三',
  '四',
  '五',
  '六',
  '日',
];

/// 某天对应的单字中文周几。
String followingCalendarWeekdayLabel(DateTime date) =>
    followingCalendarWeekdayLabels[date.weekday - 1];

/// 月历网格。`month` 允许越界归一（`0` → 上一年 12 月，`13` → 下一年 1 月）。
///
/// 首行从本月 1 日所在周的那一周开始，末行补齐到整周，因此 `weeks.length` 是
/// 4~6 之间的值（例如 2026-10 周一起始是 5 行 35 格：9/28 ~ 11/1）。
CalendarMonth followingCalendarMonth({
  required int year,
  required int month,
  bool mondayFirst = true,
}) {
  final first = DateTime(year, month);
  final normalizedYear = first.year;
  final normalizedMonth = first.month;
  final dayCount = DateTime(normalizedYear, normalizedMonth + 1, 0).day;
  // DateTime.weekday：周一 = 1 … 周日 = 7；周日起始时把周日折成 0。
  final leading = mondayFirst ? first.weekday - 1 : first.weekday % 7;
  final start = DateTime(normalizedYear, normalizedMonth, 1 - leading);
  final rowCount = ((leading + dayCount) / 7).ceil();
  final weeks = <List<CalendarCell>>[];
  for (var row = 0; row < rowCount; row++) {
    final week = <CalendarCell>[];
    for (var column = 0; column < 7; column++) {
      final date = DateTime(
        start.year,
        start.month,
        start.day + row * 7 + column,
      );
      final inMonth =
          date.year == normalizedYear && date.month == normalizedMonth;
      week.add(CalendarCell(date: date, inMonth: inMonth));
    }
    weeks.add(week);
  }
  return CalendarMonth(
    year: normalizedYear,
    month: normalizedMonth,
    mondayFirst: mondayFirst,
    weeks: weeks,
  );
}

/// 把一批追番聚合成「本地自然日 → 条目列表」，**一集一条**。
///
/// - 只返回有条目的日子（没有更新的日子不出现在 map 里）；
/// - 同一部剧同一天的多集各出一条，各带自己的集号与进度（不再合并区间）；
/// - 每天内部按「剧名 → 季 → 集号」稳定排序；map 的键按时间升序。
///
/// [airTimes] 是调用方查到的真实播出时间；本层只做匹配（`seriesKey + season`）
/// 与时间校验，不发起查询。
///
/// [officialTotalEpisodes] 是调用方查到的**官方该季总集数**，键为
/// `followingIdentityKey`（如 TMDB 的 `seasonEpisodeCounts`）；缺失或 `<= 0`
/// 时进度分母降级为本线路可播集数（见 [CalendarTotalSource]）。
Map<DateTime, List<CalendarEntry>> followingCalendarByDay({
  required List<Following> items,
  required int nowMs,
  List<FollowingAirTime> airTimes = const [],
  Map<String, int> officialTotalEpisodes = const {},
}) {
  final airTimesByIdentity = <String, List<FollowingAirTime>>{};
  for (final airTime in airTimes) {
    airTimesByIdentity
        .putIfAbsent(airTime.identityKey, () => <FollowingAirTime>[])
        .add(airTime);
  }

  final byDay = <DateTime, List<CalendarEntry>>{};
  // 同一集只允许出现一次（重复的 airTime 不应画成两行）。
  final seen = <String>{};

  for (final item in items) {
    final identity = item.identityKey;
    final watched = math.max(0, item.watchedEpisode);
    final lineReleased = math.max(0, item.releasedEpisode);
    final official = math.max(0, officialTotalEpisodes[identity] ?? 0);
    final totalEpisodes = official > 0 ? official : lineReleased;
    final totalSource = official > 0
        ? CalendarTotalSource.official
        : (lineReleased > 0
              ? CalendarTotalSource.line
              : CalendarTotalSource.unknown);
    final ongoing =
        FollowingStatus.normalize(item.status) == FollowingStatus.returning;

    void put(
      DateTime day,
      int episode,
      CalendarSource source, {
      String episodeTitle = '',
      bool aired = true,
      int airingThroughEpisode = 0,
    }) {
      final known = episode >= 1;
      final dedupeKey =
          '$identity|${day.year}-${day.month}-${day.day}|$episode';
      if (!seen.add(dedupeKey)) return;
      byDay
          .putIfAbsent(day, () => <CalendarEntry>[])
          .add(
            CalendarEntry(
              seriesKey: item.seriesKey,
              season: item.season,
              vodName: item.vodName,
              vodPic: item.vodPic,
              episode: known ? episode : 0,
              totalEpisodes: totalEpisodes,
              watchedEpisode: watched,
              // 未看只按真实已看集号判定，且必须已经播出；水位不参与。
              unwatchedCount: known && aired && episode > watched ? 1 : 0,
              ongoing: ongoing,
              source: source,
              totalSource: totalSource,
              episodeTitle: episodeTitle,
              aired: aired,
              airingThroughEpisode: airingThroughEpisode,
            ),
          );
    }

    _collectItem(
      item,
      nowMs: nowMs,
      airTimes: airTimesByIdentity[identity] ?? const <FollowingAirTime>[],
      put: put,
    );
  }

  final days = byDay.keys.toList()..sort();
  final result = <DateTime, List<CalendarEntry>>{};
  for (final day in days) {
    result[day] = byDay[day]!..sort(_compareEntries);
  }
  return result;
}

/// 一天的更新汇总，供「按日期分段」的标题行用。
class CalendarDaySummary {
  const CalendarDaySummary({
    required this.seriesCount,
    required this.episodeCount,
    required this.unwatchedEpisodeCount,
    this.pendingEpisodeCount = 0,
  });

  /// 当天有更新的剧数（按 `identityKey` 去重）。
  final int seriesCount;

  /// 当天更新的集数（= 条目数）。
  final int episodeCount;

  /// 其中已播出但还没看的集数。
  final int unwatchedEpisodeCount;

  /// 其中排期在未来、还没播出的集数。
  final int pendingEpisodeCount;

  bool get isEmpty => episodeCount == 0;

  bool get hasUnwatched => unwatchedEpisodeCount > 0;

  bool get hasPending => pendingEpisodeCount > 0;

  /// `3 部更新 · 未看 5 集`；有未来集时并列 `· 待播 2 集`；都没有只报部数。
  String get label {
    final parts = <String>['$seriesCount 部更新'];
    if (hasUnwatched) parts.add('未看 $unwatchedEpisodeCount 集');
    if (hasPending) parts.add('待播 $pendingEpisodeCount 集');
    return parts.join(' · ');
  }
}

/// 单日汇总的纯函数：直接喂 [CalendarDay.entries] 或 `byDay[day]!`。
CalendarDaySummary followingCalendarDaySummary(List<CalendarEntry> entries) {
  final identities = <String>{};
  var unwatched = 0;
  var pending = 0;
  for (final entry in entries) {
    identities.add(entry.identityKey);
    if (entry.unwatched) unwatched++;
    if (entry.episodePending) pending++;
  }
  return CalendarDaySummary(
    seriesCount: identities.length,
    episodeCount: entries.length,
    unwatchedEpisodeCount: unwatched,
    pendingEpisodeCount: pending,
  );
}

/// 当天哪些条目是该剧的**首条**（剧级信息只在首条展示一次）。
///
/// [entries] 已按「剧名 → 身份键 → 季 → 集号」排好序；每遇到一个新的身份键就记下
/// 它的下标，同一天同一部剧只有一条为 true，因此剧级行既不会重复也不会缺失。
Set<int> followingCalendarSeriesLeadIndexes(List<CalendarEntry> entries) {
  final seen = <String>{};
  final leads = <int>{};
  for (var index = 0; index < entries.length; index++) {
    if (seen.add(entries[index].identityKey)) leads.add(index);
  }
  return leads;
}

/// 单日查询：没有条目的日子返回空 [CalendarDay]（`date` 已归一到 0:00）。
CalendarDay followingCalendarDayOf(
  Map<DateTime, List<CalendarEntry>> byDay,
  DateTime day,
) {
  final date = DateTime(day.year, day.month, day.day);
  return CalendarDay(
    date: date,
    entries: byDay[date] ?? const <CalendarEntry>[],
  );
}

/// 今日聚合。
CalendarDay followingCalendarToday(
  Map<DateTime, List<CalendarEntry>> byDay, {
  required int nowMs,
}) => followingCalendarDayOf(byDay, followingCalendarDateOf(nowMs));

/// 当月有更新的日号集合（`1`~`31`，供月历画圆点）。
Set<int> followingCalendarUpdateDaysInMonth(
  Map<DateTime, List<CalendarEntry>> byDay, {
  required int year,
  required int month,
}) {
  final anchor = DateTime(year, month);
  final days = <int>{};
  for (final entry in byDay.entries) {
    if (entry.value.isEmpty) continue;
    if (entry.key.year != anchor.year || entry.key.month != anchor.month) {
      continue;
    }
    days.add(entry.key.day);
  }
  return days;
}

/// 当月每天的「是否有未看」：键是日号，值 `true` 表示当天至少有一条未看。
///
/// 只包含有条目的日子；供日历画「已播未看=强调色 / 其余（全已看或待播）=弱化色」圆点。
Map<int, bool> followingCalendarUnwatchedDaysInMonth(
  Map<DateTime, List<CalendarEntry>> byDay, {
  required int year,
  required int month,
}) {
  final anchor = DateTime(year, month);
  final days = <int, bool>{};
  for (final entry in byDay.entries) {
    if (entry.value.isEmpty) continue;
    if (entry.key.year != anchor.year || entry.key.month != anchor.month) {
      continue;
    }
    final unwatched = entry.value.any((item) => item.unwatched);
    days[entry.key.day] = unwatched;
  }
  return days;
}

/// 某天所在周的周一 0:00。
DateTime followingCalendarWeekStart(DateTime day) =>
    DateTime(day.year, day.month, day.day - (day.weekday - 1));

/// 锚点日所在周（周一 → 周日）的 7 天明细。
CalendarWeek followingCalendarWeek(
  Map<DateTime, List<CalendarEntry>> byDay, {
  required DateTime anchor,
}) {
  final start = followingCalendarWeekStart(anchor);
  final days = <CalendarDay>[
    for (var offset = 0; offset < 7; offset++)
      followingCalendarDayOf(
        byDay,
        DateTime(start.year, start.month, start.day + offset),
      ),
  ];
  return CalendarWeek(
    anchor: DateTime(anchor.year, anchor.month, anchor.day),
    days: days,
  );
}

// ---------------------------------------------------------------------------
// 内部实现
// ---------------------------------------------------------------------------

/// 单部追番的归日：TMDB 排期优先，否则降级本地；每一集调一次 [put]。
void _collectItem(
  Following item, {
  required int nowMs,
  required List<FollowingAirTime> airTimes,
  required void Function(
    DateTime day,
    int episode,
    CalendarSource source, {
    String episodeTitle,
    bool aired,
    int airingThroughEpisode,
  })
  put,
}) {
  final released = math.max(0, item.releasedEpisode);
  // 日历单位是自然日：排期日不晚于今天就算已播出，当天晚些时候的排期
  // 不该被读成「还没播」（TMDB 的 air_date 没有钟点）。
  final nowDay = followingCalendarDateOf(nowMs);

  final scheduled = <({DateTime day, int episode, String title})>[];
  for (final airTime in airTimes) {
    final day = _airDay(airTime.airAtMs, nowMs);
    if (day == null) continue;
    final episode = airTime.episode > 0 ? airTime.episode : released;
    if (episode < 1) continue;
    scheduled.add((day: day, episode: episode, title: airTime.episodeTitle));
  }
  if (scheduled.isNotEmpty) {
    // 排期上限取该剧该季全部 airTimes 的最大集号，供「TMDB 排期至 E14」。
    var airingThrough = 0;
    for (final slot in scheduled) {
      if (slot.episode > airingThrough) airingThrough = slot.episode;
    }
    for (final slot in scheduled) {
      put(
        slot.day,
        slot.episode,
        CalendarSource.real,
        episodeTitle: slot.title,
        aired: !slot.day.isAfter(nowDay),
        airingThroughEpisode: airingThrough,
      );
    }
    return;
  }

  final nextDay = _airDay(item.nextAirAtMs, nowMs);
  if (nextDay != null) {
    put(
      nextDay,
      released,
      CalendarSource.real,
      aired: !nextDay.isAfter(nowDay),
    );
    return;
  }

  // 降级：本地时间归日，**只出一条最新一集**（`released`），不逐集展开。
  // 这条路径的日期是 lastCheckedAt/metadataUpdatedAt/updatedAt 推算的假日期，
  // 已属降级；再把全部历史未看集摊到那一天（长番 200 集就是 200 条噪音）会让
  // 列表不可用。未看信息由 unwatchedCount / progressLabel / 日汇总表达，不靠条数堆。
  // 「一集一条」只用在日期可信的两条路径（airTimes / nextAirAtMs）上。
  // 集号未知（released < 1）也留一条，日历上仍要能看到这部剧这天有动静。
  // 降级日期的语义是「已发布」，因此恒视为已播出。
  final day = _localDay(item, nowMs);
  put(day, released, CalendarSource.local);
}

/// 真实播出时间 → 自然日；`<= 0` 或超出可信窗口返回 null（视为不可用）。
DateTime? _airDay(int airAtMs, int nowMs) {
  if (airAtMs <= 0) return null;
  final lead = nowMs + FollowingCalendarPolicy.maxAirLead.inMilliseconds;
  final age = nowMs - FollowingCalendarPolicy.maxAirAge.inMilliseconds;
  if (airAtMs > lead || airAtMs < age) return null;
  return followingCalendarDateOf(airAtMs);
}

/// 本地可用时间 → 自然日：检查时间 → 元数据时间 → 更新时间 → 今天。
DateTime _localDay(Following item, int nowMs) {
  final limit = nowMs + FollowingCalendarPolicy.maxLocalSkew.inMilliseconds;
  final floor = nowMs - FollowingCalendarPolicy.maxAirAge.inMilliseconds;
  for (final candidate in [
    item.lastCheckedAtMs,
    item.metadataUpdatedAtMs,
    item.updatedAtMs,
  ]) {
    if (candidate <= 0 || candidate > limit || candidate < floor) continue;
    return followingCalendarDateOf(candidate);
  }
  return followingCalendarDateOf(nowMs);
}

/// 剧名 → 身份键 → 季 → 集号（身份键只为同一剧名下的稳定排序）。
int _compareEntries(CalendarEntry a, CalendarEntry b) {
  final byName = a.vodName.compareTo(b.vodName);
  if (byName != 0) return byName;
  final byKey = a.seriesKey.compareTo(b.seriesKey);
  if (byKey != 0) return byKey;
  final bySeason = a.season.compareTo(b.season);
  if (bySeason != 0) return bySeason;
  return a.episode.compareTo(b.episode);
}
