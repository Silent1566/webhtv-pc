/// 追剧日历的「真实播出时间」编排（Phase 9 · P2-1 配套）。
///
/// 链路：追番 → TMDB 剧集身份 → `/tv/{id}/season/{n}` 各集 `air_date`
/// → [FollowingAirTime]。本层**不直接发请求**：匹配与取集都由调用方注入，
/// 因此单测可以完全离线。
///
/// 契约：
/// - TMDB 未配置时**零网络请求**直接返回空（日历退回本地推算）；
/// - 单请求超时/异常/无匹配都只跳过该剧并写负缓存，**任何情况都不抛异常**；
/// - 成功结果缓存 6 小时、失败缓存 30 分钟，有效期内同一部剧不重复请求；
/// - 批量串行分组，组内并发上限由 [FollowingAirTimeService.maxConcurrency] 决定。
library;

import 'dart:math' as math;

import '../core/following.dart';
import '../core/following_calendar.dart';
import '../core/tmdb_media.dart';

/// 追番 → TMDB 剧集 id；`null` 表示未匹配或无可用身份（不发起取集请求）。
typedef FollowingTmdbIdResolver = Future<int?> Function(Following item);

/// 取 TMDB 某一季的各集；[seasonNumber] 是 **TMDB 1 基**季号。
typedef FollowingSeasonEpisodeFetcher = Future<List<TmdbEpisode>> Function(
  int tmdbId,
  int seasonNumber,
);

/// 一部追番该季的**官方总集数**（追剧日历进度分母的首选来源）。
///
/// 来源就是 TMDB `/tv/{id}/season/{n}` 返回的剧集条数，与 [FollowingAirTime]
/// 共享同一次取集请求，**不额外发请求**。
class FollowingSeasonTotal {
  const FollowingSeasonTotal({
    required this.seriesKey,
    required this.season,
    required this.totalEpisodes,
  });

  final String seriesKey;

  /// 数据层的季下标（0 基，与 [FollowingAirTime.season] 一致）。
  final int season;

  /// 官方该季总集数；产出时恒为正。
  final int totalEpisodes;

  /// `followingIdentityKey` 格式的身份键。
  String get identityKey => followingIdentityKey(seriesKey, season);
}

/// 同一批追番的一次取集结果：播出时间与官方该季总集数是同一份数据。
class FollowingAirTimeResult {
  const FollowingAirTimeResult({
    required this.airTimes,
    required this.seasonTotals,
  });

  /// 空结果（未配置/空批/全部失败）。
  static const FollowingAirTimeResult empty = FollowingAirTimeResult(
    airTimes: [],
    seasonTotals: [],
  );

  final List<FollowingAirTime> airTimes;

  final List<FollowingSeasonTotal> seasonTotals;
}

/// 把一批追番解析成 [FollowingAirTime] 与 [FollowingSeasonTotal]。
class FollowingAirTimeService {
  FollowingAirTimeService({
    required bool Function() isConfigured,
    required FollowingTmdbIdResolver resolveTmdbId,
    required FollowingSeasonEpisodeFetcher fetchEpisodes,
    DateTime Function()? clock,
    this.successTtl = const Duration(hours: 6),
    this.failureTtl = const Duration(minutes: 30),
    this.requestTimeout = const Duration(seconds: 10),
    this.maxConcurrency = 2,
  }) : _isConfigured = isConfigured,
       _resolveTmdbId = resolveTmdbId,
       _fetchEpisodes = fetchEpisodes,
       _clock = clock ?? DateTime.now;

  // ignore_for_file: prefer_initializing_formals
  final bool Function() _isConfigured;
  final FollowingTmdbIdResolver _resolveTmdbId;
  final FollowingSeasonEpisodeFetcher _fetchEpisodes;
  final DateTime Function() _clock;

  /// 成功结果的缓存时长。
  final Duration successTtl;

  /// 失败（超时/异常/无匹配）的负缓存时长。
  final Duration failureTtl;

  /// 单次匹配或取集的超时上限。
  final Duration requestTimeout;

  /// 组内并发上限（TMDB 有速率限制）。
  final int maxConcurrency;

  /// `identityKey` → 缓存条目（含成功与失败两种）。
  final Map<String, _AirTimeCacheEntry> _cache = {};

  /// 为本批追番取真实播出时间；只为本批产出条目。
  ///
  /// 未配置 TMDB、批量为空或全部失败时返回空列表，**不抛异常**。
  Future<List<FollowingAirTime>> airTimesFor(List<Following> items) async =>
      (await resolveFor(items)).airTimes;

  /// 为本批追番取**官方该季总集数**（进度分母首选来源）。
  ///
  /// 与 [airTimesFor] 共用缓存：先调哪个都只发一次取集请求，之后命中缓存。
  /// 未配置 TMDB、批量为空或全部失败时返回空列表，**不抛异常**。
  Future<List<FollowingSeasonTotal>> seasonTotalsFor(
    List<Following> items,
  ) async => (await resolveFor(items)).seasonTotals;

