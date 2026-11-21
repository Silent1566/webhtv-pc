/// TMDB API / 图片线路的内置预设（对齐安卓 `utils/TmdbProxy`）。
///
/// 这一层是**纯逻辑**：只有常量与地址归一，不依赖 Flutter、`dart:io` 与 `http`。
///
/// 为什么需要预设：海报与背景全部走 `images.tmdb.org`，这个域名在部分网络下
/// 打不开或极慢。安卓版内置了官方直连、公共反代与 wsrv.nl 三条可切换的图片
/// 线路；PC 版此前只能手打完整地址（还得自己记住 `/t/p/w342` 的尾巴），既容易
/// 写错，也不知道还有哪些线路可用。
///
/// 与安卓的差异（有意）：安卓的 `auto`（低延迟优先 + 失败切换）要有运行时测速
/// 与逐图兜底，PC 端没有等价实现，因此这里只提供**静态线路选择**——设置页的
/// 「测试图片线路」按钮让用户自测，选中后不做静默切换（换线路是用户的决定，
/// 不是运行时偷偷改配置）。
library;

import 'tmdb_media.dart';

/// 一条可选线路。
class TmdbRouteOption {
  const TmdbRouteOption({
    required this.value,
    required this.label,
    required this.note,
  });

  /// 输入形态：API 不含 `/3`，图片不含 `/t/p/<尺寸>`。
  ///
  /// 写进 `TmdbConfig` 前一律过 `sanitize()`，由它补 `/3` 与 `/t/p/w342`；
  /// 这样预设与用户手打的地址走同一条归一化路径，不需要第二套解析。
  final String value;

  /// 下拉里显示的名字。
  final String label;

  /// 一行说明：这条线路是什么、为什么会用它。
  final String note;
}

/// 「自动」线路的哨兵值（对齐安卓 `TmdbProxy.AUTO`）。
///
/// 存的是语义而不是地址：具体走哪条由 [TmdbRouteSelector] 按实测延迟与失败
/// 冷却实时决定，因此换线路不需要改配置。
const String tmdbAutoRoute = 'auto';

/// 是否是「自动」线路。
bool tmdbIsAutoRoute(String value) =>
    value.trim().toLowerCase() == tmdbAutoRoute;

/// 自动模式下的 API 候选（顺序＝未测速时的默认优先级）。
///
/// 三条均实测可用（2026-11-21，`/3/configuration` 返回 401＝已转发到 TMDB，
/// 只是缺 key）：官方 2.86s / 备用 2.86s / 反代 2.00s。
/// 安卓内置的 `tmdb.itv666.cc` 实测连接失败（000），不收录。
const List<String> tmdbApiAutoCandidates = [
  'https://api.tmdb.org',
  'https://api.themoviedb.org',
  'https://jsnzkpg4.pages.dev/https://api.tmdb.org',
];

/// 自动模式下的图片候选（顺序＝未测速时的默认优先级）。
///
/// 四条均实测可用（2026-11-21，同一张 w342 海报全部返回 200）：
/// 官方 2.27s / 官方备用 1.85s / 反代 2.18s / wsrv 0.91s（重新编码，40.6 KB）。
const List<String> tmdbImageAutoCandidates = [
  'https://images.tmdb.org',
  'https://jsnzkpg4.pages.dev/https://image.tmdb.org',
  'https://wsrv.nl/?url=https://image.tmdb.org',
  'https://image.tmdb.org',
];

/// 内置 API 线路。标签里带域名，用户在下拉里就能确认自己选的是谁。
const List<TmdbRouteOption> tmdbApiRoutes = [
  TmdbRouteOption(
    value: tmdbAutoRoute,
    label: '自动（低延迟优先，失败切换）',
    note: '按实测延迟排序，请求失败自动换下一条（与安卓同语义）',
  ),
  TmdbRouteOption(
    value: 'https://api.tmdb.org',
    label: '官方 API（api.tmdb.org）',
    note: 'https://api.tmdb.org/3 · TMDB 官方主域名',
  ),
  TmdbRouteOption(
    value: 'https://api.themoviedb.org',
    label: '官方备用（api.themoviedb.org）',
    note: '官方另一域名 · 主域名解析异常时换这条',
  ),
  TmdbRouteOption(
    value: 'https://jsnzkpg4.pages.dev/https://api.tmdb.org',
    label: '公共反代（jsnzkpg4.pages.dev）',
    note: '把官方地址接在反代后面 · API 与图片同一个域名',
  ),
];

