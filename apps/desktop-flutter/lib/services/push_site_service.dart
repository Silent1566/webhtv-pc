/// 推送的合成站点服务（安卓 `SiteApi.pushDetail` 的服务层对应物）。
///
/// 为什么要有它：配置里没有「推送」源时，推送仍然必须能进**普通详情页**——
/// 线路、选集、播放按钮、历史与 TMDB 都走既有管线。这里只实现推送真正需要的
/// 两个动作：详情返回单线路单集、播放把地址原样交给播放器；其它动作不参与。
library;

import '../core/parse_failover.dart';
import '../core/protocol.dart';
import '../core/push_parser.dart';
import 'parse_service.dart';
import 'site_service.dart';

class PushSiteService extends SiteService {
  PushSiteService({
    required super.appConfig,
    required super.router,
    super.database,
    super.userAgent,
    required this.parsed,
  });

  final PushParsed parsed;

  @override
  Future<SiteCallResult<SiteResult>> detail(
    Site site,
    String vodId, {
    VodIdentityHint? identity,
  }) async {
    return SiteCallResult(
      value: pushSiteDetail(parsed),
      latency: Duration.zero,
    );
  }

  @override
  Future<SiteCallResult<PlaybackDecision>> resolvePlayback({
    required Site site,
    required String episodeTarget,
    String? flag,
    String? vodId,
    int? qualityIndex,
    ParseService? parseService,
    ParseFailoverSettings? parseFailover,
    String? preferredParseName,
  }) async {
    // 推送地址已经是可播目标：不做直链初判、不走解析器，直接交给播放器
    // （安卓 `Push` extractor 对 `push://` 也是同一语义）。
    return SiteCallResult(
      value: PlaybackDecision(
        action: PlaybackAction.direct,
        url: episodeTarget,
        flag: flag ?? pushSourceName,
      ),
      latency: Duration.zero,
    );
  }
}
