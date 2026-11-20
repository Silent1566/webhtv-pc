/// 首页数据投影的门禁（docs/phase11/design/02-home-feed-contract.md §1–§3）。
///
/// 用例名里带不变量编号（I1–I6）或文档小节号（§2.1-x / §2.2 / §2.3 / §3），
/// 这样「文档改了用例没改」在 review 时一眼可见。
///
/// 这里只测纯逻辑：不建 widget、不碰 AppState。首屏时序（§3 的追加不重排）
/// 在页面层实现，这里钉的是它依赖的那条性质——推荐后到只往 hero 尾部加。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/detail_recommendation.dart';
import 'package:webhtv_pc/core/following.dart';
import 'package:webhtv_pc/core/home_feed.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/services/storage.dart';

void main() {
  group('homeHeroHeight · 首屏两档高度', () {
    test('有背景图：占满内容区，夹在 360–1000', () {
      expect(homeHeroHeight(800, hasArt: true), 800);
      expect(homeHeroHeight(1440, hasArt: true), 1000);
      expect(homeHeroHeight(200, hasArt: true), 360);
    });

    test('没有背景图：收到 62%，夹在 360–640', () {
      expect(homeHeroHeight(800, hasArt: false), closeTo(496, 0.01));
      expect(homeHeroHeight(2000, hasArt: false), 640);
      expect(homeHeroHeight(300, hasArt: false), 360);
    });
  });

  group('元数据覆盖图', () {
    test('未启用覆盖时缺省海报保留原图（旧调用不受影响）', () {
      final item = const HomeItem(
        kind: HomeItemKind.following,
        key: 'k',
        title: 't',
        poster: 'source.jpg',
        backdrop: 'source-back.jpg',
      ).copyWith(poster: null, backdrop: null);
      expect(item.poster, 'source.jpg');
      expect(item.backdrop, 'source-back.jpg');
    });

    test('字段级来源被停用后覆盖为空，不再恢复站点海报', () {
      final item =
          const HomeItem(
            kind: HomeItemKind.following,
            key: 'k',
            title: 't',
            poster: 'source.jpg',
            backdrop: 'source-back.jpg',
          ).copyWith(
            poster: null,
            backdrop: null,
            hidePoster: true,
            hideBackdrop: true,
          );
      expect(item.poster, isNull);
      expect(item.backdrop, isNull);
    });
  });

  group('I1 容量与唯一', () {
    test('I1 · hero 最多 12 张，每条轨道最多 20 条', () {
      final feed = buildHomeFeed(
        history: [
          for (var i = 0; i < 25; i++)
            _history(id: i + 1, title: '剧$i', updatedAt: 100 - i),
        ],
        followings: [
          for (var i = 0; i < 8; i++)
            _following(
              series: 's$i',
              title: '追$i',
              released: 5,
              watched: 1,
              updatedAtMs: 100 - i,
            ),
        ],
        tmdbRecommendations: [
          for (var i = 0; i < 10; i++) _tmdb(title: 'T$i', id: 200 + i),
        ],
        doubanRecommendations: [
          for (var i = 0; i < 10; i++) _douban(title: 'D$i', id: 'db$i'),
        ],
      );

      expect(feed.hero.length, 12);
      for (final rail in feed.rails) {
        expect(rail.items.length, lessThanOrEqualTo(20), reason: rail.title);
      }
      expect(_rail(feed, HomeRailKind.resume)!.items.length, 20);
      expect(_rail(feed, HomeRailKind.following)!.items.length, 8);
      expect(_rail(feed, HomeRailKind.recommendTmdb)!.items.length, 10);
      expect(_rail(feed, HomeRailKind.recommendDouban)!.items.length, 10);
    });

    test('I1 · hero 内 key 唯一，每条轨道内 key 唯一', () {
      final feed = _mixedFeed();
      final heroKeys = feed.hero.map((item) => item.key).toList();
      expect(heroKeys.toSet().length, heroKeys.length);
      for (final rail in feed.rails) {
        final keys = rail.items.map((item) => item.key).toList();
        expect(keys.toSet().length, keys.length, reason: rail.title);
      }
    });

    test('I1 · 同一个 key 的两行（源站改过名）只出现一次', () {
      final feed = buildHomeFeed(
        history: [
          _history(id: 1, vodId: 'same', title: '庆余年', updatedAt: 9),
          _history(id: 2, vodId: 'same', title: '庆余年·第一季', updatedAt: 8),
        ],
        followings: const [],
      );

      expect(feed.hero.length, 1);
      expect(_rail(feed, HomeRailKind.resume)!.items.length, 1);
    });
  });

  test('推荐条目带上 TMDB 列表自带的简介（不额外请求）', () {
    final feed = buildHomeFeed(
      history: const [],
      followings: const [],
      tmdbRecommendations: [
        _tmdb(title: '轧戏', id: 9, overview: '  一个关于舞台与命案的故事。  '),
      ],
    );
    expect(feed.hero.single.overview, '一个关于舞台与命案的故事。');
  });

  group('I2 推荐位不能整段消失', () {
    test('I2 · 续播再多也挤不掉推荐位（3 + 6 + 3 = 12，结构上就占着）', () {
      // 用户 2026-11-19 把 hero 放大到 12 之后，三类的预算之和正好等于总数，
      // 「推荐被挤掉再拿续播换回来」那段补偿逻辑因此删掉了——这条用例钉的是
      // 新的不变量：本地条目再多，推荐仍然拿满自己的 3 个位置。
      final feed = buildHomeFeed(
        history: [
          for (var i = 0; i < 10; i++)
            _history(id: i + 1, title: '续$i', updatedAt: 100 - i),
        ],
        followings: [
          for (var i = 0; i < 5; i++)
            _following(
              series: 's$i',
              title: '追$i',
              released: 5,
              watched: 1,
              updatedAtMs: 50 - i,
            ),
        ],
        tmdbRecommendations: [
          _tmdb(title: 'T1', id: 1),
          _tmdb(title: 'T2', id: 2),
        ],
        doubanRecommendations: [
          _douban(title: 'D1', id: 'db1'),
          _douban(title: 'D2', id: 'db2'),
        ],
      );

      expect(feed.hero.length, 12);
      expect(_titlesIn(feed.hero, HomeItemKind.following).length, 3);
      expect(_titlesIn(feed.hero, HomeItemKind.resume).length, 6);
      expect(_titlesIn(feed.hero, HomeItemKind.recommend).length, 3);
    });

    test('I2 · 推荐在没被挤掉时照常出现（不触发替换）', () {
      final feed = buildHomeFeed(
        history: [_history(id: 1, title: '续0', updatedAt: 5)],
        followings: const [],
        tmdbRecommendations: [_tmdb(title: 'T1', id: 1)],
        doubanRecommendations: [_douban(title: 'D1', id: 'db1')],
      );

      expect(_titles(feed.hero), ['续0', 'T1', 'D1']);
    });

    test('I2 · 推荐标题已被追剧占用时不再强塞（I4 优先）', () {
      final feed = buildHomeFeed(
        history: const [],
        followings: [
          _following(
            series: 'x',
            title: '同名剧',
            released: 3,
            watched: 1,
            updatedAtMs: 5,
          ),
        ],
        tmdbRecommendations: [_tmdb(title: '同名剧', id: 7)],
      );

      expect(feed.hero.length, 1);
      expect(feed.hero.single.kind, HomeItemKind.following);
      expect(_rail(feed, HomeRailKind.recommendTmdb), isNull);
    });
  });

  group('I3 续播区间', () {
    test('I3 · 未开始、恰好 0.95、超过 0.95 都不进，0.94 留', () {
      final feed = buildHomeFeed(
        history: [
          _history(id: 1, title: '没开始', positionMs: 0, updatedAt: 5),
          _history(
            id: 2,
            title: '恰0.95',
            positionMs: 570000,
            durationMs: 600000,
            updatedAt: 4,
          ),
          _history(
            id: 3,
            title: '超了',
            positionMs: 900000,
            durationMs: 600000,
            updatedAt: 3,
          ),
          _history(
            id: 4,
            title: '0.94',
            positionMs: 564000,
            durationMs: 600000,
            updatedAt: 2,
          ),
        ],
        followings: const [],
      );

      expect(_titles(feed.hero), ['0.94']);
      expect(_titles(_rail(feed, HomeRailKind.resume)!.items), ['0.94']);
    });

    test('I3 · durationMs 为 0 或负数视为算不出进度，不进续播', () {
      final feed = buildHomeFeed(
        history: [
          _history(id: 1, title: '零时长', positionMs: 60000, durationMs: 0),
          _history(id: 2, title: '负时长', positionMs: 60000, durationMs: -1),
        ],
        followings: const [],
      );

      expect(feed.isEmpty, isTrue);
    });

    test('I3 · 同标题只留最新一条（hero 与轨道同一个答案）', () {
      final feed = buildHomeFeed(
        history: [
          _history(id: 1, title: '同一部', updatedAt: 10),
          _history(id: 2, title: '同一部', updatedAt: 99),
        ],
        followings: const [],
      );

      expect(feed.hero.length, 1);
      expect(feed.hero.single.history!.updatedAt, 99);
      expect(_rail(feed, HomeRailKind.resume)!.items.length, 1);
    });
  });

  group('I4 跨轨道去重', () {
    test('I4 · following 优先于 resume', () {
      final feed = buildHomeFeed(
        history: [_history(id: 1, title: '庆余年', updatedAt: 10)],
        followings: [
          _following(
            series: 'q',
            title: '庆余年',
            released: 8,
            watched: 2,
            updatedAtMs: 7,
          ),
        ],
      );

      expect(feed.hero.single.kind, HomeItemKind.following);
      expect(_titles(feed.hero), ['庆余年']);
      expect(_rail(feed, HomeRailKind.resume), isNull);
    });

    test('I4 · resume 优先于 recommend', () {
      final feed = buildHomeFeed(
        history: [_history(id: 1, title: '漫长的季节', updatedAt: 10)],
        followings: const [],
        tmdbRecommendations: [_tmdb(title: '漫长的季节', id: 42)],
      );

      expect(feed.hero.single.kind, HomeItemKind.resume);
      expect(_rail(feed, HomeRailKind.recommendTmdb), isNull);
    });

    test('I4 · TMDB 行优先于豆瓣行', () {
      final feed = buildHomeFeed(
        history: const [],
        followings: const [],
        tmdbRecommendations: [_tmdb(title: '三体', id: 11)],
        doubanRecommendations: [_douban(title: '三体', id: 'db9')],
      );

      expect(_rail(feed, HomeRailKind.recommendTmdb)!.items.length, 1);
      expect(_rail(feed, HomeRailKind.recommendDouban), isNull);
    });

    test('I4 · 同一部剧的两季追番只留一条', () {
      final feed = buildHomeFeed(
        history: const [],
        followings: [
          _following(
            series: 'same',
            season: 0,
            title: '进击的巨人',
            released: 25,
            watched: 0,
            updatedAtMs: 5,
          ),
          _following(
            series: 'same',
            season: 1,
            title: '进击的巨人',
            released: 12,
            watched: 0,
            updatedAtMs: 4,
          ),
        ],
      );

      expect(_rail(feed, HomeRailKind.following)!.items.length, 1);
      expect(feed.hero.length, 1);
    });

    test('I4 · 四条轨道两两之间都不重复', () {
      final feed = _mixedFeed();
      final seen = <String>{};
      for (final rail in feed.rails) {
        for (final item in rail.items) {
          final work = recommendationTitleKey(item.title);
          expect(
            seen.add(work),
            isTrue,
            reason: [rail.title, item.title].join(' / '),
          );
        }
      }
    });
  });

  group('I5 空态判据', () {
    test('I5 · 全空输入 → isEmpty', () {
      final feed = buildHomeFeed(history: const [], followings: const []);

      expect(feed.hero, isEmpty);
      expect(feed.rails, isEmpty);
      expect(feed.isEmpty, isTrue);
    });

    test('I5 · 只有历史 → hero 与一条继续观看轨道', () {
      final feed = buildHomeFeed(
        history: [_history(id: 1, title: '剧', updatedAt: 3)],
        followings: const [],
      );

      expect(feed.isEmpty, isFalse);
      expect(feed.rails.length, 1);
      expect(feed.rails.single.kind, HomeRailKind.resume);
      expect(feed.rails.single.seeAll, HomeSeeAll.history);
    });

    test('I5 · 只有推荐 → hero 与推荐轨道都在，且没有 seeAll', () {
      final feed = buildHomeFeed(
        history: const [],
        followings: const [],
        tmdbRecommendations: [_tmdb(title: 'X', id: 3)],
      );

      expect(feed.isEmpty, isFalse);
      expect(feed.hero.length, 1);
      expect(feed.rails.single.kind, HomeRailKind.recommendTmdb);
      expect(feed.rails.single.seeAll, isNull);
    });

    test('I5 · 历史全是看完的 → isEmpty（页面据此画空态）', () {
      final feed = buildHomeFeed(
        history: [
          _history(id: 1, title: '看完了', positionMs: 600000, durationMs: 600000),
        ],
        followings: const [],
      );

      expect(feed.isEmpty, isTrue);
    });
  });

  group('I6 空字段不抛异常', () {
    test('I6 · vodPic 为空、episodeName 为空仍产出可渲染条目', () {
      final feed = buildHomeFeed(
        history: [
          _history(
            id: 1,
            title: '无图',
            poster: null,
            episode: '',
            positionMs: 120000,
            durationMs: 600000,
            updatedAt: 2,
          ),
        ],
        followings: const [],
      );

      final item = feed.hero.single;
      expect(item.title, '无图');
      expect(item.poster, isNull);
      expect(item.episodeLabel, '');
      expect(item.reason, '继续观看 · 剩 8 分钟');
      expect(item.progress, closeTo(0.2, 1e-9));
    });

    test('I6 · 空白图片地址按没有图处理（让页面兜底链生效）', () {
      final feed = buildHomeFeed(
        history: const [],
        followings: [
          _following(
            series: 'blank',
            title: '空图',
            poster: '   ',
            released: 2,
            watched: 0,
          ),
        ],
      );

      expect(feed.hero.single.poster, isNull);
    });

    test('I6 · 空标题的历史不会吞掉别的条目', () {
      final feed = buildHomeFeed(
        history: [
          _history(id: 1, title: '', updatedAt: 5),
          _history(id: 2, title: '有名字', updatedAt: 4),
        ],
        followings: const [],
      );

      expect(feed.rails.single.items.length, 2);
    });

    test('I6 · 极端字段（空标题、0/1 毫秒、空追番、空推荐标题）不抛', () {
      expect(
        () => buildHomeFeed(
          history: [
            _history(
              id: 1,
              title: '',
              poster: '',
              episode: '',
              positionMs: 1,
              durationMs: 1,
              updatedAt: 0,
            ),
            _history(
              id: 2,
              title: '脏数据',
              positionMs: 9223372036854775000,
              durationMs: 9223372036854775807,
              updatedAt: 0,
            ),
          ],
          followings: [
            _following(series: '', title: '', released: 0, watched: 0),
          ],
          tmdbRecommendations: [_tmdb(title: '', id: 1)],
        ),
        returnsNormally,
      );
    });
  });

  group('§2.1 hero 取哪几张', () {
    test('§2.1-1 · 追剧位最多 3 张、按更新时刻降序、只收有更新的', () {
      final feed = buildHomeFeed(
        history: const [],
        followings: [
          _following(
            series: 'a',
            title: '追A',
            released: 5,
            watched: 1,
            updatedAtMs: 100,
          ),
          _following(
            series: 'b',
            title: '追B',
            released: 6,
            watched: 1,
            updatedAtMs: 300,
          ),
          _following(
            series: 'c',
            title: '追C',
            released: 7,
            watched: 1,
            updatedAtMs: 200,
          ),
          _following(
            series: 'd',
            title: '追D',
            released: 7,
            watched: 7,
            updatedAtMs: 900,
          ),
        ],
      );

      expect(_titles(feed.hero), ['追B', '追C', '追A']);
      // 没有新集的那条仍然在轨道里，只是不占 hero。
      expect(
        _titles(_rail(feed, HomeRailKind.following)!.items),
        contains('追D'),
      );
    });

    test('§2.1-2 · 续播位最多 6 张、按最近播放降序、同标题只留最新', () {
      final feed = buildHomeFeed(
        history: [
          _history(id: 1, title: '同名', updatedAt: 90),
          _history(id: 2, title: '同名', updatedAt: 95),
          _history(id: 3, title: '甲', updatedAt: 80),
          _history(id: 4, title: '乙', updatedAt: 70),
          _history(id: 5, title: '丙', updatedAt: 60),
          _history(id: 6, title: '丁', updatedAt: 50),
        ],
        followings: const [],
      );

      // 6 行里「同名」合并成 1 条 → 5 条，都没超过 6 的上限。
      expect(_titles(feed.hero), ['同名', '甲', '乙', '丙', '丁']);
      expect(feed.hero.first.history!.id, 2);
    });

    test('§2.1-3 · 推荐位 TMDB 与豆瓣交替、最多 3 张', () {
      final feed = buildHomeFeed(
        history: const [],
        followings: const [],
        tmdbRecommendations: [
          _tmdb(title: 'T1', id: 1),
          _tmdb(title: 'T2', id: 2),
        ],
        doubanRecommendations: [
          _douban(title: 'D1', id: 'db1'),
          _douban(title: 'D2', id: 'db2'),
        ],
      );

      expect(_titles(feed.hero), ['T1', 'D1', 'T2']);
    });

    test('§2.1-3 · 只有一行推荐时按那一行的顺序取 3 张', () {
      final feed = buildHomeFeed(
        history: const [],
        followings: const [],
        tmdbRecommendations: [
          _tmdb(title: 'T1', id: 1),
          _tmdb(title: 'T2', id: 2),
          _tmdb(title: 'T3', id: 3),
        ],
      );

      expect(_titles(feed.hero), ['T1', 'T2', 'T3']);
      expect(_titles(_rail(feed, HomeRailKind.recommendTmdb)!.items), [
        'T1',
        'T2',
        'T3',
      ]);
    });

    test('§2.1-5 · 不足 3 张就按真实数量，不凑数不循环', () {
      final one = buildHomeFeed(
        history: [_history(id: 1, title: '唯一', updatedAt: 1)],
        followings: const [],
      );
      final two = buildHomeFeed(
        history: [
          _history(id: 1, title: 'A', updatedAt: 2),
          _history(id: 2, title: 'B', updatedAt: 1),
        ],
        followings: const [],
      );

      expect(one.hero.length, 1);
      expect(two.hero.length, 2);
    });
  });

  group('§2.2 轨道排序', () {
    test('§2.2 · 追剧轨道：有更新在前，再按 nextAirAtMs 升序（0 最后），再按 createdAtMs 降序', () {
      final feed = buildHomeFeed(
        history: const [],
        followings: [
          _following(
            series: 'a',
            title: 'A',
            released: 5,
            watched: 1,
            nextAirAtMs: 0,
            createdAtMs: 10,
          ),
          _following(
            series: 'b',
            title: 'B',
            released: 5,
            watched: 1,
            nextAirAtMs: 500,
            createdAtMs: 20,
          ),
          _following(
            series: 'c',
            title: 'C',
            released: 5,
            watched: 1,
            nextAirAtMs: 100,
            createdAtMs: 30,
          ),
          _following(
            series: 'd',
            title: 'D',
            released: 3,
            watched: 3,
            nextAirAtMs: 50,
            createdAtMs: 99,
          ),
        ],
      );

      expect(_titles(_rail(feed, HomeRailKind.following)!.items), [
        'C',
        'B',
        'A',
        'D',
      ]);
    });

    test('§2.2 · 继续观看轨道与 hero 同口径，容量 20', () {
      final feed = buildHomeFeed(
        history: [
          for (var i = 0; i < 24; i++)
            _history(id: i + 1, title: '剧$i', updatedAt: 100 - i),
        ],
        followings: const [],
      );

      final rail = _rail(feed, HomeRailKind.resume)!;
      expect(rail.items.length, 20);
      expect(_titles(rail.items.take(3).toList()), ['剧0', '剧1', '剧2']);
      expect(_titles(feed.hero), ['剧0', '剧1', '剧2', '剧3', '剧4', '剧5']);
    });

    test('§2.2 · 推荐轨道保持服务返回顺序，不按评分重排', () {
      final feed = buildHomeFeed(
        history: const [],
        followings: const [],
        tmdbRecommendations: [
          _tmdb(title: '低分', id: 1, subtitle: '2024 · 4.0'),
          _tmdb(title: '高分', id: 2, subtitle: '2024 · 9.1'),
        ],
      );

      expect(_titles(_rail(feed, HomeRailKind.recommendTmdb)!.items), [
        '低分',
        '高分',
      ]);
    });

    test('§2.2 · 空轨道不出现在 rails 里', () {
      final feed = buildHomeFeed(
        history: [_history(id: 1, title: '只有续播')],
        followings: const [],
      );

      expect(feed.rails.map((rail) => rail.kind).toList(), [
        HomeRailKind.resume,
      ]);
    });
  });

  group('§2.3 理由行', () {
    test('§2.3 · 续播：继续观看 · 集名 · 剩 M 分钟', () {
      final feed = buildHomeFeed(
        history: [
          _history(
            id: 1,
            title: '剧',
            episode: '第08集',
            positionMs: 300000,
            durationMs: 600000,
          ),
        ],
        followings: const [],
      );

      expect(feed.hero.single.reason, '继续观看 · 第08集 · 剩 5 分钟');
    });

    test('§2.3 · 集名为空 → 继续观看 · 剩 M 分钟', () {
      final feed = buildHomeFeed(
        history: [
          _history(
            id: 1,
            title: '剧',
            episode: '',
            positionMs: 300000,
            durationMs: 600000,
          ),
        ],
        followings: const [],
      );

      expect(feed.hero.single.reason, '继续观看 · 剩 5 分钟');
    });

    test('§2.3 · M 先 ceil：0.9499 的进度算「剩 1 分钟」而不是 0', () {
      final feed = buildHomeFeed(
        history: [
          _history(
            id: 1,
            title: '剧',
            episode: '第08集',
            positionMs: 569940,
            durationMs: 600000,
          ),
        ],
        followings: const [],
      );

      expect(feed.hero.single.reason, '继续观看 · 第08集 · 剩 1 分钟');
    });

    test('§2.3 · M > 999 时不写分钟（异常时长不写成剩 60000 分钟）', () {
      final feed = buildHomeFeed(
        history: [
          _history(
            id: 1,
            title: '脏时长',
            episode: '第08集',
            positionMs: 1000,
            durationMs: 3600000000,
          ),
        ],
        followings: const [],
      );

      expect(feed.hero.single.reason, '继续观看 · 第08集');
    });

    test('§2.3 · durationMs == 0 的行先被 I3 挡下，「继续观看」降级分支不可达', () {
      final feed = buildHomeFeed(
        history: [
          _history(
            id: 1,
            title: '零时长',
            episode: '第08集',
            positionMs: 60000,
            durationMs: 0,
          ),
        ],
        followings: const [],
      );

      // 契约里「durationMs == 0 → 就写继续观看」这条降级保留在 _resumeReason 里
      // 作防御，但 buildHomeFeed 永远看不到这种行；这里钉住的是这层先后关系。
      expect(feed.isEmpty, isTrue);
    });

    test('§2.3 · 推荐理由：entry.reason 非空直接用', () {
      final feed = buildHomeFeed(
        history: const [],
        followings: const [],
        tmdbRecommendations: [
          _tmdb(
            title: '推荐',
            id: 1,
            reason: '因为你看过《漫长的季节》',
            subtitle: '2024 · 8.1',
          ),
        ],
      );

      expect(feed.hero.single.reason, '因为你看过《漫长的季节》');
      expect(feed.hero.single.subtitle, '2024 · 8.1');
    });

    test('§2.3 · 推荐理由为空 → 年份 · 评分（豆瓣评分走结构化字段）', () {
      final feed = buildHomeFeed(
        history: const [],
        followings: const [],
        doubanRecommendations: [
          _douban(title: '豆瓣剧', id: 'db1', subtitle: '2024 · 剧集', rating: 8.4),
        ],
      );

      expect(feed.hero.single.subtitle, '2024 · 8.4');
      expect(feed.hero.single.reason, '2024 · 8.4');
    });

    test('§2.3 · 年份与评分都没有 → 理由行为空串（不显示理由行）', () {
      final feed = buildHomeFeed(
        history: const [],
        followings: const [],
        tmdbRecommendations: [_tmdb(title: '裸条目', id: 1)],
      );

      expect(feed.hero.single.subtitle, '');
      expect(feed.hero.single.reason, '');
    });

    test('§2.3 · 追剧：更新至 集名；无集名退回「第N集」；两者皆无则留空', () {
      final named = buildHomeFeed(
        history: const [],
        followings: [
          _following(
            series: 'a',
            title: 'A',
            released: 12,
            watched: 3,
            latestName: '第12集',
          ),
        ],
      );
      final unnamed = buildHomeFeed(
        history: const [],
        followings: [
          _following(series: 'b', title: 'B', released: 7, watched: 1),
        ],
      );
      final blank = buildHomeFeed(
        history: const [],
        followings: [
          _following(series: 'c', title: 'C', released: 0, watched: 0),
        ],
      );

      expect(named.hero.single.reason, '更新至 第12集');
      // 没有 air data 时不写「· 平台 播出时间」这半句。
      expect(named.hero.single.reason.contains('·'), isFalse);
      expect(unnamed.hero.single.reason, '更新至 第7集');
      expect(blank.hero, isEmpty);
      expect(blank.rails.single.items.single.reason, '');
    });
  });

  group('§3 推荐晚到', () {
    test('§3 · 推荐只在 hero 尾部追加，本地已有的前三张 key 不动', () {
      final local = [
        for (var i = 0; i < 3; i++)
          _history(id: i + 1, title: '续$i', updatedAt: 10 - i),
      ];

      final before = buildHomeFeed(history: local, followings: const []);
      final after = buildHomeFeed(
        history: local,
        followings: const [],
        tmdbRecommendations: [_tmdb(title: 'T1', id: 1)],
        doubanRecommendations: [_douban(title: 'D1', id: 'db1')],
      );

      expect(_titles(after.hero), ['续0', '续1', '续2', 'T1', 'D1']);
      expect(
        after.hero.take(before.hero.length).map((item) => item.key).toList(),
        before.hero.map((item) => item.key).toList(),
      );
    });
  });
}

