/// TMDB 播放入口契约（`docs/phase4/design/04` §8）。
///
/// 职责：
/// - 承载从详情页透传到播放页的**季度身份**（`04` §8.1 的 7 个参数）；
/// - 提供剧集定位的三段优先级（`04` §8.2）。
///
/// 关键契约：
/// - `episodeUrl` 是同一 TMDB 集内区分版本的**唯一可靠标识**，必须优先；
/// - 季度身份**不进入** `PlaybackDecision`（`04` §8.3），本文件也不引用它；
/// - 纯逻辑：不依赖 `flutter/material.dart` 与 `dart:io`。
library;

import 'protocol.dart';
import 'tmdb_identity.dart';

/// 播放入口透传的季度身份（`04` §8.1）。
///
/// 未确证的字段用 `-1` / 空串表示，不猜测：
/// - `UnknownSeason` 时 `seasonNumber = -1`；
/// - 无法确定集号时 `episodeNumber = -1`。
class TmdbPlaybackIdentity {
  const TmdbPlaybackIdentity({
    required this.tmdbId,
    required this.mediaType,
    this.seasonNumber = -1,
    this.episodeNumber = -1,
    this.flagKey = '',
    this.episodeUrl = '',
    this.episodeName = '',
  });

  /// 媒体身份（`04` §8.1）。
  final int tmdbId;
  final TmdbMediaType mediaType;

  /// 已确证季度；`UnknownSeason` 时为 `-1`（不传）。
  final int seasonNumber;

  /// TMDB 集号；无法确定时为 `-1`（不传）。
  final int episodeNumber;

  /// 线路绑定键（`02` §2.2）。
  final String flagKey;

  /// **来源剧集 URL**（`04` §8.2 的消歧关键）。
  final String episodeUrl;

  /// 来源剧集名。
  final String episodeName;

  bool get hasIdentity => tmdbId > 0;

  bool get isTv => mediaType == TmdbMediaType.tv;

  /// 是否带已确证季度（`UnknownSeason` 时不传，`04` §8.1）。
  bool get hasSeason => isTv && seasonNumber >= 0;

  bool get hasEpisodeNumber => isTv && episodeNumber > 0;

  TmdbIdentity? get identity => TmdbIdentity.of(mediaType, tmdbId);

  /// 从剧集 + 线路上下文构造（详情页调用）。
  static TmdbPlaybackIdentity of({
    required TmdbIdentity? identity,
    required VodEpisode episode,
    required String flagKey,
    int seasonNumber = -1,
    int episodeNumber = -1,
  }) {
    return TmdbPlaybackIdentity(
      tmdbId: identity?.tmdbId ?? 0,
      mediaType: identity?.mediaType ?? TmdbMediaType.tv,
      seasonNumber: seasonNumber,
      episodeNumber: episodeNumber,
      flagKey: flagKey,
      episodeUrl: episode.url,
      episodeName: episode.name,
    );
  }

  @override
  String toString() =>
      'TmdbPlaybackIdentity(${mediaType.name}:$tmdbId season=$seasonNumber '
      'episode=$episodeNumber flag=$flagKey)';
}

/// 剧集定位结果。
class TmdbEpisodeLocation {
  const TmdbEpisodeLocation({required this.index, required this.matchedBy});

  /// 命中的剧集下标；`-1` 表示未命中。
  final int index;

  /// 命中依据：`episodeUrl` / `episodeName` / `tmdbEpisodeNumber` / `none`。
  final String matchedBy;

  bool get found => index >= 0;
}

/// 剧集定位（`04` §8.2）。
///
/// 三段优先级固定：
/// ```text
/// 1. episodeUrl 精确相等
/// 2. episodeName 相等（忽略大小写）
/// 3. TMDB 季集号相等（兜底，读 `extra['tmdb_episode_number']`）
/// ```
///
/// 两条兼容语义（`05` §3.5）：
/// - **URL 变但集名相同 → 仍视为同集**（线路换 CDN 的容错）：第 2 段兜住；
/// - **同 TMDB 集号 + URL 与集名都不同 → 仍视为同集**（跨源续播）：第 3 段兜住。
abstract final class TmdbEpisodeLocator {
  /// 命中的 `matchedBy` 取值。
  static const String byUrl = 'episodeUrl';
  static const String byName = 'episodeName';
  static const String byNumber = 'tmdbEpisodeNumber';
  static const String byNone = 'none';

