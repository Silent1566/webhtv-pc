import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/detail_recommendation.dart';
import 'package:webhtv_pc/core/following.dart';
import 'package:webhtv_pc/core/home_feed.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/services/storage.dart';

HomeItem item(String key, {HomeItemKind kind = HomeItemKind.resume}) =>
    HomeItem(kind: kind, key: key, title: key);

void main() {
  test('完播作品不从热门或推荐补位，同名不同身份的作品仍可进入', () {
    const completed = PlaybackHistory(
      id: 1,
      siteKey: 'site',
      vodId: 'movie',
      vodName: '《雪夜》网盘版',
      flag: 'line',
      episodeName: '',
      episodeId: 'movie',
      positionMs: 599000,
      durationMs: 600000,
      updatedAt: 1,
      tmdbId: 10,
      mediaType: 'movie',
    );
    HomeItem recommendation(String title, int id) => HomeItem(
      kind: HomeItemKind.recommend,
      key: 'movie:$id',
      title: title,
      entry: RecommendationEntry(
        item: TmdbItem(tmdbId: id, mediaType: TmdbMediaType.movie, title: title),
        source: RecommendationSource.tmdb,
      ),
    );
    final feed = HomeFeed(hero: [
      recommendation('Snowy Night', 10),
      recommendation('雪夜', 11),
    ]);
    final pool = homeHeroCandidates(
      feed,
      history: const [completed],
      hot: [
        item('雪夜', kind: HomeItemKind.hot),
        item('未看作品', kind: HomeItemKind.hot),
      ],
    );
    expect(pool.map((item) => item.key), ['movie:11', '未看作品']);
  });

  test('播完普通一集不等于看完整部剧', () {
    const history = PlaybackHistory(
      id: 3,
      siteKey: 'site',
      vodId: 'first-episode',
      vodName: '连载剧',
      flag: 'line',
      episodeName: '第1集',
      episodeId: 'one',
      positionMs: 600000,
      durationMs: 600000,
      updatedAt: 1,
      completed: true,
      tmdbId: 12,
      mediaType: 'tv',
    );
    final feed = HomeFeed(hero: [item('连载剧', kind: HomeItemKind.recommend)]);
    expect(
      homeHeroCandidates(feed, history: const [history]).map((item) => item.title),
      ['连载剧'],
    );
  });

  test('按季和集核对最新已播集，不看播放进度', () {
    PlaybackHistory episode(String name, int positionMs) => PlaybackHistory(
      id: 1,
      siteKey: 'site',
      vodId: 'tv',
      vodName: '连载剧',
      flag: 'line',
      episodeName: name,
      episodeId: name,
      positionMs: positionMs,
      durationMs: 600000,
      updatedAt: 1,
      tmdbId: 12,
      mediaType: 'tv',
    );
    final feed = HomeFeed(hero: [item('连载剧', kind: HomeItemKind.hot)]);
    List<HomeItem> select(PlaybackHistory row, {bool tracked = false}) =>
        homeHeroCandidates(
          feed,
          history: [row],
          followings: [
            if (tracked) Following(
              seriesKey: 'tv',
              season: 0,
              siteKey: 'site',
              vodId: 'tv',
              vodName: '连载剧',
              latestReleasedEpisode: 3,
              latestEpisodeName: 'S02E03',
            ),
          ],
          lastAiredEpisodeFor: tracked ? null : (_) => (season: 2, episode: 3),
        );
    expect(select(episode('S01E03', 600000)), hasLength(1));
    expect(select(episode('第3集', 600000)), hasLength(1));
    expect(select(episode('S02E02', 600000)), hasLength(1));
    expect(select(episode('S02E03', 1)), isEmpty);
    expect(select(episode('S01E03', 600000), tracked: true), hasLength(1));
    expect(select(episode('S02E03', 1), tracked: true), isEmpty);
  });

  test('第24集网盘文件名可直接按最新已播集过滤', () {
    PlaybackHistory episode(String name) => PlaybackHistory(
      id: 24,
      siteKey: 'netdisk',
      vodId: 'series',
      vodName: '今天是太阳雨',
      flag: '4K',
      episodeName: name,
      episodeId: name,
      positionMs: 5000,
      durationMs: 3267907,
      updatedAt: 1,
      tmdbId: 307853,
      mediaType: 'tv',
    );
    final feed = HomeFeed(hero: [item('今天是太阳雨', kind: HomeItemKind.hot)]);
    List<HomeItem> select(String name, int latest) => homeHeroCandidates(
      feed,
      history: [episode(name)],
      lastAiredEpisodeFor: (_) => (season: 1, episode: latest),
    );
    expect(select('24 4K.mkv(5.34 GB)', 24), isEmpty);
    expect(select('24 4K.mkv(5.34 GB)', 25), hasLength(1));
    expect(select('24-25 4K.mkv(5.34 GB)', 24), hasLength(1));
  });

  test('已看完的旧集不会挡住同一部追剧的新一集', () {
    const completed = PlaybackHistory(
      id: 1,
      siteKey: 'site',
      vodId: 'show',
      vodName: '追剧中',
      flag: 'line',
      episodeName: '第1集',
      episodeId: 'one',
      positionMs: 600000,
      durationMs: 600000,
      updatedAt: 1,
      completed: true,
    );
    final feed = buildHomeFeed(
      history: const [completed],
      followings: [
        Following(
          seriesKey: 'show',
          season: 1,
          siteKey: 'site',
          vodId: 'show',
          vodName: '追剧中',
          watchedEpisode: 1,
          latestReleasedEpisode: 2,
        ),
      ],
    );
    final pool = homeHeroCandidates(feed, history: const [completed]);
    expect(pool.single.following?.latestReleasedEpisode, 2);
  });

  test('首批hero之后的后续作品仍进入资格候选池', () {
    final hero = [for (var i = 0; i < 6; i++) item('show$i')];
    final rail = [for (var i = 0; i < 20; i++) item('show$i')];
    final feed = HomeFeed(hero: hero, rails: [HomeRail(
      kind: HomeRailKind.resume, title: '继续观看', items: rail,
    )]);
    final pool = homeHeroCandidates(feed);
    expect(pool.map((x) => x.key), [for (var i = 0; i < 20; i++) 'show$i']);
    expect(feed.hero.length, 6);
    expect(feed.rails.single.items.length, 20, reason: '候选过滤不改轨道原数据');
  });

  test('热门可补位，但不能把同一作品加入两次', () {
    final feed = HomeFeed(hero: [item('local')], rails: [HomeRail(
      kind: HomeRailKind.resume, title: '继续观看', items: [item('local'), item('later')],
    )]);
    final pool = homeHeroCandidates(feed, hot: [item('later'), item('hot', kind: HomeItemKind.hot)]);
    expect(pool.map((x) => x.key), ['local', 'later', 'hot']);
  });

  test('候选池有总量上限，不因全部不合格无界查找', () {
    final feed = HomeFeed(hero: [for (var i=0; i<200;i++) item('s$i')]);
    expect(homeHeroCandidates(feed).length, 120);
  });
}
