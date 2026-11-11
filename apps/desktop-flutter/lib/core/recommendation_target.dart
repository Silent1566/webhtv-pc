/// 推荐卡片的点击去向（纯逻辑，不依赖 Flutter、网络与状态层）。
///
/// 规则（用户决策 2026-11，见 task-4 brief）：
/// - **当前站点按标题命中**这部作品 → 打开该站点的真实详情页，选中那条 `Vod`
///   可以直接播放；
/// - **当前站点搜不到 / 搜索失败** → 打开同一作品的「导航源形态」详情页：剧集卡片
///   由 TMDB 提供，播放只能经既有「换源」流程取得，绝不伪造可播放身份；
/// - **没有 TMDB 身份的豆瓣条目** → 仍走既有按标题搜索（与改造前逐字一致）。
///
/// 为什么单独成文件：两个详情页（站源详情页与纯 TMDB 详情页）共用同一条规则。
/// 把判定做成纯函数，页面只负责「发一次搜索 + 按结果跳转」，两边不可能各写一套。
library;

import 'protocol.dart';
import 'search_result_filter.dart';
import 'tmdb_identity.dart';

/// 推荐卡片在站源侧的搜索关键词（标题去首尾空白）。
///
/// 只做 trim，不拼年份/评分：站源标题里的年份写法不统一（`2024` / `(2024)` /
/// `【2024】`），拼进去只会降低命中率；空格/全角/大小写差异由既有的
/// [searchResultMatches] 归一化吸收，这里不另造一套。
String recommendationSearchKeyword(TmdbItem item) => item.title.trim();

/// 站源搜索结果中与 [keyword] 最匹配的一条；没有达到阈值的条目返回 `null`。
///
/// 打分与阈值判定完全复用 [searchScore] / [searchResultMatches]——与搜索页、
/// 换源浮层同一套口径（阈值来自 [AppState.searchSimilarity]）。并列同分取**结果
/// 顺序更靠前**的一条：站源自己的相关度排序就是既有的平局规则，不另造一套。
///
/// 阈值 0 表示「不过滤」（上游语义），此时仍按得分取最优，而不是无脑取第一条。
Vod? recommendationSiteMatch(
  List<Vod> results, {
  required String keyword,
  required int similarityPercent,
}) {
  Vod? best;
  var bestScore = -1;
  for (final vod in results) {
    if (!searchResultMatches(keyword, vod.vodName, similarityPercent)) continue;
    final score = searchScore(keyword, vod.vodName);
    if (score > bestScore) {
      best = vod;
      bestScore = score;
    }
  }
  return best;
}

/// 推荐点击的去向。三种结局互斥，页面对每种只做一件固定的事。
sealed class RecommendationTarget {
  const RecommendationTarget();
}

/// 当前站点命中了：打开这个站点的真实详情页（可直接播放）。
final class RecommendationSiteTarget extends RecommendationTarget {
  const RecommendationSiteTarget(this.vod);

  final Vod vod;
}

/// 当前站点没命中：打开同一作品的导航源形态详情页（TMDB 剧集卡片 + 换源）。
final class RecommendationNavSourceTarget extends RecommendationTarget {
  const RecommendationNavSourceTarget(this.vod);

  final Vod vod;
}

/// 没有可播放身份可谈：沿用既有的「按标题搜索站源」页面。
final class RecommendationTitleSearchTarget extends RecommendationTarget {
  const RecommendationTitleSearchTarget(this.title);

  final String title;
}

/// 导航源回退页的合成条目。
///
/// `vodId` 必须为空：它没有任何站源身份，空 id 让 [AppState.loadDetail] **跳过
/// 站源详情请求**（`ids=` 空串只会换来一条业务错误），只跑 TMDB 链。因此本条目
/// 也不会写进 TMDB 匹配缓存（`TmdbMatchCache` 对空 vodId 读写都返回空），
/// 不会把不同作品的匹配结论串到一起。
Vod recommendationFallbackVod(TmdbItem item) => Vod(
  vodId: '',
  vodName: item.title,
  vodPic: item.posterUrl,
  vodContent: item.overview,
  extra: {'tmdb_id': item.tmdbId, 'media_type': item.mediaType.wireName},
);

/// 根据「搜索结果」判定跳转目标（纯函数，搜索结果由调用方先行取得）。
RecommendationTarget recommendationTargetFor({
  required TmdbItem item,
  List<Vod> results = const [],
  required int similarityPercent,
}) {
  if (item.identity == null) return RecommendationTitleSearchTarget(item.title);
  final keyword = recommendationSearchKeyword(item);
  final match = keyword.isEmpty
      ? null
      : recommendationSiteMatch(
          results,
          keyword: keyword,
          similarityPercent: similarityPercent,
        );
  if (match != null) return RecommendationSiteTarget(match);
  return RecommendationNavSourceTarget(recommendationFallbackVod(item));
}

/// 先搜索 [site] 再判定跳转目标（页面点击的统一入口）。
///
/// 契约：
/// - 没有 TMDB 身份 / 没有可用站点 / 标题为空 → 不搜索；
/// - 搜索**抛错或返回 `null`** 一律按「没命中」处理，退回导航源形态：推荐是
///   锦上添花，绝不能因为一次搜索失败就把点击变成异常或什么都不发生。
Future<RecommendationTarget> resolveRecommendationTarget({
  required TmdbItem item,
  required Site? site,
  required int similarityPercent,
  required Future<List<Vod>?> Function(Site site, String keyword) search,
}) async {
  if (item.identity == null) return RecommendationTitleSearchTarget(item.title);
  final targetSite = site;
  if (targetSite == null) return RecommendationTitleSearchTarget(item.title);
  final keyword = recommendationSearchKeyword(item);
  if (keyword.isEmpty) {
    return RecommendationNavSourceTarget(recommendationFallbackVod(item));
  }
  List<Vod>? results;
  try {
    results = await search(targetSite, keyword);
  } catch (_) {
    results = null;
  }
  return recommendationTargetFor(
    item: item,
    results: results ?? const [],
    similarityPercent: similarityPercent,
  );
}
