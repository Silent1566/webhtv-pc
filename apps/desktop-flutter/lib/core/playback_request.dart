import 'source_swap.dart';
import 'protocol.dart';
import 'tmdb_detail_model.dart';
import 'tmdb_playback.dart';
import 'history_view.dart';

/// 一次播放请求（由详情页或命令行构造）。
class PlaybackRequest {
  const PlaybackRequest({
    required this.url,
    required this.title,
    required this.siteKey,
    required this.vodId,
    required this.vodName,
    required this.episodeName,
    required this.flag,
    String? playbackFlag,
    String? episodeTarget,
    this.headers = const {},
    this.startPosition,
    this.playLines = const [],
    this.lineRoutes = const {},
    this.episodeCardsByFlag = const {},
    this.episodesReversed = false,
    this.episodeIndex = 0,
    this.vodPic,
    this.directUrl = false,
    this.subtitles = const [],
    this.subtitleHeaders = const {},
    this.danmaku = const [],
    this.tmdb,
    this.resumeSeed,
    this.sourceKey = '',
  }) : episodeTarget = episodeTarget ?? url,
       playbackFlag = playbackFlag ?? flag;

  final String url;
  final String title;
  final String siteKey;
  final String vodId;
  final String vodName;
  final String episodeName;
  final String flag;
  final String playbackFlag;
  final Map<String, String> headers;
  final Duration? startPosition;

  /// 站点播放入口的**输入目标**（详情 `vod_play_url` 里该集 `$` 之后的值）。
  ///
  /// 与 [url] 的区别很关键：
  /// - [url] 是**解析后的可播地址**（T4 站点还要再经本地代理换成 `127.0.0.1/p/<token>/…`），
  ///   带时效签名，**不能**当作再次解析的输入；
  /// - [episodeTarget] 是站点能认的原始目标（网盘站是分享链，普通站是剧集地址）。
  ///
  /// 历史续播必须用 [episodeTarget] 重新解析：拿 [url] 去问站点只会得到
  /// 「站点返回业务错误」（用户反馈 2026-10-09「无法从历史记录页面继续播放」）。
  /// 为空时回退到 [url]（兼容命令行/直播等无需二次解析的场景）。
  final String episodeTarget;

  /// 播放结果携带的外挂字幕（§10.3）。
  final List<SubtitleInfo> subtitles;

  /// 拉取外挂字幕时使用的 Header（与媒体一致，含 Referer/UA/Cookie）。
  ///
  /// 与 [headers] 分开：走本地代理时 [headers] 被清空（由代理注入），而字幕由
  /// 宿主自己请求，必须用代理前的原始 Header（§11.3.1）。
  final Map<String, String> subtitleHeaders;

  /// 播放结果携带的弹幕源（§21 Phase 3）。拉取弹幕同样使用 [subtitleHeaders]。
  final List<DanmakuSource> danmaku;

  /// TMDB 季度身份（`docs/phase4/design/04` §8.1）。
  ///
  /// 为 `null` 时表示未携带季度身份（历史恢复、直播、命令行），
  /// 此时只写来源 `history`，不写季度进度（`02` §6.2）。
  final TmdbPlaybackIdentity? tmdb;

  /// 详情页给出的全部线路，用于线路切换与上下集。
  final List<VodPlayLine> playLines;

  /// 外部（换源并入）线路的来源路由：页面内 flag → 来源站点与它自己的 vodId。
  ///
  /// 为什么播放器也要收：换集、切线路都会重新解析地址，而外部线路必须**继续**
  /// 定向到它自己的站点。只看 [siteKey] 不够——[siteKey] 记的是真来源站点，
  /// 但 `vodId` 也得跟着换，否则会拿原站点的 vod 去问外部站点。
  final Map<String, SwapLineRoute> lineRoutes;

  /// 详情页为**每一条线路**各算一次的剧集卡片（`tmdb_detail_model.dart`），
  /// 按线路展示标识（[flag]）分组。
  ///
  /// 为什么播放器还要收一次：浮层里的选集面板要显示详情页那套海报卡片
  /// （集号/集标题/剧照），而播放器手上只有 [playLines] 里的来源集名。
  /// 卡片只能由详情页算好传下来——集号推断依赖季过滤后的渲染顺序与
  /// `sourceIndices`（见 `TmdbEpisodeCards.build`），播放器没有这些上下文。
  ///
  /// 为什么是 **Map 而不是单个列表**：卡片以前只给「详情页当时选中的那条线路」，
  /// 播放器切到别的线路时 `copyWith` 会把旧卡片原样带过；两条线路集数恰好相等时，
  /// 旧线路的剧照会被贴到新线路的集上，长度校验根本查不出来。按线路分组后，
  /// 切到哪条线路就取哪条线路自己的卡片。
  ///
  /// 空 Map = 这次播放没有卡片可用（未匹配 TMDB、历史恢复、直播、命令行），
  /// 不是「暂时还没传」：调用方不得为它编造占位卡片。
  final Map<String, List<TmdbEpisodeCard>> episodeCardsByFlag;

