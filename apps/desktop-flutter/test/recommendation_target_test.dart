/// 推荐点击去向的纯逻辑门禁（Task4：当前站点命中 → 站源详情；未命中 → 导航源回退）。
///
/// 这一层只做三件事，全部可以脱离 Flutter 与网络验证：
/// - 站源搜索关键字（标题归一）；
/// - 搜索结果里挑出「过了用户相似度阈值且得分最高」的一条，并列取结果顺序在前者；
/// - 把「有没有 TMDB 身份 / 搜到没有 / 搜索失败」收敛成一个明确的跳转目标。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/recommendation_target.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';

const _movie = TmdbItem(
  tmdbId: 2,
  mediaType: TmdbMediaType.movie,
  title: '推荐作品',
  posterUrl: 'https://img.example/poster.jpg',
  overview: '剧情简介',
);

/// 豆瓣条目在补 TMDB 元数据失败时就是这种形状：没有可用身份（`tmdbId == 0`）。
const _unboundDouban = TmdbItem(
  tmdbId: 0,
  mediaType: TmdbMediaType.movie,
  title: '豆瓣作品',
);

Vod _vod(String id, String name) => Vod(vodId: id, vodName: name);

Site _site() => Site(
  key: 'current',
  name: '当前站',
  type: 1,
  api: 'https://fixture.invalid/api.php/provide/vod',
);

