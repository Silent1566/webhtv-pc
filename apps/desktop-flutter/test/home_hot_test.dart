/// 首页「热门」轨道的门禁（lib/core/home_hot.dart）。
///
/// 与 home_feed_test.dart 同一种写法：只测纯逻辑，不建 widget、不碰 AppState、
/// 不发网络——榜单数据在页面层取好后作为参数传进来。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/home_feed.dart';
import 'package:webhtv_pc/core/home_hot.dart';
import 'package:webhtv_pc/services/search_suggest_service.dart';

void main() {
  group('hotRails · 三个类目', () {
    test('顺序固定为 剧集 → 电影 → 综艺，标题与 kind 对应', () {
      final rails = hotRails({
        HotRankCategory.variety: [_item(title: '综', rank: 1)],
        HotRankCategory.movie: [_item(title: '影', rank: 1)],
        HotRankCategory.series: [_item(title: '剧', rank: 1)],
      });

      expect(rails.map((rail) => rail.kind).toList(), [
        HomeRailKind.hotTv,
        HomeRailKind.hotMovie,
        HomeRailKind.hotVariety,
      ]);
      expect(rails.map((rail) => rail.title).toList(), [
        '热门剧集',
        '热门电影',
        '热门综艺',
      ]);
      // 每个类目只装自己的条目，不串行。
      expect(rails.map((rail) => rail.items.single.title).toList(), [
        '剧',
        '影',
        '综',
      ]);
    });

    test('seeAll 恒为 null：热门没有独立页', () {
      final rails = hotRails({
        HotRankCategory.movie: [_item(title: '影', rank: 1)],
      });
      expect(rails.single.seeAll, isNull);
    });
  });

  group('hotRails · 空输入', () {
    test('全空返回空列表，且就是那个 const 实例', () {
      final rails = hotRails(const {});
      expect(rails, isEmpty);
      expect(identical(rails, const <HomeRail>[]), isTrue);
    });

    test('空类目不出轨道（含显式传空列表的类目）', () {
      final rails = hotRails({
        HotRankCategory.movie: const [],
        HotRankCategory.series: [_item(title: '剧', rank: 2)],
      });
      expect(rails.map((rail) => rail.kind).toList(), [HomeRailKind.hotTv]);
      expect(rails.single.items.single.title, '剧');
    });

    test('所有类目都是空列表时也不出轨道', () {
      final rails = hotRails({
        HotRankCategory.movie: const [],
        HotRankCategory.series: const [],
        HotRankCategory.variety: const [],
      });
      expect(rails, isEmpty);
    });
  });

  group('hotItem · 字段口径', () {
    test('kind 为 hot，history / following / entry 全 null', () {
      final item = hotItem(_item(title: '漫长的季节', rank: 3),
          categoryKey: 'series');
      expect(item.kind, HomeItemKind.hot);
      expect(item.history, isNull);
      expect(item.following, isNull);
      expect(item.entry, isNull);
      expect(item.progress, 0);
      expect(item.episodeLabel, '');
    });

    test('key 为 hot:<类目>:<名次>，标题去空白进 title', () {
      final item = hotItem(_item(title: '  流浪地球  ', rank: 1),
          categoryKey: 'movie');
      expect(item.key, 'hot:movie:1');
      expect(item.title, '流浪地球');
    });

    test('cover 空白 → poster 为 null；有地址 → 去空白后保留', () {
      expect(
        hotItem(_item(title: 'A', cover: '   ', rank: 1), categoryKey: 'movie')
            .poster,
        isNull,
      );
      expect(
        hotItem(_item(title: 'A', cover: null, rank: 1), categoryKey: 'movie')
            .poster,
        isNull,
      );
      expect(
        hotItem(_item(title: 'A', cover: ' https://img/a.jpg ', rank: 1),
                categoryKey: 'movie')
            .poster,
        'https://img/a.jpg',
      );
    });

    test('score 非空 → 豆瓣 <score>；空 → 空串', () {
      expect(
        hotItem(_item(title: 'A', score: '8.7', rank: 1),
                categoryKey: 'movie')
            .subtitle,
        '豆瓣 8.7',
      );
      expect(
        hotItem(_item(title: 'A', score: '  ', rank: 1), categoryKey: 'movie')
            .subtitle,
        '',
      );
      expect(
        hotItem(_item(title: 'A', rank: 1), categoryKey: 'movie').subtitle,
        '',
      );
    });

    test('upinfo 非空 → reason 原样（去空白）；空 → 热门', () {
      expect(
        hotItem(_item(title: 'A', upinfo: ' 全47集 ', rank: 1),
                categoryKey: 'series')
            .reason,
        '全47集',
      );
      expect(
        hotItem(_item(title: 'A', upinfo: '2026-10-13期', rank: 2),
                categoryKey: 'variety')
            .reason,
        '2026-10-13期',
      );
      expect(
        hotItem(_item(title: 'A', rank: 1), categoryKey: 'movie').reason,
        '热门',
      );
      expect(
        hotItem(_item(title: 'A', upinfo: '   ', rank: 1), categoryKey: 'movie')
            .reason,
        '热门',
      );
    });
  });

  group('hotItem · 缺名次的 key', () {
    test('rank 缺失或 <= 0 时退回标题，同一批里仍互不相同', () {
      final keys = [
        hotItem(_item(title: '影一'), categoryKey: 'movie').key,
        hotItem(_item(title: '影二', rank: 0), categoryKey: 'movie').key,
        hotItem(_item(title: '影三', rank: null), categoryKey: 'movie').key,
      ];
      expect(keys.toSet().length, 3);
      expect(keys.first, 'hot:movie:影一');
    });

    test('同名作品在三个类目里得到三个 key', () {
      final keys = [
        for (final key in ['movie', 'series', 'variety'])
          hotItem(_item(title: '同名', rank: 1), categoryKey: key).key,
      ];
      expect(keys.toSet().length, 3);
    });
  });

  group('hotRails · 容量与原序', () {
    test('每条轨道最多 30 条（hotPoolLimit 口径）', () {
      final rails = hotRails({
        HotRankCategory.movie: [
          for (var i = 1; i <= 40; i++) _item(title: '影$i', rank: i),
        ],
        HotRankCategory.series: [
          for (var i = 1; i <= 30; i++) _item(title: '剧$i', rank: i),
        ],
      });
      expect(rails[0].items.length, 30);
      expect(rails[1].items.length, 30);
      // 截断取前 30，不是任意 30 条；名次 40 的那条不该冒进来。
      expect(rails[1].items.first.title, '影1');
      expect(rails[1].items.last.title, '影30');
      expect(rails[1].items.last.key, 'hot:movie:30');
    });

    test('保持榜单原序，不按评分或标题重排', () {
      final rails = hotRails({
        HotRankCategory.movie: [
          _item(title: '低分', score: '3.1', rank: 1),
          _item(title: '高分', score: '9.9', rank: 2),
          _item(title: '阿乙', score: '6.0', rank: 3),
        ],
      });
      expect(rails.single.items.map((item) => item.title).toList(), [
        '低分',
        '高分',
        '阿乙',
      ]);
    });

    test('同一 key 重复出现时只留前一条（不重排、不画两张同 key 卡）', () {
      final rails = hotRails({
        HotRankCategory.movie: [
          _item(title: '影一', rank: 1),
          _item(title: '同一部作品', rank: 2),
          _item(title: '同一部作品', rank: 2),
        ],
      });
      expect(rails.single.items.length, 2);
      expect(rails.single.items.map((item) => item.title).toList(), [
        '影一',
        '同一部作品',
      ]);
    });
  });
}

SearchSuggestItem _item({
  String title = '',
  String? cover,
  String? upinfo,
  String? score,
  int? rank,
}) => SearchSuggestItem(
  title: title,
  cover: cover,
  subtitle: upinfo,
  score: score,
  detailUrl: 'https://www.360kan.com/detail/$title',
  rank: rank,
);