/// 四类输入都有、标题还互相重叠的一份样本：用来查 I1/I4 的一致性。
HomeFeed _mixedFeed() => buildHomeFeed(
  history: [
    _history(id: 1, title: '共有的作品', updatedAt: 50),
    _history(id: 2, title: '只要续播', updatedAt: 40),
  ],
  followings: [
    _following(
      series: 'm',
      title: '共有的作品',
      released: 9,
      watched: 1,
      updatedAtMs: 60,
    ),
    _following(
      series: 'n',
      title: '另一部追剧',
      released: 4,
      watched: 0,
      updatedAtMs: 55,
    ),
  ],
  tmdbRecommendations: [
    _tmdb(title: '共有的作品', id: 91),
    _tmdb(title: '推荐X', id: 92),
  ],
  doubanRecommendations: [
    _douban(title: '推荐X', id: 'dbx'),
    _douban(title: '推荐Y', id: 'dby'),
  ],
);

PlaybackHistory _history({
  int id = 1,
  String? vodId,
  String title = '剧集',
  String? poster = 'poster.jpg',
  String episode = '第01集',
  int positionMs = 60000,
  int durationMs = 600000,
  int updatedAt = 1,
  String year = '',
  String sourceKey = 'local',
}) => PlaybackHistory(
  id: id,
  siteKey: 'site',
  vodId: vodId ?? 'vod$id',
  vodName: title,
  vodPic: poster,
  flag: '',
  episodeName: episode,
  episodeId: 'ep$id',
  positionMs: positionMs,
  durationMs: durationMs,
  updatedAt: updatedAt,
  sourceKey: sourceKey,
  vodYear: year,
);

