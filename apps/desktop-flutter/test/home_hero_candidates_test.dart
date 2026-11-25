import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/home_feed.dart';

HomeItem item(String key, {HomeItemKind kind = HomeItemKind.resume}) =>
    HomeItem(kind: kind, key: key, title: key);

void main() {
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
