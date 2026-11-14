/// 历史记录海报补齐的三级回退（纯 Dart，不依赖 Flutter，也不碰数据库）。
///
/// 为什么需要三级：「最近观看」里的记录可能来自**桥接源**，那类站点的
/// `ids=` 详情实测返回 `vod_id:\"\" vod_pic:\"\"`（空壳），只有 `wd=片名` 搜索
/// 能拿到图；而记录归属的配置还可能是**非生效配置**，现有
/// `DatabaseTmdbMatchStore` 被 `config_id` 绑在生效配置上读不到它的海报行。
/// 所以顺序按「最便宜且最精确」到「最贵且最模糊」排列，每级命中即短路。
library;

import '../core/protocol.dart';
import 'storage.dart';
import 'site_service.dart';

/// 三级回退取海报。构造注入协作者，自身无状态、可测。
class HistoryPosterRepair {
  HistoryPosterRepair({
    required this.siteService,
    required this.configForSourceKey,
    required this.cachedTmdbPosterUrl,
    required this.fallbackConfig,
  });

  final SiteService? siteService;

  /// 取记录**自己的**配置；返回 null 时退回 [fallbackConfig]。
  final AppConfig? Function(String sourceKey) configForSourceKey;

  /// 跨配置读 TMDB 缓存海报（只关心图，不关心它属于哪份配置）。
  final String? Function(String siteKey, String vodId) cachedTmdbPosterUrl;

  /// 生效配置，兜底用。
  final AppConfig? fallbackConfig;

  /// 逐级取海报，任一级命中即返回；取不到返回 null。
  ///
  /// 每级各自 try/catch：一级抛异常不能把后面两级一起拖下水——这三级本来就
  /// 是「哪级能拿到算哪级」，互相之间不该有失败传染。
  Future<String?> posterFor(PlaybackHistory item) async {
    final siteKey = item.siteKey.trim();
    final vodId = item.vodId.trim();
    if (siteKey.isEmpty || vodId.isEmpty) return null;

    final site = _siteOf(siteKey, item.sourceKey);
    final l1 = await _fromDetail(site, item);
    if (l1 != null) return l1;
    final l2 = _fromTmdbCache(siteKey, vodId);
    if (l2 != null) return l2;
    return _fromSearch(site, item);
  }

  /// 按记录自己的配置找站点：跨源记录要拿它所属那份配置的 sites，
  /// 拿生效配置会找不到（这就是原缺陷）。
  Site? _siteOf(String siteKey, String sourceKey) {
    try {
      final config = configForSourceKey(sourceKey.trim()) ?? fallbackConfig;
      if (config == null) return null;
      for (final site in config.sites) {
        if (site.key == siteKey) return site;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// L1 站点详情：最精确，且不需要额外关键词。
  ///
  /// folder 壳必须走 `t=` 展开，拿它调 `ids=` 会被站源判业务错误（见
  /// `Vod.isFolder` 的注释）。
  Future<String?> _fromDetail(Site? site, PlaybackHistory item) async {
    final service = siteService;
    if (service == null || site == null) return null;
    try {
      final parent = Vod(vodId: item.vodId, vodName: item.vodName);
      final result = parent.isFolder
          ? await service.folderDetail(site, parent)
          : await service.detail(
              site,
              item.vodId,
              identity: VodIdentityHint(
                vodId: item.vodId,
                vodName: item.vodName,
              ),
            );
      if (result.value.list.isEmpty) return null;
      return _clean(result.value.list.first.vodPic);
    } catch (_) {
      return null;
    }
  }

  /// L2 TMDB 缓存：**即使 L1 找不到站点也必须走到这一级**。
  /// 桥接源的详情是空壳，海报只可能落在 TMDB 匹配行里。
  String? _fromTmdbCache(String siteKey, String vodId) {
    try {
      return _clean(cachedTmdbPosterUrl(siteKey, vodId));
    } catch (_) {
      return null;
    }
  }

  /// L3 搜索兜底：最贵也最模糊，只在站点声明可搜索时做。
  ///
  /// `cache: false`：这次搜索不是用户发起的，写进搜索缓存会污染
  /// `(关键词, 站点)` 这条键，用户之后搜同一片名会看到这次的结果。
  Future<String?> _fromSearch(Site? site, PlaybackHistory item) async {
    final service = siteService;
    final keyword = item.vodName.trim();
    if (service == null || site == null || !site.searchable) return null;
    if (keyword.isEmpty) return null;
    try {
      final result = await service.search(
        site,
        keyword: keyword,
        quick: site.quickSearch,
        cache: false,
      );
      final list = result.value.list;
      for (final vod in list) {
        if (vod.vodId == item.vodId) return _clean(vod.vodPic);
      }
      // 桥接源重建出的 vod_id 可能已经变了，退一步按片名认人：历史里保存的
      // 片名带前后空格，搜索结果是干净的，所以两边都 trim 后比。
      for (final vod in list) {
        if (vod.vodName.trim() == keyword) return _clean(vod.vodPic);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  static String? _clean(String? poster) {
    final trimmed = poster?.trim();
    return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }
}
