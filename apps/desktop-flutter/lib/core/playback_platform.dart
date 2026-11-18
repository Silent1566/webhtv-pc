/// 播放平台标签的纯逻辑层（详情页 hero 标签行 + 追剧日历条目右上角共用）。
///
/// 口径（用户 2026-11-18 澄清）：播放平台 = TMDB 的 networks（播出平台/电视网），
/// 例如腾讯视频、爱奇艺、优酷、CCTV-8、HBO；**不是**爬虫站源 / 站点的名字。
/// 只有剧集（tv）响应带 networks，电影没有，因此电影不显示这个标签。
/// 都没有时返回空串，调用方整块不渲染（不留空标签位）。
///
/// 本层不依赖 Flutter 与 dart:io，可在 flutter test 里无副作用断言。
library;

/// TMDB 台名的中文显示名：只有显示层，未收录的原样返回。
///
/// TMDB 的 networks[].name 不随语言本地化（Youku / Tencent Video / iQIYI），
/// 因此这里给中文用户最常见的平台一份显式对照表；不猜、不音译，
/// 表里没有就照原样显示（如 HBO / Netflix / CCTV-8）。
const Map<String, String> networkDisplayNamesZh = {
  'tencent video': '腾讯视频',
  'iqiyi': '爱奇艺',
  'youku': '优酷',
  'mango tv': '芒果TV',
  'mangotv': '芒果TV',
  'bilibili': '哔哩哔哩',
  'sohu video': '搜狐视频',
  // 卫视：TMDB 两套写法混用（Hunan TV / Hunan Television），两套都收。
  'hunan tv': '湖南卫视',
  'hunan television': '湖南卫视',
  'hunan broadcasting system': '湖南卫视',
  'zhejiang tv': '浙江卫视',
  'zhejiang television': '浙江卫视',
  'jiangsu tv': '江苏卫视',
  'jiangsu television': '江苏卫视',
  'dragon tv': '东方卫视',
  'dragon television': '东方卫视',
  'beijing tv': '北京卫视',
  'beijing television': '北京卫视',
  'shenzhen tv': '深圳卫视',
  'shenzhen television': '深圳卫视',
  'anhui tv': '安徽卫视',
  'anhui television': '安徽卫视',
  'shandong tv': '山东卫视',
  'shandong television': '山东卫视',
  'guangdong tv': '广东卫视',
  'guangdong television': '广东卫视',
  'tianjin tv': '天津卫视',
  'tianjin television': '天津卫视',
  'henan tv': '河南卫视',
  'henan television': '河南卫视',
  'hubei tv': '湖北卫视',
  'hubei television': '湖北卫视',
  'sichuan tv': '四川卫视',
  'sichuan television': '四川卫视',
  'liaoning tv': '辽宁卫视',
  'liaoning television': '辽宁卫视',
  'jilin tv': '吉林卫视',
  'jilin television': '吉林卫视',
  'hebei tv': '河北卫视',
  'hebei television': '河北卫视',
  'yunnan tv': '云南卫视',
  'yunnan television': '云南卫视',
};

/// 台名的中文显示名；空串返回空串。
String tmdbNetworkDisplayName(String name) {
  final text = name.trim();
  if (text.isEmpty) return '';
  return networkDisplayNamesZh[text.toLowerCase()] ?? text;
}

/// 从 TMDB 详情响应的 networks 取台名：去空、去重、保序，上限 cap。
///
/// [networks] 允许是任何形状（非 List、元素不是 Map、name 缺失都跳过），
/// 调用方不必先校验响应结构。[cap] 小于等于 0 表示不设上限。
List<String> tmdbNetworkNames(Object? networks, {int cap = 2}) {
  if (networks is! List) return const [];
  final names = <String>[];
  for (final value in networks) {
    if (value is! Map) continue;
    final text = (value['name'] ?? '').toString().trim();
    if (text.isEmpty || names.contains(text)) continue;
    names.add(text);
    if (cap > 0 && names.length >= cap) break;
  }
  return names;
}

/// 平台标签文案：台名转中文显示名后以 " / " 连接，最多 [maxNetworks] 个。
///
/// 返回空串表示「没有可展示的平台」，调用方据此隐藏标签，不要用占位文案。
String playbackPlatformLabel({
  List<String> networks = const [],
  int maxNetworks = 2,
}) {
  final names = <String>[];
  for (final value in networks) {
    final text = tmdbNetworkDisplayName(value);
    if (text.isEmpty || names.contains(text)) continue;
    names.add(text);
    if (maxNetworks > 0 && names.length >= maxNetworks) break;
  }
  return names.join(' / ');
}