  /// 一次取集同时得到播出时间与官方该季总集数（两者是同一份数据的两种视图）。
  ///
  /// 未配置 TMDB、批量为空或全部失败时返回 [FollowingAirTimeResult.empty]，
  /// **不抛异常**。
  Future<FollowingAirTimeResult> resolveFor(List<Following> items) async {
    if (items.isEmpty) return FollowingAirTimeResult.empty;
    if (!_safeIsConfigured()) return FollowingAirTimeResult.empty;

    final airTimes = <FollowingAirTime>[];
    final seasonTotals = <FollowingSeasonTotal>[];
    final batchSize = math.max(1, maxConcurrency);
    for (var index = 0; index < items.length; index += batchSize) {
      final batch = items.sublist(
        index,
        math.min(index + batchSize, items.length),
      );
      final groups = await Future.wait(batch.map(_resolveOne));
      for (final group in groups) {
        airTimes.addAll(group.airTimes);
        seasonTotals.addAll(group.seasonTotals);
      }
    }
    return FollowingAirTimeResult(
      airTimes: airTimes,
      seasonTotals: seasonTotals,
    );
  }

  bool _safeIsConfigured() {
    try {
      return _isConfigured();
    } catch (_) {
      return false;
    }
  }

  /// 单部追番：命中缓存直接用，否则「匹配 + 取集 + 归日/计数」。
  Future<FollowingAirTimeResult> _resolveOne(Following item) async {
    final key = item.identityKey;
    final nowMs = _clock().millisecondsSinceEpoch;
    final cached = _cache[key];
    if (cached != null && cached.expiresAtMs > nowMs) {
      return cached.result ?? FollowingAirTimeResult.empty;
    }

    try {
      final tmdbId = await _resolveTmdbId(item).timeout(requestTimeout);
      if (tmdbId == null || tmdbId <= 0) {
        _putFailure(key, nowMs);
        return FollowingAirTimeResult.empty;
      }
      // TMDB 季号从 1 开始，数据层 `Following.season` 是 0 基下标：请求时 +1。
      final episodes = await _fetchEpisodes(
        tmdbId,
        math.max(0, item.season) + 1,
      ).timeout(requestTimeout);

      final airTimes = <FollowingAirTime>[];
      for (final episode in episodes) {
        final airAtMs = _localDayStartMs(episode.date);
        if (airAtMs == null) continue;
        airTimes.add(
          FollowingAirTime(
            seriesKey: item.seriesKey,
            season: item.season,
            episode: episode.number,
            airAtMs: airAtMs,
            // 同一份取集结果里的集名，不额外发请求；集名缺失时留空。
            episodeTitle: episode.title.trim(),
          ),
        );
      }
      // 取集列表本身就是该季全部剧集：长度即官方总集数，不必另发请求。
      final seasonTotals = <FollowingSeasonTotal>[];
      if (episodes.isNotEmpty) {
        seasonTotals.add(
          FollowingSeasonTotal(
            seriesKey: item.seriesKey,
            season: item.season,
            totalEpisodes: episodes.length,
          ),
        );
      }
      final result = FollowingAirTimeResult(
        airTimes: airTimes,
        seasonTotals: seasonTotals,
      );
      _cache[key] = _AirTimeCacheEntry(
        result: result,
        expiresAtMs: nowMs + successTtl.inMilliseconds,
      );
      return result;
    } catch (_) {
      // 超时/网络/解析失败一律降级：只跳过这一部剧。
      _putFailure(key, nowMs);
      return FollowingAirTimeResult.empty;
    }
  }

  void _putFailure(String key, int nowMs) {
    _cache[key] = _AirTimeCacheEntry(
      result: null,
      expiresAtMs: nowMs + failureTtl.inMilliseconds,
    );
  }
}

/// 缓存条目：`result == null` 表示负缓存（上次失败）。
class _AirTimeCacheEntry {
  const _AirTimeCacheEntry({required this.result, required this.expiresAtMs});

  final FollowingAirTimeResult? result;
  final int expiresAtMs;
}

final RegExp _isoDatePattern = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');

/// `YYYY-MM-DD` → **本地时区**自然日 0 点的毫秒纪元；空或非法返回 `null`。
///
/// 必须用 `DateTime(y, m, d)` 构造：`DateTime.parse('2019-11-20')` 会按 UTC
/// 解析，东八区会偏成前一天的 20:00，归日直接错一格。
int? _localDayStartMs(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return null;
  final match = _isoDatePattern.firstMatch(text);
  if (match == null) return null;
  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final day = int.parse(match.group(3)!);
  final date = DateTime(year, month, day);
  // 回读校验：`DateTime(2019, 2, 30)` 会被归一化成 3 月 2 日，这类脏数据要丢掉。
  if (date.year != year || date.month != month || date.day != day) return null;
  return date.millisecondsSinceEpoch;
}
