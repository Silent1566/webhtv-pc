/// 推荐 → 详情：**一条规则，多处分入口**。
///
/// 去向由纯函数 [resolveRecommendationTarget] 判定——命中当前站点 → 该站点的真实
/// 条目详情页（可直接播放）；没命中 / 搜索失败 → 导航源形态的回退详情页
/// （TMDB 剧集卡片 + 换源 + 重新匹配）；没有 TMDB 身份 → 按标题搜站源。
///
/// 本文件只承担「发一次快搜 + 按去向推页」这一段。点播页的推荐卡自己做了同样的
/// 一段（它额外要在推页期间持住本站详情，见 browse_pages.dart 的
/// _pushRecommendationDetail），首页没有这份牵挂，直接走这里——两处因此不会一处
/// 进站点详情页、另一处进纯 TMDB 页（用户 2026-11-21 反馈：首页「查看详情」的
/// 页面与导航站详情页效果不一致，且没有「重新匹配」）。
library;

import 'package:flutter/material.dart';

import '../core/protocol.dart';
import '../core/recommendation_target.dart';
import '../core/tmdb_identity.dart';
import '../state/app_state.dart';
import 'browse_pages.dart';
import 'search_page.dart';
import 'glass_widgets.dart';

/// 打开 [item] 的详情页。
///
/// [site] 是「按标题搜一次」的目标站点，通常是生效配置的选中站点。为空时按
/// [resolveRecommendationTarget] 的既有口径退回按标题搜索页——不伪造可播放身份，
/// 也不假装这部作品在当前站点有货。
Future<void> openRecommendationDetail(
  BuildContext context,
  AppState state,
  TmdbItem item, {
  required Site? site,
}) async {
  final target = await resolveRecommendationTarget(
    item: item,
    site: site,
    similarityPercent: state.searchSimilarity,
    // 与换源浮层同一口径（安卓 startInlineSourceSearch 也是 quick）。
    search: (site, keyword) async =>
        (await state.search(site, keyword: keyword, quick: true))?.list,
  );
  if (!context.mounted) return;
  switch (target) {
    case RecommendationSiteTarget(:final vod):
    case RecommendationNavSourceTarget(:final vod):
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => DetailPage(state: state, vod: vod),
        ),
      );
    case RecommendationTitleSearchTarget(:final title):
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => Scaffold(
            appBar: AppBar(
              title: const Text('搜索站源'),
              backgroundColor: Colors.transparent,
              flexibleSpace: const IgnorePointer(
                child: GlassPane(
                  borderRadius: BorderRadius.zero,
                  child: SizedBox.expand(),
                ),
              ),
            ),
            body: SearchPage(state: state, initialKeyword: title),
          ),
        ),
      );
  }
}