/// 内置图片线路。标签里带域名，用户在下拉里就能确认自己选的是谁。
const List<TmdbRouteOption> tmdbImageRoutes = [
  TmdbRouteOption(
    value: tmdbAutoRoute,
    label: '自动（测速择优，失败重测）',
    note: '启动时测速选最快的一条；取图连续失败会自动重测并换线',
  ),
  TmdbRouteOption(
    value: 'https://images.tmdb.org',
    label: '官方图片（images.tmdb.org）',
    note: 'https://images.tmdb.org/t/p/w342 · TMDB 官方图床',
  ),
  TmdbRouteOption(
    value: 'https://image.tmdb.org',
    label: '官方备用（image.tmdb.org）',
    note: '官方另一图床域名（单数 image），与官方图床同源',
  ),
  TmdbRouteOption(
    value: 'https://jsnzkpg4.pages.dev/https://image.tmdb.org',
    label: '公共反代（jsnzkpg4.pages.dev）',
    note: '拼出来是 <反代>/https://image.tmdb.org/t/p/w342/… · 实测可用',
  ),
  TmdbRouteOption(
    value: 'https://wsrv.nl/?url=https://image.tmdb.org',
    label: 'wsrv.nl 图片代理（wsrv.nl）',
    note: '第三方图片 CDN，会重新编码（同一张海报字节数会变）',
  ),
];

/// 线路探测用的图片：TMDB 官方公共海报（w342）。
///
/// 换线路的用户要的答案就是「这张图能不能拿到、多快」，所以探测必须取一张
/// 真图而不是只问域名在不在：404 与 200 的区别正是「反代活着但上游没通」与
/// 「线路可用」的区别。
const String tmdbImageProbePath =
    '/t/p/w342/jSziioSwPVrOy9Yow3XhWIBDjq1.jpg';

String _withScheme(String value) {
  final text = value.trim();
  if (text.isEmpty || text.contains('://')) return text;
  return 'https://$text';
}

String _trimTrailingSlash(String value) {
  var text = value;
  while (text.endsWith('/')) {
    text = text.substring(0, text.length - 1);
  }
  return text;
}

/// 去掉尺寸段与 `/t/p`，保留原大小写：`…/t/p/w342` → `…`。
String _imageHostOf(String value) {
  var text = _trimTrailingSlash(_withScheme(value));
  text = _trimTrailingSlash(TmdbImageSelector.stripImageSize(text));
  if (text.endsWith('/t/p')) {
    text = _trimTrailingSlash(text.substring(0, text.length - 4));
  }
  return text;
}

/// API 线路的比较键：补协议、去末尾斜杠、去末尾 `/3`、小写。
String tmdbApiRouteKey(String value) {
  if (tmdbIsAutoRoute(value)) return tmdbAutoRoute;
  var text = _trimTrailingSlash(_withScheme(value));
  if (text.endsWith('/3')) {
    text = _trimTrailingSlash(text.substring(0, text.length - 2));
  }
  return text.toLowerCase();
}

/// 图片线路的比较键：在 [tmdbApiRouteKey] 基础上再去 `/t/p` 与尺寸段。
String tmdbImageRouteKey(String value) =>
    tmdbIsAutoRoute(value) ? tmdbAutoRoute : _imageHostOf(value).toLowerCase();

/// 命中的内置 API 线路；未命中返回 `null`（＝用户自定义地址）。
TmdbRouteOption? tmdbApiRouteOf(String apiBase) {
  final key = tmdbApiRouteKey(apiBase);
  for (final option in tmdbApiRoutes) {
    if (tmdbApiRouteKey(option.value) == key) return option;
  }
  return null;
}

/// 命中的内置图片线路；未命中返回 `null`（＝用户自定义地址）。
///
/// 只按「线路」比较，尺寸与 `/t/p` 尾巴不参与：用户把官方图床改成 `w500`
/// 仍然算官方线路，设置页不该显示成「自定义」。
TmdbRouteOption? tmdbImageRouteOf(String imageBase) {
  final key = tmdbImageRouteKey(imageBase);
  for (final option in tmdbImageRoutes) {
    if (tmdbImageRouteKey(option.value) == key) return option;
  }
  return null;
}

