/// Phase 4 · TMDB 播放入口契约：季度身份、剧集定位三段优先级、自动连播
/// （`docs/phase4/design/04` §8.2、§8.4）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/core/tmdb_playback.dart';

VodEpisode _episode(String name, String url, {int? season, int? number}) =>
    VodEpisode(
      name: name,
      url: url,
      extra: {
        'tmdb_season_number': ?season,
        'tmdb_episode_number': ?number,
      },
    );

void main() {
  group('播放入口 7 参数（§8.1）', () {
    test('已确证季度：seasonNumber/episodeNumber 透传', () {
      final identity = TmdbPlaybackIdentity.of(
        identity: TmdbIdentity.of(TmdbMediaType.tv, 1399),
        episode: _episode('第 2 集', 'https://cdn/2.m3u8'),
        flagKey: 'f#0',
        seasonNumber: 1,
        episodeNumber: 2,
      );
      expect(identity.tmdbId, 1399);
      expect(identity.mediaType, TmdbMediaType.tv);
      expect(identity.seasonNumber, 1);
      expect(identity.episodeNumber, 2);
      expect(identity.flagKey, 'f#0');
      expect(identity.episodeUrl, 'https://cdn/2.m3u8');
      expect(identity.episodeName, '第 2 集');
      expect(identity.hasSeason, isTrue);
    });

    test('未确证季度：seasonNumber = -1，hasSeason 为假', () {
      final identity = TmdbPlaybackIdentity.of(
        identity: TmdbIdentity.of(TmdbMediaType.tv, 1399),
        episode: _episode('第 2 集', 'https://cdn/2.m3u8'),
        flagKey: 'f#0',
      );
      expect(identity.seasonNumber, -1);
      expect(identity.episodeNumber, -1);
      expect(identity.hasSeason, isFalse);
      expect(identity.hasEpisodeNumber, isFalse);
    });

    test('电影不视为剧集季度', () {
      final identity = TmdbPlaybackIdentity.of(
        identity: TmdbIdentity.of(TmdbMediaType.movie, 550),
        episode: _episode('正片', 'https://cdn/m.mp4'),
        flagKey: 'f',
        seasonNumber: 1,
      );
      expect(identity.isTv, isFalse);
      expect(identity.hasSeason, isFalse);
    });

    test('无 TMDB 身份：hasIdentity 为假（不进入季度进度）', () {
      final identity = TmdbPlaybackIdentity.of(
        identity: null,
        episode: _episode('第 1 集', 'u'),
        flagKey: 'f',
      );
      expect(identity.hasIdentity, isFalse);
      expect(identity.identity, isNull);
    });
  });

  group('剧集定位三段优先级（§8.2）', () {
    final episodes = [
      _episode('第 1 集', 'https://cdn/1.m3u8', season: 1, number: 1),
      _episode('第 2 集', 'https://cdn/2.m3u8', season: 1, number: 2),
      _episode('第 3 集', 'https://cdn/3.m3u8', season: 1, number: 3),
    ];

    test('第 1 段：episodeUrl 精确相等优先（即使集名不同）', () {
      final location = TmdbEpisodeLocator.locate(
        episodes: episodes,
        identity: const TmdbPlaybackIdentity(
          tmdbId: 1399,
          mediaType: TmdbMediaType.tv,
          seasonNumber: 1,
          episodeNumber: 1,
          episodeUrl: 'https://cdn/3.m3u8',
          episodeName: '完全不同的名字',
        ),
      );
      expect(location.index, 2);
      expect(location.matchedBy, TmdbEpisodeLocator.byUrl);
    });

    test('第 2 段：URL 变但集名相同 → 仍视为同集（线路换 CDN 容错）', () {
      final location = TmdbEpisodeLocator.locate(
        episodes: episodes,
        identity: const TmdbPlaybackIdentity(
          tmdbId: 1399,
          mediaType: TmdbMediaType.tv,
          seasonNumber: 1,
          episodeNumber: 9,
          episodeUrl: 'https://cdn-new/2.m3u8',
          episodeName: '第 2 集',
        ),
      );
      expect(location.index, 1);
      expect(location.matchedBy, TmdbEpisodeLocator.byName);
    });

    test('集名比较忽略大小写', () {
      final location = TmdbEpisodeLocator.locate(
        episodes: [_episode('Episode 2', 'https://cdn/2.m3u8')],
        identity: const TmdbPlaybackIdentity(
          tmdbId: 1,
          mediaType: TmdbMediaType.tv,
          episodeName: 'EPISODE 2',
        ),
      );
      expect(location.index, 0);
      expect(location.matchedBy, TmdbEpisodeLocator.byName);
    });

    test('第 3 段：同 TMDB 集号 + URL 与集名都不同 → 仍视为同集（跨源续播）', () {
      final location = TmdbEpisodeLocator.locate(
        episodes: episodes,
        identity: const TmdbPlaybackIdentity(
          tmdbId: 1399,
          mediaType: TmdbMediaType.tv,
          seasonNumber: 1,
          episodeNumber: 3,
          episodeUrl: 'https://other-cdn/x.m3u8',
          episodeName: '第 3 话',
        ),
      );
      expect(location.index, 2);
      expect(location.matchedBy, TmdbEpisodeLocator.byNumber);
    });

    test('三段都不命中 → index = -1', () {
      final location = TmdbEpisodeLocator.locate(
        episodes: episodes,
        identity: const TmdbPlaybackIdentity(
          tmdbId: 1399,
          mediaType: TmdbMediaType.tv,
          seasonNumber: 1,
          episodeNumber: 99,
          episodeUrl: 'https://missing/x.m3u8',
          episodeName: '不存在',
        ),
      );
      expect(location.index, -1);
      expect(location.found, isFalse);
      expect(location.matchedBy, TmdbEpisodeLocator.byNone);
    });

    test('空线路列表 → index = -1', () {
      expect(
        TmdbEpisodeLocator.indexOf(
          episodes: const [],
          identity: const TmdbPlaybackIdentity(
            tmdbId: 1,
            mediaType: TmdbMediaType.tv,
          ),
        ),
        -1,
      );
    });

    test('同一 TMDB 集号的多个版本：URL 优先，不会串到第一个版本', () {
      final multiVersion = [
        _episode('第 2 集', 'https://cdn/v1/2.m3u8', season: 1, number: 2),
        _episode('第 2 集', 'https://cdn/v2/2.m3u8', season: 1, number: 2),
      ];
      final location = TmdbEpisodeLocator.locate(
        episodes: multiVersion,
        identity: const TmdbPlaybackIdentity(
          tmdbId: 1399,
          mediaType: TmdbMediaType.tv,
          seasonNumber: 1,
          episodeNumber: 2,
          episodeUrl: 'https://cdn/v2/2.m3u8',
          episodeName: '第 2 集',
        ),
      );
      expect(location.index, 1);
      expect(location.matchedBy, TmdbEpisodeLocator.byUrl);
    });
  });

  group('自动连播不跨季度（§8.4）', () {
    final episodes = [
      _episode('第 1 集', 'u1', season: 1),
      _episode('第 2 集', 'u2', season: 1),
      _episode('第 1 集', 'u3', season: 2),
      _episode('第 2 集', 'u4', season: 2),
    ];

    test('同季度内 → 前进一集', () {
      expect(
        TmdbAutoPlay.nextIndex(
          episodes: episodes,
          currentIndex: 0,
          availableSeasons: const [1, 2],
          selectedSeason: 1,
        ),
        1,
      );
    });

    test('跨季度边界 → 停止（返回 -1）', () {
      expect(
        TmdbAutoPlay.nextIndex(
          episodes: episodes,
          currentIndex: 1,
          availableSeasons: const [1, 2],
          selectedSeason: 1,
        ),
        -1,
      );
    });

    test('季度末集 → 停止', () {
      expect(
        TmdbAutoPlay.nextIndex(
          episodes: episodes,
          currentIndex: 3,
          availableSeasons: const [1, 2],
          selectedSeason: 2,
        ),
        -1,
      );
    });

    test('未分类集视为同季（不因缺季度信息中断连播）', () {
      final withUnknown = [
        _episode('第 1 集', 'u1', season: 1),
        _episode('第 2 集', 'u2'),
      ];
      expect(
        TmdbAutoPlay.nextIndex(
          episodes: withUnknown,
          currentIndex: 0,
          availableSeasons: const [1],
          selectedSeason: 1,
        ),
        1,
      );
    });

    test('扁平列表（可播放季度为空）→ 不设季度边界', () {
      expect(
        TmdbAutoPlay.nextIndex(
          episodes: episodes,
          currentIndex: 0,
          availableSeasons: const [],
          selectedSeason: -1,
        ),
        1,
      );
    });

    test('非法下标 → 停止', () {
      expect(
        TmdbAutoPlay.nextIndex(
          episodes: episodes,
          currentIndex: -1,
          availableSeasons: const [],
          selectedSeason: -1,
        ),
        -1,
      );
      expect(
        TmdbAutoPlay.nextIndex(
          episodes: episodes,
          currentIndex: 99,
          availableSeasons: const [],
          selectedSeason: -1,
        ),
        -1,
      );
    });
  });
}
