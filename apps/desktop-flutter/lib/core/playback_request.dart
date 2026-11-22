import 'source_swap.dart';
import 'protocol.dart';
import 'tmdb_detail_model.dart';
import 'tmdb_playback.dart';
import 'history_view.dart';

/// 播放源的种类。
///
/// 只有两类，没有中间态：一类是站点解析（含本地代理）产出的媒体地址，
/// 一类是用户通过「打开本地文件」挑中的一个磁盘文件。
enum PlaybackSourceKind {
  /// 站点解析或本地代理产出的媒体地址：可带 Header、可跨源续播。
  remote,

  /// 磁盘上的本地媒体文件：没有站点、没有 Header、不经回环代理。
  local,
}

/// 一次播放请求（由详情页、命令行或「打开本地文件」构造）。
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
    this.qualities = const [],
    this.qualityIndex = 0,
    this.startPosition,
    this.playLines = const [],
    this.lineRoutes = const {},
    this.episodeCardsByFlag = const {},
    this.episodesReversed = false,
    this.episodeIndex = 0,
    this.vodPic,
    this.posterUrl,
    this.vodYear,
    this.directUrl = false,
    this.subtitles = const [],
    this.subtitleHeaders = const {},
    this.danmaku = const [],
    this.tmdb,
    this.resumeSeed,
    this.sourceKey = '',
    this.parseSources = const <String>[],
    this.parseSource = '',
    this.sourceKind = PlaybackSourceKind.remote,
    this.localPath = '',
  }) : episodeTarget = episodeTarget ?? url,
       playbackFlag = playbackFlag ?? flag;

  /// 「打开本地文件」的请求：把一个磁盘路径包成 [PlaybackSourceKind.local]。
  ///
  /// 本地源与站点播放的**边界**（Wave 1 定死；播放器页 Wave 2 再消费）：
  /// - **不注入 Header**：[headers] / [subtitleHeaders] 恒为空——本地文件没有
  ///   站点鉴权，也没有理由让 Cookie/Referer 跟着一个本地路径走；
  /// - **不经回环代理、不过站点解析**：[url] 就是磁盘路径本身，[directUrl] 仍为
  ///   `false`——`directUrl` 在播放器页等价于「直播」，借用它会让进度条消失；
  /// - **不参与跨源续播与多源聚合**：[episodeTarget] 只回退成同一路径，没有站点
  ///   可以重新解析；[playLines] / [lineRoutes] / [episodeCardsByFlag] /
  ///   [parseSources] / [parseSource] 全为空，[resumeSeed] 不带；
  /// - [siteKey] 固定 [localSiteKey]：历史与进度按站点分组，本地播放集中在
  ///   这一个合成站点下，不会混进任何真实配置的续播。
  factory PlaybackRequest.localFile({required String path, String? title}) {
    final target = path.trim();
    if (target.isEmpty) {
      throw ArgumentError.value(path, 'path', '本地文件路径不能为空');
    }
    final name = _fileName(target);
    final display = (title ?? '').trim();
    final resolved = display.isEmpty ? _fileTitle(name) : display;
    return PlaybackRequest(
      url: target,
      // `url` 与 `localPath` 必须一致：播放器页直接 `open(request.url)`，它不看
      // 源种类——两者分叉，本地文件就打不开了。
      localPath: target,
      sourceKind: PlaybackSourceKind.local,
      title: resolved,
      siteKey: localSiteKey,
      vodId: target,
      vodName: resolved,
      episodeName: name,
      flag: localSourceFlag,
    );
  }

  /// 本地播放的合成站点标识（历史按站点分组，本地播放集中在这一条下）。
  static const String localSiteKey = 'local-file';

  /// 本地播放的线路名。
  static const String localSourceFlag = '本地文件';

  static String _fileName(String path) {
    final parts = path.split(RegExp(r'[/\\]')).where((s) => s.isNotEmpty);
    return parts.isEmpty ? path : parts.last;
  }

  /// 去掉扩展名：`阿凡达.2009.mkv` 的标题只留 `阿凡达.2009`。
  static String _fileTitle(String fileName) {
    final dot = fileName.lastIndexOf('.');
    return dot <= 0 ? fileName : fileName.substring(0, dot);
  }

  final String url;
  final String title;
  final String siteKey;
  final String vodId;
  final String vodName;
  final String episodeName;
  final String flag;
  final String playbackFlag;
  final Map<String, String> headers;
  final List<PlaybackQuality> qualities;
  final int qualityIndex;
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

  /// 本剧海报（选集卡片剧照缺失/失败时的回退图）。
  ///
  /// 与详情页卡片同一个取值口径：**TMDB 海报优先、站源封面兜底**
  /// （`browse_pages.dart` 的 `_ownedTmdb?.detailData?.posterUrl ?? vod.vodPic`）。
  /// 为什么不能只让播放器读 [vodPic]：站源封面常是低清竖图，而详情页卡片
  /// （以及播放器里要模仿的那一屏）用的是 TMDB 海报——少带一个字段，同一部剧
  /// 在两个页面就会有两张不同的回退图。
  ///
  /// 空/缺省 = 这次播放没有可回退的海报（历史续播、直播、命令行、本地文件），
  /// 不是「暂时还没传」：消费方不得据此编造图片。
  final String? posterUrl;

  /// 作品年份（`Vod.vodYear` 原样带下来，可能为空或非四位数字）。
  ///
  /// 为什么播放器需要它：弹幕库搜索是按片名问中转的，中转会同时返回同名不同年
  /// 的多部剧（`一马当先(2026)【电视剧】` / `一马当先(2023)【短剧】`）。年份是
  /// 区分它们唯一的结构化证据，而详情页之外的构造点（历史续播/推送/直播/本地
  /// 文件）拿不到 `Vod`，所以默认 null，由消费方按「缺证据」中性处理。
  final String? vodYear;

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

  /// 本次播放**实际可选**的解析源名称（`PlaybackDecision.parseSources` 原样带过来）。
  ///
  /// 为什么由播放结果带过来而不是 UI 读全局配置：原来源续播用的是**那份配置**的
  /// 解析器，读当前配置会把 A 配置的解析器列在 B 配置的播放上；而且直链播放
  /// 根本没有可切换的解析源，读配置就会凭空多出一排无效入口。
  final List<String> parseSources;

  /// 当前生效的解析源名称；[parseSources] 为空时无意义。
  final String parseSource;

  /// 本次播放的源种类；[PlaybackSourceKind.local] 时看 [localPath]。
  final PlaybackSourceKind sourceKind;

  /// 本地文件的磁盘路径；空串 = 非本地源。
  ///
  /// 为本地源时**等于** [url]（见 [PlaybackRequest.localFile]）。
  final String localPath;

  /// 是否本地文件播放。
  ///
  /// 消费方应只看这一个判据，不要用「地址以 `/` 或盘符开头」之类去猜：本地
  /// 与否是请求的语义，不是地址的形状。
  bool get isLocal => sourceKind == PlaybackSourceKind.local;

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
    Map<String, String>? subtitleHeaders,
    List<PlaybackQuality>? qualities,
    List<VodPlayLine>? playLines,
    // 补齐选集入口时一并换上「线路 → 来源站点/vod_id」的路由：只换线路不换路由，
    // 换集会拿原请求的 vodId 去问站点（目录条目会直接被判为业务错误）。
    Map<String, SwapLineRoute>? lineRoutes,
    int? qualityIndex,
    int? episodeIndex,
    Duration? startPosition,
    bool clearStartPosition = false,
    List<SubtitleInfo>? subtitles,
    List<DanmakuSource>? danmaku,
    ResumeSeed? resumeSeed,
    bool clearResumeSeed = false,
    String? sourceKey,
    bool clearSourceKey = false,
    List<String>? parseSources,
    String? parseSource,
    PlaybackSourceKind? sourceKind,
    String? localPath,
    // 年份是详情页的上下文：换集时原样带过，否则换了集就丢掉了「同名哪一部」的线索。
    String? vodYear,
    // 换集要同时换成该集的 TMDB 身份；缺这个参数会让 `copyWith(tmdb: …)`
    // 在编译期就失败（beta 抽类时只留了构造实参，漏了形参）。
    TmdbPlaybackIdentity? tmdb,
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
      qualities: qualities ?? this.qualities,
      qualityIndex: qualityIndex ?? this.qualityIndex,
      startPosition: clearStartPosition
          ? null
          : (startPosition ?? this.startPosition),
      // 与 `startPosition` 一样是「一次性交接」：显式清除优先，其次是新值。
      resumeSeed: clearResumeSeed ? null : (resumeSeed ?? this.resumeSeed),
      playLines: playLines ?? this.playLines,
      // 与 `playLines` / `siteKey` 一样原样带过：换集不能把外部线路的路由丢掉。
      lineRoutes: lineRoutes ?? this.lineRoutes,
      // 卡片同属「详情页一次性算好」的上下文：换集不带过来，选集面板就退回裸集名，
      // 而播放器自己再也算不回来（缺选中季度与季过滤后的渲染顺序）。按线路分组后
      // 切线路也能取到**那条线路自己**的卡片，不必等详情页重新算。
      episodeCardsByFlag: episodeCardsByFlag,
      // 倒序是详情页那一刻的展示顺序，与卡片同属一次性快照：换集不能把它翻回去。
      episodesReversed: episodesReversed,
      episodeIndex: episodeIndex ?? this.episodeIndex,
      vodPic: vodPic,
      // 海报同属「详情页带下来的上下文」：换集不能让选集卡片的回退图变成灰块，
      // 所以这里没有形参、原样带过。
      posterUrl: posterUrl,
      vodYear: vodYear ?? this.vodYear,
      directUrl: directUrl,
      subtitles: subtitles ?? this.subtitles,
      subtitleHeaders: subtitleHeaders ?? this.subtitleHeaders,
      danmaku: danmaku ?? this.danmaku,
      tmdb: tmdb,
      // 播放源归属默认原样带过：换集后进度仍要写回同一条来源。
      // 切到**外部并入线路**（属于当前配置）时必须显式清空，否则进度会被
      // 写回原来源，历史页从此多出一条挂错源的记录。
      sourceKey: clearSourceKey ? '' : (sourceKey ?? this.sourceKey),
      parseSources: parseSources ?? this.parseSources,
      parseSource: parseSource ?? this.parseSource,
      // 源种类与本地路径原样带过：换集对本地文件没有意义，但漏掉这两个字段会
      // 把一次「copyWith 之后的本地请求」悄悄降级成 remote，播放器页从此按站点
      // 语义处理它（例如拿本地路径去问站点重新解析）。
      sourceKind: sourceKind ?? this.sourceKind,
      localPath: localPath ?? this.localPath,
    );
  }
}