  /// 详情页当时的页面级「倒序」开关状态（`browse_pages.dart` 的 `_episodesReversed`）。
  ///
  /// 卡片顺序由详情页按它当时的倒序状态算好，播放器的选集面板必须跟着同一个方向
  /// 排列，否则集列表、区间标签与卡片三者会互相错位。这是**页面级临时状态**，
  /// 只在用户点播那一刻快照一次，播放器不再翻它。
  final bool episodesReversed;

  final int episodeIndex;
  final String? vodPic;

  /// 待迁移的续播种子（跨源续播用，`docs/phase5/design/05` §7.3）。
  ///
  /// 为什么播放器还要收一次：比例换算需要**目标集的真实时长**，而目标集要
  /// `open()` 成功后才拿得到（[_load] 里 `_controller.duration`）。详情页算出的
  /// [startPosition] 只能按绝对毫秒给（它拿不到时长），两源同一集时长差很大时
  /// 会落到中段甚至片尾。带上种子后由播放器用真实时长重算一遍。
  ///
  /// 这是**一次性交接**：首次恢复成功后即被清掉（见 [_load]），换集与
  /// 「从最新进度续播」也必须清掉，否则会把上一集的种子套到新集上。
  final ResumeSeed? resumeSeed;

  /// 这一次播放用的**播放源标识**（`core/source_key.dart`）。
  ///
  /// 空串 = 当前生效源（既有语义）。非空且与生效源不同时，说明这次播放来自
  /// 「其它配置的历史」：换集/切线路必须继续用**那份配置**解析
  /// （[AppState.resolvePlaybackForSource]），进度也必须写回它自己的
  /// `source_key`，否则一次续播就会在当前源里多出一条同名历史。
  final String sourceKey;

  /// 地址已是最终可播地址（直播频道），无需经站点播放入口解析。
  ///
  /// 直播源的 `urls` 直接在本地就是媒体地址，走解析器只会多余地请求站点；
  /// 同时直播需要「失败按顺序切线路」（§13.3），与点播的剧集切换语义不同。
  final bool directUrl;

  PlaybackRequest copyWith({
    String? url,
    String? episodeTarget,
    String? episodeName,
    String? flag,
    String? playbackFlag,
    Map<String, String>? headers,
    int? episodeIndex,
    Duration? startPosition,
    bool clearStartPosition = false,
    List<SubtitleInfo>? subtitles,
    List<DanmakuSource>? danmaku,
    ResumeSeed? resumeSeed,
    bool clearResumeSeed = false,
    String? sourceKey,
    bool clearSourceKey = false,
  }) {
    return PlaybackRequest(
      url: url ?? this.url,
      // `episodeTarget` **不随 `url` 自动跟随**：两者语义不同（前者是站点入口
      // 目标、后者是解析后的可播地址），若换 `url` 时把入口目标也顶成播放地址，
      // 历史里存的就又是站点认不了的值。换集的调用点必须**显式**传 `episodeTarget`。
      episodeTarget: episodeTarget ?? this.episodeTarget,
      title: title,
      siteKey: siteKey,
      vodId: vodId,
      vodName: vodName,
      episodeName: episodeName ?? this.episodeName,
      flag: flag ?? this.flag,
      playbackFlag: playbackFlag ?? this.playbackFlag,
      headers: headers ?? this.headers,
      startPosition: clearStartPosition
          ? null
          : (startPosition ?? this.startPosition),
      // 与 `startPosition` 一样是「一次性交接」：显式清除优先，其次是新值。
      resumeSeed: clearResumeSeed ? null : (resumeSeed ?? this.resumeSeed),
      playLines: playLines,
      // 与 `playLines` / `siteKey` 一样原样带过：换集不能把外部线路的路由丢掉。
      lineRoutes: lineRoutes,
      // 卡片同属「详情页一次性算好」的上下文：换集不带过来，选集面板就退回裸集名，
      // 而播放器自己再也算不回来（缺选中季度与季过滤后的渲染顺序）。按线路分组后
      // 切线路也能取到**那条线路自己**的卡片，不必等详情页重新算。
      episodeCardsByFlag: episodeCardsByFlag,
      // 倒序是详情页那一刻的展示顺序，与卡片同属一次性快照：换集不能把它翻回去。
      episodesReversed: episodesReversed,
      episodeIndex: episodeIndex ?? this.episodeIndex,
      vodPic: vodPic,
      directUrl: directUrl,
      subtitles: subtitles ?? this.subtitles,
      subtitleHeaders: subtitleHeaders,
      danmaku: danmaku ?? this.danmaku,
      tmdb: tmdb,
      // 播放源归属默认原样带过：换集后进度仍要写回同一条来源。
      // 切到**外部并入线路**（属于当前配置）时必须显式清空，否则进度会被
      // 写回原来源，历史页从此多出一条挂错源的记录。
      sourceKey: clearSourceKey ? '' : (sourceKey ?? this.sourceKey),
    );
  }
}
