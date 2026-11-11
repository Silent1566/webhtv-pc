/// 本地导入源（`spiders/local/<key>/` 与 `webhome/<key>/`）如何变成**可选站点**。
///
/// 与 [AppState] 分离的理由：站点条目构造与合并优先级是纯函数，能脱离
/// 注册表/磁盘单独验证；而写入 `_config`、缓存失效、路由刷新属于状态机，
/// 留在 `AppState` 里。
///
/// 合并优先级（高 → 低）：**JSON 注入 > 用户配置 > 本地导入源**。
/// 同 key 一律不覆盖：本地条目被拒绝并记入 [LocalSiteMerge.rejectedKeys]，
/// 由调用方如实报告，而不是静默丢掉或悄悄改写别人的站点。
library;

import 'package:path/path.dart' as p;

import '../core/protocol.dart';
import '../services/spider_registry.dart';
import '../services/spider_router.dart';
import '../services/web_home_store.dart';

/// 本地 HTML 首页站点的 `api` 前缀。
///
/// **不复用 `spider-local:`**：那个 scheme 表示 `webhtv-ipc-v1` sidecar 爬虫，
/// 而 webHome 由 WebView2 承载、**不可搜索**。混用会让页面宿主被当成爬虫路由
/// （`SpiderLocalBinding.resolve` 找不到 manifest，界面显示「manifest 未注册」
/// 而真实原因只是"它不是爬虫"）。
const String webHomeApiScheme = 'web-home:';

String webHomeApiForKey(String key) => '$webHomeApiScheme$key';

/// 站点是否为本地 HTML 首页；是则返回 webHome key，否则 null。
String? webHomeKeyOfSite(Site site) {
  final api = site.api.trim();
  if (!api.startsWith(webHomeApiScheme)) return null;
  final key = api.substring(webHomeApiScheme.length).trim();
  return key.isEmpty ? null : key;
}

/// 本地 HTML 首页条目的可用性：**可打开、不提供站点内搜索**。
const SiteAvailability webHomeSiteAvailability = SiteAvailability(
  available: true,
  runtimeName: 'HTML 首页 (WebView2)',
  stage: 'MVP-B',
  reason: '本地 HTML 页面，不提供站点内搜索',
);

/// 该 Spider 是否属于「用户导入的本地源」，即落在 `spiders/local/<key>/`。
///
/// **根级 manifest 不算**：手工添加与远端直连注册的产物写在 `spiders/<key>/`，
/// 它们是**被配置按 key 引用**的存在（`api=spider-local:<key>` 或直连注册结果）。
/// 把它们自动变成站点，会让用户凭空多出一批没选择过的站点，并让运行中的站点
/// 集合与配置不一致（实测回归：`phase2_spider_page_test` 的运行时状态由 1 变 2）。
bool isImportedLocalSpider(LocalSpider spider, String registryRoot) =>
    p.isWithin(p.join(registryRoot, 'local'), spider.rootDir);

/// 由已注册的本地 Spider 与已启用的 webHome 源构造站点条目。
///
/// - py/js 沿用既有 `spider-local:<key>` 路由；
/// - html 用 `web-home:<key>` 且 `searchable=false`：它不是爬虫，不假装能搜；
/// - 按 key 排序固定：导入前后列表位置不跳。
List<Site> buildLocalSourceSites({
  required Iterable<LocalSpider> spiders,
  required Iterable<WebHomeSource> webHomeSources,
}) {
  final sites = <Site>[
    for (final spider in spiders)
      Site(
        key: spider.key,
        name: spider.manifest.name,
        type: 3,
        api: '${SpiderLocalBinding.scheme}${spider.key}',
        searchable: spider.manifest.capabilities.supports('search'),
      ),
    for (final source in webHomeSources)
      Site(
        key: source.key,
        name: source.name,
        type: 3,
        api: webHomeApiForKey(source.key),
        searchable: false,
      ),
  ]..sort((a, b) => a.key.compareTo(b.key));
  return sites;
}

/// 本地源并入后的结论。
class LocalSiteMerge {
  const LocalSiteMerge({required this.config, this.rejectedKeys = const []});

  final AppConfig config;

  /// 因为同 key 已存在（用户配置或 JSON 注入）而被拒绝的本地 key，保持输入顺序。
  final List<String> rejectedKeys;
}

/// 把本地源**追加**到既有合并结果之后。
///
/// [base] 是 `用户配置 + JSON 注入` 的结果；为 null 表示用户还没有任何配置——
/// 此时返回只含本地源的配置，让「没有任何配置也能用本地源」成立。
///
/// 本函数只构造新对象，绝不写回配置记录：调用方不得把结果持久化，
/// 否则本地源会被固化进用户配置（下次打开就变成"用户自己写的站点"）。
LocalSiteMerge mergeLocalSourceSites(AppConfig? base, List<Site> localSites) {
  final merged = LocalSiteMerge(config: base ?? AppConfig());
  if (localSites.isEmpty) return merged;
  final config = base ?? AppConfig();
  final sites = List<Site>.of(config.sites);
  final existing = sites.map((site) => site.key).toSet();
  final rejected = <String>[];
  for (final site in localSites) {
    if (!existing.add(site.key)) {
      rejected.add(site.key);
      continue;
    }
    sites.add(site);
  }
  if (rejected.isEmpty) {
    return LocalSiteMerge(config: _copyWithSites(config, sites));
  }
  return LocalSiteMerge(
    config: _copyWithSites(config, sites),
    rejectedKeys: rejected,
  );
}

/// 复制配置、只替换站点列表（其余字段原样保留，避免丢失 doh/hosts/ads 等）。
AppConfig _copyWithSites(AppConfig config, List<Site> sites) => AppConfig(
  name: config.name,
  spider: config.spider,
  sites: sites,
  parses: config.parses,
  flags: config.flags,
  lives: config.lives,
  doh: config.doh,
  proxy: config.proxy,
  hosts: config.hosts,
  headers: config.headers,
  rules: config.rules,
  hlsRules: config.hlsRules,
  groupRules: config.groupRules,
  ads: config.ads,
  wallpaper: config.wallpaper,
  logo: config.logo,
  notice: config.notice,
  home: config.home,
  parse: config.parse,
  urls: config.urls,
  msg: config.msg,
  hasMsgKey: config.hasMsgKey,
  extra: config.extra,
);
