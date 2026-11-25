/// 首页三件事的回归门禁（用户 2026-11-25 三条反馈）：
///
/// 1. 直播行不能进首页续播；
/// 2. 同一部作品在首页只能出现一次，**即使它来自两个站点、两套站名**；
/// 3. hero 高度不分档：没有 16:9 背景图的那一张与有图的一样高。
///
/// 这里只测纯逻辑（`core/home_feed.dart`），不建 widget、不碰 AppState。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/home_feed.dart';
import 'package:webhtv_pc/services/storage.dart';

PlaybackHistory _row({
  required int id,
  required String site,
  required String vodId,
  required String title,
  int updatedAt = 100,
  int tmdbId = 0,
  String mediaType = '',
}) => PlaybackHistory(
  id: id,
  siteKey: site,
  vodId: vodId,
  vodName: title,
  vodPic: 'p.jpg',
  flag: '线路',
  episodeName: '第1集',
  episodeId: 'ep1',
  positionMs: 60000,
  durationMs: 100000,
  updatedAt: updatedAt,
  tmdbId: tmdbId,
  mediaType: mediaType,
);

HomeRail? _rail(HomeFeed feed, HomeRailKind kind) {
  for (final rail in feed.rails) {
    if (rail.kind == kind) return rail;
  }
  return null;
}

void main() {
  group('同一部作品只出现一次（跨站点）', () {
    test('网盘站片名里的《》与下载噪声不影响识别同一部作品', () {
      // 真实数据（history 表）：rrdy_night 的站名带网盘噪声，minuo 的站名干净，
      // 两者是同一部剧（TMDB 317787），首页曾经因此出现两张卡。
      final feed = buildHomeFeed(
        history: [
          _row(
            id: 2,
            site: 'rrdy_night',
            vodId: 'a',
            title: '《那一夜，我怀了社长的孩子》百度云网盘夸克下载.阿里云盘.中字.(2026)',
            updatedAt: 200,
            tmdbId: 317787,
            mediaType: 'tv',
          ),
          _row(
            id: 1,
            site: 'minuo',
            vodId: 'b',
            title: '那一夜我怀了社长的孩子',
            updatedAt: 100,
          ),
        ],
        followings: const [],
      );

      expect(feed.hero.length, 1, reason: '同一部作品在 hero 里只能有一张');
      expect(_rail(feed, HomeRailKind.resume)!.items.length, 1);
      expect(feed.hero.single.history?.updatedAt, 200, reason: '留最近看的那一条');
    });

    test('同一 TMDB 身份、站名完全不同也只出现一次', () {
      final feed = buildHomeFeed(
        history: [
          _row(
            id: 2,
            site: 's1',
            vodId: 'a',
            title: '罪蓝之路 4K内嵌中字',
            updatedAt: 200,
            tmdbId: 900,
            mediaType: 'tv',
          ),
          _row(
            id: 1,
            site: 's2',
            vodId: 'b',
            title: '罪蓝之路',
            updatedAt: 100,
            tmdbId: 900,
            mediaType: 'tv',
          ),
        ],
        followings: const [],
      );

      expect(feed.hero.length, 1);
    });

    test('同一片名下是两个 TMDB 身份：那是两部作品，都留', () {
      // 《三体》动画版 / 电视剧版：标题归一化后同名，但身份不同——不能替用户猜。
      final feed = buildHomeFeed(
        history: [
          _row(
            id: 2,
            site: 's1',
            vodId: 'a',
            title: '《三体》动画版',
            updatedAt: 200,
            tmdbId: 111,
            mediaType: 'tv',
          ),
          _row(
            id: 1,
            site: 's2',
            vodId: 'b',
            title: '《三体》电视剧版',
            updatedAt: 100,
            tmdbId: 222,
            mediaType: 'tv',
          ),
        ],
        followings: const [],
      );

      expect(feed.hero.length, 2);
    });

    test('身份收掉的那一条要把标题登记成别名，否则同名的无身份行会漏回来', () {
      final feed = buildHomeFeed(
        history: [
          _row(
            id: 3,
            site: 's1',
            vodId: 'a',
            title: '罪蓝之路 4K内嵌中字',
            updatedAt: 300,
            tmdbId: 900,
            mediaType: 'tv',
          ),
          _row(
            id: 2,
            site: 's2',
            vodId: 'b',
            title: '罪蓝之路',
            updatedAt: 200,
            tmdbId: 900,
            mediaType: 'tv',
          ),
          _row(
            id: 1,
            site: 's3',
            vodId: 'c',
            title: '罪蓝之路',
            updatedAt: 100,
          ),
        ],
        followings: const [],
      );

      expect(feed.hero.length, 1);
      expect(feed.hero.single.history?.id, 3);
    });

    test('不同作品仍各占一条（去重不能吞掉内容）', () {
      final feed = buildHomeFeed(
        history: [
          _row(id: 2, site: 's1', vodId: 'a', title: '罪蓝之路', updatedAt: 200),
          _row(id: 1, site: 's1', vodId: 'b', title: '漫长的季节', updatedAt: 100),
        ],
        followings: const [],
      );

      expect(feed.hero.length, 2);
    });
  });

  group('hero 是轨道的子集', () {
    test('hero 里的续播条目仍然留在自己的轨道里（页面层不得把它删掉）', () {
      // 02 §1 I4：同一部作品在 hero 与它自己那条轨道里各出现一次是**有意的**
      // ——hero 是「今天最值得点的几张」，轨道是完整列表。页面层二次去重若与
      // hero 共用认领器，只有一条续播时整条轨道会连标题一起消失。
      final feed = buildHomeFeed(
        history: [
          _row(id: 1, site: 's1', vodId: 'a', title: '罪蓝之路', updatedAt: 100),
        ],
        followings: const [],
      );

      expect(feed.hero.single.key, _rail(feed, HomeRailKind.resume)!.items.single.key);
    });
  });

  group('直播行不进首页', () {
    test('直播站点的历史行不出现在 hero 与续播轨道', () {
      final feed = buildHomeFeed(
        history: [
          // 真实数据：site_key=Douyu、flag=DouyuLive、episode_name=原画1080P30。
          _row(
            id: 3,
            site: 'Douyu',
            vodId: '冬天到了 该上分了！ 10040721',
            title: '冬天到了 该上分了！ 10040721',
            updatedAt: 300,
          ),
          _row(id: 2, site: 's1', vodId: 'a', title: '罪蓝之路', updatedAt: 200),
        ],
        followings: const [],
        liveSiteKeys: const {'Douyu', 'csp_Live'},
      );

      expect(feed.hero.map((item) => item.title), isNot(contains('冬天到了 该上分了！ 10040721')));
      expect(_rail(feed, HomeRailKind.resume)!.items.length, 1);
    });

    test('不传直播站点集合时行为不变（旧调用不受影响）', () {
      final feed = buildHomeFeed(
        history: [
          _row(id: 3, site: 'Douyu', vodId: 'l', title: '直播台', updatedAt: 300),
        ],
        followings: const [],
      );

      expect(feed.hero.length, 1);
    });
  });

  group('hero 高度不分档', () {
    test('没有 16:9 背景图也占满内容区，夹在 360–1000', () {
      expect(homeHeroHeight(800), 800);
      expect(homeHeroHeight(1400), 1000);
      expect(homeHeroHeight(200), 360);
    });
  });
}