void main() {
  group('推荐卡片站源搜索关键字', () {
    test('电影标题只去首尾空白，不改写内容', () {
      expect(recommendationSearchKeyword(_movie), '推荐作品');
      expect(
        recommendationSearchKeyword(
          const TmdbItem(
            tmdbId: 2,
            mediaType: TmdbMediaType.movie,
            title: '  推荐 作品  ',
          ),
        ),
        '推荐 作品',
        reason: '只做 trim：站源标题写法不统一，额外改写会降低命中率',
      );
    });

    test('剧集标题同一条规则（媒体类型不参与关键字构造）', () {
      expect(
        recommendationSearchKeyword(
          const TmdbItem(
            tmdbId: 1399,
            mediaType: TmdbMediaType.tv,
            title: ' 导航剧 ',
          ),
        ),
        '导航剧',
      );
    });
  });

  group('站源搜索结果匹配', () {
    test('阈值 100 只接受完全一致，包含关系不算命中', () {
      final results = [_vod('a', '推荐作品 2024'), _vod('b', '推荐作品')];
      expect(
        recommendationSiteMatch(
          results,
          keyword: '推荐作品',
          similarityPercent: 100,
        )?.vodId,
        'b',
      );
    });

    test('阈值 30 接受「候选包含查询」，得分高者胜出', () {
      final results = [_vod('a', '推荐作品 第二季'), _vod('b', '推荐作品')];
      expect(
        recommendationSiteMatch(
          results,
          keyword: '推荐作品',
          similarityPercent: 30,
        )?.vodId,
        'b',
        reason: '100 分（完全一致）必须压过包含关系的覆盖率分',
      );
    });

    test('低于阈值的条目不命中（不是「取最像的那条」）', () {
      final results = [_vod('a', '完全无关的剧'), _vod('b', '推荐作品 2024')];
      expect(
        recommendationSiteMatch(
          results,
          keyword: '推荐作品',
          similarityPercent: 60,
        ),
        isNull,
      );
    });

    test('空结果永远不是命中', () {
      expect(
        recommendationSiteMatch(
          const [],
          keyword: '推荐作品',
          similarityPercent: 0,
        ),
        isNull,
      );
    });

    test('并列同分取结果顺序更靠前的一条（确定性平局规则）', () {
      final results = [_vod('first', '推荐作品'), _vod('second', '推荐作品')];
      expect(
        recommendationSiteMatch(
          results,
          keyword: '推荐作品',
          similarityPercent: 100,
        )?.vodId,
        'first',
      );
    });

    test('阈值 0 不过滤，但仍按得分取最优而不是取第一条', () {
      final results = [_vod('a', '别的剧'), _vod('b', '推荐作品')];
      expect(
        recommendationSiteMatch(
          results,
          keyword: '推荐作品',
          similarityPercent: 0,
        )?.vodId,
        'b',
      );
    });

    test('全角/空格差异由既有归一化吸收（不另造一套比较）', () {
      final results = [_vod('a', '推荐　作品')];
      expect(
        recommendationSiteMatch(
          results,
          keyword: '推荐 作品',
          similarityPercent: 100,
        )?.vodId,
        'a',
      );
    });
  });

  group('回退用的合成条目', () {
    test('没有 vodId、没有线路，只带 TMDB 展示字段', () {
      final vod = recommendationFallbackVod(_movie);
      expect(vod.vodId, isEmpty, reason: '空 vodId 才能让详情页跳过站源详情请求');
      expect(vod.vodName, '推荐作品');
      expect(vod.vodPic, 'https://img.example/poster.jpg');
      expect(vod.vodContent, '剧情简介');
      expect(vod.vodPlayFrom, isNull);
      expect(vod.vodPlayUrl, isNull);
      expect(vod.isFolder, isFalse);
    });
  });

  group('点击去向（同步判定）', () {
    test('没有 TMDB 身份的豆瓣条目 → 既有按标题搜索', () {
      final target = recommendationTargetFor(
        item: _unboundDouban,
        similarityPercent: 30,
      );
      expect(target, isA<RecommendationTitleSearchTarget>());
      expect((target as RecommendationTitleSearchTarget).title, '豆瓣作品');
    });

    test('命中 → 打开该站点的那条真实条目', () {
      final target = recommendationTargetFor(
        item: _movie,
        results: [_vod('match-1', '推荐作品')],
        similarityPercent: 30,
      );
      expect(target, isA<RecommendationSiteTarget>());
      expect((target as RecommendationSiteTarget).vod.vodId, 'match-1');
    });

    test('未命中 → 导航源形态的合成条目', () {
      final target = recommendationTargetFor(
        item: _movie,
        results: [_vod('a', '完全无关的剧')],
        similarityPercent: 60,
      );
      expect(target, isA<RecommendationNavSourceTarget>());
      final vod = (target as RecommendationNavSourceTarget).vod;
      expect(vod.vodId, isEmpty);
      expect(vod.vodName, '推荐作品');
    });

    test('标题为空时不搜索、直接回退（不拿空关键字命中任何条目）', () {
      final target = recommendationTargetFor(
        item: const TmdbItem(
          tmdbId: 2,
          mediaType: TmdbMediaType.movie,
          title: '   ',
        ),
        results: [_vod('a', '推荐作品')],
        similarityPercent: 0,
      );
      expect(target, isA<RecommendationNavSourceTarget>());
    });
  });

  group('点击去向（含搜索）', () {
    test('搜索命中 → 站源条目', () async {
      final calls = <String>[];
      final target = await resolveRecommendationTarget(
        item: _movie,
        site: _site(),
        similarityPercent: 30,
        search: (site, keyword) async {
          calls.add('${site.key}|$keyword');
          return [_vod('match-1', '推荐作品')];
        },
      );
      expect(calls, ['current|推荐作品']);
      expect((target as RecommendationSiteTarget).vod.vodId, 'match-1');
    });

    test('搜索抛错 → 导航源回退，异常不外泄', () async {
      final target = await resolveRecommendationTarget(
        item: _movie,
        site: _site(),
        similarityPercent: 30,
        search: (site, keyword) async => throw StateError('站点 500'),
      );
      expect(target, isA<RecommendationNavSourceTarget>());
    });

    test('搜索返回 null（站点不可用）→ 导航源回退', () async {
      final target = await resolveRecommendationTarget(
        item: _movie,
        site: _site(),
        similarityPercent: 30,
        search: (site, keyword) async => null,
      );
      expect(target, isA<RecommendationNavSourceTarget>());
    });

    test('没有可用站点 → 既有按标题搜索（回退页没有站点也加载不了 TMDB）', () async {
      final calls = <String>[];
      final target = await resolveRecommendationTarget(
        item: _movie,
        site: null,
        similarityPercent: 30,
        search: (site, keyword) async {
          calls.add(keyword);
          return const [];
        },
      );
      expect(calls, isEmpty);
      expect(target, isA<RecommendationTitleSearchTarget>());
    });

    test('没有 TMDB 身份时不发站源搜索', () async {
      final calls = <String>[];
      final target = await resolveRecommendationTarget(
        item: _unboundDouban,
        site: _site(),
        similarityPercent: 30,
        search: (site, keyword) async {
          calls.add(keyword);
          return [_vod('a', '豆瓣作品')];
        },
      );
      expect(calls, isEmpty);
      expect(target, isA<RecommendationTitleSearchTarget>());
    });
  });
}
