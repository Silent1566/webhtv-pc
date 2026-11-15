/// 「站点详情里的线路」+「每条线路该用哪个站点/vod_id 解析」。
///
/// 为什么把两者绑成一个值：播放器换集时只有线路、没有路由，就会拿**父目录**的
/// `vod_id` 去问站点。网盘聚合的目录条目（`atvp_detail:`）必须用条目自己的 id
/// 才能展开分享链（见 `protocol.dart` 的 `bridgeFolderVodId`），父目录 id 会被
/// 判为业务错误。线路与路由分开传递时，任何一处漏掉都会退回「父目录 id」。
library;

import 'protocol.dart';
import 'source_swap.dart';

/// 一次线路补齐的结果：线路列表 + 线路展示名到来源路由的映射。
///
/// [routes] 的键与 [VodPlayLine.flag] 一致（都是页面内的线路展示名）。空 Map
/// 表示这次补齐没有额外路由——普通详情记录就是这种形态，此时播放器沿用请求
/// 自带的 `siteKey`/`vodId`。
class PlaybackLines {
  const PlaybackLines({this.lines = const [], this.routes = const {}});

  /// 与详情页 / 目录页看到的是同一份线路（同样的展示名与分集）。
  final List<VodPlayLine> lines;

  /// 线路展示名 → 该线路自己的站点与 `vod_id`。
  final Map<String, SwapLineRoute> routes;

  static const PlaybackLines empty = PlaybackLines();

  bool get isEmpty => lines.isEmpty;

  bool get isNotEmpty => lines.isNotEmpty;

  /// 并入既有路由：**已有条目优先**。
  ///
  /// 已有路由来自详情页的换源合并（同一份页面上下文），比后补的线路更可信；
  /// 覆盖它会让用户切到换源线路后又被打回原站点。
  Map<String, SwapLineRoute> routesWith(Map<String, SwapLineRoute> existing) => {
    ...routes,
    ...existing,
  };
}