/// 设置页显示的「当前实际线路」快照（自动模式下是已解析的那条）。
class TmdbRouteStatus {
  const TmdbRouteStatus({
    required this.apiBase,
    required this.imageBase,
    required this.apiAuto,
    required this.imageAuto,
  });

  /// 实际生效的 API 基址（`…/3`）。
  final String apiBase;

  /// 实际生效的图片基址（`…/t/p/w342`）。
  final String imageBase;

  final bool apiAuto;
  final bool imageAuto;

  /// 一行线路名：自动模式写出当前解析到的主机，否则用内置线路名。
  String get apiLabel => _routeLabel(apiBase, tmdbApiRoutes, apiAuto);

  String get imageLabel => _routeLabel(imageBase, tmdbImageRoutes, imageAuto);

  String get apiHost => _hostOf(apiBase);

  String get imageHost => _hostOf(imageBase);
}

String _routeLabel(String base, List<TmdbRouteOption> routes, bool auto) {
  final host = _hostOf(base);
  if (auto) return '自动 · $host';
  for (final option in routes) {
    if (option.value == tmdbAutoRoute) continue;
    if (tmdbApiRouteKey(option.value) == tmdbApiRouteKey(base)) return option.label;
  }
  return host;
}

String _hostOf(String value) {
  final host = Uri.tryParse(value.trim())?.host ?? '';
  return host.isEmpty ? value.trim() : host;
}

/// 一次图片线路探测的结果（纯数据，设置页直接显示）。
class TmdbImageProbe {
  const TmdbImageProbe({
    required this.url,
    required this.statusCode,
    required this.bytes,
    required this.elapsed,
    this.error,
  });

  /// 实际请求的地址。
  final String url;

  /// HTTP 状态码；`0` 表示连响应都没拿到（DNS / 连接失败 / 超时）。
  final int statusCode;

  /// 响应体字节数。
  final int bytes;

  final Duration elapsed;

  /// 失败原因（人话）；成功时为 `null`。
  final String? error;

  bool get ok => statusCode == 200 && bytes > 0;
}

/// 探测结果的一句话结论（设置页原样显示）。
String tmdbImageProbeSummary(TmdbImageProbe probe) {
  final host = Uri.tryParse(probe.url)?.host ?? '';
  final prefix = host.isEmpty ? '图片线路' : '图片线路 $host';
  if (probe.ok) {
    final kb = (probe.bytes / 1024).toStringAsFixed(1);
    final seconds = (probe.elapsed.inMilliseconds / 1000).toStringAsFixed(2);
    return '$prefix 正常：HTTP 200 · $kb KB · ${seconds}s';
  }
  if (probe.statusCode == 0) {
    return '$prefix 不可用：${probe.error ?? '没有拿到响应'}';
  }
  return '$prefix 返回 HTTP ${probe.statusCode}'
      '${probe.error == null ? '' : '（${probe.error}）'}';
}

/// 从一张已拼接的图片 URL 反查它属于哪条候选线路（按主机名匹配）。
///
/// 自动线路要靠它把「某张图挂了」归因到具体线路；反代与官方域名的主机不同，
/// 因此主机名足够区分（wsrv 这类目标地址在查询参数里的形态也只需看主机）。
String? tmdbImageRouteOfUrl(String url, List<String> candidates) {
  final host = Uri.tryParse(url.trim())?.host.toLowerCase() ?? '';
  if (host.isEmpty) return null;
  for (final candidate in candidates) {
    if (Uri.tryParse(candidate.trim())?.host.toLowerCase() == host) return candidate;
  }
  return null;
}

/// 线路探测地址：`<图片线路>/t/p/w342/<公共海报>`。
///
/// 三种线路形态都能拼：官方 `…/t/p/w342/x.jpg`、反代
/// `<反代>/https://image.tmdb.org/t/p/w342/x.jpg`、wsrv 的
/// `?url=https://image.tmdb.org/t/p/w342/x.jpg`。
String tmdbImageProbeUrl(String imageValue) {
  // 自动线路没有具体地址：探测前必须先用 [TmdbRouteSelector] 解析。
  if (tmdbIsAutoRoute(imageValue)) return '';
  final host = _imageHostOf(imageValue);
  if (host.isEmpty) return '';
  return TmdbImageSelector.image(host, tmdbImageProbePath);
}
