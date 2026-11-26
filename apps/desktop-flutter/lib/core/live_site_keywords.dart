/// 直播站的识别口径（用户 2026-11-25：照安卓「按名称屏蔽短剧 / 小说」那套做法，
/// 关键词可自定义，默认只内置两个）。
///
/// 为什么只能按名字判：站点数据模型里没有「直播」字段（`config_sites` 只有 type 3/4，
/// 和点播站共用同一套取值），历史行也没有 `is_live` 列；而真实存在的直播站名字里都写着
/// 「直播」（「网络直播[官]」「虎牙直播[官]」「🌇｜斗鱼｜直播」）。这和
/// `TmdbConfig.disabledSites` 判「短剧 / 小说」用的是同一种包含匹配，所以复用它的
/// `normalizeBrackets`，两边口径一致。
library;

import 'tmdb_config.dart' show normalizeBrackets;

/// 内置关键词。用户可在「设置 → 直播」里增删；删空等于关掉这条判据。
const List<String> liveSiteDefaultKeywords = ['直播', 'Live'];

/// 归一化用户输入：去首尾空白、丢空串、大小写不敏感去重，保序。
List<String> normalizeLiveSiteKeywords(Iterable<String> raw) {
  final seen = <String>{};
  final out = <String>[];
  for (final item in raw) {
    final text = item.trim();
    if (text.isEmpty) continue;
    if (!seen.add(text.toLowerCase())) continue;
    out.add(text);
  }
  return out;
}

/// [text] 是否命中 [keywords] 里任意一条（包含匹配，忽略全/半角括号与大小写）。
bool matchesLiveSiteKeyword(Iterable<String> keywords, String text) {
  final target = normalizeBrackets(text).toLowerCase();
  if (target.isEmpty) return false;
  for (final keyword in keywords) {
    final normalized = normalizeBrackets(keyword.trim()).toLowerCase();
    if (normalized.isEmpty) continue;
    if (target.contains(normalized)) return true;
  }
  return false;
}

/// 直播站的 site key 集合：直播源名 + 站点名/键命中关键词的站点。
///
/// 首页据此把直播行挡在外面（`buildHomeFeed(liveSiteKeys:)`）。站点名与键都查一遍：
/// 配置里既有名字叫「🌇｜斗鱼｜直播」而键叫 `Douyu` 的站，也有键叫 `csp_Live`
/// 而名字叫「网络直播[官]」的站。
Set<String> liveSiteKeysFor({
  required Iterable<String> sourceNames,
  required Map<String, String> siteNames,
  required Iterable<String> keywords,
}) {
  final keys = <String>{...sourceNames};
  for (final entry in siteNames.entries) {
    if (matchesLiveSiteKeyword(keywords, entry.value) ||
        matchesLiveSiteKeyword(keywords, entry.key)) {
      keys.add(entry.key);
    }
  }
  return keys;
}