  static TmdbEpisodeLocation locate({
    required List<VodEpisode> episodes,
    required TmdbPlaybackIdentity identity,
  }) {
    if (episodes.isEmpty) {
      return const TmdbEpisodeLocation(index: -1, matchedBy: byNone);
    }

    // 1. episodeUrl 精确相等（唯一可靠标识）
    final url = identity.episodeUrl.trim();
    if (url.isNotEmpty) {
      for (var i = 0; i < episodes.length; i++) {
        if (episodes[i].url == url) {
          return TmdbEpisodeLocation(index: i, matchedBy: byUrl);
        }
      }
    }

    // 2. episodeName 相等（忽略大小写）
    final name = identity.episodeName.trim().toLowerCase();
    if (name.isNotEmpty) {
      for (var i = 0; i < episodes.length; i++) {
        if (episodes[i].name.trim().toLowerCase() == name) {
          return TmdbEpisodeLocation(index: i, matchedBy: byName);
        }
      }
    }

    // 3. TMDB 季集号相等（兜底）
    if (identity.hasEpisodeNumber) {
      for (var i = 0; i < episodes.length; i++) {
        final raw = episodes[i].extra['tmdb_episode_number'];
        final number = raw is int ? raw : (raw is num ? raw.toInt() : null);
        if (number == identity.episodeNumber) {
          return TmdbEpisodeLocation(index: i, matchedBy: byNumber);
        }
      }
    }

    return const TmdbEpisodeLocation(index: -1, matchedBy: byNone);
  }

  /// 便捷入口：只要下标（未命中返回 `-1`）。
  static int indexOf({
    required List<VodEpisode> episodes,
    required TmdbPlaybackIdentity identity,
  }) => locate(episodes: episodes, identity: identity).index;
}

/// 自动连播的下一集选择（`04` §8.4）。
///
/// 三条约束：
/// 1. 仍在**当前线路**内（跨线路切换由换源显式触发）；
/// 2. 仍在**当前季度**内；
/// 3. 跨季度边界时**停止**（不跨季连播）。
abstract final class TmdbAutoPlay {
  static int nextIndex({
    required List<VodEpisode> episodes,
    required int currentIndex,
    required List<int> availableSeasons,
    required int selectedSeason,
  }) {
    if (currentIndex < 0 || currentIndex >= episodes.length) return -1;
    final next = currentIndex + 1;
    if (next >= episodes.length) return -1;
    // 可播放季度为空 → 扁平列表，无季度边界
    if (availableSeasons.isEmpty) return next;
    if (selectedSeason < 0) return next;

    final season = _seasonOf(episodes[next]);
    // 未分类的集无法被证明不属于当前季 → 视为同季（不丢集）
    if (season < 0 || season == selectedSeason) return next;
    // 跨季度边界 → 停止自动连播
    return -1;
  }

  /// 单集所在季度（`-1` 未分类）。
  static int _seasonOf(VodEpisode episode) {
    final raw = episode.extra['tmdb_season_number'];
    final number = raw is int ? raw : (raw is num ? raw.toInt() : null);
    return number ?? -1;
  }
}

/// 来源历史键（`02` §6.1）。
///
/// 季度进度与来源 `history` 的关联键：**不含 TMDB 身份**，因此 TMDB 失败或
/// 未匹配时依然可用（`04` §3.4 失败隔离）。
abstract final class TmdbHistoryKey {
  static const String separator = '@@@';

  static String of({
    required String siteKey,
    required String vodId,
    required String flag,
    required String episodeUrl,
  }) => [siteKey, vodId, flag, episodeUrl].join(separator);
}
