/// 首页「热门」轨道：把 360kan 榜单折成三条 `HomeRail`。
///
/// 与 `home_feed.dart` 同一种分工：**只做投影**——不取数、不排序、不持有状态，
/// 给定输入输出确定，因此可以纯 Dart 单测钉死。
///
/// 单独一个文件而不是并进 `buildHomeFeed`：热门的数据来源是外网榜单，
/// 与本机三源（历史 / 追剧 / 推荐）没有交集，混进去会让「本地数据全空 = 空态」
/// 这条判断多出一个异步来源。
library;

import '../services/search_suggest_service.dart';
import 'home_feed.dart';

/// 单条热门轨道的条目上限。
///
/// 默认投影与 `SearchSuggestService.hotPoolLimit`(30) 同口径。
/// 首页分页显式传 `maxItems: null`，保留同一次请求已返回的完整榜单快照。
const int _hotRailMax = 30;

/// 榜单条目 → 首页卡片。
///
/// [categoryKey] 只进 key，不进文案：三个类目里同名的作品是两件作品，
/// 而卡面上看不出「这是电影榜单还是剧集榜单」——标题已经写在轨道上了。
HomeItem hotItem(SearchSuggestItem item, {required String categoryKey}) {
  final title = item.title.trim();
  final upinfo = item.subtitle?.trim() ?? '';
  final score = item.score?.trim() ?? '';
  return HomeItem(
    kind: HomeItemKind.hot,
    key: _hotKey(item, categoryKey, title),
    title: title,
    poster: _imageOrNull(item.cover),
    // 口径与推荐行一致：一个评分，不叠年份（推荐行那边是 recommendation_meta）。
    // 榜单只给豆瓣分，所以这里直接写出来源，免得和 TMDB / AI 的分数混为一谈。
    subtitle: score.isEmpty ? '' : '豆瓣 $score',
    // upinfo 是「全47集」「2026-10-13期」，正好是卡片第二行要的信息；
    // 缺了才退回类目名，而不是留空——热门卡少一行会显得没加载完。
    reason: upinfo.isEmpty ? '热门' : upinfo,
  );
}

/// 三个类目的轨道。
///
/// 空类目不出轨道，全空返回 `const []`：调用方拿到的永远是「能直接铺进列表」
/// 的东西，不用再过滤一遍空列表（空轨道在页面上就是一条空行）。
List<HomeRail> hotRails(
  Map<HotRankCategory, List<SearchSuggestItem>> byCategory, {
  int? maxItems = _hotRailMax,
}) {
  final rails = <HomeRail>[];
  for (final spec in _railSpecs) {
    final items = _hotItems(
      byCategory[spec.category],
      spec.category.name,
      maxItems,
    );
    if (items.isEmpty) continue;
    // seeAll 恒为 null：热门没有独立页，入口点不开就不放（HomeSeeAll 里也没有
    // 对应值），与推荐行同一个理由。
    rails.add(HomeRail(kind: spec.kind, title: spec.title, items: items));
  }
  return rails.isEmpty ? const [] : rails;
}

/// 类目的固定顺序与文案：剧集 → 电影 → 综艺。
///
/// 顺序写死在表里而不是遍历入参 map：map 的迭代顺序由调用方怎么建决定，
/// 首页三条轨道的先后不该随入参的构造方式变来变去。
class _RailSpec {
  const _RailSpec(this.category, this.kind, this.title);

  final HotRankCategory category;
  final HomeRailKind kind;
  final String title;
}

const List<_RailSpec> _railSpecs = [
  _RailSpec(HotRankCategory.series, HomeRailKind.hotTv, '热门剧集'),
  _RailSpec(HotRankCategory.movie, HomeRailKind.hotMovie, '热门电影'),
  _RailSpec(HotRankCategory.variety, HomeRailKind.hotVariety, '热门综艺'),
];

/// 一个类目的条目：**保持榜单原序**，只截断、不去重排。
///
/// 名次本身就是榜单想说的话，按评分或标题再排一次等于替 360kan 重排。
List<HomeItem> _hotItems(
  List<SearchSuggestItem>? pool,
  String categoryKey,
  int? maxItems,
) {
  if (pool == null) return const [];
  final items = <HomeItem>[];
  final seen = <String>{};
  for (final row in pool) {
    if (maxItems != null && items.length >= maxItems) break;
    final item = hotItem(row, categoryKey: categoryKey);
    // 榜单偶尔把同一部作品排两次；key 撞车会让卡片列表出现两个相同 key。
    // 留先出现的那条：名次更靠前，也维持「不重排」。
    if (!seen.add(item.key)) continue;
    items.add(item);
  }
  return items;
}

/// 条目的去重键。
///
/// 名次是榜单身份，但它只在**类目内**唯一（电影第 1 名和剧集第 1 名是两件作品），
/// 所以类目必须进 key。缺名次的行退回标题：那种行很少，但没有 key 比 key 不够
/// 漂亮更糟。
String _hotKey(SearchSuggestItem item, String categoryKey, String title) {
  final rank = item.rank ?? 0;
  if (rank > 0) return 'hot:$categoryKey:$rank';
  return 'hot:$categoryKey:$title';
}

/// 图片地址的空值归一：空串按「没有图」处理，让页面层的兜底链能生效。
String? _imageOrNull(String? url) {
  final trimmed = url?.trim() ?? '';
  return trimmed.isEmpty ? null : trimmed;
}
