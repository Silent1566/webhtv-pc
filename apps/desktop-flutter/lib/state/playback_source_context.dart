/// 一份**非当前**配置的播放上下文（历史记录按「原来源」播放/看详情用）。
///
/// ## 为什么需要它
///
/// 全局历史里混着别的播放源（桥接设备上的另一个配置、PC 导入的另一份配置）。
/// 用户点这类记录时，正确行为是**用那条记录所属配置的信息**解析播放，
/// 而**不**切换当前配置，也不改顶栏选中的站点——`activateConfigRecord` 会把
/// 整个 App 弹到另一个源上（`history_cross_source.dart` 头部注释的决定 1）。
///
/// 光把站点对象传下去不够：站点服务把 **配置级** 的东西一起用了
/// （`appConfig.headers`、解析规则、广告规则、直连 spider 注册结果、
/// sidecar 运行时缓存）。所以这里持有的是「配置 + 它自己的站点服务」这一对，
/// 调用方拿到什么就是什么，不会再从 `AppState` 的生效配置里补。
///
/// ## 为什么站点按 key 现查
///
/// 同名 key 在多个配置里完全可能重复（都是 `csp_xxx`）。把站点缓存在这里会让
/// 「配置重新导入后站点变了」读到一个过期对象，所以只缓存配置与服务，站点按
/// key 现查。
library;

import '../core/protocol.dart';
import '../services/site_service.dart';
import '../services/storage.dart';

/// 原来源播放上下文：配置记录 + 它自己的站点服务。
class PlaybackSourceContext {
  const PlaybackSourceContext({
    required this.sourceKey,
    required this.record,
    required this.config,
    required this.service,
  });

  /// 播放源标识（`core/source_key.dart`），也是历史行的 `source_key`。
  final String sourceKey;

  /// 该来源对应的配置记录（取名称、设备等展示信息用）。
  final ConfigRecord record;

  /// 该配置自己的 `AppConfig`。
  final AppConfig config;

  /// 绑定到 [config] 的站点服务：请求头、解析规则、运行时都由它自己的路由决定。
  final SiteService service;

  /// 在这份配置里按 key 查站点；找不到返回 `null`（调用方据此回退）。
  ///
  /// 隐藏站点（`hide`）也算「找得到」：历史里的记录可能属于用户后来隐藏的站点，
  /// 隐藏只影响列表展示，不影响已存在的历史能不能续播。
  Site? siteByKey(String key) {
    final target = key.trim();
    if (target.isEmpty) return null;
    for (final site in config.sites) {
      if (site.key == target) return site;
    }
    return null;
  }

  @override
  String toString() => 'PlaybackSourceContext($sourceKey sites=${config.sites.length})';
}