Following _following({
  String series = 'series',
  String title = '追剧',
  int season = 0,
  String? poster = 'f.jpg',
  int released = 0,
  int watched = 0,
  int nextAirAtMs = 0,
  int createdAtMs = 0,
  int updatedAtMs = 0,
  String latestName = '',
}) => Following(
  seriesKey: series,
  season: season,
  siteKey: 'site',
  vodId: series,
  vodName: title,
  vodPic: poster,
  latestReleasedEpisode: released,
  watchedEpisode: watched,
  nextAirAtMs: nextAirAtMs,
  createdAtMs: createdAtMs,
  updatedAtMs: updatedAtMs,
  latestEpisodeName: latestName,
);

RecommendationEntry _tmdb({
  required String title,
  required int id,
  String reason = '',
  String subtitle = '',
  String? poster = 't.jpg',
  String? backdrop,
  String? overview,
}) => RecommendationEntry(
  item: TmdbItem(
    tmdbId: id,
    mediaType: TmdbMediaType.tv,
    title: title,
    subtitle: subtitle,
    overview: overview,
    posterUrl: poster,
    backdropUrl: backdrop,
  ),
  source: RecommendationSource.tmdb,
  reason: reason,
);

RecommendationEntry _douban({
  required String title,
  required String id,
  String reason = '',
  String subtitle = '',
  double rating = 0,
  String? poster = 'd.jpg',
}) => RecommendationEntry(
  item: TmdbItem(
    tmdbId: 0,
    mediaType: TmdbMediaType.tv,
    title: title,
    subtitle: subtitle,
    posterUrl: poster,
  ),
  source: RecommendationSource.douban,
  reason: reason,
  doubanId: id,
  doubanRating: rating,
);

List<String> _titles(List<HomeItem> items) => [
  for (final item in items) item.title,
];

List<String> _titlesIn(List<HomeItem> items, HomeItemKind kind) => [
  for (final item in items)
    if (item.kind == kind) item.title,
];

HomeRail? _rail(HomeFeed feed, HomeRailKind kind) {
  for (final rail in feed.rails) {
    if (rail.kind == kind) return rail;
  }
  return null;
}
